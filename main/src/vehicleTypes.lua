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
local OFFSET_NUM_SEATS = 0x18318
local OFFSET_SEAT_POS = 0x1831c
local VECTOR_SIZE = 12
local DEFAULT_WHEEL_RADIUS = 0.5
local DEFAULT_WHEEL_MASS = 1.0
local DEFAULT_INITIAL_WHEEL_FLAGS = 0

local function safeRead(obj, key)
	local ok, value = pcall(function()
		return obj[key]
	end)
	if not ok then
		return nil
	end
	return value
end

local function normalizeIndex(index, minValue, maxValue)
	if type(index) ~= "number" or index ~= index then
		return nil
	end

	index = math.floor(index)
	if index < minValue or index > maxValue then
		return nil
	end

	return index
end

local function hasMemoryAPI()
	return type(memory) == "table"
		and type(memory.getAddress) == "function"
		and type(memory.readFloat) == "function"
		and type(memory.writeFloat) == "function"
		and type(memory.readInt) == "function"
		and type(memory.writeInt) == "function"
end

local function getNativeVehicleTypeAPI()
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

local function isVehicleTypeUserdata(value)
	return type(value) == "userdata" and safeRead(value, "class") == "VehicleType"
end

local function getVehicleTypeByIndex(index)
	local normalized = normalizeIndex(index, 0, MAX_VEHICLE_TYPE_INDEX)
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

local function getVehicleTypeIndex(ref)
	if isVehicleTypeUserdata(ref) then
		return normalizeIndex(safeRead(ref, "index"), 0, MAX_VEHICLE_TYPE_INDEX)
	end

	if type(ref) == "number" then
		return normalizeIndex(ref, 0, MAX_VEHICLE_TYPE_INDEX)
	end

	return nil
end

local function getVehicleTypeAddress(vehicleType)
	if not hasMemoryAPI() then
		return nil, "memory api unavailable"
	end

	local okAddress, address = pcall(memory.getAddress, vehicleType)
	if not okAddress or type(address) ~= "number" or address <= 0 then
		return nil, "failed to resolve vehicle type address"
	end

	return address
end

local function getVehicleTypeSlotAddress(index)
	if not hasMemoryAPI() then
		return nil
	end

	local normalized = normalizeIndex(index, 0, MAX_VEHICLE_TYPE_INDEX)
	if normalized == nil then
		return nil
	end

	return memory.getBaseAddress() + SERVER_VEHICLE_TYPES_OFFSET + (normalized * VEHICLE_TYPE_SIZE)
end

local function normalizeSeatVector(value)
	if type(value) == "userdata" and safeRead(value, "class") == "Vector" then
		return {
			x = tonumber(safeRead(value, "x")) or 0,
			y = tonumber(safeRead(value, "y")) or 0,
			z = tonumber(safeRead(value, "z")) or 0,
		}
	end

	assert(type(value) == "table", "vehicleTypes.new: seatPos entries must be Vector-like tables")
	return {
		x = tonumber(value.x) or 0,
		y = tonumber(value.y) or 0,
		z = tonumber(value.z) or 0,
	}
end

local function normalizeSeatPositions(numSeats, seatPos)
	assert(type(seatPos) == "table", "vehicleTypes.new: seatPos must be a table")

	local normalized = {}
	for i = 1, 4 do
		local raw = seatPos[i]
		if i <= numSeats then
			assert(raw ~= nil, "vehicleTypes.new: missing seatPos[" .. i .. "]")
			normalized[i] = normalizeSeatVector(raw)
		else
			normalized[i] = { x = 0, y = 0, z = 0 }
		end
	end

	return normalized
end

local function readSeatPositions(address)
	local seatPos = {}
	for i = 0, 3 do
		local base = address + OFFSET_SEAT_POS + (i * VECTOR_SIZE)
		seatPos[i + 1] = {
			x = memory.readFloat(base),
			y = memory.readFloat(base + 4),
			z = memory.readFloat(base + 8),
		}
	end
	return seatPos
end

local function writeSeatPositions(address, seatPos)
	for i = 0, 3 do
		local base = address + OFFSET_SEAT_POS + (i * VECTOR_SIZE)
		local value = seatPos[i + 1] or { x = 0, y = 0, z = 0 }
		memory.writeFloat(base, value.x or 0)
		memory.writeFloat(base + 4, value.y or 0)
		memory.writeFloat(base + 8, value.z or 0)
	end
end

local function resolveVehicleType(ref)
	if isVehicleTypeUserdata(ref) then
		return ref
	end

	if type(ref) == "number" then
		return getVehicleTypeByIndex(ref)
	end

	if type(ref) == "string" and ref ~= "" and type(vehicleTypes.getByName) == "function" then
		local ok, vehicleType = pcall(vehicleTypes.getByName, ref)
		if ok then
			return vehicleType
		end
	end

	return nil
end

local function normalizeCustomIndex(index)
	return normalizeIndex(index, FIRST_CUSTOM_INDEX, MAX_VEHICLE_TYPE_INDEX)
end

local function allocateNextCustomIndex(state)
	local entriesByIndex = state.customVehicleTypesByIndex or {}
	local nextIndex = state.nextCustomVehicleTypeIndex or FIRST_CUSTOM_INDEX

	while nextIndex <= MAX_VEHICLE_TYPE_INDEX and entriesByIndex[nextIndex] do
		nextIndex = nextIndex + 1
	end

	if nextIndex > MAX_VEHICLE_TYPE_INDEX then
		return nil, "no more custom vehicle type slots available (max index " .. MAX_VEHICLE_TYPE_INDEX .. ")"
	end

	state.nextCustomVehicleTypeIndex = nextIndex + 1
	return nextIndex
end

local function validateModel(model)
	assert(type(model) == "string" and model ~= "", "vehicleTypes.new: model must be a non-empty string")
	assert(not model:find("[/\\]"), "vehicleTypes.new: model must be an SBV name, not a path")
	assert(not string.lower(model):match("%.tst$"), "vehicleTypes.new: TST models are not supported")
	return model
end

local function normalizeAudio(audio)
	assert(type(audio) == "string" and audio ~= "", "vehicleTypes.new: audio must be a non-empty string")
	return audio
end

local function buildDefinition(name, controllableState, usesExternalModel, price, mass, acceleration, model,
		numSeats, seatPos, audio, index)
	assert(type(name) == "string" and name ~= "", "vehicleTypes.new: name must be a non-empty string")
	assert(type(controllableState) == "number", "vehicleTypes.new: controllableState must be a number")
	assert(type(usesExternalModel) == "boolean" or type(usesExternalModel) == "number",
		"vehicleTypes.new: usesExternalModel must be boolean or number")
	assert(type(price) == "number", "vehicleTypes.new: price must be a number")
	assert(type(mass) == "number", "vehicleTypes.new: mass must be a number")
	assert(type(acceleration) == "number", "vehicleTypes.new: acceleration must be a number")
	assert(type(numSeats) == "number", "vehicleTypes.new: numSeats must be a number")

	local normalizedNumSeats = math.floor(numSeats)
	assert(normalizedNumSeats >= 0 and normalizedNumSeats <= 4, "vehicleTypes.new: numSeats must be in range 0..4")

	return {
		index = index,
		name = name,
		controllableState = math.floor(controllableState),
		usesExternalModel = ((usesExternalModel == true or usesExternalModel == 1) and 1 or 0),
		price = math.floor(price),
		mass = mass,
		acceleration = acceleration,
		model = validateModel(model),
		numSeats = normalizedNumSeats,
		seatPos = normalizeSeatPositions(normalizedNumSeats, seatPos),
		audio = normalizeAudio(audio),
	}
end

local function writeDefinitionToVehicleType(targetType, definition)
	local address, addrErr = getVehicleTypeAddress(targetType)
	assert(address ~= nil, "vehicleTypes.new: failed to resolve vehicle type address (" .. tostring(addrErr) .. ")")

	targetType.name = definition.name
	memory.writeInt(address + OFFSET_CONTROLLABLE_STATE, definition.controllableState)
	memory.writeInt(address + OFFSET_USES_EXTERNAL_MODEL, definition.usesExternalModel)
	memory.writeInt(address + OFFSET_PRICE, definition.price)
	memory.writeFloat(address + OFFSET_MASS, definition.mass)
	memory.writeFloat(address + OFFSET_ACCELERATION, definition.acceleration)
	return address
end

local function finalizeVehicleTypeDefinition(targetType, definition, address)
	local nativeApi = getNativeVehicleTypeAPI()
	assert(nativeApi ~= nil, "vehicleTypes.new: srcIntegrationNative vehicle helpers unavailable")

	local targetIndex = getVehicleTypeIndex(targetType)
	assert(targetIndex ~= nil, "vehicleTypes.new: failed to resolve target vehicle type index")

	nativeApi.loadSBV(targetIndex, definition.model)
	nativeApi.setupVehicleTypeNew(
		targetIndex,
		DEFAULT_WHEEL_RADIUS,
		DEFAULT_WHEEL_MASS,
		DEFAULT_INITIAL_WHEEL_FLAGS
	)
	memory.writeInt(address + OFFSET_NUM_SEATS, definition.numSeats)
	writeSeatPositions(address, definition.seatPos)
	nativeApi.setupObjectTypeWeight(targetIndex)
end

local function buildSyncPayload(state)
	local entries = {}
	for _, entry in pairs(state.customVehicleTypesByIndex or {}) do
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

local function emitSyncPayload(src, payload, player)
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

local function broadcastCustomVehicleTypes(state, src)
	local payload = buildSyncPayload(state)
	if payload then
		emitSyncPayload(src, payload, nil)
	end
end

local function recordDefinition(state, definition, sourceIndex)
	state.customVehicleTypesByIndex = state.customVehicleTypesByIndex or {}
	state.customVehicleTypesByIndex[definition.index] = {
		index = definition.index,
		sourceIndex = sourceIndex or -1,
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
	}
	state.vehicleTypeModelAssignments[definition.index] = definition.model
	state.vehicleTypeAudioAssignments[definition.index] = definition.audio
end

local function constructVehicleType(state, src, definition, sourceIndex)
	local targetIndex = definition.index
	if targetIndex == nil then
		local allocatedIndex, allocErr = allocateNextCustomIndex(state)
		assert(allocatedIndex ~= nil, "vehicleTypes.new: " .. tostring(allocErr))
		targetIndex = allocatedIndex
	else
		targetIndex = normalizeCustomIndex(targetIndex)
		assert(targetIndex ~= nil, "vehicleTypes.new: invalid target index")
		if targetIndex >= (state.nextCustomVehicleTypeIndex or FIRST_CUSTOM_INDEX) then
			state.nextCustomVehicleTypeIndex = targetIndex + 1
		end
	end

	definition.index = targetIndex

	local slotAddress = getVehicleTypeSlotAddress(targetIndex)
	assert(slotAddress ~= nil, "vehicleTypes.new: failed to resolve target slot address")
	memory.writeFloat(slotAddress + OFFSET_MASS, definition.mass > 0 and definition.mass or 0.1)

	local targetType = getVehicleTypeByIndex(targetIndex)
	assert(targetType ~= nil, "vehicleTypes.new: failed to resolve target vehicle type at index " .. tostring(targetIndex))

	local address = writeDefinitionToVehicleType(targetType, definition)
	finalizeVehicleTypeDefinition(targetType, definition, address)
	recordDefinition(state, definition, sourceIndex)
	broadcastCustomVehicleTypes(state, src)

	local network = require("main.src.network")
	network.sendVehicleTypeModel(state, nil, targetIndex, definition.model)
	network.sendVehicleTypeAudio(state, nil, targetIndex, definition.audio)

	return targetType
end

local function newVehicleType(state, src, name, controllableState, usesExternalModel, price, mass, acceleration,
		model, numSeats, seatPos, audio, index)
	local definition = buildDefinition(name, controllableState, usesExternalModel, price, mass, acceleration, model,
			numSeats, seatPos, audio, index)
	return constructVehicleType(state, src, definition, -1)
end

local function cloneVehicleType(state, src, sourceRef, targetIndexOrOverrides, overrides)
	local sourceType = resolveVehicleType(sourceRef)
	assert(sourceType ~= nil, "vehicleTypes.clone: invalid source vehicle type")

	local targetIndex = targetIndexOrOverrides
	if type(targetIndexOrOverrides) == "table" and overrides == nil then
		overrides = targetIndexOrOverrides
		targetIndex = nil
	end

	local sourceAddress, addrErr = getVehicleTypeAddress(sourceType)
	assert(sourceAddress ~= nil, "vehicleTypes.clone: failed to resolve source vehicle type address (" .. tostring(addrErr) .. ")")

	local sourceIndex = getVehicleTypeIndex(sourceType) or -1
	local sourceNumSeats = memory.readInt(sourceAddress + OFFSET_NUM_SEATS)
	local sourceDefinition = {
		index = targetIndex,
		name = safeRead(sourceType, "name"),
		controllableState = safeRead(sourceType, "controllableState"),
		usesExternalModel = memory.readInt(sourceAddress + OFFSET_USES_EXTERNAL_MODEL),
		price = safeRead(sourceType, "price"),
		mass = safeRead(sourceType, "mass"),
		acceleration = safeRead(sourceType, "acceleration") or memory.readFloat(sourceAddress + OFFSET_ACCELERATION),
		model = state.vehicleTypeModelAssignments[sourceIndex] or safeRead(sourceType, "name"),
		numSeats = sourceNumSeats,
		seatPos = readSeatPositions(sourceAddress),
		audio = state.vehicleTypeAudioAssignments[sourceIndex] or safeRead(sourceType, "name"),
	}

	if type(overrides) == "table" then
		for key, value in pairs(overrides) do
			if key == "seatPos" then
				sourceDefinition.seatPos = value
			elseif sourceDefinition[key] ~= nil or key == "index" or key == "audio" or key == "model" then
				sourceDefinition[key] = value
			end
		end
	end

	local definition = buildDefinition(
		sourceDefinition.name,
		sourceDefinition.controllableState,
		sourceDefinition.usesExternalModel,
		sourceDefinition.price,
		sourceDefinition.mass,
		sourceDefinition.acceleration,
		sourceDefinition.model,
		sourceDefinition.numSeats,
		sourceDefinition.seatPos,
		sourceDefinition.audio,
		sourceDefinition.index
	)

	return constructVehicleType(state, src, definition, sourceIndex)
end

local function runInitVehicleTypeHook(state, src)
	if state.vehicleTypeInitHookRan then
		return
	end
	state.vehicleTypeInitHookRan = true
	broadcastCustomVehicleTypes(state, src)
end

function M.install(state, src)
	if state.vehicleTypesAPIInstalled then
		return
	end

	if type(vehicleTypes) ~= "table" then
		log.warn("vehicleTypes API unavailable; custom vehicle type helpers not installed")
		return
	end

	state.customVehicleTypesByIndex = state.customVehicleTypesByIndex or {}
	state.nextCustomVehicleTypeIndex = state.nextCustomVehicleTypeIndex or FIRST_CUSTOM_INDEX
	state.vehicleTypeModelAssignments = state.vehicleTypeModelAssignments or {}
	state.vehicleTypeAudioAssignments = state.vehicleTypeAudioAssignments or {}
	state.buildCustomVehicleTypesSyncPayload = function()
		return buildSyncPayload(state)
	end

	vehicleTypes.new = function(name, controllableState, usesExternalModel, price, mass, acceleration, model,
			numSeats, seatPos, audio, index)
		return newVehicleType(state, src, name, controllableState, usesExternalModel, price, mass, acceleration, model,
			numSeats, seatPos, audio, index)
	end

	vehicleTypes.clone = function(sourceRef, targetIndexOrOverrides, overrides)
		return cloneVehicleType(state, src, sourceRef, targetIndexOrOverrides, overrides)
	end

	if type(src) == "table" then
		if type(src.syncCustomVehicleTypes) ~= "function" then
			src.syncCustomVehicleTypes = function(player)
				local payload = buildSyncPayload(state)
				if not payload then
					return false
				end
				return emitSyncPayload(src, payload, player)
			end
		end

		if type(src.setVehicleTypeModel) ~= "function" then
			src.setVehicleTypeModel = function(indexOrType, modelName, player)
				local targetIndex = getVehicleTypeIndex(indexOrType)
				assert(type(targetIndex) == "number",
					"src.setVehicleTypeModel(indexOrVehicleType, modelName, player?): first arg must be number or VehicleType")
				assert(targetIndex >= 0 and targetIndex <= MAX_VEHICLE_TYPE_INDEX,
					"src.setVehicleTypeModel: index out of range")
				if player ~= nil then
					assert(type(player) == "userdata" and player.class == "Player", "src.setVehicleTypeModel: player must be Player or nil")
					assert(not player.isBot, "src.setVehicleTypeModel: player cannot be a bot")
				end

				local normalizedModel = validateModel(modelName)
				state.vehicleTypeModelAssignments[targetIndex] = normalizedModel
				local entry = state.customVehicleTypesByIndex[targetIndex]
				if entry then
					entry.model = normalizedModel
				end

				local network = require("main.src.network")
				return network.sendVehicleTypeModel(state, player, targetIndex, normalizedModel)
			end
		end

		if type(src.setVehicleTypeAudio) ~= "function" then
			src.setVehicleTypeAudio = function(indexOrType, audioRef, player)
				local targetIndex = getVehicleTypeIndex(indexOrType)
				assert(type(targetIndex) == "number",
					"src.setVehicleTypeAudio(indexOrVehicleType, audioRef, player?): first arg must be number or VehicleType")
				assert(targetIndex >= 0 and targetIndex <= MAX_VEHICLE_TYPE_INDEX,
					"src.setVehicleTypeAudio: index out of range")
				if player ~= nil then
					assert(type(player) == "userdata" and player.class == "Player", "src.setVehicleTypeAudio: player must be Player or nil")
					assert(not player.isBot, "src.setVehicleTypeAudio: player cannot be a bot")
				end

				local normalizedAudio = normalizeAudio(audioRef)
				state.vehicleTypeAudioAssignments[targetIndex] = normalizedAudio
				local entry = state.customVehicleTypesByIndex[targetIndex]
				if entry then
					entry.audio = normalizedAudio
				end

				local network = require("main.src.network")
				return network.sendVehicleTypeAudio(state, player, targetIndex, normalizedAudio)
			end
		end
	end

	local function scheduleInitHook()
		if type(hook) == "table" and type(hook.once) == "function" then
			hook.once("Logic", function()
				runInitVehicleTypeHook(state, src)
			end)
			return
		end

		runInitVehicleTypeHook(state, src)
	end

	if type(hook) == "table" and type(hook.add) == "function" then
		hook.add("ConfigLoaded", "main.src.vehicleTypes.init", function()
			scheduleInitHook()
		end)
		scheduleInitHook()
	else
		runInitVehicleTypeHook(state, src)
	end

	state.vehicleTypesAPIInstalled = true
	log.info("vehicleTypes.new API installed")
end

return M
