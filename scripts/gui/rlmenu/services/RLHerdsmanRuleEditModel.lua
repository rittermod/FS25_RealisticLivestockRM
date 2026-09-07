-- RLHerdsmanRuleEditModel.lua
-- Pure edit-state model for the Herdsman rule detail pane: overlayRule merges a sparse
-- pending edit onto a stored record for the live render and the flush payload,
-- reshapeParamsForOperation rebuilds params when the operation changes, and duplicateRule
-- clones a stored record into a create-ready copy.
--
-- Purity contract: plain data in, plain data out. No g_* globals, element refs, setText /
-- setVisible / SmoothList calls or XML. Its one sibling dependency is the pure
-- RLHerdsmanRulePresenter, which owns the per-operation default params. Dual-run.

local Log = RmLogging.getLogger("RLRM")

RLHerdsmanRuleEditModel = {}

-- =============================================================================
-- Constants
-- =============================================================================

--- Sentinel an overlay field carries to mean "set the merged field to nil". A sparse
--- pending table cannot otherwise tell "no override, keep stored" (an absent key) from
--- "clear to nil". A unique table, so it can never collide with a real field value.
RLHerdsmanRuleEditModel.CLEAR = {}

--- The whole-record fields an overlay may replace. Immutable identity (id/farmId/version)
--- is absent - the service re-pins those on update. `params` is replaced WHOLESALE, never
--- shallow-merged, so a buy rule's nested budget never loses siblings.
local OVERLAY_FIELDS = { "name", "operation", "enabled", "filterId", "params", "targetHusbandries" }

--- Cross-operation scalar params that may carry over an operation change. Op-specific
--- params (buy's nested `budget`, naming `convention`, ai `semen`) are NEVER carried.
local CARRY_OVER_FIELDS = { "maxAnimals", "mark" }

-- =============================================================================
-- Internal helpers
-- =============================================================================

--- Deep-copy a plain-data value so a merged record never aliases the caller's tables.
--- Assumes acyclic plain data (rule records are); no metatables are preserved.
---@param value any
---@return any copy
local function deepCopy(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for k, v in pairs(value) do
        out[k] = deepCopy(v)
    end
    return out
end

-- =============================================================================
-- Overlay (live render + flush payload)
-- =============================================================================

--- Overlay a sparse `pending` edit onto a `stored` rule record, returning a NEW deep-copied
--- merged record - so rendering the overlay can never mutate the cached stored record.
---@param stored table the stored rule record
---@param pending table|nil sparse field overrides; a field == CLEAR nils it
---@return table merged deep-copied merged record
function RLHerdsmanRuleEditModel.overlayRule(stored, pending)
    local merged = deepCopy(stored)
    if type(pending) ~= "table" then
        Log:trace("RLHerdsmanRuleEditModel.overlayRule: no pending for id=%s -> stored copy",
            tostring(type(stored) == "table" and stored.id or nil))
        return merged
    end

    local applied = {}
    for _, field in ipairs(OVERLAY_FIELDS) do
        local v = pending[field]
        if v == RLHerdsmanRuleEditModel.CLEAR then
            merged[field] = nil
            applied[#applied + 1] = field .. "=nil"
        elseif v ~= nil then
            merged[field] = deepCopy(v)
            applied[#applied + 1] = field
        end
    end

    Log:trace("RLHerdsmanRuleEditModel.overlayRule: id=%s applied=[%s]",
        tostring(type(stored) == "table" and stored.id or nil), table.concat(applied, ","))
    return merged
end

-- =============================================================================
-- Operation-change param reshape (carry-over)
-- =============================================================================

--- Reshape `currentParams` for a new operation: start from that operation's fresh defaults
--- and carry over each CARRY_OVER_FIELDS scalar the new operation also uses, so the user's
--- value survives the switch. Carried values pass through as-is; an out-of-domain value is
--- caught at flush time by validateParams. An unknown operation yields the presenter's
--- empty table plus its one-shot warning.
---@param currentParams table|nil the params before the operation change
---@param newOperation any the operation being switched to
---@return table params complete reshaped params for newOperation
function RLHerdsmanRuleEditModel.reshapeParamsForOperation(currentParams, newOperation)
    local reshaped = RLHerdsmanRulePresenter.defaultParamsForOperation(newOperation)
    local carried = {}
    if type(currentParams) == "table" then
        for _, field in ipairs(CARRY_OVER_FIELDS) do
            if reshaped[field] ~= nil and currentParams[field] ~= nil then
                reshaped[field] = currentParams[field]
                carried[#carried + 1] = field
            end
        end
    end

    Log:trace("RLHerdsmanRuleEditModel.reshapeParamsForOperation: newOp=%s carried=[%s]",
        tostring(newOperation), table.concat(carried, ","))
    return reshaped
end

-- =============================================================================
-- Duplicate
-- =============================================================================

--- Deep-clone a stored rule into a create-ready duplicate under `newName`. No id or version
--- - the service assigns those on create. A dangling source filterId is carried as-is, so
--- the clone is inert until repaired, exactly like its source.
---@param source table the stored source rule record
---@param newName string the collision-free duplicate name
---@return table rule a create-ready duplicate record (no id/version)
function RLHerdsmanRuleEditModel.duplicateRule(source, newName)
    local rule = {
        name              = newName,
        operation         = source.operation,
        farmId            = source.farmId,
        enabled           = source.enabled,
        filterId          = source.filterId,
        targetHusbandries = deepCopy(source.targetHusbandries) or {},
        params            = deepCopy(source.params) or {},
    }
    Log:trace("RLHerdsmanRuleEditModel.duplicateRule: source.id=%s newName=%q operation=%s enabled=%s filterId=%s targets=%d",
        tostring(source.id), tostring(newName), tostring(rule.operation), tostring(rule.enabled),
        tostring(rule.filterId), #rule.targetHusbandries)
    return rule
end

Log:debug("RLHerdsmanRuleEditModel: loaded")
