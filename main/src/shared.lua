local json = require("main.json")
pcall(require, "librosaserver_src_integration")
local config = require("main.src.config")
local runtime_state = require("main.src.runtime_state")
local sync_paths = require("main.src.sync_paths")
local sync_snapshot = require("main.src.sync_snapshot")

local M = {}

M.DEFAULT_CONFIG = config.DEFAULTS

function M.resolveConfig(raw)
	return config.resolve(raw)
end

function M.getState()
	local state = runtime_state.get()
	return state
end

function M.clientId(connection)
	return string.format("%s:%s", tostring(connection.address), tostring(connection.port))
end

function M.safeJsonDecode(raw)
	if type(raw) ~= "string" or raw == "" then
		return nil
	end

	local ok, decoded = pcall(json.decode, raw)
	if not ok or type(decoded) ~= "table" then
		return nil
	end

	return decoded
end

function M.joinPath(first, second)
	return sync_paths.join(first, second)
end

function M.scriptsRoot(runtime_config)
	return sync_paths.scripts_root(runtime_config)
end

function M.assetsRoot(runtime_config)
	return sync_paths.assets_root(runtime_config)
end

function M.readFile(path)
	return sync_paths.read_file(path)
end

function M.isSafeSyncPath(path)
	return sync_paths.is_safe_script(path)
end

function M.isLuaPath(path)
	return sync_paths.is_lua(path)
end

function M.isSafeAssetSyncPath(path)
	return sync_paths.is_safe_asset(path)
end

function M.eventPayloadSize(payload)
	local ok, encoded = pcall(json.encode, payload)
	if not ok then
		return math.huge
	end
	return #encoded
end

function M.normalizeLoadedLevel(raw_level)
	return sync_snapshot.normalize_loaded_level(raw_level)
end

function M.normalizePersistentMode(raw_mode)
	return sync_snapshot.normalize_persistent_mode(raw_mode)
end

function M.discoverPersistentMode(state)
	return sync_snapshot.discover_persistent_mode(state)
end

function M.discoverSyncFiles(state)
	return sync_snapshot.discover(state)
end

function M.discoverScripts(state)
	return sync_snapshot.discover_scripts(state)
end

function M.discoverAssetFiles(state)
	return sync_snapshot.discover_asset_files(state)
end

return M
