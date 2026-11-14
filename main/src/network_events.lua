local log = require("main.src.log")
local event_codec = require("main.src.event_codec")
local udp_events = require("main.src.udp_events")
local network_session = require("main.src.network_session")

local client_id = network_session.client_id
local parse_positive_integer = network_session.parse_positive_integer
local validate_bound_player = network_session.validate_bound_player
local get_player_connection = network_session.get_player_connection

local network_events = {}
local SERVER_EVENT_ID_MAX = network_session.SERVER_EVENT_ID_MAX
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
local unpack_values = table.unpack or unpack

local function should_log_event_failure(state, connection, event_hash)
	local client = state.clients[connection]
	if not client or event_hash == nil then
		return true
	end

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
		local ok, err = pcall(function()
			return fn(connection, unpack_values(args, 1, args.n or 0))
		end)
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

-- names the events filling a client's reliable queue, so an overflow points at the sender
local function describe_backlog(client)
	local counts, names, total = {}, {}, 0
	for _, pending in pairs(client.pending_events) do
		if not counts[pending.name] then
			names[#names + 1] = pending.name
			counts[pending.name] = 0
		end
		counts[pending.name] = counts[pending.name] + 1
		total = total + 1
	end
	table.sort(names, function(a, b)
		return counts[a] > counts[b]
	end)
	local parts = {}
	for index = 1, math.min(#names, 5) do
		parts[index] = string.format("%s x%d", names[index], counts[names[index]])
	end
	return string.format(
		"%d unacknowledged events [%s]; the client is not acknowledging fast enough, so send less often"
			.. " or use src.emitClientEventLatest for replaceable state",
		total,
		table.concat(parts, ", ")
	)
end

local function queue_reliable_udp_event(state, connection, name, event_hash, argument_bytes, latest)
	local client = state.clients[connection]
	if not client or not connection.is_open or not client.hello or not client.bound then
		return false
	end

	if type(name) ~= "string" or name == "" then
		return false
	end

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
			encoded, encode_error = event_codec.encode(unpack_values(argument_bytes, 1, count))
		else
			encoded, encode_error = event_codec.encode()
		end
		if not encoded then
			log.warn("failed to encode UDP event payload (%s): %s", name, tostring(encode_error))
			return false
		end
		argument_bytes = encoded
	end

	local message_id = client.next_event_id
	if message_id > SERVER_EVENT_ID_MAX then
		log.warn("server event ID space exhausted for client %s; reconnect required", client_id(connection))
		return false
	end
	local bytes, encode_error = udp_events.encode_reliable_event(event_hash, message_id, argument_bytes)
	if not bytes then
		log.warn("failed to encode UDP event (%s): %s", name, tostring(encode_error))
		return false
	end
	if #bytes - 18 > math.min(262144, state.config.maxEventBytes) then
		log.warn("event too large; dropping (%s)", name)
		return false
	end

	client.next_event_id = message_id + 1

	if latest then
		if not udp_events.enqueue_latest(client, bytes) then
			udp_events.warn_limited(client, "latest_dropped", "latest-state UDP event dropped (%s) client=%s", name, client_id(connection))
			return false
		end
		return true
	end

	if not udp_events.enqueue(client, bytes) then
		udp_events.warn_limited(client, "event_budget", "UDP event queue budget exhausted (%s) client=%s: %s",
			name,
			client_id(connection),
			describe_backlog(client)
		)
		return false
	end

	client.pending_events[message_id] = {
		bytes = bytes,
		name = name,
		event_hash = event_hash,
		created_tick = state.tick,
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

	local normalized_message_id = parse_positive_integer(message_id)
	if not normalized_message_id then
		return false
	end

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
	if #bytes - 18 > math.min(262144, state.config.maxEventBytes) then
		log.warn("result too large; dropping (%s)", name)
		return false
	end

	if not udp_events.enqueue(client, bytes) then
		udp_events.warn_limited(client, "result_budget", "UDP result queue budget exhausted (%s) client=%s: %s",
			name,
			client_id(connection),
			describe_backlog(client)
		)
		return false
	end

	client.pending_results[normalized_message_id] = {
		bytes = bytes,
		name = name,
		event_hash = event_hash,
		created_tick = state.tick,
	}

	return true
end

local function handle_reliable_event_ack_batch_payload(state, connection, message_ids)
	local client = state.clients[connection]
	if client and type(message_ids) == "table" then
		for i = 1, #message_ids do
			local message_id = parse_positive_integer(message_ids[i])
			if message_id then
				local pending = client.pending_events[message_id]
				if pending then
					client.pending_events[message_id] = nil
					client.awaiting_results[message_id] = {
						name = pending.name,
						event_hash = pending.event_hash,
						acked_tick = state.tick,
						-- Allow the 120-second transport deadline for a fragmented result.
						deadline_tick = state.tick + state.config.eventProcessTimeoutTicks + 7200,
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
					log.warn_limited(client.warn_limits, "unknown_ack", "received EVENT_ACK for unknown id=%s from %s", message_id, client_id(connection))
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

	local message_id = parse_positive_integer(message and message.message_id)
	if not message_id then
		log.warn_limited(client.warn_limits, "invalid_result_id", "received EVENT_RESULT with invalid message_id from %s", client_id(connection))
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
		log.warn_limited(client.warn_limits, "unknown_result", "received EVENT_RESULT for unknown id=%s from %s", message_id, client_id(connection))
		return
	end

	client.awaiting_results[message_id] = nil
	client.early_results[message_id] = nil
	mark_event_recently_completed(state, client, message_id)
	log_event_result(state, connection, tracked.name, tracked.event_hash, message_id, result)
end

local function process_pending_retries(state, connection)
	local client = state.clients[connection]
	if not client then return end
	local transport_error = udp_events.tick(client, state.config)
	if transport_error then
		udp_events.warn_limited(client, "udp_transport_failed", "UDP transport failed (%s): %s", client_id(connection), transport_error)
		connection:close()
		return
	end
	if client.udp_events_ready ~= true then return end
	cleanup_recent_completions(state, client)

	for message_id, pending in pairs(client.awaiting_results) do
		if state.tick >= pending.deadline_tick then
			log.warn(
				"event result timeout: name=%s id=%s client=%s (receipt confirmed; processing status uncertain)",
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

function network_events.on_client_event(state, name, fn)
	assert(type(name) == "string", "src.onClientEvent(name, fn): name must be string")
	assert(type(fn) == "function", "src.onClientEvent(name, fn): fn must be function")


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

function network_events.emit_client_event(state, player, name, event_hash, argument_bytes, latest)
	-- argument bytes are already encoded, only the per-client header differs
	local args = argument_bytes

	if player == nil then
		local sent = 0
		for connection, client in pairs(state.clients) do
			if connection.is_open and client.hello and client.bound
				and validate_bound_player(connection, client) then
				if queue_reliable_udp_event(state, connection, name, event_hash, args, latest) then
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

	return queue_reliable_udp_event(state, connection, name, event_hash, args, latest)
end

function network_events.on_udp_datagram(state, decoded)
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

		if message.latest then
			handle_client_event(state, connection, message) -- Latest state has no processing result or delivery receipt.
		elseif message.kind == 1 and udp_events.accept(client, message) then
			local pending_result = client.pending_results[message.message_id]
			if pending_result then
				udp_events.enqueue(client, pending_result.bytes)
			elseif not client.recent_completed[message.message_id] then
				local result = handle_client_event(state, connection, message)
				local result_payload, encode_error = event_codec.encode(
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
							"failed to queue result for client event (%s) id=%s client=%s; disconnecting the client",
							result.event_name or udp_events.format_event_hash(message.event_hash),
							message.message_id,
							client_id(connection)
						)
						connection:close()
					end
				else
					log.warn(
						"failed to encode result payload for client event (%s): %s",
						result.event_name or udp_events.format_event_hash(message.event_hash),
						tostring(encode_error)
					)
					connection:close()
				end
			end
		elseif message.kind == 2 then
			handle_reliable_event_ack_batch_payload(state, connection, message.message_ids)
		elseif message.kind == 3 and udp_events.accept(client, message) then
			handle_reliable_event_result_payload(state, connection, message)
		end
	end
end

network_events.sanitize_log_text = sanitize_log_text
network_events.process_pending_retries = process_pending_retries

return network_events
