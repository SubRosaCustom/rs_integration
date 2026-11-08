-- Run from rs_integration: lua test/tests/refresh_cancellation.lua
-- Uses the real worker handlers and main-thread transport with deterministic sockets.
package.loaded["main.json"] = dofile("test/main/json.lua")
package.loaded.libminiz = {}
os.realClock = function() return 0 end
local json = require("main.json")
local codec = require("main.src.threaded_tcp_codec")
local transport = require("main.src.threaded_tcp_server")

local file = assert(io.open("main/src/threaded_tcp_worker.lua", "r"))
local source = file:read("*a")
file:close()
source = source:sub(1, assert(source:find("while not sleep", 1, true)) - 1)
source = source .. [[
return {
    handle = handle_command, connections = connections,
    fill = fill_stream_queue, send = send_to_client,
}
]]

local function pair()
	local commands, events, wire = {}, {}, {}
	local worker = assert(load(source))()
	sendMessage = function(message) events[#events + 1] = message end
	Worker = { new = function()
		return {
			sendMessage = function(_, message) commands[#commands + 1] = message end,
			receiveMessage = function() return table.remove(events, 1) end,
		}
	end }
	local server = transport.new(27015)
	commands = {} -- Binding is outside this deterministic socket test.
	events[#events + 1] = codec.encode(codec.LISTENING, 0, 27015)
	events[#events + 1] = codec.encode(codec.ACCEPTED, 1, 27016, "127.0.0.1")
	server:poll()
	local connection = assert(server:accept())
	local socket = {
		send = function(_, bytes) wire[#wire + 1] = bytes; return #bytes end,
	}
	local remote = { socket = socket, send_queue = {},
		send_stats = { calls = 0, blocked = 0, bytes = 0, partial = 0, }, }
	worker.connections[1] = remote
	return {
		server = server, connection = connection, remote = remote, worker = worker,
		commands = function()
			while #commands > 0 do worker.handle(assert(codec.decode(table.remove(commands, 1)))) end
		end,
		send = function(budget) assert(worker.send(1, remote, budget or 10 * 1024 * 1024)) end,
		wire = function() return table.concat(wire) end,
		event = function(kind, value) events[#events + 1] = codec.encode(kind, 1, value) end,
	}
end

local notice = json.encode({ type = "REFRESH_NOTICE", payload = { syncGeneration = 2 } }) .. "\n"
local frame = codec.encode_binary_frame("FILE_CHUNK", string.rep("x", 400000))

-- Cancel main-owned frames across SEND fragment boundaries, whether their first
-- fragment is partially written, entirely written, or never started.
for _, transmitted in ipairs({ 0, 17, 262144 }) do
	for _, submit_tail in ipairs({ false, true }) do
		local p = pair()
		local accepted = p.connection:send(frame)
		assert(accepted == 262144)
		if submit_tail then assert(p.connection:send(frame:sub(accepted + 1)) == #frame - accepted) end
		p.commands()
		p.send(transmitted)
		p.connection:discard_pending_sends(not submit_tail and frame:sub(accepted + 1) or nil)
		assert(p.connection:send(notice) == #notice)
		p.commands()
		p.send()
		p.server:poll()
		assert(p.wire() == (transmitted > 0 and frame or "") .. notice)
		assert(p.connection.pending_send_bytes == 0 and p.server.pending_send_messages == 0)
		assert(not p.remote.sending_frame_id)
	end
end

-- If an earlier complete frame is on the wire, discard a later frame's tail.
do
	local p = pair()
	local earlier = '{"type":"INDEX_RES"}\n'
	p.connection:send(earlier)
	local accepted = p.connection:send(frame)
	p.commands(); p.send(5)
	p.connection:discard_pending_sends(frame:sub(accepted + 1))
	p.connection:send(notice)
	p.commands(); p.send(); p.server:poll()
	assert(p.wire() == earlier .. notice)
	assert(p.connection.pending_send_bytes == 0 and p.server.pending_send_messages == 0)
end

-- A repeated refresh must also preserve a tail retained by an earlier cancel.
do
	local p = pair()
	local accepted = p.connection:send(frame)
	p.commands(); p.send(17)
	p.connection:discard_pending_sends(frame:sub(accepted + 1))
	p.connection:send(notice)
	p.commands()
	p.connection:discard_pending_sends()
	p.connection:send(notice)
	p.commands(); p.send(); p.server:poll()
	assert(p.wire() == frame .. notice)
	assert(p.connection.pending_send_bytes == 0 and p.server.pending_send_messages == 0)
end

-- A stream's partially transmitted binary frame finishes before the notice.
-- Its other queued frames, unqueued archive bytes, and BUNDLE_END are discarded.
for _, transmitted in ipairs({ 0, 17 }) do
	local p = pair()
	p.remote.stream = { id = "old", archive = string.rep("z", 500000), offset = 1,
		end_frame = '{"type":"BUNDLE_END"}\n', generation = 1, }
	p.worker.fill(p.remote)
	assert(#p.remote.send_queue == 4)
	local first = p.remote.send_queue[1].bytes
	p.send(transmitted)
	p.connection:discard_pending_sends()
	p.connection:send(notice)
	p.commands()
	assert(p.remote.stream == nil)
	p.worker.fill(p.remote); p.send(); p.server:poll()
	assert(p.wire() == (transmitted > 0 and first or "") .. notice)
end

-- Stream chunks cannot interleave a main frame awaiting another SEND fragment.
do
	local p = pair()
	local accepted = p.connection:send(frame)
	p.commands()
	p.remote.send_queue[#p.remote.send_queue + 1] = {
		bytes = "stream frame", offset = 1, main_owned = false,
	}
	p.send()
	assert(p.wire() == frame:sub(1, accepted))
	p.connection:send(frame:sub(accepted + 1))
	p.commands(); p.send()
	assert(p.wire() == frame .. "stream frame")
end

-- Real worker completion events carry the generation assigned by the server.
do
	local p = pair()
	p.worker.handle({ kind = codec.CACHE_BUNDLE, payload = string.pack(">I2", 3) .. "old" .. "ZIP" })
	assert(p.connection:start_bundle("old", "bundle end"))
	p.commands(); p.worker.fill(p.remote); p.send(); p.server:poll()
	assert(not p.connection.stream_active)
end

-- Delayed completions from canceled streams must not finish their replacement.
do
	local p = pair()
	assert(p.connection:start_bundle("old", "end"))
	local old_generation = p.connection.stream_generation
	p.connection:discard_pending_sends()
	assert(p.connection:start_partial("new", { "new.lua" }))
	p.event(codec.STREAM_DONE, old_generation)
	p.server:poll()
	assert(p.connection.stream_active)
	p.event(codec.STREAM_DONE, p.connection.stream_generation)
	p.server:poll()
	assert(not p.connection.stream_active)
end

-- Both bound and valid pre-bind HELLO clients reset; raw connections do not.
package.loaded["main.src.event_codec"] = {}
package.loaded["main.src.udp_events"] = {
	tick = function(client) client.udp_tick_called = true end,
	reset_client = function() end,
}
local network = require("main.src.network")
local clients = {}
local state = { clients = clients, sync_generation = 3, runtime_id = "runtime",
	manifest_hash = "new scope", config = { disallowedPaths = {}, disableClientTiremarks = true }, }
local function add_client(hello, bound, open, valid)
	local connection = { is_open = open, address = "127.0.0.1" }
	function connection:discard_pending_sends(tail) self.discarded = true; self.tail = tail end
	function connection:close() self.is_open = false end
	local client = { hello = hello, bound = bound, send_queue = { "old partial frame", "obsolete" },
		send_offset = 5, pending_bundle_requests = { "old" }, pending_file_requests = { "old" },
		active_bundle_transfer = {}, active_file_transfer = { file = {
			close = function() connection.file_closed = true end,
		} }, udp_events_ready = true, ready_generation = 3,
		ready_manifest_hash = "old scope", pending_events = { "keep" }, }
	if bound then
		client.game_address = "127.0.0.1"
		client.game_port = 27071
		client.player = { isBot = false, account = {},
			connection = { address = valid and "127.0.0.1" or "other", port = 27071 }, }
	end
	clients[connection] = client
	return connection, client
end
local pending, pending_client = add_client(true, false, true)
local bound, bound_client = add_client(true, true, true, true)
local raw, raw_client = add_client(false, false, true)
local closed = add_client(true, false, false)
local invalid = add_client(true, true, true, false)
network.refresh(state, "disabled-plugin")
for _, connection in ipairs({ pending, bound }) do
	local client = clients[connection]
	assert(connection.discarded and connection.tail == "partial frame" and connection.file_closed)
	assert(#client.pending_bundle_requests == 0 and #client.pending_file_requests == 0)
	assert(not client.active_bundle_transfer and not client.active_file_transfer)
	assert(client.send_offset == 1 and #client.send_queue == 1)
	local message = json.decode(client.send_queue[1])
	assert(message.type == "REFRESH_NOTICE" and message.payload.syncGeneration == 4)
	assert(message.payload.disableClientTiremarks == true)
	assert(message.payload.manifestHash == "new scope" and message.payload.pluginReload == "disabled-plugin")
	assert(client.sync_state == "capable" and client.generation == 4)
	assert(client.ready_generation == 0 and not client.ready_manifest_hash and not client.udp_events_ready)
	assert(client.pending_events[1] == "keep" and client.udp_tick_called)
end
assert(not raw.discarded and #raw_client.send_queue == 2)
assert(not closed.discarded and not invalid.is_open)
assert(require("main.src.protocol").VERSION == 10)

state.config.disableClientTiremarks = false
network.refresh(state)
for _, connection in ipairs({ pending, bound }) do
	local message = json.decode(clients[connection].send_queue[1])
	assert(message.payload.disableClientTiremarks == false)
end

print("refresh cancellation, TCP frame preservation, and tiremark policy checks passed")
