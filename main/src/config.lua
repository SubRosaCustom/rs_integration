local M = {}

local BASE64_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local function encode_base64(bytes)
	local encoded = (bytes:gsub(".", function(character)
		local value = character:byte()
		local bits = ""
		for index = 8, 1, -1 do
			bits = bits .. (value % 2 ^ index - value % 2 ^ (index - 1) > 0 and "1" or "0")
		end
		return bits
	end) .. "0000"):gsub("%d%d%d?%d?%d?%d?", function(bits)
		if #bits < 6 then
			return ""
		end
		local value = 0
		for index = 1, 6 do
			value = value + (bits:sub(index, index) == "1" and 2 ^ (6 - index) or 0)
		end
		return BASE64_ALPHABET:sub(value + 1, value + 1)
	end)
	return encoded .. ({ "", "==", "=" })[#bytes % 3 + 1]
end

local function load_motd_icon(path)
	if path == "" then
		return ""
	end
	local file = io.open(path, "rb")
	if not file then
		return ""
	end
	local bytes = file:read("*a")
	file:close()
	if #bytes >= 5 * 1024 or #bytes < 24 or bytes:sub(1, 8) ~= "\137PNG\r\n\26\n" then
		return ""
	end
	local width, height = string.unpack(">I4I4", bytes, 17)
	if width ~= 32 or height ~= 32 then
		return ""
	end
	return encode_base64(bytes)
end

M.DEFAULTS = {
	enabled = true,
	disallowNonSRCPlayers = false,
	clientRoot = "subrosacustom",
	motd = "",
	motdIcon = "",
	motdIconData = "",
	readSize = 16384,
	fileChunkSize = 65536,
	maxReadBytesPerTick = 262144,
	maxSendBytesPerTick = 1048576,
	maxFileChunksPerTick = 16,
	maxQueuedSendFrames = 64,
	autoRefreshEnabled = false,
	autoRefreshDebounceTicks = 20,
	eventRetryBaseTicks = 20,
	eventRetryMaxAttempts = 5,
	maxEventBytes = 262144,
	eventProcessTimeoutTicks = 180,
	eventDebugLogSuccess = false,
}

local function copy_defaults()
	local copy = {}
	for key, value in pairs(M.DEFAULTS) do
		copy[key] = value
	end
	return copy
end

local function normalize_number(value, fallback, minimum)
	local number = tonumber(value)
	if not number then
		return fallback
	end

	if minimum and number < minimum then
		return minimum
	end

	return number
end

function M.resolve(raw)
	local resolved = copy_defaults()
	if type(raw) ~= "table" then
		return resolved
	end

	if type(raw.enabled) == "boolean" then
		resolved.enabled = raw.enabled
	end

	if type(raw.disallowNonSRCPlayers) == "boolean" then
		resolved.disallowNonSRCPlayers = raw.disallowNonSRCPlayers
	end

	if type(raw.clientRoot) == "string" and raw.clientRoot ~= "" then
		resolved.clientRoot = raw.clientRoot
	end

	if type(raw.motd) == "string" then
		resolved.motd = raw.motd:sub(1, 160)
	end

	if type(raw.motdIcon) == "string" then
		resolved.motdIcon = raw.motdIcon
	end
	resolved.motdIconData = load_motd_icon(resolved.motdIcon)

	resolved.readSize = normalize_number(raw.readSize, resolved.readSize, 1024)
	resolved.fileChunkSize = normalize_number(raw.fileChunkSize, resolved.fileChunkSize, 256)
	resolved.maxReadBytesPerTick = normalize_number(raw.maxReadBytesPerTick, resolved.maxReadBytesPerTick, 4096)
	resolved.maxSendBytesPerTick = normalize_number(raw.maxSendBytesPerTick, resolved.maxSendBytesPerTick, 4096)
	resolved.maxFileChunksPerTick = normalize_number(raw.maxFileChunksPerTick, resolved.maxFileChunksPerTick, 1)
	resolved.maxQueuedSendFrames = normalize_number(raw.maxQueuedSendFrames, resolved.maxQueuedSendFrames, 8)
	resolved.autoRefreshEnabled = raw.autoRefreshEnabled == true
	resolved.autoRefreshDebounceTicks = normalize_number(
		raw.autoRefreshDebounceTicks,
		resolved.autoRefreshDebounceTicks,
		1
	)
	resolved.eventRetryBaseTicks = normalize_number(raw.eventRetryBaseTicks, resolved.eventRetryBaseTicks, 1)
	resolved.eventRetryMaxAttempts = normalize_number(
		raw.eventRetryMaxAttempts,
		resolved.eventRetryMaxAttempts,
		1
	)
	resolved.maxEventBytes = normalize_number(raw.maxEventBytes, resolved.maxEventBytes, 1024)
	resolved.eventProcessTimeoutTicks = normalize_number(
		raw.eventProcessTimeoutTicks,
		resolved.eventProcessTimeoutTicks,
		1
	)
	if type(raw.eventDebugLogSuccess) == "boolean" then
		resolved.eventDebugLogSuccess = raw.eventDebugLogSuccess
	end

	return resolved
end

function M.copy_defaults()
	return copy_defaults()
end

return M
