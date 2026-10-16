# Scoped client assets

The asset manifest is sourced only from:

- `clientRoot/assets/modes/<activeMode>/**`
- `clientRoot/assets/plugins/<enabledClientPlugin>/**`

A client plugin exists when `clientRoot/scripts/plugins/<name>.lua` or
`clientRoot/scripts/plugins/<name>/init.lua` exists. Plugins are enabled by default,
minus the names in `clientRoot/scripts/disabledPlugins.json`. Server-side plugins
and per-plugin configuration settings do not select client assets. Owner names
use ASCII letters, digits, `_` and `-` only. The active mode may have a `.lua`
suffix, which is removed before owner selection.

The source ownership prefix is stripped. For example,
`assets/plugins/vehicles/data/model/buggy.cmo` is advertised and cached as
`data/model/buggy.cmo`; scripts continue using that logical path. Move existing
loose assets under their mode/plugin ownership folder before deploying this
change. There is deliberately no fallback to scanning all of `assets/`.
Missing or empty selected roots contribute no files. Independent `data/*.sbv`
and the selected map's `data/<level>/` sources remain in place. Script syncing
is unchanged.

Owners and files are enumerated deterministically. Identical logical-path
collisions are deduplicated; different contents at the same path (or differently-cased aliases) reject the
refresh, retaining the previous complete snapshot. Malformed disable lists also
reject the update. Owner paths cannot escape their roots through symlinks.
Canonical containment uses LuaJIT's FFI and libc `realpath` on RosaServer/Linux.

Enable/disable commands refresh immediately. Entry-point/disable-list membership
is checked every 60 server ticks even when optional content watching is disabled.
With `autoRefreshEnabled`, JSON and supported asset changes now trigger refresh,
as do script changes. `src.refreshSyncFiles()` remains the explicit full refresh. A targeted plugin reload
is promoted to a full replay if asset contents or scope membership changed.

Deploy the client, core, and integration changes together. Protocol 9 is unchanged;
new manifests remain valid protocol-9 subsets, but the updated client is needed
for interrupted-transfer cleanup and resource-ownership reconciliation.

Host regression test:

```sh
lua test/scoped_assets_test.lua
```

The fixture filesystem models canonical paths and symlinks; it does not replace
a live LuaJIT/RosaServer test. Native acceptance should cover switching modes and
disabling/re-enabling plugins while joining and mid-bundle, then verify removed
files are pruned and locally permitted resource packs regain removed ownership.
