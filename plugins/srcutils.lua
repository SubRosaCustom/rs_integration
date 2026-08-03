---@type Plugin
local plugin = ...
plugin.name = "SRC Utils"
plugin.author = "Sub Rosa Custom"
plugin.description = "Utility commands and optional auto-refresh support for SRC."

require("main.src.init")

local json = require("main.json")
local runtime_state = require("main.src.runtime_state")
local sync_paths = require("main.src.sync_paths")
local watcher = require("main.src.watcher")

local src = assert(_G.src, "SRC utils requires main.src.init to initialize first")
local state = runtime_state.get()
local disabled_plugins_file = "disabledPlugins.json"
local message_player = messagePlayerWrap

local function refresh_now()
	src.refreshSyncFiles()
end

local function scripts_root()
	return sync_paths.scripts_root(state.config)
end

local function disabled_plugins_path()
	return sync_paths.join(scripts_root(), disabled_plugins_file)
end

local function read_disabled_plugins()
	local source = sync_paths.read_file(disabled_plugins_path())
	if not source or source == "" then
		return {}
	end

	local ok, decoded = pcall(json.decode, source)
	if not ok or type(decoded) ~= "table" then
		error(string.format("Invalid %s", disabled_plugins_file))
	end

	local names = {}
	for i = 1, #decoded do
		local name = decoded[i]
		if type(name) == "string" and name ~= "" then
			names[name] = true
		end
	end

	return names
end

local function write_disabled_plugins(names)
	local scripts_root_path = scripts_root()
	pcall(os.createDirectory, state.config.clientRoot)
	pcall(os.createDirectory, scripts_root_path)

	local sorted = {}
	for name, is_disabled in pairs(names) do
		if is_disabled then
			sorted[#sorted + 1] = name
		end
	end
	table.sort(sorted)

	local path = disabled_plugins_path()
	if #sorted == 0 then
		os.remove(path)
		return
	end

	local file = assert(io.open(path, "wb"), string.format("Failed to open %s", path))
	file:write(json.encode(sorted))
	file:close()
end

local function collect_client_plugin_names()
	local plugins_root = sync_paths.join(scripts_root(), "plugins")
	local ok, entries = pcall(os.listDirectory, plugins_root)
	if not ok or type(entries) ~= "table" then
		return {}
	end

	local names = {}
	for _, entry in ipairs(entries) do
		if entry.isDirectory then
			local init_path = sync_paths.join(sync_paths.join(plugins_root, entry.name), "init.lua")
			if sync_paths.read_file(init_path) then
				names[entry.name] = true
			end
		else
			local stem = entry.name:match("^(.+)%.lua$")
			if stem and stem ~= "init" then
				names[stem] = true
			end
		end
	end

	local sorted = {}
	for name, _ in pairs(names) do
		sorted[#sorted + 1] = name
	end
	table.sort(sorted)
	return sorted
end

local function has_client_plugin(name)
	local names = collect_client_plugin_names()
	for i = 1, #names do
		if names[i] == name then
			return true
		end
	end
	return false
end

local function auto_complete_client_plugin_arg(args)
	if #args < 1 then
		return
	end

	local beginning = string.lower(args[1])
	local names = collect_client_plugin_names()
	for i = 1, #names do
		local name = names[i]
		if string.lower(name):sub(1, #beginning) == beginning then
			args[1] = name
			return
		end
	end
end

local function count_clients()
	local total = 0
	local hello = 0
	local bound = 0

	for connection, client in pairs(state.clients) do
		if connection and connection.is_open and client then
			total = total + 1
			if client.hello then
				hello = hello + 1
			end
			if client.bound then
				bound = bound + 1
			end
		end
	end

	return total, hello, bound
end

local function count_queued_bytes(queue)
	local total = 0
	for i = 1, #queue do
		total = total + #(queue[i] or "")
	end
	return total
end

plugin.commands["/srcrefresh"] = {
	info = "Refresh Sub Rosa Custom client scripts for all connected SRC clients.",
	canCall = function(ply)
		return ply.isConsole or ply.isAdmin
	end,
	call = function(ply)
		assert(src.enabled, "SRC is disabled")
		refresh_now()
		local message = "SRC refresh queued for all connected clients"
		message_player(ply, message)
	end,
}

plugin.commands["/srcstatus"] = {
	info = "Show current SRC runtime status.",
	canCall = function(ply)
		return ply.isConsole or ply.isAdmin
	end,
	call = function(ply)
		local total_clients, hello_clients, bound_clients = count_clients()
		message_player(
			ply,
			string.format(
				"SRC enabled=%s runtimeActive=%s port=%s scripts=%d assets=%d clients=%d hello=%d bound=%d watch=%s",
				tostring(src.enabled == true),
				tostring(state.runtime_active == true),
				tostring(state.bound_port or "unbound"),
				#state.scripts,
				#state.asset_files,
				total_clients,
				hello_clients,
				bound_clients,
				tostring(state.config.autoRefreshEnabled == true)
			)
		)
		message_player(
			ply,
			string.format(
				"SRC runtimeID=%s syncGeneration=%s loadedLevel=%s persistentMode=%s",
				tostring(state.runtime_id),
				tostring(state.sync_generation),
				state.loaded_level ~= "" and state.loaded_level or "<none>",
				state.persistent_mode ~= "" and state.persistent_mode or "<none>"
			)
		)
	end,
}

plugin.commands["/srcclients"] = {
	info = "List connected SRC TCP clients and their bind state.",
	canCall = function(ply)
		return ply.isConsole or ply.isAdmin
	end,
	call = function(ply)
		local rows = {}
		local ordinal = 0

		for connection, client in pairs(state.clients) do
			if connection and connection.is_open and client then
				ordinal = ordinal + 1
				rows[#rows + 1] = {
					id = ordinal,
					player = client.player and client.player.name or "<unbound>",
					hello = client.hello == true and "yes" or "no",
					bound = client.bound == true and "yes" or "no",
					generation = tostring(client.generation or 0),
					send_frames = #client.send_queue,
					pending_files = #client.pending_file_requests,
					pending_events = table.numElements(client.pending_events or {}),
				}
			end
		end

		table.sort(rows, function(a, b)
			return a.id < b.id
		end)

		if #rows == 0 then
			message_player(ply, "No SRC TCP clients connected")
			return
		end

		for i = 1, #rows do
			local row = rows[i]
			message_player(
				ply,
				string.format(
					"client#%d player=%s hello=%s bound=%s gen=%s sendFrames=%d pendingFiles=%d pendingEvents=%d",
					row.id,
					row.player,
					row.hello,
					row.bound,
					row.generation,
					row.send_frames,
					row.pending_files,
					row.pending_events
				)
			)
		end
	end,
}

plugin.commands["/srcwatch"] = {
	info = "Toggle SRC auto-refresh watching for this server process.",
	alias = { "srcwatch" },
	canCall = function(ply)
		return ply.isConsole
	end,
	call = function(ply)
		state.config.autoRefreshEnabled = not (state.config.autoRefreshEnabled == true)
		if not state.config.autoRefreshEnabled then
			watcher.clear(state)
		end

		message_player(
			ply,
			string.format(
				"%s watching SRC client root %s",
				state.config.autoRefreshEnabled and "Now" or "No longer",
				tostring(state.config.clientRoot)
			)
		)
	end,
}

plugin.commands["/srcenableplugin"] = {
	info = "Enable a synced client plugin for all SRC clients.",
	usage = "<plugin>",
	autoComplete = auto_complete_client_plugin_arg,
	canCall = function(ply)
		return ply.isConsole or ply.isAdmin
	end,
	call = function(ply, _, args)
		assert(src.enabled, "SRC is disabled")
		assert(#args >= 1, "usage")

		local plugin_name = args[1]
		assert(has_client_plugin(plugin_name), "Invalid client plugin")

		local disabled = read_disabled_plugins()
		assert(disabled[plugin_name], "Plugin already enabled")

		disabled[plugin_name] = nil
		write_disabled_plugins(disabled)
		refresh_now()
		message_player(ply, string.format("Enabled SRC client plugin %s", plugin_name))
	end,
}

plugin.commands["/srcdisableplugin"] = {
	info = "Disable a synced client plugin for all SRC clients.",
	usage = "<plugin>",
	autoComplete = auto_complete_client_plugin_arg,
	canCall = function(ply)
		return ply.isConsole or ply.isAdmin
	end,
	call = function(ply, _, args)
		assert(src.enabled, "SRC is disabled")
		assert(#args >= 1, "usage")

		local plugin_name = args[1]
		assert(has_client_plugin(plugin_name), "Invalid client plugin")

		local disabled = read_disabled_plugins()
		assert(not disabled[plugin_name], "Plugin already disabled")

		disabled[plugin_name] = true
		write_disabled_plugins(disabled)
		refresh_now()
		message_player(ply, string.format("Disabled SRC client plugin %s", plugin_name))
	end,
}

plugin.commands["/srcdumpstate"] = {
	info = "Dump a compact SRC internal state snapshot.",
	canCall = function(ply)
		return ply.isConsole or ply.isAdmin
	end,
	call = function(ply)
		local total_clients, hello_clients, bound_clients = count_clients()
		local total_send_frames = 0
		local total_send_bytes = 0
		local total_pending_files = 0
		local total_pending_events = 0
		local total_awaiting_results = 0

		for connection, client in pairs(state.clients) do
			if connection and connection.is_open and client then
				total_send_frames = total_send_frames + #client.send_queue
				total_send_bytes = total_send_bytes + count_queued_bytes(client.send_queue)
				total_pending_files = total_pending_files + #client.pending_file_requests
				total_pending_events = total_pending_events + table.numElements(client.pending_events or {})
				total_awaiting_results = total_awaiting_results + table.numElements(client.awaiting_results or {})
			end
		end

		message_player(
			ply,
			string.format(
				"runtimeID=%s enabled=%s runtimeActive=%s tick=%s syncGeneration=%s boundPort=%s",
				tostring(state.runtime_id),
				tostring(src.enabled == true),
				tostring(state.runtime_active == true),
				tostring(state.tick),
				tostring(state.sync_generation),
				tostring(state.bound_port or "unbound")
			)
		)
		message_player(
			ply,
			string.format(
				"scripts=%d assets=%d loadedLevel=%s persistentMode=%s nextEventID=%s",
				#state.scripts,
				#state.asset_files,
				state.loaded_level ~= "" and state.loaded_level or "<none>",
				state.persistent_mode ~= "" and state.persistent_mode or "<none>",
				tostring(state.next_event_id)
			)
		)
		message_player(
			ply,
			string.format(
				"watchEnabled=%s watchRoot=%s watchedDirs=%d pendingRefreshTick=%s",
				tostring(state.config.autoRefreshEnabled == true),
				tostring(state.watched_root or "<none>"),
				table.numElements(state.watched_directories or {}),
				tostring(state.pending_refresh_tick or "<none>")
			)
		)
		message_player(
			ply,
			string.format(
				"clients=%d hello=%d bound=%d sendFrames=%d sendBytes=%d pendingFiles=%d pendingEvents=%d awaitingResults=%d",
				total_clients,
				hello_clients,
				bound_clients,
				total_send_frames,
				total_send_bytes,
				total_pending_files,
				total_pending_events,
				total_awaiting_results
			)
		)
	end,
}

plugin.commands["/srckicknonsrc"] = {
	info = "Remove currently connected non-bot players without a bound SRC client.",
	canCall = function(ply)
		return ply.isConsole or ply.isAdmin
	end,
	call = function(ply)
		local kicked = 0

		for _, player in ipairs(players.getNonBots()) do
			local client_state = src.getClientState(player)
			if player.connection and not client_state.connected then
				player:sendMessage("SRC is required on this server")
				player.connection.timeoutTime = 50 * server.TPS
				kicked = kicked + 1
			end
		end

		message_player(ply, string.format("Kicked %d non-SRC player(s)", kicked))
	end,
}

plugin:addHook("Logic", function()
	if not src.enabled then
		watcher.clear(state)
		return
	end

	watcher.ensure(state)
	watcher.process(state, function()
		refresh_now()
		plugin:print("auto-refresh queued")
	end)
end)

plugin:addDisableHandler(function()
	watcher.clear(state)
end)
