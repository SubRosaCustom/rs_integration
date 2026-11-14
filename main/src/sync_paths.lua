local utf8_sanitize = require("main.src.utf8_sanitize")

local sync_paths = {}

local PROTECTED_TEXTURE_FILES = {
	["texture/box.png"] = true,
	["texture/cash_dollar.png"] = true,
	["texture/cash_fifty.png"] = true,
	["texture/cash_five.png"] = true,
	["texture/cash_hundred.png"] = true,
	["texture/cash_one.png"] = true,
	["texture/cash_ten.png"] = true,
	["texture/cash_thousand.png"] = true,
	["texture/cash_twenty.png"] = true,
	["texture/disk.png"] = true,
	["texture/dotmatrixfont.png"] = true,
	["texture/font01.png"] = true,
	["texture/font02.png"] = true,
	["texture/hundredbill.png"] = true,
	["texture/icon-ak47.png"] = true,
	["texture/icon-bandage.png"] = true,
	["texture/icon-case-empty.png"] = true,
	["texture/icon-clip-ak47.png"] = true,
	["texture/icon-clip-m16.png"] = true,
	["texture/icon-clip-mp5.png"] = true,
	["texture/icon-clip-pistol.png"] = true,
	["texture/icon-clip-uzi.png"] = true,
	["texture/icon-disk-black.png"] = true,
	["texture/icon-disk-blue.png"] = true,
	["texture/icon-disk-gold.png"] = true,
	["texture/icon-disk-green.png"] = true,
	["texture/icon-disk-red.png"] = true,
	["texture/icon-disk-white.png"] = true,
	["texture/icon-grenade.png"] = true,
	["texture/icon-key.png"] = true,
	["texture/icon-keyboard.png"] = true,
	["texture/icon-m16.png"] = true,
	["texture/icon-mp5.png"] = true,
	["texture/icon-phone.png"] = true,
	["texture/icon-pistol.png"] = true,
	["texture/icon-soccer_ball.png"] = true,
	["texture/icon-stack.png"] = true,
	["texture/icon-uzi.png"] = true,
	["texture/icon_muted.png"] = true,
	["texture/icon_speaker.png"] = true,
	["texture/icon_talking.png"] = true,
	["texture/mic.png"] = true,
	["texture/money.png"] = true,
	["texture/mouse01.png"] = true,
	["texture/times.png"] = true,
	["texture/title.png"] = true,
}

function sync_paths.join(first, second)
	if first:sub(-1) == "/" then
		return first .. second
	end
	return first .. "/" .. second
end

function sync_paths.scripts_root(runtime_config)
	return sync_paths.join(runtime_config.clientRoot, "scripts")
end

function sync_paths.assets_root(runtime_config)
	return sync_paths.join(runtime_config.clientRoot, "assets")
end

-- Resolve before reading so an owner cannot import another tree through symlinks.
-- RosaServer runs on LuaJIT/Linux; fail closed if canonicalization is unavailable.
local realpath
local ok, ffi = pcall(require, "ffi")
if ok then
	pcall(ffi.cdef, "char *realpath(const char *path, char *resolved_path); void free(void *ptr);")
	realpath = function(path)
		local resolved = ffi.C.realpath(path, nil)
		if resolved == nil then return nil end
		local result = ffi.string(resolved)
		ffi.C.free(resolved)
		return result
	end
end

function sync_paths.exists(path)
	return realpath ~= nil and realpath(path) ~= nil
end

function sync_paths.is_contained(root, path)
	if not realpath or type(root) ~= "string" or type(path) ~= "string" then return false end
	root = root:gsub("/+$", "")
	if path:sub(1, #root + 1) ~= root .. "/" then return false end
	local relative = path:sub(#root + 2)
	if relative == "" or relative:find("..", 1, true) or relative:find("\\", 1, true)
		or relative:find("//", 1, true) or relative:find("%c") or relative:find(":", 1, true) then return false end
	local base, resolved = realpath(root), realpath(path)
	return base ~= nil and resolved ~= nil and resolved == base .. "/" .. relative
end

function sync_paths.read_file(path, max_bytes)
	local file = io.open(path, "rb")
	if not file then
		return nil
	end

	if not max_bytes then
		local contents, read_error = file:read("*all")
		file:close()
		assert(not read_error, "Cannot read sync file: " .. path .. ": " .. tostring(read_error))
		return contents
	end
	local chunks, total = {}, 0
	while true do
		local bytes, read_error = file:read(math.min(65536, max_bytes - total + 1))
		if read_error then
			file:close()
			error("Cannot read sync file: " .. path .. ": " .. tostring(read_error))
		end
		if not bytes or bytes == "" then break end
		total = total + #bytes
		if total > max_bytes then
			file:close()
			error("Sync file exceeds size limit: " .. path)
		end
		chunks[#chunks + 1] = bytes
	end
	file:close()
	return table.concat(chunks)
end

-- nil when the file can't be opened
function sync_paths.file_size(path)
	local file = io.open(path, "rb")
	if not file then
		return nil
	end
	local size, seek_error = file:seek("end")
	file:close()
	assert(size, "Cannot size sync file: " .. path .. ": " .. tostring(seek_error))
	return size
end

function sync_paths.extension(name)
	if type(name) ~= "string" then
		return ""
	end

	local dot = name:match("^.*()%.")
	if not dot then
		return ""
	end

	return name:sub(dot):lower()
end

function sync_paths.is_lua(path)
	return type(path) == "string" and path:sub(-4):lower() == ".lua"
end

local RESERVED_DEVICE_NAMES = { con = true, prn = true, aux = true, nul = true, ["conin$"] = true, ["conout$"] = true }

local function is_reserved_device_component(component)
	local stem = component:match("^([^.]*)"):gsub(" +$", ""):lower()
	if RESERVED_DEVICE_NAMES[stem] then return true end
	return stem:match("^com%d$") ~= nil or stem:match("^lpt%d$") ~= nil
end

-- same rules as the client's PathSafety::isSafeRelativePath
local function is_relative(path)
	if type(path) ~= "string" or path == "" or #path > 1024
		or path:find("[%c\\:<>\"|?*]") then
		return false
	end
	-- paths are echoed back, so repairing bytes would break lookup
	if not utf8_sanitize.is_valid(path) then
		return false
	end
	for component in (path .. "/"):gmatch("([^/]*)/") do
		if component == "" or component == "." or component == ".."
			or component:find("[%. ]$") or is_reserved_device_component(component) then
			return false
		end
	end
	return true
end

sync_paths.is_safe_relative = is_relative

-- non-UTF-8 name that would sync if valid, so the scan can report it
function sync_paths.is_invalid_utf8_syncable_name(name)
	if type(name) ~= "string" or utf8_sanitize.is_valid(name) then
		return false
	end
	local repaired = utf8_sanitize.sanitize(name)
	return sync_paths.is_safe_script(repaired) or sync_paths.is_safe_asset(repaired)
end

function sync_paths.is_safe_script(path)
	if not is_relative(path) then
		return false
	end

	local extension = sync_paths.extension(path)
	return extension == ".lua" or extension == ".yml" or extension == ".yaml" or extension == ".json"
end

function sync_paths.is_safe_asset(path)
	if not is_relative(path) then
		return false
	end

	local extension = sync_paths.extension(path)
	local is_supported = extension == ".csx"
		or extension == ".sbc"
		or extension == ".sbl"
		or extension == ".cmo"
		or extension == ".cmc"
		or extension == ".itm"
		or extension == ".it3"
		or extension == ".png"
		or extension == ".wav"
		or extension == ".sbv"
	if not is_supported then
		return false
	end

	return PROTECTED_TEXTURE_FILES[string.lower(path)] ~= true
end

return sync_paths
