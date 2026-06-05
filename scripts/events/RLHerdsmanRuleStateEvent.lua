--[[
    RLHerdsmanRuleStateEvent.lua
    Full-state Herdsman rule snapshot (M-Service S5).

    Server -> client only. Dispatched from `sendInitialClientState` for every
    connecting client so late-joiners converge with the authoritative server
    rule registry. Also the reconciliation path for the S3/S4 delta events: a
    bounded `targetHusbandries` divergence on a create/update hop is re-sent
    whole here, so a late joiner (or a peer that narrowed a target set during a
    delta hop) converges to the server's truth.

    Wire format (the per-record codec is S3's RLHerdsmanRuleWire, reused
    UNCHANGED; this event owns ONLY the count prefix + the N-record loop):
        streamWriteUInt16(count)
        for i = 1, count do RLHerdsmanRuleWire.writeRule(streamId, rules[i]) end

    Receiver flow (`run`):
      1. Server-authoritative-receive guard: drop the event if this machine is a
         server. The snapshot is strictly server->client; a crafted client send
         must not `clear()` + replace authoritative state.
      2. `g_rlHerdsmanRuleService:clear()` -- drop stale local state.
      3. For each received rule, route through `applyIncomingCreate`, which does
         NOT dispatch further events (the receiver apply is not a local mutation
         that should re-broadcast), re-enforces the S1 field floor per record
         (defense in depth), and deep-clones the wire payload (ownership).

    Empty-set (count=0) is a valid state event -- a server with zero rules still
    sends, giving clients a deterministic "clear-to-empty" signal on join.

    State-event Event-class shape: emptyNew/new/writeStream/readStream/run +
    a server-only static sendEvent dispatcher (the single guarded send path),
    matching the in-mod RLFilterStateEvent and the sibling state events
    (AnimalSystemStateEvent, HusbandryMessageStateEvent).
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

--- Upper sanity bound on the wire-side rule count. Any server that ever
--- accumulates 10,000 Herdsman rules is pathological; the real purpose of this
--- cap is to defend the reader against a desynced upstream stream that could
--- produce a count up to 65535 and spin the reader to a session-timing-out
--- crash. Exceeding the cap drops the event and leaves the receiver in its
--- prior state.
RLHerdsmanRuleStateEvent.MAX_RULE_COUNT = 10000

--- Serialize via the shared RLHerdsmanRuleWire codec with a UInt16 count prefix.
---
--- Counts contiguous 1..N entries via `ipairs` rather than `#self.rules` so a
--- future `list()` refactor that yields a sparse / map-shaped table surfaces as
--- :warning rather than a silent under-count on the wire.
function RLHerdsmanRuleStateEvent:writeStream(streamId, connection)
    local rules = self.rules or {}

    local count = 0
    for _, _ in ipairs(rules) do count = count + 1 end

    -- Surface any divergence between the sequence-count (`ipairs`) and a raw
    -- `pairs` sweep. Normal `g_rlHerdsmanRuleService:list()` input produces equal
    -- counts because it builds via `table.insert`.
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

--- Deserialize + run on this machine.
---
--- Defends against a desynced / corrupted stream by capping the count at
--- `MAX_RULE_COUNT`. If exceeded, the event is dropped -- receiver stays in its
--- prior state rather than spinning the reader through up to 65535 invalid
--- records.
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

--- Apply the received state on the client.
---
--- Flow:
---   1. Server-authoritative-receive guard: drop the event if this machine is
---      running a server. The state event is strictly server-to-client; a
---      crafted client send would otherwise cause the server's `run()` to
---      `clear()` and replace authoritative state from a client payload.
---   2. Nil-guard `g_rlHerdsmanRuleService`. Unlikely (the eager source-time
---      singleton exists before sendInitialClientState) but cheap and explicit.
---   3. `clear()` to drop any stale local state.
---   4. Apply each wire-decoded rule via `applyIncomingCreate`, which:
---      - does not dispatch further events (receiver apply is not a local
---        mutation that should re-broadcast),
---      - re-enforces the S1 field floor per record (a crafted payload that
---        satisfied the typed codec cannot bypass the rule invariants),
---      - deep-clones the payload before storing (ownership contract).
---      Malformed records (nil / nil-or-empty `id`) are skipped with :warning.
---      A well-formed (unique-id) snapshot never fires the method's existing-id
---      overwrite :warning post-clear; a crafted snapshot carrying duplicate ids
---      does (benign, last-wins).
function RLHerdsmanRuleStateEvent:run(connection)
    local rules = self.rules or {}

    -- Iterate by highest numeric key, NOT `#rules`: `#` on a list with a nil hole
    -- ({valid, nil, valid}) is a border that can truncate before a later valid record.
    -- Real inputs (readStream loop / service:list()) are always dense, but a sparse
    -- input must still apply every present record and warn-skip the holes.
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
end

--- Server-only dispatcher. Sends the full rule state to a single target
--- connection. Clients that call this get a `:warning` drop
--- (server-authoritative). This is the SINGLE dispatch path -- both the primary
--- wiring in `RealisticLivestock_FSBaseMission:sendInitialClientState` and any
--- future admin-triggered resend route through here, so the `g_server == nil` +
--- nil-connection guards below cover every send site.
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
