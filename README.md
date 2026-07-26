# Sub Rosa: Custom RosaServer Integration

`rs_integration` is the server-side integration layer for SRC on RosaServer.

It expects the native SRC server helper libraries to be present separately:
- `require("librosaserver_src_integration")` for item type overrides
- `require("libminiz")` for in-memory ZIP archive creation/extraction used by sync bundling

## TL;DR
If you want SRC clients to actually work on a RosaServer deployment, this module is required.
It owns the server-side transport, sync pipeline, and runtime coordination for SRC.

## What It Does

`rs_integration` is responsible for:

- exposing the SRC server runtime inside RosaServer
- accepting and managing SRC TCP client connections
- sending script indexes and file chunks
- syncing client assets from `clientRoot` (default `subrosacustom`)
- bridging client/server custom events
- syncing custom item types and related metadata
- refreshing synced client content during development

This repository is the server half of SRC. It is not the native client mod, and it is not the standard client Lua implementation (that is [Sub Rosa: Custom Core](https://github.com/SubRosaCustom/core)).

## Runtime Notes

- SRC uses TCP for control/sync and sends standalone batched event datagrams
  through the game's existing UDP socket and port.
- Server-owned reliable event IDs are allocated in the unsigned range `0x80000000` to `0xFFFFFFFF` to avoid client/server ID collisions.
- `plugins/srcutils.lua` exposes `/srcwatch`, `/srcdisableplugin`, `/srcenableplugin`, and supports `srcwatch` as an alias.
- Internal Lua helpers in this repo are now normalized to `snake_case`; API-facing names are preserved for compatibility with existing configs/plugins.
- The native helper libraries now load as two separate Lua modules: `librosaserver_src_integration` and `libminiz`.

## Project Layout

- `main/src/init.lua` installs the SRC runtime into the server
- `main/src/network.lua` owns the protocol and connection lifecycle
- `main/src/shared.lua` owns config, paths, and shared state
- `main/src/itemTypes.lua` owns custom item type sync helpers
- `main/src/watcher.lua` owns the watcher helper used by SRC utility plugins
- `plugins/srcutils.lua` owns `/srcrefresh`, `/srcstatus`, `/srcclients`, `/srcwatch`, `/srcdisableplugin`, `/srcenableplugin`, `/srcdumpstate`, and `/srckicknonsrc`
- `plugins/srccShowcase.lua` is an example server plugin

## Testing

Run `cd test && ./test`. The suite boots the real RosaServer runtime and pulls
the pinned `rs_utils` release declared in `test/test`.

## Configuration

This module is configured through `config.src` in the server's Lua config.

Common settings include:

- `enabled`
- `clientRoot`
- `disallowNonSRCPlayers`
- file transfer limits
- queue limits
- auto-refresh settings
- event retry/timeout settings

`clientRoot` is the server-side directory tree that gets indexed and synced to SRC clients.

Current layout under `clientRoot`:

- `scripts/` contains synced Lua, YAML, and JSON script/runtime files
- `assets/` contains synced client assets such as `.cmo`, `.png`, `.wav`, `.csx`, `.sbc`, and `.sbl`

Logical sync paths stay clean:

- scripts are indexed relative to `scripts/`, so the client still sees paths like `main/init.lua`
- assets are indexed relative to `assets/`, so the client still sees paths like `data/model/foo.cmo` or `texture/icon-foo.png`

## Runtime Role

At runtime, `rs_integration` sits in the RosaServer process and delivers the client-side runtime to SRC players.

That typically means:

- `client` is installed on the player's machine
- `rs_integration` runs on the server
- `core` and other synced client scripts live under `clientRoot/scripts`
- synced client assets live under `clientRoot/assets`
- the server syncs those files to the client during join/resync

## Related Repositories

- [`client`](https://github.com/SubRosaCustom/client): Sub Rosa: Custom client mod, as of writing this not public to avoid development of cheats
- [`core`](https://github.com/SubRosaCustom/core): optional (recommended) standard client-side Lua runtime usually synced through this repo
- [`RosaServer`](https://github.com/jpxs-intl/RosaServer)
- [`RosaServerCore`](https://github.com/jpxs-intl/RosaServerCore)
