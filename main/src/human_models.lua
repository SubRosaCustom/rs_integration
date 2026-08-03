local log = require("main.src.log")
local network = require("main.src.network")

local M = {}

local MIN_CUSTOM_HUMAN_MODEL_INDEX = 0
local MAX_CUSTOM_HUMAN_MODEL_INDEX = 29

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
	if state.human_models_api_installed and not force then
		return
	end

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

	state.human_models_api_installed = true
	log.info("human model registry API installed")
end

return M
