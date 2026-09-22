-- RLHerdsmanPlanner.lua
-- The pure herdsman day-tick planner.
--
-- `planActions(rules, ctx)` decides WHICH animals each enabled rule acts on, in run order,
-- threading cross-rule claims, a farm-scoped money ledger, a planner-wide dewar straw ledger and a
-- per-husbandry free-slot ledger, and returns ordered intended-action records. The surprising part
-- - sequential state threading across rules - is isolated here in one headless module: data in,
-- data out. It reads no `g_*` and MUST NOT mutate `rules`, `ctx` or any animal / dewar table. The
-- only engine calls are the REAL primitives reached through the injected ctx and the passed-in
-- Animal: the price path, the deterministic naming list, the AI eligibility predicate, and the
-- display predicate the sale gate reads. The
-- animal mutations and event dispatch belong to RLHerdsmanExecutor.
--
-- ctx contract (the day-tick builds it in-game; tests fabricate it from real Animals):
--   ctx = {
--     husbandries         = { [uniqueId] = { animalTypeIndex = n, animals = { Animal, ... }, freeSlots = n } },
--     dealerAnimalsByType = { [animalTypeIndex] = { Animal, ... } },
--     filtersById         = { [filterId] = filterRecord },
--     animalSystem        = <real AnimalSystem>,           -- getAnimalTransportFee
--     animalNameSystem    = <real AnimalNameSystem>,       -- getNamesAlphabetical
--     farmBalanceByFarmId = { [farmId] = balance },        -- money-ledger seed, farm-scoped
--     dewarsByFarmId      = { [farmId] = { [animalTypeIndex] = { {animal=<sire>, straws=n, uniqueId=s}, ... } } },
--     buyMarkup           = number,                        -- active dealer-quality markup
--   }
-- `buyMarkup` is a STRUCTURAL dep, deliberately unguarded and undefaulted: any default this module
-- could pick would be the one wrong number that reading the preset exists to eliminate, so a ctx
-- missing it RAISES on the buy arithmetic rather than pricing every automated purchase at a stale
-- markup. The caller farm-scopes both `rules` and `ctx.husbandries`; the planner filters `enabled`.
-- `farmBalanceByFarmId` and `dewarsByFarmId` are keyed by `rule.farmId`, and the farmId VALUE type
-- must match the table KEY type or both silently read empty. `freeSlots` is the destination
-- husbandry's total free animal-slot count; only Buy requires it.
--
-- Action records, emitted in run order (operation rank, then `compareRulesByName` within an op;
-- within a rule, targets in lexicographic uniqueId order):
--   sell { ruleId, operation="sell", husbandryId, animals=<price desc>, mark, wage, amountGained? }
--        (`amountGained` present iff `mark==false`; a marked sell is advisory - no money, no event)
--   move { ruleId, operation="move", husbandryId=<source>, animals=<genetics desc>, destinationHusbandry, mark, wage }
--        (an OUT op like sell: the selected set leaves the SOURCE plan pool this tick, and the
--        destination-side add lands next day - there is no same-day dest-add)
--   buy  { ruleId, operation="buy",  husbandryId, animals=<price asc>,  amountSpent, wage }
--   castrate { ruleId, operation="castrate", husbandryId, animals=<survivors>, mark, wage }
--   naming   { ruleId, operation="naming", husbandryId, animals=<named>, convention, wage,
--              assignments?, previousOut? } (assignments+previousOut iff alphabetical AND >=1 named)
--   ai { ruleId, operation="ai", husbandryId, animals, dewars, mark, wage }
--   horseCare { ruleId, operation="horseCare", husbandryId, animals=<pool order>, wage }
--        (no `mark` key at all - a stray one would flip the executor row and route it into the
--        message layer's mark-precedence branch)
--
-- Run order is RLHerdsmanRuleService.OPERATION_ORDER: sell frees herd space and funds buys before
-- buy fills the space and spends the proceeds.
--
-- Which animal types an operation may target is NOT decided here: the declarations and the
-- predicate live in RLHerdsmanRuleService, shared with the presenter so the editor and the runtime
-- cannot encode different rules. Every per-target SOURCE resolution goes through
-- `resolveGatedHusbandry`, so an operation gaining a declaration needs no planner edit.
--
-- SCOPE LIMIT, stated because the obvious reading of the line above is wrong: that covers the
-- SOURCE axis only. `move`'s `params.destinationHusbandry` is never resolved or type-checked here,
-- while the presenter DOES gate the destination - so a declaration added for `move` would be
-- honoured by the editor's destination picker and ignored by the runtime on that axis.
--
-- Candidate match is RLFilterEvaluator.evaluate, which fails closed: a nil or deleted filter selects
-- nothing and never raises. Naming carries no filter and selects every remaining UNNAMED animal.

local Log = RmLogging.getLogger("RLRM")

RLHerdsmanPlanner = {}

-- =============================================================================
-- Constants
-- =============================================================================

--- Greppable prefix on every planner log line.
local LOG_PREFIX = "[planActions]"

--- Buy applies the ACTIVE dealer-quality markup on the sell price before adding transport, with the
--- markup injected as `ctx.buyMarkup` rather than compiled in. Sell applies NO markup - which is not
--- "the raw price" either, because the transport fee is still ADDED here, where the player sell path
--- subtracts it.
local SELL_MARKUP = 1.0

--- Per-operation claim traits - how each operation threads state across the sequential rule passes:
---   * `removesFromPlanPool` (sell, move) - an OUT op: a selected animal leaves its SOURCE
---     husbandry's plan pool, so it is absent from every later rule's candidates. The trait NAME is
---     declared here; the actual pool removal lives in each op's dispatch branch.
---   * `sourcesFromDealer` + `addsToHerd` (buy) - candidates come from the dealer pool, and a bought
---     animal joins the destination husbandry's owned pool so later cross-op rules see it.
---   * `noFilter` (naming) - no filter is evaluated; naming selects ALL remaining animals.
--- Every operation ALSO claims same-operation, enforced uniformly by the per-op claimed set. Every
--- registered operation MUST have an entry even with no plan arm: `matchFromPool` reads
--- `traits.noFilter`, so a missing entry would raise the moment a future arm routes through it.
RLHerdsmanPlanner.OPERATION_TRAITS = {
    sell      = { removesFromPlanPool = true },
    move      = { removesFromPlanPool = true },
    buy       = { sourcesFromDealer = true, addsToHerd = true },
    castrate  = {},
    naming    = { noFilter = true },
    ai        = {},
    horseCare = {},
}

--- Herdsman daily wage per animal, keyed by the runtime AnimalType.* index so it matches
--- `husbandry.animalTypeIndex`. A type absent from the table falls back to DEFAULT_WAGE.
local DEFAULT_WAGE = 5
local WAGE_BY_NAME = { COW = 20, SHEEP = 12.5, PIG = 10, HORSE = 25, CHICKEN = 2 }

--- The daily wage rate for an animalType. The index->wage table is built at RUNTIME, not at module
--- load: in-game `AnimalType` is not yet populated when this module is sourced, so a load-time build
--- keys off nil and every wage collapses to DEFAULT_WAGE. Memoized only once `AnimalType` is
--- actually populated, so a too-early call retries instead of poisoning the cache.
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

--- operation -> run-order rank, derived from the service's OPERATION_ORDER. Used to skip
--- unknown-operation rules before sorting and to rank the run.
local OPERATION_RANK = {}
for rank, op in ipairs(RLHerdsmanRuleService.OPERATION_ORDER) do
    OPERATION_RANK[op] = rank
end

--- The planner's SINGLE `AnimalType` read for the operation x animalType gate, behind a module field
--- so a test can swap it - the only way to reach the fail-closed leg from a test, since reassigning
--- the root global does not propagate under the engine's setfenv sandbox.
---
--- Called per `planActions`, never memoized: `AnimalType` is populated after this file is sourced,
--- so a cached empty map would close an allow-list gate for the whole session.
---@return table animalTypeIndexByName map of declared NAME -> live animalType index
function RLHerdsmanPlanner._resolveAnimalTypeIndexMap()
    -- ONE return value, deliberately: the resolver's second is DISCARDED so this seam stays safe in
    -- any argument position, where a two-value call would silently widen its caller's argument list.
    local map = RLHerdsmanRuleService.resolveAnimalTypeIndexMap(AnimalType)
    return map
end

-- =============================================================================
-- Internal helpers (pure)
-- =============================================================================

--- Build the claim-set / dedup key for an animal from its identity triple. Returns nil when ANY
--- identity field is nil - `toKey`'s string concat would otherwise raise - so the caller skips the
--- animal and warns instead of crashing. The three-field key keeps two animals that share a uniqueId
--- across farms or countries distinct, and is the deterministic tie-break for equal-price sorts.
---@param animal table|nil
---@return string|nil key, or nil when an identity field is missing
local function animalKey(animal)
    if type(animal) ~= "table" then return nil end
    local farmId, uniqueId = animal.farmId, animal.uniqueId
    -- Gate the birthday read on table type: a malformed scalar `birthday` must yield a nil key,
    -- never an index-a-scalar raise.
    local country = type(animal.birthday) == "table" and animal.birthday.country or nil
    if farmId == nil or uniqueId == nil or country == nil then
        return nil
    end
    return RLAnimalUtil.toKey(farmId, uniqueId, country)
end

--- Dedupe a rule's target uniqueIds and return them in lexicographic order, plus the number of
--- duplicates dropped. The service stores `targetHusbandries` order-insensitively, so list order
--- carries no semantics; a lexicographic order makes the plan reproducible and pins "first target
--- takes all" for a multi-target buy.
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

--- Coerce a rule's `maxAnimals` param to a positive integer count, or nil when the rule must not
--- run: nil is a never-configured no-op (DEBUG), a non-number is corrupt data (WARN, fail closed),
--- and a number floors to an integer count that must be > 0.
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

--- Validate a Buy rule's `budget` param, failing closed on corrupt data rather than coercing and
--- executing. For type "fixed" only `fixed` must be a number; for "percentage" only `percentage`.
---@param rule table
---@param params table
---@return string|nil budgetType
---@return number|nil budgetFixed
---@return number|nil budgetPercentage
---@return boolean bad true -> skip the rule (a warning is already logged)
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

--- Walk the alphabetical-naming cursor over a sorted name list, given the incoming cursor (already
--- normalized "" -> nil by the caller), and return the assigned name plus the advanced cursor.
--- `names` is guaranteed non-empty by the caller.
---
--- Pick rule: the first index `i` where `prev == nil OR name > prev OR i == #names`; then if `i` is
--- the last index AND `prev == name`, WRAP to `names[1]`. Consequences: a nil cursor yields
--- `names[1]`; a cursor equal to the last name wraps; a stale cursor past the last name picks the
--- LAST name without wrapping; a mid-range cursor not in the list skips ahead; and more animals than
--- names cycles the cursor so names repeat.
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

--- Plan the herdsman day-tick: which animals each enabled rule acts on, in run order, with the
--- two-level claim model and the farm-scoped money ledger threaded across sequential rule passes.
--- Pure: `rules`, `ctx` and every animal table are left unmutated.
---
--- Algorithm:
---   1. Filter to runnable rules: `enabled == true`, operation in OPERATION_ORDER (else skip +
---      WARN), and a non-naming rule with `filterId == nil` is an incomplete draft (skip + DEBUG).
---   2. Sort by operation rank, then `compareRulesByName`.
---   3. Per rule, dedupe and lexicographically order its targets, then per target select candidates
---      from the internal REMAINING pools, apply the per-operation pricing / cap / wage / claim, and
---      emit an action when at least one animal was selected.
---
--- Per-operation selection:
---   * Sell: shortlist = filter-match AND `getCanBeSold()` AND `RLDiseaseSaleGate.check`; price DESC
---     with a toKey tie-break; take the top `maxAnimals`; CLAIM the selected set globally, mark or
---     exec alike; an executed sell credits its proceeds to the farm ledger and its count to the
---     husbandry's slot ledger.
---   * Buy: budget resolved against the running ledger (fail closed on bad params or a nil balance);
---     shortlist = filter-match AND affordable at the buy markup; price ASC; consume cheapest until
---     the next price exceeds the remaining budget, `maxAnimals`, or the free slots; claim from the
---     dealer pool, append to the destination owned pool, debit both ledgers.
---   * Castrate: per survivor hard-skip female / isCastrated / fertility==0 (nil genetics ->
---     skip + WARN); `mark` gates only the executor's mutation. Same-op claim, cross-op visible.
---   * Naming: no filter, unnamed-only; a convention other than "random" is alphabetical (+WARN);
---     the per-rule cursor walk yields `assignments` + `previousOut`, and random defers the strings.
---   * HorseCare: HORSE-only via the fail-closed allow-list gate; filter-match with no hard floor
---     and no idempotency gate. Same-op claim, cross-op visible, no mark, no cap.
---   * AI: filter-match plus the REAL `getCanBeInseminatedByAnimal` (the SOLE eligibility gate) over
---     the rule's farm/type dewar bucket; genetics-desc sort, greedy best-first straw assignment
---     against the planner-wide ledger, cap-then-claim so only the inseminated set commits straws.
---
--- Claim mechanics: owned ops draw from a per-husbandry owned pool (a shallow copy); sell and move
--- remove their CAPPED selected set, so capped-out matches stay candidates for a later same-op rule;
--- castrate / naming / ai keep selected animals in the pool for cross-op visibility but record the
--- per-op claim; buy removes its set from the dealer pool and appends it to the destination pool.
---
--- Edge handling - it never raises except on the nil-arg guard, a missing `ctx.buyMarkup`, and a
--- malformed declaration in `RLHerdsmanRuleService.OPERATION_ANIMAL_TYPES`, whose lists are walked
--- with `ipairs` on the assumption they are arrays: an unresolvable or malformed target husbandry is
--- skipped + WARN once per uid per call; an animal with a nil identity field is skipped + WARN; a
--- deleted filter selects nothing; a missing `ctx.animalSystem` fails a sell/buy rule closed; an
--- empty target list or selection emits no record.
---
---@param rules table[] farm-scoped rule records (the planner filters `enabled`)
---@param ctx table { husbandries, dealerAnimalsByType, filtersById, animalSystem, animalNameSystem, farmBalanceByFarmId, dewarsByFarmId, buyMarkup }
---@return table[] actions ordered action records (see the file header for per-op shapes)
function RLHerdsmanPlanner.planActions(rules, ctx)
    if rules == nil or ctx == nil then
        -- The caller owns construction; a nil top-level arg is a programmer error - fail loud.
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
    -- Read RAW - no coercion, no `or` default. See the structural-dep note in the file header.
    local buyMarkup = ctx.buyMarkup

    -- The declared animal type NAME -> live index map, resolved ONCE per call through the module
    -- seam. A name that does not resolve is simply absent, which is what gives each declaration its
    -- polarity with no special-casing here. Coerced because the seam is swappable: a double
    -- returning nil would otherwise raise on the first index below, and only at DEBUG level.
    local animalTypeIndexByName = RLHerdsmanPlanner._resolveAnimalTypeIndexMap()
    if type(animalTypeIndexByName) ~= "table" then animalTypeIndexByName = {} end
    local declaredTypeNames = RLHerdsmanRuleService.getDeclaredAnimalTypeNames()
    local resolvedTypeNames, missingTypeNames = {}, {}
    for _, name in ipairs(declaredTypeNames) do
        if animalTypeIndexByName[name] ~= nil then
            resolvedTypeNames[#resolvedTypeNames + 1] = string.format("%s=%s", name, tostring(animalTypeIndexByName[name]))
        else
            missingTypeNames[#missingTypeNames + 1] = name
        end
    end
    Log:debug("%s animalType gate map: resolved [%s] missing [%s]",
        LOG_PREFIX, table.concat(resolvedTypeNames, " "), table.concat(missingTypeNames, ","))

    -- Not one declared name resolved, yet the registry declares some: the gate is degenerate for
    -- EVERY operation this tick. An allow-list operation announces itself per rule below, but an
    -- EXCLUSION cannot - an exclusion resolving nothing excludes nothing and reads as a healthy open
    -- gate, so castrate would quietly start castrating chickens. The unwarned polarity is the
    -- dangerous one, so the systemic case is reported once per call here.
    if #declaredTypeNames > 0 and #resolvedTypeNames == 0 then
        Log:warning("%s NO declared animal type resolved this tick [%s] - every operation x animalType gate is degenerate: allow-lists admit nothing, EXCLUSIONS exclude nothing (so an excluded type is now actioned). Check AnimalSystem load order",
            LOG_PREFIX, table.concat(missingTypeNames, ","))
    end

    -- One evalCtx per planActions call: RLFilterEvaluator.evaluate MUTATES its third arg (per-call
    -- warning / type-mismatch dedup sets), so never pass the planner's input ctx through.
    local evalCtx = { warnedFields = {}, typeMismatchFields = {} }

    -- Internal mutable bookkeeping (copies; ctx is never touched):
    --   remainingByHusbandry[uid] - owned animals still available for a husbandry, built lazily.
    --   dealerRemaining[typeIdx]  - dealer animals still available for a type, built lazily.
    --   claimedByOp[op]           - set of claimed animal keys for an op (same-op claim).
    --   ledger[farmId]            - running farm balance projection, seeded once, credited by
    --     executed sells and debited by buys in run order.
    --   ledgerSeeded[farmId]      - distinguishes "not yet seeded" from "seeded to nil" (a
    --     non-number or absent balance leaves ledger[farmId] nil -> buy fails closed).
    --   warnedHusbandries[uid]    - per-call dedup for the unresolvable/malformed warning.
    --   warnedAnimals[animal]     - per-call dedup for the nil/invalid-identity warning, keyed by
    --     the animal value since the same pool entry is re-scanned by each op.
    local remainingByHusbandry = {}
    local dealerRemaining = {}
    local claimedByOp = {}
    local ledger = {}
    local ledgerSeeded = {}
    local warnedHusbandries = {}
    local warnedAnimals = {}
    --   slotLedger[uid]           - running free-slot projection per husbandry, the slot analog of
    --     the money ledger. nil = unseeded, or seeded to a missing/non-finite value, and a buy then
    --     fails closed.
    --   slotLedgerSeeded[uid]     - idempotency marker so a credit or debit is never re-seeded over.
    --   slotSeed[uid]             - the original floored seed, which distinguishes the two buy no-op
    --     causes: seed <= 0 is a full barn, seed > 0 with remaining <= 0 is ledger-exhausted.
    --   warnedSlots[uid]          - per-call dedup for the missing/non-finite freeSlots warning.
    local slotLedger = {}
    local slotLedgerSeeded = {}
    local slotSeed = {}
    local warnedSlots = {}
    --   warnedDewars[dewar]       - per-call dedup for the malformed-sire / nil-uniqueId warning.
    --   dewarStrawLedger[dewar]   - planner-wide straw projection keyed by dewar IDENTITY, threaded
    --     across ALL AI rules in run order. Only the post-cap inseminated set decrements it.
    local warnedDewars = {}
    local dewarStrawLedger = {}

    --- Resolve a target husbandry record, or nil plus one warning per uid when it is absent or
    --- malformed.
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

    --- Resolve a target husbandry AND apply the operation x animalType gate: the single per-target
    --- entry point for every plan arm.
    ---
    --- RESOLVE FIRST, GATE SECOND, and that order is the contract: the malformed-husbandry warning
    --- must still fire for a target the gate would go on to reject, so gating first would silence a
    --- real data fault behind a routine type mismatch.
    ---
    --- Every per-target resolution goes through here rather than `resolveHusbandry` directly, so the
    --- gate is structural instead of per-arm. `ownedPool`'s own call is deliberately NOT routed
    --- here: it is operation-agnostic and shared across arms, so gating there would apply one
    --- operation's rule to another's pool.
    ---@param uid string
    ---@param operation string the rule's operation key
    ---@param ruleId any for the DEBUG line
    ---@return table|nil husbandry nil when unresolvable, malformed, or type-incompatible
    local function resolveGatedHusbandry(uid, operation, ruleId)
        local h = resolveHusbandry(uid)
        if h == nil then return nil end
        if not RLHerdsmanRuleService.isOperationAnimalTypeCompatible(operation, h.animalTypeIndex, animalTypeIndexByName) then
            -- The row carries the target's index but not what it was measured against: the per-call
            -- "animalType gate map" line above carries the resolved and missing declared names, so
            -- the pair reads together at DEBUG.
            Log:debug("%s rule=%s op=%s husbandry=%s: animalType-incompatible target no-op (typeIndex=%s); other targets proceed",
                LOG_PREFIX, tostring(ruleId), tostring(operation), tostring(uid), tostring(h.animalTypeIndex))
            return nil
        end
        return h
    end

    --- The remaining owned-animal pool for a husbandry, lazily shallow-copied from ctx and never the
    --- live array. nil when the husbandry is unresolvable or malformed.
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

    --- The remaining dealer pool for an animalType, lazily shallow-copied from ctx. A missing or
    --- non-table entry yields an empty pool, never a raise.
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

    --- Seed the running money ledger for a farm exactly once. A non-number or absent balance leaves
    --- ledger[farmId] nil, so a buy fails closed and a sell cannot thread its credit. Idempotent, so
    --- credits and debits are never overwritten.
    ---@param farmId any
    local function seedLedger(farmId)
        if not ledgerSeeded[farmId] then
            ledgerSeeded[farmId] = true
            local v = farmBalanceByFarmId[farmId]
            if type(v) == "number" then ledger[farmId] = v end
        end
    end

    --- Seed the per-husbandry free-slot ledger exactly once. Only a FINITE number seeds, floored to
    --- an integer slot count; anything else leaves the ledger nil and a buy fails closed. A
    --- fabricated negative IS seeded, so the buy gate takes the full-barn no-op path rather than
    --- warning. Idempotent, so a sell's credit and a buy's debit survive a re-seed.
    ---@param uid string
    local function seedSlotLedger(uid)
        if not slotLedgerSeeded[uid] then
            slotLedgerSeeded[uid] = true
            local h = husbandries[uid]
            local v = type(h) == "table" and h.freeSlots or nil
            -- Finite check: NaN ~= NaN, and both infinities compare equal to math.huge / -math.huge.
            if type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge then
                local floored = math.floor(v)
                slotLedger[uid] = floored
                slotSeed[uid] = floored
            end
        end
    end

    --- Real per-animal price: the REAL getSellPrice scaled by the caller's markup, plus the REAL
    --- transport fee, which is ADDED for both legs. The caller guarantees `animalSystem` is usable.
    ---@param animal table
    ---@param markup number
    ---@return number price
    local function priceOf(animal, markup)
        return animal:getSellPrice() * markup
            + animalSystem:getAnimalTransportFee(animal.subTypeIndex, animal.age)
    end

    --- Walk a candidate pool, returning the ordered animals that carry a resolvable identity, are
    --- not already claimed by this op, and match. Does NOT claim or mutate the pool - the caller
    --- prices, caps and claims the post-match set, so capped-out matches stay candidates for a later
    --- same-op rule.
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
                -- Skip + WARN on a malformed candidate WITHOUT indexing a non-table. Deduped per
                -- call, since the same pool entry is re-scanned by each op.
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

    --- Record each animal's key in a per-op claimed set. nil-keyed animals never reach here.
    ---@param claimed table
    ---@param animals table[]
    local function claimAll(claimed, animals)
        for _, a in ipairs(animals) do
            local k = animalKey(a)
            if k ~= nil then claimed[k] = true end
        end
    end

    --- Rebuild a pool array excluding the selected keys, order preserved. Shared by sell's
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
    --- invokes. A row can pass the identity gate yet be a non-Animal data table without them, and
    --- pricing it would be a call-on-nil-method raise, so the caller skips and warns instead.
    ---@param animal table identity-valid candidate
    ---@param needsCanBeSold boolean true for Sell (also needs getCanBeSold)
    ---@return boolean priceable
    local function isPriceableAnimal(animal, needsCanBeSold)
        if type(animal.getSellPrice) ~= "function" then return false end
        if needsCanBeSold and type(animal.getCanBeSold) ~= "function" then return false end
        return true
    end

    --- Skip + WARN, deduped, a matched candidate that lacks the real-Animal price methods.
    ---@param animal table
    local function warnNotPriceable(animal)
        if not warnedAnimals[animal] then
            Log:warning("%s skipping candidate without real-Animal price methods (uniqueId=%s) - not an Animal instance",
                LOG_PREFIX, tostring(type(animal) == "table" and animal.uniqueId or animal))
            warnedAnimals[animal] = true
        end
    end

    --- True when a dewar's sire carries the identity fields the REAL getCanBeInseminatedByAnimal
    --- reads. That predicate formats `AREA_CODES[otherAnimal.country].code` UNCONDITIONALLY, so a
    --- sire with a nil or unknown country would raise; the AI caller treats such a dewar as
    --- incompatible plus a warning instead.
    ---@param sire table|nil dewar.animal
    ---@return boolean usable
    local function isUsableSire(sire)
        if type(sire) ~= "table" then return false end
        if sire.typeIndex == nil or sire.farmId == nil or sire.uniqueId == nil then return false end
        local country = sire.country
        return country ~= nil and RLConstants.AREA_CODES[country] ~= nil
    end

    --- Seed the planner-wide straw ledger for a dewar exactly once, keyed by the dewar table ref so
    --- the remaining count threads across every AI rule. Idempotent, so a dewar legitimately seeded
    --- to 0 is never re-seeded and prior rules' decrements survive.
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
            -- The service floor forbids a naming filterId; a stray one from stale or migrated data
            -- is ignored, but surfaced so the mis-tag is visible.
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

        -- The SYSTEMIC gate-closed case: this operation declares an allow-list and not one of its
        -- names resolved, so it can run on NO pen this tick - a different event from an ordinary
        -- per-target type mismatch, and one the per-target DEBUG rows leave no evidence of at the
        -- stable INFO level. Rendered from the DECLARATION, never from a hardcoded type, so a future
        -- allow-list operation inherits the diagnosis. Fires once per affected rule regardless of
        -- target count, after the dedupe / empty-targets rows so their order is unchanged.
        local gateClosed, unresolvedNames = RLHerdsmanRuleService.isOperationTypeGateClosed(op, animalTypeIndexByName)
        if gateClosed then
            -- An EMPTY allow-list is also closed, and there "declared type(s) [] did not resolve"
            -- would be false twice over, since nothing was declared and so nothing failed.
            if #unresolvedNames > 0 then
                Log:warning("%s rule=%s op=%s: declared animal type(s) [%s] did not resolve - NO pen is targetable this tick (fail closed)",
                    LOG_PREFIX, tostring(rule.id), tostring(op), table.concat(unresolvedNames, ","))
            else
                Log:warning("%s rule=%s op=%s: the operation declares an EMPTY allow-list - NO pen is targetable this tick (fail closed)",
                    LOG_PREFIX, tostring(rule.id), tostring(op))
            end
        end

        if op == "sell" then
            -- A missing animalSystem is a wiring error: fail closed rather than crash the tick.
            if type(animalSystem) ~= "table" then
                Log:warning("%s rule=%s op=sell skipped: ctx.animalSystem missing (T4 wiring)", LOG_PREFIX, tostring(rule.id))
            else
                local maxN = normalizeMaxAnimals(rule, params)
                if maxN ~= nil then
                    local mark = params.mark == true
                    for _, uid in ipairs(targets) do
                        local h = resolveGatedHusbandry(uid, op, rule.id)
                        if h ~= nil then
                            local pool = ownedPool(uid)
                            local candidates = #pool
                            -- Shortlist = filter-matched AND sellable AND not sick; a nil getCanBeSold
                            -- counts as a skip. It feeds exec and mark alike, so a sick animal is never
                            -- marked either. S is the pre-cap shortlist size, the wage's `min(S, n*5)` operand.
                            local matched = matchFromPool(pool, filter, false, claimed)
                            local shortlist = {}
                            for _, a in ipairs(matched) do
                                if not isPriceableAnimal(a, true) then
                                    warnNotPriceable(a)
                                elseif a:getCanBeSold() then
                                    if RLDiseaseSaleGate.check(a) then
                                        shortlist[#shortlist + 1] = { animal = a, price = priceOf(a, SELL_MARKUP), key = animalKey(a) }
                                    else
                                        Log:debug("%s rule=%s op=sell husbandry=%s: excluded sick animal uniqueId=%s farmId=%s",
                                            LOG_PREFIX, tostring(rule.id), tostring(uid), tostring(a.uniqueId), tostring(a.farmId))
                                    end
                                end
                            end
                            local S = #shortlist
                            -- Price DESC; equal prices break by the identity key, which decides which
                            -- animals a tie straddling the cap takes.
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
                                -- Global claim, mark OR exec: the selected set leaves the owned pool,
                                -- so no later rule can touch it. Capped-out matches are NOT claimed.
                                remainingByHusbandry[uid] = poolMinus(pool, selectedKeys)
                                claimAll(claimed, selected)
                                local action = { ruleId = rule.id, operation = "sell", husbandryId = uid,
                                    animals = selected, mark = mark, wage = wage }
                                if not mark then
                                    -- Carry the proceeds and credit the farm ledger so a later
                                    -- same-farm buy can spend them; a marked sell is advisory only.
                                    action.amountGained = amountGained
                                    seedLedger(rule.farmId)
                                    if type(ledger[rule.farmId]) == "number" then
                                        ledger[rule.farmId] = ledger[rule.farmId] + amountGained
                                    end
                                    -- An executed sell frees engine slots synchronously, so credit
                                    -- this husbandry's slot ledger by the sold count. Only a SEEDED
                                    -- ledger is credited; a husbandry with nil freeSlots skips it.
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
            -- Move is an OUT op: the selected, capped set leaves its SOURCE plan pool and takes the
            -- same-op claim unconditionally, mark or exec, so no later-ordered rule can plan the
            -- moved animals - which is what keeps a "castrate the rest" rule off the moved breeding
            -- bull. The set is deliberately NOT appended to the destination's pool this tick,
            -- because a move can fail at execute and a same-day dest-add would resurrect a cross-pen
            -- snip; destination rules pick the animals up next day. Move prices nothing, so there is
            -- no animalSystem guard, and genetics has NO floor - a whole-nil genetics scores 0 and
            -- sorts last, yet stays selectable.
            local dest = params.destinationHusbandry
            if type(dest) ~= "string" or dest:gsub("%s", "") == "" then
                -- Clean no-op: select nothing, claim nothing, emit nothing. Claiming animals out of
                -- the pool for a move that does nothing would wrongly suppress "castrate the rest".
                -- Checked ONCE at the rule level, before the target loop, so the cause is unambiguous.
                Log:debug("%s rule=%s op=move no-op: missing/empty destinationHusbandry (%s)",
                    LOG_PREFIX, tostring(rule.id), tostring(dest))
            else
                local maxN = normalizeMaxAnimals(rule, params)
                if maxN ~= nil then
                    local mark = params.mark == true
                    for _, uid in ipairs(targets) do
                        local h = resolveGatedHusbandry(uid, op, rule.id)
                        if h ~= nil then
                            local pool = ownedPool(uid)
                            local candidates = #pool
                            -- No eligibility step between match and shortlist, unlike sell, so
                            -- S == #matched. S exists only for the cap and the DEBUG line here.
                            local matched = matchFromPool(pool, filter, false, claimed)
                            local shortlist = {}
                            for _, a in ipairs(matched) do
                                -- Per-field-coerced genetics sum: each field contributes its value
                                -- when numeric, else 0, so a malformed genetics never raises and
                                -- never skips.
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
                            -- Genetics DESC so the best survive the cap, then identity key, then a
                            -- stable build-order tiebreak - the same comparator shape the AI op uses.
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
                            -- W is resolved PER TARGET, so a mixed-type multi-target move wages each
                            -- pen by its own type; n is the PLANNED count, and the executor scales
                            -- actual over planned later.
                            local W = wageFor(h.animalTypeIndex)
                            local wage = W * 0.5 * n * (mark and 0.35 or 1)
                            Log:debug("%s rule=%s op=move husbandry=%s candidates=%d shortlist=%d selected=%d mark=%s dest=%s wage=%.2f",
                                LOG_PREFIX, tostring(rule.id), tostring(uid), candidates, S, n, tostring(mark), tostring(dest), wage)
                            if n > 0 then
                                -- The selected set leaves the SOURCE pool and takes the same-op claim.
                                -- Capped-out matches stay candidates. NEVER touch ownedPool(dest).
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
                -- Gate on maxAnimals FIRST, and validate the budget only for a rule that would
                -- actually run, so a maxAnimals-dead rule stays quiet.
                local budgetType, budgetFixed, budgetPct, badBudget
                if maxN ~= nil then
                    budgetType, budgetFixed, budgetPct, badBudget = validateBuyBudget(rule, params)
                end
                if maxN ~= nil and not badBudget then
                    for _, uid in ipairs(targets) do
                        local h = resolveGatedHusbandry(uid, op, rule.id)
                        if h ~= nil then
                            -- SPACE gate BEFORE the money gate, mirroring AIAnimalBuyEvent.validate.
                            -- The running slot count threads executed-sell credits and buy debits, so
                            -- a same-tick sell frees barn space before a later buy fills it.
                            seedSlotLedger(uid)
                            local slotsRemaining = slotLedger[uid]
                            if slotsRemaining == nil then
                                -- Missing / non-finite freeSlots at a buy target: fail closed. The
                                -- day-tick sources freeSlots unconditionally, so a nil here is a
                                -- fabricated or test ctx.
                                if not warnedSlots[uid] then
                                    Log:warning("%s rule=%s op=buy husbandry=%s skipped: missing/non-finite freeSlots - fail closed",
                                        LOG_PREFIX, tostring(rule.id), tostring(uid))
                                    warnedSlots[uid] = true
                                end
                            elseif slotsRemaining <= 0 then
                                -- Full barn versus ledger-exhausted: distinct causes.
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
                                    Log:warning("%s rule=%s op=buy husbandry=%s skipped: nil farm balance (ledger[%s])",
                                        LOG_PREFIX, tostring(rule.id), tostring(uid), tostring(rule.farmId))
                                elseif balance <= 0 then
                                    -- MUST gate BEFORE math.clamp: the real engine math.clamp RAISES
                                    -- on max < min, so a negative balance must never reach it.
                                    Log:debug("%s rule=%s op=buy husbandry=%s no-op: balance <= 0 (%.2f)",
                                        LOG_PREFIX, tostring(rule.id), tostring(uid), balance)
                                else
                                    local budget = (budgetType == "percentage")
                                        and math.floor(balance * budgetPct / 100) or budgetFixed
                                    budget = math.clamp(budget, 0, balance)   -- balance > 0 here -> clamp safe
                                    if budget <= 0 then
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
                                            -- Three break conditions: budget (strict `>`, so a
                                            -- candidate priced exactly at the remainder IS bought),
                                            -- the maxAnimals cap, and free slots (one animal, one
                                            -- slot).
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
                                        -- `matched` distinguishes the three Buy no-op causes:
                                        -- matched=0 filter-empty; matched>0 and affordable=0
                                        -- all-unaffordable; affordable>0 and selected<cap means the
                                        -- budget or the slots ran out mid-loop.
                                        Log:debug("%s rule=%s op=buy husbandry=%s markup=%.3f candidates=%d matched=%d affordable=%d selected=%d slotsAtEntry=%d budgetAtEntry=%.2f amountSpent=%.2f wage=%.2f",
                                            LOG_PREFIX, tostring(rule.id), tostring(uid), buyMarkup, candidates, #matched, S, n, slotsRemaining, budget, amountSpent, wage)
                                        -- Per-animal price breakdown for the SELECTED set only,
                                        -- bounded by maxAnimals so it can never flood. The aggregate
                                        -- line names no animal and does not show how the markup and
                                        -- the fee split the charge, which leaves a charged price
                                        -- impossible to audit against the dealer list. The fee is
                                        -- derived by subtraction, so the line is self-verifying.
                                        -- Level-guarded because Lua evaluates log arguments BEFORE
                                        -- the logger checks the level.
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
                                            -- Remove the bought animals from the dealer pool, claim
                                            -- same-op, append to the destination owned pool so
                                            -- cross-op rules see them, and debit both ledgers.
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
            -- Owned-herd, no cap, no sort, sequential. The chicken exclusion is a DECLARATION in
            -- RLHerdsmanRuleService, not an arm-local check - do not restore one here. Candidates
            -- come via the filter; per survivor the hard floor the user filter cannot express -
            -- female, already-castrated, infertile - plus a nil-genetics guard. `mark` only sets the
            -- action field that gates the executor's mutation, never the claim. Same-op claim,
            -- cross-op visible: one animal may be castrated AND named the same day.
            local mark = params.mark == true
            for _, uid in ipairs(targets) do
                local h = resolveGatedHusbandry(uid, op, rule.id)
                if h ~= nil then
                    local pool = ownedPool(uid)
                    local candidates = #pool
                    local matched = matchFromPool(pool, filter, false, claimed)
                    local selected = {}
                    for _, a in ipairs(matched) do
                        local g = a.genetics
                        if a.gender == "female" or a.isCastrated then
                            -- Hard floor, silent. Checked first so the genetics read is short-circuited for females.
                        elseif type(g) ~= "table" or g.fertility == nil then
                            -- Never index nil; fail closed. Deduped per call.
                            if not warnedAnimals[a] then
                                Log:warning("%s rule=%s op=castrate skipping animal with nil genetics/fertility (uniqueId=%s) - fail closed",
                                    LOG_PREFIX, tostring(rule.id), tostring(type(a) == "table" and a.uniqueId or a))
                                warnedAnimals[a] = true
                            end
                        elseif g.fertility == 0 then
                            -- Infertile -> hard-skip, silent.
                        else
                            selected[#selected + 1] = a
                        end
                    end
                    local n = #selected
                    local W = wageFor(h.animalTypeIndex)
                    -- Single-term wage: no min(S, n*5) shortlist component, which is sell/buy-only.
                    -- mark halves-then-discounts to the 0.35 advisory rate.
                    local wage = W * 0.5 * n * (mark and 0.35 or 1)
                    Log:debug("%s rule=%s op=castrate husbandry=%s candidates=%d selected=%d mark=%s wage=%.2f",
                        LOG_PREFIX, tostring(rule.id), tostring(uid), candidates, n, tostring(mark), wage)
                    if n > 0 then
                        -- The same-op claim covers EVERY survivor, mark-independent; they stay in the
                        -- pool for naming and ai.
                        claimAll(claimed, selected)
                        actions[#actions + 1] = { ruleId = rule.id, operation = "castrate", husbandryId = uid,
                            animals = selected, mark = mark, wage = wage }
                    end
                end
            end

        elseif op == "naming" then
            -- Owned-herd, no filter, narrowed to unnamed-only (exact ~= "", so a whitespace-only name
            -- counts as named). No cap, no mark. A missing name system is a wiring error -> fail
            -- closed, mirroring the sell/buy guard.
            if type(animalNameSystem) ~= "table" or type(animalNameSystem.getNamesAlphabetical) ~= "function" then
                Log:warning("%s rule=%s op=naming skipped: ctx.animalNameSystem missing/invalid (T4 wiring)", LOG_PREFIX, tostring(rule.id))
            else
                -- "random" -> random; anything else -> alphabetical, warning when it is not literally
                -- "alphabetical" (stale "" / "legacy" / nil).
                local convention = params.convention
                local isRandom = convention == "random"
                local conventionOut = isRandom and "random" or "alphabetical"
                if not isRandom and convention ~= "alphabetical" then
                    Log:warning("%s rule=%s op=naming: convention '%s' is not 'random'/'alphabetical' - treating as alphabetical (legacy else-branch)",
                        LOG_PREFIX, tostring(rule.id), tostring(convention))
                end
                -- One per-rule cursor, shared across the male/female lists. "" is the wire's nil
                -- sentinel and any non-string is corrupt persisted data, so both normalize to nil
                -- rather than letting walkCursor's `name > prev` raise.
                local cursor = params.previous
                if type(cursor) ~= "string" or cursor == "" then cursor = nil end
                -- The cursor threads across the WHOLE rule in deterministic uid order, NOT per
                -- target: which animal gets which name is a pure function of the rule's candidate set
                -- and toKey order, independent of how animals are grouped into targets. So gather
                -- every unnamed unclaimed candidate into one stream, sort ONCE by toKey, walk the
                -- shared cursor, then partition the named animals back into per-target actions.
                local stream = {}    -- { { animal = a, uid = <husbandry uid> }, ... } rule-wide
                local byTarget = {}  -- [uid] = { h, candidates, named = {}, assignments = {} }
                for _, uid in ipairs(targets) do
                    local h = resolveGatedHusbandry(uid, op, rule.id)
                    if h ~= nil then
                        local pool = ownedPool(uid)
                        byTarget[uid] = { h = h, candidates = #pool, named = {}, assignments = {} }
                        -- noFilter: every remaining unclaimed animal, then unnamed-only.
                        local matched = matchFromPool(pool, filter, traits.noFilter == true, claimed)
                        for _, a in ipairs(matched) do
                            if a.name == nil or a.name == "" then
                                stream[#stream + 1] = { animal = a, uid = uid }
                            end
                        end
                    end
                end
                -- Deterministic rule-wide order; nil-key animals were already dropped by
                -- matchFromPool, so every stream entry has a key.
                table.sort(stream, function(x, y) return animalKey(x.animal) < animalKey(y.animal) end)
                for _, item in ipairs(stream) do
                    local a = item.animal
                    local names = animalNameSystem:getNamesAlphabetical(a.gender)
                    if type(names) == "table" and #names > 0 then
                        local bucket = byTarget[item.uid]
                        if isRandom then
                            -- The executor generates the string; the planner only selects and counts.
                            bucket.named[#bucket.named + 1] = a
                        else
                            local assignedName
                            assignedName, cursor = walkCursor(names, cursor)
                            bucket.named[#bucket.named + 1] = a
                            bucket.assignments[#bucket.assignments + 1] = { animal = a, name = assignedName }
                        end
                    else
                        -- Empty gender list -> skip: no name, not counted, cursor unchanged.
                        Log:debug("%s rule=%s op=naming husbandry=%s: empty name list for gender=%s (uniqueId=%s) - skipped, uncounted",
                            LOG_PREFIX, tostring(rule.id), tostring(item.uid), tostring(a.gender), tostring(a.uniqueId))
                    end
                end
                -- One action per target that named at least one animal, in lexicographic target
                -- order. `previousOut` is the RULE-FINAL cursor - the same value on every action of
                -- the rule, so the executor writes it back once regardless of which action it reads.
                for _, uid in ipairs(targets) do
                    local bucket = byTarget[uid]
                    if bucket ~= nil then
                        local named = bucket.named
                        local n = #named
                        local W = wageFor(bucket.h.animalTypeIndex)
                        local wage = W * 0.15 * n   -- single term, no shortlist component
                        Log:debug("%s rule=%s op=naming husbandry=%s candidates=%d named=%d convention=%s wage=%.2f",
                            LOG_PREFIX, tostring(rule.id), tostring(uid), bucket.candidates, n, conventionOut, wage)
                        if n > 0 then
                            -- Same-op claim; cross-op visible, so a named animal stays in the pool.
                            claimAll(claimed, named)
                            local action = { ruleId = rule.id, operation = "naming", husbandryId = uid,
                                animals = named, convention = conventionOut, wage = wage }
                            if not isRandom then
                                action.assignments = bucket.assignments
                                action.previousOut = cursor
                            end
                            actions[#actions + 1] = action
                        end
                    end
                end
            end

        elseif op == "ai" then
            -- Owned-herd, non-end-task, the LAST op. Deliberate genetics-first deviation: this
            -- planner collects compatible dewars straw-IGNORANT, sorts candidates genetics-desc
            -- FIRST, then greedily assigns scarce straws best-first against the planner-wide ledger.
            -- Because greedy straw assignment is an order-dependent bipartite matching, in the rare
            -- multi-dewar cross-compatible scarce-straw case it can inseminate FEWER total animals -
            -- accepted, to prioritise the best genetics. The real getCanBeInseminatedByAnimal is the
            -- SOLE eligibility gate, with no fertility==0 check.
            local maxN = normalizeMaxAnimals(rule, params)
            if maxN ~= nil then
                local mark = params.mark == true
                local semen = params.semen
                for _, uid in ipairs(targets) do
                    local h = resolveGatedHusbandry(uid, op, rule.id)
                    if h ~= nil then
                        local typeIdx = h.animalTypeIndex
                        -- Farm scope is rule.farmId, the key the money ledger uses, and the farmId
                        -- VALUE type must match the table KEY type or the bucket silently reads
                        -- empty. DewarManager stores insert-order, so the planner sorts by uniqueId.
                        local farmBucket = dewarsByFarmId[rule.farmId]
                        local rawBucket = type(farmBucket) == "table" and farmBucket[typeIdx] or nil
                        local sortedBucket = {}
                        if type(rawBucket) == "table" then
                            for _, d in ipairs(rawBucket) do
                                if type(d) == "table" and d.animal ~= nil then
                                    if d.uniqueId == nil then
                                        -- The action's `dewars` value would be nil; skip + WARN.
                                        if not warnedDewars[d] then
                                            Log:warning("%s rule=%s op=ai husbandry=%s: dewar with nil uniqueId skipped",
                                                LOG_PREFIX, tostring(rule.id), tostring(uid))
                                            warnedDewars[d] = true
                                        end
                                    else
                                        sortedBucket[#sortedBucket + 1] = d
                                    end
                                end
                                -- A nil sire never inseminates -> silently dropped.
                            end
                            table.sort(sortedBucket, function(x, y) return tostring(x.uniqueId) < tostring(y.uniqueId) end)
                        end
                        -- "any" -> the whole sorted bucket; a specific uniqueId -> the FIRST matching
                        -- dewar in uniqueId order; not found or empty bucket -> no action.
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
                            -- A specific semen matching no dewar is a likely config error; a nil or
                            -- empty farm/type bucket is routine.
                            if semenNotFound then
                                Log:warning("%s rule=%s op=ai husbandry=%s: semen '%s' matched no dewar (likely config error) - no action",
                                    LOG_PREFIX, tostring(rule.id), tostring(uid), tostring(semen))
                            else
                                Log:debug("%s rule=%s op=ai husbandry=%s no-op: no dewars for farm/type (farmId=%s typeIndex=%s)",
                                    LOG_PREFIX, tostring(rule.id), tostring(uid), tostring(rule.farmId), tostring(typeIdx))
                            end
                        else
                            -- Seed the planner-wide straw ledger for every resolved dewar, so
                            -- remaining straws thread across ALL AI rules with no cross-rule
                            -- overcommit.
                            for _, d in ipairs(dewars) do seedDewarStraws(d) end
                            local pool = ownedPool(uid)
                            -- Candidate eligibility: filter-matched, not same-op-claimed, and at
                            -- least one compatible dewar. Straw-IGNORANT here - the predicate is
                            -- pure, so collecting ALL compatible dewars is observationally safe and
                            -- is the mechanism behind the genetics-first deviation.
                            local matched = matchFromPool(pool, filter, false, claimed)
                            local candidates = {}
                            for _, a in ipairs(matched) do
                                local g = a.genetics
                                local gm, gq, gf, gh, gp
                                if type(g) == "table" then gm, gq, gf, gh, gp = g.metabolism, g.quality, g.fertility, g.health, g.productivity end
                                local geneticsOk = type(gm) == "number" and type(gq) == "number"
                                    and type(gf) == "number" and type(gh) == "number" and (gp == nil or type(gp) == "number")
                                if not geneticsOk then
                                    -- Never index nil in the sum; fail closed. Deduped per call.
                                    if not warnedAnimals[a] then
                                        Log:warning("%s rule=%s op=ai skipping animal with nil/non-number genetics (uniqueId=%s) - fail closed",
                                            LOG_PREFIX, tostring(rule.id), tostring(type(a) == "table" and a.uniqueId or a))
                                        warnedAnimals[a] = true
                                    end
                                elseif type(a.getCanBeInseminatedByAnimal) ~= "function" then
                                    -- The AI analog of Sell/Buy's isPriceableAnimal guard: a matched
                                    -- row can carry valid identity and genetics yet be a non-Animal
                                    -- data table without the real predicate method.
                                    if not warnedAnimals[a] then
                                        Log:warning("%s rule=%s op=ai skipping candidate without getCanBeInseminatedByAnimal (uniqueId=%s) - not an Animal instance",
                                            LOG_PREFIX, tostring(rule.id), tostring(type(a) == "table" and a.uniqueId or a))
                                        warnedAnimals[a] = true
                                    end
                                else
                                    -- Compatible dewars in uniqueId order. A malformed sire is treated
                                    -- incompatible plus a warning, via isUsableSire before the
                                    -- predicate, so it can never raise.
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
                            -- Genetics DESC, then identity key, then a stable ord tiebreak so a key
                            -- collision is still deterministic - it decides who straddles the cap.
                            table.sort(candidates, function(x, y)
                                if x.genetics ~= y.genetics then return x.genetics > y.genetics end
                                if x.key ~= y.key then return x.key < y.key end
                                return x.ord < y.ord
                            end)
                            -- Greedy best-first straw assignment against a per-rule SCRATCH view of
                            -- the planner-wide ledger, whose remaining already reflects prior AI
                            -- rules' commits. The assignable set defines S over ALL candidates.
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
                            -- Cap-then-claim: commit ONLY the inseminated set's straws, so capped-out
                            -- candidates consume nothing and stay available for a later AI rule.
                            local inseminatedAnimals, inseminatedDewars = {}, {}
                            for i = 1, n do
                                local item = assignable[i]
                                inseminatedAnimals[i] = item.animal
                                inseminatedDewars[i] = item.dewar.uniqueId
                                dewarStrawLedger[item.dewar] = (dewarStrawLedger[item.dewar] or 0) - 1
                            end
                            local W = wageFor(typeIdx)
                            -- Per-animal 1.2 exec / 0.45 mark, plus the shortlist term
                            -- min(S, n*5)*0.2 at 1.0 exec / 0.35 mark.
                            local wage = W * n * (mark and 0.45 or 1.2)
                                + W * math.min(S, n * 5) * 0.2 * (mark and 0.35 or 1)
                            Log:debug("%s rule=%s op=ai husbandry=%s eligible=%d assignable=%d inseminated=%d wage=%.2f mark=%s semen=%s",
                                LOG_PREFIX, tostring(rule.id), tostring(uid), eligibleCount, S, n, wage, tostring(mark), tostring(semen))
                            if n > 0 then
                                -- The same-op claim covers ONLY the inseminated set; AI is the last
                                -- op, so cross-op visibility is moot. mark never gates the claim.
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
            -- Owned-herd, HORSE-only, no cap, no sort, no mark, sequential. Structurally the castrate
            -- arm minus the per-survivor hard floor and all mark handling: the filter is the ONLY
            -- narrowing beyond the type gate, which fails CLOSED here, and a gated-out target of a
            -- multi-target rule is a per-target no-op.
            --
            -- NO IDEMPOTENCY GATE, and that is load-bearing rather than an oversight. Skipping a horse
            -- already at riding 100 / dirt 0 would re-import the exact barn-ordering variance the
            -- executor's deferral exists to remove: planning runs INLINE while the care write is
            -- DEFERRED, so at plan time a horse reads 100 on a barn whose own day tick has not run yet
            -- and 0 on one whose has, and selection would depend on how the barn was acquired.
            for _, uid in ipairs(targets) do
                local h = resolveGatedHusbandry(uid, op, rule.id)
                if h ~= nil then
                    local pool = ownedPool(uid)
                    local candidates = #pool
                    local selected = matchFromPool(pool, filter, false, claimed)
                    local n = #selected
                    local W = wageFor(h.animalTypeIndex)
                    -- Single-term wage at the naming coefficient - 3.75 per horse per day for a HORSE
                    -- pen - with no shortlist component. It is bounded by the long-season breeder
                    -- rather than by the default settings: full care buys a one-off of about +3,500
                    -- on a mature horse, while this wage recurs every real day the animal is held, and
                    -- the castrate coefficient of 0.50 goes underwater over a 36-month hold.
                    local wage = W * 0.15 * n
                    Log:debug("%s rule=%s op=horseCare husbandry=%s candidates=%d selected=%d wage=%.2f",
                        LOG_PREFIX, tostring(rule.id), tostring(uid), candidates, n, wage)
                    if n > 0 then
                        -- Same-op claim; the horses STAY in the owned pool so cross-op rules still see
                        -- them - a horse may be cared for and named the same day.
                        claimAll(claimed, selected)
                        actions[#actions + 1] = { ruleId = rule.id, operation = "horseCare", husbandryId = uid,
                            animals = selected, wage = wage }
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
