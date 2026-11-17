local log = require("main.src.log")
local protocol = require("main.src.protocol")
local index_response = require("main.src.index_response")
local udp_events = require("main.src.udp_events")
local network_session = require("main.src.network_session")
local network_transfer = require("main.src.network_transfer")
local network_sync_payload = require("main.src.network_sync_payload")
local network_events = require("main.src.network_events")

local client_id = network_session.client_id
local enqueue_bytes = network_session.enqueue_bytes
local enqueue_frame = network_session.enqueue_frame
local reset_client_sync_state = network_session.reset_client_sync_state
local clear_client_binding = network_session.clear_client_binding
local apply_bound_player = network_session.apply_bound_player
local resolve_client_player_from_hello = network_session.resolve_client_player_from_hello
local refresh_client_player_binding = network_session.refresh_client_player_binding
local queue_sync_file = network_transfer.queue_sync_file
local queue_sync_bundle = network_transfer.queue_sync_bundle
local send_initial_custom_item_sync = network_sync_payload.send_initial_custom_item_sync
local send_initial_custom_vehicle_sync = network_sync_payload.send_initial_custom_vehicle_sync
local sanitize_log_text = network_events.sanitize_log_text

local network_handshake = {}

local function reject_protocol_mismatch(state, connection, payload)
	local client = state.clients[connection]
	if tonumber(payload.protocol) == protocol.VERSION then
		return false
	end

	log.warn(
		"SRC protocol mismatch (%s): client=%s server=%d",
		client_id(connection),
		tostring(payload.protocol),
		protocol.VERSION
	)
	enqueue_frame(state, connection, "ERROR_REPORT", {
		code = "SRC_PROTOCOL_MISMATCH",
		error = string.format(
			"Client protocol %s is incompatible with server protocol %d",
			tostring(payload.protocol),
			protocol.VERSION
		),
		fatal = true,
		serverProtocol = protocol.VERSION,
	})
	if client then
		client.close_after_flush = true
	end
	return true
end

local function require_hello(state, connection, frame_name)
	local client = state.clients[connection]
	if client and client.hello then
		return client
	end

	enqueue_frame(state, connection, "ERROR_REPORT", {
		code = "SRC_BIND_REQUIRED",
		error = string.format("HELLO required before %s", frame_name),
	})
	return nil
end

local function handle_ping(state, connection, payload)
	local client = state.clients[connection]
	if reject_protocol_mismatch(state, connection, payload) then
		return
	end
	if client then
		client.last_heartbeat_at = os.realClock()
	end
	enqueue_frame(state, connection, "SRC_PONG", {
		protocol = protocol.VERSION,
		motd = state.config.motd,
		motdIcon = state.config.motdIconData,
	})
end

local function handle_hello(state, connection, payload)
	local client = state.clients[connection]
	if not client or reject_protocol_mismatch(state, connection, payload) then
		return
	end

	reset_client_sync_state(connection, client)
	local udp_token = udp_events.new_token()
	if not udp_token then
		log.warn("SRC handshake rejected: UDP token generation is unavailable")
		enqueue_frame(state, connection, "ERROR_REPORT", {
			code = "SRC_UDP_UNAVAILABLE",
			error = "UDP token generation is unavailable",
			fatal = true,
		})
		client.close_after_flush = true
		return
	end

	udp_events.set_token(state, connection, client, udp_token)
	client.hello = true
	client.hello_payload = payload
	client.generation = state.sync_generation
	client.sync_state = "capable"

	local player, bind_error = resolve_client_player_from_hello(state, connection, payload)
	if player then
		apply_bound_player(state, connection, client, player)
	elseif bind_error == "invalid_hello_payload" or bind_error == "ambiguous_bind_claims" then
		log.warn("SRC bind rejected (%s): %s", client_id(connection), tostring(bind_error))
		clear_client_binding(connection, client)
		client.hello = false
		enqueue_frame(state, connection, "ERROR_REPORT", {
			code = "SRC_BIND_REJECTED",
			error = tostring(bind_error),
			fatal = true,
		})
		client.close_after_flush = true
		return
	else
		udp_events.unbind_endpoint(client)
		client.player = nil
		client.bound = false
	end

	enqueue_frame(state, connection, "HELLO_ACK", {
		protocol = protocol.VERSION,
		disallowedPaths = state.config.disallowedPaths,
		disableClientTiremarks = state.config.disableClientTiremarks == true,
		disableDiscordJoin = state.config.disableDiscordJoin == true,
		hideDiscordDetails = state.config.hideDiscordDetails == true,
		port = server.port,
		udpToken = udp_token,
		maxEventBytes = state.config.maxEventBytes,
		runtimeID = state.runtime_id,
		syncGeneration = state.sync_generation,
		manifestHash = state.manifest_hash,
		bindState = client.bound and "bound" or "pending",
	})

	if client.bound then
		send_initial_custom_item_sync(state, connection)
		send_initial_custom_vehicle_sync(state, connection)
	end
end

local function handle_index_request(state, connection)
	local client = require_hello(state, connection, "INDEX_REQ")
	if not client then
		return
	end

	if not refresh_client_player_binding(state, connection, client) then
		client.pending_index_request = true
		return
	end
	client.pending_index_request = false

	-- INDEX_RES terminates the complete runtime snapshot.
	send_initial_custom_item_sync(state, connection)
	send_initial_custom_vehicle_sync(state, connection)
	enqueue_bytes(state, connection, index_response.bytes(state))
	client.sync_state = "syncing"
end

local function handle_file_request(state, connection, payload)
	local client = require_hello(state, connection, "FILE_REQ")
	if client and refresh_client_player_binding(state, connection, client) then
		queue_sync_file(state, connection, payload.path)
	end
end

local function handle_bundle_request(state, connection, payload)
	local client = require_hello(state, connection, "BUNDLE_REQ")
	if client and refresh_client_player_binding(state, connection, client) then
		queue_sync_bundle(state, connection, payload.id, payload.paths)
	end
end

local function handle_sync_ready(state, connection, payload)
	local client = state.clients[connection]
	local generation = math.floor(tonumber(payload.syncGeneration) or 0)
	local runtime_id = tostring(payload.runtimeID or "")
	local manifest_hash = tostring(payload.manifestHash or "")
	if client and client.hello and client.bound
		and generation == state.sync_generation
		and runtime_id == tostring(state.runtime_id)
		and manifest_hash ~= ""
		and manifest_hash == state.manifest_hash then
		client.sync_state = "ready"
		client.ready_generation = generation
		client.ready_manifest_hash = manifest_hash
		enqueue_frame(state, connection, "SYNC_READY_ACK", {
			runtimeID = state.runtime_id,
			syncGeneration = state.sync_generation,
			manifestHash = state.manifest_hash,
		})
	else
		enqueue_frame(state, connection, "ERROR_REPORT", {
			code = "SRC_STALE_MANIFEST",
			error = "SYNC_READY does not match the active server manifest",
		})
	end
end

local function handle_udp_ready(state, connection)
	local client = state.clients[connection]
	if not client or not client.hello or not client.bound or client.sync_state ~= "ready" then
		return
	end

	local completion_expiry =
		state.tick + math.max(120, tonumber(state.config.eventProcessTimeoutTicks) or 180)
	for _, pending in pairs(client.awaiting_results) do
		pending.deadline_tick = state.tick + state.config.eventProcessTimeoutTicks + 7200
	end
	for message_id in pairs(client.recent_completed) do
		client.recent_completed[message_id] = completion_expiry
	end
	client.udp_events_ready = true
end

local function handle_error_report(_, connection, payload)
	log.warn("client error (%s): %s", client_id(connection), sanitize_log_text(payload.error))
end

local FRAME_HANDLERS = {
	SRC_PING = handle_ping,
	HELLO = handle_hello,
	INDEX_REQ = handle_index_request,
	FILE_REQ = handle_file_request,
	BUNDLE_REQ = handle_bundle_request,
	SYNC_READY = handle_sync_ready,
	EVENTS_UDP_READY = handle_udp_ready,
	ERROR_REPORT = handle_error_report,
}

local function handle_frame(state, connection, frame)
	if type(frame) ~= "table" or type(frame.type) ~= "string" then
		return
	end

	local frame_handler = FRAME_HANDLERS[frame.type]
	if frame_handler then
		local payload = type(frame.payload) == "table" and frame.payload or {}
		frame_handler(state, connection, payload, frame.type)
	end
end

network_handshake.handle_frame = handle_frame
network_handshake.handle_index_request = handle_index_request

return network_handshake
