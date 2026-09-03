--[[
    RLDiseaseFatality.lua
    The one home for turning an authored per-month case fatality into the per-tick
    hazard an infectious animal actually rolls, and for moving the record to DEAD
    when that roll hits.

    THE VULNERABILITY FACTOR ARRIVES AS A NUMBER. This module reads no animal, no
    mission and no animal-type registry: the caller resolves the factor and hands
    it over, exactly as `RLDiseaseVulnerability`'s own header says a consumer
    should use it. That keeps the dependency set to `RLDiseaseRates` and
    `RLDiseaseRecord`, keeps the module dual-running with no registry, and leaves
    the animal-to-factor resolution in one place for the slice that wires a caller.

    THE COMPOSITION ORDER IS THE CONTRACT, and it is the thing to get right before
    anything else here. The authored rate is scaled by the animal's factor while it
    is still a MONTHLY rate, and the conversion to per-tick happens LAST:

        monthly  = the endpoint's authored rate
        scaled   = monthly * vulnerability      -- still per MONTH
        hazard   = perTick(min(scaled, 1), daysPerPeriod)

    Scaling the per-TICK value instead makes cumulative risk depend on the player's
    days-per-period setting, which is the defect the whole two-clocks design exists
    to remove: compounding `perTick(m * v, n)` over `n` ticks returns `m * v` at
    every `n`, while compounding `perTick(m, n) * v` returns a value that moves with
    `n`.

    ONE INVERTED GUARD DOES THE WORK OF THREE SEPARATE CHECKS, and it sits between
    the multiply and the clamp. `not (scaled > 0)` returns a hazard of 0 for a zero
    rate, a negative product AND a NaN in a single test, where the plain `<= 0` form
    catches none of the NaN case because every comparison against NaN is false in
    both directions.

    IT REJECTS EXACTLY THOSE THREE, AND A POSITIVE INFINITY IS NOT AMONG THEM - read
    the guard as "non-positive or NaN", never as "non-finite". An infinite product is
    greater than zero, so it passes here and the clamp below takes it to 1: certain
    death. That is deliberate rather than a hole. An infinitely vulnerable animal
    dying IS the right answer, where a NaN means "no information about this animal"
    and correctly yields a hazard of zero - the two non-finite values want opposite
    treatments, which is why one guard cannot and should not cover both. The producer
    reaches an infinite factor only for a negative-infinite age, which no animal has.

    Three measured values say why each half of the guard matters:

      a zero rate against an infinite factor multiplies to NaN, so a harmless
      disease would launder into certain death without the guard.

      a NaN in the clamp's FIRST slot yields 1 and in its second yields the NaN, so
      a fold cannot be the NaN filter in either order - one direction manufactures
      certainty, the other a hazard that never fires.

      `RLDiseaseVulnerability.factor` ends in a fold whose NaN behaviour DIFFERS
      between the two runtimes this module runs on. With the guard above, both land
      on a hazard of 0, so the two runners agree and one shared dual-run assert can
      pin the result.

    Only AFTER that guard is the clamp applied, and its argument order therefore
    carries nothing - the fold can never see a NaN. The clamp is an UPPER bound
    only: the lower bound belongs to the vulnerability module's own floor, and the
    guard above catches a negative product anyway. An unclamped product above 1
    reaches the rate conversion outside its domain and returns NaN, after which a
    `draw < hazard` comparison is false forever with no error and no log line.

    NO UNGUARDED DIVISION BY AN AUTHOR-SUPPLIABLE VALUE. There IS one division here -
    the reciprocal of the median - and the property that matters is that it is
    GUARDED, not that it is absent: `not (median > 0)` returns certainty above it and
    the infinite case returns zero. Stating it as "no division occurs" would be
    literally false and, worse, uncheckable - a future edit that reorders the guard
    would still satisfy the sentence while destroying the property. The engine logs a
    divide-by-zero script error plus a full callstack on any division by zero while
    LuaJIT is silent on the same expression, so an unguarded one would be invisible to
    every headless run and would move the in-game error-line pin. The median is read
    with a non-negative check upstream that refuses only a negative, so zero parses
    and so does a NaN.

    `endpoint` SELECTS WHICH AUTHORED NUMBER IS THE RATE, through a CLOSED dispatch.
    `terminal` converts the `chronicMonthsToDeath` MEDIAN and never reads
    `caseFatality`; `recovers`, `lifelong` and `cureOnly` each read `caseFatality`.
    The three are listed EXPLICITLY rather than reached by an `else`, so a fifth
    endpoint added later refuses with a diagnostic instead of silently inheriting
    a rate that means something different. An unrecognised or nil endpoint returns
    0 - never the `caseFatality` arm by fall-through, which is the infer-from-absence
    shape the endpoint vocabulary exists to remove.

    That dispatch also settles a mis-authored `terminal` model at RUNTIME: the
    parser accepts `terminal` with a `caseFatality` other than 1, and under this
    design there is no ambiguity, because the median wins and the scalar is inert.

    TREATMENT IS NOT READ. No field of a running course reaches any line here, so a
    treated animal serves the identical hazard to an untreated one. What this module
    CANNOT establish is the tick ORDER - that fatality is rolled before a course can
    complete - because a module with no caller cannot prove an ordering. That
    obligation belongs to the slices that wire the tick.

    SHARP EDGES, named so the next reader does not rediscover them.

      nil vulnerability   RAISES on the multiply, deliberately, BEFORE any
                          days-per-period arithmetic and before the draw. A wiring
                          bug should be loud.
      nil daysPerPeriod   RAISES inside the rate conversion, for the same reason. The
                          hazard is computed before the draw, so the generator is
                          untouched.
      a dpp of zero       yields certainty - the rate primitive returns 1 there. Its
                          header states that the 1..28 range is enforced only by the
                          settings screen, so a consumer that cares bounds it at its
                          own call site. No slice owns that bound yet.
      infinite median     yields a hazard of 0: the reciprocal is 0 and a half raised
                          to 0 is 1, so the disease never kills. A documented
                          authoring consequence, not a guard. A large FINITE median
                          reaches the same place by underflow rather than by the
                          explicit branch - measured, the hazard is 1.11e-16 at a
                          median of 1e16 and bit-exactly 0 at 1e17 - so read the
                          infinite case as the declared end of a continuum, not as
                          the only median that cannot kill.

    Nothing calls this module yet. The slices that wire the progression tick adopt
    it, and the ANIMAL's death stays with them: `roll` moves the RECORD to DEAD
    through `transition`, which means "this animal died OF THIS DISEASE" and is not
    the animal's own dead flag.
]]

RLDiseaseFatality = {}

local Log = RmLogging.getLogger("RLRM")


--- What a fatality roll did, in the first return slot.
---
--- Deliberately NOT the record module's APPLIED / REFUSED / REMOVE trio. A survived
--- roll writes nothing, so `APPLIED` - which that module locked as "a counter write
--- was applied" - would have to stretch to cover a call that wrote nothing, and
--- `REFUSED` would claim the work was declined when it was done.
---
--- `NONE` is spelled the same as the record module's own `TREATMENT_RESULT.NONE`,
--- and the two vocabularies are NEVER fed to each other - the same warning the exit
--- reasons carry against the parser's lowercase authored outcome. This one answers
--- "what did the fatality roll do"; that one answers "what did the treatment advance
--- do".
---
--- Values are identical to their keys, so a log line reads without a reverse map and
--- one object serves as both the key set and the value set.
---
--- READ-ONLY by contract: consumers share this object and there is deliberately no
--- defensive copy.
RLDiseaseFatality.FATALITY_RESULT = {
    ["NONE"] = "NONE",
    ["SURVIVED"] = "SURVIVED",
    ["DIED"] = "DIED"
}


--- The survival probability a `terminal` model's median month count describes.
---
--- `chronicMonthsToDeath` is a MEDIAN, not a span: half of affected animals are dead
--- by that month. So the per-month hazard that reproduces it raises this constant to
--- the reciprocal of the median and subtracts from one, which is what makes the death
--- a geometric tail rather than a deterministic event at the clock boundary.
---
--- Public and read at CALL time through the module table, so a suite can pin it and a
--- deliberate break can move it. A code constant on every peer, never persisted and
--- never sent over the wire.
RLDiseaseFatality.CHRONIC_SURVIVAL_AT_MEDIAN = 0.5


--- The authored per-MONTH fatality rate for a model, selected by its endpoint.
---
--- A CLOSED dispatch on `model.endpoint`, read through `RLDiseaseRecord.ENDPOINT` at
--- CALL time rather than against lowercase literals, so this module declares none of
--- the four names and the vocabulary keeps one home.
--- @param model table|nil A parsed model entry. TRUSTED INTERNAL input; a nil or
---        non-table returns 0 rather than raising.
--- @return number monthly A per-month probability, or 0 for a model this module
---         cannot price
function RLDiseaseFatality.monthlyHazard(model)
    if type(model) ~= "table" then return 0 end

    local ENDPOINT = RLDiseaseRecord.ENDPOINT
    local endpoint = model.endpoint

    if endpoint == ENDPOINT.terminal then
        local median = model.chronicMonthsToDeath

        -- BEFORE any division, and that order is the whole point. `not (median > 0)`
        -- catches zero, a negative and a NaN in one test; forming the reciprocal above
        -- it would emit an engine error line plus a callstack in-game for a value the
        -- upstream non-negative read accepts.
        --
        -- Returning 1 makes "a median of zero months means death on the first roll" a
        -- DECLARED rule rather than one inferred from raising a half to infinity.
        if not (median > 0) then
            return 1
        end

        -- An infinite median gives a reciprocal of 0, and a half raised to 0 is 1, so
        -- the hazard is 0 and the disease never kills. Declared here rather than left
        -- to fall out of the arithmetic, for the same reason as the guard above.
        if median == math.huge then
            return 0
        end

        return 1 - RLDiseaseFatality.CHRONIC_SURVIVAL_AT_MEDIAN ^ (1 / median)
    end

    -- The three non-terminal endpoints are listed EXPLICITLY rather than reached by
    -- an `else`. A fifth endpoint added later then refuses below instead of silently
    -- inheriting `caseFatality`, which for `terminal` already means something
    -- different.
    if endpoint == ENDPOINT.recovers
        or endpoint == ENDPOINT.lifelong
        or endpoint == ENDPOINT.cureOnly then
        return model.caseFatality
    end

    Log:debug("RLDiseaseFatality.monthlyHazard: refused an unrecognised endpoint=%s "
        .. "- returning a hazard of 0 rather than inheriting caseFatality",
        tostring(endpoint))

    return 0
end


--- The per-tick hazard for one animal against one model.
---
--- Scales the MONTHLY rate by the animal's vulnerability, rejects a zero, negative or
--- NaN product outright, clamps the rest to 1, and converts last.
---
--- NOT "non-finite": a positive infinity passes the guard and clamps to certain death,
--- deliberately. See the header for why the two non-finite values want opposite answers.
--- @param model table|nil A parsed model entry. TRUSTED INTERNAL input.
--- @param vulnerability number The animal's factor, as `RLDiseaseVulnerability.factor`
---        returns it. TRUSTED INTERNAL input - a nil RAISES on the multiply,
---        deliberately, before any other arithmetic.
--- @param daysPerPeriod number Ticks in one period. TRUSTED INTERNAL input - a nil
---        RAISES inside the rate primitive. Read it at call time; never cache it.
--- @return number pTick The per-tick probability, 0 where the guard rejected the product
--- @return number monthly The monthly rate the hazard was derived from, so a caller
---         can log it without recomputing
function RLDiseaseFatality.perTickHazard(model, vulnerability, daysPerPeriod)
    local monthly = RLDiseaseFatality.monthlyHazard(model)

    -- The multiply is FIRST, so a nil vulnerability raises here rather than reaching
    -- the conversion. Still a per-MONTH quantity at this point.
    local scaled = monthly * vulnerability

    -- ONE inverted comparison rejecting zero, a negative product AND a NaN. Written
    -- this way rather than the plain `<= 0` because every comparison against NaN is
    -- false, so the plain form would pass a NaN straight through to the fold below -
    -- and a NaN in that fold's first slot yields 1, which would launder a meaningless
    -- product into certain death. This is also what makes the two runtimes agree: the
    -- sibling vulnerability module's floor propagates a NaN under one and returns 0
    -- under the other, and both land here on a hazard of 0.
    if not (scaled > 0) then
        return 0, monthly
    end

    -- The fold's argument order is INERT, because the guard above has already
    -- excluded every NaN. It is a clamp and nothing else.
    return RLDiseaseRates.perTick(math.min(scaled, 1), daysPerPeriod), monthly
end


--- Roll one tick's fatality for an infectious record, moving it to DEAD on a hit.
---
--- The hazard is computed BEFORE the draw, so a nil `vulnerability` or
--- `daysPerPeriod` raises with the generator uncalled.
---
--- Achieved is a draw strictly BELOW the hazard, never at it, which is what makes a
--- hazard of 0 never fire and a hazard of 1 always fire against a generator whose
--- range excludes 1.
--- @param record table|nil A record from `RLDiseaseRecord.new`. TRUSTED INTERNAL
---        input; a nil or non-table returns NONE rather than raising.
--- @param model table|nil The parsed model entry for that record's disease. A nil or
---        `false` model - the ordinary conditional-and idiom yields `false` - returns
---        NONE.
--- @param vulnerability number The animal's factor. TRUSTED INTERNAL input.
--- @param daysPerPeriod number Ticks in one period. TRUSTED INTERNAL input.
--- @param rng function|nil A zero-argument generator returning a value at or above 0
---        and below 1, defaulting to `math.random`. A TRUSTED INTERNAL TEST SEAM, the
---        same shape the dealer quality model, the genetics draw and the treatment
---        advance already use. Production passes nothing.
--- @return string result A FATALITY_RESULT value - NONE when nothing was rolled,
---         SURVIVED or DIED when it was
--- @return number hazard The per-tick probability used, 0 on every refusal
function RLDiseaseFatality.roll(record, model, vulnerability, daysPerPeriod, rng)
    local RESULT = RLDiseaseFatality.FATALITY_RESULT

    if type(record) ~= "table" then return RESULT.NONE, 0 end
    if type(model) ~= "table" then return RESULT.NONE, 0 end

    -- ONE guard covering all four other STATE values and any unrecognised one an
    -- older codec might produce. Only a symptomatic record rolls.
    if record.state ~= RLDiseaseRecord.STATE.INFECTIOUS then
        Log:trace("RLDiseaseFatality.roll: refused title=%s - state is %s, not INFECTIOUS",
            tostring(record.title), tostring(record.state))

        return RESULT.NONE, 0
    end

    rng = rng or math.random

    local hazard, monthly = RLDiseaseFatality.perTickHazard(model, vulnerability, daysPerPeriod)
    local draw = rng()
    local result = RESULT.SURVIVED

    if draw < hazard then
        -- The record's own state machine owns this write; the ANIMAL's death belongs
        -- to the caller, which reads DIED and drives it. A hit the transition refused
        -- would report as a miss, but the pair is unconditional and the state guard
        -- above already proved the record is INFECTIOUS, so that arm is unreachable.
        if RLDiseaseRecord.transition(record, RLDiseaseRecord.STATE.DEAD)
            == RLDiseaseRecord.APPLIED then
            result = RESULT.DIED
        end
    end

    -- TRACE for the per-roll line and DEBUG only for a death, and the split is by
    -- FREQUENCY rather than by taste. `roll` fires per infectious record per tick.
    --
    -- BE PRECISE ABOUT WHAT THE LEVEL BUYS, because the obvious reading is wrong: Lua
    -- evaluates a call's arguments before the logger ever sees the level, so the seven
    -- `tostring()` calls below are paid at TRACE exactly as they would be at DEBUG,
    -- and at every level including OFF. What TRACE buys is the FORMATTING and the
    -- EMISSION, plus keeping the default development view readable - not the argument
    -- evaluation. Anyone wanting that cost gone needs a level check around the call,
    -- not a lower level on it.
    --
    -- The death line is DEBUG because a death is rare and is the line a player's "my
    -- healthy cow died" report needs; there the emission cost is the point of paying it.
    Log:trace("RLDiseaseFatality.roll: title=%s endpoint=%s monthly=%s vulnerability=%s "
        .. "hazard=%s draw=%s result=%s",
        tostring(record.title), tostring(model.endpoint), tostring(monthly),
        tostring(vulnerability), tostring(hazard), tostring(draw), tostring(result))

    if result == RESULT.DIED then
        Log:debug("RLDiseaseFatality.roll: title=%s DIED - hazard=%s draw=%s",
            tostring(record.title), tostring(hazard), tostring(draw))
    end

    return result, hazard
end


-- THREE SITES LOG HERE: the load line, `roll`'s off-INFECTIOUS refusal, and `roll`'s
-- own per-roll and death pair. The two rate functions are silent, and the enumeration
-- below says why.
--
-- `monthlyHazard` branches four ways and logs only the refusal, because the other
-- three arms are a pure function of one field the caller already holds and can name
-- itself. The refusal is different: it is the one arm reachable from a record whose
-- endpoint a later mod version retired, and without a line that record prices at 0
-- forever with nothing in the log to say so.
--
-- `perTickHazard` is straight-line arithmetic with one guard, and the guard's whole
-- output - the hazard - is already carried on `roll`'s TRACE line beside the inputs
-- that produced it, so a line inside it would repeat what its only caller reports. The
-- two type guards on `roll` are silent for the reason both appliers on the record
-- module are: a non-table has no title to name.
--
-- ONE RESIDUAL ON THE REFUSAL LINE, stated rather than guarded: it is DEBUG on a path
-- that runs per record per tick, so a single record whose endpoint a later mod version
-- retired emits one line per tick for the life of the save, at the level development
-- rests on. It stays DEBUG because a record silently priced at 0 forever is the worse
-- failure, and it is unreachable from parser output - the parser refuses an
-- unrecognised endpoint outright. Whichever slice acquires the first caller owns
-- deciding whether that needs a latch.
Log:info("RLDiseaseFatality loaded")
