DiseaseTreatmentToggleEvent = {}
local DiseaseTreatmentToggleEvent_mt = Class(DiseaseTreatmentToggleEvent, Event)
InitEventClass(DiseaseTreatmentToggleEvent, "DiseaseTreatmentToggleEvent")

function DiseaseTreatmentToggleEvent.emptyNew()
    local self = Event.new(DiseaseTreatmentToggleEvent_mt)
    return self
end

function DiseaseTreatmentToggleEvent.new(object, animal, diseaseTitle, beingTreated)
    local self = DiseaseTreatmentToggleEvent.emptyNew()
    self.object = object
    self.animal = animal
    self.diseaseTitle = diseaseTitle
    self.beingTreated = beingTreated
    return self
end

function DiseaseTreatmentToggleEvent:readStream(streamId, connection)
    self.object = NetworkUtil.readNodeObject(streamId)
    self.animal = RLAnimalUtil.readStreamIdentifiers(streamId, connection)
    self.diseaseTitle = streamReadString(streamId)
    self.beingTreated = streamReadBool(streamId)
    self:run(connection)
end

function DiseaseTreatmentToggleEvent:writeStream(streamId, connection)
    NetworkUtil.writeNodeObject(streamId, self.object)
    RLAnimalUtil.writeStreamIdentifiers(self.animal, streamId, connection)
    streamWriteString(streamId, self.diseaseTitle)
    streamWriteBool(streamId, self.beingTreated)
end

--- Apply a disease-treatment toggle on this receiver, validating it first when this
--- machine is the server and the request came from a remote client.
---
--- Flow:
---   1. Abort on a husbandry that vanished in flight.
---   2. Capability + result guard, ABOVE the branch guard so the peer-apply leg is
---      covered too: an object that does not carry both accessors as functions, or a
---      cluster system with no `animals` table, is unusable and aborts here rather
---      than raising inside `RLAnimalUtil.find`, which opens with `pairs`.
---   3. Server receiving from a remote client: authorize (permission, then farm-id
---      validity on both sides, then farm scope) and drop on rejection, BEFORE the
---      rebroadcast, so a rejected request reaches nobody.
---   4. Rebroadcast to every peer except the sender.
---   5. Apply the toggle, reading the cluster system the guard already validated.
---@param connection table The network connection the event arrived on
function DiseaseTreatmentToggleEvent:run(connection)
    if self.object == nil then
        Log:warning("DiseaseTreatmentToggleEvent:run: self.object is nil (husbandry gone during event flight?), aborting")
        return
    end

    local identifiers = self.animal

    -- Hoisted above the branch guard on purpose: a peer applying a broadcast reaches
    -- the same payload-resolved object, so a guard inside the server branch would
    -- leave that leg unprotected. Tests callability rather than presence, because a
    -- truthy non-function field raises on the colon call just the same.
    if type(self.object.getOwnerFarmId) ~= "function"
        or type(self.object.getClusterSystem) ~= "function" then
        Log:warning("DiseaseTreatmentToggleEvent:run: object %s does not carry the required accessors (stale node id?), aborting uniqueId=%s",
            tostring(self.object), tostring(identifiers.uniqueId))
        return
    end

    local clusterSystem = self.object:getClusterSystem()
    if clusterSystem == nil or type(clusterSystem.animals) ~= "table" then
        Log:warning("DiseaseTreatmentToggleEvent:run: object %s has no usable cluster system (torn down?), aborting uniqueId=%s",
            tostring(self.object), tostring(identifiers.uniqueId))
        return
    end

    if not connection:getIsServer() then
        local ownerFarmId = self.object:getOwnerFarmId()
        local ok, reason, userName, userId, requesterFarmId =
            RLPermissionHelper.authorizeConnection(connection, "tradeAnimals", ownerFarmId)

        if not ok then
            Log:warning("DiseaseTreatmentToggleEvent:run: %s for user '%s' (userId=%s, farmId=%s) on pen owned by farmId=%s, uniqueId=%s - dropping",
                tostring(reason), tostring(userName), tostring(userId),
                tostring(requesterFarmId), tostring(ownerFarmId), tostring(identifiers.uniqueId))
            return
        end

        g_server:broadcastEvent(
            DiseaseTreatmentToggleEvent.new(self.object, self.animal, self.diseaseTitle, self.beingTreated),
            nil, connection, nil)
        Log:debug("DiseaseTreatmentToggleEvent:run: rebroadcasting treatment toggle to other clients")
    end

    local animal = RLAnimalUtil.find(clusterSystem.animals, identifiers.farmId, identifiers.uniqueId, identifiers.country or identifiers.birthday.country)

    if animal ~= nil then
        for _, disease in pairs(animal.diseases) do
            if disease.type.title == self.diseaseTitle then
                disease.beingTreated = self.beingTreated
                Log:trace("DiseaseTreatmentToggleEvent:run: %s treatment=%s uniqueId=%s",
                    self.diseaseTitle, tostring(self.beingTreated), tostring(identifiers.uniqueId))
                return
            end
        end
        Log:warning("DiseaseTreatmentToggleEvent:run: disease '%s' not found on uniqueId=%s", self.diseaseTitle, tostring(identifiers.uniqueId))
    else
        Log:warning("DiseaseTreatmentToggleEvent:run: animal not found uniqueId=%s", tostring(identifiers.uniqueId))
    end
end

function DiseaseTreatmentToggleEvent.sendEvent(object, animal, diseaseTitle, beingTreated)
    if g_server ~= nil then
        g_server:broadcastEvent(DiseaseTreatmentToggleEvent.new(object, animal, diseaseTitle, beingTreated))
    else
        g_client:getServerConnection():sendEvent(DiseaseTreatmentToggleEvent.new(object, animal, diseaseTitle, beingTreated))
    end
end
