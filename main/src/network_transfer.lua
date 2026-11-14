local json = require("main.json")

local log = require("main.src.log")
local sync_paths = require("main.src.sync_paths")
local threaded_tcp_codec = require("main.src.threaded_tcp_codec")
local network_session = require("main.src.network_session")

local client_id = network_session.client_id
local enqueue_bytes = network_session.enqueue_bytes
local enqueue_frame = network_session.enqueue_frame

local network_transfer = {}
local MAX_PENDING_SYNC_REQUESTS = 32
local MAX_PARTIAL_BUNDLE_PATHS = 4096

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

	if #client.pending_file_requests >= MAX_PENDING_SYNC_REQUESTS then
		log.warn("Too many pending file requests (%s)", client_id(connection))
		connection:close()
		return
	end
	table.insert(client.pending_file_requests, relative_path)
end

local function queue_sync_bundle(state, connection, bundle_id, paths)
	local client = state.clients[connection]
	if not client or type(bundle_id) ~= "string" or bundle_id == "" then
		return
	end

	local bundle = state.sync_bundles_by_id and state.sync_bundles_by_id[bundle_id] or nil
	if type(paths) == "table" then
		if #paths == 0 or #paths > MAX_PARTIAL_BUNDLE_PATHS then
			log.warn("Invalid partial bundle path count (%s)", client_id(connection))
			connection:close()
			return
		end
		-- The worker validates the request against its immutable snapshot and builds the ZIP.
		bundle = { id = bundle_id, kind = "partial", paths = paths, }
	elseif not bundle then
		enqueue_frame(state, connection, "ERROR_REPORT", {
			error = "invalid BUNDLE_REQ id", id = bundle_id,
		})
		return
	end

	if client.active_bundle_transfer and client.active_bundle_transfer.id == bundle_id then
		return
	end

	for _, queued in ipairs(client.pending_bundle_requests) do
		if queued.id == bundle_id then
			return
		end
	end

	if #client.pending_bundle_requests >= MAX_PENDING_SYNC_REQUESTS then
		log.warn("Too many pending bundle requests (%s)", client_id(connection))
		connection:close()
		return
	end
	table.insert(client.pending_bundle_requests, bundle)
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

	local bundle = table.remove(client.pending_bundle_requests, 1)
	local bundle_id = bundle.id
	local started
	if bundle.kind == "partial" then
		started = connection:start_partial(bundle_id, bundle.paths)
	else
		local end_frame = json.encode({ type = "BUNDLE_END", payload = { id = bundle_id } }) .. "\n"
		started = connection:start_bundle(bundle_id, end_frame)
	end
	if not started then
		table.insert(client.pending_bundle_requests, 1, bundle)
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
	if #client.send_queue > 0 or connection.pending_send_bytes > 0 then
		return
	end

	if client.active_bundle_transfer and not connection.stream_active then
		client.active_bundle_transfer = nil
	end
	if not client.active_bundle_transfer then
		start_next_bundle_transfer(state, connection, client)
	end
end

network_transfer.queue_sync_file = queue_sync_file
network_transfer.queue_sync_bundle = queue_sync_bundle
network_transfer.pump_file_transfer = pump_file_transfer
network_transfer.pump_bundle_transfer = pump_bundle_transfer

return network_transfer
