local M = {}

local DELETE_EVENT = "src.world.deleteBlock"
local RESET_EVENT = "src.world.resetBlocks"

local function coordinate(value, name)
	assert(type(value) == "number" and value == math.floor(value), name .. " must be an integer")
	return value
end

local function key(x, y, z)
	return string.format("%d:%d:%d", x, y, z)
end

function M.install(state, src)
	state.world_mutation_generation = state.world_mutation_generation or 1
	state.deleted_world_blocks = state.deleted_world_blocks or {}

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
		emit_delete(nil, record_delete(x, y, z))
		return true
	end

	hook.add("PostAreaDeleteBlock", "main.src.worldMutations", function(x, y, z)
		if src.enabled then
			emit_delete(nil, record_delete(x, y, z))
		end
	end)

	hook.add("PostResetGame", "main.src.worldMutations", reset_mutations)
end

function M.sync(state, src, player)
	if type(src) ~= "table" or type(src.emitClientEvent) ~= "function" then
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

return M
