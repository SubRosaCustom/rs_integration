local log = require("main.src.log")
local sync_paths = require("main.src.sync_paths")

local watcher = {}
local STRUCTURE_EVENTS = bit32.bor(FILE_WATCH_CREATE, FILE_WATCH_DELETE,
	FILE_WATCH_MOVE, FILE_WATCH_DELETE_SELF, FILE_WATCH_MOVE_SELF)
local WATCH_EVENTS = bit32.bor(FILE_WATCH_MODIFY, STRUCTURE_EVENTS)
-- inotify reports tree changes; the full walk is a safety net for events receiveEvent drops
local SAFETY_RESCAN_SECONDS = 30

local function safety_rescan_ticks()
	return math.floor((tonumber(server and server.TPS) or 60) * SAFETY_RESCAN_SECONDS)
end

function watcher.clear(state)
	state.file_watcher = nil
	state.watched_directories = {}
	state.watched_root = nil
	state.pending_refresh_tick = nil
	state.next_watch_scan_tick = nil
end

local function watch_directory_recursive(state, root, rel)
	rel = rel or ""

	local dir = root
	if rel ~= "" then
		dir = sync_paths.join(root, rel)
	end

	if not state.watched_directories[dir] then
		state.file_watcher:addWatch(dir, WATCH_EVENTS)
		state.watched_directories[dir] = true
	end

	local ok, entries = pcall(os.listDirectory, dir)
	if not ok or type(entries) ~= "table" then
		return
	end

	for _, entry in ipairs(entries) do
		if entry.isDirectory and sync_paths.is_contained(root, sync_paths.join(dir, entry.name)) then
			local child = entry.name
			if rel ~= "" then
				child = rel .. "/" .. entry.name
			end
			watch_directory_recursive(state, root, child)
		end
	end
end

function watcher.ensure(state)
	if state.config.autoRefreshEnabled ~= true then
		if state.file_watcher then
			watcher.clear(state)
			log.info("auto-refresh watcher disabled")
		end
		return
	end

	local root = state.config.clientRoot
	if state.file_watcher and state.watched_root == root then
		if state.tick >= (state.next_watch_scan_tick or 0) then
			local previous_count = 0
			for _ in pairs(state.watched_directories) do previous_count = previous_count + 1 end
			watch_directory_recursive(state, root, "")
			local next_count = 0
			for _ in pairs(state.watched_directories) do next_count = next_count + 1 end
			if next_count ~= previous_count then
				state.pending_refresh_tick = state.tick + state.config.autoRefreshDebounceTicks
			end
			state.next_watch_scan_tick = state.tick + safety_rescan_ticks()
		end
		return
	end

	watcher.clear(state)
	state.file_watcher = FileWatcher.new()
	state.watched_directories = {}
	state.watched_root = root
	pcall(os.createDirectory, root)
	watch_directory_recursive(state, root, "")
	state.next_watch_scan_tick = state.tick + safety_rescan_ticks()
	log.info("auto-refresh watcher enabled")
end

function watcher.process(state, on_refresh)
	if not state.file_watcher then
		return
	end

	local changed = false
	local structure_changed = false
	while true do
		local received, ev = pcall(state.file_watcher.receiveEvent, state.file_watcher)
		if not received then
			-- receiveEvent throws on inotify queue overflow, events may be lost: rescan
			log.warn_limited(state.watcher_warn_limits, "receive", "file watcher event failure, rescanning: %s", tostring(ev))
			structure_changed = true
			changed = true
			break
		end
		if not ev then
			break
		end

		if bit32.band(ev.mask or 0, STRUCTURE_EVENTS) ~= 0 then
			structure_changed = true
			changed = true
		end
		if type(ev.name) == "string" and (sync_paths.is_safe_script(ev.name) or sync_paths.is_safe_asset(ev.name)) then
			changed = true
		elseif type(ev.descriptor) == "string" and (sync_paths.is_safe_script(ev.descriptor) or sync_paths.is_safe_asset(ev.descriptor)) then
			changed = true
		end
	end

	if structure_changed then
		-- Renamed/recreated directories need new native watches, even at the same path.
		local pending_refresh_tick = state.pending_refresh_tick
		watcher.clear(state)
		watcher.ensure(state)
		state.pending_refresh_tick = pending_refresh_tick
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

return watcher
