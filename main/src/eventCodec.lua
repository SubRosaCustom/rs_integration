local M = {}

local MAGIC = "SRCA"
local VERSION = 1

local TYPE_NIL = 0
local TYPE_FALSE = 1
local TYPE_TRUE = 2
local TYPE_INTEGER = 3
local TYPE_NUMBER = 4
local TYPE_STRING = 5
local TYPE_BINARY = 6

local FNV64_OFFSET_HI = 0xCBF29CE4
local FNV64_OFFSET_LO = 0x84222325
local FNV64_SHIFTS = { 0, 1, 4, 5, 7, 8, 40 }

local unpackFn = table.unpack or unpack
local bitLib = bit32 or bit
assert(bitLib, "main.src.eventCodec requires bit32 or bit")

local bxor = bitLib.bxor
local band = bitLib.band

local binaryMetatable = {}
binaryMetatable.__index = binaryMetatable

local function normalizeBlobOffset(offset, size)
	if offset == nil then
		return 1
	end

	offset = tonumber(offset)
	if not offset then
		return nil
	end

	offset = math.floor(offset)
	if offset == 0 then
		offset = 1
	end

	if offset < 1 or offset > (size + 1) then
		return nil
	end

	return offset
end

local function normalizeBlobRange(bytes, offset, count)
	local size = #bytes
	local startIndex = normalizeBlobOffset(offset, size)
	if not startIndex then
		return nil
	end

	if count == nil then
		return startIndex, size - startIndex + 1
	end

	count = tonumber(count)
	if not count then
		return nil
	end

	count = math.floor(count)
	if count < 0 or (startIndex + count - 1) > size then
		return nil
	end

	return startIndex, count
end

local function getBlobBytes(value)
	if type(value) ~= "table" or getmetatable(value) ~= binaryMetatable then
		return nil
	end
	return rawget(value, "data")
end

function binaryMetatable:size()
	local bytes = getBlobBytes(self)
	return bytes and #bytes or 0
end

binaryMetatable.len = binaryMetatable.size
binaryMetatable.length = binaryMetatable.size

function binaryMetatable:bytes(offset, count)
	local bytes = getBlobBytes(self)
	if type(bytes) ~= "string" then
		return nil
	end

	local startIndex, byteCount = normalizeBlobRange(bytes, offset, count)
	if not startIndex then
		return nil
	end

	return bytes:sub(startIndex, startIndex + byteCount - 1)
end

binaryMetatable.readBytes = binaryMetatable.bytes
binaryMetatable.readString = binaryMetatable.bytes
binaryMetatable.raw = binaryMetatable.bytes

local function readBlobValue(blob, offset, width, format)
	local bytes = getBlobBytes(blob)
	if type(bytes) ~= "string" then
		return nil
	end

	local startIndex, byteCount = normalizeBlobRange(bytes, offset, width)
	if not startIndex or byteCount ~= width then
		return nil
	end

	local ok, value = pcall(string.unpack, format, bytes, startIndex)
	if not ok then
		return nil
	end

	return value
end

function binaryMetatable:readByte(offset)
	return readBlobValue(self, offset, 1, ">b")
end

function binaryMetatable:readUByte(offset)
	return readBlobValue(self, offset, 1, ">B")
end

binaryMetatable.byte = binaryMetatable.readUByte

function binaryMetatable:readShort(offset)
	return readBlobValue(self, offset, 2, ">i2")
end

function binaryMetatable:readUShort(offset)
	return readBlobValue(self, offset, 2, ">I2")
end

function binaryMetatable:readInt(offset)
	return readBlobValue(self, offset, 4, ">i4")
end

function binaryMetatable:readUInt(offset)
	return readBlobValue(self, offset, 4, ">I4")
end

function binaryMetatable:readLong(offset)
	return readBlobValue(self, offset, 8, ">i8")
end

function binaryMetatable:readULong(offset)
	return readBlobValue(self, offset, 8, ">I8")
end

function binaryMetatable:readFloat(offset)
	return readBlobValue(self, offset, 4, ">f")
end

function binaryMetatable:readDouble(offset)
	return readBlobValue(self, offset, 8, ">d")
end

binaryMetatable.sub = binaryMetatable.bytes
binaryMetatable.__len = binaryMetatable.size

local function u32(value)
	value = band(value, 0xFFFFFFFF)
	if value < 0 then
		value = value + 0x100000000
	end
	return value
end

local function isInteger(value)
	if type(value) ~= "number" then
		return false
	end

	if math.type then
		return math.type(value) == "integer"
	end

	return value == math.floor(value)
end

local function add64(ahi, alo, bhi, blo)
	local lo = alo + blo
	local carry = 0
	if lo >= 0x100000000 then
		lo = lo - 0x100000000
		carry = 1
	end

	local hi = (ahi + bhi + carry) % 0x100000000
	return hi, lo
end

local function shl64(hi, lo, shift)
	if shift <= 0 then
		return hi, lo
	end

	if shift >= 64 then
		return 0, 0
	end

	if shift >= 32 then
		return u32(lo * (2 ^ (shift - 32))), 0
	end

	return u32((hi * (2 ^ shift)) + math.floor(lo / (2 ^ (32 - shift)))), u32(lo * (2 ^ shift))
end

local function mulFnvPrime(hi, lo)
	local outHi, outLo = 0, 0
	for i = 1, #FNV64_SHIFTS do
		local shiftedHi, shiftedLo = shl64(hi, lo, FNV64_SHIFTS[i])
		outHi, outLo = add64(outHi, outLo, shiftedHi, shiftedLo)
	end
	return outHi, outLo
end

local function packU32(value)
	value = u32(value)
	local b1 = math.floor(value / 0x1000000) % 0x100
	local b2 = math.floor(value / 0x10000) % 0x100
	local b3 = math.floor(value / 0x100) % 0x100
	local b4 = value % 0x100
	return string.char(b1, b2, b3, b4)
end

local function isBlob(value)
	return type(value) == "table" and getmetatable(value) == binaryMetatable
end

function M.blob(bytes)
	assert(type(bytes) == "string", "blob(bytes): bytes must be string")
	return setmetatable({ data = bytes }, binaryMetatable)
end

function M.isBlob(value)
	return isBlob(value)
end

function M.encode(...)
	local count = select("#", ...)
	local parts = { MAGIC, string.char(VERSION), packU32(count) }

	for i = 1, count do
		local value = select(i, ...)
		local valueType = type(value)

		if value == nil then
			parts[#parts + 1] = string.char(TYPE_NIL)
		elseif valueType == "boolean" then
			parts[#parts + 1] = string.char(value and TYPE_TRUE or TYPE_FALSE)
		elseif valueType == "number" then
			if isInteger(value) then
				parts[#parts + 1] = string.char(TYPE_INTEGER) .. string.pack(">i8", math.floor(value))
			else
				parts[#parts + 1] = string.char(TYPE_NUMBER) .. string.pack(">d", value)
			end
		elseif valueType == "string" then
			parts[#parts + 1] = string.char(TYPE_STRING) .. packU32(#value) .. value
		elseif isBlob(value) then
			local bytes = rawget(value, "data")
			if type(bytes) ~= "string" then
				return nil, "invalid binary payload"
			end
			parts[#parts + 1] = string.char(TYPE_BINARY) .. packU32(#bytes) .. bytes
		else
			return nil, "unsupported value type: " .. valueType
		end
	end

	return table.concat(parts)
end

function M.encodeArgs(...)
	return M.encode(...)
end

function M.decode(blob)
	if type(blob) ~= "string" or #blob < 9 then
		return nil, "blob too short"
	end

	local magic, version, count, pos = string.unpack(">c4BI4", blob)
	if magic ~= MAGIC then
		return nil, "invalid magic"
	end
	if version ~= VERSION then
		return nil, "unsupported version"
	end

	local values = {}
	for index = 1, count do
		if pos > #blob then
			return nil, "truncated value"
		end

		local valueType = string.byte(blob, pos)
		pos = pos + 1

		if valueType == TYPE_NIL then
			values[index] = nil
		elseif valueType == TYPE_FALSE then
			values[index] = false
		elseif valueType == TYPE_TRUE then
			values[index] = true
		elseif valueType == TYPE_INTEGER then
			local value
			value, pos = string.unpack(">i8", blob, pos)
			values[index] = value
		elseif valueType == TYPE_NUMBER then
			local value
			value, pos = string.unpack(">d", blob, pos)
			values[index] = value
		elseif valueType == TYPE_STRING or valueType == TYPE_BINARY then
			local len
			len, pos = string.unpack(">I4", blob, pos)
			if len < 0 or pos + len - 1 > #blob then
				return nil, "truncated string"
			end
			local bytes = blob:sub(pos, pos + len - 1)
			if valueType == TYPE_BINARY then
				values[index] = M.blob(bytes)
			else
				values[index] = bytes
			end
			pos = pos + len
		else
			return nil, "unknown value type"
		end
	end

	if pos ~= #blob + 1 then
		return nil, "trailing bytes"
	end

	return values, count
end

function M.decodeArgs(blob)
	local values, countOrErr = M.decode(blob)
	if not values then
		return nil, countOrErr
	end

	values.n = countOrErr
	return values
end

function M.unpack(blob)
	local values, countOrErr = M.decode(blob)
	if not values then
		return nil, countOrErr
	end

	return unpackFn(values, 1, countOrErr)
end

function M.hashName(name)
	if type(name) ~= "string" then
		return nil
	end

	local hi = FNV64_OFFSET_HI
	local lo = FNV64_OFFSET_LO
	for i = 1, #name do
		lo = u32(bxor(lo, name:byte(i)))
		hi, lo = mulFnvPrime(hi, lo)
	end

	return packU32(hi) .. packU32(lo)
end

function M.hex(hashBytes)
	if type(hashBytes) ~= "string" then
		return tostring(hashBytes)
	end

	return (hashBytes:gsub(".", function(byte)
		return string.format("%02x", byte:byte())
	end))
end

return M
