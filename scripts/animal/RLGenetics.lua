--[[
    RLGenetics.lua
    The one home for genetics BANDING: the two tier ladders, the single-value
    domain predicate, and the guarded domain entries that sit on top of them.

    Engine-free and deterministic in what it returns: no g_* access, no GUI, no
    XML, no engine natives. RmLogging and RLConstants at file scope are the only
    couplings, so the module dual-runs headless.

    It is NOT side-effect-free, and calling it "pure" without that qualifier is
    wrong: three module-scope warn latches are its mutable state, and the
    failure path logs.

    Two layers, deliberately separated:

      resolve()   the raw ladder primitive - any number against any ladder, no
                  domain opinion, and it RAISES on a nil or non-number value. A
                  caller whose value is not a genetics trait uses this directly.

      perTrait() / fertility() / overall()
                  the DOMAIN entries. Each guards its input, NEVER raises, and
                  falls back to its ladder's lowest band with one latched
                  warning.

    KEYS arrays hold FULL localisation keys, and there is always exactly one
    more key than there are thresholds - the extra key is the fall-through band
    for values below the last rung.
]]

RLGenetics = {}

local Log = RmLogging.getLogger("RLRM")


-- Genetics domain, read from the mod's one constants home rather than restated
-- as literals here, so this module follows a bounds change instead of silently
-- disagreeing with RLGeneticsDraw and RLDealerQualityModel.
RLGenetics.MIN = RLConstants.GENETICS_MIN
RLGenetics.MAX = RLConstants.GENETICS_MAX

-- The one value outside [MIN, MAX] that is legitimate rather than corrupt, and
-- only for fertility: a castrated male, a freemartin heifer or an animal bred
-- sterile stores exactly 0. Every other trait treats 0 as corrupt.
RLGenetics.INFERTILE_VALUE = 0


-- Per-trait ladder: metabolism, health, fertility, meat quality, productivity.
-- Ordered highest-first, so a linear scan stops at the first rung the value
-- meets.
--
-- READ-ONLY by contract. RLGeneticsFormatter re-exports these very tables (same
-- objects, no copy), so mutating one mutates every consumer. There is
-- deliberately no defensive copy and no metatable freeze - both sit on the row-
-- render path, and the contract is upheld by review.
RLGenetics.PER_TRAIT_THRESHOLDS = { 1.65, 1.4, 1.1, 0.9, 0.7, 0.35 }

RLGenetics.PER_TRAIT_KEYS = {
    "rl_ui_genetics_extremelyHigh",
    "rl_ui_genetics_veryHigh",
    "rl_ui_genetics_high",
    "rl_ui_genetics_average",
    "rl_ui_genetics_low",
    "rl_ui_genetics_veryLow",
    "rl_ui_genetics_extremelyLow",
}

-- Aggregate ladder for the Overall row. Same shape, different vocabulary
-- (good/bad rather than high/low) and a different scale: its input is a
-- normalised FACTOR, not a trait value, so the two ladders are never
-- interchangeable.
--
-- READ-ONLY by contract - see PER_TRAIT_THRESHOLDS.
RLGenetics.OVERALL_THRESHOLDS = { 0.95, 0.8, 0.6, 0.4, 0.2, 0.05 }

RLGenetics.OVERALL_KEYS = {
    "rl_ui_genetics_extremelyGood",
    "rl_ui_genetics_veryGood",
    "rl_ui_genetics_good",
    "rl_ui_genetics_average",
    "rl_ui_genetics_bad",
    "rl_ui_genetics_veryBad",
    "rl_ui_genetics_extremelyBad",
}

-- Fertility's extra band, outside both ladders.
RLGenetics.INFERTILE_KEY = "rl_ui_genetics_infertile"


-- The fall-through band of each ladder, resolved once. Both domain entries use
-- their ladder's lowest key as the guarded fallback, so a corrupt value reads
-- as the worst band rather than as a plausible middling one.
local LOWEST_PER_TRAIT = RLGenetics.PER_TRAIT_KEYS[#RLGenetics.PER_TRAIT_KEYS]
local LOWEST_OVERALL   = RLGenetics.OVERALL_KEYS[#RLGenetics.OVERALL_KEYS]


-- One latch per domain entry: the first corrupt value each entry meets is
-- reported, the rest are silent. Banding runs several times per rendered row,
-- so an unlatched warning would flood the log from a single bad animal.
--
-- Module scope, NOT an `RLGenetics = RLGenetics or {}` idiom: main.lua re-sources
-- per map load, so these reset when a save is loaded. Accepted cost - on a
-- long-running dedicated server only the first corrupt animal per entry is
-- reported.
local warnedPerTrait = false
local warnedFertility = false
local warnedOverall = false


-- What each entry actually accepts, in the entry's own terms. These are NOT
-- interchangeable: `overall` bands a normalised FACTOR and deliberately does
-- not apply the trait domain, so quoting [MIN, MAX] in its warning would send a
-- maintainer to the wrong rule for a legal factor like 0.19.
local EXPECTED_PER_TRAIT = string.format("a trait value in [%s, %s], or exactly %s (infertile)",
    tostring(RLGenetics.MIN), tostring(RLGenetics.MAX), tostring(RLGenetics.INFERTILE_VALUE))
local EXPECTED_FERTILITY = EXPECTED_PER_TRAIT
local EXPECTED_OVERALL = "a finite number (an aggregate factor is open-ended, NOT clamped to the trait domain)"


--- Emit one latched warning describing a rejected value.
---
--- Formats with `%s` + `tostring` throughout, never `%d`/`%f`: the offending
--- value can be a string, a boolean or a table, and the headless harness calls
--- `string.format` BARE (the in-game logger pcalls it), so a numeric verb would
--- raise headless only - breaking dual-run parity and the never-raises contract
--- at the same time.
--- @param entry string Name of the domain entry, for the log line
--- @param value any The rejected value
--- @param fallbackKey string The key being returned instead
--- @param expectation string What this entry accepts, phrased for this entry
local function warnRejected(entry, value, fallbackKey, expectation)
    Log:warning(
        "RLGenetics.%s: rejected value %s (type %s) - banding as %s. Expected %s. Further occurrences from this entry are silent until the next map load.",
        entry, tostring(value), type(value), tostring(fallbackKey), expectation)
end


--- Is this a value a well-formed save can hold for a genetics trait?
---
--- The allowlist needs no special cases: one `type` test plus one range test
--- already rejects NaN (every comparison against it is false), both infinities,
--- and every out-of-range finite number. The `type` test is mandatory AND first
--- - `"x" >= 0.25` raises.
---
--- `nil` is VALID: an absent trait is a normal load path, not corruption (a pig
--- carries no productivity). Callers that need "absent" and "present" to differ
--- must test for nil themselves.
---
--- @param value any The value to check; `nil` counts as valid (absent)
--- @param traitKey string|nil Trait name. `nil` means the trait-agnostic UNION,
---        which admits the infertile 0 because the caller cannot tell a legal
---        infertile fertility from a corrupt quality. Only `"fertility"` or
---        `nil` unlock 0; any other key rejects it.
--- @return boolean isValid
function RLGenetics.isValidTraitValue(value, traitKey)
    if value == nil then return true end
    if type(value) ~= "number" then return false end

    if value >= RLGenetics.MIN and value <= RLGenetics.MAX then return true end

    -- The infertile carve-out is the only value admitted from outside the
    -- domain. `-0.0 == 0` in Lua, so a negative zero passes here too.
    return value == RLGenetics.INFERTILE_VALUE
        and (traitKey == nil or traitKey == "fertility")
end


--- Pick a band key by scanning a threshold ladder highest-first.
---
--- STRICT AND UNGUARDED, deliberately: this is the raw primitive, and it RAISES
--- on a nil or non-number value rather than inventing a band for it. The domain
--- entries below are what a genetics caller should reach for; use this directly
--- only for a value that is not a genetics trait.
---
--- @param value number Compared with `>=`, so a value sitting exactly on a rung
---        takes that rung's key
--- @param thresholds table Rungs, highest first. TRUSTED INTERNAL input - not
---        validated; a nil or non-table raises inside `ipairs`
--- @param keys table Band keys, same order, exactly one longer than
---        `thresholds`. A mismatched length silently collapses or skips a band
--- @return string|nil key The band key, or the last key when the value is below
---         every rung. NIL when `keys` cannot supply one - an empty list, or a
---         list too short for the matched rung - which flows on as a nil
---         localisation key rather than raising
function RLGenetics.resolve(value, thresholds, keys)
    for i, threshold in ipairs(thresholds) do
        if value >= threshold then return keys[i] end
    end

    return keys[#keys]
end


--- Band any single genetics trait value against the per-trait ladder.
---
--- Trait-AGNOSTIC by signature: it receives a bare number and cannot tell which
--- trait it belongs to, so it validates against the UNION and accepts the
--- infertile 0 silently. Do NOT tighten this to [MIN, MAX] - generic loops feed
--- it `animal.genetics` wholesale, so every castrated male and freemartin
--- heifer would warn on every render.
---
--- @param value number|nil Trait value; `nil` is treated as absent
--- @return string key Never nil, never raises
function RLGenetics.perTrait(value)
    -- Absent is normal, so it short-circuits BEFORE the allowlist and before
    -- resolve (which would raise on nil) - and it stays silent.
    if value == nil then return LOWEST_PER_TRAIT end

    if not RLGenetics.isValidTraitValue(value, nil) then
        if not warnedPerTrait then
            warnedPerTrait = true
            warnRejected("perTrait", value, LOWEST_PER_TRAIT, EXPECTED_PER_TRAIT)
        end

        return LOWEST_PER_TRAIT
    end

    return RLGenetics.resolve(value, RLGenetics.PER_TRAIT_THRESHOLDS, RLGenetics.PER_TRAIT_KEYS)
end


--- Band a fertility value, honouring the infertile band at exactly 0.
---
--- Guard order is the contract. `nil` short-circuits FIRST and yields the
--- lowest band, NOT infertile: coalescing to 0 before the exactly-0 test would
--- report every animal with no fertility recorded as sterile. Validation then
--- runs BEFORE the infertile test, so the allowlist stays symmetric with
--- `perTrait` and a negative value is rejected instead of being read as
--- sterile.
---
--- @param value number|nil Fertility value; `nil` is treated as absent
--- @return string key Never nil, never raises
function RLGenetics.fertility(value)
    if value == nil then return LOWEST_PER_TRAIT end

    if not RLGenetics.isValidTraitValue(value, "fertility") then
        if not warnedFertility then
            warnedFertility = true
            warnRejected("fertility", value, LOWEST_PER_TRAIT, EXPECTED_FERTILITY)
        end

        return LOWEST_PER_TRAIT
    end

    if value == RLGenetics.INFERTILE_VALUE then return RLGenetics.INFERTILE_KEY end

    return RLGenetics.resolve(value, RLGenetics.PER_TRAIT_THRESHOLDS, RLGenetics.PER_TRAIT_KEYS)
end


--- Band an aggregate genetics FACTOR against the overall ladder.
---
--- Takes a normalised factor, not a trait value, so it cannot reuse the trait
--- allowlist: 0.19 and 0.04 are perfectly legal factors and invalid trait
--- values, and a shared predicate would make the ladder's own just-below
--- fixtures self-trip. Its guard is therefore finite-number-only.
---
--- Banding is OPEN-ENDED and never clamps: a factor above 1 bands as the top
--- key and a negative factor as the bottom one, silently. Unlike an absent
--- trait, an absent FACTOR is a caller bug, so `nil` warns here.
---
--- @param factor number|nil Aggregate factor, typically `sum / (MAX * statCount)`
--- @return string key Never nil, never raises
function RLGenetics.overall(factor)
    -- `factor ~= factor` is the NaN test; the two explicit infinity tests are
    -- needed because both infinities compare normally against the rungs and
    -- would otherwise band as a real value.
    if type(factor) ~= "number"
        or factor ~= factor
        or factor == math.huge
        or factor == -math.huge then

        if not warnedOverall then
            warnedOverall = true
            warnRejected("overall", factor, LOWEST_OVERALL, EXPECTED_OVERALL)
        end

        return LOWEST_OVERALL
    end

    return RLGenetics.resolve(factor, RLGenetics.OVERALL_THRESHOLDS, RLGenetics.OVERALL_KEYS)
end


--- Clear all three warn latches so the next corrupt value is reported again.
---
--- TEST SEAM. Production never calls it: the latches are meant to survive a
--- session and are reset by the per-map-load re-source. It exists so a suite
--- can exercise a rejection path without leaving the latches spent for whatever
--- runs next.
--- @return nil
function RLGenetics._resetWarnLatches()
    warnedPerTrait = false
    warnedFertility = false
    warnedOverall = false
end


Log:info("RLGenetics loaded")
