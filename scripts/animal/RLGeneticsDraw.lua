--[[
    RLGeneticsDraw.lua
    Base genetics draw for dealer sale animals: a reject-truncated Bates-3 bell.

    Pure data-in / data-out. No `g_*`, no XML, no GUI, no engine state beyond
    `math.clamp` on the guard-cap fallback - so the module dual-runs headless.

    The curve: one per-animal base quality `q` is the mean of three uniforms
    stretched onto `[1 - H, 1 + H]`; each trait is `q` plus its own
    `uniform(-JITTER, +JITTER)`. If ANY trait leaves `[MIN, MAX]` the WHOLE
    animal is redrawn (`q` included), so accepted attempts stay independent and
    the bell keeps its shape at the domain edges. Redrawing only the offending
    trait would bias the accepted jitter inward near a limit and re-create
    shoulder bumps, which is exactly the artifact this draw exists to avoid.

    The shared `q` is the point, not a side effect: an animal's traits stay
    correlated (a good animal is good across the board), at the cost of roughly
    halving the within-animal spread compared with independent per-trait draws.

    Curve constants (`H`, `JITTER`, the Bates order of 3, `MAX_ATTEMPTS`) were
    selected by a width sweep plus a shoulder-bump proof in the dealer-quality
    distribution research and are pinned there - changing any of them is a
    design decision, not a tuning knob.
]]

RLGeneticsDraw = {}

local Log = RmLogging.getLogger("RLRM")


-- Genetics domain. Read from the mod's one constants home so this module, the
-- dealer-quality model and every downstream consumer share a single definition.
RLGeneticsDraw.MIN = RLConstants.GENETICS_MIN
RLGeneticsDraw.MAX = RLConstants.GENETICS_MAX

-- Curve centre, DERIVED from the domain rather than written as a literal. The
-- `q` mapping below used to hard-code `1`, which meant this module could not
-- follow a change to the bounds it had just been refactored to read from one
-- home: moving MIN or MAX alone silently produced an off-centre, mis-scaled bell
-- and drove the rejection rate toward MAX_ATTEMPTS exhaustion, which only WARNs.
-- Deriving it closes that coupling (RLRM-556 review F6, Ritter 2026-07-29).
--
-- Behaviour is unchanged for the shipped domain: `(0.25 + 1.75) / 2` is exactly
-- `1.0`, the value the literal carried.
RLGeneticsDraw.CENTRE = (RLGeneticsDraw.MIN + RLGeneticsDraw.MAX) / 2

-- Half-width of the pre-rejection support, in domain units around CENTRE: `q` is
-- drawn on `[CENTRE - H, CENTRE + H]`, i.e. wider than `[MIN, MAX]`, so that the
-- rejection step returns a bell whose tails reach the domain limits instead of
-- a bell truncated to a plateau.
--
-- H itself is still a hand-picked curve constant, NOT derived - it sets how much
-- of the bell's body survives rejection, which is a shape decision rather than a
-- consequence of the domain. Retuning it is Ask First per the spec's Boundaries.
RLGeneticsDraw.H = 1.5

-- Per-trait spread around the animal's base quality: `uniform(-JITTER, +JITTER)`.
RLGeneticsDraw.JITTER = 0.15

-- Guard cap on the reject loop. MUST be >= 1: at 0 or less the attempt loop
-- never runs and the fallback would clamp a nil table. With the pinned curve the
-- per-attempt rejection rate is about 0.2, so exhausting 20 attempts is a
-- roughly 1e-14 event - a tripwire, not a code path players meet.
RLGeneticsDraw.MAX_ATTEMPTS = 20

-- Accepted draws that needed MORE than this many attempts are worth a DEBUG
-- line; the ordinary one-or-two-attempt case stays at TRACE because generation
-- fires hundreds of times per dealer reset.
RLGeneticsDraw.DEBUG_ATTEMPT_THRESHOLD = 5


-- The two ordered trait-key arrays the production call sites pass, so the call
-- sites cannot drift apart. Order is load-bearing: `draw` walks them with
-- `ipairs`, so a seeded RNG reproduces byte-identical output only while the
-- order holds.
--
-- READ-ONLY by contract: neither `draw` nor any caller may mutate these tables.
-- There is deliberately no defensive copy and no metatable freeze - both sit on
-- a hot path, and the contract is upheld by review.
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
--- Every returned value is inside `[MIN, MAX]`: normally because the attempt was
--- accepted, and on guard-cap exhaustion because the last attempt is clamped.
--- Callers may therefore treat the result as domain-valid unconditionally.
---
--- RNG consumption is a constant `3 + #traitKeys` calls per attempt - the trait
--- loop deliberately keeps scanning after the first out-of-range value, so a
--- deterministic stub sees the same stream regardless of which trait failed.
---
--- @param traitKeys table Ordered array of trait keys to draw. TRUSTED INTERNAL
---        input - not validated. Pass `TRAITS_BASE` or `TRAITS_WITH_PRODUCTIVITY`;
---        duplicate keys would collapse in the result while still consuming RNG.
--- @param randomFn function|nil `function() -> number in [0, 1)`. TEST-ONLY
---        injection seam, trusted and unvalidated; production passes nothing and
---        gets `math.random`.
--- @return table genetics Map of trait key to value, every value in `[MIN, MAX]`
--- @return number attempts Attempts consumed, `1 .. MAX_ATTEMPTS`
--- @return boolean exhausted True when the guard cap was hit and the result was clamped
function RLGeneticsDraw.draw(traitKeys, randomFn)
    randomFn = randomFn or math.random

    local lastValues

    for attempt = 1, RLGeneticsDraw.MAX_ATTEMPTS do
        -- Bates-3: the mean of three uniforms, stretched onto [1 - H, 1 + H].
        local qUnit = (randomFn() + randomFn() + randomFn()) / 3
        -- CENTRE, not a literal 1: the curve follows the domain if either bound
        -- ever moves. Identical arithmetic for the shipped domain, where CENTRE
        -- is exactly 1.0 (RLRM-556 review F6).
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
            -- TRACE, not DEBUG: this fires once per generated sale animal
            -- (hundreds per dealer reset). The per-trait values double as the
            -- live sample dump for verifying the distribution in a play session.
            --
            -- Level-guarded: RmLogger:trace checks the level INSIDE the method,
            -- so `formatTraitValues` - a table alloc, N string.format calls and a
            -- table.concat - was being paid on EVERY accepted draw at every
            -- level, ERROR included (~1,250 formats per default dealer reset).
            -- Mirrors the guards at `RealisticLivestock_AnimalSystem`
            -- (createNewSaleAnimal) and `RLMenuBuyFrame` (the dealer-list digest).
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

    -- Guard-cap fallback: keep the last attempt's correlated character and pull
    -- it into the domain. Clamping re-introduces one exact-edge value, which is
    -- why it is a WARNING - it should never be seen in a normal session.
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
