local log = require("main.src.log")
local event_codec = require("main.src.event_codec")

local reliable_udp = require("main.src.reliable_udp")
local peers = setmetatable({}, { __mode = "k", })
local udp_events = {}

local MAX_GLOBAL_BUFFERED_BYTES = 16 * 1024 * 1024
-- floor per client, so a full global budget never starves a quiet one
local MIN_CLIENT_BUFFERED_BYTES = 128 * 1024
local peer_count = 0

-- inbound token buckets per client
local DATAGRAM_RATE, DATAGRAM_BURST = 240, 64
local EVENT_RATE, EVENT_BURST = 120, 32
local MAX_INBOX_DATAGRAMS = 128
local MAX_PENDING_MESSAGES = 256
local OVER_LIMIT_DISCONNECT_SECONDS = 5

local fallback_warn_limits = {}

-- keyed per client and fixed kind strings
function udp_events.warn_limited(client, kind, ...)
	local limits = fallback_warn_limits
	if client then
		limits = client.warn_limits
	end
	log.warn_limited(limits, kind, ...)
end

-- test hook: the global counter must equal this sum
function udp_events.buffered_bytes_sum()
	local total = 0
	for peer in pairs(peers) do
		total = total + peer.bytes
	end
	return total
end

function udp_events.buffered_bytes()
	return reliable_udp.total_bytes()
end

local function get_peer(client)
	if not client.udp_reliable then
		client.udp_reliable = reliable_udp.new()
		peers[client.udp_reliable] = true
		peer_count = peer_count + 1
	end
	return client.udp_reliable
end

-- bytes this client may still buffer: its share of the global budget, not below the floor
local function client_available_bytes(peer)
	local share = math.max(MIN_CLIENT_BUFFERED_BYTES, math.floor(MAX_GLOBAL_BUFFERED_BYTES / math.max(1, peer_count)))
	local global_room = MAX_GLOBAL_BUFFERED_BYTES - reliable_udp.total_bytes()
	local floor_room = MIN_CLIENT_BUFFERED_BYTES - peer.bytes
	return math.max(0, math.min(share - peer.bytes, math.max(global_room, floor_room)))
end

local MAX_DATAGRAM_SIZE = 1200
local MAX_FLUSH_DATAGRAMS = 8 -- At most 9,600 bytes per peer/native send.
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

function udp_events.reset_client(client)
	if not client then
		return
	end

	if client.udp_reliable then
		reliable_udp.release(client.udp_reliable)
		peers[client.udp_reliable] = nil
		peer_count = peer_count - 1
	end
	if client.udp_token_index and client.udp_token then
		client.udp_token_index[client.udp_token] = nil
	end
	client.udp_token_index = nil
	client.udp_inbox = nil
	client.udp_pending_messages = nil
	client.udp_over_since = nil
	client.udp_reliable = nil
	client.udp_send_queue = {}
	client.udp_pending_ack_order = {}
	client.udp_pending_ack_set = {}
	client.udp_pending_ack_start = 1
	client.udp_events_ready = false
	client.udp_token = nil
end

function udp_events.set_token(state, connection, client, token)
	if client.udp_token_index and client.udp_token then
		client.udp_token_index[client.udp_token] = nil
	end
	state.clients_by_token[token] = connection
	client.udp_token_index = state.clients_by_token
	client.udp_token = token
end

local function endpoint_key(address, port)
	local normalized_port = normalize_port(port)
	if not normalized_port then
		return nil
	end
	return tostring(address) .. ":" .. normalized_port
end

function udp_events.unbind_endpoint(client)
	if client and client.udp_endpoint_index and client.udp_endpoint_key then
		local index = client.udp_endpoint_index
		if index[client.udp_endpoint_key] == client.udp_endpoint_connection then
			index[client.udp_endpoint_key] = nil
		end
	end
	if client then
		client.udp_endpoint_index = nil
		client.udp_endpoint_key = nil
		client.udp_endpoint_connection = nil
	end
end

-- call once the game endpoint is bound to a player
function udp_events.bind_endpoint(state, connection, client)
	udp_events.unbind_endpoint(client)
	local key = endpoint_key(client.game_address, client.game_port)
	if not key then
		return
	end
	state.clients_by_endpoint[key] = connection
	client.udp_endpoint_index = state.clients_by_endpoint
	client.udp_endpoint_key = key
	client.udp_endpoint_connection = connection
end

-- drops a client's index entries and buffered bytes
function udp_events.remove_client(client)
	udp_events.unbind_endpoint(client)
	udp_events.reset_client(client)
end

function udp_events.binary(bytes)
	return event_codec.blob(bytes)
end

function udp_events.hash_event_name(name)
	return event_codec.hash_name(name)
end

function udp_events.format_event_hash(value)
	return event_codec.hex(value)
end

function udp_events.encode_reliable_event(event_hash, message_id, payload_bytes)
	return encode_event_like_message(KIND_RELIABLE_EVENT, event_hash, message_id, payload_bytes)
end

function udp_events.encode_reliable_result(event_hash, message_id, payload_bytes)
	return encode_result_message(event_hash, message_id, payload_bytes)
end

function udp_events.enqueue(client, encoded_message)
	if not client or type(encoded_message) ~= "string" or #encoded_message < 18 then
		return false
	end
	local kind, flags, _, id = string.unpack(">BBc8I4", encoded_message)
	if flags ~= 0 then
		return false
	end
	local peer = get_peer(client)
	if #encoded_message > client_available_bytes(peer) then
		return false
	end
	return reliable_udp.enqueue(peer, kind, id, encoded_message)
end

function udp_events.enqueue_latest(client, encoded_message)
	if not client or type(encoded_message) ~= "string" or #encoded_message < 18 then return false end
	local _, _, _, id = string.unpack(">BBc8I4", encoded_message)
	local peer = get_peer(client)
	if #encoded_message > client_available_bytes(peer) then return false end
	return reliable_udp.enqueue_latest(peer, id, encoded_message)
end

function udp_events.accept(client, message)
	return reliable_udp.accept(get_peer(client), message.kind, message.message_id)
end

function udp_events.tick(client, config)
	local peer = get_peer(client)
	if config then
		peer.retry_base = (config.eventRetryBaseTicks or 20) / 60
		peer.retry_attempts = config.eventRetryMaxAttempts or 5
	end
	reliable_udp.advance(peer, os.realClock(), client.udp_events_ready == true)
	return peer.error
end

function udp_events.new_token()
	local token = srcIntegrationNative.randomToken()
	if type(token) ~= "string" or #token ~= 32 then
		return nil
	end
	return token
end

local function find_client_for_game_endpoint(state, address, port)
	local index = state and state.clients_by_endpoint
	local key = index and endpoint_key(address, port)
	local connection = key and index[key]
	local client = connection and state.clients[connection]
	if client and client.bound then
		return connection, client
	end
	return nil, nil
end

-- game endpoint belongs to a bound client with an open TCP connection
function udp_events.has_bound_client(state, address, port)
	local connection = find_client_for_game_endpoint(state, address, port)
	return connection ~= nil and connection.is_open == true
end

local function find_client_for_datagram(state, token, address)
	local index = state and state.clients_by_token
	local connection = index and index[token]
	local client = connection and state.clients[connection]
	if client and client.udp_token == token and tostring(connection.address) == tostring(address) then
		return connection, client
	end
	return nil, nil
end

function udp_events.on_send_packet(state, address, port)
	local _, client = find_client_for_game_endpoint(state, address, port)
	if not client or client.udp_events_ready ~= true then
		return
	end
	udp_events.tick(client, state.config)
	for _ = 1, MAX_FLUSH_DATAGRAMS do
		local packet = reliable_udp.next(get_peer(client))
		if not packet then break end
		local datagram, encode_error = build_datagram(client.udp_token, packet)
		if not datagram then
			udp_events.warn_limited(client, "udp_build_failed", "failed to build UDP datagram: %s", tostring(encode_error))
			break
		end
		local sent = srcIntegrationNative.sendPacket(tostring(address), normalize_port(port), datagram)
		if sent ~= #datagram then
			udp_events.warn_limited(client, "udp_send_failed", "UDP send attempt failed: %s", tostring(sent))
			break
		end
	end
end

local malformed_datagram_warnings = {}

local function refill(client, now)
	local rate = client.udp_rate
	if not rate then
		client.udp_rate = { datagrams = DATAGRAM_BURST, events = EVENT_BURST, at = now, }
		return client.udp_rate
	end
	local elapsed = math.max(0, now - rate.at)
	rate.at = now
	rate.datagrams = math.min(DATAGRAM_BURST, rate.datagrams + elapsed * DATAGRAM_RATE)
	rate.events = math.min(EVENT_BURST, rate.events + elapsed * EVENT_RATE)
	return rate
end

-- returns the decoded entry or nil
local function process_datagram(state, connection, client, entry, rate)
	local token, address, port, batch = client.udp_token, entry.address, entry.port, entry.batch
	if not token then
		return nil -- The session was reset after this datagram was queued.
	end
	if batch == EMPTY_BATCH then
		local reply = build_datagram(token, EMPTY_BATCH)
		srcIntegrationNative.sendPacket(address, port, reply)
		return nil
	end
	if not client.bound or not client.udp_events_ready then
		return nil
	end
	udp_events.tick(client, state.config)
	local peer = get_peer(client)
	local messages = {}
	local pending = client.udp_pending_messages
	for _, delivery in ipairs(reliable_udp.receive(peer, batch, client_available_bytes(peer))) do
		local message, decode_error = decode_message(delivery.bytes)
		if not message or message.kind ~= delivery.kind or message.message_id ~= delivery.id
			or #delivery.bytes - 18 > math.min(262144, state.config.maxEventBytes) then
			peer.error = decode_error or "invalid reassembled UDP event"
			break
		end
		message.latest = delivery.latest
		if (pending and #pending > 0) or rate.events < 1 then
			pending = pending or {}
			pending[#pending + 1] = message
			client.udp_pending_messages = pending
			if #pending > MAX_PENDING_MESSAGES then
				peer.error = "UDP event backlog exceeded"
				break
			end
		else
			rate.events = rate.events - 1
			messages[#messages + 1] = message
		end
	end
	for _, receipt in ipairs(reliable_udp.take_receipts(peer)) do
		messages[#messages + 1] = { kind = 2, message_ids = { receipt.id, }, }
	end
	if peer.error then
		udp_events.warn_limited(client, "udp_transport_failed", "UDP transport failed: %s", peer.error)
		connection:close()
		return nil
	end
	return { connection = connection, client = client, messages = messages, }
end

-- defers work over the token buckets, disconnects sustained overload
local function service_client(state, connection, client, now, decoded)
	local rate = refill(client, now)
	local inbox = client.udp_inbox
	local pending = client.udp_pending_messages
	if pending and #pending > 0 then
		local released = {}
		while #pending > 0 and rate.events >= 1 do
			rate.events = rate.events - 1
			released[#released + 1] = table.remove(pending, 1)
		end
		if #released > 0 then
			decoded[#decoded + 1] = { connection = connection, client = client, messages = released, }
		end
	end
	while inbox and #inbox > 0 and rate.datagrams >= 1 and connection.is_open do
		rate.datagrams = rate.datagrams - 1
		local entry = table.remove(inbox, 1)
		local result = process_datagram(state, connection, client, entry, rate)
		if result then
			decoded[#decoded + 1] = result
		end
	end

	pending = client.udp_pending_messages
	local backlog = (inbox and #inbox > 0) or (pending and #pending > 0)
	if not backlog or not connection.is_open then
		client.udp_over_since = nil
		state.udp_backlog[connection] = nil
		return
	end
	state.udp_backlog[connection] = client
	client.udp_over_since = client.udp_over_since or now
	if now - client.udp_over_since >= OVER_LIMIT_DISCONNECT_SECONDS then
		udp_events.warn_limited(
			client,
			"udp_rate_limit",
			"disconnecting %s: inbound UDP over rate limit for %ds (datagrams %d/s, events %d/s)",
			tostring(connection.address),
			OVER_LIMIT_DISCONNECT_SECONDS,
			DATAGRAM_RATE,
			EVENT_RATE
		)
		connection:close()
	end
end

function udp_events.on_packet_receive(state)
	local ok, drained_or_err = pcall(srcIntegrationNative.drainSrcPackets)
	if not ok or type(drained_or_err) ~= "table" then
		log.warn("standalone UDP drain failed: %s", tostring(drained_or_err))
		return {}, false
	end

	local now = os.realClock()
	local touched = {}
	for _, packet in ipairs(drained_or_err.packets or {}) do
		repeat
			local token, batch, datagram_err = parse_datagram(packet.data)
			if not token then
				log.warn_limited(malformed_datagram_warnings, "invalid_datagram", "invalid standalone UDP datagram: %s", tostring(datagram_err))
				break
			end

			local address = tostring(packet.address)
			local port = normalize_port(packet.port)
			local connection, client = find_client_for_datagram(state, token, address)
			if not client or not port or not connection.is_open or not client.hello then
				break
			end
			if client.bound and (tostring(client.game_address) ~= address
				or tonumber(client.game_port) ~= port) then
				break
			end
			client.game_address = address
			client.game_port = port

			local inbox = client.udp_inbox
			if not inbox then
				inbox = {}
				client.udp_inbox = inbox
			end
			if #inbox >= MAX_INBOX_DATAGRAMS then
				-- reliable transfers retransmit, the overload check handles the sender
				udp_events.warn_limited(client, "udp_inbox_full", "dropping UDP datagram from %s: inbound queue full", address)
			else
				inbox[#inbox + 1] = { address = address, port = port, batch = batch, }
			end
			touched[connection] = client
		until true
	end

	local decoded = {}
	local serviced = {}
	for connection, client in pairs(state.udp_backlog) do
		serviced[connection] = true
		service_client(state, connection, client, now, decoded)
	end
	for connection, client in pairs(touched) do
		if not serviced[connection] then
			service_client(state, connection, client, now, decoded)
		end
	end

	local should_override = (tonumber(drained_or_err.drained) or 0) > 0
		and drained_or_err.vanillaPending ~= true
	return decoded, should_override
end

return udp_events
