--# selene: allow(unused_variable)
--# selene: allow(unscoped_variables)
---@meta

---A value that can be sent through SRC client/server events:
---nil, boolean, number, string, or a binary blob created with src.blob().
---@alias SrcEventValue nil|boolean|number|string|SrcBlob

do
	---A binary payload for SRC events, created with src.blob().
	---Offsets are 1-based. Readers return nil when out of range.
	---#blob -> size in bytes
	---@class SrcBlob
	local SrcBlob

	---Get the size of the payload in bytes.
	---@return integer size
	function SrcBlob:size() end

	---Get a copy of the raw bytes.
	---@param offset? integer The 1-based start offset. Defaults to 1.
	---@param count? integer How many bytes to read. Defaults to the rest.
	---@return string? bytes The bytes, or nil if the range is invalid.
	function SrcBlob:bytes(offset, count) end

	---Alias of bytes.
	---@param offset? integer The 1-based start offset. Defaults to 1.
	---@param count? integer How many bytes to read. Defaults to the rest.
	---@return string? bytes The bytes, or nil if the range is invalid.
	function SrcBlob:sub(offset, count) end

	---Read a signed 1-byte integer.
	---@param offset integer The 1-based offset.
	---@return integer? value
	function SrcBlob:readByte(offset) end

	---Read an unsigned 1-byte integer.
	---@param offset integer The 1-based offset.
	---@return integer? value
	function SrcBlob:readUByte(offset) end

	---Read a signed big-endian 2-byte integer.
	---@param offset integer The 1-based offset.
	---@return integer? value
	function SrcBlob:readShort(offset) end

	---Read an unsigned big-endian 2-byte integer.
	---@param offset integer The 1-based offset.
	---@return integer? value
	function SrcBlob:readUShort(offset) end

	---Read a signed big-endian 4-byte integer.
	---@param offset integer The 1-based offset.
	---@return integer? value
	function SrcBlob:readInt(offset) end

	---Read an unsigned big-endian 4-byte integer.
	---@param offset integer The 1-based offset.
	---@return integer? value
	function SrcBlob:readUInt(offset) end

	---Read a signed big-endian 8-byte integer.
	---@param offset integer The 1-based offset.
	---@return integer? value
	function SrcBlob:readLong(offset) end

	---Read an unsigned big-endian 8-byte integer.
	---@param offset integer The 1-based offset.
	---@return integer? value
	function SrcBlob:readULong(offset) end

	---Read a big-endian single-precision float.
	---@param offset integer The 1-based offset.
	---@return number? value
	function SrcBlob:readFloat(offset) end

	---Read a big-endian double-precision float.
	---@param offset integer The 1-based offset.
	---@return number? value
	function SrcBlob:readDouble(offset) end
end

---A file record in the sync index, as returned by src.listScripts.
---@class SrcSyncFileRecord
---@field path string The logical sync path, ex. "main/init.lua".
---@field size integer The file size in bytes.
---@field sha256 string The hex SHA-256 of the file contents.
---@field mtime number The file's last modification time.
---@field sourcePath string The server-side path the file was read from.
---@field kind string "script" or "asset".

---Snapshot of a player's SRC client connection state, returned by
---src.getClientState.
---@class SrcClientState
---@field enabled boolean Whether the SRC runtime is enabled on the server.
---@field connected boolean Whether the player has an open, bound SRC connection.
---@field hello boolean Whether the client completed the SRC hello handshake.
---@field scriptCount integer How many script files are in the sync index.
---@field assetFileCount integer How many asset files are in the sync index.
---@field loadedLevel string The level name the sync index was built for.
---@field persistentMode string The persistent mode name synced to clients.
---@field port integer The port the SRC TCP server is bound to.

---A custom human model definition for src.registerHumanModel.
---CMC names are resolved from the synced assets; "data/model/" prefixes and
---".cmc" suffixes are stripped.
---@class SrcHumanModelDef
---@field male string The CMC model name used for male characters.
---@field female string The CMC model name used for female characters.

---A seat position for vehicleTypes.new/clone. A Vector also works.
---@class SrcSeatPosition
---@field x number
---@field y number
---@field z number

---Field overrides for itemTypes.clone.
---Any writable ItemType field name may be used with a number, boolean,
---string or Vector value; they are applied to the cloned type.
---@class SrcItemTypeOverrides
---@field name string?
---@field price integer?
---@field mass number?
---@field fireRate integer?
---@field magazineAmmo integer?
---@field bulletType integer?
---@field bulletVelocity number?
---@field bulletSpread number?
---@field numHands integer?
---@field isGun boolean?
---@field canMountTo table<integer|string, boolean>? Parent item type indices/names mapped to whether the clone can mount to them.

---Definition overrides for vehicleTypes.clone.
---@class SrcVehicleTypeOverrides
---@field index integer? The custom slot to clone into (17-127).
---@field name string?
---@field controllableState integer? 0 = cannot be controlled, 1 = car, 2 = helicopter.
---@field usesExternalModel boolean|integer?
---@field price integer?
---@field mass number?
---@field acceleration number?
---@field model string? The client-side model name.
---@field numSeats integer? The number of seats, 0-4.
---@field seatPos SrcSeatPosition[]? One position per seat.
---@field audio string? The engine audio reference name.
---@field wheelRadius number?
---@field wheelMass number?
