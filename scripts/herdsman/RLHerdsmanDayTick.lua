-- RLHerdsmanDayTick.lua
-- The day-tick that runs the herdsman: a MessageType.DAY_CHANGED subscriber that,
-- once per day server-side, runs RLHerdsmanPlanner.planActions -> RLHerdsmanExecutor.executeActions
-- per farm and surfaces the wage.
--
-- Two layers. subscribe()/buildEnv() READ g_* and are the only in-game wiring, registered once
-- from RealisticLivestock_FSBaseMission:onStartMission. run(env) and the ctx builders read NO
-- g_*: they take the injected `env` and return plain data, so the orchestration is unit-tested
-- on real Animals headless, and production differs only in how `env` is built.
--
-- Server-only via the in-handler g_server guard, mirroring RLMessageAggregator: onStartMission
-- registers on ALL peers, so a dedicated server ticks and a client registers an inert listener.
--
-- The executor OWNS the MoneyType.HERDSMAN_WAGES deduction; this module only logs
-- summary.wageByFarm at DEBUG and never re-deducts.
--
-- env contract (raw engine shapes in; buildPlannerCtx/buildExecutorCtx reshape them into the
-- frozen planner/executor ctx):
--   env = {
--     farms                  = { farmRecord, ... },                 -- g_farmManager:getFarms() (SPECTATOR skipped in run)
--     rulesForFarm(farmId)   -> { rule, ... },                      -- ruleService:listForFarm (NOT enabled-filtered; run filters)
--     husbandriesForFarm(id) -> { placeable, ... },                 -- husbandrySystem:getPlaceablesByFarm(EXPLICIT id)
--     rawDealerAnimals(idx)  -> { Animal, ... },                    -- animalSystem:getSaleAnimalsByTypeIndex (live, reserved-INCLUSIVE)
--     filtersById            = { [filterId] = filter },             -- g_rlFilterService:list keyed by id (farm-independent)
--     balanceForFarm(farmId) -> number|nil,                         -- g_farmManager:getFarmById(id):getBalance()
--     dewarsForFarm(farmId)  -> { [typeIndex] = { <dewar OBJECT>, ... } }|nil,  -- g_dewarManager:getDewarsByFarm (RAW objects)
--     buyMarkup              = number,                          -- active dealer-quality markup (buy pricing)
--     dealerQualityIndex     = number|nil,                      -- preset index it came from; DEBUG readout ONLY
--     defer(fn)              -> nil,                            -- run fn after the current DAY_CHANGED chain (horse care only)
--     server, mission, ruleService, animalSystem, animalNameSystem,
--   }
-- `defer` and `buyMarkup` are forwarded verbatim into the executor / planner ctx, where each is a
-- STRUCTURAL dep. Both are resolved here because buildEnv is this module's only g_*-reading layer.
--
-- readout contract (run's return value; surfaced at DEBUG):
--   readout = {
--     farmsProcessed = number,                  -- farms that ran plan/execute (SPECTATOR + no-enabled-rule farms skipped)
--     byFarm = { [farmId] = {                   -- one row per processed farm with enabled rules
--       wage           = number,                -- = summary.wageByFarm[farmId] (0 if none)
--       plannedActions = number,                -- #plan
--       dispatched     = number,                -- executor result rows with dispatched == true
--     } },
--   }

local Log = RmLogging.getLogger("RLRM")

RLHerdsmanDayTick = {}

-- =============================================================================
-- Constants
-- =============================================================================

--- Greppable prefix on every day-tick log line.
local LOG_PREFIX = "[herdsmanTick]"

--- operation -> the AI_MANAGER_* mark the clear-stale pass clears. buy + naming carry no
--- clearable op mark.
local MARK_BY_OPERATION = {
    sell     = "AI_MANAGER_SELL",
    castrate = "AI_MANAGER_CASTRATE",
    ai       = "AI_MANAGER_INSEMINATE",
    move     = "AI_MANAGER_MOVE",
}

-- =============================================================================
-- Internal helpers (pure - no g_*; reshape the injected env into the FROZEN
-- planner/executor ctx, which those modules own. Add nothing to those ctx.)
-- =============================================================================

--- Index a farm's live husbandry placeables by their uniqueId - the key space the rules'
--- targetHusbandries and the executor's husbandryPlaceablesById both use. A duplicate uniqueId
--- WARNs and keeps the last, deterministically, rather than raising.
---@param husbandries table array of husbandry placeables (env.husbandriesForFarm result)
---@return table husbandriesById { [uniqueId] = placeable }
local function indexHusbandriesByUniqueId(husbandries)
    local byId = {}
    for _, placeable in pairs(husbandries) do
        local uid = placeable:getUniqueId()
        if byId[uid] ~= nil then
            Log:warning("%s duplicate husbandry uniqueId '%s' across live placeables - keeping last",
                LOG_PREFIX, tostring(uid))
        end
        byId[uid] = placeable
    end
    return byId
end

--- Index a farm's live owner EPP (butcher) placeables by uniqueId - the SAME key space a move
--- rule's destinationHusbandry uses, so the executor's dest fall-through can resolve one.
--- Nil-tolerant, because EPP is an optional mod: an absent input yields an empty map, never nil.
---@param epps table|nil array of EPP placeables (env.eppsForFarm result)
---@return table eppsById { [uniqueId] = placeable }
local function indexEPPsByUniqueId(epps)
    local byId = {}
    for _, placeable in pairs(epps or {}) do
        local uid = placeable:getUniqueId()
        if byId[uid] ~= nil then
            Log:warning("%s duplicate EPP uniqueId '%s' across live placeables - keeping last",
                LOG_PREFIX, tostring(uid))
        end
        byId[uid] = placeable
    end
    return byId
end

--- Clear each enabled sell/castrate/ai rule's op mark on EVERY animal of its target husbandries,
--- BEFORE the executor runs: executeActions re-SETS the mark for mark-mode actions, so clearing
--- afterwards would wipe a freshly-set one. Each animal cleared also broadcasts AnimalMarkEvent
--- (active=false) through the injected server, caller-mutates-first and no sendLocal, so removals
--- reach MP clients - the CLEAR-direction mirror of @see RLHerdsmanExecutor setMarkOnAll. Clears
--- even when no candidate matches this tick. A target absent from the live placeables is skipped
--- and WARNed. markKey is always a non-nil AI_MANAGER_* key here, so AnimalMarkEvent's destructive
--- clear-all mode is unreachable.
---@param enabledRules table array of ENABLED rules for the farm (run applies the enabled filter)
---@param husbandriesById table { [uniqueId] = placeable }
---@param server any injected server (env.server); broadcast only when non-nil
local function clearStaleMarks(enabledRules, husbandriesById, server)
    for _, rule in ipairs(enabledRules) do
        local markKey = MARK_BY_OPERATION[rule.operation]
        if markKey ~= nil then
            for _, uid in ipairs(rule.targetHusbandries or {}) do
                local placeable = husbandriesById[uid]
                if placeable == nil then
                    Log:warning("%s clearStaleMarks: rule=%s op=%s target husbandry '%s' not live - skipped",
                        LOG_PREFIX, tostring(rule.id), tostring(rule.operation), tostring(uid))
                else
                    for _, animal in pairs(placeable:getClusters()) do
                        RmSafeUtils.safeAnimalCall(animal, "RLHerdsmanDayTick:clearStaleMark", function()
                            -- Only clear a mark that is set.
                            if animal:getMarked(markKey) then
                                animal:setMarked(markKey, false)
                                -- Broadcast WITHOUT sendLocal: AnimalMarkEvent:run applies setMarked
                                -- on server and client alike, and the server already cleared above.
                                if server ~= nil then
                                    server:broadcastEvent(AnimalMarkEvent.new(placeable, animal, markKey, false))
                                    Log:debug("%s clearStaleMarks: broadcast AnimalMarkEvent uniqueId=%s key=%s active=false",
                                        LOG_PREFIX, tostring(animal.uniqueId), tostring(markKey))
                                end
                            end
                        end)
                    end
                end
            end
        end
    end
end

--- Shape the FROZEN planner ctx for ONE farm: husbandries keyed by uniqueId with their type, live
--- clusters and free animal-slot count, the reserved-excluded dealer pool, the farm-scoped balance
--- seed, and the materialized dewar pool. filtersById, the service refs and buyMarkup pass straight
--- through from env.
---@param farm table the farm record (carries farm.farmId)
---@param husbandriesById table { [uniqueId] = placeable } (already deduped by run)
---@param env table the run(env) seam
---@return table plannerCtx the FROZEN RLHerdsmanPlanner.planActions ctx
local function buildPlannerCtx(farm, husbandriesById, env)
    local farmId = farm.farmId
    local husbandries = {}
    local dealerAnimalsByType = {}  -- per-farm memo, keyed by animalTypeIndex (fresh table -> per-farm re-read)

    for uid, placeable in pairs(husbandriesById) do
        local typeIndex = placeable:getAnimalTypeIndex()
        husbandries[uid] = {
            animalTypeIndex = typeIndex,
            animals = placeable:getClusters(),
            -- The planner's Buy slot cap: total free animal slots, mirroring
            -- AIAnimalBuyEvent.validate's space gate.
            freeSlots = placeable:getNumOfFreeAnimalSlots(),
        }
        -- Reserved-exclusion: nothing sets `animal.reserved` TRUE any more, so this filter removes
        -- nothing today - `AnimalSystem:onDayChanged` only clears it. Kept as a cheap guard in case
        -- a reservation producer returns; removing it is a deliberate call, not a tidy-up.
        if dealerAnimalsByType[typeIndex] == nil then
            local pool = {}
            for _, animal in pairs(env.rawDealerAnimals(typeIndex)) do
                if not animal.reserved then pool[#pool + 1] = animal end
            end
            dealerAnimalsByType[typeIndex] = pool
        end
    end

    -- Materialize the raw dewar vehicle objects (DewarManager bucket: {[typeIndex]={dewar,...}}).
    local dewarsByType = {}
    local rawDewars = env.dewarsForFarm(farmId)
    if rawDewars ~= nil then
        for typeIndex, dewarList in pairs(rawDewars) do
            local materialized = {}
            for _, d in pairs(dewarList) do
                materialized[#materialized + 1] = { animal = d.animal, straws = d.straws, uniqueId = d:getUniqueId() }
            end
            dewarsByType[typeIndex] = materialized
        end
    end

    return {
        husbandries         = husbandries,
        dealerAnimalsByType = dealerAnimalsByType,
        filtersById         = env.filtersById,
        animalSystem        = env.animalSystem,
        animalNameSystem    = env.animalNameSystem,
        farmBalanceByFarmId = { [farmId] = env.balanceForFarm(farmId) },
        dewarsByFarmId      = { [farmId] = dewarsByType },
        -- Deliberately NOT defaulted here: the planner treats it as a structural dep and must
        -- raise on a ctx that lacks it rather than price at a stale markup.
        buyMarkup           = env.buyMarkup,
    }
end

--- Shape the FROZEN executor ctx: the same uniqueId->placeable map the planner keyed off, the
--- owner-farm EPP placeable map for the move-dest fall-through, the dispatch boundary and the
--- service refs. `eppPlaceablesById` is ALWAYS set, possibly empty, never nil.
---@param husbandriesById table { [uniqueId] = placeable }
---@param eppPlaceablesById table { [uniqueId] = EPP placeable } (possibly empty; never nil)
---@param env table the run(env) seam
---@return table executorCtx the FROZEN RLHerdsmanExecutor.executeActions ctx
local function buildExecutorCtx(husbandriesById, eppPlaceablesById, env)
    return {
        server                  = env.server,
        mission                 = env.mission,
        husbandryPlaceablesById = husbandriesById,
        eppPlaceablesById       = eppPlaceablesById or {},
        ruleService             = env.ruleService,
        animalNameSystem        = env.animalNameSystem,
        -- Deliberately NOT defaulted, like buyMarkup: the executor treats it as a structural dep
        -- and must fail loud rather than skip the care write while still charging for it.
        defer                   = env.defer,
    }
end

--- Server-only gate: the tick runs only where there is a server (a dedicated server has g_server;
--- a pure client's is nil). A pure predicate, so the dual-run suite can prove the gate without
--- nil-ing the root global.
---@param server any g_server (or the injected server handle)
---@return boolean
function RLHerdsmanDayTick._shouldTick(server)
    return server ~= nil
end

-- The pure helpers above stay local for run()'s fast path and are exposed here as the unit-test
-- seam, the same shape RLHerdsmanExecutor._executeOne uses.
RLHerdsmanDayTick._indexHusbandriesByUniqueId = indexHusbandriesByUniqueId
RLHerdsmanDayTick._indexEPPsByUniqueId        = indexEPPsByUniqueId
RLHerdsmanDayTick._clearStaleMarks            = clearStaleMarks
RLHerdsmanDayTick._buildPlannerCtx            = buildPlannerCtx
RLHerdsmanDayTick._buildExecutorCtx           = buildExecutorCtx

-- =============================================================================
-- Orchestration (pure - no g_*; the dual-run seam)
-- =============================================================================

--- Run the herdsman day-tick over every farm in `env`. Per farm, SPECTATOR skipped: filter to
--- enabled rules, clear stale op marks, shape both ctx, run planActions -> executeActions, and log
--- the executor's per-farm wage at DEBUG. A farm with no enabled rules and a farm with an empty
--- plan each log a distinct no-op line, so "tick ran, nothing matched" reads apart from "tick
--- never ran". Reads no g_*; the engine boundary is the injected env.
---@param env table the run(env) seam (subscriber builds it from g_*; tests inject fakes)
---@return table readout { farmsProcessed, byFarm = { [farmId] = { wage, plannedActions, dispatched } } }
function RLHerdsmanDayTick.run(env)
    local readout = { farmsProcessed = 0, byFarm = {} }
    local farms = env.farms or {}

    -- Entry line: proves the tick fired at all. Counts only farms that will actually run, so the
    -- diagnostic does not overstate by the spectator slot.
    local farmCount = 0
    for _, farm in pairs(farms) do
        if farm.farmId ~= FarmManager.SPECTATOR_FARM_ID then farmCount = farmCount + 1 end
    end
    Log:debug("%s day-tick entry: %d farm(s) to process", LOG_PREFIX, farmCount)

    -- The markup this tick prices buys at, read off the injected env so the line is assertable
    -- under the dual-run harness. Guarded because RmLogging pcall-wraps string.format and falls
    -- back to the RAW template, so an unusable markup would emit `markup=%.3f` verbatim and lose
    -- the one diagnostic that names it. This does not gate the tick - the fail-loud placement is
    -- the planner's buy arithmetic.
    if type(env.buyMarkup) ~= "number" then
        Log:warning("%s dealer-quality buy markup is %s, not a number - a T4 wiring bug; buy rules will fail loud once one prices a candidate",
            LOG_PREFIX, tostring(env.buyMarkup))
    else
        Log:debug("%s dealer-quality buy markup=%.3f (preset %s)",
            LOG_PREFIX, env.buyMarkup, tostring(env.dealerQualityIndex))
    end

    for _, farm in pairs(farms) do
        local farmId = farm.farmId

        if farmId == FarmManager.SPECTATOR_FARM_ID then
            Log:trace("%s farm=%s is SPECTATOR - skipped", LOG_PREFIX, tostring(farmId))
        else
            -- listForFarm does NOT filter enabled; the enabled filter lives here and drives both
            -- the no-op gate and what clearStaleMarks + planActions act on.
            local enabledRules = {}
            for _, rule in ipairs(env.rulesForFarm(farmId) or {}) do
                if rule.enabled then enabledRules[#enabledRules + 1] = rule end
            end

            if #enabledRules == 0 then
                Log:debug("%s farm=%s: 0 enabled rules - no-op", LOG_PREFIX, tostring(farmId))
            else
                local husbandriesById = indexHusbandriesByUniqueId(env.husbandriesForFarm(farmId) or {})

                -- Clear BEFORE execute: the executor re-sets marks for mark-mode actions.
                clearStaleMarks(enabledRules, husbandriesById, env.server)

                local plan = RLHerdsmanPlanner.planActions(enabledRules, buildPlannerCtx(farm, husbandriesById, env))

                if #plan == 0 then
                    Log:debug("%s farm=%s: %d enabled rule(s) but empty plan - no-op",
                        LOG_PREFIX, tostring(farmId), #enabledRules)
                end

                local eppPlaceablesById = indexEPPsByUniqueId(env.eppsForFarm ~= nil and env.eppsForFarm(farmId) or {})

                local execCtx = buildExecutorCtx(husbandriesById, eppPlaceablesById, env)
                local summary = RLHerdsmanExecutor.executeActions(plan, execCtx)
                local wageByFarm = summary.wageByFarm or {}

                -- Surface only: the executor already deducted it.
                for fid, wage in pairs(wageByFarm) do
                    Log:debug("%s wage readout: farm=%s wage=%s (deducted by executor)", LOG_PREFIX, tostring(fid), tostring(wage))
                end

                RLHerdsmanMessages.emit(summary, execCtx)

                local dispatched = 0
                for _, row in ipairs(summary.results or {}) do
                    if row.dispatched then dispatched = dispatched + 1 end
                end

                Log:debug("%s farm=%s: %d enabled rule(s), planned=%d, dispatched=%d",
                    LOG_PREFIX, tostring(farmId), #enabledRules, #plan, dispatched)

                readout.byFarm[farmId] = {
                    wage = wageByFarm[farmId] or 0,
                    plannedActions = #plan,
                    dispatched = dispatched,
                }
                readout.farmsProcessed = readout.farmsProcessed + 1
            end
        end
    end

    return readout
end

-- =============================================================================
-- In-game glue (reads g_* - the ONLY non-dual-run layer)
-- =============================================================================

--- Assemble the run(env) seam from live g_* globals. Every closure passes its farmId EXPLICITLY:
--- a nil farmId to getPlaceablesByFarm defaults to g_localPlayer.farmId, which is nil on a
--- dedicated server and crashes.
---@return table env
function RLHerdsmanDayTick.buildEnv()
    local mission = g_currentMission
    local animalSystem = mission.animalSystem
    local husbandrySystem = mission.husbandrySystem
    local ruleService = g_rlHerdsmanRuleService

    -- Filters are farm-independent: read the list once and key it by id for the planner ctx.
    local filtersById = {}
    if g_rlFilterService ~= nil then
        for _, f in ipairs(g_rlFilterService:list()) do
            if f.id ~= nil then filtersById[f.id] = f end
        end
    end

    return {
        farms              = g_farmManager:getFarms(),
        rulesForFarm       = function(farmId) return ruleService:listForFarm(farmId) end,
        husbandriesForFarm = function(farmId) return husbandrySystem:getPlaceablesByFarm(farmId) end,
        -- Owner-farm EPP (butcher) placeables for the move-dest fall-through, scanned the same way
        -- @see RLMoveDestinationHelper.getValidDestinations does. Nil-guarded, so an absent EPP mod
        -- yields an empty list.
        eppsForFarm        = function(farmId)
            local out = {}
            local ps = mission.placeableSystem
            if ps ~= nil and ps.placeables ~= nil then
                for _, placeable in ipairs(ps.placeables) do
                    if placeable.spec_extendedProductionPoint ~= nil
                        and placeable.getOwnerFarmId ~= nil
                        and placeable:getOwnerFarmId() == farmId then
                        out[#out + 1] = placeable
                    end
                end
            end
            return out
        end,
        rawDealerAnimals   = function(typeIndex) return animalSystem:getSaleAnimalsByTypeIndex(typeIndex) end,
        filtersById        = filtersById,
        balanceForFarm     = function(farmId)
            local farm = g_farmManager:getFarmById(farmId)
            return farm ~= nil and farm:getBalance() or nil
        end,
        dewarsForFarm      = function(farmId) return g_dewarManager:getDewarsByFarm(farmId) end,
        -- A VALUE, not a closure: farm-independent, and buildEnv re-runs inside the DAY_CHANGED
        -- handler. Called at RUNTIME only - main.lua sources RLDealerQualityResolver AFTER this
        -- module, so a file-scope reference here would read nil.
        buyMarkup          = RLDealerQualityResolver.getMarkup(),
        dealerQualityIndex = RLDealerQualityResolver.getActiveIndex(),
        -- The horse-care deferral seam. The care write sets riding = 100, and
        -- @see AnimalHorse.processRidingUpdate grades fitness from riding and then zeroes it for
        -- the day. Both run off DAY_CHANGED and the order between this tick and a given husbandry
        -- placeable is placement-dependent, so an inline write is correct on one barn and silently
        -- zeroed on another. A zero-delay oneshot re-queues the write behind every DAY_CHANGED
        -- subscriber and still lands in the same frame. Same seam as
        -- @see RLMessageAggregator.initialize. Injected rather than read inside the executor,
        -- which documents no g_* reads.
        defer              = function(fn) Timer.createOneshot(0, fn) end,
        server             = g_server,
        mission            = mission,
        ruleService        = ruleService,
        animalSystem       = animalSystem,
        animalNameSystem   = mission.animalNameSystem,
    }
end

--- Register the day-tick: a single anonymous MessageType.DAY_CHANGED subscriber, subscribed on ALL
--- peers and server-only via the in-handler g_server guard. The handler body is wrapped in
--- RmSafeUtils.safeCall so an unhandled error cannot break the DAY_CHANGED publish chain. Called
--- once from RealisticLivestock_FSBaseMission:onStartMission.
function RLHerdsmanDayTick.subscribe()
    g_messageCenter:subscribe(MessageType.DAY_CHANGED, function()
        RmSafeUtils.safeCall("RLHerdsmanDayTick:onDayChanged", function()
            if not RLHerdsmanDayTick._shouldTick(g_server) then
                Log:debug("%s client (g_server == nil) - tick does not run", LOG_PREFIX)
                return
            end
            RLHerdsmanDayTick.run(RLHerdsmanDayTick.buildEnv())
        end)
    end)
end
