-- Run from rs_integration: lua test/tests/world_mutations.lua
local world_mutations = require("main.src.world_mutations")
local hooks = {}
local events = {}
local deleted = 0

hook = {
	add = function(event, name, callback)
		hooks[event] = callback
	end,
}
physics = {
	getBlock = function() return 1 end,
	deleteBlock = function() deleted = deleted + 1 end,
}
local state = {}
local src = {
	enabled = true,
	emitClientEvent = function(player, name, ...)
		events[#events + 1] = { player = player, name = name, args = { ... }, }
		return true
	end,
}
world_mutations.install(state, src)

-- Startup/map construction must not send or retain deletions.
assert(src.deleteBlock(1, 2, 3))
hooks.PostAreaDeleteBlock(4, 5, 6)
world_mutations.sync(state, src, "joining player")
assert(deleted == 1 and #events == 0)
assert(next(state.deleted_world_blocks) == nil)

hooks.PostResetGame()
assert(#events == 1 and events[1].name == "src.world.resetBlocks")
assert(src.deleteBlock(1, 2, 3))
hooks.PostAreaDeleteBlock(4, 5, 6)
assert(#events == 3)
assert(events[2].name == "src.world.deleteBlock")
assert(events[3].name == "src.world.deleteBlock")
world_mutations.sync(state, src, "joining player")
assert(#events == 6)

-- Reload preserves the active map's mutation tracking.
world_mutations.install(state, src)
assert(state.world_mutations_ready)

hooks.ResetGame()
local before_reset = #events
for x = 1, 1000 do
	hooks.PostAreaDeleteBlock(x, 0, 0)
	assert(src.deleteBlock(x, 0, 0))
end
world_mutations.sync(state, src, "joining during reset")
assert(#events == before_reset)
assert(next(state.deleted_world_blocks) == nil)

hooks.PostResetGame()
assert(#events == before_reset + 1)
local generation = events[#events].args[1]
world_mutations.sync(state, src, "joining after reset")
assert(#events == before_reset + 2)
assert(events[#events].name == "src.world.resetBlocks")
hooks.PostAreaDeleteBlock(7, 8, 9)
assert(events[#events].name == "src.world.deleteBlock")
assert(events[#events].args[1] == generation)
assert(state.deleted_world_blocks["1:2:3"] == nil)

print("world mutation reset contract passed")
