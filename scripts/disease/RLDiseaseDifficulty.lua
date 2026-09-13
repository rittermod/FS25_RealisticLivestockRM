--[[
    RLDiseaseDifficulty.lua
    The disease difficulty ladder (Off / Easy / Normal / Hard) and the three scaling helpers
    `DiseaseManager` applies where each quantity enters the model: the infection chance, the
    incubation window and R0.

    Pure data-in / data-out: no setting read, no g_*, no XML. `PRESETS` is append-only and a
    row's array index IS the persisted setting value. Normal is an exact identity. Off keeps
    identity scales, since nothing reads a scale while diseases are off. `RLDiseaseRecord` is
    read at call time only.
]]

RLDiseaseDifficulty = {}

local Log = RmLogging.getLogger("RLRM")

RLDiseaseDifficulty.OFF_INDEX = 1
RLDiseaseDifficulty.DEFAULT_INDEX = 3

RLDiseaseDifficulty.PRESETS = {
    [1] = { key = "off",    enabled = false, infection = 1.0, incubation = 1.0, spread = 1.0 },
    [2] = { key = "easy",   enabled = true,  infection = 0.5, incubation = 0.0, spread = 0.6 },
    [3] = { key = "normal", enabled = true,  infection = 1.0, incubation = 1.0, spread = 1.0 },
    [4] = { key = "hard",   enabled = true,  infection = 2.0, incubation = 2.0, spread = 1.5 }
}

RLDiseaseDifficulty.PRESET_COUNT = #RLDiseaseDifficulty.PRESETS

-- Reset by the module re-sourcing on every map load, so it warns once per map load.
local _warnedInvalidIndex = false


--- True when `index` addresses a shipped preset; `2.5`, `"3"` and nil do not.
---@param index any the stored or received setting value
---@return boolean valid
function RLDiseaseDifficulty.isValidIndex(index)
    return type(index) == "number" and RLDiseaseDifficulty.PRESETS[index] ~= nil
end


--- The preset row for `index`, falling back to Normal with one WARNING per map load for anything invalid.
---@param index any the stored or received setting value; never raises for any input
---@return table preset the live row, READ-ONLY by contract
function RLDiseaseDifficulty.getPreset(index)
    if RLDiseaseDifficulty.isValidIndex(index) then
        return RLDiseaseDifficulty.PRESETS[index]
    end

    local fallback = RLDiseaseDifficulty.PRESETS[RLDiseaseDifficulty.DEFAULT_INDEX]

    if not _warnedInvalidIndex then
        _warnedInvalidIndex = true

        Log:warning("RLDiseaseDifficulty.getPreset: index %s addresses no preset - falling back to [%s] (%s)",
            tostring(index), tostring(RLDiseaseDifficulty.DEFAULT_INDEX), tostring(fallback.key))
    else
        Log:trace("RLDiseaseDifficulty.getPreset: index %s addresses no preset - falling back to %s (already warned)",
            tostring(index), tostring(fallback.key))
    end

    return fallback
end


--- Whether diseases run at all under `index`; an invalid index reads as Normal, so enabled.
---@param index any the stored or received setting value; never raises for any input
---@return boolean enabled
function RLDiseaseDifficulty.isEnabled(index)
    -- An explicit branch: an `a and b or c` shape turns Off's `false` into `true`.
    if RLDiseaseDifficulty.getPreset(index).enabled then
        return true
    end

    return false
end


--- Map the retired binary setting's stored state onto a preset: OFF (1) is Off, everything else is Normal.
---@param state any the legacy `diseasesEnabled#value` read; nil when the element is absent
---@return number index the preset index to store
function RLDiseaseDifficulty.fromLegacyEnabledState(state)
    if state == 1 then
        return RLDiseaseDifficulty.OFF_INDEX
    end

    if state ~= 2 then
        Log:trace("RLDiseaseDifficulty.fromLegacyEnabledState: legacy state %s is neither 1 nor 2 - Normal",
            tostring(state))
    end

    return RLDiseaseDifficulty.DEFAULT_INDEX
end


--- Scale an authored per-month infection chance: a non-positive or NaN product is 0, and the result caps at 1.
---@param pMonth number the authored per-month probability. TRUSTED INTERNAL input
---@param scale number the preset's `infection` multiplier. TRUSTED INTERNAL input
---@return number pMonth the scaled per-month probability, in [0, 1]
function RLDiseaseDifficulty.scaleInfectionChance(pMonth, scale)
    local product = pMonth * scale

    -- The refusal runs BEFORE the cap: math.min(nan, 1) is 1 on both runtimes, so a fold
    -- would turn a NaN product into certain infection.
    if not (product > 0) then
        Log:trace("RLDiseaseDifficulty.scaleInfectionChance: pMonth=%s scale=%s -> 0 (non-positive or NaN)",
            tostring(pMonth), tostring(scale))

        return 0
    end

    if product > 1 then
        Log:trace("RLDiseaseDifficulty.scaleInfectionChance: pMonth=%s scale=%s product=%s -> capped at 1",
            tostring(pMonth), tostring(scale), tostring(product))

        return 1
    end

    return product
end


--- The hidden window a record seeded under `scale` serves: an authored 0 stays 0, anything else floors at 1 tick.
---@param authoredTicks number the model's authored `incubationTicks`. TRUSTED INTERNAL input
---@param scale number the preset's `incubation` multiplier. TRUSTED INTERNAL input
---@return number ticks the effective integer window
function RLDiseaseDifficulty.effectiveIncubationTicks(authoredTicks, scale)
    -- The floor bounds a SCALE, never an AUTHOR: an authored 0 means visible at once.
    if not (authoredTicks > 0) then
        Log:trace("RLDiseaseDifficulty.effectiveIncubationTicks: authored %s -> 0 (no hidden window)",
            tostring(authoredTicks))

        return 0
    end

    return RLDiseaseRecord.incubationTicksFor(authoredTicks * scale)
end


--- The model the spread pass prices: the registry's own table at scale 1, otherwise a copy carrying the scaled R0.
---@param model table a parsed registry model; never written
---@param spreadScale number the preset's `spread` multiplier. TRUSTED INTERNAL input
---@return table model `model` itself at scale 1, otherwise a shallow copy
function RLDiseaseDifficulty.spreadModel(model, spreadScale)
    if spreadScale == 1 then
        return model
    end

    local copy = {}

    for field, value in pairs(model) do copy[field] = value end

    copy.r0 = model.r0 * spreadScale

    Log:trace("RLDiseaseDifficulty.spreadModel: title=%s r0 %s -> %s (scale %s)",
        tostring(model.title), tostring(model.r0), tostring(copy.r0), tostring(spreadScale))

    return copy
end


local loadedRows = {}

for index, preset in ipairs(RLDiseaseDifficulty.PRESETS) do
    loadedRows[#loadedRows + 1] = string.format("[%s] %s enabled=%s infection=%s incubation=%s spread=%s",
        tostring(index), tostring(preset.key), tostring(preset.enabled), tostring(preset.infection),
        tostring(preset.incubation), tostring(preset.spread))
end

Log:debug("RLDiseaseDifficulty loaded: %s", table.concat(loadedRows, "; "))
