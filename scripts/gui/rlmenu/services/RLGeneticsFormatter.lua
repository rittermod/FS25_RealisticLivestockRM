--[[
    RLGeneticsFormatter.lua
    Pure genetics display formatter for the RL Tabbed Menu detail pane.

    Converts Animal genetics + type into a list of display-ready rows:
      { { labelKey, valueKey, colorKey, numericValue }, ... }

    Banding is NOT owned here. RLGenetics owns both ladders and the domain
    entries; this module re-exports its constants and forwards its resolvers, so
    every consumer of RLGenetics bands identically by construction.

    REMAINING DUPLICATE: Animal:addGeneticsInfo still carries its own copy of
    these numbers and is deliberately not migrated here. It bands identically
    today, so nothing is visibly wrong - but the locked-numbers tripwire in
    RLGeneticsTests does NOT cover it, and the two can drift silently. Do not
    read "one home" as "only home" until that call site moves.

    Engine-free - no g_* access, no GUI calls - and unit-testable without a
    running mission. NOT side-effect-free, though: the fertility resolver
    forwards into RLGenetics, which logs and flips a warn latch on a rejected
    value. The optional numericValue (0-99) is produced by
    RLScaleHelper.scaleToNinetyNine, the same helper that powers the in-game
    animal name tag.
]]

local Log = RmLogging and RmLogging.getLogger and RmLogging.getLogger("RLRM") or nil

RLGeneticsFormatter = {}

-- =============================================================================
-- Tier label keys (localization keys resolved by the frame, not here)
-- =============================================================================

-- All five constants below are RE-EXPORTS: they are the SAME OBJECTS as
-- RLGenetics', not copies. Two consequences a maintainer must not lose:
--   * they are READ-ONLY by contract - mutating one here mutates every consumer
--     of RLGenetics, mod-wide;
--   * binding them at file scope pins this module AFTER RLGenetics in
--     main.lua's source order.
-- The names are kept so existing consumers and tests read unchanged.

--- Keys used by the stat rows that lean "high = good": metabolism, health,
--- fertility, meat quality, productivity. Ordered highest-first so a linear
--- scan stops at the first threshold the value meets.
--- @see RLGenetics.PER_TRAIT_KEYS
RLGeneticsFormatter.HIGH_TIER_KEYS = RLGenetics.PER_TRAIT_KEYS

--- Thresholds for the HIGH_TIER_KEYS ladder, one per key in the same order.
--- Value >= thresholds[i] selects keys[i]; values below the last threshold
--- fall through to "extremelyLow".
--- @see RLGenetics.PER_TRAIT_THRESHOLDS
RLGeneticsFormatter.HIGH_TIER_THRESHOLDS = RLGenetics.PER_TRAIT_THRESHOLDS

--- Keys used by the Overall row, which leans "high = good" but uses a
--- separate "good/bad" vocabulary distinct from the other stats.
--- @see RLGenetics.OVERALL_KEYS
RLGeneticsFormatter.OVERALL_TIER_KEYS = RLGenetics.OVERALL_KEYS

--- Thresholds for the OVERALL_TIER_KEYS ladder. Scaled for a normalised
--- aggregate FACTOR, not a raw trait value, so it is never interchangeable with
--- HIGH_TIER_THRESHOLDS.
--- @see RLGenetics.OVERALL_THRESHOLDS
RLGeneticsFormatter.OVERALL_TIER_THRESHOLDS = RLGenetics.OVERALL_THRESHOLDS

--- Fertility has a special "infertile" tier at value == 0.
--- @see RLGenetics.INFERTILE_KEY
RLGeneticsFormatter.FERTILITY_INFERTILE_KEY = RLGenetics.INFERTILE_KEY

-- =============================================================================
-- Color keys (consumed by frame; frame maps key -> RGBA tuple for setTextColor)
-- =============================================================================

--- Color keys grouped by tier. Returned from format() as row.colorKey.
--- Frame maps color keys to RGBA tuples; no GUI profiles needed.
RLGeneticsFormatter.COLOR_KEY = {
    INFERTILE     = "infertile",     -- red
    EXTREMELY_LOW = "extremelyLow",  -- red
    VERY_LOW      = "veryLow",       -- red-orange
    LOW           = "low",           -- orange
    AVERAGE       = "average",       -- yellow
    HIGH          = "high",          -- yellow-green
    VERY_HIGH     = "veryHigh",      -- green
    EXTREMELY_HIGH = "extremelyHigh",-- bright green
}

--- Map from value-key suffix to display color key.
RLGeneticsFormatter.VALUE_KEY_TO_COLOR_KEY = {
    rl_ui_genetics_infertile      = RLGeneticsFormatter.COLOR_KEY.INFERTILE,
    rl_ui_genetics_extremelyLow   = RLGeneticsFormatter.COLOR_KEY.EXTREMELY_LOW,
    rl_ui_genetics_extremelyBad   = RLGeneticsFormatter.COLOR_KEY.EXTREMELY_LOW,
    rl_ui_genetics_veryLow        = RLGeneticsFormatter.COLOR_KEY.VERY_LOW,
    rl_ui_genetics_veryBad        = RLGeneticsFormatter.COLOR_KEY.VERY_LOW,
    rl_ui_genetics_low            = RLGeneticsFormatter.COLOR_KEY.LOW,
    rl_ui_genetics_bad            = RLGeneticsFormatter.COLOR_KEY.LOW,
    rl_ui_genetics_average        = RLGeneticsFormatter.COLOR_KEY.AVERAGE,
    rl_ui_genetics_high           = RLGeneticsFormatter.COLOR_KEY.HIGH,
    rl_ui_genetics_good           = RLGeneticsFormatter.COLOR_KEY.HIGH,
    rl_ui_genetics_veryHigh       = RLGeneticsFormatter.COLOR_KEY.VERY_HIGH,
    rl_ui_genetics_veryGood       = RLGeneticsFormatter.COLOR_KEY.VERY_HIGH,
    rl_ui_genetics_extremelyHigh  = RLGeneticsFormatter.COLOR_KEY.EXTREMELY_HIGH,
    rl_ui_genetics_extremelyGood  = RLGeneticsFormatter.COLOR_KEY.EXTREMELY_HIGH,
}

-- =============================================================================
-- Tier resolution
-- =============================================================================

--- Pick a tier key from a value against a thresholds+keys ladder. Ladders
--- always have one more key than thresholds; values below the last threshold
--- fall through to the last key.
---
--- Thin forwarder to the shared primitive, which is STRICT: it raises on a nil
--- or non-number value rather than inventing a band.
--- @param value number
--- @param thresholds table list of thresholds, highest first
--- @param keys table list of tier keys, same order as thresholds + 1
--- @return string key
--- @see RLGenetics.resolve
function RLGeneticsFormatter.resolveTier(value, thresholds, keys)
    return RLGenetics.resolve(value, thresholds, keys)
end

--- Resolve a fertility value to its tier key, honoring the special
--- "infertile" case at value == 0.
---
--- Thin forwarder to the shared domain entry, which guards its input and never
--- raises. No local nil coalesce is needed: a nil fertility bands as the lowest
--- tier there too, NOT as infertile.
--- @param fertility number|nil
--- @return string key
--- @see RLGenetics.fertility
function RLGeneticsFormatter.resolveFertilityTier(fertility)
    return RLGenetics.fertility(fertility)
end

-- =============================================================================
-- Numeric value (0-99)
-- =============================================================================

--- Convert a raw 0.25..1.75 genetics value into the same 0-99 integer that
--- the in-game animal name tag uses ([98-94:87:...]). Returns nil when the
--- shared helper is missing (see RLScaleHelper.scaleToNinetyNine in
--- scripts/utils/RLScaleHelper.lua). Caller renders the nil case as
--- "label only" (no number prefix).
---
--- Silent when the helper is missing - the warning is emitted once per
--- format() pass by the caller, not per row, to avoid log spam.
--- @param value number|nil
--- @return integer|nil
function RLGeneticsFormatter.toNumericValue(value)
    if value == nil then return nil end
    if RLScaleHelper == nil or RLScaleHelper.scaleToNinetyNine == nil then
        return nil
    end
    return RLScaleHelper.scaleToNinetyNine(value)
end

-- =============================================================================
-- Productivity label per species
-- =============================================================================

--- Return the productivity row label key for an animal type, or nil when
--- the type has no productivity row.
---
--- The label names a species-level breeding trait, not the individual's
--- current output: a COW returns rl_ui_milk for every subtype and gender, and
--- a goat (SHEEP subtype GOAT or the male RAM_GOAT) likewise returns
--- rl_ui_milk. Every other SHEEP subtype - including nil and "" - returns
--- rl_ui_wool.
--- @param animalTypeIndex number|nil
--- @param subTypeName string|nil optional; distinguishes goats within SHEEP. A nil/absent value keeps the SHEEP -> wool default.
--- @return string|nil labelKey
function RLGeneticsFormatter.getProductivityLabelKey(animalTypeIndex, subTypeName)
    if animalTypeIndex == nil or AnimalType == nil then return nil end
    if animalTypeIndex == AnimalType.COW then return "rl_ui_milk" end
    if animalTypeIndex == AnimalType.SHEEP then
        if subTypeName == "GOAT" or subTypeName == "RAM_GOAT" then return "rl_ui_milk" end
        return "rl_ui_wool"
    end
    if animalTypeIndex == AnimalType.CHICKEN then return "rl_ui_eggs" end
    return nil
end

-- =============================================================================
-- Public entry point
-- =============================================================================

--- Format an animal's genetics into display-ready rows.
---
--- The productivity row is gated by animal TYPE, not by gender or subtype: COW,
--- SHEEP and CHICKEN carry it, so a bull gets it too (a bull is AnimalType.COW).
--- Types with no productivity label - pigs and horses - get 5 rows; the rest get
--- 6, provided the animal actually carries a productivity value. Rows are:
---   [1] Overall     ("good/bad" scale)
---   [2] Metabolism  ("high/low" scale)
---   [3] Health      ("high/low" scale)
---   [4] Fertility   ("high/low" scale, + infertile at 0)
---   [5] Meat        ("high/low" scale)
---   [6] Productivity (optional, species-dependent label Milk/Wool/Eggs)
---
--- Each row is `{ labelKey, valueKey, colorKey, numericValue }`:
---   - labelKey/valueKey are localization keys (frame resolves text)
---   - colorKey maps to an RGBA tuple (frame applies setTextColor)
---   - numericValue is an integer 0..99 (or nil if RLScaleHelper is
---     not loaded). Same scale as the in-game name tag.
---
--- Pure function: no side effects, no GUI, no g_* access. Uses the
--- RLScaleHelper.scaleToNinetyNine helper for the numeric value.
---
--- @param genetics table|nil
--- @param animalTypeIndex number|nil
--- @param subTypeName string|nil optional; distinguishes goats within SHEEP for the productivity-row label (see getProductivityLabelKey). A nil/absent value keeps the SHEEP -> wool default.
--- @return table rows
function RLGeneticsFormatter.format(genetics, animalTypeIndex, subTypeName)
    if genetics == nil then return {} end

    -- An empty / all-nil-stats genetics table is treated as no data.
    -- Avoids rendering five "Extremely Bad / Extremely Low" rows for animals
    -- with a zero-init genetics table (e.g. fresh imports, pallet animals).
    if genetics.metabolism == nil
        and genetics.health == nil
        and genetics.fertility == nil
        and genetics.quality == nil
        and genetics.productivity == nil then
        return {}
    end

    -- Warn once per format() pass if the 0-99 scale helper is missing, so a
    -- load-order regression does not silently downgrade every row to
    -- label-only. toNumericValue() itself stays silent (emitting per row
    -- would spam 5-6 duplicate warnings on every menu refresh).
    if Log ~= nil
        and (RLScaleHelper == nil or RLScaleHelper.scaleToNinetyNine == nil) then
        Log:warning("RLGeneticsFormatter.format: RLScaleHelper.scaleToNinetyNine unavailable, rows will render as label-only (check main.lua load order)")
    end

    local rows = {}

    -- Row 1: Overall. Sums the five stats against 1.75 per best-slot.
    local productivity = genetics.productivity
    local metabolism   = genetics.metabolism or 0
    local quality      = genetics.quality or 0
    local health       = genetics.health or 0
    local fertility    = genetics.fertility or 0
    local hasProductivity = productivity ~= nil
    local statCount = hasProductivity and 5 or 4

    local overallSum = metabolism + quality + health + fertility + (hasProductivity and productivity or 0)
    local overallBest = 1.75 * statCount
    local overallFactor = (overallBest > 0) and (overallSum / overallBest) or 0
    local overallKey = RLGeneticsFormatter.resolveTier(
        overallFactor,
        RLGeneticsFormatter.OVERALL_TIER_THRESHOLDS,
        RLGeneticsFormatter.OVERALL_TIER_KEYS
    )
    -- Overall numeric uses the stat average through scaleToNinetyNine so it
    -- matches the in-game name-tag's [NN-...] overall figure in AnimalScreenBase.
    local overallAvg = (statCount > 0) and (overallSum / statCount) or 0
    table.insert(rows, {
        labelKey     = "rl_ui_overall",
        valueKey     = overallKey,
        colorKey     = RLGeneticsFormatter.VALUE_KEY_TO_COLOR_KEY[overallKey],
        numericValue = RLGeneticsFormatter.toNumericValue(overallAvg),
    })

    -- Row 2: Metabolism
    local metabolismKey = RLGeneticsFormatter.resolveTier(
        metabolism,
        RLGeneticsFormatter.HIGH_TIER_THRESHOLDS,
        RLGeneticsFormatter.HIGH_TIER_KEYS
    )
    table.insert(rows, {
        labelKey     = "rl_ui_metabolism",
        valueKey     = metabolismKey,
        colorKey     = RLGeneticsFormatter.VALUE_KEY_TO_COLOR_KEY[metabolismKey],
        numericValue = RLGeneticsFormatter.toNumericValue(metabolism),
    })

    -- Row 3: Health
    local healthKey = RLGeneticsFormatter.resolveTier(
        health,
        RLGeneticsFormatter.HIGH_TIER_THRESHOLDS,
        RLGeneticsFormatter.HIGH_TIER_KEYS
    )
    table.insert(rows, {
        labelKey     = "rl_ui_health",
        valueKey     = healthKey,
        colorKey     = RLGeneticsFormatter.VALUE_KEY_TO_COLOR_KEY[healthKey],
        numericValue = RLGeneticsFormatter.toNumericValue(health),
    })

    -- Row 4: Fertility (with special infertile case)
    local fertilityKey = RLGeneticsFormatter.resolveFertilityTier(fertility)
    table.insert(rows, {
        labelKey     = "rl_ui_fertility",
        valueKey     = fertilityKey,
        colorKey     = RLGeneticsFormatter.VALUE_KEY_TO_COLOR_KEY[fertilityKey],
        numericValue = RLGeneticsFormatter.toNumericValue(fertility),
    })

    -- Row 5: Meat (quality)
    local meatKey = RLGeneticsFormatter.resolveTier(
        quality,
        RLGeneticsFormatter.HIGH_TIER_THRESHOLDS,
        RLGeneticsFormatter.HIGH_TIER_KEYS
    )
    table.insert(rows, {
        labelKey     = "rl_ui_meat",
        valueKey     = meatKey,
        colorKey     = RLGeneticsFormatter.VALUE_KEY_TO_COLOR_KEY[meatKey],
        numericValue = RLGeneticsFormatter.toNumericValue(quality),
    })

    -- Row 6 (optional): Productivity - species-specific label
    local productivityLabel = RLGeneticsFormatter.getProductivityLabelKey(animalTypeIndex, subTypeName)
    if hasProductivity and productivityLabel ~= nil then
        local productivityKey = RLGeneticsFormatter.resolveTier(
            productivity,
            RLGeneticsFormatter.HIGH_TIER_THRESHOLDS,
            RLGeneticsFormatter.HIGH_TIER_KEYS
        )
        table.insert(rows, {
            labelKey     = productivityLabel,
            valueKey     = productivityKey,
            colorKey     = RLGeneticsFormatter.VALUE_KEY_TO_COLOR_KEY[productivityKey],
            numericValue = RLGeneticsFormatter.toNumericValue(productivity),
        })
    end

    if Log ~= nil then
        for _, row in ipairs(rows) do
            Log:trace("RLGeneticsFormatter.format: row label=%s value=%s color=%s numeric=%s",
                tostring(row.labelKey), tostring(row.valueKey), tostring(row.colorKey), tostring(row.numericValue))
        end
    end

    return rows
end
