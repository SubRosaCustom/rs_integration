local config = require("main.src.config")

local runtime_state = {}

local GLOBAL_STATE_KEY = "__srcMainState"

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
		tcp_server = nil,
		bound_port = nil,
		clients = {},
		clients_by_token = {},
		clients_by_endpoint = {},
		udp_backlog = {},
		watcher_warn_limits = {},
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
		human_accessories_api_installed = false,
		human_model_assignments = {},
		human_necktie_assignments = {},
		human_necklace_assignments = {},
		src_admission_rejections = {},
		src_recovery_grace_until = 0,
		browser_marker_mutation_stack = {},
		world_mutation_generation = 1,
		deleted_world_blocks = {},
	}
end

runtime_state.new = new_state

function runtime_state.get()
	local state = _G[GLOBAL_STATE_KEY]
	state = state or {}
	_G[GLOBAL_STATE_KEY] = state
	-- state from before a code reload may lack newer fields
	for key, value in pairs(new_state()) do
		if state[key] == nil then
			state[key] = value
		end
	end
	return state
end

return runtime_state
