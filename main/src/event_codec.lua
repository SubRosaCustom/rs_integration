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

local unpack_values = table.unpack or unpack
local bit_library = bit32 or bit
assert(bit_library, "main.src.event_codec requires bit32 or bit")

local bxor = bit_library.bxor
local band = bit_library.band

local binary_metatable = {}
binary_metatable.__index = binary_metatable

local function normalize_blob_offset(offset, size)
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

local function normalize_blob_range(bytes, offset, count)
	local size = #bytes
	local start_index = normalize_blob_offset(offset, size)
	if not start_index then
		return nil
	end

	if count == nil then
		return start_index, size - start_index + 1
	end

	count = tonumber(count)
	if not count then
		return nil
	end

	count = math.floor(count)
	if count < 0 or (start_index + count - 1) > size then
		return nil
	end

	return start_index, count
end

local function get_blob_bytes(value)
	if type(value) ~= "table" or getmetatable(value) ~= binary_metatable then
		return nil
	end
	return rawget(value, "data")
end

function binary_metatable:size()
	local bytes = get_blob_bytes(self)
	return bytes and #bytes or 0
end

binary_metatable.len = binary_metatable.size
binary_metatable.length = binary_metatable.size

function binary_metatable:bytes(offset, count)
	local bytes = get_blob_bytes(self)
	if type(bytes) ~= "string" then
		return nil
	end

	local start_index, byte_count = normalize_blob_range(bytes, offset, count)
	if not start_index then
		return nil
	end

	return bytes:sub(start_index, start_index + byte_count - 1)
end

binary_metatable.readBytes = binary_metatable.bytes
binary_metatable.readString = binary_metatable.bytes
binary_metatable.raw = binary_metatable.bytes

local function read_blob_value(blob, offset, width, format)
	local bytes = get_blob_bytes(blob)
	if type(bytes) ~= "string" then
		return nil
	end

	local start_index, byte_count = normalize_blob_range(bytes, offset, width)
	if not start_index or byte_count ~= width then
		return nil
	end

	local ok, value = pcall(string.unpack, format, bytes, start_index)
	if not ok then
		return nil
	end

	return value
end

function binary_metatable:readByte(offset)
	return read_blob_value(self, offset, 1, ">b")
end

function binary_metatable:readUByte(offset)
	return read_blob_value(self, offset, 1, ">B")
end

binary_metatable.byte = binary_metatable.readUByte

function binary_metatable:readShort(offset)
	return read_blob_value(self, offset, 2, ">i2")
end

function binary_metatable:readUShort(offset)
	return read_blob_value(self, offset, 2, ">I2")
end

function binary_metatable:readInt(offset)
	return read_blob_value(self, offset, 4, ">i4")
end

function binary_metatable:readUInt(offset)
	return read_blob_value(self, offset, 4, ">I4")
end

function binary_metatable:readLong(offset)
	return read_blob_value(self, offset, 8, ">i8")
end

function binary_metatable:readULong(offset)
	return read_blob_value(self, offset, 8, ">I8")
end

function binary_metatable:readFloat(offset)
	return read_blob_value(self, offset, 4, ">f")
end

function binary_metatable:readDouble(offset)
	return read_blob_value(self, offset, 8, ">d")
end

binary_metatable.sub = binary_metatable.bytes
binary_metatable.__len = binary_metatable.size

local function u32(value)
	value = band(value, 0xFFFFFFFF)
	if value < 0 then
		value = value + 0x100000000
	end
	return value
end

local function is_integer(value)
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

local function multiply_fnv_prime(hi, lo)
	local output_high, output_low = 0, 0
	for i = 1, #FNV64_SHIFTS do
		local shifted_high, shifted_low = shl64(hi, lo, FNV64_SHIFTS[i])
		output_high, output_low = add64(output_high, output_low, shifted_high, shifted_low)
	end
	return output_high, output_low
end

local function pack_u32(value)
	value = u32(value)
	local b1 = math.floor(value / 0x1000000) % 0x100
	local b2 = math.floor(value / 0x10000) % 0x100
	local b3 = math.floor(value / 0x100) % 0x100
	local b4 = value % 0x100
	return string.char(b1, b2, b3, b4)
end

local function is_blob(value)
	return type(value) == "table" and getmetatable(value) == binary_metatable
end

function M.blob(bytes)
	assert(type(bytes) == "string", "blob(bytes): bytes must be string")
	return setmetatable({ data = bytes }, binary_metatable)
end

function M.is_blob(value)
	return is_blob(value)
end

function M.encode(...)
	local count = select("#", ...)
	local parts = { MAGIC, string.char(VERSION), pack_u32(count) }

	for i = 1, count do
		local value = select(i, ...)
		local value_type = type(value)

		if value == nil then
			parts[#parts + 1] = string.char(TYPE_NIL)
		elseif value_type == "boolean" then
			parts[#parts + 1] = string.char(value and TYPE_TRUE or TYPE_FALSE)
		elseif value_type == "number" then
			if is_integer(value) then
				parts[#parts + 1] = string.char(TYPE_INTEGER) .. string.pack(">i8", math.floor(value))
			else
				parts[#parts + 1] = string.char(TYPE_NUMBER) .. string.pack(">d", value)
			end
		elseif value_type == "string" then
			parts[#parts + 1] = string.char(TYPE_STRING) .. pack_u32(#value) .. value
		elseif is_blob(value) then
			local bytes = rawget(value, "data")
			if type(bytes) ~= "string" then
				return nil, "invalid binary payload"
			end
			parts[#parts + 1] = string.char(TYPE_BINARY) .. pack_u32(#bytes) .. bytes
		else
			return nil, "unsupported value type: " .. value_type
		end
	end

	return table.concat(parts)
end

function M.encode_args(...)
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

		local value_type = string.byte(blob, pos)
		pos = pos + 1

		if value_type == TYPE_NIL then
			values[index] = nil
		elseif value_type == TYPE_FALSE then
			values[index] = false
		elseif value_type == TYPE_TRUE then
			values[index] = true
		elseif value_type == TYPE_INTEGER then
			local value
			value, pos = string.unpack(">i8", blob, pos)
			values[index] = value
		elseif value_type == TYPE_NUMBER then
			local value
			value, pos = string.unpack(">d", blob, pos)
			values[index] = value
		elseif value_type == TYPE_STRING or value_type == TYPE_BINARY then
			local len
			len, pos = string.unpack(">I4", blob, pos)
			if len < 0 or pos + len - 1 > #blob then
				return nil, "truncated string"
			end
			local bytes = blob:sub(pos, pos + len - 1)
			if value_type == TYPE_BINARY then
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

function M.decode_args(blob)
	local values, count_or_error = M.decode(blob)
	if not values then
		return nil, count_or_error
	end

	values.n = count_or_error
	return values
end

function M.unpack(blob)
	local values, count_or_error = M.decode(blob)
	if not values then
		return nil, count_or_error
	end

	return unpack_values(values, 1, count_or_error)
end

function M.hash_name(name)
	if type(name) ~= "string" then
		return nil
	end

	local hi = FNV64_OFFSET_HI
	local lo = FNV64_OFFSET_LO
	for i = 1, #name do
		lo = u32(bxor(lo, name:byte(i)))
		hi, lo = multiply_fnv_prime(hi, lo)
	end

	return pack_u32(hi) .. pack_u32(lo)
end

function M.hex(hash_bytes)
	if type(hash_bytes) ~= "string" then
		return tostring(hash_bytes)
	end

	return (hash_bytes:gsub(".", function(byte)
		return string.format("%02x", byte:byte())
	end))
end

return M
