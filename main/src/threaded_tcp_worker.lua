local codec = require("main.src.threaded_tcp_codec")

local READ_SIZE = 16384
local SEND_BUDGET = 1024 * 1024
local MAX_COMMANDS_PER_PASS = 1024
local MAX_ACCEPTS_PER_PASS = 64
local MAX_CONNECTIONS = 256
local WORKER_SLEEP_MS = 2
local STREAM_CHUNK_SIZE = 64 * 1024
local STREAM_QUEUE_TARGET = 4
local STATS_INTERVAL_SECONDS = 1

local tcp_server
local connections = {}
local bundle_cache = {}
local connection_count = 0
local next_connection_id = 1

local function record_send(connection, requested, sent)
	local stats = connection.send_stats
	if not stats.started_at then
		stats.started_at = os.realClock()
	end

	stats.calls = stats.calls + 1
	if sent <= 0 then
		stats.blocked = stats.blocked + 1
		return
	end

	stats.bytes = stats.bytes + sent
	if sent < requested then
		stats.partial = stats.partial + 1
	end
end

local function report_send_stats(id, connection)
	local stats = connection.send_stats
	if not stats.started_at then
		return
	end

	local now = os.realClock()
	local elapsed = now - stats.started_at
	if elapsed < STATS_INTERVAL_SECONDS then
		return
	end

	local elapsed_ms = math.max(1, math.floor(elapsed * 1000))
	local payload = string.pack(
		">I4I4I4I4",
		stats.bytes,
		stats.calls,
		stats.blocked,
		stats.partial
	)
	sendMessage(codec.encode(codec.SEND_STATS, id, elapsed_ms, payload))
	connection.send_stats = {
		started_at = nil,
		bytes = 0,
		calls = 0,
		blocked = 0,
		partial = 0,
	}
end

local function acknowledge_pending(id, pending)
	if pending.main_owned then
		sendMessage(codec.encode(codec.SENT, id, #pending.bytes))
	end
end

local function close_stream(connection)
	connection.stream = nil
end

local function release_send_queue(id, connection)
	for _, pending in ipairs(connection.send_queue) do
		acknowledge_pending(id, pending)
	end
	connection.send_queue = {}
end

local function discard_unsent_frames(id, connection)
	local in_flight = connection.send_queue[1]
	local keep_in_flight = in_flight and in_flight.offset > 1

	for index, pending in ipairs(connection.send_queue) do
		if not (keep_in_flight and index == 1) then
			acknowledge_pending(id, pending)
		end
	end

	connection.send_queue = keep_in_flight and { in_flight } or {}
end

local function close_connection(id)
	local connection = connections[id]
	if not connection then
		return
	end

	close_stream(connection)
	release_send_queue(id, connection)
	if connection.socket.isOpen then
		pcall(connection.socket.close, connection.socket)
	end
	connections[id] = nil
	connection_count = connection_count - 1
	sendMessage(codec.encode(codec.CLOSED, id, 0))
end

local function encode_binary_frame(frame_type, payload)
	return "SRCB" .. string.pack(">I2I4", #frame_type, #payload) .. frame_type .. payload
end

local function cache_bundle(payload)
	if #payload < 3 then
		error("invalid bundle cache command")
	end

	local bundle_id_size = string.unpack(">I2", payload)
	local archive_offset = 3 + bundle_id_size
	if bundle_id_size == 0 or archive_offset > #payload then
		error("invalid bundle cache command")
	end

	local bundle_id = payload:sub(3, archive_offset - 1)
	bundle_cache[bundle_id] = payload:sub(archive_offset)
end

local function open_bundle_stream(connection, payload)
	if #payload < 3 then
		error("invalid bundle stream command")
	end

	local bundle_id_size = string.unpack(">I2", payload)
	local end_frame_offset = 3 + bundle_id_size
	if bundle_id_size == 0 or end_frame_offset > #payload then
		error("invalid bundle stream command")
	end

	local bundle_id = payload:sub(3, end_frame_offset - 1)
	local end_frame = payload:sub(end_frame_offset)
	if end_frame == "" then
		error("invalid bundle stream command")
	end
	local archive = bundle_cache[bundle_id]
	if not archive then
		error("bundle is not cached")
	end

	close_stream(connection)
	connection.stream = {
		id = bundle_id,
		archive = archive,
		offset = 1,
		end_frame = end_frame,
	}
end

local function fill_stream_queue(connection)
	while connection.stream and #connection.send_queue < STREAM_QUEUE_TARGET do
		local stream = connection.stream
		local chunk = stream.archive:sub(stream.offset, stream.offset + STREAM_CHUNK_SIZE - 1)
		if chunk ~= "" then
			local payload = string.pack(">I2", #stream.id) .. stream.id .. chunk
			stream.offset = stream.offset + #chunk
			connection.send_queue[#connection.send_queue + 1] = {
				bytes = encode_binary_frame("BUNDLE_CHUNK", payload),
				offset = 1,
				main_owned = false,
			}
		else
			local end_frame = stream.end_frame
			close_stream(connection)
			connection.send_queue[#connection.send_queue + 1] = {
				bytes = end_frame,
				offset = 1,
				main_owned = false,
				stream_end = true,
			}
		end
	end
end

local function bind(port)
	if tcp_server then
		return
	end

	local ok, server_or_error = pcall(TCPServer.new, port)
	if not ok then
		sendMessage(codec.encode_error(server_or_error))
		return
	end

	tcp_server = server_or_error
	sendMessage(codec.encode(codec.LISTENING, 0, port))
end

local function handle_command(command)
	if command.kind == codec.BIND then
		bind(command.value)
		return
	end
	if command.kind == codec.CACHE_BUNDLE then
		cache_bundle(command.payload)
		return
	end

	local connection = connections[command.id]
	if command.kind == codec.SEND then
		if connection then
			connection.send_queue[#connection.send_queue + 1] = {
				bytes = command.payload,
				offset = 1,
				main_owned = true,
			}
		else
			sendMessage(codec.encode(codec.SENT, command.id, #command.payload))
		end
		return
	end

	if command.kind == codec.CLOSE then
		close_connection(command.id)
		return
	end
	if command.kind == codec.DISCARD_SENDS then
		if connection then
			close_stream(connection)
			discard_unsent_frames(command.id, connection)
		end
		return
	end

	if command.kind == codec.START_BUNDLE then
		if connection then
			open_bundle_stream(connection, command.payload)
		end
		return
	end

	if command.kind == codec.DATA_ACK then
		if connection then
			connection.awaiting_data_ack = false
		end
		return
	end

	error("unknown worker command")
end

local function process_commands()
	for _ = 1, MAX_COMMANDS_PER_PASS do
		local message = receiveMessage()
		if message == nil then
			return
		end

		local command, decode_error = codec.decode(message)
		if command then
			handle_command(command)
		else
			sendMessage(codec.encode_error(decode_error))
		end
	end
end

local function accept_connections()
	if not tcp_server then
		return
	end

	for _ = 1, MAX_ACCEPTS_PER_PASS do
		if connection_count >= MAX_CONNECTIONS then
			return
		end

		local ok, socket_or_error = pcall(tcp_server.accept, tcp_server)
		if not ok then
			sendMessage(codec.encode_error(socket_or_error))
			return
		end
		if socket_or_error == nil then
			return
		end

		local id = next_connection_id
		next_connection_id = next_connection_id + 1
		connection_count = connection_count + 1
		connections[id] = {
			socket = socket_or_error,
			send_queue = {},
			awaiting_data_ack = false,
			send_stats = {
				started_at = nil,
				bytes = 0,
				calls = 0,
				blocked = 0,
				partial = 0,
			},
		}
		sendMessage(
			codec.encode(codec.ACCEPTED, id, socket_or_error.port, tostring(socket_or_error.address))
		)
	end
end

local function receive_from_client(id, connection)
	if connection.awaiting_data_ack then
		return true
	end

	local ok, data_or_error = pcall(connection.socket.receive, connection.socket, READ_SIZE)
	if not ok then
		return false
	end
	if data_or_error == nil then
		return true
	end

	local bytes = tostring(data_or_error)
	if bytes == "" then
		return false
	end

	connection.awaiting_data_ack = true
	sendMessage(codec.encode(codec.DATA, id, #bytes, bytes))
	return true
end

local function send_to_client(id, connection, budget)
	local sent_this_pass = 0
	while #connection.send_queue > 0 and sent_this_pass < budget do
		local pending = connection.send_queue[1]
		local remaining_budget = budget - sent_this_pass
		local bytes = pending.bytes:sub(pending.offset, pending.offset + remaining_budget - 1)
		local ok, sent_or_error = pcall(connection.socket.send, connection.socket, bytes)
		if not ok then
			return false
		end

		local sent = tonumber(sent_or_error) or 0
		if not pending.main_owned then
			record_send(connection, #bytes, sent)
		end
		if sent <= 0 then
			return true
		end

		pending.offset = pending.offset + sent
		sent_this_pass = sent_this_pass + sent
		if pending.offset > #pending.bytes then
			table.remove(connection.send_queue, 1)
			acknowledge_pending(id, pending)
			if pending.stream_end then
				sendMessage(codec.encode(codec.STREAM_DONE, id, 0))
			end
		else
			return true
		end
	end
	return true
end

local function process_connections()
	for _, connection in pairs(connections) do
		fill_stream_queue(connection)
	end

	local active_senders = 0
	for _, connection in pairs(connections) do
		if #connection.send_queue > 0 then
			active_senders = active_senders + 1
		end
	end
	local send_budget = active_senders > 0 and math.floor(SEND_BUDGET / active_senders) or 0

	local closed = {}
	for id, connection in pairs(connections) do
		if not connection.socket.isOpen or not receive_from_client(id, connection) or
			not send_to_client(id, connection, send_budget) then
			closed[#closed + 1] = id
		else
			report_send_stats(id, connection)
		end
	end

	for _, id in ipairs(closed) do
		close_connection(id)
	end
end

local function run_pass()
	process_commands()
	accept_connections()
	process_connections()
end

while not sleep(WORKER_SLEEP_MS) do
	local ok, worker_error = xpcall(run_pass, debug.traceback)
	if not ok then
		sendMessage(codec.encode_error(worker_error))
		break
	end
end

for id in pairs(connections) do
	close_connection(id)
end
if tcp_server and tcp_server.isOpen then
	pcall(tcp_server.close, tcp_server)
end
