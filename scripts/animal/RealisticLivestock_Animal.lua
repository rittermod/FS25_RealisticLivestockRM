Animal = {}
local Animal_mt = Class(Animal)
local Log = RmLogging.getLogger("RLRM")

--- Resolves subType by index, with fallback to name lookup or default index 1
-- @param subTypeIndex number The initial subType index
-- @param subTypeName string|nil Optional subType name for fallback lookup
-- @return number resolvedIndex, table|nil subType, string resolvedName
function Animal.resolveSubType(subTypeIndex, subTypeName)
    local animalSystem = g_currentMission.animalSystem
    local subType = animalSystem:getSubTypeByIndex(subTypeIndex)

    -- Index resolved to a subtype whose name differs from the streamed name.
    -- Means the wire index came from a peer with a different subtype registry
    -- (typically MP DLC asymmetry: server registered Highland Cattle, client did not,
    -- so all later indices shift). Reject the index and let the name-based fallback
    -- below resolve to the client-local index. Without this guard, the bug is silent:
    -- subTypes[N] returns a valid-but-wrong subType (e.g. PIG_LANDRACE) and the animal
    -- renders as the wrong breed/species on the client.
    if subType ~= nil and subTypeName ~= nil and subTypeName ~= ""
            and subType.name ~= subTypeName then
        Log:warning("resolveSubType: subTypeIndex %d resolved to '%s' but stream named '%s' - using name lookup (DLC asymmetry?)",
            subTypeIndex, subType.name, subTypeName)
        subType = nil
    end

    -- Try name-based lookup if index failed and name provided
    if subType == nil and subTypeName ~= nil and subTypeName ~= "" then
        local mappedIndex = animalSystem:getSubTypeIndexByName(subTypeName)
        if mappedIndex ~= nil then
            subTypeIndex = mappedIndex
            subType = animalSystem:getSubTypeByIndex(subTypeIndex)
            Log:info("Resolved subType '%s' from name (index %d)", subTypeName, subTypeIndex)
        end
    end

    -- Final fallback to index 1
    if subType == nil then
        Log:warning("subTypeIndex %d not found, falling back to 1", subTypeIndex)
        subTypeIndex = 1
        subType = animalSystem:getSubTypeByIndex(subTypeIndex)
    end

    local resolvedName = (subType ~= nil and subType.name) or "UNKNOWN"
    return subTypeIndex, subType, resolvedName
end

--- Create a new Animal instance.
--- @param config table|nil Config table with named fields, or nil for empty shell.
---   Fields: age, health, monthsSinceLastBirth, gender, subTypeIndex, reproduction,
---   isParent, isPregnant, isLactating, clusterSystem, uniqueId, motherId, fatherId,
---   pos, name, dirt, fitness, riding, farmId, weight, genetics, impregnatedBy,
---   variation, children, monitor, isCastrated, diseases, recentlyBoughtByAI, marks,
---   insemination. All fields optional; defaults applied for omitted fields.
--- @return table animal New Animal instance
function Animal.new(config)
    local cfg = config or {}
    local self = setmetatable({}, Animal_mt)

    self.input, self.output = {}, {}

    self.isCastrated = cfg.isCastrated or false

    self.clusterSystem = cfg.clusterSystem

    self.insemination = cfg.insemination

    self.recentlyBoughtByAI = cfg.recentlyBoughtByAI or false
    self.children = cfg.children or {}
    self.age = cfg.age or 0
    self.health = cfg.health or 0
    self.monthsSinceLastBirth = cfg.monthsSinceLastBirth or 0
    self.gender = cfg.gender or "female"
    local subType
    if config and not cfg.subTypeIndex then
        Log:debug("Animal.new: subTypeIndex missing from config, using default 1")
    end
    self.subTypeIndex, subType, self.subType = Animal.resolveSubType(cfg.subTypeIndex or 1, nil)
    self.reproduction = cfg.reproduction or 0
    self.isParent = cfg.isParent or false
    self.isPregnant = cfg.isPregnant or false
    self.isLactating = cfg.isLactating or false
    self.isDirty = false
    self.isIndividual = true
    self.name = nil
    self.isDead = false
    self.isSold = false
    self.canBeSold = cfg.canBeSold  -- nil = sellable (default); false = blocked by third-party mod at conversion
    self.weight = cfg.weight or nil
    self.marks = cfg.marks or self:getDefaultMarks()

    self.variation = cfg.variation or nil

    local genetics = cfg.genetics
    self.genetics = genetics
    self.impregnatedBy = cfg.impregnatedBy

    self.animalTypeIndex = g_currentMission.animalSystem:getTypeIndexBySubTypeIndex(self.subTypeIndex) or 1
    local targetWeight = subType ~= nil and subType.targetWeight or 0
    self.breed = (subType ~= nil and subType.breed) or "UNKNOWN"

    if genetics == nil then
        self.genetics = {}

        local healthChance = math.random()

        if healthChance < 0.05 then
            self.genetics.health = math.random(25, 35) / 100
        elseif healthChance < 0.25 then
            self.genetics.health = math.random(35, 90) / 100
        elseif healthChance > 0.95 then
            self.genetics.health = math.random(165, 175) / 100
        elseif healthChance > 0.75 then
            self.genetics.health = math.random(110, 165) / 100
        else
            self.genetics.health = math.random(90, 110) / 100
        end


        local fertilityChance = math.random()

        if fertilityChance < 0.001 then
            self.genetics.fertility = 0
        elseif fertilityChance < 0.05 then
            self.genetics.fertility = math.random(25, 35) / 100
        elseif fertilityChance < 0.25 then
            self.genetics.fertility = math.random(35, 90) / 100
        elseif fertilityChance > 0.95 then
            self.genetics.fertility = math.random(165, 175) / 100
        elseif fertilityChance > 0.75 then
            self.genetics.fertility = math.random(110, 165) / 100
        else
            self.genetics.fertility = math.random(90, 110) / 100
        end


        if self.animalTypeIndex == AnimalType.COW or self.animalTypeIndex == AnimalType.SHEEP or self.animalTypeIndex == AnimalType.CHICKEN then
            local productivityChance = math.random()

            if productivityChance < 0.05 then
                self.genetics.productivity = math.random(25, 35) / 100
            elseif productivityChance < 0.25 then
                self.genetics.productivity = math.random(35, 90) / 100
            elseif productivityChance > 0.95 then
                self.genetics.productivity = math.random(165, 175) / 100
            elseif productivityChance > 0.75 then
                self.genetics.productivity = math.random(110, 165) / 100
            else
                self.genetics.productivity = math.random(90, 110) / 100
            end
        end


        local meatQualityChance = math.random()

        if meatQualityChance < 0.05 then
            self.genetics.quality = math.random(25, 35) / 100
        elseif meatQualityChance < 0.25 then
            self.genetics.quality = math.random(35, 90) / 100
        elseif meatQualityChance > 0.95 then
            self.genetics.quality = math.random(165, 175) / 100
        elseif meatQualityChance > 0.75 then
            self.genetics.quality = math.random(110, 165) / 100
        else
            self.genetics.quality = math.random(90, 110) / 100
        end


        local metabolismChance = math.random()

        if metabolismChance < 0.05 then
            self.genetics.metabolism = math.random(25, 35) / 100
        elseif metabolismChance < 0.25 then
            self.genetics.metabolism = math.random(35, 90) / 100
        elseif metabolismChance > 0.95 then
            self.genetics.metabolism = math.random(165, 175) / 100
        elseif metabolismChance > 0.75 then
            self.genetics.metabolism = math.random(110, 165) / 100
        else
            self.genetics.metabolism = math.random(90, 110) / 100
        end
    end


    if self.weight == nil then
        local minWeight = subType.minWeight
        local maxWeight = subType.maxWeight

        local weightPerMonth = (targetWeight - minWeight) / (subType.reproductionMinAgeMonth * 1.5)
        self.weight = math.clamp(
        (minWeight + (weightPerMonth * math.clamp(self.age, 0, 20))) * (math.random(85, 115) / 100), minWeight, maxWeight)
    end


    self.targetWeight = targetWeight + (((targetWeight * self.genetics.metabolism) - targetWeight) / 2.5)

    local farmId = cfg.farmId
    self.farmId = farmId or nil

    local id = cfg.uniqueId

    if self.clusterSystem ~= nil then
        if id == nil then
            local ownerFarmId = self.clusterSystem.owner.ownerFarmId
            local farm = g_farmManager.farmIdToFarm[ownerFarmId]


            if farm == nil then
                id = "1"
            else
                id = farm.stats:getNextAnimalId(g_currentMission.animalSystem:getSubTypeByIndex(self.subTypeIndex)
                .typeIndex)

                local farmHerdId = farm.stats.statistics.farmId
                if farmHerdId == nil then
                    farmHerdId = math.random(100000, 999999)
                    farm.stats.statistics.farmId = farmHerdId
                end

                self.farmId = tostring(farmHerdId)

                id = RLAnimalUtil.generateUniqueId(farmHerdId, id)
            end
        end

        if farmId == nil then
            local farm = g_farmManager.farmIdToFarm[self.clusterSystem.owner.ownerFarmId]
            if farm == nil then
                self.farmId = "1"
            else
                local farmHerdId = farm.stats.statistics.farmId
                if farmHerdId == nil then
                    farmHerdId = math.random(100000, 999999)
                    farm.stats.statistics.farmId = farmHerdId
                end

                self.farmId = tostring(farmHerdId)
            end
        end
    end

    self.uniqueId = id
    self.id = "0-0"
    self.idFull = "0-0"

    self.motherId = cfg.motherId or "-1"
    self.fatherId = cfg.fatherId or "-1"


    -- for compatibility reasons with mods such as InfoDisplayExtension

    self.numAnimals = 1
    self.maxNumAnimals = 1

    local reproductionText = g_i18n:getText("statistic_reproduction")

    self.infoReproduction = {
        text = "",
        title = reproductionText,
        titleOrg = reproductionText
    }
    self.infoHealth = {
        text = "",
        title = g_i18n:getText("ui_horseHealth")
    }

    local name = cfg.name
    self.name = name or nil


    self.dirt = cfg.dirt or 0
    self.fitness = cfg.fitness or 0
    self.riding = cfg.riding or 0
    if name == "" then name = nil end
    self.name = name or (self:isHorse() and g_currentMission.animalNameSystem:getRandomName(self.gender) or nil)


    self.pos = cfg.pos or nil


    if self.age >= 0 then
        local environment = g_currentMission.environment

        local currentMonth = environment.currentPeriod + 2
        local currentYear = environment.currentYear

        if currentMonth > 12 then currentMonth = currentMonth - 12 end

        local birthYear = currentYear - math.floor(self.age / 12)
        local birthMonth = currentMonth - (self.age % 12)

        if birthMonth <= 0 then birthMonth = 12 + birthMonth end

        local birthCountry = math.random() >= 0.01 and RealisticLivestock.getMapCountryIndex() or
        math.random(1, #RLConstants.AREA_CODES)

        self.birthday = {
            ["day"] = math.random(1, RLConstants.DAYS_PER_MONTH[birthMonth]),
            ["month"] = birthMonth,
            ["year"] = birthYear,
            ["country"] = birthCountry,
            ["lastAgeMonth"] = currentMonth
        }
    end

    self.diseases = cfg.diseases or {}

    self:updateInput()
    self:updateOutput(g_currentMission.environment.weather.temperatureUpdater.currentMin or 20)

    self.monitor = cfg.monitor or { ["active"] = false, ["removed"] = false, ["fee"] = 5 }

    local animalType = g_currentMission.animalSystem.types[self.animalTypeIndex]

    self.monitor.fee = animalType == nil and 5 or
    math.max(animalType.navMeshAgentAttributes.height * animalType.navMeshAgentAttributes.radius * 15, 0.25)

    return self
end

function Animal:delete()
    local clusterSystem = self.clusterSystem or nil

    if clusterSystem ~= nil then
        for i, animal in pairs(clusterSystem.animals) do
            if animal == self then
                table.remove(clusterSystem.animals, i)
                break
            end
        end
    end

    self = nil
end

function Animal:setClusterSystem(clusterSystem)
    self.clusterSystem = clusterSystem
    if clusterSystem ~= nil then self.sale = nil end
end

function Animal:getSupportsMerging()
    return false
end

-- XML persistence delegates -> AnimalPersistence module
Animal.loadFromXMLFile = AnimalPersistence.loadFromXMLFile -- see scripts/animal/AnimalPersistence.lua

function Animal:saveToXMLFile(xmlFile, key) return AnimalPersistence.saveToXMLFile(self, xmlFile, key) end

-- Stream serialization delegates -> AnimalSerialization module
function Animal:writeStream(streamId, connection)
    return AnimalSerialization.writeStream(self, streamId, connection)
end

function Animal:readStream(streamId, connection)
    return AnimalSerialization.readStream(self, streamId, connection)
end

-- Delegates (backward compatibility - remove in future cleanup)
function Animal:writeStreamIdentifiers(streamId, connection)
    Log:trace("DELEGATE: Animal:writeStreamIdentifiers called - use RLAnimalUtil.writeStreamIdentifiers directly")
    return RLAnimalUtil.writeStreamIdentifiers(self, streamId, connection)
end

Animal.readStreamIdentifiers = function(streamId, connection)
    Log:trace("DELEGATE: Animal.readStreamIdentifiers called - use RLAnimalUtil.readStreamIdentifiers directly")
    return RLAnimalUtil.readStreamIdentifiers(streamId, connection)
end


function Animal:writeStreamUnborn(streamId, connection)
    return AnimalSerialization.writeStreamUnborn(self, streamId, connection)
end

function Animal:readStreamUnborn(streamId, connection)
    return AnimalSerialization.readStreamUnborn(self, streamId, connection)
end

function Animal:clone()
    local newAnimal = Animal.new({
        age = self.age,
        health = self.health,
        monthsSinceLastBirth = self.monthsSinceLastBirth,
        gender = self.gender,
        subTypeIndex = self.subTypeIndex,
        reproduction = self.reproduction,
        isParent = self.isParent,
        isPregnant = self.isPregnant,
        isLactating = self.isLactating,
        clusterSystem = self.clusterSystem,
        uniqueId = self.uniqueId,
        motherId = self.motherId,
        fatherId = self.fatherId,
        pos = self.pos,
        name = self.name,
        dirt = self.dirt,
        fitness = self.fitness,
        riding = self.riding,
        farmId = self.farmId,
        weight = self.weight,
        genetics = self.genetics,
        impregnatedBy = self.impregnatedBy,
        variation = self.variation,
        children = self.children,
        monitor = self.monitor,
        isCastrated = self.isCastrated,
        diseases = self.diseases,
        recentlyBoughtByAI = self.recentlyBoughtByAI,
        marks = self.marks,
        insemination = self.insemination,
        canBeSold = self.canBeSold,
    })

    newAnimal:setBirthday(self.birthday)

    if self.pregnancy ~= nil then newAnimal.pregnancy = self.pregnancy end

    return newAnimal
end

function Animal:setBirthday(birthday)
    if birthday ~= nil then self.birthday = birthday end
end

function Animal:getBirthday()
    return self.birthday
end

function Animal:setGenetics(genetics)
    self.genetics = genetics
end

function Animal:getGenetics()
    return self.genetics
end

function Animal:setUniqueId(farmId)
    if self.clusterSystem == nil then
        if farmId == nil then
            Log:trace("setUniqueId: no clusterSystem and no farmId arg, returning unchanged")
            return
        end

        if type(farmId) == "string" then farmId = tonumber(farmId) end

        local id = g_currentMission.animalSystem:getNextAnimalIdForFarm(self.birthday.country, self.animalTypeIndex,
            farmId)

        self.farmId = tostring(farmId)
        self.uniqueId = RLAnimalUtil.generateUniqueId(farmId, id)

        return
    end

    local ownerFarmId = self.clusterSystem.owner.ownerFarmId
    Log:trace("setUniqueId: ownerFarmId=%s, type=%s", tostring(ownerFarmId), type(ownerFarmId))

    if ownerFarmId == nil then
        Log:trace("setUniqueId: ownerFarmId is nil, fallback to 1/1")
        self.uniqueId, self.farmId = "1", "1"
        return
    end

    local farm = g_farmManager.farmIdToFarm[ownerFarmId]
    Log:trace("setUniqueId: farm lookup for ownerFarmId=%s -> %s", tostring(ownerFarmId), tostring(farm))

    if farm == nil then
        Log:trace("setUniqueId: farm is nil, fallback to 1/1")
        self.uniqueId, self.farmId = "1", "1"
    else
        id = farm.stats:getNextAnimalId(g_currentMission.animalSystem:getSubTypeByIndex(self.subTypeIndex).typeIndex)

        local farmHerdId = farm.stats.statistics.farmId
        if farmHerdId == nil then
            farmHerdId = math.random(100000, 999999)
            farm.stats.statistics.farmId = farmHerdId
        end

        self.farmId = tostring(farmHerdId)
        self.uniqueId = RLAnimalUtil.generateUniqueId(farmHerdId, id)
    end
end

-- Delegate (backward compatibility - remove in future cleanup)
function Animal:getHash()
    Log:trace("DELEGATE: Animal:getHash called - use RLAnimalUtil.getHash directly")
    return RLAnimalUtil.getHash(self)
end

function Animal:changeNumAnimals(delta)
    local oldNum = self.numAnimals
    self.numAnimals = math.clamp(math.floor(self.numAnimals + delta), 0, 1)
    self:setDirty()
    return delta - (self.numAnimals - oldNum)
end

function Animal:setDirty()
    self.isDirty = true
    if self.clusterSystem ~= nil then self.clusterSystem:setDirty() end
end

function Animal:getRidableFilename()
    return self:getSubType().rideableFilename or nil
end

function Animal:getNumAnimals()
    return self.numAnimals
end

function Animal:getSubTypeIndex()
    return self.subTypeIndex
end

function Animal:getSubType()
    return g_currentMission.animalSystem:getSubTypeByName(self.subType)
end

function Animal:increaseAge()
    self.age = self.age + 1
end

function Animal:getAge()
    return self.age
end

function Animal:getName()
    return self.name or ""
end

function Animal:setName(name)
    self.name = name
end

function Animal:getTranportationFee(factor)
    return g_currentMission.animalSystem:getAnimalTransportFee(self.subTypeIndex, self.age) * factor
end

--- Whether this animal can be sold.
--- Checks both death state and the canBeSold flag captured from vanilla cluster
--- at conversion time. nil and true are treated as sellable; only explicit false blocks.
--- @return boolean
function Animal:getCanBeSold()
    return self.isDead == false and self.canBeSold ~= false
end

--- Populate the info rows for this animal.
--- @param infos table   Appended with stat rows (mutated in place).
--- @param forceShowAll? boolean  When true, unhide monitor-gated fields
---        (Health, Weight, Lactation). Used by the Buy tab so dealer animals
---        expose full stats at purchase time even though they carry no
---        monitor. Defaults to false; existing callers (Info / Move / Sell
---        via husbandry:getAnimalInfos) behave unchanged.
function Animal:addInfos(infos, forceShowAll)
    local subType = self:getSubType()

    local hasMonitor = self.monitor.active or self.monitor.removed or forceShowAll == true
    local healthFactor = self:getHealthFactor()

    if hasMonitor then
        self.infoHealth.value = healthFactor
        self.infoHealth.ratio = healthFactor
        self.infoHealth.valueText = string.format("%d %%", g_i18n:formatNumber(healthFactor * 100, 0))

        table.insert(infos, self.infoHealth)
    end

    if self:getSupportsReproduction() then
        local reproductionFactor = self:getReproductionFactor()
        self.infoReproduction.value = reproductionFactor
        self.infoReproduction.ratio = reproductionFactor
        self.infoReproduction.valueText = string.format("%d %%", g_i18n:formatNumber(reproductionFactor * 100, 0))
        self.infoReproduction.disabled = not self:getCanReproduce()
        self.infoReproduction.title = self.infoReproduction.titleOrg

        if self.infoReproduction.disabled then
            local reasonText, thresholdText = nil, nil

            if self.age < subType.reproductionMinAgeMonth then
                reasonText = g_i18n:getText("rl_ui_tooYoung")
                thresholdText = g_i18n:formatNumMonth(subType.reproductionMinAgeMonth)
            elseif self.isParent and self.monthsSinceLastBirth <= 2 then
                reasonText = g_i18n:getText("rl_ui_recoveringLastBirth")
                thresholdText = g_i18n:formatNumMonth(3 - self.monthsSinceLastBirth)
            elseif not RealisticLivestock.hasMaleAnimalInPen(self.clusterSystem, subType.name, self) and self.reproduction == 0 then
                reasonText = g_i18n:getText("rl_ui_noMaleAnimal")
                thresholdText = "0"
            elseif healthFactor < subType.reproductionMinHealth then
                reasonText = g_i18n:getText("rl_ui_unhealthy")
                thresholdText = string.format("%d %%", subType.reproductionMinHealth)
            end

            if reasonText ~= nil then
                self.infoReproduction.valueText = string.format("%s (< %s)", reasonText, thresholdText)
            end
        end

        table.insert(infos, self.infoReproduction)
    end

    if hasMonitor then
        if self.infoWeight == nil then
            self.infoWeight = {
                text = g_i18n:getText("rl_ui_weight"),
                title = g_i18n:getText("rl_ui_weight")
            }
        end


        self.infoWeight.value = 1
        self.infoWeight.ratio = self.weight / self.targetWeight
        self.infoWeight.valueText = string.format("%.2f", self.weight) ..
        "kg / " .. string.format("%.2f", self.targetWeight) .. "kg"

        table.insert(infos, self.infoWeight)
    end


    if self.gender ~= nil and self.gender == "female" then
        if self.infoPregnant == nil then
            self.infoPregnant = {
                text = g_i18n:getText("rl_ui_pregnant"),
                title = g_i18n:getText("rl_ui_pregnant")
            }
        end


        self.infoPregnant.value = 1
        self.infoPregnant.ratio = self.isPregnant and 1 or 0
        self.infoPregnant.valueText = self.isPregnant and g_i18n:getText("rl_ui_yes") or g_i18n:getText("rl_ui_no")

        table.insert(infos, self.infoPregnant)

        local pregnancy = self.pregnancy

        if pregnancy ~= nil and pregnancy.pregnancies and #pregnancy.pregnancies > 0 then
            if self.infoPregnancyExpecting == nil then
                self.infoPregnancyExpecting = {
                    text = g_i18n:getText("rl_ui_pregnancyExpecting"),
                    title = g_i18n:getText("rl_ui_pregnancyExpecting"),
                    value = 1,
                    ratio = 1
                }
            end

            if self.infoPregnancyExpected == nil then
                self.infoPregnancyExpected = {
                    text = g_i18n:getText("rl_ui_pregnancyExpected"),
                    title = g_i18n:getText("rl_ui_pregnancyExpected"),
                    value = 1,
                    ratio = 1
                }
            end

            self.infoPregnancyExpecting.valueText = string.format("%s %s", #pregnancy.pregnancies,
                g_i18n:getText("rl_ui_pregnancy" .. (#pregnancy.pregnancies == 1 and "Baby" or "Babies")))
            self.infoPregnancyExpected.valueText = string.format("%s/%s/%s", pregnancy.expected.day,
                pregnancy.expected.month, pregnancy.expected.year + RLConstants.START_YEAR.FULL)

            table.insert(infos, self.infoPregnancyExpecting)
            table.insert(infos, self.infoPregnancyExpected)
        end

        if self.isLactating ~= nil and hasMonitor and self.age > 12 and self.clusterSystem ~= nil and self.clusterSystem.owner.spec_husbandryMilk ~= nil then
            if self.infoLactation == nil then
                self.infoLactation = {
                    text = g_i18n:getText("rl_ui_lactating"),
                    title = g_i18n:getText("rl_ui_lactating")
                }
            end

            self.infoLactation.value = 1
            self.infoLactation.ratio = self.isLactating and 1 or 0
            self.infoLactation.valueText = self.isLactating and g_i18n:getText("rl_ui_yes") or g_i18n:getText("rl_ui_no")

            table.insert(infos, self.infoLactation)
        end
    end


    if self:isHorse() then
        AnimalHorse.addHorseInfos(self, infos)
    end
end

function Animal:showInfo(box)
    local index = self:getSubTypeIndex()
    local subType = self:getSubType()
    local name = subType.name

    local yesText = g_i18n:getText("rl_ui_yes")
    local noText = g_i18n:getText("rl_ui_no")

    local fillTypeTitle = g_fillTypeManager:getFillTypeTitleByIndex(subType.fillTypeIndex)

    box:addLine(g_i18n:getText("infohud_type"), fillTypeTitle)
    if self:getName() ~= "" then box:addLine(g_i18n:getText("infohud_name"), self:getName()) end
    box:addLine(g_i18n:getText("rl_ui_uniqueId"), self.uniqueId)
    box:addLine(g_i18n:getText("rl_ui_farmId"), self.farmId)
    box:addLine(g_i18n:getText("infohud_age"), RealisticLivestock.formatAge(self.age))

    if self.birthday ~= nil then
        local birthday = self.birthday
        box:addLine(g_i18n:getText("rl_ui_birthday"),
            string.format("%d/%d/%d", birthday.day, birthday.month, RLConstants.START_YEAR.FULL + birthday.year))
    end

    box:addLine(g_i18n:getText("rl_ui_gender"),
        self.gender == "male" and g_i18n:getText("rl_ui_male") or g_i18n:getText("rl_ui_female"))


    if self:isHorse() then
        AnimalHorse.showHorseHudInfo(self, box)
    end

    if self.gender ~= nil and self.gender == "female" and subType.supportsReproduction then
        box:addLine(g_i18n:getText("infohud_reproduction"), string.format("%d%%", self.reproduction))


        local pregnancy = self.pregnancy

        if pregnancy ~= nil and pregnancy.pregnancies and #pregnancy.pregnancies > 0 then
            box:addLine(g_i18n:getText("rl_ui_pregnancyExpecting"),
                string.format("%s %s", #pregnancy.pregnancies,
                    g_i18n:getText("rl_ui_pregnancy" .. (#pregnancy.pregnancies == 1 and "Baby" or "Babies"))))
            box:addLine(g_i18n:getText("rl_ui_pregnancyExpected"),
                string.format("%s/%s/%s", pregnancy.expected.day, pregnancy.expected.month,
                    pregnancy.expected.year + RLConstants.START_YEAR.FULL))
        end


        local healthFactor = self:getHealthFactor()
        local text = yesText

        if self.age < subType.reproductionMinAgeMonth then
            text = g_i18n:getText("rl_ui_tooYoungBracketed")
        elseif self.isParent and self.monthsSinceLastBirth <= 2 then
            text = g_i18n:getText("rl_ui_recoveringLastBirthBracketed")
        elseif self.clusterSystem ~= nil and not RealisticLivestock.hasMaleAnimalInPen(self.clusterSystem.owner.spec_husbandryAnimals, name, self) and not self.isPregnant then
            text = g_i18n:getText("rl_ui_noMaleAnimalBracketed")
        elseif healthFactor < subType.reproductionMinHealth then
            text = g_i18n:getText("rl_ui_unhealthyBracketed")
        end

        box:addLine(g_i18n:getText("rl_ui_canReproduce"), text)

        if self.age >= subType.reproductionMinAgeMonth then box:addLine(g_i18n:getText("rl_ui_pregnant"),
                self.isPregnant and yesText or noText) end

        if self.isPregnant then box:addLine(g_i18n:getText("rl_ui_impregnatedBy"),
                (self.impregnatedBy ~= nil and self.impregnatedBy.uniqueId ~= "-1") and self.impregnatedBy.uniqueId or
                g_i18n:getText("rl_ui_unknown")) end
    elseif self.gender ~= nil and self.gender == "male" and subType.reproductionMinAgeMonth ~= nil and self.age >= subType.reproductionMinAgeMonth then
        local monotonicHour = g_currentMission.environment:getMonotonicHour()
        if self.numImpregnatableAnimals == nil or (self.lastNumImpregnatableAnimalsUpdate ~= nil and monotonicHour >= self.lastNumImpregnatableAnimalsUpdate + 1) then
            self.lastNumImpregnatableAnimalsUpdate = monotonicHour
            self.numImpregnatableAnimals = self:getNumberOfImpregnatableFemalesForMale()
        end

        box:addLine(g_i18n:getText("rl_ui_maleNumImpregnatable"), string.format("%s", self.numImpregnatableAnimals or 0))
    end

    box:addLine(g_i18n:getText("rl_ui_value"), g_i18n:formatMoney(self:getSellPrice(), 2, true, true))

    if self.isCastrated then box:addLine(g_i18n:getText("rl_ui_castrated"), g_i18n:getText("rl_ui_yes")) end
end

function Animal:showGeneticsInfo(box)
    local genetics = self.genetics
    local metabolism = genetics.metabolism
    local typeIndex = self.animalTypeIndex


    local overallGenetics = metabolism + genetics.quality + genetics.health + genetics.fertility +
    (genetics.productivity ~= nil and genetics.productivity or 0)
    local bestGenetics = 1.75 + 1.75 + 1.75 + 1.75 + (genetics.productivity ~= nil and 1.75 or 0)
    local qualityText = "extremelyBad"
    local geneticsFactor = overallGenetics / bestGenetics

    if geneticsFactor >= 0.95 then
        qualityText = "extremelyGood"
    elseif geneticsFactor >= 0.8 then
        qualityText = "veryGood"
    elseif geneticsFactor >= 0.65 then
        qualityText = "good"
    elseif geneticsFactor >= 0.35 then
        qualityText = "average"
    elseif geneticsFactor >= 0.2 then
        qualityText = "bad"
    elseif geneticsFactor >= 0.05 then
        qualityText = "veryBad"
    end

    box:addLine("rl_ui_overall", "rl_ui_genetics_" .. qualityText)

    if metabolism >= 1.65 then
        qualityText = "extremelyHigh"
    elseif metabolism >= 1.4 then
        qualityText = "veryHigh"
    elseif metabolism >= 1.1 then
        qualityText = "high"
    elseif metabolism >= 0.9 then
        qualityText = "average"
    elseif metabolism >= 0.7 then
        qualityText = "low"
    elseif metabolism >= 0.35 then
        qualityText = "veryLow"
    else
        qualityText = "extremelyLow"
    end

    box:addLine(g_i18n:getText("rl_ui_metabolism"), "rl_ui_genetics_" .. qualityText)

    local health = genetics.health

    if health >= 1.65 then
        qualityText = "extremelyHigh"
    elseif health >= 1.4 then
        qualityText = "veryHigh"
    elseif health >= 1.1 then
        qualityText = "high"
    elseif health >= 0.9 then
        qualityText = "average"
    elseif health >= 0.7 then
        qualityText = "low"
    elseif health >= 0.35 then
        qualityText = "veryLow"
    else
        qualityText = "extremelyLow"
    end

    box:addLine(g_i18n:getText("rl_ui_health"), "rl_ui_genetics_" .. qualityText)

    local fertility = genetics.fertility

    if fertility >= 1.65 then
        qualityText = "extremelyHigh"
    elseif fertility >= 1.4 then
        qualityText = "veryHigh"
    elseif fertility >= 1.1 then
        qualityText = "high"
    elseif fertility >= 0.9 then
        qualityText = "average"
    elseif fertility >= 0.7 then
        qualityText = "low"
    elseif fertility >= 0.35 then
        qualityText = "veryLow"
    elseif fertility > 0 then
        qualityText = "extremelyLow"
    else
        qualityText = "infertile"
    end

    box:addLine(g_i18n:getText("rl_ui_fertility"), "rl_ui_genetics_" .. qualityText)

    local meat = genetics.quality

    if meat >= 1.65 then
        qualityText = "extremelyHigh"
    elseif meat >= 1.4 then
        qualityText = "veryHigh"
    elseif meat >= 1.1 then
        qualityText = "high"
    elseif meat >= 0.9 then
        qualityText = "average"
    elseif meat >= 0.7 then
        qualityText = "low"
    elseif meat >= 0.35 then
        qualityText = "veryLow"
    else
        qualityText = "extremelyLow"
    end

    box:addLine(g_i18n:getText("rl_ui_meat"), "rl_ui_genetics_" .. qualityText)

    if genetics.productivity ~= nil then
        local productivity = genetics.productivity

        if productivity >= 1.65 then
            qualityText = "extremelyHigh"
        elseif productivity >= 1.4 then
            qualityText = "veryHigh"
        elseif productivity >= 1.1 then
            qualityText = "high"
        elseif productivity >= 0.9 then
            qualityText = "average"
        elseif productivity >= 0.7 then
            qualityText = "low"
        elseif productivity >= 0.35 then
            qualityText = "veryLow"
        else
            qualityText = "extremelyLow"
        end

        if typeIndex == AnimalType.COW then box:addLine(g_i18n:getText("rl_ui_milk"), "rl_ui_genetics_" .. qualityText) end
        if typeIndex == AnimalType.SHEEP then box:addLine(g_i18n:getText((self.subType == "GOAT" or self.subType == "RAM_GOAT") and "rl_ui_milk" or "rl_ui_wool"), "rl_ui_genetics_" .. qualityText) end
        if typeIndex == AnimalType.CHICKEN then box:addLine(g_i18n:getText("rl_ui_eggs"),
                "rl_ui_genetics_" .. qualityText) end
    end
end

function Animal:addGeneticsInfo()
    local texts = {}

    local genetics = self.genetics
    if genetics == nil then return {} end

    local text = {}

    local metabolism = genetics.metabolism
    local overallGenetics = metabolism + genetics.quality + genetics.health + genetics.fertility +
    (genetics.productivity ~= nil and genetics.productivity or 0)
    local bestGenetics = 1.75 + 1.75 + 1.75 + 1.75 + (genetics.productivity ~= nil and 1.75 or 0)
    local qualityText = "extremelyBad"
    local geneticsFactor = overallGenetics / bestGenetics

    if geneticsFactor >= 0.95 then
        qualityText = "extremelyGood"
    elseif geneticsFactor >= 0.8 then
        qualityText = "veryGood"
    elseif geneticsFactor >= 0.6 then
        qualityText = "good"
    elseif geneticsFactor >= 0.4 then
        qualityText = "average"
    elseif geneticsFactor >= 0.2 then
        qualityText = "bad"
    elseif geneticsFactor >= 0.05 then
        qualityText = "veryBad"
    end

    text = {
        title = g_i18n:getText("rl_ui_overall"),
        text = "rl_ui_genetics_" .. qualityText
    }

    table.insert(texts, text)

    if metabolism >= 1.65 then
        qualityText = "extremelyHigh"
    elseif metabolism >= 1.4 then
        qualityText = "veryHigh"
    elseif metabolism >= 1.1 then
        qualityText = "high"
    elseif metabolism >= 0.9 then
        qualityText = "average"
    elseif metabolism >= 0.7 then
        qualityText = "low"
    elseif metabolism >= 0.35 then
        qualityText = "veryLow"
    else
        qualityText = "extremelyLow"
    end

    text = {
        title = g_i18n:getText("rl_ui_metabolism"),
        text = "rl_ui_genetics_" .. qualityText
    }

    table.insert(texts, text)

    local health = genetics.health

    if health >= 1.65 then
        qualityText = "extremelyHigh"
    elseif health >= 1.4 then
        qualityText = "veryHigh"
    elseif health >= 1.1 then
        qualityText = "high"
    elseif health >= 0.9 then
        qualityText = "average"
    elseif health >= 0.7 then
        qualityText = "low"
    elseif health >= 0.35 then
        qualityText = "veryLow"
    else
        qualityText = "extremelyLow"
    end

    text = {
        title = g_i18n:getText("rl_ui_health"),
        text = "rl_ui_genetics_" .. qualityText
    }

    table.insert(texts, text)

    local fertility = genetics.fertility

    if fertility >= 1.65 then
        qualityText = "extremelyHigh"
    elseif fertility >= 1.4 then
        qualityText = "veryHigh"
    elseif fertility >= 1.1 then
        qualityText = "high"
    elseif fertility >= 0.9 then
        qualityText = "average"
    elseif fertility >= 0.7 then
        qualityText = "low"
    elseif fertility >= 0.35 then
        qualityText = "veryLow"
    elseif fertility > 0 then
        qualityText = "extremelyLow"
    else
        qualityText = "infertile"
    end

    text = {
        title = g_i18n:getText("rl_ui_fertility"),
        text = "rl_ui_genetics_" .. qualityText
    }

    table.insert(texts, text)

    local meat = genetics.quality

    if meat >= 1.65 then
        qualityText = "extremelyHigh"
    elseif meat >= 1.4 then
        qualityText = "veryHigh"
    elseif meat >= 1.1 then
        qualityText = "high"
    elseif meat >= 0.9 then
        qualityText = "average"
    elseif meat >= 0.7 then
        qualityText = "low"
    elseif meat >= 0.35 then
        qualityText = "veryLow"
    else
        qualityText = "extremelyLow"
    end

    text = {
        title = g_i18n:getText("rl_ui_meat"),
        text = "rl_ui_genetics_" .. qualityText
    }

    table.insert(texts, text)

    if genetics.productivity ~= nil then
        local productivity = genetics.productivity

        if productivity >= 1.65 then
            qualityText = "extremelyHigh"
        elseif productivity >= 1.4 then
            qualityText = "veryHigh"
        elseif productivity >= 1.1 then
            qualityText = "high"
        elseif productivity >= 0.9 then
            qualityText = "average"
        elseif productivity >= 0.7 then
            qualityText = "low"
        elseif productivity >= 0.35 then
            qualityText = "veryLow"
        else
            qualityText = "extremelyLow"
        end

        local productivityTitle = ""
        if self.animalTypeIndex == AnimalType.COW then productivityTitle = g_i18n:getText("rl_ui_milk") end
        if self.animalTypeIndex == AnimalType.SHEEP then productivityTitle = g_i18n:getText((self.subType == "GOAT" or self.subType == "RAM_GOAT") and "rl_ui_milk" or "rl_ui_wool") end
        if self.animalTypeIndex == AnimalType.CHICKEN then productivityTitle = g_i18n:getText("rl_ui_eggs") end

        text = {
            title = productivityTitle,
            text = "rl_ui_genetics_" .. qualityText
        }

        table.insert(texts, text)
    end

    return texts
end

function Animal:showMonitorInfo(box)
    if not self.monitor.active and not self.monitor.removed then return end

    local daysPerMonth = g_currentMission.environment.daysPerPeriod

    box:addLine(g_i18n:getText("rl_ui_monitorFee"),
        string.format(g_i18n:getText("rl_ui_feePerMonth"), g_i18n:formatMoney(self.monitor.fee, 2, true, true)))
    box:addLine(g_i18n:getText("infohud_health"), string.format("%d%%", self.health))

    if self.clusterSystem ~= nil and self.clusterSystem.owner.spec_husbandryMilk ~= nil and self.gender ~= nil and self.gender == "female" and self.age >= 12 then
        if self.isLactating ~= nil then box:addLine(g_i18n:getText("rl_ui_lactating"),
                self.isLactating and g_i18n:getText("rl_ui_yes") or g_i18n:getText("rl_ui_no")) end
    end

    box:addLine(g_i18n:getText("rl_ui_weight"), string.format("%.2f", self.weight) .. "kg")
    box:addLine(g_i18n:getText("rl_ui_targetWeight"), string.format("%.2f", self.targetWeight) .. "kg")
    box:addLine(g_i18n:getText("rl_ui_valuePerKilo"),
        g_i18n:formatMoney(self:getSellPrice() / self.weight, 2, true, true))

    for fillType, amount in pairs(self.input) do
        box:addLine(g_i18n:getText("rl_ui_input_" .. fillType),
            string.format(g_i18n:getText("rl_ui_amountPerDay"), (amount * 24) / daysPerMonth))
    end

    for fillType, amount in pairs(self.output) do
        local outputText = fillType

        if fillType == "pallets" then
            if self.animalTypeIndex == AnimalType.COW then outputText = "pallets_milk" end

            if self.animalTypeIndex == AnimalType.SHEEP then outputText = self.subType == "GOAT" and "pallets_goatMilk" or
                "pallets_wool" end

            if self.animalTypeIndex == AnimalType.CHICKEN then outputText = "pallets_eggs" end
        end

        box:addLine(g_i18n:getText("rl_ui_output_" .. outputText),
            string.format(g_i18n:getText("rl_ui_amountPerDay"), (amount * 24) / daysPerMonth))
    end
end

function Animal:showDiseasesInfo(box)
    for _, disease in pairs(self.diseases) do disease:showInfo(box) end
end

function Animal:getFillTypeTitle()
    return g_fillTypeManager:getFillTypeTitleByIndex(self:getSubType().fillTypeIndex)
end

function Animal:getHealthFactor() return AnimalHealth.getHealthFactor(self) end

-- Fertility/reproduction delegates -> AnimalReproduction module
function Animal:getReproductionFactor() return AnimalReproduction.getReproductionFactor(self) end

function Animal:getSupportsReproduction() return AnimalReproduction.getSupportsReproduction(self) end

function Animal:changeReproduction(delta) AnimalReproduction.changeReproduction(self, delta) end

function Animal:getReproductionDelta() return AnimalReproduction.getReproductionDelta(self) end

function Animal:getCanReproduce() return AnimalReproduction.getCanReproduce(self) end

function Animal:updateHealth(foodFactor) AnimalHealth.updateHealth(self, foodFactor) end

function Animal:updateWeight(foodFactor)
    local subType = self:getSubType()
    local minWeight = subType.minWeight
    local targetWeight = self.targetWeight
    local weight = self.weight
    local metabolism = self.genetics.metabolism
    local adultMonth = subType.reproductionMinAgeMonth * 1.5

    local baseIncrease = ((targetWeight - minWeight) / adultMonth) / (24 * g_currentMission.environment.daysPerPeriod)
    local increase = baseIncrease * (self.gender == "female" and 0.6 or 1.0) * (1 + ((adultMonth - self.age) / 75)) *
    math.min(foodFactor * 1.25, 1)

    if increase < 0 then metabolism = 1 + (1 - metabolism) end

    increase = increase * metabolism

    if self.isCastrated then increase = increase * 1.15 end

    if self.clusterSystem ~= nil and self.clusterSystem.owner ~= nil and self.clusterSystem.owner.spec_husbandryMilk ~= nil and self.isLactating then increase =
        increase * 0.75 end

    local decrease = 0
    if weight > targetWeight then decrease = (weight - targetWeight) / (metabolism * 25) end

    if foodFactor == 0 then
        if weight < targetWeight then
            decrease = (targetWeight - weight) / ((1 - (metabolism - 1)) * 150)
        elseif weight > targetWeight then
            decrease = decrease + ((weight - targetWeight) / ((1 - (metabolism - 1)) * 150))
        end
    end

    self.weight = math.max(self.weight + increase - decrease, 0.001)

    local minWeightForAge = minWeight * (math.min(self.age, subType.reproductionMinAgeMonth * 1.5) + 0.5) * 0.5
    if self.weight < minWeightForAge then self.health = math.clamp(
        self.health - (((minWeightForAge - self.weight) / minWeightForAge) * 0.2), 0, 100) end
end

--- Advance post-birth recovery by one period: bump monthsSinceLastBirth and,
--- once it reaches the lactation cutoff, stop lactating. Pure and deterministic
--- -- reads/writes only these two fields, touches no game state and sets no
--- dirty flag -- so MP clients can run it locally in lockstep with the server,
--- the same property that lets aging run client-side. The isLactating flip is
--- one-directional at >= 10; re-enabling lactation is AnimalBirthEvent's job.
--- @see RealisticLivestock_PlaceableHusbandryAnimals.onPeriodChanged (client branch)
function Animal:advanceRecoveryPeriod()
    -- A legacy/corrupt savegame may carry a nil counter (Animal.new coerces it to
    -- 0); guard so the +1 cannot throw on a peer that bypassed those defaults.
    if self.monthsSinceLastBirth == nil then self.monthsSinceLastBirth = 0 end

    self.monthsSinceLastBirth = self.monthsSinceLastBirth + 1

    if self.isLactating and self.monthsSinceLastBirth >= 10 then
        self.isLactating = false
    end

    Log:trace("advanceRecoveryPeriod: uniqueId=%s monthsSinceLastBirth=%d isLactating=%s",
        tostring(self.uniqueId), self.monthsSinceLastBirth, tostring(self.isLactating))
end

function Animal:onPeriodChanged()
    self:advanceRecoveryPeriod()

    local totalTreatmentCost = 0

    for i = #self.diseases, 1, -1 do
        local died, treatmentCost = self.diseases[i]:onPeriodChanged(self, self.deathEnabled)
        totalTreatmentCost = totalTreatmentCost + treatmentCost

        if died then return totalTreatmentCost end
    end

    return totalTreatmentCost
end

function Animal:onDayChanged(spec, isServer, day, month, year, currentDayInPeriod, daysPerPeriod, isSaleAnimal)
    if g_server ~= nil and g_diseaseManager ~= nil then g_diseaseManager:onDayChanged(self) end

    self:setRecentlyBoughtByAI(false)

    local birthday = self.birthday

    if day == nil then
        local environment = g_currentMission.environment
        month = environment.currentPeriod + 2
        currentDayInPeriod = environment.currentDayInPeriod

        if month > 12 then month = month - 12 end

        daysPerPeriod = environment.daysPerPeriod
        day = 1 + math.floor((currentDayInPeriod - 1) * (RLConstants.DAYS_PER_MONTH[month] / daysPerPeriod))
        year = environment.currentYear
    end


    if birthday ~= nil and birthday.lastAgeMonth ~= month then
        if birthday.day <= day or currentDayInPeriod == daysPerPeriod then
            self:increaseAge()
            self.birthday.lastAgeMonth = month
        end
    elseif birthday == nil and day == 1 then
        self:increaseAge()
    end


    if self:isHorse() and not isSaleAnimal then
        AnimalHorse.processRidingUpdate(self)
    end

    -- Reproduction: insemination resolution, pregnancy progression, natural conception
    local children, deadAnimals, childrenSold, childrenSoldAmount =
        AnimalReproduction.processDaily(self, spec, day, month, year, isSaleAnimal)

    -- Death evaluation: low health -> old age -> random accidents (with AnimalDeathEvent broadcast)
    local lowHealthDeath, oldDeath, randomDeath, randomDeathMoney =
        AnimalHealth.evaluateDaily(self, spec)

    return children, deadAnimals, childrenSold, childrenSoldAmount, lowHealthDeath, oldDeath, randomDeath,
        randomDeathMoney
end

-- Reproduction delegates -> AnimalReproduction module
function Animal:createPregnancy(childNum, month, year, father) AnimalReproduction.createPregnancy(self, childNum, month,
        year, father) end

function Animal:generateRandomOffspring() return AnimalReproduction.generateRandomOffspring(self) end

function Animal:reproduce(spec, day, month, year, isSaleAnimal) return AnimalReproduction.reproduce(self, spec, day,
        month, year, isSaleAnimal) end

function Animal:getAnimalTypeIndex()
    return g_currentMission.animalSystem:getTypeIndexBySubTypeIndex(self.subTypeIndex)
end

-- Health/death delegates -> AnimalHealth module
function Animal:die(reason) AnimalHealth.die(self, reason) end

function Animal:calculateLowHealthMonthlyAnimalDeaths() return AnimalHealth.calculateLowHealthMonthlyAnimalDeaths(self) end

function Animal:calculateOldAgeMonthlyAnimalDeaths() return AnimalHealth.calculateOldAgeMonthlyAnimalDeaths(self) end

function Animal:calculateRandomMonthlyAnimalDeaths(spec) return AnimalHealth.calculateRandomMonthlyAnimalDeaths(self,
        spec) end

-- ##################################
--             HORSES
-- (implementations in AnimalHorse.lua)
-- ##################################

--- Canonical horse type check. Use this instead of string-matching self.subType.
--- @return boolean true if this animal is a horse (any subtype: HORSE, STALLION, etc.)
function Animal:isHorse() return self.animalTypeIndex == AnimalType.HORSE end

function Animal:getHealthChangeFactor(foodFactor) return AnimalHorse.getHealthChangeFactor(self, foodFactor) end

function Animal:getFitnessFactor() return AnimalHorse.getFitnessFactor(self) end

function Animal:changeFitness(delta) AnimalHorse.changeFitness(self, delta) end

function Animal:getRidingFactor() return AnimalHorse.getRidingFactor(self) end

function Animal:setRiding(riding) AnimalHorse.setRiding(self, riding) end

function Animal:resetRiding() AnimalHorse.resetRiding(self) end

function Animal:changeRiding(delta) AnimalHorse.changeRiding(self, delta) end

function Animal:getDirtFactor() return AnimalHorse.getDirtFactor(self) end

function Animal:changeDirt(delta) AnimalHorse.changeDirt(self, delta) end

function Animal:getSellPrice()
    local subType = self:getSubType()
    local sellPrice = subType.sellPrice:get(self.age < 0 and 0 or self.age)

    local weight = self.weight
    local targetWeightForAge = ((self.targetWeight - subType.minWeight) / (subType.reproductionMinAgeMonth * 1.5)) *
    math.min(self.age + 1.5, subType.reproductionMinAgeMonth * 1.5) * 0.85

    local weightFactor = 1 + ((weight - targetWeightForAge) / targetWeightForAge)

    local meatFactor = self.genetics.quality

    sellPrice = sellPrice + (sellPrice * 0.25 * (meatFactor - 1))

    sellPrice = math.max(sellPrice + (((sellPrice * 0.6) / subType.targetWeight) * weight * (-1 + meatFactor)), 0.5)

    if self.isCastrated then sellPrice = sellPrice + sellPrice * 0.15 end

    for _, disease in pairs(self.diseases) do sellPrice = disease:modifyValue(sellPrice) end

    if self:isHorse() then
        return AnimalHorse.getHorseSellPrice(self, sellPrice, meatFactor, weightFactor)
    end

    return math.max(
    sellPrice * 0.6 + (sellPrice * 0.4 * weightFactor * (0.75 * self:getHealthFactor())) +
    sellPrice * (self.isLactating and 0.15 or 0) + sellPrice * (self.isPregnant and 0.25 or 0), sellPrice * 0.05)
end

function Animal:getDailyRidingTime() return AnimalHorse.getDailyRidingTime(self) end

function Animal:getNumberOfImpregnatableFemalesForMale()
    if self.gender == "female" or self.clusterSystem == nil then return 0 end

    local subType = self:getSubType()
    local animalType = self.animalTypeIndex

    if (subType.reproductionMinAgeMonth ~= nil and subType.reproductionMinAgeMonth > self.age) or ((animalType == AnimalType.COW and self.age >= 132) or (animalType == AnimalType.SHEEP and self.age >= 72) or (animalType == AnimalType.HORSE and self.age >= 300) or (animalType == AnimalType.CHICKEN and self.age >= 72) or (animalType == AnimalType.PIG and self.age >= 48)) then return 0 end

    local i = 0
    local id = self:getIdentifiers()

    for _, animal in ipairs(self.clusterSystem:getAnimals()) do
        if animal.gender == "male" or (animal.fatherId ~= nil and id == animal.fatherId) or animal.isPregnant then continue end

        local s = animal:getSubType()
        if s.reproductionMinAgeMonth == nil or s.reproductionMinAgeMonth > animal.age then continue end

        if subType.name == "BULL_WATERBUFFALO" then
            if s.name == "COW_WATERBUFFALO" then i = i + 1 end
        elseif subType.name == "RAM_GOAT" then
            if s.name == "GOAT" then i = i + 1 end
        elseif s.name ~= "GOAT" and s.name ~= "COW_WATERBUFFALO" then
            i = i + 1
        end
    end

    return i
end

function Animal.onSettingChanged(name, state)
    Animal[name] = state
end

--- Pure daily-food formula extracted from Animal:updateInput so both the live
--- path and the pen feed forecast (RLPenFeedForecast) share one source of truth.
--- Mirrors the legacy `if fillType == "food"` branch verbatim.
---@param age number               Animal age in months (reserved; not used yet -- kept for symmetry with forecast scratch state).
---@param isLactating boolean      Lactation flag.
---@param reproduction number|nil  Reproduction counter [0, 100].
---@param numPregnancies number    Count of expected offspring; pass 0 when not pregnant.
---@param metabolism number|nil    Genetics metabolism multiplier.
---@param baseCurveValue number    `subType.input.food:get(age)` from the caller.
---@param foodScale number|nil     Global food-scale setting (`RealisticLivestock_PlaceableHusbandryFood.foodScale`); defaults to 1 when nil.
---@return number litersPerDay
function Animal._computeDailyFood(age, isLactating, reproduction, numPregnancies, metabolism, baseCurveValue, foodScale)
    local litersPerDay = baseCurveValue

    if isLactating then litersPerDay = litersPerDay * 1.25 end

    if reproduction ~= nil and reproduction > 0 and numPregnancies > 0 then
        litersPerDay = litersPerDay * math.min(math.pow(1 + ((reproduction / 100) / 5), numPregnancies), 2.0)
    end

    if metabolism ~= nil then litersPerDay = litersPerDay * metabolism end

    litersPerDay = litersPerDay * (foodScale or 1)

    return litersPerDay
end

function Animal:updateInput()
    local subType = self:getSubType()


    for fillType, input in pairs(subType.input) do
        local litersPerDay = input:get(self.age)

        if fillType == "food" then
            local numPregnancies = (self.pregnancy ~= nil and self.pregnancy.pregnancies ~= nil)
                and #self.pregnancy.pregnancies or 0
            litersPerDay = Animal._computeDailyFood(
                self.age,
                self.isLactating,
                self.reproduction,
                numPregnancies,
                self.genetics.metabolism,
                litersPerDay,
                RealisticLivestock_PlaceableHusbandryFood.foodScale
            )
        end

        if fillType == "water" then
            if self.isLactating then litersPerDay = litersPerDay * 1.5 end

            if self.reproduction ~= nil and self.reproduction > 0 and self.pregnancy ~= nil and self.pregnancy.pregnancies ~= nil then
                litersPerDay = litersPerDay * math.min(math.pow(1 + ((self.reproduction / 100) / 5), #self.pregnancy.pregnancies), 2.0)
            end
        end

        self.input[fillType] = litersPerDay / 24
    end

    if self.isLactating or self.isPregnant then
        local pregCount = (self.pregnancy ~= nil and self.pregnancy.pregnancies ~= nil) and #self.pregnancy.pregnancies or 0
        Log:trace("updateInput: animal=%s food/h=%.4f water/h=%.4f isLactating=%s isPregnant=%s reproduction=%d pregnancies=%d",
            tostring(self.uniqueId), self.input.food or 0, self.input.water or 0,
            tostring(self.isLactating), tostring(self.isPregnant), self.reproduction or 0, pregCount)
    end
end

function Animal:updateOutput(temp)
    local subType = self:getSubType()

    for fillType, output in pairs(subType.output) do
        local litersPerDay = 0

        if output.curve ~= nil then
            litersPerDay = output.curve:get(self.age)
        else
            litersPerDay = output:get(self.age)
        end

        if litersPerDay == nil then
            Log:warning("updateOutput: nil litersPerDay for '%s' output '%s' (age=%d, hasCurve=%s, subType='%s')",
                tostring(self.uniqueId), fillType, self.age, tostring(output.curve ~= nil), tostring(subType.name))
            litersPerDay = 0
        end

        if fillType == "pallets" then
            local fillTypeIndex = output.fillType
            local productivity = self.genetics.productivity or 1

            if fillTypeIndex == FillType.WOOL then
                if temp < 12 then litersPerDay = 0 end
            elseif fillTypeIndex == FillType.GOATMILK then
                local monthsSinceLastBirth = self.monthsSinceLastBirth or 12
                local factor = 0.8

                if monthsSinceLastBirth >= 10 or not self.isLactating or not self.isParent then
                    factor = 0
                elseif monthsSinceLastBirth <= 3 then
                    factor = factor + (monthsSinceLastBirth / 6)
                else
                    factor = factor + ((11 - monthsSinceLastBirth) / 15)
                end

                litersPerDay = litersPerDay * factor
            end

            litersPerDay = litersPerDay * productivity
        end

        -- Milk diagnostics: capture the milk gate breakdown here, but defer the
        -- logging until AFTER the disease modifier below - a sick cow is zeroed by
        -- disease:modifyOutput, not by the lactation gate, and the two are
        -- indistinguishable from the husbandry side (both read 0). Carrying these in
        -- loop-body locals lets the post-disease log split "gate failure" from "disease".
        local isMilk = fillType == "milk"
        local milkCurve, milkFactor, milkProductivity, milkPreDisease

        if isMilk then
            local monthsSinceLastBirth = self.monthsSinceLastBirth or 12
            local factor = 0.8
            local productivity = self.genetics.productivity or 1
            local curveLitersPerDay = litersPerDay

            if monthsSinceLastBirth >= 10 or not self.isLactating or not self.isParent then
                factor = 0
            elseif monthsSinceLastBirth <= 3 then
                factor = factor + (monthsSinceLastBirth / 6)
            else
                factor = factor + ((11 - monthsSinceLastBirth) / 15)
            end

            litersPerDay = litersPerDay * factor * productivity

            milkCurve, milkFactor, milkProductivity, milkPreDisease = curveLitersPerDay, factor, productivity, litersPerDay
        end

        for _, disease in pairs(self.diseases) do litersPerDay = disease:modifyOutput(fillType, litersPerDay) end

        if isMilk then
            -- litersPerDay is now the FINAL value (post lactation gate AND disease).
            -- TRACE the full breakdown for every cow every recompute; there is no
            -- debugger, so this is the only way to see why a lactating cow yields no milk.
            Log:trace("updateOutput[milk]: animal=%s/%s subType=%s age=%d curve(l/day)=%.3f isLactating=%s isParent=%s months=%s factor=%.3f productivity=%.3f diseases=%d -> preDisease l/h=%.4f final l/h=%.4f",
                tostring(self.farmId), tostring(self.uniqueId), tostring(subType.name), self.age or -1,
                milkCurve, tostring(self.isLactating), tostring(self.isParent),
                tostring(self.monthsSinceLastBirth), milkFactor, milkProductivity, #self.diseases,
                milkPreDisease / 24, litersPerDay / 24)

            -- Smoking-gun DEBUG: client shows "lactating" but the FINAL server output is 0.
            -- reason= attributes it - "disease" (gate produced milk, a disease zeroed it)
            -- vs a specific gate term. Surfaces at the default dev level.
            if self.isLactating and litersPerDay <= 0 then
                local reason = (milkPreDisease > 0 and "disease")
                    or (milkCurve <= 0 and "curve=0(age?)")
                    or (not self.isParent and "notParent")
                    or ((self.monthsSinceLastBirth or 12) >= 10 and "months>=10")
                    or (milkProductivity <= 0 and "productivity=0")
                    or (milkFactor <= 0 and "factor=0")
                    or "unknown"
                Log:debug("updateOutput[milk]: animal=%s/%s is LACTATING but produces 0 milk (age=%d curve=%.3f isParent=%s months=%s productivity=%.3f diseases=%d preDisease l/h=%.4f) reason=%s",
                    tostring(self.farmId), tostring(self.uniqueId), self.age or -1, milkCurve,
                    tostring(self.isParent), tostring(self.monthsSinceLastBirth), milkProductivity,
                    #self.diseases, milkPreDisease / 24, reason)
            end
        end

        self.output[fillType] = litersPerDay / 24
    end
end

function Animal:getInput(inputType)
    return self.input[inputType] or 0
end

function Animal:getOutput(outputType)
    return self.output[outputType] or 0
end

function Animal:getHasName()
    return self.name ~= nil and self.name ~= ""
end

function Animal:removeDisease(title)
    for i, disease in pairs(self.diseases) do
        if disease.type.title == title then
            self:addMessage("DISEASE_CURED", { disease.type.name })
            table.remove(self.diseases, i)
            return
        end
    end
end

function Animal:addDisease(type, isCarrier, genes)
    table.insert(self.diseases, Disease.new(type, isCarrier, genes))

    self:addMessage("DISEASE_CONTRACTED", { type.name })
end

function Animal:getDisease(title)
    for _, disease in pairs(self.diseases) do
        if disease.type.title == title then return disease end
    end

    return nil
end

function Animal:addMessage(id, args)
    if self.clusterSystem == nil or self.clusterSystem.owner == nil or self.clusterSystem.owner.addRLMessage == nil then return end

    self.clusterSystem.owner:addRLMessage(id, self:getIdentifiers(), args)
end

function Animal:getIdentifiers()
    return string.format("%s %s %s", RLConstants.AREA_CODES[self.birthday.country].code, self.farmId, self.uniqueId)
end

function Animal:compareIdentifiers(identifiers)
    return self:getIdentifiers() == identifiers
end

function Animal:setRecentlyBoughtByAI(value)
    self.recentlyBoughtByAI = value
end

function Animal:getRecentlyBoughtByAI()
    return self.recentlyBoughtByAI or false
end

function Animal:getMarked(key)
    if key == nil then
        for _, mark in pairs(self.marks) do
            if mark.active then return true end
        end

        return false
    end

    return (self.marks[key].active) or false
end

--- Set or clear marks on this animal. key=nil targets all marks (clears herdsman marks too).
--- @param key string|nil Mark key ("PLAYER", "AI_MANAGER_SELL", etc.) or nil for all
--- @param active boolean
function Animal:setMarked(key, active)
    if key == nil then
        for markKey, mark in pairs(self.marks) do self.marks[markKey].active = active end
        Log:trace("setMarked: all marks set to %s for %s", tostring(active), tostring(self.uniqueId))
    else
        self.marks[key].active = active
        Log:trace("setMarked: key=%s active=%s for %s", key, tostring(active), tostring(self.uniqueId))
    end

    self:updateVisualMarker()
end

function Animal:getDefaultMarks()
    return table.clone(RLConstants.MARKS, 3)
end

function Animal:getHighestPriorityMark()
    local highest

    for key, mark in pairs(self.marks) do
        if not mark.active then continue end

        if highest == nil or highest.priority > mark.priority then highest = { ["key"] = key, ["priority"] = mark
            .priority } end
    end

    return highest.key
end

-- Insemination delegates -> AnimalReproduction module
function Animal:getCanBeInseminatedByAnimal(animal) return AnimalReproduction.getCanBeInseminatedByAnimal(self, animal) end

function Animal:setInsemination(animal) AnimalReproduction.setInsemination(self, animal) end

--- Whether this animal currently carries an ACTIVE disease record. A record is
--- active iff it is neither cured (immunity countdown running) nor a genetic
--- carrier - both read as healthy on every list surface and in the
--- hasAnyDisease filter field, while the record itself stays attached (a cured
--- record blocks re-infection; a carrier record marks the carried gene).
--- Strict boolean contract: never nil (the filter evaluator type-gates and
--- would silently match nothing) and never raises on a nil diseases table.
--- Deliberately unlogged: the three list sort comparators call this per
--- comparison, so a per-call trace would dominate the log at TRACE.
---@return boolean hasActiveDisease true iff diseases are enabled AND at least one attached
---        record is neither cured nor a carrier; false whenever the manager is absent,
---        diseases are disabled, or the animal carries no diseases table
function Animal:getHasAnyDisease()
    if g_diseaseManager == nil or not g_diseaseManager.diseasesEnabled or self.diseases == nil then
        return false
    end

    for _, disease in ipairs(self.diseases) do
        if not disease.cured and not disease.isCarrier then
            return true
        end
    end

    return false
end

--- Resolve the three display flags the animal-list cards render as status icons.
--- Gating mirrors getHasAnyDisease exactly: an absent manager, disabled diseases
--- or an absent diseases table all yield three falses, so turning diseases off
--- clears the icons the same way it clears every other disease surface.
---
--- "Untreated" and "treated" describe ACTIVE records only (neither cured nor a
--- carrier), so a cured record contributes nothing whatever its beingTreated
--- flag says. Carrier is keyed on isCarrier alone, cured or not, because it
--- marks a lifelong carried gene rather than a record state.
---
--- WITHIN one record the three are exclusive - a carrier record can never also
--- report untreated or treated. ACROSS records they are independent, which is
--- how an animal carrying a gene and running an active infection lights two
--- icons. A degenerate record (no fields set) reports untreated, matching what
--- getHasAnyDisease already does with the same input.
---
--- Iterates with ipairs to match the list predicate: a sparse diseases table has
--- to be read the same way by both, or the icons and the section grouping would
--- disagree about the same animal.
---@return boolean untreated true iff at least one active record is not being treated
---@return boolean treated true iff at least one active record is being treated
---@return boolean carrier true iff at least one record carries the gene
function Animal:getDiseaseStatusFlags()
    if g_diseaseManager == nil or not g_diseaseManager.diseasesEnabled or self.diseases == nil then
        return false, false, false
    end

    local untreated, treated, carrier = false, false, false

    for _, disease in ipairs(self.diseases) do
        if disease.isCarrier then
            carrier = true
        elseif not disease.cured then
            if disease.beingTreated then
                treated = true
            else
                untreated = true
            end
        end
    end

    Log:trace("getDiseaseStatusFlags: uniqueId=%s untreated=%s treated=%s carrier=%s",
        tostring(self.uniqueId), tostring(untreated), tostring(treated), tostring(carrier))

    return untreated, treated, carrier
end

function Animal:createVisual(husbandryId, animalId)
    self.visualAnimal = VisualAnimal.new(self, husbandryId, animalId)
    self.visualAnimal:load()
end

function Animal:deleteVisual()
    if self.visualAnimal ~= nil then self.visualAnimal:delete() end

    self.visualAnimal = nil
end

function Animal:setVisualEarTagColours(leftTag, leftText, rightTag, rightText)
    if self.visualAnimal ~= nil then self.visualAnimal:setEarTagColours(leftTag, leftText, rightTag, rightText) end
end

function Animal:updateVisualRightEarTag()
    if self.visualAnimal ~= nil then self.visualAnimal:setRightEarTag() end
end

function Animal:updateVisualLeftEarTag()
    if self.visualAnimal ~= nil then self.visualAnimal:setLeftEarTag() end
end

function Animal:updateVisualMonitor()
    if self.visualAnimal ~= nil then self.visualAnimal:setMonitor() end
end

function Animal:updateVisualMarker()
    if self.visualAnimal ~= nil then self.visualAnimal:setMarker() end
end
