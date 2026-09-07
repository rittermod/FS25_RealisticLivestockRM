-- RLFilterEvaluator.lua
-- Pure recursive AST evaluator for saveable filters.
--
-- Node shape:
--   node      = group | condition
--   group     = { op="AND"|"OR", children={node, ...} }
--   condition = { field="<catalog key>", cmp="<|<=|==|!=|>=|>|in|notin|contains|notcontains", value=<scalar|list> }
--   filter    = { id, name, animalType, farmId, expression=<node>, version }
--
-- Evaluation rules:
--   - empty AND children -> true (vacuous); logged at :debug
--   - empty OR children  -> false (vacuous); logged at :debug
--   - unknown field      -> false; :warning once per outer call via ctx
--   - type-mismatch      -> false; :trace once per (field, outer-call) via ctx
--   - monitor-gated off  -> false; :trace
--   - getter returns nil for any reason -> false (graceful)
--
-- Logging precedence: leaf :trace, outer :debug, warnings deduped.

local Log = RmLogging.getLogger("RLRM")

RLFilterEvaluator = {}

-- =============================================================================
-- Comparator implementations
-- =============================================================================

--- Return true when `animalValue op conditionValue` holds. Graceful on nil inputs - any nil
--- operand fails the comparison. `in` / `notin` treat `conditionValue` as a list.
---@param op string comparator token
---@param animalValue any value returned by field getter
---@param conditionValue any value stored on the condition
---@return boolean
local function compare(op, animalValue, conditionValue)
    -- `==` and `!=` gate on type equality FIRST, because Lua's raw `~=` returns true for
    -- `age ~= "50"` - failing open and broadening matches on malformed data. A type mismatch is
    -- false for both operators, so bad filter data can never widen the result set.
    if op == "==" or op == "!=" then
        if type(animalValue) ~= type(conditionValue) then
            return false
        end
        if op == "==" then return animalValue == conditionValue end
        return animalValue ~= conditionValue
    end

    if op == "in" or op == "notin" then
        if type(conditionValue) ~= "table" then return false end
        local found = false
        for _, v in ipairs(conditionValue) do
            if animalValue == v then
                found = true
                break
            end
        end
        if op == "in" then return found end
        return not found
    end

    -- Case-insensitive plain (non-pattern) substring match. Both operands must be strings, and
    -- an empty needle is rejected so "contains ''" does not trivially match every named animal.
    if op == "contains" or op == "notcontains" then
        if type(animalValue) ~= "string" or type(conditionValue) ~= "string" then
            return false
        end
        if conditionValue == "" then return false end
        local found = string.find(animalValue:lower(), conditionValue:lower(), 1, true) ~= nil
        if op == "contains" then return found end
        return not found
    end

    -- Numeric comparators require non-nil numbers on both sides.
    if animalValue == nil or conditionValue == nil then return false end
    if type(animalValue) ~= "number" or type(conditionValue) ~= "number" then
        return false
    end

    if op == "<"  then return animalValue <  conditionValue end
    if op == "<=" then return animalValue <= conditionValue end
    if op == ">"  then return animalValue >  conditionValue end
    if op == ">=" then return animalValue >= conditionValue end
    return false
end

-- =============================================================================
-- Leaf (condition) evaluation
-- =============================================================================

--- Evaluate a condition node against an animal. Never raises: every graceful-degrade case
--- returns false and logs its reason, with `ctx` deduping warnings per outer call.
---@param condition table { field, cmp, value }
---@param animal table
---@param ctx table per-call context with `warnedFields` and `typeMismatchFields` sets
---@return boolean
local function evalCondition(condition, animal, ctx)
    if condition == nil or condition.field == nil or condition.cmp == nil then
        Log:trace("RLFilterEvaluator.evalCondition: malformed condition, returning false")
        return false
    end

    local fieldKey = condition.field
    local field = RLFilterFieldCatalog.get(fieldKey)

    if field == nil then
        if not ctx.warnedFields[fieldKey] then
            Log:warning("RLFilterEvaluator.evalCondition: unknown field '%s' (catalog lookup failed); returning false for all occurrences in this call",
                tostring(fieldKey))
            ctx.warnedFields[fieldKey] = true
        end
        return false
    end

    -- Type-scope gate, e.g. genetics.productivity on PIG.
    local animalTypeIndex = animal and animal.animalTypeIndex or nil
    if not RLFilterFieldCatalog.isAvailableForType(field, animalTypeIndex) then
        if not ctx.typeMismatchFields[fieldKey] then
            Log:trace("RLFilterEvaluator.evalCondition: field '%s' not available for animalTypeIndex=%s; returning false",
                tostring(fieldKey), tostring(animalTypeIndex))
            ctx.typeMismatchFields[fieldKey] = true
        end
        return false
    end

    -- The monitor gate is handled inside the getter; a nil result is the signal.
    local animalValue = field.getter(animal)
    if animalValue == nil then
        Log:trace("RLFilterEvaluator.evalCondition: field '%s' returned nil for animal (monitor off / missing genetics / etc.); returning false",
            tostring(fieldKey))
        return false
    end

    local result = compare(condition.cmp, animalValue, condition.value)
    Log:trace("RLFilterEvaluator.evalCondition: field=%s cmp=%s animal=%s cond=%s -> %s",
        tostring(fieldKey), tostring(condition.cmp),
        tostring(animalValue), tostring(condition.value), tostring(result))
    return result
end

-- =============================================================================
-- Recursive group / node evaluation
-- =============================================================================

--- Dispatch by node kind: a group has `op` and `children`, a condition has `field` and `cmp`.
---@param node table
---@param animal table
---@param ctx table
---@return boolean
local function evalNode(node, animal, ctx)
    if node == nil then
        Log:trace("RLFilterEvaluator.evalNode: nil node, returning false")
        return false
    end

    if node.op ~= nil and node.children ~= nil then
        local op = node.op
        local children = node.children

        if #children == 0 then
            if op == "AND" then
                Log:debug("RLFilterEvaluator.evalNode: empty AND children, returning true (vacuous)")
                return true
            elseif op == "OR" then
                Log:debug("RLFilterEvaluator.evalNode: empty OR children, returning false (vacuous)")
                return false
            else
                Log:trace("RLFilterEvaluator.evalNode: empty children with unknown op=%s, returning false",
                    tostring(op))
                return false
            end
        end

        if op == "AND" then
            for _, child in ipairs(children) do
                if not evalNode(child, animal, ctx) then return false end
            end
            return true
        elseif op == "OR" then
            for _, child in ipairs(children) do
                if evalNode(child, animal, ctx) then return true end
            end
            return false
        else
            Log:trace("RLFilterEvaluator.evalNode: unknown group op=%s, returning false",
                tostring(op))
            return false
        end
    end

    return evalCondition(node, animal, ctx)
end

-- =============================================================================
-- Public entry point
-- =============================================================================

--- Evaluate a filter record (carrying `.expression`) or a bare node against an animal. A fresh
--- `ctx` is allocated per outer call when none is supplied, giving per-call warning dedup.
---@param filterOrNode table filter (with .expression) or node (group|condition)
---@param animal table animal instance (read-only access via catalog getters)
---@param ctx table|nil optional context; caller rarely supplies one
---@return boolean
function RLFilterEvaluator.evaluate(filterOrNode, animal, ctx)
    ctx = ctx or { warnedFields = {}, typeMismatchFields = {} }
    ctx.warnedFields = ctx.warnedFields or {}
    ctx.typeMismatchFields = ctx.typeMismatchFields or {}

    if filterOrNode == nil then
        Log:debug("RLFilterEvaluator.evaluate: nil filter/node, returning false")
        return false
    end

    -- The catalog getters assume a non-nil animal table, so this guards once at the entry point
    -- rather than inside every getter, preserving the never-raises contract.
    if animal == nil then
        Log:trace("RLFilterEvaluator.evaluate: nil animal, returning false")
        return false
    end

    local node = filterOrNode.expression or filterOrNode
    local result = evalNode(node, animal, ctx)

    local filterId = filterOrNode.id or "<inline>"
    Log:debug("RLFilterEvaluator.evaluate: filter=%s animal.uniqueId=%s -> %s",
        tostring(filterId),
        tostring(animal and animal.uniqueId),
        tostring(result))
    return result
end

Log:trace("RLFilterEvaluator: loaded")
