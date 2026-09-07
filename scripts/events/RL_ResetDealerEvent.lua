--[[
    RL_ResetDealerEvent.lua
    Network event for resetting the animal dealer or AI animal pool.

    Implements a client-to-server REQUEST pattern (NOT Pattern A).
    The server generates new random animals, so the client cannot
    mutate-first. The client sends a request, the server validates
    admin (masterUser) permission, executes the reset, and broadcasts
    the resulting state to all clients via AnimalSystemStateEvent.

    Permission model: masterUser only (global admin action, not per-farm).
    Resetting the dealer is a global admin action affecting all farms,
    not a per-farm trade operation.
]]

RL_ResetDealerEvent = {}

RL_ResetDealerEvent.TYPE_DEALER = 1
RL_ResetDealerEvent.TYPE_AI_ANIMALS = 2

local RL_ResetDealerEvent_mt = Class(RL_ResetDealerEvent, Event)
InitEventClass(RL_ResetDealerEvent, "RL_ResetDealerEvent")

local Log = RmLogging.getLogger("RLRM")


function RL_ResetDealerEvent.emptyNew()
    Log:trace("RL_ResetDealerEvent.emptyNew")
    local self = Event.new(RL_ResetDealerEvent_mt)
    return self
end


function RL_ResetDealerEvent.new(resetType)
    Log:trace("RL_ResetDealerEvent.new: resetType=%d", resetType)
    local self = RL_ResetDealerEvent.emptyNew()
    self.resetType = resetType
    return self
end


--- Wire format: UInt8(resetType)
function RL_ResetDealerEvent:writeStream(streamId, connection)
    Log:trace("RL_ResetDealerEvent:writeStream: resetType=%d", self.resetType)
    streamWriteUInt8(streamId, self.resetType)
end


function RL_ResetDealerEvent:readStream(streamId, connection)
    self.resetType = streamReadUInt8(streamId)
    Log:trace("RL_ResetDealerEvent:readStream: resetType=%d", self.resetType)
    self:run(connection)
end


--- Server receives a reset request from a remote client: validate masterUser permission,
--- execute, and broadcast the new state. This event itself is never rebroadcast.
function RL_ResetDealerEvent:run(connection)
    local userName = "unknown"
    local user = g_currentMission.userManager:getUserByConnection(connection)
    if user ~= nil then
        userName = user.nickname or userName
    end

    local isMasterUser = connection:getIsServer()
        or g_currentMission.userManager:getIsConnectionMasterUser(connection)

    if not isMasterUser then
        Log:warning("RL_ResetDealerEvent:run: permission denied for user '%s' (resetType=%d) - not admin",
            tostring(userName), self.resetType)
        return
    end

    Log:info("RL_ResetDealerEvent:run: admin '%s' authorized, executing reset type %d",
        tostring(userName), self.resetType)

    RL_ResetDealerEvent.executeOnServer(self.resetType)
end


--- Execute the reset on the server and broadcast the new state. Called by sendEvent on
--- host/SP, or by run() after validating a remote client's request.
function RL_ResetDealerEvent.executeOnServer(resetType)
    local animalSystem = g_currentMission.animalSystem

    if resetType == RL_ResetDealerEvent.TYPE_DEALER then

        animalSystem:removeAllSaleAnimals()

        local totalAnimals = 0
        local typeCount = 0

        for animalTypeIndex, animals in pairs(animalSystem.animals) do

            for i = 1, animalSystem.maxDealerAnimals do
                local animal = animalSystem:createNewSaleAnimal(animalTypeIndex)
                if animal ~= nil then table.insert(animals, animal) end
            end

            animalSystem.animals[animalTypeIndex] = animals
            totalAnimals = totalAnimals + #animals
            typeCount = typeCount + 1

        end

        Log:info("RL_ResetDealerEvent: reset dealer - %d animals across %d types", totalAnimals, typeCount)

    elseif resetType == RL_ResetDealerEvent.TYPE_AI_ANIMALS then

        for index in pairs(animalSystem.aiAnimals) do
            animalSystem.aiAnimals[index] = {}
        end

        local totalAnimals = 0
        local typeCount = 0

        for animalTypeIndex, animals in pairs(animalSystem.aiAnimals) do

            for i = 1, 15 do
                local animal = animalSystem:createNewAIAnimal(animalTypeIndex)
                if animal ~= nil then table.insert(animals, animal) end
            end

            totalAnimals = totalAnimals + #animals
            typeCount = typeCount + 1

        end

        Log:info("RL_ResetDealerEvent: reset AI animals - %d animals across %d types", totalAnimals, typeCount)

    else
        Log:warning("RL_ResetDealerEvent: unknown resetType %d, ignoring", resetType)
        return
    end

    g_server:broadcastEvent(AnimalSystemStateEvent.new(animalSystem.countries, animalSystem.animals, animalSystem.aiAnimals))
    Log:debug("RL_ResetDealerEvent: broadcast AnimalSystemStateEvent after reset type %d", resetType)
end


--- Dispatch helper. Host/SP executes directly; client sends request to server.
function RL_ResetDealerEvent.sendEvent(resetType)
    Log:debug("RL_ResetDealerEvent.sendEvent: type=%d", resetType)

    if g_server ~= nil then
        RL_ResetDealerEvent.executeOnServer(resetType)
    else
        g_client:getServerConnection():sendEvent(RL_ResetDealerEvent.new(resetType))
    end
end
