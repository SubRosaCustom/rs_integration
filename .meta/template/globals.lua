--# selene: allow(unused_variable)
--# selene: allow(unscoped_variables)
---@meta

-- Metadata follows this local checkout. Published baseline checked on 2026-10-25:
-- 3053f88a4dcb31625c018ea6e143e3b4ac241ffe (control protocol 9). LOCAL-ONLY notes identify
-- additions or behavior absent from that baseline; they are not release guarantees.

-- Globals added to the RosaServer Lua runtime by rs_integration.
-- These sit on top of the base RosaServer API (see the RosaServerCore .meta).

---The SRC server runtime; only one instance in the global variable `src`.
---Installed by main/src/init.lua when the module is loaded.
---@class SrcGlobal
---@field enabled boolean Whether the SRC runtime is enabled (config.src.enabled).
src = {}

---Queue a sync refresh for all connected SRC clients using the current
---file index. This does not rescan changed files.
function src.refresh() end

---Re-discover scripts and selected mode/plugin assets under clientRoot, then
---queue a sync refresh for all connected SRC clients.
function src.refreshSyncFiles() end

---Register a handler for a client-to-server SRC event.
---The handler receives the client's SRC TCP connection followed by the
---decoded event arguments. Use src.getClientPlayer(connection) to resolve
---the sending player.
---@param name string The event name.
---@param fn fun(connection: TCPServerConnection, ...: SrcEventValue) The handler function.
---@return boolean registered False if the name collides with a different registered event.
function src.onClientEvent(name, fn) end

---Emit a server-to-client SRC event.
---The server maxEventBytes setting may lower the 256 KiB limit.
---Ordinary reliable events exist in the published baseline; delivery is unordered.
---LOCAL-ONLY transport policy below describes protocol 10, not published protocol 9.
---Each native send flushes queued fragments and receipts in up to eight size-bounded datagrams
---per peer (at most 9,600 bytes); congestion limits may stop the flush sooner.
---No extra transport pacing timer is imposed; congestion windows and retry deadlines still apply.
---The complete encoded argument block is limited to 256 KiB, including serialization overhead.
---Queue acceptance does not guarantee remote processing.
---Disconnects discard pending events; they are not replayed into a new session.
---Arguments may be nil, boolean, number, string or src.blob() values.
---@param player Player|nil The target player, or nil to broadcast to all SRC clients.
---@param name string The event name.
---@param ... SrcEventValue The event arguments.
---@return integer|boolean sent The number of clients queued when broadcasting, or whether the event was queued for a single player.
function src.emitClientEvent(player, name, ...) end

---LOCAL-ONLY API: absent from the published protocol-9 baseline.
---Send replaceable latest state over UDP (protocol 10); requires matching client/integration.
---Newer unsent values replace older values for the same event name and peer.
---No receipts, processing results or retries; packet loss can drop the final update.
---Older sequence IDs are discarded. At most 32 distinct names per session.
---Encoded arguments are limited to 485 bytes; the server may impose a lower limit.
---Handled with onServerEvent. Keep permissions and lifecycle actions reliable.
---@param player Player|nil Target player, or nil for all SRC clients.
---@param name string
---@param ... SrcEventValue
---@return integer|boolean queued Count for broadcast, boolean for a single player.
function src.emitClientEventLatest(player, name, ...) end

---Request a synced client plugin reload on all connected SRC clients.
---Asset contents, selected owners, effective mode or level changes promote it to a full replay.
---@param plugin_name string The plugin file name.
function src.reloadClientPlugin(plugin_name) end

---Send a custom item type sync payload to clients.
---Prefer src.syncCustomItemTypes, which builds the payload for you.
---The payload replaces the complete custom item type list; an empty list clears it.
---@param player Player|nil The target player, or nil to broadcast.
---@param payload table The sync payload, as built by the runtime.
---@return integer|boolean sent The number of clients queued when broadcasting, or whether the frame was queued for a single player.
function src.syncClientItemTypes(player, payload) end

---Send a custom vehicle type sync payload to clients.
---Prefer src.syncCustomVehicleTypes, which builds the payload for you.
---The payload replaces the complete custom vehicle type list; an empty list clears it.
---@param player Player|nil The target player, or nil to broadcast.
---@param payload table The sync payload, as built by the runtime.
---@return integer|boolean sent The number of clients queued when broadcasting, or whether the frame was queued for a single player.
function src.syncClientVehicleTypes(player, payload) end

---Build and send the current custom item type set to clients.
---@param player? Player The target player, or nil to broadcast.
---@return integer|boolean sent Empty type sets are also sent to clear previous definitions.
---LOCAL-ONLY behavior: definitions with file assignments outside the active asset manifest
---are omitted until those assets return; the published baseline does not apply this filter.
function src.syncCustomItemTypes(player) end

---Assign a client-side CMO model to an item type and sync it.
---Replaces any previous CMO, ITM, or IT3 model assignment for this type.
---Synced paths must match the current manifest exactly.
---@param indexOrType integer|ItemType The item type to assign to (0-254).
---@param modelName string The CMO model name, resolved from the synced assets.
---@param player? Player Limits the immediate send only. Shared assignment state changes for future syncs; nil broadcasts.
---@return integer|boolean sent
function src.setItemTypeModel(indexOrType, modelName, player) end

---Assign a client-side inventory icon texture to an item type and sync it.
---@param indexOrType integer|ItemType The item type to assign to (0-254).
---@param iconPath string The synced asset path of the icon, ex. "texture/icon-foo.png".
---@param player? Player Limits the immediate send only. Shared assignment state changes for future syncs; nil broadcasts.
---@return integer|boolean sent
function src.setItemTypeIcon(indexOrType, iconPath, player) end

---Assign an .itm definition file to an item type, apply it server-side, and
---sync it to clients. ITM supplies render geometry/markers; it does not create
---the stock startup box collision mesh for a fresh item type.
---Replaces any previous CMO, ITM, or IT3 model assignment for this type.
---Synced paths must match the current manifest exactly.
---@param indexOrType integer|ItemType The item type to assign to (0-254).
---LOCAL-ONLY behavior: matching logical manifest paths resolve to their owning server file.
---Published fallback lookup tries the supplied path, assets root + path, then clientRoot + path.
---Both versions transmit the supplied logical path unchanged; avoid sending ownership prefixes.
---@param itmPath string A logical synced asset path ending in .itm.
---@param player? Player Limits the immediate send only. Shared assignment state changes for future syncs; nil broadcasts.
---@return integer|boolean sent
function src.setItemTypeITM(indexOrType, itmPath, player) end

---Assign an .it3 definition file to an item type, apply it server-side, and
---sync it to clients.
---Replaces any previous CMO, ITM, or IT3 model assignment for this type.
---Synced paths must match the current manifest exactly.
---@param indexOrType integer|ItemType The item type to assign to (0-254).
---LOCAL-ONLY behavior: matching logical manifest paths resolve to their owning server file.
---Published fallback lookup tries the supplied path, assets root + path, then clientRoot + path.
---Both versions transmit the supplied logical path unchanged; avoid sending ownership prefixes.
---@param it3Path string A logical synced asset path ending in .it3.
---@param player? Player Limits the immediate send only. Shared assignment state changes for future syncs; nil broadcasts.
---@return integer|boolean sent
function src.setItemTypeIT3(indexOrType, it3Path, player) end

---Assign a client-side texture to an item type's model and sync it.
---File paths resolve within the current manifest; bare filenames must be unique.
---Builtin textures are available without first rendering a vanilla item.
---@param indexOrType integer|ItemType The item type to assign to (0-254).
---@param textureRef string A builtin texture name (gun_tex, grenade, soccerball, watermelon, tex_2) or a synced texture file path.
---@param player? Player Limits the immediate send only. Shared assignment state changes for future syncs; nil broadcasts.
---@return integer|boolean sent
function src.setItemTypeTexture(indexOrType, textureRef, player) end

---Assign custom gunshot sounds to an item type and sync them.
---@param indexOrType integer|ItemType The item type to assign to (0-254).
---@param soundPaths string|string[] A builtin sound name, one synced .wav path, or up to 6 synced .wav paths.
---@param player? Player Limits the immediate send only. Shared assignment state changes for future syncs; nil broadcasts.
---@return integer|boolean sent
function src.setItemTypeFireSounds(indexOrType, soundPaths, player) end

---Build and send the current custom vehicle type set to clients.
---@param player? Player The target player, or nil to broadcast.
---@return integer|boolean sent Empty type sets are also sent to clear previous definitions.
function src.syncCustomVehicleTypes(player) end

---Assign a client-side model to a vehicle type and sync it.
---@param indexOrType integer|VehicleType The vehicle type to assign to (0-127).
---@param modelName string Bare SBV name, without path or extension. Requires server file data/<name>.sbv.
---@param player? Player Limits the immediate send only. Shared assignment state changes for future syncs; nil broadcasts.
---@return integer|boolean sent
function src.setVehicleTypeModel(indexOrType, modelName, player) end

---Assign client-side engine audio to a vehicle type and sync it.
---@param indexOrType integer|VehicleType The vehicle type to assign to (0-127).
---@param audioRef string The audio reference name.
---@param player? Player Limits the immediate send only. Shared assignment state changes for future syncs; nil broadcasts.
---@return integer|boolean sent
function src.setVehicleTypeAudio(indexOrType, audioRef, player) end

---Register a custom human model (CMC pair) at a model index and sync it to
---all SRC clients. Clients hold at most 6 custom human models at once; slots are
---handed out in ascending index order, so models beyond the 6th lowest index do not load.
---@param index integer The custom model index, between 0 and 29.
---@param def SrcHumanModelDef The male/female CMC names, ex. { male = "model_m", female = "model_f" }.
---@return integer index The normalized model index.
function src.registerHumanModel(index, def) end

---Register a custom necktie model (CMC pair) at an accessory index and sync
---it to all SRC clients.
---@param index integer The custom necktie index, between 11 and 15.
---@param def SrcHumanModelDef The male/female CMC names.
---@return integer index The normalized accessory index.
function src.registerHumanNecktie(index, def) end

---Register a custom necklace model (CMC pair) at an accessory index and sync
---it to all SRC clients.
---@param index integer The custom necklace index, between 3 and 15.
---@param def SrcHumanModelDef The male/female CMC names.
---@return integer index The normalized accessory index.
function src.registerHumanNecklace(index, def) end

---Delete a world block on the server and sync the deletion to SRC clients.
---Sync starts at PostResetGame and is suspended during ResetGame/map loading.
---@param x integer The block X coordinate.
---@param y integer The block Y coordinate.
---@param z integer The block Z coordinate.
---@return boolean deleted False when the block was already empty.
function src.deleteBlock(x, y, z) end

---Get the SRC connection state of a player's client.
---@param player Player The player to query.
---@return SrcClientState state The client state snapshot.
function src.getClientState(player) end

---Resolve the player bound to an SRC client connection.
---Use inside src.onClientEvent handlers.
---@param connection TCPServerConnection The SRC TCP connection.
---@return Player? player The bound player, or nil.
function src.getClientPlayer(connection) end

---Re-discover and list the synced script files under clientRoot/scripts.
---Record paths are relative to scripts/, ex. "main/init.lua".
---@return SrcSyncFileRecord[] scripts
function src.listScripts() end

---Wrap a byte string so it is sent through events as a binary payload
---instead of a plain string.
---@param bytes string The raw bytes to wrap.
---@return SrcBlob blob The wrapped binary payload.
function src.binary(bytes) end

---Alias of src.binary.
---@param bytes string The raw bytes to wrap.
---@return SrcBlob blob The wrapped binary payload.
function src.blob(bytes) end

---LOCAL-ONLY API in the current uncommitted item_types.lua; absent from published source.
---Create a fresh zero-initialized custom item type in an automatically allocated
---slot (46-254), apply fields, and sync it to SRC clients. No stock definition is cloned.
---Defaults: mass 0.1, collision enabled, numHands 1 and isOneHanded true.
---Native pocket slots 3-6 are enabled; slot 2 (gun holster) is disabled.
---Both grips use the stock phone's native handheld axis-angle calibration.
---Assign collision/render geometry with src.setItemTypeIT3 before creating fresh physical items.
---ITM loading supplies render geometry/anchors only; it does not build the stock startup box collider.
---Added to the RosaServer itemTypes library by rs_integration.
---@param name string Item name, 1-63 bytes without NUL.
---@param fields? SrcNewItemTypeFields Definition fields; mass must be finite and positive, numHands must be 0-2. Pass name separately. Hand flags use native writes and do not require userdata setters.
---@return ItemType itemType The new item type.
---boundsCenter is the nonnegative collision half-extents, not a center position; defaults to the stock phone bounds.
---Rotational inertia is derived from those bounds using native catalog setup. If any extent is zero, native unit inertia is used.
---Before allocation, mass, nonzero bounds and derived inertia must be in the native float range
---2^-149 through (2-2^-23)*2^127. Zero bounds remain allowed; zero mass/inertia are rejected.
---IT3/ITM loading does not initialize bounds or recalculate inertia; supply boundsCenter when constructing a differently sized item.
function itemTypes.new(name, fields) end

---Clone an existing item type into a custom slot (46-254), optionally
---overriding fields, and sync it to SRC clients.
---Added to the RosaServer `itemTypes` library by rs_integration.
---@param sourceRef integer|string|ItemType The source item type (index, exact name, or object).
---@param targetIndex? integer The custom slot to clone into (46-254). Auto-allocated when omitted.
---@param overrides? SrcItemTypeOverrides Field overrides applied to the clone.
---@return ItemType itemType The cloned item type.
---@overload fun(sourceRef: integer|string|ItemType, overrides: SrcItemTypeOverrides): ItemType
function itemTypes.clone(sourceRef, targetIndex, overrides) end

---Create a new custom vehicle type in a custom slot (17-127) and sync it to
---SRC clients.
---Added to the RosaServer `vehicleTypes` library by rs_integration.
---@param name string The vehicle type name.
---@param controllableState integer 0 = cannot be controlled, 1 = car, 2 = helicopter.
---@param usesExternalModel boolean|integer
---@param price integer How much money is taken when bought.
---@param mass number In kilograms, kind of.
---@param acceleration number How fast the vehicle can accelerate.
---@param model string Bare SBV name without directory or extension; requires data/<name>.sbv on the server.
---@param numSeats integer The number of seats, 0-8.
---@param seatPos (Vector|SrcSeatPosition)[] One position per seat; native Vectors and tables are accepted.
---@param audio string The engine audio reference name.
---@param wheelRadius? number Positive wheel radius. Defaults to 0.3125.
---@param wheelMass? number Positive wheel mass. Defaults to 12.
---@param index? integer The custom slot to use (17-127). Auto-allocated when omitted.
---@return VehicleType vehicleType The created vehicle type.
function vehicleTypes.new(name, controllableState, usesExternalModel, price, mass, acceleration, model, numSeats, seatPos, audio, wheelRadius, wheelMass, index) end

---Clone an existing vehicle type into a custom slot (17-127), optionally
---overriding definition fields, and sync it to SRC clients.
---Added to the RosaServer `vehicleTypes` library by rs_integration.
---@param sourceRef integer|string|VehicleType The source vehicle type (index, exact name, or object).
---@param targetIndex? integer The custom slot to clone into (17-127). Auto-allocated when omitted.
---@param overrides? SrcVehicleTypeOverrides Definition overrides applied to the clone.
---@return VehicleType vehicleType The cloned vehicle type.
---@overload fun(sourceRef: integer|string|VehicleType, overrides: SrcVehicleTypeOverrides): VehicleType
function vehicleTypes.clone(sourceRef, targetIndex, overrides) end
