--[[
    RLDealerSaleStateEvent.lua
    Full dealer sale-availability override set (server -> client).

    Dispatched to every connecting client so a late joiner converges with the authoritative
    server state, and broadcast after each accepted admin change. Wire format is
    `RLDealerSaleWire.writeList`; every record in a snapshot is an override, so a record
    arriving as a clear is a protocol error and is skipped.

    Receiver flow: guard server-authoritative receive, then RECONSTRUCT
    `g_rlDealerSaleRegistry` and re-`set` each record - never a merge, because the registry
    is `or`-guarded at load and the server-only loader never runs on a client, so a merge
    would carry a previous session's overrides into this one. Then
    `applyToLiveSubTypes()` for local flags only, NEVER `applyAndRepopulate()`, which ends
    in a dealer-reset REQUEST and would produce one per connected client.

    `sessionBaseline` is never touched here: the client's FIRST apply lazily captures the
    shipped defaults from a store no apply has written yet, so re-capturing afterwards would
    record already-overridden values as the defaults and permanently break restore-on-clear.

    An empty set is a valid state event - the deterministic clear-to-empty signal.
]]

RLDealerSaleStateEvent = {}
local RLDealerSaleStateEvent_mt = Class(RLDealerSaleStateEvent, Event)

InitEventClass(RLDealerSaleStateEvent, "RLDealerSaleStateEvent")

local Log = RmLogging.getLogger("RLRM")

--- Empty constructor used during deserialization.
---@return table self
function RLDealerSaleStateEvent.emptyNew()
    Log:trace("RLDealerSaleStateEvent.emptyNew")
    local self = Event.new(RLDealerSaleStateEvent_mt)
    return self
end

--- Construct a new event carrying the authoritative override set.
---
--- Registry records are NORMALISED to the wire record shape here, so `self.records`
--- carries exactly ONE shape no matter which path produced it - this constructor
--- (from `enumerate()`, which has no `isSet` field) or `readStream` (from the codec,
--- which always does). Without that, `run()` would have to tolerate an absent `isSet`,
--- and the obvious later "tidy-up" of its protocol check to `not rec.isSet` would
--- silently turn the join push and every broadcast into a no-op.
---@param records table[]|nil records shaped like `RLDealerSaleRegistry:enumerate()`
---@return table self
function RLDealerSaleStateEvent.new(records)
    local self = RLDealerSaleStateEvent.emptyNew()

    local normalised = {}
    for i = 1, #(records or {}) do
        local rec = records[i]
        if type(rec) ~= "table" then
            Log:warning("RLDealerSaleStateEvent.new: skipping a non-table record at index %d (%s); that stage is not carried to the client",
                i, type(rec))
        else
            -- A snapshot carries overrides, so a record with no `isSet` IS one. An
            -- explicit value is preserved verbatim (never `rec.isSet or true`, which
            -- would rewrite a false into a true) so `run()` can still reject it as the
            -- protocol error it is.
            local isSet = true
            if rec.isSet ~= nil then isSet = rec.isSet end

            normalised[#normalised + 1] = {
                subTypeName = rec.subTypeName,
                minAge      = rec.minAge,
                isSet       = isSet,
                canBeBought = rec.canBeBought,
            }
        end
    end

    self.records = normalised
    Log:trace("RLDealerSaleStateEvent.new: #records=%d", #self.records)
    return self
end

--- Server-context check, factored out so the in-game rlTest can swap it without mutating the root
--- g_server global (rlTest cannot reassign a root g_*, only a level below it - so the
--- server-vs-pure-client branches in run() and in BOTH dispatchers are driven through this
--- function). Production reads g_server.
---@return boolean true if this process is the authoritative server
function RLDealerSaleStateEvent.isServer()
    return g_server ~= nil
end

--- Serialize the override set. `self.records` is already in the wire record shape
--- (the constructor normalises, the codec produces it directly), so this hands the
--- list straight to the codec - which owns per-record validation and the count/cap
--- framing, and drops anything malformed with the key named.
function RLDealerSaleStateEvent:writeStream(streamId, connection)
    local records = self.records or {}
    Log:trace("RLDealerSaleStateEvent:writeStream: #records=%d", #records)
    RLDealerSaleWire.writeList(streamId, records)
end

--- Deserialize + run on this machine. A dropped payload MUST NOT reach `run()`:
--- the empty list would reconstruct the registry EMPTY and wipe every override
--- this peer holds.
function RLDealerSaleStateEvent:readStream(streamId, connection)
    local records, dropped = RLDealerSaleWire.readList(streamId)
    self.records = records

    if dropped then
        Log:warning("RLDealerSaleStateEvent:readStream: the codec dropped the payload; NOT applying, this peer keeps its current override set rather than being wiped")
        return
    end

    Log:trace("RLDealerSaleStateEvent:readStream: #records=%d", #records)
    self:run(connection)
end

--- Apply the received state on this peer.
function RLDealerSaleStateEvent:run(connection)
    local records = self.records or {}
    local count = #records

    if RLDealerSaleStateEvent.isServer() then
        Log:warning("RLDealerSaleStateEvent:run: received on the server; this state event is server-authoritative send-only, dropping %d record(s) so a crafted client send cannot rewrite the dealer overrides",
            count)
        return
    end

    if RLDealerSaleRegistry == nil then
        Log:warning("RLDealerSaleStateEvent:run: RLDealerSaleRegistry is nil (load-order regression); dropping %d record(s), this peer keeps its shipped dealer defaults",
            count)
        return
    end

    -- Full-set REPLACE built off-side, then swapped in, so a mid-loop failure can
    -- never leave a half-applied registry live.
    local registry = RLDealerSaleRegistry.new()
    local applied = 0

    for i = 1, count do
        local rec = records[i]
        if type(rec) ~= "table" then
            Log:warning("RLDealerSaleStateEvent:run: skipping a malformed record at index %d (%s); that stage falls back to this peer's shipped default",
                i, type(rec))
        elseif rec.isSet ~= true then
            Log:warning("RLDealerSaleStateEvent:run: record %d (%s @%s) is not an override (isSet=%s), but a snapshot carries only overrides; skipping it (protocol error) - that stage falls back to its shipped default",
                i, tostring(rec.subTypeName), tostring(rec.minAge), tostring(rec.isSet))
        elseif registry:set(rec.subTypeName, rec.minAge, rec.canBeBought) then
            applied = applied + 1
        else
            Log:warning("RLDealerSaleStateEvent:run: the registry rejected record %d (%s @%s); that stage falls back to this peer's shipped default",
                i, tostring(rec.subTypeName), tostring(rec.minAge))
        end
    end

    g_rlDealerSaleRegistry = registry

    -- Same load-order failure class as the registry guard above, and it matters more
    -- here: the swap has already happened, so a throw would leave this peer holding
    -- the new registry with un-applied flags, and on the join path it would land
    -- inside the initial-state handshake.
    if RLDealerSaleApply == nil then
        Log:warning("RLDealerSaleStateEvent:run: RLDealerSaleApply is nil (load-order regression); the %d override(s) are stored but the live flags are NOT folded, so this peer's dealer keeps its shipped defaults until the next apply",
            applied)
        return
    end

    RLDealerSaleApply.applyToLiveSubTypes()

    Log:debug("RLDealerSaleStateEvent:run: received %d override(s), applied %d (registry reconstructed)",
        count, applied)
end

--- Server-only dispatcher to ONE target connection (the join push). This and
--- `broadcastToClients` are the only send paths, so the server guard lives on
--- exactly two code paths.
---@param records table[] records shaped like `RLDealerSaleRegistry:enumerate()`
---@param connection table target connection (single client)
function RLDealerSaleStateEvent.sendEvent(records, connection)
    if not RLDealerSaleStateEvent.isServer() then
        Log:warning("RLDealerSaleStateEvent.sendEvent: a client cannot emit the authoritative dealer state; dropping (the target peer keeps its current overrides)")
        return
    end

    -- Type-guard BEFORE any `#`. A non-table here throws inside the prepended
    -- sendInitialClientState, which aborts that whole hook and leaves the joining
    -- client with NO initial state at all - not merely no dealer state. The request
    -- event's entry point carries the same guard; these two dispatchers are the only
    -- send paths, so the guards genuinely live on one code path each.
    if type(records) ~= "table" then
        Log:warning("RLDealerSaleStateEvent.sendEvent: records is not a table (%s); dropping, so that client will not receive the dealer overrides",
            type(records))
        return
    end

    if connection == nil then
        Log:warning("RLDealerSaleStateEvent.sendEvent: nil connection; dropping %d record(s), so that client will not receive the dealer overrides",
            #records)
        return
    end

    Log:trace("RLDealerSaleStateEvent.sendEvent: dispatching #records=%d", #records)
    connection:sendEvent(RLDealerSaleStateEvent.new(records))
end

--- Server-only dispatcher to every connected client (the change hop). Sent
--- unconditionally after an accepted change; in singleplayer it reaches zero
--- connections.
---@param records table[] records shaped like `RLDealerSaleRegistry:enumerate()`
function RLDealerSaleStateEvent.broadcastToClients(records)
    if not RLDealerSaleStateEvent.isServer() then
        Log:warning("RLDealerSaleStateEvent.broadcastToClients: a client cannot broadcast the authoritative dealer state; dropping (no peer is updated)")
        return
    end

    if type(records) ~= "table" then
        Log:warning("RLDealerSaleStateEvent.broadcastToClients: records is not a table (%s); dropping, so no peer is updated",
            type(records))
        return
    end

    Log:trace("RLDealerSaleStateEvent.broadcastToClients: broadcasting #records=%d", #records)
    g_server:broadcastEvent(RLDealerSaleStateEvent.new(records))
end

Log:trace("RLDealerSaleStateEvent: loaded")
