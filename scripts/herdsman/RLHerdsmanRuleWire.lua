-- RLHerdsmanRuleWire.lua
-- Byte-level wire codec shared by the Herdsman rule MP events (M-Service S3).
--
-- Stream layout (writeRule):
--   streamWriteString  rule.id
--   streamWriteString  rule.name
--   streamWriteString  rule.operation       -- read FIRST -> drives filterId + params
--   [non-naming only]  streamWriteString rule.filterId   -- OMITTED for naming
--   streamWriteInt32   rule.farmId          -- -1 nil sentinel (always set on a valid rule)
--   streamWriteUInt16  rule.version
--   streamWriteBool    rule.enabled
--   targetHusbandries: streamWriteUInt16 count, then NetworkUtil.writeNodeObject per target
--   params:            PARAMS_WIRE_CODECS[operation].write   (skipped + :warning on unknown op)
--
-- filterId is operation-gated, NOT sentinelled: a non-naming rule always carries a
-- non-empty filterId (the S1 validity floor guarantees it), naming never does. The
-- operation token already on the wire tells the reader whether to expect the field,
-- so a persisted "" (a legal non-naming state) round-trips verbatim instead of being
-- corrupted by a ""-means-nil sentinel.
--
-- targetHusbandries is a node-object list, not a uniqueId-string list. The engine
-- maintains a stable cross-machine node id per placeable, so each target resolves
-- string -> live placeable on write (g_currentMission.placeableSystem) and back to
-- string on read (placeable:getUniqueId). A uniqueId that does not resolve to a live
-- placeable on write is skipped (the count reflects only what is written, so the
-- stream stays aligned); a node-object that does not resolve on read is skipped
-- likewise. Both emit :warning. This is the one field that can transiently diverge on
-- the create hop -- bounded, and reconciled by the later state-sync slice.
--
-- The operation token precedes the params block, so writer and reader take the
-- identical "is there a codec for this operation?" branch: an unknown operation
-- round-trips its scalars with empty params and stays byte-aligned, then the service
-- floor rejects it downstream. No mid-record bail (which would desync the stream).

local Log = RmLogging.getLogger("RLRM")

RLHerdsmanRuleWire = {}

--- Sentinel written in place of nil for the optional farmId int (a real farmId is
--- always a positive id, so -1 is unambiguous). Kept for symmetry with the filter
--- wire and as defence against an un-floored record reaching the codec.
RLHerdsmanRuleWire.NIL_INT_SENTINEL = -1

-- =============================================================================
-- Per-operation params codecs
-- =============================================================================

--- Per-operation params write/read functions, keyed by a rule's `operation`. The
--- key set IS the operation whitelist: a rule whose operation has no codec writes
--- (and reads) no params bytes, so the record stays byte-aligned and the service
--- floor rejects the unknown operation downstream.
---
--- Field types match the persisted XML shape (the rule's stored `params` table):
---   sell      -> maxAnimals Int32, mark Bool
---   buy       -> maxAnimals Int32; budget.type String, budget.fixed Int32, budget.percentage Float32
---   castrate  -> mark Bool
---   naming    -> convention String, previous String ("" sentinel for nil cursor)
---   ai        -> maxAnimals Int32, mark Bool, semen String
---
--- The codec is a transport, not a validator: it round-trips type-correct values
--- verbatim. Per-operation VALUE validation is the picker / M-Frame's job; the
--- service floor + the receiver's `applyIncomingCreate` enforce the invariants.
---@type table<string, { write: fun(streamId:number, params:table), read: fun(streamId:number):table }>
local PARAMS_WIRE_CODECS = {
    sell = {
        write = function(streamId, p)
            streamWriteInt32(streamId, p.maxAnimals)
            streamWriteBool(streamId, p.mark == true)
        end,
        read = function(streamId)
            local maxAnimals = streamReadInt32(streamId)
            local mark = streamReadBool(streamId)
            return { maxAnimals = maxAnimals, mark = mark }
        end,
    },
    buy = {
        write = function(streamId, p)
            local budget = p.budget or {}
            streamWriteInt32(streamId, p.maxAnimals)
            streamWriteString(streamId, budget.type or "")
            streamWriteInt32(streamId, budget.fixed)
            streamWriteFloat32(streamId, budget.percentage)
        end,
        read = function(streamId)
            local maxAnimals = streamReadInt32(streamId)
            local budgetType = streamReadString(streamId)
            local fixed = streamReadInt32(streamId)
            local percentage = streamReadFloat32(streamId)
            return {
                maxAnimals = maxAnimals,
                budget = { type = budgetType, fixed = fixed, percentage = percentage },
            }
        end,
    },
    castrate = {
        write = function(streamId, p)
            streamWriteBool(streamId, p.mark == true)
        end,
        read = function(streamId)
            local mark = streamReadBool(streamId)
            return { mark = mark }
        end,
    },
    naming = {
        write = function(streamId, p)
            streamWriteString(streamId, p.convention or "")
            -- previous is optional (the alphabetical cursor). The wire has no field
            -- omission, so an absent/nil cursor goes as "" and reads back to a missing
            -- key -- the alphabetical sequence then restarts at "A".
            streamWriteString(streamId, p.previous or "")
        end,
        read = function(streamId)
            local convention = streamReadString(streamId)
            local previous = streamReadString(streamId)
            local params = { convention = convention }
            if previous ~= "" then params.previous = previous end
            return params
        end,
    },
    ai = {
        write = function(streamId, p)
            streamWriteInt32(streamId, p.maxAnimals)
            streamWriteBool(streamId, p.mark == true)
            streamWriteString(streamId, p.semen or "")
        end,
        read = function(streamId)
            local maxAnimals = streamReadInt32(streamId)
            local mark = streamReadBool(streamId)
            local semen = streamReadString(streamId)
            return { maxAnimals = maxAnimals, mark = mark, semen = semen }
        end,
    },
}

--- Exposed read-only for tests that want to assert the canonical operation
--- whitelist without reaching into the service.
RLHerdsmanRuleWire._PARAMS_WIRE_CODECS = PARAMS_WIRE_CODECS

-- =============================================================================
-- targetHusbandries node-object list IO
-- =============================================================================

--- Write the rule's target husbandries as a UInt16 count followed by one
--- node-object per resolvable target. Each stored uniqueId is resolved to a live
--- placeable via the placeable system; a uniqueId with no live placeable is skipped
--- with a `:warning` and the count reflects only what is written, so the read side
--- stays byte-aligned.
---@param streamId number
---@param targets string[] stored target uniqueId strings (dense array)
---@param ruleId any rule id, for log context only
local function writeTargets(streamId, targets, ruleId)
    local placeableSystem = g_currentMission ~= nil and g_currentMission.placeableSystem or nil

    local resolved = {}
    if type(targets) == "table" then
        for _, uniqueId in ipairs(targets) do
            local placeable = placeableSystem ~= nil and placeableSystem:getPlaceableByUniqueId(uniqueId) or nil
            if placeable ~= nil then
                resolved[#resolved + 1] = placeable
            else
                Log:warning("RLHerdsmanRuleWire.writeTargets: rule id=%s target uniqueId '%s' does not resolve to a live placeable; skipping (count excludes it)",
                    tostring(ruleId), tostring(uniqueId))
            end
        end
    end

    streamWriteUInt16(streamId, #resolved)
    for _, placeable in ipairs(resolved) do
        NetworkUtil.writeNodeObject(streamId, placeable)
    end

    Log:trace("RLHerdsmanRuleWire.writeTargets: rule id=%s wrote %d/%d targets",
        tostring(ruleId), #resolved, type(targets) == "table" and #targets or 0)
end

--- Read the target husbandries: a UInt16 count, then one node-object per entry,
--- each mapped back to its uniqueId. A node-object that does not resolve to a live
--- placeable on this machine (or whose uniqueId is nil) is skipped with a `:warning`;
--- `readNodeObject` always consumes its fixed-width id, so the stream stays aligned
--- regardless. Order is preserved.
---@param streamId number
---@param ruleId any rule id, for log context only
---@return string[] targets resolved uniqueId strings in wire order
local function readTargets(streamId, ruleId)
    local count = streamReadUInt16(streamId)
    local targets = {}
    for i = 1, count do
        local placeable = NetworkUtil.readNodeObject(streamId)
        if placeable == nil then
            Log:warning("RLHerdsmanRuleWire.readTargets: rule id=%s target %d/%d did not resolve to a live placeable on read; skipping (bounded, state-sync reconciled)",
                tostring(ruleId), i, count)
        else
            local uniqueId = placeable:getUniqueId()
            if uniqueId == nil or uniqueId == "" then
                Log:warning("RLHerdsmanRuleWire.readTargets: rule id=%s target %d/%d resolved a placeable with nil/empty uniqueId; skipping",
                    tostring(ruleId), i, count)
            else
                targets[#targets + 1] = uniqueId
            end
        end
    end

    Log:trace("RLHerdsmanRuleWire.readTargets: rule id=%s read %d/%d targets",
        tostring(ruleId), #targets, count)
    return targets
end

-- =============================================================================
-- Rule record IO (public)
-- =============================================================================

--- Write a whole flat rule record to `streamId`. Field order is fixed so the read
--- side can mirror it byte-for-byte; `operation` precedes `filterId` and `params`
--- because both branch on it. `filterId` is omitted for naming rules. An unknown
--- operation writes no params bytes (the reader skips the same block), keeping the
--- stream aligned for the downstream floor to reject.
---@param streamId number
---@param rule table rule record (id/name/operation/filterId/farmId/version/enabled/targetHusbandries/params)
function RLHerdsmanRuleWire.writeRule(streamId, rule)
    local operation = rule.operation or ""

    streamWriteString(streamId, rule.id or "")
    streamWriteString(streamId, rule.name or "")
    streamWriteString(streamId, operation)

    -- filterId is operation-gated: present (non-empty, per S1 floor) for every
    -- non-naming operation, omitted entirely for naming.
    if operation ~= "naming" then
        streamWriteString(streamId, rule.filterId or "")
    end

    local farmId = rule.farmId
    streamWriteInt32(streamId, farmId ~= nil and farmId or RLHerdsmanRuleWire.NIL_INT_SENTINEL)
    streamWriteUInt16(streamId, rule.version or 1)
    streamWriteBool(streamId, rule.enabled == true)

    writeTargets(streamId, rule.targetHusbandries, rule.id)

    local codec = PARAMS_WIRE_CODECS[operation]
    if codec ~= nil then
        codec.write(streamId, rule.params or {})
    else
        Log:warning("RLHerdsmanRuleWire.writeRule: rule id=%s has unknown operation '%s'; no params written (record stays aligned, floor rejects on apply)",
            tostring(rule.id), tostring(operation))
    end

    Log:trace("RLHerdsmanRuleWire.writeRule: id=%s name=%s operation=%s farmId=%s version=%s enabled=%s filterId=%s",
        tostring(rule.id), tostring(rule.name), tostring(operation),
        tostring(farmId), tostring(rule.version), tostring(rule.enabled), tostring(rule.filterId))
end

--- Read a whole flat rule record from `streamId`, mirroring `writeRule`'s field
--- order. `operation` is read before `filterId`/`params` so it can drive both
--- branches. The reconstructed record is returned as-is; the caller (event `run()`
--- -> `applyIncomingCreate`) re-validates it against the S1 floor before storing.
---@param streamId number
---@return table rule reconstructed rule record
function RLHerdsmanRuleWire.readRule(streamId)
    local id = streamReadString(streamId)
    local name = streamReadString(streamId)
    local operation = streamReadString(streamId)

    -- filterId mirrors the write-side gate: naming carries none (reads back nil),
    -- every other operation reads the string verbatim ("" stays "", never coerced).
    local filterId = nil
    if operation ~= "naming" then
        filterId = streamReadString(streamId)
    end

    local farmId = streamReadInt32(streamId)
    if farmId == RLHerdsmanRuleWire.NIL_INT_SENTINEL then farmId = nil end
    local version = streamReadUInt16(streamId)
    local enabled = streamReadBool(streamId)

    local targetHusbandries = readTargets(streamId, id)

    local params
    local codec = PARAMS_WIRE_CODECS[operation]
    if codec ~= nil then
        params = codec.read(streamId)
    else
        params = {}
        Log:warning("RLHerdsmanRuleWire.readRule: id=%s has unknown operation '%s'; no params read (record stays aligned, floor rejects on apply)",
            tostring(id), tostring(operation))
    end

    Log:trace("RLHerdsmanRuleWire.readRule: id=%s name=%s operation=%s farmId=%s version=%s enabled=%s filterId=%s targets=%d",
        tostring(id), tostring(name), tostring(operation),
        tostring(farmId), tostring(version), tostring(enabled), tostring(filterId), #targetHusbandries)

    return {
        id = id,
        name = name,
        operation = operation,
        filterId = filterId,
        farmId = farmId,
        version = version,
        enabled = enabled,
        targetHusbandries = targetHusbandries,
        params = params,
    }
end

Log:trace("RLHerdsmanRuleWire: loaded")
