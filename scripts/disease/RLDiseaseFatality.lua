--[[
    RLDiseaseFatality.lua
    Turns an authored per-month case fatality into the per-tick hazard an infectious
    animal rolls, and moves the record to DEAD when that roll hits. The vulnerability
    factor arrives as a NUMBER - this module reads no animal and no registry.

    THE COMPOSITION ORDER IS THE CONTRACT: scale the MONTHLY rate, convert LAST.
        scaled = monthly * vulnerability            -- still per MONTH
        hazard = perTick(min(scaled, 1), daysPerPeriod)
    Scaling the per-TICK value instead makes cumulative risk depend on the player's
    days-per-period setting, which is the defect the two-clocks design removes.
]]

RLDiseaseFatality = {}

local Log = RmLogging.getLogger("RLRM")


--- What a fatality roll did, in the first return slot.
---
--- Deliberately NOT the record module's APPLIED / REFUSED / REMOVE trio: a survived
--- roll writes nothing. `NONE` is spelled the same as `TREATMENT_RESULT.NONE` and the
--- two vocabularies are NEVER fed to each other. READ-ONLY by contract.
RLDiseaseFatality.FATALITY_RESULT = {
    ["NONE"] = "NONE",
    ["SURVIVED"] = "SURVIVED",
    ["DIED"] = "DIED"
}


--- The survival probability a `terminal` model's median month count describes.
---
--- `chronicMonthsToDeath` is a MEDIAN, not a span - half of affected animals are dead
--- by that month - so raising this to the reciprocal of the median makes the death a
--- geometric tail rather than a deterministic event at the clock boundary. Public and
--- read at CALL time, so a suite can pin it.
RLDiseaseFatality.CHRONIC_SURVIVAL_AT_MEDIAN = 0.5


--- The authored per-MONTH fatality rate for a model, selected by its endpoint.
---
--- A CLOSED dispatch on `model.endpoint`, read through `RLDiseaseRecord.ENDPOINT` at
--- CALL time, so this module declares none of the four names.
--- @param model table|nil A parsed model entry. TRUSTED INTERNAL input; a nil or
---        non-table returns 0 rather than raising.
--- @return number monthly A per-month probability, or 0 for a model this module
---         cannot price
function RLDiseaseFatality.monthlyHazard(model)
    if type(model) ~= "table" then return 0 end

    local ENDPOINT = RLDiseaseRecord.ENDPOINT
    local endpoint = model.endpoint

    if endpoint == ENDPOINT.terminal then
        local median = model.chronicMonthsToDeath

        -- BEFORE any division, and that order is the point: `not (median > 0)` catches
        -- zero, a negative and a NaN in one test, and forming the reciprocal above it
        -- would emit an engine error line plus a callstack in-game.
        if not (median > 0) then
            return 1
        end

        -- Declared rather than left to fall out of the arithmetic: an infinite median
        -- gives a reciprocal of 0, a half raised to 0 is 1, so the disease never kills.
        if median == math.huge then
            return 0
        end

        return 1 - RLDiseaseFatality.CHRONIC_SURVIVAL_AT_MEDIAN ^ (1 / median)
    end

    -- Listed EXPLICITLY rather than reached by an `else`, so a fifth endpoint added
    -- later refuses below instead of silently inheriting `caseFatality`.
    if endpoint == ENDPOINT.recovers
        or endpoint == ENDPOINT.lifelong
        or endpoint == ENDPOINT.cureOnly then
        return model.caseFatality
    end

    Log:debug("RLDiseaseFatality.monthlyHazard: refused an unrecognised endpoint=%s "
        .. "- returning a hazard of 0 rather than inheriting caseFatality",
        tostring(endpoint))

    return 0
end


--- The per-tick hazard for one animal against one model: scale, reject, clamp, convert.
---
--- The guard is "non-positive or NaN", NOT "non-finite" - a positive infinity passes it
--- and clamps to certain death, deliberately, because an infinitely vulnerable animal
--- dying is right where a NaN means "no information about this animal".
--- @param model table|nil A parsed model entry. TRUSTED INTERNAL input.
--- @param vulnerability number The animal's factor, as `RLDiseaseVulnerability.factor`
---        returns it. TRUSTED INTERNAL input - a nil RAISES on the multiply,
---        deliberately, before any other arithmetic.
--- @param daysPerPeriod number Ticks in one period. TRUSTED INTERNAL input - a nil
---        RAISES inside the rate primitive. Read it at call time; never cache it.
--- @return number pTick The per-tick probability, 0 where the guard rejected the product
--- @return number monthly The monthly rate the hazard was derived from, so a caller
---         can log it without recomputing
function RLDiseaseFatality.perTickHazard(model, vulnerability, daysPerPeriod)
    local monthly = RLDiseaseFatality.monthlyHazard(model)

    -- The multiply is FIRST, so a nil vulnerability raises here rather than reaching
    -- the conversion. Still a per-MONTH quantity at this point.
    local scaled = monthly * vulnerability

    -- ONE inverted comparison rejecting zero, a negative product AND a NaN. The plain
    -- `<= 0` form passes a NaN straight through to the fold, whose first slot yields 1
    -- and would launder a meaningless product into certain death. It is also what makes
    -- the two runtimes agree on a NaN vulnerability.
    if not (scaled > 0) then
        return 0, monthly
    end

    -- The fold's argument order is INERT: the guard above already excluded every NaN,
    -- so this is a clamp and nothing else.
    return RLDiseaseRates.perTick(math.min(scaled, 1), daysPerPeriod), monthly
end


--- Roll one tick's fatality for an infectious record, moving it to DEAD on a hit.
---
--- The hazard is computed BEFORE the draw, so a nil `vulnerability` or `daysPerPeriod`
--- raises with the generator uncalled. Achieved is a draw strictly BELOW the hazard.
--- @param record table|nil A record from `RLDiseaseRecord.new`. TRUSTED INTERNAL
---        input; a nil or non-table returns NONE rather than raising.
--- @param model table|nil The parsed model entry for that record's disease. A nil or
---        `false` model - the ordinary conditional-and idiom yields `false` - returns
---        NONE.
--- @param vulnerability number The animal's factor. TRUSTED INTERNAL input.
--- @param daysPerPeriod number Ticks in one period. TRUSTED INTERNAL input.
--- @param rng function|nil A zero-argument generator returning a value at or above 0
---        and below 1, defaulting to `math.random`. A TRUSTED INTERNAL TEST SEAM;
---        production passes nothing.
--- @return string result A FATALITY_RESULT value - NONE when nothing was rolled,
---         SURVIVED or DIED when it was
--- @return number hazard The per-tick probability used, 0 on every refusal
function RLDiseaseFatality.roll(record, model, vulnerability, daysPerPeriod, rng)
    local RESULT = RLDiseaseFatality.FATALITY_RESULT

    if type(record) ~= "table" then return RESULT.NONE, 0 end
    if type(model) ~= "table" then return RESULT.NONE, 0 end

    -- ONE guard covering the four other states and any an older codec retired.
    if record.state ~= RLDiseaseRecord.STATE.INFECTIOUS then
        Log:trace("RLDiseaseFatality.roll: refused title=%s - state is %s, not INFECTIOUS",
            tostring(record.title), tostring(record.state))

        return RESULT.NONE, 0
    end

    rng = rng or math.random

    local hazard, monthly = RLDiseaseFatality.perTickHazard(model, vulnerability, daysPerPeriod)
    local draw = rng()
    local result = RESULT.SURVIVED

    if draw < hazard then
        -- The record's own state machine owns this write; the ANIMAL's death belongs to
        -- the caller, which reads DIED and drives it. The refusal arm is unreachable -
        -- the pair is unconditional and the state guard above already proved INFECTIOUS.
        if RLDiseaseRecord.transition(record, RLDiseaseRecord.STATE.DEAD)
            == RLDiseaseRecord.APPLIED then
            result = RESULT.DIED
        end
    end

    -- TRACE per roll because this fires per infectious record per tick; DEBUG for a
    -- death, which is rare and is the line a "my healthy cow died" report needs.
    Log:trace("RLDiseaseFatality.roll: title=%s endpoint=%s monthly=%s vulnerability=%s "
        .. "hazard=%s draw=%s result=%s",
        tostring(record.title), tostring(model.endpoint), tostring(monthly),
        tostring(vulnerability), tostring(hazard), tostring(draw), tostring(result))

    if result == RESULT.DIED then
        Log:debug("RLDiseaseFatality.roll: title=%s DIED - hazard=%s draw=%s",
            tostring(record.title), tostring(hazard), tostring(draw))
    end

    return result, hazard
end


Log:info("RLDiseaseFatality loaded")
