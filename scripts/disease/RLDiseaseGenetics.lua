--[[
    RLDiseaseGenetics.lua
    The genetics half of a genetic disease: Mendelian inheritance at conception, the draw
    that seeds a dealer animal, the affected animal's daily death roll, and the carrier
    output profile.

    A genetic record never runs the SEIR course. An affected animal is held at INFECTIOUS
    and dies on its model's own terminal hazard; a carrier is held at EXPOSED for life and
    folds its carrier profile into output.

    Pure data-in / data-out: an injected zero-arg `rng` defaulting to `math.random`, no
    setting and no `g_*`. RLDiseaseFatality and RLDiseaseEffects are read at CALL time only.
]]

RLDiseaseGenetics = {}

local Log = RmLogging.getLogger("RLRM")


--- What an affected animal's death roll did. READ-ONLY by contract.
RLDiseaseGenetics.DEATH_RESULT = {
    ["DIED"] = "DIED",
    ["SURVIVED"] = "SURVIVED"
}

--- Chance a parent holding ONE copy passes it on, drawn with `<=` rather than an authored strict `<`.
RLDiseaseGenetics.SINGLE_COPY_PASS_CHANCE = 0.5

--- Share of seeded dealer animals holding TWO copies, drawn with `<=` rather than an authored strict `<`.
RLDiseaseGenetics.SEEDED_TWO_COPY_SHARE = 0.25

--- The vulnerability an affected animal's death is priced at, so health, genetics and age never scale it.
RLDiseaseGenetics.AFFECTED_VULNERABILITY = 1


--- Resolve a newborn's copies from both parents, drawing once per parent that holds exactly one.
---@param genesA number This record's copies, 0..2; its draw comes first.
---@param genesB number The other parent's copies of the same title, 0 when it holds none.
---@param genetic table The model's `genetic` block: `recessive`, `dominant`, `saleChance`.
---@param rng function|nil Zero-arg generator returning [0, 1); defaults to `math.random`.
---@return number genes The newborn's copies, 0..2; 0 means it inherits no record.
---@return boolean isCarrier True only for a single recessive copy.
function RLDiseaseGenetics.inherit(genesA, genesB, genetic, rng)
    rng = rng or math.random

    local parents = { genesA, genesB }
    local copies = 0

    -- Two copies always pass one and none never does, so only a single copy draws.
    for i = 1, 2 do
        if parents[i] == 2 then
            copies = copies + 1
        elseif parents[i] == 1 and rng() <= RLDiseaseGenetics.SINGLE_COPY_PASS_CHANCE then
            copies = copies + 1
        end
    end

    local isCarrier = copies == 1 and genetic.recessive == true

    Log:trace("RLDiseaseGenetics.inherit: parents=%s+%s recessive=%s -> genes=%s carrier=%s",
        tostring(genesA), tostring(genesB), tostring(genetic.recessive), tostring(copies),
        tostring(isCarrier))

    return copies, isCarrier
end


--- Draw whether a freshly generated dealer animal holds this disease, and how many copies.
---@param genetic table The model's `genetic` block: `recessive`, `dominant`, `saleChance`.
---@param rng function|nil Zero-arg generator returning [0, 1); defaults to `math.random`.
---@return number|nil genes 1 or 2 on a hit; nil on a miss.
---@return boolean|nil isCarrier True only for a single recessive copy; nil on a miss.
function RLDiseaseGenetics.seedForSale(genetic, rng)
    rng = rng or math.random

    local draw = rng()

    -- STRICTLY below the authored probability, so a saleChance of 0 never seeds.
    if not (draw < genetic.saleChance) then
        Log:trace("RLDiseaseGenetics.seedForSale: missed, draw=%s saleChance=%s",
            tostring(draw), tostring(genetic.saleChance))

        return nil
    end

    local genes = rng() <= RLDiseaseGenetics.SEEDED_TWO_COPY_SHARE and 2 or 1
    local isCarrier = genetic.recessive == true and genes == 1

    Log:trace("RLDiseaseGenetics.seedForSale: hit, draw=%s saleChance=%s -> genes=%s carrier=%s",
        tostring(draw), tostring(genetic.saleChance), tostring(genes), tostring(isCarrier))

    return genes, isCarrier
end


--- Roll one daily tick of an affected animal's death against its model's own terminal hazard.
---@param model table The genetic disease's parsed model entry.
---@param daysPerPeriod number Ticks in one period, 1..28.
---@param rng function|nil Zero-arg generator returning [0, 1); defaults to `math.random`.
---@return string result A `DEATH_RESULT` value.
---@return number hazard The per-tick probability the draw was compared against.
function RLDiseaseGenetics.rollAffectedDeath(model, daysPerPeriod, rng)
    rng = rng or math.random

    local RESULT = RLDiseaseGenetics.DEATH_RESULT
    local hazard = RLDiseaseFatality.perTickHazard(model, RLDiseaseGenetics.AFFECTED_VULNERABILITY,
        daysPerPeriod)
    local draw = rng()
    local result = RESULT.SURVIVED

    if draw < hazard then result = RESULT.DIED end

    Log:trace("RLDiseaseGenetics.rollAffectedDeath: title=%s dpp=%s hazard=%s draw=%s result=%s",
        tostring(model.title), tostring(daysPerPeriod), tostring(hazard), tostring(draw),
        tostring(result))

    return result, hazard
end


-- Folded WHATEVER the record's state: a carrier sits at EXPOSED for life, and its profile is a
-- carried gene rather than a symptom, so the resolver's INFECTIOUS gate does not apply to it.
--- Fold every carrier record's output profile into a fresh four-channel table seeded at 1.0.
---@param records table An ORDERED ARRAY of disease records; the order is the caller's obligation.
---@param models table The title-keyed model map the definition parser returns.
---@return table multipliers The four output channels, always all four, always a fresh table.
---@return number count How many carrier records folded a profile.
function RLDiseaseGenetics.carrierOutputs(records, models)
    local channels = RLDiseaseEffects.OUTPUT_CHANNELS
    local result = {}
    local count = 0

    for _, name in ipairs(channels) do result[name] = 1.0 end

    for _, record in ipairs(records) do
        if record.isCarrier == true then
            local model = models[record.title]

            if model ~= nil and model.carrier ~= nil then
                local output = model.carrier.output

                for _, name in ipairs(channels) do
                    local value = output[name]
                    if value ~= nil then result[name] = result[name] * value end
                end

                count = count + 1
            else
                Log:trace("RLDiseaseGenetics.carrierOutputs: skipped carrier title=%s, no carrier profile",
                    tostring(record.title))
            end
        end
    end

    Log:trace("RLDiseaseGenetics.carrierOutputs: count=%s -> milk=%s pallets=%s manure=%s liquidManure=%s",
        tostring(count), tostring(result.milk), tostring(result.pallets), tostring(result.manure),
        tostring(result.liquidManure))

    return result, count
end


Log:info("RLDiseaseGenetics loaded")
