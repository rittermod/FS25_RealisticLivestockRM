--[[
    RLHerdsmanRuleDeleteEvent.lua
    Network event for deleting a Herdsman rule record by id.

    Pattern A: the caller (RLHerdsmanRuleService:delete) MUST mutate local state BEFORE
    calling sendEvent; run() removes the rule on every receiver that is not the original
    sender, and the server rebroadcasts with ignoreConnection=sender.

    The payload is JUST the id, so the farmId for the scope check is derived from the
    server's stored record rather than the wire. An id the server does not hold is a
    benign no-op (a late joiner's delete), not a rejection.
]]

RLHerdsmanRuleDeleteEvent = {}
local RLHerdsmanRuleDeleteEvent_mt = Class(RLHerdsmanRuleDeleteEvent, Event)

InitEventClass(RLHerdsmanRuleDeleteEvent, "RLHerdsmanRuleDeleteEvent")

local Log = RmLogging.getLogger("RLRM")

--- Empty constructor used during deserialization.
---@return table self
function RLHerdsmanRuleDeleteEvent.emptyNew()
    Log:trace("RLHerdsmanRuleDeleteEvent.emptyNew")
    local self = Event.new(RLHerdsmanRuleDeleteEvent_mt)
    return self
end

--- Construct a new event carrying the id to delete.
---@param id string rule id to delete
---@return table self
function RLHerdsmanRuleDeleteEvent.new(id)
    Log:trace("RLHerdsmanRuleDeleteEvent.new: id=%s", tostring(id))
    local self = RLHerdsmanRuleDeleteEvent.emptyNew()
    self.id = id
    return self
end

--- Authorized iff the sender holds the trade permission and is on the stored rule's farm.
---@param hasTradePermission boolean sender holds the tradeAnimals permission
---@param senderFarmId number|nil the sending player's resolved farm id
---@param ruleFarmId number|nil the STORED rule's owning farm id
---@return boolean authorized
function RLHerdsmanRuleDeleteEvent.isAuthorized(hasTradePermission, senderFarmId, ruleFarmId)
    return hasTradePermission == true
        and senderFarmId ~= nil
        and ruleFarmId ~= nil
        and senderFarmId == ruleFarmId
end

--- Serialize the id only.
function RLHerdsmanRuleDeleteEvent:writeStream(streamId, connection)
    streamWriteString(streamId, self.id or "")
    Log:trace("RLHerdsmanRuleDeleteEvent:writeStream: id=%s", tostring(self.id))
end

--- Deserialize + run on this machine.
function RLHerdsmanRuleDeleteEvent:readStream(streamId, connection)
    self.id = streamReadString(streamId)
    Log:trace("RLHerdsmanRuleDeleteEvent:readStream: id=%s", tostring(self.id))
    self:run(connection)
end

--- Resolve user context for warning-path decisions.
---@param connection table
---@return string userName, any userId
local function getUserContext(connection)
    local userId = g_currentMission.userManager:getUniqueUserIdByConnection(connection)
    local userName = (g_currentMission.userManager:getUserByConnection(connection) or {}).nickname or "unknown"
    return userName, userId
end

--- Validate a remote client's delete, rebroadcast to the other peers, then apply here.
function RLHerdsmanRuleDeleteEvent:run(connection)
    local id = self.id
    if id == nil or id == "" then
        Log:warning("RLHerdsmanRuleDeleteEvent:run: malformed payload (id=%s); aborting", tostring(id))
        return
    end

    if not connection:getIsServer() then
        local userName, userId = getUserContext(connection)

        if not g_currentMission:getHasPlayerPermission("tradeAnimals", connection) then
            Log:warning("RLHerdsmanRuleDeleteEvent:run: permission 'tradeAnimals' denied for user '%s' (userId=%s) rule id=%s",
                tostring(userName), tostring(userId), tostring(id))
            return
        end

        if g_rlHerdsmanRuleService == nil then
            Log:warning("RLHerdsmanRuleDeleteEvent:run: g_rlHerdsmanRuleService is nil on server; cannot validate id=%s",
                tostring(id))
            return
        end

        -- _rawGetById avoids an unnecessary deep-clone on this read-only check.
        local stored = g_rlHerdsmanRuleService:_rawGetById(id)
        if stored == nil then
            Log:warning("RLHerdsmanRuleDeleteEvent:run: unknown id '%s' from user '%s' (userId=%s); no-op",
                tostring(id), tostring(userName), tostring(userId))
            return
        end

        if stored.farmId ~= nil then
            local userFarm = g_farmManager:getFarmForUniqueUserId(userId)
            if userFarm == nil or userFarm.farmId == nil then
                Log:warning("RLHerdsmanRuleDeleteEvent:run: no farm lookup for user '%s' (userId=%s); aborting delete id=%s farmId=%s",
                    tostring(userName), tostring(userId), tostring(id), tostring(stored.farmId))
                return
            end
            if userFarm.farmId ~= stored.farmId then
                Log:warning("RLHerdsmanRuleDeleteEvent:run: farm-scope mismatch for user '%s' (userId=%s, userFarmId=%s) rule id=%s storedFarmId=%s",
                    tostring(userName), tostring(userId), tostring(userFarm.farmId),
                    tostring(id), tostring(stored.farmId))
                return
            end
        end

        -- Everyone except the sender: it already mutated locally before sendEvent.
        g_server:broadcastEvent(
            RLHerdsmanRuleDeleteEvent.new(id),
            nil, connection, nil)

        Log:debug("RLHerdsmanRuleDeleteEvent:run: validated delete from user '%s' (userId=%s), rebroadcasting id=%s",
            tostring(userName), tostring(userId), tostring(id))
    end

    if g_rlHerdsmanRuleService == nil then
        Log:warning("RLHerdsmanRuleDeleteEvent:run: g_rlHerdsmanRuleService is nil; skipping apply for id=%s",
            tostring(id))
        return
    end

    local applied = g_rlHerdsmanRuleService:applyIncomingDelete(id)
    if applied then
        Log:debug("RLHerdsmanRuleDeleteEvent:run: applied delete id=%s", tostring(id))
    else
        Log:trace("RLHerdsmanRuleDeleteEvent:run: no-op delete id=%s (already gone)", tostring(id))
    end

    -- Refresh an open Herdsman menu frame; nil-guarded for early lifecycle / never opened.
    if g_rlMenu ~= nil and g_rlMenu.herdsmanFrame ~= nil
       and g_rlMenu.herdsmanFrame.refreshIfOpen ~= nil then
        g_rlMenu.herdsmanFrame:refreshIfOpen()
    end
end

--- Broadcast to clients if we are the server, otherwise upload to the server.
---@param id string rule id to delete
function RLHerdsmanRuleDeleteEvent.sendEvent(id)
    if id == nil or id == "" then
        Log:warning("RLHerdsmanRuleDeleteEvent.sendEvent: invalid id=%s; skipping", tostring(id))
        return
    end

    Log:trace("RLHerdsmanRuleDeleteEvent.sendEvent: dispatching id=%s", tostring(id))

    if g_server ~= nil then
        g_server:broadcastEvent(RLHerdsmanRuleDeleteEvent.new(id))
    elseif g_client ~= nil then
        local conn = g_client:getServerConnection()
        if conn == nil then
            Log:warning("RLHerdsmanRuleDeleteEvent.sendEvent: g_client has no server connection; dropping dispatch id=%s",
                tostring(id))
            return
        end
        conn:sendEvent(RLHerdsmanRuleDeleteEvent.new(id))
    else
        Log:trace("RLHerdsmanRuleDeleteEvent.sendEvent: neither g_server nor g_client set; offline path, no dispatch")
    end
end
