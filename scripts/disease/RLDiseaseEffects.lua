--[[
    RLDiseaseEffects.lua
    The one home for turning an animal's SEIR records into the six sub-lethal
    multipliers its production and its body are scaled by.

    SIX CHANNELS, AUTHORED IN TWO PLACES ON THE MODEL. Four of them multiply what
    leaves the pen - `milk`, `pallets` (eggs and wool), `manure` and `liquidManure` -
    and are authored inside `<model><effects><output type modifier>`. The other two
    hit the animal itself and are authored as attributes on `<effects>`:
    `weightGain` and `fertility`. The four output names cannot express the second
    pair, which is why the split exists.

    ONLY AN INFECTIOUS RECORD CONTRIBUTES, and the EXPOSED case is a deliberate
    ANTI-DECISION rather than an oversight. An incubating animal produces exactly as
    a healthy one does: that is what makes incubation invisible, and a partial dip
    during it would hand the player the early warning the design withholds on
    purpose. RECOVERED, DEAD, SUSCEPTIBLE and any value a later codec retired all
    contribute nothing too, and ONE state test covers all five - exactly as
    `RLDiseaseFatality.roll`'s does.

    THE FOLD IS MULTIPLICATIVE, ACROSS RECORDS AND ACROSS CHANNELS. Two records at
    0.5 on one channel leave a quarter, which is what the shipped `updateOutput` loop
    this eventually replaces already does.

    A VALUE ABOVE 1 IS CARRIED THROUGH UNCLAMPED. ped authors `liquidManure="4"` -
    four times the slurry - so this is "what does the disease do to output", not a
    penalty channel. There is no upper clamp anywhere in this module, and adding one
    would silently delete an authored effect.

    EVERY RETURNED TABLE CARRIES ALL SIX KEYS, ALWAYS, SEEDED AT 1.0, and it is FRESH
    on every call. A consumer never writes `or 1` and never has to wonder whether the
    table it holds is shared: an absent scalar, an empty output map, an empty record
    array and a non-table argument all return the same complete identity table, and
    no module-level table is ever returned by reference. A caller mutating its result
    cannot poison the next one.

    `contributors` IS THE SECOND RETURN, AND ITS DEFINITION IS LOAD-BEARING. It
    counts records that RESOLVED - INFECTIOUS, with a title present in `models`,
    whose model carries an `effects` table - and nothing else. It exists because an
    identity table comes back for two completely different situations: no record
    contributed at all, and a record contributed exactly 1.0 on all six (cvm's model
    half authors 1 / 1 and an empty output map). The multiplier table alone cannot
    separate them; this count is the only thing that can. It is also a number the
    fold already computed, so a caller logging the outcome recomputes nothing.

    RECORD ORDER IS THE CALLER'S OBLIGATION, and the determinism claim is scoped to a
    fixed array. Float multiplication is not associative, so three or more
    contributing records can produce products differing in the last ulp between two
    orderings; two factors are commutative and cannot. This module walks `ipairs` and
    does NOT sort - sorting per call in a per-animal loop buys nothing the caller
    cannot do once - so the canonical order belongs to whoever builds the array. Until
    that lands the claim is "identical for the same array", never "identical across
    peers".

    NOTE WHAT THE ORDERED CHANNEL LISTS ARE AND ARE NOT FOR. They exist for SEED
    COMPLETENESS and a stable log line, never for float determinism: each channel is
    an INDEPENDENT accumulator touched once per record, so the order the channels are
    walked in cannot change any channel's product. Reading them as a float-ordering
    device is the mistake to avoid - the axis that does matter is the RECORD order
    above.

    A PARSER-PRODUCED MODEL IS TRUSTED BELOW ITS FIRST LEVEL, and two facts license
    that. `RLDiseaseDefinition.buildModelEntry` assigns `model.effects`
    unconditionally on every path that returns a model, and `readModelOutputs` opens
    `local output = {}` and always returns it. So `model.effects` and
    `model.effects.output` are read here without type tests: every shape a guard
    would catch needs a hand-built table, whose actor is the mod author or a test
    fixture, not a player.

    THE TWO ARGUMENTS ARE DIFFERENT AND ARE GUARDED, AND THE REASON IS CONTAINMENT
    RATHER THAN SILENCE. Be precise about this, because the obvious framing is
    backwards: WITHOUT the guards a nil `records` raises inside `ipairs` and a nil
    `models` raises on the first title lookup, so the unguarded code fails LOUDLY -
    the guards are what create the identity-return path, not what prevent one. What
    they buy is where the failure lands. The intended consumers run this per animal
    inside a pen's tick, and a raise there aborts the whole pen's update; a logged
    identity return degrades one animal's multipliers and lets the tick finish. So
    the trade is a contained, logged wrong answer over an uncontained abort, on a
    path whose only realistic caller error is a wiring bug in code that has not
    shipped yet.

    THE CARRIER PROFILE IS PARSED AND DELIBERATELY NOT READ HERE. cvm authors
    `<carrier><effects><output type="milk" modifier="1.5"/>` and the parser reads it
    correctly into the model's own carrier profile. Nothing in this module can reach
    it, and the reason is structural: a SEIR record carries eight keys and none of
    them is a carrier flag. The player-visible carrier bonus belongs to the slice that
    owns carriers.

    BE PRECISE ABOUT THE GENETIC EXCLUSION, because the obvious reading over-claims -
    the same wording the transmission pass carries for the same gate. A separate
    ticket intends to keep a genetic archetype out of SEIR flow, which would mean cvm
    never produces a record reaching this module at all, but THAT GATE HAS NO SITE
    YET. Nothing here reads `archetype`, so the exclusion is the caller's obligation
    rather than a property of this file. One consequence is worth stating plainly:
    until that gate exists cvm CAN reach `resolve`, and it is precisely the record
    whose model authors 1 / 1 with an empty output map - so the contributor count's
    identity-with-a-contributor case is reachable today rather than hypothetical.

    NO NaN OR INFINITY GUARD, AND THAT IS A DELIBERATE DIVERGENCE FROM TWO SIBLINGS.
    The fatality and transmission modules both carry inverted comparisons written
    specifically to catch a NaN, and this module carries none - so the difference is
    worth naming rather than leaving as an apparent omission. Those two DERIVE their
    rates through division and exponentiation, where a NaN is manufactured by the
    arithmetic itself; this one only multiplies numbers an author wrote. A NaN or an
    infinity therefore reaches the fold only from a hand-edited definition file, whose
    actor is the mod author and who finds out on the next launch. `readNonNegative`
    refuses a negative and nothing else, so such a value does parse - it would poison
    one channel for one disease, visibly, rather than corrupt a save or move money.
    Guarding it here would be a defence against the mod's own shipped data.

    THE DISEASES-ENABLED SETTING IS NOT READ EITHER. This module reads no setting, no
    animal, no `g_*` and no registry; every input arrives as a parameter. Each
    consumer applies its own gate, along with its own lactation factor and its own
    pallets-versus-tank split.

    RELIEF DOES NOT REACH ANY MULTIPLIER TODAY. A completed course whose outcome is
    relief returns a result value nothing reads: expressing relief here would need
    either a ninth record key - locked out, and already refused once - or an authored
    relief effects block, which is a schema change. A separate issue owns whether
    relief should ever mean something.

    THIS IS THE FIFTH PREDICATE OVER THE SAME DOMAIN AND MUST NOT BE UNIFIED WITH ANY
    OF THE OTHER FOUR. `Animal:getHasAnyDisease` asks "should a player see this animal
    as sick"; `DiseaseManager.collectTransmissionSources` asks "is this animal
    shedding" under the legacy record; `Disease:getStatus`'s paused arm asks "does this
    record hold progress"; `RLDiseaseSpread` asks "is this record shedding under SEIR";
    and this one asks "is this record costing its owner output". They read different
    fields and answer different questions. A shared active-record helper is the repair
    that must not be made.

    Pure data-in / data-out. No `g_*`, no GUI, no XML, no engine natives, no
    randomness - and no animal method, mission or registry read. RmLogging at file
    scope is the only unconditional dependency; `RLDiseaseRecord` is reached at CALL
    time only, which is why this file's position in the loader is ordinary rather
    than required.

    SHARP EDGES, named so the next reader does not rediscover them.

      an unknown channel   a key in a model's output map that is not one of the four
                           is IGNORED, with one DEBUG line per key per record. The
                           parser allowlists the same four names, so the only
                           reachable producer is a FUTURE parser change adding a
                           fifth channel that this module does not learn about - and
                           that line is the runtime half of the alarm for it.
      an unknown title     a record whose title resolves to no model contributes
                           nothing, with one DEBUG line naming it. Never a default
                           model, never an identity fabricated silently. This IS
                           reachable in production: a savegame can hold a record for
                           a disease a later mod version removed from the definition
                           file.
      a nil title          skipped with one DEBUG line. Indexing a map with a nil KEY
                           is a READ and is safe - Lua raises on a nil key only on a
                           WRITE - so the line is what makes the skip visible rather
                           than what makes it safe.
      a sparse array       the `ipairs` walk stops at the first hole, so the logged
                           record count is the WALKED count and never the length
                           operator, which is implementation-defined on such an array.
                           Contract, matching every other ordered walk in this family.
      a map-shaped input   a title-keyed records table walks zero elements and
                           returns identity. That is the likeliest wiring mistake -
                           it is the shape the shipped output loop walks today - so a
                           walked count of zero over a non-empty table emits its own
                           DEBUG line rather than passing silently.

    THE FOUR OUTPUT CHANNEL NAMES LIVE IN TWO PLACES, and this slice deliberately does
    not unify them. `RLDiseaseDefinition` holds its own file-local allowlist that
    refuses an unknown type at parse time; this module needs its own ordered list to
    seed the identity table and to walk the fold. Promoting one into a shared home is
    a sibling edit. The residual is real and carries two alarms: the runtime DEBUG
    line above, and a mechanical check that every name declared here is present in the
    parser.

    Nothing calls this module yet. The four fill-type channels and the two animal
    channels are wired by their own slices, each of which owns its own gating and its
    own hoisting - the shipped `updateOutput` folds diseases INSIDE a per-fillType
    loop, so a naive port would call `resolve` once per fill type per animal per tick.
    Nothing in the tree yet produces the record shape this module reads either; the
    switchover that changes it also owns the canonical order of the record array.
]]

RLDiseaseEffects = {}

local Log = RmLogging.getLogger("RLRM")


--- The four channels that multiply what leaves the pen, in fold order.
---
--- `RLDiseaseDefinition` holds a file-local allowlist of the SAME four names and
--- refuses an unknown type at parse time. Unifying the two into one shared home is a
--- sibling edit and is deliberately not done here, so the drift is real: a FIFTH
--- channel added to the parser and not to this list parses cleanly and is then
--- silently dropped by the fold. The unknown-channel DEBUG line in `resolve` is the
--- runtime alarm for exactly that, and a mechanical name check is the static one.
---
--- ORDERED, and the order is for SEED COMPLETENESS and a stable log line - never for
--- float determinism. Each channel is an independent accumulator touched once per
--- record, so walking them in a different order cannot change any channel's product.
---
--- MUST stay DISJOINT from `ANIMAL_CHANNELS`: their union is what `newIdentity`
--- seeds, so a name appearing in both would yield a five-key table.
---
--- READ-ONLY by contract: consumers share this object and there is deliberately no
--- defensive copy, exactly like `RLDiseaseRecord.STATE` and
--- `RLDiseaseFatality.FATALITY_RESULT`.
RLDiseaseEffects.OUTPUT_CHANNELS = { "milk", "pallets", "manure", "liquidManure" }


--- The two channels that hit the animal rather than the pen's output, in fold order.
---
--- Authored as ATTRIBUTES on the effects element rather than as output rows, because
--- the four output names cannot express them. Same ordering rationale and the same
--- READ-ONLY-by-contract status as `OUTPUT_CHANNELS`, and disjoint from it.
RLDiseaseEffects.ANIMAL_CHANNELS = { "weightGain", "fertility" }


--- The OUTPUT channel names as a SET, for the drift alarm's membership test.
---
--- Built from the ordered list rather than hand-written beside it, so the two cannot
--- disagree. It exists because the alarm cannot test membership in the RESULT table:
--- that table is seeded from BOTH lists, so `result[name] ~= nil` is true for
--- `weightGain` and `fertility` as well - and an `effects.output.weightGain` would
--- then be dropped by the fold (which reads the animal channels off `effects`, not
--- off `effects.output`) while the alarm stayed silent. MEASURED: before this set
--- existed, that key folded nothing and reported nothing, so the alarm had a hole on
--- exactly the two names most likely to be mis-nested by an author.
local OUTPUT_CHANNEL_SET = {}

for _, name in ipairs(RLDiseaseEffects.OUTPUT_CHANNELS) do
    OUTPUT_CHANNEL_SET[name] = true
end


--- A fresh six-key multiplier table, every channel at 1.0.
---
--- Built by WALKING the two ordered lists rather than from a literal, so a channel
--- added to a list cannot be forgotten in the seed. That is also what makes the
--- disjointness rule above load-bearing: a name in both lists is seeded twice and
--- the table comes back with five keys.
--- @return table multipliers A fresh table carrying all six channel names at 1.0
local function newIdentity()
    local result = {}

    for _, name in ipairs(RLDiseaseEffects.ANIMAL_CHANNELS) do result[name] = 1.0 end
    for _, name in ipairs(RLDiseaseEffects.OUTPUT_CHANNELS) do result[name] = 1.0 end

    return result
end


--- Resolve an animal's sub-lethal multipliers from its records.
---
--- Walks the record array ONCE with `ipairs`, keeps only the records at INFECTIOUS,
--- resolves each one's model by title, and folds its authored effects into a fresh
--- six-key table seeded at 1.0 on every channel.
---
--- Mutates nothing - not the records, not the models, not the array. The result is a
--- fresh table the caller may keep or discard.
--- @param records table|nil An ORDERED ARRAY of SEIR records, each carrying `title`
---        and `state`. TRUSTED INTERNAL input in its CONTENTS and type-guarded at the
---        top level: a nil, `false` or non-table returns the identity table with one
---        DEBUG line, because a wiring bug here produces silently wrong output rather
---        than a crash. The ORDER is the caller's obligation - see the header.
--- @param models table|nil The title-keyed model map `RLDiseaseDefinition.parse`
---        returns. Same guard, same reason. Trusted BELOW its first level: a
---        parser-produced entry always carries an effects table whose output map is
---        always a table, so neither is type-tested.
--- @return table multipliers Six keys, always, always fresh, never nil-valued, never
---         clamped
--- @return number contributors How many records RESOLVED - INFECTIOUS, title known,
---         model carrying effects. The only thing separating "nothing contributed"
---         from "everything contributed exactly 1.0"
function RLDiseaseEffects.resolve(records, models)
    local result = newIdentity()
    local contributors = 0

    -- BOTH arguments are guarded, and each logs. The silent early return is the
    -- failure mode worth avoiding here: a consumer passing nil would otherwise get
    -- identity multipliers on every animal with nothing in the log to say so.
    if type(records) ~= "table" then
        Log:debug("RLDiseaseEffects.resolve: refused - records is a %s, not a table; "
            .. "returning identity multipliers", type(records))

        return result, contributors
    end

    if type(models) ~= "table" then
        Log:debug("RLDiseaseEffects.resolve: refused - models is a %s, not a table; "
            .. "returning identity multipliers", type(models))

        return result, contributors
    end

    -- Read at CALL time through the record module's own vocabulary rather than
    -- against an uppercase literal, so the five state names keep one home.
    local INFECTIOUS = RLDiseaseRecord.STATE.INFECTIOUS

    local walked = 0

    for _, record in ipairs(records) do

        walked = walked + 1

        if type(record) ~= "table" then
            Log:debug("RLDiseaseEffects.resolve: skipped element %s - it is a %s, not a "
                .. "record table", tostring(walked), type(record))
        elseif record.state ~= INFECTIOUS then
            -- ONE guard covering all four other STATE values and any unrecognised one
            -- an older codec might produce. TRACE rather than DEBUG because this is
            -- the ordinary case for a recovered or incubating animal and it fires per
            -- record per call.
            --
            -- The EXPECTED state is rendered from the vocabulary rather than spelled
            -- as a literal, for the same reason the comparison above reads it there:
            -- the record module is the one home for the five names, so a diagnostic
            -- that hardcoded one would go stale under a rename the comparison follows.
            Log:trace("RLDiseaseEffects.resolve: skipped title=%s - state is %s, not %s",
                tostring(record.title), tostring(record.state), tostring(INFECTIOUS))
        else
            local title = record.title

            if title == nil then
                -- Indexing the model map with a nil key would be a safe READ, so this
                -- line is what makes the skip visible rather than what makes it safe.
                Log:debug("RLDiseaseEffects.resolve: skipped an INFECTIOUS record at "
                    .. "index %s - it carries no title", tostring(walked))
            else
                local model = models[title]

                if model == nil then
                    -- REACHABLE IN PRODUCTION: a savegame can hold a record whose
                    -- disease a later mod version removed from the definition file.
                    -- Refused rather than defaulted - a fabricated identity would be
                    -- indistinguishable from a disease that genuinely does nothing.
                    Log:debug("RLDiseaseEffects.resolve: title=%s resolves to no model, "
                        .. "so it contributes nothing", tostring(title))
                else
                    local effects = model.effects

                    -- Trusted below the first level: `buildModelEntry` assigns the
                    -- effects table on every path that returns a model, and
                    -- `readModelOutputs` always returns a table. See the header for
                    -- why the arguments above are guarded and this is not.
                    local outputs = effects.output

                    -- ANIMAL channels first, then OUTPUT channels, each walked in its
                    -- own list order. Multiplying only where the value is non-nil is
                    -- what makes an absent scalar contribute nothing rather than
                    -- zeroing the channel: `readNonNegative` returns nil for an absent
                    -- attribute, so a model declaring neither scalar is a SHIPPED
                    -- shape rather than a malformed one.
                    for _, name in ipairs(RLDiseaseEffects.ANIMAL_CHANNELS) do
                        local value = effects[name]
                        if value ~= nil then result[name] = result[name] * value end
                    end

                    for _, name in ipairs(RLDiseaseEffects.OUTPUT_CHANNELS) do
                        local value = outputs[name]
                        if value ~= nil then result[name] = result[name] * value end
                    end

                    -- THE ONE `pairs` WALK IN THIS MODULE, and it exists only to log.
                    -- It reports a key the parser would have to start emitting for the
                    -- two vocabularies to have drifted apart - the runtime half of the
                    -- drift alarm the header describes. One line per unknown key per
                    -- record; an authored map holds at most four entries.
                    for name in pairs(outputs) do
                        if not OUTPUT_CHANNEL_SET[name] then
                            Log:debug("RLDiseaseEffects.resolve: title=%s authors output "
                                .. "channel %s, which this module does not carry - the "
                                .. "value is IGNORED", tostring(title), tostring(name))
                        end
                    end

                    contributors = contributors + 1
                end
            end
        end

    end

    -- THE MAP-SHAPED-INPUT ALARM. A title-keyed table walks zero elements under
    -- `ipairs` and returns identity, and that is the likeliest wiring mistake because
    -- it is the shape the shipped output loop walks today. `next` distinguishes it
    -- from a genuinely empty array, which is an ordinary and silent case.
    if walked == 0 and next(records) ~= nil then
        Log:debug("RLDiseaseEffects.resolve: walked 0 records from a NON-EMPTY table - "
            .. "the array is sparse at index 1, or the records table is keyed rather "
            .. "than ordered; returning identity multipliers")
    end

    -- ONE line per completed call, carrying the WALKED count rather than the length
    -- operator, which is implementation-defined on a sparse array. TRACE because the
    -- intended callers run this per animal per tick.
    --
    -- BE PRECISE ABOUT WHAT THE LEVEL BUYS, because the obvious reading is wrong: Lua
    -- evaluates a call's arguments before the logger ever sees the level, so the eight
    -- `tostring()` calls below are paid at TRACE exactly as they would be at DEBUG,
    -- and at every level including OFF. What TRACE buys is the FORMATTING, the
    -- EMISSION and a readable default development view - not the argument evaluation.
    Log:trace("RLDiseaseEffects.resolve: walked=%s contributors=%s -> weightGain=%s "
        .. "fertility=%s milk=%s pallets=%s manure=%s liquidManure=%s",
        tostring(walked), tostring(contributors), tostring(result.weightGain),
        tostring(result.fertility), tostring(result.milk), tostring(result.pallets),
        tostring(result.manure), tostring(result.liquidManure))

    return result, contributors
end


-- TEN SITES LOG HERE - the two argument guards, the non-table element, the nil
-- title, the unresolved title, the unknown channel key, the map-shaped-input alarm,
-- the off-INFECTIOUS skip, the per-call summary and the load line - at THREE levels,
-- and the split between them is by FREQUENCY rather than by taste.
--
-- The off-INFECTIOUS skip and the per-call summary are TRACE, because both fire on
-- the ordinary path: a healthy or recovered animal is the common case, and the
-- summary fires once per call on a path the consumers run per animal per tick.
-- Everything else is DEBUG, because every one of them reports a data shape that
-- should not occur and that nothing else in the log would name.
--
-- The load line is the third level, INFO, and it is the one every sibling module in
-- this family ends on - it marks that the module reached the end of its own source.
--
-- NO OTHER LINE ABOVE DEBUG, deliberately. Every branch here is a data-shape observation
-- rather than a condition an admin acts on: an unresolved title is a savegame that
-- outlived a definition change, an unknown channel is an authoring drift, and a
-- non-table argument is a wiring bug in code that has not shipped yet. A WARNING on
-- any of them would put a per-record line into the production INFO budget for a
-- condition the player can do nothing about.
--
-- EVERY LINE FORMATS ITS CALLER-SUPPLIED VALUES WITH `%s` AND `tostring()`, never
-- with concatenation. That is a contract rather than a style preference: the in-game
-- logger pcall-wraps its own formatting and degrades on a bad argument, while the
-- headless harness formats bare and RAISES on the same input - so a concatenated nil
-- or table title would turn a diagnostic into a runner abort on one runtime only.
Log:info("RLDiseaseEffects loaded")
