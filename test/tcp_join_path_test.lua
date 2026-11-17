-- Run from rs_integration/: lua test/tcp_join_path_test.lua
package.path = "./?.lua;" .. package.path
package.preload["main.json"] = function() return dofile("test/main/json.lua") end
local json = require("main.json")
local sanitize = require("main.src.utf8_sanitize")
local buffer_module = require("main.src.tcp_receive_buffer")
local limits = require("main.src.tcp_connection_limits")
local index_response = require("main.src.index_response")

-- vs the old whole-string implementation
local MAX = 64
local function reference(chunks)
	local buffer, lines = "", {}
	for _, data in ipairs(chunks) do
		local nl = data:find("\n", 1, true)
		if #buffer + (nl or (#data + 1)) > MAX then return lines, false end
		buffer = buffer .. data
		while true do
			local pos = buffer:find("\n", 1, true)
			if not pos then
				if #buffer >= MAX then return lines, false end
				break
			end
			if pos > MAX then return lines, false end
			local line = buffer:sub(1, pos - 1)
			buffer = buffer:sub(pos + 1)
			if line ~= "" then lines[#lines + 1] = line end
		end
	end
	return lines, true
end
local function candidate(chunks)
	local buffer, lines = buffer_module.new(), {}
	for _, data in ipairs(chunks) do
		if not buffer:push(data, MAX) then return lines, false end
		while true do
			local line = buffer:pop_line()
			if not line then break end
			lines[#lines + 1] = line
		end
	end
	return lines, true
end
math.randomseed(7)
local alphabet = { "a", "bc", "\n", "\n\n", "xyz", "{}", "q" }
for _ = 1, 3000 do
	local chunks = {}
	for i = 1, math.random(1, 12) do
		local parts = {}
		for j = 1, math.random(1, 6) do parts[j] = alphabet[math.random(#alphabet)] end
		chunks[i] = table.concat(parts)
	end
	local expected, expected_ok = reference(chunks)
	local actual, actual_ok = candidate(chunks)
	assert(actual_ok == expected_ok, "ok mismatch")
	assert(#actual == #expected, "line count mismatch")
	for i = 1, #expected do assert(actual[i] == expected[i], "line mismatch") end
end

-- frame split across pushes, byte by byte
local split = buffer_module.new()
for char in ("hello world\nnext\n"):gmatch(".") do assert(split:push(char, 1024)) end
assert(split:pop_line() == "hello world" and split:pop_line() == "next" and not split:pop_line())
assert(split.total_bytes == 0)

-- pre-HELLO buffer cap
local pre, bound = { hello = false }, { hello = true }
assert(limits.buffer_limit(pre, 8 * 1024 * 1024) == 64 * 1024)
assert(limits.buffer_limit(bound, 8 * 1024 * 1024) == 8 * 1024 * 1024)
local flood = buffer_module.new()
local ok = true
for _ = 1, 100 do
	ok = flood:push(string.rep("x", 1024), limits.buffer_limit(pre, 8 * 1024 * 1024))
	if not ok then break end
end
assert(not ok and flood.total_bytes < 64 * 1024, "pre-HELLO backlog must stay capped")
local backlog = buffer_module.new()
for _ = 1, 100 do assert(backlog:push(string.rep("x", 1024), limits.buffer_limit(bound, 8 * 1024 * 1024))) end

-- admission limits
local clients = {}
local function connect(address, hello)
	local connection = { address = address, is_open = true }
	local reason = limits.accept_rejection(clients, connection)
	if not reason then clients[connection] = { hello = hello or false, connected_at = 0 } end
	return reason, connection
end
for _ = 1, limits.MAX_CONNECTIONS_PER_ADDRESS do assert(not connect("192.0.2.1")) end
assert(connect("192.0.2.1") == "per-address connection cap")
assert(not connect("192.0.2.2", true))
for i = 1, limits.MAX_PRE_HELLO_CONNECTIONS - limits.MAX_CONNECTIONS_PER_ADDRESS do
	assert(not connect("198.51.100." .. i), i)
end
assert(connect("203.0.113.1") == "pre-HELLO connection cap")
local client = { hello = false, connected_at = 100 }
assert(not limits.pre_hello_expired(client, 100 + limits.PRE_HELLO_TIMEOUT_SECONDS - 0.1))
assert(limits.pre_hello_expired(client, 100 + limits.PRE_HELLO_TIMEOUT_SECONDS))
client.hello = true
assert(not limits.pre_hello_expired(client, 1e9))

-- INDEX_RES cache rebuilds only when an input changes
local state = {
	config = { disallowedPaths = { "a.lua" }, disableClientTiremarks = false },
	sync_bundles = {
		{ id = "core", kind = "scripts", size = 5, archive_sha256 = "aa", content_sha256 = "bb",
			files = { { path = "caf\233.lua", sha256 = "cc", size = 3 } } },
	},
	loaded_level = "city", persistent_mode = false, runtime_id = "rid", sync_generation = 3, manifest_hash = "m1",
}
local function per_client(s)
	local bundles = {}
	for i, b in ipairs(s.sync_bundles) do
		bundles[i] = { id = b.id, kind = b.kind, size = b.size, archiveSha256 = b.archive_sha256,
			contentSha256 = b.content_sha256, files = b.files }
	end
	return json.encode(sanitize.sanitize_value({ type = "INDEX_RES", payload = {
		bundles = bundles, disallowedPaths = s.config.disallowedPaths or {},
		disableClientTiremarks = s.config.disableClientTiremarks == true,
		disableDiscordJoin = s.config.disableDiscordJoin == true,
		hideDiscordDetails = s.config.hideDiscordDetails == true, loadedLevel = s.loaded_level,
		persistentMode = s.persistent_mode, runtimeID = s.runtime_id, syncGeneration = s.sync_generation,
		manifestHash = s.manifest_hash } })) .. "\n"
end
local first = index_response.bytes(state)
assert(first == per_client(state), "cached bytes must equal the per-client encoding")
assert(rawequal(first, index_response.bytes(state)))
assert(index_response.bytes(state) == first)
-- a cache key field change rebuilds it
state.manifest_hash, state.sync_bundles = "m2", { { id = "core", kind = "scripts", size = 6, archive_sha256 = "dd", content_sha256 = "ee", files = {} } }
assert(index_response.bytes(state) == per_client(state) and index_response.bytes(state) ~= first)
state.sync_generation = 4
assert(index_response.bytes(state) == per_client(state))
state.loaded_level = "other"
assert(index_response.bytes(state) == per_client(state))

print("TCP join path passed")
