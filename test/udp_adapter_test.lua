-- Host-only adapter check. Production uses MoonJIT's bit library.
bit32 = {
	bxor = function(a, b) return (a ~ b) & 0xFFFFFFFF end,
	band = function(a, b) return (a & b) & 0xFFFFFFFF end,
}
local time = 0
os.realClock = function() return time end
local inbound, outbound = {}, {}
srcIntegrationNative = {
	drainSrcPackets = function()
		local packets = inbound
		inbound = {}
		return { packets = packets, drained = #packets, vanillaPending = false, }
	end,
	sendPacket = function(_, _, data)
		outbound[#outbound + 1] = data
		return #data
	end,
}
local codec = require("main.src.event_codec")
local udp = require("main.src.udp_events")
local reliable = require("main.src.reliable_udp")
local token = string.rep("a", 32)
local connection = { is_open = true, close = function(self) self.is_open = false end, }
local client = {
	udp_token = token, hello = true, bound = true, udp_events_ready = true,
	player = { connection = { address = "127.0.0.1", port = 27071, }, },
}
local state = { clients = { [connection] = client, }, config = { maxEventBytes = 262144, }, }
local remote = reliable.new()
local event_hash = assert(udp.hash_event_name("test.fragments"))
local value = string.rep("x", 262130)
local arguments = assert(codec.encode_args(value))
assert(#arguments == 262144)
assert(not udp.encode_reliable_event(event_hash, 7, arguments .. "x"))
local event = assert(udp.encode_reliable_event(event_hash, 7, arguments))
assert(reliable.enqueue(remote, 1, 7, event))
local delivered, result_delivered = 0, 0
local function wrap(packet)
	return string.pack(">c4c4BBc32I2", "7DFP", "SRCU", 2, 0, token, #packet) .. packet
end
for tick = 0, 12000 do
	time = tick * 0.01
	reliable.advance(remote, time, true)
	udp.tick(client)
	local packet = reliable.next(remote)
	if packet and #packet + 44 <= 548 then
		local entry = { address = "127.0.0.1", port = 27071, data = wrap(packet), }
		inbound = { entry, entry, }
	end
	local decoded = udp.on_packet_receive(state)
	for _, datagram in ipairs(decoded) do
		for _, message in ipairs(datagram.messages) do
			if message.kind == 1 and udp.accept(client, message) then
				delivered = delivered + 1
				assert(message.args[1] == value)
				local result = assert(udp.encode_reliable_result(event_hash, 7, arguments))
				assert(udp.enqueue(client, result))
			end
		end
	end
	udp.on_send_packet(state, "127.0.0.1", 27071)
	for _, datagram in ipairs(outbound) do
		assert(#datagram <= 1200 and datagram:byte(9) == 2)
		if #datagram <= 548 then
			for _, result in ipairs(reliable.receive(remote, datagram:sub(45))) do
				assert(result.kind == 3 and result.id == 7)
				assert(result.bytes:sub(19) == arguments)
				result_delivered = result_delivered + 1
				reliable.accept(remote, result.kind, result.id)
			end
		end
	end
	outbound = {}
	assert(connection.is_open and not remote.error)
	if delivered == 1 and result_delivered == 1 and client.udp_reliable.bytes == 0 then break end
end
assert(delivered == 1 and result_delivered == 1)
assert(client.udp_reliable.bytes == 0)
local old_peer = client.udp_reliable
udp.reset_client(client)
assert(client.udp_reliable == nil and client.udp_token == nil)
assert(old_peer.bytes == 0)
print("UDP adapter: 256 KiB event/result, duplicate drain, MTU fallback and reset passed")
