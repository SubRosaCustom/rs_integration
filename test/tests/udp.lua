local event_codec = require("main.src.eventCodec")
local network = require("main.src.network")
local udp_events = require("main.src.udpEvents")

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
		isOpen = true,
		address = "127.0.0.1",
		port = 27071,
	}
	function connection:close()
		self.isOpen = false
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
		recvBuffer = "",
		sendQueue = {},
		sendOffset = 1,
		pendingFileRequests = {},
		pendingBundleRequests = {},
		pendingEvents = {},
		pendingResults = {},
		awaitingResults = {},
		earlyResults = {},
		recentCompleted = {},
		hello = true,
		helloPayload = nil,
		bound = true,
		udpEventsReady = true,
		udp_token = token,
		udpSendQueue = {},
		udpPendingAckOrder = {},
		udpPendingAckSet = {},
		udpPendingAckStart = 1,
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
	udp_events.resetClient(reset_client)
	assert(reset_client.udp_token == nil)

	local pending_events = client.pendingEvents
	local pending_results = client.pendingResults
	local awaiting_results = client.awaitingResults
	local early_results = client.earlyResults
	local recent_completed = client.recentCompleted
	local udp_send_queue = client.udpSendQueue
	local udp_pending_ack_order = client.udpPendingAckOrder
	local udp_pending_ack_set = client.udpPendingAckSet
	network.refresh(state)
	assert(client.pendingEvents == pending_events)
	assert(client.pendingResults == pending_results)
	assert(client.awaitingResults == awaiting_results)
	assert(client.earlyResults == early_results)
	assert(client.recentCompleted == recent_completed)
	assert(client.udpSendQueue == udp_send_queue)
	assert(client.udpPendingAckOrder == udp_pending_ack_order)
	assert(client.udpPendingAckSet == udp_pending_ack_set)
	assert(client.udp_token == token)
	assert(not client.udpEventsReady)
	client.udpEventsReady = true

	local handled = 0
	assert(src.onClientEvent("test.loopback", function(_, value)
		assert(value == "payload")
		handled = handled + 1
		return "processed"
	end))

	local event_hash = assert(udp_events.hashEventName("test.loopback"))
	local args = assert(event_codec.encodeArgs("payload"))
	local message = assert(udp_events.encodeReliableEvent(event_hash, 7, args))
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
			udp_events.onSendPacket(state, "127.0.0.1", 27071)
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
		assert(client.pendingResults[7])
		assert(#client.udpPendingAckOrder == 0)
		assert(#client.udpSendQueue == 0)

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
		assert(not connection.isOpen)
		assert(not client.bound)
		state.clients[connection] = nil
	end
	next_test_tick(wait_for_results)
end
