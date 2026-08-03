local log = require("main.src.log")
local sync_paths = require("main.src.sync_paths")

local M = {}

local PROTOCOL_VERSION = 1
local ITEM_TYPE_SIZE = 0x13D0
local ITEM_TYPE_NATIVE_BUFFER_OFFSETS = { 0x13A8, 0x13B0, 0x13C0, 0x13C8, }
local MAX_ITEM_TYPE_COUNT = 255
local MAX_ITEM_TYPE_INDEX = MAX_ITEM_TYPE_COUNT - 1
local FIRST_CUSTOM_INDEX = 46

local function safe_read(obj, key)
	local ok, value = pcall(function()
		return obj[key]
	end)
	if not ok then
		return nil
	end
	return value
end

local function safe_write(obj, key, value)
	pcall(function()
		obj[key] = value
	end)
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

local function has_memory_read_api()
	return type(memory) == "table"
		and type(memory.getAddress) == "function"
		and type(memory.readBytes) == "function"
end

local function has_memory_write_api()
	return has_memory_read_api() and type(memory.writeBytes) == "function"
end

local function get_native_item_type_api()
	if type(srcIntegrationNative) ~= "table" then
		return nil
	end

	if type(srcIntegrationNative.loadITM) ~= "function"
		or type(srcIntegrationNative.loadIT3) ~= "function" then
		return nil
	end

	return srcIntegrationNative
end

local function is_item_type_userdata(value)
	return type(value) == "userdata" and safe_read(value, "class") == "ItemType"
end

local function get_item_type_by_index(index)
	local normalized = normalize_index(index, 0, MAX_ITEM_TYPE_INDEX)
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

local function get_item_type_index(ref)
	if is_item_type_userdata(ref) then
		return normalize_index(safe_read(ref, "index"), 0, MAX_ITEM_TYPE_INDEX)
	end

	if type(ref) == "number" then
		return normalize_index(ref, 0, MAX_ITEM_TYPE_INDEX)
	end

	return nil
end

local function get_item_type_address(item_type)
	if not has_memory_read_api() then
		return nil, "memory read api unavailable"
	end

	local address_ok, address = pcall(memory.getAddress, item_type)
	if not address_ok or type(address) ~= "number" or address <= 0 then
		return nil, ("failed to resolve item type address (%s)").format(tostring(address))
	end

	return address
end

local function read_item_type_bytes_from_address(address)
	if not has_memory_read_api() then
		return nil, "memory read api unavailable"
	end

	local bytes_ok, bytes_or_error = pcall(memory.readBytes, address, ITEM_TYPE_SIZE)
	if not bytes_ok then
		return nil, tostring(bytes_or_error)
	end

	if type(bytes_or_error) ~= "string" or #bytes_or_error ~= ITEM_TYPE_SIZE then
		return nil, "failed to read full item type blob"
	end

	return bytes_or_error
end

local function write_item_type_bytes(address, bytes)
	if not has_memory_write_api() then
		return false, "memory write api unavailable"
	end

	local write_ok, write_error = pcall(memory.writeBytes, address, bytes)
	if not write_ok then
		return false, tostring(write_error)
	end

	return true
end

local function resolve_item_type(ref)
	if is_item_type_userdata(ref) then
		return ref
	end

	if type(ref) == "number" then
		return get_item_type_by_index(ref)
	end

	if type(ref) == "string" and ref ~= "" and type(itemTypes.getByName) == "function" then
		local ok, item_type = pcall(itemTypes.getByName, ref)
		if ok then
			return item_type
		end
	end

	return nil
end

local function copy_vector(dst, src)
	if not dst or not src then
		return
	end

	local x = safe_read(src, "x")
	local y = safe_read(src, "y")
	local z = safe_read(src, "z")

	if type(x) == "number" then
		safe_write(dst, "x", x)
	end
	if type(y) == "number" then
		safe_write(dst, "y", y)
	end
	if type(z) == "number" then
		safe_write(dst, "z", z)
	end
end

local function value_looks_like_vector(value)
	return type(value) == "table"
		and (type(value.x) == "number" or type(value.y) == "number" or type(value.z) == "number")
end

local function apply_can_mount_to_overrides(target_type, can_mount_to_overrides)
	if not is_item_type_userdata(target_type) or type(can_mount_to_overrides) ~= "table" then
		return
	end

	for i = 1, #can_mount_to_overrides do
		local parent_index = i - 1
		if parent_index >= FIRST_CUSTOM_INDEX then
			break
		end

		local parent_type = get_item_type_by_index(parent_index)
		if parent_type then
			local value = can_mount_to_overrides[i]
			local allowed = value == true or value == 1
			pcall(target_type.setCanMountTo, target_type, parent_type, allowed)
		end
	end
end

local function apply_clone_overrides(target_type, overrides)
	if not is_item_type_userdata(target_type) or type(overrides) ~= "table" then
		return
	end

	for key, value in pairs(overrides) do
		if key ~= "canMountTo" and type(key) == "string" then
			if value_looks_like_vector(value) then
				local destination_vector = safe_read(target_type, key)
				if destination_vector then
					copy_vector(destination_vector, value)
				end
			elseif type(value) == "number" or type(value) == "boolean" or type(value) == "string" then
				safe_write(target_type, key, value)
			end
		end
	end

	apply_can_mount_to_overrides(target_type, overrides.canMountTo)
end

function M.build_sync_payload(state)
	local entries_by_index = state.custom_item_types_by_index or {}
	local item_type_entries = {}

	for _, entry in pairs(entries_by_index) do
		if type(entry) == "table" and type(entry.bytes) == "string" and #entry.bytes == ITEM_TYPE_SIZE then
			item_type_entries[#item_type_entries + 1] = entry
		end
	end

	table.sort(item_type_entries, function(a, b)
		return (a.index or 0) < (b.index or 0)
	end)

	if #item_type_entries == 0 then
		return nil
	end

	local metadata = {}
	local chunks = {}
	for i = 1, #item_type_entries do
		local entry = item_type_entries[i]
		metadata[#metadata + 1] = {
			index = entry.index,
			sourceIndex = entry.sourceIndex,
		}
		chunks[#chunks + 1] = entry.bytes
	end

	local raw_blob = table.concat(chunks)
	if #raw_blob ~= (#metadata * ITEM_TYPE_SIZE) then
		log.warn("failed to build custom item type sync blob: size mismatch")
		return nil
	end

	return {
		version = PROTOCOL_VERSION,
		itemTypeSize = ITEM_TYPE_SIZE,
		itemTypes = metadata,
		binRaw = raw_blob,
	}
end

local function emit_sync_payload(src, payload, player)
	if type(src) ~= "table" or type(src.syncClientItemTypes) ~= "function" then
		return false
	end

	if type(payload) ~= "table" then
		return false
	end

	if type(payload.itemTypes) ~= "table" or #payload.itemTypes == 0 then
		return false
	end

	if type(payload.binRaw) ~= "string" or payload.binRaw == "" then
		return false
	end

	local ok, sent = pcall(src.syncClientItemTypes, player, payload)
	if not ok then
		log.warn("failed to emit custom item type sync payload: %s", tostring(sent))
		return false
	end

	return sent and true or false
end

local function broadcast_custom_item_types(state, src)
	local payload = M.build_sync_payload(state)
	if payload then
		emit_sync_payload(src, payload, nil)
	end
end

local function snapshot_custom_item_type(state, target_type, source_index)
	local target_index = get_item_type_index(target_type)
	if target_index == nil then
		return false
	end

	local address, address_error = get_item_type_address(target_type)
	if not address then
		if not state.item_type_sync_memory_warning_shown then
			state.item_type_sync_memory_warning_shown = true
			log.warn("custom item type sync disabled: %s", tostring(address_error))
		end
		return false
	end

	local bytes, read_error = read_item_type_bytes_from_address(address)
	if not bytes then
		if not state.item_type_sync_memory_warning_shown then
			state.item_type_sync_memory_warning_shown = true
			log.warn("custom item type sync disabled: %s", tostring(read_error))
		end
		return false
	end

	state.item_type_sync_memory_warning_shown = false
	state.custom_item_types_by_index = state.custom_item_types_by_index or {}
	state.custom_item_types_by_index[target_index] = {
		index = target_index,
		sourceIndex = source_index,
		bytes = bytes,
	}

	return true
end

local function allocate_next_custom_index(state)
	local entries_by_index = state.custom_item_types_by_index or {}
	local next_index = state.next_custom_item_type_index or FIRST_CUSTOM_INDEX

	while next_index <= MAX_ITEM_TYPE_INDEX and entries_by_index[next_index] do
		next_index = next_index + 1
	end

	if next_index > MAX_ITEM_TYPE_INDEX then
		return nil, "no more custom item type slots available (max index " .. MAX_ITEM_TYPE_INDEX .. ")"
	end

	state.next_custom_item_type_index = next_index + 1
	return next_index
end

local function normalize_custom_index(index)
	return normalize_index(index, FIRST_CUSTOM_INDEX, MAX_ITEM_TYPE_INDEX)
end

local function clone_item_type(state, src, source_ref, target_index, overrides)
	local source_type = resolve_item_type(source_ref)
	assert(source_type ~= nil, "itemTypes.clone: invalid source item type")

	if type(target_index) == "table" and overrides == nil then
		overrides = target_index
		target_index = nil
	end

	if target_index == nil then
		local allocated_index, allocation_error = allocate_next_custom_index(state)
		assert(allocated_index ~= nil, "itemTypes.clone: " .. tostring(allocation_error))
		target_index = allocated_index
	end

	local normalized_target_index = normalize_custom_index(target_index)
	assert(normalized_target_index ~= nil, "itemTypes.clone: invalid target index " .. tostring(target_index))

	if normalized_target_index >= (state.next_custom_item_type_index or FIRST_CUSTOM_INDEX) then
		state.next_custom_item_type_index = normalized_target_index + 1
	end

	memory.writeFloat(memory.getBaseAddress() + 0x5a60d7c0 + (normalized_target_index * 0x13D0) + 0x8, 0.1) -- set mass to 0.1 to make the item_type "valid"
	local target_type = get_item_type_by_index(normalized_target_index)
	assert(target_type ~= nil, "itemTypes.clone: failed to resolve target item type at index " .. tostring(normalized_target_index))

	local source_address, source_address_error = get_item_type_address(source_type)
	assert(source_address, "itemTypes.clone: failed to get source address (" .. tostring(source_address_error) .. ")")

	local target_address, target_address_error = get_item_type_address(target_type)
	assert(target_address, "itemTypes.clone: failed to get target address (" .. tostring(target_address_error) .. ")")

	local source_bytes, read_error = read_item_type_bytes_from_address(source_address)
	assert(source_bytes, "itemTypes.clone: failed to read source bytes (" .. tostring(read_error) .. ")")

	local write_ok, write_error = write_item_type_bytes(target_address, source_bytes)
	assert(write_ok, "itemTypes.clone: failed writing target bytes (" .. tostring(write_error) .. ")")

	apply_clone_overrides(target_type, overrides)

	local source_index = get_item_type_index(source_type)
	if snapshot_custom_item_type(state, target_type, source_index) then
		broadcast_custom_item_types(state, src)
	end

	return target_type
end

local function run_init_item_type_hook(state, src)
	if state.item_type_init_hook_ran then
		return
	end
	state.item_type_init_hook_ran = true

	if type(hook) == "table" and type(hook.run) == "function" then
		local ok, run_error = pcall(hook.run, "SRC_InitItemType")
		if not ok then
			log.warn("SRC_InitItemType failed: %s", tostring(run_error))
		end
	end

	broadcast_custom_item_types(state, src)
end

local function normalize_fire_sound_paths(sound_paths)
	if type(sound_paths) == "string" then
		assert(sound_paths ~= "", "src.setItemTypeFireSounds: sound ref must be non-empty")
		local trimmed = sound_paths:match("^%s*(.-)%s*$")
		assert(trimmed ~= "", "src.setItemTypeFireSounds: sound ref must be non-empty")

		local lowered = string.lower(trimmed)
		if lowered:find("/", 1, true) or lowered:find("\\", 1, true) or lowered:match("%.wav$") then
			return {
				kind = "files",
				files = { trimmed },
			}
		end

		local builtin = lowered:gsub("%.wav$", "")
		assert(builtin ~= "", "src.setItemTypeFireSounds: builtin sound ref must be non-empty")
		return {
			kind = "builtin",
			builtin = builtin,
		}
	end

	assert(type(sound_paths) == "table", "src.setItemTypeFireSounds: soundPaths must be string or table")

	local normalized = {}
	for i = 1, #sound_paths do
		local path = sound_paths[i]
		assert(type(path) == "string" and path ~= "",
			"src.setItemTypeFireSounds: every sound path must be a non-empty string")
		normalized[#normalized + 1] = path
	end

	assert(#normalized <= 6, "src.setItemTypeFireSounds: maximum 6 custom sound paths")

	return {
		kind = "files",
		files = normalized,
	}
end

local BUILTIN_TEXTURE_NAMES = {
	gun_tex = true,
	grenade = true,
	soccerball = true,
	watermelon = true,
	tex_2 = true,
}

local function normalize_texture_assignment(texture_ref)
	assert(type(texture_ref) == "string" and texture_ref ~= "", "src.setItemTypeTexture: texture ref must be a non-empty string")

	local trimmed = texture_ref:match("^%s*(.-)%s*$")
	assert(trimmed ~= "", "src.setItemTypeTexture: texture ref must be non-empty")

	local file_name = trimmed:match("([^/\\]+)$") or trimmed
	local stem = string.lower(file_name):gsub("%.png$", "")
	if BUILTIN_TEXTURE_NAMES[stem] then
		return {
			kind = "builtin",
			builtin = stem,
		}
	end

	return {
		kind = "file",
		file = trimmed,
	}
end

local function normalize_item_type_file(state, path, extension, label)
	assert(type(path) == "string" and path ~= "", "src.setItemType" .. label .. ": path must be a non-empty string")
	local trimmed = path:match("^%s*(.-)%s*$")
	assert(trimmed ~= "", "src.setItemType" .. label .. ": path must be a non-empty string")
	assert(not trimmed:find("\\", 1, true), "src.setItemType" .. label .. ": use forward slash paths")
	assert(string.lower(trimmed):match("%" .. extension .. "$"), "src.setItemType" .. label .. ": path must end with " .. extension)

	local candidates = {
		trimmed,
		sync_paths.join(sync_paths.assets_root(state.config), trimmed),
		sync_paths.join(state.config.clientRoot, trimmed),
	}
	for i = 1, #candidates do
		local candidate = candidates[i]
		local file = io.open(candidate, "rb")
		if file ~= nil then
			file:close()
			return trimmed, candidate
		end
	end

	assert(false, "src.setItemType" .. label .. ": missing file " .. trimmed)
end

local function apply_native_item_type_file(state, target_index, file_path, loader_name)
	local native_api = get_native_item_type_api()
	assert(native_api ~= nil, "src.setItemType" .. loader_name .. ": srcIntegrationNative item model helpers unavailable")

	local target_type = get_item_type_by_index(target_index)
	assert(target_type ~= nil, "src.setItemType" .. loader_name .. ": failed to resolve item type at index " .. tostring(target_index))
	if not state.item_type_native_file_loaded[target_index] then
		local target_address, target_address_error = get_item_type_address(target_type)
		assert(target_address, "src.setItemType" .. loader_name .. ": failed to resolve item type address (" .. tostring(target_address_error) .. ")")
		for _, offset in ipairs(ITEM_TYPE_NATIVE_BUFFER_OFFSETS) do
			local write_ok, write_error = write_item_type_bytes(target_address + offset, string.rep("\0", 8))
			assert(write_ok, "src.setItemType" .. loader_name .. ": failed clearing inherited native buffer (" .. tostring(write_error) .. ")")
		end
	end

	native_api["load" .. loader_name](target_index, file_path)
	state.item_type_native_file_loaded[target_index] = true
	local existing_entry = state.custom_item_types_by_index and state.custom_item_types_by_index[target_index]
	local source_index = type(existing_entry) == "table" and existing_entry.sourceIndex or target_index
	assert(snapshot_custom_item_type(state, target_type, source_index),
		"src.setItemType" .. loader_name .. ": failed to snapshot item type after native load")
end

function M.install(state, src, force)
	local was_installed = state.item_types_api_installed
	if was_installed and not force then
		return
	end

	if type(itemTypes) ~= "table" then
		log.warn("itemTypes API unavailable; custom item type helpers not installed")
		return
	end

	state.custom_item_types_by_index = state.custom_item_types_by_index or {}
	state.next_custom_item_type_index = state.next_custom_item_type_index or FIRST_CUSTOM_INDEX
	state.item_type_model_assignments = state.item_type_model_assignments or {}
	state.item_type_icon_assignments = state.item_type_icon_assignments or {}
	state.item_type_itm_assignments = state.item_type_itm_assignments or {}
	state.item_type_it3_assignments = state.item_type_it3_assignments or {}
	state.item_type_native_file_loaded = state.item_type_native_file_loaded or {}
	state.item_type_texture_assignments = state.item_type_texture_assignments or {}
	state.item_type_fire_sound_assignments = state.item_type_fire_sound_assignments or {}

	itemTypes.clone = function(source_ref, target_index_or_overrides, overrides)
		return clone_item_type(state, src, source_ref, target_index_or_overrides, overrides)
	end
	itemTypes.create = nil

	if type(src) == "table" then
		if force or type(src.syncCustomItemTypes) ~= "function" then
			src.syncCustomItemTypes = function(player)
				local payload = M.build_sync_payload(state)
				if not payload then
					return false
				end
				return emit_sync_payload(src, payload, player)
			end
		end

		if force or type(src.setItemTypeModel) ~= "function" then
			src.setItemTypeModel = function(index_or_type, model_name, player)
				local target_index = get_item_type_index(index_or_type)
				assert(type(target_index) == "number",
					"src.setItemTypeModel(indexOrItemType, modelName, player?): first arg must be number or ItemType")

				assert(type(model_name) == "string" and model_name ~= "", "src.setItemTypeModel: modelName must be a non-empty string")
				assert(target_index >= 0 and target_index <= MAX_ITEM_TYPE_INDEX, "src.setItemTypeModel: index out of range")

				if player ~= nil then
					assert(type(player) == "userdata" and player.class == "Player", "src.setItemTypeModel: player must be Player or nil")
					assert(not player.isBot, "src.setItemTypeModel: player cannot be a bot")
				end

				state.item_type_model_assignments[target_index] = model_name
				local network = require("main.src.network")
				src.syncCustomItemTypes(player)
				return network.send_item_type_model(state, player, target_index, model_name)
			end
		end

		if force or type(src.setItemTypeIcon) ~= "function" then
			src.setItemTypeIcon = function(index_or_type, icon_path, player)
				local target_index = get_item_type_index(index_or_type)
				assert(type(target_index) == "number",
					"src.setItemTypeIcon(indexOrItemType, iconPath, player?): first arg must be number or ItemType")

				assert(type(icon_path) == "string" and icon_path ~= "", "src.setItemTypeIcon: iconPath must be a non-empty string")
				assert(target_index >= 0 and target_index <= MAX_ITEM_TYPE_INDEX, "src.setItemTypeIcon: index out of range")

				if player ~= nil then
					assert(type(player) == "userdata" and player.class == "Player", "src.setItemTypeIcon: player must be Player or nil")
					assert(not player.isBot, "src.setItemTypeIcon: player cannot be a bot")
				end

				state.item_type_icon_assignments[target_index] = icon_path
				local network = require("main.src.network")
				src.syncCustomItemTypes(player)
				return network.send_item_type_icon(state, player, target_index, icon_path)
			end
		end

		if force or type(src.setItemTypeITM) ~= "function" then
			src.setItemTypeITM = function(index_or_type, itm_path, player)
				local target_index = get_item_type_index(index_or_type)
				assert(type(target_index) == "number",
					"src.setItemTypeITM(indexOrItemType, itmPath, player?): first arg must be number or ItemType")
				assert(target_index >= 0 and target_index <= MAX_ITEM_TYPE_INDEX, "src.setItemTypeITM: index out of range")
				if player ~= nil then
					assert(type(player) == "userdata" and player.class == "Player", "src.setItemTypeITM: player must be Player or nil")
					assert(not player.isBot, "src.setItemTypeITM: player cannot be a bot")
				end

				local sync_path, server_path = normalize_item_type_file(state, itm_path, ".itm", "ITM")
				apply_native_item_type_file(state, target_index, server_path, "ITM")
				state.item_type_itm_assignments[target_index] = sync_path
				local network = require("main.src.network")
				src.syncCustomItemTypes(player)
				return network.send_item_type_itm(state, player, target_index, sync_path)
			end
		end

		if force or type(src.setItemTypeIT3) ~= "function" then
			src.setItemTypeIT3 = function(index_or_type, it3_path, player)
				local target_index = get_item_type_index(index_or_type)
				assert(type(target_index) == "number",
					"src.setItemTypeIT3(indexOrItemType, it3Path, player?): first arg must be number or ItemType")
				assert(target_index >= 0 and target_index <= MAX_ITEM_TYPE_INDEX, "src.setItemTypeIT3: index out of range")
				if player ~= nil then
					assert(type(player) == "userdata" and player.class == "Player", "src.setItemTypeIT3: player must be Player or nil")
					assert(not player.isBot, "src.setItemTypeIT3: player cannot be a bot")
				end

				local sync_path, server_path = normalize_item_type_file(state, it3_path, ".it3", "IT3")
				apply_native_item_type_file(state, target_index, server_path, "IT3")
				state.item_type_it3_assignments[target_index] = sync_path
				local network = require("main.src.network")
				src.syncCustomItemTypes(player)
				return network.send_item_type_it3(state, player, target_index, sync_path)
			end
		end

		if force or type(src.setItemTypeTexture) ~= "function" then
			src.setItemTypeTexture = function(index_or_type, texture_ref, player)
				local target_index = get_item_type_index(index_or_type)
				assert(type(target_index) == "number",
					"src.setItemTypeTexture(indexOrItemType, textureRef, player?): first arg must be number or ItemType")

				assert(target_index >= 0 and target_index <= MAX_ITEM_TYPE_INDEX, "src.setItemTypeTexture: index out of range")

				if player ~= nil then
					assert(type(player) == "userdata" and player.class == "Player", "src.setItemTypeTexture: player must be Player or nil")
					assert(not player.isBot, "src.setItemTypeTexture: player cannot be a bot")
				end

				local normalized_texture = normalize_texture_assignment(texture_ref)
				state.item_type_texture_assignments[target_index] = normalized_texture

				local network = require("main.src.network")
				src.syncCustomItemTypes(player)
				return network.send_item_type_texture(state, player, target_index, normalized_texture)
			end
		end

		if force or type(src.setItemTypeFireSounds) ~= "function" then
			src.setItemTypeFireSounds = function(index_or_type, sound_paths, player)
				local target_index = get_item_type_index(index_or_type)
				assert(type(target_index) == "number",
					"src.setItemTypeFireSounds(indexOrItemType, soundPaths, player?): first arg must be number or ItemType")

				assert(target_index >= 0 and target_index <= MAX_ITEM_TYPE_INDEX,
					"src.setItemTypeFireSounds: index out of range")

				if player ~= nil then
					assert(type(player) == "userdata" and player.class == "Player",
						"src.setItemTypeFireSounds: player must be Player or nil")
					assert(not player.isBot, "src.setItemTypeFireSounds: player cannot be a bot")
				end

				local normalized_sound_paths = normalize_fire_sound_paths(sound_paths)
				state.item_type_fire_sound_assignments[target_index] = normalized_sound_paths

				local network = require("main.src.network")
				src.syncCustomItemTypes(player)
				return network.send_item_type_fire_sounds(state, player, target_index, normalized_sound_paths)
			end
		end
	end

	local function schedule_init_hook()
		if type(hook) == "table" and type(hook.once) == "function" then
			hook.once("Logic", function()
				run_init_item_type_hook(state, src)
			end)
			return
		end

		run_init_item_type_hook(state, src)
	end

	if type(hook) == "table" and type(hook.add) == "function" then
		hook.add("ConfigLoaded", "main.src.itemTypes.init", function()
			schedule_init_hook()
		end)
		schedule_init_hook()
	else
		run_init_item_type_hook(state, src)
	end

	state.item_types_api_installed = true
	log.info("itemTypes.clone API installed")
end

return M
