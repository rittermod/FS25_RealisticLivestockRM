-- RLHerdsmanDayTick.lua
-- M-Tick T4 - the day-tick wiring that makes the new herdsman actually run.
-- T1/T2 give a tested RLHerdsmanPlanner.planActions; T3 gives a tested
-- RLHerdsmanExecutor.executeActions - but nothing fires them. This module is the missing
-- tick: a MessageType.DAY_CHANGED subscriber (mirroring RLMessageAggregator.initialize) that,
-- once per day server-side, runs planActions -> executeActions per farm and surfaces the wage.
--
-- Split into a thin in-game glue layer and a fully dual-run orchestration layer (Rule C):
--   * subscribe()/buildEnv() READ g_* - the only in-game wiring. Registered once from
--     RealisticLivestock_FSBaseMission:onStartMission, beside RLMessageAggregator.initialize.
--   * run(env)/clearStaleMarks/buildPlannerCtx/buildExecutorCtx read NO g_*; they take the
--     injected `env` and return plain data, so the whole orchestration (per-farm loop, clear-
--     stale-marks, ctx shaping, wage readout) is unit-tested on REAL Animals headless. Prod and
--     tests differ ONLY in how `env` is built (live globals vs injected fakes). clearStaleMarks
--     also broadcasts AnimalMarkEvent (active=false) per cleared animal through env.server (caller-
--     mutates-first, no sendLocal) so mark REMOVALS sync to MP clients - the CLEAR-direction mirror
--     of the executor's SET-direction AnimalMarkEvent broadcast.
--
-- Server-only via the in-handler g_server guard (the fix), exactly as
-- RLMessageAggregator does: onStartMission registers on ALL peers, so server-only-ness comes
-- from the handler's `if g_server == nil then return end` early-return. A dedicated server has
-- g_server, so dedis ARE ticked; clients register an inert listener.
--
-- Coexists with legacy (D12): the legacy AIAnimalManager tick and the legacy wage hook
-- (RealisticLivestock_FSBaseMission:onDayChanged) stay live and untouched. T4 acts only on new
-- rules. T3 OWNS the MoneyType.HERDSMAN_WAGES deduction (one addMoney per farm); T4 NEVER
-- re-deducts - it only LOGS summary.wageByFarm at DEBUG. Player/GUI wage surfacing is T5.
--
-- env contract (subscriber builds it from g_*; tests inject fakes - RAW engine shapes in,
-- buildPlannerCtx/buildExecutorCtx reshape into the FROZEN planner/executor ctx):
--   env = {
--     farms                  = { farmRecord, ... },                 -- g_farmManager:getFarms() (SPECTATOR skipped in run)
--     rulesForFarm(farmId)   -> { rule, ... },                      -- ruleService:listForFarm (NOT enabled-filtered; run filters)
--     husbandriesForFarm(id) -> { placeable, ... },                 -- husbandrySystem:getPlaceablesByFarm(EXPLICIT id)
--     rawDealerAnimals(idx)  -> { Animal, ... },                    -- animalSystem:getSaleAnimalsByTypeIndex (live, reserved-INCLUSIVE; per-farm re-read)
--     filtersById            = { [filterId] = filter },             -- g_rlFilterService:list keyed by id (farm-independent)
--     balanceForFarm(farmId) -> number|nil,                         -- g_farmManager:getFarmById(id):getBalance()
--     dewarsForFarm(farmId)  -> { [typeIndex] = { <dewar OBJECT>, ... } }|nil,  -- g_dewarManager:getDewarsByFarm (RAW objects)
--     buyMarkup              = number,                          -- active dealer-quality markup (buy pricing)
--     dealerQualityIndex     = number|nil,                      -- preset index it came from; DEBUG readout ONLY
--     server, mission, ruleService, animalSystem, animalNameSystem,
--   }
-- `buyMarkup` is resolved ONCE per tick in buildEnv and forwarded verbatim into the planner ctx.
-- It lives in env rather than being read where it is used because buildEnv is this module's only
-- g_*-reading layer: resolving it further in would make the dual-run layer env-dependent and would
-- pin every headless assert to the default preset, with no way to exercise another one.
--
-- readout contract (run's return value; surfaced at DEBUG, consumed by no caller yet - T5
-- reads the executor summary directly. Defined so tests + LuaDoc have a concrete shape):
--   readout = {
--     farmsProcessed = number,                  -- farms that ran plan/execute (SPECTATOR + no-enabled-rule farms skipped)
--     byFarm = { [farmId] = {                   -- one row per processed farm with enabled rules
--       wage           = number,                -- = summary.wageByFarm[farmId] (0 if none)
--       plannedActions = number,                -- #plan
--       dispatched     = number,                -- executor result rows with dispatched == true
--     } },
--   }
--
-- Parity anchors in AIAnimalManager:onDayChanged: the per-operation clear-stale-marks legs (sell /
-- castrate / ai) + their enabled/maxAnimals op gates; the dealer pool + its reserved exclusion; the
-- dewar source. Wage hook + farm loop: RealisticLivestock_FSBaseMission:onDayChanged. The spectator
-- farm (FarmManager.SPECTATOR_FARM_ID) is skipped before any gather.

local Log = RmLogging.getLogger("RLRM")

RLHerdsmanDayTick = {}

-- =============================================================================
-- Constants
-- =============================================================================

--- Greppable prefix on every day-tick log line (the entry / per-farm / no-op lines are the
--- verification surface; mutation-parity tracing is the executor's [executeActions] rows).
local LOG_PREFIX = "[herdsmanTick]"

--- operation -> the AI_MANAGER_* mark the clear-stale pass clears (mirrors AIAnimalManager's
--- per-operation clear-stale legs). buy + naming carry no clearable op mark.
local MARK_BY_OPERATION = {
    sell     = "AI_MANAGER_SELL",
    castrate = "AI_MANAGER_CASTRATE",
    ai       = "AI_MANAGER_INSEMINATE",
    move     = "AI_MANAGER_MOVE",
}

-- =============================================================================
-- Internal helpers (pure - no g_*; build/reshape the injected env into the
-- FROZEN planner/executor ctx, which T1/T2/T3 own. Add nothing to those ctx.)
-- =============================================================================

--- Index a farm's live husbandry placeables by their uniqueId (the key space the rules'
--- targetHusbandries + the executor's husbandryPlaceablesById both use). A duplicate uniqueId
--- across live placeables WARNs and keeps the last (deterministic, never raises).
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

--- Index a farm's live owner EPP (butcher) placeables by their uniqueId - the SAME key space the
--- rules' move destinationHusbandry uses (RLHusbandryTargetKey.keyFor = getUniqueId() on the
--- server, and the tick is server-only), so the executor's _doMove dest fall-through resolves an
--- EPP dest key to its placeable. Nil-tolerant (EPP is an optional mod - an empty / nil input
--- yields an empty map, the always-set-possibly-empty contract). A duplicate uniqueId WARNs and
--- keeps the last (deterministic, never raises), mirroring indexHusbandriesByUniqueId.
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
--- BEFORE the executor runs (decision 1b): executeActions re-SETS the mark for mark-mode actions,
--- so clearing afterwards would wipe a freshly-set mark. Each animal actually cleared ALSO
--- broadcasts AnimalMarkEvent (active=false) through the injected server (caller-mutates-first, no
--- sendLocal) so the REMOVAL syncs to MP clients - the CLEAR-direction mirror of the executor's
--- SET-direction broadcast (@see RLHerdsmanExecutor setMarkOnAll) and the player path
--- (@see RLAnimalInfoService.markAnimal). Full legacy parity incl. zero-selection passes (the mark
--- clears even when no candidate matches this tick). Owns its own unresolvable-target guard (it runs
--- before the planner): a target absent from the live placeables is skipped + WARNed. Every
--- per-animal mutation + broadcast is wrapped in RmSafeUtils.safeAnimalCall so one malformed animal
--- cannot abort the loop or leave a half-applied state (project mandate). markKey is always a
--- non-nil AI_MANAGER_* key here (the MARK_BY_OPERATION gate), so AnimalMarkEvent's destructive
--- clear-all mode (key=nil) is structurally unreachable - no nil-key guard needed.
---@param enabledRules table array of ENABLED rules for the farm (run applies the enabled filter)
---@param husbandriesById table { [uniqueId] = placeable }
---@param server any injected server (env.server); broadcast only when non-nil. The live tick is
---  server-gated by run(), so a nil server is a defensive unit-call path that still clears but does
---  not broadcast.
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
                            -- Mirror legacy's gate (AIAnimalManager's clear-stale legs): only clear a set mark.
                            if animal:getMarked(markKey) then
                                animal:setMarked(markKey, false)
                                -- MP sync: broadcast WITHOUT sendLocal. AnimalMarkEvent:run applies setMarked on
                                -- server AND client, so the server already cleared above; sendLocal would re-run
                                -- run() locally (redundant re-clear, possible double broadcast). Scoped inside the
                                -- getMarked gate + safeAnimalCall, so the broadcast is exactly as scoped as the
                                -- mutation and shares its isolation boundary.
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

--- Shape the FROZEN planner ctx (T1 + T2a/b/c) for ONE farm: husbandries keyed by uniqueId with
--- their type + live clusters + free animal-slot count (the planner's Buy space cap), the
--- reserved-excluded dealer pool (built once per type, re-read
--- freshly per farm), the farm-scoped balance ledger seed, and the materialized dewar pool
--- (raw dewar OBJECT -> { animal, straws, uniqueId } - the planner's per-T2c nil-guards filter,
--- T4 materializes faithfully). filtersById + the service refs pass straight through from env, as
--- does buyMarkup - a farm-independent scalar, so every farm this tick prices at the same markup.
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
            -- The planner's Buy slot cap: total free animal slots (no-arg, mirrors
            -- AIAnimalBuyEvent.validate's space gate). Unguarded spec-method call, same posture as
            -- getAnimalTypeIndex/getClusters above; the subscriber's safeCall wrap is the isolation boundary.
            freeSlots = placeable:getNumOfFreeAnimalSlots(),
        }
        -- Reserved-exclusion is parity-critical (legacy AIAnimalManager claims dealer animals
        -- via animal.reserved). Memoized across same-type husbandries on this farm.
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
        -- Forwarded verbatim - farm-independent, so it is the same scalar for every farm this
        -- tick. Deliberately NOT defaulted here: the planner treats it as a structural dep and
        -- must raise on a ctx that lacks it rather than price at a stale markup.
        buyMarkup           = env.buyMarkup,
    }
end

--- Shape the FROZEN executor ctx (T3): the same uniqueId->placeable map the planner keyed off, the
--- owner-farm EPP placeable map for the move-dest fall-through, plus the dispatch
--- boundary (server/mission) + the service refs. `eppPlaceablesById` is ALWAYS set (possibly an empty
--- table - EPP is an optional mod), the always-set contract the executor relies on (a nil map would be
--- treated as empty anyway - the missing-dest skip - but the day-tick never hands it nil).
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
    }
end

--- Server-only gate (the fix): the tick runs only where there is a server (a dedicated
--- server has g_server, so dedis ARE included; a pure client's g_server is nil). Pulled out as a
--- pure predicate so the dual-run suite proves the gate WITHOUT nil-ing the root global g_server
--- (which in-game rlTest cannot do safely); the handler applies it to the live g_server.
---@param server any g_server (or the injected server handle)
---@return boolean
function RLHerdsmanDayTick._shouldTick(server)
    return server ~= nil
end

-- The pure helpers above are local for run()'s fast path AND exposed here so the dual-run suite
-- (RLHerdsmanDayTickTests) can unit-test each in isolation on real Animals - the same "internal
-- function on the module table" testing seam RLHerdsmanExecutor._executeOne uses.
RLHerdsmanDayTick._indexHusbandriesByUniqueId = indexHusbandriesByUniqueId
RLHerdsmanDayTick._indexEPPsByUniqueId        = indexEPPsByUniqueId
RLHerdsmanDayTick._clearStaleMarks            = clearStaleMarks
RLHerdsmanDayTick._buildPlannerCtx            = buildPlannerCtx
RLHerdsmanDayTick._buildExecutorCtx           = buildExecutorCtx

-- =============================================================================
-- Orchestration (pure - no g_*; THE dual-run seam, decision 3a)
-- =============================================================================

--- Run the new herdsman day-tick over every farm in `env`. Per farm (SPECTATOR skipped): filter
--- to enabled rules, and on a no-enabled-rules farm log a graceful no-op exit (a
--- diagnostic, distinguishing "tick ran, nothing matched" from "tick never ran"). Otherwise clear
--- stale op marks, shape the planner + executor ctx, run planActions -> executeActions, and LOG
--- the executor's per-farm wage at DEBUG (surface only - T3 already deducted it; T4 NEVER calls
--- addMoney). Reads no g_*; the engine boundary is the injected env. Returns a readout (above).
---@param env table the run(env) seam (subscriber builds it from g_*; tests inject fakes)
---@return table readout { farmsProcessed, byFarm = { [farmId] = { wage, plannedActions, dispatched } } }
function RLHerdsmanDayTick.run(env)
    local readout = { farmsProcessed = 0, byFarm = {} }
    local farms = env.farms or {}

    -- A server-side entry line (dedi included) proves the tick fired at all. Count
    -- only the farms that will actually run (SPECTATOR is skipped below), so the diagnostic count
    -- is honest rather than overstating by the spectator slot.
    local farmCount = 0
    for _, farm in pairs(farms) do
        if farm.farmId ~= FarmManager.SPECTATOR_FARM_ID then farmCount = farmCount + 1 end
    end
    Log:debug("%s day-tick entry: %d farm(s) to process", LOG_PREFIX, farmCount)

    -- The markup this tick prices buys at, read off the injected env so the line is assertable
    -- under the dual-run harness (a line at the buildEnv seam would be in-game only). This is the
    -- ONLY markup line on a tick where no buy reaches the planner's deepest branch; when one does,
    -- the per-buy [planActions] line reports the same value again.
    -- Guarded because RmLogging pcall-wraps string.format and falls back to printing the RAW
    -- template: an unusable markup would otherwise emit `markup=%.3f` verbatim, losing the one
    -- diagnostic that names it, in exactly the case someone would be reading for it. This does NOT
    -- gate the tick - the fail-loud placement is the planner's buy arithmetic, and this WARNING
    -- only makes a wiring bug legible before a buy rule gets there (it may never, if no candidate
    -- reaches pricing).
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
            -- Skip the spectator farm before any gather (FarmManager.SPECTATOR_FARM_ID).
            Log:trace("%s farm=%s is SPECTATOR - skipped", LOG_PREFIX, tostring(farmId))
        else
            -- listForFarm does NOT filter enabled; the enabled filter lives here (drives both the
            -- no-op gate and what clearStaleMarks + planActions act on).
            local enabledRules = {}
            for _, rule in ipairs(env.rulesForFarm(farmId) or {}) do
                if rule.enabled then enabledRules[#enabledRules + 1] = rule end
            end

            if #enabledRules == 0 then
                -- Graceful no-op exit - no plan, no execute, no money.
                Log:debug("%s farm=%s: 0 enabled rules - no-op", LOG_PREFIX, tostring(farmId))
            else
                local husbandriesById = indexHusbandriesByUniqueId(env.husbandriesForFarm(farmId) or {})

                -- Clear BEFORE execute (decision 1b): the executor re-sets marks for mark-mode actions.
                -- env.server threads the dispatch boundary so cleared marks broadcast to MP clients.
                clearStaleMarks(enabledRules, husbandriesById, env.server)

                local plan = RLHerdsmanPlanner.planActions(enabledRules, buildPlannerCtx(farm, husbandriesById, env))

                -- An empty plan is the OTHER graceful no-op exit (enabled rules, but
                -- nothing matched this tick) - log it distinctly so a dedi reviewer reads "tick ran,
                -- nothing to do" rather than inferring it from a planned=0 metrics line.
                if #plan == 0 then
                    Log:debug("%s farm=%s: %d enabled rule(s) but empty plan - no-op",
                        LOG_PREFIX, tostring(farmId), #enabledRules)
                end

                -- Owner-farm EPP (butcher) placeables for the move-dest fall-through. ALWAYS
                -- built (possibly empty - EPP is an optional mod, and a test env may omit eppsForFarm):
                -- keyed by uniqueId, the same key space the rule's move destinationHusbandry uses.
                local eppPlaceablesById = indexEPPsByUniqueId(env.eppsForFarm ~= nil and env.eppsForFarm(farmId) or {})

                local execCtx = buildExecutorCtx(husbandriesById, eppPlaceablesById, env)
                local summary = RLHerdsmanExecutor.executeActions(plan, execCtx)
                local wageByFarm = summary.wageByFarm or {}

                -- Wage readout (DEBUG, surface only - T3 already deducted it; T4 never re-deducts).
                for fid, wage in pairs(wageByFarm) do
                    Log:debug("%s wage readout: farm=%s wage=%s (deducted by executor)", LOG_PREFIX, tostring(fid), tostring(wage))
                end

                -- T5 OWNS this hook: surface the executed/marked ops as player messages -
                -- the parity readout legacy AIAnimalManager:onDayChanged emitted. T4's frozen contract
                -- had no message seam; execCtx (carrying husbandryPlaceablesById - the SAME placeable
                -- handles T3 dispatched its events against) is in scope right here, after executeActions.
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

--- Assemble the run(env) seam from live g_* globals. RAW engine shapes + service refs in;
--- buildPlannerCtx/buildExecutorCtx reshape them into the frozen ctx. Every closure passes its
--- farmId EXPLICITLY to the engine read - a nil farmId to getPlaceablesByFarm defaults to
--- g_localPlayer.farmId, which is nil on a dedicated server -> crash (the context).
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
        -- Owner-farm EPP (butcher) placeables for the move-dest fall-through. Scans the
        -- placeableSystem for spec_extendedProductionPoint, mirroring RLMoveDestinationHelper.getValidDestinations' scan;
        -- nil-guarded so an absent EPP mod (no such spec on any placeable) yields an empty list.
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
        -- The active dealer-quality markup, resolved fresh per tick. A VALUE, not a closure: it is
        -- farm-independent, and buildEnv itself re-runs inside the DAY_CHANGED handler, so a value
        -- is exactly as current as a closure would be (filtersById is the same precedent).
        -- Called at RUNTIME only - main.lua sources RLDealerQualityResolver AFTER this module, so a
        -- file-scope reference here would read nil. The index rides along for the readout line in
        -- run(); resolving it there instead would make that layer env-dependent.
        buyMarkup          = RLDealerQualityResolver.getMarkup(),
        dealerQualityIndex = RLDealerQualityResolver.getActiveIndex(),
        server             = g_server,
        mission            = mission,
        ruleService        = ruleService,
        animalSystem       = animalSystem,
        animalNameSystem   = mission.animalNameSystem,
    }
end

--- Register the day-tick. A single anonymous MessageType.DAY_CHANGED subscriber mirroring
--- RLMessageAggregator.initialize: subscribed on ALL peers (onStartMission runs on all peers),
--- server-only via the in-handler g_server guard (dedis included; clients register an inert
--- listener). The handler body is wrapped in RmSafeUtils.safeCall so an unhandled error cannot
--- break the DAY_CHANGED publish chain. Subscribe ONCE (one day-change -> one run); the shared
--- onStartMission-registered DAY_CHANGED shape is exactly RLMessageAggregator's. Called from
--- RealisticLivestock_FSBaseMission:onStartMission, beside RLMessageAggregator.initialize.
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
