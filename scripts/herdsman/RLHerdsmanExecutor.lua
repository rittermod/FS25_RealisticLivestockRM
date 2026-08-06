-- RLHerdsmanExecutor.lua
-- M-Tick T3 - the in-game executor wall. Turns the pure plan from
-- RLHerdsmanPlanner.planActions (T1/T2) into the SAME mutations legacy
-- AIAnimalManager:onDayChanged performs (MUTATION PARITY): it dispatches the SAME
-- events (AIAnimalSellEvent / AIAnimalBuyEvent / AIAnimalInseminationEvent), applies
-- castrate + naming as direct server-side field writes AND broadcasts AnimalCastrateEvent /
-- AnimalNameChangeEvent per animal (caller-mutates-first, no sendLocal) so those writes sync
-- to clients, sets the AI_MANAGER_* mark for mark-mode actions (broadcasting AnimalMarkEvent
-- per animal, caller-mutates-first, no sendLocal, so marks sync to clients too) instead of
-- executing, persists the naming cursor, and deducts the herdsman wage once per farm
-- via MoneyType.HERDSMAN_WAGES.
--
-- Membership backstop: before each DIRECT mutation (castrate exec, naming random/alphabetical,
-- mark-mode setMarkOnAll) the executor resolves the action's animal in the husbandry's LIVE
-- cluster (placeable:getClusterSystem().animals) by three-field identity and mutates/broadcasts
-- the RESOLVED object - the same membership check AnimalCastrateEvent:run performs. An animal not
-- in the cluster at execute time is skipped (no field write, no broadcast, one WARNING); siblings
-- proceed. This keeps any plan/execute divergence from ever mutating a dealer-pool / foreign
-- animal. The event-dispatched legs (sell / buy / ai exec) carry no such guard - their events
-- resolve membership themselves.
--
-- T3 makes NO candidate decisions: the plan is authoritative. The executor obeys
-- action.mark / action.wage / action.animals verbatim; it never selects, caps, sorts,
-- computes wage, or reorders. It also does NOT clear stale marks (that is T4, the
-- clear-before-execute ordering) and emits NO player notifications (that is T5 -
-- the returned summary carries the per-action data T5 needs).
--
-- Dependency injection (Rule C), no g_* reads. The dispatch boundary arrives through
-- `ctx`, so the executor's DECISIONS are dual-run (the suite injects fakes/spies; T4 wires
-- the real globals - the calls are byte-identical to legacy):
--   ctx = {
--     server                  = g_server,                        -- broadcastEvent(event, true)
--     mission                 = g_currentMission,                -- addMoney (wage)
--     husbandryPlaceablesById = { [uniqueId] = <placeable> },    -- event object, getOwnerFarmId, getNumOfFreeAnimalSlots
--     ruleService             = <RLHerdsmanRuleService>,         -- setNamingCursor(id, previous)
--     animalNameSystem        = <real AnimalNameSystem>,         -- getRandomName(gender) (reused from T2)
--     defer                   = function(fn) ... end,            -- run fn after the current day-change chain
--   }
--
-- The horse-care leg is the ONE deferred leg, and `defer` is a STRUCTURAL dep for that reason:
-- a missing seam would leave horse care silently never writing while the wage is still charged -
-- the worst failure shape available - so it joins the fail-loud entry guard rather than
-- defaulting (the ctx.buyMarkup precedent). It is checked with type(...) ~= "function", not
-- ~= nil, so a non-callable cannot pass. The client guard runs FIRST, so the fail-loud binds
-- server-side only.
--
-- Why horse care defers at all: the care write must land AFTER Animal:onDayChanged ->
-- AnimalHorse.processRidingUpdate has graded and zeroed `riding` for the day, and the
-- DAY_CHANGED dispatch order between the herdsman tick and a husbandry placeable is NOT fixed -
-- it depends on whether the barn was preplaced, savegame-loaded, or bought mid-session, and the
-- same barn changes sides across a save/reload. Without the deferral the feature is correct on a
-- preplaced barn and silently zeroed on a bought one. Membership still resolves INLINE (only the
-- field WRITE defers), so the result row's count / skippedCount and the wage stay exact and the
-- row contract is identical to _doCastrate's.
-- T3 does NOT read ctx.husbandries (clear-stale-marks is T4, decision 1b).
--
-- summary (return value, consumed by T4 wage readout + T5 messages):
--   summary = {
--     wageByFarm = { [farmId] = number },         -- one deduction per farm with > 0
--     results    = { <one row per plan action, in plan order> },
--   }
-- A result row: { ruleId, husbandryId, farmId, operation, count, skippedCount, mark,
--   amountGained, amountSpent, dispatched, skipReason }. `dispatched` is true iff the event
--   broadcast / direct mutation was applied; `skipReason` is nil when dispatched, else one of
--   "no-space" | "no-money" | "mark-mode" | "missing-placeable" | "missing-dest" | "bad-data" |
--   "not-in-husbandry" | "defer-failed" (horse care only - the deferral seam raised, so the write
--   can never land; distinct from "bad-data" because the cluster and members WERE resolvable).
--   Every skipReason except "mark-mode" and "no-space"/"no-money" means no wage was charged.
--   On a guarded direct-mutation leg (castrate exec / naming / mark-mode) `count` is the count
--   ACTUALLY mutated/marked and `skippedCount` is the membership-skip count (planned - actual);
--   the unguarded legs (sell / buy / ai exec) report the planned count with skippedCount 0. An exec
--   leg whose animals ALL skip membership reports skipReason="not-in-husbandry" (count 0); a mark
--   leg whose animals all skip keeps skipReason="mark-mode" (its identity is load-bearing for T5).
--
-- Parity anchors in AIAnimalManager:onDayChanged: Sell broadcast / Buy broadcast /
-- Castrate field writes + event / Naming walk + event / AI broadcast; wage in
-- RealisticLivestock_FSBaseMission:onDayChanged. T3 SETS marks for mark-mode; clear-stale
-- is T4.
--
-- T3 wires NO MessageCenter subscription and NO day-tick hook of its own - RLHerdsmanDayTick
-- (T4) is the only caller. The legacy AIAnimalManager tick is frozen behind
-- AIAnimalManager.FREEZE_LEGACY_HERDSMAN, so this executor is the only dispatch and the only
-- HERDSMAN_WAGES charge.

local Log = RmLogging.getLogger("RLRM")

RLHerdsmanExecutor = {}

-- =============================================================================
-- Constants
-- =============================================================================

local LOG_PREFIX = "[executeActions]"

local MARK_BY_OPERATION = {
    sell     = "AI_MANAGER_SELL",
    castrate = "AI_MANAGER_CASTRATE",
    ai       = "AI_MANAGER_INSEMINATE",
    move     = "AI_MANAGER_MOVE",
}

-- =============================================================================
-- Internal helpers
-- =============================================================================

--- Finite-number guard: rejects nil / non-number / NaN / +-inf. Used to fail closed on
--- amounts that would crash the event's validate arithmetic and on a malformed wage.
---@param v any
---@return boolean
local function isFiniteNumber(v)
    return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

--- Resolve the herdsman wage contribution for an action, failing closed: a non-finite /
--- non-number wage is treated as 0 (with a WARNING), never raising.
---@param action table
---@return number
local function resolveWage(action)
    if isFiniteNumber(action.wage) then return action.wage end
    Log:warning("%s rule=%s op=%s: non-number wage (%s) - treating as 0",
        LOG_PREFIX, tostring(action.ruleId), tostring(action.operation), tostring(action.wage))
    return 0
end

--- Resolve the action's husbandry cluster animal list ONCE per action, failing closed without
--- raising: a missing getClusterSystem method, a nil / non-table cluster system, or a nil /
--- non-table .animals all return nil so the caller whole-action skips (skipReason="bad-data", no
--- wage, no prefix mutation). @see AnimalCastrateEvent.run for the canonical resolve.
---@param placeable table husbandry placeable owning the cluster
---@return table|nil animals the live cluster animal array, or nil when unavailable
local function resolveClusterAnimals(placeable)
    if type(placeable.getClusterSystem) ~= "function" then
        return nil
    end
    local clusterSystem = placeable:getClusterSystem()
    if type(clusterSystem) ~= "table" or type(clusterSystem.animals) ~= "table" then
        return nil
    end
    return clusterSystem.animals
end

--- Membership guard: resolve `probe` (an action animal reference) to the LIVE cluster object by
--- three-field identity - the same check AnimalCastrateEvent:run performs. Logs ONE WARNING and
--- returns nil when the probe is malformed (nil farmId / uniqueId / birthday.country) OR is not a
--- current member; the caller then skips THAT animal (no field write, no broadcast) and siblings
--- proceed. Present -> returns the RESOLVED cluster object to mutate + broadcast (never the probe).
---@param clusterAnimals table the cluster animal list from resolveClusterAnimals
---@param probe table the action's animal reference
---@param action table for the WARNING row (ruleId / operation / husbandryId)
---@param farmId number for the WARNING row
---@return table|nil resolved the live cluster animal, or nil to skip this animal
local function resolveMember(clusterAnimals, probe, action, farmId)
    -- A non-table probe (a corrupt action.animals entry) is malformed; guard before indexing so the
    -- "never raises" contract holds for any junk entry, not only nil-field animals.
    if type(probe) ~= "table" then
        Log:warning("%s rule=%s op=%s husbandry=%s farm=%s: non-table animal entry (%s) - skipped (malformed)",
            LOG_PREFIX, tostring(action.ruleId), tostring(action.operation), tostring(action.husbandryId),
            tostring(farmId), tostring(probe))
        return nil
    end
    local country = (type(probe.birthday) == "table") and probe.birthday.country or nil
    if probe.farmId == nil or probe.uniqueId == nil or country == nil then
        Log:warning("%s rule=%s op=%s husbandry=%s farm=%s uniqueId=%s country=%s: malformed animal identity - skipped (not in husbandry at execute)",
            LOG_PREFIX, tostring(action.ruleId), tostring(action.operation), tostring(action.husbandryId),
            tostring(farmId), tostring(probe.uniqueId), tostring(country))
        return nil
    end
    local resolved = RLAnimalUtil.find(clusterAnimals, probe.farmId, probe.uniqueId, country)
    if resolved == nil then
        Log:warning("%s rule=%s op=%s husbandry=%s farm=%s uniqueId=%s country=%s: not in husbandry at execute - skipped",
            LOG_PREFIX, tostring(action.ruleId), tostring(action.operation), tostring(action.husbandryId),
            tostring(farmId), tostring(probe.uniqueId), tostring(country))
    end
    return resolved
end

--- Mark-mode leg (shared by sell / castrate / ai): set the AI_MANAGER_* mark on every RESOLVED
--- cluster member of the action AND broadcast AnimalMarkEvent per animal (caller-mutates-first, no
--- sendLocal) so the mark syncs to MP clients - the same shape the player path (@see
--- RLAnimalInfoService.markAnimal) and the castrate / naming exec legs use. Each animal is
--- membership-resolved first (@see resolveMember): an absent animal is skipped (no setMarked, no
--- broadcast, one WARNING). setMarked is fully real headless (the visual-marker call self-no-ops
--- with no visual instance). Returns the leg outcome tuple: a mark row ALWAYS reports
--- dispatched=false + skipReason="mark-mode" (its identity is load-bearing for T5) regardless of how
--- many resolved, and `actualMarked` drives _executeOne's count / skippedCount / actual-over-planned
--- wage. Fails CLOSED two ways: a nil markKey (AnimalMarkEvent treats key=nil as a destructive
--- clear-ALL-marks, @see AnimalMarkEvent.new) skips the whole action keeping the legacy mark-mode
--- wage; a nil / non-table cluster whole-action skips as bad-data (no wage).
---@param ctx table dispatch context (ctx.server:broadcastEvent)
---@param placeable table husbandry placeable owning the animals' cluster system (the event object)
---@param action table the mark-mode action (animals + ruleId / operation / husbandryId for the log row)
---@param markKey string the AI_MANAGER_* mark to set + broadcast
---@param farmId number owning farm (log context)
---@return boolean chargeWage
---@return boolean dispatched
---@return string|nil skipReason
---@return number|nil actualMarked count actually marked (nil = wage not scaled - the nil-key fail-closed)
---@return number|nil skippedCount membership-skip count (nil when actualMarked is nil)
local function setMarkOnAll(ctx, placeable, action, markKey, farmId)
    if markKey == nil then
        Log:warning("%s rule=%s op=%s husbandry=%s farm=%s: nil mark key - skipped (no setMarked, no broadcast; nil key is AnimalMarkEvent clear-all)",
            LOG_PREFIX, tostring(action.ruleId), tostring(action.operation), tostring(action.husbandryId), tostring(farmId))
        return true, false, "mark-mode", nil
    end

    local clusterAnimals = resolveClusterAnimals(placeable)
    if clusterAnimals == nil then
        Log:warning("%s rule=%s op=%s husbandry=%s farm=%s: cluster unavailable (getClusterSystem) - whole action skipped (no wage)",
            LOG_PREFIX, tostring(action.ruleId), tostring(action.operation), tostring(action.husbandryId), tostring(farmId))
        return false, false, "bad-data", nil
    end

    local marked, skipped = 0, 0
    for _, probe in ipairs(action.animals) do
        local animal = resolveMember(clusterAnimals, probe, action, farmId)
        if animal ~= nil then
            animal:setMarked(markKey, true)
            -- MP sync: broadcast WITHOUT sendLocal. AnimalMarkEvent:run applies setMarked on server AND
            -- client, so the server already marked above; sendLocal would re-run run() locally (redundant
            -- re-mark, possible double broadcast). @see RLAnimalInfoService.markAnimal.
            ctx.server:broadcastEvent(AnimalMarkEvent.new(placeable, animal, markKey, true))
            Log:debug("%s rule=%s op=%s husbandry=%s farm=%s: broadcast AnimalMarkEvent uniqueId=%s key=%s",
                LOG_PREFIX, tostring(action.ruleId), tostring(action.operation), tostring(action.husbandryId),
                tostring(farmId), tostring(animal.uniqueId), tostring(markKey))
            marked = marked + 1
        else
            skipped = skipped + 1
        end
    end
    return true, false, "mark-mode", marked, skipped
end

--- Emit the single uniform greppable per-action trace row, read from the result table so EVERY
--- exit path (including the early fail-closed skips) logs exactly one identical DEBUG row.
---@param result table
local function logActionRow(result)
    Log:debug("%s rule=%s op=%s husbandry=%s farm=%s count=%d skippedCount=%d mark=%s dispatched=%s amountGained=%s amountSpent=%s skipReason=%s",
        LOG_PREFIX, tostring(result.ruleId), tostring(result.operation), tostring(result.husbandryId),
        tostring(result.farmId), result.count, result.skippedCount, tostring(result.mark), tostring(result.dispatched),
        tostring(result.amountGained), tostring(result.amountSpent), tostring(result.skipReason))
end

-- =============================================================================
-- Public API
-- =============================================================================

--- Apply the planned actions in-game (server-only), mirroring legacy
--- AIAnimalManager:onDayChanged. Per action: dispatch the SAME event legacy does (sell /
--- buy / ai), apply castrate + naming directly THEN broadcast AnimalCastrateEvent /
--- AnimalNameChangeEvent per animal so clients sync, OR set the AI_MANAGER_* mark for
--- a mark-mode action AND broadcast AnimalMarkEvent per animal so the mark syncs to clients;
--- accumulate the herdsman wage per farm and deduct it once per farm at
--- the end. Fails LOUD on a missing STRUCTURAL ctx dep (a T4-wiring bug), fails CLOSED
--- (skip + WARNING, never raise) on a per-action data problem. Reads no g_*; the dispatch
--- boundary is injected via ctx.
---@param plan table|nil ordered action records from RLHerdsmanPlanner.planActions
---@param ctx table dispatch context (server, mission, husbandryPlaceablesById, ruleService, animalNameSystem)
---@return table summary { wageByFarm = { [farmId]=number }, results = { <row per action> } }
function RLHerdsmanExecutor.executeActions(plan, ctx)
    local summary = { wageByFarm = {}, results = {} }

    -- Server-only: a dedicated server has g_server ~= nil, so guarding on ctx.server (= g_server)
    -- correctly includes dedis. T4 only ticks server-side; the executor still guards.
    if ctx == nil or ctx.server == nil then
        Log:debug("%s not server (ctx.server==nil) - no dispatch / mutation / money; empty summary", LOG_PREFIX)
        return summary
    end

    -- Fail LOUD on a missing STRUCTURAL dep the executor unconditionally needs: a missing one
    -- is a T4-wiring bug, never a silent no-op that would hide a broken day-tick.
    -- `defer` is checked for CALLABILITY, not mere presence: a `== nil` check would let a
    -- non-callable through to the horse-care arm, where calling it raises far from the cause.
    if ctx.mission == nil or ctx.ruleService == nil or ctx.animalNameSystem == nil
        or ctx.husbandryPlaceablesById == nil or type(ctx.defer) ~= "function" then
        -- One convention for all five: present-and-usable as a boolean. Reporting `defer` as a
        -- type() string while its four neighbours read true/false makes the reader stop and work
        -- out which field uses which format, and the `function` case is unreachable here anyway.
        error(string.format(
            "%s missing structural ctx dep (T4 wiring bug): mission=%s ruleService=%s animalNameSystem=%s husbandryPlaceablesById=%s defer=%s",
            LOG_PREFIX, tostring(ctx.mission ~= nil), tostring(ctx.ruleService ~= nil),
            tostring(ctx.animalNameSystem ~= nil), tostring(ctx.husbandryPlaceablesById ~= nil),
            tostring(type(ctx.defer) == "function")))
    end

    if plan == nil then
        Log:trace("%s nil plan - empty summary", LOG_PREFIX)
        return summary
    end

    -- First-seen farm order so the per-farm wage deduction is deterministic across runners
    -- (pairs() order is undefined); per-farm deductions are otherwise independent.
    local wageFarmOrder = {}

    for _, action in ipairs(plan) do
        local result = RLHerdsmanExecutor._executeOne(action, ctx, summary, wageFarmOrder)
        summary.results[#summary.results + 1] = result
    end

    -- One HERDSMAN_WAGES deduction per farm with a positive accrued wage (parity with
    -- RealisticLivestock_FSBaseMission:onDayChanged), in first-seen plan order.
    for _, farmId in ipairs(wageFarmOrder) do
        local wage = summary.wageByFarm[farmId]
        if wage ~= nil and wage > 0 then
            ctx.mission:addMoney(-wage, farmId, MoneyType.HERDSMAN_WAGES, true, true)
            Log:debug("%s wage deducted farmId=%s wage=%.2f", LOG_PREFIX, tostring(farmId), wage)
        end
    end

    return summary
end

-- =============================================================================
-- Per-action execution
-- =============================================================================

--- Resolve one action and apply it, accumulating any farm-attributed wage into
--- summary.wageByFarm. Returns the result row. Never raises (per-action problems fail closed).
---@param action table
---@param ctx table
---@param summary table
---@param wageFarmOrder table first-seen farmId order for deterministic wage deduction
---@return table result
function RLHerdsmanExecutor._executeOne(action, ctx, summary, wageFarmOrder)
    local result = {
        ruleId       = action.ruleId,
        husbandryId  = action.husbandryId,
        farmId       = nil,
        operation    = action.operation,
        count        = 0,
        skippedCount = 0,
        mark         = action.mark == true,
        amountGained = action.amountGained,
        amountSpent  = action.amountSpent,
        dispatched   = false,
        skipReason   = nil,
    }

    -- Per-action resolution: the records carry only husbandryId (never farmId).
    local placeable = ctx.husbandryPlaceablesById[action.husbandryId]
    if placeable == nil then
        result.skipReason = "missing-placeable"
        Log:warning("%s rule=%s op=%s husbandry=%s: husbandry not in ctx - dropped (no dispatch, no wage)",
            LOG_PREFIX, tostring(action.ruleId), tostring(action.operation), tostring(action.husbandryId))
        logActionRow(result)
        return result
    end

    local farmId = placeable:getOwnerFarmId()
    if farmId == nil then
        result.skipReason = "missing-placeable"
        Log:warning("%s rule=%s op=%s husbandry=%s: getOwnerFarmId() nil - dropped (unattributable, no dispatch, no wage)",
            LOG_PREFIX, tostring(action.ruleId), tostring(action.operation), tostring(action.husbandryId))
        logActionRow(result)
        return result
    end
    result.farmId = farmId

    local animals = action.animals
    local count = (type(animals) == "table") and #animals or 0
    result.count = count
    if count == 0 then
        result.skipReason = "bad-data"
        Log:warning("%s rule=%s op=%s husbandry=%s farm=%s: zero animals - skipped before validate (no wage)",
            LOG_PREFIX, tostring(action.ruleId), tostring(action.operation), tostring(action.husbandryId), tostring(farmId))
        logActionRow(result)
        return result
    end

    -- Dispatch by operation. Each branch returns (chargeWage, dispatched, skipReason); a
    -- data-skip returns chargeWage=false (the action is dropped). chargeWage=true charges the
    -- wage regardless of dispatch outcome (mark, exec, OR validate-rejected) - legacy charges
    -- self.wage before/independent of dispatch.
    -- Guarded direct-mutation legs return a 4th value (the count ACTUALLY mutated/marked) and a 5th
    -- (their own membership-skip count) - both nil from the unguarded sell / buy / ai exec legs. They
    -- re-derive the row's count + skippedCount and scale the wage below.
    local op = action.operation
    -- `extra` (6th return) is the SCALING-FREE row channel: only the move EPP leg returns it, a
    -- { movedCount, skippedAge } table merged onto the row below WITHOUT touching actualCount (so the
    -- wage stays planned). Every other leg leaves it nil.
    local chargeWage, dispatched, skipReason, actualCount, skippedCount, extra
    if op == "sell" then
        chargeWage, dispatched, skipReason, actualCount, skippedCount = RLHerdsmanExecutor._doSell(action, ctx, placeable, farmId, count)
    elseif op == "buy" then
        chargeWage, dispatched, skipReason, actualCount, skippedCount = RLHerdsmanExecutor._doBuy(action, ctx, placeable, farmId, count)
    elseif op == "castrate" then
        chargeWage, dispatched, skipReason, actualCount, skippedCount = RLHerdsmanExecutor._doCastrate(action, ctx, placeable, farmId, count)
    elseif op == "naming" then
        chargeWage, dispatched, skipReason, actualCount, skippedCount = RLHerdsmanExecutor._doNaming(action, ctx, placeable, farmId, count)
    elseif op == "ai" then
        chargeWage, dispatched, skipReason, actualCount, skippedCount = RLHerdsmanExecutor._doAi(action, ctx, placeable, farmId, count)
    elseif op == "move" then
        chargeWage, dispatched, skipReason, actualCount, skippedCount, extra = RLHerdsmanExecutor._doMove(action, ctx, placeable, farmId, count)
    elseif op == "horseCare" then
        chargeWage, dispatched, skipReason, actualCount, skippedCount = RLHerdsmanExecutor._doHorseCare(action, ctx, placeable, farmId, count)
    else
        chargeWage, dispatched, skipReason = false, false, "bad-data"
        Log:warning("%s rule=%s husbandry=%s farm=%s: unknown operation '%s' - skipped (no wage)",
            LOG_PREFIX, tostring(action.ruleId), tostring(action.husbandryId), tostring(farmId), tostring(op))
    end

    result.dispatched = dispatched
    result.skipReason = skipReason

    -- A guarded leg reports the count it ACTUALLY mutated/marked AND its OWN membership-skip count
    -- (NOT count - actualCount, which would fabricate skips for a planner cardinality anomaly such as
    -- an empty-assignments alphabetical action). Unguarded legs (actualCount nil) keep the planned
    -- count + skippedCount 0.
    if actualCount ~= nil then
        result.count = actualCount
        result.skippedCount = skippedCount or 0
    end

    -- EPP move counts ride the SCALING-FREE `extra` channel: the move EPP leg keeps actualCount
    -- nil (so the wage stays planned above/below) and returns { movedCount, skippedAge } merged here.
    -- movedCount = animals dispatched to the butcher (drives the moved message, falling back to count
    -- for husbandry rows); skippedAge = animals filtered out for age (drives the skipped-age message).
    -- Husbandry-move + non-move rows carry no extra (nil), so those rows are byte-identical.
    if type(extra) == "table" then
        result.movedCount = extra.movedCount
        result.skippedAge = extra.skippedAge
    end

    if chargeWage then
        -- Wage follows the ACTUAL acted-on count on a guarded leg: a membership skip is never paid
        -- for (all-skipped -> 0). Exact for the linear castrate/naming formulas; an accepted
        -- approximation for the mark-mode min(S, n*5) component. count > 0 here (a zero-animal action
        -- skipped before dispatch), so the divisor is safe.
        local wage = resolveWage(action)
        if actualCount ~= nil then
            wage = wage * actualCount / count
        end
        if summary.wageByFarm[farmId] == nil then
            summary.wageByFarm[farmId] = 0
            wageFarmOrder[#wageFarmOrder + 1] = farmId
        end
        summary.wageByFarm[farmId] = summary.wageByFarm[farmId] + wage
    end

    logActionRow(result)
    return result
end

--- Sell: exec broadcasts AIAnimalSellEvent (the event deducts MoneyType.SOLD_ANIMALS on the
--- server's cluster-batch success); mark sets AI_MANAGER_SELL. Wage charged either way.
---@param action table
---@param ctx table
---@param placeable table
---@param farmId number
---@param count number
---@return boolean chargeWage
---@return boolean dispatched
---@return string|nil skipReason
---@return number|nil actualMarked nil on the unguarded sell exec leg; count marked on the mark leg
---@return number|nil skippedCount membership-skip count on the mark leg (nil on the unguarded exec leg)
function RLHerdsmanExecutor._doSell(action, ctx, placeable, farmId, count)
    if action.mark == true then
        return setMarkOnAll(ctx, placeable, action, MARK_BY_OPERATION.sell, farmId)
    end

    if not isFiniteNumber(action.amountGained) then
        Log:warning("%s rule=%s op=sell husbandry=%s farm=%s: non-number amountGained (%s) - skipped (no wage)",
            LOG_PREFIX, tostring(action.ruleId), tostring(action.husbandryId), tostring(farmId), tostring(action.amountGained))
        return false, false, "bad-data"
    end

    -- AIAnimalSellEvent.validate returns non-nil ONLY on object == nil, which the
    -- missing-placeable guard already caught; this branch is defensive.
    local errorCode = AIAnimalSellEvent.validate(placeable, count, action.amountGained, farmId)
    if errorCode ~= nil then
        Log:warning("%s rule=%s op=sell husbandry=%s farm=%s: validate rejected (errorCode=%s) - dispatch skipped (wage charged)",
            LOG_PREFIX, tostring(action.ruleId), tostring(action.husbandryId), tostring(farmId), tostring(errorCode))
        return true, false, "missing-placeable"
    end

    ctx.server:broadcastEvent(AIAnimalSellEvent.new(placeable, action.animals, action.amountGained), true)
    return true, true, nil
end

--- Buy (no mark param): exec runs AIAnimalBuyEvent.validate (the REAL runtime gate - free
--- slots + money) then broadcasts AIAnimalBuyEvent (removeSaleAnimal + addAnimals + deducts
--- MoneyType.NEW_ANIMALS_COST). A validate rejection skips dispatch but STILL charges wage.
--- Note: validate's money check reads the GLOBAL g_currentMission:getMoney (not ctx.mission), so
--- in production ctx.mission MUST be g_currentMission - T4 cannot point ctx.mission elsewhere
--- without the buy money-gate silently diverging from the wage ledger.
---@param action table
---@param ctx table
---@param placeable table
---@param farmId number
---@param count number
---@return boolean chargeWage
---@return boolean dispatched
---@return string|nil skipReason
function RLHerdsmanExecutor._doBuy(action, ctx, placeable, farmId, count)
    if not isFiniteNumber(action.amountSpent) then
        Log:warning("%s rule=%s op=buy husbandry=%s farm=%s: non-number amountSpent (%s) - skipped (no wage)",
            LOG_PREFIX, tostring(action.ruleId), tostring(action.husbandryId), tostring(farmId), tostring(action.amountSpent))
        return false, false, "bad-data"
    end

    local errorCode = AIAnimalBuyEvent.validate(placeable, count, action.amountSpent, farmId)
    if errorCode == AnimalBuyEvent.BUY_ERROR_NOT_ENOUGH_SPACE then
        Log:warning("%s rule=%s op=buy husbandry=%s farm=%s count=%d: not enough space - dispatch skipped (wage charged)",
            LOG_PREFIX, tostring(action.ruleId), tostring(action.husbandryId), tostring(farmId), count)
        return true, false, "no-space"
    elseif errorCode == AnimalBuyEvent.BUY_ERROR_NOT_ENOUGH_MONEY then
        Log:warning("%s rule=%s op=buy husbandry=%s farm=%s amountSpent=%.2f: not enough money - dispatch skipped (wage charged)",
            LOG_PREFIX, tostring(action.ruleId), tostring(action.husbandryId), tostring(farmId), action.amountSpent)
        return true, false, "no-money"
    elseif errorCode ~= nil then
        Log:warning("%s rule=%s op=buy husbandry=%s farm=%s: validate rejected (errorCode=%s) - dispatch skipped (wage charged)",
            LOG_PREFIX, tostring(action.ruleId), tostring(action.husbandryId), tostring(farmId), tostring(errorCode))
        return true, false, "missing-placeable"
    end

    ctx.server:broadcastEvent(AIAnimalBuyEvent.new(placeable, action.animals, action.amountSpent), true)
    return true, true, nil
end

--- Castrate: exec sets isCastrated + zeroes genetics.fertility per animal AND broadcasts
--- AnimalCastrateEvent per animal (caller-mutates-first, no sendLocal) so clients sync; mark
--- sets AI_MANAGER_CASTRATE.
---@param action table
---@param ctx table
---@param placeable table
---@param farmId number
---@param count number
---@return boolean chargeWage
---@return boolean dispatched
---@return string|nil skipReason
---@return number|nil actualCount nil on the mark leg's nil-key/bad-data fail-closed; count castrated otherwise
---@return number|nil skippedCount membership-skip count (nil when actualCount is nil)
function RLHerdsmanExecutor._doCastrate(action, ctx, placeable, farmId, count)
    if action.mark == true then
        return setMarkOnAll(ctx, placeable, action, MARK_BY_OPERATION.castrate, farmId)
    end

    -- Validate EVERY animal's genetics table BEFORE mutating, so a malformed animal drops the
    -- whole action (fail closed) instead of castrating a prefix then raising on a nil index. The
    -- planner already hard-skips nil-genetics castrate candidates; this guards a corrupt action.
    -- Retained by design: corrupt action data fails the whole action regardless of membership.
    for _, animal in ipairs(action.animals) do
        if type(animal.genetics) ~= "table" then
            Log:warning("%s rule=%s op=castrate husbandry=%s farm=%s: animal has no genetics table - skipped (no wage)",
                LOG_PREFIX, tostring(action.ruleId), tostring(action.husbandryId), tostring(farmId))
            return false, false, "bad-data"
        end
    end

    -- Membership backstop: resolve the live cluster once, then mutate + broadcast only RESOLVED
    -- members. A nil / non-table cluster fails the whole action closed (no wage).
    local clusterAnimals = resolveClusterAnimals(placeable)
    if clusterAnimals == nil then
        Log:warning("%s rule=%s op=castrate husbandry=%s farm=%s: cluster unavailable (getClusterSystem) - whole action skipped (no wage)",
            LOG_PREFIX, tostring(action.ruleId), tostring(action.husbandryId), tostring(farmId))
        return false, false, "bad-data"
    end

    local actual, skipped = 0, 0
    for _, probe in ipairs(action.animals) do
        local animal = resolveMember(clusterAnimals, probe, action, farmId)
        if animal ~= nil then
            -- Mirror AnimalCastrateEvent:run on the RESOLVED object: isCastrated always, fertility=0
            -- only when its genetics is a TABLE (the type check, not merely ~= nil, never raises on a
            -- divergent resolved object whose genetics is non-table junk - false / 0 / string).
            animal.isCastrated = true
            if type(animal.genetics) == "table" then
                animal.genetics.fertility = 0
            end
            -- MP sync: broadcast WITHOUT sendLocal. AnimalCastrateEvent:run applies the castrate on
            -- server AND client, so the server already mutated above; sendLocal would re-run run()
            -- locally (redundant re-mutation, possible double broadcast). @see RLAnimalInfoService.castrateAnimal.
            ctx.server:broadcastEvent(AnimalCastrateEvent.new(placeable, animal))
            Log:debug("%s rule=%s op=castrate husbandry=%s farm=%s: broadcast AnimalCastrateEvent uniqueId=%s",
                LOG_PREFIX, tostring(action.ruleId), tostring(action.husbandryId), tostring(farmId), tostring(animal.uniqueId))
            actual = actual + 1
        else
            skipped = skipped + 1
        end
    end

    -- Every animal skipped membership -> a genuine all-skip exec row (count 0), distinct from the
    -- mark-mode and bad-data skips; the wage scales to 0.
    if actual == 0 then
        return true, false, "not-in-husbandry", 0, skipped
    end
    return true, true, nil, actual, skipped
end

--- The full-care values. `riding` is written ABSOLUTE (setRiding clamps to 0-100); dirt is
--- cleared by a -100 DELTA, because changeDirt is the only mutator the Animal prototype exposes.
--- On a corrupt save carrying dirt > 100 the clear is therefore PARTIAL, landing at
--- `clamp(dirt - 100, 0, 100)`: 150 -> 50, and only dirt >= 200 lands at 100. Accepted - the
--- per-animal DEBUG row's before/after makes it visible rather than silent.
---
--- Why the care level is 100 rather than the 40 that would merely hold fitness. `changeFitness`
--- applies `math.floor` to `fitness + delta` (the SUM, not the increment - so a fractional fitness
--- loaded from a save shifts the first tick by one), which makes the effective daily gain
--- `floor(25 * factor / daysPerPeriod)` ABOVE the threshold. `factor` here is the normalized
--- `(riding/100 - t) / (1 - t)`, NOT `riding/100`, and `t` is `ridingThresholdFactor` - 0.4 by
--- engine default and unset in RLRM's `animals.xml`, so every number below is a 0.4 number and a
--- subtype declaring `health#ridingThreshold` invalidates the ladder.
---
--- Above the threshold each care level therefore has a `daysPerPeriod` at which its gain floors to
--- zero and fitness stops growing: riding 50 dies at 5, 60 at 9, 70 at 13, 80 at 17, 90 at 21, and
--- 100 only at 26. That makes 100 the level that stays useful across the seasons players actually
--- run - though NOT across the whole selectable range, which reaches 28: at 26, 27 and 28 even full
--- care grows no fitness, and the operation is then a grooming service that also holds the riding
--- price term. At exactly 40 the factor is 0, so fitness FREEZES wherever it already sits instead of
--- converging - a horse bought at 0 stays at 0 and one already at 100 stays at 100, making the
--- settled sale price history-dependent. Below 40 the arithmetic changes shape: `delta` is 10 rather
--- than 25 and the factor is negative, so care actively DECAYS fitness while still billing the wage,
--- and because the decay uses `ceil` it never floors away - a sub-threshold level loses ground at
--- every `daysPerPeriod`, which is strictly worse for the player than owning no rule at all.
local HORSE_CARE_RIDING = 100
local HORSE_CARE_DIRT_DELTA = -100

--- The DEFERRED half of the horse-care leg: re-validate membership, then write.
--- Runs OUTSIDE the day-tick's own safeCall (the timer fires later), so it carries its own
--- isolation - per-animal via safeAnimalCall, so one malformed horse cannot abort the loop and
--- leave every sibling unwritten while the full wage was already charged.
---
--- Membership is re-resolved rather than trusted: the inline pass proved these were members when
--- the action was armed, but a horse can leave the pen between arming and firing (mounted as a
--- rideable, loaded into a trailer, sold). The row already reported it as acted-on; writing to a
--- non-member would be worse than the count being one optimistic.
---@param action table the horse-care action (ruleId / husbandryId for the log rows)
---@param placeable table husbandry placeable owning the cluster
---@param planned table[] the INLINE-resolved live cluster animals
---@param farmId number owning farm (log context)
---@return nil the row and wage were committed when the action was armed; this half cannot retract them
function RLHerdsmanExecutor._writeHorseCare(action, placeable, planned, farmId)
    local clusterAnimals = resolveClusterAnimals(placeable)
    -- An EMPTY list is the teardown signal and aborts ONCE. Without this special case every probe
    -- would simply fail membership and emit its own WARNING - N lines saying "not in husbandry"
    -- for a husbandry that no longer exists. Base onDelete nils clusterHusbandry but never
    -- clusterSystem, and RLRM's AnimalClusterSystem:delete sets animals = {}, so the torn-down
    -- shape is {} rather than nil.
    if clusterAnimals == nil or #clusterAnimals == 0 then
        -- Distinguish the two causes: a cluster system that is GONE (the husbandry was deleted or
        -- sold) from a live pen that merely emptied during this same day-change chain (deaths, or a
        -- legacy sell inside the placeable's own tick). Reporting the second as "cluster gone"
        -- misdirects diagnosis of an entirely normal day.
        local torn = type(placeable.getClusterSystem) ~= "function" or clusterAnimals == nil
        Log:warning("%s rule=%s op=horseCare husbandry=%s farm=%s: %s when the deferred write fired - %d planned horse(s) unwritten (aborted once)",
            LOG_PREFIX, tostring(action.ruleId), tostring(action.husbandryId), tostring(farmId),
            torn and "cluster gone (husbandry torn down)" or "pen emptied during this day-change chain",
            #planned)
        -- Emit the summary row on THIS path too. It is a separate requirement from the abort
        -- WARNING, and this is the outcome where a reader most needs applied/skipped to be explicit:
        -- the action row already reported these horses as acted-on and the wage is already committed.
        Log:debug("%s rule=%s op=horseCare husbandry=%s farm=%s: deferred write complete applied=0 left-pen=%d failed=0 of %d planned (aborted: no live cluster)",
            LOG_PREFIX, tostring(action.ruleId), tostring(action.husbandryId), tostring(farmId),
            #planned, #planned)
        return
    end

    local applied, left, failed = 0, 0, 0
    for _, probe in ipairs(planned) do
        local animal = resolveMember(clusterAnimals, probe, action, farmId)
        if animal == nil then
            left = left + 1
        else
            local ok = RmSafeUtils.safeAnimalCall(animal, "RLHerdsmanExecutor:horseCareWrite", function()
                local ridingBefore, dirtBefore = animal.riding, animal.dirt
                animal:setRiding(HORSE_CARE_RIDING)
                animal:changeDirt(HORSE_CARE_DIRT_DELTA)
                -- AnimalHorse's mutators do NOT set the dirty flag (base AnimalClusterHorse's do),
                -- so the leg must. This drives clusterSystem:setDirty -> owner:raiseActive, and the
                -- placeable's own update flushes, broadcasting AnimalClusterUpdateEvent - whose
                -- payload already carries dirt / fitness / riding for every animal. One broadcast
                -- per husbandry per flush, versus one or two per animal for a bespoke event.
                animal:setDirty()
                Log:debug("%s rule=%s op=horseCare husbandry=%s farm=%s: cared uniqueId=%s riding %s->%s dirt %s->%s",
                    LOG_PREFIX, tostring(action.ruleId), tostring(action.husbandryId), tostring(farmId),
                    tostring(animal.uniqueId), tostring(ridingBefore), tostring(animal.riding),
                    tostring(dirtBefore), tostring(animal.dirt))
                return true
            end, { false })
            if ok then applied = applied + 1 else failed = failed + 1 end
        end
    end

    -- ruleId + husbandryId are load-bearing on this row: concurrent pens in one tick emit
    -- interleaved callbacks, and without both there is no way to tell them apart in the log.
    Log:debug("%s rule=%s op=horseCare husbandry=%s farm=%s: deferred write complete applied=%d left-pen=%d failed=%d of %d planned",
        LOG_PREFIX, tostring(action.ruleId), tostring(action.husbandryId), tostring(farmId),
        applied, left, failed, #planned)
end

--- Horse care: write riding = 100 and clear dirt on every planned HORSE, DEFERRED to after the
--- animal day tick (see the file header for why the ordering is the substance).
---
--- Membership resolves INLINE, before arming - so this returns the guarded-leg tuple in the same
--- SHAPE as _doCastrate's: `count` is the resolved count, `skippedCount` the membership skips, and
--- the wage scales to the count rather than to what was planned.
---
--- The SHAPE is identical; the SEMANTICS are not, and a consumer must not confuse them.
--- _doCastrate's `count` counts mutations that have ALREADY happened and been broadcast. This
--- leg's `count` is PREDICTIVE: the writes land one or more frames later, and the callback
--- re-validates membership and may drop some of them. A horse sold or mounted between arming and
--- firing is counted here and never written. Anything downstream that reads `count` as "work done"
--- - the wage today, the message family in the next slice - is optimistic for this operation alone.
---
--- The leg performs NO animal-type check, by decision. The planner's pen gate is the only gate,
--- and it is sufficient because a pen cannot hold a foreign-type animal through any gated path
--- (PlaceableHusbandryAnimals:getSupportsAnimalSubType is enforced on every entry path; buy draws
--- from a per-type dealer pool; births inherit the mother's type). A per-animal type check here
--- would be this layer's first root-global read, in a module whose header claims none and whose
--- dual-run posture depends on that claim - spent on a path normal play cannot reach. An
--- acceptance criterion greps this file to keep one from being reintroduced in good faith; do not
--- defeat it by naming the rejected predicate here.
---@param action table the horse-care action (animals + ruleId / husbandryId)
---@param ctx table dispatch context (ctx.defer is the deferral seam this leg consumes)
---@param placeable table husbandry placeable owning the animals' cluster system
---@param farmId number owning farm (wage attribution + log context)
---@param count number planned animal count (the wage scales actual/planned against it)
---@return boolean chargeWage
---@return boolean dispatched
---@return string|nil skipReason
---@return number|nil actualCount nil on a bad-data fail-closed; count armed otherwise
---@return number|nil skippedCount membership-skip count (nil when actualCount is nil)
function RLHerdsmanExecutor._doHorseCare(action, ctx, placeable, farmId, count)
    -- Cluster resolve precedes arming, so the bad-data outcome stays reachable: no wage, no timer.
    local clusterAnimals = resolveClusterAnimals(placeable)
    if clusterAnimals == nil then
        Log:warning("%s rule=%s op=horseCare husbandry=%s farm=%s: cluster unavailable (getClusterSystem) - whole action skipped (no wage, nothing armed)",
            LOG_PREFIX, tostring(action.ruleId), tostring(action.husbandryId), tostring(farmId))
        return false, false, "bad-data"
    end

    local resolved, skipped = {}, 0
    for _, probe in ipairs(action.animals) do
        local animal = resolveMember(clusterAnimals, probe, action, farmId)
        if animal ~= nil then
            resolved[#resolved + 1] = animal
        else
            skipped = skipped + 1
        end
    end

    local actual = #resolved
    if actual == 0 then
        -- Every planned horse skipped membership: a genuine all-skip exec row (wage scales to 0),
        -- and nothing is armed - a timer that would write nothing is not worth scheduling.
        Log:debug("%s rule=%s op=horseCare husbandry=%s farm=%s: all %d planned horse(s) absent from the cluster - nothing armed",
            LOG_PREFIX, tostring(action.ruleId), tostring(action.husbandryId), tostring(farmId), count)
        return true, false, "not-in-husbandry", 0, skipped
    end

    -- Arming is itself guarded: a raising ctx.defer must not take out the remaining actions or the
    -- per-farm wage deduction that follows them. safeCall logs the failure - a silent pcall here
    -- would hide a broken seam behind a wage that still gets charged.
    local armed = RmSafeUtils.safeCall(
        string.format("RLHerdsmanExecutor:armHorseCare rule=%s husbandry=%s", tostring(action.ruleId), tostring(action.husbandryId)),
        function()
            ctx.defer(function()
                RmSafeUtils.safeCall(
                    string.format("RLHerdsmanExecutor:horseCareDeferred rule=%s husbandry=%s", tostring(action.ruleId), tostring(action.husbandryId)),
                    function()
                        RLHerdsmanExecutor._writeHorseCare(action, placeable, resolved, farmId)
                    end)
            end)
        end)

    if not armed then
        -- The seam raised, so NOTHING will ever write - and therefore nothing is charged. Returning
        -- chargeWage=true here would bill the farm the full planned wage for a write that provably
        -- never happens, which is precisely the failure shape the file header calls the worst one
        -- available and cites as the reason `defer` is fail-loud in the first place.
        -- Its OWN reason, not "bad-data": that reason already means "no wage" at every other exit in
        -- this module, and reusing it for a case with a live cluster and resolved members would make
        -- the two indistinguishable to anything reading the row.
        Log:warning("%s rule=%s op=horseCare husbandry=%s farm=%s: the defer seam raised - %d resolved horse(s) will never be written; no wage charged",
            LOG_PREFIX, tostring(action.ruleId), tostring(action.husbandryId), tostring(farmId), actual)
        return false, false, "defer-failed", 0, skipped
    end

    Log:debug("%s rule=%s op=horseCare husbandry=%s farm=%s: armed deferred care for %d horse(s) (%d skipped at membership)",
        LOG_PREFIX, tostring(action.ruleId), tostring(action.husbandryId), tostring(farmId), actual, skipped)
    return true, true, nil, actual, skipped
end

--- Naming: alphabetical writes the planner-assigned names + advances the server-only cursor
--- via ruleService:setNamingCursor; random generates a fresh name per animal and never advances
--- the cursor. Each named animal broadcasts AnimalNameChangeEvent (caller-mutates-first, no
--- sendLocal) so clients sync. Naming has no mark param. Wage always charged.
---@param action table
---@param ctx table
---@param placeable table
---@param farmId number
---@param count number
---@return boolean chargeWage
---@return boolean dispatched
---@return string|nil skipReason
---@return number|nil actualCount nil on a bad-data fail-closed; count named otherwise
---@return number|nil skippedCount membership-skip count (nil when actualCount is nil)
function RLHerdsmanExecutor._doNaming(action, ctx, placeable, farmId, count)
    -- Membership backstop applies to both conventions: resolve the live cluster once, then write +
    -- broadcast only RESOLVED members. A nil / non-table cluster fails the whole action closed.
    local clusterAnimals = resolveClusterAnimals(placeable)
    if clusterAnimals == nil then
        Log:warning("%s rule=%s op=naming husbandry=%s farm=%s: cluster unavailable (getClusterSystem) - whole action skipped (no wage)",
            LOG_PREFIX, tostring(action.ruleId), tostring(action.husbandryId), tostring(farmId))
        return false, false, "bad-data"
    end

    if action.convention == "random" then
        local named, skipped = 0, 0
        for _, probe in ipairs(action.animals) do
            local animal = resolveMember(clusterAnimals, probe, action, farmId)
            if animal ~= nil then
                -- Capture the generated name into a local so the field write and the broadcast carry
                -- the SAME value (an empty name list -> getRandomName nil -> name cleared on both sides).
                local name = ctx.animalNameSystem:getRandomName(animal.gender)
                animal.name = name
                ctx.server:broadcastEvent(AnimalNameChangeEvent.new(placeable, animal, name))
                Log:debug("%s rule=%s op=naming(random) husbandry=%s farm=%s: broadcast AnimalNameChangeEvent uniqueId=%s name=%s",
                    LOG_PREFIX, tostring(action.ruleId), tostring(action.husbandryId), tostring(farmId), tostring(animal.uniqueId), tostring(name))
                named = named + 1
            else
                skipped = skipped + 1
            end
        end
        if named == 0 then
            return true, false, "not-in-husbandry", 0, skipped
        end
        return true, true, nil, named, skipped
    end

    -- Alphabetical: the planner carries the resolved { animal, name } assignments. Validate EVERY
    -- entry BEFORE writing any name, so a malformed entry drops the whole action (fail closed)
    -- instead of naming a prefix then raising on the bad one (no partial mutation).
    if type(action.assignments) ~= "table" then
        Log:warning("%s rule=%s op=naming husbandry=%s farm=%s: alphabetical action missing assignments - skipped (no wage)",
            LOG_PREFIX, tostring(action.ruleId), tostring(action.husbandryId), tostring(farmId))
        return false, false, "bad-data"
    end
    for _, entry in ipairs(action.assignments) do
        if type(entry) ~= "table" or type(entry.animal) ~= "table" or type(entry.name) ~= "string" then
            Log:warning("%s rule=%s op=naming husbandry=%s farm=%s: malformed assignment entry - skipped (no wage)",
                LOG_PREFIX, tostring(action.ruleId), tostring(action.husbandryId), tostring(farmId))
            return false, false, "bad-data"
        end
    end

    -- Write + broadcast only RESOLVED members (entry.animal resolved in the live cluster); an absent
    -- assignment animal is a membershipSkip. count = named and skippedCount = membershipSkips both
    -- derive from THIS loop (not count - named), so an empty/short assignments list - a planner
    -- cardinality anomaly, never a membership miss - reports 0 membership skips, not #animals.
    local named = 0
    local membershipSkips = 0
    for _, entry in ipairs(action.assignments) do
        local animal = resolveMember(clusterAnimals, entry.animal, action, farmId)
        if animal ~= nil then
            animal.name = entry.name
            ctx.server:broadcastEvent(AnimalNameChangeEvent.new(placeable, animal, entry.name))
            Log:debug("%s rule=%s op=naming(alpha) husbandry=%s farm=%s: broadcast AnimalNameChangeEvent uniqueId=%s name=%s",
                LOG_PREFIX, tostring(action.ruleId), tostring(action.husbandryId), tostring(farmId), tostring(animal.uniqueId), tostring(entry.name))
            named = named + 1
        else
            membershipSkips = membershipSkips + 1
        end
    end

    -- Persist the advanced cursor once per rule (server-only, no broadcast - clients never run the
    -- naming day-tick). The cursor persists whenever the action survives data validation - partial
    -- AND all-skipped (the planner already consumed those names; sequence gaps are cosmetic and keep
    -- the cursor planner-consistent). Only a bad-data drop returns before reaching here.
    if action.previousOut ~= nil then
        ctx.ruleService:setNamingCursor(action.ruleId, action.previousOut)
    end

    -- "not-in-husbandry" requires >= 1 membership skip AND zero writes; an empty-assignments planner
    -- violation (named=0, membershipSkips=0) is NOT a membership skip - it dispatches with count 0 and
    -- skippedCount 0 (membershipSkips carries the real skip count to the row).
    if named == 0 and membershipSkips > 0 then
        return true, false, "not-in-husbandry", 0, membershipSkips
    end
    return true, true, nil, named, membershipSkips
end

--- AI (insemination): exec zips the parallel animals + dewars arrays into the event's
--- { animal, dewar } items and broadcasts AIAnimalInseminationEvent (the event applies
--- setInsemination + dewar:changeStraws(-1) itself - T3 does NOT decrement straws). NO
--- validate (legacy has none). mark sets AI_MANAGER_INSEMINATE.
---@param action table
---@param ctx table
---@param placeable table
---@param farmId number
---@param count number
---@return boolean chargeWage
---@return boolean dispatched
---@return string|nil skipReason
---@return number|nil actualMarked nil on the unguarded ai exec leg; count marked on the mark leg
---@return number|nil skippedCount membership-skip count on the mark leg (nil on the unguarded exec leg)
function RLHerdsmanExecutor._doAi(action, ctx, placeable, farmId, count)
    if action.mark == true then
        return setMarkOnAll(ctx, placeable, action, MARK_BY_OPERATION.ai, farmId)
    end

    -- The planner emits plain-data uniqueId strings (RLHerdsmanPlanner stays data-only for headless
    -- purity). The event wires the dewar as a network node object, so resolve each
    -- string to the LIVE server-side dewar here (a server-side uniqueId lookup is fine). A nil/empty
    -- string OR a string that resolves to no live dewar fails the WHOLE action bad-data (no wage, no
    -- dispatch) - parity with the existing all-or-nothing early-returns, keeping #items == count.
    local dewars = action.dewars
    if type(dewars) ~= "table" or #dewars ~= count then
        Log:warning("%s rule=%s op=ai husbandry=%s farm=%s: animals/dewars length mismatch (%d vs %s) - skipped (no wage)",
            LOG_PREFIX, tostring(action.ruleId), tostring(action.husbandryId), tostring(farmId),
            count, tostring(type(dewars) == "table" and #dewars or dewars))
        return false, false, "bad-data"
    end

    local farmDewars = g_dewarManager:getDewarsByFarm(farmId)

    local items = {}
    for i = 1, count do
        local dewarUniqueId = dewars[i]
        if type(dewarUniqueId) ~= "string" or dewarUniqueId == "" then
            Log:warning("%s rule=%s op=ai husbandry=%s farm=%s: dewar[%d] not a non-empty string (%s) - skipped (no wage)",
                LOG_PREFIX, tostring(action.ruleId), tostring(action.husbandryId), tostring(farmId), i, tostring(dewarUniqueId))
            return false, false, "bad-data"
        end

        -- Resolve to the live dewar in the target animal's type bucket - the same match the event's
        -- old server loop performed (getDewarsByFarm[animalTypeIndex] -> uniqueId compare).
        local animal = action.animals[i]
        local bucket = farmDewars and animal and farmDewars[animal.animalTypeIndex]
        local dewar
        if type(bucket) == "table" then
            for _, d in pairs(bucket) do
                if d:getUniqueId() == dewarUniqueId then dewar = d break end
            end
        end

        if dewar == nil then
            Log:warning("%s rule=%s op=ai husbandry=%s farm=%s: dewar[%d] uniqueId=%s resolved to no live dewar - skipped (no wage)",
                LOG_PREFIX, tostring(action.ruleId), tostring(action.husbandryId), tostring(farmId), i, tostring(dewarUniqueId))
            return false, false, "bad-data"
        end

        items[i] = { animal = animal, dewar = dewar }
    end

    ctx.server:broadcastEvent(AIAnimalInseminationEvent.new(placeable, items), true)
    Log:debug("%s rule=%s op=ai husbandry=%s farm=%s: dispatched %d insemination item(s)",
        LOG_PREFIX, tostring(action.ruleId), tostring(action.husbandryId), tostring(farmId), count)
    return true, true, nil
end

--- Move: exec broadcasts AIAnimalMoveEvent (the event resolves the live source clusters + relocates
--- them to the dest husbandry on the server); mark sets AI_MANAGER_MOVE on the source-pen animals.
--- Unlike sell/buy/ai, move has NO legacy analog - it is a new server-authoritative AI event, NOT a
--- broadcast of the player AnimalMoveEvent (which is request/response and cannot be server-broadcast).
---
--- Mark mode is DEST-INDEPENDENT and checked FIRST: it marks source-pen animals, so a missing /
--- degenerate dest must not block it (parity with the sell mark leg). The exec leg then fails CLOSED
--- on the structural problems (dest == source, or dest absent from ctx) with NO wage, and charges the
--- wage on a validate REJECTION (no-space / unsupported-type) - the same posture buy uses (wage on a
--- validate reject, none on a bad-data early return). Validation is TYPE-level: a husbandry source pen
--- is single-type, so one representative subtype answers dest type-support + total free slots
--- (@see AIAnimalMoveEvent.validate); no per-subtype loop. Move is an UNGUARDED event-dispatched leg
--- (AIAnimalMoveEvent:run resolves membership itself), so it reports the planned count + skippedCount 0
--- and charges the planned wage - no actual/planned scaling (that is the mark + other guarded legs only).
---@param action table
---@param ctx table
---@param placeable table the already-resolved SOURCE husbandry placeable
---@param farmId number
---@param count number
---@return boolean chargeWage
---@return boolean dispatched
---@return string|nil skipReason
---@return number|nil actualMarked nil on the unguarded move exec leg; count marked on the mark leg
---@return number|nil skippedCount membership-skip count on the mark leg (nil on the unguarded exec leg)
function RLHerdsmanExecutor._doMove(action, ctx, placeable, farmId, count)
    if action.mark == true then
        return setMarkOnAll(ctx, placeable, action, MARK_BY_OPERATION.move, farmId)
    end

    -- Structural fail-closed (no wage), checked BEFORE validate: a same-pen move is a no-op. The
    -- slice-5 picker prevents authoring it; this is the defensive backstop.
    if action.destinationHusbandry == action.husbandryId then
        Log:warning("%s rule=%s op=move husbandry=%s farm=%s: destination == source - skipped (no-op, no wage)",
            LOG_PREFIX, tostring(action.ruleId), tostring(action.husbandryId), tostring(farmId))
        return false, false, "bad-data"
    end

    -- Dest resolves DI-purely from the owner-farm uniqueId->placeable maps the source came from:
    -- husbandry first, then the EPP (butcher) map. An owner-farm dest is guaranteed a
    -- member (the picker only offers owner-farm dests), so no g_* read / RLHusbandryTargetKey.resolve
    -- is needed, keeping the decision path dual-runnable. eppPlaceablesById is nil-tolerated (treated
    -- as empty - the always-set-possibly-empty contract), so no-EPP-mod falls straight through to
    -- the existing missing-dest / husbandry paths. An absent dest is a barn/butcher deleted or
    -- transferred since the rule was authored.
    local dest = ctx.husbandryPlaceablesById[action.destinationHusbandry]
    if dest == nil then
        dest = (ctx.eppPlaceablesById or {})[action.destinationHusbandry]
    end
    if dest == nil then
        Log:warning("%s rule=%s op=move husbandry=%s farm=%s: destination '%s' not in ctx - skipped (no dispatch, no wage)",
            LOG_PREFIX, tostring(action.ruleId), tostring(action.husbandryId), tostring(farmId), tostring(action.destinationHusbandry))
        return false, false, "missing-dest"
    end

    -- EPP (butcher) dest: unwrap the production point and run the delivery-time age filter +
    -- all-or-nothing capacity gate in the pinned order. A husbandry dest has no
    -- spec_extendedProductionPoint, so this branch is skipped and the existing husbandry path runs
    -- byte-identical (nil-guarded, zero change when the EPP mod is absent).
    local eppSpec = dest.spec_extendedProductionPoint
    if eppSpec ~= nil and eppSpec.productionPoint ~= nil then
        return RLHerdsmanExecutor._doMoveToEPP(action, ctx, placeable, dest, eppSpec.productionPoint, farmId, count)
    end

    -- TYPE-level gate (one representative subtype: the source pen is single-type). A reject still
    -- charges the wage (buy parity); this is the R3-at-execute overflow (slice 3 leaves the dest uncapped).
    local errorCode = AIAnimalMoveEvent.validate(placeable, dest, count, action.animals[1].subTypeIndex)
    if errorCode == AnimalMoveEvent.MOVE_ERROR_NOT_ENOUGH_SPACE then
        Log:warning("%s rule=%s op=move husbandry=%s farm=%s count=%d: destination has no room - dispatch skipped (wage charged)",
            LOG_PREFIX, tostring(action.ruleId), tostring(action.husbandryId), tostring(farmId), count)
        return true, false, "no-space"
    elseif errorCode == AnimalMoveEvent.MOVE_ERROR_ANIMAL_NOT_SUPPORTED then
        Log:warning("%s rule=%s op=move husbandry=%s farm=%s: destination does not support the animal type - dispatch skipped (wage charged)",
            LOG_PREFIX, tostring(action.ruleId), tostring(action.husbandryId), tostring(farmId))
        return true, false, "bad-data"
    elseif errorCode ~= nil then
        Log:warning("%s rule=%s op=move husbandry=%s farm=%s: validate rejected (errorCode=%s) - dispatch skipped (wage charged)",
            LOG_PREFIX, tostring(action.ruleId), tostring(action.husbandryId), tostring(farmId), tostring(errorCode))
        return true, false, "bad-data"
    end

    -- broadcastEvent(..., true) runs the local :run SYNCHRONOUSLY, so two moves to the same dest the
    -- same tick do not over-fill: the first move's updateNow reduces the dest's free slots before the
    -- second _doMove's validate reads them (the same synchronicity sell/buy rely on).
    ctx.server:broadcastEvent(AIAnimalMoveEvent.new(placeable, dest, action.animals), true)
    Log:debug("%s rule=%s op=move husbandry=%s farm=%s: broadcast AIAnimalMoveEvent dest=%s count=%d",
        LOG_PREFIX, tostring(action.ruleId), tostring(action.husbandryId), tostring(farmId), tostring(action.destinationHusbandry), count)
    return true, true, nil
end

--- Move to an EPP (butcher) destination: player-move-FACING parity - the delivery-time age
--- filter + the same delivery primitive - with two DELIBERATE divergences (placeable-keyed transport;
--- ALL-OR-NOTHING capacity). PINNED order:
---   1. typeData PRESENCE on the SOURCE pen's type index (placeable:getAnimalTypeIndex() - single-type
---      pen, in-ctx, no g_*) BEFORE any age read; nil -> ANIMAL_NOT_SUPPORTED reject, wage charged.
---   2. age filter over action.animals vs typeData.minimumAge/.maximumAge (player-path `or 0`/`or 999`
---      defaults); out-of-window animals are skipped-for-age (counted, surfaced).
---   3. eligible == 0 -> no dispatch, skipReason "all-age-ineligible", wage charged.
---   4. space/subtype validate on the ELIGIBLE count (AIAnimalMoveEvent.validate unwraps the pp);
---      ALL-OR-NOTHING - a reject skips the WHOLE dispatch (wage charged), skipped-age still surfaced.
---   5. dispatch the eligible only via AIAnimalMoveEvent (targetObject = the EPP PLACEABLE; the event
---      unwraps + delivers via the shipped player-path primitive).
--- Counts ride the SCALING-FREE extra channel ({ movedCount, skippedAge }); actualCount stays nil so
--- the wage is planned. @see RLHerdsmanExecutor._executeOne (the extra merge). Butcher free slots are
--- logged at validate to make the same-tick slot-sync residual visible (Design Notes).
---@param action table
---@param ctx table
---@param placeable table the resolved SOURCE husbandry placeable (single-type pen)
---@param dest table the resolved EPP destination PLACEABLE (carries spec_extendedProductionPoint)
---@param pp table the unwrapped production point (dest.spec_extendedProductionPoint.productionPoint)
---@param farmId number
---@param count number planned animal count
---@return boolean chargeWage
---@return boolean dispatched
---@return string|nil skipReason
---@return nil actualCount always nil (the EPP move never scales the wage)
---@return nil skippedCount always nil
---@return table extra { movedCount, skippedAge }
function RLHerdsmanExecutor._doMoveToEPP(action, ctx, placeable, dest, pp, farmId, count)
    -- 1. typeData PRESENCE (before any age read). The source pen is single-type; its type index
    -- keys the butcher's animalsTypeData. getAnimalTypeIndex is the source placeable's own method
    -- (in-ctx, no g_*), the same read the planner ctx uses for the pen type.
    local typeIndex = placeable.getAnimalTypeIndex ~= nil and placeable:getAnimalTypeIndex() or nil
    local typeData = (typeIndex ~= nil and type(pp.animalsTypeData) == "table") and pp.animalsTypeData[typeIndex] or nil
    if typeData == nil then
        Log:warning("%s rule=%s op=move husbandry=%s farm=%s: butcher does not accept the pen type (typeIndex=%s) - ANIMAL_NOT_SUPPORTED, dispatch skipped (wage charged)",
            LOG_PREFIX, tostring(action.ruleId), tostring(action.husbandryId), tostring(farmId), tostring(typeIndex))
        return true, false, "bad-data"
    end

    -- 2. Delivery-time age filter (player-move parity: same minimumAge/maximumAge, same `or 0`/`or 999`
    -- defaults). animal.age is the pen animal's live age (in RLRM the cluster IS the Animal).
    local minAge = typeData.minimumAge or 0
    local maxAge = typeData.maximumAge or 999
    local eligible = {}
    local skippedAge = 0
    for _, animal in ipairs(action.animals) do
        local age = (type(animal) == "table" and animal.age) or 0
        if age >= minAge and age <= maxAge then
            eligible[#eligible + 1] = animal
        else
            skippedAge = skippedAge + 1
        end
    end
    Log:info("%s rule=%s op=move husbandry=%s farm=%s: butcher age filter (window %d-%d) -> %d eligible, %d skipped-age of %d",
        LOG_PREFIX, tostring(action.ruleId), tostring(action.husbandryId), tostring(farmId), minAge, maxAge, #eligible, skippedAge, count)

    -- 3. All eligible filtered out: no dispatch, wage charged (buy/no-space parity), skipped-age still surfaced.
    if #eligible == 0 then
        Log:warning("%s rule=%s op=move husbandry=%s farm=%s: all %d animal(s) age-ineligible for the butcher - dispatch skipped (wage charged)",
            LOG_PREFIX, tostring(action.ruleId), tostring(action.husbandryId), tostring(farmId), count)
        return true, false, "all-age-ineligible", nil, nil, { movedCount = 0, skippedAge = skippedAge }
    end

    -- 4. Space + subtype validate on the ELIGIBLE count (validate unwraps the pp). ALL-OR-NOTHING: a
    -- no-space / unsupported-subtype reject skips the WHOLE dispatch (deliberate divergence from the
    -- player UI's part-fill - Design Notes), wage charged, skipped-age still surfaced. Log the butcher's
    -- free slots at validate to make the same-tick slot-sync residual visible.
    -- Representative subtype = the FIRST ELIGIBLE animal's (a survivor of the age filter), not
    -- action.animals[1] which could be an age-dropped animal of a different subtype in a hypothetical
    -- multi-subtype pen. #eligible >= 1 is guaranteed here (the eligible==0 early-return above).
    local repSubTypeIndex = eligible[1].subTypeIndex
    local freeSlots = (pp.getNumOfFreeAnimalSlots ~= nil) and pp:getNumOfFreeAnimalSlots(repSubTypeIndex) or nil
    Log:info("%s rule=%s op=move husbandry=%s farm=%s: butcher free slots at validate = %s (need %d eligible)",
        LOG_PREFIX, tostring(action.ruleId), tostring(action.husbandryId), tostring(farmId), tostring(freeSlots), #eligible)

    local errorCode = AIAnimalMoveEvent.validate(placeable, dest, #eligible, repSubTypeIndex)
    if errorCode == AnimalMoveEvent.MOVE_ERROR_NOT_ENOUGH_SPACE then
        Log:warning("%s rule=%s op=move husbandry=%s farm=%s: butcher has no room for %d eligible (ALL-OR-NOTHING) - dispatch skipped (wage charged)",
            LOG_PREFIX, tostring(action.ruleId), tostring(action.husbandryId), tostring(farmId), #eligible)
        return true, false, "no-space", nil, nil, { movedCount = 0, skippedAge = skippedAge }
    elseif errorCode ~= nil then
        Log:warning("%s rule=%s op=move husbandry=%s farm=%s: butcher validate rejected (errorCode=%s) - dispatch skipped (wage charged)",
            LOG_PREFIX, tostring(action.ruleId), tostring(action.husbandryId), tostring(farmId), tostring(errorCode))
        return true, false, "bad-data", nil, nil, { movedCount = 0, skippedAge = skippedAge }
    end

    -- 5. Dispatch the eligible animals only. targetObject is the EPP PLACEABLE (MP-stable node-object);
    -- AIAnimalMoveEvent:run unwraps the pp and delivers via the shipped player-path primitive.
    ctx.server:broadcastEvent(AIAnimalMoveEvent.new(placeable, dest, eligible), true)
    Log:debug("%s rule=%s op=move husbandry=%s farm=%s: broadcast AIAnimalMoveEvent to butcher dest=%s eligible=%d skippedAge=%d",
        LOG_PREFIX, tostring(action.ruleId), tostring(action.husbandryId), tostring(farmId), tostring(action.destinationHusbandry), #eligible, skippedAge)
    return true, true, nil, nil, nil, { movedCount = #eligible, skippedAge = skippedAge }
end
