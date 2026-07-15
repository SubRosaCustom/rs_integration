--# selene: allow(unused_variable)
--# selene: allow(unscoped_variables)
---@meta

-- Hooks added to the RosaServer hook system by rs_integration.
-- Base hook aliases (Logic, ConfigLoaded, ...) come from RosaServerCore.

---Called once after the SRC item type sync API is installed and config has
---loaded. Register custom item types here (itemTypes.clone,
---src.setItemTypeModel, ...) so they are included in the initial sync.
---@alias hooks.SRC_InitItemType fun(): HookReturn
