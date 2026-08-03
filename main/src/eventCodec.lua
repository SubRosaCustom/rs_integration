local implementation = require("main.src.event_codec")

return {
	blob = implementation.blob,
	isBlob = implementation.is_blob,
	encode = implementation.encode,
	encodeArgs = implementation.encode_args,
	decode = implementation.decode,
	decodeArgs = implementation.decode_args,
	unpack = implementation.unpack,
	hashName = implementation.hash_name,
	hex = implementation.hex,
}
