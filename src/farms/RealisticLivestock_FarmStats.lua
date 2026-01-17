RealisticLivestock_FarmStats = {}

function RealisticLivestock_FarmStats:loadFromXMLFile(xmlFile, rootKey)

    local key = rootKey .. ".statistics"
    self.statistics.farmId = xmlFile:getInt(key .. ".farmId", math.random(100000, 999999))
    self.statistics.cowId = xmlFile:getInt(key .. ".cowId", 0)
    self.statistics.pigId = xmlFile:getInt(key .. ".pigId", 0)
    self.statistics.sheepId = xmlFile:getInt(key .. ".sheepId", 0)
    self.statistics.horseId = xmlFile:getInt(key .. ".horseId", 0)
    self.statistics.chickenId = xmlFile:getInt(key .. ".chickenId", 0)

end

FarmStats.loadFromXMLFile = Utils.prependedFunction(FarmStats.loadFromXMLFile, RealisticLivestock_FarmStats.loadFromXMLFile)


function RealisticLivestock_FarmStats:saveToXMLFile(xmlFile, rootKey)

    local key = rootKey .. ".statistics"

    if self.statistics.farmId == nil then self.statistics.farmId = math.random(100000, 999999) end
    if self.statistics.cowId == nil then self.statistics.cowId = 0 end
    if self.statistics.pigId == nil then self.statistics.pigId = 0 end
    if self.statistics.sheepId == nil then self.statistics.sheepId = 0 end
    if self.statistics.horseId == nil then self.statistics.horseId = 0 end
    if self.statistics.chickenId == nil then self.statistics.chickenId = 0 end


    xmlFile:setInt(key .. ".farmId", self.statistics.farmId)
    xmlFile:setInt(key .. ".cowId", self.statistics.cowId)
    xmlFile:setInt(key .. ".pigId", self.statistics.pigId)
    xmlFile:setInt(key .. ".sheepId", self.statistics.sheepId)
    xmlFile:setInt(key .. ".horseId", self.statistics.horseId)
    xmlFile:setInt(key .. ".chickenId", self.statistics.chickenId)

end

FarmStats.saveToXMLFile = Utils.prependedFunction(FarmStats.saveToXMLFile, RealisticLivestock_FarmStats.saveToXMLFile)


function RealisticLivestock_FarmStats:getNextAnimalId(animalType)

    if animalType == AnimalType.COW then
        if self.statistics.cowId == nil then self.statistics.cowId = 0 end
        self.statistics.cowId = self.statistics.cowId + 1
        return self.statistics.cowId
    end

    if animalType == AnimalType.PIG then
        if self.statistics.pigId == nil then self.statistics.pigId = 0 end
        self.statistics.pigId = self.statistics.pigId + 1
        return self.statistics.pigId
    end

    if animalType == AnimalType.SHEEP then
        if self.statistics.sheepId == nil then self.statistics.sheepId = 0 end
        self.statistics.sheepId = self.statistics.sheepId + 1
        return self.statistics.sheepId
    end

    if animalType == AnimalType.HORSE then
        if self.statistics.horseId == nil then self.statistics.horseId = 0 end
        self.statistics.horseId = self.statistics.horseId + 1
        return self.statistics.horseId
    end

    if animalType == AnimalType.CHICKEN then
        if self.statistics.chickenId == nil then self.statistics.chickenId = 0 end
        self.statistics.chickenId = self.statistics.chickenId + 1
        return self.statistics.chickenId
    end

    return 1

end

FarmStats.getNextAnimalId = RealisticLivestock_FarmStats.getNextAnimalId