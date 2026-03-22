---@diagnostic disable: lowercase-global
local log = require("main.src.log")
local eventCodec = require("main.src.eventCodec")
local shared = require("main.src.shared")
local network = require("main.src.network")
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

function src.refreshSyncFiles()
	refreshNow()
end

function src.onClientEvent(name, fn)
	assert(type(name) == "string" and name ~= "", "src.onClientEvent(name, fn): name must be non-empty string")
	assert(type(fn) == "function", "src.onClientEvent(name, fn): fn must be function")

	return network.onClientEvent(state, name, fn)
end

function src.emitClientEvent(player, name, ...)
	if player ~= nil then
		assert(type(player) == "userdata" and player.class == "Player", "src.emitClientEvent(player, ...): player must be Player or nil")
		assert(not player.isBot, "src.emitClientEvent(player, ...): player cannot be a bot")
	end
	assert(type(name) == "string" and name ~= "", "src.emitClientEvent(player, name, ...): name must be non-empty string")

	local hash = eventCodec.hashName(name)
	if not hash then
		error("src.emitClientEvent(player, name, ...): failed to hash event name")
	end

	local argsBytes, encodeErr = eventCodec.encodeArgs(...)
	assert(argsBytes ~= nil, "src.emitClientEvent(player, name, ...): " .. tostring(encodeErr))

	return network.emitClientEvent(state, player, name, hash, argsBytes)
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

function src.getClientPlayer(connection)
	return network.getConnectionPlayer(state, connection)
end

function src.listScripts()
	return shared.discoverScripts(state)
end

function src.binary(bytes)
	return network.binary(bytes)
end

src.blob = src.binary

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

		network.logicStep(state)
	end)

	hook.add("SendPacket", "main.src.udpSendPacket", function(address, port)
		network.onSendPacket(state, address, port)
	end)

	hook.add("PostSendPacket", "main.src.udpPostSendPacket", function()
		network.onPostSendPacket(state)
	end)

	hook.add("PostPacketReceive", "main.src.udpPostPacketReceive", function()
		network.onPostPacketReceive(state)
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
