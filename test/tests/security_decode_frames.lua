package.path = './?.lua;' .. package.path
package.preload['main.json'] = function() return dofile('test/main/json.lua') end
package.loaded['main.src.log'] = {info = function() end, warn = function() end, warn_limited = function() end}
server = {port = 0}
os.realClock = os.clock
bit32 = {bxor = function(a, b) return (a ~ b) & 0xFFFFFFFF end, band = function(a, b) return (a & b) & 0xFFFFFFFF end}

local codecs = {dofile('main/src/event_codec.lua'), dofile('../core/main/eventCodec.lua')}
for _, codec in ipairs(codecs) do
	for _, value in ipairs({42, 1.5, 'hello', codec.blob('hello')}) do
		local encoded = assert(codec.encode(value))
		for length = 0, #encoded - 1 do
			local ok, result, reason = pcall(codec.decode, encoded:sub(1, length))
			assert(ok and result == nil and type(reason) == 'string', 'truncated value must return an error')
		end
		assert(codec.decode(encoded))
	end
end

local network = require('main.src.network')
local transfer = require('main.src.network_transfer')
local limit = require('main.src.tcp_connection_limits').PRE_HELLO_MAX_BUFFER_BYTES

-- drives the real accept/read path; the fake connection is the native socket boundary
local function run(chunks)
	local connection = {is_open = true, address = '192.0.2.1', pending_send_bytes = 0,
		take_send_stats = function() end, discard_pending_sends = function() end}
	function connection:receive() return table.remove(chunks, 1) end
	function connection:send(data) return #data end
	function connection:close() self.is_open = false end
	local accepted = false
	local state = {clients = {}, tick = 0,
		config = {readSize = 1 << 16, maxReadBytesPerTick = 1 << 26, fileChunkSize = 1024,
			maxFileChunksPerTick = 1, maxQueuedSendFrames = 8, maxSendBytesPerTick = 1 << 20},
		tcp_server = {is_open = true, set_snapshot = function() return true end, poll = function() end,
			accept = function() if accepted then return nil end accepted = true return connection end}}
	network.logic_step(state)
	return connection
end
assert(run({string.rep('a', limit - 1), '\n'}).is_open, 'frame at the limit is accepted')
assert(not run({string.rep('a', limit)}).is_open, 'unterminated data over the limit closes')
assert(not run({string.rep('a', limit / 2), string.rep('b', limit / 2) .. '\n'}).is_open, 'oversized frame split across reads closes')
assert(run({'{}\n{}\n'}).is_open, 'several small frames are accepted')
for _, codec in ipairs(codecs) do
	local nils = {}
	local ok_blob = assert(codec.encode(table.unpack(nils, 1, 255)))
	local values, count = codec.decode(ok_blob)
	assert(values and count == 255, 'cap must be accepted')
	assert(codec.encode(table.unpack(nils, 1, 256)) == nil, 'encoder must refuse over cap')
	local over = 'SRCA' .. string.char(1) .. string.pack('>I4', 256) .. string.rep('\0', 256)
	local result, reason = codec.decode(over)
	assert(result == nil and reason == 'too many arguments', 'decoder must reject over cap')
	local huge = 'SRCA' .. string.char(1) .. string.pack('>I4', 9000) .. string.rep('\0', 9000)
	local args, args_reason = codec.decode_args(huge)
	assert(args == nil and args_reason == 'too many arguments')
end
print('Malformed event values and TCP frame limits passed')

local connection = {is_open = true}
function connection:close() self.is_open = false end
local client = {pending_file_requests = {}, pending_bundle_requests = {}, send_queue = {}}
local state = {clients = {[connection] = client}, scripts_by_path = {}, asset_files_by_path = {}, sync_bundles_by_id = {}}
for i = 1, 33 do
	local name = 'file' .. i .. '.lua'
	state.scripts_by_path[name] = true
	transfer.queue_sync_file(state, connection, name)
end
assert(not connection.is_open and #client.pending_file_requests == 32, 'pending file requests are capped')
connection.is_open = true
transfer.queue_sync_bundle(state, connection, 'partial', {})
assert(not connection.is_open, 'empty partial bundle request closes the connection')
print('Pending sync request limits passed')
