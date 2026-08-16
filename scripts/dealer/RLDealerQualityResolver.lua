-- RLDealerQualityResolver.lua
-- Resolves which dealer-quality preset is ACTIVE, and the markup that follows
-- from it, for every consumer that prices or generates a dealer animal.
--
-- Split deliberately in two:
--   * indexFrom(settings) is ENV-FREE - data in, data out, no global reads and
--     no mutation of the argument - so it is dual-runnable under the headless
--     harness against a literal table.
--   * getActiveIndex() is the two-line adapter that reads the real RLSettings.
--
-- The active preset is read from `RLSettings.SETTINGS.dealerQuality.state`
-- rather than from a mirror field on AnimalSystem. The markup is read on
-- CLIENTS too, and a mirror only exists on a machine where the settings
-- callback has fired, whereas `state` is the quantity the wire actually
-- carries. Reading the synced field directly removes a whole class of
-- "client priced with a stale markup" bug.
--
-- Guard asymmetry, deliberate: RLSettings is nil-guarded because its absence
-- is a LEGITIMATE state (headless, very early load, before the settings row
-- exists). RLDealerQualityModel is NOT guarded anywhere in this file, because
-- its absence is always our own packaging or load-order error - failing loud at
-- the first dereference catches that before shipping instead of silently
-- pricing at a fallback.

RLDealerQualityResolver = {}

local Log = RmLogging.getLogger("RLRM")


-- One-shot log flags. These make the module stateful but NOT env-dependent:
-- the return value is still determined entirely by the argument. They leak
-- across repeated rlTest runs in one session, so no test may assert on a log
-- line firing, on a flag being cold, or on run order.
local warnedInvalidState = false
local loggedAbsentSettings = false

-- Log-only memo for the change-triggered markup line. SEEDED to DEFAULT_INDEX,
-- never to nil: seeded to nil the very first getMarkup() call would compare
-- against nil and emit a spurious "markup resolved" line on a default-preset
-- session. Seeding here makes "no change has happened yet" and "the resolved
-- index equals the memo" the same state. No behaviour depends on it.
local lastMarkupIndex = RLDealerQualityModel.DEFAULT_INDEX


--- Resolve a validated preset index from a settings table. Env-free.
--- Any shape that is not a valid 1..PRESET_COUNT index resolves to
--- DEFAULT_INDEX, so callers never have to validate the result.
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

    -- Read the state defensively: `type(entry) == "table"` because a scalar entry
    -- (hand-edited save, a migration writing the index directly) would otherwise
    -- raise on the index, and this sits on the per-row dealer price path. An
    -- explicit assignment rather than the `and/or` idiom because that idiom
    -- collapses a `false` state to nil, which would skip the warning below.
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


--- The active preset index for this machine, read from live settings.
--- Reading an undefined global yields nil in Lua, so the RLSettings guard is a
--- real guard, not ceremony - it is what lets the pricing path load headless.
--- @return number presetIndex A valid preset index, never nil
function RLDealerQualityResolver.getActiveIndex()
    return RLDealerQualityResolver.indexFrom(RLSettings ~= nil and RLSettings.SETTINGS or nil)
end


--- The buy-side markup for the active preset. This is THE markup accessor for every LIVE pricing
--- path. One qualification on "every", deliberate: the herdsman reaches it INDIRECTLY, because
--- RLHerdsmanPlanner must stay pure - RLHerdsmanDayTick.buildEnv calls this once per tick and
--- injects the result as that planner's ctx.buyMarkup.
--- Logs only when the resolved preset CHANGES, because this sits on the
--- dealer-row render path and is called per row per refresh.
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
