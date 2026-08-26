--[[
    AnimalPersistence.lua
    XML save/load logic extracted from Animal.lua.

    Provides loadFromXMLFile (static) and saveToXMLFile (instance-to-module)
    for XML persistence. Animal.lua retains thin delegates that route to
    this module.

    Sourced BEFORE RealisticLivestock_Animal.lua (same pattern as AnimalHorse,
    AnimalReproduction, AnimalHealth).

    NOTE: Serialization (writeStream/readStream), constructor (Animal.new),
    clone(), and all state fields remain in Animal.lua. writeStream/readStream
    is MP protocol and version-locked (serialization scope).
]]

AnimalPersistence = {}

local Log = RmLogging.getLogger("RLRM")


-- =============================================================================
-- XML PERSISTENCE FUNCTIONS (delegated from Animal)
-- =============================================================================

--- Load an animal from XML save data.
--- Static function - creates and returns a new Animal from saved XML fields.
--- Handles both legacy (int subType) and current (string subType) formats.
--- Recursively loads pregnancy children via AnimalPersistence.loadFromXMLFile.
--- @param xmlFile table XMLFile object
--- @param key string XML path key
--- @param clusterSystem table|nil Cluster system (nil for pregnancy children)
--- @param isLegacy boolean Whether this is a legacy-format save
--- @return table|nil animal New Animal instance, or nil if subType not found
function AnimalPersistence.loadFromXMLFile(xmlFile, key, clusterSystem, isLegacy)

    local subTypeIndex

    if isLegacy then
        subTypeIndex = xmlFile:getInt(key .. "#subType", 3)
        local st = g_currentMission.animalSystem:getSubTypeByIndex(subTypeIndex)
        Log:debug("loadAnimal: legacy int subType=%d -> resolved name=%s", subTypeIndex, st and st.name or "nil")
    else
        local subTypeName = xmlFile:getString(key .. "#subType", "COW_HOLSTEIN")
        subTypeIndex = g_currentMission.animalSystem:getSubTypeIndexByName(subTypeName)
        Log:debug("loadAnimal: saved subType='%s' -> resolved index=%s", subTypeName, tostring(subTypeIndex))
    end

    if subTypeIndex == nil then
        if isLegacy then
            Log:warning("loadAnimal: legacy subTypeIndex %s not found in registry - animal will be dropped", tostring(subTypeIndex))
        else
            local rawName = xmlFile:getString(key .. "#subType", "?")
            Log:warning("loadAnimal: subType '%s' not found in registry - animal will be dropped (key=%s)", rawName, key)
        end
        return nil
    end

    local age = xmlFile:getInt(key .. "#age")
    local health = xmlFile:getFloat(key .. "#health")
    local monthsSinceLastBirth = xmlFile:getInt(key .. "#monthsSinceLastBirth")
    local gender = xmlFile:getString(key .. "#gender")
    local reproduction = xmlFile:getFloat(key .. "#reproduction", 0)
    local isParent = xmlFile:getBool(key .. "#isParent")
    local isPregnant = xmlFile:getBool(key .. "#isPregnant")
    local isLactating = xmlFile:getBool(key .. "#isLactating")
    local recentlyBoughtByAI = xmlFile:getBool(key .. "#recentlyBoughtByAI", false)
    local id = xmlFile:getString(key .. "#id", nil)
    local farmId = xmlFile:getString(key .. "#farmId", nil)
    local motherId = xmlFile:getString(key .. "#motherId", nil)
    local fatherId = xmlFile:getString(key .. "#fatherId", nil)
    local weight = xmlFile:getFloat(key .. "#weight", nil)
    local variation = xmlFile:getInt(key .. "#variation", nil)

    local marks = Animal.getDefaultMarks()

    xmlFile:iterate(key .. ".marks.mark", function(_, markKey)

        local mark = xmlFile:getString(markKey .. "#key", "PLAYER")
        marks[mark].active = xmlFile:getBool(markKey .. "#active", false)

    end)

    if subTypeIndex == nil then
        local subTypeName = xmlFile:getString(key .. "#subType", nil)
        if subTypeName == nil then return nil end
        subTypeIndex = g_currentMission.animalSystem:getSubTypeIndexByName(subTypeName)
    end


    local name = xmlFile:getString(key .. "#name", nil)
    local dirt = xmlFile:getFloat(key .. "#dirt", nil)
    local fitness = xmlFile:getFloat(key .. "#fitness", nil)
    local riding = xmlFile:getFloat(key .. "#riding", nil)

    local pos = nil

    local children = {}

    xmlFile:iterate(key .. ".children.child", function (_, childrenKey)

        local childUniqueId = xmlFile:getString(childrenKey .. "#uniqueId", nil)
        local childFarmId = xmlFile:getString(childrenKey .. "#farmId", nil)
        local child = {
            farmId = childFarmId,
            uniqueId = childUniqueId
        }
        table.insert(children, child)

    end)


    local pregnancy

    if xmlFile:hasProperty(key .. ".pregnancy") then

        pregnancy = { ["pregnancies"] = {} }
        local pregnancyKey = key .. ".pregnancy"

        pregnancy.expected = {
            ["day"] = xmlFile:getInt(pregnancyKey .. "#day", 1),
            ["month"] = xmlFile:getInt(pregnancyKey .. "#month", 1),
            ["year"] = xmlFile:getInt(pregnancyKey .. "#year", 1)
        }

        pregnancy.duration = xmlFile:getInt(pregnancyKey .. "#duration", 1)

        xmlFile:iterate(pregnancyKey .. ".pregnancies.pregnancy", function (_, pregnanciesKey)

            local child = AnimalPersistence.loadFromXMLFile(xmlFile, pregnanciesKey, nil, isLegacy)

            table.insert(pregnancy.pregnancies, child)

        end)

    end


    local birthdayDay = xmlFile:getInt(key .. ".birthday#day", nil)
    local birthdayMonth = xmlFile:getInt(key .. ".birthday#month", nil)
    local birthdayYear = xmlFile:getInt(key .. ".birthday#year", nil)
    local birthdayCountry = xmlFile:getInt(key .. ".birthday#country", nil)
    local lastAgeMonth = xmlFile:getInt(key .. ".birthday#lastAgeMonth", 0)


    local birthday

    if birthdayDay ~= nil and birthdayMonth ~= nil and birthdayYear ~= nil and birthdayCountry ~= nil then
        birthday = {
            ["day"] = birthdayDay,
            ["month"] = birthdayMonth,
            ["year"] = birthdayYear,
            ["country"] = birthdayCountry,
            ["lastAgeMonth"] = lastAgeMonth
        }
    end




    local impregnatedBy

    if xmlFile:hasProperty(key .. ".impregnatedBy") then

        impregnatedBy = {
            ["uniqueId"] = xmlFile:getString(key .. ".impregnatedBy#uniqueId", nil),
            ["metabolism"] = xmlFile:getFloat(key .. ".impregnatedBy#metabolism", nil),
            ["productivity"] = xmlFile:getFloat(key .. ".impregnatedBy#productivity", nil),
            ["quality"] = xmlFile:getFloat(key .. ".impregnatedBy#quality", nil),
            ["health"] = xmlFile:getFloat(key .. ".impregnatedBy#health", nil),
            ["fertility"] = xmlFile:getFloat(key .. ".impregnatedBy#fertility", nil)
        }

    end


    local genetics

    if xmlFile:hasProperty(key .. ".genetics") then

        genetics = {
            ["metabolism"] = xmlFile:getFloat(key .. ".genetics#metabolism", nil),
            ["productivity"] = xmlFile:getFloat(key .. ".genetics#productivity", nil),
            ["quality"] = xmlFile:getFloat(key .. ".genetics#quality", nil),
            ["health"] = xmlFile:getFloat(key .. ".genetics#health", nil),
            ["fertility"] = xmlFile:getFloat(key .. ".genetics#fertility", nil)
        }

    end


    local monitor = { ["active"] = xmlFile:getBool(key .. ".monitor#active", false), ["removed"] = xmlFile:getBool(key .. ".monitor#removed", false) }

    local isCastrated = xmlFile:getBool(key .. "#isCastrated", false)

    -- nil when absent (backward compatible, treated as sellable); false when explicitly saved
    local canBeSold = xmlFile:getBool(key .. "#canBeSold")

    local diseases = {}

    -- Every skip below is a BARE return, never `return false`. Returning exactly false from an
    -- iterate callback ends the walk, so it would drop every REMAINING disease on this animal
    -- rather than just the one that could not be resolved. Returning nothing continues it.
    xmlFile:iterate(key .. ".diseases.disease", function (_, diseaseKey)

        if g_diseaseManager == nil then
            Log:warning("loadAnimal: dropping a disease record, reason=no disease manager (farmId=%s uniqueId=%s)",
                tostring(farmId), tostring(id))
            return
        end

        -- tostring on the way IN, not inside the renderer: an absent field would otherwise not be
        -- a key at all, so the warning would silently omit it rather than render it as nil - and a
        -- grep for `uniqueId=` would under-count exactly the records that lost their identity. An
        -- unborn child loaded through the pregnancy recursion is the reachable case: it reads its
        -- id and farm off a key that carries neither.
        local diseaseType = g_diseaseManager:resolveRecordType(xmlFile:getString(diseaseKey .. "#title"),
            { farmId = tostring(farmId), uniqueId = tostring(id), context = "savegame" })

        if diseaseType == nil then return end

        local disease = Disease.new(diseaseType)

        disease:loadFromXMLFile(xmlFile, diseaseKey)

        table.insert(diseases, disease)

    end)


    local insemination

    if xmlFile:hasProperty(key .. ".insemination") then

        insemination = {
            ["country"] = xmlFile:getInt(key .. ".insemination#country"),
            ["farmId"] = xmlFile:getString(key .. ".insemination#farmId"),
            ["uniqueId"] = xmlFile:getString(key .. ".insemination#uniqueId"),
            ["name"] = xmlFile:getString(key .. ".insemination#name"),
            ["subTypeIndex"] = xmlFile:getInt(key .. ".insemination#subTypeIndex"),
            ["genetics"] = {},
            ["success"] = xmlFile:getFloat(key .. ".insemination#success")
        }

        insemination.genetics.metabolism = xmlFile:getFloat(key .. ".insemination.genetics#metabolism")
        insemination.genetics.health = xmlFile:getFloat(key .. ".insemination.genetics#health")
        insemination.genetics.fertility = xmlFile:getFloat(key .. ".insemination.genetics#fertility")
        insemination.genetics.quality = xmlFile:getFloat(key .. ".insemination.genetics#quality")
        insemination.genetics.productivity = xmlFile:getFloat(key .. ".insemination.genetics#productivity")

    end



    local animal = Animal.new({
        age = age, health = health, monthsSinceLastBirth = monthsSinceLastBirth,
        gender = gender, subTypeIndex = subTypeIndex, reproduction = reproduction,
        isParent = isParent, isPregnant = isPregnant, isLactating = isLactating,
        clusterSystem = clusterSystem, uniqueId = id, motherId = motherId,
        fatherId = fatherId, pos = pos, name = name, dirt = dirt,
        fitness = fitness, riding = riding, farmId = farmId, weight = weight,
        genetics = genetics, impregnatedBy = impregnatedBy, variation = variation,
        children = children, monitor = monitor, isCastrated = isCastrated,
        diseases = diseases, recentlyBoughtByAI = recentlyBoughtByAI,
        marks = marks, insemination = insemination,
        canBeSold = canBeSold
    })

    animal:setBirthday(birthday)

    if pregnancy ~= nil and #pregnancy.pregnancies > 0 then
        animal.pregnancy = pregnancy
    elseif reproduction > 0 then

        if animal.clusterSystem ~= nil then

            local childNum = animal:generateRandomOffspring()

            if childNum > 0 then

                local month = g_currentMission.environment.currentPeriod + 2
                if month > 12 then month = month - 12 end
                local year = g_currentMission.environment.currentYear

                animal:createPregnancy(childNum, month, year)

            else

                animal.reproduction = 0
                animal.isPregnant = false

            end

        else

            animal.reproduction = 0
            animal.isPregnant = false

        end

    end

    return animal

end


--- Save animal data to XML file.
--- Writes all animal fields including genetics, pregnancy, diseases,
--- insemination, marks, birthday, and monitor state.
--- @param animal table Animal instance
--- @param xmlFile table XMLFile object
--- @param key string XML path key
function AnimalPersistence.saveToXMLFile(animal, xmlFile, key)

    xmlFile:setInt(key .. "#age", animal.age)
    xmlFile:setFloat(key .. "#health", animal.health)
    xmlFile:setInt(key .. "#monthsSinceLastBirth", animal.monthsSinceLastBirth)
    xmlFile:setInt(key .. "#numAnimals", 1)
    xmlFile:setString(key .. "#gender", animal.gender)
    xmlFile:setString(key .. "#subType", animal.subType)
    xmlFile:setFloat(key .. "#reproduction", animal.reproduction)
    xmlFile:setBool(key .. "#isParent", animal.isParent)
    xmlFile:setBool(key .. "#isPregnant", animal.isPregnant)
    xmlFile:setBool(key .. "#isLactating", animal.isLactating)
    xmlFile:setBool(key .. "#recentlyBoughtByAI", animal.recentlyBoughtByAI or false)
    xmlFile:setString(key .. "#id", animal.uniqueId)
    if animal.variation ~= nil then xmlFile:setInt(key .. "#variation", animal.variation) end
    xmlFile:setString(key .. "#farmId", animal.farmId)
    xmlFile:setString(key .. "#motherId", animal.motherId)
    xmlFile:setString(key .. "#fatherId", animal.fatherId)
    xmlFile:setFloat(key .. "#weight", animal.weight)

    local markI = 0

    for _, mark in pairs(animal.marks) do

        local markKey = string.format("%s.marks.mark(%s)", key, markI)

        xmlFile:setString(markKey .. "#key", mark.key)
        xmlFile:setBool(markKey .. "#active", mark.active)

        markI = markI + 1

    end

    if animal.name ~= nil and animal.name ~= "" then xmlFile:setString(key .. "#name", animal.name) end

    if animal:isHorse() then
        AnimalHorse.saveHorseFields(animal, xmlFile, key)
    end

    xmlFile:setSortedTable(key .. ".children.child", animal.children, function (index, child)
        xmlFile:setString(index .. "#uniqueId", child.uniqueId)
        xmlFile:setString(index .. "#farmId", child.farmId)
    end)

    if animal.pregnancy ~= nil then

        local pregnancy = animal.pregnancy
        local pregnancyKey = key .. ".pregnancy"

        xmlFile:setInt(pregnancyKey .. "#day", pregnancy.expected.day)
        xmlFile:setInt(pregnancyKey .. "#month", pregnancy.expected.month)
        xmlFile:setInt(pregnancyKey .. "#year", pregnancy.expected.year)
        xmlFile:setInt(pregnancyKey .. "#duration", pregnancy.duration)

        xmlFile:setSortedTable(pregnancyKey .. ".pregnancies.pregnancy", pregnancy.pregnancies, function (index, child)

            xmlFile:setFloat(index .. "#health", child.health)
            xmlFile:setString(index .. "#gender", child.gender)
            xmlFile:setString(index .. "#subType", child.subType)
            xmlFile:setString(index .. "#motherId", child.motherId)
            xmlFile:setString(index .. "#fatherId", child.fatherId)

            local pregnancyGenetics = child.genetics

            if pregnancyGenetics ~= nil then

                xmlFile:setFloat(index .. ".genetics#metabolism", pregnancyGenetics.metabolism)
                xmlFile:setFloat(index .. ".genetics#quality", pregnancyGenetics.quality)
                xmlFile:setFloat(index .. ".genetics#health", pregnancyGenetics.health)
                xmlFile:setFloat(index .. ".genetics#fertility", pregnancyGenetics.fertility)
                if pregnancyGenetics.productivity ~= nil then xmlFile:setFloat(index .. ".genetics#productivity", pregnancyGenetics.productivity) end

            end

            xmlFile:setSortedTable(index .. ".diseases.disease", child.diseases, function (diseaseKey, disease)
                disease:saveToXMLFile(xmlFile, diseaseKey)
            end)

        end)

    end

    if animal.impregnatedBy ~= nil then

        xmlFile:setString(key .. ".impregnatedBy#uniqueId", animal.impregnatedBy.uniqueId)
        xmlFile:setFloat(key .. ".impregnatedBy#metabolism", animal.impregnatedBy.metabolism)
        xmlFile:setFloat(key .. ".impregnatedBy#quality", animal.impregnatedBy.quality)
        xmlFile:setFloat(key .. ".impregnatedBy#health", animal.impregnatedBy.health)
        xmlFile:setFloat(key .. ".impregnatedBy#fertility", animal.impregnatedBy.fertility)
        if animal.impregnatedBy.productivity ~= nil then xmlFile:setFloat(key .. ".impregnatedBy#productivity", animal.impregnatedBy.productivity) end
    end

    if animal.genetics ~= nil then

        xmlFile:setFloat(key .. ".genetics#metabolism", animal.genetics.metabolism)
        xmlFile:setFloat(key .. ".genetics#quality", animal.genetics.quality)
        xmlFile:setFloat(key .. ".genetics#health", animal.genetics.health)
        xmlFile:setFloat(key .. ".genetics#fertility", animal.genetics.fertility)
        if animal.genetics.productivity ~= nil then xmlFile:setFloat(key .. ".genetics#productivity", animal.genetics.productivity) end
    end

    if animal.birthday ~= nil then

        xmlFile:setInt(key .. ".birthday#day", animal.birthday.day)
        xmlFile:setInt(key .. ".birthday#month", animal.birthday.month)
        xmlFile:setInt(key .. ".birthday#year", animal.birthday.year)
        xmlFile:setInt(key .. ".birthday#country", animal.birthday.country)
        xmlFile:setInt(key .. ".birthday#lastAgeMonth", animal.birthday.lastAgeMonth)

    end

    if animal.insemination ~= nil then

        local insemination = animal.insemination

        xmlFile:setInt(key .. ".insemination#country", insemination.country)
        xmlFile:setString(key .. ".insemination#farmId", insemination.farmId)
        xmlFile:setString(key .. ".insemination#uniqueId", insemination.uniqueId)
        xmlFile:setString(key .. ".insemination#name", insemination.name)
        xmlFile:setInt(key .. ".insemination#subTypeIndex", insemination.subTypeIndex)
        xmlFile:setFloat(key .. ".insemination#success", insemination.success)
        xmlFile:setFloat(key .. ".insemination.genetics#metabolism", insemination.genetics.metabolism)
        xmlFile:setFloat(key .. ".insemination.genetics#quality", insemination.genetics.quality)
        xmlFile:setFloat(key .. ".insemination.genetics#health", insemination.genetics.health)
        xmlFile:setFloat(key .. ".insemination.genetics#fertility", insemination.genetics.fertility)
        if insemination.genetics.productivity ~= nil then xmlFile:setFloat(key .. ".insemination.genetics#productivity", insemination.genetics.productivity) end

    end

    xmlFile:setBool(key .. ".monitor#active", animal.monitor.active)
    xmlFile:setBool(key .. ".monitor#removed", animal.monitor.removed)

    if animal.isCastrated then xmlFile:setBool(key .. "#isCastrated", true) end
    if animal.canBeSold == false then xmlFile:setBool(key .. "#canBeSold", false) end

    for i, disease in pairs(animal.diseases) do

        disease:saveToXMLFile(xmlFile, key .. ".diseases.disease(" .. (i - 1) .. ")")

    end

end
