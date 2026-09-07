--[[
    RLGeneticsFormatter.lua
    Pure genetics display formatter for the detail pane. Converts Animal genetics + type
    into display-ready rows { labelKey, valueKey, colorKey, numericValue }.

    Banding is NOT owned here: RLGenetics owns both ladders and the domain entries, and this
    module re-exports its constants and forwards its resolvers, so every consumer bands
    identically by construction. REMAINING DUPLICATE: Animal:addGeneticsInfo still carries
    its own copy of these numbers, outside the locked-numbers tripwire in RLGeneticsTests,
    so the two can drift silently.

    Engine-free - no g_*, no GUI - but NOT side-effect-free: the fertility resolver forwards
    into RLGenetics, which logs and flips a warn latch on a rejected value.
]]

local Log = RmLogging and RmLogging.getLogger and RmLogging.getLogger("RLRM") or nil

RLGeneticsFormatter = {}

-- =============================================================================
-- Tier label keys (localization keys resolved by the frame, not here)
-- =============================================================================

-- All five constants below are RE-EXPORTS - the SAME OBJECTS as RLGenetics', not copies.
-- They are therefore READ-ONLY by contract (mutating one here mutates every consumer of
-- RLGenetics, mod-wide), and binding them at file scope pins this module AFTER RLGenetics
-- in main.lua's source order.

--- Keys for the stat rows that lean "high = good", ordered highest-first.
--- @see RLGenetics.PER_TRAIT_KEYS
RLGeneticsFormatter.HIGH_TIER_KEYS = RLGenetics.PER_TRAIT_KEYS

--- Thresholds for the HIGH_TIER_KEYS ladder; values below the last one fall through.
--- @see RLGenetics.PER_TRAIT_THRESHOLDS
RLGeneticsFormatter.HIGH_TIER_THRESHOLDS = RLGenetics.PER_TRAIT_THRESHOLDS

--- Keys for the Overall row, which uses a separate "good/bad" vocabulary.
--- @see RLGenetics.OVERALL_KEYS
RLGeneticsFormatter.OVERALL_TIER_KEYS = RLGenetics.OVERALL_KEYS

--- Thresholds for OVERALL_TIER_KEYS, scaled for a normalised aggregate FACTOR rather than
--- a raw trait value, so they are never interchangeable with HIGH_TIER_THRESHOLDS.
--- @see RLGenetics.OVERALL_THRESHOLDS
RLGeneticsFormatter.OVERALL_TIER_THRESHOLDS = RLGenetics.OVERALL_THRESHOLDS

--- Fertility has a special "infertile" tier at value == 0.
--- @see RLGenetics.INFERTILE_KEY
RLGeneticsFormatter.FERTILITY_INFERTILE_KEY = RLGenetics.INFERTILE_KEY

-- =============================================================================
-- Color keys (consumed by frame; frame maps key -> RGBA tuple for setTextColor)
-- =============================================================================

--- Color keys grouped by tier. Returned from format() as row.colorKey.
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

--- Pick a tier key from a value against a thresholds+keys ladder.
---
--- Thin forwarder to the shared primitive, which is STRICT: it raises on a nil or
--- non-number value rather than inventing a band.
--- @param value number
--- @param thresholds table list of thresholds, highest first
--- @param keys table list of tier keys, same order as thresholds + 1
--- @return string key
--- @see RLGenetics.resolve
function RLGeneticsFormatter.resolveTier(value, thresholds, keys)
    return RLGenetics.resolve(value, thresholds, keys)
end

--- Resolve a fertility value to its tier key, honoring "infertile" at value == 0.
---
--- Thin forwarder to the shared domain entry, which guards its input and never raises. A
--- nil fertility bands as the LOWEST tier there, not as infertile.
--- @param fertility number|nil
--- @return string key
--- @see RLGenetics.fertility
function RLGeneticsFormatter.resolveFertilityTier(fertility)
    return RLGenetics.fertility(fertility)
end

-- =============================================================================
-- Numeric value (0-99)
-- =============================================================================

--- Convert a raw 0.25..1.75 genetics value into the same 0-99 integer the in-game animal
--- name tag uses. Returns nil when RLScaleHelper is missing, which the caller renders as
--- label-only; the missing-helper warning is emitted once per format() pass, not per row.
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

--- Return the productivity row label key for an animal type, or nil when the type has none.
---
--- The label names a SPECIES-level breeding trait, not the individual's current output: a
--- COW returns rl_ui_milk for every subtype and gender, and a goat (SHEEP subtype GOAT or
--- RAM_GOAT) likewise returns rl_ui_milk. Every other SHEEP subtype, nil and "" included,
--- returns rl_ui_wool.
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

--- Format an animal's genetics into display-ready rows: Overall, Metabolism, Health,
--- Fertility, Meat, and an optional species-dependent Productivity row.
---
--- The productivity row is gated by animal TYPE, not gender or subtype, so a bull gets it
--- too (a bull is AnimalType.COW). Pigs and horses have no productivity label and get 5
--- rows; the rest get 6 when the animal carries a productivity value. Pure function.
--- @param genetics table|nil
--- @param animalTypeIndex number|nil
--- @param subTypeName string|nil optional; distinguishes goats within SHEEP for the productivity-row label (see getProductivityLabelKey). A nil/absent value keeps the SHEEP -> wool default.
--- @return table rows
function RLGeneticsFormatter.format(genetics, animalTypeIndex, subTypeName)
    if genetics == nil then return {} end

    -- An all-nil-stats table is no data, not five "Extremely Low" rows: zero-init genetics
    -- reach here from fresh imports and pallet animals.
    if genetics.metabolism == nil
        and genetics.health == nil
        and genetics.fertility == nil
        and genetics.quality == nil
        and genetics.productivity == nil then
        return {}
    end

    -- Once per pass, so a load-order regression cannot silently downgrade every row.
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
    -- The overall numeric uses the stat AVERAGE so it matches the in-game name tag's
    -- [NN-...] figure in AnimalScreenBase.
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
