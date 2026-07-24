local log = require("main.src.log")
local eventCodec = require("main.src.eventCodec")

local M = {}

local PACKET_READ_ADDRESS_ADDRESS = 0x39085C84
local PACKET_READ_PORT_ADDRESS = 0x39085C88
local RECV_PACKET_SIZE_ADDRESS = 0x39085C98
local RECV_PACKET_ADDRESS = 0x39085CA4
local MAX_DATAGRAM_SIZE = 1200
local DATAGRAM_HEADER_SIZE = 28
local MAX_BATCH_SIZE = MAX_DATAGRAM_SIZE - DATAGRAM_HEADER_SIZE
local MAX_RAW_MESSAGE_SIZE = MAX_BATCH_SIZE - 8
local GAME_MAGIC = "7DFP"
local MAGIC = "SRCU"
local DATAGRAM_VERSION = 1
local BATCH_VERSION = 1
local EMPTY_BATCH = string.pack(">BBI2", BATCH_VERSION, 0, 0)

local KIND_RELIABLE_EVENT = 1
local KIND_RELIABLE_ACK_BATCH = 2
local KIND_RELIABLE_RESULT = 3

local function get_base_address()
	local ok, value = pcall(memory.getBaseAddress)
	if not ok or type(value) ~= "number" or value == 0 then
		return nil
	end
	return math.floor(value)
end

local function read_int(offset)
	local base_address = get_base_address()
	if not base_address then
		return nil
	end
	local ok, value = pcall(memory.readInt, base_address + offset)
	if not ok or type(value) ~= "number" then
		return nil
	end
	return math.floor(value)
end

local function write_int(offset, value)
	local base_address = get_base_address()
	if not base_address then
		return false
	end
	return pcall(memory.writeInt, base_address + offset, math.floor(value))
end

local function read_bytes(offset, size)
	local base_address = get_base_address()
	if not base_address then
		return nil
	end
	local ok, value = pcall(memory.readBytes, base_address + offset, size)
	if not ok or type(value) ~= "string" then
		return nil
	end
	return value
end

local function write_bytes(offset, value)
	local base_address = get_base_address()
	if not base_address then
		return false
	end
	return pcall(memory.writeBytes, base_address + offset, value)
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

local function ipv4_from_integer(value)
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

local function build_datagram(token, batch)
	if type(token) ~= "string" or #token ~= 16 then
		return nil, "invalid UDP token"
	end
	if type(batch) ~= "string" or #batch < 4 or #batch > MAX_BATCH_SIZE then
		return nil, "UDP batch size out of range"
	end

	return string.pack(">c4c4BBc16I2", GAME_MAGIC, MAGIC, DATAGRAM_VERSION, 0, token, #batch) .. batch
end

local function parse_datagram(raw)
	if type(raw) ~= "string" or #raw < DATAGRAM_HEADER_SIZE or #raw > MAX_DATAGRAM_SIZE then
		return nil, nil, "UDP datagram size out of range"
	end

	local game_magic, magic, version, flags, token, batch_size, next_pos =
		string.unpack(">c4c4BBc16I2", raw)
	if game_magic ~= GAME_MAGIC or magic ~= MAGIC then
		return nil
	end
	if version ~= DATAGRAM_VERSION or flags ~= 0 then
		return nil, nil, "unsupported UDP datagram header"
	end
	if batch_size ~= #raw - DATAGRAM_HEADER_SIZE then
		return nil, nil, "UDP datagram payload size mismatch"
	end

	return token, raw:sub(next_pos)
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

	local maxCount = math.floor((maxBatchBytes - 12) / 4)
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
	client.udp_token = nil
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

function M.new_token()
	local native = rawget(_G, "srcIntegrationNative")
	if type(native) ~= "table" or type(native.randomToken) ~= "function" then
		return nil
	end

	local ok, token = pcall(native.randomToken)
	if not ok or type(token) ~= "string" or #token ~= 16 then
		return nil
	end
	return token
end

local function find_client_for_game_endpoint(state, address, port)
	if not state or type(state.clients) ~= "table" then
		return nil, nil
	end

	local normalizedAddress = tostring(address)
	local normalizedPort = normalizePort(port)
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

local function find_client_for_datagram(state, token, address)
	if type(state) ~= "table" or type(state.clients) ~= "table" then
		return nil, nil
	end

	for connection, client in pairs(state.clients) do
		if client
			and client.udp_token == token
			and tostring(connection.address) == tostring(address) then
			return connection, client
		end
	end
	return nil, nil
end

function M.onSendPacket(state, address, port)
	local _, client = find_client_for_game_endpoint(state, address, port)
	local native = rawget(_G, "srcIntegrationNative")
	if not client or client.udpEventsReady ~= true or type(native) ~= "table"
		or type(native.sendPacket) ~= "function" then
		return
	end

	local ackBytes, ackCount = buildAckBatchForPacket(client, MAX_BATCH_SIZE)
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

	local batch, count = buildBatch(queueToBatch, MAX_BATCH_SIZE)
	if type(batch) ~= "string" or count <= 0 then
		return
	end

	local datagram, encode_err = build_datagram(client.udp_token, batch)
	if not datagram then
		log.warn("failed to build standalone UDP datagram: %s", tostring(encode_err))
		return
	end

	local ok, sent_or_err = pcall(native.sendPacket, tostring(address), normalizePort(port), datagram)
	if not ok then
		log.warn("standalone UDP send failed: %s", tostring(sent_or_err))
		return
	end
	if sent_or_err ~= #datagram then
		return
	end

	if ackCount > 0 then
		consumeAckBatch(client, ackCount)
	end

	local event_count = math.max(0, count - (ackCount > 0 and 1 or 0))
	if event_count > 0 and type(client.udpSendQueue) == "table" then
		for _ = 1, event_count do
			table.remove(client.udpSendQueue, 1)
		end
	end
end

function M.onPostPacketReceive(state)
	local packet_size = read_int(RECV_PACKET_SIZE_ADDRESS)
	if type(packet_size) ~= "number" or packet_size < DATAGRAM_HEADER_SIZE
		or packet_size > MAX_DATAGRAM_SIZE then
		return nil
	end

	local raw = read_bytes(RECV_PACKET_ADDRESS, packet_size)
	if type(raw) ~= "string" or #raw ~= packet_size
		or raw:sub(1, 8) ~= GAME_MAGIC .. MAGIC then
		return nil
	end

	write_bytes(RECV_PACKET_ADDRESS, string.rep("\0", packet_size))
	write_int(RECV_PACKET_SIZE_ADDRESS, 0)

	local token, batch, datagram_err = parse_datagram(raw)
	if not token then
		log.warn("invalid standalone UDP datagram: %s", tostring(datagram_err))
		return nil
	end

	local address = ipv4_from_integer(read_int(PACKET_READ_ADDRESS_ADDRESS) or 0)
	local port = normalizePort(read_int(PACKET_READ_PORT_ADDRESS))
	local connection, client = find_client_for_datagram(state, token, address)
	if not client or not port then
		return nil
	end

	local messages, decode_err = decodeBatch(batch)
	if not messages then
		log.warn("invalid inbound SRC UDP batch: %s", tostring(decode_err))
		return nil
	end

	if #messages == 0 then
		local native = rawget(_G, "srcIntegrationNative")
		local reply = build_datagram(token, EMPTY_BATCH)
		if type(native) == "table" and type(native.sendPacket) == "function" then
			pcall(native.sendPacket, address, port, reply)
		end
	end

	return {
		connection = connection,
		client = client,
		messages = messages,
	}
end

return M
