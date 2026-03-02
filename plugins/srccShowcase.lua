---@type Plugin
local plugin = ...
plugin.name = "SRCC Showcase Server"
plugin.author = "Sub Rosa Custom"
plugin.description = "Server counterpart for SRCC showcase client plugin."

require("main.src.init")

local src = _G.src
assert(src, "SRCC showcase requires server/main/src/init.lua to be loaded first")

plugin.defaultConfig = {
	noticeEveryTicks = 1800, -- ~30s at 60 TPS
	autoBroadcastNotices = true,
}

local tickCounter = 0

local globalState = _G.__srccShowcaseServerState or {
	initialized = false,
	activePlugin = nil,
}
_G.__srccShowcaseServerState = globalState
globalState.activePlugin = plugin

local function active()
	local p = globalState.activePlugin
	return p and p.isEnabled and p or nil
end

local function emitTo(connection, eventName, payload, bin)
	local p = active()
	if not p then
		return false
	end
	return src.emitClientEvent(connection.player, eventName, payload, bin)
end

local function emitAll(eventName, payload, bin)
	local p = active()
	if not p then
		return 0
	end
	return src.emitClientEvent(nil, eventName, payload, bin)
end

if not globalState.initialized then
	globalState.initialized = true

	plugin:addHook("SRC_InitItemType", function()
		local customIdx = itemTypes.clone(35, { name = "Custom Ball" })
		src.setItemTypeModel(customIdx, "custom_ball")
		src.setItemTypeIcon(customIdx, "texture/icon-custom-ball.png")
	end)

	src.onClientEvent("srcc.showcase.hello", function(connection, data)
		local p = active()
		if not p then
			return
		end

		p:print("Client hello from " .. tostring(connection.address) .. ":" .. tostring(connection.port))
		emitTo(connection, "srcc.showcase.welcome", {
			message = "server acknowledged hello",
			serverTick = tickCounter,
			echo = data,
		})
	end)

	src.onClientEvent("srcc.showcase.ping", function(connection, data)
		local p = active()
		if not p then
			return
		end

		emitTo(connection, "srcc.showcase.pong", {
			serverTick = tickCounter,
			reason = data and data.reason or "unknown",
			echo = data,
		})
	end)

	src.onClientEvent("srcc.showcase.request_state", function(connection, data)
		local p = active()
		if not p then
			return
		end

		local sent = emitAll("srcc.showcase.notice", {
			text = "A client requested SRCC state (" .. tostring(connection.address) .. ")",
			serverTick = tickCounter,
		})

		emitTo(connection, "srcc.showcase.state", {
			serverTick = tickCounter,
			connectedClients = sent,
			requestEcho = data,
		})
	end)

	src.onClientEvent("srcc.example.ping", function(connection, data)
		local p = active()
		if not p then
			return
		end

		emitTo(connection, "srcc.example.echo", {
			message = "server acknowledged srcc.example.ping",
			serverTick = tickCounter,
			echo = data,
		})
	end)
end

plugin.commands["/srcshowcase"] = {
	info = "Send an SRCC showcase notice to all connected SRC clients.",
	usage = "<message>",
	canCall = function(ply)
		return ply.isConsole or ply.isAdmin
	end,
	call = function(ply, _, args)
		if #args == 0 then
			error("usage")
		end

		local message = table.concat(args, " ")
		local sent = emitAll("srcc.showcase.notice", {
			text = message,
			serverTick = tickCounter,
		})

		local output = "SRCC showcase notice sent to " .. tostring(sent) .. " client(s)"
		if ply.sendMessage then
			ply:sendMessage(output)
		else
			plugin:print(output)
		end
	end,
}

plugin:addEnableHandler(function()
	tickCounter = 0
	plugin:print("SRCC showcase server enabled")
end)

plugin:addDisableHandler(function()
	if globalState.activePlugin == plugin then
		globalState.activePlugin = nil
	end
end)

local oldLevelToLoad
local oldloadedLevel
local oldIsLevelLoaded

plugin:addHook("Logic", function()
	tickCounter = tickCounter + 1
	
	if oldLevelToLoad ~= server.levelToLoad then
		emitAll("srcc.showcase.notice", {
			text = "server.levelToLoad = " .. tostring(server.levelToLoad),
			serverTick = tickCounter,
		})
	end
	if oldloadedLevel ~= server.loadedLevel then
		emitAll("srcc.showcase.notice", {
			text = "server.loadedLevel = " .. tostring(server.loadedLevel),
			serverTick = tickCounter,
		})
	end
	if oldIsLevelLoaded ~= server.isLevelLoaded then
		emitAll("srcc.showcase.notice", {
			text = "server.isLevelLoaded = " .. tostring(server.isLevelLoaded),
			serverTick = tickCounter,
		})
	end

	oldLevelToLoad = server.levelToLoad
	oldloadedLevel = server.loadedLevel
	oldIsLevelLoaded = server.isLevelLoaded

	if plugin.config.autoBroadcastNotices and tickCounter % plugin.config.noticeEveryTicks == 0 then
		emitAll("srcc.showcase.notice", {
			text = "Periodic server notice tick=" .. tostring(tickCounter),
			serverTick = tickCounter,
		})
	end
end)
