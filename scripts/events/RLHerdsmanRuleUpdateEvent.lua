--[[
    RLHerdsmanRuleUpdateEvent.lua
    Network event for whole-object replacement of a Herdsman rule record (M-Service S4).

    Pattern A (caller-mutates-first + rebroadcast-from-run with ignoreConnection=sender).
    The caller (RLHerdsmanRuleService:update) MUST mutate local state BEFORE calling
    sendEvent. This event's run() applies the mutation on every receiver that is NOT the
    original sender.

    Codec: REUSES S3's whole-object rule codec UNCHANGED -- writeStream ->
    RLHerdsmanRuleWire.writeRule, readStream -> RLHerdsmanRuleWire.readRule. No new wire
    format; Update sends the same flat record Create does.

    Server-side validation (server receiving from a remote client) mirrors the CONTROL
    FLOW of RLFilterUpdateEvent:run (granular, with distinct :warning per failure mode):
      1. tradeAnimals permission for the sending connection.
      2. The rule id must already exist (unknown id -> reject, no rebroadcast).
      3. IMMUTABILITY guard: payload.farmId / payload.version must equal the stored
         record (id is immutable by construction -- it is the lookup key). A divergence
         is a tamper attempt -> reject BEFORE rebroadcast.
      4. Farm scope: the sender's farm must equal the stored rule's owning farmId.
    The pure isAuthorized predicate collapses permission + farm-match for unit testing in
    isolation; run() itself keeps the filter's granular checks so each failure mode logs a
    distinct :warning (permission vs no-farm-lookup vs farm-mismatch), matching the I/O
    matrix rows. The predicate is fed the STORED rule's farmId (the rule already exists).

    Like the LANDED RLHerdsmanRuleCreateEvent, run() OMITS the filter event's post-apply
    g_rlMenu UI fanout: there is no Herdsman M-Frame yet (it subscribes later). This slice
    is NOT multiplayer-shippable on its own: late joiners receive nothing until the S5
    state-sync slice. Ship Create+Update/Delete+State together.
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

--- Pure authorization predicate. A remote update is authorized iff the sender holds the
--- trade permission AND the sender's farm matches the rule's owning farm. No `g_*` access
--- -- the caller resolves the inputs and feeds them in, so the decision is unit-testable
--- in isolation. Identical body to RLHerdsmanRuleCreateEvent.isAuthorized; kept per-event
--- (self-contained) rather than shared so each event stays independently testable.
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

--- Serialize via the shared rule wire codec (REUSED from S3, unchanged).
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

--- Execute the event on the receiver (Pattern A).
---
--- Flow (mirrors RLFilterUpdateEvent:run granular control flow, minus the UI fanout):
---   1. Guard against a malformed payload (nil rule or nil/empty id).
---   2. If server receiving from a remote client:
---        a. reject on missing tradeAnimals permission,
---        b. reject an unknown id (no record to replace),
---        c. reject any farmId/version divergence from the stored record (immutability),
---        d. reject a farm-scope mismatch (sender's farm != stored rule's farm),
---      logging a distinct :warning per failure and dropping (no rebroadcast/apply).
---      On success, rebroadcast with ignoreConnection=sender.
---   3. Apply the update on this receiver (server-received-from-remote or a client
---      receiving the rebroadcast). The sender never enters run() (ignoreConnection).
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

        -- Immutability guard: reject divergence on farmId/version before rebroadcast.
        -- A legitimate client never sends a divergent payload (RLHerdsmanRuleService:update
        -- re-pins these); the only vector is a hand-crafted packet -> tamper attempt.
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

        -- Farm-scope: a rule is always farm-scoped (integer farmId per the S1 floor), so
        -- the sender must be on the stored rule's farm. Using stored.farmId (equal to
        -- payload.farmId post-immutability check) is the defense-in-depth read.
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

        -- Rebroadcast to everyone except the sender (sender already mutated locally before
        -- sendEvent and must not receive an echo).
        g_server:broadcastEvent(
            RLHerdsmanRuleUpdateEvent.new(rule),
            nil, connection, nil)

        Log:debug("RLHerdsmanRuleUpdateEvent:run: validated update from user '%s' (userId=%s), rebroadcasting id=%s",
            tostring(userName), tostring(userId), tostring(rule.id))
    end

    -- Apply the update on this receiver. applyIncomingUpdate re-validates against the S1
    -- field floor, so a crafted payload that passed the codec cannot bypass the rule
    -- invariants (MP must not bypass the field floor; same posture as applyIncomingCreate).
    if g_rlHerdsmanRuleService == nil then
        Log:warning("RLHerdsmanRuleUpdateEvent:run: g_rlHerdsmanRuleService is nil; skipping apply for id=%s",
            tostring(rule.id))
        return
    end

    -- Branch the apply log on the receiver's verdict so a :debug "applied" line only appears
    -- when applyIncomingUpdate actually stored the record. A floor-invalid payload (rejected +
    -- :warning by the receiver, storing nothing) downgrades to :trace - mirroring the delete
    -- event's applied/no-op split - so the logs accurately explain WHY state did not change.
    local applied = g_rlHerdsmanRuleService:applyIncomingUpdate(rule)
    if applied then
        Log:debug("RLHerdsmanRuleUpdateEvent:run: applied update id=%s name=%s",
            tostring(rule.id), tostring(rule.name))
    else
        Log:trace("RLHerdsmanRuleUpdateEvent:run: update not stored id=%s (rejected by applyIncomingUpdate; see its :warning)",
            tostring(rule.id))
    end
end

--- Thin dispatch: broadcast to clients if we are the server, otherwise upload to the
--- server. Caller (service) MUST have already mutated local state before calling this.
--- Guards on `g_server` / `g_client` so offline or early-lifecycle paths stay safe.
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
