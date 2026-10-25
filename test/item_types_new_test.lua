-- Run from rs_integration: lua test/item_types_new_test.lua
package.loaded["main.src.log"] = { info = function() end, warn = error, }
local real_type = type
local records, blobs, masses, writes, snapshots = {}, {}, {}, {}, {}
local native_ints, native_floats = {}, {}
local stock_bounds = { x = .078125, y = .234375, z = .078125, }
local stock_grip = string.rep("g", 16)
local ffi = not string.pack and require("ffi")
-- Encode IEEE-754 bytes so the fixture verifies the actual synced physics fields too.
local function float_bytes(value)
	if string.pack then
		local bytes = string.pack("<f", value)
		return bytes, (string.unpack("<f", bytes))
	end
	local native = ffi.new("float[1]", value)
	return ffi.string(native, 4), tonumber(native[0])
end
local stock_inertia = float_bytes(3 / (.234375 ^ 2 + .078125 ^ 2))
	.. float_bytes(3 / (.078125 ^ 2 + .078125 ^ 2))
	.. float_bytes(3 / (.078125 ^ 2 + .234375 ^ 2))
masses[25], blobs[25] = 1, string.rep("s", 0xB0) .. stock_grip .. string.rep("s", 0x13D0 - 0xC0)
local base, pool, stride = 0x100000, 0x5A60D7C0, 0x13D0
local function address(index)
	return base + pool + index * stride
end
itemTypes = setmetatable({}, {
	__index = function(_, index)
		if real_type(index) ~= "number" or not masses[index] or masses[index] <= 0 then return nil end
		if not records[index] then
			records[index] = setmetatable({
				class = "ItemType", index = index,
				boundsCenter = stock_bounds,
				rightHandPos = { x = 0, y = 0, z = 0, },
				leftHandPos = { x = 0, y = 0, z = 0, },
			}, {
				__index = function(_, key)
					if key == "numHands" then return native_ints[index] and native_ints[index][0x7C] end
				end,
				__newindex = function(object, key, value)
					assert(key ~= "isOneHanded" and key ~= "numHands", "native hand fields must not use userdata setters")
					rawset(object, key, value)
				end,
			})
		end
		return records[index]
	end,
})
type = function(value)
	if real_type(value) == "table" and (value.class == "ItemType" or value.class == "Vector") then return "userdata" end
	return real_type(value)
end
memory = {
	getBaseAddress = function() return base end,
	getAddress = function(record) return address(record.index) end,
	readBytes = function(pointer, count)
		local relative = pointer - base - pool
		local index, offset = math.floor(relative / stride), relative % stride
		assert((count == stride and offset == 0) or (count == 16 and offset == 0xB0 and index == 25))
		return assert(blobs[index]):sub(offset + 1, offset + count)
	end,
	writeBytes = function(pointer, bytes)
		local relative = pointer - base - pool
		local index, offset = math.floor(relative / stride), relative % stride
		assert((#bytes == stride and offset == 0) or (#bytes == 16 and (offset == 0xB0 or offset == 0xC0)))
		local previous = blobs[index] or string.rep("\0", stride)
		blobs[index] = previous:sub(1, offset) .. bytes .. previous:sub(offset + #bytes + 1)
		writes[#writes + 1] = pointer
	end,
	writeFloat = function(pointer, value)
		local relative = pointer - base - pool
		local index, offset = math.floor(relative / stride), relative % stride
		assert(offset == 8 or (offset >= 0x104 and offset <= 0x118 and offset % 4 == 0))
		assert(value >= 0 and value < math.huge)
		local bytes, rounded = float_bytes(value)
		native_floats[index] = native_floats[index] or {}
		native_floats[index][offset] = rounded
		if offset == 8 then masses[index] = rounded end
		blobs[index] = blobs[index] or string.rep("\0", stride)
		blobs[index] = blobs[index]:sub(1, offset) .. bytes .. blobs[index]:sub(offset + 5)
	end,
	writeInt = function(pointer, value)
		local relative = pointer - base - pool
		local index, offset = math.floor(relative / stride), relative % stride
		assert(offset == 0x0C or offset == 0x14 or offset == 0x7C or (offset >= 0x5E0 and offset <= 0x5EC and offset % 4 == 0), "only native definition fields may be written")
		assert(value == 0 or value == 1 or (offset == 0x7C and value == 2))
		native_ints[index] = native_ints[index] or {}
		native_ints[index][offset] = value
		local bytes = string.char(value, 0, 0, 0)
		blobs[index] = blobs[index]:sub(1, offset) .. bytes .. blobs[index]:sub(offset + 5)
	end,
}
local state = {}
local src = {
	syncClientItemTypes = function(player, payload)
		assert(player == nil)
		snapshots[#snapshots + 1] = payload
		return true
	end,
}
local module = require("main.src.item_types")
module.install(state, src)
local red = itemTypes.new("red spray can", {
	mass = 0.25, numHands = 1, rightHandPos = { x = 1, y = 2, z = 3, },
	leftHandPos = { class = "Vector", x = -1, y = -2, z = -3, },
})
assert(red.index == 46 and red.name == "red spray can" and masses[46] == 0.25)
assert(red.numHands == 1 and native_ints[46][0x14] == 1 and red.rightHandPos.z == 3)
assert(red.leftHandPos.z == -3, "native Vector fields are copied into their destination")
assert(blobs[46]:sub(1, 8) == string.rep("\0", 8),
	"fresh types keep the cached-hull selector disabled and price zero")
assert(blobs[46]:sub(0x10 + 1, 0x14) == string.rep("\0", 4)
	and blobs[46]:sub(0x18 + 1, 0x30) == string.rep("\0", 0x30 - 0x18),
	"a generic handheld item must not inherit gun, ammunition or projectile defaults")
assert(blobs[46]:sub(0xF0 + 1, 0x104) == string.rep("\0", 0x104 - 0xF0),
	"stock weapon profile values are not required generic item defaults")
assert(blobs[46]:sub(0x5FC + 1, 0x1394) == string.rep("\0", 0x1394 - 0x5FC),
	"geometry and cached collision pointers stay zero until their owning loader runs")

assert(blobs[46]:sub(0xD0 + 1, 0x104) == string.rep("\0", 0x104 - 0xD0)
 and blobs[46]:sub(0x11C + 1, 0x5DC) == string.rep("\0", 0x5DC - 0x11C)
 and blobs[46]:sub(0x13A8 + 1) == string.rep("\0", stride - 0x13A8),
 "fresh storage inherits no unrelated fields or native pointers")
assert(blobs[46]:sub(0xB0 + 1, 0xC0) == stock_grip and blobs[46]:sub(0xC0 + 1, 0xD0) == stock_grip,
 "both hands receive the stock axis-angle grip calibration")
assert(blobs[46]:sub(0x110 + 1, 0x11C) == stock_inertia, "fresh types need nonzero rotational inertia before IT3 loading")
for slot = 1, 4 do
 local flag = native_ints[46][0x5DC + slot * 4]
 assert(flag == 1, "number-key stowing is permitted in every pocket")
 local can_stow = flag ~= 0 and 0 < 2
 assert(can_stow and not (flag ~= 0 and 2 < 2), "native inventory eligibility still respects pocket capacity")
end
assert(not native_ints[46][0x5DC], "non-gun defaults do not enable the holster")
assert(#writes == 3 and writes[1] == address(46) and writes[2] == address(46) + 0xB0
 and writes[3] == address(46) + 0xC0, "fresh storage and both grips are written; physics fields use native float writes")
local blue = itemTypes.new("blue spray can")
assert(blue.index == 47 and blue.name == "blue spray can" and masses[47] == select(2, float_bytes(0.1)))
assert(blue.numHands == 1 and native_ints[47][0x14] == 1)
local payload = snapshots[#snapshots]
assert(#payload.itemTypes == 2 and #payload.binRaw == 2 * stride)
assert(payload.binRaw:sub(0x5E0 + 1, 0x5E0 + 4) == string.char(1, 0, 0, 0)
 and payload.binRaw:sub(0xB0 + 1, 0xC0) == stock_grip,
 "pocket eligibility and grip calibration are included in the synced definition")
assert(payload.binRaw:sub(0x110 + 1, 0x11C) == stock_inertia, "clients receive the corrected rotational inertia in the replacement type snapshot")
assert(payload.itemTypes[1].sourceIndex == 46 and payload.itemTypes[2].sourceIndex == 47,
	"self-source metadata preserves the existing wire contract without copying a model")
assert(state.custom_item_types_by_index[46] and state.custom_item_types_by_index[47])
assert(native_ints[46][0x0C] == 1 and native_ints[47][0x0C] == 1, "new types enable collision")
local before_writes, before_index = #writes, state.next_custom_item_type_index
for _, name in ipairs({ "", string.rep("a", 64), "bad\0name", }) do
	assert(not pcall(itemTypes.new, name))
end
for _, mass in ipairs({ 0, -1, math.huge, "heavy", false, 0 / 0, }) do
	assert(not pcall(itemTypes.new, "bad mass", { mass = mass, }))
end
assert(not pcall(itemTypes.new, "bad fields", false))
assert(not pcall(itemTypes.new, "two names", { name = "other", }))
assert(#writes == before_writes and state.next_custom_item_type_index == before_index,
	"invalid definitions are rejected before allocation or native writes")
masses[25], blobs[25] = 1, string.rep("p", stride)
local cloned = itemTypes.clone(itemTypes[25], { name = "still a clone", })
assert(cloned.index == 48 and cloned.name == "still a clone" and blobs[48] == blobs[25],
	"new and clone share allocation without changing clone semantics")
assert(state.custom_item_types_by_index[48].sourceIndex == 25)
module.install(state, src, true)
assert(itemTypes.new("after reload").index == 49, "forced API reinstall preserves allocation")
local two_handed = itemTypes.new("two hands", { numHands = 2, isOneHanded = false, })
assert(two_handed.numHands == 2 and native_ints[two_handed.index][0x14] == 0, "native hand-field overrides work without setters")
state.next_custom_item_type_index = 254
assert(itemTypes.new("last slot").index == 254)
before_writes = #writes
assert(not pcall(itemTypes.new, "overflow") and #writes == before_writes, "capacity overflow cannot write")
state.next_custom_item_type_index = 50
local box = itemTypes.new("physical box", { boundsCenter = { x = .5, y = .5, z = .5, }, })
local physics = native_floats[box.index]
assert(physics[0x104] == .5 and physics[0x108] == .5 and physics[0x10C] == .5)
assert(physics[0x110] == 6 and physics[0x114] == 6 and physics[0x118] == 6,
	"native box formula gives reciprocal inertia 6 for a unit cube")
local raw = state.custom_item_types_by_index[box.index].bytes
assert(raw:sub(0x104 + 1, 0x110) == float_bytes(.5):rep(3))
assert(raw:sub(0x110 + 1, 0x11C) == float_bytes(6):rep(3), "physics defaults reach the client snapshot")
-- Native CreateItem reciprocates the catalog value; CreateRigidBody reciprocates it again.
-- A unit cube therefore retains a finite, nonzero angular response to an impulse.
local body_inertia = 1 / physics[0x110]
local body_inverse_inertia = 1 / body_inertia
assert(body_inverse_inertia * .01 == .06)
local flat = itemTypes.new("flat box", { boundsCenter = { x = .5, y = 0, z = .5, }, })
assert(native_floats[flat.index][0x110] == 1 and native_floats[flat.index][0x114] == 1
	and native_floats[flat.index][0x118] == 1, "zero extent follows native unit-inertia branch")
local before = state.next_custom_item_type_index
for _, bounds in ipairs({ false, "bad", { x=-1,y=1,z=1 }, { x=1,y=math.huge,z=1 }, { x=1,y=1 }, { x=1,y=0/0,z=1 } }) do
	assert(not pcall(itemTypes.new, "invalid bounds", { boundsCenter=bounds }))
end
assert(state.next_custom_item_type_index == before, "invalid bounds fail before allocating a type")
local sign = itemTypes.new("round sign", { boundsCenter = { x=.7875, y=1.095, z=.52, }, })
local sign_physics = native_floats[sign.index]
assert(math.abs(sign_physics[0x110] - 2.041614917399663) < 1e-6)
assert(math.abs(sign_physics[0x114] - 3.3686810911719505) < 1e-6)
assert(math.abs(sign_physics[0x118] - 1.6490935139090732) < 1e-6,
	"the sign uses its own dimensions rather than the phone inertia profile")
local phone = native_floats[red.index]
assert(phone[0x104] == stock_bounds.x and phone[0x108] == stock_bounds.y and phone[0x10C] == stock_bounds.z,
	"default half-extents must not remain zero")

local before_index, before_writes, before_snapshots = state.next_custom_item_type_index, #writes, #snapshots
for _, mass in ipairs({ 1e-100, 1e100, }) do
	assert(not pcall(itemTypes.new, "unrepresentable mass", { mass = mass, }))
end
for _, extent in ipairs({ 1e-100, 1e100, 1e-20, 1e30, }) do
	assert(not pcall(itemTypes.new, "unrepresentable bounds or inertia", {
		boundsCenter = { x = extent, y = extent, z = extent, },
	}))
end
assert(state.next_custom_item_type_index == before_index and #writes == before_writes
	and #snapshots == before_snapshots and not blobs[before_index],
	"native float underflow/overflow must fail before allocation, writes or publication")
local minimum_mass = itemTypes.new("minimum float mass", { mass = 2 ^ -149, })
assert(masses[minimum_mass.index] == 2 ^ -149, "minimum accepted mass survives native float conversion")
local maximum = (2 - 2 ^ -23) * 2 ^ 127
local maximum_mass = itemTypes.new("maximum float mass", { mass = maximum, })
assert(masses[maximum_mass.index] == maximum, "maximum accepted mass stays finite")
type = real_type
print("PASS: fresh item types, defaults, overrides, sync contract, reload, validation and allocation limits")
