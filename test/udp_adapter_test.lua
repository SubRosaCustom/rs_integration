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

-- One native send callback carries both queued events, without advancing wall time.
client.udp_token = token
client.udp_events_ready = true
udp.on_send_packet(state, "127.0.0.1", 27071) -- Initial size probe.
outbound = {}
local small = assert(codec.encode_args("small"))
assert(udp.enqueue(client, assert(udp.encode_reliable_event(event_hash, 201, small))))
assert(udp.enqueue(client, assert(udp.encode_reliable_result(event_hash, 202, small))))
udp.on_send_packet(state, "127.0.0.1", 27071)
assert(#outbound == 1 and #outbound[1] <= 1200 and outbound[1]:byte(45) == 5)
local reader = reliable.new()
local messages = reliable.receive(reader, outbound[1]:sub(45))
assert(#messages == 2 and messages[1].kind ~= messages[2].kind)
print("UDP adapter: one native send batches event/result without a pacing delay passed")

local function fresh_peer()
    udp.reset_client(client)
    client.udp_token, client.udp_events_ready = token, true
    udp.tick(client)
    client.udp_reliable.probe_due = time + 60
    outbound = {}
    return client.udp_reliable
end
local peer = fresh_peer()
-- Real completed transfers create enough pending receipts to exceed one flush.
for id = 1, 400 do
    local fragment = string.pack(">BBI4I2I4I2I2", 1, 1, id, 1, 18, 488, 0) .. string.rep("x",18)
    assert(#reliable.receive(peer, fragment) == 1)
    assert(reliable.accept(peer, 1, id))
end
udp.on_send_packet(state, "127.0.0.1", 27071)
assert(#outbound == 8 and next(peer.acks), "Stop at the flush packet budget and retain queued receipts")
local bytes = 0
for _, datagram in ipairs(outbound) do assert(#datagram <= 1200); bytes = bytes + #datagram end
assert(bytes <= 9600)
outbound = {}
udp.on_send_packet(state, "127.0.0.1", 27071)
assert(#outbound > 0 and #outbound <= 8 and not next(peer.acks), "Next send continues without advancing time")
outbound = {}; udp.on_send_packet(state, "127.0.0.1", 27071); assert(#outbound == 0, "Idle flush sends nothing")
peer = fresh_peer()
local medium = assert(codec.encode_args(string.rep("x",400)))
for id=1,4 do assert(udp.enqueue(client, assert(udp.encode_reliable_event(event_hash,id,medium)))) end
udp.on_send_packet(state, "127.0.0.1", 27071)
assert(#outbound == 2, "Congestion window stops a burst before the flush budget")
outbound={};udp.on_send_packet(state,"127.0.0.1",27071);assert(#outbound==0)
peer = fresh_peer()
for id=1,4 do assert(udp.enqueue(client, assert(udp.encode_reliable_event(event_hash,id,medium)))) end
local original_send,attempts=srcIntegrationNative.sendPacket,0
srcIntegrationNative.sendPacket=function() attempts=attempts+1;return 0 end
package.loaded['main.src.log'].warn=function() end -- Expected native send failure boundary.
udp.on_send_packet(state,"127.0.0.1",27071)
assert(attempts==1,"Stop flushing after a native send failure")
srcIntegrationNative.sendPacket=original_send
print("UDP adapter: multi-datagram budget, carryover, idle, congestion and failed-send stop passed")
