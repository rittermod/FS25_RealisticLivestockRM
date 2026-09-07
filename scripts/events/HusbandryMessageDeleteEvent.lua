--[[
    HusbandryMessageDeleteEvent.lua
    Network event for deleting one or more RL messages from a husbandry.

    Pattern A: the caller (RLMessageService.deleteMessages) MUST mutate local state
    BEFORE calling sendEvent; run() applies the mutation on every receiver that is not
    the original sender, which its own broadcastEvent excludes via ignoreConnection.

    Server-side validation (permission + farm scope) is the authoritative boundary; the
    frame-side UI gate in RLMenuMessagesFrame is a secondary UX helper only.
]]

HusbandryMessageDeleteEvent = {}
local HusbandryMessageDeleteEvent_mt = Class(HusbandryMessageDeleteEvent, Event)

InitEventClass(HusbandryMessageDeleteEvent, "HusbandryMessageDeleteEvent")

local Log = RmLogging.getLogger("RLRM")

--- Empty constructor used during event deserialization.
--- @return table self
function HusbandryMessageDeleteEvent.emptyNew()
    Log:trace("HusbandryMessageDeleteEvent.emptyNew")
    local self = Event.new(HusbandryMessageDeleteEvent_mt)
    return self
end

--- Construct a new event carrying a husbandry and the list of uniqueIds to delete.
--- @param husbandry table Husbandry placeable (must have spec_husbandryAnimals)
--- @param uniqueIds table Array of message uniqueIds (int, UInt16 on the wire)
--- @return table self
function HusbandryMessageDeleteEvent.new(husbandry, uniqueIds)
    Log:trace("HusbandryMessageDeleteEvent.new: %d id(s)",
        (uniqueIds ~= nil and #uniqueIds) or 0)
    local self = HusbandryMessageDeleteEvent.emptyNew()
    self.husbandry = husbandry
    self.uniqueIds = uniqueIds or {}
    return self
end

--- Serialize as nodeObject(husbandry) + UInt16(count) + count * UInt16(uniqueId), the
--- same id width HusbandryMessageStateEvent uses.
--- @param streamId number Network stream id
--- @param connection table Network connection (unused, required by Event API)
function HusbandryMessageDeleteEvent:writeStream(streamId, connection)
    local count = #self.uniqueIds
    Log:trace("HusbandryMessageDeleteEvent:writeStream: %d id(s) for husbandry '%s'",
        count, tostring(self.husbandry ~= nil and self.husbandry:getName() or "nil"))

    NetworkUtil.writeNodeObject(streamId, self.husbandry)
    streamWriteUInt16(streamId, count)

    for i = 1, count do
        streamWriteUInt16(streamId, self.uniqueIds[i])
    end
end

--- Deserialize the event from the network and run it on this machine.
--- @param streamId number Network stream id
--- @param connection table Network connection (passed through to run)
function HusbandryMessageDeleteEvent:readStream(streamId, connection)
    self.husbandry = NetworkUtil.readNodeObject(streamId)

    local count = streamReadUInt16(streamId)
    self.uniqueIds = {}

    for i = 1, count do
        self.uniqueIds[i] = streamReadUInt16(streamId)
    end

    Log:trace("HusbandryMessageDeleteEvent:readStream: %d id(s) for husbandry '%s'",
        count, tostring(self.husbandry ~= nil and self.husbandry:getName() or "nil"))

    self:run(connection)
end

--- Validate a remote client's delete, rebroadcast to the other peers, then apply here.
--- Deleting an unknown uniqueId is a no-op, so the apply loop is idempotent.
--- @param connection table Network connection the event arrived on
function HusbandryMessageDeleteEvent:run(connection)
    -- readNodeObject can return nil (stale id) or a non-husbandry object sharing an id
    -- during a sell-placeable race, so the spec check is what proves it is livestock.
    if self.husbandry == nil or self.husbandry.spec_husbandryAnimals == nil then
        Log:warning("HusbandryMessageDeleteEvent:run: invalid husbandry (nil or not a livestock placeable), aborting")
        return
    end

    if not connection:getIsServer() then
        local userId = g_currentMission.userManager:getUniqueUserIdByConnection(connection)
        local userName = (g_currentMission.userManager:getUserByConnection(connection) or {}).nickname or "unknown"

        if not g_currentMission:getHasPlayerPermission("updateFarm", connection) then
            Log:warning("HusbandryMessageDeleteEvent:run: permission denied for user '%s' (userId=%s) on husbandry '%s'",
                tostring(userName), tostring(userId), tostring(self.husbandry:getName()))
            return
        end

        local userFarm = g_farmManager:getFarmForUniqueUserId(userId)
        if userFarm == nil or userFarm.farmId == nil then
            Log:warning("HusbandryMessageDeleteEvent:run: no farm lookup for user '%s' (userId=%s) on husbandry '%s', aborting",
                tostring(userName), tostring(userId), tostring(self.husbandry:getName()))
            return
        end

        local husbandryFarmId = self.husbandry:getOwnerFarmId()
        if userFarm.farmId ~= husbandryFarmId then
            Log:warning("HusbandryMessageDeleteEvent:run: farm scope mismatch for user '%s' (userId=%s, user farmId=%s) on husbandry '%s' (farmId=%s), aborting",
                tostring(userName), tostring(userId), tostring(userFarm.farmId),
                tostring(self.husbandry:getName()), tostring(husbandryFarmId))
            return
        end

        -- Everyone except the sender: it already mutated locally before sendEvent.
        g_server:broadcastEvent(
            HusbandryMessageDeleteEvent.new(self.husbandry, self.uniqueIds),
            nil, connection, nil)

        Log:debug("HusbandryMessageDeleteEvent:run: validated client delete, rebroadcasting %d id(s) to other clients",
            #self.uniqueIds)
    end

    for i = 1, #self.uniqueIds do
        self.husbandry:deleteRLMessage(self.uniqueIds[i])
    end

    Log:debug("HusbandryMessageDeleteEvent:run: applied %d delete(s) to husbandry '%s'",
        #self.uniqueIds, tostring(self.husbandry:getName()))

    -- Refresh an open Messages frame; nil-guarded for early lifecycle / never opened.
    if g_rlMenu ~= nil and g_rlMenu.messagesFrame ~= nil
       and g_rlMenu.messagesFrame.refreshIfOpen ~= nil then
        g_rlMenu.messagesFrame:refreshIfOpen()
    end
end

--- Broadcast to clients if we are the server, otherwise upload to the server.
--- @param husbandry table Husbandry placeable
--- @param uniqueIds table Array of uniqueIds to delete
function HusbandryMessageDeleteEvent.sendEvent(husbandry, uniqueIds)
    if husbandry == nil or uniqueIds == nil or #uniqueIds == 0 then
        Log:warning("HusbandryMessageDeleteEvent.sendEvent: invalid args, skipping")
        return
    end

    Log:trace("HusbandryMessageDeleteEvent.sendEvent: dispatching %d id(s)", #uniqueIds)

    if g_server ~= nil then
        g_server:broadcastEvent(HusbandryMessageDeleteEvent.new(husbandry, uniqueIds))
    else
        g_client:getServerConnection():sendEvent(HusbandryMessageDeleteEvent.new(husbandry, uniqueIds))
    end
end
