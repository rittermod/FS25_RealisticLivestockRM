--[[
    RLDiseaseSpread.lua
    The one home for deciding WHO gets infected in a pen this tick - who is
    shedding, who is eligible to catch it, and the draw that settles each pair.

    IT DECIDES AND IT NEVER APPLIES. `plan` returns the infections it chose,
    carrying live animal references, and constructs nothing. Building the record,
    seeding its hidden window and writing it onto the animal belong to the caller.
    That is the same shape the herdsman planner already ships: a pure pass returns
    intended actions over live objects and an executor applies them.

    PREVALENCE IS A RATIO OVER THE LIVE POPULATION, AND THAT IS THE WHOLE
    SCALE-INVARIANCE PROPERTY. The per-animal chance is `count / population`, never
    the raw count, which is what makes a thousand-animal herd behave the same in one
    pen or in forty. `population` counts only the animals that survived the dead
    skip, and THE DEAD SKIP PRECEDES THE INCREMENT: a corpse is absent from the
    denominator exactly as it is absent from the shedder set. Keeping corpses in the
    denominator would make a pen with a body in it spread more slowly than the same
    pen after the flush - a difference no player could see and no test would name.

    PREVALENCE MULTIPLIES THE MONTHLY RATE, AND THE PER-TICK CONVERSION HAPPENS
    LAST. It is passed INTO `RLDiseaseTransmission.perTickRate` rather than applied
    to what that function returns, because converting first and scaling second makes
    cumulative risk depend on the player's days-per-period setting - the defect the
    two-clocks design exists to remove.

    THAT FUNCTION CLAMPS THE MONTHLY PRODUCT AT 1, so a saturated pen LOSES the R0
    guarantee: above saturation the realised R0 falls below the authored figure, and
    by a different amount at each period length. Inside the clamp the invariant holds
    exactly. Know it before reading a spread number off a heavily infected pen, and
    before designing any oracle over one - the clamp maps two different wrong answers
    onto the identical value.

    WHO SHEDS IS THE RECORD STATE AND NOTHING ELSE: EXPOSED or INFECTIOUS. RECOVERED,
    DEAD, SUSCEPTIBLE and any value a later codec retired all shed nothing. EXPOSED
    counts in FULL because the contagious window this rate is derived from already
    counts the incubation ticks in full - the two must agree or the realised R0 stops
    matching the authored one.

    THERE IS NO CARRIER TEST HERE, AND NOTHING IS MISSING. The record carries eight
    keys and none of them is a carrier flag. Under this model an asymptomatic shedder
    is authored as a `lifelong` endpoint and is INFECTIOUS like any other case, while
    a genetic carrier belongs to the genetics system. The legacy collector's `cured` /
    `isCarrier` predicate answers a different question over a different record shape;
    do not fold the two together.

    BE PRECISE ABOUT THE GENETIC EXCLUSION, because the obvious reading over-claims:
    nothing here reads `archetype`, so a genetic model is kept out of this pass by
    WHOEVER BUILDS THE CTX, not by this module. That gate is a separate slice's and
    it has no site yet. State it as the caller's obligation rather than as a property
    of this file.

    ANY EXISTING RECORD OF A TITLE REFUSES THE RECIPIENT, WHATEVER ITS STATE. That is
    where immunity lives - in the recipient-side eligibility test rather than in a
    counter - so no later slice may drop a record early to "clean up" without
    reopening reinfection. A consequence worth stating, because two other claims rest
    on it: an animal can hold at most ONE record per title, which is what keeps a
    title's count at or below the population and prevalence inside [0, 1].

    TWO PASSES, AND THE PRICING IS HOISTED ABOVE THE RECIPIENT WALK. The rate is
    animal-INVARIANT, so pricing it per animal would repeat three TRACE calls per
    eligible pair, emit the unknown-title line once per animal instead of once per
    title, and leave `stats.rates` empty for a title with no eligible recipient -
    which is exactly the case a scale-invariance oracle needs to read.

    NO UNGUARDED DIVISION BY THE POPULATION. `not (population > 0)` sits above the
    ratio and returns the empty plan: ONE inverted comparison rejecting zero, a
    negative count and a NaN, where a plain `<= 0` catches none of the NaN case
    because every comparison against a NaN is false in both directions. The cost of
    getting it wrong is asymmetric and worth naming: the engine emits a
    divide-by-zero script error plus a callstack where LuaJIT is silent, so an
    unguarded `x/0` here would be invisible to every headless run while moving the
    in-game error-line pin.

    BOTH WALKS ARE ORDERED AND THE TITLE LIST IS SORTED, BECAUSE DRAW ORDER IS PART
    OF THE OUTCOME. `pairs` order is undefined and differs per process, so an
    unsorted title walk would make the draw sequence differ between the two runners
    and between runs, which no seeded generator rescues. The infections array is
    emitted animal-major then title-sorted, AND THAT ORDER IS CONTRACT: the generator
    takes no arguments and cannot observe which title it was drawn against, so the
    output order is the only observable that separates a sorted walk from a hash one.

    TWO SHIPPED BEHAVIOURS CHANGE UNDER THIS PASS, and the slice that delegates to it
    inherits both. The denominator moves from the whole array (corpses included) to
    the live count, which is the scale-invariance property above. And the draw moves
    from at-or-below the rate to STRICTLY below it, which is what makes a rate of 0
    never fire. Neither is incidental; neither is a regression.

    Pure data-in / data-out. No `g_*`, no GUI, no XML, no engine natives - and no
    animal method, mission or registry read. RmLogging at file scope is the only
    unconditional dependency; the two sibling disease modules are reached at CALL
    time only, which is why this file's position in the loader is ordinary rather
    than required.

    SHARP EDGES, named so the next reader does not rediscover them.

      nil daysPerPeriod   RAISES inside the rate module, deliberately - a wiring bug
                          should be loud. The precondition is a SHEDDER, not an
                          eligible recipient: pricing is hoisted above the recipient
                          walk, so the raise fires as soon as any title sheds and has
                          a usable model, even in a pen where nobody can catch it.
                          Only a pen with nothing shedding prices nothing.
      nil incubationTicks RAISES the same way, on the division that forms the hidden
                          window, and under the same shedder condition.
      a sparse animals    ends the `ipairs` walk at the first hole and under-counts
      array               both the population and the shedders. The caller's array is
                          a pen's own animal list, which has no holes; this is a
                          documented consequence of that contract, not a guard.
      a sparse or         the two functions read it differently ON PURPOSE, and the
      hash-keyed          asymmetry is worth knowing: `collectShedders` walks it with
      `diseases` table    `ipairs` and stops at a hole, while `isEligible` walks it
                          with `pairs` and sees every entry. Both directions fail
                          SAFE - the title sheds less, or not at all, while its
                          holder stays protected - so this is documented rather than
                          reconciled. No producer makes holes today.
      a non-function rng  RAISES on the first draw. Same reason: a malformed injected
                          dependency is a wiring bug, and every caller is mod code
                          inside this subsystem.

    Nothing calls this module yet, and nothing in the tree yet produces the record
    shape it reads. The pen walk that adopts it, the guard that turns the feature
    off, the ctx it is handed and the adaptation of a live animal into the view below
    all belong to the slice that wires the caller.
]]

RLDiseaseSpread = {}

local Log = RmLogging.getLogger("RLRM")


--- Why a candidate recipient was refused, in `isEligible`'s second return slot.
---
--- Values are identical to their keys, so a log line reads without a reverse map and
--- one object serves as both the key set and the value set.
---
--- `DEAD` deliberately COLLIDES with a `RLDiseaseRecord.STATE` name and the two are
--- unrelated: this one answers "why was this animal refused as a recipient", that one
--- answers "what state is this record in". The collision is why the state-literal grep
--- gate over this file is scoped around `DEAD` rather than covering all five names.
---
--- READ-ONLY by contract: consumers share this object and there is deliberately no
--- defensive copy, exactly like every sibling vocabulary in this subsystem.
RLDiseaseSpread.SKIP_REASON = {
    ["DEAD"] = "DEAD",
    ["HOLDS_RECORD"] = "HOLDS_RECORD",
    ["PREREQUISITE"] = "PREREQUISITE"
}


--- Count the shedding records per disease title, and the live population beside them.
---
--- Walks the collection ONCE. A dead animal is skipped WHOLE and BEFORE the
--- population increment, so one skip removes it from both roles at once and an
--- all-dead pen lands on a population of 0 - which is what lets the caller's division
--- guard actually fire.
--- @param animals table|nil The pen's animals, an ordered array. TRUSTED INTERNAL
---        input; a nil or non-table returns `{}, 0` rather than raising.
--- @return table counts Title -> number of shedding records. A FRESH table per call.
--- @return number population The animals that survived the dead skip
function RLDiseaseSpread.collectShedders(animals)
    local counts = {}
    local population = 0

    if type(animals) ~= "table" then return counts, population end

    -- Read at CALL time through the record module's own vocabulary rather than
    -- against lowercase literals, so the five state names keep one home.
    local STATE = RLDiseaseRecord.STATE

    for _, animal in ipairs(animals) do

        if not animal.isDead then

            population = population + 1

            local diseases = animal.diseases

            -- A healthy animal carries no disease table at all, so this is the
            -- ORDINARY case rather than a defect: it contributes nothing as a source
            -- and stays in the population as a susceptible.
            if type(diseases) == "table" then

                for _, record in ipairs(diseases) do

                    local title = record.title

                    if type(title) ~= "string" then
                        -- The ONE place in this module where caller data becomes a
                        -- table KEY, and Lua raises on a NaN key - on write only. The
                        -- type test rejects every non-string before the write below,
                        -- so the never-raise property is total.
                        Log:debug("RLDiseaseSpread.collectShedders: skipped a record whose "
                            .. "title is a %s, not a string - it cannot key the source set",
                            type(title))
                    elseif record.state == STATE.EXPOSED or record.state == STATE.INFECTIOUS then
                        -- THE WHOLE SHEDDING PREDICATE, and it reads STATE alone. A
                        -- carrier is not one of these two, because the record carries
                        -- no carrier flag; see the header for where that concept went.
                        -- The eligibility rule below is what keeps a title's count at
                        -- or below the population, by admitting one record per title
                        -- per animal.
                        counts[title] = (counts[title] or 0) + 1
                    end

                end

            end

        end

    end

    return counts, population
end


--- May this animal catch this disease?
---
--- Answers over plain data - alive, holds no record of the title in ANY state, and
--- every model prerequisite matches - and returns a closed reason beside the verdict
--- so a caller can report the refusal without reading the log.
--- @param animal table|nil An animal view carrying `isDead` and `diseases`. TRUSTED
---        INTERNAL input; a non-table returns `false` with a NIL reason, because a
---        non-table has no identity to name - and a nil reason must never be tallied,
---        since a nil table key raises on write.
--- @param title string The disease title being offered.
--- @param model table|nil The parsed `<model>` half, for its prerequisites. A nil or
---        non-table is normalized to "no prerequisites" rather than raising.
--- @return boolean eligible
--- @return string|nil reason A SKIP_REASON value on a refusal, nil otherwise
function RLDiseaseSpread.isEligible(animal, title, model)
    local REASON = RLDiseaseSpread.SKIP_REASON

    if type(animal) ~= "table" then return false, nil end

    if animal.isDead then return false, REASON.DEAD end

    -- ANY record of this title refuses, whatever its state - which is where immunity
    -- lives, and why a recovered record is as protective as an active one. The
    -- record's STATE is deliberately NOT read here: reading it would let a recovered
    -- animal be reinfected inside its own immunity window.
    for _, record in pairs(animal.diseases or {}) do
        if record.title == title then return false, REASON.HOLDS_RECORD end
    end

    -- Normalized AHEAD of reading `prerequisites`, so a nil or scalar model walks
    -- nothing instead of raising on the index.
    if type(model) ~= "table" then return true end

    for _, prerequisite in ipairs(model.prerequisites or {}) do

        local path = prerequisite.path

        -- ONE predicate for the absent path and the empty one. An unguarded walk over
        -- an empty path never descends, so it would compare the ANIMAL TABLE against
        -- the authored value and refuse every animal forever, silently.
        if type(path) ~= "table" or #path == 0 then
            return false, REASON.PREREQUISITE
        end

        local currentValue = animal

        -- `ipairs`, not the shipped loop's `pairs`: `path` is `string.split`'s ordered
        -- array, and descending it in hash order reads the wrong field. The defect is
        -- latent in shipped data - every authored prerequisite is single-segment - so
        -- this is new code following the convention rather than a fix to the old path.
        for _, segment in ipairs(path) do
            -- A TYPE test rather than a nil test, and the difference is reachable: a
            -- dotted path descending through a boolean or a number would raise on the
            -- index, and a raise here aborts the whole pen tick of whatever drives
            -- this pass.
            if type(currentValue) ~= "table" then return false, REASON.PREREQUISITE end
            currentValue = currentValue[segment]
        end

        if currentValue ~= prerequisite.value then
            return false, REASON.PREREQUISITE
        end

    end

    return true
end


--- Decide this tick's infections for one pen.
---
--- Composes the two functions above in TWO passes: every shedding title is resolved
--- and priced ONCE, above the recipient walk, and then each live animal draws once
--- per eligible (animal, title) pair against that title's rate.
---
--- Mutates nothing - not the animals, not their records, not the input collection.
--- @param animals table|nil The pen's animals. A non-table returns the empty plan.
--- @param ctx table|nil `{ diseases = <title -> { model, maxLifespanMonths,
---        incubationTicks }>, daysPerPeriod = <number>, rng = <function|nil> }`. A
---        non-table returns the empty plan. `rng` is a zero-argument generator
---        returning `[0, 1)`, defaulting to `math.random` - the same TRUSTED INTERNAL
---        TEST SEAM the fatality roll, the dealer quality model and the genetics draw
---        already use. Production passes nothing.
--- @return table infections Array of `{ animal = <live reference>, title = <string> }`
---         in animal-major, title-sorted order. THAT ORDER IS CONTRACT.
--- @return table stats `{ population, shedders, rates, monthly, unpriced, skipped,
---         rolls }` - all seven FIELDS present on EVERY return path, guards included,
---         so a caller never nil-checks a field. `monthly` carries the CLAMPED monthly
---         rate each priced title converted from, and a value of 1 there is the
---         SATURATION tell that `rates` cannot give: above saturation the clamp maps
---         every excess onto the same per-tick number. Two things this shape is NOT,
---         both easy to over-read: the five table fields are EMPTY rather than
---         pre-keyed, so `stats.skipped.DEAD` is nil and not 0 and a caller summing
---         reasons must default them; and `population` is zero only on the two guard
---         paths - a live pen with nothing shedding returns the real count beside
---         empty tables
function RLDiseaseSpread.plan(animals, ctx)
    local infections = {}

    -- Built up front and returned by every path below, so the shape is never
    -- partially nil. `skipped` counts (animal, title) PAIRS rather than animals - one
    -- animal refused for three titles contributes three - which is the same
    -- different-units trap the legacy collector documents for its own two counters.
    -- `rates` is populated for every PRICED title whether or not it found a
    -- recipient, because it is the pass's only non-stochastic observable and a
    -- scale-invariance claim has nothing else to read.
    local stats = {
        ["population"] = 0,
        ["shedders"] = {},
        ["rates"] = {},
        ["monthly"] = {},
        ["unpriced"] = {},
        ["skipped"] = {},
        ["rolls"] = 0
    }

    if type(animals) ~= "table" or type(ctx) ~= "table" then
        Log:trace("RLDiseaseSpread.plan: refused - animals is a %s and ctx is a %s",
            type(animals), type(ctx))

        return infections, stats
    end

    local counts, population = RLDiseaseSpread.collectShedders(animals)

    stats.population = population

    -- A FRESH copy rather than the table the collector counted into. Be honest about
    -- what that buys: `counts` is local and dies with this call, so aliasing it would
    -- be UNOBSERVABLE to any caller - measured, by aliasing it and finding the suite
    -- unchanged. The copy is kept because handing out a table this function still
    -- reads is the shape that stops being safe the moment anything here runs after
    -- the return, not because a test can catch its removal.
    for title, amount in pairs(counts) do stats.shedders[title] = amount end

    -- ONE inverted comparison rather than `<= 0`, matching the guard style the two
    -- sibling rate modules use. Scope the claim honestly: `population` is a local
    -- integer this file increments, so ZERO is the only value it can actually take
    -- here - the NaN and negative arms are defensive by FORM, and would start
    -- earning their keep the day a caller supplies the denominator. What the guard
    -- does buy today is the division below never being formed on an empty pen; see
    -- the header for why an unguarded one would be invisible to every headless run.
    if not (population > 0) then
        Log:trace("RLDiseaseSpread.plan: no live animal in %d entr(ies) - empty plan, "
            .. "no division performed", #animals)

        return infections, stats
    end

    local titles = {}
    for title in pairs(counts) do titles[#titles + 1] = title end

    if #titles == 0 then
        Log:trace("RLDiseaseSpread.plan: population=%d, nothing shedding - empty plan",
            population)

        return infections, stats
    end

    -- SORTED, and the sort is load-bearing rather than cosmetic: it is what makes the
    -- draw sequence identical between the two runners and between runs.
    table.sort(titles)

    -- PASS ONE: resolve and price each shedding title exactly once.
    local priced = {}
    local diseases = ctx.diseases or {}

    for _, title in ipairs(titles) do

        local entry = diseases[title]

        -- ONE predicate covering both refusable shapes - no entry at all, and an
        -- entry whose model half was refused at parse. Both are REFUSED rather than
        -- defaulted: a default model would price a disease against numbers its author
        -- never wrote.
        if type(entry) ~= "table" or type(entry.model) ~= "table" then
            Log:debug("RLDiseaseSpread.plan: refused title=%s - the ctx carries no usable "
                .. "model for it, so nobody is offered this disease", tostring(title))

            stats.unpriced[title] = true
        else
            local prevalence = counts[title] / population
            -- BOTH returns are kept. The second is the CLAMPED monthly rate the
            -- conversion actually consumed, and it is the only thing that separates a
            -- SATURATED pen from an honest one: above saturation the clamp maps every
            -- excess onto 1, so `rates` alone still reads plausible while the realised
            -- R0 has already fallen below the authored figure. This module RECORDS it
            -- and draws no conclusion from it - what saturation means is the caller's.
            local pTick, monthly = RLDiseaseTransmission.perTickRate(entry.model,
                entry.maxLifespanMonths, entry.incubationTicks, prevalence,
                ctx.daysPerPeriod)

            stats.rates[title] = pTick
            stats.monthly[title] = monthly

            priced[#priced + 1] = {
                ["title"] = title,
                ["model"] = entry.model,
                ["rate"] = pTick,
                ["prevalence"] = prevalence
            }
        end

    end

    local rng = ctx.rng or math.random

    -- PASS TWO: walk the live animals and draw per eligible pair. The dead are
    -- filtered HERE rather than through `isEligible`, which keeps its own DEAD arm
    -- for its other callers - so `stats.skipped.DEAD` is always zero from `plan`, and
    -- that is contract rather than a gap.
    for _, animal in ipairs(animals) do

        if not animal.isDead then

            for _, entry in ipairs(priced) do

                local eligible, reason = RLDiseaseSpread.isEligible(animal, entry.title,
                    entry.model)

                if eligible then
                    -- Eligibility runs BEFORE the draw, so a refused recipient
                    -- consumes no randomness and the draw budget is a pure function
                    -- of the collection.
                    local draw = rng()

                    stats.rolls = stats.rolls + 1

                    Log:trace("RLDiseaseSpread.plan: rolled title=%s uniqueId=%s farmId=%s "
                        .. "prevalence=%s rate=%s draw=%s hit=%s",
                        tostring(entry.title), tostring(animal.uniqueId),
                        tostring(animal.farmId), tostring(entry.prevalence),
                        tostring(entry.rate), tostring(draw), tostring(draw < entry.rate))

                    -- STRICTLY below, never at, which is what makes a rate of 0 never
                    -- fire against a generator whose range excludes 1.
                    if draw < entry.rate then
                        infections[#infections + 1] = {
                            ["animal"] = animal,
                            ["title"] = entry.title
                        }

                        Log:debug("RLDiseaseSpread.plan: INFECTED title=%s uniqueId=%s "
                            .. "farmId=%s - rate=%s draw=%s",
                            tostring(entry.title), tostring(animal.uniqueId),
                            tostring(animal.farmId), tostring(entry.rate), tostring(draw))
                    end
                elseif reason ~= nil then
                    -- A nil reason is the non-table animal, and it is deliberately NOT
                    -- tallied: writing a nil table key raises.
                    stats.skipped[reason] = (stats.skipped[reason] or 0) + 1
                end

            end

        end

    end

    Log:trace("RLDiseaseSpread.plan: population=%d priced=%d unpriced-titles=%d rolls=%d "
        .. "-> %d infection(s)",
        population, #priced, #titles - #priced, stats.rolls, #infections)

    return infections, stats
end


-- NINE SITES LOG HERE - three guard TRACEs, the per-plan summary TRACE, the per-draw
-- TRACE, the unpriced DEBUG, the decided-infection DEBUG, the malformed-title DEBUG in
-- the collector, and the load line - in FIVE kinds, and the split between the kinds is
-- by FREQUENCY rather than by taste.
--
-- The per-DRAW line is TRACE because it fires per eligible pair per tick - the
-- busiest path this module has - while the DECIDED INFECTION is DEBUG, because an
-- infection is rare and is the line a player's "where did this outbreak come from"
-- report needs. That is the same split the fatality roll already ships.
--
-- The per-PLAN summary is TRACE and is emitted on EVERY return path, the three early
-- ones included, so a walkthrough always has one unconditional line per call rather
-- than a line that vanishes exactly when the pass did nothing.
--
-- The unpriced-title refusal is DEBUG and lives in the PRICING pass, which is what
-- makes it fire once per title rather than once per animal. The malformed-title skip
-- is DEBUG for the same reason it exists at all: that record is invisible to the
-- pass forever and nothing else would say so.
--
-- BE PRECISE ABOUT WHAT THE LEVEL BUYS, because the obvious reading is wrong: Lua
-- evaluates a call's arguments before the logger ever sees the level, so every
-- `tostring()` above is paid at TRACE exactly as it would be at DEBUG, and at every
-- level including OFF. What TRACE buys is the FORMATTING, the EMISSION and a readable
-- default development view - not the argument evaluation.
--
-- The draw line names `uniqueId` AND `farmId`. One alone is not unique across farms,
-- and while the three-field identity rule governs COMPARISON rather than what a log
-- line prints, a line that cannot identify its animal is not a diagnostic.
Log:info("RLDiseaseSpread loaded")
