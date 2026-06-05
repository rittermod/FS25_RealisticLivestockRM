--[[
    RLHerdsmanRuleDeleteEvent.lua
    Network event for deleting a Herdsman rule record by id (M-Service S4).

    Pattern A (caller-mutates-first + rebroadcast-from-run with ignoreConnection=sender).
    The caller (RLHerdsmanRuleService:delete) MUST mutate local state BEFORE calling
    sendEvent. This event's run() removes the rule on every receiver that is NOT the
    original sender.

    Payload is JUST the id: writeStream -> streamWriteString, readStream -> streamReadString.
    The farmId used for the scope check is derived from the SERVER's stored record (the
    authoritative source), NOT the wire -- the delete payload carries no farmId.

    Server-side validation (server receiving from a remote client) mirrors the CONTROL
    FLOW of RLFilterDeleteEvent:run (granular, distinct :warning per failure mode):
      1. tradeAnimals permission for the sending connection.
      2. stored = _rawGetById(id). An unknown id is a benign NO-OP (a delete for an id a
         late-joiner never saw), not a hard reject -- :warning + drop, no rebroadcast.
      3. Farm scope: the sender's farm must equal the STORED rule's owning farmId.
    The pure isAuthorized predicate collapses permission + farm-match for unit testing in
    isolation; run() keeps the filter's granular checks so each failure mode logs a distinct
    :warning. The predicate is fed the STORED rule's farmId (the rule already exists).

    Like the LANDED RLHerdsmanRuleCreateEvent, run() OMITS the filter event's post-apply
    g_rlMenu UI fanout: there is no Herdsman M-Frame yet. This slice is NOT multiplayer-
    shippable on its own (see the Create/Update events); ship the trio + S5 state together.
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

--- Pure authorization predicate. A remote delete is authorized iff the sender holds the
--- trade permission AND the sender's farm matches the stored rule's owning farm. No `g_*`
--- access -- the caller resolves the inputs and feeds them in. Identical body to
--- RLHerdsmanRuleCreateEvent.isAuthorized; kept per-event (self-contained) so each event
--- stays independently testable.
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

--- Execute the event on the receiver (Pattern A).
---
--- Flow (mirrors RLFilterDeleteEvent:run granular control flow, minus the UI fanout):
---   1. Guard against a malformed payload (nil/empty id).
---   2. If server receiving from a remote client:
---        a. reject on missing tradeAnimals permission,
---        b. NO-OP an unknown id (benign: a delete for an id this peer never saw),
---        c. reject a farm-scope mismatch (sender's farm != stored rule's farm),
---      logging a distinct :warning per failure and dropping (no rebroadcast/apply).
---      On success, rebroadcast with ignoreConnection=sender.
---   3. Apply the delete on this receiver. The sender never enters run() (ignoreConnection).
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
            -- A delete for an id this peer never saw is benign (late-joiner / reconnect),
            -- so it is a NO-OP, not a hard reject.
            Log:warning("RLHerdsmanRuleDeleteEvent:run: unknown id '%s' from user '%s' (userId=%s); no-op",
                tostring(id), tostring(userName), tostring(userId))
            return
        end

        -- Farm-scope: a rule is always farm-scoped (integer farmId per the S1 floor), so
        -- the sender must be on the stored rule's farm. farmId is derived from the stored
        -- record (the payload carries none).
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

        -- Rebroadcast to everyone except the sender (sender already mutated locally before
        -- sendEvent and must not receive an echo).
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

    -- Branch the apply log so an "applied" line only appears when a record was actually
    -- removed. The already-gone path downgrades to :trace (legitimate late-join / reconnect).
    local applied = g_rlHerdsmanRuleService:applyIncomingDelete(id)
    if applied then
        Log:debug("RLHerdsmanRuleDeleteEvent:run: applied delete id=%s", tostring(id))
    else
        Log:trace("RLHerdsmanRuleDeleteEvent:run: no-op delete id=%s (already gone)", tostring(id))
    end
end

--- Thin dispatch: broadcast to clients if we are the server, otherwise upload to the
--- server. Caller (service) MUST have already mutated local state before calling this.
--- Guards on `g_server` / `g_client` so offline or early-lifecycle paths stay safe.
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
