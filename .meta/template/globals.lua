--# selene: allow(unused_variable)
--# selene: allow(unscoped_variables)
---@meta

-- Globals added to the RosaServer Lua runtime by rs_integration.
-- These sit on top of the base RosaServer API (see the RosaServerCore .meta).

---The SRC server runtime; only one instance in the global variable `src`.
---Installed by main/src/init.lua when the module is loaded.
---@class SrcGlobal
---@field enabled boolean Whether the SRC runtime is enabled (config.src.enabled).
src = {}

---Queue a sync refresh for all connected SRC clients using the current
---file index.
function src.refresh() end

---Re-discover the synced script/asset file index from clientRoot, then
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
---Arguments may be nil, boolean, number, string or src.blob() values.
---@param player Player|nil The target player, or nil to broadcast to all SRC clients.
---@param name string The event name.
---@param ... SrcEventValue The event arguments.
---@return integer|boolean sent The number of clients queued when broadcasting, or whether the event was queued for a single player.
function src.emitClientEvent(player, name, ...) end

---Reload a synced client plugin on all connected SRC clients.
---@param plugin_name string The plugin file name.
function src.reloadClientPlugin(plugin_name) end

---Send a custom item type sync payload to clients.
---Prefer src.syncCustomItemTypes, which builds the payload for you.
---@param player Player|nil The target player, or nil to broadcast.
---@param payload table The sync payload, as built by the runtime.
---@return integer|boolean sent The number of clients queued when broadcasting, or whether the frame was queued for a single player.
function src.syncClientItemTypes(player, payload) end

---Send a custom vehicle type sync payload to clients.
---Prefer src.syncCustomVehicleTypes, which builds the payload for you.
---@param player Player|nil The target player, or nil to broadcast.
---@param payload table The sync payload, as built by the runtime.
---@return integer|boolean sent The number of clients queued when broadcasting, or whether the frame was queued for a single player.
function src.syncClientVehicleTypes(player, payload) end

---Build and send the current custom item type set to clients.
---@param player? Player The target player, or nil to broadcast.
---@return integer|boolean sent False if there are no custom item types.
function src.syncCustomItemTypes(player) end

---Assign a client-side CMO model to an item type and sync it.
---@param indexOrType integer|ItemType The item type to assign to (0-254).
---@param modelName string The CMO model name, resolved from the synced assets.
---@param player? Player The target player, or nil to broadcast.
---@return integer|boolean sent
function src.setItemTypeModel(indexOrType, modelName, player) end

---Assign a client-side inventory icon texture to an item type and sync it.
---@param indexOrType integer|ItemType The item type to assign to (0-254).
---@param iconPath string The synced asset path of the icon, ex. "texture/icon-foo.png".
---@param player? Player The target player, or nil to broadcast.
---@return integer|boolean sent
function src.setItemTypeIcon(indexOrType, iconPath, player) end

---Assign an .itm definition file to an item type, apply it server-side, and
---sync it to clients.
---@param indexOrType integer|ItemType The item type to assign to (0-254).
---@param itmPath string A forward-slash path ending in .itm, resolved against clientRoot.
---@param player? Player The target player, or nil to broadcast.
---@return integer|boolean sent
function src.setItemTypeITM(indexOrType, itmPath, player) end

---Assign an .it3 definition file to an item type, apply it server-side, and
---sync it to clients.
---@param indexOrType integer|ItemType The item type to assign to (0-254).
---@param it3Path string A forward-slash path ending in .it3, resolved against clientRoot.
---@param player? Player The target player, or nil to broadcast.
---@return integer|boolean sent
function src.setItemTypeIT3(indexOrType, it3Path, player) end

---Assign a client-side texture to an item type's model and sync it.
---@param indexOrType integer|ItemType The item type to assign to (0-254).
---@param textureRef string A builtin texture name (gun_tex, grenade, soccerball, watermelon, tex_2) or a synced texture file path.
---@param player? Player The target player, or nil to broadcast.
---@return integer|boolean sent
function src.setItemTypeTexture(indexOrType, textureRef, player) end

---Assign custom gunshot sounds to an item type and sync them.
---@param indexOrType integer|ItemType The item type to assign to (0-254).
---@param soundPaths string|string[] A builtin sound name, one synced .wav path, or up to 6 synced .wav paths.
---@param player? Player The target player, or nil to broadcast.
---@return integer|boolean sent
function src.setItemTypeFireSounds(indexOrType, soundPaths, player) end

---Build and send the current custom vehicle type set to clients.
---@param player? Player The target player, or nil to broadcast.
---@return integer|boolean sent False if there are no custom vehicle types.
function src.syncCustomVehicleTypes(player) end

---Assign a client-side model to a vehicle type and sync it.
---@param indexOrType integer|VehicleType The vehicle type to assign to (0-127).
---@param modelName string The model name, resolved from the synced assets.
---@param player? Player The target player, or nil to broadcast.
---@return integer|boolean sent
function src.setVehicleTypeModel(indexOrType, modelName, player) end

---Assign client-side engine audio to a vehicle type and sync it.
---@param indexOrType integer|VehicleType The vehicle type to assign to (0-127).
---@param audioRef string The audio reference name.
---@param player? Player The target player, or nil to broadcast.
---@return integer|boolean sent
function src.setVehicleTypeAudio(indexOrType, audioRef, player) end

---Register a custom human model (CMC pair) at a model index and sync it to
---all SRC clients.
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
---@param model string The client-side model name, resolved from the synced assets.
---@param numSeats integer The number of seats, 0-8.
---@param seatPos SrcSeatPosition[] One position per seat.
---@param audio string The engine audio reference name.
---@param wheelRadius? number The wheel radius. Defaults to the runtime default.
---@param wheelMass? number The wheel mass. Defaults to the runtime default.
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
