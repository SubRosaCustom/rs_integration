---@type Plugin
local plugin = ...
plugin.name = "SRC Utils"
plugin.author = "Sub Rosa Custom"
plugin.description = "Utility commands and optional auto-refresh support for SRC."

require("main.src.init")

local watcher = require("main.src.watcher")
local shared = require("main.src.shared")

local src = assert(_G.src, "SRC utils requires main.src.init to initialize first")
local state = shared.getState()

local function refresh_now()
	src.refreshSyncFiles()
end

local function count_clients()
	local total = 0
	local hello = 0
	local bound = 0

	for connection, client in pairs(state.clients) do
		if connection and connection.isOpen and client then
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
		messagePlayerWrap(ply, message)
	end,
}

plugin.commands["/srcstatus"] = {
	info = "Show current SRC runtime status.",
	canCall = function(ply)
		return ply.isConsole or ply.isAdmin
	end,
	call = function(ply)
		local totalClients, helloClients, boundClients = count_clients()
		messagePlayerWrap(
			ply,
			string.format(
				"SRC enabled=%s runtimeActive=%s port=%s scripts=%d assets=%d clients=%d hello=%d bound=%d watch=%s",
				tostring(src.enabled == true),
				tostring(state.runtimeActive == true),
				tostring(state.boundPort or "unbound"),
				#state.scripts,
				#state.assetFiles,
				totalClients,
				helloClients,
				boundClients,
				tostring(state.config.autoRefreshEnabled == true)
			)
		)
		messagePlayerWrap(
			ply,
			string.format(
				"SRC runtimeID=%s syncGeneration=%s loadedLevel=%s persistentMode=%s",
				tostring(state.runtimeID),
				tostring(state.syncGeneration),
				state.loadedLevel ~= "" and state.loadedLevel or "<none>",
				state.persistentMode ~= "" and state.persistentMode or "<none>"
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
			if connection and connection.isOpen and client then
				ordinal = ordinal + 1
				rows[#rows + 1] = {
					id = ordinal,
					player = client.player and client.player.name or "<unbound>",
					hello = client.hello == true and "yes" or "no",
					bound = client.bound == true and "yes" or "no",
					generation = tostring(client.generation or 0),
					sendFrames = #client.sendQueue,
					pendingFiles = #client.pendingFileRequests,
					pendingEvents = table.numElements(client.pendingEvents or {}),
				}
			end
		end

		table.sort(rows, function(a, b)
			return a.id < b.id
		end)

		if #rows == 0 then
			messagePlayerWrap(ply, "No SRC TCP clients connected")
			return
		end

		for i = 1, #rows do
			local row = rows[i]
			messagePlayerWrap(
				ply,
				string.format(
					"client#%d player=%s hello=%s bound=%s gen=%s sendFrames=%d pendingFiles=%d pendingEvents=%d",
					row.id,
					row.player,
					row.hello,
					row.bound,
					row.generation,
					row.sendFrames,
					row.pendingFiles,
					row.pendingEvents
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

		messagePlayerWrap(
			ply,
			string.format(
				"%s watching SRC client root %s",
				state.config.autoRefreshEnabled and "Now" or "No longer",
				tostring(state.config.clientRoot)
			)
		)
	end,
}

plugin.commands["/srcdumpstate"] = {
	info = "Dump a compact SRC internal state snapshot.",
	canCall = function(ply)
		return ply.isConsole or ply.isAdmin
	end,
	call = function(ply)
		local totalClients, helloClients, boundClients = count_clients()
		local totalSendFrames = 0
		local totalSendBytes = 0
		local totalPendingFiles = 0
		local totalPendingEvents = 0
		local totalAwaitingResults = 0

		for connection, client in pairs(state.clients) do
			if connection and connection.isOpen and client then
				totalSendFrames = totalSendFrames + #client.sendQueue
				totalSendBytes = totalSendBytes + count_queued_bytes(client.sendQueue)
				totalPendingFiles = totalPendingFiles + #client.pendingFileRequests
				totalPendingEvents = totalPendingEvents + table.numElements(client.pendingEvents or {})
				totalAwaitingResults = totalAwaitingResults + table.numElements(client.awaitingResults or {})
			end
		end

		messagePlayerWrap(
			ply,
			string.format(
				"runtimeID=%s enabled=%s runtimeActive=%s tick=%s syncGeneration=%s boundPort=%s",
				tostring(state.runtimeID),
				tostring(src.enabled == true),
				tostring(state.runtimeActive == true),
				tostring(state.tick),
				tostring(state.syncGeneration),
				tostring(state.boundPort or "unbound")
			)
		)
		messagePlayerWrap(
			ply,
			string.format(
				"scripts=%d assets=%d loadedLevel=%s persistentMode=%s nextEventID=%s",
				#state.scripts,
				#state.assetFiles,
				state.loadedLevel ~= "" and state.loadedLevel or "<none>",
				state.persistentMode ~= "" and state.persistentMode or "<none>",
				tostring(state.nextEventID)
			)
		)
		messagePlayerWrap(
			ply,
			string.format(
				"watchEnabled=%s watchRoot=%s watchedDirs=%d pendingRefreshTick=%s",
				tostring(state.config.autoRefreshEnabled == true),
				tostring(state.watchedRoot or "<none>"),
				table.numElements(state.watchedDirectories or {}),
				tostring(state.pendingRefreshTick or "<none>")
			)
		)
		messagePlayerWrap(
			ply,
			string.format(
				"clients=%d hello=%d bound=%d sendFrames=%d sendBytes=%d pendingFiles=%d pendingEvents=%d awaitingResults=%d",
				totalClients,
				helloClients,
				boundClients,
				totalSendFrames,
				totalSendBytes,
				totalPendingFiles,
				totalPendingEvents,
				totalAwaitingResults
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
			local clientState = src.getClientState(player)
			if player.connection and not clientState.connected then
				player:sendMessage("SRC is required on this server")
				player.connection.timeoutTime = 50 * server.TPS
				kicked = kicked + 1
			end
		end

		messagePlayerWrap(ply, string.format("Kicked %d non-SRC player(s)", kicked))
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
