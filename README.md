# Sub Rosa: Custom RS Integration

The RosaServer-side bridge for Sub Rosa: Custom.

This repository plugs into a `RosaServer` / `RosaServerCore` server and handles:

- SRC TCP handshake
- script index delivery
- file and asset sync
- client/server event transport
- custom item type replication
- custom item model/icon/fire-sound replication

In practical terms, this is the server half of the SRCC sync protocol.

Requires:

- [RosaServer](https://github.com/jpxs-intl/RosaServer)
- typically [RosaServerCore](https://github.com/jpxs-intl/RosaServerCore)
- [Sub Rosa: Custom Client](https://github.com/SubRosaCustom/client) on the connecting clients

# Getting Started

## Layout

- `main/src/init.lua` is the entrypoint
- `main/src/network.lua` owns the TCP protocol and frame handling
- `main/src/shared.lua` owns config/state/discovery helpers
- `main/src/watcher.lua` owns auto-refresh file watching
- `main/src/itemTypes.lua` owns custom item type sync helpers
- `plugins/srccShowcase.lua` is the local example plugin

## Configuration

This module reads from `config.src` inside the main RosaServer Lua config.

Current config fields include:

- `enabled`
- `disallowNonSRCPlayers`
- `clientRoot`
- `readSize`
- `fileChunkSize`
- `maxReadBytesPerTick`
- `maxSendBytesPerTick`
- `maxFileChunksPerTick`
- `maxQueuedSendFrames`
- `autoRefreshEnabled`
- `autoRefreshDebounceTicks`
- `eventRetryBaseTicks`
- `eventRetryMaxAttempts`
- `maxEventBytes`
- `eventProcessTimeoutTicks`
- `eventDebugLogSuccess`

If `enabled = false`, the runtime shuts itself down cleanly.

## What Gets Synced

From `clientRoot`:

- Lua scripts
- custom assets under safe paths
- custom item type blobs
- custom item models
- custom item icons
- custom item fire sound assignments

Safe asset roots are intentionally constrained. Right now the integration is built for SRCC’s expected paths such as:

- `data/...`
- `texture/...`
- `sound/...`

# API Surface

The module installs helpers onto global `src`.

Notable functions:

- `src.refresh()`
- `src.onClientEvent(name, fn)`
- `src.emitClientEvent(player, name, data, bin)`
- `src.syncClientItemTypes(player, payload)`
- `src.setItemTypeModel(indexOrItemType, modelName, player?)`
- `src.setItemTypeIcon(indexOrItemType, iconPath, player?)`
- `src.setItemTypeFireSounds(indexOrItemType, soundPaths, player?)`
- `src.getClientState(player)`
- `src.listScripts()`

Custom item helpers are installed out of `main/src/itemTypes.lua`.

# Operational Notes

## Refreshing

The integration supports manual refresh through:

- `src.refresh()`
- `/srcrefresh`

It also supports optional auto-refresh through the watcher.

## Join Gating

This repo only provides the server side. Initial join blocking, sync overlays, and client resume behavior are owned by `client/`.

## Binary Transport

Heavy server-to-client sync payloads are already moved off JSON where it materially helps. That includes raw file chunks and custom item type blobs. Control traffic is still JSON on purpose.

# Scope

This repo is not RosaServerCore and it is not the SRCC client.

- It does not own native hooks.
- It does not own the client Lua runtime.
- It does not replace RosaServer gameplay logic.

It exists to connect RosaServer to SRCC clients without bolting sync logic all over your actual gamemode code.
