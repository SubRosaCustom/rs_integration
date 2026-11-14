local json = require("main.json")

local log = require("main.src.log")
local udp_events = require("main.src.udp_events")
local utf8_sanitize = require("main.src.utf8_sanitize")

local network_session = {}
local SERVER_EVENT_ID_START = 0x80000000
local SERVER_EVENT_ID_MAX = 0xFFFFFFFF
local disconnect_other_connections_for_player

local function parse_positive_integer(value)
	if type(value) == "number" then
		local num = math.floor(value)
		if num > 0 then
			return num
		end
		return nil
	end

	if type(value) == "string" and value ~= "" then
		local parsed = tonumber(value)
		if parsed then
			local num = math.floor(parsed)
			if num > 0 then
				return num
			end
		end
	end

	return nil
end

local function client_id(connection)
	return string.format("%s:%s", tostring(connection.address), tostring(connection.port))
end

local function get_player_connection(state, player)
	if not state or not player then
		return nil
	end

	if type(player) == "userdata" and player.class == "Player" then
		if player.isBot then
			return nil
		end

		for connection, client in pairs(state.clients) do
			if client and connection and connection.is_open and client.player == player
				and player.connection then
				return connection
			end
		end
	end

	return nil
end

local function resolve_client_player_from_hello(state, connection, payload)
	if not connection then
		return nil, "missing_connection"
	end

	if type(payload) ~= "table" then
		return nil, "invalid_hello_payload"
	end

	local phone_number = parse_positive_integer(payload.phoneNumber)
	local sub_rosa_id = parse_positive_integer(payload.subRosaID)
	if not phone_number and not sub_rosa_id then
		return nil, "missing_bind_claims"
	end

	local best_player = nil
	local client = state.clients[connection]
	if not client or not client.game_address or not client.game_port
		or tostring(client.game_address) ~= tostring(connection.address) then
		return nil, "missing_game_endpoint"
	end
	local remote_address = tostring(connection.address)

	for _, player in ipairs(players.getNonBots()) do
		if not player.isBot and player.account and player.connection
			and tostring(player.connection.address) == remote_address
			and tonumber(player.connection.port) == tonumber(client.game_port) then
			if phone_number and tonumber(player.phoneNumber) ~= phone_number then
				goto continue
			end
			if sub_rosa_id and tonumber(player.subRosaID) ~= sub_rosa_id then
				goto continue
			end

			if best_player ~= nil then
				return nil, "ambiguous_bind_claims"
			end

			best_player = player
		end
		::continue::
	end

	if not best_player then
		return nil, "no_matching_player"
	end

	return best_player, nil
end

local function apply_bound_player(state, connection, client, player)
	if not state or not connection or not client or not player then
		return false
	end

	disconnect_other_connections_for_player(state, player, connection)
	client.player = player
	client.bound = true
	client.close_after_flush = false
	udp_events.bind_endpoint(state, connection, client)
	return true
end

local function close_client_transfer(client)
	if client and client.active_file_transfer and client.active_file_transfer.file then
		pcall(function()
			client.active_file_transfer.file:close()
		end)
	end
	if client then
		client.active_file_transfer = nil
		client.active_bundle_transfer = nil
	end
end

local function reset_client_sync_state(connection, client, preserve_udp_state)
	-- The worker may already have transmitted a prefix of this protocol frame.
	-- Hand it the unsent tail so cancellation can finish that frame atomically.
	local remaining_frame
	if client.send_offset and client.send_offset > 1 and client.send_queue and client.send_queue[1] then
		remaining_frame = client.send_queue[1]:sub(client.send_offset)
	end
	connection:discard_pending_sends(remaining_frame)
	close_client_transfer(client)
	client.pending_file_requests = {}
	client.pending_bundle_requests = {}
	client.pending_index_request = false
	client.send_queue = {}
	client.send_offset = 1
	client.sync_state = client.hello and "capable" or "connected"
	client.ready_generation = 0
	client.ready_manifest_hash = nil
	if preserve_udp_state then
		client.udp_events_ready = false
		udp_events.tick(client)
	else
		client.pending_events = {}
		client.pending_results = {}
		client.awaiting_results = {}
		client.early_results = {}
		client.recent_completed = {}
		client.next_event_id = SERVER_EVENT_ID_START
		udp_events.reset_client(client)
	end
end

local function clear_client_binding(connection, client)
	reset_client_sync_state(connection, client)
	udp_events.unbind_endpoint(client)
	client.player = nil
	client.bound = false
end

local function validate_bound_player(connection, client)
	if not connection or not client or not client.player then
		return nil
	end

	local player = client.player
	local player_connection = player.connection
	local invalid = player.isBot or not player.account or not player_connection
		or tostring(player_connection and player_connection.address) ~= tostring(connection.address)
		or tostring(client.game_address) ~= tostring(connection.address)
		or tonumber(player_connection and player_connection.port) ~= tonumber(client.game_port)
	if client.hello_payload then
		local phone_number = parse_positive_integer(client.hello_payload.phoneNumber)
		local sub_rosa_id = parse_positive_integer(client.hello_payload.subRosaID)
		if phone_number and tonumber(player.phoneNumber) ~= phone_number then
			invalid = true
		end
		if sub_rosa_id and tonumber(player.subRosaID) ~= sub_rosa_id then
			invalid = true
		end
	end

	if invalid then
		clear_client_binding(connection, client)
		connection:close()
		return nil
	end

	return player
end

local function refresh_client_player_binding(state, connection, client)
	if not state or not connection or not connection.is_open or not client then
		return nil
	end

	local player = validate_bound_player(connection, client)
	if player then
		return player
	end

	if not connection.is_open or client.hello ~= true then
		return nil
	end

	local rebound_player, _ = resolve_client_player_from_hello(state, connection, client.hello_payload)
	if rebound_player and apply_bound_player(state, connection, client, rebound_player) then
		return rebound_player
	end

	return nil
end

local function is_client_syncing(client)
	if not client or client.hello ~= true then
		return false
	end

	if client.udp_events_ready ~= true then
		return true
	end

	if client.active_file_transfer then
		return true
	end

	if client.active_bundle_transfer then
		return true
	end

	if type(client.pending_bundle_requests) == "table" and #client.pending_bundle_requests > 0 then
		return true
	end

	return type(client.pending_file_requests) == "table" and #client.pending_file_requests > 0
end

local function suppress_player_timeout_while_syncing(client)
	if not client or client.bound ~= true or client.player == nil then
		return
	end

	local player_connection = client.player.connection
	if not player_connection or not is_client_syncing(client) then
		return
	end

	player_connection.timeoutTime = 0
end

disconnect_other_connections_for_player = function(state, player, except_connection)
	if not player then
		return
	end

	for connection, client in pairs(state.clients) do
		if connection ~= except_connection and client and client.player == player then
			reset_client_sync_state(connection, client)
			client.close_after_flush = true
		end
	end
end

local function next_sync_generation(state)
	local current = tonumber(state.sync_generation) or 0
	current = current + 1
	state.sync_generation = current
	return current
end

local function clear_client_state(state, connection)
	local client = state.clients[connection]
	close_client_transfer(client)
	udp_events.remove_client(client)
	state.clients[connection] = nil
end

local function enqueue_bytes(state, connection, bytes)
	local client = state.clients[connection]
	if not client or type(bytes) ~= "string" or #bytes == 0 then
		return false
	end

	table.insert(client.send_queue, bytes)
	return true
end

local function enqueue_frame(state, connection, frame_type, payload)
	-- main.json doesn't check UTF-8 but the client's parser rejects it
	local body = utf8_sanitize.sanitize_value({
		type = frame_type,
		payload = payload or {},
	})

	return enqueue_bytes(state, connection, json.encode(body) .. "\n")
end

local function flush_send_queue(state, connection)
	local client = state.clients[connection]
	if not client or not connection.is_open then
		return
	end

	local send_budget = math.max(1024, state.config.maxSendBytesPerTick)
	local sent_this_tick = 0
	while #client.send_queue > 0 and sent_this_tick < send_budget do
		local current = client.send_queue[1]
		local offset = client.send_offset
		local chunk = current:sub(offset)

		local ok, sent_or_error = pcall(connection.send, connection, chunk)
		if not ok then
			log.warn("send failed (%s): %s", client_id(connection), sent_or_error)
			connection:close()
			break
		end

		local sent = tonumber(sent_or_error) or 0
		if sent <= 0 then
			break
		end
		sent_this_tick = sent_this_tick + sent

		client.send_offset = offset + sent
		if client.send_offset > #current then
			table.remove(client.send_queue, 1)
			client.send_offset = 1
		else
			break
		end
	end

	if client.close_after_flush and #client.send_queue == 0 and
		connection.pending_send_bytes == 0 and not connection.stream_active and connection.is_open then
		connection:close()
	end
end

network_session.parse_positive_integer = parse_positive_integer
network_session.client_id = client_id
network_session.get_player_connection = get_player_connection
network_session.resolve_client_player_from_hello = resolve_client_player_from_hello
network_session.apply_bound_player = apply_bound_player
network_session.reset_client_sync_state = reset_client_sync_state
network_session.clear_client_binding = clear_client_binding
network_session.validate_bound_player = validate_bound_player
network_session.refresh_client_player_binding = refresh_client_player_binding
network_session.suppress_player_timeout_while_syncing = suppress_player_timeout_while_syncing
network_session.next_sync_generation = next_sync_generation
network_session.clear_client_state = clear_client_state
network_session.enqueue_bytes = enqueue_bytes
network_session.enqueue_frame = enqueue_frame
network_session.flush_send_queue = flush_send_queue
network_session.SERVER_EVENT_ID_START = SERVER_EVENT_ID_START
network_session.SERVER_EVENT_ID_MAX = SERVER_EVENT_ID_MAX

return network_session
