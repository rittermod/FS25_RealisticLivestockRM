DiseaseTreatmentToggleEvent = {}
local DiseaseTreatmentToggleEvent_mt = Class(DiseaseTreatmentToggleEvent, Event)
InitEventClass(DiseaseTreatmentToggleEvent, "DiseaseTreatmentToggleEvent")

function DiseaseTreatmentToggleEvent.emptyNew()
    local self = Event.new(DiseaseTreatmentToggleEvent_mt)
    return self
end

function DiseaseTreatmentToggleEvent.new(object, animal, diseaseTitle, treatmentRunning)
    local self = DiseaseTreatmentToggleEvent.emptyNew()
    self.object = object
    self.animal = animal
    self.diseaseTitle = diseaseTitle
    self.treatmentRunning = treatmentRunning
    return self
end

function DiseaseTreatmentToggleEvent:readStream(streamId, connection)
    self.object = NetworkUtil.readNodeObject(streamId)
    self.animal = RLAnimalUtil.readStreamIdentifiers(streamId, connection)
    self.diseaseTitle = streamReadString(streamId)
    self.treatmentRunning = streamReadBool(streamId)
    self:run(connection)
end

function DiseaseTreatmentToggleEvent:writeStream(streamId, connection)
    NetworkUtil.writeNodeObject(streamId, self.object)
    RLAnimalUtil.writeStreamIdentifiers(self.animal, streamId, connection)
    streamWriteString(streamId, self.diseaseTitle)
    streamWriteBool(streamId, self.treatmentRunning)
end

--- Resolve the record a toggle names, for the server's pre-rebroadcast refusal check.
--- Mirrors the apply loop's matching exactly - first title match over an unordered walk -
--- because the two must agree on which record a duplicate title selects.
---@param clusterSystem table The pen's cluster system, already validated by the caller
---@param identifiers table The event's animal identity triple
---@param title string The disease title the toggle names
---@return table|nil disease The matching record, or nil when the herd carries none
local function findRecord(clusterSystem, identifiers, title)
    local animal = RLAnimalUtil.find(clusterSystem.animals, identifiers.farmId, identifiers.uniqueId,
        identifiers.country or identifiers.birthday.country)

    if animal == nil then return nil end

    for _, disease in pairs(animal.diseases) do
        if disease.title == title then return disease end
    end

    return nil
end

--- Apply a disease-treatment toggle on this receiver, validating it first when this machine
--- is the server and the request came from a remote client. In order: abort on a vanished
--- husbandry; capability-guard ABOVE the branch guard so the peer-apply leg is covered too;
--- then, for a remote request only, authorize and resolve-then-refuse BEFORE the rebroadcast,
--- so a rejected or refused toggle reaches neither this record nor any peer; rebroadcast; apply.
---
--- The refusal binds the request-inbound branch ONLY, deliberately: a peer applies the
--- authority's values rather than re-deciding them, and guarding it would let a peer veto a
--- decision the server already made.
---@param connection table The network connection the event arrived on
function DiseaseTreatmentToggleEvent:run(connection)
    if self.object == nil then
        Log:warning("DiseaseTreatmentToggleEvent:run: self.object is nil (husbandry gone during event flight?), aborting")
        return
    end

    local identifiers = self.animal

    -- Hoisted above the branch guard on purpose: a peer applying a broadcast reaches the
    -- same payload-resolved object, so a guard inside the server branch would leave that
    -- leg unprotected. Tests CALLABILITY - a truthy non-function raises just the same.
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

        -- The server-side counterpart to the dialog's own gate, mirroring BOTH halves so the
        -- server refuses exactly what the client refuses. After authorization and above the
        -- rebroadcast is the only placement where a rejected request never walks the herd AND
        -- a refused toggle reaches nobody. `disease == nil` falls through to the not-found
        -- warning below.
        local disease = findRecord(clusterSystem, identifiers, self.diseaseTitle)
        local refusal

        -- Both clauses must keep mirroring the dialog's own gate exactly - that mirroring is
        -- the whole reason this block exists. Which states may start or resume a course is
        -- the enrolment rule's to decide, not this one's.
        if disease ~= nil then
            if disease.state == RLDiseaseRecord.STATE.RECOVERED then
                refusal = "recovered"
            elseif disease.model.treatment == nil then
                refusal = "untreatable"
            end
        end

        if refusal ~= nil then
            -- Every value formatted %s + tostring(): the headless harness RAISES where the
            -- in-game logger degrades, so this is a contract, not a style preference. The
            -- PEN's ownerFarmId, so the line agrees with the authorization warning above.
            Log:warning(
                "DiseaseTreatmentToggleEvent:run: refusing a treatment toggle, reason=%s "
                    .. "(disease=%s ownerFarmId=%s uniqueId=%s user='%s' userId=%s) - dropping",
                tostring(refusal), tostring(disease.title), tostring(ownerFarmId),
                tostring(identifiers.uniqueId), tostring(userName), tostring(userId))
            return
        end

        g_server:broadcastEvent(
            DiseaseTreatmentToggleEvent.new(self.object, self.animal, self.diseaseTitle, self.treatmentRunning),
            nil, connection, nil)
        Log:debug("DiseaseTreatmentToggleEvent:run: rebroadcasting treatment toggle to other clients")
    end

    local animal = RLAnimalUtil.find(clusterSystem.animals, identifiers.farmId, identifiers.uniqueId, identifiers.country or identifiers.birthday.country)

    if animal ~= nil then
        for _, disease in pairs(animal.diseases) do
            if disease.title == self.diseaseTitle then
                disease.treatmentRunning = self.treatmentRunning
                Log:trace("DiseaseTreatmentToggleEvent:run: %s treatment=%s uniqueId=%s",
                    self.diseaseTitle, tostring(self.treatmentRunning), tostring(identifiers.uniqueId))
                return
            end
        end
        Log:warning("DiseaseTreatmentToggleEvent:run: disease '%s' not found on uniqueId=%s", self.diseaseTitle, tostring(identifiers.uniqueId))
    else
        Log:warning("DiseaseTreatmentToggleEvent:run: animal not found uniqueId=%s", tostring(identifiers.uniqueId))
    end
end

function DiseaseTreatmentToggleEvent.sendEvent(object, animal, diseaseTitle, treatmentRunning)
    if g_server ~= nil then
        g_server:broadcastEvent(DiseaseTreatmentToggleEvent.new(object, animal, diseaseTitle, treatmentRunning))
    else
        g_client:getServerConnection():sendEvent(DiseaseTreatmentToggleEvent.new(object, animal, diseaseTitle, treatmentRunning))
    end
end
