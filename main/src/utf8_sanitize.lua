-- repairs invalid UTF-8 at the send boundary; the client's nlohmann::json rejects it, main.json doesn't
local utf8_sanitize = {}

utf8_sanitize.REPLACEMENT = "\239\191\189" -- U+FFFD
local MAX_DEPTH = 32

-- byte length of the valid sequence at i, or nil
local function sequence_length(s, i)
	local b1 = s:byte(i)
	if b1 < 0x80 then
		return 1
	end
	if b1 >= 0xC2 and b1 <= 0xDF then
		local b2 = s:byte(i + 1)
		if b2 and b2 >= 0x80 and b2 <= 0xBF then
			return 2
		end
	elseif b1 >= 0xE0 and b1 <= 0xEF then
		local b2, b3 = s:byte(i + 1, i + 2)
		if b2 and b3 and b3 >= 0x80 and b3 <= 0xBF then
			local low = b1 == 0xE0 and 0xA0 or 0x80
			local high = b1 == 0xED and 0x9F or 0xBF
			if b2 >= low and b2 <= high then
				return 3
			end
		end
	elseif b1 >= 0xF0 and b1 <= 0xF4 then
		local b2, b3, b4 = s:byte(i + 1, i + 3)
		if b2 and b3 and b4 and b3 >= 0x80 and b3 <= 0xBF and b4 >= 0x80 and b4 <= 0xBF then
			local low = b1 == 0xF0 and 0x90 or 0x80
			local high = b1 == 0xF4 and 0x8F or 0xBF
			if b2 >= low and b2 <= high then
				return 4
			end
		end
	end
	return nil
end

function utf8_sanitize.is_valid(s)
	if type(s) ~= "string" then
		return false
	end
	local i, n = 1, #s
	while i <= n do
		-- skip an ASCII run in one C call
		local ascii_end = s:find("[\128-\255]", i)
		if not ascii_end then
			return true
		end
		local length = sequence_length(s, ascii_end)
		if not length then
			return false
		end
		i = ascii_end + length
	end
	return true
end

-- invalid bytes become U+FFFD
function utf8_sanitize.sanitize(s)
	if type(s) ~= "string" or not s:find("[\128-\255]") or utf8_sanitize.is_valid(s) then
		return s
	end
	local parts, count = {}, 0
	local i, n = 1, #s
	while i <= n do
		local high = s:find("[\128-\255]", i)
		if not high then
			count = count + 1
			parts[count] = s:sub(i)
			break
		end
		if high > i then
			count = count + 1
			parts[count] = s:sub(i, high - 1)
		end
		local length = sequence_length(s, high)
		count = count + 1
		if length then
			parts[count] = s:sub(high, high + length - 1)
			i = high + length
		else
			parts[count] = utf8_sanitize.REPLACEMENT
			i = high + 1
		end
	end
	return table.concat(parts)
end

-- sanitized copy of every string key and value; clean, cyclic or too deep input comes back as is
local function sanitize_value(value, depth)
	local kind = type(value)
	if kind == "string" then
		return utf8_sanitize.sanitize(value)
	end
	if kind ~= "table" or depth > MAX_DEPTH then
		return value
	end
	local copy
	for key, item in pairs(value) do
		local new_key = sanitize_value(key, depth + 1)
		local new_item = sanitize_value(item, depth + 1)
		if copy == nil and (new_key ~= key or new_item ~= item) then
			copy = {}
			for k, v in pairs(value) do
				copy[k] = v
			end
		end
		if copy ~= nil then
			if new_key ~= key then
				copy[key] = nil
			end
			copy[new_key] = new_item
		end
	end
	return copy or value
end

function utf8_sanitize.sanitize_value(value)
	return sanitize_value(value, 0)
end

return utf8_sanitize
