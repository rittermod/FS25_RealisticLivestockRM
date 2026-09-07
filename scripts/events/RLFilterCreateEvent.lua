--[[
    RLFilterCreateEvent.lua
    Network event for creating a saveable filter record.

    Pattern A: the caller (RLFilterService:create) MUST mutate local state BEFORE calling
    sendEvent; run() applies the mutation on every receiver that is not the original
    sender, and the server rebroadcasts with ignoreConnection=sender.

    Codec: RLFilterWire.writeFilter / readFilter. A server receiving from a remote client
    checks the tradeAnimals permission, the sender's farm against a farm-scoped filter,
    and a colliding id before it rebroadcasts.
]]

RLFilterCreateEvent = {}
local RLFilterCreateEvent_mt = Class(RLFilterCreateEvent, Event)

InitEventClass(RLFilterCreateEvent, "RLFilterCreateEvent")

local Log = RmLogging.getLogger("RLRM")

--- Empty constructor used during deserialization.
---@return table self
function RLFilterCreateEvent.emptyNew()
    Log:trace("RLFilterCreateEvent.emptyNew")
    local self = Event.new(RLFilterCreateEvent_mt)
    return self
end

--- Construct a new event carrying a whole filter record.
---@param filter table filter record (with id populated -- client-assigned via Utils.getUniqueId)
---@return table self
function RLFilterCreateEvent.new(filter)
    Log:trace("RLFilterCreateEvent.new: id=%s name=%s",
        tostring(filter and filter.id), tostring(filter and filter.name))
    local self = RLFilterCreateEvent.emptyNew()
    self.filter = filter
    return self
end

--- Serialize via the shared RLFilterWire codec.
function RLFilterCreateEvent:writeStream(streamId, connection)
    if self.filter == nil then
        Log:warning("RLFilterCreateEvent:writeStream: nil filter payload (nothing to write)")
        return
    end
    Log:trace("RLFilterCreateEvent:writeStream: id=%s", tostring(self.filter.id))
    RLFilterWire.writeFilter(streamId, self.filter)
end

--- Deserialize + run on this machine.
function RLFilterCreateEvent:readStream(streamId, connection)
    self.filter = RLFilterWire.readFilter(streamId)
    Log:trace("RLFilterCreateEvent:readStream: id=%s name=%s",
        tostring(self.filter and self.filter.id), tostring(self.filter and self.filter.name))
    self:run(connection)
end

--- Log user context for warning-path decisions.
---@param connection table
---@return string userName, any userId
local function getUserContext(connection)
    local userId = g_currentMission.userManager:getUniqueUserIdByConnection(connection)
    local userName = (g_currentMission.userManager:getUserByConnection(connection) or {}).nickname or "unknown"
    return userName, userId
end

--- Validate a remote client's payload, rebroadcast to the other peers, then apply here
--- and fan the change out to the filter-consuming menu frames.
function RLFilterCreateEvent:run(connection)
    local filter = self.filter
    if filter == nil or filter.id == nil or filter.id == "" then
        Log:warning("RLFilterCreateEvent:run: malformed payload (id=%s); aborting",
            tostring(filter and filter.id))
        return
    end

    if not connection:getIsServer() then
        local userName, userId = getUserContext(connection)

        if not g_currentMission:getHasPlayerPermission("tradeAnimals", connection) then
            Log:warning("RLFilterCreateEvent:run: permission 'tradeAnimals' denied for user '%s' (userId=%s) filter id=%s",
                tostring(userName), tostring(userId), tostring(filter.id))
            return
        end

        if filter.farmId ~= nil then
            local userFarm = g_farmManager:getFarmForUniqueUserId(userId)
            if userFarm == nil or userFarm.farmId == nil then
                Log:warning("RLFilterCreateEvent:run: no farm lookup for user '%s' (userId=%s); aborting create id=%s",
                    tostring(userName), tostring(userId), tostring(filter.id))
                return
            end
            if userFarm.farmId ~= filter.farmId then
                Log:warning("RLFilterCreateEvent:run: farm-scope mismatch for user '%s' (userId=%s, userFarmId=%s) filter id=%s farmId=%s",
                    tostring(userName), tostring(userId), tostring(userFarm.farmId),
                    tostring(filter.id), tostring(filter.farmId))
                return
            end
        end

        -- _rawGetById avoids an unnecessary deep-clone on this read-only check.
        if g_rlFilterService ~= nil and g_rlFilterService:_rawGetById(filter.id) ~= nil then
            Log:warning("RLFilterCreateEvent:run: duplicate id '%s' for user '%s' (userId=%s); rejecting create",
                tostring(filter.id), tostring(userName), tostring(userId))
            return
        end

        -- Everyone except the sender: it already mutated locally before sendEvent.
        g_server:broadcastEvent(
            RLFilterCreateEvent.new(filter),
            nil, connection, nil)

        Log:debug("RLFilterCreateEvent:run: validated create from user '%s', rebroadcasting id=%s",
            tostring(userName), tostring(filter.id))
    end

    if g_rlFilterService == nil then
        Log:warning("RLFilterCreateEvent:run: g_rlFilterService is nil; skipping apply for id=%s",
            tostring(filter.id))
        return
    end

    -- Applied unconditionally: a receiver that already holds this id diverged from the
    -- server, and the authoritative payload must overwrite the stale record.
    -- applyIncomingCreate's existing-id :warning is the convergence signal.
    g_rlFilterService:applyIncomingCreate(filter)
    Log:debug("RLFilterCreateEvent:run: applied create id=%s name=%s",
        tostring(filter.id), tostring(filter.name))

    Log:trace("RLFilterCreateEvent:run: fanout to consumer frames, id=%s",
        tostring(filter.id))
    if g_rlMenu ~= nil then
        -- Iterate frame NAMES, not frame references: ipairs stops at the first nil, so an
        -- array holding a nil frame field would silently skip every later frame.
        for _, frameName in ipairs({"infoFrame", "buyFrame", "sellFrame", "moveFrame"}) do
            local f = g_rlMenu[frameName]
            if f ~= nil and f.onRemoteFilterChange ~= nil then
                f:onRemoteFilterChange(filter.id, "create")
            end
        end
    end

    -- Refresh an open Settings frame; nil-guarded for early lifecycle / never opened.
    if g_rlMenu ~= nil and g_rlMenu.settingsFrame ~= nil
       and g_rlMenu.settingsFrame.refreshIfOpen ~= nil then
        g_rlMenu.settingsFrame:refreshIfOpen()
    end

    -- A remote create can change rule filter-summaries, so an open Herdsman frame needs the
    -- full reload rather than the id-gated onRemoteFilterChange fanout above.
    if g_rlMenu ~= nil and g_rlMenu.herdsmanFrame ~= nil
       and g_rlMenu.herdsmanFrame.refreshIfOpen ~= nil then
        g_rlMenu.herdsmanFrame:refreshIfOpen()
    end
end

--- Broadcast to clients if we are the server, otherwise upload to the server.
---@param filter table filter record (with id populated)
function RLFilterCreateEvent.sendEvent(filter)
    if filter == nil or filter.id == nil or filter.id == "" then
        Log:warning("RLFilterCreateEvent.sendEvent: invalid payload (id=%s); skipping",
            tostring(filter and filter.id))
        return
    end

    Log:trace("RLFilterCreateEvent.sendEvent: dispatching id=%s", tostring(filter.id))

    if g_server ~= nil then
        g_server:broadcastEvent(RLFilterCreateEvent.new(filter))
    elseif g_client ~= nil then
        local conn = g_client:getServerConnection()
        if conn == nil then
            Log:warning("RLFilterCreateEvent.sendEvent: g_client has no server connection; dropping dispatch id=%s",
                tostring(filter.id))
            return
        end
        conn:sendEvent(RLFilterCreateEvent.new(filter))
    else
        Log:trace("RLFilterCreateEvent.sendEvent: neither g_server nor g_client set; offline path, no dispatch")
    end
end
