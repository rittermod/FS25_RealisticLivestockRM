-- RLFilterFieldCatalog.lua
-- Declarative registry of the fields usable in saveable filters, read by the evaluator,
-- both codecs and the editor's field picker.
--
-- Field entry shape:
--   {
--     key          = "<stable string, also stored in filters>",
--     type         = "number" | "bool" | "enum" | "string",
--     cmps         = { "<", "<=", "==", "!=", ">=", ">", "in", "notin", "contains", "notcontains" },
--     animalTypes  = "all" | { "COW", "SHEEP", ... },  -- stable names, resolved at
--                                                       -- runtime: the AnimalType global
--                                                       -- is populated after this load
--     getter       = function(animal) -> value | nil,
--     monitorGated = true | false,   -- true means getter requires monitor.active
--     scale        = "0-99" | nil,   -- presentation scale hint for UI
--     min          = number | nil,   -- inclusive lower bound, number fields only
--     max          = number | nil,   -- inclusive upper bound
--   }
--
-- `min` / `max` are enforced by the EDITOR on OK and never by the evaluator, so an
-- out-of-range value still evaluates correctly. Enum values are STABLE INTERNAL KEYS,
-- never translated strings - the UI translates at render time.

local Log = RmLogging.getLogger("RLRM")

RLFilterFieldCatalog = {}

-- =============================================================================
-- Comparator sets
-- =============================================================================

-- Per-type comparator sets. `!=` is the leaf-level negation primitive, the AST having no NOT
-- operator. String is substring-only, keeping its op set DISJOINT from enum's - both are Lua
-- strings and would otherwise be indistinguishable.
local NUMBER_CMPS = { "<", "<=", "==", "!=", ">=", ">", "in", "notin" }
local BOOL_CMPS   = { "==" }
local ENUM_CMPS   = { "==", "!=", "in", "notin" }
local STRING_CMPS = { "contains", "notcontains" }

-- Per-type default comparator for a newly added row. Each is picked so the row MATCHES
-- EVERY ANIMAL at its default value and the user tightens from there - taking cmps[1]
-- for a number would default to `age < 0`, which matches nothing.
local DEFAULT_CMP_BY_TYPE = {
    number = ">=",
    bool   = "==",
    enum   = "==",
    string = "contains",
}

-- =============================================================================
-- Getter helpers
-- =============================================================================

--- Process-lifetime flag: emit the helper-missing warning exactly once so
--- a load-order regression is visible in logs without spamming every genetics
--- getter call.
local _warnedHelperMissing = false

--- Return the numeric value scaled to 0-99, or nil if the raw value is nil.
--- Emits a one-shot warning if RLScaleHelper is unavailable so load-order
--- regressions are diagnosable; otherwise falls through to the evaluator's
--- generic nil-value trace branch.
local function scaled(rawValue)
    if rawValue == nil then return nil end
    if RLScaleHelper == nil or RLScaleHelper.scaleToNinetyNine == nil then
        if not _warnedHelperMissing then
            Log:warning("RLFilterFieldCatalog.scaled: RLScaleHelper unavailable, genetics getters returning nil (check main.lua SECTION 2b load order)")
            _warnedHelperMissing = true
        end
        return nil
    end
    return RLScaleHelper.scaleToNinetyNine(rawValue)
end

--- True when the animal's monitor is active (weight/health values are
--- only meaningful when the monitor is running). Returns false if the
--- monitor record is missing or the animal was flagged as removed.
local function monitorActive(animal)
    return animal ~= nil
        and animal.monitor ~= nil
        and animal.monitor.active == true
        and animal.monitor.removed ~= true
end

-- =============================================================================
-- Field registry
-- =============================================================================

--- Map of catalog key -> field entry. Declared as an ordered array first so
--- that field order is deterministic; then also indexed by key for O(1)
--- lookup via RLFilterFieldCatalog.get().
---@type table[]
RLFilterFieldCatalog.FIELDS = {
    -- ---------- Age / identity flags ----------
    {
        key         = "age",
        type        = "number",
        cmps        = NUMBER_CMPS,
        animalTypes = "all",
        getter      = function(animal) return animal.age end,
        monitorGated = false,
        -- Best-effort upper bound: HORSE's 360-month max plus headroom. The editor renders
        -- cross-species filters with animalType=nil, so a per-species cap is not reachable here.
        min          = 0,
        max          = 400,
    },
    {
        key         = "gender",
        type        = "enum",
        cmps        = ENUM_CMPS,
        animalTypes = "all",
        getter      = function(animal) return animal.gender end,
        monitorGated = false,
    },
    {
        key         = "isCastrated",
        type        = "bool",
        cmps        = BOOL_CMPS,
        animalTypes = "all",
        getter      = function(animal) return animal.isCastrated == true end,
        monitorGated = false,
    },
    {
        key         = "isPregnant",
        type        = "bool",
        cmps        = BOOL_CMPS,
        animalTypes = "all",
        getter      = function(animal) return animal.isPregnant == true end,
        monitorGated = false,
    },
    {
        key         = "isLactating",
        type        = "bool",
        cmps        = BOOL_CMPS,
        animalTypes = { "COW" },
        getter      = function(animal) return animal.isLactating == true end,
        monitorGated = false,
    },
    {
        key         = "hasName",
        type        = "bool",
        cmps        = BOOL_CMPS,
        animalTypes = "all",
        getter      = function(animal)
            if animal.getHasName ~= nil then return animal:getHasName() end
            return animal.name ~= nil and animal.name ~= ""
        end,
        monitorGated = false,
    },
    {
        key         = "hasAnyDisease",
        type        = "bool",
        cmps        = BOOL_CMPS,
        animalTypes = "all",
        -- Both branches implement the SAME symptomatic rule - only an INFECTIOUS record
        -- counts - and both return a strict boolean, the evaluator type-gating a nil into
        -- a silent no-match. Keep the plain-table fallback in lockstep, gate included.
        --
        -- RLDiseaseRecord is read INSIDE the closure, which frees this file's load
        -- position: a file-scope alias would capture a nil.
        getter      = function(animal)
            if animal.getHasAnyDisease ~= nil then return animal:getHasAnyDisease() == true end
            if g_diseaseManager == nil or not g_diseaseManager.diseasesEnabled
                or animal.diseases == nil then
                return false
            end
            for _, disease in ipairs(animal.diseases) do
                if disease.state == RLDiseaseRecord.STATE.INFECTIOUS then return true end
            end
            return false
        end,
        monitorGated = false,
    },
    {
        key         = "hasAnyMark",
        type        = "bool",
        cmps        = BOOL_CMPS,
        animalTypes = "all",
        -- Mirrors Animal:getMarked() with no key:
        -- true iff at least one entry in animal.marks has active=true. Fallback path
        -- walks the raw table so tests can use plain-table fake animals. Generic
        -- "any mark" only; per-mark-kind fields (PLAYER / AI_MANAGER_*) deferred.
        getter      = function(animal)
            if animal.getMarked ~= nil then return animal:getMarked() == true end
            if animal.marks == nil then return false end
            for _, mark in pairs(animal.marks) do
                if mark.active then return true end
            end
            return false
        end,
        monitorGated = false,
    },
    {
        key         = "name",
        type        = "string",
        cmps        = STRING_CMPS,
        animalTypes = "all",
        -- Returns "" and NEVER nil for an unset name: an empty name vacuously does
        -- not contain any needle, so notcontains is true. A nil would hit the
        -- evaluator's blanket guard and collapse notcontains to false, silently
        -- excluding every unnamed animal from such a filter.
        getter      = function(animal)
            if animal.name == nil then return "" end
            return animal.name
        end,
        monitorGated = false,
    },

    -- ---------- Monitor-gated metrics ----------
    {
        key         = "weight",
        type        = "number",
        cmps        = NUMBER_CMPS,
        animalTypes = "all",
        monitorGated = true,
        getter      = function(animal)
            if not monitorActive(animal) then return nil end
            return animal.weight
        end,
        -- Only the FLOOR is knowable: target weights are derived at runtime and vary
        -- by map mod, so there is no fixed ceiling to impose without guessing.
        min          = 0,
    },
    {
        key         = "health",
        type        = "number",
        cmps        = NUMBER_CMPS,
        animalTypes = "all",
        monitorGated = true,
        getter      = function(animal)
            if not monitorActive(animal) then return nil end
            return animal.health
        end,
        min          = 0,
        max          = 100,
    },

    -- ---------- Genetics (0-99 scale) ----------
    -- All genetics fields use min=0, max=99 to match the canonical
    -- presentation scale (scaled(rawValue) -> 0..99). The evaluator
    -- compares scaled values, so the bounds mirror the visible domain.
    {
        key         = "genetics.metabolism",
        type        = "number",
        cmps        = NUMBER_CMPS,
        animalTypes = "all",
        scale       = "0-99",
        getter      = function(animal)
            return animal.genetics and scaled(animal.genetics.metabolism) or nil
        end,
        monitorGated = false,
        min          = 0,
        max          = 99,
    },
    {
        key         = "genetics.health",
        type        = "number",
        cmps        = NUMBER_CMPS,
        animalTypes = "all",
        scale       = "0-99",
        getter      = function(animal)
            return animal.genetics and scaled(animal.genetics.health) or nil
        end,
        monitorGated = false,
        min          = 0,
        max          = 99,
    },
    {
        key         = "genetics.fertility",
        type        = "number",
        cmps        = NUMBER_CMPS,
        animalTypes = "all",
        scale       = "0-99",
        getter      = function(animal)
            return animal.genetics and scaled(animal.genetics.fertility) or nil
        end,
        monitorGated = false,
        min          = 0,
        max          = 99,
    },
    {
        key         = "genetics.quality",
        type        = "number",
        cmps        = NUMBER_CMPS,
        animalTypes = "all",
        scale       = "0-99",
        getter      = function(animal)
            return animal.genetics and scaled(animal.genetics.quality) or nil
        end,
        monitorGated = false,
        min          = 0,
        max          = 99,
    },
    {
        key         = "genetics.productivity",
        type        = "number",
        cmps        = NUMBER_CMPS,
        animalTypes = { "COW", "SHEEP", "CHICKEN" },
        scale       = "0-99",
        getter      = function(animal)
            return animal.genetics and scaled(animal.genetics.productivity) or nil
        end,
        monitorGated = false,
        min          = 0,
        max          = 99,
    },
    {
        key         = "genetics.overall",
        type        = "number",
        cmps        = NUMBER_CMPS,
        animalTypes = "all",
        scale       = "0-99",
        -- Overall = scaleToNinetyNine(avg of present stats). Matches the
        -- name-tag convention at AnimalScreenBase.formatDisplayName.
        getter      = function(animal)
            if animal.genetics == nil then return nil end
            local total, count = 0, 0
            for _, v in pairs(animal.genetics) do
                if v ~= nil then
                    total = total + v
                    count = count + 1
                end
            end
            if count == 0 then return nil end
            return scaled(total / count)
        end,
        monitorGated = false,
        min          = 0,
        max          = 99,
    },

    -- ---------- Subtype / breed ----------
    {
        key         = "subType",
        type        = "enum",
        cmps        = ENUM_CMPS,
        animalTypes = "all",
        getter      = function(animal) return animal.subType end,
        monitorGated = false,
    },
}

-- =============================================================================
-- Indexed lookup
-- =============================================================================

--- key -> field entry for O(1) lookup.
---@type table<string, table>
RLFilterFieldCatalog._BY_KEY = {}
for _, field in ipairs(RLFilterFieldCatalog.FIELDS) do
    RLFilterFieldCatalog._BY_KEY[field.key] = field
end

--- Look up a field entry by key. Returns nil when the key is unknown
--- (evaluator warns on its behalf; catalog stays silent).
---@param key string
---@return table|nil field entry
function RLFilterFieldCatalog.get(key)
    return RLFilterFieldCatalog._BY_KEY[key]
end

--- Inclusive-range check for editor commits, run after the NaN reject. EDITOR-ONLY: the
--- evaluator never consults min/max, and an out-of-range value still evaluates correctly.
---@param field table|nil entry from FIELDS (nil-tolerant; treated as in-range)
---@param num number value to check
---@return boolean ok true when in range, false otherwise
---@return table|nil bounds {min=number|nil, max=number|nil} on reject; nil on accept
function RLFilterFieldCatalog.isValueInRange(field, num)
    if field == nil or field.type ~= "number" then
        Log:trace("RLFilterFieldCatalog.isValueInRange: non-number field (key=%s type=%s); returning true",
            field and tostring(field.key) or "nil",
            field and tostring(field.type) or "nil")
        return true, nil
    end

    local minB, maxB = field.min, field.max
    if minB == nil and maxB == nil then
        Log:trace("RLFilterFieldCatalog.isValueInRange: field=%s unbounded; num=%s -> true",
            tostring(field.key), tostring(num))
        return true, nil
    end

    local belowMin = (minB ~= nil) and (num < minB)
    local aboveMax = (maxB ~= nil) and (num > maxB)
    if belowMin or aboveMax then
        Log:trace("RLFilterFieldCatalog.isValueInRange: field=%s num=%s bounds(min=%s,max=%s) ok=false",
            tostring(field.key), tostring(num), tostring(minB), tostring(maxB))
        return false, { min = minB, max = maxB }
    end

    Log:trace("RLFilterFieldCatalog.isValueInRange: field=%s num=%s bounds(min=%s,max=%s) ok=true",
        tostring(field.key), tostring(num), tostring(minB), tostring(maxB))
    return true, nil
end

--- Process-lifetime flag: emit the AnimalType-missing warning exactly once.
--- Distinct from _warnedHelperMissing so each load-order regression is
--- reported independently.
local _warnedAnimalTypeMissing = false

--- True when a field is valid for an animal type; a missing index means all types. The
--- declared NAMES resolve at CALL time, because the registry global is populated after
--- this file loads.
---@param field table entry from FIELDS
---@param animalTypeIndex number|nil
---@return boolean
function RLFilterFieldCatalog.isAvailableForType(field, animalTypeIndex)
    if field == nil then return false end
    if field.animalTypes == "all" then return true end
    if animalTypeIndex == nil then return true end
    if _G.AnimalType == nil then
        if not _warnedAnimalTypeMissing then
            Log:warning("RLFilterFieldCatalog.isAvailableForType: AnimalType global is nil; allowing all type-scoped fields through (check AnimalSystem load order)")
            _warnedAnimalTypeMissing = true
        end
        return true
    end
    for _, allowedName in ipairs(field.animalTypes) do
        if _G.AnimalType[allowedName] == animalTypeIndex then return true end
    end
    return false
end

--- The ordered subset of FIELDS available for an animal type, optionally narrowed by
--- `typeFilter` - nil, a type string, or a set table. Ordering follows DECLARATION order,
--- which is what keeps the editor's field picker stable across re-renders.
---@param animalTypeIndex number|nil
---@param typeFilter string|table|nil
---@return table[] filtered ordered field entries
function RLFilterFieldCatalog.getAllForAnimalType(animalTypeIndex, typeFilter)
    local out = {}
    local filterSet
    if type(typeFilter) == "string" then
        filterSet = { [typeFilter] = true }
    elseif type(typeFilter) == "table" then
        filterSet = typeFilter
    end
    for _, field in ipairs(RLFilterFieldCatalog.FIELDS) do
        local typeOk = (filterSet == nil) or (filterSet[field.type] == true)
        if typeOk and RLFilterFieldCatalog.isAvailableForType(field, animalTypeIndex) then
            table.insert(out, field)
        end
    end
    Log:trace("RLFilterFieldCatalog.getAllForAnimalType: animalTypeIndex=%s typeFilter=%s -> %d field(s)",
        tostring(animalTypeIndex), tostring(typeFilter), #out)
    return out
end

--- Per-type default for a newly seeded row: 0, false or the empty needle. ENUM returns NIL -
--- its domains live with the display layer, and the dialog patches in domain[1] after coercion.
---@param fieldType string|nil
---@return any default value (nil for enum and unknown types)
function RLFilterFieldCatalog.getDefaultValueForType(fieldType)
    if fieldType == "number" then return 0 end
    if fieldType == "bool"   then return false end
    if fieldType == "string" then return "" end
    -- enum: nil so the dialog seeds from RLFilterFieldDisplay.getEnumDomain
    return nil
end

--- The default cmp for a field, falling back to its first cmp so a future type still gets
--- a deterministic default. Returns nil only for a field with neither - a catalog defect.
---@param field table entry from FIELDS
---@return string|nil cmp
function RLFilterFieldCatalog.getDefaultCmpForField(field)
    if field == nil then return nil end
    local byType = DEFAULT_CMP_BY_TYPE[field.type]
    if byType ~= nil then return byType end
    if field.cmps ~= nil and field.cmps[1] ~= nil then
        Log:trace("RLFilterFieldCatalog.getDefaultCmpForField: no DEFAULT_CMP_BY_TYPE for type=%s, falling back to cmps[1]=%s",
            tostring(field.type), tostring(field.cmps[1]))
        return field.cmps[1]
    end
    Log:trace("RLFilterFieldCatalog.getDefaultCmpForField: field key=%s has no DEFAULT_CMP_BY_TYPE entry and no cmps",
        tostring(field.key))
    return nil
end

-- Exposed for tests that need to inspect the default table directly.
RLFilterFieldCatalog._DEFAULT_CMP_BY_TYPE = DEFAULT_CMP_BY_TYPE

--- Coerce a condition row after a field change. The cmp survives if the new field accepts it,
--- else resets; a diverging TYPE also resets the value and names the stale rawText in
--- clearKeys, a nil-valued key vanishing from a table literal. The CALLER decides which cmps
--- are editable.
---@param oldCond table {field=string, cmp=string, value=any, rawText=string?}
---@param newFieldKey string the field the user just selected
---@param editableCmps string[]|nil whitelist of cmps the caller's editor renders
---@return table {patch=table, clearKeys=string[]|nil}
---   patch always carries `field`. `cmp` is present only when reset.
---   `value` is present only when types diverge.
---   `clearKeys` is `{"rawText"}` when types diverge, nil otherwise.
function RLFilterFieldCatalog.coerceConditionOnFieldChange(oldCond, newFieldKey, editableCmps)
    if oldCond == nil or newFieldKey == nil then
        Log:warning("RLFilterFieldCatalog.coerceConditionOnFieldChange: nil oldCond=%s newFieldKey=%s",
            tostring(oldCond), tostring(newFieldKey))
        return { patch = {}, clearKeys = nil }
    end
    local newField = RLFilterFieldCatalog.get(newFieldKey)
    if newField == nil then
        Log:warning("RLFilterFieldCatalog.coerceConditionOnFieldChange: unknown newFieldKey=%s; returning identity patch",
            tostring(newFieldKey))
        return { patch = { field = newFieldKey }, clearKeys = nil }
    end
    local oldField = RLFilterFieldCatalog.get(oldCond.field)
    local patch = { field = newField.key }

    local cmps = editableCmps
    if cmps == nil then cmps = newField.cmps end
    local cmpStillValid = false
    if cmps ~= nil then
        for _, c in ipairs(cmps) do
            if c == oldCond.cmp then cmpStillValid = true; break end
        end
    end
    if not cmpStillValid then
        patch.cmp = RLFilterFieldCatalog.getDefaultCmpForField(newField)
    end

    local clearKeys = nil
    local typesDiverge = (oldField == nil or oldField.type ~= newField.type)
    if typesDiverge then
        local defaultValue = RLFilterFieldCatalog.getDefaultValueForType(newField.type)
        if defaultValue == nil then
            -- Enum's default is domain-driven and the catalog cannot seed it, so flag
            -- `value` for explicit clearing and let the dialog patch in domain[1].
            -- Without this the stale enum value survives the type swap, the patch merge
            -- guarding on `~= nil`.
            clearKeys = { "rawText", "value" }
        else
            patch.value = defaultValue
            clearKeys = { "rawText" }
        end
    end

    Log:trace("RLFilterFieldCatalog.coerceConditionOnFieldChange: oldField=%s newField=%s typesDiverge=%s cmpReset=%s",
        tostring(oldCond.field), tostring(newField.key),
        tostring(typesDiverge), tostring(patch.cmp ~= nil))
    return { patch = patch, clearKeys = clearKeys }
end

-- =============================================================================
-- Cmp-change coercion (scalar <-> list value shape)
-- =============================================================================

--- Cmp groups by value-shape. Scalar cmps store value as a single primitive;
--- list cmps store value as an array of primitives. Substring cmps live in
--- their own scalar-string group and are disjoint from in/notin.
local SCALAR_CMPS    = { ["<"]=true, ["<="]=true, ["=="]=true, ["!="]=true, [">="]=true, [">"]=true }
local LIST_CMPS      = { ["in"]=true, ["notin"]=true }
local SUBSTRING_CMPS = { ["contains"]=true, ["notcontains"]=true }

local function cmpShape(cmp)
    if SCALAR_CMPS[cmp]    then return "scalar" end
    if LIST_CMPS[cmp]      then return "list" end
    if SUBSTRING_CMPS[cmp] then return "substring" end
    return nil
end

--- Coerce a condition row when the cmp changes within one field, wrapping or unwrapping the
--- value across a scalar/list shape change. A list narrowing to a scalar takes the FIRST
--- element; an illegal transition clears both the value and the raw text.
---@param oldCond table {field, cmp, value, rawText?}
---@param newCmp string the cmp the user just picked
---@param fieldEntry table the active catalog field (cmp set must include newCmp)
---@return table {patch=table, clearKeys=string[]|nil}
function RLFilterFieldCatalog.coerceConditionOnCmpChange(oldCond, newCmp, fieldEntry)
    if oldCond == nil or newCmp == nil or fieldEntry == nil then
        Log:warning("RLFilterFieldCatalog.coerceConditionOnCmpChange: nil arg oldCond=%s newCmp=%s fieldEntry=%s",
            tostring(oldCond), tostring(newCmp), tostring(fieldEntry))
        return { patch = {}, clearKeys = nil }
    end

    local patch = { cmp = newCmp }
    local clearKeys = nil
    local oldShape = cmpShape(oldCond.cmp)
    local newShape = cmpShape(newCmp)

    if oldShape == newShape then
        -- Same shape -> value preserved (already on oldCond; no patch entry).
        Log:trace("RLFilterFieldCatalog.coerceConditionOnCmpChange: shape preserved (%s); value untouched",
            tostring(newShape))
        return { patch = patch, clearKeys = nil }
    end

    if oldShape == "scalar" and newShape == "list" then
        if oldCond.value ~= nil then
            patch.value = { oldCond.value }
            Log:trace("RLFilterFieldCatalog.coerceConditionOnCmpChange: scalar->list wrap value=%s",
                tostring(oldCond.value))
        else
            clearKeys = { "value" }
            Log:trace("RLFilterFieldCatalog.coerceConditionOnCmpChange: scalar->list, oldValue nil; clearing")
        end
    elseif oldShape == "list" and newShape == "scalar" then
        if type(oldCond.value) == "table" and oldCond.value[1] ~= nil then
            patch.value = oldCond.value[1]
            local discardedCount = math.max(0, #oldCond.value - 1)
            if discardedCount > 0 then
                Log:warning("RLFilterFieldCatalog.coerceConditionOnCmpChange: list->scalar discarding %d value(s) beyond [1] (kept=%s)",
                    discardedCount, tostring(oldCond.value[1]))
            else
                Log:trace("RLFilterFieldCatalog.coerceConditionOnCmpChange: list->scalar value=%s",
                    tostring(oldCond.value[1]))
            end
        else
            clearKeys = { "value" }
            Log:trace("RLFilterFieldCatalog.coerceConditionOnCmpChange: list->scalar, oldValue empty; clearing")
        end
    else
        -- Substring <-> other (illegal across enum/string boundary) or unknown
        -- cmp. Reset value + rawText so the dialog seeds defaults; warn so a
        -- logic bug in the caller's cmp gate is visible.
        Log:warning("RLFilterFieldCatalog.coerceConditionOnCmpChange: illegal transition %s(%s) -> %s(%s); clearing value+rawText",
            tostring(oldCond.cmp), tostring(oldShape),
            tostring(newCmp), tostring(newShape))
        clearKeys = { "value", "rawText" }
    end

    return { patch = patch, clearKeys = clearKeys }
end

-- Exposed for tests + the dialog's editable-cmp gate.
RLFilterFieldCatalog._SCALAR_CMPS    = SCALAR_CMPS
RLFilterFieldCatalog._LIST_CMPS      = LIST_CMPS
RLFilterFieldCatalog._SUBSTRING_CMPS = SUBSTRING_CMPS

Log:debug("RLFilterFieldCatalog: loaded %d fields", #RLFilterFieldCatalog.FIELDS)
