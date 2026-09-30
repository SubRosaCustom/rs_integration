-- Run from rs_integration: lua test/tests/worker_bundle.lua
package.loaded["main.json"] = dofile("test/main/json.lua")
local json = require("main.json")
local extracts, builds = 0, 0
crypto = { sha256 = function(bytes) return bytes end, }
miniz = {
	extractZip = function(archive)
		extracts = extracts + 1
		assert(archive == "snapshot ZIP")
		return { ["a.lua"] = "contents", }
	end,
	createZip = function(inputs)
		builds = builds + 1
		assert(inputs["a.lua"] == "contents")
		return "partial ZIP"
	end,
}
package.loaded.libminiz = miniz
local file = assert(io.open("main/src/threaded_tcp_worker.lua", "r"))
local source = file:read("*a")
file:close()
-- Exercise the actual worker handlers without starting its socket loop.
source = source:sub(1, assert(source:find("while not sleep", 1, true)) - 1)
source = source .. "\nreturn cache_bundle, set_snapshot, start_partial"
local cache, publish, start = assert(load(source))()
cache(string.pack(">I2", 4) .. "base" .. "snapshot ZIP")
publish(json.encode({ manifest = "generation", bundles = {
	{ id = "base", files = { { path = "a.lua", size = 8, sha256 = "contents", }, }, },
}, }))
assert(extracts == 1 and builds == 0)
local request = { manifest = "generation", paths = { "a.lua", },
	id = "partial-" .. ("generation" .. "a.lua\n"):sub(1, 16), }
for _ = 1, 2 do
	local connection = { send_queue = {}, }
	start(connection, json.encode(request))
	assert(connection.stream.archive == "partial ZIP")
	assert(json.decode(connection.send_queue[1].bytes).type == "BUNDLE_BEGIN")
end
assert(extracts == 1 and builds == 2)
request.manifest = "old"
assert(not pcall(start, { send_queue = {}, }, json.encode(request)))
request.manifest = "generation"
request.paths = { "missing.lua", }
assert(not pcall(start, { send_queue = {}, }, json.encode(request)))
assert(builds == 2)
print("worker bundle handoff checks passed")
