---@type Plugin
local plugin = ...
plugin.name = "SRC Action Dedupe"
plugin.author = "Sub Rosa Custom"
plugin.description = "Server-side guard against invalid action-ring replay."

local ACTION_RING_SIZE = 64
local CLEARED_ACTION_TYPE = -1
local PRE_PLAYER_ACTIONS_PRIORITY = -1000
local POST_PLAYER_ACTIONS_PRIORITY = 1000

local function ring_distance(from_index, to_index)
	local distance = to_index - from_index
	if distance < 0 then
		distance = distance + ACTION_RING_SIZE
	end
	return distance
end

local function slot_is_pending(last_num_actions, num_actions, slot)
	if last_num_actions == num_actions then
		return false
	end

	if last_num_actions < num_actions then
		return last_num_actions <= slot and slot < num_actions
	end

	return slot >= last_num_actions or slot < num_actions
end

local function clear_action(action)
	action.type = CLEARED_ACTION_TYPE
	action.a = 0
	action.b = 0
	action.c = 0
	action.d = 0
end

local function get_player_state(player)
	local state = player.data.src_action_dedupe
	if state then
		return state
	end

	state = {
		server_last_num_actions = player.lastNumActions,
	}
	player.data.src_action_dedupe = state

	for slot = 0, ACTION_RING_SIZE - 1 do
		if not slot_is_pending(player.lastNumActions, player.numActions, slot) then
			clear_action(player:getAction(slot))
		end
	end

	return state
end

plugin:addHook("PlayerActions", function(player)
	if player.isBot then
		return
	end

	local state = get_player_state(player)

	if player.lastNumActions ~= state.server_last_num_actions then
		player.lastNumActions = state.server_last_num_actions
	end
end, {
	priority = PRE_PLAYER_ACTIONS_PRIORITY,
})

plugin:addHook("PostPlayerActions", function(player)
	if player.isBot then
		return
	end

	local state = get_player_state(player)

	local processed_count = ring_distance(state.server_last_num_actions, player.lastNumActions)
	for offset = 0, processed_count - 1 do
		local slot = (state.server_last_num_actions + offset) % ACTION_RING_SIZE
		clear_action(player:getAction(slot))
	end

	state.server_last_num_actions = player.lastNumActions
end, {
	priority = POST_PLAYER_ACTIONS_PRIORITY,
})
