local native_enable = hook.enable
local registered_hooks = {}
local handlers = {}
local tests_started = false

hook.continue = 1
hook.override = 2
hook.persistentMode = ""

function hook.add(event_name, name, func)
	assert(type(event_name) == "string")
	assert(type(name) == "string")
	assert(type(func) == "function")

	local event = registered_hooks[event_name]
	if not event then
		event = {
			order = {},
			by_name = {},
		}
		registered_hooks[event_name] = event
	end
	if not event.by_name[name] then
		event.order[#event.order + 1] = name
	end
	event.by_name[name] = func
	native_enable(event_name)
end

function hook.run(event_name, ...)
	local event = registered_hooks[event_name]
	if not event then
		return false
	end

	for _, name in ipairs(event.order) do
		local result = event.by_name[name](...)
		if result == hook.continue then
			return false
		end
		if result == hook.override or result == true then
			return true
		end
	end
	return false
end

config = {
	src = {
		enabled = true,
		clientRoot = "clientroot",
		autoRefreshEnabled = false,
	},
}

local src = require("main.src.init")
local network = require("main.src.network")
local runtime_state = require("main.src.runtime_state")
local state = runtime_state.get()

local function log(message)
	print(string.format("\27[34;1m[rs_integration test]\27[0m %s", message))
end

local function stop(code, message)
	network.shutdown(state)
	if message then
		log(message)
	end
	os.exit(code)
end

local function protected_call(func)
	local ok, err = pcall(func)
	if not ok then
		stop(1, string.format("\27[31;1m✘\27[0m %s", tostring(err)))
	end
end

function next_test_tick(func, ticks)
	handlers[#handlers + 1] = {
		func = func,
		ticks = ticks or 1,
	}
end

local function require_test(name)
	log(string.format("Starting %s", name))
	require(name)(state, src)
end

local function run_tests()
	require_test("tests.runtime")
	require_test("tests.sync")
	require_test("tests.tcp")
	require_test("tests.udp")
end

hook.add("Logic", "tests", function()
	if not tests_started then
		tests_started = true
		protected_call(run_tests)
		return
	end

	for index = #handlers, 1, -1 do
		local handler = handlers[index]
		handler.ticks = handler.ticks - 1
		if handler.ticks <= 0 then
			table.remove(handlers, index)
			protected_call(handler.func)
		end
	end

	if #handlers == 0 then
		stop(0, "\27[32;1m✔\27[0m All tests passed")
	end
end)
