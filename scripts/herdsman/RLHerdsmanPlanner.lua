-- RLHerdsmanPlanner.lua
-- Pure herdsman day-tick planner (M-Tick T1 + T2a Sell/Buy + T2b
-- Castrate/Naming + T2c AI/insemination) - the keystone of M-Tick.
--
-- `planActions(rules, ctx)` decides WHICH animals each enabled rule acts on, in run
-- order, threading cross-rule claims + a farm-scoped money ledger + a planner-wide dewar
-- straw ledger + a per-husbandry free-slot ledger, and returns ordered intended-action
-- records. The surprising part - sequential
-- state threading across rules - is isolated here in one 100% headless module: data in, data
-- out. `planActions` reads no `g_*` and MUST NOT mutate `rules`, `ctx`, or any animal / dewar
-- table (internal bookkeeping copies only). The ONLY engine calls are the REAL primitives
-- reached through injected ctx + the passed-in Animal: the price path (`animal:getSellPrice()`,
-- `ctx.animalSystem:getAnimalTransportFee(...)`), the deterministic naming list
-- (`ctx.animalNameSystem:getNamesAlphabetical(...)`), and the AI eligibility predicate
-- (`animal:getCanBeInseminatedByAnimal(dewar.animal)`) - dependency injection, not a `g_*` read.
-- The animal mutations (castrate flags, `animal.name`, the `params.previous` write-back, the real
-- straw decrement, setMarked/clear-stale-marks) + event dispatch are T3; the day-tick hook + ctx
-- build are T4.
--
-- ctx contract (T4 builds it in-game; tests fabricate it from real Animals):
--   ctx = {
--     husbandries         = { [uniqueId] = { animalTypeIndex = n, animals = { Animal, ... }, freeSlots = n } },
--     dealerAnimalsByType = { [animalTypeIndex] = { Animal, ... } },
--     filtersById         = { [filterId] = filterRecord },
--     animalSystem        = <real AnimalSystem>,           -- getAnimalTransportFee (DI; T2a)
--     animalNameSystem    = <real AnimalNameSystem>,       -- getNamesAlphabetical (DI; T2b)
--     farmBalanceByFarmId = { [farmId] = balance },        -- ledger seed, farm-scoped (T2a)
--     dewarsByFarmId      = { [farmId] = { [animalTypeIndex] = { {animal=<sire>, straws=n, uniqueId=s}, ... } } }, -- AI dewar pool (DI; T2c)
--     buyMarkup           = number,                        -- active dealer-quality markup (T2a Buy)
--   }
-- `buyMarkup` is a STRUCTURAL dep, deliberately UNGUARDED and undefaulted: T4 resolves it from the
-- active dealer-quality preset, so its absence is a wiring bug, not a data problem, and any default
-- this module could pick would be the one wrong number (the old compiled markup) that reading the
-- preset exists to eliminate. A ctx missing it therefore RAISES on the buy arithmetic rather than
-- silently pricing every automated purchase at a stale markup. See the Edge-handling note on
-- `planActions`.
-- The caller (T4) farm-scopes BOTH `rules` and `ctx.husbandries`, and excludes legacy
-- `reserved` dealer animals from `dealerAnimalsByType` (coexistence: legacy AIAnimalManager
-- claims dealer animals via `animal.reserved`). The planner filters `enabled` itself.
-- `farmBalanceByFarmId` + `dewarsByFarmId` are keyed by `rule.farmId` (the rule's owning farm);
-- the `farmId` value type MUST match the table key type or both silently read empty.
-- `freeSlots` is the destination husbandry's total free animal-slot count (T4 sources
-- `placeable:getNumOfFreeAnimalSlots()`); the Buy branch caps selection on it (one animal == one
-- slot, mirroring `AIAnimalBuyEvent.validate`'s space gate) via a per-husbandry slot ledger seeded
-- once, credited by an executed sell's count, debited by a buy's count. Only Buy requires it; other
-- ops tolerate a nil `freeSlots` (a sell on such a husbandry just skips its slot credit).
--
-- Action records, emitted in run order (operation rank, then within an op
-- `compareRulesByName`; within a rule, targets in lexicographic uniqueId order):
--   sell { ruleId, operation="sell", husbandryId, animals=<price desc>, mark, wage, amountGained? }
--        (`amountGained` present iff `mark==false`; a marked sell is advisory - no money/event)
--   move { ruleId, operation="move", husbandryId=<source>, animals=<genetics desc>, destinationHusbandry, mark, wage }
--        (OUT op like sell: the selected set leaves the SOURCE plan pool this tick; the
--        destination-side add lands next day - no same-day dest-add. No money/event - the
--        relocation is the executor's, slice 4.)
--   buy  { ruleId, operation="buy",  husbandryId, animals=<price asc>,  amountSpent, wage }
--   castrate { ruleId, operation="castrate", husbandryId, animals=<survivors>, mark, wage }
--   naming   { ruleId, operation="naming", husbandryId, animals=<named>, convention, wage,
--              assignments?, previousOut? } (assignments+previousOut iff alphabetical AND >=1 named)
-- ai { ruleId, operation="ai", husbandryId, animals } (T1 shape; per-op params = T2c)
--   horseCare { ruleId, operation="horseCare", husbandryId, animals=<pool order>, wage }
--        (no `mark` key at all - horseCare has no mark mode, and a stray one would flip the
--        executor row's `mark` and route it into the message layer's mark-precedence branch)
--
-- Run order = operation order (RLHerdsmanRuleService.OPERATION_ORDER: sell -> move -> buy ->
-- castrate -> naming -> ai -> horseCare) then RLHerdsmanRuleService.compareRulesByName within
-- an op (mirrors legacy AIAnimalManager:onDayChanged - sell frees herd space + funds buys
-- before buy fills the space / spends the proceeds).
--
-- `horseCare` runs LAST and is HORSE-only. Its type gate is an ALLOW-LIST and therefore fails
-- CLOSED - the opposite polarity to castrate's chicken EXCLUSION beside it, which fails open.
-- An unresolvable AnimalType.HORSE means nothing is targetable, never everything.
--
-- Candidate match is RLFilterEvaluator.evaluate (pure, fails closed: a nil / deleted
-- filter selects nothing, never raises - D16). Naming carries no filter and selects every
-- remaining UNNAMED animal in its targets (the exact `name ~= ""` skip in legacy's naming leg).

local Log = RmLogging.getLogger("RLRM")

RLHerdsmanPlanner = {}

-- =============================================================================
-- Constants
-- =============================================================================

--- Greppable prefix on every planner log line (the per-(rule, husbandry) DEBUG summary
--- lines are the verification surface; the evaluator already emits per-animal DEBUG lines).
local LOG_PREFIX = "[planActions]"

--- Buy applies the ACTIVE dealer-quality markup on the sell price before adding transport - the
--- buy leg of legacy AIAnimalManager:onDayChanged, with the markup injected as `ctx.buyMarkup`
--- rather than compiled in. Sell deliberately applies NO markup (the sell leg of that same
--- function); note that is not "the raw price" either, because the transport fee is still ADDED
--- here, where the player sell path subtracts it.
local SELL_MARKUP = 1.0

--- Per-operation claim traits - the explicit table that drives how each operation threads
--- state across the sequential rule passes (the two-level claim model, intake 1a):
---   * `removesFromPlanPool` (sell, move) - an OUT op: a selected animal leaves its SOURCE
---     husbandry's plan pool, so it is absent from EVERY later rule's candidates (global claim).
---     Sell removes it from the owned herd; move relocates it to the destination pen (the
---     dest-add lands on the next tick) - behaviorally the same plan-pool effect this tick, so
---     one neutral OUT name covers both. The shared trait NAME is declared here; the actual
---     pool removal lives in each op's dispatch branch.
---   * `sourcesFromDealer` + `addsToHerd` (buy) - candidates come from the dealer pool, NOT
---     the owned herd; a bought animal joins the destination husbandry's owned pool so later
---     cross-op rules (castrate / naming / ai) see it.
---   * `noFilter` (naming) - no filter is evaluated; naming selects ALL remaining animals in
---     its targets (T1).
--- Every operation ALSO claims same-operation (two rules of one op never pick the same
--- animal); that is enforced uniformly by the per-op claimed set, independent of these traits.
--- An operation with an empty traits table (castrate / ai / horseCare) is a plain owned-herd,
--- non-end-task, filtered op.
--- Every registered operation MUST have an entry even when it has no plan arm: `matchFromPool`
--- reads `traits.noFilter`, so a missing entry would raise the moment a future arm routes
--- through it.
RLHerdsmanPlanner.OPERATION_TRAITS = {
    sell      = { removesFromPlanPool = true },
    move      = { removesFromPlanPool = true },
    buy       = { sourcesFromDealer = true, addsToHerd = true },
    castrate  = {},
    naming    = { noFilter = true },
    ai        = {},
    horseCare = {},
}

--- Herdsman daily wage per animal, by animalTypeIndex (reproduced EXACTLY from legacy
--- `AIAnimalManager.ANIMAL_TYPE_TO_WAGE`; M-Tick open item 3 resolved -> reproduce). Keyed
--- by the runtime AnimalType.* index so it matches `husbandry.animalTypeIndex`. A type
--- absent from this table falls back to DEFAULT_WAGE (legacy `... or 5`).
local DEFAULT_WAGE = 5
local WAGE_BY_NAME = { COW = 20, SHEEP = 12.5, PIG = 10, HORSE = 25, CHICKEN = 2 }

--- The daily wage rate for an animalType (legacy `ANIMAL_TYPE_TO_WAGE[idx] or 5`). The
--- index->wage table is built at RUNTIME (first call), NOT at module load: in-game `AnimalType`
--- is not yet populated when this module is sourced (SECTION 11i), so a load-time build keys
--- off nil and every wage collapses to DEFAULT_WAGE. Legacy builds it inside
--- `AIAnimalManager.new()` (runtime) for the same reason. We memoize, but only cache once
--- `AnimalType` is actually populated, so a too-early call retries instead of poisoning the cache.
---@param animalTypeIndex any
---@return number wage rate
local wageByTypeIndex = nil
local function wageFor(animalTypeIndex)
    if wageByTypeIndex == nil and type(AnimalType) == "table" then
        local t = {}
        for name, w in pairs(WAGE_BY_NAME) do
            local idx = AnimalType[name]
            if idx ~= nil then t[idx] = w end
        end
        if next(t) ~= nil then wageByTypeIndex = t end
    end
    return (wageByTypeIndex and wageByTypeIndex[animalTypeIndex]) or DEFAULT_WAGE
end

--- operation -> run-order rank, derived from the service's OPERATION_ORDER (the single
--- source of truth; the service loads first in main.lua SECTION 11h, before this module's
--- SECTION 11i). Used to skip unknown-operation rules before sorting and to rank the run.
local OPERATION_RANK = {}
for rank, op in ipairs(RLHerdsmanRuleService.OPERATION_ORDER) do
    OPERATION_RANK[op] = rank
end

-- =============================================================================
-- Internal helpers (pure)
-- =============================================================================

--- Build the claim-set / dedup key for an animal from its identity triple
--- (`RLAnimalUtil.toKey`, mirroring `RLAnimalUtil.compare`: farmId + uniqueId +
--- birthday.country). Returns nil when ANY identity field is nil - `toKey`'s string
--- concat would otherwise raise - so the caller skips the animal + WARNs instead of
--- crashing. The three-field key keeps two animals that share a uniqueId across farms /
--- countries distinct, and is the deterministic tie-break for equal-price sorts.
---@param animal table|nil
---@return string|nil key, or nil when an identity field is missing
local function animalKey(animal)
    if type(animal) ~= "table" then return nil end
    local farmId, uniqueId = animal.farmId, animal.uniqueId
    -- Gate the birthday read on table type: a malformed scalar `birthday` must yield a
    -- nil key (skip + WARN), never an index-a-scalar raise.
    local country = type(animal.birthday) == "table" and animal.birthday.country or nil
    if farmId == nil or uniqueId == nil or country == nil then
        return nil
    end
    return RLAnimalUtil.toKey(farmId, uniqueId, country)
end

--- Dedupe a rule's target uniqueIds and return them in lexicographic order, plus the
--- number of duplicates dropped. The service stores `targetHusbandries` order-insensitively
--- (multiset equality), so list order carries no semantics; a deterministic lexicographic
--- order makes the plan reproducible (and pins "first target takes all" for multi-target buy).
--- nil entries are dropped.
---@param targetHusbandries table|nil array of placeable uniqueId strings
---@return string[] ordered deduped uniqueIds
---@return number dupes count of duplicate entries dropped
local function dedupeSortedTargets(targetHusbandries)
    local seen, out, dupes = {}, {}, 0
    if type(targetHusbandries) == "table" then
        for _, uid in ipairs(targetHusbandries) do
            if uid ~= nil then
                if seen[uid] then
                    dupes = dupes + 1
                else
                    seen[uid] = true
                    out[#out + 1] = uid
                end
            end
        end
    end
    table.sort(out, function(x, y) return tostring(x) < tostring(y) end)
    return out, dupes
end

--- Coerce a rule's `maxAnimals` param to a positive integer count, or nil when the rule
--- must not run. Distinguishes (legacy gate `(maxAnimals or 0) > 0`, plus the fail-closed
--- contract): nil -> no-op (DEBUG, never configured); non-number -> fail closed (WARN,
--- corrupt data); a number -> floored to an integer count, then `<= 0` -> no-op (DEBUG).
---@param rule table
---@param params table
---@return number|nil maxN positive integer, or nil (caller emits no action)
local function normalizeMaxAnimals(rule, params)
    local m = params.maxAnimals
    if m == nil then
        Log:debug("%s rule=%s op=%s no-op: maxAnimals nil (never runs)", LOG_PREFIX, tostring(rule.id), tostring(rule.operation))
        return nil
    end
    if type(m) ~= "number" then
        Log:warning("%s rule=%s op=%s skipped: non-number maxAnimals (%s) - fail closed",
            LOG_PREFIX, tostring(rule.id), tostring(rule.operation), tostring(m))
        return nil
    end
    m = math.floor(m)
    if m <= 0 then
        Log:debug("%s rule=%s op=%s no-op: maxAnimals <= 0 (%d)", LOG_PREFIX, tostring(rule.id), tostring(rule.operation), m)
        return nil
    end
    return m
end

--- Validate a Buy rule's `budget` param, failing closed on corrupt data (never coerce-and-
--- execute). Returns (type, fixed, percentage, bad): `bad == true` means the caller skips
--- the rule (a WARNING is already logged). For type "fixed" only `fixed` must be a number;
--- for "percentage" only `percentage` must be (mirrors legacy's actual data dependency).
---@param rule table
---@param params table
---@return string|nil budgetType
---@return number|nil budgetFixed
---@return number|nil budgetPercentage
---@return boolean bad true -> skip the rule
local function validateBuyBudget(rule, params)
    local b = params.budget
    if type(b) ~= "table" then
        Log:warning("%s rule=%s op=buy skipped: missing/invalid budget table - fail closed", LOG_PREFIX, tostring(rule.id))
        return nil, nil, nil, true
    end
    local t = b.type
    if t ~= "fixed" and t ~= "percentage" then
        Log:warning("%s rule=%s op=buy skipped: unknown budget.type '%s' (not fixed/percentage) - fail closed",
            LOG_PREFIX, tostring(rule.id), tostring(t))
        return nil, nil, nil, true
    end
    if t == "fixed" and type(b.fixed) ~= "number" then
        Log:warning("%s rule=%s op=buy skipped: non-number budget.fixed (%s) - fail closed", LOG_PREFIX, tostring(rule.id), tostring(b.fixed))
        return nil, nil, nil, true
    end
    if t == "percentage" and type(b.percentage) ~= "number" then
        Log:warning("%s rule=%s op=buy skipped: non-number budget.percentage (%s) - fail closed", LOG_PREFIX, tostring(rule.id), tostring(b.percentage))
        return nil, nil, nil, true
    end
    return t, b.fixed, b.percentage, false
end

--- Reproduce the per-animal alphabetical-naming cursor walk in `AIAnimalManager:onDayChanged`'s naming leg
--- on a sorted name list, given the incoming cursor (already normalized "" -> nil by the
--- caller). Returns the assigned name AND the advanced cursor; `names` is guaranteed non-empty
--- by the caller (an empty gender list is a caller-side skip, never reaches here).
---
--- Pick rule: the first index `i` where `prev == nil OR name > prev OR i == #names`. (Legacy
--- writes `(name ~= prev and name >= prev)`, which is exactly `name > prev` for strings.) Then
--- if `i` is the last index AND `prev == name`, WRAP - assign `names[1]`, cursor `names[1]`;
--- otherwise assign `name`, cursor `name`. Legacy-faithful consequences: `prev` nil/"" ->
--- `names[1]`; `prev == last` -> wrap; `prev` past the last name (stale) -> picks the LAST name,
--- NO wrap; `prev` mid-range-not-in-list -> first name `> prev` (skips ahead); a single-element
--- list / more animals than names -> the cursor cycles and names repeat (intended, no dedup).
---@param names string[] non-empty, alphabetically sorted
---@param prev string|nil incoming cursor (nil = start of sequence)
---@return string assigned name
---@return string cursorOut advanced cursor
local function walkCursor(names, prev)
    local last = #names
    for i = 1, last do
        local name = names[i]
        if prev == nil or name > prev or i == last then
            if i == last and prev == name then
                return names[1], names[1]   -- exact-last wrap
            end
            return name, name
        end
    end
    -- Unreachable for a non-empty list (the `i == last` clause always fires); a defensive
    -- fallthrough so a future caller can never receive nil.
    return names[1], names[1]
end

-- =============================================================================
-- Public entry point
-- =============================================================================

--- Plan the herdsman day-tick: which animals each enabled rule acts on, in run order,
--- with the locked two-level claim model + the farm-scoped money ledger threaded across
--- sequential rule passes. Pure: `rules`, `ctx`, and every animal table are left unmutated
--- (internal pool / claim / ledger copies only).
---
--- Algorithm:
---   1. Filter to runnable rules: `enabled == true`; operation in OPERATION_ORDER (else
---      skip + WARN); non-naming with `filterId == nil` is an incomplete draft -> skip +
--- DEBUG. Disabled rules skip + DEBUG.
---   2. Sort runnable rules by operation rank, then `compareRulesByName`.
---   3. Per rule, dedupe + lexicographically order its targets, then per target select
---      candidates from the internal REMAINING pools (one `evalCtx` per call), apply the
---      per-operation pricing / cap / wage / claim, and emit an action when >= 1 selected.
---
--- Per-operation selection (T2a Sell/Buy; T2b Castrate/Naming; T2c AI):
---   * Sell: shortlist = filter-match AND `getCanBeSold()`; price = real getSellPrice +
---     transport; sort price DESC (toKey tie-break); take top `maxAnimals`; wage per the
---     legacy formula; CLAIM the selected set globally (mark OR exec) - remove from the
---     owned pool; an executed (mark==false) sell credits its proceeds to the farm ledger.
---   * Buy: budget resolved against the running ledger (fail closed on bad params / nil
---     balance; `<= 0` -> no-op); shortlist = filter-match AND affordable (price <= budget,
---     buy markup); sort price ASC; consume cheapest until the next price exceeds the
---     remaining budget (strict `>`) or `maxAnimals`; claim from the dealer pool, append to
---     the destination owned pool, and DEBIT the farm ledger.
---   * Castrate: resolve-first + per-target chicken no-op; per survivor hard-skip female /
---     isCastrated / fertility==0 (nil genetics -> skip+WARN); wage `W*0.5*n*(mark?0.35:1)` (single
---     term); `mark` action field gates only the T3 mutation. Same-op claim, cross-op visible.
---   * Naming: no filter, unnamed-only; convention non-"random" -> alphabetical (+WARN); the
---     per-rule `previous` cursor walk (shared across genders, deterministic uid order) yields
---     `assignments` + `previousOut`; random defers strings (no previousOut); wage `W*0.15*n`.
---   * HorseCare: HORSE-only (fail-CLOSED allow-list gate on the resolved husbandry's
---     animalTypeIndex); filter-match over the owned pool with NO hard floor and NO
---     idempotency gate (an already-groomed horse is selected identically - see the arm);
---     wage `W*0.15*n` (single term, the naming coefficient). Same-op claim, cross-op
---     visible, no mark, no cap. Emits no `mark` key.
---   * AI: filter-match + the REAL `getCanBeInseminatedByAnimal` (the SOLE eligibility gate) over
---     the rule.farmId/type dewar bucket; genetics-desc sort, greedy best-first straw assignment
---     against the planner-wide dewar-identity ledger, `maxAnimals` cap-then-claim (commit only the
---     inseminated set's straws); AI wage; `mark` gates only the T3 dispatch. animals=<inseminated
---     refs, genetics desc> + a parallel dewars=<uniqueId> array. Same-op claim, the LAST op.
---
--- Claim mechanics (the two-level model): owned ops draw from a per-husbandry owned pool
--- (shallow copy of `ctx.husbandries[uid].animals`); sell removes its CAPPED selected set
--- (capped-out matches stay candidates for a later same-op rule); castrate/naming/ai keep
--- selected animals in the pool (cross-op visible) but record the per-op claim so a later
--- SAME-op rule cannot re-pick them; buy removes its selected set from the dealer pool and
--- appends it to the destination owned pool.
---
--- Edge handling (never raises except the nil-arg guard and a missing structural BUY dep -
--- `ctx.buyMarkup`, see the file header): an unresolvable / malformed target husbandry is
--- skipped + WARN (once per uid per call); an animal with a nil identity field is
--- skipped + WARN; a deleted / nil filter selects nothing (evaluator fails closed); a missing
--- `ctx.animalSystem` fails a sell/buy rule closed (WARN); an empty target list / selection
--- emits no record (+ DEBUG).
---
---@param rules table[] farm-scoped rule records (the planner filters `enabled`)
---@param ctx table { husbandries, dealerAnimalsByType, filtersById, animalSystem, animalNameSystem, farmBalanceByFarmId, dewarsByFarmId, buyMarkup }
---@return table[] actions ordered action records (see the file header for per-op shapes)
function RLHerdsmanPlanner.planActions(rules, ctx)
    if rules == nil or ctx == nil then
        -- T4 owns construction; a nil top-level arg is a programmer error - fail loud.
        error(string.format("RLHerdsmanPlanner.planActions: rules and ctx are required (got rules=%s, ctx=%s)",
            tostring(rules), tostring(ctx)))
    end

    local husbandries = type(ctx.husbandries) == "table" and ctx.husbandries or {}
    local dealerByType = type(ctx.dealerAnimalsByType) == "table" and ctx.dealerAnimalsByType or {}
    local filtersById = type(ctx.filtersById) == "table" and ctx.filtersById or {}
    local animalSystem = ctx.animalSystem
    local animalNameSystem = ctx.animalNameSystem
    local farmBalanceByFarmId = type(ctx.farmBalanceByFarmId) == "table" and ctx.farmBalanceByFarmId or {}
    local dewarsByFarmId = type(ctx.dewarsByFarmId) == "table" and ctx.dewarsByFarmId or {}
    -- Read RAW - no type coercion, no `or` default. A ctx that omits this raises on the buy
    -- arithmetic rather than pricing every automated purchase at a stale markup; see the
    -- structural-dep note in the file header.
    local buyMarkup = ctx.buyMarkup

    -- The CHICKEN type index for castrate's per-target no-op (the chicken skip in legacy's
    -- castrate leg). Read
    -- once; AnimalType is a runtime global (populated by AnimalSystem.new well before the day-tick),
    -- so a missing table just yields nil -> no target is treated as chicken (fail-open, matching
    -- wageFor's lazy-AnimalType posture; in practice AnimalType is always present at tick time).
    local chickenTypeIndex = type(AnimalType) == "table" and AnimalType.CHICKEN or nil

    -- The HORSE type index for horseCare's allow-list gate. Resolved by NAME, once per call,
    -- exactly as chickenTypeIndex is - never a literal index (animalTypeIndex is assigned by
    -- registration ORDER, so a map or bridge can shift it).
    -- OPPOSITE POLARITY to the line above, and this is the one a maintainer will get backwards
    -- by mirroring castrate: chicken is an EXCLUSION, so a nil index excludes nothing (fail
    -- OPEN). Horse care is an ALLOW-LIST, so a nil index must make nothing targetable (fail
    -- CLOSED) - the arm's gate is `horseTypeIndex == nil or h.animalTypeIndex ~= horseTypeIndex`.
    -- Written the other way round it would groom cows on a map where AnimalType.HORSE did not
    -- resolve.
    local horseTypeIndex = type(AnimalType) == "table" and AnimalType.HORSE or nil

    -- One evalCtx per planActions call: RLFilterEvaluator.evaluate MUTATES its third arg
    -- (per-call warning / type-mismatch dedup sets), so NEVER pass the planner's input ctx
    -- through - allocate a planner-internal table dedicated to that.
    local evalCtx = { warnedFields = {}, typeMismatchFields = {} }

    -- Internal mutable bookkeeping (copies; ctx is never touched):
    --   remainingByHusbandry[uid] - owned animals still available for a husbandry (after
    --     sell removals + buy appends); shallow array copy, built lazily.
    --   dealerRemaining[typeIdx]  - dealer animals still available for a type; shallow array
    --     copy, built lazily.
    --   claimedByOp[op]           - set of claimed animal keys for an op (same-op claim).
    --   ledger[farmId]            - running farm balance projection; seeded once from
    --     ctx.farmBalanceByFarmId, credited by executed sells, debited by buys (run order).
    --   ledgerSeeded[farmId]      - distinguishes "not yet seeded" from "seeded to nil"
    --     (a non-number / absent balance leaves ledger[farmId] nil -> buy fails closed).
    --   warnedHusbandries[uid]    - per-call dedup for the unresolvable/malformed WARNING.
    --   warnedAnimals[animal]     - per-call dedup for the nil/invalid-identity WARNING
    --     (keyed by the animal value, since the same pool entry is re-scanned by each op).
    local remainingByHusbandry = {}
    local dealerRemaining = {}
    local claimedByOp = {}
    local ledger = {}
    local ledgerSeeded = {}
    local warnedHusbandries = {}
    local warnedAnimals = {}
    --   slotLedger[uid]           - running free-slot projection per husbandry uid (the slot analog of
    --     the farm money ledger): seeded once from ctx.husbandries[uid].freeSlots (finite, floored),
    --     credited by an executed sell's count, debited by a buy's count. nil = unseeded OR seeded to a
    --     missing/non-finite value (a buy then fails closed, mirroring the nil-balance posture).
    --   slotLedgerSeeded[uid]     - idempotency marker so a credit/debit is never overwritten by a re-seed.
    --   slotSeed[uid]             - the original floored seed, kept to distinguish the two buy no-op
    --     causes: seed <= 0 is a full barn (seed-zero); seed > 0 with remaining <= 0 is ledger-exhausted.
    --   warnedSlots[uid]          - per-call dedup for the missing/non-finite freeSlots buy WARNING.
    local slotLedger = {}
    local slotLedgerSeeded = {}
    local slotSeed = {}
    local warnedSlots = {}
    --   warnedDewars[dewar]       - per-call dedup for the malformed-sire / nil-uniqueId dewar WARNING.
    --   dewarStrawLedger[dewar]   - planner-wide straw projection keyed by dewar IDENTITY (table ref),
    --     seeded lazily from d.straws and threaded across ALL AI rules in run order (the AI analog of
    --     the farm money ledger): a later AI rule plans against straws an earlier rule's inseminated
    --     set committed. Only the post-cap inseminated set decrements it (capped-out candidates do not).
    local warnedDewars = {}
    local dewarStrawLedger = {}

    --- Resolve a target husbandry record, or nil (+ WARN once per uid) when it is absent or
    --- malformed (missing `animals` or `animalTypeIndex`).
    ---@param uid string
    ---@return table|nil husbandry
    local function resolveHusbandry(uid)
        local h = husbandries[uid]
        if type(h) ~= "table" or type(h.animals) ~= "table" or h.animalTypeIndex == nil then
            if not warnedHusbandries[uid] then
                Log:warning("%s unresolvable/malformed husbandry uid=%s (absent, or missing animals/animalTypeIndex); target skipped",
                    LOG_PREFIX, tostring(uid))
                warnedHusbandries[uid] = true
            end
            return nil
        end
        return h
    end

    --- The remaining owned-animal pool for a husbandry, lazily shallow-copied from ctx
    --- (never the live array). nil when the husbandry is unresolvable / malformed.
    ---@param uid string
    ---@return table|nil pool array of animal refs
    local function ownedPool(uid)
        local pool = remainingByHusbandry[uid]
        if pool ~= nil then return pool end
        local h = resolveHusbandry(uid)
        if h == nil then return nil end
        pool = {}
        for i, a in ipairs(h.animals) do pool[i] = a end
        remainingByHusbandry[uid] = pool
        return pool
    end

    --- The remaining dealer pool for an animalType, lazily shallow-copied from ctx. A
    --- missing / non-table entry yields an empty pool (no candidates), never a raise.
    ---@param typeIdx any animalType index
    ---@return table pool array of animal refs
    local function dealerPool(typeIdx)
        local pool = dealerRemaining[typeIdx]
        if pool ~= nil then return pool end
        pool = {}
        local src = dealerByType[typeIdx]
        if type(src) == "table" then
            for i, a in ipairs(src) do pool[i] = a end
        end
        dealerRemaining[typeIdx] = pool
        return pool
    end

    --- Seed the running ledger for a farm exactly once from ctx.farmBalanceByFarmId. A
    --- non-number / absent balance leaves ledger[farmId] nil (buy then fails closed; sell
    --- cannot thread its credit). Idempotent so credits / debits are never overwritten.
    ---@param farmId any
    local function seedLedger(farmId)
        if not ledgerSeeded[farmId] then
            ledgerSeeded[farmId] = true
            local v = farmBalanceByFarmId[farmId]
            if type(v) == "number" then ledger[farmId] = v end
        end
    end

    --- Seed the per-husbandry free-slot ledger exactly once from ctx.husbandries[uid].freeSlots
    --- (the slot analog of seedLedger). Only a FINITE number seeds (floored to an integer slot
    --- count); a missing / non-number / non-finite (NaN, +-inf) value leaves slotLedger[uid] nil ->
    --- a buy then fails closed (the space-gate WARN). A fabricated negative IS seeded (floored, so
    --- it stays negative) so the buy gate takes the full-barn no-op path, not a WARN. slotSeed
    --- records the original seed (full-barn vs ledger-exhausted no-op distinction). Idempotent so an
    --- executed sell's credit + a buy's debit are never overwritten by a re-seed.
    ---@param uid string
    local function seedSlotLedger(uid)
        if not slotLedgerSeeded[uid] then
            slotLedgerSeeded[uid] = true
            local h = husbandries[uid]
            local v = type(h) == "table" and h.freeSlots or nil
            -- Finite check: NaN ~= NaN; +-inf compare equal to math.huge / -math.huge. Only a finite
            -- number seeds; everything else leaves the ledger nil (buy fails closed).
            if type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge then
                local floored = math.floor(v)
                slotLedger[uid] = floored
                slotSeed[uid] = floored
            end
        end
    end

    --- Real per-animal price: the REAL getSellPrice scaled by the caller's markup - SELL_MARKUP
    --- for the sell leg, the active dealer-quality `ctx.buyMarkup` for the buy leg - plus the
    --- REAL transport fee, which is ADDED for both legs. The SAME calls as legacy
    --- AIAnimalManager:onDayChanged (mutation parity), no mock, no re-derivation. Caller
    --- guarantees `animalSystem` is usable (sell/buy fail closed when it is missing).
    ---@param animal table
    ---@param markup number
    ---@return number price
    local function priceOf(animal, markup)
        return animal:getSellPrice() * markup
            + animalSystem:getAnimalTransportFee(animal.subTypeIndex, animal.age)
    end

    --- Walk a candidate pool, returning the ordered animals that (a) carry a resolvable
    --- identity, (b) are not already claimed by this op, and (c) match (noFilter -> all
    --- remaining; else RLFilterEvaluator.evaluate, fails closed). Does NOT claim or mutate
    --- the pool - the caller prices / caps / claims the post-match set (T2a defers the claim
    --- past the cap so capped-out matches stay candidates for a later same-op rule).
    ---@param pool table array of animal refs
    ---@param filter table|nil filter record / node, or nil (deleted -> selects nothing)
    ---@param noFilter boolean true for naming (match every remaining unclaimed animal)
    ---@param claimed table per-op claimed-key set (read only)
    ---@return table[] matched ordered candidate list
    local function matchFromPool(pool, filter, noFilter, claimed)
        local matched = {}
        for _, animal in ipairs(pool) do
            local key = animalKey(animal)
            if key == nil then
                -- Skip + WARN on a malformed candidate (nil identity field, OR a non-table
                -- entry) WITHOUT indexing a non-table - the planner never raises on bad data.
                -- Deduped per call (warnedAnimals): the same pool entry is re-scanned by each op.
                if not warnedAnimals[animal] then
                    local fid, aUid, acountry
                    if type(animal) == "table" then
                        fid, aUid = animal.farmId, animal.uniqueId
                        if type(animal.birthday) == "table" then acountry = animal.birthday.country end
                    end
                    Log:warning("%s skipping animal with nil/invalid identity (farmId=%s uniqueId=%s country=%s)",
                        LOG_PREFIX, tostring(fid), tostring(aUid), tostring(acountry))
                    warnedAnimals[animal] = true
                end
            elseif not claimed[key] then
                local match = noFilter or RLFilterEvaluator.evaluate(filter, animal, evalCtx)
                if match then
                    matched[#matched + 1] = animal
                end
            end
        end
        return matched
    end

    --- Record each animal's key in a per-op claimed set (same-op claim across rules /
    --- targets). nil-keyed animals never reach here (matchFromPool dropped them).
    ---@param claimed table
    ---@param animals table[]
    local function claimAll(claimed, animals)
        for _, a in ipairs(animals) do
            local k = animalKey(a)
            if k ~= nil then claimed[k] = true end
        end
    end

    --- Rebuild a pool array excluding the selected keys (order preserved). Shared by sell's
    --- owned-pool removal and buy's dealer-pool removal.
    ---@param pool table[]
    ---@param selectedKeys table set keyed by animal key
    ---@return table[] newPool
    local function poolMinus(pool, selectedKeys)
        local newPool = {}
        for _, a in ipairs(pool) do
            local k = animalKey(a)
            if k == nil or not selectedKeys[k] then newPool[#newPool + 1] = a end
        end
        return newPool
    end

    --- True when a matched candidate exposes the REAL Animal price methods the Sell/Buy path
    --- invokes (`getSellPrice`, and for Sell `getCanBeSold`). A row can pass `matchFromPool`'s
    --- identity gate yet be a non-Animal data table without these methods; pricing it would be
    --- a call-on-nil-method raise. The planner's contract is "never raises except the nil-arg
    --- guard and a missing structural buy dep", so the caller skips + WARNs such a row (deduped)
    --- instead - the same fail-closed posture as the nil-identity skip. Owned non-price ops
    --- (castrate/naming/ai) never reach here.
    ---@param animal table identity-valid candidate
    ---@param needsCanBeSold boolean true for Sell (also needs getCanBeSold)
    ---@return boolean priceable
    local function isPriceableAnimal(animal, needsCanBeSold)
        if type(animal.getSellPrice) ~= "function" then return false end
        if needsCanBeSold and type(animal.getCanBeSold) ~= "function" then return false end
        return true
    end

    --- Skip + WARN (deduped via warnedAnimals) a matched candidate that lacks the real-Animal
    --- price methods, keeping the planner's never-raises contract on the price path.
    ---@param animal table
    local function warnNotPriceable(animal)
        if not warnedAnimals[animal] then
            Log:warning("%s skipping candidate without real-Animal price methods (uniqueId=%s) - not an Animal instance",
                LOG_PREFIX, tostring(type(animal) == "table" and animal.uniqueId or animal))
            warnedAnimals[animal] = true
        end
    end

    --- True when a dewar's sire (`dewar.animal`) carries the identity fields the REAL
    --- getCanBeInseminatedByAnimal reads on the sire: `typeIndex` (compared to the female's
    --- `animalTypeIndex`), `farmId`, `uniqueId`, and a `country` present in `RLConstants.AREA_CODES`.
    --- The predicate formats `AREA_CODES[otherAnimal.country].code` UNCONDITIONALLY, so a sire with a
    --- nil / unknown country (or any missing identity field) would raise; the AI caller treats such a
    --- dewar as incompatible + WARN instead, honouring the planner's never-raises contract.
    ---@param sire table|nil dewar.animal
    ---@return boolean usable
    local function isUsableSire(sire)
        if type(sire) ~= "table" then return false end
        if sire.typeIndex == nil or sire.farmId == nil or sire.uniqueId == nil then return false end
        local country = sire.country
        return country ~= nil and RLConstants.AREA_CODES[country] ~= nil
    end

    --- Seed the planner-wide straw ledger for a dewar exactly once from `d.straws` (non-number /
    --- nil -> 0). Keyed by the dewar table ref so the remaining count threads across every AI rule
    --- in the pass. Idempotent: a dewar legitimately seeded to 0 (seeded value is not nil) is never
    --- re-seeded, so prior rules' decrements survive.
    ---@param d table dewar record
    local function seedDewarStraws(d)
        if dewarStrawLedger[d] == nil then
            dewarStrawLedger[d] = type(d.straws) == "number" and d.straws or 0
        end
    end

    -- ---- 1. Filter to runnable rules. ----
    local runnable = {}
    for _, rule in ipairs(rules) do
        if type(rule) ~= "table" then
            Log:warning("%s skipping non-table rule entry", LOG_PREFIX)
        elseif rule.enabled ~= true then
            Log:debug("%s skip rule=%s: disabled", LOG_PREFIX, tostring(rule.id))
        elseif OPERATION_RANK[rule.operation] == nil then
            Log:warning("%s skip rule=%s: unknown operation '%s' (not in OPERATION_ORDER)",
                LOG_PREFIX, tostring(rule.id), tostring(rule.operation))
        elseif rule.operation ~= "naming" and rule.filterId == nil then
            Log:debug("%s skip rule=%s op=%s: nil filterId (incomplete draft, never runs)",
                LOG_PREFIX, tostring(rule.id), tostring(rule.operation))
        else
            runnable[#runnable + 1] = rule
        end
    end

    -- ---- 2. Sort by operation rank, then within-op name comparator. ----
    table.sort(runnable, function(a, b)
        local ra, rb = OPERATION_RANK[a.operation], OPERATION_RANK[b.operation]
        if ra ~= rb then return ra < rb end
        return RLHerdsmanRuleService.compareRulesByName(a, b)
    end)

    -- ---- 3. Per rule, select candidates per target and emit actions. ----
    local actions = {}
    for _, rule in ipairs(runnable) do
        local op = rule.operation
        local traits = RLHerdsmanPlanner.OPERATION_TRAITS[op]
        local params = type(rule.params) == "table" and rule.params or {}
        local filter = rule.filterId ~= nil and filtersById[rule.filterId] or nil

        if op == "naming" and rule.filterId ~= nil then
            -- The service floor forbids a naming filterId; a stray one (stale / migrated data)
            -- is ignored - naming has no filter (it selects every remaining unnamed animal) - but
            -- surface it so the mis-tag is visible.
            Log:debug("%s rule=%s op=naming carries a non-nil filterId=%s; ignored (naming has no filter)",
                LOG_PREFIX, tostring(rule.id), tostring(rule.filterId))
        end

        local claimed = claimedByOp[op]
        if claimed == nil then claimed = {}; claimedByOp[op] = claimed end

        local targets, dupes = dedupeSortedTargets(rule.targetHusbandries)
        if dupes > 0 then
            Log:debug("%s rule=%s op=%s: deduped %d duplicate target(s)", LOG_PREFIX, tostring(rule.id), op, dupes)
        end
        if #targets == 0 then
            Log:debug("%s rule=%s op=%s: empty targets, no action", LOG_PREFIX, tostring(rule.id), op)
        end

        if op == "sell" then
            -- Sell needs the real price path; a missing animalSystem is a T4 wiring error -
            -- fail closed (skip + WARN) rather than crash the whole tick.
            if type(animalSystem) ~= "table" then
                Log:warning("%s rule=%s op=sell skipped: ctx.animalSystem missing (T4 wiring)", LOG_PREFIX, tostring(rule.id))
            else
                local maxN = normalizeMaxAnimals(rule, params)
                if maxN ~= nil then
                    local mark = params.mark == true
                    for _, uid in ipairs(targets) do
                        local h = resolveHusbandry(uid)
                        if h ~= nil then
                            local pool = ownedPool(uid)
                            local candidates = #pool
                            -- Shortlist = filter-matched AND sellable (getCanBeSold;
                            -- nil counts as a skip, matching legacy `not getCanBeSold()`). S =
                            -- shortlist size, pre-cap (the wage's `min(S, n*5)` operand).
                            local matched = matchFromPool(pool, filter, false, claimed)
                            local shortlist = {}
                            for _, a in ipairs(matched) do
                                if not isPriceableAnimal(a, true) then
                                    warnNotPriceable(a)
                                elseif a:getCanBeSold() then
                                    shortlist[#shortlist + 1] = { animal = a, price = priceOf(a, SELL_MARKUP), key = animalKey(a) }
                                end
                            end
                            local S = #shortlist
                            -- Price DESC; equal prices break by the three-field identity key
                            -- (deterministic, and decides which animals a tie straddling the cap takes).
                            table.sort(shortlist, function(x, y)
                                if x.price ~= y.price then return x.price > y.price end
                                return x.key < y.key
                            end)
                            local selected, selectedKeys, amountGained = {}, {}, 0
                            for i = 1, math.min(maxN, S) do
                                local item = shortlist[i]
                                selected[i] = item.animal
                                selectedKeys[item.key] = true
                                amountGained = amountGained + item.price
                            end
                            local n = #selected
                            local W = wageFor(h.animalTypeIndex)
                            local wage = W * n * (mark and 0.35 or 1) + W * math.min(S, n * 5) * 0.15 * (mark and 0.35 or 1)
                            Log:debug("%s rule=%s op=sell husbandry=%s candidates=%d shortlist=%d selected=%d mark=%s amountGained=%.2f wage=%.2f",
                                LOG_PREFIX, tostring(rule.id), tostring(uid), candidates, S, n, tostring(mark), amountGained, wage)
                            if n > 0 then
                                -- Global claim (UNCONDITIONAL, mark OR exec): the selected set
                                -- leaves the owned pool, so no later rule (sell now; castrate/
                                -- naming/ai in T2b) can touch it. Capped-out matches are NOT
                                -- claimed - they stay candidates for a later same-op sell rule.
                                remainingByHusbandry[uid] = poolMinus(pool, selectedKeys)
                                claimAll(claimed, selected)
                                local action = { ruleId = rule.id, operation = "sell", husbandryId = uid,
                                    animals = selected, mark = mark, wage = wage }
                                if not mark then
                                    -- Executed sell: carry proceeds + credit the farm ledger so a
                                    -- later same-farm buy can spend them (a marked sell is advisory
                                    -- only - no amountGained, no money, no event; T3 sets the mark).
                                    action.amountGained = amountGained
                                    seedLedger(rule.farmId)
                                    if type(ledger[rule.farmId]) == "number" then
                                        ledger[rule.farmId] = ledger[rule.farmId] + amountGained
                                    end
                                    -- Executed sell frees engine slots synchronously (T3 dispatches
                                    -- sendLocal in plan order), so credit THIS husbandry's free-slot
                                    -- ledger by the sold count - a later buy here can fill them. Only a
                                    -- SEEDED ledger is credited; a husbandry with nil freeSlots (never a
                                    -- buy target) skips the credit silently (mirror the money-ledger
                                    -- sell-credit nil guard); a marked sell credits nothing (this block).
                                    seedSlotLedger(uid)
                                    if type(slotLedger[uid]) == "number" then
                                        slotLedger[uid] = slotLedger[uid] + n
                                    end
                                end
                                actions[#actions + 1] = action
                            end
                        end
                    end
                end
            end

        elseif op == "move" then
            -- Move is an OUT op (the `removesFromPlanPool` trait it shares with sell): the
            -- selected, capped set leaves its SOURCE plan pool + same-op claim UNCONDITIONALLY
            -- (mark OR exec, success-agnostic - the planner never learns whether the execute
            -- later fails), so no later-ordered rule can plan the moved animals. That is exactly
            -- what keeps a "castrate the rest" rule off the moved breeding bull. R2: the selected
            -- set is deliberately NOT appended to the destination's owned pool this tick - the buy
            -- dest-add is the asymmetry to AVOID, because a move can fail at execute and a same-day
            -- dest-add would resurrect a cross-pen snip; destination rules pick the animals up next
            -- day. No animalSystem guard: move prices nothing (selection reads only a.genetics +
            -- the identity fields, so a non-Animal data table is fine here - the executor resolves
            -- live membership). Genetics has NO floor (unlike AI, which skips a candidate with any
            -- nil/non-number field): move has no genetics requirement, so the per-field-coerced sum
            -- only decides who survives the cap - a whole-nil genetics scores 0 (sorts last) yet
            -- stays selectable.
            local dest = params.destinationHusbandry
            if type(dest) ~= "string" or dest:gsub("%s", "") == "" then
                -- Dest-less / empty-or-whitespace dest -> clean no-op: select nothing, claim
                -- nothing, emit nothing. You cannot relocate without a destination, and claiming
                -- animals out of the pool for a move that does nothing would wrongly suppress
                -- "castrate the rest". Checked ONCE at the rule level (dest is a rule param, not
                -- per-target) BEFORE the target loop and normalizeMaxAnimals, so the no-op cause is
                -- unambiguous.
                Log:debug("%s rule=%s op=move no-op: missing/empty destinationHusbandry (%s)",
                    LOG_PREFIX, tostring(rule.id), tostring(dest))
            else
                local maxN = normalizeMaxAnimals(rule, params)
                if maxN ~= nil then
                    local mark = params.mark == true
                    for _, uid in ipairs(targets) do
                        local h = resolveHusbandry(uid)
                        if h ~= nil then
                            local pool = ownedPool(uid)
                            local candidates = #pool
                            -- Shortlist == ALL matched candidates (no eligibility step between match
                            -- and shortlist, unlike sell's getCanBeSold) -> S == #matched. S exists
                            -- only for the cap and the DEBUG line; it is never a wage operand.
                            local matched = matchFromPool(pool, filter, false, claimed)
                            local shortlist = {}
                            for _, a in ipairs(matched) do
                                -- Per-field-coerced genetics sum: each field contributes its value
                                -- when type == "number", else 0, so a nil / non-number / non-table
                                -- genetics never raises and never skips (fail-soft).
                                local g = a.genetics
                                local gm, gq, gf, gh, gp
                                if type(g) == "table" then gm, gq, gf, gh, gp = g.metabolism, g.quality, g.fertility, g.health, g.productivity end
                                local score = (type(gm) == "number" and gm or 0)
                                    + (type(gq) == "number" and gq or 0)
                                    + (type(gf) == "number" and gf or 0)
                                    + (type(gh) == "number" and gh or 0)
                                    + (type(gp) == "number" and gp or 0)
                                shortlist[#shortlist + 1] = { animal = a, genetics = score, key = animalKey(a), ord = #shortlist + 1 }
                            end
                            local S = #shortlist
                            -- Genetics DESC (the best survive the cap), then identity key ASC, then a
                            -- stable build-order ord tiebreak - the same comparator shape the AI op
                            -- uses, so an equal-sum tie straddling the cap is still deterministic.
                            table.sort(shortlist, function(x, y)
                                if x.genetics ~= y.genetics then return x.genetics > y.genetics end
                                if x.key ~= y.key then return x.key < y.key end
                                return x.ord < y.ord
                            end)
                            local selected, selectedKeys = {}, {}
                            for i = 1, math.min(maxN, S) do
                                local item = shortlist[i]
                                selected[i] = item.animal
                                selectedKeys[item.key] = true
                            end
                            local n = #selected
                            -- Single-term wage (castrate-parity rate): W*0.5*n*(mark?0.35:1). W is
                            -- resolved PER TARGET so a mixed-type multi-target move wages each pen by
                            -- its own type; n = the PLANNED selected count (charge planned, like
                            -- sell/buy/castrate - slice 4's executor scales actual/planned later).
                            local W = wageFor(h.animalTypeIndex)
                            local wage = W * 0.5 * n * (mark and 0.35 or 1)
                            Log:debug("%s rule=%s op=move husbandry=%s candidates=%d shortlist=%d selected=%d mark=%s dest=%s wage=%.2f",
                                LOG_PREFIX, tostring(rule.id), tostring(uid), candidates, S, n, tostring(mark), tostring(dest), wage)
                            if n > 0 then
                                -- R1: the selected set leaves the SOURCE pool + same-op claim,
                                -- UNCONDITIONAL (mark OR exec). Capped-out matches are NOT claimed -
                                -- they stay candidates for a later same-op move and for later cross-op
                                -- rules. R2: NEVER touch ownedPool(dest) - no same-day dest-add.
                                remainingByHusbandry[uid] = poolMinus(pool, selectedKeys)
                                claimAll(claimed, selected)
                                actions[#actions + 1] = { ruleId = rule.id, operation = "move", husbandryId = uid,
                                    animals = selected, destinationHusbandry = dest, mark = mark, wage = wage }
                            end
                        end
                    end
                end
            end

        elseif op == "buy" then
            if type(animalSystem) ~= "table" then
                Log:warning("%s rule=%s op=buy skipped: ctx.animalSystem missing (T4 wiring)", LOG_PREFIX, tostring(rule.id))
            else
                local maxN = normalizeMaxAnimals(rule, params)
                -- Gate on maxAnimals FIRST (frozen Buy boundary); validate budget only for a rule
                -- that would actually run, so a maxAnimals-dead rule stays quiet (no spurious WARN).
                local budgetType, budgetFixed, budgetPct, badBudget
                if maxN ~= nil then
                    budgetType, budgetFixed, budgetPct, badBudget = validateBuyBudget(rule, params)
                end
                if maxN ~= nil and not badBudget then
                    for _, uid in ipairs(targets) do
                        local h = resolveHusbandry(uid)
                        if h ~= nil then
                            -- SPACE gate BEFORE the money gate (mirror AIAnimalBuyEvent.validate -
                            -- space then money). seedSlotLedger reads ctx.husbandries[uid].freeSlots
                            -- once; the running slot count threads executed-sell credits + buy debits,
                            -- so a same-tick sell frees barn space before a later buy fills it.
                            seedSlotLedger(uid)
                            local slotsRemaining = slotLedger[uid]
                            if slotsRemaining == nil then
                                -- Missing / non-number / non-finite freeSlots at a buy target -> fail
                                -- closed (skip + WARN, deduped per uid). T4 sources freeSlots
                                -- unconditionally; a nil here is fabricated / test ctx.
                                if not warnedSlots[uid] then
                                    Log:warning("%s rule=%s op=buy husbandry=%s skipped: missing/non-finite freeSlots - fail closed",
                                        LOG_PREFIX, tostring(rule.id), tostring(uid))
                                    warnedSlots[uid] = true
                                end
                            elseif slotsRemaining <= 0 then
                                -- No space: full barn (seed <= 0) vs ledger-exhausted (an earlier buy
                                -- on THIS husbandry consumed every slot this tick) - distinct causes.
                                if slotSeed[uid] <= 0 then
                                    Log:debug("%s rule=%s op=buy husbandry=%s no-op: full barn (freeSlots <= 0: %d)",
                                        LOG_PREFIX, tostring(rule.id), tostring(uid), slotsRemaining)
                                else
                                    Log:debug("%s rule=%s op=buy husbandry=%s no-op: slot ledger exhausted by earlier buys (seed=%d)",
                                        LOG_PREFIX, tostring(rule.id), tostring(uid), slotSeed[uid])
                                end
                            else
                                seedLedger(rule.farmId)
                                local balance = ledger[rule.farmId]
                                if type(balance) ~= "number" then
                                    -- nil farm balance -> fail closed (mirror T1's nil-identity posture).
                                    Log:warning("%s rule=%s op=buy husbandry=%s skipped: nil farm balance (ledger[%s])",
                                        LOG_PREFIX, tostring(rule.id), tostring(uid), tostring(rule.farmId))
                                elseif balance <= 0 then
                                    -- Zero / negative balance -> no-op. MUST gate BEFORE math.clamp:
                                    -- the real engine math.clamp RAISES on max < min (clamp(_, 0, <0)),
                                    -- so a negative balance must never reach it (the headless IMPL is
                                    -- lenient and masked this; filed as a lib-fidelity follow-up).
                                    Log:debug("%s rule=%s op=buy husbandry=%s no-op: balance <= 0 (%.2f)",
                                        LOG_PREFIX, tostring(rule.id), tostring(uid), balance)
                                else
                                    local budget = (budgetType == "percentage")
                                        and math.floor(balance * budgetPct / 100) or budgetFixed
                                    budget = math.clamp(budget, 0, balance)   -- balance > 0 here -> clamp safe
                                    if budget <= 0 then
                                        -- A 0% percentage (or a fixed budget that floors to 0) on a
                                        -- positive balance -> no-op this target.
                                        Log:debug("%s rule=%s op=buy husbandry=%s no-op: budget <= 0 (balance=%.2f)",
                                            LOG_PREFIX, tostring(rule.id), tostring(uid), balance)
                                    else
                                        local typeIdx = h.animalTypeIndex
                                        local pool = dealerPool(typeIdx)
                                        local candidates = #pool   -- BEFORE filter + affordability
                                        local matched = matchFromPool(pool, filter, false, claimed)
                                        -- Affordable shortlist (price <= budget); S = shortlist size.
                                        local shortlist = {}
                                        for _, a in ipairs(matched) do
                                            if not isPriceableAnimal(a, false) then
                                                warnNotPriceable(a)
                                            else
                                                local p = priceOf(a, buyMarkup)
                                                if p <= budget then
                                                    shortlist[#shortlist + 1] = { animal = a, price = p, key = animalKey(a) }
                                                end
                                            end
                                        end
                                        local S = #shortlist
                                        table.sort(shortlist, function(x, y)
                                            if x.price ~= y.price then return x.price < y.price end
                                            return x.key < y.key
                                        end)
                                        local selected, selectedKeys, amountSpent = {}, {}, 0
                                        local selectedItems = {}
                                        local remaining = budget
                                        for _, item in ipairs(shortlist) do
                                            -- Three break conditions: budget (strict `>`, so a candidate
                                            -- priced exactly at the remainder IS bought), the maxAnimals
                                            -- cap, and free slots (one animal == one slot). slotsRemaining
                                            -- is the ledger value at this target's entry.
                                            if item.price > remaining or #selected >= maxN or #selected >= slotsRemaining then break end
                                            selected[#selected + 1] = item.animal
                                            selectedItems[#selectedItems + 1] = item
                                            selectedKeys[item.key] = true
                                            amountSpent = amountSpent + item.price
                                            remaining = remaining - item.price
                                        end
                                        local n = #selected
                                        local W = wageFor(typeIdx)
                                        local wage = W * n + W * math.min(S, n * 5) * 0.15
                                        -- `matched` distinguishes the three Buy no-op causes (T8.1):
                                        -- matched=0 filter-empty; matched>0 & affordable=0 all-unaffordable;
                                        -- affordable>0 & selected<cap budget-OR-slot-consumed mid-loop.
                                        Log:debug("%s rule=%s op=buy husbandry=%s markup=%.3f candidates=%d matched=%d affordable=%d selected=%d slotsAtEntry=%d budgetAtEntry=%.2f amountSpent=%.2f wage=%.2f",
                                            LOG_PREFIX, tostring(rule.id), tostring(uid), buyMarkup, candidates, #matched, S, n, slotsRemaining, budget, amountSpent, wage)
                                        -- Per-animal price breakdown for the SELECTED set only - bounded by
                                        -- maxAnimals, so it can never become a per-candidate flood. The
                                        -- aggregate line above names no animal and does not show how the
                                        -- markup and the transport fee split the charge, which leaves a
                                        -- charged price impossible to audit against the dealer list. The fee
                                        -- is derived by subtraction from the already-computed total rather
                                        -- than re-read, so the line is self-verifying
                                        -- (sellPrice * markup + fee == total) at the cost of one
                                        -- getSellPrice call. Level-guarded because Lua evaluates log
                                        -- arguments BEFORE the logger checks the level.
                                        if Log.level >= RmLogging.LOG_LEVEL.DEBUG then
                                            for _, item in ipairs(selectedItems) do
                                                local a = item.animal
                                                local sell = a:getSellPrice()
                                                Log:debug("%s rule=%s op=buy husbandry=%s bought uniqueId=%s farmId=%s subType=%s age=%s sellPrice=%.4f markup=%.3f fee=%.2f total=%.4f",
                                                    LOG_PREFIX, tostring(rule.id), tostring(uid), tostring(a.uniqueId),
                                                    tostring(a.farmId), tostring(a.subTypeIndex), tostring(a.age),
                                                    sell, buyMarkup, item.price - sell * buyMarkup, item.price)
                                            end
                                        end
                                        if n > 0 then
                                            -- Remove bought from the dealer pool; claim same-op; append
                                            -- to the destination owned pool (cross-op visible); debit the
                                            -- money ledger (no double-spend) AND the slot ledger (the
                                            -- destination has n fewer free slots for a later buy).
                                            dealerRemaining[typeIdx] = poolMinus(pool, selectedKeys)
                                            claimAll(claimed, selected)
                                            local destPool = ownedPool(uid)
                                            if destPool ~= nil then
                                                for _, a in ipairs(selected) do destPool[#destPool + 1] = a end
                                            end
                                            ledger[rule.farmId] = ledger[rule.farmId] - amountSpent
                                            slotLedger[uid] = slotLedger[uid] - n
                                            actions[#actions + 1] = { ruleId = rule.id, operation = "buy", husbandryId = uid,
                                                animals = selected, amountSpent = amountSpent, wage = wage }
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end

        elseif op == "castrate" then
            -- Castrate (legacy `AIAnimalManager:onDayChanged`'s castrate leg): owned-herd, no cap,
            -- no sort, sequential.
            -- Resolve the husbandry FIRST (malformed -> skip + WARN, unchanged), THEN per-target
            -- no-op a chicken-type husbandry (other targets of a multi-target rule proceed).
            -- Candidates come via the filter; per survivor apply legacy's hard floor, the one the user
            -- filter cannot express - female / already-castrated / infertile - plus a nil-genetics
            -- guard (fail closed). `mark` (coerced == true) only sets the action field that gates the
            -- T3 mutation, never the claim. Same-op claim (mark-independent), cross-op visible
            -- (survivors stay in the owned pool - one animal may be castrated AND named the same day).
            local mark = params.mark == true
            for _, uid in ipairs(targets) do
                local h = resolveHusbandry(uid)
                if h ~= nil then
                    if chickenTypeIndex ~= nil and h.animalTypeIndex == chickenTypeIndex then
                        Log:debug("%s rule=%s op=castrate husbandry=%s: chicken-type target no-op (legacy parity); other targets proceed",
                            LOG_PREFIX, tostring(rule.id), tostring(uid))
                    else
                        local pool = ownedPool(uid)
                        local candidates = #pool
                        local matched = matchFromPool(pool, filter, false, claimed)
                        local selected = {}
                        for _, a in ipairs(matched) do
                            local g = a.genetics
                            if a.gender == "female" or a.isCastrated then
                                -- Hard floor (legacy's castrate hard-skip), silent. Checked first so the genetics read is
                                -- short-circuited for females (legacy reaches genetics.fertility only past here).
                            elseif type(g) ~= "table" or g.fertility == nil then
                                -- nil genetics/fertility -> skip + WARN (never index-nil; fail-closed
                                -- posture). Deduped per call (warnedAnimals - the pool is re-scanned per op).
                                if not warnedAnimals[a] then
                                    Log:warning("%s rule=%s op=castrate skipping animal with nil genetics/fertility (uniqueId=%s) - fail closed",
                                        LOG_PREFIX, tostring(rule.id), tostring(type(a) == "table" and a.uniqueId or a))
                                    warnedAnimals[a] = true
                                end
                            elseif g.fertility == 0 then
                                -- Infertile -> hard-skip (same legacy hard floor), silent.
                            else
                                selected[#selected + 1] = a
                            end
                        end
                        local n = #selected
                        local W = wageFor(h.animalTypeIndex)
                        -- Single-term wage (legacy's castrate wage) - NO min(S, n*5) shortlist component (that is a
                        -- sell/buy-only term). mark halves-then-discounts to the 0.35 advisory rate.
                        local wage = W * 0.5 * n * (mark and 0.35 or 1)
                        Log:debug("%s rule=%s op=castrate husbandry=%s candidates=%d selected=%d mark=%s wage=%.2f",
                            LOG_PREFIX, tostring(rule.id), tostring(uid), candidates, n, tostring(mark), wage)
                        if n > 0 then
                            -- Same-op claim covers EVERY survivor (mark-independent): a later castrate
                            -- rule cannot re-pick them; they stay in the pool for naming/ai (cross-op).
                            claimAll(claimed, selected)
                            actions[#actions + 1] = { ruleId = rule.id, operation = "castrate", husbandryId = uid,
                                animals = selected, mark = mark, wage = wage }
                        end
                    end
                end
            end

        elseif op == "naming" then
            -- Naming (legacy `AIAnimalManager:onDayChanged`'s naming leg): owned-herd, no filter
            -- (selects ALL remaining), narrowed to unnamed-only (exact ~= "" - a whitespace-only
            -- name counts as named).
            -- No cap, no mark. Needs the real name system (DI) for getNamesAlphabetical; a missing one
            -- is a T4 wiring error -> fail closed (skip + WARN), mirroring the sell/buy guard.
            if type(animalNameSystem) ~= "table" or type(animalNameSystem.getNamesAlphabetical) ~= "function" then
                Log:warning("%s rule=%s op=naming skipped: ctx.animalNameSystem missing/invalid (T4 wiring)", LOG_PREFIX, tostring(rule.id))
            else
                -- convention (legacy's naming-convention branch): "random" -> random; anything else -> alphabetical (the legacy
                -- else-branch), WARN when it is not literally "alphabetical" (stale "" / "legacy" / nil).
                local convention = params.convention
                local isRandom = convention == "random"
                local conventionOut = isRandom and "random" or "alphabetical"
                if not isRandom and convention ~= "alphabetical" then
                    Log:warning("%s rule=%s op=naming: convention '%s' is not 'random'/'alphabetical' - treating as alphabetical (legacy else-branch)",
                        LOG_PREFIX, tostring(rule.id), tostring(convention))
                end
                -- One per-rule cursor (rule.params.previous), shared across the male/female lists (the
                -- legacy quirk, kept). "" is the wire's nil sentinel and ANY non-string is corrupt
                -- persisted data -> normalize to nil (start of sequence) instead of letting walkCursor's
                -- `name > prev` raise on a number/table (fail-closed, like normalizeMaxAnimals/validateBuyBudget).
                local cursor = params.previous
                if type(cursor) ~= "string" or cursor == "" then cursor = nil end
                -- The cursor threads across the WHOLE rule in deterministic uid order, NOT per-target:
                -- which animal gets which name is a pure function of the rule's candidate set + toKey
                -- order, independent of how animals are grouped into target husbandries (spec: "which
                -- animal gets which alphabetical name is reproducible"). Gather every unnamed unclaimed
                -- candidate across all targets into one stream, sort ONCE by toKey, walk the shared
                -- cursor, then partition the named animals back into per-target actions.
                local stream = {}    -- { { animal = a, uid = <husbandry uid> }, ... } rule-wide
                local byTarget = {}  -- [uid] = { h, candidates, named = {}, assignments = {} }
                for _, uid in ipairs(targets) do
                    local h = resolveHusbandry(uid)
                    if h ~= nil then
                        local pool = ownedPool(uid)
                        byTarget[uid] = { h = h, candidates = #pool, named = {}, assignments = {} }
                        -- noFilter (naming trait): every remaining unclaimed animal, then unnamed-only.
                        local matched = matchFromPool(pool, filter, traits.noFilter == true, claimed)
                        for _, a in ipairs(matched) do
                            if a.name == nil or a.name == "" then
                                stream[#stream + 1] = { animal = a, uid = uid }
                            end
                        end
                    end
                end
                -- Deterministic rule-wide order via the three-field identity key (nil-key animals were
                -- already dropped by matchFromPool, so every stream entry has a key).
                table.sort(stream, function(x, y) return animalKey(x.animal) < animalKey(y.animal) end)
                for _, item in ipairs(stream) do
                    local a = item.animal
                    local names = animalNameSystem:getNamesAlphabetical(a.gender)
                    if type(names) == "table" and #names > 0 then
                        local bucket = byTarget[item.uid]
                        if isRandom then
                            -- Random: T3 generates the string; the planner only selects + counts
                            -- (non-empty list) for wage and never advances the cursor.
                            bucket.named[#bucket.named + 1] = a
                        else
                            local assignedName
                            assignedName, cursor = walkCursor(names, cursor)
                            bucket.named[#bucket.named + 1] = a
                            bucket.assignments[#bucket.assignments + 1] = { animal = a, name = assignedName }
                        end
                    else
                        -- Empty gender list (legacy's per-gender ipairs never runs) -> skip: no name, not counted,
                        -- cursor unchanged.
                        Log:debug("%s rule=%s op=naming husbandry=%s: empty name list for gender=%s (uniqueId=%s) - skipped, uncounted",
                            LOG_PREFIX, tostring(rule.id), tostring(item.uid), tostring(a.gender), tostring(a.uniqueId))
                    end
                end
                -- Emit one action per target (lexicographic target order) that named >= 1 animal; the
                -- per-husbandry wage uses that husbandry's type. `previousOut` is the RULE-FINAL cursor
                -- (after the whole rule-wide walk) - the same value on every action of the rule, so T3
                -- writes rule.params.previous back once per rule regardless of which action it reads.
                for _, uid in ipairs(targets) do
                    local bucket = byTarget[uid]
                    if bucket ~= nil then
                        local named = bucket.named
                        local n = #named
                        local W = wageFor(bucket.h.animalTypeIndex)
                        local wage = W * 0.15 * n   -- single term (legacy's naming wage), no shortlist component
                        Log:debug("%s rule=%s op=naming husbandry=%s candidates=%d named=%d convention=%s wage=%.2f",
                            LOG_PREFIX, tostring(rule.id), tostring(uid), bucket.candidates, n, conventionOut, wage)
                        if n > 0 then
                            -- Same-op claim covers the named set; cross-op visible (named animals stay
                            -- in the owned pool - one animal may be castrated AND named the same day).
                            claimAll(claimed, named)
                            local action = { ruleId = rule.id, operation = "naming", husbandryId = uid,
                                animals = named, convention = conventionOut, wage = wage }
                            if not isRandom then
                                -- assignments + previousOut iff alphabetical AND >= 1 named (random omits both).
                                action.assignments = bucket.assignments
                                action.previousOut = cursor
                            end
                            actions[#actions + 1] = action
                        end
                    end
                end
            end

        elseif op == "ai" then
            -- AI / insemination (legacy `AIAnimalManager:onDayChanged`'s AI leg). Owned-herd,
            -- non-end-task, the LAST op. Ritter-locked genetics-first deviation: legacy assigns
            -- scarce straws during shortlist build in nondeterministic `pairs` order BEFORE the
            -- genetics sort, during its shortlist build; this planner collects compatible dewars straw-IGNORANT,
            -- sorts candidates genetics-desc FIRST, then greedily assigns scarce straws best-first
            -- against the planner-wide dewar-identity ledger. NOT byte-parity (legacy is
            -- nondeterministic); because greedy straw assignment is an order-dependent bipartite
            -- matching, in the rare multi-dewar cross-compatible scarce-straw case it can inseminate
            -- FEWER total animals (lower S/wage) than legacy - accepted to prioritise the best
            -- genetics. The real getCanBeInseminatedByAnimal is the SOLE eligibility gate (NO
            -- fertility==0 check); a marked AI is advisory (T3 sets the mark, dispatches no event).
            local maxN = normalizeMaxAnimals(rule, params)
            if maxN ~= nil then
                local mark = params.mark == true
                local semen = params.semen
                for _, uid in ipairs(targets) do
                    local h = resolveHusbandry(uid)
                    if h ~= nil then
                        local typeIdx = h.animalTypeIndex
                        -- Dewar pool (legacy's AI dewar gather): farm scope = rule.farmId (the key T2a's money
                        -- ledger uses; == legacy husbandry:getOwnerFarmId() since T4 farm-scopes rules),
                        -- type = husbandry.animalTypeIndex. The farmId value type MUST match the table
                        -- key type (mirror farmBalanceByFarmId, else a silent "no dewars"). DewarManager
                        -- stores insert-order, so the planner sorts the bucket by uniqueId itself.
                        local farmBucket = dewarsByFarmId[rule.farmId]
                        local rawBucket = type(farmBucket) == "table" and farmBucket[typeIdx] or nil
                        local sortedBucket = {}
                        if type(rawBucket) == "table" then
                            for _, d in ipairs(rawBucket) do
                                if type(d) == "table" and d.animal ~= nil then
                                    if d.uniqueId == nil then
                                        -- nil uniqueId -> the action `dewars` value would be nil; skip + WARN.
                                        if not warnedDewars[d] then
                                            Log:warning("%s rule=%s op=ai husbandry=%s: dewar with nil uniqueId skipped",
                                                LOG_PREFIX, tostring(rule.id), tostring(uid))
                                            warnedDewars[d] = true
                                        end
                                    else
                                        sortedBucket[#sortedBucket + 1] = d
                                    end
                                end
                                -- d.animal == nil never inseminates (legacy drops a nil sire) -> silently dropped.
                            end
                            table.sort(sortedBucket, function(x, y) return tostring(x.uniqueId) < tostring(y.uniqueId) end)
                        end
                        -- Semen resolution: "any" -> the whole sorted bucket; a specific uniqueId ->
                        -- the FIRST matching dewar (uniqueId order); not found / empty bucket -> no action.
                        local dewars, semenNotFound = nil, false
                        if #sortedBucket > 0 then
                            if semen == "any" then
                                dewars = sortedBucket
                            else
                                for _, d in ipairs(sortedBucket) do
                                    if d.uniqueId == semen then dewars = { d }; break end
                                end
                                if dewars == nil then semenNotFound = true end
                            end
                        end

                        if dewars == nil then
                            -- Distinct no-action causes: a specific semen matching no dewar is a
                            -- likely config error (WARN); a nil/empty farm-or-type bucket is routine (DEBUG).
                            if semenNotFound then
                                Log:warning("%s rule=%s op=ai husbandry=%s: semen '%s' matched no dewar (likely config error) - no action",
                                    LOG_PREFIX, tostring(rule.id), tostring(uid), tostring(semen))
                            else
                                Log:debug("%s rule=%s op=ai husbandry=%s no-op: no dewars for farm/type (farmId=%s typeIndex=%s)",
                                    LOG_PREFIX, tostring(rule.id), tostring(uid), tostring(rule.farmId), tostring(typeIdx))
                            end
                        else
                            -- Seed the planner-wide straw ledger for every resolved dewar (once each), so
                            -- remaining straws thread across ALL AI rules (no cross-rule overcommit).
                            for _, d in ipairs(dewars) do seedDewarStraws(d) end
                            local pool = ownedPool(uid)
                            -- Candidate eligibility (legacy's AI candidate loop): filter-matched (matchFromPool) AND
                            -- not same-op-claimed (matchFromPool, so claimed animals never reach the scratch
                            -- assignment) AND >= 1 compatible dewar. Straw-IGNORANT here - the predicate is
                            -- pure, so collecting ALL compatible dewars (vs legacy's first-match break)
                            -- is observationally safe and is the mechanism behind the genetics-first deviation.
                            local matched = matchFromPool(pool, filter, false, claimed)
                            local candidates = {}
                            for _, a in ipairs(matched) do
                                local g = a.genetics
                                local gm, gq, gf, gh, gp
                                if type(g) == "table" then gm, gq, gf, gh, gp = g.metabolism, g.quality, g.fertility, g.health, g.productivity end
                                local geneticsOk = type(gm) == "number" and type(gq) == "number"
                                    and type(gf) == "number" and type(gh) == "number" and (gp == nil or type(gp) == "number")
                                if not geneticsOk then
                                    -- nil / non-number genetics sub-field -> skip + WARN (fail closed; never
                                    -- index-nil in the sum). Deduped per call (the pool is re-scanned per op).
                                    if not warnedAnimals[a] then
                                        Log:warning("%s rule=%s op=ai skipping animal with nil/non-number genetics (uniqueId=%s) - fail closed",
                                            LOG_PREFIX, tostring(rule.id), tostring(type(a) == "table" and a.uniqueId or a))
                                        warnedAnimals[a] = true
                                    end
                                elseif type(a.getCanBeInseminatedByAnimal) ~= "function" then
                                    -- A matched row can carry a valid identity + genetics yet be a non-Animal data
                                    -- table without the real predicate method (the AI analog of Sell/Buy's
                                    -- isPriceableAnimal guard) - skip + WARN (deduped), never a call-on-nil-method raise.
                                    if not warnedAnimals[a] then
                                        Log:warning("%s rule=%s op=ai skipping candidate without getCanBeInseminatedByAnimal (uniqueId=%s) - not an Animal instance",
                                            LOG_PREFIX, tostring(rule.id), tostring(type(a) == "table" and a.uniqueId or a))
                                        warnedAnimals[a] = true
                                    end
                                else
                                    -- Compatible dewars in uniqueId order (straw-ignorant). A malformed sire
                                    -- (missing identity / country not in AREA_CODES) is treated incompatible +
                                    -- WARN, never indexed-nil/raised, via isUsableSire before the predicate.
                                    local compatible = {}
                                    for _, d in ipairs(dewars) do
                                        local sire = d.animal
                                        if not isUsableSire(sire) then
                                            if not warnedDewars[d] then
                                                Log:warning("%s rule=%s op=ai husbandry=%s: malformed sire on dewar uniqueId=%s (missing identity / country not in AREA_CODES) - treated incompatible",
                                                    LOG_PREFIX, tostring(rule.id), tostring(uid), tostring(d.uniqueId))
                                                warnedDewars[d] = true
                                            end
                                        elseif a:getCanBeInseminatedByAnimal(sire) == true then
                                            compatible[#compatible + 1] = d
                                        end
                                    end
                                    if #compatible >= 1 then
                                        candidates[#candidates + 1] = {
                                            animal = a,
                                            genetics = gm + gq + gf + gh + (gp or 0),
                                            compatibleDewars = compatible,
                                            key = animalKey(a),
                                            ord = #candidates + 1,
                                        }
                                    end
                                end
                            end
                            local eligibleCount = #candidates
                            -- Genetics DESC, then identity key (toKey) ASC, then a stable ord tiebreak so a
                            -- toKey collision is still deterministic (decides who straddles the cap).
                            table.sort(candidates, function(x, y)
                                if x.genetics ~= y.genetics then return x.genetics > y.genetics end
                                if x.key ~= y.key then return x.key < y.key end
                                return x.ord < y.ord
                            end)
                            -- Greedy best-first straw assignment against a per-rule SCRATCH view of the
                            -- planner-wide ledger (its current remaining already reflects prior AI rules'
                            -- commits). The assignable set (genetics order) defines S over ALL candidates, uncapped.
                            local scratch = {}
                            local assignable = {}
                            for _, c in ipairs(candidates) do
                                for _, d in ipairs(c.compatibleDewars) do
                                    local rem = scratch[d]
                                    if rem == nil then rem = dewarStrawLedger[d] or 0; scratch[d] = rem end
                                    if rem >= 1 then
                                        scratch[d] = rem - 1
                                        assignable[#assignable + 1] = { animal = c.animal, dewar = d }
                                        break
                                    end
                                end
                            end
                            local S = #assignable
                            local n = math.min(maxN, S)
                            -- Cap-then-claim: inseminate the first n of the assignable (genetics-best) set;
                            -- commit ONLY their straws to the planner-wide ledger (capped-out candidates
                            -- consume nothing and stay available for a later AI rule).
                            local inseminatedAnimals, inseminatedDewars = {}, {}
                            for i = 1, n do
                                local item = assignable[i]
                                inseminatedAnimals[i] = item.animal
                                inseminatedDewars[i] = item.dewar.uniqueId
                                dewarStrawLedger[item.dewar] = (dewarStrawLedger[item.dewar] or 0) - 1
                            end
                            local W = wageFor(typeIdx)
                            -- Wage (legacy's AI wage): per-animal 1.2 exec / 0.45 mark, plus the shortlist term
                            -- min(S, n*5)*0.2 at 1.0 exec / 0.35 mark - over THIS planner's S/n.
                            local wage = W * n * (mark and 0.45 or 1.2)
                                + W * math.min(S, n * 5) * 0.2 * (mark and 0.35 or 1)
                            Log:debug("%s rule=%s op=ai husbandry=%s eligible=%d assignable=%d inseminated=%d wage=%.2f mark=%s semen=%s",
                                LOG_PREFIX, tostring(rule.id), tostring(uid), eligibleCount, S, n, wage, tostring(mark), tostring(semen))
                            if n > 0 then
                                -- Same-op claim covers ONLY the inseminated set (two AI rules never inseminate
                                -- one animal); AI is the last op so cross-op visibility is moot. mark never gates the claim.
                                claimAll(claimed, inseminatedAnimals)
                                actions[#actions + 1] = { ruleId = rule.id, operation = "ai", husbandryId = uid,
                                    animals = inseminatedAnimals, dewars = inseminatedDewars, mark = mark, wage = wage }
                            elseif eligibleCount == 0 then
                                Log:debug("%s rule=%s op=ai husbandry=%s no-op: no eligible candidates", LOG_PREFIX, tostring(rule.id), tostring(uid))
                            else
                                Log:debug("%s rule=%s op=ai husbandry=%s no-op: %d eligible but all straws exhausted",
                                    LOG_PREFIX, tostring(rule.id), tostring(uid), eligibleCount)
                            end
                        end
                    end
                end
            end

        elseif op == "horseCare" then
            -- Horse care: owned-herd, HORSE-only, no cap, no sort, no mark, sequential. Structurally
            -- the castrate arm (resolve husbandry -> per-target type gate -> ownedPool -> matchFromPool
            -- -> wage -> DEBUG row -> claimAll + emit) minus the per-survivor hard floor and all mark
            -- handling: the filter is the ONLY narrowing beyond the type gate.
            --
            -- The gate FAILS CLOSED (see horseTypeIndex above): a nil index or a non-HORSE target
            -- selects nothing. A non-HORSE target of a multi-target rule is a per-target no-op - the
            -- rule's OTHER targets still proceed, matching castrate's chicken skip.
            --
            -- NO IDEMPOTENCY GATE, and that is load-bearing rather than an oversight. Skipping a horse
            -- already at riding 100 / dirt 0 would re-import the exact barn-ordering variance the
            -- executor's deferral exists to remove: planning runs INLINE while the care write is
            -- DEFERRED, so at plan time a horse reads 100 on a barn whose own day tick has not run yet
            -- and 0 on one whose has. Selection would then depend on how the barn was acquired.
            -- The SYSTEMIC nil deserves a WARNING, once per rule, and is NOT the same event as an
            -- ordinary per-target type mismatch: if AnimalType.HORSE never resolved, horse care
            -- silently never runs on ANY pen, and at the stable INFO level a per-target DEBUG row
            -- leaves no evidence of it at all. This matters more than usual because the fail-closed
            -- nil leg has no automated coverage - the log is its only observability.
            if horseTypeIndex == nil then
                Log:warning("%s rule=%s op=horseCare: AnimalType.HORSE did not resolve - NO pen is targetable this tick (fail closed)",
                    LOG_PREFIX, tostring(rule.id))
            end
            for _, uid in ipairs(targets) do
                local h = resolveHusbandry(uid)
                if h ~= nil then
                    if horseTypeIndex == nil or h.animalTypeIndex ~= horseTypeIndex then
                        Log:debug("%s rule=%s op=horseCare husbandry=%s: non-HORSE target no-op (typeIndex=%s horse=%s); other targets proceed",
                            LOG_PREFIX, tostring(rule.id), tostring(uid), tostring(h.animalTypeIndex), tostring(horseTypeIndex))
                    else
                        local pool = ownedPool(uid)
                        local candidates = #pool
                        local selected = matchFromPool(pool, filter, false, claimed)
                        local n = #selected
                        local W = wageFor(h.animalTypeIndex)
                        -- Single-term wage, the NAMING coefficient (25 * 0.15 = 3.75 per horse for a
                        -- HORSE pen). No min(S, n*5) shortlist component - that term is sell/buy/ai only.
                        --
                        -- Why the coefficient is not higher. Full care buys about +3,500 on a mature
                        -- horse priced off the 36-month sellPrice key of 5,000 - the 0.60 neglected
                        -- multiplier against the 1.30 ceiling - and that is a ONE-OFF realised on a
                        -- MANUAL sale, while this wage recurs every real day for the animal's whole
                        -- life. So the two sides are a rate against a lump sum, and the holding
                        -- period decides which wins: a horse held to 36 months sits on the books for
                        -- 36 * daysPerPeriod real days, 324 of them at daysPerPeriod 9. At 0.15 that
                        -- hold bills 1,215 against the 3,500; the castrate coefficient 0.50 bills
                        -- 4,050 on the same animal and goes underwater. The coefficient is therefore
                        -- bounded by the long-season breeder, not by the default settings, where
                        -- every candidate looks affordable.
                        --
                        -- Two honest limits on that argument. 36 months is not the curve's peak -
                        -- sellPrice keeps rising to 5,500 at 60 months, so the worst-case hold is
                        -- longer than the one costed above. And 0.15 is not unconditionally safe
                        -- either: fitness gain floors to zero above daysPerPeriod 25, which drops
                        -- the realisable delta to about +2,500, so a 36-month hold at the top of the
                        -- selectable range (28) bills 3,780 against it. The claim is that 0.15 is
                        -- the only one of the existing coefficients that stays viable across the
                        -- range players actually use, not that it can never be beaten.
                        local wage = W * 0.15 * n   -- 3.75/horse/day against a one-off ~+3,500 sale delta
                        Log:debug("%s rule=%s op=horseCare husbandry=%s candidates=%d selected=%d wage=%.2f",
                            LOG_PREFIX, tostring(rule.id), tostring(uid), candidates, n, wage)
                        if n > 0 then
                            -- Same-op claim (a later horseCare rule cannot re-pick these); the horses
                            -- STAY in the owned pool so cross-op rules still see them - a horse may be
                            -- cared for and named the same day.
                            claimAll(claimed, selected)
                            actions[#actions + 1] = { ruleId = rule.id, operation = "horseCare", husbandryId = uid,
                                animals = selected, wage = wage }
                        end
                    end
                end
            end
        end
    end

    Log:debug("%s planned %d action(s) from %d runnable rule(s) (of %d input)",
        LOG_PREFIX, #actions, #runnable, type(rules) == "table" and #rules or 0)
    return actions
end

Log:trace("RLHerdsmanPlanner: loaded")
