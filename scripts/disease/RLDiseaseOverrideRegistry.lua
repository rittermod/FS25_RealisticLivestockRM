-- RLDiseaseOverrideRegistry.lua
-- Sparse per-title override map for which diseases may produce new cases. A title with no
-- override is enabled; production stores only `false` (switching back on is `clear`).
--
-- Contract:
--   RLDiseaseOverrideRegistry.new() -> instance
--   reg:set(title, enabled) -> ok:boolean          -- upsert; false on any reject
--   reg:clear(title) -> removed:boolean            -- true if removed, false if none/invalid
--   reg:get(title) -> enabled:boolean|nil          -- override value, or nil when unset/invalid
--   reg:isEnabled(title) -> boolean                -- override when present, else true
--   reg:enumerate() -> array<{title=, enabled=}>   -- sorted by title, clone-isolated
--   reg.revision                                   -- integer, moves on a NET change only
--
-- A title is any non-empty string, stored verbatim with no registry-membership check, so an
-- override for a title the definitions no longer carry is kept.

local Log = RmLogging.getLogger("RLRM")

RLDiseaseOverrideRegistry = {}
local RLDiseaseOverrideRegistry_mt = { __index = RLDiseaseOverrideRegistry }

--- True when `title` is a non-empty string.
---@param title any
---@return boolean
local function isValidTitle(title)
    local valid = type(title) == "string" and title ~= ""
    Log:trace("RLDiseaseOverrideRegistry.isValidTitle: %s -> %s", tostring(title), tostring(valid))
    return valid
end

--- Shared title validation for set/get/clear: the title, or nil after a warning.
---@param title any
---@param context string names the calling accessor for the log line
---@return string|nil title
local function validatedTitle(title, context)
    if not isValidTitle(title) then
        Log:warning("RLDiseaseOverrideRegistry:%s: invalid title=%s (need non-empty string); rejecting",
            context, tostring(title))
        return nil
    end
    return title
end

-- =============================================================================
-- Construction
-- =============================================================================

--- Construct a new, empty registry. A per-savegame reset is a reconstruction, never a clear-all.
---@return table instance
function RLDiseaseOverrideRegistry.new()
    local self = setmetatable({}, RLDiseaseOverrideRegistry_mt)
    self.overrides = {}
    self.revision = 0
    Log:debug("RLDiseaseOverrideRegistry.new: fresh instance")
    return self
end

-- =============================================================================
-- Accessors
-- =============================================================================

--- Upsert an override; `revision` moves only when the stored value changed or was created.
---@param title string disease title
---@param enabled boolean override value
---@return boolean ok false on an invalid title or a non-boolean value
function RLDiseaseOverrideRegistry:set(title, enabled)
    local key = validatedTitle(title, "set")
    if key == nil then return false end

    if type(enabled) ~= "boolean" then
        Log:warning("RLDiseaseOverrideRegistry:set: invalid enabled=%s for %s (need boolean); rejecting",
            tostring(enabled), key)
        return false
    end

    local previous = self.overrides[key]
    self.overrides[key] = enabled

    if previous ~= enabled then
        self.revision = self.revision + 1
        Log:debug("RLDiseaseOverrideRegistry:set: %s -> enabled=%s (revision %d)", key, tostring(enabled), self.revision)
    else
        Log:trace("RLDiseaseOverrideRegistry:set: %s already enabled=%s; no change", key, tostring(enabled))
    end

    return true
end

--- Remove one override, restoring the default.
---@param title string disease title
---@return boolean removed false when the title was absent or invalid
function RLDiseaseOverrideRegistry:clear(title)
    local key = validatedTitle(title, "clear")
    if key == nil then return false end

    if self.overrides[key] == nil then
        Log:trace("RLDiseaseOverrideRegistry:clear: %s not present; no-op", key)
        return false
    end

    self.overrides[key] = nil
    self.revision = self.revision + 1
    Log:debug("RLDiseaseOverrideRegistry:clear: %s removed (revision %d)", key, self.revision)
    return true
end

--- The override value for a title, returned VERBATIM: a stored `false` comes back as `false`.
---@param title string disease title
---@return boolean|nil enabled nil when unset or invalid
function RLDiseaseOverrideRegistry:get(title)
    local key = validatedTitle(title, "get")
    if key == nil then return nil end

    local value = self.overrides[key]
    Log:trace("RLDiseaseOverrideRegistry:get: %s -> %s", key, tostring(value))
    return value
end

--- Hot path: validates and logs nothing, so an invalid title reads as enabled.
---@param title any disease title
---@return boolean enabled
function RLDiseaseOverrideRegistry:isEnabled(title)
    -- Tested by presence: `value or true` would turn a stored false back on.
    local value = self.overrides[title]
    if value ~= nil then
        return value
    end
    return true
end

--- Every override as a shallow-cloned `{ title, enabled }` record, sorted by title.
---@return table[] records
function RLDiseaseOverrideRegistry:enumerate()
    local out = {}
    for title, enabled in pairs(self.overrides) do
        out[#out + 1] = { title = title, enabled = enabled }
    end

    table.sort(out, function(a, b) return a.title < b.title end)

    Log:trace("RLDiseaseOverrideRegistry:enumerate: #=%d", #out)
    return out
end

Log:debug("RLDiseaseOverrideRegistry: loaded")
