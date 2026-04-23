local json = require("main.json")

local log = require("main.src.log")
local shared = require("main.src.shared")
local eventCodec = require("main.src.eventCodec")
local udpEvents = require("main.src.udpEvents")

local M = {}
local BINARY_MAGIC = "SRCB"
local SERVER_EVENT_ID_MIN = 0x80000000
local SERVER_EVENT_ID_MAX = 0xFFFFFFFF
local disconnectOtherConnectionsForPlayer
local loggedLegacyTcpEventFrame = false
local unpackFn = table.unpack or unpack

local function parsePositiveInteger(value)
	if type(value) == "number" then
		local num = math.floor(value)
		if num > 0 then
			return num
		end
		return nil
	end

	if type(value) == "string" and value ~= "" then
		local parsed = tonumber(value)
		if parsed then
			local num = math.floor(parsed)
			if num > 0 then
				return num
			end
		end
	end

	return nil
end

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
	client.pendingResults = client.pendingResults or {}
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

local function logEventResult(state, connection, name, msgId, result)
	local args = result and result.args or nil
	local status = tostring((args and args[1]) or result and result.status or "")
	local handled = tonumber((args and args[2]) or result and result.handled) or 0
	local errors = tonumber((args and args[3]) or result and result.errors) or 0
	local detail = tostring((args and args[4]) or result and result.detail or "")

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

local function resolveClientPlayerFromHello(_, connection, payload)
	if not connection then
		return nil, "missing_connection"
	end

	if type(payload) ~= "table" then
		return nil, "invalid_hello_payload"
	end

	local phoneNumber = parsePositiveInteger(payload.phoneNumber or payload.phone)
	local subRosaID = parsePositiveInteger(payload.subRosaID or payload.subrosaID or payload.subrosa_id)
	if not phoneNumber and not subRosaID then
		return nil, "missing_bind_claims"
	end

	local bestPlayer = nil
	local remoteAddress = tostring(connection.address)

	for _, player in ipairs(players.getNonBots()) do
		if not player.isBot and player.connection and tostring(player.connection.address) == remoteAddress then
			if phoneNumber and tonumber(player.phoneNumber) ~= phoneNumber then
				goto continue
			end
			if subRosaID and tonumber(player.subRosaID) ~= subRosaID then
				goto continue
			end

			if bestPlayer ~= nil then
				return nil, "ambiguous_bind_claims"
			end

			bestPlayer = player
		end
		::continue::
	end

	if not bestPlayer then
		return nil, "no_matching_player"
	end

	return bestPlayer, nil
end

local function applyBoundPlayer(state, connection, client, player)
	if not state or not connection or not client or not player then
		return false
	end

	disconnectOtherConnectionsForPlayer(state, player, connection)
	client.player = player
	client.bound = true
	client.closeAfterFlush = false
	return true
end

local function closeClientTransfer(client)
	if client and client.activeFileTransfer and client.activeFileTransfer.file then
		pcall(function()
			client.activeFileTransfer.file:close()
		end)
	end
	if client then
		client.activeFileTransfer = nil
		client.activeBundleTransfer = nil
	end
end

local function resetClientSyncState(client)
	if not client then
		return
	end

	closeClientTransfer(client)
	client.pendingFileRequests = {}
	client.pendingBundleRequests = {}
	client.pendingEvents = {}
	client.pendingResults = {}
	client.awaitingResults = {}
	client.earlyResults = {}
	client.recentCompleted = {}
	client.sendQueue = {}
	client.sendOffset = 1
	udpEvents.resetClient(client)
end

local function clearClientBinding(client)
	if not client then
		return
	end

	resetClientSyncState(client)
	client.player = nil
	client.bound = false
end

local function validateBoundPlayer(connection, client)
	if not connection or not client or not client.player then
		return nil
	end

	local player = client.player
	if player.isBot or not player.connection then
		clearClientBinding(client)
		return nil
	end

	if tostring(player.connection.address) ~= tostring(connection.address) then
		clearClientBinding(client)
		return nil
	end

	if client.helloPayload then
		local phoneNumber = parsePositiveInteger(client.helloPayload.phoneNumber or client.helloPayload.phone)
		local subRosaID =
			parsePositiveInteger(client.helloPayload.subRosaID or client.helloPayload.subrosaID or client.helloPayload.subrosa_id)
		if phoneNumber and tonumber(player.phoneNumber) ~= phoneNumber then
			clearClientBinding(client)
			return nil
		end
		if subRosaID and tonumber(player.subRosaID) ~= subRosaID then
			clearClientBinding(client)
			return nil
		end
	end

	return player
end

local function refreshClientPlayerBinding(state, connection, client)
	if not state or not connection or not client then
		return nil
	end

	local player = validateBoundPlayer(connection, client)
	if player then
		return player
	end

	if client.hello ~= true then
		return nil
	end

	local reboundPlayer, _ = resolveClientPlayerFromHello(state, connection, client.helloPayload)
	if reboundPlayer and applyBoundPlayer(state, connection, client, reboundPlayer) then
		return reboundPlayer
	end

	return nil
end

local function isClientSyncing(client)
	if not client or client.hello ~= true then
		return false
	end

	if client.udpEventsReady ~= true then
		return true
	end

	if client.activeFileTransfer then
		return true
	end

	if client.activeBundleTransfer then
		return true
	end

	if type(client.pendingBundleRequests) == "table" and #client.pendingBundleRequests > 0 then
		return true
	end

	return type(client.pendingFileRequests) == "table" and #client.pendingFileRequests > 0
end

local function suppressPlayerTimeoutWhileSyncing(client)
	if not client or client.bound ~= true or client.player == nil then
		return
	end

	local playerConnection = client.player.connection
	if not playerConnection or not isClientSyncing(client) then
		return
	end

	playerConnection.timeoutTime = 0
end

disconnectOtherConnectionsForPlayer = function(state, player, exceptConnection)
	if not player then
		return
	end

	for connection, client in pairs(state.clients) do
		if connection ~= exceptConnection and client and client.player == player then
			resetClientSyncState(client)
			client.closeAfterFlush = true
		end
	end
end

local function nextSyncGeneration(state)
	local current = tonumber(state.syncGeneration) or 0
	current = current + 1
	state.syncGeneration = current
	return current
end

local function clearClientState(state, connection)
	local client = state.clients[connection]
	closeClientTransfer(client)
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

local function bundleMetadataList(state)
	local bundles = {}
	if type(state.syncBundles) ~= "table" then
		return bundles
	end

	for i = 1, #state.syncBundles do
		local bundle = state.syncBundles[i]
		bundles[#bundles + 1] = {
			id = bundle.id,
			kind = bundle.kind,
			size = bundle.size,
			archiveSha256 = bundle.archiveSha256,
			contentSha256 = bundle.contentSha256,
			files = bundle.files,
		}
	end

	return bundles
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

	if client.closeAfterFlush and #client.sendQueue == 0 and connection.isOpen then
		connection:close()
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

local function queueSyncBundle(state, connection, bundleID)
	local client = state.clients[connection]
	if not client or type(bundleID) ~= "string" or bundleID == "" then
		return
	end

	local bundle = state.syncBundlesById and state.syncBundlesById[bundleID] or nil
	if not bundle or type(bundle.archive) ~= "string" or bundle.archive == "" then
		enqueueFrame(state, connection, "ERROR_REPORT", {
			error = "invalid BUNDLE_REQ id",
			id = bundleID,
		})
		return
	end

	if client.activeBundleTransfer and client.activeBundleTransfer.id == bundleID then
		return
	end

	for _, queuedID in ipairs(client.pendingBundleRequests) do
		if queuedID == bundleID then
			return
		end
	end

	table.insert(client.pendingBundleRequests, bundleID)
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

local function startNextBundleTransfer(state, connection, client)
	if client.activeBundleTransfer or #client.pendingBundleRequests == 0 then
		return false
	end

	local bundleID = table.remove(client.pendingBundleRequests, 1)
	local bundle = state.syncBundlesById and state.syncBundlesById[bundleID] or nil
	if not bundle or type(bundle.archive) ~= "string" then
		enqueueFrame(state, connection, "ERROR_REPORT", {
			error = "bundle not found in sync index",
			id = bundleID,
		})
		return false
	end

	client.activeBundleTransfer = {
		id = bundleID,
		data = bundle.archive,
		offset = 1,
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

local function pumpBundleTransfer(state, connection)
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

		if not client.activeBundleTransfer and not startNextBundleTransfer(state, connection, client) then
			return
		end

		local transfer = client.activeBundleTransfer
		if not transfer then
			return
		end

		local chunk = transfer.data:sub(transfer.offset, transfer.offset + chunkSize - 1)
		if chunk ~= "" then
			local binaryFrame = encodeBinaryFrame(
				"BUNDLE_CHUNK",
				string.pack(">I2", #transfer.id) .. transfer.id .. chunk
			)
			if not binaryFrame or not enqueueBytes(state, connection, binaryFrame) then
				return
			end
			transfer.offset = transfer.offset + #chunk
			sentChunks = sentChunks + 1
		else
			client.activeBundleTransfer = nil
			if not enqueueFrame(state, connection, "BUNDLE_END", {
				id = transfer.id,
			}) then
				return
			end
		end
	end
end

local function handleClientEvent(state, connection, message)
	local eventHash = message and message.eventHash
	local msgId = message and message.msgId
	local args = message and message.args or { n = 0 }
	local registry = state.eventHandlersByHash and state.eventHandlersByHash[eventHash] or nil
	local eventName = registry and registry.name or udpEvents.formatEventHash(eventHash)
	if not registry or not registry.callbacks or #registry.callbacks == 0 then
		log.warn(
			"event rejected [NOTHING_HANDLED_EVENT_ON_SERVER]: hash=%s id=%s client=%s",
			tostring(eventName),
			tostring(msgId),
			shared.clientId(connection)
		)
		return {
			status = "nothing_handled",
			handled = 0,
			errors = 0,
			detail = "No server handlers registered for event",
			eventName = eventName,
			eventHash = eventHash,
		}
	end

	local handled = 0
	local errors = 0
	local detail = ""
	for _, fn in ipairs(registry.callbacks) do
		local ok, err = pcall(fn, connection, unpackFn(args, 1, args.n or 0))
		handled = handled + 1
		if not ok then
			errors = errors + 1
			detail = tostring(err)
			log.warn("src.onClientEvent callback failed (%s): %s", eventName, err)
		end
	end

	local status = errors == 0 and "processed" or "handler_error"
	return {
		status = status,
		handled = handled,
		errors = errors,
		detail = detail,
		eventName = eventName,
		eventHash = eventHash,
	}
end

local function queueReliableUdpEvent(state, connection, name, eventHash, argsBytes)
	local client = state.clients[connection]
	if not client or not connection.isOpen or not client.hello or not client.bound then
		return false
	end

	if type(name) ~= "string" or name == "" then
		return false
	end

	state.eventHashesByName = state.eventHashesByName or {}
	if not eventHash then
		eventHash = state.eventHashesByName[name]
		if not eventHash then
			eventHash = udpEvents.hashEventName(name)
			if not eventHash then
				return false
			end
			state.eventHashesByName[name] = eventHash
		end
	end

	if type(argsBytes) ~= "string" then
		local encoded, encodeErr
		if type(argsBytes) == "table" then
			local count = tonumber(argsBytes.n)
			if count == nil or count < 0 then
				count = #argsBytes
			end
			encoded, encodeErr = eventCodec.encodeArgs(unpackFn(argsBytes, 1, count))
		else
			encoded, encodeErr = eventCodec.encodeArgs()
		end
		if not encoded then
			log.warn("failed to encode UDP event payload (%s): %s", name, tostring(encodeErr))
			return false
		end
		argsBytes = encoded
	end

	local msgID = state.nextEventID
	local bytes, encodeErr = udpEvents.encodeReliableEvent(eventHash, msgID, argsBytes)
	if not bytes then
		log.warn("failed to encode UDP event (%s): %s", name, tostring(encodeErr))
		return false
	end
	if #bytes > state.config.maxEventBytes then
		log.warn("event too large; dropping (%s)", name)
		return false
	end

	state.nextEventID = state.nextEventID + 1
	if state.nextEventID > SERVER_EVENT_ID_MAX then
		state.nextEventID = SERVER_EVENT_ID_MIN
	end

	udpEvents.enqueue(client, bytes)

	client.pendingEvents[msgID] = {
		bytes = bytes,
		attempts = 1,
		nextRetryTick = state.tick + state.config.eventRetryBaseTicks,
		name = name,
		eventHash = eventHash,
		createdTick = state.tick,
		lastRetryTick = state.tick,
	}

	return true
end

local function queueReliableUdpResult(state, connection, name, msgId, eventHash, payloadBytes)
	local client = state.clients[connection]
	if not client or not connection.isOpen or not client.hello or not client.bound then
		return false
	end

	if type(name) ~= "string" or name == "" then
		return false
	end

	local normalizedMsgId = parseMsgId(msgId)
	if not normalizedMsgId then
		return false
	end

	state.eventHashesByName = state.eventHashesByName or {}
	if not eventHash then
		eventHash = state.eventHashesByName[name]
		if not eventHash then
			eventHash = udpEvents.hashEventName(name)
			if not eventHash then
				return false
			end
			state.eventHashesByName[name] = eventHash
		end
	end

	if type(payloadBytes) ~= "string" then
		return false
	end

	local bytes, encodeErr = udpEvents.encodeReliableResult(eventHash, normalizedMsgId, payloadBytes)
	if not bytes then
		log.warn("failed to encode UDP result (%s): %s", name, tostring(encodeErr))
		return false
	end
	if #bytes > state.config.maxEventBytes then
		log.warn("result too large; dropping (%s)", name)
		return false
	end

	udpEvents.enqueue(client, bytes)

	client.pendingResults = client.pendingResults or {}
	client.pendingResults[normalizedMsgId] = {
		bytes = bytes,
		attempts = 1,
		nextRetryTick = state.tick + state.config.eventRetryBaseTicks,
		name = name,
		eventHash = eventHash,
		createdTick = state.tick,
		lastRetryTick = state.tick,
	}

	return true
end

local function logLegacyTcpEventFrame(frameType)
	if loggedLegacyTcpEventFrame then
		return
	end

	loggedLegacyTcpEventFrame = true
	log.warn("ignoring legacy TCP event-lane frame (%s)", tostring(frameType))
end

local function handleReliableEventAckBatchPayload(state, connection, msgIds)
	local client = state.clients[connection]
	if client and type(msgIds) == "table" then
		ensureEventTrackingTables(client)
		for i = 1, #msgIds do
			local msgId = parseMsgId(msgIds[i])
			if msgId then
				local pending = client.pendingEvents[msgId]
				if pending then
					client.pendingEvents[msgId] = nil
					client.awaitingResults[msgId] = {
						name = pending.name,
						eventHash = pending.eventHash,
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
				elseif client.pendingResults[msgId] then
					client.pendingResults[msgId] = nil
					markEventRecentlyCompleted(state, client, msgId)
				elseif client.awaitingResults[msgId] then
					-- Duplicate ACK while waiting for processing result; ignore.
				elseif client.recentCompleted[msgId] then
					-- Late ACK for a message we've already finalized; ignore.
				else
					log.warn("received EVENT_ACK for unknown id=%s from %s", msgId, shared.clientId(connection))
				end
			end
		end
	end
end

local function handleReliableEventResultPayload(state, connection, message)
	local client = state.clients[connection]
	if not client then
		return
	end
	ensureEventTrackingTables(client)

	local msgId = parseMsgId(message and message.msgId)
	if not msgId then
		log.warn("received EVENT_RESULT with invalid msgId from %s", shared.clientId(connection))
		return
	end

	local args = message and message.args or { n = 0 }
	local tracked = client.awaitingResults[msgId]
	local result = {
		eventHash = message and message.eventHash,
		status = tostring(args[1] or ""),
		handled = tonumber(args[2]) or 0,
		errors = tonumber(args[3]) or 0,
		detail = tostring(args[4] or ""),
		args = args,
	}

	if not tracked then
		if client.pendingEvents[msgId] then
			client.earlyResults[msgId] = result
			return
		end
		if client.recentCompleted[msgId] then
			return
		end
		log.warn("received EVENT_RESULT for unknown id=%s from %s", msgId, shared.clientId(connection))
		return
	end

	client.awaitingResults[msgId] = nil
	client.earlyResults[msgId] = nil
	markEventRecentlyCompleted(state, client, msgId)
	logEventResult(state, connection, tracked.name, msgId, result)
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

local function queueItemTypeTextureFrame(state, connection, index, textureAssignment)
	local client = state.clients[connection]
	if not client or not connection.isOpen or not client.hello then
		return false
	end

	if type(textureAssignment) ~= "table" then
		return false
	end

	local payload = {
		index = index,
	}

	if textureAssignment.kind == "builtin" then
		payload.builtinTexture = textureAssignment.builtin
	elseif textureAssignment.kind == "file" then
		payload.texture = textureAssignment.file
	else
		return false
	end

	return enqueueFrame(state, connection, "ITEM_TYPE_TEXTURE", payload)
end

local function queueItemTypeFireSoundsFrame(state, connection, index, soundAssignment)
	local client = state.clients[connection]
	if not client or not connection.isOpen or not client.hello then
		return false
	end

	if type(soundAssignment) ~= "table" then
		return false
	end

	local payload = {
		index = index,
	}

	if soundAssignment.kind == "builtin" then
		payload.builtinFireSound = soundAssignment.builtin
	elseif soundAssignment.kind == "files" then
		payload.fireSounds = soundAssignment.files
	else
		return false
	end

	return enqueueFrame(state, connection, "ITEM_TYPE_FIRE_SOUNDS", payload)
end

local function queueHumanModelFrame(state, connection, index, assignment)
	local client = state.clients[connection]
	if not client or not connection.isOpen or not client.hello then
		return false
	end

	if type(assignment) ~= "table" then
		return false
	end

	local male = assignment.male
	local female = assignment.female
	if type(male) ~= "string" or male == "" or type(female) ~= "string" or female == "" then
		return false
	end

	return enqueueFrame(state, connection, "HUMAN_MODEL_DEF", {
		index = index,
		male = male,
		female = female,
	})
end

local function sendInitialCustomItemSync(state, connection)
	local buildSyncPayload = state.buildCustomItemTypesSyncPayload
	if type(buildSyncPayload) == "function" then
		local ok, payloadOrErr = pcall(buildSyncPayload, connection)
		if ok then
			local payload = payloadOrErr
			if type(payload) == "table" and type(payload.itemTypes) == "table" and #payload.itemTypes > 0 then
				queueItemTypesSyncFrame(state, connection, payload)

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

				local textureAssignments = state.itemTypeTextureAssignments
				if type(textureAssignments) == "table" then
					for idx, textureAssignment in pairs(textureAssignments) do
						queueItemTypeTextureFrame(state, connection, idx, textureAssignment)
					end
				end

				local fireSoundAssignments = state.itemTypeFireSoundAssignments
				if type(fireSoundAssignments) == "table" then
					for idx, soundAssignment in pairs(fireSoundAssignments) do
						queueItemTypeFireSoundsFrame(state, connection, idx, soundAssignment)
					end
				end
			end
		else
			log.warn("failed building custom item type sync payload: %s", tostring(payloadOrErr))
		end
	end

	local humanModelAssignments = state.humanModelAssignments
	if type(humanModelAssignments) == "table" then
		for idx, assignment in pairs(humanModelAssignments) do
			queueHumanModelFrame(state, connection, idx, assignment)
		end
	end
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
			protocol = 3,
		})
		return
	end

	if frameType == "HELLO" then
		local client = state.clients[connection]
		if not client then
			return
		end

		resetClientSyncState(client)
		client.hello = true
		client.helloPayload = payload
		client.generation = state.syncGeneration

		local player, bindErr = resolveClientPlayerFromHello(state, connection, payload)
		if player then
			applyBoundPlayer(state, connection, client, player)
		elseif bindErr == "invalid_hello_payload" or bindErr == "ambiguous_bind_claims" then
			log.warn("SRC bind rejected (%s): %s", shared.clientId(connection), tostring(bindErr))
			clearClientBinding(client)
			client.hello = false
			enqueueFrame(state, connection, "ERROR_REPORT", {
				code = "SRC_BIND_REJECTED",
				error = tostring(bindErr),
			})
			client.closeAfterFlush = true
			return
		else
			client.player = nil
			client.bound = false
		end

		enqueueFrame(state, connection, "HELLO_ACK", {
			protocol = 3,
			port = server.port,
			runtimeID = state.runtimeID,
			syncGeneration = state.syncGeneration,
			bindState = client.bound and "bound" or "pending",
		})

		if client.bound then
			sendInitialCustomItemSync(state, connection)
		end
		return
	end

		if frameType == "INDEX_REQ" then
			local client = state.clients[connection]
			if not client or not client.hello then
			enqueueFrame(state, connection, "ERROR_REPORT", {
				code = "SRC_BIND_REQUIRED",
				error = "HELLO required before INDEX_REQ",
			})
			return
		end

			if #state.syncBundles == 0 and #state.scripts == 0 and #state.assetFiles == 0 then
				shared.discoverSyncFiles(state)
			end
			enqueueFrame(state, connection, "INDEX_RES", {
				bundles = bundleMetadataList(state),
				loadedLevel = state.loadedLevel,
				persistentMode = state.persistentMode,
				runtimeID = state.runtimeID,
				syncGeneration = state.syncGeneration,
			})
		return
	end

		if frameType == "FILE_REQ" then
		local client = state.clients[connection]
		if not client or not client.hello then
			enqueueFrame(state, connection, "ERROR_REPORT", {
				code = "SRC_BIND_REQUIRED",
				error = "HELLO required before FILE_REQ",
			})
			return
		end

			queueSyncFile(state, connection, payload.path)
			return
		end

		if frameType == "BUNDLE_REQ" then
			local client = state.clients[connection]
			if not client or not client.hello then
				enqueueFrame(state, connection, "ERROR_REPORT", {
					code = "SRC_BIND_REQUIRED",
					error = "HELLO required before BUNDLE_REQ",
				})
				return
			end

			queueSyncBundle(state, connection, payload.id)
			return
		end

	if frameType == "EVENT" then
		logLegacyTcpEventFrame(frameType)
		return
	end

	if frameType == "EVENT_ACK" then
		logLegacyTcpEventFrame(frameType)
		return
	end

	if frameType == "EVENT_RESULT" then
		logLegacyTcpEventFrame(frameType)
		return
	end

	if frameType == "EVENTS_UDP_READY" then
		local client = state.clients[connection]
		if client and client.hello and client.bound then
			client.udpEventsReady = true
		end
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
				udpEvents.enqueue(client, pending.bytes)
			end
		end
	end

	for msgID, pending in pairs(client.pendingResults) do
		if state.tick >= pending.nextRetryTick then
			if pending.attempts >= maxAttempts then
				log.warn(
					"result delivery failed [SERVER_NEVER_RECEIVED_IT]: name=%s id=%s client=%s attempts=%s",
					pending.name or "?",
					msgID,
					shared.clientId(connection),
					pending.attempts
				)
				client.pendingResults[msgID] = nil
				markEventRecentlyCompleted(state, client, msgID)
			else
				pending.attempts = pending.attempts + 1
				pending.nextRetryTick = state.tick + baseTicks * (2 ^ (pending.attempts - 1))
				pending.lastRetryTick = state.tick
				udpEvents.enqueue(client, pending.bytes)
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
				pendingBundleRequests = {},
				activeFileTransfer = nil,
				activeBundleTransfer = nil,
				hello = false,
			helloPayload = nil,
			player = nil,
			bound = false,
			generation = 0,
			pendingEvents = {},
			pendingResults = {},
			awaitingResults = {},
			earlyResults = {},
			recentCompleted = {},
			closeAfterFlush = false,
		}
		udpEvents.resetClient(state.clients[connOrErr])

		log.info("TCP client connected: %s", shared.clientId(connOrErr))
	end
end

local function processClients(state)
	for connection, client in pairs(state.clients) do
		if connection.isOpen and client then
			if client.hello and client.bound then
				validateBoundPlayer(connection, client)
			elseif client.hello and not client.bound then
				local player, _ = resolveClientPlayerFromHello(state, connection, client.helloPayload)
				if player then
					if applyBoundPlayer(state, connection, client, player) then
						sendInitialCustomItemSync(state, connection)
					end
				end
			end

			suppressPlayerTimeoutWhileSyncing(client)
		end

		if connection.isOpen then
			processClientReads(state, connection)
			processPendingRetries(state, connection)
			pumpBundleTransfer(state, connection)
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

	state.eventHandlers = state.eventHandlers or {}
	state.eventHandlersByHash = state.eventHandlersByHash or {}
	state.eventHashesByName = state.eventHashesByName or {}

	local eventHash = state.eventHashesByName[name]
	if not eventHash then
		eventHash = udpEvents.hashEventName(name)
		if not eventHash then
			error("src.onClientEvent(name, fn): failed to hash event name")
		end
		state.eventHashesByName[name] = eventHash
	end

	local registry = state.eventHandlersByHash[eventHash]
	if registry and registry.name ~= name then
		log.warn(
			"event hash collision while registering src.onClientEvent (%s vs %s, hash=%s)",
			registry.name,
			name,
			udpEvents.formatEventHash(eventHash)
		)
		return false
	end

	local callbacks = state.eventHandlers[name]
	if registry then
		callbacks = registry.callbacks or callbacks
		registry.callbacks = callbacks
		state.eventHandlers[name] = callbacks
	else
		if not callbacks then
			callbacks = {}
			state.eventHandlers[name] = callbacks
		end
		registry = {
			name = name,
			callbacks = callbacks,
		}
		state.eventHandlersByHash[eventHash] = registry
	end

	table.insert(callbacks, fn)
	return true
end

function M.emitClientEvent(state, player, name, eventHash, argsBytes)
	local args = argsBytes
	if type(argsBytes) == "string" then
		args = eventCodec.decodeArgs(argsBytes)
		if not args then
			return false
		end
	end

	if player == nil then
		local sent = 0
		for connection, client in pairs(state.clients) do
			local ply = connection.player
			if connection.isOpen and client.hello and client.bound and (not ply or not ply.isBot) then
				if queueReliableUdpEvent(state, connection, name, eventHash, args) then
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

	return queueReliableUdpEvent(state, connection, name, eventHash, args)
end

function M.binary(bytes)
	return udpEvents.binary(bytes)
end

function M.syncClientItemTypes(state, player, payload)
	if type(payload) ~= "table" then
		return false
	end

	if player == nil then
		local sent = 0
		for connection, client in pairs(state.clients) do
			local ply = connection.player
			if connection.isOpen and client.hello and client.bound and (not ply or not ply.isBot) then
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
			if connection.isOpen and client.hello and client.bound and (not ply or not ply.isBot) then
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

function M.sendItemTypeTexture(state, player, index, textureAssignment)
	if player == nil then
		local sent = 0
		for connection, client in pairs(state.clients) do
			local ply = connection.player
			if connection.isOpen and client.hello and client.bound and (not ply or not ply.isBot) then
				if queueItemTypeTextureFrame(state, connection, index, textureAssignment) then
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

	return queueItemTypeTextureFrame(state, connection, index, textureAssignment)
end

function M.sendItemTypeTextureToConnection(state, connection, index, textureAssignment)
	return queueItemTypeTextureFrame(state, connection, index, textureAssignment)
end

function M.sendItemTypeFireSounds(state, player, index, soundAssignment)
	if player == nil then
		local sent = 0
		for connection, client in pairs(state.clients) do
			local ply = connection.player
			if connection.isOpen and client.hello and client.bound and (not ply or not ply.isBot) then
				if queueItemTypeFireSoundsFrame(state, connection, index, soundAssignment) then
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

	return queueItemTypeFireSoundsFrame(state, connection, index, soundAssignment)
end

function M.sendItemTypeFireSoundsToConnection(state, connection, index, soundAssignment)
	return queueItemTypeFireSoundsFrame(state, connection, index, soundAssignment)
end

function M.sendHumanModel(state, player, index, assignment)
	if player == nil then
		local sent = 0
		for connection, client in pairs(state.clients) do
			local ply = connection.player
			if connection.isOpen and client.hello and client.bound and (not ply or not ply.isBot) then
				if queueHumanModelFrame(state, connection, index, assignment) then
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

	return queueHumanModelFrame(state, connection, index, assignment)
end

function M.sendHumanModelToConnection(state, connection, index, assignment)
	return queueHumanModelFrame(state, connection, index, assignment)
end


function M.sendItemTypeModel(state, player, index, modelName)
	if player == nil then
		local sent = 0
		for connection, client in pairs(state.clients) do
			local ply = connection.player
			if connection.isOpen and client.hello and client.bound and (not ply or not ply.isBot) then
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
	local generation = nextSyncGeneration(state)
	for connection, client in pairs(state.clients) do
		if connection.isOpen and client.hello then
			resetClientSyncState(client)
			client.generation = generation
			enqueueFrame(state, connection, "REFRESH_NOTICE", {
				runtimeID = state.runtimeID,
				syncGeneration = generation,
			})
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

function M.onSendPacket(state, address, port)
	udpEvents.onSendPacket(state, address, port)
end

function M.onPostSendPacket(state)
	udpEvents.onPostSendPacket(state)
end

function M.onPostPacketReceive(state)
	local decoded = udpEvents.onPostPacketReceive()
	if not decoded or type(decoded.messages) ~= "table" then
		return
	end

	local connection, client = udpEvents.findClientForEndpoint(state, decoded.address, decoded.port)
	if not client then
		return
	end

	client.udpEndpointAddress = decoded.address
	client.udpEndpointPort = decoded.port

	for _, message in ipairs(decoded.messages) do
		if message.kind == 1 then
			if client.hello and client.bound then
				udpEvents.queueAck(client, message.msgId)
				local result = handleClientEvent(state, connection, message)
				local resultPayload, encodeErr = eventCodec.encodeArgs(
					result.status,
					result.handled,
					result.errors,
					result.detail or ""
				)
				if resultPayload then
					if not queueReliableUdpResult(
						state,
						connection,
						result.eventName or udpEvents.formatEventHash(message.eventHash),
						message.msgId,
						message.eventHash,
						resultPayload
					) then
						log.warn(
							"failed to queue result for client event (%s) id=%s client=%s",
							result.eventName or udpEvents.formatEventHash(message.eventHash),
							message.msgId,
							shared.clientId(connection)
						)
					end
				else
					log.warn(
						"failed to encode result payload for client event (%s): %s",
						result.eventName or udpEvents.formatEventHash(message.eventHash),
						tostring(encodeErr)
					)
				end
			end
		elseif message.kind == 2 then
			handleReliableEventAckBatchPayload(state, connection, message.msgIds)
		elseif message.kind == 3 then
			handleReliableEventResultPayload(state, connection, message)
		end
	end
end

function M.shutdown(state)
	closeAll(state)
end

function M.getPlayerConnection(state, player)
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
