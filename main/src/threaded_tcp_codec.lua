local threaded_tcp_codec = {
	BIND = 1,
	SEND = 2,
	CLOSE = 3,
	DATA_ACK = 4,
	DISCARD_SENDS = 5,
	START_BUNDLE = 6,
	CACHE_BUNDLE = 7,
	SYNC_SNAPSHOT = 8,
	START_PARTIAL = 9,
	SEND_FRAME = 10, -- value: logical frame ID; payload: final-fragment byte, then bytes
	LISTENING = 16,
	ACCEPTED = 17,
	DATA = 18,
	SENT = 19,
	CLOSED = 20,
	ERROR = 21,
	STREAM_DONE = 22,
	SEND_STATS = 23,
	SNAPSHOT_READY = 24, -- payload: manifest hash the worker has fully staged
}

local BINARY_MAGIC = "SRCB"

function threaded_tcp_codec.encode(kind, id, value, payload)
	return string.pack(">BI4I4", kind, id, value) .. (payload or "")
end

function threaded_tcp_codec.decode(message)
	if type(message) ~= "string" or #message < 9 then
		return nil, "invalid worker message"
	end

	local kind, id, value = string.unpack(">BI4I4", message)
	return {
		kind = kind,
		id = id,
		value = value,
		payload = message:sub(10),
	}
end

function threaded_tcp_codec.encode_error(message)
	local payload = tostring(message):sub(1, 512)
	return threaded_tcp_codec.encode(threaded_tcp_codec.ERROR, 0, #payload, payload)
end

function threaded_tcp_codec.encode_binary_frame(frame_type, payload)
	if type(frame_type) ~= "string" or frame_type == "" then
		return nil
	end

	if type(payload) ~= "string" then
		payload = ""
	end

	return string.pack(">c4I2I4", BINARY_MAGIC, #frame_type, #payload) .. frame_type .. payload
end

return threaded_tcp_codec
