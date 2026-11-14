-- many-client UDP paths: indexes, global byte counter, fair share, rate limits
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
local log = require("main.src.log")
local warnings = {}
log.warn = function(...) warnings[#warnings + 1] = string.format(...) end
local codec = require("main.src.event_codec")
local udp = require("main.src.udp_events")
local reliable = require("main.src.reliable_udp")

local function wrap(token, packet)
	return string.pack(">c4c4BBc32I2", "7DFP", "SRCU", 2, 0, token, #packet) .. packet
end
local function make_client(state, index)
	local connection = {
		address = "10.0.0." .. index, is_open = true,
		close = function(self) self.is_open = false end,
	}
	local token = string.format("%032d", index)
	local client = {
		warn_limits = {}, hello = true, bound = true, udp_events_ready = true,
		game_address = connection.address, game_port = 20000 + index,
	}
	state.clients[connection] = client
	udp.set_token(state, connection, client, token)
	udp.bind_endpoint(state, connection, client)
	return connection, client, token
end

-- indexes cleared on unbind, reset and removal
do
	local state = { clients_by_token = {}, clients_by_endpoint = {}, udp_backlog = {}, clients = {}, config = { maxEventBytes = 262144, }, }
	local connection, client, token = make_client(state, 1)
	assert(state.clients_by_endpoint["10.0.0.1:20001"] == connection)
	assert(state.clients_by_token[token] == connection)
	assert(udp.has_bound_client(state, "10.0.0.1", 20001))
	assert(udp.has_bound_client(state, "10.0.0.1", 20001.0))
	assert(not udp.has_bound_client(state, "10.0.0.1", 20002))
	assert(not udp.has_bound_client(state, "10.0.0.2", 20001))
	connection.is_open = false
	assert(not udp.has_bound_client(state, "10.0.0.1", 20001), "closed connections are not SRC peers")
	connection.is_open = true
	udp.unbind_endpoint(client)
	assert(next(state.clients_by_endpoint) == nil and not udp.has_bound_client(state, "10.0.0.1", 20001))
	udp.bind_endpoint(state, connection, client)
	client.game_port = 20009 -- Rebinding replaces the old key.
	udp.bind_endpoint(state, connection, client)
	assert(state.clients_by_endpoint["10.0.0.1:20001"] == nil and state.clients_by_endpoint["10.0.0.1:20009"] == connection)
	udp.reset_client(client)
	assert(next(state.clients_by_token) == nil and client.udp_token == nil)
	udp.set_token(state, connection, client, token)
	udp.set_token(state, connection, client, string.rep("b", 32))
	assert(state.clients_by_token[token] == nil and state.clients_by_token[string.rep("b", 32)] == connection)
	udp.remove_client(client)
	state.clients[connection] = nil
	assert(next(state.clients_by_token) == nil and next(state.clients_by_endpoint) == nil)
	local c2, cl2, t2 = make_client(state, 2)
	inbound = { { address = "10.9.9.9", port = 20002, data = wrap(t2, string.pack(">BBI2", 1, 0, 0)), }, }
	udp.on_packet_receive(state)
	assert(#outbound == 0 and cl2.udp_inbox == nil)
end

-- global counter equals the sum over peers
local before = udp.buffered_bytes()
assert(before == udp.buffered_bytes_sum())
do
	local state = { clients_by_token = {}, clients_by_endpoint = {}, udp_backlog = {}, clients = {}, config = {}, }
	local hash = assert(udp.hash_event_name("scale"))
	local clients = {}
	for i = 1, 5 do
		local _, client = make_client(state, i)
		clients[i] = client
		local args = assert(codec.encode(string.rep("x", 1000 * i)))
		for id = 1, 3 do assert(udp.enqueue(client, assert(udp.encode_reliable_event(hash, id, args)))) end
		assert(udp.enqueue_latest(client, assert(udp.encode_reliable_event(hash, 50 + i, assert(codec.encode("l"))))))
		assert(udp.buffered_bytes() == udp.buffered_bytes_sum())
	end
	assert(udp.buffered_bytes() > before)
	udp.reset_client(clients[2])
	assert(udp.buffered_bytes() == udp.buffered_bytes_sum())
	for _, client in ipairs(clients) do udp.remove_client(client) end
	assert(udp.buffered_bytes() == before and udp.buffered_bytes_sum() == before)
end

-- fair share: a greedy client is refused, others still queue
do
	local state = { clients_by_token = {}, clients_by_endpoint = {}, udp_backlog = {}, clients = {}, config = {}, }
	local hash = assert(udp.hash_event_name("share"))
	local big = assert(codec.encode(string.rep("y", 200000)))
	local greedy_conn, greedy = make_client(state, 1)
	local others = {}
	for i = 2, 40 do local _, c = make_client(state, i); udp.tick(c); others[#others + 1] = c end
	udp.tick(greedy)
	local queued, id = 0, 0
	while true do
		id = id + 1
		if not udp.enqueue(greedy, assert(udp.encode_reliable_event(hash, id, big))) then break end
		queued = queued + 1
	end
	-- 40 clients: 16 MiB / 40 = ~419 KiB, greedy stops after 2 messages
	assert(queued >= 1 and queued * 200000 <= 16 * 1024 * 1024 // 40, queued)
	for _, client in ipairs(others) do
		assert(udp.enqueue(client, assert(udp.encode_reliable_event(hash, 1, big))), "other clients are unaffected")
	end
	-- oversize inbound transfer fails only its own session
	local greedy_peer = greedy.udp_reliable
	local fragment = string.pack(">BBI4I2I4I2I2", 1, 1, 900, 1, 262162, 488, 0) .. string.rep("z", 488)
	local sink = others[1]
	local peer = sink.udp_reliable
	reliable.release(peer) -- Start the quiet client from an empty buffer.
	assert(#reliable.receive(peer, fragment, 262162) == 0 and not peer.error, "within its share")
	local hog = reliable.new()
	hog.bytes = 0
	assert(#reliable.receive(hog, fragment, 1000) == 0 and hog.error == "UDP receive budget exhausted")
	for _, c in pairs(state.clients) do udp.remove_client(c) end
	assert(udp.buffered_bytes() == before, udp.buffered_bytes())
end

-- rate limit: over-limit work deferred then released, sustained overload disconnects
do
	local state = { clients_by_token = {}, clients_by_endpoint = {}, udp_backlog = {}, clients = {}, config = { maxEventBytes = 262144, }, }
	local hash = assert(udp.hash_event_name("rate"))
	local flood_conn, flood, flood_token = make_client(state, 1)
	local quiet_conn, quiet, quiet_token = make_client(state, 2)
	local function latest(id) -- Latest-state messages need no accept and ride one datagram each.
		local payload = assert(codec.encode("v"))
		local message = assert(udp.encode_reliable_event(hash, id, payload))
		return string.char(6) .. message
	end
	local function dgram(token, packet, port) return { address = "10.0.0." .. tonumber(token), port = port, data = wrap(token, packet), } end
	local function run_tick(entries)
		inbound = entries
		warnings = {}
		return udp.on_packet_receive(state)
	end
	local flood_entries = {}
	for i = 1, 100 do flood_entries[#flood_entries + 1] = dgram(flood_token, latest(i), 20001) end
	flood_entries[#flood_entries + 1] = dgram(quiet_token, latest(1), 20002)
	local decoded = run_tick(flood_entries)
	local by_client = {}
	for _, entry in ipairs(decoded) do by_client[entry.client] = (by_client[entry.client] or 0) + #entry.messages end
	assert(by_client[quiet] == 1, "quiet client is unaffected by the flood")
	assert((by_client[flood] or 0) <= 32 and (by_client[flood] or 0) >= 1, "events capped by the burst bucket")
	assert(#flood.udp_inbox > 0 or #(flood.udp_pending_messages or {}) > 0, "over-limit work is deferred")
	assert(flood_conn.is_open and state.udp_backlog[flood_conn] == flood)
	-- deferred work drains in order
	local delivered_ids = {}
	for tick = 1, 40 do
		time = tick * 0.05
		for _, entry in ipairs(run_tick({})) do
			if entry.client == flood then
				for _, message in ipairs(entry.messages) do
					assert(message.latest)
					delivered_ids[#delivered_ids + 1] = message.message_id
				end
			end
		end
		if not state.udp_backlog[flood_conn] then break end
	end
	assert(flood_conn.is_open and not state.udp_backlog[flood_conn], "backlog drains without disconnect")
	for i = 2, #delivered_ids do assert(delivered_ids[i] > delivered_ids[i - 1], "deferred events keep order") end
	-- sustained overload > 5 s
	time = 100
	local id = 1000
	local disconnected_at
	for tick = 1, 400 do
		time = 100 + tick * 0.05
		local entries = {}
		for _ = 1, 20 do entries[#entries + 1] = dgram(flood_token, string.pack(">BBI2", 1, 0, 0), 20001) end
		run_tick(entries)
		if not flood_conn.is_open then disconnected_at = time; break end
	end
	assert(disconnected_at and disconnected_at - 100 >= 5 and disconnected_at - 100 < 8, disconnected_at)
	local logged = false
	-- warn_limited prints via log.warn, captured before the final tick
	for _, line in ipairs(warnings) do if line:find("over rate limit", 1, true) then logged = true end end
	assert(logged, "disconnect reason is logged")
	assert(quiet_conn.is_open)
	-- handler flood past the deferral bound disconnects immediately
	local c3, cl3, t3 = make_client(state, 3)
	time = 500
	local next_id, over = 0, false
	for tick = 1, 120 do
		time = 500 + tick * 0.05
		local batch = {}
		for i = 1, 40 do next_id = next_id + 1; batch[i] = dgram(t3, latest(next_id), 20003) end
		run_tick(batch)
		for _, line in ipairs(warnings) do if line:find("backlog exceeded", 1, true) then over = true end end
		if not c3.is_open then break end
	end
	assert(not c3.is_open and over, "event backlog overflow disconnects with a logged reason")
end

-- warnings limited per client and kind
do
	warnings = {}
	local a, b = { warn_limits = {}, }, { warn_limits = {}, }
	for _ = 1, 5 do udp.warn_limited(a, "event_budget", "budget %s", "a") end
	udp.warn_limited(b, "event_budget", "budget %s", "b")
	udp.warn_limited(a, "latest_dropped", "latest %s", "a")
	assert(#warnings == 3, #warnings)
end

-- broadcast passes encoded bytes through
do
	local hash = assert(udp.hash_event_name("broadcast"))
	local encoded = assert(codec.encode("a", 5, true, nil, 2.5, "tail"))
	local decoded = assert(codec.decode_args(encoded))
	local old_way = assert(udp.encode_reliable_event(hash, 77, assert(codec.encode(table.unpack(decoded, 1, decoded.n)))))
	local new_way = assert(udp.encode_reliable_event(hash, 77, encoded))
	assert(old_way == new_way, "decode/re-encode and pass-through produce the same bytes")
	package.path = "./?.lua;" .. package.path
	package.preload["main.json"] = function() return dofile("test/main/json.lua") end
	local network_events = require("main.src.network_events")
	local function bound_client()
		local connection = { address = "192.0.2.1", is_open = true, close = function() end, discard_pending_sends = function() end, }
		local client = {
			hello = true, bound = true, next_event_id = 1, pending_events = {}, pending_results = {}, warn_limits = {},
			game_address = "192.0.2.1", game_port = 1234,
			player = { account = {}, connection = { address = "192.0.2.1", port = 1234, }, },
		}
		udp.reset_client(client)
		return connection, client
	end
	local connection_a, client_a = bound_client()
	local connection_b, client_b = bound_client()
	local state = {
		clients = { [connection_a] = client_a, [connection_b] = client_b, }, config = { maxEventBytes = 262144, },
		event_hashes_by_name = {},
	}
	assert(network_events.emit_client_event(state, nil, "broadcast", hash, encoded, false) == 2)
	local expected = assert(udp.encode_reliable_event(hash, 1, encoded))
	assert(client_a.pending_events[1].bytes == expected and client_b.pending_events[1].bytes == expected,
		"same encoded bytes reach every connection")
end

print("UDP scaling: indexes, byte counter, fair share, rate limits, warning limits and broadcast bytes passed")
