-- Standalone server-policy contract: lua test/tests/resource_packs.lua.
package.loaded["main.src.log"] = { info = function() end, warn = error }
local config = require("main.src.config")
local first = config.resolve({ disallowedPaths = { "data/model/head.cmo", "data/car.sbv", "data/car.sbv" } })
assert(#first.disallowedPaths == 2)
assert(first.disallowedPaths[1] == "data/car.sbv")
local second = config.resolve({})
assert(#second.disallowedPaths == 0 and #config.DEFAULTS.disallowedPaths == 0)
for _, path in ipairs({ "../head.cmo", "/data/head.cmo", "data\\head.cmo", "C:/data/head.cmo", "data//head.cmo", "data/a.", "data/a ", "data/a\0b" }) do
 assert(not pcall(config.resolve, { disallowedPaths = { path } }), path)
end
assert(not pcall(config.resolve, { disallowedPaths = { [1] = "data/a", [3] = "data/b" } }))
assert(not pcall(config.resolve, { disallowedPaths = { key = "data/a" } }))
assert(require("main.src.protocol").VERSION == 11)

assert(config.resolve(nil).disableClientTiremarks == false)
assert(config.resolve({}).disableClientTiremarks == false)
assert(config.resolve({ disableClientTiremarks = true }).disableClientTiremarks == true)
assert(config.resolve({ disableClientTiremarks = false }).disableClientTiremarks == false)
assert(config.resolve({ disableClientTiremarks = "true" }).disableClientTiremarks == false)
assert(config.DEFAULTS.disableClientTiremarks == false)

for _, key in ipairs({ "disableDiscordJoin", "hideDiscordDetails" }) do
	assert(config.DEFAULTS[key] == false)
	assert(config.resolve(nil)[key] == false)
	assert(config.resolve({ [key] = true })[key] == true)
	assert(config.resolve({ [key] = false })[key] == false)
	assert(config.resolve({ [key] = "true" })[key] == false)
end

print("resource pack and tiremark policy config checks passed")
