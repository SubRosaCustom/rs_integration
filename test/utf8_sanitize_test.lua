-- Run from rs_integration/: lua test/utf8_sanitize_test.lua
package.path = "./?.lua;" .. package.path
package.preload["main.json"] = function() return dofile("test/main/json.lua") end
local s = require("main.src.utf8_sanitize")
local R = s.REPLACEMENT

assert(s.is_valid("") and s.is_valid("plain") and s.is_valid("caf\195\169 \226\130\172 \240\159\152\128"))
-- legacy 8-bit, truncated, overlong, surrogate, out of range
for _, bad in ipairs({ "caf\233", "\128", "\195", "\192\128", "\224\128\128", "\237\160\128", "\244\144\128\128", "\245\128\128\128", "\240\159\152" }) do
	assert(not s.is_valid(bad), bad)
end
assert(s.sanitize("caf\233!") == "caf" .. R .. "!")
assert(s.sanitize("a\195") == "a" .. R)
assert(s.sanitize("\195\169\233\195\169") == "\195\169" .. R .. "\195\169")
assert(s.sanitize("ok") == "ok" and s.sanitize(7) == 7)
assert(s.is_valid(s.sanitize("\255\254\253 \237\160\128")))

local clean = { name = "x", list = { "\195\169", 1 } }
assert(s.sanitize_value(clean) == clean, "clean tables are not copied")
local dirty = { ["k\233"] = { "n\233", n = 2 }, ok = true }
local out = s.sanitize_value(dirty)
assert(out ~= dirty and dirty["k\233"][1] == "n\233", "input must not be mutated")
assert(out["k" .. R][1] == "n" .. R and out["k" .. R].n == 2 and out.ok == true)

-- round trip through the server's json stays valid UTF-8
local json = require("main.json")
local encoded = json.encode(s.sanitize_value({ type = "T", payload = { player = "Jos\233" } }))
assert(s.is_valid(encoded))

local paths = require("main.src.sync_paths")
assert(paths.is_safe_asset("texture/caf\195\169.png"))
assert(not paths.is_safe_asset("texture/caf\233.png"))
print("utf8_sanitize_test ok")
