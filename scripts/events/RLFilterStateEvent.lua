--[[
    RLFilterStateEvent.lua
    Full-state filter snapshot, server -> client only.

    Dispatched from `sendInitialClientState` for every connecting client, and the
    reconciliation path when a Pattern A delta mutation is rejected server-side: the
    next state event wipes and re-applies, converging divergent local state.

    Wire format -- a UInt16 count prefix, then N filters through the recursive
    RLFilterWire codec. count=0 is a valid state event and gives a joining client a
    deterministic clear-to-empty signal.
]]

RLFilterStateEvent = {}
local RLFilterStateEvent_mt = Class(RLFilterStateEvent, Event)

InitEventClass(RLFilterStateEvent, "RLFilterStateEvent")

local Log = RmLogging.getLogger("RLRM")

--- Empty constructor used during deserialization.
---@return table self
function RLFilterStateEvent.emptyNew()
    Log:trace("RLFilterStateEvent.emptyNew")
    local self = Event.new(RLFilterStateEvent_mt)
    return self
end

--- Construct a new event carrying a list of whole filter records.
---@param filters table[]|nil list of filter records (typically from `g_rlFilterService:list()`)
---@return table self
function RLFilterStateEvent.new(filters)
    local self = RLFilterStateEvent.emptyNew()
    self.filters = filters or {}
    Log:trace("RLFilterStateEvent.new: #filters=%d", #self.filters)
    return self
end

--- Upper sanity bound on the wire-side count; exceeding it drops the event rather than
--- spinning the reader through the up-to-65535 records a desynced stream can present.
RLFilterStateEvent.MAX_FILTER_COUNT = 10000

--- Serialize via the shared RLFilterWire codec with a UInt16 count prefix.
---
--- Counts contiguous 1..N entries via `ipairs` rather than `#self.filters` so a sparse or
--- map-shaped list surfaces as :warning rather than a silent under-count on the wire.
function RLFilterStateEvent:writeStream(streamId, connection)
    local filters = self.filters or {}

    local count = 0
    for _, _ in ipairs(filters) do count = count + 1 end

    local pairCount = 0
    for _, _ in pairs(filters) do pairCount = pairCount + 1 end
    if pairCount ~= count then
        Log:warning("RLFilterStateEvent:writeStream: filter list is not a contiguous sequence (ipairs=%d pairs=%d); writing only the sequential prefix",
            count, pairCount)
    end

    streamWriteUInt16(streamId, count)
    Log:trace("RLFilterStateEvent:writeStream: #filters=%d", count)
    for i = 1, count do
        RLFilterWire.writeFilter(streamId, filters[i])
    end
end

--- Deserialize + run on this machine, dropping the event if the count exceeds MAX_FILTER_COUNT.
function RLFilterStateEvent:readStream(streamId, connection)
    local count = streamReadUInt16(streamId)
    if count > RLFilterStateEvent.MAX_FILTER_COUNT then
        Log:warning("RLFilterStateEvent:readStream: count=%d exceeds MAX_FILTER_COUNT=%d (stream desync?); dropping event",
            count, RLFilterStateEvent.MAX_FILTER_COUNT)
        self.filters = {}
        self.dropped = true
        return
    end

    local list = {}
    for i = 1, count do
        list[i] = RLFilterWire.readFilter(streamId)
    end
    self.filters = list
    Log:trace("RLFilterStateEvent:readStream: #filters=%d", count)
    self:run(connection)
end

--- Clear the client's registry and re-apply the received snapshot through applyIncomingCreate,
--- which dispatches no further events and deep-clones each payload before storing it.
function RLFilterStateEvent:run(connection)
    local filters = self.filters or {}
    local count = #filters

    if g_server ~= nil then
        Log:warning("RLFilterStateEvent:run: received on server; state event is server-authoritative send-only, dropping (#filters=%d)",
            count)
        return
    end

    if g_rlFilterService == nil then
        Log:warning("RLFilterStateEvent:run: g_rlFilterService is nil; skipping apply (#filters=%d)",
            count)
        return
    end

    g_rlFilterService:clear()

    local applied = 0
    for i = 1, count do
        local f = filters[i]
        if f == nil or f.id == nil or f.id == "" then
            Log:warning("RLFilterStateEvent:run: skipping malformed filter at index %d (id=%s)",
                i, tostring(f and f.id))
        else
            if g_rlFilterService:applyIncomingCreate(f) then
                applied = applied + 1
            end
        end
    end

    Log:debug("RLFilterStateEvent:run: received %d filter(s), applied %d (registry cleared first)",
        count, applied)
end

--- Server-only dispatcher: send the full filter state to a single target connection.
---@param filters table[] list of filter records
---@param connection table target connection (single client)
function RLFilterStateEvent.sendEvent(filters, connection)
    if g_server == nil then
        Log:warning("RLFilterStateEvent.sendEvent: client cannot emit state event; dropping")
        return
    end
    if connection == nil then
        Log:warning("RLFilterStateEvent.sendEvent: nil connection; dropping (#filters=%d)",
            filters ~= nil and #filters or 0)
        return
    end

    local count = filters ~= nil and #filters or 0
    Log:trace("RLFilterStateEvent.sendEvent: dispatching #filters=%d", count)
    connection:sendEvent(RLFilterStateEvent.new(filters))
end

Log:trace("RLFilterStateEvent: loaded")
