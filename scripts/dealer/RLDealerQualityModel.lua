--[[
    RLDealerQualityModel.lua
    Dealer-quality preset model: the three shipped presets (genetics band, price
    markup, per-animal outlier chance) plus the reshape math the dealer
    generation path composes.

    Pure data-in / data-out. The module holds NO state, reads NO setting and
    never touches game globals, GUI, XML or the network - resolving the ACTIVE
    preset from RLSettings belongs to the generation slice, so every entry point
    takes `presetIndex` as a parameter. The one engine dependency is the GIANTS
    `math.clamp` extension (the headless entry installs it through the shared
    engine_api lib, so a missing native fails loud rather than sitting nil).

    The preset ARRAY is a CODE CONSTANT and is APPEND-ONLY: only the chosen
    INDEX is savegame state, so reordering or inserting a preset would silently
    reinterpret every already-saved value. A future fourth preset appends at
    [4]; a retired preset keeps its slot.

    `PRESETS` - and every table `getPreset` hands out - is READ-ONLY shared
    state by documented contract: the LIVE table is returned, with no defensive
    copy (both the dealer-row price path and the reshape loop are hot) and no
    metatable freeze. Callers must never write through the reference.

    A malformed preset is a mis-edited code constant, never runtime data, so the
    table is validated ONCE at load and FAILS LOUD. Runtime INPUT is the
    opposite: a merely out-of-domain value is clamped SILENTLY (an expected
    legacy-save shape), while a structurally invalid one degrades to a
    documented fallback and warns ONCE per log site.
]]

RLDealerQualityModel = {}

local Log = RmLogging.getLogger("RLRM")


-- =============================================================================
-- Constants
-- =============================================================================

-- Genetics domain: ONE home, RLConstants. This module re-exports rather than
-- re-declaring, so the sibling dealer-quality slices have a single name to
-- consume without a second copy of the bounds existing anywhere.
RLDealerQualityModel.GENETICS_MIN  = RLConstants.GENETICS_MIN
RLDealerQualityModel.GENETICS_MAX  = RLConstants.GENETICS_MAX
RLDealerQualityModel.GENETICS_SPAN = RLConstants.GENETICS_SPAN

-- Arbitrage guard: below a markup of 1.00 the dealer's asking price is under
-- what the same animal fetches when sold straight back, so buy-then-sell with
-- zero elapsed time is a deterministic profit loop. This is a TABLE invariant
-- asserted at load, never a runtime clamp - `resolveMarkup` returns the table's
-- value as-is. It stays local to this module: it is a dealer-economy rule, not
-- a genetics-domain fact.
RLDealerQualityModel.MARKUP_FLOOR = 1.00

-- Fallback index for every invalid-index path (the identity preset).
RLDealerQualityModel.DEFAULT_INDEX = 2

-- Array, 1..3 ascending in quality. The INDEX is the persisted setting value,
-- so this array is APPEND-ONLY: never reorder, never insert.
--
-- The band bounds stay LITERAL here on purpose: this table is the locked-numbers
-- artifact and the tripwire test pins these exact values, so they must read
-- plainly. `assertPresetTable` is what checks them against RLConstants at load.
RLDealerQualityModel.PRESETS = {
    [1] = { key = "budget",   lo = 0.25, hi = 1.00, markup = 1.01,  outlierChance = 0.075 },
    [2] = { key = "standard", lo = 0.25, hi = 1.75, markup = 1.075, outlierChance = 0.075 },
    [3] = { key = "premium",  lo = 1.15, hi = 1.75, markup = 1.30,  outlierChance = 0.075 },
}
-- [2].outlierChance is UNREACHABLE through `reshapeGenetics` (the identity
-- short-circuit returns before the flip) and is pinned anyway, so the three rows
-- stay structurally uniform and the shape check has no special case. Standard
-- outliers are not a feature; they are a can't-happen.

-- DERIVED, and declared AFTER PRESETS because it reads it: the count cannot
-- drift from the table it describes.
RLDealerQualityModel.PRESET_COUNT = #RLDealerQualityModel.PRESETS


-- Hot-path locals. The reshape loop and the dealer-row price path both reach
-- these on every call.
local MIN  = RLDealerQualityModel.GENETICS_MIN
local MAX  = RLDealerQualityModel.GENETICS_MAX
local SPAN = RLDealerQualityModel.GENETICS_SPAN


-- =============================================================================
-- One-shot warning latches
-- =============================================================================
-- ONE per-map-load boolean PER LOG SITE, never one shared latch: a fired
-- warning must not silence a different diagnostic. Each site below owns exactly
-- one of these. Lifetime is the MAP LOAD, not the process: FS25 re-sources every
-- mod file on each map load, so these module-scope locals reset to false then.

--- Invalid `rolled` reached `applyBand` while the band was usable.
local _warnedInvalidRolledBanded = false

--- Invalid `rolled` reached `applyBand` with no usable band to fall back on.
local _warnedInvalidRolledUnbanded = false

--- A usable `rolled` reached `applyBand` behind an unusable band.
local _warnedUnusableBand = false

--- An index that addresses no shipped preset reached `getPreset`. This is the
--- module's SOLE invalid-index warn site; the public wrappers that delegate
--- here add no warning of their own, so a composed call warns exactly once.
local _warnedInvalidIndex = false

--- Non-table `genetics` reached `reshapeGenetics`.
local _warnedInvalidGenetics = false


-- =============================================================================
-- Internal helpers
-- =============================================================================

--- True for a number that is neither NaN nor an infinity. `type()` alone cannot
--- detect either (`type(0/0)` is `"number"`), so both guards are explicit:
--- `v ~= v` catches NaN, the two comparisons catch the infinities.
---@param v any
---@return boolean isReal
local function isRealNumber(v)
    return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end


--- Log the offending preset and abort the load. Called only from
--- `assertPresetTable`, which runs at module load with a code constant.
---@param index any Preset index that failed
---@param message string What the violation was
---@param value any The offending value (for the message)
local function failPreset(index, message, value)
    Log:error("RLDealerQualityModel.assertPresetTable: preset [%s] %s (got: %s)",
        tostring(index), message, tostring(value))
    error(string.format("RLDealerQualityModel: invalid preset [%s] - %s (got: %s)",
        tostring(index), message, tostring(value)), 2)
end


-- =============================================================================
-- Preset table validation (fail loud at load)
-- =============================================================================

--- Validate a preset table, erroring LOUDLY on the first violation.
--- Called once at module load with `PRESETS`, immediately before the
--- load-confirmation line, so that line only ever prints a table that passed.
--- Public so a suite can exercise the REAL validator under `pcall` rather than
--- a re-implementation of it.
---
--- A band outside the genetics domain can only come from someone mis-editing
--- `PRESETS`: it is a CODE bug, never runtime data, so the loud once-per-process
--- failure is the honest response. It deliberately does NOT live in `applyBand`,
--- which runs on the order of a thousand times per dealer repopulate and whose
--- band cannot change between calls. The consequence that matters to callers is
--- that `applyBand`'s published `number in [lo, hi]` return is TRUE for every
--- band this module can hand out - the precondition is enforced, not assumed.
---@param presets table Array of preset rows to validate
function RLDealerQualityModel.assertPresetTable(presets)
    if type(presets) ~= "table" then
        failPreset("?", "preset table is not a table", type(presets))
    end

    -- Count and key-check through pairs, NOT `#presets`. `#` reports the array
    -- part only, so a table with a hole or an out-of-array key would carry rows
    -- that `isValidIndex` / `getPreset` still reach - reachable but unvalidated,
    -- which is exactly what this gate exists to prevent. A mis-edited PRESETS is
    -- the only way to get here, so every violation fails the load loudly.
    local count = 0

    for key in pairs(presets) do
        if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
            failPreset(tostring(key), "preset key is not a positive integer", key)
        end

        count = count + 1
    end

    if count < 1 then
        failPreset("?", "preset table is empty", count)
    end

    -- Contiguity: with keys 1..count all present, `#presets` is trustworthy and
    -- the row loop below reaches every row the lookups can reach.
    for index = 1, count do
        if presets[index] == nil then
            failPreset(index, "preset table has a hole - keys must be contiguous 1..N", "nil")
        end
    end

    for index = 1, count do
        local preset = presets[index]

        if type(preset) ~= "table" then
            failPreset(index, "preset row is not a table", type(preset))
        end

        if type(preset.key) ~= "string" or preset.key == "" then
            failPreset(index, "key must be a non-empty string", preset.key)
        end

        for _, member in ipairs({ "lo", "hi", "markup", "outlierChance" }) do
            if not isRealNumber(preset[member]) then
                failPreset(index, member .. " must be a finite number", preset[member])
            end
        end

        if preset.lo < MIN then
            failPreset(index, "lo is below GENETICS_MIN", preset.lo)
        end

        if preset.hi > MAX then
            failPreset(index, "hi is above GENETICS_MAX", preset.hi)
        end

        if preset.hi < preset.lo then
            failPreset(index, "hi is below lo", preset.hi)
        end

        if preset.markup < RLDealerQualityModel.MARKUP_FLOOR then
            failPreset(index, "markup is below MARKUP_FLOOR", preset.markup)
        end

        if preset.outlierChance < 0 or preset.outlierChance > 1 then
            failPreset(index, "outlierChance is outside [0, 1]", preset.outlierChance)
        end
    end
end


-- =============================================================================
-- Preset lookup
-- =============================================================================

--- True when `presetIndex` addresses a shipped preset. `2.0` is true (Lua reads
--- `PRESETS[2.0]` as `PRESETS[2]`); `2.5` is false, and so is every non-number.
---@param presetIndex any
---@return boolean isValid
function RLDealerQualityModel.isValidIndex(presetIndex)
    return type(presetIndex) == "number" and RLDealerQualityModel.PRESETS[presetIndex] ~= nil
end


--- Resolve a preset index to its LIVE preset row - never nil. An index that
--- addresses no preset degrades to `DEFAULT_INDEX` and warns once per process.
--- The returned table is READ-ONLY by contract; do not write through it.
---@param presetIndex any Index of the wanted preset
---@return table preset The preset row (`key`/`lo`/`hi`/`markup`/`outlierChance`)
function RLDealerQualityModel.getPreset(presetIndex)
    if RLDealerQualityModel.isValidIndex(presetIndex) then
        return RLDealerQualityModel.PRESETS[presetIndex]
    end

    if not _warnedInvalidIndex then
        Log:warning("RLDealerQualityModel.getPreset: index %s addresses no preset - falling back to [%d] (%s)",
            tostring(presetIndex), RLDealerQualityModel.DEFAULT_INDEX,
            RLDealerQualityModel.PRESETS[RLDealerQualityModel.DEFAULT_INDEX].key)
        _warnedInvalidIndex = true
    end

    return RLDealerQualityModel.PRESETS[RLDealerQualityModel.DEFAULT_INDEX]
end


-- =============================================================================
-- Reshape math
-- =============================================================================

--- Remap one genetics value from the full domain onto `[lo, hi]`.
---
--- The identity short-circuit (`lo == GENETICS_MIN and hi == GENETICS_MAX`) is
--- load-bearing, not an optimization: the generic path would compute
--- `MIN + ((x - MIN) / SPAN) * SPAN`, and in IEEE-754 doubles that is not
--- exactly `x` for every `x`, so the bit-for-bit identity claim would fail on
--- some inputs and fail nondeterministically across the value space. It keys on
--- the BAND, not on the preset index, so any future full-range preset inherits
--- the zero-arithmetic path automatically.
---
--- This leaf logs nothing but its own one-shot input warnings: a full repopulate
--- calls it hundreds to thousands of times. The per-trait TRACE line lives in
--- `reshapeGenetics`.
---@param rolled any The raw genetics value (runtime data; may be malformed)
---@param lo any Band floor
---@param hi any Band ceiling
---@return number banded Value inside `[lo, hi]` for any band this module ships
function RLDealerQualityModel.applyBand(rolled, lo, hi)
    -- Guard FIRST: math.clamp would error on nil, and NaN/inf survive a type()
    -- check. There is deliberately NO per-call domain check on the band itself -
    -- that is a TABLE invariant, asserted once at load.
    local bandUsable = isRealNumber(lo) and isRealNumber(hi) and hi >= lo

    if not isRealNumber(rolled) then
        if bandUsable then
            if not _warnedInvalidRolledBanded then
                Log:warning("RLDealerQualityModel.applyBand: invalid genetics value (%s) - returning the band floor %.2f",
                    tostring(rolled), lo)
                _warnedInvalidRolledBanded = true
            end
            -- Band-consistent floor, NOT the domain minimum: handing the worst
            -- genetics in the domain to a premium animal is the defect this closes.
            return lo
        end

        if not _warnedInvalidRolledUnbanded then
            Log:warning("RLDealerQualityModel.applyBand: invalid genetics value (%s) and unusable band (%s, %s) - returning GENETICS_MIN",
                tostring(rolled), tostring(lo), tostring(hi))
            _warnedInvalidRolledUnbanded = true
        end

        return MIN
    end

    if not bandUsable then
        if not _warnedUnusableBand then
            Log:warning("RLDealerQualityModel.applyBand: unusable band (%s, %s) - returning the domain-clamped value",
                tostring(lo), tostring(hi))
            _warnedUnusableBand = true
        end

        return math.clamp(rolled, MIN, MAX)
    end

    -- Domain guard; in production `r == rolled`, and clamping an in-range value
    -- is exact, so the identity path below stays bit-for-bit.
    local r = math.clamp(rolled, MIN, MAX)

    if lo == MIN and hi == MAX then
        return r
    end

    local fraction = (r - MIN) / SPAN       -- position in the full range, 0..1

    return math.clamp(lo + fraction * (hi - lo), MIN, MAX)
end


--- The preset's price markup. Deliberately SILENT at every level: this sits
--- behind the dealer item's price getter, which every dealer-screen row calls on
--- every refresh. An index that addresses no preset warns once from `getPreset`
--- and resolves to the default markup, so the price path can never crash or
--- return nil.
---@param presetIndex any Index of the active preset
---@return number markup Multiplier, `>= MARKUP_FLOOR` by table invariant
function RLDealerQualityModel.resolveMarkup(presetIndex)
    return RLDealerQualityModel.getPreset(presetIndex).markup
end


--- Flip the per-ANIMAL outlier coin for a preset. A fired flip means the animal
--- skips the band entirely and keeps its raw base roll - direction-agnostic, so
--- a premium outlier keeps a possibly-poor roll and a budget outlier keeps a
--- possibly-excellent one. Both are intended.
---
--- Note the zero-draw guarantee belongs to `reshapeGenetics`, not here: this
--- function DOES draw for every preset, the identity one included.
---@param presetIndex any Index of the active preset
---@param rng function|nil Zero-arg RNG returning a float in `[0, 1)`. TRUSTED
---       INTERNAL TEST SEAM - deliberately NOT validated; defaults to `math.random`.
---@return boolean fired True when this animal is an outlier
function RLDealerQualityModel.rollOutlier(presetIndex, rng)
    local preset = RLDealerQualityModel.getPreset(presetIndex)
    rng = rng or math.random

    return rng() < preset.outlierChance
end


--- Reshape one animal's genetics table under a preset. THE composed entry point,
--- and the single home for two invariants that must not be duplicated:
--- (a) the outlier coin flip is per ANIMAL, evaluated ONCE before the trait loop
---     (a per-iteration flip would make the result depend on trait-iteration
---     order and would break "one flip per animal");
--- (b) the identity preset returns before any rng draw, so it perturbs neither
---     the values nor the RNG stream.
---
--- Non-mutating: the input table is never written, and a NEW table is returned
--- under every preset. The copy is SHALLOW - genetics tables are a flat map of
--- scalar members, which is the contract this module assumes.
---@param genetics any The animal's genetics table (runtime data; may be malformed)
---@param presetIndex any Index of the active preset
---@param rng function|nil Zero-arg RNG returning a float in `[0, 1)`. TRUSTED
---       INTERNAL TEST SEAM - deliberately NOT validated; defaults to `math.random`.
---@return table|nil newGenetics A new table, or nil when `genetics` was not a table
---@return boolean wasOutlier True when the animal skipped the band
function RLDealerQualityModel.reshapeGenetics(genetics, presetIndex, rng)
    -- FIRST, before the flip: the invalid path must consume zero rng draws.
    if type(genetics) ~= "table" then
        if not _warnedInvalidGenetics then
            Log:warning("RLDealerQualityModel.reshapeGenetics: genetics is %s, not a table - returning nil so the caller keeps its own",
                type(genetics))
            _warnedInvalidGenetics = true
        end

        return nil, false
    end

    local preset = RLDealerQualityModel.getPreset(presetIndex)
    local lo, hi = preset.lo, preset.hi
    local result = {}

    -- Identity preset: a PLAIN COPY, never routed through `applyBand` (routing
    -- it would clamp out-of-domain legacy values and break the bit-for-bit
    -- claim), and no rng draw at all.
    if lo == MIN and hi == MAX then
        for key, value in pairs(genetics) do
            result[key] = value
        end

        Log:trace("RLDealerQualityModel.reshapeGenetics: preset '%s' is the identity band - copied unchanged, no rng draw",
            preset.key)

        return result, false
    end

    if RLDealerQualityModel.rollOutlier(presetIndex, rng) then
        for key, value in pairs(genetics) do
            result[key] = value
        end

        Log:debug("RLDealerQualityModel.reshapeGenetics: outlier animal under preset '%s' - band skipped, raw roll kept",
            preset.key)

        return result, true
    end

    for key, value in pairs(genetics) do
        if type(value) == "number" then
            local banded = RLDealerQualityModel.applyBand(value, lo, hi)
            Log:trace("RLDealerQualityModel.reshapeGenetics: %s %s -> %s (band [%.2f, %.2f])",
                tostring(key), tostring(value), tostring(banded), lo, hi)
            result[key] = banded
        else
            -- A corrupt member surfaces through the genetics display, not here:
            -- a WARNING would fire per animal on a corrupt save and drown the log.
            Log:trace("RLDealerQualityModel.reshapeGenetics: %s is %s, not a number - copied verbatim",
                tostring(key), type(value))
            result[key] = value
        end
    end

    return result, false
end


-- =============================================================================
-- Load-time gate
-- =============================================================================
-- The validation call comes FIRST and the confirmation line SECOND, so the
-- confirmation can never print for a table that failed.

RLDealerQualityModel.assertPresetTable(RLDealerQualityModel.PRESETS)

local loadedRows = {}

for index = 1, RLDealerQualityModel.PRESET_COUNT do
    local preset = RLDealerQualityModel.PRESETS[index]
    loadedRows[#loadedRows + 1] = string.format("[%d] %s band=[%.2f, %.2f] markup=%.3f outlier=%.3f",
        index, preset.key, preset.lo, preset.hi, preset.markup, preset.outlierChance)
end

Log:debug("RLDealerQualityModel loaded - %d presets: %s",
    RLDealerQualityModel.PRESET_COUNT, table.concat(loadedRows, "; "))
