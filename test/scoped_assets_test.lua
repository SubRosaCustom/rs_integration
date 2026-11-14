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
local mtimes, clock = {}, 0
local function add(path, bytes)
	clock = clock + 1; mtimes[path] = clock
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
	local offset = 1
	return { seek = function() return #bytes end, read = function(_, size)
		if size == '*all' then return bytes:sub(offset) end
		if offset > #bytes then return nil end
		local chunk = bytes:sub(offset, offset + size - 1)
		offset = offset + #chunk
		return chunk
	end, close = function() end }
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
	table.sort(entries, function(a, b) return a.name > b.name end)
	return entries
end
-- the temp file read as the scan clock is newer than every fixture file
os.getLastWriteTime = function(path) return mtimes[path] or (files[path] and 1) or 1000 end
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
-- archive_sha256 doesn't affect manifest identity
local cached_bundle = state.sync_bundles_by_id.clientroot
assert(cached_bundle.reused == false or cached_bundle.reused == true)
snapshot.discover(state)
assert(state.sync_bundles_by_id.clientroot.reused == true, "unchanged bundle must reuse its archive")
assert(state.sync_bundles_by_id.clientroot.archive_sha256 == cached_bundle.archive_sha256)
local createZip_calls, real_createZip, stamp = 0, miniz.createZip, 0
miniz.createZip = function(inputs, options)
	createZip_calls = createZip_calls + 1
	assert(options.level == 3 and options.store[1] == '.png')
	stamp = stamp + 1
	return real_createZip(inputs) .. '|stamp' .. stamp
end
local fresh = { config = state.config }
snapshot.discover(fresh)
assert(fresh.manifest_hash == hash and createZip_calls > 0)
local first_archive_hash = fresh.sync_bundles_by_id.clientroot.archive_sha256
local rebuilt = { config = state.config }
snapshot.discover(rebuilt)
assert(rebuilt.sync_bundles_by_id.clientroot.archive_sha256 ~= first_archive_hash)
assert(rebuilt.manifest_hash == hash, "identical content must keep manifest_hash when archive bytes differ")
local calls_before = createZip_calls
snapshot.discover(fresh)
assert(createZip_calls == calls_before, "cached bundle must not call createZip again")
miniz.createZip = real_createZip
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
local saved_size = paths.file_size
paths.file_size = function(path)
	if path == 'clientroot/scripts/plugins/zeta.lua' then return nil end
	return saved_size(path)
end
assert(not pcall(snapshot.discover, state))
assert(state.asset_files == valid_assets and state.manifest_hash == valid_hash)
paths.file_size = saved_size
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
local warnings = 0
package.loaded['main.src.log'] = { info = function() end, warn = function() warnings = warnings + 1 end,
	warn_limited = function() warnings = warnings + 1 end }
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
-- inotify tracks structure, the full walk is a slow safety net
state.tick = 60; watcher.ensure(state)
assert(not watches['clientroot/assets/plugins/zeta/new/nested'], 'no tree walk before the safety interval')
state.tick = 1800; watcher.ensure(state)
assert(watches['clientroot/assets/plugins/zeta/new/nested'])
state.tick = 1802; watcher.process(state, refreshed)
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
-- receiveEvent error forces a rescan and refresh
do
	local instances, before_refresh = watcher_instances, refreshes
	local real_receive = state.file_watcher.receiveEvent
	state.file_watcher.receiveEvent = function() error('Invalid argument') end
	state.tick = state.tick + 1
	watcher.process(state, refreshed)
	assert(watcher_instances == instances + 1 and warnings > 0)
	state.tick = state.tick + 2
	watcher.process(state, refreshed)
	assert(refreshes == before_refresh + 1)
end
print('scoped content watcher create/delete/rename checks passed')

-- Load the real init.lua with the sync snapshot and network boundaries replaced; its hooks and
-- public functions are driven the way RosaServer drives them.
local saved_loaded, saved_globals = {}, {}
for _, name in ipairs({ 'main.src.sync_snapshot', 'main.src.network', 'main.src.log', 'main.src.item_types',
	'main.src.vehicle_types', 'main.src.human_models', 'main.src.browser_marker', 'librosaserver_src_integration' }) do
	saved_loaded[name] = package.loaded[name]
end
for _, name in ipairs({ '__srcMainState', 'src', 'hook', 'config', 'players' }) do saved_globals[name] = _G[name] end
_G.__srcMainState, _G.src, _G.config = nil, nil, nil
local hook_callbacks = {}
hook = { persistentMode = '', add = function(event, _, callback) hook_callbacks[event] = callback end, override = {} }
players = { getNonBots = function() return {} end }
local discover_calls, discover_effect, refresh_calls, last_refresh_hint = 0, nil, 0, nil
local normalize_nil = function(value) return value == nil and '' or value end
package.loaded['librosaserver_src_integration'] = {}
srcIntegrationNative = setmetatable({}, { __index = function() return function() end end })
package.loaded['main.src.browser_marker'] = { on_send_packet = function() end, on_post_send_packet = function() end }
package.loaded['main.src.log'] = { info = function() end, warn = function() end }
for _, name in ipairs({ 'item_types', 'vehicle_types', 'human_models' }) do
	package.loaded['main.src.' .. name] = { install = function() end }
end
package.loaded['main.src.sync_snapshot'] = {
	normalize_persistent_mode = normalize_nil, normalize_loaded_level = normalize_nil,
	discover = function(target) discover_calls = discover_calls + 1; if discover_effect then discover_effect(target) end end,
}
package.loaded['main.src.network'] = {
	refresh = function(_, plugin_name) refresh_calls = refresh_calls + 1; last_refresh_hint = plugin_name end,
	logic_step = function() end, ensure_tcp_server = function() end, shutdown = function() end,
}
local saved_clock = os.realClock
os.realClock = os.realClock or os.clock
local init_src = dofile('main/src/init.lua')
local init_state = require('main.src.runtime_state').get()
local hash_counter = 0
local function changing_manifest(target) hash_counter = hash_counter + 1; target.manifest_hash = 'h' .. hash_counter end
local function logic_at(tick)
	init_state.tick = tick - 1
	hook_callbacks.Logic()
end

-- a client fallback differing from the raw server mode must not refresh on every tick
init_state.server_persistent_mode, init_state.persistent_mode = '', 'active'
discover_effect = changing_manifest
hook.persistentMode = ''
logic_at(2)
assert(refresh_calls == 0, 'unchanged server mode must not refresh')
hook.persistentMode = 'other'
logic_at(3)
assert(refresh_calls == 1, 'changed server mode refreshes once')
hook.persistentMode = ''

-- no-op refresh sends no notice, forced ones still do
refresh_calls = 0
local fixed_hash = 'same'
discover_effect = function(target) target.manifest_hash = fixed_hash end
init_state.manifest_hash = 'stale'
assert(init_src.refresh() == true and refresh_calls == 1)
assert(init_src.refresh() == false and refresh_calls == 1, 'unchanged manifest must not notify clients')
config = {}
hook_callbacks.ConfigLoaded(false)
assert(refresh_calls == 2, 'config load forces a refresh')
fixed_hash = 'other'
assert(init_src.refreshSyncFiles() == true and refresh_calls == 3)

-- a rejected automatic refresh backs off and returns normally so the Logic hook keeps serving connections
refresh_calls, discover_calls = 0, 0
init_state.next_scope_refresh_tick, init_state.scope_refresh_error = nil, nil
init_state.server_persistent_mode = 'stale'
hook.persistentMode = 'changed'
local failing = true
discover_effect = function(target) if failing then error('collision') end changing_manifest(target) end
logic_at(2); assert(discover_calls == 1 and refresh_calls == 0)
logic_at(3); assert(discover_calls == 1, 'backoff suppresses retries')
logic_at(62); assert(discover_calls == 2, 'retry after the backoff window')
failing = false
logic_at(122); assert(discover_calls == 3 and refresh_calls == 1 and not init_state.scope_refresh_error)
hook.persistentMode = ''
print('automatic scope rejection/backoff and no-op refresh checks passed')

-- A targeted script reload cannot hide a simultaneous disable-list/mode/asset edit.
local function reload_case(next_plugins, next_mode, next_level, next_hash, expected)
	init_state.persistent_mode, init_state.loaded_level = 'mode', 'level'
	init_state.client_plugin_signature = 'alpha\nzeta'
	init_state.asset_files = { { path = 'data/model/test.cmo', sha256 = 'old' } }
	init_state.manifest_hash = 'before'
	discover_effect = function(target)
		target.client_plugin_signature = next_plugins
		target.persistent_mode, target.loaded_level = next_mode, next_level
		target.asset_files = { { path = 'data/model/test.cmo', sha256 = next_hash } }
		target.manifest_hash = 'changed'
	end
	refresh_calls, last_refresh_hint = 0, false
	assert(init_src.reloadClientPlugin('alpha') == true)
	assert(refresh_calls == 1 and last_refresh_hint == expected)
end
-- unchanged manifest sends no notice
discover_effect = function() end
refresh_calls = 0
init_state.manifest_hash, init_state.asset_files = 'same', {}
assert(init_src.reloadClientPlugin('alpha') == false and refresh_calls == 0)
reload_case('alpha\nzeta', 'mode', 'level', 'old', 'alpha')
reload_case('alpha', 'mode', 'level', 'old', nil)
reload_case('alpha\nzeta', 'other', 'level', 'old', nil)
reload_case('alpha\nzeta', 'mode', 'other', 'old', nil)
reload_case('alpha\nzeta', 'mode', 'level', 'new', nil)
print('targeted reload scope escalation checks passed')

os.realClock = saved_clock
for name, value in pairs(saved_loaded) do package.loaded[name] = value end
for name, value in pairs(saved_globals) do _G[name] = value end

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
paths.file_size = function(path)
	if path == 'clientroot/assets/plugins/zeta/data/model/zeta.cmo' then return nil end
	return saved_size(path)
end
assert(not pcall(snapshot.discover, state))
assert(state.asset_files == stable_files and state.manifest_hash == stable_hash)
paths.file_size = saved_size
print('snapshot configuration consistency and I/O rollback checks passed')

add('clientroot/scripts/plugins/oversized.lua', string.rep('x', 2 * 1024 * 1024 + 1))
assert(not pcall(snapshot.discover, state))
assert(state.asset_files == stable_files and state.manifest_hash == stable_hash)
files['clientroot/scripts/plugins/oversized.lua'] = nil
print('oversized snapshot is rejected without replacing the published snapshot')

add('clientroot/assets/plugins/zeta/data/model/ZETA.cmo', 'zeta')
assert(not pcall(snapshot.discover, state))
assert(state.asset_files == stable_files and state.manifest_hash == stable_hash)
files['clientroot/assets/plugins/zeta/data/model/ZETA.cmo'] = nil
print('case-folded logical path collision checks passed')

-- symlinks excluded, listing failures reject the refresh
links['clientroot/scripts/plugins/alpha'] = 'elsewhere'
add('elsewhere/init.lua', 'return false')
snapshot.discover(state)
for _, record in ipairs(state.scripts) do assert(record.path ~= 'plugins/alpha/init.lua') end
links['clientroot/scripts/plugins/alpha'] = nil
links['clientroot/scripts/plugins/zeta.lua'] = 'elsewhere/init.lua'
snapshot.discover(state)
for _, record in ipairs(state.scripts) do assert(record.path ~= 'plugins/zeta.lua') end
links['clientroot/scripts/plugins/zeta.lua'] = nil
stable_files, stable_hash = state.asset_files, state.manifest_hash
local list_scripts = os.listDirectory
os.listDirectory = function(root)
	if root == 'clientroot/scripts' then error('permission denied') end
	return list_scripts(root)
end
assert(not pcall(snapshot.discover, state))
assert(state.asset_files == stable_files and state.manifest_hash == stable_hash)
os.listDirectory = list_scripts
print('script scan containment and listing failure checks passed')

for _, bad in ipairs({ './texture/box.png', 'texture/./box.png', 'texture//box.png', 'D:foo.png', 'a/b:c.png',
	'a\\b.png', '../a.png', 'a/../b.png', '/a.png', 'CON.png', 'dir/nul.lua', 'a/COM1.png', 'a./b.png', 'a/b.png.', 'a/b.png ', '' }) do
	assert(not paths.is_safe_asset(bad) and not paths.is_safe_script(bad:gsub('%.png$', '.lua')), bad)
end
assert(paths.is_safe_asset('data/model/car.cmo') and paths.is_safe_script('plugins/a/init.lua'))
assert(not paths.is_safe_asset('TEXTURE/BOX.PNG'))
print('sync path validator checks passed')

-- unchanged files aren't re-read or re-hashed
do
	local cache_state = { config = state.config }
	snapshot.discover(cache_state)
	local reads, hashes, base_sha, zips = 0, 0, crypto.sha256, 0
	local base_read, base_create = paths.read_file, miniz.createZip
	local unexpected = {}
	paths.read_file = function(path, ...)
		reads = reads + 1
		if not path:find('disabledPlugins.json', 1, true) and not path:find('config.yml', 1, true) then unexpected[#unexpected + 1] = path end
		return base_read(path, ...)
	end
	crypto.sha256 = function(bytes) hashes = hashes + 1; return base_sha(bytes) end
	miniz.createZip = function(...) zips = zips + 1; return base_create(...) end
	local cached_hash = cache_state.manifest_hash
	snapshot.discover(cache_state)
	assert(cache_state.manifest_hash == cached_hash and zips == 0)
	assert(#unexpected == 0, 'unchanged files must not be re-read: ' .. tostring(unexpected[1]))
	-- new mtime re-hashes that file
	add('clientroot/assets/plugins/zeta/data/model/zeta.cmo', 'ZETA!')
	reads, zips = 0, 0
	snapshot.discover(cache_state)
	assert(cache_state.manifest_hash ~= cached_hash and zips >= 1)
	assert(cache_state.asset_files_by_path['data/model/zeta.cmo'].sha256 == 'hash:ZETA!')
	-- a change with the same size and mtime is caught on bundle rebuild
	paths.read_file, crypto.sha256, miniz.createZip = base_read, base_sha, base_create
	add('clientroot/assets/plugins/zeta/data/model/zeta.cmo', 'zeta')
	snapshot.discover(cache_state)

	-- released archive bytes restore identically
	local bundle = cache_state.sync_bundles_by_id.clientroot
	local archive_sha = bundle.archive_sha256
	snapshot.release_archives(cache_state)
	assert(bundle.archive == nil and bundle.size > 0)
	local released_hash = cache_state.manifest_hash
	snapshot.discover(cache_state)
	assert(cache_state.manifest_hash == released_hash and cache_state.sync_bundles_by_id.clientroot.archive == nil)
	snapshot.restore_archives(cache_state)
	assert(cache_state.sync_bundles_by_id.clientroot.archive ~= nil)
	assert(cache_state.sync_bundles_by_id.clientroot.archive_sha256 == archive_sha)
	files['clientroot/assets/plugins/zeta/data/model/zeta.cmo'] = 'tampered'
	snapshot.release_archives(cache_state)
	assert(not pcall(snapshot.restore_archives, cache_state))
	add('clientroot/assets/plugins/zeta/data/model/zeta.cmo', 'zeta')
end
print('snapshot hash cache and archive release checks passed')

-- non-UTF-8 names reported once, escaped, until they change
do
	local lines, real_print = {}, print
	print = function(text) lines[#lines + 1] = text end
	add('clientroot/assets/plugins/zeta/data/model/caf\233.cmo', 'bad name')
	add('clientroot/assets/plugins/zeta/data/model/notes\233.txt', 'unsynced type')
	local warn_state = { config = state.config }
	snapshot.discover(warn_state)
	snapshot.discover(warn_state)
	print = real_print
	local hits = 0
	for _, line in ipairs(lines) do
		if line:find('caf\\xE9.cmo', 1, true) then hits = hits + 1 end
		assert(not line:find('notes', 1, true))
	end
	assert(hits == 1, 'warned ' .. hits .. ' times')
	assert(not warn_state.asset_files_by_path['data/model/caf\233.cmo'])
	files['clientroot/assets/plugins/zeta/data/model/caf\233.cmo'] = nil
	files['clientroot/assets/plugins/zeta/data/model/notes\233.txt'] = nil
end
print('non-UTF-8 name warning checks passed')
