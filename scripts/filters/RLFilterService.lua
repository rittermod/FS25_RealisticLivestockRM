-- RLFilterService.lua
-- Singleton CRUD service for saveable filter records.
--
-- Owns the in-memory registry, assigns stable ids on create, and handles the XML
-- round-trip under the settings file's `<filters>` block.
--
-- Immutability: `id`, `farmId` and `version` are frozen after create; the rest are mutable
-- through `update`. A violation is rejected and leaves state unchanged.
--
-- Scope matching is NIL-OR-EQUAL on animalType, farmId AND usage, so a nil farmId is
-- global, a nil animalType covers every type, and usage ANY appears on every frame.
--
-- MP: the mutators dispatch AFTER the local mutation, and the events land back through the
-- applyIncoming path, which bypasses dispatch so `run()` never re-fires.
--
-- OWNERSHIP: every boundary deep-copies the record, so a caller cannot mutate stored state
-- by retaining a returned reference. Internal callers needing the live one use _rawGetById.

local Log = RmLogging.getLogger("RLRM")

RLFilterService = {}
local RLFilterService_mt = { __index = RLFilterService }

--- Prefix used by `Utils.getUniqueId` for filter ids.
RLFilterService.UNIQUE_ID_PREFIX = "rlFilter_"

--- Canonical XML base key for the filters block. Both the load and save hooks MUST reference
--- this constant rather than the literal, so the two paths stay in sync.
RLFilterService.XML_BASE_KEY = "rm_RlSettings.filters"

-- =============================================================================
-- Deep copy
-- =============================================================================

--- Recursively clone an AST node. A non-nil `op` means group, `children` defaulting to empty
--- so a degenerate group is not mis-classified as a condition and destroyed.
---@param node any
---@return any clone
local function cloneNode(node)
    if type(node) ~= "table" then return node end

    if node.op ~= nil then
        local children = {}
        for i, child in ipairs(node.children or {}) do
            children[i] = cloneNode(child)
        end
        return { op = node.op, children = children }
    end

    -- condition node
    local value = node.value
    if type(value) == "table" then
        local list = {}
        for i, v in ipairs(value) do list[i] = v end
        value = list
    end
    return { field = node.field, cmp = node.cmp, value = value }
end

--- Shallow-clone the filter's top-level scalars and deep-clone its expression.
---@param f table|nil
---@return table|nil clone
local function cloneFilter(f)
    if f == nil then return nil end
    return {
        id         = f.id,
        name       = f.name,
        animalType = f.animalType,
        farmId     = f.farmId,
        usage      = f.usage,
        version    = f.version,
        expression = cloneNode(f.expression),
    }
end

--- Exposed for tests and event handlers that clone wire-decoded payloads.
RLFilterService._cloneFilter = cloneFilter

-- =============================================================================
-- Construction
-- =============================================================================

--- Construct a new, empty service instance. Instance-safe, so tests can isolate.
---@return table instance
function RLFilterService.new()
    local self = setmetatable({}, RLFilterService_mt)
    self.filtersById = {}
    Log:debug("RLFilterService.new: fresh instance")
    return self
end

-- =============================================================================
-- Internal raw accessor (no clone)
-- =============================================================================

--- Return the stored record WITHOUT cloning. Internal use only - callers must not mutate it.
---@param id string|nil
---@return table|nil stored
function RLFilterService:_rawGetById(id)
    if id == nil then return nil end
    return self.filtersById[id]
end

-- =============================================================================
-- CRUD
-- =============================================================================

--- Create a filter, assigning a unique `id` and defaulting `version` to 1. A clone is stored,
--- never the caller's table.
---@param filter table filter record (without id)
---@return table|nil filter cloned snapshot of the stored record
function RLFilterService:create(filter)
    if filter == nil then
        Log:warning("RLFilterService:create: nil filter; rejecting")
        return nil
    end

    -- Assign the id on the caller's table so `Utils.getUniqueId`'s collision-table semantics
    -- work, then clone into the registry.
    filter.id = Utils.getUniqueId(filter, self.filtersById, RLFilterService.UNIQUE_ID_PREFIX)
    filter.version = filter.version or 1

    -- nil defaults silently to ANY on create; a non-nil value is coerced, warning loudly on an
    -- unknown one.
    if filter.usage == nil then
        filter.usage = RLFilterUsage.ANY
    else
        filter.usage = RLFilterUsage.coerce(filter.usage)
    end

    local stored = cloneFilter(filter)
    self.filtersById[stored.id] = stored

    Log:debug("RLFilterService:create: id=%s name=%s animalType=%s farmId=%s usage=%s",
        tostring(stored.id), tostring(stored.name),
        tostring(stored.animalType), tostring(stored.farmId), tostring(stored.usage))

    RLFilterService._sendCreateEvent(stored)

    return cloneFilter(stored)
end

--- Look up a filter by id, as a cloned snapshot.
---@param id string
---@return table|nil
function RLFilterService:getById(id)
    local f = self.filtersById[id]
    Log:trace("RLFilterService:getById: id=%s found=%s", tostring(id), tostring(f ~= nil))
    return cloneFilter(f)
end

--- Apply a whole-object update, mutating only `name`, `animalType`, `expression` and `usage`.
--- Rejected on an unknown or mismatched id, a differing `farmId`/`version`, or a missing
--- `name`/`expression`/`usage` - a partial payload would collapse the filter into a nameless
--- match-everything record. A nil `animalType` is legal: that is a global-scope filter.
---@param id string lookup id
---@param payload table whole-object replacement payload
---@return table|nil updated cloned snapshot of the stored record
function RLFilterService:update(id, payload)
    if id == nil or payload == nil then
        Log:warning("RLFilterService:update: nil id or payload; rejecting")
        return nil
    end

    local existing = self:_rawGetById(id)
    if existing == nil then
        Log:warning("RLFilterService:update: unknown id '%s'; rejecting", tostring(id))
        return nil
    end

    if payload.id ~= id then
        Log:warning("RLFilterService:update: payload.id='%s' does not match lookup id='%s'; rejecting (id is immutable)",
            tostring(payload.id), tostring(id))
        return nil
    end

    if payload.farmId ~= existing.farmId then
        Log:warning("RLFilterService:update: payload.farmId=%s does not match stored farmId=%s; rejecting (farmId is immutable)",
            tostring(payload.farmId), tostring(existing.farmId))
        return nil
    end

    if payload.version ~= existing.version then
        Log:warning("RLFilterService:update: payload.version=%s does not match stored version=%s; rejecting (version is immutable)",
            tostring(payload.version), tostring(existing.version))
        return nil
    end

    if payload.name == nil then
        Log:warning("RLFilterService:update: payload.name is nil for id=%s; rejecting (whole-object replacement requires name)",
            tostring(id))
        return nil
    end
    if payload.expression == nil then
        Log:warning("RLFilterService:update: payload.expression is nil for id=%s; rejecting (whole-object replacement requires expression)",
            tostring(id))
        return nil
    end
    if payload.usage == nil then
        Log:warning("RLFilterService:update: payload.usage is nil for id=%s; rejecting (whole-object replacement requires usage - silent widening on a scoping axis would be data loss)",
            tostring(id))
        return nil
    end

    payload.usage = RLFilterUsage.coerce(payload.usage)

    -- Immutable fields are re-pinned from the existing record, so even a divergent payload could
    -- not persist the divergence.
    local stored = cloneFilter(payload)
    stored.id      = id
    stored.farmId  = existing.farmId
    stored.version = existing.version

    self.filtersById[id] = stored

    Log:debug("RLFilterService:update: id=%s applied (name=%s animalType=%s usage=%s)",
        id, tostring(stored.name), tostring(stored.animalType), tostring(stored.usage))

    RLFilterService._sendUpdateEvent(stored)

    return cloneFilter(stored)
end

--- Remove the filter with the given id, dispatching the Delete event after the local mutation.
---@param id string
---@return boolean removed false when the id was unknown
function RLFilterService:delete(id)
    if id == nil or self:_rawGetById(id) == nil then
        Log:warning("RLFilterService:delete: unknown id '%s'; no-op", tostring(id))
        return false
    end

    self.filtersById[id] = nil
    Log:debug("RLFilterService:delete: id=%s removed", tostring(id))

    RLFilterService._sendDeleteEvent(id)

    return true
end

-- =============================================================================
-- Queries
-- =============================================================================

--- All stored filters as an array of defensive clones. Order is undefined.
---@return table[] filters cloned snapshots
function RLFilterService:list()
    local out = {}
    for _, f in pairs(self.filtersById) do
        table.insert(out, cloneFilter(f))
    end
    Log:trace("RLFilterService:list: #=%d", #out)
    return out
end

--- Filters matching the scope by nil-or-equal on `animalType`, `farmId` and `usage`; a nil
--- argument means "any" on that axis. The `f.usage == nil` arm covers an un-normalised record
--- and pairs with the `ANY` arm so both shapes match the same set.
---@param animalType integer|nil AnimalType int index to match against
---@param farmId integer|nil farm id to match against
---@param usage string|nil canonical usage string (ANY/OWNED/DEALER) or nil for "any bucket"
---@return table[] filters cloned snapshots
function RLFilterService:listAvailable(animalType, farmId, usage)
    local out = {}
    for _, f in pairs(self.filtersById) do
        local typeMatch  = f.animalType == nil or animalType == nil or f.animalType == animalType
        local farmMatch  = f.farmId     == nil or farmId     == nil or f.farmId     == farmId
        local usageMatch = f.usage      == nil or f.usage    == RLFilterUsage.ANY or usage == nil or f.usage == usage
        if typeMatch and farmMatch and usageMatch then
            table.insert(out, cloneFilter(f))
        end
    end
    Log:trace("RLFilterService:listAvailable: animalType=%s farmId=%s usage=%s #=%d",
        tostring(animalType), tostring(farmId), tostring(usage), #out)
    return out
end

-- =============================================================================
-- Incoming-event apply paths
-- =============================================================================
--
-- These land wire-decoded payloads WITHOUT firing another event, each defensive-copying so the
-- event object cannot mutate stored state after apply. Contrast create/update/delete, which
-- take a TRUSTED caller path and both mutate and dispatch.

--- Store a wire-decoded filter record. The server validates permission, scope and duplicate
--- ids first; clients apply blindly, the rebroadcast being authoritative.
---@param filter table wire-decoded filter record
---@return boolean applied
function RLFilterService:applyIncomingCreate(filter)
    if filter == nil or filter.id == nil or filter.id == "" then
        Log:warning("RLFilterService:applyIncomingCreate: malformed payload (id=%s); dropping",
            tostring(filter and filter.id))
        return false
    end

    -- Server-authoritative state wins, but an unexpected existing record means something is
    -- wrong upstream.
    if self.filtersById[filter.id] ~= nil then
        Log:warning("RLFilterService:applyIncomingCreate: id=%s already present locally; overwriting with authoritative payload (possible id collision or duplicate broadcast)",
            tostring(filter.id))
    end

    -- Defence in depth: the wire decoder already coerces unknown bytes, so this exists so a
    -- future non-wire caller inherits the same boundary policy `:create` and `:update` enforce.
    if filter.usage == nil then
        filter.usage = RLFilterUsage.ANY
    else
        filter.usage = RLFilterUsage.coerce(filter.usage)
    end

    self.filtersById[filter.id] = cloneFilter(filter)
    Log:debug("RLFilterService:applyIncomingCreate: id=%s name=%s animalType=%s farmId=%s usage=%s",
        tostring(filter.id), tostring(filter.name),
        tostring(filter.animalType), tostring(filter.farmId),
        tostring(filter.usage))
    return true
end

--- Replace a stored record with the wire-decoded payload. The server has already enforced
--- immutability on id/farmId/version, so client receivers trust the rebroadcast.
---@param filter table wire-decoded filter record
---@return boolean applied
function RLFilterService:applyIncomingUpdate(filter)
    if filter == nil or filter.id == nil or filter.id == "" then
        Log:warning("RLFilterService:applyIncomingUpdate: malformed payload (id=%s); dropping",
            tostring(filter and filter.id))
        return false
    end

    -- The server rejects updates on unknown ids, so a client applying one missed the create.
    if self.filtersById[filter.id] == nil then
        Log:warning("RLFilterService:applyIncomingUpdate: id=%s unknown locally; acting as upsert (possible missed create)",
            tostring(filter.id))
    end

    -- A defensive coerce rather than `:update`'s rejection: rejecting here would silently drop a
    -- server-authoritative broadcast and leave the client diverged.
    if filter.usage == nil then
        filter.usage = RLFilterUsage.ANY
    else
        filter.usage = RLFilterUsage.coerce(filter.usage)
    end

    self.filtersById[filter.id] = cloneFilter(filter)
    Log:debug("RLFilterService:applyIncomingUpdate: id=%s name=%s usage=%s",
        tostring(filter.id), tostring(filter.name), tostring(filter.usage))
    return true
end

--- Remove a record in response to the Delete event. A no-op on an unknown id, logged at trace
--- since the server already validated - it just means this peer never had it.
---@param id string
---@return boolean applied
function RLFilterService:applyIncomingDelete(id)
    if id == nil or id == "" then
        Log:warning("RLFilterService:applyIncomingDelete: nil/empty id; dropping")
        return false
    end

    if self.filtersById[id] == nil then
        Log:trace("RLFilterService:applyIncomingDelete: id=%s not present locally (already gone)",
            tostring(id))
        return false
    end

    self.filtersById[id] = nil
    Log:debug("RLFilterService:applyIncomingDelete: id=%s removed", tostring(id))
    return true
end

--- Empty the registry. Called by `loadFromXMLFile` before reading, so successive save loads in
--- one process cannot leak state across games.
function RLFilterService:clear()
    self.filtersById = {}
    Log:debug("RLFilterService:clear: state emptied")
end

-- =============================================================================
-- XML IO
-- =============================================================================

--- Serialize every stored filter under `baseKey`, sorted by id so the on-disk key order is
--- deterministic across save cycles.
---@param xmlFile table XMLFile handle
---@param baseKey string e.g. `"rm_RlSettings.filters"`
function RLFilterService:saveToXMLFile(xmlFile, baseKey)
    if xmlFile == nil then
        Log:warning("RLFilterService:saveToXMLFile: nil xmlFile; skipping")
        return
    end

    local filters = self:list()
    table.sort(filters, function(a, b) return tostring(a.id) < tostring(b.id) end)

    for i, f in ipairs(filters) do
        local filterKey = string.format("%s.filter(%d)", baseKey, i - 1)
        RLFilterSerialization.writeFilter(xmlFile, filterKey, f)
    end

    Log:debug("RLFilterService:saveToXMLFile: baseKey=%s wrote=%d filters (sorted by id)", baseKey, #filters)
end

--- Clear existing state, then deserialize every filter under `baseKey`. The iterate is wrapped
--- in `pcall` so a malformed filter cannot abort the surrounding settings load.
---@param xmlFile table XMLFile handle
---@param baseKey string e.g. `"rm_RlSettings.filters"`
function RLFilterService:loadFromXMLFile(xmlFile, baseKey)
    if xmlFile == nil then
        Log:warning("RLFilterService:loadFromXMLFile: nil xmlFile; skipping")
        return
    end

    self:clear()
    local loaded = 0

    local ok, err = pcall(function()
        xmlFile:iterate(baseKey .. ".filter", function(_, filterKey)
            local f = RLFilterSerialization.readFilter(xmlFile, filterKey)
            if f ~= nil then
                self.filtersById[f.id] = f
                loaded = loaded + 1
            end
        end)
    end)

    if not ok then
        Log:warning("RLFilterService:loadFromXMLFile: iterate errored after %d filters loaded; keeping partial state (%s)",
            loaded, tostring(err))
    end

    Log:debug("RLFilterService:loadFromXMLFile: baseKey=%s loaded=%d filters", baseKey, loaded)
end

-- =============================================================================
-- Dispatch hooks (swappable for tests)
-- =============================================================================
--
-- Production fires the corresponding event via .sendEvent(); tests reassign these fields to
-- capture payloads without a network. Each nil-guards its event class so a call before the
-- events are sourced cannot crash.

---@param filter table
RLFilterService._sendCreateEvent = function(filter)
    if RLFilterCreateEvent == nil then
        Log:trace("RLFilterService._sendCreateEvent: RLFilterCreateEvent not loaded; no dispatch (offline/source-order path)")
        return
    end
    RLFilterCreateEvent.sendEvent(filter)
end

---@param filter table
RLFilterService._sendUpdateEvent = function(filter)
    if RLFilterUpdateEvent == nil then
        Log:trace("RLFilterService._sendUpdateEvent: RLFilterUpdateEvent not loaded; no dispatch")
        return
    end
    RLFilterUpdateEvent.sendEvent(filter)
end

---@param id string
RLFilterService._sendDeleteEvent = function(id)
    if RLFilterDeleteEvent == nil then
        Log:trace("RLFilterService._sendDeleteEvent: RLFilterDeleteEvent not loaded; no dispatch")
        return
    end
    RLFilterDeleteEvent.sendEvent(id)
end

-- Eager source-time singleton: the SAVE path can fire on a settings change early in the mission
-- lifecycle, so constructing here gives every consumer a live registry whatever the hook order.
-- The on-disk LOAD runs separately, after AnimalType is populated, so animalType strings can
-- resolve to indices.
g_rlFilterService = RLFilterService.new()

Log:trace("RLFilterService: loaded")
