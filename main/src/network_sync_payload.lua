local log = require("main.src.log")
local threaded_tcp_codec = require("main.src.threaded_tcp_codec")
local udp_events = require("main.src.udp_events")
local network_session = require("main.src.network_session")

local get_player_connection = network_session.get_player_connection
local validate_bound_player = network_session.validate_bound_player
local enqueue_bytes = network_session.enqueue_bytes
local enqueue_frame = network_session.enqueue_frame

local network_sync_payload = {}

local function queue_item_types_sync_frame(state, connection, payload)
	local client = state.clients[connection]
	if not client or not connection.is_open or not client.hello then
		return false
	end

	if type(payload) ~= "table" then
		return false
	end

	if type(payload.itemTypes) ~= "table" then
		return false
	end

	if type(payload.binRaw) ~= "string" then
		return false
	end

	local estimated_size = 6 + (#payload.itemTypes * 4) + #payload.binRaw
	if estimated_size > state.config.maxEventBytes then
		log.warn("item type sync payload too large; dropping")
		return false
	end

	local segments = {
		string.pack(">I2I2I2", payload.version or 1, payload.itemTypeSize or 0, #payload.itemTypes),
	}
	for i = 1, #payload.itemTypes do
		local entry = payload.itemTypes[i]
		segments[#segments + 1] = string.pack(">I2I2", entry.index or 0, entry.sourceIndex or 0)
	end
	segments[#segments + 1] = payload.binRaw

	local binary_frame = threaded_tcp_codec.encode_binary_frame("ITEM_TYPES_SYNC", table.concat(segments))
	if not binary_frame then
		return false
	end

	return enqueue_bytes(state, connection, binary_frame)
end

local function queue_vehicle_types_sync_frame(state, connection, payload)
	local client = state.clients[connection]
	if not client or not connection.is_open or not client.hello then
		return false
	end

	if type(payload) ~= "table" then
		return false
	end

	if type(payload.vehicleTypes) ~= "table" then
		return false
	end

	return enqueue_frame(state, connection, "VEHICLE_TYPES_SYNC", payload)
end

local function queue_item_type_model_frame(state, connection, index, model_name)
	local client = state.clients[connection]
	if not client or not connection.is_open or not client.hello then
		return false
	end

	return enqueue_frame(state, connection, "ITEM_TYPE_MODEL", {
		index = index,
		model = model_name,
	})
end

local function queue_item_type_itm_frame(state, connection, index, itm_path)
	local client = state.clients[connection]
	if not client or not connection.is_open or not client.hello then
		return false
	end

	return enqueue_frame(state, connection, "ITEM_TYPE_ITM", {
		index = index,
		itm = itm_path,
	})
end

local function queue_item_type_it3_frame(state, connection, index, it3_path)
	local client = state.clients[connection]
	if not client or not connection.is_open or not client.hello then
		return false
	end

	return enqueue_frame(state, connection, "ITEM_TYPE_IT3", {
		index = index,
		it3 = it3_path,
	})
end

local function queue_vehicle_type_model_frame(state, connection, index, model_name)
	local client = state.clients[connection]
	if not client or not connection.is_open or not client.hello then
		return false
	end

	return enqueue_frame(state, connection, "VEHICLE_TYPE_MODEL", {
		index = index,
		model = model_name,
	})
end

local function queue_item_type_icon_frame(state, connection, index, icon_path)
	local client = state.clients[connection]
	if not client or not connection.is_open or not client.hello then
		return false
	end

	return enqueue_frame(state, connection, "ITEM_TYPE_ICON", {
		index = index,
		icon = icon_path,
	})
end

local function queue_item_type_texture_frame(state, connection, index, texture_assignment)
	local client = state.clients[connection]
	if not client or not connection.is_open or not client.hello then
		return false
	end

	if type(texture_assignment) ~= "table" then
		return false
	end

	local payload = {
		index = index,
	}

	if texture_assignment.kind == "builtin" then
		payload.builtinTexture = texture_assignment.builtin
	elseif texture_assignment.kind == "file" then
		payload.texture = texture_assignment.file
	else
		return false
	end

	return enqueue_frame(state, connection, "ITEM_TYPE_TEXTURE", payload)
end

local function queue_item_type_fire_sounds_frame(state, connection, index, sound_assignment)
	local client = state.clients[connection]
	if not client or not connection.is_open or not client.hello then
		return false
	end

	if type(sound_assignment) ~= "table" then
		return false
	end

	local payload = {
		index = index,
	}

	if sound_assignment.kind == "builtin" then
		payload.builtinFireSound = sound_assignment.builtin
	elseif sound_assignment.kind == "files" then
		payload.fireSounds = sound_assignment.files
	else
		return false
	end

	return enqueue_frame(state, connection, "ITEM_TYPE_FIRE_SOUNDS", payload)
end

local function queue_vehicle_type_audio_frame(state, connection, index, audio_reference)
	local client = state.clients[connection]
	if not client or not connection.is_open or not client.hello then
		return false
	end

	return enqueue_frame(state, connection, "VEHICLE_TYPE_AUDIO", {
		index = index,
		audio = audio_reference,
	})
end

local function queue_human_model_frame(state, connection, index, assignment)
	local client = state.clients[connection]
	if not client or not connection.is_open or not client.hello then
		return false
	end

	if type(assignment) ~= "table" then
		return false
	end

	local male = assignment.male
	local female = assignment.female
	if type(male) ~= "string" or male == "" or type(female) ~= "string" or female == "" then
		return false
	end

	return enqueue_frame(state, connection, "HUMAN_MODEL_DEF", {
		index = index,
		male = male,
		female = female,
	})
end

local function queue_human_accessory_frame(state, connection, message_type, index, assignment)
	local client = state.clients[connection]
	if not client or not connection.is_open or not client.hello then
		return false
	end
	if type(assignment) ~= "table"
		or type(assignment.male) ~= "string" or assignment.male == ""
		or type(assignment.female) ~= "string" or assignment.female == "" then
		return false
	end

	return enqueue_frame(state, connection, message_type, {
		index = index,
		male = assignment.male,
		female = assignment.female,
	})
end

local function send_initial_custom_item_sync(state, connection)
	local item_types = require("main.src.item_types")
	if type(item_types.build_sync_payload) == "function" then
		local ok, payload_or_error = pcall(item_types.build_sync_payload, state)
		if ok then
			local payload = payload_or_error
			local defined_types = {}
			for _, entry in ipairs(type(payload) == "table" and payload.itemTypes or {}) do
				defined_types[entry.index] = true
			end
			if type(payload) == "table" and type(payload.itemTypes) == "table" then
				queue_item_types_sync_frame(state, connection, payload)
			end

			local model_assignments = state.item_type_model_assignments
			if type(model_assignments) == "table" then
				for idx, model_name in pairs(model_assignments) do
					if defined_types[idx] or idx < 46 then
						queue_item_type_model_frame(state, connection, idx, model_name)
					end
				end
			end

			if type(payload) == "table" and type(payload.itemTypes) == "table" then
				local itm_assignments = state.item_type_itm_assignments
				if type(itm_assignments) == "table" then
					for idx, itm_path in pairs(itm_assignments) do
						if defined_types[idx] then
							queue_item_type_itm_frame(state, connection, idx, itm_path)
						end
					end
				end

				local it3_assignments = state.item_type_it3_assignments
				if type(it3_assignments) == "table" then
					for idx, it3_path in pairs(it3_assignments) do
						if defined_types[idx] then
							queue_item_type_it3_frame(state, connection, idx, it3_path)
						end
					end
				end

				local icon_assignments = state.item_type_icon_assignments
				if type(icon_assignments) == "table" then
					for idx, icon_path in pairs(icon_assignments) do
						if defined_types[idx] then
							queue_item_type_icon_frame(state, connection, idx, icon_path)
						end
					end
				end

				local texture_assignments = state.item_type_texture_assignments
				if type(texture_assignments) == "table" then
					for idx, texture_assignment in pairs(texture_assignments) do
						if defined_types[idx] then
							queue_item_type_texture_frame(state, connection, idx, texture_assignment)
						end
					end
				end

				local fire_sound_assignments = state.item_type_fire_sound_assignments
				if type(fire_sound_assignments) == "table" then
					for idx, sound_assignment in pairs(fire_sound_assignments) do
						if defined_types[idx] then
							queue_item_type_fire_sounds_frame(state, connection, idx, sound_assignment)
						end
					end
				end
			end
		else
			log.warn("failed building custom item type sync payload: %s", tostring(payload_or_error))
		end
	end

	local human_model_assignments = state.human_model_assignments
	if type(human_model_assignments) == "table" then
		for idx, assignment in pairs(human_model_assignments) do
			queue_human_model_frame(state, connection, idx, assignment)
		end
	end

	for idx, assignment in pairs(state.human_necktie_assignments) do
		queue_human_accessory_frame(state, connection, "HUMAN_NECKTIE_DEF", idx, assignment)
	end
	for idx, assignment in pairs(state.human_necklace_assignments) do
		queue_human_accessory_frame(state, connection, "HUMAN_NECKLACE_DEF", idx, assignment)
	end
end

local function send_initial_custom_vehicle_sync(state, connection)
	local vehicle_types = require("main.src.vehicle_types")
	if type(vehicle_types.build_sync_payload) == "function" then
		local ok, payload_or_error = pcall(vehicle_types.build_sync_payload, state)
		if ok then
			local payload = payload_or_error
			if type(payload) == "table" and type(payload.vehicleTypes) == "table" then
				queue_vehicle_types_sync_frame(state, connection, payload)
				local defined_types = {}
				for _, entry in ipairs(payload.vehicleTypes) do
					defined_types[entry.index] = true
				end

				local model_assignments = state.vehicle_type_model_assignments
				if type(model_assignments) == "table" then
					for idx, model_name in pairs(model_assignments) do
						if defined_types[idx] then
							queue_vehicle_type_model_frame(state, connection, idx, model_name)
						end
					end
				end

				local audio_assignments = state.vehicle_type_audio_assignments
				if type(audio_assignments) == "table" then
					for idx, audio_reference in pairs(audio_assignments) do
						if defined_types[idx] then
							queue_vehicle_type_audio_frame(state, connection, idx, audio_reference)
						end
					end
				end
			end
		else
			log.warn("failed building custom vehicle type sync payload: %s", tostring(payload_or_error))
		end
	end
end

-- Live pushes skip clients whose refresh notice is still pending: they still hold the old file
-- list, and the INDEX_REQ that follows the notice resends the complete current snapshot.
function network_sync_payload.binary(bytes)
	return udp_events.binary(bytes)
end

function network_sync_payload.sync_client_item_types(state, player, payload)
	if type(payload) ~= "table" then
		return false
	end

	if player == nil then
		local sent = 0
		for connection, client in pairs(state.clients) do
			if connection.is_open and client.hello and client.bound
				and not client.pending_refresh_notice
				and validate_bound_player(connection, client) then
				if queue_item_types_sync_frame(state, connection, payload) then
					sent = sent + 1
				end
			end
		end
		return sent
	end

	if type(player) ~= "userdata" or player.class ~= "Player" then
		return false
	end

	if player.isBot then
		return false
	end

	local connection = get_player_connection(state, player)
	if not connection or state.clients[connection].pending_refresh_notice then
		return false
	end

	return queue_item_types_sync_frame(state, connection, payload)
end

function network_sync_payload.sync_client_vehicle_types(state, player, payload)
	if type(payload) ~= "table" then
		return false
	end

	if player == nil then
		local sent = 0
		for connection, client in pairs(state.clients) do
			if connection.is_open and client.hello and client.bound
				and not client.pending_refresh_notice
				and validate_bound_player(connection, client) then
				if queue_vehicle_types_sync_frame(state, connection, payload) then
					sent = sent + 1
				end
			end
		end
		return sent
	end

	if type(player) ~= "userdata" or player.class ~= "Player" then
		return false
	end

	if player.isBot then
		return false
	end

	local connection = get_player_connection(state, player)
	if not connection or state.clients[connection].pending_refresh_notice then
		return false
	end

	return queue_vehicle_types_sync_frame(state, connection, payload)
end

function network_sync_payload.send_item_type_icon(state, player, index, icon_path)
	if player == nil then
		local sent = 0
		for connection, client in pairs(state.clients) do
			if connection.is_open and client.hello and client.bound
				and not client.pending_refresh_notice
				and validate_bound_player(connection, client) then
				if queue_item_type_icon_frame(state, connection, index, icon_path) then
					sent = sent + 1
				end
			end
		end
		return sent
	end

	if type(player) ~= "userdata" or player.class ~= "Player" then
		return false
	end

	if player.isBot then
		return false
	end

	local connection = get_player_connection(state, player)
	if not connection or state.clients[connection].pending_refresh_notice then
		return false
	end

	return queue_item_type_icon_frame(state, connection, index, icon_path)
end

function network_sync_payload.send_item_type_texture(state, player, index, texture_assignment)
	if player == nil then
		local sent = 0
		for connection, client in pairs(state.clients) do
			if connection.is_open and client.hello and client.bound
				and not client.pending_refresh_notice
				and validate_bound_player(connection, client) then
				if queue_item_type_texture_frame(state, connection, index, texture_assignment) then
					sent = sent + 1
				end
			end
		end
		return sent
	end

	if type(player) ~= "userdata" or player.class ~= "Player" then
		return false
	end

	if player.isBot then
		return false
	end

	local connection = get_player_connection(state, player)
	if not connection or state.clients[connection].pending_refresh_notice then
		return false
	end

	return queue_item_type_texture_frame(state, connection, index, texture_assignment)
end

function network_sync_payload.send_item_type_fire_sounds(state, player, index, sound_assignment)
	if player == nil then
		local sent = 0
		for connection, client in pairs(state.clients) do
			if connection.is_open and client.hello and client.bound
				and not client.pending_refresh_notice
				and validate_bound_player(connection, client) then
				if queue_item_type_fire_sounds_frame(state, connection, index, sound_assignment) then
					sent = sent + 1
				end
			end
		end
		return sent
	end

	if type(player) ~= "userdata" or player.class ~= "Player" then
		return false
	end

	if player.isBot then
		return false
	end

	local connection = get_player_connection(state, player)
	if not connection or state.clients[connection].pending_refresh_notice then
		return false
	end

	return queue_item_type_fire_sounds_frame(state, connection, index, sound_assignment)
end

function network_sync_payload.send_item_type_itm(state, player, index, itm_path)
	if player == nil then
		local sent = 0
		for connection, client in pairs(state.clients) do
			if connection.is_open and client.hello and client.bound
				and not client.pending_refresh_notice
				and validate_bound_player(connection, client) then
				if queue_item_type_itm_frame(state, connection, index, itm_path) then
					sent = sent + 1
				end
			end
		end
		return sent
	end

	if type(player) ~= "userdata" or player.class ~= "Player" then
		return false
	end

	if player.isBot then
		return false
	end

	local connection = get_player_connection(state, player)
	if not connection or state.clients[connection].pending_refresh_notice then
		return false
	end

	return queue_item_type_itm_frame(state, connection, index, itm_path)
end

function network_sync_payload.send_item_type_it3(state, player, index, it3_path)
	if player == nil then
		local sent = 0
		for connection, client in pairs(state.clients) do
			if connection.is_open and client.hello and client.bound
				and not client.pending_refresh_notice
				and validate_bound_player(connection, client) then
				if queue_item_type_it3_frame(state, connection, index, it3_path) then
					sent = sent + 1
				end
			end
		end
		return sent
	end

	if type(player) ~= "userdata" or player.class ~= "Player" then
		return false
	end

	if player.isBot then
		return false
	end

	local connection = get_player_connection(state, player)
	if not connection or state.clients[connection].pending_refresh_notice then
		return false
	end

	return queue_item_type_it3_frame(state, connection, index, it3_path)
end

function network_sync_payload.send_human_model(state, player, index, assignment)
	if player == nil then
		local sent = 0
		for connection, client in pairs(state.clients) do
			if connection.is_open and client.hello and client.bound
				and not client.pending_refresh_notice
				and validate_bound_player(connection, client) then
				if queue_human_model_frame(state, connection, index, assignment) then
					sent = sent + 1
				end
			end
		end
		return sent
	end

	if type(player) ~= "userdata" or player.class ~= "Player" then
		return false
	end

	if player.isBot then
		return false
	end

	local connection = get_player_connection(state, player)
	if not connection or state.clients[connection].pending_refresh_notice then
		return false
	end

	return queue_human_model_frame(state, connection, index, assignment)
end

local function send_human_accessory(state, player, message_type, index, assignment)
	if player == nil then
		local sent = 0
		for connection, client in pairs(state.clients) do
			if connection.is_open and client.hello and client.bound
				and validate_bound_player(connection, client)
				and queue_human_accessory_frame(state, connection, message_type, index, assignment) then
				sent = sent + 1
			end
		end
		return sent
	end

	if type(player) ~= "userdata" or player.class ~= "Player" or player.isBot then
		return false
	end
	local connection = get_player_connection(state, player)
	return connection and queue_human_accessory_frame(state, connection, message_type, index, assignment) or false
end

function network_sync_payload.send_human_necktie(state, player, index, assignment)
	return send_human_accessory(state, player, "HUMAN_NECKTIE_DEF", index, assignment)
end

function network_sync_payload.send_human_necklace(state, player, index, assignment)
	return send_human_accessory(state, player, "HUMAN_NECKLACE_DEF", index, assignment)
end

function network_sync_payload.send_vehicle_type_model(state, player, index, model_name)
	if player == nil then
		local sent = 0
		for connection, client in pairs(state.clients) do
			if connection.is_open and client.hello and client.bound
				and not client.pending_refresh_notice
				and validate_bound_player(connection, client) then
				if queue_vehicle_type_model_frame(state, connection, index, model_name) then
					sent = sent + 1
				end
			end
		end
		return sent
	end

	if type(player) ~= "userdata" or player.class ~= "Player" then
		return false
	end

	if player.isBot then
		return false
	end

	local connection = get_player_connection(state, player)
	if not connection or state.clients[connection].pending_refresh_notice then
		return false
	end

	return queue_vehicle_type_model_frame(state, connection, index, model_name)
end

function network_sync_payload.send_vehicle_type_audio(state, player, index, audio_reference)
	if player == nil then
		local sent = 0
		for connection, client in pairs(state.clients) do
			if connection.is_open and client.hello and client.bound
				and not client.pending_refresh_notice
				and validate_bound_player(connection, client) then
				if queue_vehicle_type_audio_frame(state, connection, index, audio_reference) then
					sent = sent + 1
				end
			end
		end
		return sent
	end

	if type(player) ~= "userdata" or player.class ~= "Player" then
		return false
	end

	if player.isBot then
		return false
	end

	local connection = get_player_connection(state, player)
	if not connection or state.clients[connection].pending_refresh_notice then
		return false
	end

	return queue_vehicle_type_audio_frame(state, connection, index, audio_reference)
end

function network_sync_payload.send_item_type_model(state, player, index, model_name)
	if player == nil then
		local sent = 0
		for connection, client in pairs(state.clients) do
			if connection.is_open and client.hello and client.bound
				and not client.pending_refresh_notice
				and validate_bound_player(connection, client) then
				if queue_item_type_model_frame(state, connection, index, model_name) then
					sent = sent + 1
				end
			end
		end
		return sent
	end

	if type(player) ~= "userdata" or player.class ~= "Player" then
		return false
	end

	if player.isBot then
		return false
	end

	local connection = get_player_connection(state, player)
	if not connection or state.clients[connection].pending_refresh_notice then
		return false
	end

	return queue_item_type_model_frame(state, connection, index, model_name)
end

network_sync_payload.send_initial_custom_item_sync = send_initial_custom_item_sync
network_sync_payload.send_initial_custom_vehicle_sync = send_initial_custom_vehicle_sync

return network_sync_payload
