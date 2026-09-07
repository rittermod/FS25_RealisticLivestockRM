-- RLHerdsmanRuleWire.lua
-- Byte-level wire codec shared by the Herdsman rule MP events.
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
-- The operation token precedes the params block, so writer and reader take the identical "is there
-- a codec for this operation?" branch: an unknown operation round-trips its scalars with empty
-- params and stays byte-aligned, then the service floor rejects it. There is no mid-record bail,
-- which would desync the stream.
--
-- filterId carries nil as "": writeRule emits `rule.filterId or ""` and readRule coerces exactly
-- "" -> nil. The floor blocks an empty/whitespace filterId from ever being created, so "" on the
-- wire is unambiguously a nil draft, and whitespace stays verbatim for the floor to reject.
--
-- targetHusbandries travel as node-objects, NEVER as a string list - the node-object id is the only
-- placeable handle stable across machines, while the STORED key is context-dependent
-- (@see RLHusbandryTargetKey). An unresolvable key on write or an unkeyable placeable on read is
-- skipped with a warning and the count reflects only what is written, so the stream stays aligned.
-- This is the one field that can transiently diverge - bounded, reconciled by the later state-sync.

local Log = RmLogging.getLogger("RLRM")

RLHerdsmanRuleWire = {}

--- Sentinel written in place of nil for the optional farmId int; a real farmId is always positive,
--- so -1 is unambiguous.
RLHerdsmanRuleWire.NIL_INT_SENTINEL = -1

-- =============================================================================
-- Per-operation params codecs
-- =============================================================================

--- Per-operation params write/read functions, keyed by a rule's `operation`. The key set IS the
--- operation whitelist: an operation with no codec writes and reads no params bytes, so the record
--- stays byte-aligned and the service floor rejects it downstream.
---
--- Field types (`move` DIVERGES from the persisted XML shape - see its own note):
---   sell      -> maxAnimals Int32, mark Bool
---   move      -> maxAnimals Int32, mark Bool, hasDest Bool, then (only when hasDest) one dest node-object
---   buy       -> maxAnimals Int32; budget.type String, budget.fixed Int32, budget.percentage Float32
---   castrate  -> mark Bool
---   naming    -> convention String, previous String ("" sentinel for nil cursor)
---   ai        -> maxAnimals Int32, mark Bool, semen String
---   horseCare -> (no fields; zero bytes both ways)
---
--- The codec is a transport, not a validator: it round-trips type-correct values verbatim, and
--- value validation belongs to the picker and the service floor. ONE exception: `move`'s `read`
--- returns nil for a present-but-unreconstructable destination, which makes `readRule` return nil
--- so the whole record is dropped fail-closed rather than silently stripped to a mark-only draft.
---@type table<string, { write: fun(streamId:number, params:table), read: fun(streamId:number):table|nil }>
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
    move = {
        -- maxAnimals leads the params block as a fixed-width Int32, so it is always consumed before
        -- the optional dest and the record stays byte-aligned even when a fail-closed dest drops it.
        write = function(streamId, p)
            streamWriteInt32(streamId, p.maxAnimals)
            streamWriteBool(streamId, p.mark == true)
            -- hasDest is the INTENT (`~= nil`), deliberately not a non-whitespace test: a
            -- present-but-empty dest still sets hasDest and (not resolving) writes a null node-id so
            -- the receiver drops the record, while a nil dest round-trips as an inert draft.
            local hasDest = p.destinationHusbandry ~= nil
            streamWriteBool(streamId, hasDest)
            if hasDest then
                -- Move-DESTINATION site: the EPP-admitting opt-in, not the husbandry-only `resolve`
                -- the targets leg uses, or a butcher dest would fail-close on a pure client.
                local placeable = RLHusbandryTargetKey.resolveDestination(p.destinationHusbandry)
                if placeable ~= nil then
                    NetworkUtil.writeNodeObject(streamId, placeable)
                    Log:trace("RLHerdsmanRuleWire move.write: maxAnimals=%s dest key '%s' -> node-object",
                        tostring(p.maxAnimals), tostring(p.destinationHusbandry))
                else
                    -- A single-record event cannot skip mid-stream without desync, so write a null
                    -- node-id (0); the receiver reads getObject(0)==nil and drops the record.
                    NetworkUtil.writeNodeObjectId(streamId, 0)
                    Log:warning("RLHerdsmanRuleWire move.write: dest key '%s' does not resolve to a live placeable; writing a null node-id (receiver fail-closes the record)",
                        tostring(p.destinationHusbandry))
                end
            end
        end,
        read = function(streamId)
            local maxAnimals = streamReadInt32(streamId)
            local mark = streamReadBool(streamId)
            local hasDest = streamReadBool(streamId)
            if not hasDest then
                return { maxAnimals = maxAnimals, mark = mark }
            end
            -- Consume the fixed-width node-id BEFORE evaluating validity, so the stream stays
            -- byte-aligned even when the record is dropped.
            local placeable = NetworkUtil.readNodeObject(streamId)
            if placeable == nil then
                Log:warning("RLHerdsmanRuleWire move.read: dest node-object did not resolve to a live placeable on this peer; dropping the record (fail-closed)")
                return nil
            end
            local key = RLHusbandryTargetKey.keyFor(placeable)
            if key == nil then
                Log:warning("RLHerdsmanRuleWire move.read: dest placeable is unkeyable on this peer (keyFor nil); dropping the record (fail-closed)")
                return nil
            end
            Log:trace("RLHerdsmanRuleWire move.read: maxAnimals=%s dest reconstructed to key '%s'", tostring(maxAnimals), tostring(key))
            return { maxAnimals = maxAnimals, mark = mark, destinationHusbandry = key }
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
            -- The wire has no field omission, so an absent alphabetical cursor goes as "" and reads
            -- back to a missing key - the sequence then restarts at "A".
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
    horseCare = {
        -- ZERO params, symmetric on both ends. `read` returns an EMPTY table and never nil: nil is
        -- the fail-closed "drop the whole record" signal, which a param-free operation can never
        -- mean. The entry cannot be inferred from a passing round trip - the unknown-operation
        -- branch also writes zero bytes and yields `params = {}` - so its presence is asserted.
        write = function(_streamId, _p) end,
        read = function(_streamId) return {} end,
    },
}

--- Exposed read-only for tests that assert the canonical operation whitelist.
RLHerdsmanRuleWire._PARAMS_WIRE_CODECS = PARAMS_WIRE_CODECS

-- =============================================================================
-- targetHusbandries node-object list IO
-- =============================================================================

--- Write the rule's target husbandries as a UInt16 count followed by one node-object per resolvable
--- target. A key with no live placeable is skipped with a warning, and the count reflects only what
--- is written, so the read side stays byte-aligned.
---@param streamId number
---@param targets string[] stored target key strings (dense array)
---@param ruleId any rule id, for log context only
local function writeTargets(streamId, targets, ruleId)
    local resolved = {}
    if type(targets) == "table" then
        for _, key in ipairs(targets) do
            local placeable = RLHusbandryTargetKey.resolve(key)
            if placeable ~= nil then
                resolved[#resolved + 1] = placeable
            else
                -- On a client this is the bounded residual: a barn deleted between a join-time
                -- decode and this re-send narrows the set, and the server replaces with the narrowed
                -- set. Loud and bounded, never silent.
                Log:warning("RLHerdsmanRuleWire.writeTargets: rule id=%s target key '%s' does not resolve to a live husbandry placeable; dropping it from the flushed set (count excludes it; bounded residual)",
                    tostring(ruleId), tostring(key))
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

--- Read the target husbandries: a UInt16 count, then one node-object per entry mapped back to its
--- context key. An unresolvable node-object or an unkeyable placeable is skipped; `readNodeObject`
--- always consumes its fixed-width id, so the stream stays aligned. Order is preserved.
---@param streamId number
---@param ruleId any rule id, for log context only
---@return string[] targets resolved target key strings in wire order
local function readTargets(streamId, ruleId)
    local count = streamReadUInt16(streamId)
    local targets = {}
    for i = 1, count do
        local placeable = NetworkUtil.readNodeObject(streamId)
        if placeable == nil then
            Log:warning("RLHerdsmanRuleWire.readTargets: rule id=%s target %d/%d did not resolve to a live placeable on read; skipping (bounded, state-sync reconciled)",
                tostring(ruleId), i, count)
        else
            local key = RLHusbandryTargetKey.keyFor(placeable)
            if key ~= nil then
                targets[#targets + 1] = key
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

--- Write a whole flat rule record to `streamId`, in the fixed field order the read side mirrors.
---@param streamId number
---@param rule table rule record (id/name/operation/filterId/farmId/version/enabled/targetHusbandries/params)
function RLHerdsmanRuleWire.writeRule(streamId, rule)
    local operation = rule.operation or ""

    streamWriteString(streamId, rule.id or "")
    streamWriteString(streamId, rule.name or "")
    streamWriteString(streamId, operation)

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

--- Read a whole flat rule record from `streamId`, mirroring `writeRule`'s field order. The record is
--- returned as-is; the caller re-validates it against the service floor before storing. Returns nil
--- - a fail-closed drop - when a PRESENT params codec's `read` returns nil; the three receivers cope
--- (Create/Update `run()` guard `rule == nil`, State `run()` warn-skips a nil hole).
---@param streamId number
---@return table|nil rule reconstructed rule record, or nil when a present codec fail-closes
function RLHerdsmanRuleWire.readRule(streamId)
    local id = streamReadString(streamId)
    local name = streamReadString(streamId)
    local operation = streamReadString(streamId)

    -- Mirrors the write-side gate: naming carries no filterId, every other operation reads the
    -- string and coerces exactly "" -> nil. Whitespace is left verbatim so a crafted "  " is
    -- rejected by the receiver floor rather than silently normalized to a valid nil.
    local filterId = nil
    if operation ~= "naming" then
        filterId = streamReadString(streamId)
        if filterId == "" then filterId = nil end
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
        if params == nil then
            -- The codec has already consumed its fixed-width bytes, so the stream stays aligned for
            -- any following record.
            Log:warning("RLHerdsmanRuleWire.readRule: id=%s operation=%s codec read returned nil; dropping the whole record (fail-closed)",
                tostring(id), tostring(operation))
            return nil
        end
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
