local json = require("main.json")

local log = require("main.src.log")
local event_codec = require("main.src.event_codec")
local protocol = require("main.src.protocol")
local sync_paths = require("main.src.sync_paths")
local sync_snapshot = require("main.src.sync_snapshot")
local threaded_tcp_codec = require("main.src.threaded_tcp_codec")
local threaded_tcp_server = require("main.src.threaded_tcp_server")
local udp_events = require("main.src.udp_events")
local world_mutations = require("main.src.world_mutations")

local M = {}
local HEARTBEAT_TIMEOUT_SECONDS = 60
local SERVER_EVENT_ID_MIN = 0x80000000
local SERVER_EVENT_ID_MAX = 0xFFFFFFFF
local MAX_EVENT_LOG_DETAIL_BYTES = 512
local MAX_REPORTED_EVENT_FAILURE_HASHES = 256
local VALID_CLIENT_EVENT_STATUSES = {
	decode_error = true,
	handler_error = true,
	no_handler = true,
	nothing_handled = true,
	processed = true,
	runtime_unavailable = true,
}
local RENAMED_CLIENT_FIELDS = {
	activeBundleTransfer = "active_bundle_transfer",
	activeFileTransfer = "active_file_transfer",
	awaitingResults = "awaiting_results",
	closeAfterFlush = "close_after_flush",
	earlyResults = "early_results",
	helloPayload = "hello_payload",
	pendingBundleRequests = "pending_bundle_requests",
	pendingEvents = "pending_events",
	pendingFileRequests = "pending_file_requests",
	pendingResults = "pending_results",
	recentCompleted = "recent_completed",
	recvBuffer = "receive_buffer",
	sendOffset = "send_offset",
	sendQueue = "send_queue",
	udpEventsReady = "udp_events_ready",
	udpPendingAckOrder = "udp_pending_ack_order",
	udpPendingAckSet = "udp_pending_ack_set",
	udpPendingAckStart = "udp_pending_ack_start",
	udpSendQueue = "udp_send_queue",
}
local disconnect_other_connections_for_player
local logged_legacy_tcp_event_frame = false
local next_tcp_bind_tick = 0
local unpack_values = table.unpack or unpack

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

local function parse_message_id(value)
	if type(value) == "number" then
		local id = math.floor(value)
		if id > 0 then
			return id
		end
		return nil
	end

	if type(value) == "string" and value ~= "" then
		local parsed = tonumber(value)
		if parsed then
			local id = math.floor(parsed)
			if id > 0 then
				return id
			end
		end
	end

	return nil
end

local function client_id(connection)
	return string.format("%s:%s", tostring(connection.address), tostring(connection.port))
end

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

local function migrate_client_fields(client)
	for old_name, new_name in pairs(RENAMED_CLIENT_FIELDS) do
		if client[new_name] == nil and client[old_name] ~= nil then
			client[new_name] = client[old_name]
		end
		client[old_name] = nil
	end
end

local function ensure_event_tracking_tables(client)
	migrate_client_fields(client)
	client.awaiting_results = client.awaiting_results or {}
	client.early_results = client.early_results or {}
	client.recent_completed = client.recent_completed or {}
	client.pending_results = client.pending_results or {}
end

local function should_log_event_failure(state, connection, event_hash)
	local client = state.clients[connection]
	if not client or event_hash == nil then
		return true
	end

	client.reported_failure_event_hashes = client.reported_failure_event_hashes or {}
	if client.reported_failure_event_hashes[event_hash] then
		return false
	end
	if (client.reported_failure_event_hash_count or 0) >= MAX_REPORTED_EVENT_FAILURE_HASHES then
		return false
	end

	client.reported_failure_event_hashes[event_hash] = true
	client.reported_failure_event_hash_count = (client.reported_failure_event_hash_count or 0) + 1
	return true
end

local function sanitize_log_text(value)
	local ok, text = pcall(tostring, value)
	if not ok then
		return "<unprintable>"
	end

	text = text:gsub("[^ -~]", "?")
	if #text > MAX_EVENT_LOG_DETAIL_BYTES then
		text = text:sub(1, MAX_EVENT_LOG_DETAIL_BYTES - 3) .. "..."
	end
	return text
end

local function normalize_client_event_count(value)
	if type(value) ~= "number" or value ~= value or value < 0 then
		return 0
	end
	return math.min(math.floor(value), 0xFFFF)
end

local function mark_event_recently_completed(state, client, message_id)
	local keep_ticks = math.max(120, tonumber(state.config.eventProcessTimeoutTicks) or 180)
	client.recent_completed[message_id] = state.tick + keep_ticks
end

local function cleanup_recent_completions(state, client)
	for message_id, expiry_tick in pairs(client.recent_completed) do
		if state.tick >= expiry_tick then
			client.recent_completed[message_id] = nil
		end
	end
end

local function log_event_result(state, connection, name, event_hash, message_id, result)
	local args = result and result.args or nil
	local claimed_status = (args and args[1]) or result and result.status
	local claimed_detail = (args and args[4]) or result and result.detail
	local status = type(claimed_status) == "string" and claimed_status or ""
	local handled = normalize_client_event_count((args and args[2]) or result and result.handled)
	local errors = normalize_client_event_count((args and args[3]) or result and result.errors)
	local detail = type(claimed_detail) == "string" and sanitize_log_text(claimed_detail) or ""
	if not VALID_CLIENT_EVENT_STATUSES[status] then
		status = "invalid_client_status"
	end

	if status == "processed" and errors == 0 then
		if state.config.eventDebugLogSuccess then
			log.info(
				"client-claimed event processed [UNTRUSTED_CLIENT_CLAIM]: name=%s id=%s client=%s handlers=%s",
				name or "?",
				message_id,
				client_id(connection),
				handled
			)
		end
	else
		if not should_log_event_failure(state, connection, event_hash) then
			return
		end

		log.warn(
			"client-claimed event failure [UNTRUSTED]: name=%s id=%s client=%s status=%s handlers=%s errors=%s detail=%s",
			name or "?",
			message_id,
			client_id(connection),
			status ~= "" and status or "unknown",
			handled,
			errors,
			detail ~= "" and detail or "-"
		)
	end
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

local function resolve_client_player_from_hello(_, connection, payload)
	if not connection then
		return nil, "missing_connection"
	end

	if type(payload) ~= "table" then
		return nil, "invalid_hello_payload"
	end

	local phone_number = parse_positive_integer(payload.phoneNumber or payload.phone)
	local sub_rosa_id = parse_positive_integer(payload.subRosaID or payload.subrosaID or payload.subrosa_id)
	if not phone_number and not sub_rosa_id then
		return nil, "missing_bind_claims"
	end

	local best_player = nil
	local remote_address = tostring(connection.address)

	for _, player in ipairs(players.getNonBots()) do
		if not player.isBot and player.connection and tostring(player.connection.address) == remote_address then
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
	connection:discard_pending_sends()
	close_client_transfer(client)
	client.pending_file_requests = {}
	client.pending_bundle_requests = {}
	client.send_queue = {}
	client.send_offset = 1
	client.sync_state = client.hello and "capable" or "connected"
	client.ready_generation = 0
	client.ready_manifest_hash = nil
	if preserve_udp_state then
		client.udp_events_ready = false
	else
		client.pending_events = {}
		client.pending_results = {}
		client.awaiting_results = {}
		client.early_results = {}
		client.recent_completed = {}
		udp_events.reset_client(client)
	end
end

local function clear_client_binding(connection, client)
	reset_client_sync_state(connection, client)
	client.player = nil
	client.bound = false
end

local function validate_bound_player(connection, client)
	if not connection or not client or not client.player then
		return nil
	end

	local player = client.player
	local player_connection = player.connection
	local invalid = player.isBot or not player_connection
		or tostring(player_connection and player_connection.address) ~= tostring(connection.address)
	if client.hello_payload then
		local phone_number = parse_positive_integer(client.hello_payload.phoneNumber or client.hello_payload.phone)
		local sub_rosa_id =
			parse_positive_integer(client.hello_payload.subRosaID or client.hello_payload.subrosaID or client.hello_payload.subrosa_id)
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
	local body = {
		type = frame_type,
		payload = payload or {},
	}

	return enqueue_bytes(state, connection, json.encode(body) .. "\n")
end

local function bundle_metadata_list(state)
	local bundles = {}
	if type(state.sync_bundles) ~= "table" then
		return bundles
	end

	for i = 1, #state.sync_bundles do
		local bundle = state.sync_bundles[i]
		bundles[#bundles + 1] = {
			id = bundle.id,
			kind = bundle.kind,
			size = bundle.size,
			archiveSha256 = bundle.archive_sha256,
			contentSha256 = bundle.content_sha256,
			files = bundle.files,
		}
	end

	return bundles
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

local function queue_sync_file(state, connection, relative_path)
	local client = state.clients[connection]
	if not client then
		return
	end

	local is_script = state.scripts_by_path[relative_path] ~= nil
	local is_asset_file = state.asset_files_by_path[relative_path] ~= nil

	local valid_path = false
	if is_script then
		valid_path = sync_paths.is_safe_script(relative_path)
	elseif is_asset_file then
		valid_path = sync_paths.is_safe_asset(relative_path)
	end

	if not valid_path then
		enqueue_frame(state, connection, "ERROR_REPORT", {
			error = "invalid FILE_REQ path",
			path = relative_path,
		})
		return
	end

	if client.active_file_transfer and client.active_file_transfer.path == relative_path then
		return
	end

	for _, queued_path in ipairs(client.pending_file_requests) do
		if queued_path == relative_path then
			return
		end
	end

	table.insert(client.pending_file_requests, relative_path)
end

local function queue_sync_bundle(state, connection, bundle_id)
	local client = state.clients[connection]
	if not client or type(bundle_id) ~= "string" or bundle_id == "" then
		return
	end

	local bundle = state.sync_bundles_by_id and state.sync_bundles_by_id[bundle_id] or nil
	if not bundle or type(bundle.archive) ~= "string" or bundle.archive == "" then
		enqueue_frame(state, connection, "ERROR_REPORT", {
			error = "invalid BUNDLE_REQ id",
			id = bundle_id,
		})
		return
	end

	if client.active_bundle_transfer and client.active_bundle_transfer.id == bundle_id then
		return
	end

	for _, queued_id in ipairs(client.pending_bundle_requests) do
		if queued_id == bundle_id then
			return
		end
	end

	table.insert(client.pending_bundle_requests, bundle_id)
end

local function start_next_file_transfer(state, connection, client)
	if client.active_file_transfer or #client.pending_file_requests == 0 then
		return false
	end

	local relative_path = table.remove(client.pending_file_requests, 1)
	local full_path = nil
	local script_record = state.scripts_by_path[relative_path]
	local asset_record = state.asset_files_by_path[relative_path]
	if script_record then
		full_path = script_record.source_path
	elseif asset_record then
		full_path = asset_record.source_path
	end

	if not full_path then
		enqueue_frame(state, connection, "ERROR_REPORT", {
			error = "path not found in sync index",
			path = relative_path,
		})
		return false
	end

	local file = io.open(full_path, "rb")
	if not file then
		enqueue_frame(state, connection, "ERROR_REPORT", {
			error = "file read failed",
			path = relative_path,
		})
		return false
	end

	client.active_file_transfer = {
		path = relative_path,
		file = file,
	}
	return true
end

local function start_next_bundle_transfer(state, connection, client)
	if client.active_bundle_transfer or #client.pending_bundle_requests == 0 then
		return false
	end

	local bundle_id = table.remove(client.pending_bundle_requests, 1)
	local bundle = state.sync_bundles_by_id and state.sync_bundles_by_id[bundle_id] or nil
	if not bundle or type(bundle.archive) ~= "string" then
		enqueue_frame(state, connection, "ERROR_REPORT", {
			error = "bundle not found in sync index",
			id = bundle_id,
		})
		return false
	end

	local end_frame = json.encode({ type = "BUNDLE_END", payload = { id = bundle_id } }) .. "\n"
	local started = connection:start_bundle(
		bundle_id,
		bundle.archive_sha256,
		bundle.archive,
		end_frame
	)
	if not started then
		table.insert(client.pending_bundle_requests, 1, bundle_id)
		return false
	end

	client.active_bundle_transfer = { id = bundle_id }
	return true
end

local function pump_file_transfer(state, connection)
	local client = state.clients[connection]
	if not client or not connection.is_open then
		return
	end

	local chunk_size = math.max(256, state.config.fileChunkSize)
	local chunk_budget = math.max(1, state.config.maxFileChunksPerTick)
	local max_queued_send_frames = math.max(8, state.config.maxQueuedSendFrames)

	local sent_chunks = 0
	while sent_chunks < chunk_budget do
		if #client.send_queue >= max_queued_send_frames then
			return
		end

		if not client.active_file_transfer and not start_next_file_transfer(state, connection, client) then
			return
		end

		local transfer = client.active_file_transfer
		if not transfer then
			return
		end

		local read_ok, chunk_or_error = pcall(transfer.file.read, transfer.file, chunk_size)
		if not read_ok then
			enqueue_frame(state, connection, "ERROR_REPORT", {
				error = "file read failed",
				path = transfer.path,
			})
			pcall(function()
				transfer.file:close()
			end)
			client.active_file_transfer = nil
			return
		end

		if type(chunk_or_error) == "string" and #chunk_or_error > 0 then
			local binary_frame = threaded_tcp_codec.encode_binary_frame(
				"FILE_CHUNK",
				string.pack(">I2", #transfer.path) .. transfer.path .. chunk_or_error
			)
			if not binary_frame or not enqueue_bytes(state, connection, binary_frame) then
				return
			end
			sent_chunks = sent_chunks + 1
		else
			pcall(function()
				transfer.file:close()
			end)
			client.active_file_transfer = nil
			if not enqueue_frame(state, connection, "FILE_END", {
				path = transfer.path,
			}) then
				return
			end
		end
	end
end

local function pump_bundle_transfer(state, connection)
	local client = state.clients[connection]
	if not client or not connection.is_open then
		return
	end

	if client.active_bundle_transfer and not connection.stream_active then
		client.active_bundle_transfer = nil
	end
	if not client.active_bundle_transfer then
		start_next_bundle_transfer(state, connection, client)
	end
end

local function handle_client_event(state, connection, message)
	local event_hash = message and message.event_hash
	local message_id = message and message.message_id
	local args = message and message.args or { n = 0 }
	local registry = state.event_handlers_by_hash and state.event_handlers_by_hash[event_hash] or nil
	local event_name = registry and registry.name or udp_events.format_event_hash(event_hash)
	if not registry or not registry.callbacks or #registry.callbacks == 0 then
		if should_log_event_failure(state, connection, event_hash) then
			log.warn(
				"event rejected [NOTHING_HANDLED_EVENT_ON_SERVER]: hash=%s id=%s client=%s",
				tostring(event_name),
				tostring(message_id),
				client_id(connection)
			)
		end
		return {
			status = "nothing_handled",
			handled = 0,
			errors = 0,
			detail = "No server handlers registered for event",
			event_name = event_name,
			event_hash = event_hash,
		}
	end

	local handled = 0
	local errors = 0
	local detail = ""
	for _, fn in ipairs(registry.callbacks) do
		local ok, err = pcall(fn, connection, unpack_values(args, 1, args.n or 0))
		handled = handled + 1
		if not ok then
			errors = errors + 1
			detail = "Server event handler failed"
			if should_log_event_failure(state, connection, event_hash) then
				log.warn(
					"server Lua event handler failed: name=%s client=%s detail=%s",
					event_name,
					client_id(connection),
					sanitize_log_text(err)
				)
			end
		end
	end

	local status = errors == 0 and "processed" or "handler_error"
	return {
		status = status,
		handled = handled,
		errors = errors,
		detail = detail,
		event_name = event_name,
		event_hash = event_hash,
	}
end

local function queue_reliable_udp_event(state, connection, name, event_hash, argument_bytes)
	local client = state.clients[connection]
	if not client or not connection.is_open or not client.hello or not client.bound then
		return false
	end

	if type(name) ~= "string" or name == "" then
		return false
	end

	state.event_hashes_by_name = state.event_hashes_by_name or {}
	if not event_hash then
		event_hash = state.event_hashes_by_name[name]
		if not event_hash then
			event_hash = udp_events.hash_event_name(name)
			if not event_hash then
				return false
			end
			state.event_hashes_by_name[name] = event_hash
		end
	end

	if type(argument_bytes) ~= "string" then
		local encoded, encode_error
		if type(argument_bytes) == "table" then
			local count = tonumber(argument_bytes.n)
			if count == nil or count < 0 then
				count = #argument_bytes
			end
			encoded, encode_error = event_codec.encode_args(unpack_values(argument_bytes, 1, count))
		else
			encoded, encode_error = event_codec.encode_args()
		end
		if not encoded then
			log.warn("failed to encode UDP event payload (%s): %s", name, tostring(encode_error))
			return false
		end
		argument_bytes = encoded
	end

	local message_id = state.next_event_id
	local bytes, encode_error = udp_events.encode_reliable_event(event_hash, message_id, argument_bytes)
	if not bytes then
		log.warn("failed to encode UDP event (%s): %s", name, tostring(encode_error))
		return false
	end
	if #bytes > state.config.maxEventBytes then
		log.warn("event too large; dropping (%s)", name)
		return false
	end

	state.next_event_id = state.next_event_id + 1
	if state.next_event_id > SERVER_EVENT_ID_MAX then
		state.next_event_id = SERVER_EVENT_ID_MIN
	end

	udp_events.enqueue(client, bytes)

	client.pending_events[message_id] = {
		bytes = bytes,
		attempts = 1,
		next_retry_tick = state.tick + state.config.eventRetryBaseTicks,
		name = name,
		event_hash = event_hash,
		created_tick = state.tick,
		last_retry_tick = state.tick,
	}

	return true
end

local function queue_reliable_udp_result(state, connection, name, message_id, event_hash, payload_bytes)
	local client = state.clients[connection]
	if not client or not connection.is_open or not client.hello or not client.bound then
		return false
	end

	if type(name) ~= "string" or name == "" then
		return false
	end

	local normalized_message_id = parse_message_id(message_id)
	if not normalized_message_id then
		return false
	end

	state.event_hashes_by_name = state.event_hashes_by_name or {}
	if not event_hash then
		event_hash = state.event_hashes_by_name[name]
		if not event_hash then
			event_hash = udp_events.hash_event_name(name)
			if not event_hash then
				return false
			end
			state.event_hashes_by_name[name] = event_hash
		end
	end

	if type(payload_bytes) ~= "string" then
		return false
	end

	local bytes, encode_error = udp_events.encode_reliable_result(event_hash, normalized_message_id, payload_bytes)
	if not bytes then
		log.warn("failed to encode UDP result (%s): %s", name, tostring(encode_error))
		return false
	end
	if #bytes > state.config.maxEventBytes then
		log.warn("result too large; dropping (%s)", name)
		return false
	end

	udp_events.enqueue(client, bytes)

	client.pending_results = client.pending_results or {}
	client.pending_results[normalized_message_id] = {
		bytes = bytes,
		attempts = 1,
		next_retry_tick = state.tick + state.config.eventRetryBaseTicks,
		name = name,
		event_hash = event_hash,
		created_tick = state.tick,
		last_retry_tick = state.tick,
	}

	return true
end

local function log_legacy_tcp_event_frame(frame_type)
	if logged_legacy_tcp_event_frame then
		return
	end

	logged_legacy_tcp_event_frame = true
	log.warn("ignoring legacy TCP event-lane frame (%s)", tostring(frame_type))
end

local function handle_reliable_event_ack_batch_payload(state, connection, message_ids)
	local client = state.clients[connection]
	if client and type(message_ids) == "table" then
		ensure_event_tracking_tables(client)
		for i = 1, #message_ids do
			local message_id = parse_message_id(message_ids[i])
			if message_id then
				local pending = client.pending_events[message_id]
				if pending then
					client.pending_events[message_id] = nil
					client.awaiting_results[message_id] = {
						name = pending.name,
						event_hash = pending.event_hash,
						acked_tick = state.tick,
						deadline_tick = state.tick + state.config.eventProcessTimeoutTicks,
					}

					local early = client.early_results[message_id]
					if early then
						client.early_results[message_id] = nil
						local tracked_name = client.awaiting_results[message_id] and client.awaiting_results[message_id].name or pending.name
						client.awaiting_results[message_id] = nil
						mark_event_recently_completed(state, client, message_id)
						log_event_result(state, connection, tracked_name, pending.event_hash, message_id, early)
					end
				elseif client.pending_results[message_id] then
					client.pending_results[message_id] = nil
					mark_event_recently_completed(state, client, message_id)
				elseif client.awaiting_results[message_id] then
					-- Duplicate ACK while waiting for processing result; ignore.
				elseif client.recent_completed[message_id] then
					-- Late ACK for a message we've already finalized; ignore.
				else
					log.warn("received EVENT_ACK for unknown id=%s from %s", message_id, client_id(connection))
				end
			end
		end
	end
end

local function handle_reliable_event_result_payload(state, connection, message)
	local client = state.clients[connection]
	if not client then
		return
	end
	ensure_event_tracking_tables(client)

	local message_id = parse_message_id(message and message.message_id)
	if not message_id then
		log.warn("received EVENT_RESULT with invalid message_id from %s", client_id(connection))
		return
	end

	local args = message and message.args or { n = 0 }
	local tracked = client.awaiting_results[message_id]
	local result = {
		event_hash = message and message.event_hash,
		status = tostring(args[1] or ""),
		handled = tonumber(args[2]) or 0,
		errors = tonumber(args[3]) or 0,
		detail = tostring(args[4] or ""),
		args = args,
	}

	if not tracked then
		if client.pending_events[message_id] then
			client.early_results[message_id] = result
			return
		end
		if client.recent_completed[message_id] then
			return
		end
		log.warn("received EVENT_RESULT for unknown id=%s from %s", message_id, client_id(connection))
		return
	end

	client.awaiting_results[message_id] = nil
	client.early_results[message_id] = nil
	mark_event_recently_completed(state, client, message_id)
	log_event_result(state, connection, tracked.name, tracked.event_hash, message_id, result)
end

local function queue_item_types_sync_frame(state, connection, payload)
	local client = state.clients[connection]
	if not client or not connection.is_open or not client.hello then
		return false
	end

	if type(payload) ~= "table" then
		return false
	end

	if type(payload.itemTypes) ~= "table" or #payload.itemTypes == 0 then
		return false
	end

	if type(payload.binRaw) ~= "string" or payload.binRaw == "" then
		return false
	end

	local estimated_size = 6 + (#payload.itemTypes * 4) + #payload.binRaw
	if estimated_size > state.config.maxEventBytes then
		log.warn("item type sync payload too large; dropping")
		return false
	end

	local segments = {
		string.pack(">I2I2I2", payload.version or 1, payload.itemTypeSize or 0, #payload.itemTypes),
	}
	for i = 1, #payload.itemTypes do
		local entry = payload.itemTypes[i]
		segments[#segments + 1] = string.pack(">I2I2", entry.index or 0, entry.sourceIndex or 0)
	end
	segments[#segments + 1] = payload.binRaw

	local binary_frame = threaded_tcp_codec.encode_binary_frame("ITEM_TYPES_SYNC", table.concat(segments))
	if not binary_frame then
		return false
	end

	return enqueue_bytes(state, connection, binary_frame)
end

local function queue_vehicle_types_sync_frame(state, connection, payload)
	local client = state.clients[connection]
	if not client or not connection.is_open or not client.hello then
		return false
	end

	if type(payload) ~= "table" then
		return false
	end

	if type(payload.vehicleTypes) ~= "table" or #payload.vehicleTypes == 0 then
		return false
	end

	return enqueue_frame(state, connection, "VEHICLE_TYPES_SYNC", payload)
end

local function queue_item_type_model_frame(state, connection, index, model_name)
	local client = state.clients[connection]
	if not client or not connection.is_open or not client.hello then
		return false
	end

	return enqueue_frame(state, connection, "ITEM_TYPE_MODEL", {
		index = index,
		model = model_name,
	})
end

local function queue_item_type_itm_frame(state, connection, index, itm_path)
	local client = state.clients[connection]
	if not client or not connection.is_open or not client.hello then
		return false
	end

	return enqueue_frame(state, connection, "ITEM_TYPE_ITM", {
		index = index,
		itm = itm_path,
	})
end

local function queue_item_type_it3_frame(state, connection, index, it3_path)
	local client = state.clients[connection]
	if not client or not connection.is_open or not client.hello then
		return false
	end

	return enqueue_frame(state, connection, "ITEM_TYPE_IT3", {
		index = index,
		it3 = it3_path,
	})
end

local function queue_vehicle_type_model_frame(state, connection, index, model_name)
	local client = state.clients[connection]
	if not client or not connection.is_open or not client.hello then
		return false
	end

	return enqueue_frame(state, connection, "VEHICLE_TYPE_MODEL", {
		index = index,
		model = model_name,
	})
end

local function queue_item_type_icon_frame(state, connection, index, icon_path)
	local client = state.clients[connection]
	if not client or not connection.is_open or not client.hello then
		return false
	end

	return enqueue_frame(state, connection, "ITEM_TYPE_ICON", {
		index = index,
		icon = icon_path,
	})
end

local function queue_item_type_texture_frame(state, connection, index, texture_assignment)
	local client = state.clients[connection]
	if not client or not connection.is_open or not client.hello then
		return false
	end

	if type(texture_assignment) ~= "table" then
		return false
	end

	local payload = {
		index = index,
	}

	if texture_assignment.kind == "builtin" then
		payload.builtinTexture = texture_assignment.builtin
	elseif texture_assignment.kind == "file" then
		payload.texture = texture_assignment.file
	else
		return false
	end

	return enqueue_frame(state, connection, "ITEM_TYPE_TEXTURE", payload)
end

local function queue_item_type_fire_sounds_frame(state, connection, index, sound_assignment)
	local client = state.clients[connection]
	if not client or not connection.is_open or not client.hello then
		return false
	end

	if type(sound_assignment) ~= "table" then
		return false
	end

	local payload = {
		index = index,
	}

	if sound_assignment.kind == "builtin" then
		payload.builtinFireSound = sound_assignment.builtin
	elseif sound_assignment.kind == "files" then
		payload.fireSounds = sound_assignment.files
	else
		return false
	end

	return enqueue_frame(state, connection, "ITEM_TYPE_FIRE_SOUNDS", payload)
end

local function queue_vehicle_type_audio_frame(state, connection, index, audio_reference)
	local client = state.clients[connection]
	if not client or not connection.is_open or not client.hello then
		return false
	end

	return enqueue_frame(state, connection, "VEHICLE_TYPE_AUDIO", {
		index = index,
		audio = audio_reference,
	})
end

local function queue_human_model_frame(state, connection, index, assignment)
	local client = state.clients[connection]
	if not client or not connection.is_open or not client.hello then
		return false
	end

	if type(assignment) ~= "table" then
		return false
	end

	local male = assignment.male
	local female = assignment.female
	if type(male) ~= "string" or male == "" or type(female) ~= "string" or female == "" then
		return false
	end

	return enqueue_frame(state, connection, "HUMAN_MODEL_DEF", {
		index = index,
		male = male,
		female = female,
	})
end

local function send_initial_custom_item_sync(state, connection)
	local item_types = require("main.src.item_types")
	if type(item_types.build_sync_payload) == "function" then
		local ok, payload_or_error = pcall(item_types.build_sync_payload, state)
		if ok then
			local payload = payload_or_error
			if type(payload) == "table" and type(payload.itemTypes) == "table" and #payload.itemTypes > 0 then
				queue_item_types_sync_frame(state, connection, payload)
			end

			local model_assignments = state.item_type_model_assignments
			if type(model_assignments) == "table" then
				for idx, model_name in pairs(model_assignments) do
					queue_item_type_model_frame(state, connection, idx, model_name)
				end
			end

			if type(payload) == "table" and type(payload.itemTypes) == "table" and #payload.itemTypes > 0 then
				local itm_assignments = state.item_type_itm_assignments
				if type(itm_assignments) == "table" then
					for idx, itm_path in pairs(itm_assignments) do
						queue_item_type_itm_frame(state, connection, idx, itm_path)
					end
				end

				local it3_assignments = state.item_type_it3_assignments
				if type(it3_assignments) == "table" then
					for idx, it3_path in pairs(it3_assignments) do
						queue_item_type_it3_frame(state, connection, idx, it3_path)
					end
				end

				local icon_assignments = state.item_type_icon_assignments
				if type(icon_assignments) == "table" then
					for idx, icon_path in pairs(icon_assignments) do
						queue_item_type_icon_frame(state, connection, idx, icon_path)
					end
				end

				local texture_assignments = state.item_type_texture_assignments
				if type(texture_assignments) == "table" then
					for idx, texture_assignment in pairs(texture_assignments) do
						queue_item_type_texture_frame(state, connection, idx, texture_assignment)
					end
				end

				local fire_sound_assignments = state.item_type_fire_sound_assignments
				if type(fire_sound_assignments) == "table" then
					for idx, sound_assignment in pairs(fire_sound_assignments) do
						queue_item_type_fire_sounds_frame(state, connection, idx, sound_assignment)
					end
				end
			end
		else
			log.warn("failed building custom item type sync payload: %s", tostring(payload_or_error))
		end
	end

	local human_model_assignments = state.human_model_assignments
	if type(human_model_assignments) == "table" then
		for idx, assignment in pairs(human_model_assignments) do
			queue_human_model_frame(state, connection, idx, assignment)
		end
	end
end

local function send_initial_custom_vehicle_sync(state, connection)
	local vehicle_types = require("main.src.vehicle_types")
	if type(vehicle_types.build_sync_payload) == "function" then
		local ok, payload_or_error = pcall(vehicle_types.build_sync_payload, state)
		if ok then
			local payload = payload_or_error
			if type(payload) == "table" and type(payload.vehicleTypes) == "table" and #payload.vehicleTypes > 0 then
				queue_vehicle_types_sync_frame(state, connection, payload)

				local model_assignments = state.vehicle_type_model_assignments
				if type(model_assignments) == "table" then
					for idx, model_name in pairs(model_assignments) do
						queue_vehicle_type_model_frame(state, connection, idx, model_name)
					end
				end

				local audio_assignments = state.vehicle_type_audio_assignments
				if type(audio_assignments) == "table" then
					for idx, audio_reference in pairs(audio_assignments) do
						queue_vehicle_type_audio_frame(state, connection, idx, audio_reference)
					end
				end
			end
		else
			log.warn("failed building custom vehicle type sync payload: %s", tostring(payload_or_error))
		end
	end
end

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

	client.udp_token = udp_token
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
		client.player = nil
		client.bound = false
	end

	enqueue_frame(state, connection, "HELLO_ACK", {
		protocol = protocol.VERSION,
		port = server.port,
		udpToken = udp_token,
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

	if #state.sync_bundles == 0 and #state.scripts == 0 and #state.asset_files == 0 then
		sync_snapshot.discover(state)
	end
	enqueue_frame(state, connection, "INDEX_RES", {
		bundles = bundle_metadata_list(state),
		loadedLevel = state.loaded_level,
		persistentMode = state.persistent_mode,
		runtimeID = state.runtime_id,
		syncGeneration = state.sync_generation,
		manifestHash = state.manifest_hash,
	})
	client.sync_state = "syncing"
end

local function handle_file_request(state, connection, payload)
	if require_hello(state, connection, "FILE_REQ") then
		queue_sync_file(state, connection, payload.path)
	end
end

local function handle_bundle_request(state, connection, payload)
	if require_hello(state, connection, "BUNDLE_REQ") then
		queue_sync_bundle(state, connection, payload.id)
	end
end

local function handle_legacy_event(_, _, _, frame_type)
	log_legacy_tcp_event_frame(frame_type)
end

local function handle_sync_ready(state, connection, payload)
	local client = state.clients[connection]
	local generation = math.floor(tonumber(payload.syncGeneration) or 0)
	local runtime_id = tostring(payload.runtimeID or "")
	local manifest_hash = tostring(payload.manifestHash or "")
	if client and client.hello
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

	local retry_tick = state.tick + state.config.eventRetryBaseTicks
	local completion_expiry =
		state.tick + math.max(120, tonumber(state.config.eventProcessTimeoutTicks) or 180)
	for _, pending in pairs(client.pending_events or {}) do
		pending.next_retry_tick = retry_tick
	end
	for _, pending in pairs(client.pending_results or {}) do
		pending.next_retry_tick = retry_tick
	end
	for _, pending in pairs(client.awaiting_results or {}) do
		pending.deadline_tick = state.tick + state.config.eventProcessTimeoutTicks
	end
	for message_id in pairs(client.recent_completed or {}) do
		client.recent_completed[message_id] = completion_expiry
	end
	client.udp_events_ready = true
	world_mutations.sync(state, rawget(_G, "src"), client.player)
end

local function handle_error_report(_, connection, payload)
	log.warn("client error (%s): %s", client_id(connection), tostring(payload.error))
end

local FRAME_HANDLERS = {
	SRC_PING = handle_ping,
	HELLO = handle_hello,
	INDEX_REQ = handle_index_request,
	FILE_REQ = handle_file_request,
	BUNDLE_REQ = handle_bundle_request,
	EVENT = handle_legacy_event,
	SYNC_READY = handle_sync_ready,
	EVENT_ACK = handle_legacy_event,
	EVENT_RESULT = handle_legacy_event,
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

local function process_buffered_frames(state, connection, client, frame_budget)
	local processed = 0
	while processed < frame_budget do
		local newline_position = client.receive_buffer:find("\n", 1, true)
		if not newline_position then
			break
		end

		local line = client.receive_buffer:sub(1, newline_position - 1)
		client.receive_buffer = client.receive_buffer:sub(newline_position + 1)

		if line ~= "" then
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
		local ok, data_or_error = pcall(connection.receive, connection, read_size)
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

		client.receive_buffer = client.receive_buffer .. data
		frames_this_tick = frames_this_tick + process_buffered_frames(
			state,
			connection,
			client,
			max_frames_per_tick - frames_this_tick
		)
	end
end

local function process_pending_retries(state, connection)
	local client = state.clients[connection]
	if not client or client.udp_events_ready ~= true then
		return
	end
	ensure_event_tracking_tables(client)
	cleanup_recent_completions(state, client)

	local max_attempts = state.config.eventRetryMaxAttempts
	local base_ticks = state.config.eventRetryBaseTicks

	for message_id, pending in pairs(client.pending_events) do
		if state.tick >= pending.next_retry_tick then
			if pending.attempts >= max_attempts then
				log.warn(
					"event delivery failed [SERVER_NEVER_RECEIVED_IT]: name=%s id=%s client=%s attempts=%s",
					pending.name or "?",
					message_id,
					client_id(connection),
					pending.attempts
				)
				client.pending_events[message_id] = nil
				client.early_results[message_id] = nil
				mark_event_recently_completed(state, client, message_id)
			else
				pending.attempts = pending.attempts + 1
				pending.next_retry_tick = state.tick + base_ticks * (2 ^ (pending.attempts - 1))
				pending.last_retry_tick = state.tick
				udp_events.enqueue(client, pending.bytes)
			end
		end
	end

	for message_id, pending in pairs(client.pending_results) do
		if state.tick >= pending.next_retry_tick then
			if pending.attempts >= max_attempts then
				log.warn(
					"result delivery failed [SERVER_NEVER_RECEIVED_IT]: name=%s id=%s client=%s attempts=%s",
					pending.name or "?",
					message_id,
					client_id(connection),
					pending.attempts
				)
				client.pending_results[message_id] = nil
				mark_event_recently_completed(state, client, message_id)
			else
				pending.attempts = pending.attempts + 1
				pending.next_retry_tick = state.tick + base_ticks * (2 ^ (pending.attempts - 1))
				pending.last_retry_tick = state.tick
				udp_events.enqueue(client, pending.bytes)
			end
		end
	end

	for message_id, pending in pairs(client.awaiting_results) do
		if state.tick >= pending.deadline_tick then
			log.warn(
				"event processing timeout [SRC_OR_SRCC_NEVER_PROCESSED_IT]: name=%s id=%s client=%s (acked transport, no process result)",
				pending.name or "?",
				message_id,
				client_id(connection)
			)
			client.awaiting_results[message_id] = nil
			client.early_results[message_id] = nil
			mark_event_recently_completed(state, client, message_id)
		end
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

		state.clients[connection] = {
			receive_buffer = "",
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
			pending_events = {},
			pending_results = {},
			awaiting_results = {},
			early_results = {},
			recent_completed = {},
			close_after_flush = false,
			last_heartbeat_at = os.realClock(),
			sync_state = "connected",
			ready_generation = 0,
			ready_manifest_hash = nil,
		}
		udp_events.reset_client(state.clients[connection])

		log.info("TCP client connected: %s", client_id(connection))
	end
end

local function process_clients(state)
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

			suppress_player_timeout_while_syncing(client)
		end

		if connection.is_open then
			process_client_reads(state, connection)
			client.last_heartbeat_at = client.last_heartbeat_at or os.realClock()
			if os.realClock() - client.last_heartbeat_at >= HEARTBEAT_TIMEOUT_SECONDS then
				log.warn("SRC heartbeat timed out: %s", client_id(connection))
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

function M.on_client_event(state, name, fn)
	assert(type(name) == "string", "src.onClientEvent(name, fn): name must be string")
	assert(type(fn) == "function", "src.onClientEvent(name, fn): fn must be function")

	state.event_handlers = state.event_handlers or {}
	state.event_handlers_by_hash = state.event_handlers_by_hash or {}
	state.event_hashes_by_name = state.event_hashes_by_name or {}

	local event_hash = state.event_hashes_by_name[name]
	if not event_hash then
		event_hash = udp_events.hash_event_name(name)
		if not event_hash then
			error("src.onClientEvent(name, fn): failed to hash event name")
		end
		state.event_hashes_by_name[name] = event_hash
	end

	local registry = state.event_handlers_by_hash[event_hash]
	if registry and registry.name ~= name then
		log.warn(
			"event hash collision while registering src.onClientEvent (%s vs %s, hash=%s)",
			registry.name,
			name,
			udp_events.format_event_hash(event_hash)
		)
		return false
	end

	local callbacks = state.event_handlers[name]
	if registry then
		callbacks = registry.callbacks or callbacks
		registry.callbacks = callbacks
		state.event_handlers[name] = callbacks
	else
		if not callbacks then
			callbacks = {}
			state.event_handlers[name] = callbacks
		end
		registry = {
			name = name,
			callbacks = callbacks,
		}
		state.event_handlers_by_hash[event_hash] = registry
	end

	table.insert(callbacks, fn)
	return true
end

function M.emit_client_event(state, player, name, event_hash, argument_bytes)
	local args = argument_bytes
	if type(argument_bytes) == "string" then
		args = event_codec.decode_args(argument_bytes)
		if not args then
			return false
		end
	end

	if player == nil then
		local sent = 0
		for connection, client in pairs(state.clients) do
			if connection.is_open and client.hello and client.bound
				and validate_bound_player(connection, client) then
				if queue_reliable_udp_event(state, connection, name, event_hash, args) then
					sent = sent + 1
				end
			end
		end
		return sent
	end

	if type(player) ~= "userdata" or player.class ~= "Player" then
		return false
	end

	if player.isBot then
		return false
	end

	local connection = get_player_connection(state, player)
	if not connection then
		return false
	end

	return queue_reliable_udp_event(state, connection, name, event_hash, args)
end

function M.binary(bytes)
	return udp_events.binary(bytes)
end

function M.sync_client_item_types(state, player, payload)
	if type(payload) ~= "table" then
		return false
	end

	if player == nil then
		local sent = 0
		for connection, client in pairs(state.clients) do
			if connection.is_open and client.hello and client.bound
				and validate_bound_player(connection, client) then
				if queue_item_types_sync_frame(state, connection, payload) then
					sent = sent + 1
				end
			end
		end
		return sent
	end

	if type(player) ~= "userdata" or player.class ~= "Player" then
		return false
	end

	if player.isBot then
		return false
	end

	local connection = get_player_connection(state, player)
	if not connection then
		return false
	end

	return queue_item_types_sync_frame(state, connection, payload)
end

function M.sync_client_vehicle_types(state, player, payload)
	if type(payload) ~= "table" then
		return false
	end

	if player == nil then
		local sent = 0
		for connection, client in pairs(state.clients) do
			if connection.is_open and client.hello and client.bound
				and validate_bound_player(connection, client) then
				if queue_vehicle_types_sync_frame(state, connection, payload) then
					sent = sent + 1
				end
			end
		end
		return sent
	end

	if type(player) ~= "userdata" or player.class ~= "Player" then
		return false
	end

	if player.isBot then
		return false
	end

	local connection = get_player_connection(state, player)
	if not connection then
		return false
	end

	return queue_vehicle_types_sync_frame(state, connection, payload)
end

function M.send_item_type_icon(state, player, index, icon_path)
	if player == nil then
		local sent = 0
		for connection, client in pairs(state.clients) do
			if connection.is_open and client.hello and client.bound
				and validate_bound_player(connection, client) then
				if queue_item_type_icon_frame(state, connection, index, icon_path) then
					sent = sent + 1
				end
			end
		end
		return sent
	end

	if type(player) ~= "userdata" or player.class ~= "Player" then
		return false
	end

	if player.isBot then
		return false
	end

	local connection = get_player_connection(state, player)
	if not connection then
		return false
	end

	return queue_item_type_icon_frame(state, connection, index, icon_path)
end

function M.send_item_type_texture(state, player, index, texture_assignment)
	if player == nil then
		local sent = 0
		for connection, client in pairs(state.clients) do
			if connection.is_open and client.hello and client.bound
				and validate_bound_player(connection, client) then
				if queue_item_type_texture_frame(state, connection, index, texture_assignment) then
					sent = sent + 1
				end
			end
		end
		return sent
	end

	if type(player) ~= "userdata" or player.class ~= "Player" then
		return false
	end

	if player.isBot then
		return false
	end

	local connection = get_player_connection(state, player)
	if not connection then
		return false
	end

	return queue_item_type_texture_frame(state, connection, index, texture_assignment)
end

function M.send_item_type_fire_sounds(state, player, index, sound_assignment)
	if player == nil then
		local sent = 0
		for connection, client in pairs(state.clients) do
			if connection.is_open and client.hello and client.bound
				and validate_bound_player(connection, client) then
				if queue_item_type_fire_sounds_frame(state, connection, index, sound_assignment) then
					sent = sent + 1
				end
			end
		end
		return sent
	end

	if type(player) ~= "userdata" or player.class ~= "Player" then
		return false
	end

	if player.isBot then
		return false
	end

	local connection = get_player_connection(state, player)
	if not connection then
		return false
	end

	return queue_item_type_fire_sounds_frame(state, connection, index, sound_assignment)
end

function M.send_item_type_itm(state, player, index, itm_path)
	if player == nil then
		local sent = 0
		for connection, client in pairs(state.clients) do
			if connection.is_open and client.hello and client.bound
				and validate_bound_player(connection, client) then
				if queue_item_type_itm_frame(state, connection, index, itm_path) then
					sent = sent + 1
				end
			end
		end
		return sent
	end

	if type(player) ~= "userdata" or player.class ~= "Player" then
		return false
	end

	if player.isBot then
		return false
	end

	local connection = get_player_connection(state, player)
	if not connection then
		return false
	end

	return queue_item_type_itm_frame(state, connection, index, itm_path)
end

function M.send_item_type_it3(state, player, index, it3_path)
	if player == nil then
		local sent = 0
		for connection, client in pairs(state.clients) do
			if connection.is_open and client.hello and client.bound
				and validate_bound_player(connection, client) then
				if queue_item_type_it3_frame(state, connection, index, it3_path) then
					sent = sent + 1
				end
			end
		end
		return sent
	end

	if type(player) ~= "userdata" or player.class ~= "Player" then
		return false
	end

	if player.isBot then
		return false
	end

	local connection = get_player_connection(state, player)
	if not connection then
		return false
	end

	return queue_item_type_it3_frame(state, connection, index, it3_path)
end

function M.send_human_model(state, player, index, assignment)
	if player == nil then
		local sent = 0
		for connection, client in pairs(state.clients) do
			if connection.is_open and client.hello and client.bound
				and validate_bound_player(connection, client) then
				if queue_human_model_frame(state, connection, index, assignment) then
					sent = sent + 1
				end
			end
		end
		return sent
	end

	if type(player) ~= "userdata" or player.class ~= "Player" then
		return false
	end

	if player.isBot then
		return false
	end

	local connection = get_player_connection(state, player)
	if not connection then
		return false
	end

	return queue_human_model_frame(state, connection, index, assignment)
end

function M.send_vehicle_type_model(state, player, index, model_name)
	if player == nil then
		local sent = 0
		for connection, client in pairs(state.clients) do
			if connection.is_open and client.hello and client.bound
				and validate_bound_player(connection, client) then
				if queue_vehicle_type_model_frame(state, connection, index, model_name) then
					sent = sent + 1
				end
			end
		end
		return sent
	end

	if type(player) ~= "userdata" or player.class ~= "Player" then
		return false
	end

	if player.isBot then
		return false
	end

	local connection = get_player_connection(state, player)
	if not connection then
		return false
	end

	return queue_vehicle_type_model_frame(state, connection, index, model_name)
end

function M.send_vehicle_type_audio(state, player, index, audio_reference)
	if player == nil then
		local sent = 0
		for connection, client in pairs(state.clients) do
			if connection.is_open and client.hello and client.bound
				and validate_bound_player(connection, client) then
				if queue_vehicle_type_audio_frame(state, connection, index, audio_reference) then
					sent = sent + 1
				end
			end
		end
		return sent
	end

	if type(player) ~= "userdata" or player.class ~= "Player" then
		return false
	end

	if player.isBot then
		return false
	end

	local connection = get_player_connection(state, player)
	if not connection then
		return false
	end

	return queue_vehicle_type_audio_frame(state, connection, index, audio_reference)
end

function M.send_item_type_model(state, player, index, model_name)
	if player == nil then
		local sent = 0
		for connection, client in pairs(state.clients) do
			if connection.is_open and client.hello and client.bound
				and validate_bound_player(connection, client) then
				if queue_item_type_model_frame(state, connection, index, model_name) then
					sent = sent + 1
				end
			end
		end
		return sent
	end

	if type(player) ~= "userdata" or player.class ~= "Player" then
		return false
	end

	if player.isBot then
		return false
	end

	local connection = get_player_connection(state, player)
	if not connection then
		return false
	end

	return queue_item_type_model_frame(state, connection, index, model_name)
end

function M.refresh(state)
	local generation = next_sync_generation(state)
	for connection, client in pairs(state.clients) do
		if connection.is_open and client.hello and client.bound
			and validate_bound_player(connection, client) then
			reset_client_sync_state(connection, client, true)
			client.generation = generation
			enqueue_frame(state, connection, "REFRESH_NOTICE", {
				runtimeID = state.runtime_id,
				syncGeneration = generation,
				manifestHash = state.manifest_hash,
			})
		end
	end
end

function M.on_udp_datagram(state, decoded)
	local connection = decoded and decoded.connection or nil
	local client = decoded and decoded.client or nil
	if not connection or not client or type(decoded.messages) ~= "table" then
		return
	end

	for _, message in ipairs(decoded.messages) do
		if not connection.is_open or not client.hello or not client.bound
			or not validate_bound_player(connection, client) then
			return
		end

		if message.kind == 1 then
			ensure_event_tracking_tables(client)
			udp_events.queue_ack(client, message.message_id)
			local pending_result = client.pending_results[message.message_id]
			if pending_result then
				udp_events.enqueue(client, pending_result.bytes)
			elseif not client.recent_completed[message.message_id] then
				local result = handle_client_event(state, connection, message)
				local result_payload, encode_error = event_codec.encode_args(
					result.status,
					result.handled,
					result.errors,
					result.detail or ""
				)
				if result_payload then
					if not queue_reliable_udp_result(
						state,
						connection,
						result.event_name or udp_events.format_event_hash(message.event_hash),
						message.message_id,
						message.event_hash,
						result_payload
					) then
						log.warn(
							"failed to queue result for client event (%s) id=%s client=%s",
							result.event_name or udp_events.format_event_hash(message.event_hash),
							message.message_id,
							client_id(connection)
						)
					end
				else
					log.warn(
						"failed to encode result payload for client event (%s): %s",
						result.event_name or udp_events.format_event_hash(message.event_hash),
						tostring(encode_error)
					)
				end
			end
		elseif message.kind == 2 then
			handle_reliable_event_ack_batch_payload(state, connection, message.message_ids)
		elseif message.kind == 3 then
			handle_reliable_event_result_payload(state, connection, message)
		end
	end
end

function M.ensure_tcp_server(state)
	ensure_tcp_server(state)
end

function M.logic_step(state)
	ensure_tcp_server(state)
	accept_connections(state)
	process_clients(state)
end

function M.on_send_packet(state, address, port)
	udp_events.on_send_packet(state, address, port)
end

function M.on_packet_receive(state)
	local decoded, should_override = udp_events.on_packet_receive(state)
	for _, datagram in ipairs(decoded) do
		M.on_udp_datagram(state, datagram)
	end
	return should_override
end

function M.shutdown(state)
	close_all(state)
end

function M.get_player_connection(state, player)
	return get_player_connection(state, player)
end

function M.get_connection_player(state, connection)
	local client = state and state.clients and state.clients[connection] or nil
	if not client then
		return nil
	end

	return refresh_client_player_binding(state, connection, client)
end

function M.authorize_account_ticket(state, account, endpoint)
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
			and parse_positive_integer(client.hello_payload.phoneNumber or client.hello_payload.phone)
		if connection.is_open
			and tostring(connection.address) == address
			and claimed_phone == phone_number
			and client.sync_state == "ready"
			and client.ready_generation == state.sync_generation
			and client.ready_manifest_hash == state.manifest_hash
			and tostring(client.game_address) == address
			and tonumber(client.game_port) == tonumber(endpoint.port) then
			client.admitted_address = address
			client.admitted_port = tonumber(endpoint.port)
			return true
		end
	end

	return false
end

return M
