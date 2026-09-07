AnimalBirthEvent = {}

local AnimalBirthEvent_mt = Class(AnimalBirthEvent, Event)
InitEventClass(AnimalBirthEvent, "AnimalBirthEvent")


function AnimalBirthEvent.emptyNew()
    local self = Event.new(AnimalBirthEvent_mt)
    return self
end


function AnimalBirthEvent.new(object, animal, children, parentDied)

    local self = AnimalBirthEvent.emptyNew()

    self.object = object
    self.animal = animal
    self.children = children or {}
    self.parentDied = parentDied or false

    return self

end


function AnimalBirthEvent:readStream(streamId, connection)

    local hasObject = streamReadBool(streamId)

    self.object = hasObject and NetworkUtil.readNodeObject(streamId) or nil
    self.animal = RLAnimalUtil.readStreamIdentifiers(streamId, connection)

    local numChildren = streamReadUInt8(streamId)
    self.children = {}

    for i = 1, numChildren do
        local child = Animal.new()
        child:readStream(streamId, connection)
        table.insert(self.children, child)
    end

    self.parentDied = streamReadBool(streamId)

    self:run(connection)

end


function AnimalBirthEvent:writeStream(streamId, connection)

    streamWriteBool(streamId, self.object ~= nil)

    if self.object ~= nil then NetworkUtil.writeNodeObject(streamId, self.object) end
    
    RLAnimalUtil.writeStreamIdentifiers(self.animal, streamId, connection)

    streamWriteUInt8(streamId, #self.children)

    for _, child in pairs(self.children) do child:writeStream(streamId, connection) end

    streamWriteBool(streamId, self.parentDied)

end


--- Process birth on the receiving end: add the children, clear pregnancy, set lactating for
--- cows and goats, and remove the parent if she died. Cluster and non-cluster paths are
--- handled independently.
function AnimalBirthEvent:run(connection)

    local identifiers = self.animal

    local country = identifiers.country or identifiers.birthday.country

    Log:trace("BirthEvent:run uniqueId=%s children=%d parentDied=%s cluster=%s",
        tostring(identifiers.uniqueId), #self.children, tostring(self.parentDied), tostring(self.object ~= nil))

    if self.object == nil then

        local animals = g_currentMission.animalSystem.animals[identifiers.animalTypeIndex]

        for _, child in pairs(self.children) do table.insert(animals, child) end

        local parent = RLAnimalUtil.find(animals, identifiers.farmId, identifiers.uniqueId, country)

        if parent ~= nil then
            parent.isParent = true
            parent.monthsSinceLastBirth = 0
            parent.pregnancy = nil
            parent.impregnatedBy = nil
            parent.isPregnant = false
            parent.reproduction = 0

            if parent.animalTypeIndex == AnimalType.COW or parent.subType == "GOAT" then parent.isLactating = true end

            if self.parentDied then RLAnimalUtil.findAndRemove(animals, identifiers.farmId, identifiers.uniqueId, country) end
        else
            Log:trace("BirthEvent:run parent not found uniqueId=%s", tostring(identifiers.uniqueId))
        end

    else

        local clusterSystem = self.object:getClusterSystem()

        -- Server-only: queue children adds + flush so they appear in clusterSystem.animals
        -- before the parent lookup. Clients skip; their cluster state syncs via the
        -- AnimalClusterUpdateEvent broadcast that fires from the server's flush.
        if g_server ~= nil then
            local ok, err = pcall(function()
                for _, child in pairs(self.children) do
                    clusterSystem:addPendingAddCluster(child)
                end
            end)
            local ok2, err2 = pcall(function() clusterSystem:updateNow() end)
            if not (ok and ok2) then
                Log:error("BirthEvent:run: addCluster batch failed children=%d queue=%s flush=%s",
                    #self.children, tostring(err), tostring(err2))
            end
        end

        -- Every machine: parent state mutations on the existing animal reference.
        -- Client clusterSystem.animals already contains parent (synced from earlier);
        -- server clusterSystem.animals contains parent (was there before this event).
        local parent = RLAnimalUtil.find(clusterSystem.animals, identifiers.farmId, identifiers.uniqueId, country)

        if parent ~= nil then
            parent.isParent = true
            parent.monthsSinceLastBirth = 0
            parent.pregnancy = nil
            parent.impregnatedBy = nil
            parent.isPregnant = false
            parent.reproduction = 0

            if parent.animalTypeIndex == AnimalType.COW or parent.subType == "GOAT" then parent.isLactating = true end
        else
            Log:trace("BirthEvent:run parent not found uniqueId=%s (cluster)", tostring(identifiers.uniqueId))
        end

        -- Server-only: parentDied removal + flush.
        if self.parentDied and g_server ~= nil then
            local parentKey = RLAnimalUtil.toKeyFromIdentifiers(identifiers)
            local parentCluster = clusterSystem:getClusterById(parentKey)
            if parentCluster ~= nil then
                local ok, err = pcall(function() clusterSystem:addPendingRemoveCluster(parentCluster) end)
                local ok2, err2 = pcall(function() clusterSystem:updateNow() end)
                if not (ok and ok2) then
                    Log:error("BirthEvent:run: parentDied removal failed key=%s queue=%s flush=%s",
                        tostring(parentKey), tostring(err), tostring(err2))
                end
            else
                Log:warning("BirthEvent:run: parentDied but cluster not found for key=%s", tostring(parentKey))
            end
        end

        Log:debug("BirthEvent:run: cluster path complete uniqueId=%s children=%d parentDied=%s server=%s",
            tostring(identifiers.uniqueId), #self.children, tostring(self.parentDied), tostring(g_server ~= nil))

    end

end