-- RLFilterSerialization.lua
-- Recursive XML writer/reader for saveable filter records.
--
-- Canonical XML key contract:
--
--   rm_RlSettings.filters.filter(i)
--     @id, @name, @animalType, @farmId, @version
--     .group                       -- root group, exactly one
--       @op                        -- "AND" | "OR"
--       .condition(j)
--         @field, @cmp, @value     -- scalar (type per catalog)
--         .value(k)                -- list elements for `in` / `notin` only
--       .group(j)                  -- nested child group (recursive)
--
-- Value encoding is driven by RLFilterFieldCatalog entry.type:
--   number -> setFloat/getFloat
--   bool   -> setBool /getBool
--   enum   -> setString/getString
--   string -> setString/getString (same codec as enum; semantic split only)
--
-- animalType is stored as the STABLE STRING NAME, not the runtime int index, matching the
-- persistence contract `AnimalPersistence` uses for subType: it survives AnimalType reordering
-- across game versions or mod sets. The MP wire format still carries the int index.
--
-- Fail-closed on both directions. A failed animalType name<->index resolution warns, so a silent
-- scope drop on reload is diagnosable. A missing `.group` subtree on read warns and skips the
-- filter rather than fabricating an empty AND that would match every animal. A scalar condition
-- with a nil `value` is rejected at write time instead of passing nil to the XML C bindings. And
-- `cmp` is validated against the catalog field's whitelist on read and write alike.

local Log = RmLogging.getLogger("RLRM")

RLFilterSerialization = {}

-- =============================================================================
-- Type codecs (driven by RLFilterFieldCatalog entry.type)
-- =============================================================================

--- Per-catalog-type XML read/write functions. Keyed by catalog `type` value.
---@type table<string, { write: fun(x:table, k:string, v:any), read: fun(x:table, k:string, d:any):any }>
local TYPE_CODECS = {
    number = {
        write = function(x, k, v) x:setFloat(k, v) end,
        read  = function(x, k, d) return x:getFloat(k, d) end,
    },
    bool = {
        write = function(x, k, v) x:setBool(k, v) end,
        read  = function(x, k, d) return x:getBool(k, d) end,
    },
    enum = {
        write = function(x, k, v) x:setString(k, v) end,
        read  = function(x, k, d) return x:getString(k, d) end,
    },
    string = {
        write = function(x, k, v) x:setString(k, v) end,
        read  = function(x, k, d) return x:getString(k, d) end,
    },
}

-- =============================================================================
-- AnimalType int <-> stable name (warn on silent drops)
-- =============================================================================

--- Per-process dedup for type-name / type-index resolution warnings. Emitting
--- once per distinct bad input keeps a corrupt save from spamming the log
--- while still surfacing every distinct failure.
local _warnedTypeIndex = {}
local _warnedTypeName  = {}

--- Resolve an AnimalType int index back to its stable string name
--- ("COW", "PIG", ...). Returns nil if the global is missing or the
--- index is not registered (e.g. map bridge not yet loaded).
---
--- When the caller supplied a non-nil idx but resolution fails, emit a
--- one-shot `:warning` keyed on that idx. Silent nil returns would let
--- a typed filter silently demote to global scope on re-save.
---@param idx integer|nil
---@return string|nil name
local function animalTypeIndexToName(idx)
    if idx == nil then return nil end
    if _G.AnimalType == nil then
        if not _warnedTypeIndex[idx] then
            Log:warning("RLFilterSerialization.animalTypeIndexToName: _G.AnimalType is nil; cannot resolve idx=%s (scope will be silently dropped)",
                tostring(idx))
            _warnedTypeIndex[idx] = true
        end
        return nil
    end
    for name, i in pairs(_G.AnimalType) do
        if type(i) == "number" and i == idx then return name end
    end
    if not _warnedTypeIndex[idx] then
        Log:warning("RLFilterSerialization.animalTypeIndexToName: idx=%s not registered in AnimalType; filter scope will persist as global on next save",
            tostring(idx))
        _warnedTypeIndex[idx] = true
    end
    return nil
end

--- Resolve a stable AnimalType name back to its runtime int index.
--- Returns nil when the name isn't registered.
---
--- Emits a one-shot `:warning` when a non-nil name fails to resolve
--- (e.g. the mod that registered a custom type was uninstalled between
--- save cycles). Without this warning a COW-scoped filter would silently
--- become global on reload.
---@param name string|nil
---@return integer|nil index
local function animalTypeNameToIndex(name)
    if name == nil or name == "" then return nil end
    if _G.AnimalType == nil then
        if not _warnedTypeName[name] then
            Log:warning("RLFilterSerialization.animalTypeNameToIndex: _G.AnimalType is nil; cannot resolve name=%s", tostring(name))
            _warnedTypeName[name] = true
        end
        return nil
    end
    local idx = _G.AnimalType[name]
    if type(idx) == "number" then return idx end
    if not _warnedTypeName[name] then
        Log:warning("RLFilterSerialization.animalTypeNameToIndex: name='%s' not registered in AnimalType (mod uninstalled?); filter will load as global scope",
            tostring(name))
        _warnedTypeName[name] = true
    end
    return nil
end

-- =============================================================================
-- cmp validation (whitelist against catalog field.cmps)
-- =============================================================================

--- True when `cmp` appears in `field.cmps`. Used to fail-closed on invalid
--- comparators at the I/O boundary rather than deferring the error to the
--- evaluator where it'd silently return false for every animal with no
--- diagnostic trail.
---@param field table catalog entry
---@param cmp string
---@return boolean
local function isCmpAllowed(field, cmp)
    if field == nil or field.cmps == nil then return false end
    for _, allowed in ipairs(field.cmps) do
        if allowed == cmp then return true end
    end
    return false
end

-- =============================================================================
-- Condition (leaf) IO
-- =============================================================================

--- Write a single condition node into `condKey`. Returns true on success,
--- false when the field or codec is unknown, the value is missing, or the
--- comparator is not allowed for this field type (all fail-closed: skip
--- the condition, log a warning; mirrors evaluator's unknown-field policy).
---@param xmlFile table XMLFile handle
---@param condKey string path prefix for this condition
---@param cond table { field, cmp, value }
---@return boolean wrote
local function writeCondition(xmlFile, condKey, cond)
    if cond == nil or cond.field == nil or cond.cmp == nil then
        Log:warning("RLFilterSerialization.writeCondition: malformed condition at %s (field=%s cmp=%s); skipping",
            tostring(condKey), tostring(cond and cond.field), tostring(cond and cond.cmp))
        return false
    end

    local field = RLFilterFieldCatalog.get(cond.field)
    if field == nil then
        Log:warning("RLFilterSerialization.writeCondition: unknown field '%s' at %s; skipping (fail-closed)",
            tostring(cond.field), tostring(condKey))
        return false
    end

    -- Reject unknown / not-allowed comparators at the I/O boundary so a
    -- future deprecated `cmp` does not silently persist into saves.
    if not isCmpAllowed(field, cond.cmp) then
        Log:warning("RLFilterSerialization.writeCondition: cmp '%s' is not in whitelist for field '%s' at %s; skipping",
            tostring(cond.cmp), tostring(cond.field), tostring(condKey))
        return false
    end

    local codec = TYPE_CODECS[field.type]
    if codec == nil then
        Log:warning("RLFilterSerialization.writeCondition: no codec for type '%s' (field %s); skipping",
            tostring(field.type), tostring(cond.field))
        return false
    end

    -- Validate value shape BEFORE emitting any XML.
    -- Previous ordering wrote @field and @cmp first, and only then checked
    -- the value - if the value was malformed, the @field/@cmp attrs were
    -- already on disk. When this happened to the *trailing* condition of
    -- a group, writeGroup's index-reuse only overwrites on a successful
    -- subsequent write - the orphan attrs survived and reloaded as a
    -- `notin []` (matches every animal) or a nil-valued scalar. Validate
    -- first, write nothing if the shape is bad.
    if cond.cmp == "in" or cond.cmp == "notin" then
        if type(cond.value) ~= "table" then
            Log:warning("RLFilterSerialization.writeCondition: cmp=%s expects list value, got %s at %s; skipping (no XML written)",
                cond.cmp, type(cond.value), tostring(condKey))
            return false
        end
    else
        -- Nil scalar value reaching setXMLFloat/Bool/String via the C
        -- binding is unsafe (undefined behavior / crash). Fail-closed here
        -- so one malformed condition can't abort the entire AnimalSystem save.
        if cond.value == nil then
            Log:warning("RLFilterSerialization.writeCondition: scalar cmp='%s' on field '%s' has nil value at %s; skipping (no XML written)",
                tostring(cond.cmp), tostring(cond.field), tostring(condKey))
            return false
        end
    end

    -- All validation passed; safe to emit.
    xmlFile:setString(condKey .. "#field", cond.field)
    xmlFile:setString(condKey .. "#cmp", cond.cmp)

    if cond.cmp == "in" or cond.cmp == "notin" then
        for k, v in ipairs(cond.value) do
            local vKey = string.format("%s.value(%d)", condKey, k - 1)
            codec.write(xmlFile, vKey .. "#value", v)
        end
        Log:trace("RLFilterSerialization.writeCondition: %s field=%s cmp=%s list#=%d",
            condKey, cond.field, cond.cmp, #cond.value)
    else
        codec.write(xmlFile, condKey .. "#value", cond.value)
        Log:trace("RLFilterSerialization.writeCondition: %s field=%s cmp=%s value=%s",
            condKey, cond.field, cond.cmp, tostring(cond.value))
    end

    return true
end

--- Read a single condition from `condKey`. Returns the condition table
--- on success or nil when the field/codec/cmp is unknown (fail-closed).
---@param xmlFile table XMLFile handle
---@param condKey string path prefix for this condition
---@return table|nil condition
local function readCondition(xmlFile, condKey)
    local fieldKey = xmlFile:getString(condKey .. "#field")
    local cmp = xmlFile:getString(condKey .. "#cmp")

    if fieldKey == nil or cmp == nil then
        Log:warning("RLFilterSerialization.readCondition: missing field/cmp at %s (field=%s cmp=%s); skipping",
            tostring(condKey), tostring(fieldKey), tostring(cmp))
        return nil
    end

    local field = RLFilterFieldCatalog.get(fieldKey)
    if field == nil then
        Log:warning("RLFilterSerialization.readCondition: unknown field '%s' at %s; skipping (fail-closed)",
            tostring(fieldKey), tostring(condKey))
        return nil
    end

    -- Reject unknown / not-allowed comparators at the I/O boundary.
    if not isCmpAllowed(field, cmp) then
        Log:warning("RLFilterSerialization.readCondition: cmp '%s' is not in whitelist for field '%s' at %s; skipping",
            tostring(cmp), tostring(fieldKey), tostring(condKey))
        return nil
    end

    local codec = TYPE_CODECS[field.type]
    if codec == nil then
        Log:warning("RLFilterSerialization.readCondition: no codec for type '%s' (field %s); skipping",
            tostring(field.type), tostring(fieldKey))
        return nil
    end

    local cond = { field = fieldKey, cmp = cmp }

    if cmp == "in" or cmp == "notin" then
        local values = {}
        xmlFile:iterate(condKey .. ".value", function(_, vKey)
            local v = codec.read(xmlFile, vKey .. "#value", nil)
            if v ~= nil then table.insert(values, v) end
        end)
        cond.value = values
        Log:trace("RLFilterSerialization.readCondition: %s field=%s cmp=%s list#=%d",
            condKey, fieldKey, cmp, #values)
    else
        cond.value = codec.read(xmlFile, condKey .. "#value", nil)
        Log:trace("RLFilterSerialization.readCondition: %s field=%s cmp=%s value=%s",
            condKey, fieldKey, cmp, tostring(cond.value))
    end

    return cond
end

-- =============================================================================
-- Group (recursive) IO
-- =============================================================================

--- True when a node is shaped like a group. Bare conditions should be
--- wrapped by callers before reaching this point.
---@param node table|nil
---@return boolean
local function isGroup(node)
    return node ~= nil and node.op ~= nil and node.children ~= nil
end

--- Write a group node (recursive).
--- Children are serialized conditions-first then groups, matching the
--- "collapse-ordering" rule: cross-type order is not preserved
--- because AND/OR are commutative/associative.
---@param xmlFile table
---@param groupKey string
---@param group table { op, children }
local function writeGroup(xmlFile, groupKey, group)
    xmlFile:setString(groupKey .. "#op", group.op or "AND")

    local children = group.children or {}
    local condIdx, groupIdx = 0, 0

    -- First pass: conditions. Skipped writes (unknown field/codec) do not
    -- advance condIdx, so the resulting XML has no gaps.
    for _, child in ipairs(children) do
        if not isGroup(child) then
            local childKey = string.format("%s.condition(%d)", groupKey, condIdx)
            if writeCondition(xmlFile, childKey, child) then
                condIdx = condIdx + 1
            end
        end
    end

    -- Second pass: nested groups.
    for _, child in ipairs(children) do
        if isGroup(child) then
            local childKey = string.format("%s.group(%d)", groupKey, groupIdx)
            writeGroup(xmlFile, childKey, child)
            groupIdx = groupIdx + 1
        end
    end

    Log:trace("RLFilterSerialization.writeGroup: %s op=%s conditions=%d groups=%d",
        groupKey, tostring(group.op), condIdx, groupIdx)
end

--- Read a group node (recursive). Children ordering on load is
--- `conditions[] ++ groups[]` per the contract.
---@param xmlFile table
---@param groupKey string
---@return table group { op, children }
local function readGroup(xmlFile, groupKey)
    local op = xmlFile:getString(groupKey .. "#op", "AND")
    local children = {}

    xmlFile:iterate(groupKey .. ".condition", function(_, condKey)
        local c = readCondition(xmlFile, condKey)
        if c ~= nil then table.insert(children, c) end
    end)

    xmlFile:iterate(groupKey .. ".group", function(_, childGroupKey)
        table.insert(children, readGroup(xmlFile, childGroupKey))
    end)

    Log:trace("RLFilterSerialization.readGroup: %s op=%s #children=%d",
        groupKey, op, #children)
    return { op = op, children = children }
end

-- =============================================================================
-- Filter record IO (public)
-- =============================================================================

--- Write one filter record at `filterKey`. Optional scope attributes
--- (`animalType`, `farmId`) are omitted when nil so the XML cleanly
--- reflects "global" / "any type" without sentinel values.
---
--- Callers that supply a bare-condition `expression` (no `op`) are
--- transparently wrapped into a single-child AND group so the XML key
--- contract ("root group, exactly one") is always satisfied. Contract:
--- the write-then-read round-trip yields a structurally equal filter
--- when the expression was already a group; bare-condition inputs come
--- back wrapped, which matches how the service/evaluator see them anyway.
---@param xmlFile table
---@param filterKey string
---@param filter table filter record
function RLFilterSerialization.writeFilter(xmlFile, filterKey, filter)
    xmlFile:setString(filterKey .. "#id", filter.id or "")
    xmlFile:setString(filterKey .. "#name", filter.name or "")

    local typeName = animalTypeIndexToName(filter.animalType)
    if typeName ~= nil then
        xmlFile:setString(filterKey .. "#animalType", typeName)
    end

    if filter.farmId ~= nil then
        xmlFile:setInt(filterKey .. "#farmId", filter.farmId)
    end

    -- usage axis is always written when present in-memory. Service-side
    -- normalisation (create-default + update-coerce) means stored records
    -- carry a canonical string. We still defensively check for nil so a
    -- service-bypass call site (tests, future direct callers) cannot blow
    -- up the writer.
    if filter.usage ~= nil then
        xmlFile:setString(filterKey .. "#usage", filter.usage)
    end

    xmlFile:setInt(filterKey .. "#version", filter.version or 1)

    local expression = filter.expression
    if expression == nil then
        Log:warning("RLFilterSerialization.writeFilter: filter %s has nil expression; writing empty AND group",
            tostring(filter.id))
        expression = { op = "AND", children = {} }
    elseif not isGroup(expression) then
        Log:warning("RLFilterSerialization.writeFilter: filter %s expression is bare condition; wrapping in AND group",
            tostring(filter.id))
        expression = { op = "AND", children = { expression } }
    end

    writeGroup(xmlFile, filterKey .. ".group", expression)

    Log:trace("RLFilterSerialization.writeFilter: %s id=%s name=%s animalType=%s farmId=%s usage=%s version=%s",
        filterKey, tostring(filter.id), tostring(filter.name),
        tostring(typeName), tostring(filter.farmId), tostring(filter.usage), tostring(filter.version))
end

--- Read one filter record from `filterKey`. Returns nil when the record
--- is missing required identity (id) or when the mandatory `.group`
--- subtree is absent: fabricating a match-all filter from
--- a truncated save is worse than skipping the record, because on the
--- next save the empty-AND would be written back and silently persist.
--- Caller is responsible for storing the returned record.
---@param xmlFile table
---@param filterKey string
---@return table|nil filter
function RLFilterSerialization.readFilter(xmlFile, filterKey)
    local id = xmlFile:getString(filterKey .. "#id")
    if id == nil or id == "" then
        Log:warning("RLFilterSerialization.readFilter: missing id at %s; skipping filter",
            tostring(filterKey))
        return nil
    end

    local name = xmlFile:getString(filterKey .. "#name", "")
    local typeName = xmlFile:getString(filterKey .. "#animalType")
    local animalType = animalTypeNameToIndex(typeName)
    local farmId = xmlFile:getInt(filterKey .. "#farmId")
    local version = xmlFile:getInt(filterKey .. "#version", 1)

    -- usage axis: absent attr is the legacy-save case (#4) - silent default
    -- to ANY. Present-but-unknown attr is a corrupt-save or version-skew
    -- case (#14 inbound boundary) - coerce to ANY + WARN via the validator.
    local usageRaw = xmlFile:getString(filterKey .. "#usage")
    local usage
    if usageRaw == nil then
        usage = RLFilterUsage.ANY
    else
        usage = RLFilterUsage.coerce(usageRaw)
    end

    -- A filter without a `.group` subtree is malformed XML (truncated
    -- save, incompatible mod version, etc.). Skip + warn so the corruption
    -- is visible in logs and does not silently persist as a match-all.
    local groupKey = filterKey .. ".group"
    if not xmlFile:hasProperty(groupKey) then
        Log:warning("RLFilterSerialization.readFilter: filter id=%s at %s has no .group subtree; skipping (corrupt save?)",
            tostring(id), tostring(filterKey))
        return nil
    end

    local expression = readGroup(xmlFile, groupKey)

    Log:trace("RLFilterSerialization.readFilter: %s id=%s name=%s animalType=%s farmId=%s usage=%s version=%d",
        filterKey, id, tostring(name), tostring(typeName), tostring(farmId), tostring(usage), version)

    return {
        id = id,
        name = name,
        animalType = animalType,
        farmId = farmId,
        usage = usage,
        expression = expression,
        version = version,
    }
end

Log:trace("RLFilterSerialization: loaded")
