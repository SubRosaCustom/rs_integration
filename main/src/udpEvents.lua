local implementation = require("main.src.udp_events")

return {
	resetClient = implementation.reset_client,
	binary = implementation.binary,
	hashEventName = implementation.hash_event_name,
	formatEventHash = implementation.format_event_hash,
	encodeReliableEvent = implementation.encode_reliable_event,
	encodeReliableAckBatch = implementation.encode_reliable_ack_batch,
	encodeReliableResult = implementation.encode_reliable_result,
	enqueue = implementation.enqueue,
	queueAck = implementation.queue_ack,
	new_token = implementation.new_token,
	onSendPacket = implementation.on_send_packet,
	onPacketReceive = implementation.on_packet_receive,
}
