RealisticLivestock_AnimalClusterHusbandry = {}
RealisticLivestock_AnimalClusterHusbandry.MAX_HUSBANDRIES = 50

local modDirectory = g_currentModDirectory



function RealisticLivestock_AnimalClusterHusbandry:create(superFunc, xmlFilename, navigationNode, raycastDistance, collisionMask)

    if self.husbandryId ~= nil then
        self:deleteHusbandry()
    end

    self.navigationNode = navigationNode
    self.collisionMask = collisionMask
    self.xmlFilename = xmlFilename
    self.raycastDistance = raycastDistance
    self.visualAnimalCount = 0

    local animalPositioning = CollisionMask.ANIMAL_POSITIONING

    self.husbandryIds = {}
    self.husbandryIdsToVisualAnimalCount = {}

    for i=1, 8 do
        local husbandry = createAnimalHusbandry(self.animalTypeName, navigationNode, xmlFilename, raycastDistance, animalPositioning, collisionMask, AudioGroup.ENVIRONMENT)

        if husbandry == 0 then
            Log:error("Failed to create animal husbandry for %q with navigation mesh %q and config %q", self.animalTypeName, I3DUtil.getNodePath(navigationNode), xmlFilename)
            break
        end

        table.insert(self.husbandryIds, husbandry)
        self.husbandryIdsToVisualAnimalCount[husbandry] = 0
    end

    self.husbandryId = self.husbandryIds[1]
    self.visualUpdatePending = true
    self:onIndoorStateChanged()

    return self.husbandryId

end

AnimalClusterHusbandry.create = Utils.overwrittenFunction(AnimalClusterHusbandry.create, RealisticLivestock_AnimalClusterHusbandry.create)



function RealisticLivestock_AnimalClusterHusbandry:deleteHusbandry(superFunc)
    if self.husbandryIds ~= nil then

        if self.animalIdToCluster == nil then self.animalIdToCluster = {} end

        for husbandryId, animalIds in pairs(self.animalIdToCluster) do

            for animalId, animal in pairs(animalIds) do

                removeHusbandryAnimal(self.husbandryIds[husbandryId], animalId)
                animal:deleteVisual()

            end

        end

        g_soundManager:removeIndoorStateChangedListener(self)

        for _, id in pairs(self.husbandryIds) do
            delete(id)
        end

        self.husbandryIds = nil
        self.husbandryId = nil
        self.husbandryIdsToVisualAnimalCount = nil
        self.animalIdToCluster = nil
    end
end

AnimalClusterHusbandry.deleteHusbandry = Utils.overwrittenFunction(AnimalClusterHusbandry.deleteHusbandry, RealisticLivestock_AnimalClusterHusbandry.deleteHusbandry)


--- Rebuild the pen's visual animals; a horse back from riding is placed at the spot it was handed.
--- @param superFunc function the overwritten base method, never called
--- @param removeAll boolean|nil remove every visual before re-adding
function RealisticLivestock_AnimalClusterHusbandry:updateVisuals(superFunc, removeAll)

    -- Phase timing: localise visual-update cost
    -- (staleRemove / setup / mainLoop / shader). Both early-return paths
    -- (husbandryNotReady, cap reached) emit a one-line DEBUG with elapsed ms.
    local tStart = getTimeSec()
    local tPhase = tStart
    Log:trace(">>> AnimalClusterHusbandry:updateVisuals(removeAll=%s) husbandryId=%s", tostring(removeAll),
        tostring(self.husbandryId))
    local function phaseDoneMs()
        local now = getTimeSec()
        local ms = (now - tPhase) * 1000
        tPhase = now
        return ms
    end

    if self.husbandryId == nil or not isHusbandryReady(self.husbandryId) then
        self.visualUpdatePending = true
        Log:debug("AnimalClusterHusbandry:updateVisuals: deferred (husbandryNotReady) took %.2fms",
            (getTimeSec() - tStart) * 1000)
        Log:trace("<<< AnimalClusterHusbandry:updateVisuals (deferred) husbandryId=%s", tostring(self.husbandryId))
        return
    end


    local animals = self.nextUpdateClusters or {}
    local nextCount = #animals
    self.totalNumAnimalsPerVisualAnimalIndex = {}
    local newAnimalMapping = {}
    local newAnimalIdToVisualAnimalIndex = {}


    if self.animalIdToCluster == nil then self.animalIdToCluster = {} end

    for husbandryId, animalIds in pairs(self.animalIdToCluster) do
        if type(animalIds) ~= "table" then continue end

        local idsToRemove = {}

        for animalId, animal in pairs(animalIds) do

            if removeAll or animal == nil or animal.isSold or animal.isDead or animal.id == nil or animal.uniqueId == "1-1" or animal.uniqueId == "0-0" or animal.numAnimals <= 0 then

                Log:trace("AnimalClusterHusbandry:updateVisuals: stale visual removed husbandry=%s animalId=%s "
                    .. "farmId=%s uniqueId=%s removeAll=%s",
                    tostring(husbandryId), tostring(animalId), tostring(animal and animal.farmId),
                    tostring(animal and animal.uniqueId), tostring(removeAll))

                local husbandryEngineId = self.husbandryIds[husbandryId]
                local count = husbandryEngineId ~= nil and self.husbandryIdsToVisualAnimalCount[husbandryEngineId] or nil
                if count ~= nil then
                    self.husbandryIdsToVisualAnimalCount[husbandryEngineId] = math.max(count - 1, 0)
                    self.visualAnimalCount = math.max(self.visualAnimalCount - 1, 0)
                end
                removeHusbandryAnimal(self.husbandryIds[husbandryId], animalId)
                
                if animal ~= nil then
                    animal.id = nil
                    animal.idFull = nil
                    animal:deleteVisual()
                end

                table.insert(idsToRemove, animalId)

            end

        end

        for _, animalId in pairs(idsToRemove) do
            animalIds[animalId] = nil
        end

    end


    local tStaleRemoveMs = phaseDoneMs()

    if removeAll then self.animalIdToCluster = {} end
    if RealisticLivestock_AnimalClusterHusbandry.MAX_HUSBANDRIES <= 0 or self.visualAnimalCount == RealisticLivestock_AnimalClusterHusbandry.MAX_HUSBANDRIES then
        Log:debug("AnimalClusterHusbandry:updateVisuals: early-return (cap reached) staleRemove=%.2fms total=%.2fms",
            tStaleRemoveMs, (getTimeSec() - tStart) * 1000)
        Log:trace("<<< AnimalClusterHusbandry:updateVisuals (cap reached) husbandryId=%s", tostring(self.husbandryId))
        return
    end


    local areaCode = RealisticLivestock.getMapCountryCode()


    local i = 1
    local profile = Utils.getPerformanceClassId()
    local maxAnimalsPerHusbandry = (profile == GS_PROFILE_VERY_LOW and 8) or (profile == GS_PROFILE_LOW and 10) or (profile == GS_PROFILE_MEDIUM and 16) or (profile == GS_PROFILE_HIGH and 20) or (profile == GS_PROFILE_VERY_HIGH and 25) or (profile == GS_PROFILE_ULTRA and 25) or 8
 
    local animalSystem = g_currentMission.animalSystem
    local animalType = animalSystem.types[self.placeable:getAnimalTypeIndex()]

    local colours = animalType.colours or animalSystem.baseColours

    if colours.earTagLeft == nil or colours.earTagLeft_text == nil or colours.earTagRight == nil or colours.earTagRight_text == nil then colours = animalSystem.baseColours end
    
    local earTagLeftR, earTagLeftG, earTagLeftB = colours.earTagLeft[1], colours.earTagLeft[2], colours.earTagLeft[3]
    local earTagLeftTextR, earTagLeftTextG, earTagLeftTextB = colours.earTagLeft_text[1], colours.earTagLeft_text[2], colours.earTagLeft_text[3]
    local earTagRightR, earTagRightG, earTagRightB = colours.earTagRight[1], colours.earTagRight[2], colours.earTagRight[3]
    local earTagRightTextR, earTagRightTextG, earTagRightTextB = colours.earTagRight_text[1], colours.earTagRight_text[2], colours.earTagRight_text[3]

    local tSetupMs = phaseDoneMs()


    for _, animal in pairs(animals) do

        if self.visualAnimalCount >= RealisticLivestock_AnimalClusterHusbandry.MAX_HUSBANDRIES
            or i > #self.husbandryIds or animal.isDead or animal.numAnimals <= 0
            or animal.uniqueId == "1-1" or animal.uniqueId == "0-0"
            or (animal.id ~= nil and animal.idFull ~= nil and animal.id ~= "0-0"
                and animal.visualAnimalIndex == nil) then
            Log:trace("AnimalClusterHusbandry:updateVisuals: skipped farmId=%s uniqueId=%s visualCount=%d i=%d "
                .. "isDead=%s numAnimals=%s id=%s",
                tostring(animal.farmId), tostring(animal.uniqueId), self.visualAnimalCount, i,
                tostring(animal.isDead), tostring(animal.numAnimals), tostring(animal.id))
            continue
        end

        local husbandryAnimalCount = self.husbandryIdsToVisualAnimalCount[self.husbandryIds[i]] 

        local useTempId = false
        local tempHusbandryId
        local animalId = 0

        if animal.id ~= nil and animal.idFull ~= nil and animal.id ~= "0-0" and animal.visualAnimalIndex ~= nil then

            local age = animal:getAge()
            local newVisualAnimalIndex = self.animalSystem:getVisualAnimalIndexByAge(animal:getSubTypeIndex(), age == -1 and 0 or age)

            if newVisualAnimalIndex ~= animal.visualAnimalIndex then
                tempHusbandryId = tonumber(string.sub(animal.id, 1, 1))
                local tempAnimalId = tonumber(string.sub(animal.id, 3))

                Log:trace("AnimalClusterHusbandry:updateVisuals: age-band re-add farmId=%s uniqueId=%s "
                    .. "visual %s -> %s husbandry=%s",
                    tostring(animal.farmId), tostring(animal.uniqueId), tostring(animal.visualAnimalIndex),
                    tostring(newVisualAnimalIndex), tostring(tempHusbandryId))

                removeHusbandryAnimal(self.husbandryIds[tempHusbandryId], tempAnimalId)
                animal:deleteVisual()
                animalId = addHusbandryAnimal(self.husbandryIds[tempHusbandryId], newVisualAnimalIndex - 1)
                if animalId == 0 then
                    Log:trace("AnimalClusterHusbandry:updateVisuals: add refused husbandry=%s farmId=%s uniqueId=%s",
                        tostring(tempHusbandryId), tostring(animal.farmId), tostring(animal.uniqueId))
                end

                self.visualAnimalCount = math.max(self.visualAnimalCount - 1, 0)
                husbandryAnimalCount = husbandryAnimalCount - 1
                self.animalIdToCluster[tempHusbandryId][tempAnimalId] = nil

                if animalId == nil then

                    self.husbandryIdsToVisualAnimalCount[self.husbandryIds[i]] = self.husbandryIdsToVisualAnimalCount[self.husbandryIds[i]] - 1

                    Log:trace("AnimalClusterHusbandry:updateVisuals: age-band re-add returned nil, skipped "
                        .. "farmId=%s uniqueId=%s", tostring(animal.farmId), tostring(animal.uniqueId))
                    continue

                end
                
                useTempId = true
            else
                Log:trace("AnimalClusterHusbandry:updateVisuals: visual up to date farmId=%s uniqueId=%s",
                    tostring(animal.farmId), tostring(animal.uniqueId))
                continue
            end

        end


        local subTypeIndex = animal:getSubTypeIndex()
        local age = animal:getAge()

        age = age == -1 and 0 or age

        local visualAnimalIndex = self.animalSystem:getVisualAnimalIndexByAge(subTypeIndex, age)


        if animalId == 0 then

            -- Decided before any add: an age-band re-add that fell through here never reads the position.
            local isNewVisual = not useTempId

            while not useTempId and husbandryAnimalCount >= maxAnimalsPerHusbandry and i <= #self.husbandryIds and self.visualAnimalCount < RealisticLivestock_AnimalClusterHusbandry.MAX_HUSBANDRIES do
                i = i + 1
                if i > #self.husbandryIds then break end
                husbandryAnimalCount = self.husbandryIdsToVisualAnimalCount[self.husbandryIds[i]]
            end

            if i > #self.husbandryIds or (husbandryAnimalCount >= maxAnimalsPerHusbandry and not useTempId) then
                Log:trace("AnimalClusterHusbandry:updateVisuals: husbandries full at i=%d count=%s max=%d, "
                    .. "stopping before farmId=%s uniqueId=%s",
                    i, tostring(husbandryAnimalCount), maxAnimalsPerHusbandry, tostring(animal.farmId),
                    tostring(animal.uniqueId))
                break
            end

            local spawnPos, spawnRot
            if isNewVisual then
                local px, py, pz, prx, pry, prz = animal:getPendingSpawnWorldPosition()
                if px ~= nil then
                    -- The engine add takes its optional placement as vectors.
                    spawnPos = vector.create(px, py, pz)
                    spawnRot = vector.create(prx, pry, prz)
                    animal:clearPendingSpawnWorldPosition()
                    Log:debug("AnimalClusterHusbandry:updateVisuals: placing returned animal farmId=%s uniqueId=%s "
                        .. "at x=%s y=%s z=%s yaw=%s",
                        tostring(animal.farmId), tostring(animal.uniqueId), tostring(px), tostring(py),
                        tostring(pz), tostring(pry))
                end
            end

            if spawnPos ~= nil then
                animalId = addHusbandryAnimal(self.husbandryIds[useTempId and tempHusbandryId or i],
                    visualAnimalIndex - 1, spawnPos, spawnRot)
            else
                animalId = addHusbandryAnimal(self.husbandryIds[useTempId and tempHusbandryId or i],
                    visualAnimalIndex - 1)
            end
            if animalId == 0 then
                Log:trace("AnimalClusterHusbandry:updateVisuals: add refused husbandry=%s farmId=%s uniqueId=%s",
                    tostring(useTempId and tempHusbandryId or i), tostring(animal.farmId), tostring(animal.uniqueId))
            end


            while animalId == 0 and i <= #self.husbandryIds do
                i = useTempId and i or (i + 1)
                useTempId = false
                if i > #self.husbandryIds or self.husbandryIdsToVisualAnimalCount[self.husbandryIds[i]] >= maxAnimalsPerHusbandry then break end
                if spawnPos ~= nil then
                    animalId = addHusbandryAnimal(self.husbandryIds[i], visualAnimalIndex - 1, spawnPos, spawnRot)
                else
                    animalId = addHusbandryAnimal(self.husbandryIds[i], visualAnimalIndex - 1)
                end
                if animalId == 0 then
                    Log:trace("AnimalClusterHusbandry:updateVisuals: add refused husbandry=%s farmId=%s uniqueId=%s",
                        tostring(i), tostring(animal.farmId), tostring(animal.uniqueId))
                end
            end

            if spawnPos ~= nil and animalId == 0 then
                Log:debug("AnimalClusterHusbandry:updateVisuals: spawn position lost, no husbandry took the add "
                    .. "farmId=%s uniqueId=%s",
                    tostring(animal.farmId), tostring(animal.uniqueId))
            end

        end


        if animalId > 0 then

            self.visualAnimalCount = self.visualAnimalCount + 1
            husbandryAnimalCount = husbandryAnimalCount + 1

            local visualData = self.animalSystem:getVisualByAge(subTypeIndex, age)
            local variations = visualData.visualAnimal.variations

            if #variations >= 1 then
                local variationIndex = animal.variation
                if variationIndex == nil or variationIndex > #variations then
                    variationIndex = math.random(1, #variations)
                    animal.variation = variationIndex
                end

                local variation = variations[variationIndex]
                setAnimalTextureTile(self.husbandryIds[useTempId and tempHusbandryId or i], animalId, variation.tileUIndex, variation.tileVIndex)
            end

            if not self.animalIdToCluster[useTempId and tempHusbandryId or i] then
                self.animalIdToCluster[useTempId and tempHusbandryId or i] = {}
            end

            animal.id = (useTempId and tempHusbandryId or i) .. "-" .. animalId
            animal.idFull = self.husbandryIds[useTempId and tempHusbandryId or i] .. "-" .. animalId
            animal.visualAnimalIndex = visualAnimalIndex

            self.animalIdToCluster[useTempId and tempHusbandryId or i][animalId] = animal

            animal:createVisual(self.husbandryIds[useTempId and tempHusbandryId or i], animalId)
            animal:setVisualEarTagColours(colours.earTagLeft, colours.earTagLeft_text, colours.earTagRight, colours.earTagRight_text)

        else
            Log:trace("AnimalClusterHusbandry:updateVisuals: no visual this pass farmId=%s uniqueId=%s",
                tostring(animal.farmId), tostring(animal.uniqueId))
            animal.id = nil
            animal.idFull = nil
            animal.visualAnimalIndex = nil
        end

        self.husbandryIdsToVisualAnimalCount[self.husbandryIds[i]] = husbandryAnimalCount

        if self.visualAnimalCount > RealisticLivestock_AnimalClusterHusbandry.MAX_HUSBANDRIES then
            Log:trace("AnimalClusterHusbandry:updateVisuals: visual cap passed, stopping (visualCount=%s)",
                tostring(self.visualAnimalCount))
            break
        end
        if animalId == 0 then
            Log:trace("AnimalClusterHusbandry:updateVisuals: last add refused, stopping after farmId=%s uniqueId=%s",
                tostring(animal.farmId), tostring(animal.uniqueId))
            break
        end

    end

    local tMainLoopMs = phaseDoneMs()

    i = 1


    for husbandryId, animalIds in pairs(self.animalIdToCluster) do

        for animalId, animal in animalIds do

            local dirtFactor = 0.1

            local animalRootNode = getAnimalRootNode(self.husbandryIds[husbandryId], animalId)
            if animalRootNode == 0 then break end

            I3DUtil.setShaderParameterRec(animalRootNode, "dirt", dirtFactor, nil, nil, nil)

            local x, y, z, w = getAnimalShaderParameter(self.husbandryIds[husbandryId], animalId, "atlasInvSizeAndOffsetUV")

            I3DUtil.setShaderParameterRec(animalRootNode, "atlasInvSizeAndOffsetUV", x, y, z, w)

        end
    end

    local tShaderPassMs = phaseDoneMs()




    self.animalIdToVisualAnimalIndex = newAnimalIdToVisualAnimalIndex
    self:getPlaceable().spec_husbandryAnimals.clusterSystem:updateIdMapping()
    self.nextUpdateClusters = nil
    self.visualUpdatePending = false

    local tTotalMs = (getTimeSec() - tStart) * 1000

    Log:debug("AnimalClusterHusbandry:updateVisuals: husbandryId=%s nextClusters=%d visualCount=%d phases: staleRemove=%.2fms setup=%.2fms mainLoop=%.2fms shader=%.2fms total=%.2fms",
        tostring(self.husbandryId),
        nextCount,
        self.visualAnimalCount,
        tStaleRemoveMs, tSetupMs, tMainLoopMs, tShaderPassMs, tTotalMs)
    Log:trace("<<< AnimalClusterHusbandry:updateVisuals (done) husbandryId=%s", tostring(self.husbandryId))

end

AnimalClusterHusbandry.updateVisuals = Utils.overwrittenFunction(AnimalClusterHusbandry.updateVisuals, RealisticLivestock_AnimalClusterHusbandry.updateVisuals)


function RealisticLivestock_AnimalClusterHusbandry:getAnimalPosition(superFunc, id)

    for husbandryId, animalIds in pairs(self.animalIdToCluster) do

        for animalId, animal in pairs(animalIds) do

            if animal.id == id or animal.farmId .. " " .. animal.uniqueId == id then
                local x, y, z = getAnimalPosition(self.husbandryIds[husbandryId], animalId)
                local a, b, c = getAnimalRotation(self.husbandryIds[husbandryId], animalId)
                return x, y, z, a, b, c
            end

        end

    end

    return nil

end

AnimalClusterHusbandry.getAnimalPosition = Utils.overwrittenFunction(AnimalClusterHusbandry.getAnimalPosition, RealisticLivestock_AnimalClusterHusbandry.getAnimalPosition)


function RealisticLivestock_AnimalClusterHusbandry:getClusterByAnimalId(superFunc, id, husbandryId)

    if husbandryId ~= nil then

        for index, husbandryIdFull in ipairs(self.husbandryIds) do
            if husbandryIdFull == husbandryId and self.animalIdToCluster[index] ~= nil and self.animalIdToCluster[index][id] ~= nil then return self.animalIdToCluster[index][id] end
        end

        return nil

    end


    if type(id) ~= "string" then id = tostring(id) end


    if string.contains(id, "-") then

        local a, _ = string.find(id, "-")
        husbandryId = string.sub(id, 1, (a - 1) or 2)
        local animalId = string.sub(id, (a + 1) or 1)

        if husbandryId ~= nil and animalId ~= nil and self.animalIdToCluster[husbandryId] ~= nil and self.animalIdToCluster[husbandryId][animalId] ~= nil then return self.animalIdToCluster[husbandryId][animalId] end

    end


    for husbandryId, animalIds in pairs(self.animalIdToCluster) do


        for animalId, animal in pairs(animalIds) do

            if animal.id == id then
            end

        end

    end

    return nil

end

AnimalClusterHusbandry.getClusterByAnimalId = Utils.overwrittenFunction(AnimalClusterHusbandry.getClusterByAnimalId, RealisticLivestock_AnimalClusterHusbandry.getClusterByAnimalId)