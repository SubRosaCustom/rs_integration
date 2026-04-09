local log = require("main.src.log")
local shared = require("main.src.shared")

local M = {}

function M.clear(state)
	state.fileWatcher = nil
	state.watchedDirectories = {}
	state.watchedRoot = nil
	state.pendingRefreshTick = nil
end

local function watchDirectoryRecursive(state, root, rel)
	rel = rel or ""

	local dir = root
	if rel ~= "" then
		dir = shared.joinPath(root, rel)
	end

	if not state.watchedDirectories[dir] then
		state.fileWatcher:addWatch(dir, FILE_WATCH_MODIFY)
		state.watchedDirectories[dir] = true
	end

	local ok, entries = pcall(os.listDirectory, dir)
	if not ok or type(entries) ~= "table" then
		return
	end

	for _, entry in ipairs(entries) do
		if entry.isDirectory then
			local child = entry.name
			if rel ~= "" then
				child = rel .. "/" .. entry.name
			end
			watchDirectoryRecursive(state, root, child)
		end
	end
end

function M.ensure(state)
	if state.config.autoRefreshEnabled ~= true then
		if state.fileWatcher then
			M.clear(state)
			log.info("auto-refresh watcher disabled")
		end
		return
	end

	local root = state.config.clientRoot
	if state.fileWatcher and state.watchedRoot == root then
		return
	end

	M.clear(state)
	state.fileWatcher = FileWatcher.new()
	state.watchedDirectories = {}
	state.watchedRoot = root
	pcall(os.createDirectory, root)
	watchDirectoryRecursive(state, root, "")
	log.info("auto-refresh watcher enabled")
end

function M.process(state, onRefresh)
	if not state.fileWatcher then
		return
	end

	local changed = false
	while true do
		local ev = state.fileWatcher:receiveEvent()
		if not ev then
			break
		end

		if type(ev.name) == "string" and shared.isLuaPath(ev.name) then
			changed = true
		elseif type(ev.descriptor) == "string" and shared.isLuaPath(ev.descriptor) then
			changed = true
		end
	end

	if changed then
		state.pendingRefreshTick = state.tick + state.config.autoRefreshDebounceTicks
	end

	if state.pendingRefreshTick and state.tick >= state.pendingRefreshTick then
		state.pendingRefreshTick = nil
		if onRefresh then
			onRefresh()
		end
	end
end

return M
