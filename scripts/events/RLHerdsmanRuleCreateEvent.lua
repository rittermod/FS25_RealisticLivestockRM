--[[
    RLHerdsmanRuleCreateEvent.lua
    Network event for creating a Herdsman rule record.

    Pattern A: the caller (RLHerdsmanRuleService:create) MUST mutate local state BEFORE
    calling sendEvent; run() applies the mutation on every receiver that is not the
    original sender, and the server rebroadcasts with ignoreConnection=sender.

    Codec: RLHerdsmanRuleWire.writeRule / readRule. A server receiving from a remote
    client checks the tradeAnimals permission, the sender's farm against the rule's
    owning farmId, and a colliding id before it rebroadcasts.
]]

RLHerdsmanRuleCreateEvent = {}
local RLHerdsmanRuleCreateEvent_mt = Class(RLHerdsmanRuleCreateEvent, Event)

InitEventClass(RLHerdsmanRuleCreateEvent, "RLHerdsmanRuleCreateEvent")

local Log = RmLogging.getLogger("RLRM")

--- Empty constructor used during deserialization.
---@return table self
function RLHerdsmanRuleCreateEvent.emptyNew()
    Log:trace("RLHerdsmanRuleCreateEvent.emptyNew")
    local self = Event.new(RLHerdsmanRuleCreateEvent_mt)
    return self
end

--- Construct a new event carrying a whole rule record.
---@param rule table rule record (with id populated -- service-assigned via Utils.getUniqueId)
---@return table self
function RLHerdsmanRuleCreateEvent.new(rule)
    Log:trace("RLHerdsmanRuleCreateEvent.new: id=%s name=%s",
        tostring(rule and rule.id), tostring(rule and rule.name))
    local self = RLHerdsmanRuleCreateEvent.emptyNew()
    self.rule = rule
    return self
end

--- Authorized iff the sender holds the trade permission and is on the rule's owning farm.
---@param hasTradePermission boolean sender holds the tradeAnimals permission
---@param senderFarmId number|nil the sending player's resolved farm id
---@param ruleFarmId number|nil the rule's owning farm id
---@return boolean authorized
function RLHerdsmanRuleCreateEvent.isAuthorized(hasTradePermission, senderFarmId, ruleFarmId)
    return hasTradePermission == true
        and senderFarmId ~= nil
        and ruleFarmId ~= nil
        and senderFarmId == ruleFarmId
end

--- Serialize via the shared rule wire codec.
function RLHerdsmanRuleCreateEvent:writeStream(streamId, connection)
    if self.rule == nil then
        Log:warning("RLHerdsmanRuleCreateEvent:writeStream: nil rule payload (nothing to write)")
        return
    end
    Log:trace("RLHerdsmanRuleCreateEvent:writeStream: id=%s", tostring(self.rule.id))
    RLHerdsmanRuleWire.writeRule(streamId, self.rule)
end

--- Deserialize + run on this machine.
function RLHerdsmanRuleCreateEvent:readStream(streamId, connection)
    self.rule = RLHerdsmanRuleWire.readRule(streamId)
    Log:trace("RLHerdsmanRuleCreateEvent:readStream: id=%s name=%s",
        tostring(self.rule and self.rule.id), tostring(self.rule and self.rule.name))
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

--- Validate a remote client's payload, rebroadcast to the other peers, then apply here.
function RLHerdsmanRuleCreateEvent:run(connection)
    local rule = self.rule
    if rule == nil or rule.id == nil or rule.id == "" then
        Log:warning("RLHerdsmanRuleCreateEvent:run: malformed payload (id=%s); aborting",
            tostring(rule and rule.id))
        return
    end

    if not connection:getIsServer() then
        local userName, userId = getUserContext(connection)

        local hasTradePermission = g_currentMission:getHasPlayerPermission("tradeAnimals", connection)

        -- A stale or absent farm lookup is real in MP; the predicate treats nil as unauthorized.
        local userFarm = g_farmManager:getFarmForUniqueUserId(userId)
        local senderFarmId = (userFarm ~= nil) and userFarm.farmId or nil

        if not RLHerdsmanRuleCreateEvent.isAuthorized(hasTradePermission, senderFarmId, rule.farmId) then
            Log:warning("RLHerdsmanRuleCreateEvent:run: create rejected for user '%s' (userId=%s) -- permission=%s senderFarmId=%s ruleFarmId=%s rule id=%s",
                tostring(userName), tostring(userId), tostring(hasTradePermission),
                tostring(senderFarmId), tostring(rule.farmId), tostring(rule.id))
            return
        end

        -- _rawGetById avoids an unnecessary deep-clone on this read-only check.
        if g_rlHerdsmanRuleService ~= nil and g_rlHerdsmanRuleService:_rawGetById(rule.id) ~= nil then
            Log:warning("RLHerdsmanRuleCreateEvent:run: duplicate id '%s' for user '%s' (userId=%s); rejecting create before rebroadcast",
                tostring(rule.id), tostring(userName), tostring(userId))
            return
        end

        -- Everyone except the sender: it already mutated locally before sendEvent.
        g_server:broadcastEvent(
            RLHerdsmanRuleCreateEvent.new(rule),
            nil, connection, nil)

        Log:debug("RLHerdsmanRuleCreateEvent:run: validated create from user '%s', rebroadcasting id=%s",
            tostring(userName), tostring(rule.id))
    end

    if g_rlHerdsmanRuleService == nil then
        Log:warning("RLHerdsmanRuleCreateEvent:run: g_rlHerdsmanRuleService is nil; skipping apply for id=%s",
            tostring(rule.id))
        return
    end

    g_rlHerdsmanRuleService:applyIncomingCreate(rule)
    Log:debug("RLHerdsmanRuleCreateEvent:run: applied create id=%s name=%s",
        tostring(rule.id), tostring(rule.name))

    -- Refresh an open Herdsman menu frame; nil-guarded for early lifecycle / never opened.
    if g_rlMenu ~= nil and g_rlMenu.herdsmanFrame ~= nil
       and g_rlMenu.herdsmanFrame.refreshIfOpen ~= nil then
        g_rlMenu.herdsmanFrame:refreshIfOpen()
    end
end

--- Broadcast to clients if we are the server, otherwise upload to the server.
---@param rule table rule record (with id populated)
function RLHerdsmanRuleCreateEvent.sendEvent(rule)
    if rule == nil or rule.id == nil or rule.id == "" then
        Log:warning("RLHerdsmanRuleCreateEvent.sendEvent: invalid payload (id=%s); skipping",
            tostring(rule and rule.id))
        return
    end

    Log:trace("RLHerdsmanRuleCreateEvent.sendEvent: dispatching id=%s", tostring(rule.id))

    if g_server ~= nil then
        g_server:broadcastEvent(RLHerdsmanRuleCreateEvent.new(rule))
    elseif g_client ~= nil then
        local conn = g_client:getServerConnection()
        if conn == nil then
            Log:warning("RLHerdsmanRuleCreateEvent.sendEvent: g_client has no server connection; dropping dispatch id=%s",
                tostring(rule.id))
            return
        end
        conn:sendEvent(RLHerdsmanRuleCreateEvent.new(rule))
    else
        Log:trace("RLHerdsmanRuleCreateEvent.sendEvent: neither g_server nor g_client set; offline path, no dispatch")
    end
end
