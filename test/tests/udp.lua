local event_codec = require("main.src.event_codec")
local network = require("main.src.network")
local udp_events = require("main.src.udp_events")

local function read_file(path)
	local file = io.open(path, "rb")
	if not file then
		return nil
	end
	local bytes = file:read("*all")
	file:close()
	return bytes
end

local function write_file(path, bytes)
	local file = assert(io.open(path, "wb"))
	file:write(bytes)
	file:close()
end

return function(state, src)
	local connection = {
		is_open = true,
		address = "127.0.0.1",
		port = 27071,
	}
	function connection:close()
		self.is_open = false
	end
	function connection:discard_pending_sends()
	end
	function connection:receive()
		return nil
	end
	function connection:send(bytes)
		return #bytes
	end
	function connection:take_send_stats()
		return nil
	end

	local token = assert(udp_events.new_token())
	local client = {
		receive_buffer = "",
		send_queue = {},
		send_offset = 1,
		pending_file_requests = {},
		pending_bundle_requests = {},
		pending_events = {},
		pending_results = {},
		awaiting_results = {},
		early_results = {},
		recent_completed = {},
		hello = true,
		hello_payload = nil,
		bound = true,
		udp_events_ready = true,
		udp_token = token,
		udp_send_queue = {},
		udp_pending_ack_order = {},
		udp_pending_ack_set = {},
		udp_pending_ack_start = 1,
		last_heartbeat_at = os.realClock(),
		sync_state = "ready",
		player = {
			isBot = false,
			connection = {
				address = "127.0.0.1",
				port = 27071,
				timeoutTime = 0,
			},
		},
	}
	state.clients[connection] = client

	local reset_client = {
		udp_token = token,
	}
	udp_events.reset_client(reset_client)
	assert(reset_client.udp_token == nil)

	local pending_events = client.pending_events
	local pending_results = client.pending_results
	local awaiting_results = client.awaiting_results
	local early_results = client.early_results
	local recent_completed = client.recent_completed
	local udp_send_queue = client.udp_send_queue
	local udp_pending_ack_order = client.udp_pending_ack_order
	local udp_pending_ack_set = client.udp_pending_ack_set
	network.refresh(state)
	assert(client.pending_events == pending_events)
	assert(client.pending_results == pending_results)
	assert(client.awaiting_results == awaiting_results)
	assert(client.early_results == early_results)
	assert(client.recent_completed == recent_completed)
	assert(client.udp_send_queue == udp_send_queue)
	assert(client.udp_pending_ack_order == udp_pending_ack_order)
	assert(client.udp_pending_ack_set == udp_pending_ack_set)
	assert(client.udp_token == token)
	assert(not client.udp_events_ready)
	client.udp_events_ready = true

	local handled = 0
	assert(src.onClientEvent("test.loopback", function(_, value)
		assert(value == "payload")
		handled = handled + 1
		return "processed"
	end))

	local event_hash = assert(udp_events.hash_event_name("test.loopback"))
	local args = assert(event_codec.encode_args("payload"))
	local message = assert(udp_events.encode_reliable_event(event_hash, 7, args))
	local batch = string.pack(">BBI2I4", 1, 0, 1, #message) .. message
	local datagram = string.pack(">c4c4BBc32I2", "7DFP", "SRCU", 1, 0, token, #batch) .. batch

	local attempts = 0
	local function wait_for_probe()
		attempts = attempts + 1
		if not read_file("udp_probe.ready") then
			assert(attempts < 600, "UDP probe did not become ready")
			next_test_tick(wait_for_probe)
			return
		end
		write_file("udp_request.bin", datagram)
	end
	next_test_tick(wait_for_probe)

	local result_attempts = 0
	local sent = false
	local function wait_for_results()
		result_attempts = result_attempts + 1
		if handled == 1 and not sent then
			udp_events.on_send_packet(state, "127.0.0.1", 27071)
			sent = true
		end

		local outbound = read_file("udp_outbound.bin")
		if handled ~= 1 or not outbound then
			assert(result_attempts < 600, "UDP integration loopback did not complete")
			next_test_tick(wait_for_results)
			return
		end

		local game_magic, magic, version, flags, outbound_token, batch_size, batch_position =
			string.unpack(">c4c4BBc32I2", outbound)
		assert(game_magic == "7DFP")
		assert(magic == "SRCU")
		assert(version == 1 and flags == 0)
		assert(outbound_token == token)
		assert(batch_size == #outbound - 44)
		assert(#outbound <= 1200)

		local batch_version, _, message_count, message_position =
			string.unpack(">BBI2", outbound, batch_position)
		assert(batch_version == 1)
		assert(message_count >= 2)

		local message_kinds = {}
		for _ = 1, message_count do
			local message_size
			message_size, message_position = string.unpack(">I4", outbound, message_position)
			message_kinds[outbound:byte(message_position)] = true
			message_position = message_position + message_size
		end
		assert(message_kinds[2])
		assert(message_kinds[3])
		assert(client.pending_results[7])
		assert(#client.udp_pending_ack_order == 0)
		assert(#client.udp_send_queue == 0)

		client.player.connection = nil
		network.on_udp_datagram(state, {
			connection = connection,
			client = client,
			messages = {
				{
					kind = 1,
				},
			},
		})
		assert(not connection.is_open)
		assert(not client.bound)
		state.clients[connection] = nil
	end
	next_test_tick(wait_for_results)
end
