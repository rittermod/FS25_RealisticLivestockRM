-- RLFilterWire.lua
-- Byte-level wire codec shared by the filter MP events.
--
-- Stream layout:
--
--   writeByType(streamId, v, type):
--     number      -> streamWriteFloat32
--     bool        -> streamWriteBool
--     enum/string -> streamWriteString
--
--   writeCondition(streamId, c):
--     streamWriteString c.field
--     streamWriteString c.cmp
--     type = catalog[c.field].type
--     if c.cmp in {"in","notin"}:
--         streamWriteUInt8(#c.value)
--         for each v in c.value: writeByType(streamId, v, type)
--     else:
--         writeByType(streamId, c.value, type)     -- no leading byte
--
--   writeGroup(streamId, g):
--     streamWriteString g.op
--     streamWriteUInt8(#conditions); for each: writeCondition
--     streamWriteUInt8(#groups);     for each: writeGroup   (recursive)
--
--   writeFilter(streamId, f):
--     streamWriteString f.id
--     streamWriteString f.name
--     streamWriteInt32  f.animalType   (-1 for nil, else AnimalType int)
--     streamWriteInt32  f.farmId       (-1 for nil, else farmId)
--     streamWriteUInt16 f.version      (widened from UInt8 to survive long-lived filters)
--     writeGroup(streamId, f.expression)
--
-- Sentinel -1 for an optional int avoids an extra bool per field. A malformed condition is
-- emitted as two empty strings, the empty field being the reader's sentinel.
--
-- FAIL-CLOSED on read: an unknown catalog field warns and returns nil, and the group reader
-- will likely desync from there - accepted, since the receiver then drops the event. An
-- out-of-set cmp warns, DRAINS its elements so the stream stays aligned, and returns nil.

local Log = RmLogging.getLogger("RLRM")

RLFilterWire = {}

-- =============================================================================
-- Type codec (per-catalog-type scalar write/read)
-- =============================================================================

--- Write a single scalar value of the given catalog type to `streamId`.
---@param streamId number
---@param v any
---@param typ string "number" | "bool" | "enum" | "string"
---@return boolean wrote true on success
local function writeByType(streamId, v, typ)
    if typ == "number" then
        streamWriteFloat32(streamId, v)
    elseif typ == "bool" then
        streamWriteBool(streamId, v == true)
    elseif typ == "enum" then
        streamWriteString(streamId, tostring(v))
    elseif typ == "string" then
        streamWriteString(streamId, tostring(v))
    else
        Log:warning("RLFilterWire.writeByType: unknown type '%s' (skipping)", tostring(typ))
        return false
    end
    return true
end

--- Read a single scalar value of the given catalog type from `streamId`.
---@param streamId number
---@param typ string
---@return any value (nil on unknown type)
local function readByType(streamId, typ)
    if typ == "number" then
        return streamReadFloat32(streamId)
    elseif typ == "bool" then
        return streamReadBool(streamId)
    elseif typ == "enum" then
        return streamReadString(streamId)
    elseif typ == "string" then
        return streamReadString(streamId)
    end
    Log:warning("RLFilterWire.readByType: unknown type '%s'", tostring(typ))
    return nil
end

-- =============================================================================
-- Count / cmp helpers
-- =============================================================================

--- Clamp + warn when a count exceeds UInt8 range. Writer-side only: truncating to 255
--- keeps the stream aligned, where an out-of-range streamWriteUInt8 is undefined.
---@param n integer
---@param what string descriptor for log
---@return integer clamped
local function clampU8(n, what)
    if n == nil or n < 0 then
        Log:warning("RLFilterWire.clampU8: negative/nil count for %s; using 0", tostring(what))
        return 0
    end
    if n > 255 then
        Log:warning("RLFilterWire.clampU8: %s count %d exceeds UInt8 (truncating to 255)", tostring(what), n)
        return 255
    end
    return n
end

--- TRACE-log helper: comma-join a list of scalars. `tostring` per element, since
--- `table.concat` raises on a bool or mixed-type list.
---@param list table
---@param n integer number of elements to serialize
---@return string
local function joinValues(list, n)
    local parts = {}
    for i = 1, n do parts[i] = tostring(list[i]) end
    return table.concat(parts, ",")
end

--- True when the cmp token selects a list-valued condition (`in` / `notin`).
--- Used by both writer and reader to frame list vs scalar payloads without
--- a leading wire discriminant.
---@param cmp string
---@return boolean
local function isListCmp(cmp)
    return cmp == "in" or cmp == "notin"
end

--- True when `cmp` appears in `field.cmps` (catalog whitelist). Matches
--- RLFilterSerialization policy so wire + XML fail-closed on the same
--- invariants.
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

--- Write a single condition, trusting the service's pre-dispatch validation. A malformed
--- input writes the two-empty-string sentinel and no payload bytes.
---@param streamId number
---@param cond table { field, cmp, value }
---@return boolean wrote true on success
local function writeCondition(streamId, cond)
    if cond == nil or cond.field == nil or cond.cmp == nil then
        Log:warning("RLFilterWire.writeCondition: malformed condition (field=%s cmp=%s); writing sentinel",
            tostring(cond and cond.field), tostring(cond and cond.cmp))
        streamWriteString(streamId, "")
        streamWriteString(streamId, "")
        return false
    end

    local field = RLFilterFieldCatalog.get(cond.field)
    if field == nil then
        Log:warning("RLFilterWire.writeCondition: unknown field '%s'; writing sentinel",
            tostring(cond.field))
        streamWriteString(streamId, "")
        streamWriteString(streamId, "")
        return false
    end

    if not isCmpAllowed(field, cond.cmp) then
        Log:warning("RLFilterWire.writeCondition: cmp '%s' not in whitelist for field '%s'; writing sentinel",
            tostring(cond.cmp), tostring(cond.field))
        streamWriteString(streamId, "")
        streamWriteString(streamId, "")
        return false
    end

    streamWriteString(streamId, cond.field)
    streamWriteString(streamId, cond.cmp)

    if isListCmp(cond.cmp) then
        local list = cond.value
        if type(list) ~= "table" then
            Log:warning("RLFilterWire.writeCondition: cmp=%s expects table value, got %s (writing empty list)",
                cond.cmp, type(list))
            streamWriteUInt8(streamId, 0)
            return false
        end
        local n = clampU8(#list, string.format("condition '%s' list", cond.field))
        streamWriteUInt8(streamId, n)
        for i = 1, n do
            writeByType(streamId, list[i], field.type)
        end
        Log:trace("RLFilterWire.writeCondition: field=%s cmp=%s list=[%s]",
            cond.field, cond.cmp, joinValues(list, n))
    else
        if cond.value == nil then
            Log:warning("RLFilterWire.writeCondition: nil scalar value on field '%s' cmp='%s'; writing type default",
                cond.field, cond.cmp)
            -- A type default keeps the stream aligned; the service layer already rejects
            -- nil-scalar conditions before dispatch, so this is defence in depth.
            if field.type == "number" then
                streamWriteFloat32(streamId, 0)
            elseif field.type == "bool" then
                streamWriteBool(streamId, false)
            elseif field.type == "enum" then
                streamWriteString(streamId, "")
            elseif field.type == "string" then
                streamWriteString(streamId, "")
            end
            return false
        end
        writeByType(streamId, cond.value, field.type)
        Log:trace("RLFilterWire.writeCondition: field=%s cmp=%s value=%s",
            cond.field, cond.cmp, tostring(cond.value))
    end

    return true
end

--- Read a single condition, or nil on sentinel, unknown field or rejected cmp. A rejected
--- cmp still DRAINS its payload so the surrounding group stream stays aligned.
---@param streamId number
---@return table|nil cond
local function readCondition(streamId)
    local fieldKey = streamReadString(streamId)
    local cmp = streamReadString(streamId)

    if fieldKey == nil or fieldKey == "" or cmp == nil or cmp == "" then
        Log:warning("RLFilterWire.readCondition: sentinel (field='%s' cmp='%s'); skipping",
            tostring(fieldKey), tostring(cmp))
        return nil
    end

    local field = RLFilterFieldCatalog.get(fieldKey)
    if field == nil then
        Log:warning("RLFilterWire.readCondition: unknown field '%s' (catalog drift); stream may desync, dropping condition",
            tostring(fieldKey))
        -- Draining needs field.type to decode the value, so it is impossible here. The group
        -- reader will misinterpret the following bytes and the receiver drops the event.
        return nil
    end

    if not isCmpAllowed(field, cmp) then
        Log:warning("RLFilterWire.readCondition: cmp '%s' not in whitelist for field '%s'; draining payload",
            tostring(cmp), tostring(fieldKey))
        -- Drain based on cmp syntax so the stream stays aligned. Syntactic
        -- cmp check (string literal "in"/"notin") works even when the cmp
        -- itself is rejected by the whitelist -- it's purely a framing hint.
        if isListCmp(cmp) then
            local n = streamReadUInt8(streamId) or 0
            for _ = 1, n do readByType(streamId, field.type) end
        else
            readByType(streamId, field.type)
        end
        return nil
    end

    local cond = { field = fieldKey, cmp = cmp }

    if isListCmp(cmp) then
        local n = streamReadUInt8(streamId) or 0
        local values = {}
        for _ = 1, n do
            local v = readByType(streamId, field.type)
            if v ~= nil then table.insert(values, v) end
        end
        cond.value = values
        Log:trace("RLFilterWire.readCondition: field=%s cmp=%s list=[%s]",
            fieldKey, cmp, joinValues(values, #values))
    else
        cond.value = readByType(streamId, field.type)
        Log:trace("RLFilterWire.readCondition: field=%s cmp=%s value=%s",
            fieldKey, cmp, tostring(cond.value))
    end

    return cond
end

-- =============================================================================
-- Group (recursive) IO
-- =============================================================================

local function isGroup(node)
    return node ~= nil and node.op ~= nil and node.children ~= nil
end

--- Partition children into (conditions, groups) lists preserving input order
--- within each bucket. Matches the on-reload ordering convention.
---@param children table
---@return table conditions, table groups
local function partitionChildren(children)
    local conditions, groups = {}, {}
    for _, c in ipairs(children or {}) do
        if isGroup(c) then
            table.insert(groups, c)
        else
            table.insert(conditions, c)
        end
    end
    return conditions, groups
end

--- Write a group (recursive). op + UInt8 conds + conditions + UInt8 groups + groups.
---@param streamId number
---@param group table { op, children }
local function writeGroup(streamId, group)
    streamWriteString(streamId, group.op or "AND")

    local conditions, groups = partitionChildren(group.children)

    local nc = clampU8(#conditions, "group conditions")
    streamWriteUInt8(streamId, nc)
    for i = 1, nc do
        writeCondition(streamId, conditions[i])
    end

    local ng = clampU8(#groups, "group subgroups")
    streamWriteUInt8(streamId, ng)
    for i = 1, ng do
        writeGroup(streamId, groups[i])
    end

    Log:trace("RLFilterWire.writeGroup: op=%s conditions=%d groups=%d",
        tostring(group.op), nc, ng)
end

--- Read a group (recursive). Children order on the wire is
--- `conditions[] ++ groups[]` per the contract.
---@param streamId number
---@return table group { op, children }
local function readGroup(streamId)
    local op = streamReadString(streamId)
    local children = {}

    local nc = streamReadUInt8(streamId) or 0
    for _ = 1, nc do
        local c = readCondition(streamId)
        if c ~= nil then table.insert(children, c) end
    end

    local ng = streamReadUInt8(streamId) or 0
    for _ = 1, ng do
        table.insert(children, readGroup(streamId))
    end

    Log:trace("RLFilterWire.readGroup: op=%s #children=%d (nc=%d ng=%d)",
        tostring(op), #children, nc, ng)
    return { op = op, children = children }
end

-- =============================================================================
-- Filter record IO (public)
-- =============================================================================

--- Sentinel used in place of nil for optional animalType / farmId on the wire.
RLFilterWire.NIL_INT_SENTINEL = -1

--- Write a whole filter record. Optional scope ints use -1 as the nil sentinel.
--- A bare-condition `expression` is wrapped in a single-child AND group so the
--- wire always carries exactly one root group.
---@param streamId number
---@param filter table
function RLFilterWire.writeFilter(streamId, filter)
    streamWriteString(streamId, filter.id or "")
    streamWriteString(streamId, filter.name or "")

    local atype = filter.animalType
    streamWriteInt32(streamId, atype ~= nil and atype or RLFilterWire.NIL_INT_SENTINEL)

    local fid = filter.farmId
    streamWriteInt32(streamId, fid ~= nil and fid or RLFilterWire.NIL_INT_SENTINEL)

    -- UInt16 version: UInt8 saturates at 255, unusable ceiling for long-lived
    -- filters if a future cycle ever bumps the version.
    streamWriteUInt16(streamId, filter.version or 1)

    -- 1-byte usage scope axis. The `or 0` fallback defends against an un-normalised in-memory
    -- filter, which service create/update and the serializer should already have coerced;
    -- defaulting to ANY keeps the receiver's decode safe if a caller ever bypasses that.
    streamWriteUInt8(streamId, RLFilterUsage.BYTE[filter.usage] or 0)

    local expression = filter.expression
    if expression == nil then
        Log:warning("RLFilterWire.writeFilter: filter %s has nil expression; writing empty AND group",
            tostring(filter.id))
        expression = { op = "AND", children = {} }
    elseif not isGroup(expression) then
        Log:warning("RLFilterWire.writeFilter: filter %s expression is bare condition; wrapping in AND group",
            tostring(filter.id))
        expression = { op = "AND", children = { expression } }
    end

    writeGroup(streamId, expression)

    Log:trace("RLFilterWire.writeFilter: id=%s name=%s animalType=%s farmId=%s usage=%s version=%s",
        tostring(filter.id), tostring(filter.name),
        tostring(atype), tostring(fid), tostring(filter.usage), tostring(filter.version))
end

--- Read a whole filter record. Returns the reconstructed filter table. On
--- a malformed stream, the caller (event `run()`) should validate the
--- result before applying (e.g. id non-empty).
---@param streamId number
---@return table filter
function RLFilterWire.readFilter(streamId)
    local id = streamReadString(streamId)
    local name = streamReadString(streamId)

    local atype = streamReadInt32(streamId)
    if atype == RLFilterWire.NIL_INT_SENTINEL then atype = nil end

    local fid = streamReadInt32(streamId)
    if fid == RLFilterWire.NIL_INT_SENTINEL then fid = nil end

    local version = streamReadUInt16(streamId)

    -- Known usage bytes decode via FROM_BYTE; a reserved byte coerces to ANY with a warning.
    -- The canonical string lands in the returned table, so `service:applyIncoming*` callers
    -- see a pre-normalised value.
    local usageByte = streamReadUInt8(streamId)
    local usage = RLFilterUsage.FROM_BYTE[usageByte]
    if usage == nil then
        Log:warning("RLFilterWire.readFilter: unknown usage byte %d coerced to ANY", usageByte)
        usage = RLFilterUsage.ANY
    end

    local expression = readGroup(streamId)

    Log:trace("RLFilterWire.readFilter: id=%s name=%s animalType=%s farmId=%s usage=%s version=%s",
        tostring(id), tostring(name), tostring(atype), tostring(fid), tostring(usage), tostring(version))

    return {
        id = id,
        name = name,
        animalType = atype,
        farmId = fid,
        usage = usage,
        expression = expression,
        version = version,
    }
end

Log:trace("RLFilterWire: loaded")
