-- RLHerdsmanExecutor.lua
-- The in-game executor wall: turns the pure plan from RLHerdsmanPlanner.planActions into
-- mutations. It dispatches AIAnimalSellEvent / AIAnimalBuyEvent / AIAnimalInseminationEvent /
-- AIAnimalMoveEvent, applies castrate + naming + horse care as direct server-side field writes and
-- broadcasts the matching per-animal event (caller-mutates-first, no sendLocal) so those writes
-- sync to clients, sets the AI_MANAGER_* mark for mark-mode actions, persists the naming cursor,
-- and deducts the herdsman wage once per farm via MoneyType.HERDSMAN_WAGES.
--
-- Membership backstop: before each DIRECT mutation the executor resolves the action's animal in the
-- husbandry's LIVE cluster by three-field identity - the same check AnimalCastrateEvent:run performs
-- - and mutates the RESOLVED object. An animal not in the cluster at execute time is skipped with
-- one warning while its siblings proceed, so a plan/execute divergence can never mutate a
-- dealer-pool or foreign animal. The event-dispatched legs carry no such guard: their events resolve
-- membership themselves.
--
-- The executor makes NO candidate decisions - the plan is authoritative, and it obeys action.mark /
-- action.wage / action.animals verbatim without selecting, capping, sorting or reordering. It does
-- not clear stale marks (the day-tick does that, before execute) and emits no player notifications
-- (RLHerdsmanMessages does, from the summary this returns).
--
-- No g_* reads: the dispatch boundary arrives through `ctx`, so the DECISIONS are dual-run.
--   ctx = {
--     server                  = g_server,                        -- broadcastEvent(event, true)
--     mission                 = g_currentMission,                -- addMoney (wage)
--     husbandryPlaceablesById = { [uniqueId] = <placeable> },    -- event object, getOwnerFarmId, getNumOfFreeAnimalSlots
--     ruleService             = <RLHerdsmanRuleService>,         -- setNamingCursor(id, previous)
--     animalNameSystem        = <real AnimalNameSystem>,         -- getRandomName(gender)
--     defer                   = function(fn) ... end,            -- run fn after the current day-change chain
--   }
--
-- `defer` is a STRUCTURAL dep rather than a defaulted one: horse care is the one deferred leg, and a
-- missing seam would leave it silently never writing while the wage is still charged. It is checked
-- for CALLABILITY, so a non-callable cannot pass, and the client guard runs first so the fail-loud
-- binds server-side only.
--
-- summary (return value):
--   summary = {
--     wageByFarm = { [farmId] = number },         -- one deduction per farm with > 0
--     results    = { <one row per plan action, in plan order> },
--   }
-- A result row: { ruleId, husbandryId, farmId, operation, count, skippedCount, mark, amountGained,
--   amountSpent, dispatched, skipReason }. `dispatched` is true iff the broadcast or direct mutation
--   was applied; `skipReason` is nil when dispatched, else one of "no-space" | "no-money" |
--   "mark-mode" | "missing-placeable" | "missing-dest" | "bad-data" | "not-in-husbandry" |
--   "defer-failed" | "all-age-ineligible" | "all-sick". The wage follows each leg's chargeWage, not
--   the reason: "missing-dest" and "defer-failed" never charge, "bad-data" and "missing-placeable"
--   charge only where the leg says so (a validate rejection does, a data-skip does not), and every other
--   reason charges. On a guarded direct-mutation leg `count` is the count ACTUALLY mutated or marked and
--   `skippedCount` the membership-skip count; the unguarded legs report the planned count with
--   skippedCount 0. An exec leg whose animals ALL skip membership reports "not-in-husbandry"; a mark
--   leg whose animals all skip keeps "mark-mode", whose identity the message layer depends on.

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

--- Finite-number guard: rejects nil / non-number / NaN / +-inf, so an amount that would crash an
--- event's validate arithmetic fails closed instead.
---@param v any
---@return boolean
local function isFiniteNumber(v)
    return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

--- Resolve the herdsman wage contribution for an action, failing closed: a non-finite wage is
--- treated as 0 with a warning, never raising.
---@param action table
---@return number
local function resolveWage(action)
    if isFiniteNumber(action.wage) then return action.wage end
    Log:warning("%s rule=%s op=%s: non-number wage (%s) - treating as 0",
        LOG_PREFIX, tostring(action.ruleId), tostring(action.operation), tostring(action.wage))
    return 0
end

--- Resolve the action's husbandry cluster animal list ONCE per action, without raising: a missing
--- method or a non-table cluster / .animals returns nil, so the caller whole-action skips as
--- bad-data with no wage and no prefix mutation. @see AnimalCastrateEvent.run.
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

--- Membership guard: resolve `probe` to the LIVE cluster object by three-field identity. Logs one
--- warning and returns nil when the probe is malformed or is not a current member, so the caller
--- skips THAT animal and siblings proceed. Returns the RESOLVED cluster object to mutate and
--- broadcast, never the probe.
---@param clusterAnimals table the cluster animal list from resolveClusterAnimals
---@param probe table the action's animal reference
---@param action table for the warning row (ruleId / operation / husbandryId)
---@param farmId number for the warning row
---@return table|nil resolved the live cluster animal, or nil to skip this animal
local function resolveMember(clusterAnimals, probe, action, farmId)
    -- Guard before indexing, so the never-raises contract holds for any junk entry rather than only
    -- for nil-field animals.
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

--- Mark-mode leg, shared by sell / castrate / ai / move: set the AI_MANAGER_* mark on every RESOLVED
--- cluster member and broadcast AnimalMarkEvent per animal so the mark syncs to MP clients.
--- A mark row ALWAYS reports dispatched=false with skipReason="mark-mode" regardless of how many
--- resolved, because the message layer keys off that identity. Fails CLOSED two ways: a nil markKey
--- skips the whole action while keeping the mark-mode wage, because AnimalMarkEvent treats a nil key
--- as a destructive clear-ALL; an unavailable cluster skips as bad-data with no wage.
---@see resolveMember
---@see AnimalMarkEvent.new
---@see RLAnimalInfoService.markAnimal
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
            -- Broadcast WITHOUT sendLocal: AnimalMarkEvent:run applies setMarked on server AND
            -- client, and the server already marked above. @see RLAnimalInfoService.markAnimal.
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

--- Emit the single uniform greppable per-action trace row, read from the result table so every exit
--- path - the early fail-closed skips included - logs exactly one identical DEBUG row.
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

--- Apply the planned actions in-game, server-only: per action dispatch the event or apply the direct
--- mutation, or set the mark for a mark-mode action; accumulate the herdsman wage per farm and
--- deduct it once per farm at the end. Fails LOUD on a missing STRUCTURAL ctx dep (a day-tick wiring
--- bug) and fails CLOSED - skip plus a warning, never raising - on a per-action data problem.
---@param plan table|nil ordered action records from RLHerdsmanPlanner.planActions
---@param ctx table dispatch context (server, mission, husbandryPlaceablesById, ruleService, animalNameSystem)
---@return table summary { wageByFarm = { [farmId]=number }, results = { <row per action> } }
function RLHerdsmanExecutor.executeActions(plan, ctx)
    local summary = { wageByFarm = {}, results = {} }

    -- A dedicated server has g_server ~= nil, so guarding on ctx.server correctly includes dedis.
    if ctx == nil or ctx.server == nil then
        Log:debug("%s not server (ctx.server==nil) - no dispatch / mutation / money; empty summary", LOG_PREFIX)
        return summary
    end

    -- A missing structural dep is a day-tick wiring bug, never a silent no-op that would hide a
    -- broken tick. `defer` is checked for CALLABILITY: a `== nil` check would let a non-callable
    -- through to the horse-care arm, where calling it raises far from the cause.
    if ctx.mission == nil or ctx.ruleService == nil or ctx.animalNameSystem == nil
        or ctx.husbandryPlaceablesById == nil or type(ctx.defer) ~= "function" then
        -- One convention for all five: present-and-usable as a boolean, so the reader does not have
        -- to work out which field uses which format.
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

    -- First-seen farm order, so the per-farm wage deduction is deterministic across runners.
    local wageFarmOrder = {}

    for _, action in ipairs(plan) do
        local result = RLHerdsmanExecutor._executeOne(action, ctx, summary, wageFarmOrder)
        summary.results[#summary.results + 1] = result
    end

    -- One HERDSMAN_WAGES deduction per farm with a positive accrued wage, in first-seen plan order.
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

--- Resolve one action and apply it, accumulating any farm-attributed wage into summary.wageByFarm.
--- Never raises: per-action problems fail closed.
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

    -- The records carry only husbandryId, never farmId.
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

    -- Each branch returns (chargeWage, dispatched, skipReason). A data-skip returns chargeWage=false
    -- and the action is dropped; chargeWage=true charges regardless of the dispatch outcome, because
    -- the wage is charged independently of dispatch. A guarded direct-mutation leg adds a 4th value
    -- (the count ACTUALLY mutated or marked) and a 5th (its own membership-skip count), both nil from
    -- the unguarded legs. `extra` is the SCALING-FREE row channel: only the move EPP leg returns it,
    -- a { movedCount, skippedAge, skippedSick } table merged onto the row without touching
    -- actualCount, so its wage stays planned.
    local op = action.operation
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

    -- A guarded leg reports its OWN membership-skip count, not `count - actualCount`, which would
    -- fabricate skips for a planner cardinality anomaly such as an empty-assignments naming action.
    if actualCount ~= nil then
        result.count = actualCount
        result.skippedCount = skippedCount or 0
    end

    -- movedCount = animals dispatched to the butcher, falling back to count for husbandry rows;
    -- skippedAge / skippedSick = animals filtered out for age / for showing symptoms. Husbandry-move
    -- and non-move rows carry no extra.
    if type(extra) == "table" then
        result.movedCount = extra.movedCount
        result.skippedAge = extra.skippedAge
        result.skippedSick = extra.skippedSick
    end

    if chargeWage then
        -- Wage follows the ACTUAL acted-on count on a guarded leg, so a membership skip is never paid
        -- for. Exact for the linear castrate/naming formulas, an accepted approximation for the
        -- mark-mode component. count > 0 here, so the divisor is safe.
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

--- Sell: exec broadcasts AIAnimalSellEvent, which deducts MoneyType.SOLD_ANIMALS on the server's
--- cluster-batch success; mark sets AI_MANAGER_SELL. Wage charged either way.
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

    -- Defensive: AIAnimalSellEvent.validate returns non-nil only on object == nil, which the
    -- missing-placeable guard already caught.
    local errorCode = AIAnimalSellEvent.validate(placeable, count, action.amountGained, farmId)
    if errorCode ~= nil then
        Log:warning("%s rule=%s op=sell husbandry=%s farm=%s: validate rejected (errorCode=%s) - dispatch skipped (wage charged)",
            LOG_PREFIX, tostring(action.ruleId), tostring(action.husbandryId), tostring(farmId), tostring(errorCode))
        return true, false, "missing-placeable"
    end

    ctx.server:broadcastEvent(AIAnimalSellEvent.new(placeable, action.animals, action.amountGained), true)
    return true, true, nil
end

--- Buy (no mark param): exec runs AIAnimalBuyEvent.validate - the real runtime gate on free slots and
--- money - then broadcasts the event. A validate rejection skips dispatch but still charges the wage.
--- validate's money check reads the GLOBAL g_currentMission, so in production ctx.mission MUST be
--- g_currentMission or the buy money-gate silently diverges from the wage ledger.
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

--- Castrate: exec sets isCastrated and zeroes genetics.fertility per animal, then broadcasts
--- AnimalCastrateEvent per animal so clients sync; mark sets AI_MANAGER_CASTRATE.
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

    -- Validate EVERY animal's genetics table BEFORE mutating, so a malformed animal drops the whole
    -- action instead of castrating a prefix and then raising. Corrupt action data fails the whole
    -- action regardless of membership.
    for _, animal in ipairs(action.animals) do
        if type(animal.genetics) ~= "table" then
            Log:warning("%s rule=%s op=castrate husbandry=%s farm=%s: animal has no genetics table - skipped (no wage)",
                LOG_PREFIX, tostring(action.ruleId), tostring(action.husbandryId), tostring(farmId))
            return false, false, "bad-data"
        end
    end

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
            -- Mirror AnimalCastrateEvent:run on the RESOLVED object. The genetics TYPE check, not
            -- merely `~= nil`, keeps a divergent resolved object from raising.
            animal.isCastrated = true
            if type(animal.genetics) == "table" then
                animal.genetics.fertility = 0
            end
            -- Broadcast WITHOUT sendLocal: the event applies on server AND client, and the server
            -- already mutated above. @see RLAnimalInfoService.castrateAnimal.
            ctx.server:broadcastEvent(AnimalCastrateEvent.new(placeable, animal))
            Log:debug("%s rule=%s op=castrate husbandry=%s farm=%s: broadcast AnimalCastrateEvent uniqueId=%s",
                LOG_PREFIX, tostring(action.ruleId), tostring(action.husbandryId), tostring(farmId), tostring(animal.uniqueId))
            actual = actual + 1
        else
            skipped = skipped + 1
        end
    end

    -- Every animal skipped membership: a genuine all-skip exec row, distinct from the mark-mode and
    -- bad-data skips, and the wage scales to 0.
    if actual == 0 then
        return true, false, "not-in-husbandry", 0, skipped
    end
    return true, true, nil, actual, skipped
end

--- The full-care values. `riding` is written ABSOLUTE; dirt is cleared by a -100 DELTA, because
--- changeDirt is the only mutator the Animal prototype exposes - so on a corrupt save carrying
--- dirt > 100 the clear is PARTIAL, and the per-animal DEBUG row's before/after makes that visible.
---
--- 100 rather than a lower level because every care level has a `daysPerPeriod` above which its
--- fitness gain floors to zero, and 100 is the only one that survives the season lengths players
--- actually run. At the 0.4 default threshold care merely FREEZES fitness, and below it care
--- actively DECAYS fitness while still billing the wage.
local HORSE_CARE_RIDING = 100
local HORSE_CARE_DIRT_DELTA = -100

--- The DEFERRED half of the horse-care leg: re-validate membership, then write. It runs outside the
--- day-tick's own safeCall, so it carries its own per-animal isolation - one malformed horse must
--- not abort the loop and leave every sibling unwritten after the full wage was charged.
---
--- Membership is re-resolved rather than trusted: a horse can leave the pen between arming and
--- firing (mounted, loaded into a trailer, sold). The row already reported it as acted-on, and
--- writing to a non-member would be worse than the count being one optimistic.
---@param action table the horse-care action (ruleId / husbandryId for the log rows)
---@param placeable table husbandry placeable owning the cluster
---@param planned table[] the INLINE-resolved live cluster animals
---@param farmId number owning farm (log context)
---@return nil the row and wage were committed when the action was armed; this half cannot retract them
function RLHerdsmanExecutor._writeHorseCare(action, placeable, planned, farmId)
    local clusterAnimals = resolveClusterAnimals(placeable)
    -- An EMPTY list is the teardown signal and aborts ONCE; without this case every probe would fail
    -- membership and emit its own warning for a husbandry that no longer exists. Base onDelete nils
    -- clusterHusbandry but never clusterSystem, and AnimalClusterSystem:delete sets animals = {}, so
    -- the torn-down shape is {} rather than nil.
    if clusterAnimals == nil or #clusterAnimals == 0 then
        -- Distinguish a cluster system that is GONE from a live pen that merely emptied during this
        -- same day-change chain; reporting the second as "cluster gone" misdirects diagnosis.
        local torn = type(placeable.getClusterSystem) ~= "function" or clusterAnimals == nil
        Log:warning("%s rule=%s op=horseCare husbandry=%s farm=%s: %s when the deferred write fired - %d planned horse(s) unwritten (aborted once)",
            LOG_PREFIX, tostring(action.ruleId), tostring(action.husbandryId), tostring(farmId),
            torn and "cluster gone (husbandry torn down)" or "pen emptied during this day-change chain",
            #planned)
        -- The summary row is emitted on this path too: the action row already reported these horses
        -- as acted-on and the wage is committed, so applied/skipped must be explicit here.
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
                -- The flag LEADS the two field writes, and that order is the contract: a raise
                -- between the writes must not leave the horse mutated server-side but unflagged,
                -- because under-flagging is a silent MP divergence while over-flagging costs one
                -- extra cluster pass. This leg owns the flag - neither the AnimalHorse mutators nor
                -- the base cluster class sets one - so do not assume a mutator flags on your behalf.
                -- setDirty only marks: the placeable's own update flushes and broadcasts
                -- AnimalClusterUpdateEvent, whose payload already carries dirt / fitness / riding.
                -- Flag-first is safe only because nothing can flush in this window.
                animal:setDirty()
                animal:setRiding(HORSE_CARE_RIDING)
                animal:changeDirt(HORSE_CARE_DIRT_DELTA)
                Log:debug("%s rule=%s op=horseCare husbandry=%s farm=%s: cared uniqueId=%s riding %s->%s dirt %s->%s",
                    LOG_PREFIX, tostring(action.ruleId), tostring(action.husbandryId), tostring(farmId),
                    tostring(animal.uniqueId), tostring(ridingBefore), tostring(animal.riding),
                    tostring(dirtBefore), tostring(animal.dirt))
                return true
            end, { false })
            if ok then applied = applied + 1 else failed = failed + 1 end
        end
    end

    -- ruleId + husbandryId are load-bearing on this row: concurrent pens in one tick emit interleaved
    -- callbacks, and without both there is no way to tell them apart in the log.
    Log:debug("%s rule=%s op=horseCare husbandry=%s farm=%s: deferred write complete applied=%d left-pen=%d failed=%d of %d planned",
        LOG_PREFIX, tostring(action.ruleId), tostring(action.husbandryId), tostring(farmId),
        applied, left, failed, #planned)
end

--- Horse care: write riding = 100 and clear dirt on every planned HORSE, DEFERRED to after the
--- animal day tick - see the file header for why the ordering is the substance.
---
--- Membership resolves INLINE, before arming, so this returns the guarded-leg tuple in the same SHAPE
--- as _doCastrate's. The SEMANTICS differ and a consumer must not confuse them: _doCastrate's `count`
--- counts mutations that have already happened, while this leg's is PREDICTIVE - the writes land one
--- or more frames later and the callback may drop some of them, so a horse sold or mounted between
--- arming and firing is counted here and never written. Anything downstream reading `count` as "work
--- done" is optimistic for this operation alone.
---
--- The leg performs NO animal-type check, by decision: the planner's pen gate is sufficient, because
--- a pen cannot hold a foreign-type animal through any gated path, and a per-animal check here would
--- be this module's first root-global read.
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
    -- The cluster resolve precedes arming, so the bad-data outcome stays reachable: no wage, no timer.
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
        -- Every planned horse skipped membership: the wage scales to 0, and a timer that would write
        -- nothing is not worth scheduling.
        Log:debug("%s rule=%s op=horseCare husbandry=%s farm=%s: all %d planned horse(s) absent from the cluster - nothing armed",
            LOG_PREFIX, tostring(action.ruleId), tostring(action.husbandryId), tostring(farmId), count)
        return true, false, "not-in-husbandry", 0, skipped
    end

    -- Arming is itself guarded: a raising ctx.defer must not take out the remaining actions or the
    -- per-farm wage deduction. safeCall logs the failure, where a silent pcall would hide a broken
    -- seam behind a wage that still gets charged.
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
        -- The seam raised, so nothing will ever write and nothing is charged. Its OWN skipReason, not
        -- "bad-data": that reason already means "no wage" at every other exit, and reusing it for a
        -- case with a live cluster and resolved members would make the two indistinguishable.
        Log:warning("%s rule=%s op=horseCare husbandry=%s farm=%s: the defer seam raised - %d resolved horse(s) will never be written; no wage charged",
            LOG_PREFIX, tostring(action.ruleId), tostring(action.husbandryId), tostring(farmId), actual)
        return false, false, "defer-failed", 0, skipped
    end

    Log:debug("%s rule=%s op=horseCare husbandry=%s farm=%s: armed deferred care for %d horse(s) (%d skipped at membership)",
        LOG_PREFIX, tostring(action.ruleId), tostring(action.husbandryId), tostring(farmId), actual, skipped)
    return true, true, nil, actual, skipped
end

--- Naming: alphabetical writes the planner-assigned names and advances the server-only cursor via
--- ruleService:setNamingCursor; random generates a fresh name per animal and never advances the
--- cursor. Each named animal broadcasts AnimalNameChangeEvent so clients sync. Naming has no mark
--- param, and the wage is always charged.
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
                -- Capture the generated name so the field write and the broadcast carry the SAME
                -- value: an empty name list yields nil and clears the name on both sides.
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
    -- entry BEFORE writing any name, so a malformed entry drops the whole action rather than naming a
    -- prefix and then raising.
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

    -- Both counts derive from THIS loop rather than from `count - named`, so an empty or short
    -- assignments list - a planner cardinality anomaly, never a membership miss - reports 0
    -- membership skips instead of #animals.
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

    -- Persist the advanced cursor once per rule, server-only and unbroadcast. It persists whenever
    -- the action survives data validation, partial and all-skipped alike: the planner already
    -- consumed those names, so sequence gaps are cosmetic and the cursor stays planner-consistent.
    if action.previousOut ~= nil then
        ctx.ruleService:setNamingCursor(action.ruleId, action.previousOut)
    end

    -- "not-in-husbandry" requires at least one membership skip AND zero writes; an empty-assignments
    -- planner violation dispatches with count 0 and skippedCount 0 instead.
    if named == 0 and membershipSkips > 0 then
        return true, false, "not-in-husbandry", 0, membershipSkips
    end
    return true, true, nil, named, membershipSkips
end

--- AI (insemination): exec zips the parallel animals + dewars arrays into the event's
--- { animal, dewar } items and broadcasts AIAnimalInseminationEvent, which applies setInsemination
--- and decrements the straws itself. No validate. mark sets AI_MANAGER_INSEMINATE.
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

    -- The planner emits plain-data uniqueId strings, so resolve each to the LIVE server-side dewar
    -- here. Any unresolvable entry fails the WHOLE action as bad-data - no wage, no dispatch - which
    -- keeps #items == count.
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

        -- Resolve in the target animal's type bucket - the same match the event's own server loop
        -- performed.
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

--- Move: exec broadcasts AIAnimalMoveEvent, which resolves the live source clusters and relocates
--- them on the server; mark sets AI_MANAGER_MOVE on the source-pen animals.
---
--- Mark mode is DEST-INDEPENDENT and checked FIRST, because it marks source-pen animals and a
--- missing dest must not block it. The exec leg then fails CLOSED with no wage on the structural
--- problems - dest == source, or a dest absent from ctx - and charges the wage on a validate
--- REJECTION, the same posture buy uses. Validation is TYPE-level: a husbandry source pen is
--- single-type, so one representative subtype answers dest type-support and free slots. Move is an
--- UNGUARDED event-dispatched leg, so it reports the planned count and charges the planned wage.
---@see AIAnimalMoveEvent.validate
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

    -- A same-pen move is a no-op. The picker prevents authoring one; this is the backstop.
    if action.destinationHusbandry == action.husbandryId then
        Log:warning("%s rule=%s op=move husbandry=%s farm=%s: destination == source - skipped (no-op, no wage)",
            LOG_PREFIX, tostring(action.ruleId), tostring(action.husbandryId), tostring(farmId))
        return false, false, "bad-data"
    end

    -- The dest resolves from the same owner-farm uniqueId maps the source came from - husbandry
    -- first, then EPP - so no g_* read is needed and the decision path stays dual-runnable.
    -- eppPlaceablesById is nil-tolerated, so no-EPP-mod falls through to the husbandry paths. An
    -- absent dest means a barn or butcher was deleted or transferred since the rule was authored.
    local dest = ctx.husbandryPlaceablesById[action.destinationHusbandry]
    if dest == nil then
        dest = (ctx.eppPlaceablesById or {})[action.destinationHusbandry]
    end
    if dest == nil then
        Log:warning("%s rule=%s op=move husbandry=%s farm=%s: destination '%s' not in ctx - skipped (no dispatch, no wage)",
            LOG_PREFIX, tostring(action.ruleId), tostring(action.husbandryId), tostring(farmId), tostring(action.destinationHusbandry))
        return false, false, "missing-dest"
    end

    -- A husbandry dest has no spec_extendedProductionPoint, so the branch is skipped and the
    -- husbandry path runs unchanged when the EPP mod is absent.
    local eppSpec = dest.spec_extendedProductionPoint
    if eppSpec ~= nil and eppSpec.productionPoint ~= nil then
        return RLHerdsmanExecutor._doMoveToEPP(action, ctx, placeable, dest, eppSpec.productionPoint, farmId, count)
    end

    -- TYPE-level gate on one representative subtype. A reject still charges the wage, matching buy.
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

    -- broadcastEvent(..., true) runs the local :run SYNCHRONOUSLY, so two moves to the same dest in
    -- one tick cannot over-fill: the first move's updateNow reduces the dest's free slots before the
    -- second validate reads them.
    ctx.server:broadcastEvent(AIAnimalMoveEvent.new(placeable, dest, action.animals), true)
    Log:debug("%s rule=%s op=move husbandry=%s farm=%s: broadcast AIAnimalMoveEvent dest=%s count=%d",
        LOG_PREFIX, tostring(action.ruleId), tostring(action.husbandryId), tostring(farmId), tostring(action.destinationHusbandry), count)
    return true, true, nil
end

--- Move to an EPP (butcher) destination: player-move parity on the delivery-time age filter and the
--- delivery primitive, with two deliberate divergences - placeable-keyed transport, and ALL-OR-NOTHING
--- capacity. The order is PINNED:
---   1. typeData PRESENCE on the SOURCE pen's type index, BEFORE any age read; nil rejects as
---      ANIMAL_NOT_SUPPORTED with the wage charged.
---   2. age filter over action.animals against typeData.minimumAge/.maximumAge; out-of-window animals
---      are skipped-for-age.
---   2b. sick filter over the age-eligible (RLDiseaseSaleGate); a sick animal is skipped-for-sickness.
---   3. eligible == 0 -> no dispatch, skipReason "all-sick" when any was sick else
---      "all-age-ineligible", wage charged.
---   4. space/subtype validate on the ELIGIBLE count; a reject skips the WHOLE dispatch with the wage
---      charged, and both skip counts still surface.
---   5. dispatch the eligible only, with the EPP PLACEABLE as targetObject.
--- Counts ride the SCALING-FREE extra channel, so the wage stays planned.
--- @see RLHerdsmanExecutor._executeOne for the merge.
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
---@return table extra { movedCount, skippedAge, skippedSick }
function RLHerdsmanExecutor._doMoveToEPP(action, ctx, placeable, dest, pp, farmId, count)
    -- 1. The source pen is single-type, and its type index keys the butcher's animalsTypeData.
    local typeIndex = placeable.getAnimalTypeIndex ~= nil and placeable:getAnimalTypeIndex() or nil
    local typeData = (typeIndex ~= nil and type(pp.animalsTypeData) == "table") and pp.animalsTypeData[typeIndex] or nil
    if typeData == nil then
        Log:warning("%s rule=%s op=move husbandry=%s farm=%s: butcher does not accept the pen type (typeIndex=%s) - ANIMAL_NOT_SUPPORTED, dispatch skipped (wage charged)",
            LOG_PREFIX, tostring(action.ruleId), tostring(action.husbandryId), tostring(farmId), tostring(typeIndex))
        return true, false, "bad-data"
    end

    -- 2. Delivery-time age filter, with the player path's own `or 0` / `or 999` defaults.
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

    -- 2b. The sick gate over the age-eligible only, so skippedAge stays exactly the age count.
    local skippedSick = 0
    if #eligible > 0 then
        local healthy = {}
        for _, animal in ipairs(eligible) do
            if RLDiseaseSaleGate.check(animal) then
                healthy[#healthy + 1] = animal
            else
                skippedSick = skippedSick + 1
                Log:debug("%s rule=%s op=move husbandry=%s farm=%s: skipping sick animal uniqueId=%s for the butcher",
                    LOG_PREFIX, tostring(action.ruleId), tostring(action.husbandryId), tostring(farmId), tostring(animal.uniqueId))
            end
        end
        eligible = healthy
        Log:debug("%s rule=%s op=move husbandry=%s farm=%s: butcher sick filter -> %d eligible, %d skipped-sick",
            LOG_PREFIX, tostring(action.ruleId), tostring(action.husbandryId), tostring(farmId), #eligible, skippedSick)
    end

    -- 3. All eligible filtered out: no dispatch, wage charged, both skip counts still surfaced.
    if #eligible == 0 then
        if skippedSick > 0 then
            Log:warning("%s rule=%s op=move husbandry=%s farm=%s: no animal left for the butcher, %d sick - dispatch skipped (wage charged)",
                LOG_PREFIX, tostring(action.ruleId), tostring(action.husbandryId), tostring(farmId), skippedSick)
            return true, false, "all-sick", nil, nil, { movedCount = 0, skippedAge = skippedAge, skippedSick = skippedSick }
        end
        Log:warning("%s rule=%s op=move husbandry=%s farm=%s: all %d animal(s) age-ineligible for the butcher - dispatch skipped (wage charged)",
            LOG_PREFIX, tostring(action.ruleId), tostring(action.husbandryId), tostring(farmId), count)
        return true, false, "all-age-ineligible", nil, nil, { movedCount = 0, skippedAge = skippedAge, skippedSick = 0 }
    end

    -- 4. The representative subtype is the FIRST ELIGIBLE animal's, not action.animals[1], which
    -- could be an age-dropped animal of a different subtype. The butcher's free slots are logged here
    -- to make the same-tick slot-sync residual visible.
    local repSubTypeIndex = eligible[1].subTypeIndex
    local freeSlots = (pp.getNumOfFreeAnimalSlots ~= nil) and pp:getNumOfFreeAnimalSlots(repSubTypeIndex) or nil
    Log:info("%s rule=%s op=move husbandry=%s farm=%s: butcher free slots at validate = %s (need %d eligible)",
        LOG_PREFIX, tostring(action.ruleId), tostring(action.husbandryId), tostring(farmId), tostring(freeSlots), #eligible)

    local errorCode = AIAnimalMoveEvent.validate(placeable, dest, #eligible, repSubTypeIndex)
    if errorCode == AnimalMoveEvent.MOVE_ERROR_NOT_ENOUGH_SPACE then
        Log:warning("%s rule=%s op=move husbandry=%s farm=%s: butcher has no room for %d eligible (ALL-OR-NOTHING) - dispatch skipped (wage charged)",
            LOG_PREFIX, tostring(action.ruleId), tostring(action.husbandryId), tostring(farmId), #eligible)
        return true, false, "no-space", nil, nil, { movedCount = 0, skippedAge = skippedAge, skippedSick = skippedSick }
    elseif errorCode ~= nil then
        Log:warning("%s rule=%s op=move husbandry=%s farm=%s: butcher validate rejected (errorCode=%s) - dispatch skipped (wage charged)",
            LOG_PREFIX, tostring(action.ruleId), tostring(action.husbandryId), tostring(farmId), tostring(errorCode))
        return true, false, "bad-data", nil, nil, { movedCount = 0, skippedAge = skippedAge, skippedSick = skippedSick }
    end

    -- 5. Dispatch the eligible only. targetObject is the EPP PLACEABLE, an MP-stable node object; the
    -- event unwraps the production point and delivers via the shipped player-path primitive.
    ctx.server:broadcastEvent(AIAnimalMoveEvent.new(placeable, dest, eligible), true)
    Log:debug("%s rule=%s op=move husbandry=%s farm=%s: broadcast AIAnimalMoveEvent to butcher dest=%s eligible=%d skippedAge=%d skippedSick=%d",
        LOG_PREFIX, tostring(action.ruleId), tostring(action.husbandryId), tostring(farmId), tostring(action.destinationHusbandry), #eligible, skippedAge, skippedSick)
    return true, true, nil, nil, nil, { movedCount = #eligible, skippedAge = skippedAge, skippedSick = skippedSick }
end
