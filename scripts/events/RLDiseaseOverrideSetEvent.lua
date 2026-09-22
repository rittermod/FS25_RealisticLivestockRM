--[[
    RLDiseaseOverrideSetEvent.lua
    Disease-override change REQUEST (client -> server): the reconcile op list, never a full set.

    Each op is `{ title, enabled }`: false switches a title off, true clears its override.
    `executeOnServer` is the one mutation funnel; it broadcasts the full state only when the
    batch changed something NET, and the broadcast includes the requester because there is no
    response event. Nothing here writes to disk; the next rm_RlSettings.xml save carries the registry.
]]

RLDiseaseOverrideSetEvent = {}
local RLDiseaseOverrideSetEvent_mt = Class(RLDiseaseOverrideSetEvent, Event)

InitEventClass(RLDiseaseOverrideSetEvent, "RLDiseaseOverrideSetEvent")

local Log = RmLogging.getLogger("RLRM")

--- Empty constructor used during deserialization.
---@return table self
function RLDiseaseOverrideSetEvent.emptyNew()
    Log:trace("RLDiseaseOverrideSetEvent.emptyNew")
    local self = Event.new(RLDiseaseOverrideSetEvent_mt)
    return self
end

--- Construct a request carrying a reconcile op list.
---@param ops table[]|nil ops shaped like `RLDiseaseOverrideReconcile.diff` returns
---@return table self
function RLDiseaseOverrideSetEvent.new(ops)
    local self = RLDiseaseOverrideSetEvent.emptyNew()
    self.ops = ops or {}
    Log:trace("RLDiseaseOverrideSetEvent.new: #ops=%d", #self.ops)
    return self
end

--- Server-context seam, so an in-game suite can drive the peer branch without a root `g_*` write.
---@return boolean true if this process is the authoritative server
function RLDiseaseOverrideSetEvent.isServer()
    local isServer = g_server ~= nil
    Log:trace("RLDiseaseOverrideSetEvent.isServer: %s", tostring(isServer))
    return isServer
end

--- Serialize the op list: a UInt16 count, then (String title, Bool enabled) per op.
---@param streamId number
---@param connection table
function RLDiseaseOverrideSetEvent:writeStream(streamId, connection)
    local ops = self.ops or {}
    streamWriteUInt16(streamId, #ops)
    for _, op in ipairs(ops) do
        streamWriteString(streamId, op.title)
        streamWriteBool(streamId, op.enabled)
    end
    Log:trace("RLDiseaseOverrideSetEvent:writeStream: #ops=%d", #ops)
end

--- Deserialize and run on this machine.
---@param streamId number
---@param connection table
function RLDiseaseOverrideSetEvent:readStream(streamId, connection)
    local count = streamReadUInt16(streamId)
    local ops = {}
    for i = 1, count do
        local title = streamReadString(streamId)
        local enabled = streamReadBool(streamId)
        ops[i] = { title = title, enabled = enabled }
    end
    self.ops = ops

    Log:trace("RLDiseaseOverrideSetEvent:readStream: #ops=%d", count)
    self:run(connection)
end

--- Server receives a change request: peer guard first, then the admin gate.
---@param connection table the sender's connection
function RLDiseaseOverrideSetEvent:run(connection)
    local ops = self.ops or {}

    if not RLDiseaseOverrideSetEvent.isServer() then
        Log:warning("RLDiseaseOverrideSetEvent:run: received on a non-server peer; this class is a request only, dropping %d op(s)",
            #ops)
        return
    end

    local userManager = g_currentMission.userManager
    local user = userManager:getUserByConnection(connection)
    local userName = user ~= nil and user.nickname or "unknown"
    local userId = user ~= nil and user.getId ~= nil and user:getId() or nil

    if not userManager:getIsConnectionMasterUser(connection) then
        local farm = userId ~= nil and g_farmManager ~= nil and g_farmManager:getFarmByUserId(userId) or nil
        Log:warning("RLDiseaseOverrideSetEvent:run: permission denied for user '%s' (userId=%s, farmId=%s, %d op(s)) - not admin; nothing applied",
            tostring(userName), tostring(userId), tostring(farm ~= nil and farm.farmId or nil), #ops)
        return
    end

    Log:info("RLDiseaseOverrideSetEvent:run: admin '%s' (userId=%s) authorized, applying %d disease override op(s)",
        tostring(userName), tostring(userId), #ops)

    RLDiseaseOverrideSetEvent.executeOnServer(ops)
end

--- The one server mutation funnel; broadcasts only on a net change across the whole batch.
---@param ops table[] ops shaped like `RLDiseaseOverrideReconcile.diff` returns
---@return number changed titles whose stored value now differs
function RLDiseaseOverrideSetEvent.executeOnServer(ops)
    if type(ops) ~= "table" then
        Log:warning("RLDiseaseOverrideSetEvent.executeOnServer: ops is not a table (%s); nothing applied", type(ops))
        return 0
    end

    local registry = g_rlDiseaseOverrideRegistry
    local before, order = {}, {}

    for _, op in ipairs(ops) do
        if type(op) == "table" and type(op.title) == "string" and before[op.title] == nil then
            order[#order + 1] = op.title
            before[op.title] = { value = registry:get(op.title) }
        end
    end

    for i, op in ipairs(ops) do
        if type(op) ~= "table" then
            Log:warning("RLDiseaseOverrideSetEvent.executeOnServer: op %d is not a table (%s); skipped", i, type(op))
        elseif op.enabled == false then
            registry:set(op.title, false)
        elseif op.enabled == true then
            registry:clear(op.title)
        else
            Log:warning("RLDiseaseOverrideSetEvent.executeOnServer: op %d (%s) has no boolean enabled; skipped",
                i, tostring(op.title))
        end
    end

    local changed = 0
    for _, title in ipairs(order) do
        if registry:get(title) ~= before[title].value then
            changed = changed + 1
        end
    end

    if changed == 0 then
        Log:debug("RLDiseaseOverrideSetEvent.executeOnServer: no net change (%d op(s)); no broadcast", #ops)
        return 0
    end

    Log:info("RLDiseaseOverrideSetEvent.executeOnServer: %d disease title(s) changed from %d op(s); broadcasting",
        changed, #ops)
    RLDiseaseOverrideStateEvent.broadcastToClients(registry:enumerate())
    return changed
end

--- The only public entry: SP and a listen host execute directly, a pure client uploads.
---@param ops table[] ops shaped like `RLDiseaseOverrideReconcile.diff` returns
function RLDiseaseOverrideSetEvent.sendEvent(ops)
    if type(ops) ~= "table" then
        Log:warning("RLDiseaseOverrideSetEvent.sendEvent: invalid payload (%s); nothing dispatched", type(ops))
        return
    end

    if RLDiseaseOverrideSetEvent.isServer() then
        Log:debug("RLDiseaseOverrideSetEvent.sendEvent: authority; applying %d op(s) directly", #ops)
        RLDiseaseOverrideSetEvent.executeOnServer(ops)
    elseif g_client ~= nil then
        local conn = g_client:getServerConnection()
        if conn == nil then
            Log:warning("RLDiseaseOverrideSetEvent.sendEvent: no server connection; dropping %d op(s)", #ops)
            return
        end
        Log:debug("RLDiseaseOverrideSetEvent.sendEvent: requesting %d op(s) from the server", #ops)
        conn:sendEvent(RLDiseaseOverrideSetEvent.new(ops))
    else
        Log:trace("RLDiseaseOverrideSetEvent.sendEvent: neither server nor client; no dispatch")
    end
end

Log:trace("RLDiseaseOverrideSetEvent: loaded")
