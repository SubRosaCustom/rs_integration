---@diagnostic disable: lowercase-global
local log = require("main.src.log")
local shared = require("main.src.shared")
local network = require("main.src.network")
local watcher = require("main.src.watcher")
local itemTypeSync = require("main.src.itemTypes")

local state = shared.getState()

local src = _G.src or {}
_G.src = src

itemTypeSync.install(state, src)

local function refreshNow()
	shared.discoverSyncFiles(state)
	src.refresh()
end

local function disableRuntime(reason)
	src.enabled = false
	state.enabled = false
	state.runtimeActive = false
	network.shutdown(state)
	watcher.clear(state)
	if reason then
		log.info(reason)
	end
end

local function applyConfig(isReload)
	local raw = nil
	if type(config) == "table" then
		raw = config.src
	end

	state.config = shared.resolveConfig(raw)
	state.enabled = state.config.enabled ~= false
	src.enabled = state.enabled

	if not state.enabled then
		if state.runtimeActive then
			disableRuntime("disabled via config")
		end
		return
	end

	refreshNow()
	network.ensureTcpServer(state)
	watcher.ensure(state)

	if not state.runtimeActive then
		log.info("enabled")
	elseif isReload then
		log.info("config reloaded")
	end

	state.runtimeActive = true
end

function src.refresh()
	network.refresh(state)
end

function src.onClientEvent(name, fn)
	network.onClientEvent(state, name, fn)
end

function src.emitClientEvent(player, name, data, bin)
	if player ~= nil then
		assert(type(player) == "userdata" and player.class == "Player", "src.emitClientEvent(player, ...): player must be Player or nil")
		assert(not player.isBot, "src.emitClientEvent(player, ...): player cannot be a bot")
	end
	return network.emitClientEvent(state, player, name, data, bin)
end

function src.syncClientItemTypes(player, payload)
	if player ~= nil then
		assert(type(player) == "userdata" and player.class == "Player", "src.syncClientItemTypes(player, payload): player must be Player or nil")
		assert(not player.isBot, "src.syncClientItemTypes(player, payload): player cannot be a bot")
	end
	assert(type(payload) == "table", "src.syncClientItemTypes(player, payload): payload must be table")
	return network.syncClientItemTypes(state, player, payload)
end

-- src.setItemTypeModel and src.setItemTypeIcon are installed
-- by itemTypeSync.install() above; they are defined in itemTypes.lua

function src.getClientState(player)
	local connection = network.getPlayerConnection(player)
	local client = connection and state.clients[connection] or nil
	local connected = connection and connection.isOpen and client ~= nil or false

	return {
		enabled = src.enabled,
		connected = connected,
		hello = client and client.hello or false,
		scriptCount = #state.scripts,
		assetFileCount = #state.assetFiles,
		loadedLevel = state.loadedLevel,
		persistentMode = state.persistentMode,
		port = state.boundPort,
	}
end

function src.listScripts()
	return shared.discoverScripts(state)
end

local function ensureCommandRegistration()
	if type(hook) ~= "table" or type(hook.plugins) ~= "table" then
		log.warn("could not register /srcrefresh command (hook.plugins unavailable)")
		return
	end

	local commandPluginName = "__main_src_commands"
	local commandPlugin = hook.plugins[commandPluginName]

	if not commandPlugin then
		commandPlugin = {
			name = "main.src.commands",
			isEnabled = true,
			hooks = {},
			polyHooks = {},
			commands = {},
		}
		hook.plugins[commandPluginName] = commandPlugin
	end

	commandPlugin.isEnabled = true
	commandPlugin.hooks = commandPlugin.hooks or {}
	commandPlugin.polyHooks = commandPlugin.polyHooks or {}
	commandPlugin.commands = commandPlugin.commands or {}
	commandPlugin.commands["/srcrefresh"] = {
		info = "Refresh Sub Rosa Custom client scripts for all connected SRC clients.",
		canCall = function(ply)
			return ply.isConsole or ply.isAdmin
		end,
		call = function(ply)
			refreshNow()
			local message = "SRC refresh queued for all connected clients"
			if ply and ply.sendMessage then
				ply:sendMessage(message)
			else
				log.info(message)
			end
		end,
	}
end

local function ensureNonSRCGateHook()
	if type(hook) ~= "table" or type(hook.add) ~= "function" then
		log.warn("could not register non-SRC gate hook (hook.add unavailable)")
		return
	end

	hook.add("AccountTicketFound", "main.src.disallowNonSRCPlayers", function(acc)
		if state.config.disallowNonSRCPlayers ~= true then
			return
		end

		if acc then
			return
		end

		if type(hook.once) == "function" then
			hook.once("SendConnectResponse", function(_, _, data)
				data.message = "Only SRC allowed - discord.gg/subrosacustom"
			end)
		end

		return hook.override
	end)
end

if not state.hooksRegistered then
	ensureCommandRegistration()
	ensureNonSRCGateHook()

	hook.add("ConfigLoaded", "main.src", function(isReload)
		applyConfig(isReload)
	end)

	hook.add("Logic", "main.src", function()
		state.tick = state.tick + 1

		if not src.enabled then
			return
		end

		local normalizedPersistentMode = shared.normalizePersistentMode(
			type(hook) == "table" and hook.persistentMode or nil
		)
		if normalizedPersistentMode ~= state.persistentMode then
			shared.discoverPersistentMode(state)
			src.refresh()
			log.info(
				"persistent mode changed to %s; sync refresh queued",
				state.persistentMode ~= "" and state.persistentMode or "<none>"
			)
		end

		local normalizedLoadedLevel = shared.normalizeLoadedLevel(server and server.loadedLevel or nil)
		if normalizedLoadedLevel ~= state.loadedLevel then
			shared.discoverAssetFiles(state)
			src.refresh()
			log.info("loaded level changed to %s; sync refresh queued", state.loadedLevel ~= "" and state.loadedLevel or "<none>")
		end

		watcher.ensure(state)
		watcher.process(state, function()
			refreshNow()
			log.info("auto-refresh queued")
		end)
		network.logicStep(state)
	end)

	hook.add("InterruptSignal", "main.src", function()
		disableRuntime("interrupt signal received")
	end)

	state.hooksRegistered = true
end

if not state.moduleLoaded then
	if type(config) == "table" then
		applyConfig(false)
	else
		state.config = shared.resolveConfig(nil)
		state.enabled = state.config.enabled ~= false
		src.enabled = state.enabled
	end
	state.moduleLoaded = true
	log.info("main module loaded")
else
	log.info("main module already initialized; skipping duplicate setup")
end

return src
