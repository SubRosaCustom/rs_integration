local log = require("main.src.log")
local network = require("main.src.network")

local M = {}

local MIN_CUSTOM_HUMAN_MODEL_INDEX = 0
local MAX_CUSTOM_HUMAN_MODEL_INDEX = 29
local MIN_CUSTOM_NECKTIE_INDEX = 11
local MAX_CUSTOM_NECKTIE_INDEX = 15
local MIN_CUSTOM_NECKLACE_INDEX = 3
local MAX_CUSTOM_NECKLACE_INDEX = 15

local function normalize_index(index)
	if type(index) ~= "number" or index ~= index then
		return nil
	end

	local normalized = math.floor(index)
	if normalized < MIN_CUSTOM_HUMAN_MODEL_INDEX or normalized > MAX_CUSTOM_HUMAN_MODEL_INDEX then
		return nil
	end

	return normalized
end

local function trim(value)
	if type(value) ~= "string" then
		return ""
	end

	return value:match("^%s*(.-)%s*$")
end

local function normalize_model_name(value)
	local normalized = trim(value)
	if normalized == "" then
		return nil
	end

	normalized = normalized:gsub("\\", "/")
	normalized = normalized:gsub("^data/model/", "")
	normalized = normalized:gsub("%.cmc$", "")
	normalized = normalized:match("([^/]+)$") or normalized
	normalized = trim(normalized)
	if normalized == "" then
		return nil
	end

	return normalized
end

local function normalize_assignment(def)
	if type(def) ~= "table" then
		return nil
	end

	local male = normalize_model_name(def.male)
	local female = normalize_model_name(def.female)
	if male == nil or female == nil then
		return nil
	end

	return {
		male = male,
		female = female,
	}
end

function M.install(state, src, force)
	if state.human_models_api_installed and state.human_accessories_api_installed and not force then
		return
	end
	state.human_necktie_assignments = state.human_necktie_assignments or {}
	state.human_necklace_assignments = state.human_necklace_assignments or {}

	src.registerHumanModel = function(index, def)
		local normalized_index = normalize_index(index)
		assert(
			normalized_index ~= nil,
			("src.registerHumanModel(index, def): index must be an integer between %d and %d"):format(
				MIN_CUSTOM_HUMAN_MODEL_INDEX,
				MAX_CUSTOM_HUMAN_MODEL_INDEX
			)
		)

		local assignment = normalize_assignment(def)
		assert(
			assignment ~= nil,
			"src.registerHumanModel(index, def): def must contain non-empty male and female CMC names"
		)

		state.human_model_assignments[normalized_index] = assignment
		local sent = network.send_human_model(state, nil, normalized_index, assignment)
		if sent == false then
			log.warn("failed queuing human model sync for index %d", normalized_index)
		end

		return normalized_index
	end

	local function register_accessory(index, def, minimum, maximum, assignments, send, api_name)
		local normalized_index = normalize_index(index)
		assert(
			normalized_index ~= nil and normalized_index >= minimum and normalized_index <= maximum,
			("%s(index, def): index must be an integer between %d and %d"):format(api_name, minimum, maximum)
		)

		local assignment = normalize_assignment(def)
		assert(
			assignment ~= nil,
			("%s(index, def): def must contain non-empty male and female CMC names"):format(api_name)
		)

		assignments[normalized_index] = assignment
		local sent = send(state, nil, normalized_index, assignment)
		if sent == false then
			log.warn("failed queuing %s sync for index %d", api_name, normalized_index)
		end

		return normalized_index
	end

	src.registerHumanNecktie = function(index, def)
		return register_accessory(
			index,
			def,
			MIN_CUSTOM_NECKTIE_INDEX,
			MAX_CUSTOM_NECKTIE_INDEX,
			state.human_necktie_assignments,
			network.send_human_necktie,
			"src.registerHumanNecktie"
		)
	end

	src.registerHumanNecklace = function(index, def)
		return register_accessory(
			index,
			def,
			MIN_CUSTOM_NECKLACE_INDEX,
			MAX_CUSTOM_NECKLACE_INDEX,
			state.human_necklace_assignments,
			network.send_human_necklace,
			"src.registerHumanNecklace"
		)
	end

	state.human_models_api_installed = true
	state.human_accessories_api_installed = true
	log.info("human model registry API installed")
end

return M
