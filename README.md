# Sub Rosa: Custom RS Integration

`rs_integration` is the server-side integration layer for SRC on RosaServer.

If you want client-side modding support or SRC-enabled clients at all, this repository is required. It plugs into RosaServer, exposes the SRC networking/runtime helpers on the server, and delivers scripts/assets/client metadata to connected SRC clients.

## What It Does

`rs_integration` is responsible for:

- exposing the SRC server runtime inside RosaServer
- accepting and managing SRC TCP client connections
- sending script indexes and file chunks
- syncing client assets from `clientRoot`
- bridging client/server custom events
- syncing custom item types and related metadata
- refreshing synced client content during development

This repository is the server half of SRC. It is not the native client mod, and it is not the standard client Lua implementation.

## Why It Matters

There is no serious SRC deployment without `rs_integration`.

It is the piece that enables:

- client-side scripting delivered from the server
- synced client assets
- SRC handshake/state management
- server-driven custom item/client metadata sync

Without it, RosaServer does not know how to talk to the SRC client mod.

## Project Layout

- `main/src/init.lua` installs the SRC runtime into the server
- `main/src/network.lua` owns the protocol and connection lifecycle
- `main/src/shared.lua` owns config, paths, and shared state
- `main/src/itemTypes.lua` owns custom item type sync helpers
- `main/src/watcher.lua` owns the watcher helper used by SRC utility plugins
- `plugins/srcutils.lua` owns `/srcrefresh` and optional auto-refresh behavior
- `plugins/srccShowcase.lua` is an example server plugin

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

- [`client`](https://github.com/SubRosaCustom/client): the native SRC client mod
- [`core`](https://github.com/SubRosaCustom/core): optional standard client-side Lua implementation typically synced through this repo
- [`RosaServer`](https://github.com/jpxs-intl/RosaServer): upstream dedicated server
- [`RosaServerCore`](https://github.com/jpxs-intl/RosaServerCore): upstream standard server Lua framework
