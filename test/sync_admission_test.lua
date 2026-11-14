-- Run from rs_integration/: lua test/sync_admission_test.lua
bit32 = { bxor = function(a, b) return (a ~ b) & 0xFFFFFFFF end, band = function(a, b) return (a & b) & 0xFFFFFFFF end }
package.path = "./?.lua;" .. package.path
package.preload["main.json"] = function() return dofile("test/main/json.lua") end
package.loaded["main.src.log"] = { info = function() end, warn = function() end }

-- payload and transfer producers are the observable outputs of admission
local sent, queued = 0, 0
package.loaded["main.src.index_response"] = { bytes = function() sent = sent + 1; return "index" end }
package.loaded["main.src.network_sync_payload"] = {
	send_initial_custom_item_sync = function() sent = sent + 1 end,
	send_initial_custom_vehicle_sync = function() sent = sent + 1 end,
}
package.loaded["main.src.network_transfer"] = {
	queue_sync_file = function() queued = queued + 1 end,
	queue_sync_bundle = function() queued = queued + 1 end,
}

local session = require("main.src.network_session")
local handshake = require("main.src.network_handshake")

local player_list = {}
players = { getNonBots = function() return player_list end }
local connection = { address = "192.0.2.1", is_open = true, close = function() end, discard_pending_sends = function() end }
local client = { send_queue = {}, hello = true, game_address = "192.0.2.1", game_port = 1234, hello_payload = { phoneNumber = 42 } }
local state = {
	clients = { [connection] = client }, config = {}, sync_generation = 1,
	clients_by_endpoint = {}, clients_by_token = {}, udp_backlog = {},
}
local player = { account = {}, phoneNumber = 42, subRosaID = 7, connection = { address = "192.0.2.1", port = 1234 } }
player_list[1] = player

local function resolves(hello)
	return session.resolve_client_player_from_hello(state, connection, hello) == player
end
assert(resolves({ phoneNumber = 42 }), "matching account-backed player resolves")
player.account = nil
assert(not resolves({ phoneNumber = 42 }), "player without an account is not admitted")
player.account = {}
player.connection.port = 1235
assert(not resolves({ phoneNumber = 42 }), "mismatched game port is not admitted")
player.connection.port = 1234
assert(not resolves({ phoneNumber = 43 }), "mismatched phone number is not admitted")
client.game_address = "192.0.2.2"
assert(not resolves({ phoneNumber = 42 }), "mismatched game address is not admitted")
client.game_address = "192.0.2.1"

-- requests before native admission send nothing; they are served once the player is bound
player.account = nil
handshake.handle_frame(state, connection, { type = "INDEX_REQ" })
handshake.handle_frame(state, connection, { type = "FILE_REQ", payload = { path = "x" } })
handshake.handle_frame(state, connection, { type = "BUNDLE_REQ", payload = { id = "x" } })
assert(sent == 0 and queued == 0, "unadmitted client must receive no content")
player.account = {}
handshake.handle_frame(state, connection, { type = "INDEX_REQ" })
handshake.handle_frame(state, connection, { type = "FILE_REQ", payload = { path = "x" } })
handshake.handle_frame(state, connection, { type = "BUNDLE_REQ", payload = { id = "x" } })
assert(sent == 3 and queued == 2 and #client.send_queue == 1, "admitted client receives the index and queued content")
print("Sync admission gate passed")
