AnimalDeathEvent = {}

local AnimalDeathEvent_mt = Class(AnimalDeathEvent, Event)
InitEventClass(AnimalDeathEvent, "AnimalDeathEvent")


function AnimalDeathEvent.emptyNew()
    local self = Event.new(AnimalDeathEvent_mt)
    return self
end


function AnimalDeathEvent.new(object, animal)

    local self = AnimalDeathEvent.emptyNew()

    self.object = object
    self.animal = animal

    return self

end


function AnimalDeathEvent:readStream(streamId, connection)

    local hasObject = streamReadBool(streamId)

    self.object = hasObject and NetworkUtil.readNodeObject(streamId) or nil
    self.animal = RLAnimalUtil.readStreamIdentifiers(streamId, connection)

    self:run(connection)

end


function AnimalDeathEvent:writeStream(streamId, connection)

    streamWriteBool(streamId, self.object ~= nil)

    if self.object ~= nil then NetworkUtil.writeNodeObject(streamId, self.object) end
    
    RLAnimalUtil.writeStreamIdentifiers(self.animal, streamId, connection)

end


--- Remove a dead animal from the herd: `findAndRemove` on the non-cluster path, which runs
--- on every machine, or `addPendingRemoveCluster` + `updateNow` server-side, clients syncing
--- through the flush broadcast. Without the server guard, addPendingRemoveCluster asserts
--- and crashes clients on every animal death.
function AnimalDeathEvent:run(connection)

    local identifiers = self.animal

    if self.object == nil then
        local animals = g_currentMission.animalSystem.animals[identifiers.animalTypeIndex]
        RLAnimalUtil.findAndRemove(animals, identifiers.farmId, identifiers.uniqueId, identifiers.country or identifiers.birthday.country)
    elseif g_server ~= nil then
        local clusterSystem = self.object:getClusterSystem()
        local key = RLAnimalUtil.toKeyFromIdentifiers(identifiers)
        local cluster = clusterSystem:getClusterById(key)

        if cluster ~= nil then
            local ok, err = pcall(function() clusterSystem:addPendingRemoveCluster(cluster) end)
            local ok2, err2 = pcall(function() clusterSystem:updateNow() end)
            if not (ok and ok2) then
                Log:error("DeathEvent:run: cluster removal failed key=%s queue=%s flush=%s",
                    tostring(key), tostring(err), tostring(err2))
            end
        else
            Log:warning("DeathEvent:run: cluster not found for key=%s", tostring(key))
        end
    end

    Log:trace("DeathEvent:run removed uniqueId=%s cluster=%s server=%s",
        tostring(identifiers.uniqueId), tostring(self.object ~= nil), tostring(g_server ~= nil))

end