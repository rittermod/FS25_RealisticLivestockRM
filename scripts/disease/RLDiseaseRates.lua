--[[
    RLDiseaseRates.lua
    The one home for the per-month to per-tick probability conversion the disease
    model needs, plus its inverse.

    The pen ticks daily and advances the disease clock by `dt = 1 / daysPerPeriod`
    months, while fatality, transmission and infection are all authored per MONTH.
    `perTick` converts one into the other so a monthly probability delivers the
    same cumulative risk whatever period length the player runs, and `compound`
    converts back so the invariant can be asserted against real code instead of
    against a copy of the formula in a test body.

    Pure data-in / data-out. No `g_*`, no GUI, no XML, no engine natives at all -
    RmLogging at file scope is the only dependency, so the module dual-runs
    headless.

    `daysPerPeriod` arrives as a PARAMETER and is never read from the environment
    here, nor cached at module load. The setting is player-changeable mid-game, so
    a captured value goes stale silently, and a module-load read is the load-order
    trap that reads populated headless and empty in-game. Read it at CALL time and
    pass it.

    HOW EXACT THE ROUND TRIP IS - the part worth knowing before writing an
    assertion against it. The algebra inverts exactly; the arithmetic does not.
    `1 - (1 - p)` is not `p` in IEEE-754, because the intermediate `1 - p` is
    already rounded, so even `daysPerPeriod = 1` is not the identity:
    `perTick(0.001, 1)` returns `0.0010000000000000009`. Never compare a
    round-tripped value with `==`.

    What IS exact is the pair of boundary values, at every integer
    `daysPerPeriod` from 1 to 28: `perTick(0, n)` is bit-exactly `0` and
    `perTick(1, n)` bit-exactly `1`, because `1 - 1` and `1 - 0` are both exact.
    The zero case is load-bearing rather than decorative - a disease with no
    spread must stay at no spread.

    Everything between is a tolerance claim, and the tolerance is ABSOLUTE.
    Relative error grows without bound as the probability shrinks, so a relative
    criterion is unsatisfiable in the tail; absolute error does not, and over a
    28,336-pair sweep of `[1e-12, 1]` against 1..28 the worst is about `1.6e-15`.

    TWO SEPARATE FLOORS, easily conflated - they sit three orders apart. The
    suite's tolerance (`EPSILON`, which the suite owns) is exercised only down to
    `1e-12`, because an absolute bound stops DISCRIMINATING below there: an
    implementation returning a constant zero would satisfy it. Far lower, and
    rung-dependent, the arithmetic actually underflows - `perTick` first returns
    bit-exact zero around `1.6e-15` at 28 ticks and around `5.6e-17` at one
    (measured), so a nonzero monthly probability becomes impossible per tick.
    Both floors sit far below any authored probability.

    SHARP EDGES, named so the next reader does not rediscover them. There is
    deliberately no validation: all three future callers are mod code inside this
    subsystem, and the wiring bug a real caller produces is a MISSING argument,
    which raises on the arithmetic. Out-of-domain VALUES are trusted and do not
    raise - and the two functions differ on every one of them, so read this as an
    enumeration rather than a rule (all measured):

      out of range   `perTick(1.5, 3)` is `nan`; `compound(1.5, 3)` is `1.125` -
                     it leaves [0, 1] WITHOUT producing nan, so a caller checking
                     only for nan does not catch it
      zero ticks     `perTick(p, 0)` is `1` (certainty); `compound(p, 0)` is `0`
      negative       `perTick(-0.5, 3)` is `-0.14...`; `compound(-0.5, 3)` is `-2.375`

    Of those, `perTick -> 1` is the one to respect: for a fatality or transmission
    rate it means the event fires every tick, with no nan, no error and no log
    line to notice it by.

    On the range of `daysPerPeriod`: the settings screen offers an integer in
    1..28, and that is the only place the range is enforced. A value outside it
    can still reach this module - a loaded save carries whatever it carries - so
    a consumer that cares should bound the number at its own call site rather
    than treat 1..28 as guaranteed here.

    Nothing calls this module yet. The fatality, transmission and infection slices
    each adopt it in their own change.
]]

RLDiseaseRates = {}

local Log = RmLogging.getLogger("RLRM")


--- Convert a per-month probability to the per-tick probability that compounds
--- back to it over one period.
---
--- `p_tick = 1 - (1 - p_month) ^ (1 / daysPerPeriod)`. Stated in that form rather
--- than through `exp`/`log`: both were measured and their worst round-trip error
--- is identical to six significant figures, because the loss lives in the shared
--- `1 - p` term rather than in the exponentiation, so the transcendental pair
--- buys nothing. The formulation that genuinely avoids forming `1 - p` needs
--- `expm1` and `log1p`, and both are absent from this runtime.
--- @param pMonth number Probability in [0, 1]. TRUSTED INTERNAL input - not
---        validated; see the header's sharp-edge enumeration.
--- @param daysPerPeriod number Ticks in one period - the pen ticks daily, so this
---        is the days-per-period setting, an integer 1..28. TRUSTED INTERNAL input -
---        not validated. Read it at call time; never cache it.
--- @return number pTick Probability in [0, 1] for in-domain input
function RLDiseaseRates.perTick(pMonth, daysPerPeriod)
    return 1 - (1 - pMonth) ^ (1 / daysPerPeriod)
end


--- Compound a per-tick probability back over a whole period. Inverse of perTick.
---
--- Public surface rather than a test-local helper on purpose: the compounding
--- invariant is what this module promises, and writing `1 - (1 - t) ^ n` inside a
--- test body would assert a copy of the formula instead of the module. It also
--- carries its own boundary and value coverage, because a round trip alone cannot
--- separate a correct pair from a jointly-wrong one.
--- @param pTick number Probability in [0, 1]. TRUSTED INTERNAL input - not
---        validated; see the header's sharp-edge enumeration.
--- @param daysPerPeriod number Ticks in one period - the pen ticks daily, so this
---        is the days-per-period setting, an integer 1..28. TRUSTED INTERNAL input -
---        not validated. Read it at call time; never cache it.
--- @return number pMonth Probability in [0, 1] for in-domain input
function RLDiseaseRates.compound(pTick, daysPerPeriod)
    return 1 - (1 - pTick) ^ daysPerPeriod
end


-- The load line is the whole of this module's logging, deliberately. Both
-- functions are single-expression pure arithmetic - no branch, no early return,
-- no failure path - so there is no branch decision for TRACE to record and no
-- outcome for DEBUG to report. Read the absence as that, not as under-logging.
Log:info("RLDiseaseRates loaded")
