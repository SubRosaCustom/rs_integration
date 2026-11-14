-- Run from rs_integration/: lua test/event_codec_test.lua
bit32 = bit32 or { bxor = function(a, b) return (a ~ b) & 0xFFFFFFFF end, band = function(a, b) return (a & b) & 0xFFFFFFFF end }

local function read(path)
	local file = assert(io.open(path, "rb"))
	local text = file:read("a")
	file:close()
	return text
end

local function to_hex(bytes)
	return (bytes:gsub(".", function(byte) return string.format("%02x", byte:byte()) end))
end

local vectors = dofile("../core/test/event_codec_vectors.lua")
local codec = dofile("main/src/event_codec.lua")

assert(read("main/src/event_codec.lua") == read("../core/main/eventCodec.lua"), "codec copies differ")

for _, vector in ipairs(vectors.hashes) do
	assert(to_hex(codec.hash_name(vector.name)) == vector.hex, "hash " .. vector.name)
	assert(codec.hex(codec.hash_name(vector.name)) == vector.hex, "hex " .. vector.name)
end

for _, vector in ipairs(vectors.encodings) do
	local args = type(vector.args) == "function" and vector.args(codec) or vector.args
	local encoded = assert(codec.encode(table.unpack(args, 1, vector.n)))
	assert(to_hex(encoded) == vector.hex, "encode " .. vector.name)
	local decoded = assert(codec.decode_args(encoded))
	assert(decoded.n == vector.n, "count " .. vector.name)
	assert(to_hex(assert(codec.encode(table.unpack(decoded, 1, decoded.n)))) == vector.hex, "round trip " .. vector.name)
end
print("event codec vectors passed")
