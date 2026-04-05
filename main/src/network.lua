local json = require("main.json")

local log = require("main.src.log")
local shared = require("main.src.shared")
local eventCodec = require("main.src.eventCodec")
local udpEvents = require("main.src.udpEvents")

local M = {}
local BINARY_MAGIC = "SRCB"
local disconnectOtherConnectionsForPlayer
local loggedLegacyTcpEventFrame = false
local unpackFn = table.unpack or unpack

local function parse_positive_integer(value)
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

local function encode_binary_frame(frameType, payload)
	if type(frameType) ~= "string" or frameType == "" then
		return nil
	end

	if type(payload) ~= "string" then
		payload = ""
	end

	return string.pack(">c4I2I4", BINARY_MAGIC, #frameType, #payload) .. frameType .. payload
end

local function parse_msg_id(value)
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

local SERVER_EVENT_ID_MIN = 0x80000000
local SERVER_EVENT_ID_MAX = 0xFFFFFFFF

local function ensure_event_tracking_tables(client)
	client.awaitingResults = client.awaitingResults or {}
	client.earlyResults = client.earlyResults or {}
	client.recentCompleted = client.recentCompleted or {}
	client.pendingResults = client.pendingResults or {}
end

local function mark_event_recently_completed(state, client, msgId)
	local keepTicks = math.max(120, tonumber(state.config.eventProcessTimeoutTicks) or 180)
	client.recentCompleted[msgId] = state.tick + keepTicks
end

local function cleanup_recent_completions(state, client)
	for msgId, expiryTick in pairs(client.recentCompleted) do
		if state.tick >= expiryTick then
			client.recentCompleted[msgId] = nil
		end
	end
end

local function log_event_result(state, connection, name, msgId, result)
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

local function get_player_connection(state, player)
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

local function resolve_client_player_from_hello(_, connection, payload)
	if not connection then
		return nil, "missing_connection"
	end

	if type(payload) ~= "table" then
		return nil, "invalid_hello_payload"
	end

	local phoneNumber = parse_positive_integer(payload.phoneNumber or payload.phone)
	local subRosaID = parse_positive_integer(payload.subRosaID or payload.subrosaID or payload.subrosa_id)
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

local function apply_bound_player(state, connection, client, player)
	if not state or not connection or not client or not player then
		return false
	end

	disconnectOtherConnectionsForPlayer(state, player, connection)
	client.player = player
	client.bound = true
	client.closeAfterFlush = false
	return true
end

local function close_client_transfer(client)
	if client and client.activeFileTransfer and client.activeFileTransfer.file then
		pcall(function()
			client.activeFileTransfer.file:close()
		end)
	end
	if client then
		client.activeFileTransfer = nil
	end
end

local function reset_client_sync_state(client)
	if not client then
		return
	end

	close_client_transfer(client)
	client.pendingFileRequests = {}
	client.pendingEvents = {}
	client.pendingResults = {}
	client.awaitingResults = {}
	client.earlyResults = {}
	client.recentCompleted = {}
	client.sendQueue = {}
	client.sendOffset = 1
	udpEvents.resetClient(client)
end

local function clear_client_binding(client)
	if not client then
		return
	end

	reset_client_sync_state(client)
	client.player = nil
	client.bound = false
end

local function validate_bound_player(connection, client)
	if not connection or not client or not client.player then
		return nil
	end

	local player = client.player
	if player.isBot or not player.connection then
		clear_client_binding(client)
		return nil
	end

	if tostring(player.connection.address) ~= tostring(connection.address) then
		clear_client_binding(client)
		return nil
	end

	if client.helloPayload then
		local phoneNumber = parse_positive_integer(client.helloPayload.phoneNumber or client.helloPayload.phone)
		local subRosaID =
			parse_positive_integer(client.helloPayload.subRosaID or client.helloPayload.subrosaID or client.helloPayload.subrosa_id)
		if phoneNumber and tonumber(player.phoneNumber) ~= phoneNumber then
			clear_client_binding(client)
			return nil
		end
		if subRosaID and tonumber(player.subRosaID) ~= subRosaID then
			clear_client_binding(client)
			return nil
		end
	end

	return player
end

local function is_client_syncing(client)
	if not client or client.hello ~= true then
		return false
	end

	if client.udpEventsReady ~= true then
		return true
	end

	if client.activeFileTransfer then
		return true
	end

	return type(client.pendingFileRequests) == "table" and #client.pendingFileRequests > 0
end

local function suppress_player_timeout_while_syncing(client)
	if not client or client.bound ~= true or client.player == nil then
		return
	end

	local playerConnection = client.player.connection
	if not playerConnection or not is_client_syncing(client) then
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
			reset_client_sync_state(client)
			client.closeAfterFlush = true
		end
	end
end

local function next_sync_generation(state)
	local current = tonumber(state.syncGeneration) or 0
	current = current + 1
	state.syncGeneration = current
	return current
end

local function clear_client_state(state, connection)
	local client = state.clients[connection]
	close_client_transfer(client)
	state.clients[connection] = nil
end

local function enqueue_bytes(state, connection, bytes)
	local client = state.clients[connection]
	if not client or type(bytes) ~= "string" or #bytes == 0 then
		return false
	end

	table.insert(client.sendQueue, bytes)
	return true
end

local function enqueue_frame(state, connection, frameType, payload)
	local body = {
		type = frameType,
		payload = payload or {},
	}

	return enqueue_bytes(state, connection, json.encode(body) .. "\n")
end

local function flush_send_queue(state, connection)
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

local function queue_sync_file(state, connection, relPath)
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
		enqueue_frame(state, connection, "ERROR_REPORT", {
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

local function start_next_file_transfer(state, connection, client)
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
		enqueue_frame(state, connection, "ERROR_REPORT", {
			error = "path not found in sync index",
			path = relPath,
		})
		return false
	end

	local file = io.open(fullPath, "rb")
	if not file then
		enqueue_frame(state, connection, "ERROR_REPORT", {
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

local function pump_file_transfer(state, connection)
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

		if not client.activeFileTransfer and not start_next_file_transfer(state, connection, client) then
			return
		end

		local transfer = client.activeFileTransfer
		if not transfer then
			return
		end

		local okRead, chunkOrErr = pcall(transfer.file.read, transfer.file, chunkSize)
		if not okRead then
			enqueue_frame(state, connection, "ERROR_REPORT", {
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
			local binaryFrame = encode_binary_frame(
				"FILE_CHUNK",
				string.pack(">I2", #transfer.path) .. transfer.path .. chunkOrErr
			)
			if not binaryFrame or not enqueue_bytes(state, connection, binaryFrame) then
				return
			end
			sentChunks = sentChunks + 1
		else
			pcall(function()
				transfer.file:close()
			end)
			client.activeFileTransfer = nil
			if not enqueue_frame(state, connection, "FILE_END", {
				path = transfer.path,
			}) then
				return
			end
		end
	end
end

local function handle_client_event(state, connection, message)
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

local function queue_reliable_udp_event(state, connection, name, eventHash, argsBytes)
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

local function queue_reliable_udp_result(state, connection, name, msgId, eventHash, payloadBytes)
	local client = state.clients[connection]
	if not client or not connection.isOpen or not client.hello or not client.bound then
		return false
	end

	if type(name) ~= "string" or name == "" then
		return false
	end

	local normalizedMsgId = parse_msg_id(msgId)
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

local function log_legacy_tcp_event_frame(frameType)
	if loggedLegacyTcpEventFrame then
		return
	end

	loggedLegacyTcpEventFrame = true
	log.warn("ignoring legacy TCP event-lane frame (%s)", tostring(frameType))
end

local function handle_reliable_event_ack_batch_payload(state, connection, msgIds)
	local client = state.clients[connection]
	if client and type(msgIds) == "table" then
		ensure_event_tracking_tables(client)
		for i = 1, #msgIds do
			local msgId = parse_msg_id(msgIds[i])
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
						mark_event_recently_completed(state, client, msgId)
						log_event_result(state, connection, trackedName, msgId, early)
					end
				elseif client.pendingResults[msgId] then
					client.pendingResults[msgId] = nil
					mark_event_recently_completed(state, client, msgId)
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

local function handle_reliable_event_result_payload(state, connection, message)
	local client = state.clients[connection]
	if not client then
		return
	end
	ensure_event_tracking_tables(client)

	local msgId = parse_msg_id(message and message.msgId)
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
	mark_event_recently_completed(state, client, msgId)
	log_event_result(state, connection, tracked.name, msgId, result)
end

local function queue_item_types_sync_frame(state, connection, payload)
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

	local binaryFrame = encode_binary_frame("ITEM_TYPES_SYNC", table.concat(segments))
	if not binaryFrame then
		return false
	end

	return enqueue_bytes(state, connection, binaryFrame)
end

local function queue_item_type_model_frame(state, connection, index, modelName)
	local client = state.clients[connection]
	if not client or not connection.isOpen or not client.hello then
		return false
	end

	return enqueue_frame(state, connection, "ITEM_TYPE_MODEL", {
		index = index,
		model = modelName,
	})
end

local function queue_item_type_icon_frame(state, connection, index, iconPath)
	local client = state.clients[connection]
	if not client or not connection.isOpen or not client.hello then
		return false
	end

	return enqueue_frame(state, connection, "ITEM_TYPE_ICON", {
		index = index,
		icon = iconPath,
	})
end

local function queue_item_type_texture_frame(state, connection, index, textureAssignment)
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

	return enqueue_frame(state, connection, "ITEM_TYPE_TEXTURE", payload)
end

local function queue_item_type_fire_sounds_frame(state, connection, index, soundAssignment)
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

	return enqueue_frame(state, connection, "ITEM_TYPE_FIRE_SOUNDS", payload)
end

local function send_initial_custom_item_sync(state, connection)
	local buildSyncPayload = state.buildCustomItemTypesSyncPayload
	if type(buildSyncPayload) == "function" then
		local ok, payloadOrErr = pcall(buildSyncPayload, connection)
		if ok then
			local payload = payloadOrErr
			if type(payload) == "table" and type(payload.itemTypes) == "table" and #payload.itemTypes > 0 then
				queue_item_types_sync_frame(state, connection, payload)

				local modelAssignments = state.itemTypeModelAssignments
				if type(modelAssignments) == "table" then
					for idx, modelName in pairs(modelAssignments) do
						queue_item_type_model_frame(state, connection, idx, modelName)
					end
				end

				local iconAssignments = state.itemTypeIconAssignments
				if type(iconAssignments) == "table" then
					for idx, iconPath in pairs(iconAssignments) do
						queue_item_type_icon_frame(state, connection, idx, iconPath)
					end
				end

				local textureAssignments = state.itemTypeTextureAssignments
				if type(textureAssignments) == "table" then
					for idx, textureAssignment in pairs(textureAssignments) do
						queue_item_type_texture_frame(state, connection, idx, textureAssignment)
					end
				end

				local fireSoundAssignments = state.itemTypeFireSoundAssignments
				if type(fireSoundAssignments) == "table" then
					for idx, soundAssignment in pairs(fireSoundAssignments) do
						queue_item_type_fire_sounds_frame(state, connection, idx, soundAssignment)
					end
				end
			end
		else
			log.warn("failed building custom item type sync payload: %s", tostring(payloadOrErr))
		end
	end
end

local function handle_frame(state, connection, frame)
	if type(frame) ~= "table" then
		return
	end

	local frameType = frame.type
	local payload = frame.payload or {}
	if type(frameType) ~= "string" then
		return
	end

	if frameType == "SRC_PING" then
		enqueue_frame(state, connection, "SRC_PONG", {
			protocol = 1,
		})
		return
	end

	if frameType == "HELLO" then
		local client = state.clients[connection]
		if not client then
			return
		end

		reset_client_sync_state(client)
		client.hello = true
		client.helloPayload = payload
		client.generation = state.syncGeneration

		local player, bindErr = resolve_client_player_from_hello(state, connection, payload)
		if player then
			apply_bound_player(state, connection, client, player)
		elseif bindErr == "invalid_hello_payload" or bindErr == "ambiguous_bind_claims" then
			log.warn("SRC bind rejected (%s): %s", shared.clientId(connection), tostring(bindErr))
			clear_client_binding(client)
			client.hello = false
			enqueue_frame(state, connection, "ERROR_REPORT", {
				code = "SRC_BIND_REJECTED",
				error = tostring(bindErr),
			})
			client.closeAfterFlush = true
			return
		else
			client.player = nil
			client.bound = false
		end

		enqueue_frame(state, connection, "HELLO_ACK", {
			protocol = 1,
			port = server.port,
			runtimeID = state.runtimeID,
			syncGeneration = state.syncGeneration,
			bindState = client.bound and "bound" or "pending",
		})

		if client.bound then
			send_initial_custom_item_sync(state, connection)
		end
		return
	end

	if frameType == "INDEX_REQ" then
		local client = state.clients[connection]
		if not client or not client.hello then
			enqueue_frame(state, connection, "ERROR_REPORT", {
				code = "SRC_BIND_REQUIRED",
				error = "HELLO required before INDEX_REQ",
			})
			return
		end

		shared.discoverAssetFiles(state)
		shared.discoverPersistentMode(state)
		enqueue_frame(state, connection, "INDEX_RES", {
			files = state.scripts,
			assetFiles = state.assetFiles,
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
			enqueue_frame(state, connection, "ERROR_REPORT", {
				code = "SRC_BIND_REQUIRED",
				error = "HELLO required before FILE_REQ",
			})
			return
		end

		queue_sync_file(state, connection, payload.path)
		return
	end

	if frameType == "EVENT" then
		log_legacy_tcp_event_frame(frameType)
		return
	end

	if frameType == "EVENT_ACK" then
		log_legacy_tcp_event_frame(frameType)
		return
	end

	if frameType == "EVENT_RESULT" then
		log_legacy_tcp_event_frame(frameType)
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

local function process_buffered_frames(state, connection, client, frameBudget)
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
				handle_frame(state, connection, frame)
			else
				enqueue_frame(state, connection, "ERROR_REPORT", {
					error = "invalid JSON frame",
				})
			end
			processed = processed + 1
		end
	end
	return processed
end

local function process_client_reads(state, connection)
	local client = state.clients[connection]
	if not client or not connection.isOpen then
		return
	end

	local readSize = state.config.readSize
	local maxReadBytesPerTick = math.max(readSize, tonumber(state.config.maxReadBytesPerTick) or 262144)
	local maxFramesPerTick = 256
	local readBytesThisTick = 0
	local framesThisTick = process_buffered_frames(state, connection, client, maxFramesPerTick)

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
		framesThisTick = framesThisTick + process_buffered_frames(
			state,
			connection,
			client,
			maxFramesPerTick - framesThisTick
		)
	end
end

local function process_pending_retries(state, connection)
	local client = state.clients[connection]
	if not client then
		return
	end
	ensure_event_tracking_tables(client)
	cleanup_recent_completions(state, client)

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
				mark_event_recently_completed(state, client, msgID)
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
				mark_event_recently_completed(state, client, msgID)
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
			mark_event_recently_completed(state, client, msgID)
		end
	end
end

local function accept_connections(state)
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

local function process_clients(state)
	for connection, client in pairs(state.clients) do
		if connection.isOpen and client then
			if client.hello and client.bound then
				validate_bound_player(connection, client)
			elseif client.hello and not client.bound then
				local player, _ = resolve_client_player_from_hello(state, connection, client.helloPayload)
				if player then
					if apply_bound_player(state, connection, client, player) then
						send_initial_custom_item_sync(state, connection)
					end
				end
			end

			suppress_player_timeout_while_syncing(client)
		end

		if connection.isOpen then
			process_client_reads(state, connection)
			process_pending_retries(state, connection)
			pump_file_transfer(state, connection)
			flush_send_queue(state, connection)
		end

		if not connection.isOpen then
			log.info("TCP client disconnected: %s", shared.clientId(connection))
			clear_client_state(state, connection)
		end
	end
end

local function close_all(state)
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

local function ensure_tcp_server(state)
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
		close_all(state)
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
				if queue_reliable_udp_event(state, connection, name, eventHash, args) then
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

	local connection = get_player_connection(state, player)
	if not connection then
		return false
	end

	return queue_reliable_udp_event(state, connection, name, eventHash, args)
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
				if queue_item_types_sync_frame(state, connection, payload) then
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

	local connection = get_player_connection(state, player)
	if not connection then
		return false
	end

	return queue_item_types_sync_frame(state, connection, payload)
end

function M.syncClientItemTypesToConnection(state, connection, payload)
	if type(payload) ~= "table" then
		return false
	end

	return queue_item_types_sync_frame(state, connection, payload)
end

function M.sendItemTypeModelToConnection(state, connection, index, modelName)
	return queue_item_type_model_frame(state, connection, index, modelName)
end

function M.sendItemTypeIcon(state, player, index, iconPath)
	if player == nil then
		local sent = 0
		for connection, client in pairs(state.clients) do
			local ply = connection.player
			if connection.isOpen and client.hello and client.bound and (not ply or not ply.isBot) then
				if queue_item_type_icon_frame(state, connection, index, iconPath) then
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

	local connection = get_player_connection(state, player)
	if not connection then
		return false
	end

	return queue_item_type_icon_frame(state, connection, index, iconPath)
end

function M.sendItemTypeIconToConnection(state, connection, index, iconPath)
	return queue_item_type_icon_frame(state, connection, index, iconPath)
end

function M.sendItemTypeTexture(state, player, index, textureAssignment)
	if player == nil then
		local sent = 0
		for connection, client in pairs(state.clients) do
			local ply = connection.player
			if connection.isOpen and client.hello and client.bound and (not ply or not ply.isBot) then
				if queue_item_type_texture_frame(state, connection, index, textureAssignment) then
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

	local connection = get_player_connection(state, player)
	if not connection then
		return false
	end

	return queue_item_type_texture_frame(state, connection, index, textureAssignment)
end

function M.sendItemTypeTextureToConnection(state, connection, index, textureAssignment)
	return queue_item_type_texture_frame(state, connection, index, textureAssignment)
end

function M.sendItemTypeFireSounds(state, player, index, soundAssignment)
	if player == nil then
		local sent = 0
		for connection, client in pairs(state.clients) do
			local ply = connection.player
			if connection.isOpen and client.hello and client.bound and (not ply or not ply.isBot) then
				if queue_item_type_fire_sounds_frame(state, connection, index, soundAssignment) then
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

	local connection = get_player_connection(state, player)
	if not connection then
		return false
	end

	return queue_item_type_fire_sounds_frame(state, connection, index, soundAssignment)
end

function M.sendItemTypeFireSoundsToConnection(state, connection, index, soundAssignment)
	return queue_item_type_fire_sounds_frame(state, connection, index, soundAssignment)
end


function M.sendItemTypeModel(state, player, index, modelName)
	if player == nil then
		local sent = 0
		for connection, client in pairs(state.clients) do
			local ply = connection.player
			if connection.isOpen and client.hello and client.bound and (not ply or not ply.isBot) then
				if queue_item_type_model_frame(state, connection, index, modelName) then
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

	local connection = get_player_connection(state, player)
	if not connection then
		return false
	end

	return queue_item_type_model_frame(state, connection, index, modelName)
end

function M.refresh(state)
	local generation = next_sync_generation(state)
	for connection, client in pairs(state.clients) do
		if connection.isOpen and client.hello then
			reset_client_sync_state(client)
			client.generation = generation
			enqueue_frame(state, connection, "REFRESH_NOTICE", {
				runtimeID = state.runtimeID,
				syncGeneration = generation,
			})
		end
	end
end

function M.ensure_tcp_server(state)
	ensure_tcp_server(state)
end

function M.logicStep(state)
	ensure_tcp_server(state)
	accept_connections(state)
	process_clients(state)
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
				local result = handle_client_event(state, connection, message)
				local resultPayload, encodeErr = eventCodec.encodeArgs(
					result.status,
					result.handled,
					result.errors,
					result.detail or ""
				)
				if resultPayload then
					if not queue_reliable_udp_result(
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
			handle_reliable_event_ack_batch_payload(state, connection, message.msgIds)
		elseif message.kind == 3 then
			handle_reliable_event_result_payload(state, connection, message)
		end
	end
end

function M.shutdown(state)
	close_all(state)
end

function M.get_player_connection(player)
	return get_player_connection(state, player)
end

function M.getConnectionPlayer(state, connection)
	local client = state and state.clients and state.clients[connection] or nil
	if not client then
		return nil
	end

	return client.player or refreshClientPlayerBinding(state, connection, client)
end

return M
