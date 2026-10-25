-- Standalone host test: lua test/scoped_assets_test.lua (Lua 5.4 or LuaJIT).
package.path = './?.lua;' .. package.path
package.preload['main.json'] = function() return dofile('test/main/json.lua') end
local files, dirs, links = {}, {}, {}
-- YAML parsing is supplied by RosaServerCore; mock only that external boundary.
local yaml_configs = {
	['defaultGameMode: active'] = { defaultGameMode = 'active' },
	['defaultGameMode: active.lua'] = { defaultGameMode = 'active.lua' },
}
package.preload['main.yaml'] = function() return {
	parse = function(source) return assert(yaml_configs[source], 'invalid YAML') end,
} end
local function add(path, bytes)
	files[path] = bytes
	local parent = path:match('^(.*)/[^/]+$')
	while parent do dirs[parent] = true; parent = parent:match('^(.*)/[^/]+$') end
end
local function resolve(path)
	for from, to in pairs(links) do
		if path == from or path:sub(1, #from + 1) == from .. '/' then
			path = to .. path:sub(#from + 1)
			break
		end
	end
	if files[path] or dirs[path] then return '/fixture/' .. path end
end
package.preload.ffi = function()
	return { cdef = function() end, string = function(s) return s end,
		C = { realpath = resolve, free = function() end } }
end
local real_open = io.open
io.open = function(path, mode)
	if mode ~= 'rb' then return real_open(path, mode) end
	local bytes = files[path]
	if not bytes then return nil end
	return { read = function() return bytes end, close = function() end }
end
os.listDirectory = function(root)
	local entries, seen = {}, {}
	local function visit(path, is_directory)
		local parent, name = path:match('^(.*)/([^/]+)$')
		if parent == root and not seen[name] then
			entries[#entries + 1] = { name = name, isDirectory = is_directory }
			seen[name] = true
		end
	end
	for path in pairs(dirs) do visit(path, true) end
	for path in pairs(files) do visit(path, false) end
	-- Deliberately reverse order to verify stable output.
	table.sort(entries, function(a, b) return a.name > b.name end)
	return entries
end
os.getLastWriteTime = function() return 1 end
os.createDirectory = function(path) dirs[path] = true end
if not bit32 then
	-- Load arithmetic only on 5.4; LuaJIT uses its native bit module.
	local ok, bit = pcall(require, 'bit')
	if ok then bit32 = bit else bit32 = assert(load([[return {
		band = function(a,b) return a & b end,
		bxor = function(a,b) return a ~ b end,
		rshift = function(a,b) return a >> b end,
		bor = function(...) local n = 0; for i = 1, select('#', ...) do n = n | select(i, ...) end; return n end }]]))() end
end
crypto = { sha256 = function(bytes) return 'hash:' .. bytes end }
package.preload.libminiz = function()
	miniz = { createZip = function(inputs)
		local sorted = {}; for name in pairs(inputs) do sorted[#sorted + 1] = name end
		table.sort(sorted)
		local result = {}; for _, name in ipairs(sorted) do result[#result + 1] = name .. ':' .. inputs[name] end
		return table.concat(result, '|')
	end }
end
hook, server = { persistentMode = 'active' }, { loadedLevel = '' }
local snapshot = require('main.src.sync_snapshot')
local scope = require('main.src.client_scope')
local paths = require('main.src.sync_paths')
local state = { config = { clientRoot = 'clientroot' } }
add('clientroot/scripts/plugins/zeta.lua', 'return true')
add('clientroot/scripts/plugins/alpha/init.lua', 'return true')
add('clientroot/scripts/plugins/disabled.lua', 'return true')
add('clientroot/scripts/modes/not_a_plugin.lua', 'return true')
add('clientroot/scripts/disabledPlugins.json', '["disabled"]')
add('clientroot/assets/modes/active/data/model/mode.cmo', 'active')
add('clientroot/assets/modes/other/data/model/other.cmo', 'inactive')
add('clientroot/assets/plugins/alpha/data/model/alpha.cmo', 'alpha')
add('clientroot/assets/plugins/zeta/data/model/zeta.cmo', 'zeta')
add('clientroot/assets/plugins/disabled/data/model/disabled.cmo', 'disabled')
add('clientroot/assets/plugins/not_a_plugin/not.wav', 'mode is not plugin')
add('clientroot/assets/loose.wav', 'loose')
add('data/custom.sbv', 'independent vehicle')
assert(table.concat(scope.enabled(state.config), ',') == 'alpha,zeta')
snapshot.discover(state)
assert(#state.asset_files == 4)
assert(state.asset_paths_folded['data/model/mode.cmo'] == 'data/model/mode.cmo')
assert(state.asset_files_by_path['data/model/mode.cmo'])
assert(state.asset_files_by_path['data/model/alpha.cmo'])
assert(not state.asset_files_by_path['loose.wav'])
hook.persistentMode = 'other'
snapshot.discover(state)
assert(not state.asset_files_by_path['data/model/mode.cmo'])
assert(not state.asset_paths_folded['data/model/mode.cmo'])
assert(state.asset_paths_folded['data/model/other.cmo'] == 'data/model/other.cmo')
assert(state.asset_files_by_path['data/model/other.cmo'])
hook.persistentMode = 'active'
snapshot.discover(state)
local hash = state.manifest_hash
snapshot.discover(state); assert(state.manifest_hash == hash)
-- Directory/entry read errors must retain the previous published snapshot.
local saved_list = os.listDirectory
os.listDirectory = function(root)
	if root == 'clientroot/scripts/plugins' then error('permission denied') end
	return saved_list(root)
end
local valid_assets, valid_hash = state.asset_files, state.manifest_hash
assert(not pcall(snapshot.discover, state))
assert(state.asset_files == valid_assets and state.manifest_hash == valid_hash)
os.listDirectory = saved_list
local saved_read = paths.read_file
paths.read_file = function(path)
	if path == 'clientroot/scripts/plugins/zeta.lua' then return nil end
	return saved_read(path)
end
assert(not pcall(snapshot.discover, state))
assert(state.asset_files == valid_assets and state.manifest_hash == valid_hash)
paths.read_file = saved_read
-- The fallback comes from the captured client config, and server mode wins.
hook.persistentMode = ''
add('clientroot/scripts/config.yml', 'defaultGameMode: active')
snapshot.discover(state)
assert(state.server_persistent_mode == '' and state.persistent_mode == 'active')
assert(state.asset_files_by_path['data/model/mode.cmo'])
files['clientroot/scripts/config.yml'] = 'defaultGameMode: active.lua'
snapshot.discover(state)
assert(state.persistent_mode == 'active' and state.server_persistent_mode == '')
hook.persistentMode = 'other'
snapshot.discover(state)
assert(state.persistent_mode == 'other' and state.server_persistent_mode == 'other')
assert(state.asset_files_by_path['data/model/other.cmo'])
hook.persistentMode = ''
valid_assets, valid_hash = state.asset_files, state.manifest_hash
files['clientroot/scripts/config.yml'] = 'invalid YAML'
assert(not pcall(snapshot.discover, state))
assert(state.asset_files == valid_assets and state.manifest_hash == valid_hash)
files['clientroot/scripts/config.yml'] = nil
snapshot.discover(state)
assert(state.persistent_mode == '' and not state.asset_files_by_path['data/model/mode.cmo'])
hook.persistentMode = 'active'
snapshot.discover(state)
print('plugin I/O rollback and default-mode asset checks passed')

-- Missing/empty roots never fall back to a broad scan.
hook.persistentMode = 'missing'
files['clientroot/scripts/disabledPlugins.json'] = '["alpha", "zeta", "disabled"]'
snapshot.discover(state); assert(#state.asset_files == 1)
files['clientroot/scripts/disabledPlugins.json'] = '["disabled"]'
snapshot.discover(state); assert(#state.asset_files == 3)
-- A matching logical path is deduplicated; conflicting bytes abort atomically.
add('clientroot/assets/plugins/zeta/data/model/alpha.cmo', 'alpha')
snapshot.discover(state); assert(#state.asset_files == 3)
local previous, previous_hash = state.asset_files, state.manifest_hash
files['clientroot/assets/plugins/zeta/data/model/alpha.cmo'] = 'conflict'
assert(not pcall(snapshot.discover, state))
assert(state.asset_files == previous and state.manifest_hash == previous_hash)
files['clientroot/assets/plugins/zeta/data/model/alpha.cmo'] = nil
-- Scope input rejects traversal and malformed disable files without publishing.
assert(snapshot.normalize_persistent_mode('../active') == '')
assert(snapshot.normalize_persistent_mode('modes/active') == '')
assert(not scope.valid_owner('bad/name'))
assert(not paths.is_safe_asset('C:/file.wav'))
assert(not paths.is_safe_asset('data/../file.wav'))
assert(not paths.is_safe_asset('data/\0file.wav'))
files['clientroot/scripts/disabledPlugins.json'] = '{}'
assert(not pcall(snapshot.discover, state))
files['clientroot/scripts/disabledPlugins.json'] = '["../alpha"]'
assert(not pcall(snapshot.discover, state))
files['clientroot/scripts/disabledPlugins.json'] = '[null,"disabled"]'
assert(scope.read_disabled(state.config).disabled)
-- Existing broken/unreadable disable entries are not mistaken for missing lists.
links['clientroot/scripts/disabledPlugins.json'] = 'nonexistent'
assert(not pcall(snapshot.discover, state))
links['clientroot/scripts/disabledPlugins.json'] = nil
-- Symlinked ownership roots and nested directory/file escapes are excluded.
links['clientroot/assets/plugins/alpha'] = 'elsewhere'
dirs.elsewhere = true
snapshot.discover(state); assert(not state.asset_files_by_path['data/model/alpha.cmo'])
links['clientroot/assets/plugins/alpha'] = nil
links['clientroot/assets/plugins/alpha/data'] = 'elsewhere'
snapshot.discover(state); assert(not state.asset_files_by_path['data/model/alpha.cmo'])
links['clientroot/assets/plugins/alpha/data'] = nil
links['clientroot/assets/plugins/alpha/data/model/alpha.cmo'] = 'data/custom.sbv'
snapshot.discover(state); assert(not state.asset_files_by_path['data/model/alpha.cmo'])
add('data/custommap/city2.sbc', 'independent map')
add('data/unselectedmap/city2.sbc', 'unselected map')
server.loadedLevel = 'custommap'
snapshot.discover(state)
assert(state.sync_bundles_by_id.map)
assert(state.asset_files_by_path['data/custommap/city2.sbc'])
assert(not state.asset_files_by_path['data/unselectedmap/city2.sbc'])
server.loadedLevel = ''
print('scoped assets: selected owners, toggles, stable paths, collisions, traversal and symlinks passed')

-- Optional content watching includes assets and the JSON disable list, and catches
-- newly-created owner subdirectories when its watches are reconciled.
package.loaded['main.src.log'] = { info = function() end }
local events, watches, watch_calls = {}, {}, {}
FILE_WATCH_MODIFY, FILE_WATCH_CREATE, FILE_WATCH_DELETE = 1, 2, 4
FILE_WATCH_MOVE, FILE_WATCH_DELETE_SELF, FILE_WATCH_MOVE_SELF = 8, 16, 32
local watcher_instances = 0
FileWatcher = { new = function()
	watcher_instances = watcher_instances + 1
	return {
	addWatch = function(_, path, mask)
		watches[path] = mask
		watch_calls[path] = (watch_calls[path] or 0) + 1
	end,
	receiveEvent = function() return table.remove(events, 1) end,
} end }
local watcher = require('main.src.watcher')
state.config.autoRefreshEnabled = true
state.config.autoRefreshDebounceTicks = 2
state.tick = 0
watcher.ensure(state)
local refreshes = 0
local function refreshed() refreshes = refreshes + 1 end
events[1] = { name = 'disabledPlugins.json' }
watcher.process(state, refreshed)
state.tick = 2; watcher.process(state, refreshed)
assert(refreshes == 1)
events[1] = { name = 'asset.wav' }
watcher.process(state, refreshed)
state.tick = 4; watcher.process(state, refreshed)
assert(refreshes == 2)
add('clientroot/assets/plugins/zeta/new/nested/new.wav', 'new')
state.tick = 60; watcher.ensure(state)
assert(watches['clientroot/assets/plugins/zeta/new/nested'])
state.tick = 62; watcher.process(state, refreshed)
assert(refreshes == 3)
local mask = watches['clientroot/assets/plugins/zeta']
for _, event_mask in ipairs({ FILE_WATCH_CREATE, FILE_WATCH_DELETE, FILE_WATCH_MOVE }) do
	assert(bit32.band(mask, event_mask) == event_mask)
	state.tick = state.tick + 1
	local previous_instances = watcher_instances
	local previous_calls = watch_calls['clientroot/assets/plugins/zeta/new/nested']
	-- A rename has a temporary filename, not necessarily a supported asset suffix.
	events[1] = { name = 'save.tmp', mask = event_mask }
	watcher.process(state, refreshed)
	assert(watcher_instances == previous_instances + 1)
	assert(watch_calls['clientroot/assets/plugins/zeta/new/nested'] == previous_calls + 1)
	local before_refresh = refreshes
	state.tick = state.tick + 2
	watcher.process(state, refreshed)
	assert(refreshes == before_refresh + 1)
end
print('scoped content watcher create/delete/rename checks passed')

-- Automatic refresh rejection must back off and return normally, leaving the
-- main Logic hook free to service existing network connections.
local init_file = assert(real_open('main/src/init.lua', 'r'))
local init_source = init_file:read('*a'); init_file:close()
-- A client fallback differs from the raw server mode without causing a refresh each tick.
local mode_first = assert(init_source:find('local normalized_persistent_mode = ', 1, true))
local mode_last = assert(init_source:find('local normalized_loaded_level = ', mode_first, true))
local mode_check = assert((loadstring or load)('local state, hook, sync_snapshot, refresh_automatically, log = ...\n' ..
	init_source:sub(mode_first, mode_last - 1)))
local mode_refreshes = 0
mode_check({ server_persistent_mode = '', persistent_mode = 'active' }, { persistentMode = '' }, snapshot,
	function() mode_refreshes = mode_refreshes + 1; return true end, { info = function() end })
assert(mode_refreshes == 0)
mode_check({ server_persistent_mode = '', persistent_mode = 'active' }, { persistentMode = 'other' }, snapshot,
	function() mode_refreshes = mode_refreshes + 1; return true end, { info = function() end })
assert(mode_refreshes == 1)

local first = assert(init_source:find('local function refresh_automatically()', 1, true))
local last = assert(init_source:find('\nlocal function disable_runtime', first, true))
local compile = loadstring or load
local load_helper = assert(compile('local state, refresh_now, log = ...\n' ..
	init_source:sub(first, last - 1) .. '\nreturn refresh_automatically'))
local probe, attempts, logs, fail = { tick = 1 }, 0, 0, true
local auto_refresh = load_helper(probe, function()
	attempts = attempts + 1
	if fail then error('collision') end
end, { info = function() logs = logs + 1 end })
assert(not auto_refresh() and attempts == 1 and logs == 1)
probe.tick = 2; assert(not auto_refresh() and attempts == 1)
probe.tick = 61; assert(not auto_refresh() and attempts == 2 and logs == 1)
fail = false; probe.tick = 121
assert(auto_refresh() and attempts == 3 and not probe.scope_refresh_error)
print('automatic scope rejection/backoff checks passed')

-- A targeted script reload cannot hide a simultaneous disable-list/mode/asset edit.
local reload_first = assert(init_source:find('function src.reloadClientPlugin(', 1, true))
local reload_last = assert(init_source:find('\nfunction src.onClientEvent', reload_first, true))
local load_reload = assert(compile('local src, state, sync_snapshot, network = ...\n' ..
	init_source:sub(reload_first, reload_last - 1) .. '\nreturn src.reloadClientPlugin'))
local function reload_case(next_plugins, next_mode, next_level, next_hash, expected)
	local current = { persistent_mode = 'mode', loaded_level = 'level', client_plugin_signature = 'alpha\nzeta',
		asset_files = { { path = 'data/model/test.cmo', sha256 = 'old' } } }
	local called, hint = false, false
	local reload = load_reload({}, current, { discover = function(target)
		target.client_plugin_signature = next_plugins
		target.persistent_mode, target.loaded_level = next_mode, next_level
		target.asset_files = { { path = 'data/model/test.cmo', sha256 = next_hash } }
	end }, { refresh = function(_, plugin_name) called, hint = true, plugin_name end })
	reload('alpha')
	assert(called and hint == expected)
end
reload_case('alpha\nzeta', 'mode', 'level', 'old', 'alpha')
reload_case('alpha', 'mode', 'level', 'old', nil)
reload_case('alpha\nzeta', 'other', 'level', 'old', nil)
reload_case('alpha\nzeta', 'mode', 'other', 'old', nil)
reload_case('alpha\nzeta', 'mode', 'level', 'new', nil)
print('targeted reload scope escalation checks passed')

-- Scope configuration and the published script bytes must come from one build.
files['clientroot/scripts/disabledPlugins.json'] = '["disabled"]'
snapshot.discover(state)
local stable_files, stable_hash = state.asset_files, state.manifest_hash
local read_before = paths.read_file
local disable_reads = 0
paths.read_file = function(path)
	local value = read_before(path)
	if path == 'clientroot/scripts/disabledPlugins.json' then
		disable_reads = disable_reads + 1
		if disable_reads == 2 then
			files[path] = '["disabled","alpha","zeta"]'
		end
	end
	return value
end
assert(not pcall(snapshot.discover, state))
assert(state.asset_files == stable_files and state.manifest_hash == stable_hash)
paths.read_file = read_before
files['clientroot/scripts/disabledPlugins.json'] = '["disabled"]'
-- Missing roots are valid; an I/O error in an existing selected root is not.
local list_before = os.listDirectory
os.listDirectory = function(root)
	if root == 'clientroot/assets/plugins/zeta' then error('permission denied') end
	return list_before(root)
end
assert(not pcall(snapshot.discover, state))
assert(state.asset_files == stable_files and state.manifest_hash == stable_hash)
os.listDirectory = list_before
paths.read_file = function(path)
	if path == 'clientroot/assets/plugins/zeta/data/model/zeta.cmo' then return nil end
	return read_before(path)
end
assert(not pcall(snapshot.discover, state))
assert(state.asset_files == stable_files and state.manifest_hash == stable_hash)
paths.read_file = read_before
print('snapshot configuration consistency and I/O rollback checks passed')

add('clientroot/assets/plugins/zeta/data/model/ZETA.cmo', 'zeta')
assert(not pcall(snapshot.discover, state))
assert(state.asset_files == stable_files and state.manifest_hash == stable_hash)
files['clientroot/assets/plugins/zeta/data/model/ZETA.cmo'] = nil
print('case-folded logical path collision checks passed')
