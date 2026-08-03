local config = require("main.src.config")

local M = {}

local GLOBAL_STATE_KEY = "__srcMainState"

local RENAMED_FIELDS = {
	runtimeActive = "runtime_active",
	hooksRegistered = "hooks_registered",
	moduleLoaded = "module_loaded",
	runtimeID = "runtime_id",
	syncGeneration = "sync_generation",
	manifestHash = "manifest_hash",
	tcpBindInProgress = "tcp_bind_in_progress",
	nextEventID = "next_event_id",
	tcpServer = "tcp_server",
	boundPort = "bound_port",
	eventHandlers = "event_handlers",
	eventHandlersByHash = "event_handlers_by_hash",
	eventHashesByName = "event_hashes_by_name",
	scriptsByPath = "scripts_by_path",
	assetFiles = "asset_files",
	assetFilesByPath = "asset_files_by_path",
	syncBundles = "sync_bundles",
	syncBundlesById = "sync_bundles_by_id",
	loadedLevel = "loaded_level",
	persistentMode = "persistent_mode",
	fileWatcher = "file_watcher",
	watchedDirectories = "watched_directories",
	watchedRoot = "watched_root",
	pendingRefreshTick = "pending_refresh_tick",
	itemTypesAPIInstalled = "item_types_api_installed",
	customItemTypesByIndex = "custom_item_types_by_index",
	nextCustomItemTypeIndex = "next_custom_item_type_index",
	itemTypeInitHookRan = "item_type_init_hook_ran",
	itemTypeModelAssignments = "item_type_model_assignments",
	itemTypeIconAssignments = "item_type_icon_assignments",
	itemTypeTextureAssignments = "item_type_texture_assignments",
	itemTypeFireSoundAssignments = "item_type_fire_sound_assignments",
	itemTypeIT3Assignments = "item_type_it3_assignments",
	itemTypeITMAssignments = "item_type_itm_assignments",
	itemTypeNativeFileLoaded = "item_type_native_file_loaded",
	itemTypeSyncMemoryWarningShown = "item_type_sync_memory_warning_shown",
	vehicleTypesAPIInstalled = "vehicle_types_api_installed",
	customVehicleTypesByIndex = "custom_vehicle_types_by_index",
	nextCustomVehicleTypeIndex = "next_custom_vehicle_type_index",
	vehicleTypeInitHookRan = "vehicle_type_init_hook_ran",
	vehicleTypeModelAssignments = "vehicle_type_model_assignments",
	vehicleTypeAudioAssignments = "vehicle_type_audio_assignments",
	humanModelsAPIInstalled = "human_models_api_installed",
	humanModelAssignments = "human_model_assignments",
	srcAdmissionRejections = "src_admission_rejections",
	srcRecoveryGraceUntil = "src_recovery_grace_until",
	browserMarkerMutationStack = "browser_marker_mutation_stack",
}

local function migrate_fields(state)
	local was_legacy = false
	for old_name, new_name in pairs(RENAMED_FIELDS) do
		local old_value = rawget(state, old_name)
		if old_value ~= nil then
			was_legacy = true
			if rawget(state, new_name) == nil then
				rawset(state, new_name, old_value)
			end
			rawset(state, old_name, nil)
		end
	end

	if rawget(state, "buildCustomItemTypesSyncPayload") ~= nil
		or rawget(state, "buildCustomVehicleTypesSyncPayload") ~= nil
		or rawget(state, "sync_world_mutations") ~= nil then
		was_legacy = true
	end

	rawset(state, "buildCustomItemTypesSyncPayload", nil)
	rawset(state, "buildCustomVehicleTypesSyncPayload", nil)
	rawset(state, "sync_world_mutations", nil)

	return was_legacy
end

local function install_legacy_aliases(state)
	local current_metatable = getmetatable(state)
	if current_metatable and rawget(current_metatable, "__src_runtime_state_aliases") then
		return
	end

	local metatable = {}
	if current_metatable then
		for key, value in pairs(current_metatable) do
			metatable[key] = value
		end
	end

	local previous_index = metatable.__index
	local previous_new_index = metatable.__newindex

	metatable.__src_runtime_state_aliases = true
	metatable.__index = function(target, key)
		local renamed = RENAMED_FIELDS[key]
		if renamed then
			return rawget(target, renamed)
		end
		if type(previous_index) == "function" then
			return previous_index(target, key)
		end
		if type(previous_index) == "table" then
			return previous_index[key]
		end
		return nil
	end
	metatable.__newindex = function(target, key, value)
		local renamed = RENAMED_FIELDS[key]
		if renamed then
			rawset(target, renamed, value)
			return
		end
		if type(previous_new_index) == "function" then
			previous_new_index(target, key, value)
			return
		end
		if type(previous_new_index) == "table" then
			previous_new_index[key] = value
			return
		end
		rawset(target, key, value)
	end

	setmetatable(state, metatable)
end

local function install_legacy_connection_aliases(connection)
	if type(connection) ~= "table" or rawget(connection, "isOpen") == nil then
		return
	end

	local current_metatable = getmetatable(connection)
	if current_metatable and rawget(current_metatable, "__src_connection_aliases") then
		return
	end

	local metatable = {}
	if current_metatable then
		for key, value in pairs(current_metatable) do
			metatable[key] = value
		end
	end

	local previous_index = metatable.__index
	local previous_new_index = metatable.__newindex

	metatable.__src_connection_aliases = true
	metatable.__index = function(target, key)
		if key == "is_open" then
			return rawget(target, "isOpen")
		end
		if type(previous_index) == "function" then
			return previous_index(target, key)
		end
		if type(previous_index) == "table" then
			return previous_index[key]
		end
		return nil
	end
	metatable.__newindex = function(target, key, value)
		if key == "is_open" then
			rawset(target, "isOpen", value)
			return
		end
		if type(previous_new_index) == "function" then
			previous_new_index(target, key, value)
			return
		end
		if type(previous_new_index) == "table" then
			previous_new_index[key] = value
			return
		end
		rawset(target, key, value)
	end

	setmetatable(connection, metatable)
end

local function install_legacy_tcp_server_aliases(tcp_server)
	if type(tcp_server) ~= "table" then
		return
	end

	local current_metatable = getmetatable(tcp_server)
	if current_metatable and rawget(current_metatable, "__src_tcp_server_aliases") then
		return
	end

	local metatable = {}
	if current_metatable then
		for key, value in pairs(current_metatable) do
			metatable[key] = value
		end
	end

	local previous_index = metatable.__index
	local previous_new_index = metatable.__newindex
	local renamed_fields = {
		is_open = "isOpen",
		is_listening = "isListening",
	}

	metatable.__src_tcp_server_aliases = true
	metatable.__index = function(target, key)
		local legacy_name = renamed_fields[key]
		if legacy_name then
			return rawget(target, legacy_name)
		end
		if type(previous_index) == "function" then
			return previous_index(target, key)
		end
		if type(previous_index) == "table" then
			return previous_index[key]
		end
		return nil
	end
	metatable.__newindex = function(target, key, value)
		local legacy_name = renamed_fields[key]
		if legacy_name then
			rawset(target, legacy_name, value)
			return
		end
		if type(previous_new_index) == "function" then
			previous_new_index(target, key, value)
			return
		end
		if type(previous_new_index) == "table" then
			previous_new_index[key] = value
			return
		end
		rawset(target, key, value)
	end

	setmetatable(tcp_server, metatable)

	local accept = tcp_server.accept
	if type(accept) == "function" then
		tcp_server.accept = function(target)
			local connection = accept(target)
			install_legacy_connection_aliases(connection)
			return connection
		end
	end
end

local function reset_legacy_runtime(state)
	local connections = {}
	for connection in pairs(state.clients or {}) do
		connections[connection] = true
	end
	if type(state.tcp_server) == "table" then
		for _, connection in pairs(state.tcp_server.connections or {}) do
			connections[connection] = true
		end
		for _, connection in ipairs(state.tcp_server.accept_queue or {}) do
			connections[connection] = true
		end
	end

	for connection in pairs(connections) do
		if type(connection) == "table" and type(connection.close) == "function" then
			pcall(connection.close, connection)
		end
	end

	state.clients = {}
	if type(state.tcp_server) == "table" then
		state.tcp_server.connections = {}
		state.tcp_server.accept_queue = {}
	end
	install_legacy_tcp_server_aliases(state.tcp_server)
	state.hooks_registered = false
	state.module_loaded = false
end

local function new_state()
	return {
		config = config.copy_defaults(),
		enabled = true,
		runtime_active = false,
		hooks_registered = false,
		module_loaded = false,
		runtime_id = tostring(os.realClock and os.realClock() or os.clock()),
		sync_generation = 1,
		manifest_hash = "",
		tcp_bind_in_progress = false,
		tick = 0,
		next_event_id = 0x80000000,
		tcp_server = nil,
		bound_port = nil,
		clients = {},
		event_handlers = {},
		event_handlers_by_hash = {},
		event_hashes_by_name = {},
		scripts = {},
		scripts_by_path = {},
		asset_files = {},
		asset_files_by_path = {},
		sync_bundles = {},
		sync_bundles_by_id = {},
		loaded_level = "",
		persistent_mode = "",
		file_watcher = nil,
		watched_directories = {},
		watched_root = nil,
		pending_refresh_tick = nil,
		item_types_api_installed = false,
		custom_item_types_by_index = {},
		next_custom_item_type_index = 46,
		item_type_init_hook_ran = false,
		item_type_model_assignments = {},
		item_type_icon_assignments = {},
		item_type_texture_assignments = {},
		item_type_fire_sound_assignments = {},
		item_type_it3_assignments = {},
		item_type_itm_assignments = {},
		item_type_native_file_loaded = {},
		item_type_sync_memory_warning_shown = false,
		vehicle_types_api_installed = false,
		custom_vehicle_types_by_index = {},
		next_custom_vehicle_type_index = 17,
		vehicle_type_init_hook_ran = false,
		vehicle_type_model_assignments = {},
		vehicle_type_audio_assignments = {},
		human_models_api_installed = false,
		human_model_assignments = {},
		src_admission_rejections = {},
		src_recovery_grace_until = 0,
		browser_marker_mutation_stack = {},
		world_mutation_generation = 1,
		deleted_world_blocks = {},
	}
end

function M.get()
	local state = _G[GLOBAL_STATE_KEY]
	if state then
		local was_legacy = migrate_fields(state)
		if was_legacy then
			reset_legacy_runtime(state)
		end
		install_legacy_aliases(state)
		return state, was_legacy
	end

	state = new_state()
	install_legacy_aliases(state)
	_G[GLOBAL_STATE_KEY] = state
	return state, false
end

return M
