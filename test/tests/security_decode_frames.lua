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

local file = assert(io.open('main/src/network.lua'))
local source = file:read('*a')
file:close()
local functions = assert(source:match('(local function process_buffered_frames.-)\nlocal function process_pending_retries'))
local env = setmetatable({MAX_TCP_FRAME_BYTES = 32, log = {warn = function() end},
	client_id = function() return 'test' end, decode_json = function() return {} end,
	handle_frame = function() end, enqueue_frame = function() end}, {__index = _G})
local process = assert(load(functions .. '\nreturn process_client_reads', 'network framing', 't', env))()
local function run(chunks)
	local connection = {is_open = true}
	function connection:receive() return table.remove(chunks, 1) end
	function connection:close() self.is_open = false end
	local client = {receive_buffer = ''}
	local state = {clients = {[connection] = client}, config = {readSize = 16, maxReadBytesPerTick = 1024}}
	process(state, connection)
	return connection, client
end
assert(run({string.rep('a', 31), '\n'}).is_open)
assert(not run({string.rep('a', 32)}).is_open)
assert(not run({string.rep('a', 20), string.rep('b', 12) .. '\n'}).is_open)
assert(run({'{}\n{}\n'}).is_open)
print('Malformed event values and TCP frame limits passed')

local queue_source = assert(source:match('(local function queue_sync_file.-)\nlocal function start_next_file_transfer'))
env.MAX_PENDING_SYNC_REQUESTS = 32
env.MAX_PARTIAL_BUNDLE_PATHS = 4096
env.sync_paths = {is_safe_script = function() return true end, is_safe_asset = function() return true end}
local queue_file, queue_bundle = assert(load(queue_source .. '\nreturn queue_sync_file, queue_sync_bundle', 'sync queues', 't', env))()
local connection = {is_open = true}
function connection:close() self.is_open = false end
local client = {pending_file_requests = {}, pending_bundle_requests = {}}
local state = {clients = {[connection] = client}, scripts_by_path = {}, asset_files_by_path = {}, sync_bundles_by_id = {}}
for i = 1, 33 do
	local name = tostring(i)
	state.scripts_by_path[name] = true
	queue_file(state, connection, name)
end
assert(not connection.is_open and #client.pending_file_requests == 32)
connection.is_open = true
queue_bundle(state, connection, 'partial', {})
assert(not connection.is_open)
print('Pending sync request limits passed')
