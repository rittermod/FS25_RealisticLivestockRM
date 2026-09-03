--[[
    RLDiseaseTransmission.lua
    The one home for turning an authored R0 into the per-tick probability a
    susceptible animal rolls against one shedding disease.

    R0 IS THE AUTHORED PARAMETER AND THE MONTHLY RATE IS DERIVED. R0 is
    dimensionless, comparable to published figures, and stable across period
    lengths; the per-month transmission rate that realises it depends on how long
    a case actually sheds, which depends on the tick size. Storing the rate
    instead would make the authored number mean something different at every
    days-per-period setting, which is the defect this design removes.

    WHY `beta x months` IS THE AUTHORED R0, AND IN WHICH LIMIT. The model is
    frequency-dependent, so one index case in a pen of N faces N - 1 susceptibles,
    each at a monthly probability of `beta x (1/N)`. Expected secondary cases per
    month is therefore `beta x (N-1)/N`, and over the case's contagious window it
    is `beta x months x (N-1)/N`. Setting the LARGE-POPULATION limit of that equal
    to the authored R0 gives `beta = R0 / months`.

    STATE THAT LIMIT RATHER THAN ROUNDING IT AWAY: `(N-1)/N` is not 1. Measured, it
    is 0.975 in a forty-animal pen and 0.5 in a pen of two, so the realised R0 runs
    slightly under the authored figure in any real pen and materially under it in a
    tiny one. That is the standard frequency-dependent convention and it is the
    reading this module implements; whether the slice that walks the pen should
    correct for a finite population is that slice's decision, not this one's.

    THE WINDOW IS SHORTER THAN THE AUTHORED DURATION, because a case that dies
    stops shedding. Under a flat monthly hazard `h` the expected time in the phase
    is `(1 - (1-h)^D) / -ln(1-h)` over a finite span `D`, and `1 / -ln(1-h)` over
    an unbounded one. Measured: footAndMouth's authored two months yields
    1.8811998468783131.

    THE CAP IS DISEASE-LEVEL, AND THAT IS THE OPPOSITE READING FROM THE
    VULNERABILITY MODULE'S AGE TERM. That module bounds its frailty curve by the
    ANIMAL's own species lifespan, because frailty is a property of the animal.
    This one takes the shortest-lived AFFECTED species, because the question here
    is how long a case CAN shed and a disease shared by chickens and cows cannot
    shed for longer in a chicken than a chicken lives. Both are correct for their
    own question and the two are not interchangeable. That a cow's case is then
    bounded by a chicken's lifespan is the design's stated conservative bound.

    EXPOSED SHEDS. The hidden window counts in full toward the contagious months -
    the state table makes an exposed animal infected and contagious, just
    invisible. The schema carries no per-disease "sheds while exposed" attribute
    and this module does not invent one.

    `incubationTicks` ARRIVES AS A PARAMETER, NOT OFF THE MODEL. The count an
    animal actually serves is the authored value after the difficulty preset's
    scale and the record module's floor, and neither composition is readable from
    a pure module. Passing the authored attribute is correct only at a 1x preset;
    at any other, the realised R0 would drift from the authored one silently.

    THE COMPOSITION ORDER IS THE CONTRACT. Prevalence multiplies the MONTHLY rate
    and the per-tick conversion happens LAST:

        beta    = r0 / contagiousMonths        -- per MONTH
        monthly = beta * prevalence            -- still per MONTH
        pTick   = perTick(min(monthly, 1), daysPerPeriod)

    Converting first and scaling second makes cumulative risk depend on the
    player's days-per-period setting, which is the defect the two-clocks design
    exists to remove: compounding `perTick(m * p, n)` over `n` ticks returns
    `m * p` at every `n`, while compounding `perTick(m, n) * p` returns a value
    that moves with `n`.

    TWO INVERTED GUARDS DO THE WORK, and neither is a fold. `not (monthly > 0)`
    rejects a zero rate, a negative product and a NaN in one test; `not (raw > 0)`
    does the same for the shedding window BEFORE it is capped. The plain `<= 0`
    form catches none of the NaN case, because every comparison against a NaN is
    false in both directions - and a fold cannot serve as the filter in either
    order. Measured: `math.min(nan, 144)` is `144`, so an uncaught NaN window
    would launder into a plausible finite one, and `math.min(144, nan)` is `nan`,
    which is the mirror failure. The folds below only ever clamp.

    READ THE FIRST GUARD AS "NON-POSITIVE OR NaN", NEVER AS "NON-FINITE". A
    positive infinity is greater than zero, so it passes and the clamp takes it to
    1: certainty. That is the correct reading of an infinite force of infection,
    not a hole.

    NO UNGUARDED DIVISION BY A VALUE A MODEL, A SAVE OR A CALLER CAN SET TO ZERO.
    There ARE divisions - FOUR sites over THREE divisors - and the property that
    matters is that every divisor is tested by an inverted guard above its first
    use, not that they are absent. Stating it as "no division occurs" would be
    false and, worse, uncheckable, because an edit that reorders a guard would
    still satisfy the sentence.

      incubationTicks / daysPerPeriod   behind `not (daysPerPeriod > 0)`
      r0 / months                       behind `not (months > 0)` and the infinite test
      1 / rate                          behind `not (rate > 0)`
      (1 - (1-h)^span) / rate           behind the same guard

    The third divisor is reachable from AUTHORED data rather than theoretical:
    measured, `-math.log(1 - h)` is exactly `0` for any `h` at or below about
    `5.55e-17` (at `5.6e-17` it is `1.1102230246251565e-16`), and the definition
    parser's probability read accepts `1e-17`. That matters beyond tidiness - the
    engine emits a divide-by-zero script error plus a callstack where LuaJIT is
    silent, so an unguarded division would be invisible to every headless run
    while moving the in-game error-line pin.

    THE ENDPOINT DISPATCH IS CLOSED. One endpoint takes its authored span; the
    other three take an unbounded window; anything else refuses with a DEBUG line
    and a window of zero. An `else` arm would hand a future fifth endpoint a
    window that means something different for it, which is the infer-from-absence
    shape the endpoint vocabulary exists to remove. The per-month fatality rate
    behind that window has exactly one home and it is `RLDiseaseFatality`; nothing
    here re-derives which authored number a given endpoint prices.

    SHARP EDGES, named so the next reader does not rediscover them.

      nil prevalence      RAISES on the multiply, deliberately. A wiring bug
                          should be loud.
      nil incubationTicks RAISES on the division that forms the hidden window.
      nil daysPerPeriod   RAISES on the GUARD comparison, one line ABOVE any
                          arithmetic - not inside the division, which never runs.
      a dpp of zero       returns 0 rather than reaching the rate primitive, and
                          that DIVERGES from the fatality module on the same
                          input, deliberately: that module lets a zero through to
                          the primitive, where the header documents the result as
                          certainty, while this one would form its OWN division
                          one line earlier. Refusing one degenerate value is not
                          the same as owning the 1..28 range bound, which no
                          slice owns.
      an infinite dpp     returns 0 - `1/inf` is 0 and the primitive returns 0 at
                          an infinite tick count. Documented, not guarded.
      the clamp bites     above a monthly rate of 1 the converted rate is pinned
                          to certainty, so the REALISED R0 falls below the
                          authored figure exactly in the high-prevalence regime.
                          Measured: footAndMouth at 28 days per period and full
                          prevalence has an unclamped monthly rate of
                          3.1300306560341782, pinned to 1. AND IT FALLS BY A
                          DIFFERENT AMOUNT AT EACH SETTING, which is the half
                          worth stating: beta grows with the tick count while the
                          clamp does not, so above saturation the realised R0 is
                          2.8812 / 2.2145 / 1.9169 at 1 / 3 / 28 days per period.
                          Inside the clamp the two-clocks invariant holds exactly;
                          above it, the setting is visible again.
      a NaN fatality      degrades to the NON-FATAL case, deliberately unguarded.
                          The parser's probability read refuses only a value
                          outside [0, 1], and both comparisons are false for a
                          NaN, so one can arrive here from an authored file. It
                          then takes the `not (hazard > 0)` arm and sheds the
                          whole span - exactly what a fatality of 0 does - while
                          the fatality module's own guard maps the same NaN to a
                          hazard of 0, so nobody dies of it either. The two
                          modules agree: an unreadable fatality behaves as no
                          fatality. Not guarded because the only actor who can
                          write that file is its author, who finds out at the
                          next launch; a guard would buy authoring ergonomics,
                          not safety.
      a bad cap           `maxLifespanMonths` is NOT validated, and unlike every
                          other degenerate input here it is not merely trusted -
                          it reaches `math.min`'s SECOND slot, which is the
                          argument order that KEEPS a NaN. Measured: a NaN cap
                          returns a NaN window and a negative cap returns the
                          negative value, both from a function documented as
                          returning 0 on every refusal. The guard above the fold
                          tests `raw`, never the cap. Every producer today is
                          `diseaseLifespanMonths`, which returns a positive number
                          or nil, so nothing reaches it - but a caller that
                          computes the bound another way owes its own check.

    Pure data-in / data-out. No `g_*`, no GUI, no XML, no engine natives - and no
    animal, mission or animal-type registry read. RmLogging at file scope is the
    only unconditional dependency; the four sibling disease modules are reached at
    CALL time only, which is why this file's position in the loader is ordinary
    rather than required.

    Nothing calls this module yet. The slice that decides who sheds and who is
    eligible adopts it, and the pen walk that turns a rate into an infection
    belongs to the slices after that.
]]

RLDiseaseTransmission = {}

local Log = RmLogging.getLogger("RLRM")


--- The shortest lifespan among a disease's affected animal types, in months.
---
--- The caller passes the parsed model half's own `animals` array, which the
--- definition parser fills at LOAD with the type NAMES that resolved. So an
--- unresolvable name cannot reach here from parser output at all; the skip and
--- the warning below defend a hand-built fixture.
---
--- An unrecognised type is SKIPPED rather than poisoning the minimum, so the
--- bound is taken over the types that DO resolve and only an all-unknown disease
--- gets none. The alternative - one unknown type making the whole disease
--- unbounded - would let a single map-bridge or pack animal silently switch a
--- shipped disease from bounded to unbounded.
--- @param animalTypeNames table|nil Ordered array of uppercase type NAMES. A nil
---        or non-table returns nil rather than raising.
--- @return number|nil months The smallest lifespan that resolved, or nil when
---         nothing did
function RLDiseaseTransmission.diseaseLifespanMonths(animalTypeNames)
    if type(animalTypeNames) ~= "table" then return nil end

    -- `ipairs` deliberately: the parser builds an ordered array, and a sparse or
    -- hash-keyed table is a caller shape this module does not serve.
    --
    -- BE PRECISE ABOUT WHAT THAT COSTS, because the obvious reading is wrong. A
    -- hole does NOT reliably reach the warning below. Measured: `{[1]="COW",
    -- [3]="CHICKEN"}` returns 240 - CHICKEN's 96, the very bound this function
    -- exists to find, is dropped silently - and a hash-keyed `{COW=true}` walks
    -- nothing at all, so `walked > 0` is false and it returns nil without a word.
    -- The warning covers a walked list that resolved NOTHING, never a truncated
    -- one. Both shapes are caller bugs the parser cannot produce.
    local walked = 0
    local resolved = 0
    local smallest = nil
    local firstUnresolved = nil

    for _, animalTypeName in ipairs(animalTypeNames) do
        walked = walked + 1

        local months = RLDiseaseVulnerability.maxLifespanMonthsFor(animalTypeName)

        if months == nil then
            if firstUnresolved == nil then firstUnresolved = animalTypeName end
        else
            resolved = resolved + 1

            if smallest == nil or months < smallest then
                smallest = months
            end
        end
    end

    -- ONE line, and only for TOTAL failure. A nil bound makes an unbounded
    -- endpoint shed forever, which drives its transmission rate to zero for the
    -- life of the save - a silent loss of a whole disease's spread that would
    -- otherwise have nothing in the log to say so. A PARTIAL miss is the
    -- documented skip above and is not worth a line.
    if walked > 0 and resolved == 0 then
        Log:warning("RLDiseaseTransmission.diseaseLifespanMonths: walked %d type name(s) "
            .. "and resolved none (first was %s) - the disease gets no shedding bound",
            walked, tostring(firstUnresolved))
    end

    return smallest
end


--- The expected number of months a case spends shedding SYMPTOMATICALLY.
---
--- Solves the flat-hazard window over the endpoint's span, then caps it by the
--- disease-level species lifespan so a chronic non-fatal disease yields a finite
--- R0 without inventing a constant.
--- @param model table|nil A parsed model entry. TRUSTED INTERNAL input; a nil or
---        non-table returns 0 rather than raising.
--- @param maxLifespanMonths number|nil The DISEASE-level bound, as
---        `diseaseLifespanMonths` returns it. A nil means no bound at all.
--- @return number months Expected symptomatic months, 0 on every refusal
function RLDiseaseTransmission.expectedSheddingMonths(model, maxLifespanMonths)
    if type(model) ~= "table" then return 0 end

    local ENDPOINT = RLDiseaseRecord.ENDPOINT
    local endpoint = model.endpoint
    local span

    -- CLOSED dispatch, read through the record module's vocabulary at CALL time
    -- rather than against literals, so the four names keep one home. `span` stays
    -- nil for the three endpoints nothing clocks, which the solve below reads as
    -- an unbounded window.
    if endpoint == ENDPOINT.recovers then
        span = model.durationMonths
    elseif endpoint == ENDPOINT.terminal
        or endpoint == ENDPOINT.lifelong
        or endpoint == ENDPOINT.cureOnly then
        span = nil
    else
        Log:debug("RLDiseaseTransmission.expectedSheddingMonths: refused an unrecognised "
            .. "endpoint=%s - returning a window of 0 rather than guessing one",
            tostring(endpoint))

        return 0
    end

    -- The UNSCALED authored rate: the window is a disease-level property, so the
    -- per-animal vulnerability factor does not enter it.
    local hazard = RLDiseaseFatality.monthlyHazard(model)
    local raw

    -- ONE branch chain assigning `raw`, never returning from inside it, so the
    -- guard and the cap below are reached from every arm. That single trailing
    -- fold is structural rather than stylistic: capping inside each arm would put
    -- four folds in this function and make the cap three edits to break instead
    -- of one.
    if hazard >= 1 then
        -- DECLARED rather than inferred. Behaviourally inert - at a hazard of 1
        -- the rate below is infinite and both solve arms compute `x / inf = 0`
        -- anyway - and it stays because the rule should be readable at the
        -- branch, not reconstructed from the arithmetic.
        raw = 0
    elseif not (hazard > 0) then
        raw = span or math.huge
    else
        local rate = -math.log(1 - hazard)

        if not (rate > 0) then
            -- The underflow arm, and it sits ABOVE both divisions on purpose.
            raw = span or math.huge
        elseif span == nil then
            raw = 1 / rate
        else
            raw = (1 - (1 - hazard) ^ span) / rate
        end
    end

    -- The NaN filter, and it must precede the fold. A NaN span parses today (the
    -- parser's non-negative read refuses only a negative), and `math.min` keeps
    -- whichever operand it holds by default - so without this a NaN window would
    -- come back as a plausible finite lifespan.
    if not (raw > 0) then
        Log:trace("RLDiseaseTransmission.expectedSheddingMonths: endpoint=%s hazard=%s "
            .. "span=%s raw=%s -> 0 (non-positive or NaN window)",
            tostring(endpoint), tostring(hazard), tostring(span), tostring(raw))

        return 0
    end

    local capped = math.min(raw, maxLifespanMonths or math.huge)

    Log:trace("RLDiseaseTransmission.expectedSheddingMonths: endpoint=%s hazard=%s "
        .. "span=%s raw=%s cap=%s -> %s",
        tostring(endpoint), tostring(hazard), tostring(span), tostring(raw),
        tostring(maxLifespanMonths), tostring(capped))

    return capped
end


--- The per-MONTH transmission rate that realises the authored R0 at this tick size.
---
--- Adds the hidden window to the symptomatic one, because an exposed animal is
--- already shedding, and converts it at the tick size - incubation is counted in
--- TICKS, not months.
--- @param model table|nil A parsed model entry. TRUSTED INTERNAL input; a nil or
---        non-table returns `0, 0`. Its own guard, not a borrowed one: the
---        window function returning 0 for a non-table still leaves `months`
---        positive for any nonzero incubation, so control would otherwise reach
---        the model's own R0 field.
--- @param maxLifespanMonths number|nil The DISEASE-level shedding bound.
--- @param incubationTicks number The EFFECTIVE tick count an animal serves -
---        the authored value after the difficulty scale and the record module's
---        floor, composed by the caller. TRUSTED INTERNAL input; a nil RAISES.
--- @param daysPerPeriod number Ticks in one period. TRUSTED INTERNAL input - a
---        nil RAISES on the guard below. Read it at call time; never cache it.
--- @return number beta The per-month rate, 0 on every refusal
--- @return number contagiousMonths The window it divided by; 0 where a guard
---         refused before the window was formed
function RLDiseaseTransmission.betaMonthly(model, maxLifespanMonths, incubationTicks, daysPerPeriod)
    if type(model) ~= "table" then return 0, 0 end

    -- NOT the 1..28 range bound, which no slice owns. This refuses exactly the
    -- one value that would make the division below form an `x/0`, and it returns
    -- `0, 0` rather than `0, months` because no window was computed to report.
    if not (daysPerPeriod > 0) then return 0, 0 end

    local months = incubationTicks / daysPerPeriod
        + RLDiseaseTransmission.expectedSheddingMonths(model, maxLifespanMonths)

    if not (months > 0) or months == math.huge then
        Log:trace("RLDiseaseTransmission.betaMonthly: endpoint=%s months=%s -> beta 0 "
            .. "(a zero or infinite window realises no R0)",
            tostring(model.endpoint), tostring(months))

        return 0, months
    end

    local beta = model.r0 / months

    Log:trace("RLDiseaseTransmission.betaMonthly: endpoint=%s ticks=%s dpp=%s months=%s "
        .. "-> beta=%s",
        tostring(model.endpoint), tostring(incubationTicks), tostring(daysPerPeriod),
        tostring(months), tostring(beta))

    return beta, months
end


--- The per-tick probability one susceptible animal rolls against one disease.
---
--- Scales the MONTHLY rate by the pen's prevalence, rejects a zero, negative or
--- NaN product, clamps the rest to 1, and converts LAST.
--- @param model table|nil A parsed model entry. TRUSTED INTERNAL input.
--- @param maxLifespanMonths number|nil The DISEASE-level shedding bound.
--- @param incubationTicks number The EFFECTIVE tick count. TRUSTED INTERNAL input.
--- @param prevalence number The shedding share of the pen. TRUSTED INTERNAL input -
---        a nil RAISES on the multiply. A value above 1 is NOT clamped: the fold
---        below clamps the PRODUCT, so an out-of-domain prevalence passes through
---        untouched whenever `beta * prevalence` stays at or below 1, and is
---        indistinguishable from a legitimate rate.
--- @param daysPerPeriod number Ticks in one period. TRUSTED INTERNAL input.
--- @return number pTick The per-tick probability, 0 on every refusal
--- @return number monthly The CLAMPED monthly rate actually converted - not beta.
---         That is what lets a caller assert the round trip without writing a
---         second copy of the clamp.
function RLDiseaseTransmission.perTickRate(model, maxLifespanMonths, incubationTicks, prevalence, daysPerPeriod)
    local beta = RLDiseaseTransmission.betaMonthly(model, maxLifespanMonths,
        incubationTicks, daysPerPeriod)

    -- The multiply is FIRST, so a nil prevalence raises here rather than reaching
    -- the conversion. Still a per-MONTH quantity at this point.
    local monthly = beta * prevalence

    -- ONE inverted comparison rejecting zero, a negative product AND a NaN. The
    -- measured exception is deliberate: `not (inf > 0)` is FALSE, so an infinite
    -- product is not rejected here - it passes and the fold below takes it to 1,
    -- which is the correct reading of an infinite force of infection.
    if not (monthly > 0) then
        Log:trace("RLDiseaseTransmission.perTickRate: prevalence=%s monthly=%s -> 0 "
            .. "(non-positive or NaN force of infection)",
            tostring(prevalence), tostring(monthly))

        return 0, 0
    end

    -- The fold's argument order is INERT, because the guard above has already
    -- excluded every NaN. It is a clamp and nothing else.
    local clamped = math.min(monthly, 1)
    local pTick = RLDiseaseRates.perTick(clamped, daysPerPeriod)

    Log:trace("RLDiseaseTransmission.perTickRate: prevalence=%s monthly=%s clampBit=%s "
        .. "dpp=%s -> pTick=%s",
        tostring(prevalence), tostring(monthly), tostring(clamped ~= monthly),
        tostring(daysPerPeriod), tostring(pTick))

    return pTick, clamped
end


-- ALL THREE PER-CALL LINES ARE TRACE, and the level is chosen by FREQUENCY rather
-- than by taste. `perTickRate` calls `betaMonthly`, which calls
-- `expectedSheddingMonths`, so once a caller exists all three fire per susceptible
-- per disease per tick - the busiest path in the subsystem.
--
-- BE PRECISE ABOUT WHAT THE LEVEL BUYS, because the obvious reading is wrong: Lua
-- evaluates a call's arguments before the logger ever sees the level, so every
-- `tostring()` below is paid at TRACE exactly as it would be at DEBUG, and at every
-- level including OFF. What TRACE buys is the FORMATTING, the EMISSION and a
-- readable default development view - not the argument evaluation.
--
-- The two REFUSALS are louder on purpose and neither runs per tick in normal play:
-- an unrecognised endpoint is DEBUG because such a record would price at zero
-- forever with nothing in the log to say so, and a disease whose whole type list
-- failed to resolve is WARNING because it loses a mechanic outright. Both are
-- unreachable from parser output.
--
-- NONE of these lines names a title, and that is a property of the input rather
-- than a choice: a parsed model entry carries none, because the title is the key
-- it is stored under.
Log:info("RLDiseaseTransmission loaded")
