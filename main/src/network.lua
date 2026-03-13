local json = require("main.json")

local log = require("main.src.log")
local shared = require("main.src.shared")

local M = {}
local BINARY_MAGIC = "SRCB"

local function encodeBinaryFrame(frameType, payload)
	if type(frameType) ~= "string" or frameType == "" then
		return nil
	end

	if type(payload) ~= "string" then
		payload = ""
	end

	return string.pack(">c4I2I4", BINARY_MAGIC, #frameType, #payload) .. frameType .. payload
end

local function parseMsgId(value)
	if type(value) == "number" then
		local id = math.floor(value)
		if id > 0 then
			return id
		end
		return nil
	end

	if type(value) == "string" and value ~= "" then
		local parsed = tonumber(value)
		if parsed then
			local id = math.floor(parsed)
			if id > 0 then
				return id
			end
		end
	end

	return nil
end

local function ensureEventTrackingTables(client)
	client.awaitingResults = client.awaitingResults or {}
	client.earlyResults = client.earlyResults or {}
	client.recentCompleted = client.recentCompleted or {}
end

local function markEventRecentlyCompleted(state, client, msgId)
	local keepTicks = math.max(120, tonumber(state.config.eventProcessTimeoutTicks) or 180)
	client.recentCompleted[msgId] = state.tick + keepTicks
end

local function cleanupRecentCompletions(state, client)
	for msgId, expiryTick in pairs(client.recentCompleted) do
		if state.tick >= expiryTick then
			client.recentCompleted[msgId] = nil
		end
	end
end

local function logEventResult(state, connection, name, msgId, payload)
	local status = tostring(payload.status or "")
	local handled = tonumber(payload.handled) or 0
	local errors = tonumber(payload.errors) or 0
	local detail = tostring(payload.error or "")

	if status == "processed" and errors == 0 then
		if state.config.eventDebugLogSuccess then
			log.info(
				"event processed [OK]: name=%s id=%s client=%s handlers=%s",
				name or "?",
				msgId,
				shared.clientId(connection),
				handled
			)
		end
	else
		log.warn(
			"event processing failed [SRC_OR_SRCC_NEVER_PROCESSED_IT]: name=%s id=%s client=%s status=%s handlers=%s errors=%s detail=%s",
			name or "?",
			msgId,
			shared.clientId(connection),
			status ~= "" and status or "unknown",
			handled,
			errors,
			detail ~= "" and detail or "-"
		)
	end
end

local function getPlayerConnection(state, player)
	if not state or not player then
		return nil
	end

	if type(player) == "userdata" and player.class == "Player" then
		if player.isBot then
			return nil
		end

		for connection, client in pairs(state.clients) do
			if client and connection and client.player == player then
				return connection
			end
		end
	end

	return nil
end

local function resolveClientPlayer(_, connection)
	if not connection then
		return nil
	end

	local bestPlayer = nil
	local remoteAddress = tostring(connection.address)

	for _, player in ipairs(players.getNonBots()) do
		if not player.isBot and player.connection and tostring(player.connection.address) == remoteAddress then
			if bestPlayer ~= nil then
				return nil
			end

			bestPlayer = player
		end
	end

	return bestPlayer
end

local function refreshClientPlayerBinding(state, connection, client)
	if not client or client.hello ~= true then
		return nil
	end

	local player = resolveClientPlayer(state, connection, client.helloPayload)
	client.player = player
	return player
end

local function clearClientState(state, connection)
	local client = state.clients[connection]
	if client and client.activeFileTransfer and client.activeFileTransfer.file then
		pcall(function()
			client.activeFileTransfer.file:close()
		end)
	end
	state.clients[connection] = nil
end

local function enqueueBytes(state, connection, bytes)
	local client = state.clients[connection]
	if not client or type(bytes) ~= "string" or #bytes == 0 then
		return false
	end

	table.insert(client.sendQueue, bytes)
	return true
end

local function enqueueFrame(state, connection, frameType, payload)
	local body = {
		type = frameType,
		payload = payload or {},
	}

	return enqueueBytes(state, connection, json.encode(body) .. "\n")
end

local function flushSendQueue(state, connection)
	local client = state.clients[connection]
	if not client or not connection.isOpen then
		return
	end

	local sendBudget = math.max(1024, tonumber(state.config.maxSendBytesPerTick) or 262144)
	local sentThisTick = 0
	while #client.sendQueue > 0 and sentThisTick < sendBudget do
		local current = client.sendQueue[1]
		local offset = client.sendOffset
		local chunk = current:sub(offset)

		local ok, sentOrErr = pcall(connection.send, connection, chunk)
		if not ok then
			log.warn("send failed (%s): %s", shared.clientId(connection), sentOrErr)
			connection:close()
			break
		end

		local sent = tonumber(sentOrErr) or 0
		if sent <= 0 then
			break
		end
		sentThisTick = sentThisTick + sent

		client.sendOffset = offset + sent
		if client.sendOffset > #current then
			table.remove(client.sendQueue, 1)
			client.sendOffset = 1
		else
			break
		end
	end
end

local function queueSyncFile(state, connection, relPath)
	local client = state.clients[connection]
	if not client then
		return
	end

	local isScript = state.scriptsByPath[relPath] ~= nil
	local isAssetFile = state.assetFilesByPath[relPath] ~= nil

	local validPath = false
	if isScript then
		validPath = shared.isSafeSyncPath(relPath)
	elseif isAssetFile then
		validPath = shared.isSafeAssetSyncPath(relPath)
	end

	if not validPath then
		enqueueFrame(state, connection, "ERROR_REPORT", {
			error = "invalid FILE_REQ path",
			path = relPath,
		})
		return
	end

	if client.activeFileTransfer and client.activeFileTransfer.path == relPath then
		return
	end

	for _, queuedPath in ipairs(client.pendingFileRequests) do
		if queuedPath == relPath then
			return
		end
	end

	table.insert(client.pendingFileRequests, relPath)
end

local function startNextFileTransfer(state, connection, client)
	if client.activeFileTransfer or #client.pendingFileRequests == 0 then
		return false
	end

	local relPath = table.remove(client.pendingFileRequests, 1)
	local fullPath = nil
	local scriptRecord = state.scriptsByPath[relPath]
	local assetRecord = state.assetFilesByPath[relPath]
	if scriptRecord then
		fullPath = scriptRecord.sourcePath
	elseif assetRecord then
		fullPath = assetRecord.sourcePath
	end

	if not fullPath then
		enqueueFrame(state, connection, "ERROR_REPORT", {
			error = "path not found in sync index",
			path = relPath,
		})
		return false
	end

	local file = io.open(fullPath, "rb")
	if not file then
		enqueueFrame(state, connection, "ERROR_REPORT", {
			error = "file read failed",
			path = relPath,
		})
		return false
	end

	client.activeFileTransfer = {
		path = relPath,
		file = file,
	}
	return true
end

local function pumpFileTransfer(state, connection)
	local client = state.clients[connection]
	if not client or not connection.isOpen then
		return
	end

	local chunkSize = math.max(256, tonumber(state.config.fileChunkSize) or 12000)
	local chunkBudget = math.max(1, tonumber(state.config.maxFileChunksPerTick) or 8)
	local maxQueuedSendFrames = math.max(8, tonumber(state.config.maxQueuedSendFrames) or 256)

	local sentChunks = 0
	while sentChunks < chunkBudget do
		if #client.sendQueue >= maxQueuedSendFrames then
			return
		end

		if not client.activeFileTransfer and not startNextFileTransfer(state, connection, client) then
			return
		end

		local transfer = client.activeFileTransfer
		if not transfer then
			return
		end

		local okRead, chunkOrErr = pcall(transfer.file.read, transfer.file, chunkSize)
		if not okRead then
			enqueueFrame(state, connection, "ERROR_REPORT", {
				error = "file read failed",
				path = transfer.path,
			})
			pcall(function()
				transfer.file:close()
			end)
			client.activeFileTransfer = nil
			return
		end

		if type(chunkOrErr) == "string" and #chunkOrErr > 0 then
			local binaryFrame = encodeBinaryFrame(
				"FILE_CHUNK",
				string.pack(">I2", #transfer.path) .. transfer.path .. chunkOrErr
			)
			if not binaryFrame or not enqueueBytes(state, connection, binaryFrame) then
				return
			end
			sentChunks = sentChunks + 1
		else
			pcall(function()
				transfer.file:close()
			end)
			client.activeFileTransfer = nil
			if not enqueueFrame(state, connection, "FILE_END", {
				path = transfer.path,
			}) then
				return
			end
		end
	end
end

local function handleClientEvent(state, connection, payload)
	local name = payload and payload.name
	if type(name) ~= "string" or name == "" then
		return false, "invalid_name"
	end

	local callbacks = state.eventHandlers[name]
	if not callbacks or #callbacks == 0 then
		log.warn(
			"event rejected [NOTHING_HANDLED_EVENT_ON_SERVER]: name=%s id=%s client=%s",
			name,
			tostring(payload and payload.msgId),
			shared.clientId(connection)
		)
		enqueueFrame(state, connection, "ERROR_REPORT", {
			code = "NOTHING_HANDLED_EVENT_ON_SERVER",
			error = "No server handlers registered for event",
			name = name,
			msgId = payload and payload.msgId,
		})
		return false, "no_handler"
	end

	local hadErrors = false
	for _, fn in ipairs(callbacks) do
		local ok, err = pcall(fn, connection, payload.data, payload.bin)
		if not ok then
			hadErrors = true
			log.warn("src.onClientEvent callback failed (%s): %s", name, err)
		end
	end

	if hadErrors then
		enqueueFrame(state, connection, "ERROR_REPORT", {
			code = "NOTHING_HANDLED_EVENT_ON_SERVER",
			error = "One or more server handlers failed while processing event",
			name = name,
			msgId = payload and payload.msgId,
		})
		return false, "handler_error"
	end

	return true, "processed"
end

local function queueEventFrame(state, connection, direction, name, data, bin)
	local client = state.clients[connection]
	if not client or not connection.isOpen or not client.hello then
		return false
	end

	if type(name) ~= "string" or name == "" then
		return false
	end

	local payload = {
		dir = direction,
		name = name,
		data = data,
	}

	if bin ~= nil then
		if type(bin) ~= "string" then
			return false
		end
		payload.bin = bin
	end

	if shared.eventPayloadSize(payload) > state.config.maxEventBytes then
		log.warn("event too large; dropping (%s)", name)
		return false
	end

	local msgID = state.nextEventID
	state.nextEventID = state.nextEventID + 1
	if state.nextEventID > 2147483647 then
		state.nextEventID = 1
	end

	payload.msgId = msgID
	local frame = {
		type = "EVENT",
		payload = payload,
	}
	local bytes = json.encode(frame) .. "\n"
	enqueueBytes(state, connection, bytes)

	client.pendingEvents[msgID] = {
		bytes = bytes,
		attempts = 1,
		nextRetryTick = state.tick + state.config.eventRetryBaseTicks,
		name = name,
		createdTick = state.tick,
		lastRetryTick = state.tick,
	}

	return true
end

local function queueItemTypesSyncFrame(state, connection, payload)
	local client = state.clients[connection]
	if not client or not connection.isOpen or not client.hello then
		return false
	end

	if type(payload) ~= "table" then
		return false
	end

	if type(payload.itemTypes) ~= "table" or #payload.itemTypes == 0 then
		return false
	end

	if type(payload.binRaw) ~= "string" or payload.binRaw == "" then
		return false
	end

	local estimatedSize = 6 + (#payload.itemTypes * 4) + #payload.binRaw
	if estimatedSize > state.config.maxEventBytes then
		log.warn("item type sync payload too large; dropping")
		return false
	end

	local segments = {
		string.pack(">I2I2I2", payload.version or 1, payload.itemTypeSize or 0, #payload.itemTypes),
	}
	for i = 1, #payload.itemTypes do
		local entry = payload.itemTypes[i]
		segments[#segments + 1] = string.pack(">I2I2", entry.index or 0, entry.sourceIndex or 0)
	end
	segments[#segments + 1] = payload.binRaw

	local binaryFrame = encodeBinaryFrame("ITEM_TYPES_SYNC", table.concat(segments))
	if not binaryFrame then
		return false
	end

	return enqueueBytes(state, connection, binaryFrame)
end

local function queueItemTypeModelFrame(state, connection, index, modelName)
	local client = state.clients[connection]
	if not client or not connection.isOpen or not client.hello then
		return false
	end

	return enqueueFrame(state, connection, "ITEM_TYPE_MODEL", {
		index = index,
		model = modelName,
	})
end

local function queueItemTypeIconFrame(state, connection, index, iconPath)
	local client = state.clients[connection]
	if not client or not connection.isOpen or not client.hello then
		return false
	end

	return enqueueFrame(state, connection, "ITEM_TYPE_ICON", {
		index = index,
		icon = iconPath,
	})
end

local function queueItemTypeFireSoundsFrame(state, connection, index, soundPaths)
	local client = state.clients[connection]
	if not client or not connection.isOpen or not client.hello then
		return false
	end

	if type(soundPaths) ~= "table" then
		return false
	end

	return enqueueFrame(state, connection, "ITEM_TYPE_FIRE_SOUNDS", {
		index = index,
		fireSounds = soundPaths,
	})
end

local function acknowledgeEvent(state, connection, msgID)
	if not msgID then
		return
	end

	enqueueFrame(state, connection, "EVENT_ACK", {
		msgId = msgID,
	})
end

local function handleFrame(state, connection, frame)
	if type(frame) ~= "table" then
		return
	end

	local frameType = frame.type
	local payload = frame.payload or {}
	if type(frameType) ~= "string" then
		return
	end

	if frameType == "SRC_PING" then
		enqueueFrame(state, connection, "SRC_PONG", {
			protocol = 1,
		})
		return
	end

	if frameType == "HELLO" then
		local client = state.clients[connection]
		client.hello = true
		client.helloPayload = payload
		client.player = resolveClientPlayer(state, connection, payload)
		enqueueFrame(state, connection, "HELLO_ACK", {
			protocol = 1,
			port = server.port,
		})

		local buildSyncPayload = state.buildCustomItemTypesSyncPayload
		if type(buildSyncPayload) == "function" then
			local ok, payloadOrErr = pcall(buildSyncPayload, connection)
			if ok then
				local payload = payloadOrErr
				if type(payload) == "table" and type(payload.itemTypes) == "table" and #payload.itemTypes > 0 then
					queueItemTypesSyncFrame(state, connection, payload)

					-- Also send any model and icon assignments
					local modelAssignments = state.itemTypeModelAssignments
					if type(modelAssignments) == "table" then
						for idx, modelName in pairs(modelAssignments) do
							queueItemTypeModelFrame(state, connection, idx, modelName)
						end
					end

					local iconAssignments = state.itemTypeIconAssignments
					if type(iconAssignments) == "table" then
						for idx, iconPath in pairs(iconAssignments) do
							queueItemTypeIconFrame(state, connection, idx, iconPath)
						end
					end

					local fireSoundAssignments = state.itemTypeFireSoundAssignments
					if type(fireSoundAssignments) == "table" then
						for idx, soundPaths in pairs(fireSoundAssignments) do
							queueItemTypeFireSoundsFrame(state, connection, idx, soundPaths)
						end
					end
				end
			else
				log.warn("failed building custom item type sync payload: %s", tostring(payloadOrErr))
			end
		end
		return
	end

	if frameType == "INDEX_REQ" then
		shared.discoverAssetFiles(state)
		shared.discoverPersistentMode(state)
		enqueueFrame(state, connection, "INDEX_RES", {
			files = state.scripts,
			assetFiles = state.assetFiles,
			loadedLevel = state.loadedLevel,
			persistentMode = state.persistentMode,
		})
		return
	end

	if frameType == "FILE_REQ" then
		queueSyncFile(state, connection, payload.path)
		return
	end

	if frameType == "EVENT" then
		if payload.dir == "c2s" then
			local msgId = parseMsgId(payload.msgId)
			acknowledgeEvent(state, connection, msgId)

			local ok, reason = handleClientEvent(state, connection, payload)
			if not ok and reason == "invalid_name" then
				enqueueFrame(state, connection, "ERROR_REPORT", {
					code = "NOTHING_HANDLED_EVENT_ON_SERVER",
					error = "Invalid event name in c2s event payload",
					msgId = payload.msgId,
				})
			end
		end
		return
	end

	if frameType == "EVENT_ACK" then
		local client = state.clients[connection]
		local msgId = parseMsgId(payload.msgId)
		if client and msgId then
			ensureEventTrackingTables(client)
			local pending = client.pendingEvents[msgId]
			if pending then
				client.pendingEvents[msgId] = nil
				client.awaitingResults[msgId] = {
					name = pending.name,
					ackedTick = state.tick,
					deadlineTick = state.tick + state.config.eventProcessTimeoutTicks,
				}

				local early = client.earlyResults[msgId]
				if early then
					client.earlyResults[msgId] = nil
					local trackedName = client.awaitingResults[msgId] and client.awaitingResults[msgId].name or pending.name
					client.awaitingResults[msgId] = nil
					markEventRecentlyCompleted(state, client, msgId)
					logEventResult(state, connection, trackedName, msgId, early)
				end
			elseif client.awaitingResults[msgId] then
				-- Duplicate ACK while waiting for processing result; ignore.
			elseif client.recentCompleted[msgId] then
				-- Late ACK for a message we've already finalized; ignore.
			else
				log.warn("received EVENT_ACK for unknown id=%s from %s", msgId, shared.clientId(connection))
			end
		end
		return
	end

	if frameType == "EVENT_RESULT" then
		local client = state.clients[connection]
		if not client then
			return
		end
		ensureEventTrackingTables(client)

		local msgId = parseMsgId(payload.msgId)
		if not msgId then
			log.warn("received EVENT_RESULT with invalid msgId from %s", shared.clientId(connection))
			return
		end

		local tracked = client.awaitingResults[msgId]
		if not tracked then
			if client.pendingEvents[msgId] then
				-- Result arrived before transport ACK; cache until ACK arrives.
				client.earlyResults[msgId] = payload
				return
			end
			if client.recentCompleted[msgId] then
				-- Duplicate/late EVENT_RESULT for an already finalized event.
				return
			end
			log.warn("received EVENT_RESULT for unknown id=%s from %s", msgId, shared.clientId(connection))
			return
		end

		client.awaitingResults[msgId] = nil
		client.earlyResults[msgId] = nil
		markEventRecentlyCompleted(state, client, msgId)
		logEventResult(state, connection, tracked.name, msgId, payload)
		return
	end

	if frameType == "ERROR_REPORT" then
		log.warn("client error (%s): %s", shared.clientId(connection), tostring(payload.error))
	end
end

local function processBufferedFrames(state, connection, client, frameBudget)
	local processed = 0
	while processed < frameBudget do
		local newlinePos = client.recvBuffer:find("\n", 1, true)
		if not newlinePos then
			break
		end

		local line = client.recvBuffer:sub(1, newlinePos - 1)
		client.recvBuffer = client.recvBuffer:sub(newlinePos + 1)

		if line ~= "" then
			local frame = shared.safeJsonDecode(line)
			if frame then
				handleFrame(state, connection, frame)
			else
				enqueueFrame(state, connection, "ERROR_REPORT", {
					error = "invalid JSON frame",
				})
			end
			processed = processed + 1
		end
	end
	return processed
end

local function processClientReads(state, connection)
	local client = state.clients[connection]
	if not client or not connection.isOpen then
		return
	end

	local readSize = state.config.readSize
	local maxReadBytesPerTick = math.max(readSize, tonumber(state.config.maxReadBytesPerTick) or 262144)
	local maxFramesPerTick = 256
	local readBytesThisTick = 0
	local framesThisTick = processBufferedFrames(state, connection, client, maxFramesPerTick)

	while connection.isOpen and readBytesThisTick < maxReadBytesPerTick and framesThisTick < maxFramesPerTick do
		local ok, dataOrErr = pcall(connection.receive, connection, readSize)
		if not ok then
			log.warn("receive failed (%s): %s", shared.clientId(connection), dataOrErr)
			connection:close()
			break
		end

		if dataOrErr == nil then
			break
		end

		local data = tostring(dataOrErr)
		if data == "" then
			break
		end
		readBytesThisTick = readBytesThisTick + #data

		client.recvBuffer = client.recvBuffer .. data
		framesThisTick = framesThisTick + processBufferedFrames(
			state,
			connection,
			client,
			maxFramesPerTick - framesThisTick
		)
	end
end

local function processPendingRetries(state, connection)
	local client = state.clients[connection]
	if not client then
		return
	end
	ensureEventTrackingTables(client)
	cleanupRecentCompletions(state, client)

	local maxAttempts = state.config.eventRetryMaxAttempts
	local baseTicks = state.config.eventRetryBaseTicks

	for msgID, pending in pairs(client.pendingEvents) do
		if state.tick >= pending.nextRetryTick then
			if pending.attempts >= maxAttempts then
				log.warn(
					"event delivery failed [SERVER_NEVER_RECEIVED_IT]: name=%s id=%s client=%s attempts=%s",
					pending.name or "?",
					msgID,
					shared.clientId(connection),
					pending.attempts
				)
				client.pendingEvents[msgID] = nil
				client.earlyResults[msgID] = nil
				markEventRecentlyCompleted(state, client, msgID)
			else
				pending.attempts = pending.attempts + 1
				pending.nextRetryTick = state.tick + baseTicks * (2 ^ (pending.attempts - 1))
				pending.lastRetryTick = state.tick
				enqueueBytes(state, connection, pending.bytes)
			end
		end
	end

	for msgID, pending in pairs(client.awaitingResults) do
		if state.tick >= pending.deadlineTick then
			log.warn(
				"event processing timeout [SRC_OR_SRCC_NEVER_PROCESSED_IT]: name=%s id=%s client=%s (acked transport, no process result)",
				pending.name or "?",
				msgID,
				shared.clientId(connection)
			)
			client.awaitingResults[msgID] = nil
			client.earlyResults[msgID] = nil
			markEventRecentlyCompleted(state, client, msgID)
		end
	end
end

local function acceptConnections(state)
	if not state.tcpServer or not state.tcpServer.isOpen then
		return
	end

	while true do
		local ok, connOrErr = pcall(state.tcpServer.accept, state.tcpServer)
		if not ok then
			log.warn("accept failed: %s", connOrErr)
			break
		end

		if connOrErr == nil then
			break
		end

		state.clients[connOrErr] = {
			recvBuffer = "",
			sendQueue = {},
			sendOffset = 1,
			pendingFileRequests = {},
			activeFileTransfer = nil,
			hello = false,
			helloPayload = nil,
			player = nil,
			pendingEvents = {},
			awaitingResults = {},
			earlyResults = {},
			recentCompleted = {},
		}

		log.info("TCP client connected: %s", shared.clientId(connOrErr))
	end
end

local function processClients(state)
	for connection, client in pairs(state.clients) do
		if connection.isOpen and client then
			refreshClientPlayerBinding(state, connection, client)
		end

		if connection.isOpen then
			processClientReads(state, connection)
			processPendingRetries(state, connection)
			pumpFileTransfer(state, connection)
			flushSendQueue(state, connection)
		end

		if not connection.isOpen then
			log.info("TCP client disconnected: %s", shared.clientId(connection))
			clearClientState(state, connection)
		end
	end
end

local function closeAll(state)
	for connection, _ in pairs(state.clients) do
		if connection.isOpen then
			pcall(connection.close, connection)
		end
	end
	state.clients = {}

	if state.tcpServer and state.tcpServer.isOpen then
		pcall(state.tcpServer.close, state.tcpServer)
	end
	state.tcpServer = nil
	state.boundPort = nil
end

local function ensureTcpServer(state)
	if state.tcpBindInProgress then
		return
	end

	local desiredPort = tonumber(server.port) or 0
	if desiredPort <= 0 then
		return
	end

	if state.tcpServer and state.tcpServer.isOpen and state.boundPort == desiredPort then
		return
	end

	if state.tcpServer and state.tcpServer.isOpen then
		closeAll(state)
	end

	state.tcpBindInProgress = true
	local ok, serverOrErr = pcall(TCPServer.new, desiredPort)
	state.tcpBindInProgress = false
	if not ok then
		log.warn("failed to bind TCP server on %s: %s", desiredPort, serverOrErr)
		return
	end

	state.tcpServer = serverOrErr
	state.boundPort = desiredPort
	log.info("TCP listening on server port %s", desiredPort)
end

function M.onClientEvent(state, name, fn)
	assert(type(name) == "string", "src.onClientEvent(name, fn): name must be string")
	assert(type(fn) == "function", "src.onClientEvent(name, fn): fn must be function")

	if not state.eventHandlers[name] then
		state.eventHandlers[name] = {}
	end

	table.insert(state.eventHandlers[name], fn)
end

function M.emitClientEvent(state, player, name, data, bin)
	if player == nil then
		local sent = 0
		for connection, client in pairs(state.clients) do
			local ply = connection.player
			if connection.isOpen and client.hello and (not ply or not ply.isBot) then
				if queueEventFrame(state, connection, "s2c", name, data, bin) then
					sent = sent + 1
				end
			end
		end
		return sent
	end

	if type(player) ~= "userdata" or player.class ~= "Player" then
		return false
	end

	if player.isBot then
		return false
	end

	local connection = getPlayerConnection(state, player)
	if not connection then
		return false
	end

	return queueEventFrame(state, connection, "s2c", name, data, bin)
end

function M.syncClientItemTypes(state, player, payload)
	if type(payload) ~= "table" then
		return false
	end

	if player == nil then
		local sent = 0
		for connection, client in pairs(state.clients) do
			local ply = connection.player
			if connection.isOpen and client.hello and (not ply or not ply.isBot) then
				if queueItemTypesSyncFrame(state, connection, payload) then
					sent = sent + 1
				end
			end
		end
		return sent
	end

	if type(player) ~= "userdata" or player.class ~= "Player" then
		return false
	end

	if player.isBot then
		return false
	end

	local connection = getPlayerConnection(state, player)
	if not connection then
		return false
	end

	return queueItemTypesSyncFrame(state, connection, payload)
end

function M.syncClientItemTypesToConnection(state, connection, payload)
	if type(payload) ~= "table" then
		return false
	end

	return queueItemTypesSyncFrame(state, connection, payload)
end

function M.sendItemTypeModelToConnection(state, connection, index, modelName)
	return queueItemTypeModelFrame(state, connection, index, modelName)
end

function M.sendItemTypeIcon(state, player, index, iconPath)
	if player == nil then
		local sent = 0
		for connection, client in pairs(state.clients) do
			local ply = connection.player
			if connection.isOpen and client.hello and (not ply or not ply.isBot) then
				if queueItemTypeIconFrame(state, connection, index, iconPath) then
					sent = sent + 1
				end
			end
		end
		return sent
	end

	if type(player) ~= "userdata" or player.class ~= "Player" then
		return false
	end

	if player.isBot then
		return false
	end

	local connection = getPlayerConnection(state, player)
	if not connection then
		return false
	end

	return queueItemTypeIconFrame(state, connection, index, iconPath)
end

function M.sendItemTypeIconToConnection(state, connection, index, iconPath)
	return queueItemTypeIconFrame(state, connection, index, iconPath)
end

function M.sendItemTypeFireSounds(state, player, index, soundPaths)
	if player == nil then
		local sent = 0
		for connection, client in pairs(state.clients) do
			local ply = connection.player
			if connection.isOpen and client.hello and (not ply or not ply.isBot) then
				if queueItemTypeFireSoundsFrame(state, connection, index, soundPaths) then
					sent = sent + 1
				end
			end
		end
		return sent
	end

	if type(player) ~= "userdata" or player.class ~= "Player" then
		return false
	end

	if player.isBot then
		return false
	end

	local connection = getPlayerConnection(state, player)
	if not connection then
		return false
	end

	return queueItemTypeFireSoundsFrame(state, connection, index, soundPaths)
end

function M.sendItemTypeFireSoundsToConnection(state, connection, index, soundPaths)
	return queueItemTypeFireSoundsFrame(state, connection, index, soundPaths)
end


function M.sendItemTypeModel(state, player, index, modelName)
	if player == nil then
		local sent = 0
		for connection, client in pairs(state.clients) do
			local ply = connection.player
			if connection.isOpen and client.hello and (not ply or not ply.isBot) then
				if queueItemTypeModelFrame(state, connection, index, modelName) then
					sent = sent + 1
				end
			end
		end
		return sent
	end

	if type(player) ~= "userdata" or player.class ~= "Player" then
		return false
	end

	if player.isBot then
		return false
	end

	local connection = getPlayerConnection(state, player)
	if not connection then
		return false
	end

	return queueItemTypeModelFrame(state, connection, index, modelName)
end

function M.refresh(state)
	for connection, client in pairs(state.clients) do
		if connection.isOpen and client.hello then
			enqueueFrame(state, connection, "SYNC_APPLY", {})
		end
	end
end

function M.ensureTcpServer(state)
	ensureTcpServer(state)
end

function M.logicStep(state)
	ensureTcpServer(state)
	acceptConnections(state)
	processClients(state)
end

function M.shutdown(state)
	closeAll(state)
end

function M.getPlayerConnection(player)
	return getPlayerConnection(state, player)
end

function M.getConnectionPlayer(state, connection)
	local client = state and state.clients and state.clients[connection] or nil
	if not client then
		return nil
	end

	return client.player or refreshClientPlayerBinding(state, connection, client)
end

return M
