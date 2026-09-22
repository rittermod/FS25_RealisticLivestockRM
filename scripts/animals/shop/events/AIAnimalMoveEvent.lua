-- AIAnimalMoveEvent.lua
-- Server-authoritative herdsman move: relocate animals between two husbandry pens on the owning
-- farm. Symmetric stream, and a g_server-gated :run that mutates only on the authority; pure
-- clients converge through the cluster system's own AnimalClusterUpdateEvent flush.
--
-- Source-first is an ordering invariant: the target's updateClusters reassigns idFull on the
-- shared entity, so the source's visual-count bookkeeping must read its handles first.

local Log = RmLogging.getLogger("RLRM")

AIAnimalMoveEvent = {}

local AIAnimalMoveEvent_mt = Class(AIAnimalMoveEvent, Event)
InitEventClass(AIAnimalMoveEvent, "AIAnimalMoveEvent")


function AIAnimalMoveEvent.emptyNew()
    local self = Event.new(AIAnimalMoveEvent_mt)
    return self
end


--- @param sourceObject table source husbandry placeable (the pen the animals leave)
--- @param targetObject table destination husbandry placeable (owner-farm, guaranteed by the executor)
--- @param animals table array of animal identifier records (RLAnimalUtil identity fields)
--- @return table event
function AIAnimalMoveEvent.new(sourceObject, targetObject, animals)
    local event = AIAnimalMoveEvent.emptyNew()
    event.sourceObject = sourceObject
    event.targetObject = targetObject
    event.animals = animals
    return event
end


--- Symmetric read: two node-objects, then the animals as identity records.
--- @param streamId number
--- @param connection table
function AIAnimalMoveEvent:readStream(streamId, connection)
    self.sourceObject = NetworkUtil.readNodeObject(streamId)
    self.targetObject = NetworkUtil.readNodeObject(streamId)

    local numAnimals = streamReadUInt16(streamId)
    self.animals = {}
    for i = 1, numAnimals do
        table.insert(self.animals, RLAnimalUtil.readStreamIdentifiers(streamId, connection))
    end

    Log:trace("AIAnimalMoveEvent:readStream: numAnimals=%d source=%s target=%s",
        numAnimals, tostring(self.sourceObject), tostring(self.targetObject))

    self:run(connection)
end


--- Symmetric write: mirror of readStream (no server/client direction branch).
--- @param streamId number
--- @param connection table
function AIAnimalMoveEvent:writeStream(streamId, connection)
    NetworkUtil.writeNodeObject(streamId, self.sourceObject)
    NetworkUtil.writeNodeObject(streamId, self.targetObject)

    streamWriteUInt16(streamId, #self.animals)
    for _, animal in pairs(self.animals) do
        RLAnimalUtil.writeStreamIdentifiers(animal, streamId, connection)
    end

    Log:trace("AIAnimalMoveEvent:writeStream: numAnimals=%d source=%s target=%s",
        #self.animals, tostring(self.sourceObject), tostring(self.targetObject))
end


--- Relocate the resolved source animals to the target husbandry, server-only: the pending
--- cluster API asserts isServer, so a client must skip the mutation block entirely.
--- @param connection table
function AIAnimalMoveEvent:run(connection)
    RmSafeUtils.safeCall("AIAnimalMoveEvent:run", function()
        Log:trace("AIAnimalMoveEvent:run moving %d animals server=%s",
            #self.animals, tostring(g_server ~= nil))

        if g_server == nil then return end

        -- Resolve the target shape BEFORE the cluster-system prologue. An EPP placeable has no
        -- real cluster system, so getClusterSystem() must not run for it - it would crash; it is
        -- resolved inside the husbandry branch instead.
        local eppSpec = self.targetObject.spec_extendedProductionPoint
        local targetPP = eppSpec ~= nil and eppSpec.productionPoint or nil
        local isEPPTarget = targetPP ~= nil

        local sourceClusterSystem = self.sourceObject:getClusterSystem()

        -- Resolve each animal's LIVE source cluster by three-field identity; a missing one is
        -- dropped. In RLRM a cluster IS the Animal, so one object serves both sides of the move.
        local transferList = {}
        for _, identifier in pairs(self.animals) do
            local key = RLAnimalUtil.toKeyFromIdentifiers(identifier)
            local cluster = sourceClusterSystem:getClusterById(key)
            if cluster ~= nil then
                table.insert(transferList, { animal = cluster, sourceCluster = cluster })
            else
                Log:warning("AIAnimalMoveEvent:run: source cluster not found for key=%s (skipping)", tostring(key))
            end
        end

        if isEPPTarget then
            -- EPP delivery. Age is read off the RESOLVED live cluster, never the stream, which
            -- carries identity only. Target-first and per-animal atomic, staging the source flush
            -- for delivered animals only - duplication over loss.
            local typeIndex = self.sourceObject.getAnimalTypeIndex ~= nil and self.sourceObject:getAnimalTypeIndex() or nil
            local typeData = (typeIndex ~= nil and type(targetPP.animalsTypeData) == "table") and targetPP.animalsTypeData[typeIndex] or nil
            local minAge = (typeData ~= nil and typeData.minimumAge) or 0
            local maxAge = (typeData ~= nil and typeData.maximumAge) or 999

            local eligible = {}
            local skippedAge = 0
            local skippedSick = 0
            for _, entry in ipairs(transferList) do
                local age = (entry.animal ~= nil and entry.animal.age) or 0
                if age >= minAge and age <= maxAge then
                    if RLDiseaseSaleGate.check(entry.animal) then
                        eligible[#eligible + 1] = entry
                    else
                        skippedSick = skippedSick + 1
                        Log:debug("AIAnimalMoveEvent:run: EPP sick backstop skipping uniqueId=%s farmId=%s (target=%s)",
                            tostring(entry.animal.uniqueId), tostring(entry.animal.farmId), tostring(self.targetObject))
                    end
                else
                    skippedAge = skippedAge + 1
                    Log:trace("AIAnimalMoveEvent:run: EPP age backstop skipping uniqueId=%s age=%s (window %d-%d)",
                        tostring(entry.animal ~= nil and entry.animal.uniqueId), tostring(age), minAge, maxAge)
                end
            end
            if skippedAge > 0 or skippedSick > 0 then
                Log:debug("AIAnimalMoveEvent:run: EPP backstop removed %d age + %d sick of %d resolved animal(s) (window %d-%d)",
                    skippedAge, skippedSick, #transferList, minAge, maxAge)
            end

            local okTarget, errTarget, deliveredList = AnimalMoveEvent._dispatchTargetDelivery(targetPP, eligible, nil)
            local ok1, err1 = pcall(function()
                AnimalMoveEvent._stageSourceFlushForDelivered(sourceClusterSystem, deliveredList)
            end)
            local ok2, err2 = pcall(function() sourceClusterSystem:updateNow() end)

            if okTarget and ok1 and ok2 then
                local farmId = self.targetObject.getOwnerFarmId ~= nil and self.targetObject:getOwnerFarmId() or nil
                Log:debug("AIAnimalMoveEvent:run: delivered %d animal(s) to EPP butcher farmId=%s (skippedAge=%d skippedSick=%d)",
                    #(deliveredList or {}), tostring(farmId), skippedAge, skippedSick)
            else
                Log:error("AIAnimalMoveEvent:run: EPP transfer failed delivered=%d target=%s sourceFlush=%s sourceUpdate=%s",
                    #(deliveredList or {}), tostring(errTarget), tostring(err1), tostring(err2))
            end
            return
        end

        -- Husbandry target. Source-first: remove and flush the source before delivering, per the
        -- ordering invariant above. getClusterSystem is resolved here, never on the EPP branch.
        local targetClusterSystem = self.targetObject:getClusterSystem()
        local ok1, err1 = pcall(function()
            for _, entry in ipairs(transferList) do
                sourceClusterSystem:addPendingRemoveCluster(entry.sourceCluster)
            end
        end)
        local ok2, err2 = pcall(function() sourceClusterSystem:updateNow() end)

        local okTarget, errTarget = AnimalMoveEvent._dispatchTargetDelivery(
            self.targetObject, transferList, targetClusterSystem)

        if ok1 and ok2 and okTarget then
            local farmId = self.targetObject:getOwnerFarmId()
            Log:debug("AIAnimalMoveEvent:run: moved %d animals to farmId=%s",
                #transferList, tostring(farmId))
        else
            Log:error("AIAnimalMoveEvent:run: transfer failed N=%d sourceQueue=%s sourceFlush=%s target=%s",
                #transferList, tostring(err1), tostring(err2), tostring(errTarget))
        end
    end)
end


--- Type-level validation for a move to a husbandry or an EPP (butcher) destination.
---
--- A husbandry supports an animal TYPE and reports a total free-slot count, so one
--- representative subtype answers for the whole single-type source pen. An EPP delegates to its
--- production point, whose free-slot gate is subtype-arg'd.
--- @param source table source husbandry placeable
--- @param target table destination placeable (husbandry OR EPP)
--- @param count number number of animals to move (free-slot gate)
--- @param subTypeIndex number one representative subtype of the single-type source pen
--- @return number|nil errorCode an AnimalMoveEvent.MOVE_ERROR_* constant, or nil when valid
function AIAnimalMoveEvent.validate(source, target, count, subTypeIndex)
    if source == nil then return AnimalMoveEvent.MOVE_ERROR_SOURCE_OBJECT_DOES_NOT_EXIST end
    if target == nil then return AnimalMoveEvent.MOVE_ERROR_TARGET_OBJECT_DOES_NOT_EXIST end

    -- EPP dest: the support and capacity methods live on the production point, not the placeable.
    -- A missing pp fails closed as target-does-not-exist rather than nil-indexing the spec.
    local eppSpec = target.spec_extendedProductionPoint
    if eppSpec ~= nil then
        local pp = eppSpec.productionPoint
        if pp == nil then return AnimalMoveEvent.MOVE_ERROR_TARGET_OBJECT_DOES_NOT_EXIST end
        if not pp:getSupportsAnimalSubType(subTypeIndex) then return AnimalMoveEvent.MOVE_ERROR_ANIMAL_NOT_SUPPORTED end
        if pp:getNumOfFreeAnimalSlots(subTypeIndex) < count then return AnimalMoveEvent.MOVE_ERROR_NOT_ENOUGH_SPACE end
        return nil
    end

    if not target:getSupportsAnimalSubType(subTypeIndex) then return AnimalMoveEvent.MOVE_ERROR_ANIMAL_NOT_SUPPORTED end
    if target:getNumOfFreeAnimalSlots() < count then return AnimalMoveEvent.MOVE_ERROR_NOT_ENOUGH_SPACE end
    return nil
end
