--[[
    RLDiseaseRecord.lua
    The one home for the SEIR record shape, the five-state enum, and the legal
    transitions between them.

    A record is built from a parsed `<model>` entry plus the plain data the caller
    already holds. It answers "what state is this infection in, and may it move to
    that one" - nothing about WHEN, which is each later slice's own decision.

    THE FIVE STATES.

      SUSCEPTIBLE  no record
      EXPOSED      infected, contagious, INVISIBLE to the player, no production loss
      INFECTIOUS   symptomatic, contagious, production penalty, rolls fatality
      RECOVERED    immune for its immunity window, blocks reinfection, sheds nothing
      DEAD

    SUSCEPTIBLE IS EXPRESSIBLE BUT NEVER HELD. "No record" is what it means, so no
    record ever carries it. The enum names it anyway so the infection pair has a
    `from` and the immunity-expiry pair has a `to`. `new` returns a record at
    EXPOSED, and `transition(record, "SUSCEPTIBLE")` NEVER writes the state - it
    returns REMOVE, the caller's instruction to delete the record, which belongs to
    the animal rather than to this module. A maintainer who reads the five states as
    five reachable record values will add a sixth transition to "complete" the
    table; there is no sixth.

    DEAD MEANS "THIS ANIMAL DIED OF THIS DISEASE", never "the animal is dead", which
    is why it is reachable only from INFECTIOUS. Death from any other cause is
    already the ANIMAL's property: the animal is flagged dead and queued for removal
    from the cluster system, and its whole disease table goes with it. A
    record-level DEAD covering cull, slaughter or old age would be a second,
    drift-prone copy of a fact the animal owns - the exact double-duty defect this
    record exists to remove. A record is therefore never stranded at a live state,
    because it is deleted with its animal rather than outliving it.

    THE EXIT RULE LIVES BESIDE `canTransition`, NEVER INSIDE IT. `canRecover`
    answers "may an INFECTIOUS record reach RECOVERED for this reason" over two
    DECLARED values - the model's `endpoint` and the reason the record is leaving
    INFECTIOUS - while `TRANSITIONS` stays unconditional and `transition` stays
    ENDPOINT-BLIND. So `canTransition` still takes TWO arguments and its domain is
    5 x 5, not 5 x 5 x 4: do NOT add a third argument here, and do NOT make
    `INFECTIOUS -> RECOVERED` conditional in the table.

    COMPOSING THE TWO IS THE CALLER'S JOB - ask `canRecover`, then `transition` -
    and `advanceTreatment` below is the one place in this module that performs it,
    on the call where a course completes and its efficacy roll succeeds. It is also
    the one place the two vocabularies meet: the parser's lowercase `outcome` is
    mapped to `EXIT_REASON.CURE` there and nowhere else.

    NOTHING ENFORCES THAT ORDER FOR ANY OTHER CALLER, and that is a stated residual
    rather than an oversight. `canRecover` receives neither a record nor a source
    state, so it cannot check where the record is or whether it was asked first; a
    future slice that drives a NATURAL exit inherits the same obligation and the same
    absence of enforcement. Building a gate for callers that do not exist yet buys
    nothing, and the third argument that would express it was weighed and refused.

    THE DECISION IS A PURE PREDICATE, and that shape is deliberate. `canTransition`
    answers the whole question over plain data, so the entire domain is swept by a
    truth table with no fixture and no oracle. A chain of guard clauses inside
    `transition` would be the shape that admits no per-clause proof, because each
    clause rejects what a later one also rejects.

    Pure data-in / data-out. No `g_*`, no GUI, no XML, no engine natives, no
    metatable - RmLogging at file scope is the only dependency, so the module
    dual-runs headless.

    SHARP EDGES, named so the next reader does not rediscover them.

    The transition lookup indexes TWICE, and the FIRST level needs a membership
    guard. A table READ is safe for any key including nil and NaN, so neither
    parameter needs a type check - but an unrecognised `from` yields nil at the
    first level and indexing THAT raises. The row is bound to a local and tested
    before `to` is read. `transition` needs the same shape before it touches
    `record.state`. Nothing here writes a caller-supplied value into a table key,
    which is the one place Lua raises on a NaN.

    THIS MODULE SWALLOWS A WIRING BUG WHERE ITS SIBLING RATE PRIMITIVE RAISES, and
    that inversion is deliberate rather than an oversight. A missing or misspelled
    state returns `false` instead of raising, because the guard above has to exist
    for the legitimate unknown-state case and cannot then tell it apart from a typo.
    The cost is that a mis-wired consumer sees a silent refusal; the mitigation is
    that a refusal is what those consumers assert on anyway.

    THE ENUM IS THE CANONICAL ALLOWLIST AND IS READ-ONLY BY CONTRACT. Later slices
    build a persistence codec and a wire mapping against it, so consumers share the
    object and there is deliberately no defensive copy. Every registry keyed by a
    state - a codec, a wire map, a display map - is part of a state's DEFINITION, so
    adding a sixth state means adding its entry to each; the self-check that makes
    that loud belongs at each registry's own load, not here, because no such
    registry exists yet.

    `STATE`'s values are also its keys. That makes a log line readable with no
    reverse map, makes a stale persisted value greppable, and makes the key set and
    the value set the same object for the allowlist check above.

    `TRANSITIONS` IS EXPOSED FOR A TRIPWIRE ONLY. `canTransition` is the sole
    supported read: the deferred exit rule will not live in a plain `[from][to]`
    cell, so a consumer reading the table directly is reading something that is
    about to stop being the whole answer. It is public the way a test seam is
    public, not the way `STATE` is.

    TWO STATES CARRY NO OUTGOING ROW WORTH REACHING, FOR OPPOSITE REASONS. DEAD has
    none at all, because it is terminal. SUSCEPTIBLE has exactly one - the infection
    pair - and no record ever sits there to use it, because a caller CONSTRUCTS an
    infected record rather than transitioning into one. Both fall out of the table
    naturally and neither needs a special case, which is exactly why a maintainer
    might add one.

    A record carries `endpoint` as its own field, copied at construction rather than
    re-read through a model reference. Re-reading would couple this module to the
    model registry's lifetime, and a record outlives a definition-file reload. It is
    carried VERBATIM and never gated here, because the parser already owns that
    decision - a second gate would split one vocabulary across two files.

    THAT HAZARD IS NOW CLOSED FOR THE ENDPOINT NAMES SPECIFICALLY. `ENDPOINT` below
    is their one home and the parser READS them from it rather than repeating the
    four literals, so there is one spelling rather than two copies that can drift.
    The warning above still governs `archetype`, whose vocabulary remains the
    parser's alone - the two are not symmetrical, and the paragraph headed THE TWO
    CARRIED VOCABULARIES ARE NOT UNGATED FOR THE SAME REASON says why.

    THE TWO CARRIED VOCABULARIES ARE NOT UNGATED FOR THE SAME REASON, and reading
    them as one pair gets the next question wrong. `endpoint` is CLOSED: the parser
    refuses an unrecognised value outright and the model half never reaches this
    module, so every record's endpoint is one of the four by construction.
    `archetype` is OPEN: the parser only WARNS and carries an unrecognised value
    through, so a record genuinely can hold an archetype nothing validated - which
    is deliberate, and is why the constructor's own comment speaks of a warning
    rather than a refusal. Neither is gated here; only one of them could ever
    arrive unrecognised.

    THE INCUBATION COUNTER COUNTS DOWN, AND THE FLOOR IS A PROPERTY OF THE SEED.
    `seedIncubation` is the single place `incubationTicksRemaining` is written at
    infection, and it floors through `incubationTicksFor`, so no difficulty scale
    can drive a hidden window to zero - every disease hides for at least one tick.
    A seed of N yields exactly N advances in EXPOSED, because `advanceIncubation`
    decrements FIRST and then tests. The counter is clamped at 0 and never runs
    negative: a later codec serializes this field, and a negative sentinel in an
    unsigned slot is the defect this record exists to replace.

    THE FLOOR BOUNDS A SCALE, NEVER AN AUTHOR. A disease authored at zero
    incubation means "visible at once", and the infection slice honours that by
    constructing the record straight at INFECTIOUS and never seeding it - so a `0`
    reaching `incubationTicksFor` comes from a difficulty scale applied to a
    NONZERO authored value, which is exactly the case the floor exists to stop. Do
    not add an authored-zero branch here, and do not read the model's authored
    tick count from this module at all.

    THE FOLD PUTS THE VALUE FIRST, AND THAT ORDER IS THE PORTABLE ONE. Every
    comparison against NaN is false in both directions, so `math.max` keeps
    whichever operand its implementation holds by default - measured, a NaN in the
    FIRST slot returns the other operand under both runtimes this module runs on,
    while a NaN in the SECOND slot is kept by one and discarded by the other.
    Value-first is therefore the direction that behaves identically in both. The
    sibling vulnerability module uses the opposite order deliberately, because it
    WANTS a NaN to propagate into a factor that can never fire a roll; this one
    does not, because the result is written into a field a codec serializes. Do
    not "align" the two - they differ on purpose.

    `0` IN THE COUNTER IS AMBIGUOUS, DELIBERATELY, AND THE AMBIGUITY IS BOUNDED. A
    fresh record and a surfaced record both hold `0`, so the counter alone cannot
    say which; `state` is what separates them, and it sits on the same record. An
    unseeded record therefore advances once and surfaces - the same behaviour a
    floor-seeded record has - so a forgotten seed fails SOFT, costing the player
    one tick of visibility rather than producing an instantly-visible animal.

    MORE SHARP EDGES, on the incubation surface specifically. There is no
    validation of the tick VALUE and no NaN guard: every caller is mod code inside
    this subsystem, and the definition parser already refuses a negative authored
    value. What a degenerate input DOES is specified rather than guarded:

      nil ticks   `incubationTicksFor` RAISES (nil + 0.5), deliberately - it is a
                  pure primitive, and a missing argument is a wiring bug that
                  should be loud. `seedIncubation` guards it instead, because that
                  is the applier the infection slice calls. That guard tests for
                  nil ONLY, so a `false` reaching it - the ordinary
                  `local ticks = enabled and authored * scale` idiom - still
                  raises on the arithmetic, where the record guard beside it uses
                  a TYPE test because `false` is its reachable non-table.
      NaN ticks   returns MIN_INCUBATION_TICKS, by the value-first fold above.
      negative    returns MIN_INCUBATION_TICKS. No producer: the parser drops the
                  whole model half on a negative authored value.
      math.huge   returns math.huge - NOT an integer, and `inf - 1 == inf`, so
                  such a record would stay EXPOSED forever. No producer: it needs
                  a non-finite scale. Any finite counter at or above 2^54 behaves
                  the same way, because `n - 1 == n` there.

    TWO RESIDUALS ON THE COUNTER ITSELF, recorded rather than guarded because no
    producer exists yet - a codec and a migration are later slices' work.

    A record whose counter is absent or non-numeric is a PERMANENT zombie: the
    advance refuses it at the type guard and the seed refuses it at the `~= 0`
    guard, so nothing can move it and it stays hidden, contagious and un-surfacing
    for the life of the save. That is a harder failure than the soft one above, and
    the asymmetry is deliberate only in the sense that failing closed beats writing
    over a value a codec produced. Whoever builds that codec owns making it loud.

    An out-of-enum `state` is refused by both appliers at their own state check, so
    neither reaches `transition` - which means the one DEBUG line in this module,
    written precisely so a record frozen at a stale state is not invisible at every
    level, cannot fire on the incubation path. A frozen record is therefore still
    invisible here.

    ROUNDING IS ROUND-HALF-UP (`math.floor(x + 0.5)`), so 2.5 rounds to 3. That is
    observable only under a FRACTIONAL scale, which the advanced percentage
    overrides make reachable; the preset ladder scales by whole numbers.

    THE TREATMENT COURSE RUNS ON THE DAILY TICK, IN WHOLE MONTHS. `enrolTreatment`
    seeds `treatmentMonthsRemaining` from the model's `<treatment>` block and
    `advanceTreatment` is its only decrement, serving `1 / daysPerPeriod` months per
    call so a course of N months completes on exactly the `N * daysPerPeriod`-th
    advance at every setting. That is what the whole-month authoring rule buys, and
    it is why completion compares against an absolute epsilon rather than zero.

    THE ENROL'S REFUSAL OF A NON-ZERO COUNTER IS THE PAUSE CONTRACT, not a defensive
    check. The record carries no running flag, so pausing is the caller withholding
    the advance and the served months survive because nothing else writes the counter
    down; what the refusal prevents is a resume RE-SEEDING the course. Do not "fix"
    it into a re-seed.

    Nothing calls this module yet, and that is still true after the treatment pair:
    it adds two functions and no call site. The infection, progression and fatality
    slices each adopt the module in their own change, and each goes through
    `transition` rather than assigning `record.state`.
]]

RLDiseaseRecord = {}

local Log = RmLogging.getLogger("RLRM")


--- ONE literal for the state the applier must never write, used to build BOTH the
--- enum entry and the `TRANSITIONS` key below, and read by `transition`'s REMOVE
--- branch. The two must not be able to drift: with the branch reading the public
--- `STATE` table while the legality check reads a hardcoded key, a runtime edit to
--- `STATE.SUSCEPTIBLE` makes them disagree and the applier WRITES the one state a
--- record may never hold. `STATE` is public, shared, and read-only by contract
--- only - no freeze, no defensive copy - so the drift is reachable.
local SUSCEPTIBLE = "SUSCEPTIBLE"


--- The five states. Values are identical to their keys - see the header for the
--- three reasons that matters. READ-ONLY by contract: consumers share this object.
RLDiseaseRecord.STATE = {
    [SUSCEPTIBLE] = SUSCEPTIBLE,
    ["EXPOSED"] = "EXPOSED",
    ["INFECTIOUS"] = "INFECTIOUS",
    ["RECOVERED"] = "RECOVERED",
    ["DEAD"] = "DEAD"
}


--- The four endpoint names - what ends a disease's INFECTIOUS phase.
---
--- THIS IS THE ONE HOME FOR THESE NAMES. `RLDiseaseDefinition` reads them from here
--- rather than repeating the four literals, which is what keeps the vocabulary from
--- landing in two files and drifting apart. The dependency runs one way only, and
--- that direction is the load-bearing part of the choice: this module depends on
--- nothing but RmLogging, so it can own a vocabulary the XML-reading parser reads,
--- where the reverse would give the pure, dual-running module a dependency on the
--- parser.
---
--- THE PARSER READS THIS AT FILE SCOPE, so `RLDiseaseRecord.lua` MUST be sourced
--- BEFORE `RLDiseaseDefinition.lua` - in `main.lua` and in the headless env alike.
--- Get that order wrong and the parser's file-scope read raises on a nil global,
--- which is loud in-game and INVISIBLE to the headless harness, because the harness
--- sources the record from its own env regardless of what `main.lua` says.
---
--- Values are identical to their keys, for two of the three reasons `STATE`'s are: a
--- log line readable with no reverse map, and one object serving as both the key set
--- and the value set. The third does not transfer - no endpoint is persisted by this
--- module - so "greppable stale persisted value" is deliberately not among them.
---
--- READ-ONLY by contract, exactly like `STATE`: consumers share this object and
--- there is deliberately no defensive copy.
RLDiseaseRecord.ENDPOINT = {
    ["recovers"] = "recovers",
    ["terminal"] = "terminal",
    ["lifelong"] = "lifelong",
    ["cureOnly"] = "cureOnly"
}


--- Why an INFECTIOUS record is leaving that state.
---
--- NOT the parser's `<treatment outcome>` vocabulary, and the two must never be fed
--- to each other. That one is authored lowercase (`cure` / `relief`) and answers
--- what a completed course ACHIEVES; these are uppercase and answer why a record is
--- EXITING INFECTIOUS. Passing a raw `"cure"` to `canRecover` returns false.
---
--- THE MAPPING BETWEEN THE TWO HAS ONE HOME, and it is `advanceTreatment` - the only
--- function here that holds both a record and a `<treatment>` block. It compares
--- `outcome` against the lowercase literals and passes `CURE` from this table, never
--- the authored word. A second mapping anywhere else is the drift this note exists to
--- prevent; a `relief` course never reaches `canRecover` at all, because relief is
--- not an exit.
---
--- `CURE` means a course that COMPLETED **and** whose efficacy roll SUCCEEDED, never
--- merely one that completed: efficacy is the probability a completed course
--- achieves its outcome, rolled once at completion, with the record staying where it
--- is on failure. This predicate is asked only after that roll succeeds.
---
--- `NATURAL` ships ahead of its consumer deliberately. Nothing calls it today; the
--- progression and fatality slices acquire it when they advance `monthsElapsed`
--- against the authored span. Declaring both reasons now is what makes the table
--- below a complete statement of the rule rather than a CURE-shaped fragment.
RLDiseaseRecord.EXIT_REASON = {
    ["NATURAL"] = "NATURAL",
    ["CURE"] = "CURE"
}


--- The three outcomes of an attempted transition. Three rather than a boolean,
--- because the immunity-expiry pair is legal AND must not be written: collapsing
--- REMOVE into a truthy APPLIED would leave the record alive at a state it may not
--- hold, and collapsing it into REFUSED would strand it forever.
RLDiseaseRecord.APPLIED = "APPLIED"
RLDiseaseRecord.REFUSED = "REFUSED"
RLDiseaseRecord.REMOVE = "REMOVE"


--- The hidden window's floor, in ticks. Every disease hides for at least one tick
--- and no setting can remove it - see the header for the measurement that makes
--- that load-bearing rather than tidy.
---
--- Public and read at CALL time through the module table, so a suite can pin it and
--- a deliberate break can move it. It is a code constant on every peer, never
--- persisted and never sent over the wire.
RLDiseaseRecord.MIN_INCUBATION_TICKS = 1


--- What a treatment advance did to the course, in the second return slot.
---
--- A FIFTH closed vocabulary beside `STATE`, `ENDPOINT`, `EXIT_REASON` and the three
--- outcome constants, and it exists because two completions are indistinguishable by
--- the record alone: a failed cure and a completed relief both leave the record
--- INFECTIOUS with the counter at 0. The caller cannot tell them apart from the
--- record, so the advance says which it was.
---
--- `NONE` on every refusal, so the second slot is never nil - a caller comparing
--- against a constant would otherwise read `nil == nil` and treat a refusal as
--- whichever result it asked about.
---
--- `ADVANCED` is the bare decrement: a tick was served and the course is still
--- running. The other three are terminal for the course, and all three leave the
--- counter at 0.
---
--- Values are identical to their keys, for the same two reasons `ENDPOINT`'s are: a
--- log line readable with no reverse map, and one object serving as both the key set
--- and the value set. Nothing here is persisted or sent, so the third does not apply.
---
--- READ-ONLY by contract, exactly like `STATE` and `ENDPOINT`.
RLDiseaseRecord.TREATMENT_RESULT = {
    ["NONE"] = "NONE",
    ["ADVANCED"] = "ADVANCED",
    ["CURED"] = "CURED",
    ["RELIEVED"] = "RELIEVED",
    ["FAILED"] = "FAILED"
}


--- How close to zero the treatment counter must land to count as completed.
---
--- ABSOLUTE, never relative, and never a bare `<= 0`. The counter accumulates
--- `1 / daysPerPeriod` subtractions, so the residue at completion is float noise
--- either side of zero: measured across every course of 1 to 4 months at every
--- `daysPerPeriod` in 1..28, the worst residue is 7.5e-15, while a bare `<= 0`
--- over-serves 50 of those 112 courses by a whole extra tick. The epsilon therefore
--- sits about five orders above the worst drift an authored course reaches and seven
--- below the smallest tick, so it can neither miss a completion nor swallow a real
--- one.
---
--- Public and read at CALL time through the module table, so a suite can pin it and a
--- deliberate break can move it. A code constant on every peer, never persisted and
--- never sent over the wire.
RLDiseaseRecord.TREATMENT_COMPLETION_EPSILON = 1e-9


--- The legal transitions, as a closed table rather than a chain of conditionals.
--- Exactly five ordered pairs are legal out of the twenty-five; DEAD is terminal
--- and no state transitions to itself.
---
--- Exposed for the suite's locked-constants tripwire ONLY - `canTransition` is the
--- supported read. See the header.
RLDiseaseRecord.TRANSITIONS = {
    -- Reached by CONSTRUCTION, never by an applied transition: the infection slice
    -- calls `new`. The pair is legal so the enum's `from` slot has a member.
    [SUSCEPTIBLE] = { ["EXPOSED"] = true },
    -- Incubation elapses and the animal becomes symptomatic.
    ["EXPOSED"] = { ["INFECTIOUS"] = true },
    -- Recovery or a completed cure, and disease fatality. Both stay UNCONDITIONAL
    -- here: the endpoint constraint on the first lives in `canRecover`, beside this
    -- table rather than inside it, and `testEveryEndpointMayRecover` pins that by
    -- asserting all four endpoints still reach RECOVERED through `transition`.
    ["INFECTIOUS"] = { ["RECOVERED"] = true, ["DEAD"] = true },
    -- Immunity expires. Returns REMOVE and writes nothing - a record never holds
    -- SUSCEPTIBLE.
    ["RECOVERED"] = { [SUSCEPTIBLE] = true },
    -- Terminal.
    ["DEAD"] = {}
}


--- May an INFECTIOUS record reach RECOVERED, per endpoint and per exit reason?
---
--- A closed `[endpoint][reason]` table with ONE ROW PER ENDPOINT, the all-false row
--- included. That row is not padding: a missing row and an empty row both make
--- `canRecover` return false, so without it the "declared, never inferred" claim is
--- untestable and deleting the `lifelong` row outright would leave every assert
--- green. The suite pins this key set against `ENDPOINT` in BOTH directions for
--- exactly that reason.
---
--- Named for its DESTINATION rather than `INFECTIOUS_EXITS`, which would invite a
--- maintainer to add the `DEAD` row the fatality slice owns. Leaving INFECTIOUS for
--- DEAD is `canTransition("INFECTIOUS", "DEAD")` and is not this table's question.
---
--- EVERY `false` IS DECLARED, including the cells the parser already refuses to
--- produce. Inference from an absent attribute is the shape the endpoint vocabulary
--- exists to remove, and the refusals that would justify inferring live in another
--- module: a reader here would have to take them on trust from a file they are not
--- reading, and a future endpoint that forbids a span AND recovers naturally would
--- silently inherit the wrong answer.
---
--- READ-ONLY by contract, like `STATE` and `TRANSITIONS`.
RLDiseaseRecord.RECOVERY_EXITS = {
    -- The authored span ends it naturally, and a completed cure ends it early -
    -- independently of whether any model declares a treatment, which is the model's
    -- business rather than this table's.
    ["recovers"] = { ["NATURAL"] = true, ["CURE"] = true },
    -- No span is authorable, so the hazard is the only NATURAL end - but a completed,
    -- successful course beats the death clock.
    ["terminal"] = { ["NATURAL"] = false, ["CURE"] = true },
    -- Nothing ends it; the animal sheds for life. The parser refuses a curative
    -- treatment on this endpoint, so the CURE cell has no producer - declared here
    -- anyway rather than inferred from a refusal in another file.
    ["lifelong"] = { ["NATURAL"] = false, ["CURE"] = false },
    -- The defining shape: no span, and a completed cure is the only exit.
    ["cureOnly"] = { ["NATURAL"] = false, ["CURE"] = true }
}


--- Is this ordered pair of states a legal transition?
---
--- Takes exactly two arguments, and that is a contract rather than an accident. The
--- exit rule landed BESIDE this predicate rather than inside it, so no arm here
--- reads `endpoint`: a third parameter could not express the exit REASON anyway, and
--- it would grow this sweep from 25 pairs to 100 for a question `canRecover` already
--- answers over 8.
--- @param from string|nil A STATE value. TRUSTED INTERNAL input - not validated; an
---        unrecognised value, nil or NaN is refused rather than raising.
--- @param to string|nil A STATE value. TRUSTED INTERNAL input - same handling.
--- @return boolean legal True only for the five legal ordered pairs
function RLDiseaseRecord.canTransition(from, to)
    -- Bind the row FIRST. The lookup indexes twice, and an unrecognised `from`
    -- yields nil here - indexing that with `to` is what would raise.
    local row = RLDiseaseRecord.TRANSITIONS[from]

    -- A TYPE test, not `row == nil`. The claim "a table read is safe for any key"
    -- is about the KEY and says nothing about the container: a malformed row that
    -- is neither nil nor a table (`["DEAD"] = true` instead of `{}`) makes the
    -- second index raise, and the never-raise property is meant to be total.
    if type(row) ~= "table" then return false end

    -- `== true` rather than the raw cell, so the return is a strict boolean and a
    -- caller cannot come to depend on a truthy table value.
    return row[to] == true
end


--- May an INFECTIOUS record reach RECOVERED for this reason?
---
--- The second pure predicate BESIDE `canTransition`, deliberately not a third
--- argument to it - see that function's doc block for why - and deliberately not a
--- rule left to fall out of the data, which would infer the answer from an ABSENT
--- duration attribute and leave it invisible to a reader and to every test.
---
--- ANSWERS AN ENDPOINT QUESTION, NOT A TREATABILITY ONE. `canRecover("recovers",
--- "CURE")` is true for a model that declares no `<treatment>` at all, and that is
--- correct: whether a curative course EXISTS is the model's business and the
--- parser's, while whether one can END the infectious phase is this predicate's. A
--- caller that never completes a course never asks. Stated because the name invites
--- the other reading.
---
--- Takes neither a record nor a source state, so it cannot check WHERE the record
--- is - the reason is a property of the CALL, not of the record, and the record
--- gains no ninth key for it. The header says who owns composing this with
--- `transition`.
--- @param endpoint string|nil An `ENDPOINT` value. TRUSTED INTERNAL input - not
---        validated; an unrecognised value, nil, `false` or NaN is REFUSED rather
---        than raised on.
--- @param reason string|nil An `EXIT_REASON` value. TRUSTED INTERNAL input - same
---        handling. NOT the parser's lowercase treatment `outcome`.
--- @return boolean mayRecover True only for the four legal (endpoint, reason) cells
function RLDiseaseRecord.canRecover(endpoint, reason)
    -- Membership-first, the same shape as `canTransition` and for the same reason:
    -- the lookup indexes TWICE, an unrecognised endpoint yields nil at the first
    -- level, and indexing THAT with `reason` is what would raise. The TYPE test
    -- rather than `row == nil` covers a malformed row that is neither nil nor a
    -- table, so the never-raise property is total. Short-circuiting `and` keeps the
    -- second index unreachable when the first level did not resolve, and `== true`
    -- makes every answer a strict boolean - so a declared `false` cell and an
    -- unrecognised reason are indistinguishable to a caller, which is intended.
    local row = RLDiseaseRecord.RECOVERY_EXITS[endpoint]
    local mayRecover = type(row) == "table" and row[reason] == true

    if not mayRecover then
        -- TWO MESSAGES, NOT ONE, and the split is the diagnostic. A refusal here has
        -- two very different causes that the RETURN deliberately cannot separate: a
        -- declared `false` cell - the rule working - and a value that is in no
        -- vocabulary, which is a wiring bug or a record carrying a name a later mod
        -- version retired. With one shared message a stale endpoint reads exactly
        -- like `lifelong` behaving correctly, and the animal is permanently
        -- infectious with nothing in the log to say so.
        --
        -- Both lines stay: the first PLAYER-VISIBLE refusal is a treated `lifelong`
        -- animal that never recovers, and that is a DECLARED false, so silencing the
        -- declared case would remove the line from the one case it was asked for.
        -- DEBUG keeps both out of the production INFO budget.
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


--- Apply a transition to a record. The ONLY writer of `record.state`.
---
--- Exists beside the predicate rather than leaving every caller to write
--- `if canTransition(...) then record.state = to end`, because four slices would
--- each write that line and one of them would eventually write the assignment
--- without the guard - which is the defect this module exists to remove, arriving
--- one layer up.
---
--- Returns REMOVE rather than writing for the immunity-expiry pair: a record never
--- holds SUSCEPTIBLE, so the caller deletes it while it still reads RECOVERED.
--- @param record table|nil A record from `new`. TRUSTED INTERNAL input; a nil
---        record returns REFUSED rather than raising.
--- @param to string|nil The destination STATE.
--- @return string outcome APPLIED | REFUSED | REMOVE - three distinct values, never
---         a boolean
function RLDiseaseRecord.transition(record, to)
    -- Same membership-first shape as the lookup above, and a TYPE test rather than
    -- `record == nil` for the same reason it is one there: reading `record.state`
    -- off a non-table raises. `false` is the reachable case - the ordinary Lua
    -- idiom `local record = hasIt and animal.diseases[title]` yields `false`, not
    -- nil - and the contract promises a refusal.
    if type(record) ~= "table" then return RLDiseaseRecord.REFUSED end

    if not RLDiseaseRecord.canTransition(record.state, to) then
        -- The ONE diagnostic in this module, and it earns its place: a record whose
        -- `state` is not in the enum - a value from an older codec revision, a
        -- hand-edited save - is refused forever, so it can never advance, never die
        -- and never be removed. Without this line that frozen record is invisible
        -- at every level. It cannot fire on a legal path, and DEBUG keeps it out of
        -- the production INFO budget.
        Log:debug("RLDiseaseRecord.transition: refused %s -> %s (title=%s)",
            tostring(record.state), tostring(to), tostring(record.title))

        return RLDiseaseRecord.REFUSED
    end

    -- Legal, and the one legal pair that must not be written. Deleting the record
    -- is the animal's job, not this module's. Compared against the file-local
    -- literal that also built the TRANSITIONS key, never against the public STATE
    -- table - see the literal's own comment for the drift that would otherwise let
    -- this branch write the state it exists to suppress.
    if to == SUSCEPTIBLE then
        return RLDiseaseRecord.REMOVE
    end

    record.state = to

    return RLDiseaseRecord.APPLIED
end


--- Build a fresh record at EXPOSED.
---
--- THE RATES ARE NOT COPIED. Case fatality, r0, the immunity length, the cull flag
--- and the duration pair all stay on the model, and the slices that roll them
--- re-resolve the model at roll time. That keeps the record narrow for a later
--- codec to serialize and keeps one authority for every authored number; the cost,
--- accepted, is that those slices hold a model reference when they roll.
---
--- `endpoint` is the one model-derived value that IS copied, because the state
--- machine and the later delegation both branch on it without a model in hand.
---
--- THE KEY SET IS IDENTICAL FOR EVERY ENDPOINT. The parser writes at most one of
--- the duration pair - and for `lifelong` and `cureOnly` neither - so copying
--- either would give the shapes different key sets. Not copying either removes the
--- problem. Counters with nothing to count are `0`, never nil - a nil would drop
--- the key and reintroduce the same split - and `0` on the treatment counter does
--- NOT distinguish "never treatable" from "course finished"; the model's own
--- treatment block answers that.
--- @param model table A parsed `<model>` entry. `archetype` and `endpoint` are
---        guaranteed present by the definition parser. TRUSTED INTERNAL input - a
---        shipped file read back by the mod that ships it is an internal caller, so
---        nothing here is validated.
--- @param title string The disease title. The parser's `models` map is KEYED by
---        title and writes no `title` field, so this arrives as a parameter rather
---        than being read off the model.
--- @return table record A fresh record at EXPOSED, carrying exactly eight keys
function RLDiseaseRecord.new(model, title)
    return {
        -- Carried from the model at construction. `archetype` is carried VERBATIM
        -- and never gated: the parser owns the vocabulary warning, and a second
        -- gate here would either double-report or refuse a record the parser
        -- accepted, splitting the vocabulary across two files.
        ["title"] = title,
        ["archetype"] = model.archetype,
        ["endpoint"] = model.endpoint,

        ["state"] = RLDiseaseRecord.STATE.EXPOSED,

        -- All four counters start at 0. TWO of them are advanced in this file -
        -- `incubationTicksRemaining` by `advanceIncubation` and
        -- `treatmentMonthsRemaining` by `advanceTreatment`, each the sole decrement
        -- of its own field. `monthsElapsed` and `immunityMonthsRemaining` are
        -- declared here and advanced nowhere yet; the progression and fatality
        -- slices own those.
        ["incubationTicksRemaining"] = 0,
        ["monthsElapsed"] = 0,
        ["treatmentMonthsRemaining"] = 0,
        ["immunityMonthsRemaining"] = 0
    }
end


--- Floor a tick count into the hidden window's smallest legal length.
---
--- Takes a count the caller has ALREADY scaled - the difficulty multiply belongs to
--- the settings slice that owns the preset, not here - and returns a positive
--- integer for any finite input. That split is what lets "incubation can never
--- reach zero at any scale value" hold without this module knowing what a scale is.
---
--- The fold puts the VALUE first and the constant second; the header says why that
--- order is the portable one and must not be swapped.
--- @param ticks number Tick count, already scaled by the caller. TRUSTED INTERNAL
---        input - not validated; see the header's sharp-edge enumeration, including
---        what a nil, NaN, negative or infinite value does.
--- @return number ticks A positive integer for any finite input, never below
---         MIN_INCUBATION_TICKS
function RLDiseaseRecord.incubationTicksFor(ticks)
    return math.max(math.floor(ticks + 0.5), RLDiseaseRecord.MIN_INCUBATION_TICKS)
end


--- Seed a fresh record's hidden window. The ONLY place `incubationTicksRemaining`
--- is written at infection.
---
--- Refuses a record that has left EXPOSED or is already mid-window, because either
--- way re-seeding restarts something: a record past EXPOSED has served its hidden
--- window, and one still in EXPOSED with a running counter is inside it. The
--- transition table forbids the same move in the other direction, so the refusal
--- keeps the two consistent.
--- @param record table|nil A record from `new`. TRUSTED INTERNAL input; a nil - or
---        any non-table, `false` being the reachable one - returns REFUSED rather
---        than raising.
--- @param ticks number|nil Tick count, already scaled. Floored by
---        `incubationTicksFor`. A nil returns REFUSED, because arithmetic on it
---        would otherwise raise inside a wiring bug's caller.
--- @return string outcome APPLIED | REFUSED
function RLDiseaseRecord.seedIncubation(record, ticks)
    -- Same membership-first shape as `transition`, and a TYPE test for the same
    -- reason it is one there: reading `record.state` off a non-table raises, and
    -- `false` is the reachable case.
    if type(record) ~= "table" then return RLDiseaseRecord.REFUSED end

    -- A wiring guard against a MISSING argument, not value validation - the
    -- distinction the header draws.
    if ticks == nil then return RLDiseaseRecord.REFUSED end

    if record.state ~= RLDiseaseRecord.STATE.EXPOSED then
        return RLDiseaseRecord.REFUSED
    end

    -- Tested against 0 rather than for a positive value, and the difference is not
    -- style: `> 0` RAISES on a nil counter, where `~= 0` refuses it. So this shape
    -- also declines a record whose counter is absent or non-numeric instead of
    -- writing over it or crashing on it.
    --
    -- `new` starts every counter at 0, so a fresh record is the only thing this
    -- admits. That would stop being true the moment the transition table grew a
    -- condition: a record that spent its last tick and had its surfacing REFUSED
    -- would sit at EXPOSED with the counter at 0, indistinguishable from fresh here,
    -- and would be re-seeded. `advanceIncubation` below anticipates exactly that
    -- refusal, so the two are consistent only while `EXPOSED -> INFECTIOUS` stays
    -- unconditional.
    --
    -- IT DOES, AND THE EXIT RULE DID NOT CHANGE THAT. `canRecover` sits OUTSIDE the
    -- transition table and constrains only the RECOVERED exit, so `TRANSITIONS`
    -- gained no condition and this pair keeps its guarantee. A rule placed INSIDE
    -- the table - the shape that was weighed and rejected - is what would have
    -- reintroduced the inconsistency named above.
    if record.incubationTicksRemaining ~= 0 then
        return RLDiseaseRecord.REFUSED
    end

    record.incubationTicksRemaining = RLDiseaseRecord.incubationTicksFor(ticks)

    return RLDiseaseRecord.APPLIED
end


--- Advance a record's hidden window by one tick, surfacing it when the window ends.
---
--- Decrements FIRST and then tests, so a seed of N yields exactly N advances in
--- EXPOSED. The decrement is clamped at 0: an unseeded record advances once and
--- surfaces rather than running the counter negative into a field a codec
--- serializes.
---
--- Returns two values rather than a fourth outcome constant. The outcome set is
--- locked, and the caller genuinely needs to tell "decremented" from "decremented
--- and surfaced" - the tick order puts symptoms ahead of the player's turn, so a
--- consumer acts on the SAME tick a case becomes visible rather than snapshotting
--- the state around this call. `APPLIED` therefore also covers a bare decrement.
--- @param record table|nil A record from `new`. TRUSTED INTERNAL input; a nil or
---        non-table returns REFUSED rather than raising, as does a record whose
---        counter is absent or non-numeric, since `nil - 1` raises.
--- @return string outcome APPLIED for a bare decrement; on the surfacing call,
---         whatever `transition` returned - APPLIED while the pair stays
---         unconditional. REFUSED means the call was DECLINED at a guard and
---         nothing moved, EXCEPT on a refused surfacing, where the tick is already
---         spent and deliberately not restored. `transition` returns REMOVE only
---         for a SUSCEPTIBLE destination, so REMOVE is unreachable from here.
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
    -- record sits at 0, and 0 is exactly the value a later codec's unsigned slot
    -- cannot carry one below.
    record.incubationTicksRemaining = math.max(remaining - 1, 0)

    if record.incubationTicksRemaining > 0 then
        return RLDiseaseRecord.APPLIED, false
    end

    -- The spent tick is NOT restored on a refusal. The counter is decremented above,
    -- so a transition table that later grows a condition surfaces the refusal with
    -- the tick already consumed, rather than as a silent inconsistency between the
    -- counter and the state.
    local outcome = RLDiseaseRecord.transition(record, RLDiseaseRecord.STATE.INFECTIOUS)

    return outcome, outcome == RLDiseaseRecord.APPLIED
end


--- Enrol a symptomatic record on a treatment course. The ONLY place
--- `treatmentMonthsRemaining` is written at enrolment.
---
--- REFUSING A RECORD MID-COURSE IS THE PAUSE CONTRACT AT THIS LEVEL, not a
--- defensive check, and it is the half of the pair a maintainer would "fix". The
--- record carries no running flag - the key set is locked at eight and a ninth was
--- already refused for the exit reason - so pausing is the CALLER withholding
--- `advanceTreatment`, and the served months survive by construction because nothing
--- else writes the counter down. What must never happen is a resume RE-SEEDING the
--- course, and this refusal is what stops it. Do not turn it into a re-seed.
---
--- Tested `~= 0` rather than `> 0`, exactly as `seedIncubation` tests its own
--- counter and for the same reason: `> 0` RAISES on a nil counter where `~= 0`
--- refuses it, so a record whose counter a codec left absent or non-numeric is
--- declined rather than written over.
---
--- `0` does NOT mean "never treatable" - the model's own `<treatment>` block answers
--- that, which is why this takes the block rather than reading a flag off the record.
--- @param record table|nil A record from `new`. TRUSTED INTERNAL input; a nil - or
---        any non-table, `false` being the reachable one - returns REFUSED rather
---        than raising, and returns BEFORE any log line, because there is no title
---        to name.
--- @param treatment table|nil The model's `<treatment>` block, as the definition
---        parser emits it: `months` whole and >= 1, `cost`, `efficacy` in [0, 1],
---        `outcome` in the parser's closed set. A nil or `false` block - the
---        untreatable model, reached through the ordinary `hasIt and x` idiom -
---        returns REFUSED.
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
    -- value. Assigning a nil in Lua REMOVES the key, so a block with no `months` would
    -- take the record from eight keys to seven while this function returned APPLIED -
    -- and the eight-key set is locked "on every path", with a codec still to be built
    -- against it. The record would also be bricked: the counter guard above refuses a
    -- non-numeric counter forever, and `advanceTreatment` refuses it too, so nothing
    -- could ever move it again.
    --
    -- `< 1` rides along because 0 is the value this module reserves for "no course":
    -- seeding it would return APPLIED for a course the advance then refuses as absent.
    --
    -- This is the sibling's shape, not a new one - `seedIncubation` guards its own nil
    -- tick count for the same reason. The parser refuses both cases, so no shipped
    -- model reaches here; what the guard protects is the invariant, not the input.
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


--- Serve one daily tick of a treatment course, resolving it when the course
--- completes. The ONLY decrement of `treatmentMonthsRemaining`.
---
--- THE COURSE RUNS ON THE DAILY TICK, in months. Each call serves
--- `1 / daysPerPeriod` months, so a course of N months completes on exactly the
--- `N * daysPerPeriod`-th call at every setting - which is the whole reason the
--- authoring rule makes a course a WHOLE number of months. A whole-month decrement on
--- the period boundary was weighed and rejected: it makes the served animal-time
--- depend on which day of the period the player enrolled.
---
--- COMPLETION COMPARES AGAINST AN ABSOLUTE EPSILON, never `== 0` and never a bare
--- `<= 0`. See `TREATMENT_COMPLETION_EPSILON` for the measurement; the short version
--- is that a bare `<= 0` over-serves about half of all authored courses by one tick.
---
--- THE ROLL FIRES EXACTLY ONCE PER COURSE, on the completing call, and never on a
--- bare decrement or a refusal. `efficacy` is the probability that a COMPLETED course
--- achieves its outcome - not a per-tick chance and not a partial-effect multiplier -
--- so rolling per tick would be a different mechanic wearing the same field's name.
--- Achieved is `roll < efficacy`, never `<=`, which is what makes `efficacy = 0` never
--- achieve and `efficacy = 1` always achieve against a `[0, 1)` generator.
---
--- THIS IS THE ONE PLACE THE TWO VOCABULARIES MEET. `treatment.outcome` is the
--- parser's lowercase authoring word and `EXIT_REASON` is the record's uppercase exit
--- word; they are compared and mapped here and nowhere else. The lowercase literals
--- stay inline rather than being promoted to a public table on this module, because
--- the parser owns that vocabulary and moving it would widen a public surface for a
--- single reader.
---
--- THE COMPOSITION IS `canRecover` THEN `transition`, in that order, and this is the
--- first and only caller that performs it. A cure that the endpoint refuses resolves
--- FAILED and the record stays where it is - never `transition` without asking first.
---
--- `APPLIED` on every completion, FAILED and RELIEVED included, because a counter
--- write WAS applied - the same reading `advanceIncubation` locked when it returns
--- APPLIED for a bare decrement. The second slot is what separates the three
--- completions, and it is never nil.
--- @param record table|nil A record from `new`. TRUSTED INTERNAL input; a nil or
---        non-table returns REFUSED rather than raising, as does a record whose
---        counter is absent or non-numeric.
--- @param treatment table|nil The model's `<treatment>` block. A nil or `false`
---        block returns REFUSED.
--- @param daysPerPeriod number The engine's configured days per period, clamped by
---        the environment to 1..28. TRUSTED INTERNAL input - not validated. A NIL
---        raises on the subtraction, deliberately: that is a wiring bug and should be
---        loud, and the subtraction precedes every write, so the counter and the roll
---        are untouched when it does.
--- @param rng function|nil A zero-argument generator returning `[0, 1)`, defaulting
---        to `math.random`. A TRUSTED INTERNAL TEST SEAM, the same shape the dealer
---        quality model and the genetics draw already use, so a suite can drive the
---        roll deterministically without touching the shared stream. Production
---        passes nothing.
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
        -- Clearing it belongs to whichever slice drives the exit.
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
        -- `0` is "no course", never "complete now". A course that is not running is
        -- not something to resolve.
        Log:trace("RLDiseaseRecord.advanceTreatment: refused title=%s - no course is running",
            tostring(record.title))

        return RLDiseaseRecord.REFUSED, RESULT.NONE
    end

    rng = rng or math.random

    -- The subtraction sits AHEAD of every write and ahead of the roll, so a nil
    -- `daysPerPeriod` raises with the record and the generator untouched.
    local served = remaining - 1 / daysPerPeriod

    if served > RLDiseaseRecord.TREATMENT_COMPLETION_EPSILON then
        record.treatmentMonthsRemaining = served

        Log:trace("RLDiseaseRecord.advanceTreatment: served a tick of title=%s, %s month(s) left",
            tostring(record.title), tostring(served))

        return RLDiseaseRecord.APPLIED, RESULT.ADVANCED
    end

    -- THE DISPATCH RESOLVES FIRST AND THE COUNTER IS WRITTEN AFTER IT, which is the same
    -- ordering discipline the subtraction above follows for `daysPerPeriod`. The comparison
    -- below RAISES on a block with no `efficacy`, and resolving before writing means such a
    -- raise leaves the counter exactly where the caller left it rather than destroying a
    -- part-served course that nothing could then reconstruct.
    --
    -- Every path that RETURNS still passes through the write, so the invariant a reader
    -- cares about is unchanged: the course is over however it resolves, and a FAILED roll
    -- is re-enrollable with no separate reset path because `enrolTreatment` accepts a zero
    -- counter. Only the raising path differs, and only in leaving less wreckage.
    --
    -- The roll is spent before the comparison either way - `rng()` has to run to be compared
    -- against. That is not recoverable here and does not need to be: a raise aborts the tick,
    -- and one consumed draw from a generator with no other observer costs nothing.
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
                -- UNREACHABLE BY CONSTRUCTION - the pair is unconditional and the
                -- state guard at entry already proved the record is INFECTIOUS - and
                -- kept so the dispatch cannot fall off its end with a nil result.
                result, cause = RESULT.FAILED, "transition"
            end
        else
            -- The endpoint refuses this exit. `canRecover` logs its own refusal, so
            -- this cause is named on the completion line below and nowhere else.
            result, cause = RESULT.FAILED, "endpoint"
        end
    else
        -- The else arm of a CLOSED dispatch rather than a guard: the parser refuses
        -- an outcome outside its own set, so this is reachable only from a hand-built
        -- block. It exists so the second slot is never nil.
        result, cause = RESULT.FAILED, "outcome"
    end

    -- The course is over however it resolved, and this is the one write that ends it.
    record.treatmentMonthsRemaining = 0

    -- ONE line per completion, and it is the line a player's "my treatment failed"
    -- report needs: the module's standing stance is that straight-line arithmetic
    -- needs no line because the caller holds every value one could name, and that is
    -- true of the incubation pair, whose branches turn on the record's own state and
    -- counter. It is NOT true here, because the completion turns on a roll the caller
    -- never sees.
    Log:debug("RLDiseaseRecord.advanceTreatment: course complete title=%s roll=%s "
        .. "efficacy=%s outcome=%s result=%s cause=%s",
        tostring(record.title), tostring(roll), tostring(treatment.efficacy),
        tostring(treatment.outcome), tostring(result), cause)

    return RLDiseaseRecord.APPLIED, result
end


-- FIVE SITES LOG HERE, deliberately: the load line, `transition`'s refusal,
-- `canRecover`'s pair, and the treatment pair's own refusals and completions.
-- Everything else is silent, and the enumeration below says why.
--
-- `canRecover` earns its pair of lines the way `transition` earns its one: it REFUSES
-- over a closed table, so a caller that never gets its recovery has nothing else to
-- read. Note the asymmetry with `canTransition`, which is silent on refusal - that
-- predicate's refusals are swept exhaustively by a truth table and have no player
-- consequence, where `canRecover`'s first player-visible refusal is a treated
-- `lifelong` animal that never recovers. Consequence worth knowing before the
-- progression slice lands: four of the eight cells are declared falses, so once a
-- caller asks `NATURAL` per tick these lines arrive per refused record per tick. That
-- is a volume question for the slice that acquires the call, and it is measurable
-- only then; no consumer exists to measure it now.
--
-- THE TREATMENT PAIR LOGS WHERE ITS INCUBATION SIBLING DOES NOT, and the difference
-- is not inconsistency. Every branch in the incubation pair turns on the record's own
-- state and counter - both of which the caller holds and can state itself, naming the
-- animal as this module cannot - so a line here would only repeat what the caller
-- already knows. The treatment COMPLETION turns on a roll the caller never sees, and
-- an outcome and an endpoint it would have to re-resolve, so the completion line is
-- the only place those four values ever appear together. Its refusals are TRACE for
-- the same reason the enrol's are: a caller whose course never starts, or never
-- advances, has nothing else to read, and TRACE keeps the volume out of the default
-- view. The bare decrement is TRACE too - per-tick volume is a TRACE property rather
-- than a reason to drop the line.
--
-- `canTransition` is a table lookup and a boolean, `transition` is that plus one
-- assignment, `new` is a table literal, and the three incubation functions are
-- straight-line arithmetic plus one guarded write - so there is no branch whose
-- decision a TRACE line would explain that the caller does not already hold.
-- `advanceIncubation` does branch, but only on state and counter, which is the
-- distinction the paragraph above draws. Read the absence as that, not as
-- under-logging. The callers this module is waiting on are the infection,
-- progression, fatality and switch-over slices.
--
-- THE FOUR TYPE GUARDS ARE SILENT ON PURPOSE, and both appliers do it for the same
-- reason: a non-table record has no title to name and a non-table treatment block
-- has nothing to report, so a line there could say only that something was nil.
-- That is the one early-return class in this file with no TRACE, and it is a
-- deliberate exception to the standing rule that every early return carries one.
Log:info("RLDiseaseRecord loaded")
