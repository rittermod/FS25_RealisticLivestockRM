--[[
    RLFilterDeleteEvent.lua
    Network event for deleting a saveable filter by id.

    Pattern A: the caller (RLFilterService:delete) MUST mutate local state BEFORE calling
    sendEvent; run() removes the filter on every receiver that is not the original sender,
    and the server rebroadcasts with ignoreConnection=sender.

    The payload is JUST the id, so the farmId for the scope check is derived from the
    server's stored record rather than the wire. An id the server does not hold is a
    no-op rather than a rejection.
]]

RLFilterDeleteEvent = {}
local RLFilterDeleteEvent_mt = Class(RLFilterDeleteEvent, Event)

InitEventClass(RLFilterDeleteEvent, "RLFilterDeleteEvent")

local Log = RmLogging.getLogger("RLRM")

function RLFilterDeleteEvent.emptyNew()
    Log:trace("RLFilterDeleteEvent.emptyNew")
    local self = Event.new(RLFilterDeleteEvent_mt)
    return self
end

function RLFilterDeleteEvent.new(id)
    Log:trace("RLFilterDeleteEvent.new: id=%s", tostring(id))
    local self = RLFilterDeleteEvent.emptyNew()
    self.id = id
    return self
end

function RLFilterDeleteEvent:writeStream(streamId, connection)
    streamWriteString(streamId, self.id or "")
    Log:trace("RLFilterDeleteEvent:writeStream: id=%s", tostring(self.id))
end

function RLFilterDeleteEvent:readStream(streamId, connection)
    self.id = streamReadString(streamId)
    Log:trace("RLFilterDeleteEvent:readStream: id=%s", tostring(self.id))
    self:run(connection)
end

local function getUserContext(connection)
    local userId = g_currentMission.userManager:getUniqueUserIdByConnection(connection)
    local userName = (g_currentMission.userManager:getUserByConnection(connection) or {}).nickname or "unknown"
    return userName, userId
end

function RLFilterDeleteEvent:run(connection)
    local id = self.id
    if id == nil or id == "" then
        Log:warning("RLFilterDeleteEvent:run: malformed payload (id=%s); aborting", tostring(id))
        return
    end

    if not connection:getIsServer() then
        local userName, userId = getUserContext(connection)

        if not g_currentMission:getHasPlayerPermission("tradeAnimals", connection) then
            Log:warning("RLFilterDeleteEvent:run: permission 'tradeAnimals' denied for user '%s' (userId=%s) filter id=%s",
                tostring(userName), tostring(userId), tostring(id))
            return
        end

        if g_rlFilterService == nil then
            Log:warning("RLFilterDeleteEvent:run: g_rlFilterService is nil on server; cannot validate id=%s",
                tostring(id))
            return
        end

        -- _rawGetById avoids an unnecessary deep-clone on this read-only check.
        local stored = g_rlFilterService:_rawGetById(id)
        if stored == nil then
            Log:warning("RLFilterDeleteEvent:run: unknown id '%s' from user '%s' (userId=%s); no-op",
                tostring(id), tostring(userName), tostring(userId))
            return
        end

        if stored.farmId ~= nil then
            local userFarm = g_farmManager:getFarmForUniqueUserId(userId)
            if userFarm == nil or userFarm.farmId == nil then
                Log:warning("RLFilterDeleteEvent:run: no farm lookup for user '%s' (userId=%s); aborting delete id=%s",
                    tostring(userName), tostring(userId), tostring(id))
                return
            end
            if userFarm.farmId ~= stored.farmId then
                Log:warning("RLFilterDeleteEvent:run: farm-scope mismatch for user '%s' (userId=%s, userFarmId=%s) filter id=%s storedFarmId=%s",
                    tostring(userName), tostring(userId), tostring(userFarm.farmId),
                    tostring(id), tostring(stored.farmId))
                return
            end
        end

        g_server:broadcastEvent(
            RLFilterDeleteEvent.new(id),
            nil, connection, nil)

        Log:debug("RLFilterDeleteEvent:run: validated delete from user '%s', rebroadcasting id=%s",
            tostring(userName), tostring(id))
    end

    if g_rlFilterService == nil then
        Log:warning("RLFilterDeleteEvent:run: g_rlFilterService is nil; skipping apply for id=%s",
            tostring(id))
        return
    end

    local applied = g_rlFilterService:applyIncomingDelete(id)
    if applied then
        Log:debug("RLFilterDeleteEvent:run: applied delete id=%s", tostring(id))
    else
        Log:trace("RLFilterDeleteEvent:run: no-op delete id=%s (already gone)", tostring(id))
    end

    -- The fanout fires on the already-gone branch too: that path means a peer's delete
    -- reached us out of order, and a local frame can still hold a stale activeFilterId
    -- pointing at the removed filter, which the per-frame revalidate clears.
    Log:trace("RLFilterDeleteEvent:run: fanout to consumer frames, id=%s", tostring(id))
    if g_rlMenu ~= nil then
        -- Iterate frame NAMES, not frame references: ipairs stops at the first nil, so an
        -- array holding a nil frame field would silently skip every later frame.
        for _, frameName in ipairs({"infoFrame", "buyFrame", "sellFrame", "moveFrame"}) do
            local f = g_rlMenu[frameName]
            if f ~= nil and f.onRemoteFilterChange ~= nil then
                f:onRemoteFilterChange(id, "delete")
            end
        end
    end

    -- Refresh an open Settings frame; nil-guarded for early lifecycle / never opened.
    if g_rlMenu ~= nil and g_rlMenu.settingsFrame ~= nil
       and g_rlMenu.settingsFrame.refreshIfOpen ~= nil then
        g_rlMenu.settingsFrame:refreshIfOpen()
    end

    -- A remote delete can change rule filter-summaries (a bound filter goes missing), so an
    -- open Herdsman frame needs the full reload rather than the id-gated fanout above.
    if g_rlMenu ~= nil and g_rlMenu.herdsmanFrame ~= nil
       and g_rlMenu.herdsmanFrame.refreshIfOpen ~= nil then
        g_rlMenu.herdsmanFrame:refreshIfOpen()
    end
end

--- Thin dispatch. Caller MUST have mutated local state first.
---@param id string filter id to delete
function RLFilterDeleteEvent.sendEvent(id)
    if id == nil or id == "" then
        Log:warning("RLFilterDeleteEvent.sendEvent: invalid id=%s; skipping", tostring(id))
        return
    end

    Log:trace("RLFilterDeleteEvent.sendEvent: dispatching id=%s", tostring(id))

    if g_server ~= nil then
        g_server:broadcastEvent(RLFilterDeleteEvent.new(id))
    elseif g_client ~= nil then
        local conn = g_client:getServerConnection()
        if conn == nil then
            Log:warning("RLFilterDeleteEvent.sendEvent: g_client has no server connection; dropping dispatch id=%s",
                tostring(id))
            return
        end
        conn:sendEvent(RLFilterDeleteEvent.new(id))
    else
        Log:trace("RLFilterDeleteEvent.sendEvent: neither g_server nor g_client set; offline path, no dispatch")
    end
end
