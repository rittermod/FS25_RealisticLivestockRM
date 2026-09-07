--[[
    RLHerdsmanRuleUpdateEvent.lua
    Network event for whole-object replacement of a Herdsman rule record.

    Pattern A: the caller (RLHerdsmanRuleService:update) MUST mutate local state BEFORE
    calling sendEvent; run() applies the mutation on every receiver that is not the
    original sender, and the server rebroadcasts with ignoreConnection=sender.

    Codec: RLHerdsmanRuleWire.writeRule / readRule -- the same flat record Create sends.
    farmId and version are immutable across an update; the server rejects a divergence
    before it rebroadcasts.
]]

RLHerdsmanRuleUpdateEvent = {}
local RLHerdsmanRuleUpdateEvent_mt = Class(RLHerdsmanRuleUpdateEvent, Event)

InitEventClass(RLHerdsmanRuleUpdateEvent, "RLHerdsmanRuleUpdateEvent")

local Log = RmLogging.getLogger("RLRM")

--- Empty constructor used during deserialization.
---@return table self
function RLHerdsmanRuleUpdateEvent.emptyNew()
    Log:trace("RLHerdsmanRuleUpdateEvent.emptyNew")
    local self = Event.new(RLHerdsmanRuleUpdateEvent_mt)
    return self
end

--- Construct a new event carrying a whole rule record (post-update snapshot).
---@param rule table rule record (with id populated)
---@return table self
function RLHerdsmanRuleUpdateEvent.new(rule)
    Log:trace("RLHerdsmanRuleUpdateEvent.new: id=%s name=%s",
        tostring(rule and rule.id), tostring(rule and rule.name))
    local self = RLHerdsmanRuleUpdateEvent.emptyNew()
    self.rule = rule
    return self
end

--- Authorized iff the sender holds the trade permission and is on the rule's owning farm.
---@param hasTradePermission boolean sender holds the tradeAnimals permission
---@param senderFarmId number|nil the sending player's resolved farm id
---@param ruleFarmId number|nil the STORED rule's owning farm id
---@return boolean authorized
function RLHerdsmanRuleUpdateEvent.isAuthorized(hasTradePermission, senderFarmId, ruleFarmId)
    return hasTradePermission == true
        and senderFarmId ~= nil
        and ruleFarmId ~= nil
        and senderFarmId == ruleFarmId
end

--- Serialize via the shared rule wire codec.
function RLHerdsmanRuleUpdateEvent:writeStream(streamId, connection)
    if self.rule == nil then
        Log:warning("RLHerdsmanRuleUpdateEvent:writeStream: nil rule payload (nothing to write)")
        return
    end
    Log:trace("RLHerdsmanRuleUpdateEvent:writeStream: id=%s", tostring(self.rule.id))
    RLHerdsmanRuleWire.writeRule(streamId, self.rule)
end

--- Deserialize + run on this machine.
function RLHerdsmanRuleUpdateEvent:readStream(streamId, connection)
    self.rule = RLHerdsmanRuleWire.readRule(streamId)
    Log:trace("RLHerdsmanRuleUpdateEvent:readStream: id=%s name=%s",
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
function RLHerdsmanRuleUpdateEvent:run(connection)
    local rule = self.rule
    if rule == nil or rule.id == nil or rule.id == "" then
        Log:warning("RLHerdsmanRuleUpdateEvent:run: malformed payload (id=%s); aborting",
            tostring(rule and rule.id))
        return
    end

    if not connection:getIsServer() then
        local userName, userId = getUserContext(connection)

        if not g_currentMission:getHasPlayerPermission("tradeAnimals", connection) then
            Log:warning("RLHerdsmanRuleUpdateEvent:run: permission 'tradeAnimals' denied for user '%s' (userId=%s) rule id=%s farmId=%s",
                tostring(userName), tostring(userId), tostring(rule.id), tostring(rule.farmId))
            return
        end

        if g_rlHerdsmanRuleService == nil then
            Log:warning("RLHerdsmanRuleUpdateEvent:run: g_rlHerdsmanRuleService is nil on server; cannot validate id=%s",
                tostring(rule.id))
            return
        end

        -- _rawGetById avoids an unnecessary deep-clone on this read-only check.
        local stored = g_rlHerdsmanRuleService:_rawGetById(rule.id)
        if stored == nil then
            Log:warning("RLHerdsmanRuleUpdateEvent:run: unknown id '%s' from user '%s' (userId=%s) farmId=%s; rejecting update",
                tostring(rule.id), tostring(userName), tostring(userId), tostring(rule.farmId))
            return
        end

        if rule.farmId ~= stored.farmId then
            Log:warning("RLHerdsmanRuleUpdateEvent:run: farmId tamper attempt on id=%s (payload=%s stored=%s) user='%s' (userId=%s)",
                tostring(rule.id), tostring(rule.farmId), tostring(stored.farmId), tostring(userName), tostring(userId))
            return
        end
        if rule.version ~= stored.version then
            Log:warning("RLHerdsmanRuleUpdateEvent:run: version tamper attempt on id=%s (payload=%s stored=%s) user='%s' (userId=%s)",
                tostring(rule.id), tostring(rule.version), tostring(stored.version), tostring(userName), tostring(userId))
            return
        end

        if stored.farmId ~= nil then
            local userFarm = g_farmManager:getFarmForUniqueUserId(userId)
            if userFarm == nil or userFarm.farmId == nil then
                Log:warning("RLHerdsmanRuleUpdateEvent:run: no farm lookup for user '%s' (userId=%s); aborting update id=%s farmId=%s",
                    tostring(userName), tostring(userId), tostring(rule.id), tostring(stored.farmId))
                return
            end
            if userFarm.farmId ~= stored.farmId then
                Log:warning("RLHerdsmanRuleUpdateEvent:run: farm-scope mismatch for user '%s' (userId=%s, userFarmId=%s) rule id=%s farmId=%s",
                    tostring(userName), tostring(userId), tostring(userFarm.farmId),
                    tostring(rule.id), tostring(stored.farmId))
                return
            end
        end

        -- Everyone except the sender: it already mutated locally before sendEvent.
        g_server:broadcastEvent(
            RLHerdsmanRuleUpdateEvent.new(rule),
            nil, connection, nil)

        Log:debug("RLHerdsmanRuleUpdateEvent:run: validated update from user '%s' (userId=%s), rebroadcasting id=%s",
            tostring(userName), tostring(userId), tostring(rule.id))
    end

    if g_rlHerdsmanRuleService == nil then
        Log:warning("RLHerdsmanRuleUpdateEvent:run: g_rlHerdsmanRuleService is nil; skipping apply for id=%s",
            tostring(rule.id))
        return
    end

    -- applyIncomingUpdate re-validates against the field floor and stores nothing when the
    -- record fails it, so the verdict decides whether state actually changed.
    local applied = g_rlHerdsmanRuleService:applyIncomingUpdate(rule)
    if applied then
        Log:debug("RLHerdsmanRuleUpdateEvent:run: applied update id=%s name=%s",
            tostring(rule.id), tostring(rule.name))
    else
        Log:trace("RLHerdsmanRuleUpdateEvent:run: update not stored id=%s (rejected by applyIncomingUpdate; see its :warning)",
            tostring(rule.id))
    end

    -- Refresh an open Herdsman menu frame; nil-guarded for early lifecycle / never opened.
    if g_rlMenu ~= nil and g_rlMenu.herdsmanFrame ~= nil
       and g_rlMenu.herdsmanFrame.refreshIfOpen ~= nil then
        g_rlMenu.herdsmanFrame:refreshIfOpen()
    end
end

--- Broadcast to clients if we are the server, otherwise upload to the server.
---@param rule table rule record (post-update snapshot, with id populated)
function RLHerdsmanRuleUpdateEvent.sendEvent(rule)
    if rule == nil or rule.id == nil or rule.id == "" then
        Log:warning("RLHerdsmanRuleUpdateEvent.sendEvent: invalid payload (id=%s); skipping",
            tostring(rule and rule.id))
        return
    end

    Log:trace("RLHerdsmanRuleUpdateEvent.sendEvent: dispatching id=%s", tostring(rule.id))

    if g_server ~= nil then
        g_server:broadcastEvent(RLHerdsmanRuleUpdateEvent.new(rule))
    elseif g_client ~= nil then
        local conn = g_client:getServerConnection()
        if conn == nil then
            Log:warning("RLHerdsmanRuleUpdateEvent.sendEvent: g_client has no server connection; dropping dispatch id=%s",
                tostring(rule.id))
            return
        end
        conn:sendEvent(RLHerdsmanRuleUpdateEvent.new(rule))
    else
        Log:trace("RLHerdsmanRuleUpdateEvent.sendEvent: neither g_server nor g_client set; offline path, no dispatch")
    end
end
