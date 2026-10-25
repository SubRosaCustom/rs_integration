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

local state = {
 custom_item_types_by_index = { [46] = { index=46, sourceIndex=35, bytes=string.rep("a",0x13D0) } },
 item_type_it3_assignments = { [46] = "sign.it3" },
 item_type_icon_assignments = { [46] = "icon-sign" },
 asset_files_by_path = { ["sign.it3"]={}, ["texture/icon-sign.png"]={} },
}
assert(#item_types.build_sync_payload(state).itemTypes==1)
state.asset_files_by_path={}
local inactive=item_types.build_sync_payload(state)
assert(#inactive.itemTypes==0 and inactive.binRaw=="", "Inactive scoped definitions must clear the client snapshot")
state.asset_files_by_path={ ["sign.it3"]={}, ["texture/icon-sign.png"]={} }
assert(#item_types.build_sync_payload(state).itemTypes==1, "Re-entering the mode restores its definition")
state.asset_files_by_path["texture/icon-sign.png"]=nil
assert(#item_types.build_sync_payload(state).itemTypes==0, "Missing icons must not be sent to joining clients")
print("scoped item snapshot transition passed")

state.item_type_it3_assignments=nil
state.item_type_icon_assignments=nil
state.item_type_texture_assignments={ [46]={kind="builtin",builtin=0} }
assert(#item_types.build_sync_payload(state).itemTypes==1, "Builtin assets need no manifest file")
state.item_type_texture_assignments[46]={kind="file",file="sign"}
assert(#item_types.build_sync_payload(state).itemTypes==0)
state.asset_files_by_path["texture/sign.png"]={}
assert(#item_types.build_sync_payload(state).itemTypes==1)
state.item_type_fire_sound_assignments={ [46]={kind="files",files={"bell"}} }
assert(#item_types.build_sync_payload(state).itemTypes==0)
state.asset_files_by_path["sound/bell.wav"]={}
assert(#item_types.build_sync_payload(state).itemTypes==1)

state.item_type_model_assignments = { [46] = "data/model/sign", }
assert(#item_types.build_sync_payload(state).itemTypes == 0, "Missing CMO models omit the definition")
state.asset_files_by_path["data/model/sign.cmo"] = {}
assert(#item_types.build_sync_payload(state).itemTypes == 1, "The CMO suffix is optional")
state.item_type_model_assignments[46] = "data/model/sign.cmo"
assert(#item_types.build_sync_payload(state).itemTypes == 1, "Full logical CMO paths remain valid")
state.asset_files_by_path["data/model/sign.cmo"] = nil
assert(#item_types.build_sync_payload(state).itemTypes == 0, "Leaving the CMO owner clears its definition")
state.asset_files_by_path["data/model/SIGN.cmo"] = {}
state.asset_paths_folded = { ["data/model/sign.cmo"] = "data/model/SIGN.cmo", }
assert(#item_types.build_sync_payload(state).itemTypes == 1, "CMO lookup uses the folded manifest index")
state.item_type_model_assignments[46] = "sign"
assert(#item_types.build_sync_payload(state).itemTypes == 0, "Bare CMO names do not imply data/model/")
state.asset_files_by_path["sign.cmo"] = {}
assert(#item_types.build_sync_payload(state).itemTypes == 1, "Root-level CMO paths work when present")
print("scoped CMO snapshot transitions passed")
