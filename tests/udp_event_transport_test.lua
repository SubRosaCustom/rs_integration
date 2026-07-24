local test_dir = debug.getinfo(1, "S").source:sub(2):match("(.*/)")
package.path = test_dir .. "../?.lua;" .. package.path

local has_bit, bit = pcall(require, "bit")
if has_bit then
	bit32 = { band = bit.band, bxor = bit.bxor }
else
	bit32 = {
		band = assert(load("return function(left, right) return left & right end"))(),
		bxor = assert(load("return function(left, right) return left ~ right end"))(),
	}
end

package.preload["main.src.log"] = function()
	return { info = function() end, warn = function() end }
end

server = { port = 26950 }
local sent = {}
local drained = { packets = {}, drained = 0, vanillaPending = false }
srcIntegrationNative = {
	randomToken = function()
		return "0123456789abcdef0123456789abcdef"
	end,
	sendPacket = function(address, port, data)
		sent[#sent + 1] = { address = address, port = port, data = data }
		return #data
	end,
	drainSrcPackets = function()
		return drained
	end,
}

local udp_events = require("main.src.udpEvents")
local connection = { isOpen = true, address = "127.0.0.1" }
local client = {
	udpEventsReady = true,
	udp_token = "0123456789abcdef0123456789abcdef",
	player = {
		connection = {
			address = "127.0.0.1",
			port = 26950,
		},
	},
}
local state = { clients = { [connection] = client }, tick = 1 }
local payload = assert(require("main.src.eventCodec").encodeArgs())
local encoded = assert(udp_events.encodeReliableEvent(udp_events.hashEventName("test"), 1, payload))
assert(udp_events.enqueue(client, encoded))

udp_events.onSendPacket(state, "127.0.0.1", 26950)
assert(#sent == 1)
assert(sent[1].port == 26950)
assert(sent[1].data:sub(1, 8) == "7DFPSRCU")
assert(#sent[1].data <= 1200)
assert(#client.udpSendQueue == 0)

drained = {
	packets = {
		{ address = "127.0.0.1", port = 26950, data = sent[1].data },
	},
	drained = 1,
	vanillaPending = false,
}
local decoded, should_override = udp_events.onPacketReceive(state)
assert(#decoded == 1)
assert(decoded[1].connection == connection)
assert(decoded[1].messages[1].msgId == 1)
assert(should_override == true)

drained = { packets = {}, drained = 0, vanillaPending = true }
decoded, should_override = udp_events.onPacketReceive(state)
assert(#decoded == 0)
assert(should_override == false)

package.loaded["main.src.network"] = nil
package.loaded["main.src.udpEvents"] = nil
package.loaded["main.src.eventCodec"] = nil

local received = { kind = 1, msgId = 7, eventHash = "12345678", args = { n = 0 } }
local handled = 0
local acknowledgements = 0

package.preload["main.json"] = function()
	return { encode = function() return "{}" end }
end
package.preload["main.src.shared"] = function()
	return { clientId = function() return "test-client" end }
end
package.preload["main.src.eventCodec"] = function()
	return { encodeArgs = function() return "result" end }
end
package.preload["main.src.udpEvents"] = function()
	return {
		queueAck = function()
			acknowledgements = acknowledgements + 1
		end,
		hashEventName = function()
			return received.eventHash
		end,
		formatEventHash = function()
			return "test"
		end,
		encodeReliableResult = function(_, msg_id)
			return string.format("result:%d", msg_id)
		end,
		enqueue = function(current_client, value)
			current_client.udpSendQueue = current_client.udpSendQueue or {}
			table.insert(current_client.udpSendQueue, value)
			return true
		end,
	}
end

local network = require("main.src.network")
client = {
	hello = true,
	bound = true,
	pendingEvents = {},
	pendingResults = {},
	awaitingResults = {},
	earlyResults = {},
	recentCompleted = {},
}
state = {
	clients = { [connection] = client },
	config = { maxEventBytes = 1024, eventRetryBaseTicks = 20, eventProcessTimeoutTicks = 180 },
	eventHandlers = {},
	eventHandlersByHash = {},
	eventHashesByName = {},
	tick = 1,
	syncGeneration = 7,
	manifestHash = string.rep("a", 64),
}
client.helloPayload = { phoneNumber = 1234 }
client.sync_state = "ready"
client.ready_generation = state.syncGeneration
client.ready_manifest_hash = state.manifestHash
client.game_address = "127.0.0.1"
client.game_port = 26950
assert(network.authorizeAccountTicket(
	state,
	{ phoneNumber = 1234 },
	{ address = "127.0.0.1", port = 26950 }
))
client.ready_generation = state.syncGeneration - 1
assert(not network.authorizeAccountTicket(
	state,
	{ phoneNumber = 1234 },
	{ address = "127.0.0.1", port = 26950 }
))
client.ready_generation = state.syncGeneration
assert(network.onClientEvent(state, "test", function() handled = handled + 1 end))

local datagram = { connection = connection, client = client, messages = { received } }
network.on_udp_datagram(state, datagram)
assert(client.pendingResults[received.msgId], "result was not tracked")
network.on_udp_datagram(state, datagram)
assert(handled == 1, string.format("handler ran %d times", handled))
assert(acknowledgements == 2)

client.pendingResults[received.msgId] = nil
client.recentCompleted[received.msgId] = 100
network.on_udp_datagram(state, datagram)
assert(handled == 1, string.format("completed handler ran %d times", handled))
assert(acknowledgements == 3)
