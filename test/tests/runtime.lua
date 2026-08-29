return function(state, src)
	local network = require("main.src.network")
	local protocol = require("main.src.protocol")

	assert(src.enabled)
	assert(state.enabled)
	assert(state.runtime_active)
	assert(state.hooks_registered)
	assert(state.module_loaded)

	assert(protocol.VERSION == 6)

	assert(type(srcIntegrationNative) == "table")
	assert(type(srcIntegrationNative.sendPacket) == "function")
	assert(type(srcIntegrationNative.drainSrcPackets) == "function")
	assert(type(miniz) == "table")
	assert(type(miniz.createZip) == "function")
	assert(type(miniz.extractZip) == "function")
	assert(src.registerHumanNecktie(11, { male = "tie_m", female = "tie_f", }) == 11)
	assert(src.registerHumanNecklace(3, { male = "neck_m", female = "neck_f", }) == 3)
	assert(state.human_necktie_assignments[11].male == "tie_m")
	assert(state.human_necklace_assignments[3].female == "neck_f")

	local connection = {
		address = "127.0.0.1",
		is_open = true,
	}
	local client = {
		game_address = "127.0.0.1",
		game_port = 27015,
		hello = true,
		hello_payload = {
			phoneNumber = 1234,
		},
		sync_state = "capable",
	}
	state.clients[connection] = client
	assert(network.authorize_account_ticket(
		state,
		{ phoneNumber = 1234, },
		{ address = "127.0.0.1", port = 27015, }
	))
	client.hello = false
	assert(not network.authorize_account_ticket(
		state,
		{ phoneNumber = 1234, },
		{ address = "127.0.0.1", port = 27015, }
	))
	state.clients[connection] = nil

	local attempts = 0
	local function wait_for_tcp_worker()
		attempts = attempts + 1
		if not state.tcp_server or not state.tcp_server.is_listening then
			assert(attempts < 600, state.tcp_server and state.tcp_server.last_error or "TCP worker did not start")
			next_test_tick(wait_for_tcp_worker)
			return
		end

		assert(state.bound_port == server.port)
	end
	next_test_tick(wait_for_tcp_worker)
end
