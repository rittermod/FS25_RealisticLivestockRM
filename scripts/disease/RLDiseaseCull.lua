--[[
    RLDiseaseCull.lua
    The one rule for culling a sick animal, and the salvage a cull pays. The Diseases dialog's
    button and confirm, the authority's apply path and the server's request handler all ask
    check(); none restates its clauses. Sick means the display rule: Animal:getHasAnyDisease, which
    also carries the diseases setting.

    Pure: no setting, no g_*, no GUI. Callers log the outcome.
]]

RLDiseaseCull = {}

local Log = RmLogging.getLogger("RLRM")

--- Why `check` refuses. READ-ONLY by contract.
RLDiseaseCull.REASON = {
    DEAD = "DEAD",
    NOT_SICK = "NOT_SICK",
}

--- The share of the animal's current sale price a cull pays.
RLDiseaseCull.SALVAGE_SHARE = 0.33

--- The DEATH message reason; the rl_ prefix is what makes the message renderer translate it.
RLDiseaseCull.DEATH_REASON = "rl_death_cull"


--- Whether an animal may be culled: alive, and showing symptoms by the display rule.
---@param animal table The animal to test.
---@return boolean ok True when the cull is allowed.
---@return string|nil reason A `REASON` value when refused, nil when allowed.
function RLDiseaseCull.check(animal)
    if animal.isDead or animal:getNumAnimals() <= 0 then
        Log:trace("RLDiseaseCull.check: refused, reason=DEAD (uniqueId=%s isDead=%s numAnimals=%s)",
            tostring(animal.uniqueId), tostring(animal.isDead), tostring(animal.numAnimals))
        return false, RLDiseaseCull.REASON.DEAD
    end

    if not animal:getHasAnyDisease() then
        Log:trace("RLDiseaseCull.check: refused, reason=NOT_SICK (uniqueId=%s)", tostring(animal.uniqueId))
        return false, RLDiseaseCull.REASON.NOT_SICK
    end

    Log:trace("RLDiseaseCull.check: allowed (uniqueId=%s)", tostring(animal.uniqueId))
    return true, nil
end


--- The salvage a cull of this animal pays: a share of its current sale price, nothing for a chicken.
---@param animal table The animal to price.
---@return number salvage The payout, 0 for a chicken.
function RLDiseaseCull.salvageFor(animal)
    if animal.animalTypeIndex == AnimalType.CHICKEN then
        Log:trace("RLDiseaseCull.salvageFor: 0, reason=chicken (uniqueId=%s)", tostring(animal.uniqueId))
        return 0
    end

    local salvage = animal:getSellPrice() * RLDiseaseCull.SALVAGE_SHARE
    Log:trace("RLDiseaseCull.salvageFor: %s (uniqueId=%s)", tostring(salvage), tostring(animal.uniqueId))
    return salvage
end


Log:debug("RLDiseaseCull loaded (SALVAGE_SHARE=%s)", tostring(RLDiseaseCull.SALVAGE_SHARE))
