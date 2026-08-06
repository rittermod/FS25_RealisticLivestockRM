-- RLHerdsmanRulePresenter.lua
-- Pure view-model for the Herdsman rule menu frame (M-Frame F1).
--
-- The single home for every list / detail / visibility / validation decision the
-- Herdsman frame needs, so the frame `.lua` stays bind-only (read element -> call a
-- presenter function -> write the element). This is the deliberate counter-move to
-- the Filters subtab (RLMenuSettingsFrame), which inlines that logic in the frame and
-- is the anti-example for wiring thickness.
--
-- PURITY CONTRACT (hard):
--   * Every function takes plain data (plus injected resolver / label deps) and
--     returns plain data: tables / strings / booleans.
--   * ZERO g_* globals, ZERO element refs, ZERO setText/setVisible/SmoothList,
--     ZERO XML, ZERO RLFilterService / placeableSystem.
--   * Game-state reads arrive through INJECTED resolvers (resolveName, resolveFilter);
--     the frame layer owns wiring those to g_currentMission.placeableSystem and
--     RLFilterService.
--   * Sibling pure-module constants ARE referenced directly: RLFilterUsage.* for the
--     allowed-usage map, and RLHerdsmanRuleService.OPERATIONS for the operation
--     validity set (the canonical set lives there; the presenter does not duplicate
--     it). These are pure constant tables, not game state.
--
-- Mirrors RLFilterFieldCatalog's SHAPE (top-level table, module-local Log, module
-- constants, LuaDoc + logging on every function). 100% dual-run: in-game
-- RLHerdsmanRulePresenterTests + headless herdsman_rule_presenter_suite.lua.

local Log = RmLogging.getLogger("RLRM")

RLHerdsmanRulePresenter = {}

-- =============================================================================
-- Constants
-- =============================================================================

--- Canonical run / visual order for rule sections (D3 "visual order = run order").
--- OWNED by RLHerdsmanRuleService.OPERATION_ORDER (M-Tick T1): the presenter's
--- section sort and the planner's run-order sort share one source of truth. Re-exported
--- here so the presenter's own callers + tests keep referencing it under this name. The
--- operation VALIDITY set comes from RLHerdsmanRuleService.OPERATIONS (no duplication).
RLHerdsmanRulePresenter.OPERATION_ORDER = RLHerdsmanRuleService.OPERATION_ORDER

--- operation -> rank, derived from the service's OPERATION_ORDER for O(1) section
--- placement and "is this one of the five orderable operations" membership.
local OPERATION_RANK = {}
for rank, op in ipairs(RLHerdsmanRuleService.OPERATION_ORDER) do
    OPERATION_RANK[op] = rank
end

--- Stable key order for the param-visibility map. Every getParamVisibility result
--- carries exactly these keys (defaulting false) so callers can key-test safely.
local PARAM_KEYS = { "filter", "maxAnimals", "budget", "mark", "convention", "previous", "semen", "destination" }

--- operation -> set of VISIBLE detail-pane params (true). Grounded in the
--- legacy-parity matrix (AIAnimalManager.new settings defaults): Sell maxAnimals+mark;
--- Move maxAnimals+mark+destination; Buy budget+maxAnimals; Castrate mark (no cap);
--- Naming convention+previous (no filter, no cap); AI maxAnimals+mark+semen; Horse care
--- filter only. `filter` shows for every operation except naming. Params absent from a set
--- default to false (hidden).
local PARAM_VISIBILITY = {
    sell      = { filter = true, maxAnimals = true, mark = true },
    move      = { filter = true, maxAnimals = true, mark = true, destination = true },
    buy       = { filter = true, maxAnimals = true, budget = true },
    castrate  = { filter = true, mark = true },
    naming    = { convention = true, previous = true },
    ai        = { filter = true, maxAnimals = true, mark = true, semen = true },
    horseCare = { filter = true },
}

--- operation -> allowed filter-usage membership map (D7). Buy draws from the dealer
--- pool ({ANY, DEALER}); every owned-herd operation draws from owned ({ANY, OWNED}).
--- Built against the RLFilterUsage constants (never inline strings). Naming's set is
--- inert (its filter row is hidden + validateEdit requires nil filterId) but kept
--- ticket-faithful at {ANY, OWNED}.
local ALLOWED_USAGES = {
    sell      = { [RLFilterUsage.ANY] = true, [RLFilterUsage.OWNED]  = true },
    move      = { [RLFilterUsage.ANY] = true, [RLFilterUsage.OWNED]  = true },
    buy       = { [RLFilterUsage.ANY] = true, [RLFilterUsage.DEALER] = true },
    castrate  = { [RLFilterUsage.ANY] = true, [RLFilterUsage.OWNED]  = true },
    naming    = { [RLFilterUsage.ANY] = true, [RLFilterUsage.OWNED]  = true },
    ai        = { [RLFilterUsage.ANY] = true, [RLFilterUsage.OWNED]  = true },
    horseCare = { [RLFilterUsage.ANY] = true, [RLFilterUsage.OWNED]  = true },
}

--- Operation x animalType restrictions, declared by animal type NAME. An operation ABSENT
--- from this table is unrestricted (every type is targetable).
---   * `exclude` - valid for every type EXCEPT the named ones. Castrate cannot target
---     CHICKEN (legacy skips chicken castration in its castrate branch).
---   * `allow`   - valid ONLY for the named ones. Horse care is horses-only.
--- NAMES, never indices: an animalType index is assigned at registration order, so a
--- third-party map or an active bridge shifts the numbering and a hardcoded index becomes a
--- wrong-species defect that only surfaces on someone else's map. The live index per name is
--- resolved by the CALLER and injected into the predicate, which is what keeps this module
--- free of `g_*` reads.
--- An entry carrying BOTH keys is a declaration error, not a runtime case: `allow` wins.
local OPERATION_ANIMAL_TYPES = {
    castrate  = { exclude = { "CHICKEN" } },
    horseCare = { allow   = { "HORSE" } },
}

--- Exposed read-only so the frame can resolve exactly the names these declarations reference,
--- and so a test can assert the declaration and its resolved name union have not drifted apart.
RLHerdsmanRulePresenter.OPERATION_ANIMAL_TYPES = OPERATION_ANIMAL_TYPES

-- -----------------------------------------------------------------------------
-- Param value domains
-- -----------------------------------------------------------------------------
-- The detail-pane MultiTextOption widgets consume the *_VALUES (via the fresh-array
-- accessors below); validateParams checks membership via the derived *_SET tables.
-- Grounded in the legacy herdsman option value-lists (the binary convention /
-- budget-type options + the 28-value budget-percentage list) and the rule serializer
-- field types (maxAnimals Int, budget.fixed Int, budget.percentage Float).

--- Naming convention domain (binary: random | alphabetical).
local CONVENTION_VALUES = { "random", "alphabetical" }

--- Buy budget-type domain (binary: fixed | percentage).
local BUDGET_TYPE_VALUES = { "fixed", "percentage" }

--- Buy budget-percentage domain: the 28-value legacy whitelist. A percentage is
--- valid ONLY as a member of this list, never as a free numeric value.
local BUDGET_PERCENTAGE_VALUES = {
    0.5, 1, 1.5, 2, 2.5, 3, 4, 5, 6, 7, 8, 9, 10, 12.5, 15, 17.5, 20, 25, 30, 35,
    40, 45, 50, 60, 70, 80, 90, 100,
}

--- Derived O(1) membership sets. Single source of truth is the *_VALUES array;
--- the set is rebuilt from it so the two can never drift.
local CONVENTION_SET = {}
for _, value in ipairs(CONVENTION_VALUES) do CONVENTION_SET[value] = true end
local BUDGET_TYPE_SET = {}
for _, value in ipairs(BUDGET_TYPE_VALUES) do BUDGET_TYPE_SET[value] = true end
local BUDGET_PERCENTAGE_SET = {}
for _, value in ipairs(BUDGET_PERCENTAGE_VALUES) do BUDGET_PERCENTAGE_SET[value] = true end

--- maxAnimals integer bounds (inclusive); the serializer writes it as an Int.
RLHerdsmanRulePresenter.MAXANIMALS_MIN = 1
RLHerdsmanRulePresenter.MAXANIMALS_MAX = 9999

--- The "any dewar" semen sentinel. The frame prepends this as its own option with an
--- i18n label; formatSemenOption (real dewars only) never emits it.
RLHerdsmanRulePresenter.SEMEN_ANY = "any"

-- =============================================================================
-- Internal helpers
-- =============================================================================

--- Process-lifetime flag: warn exactly once if RLHerdsmanRuleService (the canonical
--- operation-validity set) is unreachable, so a load-order regression is visible in
--- logs without spamming every validateEdit call.
local _warnedOperationsMissing = false

--- True when `operation` is one of the canonical rule operations. Prefers the
--- service's authoritative OPERATIONS set (single source of truth, not duplicated
--- here); falls back to OPERATION_RANK membership (the same five ops, presenter-owned
--- ordering data) with a one-shot warning if the service global is somehow unloaded.
---@param operation any
---@return boolean
local function isKnownOperation(operation)
    if type(operation) ~= "string" then return false end
    if RLHerdsmanRuleService ~= nil and RLHerdsmanRuleService.OPERATIONS ~= nil then
        return RLHerdsmanRuleService.OPERATIONS[operation] == true
    end
    if not _warnedOperationsMissing then
        Log:warning("RLHerdsmanRulePresenter.isKnownOperation: RLHerdsmanRuleService.OPERATIONS unavailable; falling back to OPERATION_ORDER membership (check main.lua SECTION 11h load order)")
        _warnedOperationsMissing = true
    end
    return OPERATION_RANK[operation] ~= nil
end

--- Comparator for rules within a section: delegates to the hoisted
--- RLHerdsmanRuleService.compareRulesByName (M-Tick T1) so the presenter's section /
--- filter sort and the planner's within-op run-order sort use one comparator and cannot
--- drift. Same contract: alphabetical by name (case-insensitive), nil-safe `tostring(id)`
--- tie-break. Reused for filter lists too (sortFiltersByName).
---@param a table record with `name` + `id`
---@param b table record with `name` + `id`
---@return boolean
local function compareRulesByName(a, b)
    return RLHerdsmanRuleService.compareRulesByName(a, b)
end

-- =============================================================================
-- List model
-- =============================================================================

--- Group a farm's rule list into ordered, per-operation sections for the
--- multi-section SmoothList. Sections appear in OPERATION_ORDER (Sell -> Buy ->
--- Castrate -> Naming -> AI); only operations with >= 1 rule produce a section;
--- within a section rules are alphabetical by name (case-insensitive) with a nil-safe
--- id tie-break. A rule whose operation is not one of the five is skipped + warned.
---@param rules table[]|nil array of rule records (farm-scoped by the caller)
---@return table[] sections array of `{ operation = string, rules = table[] }` in run order
function RLHerdsmanRulePresenter.buildSections(rules)
    local buckets = {}
    local count = 0
    if type(rules) == "table" then
        for _, rule in ipairs(rules) do
            local op = type(rule) == "table" and rule.operation or nil
            if op ~= nil and OPERATION_RANK[op] ~= nil then
                if buckets[op] == nil then buckets[op] = {} end
                table.insert(buckets[op], rule)
                count = count + 1
            else
                Log:warning("RLHerdsmanRulePresenter.buildSections: skipping rule with unknown operation '%s' (id=%s)",
                    tostring(op), tostring(type(rule) == "table" and rule.id or nil))
            end
        end
    end

    local sections = {}
    for _, op in ipairs(RLHerdsmanRulePresenter.OPERATION_ORDER) do
        local bucket = buckets[op]
        if bucket ~= nil and #bucket > 0 then
            table.sort(bucket, compareRulesByName)
            sections[#sections + 1] = { operation = op, rules = bucket }
        end
    end

    Log:trace("RLHerdsmanRulePresenter.buildSections: %d rule(s) -> %d section(s)", count, #sections)
    return sections
end

-- =============================================================================
-- Detail-pane param visibility
-- =============================================================================

--- Boolean visibility map for the detail-pane operation params. Every result carries
--- the full PARAM_KEYS set so callers can key-test without nil-checking. Unknown
--- operation -> all-false + warning.
---@param operation any rule operation key
---@return table map keyed by filter|maxAnimals|budget|mark|convention|previous|semen|destination (all boolean)
function RLHerdsmanRulePresenter.getParamVisibility(operation)
    local visible = PARAM_VISIBILITY[operation]
    if visible == nil then
        Log:warning("RLHerdsmanRulePresenter.getParamVisibility: unknown operation '%s'; all params hidden", tostring(operation))
    end

    local out = {}
    for _, key in ipairs(PARAM_KEYS) do
        out[key] = visible ~= nil and visible[key] == true
    end

    Log:trace("RLHerdsmanRulePresenter.getParamVisibility: operation=%s filter=%s maxAnimals=%s budget=%s mark=%s convention=%s previous=%s semen=%s destination=%s",
        tostring(operation), tostring(out.filter), tostring(out.maxAnimals), tostring(out.budget),
        tostring(out.mark), tostring(out.convention), tostring(out.previous), tostring(out.semen), tostring(out.destination))
    return out
end

-- =============================================================================
-- Detail-pane tooltip descriptors
-- =============================================================================

--- A binary editor row's selector is either state 1 or state 2; any other value means the
--- caller has no resolvable per-state tooltip key to build.
---@param state any
---@return boolean
local function isBinaryState(state)
    return state == 1 or state == 2
end

--- Build a `{ key, arg }` tooltip descriptor for ONE detail-pane editor row, or nil when the
--- row/operation combination has no help text (unknown operation, a field whose row is hidden
--- for that operation, an out-of-domain selector state, or an unknown field). PURE: returns
--- plain data only - the frame resolves `key` through g_i18n and formats the live value per
--- `arg`, so this function never touches g_i18n / elements.
---
--- `arg` tells the frame how to format the live value into the string's single `%s`:
---   nil       -> the string has no placeholder; the frame setText(getText(key)) verbatim
---   "number"  -> g_i18n:formatNumber (a per-day animal count)
---   "money"   -> g_i18n:formatMoney  (a per-day fixed budget)
---   "percent" -> tostring(pct).."%"  (a farm-money percentage)
---   "option"  -> the semen selector's current option text (a dewar label)
---
--- Key families (the deliberate two-family split, no third namespace): the op-param rows REUSE
--- the already-translated legacy `rl_ui_herdsmanTooltip_*` strings (enabled for the legacy ops,
--- convention, budget|type, semen); the new-menu-only controls + the per-pen maxAnimals/budget +
--- the Action states + move's all-new rows get `rl_menu_herdsman_*` keys. `move` is new-menu-only
--- (legacy AnimalScreen has no move op), so its enabled/maxAnimals/destination rows have no legacy
--- key and use the new menu family. The maxAnimals gate reuses PARAM_VISIBILITY (single source of
--- truth) so a tooltip is offered for exactly the operations whose maxAnimals row is shown.
---@param operation any rule operation key
---@param field any row field token: operation|name|enabled|maxAnimals|mark|convention|"budget|type"|"budget|fixed"|"budget|percentage"|semen|filter|husbandries|destination
---@param state any the widget's 1-based selector state, for the state-keyed rows (enabled/mark/convention/budget|type)
---@param value any the live param value, for the value-keyed rows (semen: SEMEN_ANY vs a dewar uniqueId)
---@return table|nil descriptor `{ key = string, arg = nil|"number"|"money"|"percent"|"option" }`, or nil
function RLHerdsmanRulePresenter.getTooltipDescriptor(operation, field, state, value)
    if not isKnownOperation(operation) then
        Log:trace("RLHerdsmanRulePresenter.getTooltipDescriptor: unknown operation '%s' -> nil", tostring(operation))
        return nil
    end

    local key, arg

    if field == "operation" then
        key = "rl_menu_herdsman_operation_tooltip"
    elseif field == "name" then
        key = "rl_menu_herdsman_name_tooltip"
    elseif field == "enabled" then
        -- Move and horse care are new-menu-only (legacy AnimalScreen has neither op, so neither
        -- has an rl_ui_herdsmanTooltip_* family), so their enabled rows use the new menu keys;
        -- every other op reuses its legacy per-state string. A new-menu-only operation MUST get
        -- a branch here: the tooltip sweep asserts a non-nil descriptor AND a resolvable key per
        -- row, so falling through would build a legacy-shaped key that exists in no locale.
        if operation == "move" then
            key = "rl_menu_herdsman_enabled_move_tooltip"
        elseif operation == "horseCare" then
            key = "rl_menu_herdsman_enabled_horseCare_tooltip"
        elseif isBinaryState(state) then
            key = string.format("rl_ui_herdsmanTooltip_%s_enabled_%d", tostring(operation), state)
        else
            Log:trace("RLHerdsmanRulePresenter.getTooltipDescriptor: enabled state '%s' out of {1,2} (operation=%s) -> nil",
                tostring(state), tostring(operation))
            return nil
        end
    elseif field == "maxAnimals" then
        -- Offered for exactly the operations whose maxAnimals row is visible (sell/buy/ai/move).
        local vis = PARAM_VISIBILITY[operation]
        if vis == nil or vis.maxAnimals ~= true then
            Log:trace("RLHerdsmanRulePresenter.getTooltipDescriptor: maxAnimals not shown for operation '%s' -> nil", tostring(operation))
            return nil
        end
        key = string.format("rl_menu_herdsman_maxAnimals_%s_tooltip", tostring(operation))
        arg = "number"
    elseif field == "mark" then
        -- The Mark toggle is the Action selector (decision 2b): state 1 = Perform (mark=false),
        -- state 2 = Mark only (mark=true). Each state has its own explicit help string.
        if state == 1 then
            key = "rl_menu_herdsman_action_perform_tooltip"
        elseif state == 2 then
            key = "rl_menu_herdsman_action_markOnly_tooltip"
        else
            Log:trace("RLHerdsmanRulePresenter.getTooltipDescriptor: mark state '%s' out of {1,2} -> nil", tostring(state))
            return nil
        end
    elseif field == "convention" then
        if not isBinaryState(state) then
            Log:trace("RLHerdsmanRulePresenter.getTooltipDescriptor: convention state '%s' out of {1,2} -> nil", tostring(state))
            return nil
        end
        key = string.format("rl_ui_herdsmanTooltip_naming_convention_%d", state)
    elseif field == "budget|type" then
        if not isBinaryState(state) then
            Log:trace("RLHerdsmanRulePresenter.getTooltipDescriptor: budget|type state '%s' out of {1,2} -> nil", tostring(state))
            return nil
        end
        key = string.format("rl_ui_herdsmanTooltip_buy_budget|type_%d", state)
    elseif field == "budget|fixed" then
        key = "rl_menu_herdsman_budgetFixed_tooltip"
        arg = "money"
    elseif field == "budget|percentage" then
        key = "rl_menu_herdsman_budgetPercentage_tooltip"
        arg = "percent"
    elseif field == "semen" then
        -- Keyed on the VALUE (the "any" sentinel vs a real dewar), not a selector state. The
        -- any-string has no placeholder; a dewar reuses the legacy "%s" string (arg=option).
        if value == RLHerdsmanRulePresenter.SEMEN_ANY then
            key = "rl_ui_herdsmanTooltip_ai_semen_any"
        else
            key = "rl_ui_herdsmanTooltip_ai_semen"
            arg = "option"
        end
    elseif field == "filter" then
        key = "rl_menu_herdsman_filter_tooltip"
    elseif field == "husbandries" then
        key = "rl_menu_herdsman_husbandries_tooltip"
    elseif field == "destination" then
        key = "rl_menu_herdsman_destination_tooltip"
    else
        Log:trace("RLHerdsmanRulePresenter.getTooltipDescriptor: unknown field '%s' (operation=%s) -> nil",
            tostring(field), tostring(operation))
        return nil
    end

    Log:trace("RLHerdsmanRulePresenter.getTooltipDescriptor: operation=%s field=%s state=%s value=%s -> key=%s arg=%s",
        tostring(operation), tostring(field), tostring(state), tostring(value), tostring(key), tostring(arg))
    return { key = key, arg = arg }
end

-- =============================================================================
-- Detail-pane param value domains, defaults + validation
-- =============================================================================

--- Fresh ordered copy of the naming-convention domain (random | alphabetical). A new
--- array per call so the frame's MultiTextOption state list can never mutate the
--- module constant.
---@return string[]
function RLHerdsmanRulePresenter.getConventionValues()
    local out = {}
    for i, value in ipairs(CONVENTION_VALUES) do out[i] = value end
    return out
end

--- Fresh ordered copy of the buy budget-type domain (fixed | percentage).
---@return string[]
function RLHerdsmanRulePresenter.getBudgetTypeValues()
    local out = {}
    for i, value in ipairs(BUDGET_TYPE_VALUES) do out[i] = value end
    return out
end

--- Fresh ordered copy of the buy budget-percentage whitelist (28 values).
---@return number[]
function RLHerdsmanRulePresenter.getBudgetPercentageValues()
    local out = {}
    for i, value in ipairs(BUDGET_PERCENTAGE_VALUES) do out[i] = value end
    return out
end

--- Which budget sub-field the buy detail pane shows for a given budget type: a fixed
--- amount XOR a herd-value percentage. Exactly one true for a known type; both false
--- for an unknown / nil type (fail-closed, so the frame hides both rather than
--- guessing).
---@param budgetType any "fixed" | "percentage" | other
---@return table { fixed = boolean, percentage = boolean }
function RLHerdsmanRulePresenter.getBudgetFieldVisibility(budgetType)
    local out = { fixed = budgetType == "fixed", percentage = budgetType == "percentage" }
    Log:trace("RLHerdsmanRulePresenter.getBudgetFieldVisibility: budgetType=%s -> fixed=%s percentage=%s",
        tostring(budgetType), tostring(out.fixed), tostring(out.percentage))
    return out
end

--- Fresh per-operation default params, used by the frame to (re)seed `params` when the
--- operation changes. Carries exactly the serializer's required keys with legacy-grounded
--- values; every default passes validateParams AND the serializer codec validate.
--- Naming carries NO `previous` key - that is the tick's internal alphabetical cursor,
--- not a setting (absent until the tick sets it). Every call builds a brand-new table
--- (including buy's nested `budget`) so callers can mutate the result freely. Unknown
--- operation -> empty table + warning.
---@param operation any rule operation key
---@return table params fresh default params table (empty for an unknown operation)
function RLHerdsmanRulePresenter.defaultParamsForOperation(operation)
    local params
    if operation == "sell" then
        params = { maxAnimals = 5, mark = false }
    elseif operation == "move" then
        -- No destinationHusbandry key: an inert draft (the dest is picked separately), mirroring a
        -- nil filterId. The cap + mark seed the same as sell; the planner caps a move on maxAnimals.
        params = { maxAnimals = 5, mark = false }
    elseif operation == "buy" then
        params = { maxAnimals = 5, budget = { type = "fixed", fixed = 5000, percentage = 1 } }
    elseif operation == "castrate" then
        params = { mark = false }
    elseif operation == "naming" then
        params = { convention = "random" }
    elseif operation == "ai" then
        params = { maxAnimals = 5, mark = false, semen = RLHerdsmanRulePresenter.SEMEN_ANY }
    elseif operation == "horseCare" then
        -- Param-free by design: the rule is enabled or it is not. The explicit branch is what
        -- separates a REGISTERED param-free operation from an unregistered one - the fallback
        -- below returns the same empty table but warns, and it must keep warning.
        params = {}
    else
        Log:warning("RLHerdsmanRulePresenter.defaultParamsForOperation: unknown operation '%s'; returning empty params", tostring(operation))
        return {}
    end

    Log:trace("RLHerdsmanRulePresenter.defaultParamsForOperation: operation=%s -> fresh defaults", tostring(operation))
    return params
end

--- Per-field value-domain checks. Each takes the raw param value and returns true only
--- when it is present AND in-domain (so an absent value is always false).

--- maxAnimals: an integer within [MAXANIMALS_MIN, MAXANIMALS_MAX].
---@param value any
---@return boolean
local function isValidMaxAnimals(value)
    return type(value) == "number" and value == math.floor(value)
        and value >= RLHerdsmanRulePresenter.MAXANIMALS_MIN
        and value <= RLHerdsmanRulePresenter.MAXANIMALS_MAX
end

--- mark: a boolean.
---@param value any
---@return boolean
local function isValidMark(value)
    return type(value) == "boolean"
end

--- convention: a member of the convention domain.
---@param value any
---@return boolean
local function isValidConvention(value)
    return type(value) == "string" and CONVENTION_SET[value] == true
end

--- budget.type: a member of the budget-type domain.
---@param value any
---@return boolean
local function isValidBudgetType(value)
    return type(value) == "string" and BUDGET_TYPE_SET[value] == true
end

--- budget.fixed: a non-negative integer (serializer setInt).
---@param value any
---@return boolean
local function isValidBudgetFixed(value)
    return type(value) == "number" and value == math.floor(value) and value >= 0
end

--- budget.percentage: a member of the 28-value whitelist.
---@param value any
---@return boolean
local function isValidBudgetPercentage(value)
    return type(value) == "number" and BUDGET_PERCENTAGE_SET[value] == true
end

--- semen: a non-empty string ("any" sentinel or a real dewar uniqueId).
---@param value any
---@return boolean
local function isValidSemen(value)
    return type(value) == "string" and value ~= ""
end

--- Per-operation USED-param descriptors: the ordered list of fields validateParams
--- reports on, each with how to read it from `params` and its domain check. The key
--- set per operation matches the serializer's required-field set exactly (the
--- codec-parity test asserts no drift); buy's nested budget sub-fields flatten to the
--- budgetType / budgetFixed / budgetPercentage result keys.
local PARAM_VALIDATORS = {
    sell = {
        { field = "maxAnimals", get = function(p) return p.maxAnimals end, check = isValidMaxAnimals },
        { field = "mark",       get = function(p) return p.mark end,       check = isValidMark },
    },
    move = {
        { field = "maxAnimals", get = function(p) return p.maxAnimals end, check = isValidMaxAnimals },
        { field = "mark",       get = function(p) return p.mark end,       check = isValidMark },
    },
    buy = {
        { field = "maxAnimals",       get = function(p) return p.maxAnimals end,                     check = isValidMaxAnimals },
        { field = "budgetType",       get = function(p) return p.budget and p.budget.type end,       check = isValidBudgetType },
        { field = "budgetFixed",      get = function(p) return p.budget and p.budget.fixed end,      check = isValidBudgetFixed },
        { field = "budgetPercentage", get = function(p) return p.budget and p.budget.percentage end, check = isValidBudgetPercentage },
    },
    castrate = {
        { field = "mark", get = function(p) return p.mark end, check = isValidMark },
    },
    naming = {
        { field = "convention", get = function(p) return p.convention end, check = isValidConvention },
    },
    ai = {
        { field = "maxAnimals", get = function(p) return p.maxAnimals end, check = isValidMaxAnimals },
        { field = "mark",       get = function(p) return p.mark end,       check = isValidMark },
        { field = "semen",      get = function(p) return p.semen end,      check = isValidSemen },
    },
    -- Param-free: no validators, so validateParams reports `ok = true` with an empty field map
    -- for ANY params table. The entry must exist all the same - an operation ABSENT from this
    -- table is an unknown one and fails closed.
    horseCare = {},
}

--- Process-lifetime flag: warn exactly once if validateParams is called with an unknown
--- operation. validateEdit calls this on every live draft validation, so a transient
--- invalid op in the editor must not spam the log (the spec's one-shot contract).
local _warnedValidateParamsUnknownOp = false

--- Validate an operation's params against their value domains, returning a per-field
--- boolean map plus an overall `ok`. `fields` carries one boolean per param the
--- operation USES (e.g. sell -> maxAnimals, mark; buy -> maxAnimals, budgetType,
--- budgetFixed, budgetPercentage); each is (present AND in-domain). `ok` is true only
--- when every used field is true, which guarantees the rule is serializer/wire-writable.
--- `previous` is never a field (it is the tick's cursor, not validated input). A nil /
--- non-table `params` is treated as empty (every field false). Unknown operation ->
--- `{ ok = false, fields = {} }` + a one-shot `:warning` (fail-closed return, like the
--- sister helpers; warned once per process so the live-validation caller cannot spam).
---@param operation any rule operation key
---@param params table|nil operation params table
---@return table { ok = boolean, fields = table<string, boolean> }
function RLHerdsmanRulePresenter.validateParams(operation, params)
    local validators = isKnownOperation(operation) and PARAM_VALIDATORS[operation] or nil
    if validators == nil then
        if not _warnedValidateParamsUnknownOp then
            Log:warning("RLHerdsmanRulePresenter.validateParams: unknown operation '%s'; not ok (empty field map)", tostring(operation))
            _warnedValidateParamsUnknownOp = true
        end
        return { ok = false, fields = {} }
    end

    local p = type(params) == "table" and params or {}
    local fields = {}
    local parts = {}
    local ok = true
    for _, validator in ipairs(validators) do
        local fieldOk = validator.check(validator.get(p)) == true
        fields[validator.field] = fieldOk
        parts[#parts + 1] = string.format("%s=%s", validator.field, tostring(fieldOk))
        if not fieldOk then ok = false end
    end

    Log:trace("RLHerdsmanRulePresenter.validateParams: operation=%s %s -> ok=%s",
        tostring(operation), table.concat(parts, " "), tostring(ok))
    return { ok = ok, fields = fields }
end

--- Process-lifetime flag: warn exactly once if RLConstants.AREA_CODES is unreachable
--- (a load-order regression), so the area-code lookup degrading to "?" is visible in
--- logs without spamming every option formatted.
local _warnedAreaCodesMissing = false

--- Format ONE real dewar's AI semen option label for the detail-pane picker, in the
--- legacy shape `"<areaCode> <farmId> <uniqueId> (<straws> <strawLabel>)"`. The area
--- code comes from RLConstants.AREA_CODES[country].code; the straw word is the injected
--- `labels.strawSingular` (straws == 1) or `labels.strawPlural` (the frame wires those
--- to the straw i18n strings). Real dewars only - it does NOT handle the "any" sentinel
--- (the frame prepends that as its own option). Unknown / nil country -> a "?" area-code
--- segment + a trace (deterministic, never crashes).
---@param country any animal country index into RLConstants.AREA_CODES
---@param farmId any owning farm id (rendered verbatim)
---@param uniqueId any dewar animal uniqueId (rendered verbatim)
---@param straws any straw count (drives singular/plural and rendered verbatim)
---@param labels table { strawSingular = string, strawPlural = string }
---@return string option
function RLHerdsmanRulePresenter.formatSemenOption(country, farmId, uniqueId, straws, labels)
    local areaCodes = RLConstants ~= nil and RLConstants.AREA_CODES or nil
    if areaCodes == nil and not _warnedAreaCodesMissing then
        Log:warning("RLHerdsmanRulePresenter.formatSemenOption: RLConstants.AREA_CODES unavailable; area codes will read '?' (check main.lua constants load order)")
        _warnedAreaCodesMissing = true
    end

    local entry = areaCodes ~= nil and areaCodes[country] or nil
    local code
    if entry ~= nil and type(entry.code) == "string" then
        code = entry.code
    else
        code = "?"
        Log:trace("RLHerdsmanRulePresenter.formatSemenOption: unknown country '%s' -> '?' area code", tostring(country))
    end

    local strawLabel = (straws == 1) and labels.strawSingular or labels.strawPlural
    local option = string.format("%s %s %s (%s %s)",
        code, tostring(farmId), tostring(uniqueId), tostring(straws), tostring(strawLabel))

    Log:trace("RLHerdsmanRulePresenter.formatSemenOption: country=%s farmId=%s uniqueId=%s straws=%s -> '%s'",
        tostring(country), tostring(farmId), tostring(uniqueId), tostring(straws), option)
    return option
end

-- =============================================================================
-- Filter-usage scoping
-- =============================================================================

--- Allowed filter-usage membership map for an operation (D7). Returns a fresh copy
--- (callers must not mutate the module table). Keys are RLFilterUsage constants;
--- callers key-test with `result[usage]`. Unknown operation -> empty map + warning.
---@param operation any rule operation key
---@return table membership map, e.g. { [RLFilterUsage.ANY] = true, [RLFilterUsage.DEALER] = true }
function RLHerdsmanRulePresenter.getAllowedFilterUsages(operation)
    local allowed = ALLOWED_USAGES[operation]
    if allowed == nil then
        Log:warning("RLHerdsmanRulePresenter.getAllowedFilterUsages: unknown operation '%s'; empty usage set", tostring(operation))
        return {}
    end

    local out = {}
    for usage, ok in pairs(allowed) do
        out[usage] = ok
    end

    Log:trace("RLHerdsmanRulePresenter.getAllowedFilterUsages: operation=%s any=%s owned=%s dealer=%s",
        tostring(operation), tostring(out[RLFilterUsage.ANY] == true),
        tostring(out[RLFilterUsage.OWNED] == true), tostring(out[RLFilterUsage.DEALER] == true))
    return out
end

--- True when `usage` is allowed for `operation` (D5: lets F4 clear a filter on
--- op-change when its usage no longer fits). Equivalent to membership in
--- getAllowedFilterUsages(operation). Unknown operation -> false + warning; nil
--- usage -> false.
---@param operation any rule operation key
---@param usage any RLFilterUsage value to test
---@return boolean
function RLHerdsmanRulePresenter.isFilterUsageAllowed(operation, usage)
    if usage == nil then
        Log:trace("RLHerdsmanRulePresenter.isFilterUsageAllowed: nil usage -> false (operation=%s)", tostring(operation))
        return false
    end

    local allowed = ALLOWED_USAGES[operation]
    if allowed == nil then
        Log:warning("RLHerdsmanRulePresenter.isFilterUsageAllowed: unknown operation '%s'; usage '%s' -> false",
            tostring(operation), tostring(usage))
        return false
    end

    local ok = allowed[usage] == true
    Log:trace("RLHerdsmanRulePresenter.isFilterUsageAllowed: operation=%s usage=%s -> %s",
        tostring(operation), tostring(usage), tostring(ok))
    return ok
end

--- The single usage to scope the filter PICKER by for an operation (D7). Derived from
--- ALLOWED_USAGES so it cannot drift from getAllowedFilterUsages: each non-naming entry is
--- exactly { ANY, X }, and this returns that one non-ANY member (buy -> DEALER; sell /
--- castrate / ai -> OWNED). The picker passes it as the `usage` scope to
--- RLFilterService:listAvailable, where ANY/nil filters fold in automatically - so a single
--- non-nil usage yields exactly the operation's { ANY, X } pool. Naming has no Filter row
--- (the picker never opens) -> nil; unknown operation -> nil + warning. nil here means "do
--- NOT open" to the caller (a nil usage would be a list-everything WILDCARD in listAvailable).
---@param operation any rule operation key
---@return string|nil RLFilterUsage value to scope by, or nil when no picker applies
function RLHerdsmanRulePresenter.getFilterPickerUsage(operation)
    if operation == "naming" then
        Log:trace("RLHerdsmanRulePresenter.getFilterPickerUsage: naming has no filter row -> nil")
        return nil
    end

    local allowed = ALLOWED_USAGES[operation]
    if allowed == nil then
        Log:warning("RLHerdsmanRulePresenter.getFilterPickerUsage: unknown operation '%s'; nil scope", tostring(operation))
        return nil
    end

    local scope = nil
    for usage, ok in pairs(allowed) do
        if ok and usage ~= RLFilterUsage.ANY then
            if scope ~= nil then
                -- ALLOWED_USAGES entries are exactly { ANY, X }; a 2nd non-ANY member means the
                -- table drifted and the picker scope would be a pairs-order coin-flip. Fail loud.
                Log:warning("RLHerdsmanRulePresenter.getFilterPickerUsage: operation '%s' has >1 non-ANY usage (%s, %s); scope is ambiguous - expected exactly { ANY, X }",
                    tostring(operation), tostring(scope), tostring(usage))
            end
            scope = usage
        end
    end

    Log:trace("RLHerdsmanRulePresenter.getFilterPickerUsage: operation=%s -> %s", tostring(operation), tostring(scope))
    return scope
end

--- Alphabetical-by-name ordering of a filter list for the picker (case-insensitive, nil-safe
--- id tie-break). Returns a SORTED COPY; the input array is never mutated (the caller owns the
--- service-cloned list). Reuses the same compareRulesByName comparator the rule list sorts by,
--- so filters and rules order identically and the rule cannot drift.
---@param filters table[]|nil array of filter records (each with `name` + `id`)
---@return table[] sorted shallow copy (empty table for nil / non-table input)
function RLHerdsmanRulePresenter.sortFiltersByName(filters)
    local out = {}
    if type(filters) == "table" then
        for i, f in ipairs(filters) do out[i] = f end
    end
    table.sort(out, compareRulesByName)
    Log:trace("RLHerdsmanRulePresenter.sortFiltersByName: %d filter(s) sorted", #out)
    return out
end

-- =============================================================================
-- AnimalType compatibility + husbandry targeting (F6)
-- =============================================================================

--- The union of every animal type NAME the OPERATION_ANIMAL_TYPES declarations reference,
--- sorted so the order is stable across runs. The frame resolves exactly this set against the
--- live registry and hands the result to the predicate below, so a declaration naming a new
--- type is resolved automatically and the two halves cannot drift apart.
---@return string[] names fresh sorted array of declared animal type names
function RLHerdsmanRulePresenter.getDeclaredAnimalTypeNames()
    local seen, names = {}, {}
    for _, rule in pairs(OPERATION_ANIMAL_TYPES) do
        for _, listKey in ipairs({ "allow", "exclude" }) do
            local list = rule[listKey]
            if type(list) == "table" then
                for _, name in ipairs(list) do
                    if not seen[name] then
                        seen[name] = true
                        names[#names + 1] = name
                    end
                end
            end
        end
    end
    table.sort(names)
    Log:trace("RLHerdsmanRulePresenter.getDeclaredAnimalTypeNames: %d declared name(s) [%s]",
        #names, table.concat(names, ","))
    return names
end

--- Render a declaration for the trace line: `allow:HORSE`, `exclude:CHICKEN`, or
--- `unrestricted`. The RULE is logged rather than the injected map, because a map renders as a
--- per-run table pointer and would make the line unreproducible between sessions.
---@param rule table|nil an OPERATION_ANIMAL_TYPES entry, or nil for an unrestricted operation
---@return string
local function describeAnimalTypeRule(rule)
    if rule == nil then return "unrestricted" end
    if rule.allow ~= nil then return "allow:" .. table.concat(rule.allow, ",") end
    if rule.exclude ~= nil then return "exclude:" .. table.concat(rule.exclude, ",") end
    return "unrestricted"
end

--- The ONE operation x animalType compatibility predicate, driven by the OPERATION_ANIMAL_TYPES
--- declarations: an operation absent from that table is unrestricted, an `exclude` operation is
--- valid for every type but the named ones, an `allow` operation is valid only for the named
--- ones. Live indices arrive as an injected name -> index map (never a `g_*`/AnimalType read
--- inside this pure helper); the frame owns building it. Shared by filterCandidateFilters, the
--- husbandry gate, the destination gate AND revalidateTargets/revalidateDestination, so
--- open-time gating and rebind cleanup cannot drift apart.
---
--- ONE rule generates the whole truth table: a declared name that does not resolve does not
--- match. So an `allow` list fails CLOSED (an unresolvable HORSE matches nothing, nothing is
--- targetable) and an `exclude` list fails OPEN (an unresolvable CHICKEN excludes nothing) with
--- no polarity special-casing and no mutable state. A nil `animalTypeIndex` (an ANY-type
--- candidate) is the same rule again: it matches no resolved index, so exclude admits it and
--- allow refuses it.
---@param operation any rule operation key
---@param animalTypeIndex any candidate animalType index, or nil for ANY
---@param animalTypeIndexByName table|nil map of declared animal type NAME -> live animalType index
---@return boolean
function RLHerdsmanRulePresenter.isOperationAnimalTypeCompatible(operation, animalTypeIndex, animalTypeIndexByName)
    local rule = OPERATION_ANIMAL_TYPES[operation]
    local compatible
    if rule == nil then
        compatible = true
    else
        local byName = type(animalTypeIndexByName) == "table" and animalTypeIndexByName or {}
        if rule.allow ~= nil then
            compatible = false
            for _, name in ipairs(rule.allow) do
                local idx = byName[name]
                if idx ~= nil and idx == animalTypeIndex then
                    compatible = true
                    break
                end
            end
        elseif rule.exclude ~= nil then
            compatible = true
            for _, name in ipairs(rule.exclude) do
                local idx = byName[name]
                if idx ~= nil and idx == animalTypeIndex then
                    compatible = false
                    break
                end
            end
        else
            -- A declaration entry carrying neither list restricts nothing.
            compatible = true
        end
    end
    Log:trace("RLHerdsmanRulePresenter.isOperationAnimalTypeCompatible: operation=%s animalType=%s rule=%s -> %s",
        tostring(operation), tostring(animalTypeIndex), describeAnimalTypeRule(rule), tostring(compatible))
    return compatible
end

--- Husbandry keep-gate shared by selectTargetableHusbandries (descriptors) AND
--- revalidateTargets (resolvable targets) - the single source of truth so open-time listing
--- and rebind cleanup cannot diverge. Keep a husbandry when its animalType is KNOWN (a
--- nil-type husbandry is EXCLUDED from typed lists and never matches the castrate exclusion),
--- matches the filter's animalType (or the filter is ANY/nil = every type), AND the
--- operation is animalType-compatible.
---@param animalTypeIndex any husbandry animalType index
---@param filterAnimalType any filter scope animalType, or nil for ANY (all types)
---@param operation any rule operation key
---@param animalTypeIndexByName table|nil map of declared animal type NAME -> live animalType index
---@return boolean
local function keepHusbandryType(animalTypeIndex, filterAnimalType, operation, animalTypeIndexByName)
    if animalTypeIndex == nil then return false end
    if filterAnimalType ~= nil and animalTypeIndex ~= filterAnimalType then return false end
    return RLHerdsmanRulePresenter.isOperationAnimalTypeCompatible(operation, animalTypeIndex, animalTypeIndexByName)
end

--- Set-aware DESTINATION type gate: `typeSpec` is a scalar animalType index (a
--- husbandry dest) OR an array of type indices (an EPP butcher that accepts several types). Admits
--- when the scalar keepHusbandryType gate passes for the scalar, or for ANY member of the set; a nil
--- scalar / nil-or-empty set is excluded. Used ONLY on the destination axis
--- (selectDestinationHusbandries + revalidateDestination) - keepHusbandryType stays scalar so the
--- source picker + target revalidation are untouched.
---@param typeSpec any scalar animalType index, or an array of type indices (EPP)
---@param filterAnimalType any filter scope animalType, or nil for ANY
---@param operation any rule operation key (always "move" on the dest axis)
---@param animalTypeIndexByName table|nil map of declared animal type NAME -> live animalType index
---@return boolean
local function keepDestinationType(typeSpec, filterAnimalType, operation, animalTypeIndexByName)
    if type(typeSpec) == "table" then
        for _, at in ipairs(typeSpec) do
            if keepHusbandryType(at, filterAnimalType, operation, animalTypeIndexByName) then return true end
        end
        return false
    end
    return keepHusbandryType(typeSpec, filterAnimalType, operation, animalTypeIndexByName)
end

--- Comparator for husbandry descriptors: case-insensitive name then uniqueId tie-break.
--- The frame applies the "Husbandry N" fallback label before projecting each
--- descriptor, so `name` is never empty; the uniqueId tie-break keeps duplicate display
--- names in a deterministic, stable order (saved target-array order + pre-check matching).
---@param a table descriptor { uniqueId, animalType, name }
---@param b table descriptor
---@return boolean
local function compareHusbandriesByName(a, b)
    local an = string.lower(tostring(a.name or ""))
    local bn = string.lower(tostring(b.name or ""))
    if an ~= bn then return an < bn end
    return tostring(a.uniqueId) < tostring(b.uniqueId)
end

--- Retrofit the filter-picker candidate list for the operation's animalType scope: drop a typed filter whose animalType is incompatible with the operation
--- (castrate x chicken), KEEP every ANY-type filter (`f.animalType == nil`, admits all
--- types). Returns a NEW array (input never mutated; the caller owns the service-cloned
--- list). Ordering stays the caller's job (sortFiltersByName).
---@param filters table[]|nil candidate filter records (each with `animalType`)
---@param operation any rule operation key
---@param animalTypeIndexByName table|nil map of declared animal type NAME -> live animalType index
---@return table[] filtered shallow copy
function RLHerdsmanRulePresenter.filterCandidateFilters(filters, operation, animalTypeIndexByName)
    local out = {}
    local dropped = 0
    if type(filters) == "table" then
        for _, f in ipairs(filters) do
            local at = type(f) == "table" and f.animalType or nil
            if at == nil or RLHerdsmanRulePresenter.isOperationAnimalTypeCompatible(operation, at, animalTypeIndexByName) then
                out[#out + 1] = f
            else
                dropped = dropped + 1
            end
        end
    end
    Log:trace("RLHerdsmanRulePresenter.filterCandidateFilters: operation=%s -> %d kept, %d dropped (incompatible typed)",
        tostring(operation), #out, dropped)
    return out
end

--- Decide whether switching a rule to `operation` must CLEAR its bound filter, and name the
--- cause. Returns nil to KEEP the binding, else one of three reason strings. The three causes an
--- operation change has for dropping a filter live here together so the frame owns no part of
--- the decision:
---   * "naming"     - a naming rule carries no filter at all (the service floor rejects one)
---   * "usage"      - the filter's usage bucket is not one the new operation draws from
---   * "animalType" - the filter's animal type is one the new operation cannot act on
---
--- ARM ORDER IS CONTRACT: naming, then usage, then animalType. Every arm produces the SAME
--- clear, so the order decides only which cause is REPORTED. The reason is diagnostic - it
--- exists because "my filter disappeared" is otherwise undiagnosable - and no caller may branch
--- on its value without renegotiating that.
---
--- Sits beside filterCandidateFilters because the two MUST agree on the animalType axis: a
--- filter the picker refuses to OFFER for type reasons is exactly a filter an operation change
--- must not leave BOUND. That agreement is why the animalType arm tests a NON-NIL
--- `filter.animalType`, carrying filterCandidateFilters' own nil short-circuit. Without it every
--- ANY-type filter would be cleared on a switch to an allow-list operation, because
--- isOperationAnimalTypeCompatible answers false for a nil index under `allow` - the same one
--- rule that gives the gate its fail-closed / fail-open polarity.
---
--- An UNRESOLVABLE binding (a deleted filter resolving to nil, or a non-table record) is left
--- as-is, mirroring filterCandidateFilters' own non-table handling: a dangling id is repaired by
--- rebinding, never by a silent erase.
---@param operation any the operation being switched TO
---@param filter table|nil the RESOLVED filter record `{ usage, animalType, ... }`, or nil
---@param animalTypeIndexByName table|nil map of declared animal type NAME -> live animalType index
---@return string|nil reason nil to keep the binding, else "naming" | "usage" | "animalType"
function RLHerdsmanRulePresenter.filterClearReasonForOperation(operation, filter, animalTypeIndexByName)
    if operation == "naming" then
        Log:trace("RLHerdsmanRulePresenter.filterClearReasonForOperation: operation=naming -> clear (reason=naming)")
        return "naming"
    end

    -- type() rather than a field read: this branch must never index `filter`, so a nil or scalar
    -- binding cannot raise here (a raise would cost an engine stack in the log).
    if type(filter) ~= "table" then
        Log:trace("RLHerdsmanRulePresenter.filterClearReasonForOperation: operation=%s filter unresolvable (%s) -> keep",
            tostring(operation), type(filter))
        return nil
    end

    if not RLHerdsmanRulePresenter.isFilterUsageAllowed(operation, filter.usage) then
        Log:trace("RLHerdsmanRulePresenter.filterClearReasonForOperation: operation=%s usage=%s not allowed -> clear (reason=usage)",
            tostring(operation), tostring(filter.usage))
        return "usage"
    end

    local at = filter.animalType
    if at ~= nil and not RLHerdsmanRulePresenter.isOperationAnimalTypeCompatible(operation, at, animalTypeIndexByName) then
        Log:trace("RLHerdsmanRulePresenter.filterClearReasonForOperation: operation=%s animalType=%s incompatible -> clear (reason=animalType)",
            tostring(operation), tostring(at))
        return "animalType"
    end

    Log:trace("RLHerdsmanRulePresenter.filterClearReasonForOperation: operation=%s usage=%s animalType=%s -> keep",
        tostring(operation), tostring(filter.usage), tostring(at))
    return nil
end

--- Gate + order the husbandry picker candidate list for a rule (D8). From a list of live
--- husbandry descriptors `{ uniqueId, animalType, name }`, keep those the operation + filter
--- scope admit (keepHusbandryType: nil-type excluded, filter-type match or ANY,
--- castrate-chicken excluded), then sort case-insensitive name + uniqueId tie-break.
--- Returns a NEW sorted array; the input is never mutated.
---@param husbandries table[]|nil descriptors { uniqueId, animalType, name }
---@param filterAnimalType any filter scope animalType, or nil for ANY (all types)
---@param operation any rule operation key
---@param animalTypeIndexByName table|nil map of declared animal type NAME -> live animalType index
---@return table[] sorted candidate descriptors
function RLHerdsmanRulePresenter.selectTargetableHusbandries(husbandries, filterAnimalType, operation, animalTypeIndexByName)
    local out = {}
    local excluded = 0
    if type(husbandries) == "table" then
        for _, h in ipairs(husbandries) do
            local at = type(h) == "table" and h.animalType or nil
            if keepHusbandryType(at, filterAnimalType, operation, animalTypeIndexByName) then
                out[#out + 1] = h
            else
                excluded = excluded + 1
            end
        end
    end
    table.sort(out, compareHusbandriesByName)
    Log:trace("RLHerdsmanRulePresenter.selectTargetableHusbandries: operation=%s filterType=%s -> %d candidate(s), %d excluded",
        tostring(operation), tostring(filterAnimalType), #out, excluded)
    return out
end

--- Gate + order the SINGLE-select destination candidate list for a MOVE rule (decision 3b). Gates
--- each descriptor with the SET-AWARE keepDestinationType (operation "move", type-compatible with
--- every type) so a husbandry dest (scalar `animalType`) AND an EPP butcher (set `animalTypes`) both
--- survive the animalType scope, sorts by name, then DROPS any descriptor whose `uniqueId` is in
--- `excludeUids` (the rule's own source targetHusbandries): a source pen is never a valid
--- destination, which also keeps every offered dest resolvable in the executor's per-farm ctx maps
--- (source==dest would be bad data). Cannot reuse selectTargetableHusbandries here - that path is the
--- scalar source gate and would drop every EPP (nil scalar animalType). Returns a NEW array;
--- inputs never mutated.
---@param husbandries table[]|nil descriptors { uniqueId, animalType|animalTypes, name, isEPP? }
---@param filterAnimalType any filter scope animalType, or nil for ANY (all types)
--- NOTE the argument POSITION: this function takes no `operation` (it applies "move"
--- internally), so the type map sits THIRD - one slot left of where it sits in the
--- source-side `selectTargetableHusbandries`.
---@param animalTypeIndexByName table|nil map of declared animal type NAME -> live animalType index
---@param excludeUids table|nil array of source uniqueId strings to exclude from the dest candidates
---@return table[] sorted candidate descriptors (sources removed)
function RLHerdsmanRulePresenter.selectDestinationHusbandries(husbandries, filterAnimalType, animalTypeIndexByName, excludeUids)
    local gated = {}
    local typeGated = 0
    if type(husbandries) == "table" then
        for _, h in ipairs(husbandries) do
            local typeSpec = type(h) == "table" and (h.animalTypes or h.animalType) or nil
            if type(h) == "table" and keepDestinationType(typeSpec, filterAnimalType, "move", animalTypeIndexByName) then
                gated[#gated + 1] = h
            else
                typeGated = typeGated + 1
            end
        end
    end
    table.sort(gated, compareHusbandriesByName)

    local excluded = {}
    if type(excludeUids) == "table" then
        for _, uid in ipairs(excludeUids) do excluded[uid] = true end
    end
    local out = {}
    local removed = 0
    for _, h in ipairs(gated) do
        if excluded[h.uniqueId] then
            removed = removed + 1
        else
            out[#out + 1] = h
        end
    end
    Log:trace("RLHerdsmanRulePresenter.selectDestinationHusbandries: filterType=%s -> %d candidate(s), %d type-gated, %d source(s) excluded",
        tostring(filterAnimalType), #out, typeGated, removed)
    return out
end

--- Revalidate a rule's stored target uniqueIds after a filter rebind OR an operation change
---. For each uid: if it is ABSENT from `typeByUid` it is UNRESOLVABLE (a deleted /
--- transiently-unloaded placeable, or a nil-type one the frame did not map) and is PRESERVED
--- - protecting the `(missing)` repair affordance + MP transient-divergence; only a
--- type-incompatible RESOLVABLE target drops (same keepHusbandryType gate as the picker, so
--- listing and cleanup share one predicate - M1). Order is preserved. Returns the kept
--- uniqueIds (a new array; input never mutated). An ANY (`filterAnimalType == nil`) scope
--- keeps every resolvable target except a castrate-incompatible one (the operation gate
--- still applies).
---@param targetHusbandries table|nil array of placeable uniqueId strings
---@param typeByUid table|nil map uniqueId -> animalType index for LIVE husbandries (non-nil types only)
---@param filterAnimalType any filter scope animalType, or nil for ANY
---@param operation any rule operation key
---@param animalTypeIndexByName table|nil map of declared animal type NAME -> live animalType index
---@return table kept array of surviving uniqueId strings (input order)
function RLHerdsmanRulePresenter.revalidateTargets(targetHusbandries, typeByUid, filterAnimalType, operation, animalTypeIndexByName)
    local kept = {}
    local dropped = 0
    local preserved = 0
    local types = type(typeByUid) == "table" and typeByUid or {}
    if type(targetHusbandries) == "table" then
        for _, uid in ipairs(targetHusbandries) do
            local at = types[uid]
            if at == nil then
                -- Unresolvable (deleted / transient / nil-type): PRESERVE.
                kept[#kept + 1] = uid
                preserved = preserved + 1
            elseif keepHusbandryType(at, filterAnimalType, operation, animalTypeIndexByName) then
                kept[#kept + 1] = uid
            else
                dropped = dropped + 1
            end
        end
    end
    Log:trace("RLHerdsmanRulePresenter.revalidateTargets: operation=%s filterType=%s -> %d kept (%d preserved-unresolvable), %d dropped",
        tostring(operation), tostring(filterAnimalType), #kept, preserved, dropped)
    return kept
end

--- Revalidate a MOVE rule's stored `destinationHusbandry` after a filter rebind OR a source-set
--- change - the single-key twin of revalidateTargets, durable against BOTH gate axes. A nil
--- dest stays nil. A dest ABSENT from `typeByUid` is UNRESOLVABLE (deleted / transient / nil-type)
--- and is PRESERVED - protecting the `(missing)` repair affordance + MP transient-divergence. A
--- RESOLVABLE dest drops to nil when EITHER its type is no longer keepDestinationType-admitted (the
--- picker's gate, operation "move") OR its `uniqueId` is now a member of `sourceUids` (a post-pick
--- source edit turned the dest into a source - the executor treats source==dest as bad data). The
--- `typeByUid` value is a scalar animalType (husbandry dest) OR a type-index SET (an EPP butcher
--- dest), gated set-aware; an EPP dest that maps to a set is type-gated instead of preserved
--- forever.
---@param destinationHusbandry any the stored dest uniqueId string, or nil
---@param typeByUid table|nil map uniqueId -> animalType index (husbandry) or type-index set (EPP) for LIVE dests
---@param filterAnimalType any filter scope animalType, or nil for ANY
--- NOTE the argument POSITION: like `selectDestinationHusbandries` this takes no `operation`
--- (it applies "move" internally), so the type map sits FOURTH - one slot left of where it
--- sits in the source-side `revalidateTargets`.
---@param animalTypeIndexByName table|nil map of declared animal type NAME -> live animalType index
---@param sourceUids table|nil array of the rule's source target uniqueId strings
---@return any destinationHusbandry the surviving dest key, or nil
function RLHerdsmanRulePresenter.revalidateDestination(destinationHusbandry, typeByUid, filterAnimalType, animalTypeIndexByName, sourceUids)
    if destinationHusbandry == nil then
        Log:trace("RLHerdsmanRulePresenter.revalidateDestination: nil dest -> nil")
        return nil
    end
    local types = type(typeByUid) == "table" and typeByUid or {}
    local at = types[destinationHusbandry]
    if at == nil then
        -- Unresolvable (deleted / transient / nil-type): PRESERVE the (missing) repair affordance.
        Log:trace("RLHerdsmanRulePresenter.revalidateDestination: dest %s unresolvable -> preserved", tostring(destinationHusbandry))
        return destinationHusbandry
    end
    if not keepDestinationType(at, filterAnimalType, "move", animalTypeIndexByName) then
        Log:trace("RLHerdsmanRulePresenter.revalidateDestination: dest %s now type-incompatible -> dropped", tostring(destinationHusbandry))
        return nil
    end
    if type(sourceUids) == "table" then
        for _, uid in ipairs(sourceUids) do
            if uid == destinationHusbandry then
                Log:trace("RLHerdsmanRulePresenter.revalidateDestination: dest %s is now a source -> dropped", tostring(destinationHusbandry))
                return nil
            end
        end
    end
    Log:trace("RLHerdsmanRulePresenter.revalidateDestination: dest %s kept", tostring(destinationHusbandry))
    return destinationHusbandry
end

-- =============================================================================
-- Read-only summaries
-- =============================================================================

--- Human-readable husbandry summary for the detail pane. Resolves each target
--- uniqueId to a placeable name via the injected `resolveName(uid) -> string|nil`,
--- joining resolved names with ", " in list order. An entry the resolver cannot
--- resolve (nil / non-string / empty) reads `labels.missing`; an empty / nil target
--- list reads `labels.none`; a nil resolver makes every entry `labels.missing`.
---@param targetHusbandries table|nil array of placeable uniqueId strings
---@param resolveName function|nil function(uid) -> name string|nil (frame wires the placeableSystem lookup)
---@param labels table { missing = string, none = string }
---@return string summary
function RLHerdsmanRulePresenter.getHusbandrySummary(targetHusbandries, resolveName, labels)
    if type(targetHusbandries) ~= "table" or #targetHusbandries == 0 then
        Log:trace("RLHerdsmanRulePresenter.getHusbandrySummary: empty/nil targets -> none")
        return labels.none
    end

    local names = {}
    local missing = 0
    for i, uid in ipairs(targetHusbandries) do
        local resolved = nil
        if resolveName ~= nil then resolved = resolveName(uid) end
        if type(resolved) == "string" and resolved ~= "" then
            names[i] = resolved
        else
            names[i] = labels.missing
            missing = missing + 1
        end
    end

    Log:trace("RLHerdsmanRulePresenter.getHusbandrySummary: %d target(s), %d unresolved", #targetHusbandries, missing)
    return table.concat(names, ", ")
end

--- Count-form label for the detail-pane husbandries BUTTON - replaces the old full
--- name-join (which overflowed a single-line button). 0 targets -> `labels.none` (the
--- "select husbandries" CTA, mirroring the filter button's empty CTA); exactly 1 -> that
--- husbandry's resolved name via the injected `resolveName(uid)` (unresolvable -> the
--- `(missing)` label); >= 2 -> `labels.selected` formatted with the count ("N selected"). A
--- nil resolver makes a single target read `(missing)`. The full per-name list is the
--- deferred Ask-First "area below" - never joined onto the button.
---@param targetHusbandries table|nil array of placeable uniqueId strings
---@param resolveName function|nil function(uid) -> name string|nil (frame wires the placeableSystem lookup)
---@param labels table { none = string, missing = string, selected = string (a "%d" format) }
---@return string label
function RLHerdsmanRulePresenter.formatHusbandryButtonLabel(targetHusbandries, resolveName, labels)
    local count = type(targetHusbandries) == "table" and #targetHusbandries or 0
    if count == 0 then
        Log:trace("RLHerdsmanRulePresenter.formatHusbandryButtonLabel: 0 targets -> none CTA")
        return labels.none
    end
    if count == 1 then
        local resolved = nil
        if resolveName ~= nil then resolved = resolveName(targetHusbandries[1]) end
        local label = (type(resolved) == "string" and resolved ~= "") and resolved or labels.missing
        Log:trace("RLHerdsmanRulePresenter.formatHusbandryButtonLabel: 1 target -> %q", tostring(label))
        return label
    end
    Log:trace("RLHerdsmanRulePresenter.formatHusbandryButtonLabel: %d targets -> selected form", count)
    return string.format(labels.selected, count)
end

--- Single-key summary for the detail-pane destination BUTTON (move rules). nil / non-string / empty
--- / WHITESPACE-only key -> `labels.none` (the "Select destination" CTA - the blank-trim matches
--- validateEdit's present-but-blank rejection, unlike formatHusbandryButtonLabel's 1-target branch
--- which shows `(missing)` for a whitespace key); a resolvable non-blank key -> the husbandry name
--- via the injected `resolveName(uid)`; an unresolvable non-blank key -> `labels.missing`.
---@param destinationHusbandry any the stored dest uniqueId string, or nil
---@param resolveName function|nil function(uid) -> name string|nil (frame wires the placeableSystem lookup)
---@param labels table { none = string, missing = string }
---@return string label
function RLHerdsmanRulePresenter.formatDestinationButtonLabel(destinationHusbandry, resolveName, labels)
    local hasKey = type(destinationHusbandry) == "string" and destinationHusbandry:gsub("%s", "") ~= ""
    if not hasKey then
        Log:trace("RLHerdsmanRulePresenter.formatDestinationButtonLabel: blank/absent dest -> none CTA")
        return labels.none
    end
    local resolved = nil
    if resolveName ~= nil then resolved = resolveName(destinationHusbandry) end
    local label = (type(resolved) == "string" and resolved ~= "") and resolved or labels.missing
    Log:trace("RLHerdsmanRulePresenter.formatDestinationButtonLabel: dest %s -> %q", tostring(destinationHusbandry), tostring(label))
    return label
end

--- Human-readable filter summary for the detail pane. Resolves `filterId` via the
--- injected `resolveFilter(filterId) -> filter|nil` and returns the resolved filter's
--- name. `filterId == nil` -> `labels.none` (naming rules / unset); a non-nil id the
--- resolver cannot resolve (deleted filter) -> `labels.missing` (D16 orphan state); a
--- nil resolver with a non-nil id -> `labels.missing`.
---@param filterId any saved-filter id (string) or nil
---@param resolveFilter function|nil function(filterId) -> filter table|nil (frame wires RLFilterService:getById)
---@param labels table { missing = string, none = string }
---@return string summary
function RLHerdsmanRulePresenter.getFilterSummary(filterId, resolveFilter, labels)
    if filterId == nil then
        Log:trace("RLHerdsmanRulePresenter.getFilterSummary: nil filterId -> none")
        return labels.none
    end

    local filter = nil
    if resolveFilter ~= nil then filter = resolveFilter(filterId) end
    if type(filter) ~= "table" or type(filter.name) ~= "string" or filter.name == "" then
        Log:trace("RLHerdsmanRulePresenter.getFilterSummary: filterId=%s unresolved -> missing", tostring(filterId))
        return labels.missing
    end

    Log:trace("RLHerdsmanRulePresenter.getFilterSummary: filterId=%s -> '%s'", tostring(filterId), filter.name)
    return filter.name
end

-- =============================================================================
-- Legacy-active banner (D13)
-- =============================================================================

--- Coexistence banner predicate (D13). Read-only over the legacy per-husbandry AI
--- settings: a husbandry is "legacy active" when ANY of its five operations is
--- `enabled == true`. Returns `(active, affectedNames)` where affectedNames lists, in
--- input order, the names of husbandries with >= 1 enabled operation. nil / non-table
--- entries -> `(false, {})`; a missing `settings` table or operation entry -> treated
--- as not-enabled. Read-only: never reorders or "fixes" legacy execution.
---@param entries table|nil array of `{ name = string, settings = { buy = { enabled }, sell = ..., castrate = ..., naming = ..., ai = ... } }`
---@return boolean active true when any husbandry has any enabled legacy operation
---@return table affectedNames string[] of names with >= 1 enabled operation (input order)
function RLHerdsmanRulePresenter.isLegacyActive(entries)
    local active = false
    local affectedNames = {}
    if type(entries) ~= "table" then
        Log:trace("RLHerdsmanRulePresenter.isLegacyActive: nil/non-table entries -> false")
        return false, affectedNames
    end

    for _, entry in ipairs(entries) do
        local settings = type(entry) == "table" and entry.settings or nil
        local entryActive = false
        if type(settings) == "table" then
            for _, op in ipairs(RLHerdsmanRulePresenter.OPERATION_ORDER) do
                local opSettings = settings[op]
                if type(opSettings) == "table" and opSettings.enabled == true then
                    entryActive = true
                    break
                end
            end
        end
        if entryActive then
            active = true
            affectedNames[#affectedNames + 1] = entry.name
        end
    end

    Log:trace("RLHerdsmanRulePresenter.isLegacyActive: active=%s affected=%d", tostring(active), #affectedNames)
    return active, affectedNames
end

-- =============================================================================
-- Edit validation (pre-submit; stricter than the service floor on targets)
-- =============================================================================

--- Validate an in-progress rule draft for the detail pane (pre-submit). Returns a
--- per-field boolean breakdown plus an overall `valid`. Deliberately STRICTER than
--- RLHerdsmanRuleService's validity floor on targets: the service accepts an empty
--- target list (inert rule), but the editor requires >= 1 so a saved rule actually
--- does something. Re-asserts the naming-filterId-nil and operation-enum rules so the
--- UI never green-lights a draft the service rejects on save. The animalType
--- target-gate + castrate chicken-exclusion stay out of scope (-> F6):
---   * nameOk         - `name` is a non-blank string (not all-whitespace)
---   * operationOk    - `operation` is in the canonical RLHerdsmanRuleService.OPERATIONS set
---   * filterOk       - naming: `filterId == nil`; non-naming: a filter is required only when
---                      `enabled` - a disabled draft may carry a nil filterId;
---                      a present filterId must always be a non-blank string
---   * filterRequired - non-naming AND `enabled` (surfaced for the frame's flush enable-demote)
---   * husbandriesOk  - `#targetHusbandries >= 1`
---   * paramsOk       - `validateParams(operation, params).ok` (per-op param value domains)
---   * destinationOk  - move dest gate (the filterOk twin): an ENABLED move needs a non-blank
---                      `params.destinationHusbandry`; a disabled move may carry nil; non-move ops n/a (true)
---   * destinationRequired - move AND `enabled` (surfaced for the frame's flush enable-demote)
---   * valid          - nameOk AND operationOk AND filterOk AND husbandriesOk AND paramsOk AND destinationOk
--- nil / non-table draft -> all-false.
---@param draft table|nil { name, operation, enabled, filterId, targetHusbandries, params }
---@return table { valid, nameOk, operationOk, filterOk, filterRequired, husbandriesOk, paramsOk, destinationOk, destinationRequired } (all boolean)
function RLHerdsmanRulePresenter.validateEdit(draft)
    if type(draft) ~= "table" then
        Log:trace("RLHerdsmanRulePresenter.validateEdit: nil/non-table draft -> all false")
        return { valid = false, nameOk = false, operationOk = false, filterOk = false, filterRequired = false, husbandriesOk = false, paramsOk = false, destinationOk = false, destinationRequired = false }
    end

    local nameOk = type(draft.name) == "string" and draft.name:gsub("%s", "") ~= ""
    local operationOk = isKnownOperation(draft.operation)

    -- filterId-vs-operation, enabled-conditional (the frame-side twin of the relaxed
    -- service floor): naming MUST carry a nil filterId; a non-naming rule needs a filter only
    -- to be ENABLED (mirrors F6's enabled-conditional husbandries) - a disabled draft may carry
    -- a nil filterId (an incomplete draft, inert until a filter is picked). A present filterId
    -- must always be a non-blank string. filterRequired (== non-naming AND enabled) is surfaced
    -- so the frame's flush demote can switch off just the enable on an unfiltered rule.
    local filterRequired = draft.operation ~= "naming" and draft.enabled == true
    local filterOk
    if draft.operation == "naming" then
        filterOk = draft.filterId == nil
    else
        local present = type(draft.filterId) == "string" and draft.filterId:gsub("%s", "") ~= ""
        if draft.enabled == true then
            filterOk = present
        else
            filterOk = draft.filterId == nil or present
        end
    end

    local husbandriesOk = type(draft.targetHusbandries) == "table" and #draft.targetHusbandries >= 1

    -- destinationHusbandry-vs-operation, enabled-conditional (the dest twin of filterOk): only a
    -- `move` rule has a destination, and it needs one only to be ENABLED (a disabled move draft may
    -- carry a nil dest - inert until picked). A present dest must always be a non-blank string. For a
    -- non-move op the dest is n/a (true). destinationRequired (== move AND enabled) is surfaced for
    -- the frame's flush demote (switch off just the enable on a dest-less move).
    local destinationRequired = draft.operation == "move" and draft.enabled == true
    local destinationOk
    if draft.operation == "move" then
        local dest = type(draft.params) == "table" and draft.params.destinationHusbandry or nil
        local present = type(dest) == "string" and dest:gsub("%s", "") ~= ""
        if draft.enabled == true then
            destinationOk = present
        else
            destinationOk = dest == nil or present
        end
    else
        destinationOk = true
    end

    local paramsOk = RLHerdsmanRulePresenter.validateParams(draft.operation, draft.params).ok

    local valid = nameOk and operationOk and filterOk and husbandriesOk and paramsOk and destinationOk

    Log:trace("RLHerdsmanRulePresenter.validateEdit: nameOk=%s operationOk=%s filterOk=%s filterRequired=%s husbandriesOk=%s paramsOk=%s destinationOk=%s destinationRequired=%s -> valid=%s",
        tostring(nameOk), tostring(operationOk), tostring(filterOk), tostring(filterRequired), tostring(husbandriesOk), tostring(paramsOk), tostring(destinationOk), tostring(destinationRequired), tostring(valid))
    return { valid = valid, nameOk = nameOk, operationOk = operationOk, filterOk = filterOk, filterRequired = filterRequired, husbandriesOk = husbandriesOk, paramsOk = paramsOk, destinationOk = destinationOk, destinationRequired = destinationRequired }
end

--- The detail-pane FLUSH gate - the enabled-conditional refinement of validateEdit.
--- Builds on validateEdit but makes the husbandry requirement ENABLED-CONDITIONAL: a rule
--- needs >= 1 target ONLY when it is `enabled`. A disabled / incomplete rule therefore stays
--- fully editable and persists with 0 targets (= a no-op rule, the empty=no-op contract);
--- enabling a 0-target rule is blocked (the enable reverts via this gate). So `ok` = name +
--- operation + filter + params all valid AND (the rule is disabled OR has >= 1 husbandry).
--- `husbandriesRequired` (== the enabled flag) and `filterRequired` (== non-naming AND enabled,
--- from validateEdit) are surfaced for the frame's enable-demote + revert logging. The
--- enabled-conditional filter requirement is baked into validateEdit's `filterOk`, so `ok`
--- consumes it directly (no separate filter arm here); the move destination gate is likewise baked
--- into validateEdit's `destinationOk` and consumed the same way. Encoded here (not ad-hoc in the
--- frame) so the gate dual-runs. nil / non-table draft -> not ok. This supersedes the pre-F6 frame
--- gate that excluded husbandriesOk entirely.
---@param draft table|nil merged rule record (includes `enabled`)
---@return table { ok, nameOk, operationOk, filterOk, filterRequired, paramsOk, husbandriesOk, husbandriesRequired, destinationOk, destinationRequired } (all boolean)
function RLHerdsmanRulePresenter.validateFlush(draft)
    local v = RLHerdsmanRulePresenter.validateEdit(draft)
    local husbandriesRequired = type(draft) == "table" and draft.enabled == true
    local ok = v.nameOk and v.operationOk and v.filterOk and v.paramsOk and v.destinationOk
        and (not husbandriesRequired or v.husbandriesOk)

    Log:trace("RLHerdsmanRulePresenter.validateFlush: nameOk=%s operationOk=%s filterOk=%s filterRequired=%s paramsOk=%s destinationOk=%s destinationRequired=%s husbandriesOk=%s husbandriesRequired=%s -> ok=%s",
        tostring(v.nameOk), tostring(v.operationOk), tostring(v.filterOk), tostring(v.filterRequired), tostring(v.paramsOk),
        tostring(v.destinationOk), tostring(v.destinationRequired), tostring(v.husbandriesOk), tostring(husbandriesRequired), tostring(ok))
    return {
        ok = ok,
        nameOk = v.nameOk, operationOk = v.operationOk, filterOk = v.filterOk, filterRequired = v.filterRequired,
        paramsOk = v.paramsOk, husbandriesOk = v.husbandriesOk,
        destinationOk = v.destinationOk, destinationRequired = v.destinationRequired,
        husbandriesRequired = husbandriesRequired,
    }
end

--- Every key `enableDemotionAxes` reads. validateFlush returns all ten as booleans, so a
--- non-boolean at any of them means the caller handed over something that is not a flush
--- breakdown - the one shape the predicate must refuse rather than interpret.
local DEMOTION_BREAKDOWN_KEYS = {
    "ok", "nameOk", "operationOk", "paramsOk",
    "filterOk", "filterRequired",
    "husbandriesOk", "husbandriesRequired",
    "destinationOk", "destinationRequired",
}

--- Which ENABLE-GATED axes are what stop this draft flushing - i.e. the axes that would come
--- good if the rule were simply not enabled. Returns an array of axis names to DEMOTE on
--- (a subset of `filter`, `husbandries`, `destination`), or nil to leave the enable alone.
---
--- The frame consumes this in two places - the edit-time flip and the flush backstop - and the
--- decision lives here, once, so the two can never diverge on what "invalidated by this edit"
--- means. The input is `validateFlush`'s breakdown verbatim; this function re-derives nothing.
---
--- Answers a non-nil result when AND ONLY WHEN all of:
---   * the draft fails the flush gate (`ok` false) - a valid draft is never demoted;
---   * `nameOk`, `operationOk` and `paramsOk` all hold - a blank name or a bad param value is
---     NOT an enable-gated failure, and demoting on one would silently disable a rule the
---     player can still repair by fixing the field they just broke. Those keep the frame's
---     full revert;
---   * at least one required-and-failing enable-gated axis exists.
--- The `*Required` flags already encode `enabled == true` (validateEdit :1340/:1360,
--- validateFlush's `husbandriesRequired`), so there is deliberately no separate enabled check:
--- on a disabled draft all three are false, no axis can fire, and the answer is nil.
---
--- ORDER IS CONTRACT: filter, husbandries, destination - validateEdit's own field order. The
--- frame renders these into a DEBUG line that ModTest pins as an ordered sequence, so an
--- unordered result would make that pin nondeterministic rather than merely ugly.
---
--- Fails SAFE on garbage: nil, a non-table, or a table that is not a flush breakdown answers
--- nil (no demote). A demote WRITES `enabled = false` onto a real rule, so guessing from a
--- malformed input is the one failure mode worth spending a key check to avoid.
---@param g table|nil a RLHerdsmanRulePresenter.validateFlush breakdown
---@return table|nil axes array of "filter" | "husbandries" | "destination" in that order, or nil
function RLHerdsmanRulePresenter.enableDemotionAxes(g)
    if type(g) ~= "table" then
        Log:trace("RLHerdsmanRulePresenter.enableDemotionAxes: nil/non-table breakdown (%s) -> no demote", type(g))
        return nil
    end

    for _, key in ipairs(DEMOTION_BREAKDOWN_KEYS) do
        if type(g[key]) ~= "boolean" then
            Log:trace("RLHerdsmanRulePresenter.enableDemotionAxes: breakdown missing/non-boolean '%s' -> no demote", key)
            return nil
        end
    end

    if g.ok then
        Log:trace("RLHerdsmanRulePresenter.enableDemotionAxes: draft flushes clean -> no demote")
        return nil
    end

    if not (g.nameOk and g.operationOk and g.paramsOk) then
        Log:trace("RLHerdsmanRulePresenter.enableDemotionAxes: non-enable-gated failure (nameOk=%s operationOk=%s paramsOk=%s) -> no demote",
            tostring(g.nameOk), tostring(g.operationOk), tostring(g.paramsOk))
        return nil
    end

    local axes = {}
    if g.filterRequired and not g.filterOk then axes[#axes + 1] = "filter" end
    if g.husbandriesRequired and not g.husbandriesOk then axes[#axes + 1] = "husbandries" end
    if g.destinationRequired and not g.destinationOk then axes[#axes + 1] = "destination" end

    if #axes == 0 then
        Log:trace("RLHerdsmanRulePresenter.enableDemotionAxes: draft invalid but no required enable-gated axis failed -> no demote")
        return nil
    end

    Log:trace("RLHerdsmanRulePresenter.enableDemotionAxes: demotable on axes=[%s]", table.concat(axes, ","))
    return axes
end

-- =============================================================================
-- Rule factory + name helpers (F7 lifecycle)
-- =============================================================================

--- Build a fresh "New rule" draft for the service create call: a disabled Sell draft (the
--- operation users reach for first), filterId nil (an incomplete draft, valid only with the relaxed floor),
--- zero targets, and Sell's default params. No id / version - the service assigns
--- the id and defaults the version on create. The caller supplies the (immutable) farmId and
--- the collision-free name (computeDefaultRuleName). Plain data in / plain data out.
---@param farmId number the owning farm id
---@param name string the default rule name
---@return table rule a create-ready Sell draft record (no id/version)
function RLHerdsmanRulePresenter.buildNewRule(farmId, name)
    local rule = {
        name              = name,
        operation         = "sell",
        farmId            = farmId,
        enabled           = false,
        filterId          = nil,
        targetHusbandries = {},
        params            = RLHerdsmanRulePresenter.defaultParamsForOperation("sell"),
    }
    Log:trace("RLHerdsmanRulePresenter.buildNewRule: farmId=%s name=%q -> disabled sell draft (no filter, 0 targets)",
        tostring(farmId), tostring(name))
    return rule
end

--- Compute a collision-free default rule name from the live rule names. Pure adaptation of
--- the Settings default-name helper: the i18n base label is PASSED IN (not read from
--- g_i18n). Tracks the MAX trailing "(N)" seen (not the count) so sparse names after deletes
--- never collide; the bare base counts as N=1 (user-visible numbering starts at 2). Returns
--- the bare base when none present, else "<base> (maxN+1)".
---@param existingNames string[]|nil the current rule names on the farm
---@param baseLabel string the localized default-name base
---@return string name a non-colliding default rule name
function RLHerdsmanRulePresenter.computeDefaultRuleName(existingNames, baseLabel)
    local base = baseLabel or ""
    -- "<base> (N)" anchored end-to-end; %W escapes any pattern-special in the base label.
    local pattern = "^" .. base:gsub("(%W)", "%%%1") .. " %((%d+)%)$"
    local maxN = 0
    if existingNames ~= nil then
        for _, name in ipairs(existingNames) do
            local n = name or ""
            if n == base then
                if maxN < 1 then maxN = 1 end
            else
                local capture = n:match(pattern)
                if capture ~= nil then
                    local num = tonumber(capture)
                    if num ~= nil and num > maxN then
                        maxN = num
                    end
                end
            end
        end
    end
    local result = (maxN == 0) and base or string.format("%s (%d)", base, maxN + 1)
    Log:trace("RLHerdsmanRulePresenter.computeDefaultRuleName: base=%q maxN=%d -> %q", tostring(base), maxN, tostring(result))
    return result
end

--- Compute a collision-free duplicate name from a source name + the live rule names. Pure
--- adaptation of the Settings duplicate-name helper: the localized suffix strings are PASSED
--- IN (suffixFirst e.g. " (copy)"; suffixNFmt e.g. " (copy %d)" - the numbered format carries
--- the language's own word order around one %d). The first duplicate gets the bare suffix;
--- subsequent ones the numbered format. Tracks the MAX N (not the count) so sparse copies
--- after deletes never collide; the bare-suffix form counts as N=1. The source's own bare
--- name is NOT a copy and never contributes.
---@param sourceName string the source rule's (merged) name
---@param existingNames string[]|nil the current rule names on the farm
---@param suffixFirst string the localized first-duplicate suffix
---@param suffixNFmt string the localized numbered-duplicate format (carries one %d)
---@return string name a non-colliding duplicate name
function RLHerdsmanRulePresenter.computeDuplicateName(sourceName, existingNames, suffixFirst, suffixNFmt)
    local base = sourceName or ""
    local first = base .. suffixFirst
    -- Escape every Lua-pattern special in literal text so a translator's parens/punctuation
    -- are matched literally; lift the %d placeholder out first (it must stay a (%d+) capture).
    local function escapePattern(s)
        return (s:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1"))
    end
    local placeholder = "\1"
    local templatePat = escapePattern((suffixNFmt:gsub("%%d", placeholder))):gsub(placeholder, "(%%d+)")
    local countPattern = "^" .. escapePattern(base) .. templatePat .. "$"
    local maxN = 0
    if existingNames ~= nil then
        for _, name in ipairs(existingNames) do
            local n = name or ""
            if n == first then
                if maxN < 1 then maxN = 1 end
            else
                local capture = n:match(countPattern)
                if capture ~= nil then
                    local num = tonumber(capture)
                    if num ~= nil and num > maxN then
                        maxN = num
                    end
                end
            end
        end
    end
    local result = (maxN == 0) and first or (base .. suffixNFmt:format(maxN + 1))
    Log:trace("RLHerdsmanRulePresenter.computeDuplicateName: base=%q maxN=%d -> %q", tostring(base), maxN, tostring(result))
    return result
end

Log:debug("RLHerdsmanRulePresenter: loaded (%d operations)", #RLHerdsmanRulePresenter.OPERATION_ORDER)
