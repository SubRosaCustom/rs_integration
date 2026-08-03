local codec = require("main.src.threaded_tcp_codec")

local M = {}
local Server = {}
Server.__index = Server

local WORKER_PATH = "main/src/threaded_tcp_worker.lua"
local MAX_PENDING_SEND_BYTES = 2 * 1024 * 1024
local MAX_PENDING_SEND_MESSAGES = 512
local MAX_SEND_MESSAGE_BYTES = 256 * 1024
local MAX_PENDING_RECEIVE_BYTES = 512 * 1024
local MAX_EVENTS_PER_POLL = 2048
local STARTUP_TIMEOUT_SECONDS = 5

local function pop_front(queue)
	local value = queue[1]
	table.remove(queue, 1)
	return value
end

local function new_connection(server, event)
	local connection = {
		id = event.id,
		address = event.payload,
		port = event.value,
		is_open = true,
		receive_queue = {},
		receive_offset = 1,
		pending_receive_bytes = 0,
		pending_send_bytes = 0,
		stream_active = false,
		send_stats = nil,
	}

	function connection:send(bytes)
		if server.pending_send_messages >= MAX_PENDING_SEND_MESSAGES then
			return 0
		end

		local accepted = math.min(
			#bytes,
			MAX_SEND_MESSAGE_BYTES,
			MAX_PENDING_SEND_BYTES - self.pending_send_bytes
		)
		if accepted <= 0 then
			return 0
		end

		local payload = bytes:sub(1, accepted)
		server.worker:sendMessage(codec.encode(codec.SEND, self.id, accepted, payload))
		self.pending_send_bytes = self.pending_send_bytes + accepted
		server.pending_send_messages = server.pending_send_messages + 1
		return accepted
	end

	function connection:receive(size)
		if #self.receive_queue == 0 then
			return nil
		end

		local bytes = self.receive_queue[1]
		local available = #bytes - self.receive_offset + 1
		local take = math.min(size, available)
		local data = bytes:sub(self.receive_offset, self.receive_offset + take - 1)
		self.receive_offset = self.receive_offset + take
		self.pending_receive_bytes = self.pending_receive_bytes - take
		if self.receive_offset > #bytes then
			pop_front(self.receive_queue)
			self.receive_offset = 1
		end
		return data
	end

	function connection:close()
		if not self.is_open then
			return
		end
		self.is_open = false
		server.worker:sendMessage(codec.encode(codec.CLOSE, self.id, 0))
	end

	function connection:start_bundle(bundle_id, archive_sha256, archive, end_frame)
		if self.stream_active then
			return false
		end

		if server.cached_bundle_hashes[bundle_id] ~= archive_sha256 then
			local cache_payload = string.pack(">I2", #bundle_id) .. bundle_id .. archive
			server.worker:sendMessage(
				codec.encode(codec.CACHE_BUNDLE, 0, #archive, cache_payload)
			)
			server.cached_bundle_hashes[bundle_id] = archive_sha256
		end

		local payload = string.pack(">I2", #bundle_id) .. bundle_id .. end_frame
		server.worker:sendMessage(codec.encode(codec.START_BUNDLE, self.id, 0, payload))
		self.stream_active = true
		return true
	end

	function connection:discard_pending_sends()
		server.worker:sendMessage(codec.encode(codec.DISCARD_SENDS, self.id, 0))
		self.stream_active = false
	end

	function connection:take_send_stats()
		local stats = self.send_stats
		self.send_stats = nil
		return stats
	end

	return connection
end

function M.new(port)
	local server = setmetatable({
		worker = Worker.new(WORKER_PATH),
		port = port,
		is_open = true,
		is_listening = false,
		accept_queue = {},
		connections = {},
		cached_bundle_hashes = {},
		pending_send_messages = 0,
		last_error = nil,
		started_at = os.realClock(),
	}, Server)
	server.worker:sendMessage(codec.encode(codec.BIND, 0, port))
	return server
end

function Server:poll()
	for _ = 1, MAX_EVENTS_PER_POLL do
		local message = self.worker:receiveMessage()
		if message == nil then
			if not self.is_listening and os.realClock() - self.started_at >= STARTUP_TIMEOUT_SECONDS then
				self.last_error = "TCP worker startup timed out"
				self.is_open = false
			end
			return
		end

		local event, decode_error = codec.decode(message)
		if not event then
			self.last_error = decode_error
			self.is_open = false
			return
		end

		if event.kind == codec.LISTENING then
			self.is_listening = true
		elseif event.kind == codec.ACCEPTED then
			local connection = new_connection(self, event)
			self.connections[event.id] = connection
			self.accept_queue[#self.accept_queue + 1] = connection
		elseif event.kind == codec.DATA then
			local connection = self.connections[event.id]
			if connection and connection.is_open then
				if connection.pending_receive_bytes + #event.payload > MAX_PENDING_RECEIVE_BYTES then
					connection:close()
				else
					connection.receive_queue[#connection.receive_queue + 1] = event.payload
					connection.pending_receive_bytes = connection.pending_receive_bytes + #event.payload
				end
			end
			self.worker:sendMessage(codec.encode(codec.DATA_ACK, event.id, 0))
		elseif event.kind == codec.SENT then
			self.pending_send_messages = math.max(0, self.pending_send_messages - 1)
			local connection = self.connections[event.id]
			if connection then
				connection.pending_send_bytes = math.max(0, connection.pending_send_bytes - event.value)
			end
		elseif event.kind == codec.CLOSED then
			local connection = self.connections[event.id]
			if connection then
				connection.is_open = false
				self.connections[event.id] = nil
			end
		elseif event.kind == codec.STREAM_DONE then
			local connection = self.connections[event.id]
			if connection then
				connection.stream_active = false
			end
		elseif event.kind == codec.SEND_STATS then
			local connection = self.connections[event.id]
			if connection then
				local bytes, calls, blocked, partial = string.unpack(
					">I4I4I4I4",
					event.payload
				)
				connection.send_stats = {
					elapsed_ms = event.value,
					bytes = bytes,
					calls = calls,
					blocked = blocked,
					partial = partial,
				}
			end
		elseif event.kind == codec.ERROR then
			self.last_error = event.payload
			self.is_open = false
			return
		else
			self.last_error = "unknown TCP worker event"
			self.is_open = false
			return
		end
	end
end

function Server:accept()
	while #self.accept_queue > 0 do
		local connection = pop_front(self.accept_queue)
		if connection.is_open then
			return connection
		end
	end
	return nil
end

function Server:close()
	if self.stopped then
		return
	end
	self.stopped = true
	self.is_open = false
	self.worker:stop()
	for _, connection in pairs(self.connections) do
		connection.is_open = false
	end
	self.connections = {}
	self.accept_queue = {}
end

return M
