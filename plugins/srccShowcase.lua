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

local tick_counter = 0

local global_state = _G.__srccShowcaseServerState or {
	initialized = false,
	active_plugin = nil,
}
_G.__srccShowcaseServerState = global_state
global_state.active_plugin = plugin

local function active()
	local p = global_state.active_plugin
	return p and p.isEnabled and p or nil
end

local function emit_to(connection, event_name, ...)
	local p = active()
	if not p then
		return false
	end
	return src.emitClientEvent(connection.player, event_name, ...)
end

local function emit_all(event_name, ...)
	local p = active()
	if not p then
		return 0
	end
	return src.emitClientEvent(nil, event_name, ...)
end

if not global_state.initialized then
	global_state.initialized = true

	plugin:addHook("SRC_InitItemType", function()
		local custom_index = itemTypes.clone(35, { name = "Custom Ball" })
		src.setItemTypeModel(custom_index, "custom_ball")
		src.setItemTypeIcon(custom_index, "texture/icon-custom-ball.png")
	end)

	src.onClientEvent("srcc.showcase.hello", function(connection, client_address, client_port)
		local p = active()
		if not p then
			return
		end

		p:print("Client hello from " .. tostring(connection.address) .. ":" .. tostring(connection.port))
		emit_to(connection, "srcc.showcase.welcome", "server acknowledged hello", tick_counter, client_address, client_port)
	end)

	src.onClientEvent("srcc.showcase.ping", function(connection, reason, local_tick)
		local p = active()
		if not p then
			return
		end

		emit_to(connection, "srcc.showcase.pong", tick_counter, reason or "unknown", local_tick or 0)
	end)

	src.onClientEvent("srcc.showcase.request_state", function(connection, requested_at_tick)
		local p = active()
		if not p then
			return
		end

		local sent = emit_all("srcc.showcase.notice", "A client requested SRCC state (" .. tostring(connection.address) .. ")", tick_counter)

		emit_to(connection, "srcc.showcase.state", tick_counter, sent, requested_at_tick or 0)
	end)

	src.onClientEvent("srcc.example.ping", function(connection, message, local_tick)
		local p = active()
		if not p then
			return
		end

		emit_to(connection, "srcc.example.echo", "server acknowledged srcc.example.ping", tick_counter, message, local_tick or 0)
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
		local sent = emit_all("srcc.showcase.notice", message, tick_counter)

		local output = "SRCC showcase notice sent to " .. tostring(sent) .. " client(s)"
		if ply.sendMessage then
			ply:sendMessage(output)
		else
			plugin:print(output)
		end
	end,
}

plugin:addEnableHandler(function()
	tick_counter = 0
	plugin:print("SRCC showcase server enabled")
end)

plugin:addDisableHandler(function()
	if global_state.active_plugin == plugin then
		global_state.active_plugin = nil
	end
end)

local old_level_to_load
local old_loaded_level
local old_is_level_loaded

plugin:addHook("Logic", function()
	tick_counter = tick_counter + 1

	if old_level_to_load ~= server.levelToLoad then
		emit_all("srcc.showcase.notice", "server.levelToLoad = " .. tostring(server.levelToLoad), tick_counter)
	end
	if old_loaded_level ~= server.loadedLevel then
		emit_all("srcc.showcase.notice", "server.loadedLevel = " .. tostring(server.loadedLevel), tick_counter)
	end
	if old_is_level_loaded ~= server.isLevelLoaded then
		emit_all("srcc.showcase.notice", "server.isLevelLoaded = " .. tostring(server.isLevelLoaded), tick_counter)
	end

	old_level_to_load = server.levelToLoad
	old_loaded_level = server.loadedLevel
	old_is_level_loaded = server.isLevelLoaded

	if plugin.config.autoBroadcastNotices and tick_counter % plugin.config.noticeEveryTicks == 0 then
		emit_all("srcc.showcase.notice", "Periodic server notice tick=" .. tostring(tick_counter), tick_counter)
	end
end)
