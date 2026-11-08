local file = assert(io.open('main/src/network.lua'))
local source = file:read('*a')
file:close()
local resolve_source = assert(source:match('(local function resolve_client_player_from_hello.-)\nlocal function apply_bound_player'))
local player_list = {}
local env = setmetatable({
    players = {getNonBots = function() return player_list end},
    parse_positive_integer = function(value) local n = tonumber(value); return n and n > 0 and n or nil end,
}, {__index = _G})
local resolve = assert(load(resolve_source .. '\nreturn resolve_client_player_from_hello', 'admission', 't', env))()
local connection = {address = '192.0.2.1'}
local client = {game_address = '192.0.2.1', game_port = 1234}
local state = {clients = {[connection] = client}}
local player = {account = {}, phoneNumber = 42, subRosaID = 7,
    connection = {address = '192.0.2.1', port = 1234}}
player_list[1] = player
assert(resolve(state, connection, {phoneNumber = 42}) == player)
player.account = nil
assert(not resolve(state, connection, {phoneNumber = 42}))
player.account = {}
player.connection.port = 1235
assert(not resolve(state, connection, {phoneNumber = 42}))
player.connection.port = 1234
assert(not resolve(state, connection, {phoneNumber = 43}))
client.game_address = '192.0.2.2'
assert(not resolve(state, connection, {phoneNumber = 42}))
client.game_address = '192.0.2.1'
local handlers = assert(source:match('(local function handle_index_request.-)\nlocal function handle_legacy_event'))
local authorized, sent, queued = false, 0, 0
env.require_hello = function() return client end
env.refresh_client_player_binding = function() return authorized end
env.send_initial_custom_item_sync = function() sent = sent + 1 end
env.send_initial_custom_vehicle_sync = function() sent = sent + 1 end
env.enqueue_frame = function() sent = sent + 1 end
env.bundle_metadata_list = function() return {} end
env.queue_sync_file = function() queued = queued + 1 end
env.queue_sync_bundle = function() queued = queued + 1 end
state.config = {}
local index, file_request, bundle_request = assert(load(handlers .. '\nreturn handle_index_request, handle_file_request, handle_bundle_request', 'handlers', 't', env))()
index(state, connection)
file_request(state, connection, {path = 'x'})
bundle_request(state, connection, {id = 'x'})
assert(client.pending_index_request and sent == 0 and queued == 0)
authorized = true
index(state, connection)
file_request(state, connection, {path = 'x'})
bundle_request(state, connection, {id = 'x'})
assert(not client.pending_index_request and sent == 3 and queued == 2)
print('Sync admission gate passed')
