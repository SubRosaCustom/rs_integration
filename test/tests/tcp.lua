local json = require("main.json")

local function read_file(path)
	local file = io.open(path, "rb")
	if not file then
		return nil
	end

	local contents = file:read("*all")
	file:close()
	return contents
end

return function()
	local attempts = 0

	local function wait_for_probe()
		attempts = attempts + 1
		local encoded = read_file("tcp_framing.json")
		if not encoded then
			assert(attempts < 600, "TCP framing probe did not complete")
			next_test_tick(wait_for_probe)
			return
		end

		local responses = json.decode(encoded)
		assert(type(responses) == "table")
		assert(#responses == 3)
		for _, response in ipairs(responses) do
			assert(response.type == "SRC_PONG")
			assert(type(response.payload) == "table")
			assert(response.payload.protocol == 5)
		end
	end

	next_test_tick(wait_for_probe)
end
