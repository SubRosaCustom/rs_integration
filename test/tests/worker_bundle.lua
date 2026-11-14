-- Run from rs_integration: lua test/tests/worker_bundle.lua
package.loaded["main.json"] = dofile("test/main/json.lua")
local json = require("main.json")
local codec = require("main.src.threaded_tcp_codec")
local extracts, builds = 0, 0
crypto = { sha256 = function(bytes) return bytes end, }
miniz = {
	extractZip = function(archive)
		extracts = extracts + 1
		assert(archive == "snapshot ZIP")
		return { ["a.lua"] = "contents", ["b.lua"] = "other", }
	end,
	createZip = function(inputs, options)
		builds = builds + 1
		assert(options.level == 3 and options.store[1] == ".png")
		local names = {}
		for name in pairs(inputs) do names[#names + 1] = name end
		table.sort(names)
		return "partial ZIP:" .. table.concat(names, ",")
	end,
}
package.loaded.libminiz = miniz
local messages = {}
sendMessage = function(message) messages[#messages + 1] = message end
local file = assert(io.open("main/src/threaded_tcp_worker.lua", "r"))
local source = file:read("*a")
file:close()
source = source:sub(1, assert(source:find("while not sleep", 1, true)) - 1)
source = source .. [[

return {
	cache = cache_bundle, publish = set_snapshot, start = start_partial, handle = handle_command,
	process = process_partial_queue, connections = connections, queue = function() return partial_queue end,
	cache_size = function() return #partial_cache_order end,
}]]
local worker = assert(load(source))()
local files = { { path = "a.lua", size = 8, sha256 = "contents", }, { path = "b.lua", size = 5, sha256 = "other", }, }
local function bundles(archive_sha256)
	return { { id = "base", archive_sha256 = archive_sha256, files = files, }, }
end
worker.cache(string.pack(">I2", 4) .. "base" .. "snapshot ZIP")

-- publish checks the hash only, extraction waits for a request
worker.publish(json.encode({ manifest = "generation", bundles = bundles("snapshot ZIP"), }))
assert(extracts == 0 and builds == 0, "snapshot publish must not extract")
local ready = assert(codec.decode(messages[#messages]))
assert(ready.kind == codec.SNAPSHOT_READY and ready.payload == "generation")
assert(not pcall(worker.publish, json.encode({ manifest = "generation", bundles = bundles("different"), })),
	"a corrupted archive must be rejected at publish")

local function request_for(paths, manifest)
	local joined = table.concat(paths, "\n") .. "\n"
	return { manifest = manifest or "generation", paths = paths, id = "partial-" .. ((manifest or "generation") .. joined):sub(1, 16), }
end
local function start(paths, manifest)
	local connection = { send_queue = {}, }
	worker.start(connection, json.encode(request_for(paths, manifest)))
	return connection
end

-- extraction once per bundle
local first = start({ "a.lua" })
assert(extracts == 1 and builds == 1)
assert(first.stream.archive == "partial ZIP:a.lua")
assert(json.decode(first.send_queue[1].bytes).type == "BUNDLE_BEGIN")
start({ "b.lua" })
assert(extracts == 1 and builds == 2)
worker.publish(json.encode({ manifest = "generation2", bundles = bundles("snapshot ZIP"), }))
start({ "a.lua" }, "generation2")
assert(extracts == 1, "unchanged bundle must not be re-extracted")

-- identical file sets share one ZIP, cache clears on manifest change
worker.publish(json.encode({ manifest = "generation", bundles = bundles("snapshot ZIP"), }))
builds = 0
local one = start({ "a.lua", "b.lua" })
local two = start({ "b.lua", "a.lua" })
assert(builds == 1 and one.stream.archive == two.stream.archive)
assert(one.stream.id ~= two.stream.id, "BUNDLE_BEGIN keeps each request's own id")
assert(worker.cache_size() == 1)
worker.publish(json.encode({ manifest = "generation3", bundles = bundles("snapshot ZIP"), }))
assert(worker.cache_size() == 0)
start({ "a.lua", "b.lua" }, "generation3")
assert(builds == 2)

-- cache bounded by entry count
local many = {}
for index = 1, 40 do
	many[index] = "f" .. index .. ".lua"
end
local many_files = {}
for _, path in ipairs(many) do many_files[#many_files + 1] = { path = path, size = 1, sha256 = "x", } end
local rebuild_extract = miniz.extractZip
miniz.extractZip = function()
	local extracted = {}
	for _, path in ipairs(many) do extracted[path] = "x" end
	return extracted
end
worker.cache(string.pack(">I2", 4) .. "base" .. "snapshot ZIP")
worker.publish(json.encode({ manifest = "generation", bundles = { { id = "base", files = many_files, }, }, }))
for _, path in ipairs(many) do start({ path, }) end
assert(worker.cache_size() == 32)
miniz.extractZip = rebuild_extract
worker.cache(string.pack(">I2", 4) .. "base" .. "snapshot ZIP")
worker.publish(json.encode({ manifest = "generation", bundles = bundles("snapshot ZIP"), }))

-- stale manifest or unknown path fails without building
builds = 0
assert(not pcall(start, { "a.lua" }, "old"))
assert(not pcall(start, { "missing.lua" }))
assert(builds == 0)

-- one build per pass, hits and failures don't use it
local function connection_with(id)
	local connection = { send_queue = {}, }
	worker.connections[id] = connection
	return connection
end
local c1, c2, c3 = connection_with(1), connection_with(2), connection_with(3)
local function queue(id, paths, manifest)
	worker.handle({ kind = codec.START_PARTIAL, id = id, value = id * 10,
		payload = json.encode(request_for(paths, manifest)), })
end
builds = 0
queue(1, { "a.lua" })
queue(2, { "b.lua" })
queue(3, { "a.lua", "b.lua" })
worker.process()
assert(builds == 1 and c1.stream and not c2.stream and not c3.stream, "one build per pass")
worker.process()
assert(builds == 2 and c2.stream and not c3.stream)
worker.process()
assert(builds == 3 and c3.stream and #worker.queue() == 0)
-- hit, stale and build drain in one pass
local c4, c5, c6 = connection_with(4), connection_with(5), connection_with(6)
queue(4, { "a.lua" })
queue(5, { "a.lua" }, "old")
queue(6, { "b.lua", "a.lua" })
local before = builds
worker.process()
assert(builds == before and c4.stream and c6.stream, "cache hits are served without a build")
local failure = json.decode(c5.send_queue[1].bytes)
assert(failure.type == "ERROR_REPORT" and c5.send_queue[1].stream_generation == 50)
-- closing a connection drops its queued build
queue(1, { "a.lua" })
worker.handle({ kind = codec.DISCARD_SENDS, id = 1, value = 0, payload = "", })
assert(#worker.queue() == 0)
print("worker bundle handoff checks passed")
