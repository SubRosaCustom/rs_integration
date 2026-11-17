local json = require("main.json")
local utf8_sanitize = require("main.src.utf8_sanitize")

local index_response = {}

local cache = {}

local function bundle_metadata_list(state)
	local bundles = {}
	for i = 1, #state.sync_bundles do
		local bundle = state.sync_bundles[i]
		bundles[#bundles + 1] = {
			id = bundle.id,
			kind = bundle.kind,
			size = bundle.size,
			archiveSha256 = bundle.archive_sha256,
			contentSha256 = bundle.content_sha256,
			files = bundle.files,
		}
	end

	return bundles
end

local function build(state)
	local body = utf8_sanitize.sanitize_value({
		type = "INDEX_RES",
		payload = {
			bundles = bundle_metadata_list(state),
			disallowedPaths = state.config.disallowedPaths,
			disableClientTiremarks = state.config.disableClientTiremarks == true,
			disableDiscordJoin = state.config.disableDiscordJoin == true,
			hideDiscordDetails = state.config.hideDiscordDetails == true,
			loadedLevel = state.loaded_level,
			persistentMode = state.persistent_mode,
			runtimeID = state.runtime_id,
			syncGeneration = state.sync_generation,
			manifestHash = state.manifest_hash,
		},
	})
	return json.encode(body) .. "\n"
end

-- fields are snapshot-wide, so the frame is shared and rebuilt when an input changes
function index_response.bytes(state)
	local config = state.config
	if cache.bytes
		and cache.manifest_hash == state.manifest_hash
		and cache.sync_bundles == state.sync_bundles
		and cache.disallowed_paths == config.disallowedPaths
		and cache.tiremarks == config.disableClientTiremarks
		and cache.discord_join == config.disableDiscordJoin
		and cache.discord_details == config.hideDiscordDetails
		and cache.loaded_level == state.loaded_level
		and cache.persistent_mode == state.persistent_mode
		and cache.runtime_id == state.runtime_id
		and cache.sync_generation == state.sync_generation then
		return cache.bytes
	end

	cache = {
		bytes = build(state),
		manifest_hash = state.manifest_hash,
		sync_bundles = state.sync_bundles,
		disallowed_paths = config.disallowedPaths,
		tiremarks = config.disableClientTiremarks,
		discord_join = config.disableDiscordJoin,
		discord_details = config.hideDiscordDetails,
		loaded_level = state.loaded_level,
		persistent_mode = state.persistent_mode,
		runtime_id = state.runtime_id,
		sync_generation = state.sync_generation,
	}
	return cache.bytes
end

return index_response
