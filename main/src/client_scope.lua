-- Client plugin entrypoints, not server plugins or per-plugin settings, own assets.
local paths = require("main.src.sync_paths")
local json = require("main.json")
local client_scope = {}
local MAX_SCRIPT_BYTES = 2 * 1024 * 1024

function client_scope.valid_owner(name)
	return type(name) == "string" and name:match("^[A-Za-z0-9_-]+$") ~= nil
end

function client_scope.read_disabled(config)
	local root = paths.scripts_root(config)
	assert(not paths.exists(root) or paths.is_contained(config.clientRoot, root), "Unsafe client scripts root")
	local path = paths.join(root, "disabledPlugins.json")
	if not paths.exists(root) then return {} end
	local listed, entries = pcall(os.listDirectory, root)
	assert(listed and type(entries) == "table", "Cannot inspect client scripts root")
	local present = false
	for _, entry in ipairs(entries) do
		if entry.name == "disabledPlugins.json" then present = true; break end
	end
	if not present then return {} end
	assert(paths.is_contained(root, path), "Unsafe disabledPlugins.json path")
	local source = assert(paths.read_file(path, MAX_SCRIPT_BYTES), "Cannot read disabledPlugins.json")
	assert(source:match("^%s*%["), "Invalid disabledPlugins.json: expected array")
	local ok, decoded = pcall(json.decode, source)
	assert(ok and type(decoded) == "table", "Invalid disabledPlugins.json")
	local disabled = {}
	for key, name in pairs(decoded) do
		assert(type(key) == "number" and client_scope.valid_owner(name), "Invalid disabledPlugins.json entry")
		disabled[name] = true
	end
	return disabled, source
end

function client_scope.names(config, namespace)
	assert(namespace == "plugins" or namespace == "modes")
	local scripts = paths.scripts_root(config)
	local root = paths.join(scripts, namespace)
	local names = {}
	if not paths.is_contained(config.clientRoot, scripts) or not paths.is_contained(scripts, root) then return names end
	local ok, entries = pcall(os.listDirectory, root)
	assert(ok and type(entries) == "table", "Cannot inspect client " .. namespace .. " root: " .. root)
	local found = {}
	for _, entry in ipairs(entries) do
		local name = entry.isDirectory and entry.name or entry.name:match("^(.+)%.lua$")
		if client_scope.valid_owner(name) then
			local path = paths.join(root, entry.name)
			if entry.isDirectory then path = paths.join(path, "init.lua") end
			if paths.is_contained(root, path) then
				-- existence and size only, the snapshot build fails loudly otherwise
				local size = paths.file_size(path)
				assert(size ~= nil, "Cannot read client entry: " .. path)
				assert(size <= MAX_SCRIPT_BYTES, "Client entry exceeds size limit: " .. path)
				found[name] = true
			end
		end
	end
	for name in pairs(found) do names[#names + 1] = name end
	table.sort(names)
	return names
end

function client_scope.enabled(config)
	local disabled, source = client_scope.read_disabled(config)
	local enabled = {}
	for _, name in ipairs(client_scope.names(config, "plugins")) do
		if not disabled[name] then enabled[#enabled + 1] = name end
	end
	return enabled, source
end

function client_scope.signature(config)
	return table.concat(client_scope.enabled(config), "\n")
end

return client_scope
