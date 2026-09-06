--[[
    RLDiseaseEffects.lua
    Folds an animal's SEIR records into the six sub-lethal multipliers its
    production and its body are scaled by: `milk`, `pallets`, `manure` and
    `liquidManure`, authored inside `<model><effects><output>`, plus `weightGain`
    and `fertility`, authored as attributes on `<effects>`.

    Only an INFECTIOUS record contributes, so incubation stays invisible. The fold
    is multiplicative across records AND across channels, and a value above 1 is
    carried through UNCLAMPED - an authored effect may raise a channel rather than
    cut it, so a clamp would silently delete one.

    Pure data-in / data-out. RECORD ORDER is the caller's obligation: this module walks
    `ipairs` and does not sort.
]]

RLDiseaseEffects = {}

local Log = RmLogging.getLogger("RLRM")


--- The four channels that multiply what leaves the pen, in fold order.
---
--- MUST stay DISJOINT from `ANIMAL_CHANNELS`, whose union seeds the result table, and
--- READ-ONLY by contract. `RLDiseaseDefinition` holds its own allowlist of the same
--- four names; a fifth added there and not here parses and is then silently dropped.
RLDiseaseEffects.OUTPUT_CHANNELS = { "milk", "pallets", "manure", "liquidManure" }


--- The two channels that hit the animal rather than the pen's output, in fold order.
---
--- Authored as attributes rather than output rows, because the four output names
--- cannot express them. READ-ONLY by contract, and disjoint from `OUTPUT_CHANNELS`.
RLDiseaseEffects.ANIMAL_CHANNELS = { "weightGain", "fertility" }


--- The OUTPUT channel names as a SET, for the unknown-channel alarm's membership test.
---
--- The alarm cannot test against the RESULT table, which is seeded from BOTH lists: a
--- mis-nested `output.weightGain` would then fold nothing and report nothing too.
local OUTPUT_CHANNEL_SET = {}

for _, name in ipairs(RLDiseaseEffects.OUTPUT_CHANNELS) do
    OUTPUT_CHANNEL_SET[name] = true
end


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


--- Resolve an animal's sub-lethal multipliers from its records, folding each
--- INFECTIOUS record's authored effects into a fresh six-key table seeded at 1.0.
--- @param records table|nil An ORDERED ARRAY of SEIR records, each carrying `title`
---        and `state`. Type-guarded at the TOP LEVEL only; the ORDER is the caller's
---        obligation.
--- @param models table|nil The title-keyed model map `RLDiseaseDefinition.parse`
---        returns. Same guard, and trusted BELOW its first level.
--- @return table multipliers Six keys, always, always fresh, never nil-valued, never
---         clamped
--- @return number contributors How many records RESOLVED - INFECTIOUS, title known,
---         model carrying effects. The only thing separating "nothing contributed"
---         from "everything contributed exactly 1.0"
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

    -- Read through the record module's own vocabulary, so the five state names keep
    -- one home and a rename reaches the comparison and the diagnostic together.
    local INFECTIOUS = RLDiseaseRecord.STATE.INFECTIOUS

    local walked = 0

    for _, record in ipairs(records) do

        walked = walked + 1

        if type(record) ~= "table" then
            Log:debug("RLDiseaseEffects.resolve: skipped element %s - it is a %s, not a "
                .. "record table", tostring(walked), type(record))
        elseif record.state ~= INFECTIOUS then
            -- ONE guard covering the four other states and any an older codec retired.
            Log:trace("RLDiseaseEffects.resolve: skipped title=%s - state is %s, not %s",
                tostring(record.title), tostring(record.state), tostring(INFECTIOUS))
        else
            local title = record.title

            if title == nil then
                -- Indexing the map with a nil KEY would be a safe read, so this line is
                -- what makes the skip visible rather than what makes it safe.
                Log:debug("RLDiseaseEffects.resolve: skipped an INFECTIOUS record at "
                    .. "index %s - it carries no title", tostring(walked))
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

                    -- THE ONE `pairs` WALK IN THIS MODULE, and it exists only to log:
                    -- the runtime half of the parser-drift alarm.
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


Log:info("RLDiseaseEffects loaded")
