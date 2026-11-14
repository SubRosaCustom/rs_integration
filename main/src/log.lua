local log = {}

local function format_message(...)
	local count = select("#", ...)
	if count == 0 then
		return ""
	end

	if count == 1 then
		return tostring((...))
	end

	local first = select(1, ...)
	if type(first) == "string" then
		local ok, formatted = pcall(string.format, first, select(2, ...))
		if ok then
			return formatted
		end
	end

	local parts = {}
	for i = 1, count do
		parts[i] = tostring(select(i, ...))
	end
	return table.concat(parts, "\t")
end

local function time_prefix()
	return "\27[30;1m[" .. os.date("%X") .. "]\27[0m "
end

function log.info(...)
	print(time_prefix() .. "\27[38;5;45m[SRC]\27[0m " .. format_message(...))
end

function log.warn(...)
	print(time_prefix() .. "\27[33m[SRC]\27[0m " .. format_message(...))
end

local WARN_LIMIT_INTERVAL_SECONDS = 10

-- limits is caller-owned with fixed string keys, so peers can't grow it
function log.warn_limited(limits, key, ...)
	local now = os.time()
	local entry = limits[key]
	if not entry then
		entry = { next_time = 0, suppressed = 0, }
		limits[key] = entry
	end
	if now < entry.next_time then
		entry.suppressed = entry.suppressed + 1
		return
	end

	local message = format_message(...)
	if entry.suppressed > 0 then
		message = string.format("%s (%d similar suppressed)", message, entry.suppressed)
		entry.suppressed = 0
	end
	entry.next_time = now + WARN_LIMIT_INTERVAL_SECONDS
	log.warn("%s", message)
end

return log
