-- RLDealerQualityResolver.lua
-- Resolves which dealer-quality preset is ACTIVE, and the markup that follows from it, for
-- every consumer that prices or generates a dealer animal.
--
-- Split in two: `indexFrom(settings)` is ENV-FREE so it dual-runs headless against a literal
-- table, and `getActiveIndex()` is the adapter that reads the real RLSettings.
--
-- The active preset comes from `RLSettings.SETTINGS.dealerQuality.state`, not a mirror field
-- on AnimalSystem: the markup is read on CLIENTS too, where no settings callback has fired.
--
-- Guard asymmetry, deliberate: RLSettings is nil-guarded because its absence is LEGITIMATE
-- (headless, or very early load); RLDealerQualityModel is guarded nowhere, because its absence
-- is always a packaging error and must fail loud rather than price at a fallback.

RLDealerQualityResolver = {}

local Log = RmLogging.getLogger("RLRM")


-- One-shot log flags. They make the module stateful but NOT env-dependent - the return value
-- still follows entirely from the argument. They leak across repeated rlTest runs in one
-- session, so no test may assert on a log line firing, on a flag being cold, or on run order.
local warnedInvalidState = false
local loggedAbsentSettings = false

-- Log-only memo for the change-triggered markup line. SEEDED to DEFAULT_INDEX, never to nil:
-- seeded to nil, the first getMarkup() call would compare against nil and emit a spurious
-- "markup resolved" line on a default-preset session. No behaviour depends on it.
local lastMarkupIndex = RLDealerQualityModel.DEFAULT_INDEX


--- Resolve a validated preset index from a settings table. Env-free, and anything that is not
--- a valid index resolves to DEFAULT_INDEX, so callers never validate the result.
--- @param settings table|nil The RLSettings.SETTINGS table, or any literal table
--- @return number presetIndex A valid preset index, never nil
function RLDealerQualityResolver.indexFrom(settings)
    if settings == nil then
        if not loggedAbsentSettings then
            loggedAbsentSettings = true
            Log:debug("RLDealerQualityResolver.indexFrom: no settings table; using DEFAULT_INDEX")
        end

        return RLDealerQualityModel.DEFAULT_INDEX
    end

    -- The type test is load-bearing on this per-row price path: a scalar entry, from a
    -- hand-edited save, would raise on the index. Explicit assignment rather than `and/or`,
    -- which collapses a `false` state to nil and would skip the warning below.
    local entry = settings.dealerQuality
    local state = nil

    if type(entry) == "table" then
        state = entry.state
    elseif entry ~= nil and not warnedInvalidState then
        warnedInvalidState = true
        Log:warning("RLDealerQualityResolver.indexFrom: dealerQuality entry is a %s, not a table; using DEFAULT_INDEX",
            type(entry))
    end

    if RLDealerQualityModel.isValidIndex(state) then return state end

    if state ~= nil and not warnedInvalidState then
        warnedInvalidState = true
        Log:warning("RLDealerQualityResolver.indexFrom: invalid dealerQuality state %s; using DEFAULT_INDEX",
            tostring(state))
    end

    return RLDealerQualityModel.DEFAULT_INDEX
end


--- The active preset index for this machine, read from live settings. The RLSettings guard is
--- what lets the pricing path load headless.
--- @return number presetIndex A valid preset index, never nil
function RLDealerQualityResolver.getActiveIndex()
    return RLDealerQualityResolver.indexFrom(RLSettings ~= nil and RLSettings.SETTINGS or nil)
end


--- The buy-side markup for the active preset - THE markup accessor for every live pricing
--- path. The herdsman reaches it indirectly through `ctx.buyMarkup`, RLHerdsmanPlanner having
--- to stay pure. Logs only when the resolved preset CHANGES; this is a render path.
--- @return number markup Multiplier applied to an animal's sell price
function RLDealerQualityResolver.getMarkup()
    local presetIndex = RLDealerQualityResolver.getActiveIndex()

    if presetIndex ~= lastMarkupIndex then
        Log:debug("RLDealerQualityResolver.getMarkup: markup resolved preset %d(%s) %.3f -> %d(%s) %.3f",
            lastMarkupIndex, RLDealerQualityModel.getPreset(lastMarkupIndex).key,
            RLDealerQualityModel.resolveMarkup(lastMarkupIndex),
            presetIndex, RLDealerQualityModel.getPreset(presetIndex).key,
            RLDealerQualityModel.resolveMarkup(presetIndex))
        lastMarkupIndex = presetIndex
    end

    return RLDealerQualityModel.resolveMarkup(presetIndex)
end


Log:debug("RLDealerQualityResolver loaded")
