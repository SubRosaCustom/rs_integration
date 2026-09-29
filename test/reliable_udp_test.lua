local reliable = require("main.src.reliable_udp")
local function payload(size)
	local pattern = {}
	for i = 0, 250 do pattern[#pattern + 1] = string.char(i) end
	return string.rep(table.concat(pattern), math.ceil(size / 251)):sub(1, size)
end
local function hex(bytes)
	return (bytes:gsub(".", function(byte) return string.format("%02x", byte:byte()) end))
end
local function unhex(text)
	return (text:gsub("..", function(byte) return string.char(tonumber(byte, 16)) end))
end
if arg[1] == "--peer" then
	local peer = reliable.new()
	for line in io.lines() do
		local now, input = line:match("^(%S+) (%S+)$")
		reliable.advance(peer, tonumber(now), true)
		local delivered = 0
		if input:sub(1, 1) == "+" then
			assert(reliable.enqueue(peer, 1, 17, payload(tonumber(input:sub(2)))))
		elseif input ~= "-" then
			for _, event in ipairs(reliable.receive(peer, unhex(input))) do
				assert(event.bytes == payload(#event.bytes))
				delivered = delivered + 1
				reliable.accept(peer, event.kind, event.id)
			end
		end
		local packet = reliable.next(peer)
		io.write(string.format("%s %d %d %s\n", packet and hex(packet) or "-", delivered,
			#reliable.take_receipts(peer), peer.error and hex(peer.error) or "-"))
		io.flush()
	end
	return
end
local function simulate(size, loss, small_path, shrink)
	local sender, receiver = reliable.new(), reliable.new()
	local bytes = payload(size)
	local delivered, receipts, packets = 0, 0, 0
	local lost_completion = false
	local delayed = {}
	for step = 0, 14999 do
		local now = step * 0.01
		reliable.advance(sender, now, true)
		reliable.advance(receiver, now, true)
		if step == 100 then assert(reliable.enqueue(sender, 1, 17, bytes)) end
		local packet = reliable.next(sender)
		local function consume(inbound)
			for _, event in ipairs(reliable.receive(receiver, inbound)) do
				assert(event.bytes == bytes)
				delivered = delivered + 1
				reliable.accept(receiver, event.kind, event.id)
			end
		end
		if packet then
			assert(#packet + 44 <= 1200)
			packets = packets + 1
			local drop = (small_path or (shrink and step > 130)) and #packet + 44 > 548
			drop = drop or (loss and packets % 13 == 0)
			if not drop then
				if loss and packets % 7 == 0 then delayed[#delayed + 1] = packet
				else
					consume(packet)
					if loss then assert(#reliable.receive(receiver, packet) == 0) end
				end
			end
		end
		if step % 17 == 0 then
			for i = #delayed, 1, -1 do consume(delayed[i]) end
			delayed = {}
		end
		packet = reliable.next(receiver)
		if packet then
			local drop = false
			if loss and packet:byte(1) == 2 and packet:byte(11) == 1 and not lost_completion then
				lost_completion = true
				drop = true
			end
			if not drop then assert(#reliable.receive(sender, packet) == 0) end
		end
		receipts = receipts + #reliable.take_receipts(sender)
		assert(not sender.error, sender.error)
		assert(not receiver.error, receiver.error)
		if receipts > 0 then break end
	end
	assert(delivered == 1 and receipts == 1)
	assert(sender.bytes == 0 and receiver.bytes == 0)
end
for _, size in ipairs({ 18, 488, 489, 1024, 1025, 1795, 262162, }) do
	simulate(size, false, false, false)
	simulate(size, true, false, false)
	simulate(size, true, true, false)
end
simulate(262162, true, false, true)
local peer = reliable.new()
assert(not reliable.enqueue(peer, 1, 1, payload(262163)))
assert(not reliable.enqueue(peer, 1, 0, payload(18)))
for id = 1, 3 do assert(reliable.enqueue(peer, 1, id, payload(262162))) end
assert(not reliable.enqueue(peer, 1, 4, payload(262162)))
reliable.advance(peer, 0, true)
reliable.advance(peer, 1, false)
reliable.advance(peer, 1000, true)
assert(not peer.error)
reliable.advance(peer, 1121, true)
assert(peer.error)
print("Lua reliable UDP tests passed")

local sender, receiver = reliable.new(), reliable.new()
reliable.advance(sender, 0, true)
assert(reliable.enqueue(sender, 1, 9, payload(1000)))
reliable.next(sender)
reliable.advance(sender, 0.1, true)
local first = assert(reliable.next(sender))
assert(#first == 504 and first:byte(1) == 1)
assert(#reliable.receive(receiver, first) == 0)
local conflict = first:sub(1, -2) .. string.char((first:byte(-1) + 1) % 256)
assert(#reliable.receive(receiver, conflict) == 0 and receiver.error)
local budget = reliable.new()
assert(#reliable.receive(budget, first, 999) == 0 and budget.error)
local truncated = reliable.new()
assert(#reliable.receive(truncated, first:sub(1, -2)) == 0 and truncated.error)
local expired = reliable.new()
reliable.advance(expired, 0, true)
reliable.receive(expired, first)
reliable.advance(expired, 121, true)
assert(expired.error)
local cached = reliable.new()
local result = string.pack(">BBI4I2I4I2I2", 1, 3, 19, 1, 18, 488, 0) .. payload(18)
assert(#reliable.receive(cached, result) == 1)
assert(reliable.accept(cached, 3, 19))
assert(not reliable.accept(cached, 3, 19))
assert(#reliable.receive(cached, result) == 0)
reliable.advance(cached, 0, true)
reliable.advance(cached, 241, true)
assert(#reliable.receive(cached, result) == 0 and cached.error)
print("Lua UDP malformed/duplicate/quota/expiry checks passed")
