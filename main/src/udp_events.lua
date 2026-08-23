local log = require("main.src.log")
local event_codec = require("main.src.event_codec")

local M = {}

local MAX_DATAGRAM_SIZE = 1200
local DATAGRAM_HEADER_SIZE = 44
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
	if #message > MAX_RAW_MESSAGE_SIZE then
		return nil, "message too large"
	end
	return message
end

local function encode_ack_batch_message(message_ids, start_index, count)
	if type(message_ids) ~= "table" or type(start_index) ~= "number" or type(count) ~= "number" or count <= 0 then
		return nil, "empty ack batch"
	end

	local parts = { string.pack(">BBI2", KIND_RELIABLE_ACK_BATCH, 0, count) }
	for i = 0, count - 1 do
		local message_id = message_ids[start_index + i]
		if type(message_id) ~= "number" then
			return nil, "invalid ack id"
		end
		parts[#parts + 1] = string.pack(">I4", math.floor(message_id))
	end

	local message = table.concat(parts)
	if #message > MAX_RAW_MESSAGE_SIZE then
		return nil, "ack batch too large"
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

	local _, _, event_hash, message_id, payload_size, next_position = string.unpack(">BBc8I4I4", raw)
	if payload_size < 0 or next_position + payload_size - 1 > #raw then
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

local function decode_ack_batch_message(raw)
	if type(raw) ~= "string" or #raw < 4 then
		return nil, "message too short"
	end

	local _, _, count, next_position = string.unpack(">BBI2", raw)
	local message_ids = {}
	for i = 1, count do
		if next_position + 3 > #raw then
			return nil, "truncated ack batch"
		end
		local message_id
		message_id, next_position = string.unpack(">I4", raw, next_position)
		message_ids[i] = message_id
	end

	if next_position <= #raw and next_position - 1 ~= #raw then
		return nil, "message size mismatch"
	end

	return {
		kind = KIND_RELIABLE_ACK_BATCH,
		message_ids = message_ids,
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
	if kind == KIND_RELIABLE_ACK_BATCH then
		return decode_ack_batch_message(raw)
	end
	if kind == KIND_RELIABLE_RESULT then
		return decode_event_like_message(kind, raw)
	end

	return nil, "unknown message kind"
end

local function build_batch(send_queue, maximum_batch_bytes)
	if type(send_queue) ~= "table" or #send_queue == 0 then
		return nil, 0
	end

	local parts = { string.pack(">BBI2", BATCH_VERSION, 0, 0) }
	local count = 0
	local used = 4
	for i = 1, #send_queue do
		local message = send_queue[i]
		if type(message) == "string" and #message > 0 then
			local required = 4 + #message
			if used + required > maximum_batch_bytes then
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

local function decode_batch(batch)
	if type(batch) ~= "string" or #batch < 4 then
		return nil, "batch too short"
	end

	local version, _, count, next_position = string.unpack(">BBI2", batch)
	if version ~= BATCH_VERSION then
		return nil, "unsupported batch version"
	end

	local messages = {}
	for _ = 1, count do
		if next_position + 3 > #batch then
			return nil, "truncated batch entry"
		end

		local message_size
		message_size, next_position = string.unpack(">I4", batch, next_position)
		if message_size <= 0 or next_position + message_size - 1 > #batch then
			return nil, "invalid batch entry size"
		end

		local raw_message = batch:sub(next_position, next_position + message_size - 1)
		next_position = next_position + message_size
		local decoded, err = decode_message(raw_message)
		if not decoded then
			return nil, err
		end
		messages[#messages + 1] = decoded
	end

	if next_position <= #batch then
		return nil, "batch trailing bytes"
	end

	return messages
end

local function get_pending_ack_window(client)
	local order = client and client.udp_pending_ack_order
	local start_index = client and client.udp_pending_ack_start or 1
	if type(order) ~= "table" or #order == 0 or start_index > #order then
		return nil, 0, 0
	end

	return order, start_index, #order - start_index + 1
end

local function queue_ack(client, message_id)
	if not client or type(message_id) ~= "number" then
		return false
	end

	local normalized = math.floor(message_id)
	if normalized <= 0 then
		return false
	end

	client.udp_pending_ack_order = client.udp_pending_ack_order or {}
	client.udp_pending_ack_set = client.udp_pending_ack_set or {}
	if client.udp_pending_ack_set[normalized] then
		return true
	end

	client.udp_pending_ack_order[#client.udp_pending_ack_order + 1] = normalized
	client.udp_pending_ack_set[normalized] = true
	return true
end

local function consume_ack_batch(client, count)
	if not client or type(count) ~= "number" or count <= 0 then
		return
	end

	local order = client.udp_pending_ack_order
	local set = client.udp_pending_ack_set
	local start_index = client.udp_pending_ack_start or 1
	if type(order) ~= "table" or type(set) ~= "table" then
		return
	end

	local last_index = math.min(#order, start_index + count - 1)
	for i = start_index, last_index do
		local message_id = order[i]
		if message_id ~= nil then
			set[message_id] = nil
		end
	end

	start_index = last_index + 1
	if start_index > #order then
		client.udp_pending_ack_order = {}
		client.udp_pending_ack_set = {}
		client.udp_pending_ack_start = 1
	else
		client.udp_pending_ack_start = start_index
	end
end

local function build_ack_batch_for_packet(client, maximum_batch_bytes)
	local order, start_index, remaining = get_pending_ack_window(client)
	if not order or remaining <= 0 then
		return nil, 0
	end

	local maximum_count = math.floor((maximum_batch_bytes - 12) / 4)
	if maximum_count <= 0 then
		return nil, 0
	end

	local count = math.min(remaining, maximum_count)
	return encode_ack_batch_message(order, start_index, count), count
end

function M.reset_client(client)
	if not client then
		return
	end

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

function M.encode_reliable_ack_batch(message_ids, start_index, count)
	return encode_ack_batch_message(message_ids, start_index, count)
end

function M.encode_reliable_result(event_hash, message_id, payload_bytes)
	return encode_result_message(event_hash, message_id, payload_bytes)
end

function M.enqueue(client, encoded_message)
	if not client or type(encoded_message) ~= "string" or #encoded_message == 0 then
		return false
	end

	client.udp_send_queue = client.udp_send_queue or {}
	client.udp_send_queue[#client.udp_send_queue + 1] = encoded_message
	return true
end

function M.queue_ack(client, message_id)
	return queue_ack(client, message_id)
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

	local ack_bytes, ack_count = build_ack_batch_for_packet(client, MAX_BATCH_SIZE)
	local queue_to_batch
	if type(ack_bytes) == "string" and ack_count > 0 then
		queue_to_batch = { ack_bytes }
		local send_queue = client.udp_send_queue
		if type(send_queue) == "table" and #send_queue > 0 then
			for i = 1, #send_queue do
				queue_to_batch[#queue_to_batch + 1] = send_queue[i]
			end
		end
	else
		queue_to_batch = client.udp_send_queue
		ack_count = 0
	end

	local batch, count = build_batch(queue_to_batch, MAX_BATCH_SIZE)
	if type(batch) ~= "string" or count <= 0 then
		return
	end

	local datagram, encode_err = build_datagram(client.udp_token, batch)
	if not datagram then
		log.warn("failed to build standalone UDP datagram: %s", tostring(encode_err))
		return
	end

	local ok, sent_or_err = pcall(native.sendPacket, tostring(address), normalize_port(port), datagram)
	if not ok then
		log.warn("standalone UDP send failed: %s", tostring(sent_or_err))
		return
	end
	if sent_or_err ~= #datagram then
		return
	end

	if ack_count > 0 then
		consume_ack_batch(client, ack_count)
	end

	local event_count = math.max(0, count - (ack_count > 0 and 1 or 0))
	if event_count > 0 and type(client.udp_send_queue) == "table" then
		for _ = 1, event_count do
			table.remove(client.udp_send_queue, 1)
		end
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
			if not client or not port then
				break
			end
			client.game_address = address
			client.game_port = port

			local messages, decode_err = decode_batch(batch)
			if not messages then
				log.warn("invalid inbound SRC UDP batch: %s", tostring(decode_err))
				break
			end

			if #messages == 0 then
				local reply = build_datagram(token, EMPTY_BATCH)
				if type(native.sendPacket) == "function" then
					pcall(native.sendPacket, address, port, reply)
				end
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
