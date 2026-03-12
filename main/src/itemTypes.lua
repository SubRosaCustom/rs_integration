local log = require("main.src.log")

local M = {}

local PROTOCOL_VERSION = 1
local ITEM_TYPE_SIZE = 0x13D0
local MAX_ITEM_TYPE_COUNT = 255
local MAX_ITEM_TYPE_INDEX = MAX_ITEM_TYPE_COUNT - 1
local FIRST_CUSTOM_INDEX = 46

local BASE64_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local BASE64_ALPHABET = {}

for i = 1, #BASE64_CHARS do
	BASE64_ALPHABET[i - 1] = BASE64_CHARS:sub(i, i)
end

local function base64Encode(input)
	if type(input) ~= "string" or #input == 0 then
		return ""
	end

	local out = {}
	local len = #input
	local i = 1
	while i <= len do
		local a = string.byte(input, i) or 0
		local b = string.byte(input, i + 1) or 0
		local c = string.byte(input, i + 2) or 0

		local n = a * 65536 + b * 256 + c
		local v1 = math.floor(n / 262144) % 64
		local v2 = math.floor(n / 4096) % 64
		local v3 = math.floor(n / 64) % 64
		local v4 = n % 64

		out[#out + 1] = BASE64_ALPHABET[v1]
		out[#out + 1] = BASE64_ALPHABET[v2]
		out[#out + 1] = (i + 1 <= len) and BASE64_ALPHABET[v3] or "="
		out[#out + 1] = (i + 2 <= len) and BASE64_ALPHABET[v4] or "="

		i = i + 3
	end

	return table.concat(out)
end

local function safeRead(obj, key)
	local ok, value = pcall(function()
		return obj[key]
	end)
	if not ok then
		return nil
	end
	return value
end

local function safeWrite(obj, key, value)
	pcall(function()
		obj[key] = value
	end)
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

local function hasMemoryReadAPI()
	return type(memory) == "table"
		and type(memory.getAddress) == "function"
		and type(memory.readBytes) == "function"
end

local function hasMemoryWriteAPI()
	return hasMemoryReadAPI() and type(memory.writeBytes) == "function"
end

local function isItemTypeUserdata(value)
	return type(value) == "userdata" and safeRead(value, "class") == "ItemType"
end

local function getItemTypeByIndex(index)
	local normalized = normalizeIndex(index, 0, MAX_ITEM_TYPE_INDEX)
	if normalized == nil then
		return nil
	end

	local ok, value = pcall(function()
		return itemTypes[normalized]
	end)
	if not ok then
		return nil
	end

	return value
end

local function getItemTypeIndex(ref)
	if isItemTypeUserdata(ref) then
		return normalizeIndex(safeRead(ref, "index"), 0, MAX_ITEM_TYPE_INDEX)
	end

	if type(ref) == "number" then
		return normalizeIndex(ref, 0, MAX_ITEM_TYPE_INDEX)
	end

	return nil
end

local function getItemTypeAddress(itemType)
	if not hasMemoryReadAPI() then
		return nil, "memory read api unavailable"
	end

	local okAddress, address = pcall(memory.getAddress, itemType)
	if not okAddress or type(address) ~= "number" or address <= 0 then
		return nil, "failed to resolve item type address"
	end

	return address
end

local function readItemTypeBytesFromAddress(address)
	if not hasMemoryReadAPI() then
		return nil, "memory read api unavailable"
	end

	local okBytes, bytesOrErr = pcall(memory.readBytes, address, ITEM_TYPE_SIZE)
	if not okBytes then
		return nil, tostring(bytesOrErr)
	end

	if type(bytesOrErr) ~= "string" or #bytesOrErr ~= ITEM_TYPE_SIZE then
		return nil, "failed to read full item type blob"
	end

	return bytesOrErr
end

local function writeItemTypeBytes(address, bytes)
	if not hasMemoryWriteAPI() then
		return false, "memory write api unavailable"
	end

	local okWrite, writeErr = pcall(memory.writeBytes, address, bytes)
	if not okWrite then
		return false, tostring(writeErr)
	end

	return true
end

local function resolveItemType(ref)
	if isItemTypeUserdata(ref) then
		return ref
	end

	if type(ref) == "number" then
		return getItemTypeByIndex(ref)
	end

	if type(ref) == "string" and ref ~= "" and type(itemTypes.getByName) == "function" then
		local ok, itemType = pcall(itemTypes.getByName, ref)
		if ok then
			return itemType
		end
	end

	return nil
end

local function copyVector(dst, src)
	if not dst or not src then
		return
	end

	local x = safeRead(src, "x")
	local y = safeRead(src, "y")
	local z = safeRead(src, "z")

	if type(x) == "number" then
		safeWrite(dst, "x", x)
	end
	if type(y) == "number" then
		safeWrite(dst, "y", y)
	end
	if type(z) == "number" then
		safeWrite(dst, "z", z)
	end
end

local function valueLooksLikeVector(value)
	return type(value) == "table"
		and (type(value.x) == "number" or type(value.y) == "number" or type(value.z) == "number")
end

local function applyCanMountToOverrides(targetType, canMountToOverrides)
	if not isItemTypeUserdata(targetType) or type(canMountToOverrides) ~= "table" then
		return
	end

	for i = 1, #canMountToOverrides do
		local parentIndex = i - 1
		if parentIndex >= FIRST_CUSTOM_INDEX then
			break
		end

		local parentType = getItemTypeByIndex(parentIndex)
		if parentType then
			local value = canMountToOverrides[i]
			local allowed = value == true or value == 1
			pcall(targetType.setCanMountTo, targetType, parentType, allowed)
		end
	end
end

local function applyCloneOverrides(targetType, overrides)
	if not isItemTypeUserdata(targetType) or type(overrides) ~= "table" then
		return
	end

	for key, value in pairs(overrides) do
		if key ~= "canMountTo" and type(key) == "string" then
			if valueLooksLikeVector(value) then
				local dstVector = safeRead(targetType, key)
				if dstVector then
					copyVector(dstVector, value)
				end
			elseif type(value) == "number" or type(value) == "boolean" or type(value) == "string" then
				safeWrite(targetType, key, value)
			end
		end
	end

	applyCanMountToOverrides(targetType, overrides.canMountTo)
end

local function buildSyncPayload(state)
	local entriesByIndex = state.customItemTypesByIndex or {}
	local itemTypeEntries = {}

	for _, entry in pairs(entriesByIndex) do
		if type(entry) == "table" and type(entry.bytes) == "string" and #entry.bytes == ITEM_TYPE_SIZE then
			itemTypeEntries[#itemTypeEntries + 1] = entry
		end
	end

	table.sort(itemTypeEntries, function(a, b)
		return (a.index or 0) < (b.index or 0)
	end)

	if #itemTypeEntries == 0 then
		return nil
	end

	local metadata = {}
	local chunks = {}
	for i = 1, #itemTypeEntries do
		local entry = itemTypeEntries[i]
		metadata[#metadata + 1] = {
			index = entry.index,
			sourceIndex = entry.sourceIndex,
		}
		chunks[#chunks + 1] = entry.bytes
	end

	local rawBlob = table.concat(chunks)
	if #rawBlob ~= (#metadata * ITEM_TYPE_SIZE) then
		log.warn("failed to build custom item type sync blob: size mismatch")
		return nil
	end

	return {
		version = PROTOCOL_VERSION,
		encoding = "base64",
		itemTypeSize = ITEM_TYPE_SIZE,
		itemTypes = metadata,
		bin = base64Encode(rawBlob),
	}
end

local function emitSyncPayload(src, payload, player)
	if type(src) ~= "table" or type(src.syncClientItemTypes) ~= "function" then
		return false
	end

	if type(payload) ~= "table" then
		return false
	end

	if type(payload.itemTypes) ~= "table" or #payload.itemTypes == 0 then
		return false
	end

	if type(payload.bin) ~= "string" or payload.bin == "" then
		return false
	end

	local ok, sent = pcall(src.syncClientItemTypes, player, payload)
	if not ok then
		log.warn("failed to emit custom item type sync payload: %s", tostring(sent))
		return false
	end

	return sent and true or false
end

local function broadcastCustomItemTypes(state, src)
	local payload = buildSyncPayload(state)
	if payload then
		emitSyncPayload(src, payload, nil)
	end
end

local function snapshotCustomItemType(state, targetType, sourceIndex)
	local targetIndex = getItemTypeIndex(targetType)
	if targetIndex == nil then
		return false
	end

	local address, addrErr = getItemTypeAddress(targetType)
	if not address then
		if not state.itemTypeSyncMemoryWarningShown then
			state.itemTypeSyncMemoryWarningShown = true
			log.warn("custom item type sync disabled: %s", tostring(addrErr))
		end
		return false
	end

	local bytes, readErr = readItemTypeBytesFromAddress(address)
	if not bytes then
		if not state.itemTypeSyncMemoryWarningShown then
			state.itemTypeSyncMemoryWarningShown = true
			log.warn("custom item type sync disabled: %s", tostring(readErr))
		end
		return false
	end

	state.itemTypeSyncMemoryWarningShown = false
	state.customItemTypesByIndex = state.customItemTypesByIndex or {}
	state.customItemTypesByIndex[targetIndex] = {
		index = targetIndex,
		sourceIndex = sourceIndex,
		bytes = bytes,
	}

	return true
end

local function allocateNextCustomIndex(state)
	local entriesByIndex = state.customItemTypesByIndex or {}
	local nextIndex = state.nextCustomItemTypeIndex or FIRST_CUSTOM_INDEX

	while nextIndex <= MAX_ITEM_TYPE_INDEX and entriesByIndex[nextIndex] do
		nextIndex = nextIndex + 1
	end

	if nextIndex > MAX_ITEM_TYPE_INDEX then
		return nil, "no more custom item type slots available (max index " .. MAX_ITEM_TYPE_INDEX .. ")"
	end

	state.nextCustomItemTypeIndex = nextIndex + 1
	return nextIndex
end

local function normalizeCustomIndex(index)
	return normalizeIndex(index, FIRST_CUSTOM_INDEX, MAX_ITEM_TYPE_INDEX)
end

local function cloneItemType(state, src, sourceRef, targetIndex, overrides)
	local sourceType = resolveItemType(sourceRef)
	assert(sourceType ~= nil, "itemTypes.clone: invalid source item type")

	if type(targetIndex) == "table" and overrides == nil then
		overrides = targetIndex
		targetIndex = nil
	end

	if targetIndex == nil then
		local allocatedIndex, allocErr = allocateNextCustomIndex(state)
		assert(allocatedIndex ~= nil, "itemTypes.clone: " .. tostring(allocErr))
		targetIndex = allocatedIndex
	end

	local normalizedTargetIndex = normalizeCustomIndex(targetIndex)
	assert(normalizedTargetIndex ~= nil, "itemTypes.clone: invalid target index " .. tostring(targetIndex))

	if normalizedTargetIndex >= (state.nextCustomItemTypeIndex or FIRST_CUSTOM_INDEX) then
		state.nextCustomItemTypeIndex = normalizedTargetIndex + 1
	end

	local targetType = getItemTypeByIndex(normalizedTargetIndex)
	assert(targetType ~= nil, "itemTypes.clone: failed to resolve target item type at index " .. tostring(normalizedTargetIndex))

	local sourceAddress, sourceAddrErr = getItemTypeAddress(sourceType)
	assert(sourceAddress, "itemTypes.clone: failed to get source address (" .. tostring(sourceAddrErr) .. ")")

	local targetAddress, targetAddrErr = getItemTypeAddress(targetType)
	assert(targetAddress, "itemTypes.clone: failed to get target address (" .. tostring(targetAddrErr) .. ")")

	local sourceBytes, readErr = readItemTypeBytesFromAddress(sourceAddress)
	assert(sourceBytes, "itemTypes.clone: failed to read source bytes (" .. tostring(readErr) .. ")")

	local okWrite, writeErr = writeItemTypeBytes(targetAddress, sourceBytes)
	assert(okWrite, "itemTypes.clone: failed writing target bytes (" .. tostring(writeErr) .. ")")

	applyCloneOverrides(targetType, overrides)

	local sourceIndex = getItemTypeIndex(sourceType)
	if snapshotCustomItemType(state, targetType, sourceIndex) then
		broadcastCustomItemTypes(state, src)
	end

	return targetType
end

local function runInitItemTypeHook(state, src)
	if state.itemTypeInitHookRan then
		return
	end
	state.itemTypeInitHookRan = true

	if type(hook) == "table" and type(hook.run) == "function" then
		local ok, runErr = pcall(hook.run, "SRC_InitItemType")
		if not ok then
			log.warn("SRC_InitItemType failed: %s", tostring(runErr))
		end
	end

	broadcastCustomItemTypes(state, src)
end

local function normalizeFireSoundPaths(soundPaths)
	if type(soundPaths) == "string" then
		assert(soundPaths ~= "", "src.setItemTypeFireSounds: sound path must be non-empty")
		return { soundPaths }
	end

	assert(type(soundPaths) == "table", "src.setItemTypeFireSounds: soundPaths must be string or table")

	local normalized = {}
	for i = 1, #soundPaths do
		local path = soundPaths[i]
		assert(type(path) == "string" and path ~= "",
			"src.setItemTypeFireSounds: every sound path must be a non-empty string")
		normalized[#normalized + 1] = path
	end

	return normalized
end

function M.install(state, src)
	if state.itemTypesAPIInstalled then
		return
	end

	if type(itemTypes) ~= "table" then
		log.warn("itemTypes API unavailable; custom item type helpers not installed")
		return
	end

	state.customItemTypesByIndex = state.customItemTypesByIndex or {}
	state.nextCustomItemTypeIndex = state.nextCustomItemTypeIndex or FIRST_CUSTOM_INDEX
	state.itemTypeModelAssignments = state.itemTypeModelAssignments or {}
	state.itemTypeIconAssignments = state.itemTypeIconAssignments or {}
	state.itemTypeFireSoundAssignments = state.itemTypeFireSoundAssignments or {}
	state.buildCustomItemTypesSyncPayload = function()
		return buildSyncPayload(state)
	end

	itemTypes.clone = function(sourceRef, targetIndexOrOverrides, overrides)
		return cloneItemType(state, src, sourceRef, targetIndexOrOverrides, overrides)
	end
	itemTypes.create = nil

	if type(src) == "table" then
		if type(src.syncCustomItemTypes) ~= "function" then
			src.syncCustomItemTypes = function(player)
				local payload = buildSyncPayload(state)
				if not payload then
					return false
				end
				return emitSyncPayload(src, payload, player)
			end
		end

		if type(src.setItemTypeModel) ~= "function" then
			src.setItemTypeModel = function(indexOrType, modelName, player)
				local targetIndex = getItemTypeIndex(indexOrType)
				assert(type(targetIndex) == "number",
					"src.setItemTypeModel(indexOrItemType, modelName, player?): first arg must be number or ItemType")

				assert(type(modelName) == "string" and modelName ~= "", "src.setItemTypeModel: modelName must be a non-empty string")
				assert(targetIndex >= 0 and targetIndex <= MAX_ITEM_TYPE_INDEX, "src.setItemTypeModel: index out of range")

				if player ~= nil then
					assert(type(player) == "userdata" and player.class == "Player", "src.setItemTypeModel: player must be Player or nil")
					assert(not player.isBot, "src.setItemTypeModel: player cannot be a bot")
				end

				state.itemTypeModelAssignments[targetIndex] = modelName
				local network = require("main.src.network")
				return network.sendItemTypeModel(state, player, targetIndex, modelName)
			end
		end

		if type(src.setItemTypeIcon) ~= "function" then
			src.setItemTypeIcon = function(indexOrType, iconPath, player)
				local targetIndex = getItemTypeIndex(indexOrType)
				assert(type(targetIndex) == "number",
					"src.setItemTypeIcon(indexOrItemType, iconPath, player?): first arg must be number or ItemType")

				assert(type(iconPath) == "string" and iconPath ~= "", "src.setItemTypeIcon: iconPath must be a non-empty string")
				assert(targetIndex >= 0 and targetIndex <= MAX_ITEM_TYPE_INDEX, "src.setItemTypeIcon: index out of range")

				if player ~= nil then
					assert(type(player) == "userdata" and player.class == "Player", "src.setItemTypeIcon: player must be Player or nil")
					assert(not player.isBot, "src.setItemTypeIcon: player cannot be a bot")
				end

				state.itemTypeIconAssignments[targetIndex] = iconPath
				local network = require("main.src.network")
				return network.sendItemTypeIcon(state, player, targetIndex, iconPath)
			end
		end

		if type(src.setItemTypeFireSounds) ~= "function" then
			src.setItemTypeFireSounds = function(indexOrType, soundPaths, player)
				local targetIndex = getItemTypeIndex(indexOrType)
				assert(type(targetIndex) == "number",
					"src.setItemTypeFireSounds(indexOrItemType, soundPaths, player?): first arg must be number or ItemType")

				assert(targetIndex >= 0 and targetIndex <= MAX_ITEM_TYPE_INDEX,
					"src.setItemTypeFireSounds: index out of range")

				if player ~= nil then
					assert(type(player) == "userdata" and player.class == "Player",
						"src.setItemTypeFireSounds: player must be Player or nil")
					assert(not player.isBot, "src.setItemTypeFireSounds: player cannot be a bot")
				end

				local normalizedSoundPaths = normalizeFireSoundPaths(soundPaths)
				state.itemTypeFireSoundAssignments[targetIndex] = normalizedSoundPaths

				local network = require("main.src.network")
				return network.sendItemTypeFireSounds(state, player, targetIndex, normalizedSoundPaths)
			end
		end
	end

	local function scheduleInitHook()
		if type(hook) == "table" and type(hook.once) == "function" then
			hook.once("Logic", function()
				runInitItemTypeHook(state, src)
			end)
			return
		end

		runInitItemTypeHook(state, src)
	end

	if type(hook) == "table" and type(hook.add) == "function" then
		hook.add("ConfigLoaded", "main.src.itemTypes.init", function()
			scheduleInitHook()
		end)
		scheduleInitHook()
	else
		runInitItemTypeHook(state, src)
	end

	state.itemTypesAPIInstalled = true
	log.info("itemTypes.clone API installed")
end

return M
