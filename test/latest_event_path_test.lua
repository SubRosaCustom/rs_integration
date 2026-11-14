-- Run from rs_integration/: lua test/latest_event_path_test.lua
bit32 = { bxor = function(a, b) return (a ~ b) & 0xFFFFFFFF end, band = function(a, b) return (a & b) & 0xFFFFFFFF end }
package.path = "./?.lua;" .. package.path
package.preload["main.json"] = function() return dofile("test/main/json.lua") end
package.loaded["main.src.log"] = { info = function() end, warn = function() end }

local network_events = require("main.src.network_events")
local udp = require("main.src.udp_events")
local codec = require("main.src.event_codec")
local reliable = require("main.src.reliable_udp")

local function new_client()
	local connection = { address = "192.0.2.1", is_open = true, close = function(self) self.is_open = false end, discard_pending_sends = function() end }
	local client = {
		hello = true, bound = true, next_event_id = 1, pending_events = {}, pending_results = {},
		warn_limits = {}, game_address = "192.0.2.1", game_port = 1234,
		player = { account = {}, connection = { address = "192.0.2.1", port = 1234 } },
	}
	udp.reset_client(client)
	return connection, client
end

local connection, client = new_client()
local state = {
	clients = { [connection] = client }, config = { maxEventBytes = 262144 }, tick = 0,
	event_hashes_by_name = {}, event_handlers = {}, event_handlers_by_hash = {},
}
local hash = assert(udp.hash_event_name("camera"))
local args = assert(codec.encode(1, 2, 3))

-- latest events carry no pending result or receipt; a newer one replaces the older one
assert(network_events.emit_client_event(state, nil, "camera", hash, args, true) == 1)
assert(next(client.pending_events) == nil and next(client.pending_results) == nil, "latest event must not be tracked for retry")
assert(network_events.emit_client_event(state, nil, "camera", hash, args, true) == 1)
reliable.advance(client.udp_reliable, 0, true)
reliable.next(client.udp_reliable) -- startup size probe
local receiver = reliable.new()
local deliveries = reliable.receive(receiver, assert(reliable.next(client.udp_reliable)))
assert(#deliveries == 1 and deliveries[1].latest and deliveries[1].id == 2, "only the newest latest event is delivered")
assert(#reliable.take_receipts(receiver) == 0, "latest events are not acknowledged")

-- ordinary events are tracked and ids are per client
assert(network_events.emit_client_event(state, nil, "normal", hash, args, false) == 1)
assert(client.pending_events[3] and next(client.pending_results) == nil)
local connection2, client2 = new_client()
state.clients[connection2] = client2
assert(network_events.emit_client_event(state, nil, "normal", hash, args, false) == 2)
assert(client2.pending_events[1] and client2.next_event_id == 2 and client.next_event_id == 5)

-- an exhausted id space refuses further events for that client only
client.next_event_id = 0xFFFFFFFF + 1
state.clients[connection2] = nil
local n = network_events.emit_client_event(state, nil, "normal", hash, args, false); assert(n == 0, tostring(n))

-- inbound latest events reach handlers without results or receipts, and authorization still applies
local got
network_events.on_client_event(state, "camera", function(_, a, b, c) got = { a, b, c } end)
local message = { kind = 1, latest = true, event_hash = hash, args = { n = 3, 7, 8, 9 } }
network_events.on_udp_datagram(state, { connection = connection, client = client, messages = { message } })
assert(got and got[1] == 7 and got[3] == 9, "latest event must reach the handler")
assert(next(client.pending_results) == nil)
got = nil
client.player.account = nil
network_events.on_udp_datagram(state, { connection = connection, client = client, messages = { message } })
assert(got == nil, "unauthorized player must not reach handlers")

print("latest events: queue, replacement, no receipts, dispatch and authorization passed")
