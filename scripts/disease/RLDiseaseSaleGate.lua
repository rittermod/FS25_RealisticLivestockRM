--[[
    RLDiseaseSaleGate.lua
    The one rule for selling an animal or delivering it to a butcher: an animal showing symptoms
    may not go. The Sell tab, the herdsman and every butcher route ask check(). Sick is
    Animal:getHasAnyDisease.

    Pure: no setting, no g_*, no GUI. Callers log the outcome.
]]

RLDiseaseSaleGate = {}

local Log = RmLogging.getLogger("RLRM")

--- Why `check` refuses. READ-ONLY by contract.
RLDiseaseSaleGate.REASON = {
    SICK = "SICK",
}


--- Whether an animal may be sold or sent to a butcher: refused while it shows symptoms.
---@param animal table The animal to test.
---@return boolean ok True when the sale or delivery is allowed.
---@return string|nil reason A `REASON` value when refused, nil when allowed.
function RLDiseaseSaleGate.check(animal)
    if animal:getHasAnyDisease() then
        Log:trace("RLDiseaseSaleGate.check: refused, reason=SICK (uniqueId=%s)", tostring(animal.uniqueId))
        return false, RLDiseaseSaleGate.REASON.SICK
    end

    Log:trace("RLDiseaseSaleGate.check: allowed (uniqueId=%s)", tostring(animal.uniqueId))
    return true, nil
end


Log:debug("RLDiseaseSaleGate loaded")
