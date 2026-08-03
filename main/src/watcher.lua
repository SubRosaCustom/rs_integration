local log = require("main.src.log")
local sync_paths = require("main.src.sync_paths")

local M = {}

function M.clear(state)
	state.file_watcher = nil
	state.watched_directories = {}
	state.watched_root = nil
	state.pending_refresh_tick = nil
end

local function watch_directory_recursive(state, root, rel)
	rel = rel or ""

	local dir = root
	if rel ~= "" then
		dir = sync_paths.join(root, rel)
	end

	if not state.watched_directories[dir] then
		state.file_watcher:addWatch(dir, FILE_WATCH_MODIFY)
		state.watched_directories[dir] = true
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
			watch_directory_recursive(state, root, child)
		end
	end
end

function M.ensure(state)
	if state.config.autoRefreshEnabled ~= true then
		if state.file_watcher then
			M.clear(state)
			log.info("auto-refresh watcher disabled")
		end
		return
	end

	local root = state.config.clientRoot
	if state.file_watcher and state.watched_root == root then
		return
	end

	M.clear(state)
	state.file_watcher = FileWatcher.new()
	state.watched_directories = {}
	state.watched_root = root
	pcall(os.createDirectory, root)
	watch_directory_recursive(state, root, "")
	log.info("auto-refresh watcher enabled")
end

function M.process(state, on_refresh)
	if not state.file_watcher then
		return
	end

	local changed = false
	while true do
		local ev = state.file_watcher:receiveEvent()
		if not ev then
			break
		end

		if type(ev.name) == "string" and sync_paths.is_lua(ev.name) then
			changed = true
		elseif type(ev.descriptor) == "string" and sync_paths.is_lua(ev.descriptor) then
			changed = true
		end
	end

	if changed then
		state.pending_refresh_tick = state.tick + state.config.autoRefreshDebounceTicks
	end

	if state.pending_refresh_tick and state.tick >= state.pending_refresh_tick then
		state.pending_refresh_tick = nil
		if on_refresh then
			on_refresh()
		end
	end
end

return M
