-- disabled: one reliable event per deleted block overflowed the 32-per-peer cap and desynced clients.
-- restore only after batching deletions into bounded snapshots.
local world_mutations = {}

local DELETE_EVENT = "src.world.deleteBlock"
local RESET_EVENT = "src.world.resetBlocks"

local function coordinate(value, name)
	assert(type(value) == "number" and value == math.floor(value), name .. " must be an integer")
	return value
end

local function key(x, y, z)
	return string.format("%d:%d:%d", x, y, z)
end

function world_mutations.install(state, src)
	state.world_mutation_generation = state.world_mutation_generation or 1
	state.deleted_world_blocks = state.deleted_world_blocks or {}
	state.world_mutations_ready = state.world_mutations_ready == true

	local function emit_delete(player, cell)
		return src.emitClientEvent(
			player,
			DELETE_EVENT,
			state.world_mutation_generation,
			cell.x,
			cell.y,
			cell.z
		)
	end

	local function record_delete(x, y, z)
		local cell = { x = x, y = y, z = z }
		state.deleted_world_blocks[key(x, y, z)] = cell
		return cell
	end

	local function reset_mutations()
		state.world_mutation_generation = state.world_mutation_generation + 1
		state.deleted_world_blocks = {}
		state.world_mutations_ready = true
		if src.enabled then
			src.emitClientEvent(nil, RESET_EVENT, state.world_mutation_generation)
		end
	end

	function src.deleteBlock(x, y, z)
		x = coordinate(x, "x")
		y = coordinate(y, "y")
		z = coordinate(z, "z")
		if physics.getBlock(x, y, z) == 0 then
			return false
		end

		physics.deleteBlock(x, y, z)
		if state.world_mutations_ready then
			emit_delete(nil, record_delete(x, y, z))
		end
		return true
	end

	hook.add("PostAreaDeleteBlock", "main.src.worldMutations", function(x, y, z)
		if src.enabled and state.world_mutations_ready then
			emit_delete(nil, record_delete(x, y, z))
		end
	end)

	hook.add("ResetGame", "main.src.worldMutations", function()
		state.world_mutations_ready = false
		state.deleted_world_blocks = {}
	end)

	hook.add("PostResetGame", "main.src.worldMutations", reset_mutations)
end

function world_mutations.sync(state, src, player)
	if not state.world_mutations_ready or type(src) ~= "table"
		or type(src.emitClientEvent) ~= "function" then
		return
	end

	src.emitClientEvent(player, RESET_EVENT, state.world_mutation_generation)
	for _, cell in pairs(state.deleted_world_blocks) do
		src.emitClientEvent(
			player,
			DELETE_EVENT,
			state.world_mutation_generation,
			cell.x,
			cell.y,
			cell.z
		)
	end
end

return world_mutations
