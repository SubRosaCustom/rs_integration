--# selene: allow(unused_variable)
--# selene: allow(unscoped_variables)
---@meta

-- See globals.lua for the published baseline and LOCAL-ONLY availability notes.

---Configuration under config.src. Resource restrictions apply only to this server session.
---@class SrcConfig
---@field enabled boolean Defaults to true.
---@field disallowNonSRCPlayers boolean Defaults to false; enforces SRC admission after the grace period.
---@field clientRoot string Defaults to "subrosacustom". Scripts and selected mode/plugin asset owners live here.
---@field disallowedPaths string[] Exact game-root-relative paths that local resource packs cannot replace. Empty clears the policy; no glob or prefix matching. Maximum 4096 input entries.
---@field motd string Browser text, truncated to 160 bytes. Defaults to an empty string.
---@field motdIcon string Path to an exact 32x32 PNG smaller than 5 KiB, relative to the server working directory. Defaults to an empty string.
---@field motdIconData string Derived base64 icon data; configure motdIcon instead.
---@field readSize number Defaults to 16384; minimum 1024.
---@field fileChunkSize number Defaults to 65536; minimum 256.
---@field maxReadBytesPerTick number Defaults to 262144; minimum 4096.
---@field maxSendBytesPerTick number Defaults to 1048576; minimum 4096.
---@field maxFileChunksPerTick number Defaults to 16; minimum 1.
---@field maxQueuedSendFrames number Defaults to 64; minimum 8.
---@field autoRefreshEnabled boolean Defaults to false.
---@field autoRefreshDebounceTicks number Defaults to 20; minimum 1.
---@field eventRetryBaseTicks number Defaults to 20; minimum 1.
---@field eventRetryMaxAttempts number Defaults to 5; minimum 1.
---@field maxEventBytes integer Complete encoded argument limit, clamped to 1024-262144; defaults to 262144.
---@field eventProcessTimeoutTicks number Defaults to 180; minimum 1.
---@field eventDebugLogSuccess boolean Defaults to false.

---A value that can be sent through SRC client/server events:
---nil, boolean, number, string, or a binary blob created with src.blob().
---@alias SrcEventValue nil|boolean|number|string|SrcBlob

do
	---A binary payload for SRC events, created with src.blob().
	---Offsets are 1-based; omitted or zero offsets select byte 1. Readers return nil when out of range.
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
	---@param offset? integer The 1-based offset. Defaults to 1; offset 0 also selects the first byte.
	---@return integer? value
	function SrcBlob:readByte(offset) end

	---Read an unsigned 1-byte integer.
	---@param offset? integer The 1-based offset. Defaults to 1; offset 0 also selects the first byte.
	---@return integer? value
	function SrcBlob:readUByte(offset) end

	---Read a signed big-endian 2-byte integer.
	---@param offset? integer The 1-based offset. Defaults to 1; offset 0 also selects the first byte.
	---@return integer? value
	function SrcBlob:readShort(offset) end

	---Read an unsigned big-endian 2-byte integer.
	---@param offset? integer The 1-based offset. Defaults to 1; offset 0 also selects the first byte.
	---@return integer? value
	function SrcBlob:readUShort(offset) end

	---Read a signed big-endian 4-byte integer.
	---@param offset? integer The 1-based offset. Defaults to 1; offset 0 also selects the first byte.
	---@return integer? value
	function SrcBlob:readInt(offset) end

	---Read an unsigned big-endian 4-byte integer.
	---@param offset? integer The 1-based offset. Defaults to 1; offset 0 also selects the first byte.
	---@return integer? value
	function SrcBlob:readUInt(offset) end

	---Read a signed big-endian 8-byte integer.
	---@param offset? integer The 1-based offset. Defaults to 1; offset 0 also selects the first byte.
	---@return integer? value
	function SrcBlob:readLong(offset) end

	---Read an unsigned big-endian 8-byte integer.
	---@param offset? integer The 1-based offset. Defaults to 1; offset 0 also selects the first byte.
	---@return integer? value
	function SrcBlob:readULong(offset) end

	---Read a big-endian single-precision float.
	---@param offset? integer The 1-based offset. Defaults to 1; offset 0 also selects the first byte.
	---@return number? value
	function SrcBlob:readFloat(offset) end

	---Read a big-endian double-precision float.
	---@param offset? integer The 1-based offset. Defaults to 1; offset 0 also selects the first byte.
	---@return number? value
	function SrcBlob:readDouble(offset) end

	---Alias of size.
	---@return integer size
	function SrcBlob:len() end

	---Alias of size.
	---@return integer size
	function SrcBlob:length() end

	---Alias of bytes; returns raw byte strings without decoding.
	---@param offset? integer Defaults to 1.
	---@param count? integer Defaults to the remaining bytes.
	---@return string? bytes
	function SrcBlob:readBytes(offset, count) end

	---Alias of bytes; returns raw byte strings without decoding.
	---@param offset? integer Defaults to 1.
	---@param count? integer Defaults to the remaining bytes.
	---@return string? bytes
	function SrcBlob:readString(offset, count) end

	---Alias of bytes; returns raw byte strings without decoding.
	---@param offset? integer Defaults to 1.
	---@param count? integer Defaults to the remaining bytes.
	---@return string? bytes
	function SrcBlob:raw(offset, count) end

	---Alias of readUByte, not the signed readByte.
	---@param offset? integer Defaults to 1.
	---@return integer? value
	function SrcBlob:byte(offset) end
end

---A file record in the sync index, as returned by src.listScripts.
---@class SrcSyncFileRecord
---@field path string The logical sync path, ex. "main/init.lua".
---@field size integer The file size in bytes.
---@field sha256 string The hex SHA-256 of the file contents.
---@field mtime number The file's last modification time.
---@field source_path string The server-side path the file was read from.
---@field kind string "script" or "asset".

---Snapshot of a player's SRC client connection state, returned by
---src.getClientState.
---@class SrcClientState
---@field enabled boolean Whether the SRC runtime is enabled on the server.
---@field connected boolean Whether the player has an open, bound SRC connection.
---@field hello boolean Whether the client completed the SRC hello handshake.
---@field syncState string The current sync state, or "disconnected".
---@field ready boolean Whether the client completed the current sync generation.
---@field scriptCount integer How many script files are in the sync index.
---@field assetFileCount integer How many asset files are in the sync index.
---@field loadedLevel string The level name the sync index was built for.
---@field persistentMode string The effective mode synced to clients: server persistent mode, or client config.yml defaultGameMode.
---@field port integer? The bound TCP port, or nil before the server binds.

---A custom human model definition for src.registerHumanModel.
---CMC names are resolved from the synced assets; "data/model/" prefixes and
---".cmc" suffixes are stripped.
---@class SrcHumanModelDef
---@field male string The CMC model name used for male characters.
---@field female string The CMC model name used for female characters.

---A seat position for vehicleTypes.new/clone. A native Vector also works.
---Missing or nonnumeric components become zero.
---@class SrcSeatPosition
---@field x? number
---@field y? number
---@field z? number

---Dense one-based array: entry i controls stock parent ItemType index i - 1 (0-45).
---Use false entries to reach a later index; sparse arrays have undefined Lua length.
---Only true or numeric 1 allows mounting; false or 0 denies it. Entries after 46 are ignored.
---Name-keyed maps and zero-based index maps are not supported by the implementation.
---@alias SrcItemMountPermissions (boolean|0|1)[]

---Vector-like field overrides used by itemTypes.clone. Omitted components stay unchanged.
---The clone helper recognizes tables, not native Vector userdata, for vector overrides.
---@class SrcItemVectorOverride
---@field x? number
---@field y? number
---@field z? number

---Field overrides for published itemTypes.clone. Scalar writes that native fields reject
---are ignored. Vector overrides must be tables; native Vector userdata is ignored.
---@class SrcItemTypeOverrides
---@field name string?
---@field price integer?
---@field mass number?
---@field boundsCenter SrcItemVectorOverride? Collision half-extents, not a center position.
---@field fireRate integer?
---@field magazineAmmo integer?
---@field bulletType integer?
---@field bulletVelocity number?
---@field bulletSpread number?
---@field numHands integer?
---@field isOneHanded boolean?
---@field primaryGripRotAxis SrcItemVectorOverride?
---@field primaryGripRotation number? Native grip angle in radians.
---@field secondaryGripRotAxis SrcItemVectorOverride?
---@field secondaryGripRotation number? Native grip angle in radians.
---@field isGun boolean?
---@field canMountTo SrcItemMountPermissions? Entry 1 controls stock index 0, entry 46 controls stock index 45. Name keys and key 0 are ignored; keys 1-46 are array positions.

---All components are required when supplying new-item collision bounds.
---@alias SrcItemBounds { x: number, y: number, z: number }

---LOCAL-ONLY fields for itemTypes.new; absent from the published baseline.
---Unlike clone, new reports invalid writes and accepts native Vector userdata.
---Mass, nonzero bounds and derived inertia must fit 2^-149..(2-2^-23)*2^127 before allocation.
---@class SrcNewItemTypeFields: SrcItemTypeOverrides
---@field name nil Pass the name as the first function argument; fields.name is rejected.
---@field mass number? Finite and positive, default 0.1. Bounds determine native inertia independently of mass.
---@field numHands integer? Integer in 0..2, default 1.
---@field isOneHanded boolean? Defaults to true; initializes the native hand flag.
---@field boundsCenter Vector|SrcItemBounds? Finite nonnegative collision half-extents with all x/y/z components. Defaults to phone bounds; any zero extent selects native unit inertia. IT3/ITM loading does not derive bounds or recalculate inertia.
---@field primaryGripRotAxis Vector|SrcItemVectorOverride? Native Vector or vector-like table.
---@field secondaryGripRotAxis Vector|SrcItemVectorOverride? Native Vector or vector-like table.

---Definition overrides for vehicleTypes.clone.
---@class SrcVehicleTypeOverrides
---@field index integer? The custom slot to clone into (17-127).
---@field name string?
---@field controllableState integer? 0 = cannot be controlled, 1 = car, 2 = helicopter.
---@field usesExternalModel boolean|integer?
---@field price integer?
---@field mass number?
---@field acceleration number?
---@field model string? Bare SBV name without directory or extension; requires data/<name>.sbv in the server working directory.
---@field numSeats integer? The number of seats, 0-8.
---@field seatPos (Vector|SrcSeatPosition)[]? One position per seat; native Vectors and tables are accepted.
---@field audio string? The engine audio reference name.
---@field wheelRadius number?
---@field wheelMass number?
