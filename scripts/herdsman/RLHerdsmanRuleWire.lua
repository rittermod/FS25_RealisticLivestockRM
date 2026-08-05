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
-- params fail-closed (move only): the move codec's `read` returns nil for a present-but-
-- unreconstructable destination, which makes readRule return nil so the receiver DROPS the whole
-- record. The codec always consumes its fixed-width bytes (two bools + the 24-bit node-id) before
-- the nil return, so a multi-record stream stays byte-aligned across the dropped record. The three
-- receivers already cope: Create/Update run() guard `rule == nil`, State run() warn-skips a nil hole.
--
-- filterId is operation-gated AND carries nil via a "" -> nil coercion: a non-naming rule
-- may be an unfiltered draft (filterId nil) or carry a non-empty (non-whitespace) filterId;
-- naming never carries one. The operation token already on the wire tells the reader whether
-- to expect the field. writeRule emits `rule.filterId or ""`, so a genuine nil goes as "" and
-- readRule coerces exactly "" -> nil; a present filterId round-trips verbatim. The floor blocks
-- an empty/whitespace filterId from ever being created, so "" on the wire is unambiguously a
-- nil draft, and a crafted whitespace token stays verbatim for the receiver floor to reject.
--
-- targetHusbandries travels as a node-object list (NetworkUtil.write/readNodeObject), NEVER as a
-- string list - the node-object id is the only placeable handle stable across machines. The STORED
-- string key is context-dependent (RLHusbandryTargetKey): server/host/dedi key by the persisted
-- uniqueId, a pure client by the net-object-id - because getUniqueId() is a savegame identifier the
-- engine streams to a client ONLY for preplaced barns; a player-bought barn streams none, so a
-- uniqueId-keyed target can never match on a client. writeTargets maps key -> live placeable
-- (RLHusbandryTargetKey.resolve), readTargets maps the decoded placeable -> key
-- (RLHusbandryTargetKey.keyFor). An unresolvable key on write / an unkeyable placeable on read is
-- skipped (the count reflects only what is written, so the stream stays aligned), both with a
-- :warning. This is the one field that can transiently diverge - bounded, reconciled by the later
-- state-sync.
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
--- Field types (the wire shape of the rule's `params` table; `move` DIVERGES from the
--- persisted XML shape - see the note below):
---   sell      -> maxAnimals Int32, mark Bool
---   move      -> maxAnimals Int32, mark Bool, hasDest Bool, then (only when hasDest) one dest node-object
---   buy       -> maxAnimals Int32; budget.type String, budget.fixed Int32, budget.percentage Float32
---   castrate  -> mark Bool
---   naming    -> convention String, previous String ("" sentinel for nil cursor)
---   ai        -> maxAnimals Int32, mark Bool, semen String
---   horseCare -> (no fields; zero bytes both ways)
---
--- The codec is a transport, not a validator: it round-trips type-correct values
--- verbatim. Per-operation VALUE validation is the picker / M-Frame's job; the
--- service floor + the receiver's `applyIncomingCreate` enforce the invariants.
---
--- ONE exception: `move`'s `read` returns nil for a present-but-unreconstructable destination
--- (a node-object that does not resolve, or a resolved-but-unkeyable placeable), which makes
--- `readRule` return nil so the WHOLE record is dropped fail-closed - the destination is never
--- silently stripped to a mark-only draft. The dest travels as a node-object re-keyed per machine
--- (RLHusbandryTargetKey: server uniqueId / pure-client net-object-id), where the XML stores a
--- verbatim string - the two codecs share a semantic contract, not a byte representation.
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
        -- `maxAnimals` (the planner's per-move cap) is a required Int; `mark` is a required bool;
        -- `destinationHusbandry` is optional. maxAnimals leads the params block (a fixed-width
        -- Int32) so it is always consumed before the optional dest, keeping the record byte-aligned
        -- even when a fail-closed dest drops it. The dest travels as a node-object re-keyed per
        -- machine via RLHusbandryTargetKey (the only placeable handle stable across machines for a
        -- bought barn), NOT a raw string. A present dest that cannot be reconstructed on the
        -- receiver fail-CLOSES the whole record (read -> nil -> readRule -> nil -> the record is
        -- dropped): the destination must never silently strip to a mark-only draft.
        write = function(streamId, p)
            streamWriteInt32(streamId, p.maxAnimals)
            streamWriteBool(streamId, p.mark == true)
            -- hasDest is the INTENT (`~= nil`), deliberately NOT a non-whitespace test: a present-
            -- but-empty/whitespace/non-string dest still sets hasDest=true and (not resolving)
            -- writes a null node-id so the receiver drops the record; a nil dest writes only the
            -- Int + two bools (an inert draft that round-trips).
            local hasDest = p.destinationHusbandry ~= nil
            streamWriteBool(streamId, hasDest)
            if hasDest then
                -- Move-DESTINATION site: resolve via the EPP-admitting opt-in (resolveDestination),
                -- NOT the husbandry-only `resolve` the targets leg uses. A butcher (EPP)
                -- dest must resolve on a pure client too, or a client editing the rule would fail-close
                -- the record; the targets read/write legs keep `resolve`/`keyFor` unchanged.
                local placeable = RLHusbandryTargetKey.resolveDestination(p.destinationHusbandry)
                if placeable ~= nil then
                    NetworkUtil.writeNodeObject(streamId, placeable)
                    Log:trace("RLHerdsmanRuleWire move.write: maxAnimals=%s dest key '%s' -> node-object",
                        tostring(p.maxAnimals), tostring(p.destinationHusbandry))
                else
                    -- Fail-closed on write: a present dest whose key does not resolve writes a null
                    -- node-id (id 0). A single-record event cannot skip mid-stream without desync,
                    -- so the receiver reads getObject(0)==nil and drops the whole record.
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
            -- Consume the fixed-width node-id BEFORE evaluating validity so the stream stays
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
    horseCare = {
        -- ZERO params: consumes and produces no bytes, symmetric on both ends. `read` returns
        -- an EMPTY table and never nil - a nil is the fail-closed "drop the whole record"
        -- signal (the move destination's contract), which a param-free operation can never mean.
        --
        -- The entry cannot be inferred from a passing round trip: the unknown-operation branch
        -- below ALSO writes zero bytes and ALSO yields `params = {}`, so removing this entry
        -- changes only a warning line. Its presence is asserted directly instead.
        write = function(_streamId, _p) end,
        read = function(_streamId) return {} end,
    },
}

--- Exposed read-only for tests that want to assert the canonical operation
--- whitelist without reaching into the service.
RLHerdsmanRuleWire._PARAMS_WIRE_CODECS = PARAMS_WIRE_CODECS

-- =============================================================================
-- targetHusbandries node-object list IO
-- =============================================================================

--- Write the rule's target husbandries as a UInt16 count followed by one node-object per resolvable
--- target. Each stored key (uniqueId on server, net-object-id on a pure client) is resolved to a
--- live husbandry placeable via RLHusbandryTargetKey.resolve; a key with no live placeable is
--- skipped with a `:warning` and the count reflects only what is written, so the read side stays
--- byte-aligned.
---@param streamId number
---@param targets string[] stored target key strings (uniqueId server / net-object-id client; dense array)
---@param ruleId any rule id, for log context only
local function writeTargets(streamId, targets, ruleId)
    local resolved = {}
    if type(targets) == "table" then
        for _, key in ipairs(targets) do
            local placeable = RLHusbandryTargetKey.resolve(key)
            if placeable ~= nil then
                resolved[#resolved + 1] = placeable
            else
                -- A stored target whose placeable no longer resolves drops from the flushed set (the
                -- count reflects only what is written). On a client this is the bounded residual: a
                -- barn deleted between a join-time decode and this re-send narrows the set, and the
                -- server replaces with the narrowed set. Loud + bounded, never silent.
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

--- Read the target husbandries: a UInt16 count, then one node-object per entry, each mapped back to
--- its context key (uniqueId on server, net-object-id on a pure client) via RLHusbandryTargetKey.keyFor.
--- A node-object that does not resolve to a live placeable on this machine, or a placeable that is
--- unkeyable (keyFor returns nil + :warning), is skipped; `readNodeObject` always consumes its
--- fixed-width id, so the stream stays aligned regardless. Order is preserved.
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
            -- Context-keyed: server stores the uniqueId, a pure client the net-object-id (the only
            -- handle a bought barn streams). keyFor fails closed (nil + :warning) on an unkeyable
            -- placeable, so the stored target count reflects only the keyable ones.
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

    -- filterId is operation-gated: a non-naming operation writes `rule.filterId or ""`
    -- (a nil draft goes as "", which readRule coerces back to nil); naming omits it.
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
---
--- Returns nil (fail-closed drop) when a PRESENT params codec's `read` returns nil - today only
--- `move`, for a present-but-unreconstructable destination. The codec consumes its fixed-width
--- bytes first, so the stream stays byte-aligned for any following record, and the three receivers
--- cope with the nil: Create/Update `run()` guard `rule == nil`, State `run()` warn-skips a nil
--- hole. The unknown-operation branch is unaffected (it keeps `params={}` and the floor rejects it).
---@param streamId number
---@return table|nil rule reconstructed rule record, or nil when a present codec fail-closes
function RLHerdsmanRuleWire.readRule(streamId)
    local id = streamReadString(streamId)
    local name = streamReadString(streamId)
    local operation = streamReadString(streamId)

    -- filterId mirrors the write-side gate: naming carries none (reads back nil);
    -- every other operation reads the string, then coerces exactly "" -> nil. Our
    -- writeRule emits "" only for a genuine nil (rule.filterId or ""), and the floor
    -- never lets a present "" through, so "" is an unambiguous nil draft here.
    -- Whitespace is left verbatim so a crafted "  " is rejected by the receiver
    -- floor, not silently normalized to a valid nil (mod-parity rationale, T1a).
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
            -- Fail-closed drop: a PRESENT codec whose `read` returned nil (a present-but-
            -- unreconstructable move destination) drops the WHOLE record. The codec has already
            -- consumed its fixed-width bytes, so the stream stays aligned for any following record.
            -- The three receivers cope: Create/Update run() guard `rule == nil`; State run()
            -- warn-skips a nil hole.
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
