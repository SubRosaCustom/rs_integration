-- admission limits for TCP connections before HELLO.
local tcp_connection_limits = {}

tcp_connection_limits.PRE_HELLO_TIMEOUT_SECONDS = 5
tcp_connection_limits.MAX_PRE_HELLO_CONNECTIONS = 32
tcp_connection_limits.MAX_CONNECTIONS_PER_ADDRESS = 8
-- largest backlog accepted before HELLO
tcp_connection_limits.PRE_HELLO_MAX_BUFFER_BYTES = 64 * 1024

-- nil if connection may join clients, else a reason
function tcp_connection_limits.accept_rejection(clients, connection)
	local address = tostring(connection.address)
	local pre_hello = 0
	local from_address = 0
	for other, client in pairs(clients) do
		if other.is_open then
			if not client.hello then
				pre_hello = pre_hello + 1
			end
			if tostring(other.address) == address then
				from_address = from_address + 1
			end
		end
	end
	if from_address >= tcp_connection_limits.MAX_CONNECTIONS_PER_ADDRESS then
		return "per-address connection cap"
	end
	if pre_hello >= tcp_connection_limits.MAX_PRE_HELLO_CONNECTIONS then
		return "pre-HELLO connection cap"
	end
	return nil
end

function tcp_connection_limits.pre_hello_expired(client, now)
	return not client.hello and now - client.connected_at >= tcp_connection_limits.PRE_HELLO_TIMEOUT_SECONDS
end

function tcp_connection_limits.buffer_limit(client, max_frame_bytes)
	if client.hello then
		return max_frame_bytes
	end
	return math.min(tcp_connection_limits.PRE_HELLO_MAX_BUFFER_BYTES, max_frame_bytes)
end

return tcp_connection_limits
