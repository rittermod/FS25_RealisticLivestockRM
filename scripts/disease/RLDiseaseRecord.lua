--[[
    RLDiseaseRecord.lua
    The SEIR record shape, the five-state enum, the legal transitions between them,
    and the appliers that own the incubation and treatment counters. It answers
    "what state is this infection in, and may it move to that one" - never WHEN.

      SUSCEPTIBLE  no record. Expressible so the enum has a `from` and a `to`, but
                   never HELD: `transition` returns REMOVE rather than writing it
      EXPOSED      infected, contagious, INVISIBLE to the player, no production loss
      INFECTIOUS   symptomatic, contagious, production penalty, rolls fatality
      RECOVERED    immune for its window, blocks reinfection, sheds nothing
      DEAD         died OF THIS DISEASE, never "the animal is dead"

    It also answers whether a STORED record still fits its definition. Two rules govern
    one when the definitions change underneath it: a record written in the pre-SEIR
    shape is dropped on load and never migrated, and a record that no longer fits its
    current definition is dropped too. `isAdherent` is the second.

    Pure data-in / data-out - RmLogging is the only dependency, so it dual-runs headless.
]]

RLDiseaseRecord = {}

local Log = RmLogging.getLogger("RLRM")


--- ONE literal for the state the applier must never write, building BOTH the enum
--- entry and the `TRANSITIONS` key and read by `transition`'s REMOVE branch.
---
--- With that branch reading the public `STATE` table while the legality check read a
--- hardcoded key, a runtime edit to `STATE.SUSCEPTIBLE` would make them disagree and
--- the applier would WRITE the one state a record may never hold.
local SUSCEPTIBLE = "SUSCEPTIBLE"


--- The five states. Values are identical to their keys, so a log line reads with no
--- reverse map and one object is both the key set and the value set.
--- READ-ONLY by contract: consumers share this object.
RLDiseaseRecord.STATE = {
    [SUSCEPTIBLE] = SUSCEPTIBLE,
    ["EXPOSED"] = "EXPOSED",
    ["INFECTIOUS"] = "INFECTIOUS",
    ["RECOVERED"] = "RECOVERED",
    ["DEAD"] = "DEAD"
}


--- The states in WIRE ORDER, and the reverse map a stream read resolves through.
---
--- APPEND-ONLY: the INDEX is what crosses the wire, so inserting or reordering a name
--- reinterprets every record in flight as a different state, and a retired state keeps
--- its slot. One array with the map DERIVED from it, never two hand-written tables.
--- READ-ONLY by contract, exactly like `STATE`.
RLDiseaseRecord.STATE_WIRE_ORDER = {
    SUSCEPTIBLE,
    "EXPOSED",
    "INFECTIOUS",
    "RECOVERED",
    "DEAD"
}

RLDiseaseRecord.STATE_WIRE_ORDINAL = {}

for ordinal, state in ipairs(RLDiseaseRecord.STATE_WIRE_ORDER) do
    RLDiseaseRecord.STATE_WIRE_ORDINAL[state] = ordinal
end


--- The four endpoint names - what ends a disease's INFECTIOUS phase, and their one home.
---
--- `RLDiseaseDefinition` READS them from here at FILE SCOPE, so `RLDiseaseRecord.lua`
--- MUST be sourced before it, in `main.lua` and in the headless env alike. The wrong
--- order raises on a nil global in-game and is INVISIBLE headless, where the harness
--- sources this module from its own env. READ-ONLY by contract, like `STATE`.
RLDiseaseRecord.ENDPOINT = {
    ["recovers"] = "recovers",
    ["terminal"] = "terminal",
    ["lifelong"] = "lifelong",
    ["cureOnly"] = "cureOnly"
}


--- Why an INFECTIOUS record is leaving that state.
---
--- NOT the parser's `<treatment outcome>` vocabulary, and the two must never be fed to
--- each other: that one is lowercase and says what a course ACHIEVES. The mapping
--- between them has one home, `advanceTreatment`, and `CURE` means a course that
--- completed AND whose efficacy roll succeeded.
RLDiseaseRecord.EXIT_REASON = {
    ["NATURAL"] = "NATURAL",
    ["CURE"] = "CURE"
}


--- The three outcomes of an attempted transition. Three rather than a boolean,
--- because the immunity-expiry pair is legal AND must not be written: a truthy
--- APPLIED would leave the record at a state it may not hold, and REFUSED would
--- strand it forever.
RLDiseaseRecord.APPLIED = "APPLIED"
RLDiseaseRecord.REFUSED = "REFUSED"
RLDiseaseRecord.REMOVE = "REMOVE"


--- The hidden window's floor, in ticks - every disease hides for at least one tick and
--- no difficulty scale can remove it. Public and read at CALL time so a suite can pin
--- it; a code constant on every peer, never persisted and never sent.
RLDiseaseRecord.MIN_INCUBATION_TICKS = 1


--- What a treatment advance did to the course, in the second return slot.
---
--- It exists because two completions are indistinguishable by the record alone - a
--- failed cure and a completed relief both leave it INFECTIOUS with the counter at 0.
--- `NONE` on every refusal, so the slot is never nil. READ-ONLY by contract.
RLDiseaseRecord.TREATMENT_RESULT = {
    ["NONE"] = "NONE",
    ["ADVANCED"] = "ADVANCED",
    ["CURED"] = "CURED",
    ["RELIEVED"] = "RELIEVED",
    ["FAILED"] = "FAILED"
}


--- How close to zero the treatment counter must land to count as completed.
---
--- ABSOLUTE, never relative and never a bare `<= 0`: the counter accumulates
--- `1 / daysPerPeriod` subtractions, so completion lands on float noise either side of
--- zero, and a bare `<= 0` over-serves about half of all authored courses by a tick.
RLDiseaseRecord.TREATMENT_COMPLETION_EPSILON = 1e-9


--- The legal transitions, as a closed table rather than a chain of conditionals -
--- exactly five ordered pairs out of the twenty-five. Exposed for the suite's
--- locked-constants tripwire ONLY; `canTransition` is the supported read.
RLDiseaseRecord.TRANSITIONS = {
    -- Reached by CONSTRUCTION, never by an applied transition; the pair is legal so
    -- the enum's `from` slot has a member.
    [SUSCEPTIBLE] = { ["EXPOSED"] = true },
    -- Incubation elapses and the animal becomes symptomatic.
    ["EXPOSED"] = { ["INFECTIOUS"] = true },
    -- Recovery or a completed cure, and disease fatality. Both stay UNCONDITIONAL:
    -- the endpoint constraint on the first lives in `canRecover`, beside this table.
    ["INFECTIOUS"] = { ["RECOVERED"] = true, ["DEAD"] = true },
    -- Immunity expires. Returns REMOVE and writes nothing.
    ["RECOVERED"] = { [SUSCEPTIBLE] = true },
    -- Terminal.
    ["DEAD"] = {}
}


--- May an INFECTIOUS record reach RECOVERED, per endpoint and per exit reason?
---
--- ONE ROW PER ENDPOINT, the all-false row included: a missing row and an empty row
--- both return false, so without it the "declared, never inferred" claim is untestable.
--- Every `false` is DECLARED, including the cells the parser already refuses to
--- produce. READ-ONLY by contract, like `STATE` and `TRANSITIONS`.
RLDiseaseRecord.RECOVERY_EXITS = {
    -- The authored span ends it naturally, and a completed cure ends it early.
    ["recovers"] = { ["NATURAL"] = true, ["CURE"] = true },
    -- No span is authorable, so the hazard is the only NATURAL end - but a completed,
    -- successful course beats the death clock.
    ["terminal"] = { ["NATURAL"] = false, ["CURE"] = true },
    -- Nothing ends it; the animal sheds for life.
    ["lifelong"] = { ["NATURAL"] = false, ["CURE"] = false },
    -- The defining shape: no span, and a completed cure is the only exit.
    ["cureOnly"] = { ["NATURAL"] = false, ["CURE"] = true }
}


--- Is this ordered pair of states a legal transition?
---
--- Takes exactly TWO arguments as a contract: the exit rule landed beside this
--- predicate rather than inside it, so no arm here reads `endpoint`.
--- @param from string|nil A STATE value. TRUSTED INTERNAL input - not validated; an
---        unrecognised value, nil or NaN is refused rather than raising.
--- @param to string|nil A STATE value. TRUSTED INTERNAL input - same handling.
--- @return boolean legal True only for the five legal ordered pairs
function RLDiseaseRecord.canTransition(from, to)
    -- Bind the row FIRST. The lookup indexes twice, and an unrecognised `from` yields
    -- nil here - indexing that with `to` is what would raise.
    local row = RLDiseaseRecord.TRANSITIONS[from]

    -- A TYPE test, not `row == nil`: a malformed row that is neither nil nor a table
    -- makes the second index raise, and the never-raise property is meant to be total.
    if type(row) ~= "table" then return false end

    -- `== true` so the return is a strict boolean and no caller can come to depend on
    -- a truthy table value.
    return row[to] == true
end


--- May an INFECTIOUS record reach RECOVERED for this reason?
---
--- Answers an ENDPOINT question, not a TREATABILITY one: `canRecover("recovers",
--- "CURE")` is true for a model declaring no `<treatment>` at all. It takes neither a
--- record nor a source state, so composing it with `transition` is the caller's job.
--- @param endpoint string|nil An `ENDPOINT` value. TRUSTED INTERNAL input - not
---        validated; an unrecognised value, nil, `false` or NaN is REFUSED.
--- @param reason string|nil An `EXIT_REASON` value. TRUSTED INTERNAL input - same
---        handling. NOT the parser's lowercase treatment `outcome`.
--- @return boolean mayRecover True only for the four legal (endpoint, reason) cells
function RLDiseaseRecord.canRecover(endpoint, reason)
    -- Membership-first, the same shape and the same reason as `canTransition`.
    local row = RLDiseaseRecord.RECOVERY_EXITS[endpoint]
    local mayRecover = type(row) == "table" and row[reason] == true

    if not mayRecover then
        -- TWO MESSAGES, and the split IS the diagnostic: a declared `false` cell is the
        -- rule working, while a value in no vocabulary is a wiring bug or a record
        -- carrying a name a later mod version retired. One shared message would make a
        -- stale endpoint read exactly like `lifelong` behaving correctly.
        if RLDiseaseRecord.ENDPOINT[endpoint] == nil
            or RLDiseaseRecord.EXIT_REASON[reason] == nil then
            Log:debug("RLDiseaseRecord.canRecover: refused an UNRECOGNISED value - "
                .. "endpoint=%s reason=%s (the reason vocabulary is EXIT_REASON, "
                .. "never the parser's lowercase treatment outcome)",
                tostring(endpoint), tostring(reason))
        else
            Log:debug("RLDiseaseRecord.canRecover: refused endpoint=%s reason=%s (declared)",
                tostring(endpoint), tostring(reason))
        end
    end

    return mayRecover
end


--- Why a stored record no longer fits the definition it names.
---
--- READ-ONLY by contract, like `STATE`, so a caller field-compares a reason rather
--- than matching a message.
RLDiseaseRecord.ADHERENCE_REASON = {
    ["NO_RECORD"] = "NO_RECORD",
    ["NO_MODEL"] = "NO_MODEL",
    ["UNKNOWN_STATE"] = "UNKNOWN_STATE",
    ["ANIMAL_TYPE"] = "ANIMAL_TYPE",
    ["TREATMENT_GONE"] = "TREATMENT_GONE",
    ["UNREACHABLE_STATE"] = "UNREACHABLE_STATE"
}


--- Does this stored record still fit the definition its title resolves to?
---
--- A record whose state a re-authored model can no longer produce is dropped, never
--- repaired - it holds no history to repair from. The check ORDER is declared, because
--- a record can fail two conditions and the reason drives the caller's tally.
--- @param record table|nil The `Disease` object - eight record keys grafted flat plus
---        `treatmentRunning`. TRUSTED INTERNAL input; nothing here raises.
--- @param model table|nil The parsed `<model>` entry. The endpoint is read from HERE.
--- @param animalTypeName string|nil Uppercase type name, nil when unresolvable.
--- @return boolean adherent True when the record still fits the model
--- @return string|nil reason An `ADHERENCE_REASON` value, nil when adherent
function RLDiseaseRecord.isAdherent(record, model, animalTypeName)
    local REASON = RLDiseaseRecord.ADHERENCE_REASON

    -- TYPE tests throughout, as in the appliers: `false` is the reachable non-table.
    if type(record) ~= "table" then return false, REASON.NO_RECORD end
    if type(model) ~= "table" then return false, REASON.NO_MODEL end

    -- `state` is the one field a save can carry outside the enum - the codec reads it
    -- with a default and validates nothing - and every applier then refuses it forever.
    if RLDiseaseRecord.STATE[record.state] == nil then
        return false, REASON.UNKNOWN_STATE
    end

    -- An EMPTY list skips too, and that half is the one worth stating: the parser drops a
    -- disease resolving no type, so neither shape is reachable - but an empty list would
    -- otherwise match nothing and drop every record on every animal.
    if animalTypeName ~= nil and type(model.animals) == "table" and #model.animals > 0 then
        local bound = false

        for i = 1, #model.animals do
            if model.animals[i] == animalTypeName then
                bound = true
                break
            end
        end

        if not bound then return false, REASON.ANIMAL_TYPE end
    end

    -- Gated on INFECTIOUS because nothing clears the running flag at a cure, so a
    -- recovered and immune animal legitimately still carries it.
    if record.state == RLDiseaseRecord.STATE.INFECTIOUS then
        local remaining = record.treatmentMonthsRemaining
        local midCourse = (type(remaining) == "number" and remaining > 0)
            or record.treatmentRunning == true

        if midCourse and type(model.treatment) ~= "table" then
            return false, REASON.TREATMENT_GONE
        end
    end

    -- Reads `RECOVERY_EXITS` rather than naming `lifelong`, so a fifth endpoint
    -- inherits the rule.
    if record.state == RLDiseaseRecord.STATE.RECOVERED then
        local exits = RLDiseaseRecord.RECOVERY_EXITS[model.endpoint]
        local reachable = type(exits) == "table"
            and (exits[RLDiseaseRecord.EXIT_REASON.NATURAL] == true
                or exits[RLDiseaseRecord.EXIT_REASON.CURE] == true)

        if not reachable then return false, REASON.UNREACHABLE_STATE end
    end

    return true, nil
end


--- Apply a transition to a record. The ONLY writer of `record.state`.
--- @param record table|nil A record from `new`. TRUSTED INTERNAL input; a nil
---        record returns REFUSED rather than raising.
--- @param to string|nil The destination STATE.
--- @return string outcome APPLIED | REFUSED | REMOVE - three distinct values, never
---         a boolean
function RLDiseaseRecord.transition(record, to)
    -- A TYPE test rather than `record == nil`, because reading `record.state` off a
    -- non-table raises and `false` is the reachable case (`hasIt and t[title]`).
    if type(record) ~= "table" then return RLDiseaseRecord.REFUSED end

    if not RLDiseaseRecord.canTransition(record.state, to) then
        -- The ONE diagnostic in this module, and it earns its place: a record whose
        -- `state` is not in the enum is refused forever - it can never advance, never
        -- die and never be removed - and without this line it is invisible.
        Log:debug("RLDiseaseRecord.transition: refused %s -> %s (title=%s)",
            tostring(record.state), tostring(to), tostring(record.title))

        return RLDiseaseRecord.REFUSED
    end

    -- The one legal pair that must not be WRITTEN; deleting the record is the animal's
    -- job. Compared against the file-local literal that also built the TRANSITIONS key.
    if to == SUSCEPTIBLE then
        return RLDiseaseRecord.REMOVE
    end

    record.state = to

    return RLDiseaseRecord.APPLIED
end


--- Build a fresh record at EXPOSED, carrying exactly eight keys.
---
--- THE RATES ARE NOT COPIED - case fatality, r0, the immunity length, the cull flag
--- and the duration pair stay on the model, so there is one authority per authored
--- number and the key set is identical for every endpoint. `endpoint` is the one
--- model-derived value that IS copied, because later branches need it with no model.
--- @param model table A parsed `<model>` entry. `archetype` and `endpoint` are
---        guaranteed present by the definition parser. TRUSTED INTERNAL input - a
---        shipped file read back by the mod that ships it is an internal caller, so
---        nothing here is validated.
--- @param title string The disease title. The parser's `models` map is KEYED by
---        title and writes no `title` field, so this arrives as a parameter.
--- @return table record A fresh record at EXPOSED, carrying exactly eight keys
function RLDiseaseRecord.new(model, title)
    return {
        -- `archetype` is carried VERBATIM and never gated: the parser owns that
        -- vocabulary's warning, and a second gate would split it across two files.
        ["title"] = title,
        ["archetype"] = model.archetype,
        ["endpoint"] = model.endpoint,

        ["state"] = RLDiseaseRecord.STATE.EXPOSED,

        -- All four counters start at 0, never nil - a nil would drop the key and give
        -- the endpoint shapes different key sets. Two are advanced in this file;
        -- `monthsElapsed` and `immunityMonthsRemaining` belong to later slices.
        ["incubationTicksRemaining"] = 0,
        ["monthsElapsed"] = 0,
        ["treatmentMonthsRemaining"] = 0,
        ["immunityMonthsRemaining"] = 0
    }
end


--- Floor an ALREADY-SCALED tick count into the hidden window's smallest legal length.
---
--- The VALUE goes first and the constant second: measured, a NaN in the first slot
--- returns the other operand under both runtimes, while a NaN second is kept by one
--- and discarded by the other. Do not swap it, and do not align it with the sibling
--- vulnerability module, which uses the opposite order on purpose.
--- @param ticks number Tick count, already scaled by the caller. TRUSTED INTERNAL
---        input - not validated; a nil RAISES, deliberately, since a missing argument
---        is a wiring bug and `seedIncubation` is the applier that guards it.
--- @return number ticks A positive integer for any finite input, never below
---         MIN_INCUBATION_TICKS
function RLDiseaseRecord.incubationTicksFor(ticks)
    return math.max(math.floor(ticks + 0.5), RLDiseaseRecord.MIN_INCUBATION_TICKS)
end


--- Seed a fresh record's hidden window. The ONLY place `incubationTicksRemaining`
--- is written at infection.
---
--- Refuses a record that has left EXPOSED or is already mid-window, because either way
--- re-seeding restarts something.
--- @param record table|nil A record from `new`. TRUSTED INTERNAL input; a nil - or
---        any non-table, `false` being the reachable one - returns REFUSED rather
---        than raising.
--- @param ticks number|nil Tick count, already scaled. Floored by
---        `incubationTicksFor`. A nil returns REFUSED.
--- @return string outcome APPLIED | REFUSED
function RLDiseaseRecord.seedIncubation(record, ticks)
    if type(record) ~= "table" then return RLDiseaseRecord.REFUSED end

    -- A wiring guard against a MISSING argument, not value validation.
    if ticks == nil then return RLDiseaseRecord.REFUSED end

    if record.state ~= RLDiseaseRecord.STATE.EXPOSED then
        return RLDiseaseRecord.REFUSED
    end

    -- Tested against 0 rather than for a positive value, and the difference is not
    -- style: `> 0` RAISES on a nil counter where `~= 0` refuses it, so this shape also
    -- declines a record whose counter is absent instead of writing over it.
    if record.incubationTicksRemaining ~= 0 then
        return RLDiseaseRecord.REFUSED
    end

    record.incubationTicksRemaining = RLDiseaseRecord.incubationTicksFor(ticks)

    return RLDiseaseRecord.APPLIED
end


--- Advance a record's hidden window by one tick, surfacing it when the window ends.
---
--- Decrements FIRST and then tests, so a seed of N yields exactly N advances in
--- EXPOSED, and the decrement is clamped at 0 rather than running negative into a
--- field a codec serializes.
--- @param record table|nil A record from `new`. TRUSTED INTERNAL input; a nil or
---        non-table returns REFUSED rather than raising, as does a record whose
---        counter is absent or non-numeric, since `nil - 1` raises.
--- @return string outcome APPLIED for a bare decrement; on the surfacing call,
---         whatever `transition` returned. REFUSED means the call was DECLINED at a
---         guard and nothing moved, EXCEPT on a refused surfacing, where the tick is
---         already spent and deliberately not restored.
--- @return boolean surfaced true ONLY on the call that moved the record to
---         INFECTIOUS - a strict boolean, never a truthy value
function RLDiseaseRecord.advanceIncubation(record)
    if type(record) ~= "table" then return RLDiseaseRecord.REFUSED, false end

    if record.state ~= RLDiseaseRecord.STATE.EXPOSED then
        return RLDiseaseRecord.REFUSED, false
    end

    local remaining = record.incubationTicksRemaining

    if type(remaining) ~= "number" then
        return RLDiseaseRecord.REFUSED, false
    end

    -- The clamp is the whole reason this is not a bare `remaining - 1`: an unseeded
    -- record sits at 0, one below what a codec's unsigned slot can carry.
    record.incubationTicksRemaining = math.max(remaining - 1, 0)

    if record.incubationTicksRemaining > 0 then
        return RLDiseaseRecord.APPLIED, false
    end

    -- The spent tick is NOT restored on a refusal: a refused surfacing shows the
    -- counter and the state out of step rather than hiding the inconsistency.
    local outcome = RLDiseaseRecord.transition(record, RLDiseaseRecord.STATE.INFECTIOUS)

    return outcome, outcome == RLDiseaseRecord.APPLIED
end


--- Enrol a symptomatic record on a treatment course. The ONLY place
--- `treatmentMonthsRemaining` is written at enrolment.
---
--- REFUSING A RECORD MID-COURSE IS THE PAUSE CONTRACT, not a defensive check: what it
--- prevents is a resume RE-SEEDING the course, so do not "fix" it into a re-seed. `0`
--- does NOT mean "never treatable" - the model's own block answers that.
--- @param record table|nil A record from `new`. TRUSTED INTERNAL input; a nil - or
---        any non-table, `false` being the reachable one - returns REFUSED rather
---        than raising, and returns BEFORE any log line, because there is no title
---        to name.
--- @param treatment table|nil The model's `<treatment>` block, as the definition
---        parser emits it: `months` whole and >= 1, `cost`, `efficacy` in [0, 1],
---        `outcome` in the parser's closed set. A nil or `false` block returns REFUSED.
--- @return string outcome APPLIED | REFUSED
function RLDiseaseRecord.enrolTreatment(record, treatment)
    if type(record) ~= "table" then return RLDiseaseRecord.REFUSED end
    if type(treatment) ~= "table" then return RLDiseaseRecord.REFUSED end

    if record.state ~= RLDiseaseRecord.STATE.INFECTIOUS then
        Log:trace("RLDiseaseRecord.enrolTreatment: refused title=%s - state is %s, not INFECTIOUS",
            tostring(record.title), tostring(record.state))

        return RLDiseaseRecord.REFUSED
    end

    if record.treatmentMonthsRemaining ~= 0 then
        Log:trace("RLDiseaseRecord.enrolTreatment: refused title=%s - a course is already "
            .. "running with %s month(s) left (this refusal IS the resume guard)",
            tostring(record.title), tostring(record.treatmentMonthsRemaining))

        return RLDiseaseRecord.REFUSED
    end

    -- THE ONE THING VALIDATED HERE, and it guards a STRUCTURAL invariant rather than a
    -- value: assigning a nil REMOVES the key, so a block with no `months` would take
    -- the record from eight keys to seven and brick it, while returning APPLIED. `< 1`
    -- rides along because 0 is this module's reserved "no course".
    if type(treatment.months) ~= "number" or treatment.months < 1 then
        Log:trace("RLDiseaseRecord.enrolTreatment: refused title=%s - the block's months is %s, "
            .. "which cannot seed a course", tostring(record.title), tostring(treatment.months))

        return RLDiseaseRecord.REFUSED
    end

    record.treatmentMonthsRemaining = treatment.months

    Log:debug("RLDiseaseRecord.enrolTreatment: enrolled title=%s for %s month(s)",
        tostring(record.title), tostring(treatment.months))

    return RLDiseaseRecord.APPLIED
end


--- Serve one daily tick of a treatment course, resolving it when the course completes.
--- The ONLY decrement of `treatmentMonthsRemaining`.
---
--- Each call serves `1 / daysPerPeriod` months, so a course of N months completes on
--- exactly the `N * daysPerPeriod`-th call at every setting. The efficacy roll fires
--- ONCE per course, on the completing call, composing `canRecover` THEN `transition`.
--- @param record table|nil A record from `new`. TRUSTED INTERNAL input; a nil or
---        non-table returns REFUSED rather than raising, as does a record whose
---        counter is absent or non-numeric.
--- @param treatment table|nil The model's `<treatment>` block. A nil or `false`
---        block returns REFUSED.
--- @param daysPerPeriod number The engine's configured days per period, clamped by
---        the environment to 1..28. TRUSTED INTERNAL input - not validated. A NIL
---        raises on the subtraction, deliberately, and the subtraction precedes every
---        write, so the counter and the roll are untouched when it does.
--- @param rng function|nil A zero-argument generator returning `[0, 1)`, defaulting
---        to `math.random`. A TRUSTED INTERNAL TEST SEAM; production passes nothing.
--- @return string outcome APPLIED | REFUSED
--- @return string result A TREATMENT_RESULT value - NONE on every refusal, ADVANCED
---         on a bare decrement, and CURED | RELIEVED | FAILED on the completing call
function RLDiseaseRecord.advanceTreatment(record, treatment, daysPerPeriod, rng)
    local RESULT = RLDiseaseRecord.TREATMENT_RESULT

    if type(record) ~= "table" then return RLDiseaseRecord.REFUSED, RESULT.NONE end
    if type(treatment) ~= "table" then return RLDiseaseRecord.REFUSED, RESULT.NONE end

    if record.state ~= RLDiseaseRecord.STATE.INFECTIOUS then
        -- A record that left INFECTIOUS with a course running keeps its counter, and
        -- this refusal is what makes that stale value inert rather than harmful.
        Log:trace("RLDiseaseRecord.advanceTreatment: refused title=%s - state is %s, "
            .. "not INFECTIOUS", tostring(record.title), tostring(record.state))

        return RLDiseaseRecord.REFUSED, RESULT.NONE
    end

    local remaining = record.treatmentMonthsRemaining

    if type(remaining) ~= "number" then
        Log:trace("RLDiseaseRecord.advanceTreatment: refused title=%s - the counter is a %s, "
            .. "not a number", tostring(record.title), type(remaining))

        return RLDiseaseRecord.REFUSED, RESULT.NONE
    end

    if remaining == 0 then
        -- `0` is "no course", never "complete now".
        Log:trace("RLDiseaseRecord.advanceTreatment: refused title=%s - no course is running",
            tostring(record.title))

        return RLDiseaseRecord.REFUSED, RESULT.NONE
    end

    rng = rng or math.random

    -- Ahead of every write and ahead of the roll, so a nil `daysPerPeriod` raises with
    -- the record and the generator untouched.
    local served = remaining - 1 / daysPerPeriod

    if served > RLDiseaseRecord.TREATMENT_COMPLETION_EPSILON then
        record.treatmentMonthsRemaining = served

        Log:trace("RLDiseaseRecord.advanceTreatment: served a tick of title=%s, %s month(s) left",
            tostring(record.title), tostring(served))

        return RLDiseaseRecord.APPLIED, RESULT.ADVANCED
    end

    -- THE DISPATCH RESOLVES FIRST AND THE COUNTER IS WRITTEN AFTER IT: the comparison
    -- below RAISES on a block with no `efficacy`, and resolving first leaves the counter
    -- where the caller left it rather than destroying a part-served course. Every path
    -- that RETURNS still passes through the write, so the course is over however it
    -- resolves and a FAILED roll is re-enrollable with no separate reset path.
    local roll = rng()
    local result, cause

    if roll >= treatment.efficacy then
        result, cause = RESULT.FAILED, "roll"
    elseif treatment.outcome == "relief" then
        -- Relief eases the symptoms and clears nothing, so the record stays
        -- INFECTIOUS and `canRecover` is never asked - relief is not an exit.
        result, cause = RESULT.RELIEVED, "relief"
    elseif treatment.outcome == "cure" then
        if RLDiseaseRecord.canRecover(record.endpoint, RLDiseaseRecord.EXIT_REASON.CURE) then
            if RLDiseaseRecord.transition(record, RLDiseaseRecord.STATE.RECOVERED)
                == RLDiseaseRecord.APPLIED then
                result, cause = RESULT.CURED, "cure"
            else
                -- UNREACHABLE BY CONSTRUCTION - the pair is unconditional and the entry
                -- guard already proved the record is INFECTIOUS - and kept so the
                -- dispatch cannot fall off its end with a nil result.
                result, cause = RESULT.FAILED, "transition"
            end
        else
            -- The endpoint refuses this exit; `canRecover` logs its own refusal.
            result, cause = RESULT.FAILED, "endpoint"
        end
    else
        -- The else arm of a CLOSED dispatch rather than a guard: the parser refuses an
        -- outcome outside its own set, so this needs a hand-built block to reach.
        result, cause = RESULT.FAILED, "outcome"
    end

    -- The course is over however it resolved, and this is the one write that ends it.
    record.treatmentMonthsRemaining = 0

    -- The one line a player's "my treatment failed" report needs: the completion turns
    -- on a roll the caller never sees, unlike every other branch in this module.
    Log:debug("RLDiseaseRecord.advanceTreatment: course complete title=%s roll=%s "
        .. "efficacy=%s outcome=%s result=%s cause=%s",
        tostring(record.title), tostring(roll), tostring(treatment.efficacy),
        tostring(treatment.outcome), tostring(result), cause)

    return RLDiseaseRecord.APPLIED, result
end


Log:info("RLDiseaseRecord loaded")
