local json = require("main.json")

local M = {}

M.DEFAULT_CONFIG = {
	enabled = true,
	disallowNonSRCPlayers = false,
	clientRoot = "subrosacustom",
	readSize = 16384,
	fileChunkSize = 12000,
	maxReadBytesPerTick = 262144,
	maxSendBytesPerTick = 262144,
	maxFileChunksPerTick = 8,
	maxQueuedSendFrames = 256,
	autoRefreshEnabled = false,
	autoRefreshDebounceTicks = 20,
	eventRetryBaseTicks = 20,
	eventRetryMaxAttempts = 5,
	maxEventBytes = 262144,
	eventProcessTimeoutTicks = 180,
	eventDebugLogSuccess = false,
}

local function copyDefaults()
	local out = {}
	for key, value in pairs(M.DEFAULT_CONFIG) do
		out[key] = value
	end
	return out
end

local function normalizeNumber(value, fallback, minValue)
	local num = tonumber(value)
	if not num then
		return fallback
	end

	if minValue and num < minValue then
		return minValue
	end

	return num
end

function M.resolveConfig(raw)
	local cfg = copyDefaults()
	if type(raw) ~= "table" then
		return cfg
	end

	if type(raw.enabled) == "boolean" then
		cfg.enabled = raw.enabled
	end

	if type(raw.disallowNonSRCPlayers) == "boolean" then
		cfg.disallowNonSRCPlayers = raw.disallowNonSRCPlayers
	end

	if type(raw.clientRoot) == "string" and raw.clientRoot ~= "" then
		cfg.clientRoot = raw.clientRoot
	end

	cfg.readSize = normalizeNumber(raw.readSize, cfg.readSize, 1024)
	cfg.fileChunkSize = normalizeNumber(raw.fileChunkSize, cfg.fileChunkSize, 256)
	cfg.maxReadBytesPerTick = normalizeNumber(raw.maxReadBytesPerTick, cfg.maxReadBytesPerTick, 4096)
	cfg.maxSendBytesPerTick = normalizeNumber(raw.maxSendBytesPerTick, cfg.maxSendBytesPerTick, 4096)
	cfg.maxFileChunksPerTick = normalizeNumber(raw.maxFileChunksPerTick, cfg.maxFileChunksPerTick, 1)
	cfg.maxQueuedSendFrames = normalizeNumber(raw.maxQueuedSendFrames, cfg.maxQueuedSendFrames, 8)
	cfg.autoRefreshEnabled = raw.autoRefreshEnabled == true
	cfg.autoRefreshDebounceTicks = normalizeNumber(raw.autoRefreshDebounceTicks, cfg.autoRefreshDebounceTicks, 1)
	cfg.eventRetryBaseTicks = normalizeNumber(raw.eventRetryBaseTicks, cfg.eventRetryBaseTicks, 1)
	cfg.eventRetryMaxAttempts = normalizeNumber(raw.eventRetryMaxAttempts, cfg.eventRetryMaxAttempts, 1)
	cfg.maxEventBytes = normalizeNumber(raw.maxEventBytes, cfg.maxEventBytes, 1024)
	cfg.eventProcessTimeoutTicks = normalizeNumber(raw.eventProcessTimeoutTicks, cfg.eventProcessTimeoutTicks, 1)
	if type(raw.eventDebugLogSuccess) == "boolean" then
		cfg.eventDebugLogSuccess = raw.eventDebugLogSuccess
	end

	return cfg
end

local GLOBAL_STATE_KEY = "__srcMainState"

function M.getState()
	local existing = _G[GLOBAL_STATE_KEY]
	if existing then
		return existing
	end

	local created = {
		config = copyDefaults(),
		enabled = true,
		runtimeActive = false,
		hooksRegistered = false,
		moduleLoaded = false,
		tcpBindInProgress = false,
		tick = 0,
		nextEventID = 1,
		tcpServer = nil,
		boundPort = nil,
		clients = {},
		eventHandlers = {},
		scripts = {},
		scriptsByPath = {},
		assetFiles = {},
		assetFilesByPath = {},
		loadedLevel = "",
		persistentMode = "",
		fileWatcher = nil,
		watchedDirectories = {},
		watchedRoot = nil,
		pendingRefreshTick = nil,
		itemTypesAPIInstalled = false,
		customItemTypesByIndex = {},
		nextCustomItemTypeIndex = 46,
		itemTypeInitHookRan = false,
		itemTypeModelAssignments = {},
		itemTypeIconAssignments = {},
		itemTypeFireSoundAssignments = {},
		buildCustomItemTypesSyncPayload = nil,
	}

	_G[GLOBAL_STATE_KEY] = created
	return created
end

function M.clientId(connection)
	return string.format("%s:%s", tostring(connection.address), tostring(connection.port))
end

function M.safeJsonDecode(raw)
	if type(raw) ~= "string" or raw == "" then
		return nil
	end

	local ok, decoded = pcall(json.decode, raw)
	if not ok or type(decoded) ~= "table" then
		return nil
	end

	return decoded
end

function M.joinPath(a, b)
	if a:sub(-1) == "/" then
		return a .. b
	end
	return a .. "/" .. b
end

function M.scriptsRoot(config)
	return M.joinPath(config.clientRoot, "scripts")
end

function M.assetsRoot(config)
	return M.joinPath(config.clientRoot, "assets")
end

function M.readFile(path)
	local file = io.open(path, "rb")
	if not file then
		return nil
	end

	local data = file:read("*all")
	file:close()
	return data
end

local function fileExtension(name)
	if type(name) ~= "string" then
		return ""
	end

	local dot = name:match("^.*()%.")
	if not dot then
		return ""
	end

	return name:sub(dot):lower()
end

local function toLower(value)
	if type(value) ~= "string" then
		return ""
	end
	return string.lower(value)
end

local DEFAULT_GAME_MODEL_CMO_FILES = {
	["9mm.cmo"] = true,
	["9mm_magazine.cmo"] = true,
	["ak47.cmo"] = true,
	["ak47_magazine.cmo"] = true,
	["cellphone.cmo"] = true,
	["desktest.cmo"] = true,
	["fhair1.cmo"] = true,
	["fhair2.cmo"] = true,
	["fhair3.cmo"] = true,
	["fhair4.cmo"] = true,
	["fhair5.cmo"] = true,
	["fhair6.cmo"] = true,
	["fhair7.cmo"] = true,
	["fhair8.cmo"] = true,
	["fhair9.cmo"] = true,
	["fhead1.cmo"] = true,
	["fhead2.cmo"] = true,
	["fhead3.cmo"] = true,
	["fhead4.cmo"] = true,
	["fhead5.cmo"] = true,
	["grenade.cmo"] = true,
	["heli.cmo"] = true,
	["lamptest.cmo"] = true,
	["m16.cmo"] = true,
	["m16_magazine.cmo"] = true,
	["mhair1.cmo"] = true,
	["mhair2.cmo"] = true,
	["mhair3.cmo"] = true,
	["mhair4.cmo"] = true,
	["mhair5.cmo"] = true,
	["mhair6.cmo"] = true,
	["mhair7.cmo"] = true,
	["mhair8.cmo"] = true,
	["mhair9.cmo"] = true,
	["mhead1.cmo"] = true,
	["mhead2.cmo"] = true,
	["mhead3.cmo"] = true,
	["mhead4.cmo"] = true,
	["mhead5.cmo"] = true,
	["mp5.cmo"] = true,
	["mp5_magazine.cmo"] = true,
	["soccerball.cmo"] = true,
	["walkietalkie.cmo"] = true,
}

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

local function isDefaultGameMapName(levelName)
	local normalized = toLower(levelName or "")
	return normalized == "round" or normalized == "test2"
end

local function shouldSkipBundledModelCmo(syncPath)
	if type(syncPath) ~= "string" then
		return false
	end

	if syncPath:sub(1, 11) ~= "data/model/" then
		return false
	end

	local modelRelative = syncPath:sub(12)
	if modelRelative:find("/", 1, true) then
		return false
	end

	local fileName = syncPath:match("([^/]+)$")
	if type(fileName) ~= "string" or fileName == "" then
		return false
	end

	fileName = toLower(fileName)
	if fileExtension(fileName) ~= ".cmo" then
		return false
	end

	return DEFAULT_GAME_MODEL_CMO_FILES[fileName] == true
end

local function isProtectedTextureFile(syncPath)
	if type(syncPath) ~= "string" then
		return false
	end

	return PROTECTED_TEXTURE_FILES[toLower(syncPath)] == true
end

local function hasSafeExtension(path)
	local ext = fileExtension(path)
	return ext == ".lua" or ext == ".yml" or ext == ".yaml" or ext == ".json"
end

local function hasSafeAssetExtension(path)
	local ext = fileExtension(path)
	return ext == ".csx" or ext == ".sbc" or ext == ".sbl" or ext == ".cmo" or ext == ".png" or ext == ".wav"
end

function M.isSafeSyncPath(path)
	if type(path) ~= "string" then
		return false
	end

	if #path == 0 then
		return false
	end

	if not hasSafeExtension(path) then
		return false
	end

	if path:find("\\", 1, true) then
		return false
	end

	if path:sub(1, 1) == "/" then
		return false
	end

	if path:find("..", 1, true) then
		return false
	end

	return true
end

function M.isLuaPath(path)
	return type(path) == "string" and path:sub(-4):lower() == ".lua"
end

function M.isSafeAssetSyncPath(path)
	if type(path) ~= "string" then
		return false
	end

	if #path == 0 then
		return false
	end

	if not hasSafeAssetExtension(path) then
		return false
	end

	if path:find("\\", 1, true) then
		return false
	end

	if path:sub(1, 1) == "/" then
		return false
	end

	if path:find("..", 1, true) then
		return false
	end

	local lowerPath = toLower(path)
	if isProtectedTextureFile(lowerPath) then
		return false
	end

	return true
end

function M.eventPayloadSize(payload)
	local ok, encoded = pcall(json.encode, payload)
	if not ok then
		return math.huge
	end
	return #encoded
end

local function collectScriptsRecursive(state, root, relativePath)
	relativePath = relativePath or ""

	local current = root
	if relativePath ~= "" then
		current = M.joinPath(root, relativePath)
	end

	local ok, entries = pcall(os.listDirectory, current)
	if not ok or type(entries) ~= "table" then
		return
	end

	for _, entry in ipairs(entries) do
		if entry.isDirectory then
			if relativePath == "" and (entry.name == "assets" or entry.name == "scripts") then
				goto continue
			end

			local child = entry.name
			if relativePath ~= "" then
				child = relativePath .. "/" .. entry.name
			end
			collectScriptsRecursive(state, root, child)
		else
			local relPath = entry.name
			if relativePath ~= "" then
				relPath = relativePath .. "/" .. entry.name
			end

			if M.isSafeSyncPath(relPath) then
				local fullPath = M.joinPath(root, relPath)
				local bytes = M.readFile(fullPath)
				if bytes then
					local record = {
						path = relPath,
						size = #bytes,
						sha256 = crypto.sha256(bytes),
						mtime = os.getLastWriteTime(fullPath),
					}
					table.insert(state.scripts, record)
					state.scriptsByPath[relPath] = record
				end
			end
		end

		::continue::
	end
end

function M.discoverScripts(state)
	pcall(os.createDirectory, state.config.clientRoot)
	local root = M.scriptsRoot(state.config)
	pcall(os.createDirectory, root)

	state.scripts = {}
	state.scriptsByPath = {}

	collectScriptsRecursive(state, root, "")
	if #state.scripts == 0 then
		collectScriptsRecursive(state, state.config.clientRoot, "")
	end

	table.sort(state.scripts, function(a, b)
		return a.path < b.path
	end)

	return state.scripts
end

function M.normalizeLoadedLevel(rawLevel)
	if type(rawLevel) ~= "string" then
		return ""
	end

	local level = rawLevel:gsub("\\", "/")
	level = level:gsub("^%s+", "")
	level = level:gsub("%s+$", "")
	level = level:gsub("^data/", "")
	level = level:gsub("^/+", "")
	level = level:gsub("/+$", "")

	if level == "" then
		return ""
	end

	if level:find("..", 1, true) then
		return ""
	end

	return level
end

function M.normalizePersistentMode(rawMode)
	if type(rawMode) ~= "string" then
		return ""
	end

	local mode = rawMode:gsub("\\", "/")
	mode = mode:gsub("^%s+", "")
	mode = mode:gsub("%s+$", "")
	mode = mode:gsub("^/+", "")
	mode = mode:gsub("/+$", "")

	if mode == "" then
		return ""
	end

	if mode:find("..", 1, true) then
		return ""
	end

	local leaf = mode:match("([^/]+)$")
	if leaf and leaf ~= "" then
		mode = leaf
	end

	mode = mode:gsub("%.lua$", "")
	mode = mode:gsub("^%s+", "")
	mode = mode:gsub("%s+$", "")
	return mode
end

function M.discoverPersistentMode(state)
	local rawMode = nil
	if type(hook) == "table" then
		rawMode = hook.persistentMode
	end

	state.persistentMode = M.normalizePersistentMode(rawMode)
	return state.persistentMode
end

local function collectAssetFilesRecursive(state, root, syncRootPrefix, relativePath)
	relativePath = relativePath or ""

	local current = root
	if relativePath ~= "" then
		current = M.joinPath(root, relativePath)
	end

	local ok, entries = pcall(os.listDirectory, current)
	if not ok or type(entries) ~= "table" then
		return
	end

	for _, entry in ipairs(entries) do
		if entry.isDirectory then
			local child = entry.name
			if relativePath ~= "" then
				child = relativePath .. "/" .. entry.name
			end
			collectAssetFilesRecursive(state, root, syncRootPrefix, child)
		else
			local relPath = entry.name
			if relativePath ~= "" then
				relPath = relativePath .. "/" .. entry.name
			end

			local fullPath = M.joinPath(root, relPath)
			local syncPath = relPath
			if syncRootPrefix ~= "" then
				syncPath = M.joinPath(syncRootPrefix, relPath)
			end
			if M.isSafeAssetSyncPath(syncPath) then
				local shouldSkip = shouldSkipBundledModelCmo(syncPath)
				if not shouldSkip then
					local bytes = M.readFile(fullPath)
					if bytes then
						local record = {
							path = syncPath,
							size = #bytes,
							sha256 = crypto.sha256(bytes),
							mtime = os.getLastWriteTime(fullPath),
						}
						if not state.assetFilesByPath[syncPath] then
							table.insert(state.assetFiles, record)
							state.assetFilesByPath[syncPath] = record
						end
					end
				end
			end
		end
	end
end

function M.discoverAssetFiles(state)
	state.assetFiles = {}
	state.assetFilesByPath = {}

	local normalizedLevel = M.normalizeLoadedLevel(server and server.loadedLevel or nil)
	state.loadedLevel = normalizedLevel

	if normalizedLevel ~= "" and not isDefaultGameMapName(normalizedLevel) then
		local levelSyncRoot = "data/" .. normalizedLevel
		collectAssetFilesRecursive(state, levelSyncRoot, levelSyncRoot, "")
	end

	pcall(os.createDirectory, state.config.clientRoot)
	local root = M.assetsRoot(state.config)
	pcall(os.createDirectory, root)
	collectAssetFilesRecursive(state, root, "", "")

	table.sort(state.assetFiles, function(a, b)
		return a.path < b.path
	end)

	return state.assetFiles
end

function M.discoverSyncFiles(state)
	M.discoverPersistentMode(state)
	M.discoverScripts(state)
	M.discoverAssetFiles(state)
end

return M
