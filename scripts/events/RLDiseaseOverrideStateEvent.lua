--[[
    RLDiseaseOverrideStateEvent.lua
    Full disease-override set (server -> client): the switched-OFF titles only.

    Sent to each joining client and broadcast after every accepted change, empty or not - an
    empty list is the legal "everything on" snapshot. The receiver RECONSTRUCTS
    `g_rlDiseaseOverrideRegistry` rather than merging, because a client never runs the loader
    and a merge would carry a previous session's overrides into this one.
]]

RLDiseaseOverrideStateEvent = {}
local RLDiseaseOverrideStateEvent_mt = Class(RLDiseaseOverrideStateEvent, Event)

InitEventClass(RLDiseaseOverrideStateEvent, "RLDiseaseOverrideStateEvent")

local Log = RmLogging.getLogger("RLRM")

--- Empty constructor used during deserialization.
---@return table self
function RLDiseaseOverrideStateEvent.emptyNew()
    Log:trace("RLDiseaseOverrideStateEvent.emptyNew")
    local self = Event.new(RLDiseaseOverrideStateEvent_mt)
    return self
end

--- Construct the event from registry records, keeping the switched-off titles.
---@param records table[]|nil records shaped like `RLDiseaseOverrideRegistry:enumerate()`
---@return table self
function RLDiseaseOverrideStateEvent.new(records)
    local self = RLDiseaseOverrideStateEvent.emptyNew()

    local titles = {}
    for _, rec in ipairs(records or {}) do
        if type(rec) == "table" and rec.enabled == false then
            titles[#titles + 1] = rec.title
        end
    end

    self.titles = titles
    Log:trace("RLDiseaseOverrideStateEvent.new: #titles=%d", #titles)
    return self
end

--- Server-context seam, so an in-game suite can drive the client branch without a root `g_*` write.
---@return boolean true if this process is the authoritative server
function RLDiseaseOverrideStateEvent.isServer()
    local isServer = g_server ~= nil
    Log:trace("RLDiseaseOverrideStateEvent.isServer: %s", tostring(isServer))
    return isServer
end

--- Serialize the switched-off titles: a UInt16 count, then one String per title.
---@param streamId number
---@param connection table
function RLDiseaseOverrideStateEvent:writeStream(streamId, connection)
    local titles = self.titles or {}
    streamWriteUInt16(streamId, #titles)
    for _, title in ipairs(titles) do
        streamWriteString(streamId, title)
    end
    Log:trace("RLDiseaseOverrideStateEvent:writeStream: #titles=%d", #titles)
end

--- Deserialize and apply on this machine.
---@param streamId number
---@param connection table
function RLDiseaseOverrideStateEvent:readStream(streamId, connection)
    local count = streamReadUInt16(streamId)
    local titles = {}
    for i = 1, count do
        titles[i] = streamReadString(streamId)
    end
    self.titles = titles

    Log:trace("RLDiseaseOverrideStateEvent:readStream: #titles=%d", count)
    self:run(connection)
end

--- Apply the received state: reconstruct the registry off-side, then swap it in.
---@param connection table
function RLDiseaseOverrideStateEvent:run(connection)
    local titles = self.titles or {}

    if RLDiseaseOverrideStateEvent.isServer() then
        Log:warning("RLDiseaseOverrideStateEvent:run: received on the server; this state event is send-only, dropping %d title(s)",
            #titles)
        return
    end

    local registry = RLDiseaseOverrideRegistry.new()
    for _, title in ipairs(titles) do
        registry:set(title, false)
    end
    g_rlDiseaseOverrideRegistry = registry

    Log:debug("RLDiseaseOverrideStateEvent:run: received %d switched-off disease title(s) (registry reconstructed)",
        #titles)
end

--- Server-only dispatcher to ONE target connection (the join push).
---@param records table[] records shaped like `RLDiseaseOverrideRegistry:enumerate()`
---@param connection table target connection (single client)
function RLDiseaseOverrideStateEvent.sendEvent(records, connection)
    if not RLDiseaseOverrideStateEvent.isServer() then
        Log:warning("RLDiseaseOverrideStateEvent.sendEvent: a client cannot emit the authoritative disease state; dropping")
        return
    end
    if connection == nil then
        Log:warning("RLDiseaseOverrideStateEvent.sendEvent: nil connection; dropping")
        return
    end

    local event = RLDiseaseOverrideStateEvent.new(records)
    Log:trace("RLDiseaseOverrideStateEvent.sendEvent: sending %d switched-off disease title(s) to a joining client",
        #event.titles)
    connection:sendEvent(event)
end

--- Server-only dispatcher to every connected client (the change hop); reaches none in singleplayer.
---@param records table[] records shaped like `RLDiseaseOverrideRegistry:enumerate()`
function RLDiseaseOverrideStateEvent.broadcastToClients(records)
    if not RLDiseaseOverrideStateEvent.isServer() then
        Log:warning("RLDiseaseOverrideStateEvent.broadcastToClients: a client cannot broadcast the authoritative disease state; dropping")
        return
    end

    local event = RLDiseaseOverrideStateEvent.new(records)
    Log:trace("RLDiseaseOverrideStateEvent.broadcastToClients: broadcasting %d switched-off disease title(s)",
        #event.titles)
    g_server:broadcastEvent(event)
end

Log:trace("RLDiseaseOverrideStateEvent: loaded")
