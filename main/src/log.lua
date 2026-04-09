local M = {}

local function formatMessage(...)
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

local function timePrefix()
	return "\27[30;1m[" .. os.date("%X") .. "]\27[0m "
end

function M.info(...)
	print(timePrefix() .. "\27[38;5;45m[SRC]\27[0m " .. formatMessage(...))
end

function M.warn(...)
	print(timePrefix() .. "\27[33m[SRC]\27[0m " .. formatMessage(...))
end

return M
