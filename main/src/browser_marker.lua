local protocol = require("main.src.protocol")

local M = {}

local PACKET_SIZE_ADDRESS = 0x39075C7C
local PACKET_BIT_OFFSET_ADDRESS = 0x39075C80
local PACKET_ADDRESS = 0x39075C84
local MAX_PACKET_SIZE = 0x10000
local MARKER = "SRCE"
local BASE_ADDRESS = memory.getBaseAddress()

local function normalize_port(port)
	local number_port = tonumber(port)
	if not number_port then
		return nil
	end
	number_port = math.floor(number_port)
	if number_port < 0 or number_port > 65535 then
		return nil
	end
	return number_port
end

local function endpoint_has_src_client(state, address, port)
	if type(state) ~= "table" or type(state.clients) ~= "table" then
		return false
	end

	local normalized_address = tostring(address)
	local normalized_port = normalize_port(port)
	if not normalized_port then
		return false
	end

	for connection, _ in pairs(state.clients) do
		if connection
			and connection.is_open
			and tostring(connection.address) == normalized_address
			and normalize_port(connection.port) == normalized_port then
			return true
		end
	end

	return false
end

function M.on_send_packet(state, address, port)
	local has_src_client = endpoint_has_src_client(state, address, port)
	if has_src_client then
		return
	end

	local packet_size = memory.readInt(BASE_ADDRESS + PACKET_SIZE_ADDRESS)
	if type(packet_size) ~= "number" or packet_size < 5 or packet_size >= MAX_PACKET_SIZE then
		return
	end
	local packet_bit_offset = memory.readInt(BASE_ADDRESS + PACKET_BIT_OFFSET_ADDRESS)
	if type(packet_bit_offset) ~= "number" or packet_bit_offset < 0 then
		packet_bit_offset = 0
	end
	local aligned_size = packet_size + (packet_bit_offset > 0 and 1 or 0)
	if aligned_size < 5 or aligned_size >= MAX_PACKET_SIZE then
		return
	end

	local header = memory.readBytes(BASE_ADDRESS + PACKET_ADDRESS, 5)
	if type(header) ~= "string" or #header ~= 5 or header:byte(5) ~= 1 then
		return
	end

	local trailer = MARKER .. string.pack(">I2", protocol.VERSION)
	if aligned_size + #trailer > MAX_PACKET_SIZE then
		return
	end

	local original_tail = memory.readBytes(BASE_ADDRESS + PACKET_ADDRESS + aligned_size, #trailer)
	if not original_tail or #original_tail ~= #trailer then
		original_tail = string.rep("\0", #trailer)
	end

	memory.writeBytes(BASE_ADDRESS + PACKET_ADDRESS + aligned_size, trailer)
	memory.writeInt(BASE_ADDRESS + PACKET_SIZE_ADDRESS, aligned_size + #trailer)
	if packet_bit_offset > 0 then
		memory.writeInt(BASE_ADDRESS + PACKET_BIT_OFFSET_ADDRESS, 0)
	end

	state.browser_marker_mutation_stack = state.browser_marker_mutation_stack or {}
	state.browser_marker_mutation_stack[#state.browser_marker_mutation_stack + 1] = {
		original_size = packet_size,
		original_bit_offset = packet_bit_offset,
		aligned_size = aligned_size,
		original_tail = original_tail,
	}
end

function M.on_post_send_packet(state)
	if type(state) ~= "table" or type(state.browser_marker_mutation_stack) ~= "table" then
		return
	end

	local mutation = table.remove(state.browser_marker_mutation_stack)
	if not mutation then
		return
	end

	memory.writeBytes(BASE_ADDRESS + PACKET_ADDRESS + mutation.aligned_size, mutation.original_tail)
	memory.writeInt(BASE_ADDRESS + PACKET_SIZE_ADDRESS, mutation.original_size)
	memory.writeInt(BASE_ADDRESS + PACKET_BIT_OFFSET_ADDRESS, mutation.original_bit_offset or 0)
end

return M
