local test_dir = debug.getinfo(1, "S").source:sub(2):match("(.*/)")
package.path = test_dir .. "../?.lua;" .. package.path

bit32 = {
	band = function(left, right) return left & right end,
	bxor = function(left, right) return left ~ right end,
}

package.preload["main.src.log"] = function()
	return { info = function() end, warn = function() end }
end

server = { port = 26950 }
local sent = {}
local base_address = 0x1000
local packet_read_address = base_address + 0x39085C84
local packet_read_port = base_address + 0x39085C88
local recv_packet_size = base_address + 0x39085C98
local recv_packet = base_address + 0x39085CA4
local ints = {}
local received_bytes = ""
memory = {
	getBaseAddress = function() return base_address end,
	readInt = function(address) return ints[address] end,
	writeInt = function(address, value)
		ints[address] = value
	end,
	readBytes = function(address, size)
		if address == recv_packet then
			return received_bytes:sub(1, size)
		end
	end,
	writeBytes = function(address, value)
		if address == recv_packet then
			received_bytes = value
		end
	end,
}
srcIntegrationNative = {
	randomToken = function()
		return "0123456789abcdef"
	end,
	sendPacket = function(address, port, data)
		sent[#sent + 1] = { address = address, port = port, data = data }
		return #data
	end,
}

local udp_events = require("main.src.udpEvents")
local connection = { isOpen = true, address = "127.0.0.1" }
local client = {
	udpEventsReady = true,
	udp_token = "0123456789abcdef",
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

received_bytes = sent[1].data
ints[packet_read_address] = 0x7F000001
ints[packet_read_port] = 26950
ints[recv_packet_size] = #received_bytes
local decoded = udp_events.onPostPacketReceive(state)
assert(decoded.connection == connection)
assert(decoded.messages[1].msgId == 1)
assert(ints[recv_packet_size] == 0)

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
}
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
