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

    THE CHRONIC EXIT RULE IS NOT HERE. `INFECTIOUS -> RECOVERED` is unconditionally
    legal, the record still CARRIES `chronic` as data, and whether a
    chronic-but-treatable disease may reach RECOVERED through a completed cure is
    settled separately. So `canTransition` takes TWO arguments and the domain is
    5 x 5, not 5 x 5 x 2 - do NOT add a third argument here.

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
    supported read: the deferred chronic rule will not live in a plain `[from][to]`
    cell, so a consumer reading the table directly is reading something that is
    about to stop being the whole answer. It is public the way a test seam is
    public, not the way `STATE` is.

    TWO STATES CARRY NO OUTGOING ROW WORTH REACHING, FOR OPPOSITE REASONS. DEAD has
    none at all, because it is terminal. SUSCEPTIBLE has exactly one - the infection
    pair - and no record ever sits there to use it, because a caller CONSTRUCTS an
    infected record rather than transitioning into one. Both fall out of the table
    naturally and neither needs a special case, which is exactly why a maintainer
    might add one.

    A record carries `chronic` as its own field, copied at construction rather than
    re-read through a model reference. Re-reading would couple this module to the
    model registry's lifetime, and a record outlives a definition-file reload.

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

    Nothing calls this module yet. The incubation, treatment and fatality slices
    each adopt it in their own change, and each goes through `transition` rather
    than assigning `record.state`.
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
    -- Recovery or a completed cure, and disease fatality. Both unconditional here;
    -- the chronic constraint on the first is deferred (see the header).
    ["INFECTIOUS"] = { ["RECOVERED"] = true, ["DEAD"] = true },
    -- Immunity expires. Returns REMOVE and writes nothing - a record never holds
    -- SUSCEPTIBLE.
    ["RECOVERED"] = { [SUSCEPTIBLE] = true },
    -- Terminal.
    ["DEAD"] = {}
}


--- Is this ordered pair of states a legal transition?
---
--- Takes exactly two arguments, and that is a contract rather than an accident: the
--- chronic exit rule is deferred, so no arm of this module reads `chronic` and a
--- third parameter would be an unused public surface the deferred work would have
--- to renegotiate.
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
--- `chronic` is the one model-derived flag that IS copied, because the state
--- machine and the later delegation both branch on it without a model in hand.
---
--- THE KEY SET IS IDENTICAL FOR A CHRONIC AND A NON-CHRONIC RECORD. The parser
--- writes exactly one of the duration pair, so copying either would give the two
--- shapes different key sets. Not copying either removes the problem. Counters with
--- nothing to count are `0`, never nil - a nil would drop the key and reintroduce
--- the same split - and `0` on the treatment counter does NOT distinguish "never
--- treatable" from "course finished"; the model's own treatment block answers that.
--- @param model table A parsed `<model>` entry. `archetype` and `chronic` are
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
        ["chronic"] = model.chronic,

        ["state"] = RLDiseaseRecord.STATE.EXPOSED,

        -- All four counters start at 0 and NONE is advanced here. The incubation,
        -- treatment and fatality slices each own their own decrement; this slice
        -- declares them and nothing more.
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
    -- `new` starts every counter at 0, so TODAY a fresh record is the only thing
    -- this admits. That stops being true the moment the transition table grows a
    -- condition: a record that spent its last tick and had its surfacing REFUSED
    -- sits at EXPOSED with the counter at 0, which is indistinguishable from fresh
    -- here and would be re-seeded. `advanceIncubation` below anticipates exactly
    -- that refusal, so the two are only consistent while the pair remains
    -- unconditional - the chronic exit rule is where this gets settled.
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


-- The load line is the whole of this module's logging, deliberately. `canTransition`
-- is a table lookup and a boolean, `transition` is that plus one assignment, `new`
-- is a table literal, and the three incubation functions are straight-line
-- arithmetic plus one guarded write - so there is no branch whose decision a TRACE
-- line would explain that the caller does not already hold. `advanceIncubation`
-- does branch, but on the record's own state and counter, both of which the caller
-- holds and can state itself, naming the animal as this module cannot. The callers
-- are the incubation, treatment, fatality and switch-over slices. Read the absence
-- as that, not as under-logging.
Log:info("RLDiseaseRecord loaded")
