local sync_paths = require("main.src.sync_paths")
local client_scope = require("main.src.client_scope")
local log = require("main.src.log")
local utf8_sanitize = require("main.src.utf8_sanitize")
local has_miniz_integration = pcall(require, "libminiz")

local sync_snapshot = {}
local MAX_SNAPSHOT_FILES = 4096
local MAX_SNAPSHOT_BYTES = 256 * 1024 * 1024
local MAX_SCRIPT_BYTES = 2 * 1024 * 1024
local MAX_ASSET_BYTES = 128 * 1024 * 1024
local MAX_SYNC_PATH_BYTES = 1024

-- unchanged files (same size and mtime) aren't re-read or re-hashed
-- config.yml and disabledPlugins.json are always read
local ALWAYS_READ = { ["config.yml"] = true, ["disabledPlugins.json"] = true, }

local RECENT_WRITE_SECONDS = 2

-- getLastWriteTime uses the filesystem clock, so read "now" from a fresh file instead of os.time
local function filesystem_now()
	local path = os.tmpname()
	local file = assert(io.open(path, "wb"))
	file:close()
	local now = os.getLastWriteTime(path)
	os.remove(path)
	return now
end

local function snapshot_file_info(state, path, sync_path, limit, force_read)
	assert(#sync_path <= MAX_SYNC_PATH_BYTES, "Sync path exceeds size limit: " .. sync_path)
	assert(state.snapshot_file_count < MAX_SNAPSHOT_FILES, "Sync snapshot exceeds file count limit")
	local size = sync_paths.file_size(path)
	if not size then
		return nil
	end
	local mtime = os.getLastWriteTime(path)
	local remaining = MAX_SNAPSHOT_BYTES - state.snapshot_bytes
	assert(size <= limit and size <= remaining, "Sync snapshot exceeds byte limit: " .. sync_path)
	local info = { size = size, mtime = mtime, }
	local cached = state.previous_file_hashes[path]
	-- a file written within the timestamp granularity of the scan can change again with the same mtime
	local settled = mtime < state.scan_clock - RECENT_WRITE_SECONDS
	if cached and settled and not force_read and cached.size == size and cached.mtime == mtime then
		info.sha256 = cached.sha256
	else
		local bytes = sync_paths.read_file(path, math.min(limit, remaining))
		if not bytes then
			return nil
		end
		assert(#bytes <= limit and #bytes <= remaining, "Sync snapshot exceeds byte limit: " .. sync_path)
		info.bytes, info.size, info.sha256 = bytes, #bytes, crypto.sha256(bytes)
	end
	state.snapshot_file_count = state.snapshot_file_count + 1
	state.snapshot_bytes = state.snapshot_bytes + info.size
	state.file_hashes[path] = { size = info.size, mtime = mtime, sha256 = info.sha256, }
	return info
end

local function escape_path(path)
	return (path:gsub("[^%w%._/%-]", function(byte) return string.format("\\x%02X", byte:byte()) end))
end

-- non-UTF-8 names can't be advertised, report once
local function note_unsyncable_name(state, directory, entry)
	if utf8_sanitize.is_valid(entry.name) then
		return
	end
	if not entry.isDirectory and not sync_paths.is_invalid_utf8_syncable_name(entry.name) then
		return
	end
	local path = sync_paths.join(directory, entry.name)
	state.invalid_names_seen[path] = true
	if not state.invalid_names_warned[path] then
		log.warn("Not syncing %s: its name is not valid UTF-8; rename it", escape_path(path))
	end
end

local function to_lower(value)
	if type(value) ~= "string" then
		return ""
	end
	return string.lower(value)
end


local band = bit32.band
local bxor = bit32.bxor
local rshift = bit32.rshift

local DEFAULT_GAME_MODEL_CMO_FILES = {
	["9mm.cmo"] = true,
	["9mm_magazine.cmo"] = true,
	["ak47.cmo"] = true,
	["ak47_magazine.cmo"] = true,
	["cellphone.cmo"] = true,
	["desktest.cmo"] = true,
	["fhair1.cmo"] = true,
	["fhair2.cmo"] = true,
	["fhair3.cmo"] = true,
	["fhair4.cmo"] = true,
	["fhair5.cmo"] = true,
	["fhair6.cmo"] = true,
	["fhair7.cmo"] = true,
	["fhair8.cmo"] = true,
	["fhair9.cmo"] = true,
	["fhead1.cmo"] = true,
	["fhead2.cmo"] = true,
	["fhead3.cmo"] = true,
	["fhead4.cmo"] = true,
	["fhead5.cmo"] = true,
	["grenade.cmo"] = true,
	["heli.cmo"] = true,
	["lamptest.cmo"] = true,
	["m16.cmo"] = true,
	["m16_magazine.cmo"] = true,
	["mhair1.cmo"] = true,
	["mhair2.cmo"] = true,
	["mhair3.cmo"] = true,
	["mhair4.cmo"] = true,
	["mhair5.cmo"] = true,
	["mhair6.cmo"] = true,
	["mhair7.cmo"] = true,
	["mhair8.cmo"] = true,
	["mhair9.cmo"] = true,
	["mhead1.cmo"] = true,
	["mhead2.cmo"] = true,
	["mhead3.cmo"] = true,
	["mhead4.cmo"] = true,
	["mhead5.cmo"] = true,
	["mp5.cmo"] = true,
	["mp5_magazine.cmo"] = true,
	["soccerball.cmo"] = true,
	["walkietalkie.cmo"] = true,
}

local DEFAULT_GAME_VEHICLE_SBV_CRC32 = {
	["data/beamer2.sbv"] = 0x8C61F42F,
	["data/golf5.sbv"] = 0xE14112E2,
	["data/minivan2.sbv"] = 0x29053325,
	["data/park5.sbv"] = 0x7AC22AC3,
	["data/train04.sbv"] = 0xEEF0232B,
	["data/turbo5.sbv"] = 0x52DED687,
	["data/van4.sbv"] = 0x2F531C11,
}

local function is_default_game_map_name(level_name)
	local normalized = to_lower(level_name or "")
	return normalized == "round" or normalized == "test2"
end

local function should_skip_bundled_model_cmo(sync_path)
	if type(sync_path) ~= "string" then
		return false
	end

	if sync_path:sub(1, 11) ~= "data/model/" then
		return false
	end

	local model_relative = sync_path:sub(12)
	if model_relative:find("/", 1, true) then
		return false
	end

	local file_name = sync_path:match("([^/]+)$")
	if type(file_name) ~= "string" or file_name == "" then
		return false
	end

	file_name = to_lower(file_name)
	if sync_paths.extension(file_name) ~= ".cmo" then
		return false
	end

	return DEFAULT_GAME_MODEL_CMO_FILES[file_name] == true
end

local function crc32(bytes)
	local crc = 0xFFFFFFFF
	for i = 1, #bytes do
		crc = bxor(crc, string.byte(bytes, i))
		for _ = 1, 8 do
			local mask = band(crc, 1)
			crc = rshift(crc, 1)
			if mask ~= 0 then
				crc = bxor(crc, 0xEDB88320)
			end
		end
	end
	return bxor(crc, 0xFFFFFFFF)
end

local function should_skip_bundled_vehicle_sbv(sync_path, bytes)
	if type(sync_path) ~= "string" or type(bytes) ~= "string" then
		return false
	end

	local expected_crc = DEFAULT_GAME_VEHICLE_SBV_CRC32[to_lower(sync_path)]
	if not expected_crc then
		return false
	end

	return crc32(bytes) == expected_crc
end

local function require_zip_integration()
	if has_miniz_integration and type(miniz) == "table" and type(miniz.createZip) == "function" then
		return miniz
	end

	error('require("libminiz") did not expose global miniz.createZip')
end

local function new_bundle(id, kind)
	return {
		id = id,
		kind = kind,
		files = {},
		archive_inputs = {},
		lazy_sources = {},
		archive = "",
		size = 0,
		archive_sha256 = "",
		content_sha256 = "",
	}
end

local function bundle_content_hash(files)
	local parts = {}
	for i = 1, #files do
		local record = files[i]
		parts[#parts + 1] = string.format(
			"%s|%s|%s|%s",
			tostring(record.kind or ""),
			record.path,
			tostring(record.size),
			record.sha256
		)
	end
	return crypto.sha256(table.concat(parts, "\n"))
end

local ZIP_OPTIONS = {
	level = 3,
	store = { ".png", ".wav", ".ogg", ".jpg", ".jpeg", },
}

sync_snapshot.ZIP_OPTIONS = ZIP_OPTIONS

-- previous_bundles reuses archives of unchanged files
local function finalize_bundle(bundle, previous_bundles)
	if #bundle.files == 0 then
		return nil
	end

	table.sort(bundle.files, function(a, b)
		return a.path < b.path
	end)

	bundle.content_sha256 = bundle_content_hash(bundle.files)
	local previous = previous_bundles and previous_bundles[bundle.id]
	if previous and previous.content_sha256 == bundle.content_sha256
		and previous.kind == bundle.kind and previous.archive ~= "" then
		bundle.archive = previous.archive
		bundle.size = previous.size
		bundle.archive_sha256 = previous.archive_sha256
		bundle.reused = true
	else
		local integration = require_zip_integration()
		for path, bytes in pairs(bundle.archive_inputs) do
			if bytes == false then
				local source = bundle.lazy_sources[path]
				bytes = sync_paths.read_file(source.source_path, source.size)
				assert(bytes ~= nil and #bytes == source.size and crypto.sha256(bytes) == source.sha256,
					"Sync file changed while building snapshot: " .. path)
				bundle.archive_inputs[path] = bytes
			end
		end
		local archive = integration.createZip(bundle.archive_inputs, ZIP_OPTIONS)
		bundle.archive = archive
		bundle.size = #archive
		bundle.archive_sha256 = crypto.sha256(archive)
		bundle.reused = false
	end
	bundle.archive_inputs = nil
	bundle.lazy_sources = nil
	return bundle
end

local function reset_sync_snapshot(state)
	state.scripts = {}
	state.scripts_by_path = {}
	state.asset_files = {}
	state.asset_files_by_path = {}
	state.asset_paths_folded = {}
	state.sync_bundles = {}
	state.sync_bundles_by_id = {}
end

local function append_snapshot_record(state, bundle, record, bytes)
	local snapshot_record = {
		path = record.path,
		size = record.size,
		sha256 = record.sha256,
		mtime = record.mtime,
		source_path = record.source_path,
		kind = record.kind,
	}

	if snapshot_record.kind == "script" then
		table.insert(state.scripts, snapshot_record)
		state.scripts_by_path[snapshot_record.path] = snapshot_record
	else
		local folded = string.lower(snapshot_record.path)
		local spelling = state.asset_paths_folded[folded]
		assert(not spelling or spelling == snapshot_record.path,
			"Case-conflicting asset path: " .. snapshot_record.path)
		state.asset_paths_folded[folded] = snapshot_record.path
		local previous = state.asset_files_by_path[snapshot_record.path]
		if previous then
			assert(previous.size == snapshot_record.size and previous.sha256 == snapshot_record.sha256,
				"Conflicting asset path: " .. snapshot_record.path)
			return
		end
		table.insert(state.asset_files, snapshot_record)
		state.asset_files_by_path[snapshot_record.path] = snapshot_record
	end

	bundle.archive_inputs[snapshot_record.path] = bytes or false
	if not bytes then
		bundle.lazy_sources[snapshot_record.path] = {
			source_path = record.source_path, size = record.size, sha256 = record.sha256,
		}
	end
	table.insert(bundle.files, {
		path = snapshot_record.path,
		size = snapshot_record.size,
		sha256 = snapshot_record.sha256,
		mtime = snapshot_record.mtime,
		kind = snapshot_record.kind,
	})
end

local function collect_scripts_recursive(state, bundle, root, relative_path)
	relative_path = relative_path or ""

	local current = root
	if relative_path ~= "" then
		current = sync_paths.join(root, relative_path)
	end

	local ok, entries = pcall(os.listDirectory, current)
	assert(ok and type(entries) == "table", "Cannot enumerate script root: " .. current)

	table.sort(entries, function(a, b) return a.name < b.name end)
	for _, entry in ipairs(entries) do
		-- no symlinks or unsafe components
		if not sync_paths.is_contained(root, sync_paths.join(current, entry.name)) then goto continue end
		note_unsyncable_name(state, current, entry)
		if entry.isDirectory then
			if relative_path == "" and (entry.name == "assets" or entry.name == "scripts") then
				goto continue
			end

			local child = entry.name
			if relative_path ~= "" then
				child = relative_path .. "/" .. entry.name
			end
			collect_scripts_recursive(state, bundle, root, child)
		else
			local relative_pathname = entry.name
			if relative_path ~= "" then
				relative_pathname = relative_path .. "/" .. entry.name
			end

			if sync_paths.is_safe_script(relative_pathname) then
				local full_path = sync_paths.join(root, relative_pathname)
				local info = snapshot_file_info(state, full_path, relative_pathname, MAX_SCRIPT_BYTES,
					ALWAYS_READ[relative_pathname])
				if info then
					append_snapshot_record(state, bundle, {
						path = relative_pathname,
						size = info.size,
						sha256 = info.sha256,
						mtime = info.mtime,
						source_path = full_path,
						kind = "script",
					}, info.bytes)
				end
			end
		end

		::continue::
	end
end

function sync_snapshot.normalize_loaded_level(raw_level)
	if type(raw_level) ~= "string" then
		return ""
	end

	local level = raw_level:gsub("\\", "/")
	level = level:gsub("^%s+", "")
	level = level:gsub("%s+$", "")
	level = level:gsub("^data/", "")
	level = level:gsub("^/+", "")
	level = level:gsub("/+$", "")

	if level == "" then
		return ""
	end

	if level:find("..", 1, true) then
		return ""
	end

	return level
end

function sync_snapshot.normalize_persistent_mode(raw_mode)
	if type(raw_mode) ~= "string" then return "" end
	local mode = raw_mode:gsub("%.lua$", "")
	return client_scope.valid_owner(mode) and mode or ""
end

function sync_snapshot.discover_persistent_mode(state, client_config_source)
	local raw_mode = nil
	if type(hook) == "table" then
		raw_mode = hook.persistentMode
	end

	state.server_persistent_mode = sync_snapshot.normalize_persistent_mode(raw_mode)
	state.persistent_mode = state.server_persistent_mode
	if state.persistent_mode == "" and client_config_source and client_config_source ~= "" then
		local yaml = require("main.yaml")
		local ok, client_config = pcall(yaml.parse, client_config_source)
		assert(ok and type(client_config) == "table", "Invalid client config.yml")
		state.persistent_mode = sync_snapshot.normalize_persistent_mode(client_config.defaultGameMode)
	end
	return state.persistent_mode
end

local function collect_asset_files_recursive(state, bundle, root, sync_root_prefix, relative_path)
	relative_path = relative_path or ""

	local current = root
	if relative_path ~= "" then
		current = sync_paths.join(root, relative_path)
	end

	local ok, entries = pcall(os.listDirectory, current)
	assert(ok and type(entries) == "table", "Cannot enumerate asset root: " .. current)

	table.sort(entries, function(a, b) return a.name < b.name end)
	for _, entry in ipairs(entries) do
		-- Reject unsafe components before either recursion or reads.
		local candidate = sync_paths.join(current, entry.name)
		if not sync_paths.is_contained(root, candidate) then goto continue end
		note_unsyncable_name(state, current, entry)
		if entry.isDirectory then
			local child = entry.name
			if relative_path ~= "" then
				child = relative_path .. "/" .. entry.name
			end
			collect_asset_files_recursive(state, bundle, root, sync_root_prefix, child)
		else
			local relative_pathname = entry.name
			if relative_path ~= "" then
				relative_pathname = relative_path .. "/" .. entry.name
			end

			local full_path = sync_paths.join(root, relative_pathname)
			local sync_path = relative_pathname
			if sync_root_prefix ~= "" then
				sync_path = sync_paths.join(sync_root_prefix, relative_pathname)
			end
			if sync_paths.is_safe_asset(sync_path) then
				local should_skip = should_skip_bundled_model_cmo(sync_path)
				if not should_skip then
					local info = assert(snapshot_file_info(state, full_path, sync_path, MAX_ASSET_BYTES,
						DEFAULT_GAME_VEHICLE_SBV_CRC32[to_lower(sync_path)] ~= nil), "Cannot read asset: " .. full_path)
					if info.bytes and should_skip_bundled_vehicle_sbv(sync_path, info.bytes) then
						goto continue
					end
					append_snapshot_record(state, bundle, {
						path = sync_path,
						size = info.size,
						sha256 = info.sha256,
						mtime = info.mtime,
						source_path = full_path,
						kind = "asset",
					}, info.bytes)
				end
			end
		end
		::continue::
	end
end

local function collect_top_level_vehicle_sbv_files(state, bundle, root, sync_root_prefix)
	local ok, entries = pcall(os.listDirectory, root)
	if not ok or type(entries) ~= "table" then
		return
	end

	table.sort(entries, function(a, b) return a.name < b.name end)
	for _, entry in ipairs(entries) do
		if not entry.isDirectory then
			note_unsyncable_name(state, root, entry)
			local relative_path = entry.name
			local sync_path = relative_path
			if sync_root_prefix ~= "" then
				sync_path = sync_paths.join(sync_root_prefix, relative_path)
			end

			if sync_paths.extension(sync_path) == ".sbv" and sync_paths.is_safe_asset(sync_path) then
				local full_path = sync_paths.join(root, relative_path)
				local info = snapshot_file_info(state, full_path, sync_path, MAX_ASSET_BYTES,
					DEFAULT_GAME_VEHICLE_SBV_CRC32[to_lower(sync_path)] ~= nil)
				if info then
					if info.bytes and should_skip_bundled_vehicle_sbv(sync_path, info.bytes) then
						goto continue
					end
					append_snapshot_record(state, bundle, {
						path = sync_path,
						size = info.size,
						sha256 = info.sha256,
						mtime = info.mtime,
						source_path = full_path,
						kind = "asset",
					}, info.bytes)
				end
			end
		end
		::continue::
	end
end

local function build_snapshot(state, previous_bundles)
	reset_sync_snapshot(state)
	state.file_hashes = {}
	state.invalid_names_seen = {}
	state.snapshot_file_count = 0
	state.snapshot_bytes = 0
	state.scan_clock = filesystem_now()
	local normalized_level = sync_snapshot.normalize_loaded_level(server and server.loadedLevel or nil)
	state.loaded_level = normalized_level

	pcall(os.createDirectory, state.config.clientRoot)
	local scripts_root = sync_paths.scripts_root(state.config)
	local assets_root = sync_paths.assets_root(state.config)
	pcall(os.createDirectory, scripts_root)
	pcall(os.createDirectory, assets_root)

	local enabled, disabled_source = client_scope.enabled(state.config)
	local client_bundle = new_bundle("clientroot", "clientroot")
	collect_scripts_recursive(state, client_bundle, scripts_root, "")
	assert(client_bundle.archive_inputs["disabledPlugins.json"] == disabled_source,
		"Client disable state changed while building snapshot")
	-- Select assets from the same immutable config bytes that core will receive.
	sync_snapshot.discover_persistent_mode(state, client_bundle.archive_inputs["config.yml"])
	state.client_plugin_signature = table.concat(enabled, "\n")
	local function collect_owner(namespace, owner)
		local root = sync_paths.join(assets_root, namespace .. "/" .. owner)
		if sync_paths.is_contained(state.config.clientRoot, assets_root)
			and sync_paths.is_contained(assets_root, root) then
			collect_asset_files_recursive(state, client_bundle, root, "", "")
		end
	end
	if state.persistent_mode ~= "" then collect_owner("modes", state.persistent_mode) end
	for _, name in ipairs(enabled) do collect_owner("plugins", name) end
	collect_top_level_vehicle_sbv_files(state, client_bundle, "data", "data")

	client_bundle = finalize_bundle(client_bundle, previous_bundles)
	if client_bundle then
		table.insert(state.sync_bundles, client_bundle)
		state.sync_bundles_by_id[client_bundle.id] = client_bundle
	end

	if normalized_level ~= "" and not is_default_game_map_name(normalized_level) then
		local level_sync_root = "data/" .. normalized_level
		local map_bundle = new_bundle("map", "map")
		if sync_paths.exists(level_sync_root) then
			collect_asset_files_recursive(state, map_bundle, level_sync_root, level_sync_root, "")
		end
		map_bundle = finalize_bundle(map_bundle, previous_bundles)
		if map_bundle then
			table.insert(state.sync_bundles, map_bundle)
			state.sync_bundles_by_id[map_bundle.id] = map_bundle
		end
	end

	table.sort(state.scripts, function(a, b)
		return a.path < b.path
	end)

	table.sort(state.asset_files, function(a, b)
		return a.path < b.path
	end)

	local manifest = {
		state.loaded_level,
		state.persistent_mode,
		state.client_plugin_signature,
	}
	for _, bundle in ipairs(state.sync_bundles) do
		manifest[#manifest + 1] = table.concat({
			bundle.id,
			bundle.kind,
			bundle.content_sha256,
		}, "|")
	end
	assert(client_scope.signature(state.config) == state.client_plugin_signature,
		"Client plugin entries changed while building snapshot")
	state.manifest_hash = crypto.sha256(table.concat(manifest, "\n"))

	return state.scripts, state.asset_files, state.sync_bundles
end

function sync_snapshot.discover(state)
	-- A conflict or malformed scope must not replace a valid published snapshot.
	local next_state = {
		config = state.config,
		previous_file_hashes = state.snapshot_file_hashes or {},
		invalid_names_warned = state.invalid_names_warned or {},
	}
	build_snapshot(next_state, state.sync_bundles_by_id)
	for _, key in ipairs({ "scripts", "scripts_by_path", "asset_files", "asset_files_by_path", "asset_paths_folded",
		"sync_bundles", "sync_bundles_by_id", "loaded_level", "persistent_mode", "server_persistent_mode",
		"client_plugin_signature", "manifest_hash" }) do
		state[key] = next_state[key]
	end
	-- only a good scan replaces these, so a failed one can't poison the hash cache
	state.snapshot_file_hashes = next_state.file_hashes
	state.invalid_names_warned = next_state.invalid_names_seen
	return state.scripts, state.asset_files, state.sync_bundles
end

-- the worker holds the archive bytes after it confirms; main keeps only metadata
function sync_snapshot.release_archives(state)
	for _, bundle in ipairs(state.sync_bundles) do
		bundle.archive = nil
	end
end

function sync_snapshot.restore_archives(state)
	local integration = require_zip_integration()
	for _, bundle in ipairs(state.sync_bundles) do
		if not bundle.archive then
			local inputs = {}
			for _, file in ipairs(bundle.files) do
				local record = state.scripts_by_path[file.path] or state.asset_files_by_path[file.path]
				local bytes = record and sync_paths.read_file(record.source_path, file.size)
				assert(bytes ~= nil and #bytes == file.size and crypto.sha256(bytes) == file.sha256,
					"Sync file changed since snapshot: " .. file.path)
				inputs[file.path] = bytes
			end
			local archive = integration.createZip(inputs, ZIP_OPTIONS)
			bundle.archive, bundle.size, bundle.archive_sha256 = archive, #archive, crypto.sha256(archive)
		end
	end
end

function sync_snapshot.discover_scripts(state)
	sync_snapshot.discover(state)
	return state.scripts
end

function sync_snapshot.discover_asset_files(state)
	sync_snapshot.discover(state)
	return state.asset_files
end

return sync_snapshot
