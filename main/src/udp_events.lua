local log = require("main.src.log")
local event_codec = require("main.src.event_codec")

local reliable_udp = require("main.src.reliable_udp")
local peers = setmetatable({}, { __mode = "k", })
local M = {}

local function buffered_bytes()
	local total = 0
	for peer in pairs(peers) do
		total = total + peer.bytes
	end
	return total
end

local function get_peer(client)
	if not client.udp_reliable then
		client.udp_reliable = reliable_udp.new()
		peers[client.udp_reliable] = true
	end
	return client.udp_reliable
end

local MAX_DATAGRAM_SIZE = 1200
local DATAGRAM_HEADER_SIZE = 44
local MAX_BATCH_SIZE = MAX_DATAGRAM_SIZE - DATAGRAM_HEADER_SIZE
local GAME_MAGIC = "7DFP"
local MAGIC = "SRCU"
local DATAGRAM_VERSION = 2
local BATCH_VERSION = 1
local EMPTY_BATCH = string.pack(">BBI2", BATCH_VERSION, 0, 0)

local KIND_RELIABLE_EVENT = 1
local KIND_RELIABLE_RESULT = 3

local function normalize_port(port)
	local number_port = tonumber(port)
	if not number_port then
		return nil
	end
	number_port = math.floor(number_port)
	if number_port < 0 or number_port > 65535 then
		return nil
	end
	return number_port
end

local function build_datagram(token, batch)
	if type(token) ~= "string" or #token ~= 32 then
		return nil, "invalid UDP token"
	end
	if type(batch) ~= "string" or #batch < 4 or #batch > MAX_BATCH_SIZE then
		return nil, "UDP batch size out of range"
	end

	return string.pack(">c4c4BBc32I2", GAME_MAGIC, MAGIC, DATAGRAM_VERSION, 0, token, #batch) .. batch
end

local function parse_datagram(raw)
	if type(raw) ~= "string" or #raw < DATAGRAM_HEADER_SIZE or #raw > MAX_DATAGRAM_SIZE then
		return nil, nil, "UDP datagram size out of range"
	end

	local game_magic, magic, version, flags, token, batch_size, next_pos =
		string.unpack(">c4c4BBc32I2", raw)
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

local function normalize_event_hash(value)
	if type(value) == "string" and #value == 8 then
		return value
	end

	if type(value) == "string" and value ~= "" then
		return event_codec.hash_name(value)
	end

	return nil
end

local function encode_event_like_message(kind, event_hash, message_id, payload_bytes)
	local normalized_hash = normalize_event_hash(event_hash)
	if not normalized_hash then
		return nil, "invalid event hash"
	end

	payload_bytes = type(payload_bytes) == "string" and payload_bytes or ""
	local message = string.pack(">BBc8I4I4", kind, 0, normalized_hash, message_id or 0, #payload_bytes) .. payload_bytes
	if #payload_bytes > 262144 then
		return nil, "message too large"
	end
	return message
end

local function encode_result_message(event_hash, message_id, payload_bytes)
	return encode_event_like_message(KIND_RELIABLE_RESULT, event_hash, message_id, payload_bytes)
end

local function decode_event_like_message(kind, raw)
	local header_size = 2 + 8 + 4 + 4
	if type(raw) ~= "string" or #raw < header_size then
		return nil, "message too short"
	end

	local _, flags, event_hash, message_id, payload_size, next_position = string.unpack(">BBc8I4I4", raw)
	if flags ~= 0 or message_id == 0 or payload_size > 262144 or next_position + payload_size - 1 ~= #raw then
		return nil, "message size mismatch"
	end

	local payload_bytes = raw:sub(next_position, next_position + payload_size - 1)
	next_position = next_position + payload_size
	local args, argument_error = event_codec.decode_args(payload_bytes)
	if not args then
		return nil, argument_error
	end

	if next_position ~= (#raw + 1) then
		return nil, "message size mismatch"
	end

	return {
		kind = kind,
		event_hash = event_hash,
		message_id = message_id,
		payload_bytes = payload_bytes,
		args = args,
	}
end

local function decode_message(raw)
	if type(raw) ~= "string" or #raw < 4 then
		return nil, "message too short"
	end

	local kind = raw:byte(1)
	if kind == KIND_RELIABLE_EVENT then
		return decode_event_like_message(kind, raw)
	end
	if kind == KIND_RELIABLE_RESULT then
		return decode_event_like_message(kind, raw)
	end

	return nil, "unknown message kind"
end

function M.reset_client(client)
	if not client then
		return
	end

	if client.udp_reliable then
		peers[client.udp_reliable] = nil
	end
	client.udp_reliable = nil
	client.udp_send_queue = {}
	client.udp_pending_ack_order = {}
	client.udp_pending_ack_set = {}
	client.udp_pending_ack_start = 1
	client.udp_events_ready = false
	client.udp_token = nil
end

function M.binary(bytes)
	return event_codec.blob(bytes)
end

function M.hash_event_name(name)
	return event_codec.hash_name(name)
end

function M.format_event_hash(value)
	return event_codec.hex(value)
end

function M.encode_reliable_event(event_hash, message_id, payload_bytes)
	return encode_event_like_message(KIND_RELIABLE_EVENT, event_hash, message_id, payload_bytes)
end

function M.encode_reliable_result(event_hash, message_id, payload_bytes)
	return encode_result_message(event_hash, message_id, payload_bytes)
end

function M.enqueue(client, encoded_message)
	if not client or type(encoded_message) ~= "string" or #encoded_message < 18 then
		return false
	end
	local kind, flags, _, id = string.unpack(">BBc8I4", encoded_message)
	if flags ~= 0 or buffered_bytes() + #encoded_message > 16 * 1024 * 1024 then
		return false
	end
	return reliable_udp.enqueue(get_peer(client), kind, id, encoded_message)
end

function M.accept(client, message)
	return reliable_udp.accept(get_peer(client), message.kind, message.message_id)
end

function M.tick(client, config)
	local peer = get_peer(client)
	if config then
		peer.retry_base = (config.eventRetryBaseTicks or 20) / 60
		peer.retry_attempts = config.eventRetryMaxAttempts or 5
	end
	reliable_udp.advance(peer, os.realClock(), client.udp_events_ready == true)
	return peer.error
end

function M.new_token()
	local native = rawget(_G, "srcIntegrationNative")
	if type(native) ~= "table" or type(native.randomToken) ~= "function" then
		return nil
	end

	local ok, token = pcall(native.randomToken)
	if not ok or type(token) ~= "string" or #token ~= 32 then
		return nil
	end
	return token
end

local function find_client_for_game_endpoint(state, address, port)
	if not state or type(state.clients) ~= "table" then
		return nil, nil
	end

	local normalized_address = tostring(address)
	local normalized_port = normalize_port(port)
	for connection, client in pairs(state.clients) do
		local player = client and client.player or nil
		local player_connection = player and player.connection or nil
		if player_connection
			and tostring(player_connection.address) == normalized_address
			and normalize_port(player_connection.port) == normalized_port then
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
			-- and tostring(connection.address) == tostring(address)
		then
			return connection, client
		end
	end
	return nil, nil
end

function M.on_send_packet(state, address, port)
	local _, client = find_client_for_game_endpoint(state, address, port)
	local native = rawget(_G, "srcIntegrationNative")
	if not client or client.udp_events_ready ~= true or type(native) ~= "table"
		or type(native.sendPacket) ~= "function" then
			return
		end
	M.tick(client, state.config)
	local packet = reliable_udp.next(get_peer(client))
	if not packet then
		return
	end
	local datagram, encode_error = build_datagram(client.udp_token, packet)
	if not datagram then
		log.warn("failed to build UDP datagram: %s", tostring(encode_error))
		return
	end
	local ok, sent = pcall(native.sendPacket, tostring(address), normalize_port(port), datagram)
	if not ok or sent ~= #datagram then
		log.warn("UDP send attempt failed: %s", tostring(sent))
	end
end

function M.on_packet_receive(state)
	local native = rawget(_G, "srcIntegrationNative")
	if type(native) ~= "table" or type(native.drainSrcPackets) ~= "function" then
		return {}, false
	end

	local ok, drained_or_err = pcall(native.drainSrcPackets)
	if not ok or type(drained_or_err) ~= "table" then
		log.warn("standalone UDP drain failed: %s", tostring(drained_or_err))
		return {}, false
	end

	local decoded = {}
	for _, packet in ipairs(drained_or_err.packets or {}) do
		repeat
			local token, batch, datagram_err = parse_datagram(packet.data)
			if not token then
				log.warn("invalid standalone UDP datagram: %s", tostring(datagram_err))
				break
			end

			local address = tostring(packet.address)
			local port = normalize_port(packet.port)
			local connection, client = find_client_for_datagram(state, token, address)
			if not client or not port or not connection.is_open or not client.hello then
				break
			end
			client.game_address = address
			client.game_port = port

			if batch == EMPTY_BATCH then
				local reply = build_datagram(token, EMPTY_BATCH)
				if type(native.sendPacket) == "function" then
					pcall(native.sendPacket, address, port, reply)
				end
				break
			end
			if not client.bound or not client.udp_events_ready then
				break
			end
			M.tick(client, state.config)
			local peer = get_peer(client)
			local messages = {}
			for _, delivery in ipairs(reliable_udp.receive(peer, batch, math.max(0, 16 * 1024 * 1024 - buffered_bytes()))) do
				local message, decode_error = decode_message(delivery.bytes)
				if not message or message.kind ~= delivery.kind or message.message_id ~= delivery.id
					or #delivery.bytes - 18 > math.min(262144, state.config.maxEventBytes) then
					peer.error = decode_error or "invalid reassembled UDP event"
					break
				end
				messages[#messages + 1] = message
			end
			for _, receipt in ipairs(reliable_udp.take_receipts(peer)) do
				messages[#messages + 1] = { kind = 2, message_ids = { receipt.id, }, }
			end
			if peer.error then
				log.warn("UDP transport failed: %s", peer.error)
				connection:close()
				break
			end

			decoded[#decoded + 1] = {
				connection = connection,
				client = client,
				messages = messages,
			}
		until true
	end

	local should_override = (tonumber(drained_or_err.drained) or 0) > 0
		and drained_or_err.vanillaPending ~= true
	return decoded, should_override
end

return M
