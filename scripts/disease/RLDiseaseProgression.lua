--[[
    RLDiseaseProgression.lua
    Advances ONE disease record by ONE tick, composing the locked tick order over the
    pure modules Phase A shipped and adding the two steps Phase A never built.

    IT DECIDES AND IT NEVER APPLIES: the entry points return an instruction plus a
    detail table and touch nothing outside the record they were handed.
      1 stepIncubation  2 stepFatality  3 stepTreatment  4 stepMonth  5 stepImmunity
    The call that SURFACES a record stops after step 1. Natural recovery is a MINIMUM,
    then a per-tick draw at the authored per-month chance.

    ONE CALL IS ONE TICK, AND THE TICK IS DAILY - the delegates already committed to
    it. TWO ENTRY POINTS, ONE BODY: `advance` rolls fatality, `advanceWithoutFatality`
    does not, and the ORDER lives in `runSteps` alone, so the module stays
    SETTING-BLIND. Pure data-in / data-out; the siblings are reached at CALL time.
]]

RLDiseaseProgression = {}

local Log = RmLogging.getLogger("RLRM")


--- What the caller should do with this record now.
---
--- `KEEP` covers every ordinary tick, surfacing and recovery included; `REMOVE` is the
--- immunity expiry, the cue to delete a record that still reads RECOVERED. Spelling
--- collisions with the sibling vocabularies are deliberate; never feed one to another.
--- READ-ONLY by contract.
RLDiseaseProgression.INSTRUCTION = {
    ["NONE"] = "NONE",
    ["KEEP"] = "KEEP",
    ["REMOVE"] = "REMOVE",
    ["DIED"] = "DIED"
}


--- How close to a boundary a counter must land to count as having reached it.
---
--- ABSOLUTE and never a bare equality, measured POST-SAVEGAME: these counters persist as
--- floats, quantised far coarser than in memory. A FIXED tolerance, never a share of the
--- span, so it does not scale with one - it clears the worst persisted residue by about 6x.
--- `RLDiseaseRecord` holds the same value.
RLDiseaseProgression.COMPLETION_EPSILON = 1e-3


--- STEP 1 - advance the hidden window, surfacing the record when it closes.
---@param record table A record from `RLDiseaseRecord.new`.
---@return boolean surfaced True only on the call that made the record symptomatic
function RLDiseaseProgression.stepIncubation(record)
    if record.state ~= RLDiseaseRecord.STATE.EXPOSED then return false end

    local _, surfaced = RLDiseaseRecord.advanceIncubation(record)

    return surfaced
end


--- STEP 2 - roll this tick's fatality for a symptomatic record.
---
--- Reached only through `advance`. The roll moves the record to DEAD itself, which is
--- why the caller's choice is an entry point rather than a discarded return.
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
--- Gated by the CALLER through `ctx.treatmentRunning`: the live object carries a
--- running flag but the eight-key RECORD this module is written against does not, so
--- the flag arrives as call context. Withholding the advance is what pausing means.
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


--- STEP 4 - advance the elapsed month; from the authored minimum on, draw a natural recovery.
---@param record table A symptomatic record.
---@param model table The parsed model entry; with no `durationMonths` nothing is drawn or recovered.
---@param ctx table Carries `daysPerPeriod` and an optional `rng`.
---@return boolean recovered True only on the call that reached RECOVERED
function RLDiseaseProgression.stepMonth(record, model, ctx)
    record.monthsElapsed = record.monthsElapsed + 1 / ctx.daysPerPeriod

    if model.durationMonths == nil then return false end

    if record.monthsElapsed
        < model.durationMonths - RLDiseaseProgression.COMPLETION_EPSILON then
        return false
    end

    -- The minimum is a GATE, never a term in the draw. Past it every call draws once against the
    -- per-tick chance, converted before the draw so a missing chance raises with no draw spent.
    local chance = RLDiseaseRates.perTick(model.recoveryChancePerMonth, ctx.daysPerPeriod)
    local draw = (ctx.rng or math.random)()

    if not (draw < chance) then
        Log:trace("RLDiseaseProgression.stepMonth: no recovery title=%s elapsed=%s minimum=%s "
            .. "chance=%s draw=%s",
            tostring(record.title), tostring(record.monthsElapsed),
            tostring(model.durationMonths), tostring(chance), tostring(draw))

        return false
    end

    -- Asked, then applied, in that order. The gate is currently unfalsifiable - only the
    -- endpoint carrying a minimum also declares this exit legal - and is composed anyway,
    -- because every cell of that table is DECLARED rather than inferred elsewhere.
    if not RLDiseaseRecord.canRecover(record.endpoint,
        RLDiseaseRecord.EXIT_REASON.NATURAL) then
        return false
    end

    if RLDiseaseRecord.transition(record, RLDiseaseRecord.STATE.RECOVERED)
        ~= RLDiseaseRecord.APPLIED then
        return false
    end

    -- Load-bearing, not bookkeeping: `transition` writes only the state, so a record
    -- that recovers unseeded is REMOVED on its very next tick.
    record.immunityMonthsRemaining = model.immunityMonths

    -- The record SURVIVES this exit and stays renderable, so a part-served course left
    -- standing here contradicts the counter's contract. The CURE exit needs no clear -
    -- `advanceTreatment` writes 0 on every completion - and the DEATH exit deliberately
    -- keeps its counters.
    local clearedTreatmentMonths = record.treatmentMonthsRemaining
    record.treatmentMonthsRemaining = 0

    Log:debug("RLDiseaseProgression: recovered naturally title=%s - elapsed %s of minimum %s "
        .. "month(s) at a per-tick chance of %s, seeded immunity at %s month(s), cleared a "
        .. "treatment counter of %s",
        tostring(record.title), tostring(record.monthsElapsed),
        tostring(model.durationMonths), tostring(chance), tostring(model.immunityMonths),
        tostring(clearedTreatmentMonths))

    return true
end


--- STEP 5 - count the immunity window down, asking for removal when it expires.
---
--- Expiry composes through `transition`, which returns REMOVE for this pair WITHOUT
--- writing, so the record is deleted while it still reads RECOVERED.
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

    -- NOT latched, and `stepImmunity` is idempotent at zero, so a caller that queues the
    -- REMOVE instead of deleting the record gets this line again on every tick.
    Log:debug("RLDiseaseProgression: immunity expired title=%s - asking the caller to "
        .. "remove the record", tostring(record.title))

    return true
end


--- The shared body both entry points run. The five-step ORDER lives here and nowhere
--- else, which is what keeps the two entry points from drifting apart.
---
--- `rollsFatality` is a structural consequence of WHICH entry point was called - never a
--- setting, and never reachable from `ctx`.
local function runSteps(record, model, ctx, rollsFatality)
    local INSTRUCTION = RLDiseaseProgression.INSTRUCTION
    local STATE = RLDiseaseRecord.STATE

    -- Built up front and returned by every path below, refusals included, so the shape
    -- is never partially nil. It indexes BOTH siblings ABOVE the type guards, so with
    -- either `source()` line missing even `advance(nil, nil, nil)` raises here.
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
    -- driver did nothing.
    local function finish(instruction)
        Log:trace("RLDiseaseProgression: title=%s instruction=%s surfaced=%s fatality=%s "
            .. "treatment=%s served=%s recovered=%s removed=%s",
            tostring(type(record) == "table" and record.title or nil),
            tostring(instruction), tostring(detail.surfaced), tostring(detail.fatality),
            tostring(detail.treatment), tostring(detail.served),
            tostring(detail.recovered), tostring(detail.removed))

        return instruction, detail
    end

    -- TYPE tests rather than nil tests: `false` is the reachable non-table.
    if type(record) ~= "table" or type(model) ~= "table" or type(ctx) ~= "table" then
        return finish(INSTRUCTION.NONE)
    end

    detail.surfaced = RLDiseaseProgression.stepIncubation(record)

    -- A player can act only between ticks, so the call that makes a record visible stops
    -- here: its first fatality roll, treatment tick and elapsed month all come on the next.
    if detail.surfaced then return finish(INSTRUCTION.KEEP) end

    -- Step 5 belongs to a record that ENTERED recovered. One that recovers later in THIS
    -- call returns before reaching it, which is what keeps a seeded counter exact.
    if record.state == STATE.RECOVERED then
        detail.removed = RLDiseaseProgression.stepImmunity(record, ctx)

        return finish(detail.removed and INSTRUCTION.REMOVE or INSTRUCTION.KEEP)
    end

    -- Still serving its hidden window: step 1 DID advance it, so the no-advance
    -- instruction would misreport this call.
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
            -- Steps 3 to 5 are skipped and both counters keep the values they held.
            -- Nothing ADVANCES a counter on a DEAD record: every applier refuses a
            -- non-INFECTIOUS record, and the state gate above returns NONE for DEAD.
            return finish(INSTRUCTION.DIED)
        end
    end

    detail.treatment, detail.served =
        RLDiseaseProgression.stepTreatment(record, model, ctx)

    if detail.treatment == RLDiseaseRecord.TREATMENT_RESULT.CURED then
        -- The delegate composed its own recovery but does NOT seed the counter, and an
        -- unseeded recovery is removed on its very next tick. No log line: the delegate
        -- already DEBUGged the completion with the roll, the efficacy and the outcome.
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
---       generator threaded to all three draws so they cannot default independently.
---@return string instruction An INSTRUCTION value
---@return table detail Six fields, always present
function RLDiseaseProgression.advance(record, model, ctx)
    return runSteps(record, model, ctx, true)
end


--- Advance one record by one daily tick WITHOUT rolling fatality.
---
--- The entry point a caller uses when deaths are switched off: no draw is consumed and
--- no record can be written to DEAD. IT CONSUMES ONE DRAW FEWER, so a later test that
--- pins a seeded multi-step outcome must pin the entry point alongside the seed.
---@param record table|nil As `advance`.
---@param model table|nil As `advance`.
---@param ctx table|nil As `advance`, minus `vulnerability`, which is unread here.
---@return string instruction An INSTRUCTION value
---@return table detail Six fields, always present
function RLDiseaseProgression.advanceWithoutFatality(record, model, ctx)
    return runSteps(record, model, ctx, false)
end


Log:info("RLDiseaseProgression loaded")
