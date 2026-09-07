--[[
    RLFilterUpdateEvent.lua
    Network event for whole-object replacement of a saveable filter.

    Pattern A: the caller (RLFilterService:update) MUST mutate local state BEFORE calling
    sendEvent; run() applies the mutation on every receiver that is not the original
    sender, and the server rebroadcasts with ignoreConnection=sender.

    Codec: RLFilterWire.writeFilter / readFilter. id, farmId and version are immutable
    across an update; the server rejects a divergence before it rebroadcasts.
]]

RLFilterUpdateEvent = {}
local RLFilterUpdateEvent_mt = Class(RLFilterUpdateEvent, Event)

InitEventClass(RLFilterUpdateEvent, "RLFilterUpdateEvent")

local Log = RmLogging.getLogger("RLRM")

function RLFilterUpdateEvent.emptyNew()
    Log:trace("RLFilterUpdateEvent.emptyNew")
    local self = Event.new(RLFilterUpdateEvent_mt)
    return self
end

function RLFilterUpdateEvent.new(filter)
    Log:trace("RLFilterUpdateEvent.new: id=%s", tostring(filter and filter.id))
    local self = RLFilterUpdateEvent.emptyNew()
    self.filter = filter
    return self
end

function RLFilterUpdateEvent:writeStream(streamId, connection)
    if self.filter == nil then
        Log:warning("RLFilterUpdateEvent:writeStream: nil filter payload (nothing to write)")
        return
    end
    Log:trace("RLFilterUpdateEvent:writeStream: id=%s", tostring(self.filter.id))
    RLFilterWire.writeFilter(streamId, self.filter)
end

function RLFilterUpdateEvent:readStream(streamId, connection)
    self.filter = RLFilterWire.readFilter(streamId)
    Log:trace("RLFilterUpdateEvent:readStream: id=%s", tostring(self.filter and self.filter.id))
    self:run(connection)
end

local function getUserContext(connection)
    local userId = g_currentMission.userManager:getUniqueUserIdByConnection(connection)
    local userName = (g_currentMission.userManager:getUserByConnection(connection) or {}).nickname or "unknown"
    return userName, userId
end

function RLFilterUpdateEvent:run(connection)
    local filter = self.filter
    if filter == nil or filter.id == nil or filter.id == "" then
        Log:warning("RLFilterUpdateEvent:run: malformed payload (id=%s); aborting",
            tostring(filter and filter.id))
        return
    end

    if not connection:getIsServer() then
        local userName, userId = getUserContext(connection)

        if not g_currentMission:getHasPlayerPermission("tradeAnimals", connection) then
            Log:warning("RLFilterUpdateEvent:run: permission 'tradeAnimals' denied for user '%s' (userId=%s) filter id=%s",
                tostring(userName), tostring(userId), tostring(filter.id))
            return
        end

        if g_rlFilterService == nil then
            Log:warning("RLFilterUpdateEvent:run: g_rlFilterService is nil on server; cannot validate id=%s",
                tostring(filter.id))
            return
        end

        -- _rawGetById avoids an unnecessary deep-clone on this read-only check.
        local stored = g_rlFilterService:_rawGetById(filter.id)
        if stored == nil then
            Log:warning("RLFilterUpdateEvent:run: unknown id '%s' from user '%s' (userId=%s); rejecting update",
                tostring(filter.id), tostring(userName), tostring(userId))
            return
        end

        if filter.farmId ~= stored.farmId then
            Log:warning("RLFilterUpdateEvent:run: farmId tamper attempt on id=%s (payload=%s stored=%s) user='%s'",
                tostring(filter.id), tostring(filter.farmId), tostring(stored.farmId), tostring(userName))
            return
        end
        if filter.version ~= stored.version then
            Log:warning("RLFilterUpdateEvent:run: version tamper attempt on id=%s (payload=%s stored=%s) user='%s'",
                tostring(filter.id), tostring(filter.version), tostring(stored.version), tostring(userName))
            return
        end

        if stored.farmId ~= nil then
            local userFarm = g_farmManager:getFarmForUniqueUserId(userId)
            if userFarm == nil or userFarm.farmId == nil then
                Log:warning("RLFilterUpdateEvent:run: no farm lookup for user '%s' (userId=%s); aborting update id=%s",
                    tostring(userName), tostring(userId), tostring(filter.id))
                return
            end
            if userFarm.farmId ~= stored.farmId then
                Log:warning("RLFilterUpdateEvent:run: farm-scope mismatch for user '%s' (userId=%s, userFarmId=%s) filter id=%s farmId=%s",
                    tostring(userName), tostring(userId), tostring(userFarm.farmId),
                    tostring(filter.id), tostring(stored.farmId))
                return
            end
        end

        g_server:broadcastEvent(
            RLFilterUpdateEvent.new(filter),
            nil, connection, nil)

        Log:debug("RLFilterUpdateEvent:run: validated update from user '%s', rebroadcasting id=%s",
            tostring(userName), tostring(filter.id))
    end

    if g_rlFilterService == nil then
        Log:warning("RLFilterUpdateEvent:run: g_rlFilterService is nil; skipping apply for id=%s",
            tostring(filter.id))
        return
    end

    g_rlFilterService:applyIncomingUpdate(filter)
    Log:debug("RLFilterUpdateEvent:run: applied update id=%s name=%s",
        tostring(filter.id), tostring(filter.name))

    Log:trace("RLFilterUpdateEvent:run: fanout to consumer frames, id=%s",
        tostring(filter.id))
    if g_rlMenu ~= nil then
        -- Iterate frame NAMES, not frame references: ipairs stops at the first nil, so an
        -- array holding a nil frame field would silently skip every later frame.
        for _, frameName in ipairs({"infoFrame", "buyFrame", "sellFrame", "moveFrame"}) do
            local f = g_rlMenu[frameName]
            if f ~= nil and f.onRemoteFilterChange ~= nil then
                f:onRemoteFilterChange(filter.id, "update")
            end
        end
    end

    -- Refresh an open Settings frame; nil-guarded for early lifecycle / never opened.
    if g_rlMenu ~= nil and g_rlMenu.settingsFrame ~= nil
       and g_rlMenu.settingsFrame.refreshIfOpen ~= nil then
        g_rlMenu.settingsFrame:refreshIfOpen()
    end

    -- A remote rename can change rule filter-summaries, so an open Herdsman frame needs the
    -- full reload rather than the id-gated onRemoteFilterChange fanout above.
    if g_rlMenu ~= nil and g_rlMenu.herdsmanFrame ~= nil
       and g_rlMenu.herdsmanFrame.refreshIfOpen ~= nil then
        g_rlMenu.herdsmanFrame:refreshIfOpen()
    end
end

--- Thin dispatch. Caller MUST have mutated local state first.
---@param filter table filter record (post-update snapshot)
function RLFilterUpdateEvent.sendEvent(filter)
    if filter == nil or filter.id == nil or filter.id == "" then
        Log:warning("RLFilterUpdateEvent.sendEvent: invalid payload (id=%s); skipping",
            tostring(filter and filter.id))
        return
    end

    Log:trace("RLFilterUpdateEvent.sendEvent: dispatching id=%s", tostring(filter.id))

    if g_server ~= nil then
        g_server:broadcastEvent(RLFilterUpdateEvent.new(filter))
    elseif g_client ~= nil then
        local conn = g_client:getServerConnection()
        if conn == nil then
            Log:warning("RLFilterUpdateEvent.sendEvent: g_client has no server connection; dropping dispatch id=%s",
                tostring(filter.id))
            return
        end
        conn:sendEvent(RLFilterUpdateEvent.new(filter))
    else
        Log:trace("RLFilterUpdateEvent.sendEvent: neither g_server nor g_client set; offline path, no dispatch")
    end
end
