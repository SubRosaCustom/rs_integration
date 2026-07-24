local M = {
	BIND = 1,
	SEND = 2,
	CLOSE = 3,
	DATA_ACK = 4,
	DISCARD_SENDS = 5,
	START_BUNDLE = 6,
	CACHE_BUNDLE = 7,
	LISTENING = 16,
	ACCEPTED = 17,
	DATA = 18,
	SENT = 19,
	CLOSED = 20,
	ERROR = 21,
	STREAM_DONE = 22,
	SEND_STATS = 23,
}

function M.encode(kind, id, value, payload)
	return string.pack(">BI4I4", kind, id, value) .. (payload or "")
end

function M.decode(message)
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

function M.encode_error(message)
	local payload = tostring(message):sub(1, 512)
	return M.encode(M.ERROR, 0, #payload, payload)
end

return M
