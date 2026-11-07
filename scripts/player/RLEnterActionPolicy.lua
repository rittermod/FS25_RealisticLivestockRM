--[[
    RLEnterActionPolicy.lua
    Whether the vehicle in range takes the enter action ahead of a looked-at dewar. Another mod can
    put a non-enterable object, the dewar included, in the interactive vehicle slot. Pure; runs headless.
]]

RLEnterActionPolicy = {}

--- Whether the vehicle in range takes the enter action ahead of a looked-at dewar.
--- @param vehicle table|nil The mission's interactive vehicle in range
--- @param canAccess boolean|nil Whether the player may use that vehicle; only exactly true counts
--- @return boolean takesEnter
function RLEnterActionPolicy.getVehicleTakesEnter(vehicle, canAccess)
    return vehicle ~= nil and vehicle.spec_enterable ~= nil and canAccess == true
end
