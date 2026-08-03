local M = {}

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

function M.join(first, second)
	if first:sub(-1) == "/" then
		return first .. second
	end
	return first .. "/" .. second
end

function M.scripts_root(runtime_config)
	return M.join(runtime_config.clientRoot, "scripts")
end

function M.assets_root(runtime_config)
	return M.join(runtime_config.clientRoot, "assets")
end

function M.read_file(path)
	local file = io.open(path, "rb")
	if not file then
		return nil
	end

	local contents = file:read("*all")
	file:close()
	return contents
end

function M.extension(name)
	if type(name) ~= "string" then
		return ""
	end

	local dot = name:match("^.*()%.")
	if not dot then
		return ""
	end

	return name:sub(dot):lower()
end

function M.is_lua(path)
	return type(path) == "string" and path:sub(-4):lower() == ".lua"
end

local function is_relative(path)
	return type(path) == "string"
		and path ~= ""
		and not path:find("\\", 1, true)
		and path:sub(1, 1) ~= "/"
		and not path:find("..", 1, true)
end

function M.is_safe_script(path)
	if not is_relative(path) then
		return false
	end

	local extension = M.extension(path)
	return extension == ".lua" or extension == ".yml" or extension == ".yaml" or extension == ".json"
end

function M.is_safe_asset(path)
	if not is_relative(path) then
		return false
	end

	local extension = M.extension(path)
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

return M
