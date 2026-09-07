--[[
    HusbandryMessageAddEvent.lua
    Server-authoritative incremental broadcast of a SINGLE husbandry RL message.

    The join snapshot (HusbandryMessageStateEvent) syncs the full set at connect time;
    this is the incremental leg. The server-side add chokepoint (addRLMessageDirect)
    broadcasts one already-decided message carrying the server-assigned uniqueId + date,
    so every client inserts it verbatim and idempotently. That keeps a single per-husbandry
    uniqueId namespace, which the first-match delete path depends on.

    Server -> clients only, broadcast with NO sendLocal (the host already inserted its own
    copy at the chokepoint), so run() executes only on clients and the apply path never
    re-broadcasts. Clients never originate a message.
]]

HusbandryMessageAddEvent = {}
local HusbandryMessageAddEvent_mt = Class(HusbandryMessageAddEvent, Event)

InitEventClass(HusbandryMessageAddEvent, "HusbandryMessageAddEvent")

local Log = RmLogging.getLogger("RLRM")

--- Empty constructor used during event deserialization.
--- @return table self
function HusbandryMessageAddEvent.emptyNew()
    Log:trace("HusbandryMessageAddEvent.emptyNew")
    local self = Event.new(HusbandryMessageAddEvent_mt)
    return self
end

--- Construct a new event carrying one resolved message for a husbandry.
--- @param husbandry table Husbandry placeable (must have spec_husbandryAnimals)
--- @param uniqueId number Server-assigned message uniqueId (UInt16 on the wire)
--- @param id string Message id (l10n key)
--- @param animal string|nil Optional animal identifier string
--- @param args table|nil Message args (coerced to strings on the wire)
--- @param date string Resolved message date string
--- @return table self
function HusbandryMessageAddEvent.new(husbandry, uniqueId, id, animal, args, date)
    Log:trace("HusbandryMessageAddEvent.new: id='%s' uniqueId=%s", tostring(id), tostring(uniqueId))
    local self = HusbandryMessageAddEvent.emptyNew()
    self.husbandry = husbandry
    self.uniqueId = uniqueId
    self.id = id
    self.animal = animal
    self.args = args or {}
    self.date = date
    return self
end

--- Serialize the event: nodeObject(husbandry) + id + date + uniqueId + hasAnimal[+ animal]
--- + argCount + argCount * String, mirroring HusbandryMessageStateEvent's per-message block.
--- @param streamId number Network stream id
--- @param connection table Network connection (unused, required by Event API)
function HusbandryMessageAddEvent:writeStream(streamId, connection)
    Log:trace("HusbandryMessageAddEvent:writeStream: id='%s' uniqueId=%s for husbandry '%s'",
        tostring(self.id), tostring(self.uniqueId),
        tostring(self.husbandry ~= nil and self.husbandry:getName() or "nil"))

    NetworkUtil.writeNodeObject(streamId, self.husbandry)

    streamWriteString(streamId, self.id)
    streamWriteString(streamId, self.date)
    streamWriteUInt16(streamId, self.uniqueId)

    streamWriteBool(streamId, self.animal ~= nil)
    if self.animal ~= nil then streamWriteString(streamId, self.animal) end

    streamWriteUInt8(streamId, #self.args)

    -- streamWriteString does NOT coerce a number, it throws, so every arg is coerced at the
    -- wire boundary. A non-string/number arg is a corrupt caller: warn, then still coerce so
    -- the broadcast survives.
    for j = 1, #self.args do
        local arg = self.args[j]
        local argType = type(arg)
        if argType ~= "string" and argType ~= "number" then
            Log:warning("HusbandryMessageAddEvent:writeStream: message '%s' arg %d is a %s (expected string/number) - coercing via tostring",
                tostring(self.id), j, argType)
        end
        streamWriteString(streamId, tostring(arg))
    end
end

--- Deserialize the event from the network and run it on this machine.
--- @param streamId number Network stream id
--- @param connection table Network connection (passed through to run)
function HusbandryMessageAddEvent:readStream(streamId, connection)
    self.husbandry = NetworkUtil.readNodeObject(streamId)

    self.id = streamReadString(streamId)
    self.date = streamReadString(streamId)
    self.uniqueId = streamReadUInt16(streamId)

    local hasAnimal = streamReadBool(streamId)
    if hasAnimal then self.animal = streamReadString(streamId) end

    local numArgs = streamReadUInt8(streamId)
    self.args = {}
    for k = 1, numArgs do table.insert(self.args, streamReadString(streamId)) end

    Log:trace("HusbandryMessageAddEvent:readStream: id='%s' uniqueId=%s for husbandry '%s'",
        tostring(self.id), tostring(self.uniqueId),
        tostring(self.husbandry ~= nil and self.husbandry:getName() or "nil"))

    self:run(connection)
end

--- Insert the message on a client, verbatim and idempotently, via addRLMessageDirect.
--- @param connection table Network connection the event arrived on
function HusbandryMessageAddEvent:run(connection)
    if self.husbandry == nil or self.husbandry.spec_husbandryAnimals == nil then
        Log:warning("HusbandryMessageAddEvent:run: invalid husbandry (nil or not a livestock placeable), aborting")
        return
    end

    -- The same uniqueId may also arrive via the join snapshot, and the delete path is
    -- first-match on uniqueId, so a duplicate row would leave a ghost after delete.
    for _, message in pairs(self.husbandry.spec_husbandryAnimals.messages or {}) do
        if message.uniqueId == self.uniqueId then
            Log:debug("HusbandryMessageAddEvent:run: uniqueId=%s already present on husbandry '%s' - idempotent skip",
                tostring(self.uniqueId), tostring(self.husbandry:getName()))
            return
        end
    end

    -- The SERVER's uniqueId, never getNextRLMessageUniqueId - that would drift the namespace.
    self.husbandry:addRLMessageDirect(self.id, self.animal, self.args, self.date, self.uniqueId)

    Log:debug("HusbandryMessageAddEvent:run: applied id='%s' uniqueId=%s to husbandry '%s'",
        tostring(self.id), tostring(self.uniqueId), tostring(self.husbandry:getName()))
end

--- Broadcast one resolved message to all connected clients (server-only entry, no sendLocal).
--- @param husbandry table Husbandry placeable
--- @param uniqueId number Server-assigned message uniqueId
--- @param id string Message id
--- @param animal string|nil Optional animal identifier string
--- @param args table|nil Message args
--- @param date string Resolved message date string
function HusbandryMessageAddEvent.sendEvent(husbandry, uniqueId, id, animal, args, date)
    if husbandry == nil or id == nil or uniqueId == nil then
        Log:warning("HusbandryMessageAddEvent.sendEvent: invalid args (husbandry/id/uniqueId nil), skipping")
        return
    end

    Log:trace("HusbandryMessageAddEvent.sendEvent: dispatching id='%s' uniqueId=%s", tostring(id), tostring(uniqueId))

    g_server:broadcastEvent(HusbandryMessageAddEvent.new(husbandry, uniqueId, id, animal, args, date))
end
