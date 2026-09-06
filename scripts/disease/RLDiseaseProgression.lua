--[[
    RLDiseaseProgression.lua
    The one home for advancing ONE disease record by ONE tick - the driver that composes
    the locked tick order over the pure modules Phase A already shipped and adds the two
    steps Phase A never built.

    IT DECIDES AND IT NEVER APPLIES. The entry points return an instruction plus a detail
    table and touch nothing outside the record they were handed: no record is deleted,
    nothing is killed, no farm is charged. Same shape the spread pass already ships - a
    pure pass returns what it decided and a caller applies it.

    ONE CALL IS ONE TICK, AND THE TICK IS DAILY. Not a choice this module makes: its
    delegates already committed to it. `advanceTreatment` serves `1 / daysPerPeriod`
    months per call, and the per-tick hazard converts through `RLDiseaseRates.perTick`,
    whose header states that the pen ticks daily. A driver invoked once per PERIOD would
    stretch every course to `N * daysPerPeriod` months and cut realised fatality by
    roughly `daysPerPeriod`x. The ticket's "per-month" names the MODEL's clock, never the
    call rate.

    FIVE STEPS, EACH ITS OWN FUNCTION, COMPOSED STRAIGHT-LINE:

      1  stepIncubation  advance the hidden window, surfacing a record
      2  stepFatality    the fatality roll                                  [A7]
      3  stepTreatment   the treatment advance, when a course is running    [A6]
      4  stepMonth       the elapsed-months advance and natural recovery    [new]
      5  stepImmunity    the immunity countdown, expiry asking for removal  [new]

    Only 4 and 5 are new logic; 1 to 3 are composition. Each step is public and takes only
    what it needs. The ORDER lives in `runSteps` and nowhere else.

    THE STEPS ARE PUBLIC BUT UNGUARDED, and the suite currently drives NONE of them
    directly - every row goes through an entry point. Only `stepIncubation` pre-tests the
    state, so calling `stepMonth` on a DEAD record still advances its counter and
    `stepImmunity` on an INFECTIOUS one still decrements immunity. That is safe as long as
    `runSteps` stays the only caller, which it is. Read the surface as "nine symbols AC-1
    pins" rather than as an invitation: a step reached from outside `runSteps` is outside
    the state machine's guarantees.

    TWO ENTRY POINTS, ONE BODY. `advance` rolls fatality; `advanceWithoutFatality` does
    not. A caller with deaths off calls the second. Three properties follow, and the third
    decided the shape:

      the module stays SETTING-BLIND - handed no flag, no preset, no collaborator, and it
      never learns why it was called one way or the other;

      the five-step order is written ONCE, in the shared body, so the two entry points
      cannot drift apart;

      there is nothing injected to type-check. An earlier revision took the roll as
      `ctx.fatalityRoll`, and the natural caller idiom for deaths-off -
      `deathEnabled and RLDiseaseFatality.roll` - yields `false`, which `~= nil` admits and
      then calls. Removing the seam removes that failure mode outright rather than
      guarding it.

    SKIPPING RATHER THAN IGNORING IS THE POINT. The roll moves the record to DEAD inside
    the pure module BEFORE returning, so a caller cannot roll-and-discard with deaths off -
    that would leave a record at DEAD on a living host. Hence an entry point rather than a
    result the caller filters.

    IT WRITES THE NATURAL COMPOSITION ONLY. `canRecover` has exactly one other caller -
    inside `advanceTreatment`, on the cure reason - and the archive locks that as the
    single home of the authored-outcome to exit-reason mapping. This module never maps an
    authored outcome, never passes that reason, and never re-implements the cure exit.

    SEEDING THE IMMUNITY COUNTER AT THE RECOVERY EXIT IS LOAD-BEARING, not bookkeeping.
    `transition` writes only the state and the counter starts at 0, so a record that
    recovers unseeded is REMOVED on its very next tick and the recovered-and-immune state
    never exists at runtime. BOTH exits seed it - the natural span and the completed cure.

    STEP 5 DOES NOT RUN ON THE CALL THAT RECOVERED. A straight-line reading would run the
    countdown against the counter step 4 has just seeded, leaving it short by
    `1 / daysPerPeriod` on every recovery, turning a model authoring zero immunity into an
    immediate removal, and shifting every expiry index by one.

    MONEY STAYS WITH THE CALLER. This module reports that a treatment tick was SERVED and
    never computes a currency amount. `served` is true on every call that decremented the
    counter, COMPLETIONS INCLUDED, because that is the tick the caller bills.

    THE DETAIL TABLE IS BUILT COMPLETE BEFORE THE GUARDS and returned fully populated on
    every path, refusals included - the contract the spread pass's stats table already
    carries, so no caller nil-checks a field. Its two result fields carry the SIBLING
    modules' own constants, read at call time; no third copy of either vocabulary.

    THE INSTRUCTION NAMES COLLIDE WITH THREE EXISTING VOCABULARIES, deliberately and
    harmlessly, and are NEVER fed to each other. `REMOVE` also names a transition outcome;
    `NONE` also names a treatment result and a fatality result; `DIED` also names a
    fatality result. This one answers "what should the caller do with this record now".

    Pure data-in / data-out: no GUI, no XML, no engine natives, no metatable, and no
    reference to the host. RmLogging at file scope is the only load-time dependency;
    `RLDiseaseRecord` and `RLDiseaseFatality` are reached at CALL time, which is why this
    file's position in the loader is ordinary rather than required.

    SHARP EDGES, named so the next reader does not rediscover them.

      nil daysPerPeriod   RAISES, matching the two sibling modules' deliberate loudness -
                          a wiring bug should be loud. Two qualifications, because the
                          flat statement is wrong in both directions. It does not raise
                          BEFORE any write: step 1 takes no `daysPerPeriod`, so a record
                          may already have decremented its window and surfaced when the
                          raise happens. And it does not raise on every record: only
                          steps 4 and 5 read the value, so an EXPOSED record that stays
                          in its window, and any record already refused at the state
                          guard, both return cleanly and never reach the read. A caller
                          ticking an entirely pre-symptomatic pen runs silent.
      nil vulnerability   RAISES inside the roll's multiply, exactly as A7 documents.
                          Reachable only through `advance`, on a symptomatic record.

    `daysPerPeriod` is otherwise TRUSTED as an integer in 1..28 and is deliberately not
    range-checked. Be accurate about WHY, because the shorter reason is half true: the
    setting is bounded to 1..28 where a player changes it, but a value restored from a
    savegame is not re-bounded on the way in, so an edited save can present anything. The
    engine derives its own per-day fraction from the same number and carries the identical
    exposure. An edited save is not a design driver here (portfolio rule 10), so the value
    is trusted anyway - NOT because nothing can produce a bad one. The same over-claim sits
    in `RLDiseaseRates`' header and is tracked for correction there.

    Nothing calls this module yet. The slice that wires the pen's daily path adopts it,
    supplies the clock and the vulnerability factor, and owns the money and the host's own
    death call.
]]

RLDiseaseProgression = {}

local Log = RmLogging.getLogger("RLRM")


--- What the caller should do with this record now.
---
--- A FOURTH closed vocabulary beside the record module's outcome trio, its treatment
--- results and the fatality results; the header says why the spelling collisions are
--- harmless. This one is about the RECORD's fate, not what one delegate did.
---
--- `NONE` means nothing was advanced. `KEEP` covers every ordinary tick - a hidden window
--- ticking down, surfacing, and recovery included. `REMOVE` is the immunity expiry, the
--- caller's cue to delete a record that still reads RECOVERED. `DIED` is the fatality hit,
--- and the record is already at DEAD when it is returned.
---
--- Values are identical to their keys, so a log line reads without a reverse map.
--- READ-ONLY by contract, like every sibling vocabulary in this subsystem.
RLDiseaseProgression.INSTRUCTION = {
    ["NONE"] = "NONE",
    ["KEEP"] = "KEEP",
    ["REMOVE"] = "REMOVE",
    ["DIED"] = "DIED"
}


--- How close to a boundary a counter must land to count as having reached it.
---
--- ABSOLUTE, never relative, and never a bare equality: both counters this module writes
--- accumulate `1 / daysPerPeriod` steps, which is not exactly representable for most
--- settings, so the residue at the boundary is float noise either side of it.
---
--- DECLARED HERE rather than reaching for the record module's treatment epsilon, whose
--- name describes a treatment course. The cost is two constants that must move together,
--- documented at this site only.
---
--- IT IS AN IN-MEMORY TOLERANCE, and it is the right size for that job: the worst plain
--- accumulation residue over dpp 1..28 x target 1..24 is 3.3e-13, three orders inside it.
---
--- IT IS NOT THE SIZE OF THE PERSISTENCE ERROR, and the two must not be conflated. A
--- counter crossing a save boundary is quantised far more coarsely than this value, so a
--- reload can cost one extra tick - always late, never early. Measured on `monthsElapsed`
--- at a mid-accumulation value: Float32 (the stream half) is 40x this epsilon at 1 month
--- and 1635x by 48; a 7-significant-digit decimal write (the savegame half) is 333x to
--- 3333x over the same range.
---
--- The ratio GROWS with the counter, which is why A6's measured figure does not transfer.
--- Float32 holds a fixed RELATIVE precision, so absolute error scales with magnitude - and
--- `treatmentMonthsRemaining` counts DOWN toward zero (small values, tiny error) while this
--- counter counts UP without bound. The "about 10x" figure measured for the treatment
--- counter was correct for that counter and wrong here. The treatment counter's own half of
--- this is tracked separately.
---
--- Public and read at CALL time, so a suite can pin it and a deliberate break can move it.
--- A code constant on every peer, never persisted and never sent over the wire.
RLDiseaseProgression.COMPLETION_EPSILON = 1e-9


--- STEP 1 - advance the hidden window, surfacing the record when it closes.
---
--- The state pre-test keeps the delegate's refusal off the per-tick path. Note what that
--- does NOT buy, because the obvious reason is wrong: `advanceIncubation` logs nothing on
--- any path, so there is no TRACE here to suppress.
---@param record table A record from `RLDiseaseRecord.new`.
---@return boolean surfaced True only on the call that made the record symptomatic
function RLDiseaseProgression.stepIncubation(record)
    if record.state ~= RLDiseaseRecord.STATE.EXPOSED then return false end

    local _, surfaced = RLDiseaseRecord.advanceIncubation(record)

    return surfaced
end


--- STEP 2 - roll this tick's fatality for a symptomatic record.
---
--- Reached only through `advance`; `advanceWithoutFatality` never calls it. The roll moves
--- the record to DEAD itself, which is why the caller's choice is an entry point rather
--- than a discarded return. The roll's second return is the hazard, for logging, and is
--- deliberately dropped - `roll` already TRACEs it beside the inputs that produced it.
---@param record table A symptomatic record.
---@param model table The parsed model entry for this record's disease.
---@param ctx table Carries `vulnerability`, `daysPerPeriod` and an optional `rng`.
---@return string result A `RLDiseaseFatality.FATALITY_RESULT` value
function RLDiseaseProgression.stepFatality(record, model, ctx)
    return (RLDiseaseFatality.roll(record, model, ctx.vulnerability,
        ctx.daysPerPeriod, ctx.rng))
end


--- STEP 3 - serve one tick of a running treatment course.
---
--- Gated by the CALLER through `ctx.treatmentRunning`. Be exact about why, because the
--- short version is wrong: the live object DOES carry a running flag - `Disease.new`
--- assigns it as the ninth key and both codecs round-trip it - but the eight-key RECORD
--- this module is written against does not, so the flag arrives as call context.
--- Withholding the advance is exactly what pausing means, and the served months survive
--- because nothing else writes the counter down.
---@param record table A symptomatic record.
---@param model table The parsed model entry; its `treatment` block may be absent.
---@param ctx table Carries `treatmentRunning`, `daysPerPeriod` and an optional `rng`.
---@return string result A `RLDiseaseRecord.TREATMENT_RESULT` value
---@return boolean served True when this call decremented the counter, completions included
function RLDiseaseProgression.stepTreatment(record, model, ctx)
    local RESULT = RLDiseaseRecord.TREATMENT_RESULT

    if not ctx.treatmentRunning then return RESULT.NONE, false end

    local outcome, result = RLDiseaseRecord.advanceTreatment(record, model.treatment,
        ctx.daysPerPeriod, ctx.rng)

    -- APPLIED covers the bare decrement AND all three completions - the tick the caller
    -- bills. A refusal (no course, an untreatable model) served nothing.
    return result, outcome == RLDiseaseRecord.APPLIED
end


--- STEP 4 - advance the elapsed month and resolve a natural recovery.
---
--- This is the counter Phase A declared and nobody advanced. A model with no authored span
--- forms no comparison at all: the two clockless endpoints carry no duration attribute, so
--- such a record never recovers naturally.
---@param record table A symptomatic record.
---@param model table The parsed model entry; `durationMonths` may be absent.
---@param ctx table Carries `daysPerPeriod`.
---@return boolean recovered True only on the call that reached RECOVERED
function RLDiseaseProgression.stepMonth(record, model, ctx)
    record.monthsElapsed = record.monthsElapsed + 1 / ctx.daysPerPeriod

    if model.durationMonths == nil then return false end

    if record.monthsElapsed
        < model.durationMonths - RLDiseaseProgression.COMPLETION_EPSILON then
        return false
    end

    -- Asked, then applied, in that order - the composition the record module's header
    -- names as the caller's job. The gate is currently unfalsifiable, because only the
    -- endpoint carrying a span also declares this exit legal; it is composed anyway
    -- because every cell of that table is DECLARED rather than inferred elsewhere.
    if not RLDiseaseRecord.canRecover(record.endpoint,
        RLDiseaseRecord.EXIT_REASON.NATURAL) then
        return false
    end

    if RLDiseaseRecord.transition(record, RLDiseaseRecord.STATE.RECOVERED)
        ~= RLDiseaseRecord.APPLIED then
        return false
    end

    record.immunityMonthsRemaining = model.immunityMonths

    Log:debug("RLDiseaseProgression: recovered naturally title=%s - elapsed %s of %s "
        .. "month(s), seeded immunity at %s month(s)",
        tostring(record.title), tostring(record.monthsElapsed),
        tostring(model.durationMonths), tostring(model.immunityMonths))

    return true
end


--- STEP 5 - count the immunity window down, asking for removal when it expires.
---
--- The decrement clamps at 0 and is tested AFTER, mirroring the incubation counter's
--- shape. Expiry composes through `transition`, the only writer of the state, which
--- returns REMOVE for this pair WITHOUT writing - a record never holds the susceptible
--- state, so it is deleted while it still reads RECOVERED.
---@param record table A recovered record.
---@param ctx table Carries `daysPerPeriod`.
---@return boolean removed True only on the call that expired the window
function RLDiseaseProgression.stepImmunity(record, ctx)
    record.immunityMonthsRemaining =
        math.max(record.immunityMonthsRemaining - 1 / ctx.daysPerPeriod, 0)

    if record.immunityMonthsRemaining > RLDiseaseProgression.COMPLETION_EPSILON then
        return false
    end

    if RLDiseaseRecord.transition(record, RLDiseaseRecord.STATE.SUSCEPTIBLE)
        ~= RLDiseaseRecord.REMOVE then
        return false
    end

    Log:debug("RLDiseaseProgression: immunity expired title=%s - asking the caller to "
        .. "remove the record", tostring(record.title))

    return true
end


--- The shared body both entry points run. The five-step ORDER lives here and nowhere else,
--- which is what keeps the two entry points from drifting apart.
---
--- `rollsFatality` is a structural consequence of WHICH entry point was called - never a
--- setting, and never reachable from `ctx`.
local function runSteps(record, model, ctx, rollsFatality)
    local INSTRUCTION = RLDiseaseProgression.INSTRUCTION
    local STATE = RLDiseaseRecord.STATE

    -- Built up front and returned by every path below, refusals included, so the shape is
    -- never partially nil.
    --
    -- It indexes BOTH siblings above the type guards, so the "never raises on bad input"
    -- promise holds only while both modules are loaded: with either `source()` line
    -- missing, even `advance(nil, nil, nil)` raises here instead of returning NONE. That
    -- is a loader defect, not an input one, and the surface gate in the suite checks only
    -- this module - but the two facts sit far enough apart to be worth stating together.
    local detail = {
        ["surfaced"] = false,
        ["fatality"] = RLDiseaseFatality.FATALITY_RESULT.NONE,
        ["treatment"] = RLDiseaseRecord.TREATMENT_RESULT.NONE,
        ["served"] = false,
        ["recovered"] = false,
        ["removed"] = false
    }

    -- ONE trace per call, on every return path including the refusals, so a walkthrough
    -- always has an unconditional line rather than one that vanishes exactly when the
    -- driver did nothing. Same shape the spread pass ships.
    local function finish(instruction)
        Log:trace("RLDiseaseProgression: title=%s instruction=%s surfaced=%s fatality=%s "
            .. "treatment=%s served=%s recovered=%s removed=%s",
            tostring(type(record) == "table" and record.title or nil),
            tostring(instruction), tostring(detail.surfaced), tostring(detail.fatality),
            tostring(detail.treatment), tostring(detail.served),
            tostring(detail.recovered), tostring(detail.removed))

        return instruction, detail
    end

    -- TYPE tests rather than nil tests: `false` is the reachable non-table, since the
    -- ordinary `local x = hasIt and t[k]` idiom yields it.
    if type(record) ~= "table" or type(model) ~= "table" or type(ctx) ~= "table" then
        return finish(INSTRUCTION.NONE)
    end

    detail.surfaced = RLDiseaseProgression.stepIncubation(record)

    -- Step 5 belongs to a record that ENTERED recovered. One that recovers later in THIS
    -- call returns before reaching it, which is what keeps a seeded counter exact.
    if record.state == STATE.RECOVERED then
        detail.removed = RLDiseaseProgression.stepImmunity(record, ctx)

        return finish(detail.removed and INSTRUCTION.REMOVE or INSTRUCTION.KEEP)
    end

    -- Still serving its hidden window: step 1 DID advance it, so the no-advance
    -- instruction would misreport this call. The one non-symptomatic exit that is not a
    -- refusal, which is why it is tested apart from the terminal below.
    if record.state == STATE.EXPOSED then
        return finish(INSTRUCTION.KEEP)
    end

    -- DEAD, and any value a later codec revision retires, stop here having advanced
    -- nothing.
    if record.state ~= STATE.INFECTIOUS then
        return finish(INSTRUCTION.NONE)
    end

    if rollsFatality then
        detail.fatality = RLDiseaseProgression.stepFatality(record, model, ctx)

        if detail.fatality == RLDiseaseFatality.FATALITY_RESULT.DIED then
            -- Steps 3 to 5 are skipped and both counters keep the values they held. A
            -- record at DEAD never outlives the tick that wrote it.
            return finish(INSTRUCTION.DIED)
        end
    end

    detail.treatment, detail.served =
        RLDiseaseProgression.stepTreatment(record, model, ctx)

    if detail.treatment == RLDiseaseRecord.TREATMENT_RESULT.CURED then
        -- The delegate composed its own recovery but does NOT seed the counter, and an
        -- unseeded recovery is removed on its very next tick. No log line here: the
        -- completion is already DEBUGged by the delegate that resolved it, carrying the
        -- roll, the efficacy and the outcome.
        record.immunityMonthsRemaining = model.immunityMonths

        return finish(INSTRUCTION.KEEP)
    end

    detail.recovered = RLDiseaseProgression.stepMonth(record, model, ctx)

    return finish(INSTRUCTION.KEEP)
end


--- Advance one record by one daily tick, rolling this tick's fatality.
---@param record table|nil A record from `RLDiseaseRecord.new`. TRUSTED INTERNAL input; a
---       nil or non-table returns NONE rather than raising.
---@param model table|nil The parsed model entry for this record's disease. Same handling.
---@param ctx table|nil `{ daysPerPeriod, vulnerability, treatmentRunning, rng }`. Same
---       handling. `treatmentRunning` is the caller's flag; `rng` is a zero-argument
---       generator threaded to BOTH delegates so they cannot default independently.
---@return string instruction An INSTRUCTION value
---@return table detail Six fields, always present
function RLDiseaseProgression.advance(record, model, ctx)
    return runSteps(record, model, ctx, true)
end


--- Advance one record by one daily tick WITHOUT rolling fatality.
---
--- The entry point a caller uses when deaths are switched off. Step 2 does not happen, so
--- no draw is consumed and no record can be written to DEAD; every other step runs exactly
--- as through `advance`. `ctx.vulnerability` is unread on this path.
---
--- IT CONSUMES ONE DRAW FEWER, so with deaths off the treatment efficacy roll reads the
--- generator one position earlier and every later stochastic outcome in that tick shifts.
--- The Design Notes reject a `vulnerability = 0` deaths-off shape partly for burning a draw
--- and displacing the sequence; skipping the call has the mirror-image property, and it is
--- accepted rather than overlooked. Nothing in the mod reproduces a seeded sequence across
--- a settings change, so the shift is unobservable in play - but a future test that pins a
--- seeded multi-step outcome must pin the entry point alongside the seed.
---@param record table|nil As `advance`.
---@param model table|nil As `advance`.
---@param ctx table|nil As `advance`, minus `vulnerability`.
---@return string instruction An INSTRUCTION value
---@return table detail Six fields, always present
function RLDiseaseProgression.advanceWithoutFatality(record, model, ctx)
    return runSteps(record, model, ctx, false)
end


-- FOUR SITES LOG HERE: the load line, the two DEBUG transitions, and the one TRACE per
-- call. The enumeration below says why there are not more.
--
-- Two of the three delegates TRACE their own refusals - `advanceTreatment` and the fatality
-- roll - so an echo here would double every line on the busiest path this subsystem has.
-- That volume is what the record module's closing note warns the slice acquiring the first
-- caller about. The third, `advanceIncubation`, logs nothing at all on any path, so there
-- is simply nothing to echo - a different reason for the same silence, worth not
-- conflating.
--
-- The two DEBUG lines are the transitions a player's report needs explaining: a case that
-- got better on its own, and one whose immunity ran out. Both are decisions this module
-- makes rather than reports, and neither value is reconstructable by the caller without
-- re-resolving the model.
--
-- ONLY THE FIRST IS SELF-LIMITING. Natural recovery fires once, because the RECOVERED
-- branch never re-enters step 4. The expiry line is NOT latched: `stepImmunity` is
-- idempotent at zero, so a caller that returns REMOVE to a queue instead of deleting the
-- record gets the same line again on every tick, indefinitely. Its frequency is the
-- CALLER's property, not this module's - the slice that wires the pen must delete promptly.
--
-- The per-call TRACE carries the instruction and all six detail fields - the whole of what
-- the call decided. It fires on every return path including refusals, so a walkthrough
-- never has to distinguish "the driver did nothing" from "it was never called".
--
-- Be precise about what the level buys, because the obvious reading is wrong: Lua evaluates
-- a call's arguments before the logger sees the level, so the eight conversions on that
-- line are paid at TRACE exactly as they would be at DEBUG, and at every level including
-- OFF. What TRACE buys is the formatting, the emission and a readable default view - never
-- the argument evaluation.
Log:info("RLDiseaseProgression loaded")
