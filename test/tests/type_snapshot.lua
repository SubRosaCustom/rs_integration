-- Standalone contract check: lua test/tests/type_snapshot.lua (from rs_integration).
package.loaded["main.src.log"] = { info = function() end, warn = error, }
package.loaded["main.src.sync_paths"] = {}
local item_types = require("main.src.item_types")
local vehicle_types = require("main.src.vehicle_types")
local empty = item_types.build_sync_payload({})
assert(#empty.itemTypes == 0 and empty.binRaw == "")
assert(empty.itemTypeSize == 0x13D0)
assert(#vehicle_types.build_sync_payload({}).vehicleTypes == 0)
local snapshot = item_types.build_sync_payload({
 custom_item_types_by_index = {
  [48] = { index = 48, sourceIndex = 35, bytes = string.rep("b", 0x13D0), },
  [46] = { index = 46, sourceIndex = 35, bytes = string.rep("a", 0x13D0), },
 },
})
assert(snapshot.itemTypes[1].index == 46 and snapshot.itemTypes[2].index == 48)
assert(snapshot.binRaw == string.rep("a", 0x13D0) .. string.rep("b", 0x13D0))
print("type snapshot contract passed")
