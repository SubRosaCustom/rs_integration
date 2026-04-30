local log = require("main.src.log")
local network = require("main.src.network")

local M = {}

local MIN_CUSTOM_HUMAN_MODEL_INDEX = 0
local MAX_CUSTOM_HUMAN_MODEL_INDEX = 29

local function normalizeIndex(index)
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

local function normalizeModelName(value)
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

local function normalizeAssignment(def)
	if type(def) ~= "table" then
		return nil
	end

	local male = normalizeModelName(def.male)
	local female = normalizeModelName(def.female)
	if male == nil or female == nil then
		return nil
	end

	return {
		male = male,
		female = female,
	}
end

function M.install(state, src)
	if state.humanModelsAPIInstalled then
		return
	end

	src.registerHumanModel = function(index, def)
		local normalizedIndex = normalizeIndex(index)
		assert(
			normalizedIndex ~= nil,
			("src.registerHumanModel(index, def): index must be an integer between %d and %d"):format(
				MIN_CUSTOM_HUMAN_MODEL_INDEX,
				MAX_CUSTOM_HUMAN_MODEL_INDEX
			)
		)

		local assignment = normalizeAssignment(def)
		assert(
			assignment ~= nil,
			"src.registerHumanModel(index, def): def must contain non-empty male and female CMC names"
		)

		state.humanModelAssignments[normalizedIndex] = assignment
		local sent = network.sendHumanModel(state, nil, normalizedIndex, assignment)
		if sent == false then
			log.warn("failed queuing human model sync for index %d", normalizedIndex)
		end

		return normalizedIndex
	end

	state.humanModelsAPIInstalled = true
	log.info("human model registry API installed")
end

return M
