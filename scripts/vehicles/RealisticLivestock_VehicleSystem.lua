RealisticLivestock_VehicleSystem = {}

function RealisticLivestock_VehicleSystem:save(_, _)
    local indexesToRemove = {}

    for i, vehicle in ipairs(self.vehicles) do
        if vehicle.spec_rideable ~= nil then table.insert(indexesToRemove, i) end
    end

    table.sort(indexesToRemove, function(a, b)
        return a > b
    end)

    for i in indexesToRemove do
        table.remove(self.vehicles, i)
    end
end

VehicleSystem.save = Utils.prependedFunction(VehicleSystem.save, RealisticLivestock_VehicleSystem.save)