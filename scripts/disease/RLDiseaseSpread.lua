--[[
    RLDiseaseSpread.lua
    Decides WHO gets infected in a pen this tick - who is shedding, who is eligible to
    catch it, and the draw that settles each pair.

    IT DECIDES AND IT NEVER APPLIES: `plan` returns the infections it chose, carrying
    live animal references, and constructs nothing.
    PREVALENCE IS A RATIO OVER THE LIVE POPULATION - `count / population`, never the raw
    count - which makes a herd behave the same in one pen or in forty, and it multiplies
    the MONTHLY rate, never the converted one. Shedding is the record STATE, EXPOSED or
    INFECTIOUS, and a genetic record never sheds. ANY record of a title refuses the
    recipient whatever its state, which is where immunity lives. Both walks are ORDERED
    and the title list SORTED, because draw order is part of the outcome.
]]

RLDiseaseSpread = {}

local Log = RmLogging.getLogger("RLRM")


--- Why a candidate recipient was refused, in `isEligible`'s second return slot.
---
--- `DEAD` deliberately COLLIDES with a `RLDiseaseRecord.STATE` name and the two are
--- unrelated: this one answers why an ANIMAL was refused as a recipient. READ-ONLY by
--- contract, like every sibling vocabulary in this subsystem.
RLDiseaseSpread.SKIP_REASON = {
    ["DEAD"] = "DEAD",
    ["HOLDS_RECORD"] = "HOLDS_RECORD",
    ["PREREQUISITE"] = "PREREQUISITE"
}


--- Count the shedding records per disease title, and the live population beside them.
---
--- A dead animal is skipped WHOLE and BEFORE the population increment, so one skip
--- removes it from both roles at once and an all-dead pen lands on a population of 0 -
--- which is what lets the caller's division guard actually fire.
--- @param animals table|nil The pen's animals, an ordered array. TRUSTED INTERNAL
---        input; a nil or non-table returns `{}, 0` rather than raising.
--- @return table counts Title -> number of shedding records. A FRESH table per call.
--- @return number population The animals that survived the dead skip
function RLDiseaseSpread.collectShedders(animals)
    local counts = {}
    local population = 0

    if type(animals) ~= "table" then return counts, population end

    -- Read at CALL time through the record module's own vocabulary, so the five state
    -- names keep one home.
    local STATE = RLDiseaseRecord.STATE

    for _, animal in ipairs(animals) do

        if not animal.isDead then

            population = population + 1

            local diseases = animal.diseases

            -- A healthy animal carries no disease table at all, so this is the ORDINARY
            -- case: it contributes no source and stays in the population as a susceptible.
            if type(diseases) == "table" then

                for _, record in ipairs(diseases) do

                    local title = record.title

                    if type(title) ~= "string" then
                        -- The ONE place caller data becomes a table KEY, and Lua raises on
                        -- a NaN key. The type test rejects every non-string before the
                        -- write, so the never-raise property is total.
                        Log:debug("RLDiseaseSpread.collectShedders: skipped a record whose "
                            .. "title is a %s, not a string - it cannot key the source set",
                            type(title))
                    elseif record.archetype == "genetic" then
                        -- An inherited record is never caught from a pen mate, so it sheds in
                        -- no state, is never counted and costs no draw.
                    elseif record.state == STATE.EXPOSED or record.state == STATE.INFECTIOUS then
                        -- THE SHEDDING PREDICATE: the STATE of every record the arm above admits.
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
--- Alive, holds no record of the title in ANY state, and every model prerequisite
--- matches; the closed reason lets a caller report a refusal without reading the log.
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

    -- ANY record of this title refuses, whatever its state. The record's STATE is
    -- deliberately NOT read: reading it would let a recovered animal be reinfected
    -- inside its own immunity window.
    for _, record in pairs(animal.diseases or {}) do
        if record.title == title then return false, REASON.HOLDS_RECORD end
    end

    -- Normalized AHEAD of reading `prerequisites`, so a nil or scalar model walks
    -- nothing instead of raising on the index.
    if type(model) ~= "table" then return true end

    for _, prerequisite in ipairs(model.prerequisites or {}) do

        local path = prerequisite.path

        -- ONE predicate for the absent path and the empty one: an unguarded walk over an
        -- empty path never descends, so it would compare the ANIMAL TABLE against the
        -- authored value and refuse every animal forever, silently.
        if type(path) ~= "table" or #path == 0 then
            return false, REASON.PREREQUISITE
        end

        local currentValue = animal

        -- `ipairs`, not the shipped loop's `pairs`: `path` is `string.split`'s ordered
        -- array, and descending it in hash order reads the wrong field.
        for _, segment in ipairs(path) do
            -- A TYPE test rather than a nil test, and the difference is reachable: a
            -- dotted path descending through a boolean or a number raises on the index,
            -- and a raise here aborts the whole pen tick of whatever drives this pass.
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
--- TWO passes: every shedding title is resolved and priced ONCE, above the recipient
--- walk, and then each live animal draws once per eligible (animal, title) pair. Mutates
--- nothing - not the animals, not their records, not the input collection.
--- @param animals table|nil The pen's animals. A non-table returns the empty plan.
--- @param ctx table|nil `{ diseases = <title -> { model, maxLifespanMonths,
---        incubationTicks }>, daysPerPeriod = <number>, rng = <function|nil> }`. A
---        non-table returns the empty plan. `rng` is a zero-argument generator returning
---        `[0, 1)`, defaulting to `math.random` - a TRUSTED INTERNAL TEST SEAM.
--- @return table infections Array of `{ animal = <live reference>, title = <string> }`
---         in animal-major, title-sorted order. THAT ORDER IS CONTRACT.
--- @return table stats `{ population, shedders, rates, monthly, unpriced, skipped,
---         rolls }` - all seven FIELDS present on EVERY return path, so a caller never
---         nil-checks a field. `monthly` carries the CLAMPED monthly rate each priced
---         title converted from, and a value of 1 there is the SATURATION tell `rates`
---         cannot give. The five table fields are EMPTY rather than pre-keyed, so
---         `stats.skipped.DEAD` is nil and not 0.
function RLDiseaseSpread.plan(animals, ctx)
    local infections = {}

    -- Built up front and returned by every path below, so the shape is never partially
    -- nil. `skipped` counts (animal, title) PAIRS rather than animals. `rates` is
    -- populated for every PRICED title whether or not it found a recipient, because it
    -- is the pass's only non-stochastic observable.
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

    -- A FRESH copy rather than the table the collector counted into. Measured vacuous
    -- today - `counts` is local and dies with this call - and kept because handing out a
    -- table this function still reads is the shape that stops being safe first.
    for title, amount in pairs(counts) do stats.shedders[title] = amount end

    -- ONE inverted comparison rather than `<= 0`, matching the sibling rate modules.
    -- `population` is a local integer this file increments, so ZERO is the only value it
    -- can take here and the NaN and negative arms are defensive by FORM; what the guard
    -- buys today is the division below never being formed on an empty pen.
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

    -- SORTED, and load-bearing rather than cosmetic: it is what makes the draw sequence
    -- identical between the two runners and between runs.
    table.sort(titles)

    -- PASS ONE: resolve and price each shedding title exactly once.
    local priced = {}
    local diseases = ctx.diseases or {}

    for _, title in ipairs(titles) do

        local entry = diseases[title]

        -- ONE predicate covering both refusable shapes - no entry, and an entry whose
        -- model half was refused at parse. REFUSED rather than defaulted: a default model
        -- would price a disease against numbers its author never wrote.
        if type(entry) ~= "table" or type(entry.model) ~= "table" then
            Log:debug("RLDiseaseSpread.plan: refused title=%s - the ctx carries no usable "
                .. "model for it, so nobody is offered this disease", tostring(title))

            stats.unpriced[title] = true
        else
            local prevalence = counts[title] / population
            -- BOTH returns are kept: the second is the CLAMPED monthly rate, the only
            -- thing separating a SATURATED pen from an honest one. This module RECORDS it
            -- and draws no conclusion from it.
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

    -- PASS TWO: walk the live animals and draw per eligible pair. The dead are filtered
    -- HERE rather than through `isEligible`, which keeps its own DEAD arm for its other
    -- callers - so `stats.skipped.DEAD` is always zero from `plan`, and that is contract.
    for _, animal in ipairs(animals) do

        if not animal.isDead then

            for _, entry in ipairs(priced) do

                local eligible, reason = RLDiseaseSpread.isEligible(animal, entry.title,
                    entry.model)

                if eligible then
                    -- Eligibility runs BEFORE the draw, so a refused recipient consumes no
                    -- randomness and the draw budget is a pure function of the collection.
                    local draw = rng()

                    stats.rolls = stats.rolls + 1

                    Log:trace("RLDiseaseSpread.plan: rolled title=%s uniqueId=%s farmId=%s "
                        .. "prevalence=%s rate=%s draw=%s hit=%s",
                        tostring(entry.title), tostring(animal.uniqueId),
                        tostring(animal.farmId), tostring(entry.prevalence),
                        tostring(entry.rate), tostring(draw), tostring(draw < entry.rate))

                    -- STRICTLY below, never at, which is what makes a rate of 0 never fire.
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
                    -- A nil reason is the non-table animal, deliberately NOT tallied:
                    -- writing a nil table key raises.
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


Log:info("RLDiseaseSpread loaded")
