-- RLDealerSaleRegistry.lua
-- Sparse override map for dealer sale-availability, plus the effective-state resolver that
-- folds an override over a loaded baseline.
--
-- Each override records a desired `canBeBought` boolean for one animal stage, keyed by
-- (subTypeName, minAge). The toggle works both directions - an override can turn a base-locked
-- stage on OR a shipped-on stage off.
--
-- Contract:
--   RLDealerSaleRegistry.new() -> instance
--   reg:set(subTypeName, minAge, canBeBought) -> ok:boolean        -- upsert; false on any reject
--   reg:clear(subTypeName, minAge) -> removed:boolean              -- true if removed, false if none/invalid
--   reg:get(subTypeName, minAge) -> canBeBought:boolean|nil        -- override value, or nil when unset/invalid
--   reg:enumerate() -> array<{subTypeName=, minAge=, canBeBought=}> -- keyed records, sorted, clone-isolated
--   RLDealerSaleRegistry.effective(override, baseline) -> boolean|nil
--
-- `subTypeName` is a non-empty string used VERBATIM, with no case or whitespace normalization -
-- callers pass the canonical `subType.name`. `minAge` is an integer in [0, MAX_MIN_AGE]. Both
-- are validated identically on set/get/clear, so an invalid key never reaches key-encoding.
--
-- Data in / data out only: this layer stores and resolves overrides. It does NOT persist them,
-- apply them to any live store, check whether a subtype is currently loaded, or sync across the
-- network - an override for a temporarily absent subtype is stored and enumerated normally.

local Log = RmLogging.getLogger("RLRM")

RLDealerSaleRegistry = {}
local RLDealerSaleRegistry_mt = { __index = RLDealerSaleRegistry }

--- Composite key: `subTypeName .. "@" .. string.format("%d", minAge)`. Injectivity does NOT
--- rely on the name's characters - a name may itself contain "@" - because the `%d`-rendered
--- minAge is pure digits and is the trailing segment, so the FINAL "@" is unambiguously the
--- separator. `%d` rather than `tostring`, which would alias large doubles through `%.14g` and
--- render `-0.0` as "-0".
local KEY_SEPARATOR = "@"

--- Widest `minAge` this registry will store: the MP wire's UInt16 ceiling, living here rather
--- than in the codec so storage and transport share ONE domain. A key the registry accepted but
--- the wire could not carry would be held and applied on the server while every client snapshot
--- silently dropped it, diverging the two permanently with only a server-side warning. Well
--- above any real animal stage, so it refuses only values that were never valid stage keys.
RLDealerSaleRegistry.MAX_MIN_AGE = 65535

--- True when `minAge` is an integer in [0, MAX_MIN_AGE]. The infinity tests are explicit
--- because `math.floor(inf) == inf` passes the integer check and `inf >= 0` is true, so the
--- range and integer checks alone would let it through. A NaN key would also break
--- `enumerate`'s `table.sort`, so it is refused at the boundary.
---@param minAge any
---@return boolean
local function isValidMinAge(minAge)
    return type(minAge) == "number"
        and minAge == minAge
        and minAge ~= math.huge
        and minAge ~= -math.huge
        and minAge >= 0
        and minAge <= RLDealerSaleRegistry.MAX_MIN_AGE
        and math.floor(minAge) == minAge
end

--- True when `subTypeName` is a non-empty string.
---@param subTypeName any
---@return boolean
local function isValidSubTypeName(subTypeName)
    return type(subTypeName) == "string" and subTypeName ~= ""
end

--- Shared key validation for set/get/clear: the encoded key, or nil after a warning, so
--- key-encoding is never reached with a nil that would crash the concat.
---@param subTypeName any
---@param minAge any
---@param context string names the calling accessor for the log line
---@return string|nil key
local function validatedKey(subTypeName, minAge, context)
    if not isValidSubTypeName(subTypeName) then
        Log:warning("RLDealerSaleRegistry:%s: invalid subTypeName=%s (need non-empty string); rejecting",
            context, tostring(subTypeName))
        return nil
    end
    if not isValidMinAge(minAge) then
        Log:warning("RLDealerSaleRegistry:%s: invalid minAge=%s (need finite integer >= 0); rejecting",
            context, tostring(minAge))
        return nil
    end
    return subTypeName .. KEY_SEPARATOR .. string.format("%d", minAge)
end

-- =============================================================================
-- Construction
-- =============================================================================

--- Construct a new, empty registry. Instance-safe, and a per-savegame reset is achieved by
--- reconstructing the instance, so no clear-all is needed.
---@return table instance
function RLDealerSaleRegistry.new()
    local self = setmetatable({}, RLDealerSaleRegistry_mt)
    self.overrides = {}
    Log:debug("RLDealerSaleRegistry.new: fresh instance")
    return self
end

-- =============================================================================
-- Accessors
-- =============================================================================

--- Upsert an override; state is left unchanged on reject.
---@param subTypeName string canonical subType.name
---@param minAge integer finite integer >= 0
---@param canBeBought boolean desired sale-availability override (either direction is valid)
---@return boolean ok false on an invalid key or a non-boolean value
function RLDealerSaleRegistry:set(subTypeName, minAge, canBeBought)
    local key = validatedKey(subTypeName, minAge, "set")
    if key == nil then return false end

    if type(canBeBought) ~= "boolean" then
        Log:warning("RLDealerSaleRegistry:set: invalid canBeBought=%s for %s (need boolean); rejecting",
            tostring(canBeBought), key)
        return false
    end

    self.overrides[key] = { subTypeName = subTypeName, minAge = minAge, canBeBought = canBeBought }
    Log:debug("RLDealerSaleRegistry:set: %s -> canBeBought=%s", key, tostring(canBeBought))
    return true
end

--- Remove one override.
---@param subTypeName string
---@param minAge integer
---@return boolean removed false when the key was absent or invalid
function RLDealerSaleRegistry:clear(subTypeName, minAge)
    local key = validatedKey(subTypeName, minAge, "clear")
    if key == nil then return false end

    if self.overrides[key] == nil then
        Log:trace("RLDealerSaleRegistry:clear: %s not present; no-op", key)
        return false
    end

    self.overrides[key] = nil
    Log:debug("RLDealerSaleRegistry:clear: %s removed", key)
    return true
end

--- The override value for a key, returned VERBATIM: a stored `false` comes back as `false`,
--- never collapsed to nil the way an `x and y or z` idiom would drop it.
---@param subTypeName string
---@param minAge integer
---@return boolean|nil canBeBought nil when unset or invalid
function RLDealerSaleRegistry:get(subTypeName, minAge)
    local key = validatedKey(subTypeName, minAge, "get")
    if key == nil then return nil end

    local record = self.overrides[key]
    if record == nil then
        Log:trace("RLDealerSaleRegistry:get: %s -> nil (unset)", key)
        return nil
    end

    Log:trace("RLDealerSaleRegistry:get: %s -> %s", key, tostring(record.canBeBought))
    return record.canBeBought
end

--- Enumerate all overrides as shallow-cloned keyed records, sorted by (subTypeName, minAge) for
--- deterministic output. All three fields are scalars, so a shallow clone fully isolates the
--- caller from stored state.
---@return table[] records
function RLDealerSaleRegistry:enumerate()
    local out = {}
    for _, record in pairs(self.overrides) do
        out[#out + 1] = {
            subTypeName = record.subTypeName,
            minAge      = record.minAge,
            canBeBought = record.canBeBought,
        }
    end

    table.sort(out, function(a, b)
        if a.subTypeName ~= b.subTypeName then
            return a.subTypeName < b.subTypeName
        end
        return a.minAge < b.minAge
    end)

    Log:trace("RLDealerSaleRegistry:enumerate: #=%d", #out)
    return out
end

-- =============================================================================
-- Effective-state resolver (pure static selector)
-- =============================================================================

--- Resolve the effective sale-availability by PRESENCE - the override when it is present, else
--- the baseline verbatim. Never `override or baseline`, which would silently drop a `false`
--- override that must win over a `true` baseline. As a pure selector `effective(nil, nil)` is
--- nil; callers guarantee a boolean baseline. Unlogged: a hot-path selector whose inputs and
--- result are observable at the caller.
---@param override boolean|nil
---@param baseline boolean|nil
---@return boolean|nil effective
function RLDealerSaleRegistry.effective(override, baseline)
    if override ~= nil then
        return override
    end
    return baseline
end

Log:debug("RLDealerSaleRegistry: loaded")
