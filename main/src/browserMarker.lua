local implementation = require("main.src.browser_marker")

return {
	onSendPacket = implementation.on_send_packet,
	onPostSendPacket = implementation.on_post_send_packet,
}
