--[[
    RLGeneticsDraw.lua
    Base genetics draw for dealer sale animals: a reject-truncated Bates-3 bell.

    Pure data-in / data-out - no `g_*`, no XML, no GUI, nothing from the engine
    beyond `math.clamp` on the guard-cap fallback - so the module dual-runs
    headless.

    One per-animal base quality `q` is the mean of three uniforms stretched onto
    `[CENTRE - H, CENTRE + H]`; each trait is `q` plus its own jitter. If ANY
    trait leaves `[MIN, MAX]` the WHOLE animal is redrawn, `q` included, so
    accepted attempts stay independent and the bell keeps its shape at the domain
    edges. The shared `q` is the point: an animal's traits stay correlated.

    H, JITTER, the Bates order of 3 and MAX_ATTEMPTS are curve constants, not
    tuning knobs - changing one is a design decision.
]]

RLGeneticsDraw = {}

local Log = RmLogging.getLogger("RLRM")


RLGeneticsDraw.MIN = RLConstants.GENETICS_MIN
RLGeneticsDraw.MAX = RLConstants.GENETICS_MAX

-- Curve centre, DERIVED so the bell follows a change to the bounds instead of
-- silently going off-centre and driving the rejection rate toward exhaustion.
-- `(0.25 + 1.75) / 2` is exactly 1.0, the literal it replaced.
RLGeneticsDraw.CENTRE = (RLGeneticsDraw.MIN + RLGeneticsDraw.MAX) / 2

-- Half-width of the pre-rejection support, wider than `[MIN, MAX]` so rejection
-- returns a bell whose tails reach the domain limits rather than a plateau. Hand
-- picked, NOT derived: it sets how much of the bell's body survives rejection.
RLGeneticsDraw.H = 1.5

-- Per-trait spread around the animal's base quality: `uniform(-JITTER, +JITTER)`.
RLGeneticsDraw.JITTER = 0.15

-- Guard cap on the reject loop. MUST be >= 1: at 0 the attempt loop never runs
-- and the fallback would clamp a nil table. With the pinned curve, exhausting 20
-- attempts is a roughly 1e-14 event - a tripwire, not a path players meet.
RLGeneticsDraw.MAX_ATTEMPTS = 20

-- Accepted draws needing more attempts than this are worth a DEBUG line; the
-- ordinary case stays at TRACE.
RLGeneticsDraw.DEBUG_ATTEMPT_THRESHOLD = 5


-- The two ordered trait-key arrays the production call sites pass. Order is
-- load-bearing: `draw` walks them with `ipairs`, so a seeded RNG reproduces
-- byte-identical output only while the order holds. READ-ONLY by contract -
-- neither `draw` nor any caller may mutate them.
RLGeneticsDraw.TRAITS_BASE = {
    "metabolism",
    "quality",
    "fertility",
    "health"
}

RLGeneticsDraw.TRAITS_WITH_PRODUCTIVITY = {
    "metabolism",
    "quality",
    "fertility",
    "health",
    "productivity"
}


--- Render trait values as a greppable `key=value` run in array order.
--- @param traitKeys table Ordered array of trait keys
--- @param values table Map of trait key to number
--- @return string text Space-separated `key=%.6f` pairs, empty for an empty key list
local function formatTraitValues(traitKeys, values)
    local parts = {}

    for _, key in ipairs(traitKeys) do
        table.insert(parts, string.format("%s=%.6f", key, values[key]))
    end

    return table.concat(parts, " ")
end


--- Draw one animal's genetics from the reject-truncated Bates-3 bell.
---
--- Every returned value is inside `[MIN, MAX]` - accepted, or clamped on guard-cap
--- exhaustion - so callers may treat the result as domain-valid unconditionally.
--- RNG consumption is a constant `3 + #traitKeys` calls per attempt, so a
--- deterministic stub sees the same stream regardless of which trait failed.
--- @param traitKeys table Ordered array of trait keys to draw. TRUSTED INTERNAL
---        input - pass `TRAITS_BASE` or `TRAITS_WITH_PRODUCTIVITY`
--- @param randomFn function|nil `function() -> number in [0, 1)`. TEST-ONLY
---        injection seam; production passes nothing and gets `math.random`
--- @return table genetics Map of trait key to value, every value in `[MIN, MAX]`
--- @return number attempts Attempts consumed, `1 .. MAX_ATTEMPTS`
--- @return boolean exhausted True when the guard cap was hit and the result clamped
function RLGeneticsDraw.draw(traitKeys, randomFn)
    randomFn = randomFn or math.random

    local lastValues

    for attempt = 1, RLGeneticsDraw.MAX_ATTEMPTS do
        -- Bates-3: the mean of three uniforms, stretched onto [CENTRE +/- H].
        local qUnit = (randomFn() + randomFn() + randomFn()) / 3
        local q = (RLGeneticsDraw.CENTRE - RLGeneticsDraw.H) + 2 * RLGeneticsDraw.H * qUnit

        local values = {}
        local inRange = true
        local firstBadKey, firstBadValue

        for _, key in ipairs(traitKeys) do
            local value = q + (randomFn() * 2 - 1) * RLGeneticsDraw.JITTER
            values[key] = value

            if value < RLGeneticsDraw.MIN or value > RLGeneticsDraw.MAX then
                -- First offender only; no break, so RNG consumption stays constant.
                if inRange then
                    firstBadKey, firstBadValue = key, value
                end

                inRange = false
            end
        end

        lastValues = values

        if inRange then
            -- Level-guarded: RmLogger:trace checks the level inside the method, so
            -- formatTraitValues would otherwise be paid on every accepted draw at
            -- every level - hundreds per dealer reset.
            if Log.level >= RmLogging.LOG_LEVEL.TRACE then
                Log:trace("RLGeneticsDraw: accept attempts=%d q=%.4f %s",
                    attempt, q, formatTraitValues(traitKeys, values))
            end

            if attempt > RLGeneticsDraw.DEBUG_ATTEMPT_THRESHOLD then
                Log:debug("RLGeneticsDraw: accepted only after %d attempts (threshold %d)",
                    attempt, RLGeneticsDraw.DEBUG_ATTEMPT_THRESHOLD)
            end

            return values, attempt, false
        end

        Log:trace("RLGeneticsDraw: reject attempt=%d trait=%s value=%.4f",
            attempt, tostring(firstBadKey), firstBadValue or 0)
    end

    -- Guard-cap fallback: keep the last attempt's correlated character and pull it
    -- into the domain. Clamping re-introduces one exact-edge value, which is why
    -- it warns - it should never be seen in a normal session.
    local lastText = formatTraitValues(traitKeys, lastValues)

    for _, key in ipairs(traitKeys) do
        lastValues[key] = math.clamp(lastValues[key], RLGeneticsDraw.MIN, RLGeneticsDraw.MAX)
    end

    Log:warning("RLGeneticsDraw: guard cap hit after %d attempts - clamped into [%.2f, %.2f]; last=[%s] clamped=[%s]",
        RLGeneticsDraw.MAX_ATTEMPTS, RLGeneticsDraw.MIN, RLGeneticsDraw.MAX,
        lastText, formatTraitValues(traitKeys, lastValues))

    return lastValues, RLGeneticsDraw.MAX_ATTEMPTS, true
end

Log:info("RLGeneticsDraw loaded")
