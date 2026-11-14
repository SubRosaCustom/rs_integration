-- Standalone host test: lua test/path_rules_test.lua (Lua 5.4 or LuaJIT).
package.path = './?.lua;' .. package.path
local sync_paths = require('main.src.sync_paths')

local failures, checked = 0, 0
for line in io.lines('test/path_rules_fixture.txt') do
	local kind, verdict, escaped = line:match('^(%a+) (%a+) ?(.*)$')
	if kind and kind ~= '' and line:sub(1, 1) ~= '#' then
		local path = escaped:gsub('\\x(%x%x)', function(hex) return string.char(tonumber(hex, 16)) end)
		local actual
		if kind == 'path' then
			actual = sync_paths.is_safe_relative(path)
		elseif kind == 'asset' then
			actual = sync_paths.is_safe_asset(path)
		else
			error('unknown fixture kind: ' .. line)
		end
		checked = checked + 1
		if actual ~= (verdict == 'accept') then
			failures = failures + 1
			io.stderr:write(('%s %s expected %s: %q\n'):format(kind, verdict, verdict, path))
		end
	end
end
assert(checked > 0, 'fixture is empty')
assert(failures == 0, failures .. ' path rule mismatches')
print('path_rules_test ok (' .. checked .. ' cases)')
