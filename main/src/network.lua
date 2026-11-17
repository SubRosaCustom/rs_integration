local json = require("main.json")

local log = require("main.src.log")
local tcp_connection_limits = require("main.src.tcp_connection_limits")
local tcp_receive_buffer = require("main.src.tcp_receive_buffer")
local threaded_tcp_server = require("main.src.threaded_tcp_server")
local udp_events = require("main.src.udp_events")
local network_session = require("main.src.network_session")
local network_transfer = require("main.src.network_transfer")
local network_sync_payload = require("main.src.network_sync_payload")
local network_handshake = require("main.src.network_handshake")
local network_events = require("main.src.network_events")

local client_id = network_session.client_id
local parse_positive_integer = network_session.parse_positive_integer
local SERVER_EVENT_ID_START = network_session.SERVER_EVENT_ID_START
local get_player_connection = network_session.get_player_connection
local validate_bound_player = network_session.validate_bound_player
local resolve_client_player_from_hello = network_session.resolve_client_player_from_hello
local apply_bound_player = network_session.apply_bound_player
local refresh_client_player_binding = network_session.refresh_client_player_binding
local suppress_player_timeout_while_syncing = network_session.suppress_player_timeout_while_syncing
local reset_client_sync_state = network_session.reset_client_sync_state
local next_sync_generation = network_session.next_sync_generation
local clear_client_state = network_session.clear_client_state
local enqueue_frame = network_session.enqueue_frame
local flush_send_queue = network_session.flush_send_queue
local pump_file_transfer = network_transfer.pump_file_transfer
local pump_bundle_transfer = network_transfer.pump_bundle_transfer
local send_initial_custom_item_sync = network_sync_payload.send_initial_custom_item_sync
local send_initial_custom_vehicle_sync = network_sync_payload.send_initial_custom_vehicle_sync
local handle_frame = network_handshake.handle_frame
local handle_index_request = network_handshake.handle_index_request
local process_pending_retries = network_events.process_pending_retries

local network = {}
local HEARTBEAT_TIMEOUT_SECONDS = 60
-- Match the client encoder's limit, including the terminating newline.
local MAX_TCP_FRAME_BYTES = 8 * 1024 * 1024
local next_tcp_bind_tick = 0
local tcp_limit_warnings = {}

local function decode_json(raw)
	if type(raw) ~= "string" or raw == "" then
		return nil
	end

	local ok, decoded = pcall(json.decode, raw)
	if not ok or type(decoded) ~= "table" then
		return nil
	end

	return decoded
end

local function process_buffered_frames(state, connection, client, frame_budget)
	local processed = 0
	while processed < frame_budget do
		local line = client.receive_buffer:pop_line()
		if not line then
			break
		end

		local frame = decode_json(line)
		if frame then
			handle_frame(state, connection, frame)
		else
			enqueue_frame(state, connection, "ERROR_REPORT", {
				error = "invalid JSON frame",
			})
		end
		processed = processed + 1
	end
	return processed
end

local function process_client_reads(state, connection)
	local client = state.clients[connection]
	if not client or not connection.is_open then
		return
	end

	local read_size = state.config.readSize
	local max_read_bytes_per_tick = math.max(read_size, state.config.maxReadBytesPerTick)
	local max_frames_per_tick = 256
	local read_bytes_this_tick = 0
	local frames_this_tick = process_buffered_frames(state, connection, client, max_frames_per_tick)

	while connection.is_open and read_bytes_this_tick < max_read_bytes_per_tick and frames_this_tick < max_frames_per_tick do
		local ok, data_or_error = pcall(
			connection.receive,
			connection,
			math.min(read_size, max_read_bytes_per_tick - read_bytes_this_tick)
		)
		if not ok then
			log.warn("receive failed (%s): %s", client_id(connection), data_or_error)
			connection:close()
			break
		end

		if data_or_error == nil then
			break
		end

		local data = tostring(data_or_error)
		if data == "" then
			break
		end
		read_bytes_this_tick = read_bytes_this_tick + #data

		local pushed = client.receive_buffer:push(
			data,
			tcp_connection_limits.buffer_limit(client, MAX_TCP_FRAME_BYTES)
		)
		if not pushed then
			log.warn("TCP frame exceeds limit (%s)", client_id(connection))
			connection:close()
			break
		end
		frames_this_tick = frames_this_tick + process_buffered_frames(
			state,
			connection,
			client,
			max_frames_per_tick - frames_this_tick
		)
	end
end

local function accept_connections(state)
	if not state.tcp_server then
		return
	end

	state.tcp_server:poll()
	for connection, client in pairs(state.clients) do
		local stats = connection:take_send_stats()
		if stats and stats.bytes > 0 then
			client.last_heartbeat_at = os.realClock()
		end
	end
	if state.tcp_server.last_error then
		log.warn("TCP worker failed: %s", state.tcp_server.last_error)
		state.tcp_server:close()
		state.tcp_server = nil
		state.tcp_bind_in_progress = false
		state.bound_port = nil
		next_tcp_bind_tick = state.tick + 60
		return
	end

	if state.tcp_bind_in_progress and state.tcp_server.is_listening then
		state.tcp_bind_in_progress = false
		state.bound_port = state.tcp_server.port
		log.info("TCP worker listening on server port %s", state.bound_port)
	end

	if not state.tcp_server.is_open then
		return
	end

	while true do
		local connection = state.tcp_server:accept()
		if connection == nil then
			break
		end

		local rejection = tcp_connection_limits.accept_rejection(state.clients, connection)
		if rejection then
			log.warn_limited(tcp_limit_warnings, "accept_rejected",
				"TCP connection rejected (%s): %s", client_id(connection), rejection)
			connection:close()
			goto next_connection
		end

		state.clients[connection] = {
			connected_at = os.realClock(),
			receive_buffer = tcp_receive_buffer.new(),
			send_queue = {},
			send_offset = 1,
			pending_file_requests = {},
			pending_bundle_requests = {},
			active_file_transfer = nil,
			active_bundle_transfer = nil,
			hello = false,
			hello_payload = nil,
			player = nil,
			bound = false,
			generation = 0,
			warn_limits = {},
			reported_failure_event_hashes = {},
			pending_events = {},
			pending_results = {},
			awaiting_results = {},
			early_results = {},
			recent_completed = {},
			next_event_id = SERVER_EVENT_ID_START,
			close_after_flush = false,
			last_heartbeat_at = os.realClock(),
			sync_state = "connected",
			ready_generation = 0,
			ready_manifest_hash = nil,
		}
		udp_events.reset_client(state.clients[connection])

		log.info("TCP client connected: %s", client_id(connection))
		::next_connection::
	end
end

local function process_clients(state)
	network.send_due_refresh_notices(state)
	for connection, client in pairs(state.clients) do
		if connection.is_open and client then
			if client.hello and client.bound then
				validate_bound_player(connection, client)
			elseif client.hello and not client.bound then
				local player, _ = resolve_client_player_from_hello(state, connection, client.hello_payload)
				if player then
					if apply_bound_player(state, connection, client, player) then
						send_initial_custom_item_sync(state, connection)
						send_initial_custom_vehicle_sync(state, connection)
					end
				end
			end

			if client.pending_index_request and client.bound then
				handle_index_request(state, connection)
			end

			suppress_player_timeout_while_syncing(client)
		end

		if connection.is_open then
			process_client_reads(state, connection)
			client.last_heartbeat_at = client.last_heartbeat_at or os.realClock()
			if os.realClock() - client.last_heartbeat_at >= HEARTBEAT_TIMEOUT_SECONDS then
				log.warn("SRC heartbeat timed out: %s", client_id(connection))
				connection:close()
			elseif tcp_connection_limits.pre_hello_expired(client, os.realClock()) then
				log.warn_limited(tcp_limit_warnings, "pre_hello_timeout",
					"TCP connection closed (%s): no HELLO within %ds",
					client_id(connection), tcp_connection_limits.PRE_HELLO_TIMEOUT_SECONDS)
				connection:close()
			else
				process_pending_retries(state, connection)
				pump_bundle_transfer(state, connection)
				pump_file_transfer(state, connection)
				flush_send_queue(state, connection)
			end
		end

		if not connection.is_open then
			log.info("TCP client disconnected: %s", client_id(connection))
			clear_client_state(state, connection)
		end
	end
end

local function close_all(state)
	for connection, _ in pairs(state.clients) do
		clear_client_state(state, connection)
		if connection.is_open then
			pcall(connection.close, connection)
		end
	end
	state.clients = {}

	if state.tcp_server then
		pcall(state.tcp_server.close, state.tcp_server)
	end
	state.tcp_server = nil
	state.tcp_bind_in_progress = false
	state.bound_port = nil
end

local function ensure_tcp_server(state)
	local desired_port = tonumber(server.port) or 0
	if desired_port <= 0 or state.tick < next_tcp_bind_tick then
		return
	end

	if state.tcp_server and state.tcp_server.is_open and state.tcp_server.port == desired_port then
		return
	end

	if state.tcp_server then
		close_all(state)
	end

	state.tcp_bind_in_progress = true
	local ok, server_or_error = pcall(threaded_tcp_server.new, desired_port)
	if not ok then
		state.tcp_bind_in_progress = false
		next_tcp_bind_tick = state.tick + 60
		log.warn("failed to bind TCP server on %s: %s", desired_port, server_or_error)
		return
	end

	state.tcp_server = server_or_error
end

-- notices are spread over a few seconds so a large server doesn't re-index every client at once
local REFRESH_NOTICE_SPREAD_SECONDS = 3
local function refresh_notice_spread_ticks(state)
	local tps = tonumber(server and server.TPS) or 60
	return state.refresh_notice_spread_ticks or math.floor(tps * REFRESH_NOTICE_SPREAD_SECONDS)
end

-- The reset happens at refresh time, so stale transfers stop immediately and a client that
-- connects or re-indexes inside the spread window already receives the new snapshot.
function network.refresh(state, plugin_name)
	local generation = next_sync_generation(state)
	local notified = {}
	for connection, client in pairs(state.clients) do
		-- Pending clients must also cancel an old snapshot when scope changes.
		if connection.is_open and client.hello
			and (not client.bound or validate_bound_player(connection, client)) then
			reset_client_sync_state(connection, client, true)
			client.generation = generation
			notified[#notified + 1] = client
		end
	end
	local spread = #notified > 1 and refresh_notice_spread_ticks(state) or 0
	for _, client in ipairs(notified) do
		client.pending_refresh_notice = {
			due_tick = (tonumber(state.tick) or 0) + (spread > 0 and math.random(0, spread) or 0),
			payload = {
				runtimeID = state.runtime_id,
				disallowedPaths = state.config.disallowedPaths,
				disableClientTiremarks = state.config.disableClientTiremarks == true,
				disableDiscordJoin = state.config.disableDiscordJoin == true,
				hideDiscordDetails = state.config.hideDiscordDetails == true,
				syncGeneration = generation,
				manifestHash = state.manifest_hash,
				pluginReload = plugin_name,
			},
		}
	end
	network.send_due_refresh_notices(state)
end

function network.send_due_refresh_notices(state)
	for connection, client in pairs(state.clients) do
		local pending = client.pending_refresh_notice
		if pending and (tonumber(state.tick) or 0) >= pending.due_tick then
			client.pending_refresh_notice = nil
			if connection.is_open then
				enqueue_frame(state, connection, "REFRESH_NOTICE", pending.payload)
			end
		end
	end
end

function network.ensure_tcp_server(state)
	ensure_tcp_server(state)
end

function network.logic_step(state)
	ensure_tcp_server(state)
	local server_ = state.tcp_server
	if server_ and server_.is_open then
		local sync_snapshot = require("main.src.sync_snapshot")
		if server_:set_snapshot(state) == false then
			-- a replacement worker has no cache and the archive bytes were released
			sync_snapshot.restore_archives(state)
			assert(server_:set_snapshot(state), "snapshot archives could not be restored")
		end
		if server_.ready_manifest_hash ~= nil and server_.ready_manifest_hash == state.manifest_hash then
			sync_snapshot.release_archives(state)
		end
	end
	accept_connections(state)
	process_clients(state)
end

function network.on_send_packet(state, address, port, endpoint)
	udp_events.on_send_packet(state, address, port, endpoint)
end

function network.on_packet_receive(state)
	local decoded, should_override = udp_events.on_packet_receive(state)
	for _, datagram in ipairs(decoded) do
		network_events.on_udp_datagram(state, datagram)
	end
	return should_override
end

function network.shutdown(state)
	close_all(state)
end

function network.get_player_connection(state, player)
	return get_player_connection(state, player)
end

function network.get_connection_player(state, connection)
	local client = state and state.clients and state.clients[connection] or nil
	if not client then
		return nil
	end

	return refresh_client_player_binding(state, connection, client)
end

function network.authorize_account_ticket(state, account, endpoint)
	if not state or not account or type(endpoint) ~= "table" then
		return false
	end

	local address = tostring(endpoint.address or "")
	local phone_number = parse_positive_integer(account.phoneNumber)
	if address == "" or not phone_number then
		return false
	end

	for connection, client in pairs(state.clients) do
		local claimed_phone = client and client.hello_payload
			and parse_positive_integer(client.hello_payload.phoneNumber)
		if connection.is_open
			and tostring(connection.address) == address
			and claimed_phone == phone_number
			and client.hello == true
			and tostring(client.game_address) == address
			and tonumber(client.game_port) == tonumber(endpoint.port) then
			client.admitted_address = address
			client.admitted_port = tonumber(endpoint.port)
			return true
		end
	end

	return false
end


return network
