# Resource pack policy (introduced in SRC protocol 9)

Current protocol 10 retains this policy schema and adds replaceable latest-state UDP events; see [reliable UDP](reliable_udp.md). Upgrade client and integration together.

Local packs replace existing client resource slots. The server does not register or request pack-only resources. Policy is configured under the existing `src` configuration:

```yaml
src:
  disallowedPaths:
    - data/model/ak47.cmo
    - data/model/gun_tex.png
    - data/beamer2.sbv
```

Paths use exact game-root-relative spelling and `/`. This is an exact path list, not a glob or directory prefix. Blocking a model does not implicitly block its texture; list both when both must remain normal. An empty list permits supported local replacements. Validation rejects absolute/traversal paths, backslashes, colons, controls, nonportable trailing spaces/dots, sparse tables and more than 4096 input entries. Duplicates are removed and paths sorted. Each resolved configuration has its own list.

The integration sends the entire `disallowedPaths` snapshot in `HELLO_ACK`, `INDEX_RES` and `REFRESH_NOTICE`, including `[]`. The existing RosaServerCore JSON encoder represents an empty table as an array. The initial handshake is required because a reconnect may resume an unchanged runtime without requesting an index. Existing configuration reload/refresh flows transmit changes; changing a configuration file without reloading it does not update clients.

A blocked file restores the current normal source. A matching synced server asset wins over a local ZIP. Explicit server assignments retain ownership of their native destination even if their filename differs from the original stock path. Failed winning pack files restore normal loading rather than revealing a lower-priority pack. Other resource paths continue. Transport reconnection retains policy; actual client session departure clears it.

Protocol 9 requires these fields and rejects invalid/missing client-side policy snapshots. Its message names retain the protocol 8 contract; current protocol 10 supports reliable-UDP batching and latest-state events. **Deploy client and integration together.** Version 8 peers fail the existing protocol version check. Rollback must also pair both modules. No core or launcher API change is needed.

This policy governs the SRC implementation on participating clients. It is not remote attestation of a player's installation or protection against an independently modified client.

Server validation:

```sh
lua test/tests/resource_packs.lua
lua test/reliable_udp_test.lua
lua test/udp_adapter_test.lua
lua test/tests/worker_bundle.lua
lua test/tests/type_snapshot.lua
luac -p main/src/config.lua main/src/network.lua main/src/protocol.lua .meta/template/types.lua
```

These host checks pass for this delivery. They do not establish live direct-UDP, Steam P2P, game rendering or Windows/MSVC behavior. The client repository's `docs/resource_packs/README.md` contains the full import inventory, replacement implementation, supported scope, constraints and native acceptance checks.
