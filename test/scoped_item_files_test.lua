-- Run from rs_integration: lua test/scoped_item_files_test.lua
package.loaded["main.src.log"] = { info = function() end, warn = error, }
local sent, loaded = {}, {}
package.loaded["main.src.network"] = {
	send_item_type_it3 = function(_, _, index, path) sent[index] = path; return true end,
	send_item_type_itm = function(_, _, index, path) sent[index] = path; return true end,
}
itemTypes = { [46] = { index = 46, class = "ItemType", }, [47] = { index = 47, class = "ItemType", }, }
-- Represent the native ItemType userdata at the game API boundary.
local real_type = type
type = function(value)
	if value == itemTypes[46] or value == itemTypes[47] then return "userdata" end
	return real_type(value)
end
memory = {
	getAddress = function() return 4096 end,
	readBytes = function(_, count) return string.rep("x", count) end,
	writeBytes = function() end,
}
srcIntegrationNative = {
	loadIT3 = function(index, path) loaded[index] = path end,
	loadITM = function(index, path) loaded[index] = path end,
}
local state = { config = { clientRoot = "clientroot", }, asset_files_by_path = {}, }
local src = { syncClientItemTypes = function() return true end, }
require("main.src.item_types").install(state, src)
local real_open = io.open
local files = {
	["clientroot/assets/modes/ninja/ninja_flag.it3"] = true,
	["clientroot/assets/plugins/props/prop.itm"] = true,
	["clientroot/assets/ninja_flag.it3"] = true,
}
io.open = function(path, mode)
	if mode ~= "rb" then return real_open(path, mode) end
	if files[path] then return { close = function() end, } end
end
state.asset_files_by_path["ninja_flag.it3"] = {
	source_path = "clientroot/assets/modes/ninja/ninja_flag.it3",
}
state.asset_files_by_path["prop.itm"] = {
	source_path = "clientroot/assets/plugins/props/prop.itm",
}
assert(src.setItemTypeIT3(46, "ninja_flag.it3"))
assert(loaded[46] == "clientroot/assets/modes/ninja/ninja_flag.it3")
assert(sent[46] == "ninja_flag.it3", "ownership prefixes must not enter client paths")
assert(src.setItemTypeITM(47, "prop.itm"))
assert(loaded[47] == "clientroot/assets/plugins/props/prop.itm" and sent[47] == "prop.itm")
files["clientroot/assets/modes/ninja/ninja_flag.it3"] = nil
assert(not pcall(src.setItemTypeIT3, 46, "ninja_flag.it3"),
	"a missing selected asset must not fall back to stale loose files")
state.asset_files_by_path = {}
assert(src.setItemTypeIT3(46, "ninja_flag.it3"))
assert(loaded[46] == "clientroot/assets/ninja_flag.it3", "preserve legacy server paths")
files["clientroot/assets/ninja_flag.it3"] = nil
assert(not pcall(src.setItemTypeIT3, 46, "ninja_flag.it3"), "missing files must fail")
io.open = real_open
type = real_type
print("PASS: scoped mode/plugin IT3/ITM files, logical client paths, legacy and missing files")
