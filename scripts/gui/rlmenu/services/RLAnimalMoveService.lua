--[[
    RLAnimalMoveService.lua
    Stateless service for animal move operations in the RL Tabbed Menu, wrapping
    RLMoveDestinationHelper and AnimalMoveEvent dispatch. Handles pen<->pen, pen->EPP and
    pen<->trailer through one path, and fires the SAME AnimalMoveEvent the legacy
    controller fires - mutation parity, never a new event class.

    Moves run through the legacy AnimalScreenTrailerFarm bulk filter pipeline: per-animal
    AnimalMoveEvent.validate, the destination EPP sick and age gates, then a running-count capacity
    check, building a survivor list; only survivors are dispatched.

    Broadcast invariant: exactly one MOVED_ANIMALS_* RLMessage per move. The server
    AnimalMoveEvent:run broadcasts in MP and skips pure SP; the client leg here is the
    mirror-image via shouldClientBroadcast, so SP, host and dedi each get exactly one.
]]

local Log = RmLogging.getLogger("RLRM")

RLAnimalMoveService = {}

--- Client-only code: a sick animal refused for a butcher before dispatch; never sent on the wire.
RLAnimalMoveService.ERROR_ANIMAL_SICK = -2

--- Error code to i18n key mapping for move operations.
--- MOVE_ERROR_INVALID_CLUSTER maps to the generic "not supported" text: there is no
--- dedicated string and it is not a user-correctable condition.
RLAnimalMoveService.ERROR_CODE_MAPPING = {
    [AnimalMoveEvent.MOVE_ERROR_SOURCE_OBJECT_DOES_NOT_EXIST] = "rl_ui_moveErrorNotSupported",
    [AnimalMoveEvent.MOVE_ERROR_TARGET_OBJECT_DOES_NOT_EXIST] = "rl_ui_moveErrorNotSupported",
    [AnimalMoveEvent.MOVE_ERROR_NO_PERMISSION]                = "rl_ui_moveErrorNoPermission",
    [AnimalMoveEvent.MOVE_ERROR_ANIMAL_NOT_SUPPORTED]         = "rl_ui_moveErrorNotSupported",
    [AnimalMoveEvent.MOVE_ERROR_NOT_ENOUGH_SPACE]             = "rl_ui_moveErrorNoSpace",
    [AnimalMoveEvent.MOVE_ERROR_INVALID_CLUSTER]              = "rl_ui_moveErrorNotSupported",
}


--- Enumerate valid move destinations for a source husbandry and animal subtype.
---
--- A nil `sourceHusbandry` is supported for dealer-buy flows: the delegate's
--- `placeable ~= sourceHusbandry` exclusion becomes a no-op, so every farm-owned placeable
--- supporting the subtype is returned.
--- @param sourceHusbandry table|nil The source husbandry placeable (excluded from results; nil for dealer-buy)
--- @param farmId number The owning farm ID
--- @param animalSubTypeIndex number The animal subtype that destinations must support
--- @return table Array of destination entries ({placeable, name, currentCount, maxCount, freeSlots, isEPP, minAge?, maxAge?})
function RLAnimalMoveService.getValidDestinations(sourceHusbandry, farmId, animalSubTypeIndex)
    if farmId == nil or farmId == 0 then
        Log:warning("RLAnimalMoveService.getValidDestinations: invalid farmId=%s", tostring(farmId))
        return {}
    end
    if sourceHusbandry == nil then
        Log:trace("RLAnimalMoveService.getValidDestinations: nil source (dealer-buy path)")
    end
    Log:debug("RLAnimalMoveService.getValidDestinations: farmId=%d subTypeIndex=%d source=%s",
        farmId, animalSubTypeIndex, tostring(sourceHusbandry ~= nil))
    return RLMoveDestinationHelper.getValidDestinations(sourceHusbandry, farmId, animalSubTypeIndex)
end


--- Validate animals against a destination, categorizing valid vs rejected.
--- @param animals table Array of Animal/cluster objects to validate
--- @param destination table Destination entry from getValidDestinations
--- @param animalTypeIndex number The animal type index
--- @return table Validation result {valid = {}, rejected = {animal, reason}, destination}
function RLAnimalMoveService.buildMoveValidationResult(animals, destination, animalTypeIndex)
    if animals == nil or #animals == 0 then
        Log:trace("RLAnimalMoveService.buildMoveValidationResult: empty animals, returning empty result")
        return { valid = {}, rejected = {}, destination = destination }
    end
    if destination == nil then
        Log:warning("RLAnimalMoveService.buildMoveValidationResult: nil destination")
        return { valid = {}, rejected = {}, destination = destination }
    end
    Log:debug("RLAnimalMoveService.buildMoveValidationResult: %d animals, dest='%s'", #animals, destination.name or "?")
    return RLMoveDestinationHelper.buildMoveValidationResult(animals, destination, animalTypeIndex)
end


--- Client-side pre-validation for a single animal move, mirroring the legacy single-move
--- call to AnimalMoveEvent.validate() before sending the event.
--- @param sourceHusbandry table The source husbandry placeable
--- @param destination table The destination placeable (entry.placeable)
--- @param farmId number The owning farm ID
--- @param animalSubTypeIndex number The animal subtype index
--- @return number|nil errorCode Nil if validation passes, error code if it fails
function RLAnimalMoveService.preValidateSingleMove(sourceHusbandry, destination, farmId, animalSubTypeIndex)
    Log:trace("RLAnimalMoveService.preValidateSingleMove: farmId=%d subTypeIndex=%d", farmId, animalSubTypeIndex)
    local errorCode = AnimalMoveEvent.validate(sourceHusbandry, destination, farmId, animalSubTypeIndex)
    if errorCode ~= nil then
        Log:debug("RLAnimalMoveService.preValidateSingleMove: failed, errorCode=%d", errorCode)
    else
        Log:trace("RLAnimalMoveService.preValidateSingleMove: passed")
    end
    return errorCode
end


--- Resolve which endpoint receives the move broadcast and which key applies, mirroring
--- AnimalMoveEvent:run: SOURCE puts the message on the source naming the target, TARGET the
--- reverse. The SINGLE / MULTIPLE suffix keys off the SURVIVOR count, not the input count.
--- Pure, so it dual-runs.
--- @param moveType string "SOURCE" or "TARGET"
--- @param survivorCount number Number of animals actually being moved
--- @return table|nil plan { husbandryRole = "source"|"target", nameRole = "target"|"source", messageKey = string }, or nil when survivorCount <= 0 or moveType is invalid
function RLAnimalMoveService.resolveBroadcastPlan(moveType, survivorCount)
    if survivorCount == nil or survivorCount <= 0 then
        return nil
    end
    local suffix = (survivorCount == 1) and "SINGLE" or "MULTIPLE"
    if moveType == "SOURCE" then
        return { husbandryRole = "source", nameRole = "target", messageKey = "MOVED_ANIMALS_SOURCE_" .. suffix }
    elseif moveType == "TARGET" then
        return { husbandryRole = "target", nameRole = "source", messageKey = "MOVED_ANIMALS_TARGET_" .. suffix }
    end
    return nil
end


--- Whether the client leg adds the moved-animals message itself. The deliberate
--- MIRROR-IMAGE of the event's own pure-SP early return, so the move broadcasts exactly
--- once across single-player, host and dedicated server alike.
--- @param serverExists boolean g_server ~= nil
--- @param netIsRunning boolean|nil g_server.netIsRunning (nil treated as not-running)
--- @return boolean broadcast True when the client leg is the sole broadcaster (pure SP)
function RLAnimalMoveService.shouldClientBroadcast(serverExists, netIsRunning)
    return serverExists == true and not netIsRunning
end


--- Filter a single-type animal list to the subset that may move: skip a nil subtype, run
--- the validator, apply the destination sick and age gates for an EPP, then a running-count capacity
--- check that rejects unless free slots STRICTLY exceed the survivors queued so far.
--- @param source table Move source endpoint (pen/trailer/EPP placeable)
--- @param target table Move destination endpoint (pen/trailer/EPP placeable); capacity is read from it
--- @param animals table Array of Animal refs for a single animalType (caller segments by type)
--- @param ownerFarmId number Owning farm id passed to the validator
--- @param eppTypeData table|nil Destination EPP age data {minimumAge?, maximumAge?}, or nil when target is not an EPP
--- @param validate function (source, target, farmId, subTypeIndex) -> errorCode|nil (AnimalMoveEvent.validate in production)
--- @return table survivors Animals passing validate + age + running-count, in input order
--- @return number|nil firstErrorCode First rejection's error code, or nil when nothing was rejected
function RLAnimalMoveService.filterMovableAnimals(source, target, animals, ownerFarmId, eppTypeData, validate)
    local survivors = {}
    local firstErrorCode = nil
    local skipped = 0

    for _, animal in ipairs(animals) do
        local label = animal.name or animal.uniqueId or "?"

        if animal.subTypeIndex == nil then
            Log:warning("RLAnimalMoveService.filterMovableAnimals: animal '%s' has nil subTypeIndex, skipping", tostring(label))
            skipped = skipped + 1
        else
            local errorCode = validate(source, target, ownerFarmId, animal.subTypeIndex)
            if errorCode ~= nil then
                if firstErrorCode == nil then firstErrorCode = errorCode end
                Log:debug("RLAnimalMoveService.filterMovableAnimals: '%s' rejected by validate (errorCode=%d)", tostring(label), errorCode)
                skipped = skipped + 1
            else
                local rejected = false

                if eppTypeData ~= nil and not RLDiseaseSaleGate.check(animal) then
                    if firstErrorCode == nil then firstErrorCode = RLAnimalMoveService.ERROR_ANIMAL_SICK end
                    Log:debug("RLAnimalMoveService.filterMovableAnimals: '%s' rejected, sick (butcher destination)", tostring(label))
                    rejected = true
                elseif eppTypeData ~= nil then
                    local age = animal.age or 0
                    local minAge = eppTypeData.minimumAge or 0
                    local maxAge = eppTypeData.maximumAge or 60
                    if age < minAge or age > maxAge then
                        if firstErrorCode == nil then firstErrorCode = AnimalMoveEvent.MOVE_ERROR_ANIMAL_NOT_SUPPORTED end
                        Log:debug("RLAnimalMoveService.filterMovableAnimals: '%s' rejected by EPP age (age=%d, allowed=%d-%d)",
                            tostring(label), age, minAge, maxAge)
                        rejected = true
                    end
                end

                if not rejected then
                    local freeSlots = target:getNumOfFreeAnimalSlots(animal.subTypeIndex)
                    if not RLTrailerEndpointService.hasRoom(freeSlots, #survivors) then
                        if firstErrorCode == nil then firstErrorCode = AnimalMoveEvent.MOVE_ERROR_NOT_ENOUGH_SPACE end
                        Log:debug("RLAnimalMoveService.filterMovableAnimals: '%s' rejected by capacity (free=%s, queued=%d)",
                            tostring(label), tostring(freeSlots), #survivors)
                        rejected = true
                    else
                        survivors[#survivors + 1] = animal
                        Log:trace("RLAnimalMoveService.filterMovableAnimals: '%s' passed (queued=%d)", tostring(label), #survivors)
                    end
                end

                if rejected then skipped = skipped + 1 end
            end
        end
    end

    Log:debug("RLAnimalMoveService.filterMovableAnimals: %d of %d survived (%d skipped), firstErrorCode=%s",
        #survivors, #animals, skipped, tostring(firstErrorCode))
    return survivors, firstErrorCode
end


--- Apply a resolved broadcast plan to live endpoints: add the MOVED_ANIMALS_* message to
--- the husbandry endpoint, naming the other one. Mirrors :run's `addRLMessage ~= nil` guard,
--- so an EPP destination silently receives no message.
--- @param plan table resolveBroadcastPlan result (non-nil)
--- @param husbandryEndpoint table Endpoint that receives the message (may lack addRLMessage -> no-op)
--- @param nameEndpoint table The other endpoint, named in the message
--- @param survivorCount number Number of animals moved (the MULTIPLE count arg)
function RLAnimalMoveService.applyClientBroadcast(plan, husbandryEndpoint, nameEndpoint, survivorCount)
    if husbandryEndpoint == nil or husbandryEndpoint.addRLMessage == nil then
        Log:trace("RLAnimalMoveService.applyClientBroadcast: endpoint has no addRLMessage (EPP destination?), no message added")
        return
    end

    -- A plain getName, not getDisplayData: the latter probes trailer-only getters that warn
    -- for husbandry / EPP endpoints, and the name VALUE is identical either way.
    local name = (nameEndpoint ~= nil and nameEndpoint.getName ~= nil) and nameEndpoint:getName() or ""
    if survivorCount == 1 then
        husbandryEndpoint:addRLMessage(plan.messageKey, nil, { name })
    else
        husbandryEndpoint:addRLMessage(plan.messageKey, nil, { survivorCount, name })
    end
    Log:debug("RLAnimalMoveService.applyClientBroadcast: key='%s' count=%d name='%s'",
        plan.messageKey, survivorCount, tostring(name))
end


--- Filter animals, dispatch the survivors through the move event, and in pure SP add the
--- one moved-animals message.
--- @param source table The move source endpoint (husbandry / trailer)
--- @param target table The move destination endpoint (husbandry / trailer / EPP)
--- @param animals table Array of Animal/cluster objects to move (one animalType)
--- @param moveType string "SOURCE" (-> target) or "TARGET" (-> target); any other value fails closed
--- @param callback function|nil Callback fired with the server error code (or the surfaced firstErrorCode when all rejected)
--- @param callbackTarget table|nil Callback target; when set the callback is invoked as callback(callbackTarget, errorCode)
--- @param deps table|nil Optional RLAnimalEventRequest injection seam (in-game recorder test); nil -> real g_*
--- @return boolean accepted True when the request was armed + dispatched; false when nothing was dispatched
---   (no animals, invalid moveType, all-rejected short-circuit, or a same-class request already in flight).
---   The caller reads this to keep its selection + release its UI lock on false.
function RLAnimalMoveService.moveAnimals(source, target, animals, moveType, callback, callbackTarget, deps)
    if animals == nil or #animals == 0 then
        Log:debug("RLAnimalMoveService.moveAnimals: no animals, skipping")
        return false
    end

    -- Fail closed before constructing any event: a garbage moveType crashes the client at
    -- streamWriteString and yields zero broadcasts in SP.
    if moveType ~= "SOURCE" and moveType ~= "TARGET" then
        Log:warning("RLAnimalMoveService.moveAnimals: invalid moveType=%s, aborting (no dispatch, no broadcast)", tostring(moveType))
        return false
    end

    Log:debug("RLAnimalMoveService.moveAnimals: %d animals, moveType=%s, source='%s' target='%s'",
        #animals, moveType,
        tostring(source and source.getName and source:getName()),
        tostring(target and target.getName and target:getName()))

    -- Owner farm for the per-animal validate; both endpoints are farm-owned. The client
    -- filter is advisory - the server :run re-validates authoritatively.
    local ownerFarmId = nil
    if source ~= nil and source.getOwnerFarmId ~= nil then
        ownerFarmId = source:getOwnerFarmId()
    elseif target ~= nil and target.getOwnerFarmId ~= nil then
        ownerFarmId = target:getOwnerFarmId()
    end

    -- Resolved from the first animal carrying a real subTypeIndex, not blindly from
    -- animals[1]: a leading nil-subTypeIndex animal would resolve a nil type and silently
    -- disable the age-gate for the real survivors.
    local eppTypeData = nil
    if target ~= nil and target.animalsTypeData ~= nil then
        local subTypeIndex = nil
        for _, animal in ipairs(animals) do
            if animal.subTypeIndex ~= nil then
                subTypeIndex = animal.subTypeIndex
                break
            end
        end
        if subTypeIndex ~= nil then
            local subType = g_currentMission.animalSystem:getSubTypeByIndex(subTypeIndex)
            if subType ~= nil then
                eppTypeData = target.animalsTypeData[subType.typeIndex]
            end
        end
        Log:trace("RLAnimalMoveService.moveAnimals: EPP destination, eppTypeData=%s", tostring(eppTypeData))
    end

    local survivors, firstErrorCode = RLAnimalMoveService.filterMovableAnimals(
        source, target, animals, ownerFarmId, eppTypeData, AnimalMoveEvent.validate)

    if #survivors == 0 then
        -- All-rejected short-circuit: the callback fires HERE and the return is false. This
        -- path never arms the request helper, so it must not touch the in-flight flag; the
        -- frame's lock release on false is idempotent with any the callback performed.
        if firstErrorCode ~= nil then
            Log:debug("RLAnimalMoveService.moveAnimals: all %d animals rejected (firstErrorCode=%d), surfacing without dispatch",
                #animals, firstErrorCode)
            if callback ~= nil then
                if callbackTarget ~= nil then
                    callback(callbackTarget, firstErrorCode)
                else
                    callback(firstErrorCode)
                end
            end
        else
            Log:debug("RLAnimalMoveService.moveAnimals: no animals passed the filter (no error code), skipping dispatch")
        end
        return false
    end

    -- The request helper owns the subscribe, the watchdog and the unsubscribe. errorCode may
    -- be RLAnimalEventRequest.TIMEOUT_CODE on expiry, which is not MOVE_SUCCESS and so
    -- surfaces as a failure.
    local function onMoveResponse(errorCode)
        Log:trace("RLAnimalMoveService.onMoveResponse: errorCode=%s", tostring(errorCode))
        if errorCode ~= AnimalMoveEvent.MOVE_SUCCESS then
            Log:debug("RLAnimalMoveService.onMoveResponse: move failed, errorCode=%s", tostring(errorCode))
        else
            Log:debug("RLAnimalMoveService.onMoveResponse: move succeeded")
        end

        if callback ~= nil then
            if callbackTarget ~= nil then
                callback(callbackTarget, errorCode)
            else
                callback(errorCode)
            end
        end
    end

    local accepted = RLAnimalEventRequest.dispatch(
        AnimalMoveEvent,
        AnimalMoveEvent.new(source, target, survivors, moveType),
        onMoveResponse, nil, deps)
    if not accepted then
        Log:debug("RLAnimalMoveService.moveAnimals: dispatch rejected (same-class request in flight), no broadcast")
        return false
    end
    Log:trace("RLAnimalMoveService.moveAnimals: dispatched %d survivor(s) via request helper", #survivors)

    -- Exactly-one-broadcast: the client leg adds the message ONLY in pure SP; in MP the
    -- server :run is the sole broadcaster and this leg stays silent.
    local serverExists = g_server ~= nil
    local netIsRunning = serverExists and g_server.netIsRunning
    if RLAnimalMoveService.shouldClientBroadcast(serverExists, netIsRunning) then
        local plan = RLAnimalMoveService.resolveBroadcastPlan(moveType, #survivors)
        if plan ~= nil then
            local husbandryEndpoint = (plan.husbandryRole == "source") and source or target
            local nameEndpoint = (plan.nameRole == "source") and source or target
            Log:trace("RLAnimalMoveService.moveAnimals: client-leg broadcast (pure SP), key='%s'", plan.messageKey)
            RLAnimalMoveService.applyClientBroadcast(plan, husbandryEndpoint, nameEndpoint, #survivors)
        end
    else
        Log:trace("RLAnimalMoveService.moveAnimals: MP context, deferring broadcast to server :run")
    end

    return true
end


--- Map an AnimalMoveEvent error code to a localized error string.
--- @param errorCode number The error code from AnimalMoveEvent
--- @return string Localized error text, or a generic fallback for unknown codes
function RLAnimalMoveService.getErrorText(errorCode)
    if errorCode == RLAnimalEventRequest.TIMEOUT_CODE then
        Log:trace("RLAnimalMoveService.getErrorText: synthetic timeout code -> rl_ui_tradeRequestTimeout")
        return g_i18n:getText("rl_ui_tradeRequestTimeout")
    end
    if errorCode == RLAnimalMoveService.ERROR_ANIMAL_SICK then
        Log:trace("RLAnimalMoveService.getErrorText: client-only sick code -> rl_ui_moveErrorSick")
        return g_i18n:getText("rl_ui_moveErrorSick")
    end
    local key = RLAnimalMoveService.ERROR_CODE_MAPPING[errorCode]
    if key ~= nil then
        Log:trace("RLAnimalMoveService.getErrorText: code=%d -> key='%s'", errorCode, key)
        return g_i18n:getText(key)
    end
    Log:warning("RLAnimalMoveService.getErrorText: unknown errorCode=%s, using fallback", tostring(errorCode))
    return g_i18n:getText("rl_ui_moveErrorNotSupported")
end
