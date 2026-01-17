RealisticLivestock_HusbandrySystem = {}

function RealisticLivestock_HusbandrySystem:getClusterHusbandryById(superFunc, id)
    for _, clusterHusbandry in ipairs(self.clusterHusbandries) do
        if clusterHusbandry.husbandryIds ~= nil then
            for _, husbandryId in ipairs(clusterHusbandry.husbandryIds) do
                if husbandryId == id then return clusterHusbandry end
            end
        end
    end

    return nil
end

HusbandrySystem.getClusterHusbandryById = Utils.overwrittenFunction(HusbandrySystem.getClusterHusbandryById, RealisticLivestock_HusbandrySystem.getClusterHusbandryById)