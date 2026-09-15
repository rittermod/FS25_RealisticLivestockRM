--[[
    RLDiseaseEffects.lua
    Folds an animal's SEIR records into the six sub-lethal multipliers its
    production and its body are scaled by: `milk`, `pallets`, `manure` and
    `liquidManure`, authored inside `<model><effects><output>`, plus `weightGain`
    and `fertility`, authored as attributes on `<effects>`.

    A three-way state gate: an INFECTIOUS record folds all six authored effects; a
    non-genetic EXPOSED record folds only the four output channels, at EXPOSED_SHARE of
    each effect's distance from 1; every other record folds nothing. The fold is
    multiplicative across records AND channels, and a value above 1 is carried UNCLAMPED.

    Pure data-in / data-out. RECORD ORDER is the caller's obligation: this module walks
    `ipairs` and does not sort.
]]

RLDiseaseEffects = {}

local Log = RmLogging.getLogger("RLRM")


-- The ONE home of the output-channel names: every consumer, the definition parser's allowlist
-- included, reads it at call time. READ-ONLY by contract, and DISJOINT from `ANIMAL_CHANNELS`,
-- since the union of the two seeds the result table.
--- The four channels that multiply what leaves the pen, in fold order.
RLDiseaseEffects.OUTPUT_CHANNELS = { "milk", "pallets", "manure", "liquidManure" }


--- The two channels that hit the animal rather than the pen's output, in fold order.
---
--- Authored as attributes rather than output rows, because the four output names
--- cannot express them. READ-ONLY by contract, and disjoint from `OUTPUT_CHANNELS`.
RLDiseaseEffects.ANIMAL_CHANNELS = { "weightGain", "fertility" }


-- Strictly between 0 and 1, so an incubating animal loses output well short of the symptomatic
-- effect, and each effect keeps its direction: one above 1 still raises its channel.
--- Share of each output effect's distance from 1 that a non-genetic EXPOSED record folds. READ-ONLY.
RLDiseaseEffects.EXPOSED_SHARE = 0.5


--- A fresh six-key multiplier table, every channel at 1.0.
---
--- Built by WALKING the two ordered lists rather than from a literal, so a channel
--- added to a list cannot be forgotten in the seed.
--- @return table multipliers A fresh table carrying all six channel names at 1.0
local function newIdentity()
    local result = {}

    for _, name in ipairs(RLDiseaseEffects.ANIMAL_CHANNELS) do result[name] = 1.0 end
    for _, name in ipairs(RLDiseaseEffects.OUTPUT_CHANNELS) do result[name] = 1.0 end

    return result
end


--- Resolve an animal's sub-lethal multipliers from its records into a fresh six-key table at 1.0.
--- @param records table|nil An ORDERED ARRAY of SEIR records, each carrying `title`
---        and `state`. Type-guarded at the TOP LEVEL only; the ORDER is the caller's
---        obligation.
--- @param models table|nil The title-keyed model map `RLDiseaseDefinition.parse`
---        returns. Same guard, and trusted BELOW its first level.
--- @return table multipliers Six keys, always, always fresh, never nil-valued, never
---         clamped
--- @return number contributors How many records took a folding arm - INFECTIOUS, or
---         non-genetic EXPOSED - with a title resolving to a model. The only thing
---         separating "nothing contributed" from "everything contributed exactly 1.0"
function RLDiseaseEffects.resolve(records, models)
    local result = newIdentity()
    local contributors = 0

    -- Guard what fails SILENTLY: unguarded, a nil argument raises loudly, but a
    -- consumer passing one would otherwise get identity multipliers on every animal
    -- with nothing in the log to say so.
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

    -- Read through the record module's own vocabulary, so the state names keep one
    -- home and a rename reaches the comparisons and the diagnostics together.
    local INFECTIOUS = RLDiseaseRecord.STATE.INFECTIOUS
    local EXPOSED = RLDiseaseRecord.STATE.EXPOSED
    local share = RLDiseaseEffects.EXPOSED_SHARE

    local walked = 0

    for _, record in ipairs(records) do

        walked = walked + 1

        local isTable = type(record) == "table"
        local infectious = isTable and record.state == INFECTIOUS
        -- A genetic record's EXPOSED state marks a lifelong carrier, not an incubation window.
        local incubating = isTable and record.state == EXPOSED and record.archetype ~= "genetic"

        if not isTable then
            Log:debug("RLDiseaseEffects.resolve: skipped element %s - it is a %s, not a "
                .. "record table", tostring(walked), type(record))
        elseif not infectious and not incubating then
            -- ONE guard covering the other states, any an older codec retired, and a
            -- genetic record at EXPOSED.
            Log:trace("RLDiseaseEffects.resolve: skipped title=%s - state is %s, archetype=%s; "
                .. "only %s, or a non-genetic %s, folds",
                tostring(record.title), tostring(record.state), tostring(record.archetype),
                tostring(INFECTIOUS), tostring(EXPOSED))
        else
            local title = record.title

            if title == nil then
                -- Indexing the map with a nil KEY would be a safe read, so this line is
                -- what makes the skip visible rather than what makes it safe.
                Log:debug("RLDiseaseEffects.resolve: skipped an %s record at index %s - it "
                    .. "carries no title", tostring(incubating and EXPOSED or INFECTIOUS),
                    tostring(walked))
            else
                local model = models[title]

                if model == nil then
                    -- REACHABLE IN PRODUCTION: a savegame can hold a record whose disease
                    -- a later mod version removed. Refused rather than defaulted, since a
                    -- fabricated identity reads as a disease that genuinely does nothing.
                    Log:debug("RLDiseaseEffects.resolve: title=%s resolves to no model, "
                        .. "so it contributes nothing", tostring(title))
                else
                    local effects = model.effects

                    -- Trusted below the first level: a parser-produced model always
                    -- carries an effects table whose output map is always a table.
                    local outputs = effects.output

                    if incubating then
                        -- Each authored output channel moves the share of the way from 1 toward
                        -- its effect; weight gain and fertility stay symptomatic only.
                        for _, name in ipairs(RLDiseaseEffects.OUTPUT_CHANNELS) do
                            local value = outputs[name]
                            if value ~= nil then
                                result[name] = result[name] * (1 + share * (value - 1))
                            end
                        end

                        Log:trace("RLDiseaseEffects.resolve: title=%s folded the incubation dip "
                            .. "at share=%s", tostring(title), tostring(share))
                    else
                        -- Multiply only where the value is non-nil, so a model declaring
                        -- neither scalar contributes nothing rather than zeroing a channel.
                        for _, name in ipairs(RLDiseaseEffects.ANIMAL_CHANNELS) do
                            local value = effects[name]
                            if value ~= nil then result[name] = result[name] * value end
                        end

                        for _, name in ipairs(RLDiseaseEffects.OUTPUT_CHANNELS) do
                            local value = outputs[name]
                            if value ~= nil then result[name] = result[name] * value end
                        end

                        Log:trace("RLDiseaseEffects.resolve: title=%s folded its authored effects",
                            tostring(title))
                    end

                    contributors = contributors + 1
                end
            end
        end

    end

    -- The map-shaped-input alarm: a title-keyed table walks zero elements and returns
    -- identity, and that is the likeliest wiring mistake because it is the shape the
    -- shipped output loop walks today. `next` separates it from an empty array.
    if walked == 0 and next(records) ~= nil then
        Log:debug("RLDiseaseEffects.resolve: walked 0 records from a NON-EMPTY table - "
            .. "the array is sparse at index 1, or the records table is keyed rather "
            .. "than ordered; returning identity multipliers")
    end

    -- The WALKED count, never `#records`, which is implementation-defined on a sparse
    -- array. TRACE because the intended callers run this per animal per tick.
    Log:trace("RLDiseaseEffects.resolve: walked=%s contributors=%s -> weightGain=%s "
        .. "fertility=%s milk=%s pallets=%s manure=%s liquidManure=%s",
        tostring(walked), tostring(contributors), tostring(result.weightGain),
        tostring(result.fertility), tostring(result.milk), tostring(result.pallets),
        tostring(result.manure), tostring(result.liquidManure))

    return result, contributors
end


Log:info("RLDiseaseEffects loaded (EXPOSED_SHARE=%s)", tostring(RLDiseaseEffects.EXPOSED_SHARE))
