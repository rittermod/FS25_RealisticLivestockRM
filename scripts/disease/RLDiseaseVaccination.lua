--[[
    RLDiseaseVaccination.lua
    What a disease's vaccine block does to a record. A dose on a healthy animal makes it immune, a
    dose on an immune one tops the protection up and never shortens it, and a dose on an infected
    one is wasted: charged by the caller, nothing changes. Every dose takes. At birth, each newborn
    takes the block's maternal months for every disease its dam holds at RECOVERED.

    Pure: no setting, no g_*, no GUI. Callers log the outcome.
]]

RLDiseaseVaccination = {}

local Log = RmLogging.getLogger("RLRM")

--- Why `check` refuses. READ-ONLY by contract.
RLDiseaseVaccination.REASON = {
    DEAD = "DEAD",
    NOT_VACCINABLE = "NOT_VACCINABLE",
}

--- What `apply` did to the record. READ-ONLY by contract.
RLDiseaseVaccination.OUTCOME = {
    CREATED = "CREATED",
    TOPPED_UP = "TOPPED_UP",
    WASTED = "WASTED",
}


--- Whether an animal may be vaccinated against a disease: alive, and the disease carries a vaccine.
---@param animal table The animal to test.
---@param model table The disease's registry entry.
---@return boolean ok True when the dose is allowed.
---@return string|nil reason A `REASON` value when refused, nil when allowed.
function RLDiseaseVaccination.check(animal, model)
    if animal.isDead or animal:getNumAnimals() <= 0 then
        Log:trace("RLDiseaseVaccination.check: refused, reason=DEAD (title=%s farmId=%s uniqueId=%s isDead=%s "
            .. "numAnimals=%s)", tostring(model.title), tostring(animal.farmId), tostring(animal.uniqueId),
            tostring(animal.isDead), tostring(animal.numAnimals))
        return false, RLDiseaseVaccination.REASON.DEAD
    end

    if model.vaccine == nil then
        Log:trace("RLDiseaseVaccination.check: refused, reason=NOT_VACCINABLE (title=%s farmId=%s uniqueId=%s)",
            tostring(model.title), tostring(animal.farmId), tostring(animal.uniqueId))
        return false, RLDiseaseVaccination.REASON.NOT_VACCINABLE
    end

    Log:trace("RLDiseaseVaccination.check: allowed (title=%s farmId=%s uniqueId=%s)", tostring(model.title),
        tostring(animal.farmId), tostring(animal.uniqueId))
    return true, nil
end


--- Step a fresh record to `to`; anything but APPLIED raises, so the caller charges nothing.
---@param record table The record addDisease just built.
---@param to string The destination state.
---@param title string The disease title, for the error text.
---@param caller string The public function stepping it, for the error text and the TRACE line.
local function step(record, to, title, caller)
    local outcome = RLDiseaseRecord.transition(record, to)

    if outcome ~= RLDiseaseRecord.APPLIED then
        error(string.format("%s: transition to %s returned %s (title=%s)",
            tostring(caller), tostring(to), tostring(outcome), tostring(title)))
    end

    Log:trace("%s: stepped to %s (title=%s)", tostring(caller), tostring(to), tostring(title))
end


--- Build a new record of `model` on an animal holding none: EXPOSED -> INFECTIOUS -> RECOVERED, never a state write.
---@param animal table The live animal; holds no record of the title.
---@param model table The disease's registry entry; never written.
---@param months number The protection to set as immunityMonthsRemaining.
---@param vaccinated boolean The record's vaccinated flag.
---@param caller string The public function building it, for the error text and the TRACE lines.
local function buildImmune(animal, model, months, vaccinated, caller)
    animal:addDisease(model)
    local record = animal:getDisease(model.title)

    if record == nil then
        error(string.format("%s: no record after addDisease (title=%s)", tostring(caller), tostring(model.title)))
    end

    step(record, RLDiseaseRecord.STATE.INFECTIOUS, model.title, caller)
    step(record, RLDiseaseRecord.STATE.RECOVERED, model.title, caller)
    record.immunityMonthsRemaining = months
    record.vaccinated = vaccinated
end


--- Apply one dose. Unguarded: a caller owes `check` and the diseases-on test, as the event's `refusal` provides.
---@param animal table The live animal.
---@param model table The disease's registry entry, carrying `vaccine`; never written.
---@return string outcome An `OUTCOME` value.
function RLDiseaseVaccination.apply(animal, model)
    local months = model.vaccine.protectionMonths
    local record = animal:getDisease(model.title)

    if record == nil then
        buildImmune(animal, model, months, true, "RLDiseaseVaccination.apply")

        Log:trace("RLDiseaseVaccination.apply: CREATED (title=%s farmId=%s uniqueId=%s months 0 -> %s)",
            tostring(model.title), tostring(animal.farmId), tostring(animal.uniqueId), tostring(months))
        return RLDiseaseVaccination.OUTCOME.CREATED
    end

    if record.state == RLDiseaseRecord.STATE.RECOVERED then
        local before = record.immunityMonthsRemaining
        -- Inverted so a NaN counter is replaced too.
        local raise = not (before >= months)

        animal:setDirty()

        if raise then
            record.immunityMonthsRemaining = months
        end
        record.vaccinated = true

        Log:trace("RLDiseaseVaccination.apply: TOPPED_UP (title=%s farmId=%s uniqueId=%s months %s -> %s)",
            tostring(model.title), tostring(animal.farmId), tostring(animal.uniqueId), tostring(before),
            tostring(record.immunityMonthsRemaining))
        return RLDiseaseVaccination.OUTCOME.TOPPED_UP
    end

    Log:trace("RLDiseaseVaccination.apply: WASTED (title=%s state=%s farmId=%s uniqueId=%s months %s -> %s)",
        tostring(model.title), tostring(record.state), tostring(animal.farmId), tostring(animal.uniqueId),
        tostring(record.immunityMonthsRemaining), tostring(record.immunityMonthsRemaining))
    return RLDiseaseVaccination.OUTCOME.WASTED
end


--- Give each newborn the maternal protection of every disease its dam holds at RECOVERED; the caller gates.
---@param dam table The mother, read at birth.
---@param children table Array of the surviving newborns.
---@return number created How many records were built across the litter.
function RLDiseaseVaccination.passMaternal(dam, children)
    local created = 0

    for _, damRecord in ipairs(dam.diseases) do
        local vaccine = damRecord.model.vaccine
        local reason = nil

        if damRecord.state ~= RLDiseaseRecord.STATE.RECOVERED then
            reason = "not RECOVERED"
        elseif vaccine == nil then
            reason = "no vaccine"
        elseif vaccine.maternalMonths == nil then
            reason = "no maternal months"
        end

        if reason ~= nil then
            Log:trace("RLDiseaseVaccination.passMaternal: skipped (title=%s state=%s reason=%s damFarmId=%s "
                .. "damUniqueId=%s)", tostring(damRecord.title), tostring(damRecord.state), reason,
                tostring(dam.farmId), tostring(dam.uniqueId))
        else
            local months = vaccine.maternalMonths

            Log:trace("RLDiseaseVaccination.passMaternal: qualifies (title=%s months=%s damFarmId=%s damUniqueId=%s "
                .. "children=%d)", tostring(damRecord.title), tostring(months), tostring(dam.farmId),
                tostring(dam.uniqueId), #children)

            for _, child in ipairs(children) do
                buildImmune(child, damRecord.model, months, false, "RLDiseaseVaccination.passMaternal")
                created = created + 1

                Log:trace("RLDiseaseVaccination.passMaternal: CREATED (title=%s farmId=%s uniqueId=%s months 0 -> %s "
                    .. "damFarmId=%s damUniqueId=%s)", tostring(damRecord.title), tostring(child.farmId),
                    tostring(child.uniqueId), tostring(months), tostring(dam.farmId), tostring(dam.uniqueId))
            end
        end
    end

    return created
end


Log:debug("RLDiseaseVaccination loaded")
