return function(state, src)
	local protocol = require("main.src.protocol")

	assert(src.enabled)
	assert(state.enabled)
	assert(state.runtimeActive)
	assert(state.hooksRegistered)
	assert(state.moduleLoaded)

	assert(protocol.VERSION == 5)

	assert(type(srcIntegrationNative) == "table")
	assert(type(srcIntegrationNative.sendPacket) == "function")
	assert(type(srcIntegrationNative.drainSrcPackets) == "function")
	assert(type(miniz) == "table")
	assert(type(miniz.createZip) == "function")
	assert(type(miniz.extractZip) == "function")

	local attempts = 0
	local function wait_for_tcp_worker()
		attempts = attempts + 1
		if not state.tcpServer or not state.tcpServer.isListening then
			assert(attempts < 600, state.tcpServer and state.tcpServer.last_error or "TCP worker did not start")
			next_test_tick(wait_for_tcp_worker)
			return
		end

		assert(state.boundPort == server.port)
	end
	next_test_tick(wait_for_tcp_worker)
end
