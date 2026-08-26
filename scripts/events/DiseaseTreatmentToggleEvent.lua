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

--- Resolve the record a toggle names, for the server's pre-rebroadcast refusal check.
---
--- Mirrors the apply loop's matching exactly - first title match wins over an unordered
--- walk - because the two must agree on WHICH record a duplicate title selects. The apply
--- loop keeps its own copy rather than calling this: it is the peer leg's resolution too,
--- and it returns as soon as it writes.
---@param clusterSystem table The pen's cluster system, already validated by the caller
---@param identifiers table The event's animal identity triple
---@param title string The disease title the toggle names
---@return table|nil disease The matching record, or nil when the herd carries none
local function findRecord(clusterSystem, identifiers, title)
    local animal = RLAnimalUtil.find(clusterSystem.animals, identifiers.farmId, identifiers.uniqueId,
        identifiers.country or identifiers.birthday.country)

    if animal == nil then return nil end

    for _, disease in pairs(animal.diseases) do
        if disease.type.title == title then return disease end
    end

    return nil
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
---   4. Server receiving from a remote client: resolve the record and refuse a toggle the
---      dialog itself would refuse - already cured, or a type carrying no treatment. Above
---      the rebroadcast, so a refused toggle reaches neither this record nor any peer. An
---      unresolvable record falls through to the existing not-found warning below.
---   5. Rebroadcast to every peer except the sender.
---   6. Apply the toggle, reading the cluster system the guard already validated.
---
--- Step 4 binds the request-inbound branch ONLY, and the asymmetry is deliberate rather
--- than an oversight: a peer's job is to apply the authority's values, not to re-decide
--- them against its own copy. Guarding the peer leg would let a peer veto a decision the
--- server already made.
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

        -- The server-side counterpart to the dialog's own gate, mirroring BOTH halves so the
        -- server refuses exactly what the client refuses. It sits here, after authorization
        -- and above the rebroadcast, because that is the only arrangement satisfying both
        -- constraints at once: a rejected request never walks the herd, and a refused toggle
        -- reaches neither this record nor any peer.
        --
        -- `disease == nil` is ordering, not padding: an unresolvable record falls through to
        -- the existing not-found warning below, which is today's behaviour.
        local disease = findRecord(clusterSystem, identifiers, self.diseaseTitle)
        local refusal

        if disease ~= nil then
            if disease.cured then
                refusal = "cured"
            elseif disease.type.treatment == nil then
                refusal = "untreatable"
            end
        end

        if refusal ~= nil then
            -- Every value formatted %s + tostring(): the headless harness formats bare and
            -- RAISES where the in-game logger degrades, so this is a contract, not a style
            -- preference. The PEN's ownerFarmId rather than the animal's identity farmId, so
            -- the line agrees with the authorization warning above it.
            Log:warning(
                "DiseaseTreatmentToggleEvent:run: refusing a treatment toggle, reason=%s "
                    .. "(disease=%s ownerFarmId=%s uniqueId=%s user='%s' userId=%s) - dropping",
                tostring(refusal), tostring(disease.type.title), tostring(ownerFarmId),
                tostring(identifiers.uniqueId), tostring(userName), tostring(userId))
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
