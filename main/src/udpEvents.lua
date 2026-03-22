local log = require("main.src.log")
local eventCodec = require("main.src.eventCodec")

local M = {}

local PACKET_SIZE_ADDRESS = 0x39075C7C
local PACKET_ADDRESS = 0x39075C84
local PACKET_READ_ADDRESS_ADDRESS = 0x39085C84
local PACKET_READ_PORT_ADDRESS = 0x39085C88
local RECV_PACKET_SIZE_ADDRESS = 0x39085C98
local RECV_PACKET_ADDRESS = 0x39085CA4 -- inferred from recvPacketSize + 0x0C, matches client layout

local MAX_PACKET_SIZE = 0x10000
local TRAILER_SIZE = 8
local MAX_RAW_MESSAGE_SIZE = MAX_PACKET_SIZE - TRAILER_SIZE - 8
local MAGIC = "SRCE"
local BATCH_VERSION = 1

local KIND_RELIABLE_EVENT = 1
local KIND_RELIABLE_ACK_BATCH = 2
local KIND_RELIABLE_RESULT = 3

local function hasMemoryAPI()
	return type(memory) == "table"
		and type(memory.getBaseAddress) == "function"
		and type(memory.readBytes) == "function"
		and type(memory.writeBytes) == "function"
		and type(memory.readInt) == "function"
		and type(memory.writeInt) == "function"
end

local function getBaseAddress()
	local ok, value = pcall(memory.getBaseAddress)
	if not ok or type(value) ~= "number" or value == 0 then
		return nil
	end
	return math.floor(value)
end

local function resolveAddress(offset)
	local baseAddress = getBaseAddress()
	if not baseAddress then
		return nil
	end
	return baseAddress + offset
end

local function readInt(offset)
	local address = resolveAddress(offset)
	if not address then
		return nil
	end
	local ok, value = pcall(memory.readInt, address)
	if not ok or type(value) ~= "number" then
		return nil
	end
	return math.floor(value)
end

local function writeInt(offset, value)
	local address = resolveAddress(offset)
	if not address then
		return false
	end
	local ok = pcall(memory.writeInt, address, math.floor(value))
	return ok
end

local function readBytes(offset, size)
	local address = resolveAddress(offset)
	if not address then
		return nil
	end
	local ok, value = pcall(memory.readBytes, address, size)
	if not ok or type(value) ~= "string" then
		return nil
	end
	return value
end

local function writeBytes(offset, value)
	local address = resolveAddress(offset)
	if not address then
		return false
	end
	local ok = pcall(memory.writeBytes, address, value)
	return ok
end

local function normalizePort(port)
	local numberPort = tonumber(port)
	if not numberPort then
		return nil
	end
	numberPort = math.floor(numberPort)
	if numberPort < 0 or numberPort > 65535 then
		return nil
	end
	return numberPort
end

local function ipv4FromInteger(value)
	if type(value) ~= "number" then
		return nil
	end

	local unsigned = value
	if unsigned < 0 then
		unsigned = unsigned + 0x100000000
	end

	local d = unsigned % 256
	unsigned = math.floor(unsigned / 256)
	local c = unsigned % 256
	unsigned = math.floor(unsigned / 256)
	local b = unsigned % 256
	unsigned = math.floor(unsigned / 256)
	local a = unsigned % 256
	return string.format("%d.%d.%d.%d", a, b, c, d)
end

local function normalizeEventHash(value)
	if type(value) == "string" and #value == 8 then
		return value
	end

	if type(value) == "string" and value ~= "" then
		return eventCodec.hashName(value)
	end

	return nil
end

local function encodeEventLikeMessage(kind, eventHash, msgId, payloadBytes)
	local normalizedHash = normalizeEventHash(eventHash)
	if not normalizedHash then
		return nil, "invalid event hash"
	end

	payloadBytes = type(payloadBytes) == "string" and payloadBytes or ""
	local message = string.pack(">BBc8I4I4", kind, 0, normalizedHash, msgId or 0, #payloadBytes) .. payloadBytes
	if #message > MAX_RAW_MESSAGE_SIZE then
		return nil, "message too large"
	end
	return message
end

local function encodeAckBatchMessage(msgIds, startIndex, count)
	if type(msgIds) ~= "table" or type(startIndex) ~= "number" or type(count) ~= "number" or count <= 0 then
		return nil, "empty ack batch"
	end

	local parts = { string.pack(">BBI2", KIND_RELIABLE_ACK_BATCH, 0, count) }
	for i = 0, count - 1 do
		local msgId = msgIds[startIndex + i]
		if type(msgId) ~= "number" then
			return nil, "invalid ack id"
		end
		parts[#parts + 1] = string.pack(">I4", math.floor(msgId))
	end

	local message = table.concat(parts)
	if #message > MAX_RAW_MESSAGE_SIZE then
		return nil, "ack batch too large"
	end
	return message
end

local function encodeResultMessage(eventHash, msgId, payloadBytes)
	return encodeEventLikeMessage(KIND_RELIABLE_RESULT, eventHash, msgId, payloadBytes)
end

local function decodeEventLikeMessage(kind, raw)
	local headerSize = 2 + 8 + 4 + 4
	if type(raw) ~= "string" or #raw < headerSize then
		return nil, "message too short"
	end

	local _, _, eventHash, msgId, payloadSize, nextPos = string.unpack(">BBc8I4I4", raw)
	if payloadSize < 0 or nextPos + payloadSize - 1 > #raw then
		return nil, "message size mismatch"
	end

	local payloadBytes = raw:sub(nextPos, nextPos + payloadSize - 1)
	nextPos = nextPos + payloadSize
	local args, argErr = eventCodec.decodeArgs(payloadBytes)
	if not args then
		return nil, argErr
	end

	if nextPos ~= (#raw + 1) then
		return nil, "message size mismatch"
	end

	return {
		kind = kind,
		eventHash = eventHash,
		msgId = msgId,
		payloadBytes = payloadBytes,
		args = args,
	}
end

local function decodeAckBatchMessage(raw)
	if type(raw) ~= "string" or #raw < 4 then
		return nil, "message too short"
	end

	local _, _, count, nextPos = string.unpack(">BBI2", raw)
	local msgIds = {}
	for i = 1, count do
		if nextPos + 3 > #raw then
			return nil, "truncated ack batch"
		end
		local msgId
		msgId, nextPos = string.unpack(">I4", raw, nextPos)
		msgIds[i] = msgId
	end

	if nextPos <= #raw and nextPos - 1 ~= #raw then
		return nil, "message size mismatch"
	end

	return {
		kind = KIND_RELIABLE_ACK_BATCH,
		msgIds = msgIds,
	}
end

local function decodeMessage(raw)
	if type(raw) ~= "string" or #raw < 4 then
		return nil, "message too short"
	end

	local kind = raw:byte(1)
	if kind == KIND_RELIABLE_EVENT then
		return decodeEventLikeMessage(kind, raw)
	end
	if kind == KIND_RELIABLE_ACK_BATCH then
		return decodeAckBatchMessage(raw)
	end
	if kind == KIND_RELIABLE_RESULT then
		return decodeEventLikeMessage(kind, raw)
	end

	return nil, "unknown message kind"
end

local function buildBatch(sendQueue, maxBatchBytes)
	if type(sendQueue) ~= "table" or #sendQueue == 0 then
		return nil, 0
	end

	local parts = { string.pack(">BBI2", BATCH_VERSION, 0, 0) }
	local count = 0
	local used = 4
	for i = 1, #sendQueue do
		local message = sendQueue[i]
		if type(message) == "string" and #message > 0 then
			local required = 4 + #message
			if used + required > maxBatchBytes then
				break
			end
			parts[#parts + 1] = string.pack(">I4", #message)
			parts[#parts + 1] = message
			used = used + required
			count = count + 1
		end
	end

	if count == 0 then
		return nil, 0
	end

	parts[1] = string.pack(">BBI2", BATCH_VERSION, 0, count)
	return table.concat(parts), count
end

local function decodeBatch(batch)
	if type(batch) ~= "string" or #batch < 4 then
		return nil, "batch too short"
	end

	local version, _, count, nextPos = string.unpack(">BBI2", batch)
	if version ~= BATCH_VERSION then
		return nil, "unsupported batch version"
	end

	local messages = {}
	for _ = 1, count do
		if nextPos + 3 > #batch then
			return nil, "truncated batch entry"
		end

		local messageSize
		messageSize, nextPos = string.unpack(">I4", batch, nextPos)
		if messageSize <= 0 or nextPos + messageSize - 1 > #batch then
			return nil, "invalid batch entry size"
		end

		local rawMessage = batch:sub(nextPos, nextPos + messageSize - 1)
		nextPos = nextPos + messageSize
		local decoded, err = decodeMessage(rawMessage)
		if not decoded then
			return nil, err
		end
		messages[#messages + 1] = decoded
	end

	if nextPos <= #batch then
		return nil, "batch trailing bytes"
	end

	return messages
end

local function splitPacket(raw)
	if type(raw) ~= "string" or #raw < TRAILER_SIZE then
		return nil
	end

	if raw:sub(-4) ~= MAGIC then
		return nil
	end

	local batchSize = string.unpack(">I4", raw:sub(-8, -5))
	local vanillaSize = #raw - TRAILER_SIZE - batchSize
	if batchSize < 0 or vanillaSize < 0 then
		return nil, "invalid appended batch size"
	end

	return raw:sub(1, vanillaSize), raw:sub(vanillaSize + 1, #raw - TRAILER_SIZE)
end

local function getPendingAckWindow(client)
	local order = client and client.udpPendingAckOrder
	local startIndex = client and client.udpPendingAckStart or 1
	if type(order) ~= "table" or #order == 0 or startIndex > #order then
		return nil, 0, 0
	end

	return order, startIndex, #order - startIndex + 1
end

local function queueAck(client, msgId)
	if not client or type(msgId) ~= "number" then
		return false
	end

	local normalized = math.floor(msgId)
	if normalized <= 0 then
		return false
	end

	client.udpPendingAckOrder = client.udpPendingAckOrder or {}
	client.udpPendingAckSet = client.udpPendingAckSet or {}
	if client.udpPendingAckSet[normalized] then
		return true
	end

	client.udpPendingAckOrder[#client.udpPendingAckOrder + 1] = normalized
	client.udpPendingAckSet[normalized] = true
	return true
end

local function consumeAckBatch(client, count)
	if not client or type(count) ~= "number" or count <= 0 then
		return
	end

	local order = client.udpPendingAckOrder
	local set = client.udpPendingAckSet
	local startIndex = client.udpPendingAckStart or 1
	if type(order) ~= "table" or type(set) ~= "table" then
		return
	end

	local lastIndex = math.min(#order, startIndex + count - 1)
	for i = startIndex, lastIndex do
		local msgId = order[i]
		if msgId ~= nil then
			set[msgId] = nil
		end
	end

	startIndex = lastIndex + 1
	if startIndex > #order then
		client.udpPendingAckOrder = {}
		client.udpPendingAckSet = {}
		client.udpPendingAckStart = 1
	else
		client.udpPendingAckStart = startIndex
	end
end

local function buildAckBatchForPacket(client, maxBatchBytes)
	local order, startIndex, remaining = getPendingAckWindow(client)
	if not order or remaining <= 0 then
		return nil, 0
	end

	local maxCount = math.floor((maxBatchBytes - 8) / 4)
	if maxCount <= 0 then
		return nil, 0
	end

	local count = math.min(remaining, maxCount)
	return encodeAckBatchMessage(order, startIndex, count), count
end

function M.resetClient(client)
	if not client then
		return
	end

	client.udpSendQueue = {}
	client.udpPendingAckOrder = {}
	client.udpPendingAckSet = {}
	client.udpPendingAckStart = 1
	client.udpEventsReady = false
	client.udpEndpointAddress = nil
	client.udpEndpointPort = nil
end

function M.binary(bytes)
	return eventCodec.blob(bytes)
end

function M.hashEventName(name)
	return eventCodec.hashName(name)
end

function M.formatEventHash(value)
	return eventCodec.hex(value)
end

function M.encodeReliableEvent(eventHash, msgId, payloadBytes)
	return encodeEventLikeMessage(KIND_RELIABLE_EVENT, eventHash, msgId, payloadBytes)
end

function M.encodeReliableAckBatch(msgIds, startIndex, count)
	return encodeAckBatchMessage(msgIds, startIndex, count)
end

function M.encodeReliableResult(eventHash, msgId, payloadBytes)
	return encodeResultMessage(eventHash, msgId, payloadBytes)
end

function M.enqueue(client, encodedMessage)
	if not client or type(encodedMessage) ~= "string" or #encodedMessage == 0 then
		return false
	end

	client.udpSendQueue = client.udpSendQueue or {}
	client.udpSendQueue[#client.udpSendQueue + 1] = encodedMessage
	return true
end

function M.queueAck(client, msgId)
	return queueAck(client, msgId)
end

function M.findClientForEndpoint(state, address, port)
	if not state or type(state.clients) ~= "table" then
		return nil, nil
	end

	local normalizedAddress = tostring(address)
	local normalizedPort = normalizePort(port)
	for connection, client in pairs(state.clients) do
		if client and client.udpEndpointAddress == normalizedAddress and client.udpEndpointPort == normalizedPort then
			return connection, client
		end
	end

	for connection, client in pairs(state.clients) do
		local player = client and client.player or nil
		local playerConnection = player and player.connection or nil
		if playerConnection
			and tostring(playerConnection.address) == normalizedAddress
			and normalizePort(playerConnection.port) == normalizedPort then
			return connection, client
		end
	end

	return nil, nil
end

function M.onSendPacket(state, address, port)
	if not hasMemoryAPI() then
		return
	end

	local _, client = M.findClientForEndpoint(state, address, port)
	if not client or client.udpEventsReady ~= true then
		return
	end

	local packetSize = readInt(PACKET_SIZE_ADDRESS)
	if type(packetSize) ~= "number" or packetSize <= 0 or packetSize >= MAX_PACKET_SIZE then
		return
	end

	local maxBatchBytes = MAX_PACKET_SIZE - packetSize - TRAILER_SIZE
	if maxBatchBytes <= 8 then
		return
	end

	local ackBytes, ackCount = buildAckBatchForPacket(client, maxBatchBytes)
	local queueToBatch
	if type(ackBytes) == "string" and ackCount > 0 then
		queueToBatch = { ackBytes }
		local sendQueue = client.udpSendQueue
		if type(sendQueue) == "table" and #sendQueue > 0 then
			for i = 1, #sendQueue do
				queueToBatch[#queueToBatch + 1] = sendQueue[i]
			end
		end
	else
		queueToBatch = client.udpSendQueue
		ackCount = 0
	end

	local batch, count = buildBatch(queueToBatch, maxBatchBytes)
	if type(batch) ~= "string" or count <= 0 then
		return
	end

	local trailer = batch .. string.pack(">I4", #batch) .. MAGIC
	local originalTail = readBytes(PACKET_ADDRESS + packetSize, #trailer)
	if not originalTail or #originalTail ~= #trailer then
		originalTail = string.rep("\0", #trailer)
	end

	if not writeBytes(PACKET_ADDRESS + packetSize, trailer) then
		return
	end
	if not writeInt(PACKET_SIZE_ADDRESS, packetSize + #trailer) then
		writeBytes(PACKET_ADDRESS + packetSize, originalTail)
		return
	end

	client.udpEndpointAddress = tostring(address)
	client.udpEndpointPort = normalizePort(port)
	state.udpSendMutationStack = state.udpSendMutationStack or {}
	state.udpSendMutationStack[#state.udpSendMutationStack + 1] = {
		client = client,
		originalSize = packetSize,
		originalTail = originalTail,
		appendedSize = #trailer,
		ackCount = ackCount,
		eventCount = math.max(0, count - (ackCount > 0 and 1 or 0)),
	}
end

function M.onPostSendPacket(state)
	if not hasMemoryAPI() or not state or type(state.udpSendMutationStack) ~= "table" then
		return
	end

	local mutation = table.remove(state.udpSendMutationStack)
	if not mutation then
		return
	end

	writeBytes(PACKET_ADDRESS + mutation.originalSize, mutation.originalTail)
	writeInt(PACKET_SIZE_ADDRESS, mutation.originalSize)

	local client = mutation.client
	if client then
		if mutation.ackCount and mutation.ackCount > 0 then
			consumeAckBatch(client, mutation.ackCount)
		end

		if mutation.eventCount and mutation.eventCount > 0 and type(client.udpSendQueue) == "table" then
			for _ = 1, mutation.eventCount do
				table.remove(client.udpSendQueue, 1)
			end
		end
	end
end

function M.onPostPacketReceive()
	if not hasMemoryAPI() then
		return nil
	end

	local packetSize = readInt(RECV_PACKET_SIZE_ADDRESS)
	if type(packetSize) ~= "number" or packetSize <= TRAILER_SIZE or packetSize > MAX_PACKET_SIZE then
		return nil
	end

	local raw = readBytes(RECV_PACKET_ADDRESS, packetSize)
	if type(raw) ~= "string" or #raw ~= packetSize then
		return nil
	end

	local vanillaPacket, batchOrErr = splitPacket(raw)
	if vanillaPacket == nil then
		if batchOrErr then
			log.warn("invalid inbound SRC UDP trailer: %s", tostring(batchOrErr))
		end
		return nil
	end

	writeBytes(RECV_PACKET_ADDRESS + #vanillaPacket, string.rep("\0", packetSize - #vanillaPacket))
	writeInt(RECV_PACKET_SIZE_ADDRESS, #vanillaPacket)

	local messages, decodeErr = decodeBatch(batchOrErr)
	if not messages then
		log.warn("invalid inbound SRC UDP batch: %s", tostring(decodeErr))
		messages = {}
	end

	local address = ipv4FromInteger(readInt(PACKET_READ_ADDRESS_ADDRESS) or 0)
	local port = normalizePort(readInt(PACKET_READ_PORT_ADDRESS))
	return {
		address = address,
		port = port,
		messages = messages,
	}
end

return M
