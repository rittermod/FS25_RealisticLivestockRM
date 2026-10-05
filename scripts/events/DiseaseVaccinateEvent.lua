--[[
    DiseaseVaccinateEvent.lua
    A player's request to vaccinate one animal against one disease. One-way and
    server-authoritative: the authority (singleplayer, a listen host) applies directly through
    sendEvent, a pure client sends the request and changes nothing, and the server re-checks and
    applies in run. Nothing is rebroadcast: the pen's flush carries the record and the farm balance
    the charge. The payload is the pen, the animal's identity and the disease title; the dose price
    is resolved on the applying machine.

    isServer, dispatchToServer, apply, chargeDose and sendEvent are seams a test may swap.
    RLDiseaseVaccination and g_diseaseManager are read at call time only.
]]

DiseaseVaccinateEvent = {}
local DiseaseVaccinateEvent_mt = Class(DiseaseVaccinateEvent, Event)
InitEventClass(DiseaseVaccinateEvent, "DiseaseVaccinateEvent")

local Log = RmLogging.getLogger("RLRM")

--- The permission a vaccination request needs.
DiseaseVaccinateEvent.PERMISSION = "tradeAnimals"


--- Why a request is refused before the dose: diseases off, or the rule's own refusal.
---@param animal table The live animal.
---@param title string The disease title requested.
---@return string|nil reason Nil when the dose is allowed.
---@return table|nil model The resolved registry entry, nil when diseases are off.
local function refusal(animal, title)
    if not g_diseaseManager.diseasesEnabled then
        Log:trace("DiseaseVaccinateEvent refusal: diseases off (title=%s farmId=%s uniqueId=%s)", tostring(title),
            tostring(animal.farmId), tostring(animal.uniqueId))
        return "DISEASES_OFF", nil
    end

    local model = g_diseaseManager:getDiseaseByTitle(title)
    local _, reason = RLDiseaseVaccination.check(animal, model)
    return reason, model
end


--- Build an empty event for the receiving side to read into.
---@return table event
function DiseaseVaccinateEvent.emptyNew()
    local self = Event.new(DiseaseVaccinateEvent_mt)
    Log:trace("DiseaseVaccinateEvent.emptyNew")
    return self
end


--- Build a vaccination request for one animal in one pen.
---@param object table The pen (husbandry placeable) holding the animal.
---@param animal table The animal, or its identity table.
---@param title string The disease title to vaccinate against.
---@return table event
function DiseaseVaccinateEvent.new(object, animal, title)
    local self = DiseaseVaccinateEvent.emptyNew()
    self.object = object
    self.animal = animal
    self.title = title
    Log:trace("DiseaseVaccinateEvent.new: title=%s uniqueId=%s farmId=%s", tostring(title),
        tostring(animal ~= nil and animal.uniqueId), tostring(animal ~= nil and animal.farmId))
    return self
end


--- Read the pen, the animal's identity and the title, then handle the request.
---@param streamId number The network stream.
---@param connection table The connection the request arrived on.
function DiseaseVaccinateEvent:readStream(streamId, connection)
    self.object = NetworkUtil.readNodeObject(streamId)
    self.animal = RLAnimalUtil.readStreamIdentifiers(streamId, connection)
    self.title = streamReadString(streamId)
    Log:trace("DiseaseVaccinateEvent:readStream: pen=%s uniqueId=%s title=%s", tostring(self.object),
        tostring(self.animal.uniqueId), tostring(self.title))
    self:run(connection)
end


--- Write the pen, the animal's identity and the title - never a price.
---@param streamId number The network stream.
---@param connection table The connection the request is sent on.
function DiseaseVaccinateEvent:writeStream(streamId, connection)
    NetworkUtil.writeNodeObject(streamId, self.object)
    RLAnimalUtil.writeStreamIdentifiers(self.animal, streamId, connection)
    streamWriteString(streamId, self.title)
    Log:trace("DiseaseVaccinateEvent:writeStream: uniqueId=%s title=%s", tostring(self.animal.uniqueId),
        tostring(self.title))
end


--- Handle a vaccination request on the server: validate the pen, the requester and the animal, then apply.
---@param connection table The connection the request arrived on.
function DiseaseVaccinateEvent:run(connection)
    local identifiers = self.animal

    if not DiseaseVaccinateEvent.isServer() then
        Log:warning("DiseaseVaccinateEvent:run: received on a non-server peer, dropping (pen=%s farmId=%s "
            .. "uniqueId=%s title=%s)", tostring(self.object), tostring(identifiers.farmId),
            tostring(identifiers.uniqueId), tostring(self.title))
        return
    end

    -- No method call on the object here: it may not have resolved on this machine.
    Log:debug("VACCINATE: request received pen=%s farmId=%s uniqueId=%s title=%s", tostring(self.object),
        tostring(identifiers.farmId), tostring(identifiers.uniqueId), tostring(self.title))

    local requesterName = (g_currentMission.userManager:getUserByConnection(connection) or {}).nickname or "unknown"

    if self.object == nil then
        Log:warning("DiseaseVaccinateEvent:run: the pen did not resolve, dropping (user='%s' farmId=%s "
            .. "uniqueId=%s title=%s)", tostring(requesterName), tostring(identifiers.farmId),
            tostring(identifiers.uniqueId), tostring(self.title))
        return
    end

    if type(self.object.getOwnerFarmId) ~= "function" or type(self.object.getClusterSystem) ~= "function" then
        Log:warning("DiseaseVaccinateEvent:run: object %s does not carry the pen accessors (stale node id?), "
            .. "dropping (user='%s' farmId=%s uniqueId=%s title=%s)",
            tostring(self.object), tostring(requesterName), tostring(identifiers.farmId),
            tostring(identifiers.uniqueId), tostring(self.title))
        return
    end

    local clusterSystem = self.object:getClusterSystem()
    if clusterSystem == nil or type(clusterSystem.animals) ~= "table" then
        Log:warning("DiseaseVaccinateEvent:run: object %s has no usable cluster system (torn down?), "
            .. "dropping (user='%s' farmId=%s uniqueId=%s title=%s)",
            tostring(self.object), tostring(requesterName), tostring(identifiers.farmId),
            tostring(identifiers.uniqueId), tostring(self.title))
        return
    end

    local penName = tostring(self.object.getName ~= nil and self.object:getName() or self.object)
    local ownerFarmId = self.object:getOwnerFarmId()
    local ok, reason, userName, userId, requesterFarmId =
        RLPermissionHelper.authorizeConnection(connection, DiseaseVaccinateEvent.PERMISSION, ownerFarmId)

    if not ok then
        Log:warning("DiseaseVaccinateEvent:run: %s for user '%s' (userId=%s, farmId=%s) on pen %s "
            .. "owned by farmId=%s, uniqueId=%s title=%s - dropping",
            tostring(reason), tostring(userName), tostring(userId), tostring(requesterFarmId),
            penName, tostring(ownerFarmId), tostring(identifiers.uniqueId), tostring(self.title))
        return
    end

    local animal = RLAnimalUtil.find(clusterSystem.animals, identifiers.farmId, identifiers.uniqueId,
        identifiers.country or identifiers.birthday.country)

    if animal == nil then
        Log:warning("DiseaseVaccinateEvent:run: animal not found in pen %s (farmId=%s uniqueId=%s user='%s' "
            .. "userId=%s ownerFarmId=%s title=%s) - dropping",
            penName, tostring(identifiers.farmId), tostring(identifiers.uniqueId), tostring(userName),
            tostring(userId), tostring(ownerFarmId), tostring(self.title))
        return
    end

    local refused, model = refusal(animal, self.title)

    if refused ~= nil then
        Log:warning("DiseaseVaccinateEvent:run: refusing, reason=%s (pen=%s ownerFarmId=%s farmId=%s uniqueId=%s "
            .. "title=%s user='%s' userId=%s) - dropping",
            tostring(refused), penName, tostring(ownerFarmId), tostring(identifiers.farmId),
            tostring(identifiers.uniqueId), tostring(self.title), tostring(userName), tostring(userId))
        return
    end

    Log:trace("DiseaseVaccinateEvent:run: authorized, applying (pen=%s uniqueId=%s title=%s)", penName,
        tostring(identifiers.uniqueId), tostring(self.title))
    DiseaseVaccinateEvent.apply(self.object, animal, model)
end


--- Vaccinate an animal: on the authority re-check and apply, on a pure client send the request.
---@param object table The pen holding the animal.
---@param animal table The live animal.
---@param title string The disease title to vaccinate against.
---@return boolean accepted True when applied here, or when the request was sent to the server.
function DiseaseVaccinateEvent.sendEvent(object, animal, title)
    if DiseaseVaccinateEvent.isServer() then
        -- Re-checked: the animal can have died, or diseases been switched off, since the caller last looked.
        local refused, model = refusal(animal, title)

        if refused ~= nil then
            Log:debug("VACCINATE: refused on the authority, reason=%s (title=%s uniqueId=%s farmId=%s)",
                tostring(refused), tostring(title), tostring(animal.uniqueId), tostring(animal.farmId))
            return false
        end

        local ok = DiseaseVaccinateEvent.apply(object, animal, model)
        Log:trace("DiseaseVaccinateEvent.sendEvent: authority applied, ok=%s (title=%s uniqueId=%s)", tostring(ok),
            tostring(title), tostring(animal.uniqueId))
        return ok
    end

    local event = DiseaseVaccinateEvent.new(object, animal, title)
    Log:debug("VACCINATE: requesting from the server pen=%s farmId=%s uniqueId=%s title=%s",
        tostring(object ~= nil and object.getName ~= nil and object:getName() or object),
        tostring(animal.farmId), tostring(animal.uniqueId), tostring(title))
    DiseaseVaccinateEvent.dispatchToServer(event)
    return true
end


--- Apply one dose, then charge the pen owner. Unguarded: callers re-check first.
---@param object table The pen holding the animal.
---@param animal table The live animal.
---@param model table The disease's registry entry, carrying `vaccine`.
---@return boolean ok False when a step raised; the step's error is logged.
---@return string|nil outcome The rule's outcome, nil when the rule raised.
function DiseaseVaccinateEvent.apply(object, animal, model)
    local outcome = nil

    local ok = RmSafeUtils.safeCall("DiseaseVaccinateEvent.apply", function()
        -- Rule first and money last, so a raise in the rule charges nothing.
        outcome = RLDiseaseVaccination.apply(animal, model)

        local cost = model.vaccine.cost
        local ownerFarmId = object:getOwnerFarmId()
        local penName = tostring(object.getName ~= nil and object:getName() or object)

        if type(ownerFarmId) ~= "number" or ownerFarmId <= 0 or ownerFarmId > FarmManager.MAX_NUM_FARMS then
            Log:warning("DiseaseVaccinateEvent.apply: the owner farmId=%s of pen %s is not a real farm, dose "
                .. "applied with no charge (title=%s uniqueId=%s outcome=%s cost=%s)",
                tostring(ownerFarmId), penName, tostring(model.title), tostring(animal.uniqueId),
                tostring(outcome), tostring(cost))
        elseif cost <= 0 then
            Log:trace("DiseaseVaccinateEvent.apply: free dose, nothing to charge (title=%s uniqueId=%s)",
                tostring(model.title), tostring(animal.uniqueId))
        else
            DiseaseVaccinateEvent.chargeDose(ownerFarmId, cost)
        end

        Log:debug("VACCINATE: applied pen=%s title=%s outcome=%s cost=%s ownerFarmId=%s farmId=%s uniqueId=%s",
            penName, tostring(model.title), tostring(outcome), tostring(cost), tostring(ownerFarmId),
            tostring(animal.farmId), tostring(animal.uniqueId))
    end)

    return ok, outcome
end


--- Charge a dose to a farm as medicine, with the change shown to the player. No balance check.
---@param farmId number The paying farm, already range-checked.
---@param amount number The positive dose price.
function DiseaseVaccinateEvent.chargeDose(farmId, amount)
    Log:trace("DiseaseVaccinateEvent.chargeDose: farmId=%s amount=%s", tostring(farmId), tostring(amount))
    g_currentMission:addMoney(0 - amount, farmId, MoneyType.MEDICINE, true, true)
end


--- Whether this machine is the authority.
---@return boolean onServer
function DiseaseVaccinateEvent.isServer()
    local onServer = g_server ~= nil
    Log:trace("DiseaseVaccinateEvent.isServer: %s", tostring(onServer))
    return onServer
end


--- Send a request to the server over this client's connection.
---@param event table The request to send.
function DiseaseVaccinateEvent.dispatchToServer(event)
    Log:trace("DiseaseVaccinateEvent.dispatchToServer: uniqueId=%s title=%s",
        tostring(event.animal ~= nil and event.animal.uniqueId), tostring(event.title))
    g_client:getServerConnection():sendEvent(event)
end
