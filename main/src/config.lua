local M = {}

M.DEFAULTS = {
	enabled = true,
	disallowNonSRCPlayers = false,
	clientRoot = "subrosacustom",
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
