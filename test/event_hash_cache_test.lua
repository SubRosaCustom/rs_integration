-- Run from rs_integration/: lua test/event_hash_cache_test.lua
bit32 = bit32 or {
	bxor = function(a, b) return (a ~ b) & 0xFFFFFFFF end,
	band = function(a, b) return (a & b) & 0xFFFFFFFF end,
}

local codec = dofile("main/src/event_codec.lua")
local vectors = dofile("../core/test/event_codec_vectors.lua")
local cache
for index = 1, math.huge do
	local name, value = debug.getupvalue(codec.hash_name, index)
	if not name then
		break
	end
	if name == "hash_cache" then
		cache = value
	end
end
assert(cache, "hash cache missing")

for _, vector in ipairs(vectors.hashes) do
	assert(codec.hex(codec.hash_name(vector.name)) == vector.hex, vector.name)
	assert(codec.hex(codec.hash_name(vector.name)) == vector.hex, vector.name)
end
assert(codec.hash_name(nil) == nil)
assert(codec.hash_name(false) == nil)
assert(codec.hash_name({}) == nil)

local expected = codec.hash_name("recurring")
assert(cache.recurring == expected)
for index = 1, 512 do
	local name = string.format("dynamic.%d", index)
	local hash = codec.hash_name(name)
	assert(#hash == 8 and codec.hash_name(name) == hash)
end
assert(cache.recurring == nil, "old entry was not evicted")
assert(codec.hash_name("recurring") == expected, "eviction changed hash")

local count = 0
for _ in pairs(cache) do
	count = count + 1
end
assert(count <= 256, "cache exceeded capacity")
local long_name = string.rep("x", 257)
local long_hash = codec.hash_name(long_name)
assert(#long_hash == 8 and codec.hash_name(long_name) == long_hash)
assert(cache[long_name] == nil, "long name retained")
print("event hash cache passed")
