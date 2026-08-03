local sync_paths = require("main.src.sync_paths")
local has_miniz_integration = pcall(require, "libminiz")

local M = {}

local function to_lower(value)
	if type(value) ~= "string" then
		return ""
	end
	return string.lower(value)
end

local bitlib = bit32
if not bitlib then
	bitlib = require("bit")
end

local band = bitlib.band
local bxor = bitlib.bxor
local rshift = bitlib.rshift

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

local function finalize_bundle(bundle)
	if #bundle.files == 0 then
		return nil
	end

	table.sort(bundle.files, function(a, b)
		return a.path < b.path
	end)

	local integration = require_zip_integration()
	local archive = integration.createZip(bundle.archive_inputs)
	bundle.archive = archive
	bundle.size = #archive
	bundle.archive_sha256 = crypto.sha256(archive)
	bundle.content_sha256 = bundle_content_hash(bundle.files)
	bundle.archive_inputs = nil
	return bundle
end

local function reset_sync_snapshot(state)
	state.scripts = {}
	state.scripts_by_path = {}
	state.asset_files = {}
	state.asset_files_by_path = {}
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
		if state.asset_files_by_path[snapshot_record.path] then
			return
		end
		table.insert(state.asset_files, snapshot_record)
		state.asset_files_by_path[snapshot_record.path] = snapshot_record
	end

	bundle.archive_inputs[snapshot_record.path] = bytes
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
	if not ok or type(entries) ~= "table" then
		return
	end

	for _, entry in ipairs(entries) do
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
				local bytes = sync_paths.read_file(full_path)
				if bytes then
					append_snapshot_record(state, bundle, {
						path = relative_pathname,
						size = #bytes,
						sha256 = crypto.sha256(bytes),
						mtime = os.getLastWriteTime(full_path),
						source_path = full_path,
						kind = "script",
					}, bytes)
				end
			end
		end

		::continue::
	end
end

function M.normalize_loaded_level(raw_level)
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

function M.normalize_persistent_mode(raw_mode)
	if type(raw_mode) ~= "string" then
		return ""
	end

	local mode = raw_mode:gsub("\\", "/")
	mode = mode:gsub("^%s+", "")
	mode = mode:gsub("%s+$", "")
	mode = mode:gsub("^/+", "")
	mode = mode:gsub("/+$", "")

	if mode == "" then
		return ""
	end

	if mode:find("..", 1, true) then
		return ""
	end

	local leaf = mode:match("([^/]+)$")
	if leaf and leaf ~= "" then
		mode = leaf
	end

	mode = mode:gsub("%.lua$", "")
	mode = mode:gsub("^%s+", "")
	mode = mode:gsub("%s+$", "")
	return mode
end

function M.discover_persistent_mode(state)
	local raw_mode = nil
	if type(hook) == "table" then
		raw_mode = hook.persistentMode
	end

	state.persistent_mode = M.normalize_persistent_mode(raw_mode)
	return state.persistent_mode
end

local function collect_asset_files_recursive(state, bundle, root, sync_root_prefix, relative_path)
	relative_path = relative_path or ""

	local current = root
	if relative_path ~= "" then
		current = sync_paths.join(root, relative_path)
	end

	local ok, entries = pcall(os.listDirectory, current)
	if not ok or type(entries) ~= "table" then
		return
	end

	for _, entry in ipairs(entries) do
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
					local bytes = sync_paths.read_file(full_path)
					if bytes then
						if should_skip_bundled_vehicle_sbv(sync_path, bytes) then
							goto continue
						end
						append_snapshot_record(state, bundle, {
							path = sync_path,
							size = #bytes,
							sha256 = crypto.sha256(bytes),
							mtime = os.getLastWriteTime(full_path),
							source_path = full_path,
							kind = "asset",
						}, bytes)
					end
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

	for _, entry in ipairs(entries) do
		if not entry.isDirectory then
			local relative_path = entry.name
			local sync_path = relative_path
			if sync_root_prefix ~= "" then
				sync_path = sync_paths.join(sync_root_prefix, relative_path)
			end

			if sync_paths.extension(sync_path) == ".sbv" and sync_paths.is_safe_asset(sync_path) then
				local full_path = sync_paths.join(root, relative_path)
				local bytes = sync_paths.read_file(full_path)
				if bytes then
					if should_skip_bundled_vehicle_sbv(sync_path, bytes) then
						goto continue
					end
					append_snapshot_record(state, bundle, {
						path = sync_path,
						size = #bytes,
						sha256 = crypto.sha256(bytes),
						mtime = os.getLastWriteTime(full_path),
						source_path = full_path,
						kind = "asset",
					}, bytes)
				end
			end
		end
		::continue::
	end
end

function M.discover(state)
	M.discover_persistent_mode(state)
	reset_sync_snapshot(state)
	local normalized_level = M.normalize_loaded_level(server and server.loadedLevel or nil)
	state.loaded_level = normalized_level

	pcall(os.createDirectory, state.config.clientRoot)
	local scripts_root = sync_paths.scripts_root(state.config)
	local assets_root = sync_paths.assets_root(state.config)
	pcall(os.createDirectory, scripts_root)
	pcall(os.createDirectory, assets_root)

	local client_bundle = new_bundle("clientroot", "clientroot")
	collect_scripts_recursive(state, client_bundle, scripts_root, "")
	if #state.scripts == 0 then
		collect_scripts_recursive(state, client_bundle, state.config.clientRoot, "")
	end
	collect_asset_files_recursive(state, client_bundle, assets_root, "", "")
	collect_top_level_vehicle_sbv_files(state, client_bundle, "data", "data")

	client_bundle = finalize_bundle(client_bundle)
	if client_bundle then
		table.insert(state.sync_bundles, client_bundle)
		state.sync_bundles_by_id[client_bundle.id] = client_bundle
	end

	if normalized_level ~= "" and not is_default_game_map_name(normalized_level) then
		local level_sync_root = "data/" .. normalized_level
		local map_bundle = new_bundle("map", "map")
		collect_asset_files_recursive(state, map_bundle, level_sync_root, level_sync_root, "")
		map_bundle = finalize_bundle(map_bundle)
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
	}
	for _, bundle in ipairs(state.sync_bundles) do
		manifest[#manifest + 1] = table.concat({
			bundle.id,
			bundle.kind,
			tostring(bundle.size),
			bundle.archive_sha256,
			bundle.content_sha256,
		}, "|")
	end
	state.manifest_hash = crypto.sha256(table.concat(manifest, "\n"))

	return state.scripts, state.asset_files, state.sync_bundles
end

function M.discover_scripts(state)
	M.discover(state)
	return state.scripts
end

function M.discover_asset_files(state)
	M.discover(state)
	return state.asset_files
end

return M
