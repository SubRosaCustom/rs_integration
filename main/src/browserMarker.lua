local M = {}

local PACKET_SIZE_ADDRESS = 0x39075C7C
local PACKET_BIT_OFFSET_ADDRESS = 0x39075C80
local PACKET_ADDRESS = 0x39075C84
local MAX_PACKET_SIZE = 0x10000
local MARKER = "SRCE"
local PROTOCOL_VERSION = 5

local function getBaseAddress()
	local ok, value = pcall(memory.getBaseAddress)
	if not ok or type(value) ~= "number" or value == 0 then
		return nil
	end
	return math.floor(value)
end

local function resolveAddress(offset)
	local baseAddress = getBaseAddress()
	if not baseAddress then
		return nil
	end
	return baseAddress + offset
end

local function readInt(offset)
	local address = resolveAddress(offset)
	if not address then
		return nil
	end
	local ok, value = pcall(memory.readInt, address)
	if not ok or type(value) ~= "number" then
		return nil
	end
	return math.floor(value)
end

local function writeInt(offset, value)
	local address = resolveAddress(offset)
	if not address then
		return false
	end
	local ok = pcall(memory.writeInt, address, math.floor(value))
	return ok
end

local function readBytes(offset, size)
	local address = resolveAddress(offset)
	if not address then
		return nil
	end
	local ok, value = pcall(memory.readBytes, address, size)
	if not ok or type(value) ~= "string" then
		return nil
	end
	return value
end

local function writeBytes(offset, value)
	local address = resolveAddress(offset)
	if not address then
		return false
	end
	local ok = pcall(memory.writeBytes, address, value)
	return ok
end

local function normalizePort(port)
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

local function endpointHasSRCClient(state, address, port)
	if type(state) ~= "table" or type(state.clients) ~= "table" then
		return false
	end

	local normalizedAddress = tostring(address)
	local normalizedPort = normalizePort(port)
	if not normalizedPort then
		return false
	end

	for connection, _ in pairs(state.clients) do
		if connection
			and connection.isOpen
			and tostring(connection.address) == normalizedAddress
			and normalizePort(connection.port) == normalizedPort then
			return true
		end
	end

	return false
end

function M.onSendPacket(state, address, port)
	local hasSRCClient = endpointHasSRCClient(state, address, port)
	if hasSRCClient then
		return
	end

	local packetSize = readInt(PACKET_SIZE_ADDRESS)
	if type(packetSize) ~= "number" or packetSize < 5 or packetSize >= MAX_PACKET_SIZE then
		return
	end
	local packetBitOffset = readInt(PACKET_BIT_OFFSET_ADDRESS)
	if type(packetBitOffset) ~= "number" or packetBitOffset < 0 then
		packetBitOffset = 0
	end
	local alignedSize = packetSize + (packetBitOffset > 0 and 1 or 0)
	if alignedSize < 5 or alignedSize >= MAX_PACKET_SIZE then
		return
	end

	local header = readBytes(PACKET_ADDRESS, 5)
	if type(header) ~= "string" or #header ~= 5 or header:byte(5) ~= 1 then
		return
	end

	local trailer = MARKER .. string.pack(">I2", PROTOCOL_VERSION)
	if alignedSize + #trailer > MAX_PACKET_SIZE then
		return
	end

	local originalTail = readBytes(PACKET_ADDRESS + alignedSize, #trailer)
	if not originalTail or #originalTail ~= #trailer then
		originalTail = string.rep("\0", #trailer)
	end

	if not writeBytes(PACKET_ADDRESS + alignedSize, trailer) then
		return
	end
	if not writeInt(PACKET_SIZE_ADDRESS, alignedSize + #trailer) then
		writeBytes(PACKET_ADDRESS + alignedSize, originalTail)
		return
	end
	if packetBitOffset > 0 and not writeInt(PACKET_BIT_OFFSET_ADDRESS, 0) then
		writeBytes(PACKET_ADDRESS + alignedSize, originalTail)
		writeInt(PACKET_SIZE_ADDRESS, packetSize)
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
	if type(state) ~= "table" or type(state.browserMarkerMutationStack) ~= "table" then
		return
	end

	local mutation = table.remove(state.browserMarkerMutationStack)
	if not mutation then
		return
	end

	writeBytes(PACKET_ADDRESS + mutation.alignedSize, mutation.originalTail)
	writeInt(PACKET_SIZE_ADDRESS, mutation.originalSize)
	writeInt(PACKET_BIT_OFFSET_ADDRESS, mutation.originalBitOffset or 0)
end

return M
