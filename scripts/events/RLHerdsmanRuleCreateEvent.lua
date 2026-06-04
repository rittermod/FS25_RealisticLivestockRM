--[[
    RLHerdsmanRuleCreateEvent.lua
    Network event for creating a Herdsman rule record (M-Service S3).

    Pattern A (caller-mutates-first + rebroadcast-from-run with
    ignoreConnection=sender). The caller (RLHerdsmanRuleService:create) MUST mutate
    local state BEFORE calling sendEvent. This event's run() applies the mutation on
    every receiver that is NOT the original sender.

    Server-side validation (server receiving from a remote client):
      1. tradeAnimals permission for the sending connection.
      2. The sender's farm must equal the rule's owning farmId (rules are farm-scoped;
         a rule always carries an integer farmId per the S1 floor).
      3. Reject if a rule with the same id already exists (pathological collision).
    Permission + farm-scope collapse into the pure isAuthorized predicate so the
    decision is unit-testable without the live permission system.

    This slice is Create-only and NOT multiplayer-shippable on its own: late joiners
    receive nothing until the state-sync slice, and a transiently-unresolvable target
    husbandry is reconciled there. Ship Create+Update/Delete+State together.
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

--- Pure authorization predicate. A remote create is authorized iff the sender holds
--- the trade permission AND the sender's farm matches the rule's owning farm. No
--- `g_*` access -- the caller resolves the inputs and feeds them in, so the decision
--- is unit-testable in isolation.
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

--- Execute the event on the receiver (Pattern A).
---
--- Flow:
---   1. Guard against a malformed payload (nil rule or nil/empty id).
---   2. If server receiving from a remote client, validate permission + farm scope
---      (via isAuthorized) and reject a duplicate id BEFORE rebroadcast. On failure,
---      log :warning and drop. On success, rebroadcast with ignoreConnection=sender.
---   3. Apply the create on this receiver unless this machine is the original sender
---      (excluded via ignoreConnection=sender).
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

        -- Resolve the sender's farm with explicit nil guards (stale/absent lookups
        -- are real in MP); the predicate treats a nil farm as unauthorized.
        local userFarm = g_farmManager:getFarmForUniqueUserId(userId)
        local senderFarmId = (userFarm ~= nil) and userFarm.farmId or nil

        if not RLHerdsmanRuleCreateEvent.isAuthorized(hasTradePermission, senderFarmId, rule.farmId) then
            Log:warning("RLHerdsmanRuleCreateEvent:run: create rejected for user '%s' (userId=%s) -- permission=%s senderFarmId=%s ruleFarmId=%s rule id=%s",
                tostring(userName), tostring(userId), tostring(hasTradePermission),
                tostring(senderFarmId), tostring(rule.farmId), tostring(rule.id))
            return
        end

        -- Pathological: payload id collides with an existing record. Reject BEFORE
        -- rebroadcast. _rawGetById avoids an unnecessary deep-clone on this check.
        if g_rlHerdsmanRuleService ~= nil and g_rlHerdsmanRuleService:_rawGetById(rule.id) ~= nil then
            Log:warning("RLHerdsmanRuleCreateEvent:run: duplicate id '%s' for user '%s' (userId=%s); rejecting create before rebroadcast",
                tostring(rule.id), tostring(userName), tostring(userId))
            return
        end

        -- Rebroadcast to everyone except the sender (sender already mutated locally
        -- before sendEvent and must not receive an echo).
        g_server:broadcastEvent(
            RLHerdsmanRuleCreateEvent.new(rule),
            nil, connection, nil)

        Log:debug("RLHerdsmanRuleCreateEvent:run: validated create from user '%s', rebroadcasting id=%s",
            tostring(userName), tostring(rule.id))
    end

    -- Apply the create on this receiver (server-received-from-remote or a client
    -- receiving the rebroadcast). The sender never enters run() thanks to
    -- ignoreConnection=sender in the rebroadcast (and its own broadcastEvent sends
    -- only remotely). applyIncomingCreate re-validates against the S1 floor, so a
    -- crafted payload that passed the codec cannot bypass the rule invariants.
    if g_rlHerdsmanRuleService == nil then
        Log:warning("RLHerdsmanRuleCreateEvent:run: g_rlHerdsmanRuleService is nil; skipping apply for id=%s",
            tostring(rule.id))
        return
    end

    g_rlHerdsmanRuleService:applyIncomingCreate(rule)
    Log:debug("RLHerdsmanRuleCreateEvent:run: applied create id=%s name=%s",
        tostring(rule.id), tostring(rule.name))
end

--- Thin dispatch: broadcast to clients if we are the server, otherwise upload to the
--- server. Caller (service) MUST have already mutated local state before calling
--- this. Guards on `g_server` / `g_client` so offline or early-lifecycle paths (mod
--- tests, service constructor wiring) stay safe.
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
