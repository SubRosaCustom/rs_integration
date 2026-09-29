-- Protocol 8 transport. Wire layout and limits match client/sync/reliable_udp.cpp.
local M = {}
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

local function pieces(count)
	local result = {}
	for i = 1, count do
		result[i] = { sent = -1, attempts = 0, acked = false, }
	end
	return result
end

local function retry_delay(peer, attempts)
	return math.min(4, math.max(peer.retry_base, peer.rtt * 3) * 2 ^ (attempts - 1))
end

function M.new()
	return {
		outbound = {}, inbound = {}, completed = {}, retired = {}, acks = {}, receipts = {},
		bytes = 0, now = 0, wall = -1, active = false, large = false,
		next_send = 0, probe_sent = -1, probe_due = 0, probe_id = 0, probe_attempts = 0,
		window = 2, rtt = 0.1, cursor = 0, retry_base = 1 / 3, retry_attempts = 5,
	}
end

function M.enqueue(peer, kind, id, bytes)
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
	peer.outbound[transfer_key] = {
		kind = kind, id = id, generation = 1, chunk = chunk, total = #bytes, bytes = bytes,
		pieces = pieces(math.ceil(#bytes / chunk)), created = peer.now, probe_at = -1, probes = 0,
	}
	peer.bytes = peer.bytes + #bytes
	return true
end

function M.advance(peer, now, active)
	if peer.wall >= 0 and peer.active then
		peer.now = peer.now + math.max(0, now - peer.wall)
	end
	peer.wall = now
	peer.active = active
	for transfer_key, completed in pairs(peer.completed) do
		if completed.expiry <= peer.now then
			local kind = math.floor(transfer_key / 4294967296)
			peer.retired[kind] = math.max(peer.retired[kind] or 0, transfer_key % 4294967296)
			peer.acks[transfer_key] = nil
			peer.completed[transfer_key] = nil
		end
	end
	for _, transfer in pairs(peer.inbound) do
		if peer.now - transfer.created >= LIFETIME then
			fail(peer, "UDP reassembly expired; session must be reset")
		end
	end
	for _, transfer in pairs(peer.outbound) do
		if peer.now - transfer.created >= LIFETIME then
			fail(peer, "UDP delivery deadline exceeded; receipt is uncertain")
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
			transfer.pieces = pieces(math.ceil(transfer.total / BASE_CHUNK))
			transfer.probe_at = -1
			transfer.probes = 0
		end
	end
end

local function ack(peer, transfer, complete)
	local bitmap = {}
	for i = 1, math.ceil(#transfer.pieces / 8) do
		bitmap[i] = 0
	end
	for i, piece in ipairs(transfer.pieces) do
		if complete or piece.acked then
			local byte = math.floor((i - 1) / 8) + 1
			bitmap[byte] = bitmap[byte] + 2 ^ ((i - 1) % 8)
		end
	end
	for i, byte in ipairs(bitmap) do
		bitmap[i] = string.char(byte)
	end
	peer.acks[key(transfer.kind, transfer.id)] = string.pack(">BBI4I2I2B",
		2, transfer.kind, transfer.id, transfer.generation, #transfer.pieces, complete and 1 or 0
	) .. table.concat(bitmap)
end

function M.next(peer)
	if peer.error or peer.now < peer.next_send then
		return nil
	end
	peer.next_send = peer.now + 0.005
	local ack_key, ack_bytes = next(peer.acks)
	if ack_key then
		peer.acks[ack_key] = nil
		return ack_bytes
	end
	if peer.probe_reply then
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
			if peer.probe_attempts == 0 then
				peer.probe_id = peer.probe_id % 0xFFFFFFFF + 1
			end
			peer.probe_attempts = peer.probe_attempts + 1
			peer.probe_sent = peer.now
			return string.pack(">BI4", 3, peer.probe_id) .. string.rep("\0", 1151)
		end
	end
	local in_flight = 0
	local order = {}
	for transfer_key, transfer in pairs(peer.outbound) do
		order[#order + 1] = transfer_key
		for _, piece in ipairs(transfer.pieces) do
			if piece.sent >= 0 and not piece.acked then
				in_flight = in_flight + 1
			end
		end
	end
	table.sort(order)
	local start = 1
	for i, transfer_key in ipairs(order) do
		if transfer_key <= peer.cursor then
			start = i + 1
		end
	end
	for visited = 0, #order - 1 do
		local transfer_key = order[(start + visited - 1) % #order + 1]
		local transfer = peer.outbound[transfer_key]
		local selected, all_acked = nil, true
		for i, piece in ipairs(transfer.pieces) do
			if not piece.acked then
				all_acked = false
				if piece.sent >= 0 and peer.now - piece.sent >= retry_delay(peer, piece.attempts) then
					selected = i
					break
				end
				if piece.sent < 0 and in_flight < math.floor(peer.window) and not selected then
					selected = i
				end
			end
		end
		if all_acked and (transfer.probe_at < 0 or peer.now - transfer.probe_at >= retry_delay(peer, math.max(1, transfer.probes))) then
			if transfer.probes >= peer.retry_attempts then
				fail(peer, "UDP completion acknowledgement timed out")
				return nil
			end
			selected = #transfer.pieces
			transfer.probe_at = peer.now
			transfer.probes = transfer.probes + 1
		end
		if selected then
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
			piece.sent = peer.now
			piece.attempts = piece.attempts + 1
			peer.cursor = transfer_key
			peer.next_send = peer.now + math.max(0.005, peer.rtt / peer.window)
			return string.pack(">BBI4I2I4I2I2", 1, transfer.kind, transfer.id,
				transfer.generation, transfer.total, transfer.chunk, selected - 1
			) .. transfer.bytes:sub((selected - 1) * transfer.chunk + 1, selected * transfer.chunk)
		end
	end
	return nil
end

function M.receive(peer, packet, available_bytes)
	available_bytes = available_bytes or MAX_BUFFERED_BYTES
	if peer.error or #packet == 0 or #packet > 1156 then
		return {}
	end
	local packet_type = packet:byte(1)
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
				peer.window = math.min(8, peer.window + 1 / peer.window)
			end
		end
		if complete == 1 then
			if not all then
				fail(peer, "incomplete UDP completion bitmap")
				return {}
			end
			peer.receipts[#peer.receipts + 1] = { kind = kind, id = id, }
			peer.bytes = peer.bytes - transfer.total
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
		ack(peer, { kind = kind, id = id, generation = generation, pieces = pieces(count), }, true)
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
		peer.bytes = peer.bytes - transfer.total
		peer.inbound[transfer_key] = nil
		transfer = nil
	end
	if not transfer then
		if id <= (peer.retired[kind] or 0) then
			fail(peer, "UDP event predates replay window; session must be reset")
			return {}
		end
		if count_entries(peer.inbound) >= 32 or peer.bytes + total > MAX_BUFFERED_BYTES
			or total > available_bytes or count_entries(peer.completed) >= 32768 then
				fail(peer, "UDP receive budget exhausted")
				return {}
			end
		transfer = {
			kind = kind, id = id, generation = generation, total = total, chunk = chunk,
			pieces = pieces(count), fragments = {}, created = peer.now,
		}
		peer.inbound[transfer_key] = transfer
		peer.bytes = peer.bytes + total
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
	transfer.pieces[index + 1].acked = true
	ack(peer, transfer, false)
	for _, piece in ipairs(transfer.pieces) do
		if not piece.acked then
		return {} end
	end
	if transfer.offered then
		return {}
	end
	transfer.offered = true
	return { { kind = kind, id = id, bytes = table.concat(transfer.fragments), }, }
end

function M.accept(peer, kind, id)
	local transfer_key = key(kind, id)
	local transfer = peer.inbound[transfer_key]
	if not transfer then
		return false
	end
	ack(peer, transfer, true)
	peer.completed[transfer_key] = { total = transfer.total, expiry = peer.now + RETENTION, }
	peer.bytes = peer.bytes - transfer.total
	peer.inbound[transfer_key] = nil
	return true
end

function M.take_receipts(peer)
	local receipts = peer.receipts
	peer.receipts = {}
	return receipts
end

return M
