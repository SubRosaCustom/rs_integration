local log = require("main.src.log")

local M = {}

local PROTOCOL_VERSION = 1
local MAX_VEHICLE_TYPE_COUNT = 128
local MAX_VEHICLE_TYPE_INDEX = MAX_VEHICLE_TYPE_COUNT - 1
local FIRST_CUSTOM_INDEX = 17
local VEHICLE_TYPE_SIZE = 0x185C0
local SERVER_VEHICLE_TYPES_OFFSET = 0x4d03560

local OFFSET_USES_EXTERNAL_MODEL = 0x0
local OFFSET_CONTROLLABLE_STATE = 0x8
local OFFSET_PRICE = 0x34
local OFFSET_MASS = 0x38
local OFFSET_ACCELERATION = 0x17874
local OFFSET_NUM_WHEELS = 0x17878
local OFFSET_FIRST_WHEEL_MASS = 0x17890
local OFFSET_FIRST_WHEEL_RADIUS = 0x17894
local OFFSET_NUM_SEATS = 0x18318
local OFFSET_SEAT_POS = 0x1831c
local VECTOR_SIZE = 12
local DEFAULT_WHEEL_RADIUS = 0.3125
local DEFAULT_WHEEL_MASS = 12
local DEFAULT_INITIAL_WHEEL_FLAGS = 2
local ZERO_VEHICLE_TYPE_BYTES = string.rep("\0", VEHICLE_TYPE_SIZE)

local function safe_read(obj, key)
	local ok, value = pcall(function()
		return obj[key]
	end)
	if not ok then
		return nil
	end
	return value
end

local function normalize_index(index, minimum, maximum)
	if type(index) ~= "number" or index ~= index then
		return nil
	end

	index = math.floor(index)
	if index < minimum or index > maximum then
		return nil
	end

	return index
end

local function has_memory_api()
	return type(memory) == "table"
		and type(memory.getAddress) == "function"
		and type(memory.readFloat) == "function"
		and type(memory.writeFloat) == "function"
		and type(memory.readInt) == "function"
		and type(memory.writeInt) == "function"
		and type(memory.writeBytes) == "function"
end

local function get_native_vehicle_type_api()
	if type(srcIntegrationNative) ~= "table" then
		return nil
	end

	if type(srcIntegrationNative.loadSBV) ~= "function"
		or type(srcIntegrationNative.setupVehicleTypeNew) ~= "function"
		or type(srcIntegrationNative.setupObjectTypeWeight) ~= "function" then
		return nil
	end

	return srcIntegrationNative
end

local function is_vehicle_type_userdata(value)
	return type(value) == "userdata" and safe_read(value, "class") == "VehicleType"
end

local function get_vehicle_type_by_index(index)
	local normalized = normalize_index(index, 0, MAX_VEHICLE_TYPE_INDEX)
	if normalized == nil then
		return nil
	end

	local ok, value = pcall(function()
		return vehicleTypes[normalized]
	end)
	if not ok then
		return nil
	end

	return value
end

local function get_vehicle_type_index(ref)
	if is_vehicle_type_userdata(ref) then
		return normalize_index(safe_read(ref, "index"), 0, MAX_VEHICLE_TYPE_INDEX)
	end

	if type(ref) == "number" then
		return normalize_index(ref, 0, MAX_VEHICLE_TYPE_INDEX)
	end

	return nil
end

local function get_vehicle_type_address(vehicle_type)
	if not has_memory_api() then
		return nil, "memory api unavailable"
	end

	local address_ok, address = pcall(memory.getAddress, vehicle_type)
	if not address_ok or type(address) ~= "number" or address <= 0 then
		return nil, "failed to resolve vehicle type address"
	end

	return address
end

local function get_vehicle_type_slot_address(index)
	if not has_memory_api() then
		return nil
	end

	local normalized = normalize_index(index, 0, MAX_VEHICLE_TYPE_INDEX)
	if normalized == nil then
		return nil
	end

	return memory.getBaseAddress() + SERVER_VEHICLE_TYPES_OFFSET + (normalized * VEHICLE_TYPE_SIZE)
end

local function clear_vehicle_type_slot(address)
	local ok, err = pcall(memory.writeBytes, address, ZERO_VEHICLE_TYPE_BYTES)
	assert(ok, "vehicleTypes.new: failed to clear target vehicle type slot (" .. tostring(err) .. ")")
end

local function clear_custom_vehicle_type_slots()
	local native_api = get_native_vehicle_type_api()
	if native_api and type(native_api.clearCustomVehicleTypeSlots) == "function" then
		native_api.clearCustomVehicleTypeSlots()
		return
	end

	if not has_memory_api() then
		return
	end

	for index = FIRST_CUSTOM_INDEX, MAX_VEHICLE_TYPE_INDEX do
		clear_vehicle_type_slot(memory.getBaseAddress() + SERVER_VEHICLE_TYPES_OFFSET + (index * VEHICLE_TYPE_SIZE))
	end
end

local function normalize_seat_vector(value)
	if type(value) == "userdata" and safe_read(value, "class") == "Vector" then
		return {
			x = tonumber(safe_read(value, "x")) or 0,
			y = tonumber(safe_read(value, "y")) or 0,
			z = tonumber(safe_read(value, "z")) or 0,
		}
	end

	assert(type(value) == "table", "vehicleTypes.new: seatPos entries must be Vector-like tables")
	return {
		x = tonumber(value.x) or 0,
		y = tonumber(value.y) or 0,
		z = tonumber(value.z) or 0,
	}
end

local function normalize_seat_positions(seat_count, seat_positions)
	assert(type(seat_positions) == "table", "vehicleTypes.new: seatPos must be a table")

	local normalized = {}
	for i = 1, 4 do
		local raw = seat_positions[i]
		if i <= seat_count then
			assert(raw ~= nil, "vehicleTypes.new: missing seatPos[" .. i .. "]")
			normalized[i] = normalize_seat_vector(raw)
		else
			normalized[i] = { x = 0, y = 0, z = 0 }
		end
	end

	return normalized
end

local function read_seat_positions(address)
	local seat_positions = {}
	for i = 0, 3 do
		local base = address + OFFSET_SEAT_POS + (i * VECTOR_SIZE)
		seat_positions[i + 1] = {
			x = memory.readFloat(base),
			y = memory.readFloat(base + 4),
			z = memory.readFloat(base + 8),
		}
	end
	return seat_positions
end

local function write_seat_positions(address, seat_positions)
	for i = 0, 3 do
		local base = address + OFFSET_SEAT_POS + (i * VECTOR_SIZE)
		local value = seat_positions[i + 1] or { x = 0, y = 0, z = 0 }
		memory.writeFloat(base, value.x or 0)
		memory.writeFloat(base + 4, value.y or 0)
		memory.writeFloat(base + 8, value.z or 0)
	end
end

local function resolve_vehicle_type(ref)
	if is_vehicle_type_userdata(ref) then
		return ref
	end

	if type(ref) == "number" then
		return get_vehicle_type_by_index(ref)
	end

	if type(ref) == "string" and ref ~= "" and type(vehicleTypes.getByName) == "function" then
		local ok, vehicle_type = pcall(vehicleTypes.getByName, ref)
		if ok then
			return vehicle_type
		end
	end

	return nil
end

local function normalize_custom_index(index)
	return normalize_index(index, FIRST_CUSTOM_INDEX, MAX_VEHICLE_TYPE_INDEX)
end

local function allocate_next_custom_index(state)
	local entries_by_index = state.custom_vehicle_types_by_index or {}
	local next_index = state.next_custom_vehicle_type_index or FIRST_CUSTOM_INDEX

	while next_index <= MAX_VEHICLE_TYPE_INDEX and entries_by_index[next_index] do
		next_index = next_index + 1
	end

	if next_index > MAX_VEHICLE_TYPE_INDEX then
		return nil, "no more custom vehicle type slots available (max index " .. MAX_VEHICLE_TYPE_INDEX .. ")"
	end

	state.next_custom_vehicle_type_index = next_index + 1
	return next_index
end

local function validate_model(model)
	assert(type(model) == "string" and model ~= "", "vehicleTypes.new: model must be a non-empty string")
	assert(not model:find("[/\\]"), "vehicleTypes.new: model must be an SBV name, not a path")
	assert(not string.lower(model):match("%.tst$"), "vehicleTypes.new: TST models are not supported")
	local path = "data/" .. model .. ".sbv"
	local file = io.open(path, "rb")
	assert(file ~= nil, "vehicleTypes.new: missing SBV file " .. path)
	file:close()
	return model
end

local function normalize_audio(audio)
	assert(type(audio) == "string" and audio ~= "", "vehicleTypes.new: audio must be a non-empty string")
	return audio
end

local function normalize_wheel_radius(wheel_radius)
	if wheel_radius == nil then
		return DEFAULT_WHEEL_RADIUS
	end

	assert(type(wheel_radius) == "number", "vehicleTypes.new: wheelRadius must be a number")
	assert(wheel_radius > 0, "vehicleTypes.new: wheelRadius must be > 0")
	return wheel_radius
end

local function normalize_wheel_mass(wheel_mass)
	if wheel_mass == nil then
		return DEFAULT_WHEEL_MASS
	end

	assert(type(wheel_mass) == "number", "vehicleTypes.new: wheelMass must be a number")
	assert(wheel_mass > 0, "vehicleTypes.new: wheelMass must be > 0")
	return wheel_mass
end

local function read_source_wheel_radius(address)
	local wheel_count = memory.readInt(address + OFFSET_NUM_WHEELS)
	if type(wheel_count) ~= "number" or wheel_count <= 0 then
		return DEFAULT_WHEEL_RADIUS
	end

	local wheel_radius = memory.readFloat(address + OFFSET_FIRST_WHEEL_RADIUS)
	if type(wheel_radius) == "number" and wheel_radius > 0 then
		return wheel_radius
	end

	return DEFAULT_WHEEL_RADIUS
end

local function read_source_wheel_mass(address)
	local wheel_count = memory.readInt(address + OFFSET_NUM_WHEELS)
	if type(wheel_count) ~= "number" or wheel_count <= 0 then
		return DEFAULT_WHEEL_MASS
	end

	local wheel_mass = memory.readFloat(address + OFFSET_FIRST_WHEEL_MASS)
	if type(wheel_mass) == "number" and wheel_mass > 0 then
		return wheel_mass
	end

	return DEFAULT_WHEEL_MASS
end

local function build_definition(name, controllable_state, uses_external_model, price, mass, acceleration, model,
		seat_count, seat_positions, audio, wheel_radius, wheel_mass, index)
	assert(type(name) == "string" and name ~= "", "vehicleTypes.new: name must be a non-empty string")
	assert(type(controllable_state) == "number", "vehicleTypes.new: controllableState must be a number")
	assert(type(uses_external_model) == "boolean" or type(uses_external_model) == "number",
		"vehicleTypes.new: usesExternalModel must be boolean or number")
	assert(type(price) == "number", "vehicleTypes.new: price must be a number")
	assert(type(mass) == "number", "vehicleTypes.new: mass must be a number")
	assert(type(acceleration) == "number", "vehicleTypes.new: acceleration must be a number")
	assert(type(seat_count) == "number", "vehicleTypes.new: numSeats must be a number")

	local normalized_seat_count = math.floor(seat_count)
	assert(normalized_seat_count >= 0 and normalized_seat_count <= 4, "vehicleTypes.new: numSeats must be in range 0..4")

	return {
		index = index,
		name = name,
		controllableState = math.floor(controllable_state),
		usesExternalModel = ((uses_external_model == true or uses_external_model == 1) and 1 or 0),
		price = math.floor(price),
		mass = mass,
		acceleration = acceleration,
		model = validate_model(model),
		numSeats = normalized_seat_count,
		seatPos = normalize_seat_positions(normalized_seat_count, seat_positions),
		audio = normalize_audio(audio),
		wheelRadius = normalize_wheel_radius(wheel_radius),
		wheelMass = normalize_wheel_mass(wheel_mass),
	}
end

local function write_definition_to_vehicle_type(target_type, definition)
	local address, address_error = get_vehicle_type_address(target_type)
	assert(address ~= nil, "vehicleTypes.new: failed to resolve vehicle type address (" .. tostring(address_error) .. ")")

	target_type.name = definition.name
	memory.writeInt(address + OFFSET_CONTROLLABLE_STATE, definition.controllableState)
	memory.writeInt(address + OFFSET_USES_EXTERNAL_MODEL, definition.usesExternalModel)
	memory.writeInt(address + OFFSET_PRICE, definition.price)
	memory.writeFloat(address + OFFSET_MASS, definition.mass)
	memory.writeFloat(address + OFFSET_ACCELERATION, definition.acceleration)
	return address
end

local function finalize_vehicle_type_definition(target_type, definition, address)
	local native_api = get_native_vehicle_type_api()
	assert(native_api ~= nil, "vehicleTypes.new: srcIntegrationNative vehicle helpers unavailable")

	local target_index = get_vehicle_type_index(target_type)
	assert(target_index ~= nil, "vehicleTypes.new: failed to resolve target vehicle type index")

	native_api.loadSBV(target_index, definition.model)
	native_api.setupVehicleTypeNew(
		target_index,
		DEFAULT_INITIAL_WHEEL_FLAGS,
		definition.wheelRadius,
		definition.wheelMass
	)
	memory.writeInt(address + OFFSET_NUM_SEATS, definition.numSeats)
	write_seat_positions(address, definition.seatPos)
	native_api.setupObjectTypeWeight(target_index)
end

function M.build_sync_payload(state)
	local entries = {}
	for _, entry in pairs(state.custom_vehicle_types_by_index or {}) do
		if type(entry) == "table" then
			entries[#entries + 1] = entry
		end
	end

	table.sort(entries, function(a, b)
		return (a.index or 0) < (b.index or 0)
	end)

	if #entries == 0 then
		return nil
	end

	return {
		version = PROTOCOL_VERSION,
		vehicleTypes = entries,
	}
end

local function emit_sync_payload(src, payload, player)
	if type(src) ~= "table" or type(src.syncClientVehicleTypes) ~= "function" then
		return false
	end

	local ok, sent = pcall(src.syncClientVehicleTypes, player, payload)
	if not ok then
		log.warn("failed to emit custom vehicle type sync payload: %s", tostring(sent))
		return false
	end

	return sent and true or false
end

local function broadcast_custom_vehicle_types(state, src)
	local payload = M.build_sync_payload(state)
	if payload then
		emit_sync_payload(src, payload, nil)
	end
end

local function record_definition(state, definition, source_index)
	state.custom_vehicle_types_by_index = state.custom_vehicle_types_by_index or {}
	state.custom_vehicle_types_by_index[definition.index] = {
		index = definition.index,
		sourceIndex = source_index or -1,
		name = definition.name,
		controllableState = definition.controllableState,
		usesExternalModel = definition.usesExternalModel,
		price = definition.price,
		mass = definition.mass,
		acceleration = definition.acceleration,
		numSeats = definition.numSeats,
		seatPos = definition.seatPos,
		model = definition.model,
		audio = definition.audio,
		wheelRadius = definition.wheelRadius,
		wheelMass = definition.wheelMass,
	}
	state.vehicle_type_model_assignments[definition.index] = definition.model
	state.vehicle_type_audio_assignments[definition.index] = definition.audio
end

local function construct_vehicle_type(state, src, definition, source_index)
	local target_index = definition.index
	if target_index == nil then
		local allocated_index, allocation_error = allocate_next_custom_index(state)
		assert(allocated_index ~= nil, "vehicleTypes.new: " .. tostring(allocation_error))
		target_index = allocated_index
	else
		target_index = normalize_custom_index(target_index)
		assert(target_index ~= nil, "vehicleTypes.new: invalid target index")
		if target_index >= (state.next_custom_vehicle_type_index or FIRST_CUSTOM_INDEX) then
			state.next_custom_vehicle_type_index = target_index + 1
		end
	end

	definition.index = target_index

	local slot_address = get_vehicle_type_slot_address(target_index)
	assert(slot_address ~= nil, "vehicleTypes.new: failed to resolve target slot address")
	clear_vehicle_type_slot(slot_address)
	memory.writeFloat(slot_address + OFFSET_MASS, definition.mass > 0 and definition.mass or 0.1)

	local target_type = get_vehicle_type_by_index(target_index)
	assert(target_type ~= nil, "vehicleTypes.new: failed to resolve target vehicle type at index " .. tostring(target_index))

	local address = write_definition_to_vehicle_type(target_type, definition)
	finalize_vehicle_type_definition(target_type, definition, address)
	record_definition(state, definition, source_index)
	broadcast_custom_vehicle_types(state, src)

	local network = require("main.src.network")
	network.send_vehicle_type_model(state, nil, target_index, definition.model)
	network.send_vehicle_type_audio(state, nil, target_index, definition.audio)

	return target_type
end

local function new_vehicle_type(state, src, name, controllable_state, uses_external_model, price, mass, acceleration,
		model, seat_count, seat_positions, audio, wheel_radius, wheel_mass, index)
	local definition = build_definition(name, controllable_state, uses_external_model, price, mass, acceleration, model,
			seat_count, seat_positions, audio, wheel_radius, wheel_mass, index)
	return construct_vehicle_type(state, src, definition, -1)
end

local function clone_vehicle_type(state, src, source_ref, target_index_or_overrides, overrides)
	local source_type = resolve_vehicle_type(source_ref)
	assert(source_type ~= nil, "vehicleTypes.clone: invalid source vehicle type")

	local target_index = target_index_or_overrides
	if type(target_index_or_overrides) == "table" and overrides == nil then
		overrides = target_index_or_overrides
		target_index = nil
	end

	local source_address, address_error = get_vehicle_type_address(source_type)
	assert(source_address ~= nil, "vehicleTypes.clone: failed to resolve source vehicle type address (" .. tostring(address_error) .. ")")

	local source_index = get_vehicle_type_index(source_type) or -1
	local source_seat_count = memory.readInt(source_address + OFFSET_NUM_SEATS)
	local source_definition = {
		index = target_index,
		name = safe_read(source_type, "name"),
		controllableState = safe_read(source_type, "controllableState"),
		usesExternalModel = memory.readInt(source_address + OFFSET_USES_EXTERNAL_MODEL),
		price = safe_read(source_type, "price"),
		mass = safe_read(source_type, "mass"),
		acceleration = safe_read(source_type, "acceleration") or memory.readFloat(source_address + OFFSET_ACCELERATION),
		model = state.vehicle_type_model_assignments[source_index] or safe_read(source_type, "name"),
		numSeats = source_seat_count,
		seatPos = read_seat_positions(source_address),
		audio = state.vehicle_type_audio_assignments[source_index] or safe_read(source_type, "name"),
		wheelRadius = read_source_wheel_radius(source_address),
		wheelMass = read_source_wheel_mass(source_address),
	}

	if type(overrides) == "table" then
		for key, value in pairs(overrides) do
			if key == "seatPos" then
				source_definition.seatPos = value
			elseif source_definition[key] ~= nil or key == "index" or key == "audio" or key == "model" then
				source_definition[key] = value
			end
		end
	end

	local definition = build_definition(
		source_definition.name,
		source_definition.controllableState,
		source_definition.usesExternalModel,
		source_definition.price,
		source_definition.mass,
		source_definition.acceleration,
		source_definition.model,
		source_definition.numSeats,
		source_definition.seatPos,
		source_definition.audio,
		source_definition.wheelRadius,
		source_definition.wheelMass,
		source_definition.index
	)

	return construct_vehicle_type(state, src, definition, source_index)
end

local function run_init_vehicle_type_hook(state, src)
	if state.vehicle_type_init_hook_ran then
		return
	end
	state.vehicle_type_init_hook_ran = true
	broadcast_custom_vehicle_types(state, src)
end

function M.install(state, src, force)
	local was_installed = state.vehicle_types_api_installed
	if was_installed and not force then
		return
	end

	if type(vehicleTypes) ~= "table" then
		log.warn("vehicleTypes API unavailable; custom vehicle type helpers not installed")
		return
	end

	state.custom_vehicle_types_by_index = state.custom_vehicle_types_by_index or {}
	state.next_custom_vehicle_type_index = state.next_custom_vehicle_type_index or FIRST_CUSTOM_INDEX
	state.vehicle_type_model_assignments = state.vehicle_type_model_assignments or {}
	state.vehicle_type_audio_assignments = state.vehicle_type_audio_assignments or {}
	if not was_installed then
		clear_custom_vehicle_type_slots()
	end

	vehicleTypes.new = function(name, controllable_state, uses_external_model, price, mass, acceleration, model,
			seat_count, seat_positions, audio, wheel_radius, wheel_mass, index)
		return new_vehicle_type(state, src, name, controllable_state, uses_external_model, price, mass, acceleration, model,
			seat_count, seat_positions, audio, wheel_radius, wheel_mass, index)
	end

	vehicleTypes.clone = function(source_ref, target_index_or_overrides, overrides)
		return clone_vehicle_type(state, src, source_ref, target_index_or_overrides, overrides)
	end

	if type(src) == "table" then
		if force or type(src.syncCustomVehicleTypes) ~= "function" then
			src.syncCustomVehicleTypes = function(player)
				local payload = M.build_sync_payload(state)
				if not payload then
					return false
				end
				return emit_sync_payload(src, payload, player)
			end
		end

		if force or type(src.setVehicleTypeModel) ~= "function" then
			src.setVehicleTypeModel = function(index_or_type, model_name, player)
				local target_index = get_vehicle_type_index(index_or_type)
				assert(type(target_index) == "number",
					"src.setVehicleTypeModel(indexOrVehicleType, modelName, player?): first arg must be number or VehicleType")
				assert(target_index >= 0 and target_index <= MAX_VEHICLE_TYPE_INDEX,
					"src.setVehicleTypeModel: index out of range")
				if player ~= nil then
					assert(type(player) == "userdata" and player.class == "Player", "src.setVehicleTypeModel: player must be Player or nil")
					assert(not player.isBot, "src.setVehicleTypeModel: player cannot be a bot")
				end

				local normalized_model = validate_model(model_name)
				state.vehicle_type_model_assignments[target_index] = normalized_model
				local entry = state.custom_vehicle_types_by_index[target_index]
				if entry then
					entry.model = normalized_model
				end

				local network = require("main.src.network")
				return network.send_vehicle_type_model(state, player, target_index, normalized_model)
			end
		end

		if force or type(src.setVehicleTypeAudio) ~= "function" then
			src.setVehicleTypeAudio = function(index_or_type, audio_reference, player)
				local target_index = get_vehicle_type_index(index_or_type)
				assert(type(target_index) == "number",
					"src.setVehicleTypeAudio(indexOrVehicleType, audioRef, player?): first arg must be number or VehicleType")
				assert(target_index >= 0 and target_index <= MAX_VEHICLE_TYPE_INDEX,
					"src.setVehicleTypeAudio: index out of range")
				if player ~= nil then
					assert(type(player) == "userdata" and player.class == "Player", "src.setVehicleTypeAudio: player must be Player or nil")
					assert(not player.isBot, "src.setVehicleTypeAudio: player cannot be a bot")
				end

				local normalized_audio = normalize_audio(audio_reference)
				state.vehicle_type_audio_assignments[target_index] = normalized_audio
				local entry = state.custom_vehicle_types_by_index[target_index]
				if entry then
					entry.audio = normalized_audio
				end

				local network = require("main.src.network")
				return network.send_vehicle_type_audio(state, player, target_index, normalized_audio)
			end
		end
	end

	local function schedule_init_hook()
		if type(hook) == "table" and type(hook.once) == "function" then
			hook.once("Logic", function()
				run_init_vehicle_type_hook(state, src)
			end)
			return
		end

		run_init_vehicle_type_hook(state, src)
	end

	if type(hook) == "table" and type(hook.add) == "function" then
		hook.add("ConfigLoaded", "main.src.vehicleTypes.init", function()
			schedule_init_hook()
		end)
		schedule_init_hook()
	else
		run_init_vehicle_type_hook(state, src)
	end

	state.vehicle_types_api_installed = true
	log.info("vehicleTypes.new API installed")
end

return M
