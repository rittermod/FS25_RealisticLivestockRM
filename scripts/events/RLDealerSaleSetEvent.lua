--[[
    RLDealerSaleSetEvent.lua
    Dealer sale-availability change REQUEST (client -> server).

    The payload is the OP LIST the selector's reconcile produced, never a desired full
    set: the server applies those ops to its own registry, so the client authors only
    the delta it performed. A client-computed full set would turn any client staleness
    into a server-side deletion of overrides the client never saw.

    Wire format: RLDealerSaleWire.writeList (count prefix + N four-field records). A
    `set` op carries its value; a `clear` op's value slot is inert. executeOnServer
    dereferences g_server and must never run on a client. The registry reaches disk
    through the career save only -- nothing here writes a savegame.
]]

RLDealerSaleSetEvent = {}
local RLDealerSaleSetEvent_mt = Class(RLDealerSaleSetEvent, Event)

InitEventClass(RLDealerSaleSetEvent, "RLDealerSaleSetEvent")

local Log = RmLogging.getLogger("RLRM")

--- Reconcile action tokens, named so the codec and the apply loop cannot drift on a typo.
local ACTION_SET = "set"
local ACTION_CLEAR = "clear"

--- Empty constructor used during deserialization.
---@return table self
function RLDealerSaleSetEvent.emptyNew()
    Log:trace("RLDealerSaleSetEvent.emptyNew")
    local self = Event.new(RLDealerSaleSetEvent_mt)
    return self
end

--- Construct a new request carrying a reconcile op list.
---@param ops table[]|nil ops shaped like `RLDealerSaleReconcile.diff` returns
---@return table self
function RLDealerSaleSetEvent.new(ops)
    local self = RLDealerSaleSetEvent.emptyNew()
    self.ops = ops or {}
    Log:trace("RLDealerSaleSetEvent.new: #ops=%d", #self.ops)
    return self
end

--- Server-context check as a seam: the in-game rlTest cannot reassign a root `g_*`, so
--- run()'s branch and sendEvent's routing are driven through this function instead.
---@return boolean true if this process is the authoritative server
function RLDealerSaleSetEvent.isServer()
    return g_server ~= nil
end

--- Encode one reconcile op as a wire record, or nil plus a reason. A `set` passes its value
--- through VERBATIM: `isSet and value or false` would collapse a nil into a valid `false`
--- and request "not buyable" for a stage the caller gave no value for. Only a `clear`,
--- whose value slot is inert, is filled with `false`.
---@param op any
---@return table|nil rec
---@return string|nil reason
local function opToRecord(op)
    if type(op) ~= "table" then
        return nil, "op is not a table (" .. type(op) .. ")"
    end
    if op.action ~= ACTION_SET and op.action ~= ACTION_CLEAR then
        return nil, "unknown action '" .. tostring(op.action) .. "'"
    end

    local isSet = op.action == ACTION_SET
    local canBeBought = false
    if isSet then
        canBeBought = op.canBeBought
    end

    return {
        subTypeName = op.subTypeName,
        minAge      = op.minAge,
        isSet       = isSet,
        canBeBought = canBeBought,
    }
end

--- Decode one wire record back into a reconcile op; a clear leaves its value field absent.
---@param rec table
---@return table op
local function recordToOp(rec)
    if rec.isSet then
        return {
            subTypeName = rec.subTypeName,
            minAge      = rec.minAge,
            action      = ACTION_SET,
            canBeBought = rec.canBeBought,
        }
    end
    return { subTypeName = rec.subTypeName, minAge = rec.minAge, action = ACTION_CLEAR }
end

--- Serialize the op list.
function RLDealerSaleSetEvent:writeStream(streamId, connection)
    local ops = self.ops or {}
    local records = {}

    for i = 1, #ops do
        local rec, reason = opToRecord(ops[i])
        if rec ~= nil then
            records[#records + 1] = rec
        else
            Log:warning("RLDealerSaleSetEvent:writeStream: dropping op %d - %s; that stage change is NOT requested from the server and stays as it is",
                i, tostring(reason))
        end
    end

    Log:trace("RLDealerSaleSetEvent:writeStream: #ops=%d -> #records=%d", #ops, #records)
    RLDealerSaleWire.writeList(streamId, records)
end

--- Deserialize + run on this machine. A dropped payload MUST NOT reach `run()`: an empty
--- op list is indistinguishable from "the admin changed nothing".
function RLDealerSaleSetEvent:readStream(streamId, connection)
    local records, dropped = RLDealerSaleWire.readList(streamId)

    if dropped then
        self.ops = {}
        Log:warning("RLDealerSaleSetEvent:readStream: the codec dropped the payload; NOT running the request, so the server's override set and dealer stock are left untouched")
        return
    end

    local ops = {}
    for i = 1, #records do
        ops[i] = recordToOp(records[i])
    end
    self.ops = ops

    Log:trace("RLDealerSaleSetEvent:readStream: #ops=%d", #ops)
    self:run(connection)
end

--- Server receives a change request from a remote client; permission is folded in here.
function RLDealerSaleSetEvent:run(connection)
    local ops = self.ops or {}
    local count = #ops

    -- On a client `connection:getIsServer()` is TRUE, so a client receiving this class
    -- would pass the authority gate below and nil-crash in executeOnServer's broadcast.
    if not RLDealerSaleSetEvent.isServer() then
        Log:warning("RLDealerSaleSetEvent:run: received on a non-server peer; this class is a client -> server request only, dropping %d op(s) (nothing is applied locally)",
            count)
        return
    end

    local userName = "unknown"
    local user = g_currentMission.userManager:getUserByConnection(connection)
    if user ~= nil then
        userName = user.nickname or userName
    end

    local isMasterUser = connection:getIsServer()
        or g_currentMission.userManager:getIsConnectionMasterUser(connection)

    if not isMasterUser then
        Log:warning("RLDealerSaleSetEvent:run: permission denied for user '%s' (%d op(s)) - not admin; the override registry, the state broadcast and the dealer stock are all unchanged",
            tostring(userName), count)
        return
    end

    Log:info("RLDealerSaleSetEvent:run: admin '%s' authorized, applying %d dealer sale-availability op(s)",
        tostring(userName), count)

    RLDealerSaleSetEvent.executeOnServer(ops)
end

--- The single server mutation funnel: apply the ops, and only when at least one landed,
--- broadcast the authoritative set and regenerate the dealer. The broadcast PRECEDES the
--- repopulate so a client holds the new flags before the regenerated stock arrives.
---@param ops table[] ops shaped like `RLDealerSaleReconcile.diff` returns
function RLDealerSaleSetEvent.executeOnServer(ops)
    if type(ops) ~= "table" then
        Log:warning("RLDealerSaleSetEvent.executeOnServer: ops is not a table (%s); nothing applied, no broadcast and no dealer re-roll",
            type(ops))
        return
    end

    if g_rlDealerSaleRegistry == nil then
        Log:warning("RLDealerSaleSetEvent.executeOnServer: g_rlDealerSaleRegistry is nil; ignoring %d op(s), no broadcast and no dealer re-roll",
            #ops)
        return
    end

    local applied = 0

    for i, op in ipairs(ops) do

        if type(op) ~= "table" then

            Log:warning("RLDealerSaleSetEvent.executeOnServer: op %d is not a table (%s); skipped, that stage is unchanged",
                i, type(op))

        elseif op.action == ACTION_CLEAR then

            -- Count the removal, not the call: a clear that removed nothing changed
            -- nothing, and counting it would re-roll the whole dealer for no effect.
            if g_rlDealerSaleRegistry:clear(op.subTypeName, op.minAge) then
                applied = applied + 1
                Log:trace("RLDealerSaleSetEvent.executeOnServer: cleared override %s @%s (back to its shipped default)",
                    op.subTypeName, tostring(op.minAge))
            else
                Log:trace("RLDealerSaleSetEvent.executeOnServer: clear removed nothing for %s @%s; not counted as applied",
                    tostring(op.subTypeName), tostring(op.minAge))
            end

        elseif op.action == ACTION_SET then

            -- Count the CHANGE, not the call: `set` is an unconditional upsert returning
            -- true even when the value is unchanged, and a stale admin snapshot does emit
            -- an op the server already applied.
            local previous = g_rlDealerSaleRegistry:get(op.subTypeName, op.minAge)

            if g_rlDealerSaleRegistry:set(op.subTypeName, op.minAge, op.canBeBought) then
                if previous ~= op.canBeBought then
                    applied = applied + 1
                    Log:trace("RLDealerSaleSetEvent.executeOnServer: set override %s @%s -> %s (was %s)",
                        op.subTypeName, tostring(op.minAge), tostring(op.canBeBought), tostring(previous))
                else
                    Log:trace("RLDealerSaleSetEvent.executeOnServer: set %s @%s was already %s; not counted as applied",
                        op.subTypeName, tostring(op.minAge), tostring(op.canBeBought))
                end
            else
                Log:trace("RLDealerSaleSetEvent.executeOnServer: registry rejected set %s @%s; not counted as applied",
                    tostring(op.subTypeName), tostring(op.minAge))
            end

        else

            Log:warning("RLDealerSaleSetEvent.executeOnServer: unknown reconcile action '%s' for %s @%s; skipped, that stage is unchanged",
                tostring(op.action), tostring(op.subTypeName), tostring(op.minAge))

        end

    end

    if applied == 0 then
        Log:debug("RLDealerSaleSetEvent.executeOnServer: no changes (%d op(s) received, none applied); no broadcast and no dealer re-roll",
            #ops)
        return
    end

    RLDealerSaleStateEvent.broadcastToClients(g_rlDealerSaleRegistry:enumerate())

    Log:debug("RLDealerSaleSetEvent.executeOnServer: %d change(s) applied and broadcast; folding onto the live flags and regenerating the dealer",
        applied)
    RLDealerSaleApply.applyAndRepopulate()
end

--- The only public entry: host / singleplayer executes directly, a pure client uploads.
---@param ops table[] ops shaped like `RLDealerSaleReconcile.diff` returns
function RLDealerSaleSetEvent.sendEvent(ops)
    if type(ops) ~= "table" then
        Log:warning("RLDealerSaleSetEvent.sendEvent: invalid payload (%s); nothing dispatched and no override changes",
            type(ops))
        return
    end

    Log:trace("RLDealerSaleSetEvent.sendEvent: dispatching #ops=%d", #ops)

    if RLDealerSaleSetEvent.isServer() then
        RLDealerSaleSetEvent.executeOnServer(ops)
    elseif g_client ~= nil then
        local conn = g_client:getServerConnection()
        if conn == nil then
            Log:warning("RLDealerSaleSetEvent.sendEvent: g_client has no server connection; dropping %d op(s), so the confirmed change never reaches the server",
                #ops)
            return
        end
        conn:sendEvent(RLDealerSaleSetEvent.new(ops))
    else
        Log:trace("RLDealerSaleSetEvent.sendEvent: neither server nor client; offline path, no dispatch")
    end
end

Log:trace("RLDealerSaleSetEvent: loaded")
