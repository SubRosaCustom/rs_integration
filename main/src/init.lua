---@diagnostic disable: lowercase-global
pcall(require, "librosaserver_src_integration")

local log = require("main.src.log")
local config_reader = require("main.src.config")
local event_codec = require("main.src.event_codec")
local network = require("main.src.network")
local browser_marker = require("main.src.browser_marker")
local human_models = require("main.src.human_models")
local item_types = require("main.src.item_types")
local runtime_state = require("main.src.runtime_state")
local sync_snapshot = require("main.src.sync_snapshot")
local vehicle_types = require("main.src.vehicle_types")
local world_mutations = require("main.src.world_mutations")

local state, was_legacy = runtime_state.get()
state.src_admission_rejections = state.src_admission_rejections or {}
state.src_recovery_grace_until = os.realClock() + 60

local src = _G.src or {}
_G.src = src

item_types.install(state, src, was_legacy)
vehicle_types.install(state, src, was_legacy)
human_models.install(state, src, was_legacy)

local function refresh_now()
	sync_snapshot.discover(state)
	src.refresh()
end

local function disable_runtime(reason)
	src.enabled = false
	state.enabled = false
	state.runtime_active = false
	network.shutdown(state)
	if reason then
		log.info(reason)
	end
end

local function apply_config(is_reload)
	local raw = nil
	if type(config) == "table" then
		raw = config.src
	end

	state.config = config_reader.resolve(raw)
	state.enabled = state.config.enabled ~= false
	src.enabled = state.enabled

	if not state.enabled then
		if state.runtime_active then
			disable_runtime("disabled via config")
		end
		return
	end

	refresh_now()
	network.ensure_tcp_server(state)

	if not state.runtime_active then
		log.info("enabled")
	elseif is_reload then
		log.info("config reloaded")
	end

	state.runtime_active = true
end

function src.refresh()
	network.refresh(state)
end

function src.refreshSyncFiles()
	refresh_now()
end

function src.reloadClientPlugin(plugin_name)
	assert(type(plugin_name) == "string" and plugin_name ~= "", "src.reloadClientPlugin(plugin_name): plugin_name must be non-empty string")
	sync_snapshot.discover(state)
	network.refresh(state, plugin_name)
end

function src.onClientEvent(name, fn)
	assert(type(name) == "string" and name ~= "", "src.onClientEvent(name, fn): name must be non-empty string")
	assert(type(fn) == "function", "src.onClientEvent(name, fn): fn must be function")

	return network.on_client_event(state, name, fn)
end

function src.emitClientEvent(player, name, ...)
	if player ~= nil then
		assert(type(player) == "userdata" and player.class == "Player", "src.emitClientEvent(player, ...): player must be Player or nil")
		assert(not player.isBot, "src.emitClientEvent(player, ...): player cannot be a bot")
	end
	assert(type(name) == "string" and name ~= "", "src.emitClientEvent(player, name, ...): name must be non-empty string")

	local hash = event_codec.hash_name(name)
	if not hash then
		error("src.emitClientEvent(player, name, ...): failed to hash event name")
	end

	local argument_bytes, encode_error = event_codec.encode_args(...)
	assert(argument_bytes ~= nil, "src.emitClientEvent(player, name, ...): " .. tostring(encode_error))

	return network.emit_client_event(state, player, name, hash, argument_bytes)
end

world_mutations.install(state, src)

function src.syncClientItemTypes(player, payload)
	if player ~= nil then
		assert(type(player) == "userdata" and player.class == "Player", "src.syncClientItemTypes(player, payload): player must be Player or nil")
		assert(not player.isBot, "src.syncClientItemTypes(player, payload): player cannot be a bot")
	end
	assert(type(payload) == "table", "src.syncClientItemTypes(player, payload): payload must be table")
	return network.sync_client_item_types(state, player, payload)
end

function src.syncClientVehicleTypes(player, payload)
	if player ~= nil then
		assert(type(player) == "userdata" and player.class == "Player", "src.syncClientVehicleTypes(player, payload): player must be Player or nil")
		assert(not player.isBot, "src.syncClientVehicleTypes(player, payload): player cannot be a bot")
	end
	assert(type(payload) == "table", "src.syncClientVehicleTypes(player, payload): payload must be table")
	return network.sync_client_vehicle_types(state, player, payload)
end

-- src.setItemTypeModel and src.setItemTypeIcon are installed
-- by item_types.install() above; they are defined in item_types.lua

function src.getClientState(player)
	local connection = network.get_player_connection(state, player)
	local client = connection and state.clients[connection] or nil
	local connected = connection and connection.is_open and client ~= nil or false

	return {
		enabled = src.enabled,
		connected = connected,
		hello = client and client.hello or false,
		syncState = client and client.sync_state or "disconnected",
		ready = client and client.sync_state == "ready" or false,
		scriptCount = #state.scripts,
		assetFileCount = #state.asset_files,
		loadedLevel = state.loaded_level,
		persistentMode = state.persistent_mode,
		port = state.bound_port,
	}
end

function src.getClientPlayer(connection)
	return network.get_connection_player(state, connection)
end

function src.listScripts()
	return sync_snapshot.discover_scripts(state)
end

function src.binary(bytes)
	return network.binary(bytes)
end

src.blob = src.binary

local function non_src_grace_ticks()
	local tps = tonumber(server and server.TPS) or 60
	return math.max(1, math.floor(tps * 30))
end

local function clear_non_src_player_tags(player)
	if not player or not player.data then
		return
	end

	player.data.srcNonSRCDeadlineTick = nil
	player.data.srcNonSRCKickQueued = nil
end

local function enforce_non_src_players()
	if os.realClock() < state.src_recovery_grace_until then
		return
	end

	for _, player in ipairs(players.getNonBots()) do
		if player.connection then
			local client_state = src.getClientState(player)
			if client_state.connected then
				clear_non_src_player_tags(player)
			else
				local deadline_tick = player.data.srcNonSRCDeadlineTick
				if deadline_tick == nil then
					player.data.srcNonSRCDeadlineTick = state.tick + non_src_grace_ticks()
				elseif player.data.srcNonSRCKickQueued ~= true and state.tick >= deadline_tick then
					player:sendMessage("SRC is required on this server")
					player.connection.timeoutTime = 50 * server.TPS
					player.data.srcNonSRCKickQueued = true
				end
			end
		else
			clear_non_src_player_tags(player)
		end
	end
end

if not state.hooks_registered then
	hook.add("AccountTicketFound", "main.src.admission", function(account)
		if state.config.disallowNonSRCPlayers ~= true then
			return
		end

		local native = rawget(_G, "srcIntegrationNative")
		local ok, endpoint = pcall(
			type(native) == "table" and native.currentPacketEndpoint or function() return nil end
		)
		if ok and type(endpoint) == "table" and network.authorize_account_ticket(state, account, endpoint) then
			return
		end

		if ok and type(endpoint) == "table" then
			local key = tostring(endpoint.address) .. ":" .. tostring(endpoint.port)
			state.src_admission_rejections[key] = {
				message = "SRC is required to play. subrosacustom.github.io",
				expires = os.realClock() + 10,
			}
		end
		return hook.override
	end)

	hook.add("SendConnectResponse", "main.src.admissionMessage", function(address, port, data)
		local key = tostring(address) .. ":" .. tostring(port)
		local rejection = state.src_admission_rejections[key]
		if rejection then
			state.src_admission_rejections[key] = nil
			data.message = rejection.message
		end
	end)

	hook.add("ConfigLoaded", "main.src", function(is_reload)
		apply_config(is_reload)
	end)

	hook.add("Logic", "main.src", function()
		state.tick = state.tick + 1
		for key, rejection in pairs(state.src_admission_rejections) do
			if rejection.expires <= os.realClock() then
				state.src_admission_rejections[key] = nil
			end
		end

		if not src.enabled then
			return
		end

		local normalized_persistent_mode = sync_snapshot.normalize_persistent_mode(
			type(hook) == "table" and hook.persistentMode or nil
		)
		if normalized_persistent_mode ~= state.persistent_mode then
			refresh_now()
			log.info(
				"persistent mode changed to %s; sync refresh queued",
				state.persistent_mode ~= "" and state.persistent_mode or "<none>"
			)
		end

		local normalized_loaded_level = sync_snapshot.normalize_loaded_level(server and server.loadedLevel or nil)
		if normalized_loaded_level ~= state.loaded_level then
			sync_snapshot.discover_asset_files(state)
			src.refresh()
			log.info("loaded level changed to %s; sync refresh queued", state.loaded_level ~= "" and state.loaded_level or "<none>")
		end

		network.logic_step(state)

		if state.config.disallowNonSRCPlayers == true then
			enforce_non_src_players()
		else
			for _, player in ipairs(players.getNonBots()) do
				clear_non_src_player_tags(player)
			end
		end
	end)

	hook.add("SendPacket", "main.src.udpSendPacket", function(address, port)
		browser_marker.on_send_packet(state, address, port)
		network.on_send_packet(state, address, port)
	end)

	hook.add("PostSendPacket", "main.src.udpPostSendPacket", function()
		browser_marker.on_post_send_packet(state)
	end)

	hook.add("PacketReceive", "main.src.udpPacketReceive", function()
		if network.on_packet_receive(state) then
			return hook.override
		end
	end)

	hook.add("InterruptSignal", "main.src", function()
		disable_runtime("interrupt signal received")
	end)

	state.hooks_registered = true
end

if not state.module_loaded then
	if type(config) == "table" then
		apply_config(false)
	else
		state.config = config_reader.resolve(nil)
		state.enabled = state.config.enabled ~= false
		src.enabled = state.enabled
	end
	state.module_loaded = true
	log.info("main module loaded")
else
	log.info("main module already initialized; skipping duplicate setup")
end

return src
