-- Protocol 10 transport. Wire layout and limits match client/sync/reliable_udp.cpp.
local reliable_udp = {}
local MAX_MESSAGE_BYTES = 256 * 1024 + 18
local MAX_BUFFERED_BYTES = 1024 * 1024
local BASE_CHUNK, LARGE_CHUNK = 488, 1024
local LIFETIME, RETENTION = 120, 240

local function key(kind, id)
	return kind * 4294967296 + id
end

local function count_entries(values)
	local count = 0
	for _ in pairs(values) do
		count = count + 1
	end
	return count
end

local function fail(peer, reason)
	peer.error = peer.error or reason
end

local total_bytes = 0

local function add_bytes(peer, delta)
	peer.bytes = peer.bytes + delta
	total_bytes = total_bytes + delta
end

-- sum of every peer's buffered bytes, for the global budget
function reliable_udp.total_bytes()
	return total_bytes
end

-- gives a dropped or reset peer's bytes back to the counter
function reliable_udp.release(peer)
	total_bytes = total_bytes - peer.bytes
	peer.bytes = 0
end

local function pieces(count)
	local result = {}
	for i = 1, count do
		result[i] = { sent = -1, attempts = 0, acked = false, }
	end
	return result
end

-- next_unsent only moves forward; flight holds sent-but-unacked indices
local function init_outbound_pieces(peer, transfer, count)
	transfer.pieces = pieces(count)
	transfer.unacked = count
	transfer.next_unsent = 1
	transfer.flight = {}
	transfer.in_flight = 0
end

local function drop_in_flight(peer, transfer)
	peer.in_flight = peer.in_flight - transfer.in_flight
	transfer.in_flight = 0
end

local function order_search(order, transfer_key)
	local low, high = 1, #order
	while low <= high do
		local middle = math.floor((low + high) / 2)
		if order[middle] < transfer_key then
			low = middle + 1
		else
			high = middle - 1
		end
	end
	return low
end

local complete_bitmaps = {}

local function complete_bitmap(count)
	local cached = complete_bitmaps[count]
	if not cached then
		local bytes = {}
		for i = 1, math.ceil(count / 8) do
			local bits = math.min(8, count - (i - 1) * 8)
			bytes[i] = string.char(2 ^ bits - 1)
		end
		cached = table.concat(bytes)
		complete_bitmaps[count] = cached
	end
	return cached
end

local function retry_delay(peer, attempts)
	return math.min(4, math.max(peer.retry_base, peer.rtt * 3) * 2 ^ (attempts - 1))
end

function reliable_udp.new()
	return {
		outbound = {}, inbound = {}, completed = {}, completed_count = 0, retired = {}, acks = {}, receipts = {},
		latest = {}, latest_sent = {}, latest_received = {},
		bytes = 0, in_flight = 0, order = {}, now = 0, wall = -1, active = false, large = false,
		probe_sent = -1, probe_due = 0, probe_id = 0, probe_attempts = 0,
		window = 2, rtt = 0.1, cursor = 0, retry_base = 1 / 3, retry_attempts = 5,
	}
end

function reliable_udp.enqueue(peer, kind, id, bytes)
	if peer.error or (kind ~= 1 and kind ~= 3) or id < 1 or id > 0xFFFFFFFF
		or #bytes < 18 or #bytes > MAX_MESSAGE_BYTES then
			return false
		end
	local transfer_key = key(kind, id)
	local existing = peer.outbound[transfer_key]
	if existing then
		return existing.bytes == bytes
	end
	if count_entries(peer.outbound) >= 32 or peer.bytes + #bytes > MAX_BUFFERED_BYTES then
		return false
	end
	local chunk = peer.large and LARGE_CHUNK or BASE_CHUNK
	local transfer = {
		kind = kind, id = id, generation = 1, chunk = chunk, total = #bytes, bytes = bytes,
		created = peer.now, probe_at = -1, probes = 0,
	}
	init_outbound_pieces(peer, transfer, math.ceil(#bytes / chunk))
	peer.outbound[transfer_key] = transfer
	peer.outbound_deadline = math.min(peer.outbound_deadline or math.huge, peer.now)
	table.insert(peer.order, order_search(peer.order, transfer_key), transfer_key)
	add_bytes(peer, #bytes)
	return true
end

function reliable_udp.enqueue_latest(peer, id, bytes)
	if peer.error or type(bytes) ~= "string" or #bytes < 18 or #bytes > 503 or id < 1 or id > 0xFFFFFFFF
		or bytes:byte(1) ~= 1 or bytes:byte(2) ~= 0 or string.unpack(">I4",bytes,11) ~= id
		or string.unpack(">I4",bytes,15) ~= #bytes - 18 then return false end
	local name = bytes:sub(3,10)
	local previous = peer.latest[name]
	if not peer.latest_sent[name] and count_entries(peer.latest_sent) >= 32 then return false end
	local size = peer.bytes - (previous and #previous or 0) + #bytes
	if size > MAX_BUFFERED_BYTES then return false end
	peer.latest_sent[name] = true
	add_bytes(peer, size - peer.bytes); peer.latest[name] = bytes
	return true
end

function reliable_udp.advance(peer, now, active)
	if peer.wall >= 0 and peer.active then
		peer.now = peer.now + math.max(0, now - peer.wall)
	end
	peer.wall = now
	peer.active = active
	while peer.completed_head and peer.completed_head.expiry <= peer.now do
		local entry = peer.completed_head
		local transfer_key = entry.key
		local kind = math.floor(transfer_key / 4294967296)
		peer.retired[kind] = math.max(peer.retired[kind] or 0, transfer_key % 4294967296)
		peer.acks[transfer_key] = nil
		peer.completed[transfer_key] = nil
		peer.completed_count = peer.completed_count - 1
		peer.completed_head = entry.next
	end
	if not peer.completed_head then
		peer.completed_tail = nil
	end
	if peer.inbound_deadline and peer.now - peer.inbound_deadline >= LIFETIME then
		peer.inbound_deadline = nil
		for _, transfer in pairs(peer.inbound) do
			local deadline = transfer.created
			if peer.now - deadline >= LIFETIME then
				fail(peer, "UDP reassembly expired; session must be reset")
			end
			peer.inbound_deadline = math.min(peer.inbound_deadline or math.huge, deadline)
		end
	end
	if peer.outbound_deadline and peer.now - peer.outbound_deadline >= LIFETIME then
		peer.outbound_deadline = nil
		for _, transfer in pairs(peer.outbound) do
			local deadline = transfer.created
			if peer.now - deadline >= LIFETIME then
				fail(peer, "UDP delivery deadline exceeded; receipt is uncertain")
			end
			peer.outbound_deadline = math.min(peer.outbound_deadline or math.huge, deadline)
		end
	end
end

local function fallback(peer)
	peer.large = false
	peer.probe_due = peer.now + 60
	peer.probe_attempts = 0
	peer.probe_sent = -1
	peer.window = 1
	for _, transfer in pairs(peer.outbound) do
		if transfer.chunk ~= BASE_CHUNK then
			transfer.generation = transfer.generation + 1
			transfer.chunk = BASE_CHUNK
			drop_in_flight(peer, transfer)
			init_outbound_pieces(peer, transfer, math.ceil(transfer.total / BASE_CHUNK))
			transfer.probe_at = -1
			transfer.probes = 0
		end
	end
end

local function ack(peer, kind, id, generation, count, complete, bitmap)
	peer.acks[key(kind, id)] = string.pack(">BBI4I2I2B", 2, kind, id, generation, count, complete and 1 or 0)
		.. (complete and complete_bitmap(count) or table.concat(bitmap))
end

local function next_frame(peer, max_bytes)
	if peer.error then
		return nil
	end
	local ack_key, ack_bytes = next(peer.acks)
	if ack_key then
		if #ack_bytes > max_bytes then return nil end
		peer.acks[ack_key] = nil
		return ack_bytes
	end
	if peer.probe_reply then
		if #peer.probe_reply > max_bytes then return nil end
		local packet = peer.probe_reply
		peer.probe_reply = nil
		return packet
	end
	if not peer.active then
		return nil
	end
	if peer.now >= peer.probe_due and (peer.probe_sent < 0 or peer.now - peer.probe_sent >= 1) then
		if peer.probe_attempts >= 3 then
			if peer.large then
				fallback(peer)
			else
				peer.probe_due = peer.now + 60
				peer.probe_attempts = 0
				peer.probe_sent = -1
			end
		else
			if max_bytes < 1156 then return nil end
			if peer.probe_attempts == 0 then
				peer.probe_id = peer.probe_id % 0xFFFFFFFF + 1
			end
			peer.probe_attempts = peer.probe_attempts + 1
			peer.probe_sent = peer.now
			return string.pack(">BI4", 3, peer.probe_id) .. string.rep("\0", 1151)
		end
	end
	for name, bytes in pairs(peer.latest) do
		if #bytes + 1 <= max_bytes then
			peer.latest[name] = nil; add_bytes(peer, -#bytes)
			return string.char(6) .. bytes
		end
	end
	local in_flight = peer.in_flight
	local order = peer.order
	local start = order_search(order, peer.cursor + 1)
	for visited = 0, #order - 1 do
		local transfer_key = order[(start + visited - 1) % #order + 1]
		local transfer = peer.outbound[transfer_key]
		local selected = nil
		local all_acked = transfer.unacked == 0
		if not all_acked then
			for i in pairs(transfer.flight) do
				local piece = transfer.pieces[i]
				if (not selected or i < selected)
					and peer.now - piece.sent >= retry_delay(peer, piece.attempts) then
					selected = i
				end
			end
			if not selected and in_flight < math.floor(peer.window) then
				local pieces_list = transfer.pieces
				local cursor = transfer.next_unsent
				while cursor <= #pieces_list and (pieces_list[cursor].sent >= 0 or pieces_list[cursor].acked) do
					cursor = cursor + 1
				end
				transfer.next_unsent = cursor
				if cursor <= #pieces_list then selected = cursor end
			end
		end
		if all_acked and (transfer.probe_at < 0 or peer.now - transfer.probe_at >= retry_delay(peer, math.max(1, transfer.probes))) then
			if transfer.probes >= peer.retry_attempts then
				fail(peer, "UDP completion acknowledgement timed out")
				return nil
			end
			selected = #transfer.pieces
		end
		local frame_bytes = selected and (16 + math.min(transfer.chunk, transfer.total - (selected - 1) * transfer.chunk))
		if selected and frame_bytes <= max_bytes then
			if all_acked then transfer.probe_at = peer.now; transfer.probes = transfer.probes + 1 end
			local piece = transfer.pieces[selected]
			if not all_acked and piece.attempts >= 3 and transfer.chunk == LARGE_CHUNK then
				fallback(peer)
				return nil
			end
			if not all_acked and piece.attempts >= peer.retry_attempts then
				fail(peer, "UDP fragment retry limit exceeded; receipt is uncertain")
				return nil
			end
			if piece.sent >= 0 and not all_acked then
				peer.window = math.max(1, peer.window / 2)
			end
			if piece.sent < 0 and not piece.acked then
				transfer.flight[selected] = true
				transfer.in_flight = transfer.in_flight + 1
				peer.in_flight = peer.in_flight + 1
			end
			piece.sent = peer.now
			piece.attempts = piece.attempts + 1
			peer.cursor = transfer_key
			return string.pack(">BBI4I2I4I2I2", 1, transfer.kind, transfer.id,
				transfer.generation, transfer.total, transfer.chunk, selected - 1
			) .. transfer.bytes:sub((selected - 1) * transfer.chunk + 1, selected * transfer.chunk)
		end
	end
	return nil
end

function reliable_udp.next(peer)
	local first = next_frame(peer, 1156)
	local budget = peer.large and 1156 or 504
	if not first or #first + 5 > budget then return first end
	local parts = { string.pack(">I2", #first), first }
	local size, count = 3 + 2 + #first, 1
	while size + 2 < budget do
		local frame = next_frame(peer, budget - size - 2)
		if not frame then break end
		parts[#parts + 1] = string.pack(">I2", #frame)
		parts[#parts + 1] = frame
		size, count = size + 2 + #frame, count + 1
	end
	if peer.error then return nil end
	if count == 1 then return first end
	return string.pack(">BI2", 5, count) .. table.concat(parts)
end

function reliable_udp.receive(peer, packet, available_bytes)
	available_bytes = available_bytes or MAX_BUFFERED_BYTES
	if peer.error or #packet == 0 or #packet > 1156 then
		return {}
	end
	local packet_type = packet:byte(1)
	if packet_type == 5 then
		if #packet < 3 then fail(peer, "short UDP batch"); return {} end
		local count, pos = string.unpack(">I2", packet, 2)
		if count < 2 or count > math.floor((#packet - 3) / 7) then fail(peer, "invalid UDP batch count"); return {} end
		local frames = {}
		for i = 1, count do
			if pos + 1 > #packet then fail(peer, "short UDP batch length"); return {} end
			local length; length, pos = string.unpack(">I2", packet, pos)
			if length < 5 or length > #packet - pos + 1 or packet:byte(pos) == 5 then
				fail(peer, "invalid UDP batch frame"); return {}
			end
			frames[i] = packet:sub(pos, pos + length - 1); pos = pos + length
		end
		if pos ~= #packet + 1 then fail(peer, "trailing UDP batch bytes"); return {} end
		local deliveries, initial_bytes = {}, peer.bytes
		for _, frame in ipairs(frames) do
			local reserved = math.max(0, peer.bytes - initial_bytes)
			local completed = reliable_udp.receive(peer, frame, math.max(0, available_bytes - reserved))
			if peer.error then return {} end
			for _, delivery in ipairs(completed) do deliveries[#deliveries + 1] = delivery end
		end
		return deliveries
	end
	if packet_type == 6 then
		if #packet < 19 or #packet > 504 or packet:byte(2) ~= 1 or packet:byte(3) ~= 0
			or string.unpack(">I4",packet,16) ~= #packet - 19 or string.unpack(">I4",packet,12) == 0 then
			fail(peer,"invalid latest-state UDP message"); return {}
		end
		local name, id = packet:sub(4,11), string.unpack(">I4",packet,12)
		local previous = peer.latest_received[name]
		if previous and id <= previous then return {} end
		if not previous and count_entries(peer.latest_received) >= 32 then fail(peer,"latest-state UDP channel budget exhausted"); return {} end
		peer.latest_received[name] = id
		return {{kind=1,id=id,bytes=packet:sub(2),latest=true}}
	end
	if packet_type == 3 or packet_type == 4 then
		if #packet ~= (packet_type == 3 and 1156 or 5) then
			fail(peer, "invalid UDP MTU probe")
			return {}
		end
		local id = string.unpack(">I4", packet, 2)
		if packet_type == 3 then
			peer.probe_reply = string.pack(">BI4", 4, id)
		elseif id == peer.probe_id and peer.probe_sent >= 0 then
			peer.large = true
			peer.probe_sent = -1
			peer.probe_attempts = 0
			peer.probe_due = peer.now + 30
		end
		return {}
	end
	if #packet < 8 or (packet_type ~= 1 and packet_type ~= 2) then
		fail(peer, "invalid UDP transport header")
		return {}
	end
	local _, kind, id, generation = string.unpack(">BBI4I2", packet)
	if (kind ~= 1 and kind ~= 3) or id == 0 or generation < 1 or generation > 2 then
		fail(peer, "invalid UDP transfer identity")
		return {}
	end
	local transfer_key = key(kind, id)
	if packet_type == 2 then
		if #packet < 11 then
			fail(peer, "short UDP bitmap")
			return {}
		end
		local count, complete = string.unpack(">I2B", packet, 9)
		if count == 0 or count > 538 or complete > 1 or #packet ~= 11 + math.ceil(count / 8) then
			fail(peer, "invalid UDP bitmap")
			return {}
		end
		local transfer = peer.outbound[transfer_key]
		if not transfer or generation ~= transfer.generation then
			return {}
		end
		if count ~= #transfer.pieces then
			fail(peer, "UDP bitmap count mismatch")
			return {}
		end
		local all = true
		for i, piece in ipairs(transfer.pieces) do
			local received = math.floor(packet:byte(12 + math.floor((i - 1) / 8)) / 2 ^ ((i - 1) % 8)) % 2 == 1
			all = all and received
			if received and not piece.acked then
				if piece.sent < 0 and complete == 0 then
					fail(peer, "UDP acknowledgement for unsent fragment")
					return {}
				end
				if piece.attempts == 1 then
					peer.rtt = math.max(0.01, math.min(2, 0.875 * peer.rtt + 0.125 * (peer.now - piece.sent)))
				end
				piece.acked = true
				transfer.unacked = transfer.unacked - 1
				if piece.sent >= 0 then
					transfer.flight[i] = nil
					transfer.in_flight = transfer.in_flight - 1
					peer.in_flight = peer.in_flight - 1
				end
				peer.window = math.min(8, peer.window + 1 / peer.window)
			end
		end
		if complete == 1 then
			if not all then
				fail(peer, "incomplete UDP completion bitmap")
				return {}
			end
			peer.receipts[#peer.receipts + 1] = { kind = kind, id = id, }
			add_bytes(peer, -transfer.total)
			drop_in_flight(peer, transfer)
			table.remove(peer.order, order_search(peer.order, transfer_key))
			peer.outbound[transfer_key] = nil
		end
		return {}
	end
	if #packet < 16 then
		fail(peer, "short UDP fragment")
		return {}
	end
	local total, chunk, index = string.unpack(">I4I2I2", packet, 9)
	if total < 18 or total > MAX_MESSAGE_BYTES or (chunk ~= BASE_CHUNK and chunk ~= LARGE_CHUNK)
		or (generation == 2 and chunk ~= BASE_CHUNK) then
			fail(peer, "invalid UDP fragment dimensions")
			return {}
		end
	local count = math.ceil(total / chunk)
	if index >= count or #packet ~= 16 + math.min(chunk, total - index * chunk) then
		fail(peer, "invalid UDP fragment length")
		return {}
	end
	local completed = peer.completed[transfer_key]
	if completed then
		if completed.total ~= total then
			fail(peer, "UDP completed message changed size")
			return {}
		end
		ack(peer, kind, id, generation, count, true)
		return {}
	end
	local transfer = peer.inbound[transfer_key]
	if transfer and generation < transfer.generation then
		return {}
	end
	if transfer and generation > transfer.generation then
		if total ~= transfer.total then
			fail(peer, "UDP restart changed size")
			return {}
		end
		add_bytes(peer, -transfer.total)
		peer.inbound[transfer_key] = nil
		transfer = nil
	end
	if not transfer then
		if id <= (peer.retired[kind] or 0) then
			fail(peer, "UDP event predates replay window; session must be reset")
			return {}
		end
		if count_entries(peer.inbound) >= 32 or peer.bytes + total > MAX_BUFFERED_BYTES
			or total > available_bytes or peer.completed_count >= 32768 then
				fail(peer, "UDP receive budget exhausted")
				return {}
			end
		transfer = {
			kind = kind, id = id, generation = generation, total = total, chunk = chunk,
			pieces = pieces(count), fragments = {}, created = peer.now,
			received = 0, bits = {}, bit_chars = {},
		}
		for i = 1, math.ceil(count / 8) do
			transfer.bits[i] = 0
			transfer.bit_chars[i] = "\0"
		end
		peer.inbound[transfer_key] = transfer
		peer.inbound_deadline = math.min(peer.inbound_deadline or math.huge, peer.now)
		add_bytes(peer, total)
	end
	if transfer.total ~= total or transfer.chunk ~= chunk then
		fail(peer, "conflicting UDP fragment metadata")
		return {}
	end
	local bytes = packet:sub(17)
	if transfer.pieces[index + 1].acked and transfer.fragments[index + 1] ~= bytes then
		fail(peer, "conflicting duplicate UDP fragment")
		return {}
	end
	transfer.fragments[index + 1] = bytes
	local piece = transfer.pieces[index + 1]
	if not piece.acked then
		piece.acked = true
		transfer.received = transfer.received + 1
		local byte = math.floor(index / 8) + 1
		transfer.bits[byte] = transfer.bits[byte] + 2 ^ (index % 8)
		transfer.bit_chars[byte] = string.char(transfer.bits[byte])
	end
	ack(peer, kind, id, transfer.generation, count, false, transfer.bit_chars)
	if transfer.received < count then
		return {}
	end
	if transfer.offered then
		return {}
	end
	transfer.offered = true
	return { { kind = kind, id = id, bytes = table.concat(transfer.fragments), }, }
end

function reliable_udp.accept(peer, kind, id)
	local transfer_key = key(kind, id)
	local transfer = peer.inbound[transfer_key]
	if not transfer then
		return false
	end
	ack(peer, kind, id, transfer.generation, #transfer.pieces, true)
	peer.completed_count = peer.completed_count + 1
	local completed = { total = transfer.total, expiry = peer.now + RETENTION, key = transfer_key, }
	peer.completed[transfer_key] = completed
	if peer.completed_tail then
		peer.completed_tail.next = completed
	else
		peer.completed_head = completed
	end
	peer.completed_tail = completed
	add_bytes(peer, -transfer.total)
	peer.inbound[transfer_key] = nil
	return true
end

function reliable_udp.take_receipts(peer)
	local receipts = peer.receipts
	peer.receipts = {}
	return receipts
end

return reliable_udp
