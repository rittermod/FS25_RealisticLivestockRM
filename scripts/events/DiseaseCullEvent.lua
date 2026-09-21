--[[
    DiseaseCullEvent.lua
    A player's request to cull a sick animal from its pen. One-way and server-authoritative: the
    authority (singleplayer, a listen host) applies directly through sendEvent, a pure client sends
    the request and changes nothing, and the server re-checks and applies in run. Nothing is
    rebroadcast: the pen's flush carries the removal, the message chokepoint the DEATH line and the
    farm balance the salvage. The payload is the pen and the animal's identity only; the salvage is
    priced on the applying machine.

    Tests swap isServer, dispatchToServer, apply and sendEvent, and record the addMoney call that
    bookSalvage makes. RLDiseaseCull is sourced after this file, so it is read at call time only.
]]

DiseaseCullEvent = {}
local DiseaseCullEvent_mt = Class(DiseaseCullEvent, Event)
InitEventClass(DiseaseCullEvent, "DiseaseCullEvent")

local Log = RmLogging.getLogger("RLRM")

--- The permission a cull request needs - the one the Diseases button is gated on.
DiseaseCullEvent.PERMISSION = "tradeAnimals"


--- Build an empty event for the receiving side to read into.
---@return table event
function DiseaseCullEvent.emptyNew()
    local self = Event.new(DiseaseCullEvent_mt)
    Log:trace("DiseaseCullEvent.emptyNew")
    return self
end


--- Build a cull request for one animal in one pen.
---@param object table The pen (husbandry placeable) holding the animal.
---@param animal table The animal, or its identity table.
---@return table event
function DiseaseCullEvent.new(object, animal)
    local self = DiseaseCullEvent.emptyNew()
    self.object = object
    self.animal = animal
    Log:trace("DiseaseCullEvent.new: uniqueId=%s farmId=%s", tostring(animal ~= nil and animal.uniqueId),
        tostring(animal ~= nil and animal.farmId))
    return self
end


--- Read the pen and the animal's identity, then handle the request.
---@param streamId number The network stream.
---@param connection table The connection the request arrived on.
function DiseaseCullEvent:readStream(streamId, connection)
    self.object = NetworkUtil.readNodeObject(streamId)
    self.animal = RLAnimalUtil.readStreamIdentifiers(streamId, connection)
    Log:trace("DiseaseCullEvent:readStream: pen=%s uniqueId=%s", tostring(self.object),
        tostring(self.animal.uniqueId))
    self:run(connection)
end


--- Write the pen and the animal's identity - nothing else travels.
---@param streamId number The network stream.
---@param connection table The connection the request is sent on.
function DiseaseCullEvent:writeStream(streamId, connection)
    NetworkUtil.writeNodeObject(streamId, self.object)
    RLAnimalUtil.writeStreamIdentifiers(self.animal, streamId, connection)
    Log:trace("DiseaseCullEvent:writeStream: uniqueId=%s", tostring(self.animal.uniqueId))
end


--- Handle a cull request on the server: validate the pen, the requester and the animal, then apply.
---@param connection table The connection the request arrived on.
function DiseaseCullEvent:run(connection)
    local identifiers = self.animal

    if not DiseaseCullEvent.isServer() then
        Log:warning("DiseaseCullEvent:run: received on a non-server peer, dropping (pen=%s farmId=%s uniqueId=%s)",
            tostring(self.object), tostring(identifiers.farmId), tostring(identifiers.uniqueId))
        return
    end

    -- No method call on the object here: it may not have resolved on this machine.
    Log:debug("CULL: request received pen=%s farmId=%s uniqueId=%s", tostring(self.object),
        tostring(identifiers.farmId), tostring(identifiers.uniqueId))

    local requesterName = (g_currentMission.userManager:getUserByConnection(connection) or {}).nickname or "unknown"

    if self.object == nil then
        Log:warning("DiseaseCullEvent:run: the pen did not resolve, dropping (user='%s' farmId=%s uniqueId=%s)",
            tostring(requesterName), tostring(identifiers.farmId), tostring(identifiers.uniqueId))
        return
    end

    if type(self.object.getOwnerFarmId) ~= "function" or type(self.object.getClusterSystem) ~= "function" then
        Log:warning("DiseaseCullEvent:run: object %s does not carry the pen accessors (stale node id?), "
            .. "dropping (user='%s' farmId=%s uniqueId=%s)",
            tostring(self.object), tostring(requesterName), tostring(identifiers.farmId),
            tostring(identifiers.uniqueId))
        return
    end

    local clusterSystem = self.object:getClusterSystem()
    if clusterSystem == nil or type(clusterSystem.animals) ~= "table" then
        Log:warning("DiseaseCullEvent:run: object %s has no usable cluster system (torn down?), "
            .. "dropping (user='%s' farmId=%s uniqueId=%s)",
            tostring(self.object), tostring(requesterName), tostring(identifiers.farmId),
            tostring(identifiers.uniqueId))
        return
    end

    local penName = tostring(self.object.getName ~= nil and self.object:getName() or self.object)
    local ownerFarmId = self.object:getOwnerFarmId()
    local ok, reason, userName, userId, requesterFarmId =
        RLPermissionHelper.authorizeConnection(connection, DiseaseCullEvent.PERMISSION, ownerFarmId)

    if not ok then
        Log:warning("DiseaseCullEvent:run: %s for user '%s' (userId=%s, farmId=%s) on pen %s "
            .. "owned by farmId=%s, uniqueId=%s - dropping",
            tostring(reason), tostring(userName), tostring(userId), tostring(requesterFarmId),
            penName, tostring(ownerFarmId), tostring(identifiers.uniqueId))
        return
    end

    local animal = RLAnimalUtil.find(clusterSystem.animals, identifiers.farmId, identifiers.uniqueId,
        identifiers.country or identifiers.birthday.country)

    if animal == nil then
        Log:warning("DiseaseCullEvent:run: animal not found in pen %s (farmId=%s uniqueId=%s user='%s' "
            .. "userId=%s ownerFarmId=%s) - dropping",
            penName, tostring(identifiers.farmId), tostring(identifiers.uniqueId), tostring(userName),
            tostring(userId), tostring(ownerFarmId))
        return
    end

    local allowed, refusal = RLDiseaseCull.check(animal)

    if not allowed then
        Log:warning("DiseaseCullEvent:run: refusing, reason=%s (pen=%s ownerFarmId=%s farmId=%s uniqueId=%s "
            .. "user='%s' userId=%s) - dropping",
            tostring(refusal), penName, tostring(ownerFarmId), tostring(identifiers.farmId),
            tostring(identifiers.uniqueId), tostring(userName), tostring(userId))
        return
    end

    Log:trace("DiseaseCullEvent:run: authorized, applying (pen=%s uniqueId=%s)", penName,
        tostring(identifiers.uniqueId))
    DiseaseCullEvent.apply(self.object, animal)
end


--- Cull an animal: on the authority re-check and apply, on a pure client send the request.
---@param object table The pen holding the animal.
---@param animal table The live animal.
---@return boolean accepted True when culled here, or when the request was sent to the server.
function DiseaseCullEvent.sendEvent(object, animal)
    if DiseaseCullEvent.isServer() then
        -- Re-checked: the animal can have died or recovered while the dialog was open.
        local ok, reason = RLDiseaseCull.check(animal)

        if not ok then
            Log:debug("CULL: refused on the authority, reason=%s (uniqueId=%s farmId=%s)", tostring(reason),
                tostring(animal.uniqueId), tostring(animal.farmId))
            return false
        end

        local culled = DiseaseCullEvent.apply(object, animal)
        Log:trace("DiseaseCullEvent.sendEvent: authority applied, culled=%s (uniqueId=%s)", tostring(culled),
            tostring(animal.uniqueId))
        return culled
    end

    local event = DiseaseCullEvent.new(object, animal)
    Log:debug("CULL: requesting from the server pen=%s farmId=%s uniqueId=%s",
        tostring(object ~= nil and object.getName ~= nil and object:getName() or object),
        tostring(animal.farmId), tostring(animal.uniqueId))
    DiseaseCullEvent.dispatchToServer(event)
    return true
end


--- Apply a cull: kill the animal, flush the pen and book the salvage. Unguarded: callers run check first.
---@param object table The pen holding the animal.
---@param animal table The live animal to cull.
---@return boolean culled False when a step raised; the step's error is logged.
---@return number salvage The salvage priced before the death, 0 when nothing was priced.
function DiseaseCullEvent.apply(object, animal)
    local salvage = 0

    local culled = RmSafeUtils.safeCall("DiseaseCullEvent.apply", function()
        -- Salvage before the death and money last, so a raise before the payout pays nothing for
        -- an animal that was not culled.
        salvage = RLDiseaseCull.salvageFor(animal)
        local sellPrice = animal:getSellPrice()

        animal:die(RLDiseaseCull.DEATH_REASON)

        -- Flush now rather than on the pen's next update: the Info list re-queries in this frame.
        object:getClusterSystem():updateNow()

        local ownerFarmId = object:getOwnerFarmId()
        local penName = tostring(object.getName ~= nil and object:getName() or object)

        if type(ownerFarmId) ~= "number" or ownerFarmId <= 0 or ownerFarmId > FarmManager.MAX_NUM_FARMS then
            Log:warning("DiseaseCullEvent.apply: the owner farmId=%s of pen %s is not a real farm, culled with "
                .. "no salvage (uniqueId=%s salvage=%s)",
                tostring(ownerFarmId), penName, tostring(animal.uniqueId), tostring(salvage))
        elseif salvage <= 0 then
            Log:trace("DiseaseCullEvent.apply: no salvage to book (uniqueId=%s)", tostring(animal.uniqueId))
        else
            DiseaseCullEvent.bookSalvage(ownerFarmId, salvage)
        end

        Log:debug("CULL: applied pen=%s ownerFarmId=%s farmId=%s uniqueId=%s sellPrice=%s share=%s salvage=%s",
            penName, tostring(ownerFarmId),
            tostring(animal.farmId), tostring(animal.uniqueId), tostring(sellPrice),
            tostring(RLDiseaseCull.SALVAGE_SHARE), tostring(salvage))
    end)

    return culled, salvage
end


--- Credit the salvage to a farm as animal sales, with the change shown to the player.
---@param farmId number The receiving farm, already range-checked.
---@param amount number The positive salvage.
function DiseaseCullEvent.bookSalvage(farmId, amount)
    Log:trace("DiseaseCullEvent.bookSalvage: farmId=%s amount=%s", tostring(farmId), tostring(amount))
    g_currentMission:addMoney(amount, farmId, MoneyType.SOLD_ANIMALS, true, true)
end


--- Whether this machine is the authority.
---@return boolean onServer
function DiseaseCullEvent.isServer()
    local onServer = g_server ~= nil
    Log:trace("DiseaseCullEvent.isServer: %s", tostring(onServer))
    return onServer
end


--- Send a request to the server over this client's connection.
---@param event table The request to send.
function DiseaseCullEvent.dispatchToServer(event)
    Log:trace("DiseaseCullEvent.dispatchToServer: uniqueId=%s",
        tostring(event.animal ~= nil and event.animal.uniqueId))
    g_client:getServerConnection():sendEvent(event)
end
