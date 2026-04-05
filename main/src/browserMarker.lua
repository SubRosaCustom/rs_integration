local M = {}

local PACKET_SIZE_ADDRESS = 0x39075C7C
local PACKET_BIT_OFFSET_ADDRESS = 0x39075C80
local PACKET_ADDRESS = 0x39075C84
local MAX_PACKET_SIZE = 0x10000
local MARKER = "SRCE"
local PROTOCOL_VERSION = 1

local function has_memory_api()
	return type(memory) == "table"
		and type(memory.get_base_address) == "function"
		and type(memory.read_bytes) == "function"
		and type(memory.write_bytes) == "function"
		and type(memory.read_int) == "function"
		and type(memory.write_int) == "function"
end

local function get_base_address()
	local ok, value = pcall(memory.get_base_address)
	if not ok or type(value) ~= "number" or value == 0 then
		return nil
	end
	return math.floor(value)
end

local function resolve_address(offset)
	local baseAddress = get_base_address()
	if not baseAddress then
		return nil
	end
	return baseAddress + offset
end

local function read_int(offset)
	local address = resolve_address(offset)
	if not address then
		return nil
	end
	local ok, value = pcall(memory.read_int, address)
	if not ok or type(value) ~= "number" then
		return nil
	end
	return math.floor(value)
end

local function write_int(offset, value)
	local address = resolve_address(offset)
	if not address then
		return false
	end
	local ok = pcall(memory.write_int, address, math.floor(value))
	return ok
end

local function read_bytes(offset, size)
	local address = resolve_address(offset)
	if not address then
		return nil
	end
	local ok, value = pcall(memory.read_bytes, address, size)
	if not ok or type(value) ~= "string" then
		return nil
	end
	return value
end

local function write_bytes(offset, value)
	local address = resolve_address(offset)
	if not address then
		return false
	end
	local ok = pcall(memory.write_bytes, address, value)
	return ok
end

local function normalize_port(port)
	local numberPort = tonumber(port)
	if not numberPort then
		return nil
	end
	numberPort = math.floor(numberPort)
	if numberPort < 0 or numberPort > 65535 then
		return nil
	end
	return numberPort
end

local function endpoint_has_srcclient(state, address, port)
	if type(state) ~= "table" or type(state.clients) ~= "table" then
		return false
	end

	local normalizedAddress = tostring(address)
	local normalizedPort = normalize_port(port)
	if not normalizedPort then
		return false
	end

	for connection, _ in pairs(state.clients) do
		if connection
			and connection.isOpen
			and tostring(connection.address) == normalizedAddress
			and normalize_port(connection.port) == normalizedPort then
			return true
		end
	end

	return false
end

function M.onSendPacket(state, address, port)
	local hasSRCClient = endpoint_has_srcclient(state, address, port)
	if not has_memory_api() or hasSRCClient then
		return
	end

	local packetSize = read_int(PACKET_SIZE_ADDRESS)
	if type(packetSize) ~= "number" or packetSize < 5 or packetSize >= MAX_PACKET_SIZE then
		return
	end
	local packetBitOffset = read_int(PACKET_BIT_OFFSET_ADDRESS)
	if type(packetBitOffset) ~= "number" or packetBitOffset < 0 then
		packetBitOffset = 0
	end
	local alignedSize = packetSize + (packetBitOffset > 0 and 1 or 0)
	if alignedSize < 5 or alignedSize >= MAX_PACKET_SIZE then
		return
	end

	local header = read_bytes(PACKET_ADDRESS, 5)
	if type(header) ~= "string" or #header ~= 5 or header:byte(5) ~= 1 then
		return
	end

	local trailer = MARKER .. string.pack(">I2", PROTOCOL_VERSION)
	if alignedSize + #trailer > MAX_PACKET_SIZE then
		return
	end

	local originalTail = read_bytes(PACKET_ADDRESS + alignedSize, #trailer)
	if not originalTail or #originalTail ~= #trailer then
		originalTail = string.rep("\0", #trailer)
	end

	if not write_bytes(PACKET_ADDRESS + alignedSize, trailer) then
		return
	end
	if not write_int(PACKET_SIZE_ADDRESS, alignedSize + #trailer) then
		write_bytes(PACKET_ADDRESS + alignedSize, originalTail)
		return
	end
	if packetBitOffset > 0 and not write_int(PACKET_BIT_OFFSET_ADDRESS, 0) then
		write_bytes(PACKET_ADDRESS + alignedSize, originalTail)
		write_int(PACKET_SIZE_ADDRESS, packetSize)
		return
	end

	state.browserMarkerMutationStack = state.browserMarkerMutationStack or {}
	state.browserMarkerMutationStack[#state.browserMarkerMutationStack + 1] = {
		originalSize = packetSize,
		originalBitOffset = packetBitOffset,
		alignedSize = alignedSize,
		originalTail = originalTail,
	}
end

function M.onPostSendPacket(state)
	if not has_memory_api() or type(state) ~= "table" or type(state.browserMarkerMutationStack) ~= "table" then
		return
	end

	local mutation = table.remove(state.browserMarkerMutationStack)
	if not mutation then
		return
	end

	write_bytes(PACKET_ADDRESS + mutation.alignedSize, mutation.originalTail)
	write_int(PACKET_SIZE_ADDRESS, mutation.originalSize)
	write_int(PACKET_BIT_OFFSET_ADDRESS, mutation.originalBitOffset or 0)
end

return M
