--[[
    RLHerdsmanRuleStateEvent.lua
    Full-state Herdsman rule snapshot, server -> client only.

    Dispatched from sendInitialClientState for every connecting client, and the
    reconciliation path for the create/update delta events: a bounded targetHusbandries
    divergence on a delta hop is re-sent whole here.

    Wire format -- a UInt16 count prefix, then N records through the shared
    RLHerdsmanRuleWire codec. count=0 is a valid state event and gives a joining client
    a deterministic clear-to-empty signal.
]]

RLHerdsmanRuleStateEvent = {}
local RLHerdsmanRuleStateEvent_mt = Class(RLHerdsmanRuleStateEvent, Event)

InitEventClass(RLHerdsmanRuleStateEvent, "RLHerdsmanRuleStateEvent")

local Log = RmLogging.getLogger("RLRM")

--- Empty constructor used during deserialization.
---@return table self
function RLHerdsmanRuleStateEvent.emptyNew()
    Log:trace("RLHerdsmanRuleStateEvent.emptyNew")
    local self = Event.new(RLHerdsmanRuleStateEvent_mt)
    return self
end

--- Construct a new event carrying a list of whole rule records.
---@param rules table[]|nil list of rule records (typically from `g_rlHerdsmanRuleService:list()`)
---@return table self
function RLHerdsmanRuleStateEvent.new(rules)
    local self = RLHerdsmanRuleStateEvent.emptyNew()
    self.rules = rules or {}
    Log:trace("RLHerdsmanRuleStateEvent.new: #rules=%d", #self.rules)
    return self
end

--- Upper sanity bound on the wire-side count; exceeding it drops the event rather than
--- spinning the reader through the up-to-65535 records a desynced stream can present.
RLHerdsmanRuleStateEvent.MAX_RULE_COUNT = 10000

--- Serialize via the shared RLHerdsmanRuleWire codec with a UInt16 count prefix. Counts
--- contiguous entries via `ipairs`, so a sparse list warns rather than under-counting.
function RLHerdsmanRuleStateEvent:writeStream(streamId, connection)
    local rules = self.rules or {}

    local count = 0
    for _, _ in ipairs(rules) do count = count + 1 end

    local pairCount = 0
    for _, _ in pairs(rules) do pairCount = pairCount + 1 end
    if pairCount ~= count then
        Log:warning("RLHerdsmanRuleStateEvent:writeStream: rule list is not a contiguous sequence (ipairs=%d pairs=%d); writing only the sequential prefix",
            count, pairCount)
    end

    streamWriteUInt16(streamId, count)
    Log:trace("RLHerdsmanRuleStateEvent:writeStream: #rules=%d", count)
    for i = 1, count do
        RLHerdsmanRuleWire.writeRule(streamId, rules[i])
    end
end

--- Deserialize + run on this machine, dropping the event if the count exceeds MAX_RULE_COUNT.
function RLHerdsmanRuleStateEvent:readStream(streamId, connection)
    local count = streamReadUInt16(streamId)
    if count > RLHerdsmanRuleStateEvent.MAX_RULE_COUNT then
        Log:warning("RLHerdsmanRuleStateEvent:readStream: count=%d exceeds MAX_RULE_COUNT=%d (stream desync?); dropping event",
            count, RLHerdsmanRuleStateEvent.MAX_RULE_COUNT)
        self.rules = {}
        self.dropped = true
        return
    end

    local list = {}
    for i = 1, count do
        list[i] = RLHerdsmanRuleWire.readRule(streamId)
    end
    self.rules = list
    Log:trace("RLHerdsmanRuleStateEvent:readStream: #rules=%d", count)
    self:run(connection)
end

--- Clear the client's registry and re-apply the snapshot through applyIncomingCreate, which
--- re-enforces the field floor and deep-clones each payload.
function RLHerdsmanRuleStateEvent:run(connection)
    local rules = self.rules or {}

    -- Iterate by highest numeric key, NOT `#rules`: `#` on a list with a nil hole
    -- ({valid, nil, valid}) is a border that can truncate before a later valid record.
    local count = 0
    for k in pairs(rules) do
        if type(k) == "number" and k > count then count = k end
    end

    if g_server ~= nil then
        Log:warning("RLHerdsmanRuleStateEvent:run: received on server; state event is server-authoritative send-only, dropping (#rules=%d)",
            count)
        return
    end

    if g_rlHerdsmanRuleService == nil then
        Log:warning("RLHerdsmanRuleStateEvent:run: g_rlHerdsmanRuleService is nil; skipping apply (#rules=%d)",
            count)
        return
    end

    g_rlHerdsmanRuleService:clear()

    local applied = 0
    for i = 1, count do
        local r = rules[i]
        if r == nil or r.id == nil or r.id == "" then
            Log:warning("RLHerdsmanRuleStateEvent:run: skipping malformed rule at index %d (id=%s)",
                i, tostring(r and r.id))
        else
            if g_rlHerdsmanRuleService:applyIncomingCreate(r) then
                applied = applied + 1
            end
        end
    end

    Log:debug("RLHerdsmanRuleStateEvent:run: received %d rule(s), applied %d (registry cleared first)",
        count, applied)

    -- Refresh an open Herdsman menu frame; nil-guarded for early lifecycle / never opened.
    if g_rlMenu ~= nil and g_rlMenu.herdsmanFrame ~= nil
       and g_rlMenu.herdsmanFrame.refreshIfOpen ~= nil then
        g_rlMenu.herdsmanFrame:refreshIfOpen()
    end
end

--- Server-only dispatcher: send the full rule state to a single target connection.
---@param rules table[] list of rule records
---@param connection table target connection (single client)
function RLHerdsmanRuleStateEvent.sendEvent(rules, connection)
    if g_server == nil then
        Log:warning("RLHerdsmanRuleStateEvent.sendEvent: client cannot emit state event; dropping")
        return
    end
    if connection == nil then
        Log:warning("RLHerdsmanRuleStateEvent.sendEvent: nil connection; dropping (#rules=%d)",
            rules ~= nil and #rules or 0)
        return
    end

    local count = rules ~= nil and #rules or 0
    Log:trace("RLHerdsmanRuleStateEvent.sendEvent: dispatching #rules=%d", count)
    connection:sendEvent(RLHerdsmanRuleStateEvent.new(rules))
end

Log:trace("RLHerdsmanRuleStateEvent: loaded")
