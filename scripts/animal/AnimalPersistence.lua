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
---
--- THE DISEASE ARRAY IS REBUILT IN DOCUMENT ORDER, and that is a contract rather than an
--- incidental property of `iterate`. The save half writes each record at an INDEXED key taken
--- from its position in the array, so document order IS array order, and every peer folds the
--- same records in the same sequence. Rebuilding it from a title-keyed map, a set, per-state
--- buckets or a re-sorted query loses that with no raise, no red assert and no log line.
---
--- @return table|nil animal New Animal instance, or nil if subType not found
--- @return number droppedLegacyDiseaseRecords How many disease records THIS animal lost to the
---         shape discriminator. Zero on every save this build wrote. Exposed because a suite
---         has no other way to assert it - the emission is a WARNING, and neither a logger spy
---         nor the error-line pin can see one.
---
---         SCOPED TO THIS ANIMAL'S OWN RECORDS. An unborn child is loaded by a recursive call
---         and is a different animal: it counts, warns and reports for itself, and its total is
---         deliberately NOT folded in here, because a number documented as one animal's loss
---         must not silently include another's. The consequence to know when reading a log: a
---         pregnant mother's returned figure does not cover her children, and a child's own
---         warning renders `farmId=nil uniqueId=nil`, because the pregnancy key it loads from
---         carries neither - a pre-existing property of that path, inherited rather than added.
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
        -- Both values, so the second return is a number on EVERY path the doc block declares it
        -- on. A bare `return nil` here hands the caller nil in that slot, and the first caller
        -- to write `total = total + dropped` would get `number + nil` on exactly the drop path -
        -- the one that is hardest to reach in a test and easiest to miss in review.
        return nil, 0
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

    -- Counts ONE drop reason: a record written in the pre-switchover shape. The other two
    -- skips below keep their own per-record warnings and are not counted here, because this
    -- number is an ORACLE - a suite asserts it, a logger spy is banned portfolio-wide, and a
    -- WARNING moves neither the error pin nor a sequence pin - so folding three reasons into
    -- one figure would make it unassertable for any of them.
    local droppedLegacyDiseaseRecords = 0

    -- Resolved ONCE: constant for the animal, where the loop below is per-record. A nil
    -- SKIPS the type check rather than failing closed, which would drop every record on
    -- every animal - so every step here takes NO default and yields nil instead.
    --
    -- Re-read rather than reusing `subTypeIndex`: that one defaults to COW_HOLSTEIN, and
    -- inheriting the default would type an unlabelled animal COW and drop a sheep's or a
    -- pig's records under a rule that is meant to skip when it cannot tell.
    local animalTypeName
    local typedSubType = isLegacy and subTypeIndex
        or g_currentMission.animalSystem:getSubTypeIndexByName(xmlFile:getString(key .. "#subType"))
    local animalSubType = typedSubType ~= nil
        and g_currentMission.animalSystem:getSubTypeByIndex(typedSubType) or nil
    local typeIndexToName = g_currentMission.animalSystem.typeIndexToName

    if animalSubType ~= nil and typeIndexToName ~= nil then
        animalTypeName = typeIndexToName[animalSubType.typeIndex]
    end

    if animalTypeName == nil then
        -- Not a WARNING: the type check is designed to skip here. But a permanently broken
        -- resolution and "nothing to drop" are otherwise indistinguishable in a log.
        Log:debug("loadAnimal: no animal type resolved, the record-adherence type check is "
            .. "skipped for this animal (farmId=%s uniqueId=%s)", tostring(farmId), tostring(id))
    end

    -- SEPARATE from the legacy counter above, never folded in: that one is an oracle scoped
    -- to a single reason, and a combined figure would be unassertable for either.
    local droppedNonAdherent = {}
    local droppedNonAdherentTotal = 0

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

        -- THE SHAPE DISCRIMINATOR, and it must sit exactly here - after the title resolves and
        -- before anything is constructed. Both shapes carry a title, and every attribute read
        -- in the codec supplies a default, so without this an old record is accepted with
        -- default values for fields it never had: a record at EXPOSED with zeroed counters
        -- that no guard refuses and nothing can ever advance. Silent, permanent, and
        -- indistinguishable from a fresh infection.
        --
        -- Absent reads as 1 - the legacy shape wrote no version - so the default is what
        -- actually does the work here, not the comparison.
        if xmlFile:getInt(diseaseKey .. "#version", 1) < Disease.RECORD_VERSION then

            droppedLegacyDiseaseRecords = droppedLegacyDiseaseRecords + 1

            return

        end

        local disease = Disease.new(diseaseType)

        disease:loadFromXMLFile(xmlFile, diseaseKey)

        -- Read at CALL time: main.lua sources this file well before the disease modules, so a
        -- file-scope alias would be nil in-game and populated headless.
        local adherent, reason = RLDiseaseRecord.isAdherent(disease, diseaseType, animalTypeName)

        if not adherent then

            -- Never index the tally with the raw return: a renamed reason constant makes
            -- `reason` nil, and `t[nil] = v` RAISES inside an iterate callback on the load
            -- path, turning a designed drop into a failed animal load.
            local reasonKey = reason or "UNSPECIFIED"

            droppedNonAdherent[reasonKey] = (droppedNonAdherent[reasonKey] or 0) + 1
            droppedNonAdherentTotal = droppedNonAdherentTotal + 1

            Log:trace("loadAnimal: dropping a disease record, reason=%s (title=%s state=%s farmId=%s uniqueId=%s)",
                tostring(reason), tostring(diseaseType.title), tostring(disease.state),
                tostring(farmId), tostring(id))

            return

        end

        table.insert(diseases, disease)

    end)

    -- ONE line per animal, for the reason the legacy warning above carries one: a herd that
    -- meets a re-authored definition file drops together. INFO, not WARNING - this is the rule
    -- working as designed, and nothing asks the player to act.
    if droppedNonAdherentTotal > 0 then

        -- Sorted, so the rendered order does not depend on hash order and cannot differ
        -- between the two runners.
        -- The RAW keys, never a `tostring` copy: re-keying the lookup would read nil for
        -- any non-string key and hand that nil straight to `%d`.
        local reasons = {}

        for reason in pairs(droppedNonAdherent) do reasons[#reasons + 1] = reason end

        table.sort(reasons, function(a, b) return tostring(a) < tostring(b) end)

        local rendered = {}

        for i = 1, #reasons do
            rendered[i] = string.format("%s=%d", tostring(reasons[i]), droppedNonAdherent[reasons[i]])
        end

        Log:info("loadAnimal: dropped %s disease record(s) that no longer fit their definition, %s (farmId=%s uniqueId=%s)",
            tostring(droppedNonAdherentTotal), table.concat(rendered, " "),
            tostring(farmId), tostring(id))

    end

    -- ONE line per animal, never one per record: a herd carrying the old shape is the normal
    -- case on the first load of this build, so per-record lines would bury the load log in
    -- exactly the situation a reader most needs to follow it.
    if droppedLegacyDiseaseRecords > 0 then
        Log:warning("loadAnimal: dropped %s pre-switchover disease record(s), reason=record shape predates the current one and carries no state to migrate (farmId=%s uniqueId=%s)",
            tostring(droppedLegacyDiseaseRecords), tostring(farmId), tostring(id))
    end


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

                local month, year = RLCalendar.getMonthAndYear(g_currentMission.environment)

                Log:trace("AnimalPersistence.loadFromXMLFile: pregnancy from reproduction=%s at %s/%s"
                    .. " (farmId=%s uniqueId=%s)",
                    tostring(reproduction), tostring(month), tostring(year), tostring(farmId), tostring(id))

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

    return animal, droppedLegacyDiseaseRecords

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

    -- INDEXED walk, never `pairs`, and this is the site that MATERIALISES the positional
    -- contract the loader and both stream halves are written against. The element index is
    -- derived from the loop variable, so with `pairs` the document's order was whatever the
    -- iterator happened to hand back - order-preserving for a dense array under this VM, and
    -- not a guarantee. Writing the index from a counted loop makes the contract true by
    -- construction instead of by luck, and matches the two stream write halves exactly.
    for i = 1, #animal.diseases do

        animal.diseases[i]:saveToXMLFile(xmlFile, key .. ".diseases.disease(" .. (i - 1) .. ")")

    end

end
