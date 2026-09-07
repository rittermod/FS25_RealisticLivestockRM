-- RLHerdsmanRuleService.lua
-- Singleton CRUD service for the Herdsman rule registry.
--
-- Owns the in-memory registry `self.rulesById` and assigns stable ids on create via
-- `Utils.getUniqueId`. A rule binds at most one saved filter (nil = an unfiltered draft) plus
-- operation params to a set of target husbandry placeables. Structural sibling of
-- `RLFilterService`, plus XML persistence and MP create/update/delete/state sync.
--
-- Rule record: `id`, `farmId` and `version` are frozen after create; `name`, `operation`,
-- `enabled`, `filterId`, `targetHusbandries` and `params` are mutable via `update`. A violation is
-- rejected with a warning and leaves state unchanged.
--
-- Validity floor, enforced on BOTH create and update:
--   * `name`              non-empty string
--   * `operation`         one of sell|move|buy|castrate|naming|ai|horseCare
--   * `farmId`            integer (the owning farm)
--   * `enabled`           boolean
--   * `params`            table (opaque here; the per-operation codec owns its shape)
--   * `targetHusbandries` dense array (may be empty -> inert rule, no targets)
--   * `filterId`          every operation except naming: nil (incomplete draft) OR a
--                          non-empty (non-whitespace) string; naming: MUST be nil
--
-- Deliberately NOT here: per-operation params validation, filterId resolution against
-- RLFilterService, and target uniqueId -> live-placeable resolution. Those belong to the picker and
-- the day-tick; the service stores the strings as given. The one exception is the operation x
-- animalType gate below, which is cross-layer policy both the editor and the runtime need and
-- neither may own.
--
-- Ownership contract: every boundary into or out of the registry deep-copies the rule record, so a
-- caller cannot mutate stored state by retaining a returned reference. Internal calls that need the
-- live reference use `_rawGetById`.

local Log = RmLogging.getLogger("RLRM")

RLHerdsmanRuleService = {}
local RLHerdsmanRuleService_mt = { __index = RLHerdsmanRuleService }

--- Prefix used by `Utils.getUniqueId` for rule ids.
RLHerdsmanRuleService.UNIQUE_ID_PREFIX = "rlHerdRule_"

--- Canonical operation set; a rule's `operation` MUST be one of these keys. Kept as a set for O(1)
--- validation - the run / visual ORDER lives in `OPERATION_ORDER` below.
RLHerdsmanRuleService.OPERATIONS = {
    sell      = true,
    move      = true,
    buy       = true,
    castrate  = true,
    naming    = true,
    ai        = true,
    horseCare = true,
}

--- Canonical run / visual order: Sell frees herd space before Buy fills it. The single source of
--- truth for the presenter's section placement and the planner's run order, each deriving its own
--- rank map so neither can read a half-built shared one.
---
--- APPEND-ONLY at the TAIL. The frame binds the operation selector's widget state to the ARRAY
--- INDEX, so inserting anywhere but the end silently reassigns every later operation's state.
RLHerdsmanRuleService.OPERATION_ORDER = { "sell", "move", "buy", "castrate", "naming", "ai", "horseCare" }

--- Within-operation comparator: alphabetical by name, case-insensitive, with a nil-safe
--- `tostring(id)` tie-break. Shared by the presenter's section sort and the planner's run-order
--- sort so the two cannot drift; generic over any `{ name, id }` record.
---@param a table record with `name` + `id`
---@param b table record with `name` + `id`
---@return boolean
function RLHerdsmanRuleService.compareRulesByName(a, b)
    local an = string.lower(tostring(a.name or ""))
    local bn = string.lower(tostring(b.name or ""))
    if an ~= bn then return an < bn end
    return tostring(a.id) < tostring(b.id)
end

-- =============================================================================
-- Operation x animalType gate
-- =============================================================================
-- The declarations and the compatibility predicate live here because both layers need them and
-- neither may own them: the presenter decides what the player can express, the planner decides what
-- actually runs, and a rule encoded on one side only is honoured by the editor while the runtime
-- silently ignores it.
--
-- Everything below is a STATIC on the module table, called with `.` and never `:`. The metatable
-- sets `__index = RLHerdsmanRuleService`, so an instance call also resolves and would silently pass
-- the INSTANCE as `operation`.

--- Operation x animalType restrictions, declared by animal type NAME. An operation ABSENT from this
--- table is unrestricted. `exclude` is valid for every type but the named ones; `allow` only for the
--- named ones. An entry carrying both keys is a declaration error, not a runtime case: `allow` wins.
---
--- NAMES, never indices: an animalType index is assigned at registration order, so a third-party map
--- shifts the numbering and a hardcoded index becomes a wrong-species defect on someone else's map.
--- The CALLER resolves the live index per name and injects it, which keeps this module free of g_*.
local OPERATION_ANIMAL_TYPES = {
    castrate  = { exclude = { "CHICKEN" } },
    horseCare = { allow   = { "HORSE" } },
}

--- Exposed read-only so the frame resolves exactly the names these declarations reference.
RLHerdsmanRuleService.OPERATION_ANIMAL_TYPES = OPERATION_ANIMAL_TYPES

--- The union of every animal type NAME the declarations reference, sorted so the order is stable
--- across runs. Callers resolve exactly this set against the live registry, so a declaration naming
--- a new type is picked up automatically.
---@return string[] names fresh sorted array of declared animal type names
function RLHerdsmanRuleService.getDeclaredAnimalTypeNames()
    local seen, names = {}, {}
    for _, rule in pairs(OPERATION_ANIMAL_TYPES) do
        for _, listKey in ipairs({ "allow", "exclude" }) do
            local list = rule[listKey]
            if type(list) == "table" then
                for _, name in ipairs(list) do
                    if not seen[name] then
                        seen[name] = true
                        names[#names + 1] = name
                    end
                end
            end
        end
    end
    table.sort(names)
    Log:trace("RLHerdsmanRuleService.getDeclaredAnimalTypeNames: %d declared name(s) [%s]",
        #names, table.concat(names, ","))
    return names
end

--- Render a declaration for the trace line: `allow:HORSE`, `exclude:CHICKEN`, or `unrestricted`.
--- The RULE is logged rather than the injected map, which would render as a per-run table pointer.
---@param rule table|nil an OPERATION_ANIMAL_TYPES entry, or nil for an unrestricted operation
---@return string
local function describeAnimalTypeRule(rule)
    if rule == nil then return "unrestricted" end
    if rule.allow ~= nil then return "allow:" .. table.concat(rule.allow, ",") end
    if rule.exclude ~= nil then return "exclude:" .. table.concat(rule.exclude, ",") end
    return "unrestricted"
end

--- Resolve the declared animal type NAMES against a registry, as a `name -> index` map. A name the
--- registry does not carry is OMITTED rather than mapped to nil, which is what gives the gate its
--- polarity for free.
---
--- The result is NEVER memoized: `AnimalType` is populated well after these files are sourced, so a
--- cached empty map would close the horse gate for the whole session. Logs at TRACE only - the
--- callers know their own call frequency and can tell "no registry" from "name absent".
---@param registry table|nil the live `AnimalType` registry (name -> index)
---@return table map resolved NAME -> index (possibly empty)
---@return string[] missingNames declared names absent from the registry, in the SORTED union order
function RLHerdsmanRuleService.resolveAnimalTypeIndexMap(registry)
    local names = RLHerdsmanRuleService.getDeclaredAnimalTypeNames()
    local map, missing = {}, {}
    local reg = type(registry) == "table" and registry or nil

    for _, name in ipairs(names) do
        -- A statement rather than `reg ~= nil and reg[name] or nil`: that idiom reports a registry
        -- value of `false` as missing.
        local idx
        if reg ~= nil then idx = reg[name] end
        if idx ~= nil then
            map[name] = idx
        else
            missing[#missing + 1] = name
        end
    end

    Log:trace("RLHerdsmanRuleService.resolveAnimalTypeIndexMap: registry=%s %d/%d declared name(s) resolved, missing [%s]",
        type(registry), #names - #missing, #names, table.concat(missing, ","))
    return map, missing
end

--- The ONE operation x animalType compatibility predicate, shared by the presenter's candidate and
--- destination gates and by the planner's per-target gate, so the editor and the runtime cannot
--- drift apart. Live indices arrive as an injected name -> index map.
---
--- ONE rule generates the whole truth table: a declared name that does not resolve does not match.
--- So an `allow` list fails CLOSED and an `exclude` list fails OPEN, with no polarity special-casing
--- and no mutable state; a nil `animalTypeIndex` is the same rule again, matching no resolved index,
--- so exclude admits it and allow refuses it. This is the NORMATIVE statement of that polarity.
---@param operation any rule operation key
---@param animalTypeIndex any candidate animalType index, or nil for ANY
---@param animalTypeIndexByName table|nil map of declared animal type NAME -> live animalType index
---@return boolean
function RLHerdsmanRuleService.isOperationAnimalTypeCompatible(operation, animalTypeIndex, animalTypeIndexByName)
    local rule = OPERATION_ANIMAL_TYPES[operation]
    local compatible
    if rule == nil then
        compatible = true
    else
        local byName = type(animalTypeIndexByName) == "table" and animalTypeIndexByName or {}
        if rule.allow ~= nil then
            compatible = false
            for _, name in ipairs(rule.allow) do
                local idx = byName[name]
                if idx ~= nil and idx == animalTypeIndex then
                    compatible = true
                    break
                end
            end
        elseif rule.exclude ~= nil then
            compatible = true
            for _, name in ipairs(rule.exclude) do
                local idx = byName[name]
                if idx ~= nil and idx == animalTypeIndex then
                    compatible = false
                    break
                end
            end
        else
            -- A declaration entry carrying neither list restricts nothing.
            compatible = true
        end
    end
    Log:trace("RLHerdsmanRuleService.isOperationAnimalTypeCompatible: operation=%s animalType=%s rule=%s -> %s",
        tostring(operation), tostring(animalTypeIndex), describeAnimalTypeRule(rule), tostring(compatible))
    return compatible
end

--- Is this operation's gate closed for EVERY type - an `allow` list none of whose names resolved?
--- That is the systemic fail-closed case worth a WARNING: the operation silently runs on no pen, and
--- a per-target DEBUG row leaves no evidence at the stable INFO level. False for an unrestricted
--- operation, for an `exclude` operation, and for an `allow` operation with at least one resolution.
--- Returning the unresolved names lets the caller render the diagnosis from the DECLARATION, so a
--- future allow-list operation inherits both the warning and its wording.
---@param operation any rule operation key
---@param animalTypeIndexByName table|nil map of declared animal type NAME -> live animalType index
---@return boolean closed
---@return string[] unresolvedNames the declared `allow` names that did not resolve (empty when not closed)
function RLHerdsmanRuleService.isOperationTypeGateClosed(operation, animalTypeIndexByName)
    local rule = OPERATION_ANIMAL_TYPES[operation]
    if rule == nil or rule.allow == nil then return false, {} end

    local byName = type(animalTypeIndexByName) == "table" and animalTypeIndexByName or {}
    local unresolved = {}
    for _, name in ipairs(rule.allow) do
        if byName[name] == nil then unresolved[#unresolved + 1] = name end
    end

    local closed = #unresolved == #rule.allow
    Log:trace("RLHerdsmanRuleService.isOperationTypeGateClosed: operation=%s rule=%s unresolved=[%s] -> %s",
        tostring(operation), describeAnimalTypeRule(rule), table.concat(unresolved, ","), tostring(closed))
    if not closed then return false, {} end
    return true, unresolved
end

--- Default `version` assigned on create when the caller omits one; frozen thereafter and not bumped
--- on update.
RLHerdsmanRuleService.DEFAULT_VERSION = 1

--- On-disk root for the rule registry inside `rm_RlSettings.xml`. Both registries share that file -
--- filters under `rm_RlSettings.filters`, rules under this key - each with its own load boundary.
RLHerdsmanRuleService.XML_BASE_KEY = "rm_RlSettings.herdsmanRules"

-- =============================================================================
-- Deep copy
-- =============================================================================

--- Recursively deep-copy an opaque value. `params` is opaque here, so this assumes nothing about
--- its shape.
---@param v any
---@return any clone
local function deepCopyValue(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, vv in pairs(v) do
        out[k] = deepCopyValue(vv)
    end
    return out
end

--- Shallow-clone the rule's top-level scalars, array-copy `targetHusbandries`, deep-clone `params`.
---@param r table|nil
---@return table|nil clone
local function cloneRule(r)
    if r == nil then return nil end

    local targets = {}
    if type(r.targetHusbandries) == "table" then
        for i, uid in ipairs(r.targetHusbandries) do
            targets[i] = uid
        end
    end

    return {
        id                = r.id,
        farmId            = r.farmId,
        version           = r.version,
        name              = r.name,
        operation         = r.operation,
        enabled           = r.enabled,
        filterId          = r.filterId,
        targetHusbandries = targets,
        params            = deepCopyValue(r.params) or {},
    }
end

--- Exposed for tests and event handlers that need the same clone contract.
RLHerdsmanRuleService._cloneRule = cloneRule

-- =============================================================================
-- Validity floor
-- =============================================================================

--- True when `t` is a dense array (contiguous integer keys 1..#t). A map-shaped or sparse value
--- would pass a bare `type == "table"` check and then be silently collapsed to `{}` by `cloneRule`'s
--- `ipairs` copy - data loss masquerading as an inert rule - so the floor rejects it instead.
---@param t table
---@return boolean
local function isDenseArray(t)
    local count = 0
    for _ in pairs(t) do count = count + 1 end
    return count == #t
end

--- Validate a candidate rule against the validity floor, for BOTH `create` and `update`, without
--- mutating it. Element typing of `targetHusbandries` and per-operation `params` shape are
--- intentionally not checked here.
---@param r table|nil
---@return boolean ok
---@return string|nil reason short reason a caller can surface in a warning
local function validateRuleFields(r)
    if r == nil then
        return false, "nil rule"
    end
    if type(r.name) ~= "string" or r.name == "" then
        return false, string.format("name must be a non-empty string (got %s)", tostring(r.name))
    end
    if type(r.operation) ~= "string" or not RLHerdsmanRuleService.OPERATIONS[r.operation] then
        return false, string.format("operation must be one of sell|move|buy|castrate|naming|ai|horseCare (got %s)", tostring(r.operation))
    end
    if type(r.farmId) ~= "number" or math.floor(r.farmId) ~= r.farmId then
        return false, string.format("farmId must be an integer (got %s)", tostring(r.farmId))
    end
    if type(r.enabled) ~= "boolean" then
        return false, string.format("enabled must be a boolean (got %s)", tostring(r.enabled))
    end
    if type(r.params) ~= "table" then
        return false, string.format("params must be a table (got %s)", tostring(r.params))
    end
    if type(r.targetHusbandries) ~= "table" then
        return false, string.format("targetHusbandries must be an array (got %s)", tostring(r.targetHusbandries))
    end
    if not isDenseArray(r.targetHusbandries) then
        return false, "targetHusbandries must be a dense array (map-shaped or sparse keys rejected; no normalization here)"
    end
    -- naming carries no filter; a non-naming rule binds at most one, and nil is a legal incomplete
    -- draft that stays inert until a filter is picked. "Needs a filter to actually run" is enforced
    -- at the day-tick.
    if r.operation == "naming" then
        if r.filterId ~= nil then
            return false, string.format("naming rules must have nil filterId (got %s)", tostring(r.filterId))
        end
    elseif r.filterId ~= nil then
        if type(r.filterId) ~= "string" or r.filterId:gsub("%s", "") == "" then
            return false, string.format("operation '%s' filterId, when present, must be a non-empty (non-whitespace) string (got %s)", r.operation, tostring(r.filterId))
        end
    end
    return true
end

--- Exposed for tests that assert the floor directly.
RLHerdsmanRuleService._validateRuleFields = validateRuleFields

-- =============================================================================
-- Record equality (no-op-diff support)
-- =============================================================================

--- Shared empty-table sentinel for `deepEqual`'s nil-as-empty arm, so that path allocates nothing.
--- Read-only: never mutated.
local EMPTY = {}

--- Order-insensitive multiset equality for two arrays of strings. nil is treated as the empty set,
--- so a re-ordered but same-membership set is equal while an added, removed or duplicated element is
--- not.
---@param a string[]|nil
---@param b string[]|nil
---@return boolean equal
local function multisetEqual(a, b)
    local counts, na, nb = {}, 0, 0
    if a ~= nil then
        for _, v in ipairs(a) do counts[v] = (counts[v] or 0) + 1; na = na + 1 end
    end
    if b ~= nil then
        for _, v in ipairs(b) do
            local c = counts[v]
            if c == nil or c == 0 then return false end
            counts[v] = c - 1
            nb = nb + 1
        end
    end
    return na == nb
end

--- Deep value-equality with the registry's two conventions: nil and an empty table compare equal,
--- and non-table leaves fall back to `==`. NOT multiset-aware - the caller routes
--- `targetHusbandries` through `multisetEqual`.
---@param a any
---@param b any
---@return boolean equal
local function deepEqual(a, b)
    local ta, tb = type(a), type(b)
    if ta ~= "table" and tb ~= "table" then
        return a == b
    end
    -- One side is a table; treat a nil counterpart as an empty table. A non-nil, non-table
    -- counterpart stays a `==` mismatch.
    if ta ~= "table" then
        if a ~= nil then return false end
        a = EMPTY
    elseif tb ~= "table" then
        if b ~= nil then return false end
        b = EMPTY
    end
    for k, av in pairs(a) do
        if not deepEqual(av, b[k]) then return false end
    end
    for k, bv in pairs(b) do
        if a[k] == nil and not deepEqual(nil, bv) then return false end
    end
    return true
end

--- Whole-record equality - the no-op-diff predicate behind `update`'s "a byte-identical update never
--- broadcasts" invariant. Deep over every key, so it needs no hand-maintained field list that could
--- drift from `validateRuleFields` / `cloneRule`. `targetHusbandries` compares as an
--- order-insensitive multiset; every other key by deep value-equality with nil == empty-table.
---@param a table|any first rule record (or any value)
---@param b table|any second rule record (or any value)
---@return boolean equal
function RLHerdsmanRuleService.equals(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then
        return a == b
    end
    if not multisetEqual(a.targetHusbandries, b.targetHusbandries) then
        Log:trace("RLHerdsmanRuleService.equals: targetHusbandries multiset differs")
        return false
    end
    for k, av in pairs(a) do
        if k ~= "targetHusbandries" and not deepEqual(av, b[k]) then
            Log:trace("RLHerdsmanRuleService.equals: key '%s' differs", tostring(k))
            return false
        end
    end
    for k, bv in pairs(b) do
        if k ~= "targetHusbandries" and a[k] == nil and not deepEqual(nil, bv) then
            Log:trace("RLHerdsmanRuleService.equals: key '%s' present only on b", tostring(k))
            return false
        end
    end
    Log:trace("RLHerdsmanRuleService.equals: records equal")
    return true
end

-- =============================================================================
-- Construction
-- =============================================================================

--- Construct a new, empty service instance. There is conceptually one per game session
--- (`g_rlHerdsmanRuleService`), but the constructor is instance-safe so tests can isolate.
---@return table instance
function RLHerdsmanRuleService.new()
    local self = setmetatable({}, RLHerdsmanRuleService_mt)
    self.rulesById = {}
    Log:debug("RLHerdsmanRuleService.new: fresh instance")
    return self
end

-- =============================================================================
-- Internal raw accessor (no clone)
-- =============================================================================

--- Return the stored record WITHOUT cloning. Internal use only - callers must not mutate it.
---@param id string|nil
---@return table|nil stored
function RLHerdsmanRuleService:_rawGetById(id)
    if id == nil then return nil end
    return self.rulesById[id]
end

-- =============================================================================
-- CRUD
-- =============================================================================

--- Create a new rule: validate the floor first, then assign a unique `id`, default `version`, and
--- store a defensive clone.
---@param rule table rule record (without id)
---@return table|nil rule cloned snapshot of the stored record, or nil when rejected
function RLHerdsmanRuleService:create(rule)
    if rule == nil then
        Log:warning("RLHerdsmanRuleService:create: nil rule; rejecting")
        return nil
    end

    local ok, reason = validateRuleFields(rule)
    if not ok then
        Log:warning("RLHerdsmanRuleService:create: rejected (%s)", tostring(reason))
        return nil
    end

    -- Assign the id on the caller's table so `Utils.getUniqueId`'s collision-table semantics work,
    -- then clone into the registry.
    rule.id = Utils.getUniqueId(rule, self.rulesById, RLHerdsmanRuleService.UNIQUE_ID_PREFIX)
    rule.version = rule.version or RLHerdsmanRuleService.DEFAULT_VERSION

    local stored = cloneRule(rule)
    self.rulesById[stored.id] = stored

    Log:debug("RLHerdsmanRuleService:create: id=%s name=%s operation=%s farmId=%s enabled=%s targets=%d filterId=%s",
        tostring(stored.id), tostring(stored.name), tostring(stored.operation),
        tostring(stored.farmId), tostring(stored.enabled),
        #stored.targetHusbandries, tostring(stored.filterId))

    -- Dispatch AFTER the local store: the caller mutates first, then the event rebroadcasts the
    -- snapshot. Module-qualified, not via self, so a test swap of the hook field is observed.
    RLHerdsmanRuleService._sendCreateEvent(stored)

    return cloneRule(stored)
end

--- Look up a rule by id, as a cloned snapshot.
---@param id string
---@return table|nil
function RLHerdsmanRuleService:getById(id)
    local r = self.rulesById[id]
    Log:trace("RLHerdsmanRuleService:getById: id=%s found=%s", tostring(id), tostring(r ~= nil))
    return cloneRule(r)
end

--- Apply a whole-object update, replacing only the mutable fields. Rejected - with a warning and
--- state unchanged - on a nil id or payload, an unknown id, an id/farmId/version that differs from
--- the stored record, or a payload that violates the floor. Whole-object replacement, because a
--- partial payload would silently collapse the rule.
---
--- No-op skip: when the re-pinned payload equals the stored record, the update leaves state
--- unchanged, skips the broadcast, and returns a clone of the existing record. That is still a
--- success, not a rejection.
---@param id string lookup id
---@param payload table whole-object replacement payload
---@return table|nil updated cloned snapshot of the stored record
function RLHerdsmanRuleService:update(id, payload)
    if id == nil or payload == nil then
        Log:warning("RLHerdsmanRuleService:update: nil id or payload; rejecting")
        return nil
    end

    local existing = self:_rawGetById(id)
    if existing == nil then
        Log:warning("RLHerdsmanRuleService:update: unknown id '%s'; rejecting", tostring(id))
        return nil
    end

    if payload.id ~= id then
        Log:warning("RLHerdsmanRuleService:update: payload.id='%s' does not match lookup id='%s'; rejecting (id is immutable)",
            tostring(payload.id), tostring(id))
        return nil
    end

    if payload.farmId ~= existing.farmId then
        Log:warning("RLHerdsmanRuleService:update: payload.farmId=%s does not match stored farmId=%s; rejecting (farmId is immutable)",
            tostring(payload.farmId), tostring(existing.farmId))
        return nil
    end

    if payload.version ~= existing.version then
        Log:warning("RLHerdsmanRuleService:update: payload.version=%s does not match stored version=%s; rejecting (version is immutable)",
            tostring(payload.version), tostring(existing.version))
        return nil
    end

    local ok, reason = validateRuleFields(payload)
    if not ok then
        Log:warning("RLHerdsmanRuleService:update: id=%s rejected (%s); state unchanged", tostring(id), tostring(reason))
        return nil
    end

    -- Immutable fields are re-pinned from the existing record, so even a divergent payload could not
    -- persist a change.
    local stored = cloneRule(payload)
    stored.id      = id
    stored.farmId  = existing.farmId
    stored.version = existing.version

    -- Compare the re-pinned `stored` against `existing`, not the raw payload, so the re-pinning can
    -- never fabricate a false diff.
    if RLHerdsmanRuleService.equals(stored, existing) then
        Log:debug("RLHerdsmanRuleService:update: id=%s payload == stored; skipping RLHerdsmanRuleUpdateEvent (no-op)", tostring(id))
        return cloneRule(existing)
    end

    self.rulesById[id] = stored

    Log:debug("RLHerdsmanRuleService:update: id=%s applied (name=%s operation=%s enabled=%s targets=%d filterId=%s)",
        id, tostring(stored.name), tostring(stored.operation), tostring(stored.enabled),
        #stored.targetHusbandries, tostring(stored.filterId))

    RLHerdsmanRuleService._sendUpdateEvent(stored)

    return cloneRule(stored)
end

--- Remove the rule with the given id.
---@param id string
---@return boolean removed false when the id was unknown
function RLHerdsmanRuleService:delete(id)
    if id == nil or self:_rawGetById(id) == nil then
        Log:warning("RLHerdsmanRuleService:delete: unknown id '%s'; no-op", tostring(id))
        return false
    end

    self.rulesById[id] = nil
    Log:debug("RLHerdsmanRuleService:delete: id=%s removed", tostring(id))

    RLHerdsmanRuleService._sendDeleteEvent(id)

    return true
end

-- =============================================================================
-- Queries
-- =============================================================================

--- All stored rules as an array of defensive clones. Order is undefined - the run / visual order is
--- computed by the presenter and applied by the day-tick, not here.
---@return table[] rules cloned snapshots
function RLHerdsmanRuleService:list()
    local out = {}
    for _, r in pairs(self.rulesById) do
        table.insert(out, cloneRule(r))
    end
    Log:trace("RLHerdsmanRuleService:list: #=%d", #out)
    return out
end

--- Rules whose frozen `farmId` matches, as cloned snapshots. Order is undefined - see `list`.
---@param farmId integer owning farm id to match against
---@return table[] rules cloned snapshots
function RLHerdsmanRuleService:listForFarm(farmId)
    local out = {}
    for _, r in pairs(self.rulesById) do
        if r.farmId == farmId then
            table.insert(out, cloneRule(r))
        end
    end
    Log:trace("RLHerdsmanRuleService:listForFarm: farmId=%s #=%d", tostring(farmId), #out)
    return out
end

--- Empty the registry, so the persistence load path can clear before reading.
function RLHerdsmanRuleService:clear()
    self.rulesById = {}
    Log:debug("RLHerdsmanRuleService:clear: state emptied")
end

-- =============================================================================
-- Naming cursor - server-only day-tick state
-- =============================================================================

--- Advance the stored alphabetical-naming cursor for a rule, in place on the LIVE record. Every
--- public getter returns a defensive clone, so this `_rawGetById` write is the single in-place path.
--- The cursor is server-authoritative day-tick state, so it persists on the next save and broadcasts
--- no update event; client replicas hold a stale `params.previous` until the next full state sync.
--- Fails closed on an unknown id or a missing `params` table.
---@param id string rule id
---@param previous string|nil advanced cursor value to store at `params.previous`
---@return boolean written true iff the cursor was written to a live record
function RLHerdsmanRuleService:setNamingCursor(id, previous)
    local stored = self:_rawGetById(id)
    if stored == nil then
        Log:warning("RLHerdsmanRuleService:setNamingCursor: unknown id '%s' (rule deleted mid-tick?); no-op", tostring(id))
        return false
    end
    if type(stored.params) ~= "table" then
        Log:warning("RLHerdsmanRuleService:setNamingCursor: id=%s has no params table (params=%s); no-op",
            tostring(id), tostring(stored.params))
        return false
    end

    stored.params.previous = previous
    Log:debug("RLHerdsmanRuleService:setNamingCursor: id=%s params.previous=%s (server-only, no broadcast)",
        tostring(id), tostring(previous))
    return true
end

-- =============================================================================
-- XML IO
-- =============================================================================

--- Serialize every stored rule under `baseKey`. Rules are sorted by id so the on-disk key order is
--- deterministic across save cycles. Assumes a FRESH or caller-cleared subtree: it does not clear
--- stale `rule(i)` nodes.
---@param xmlFile table XMLFile handle
---@param baseKey string e.g. `RLHerdsmanRuleService.XML_BASE_KEY`
function RLHerdsmanRuleService:saveToXMLFile(xmlFile, baseKey)
    if xmlFile == nil then
        Log:warning("RLHerdsmanRuleService:saveToXMLFile: nil xmlFile; skipping")
        return
    end

    local rules = self:list()
    table.sort(rules, function(a, b) return tostring(a.id) < tostring(b.id) end)

    -- `writeRule` fail-closes on a malformed record, so advancing the on-disk index only on success
    -- keeps the sequence gap-free; a gap would truncate the iterate on load.
    local written = 0
    for _, r in ipairs(rules) do
        local ruleKey = string.format("%s.rule(%d)", baseKey, written)
        if RLHerdsmanRuleSerialization.writeRule(xmlFile, ruleKey, r) then
            written = written + 1
        end
    end

    Log:debug("RLHerdsmanRuleService:saveToXMLFile: baseKey=%s listed=%d wrote=%d rules (sorted by id)", baseKey, #rules, written)
end

--- Clear existing state, then deserialize every rule under `baseKey`. Records that fail the
--- serializer's fail-closed guards are skipped, and a duplicate `#id` is skipped rather than
--- clobbering - duplicate ids are corruption, so the first record wins.
---
--- `iterate` is wrapped in `pcall` so a malformed rule that hard-errors cannot abort the surrounding
--- settings load. Partial survivors are kept, non-atomically by design.
---@param xmlFile table XMLFile handle
---@param baseKey string e.g. `RLHerdsmanRuleService.XML_BASE_KEY`
function RLHerdsmanRuleService:loadFromXMLFile(xmlFile, baseKey)
    if xmlFile == nil then
        Log:warning("RLHerdsmanRuleService:loadFromXMLFile: nil xmlFile; skipping")
        return
    end

    self:clear()
    local loaded = 0

    local ok, err = pcall(function()
        xmlFile:iterate(baseKey .. ".rule", function(_, ruleKey)
            local r = RLHerdsmanRuleSerialization.readRule(xmlFile, ruleKey)
            if r ~= nil then
                if self.rulesById[r.id] ~= nil then
                    Log:warning("RLHerdsmanRuleService:loadFromXMLFile: duplicate id '%s' at %s; skipping (first record kept, no clobber)",
                        tostring(r.id), tostring(ruleKey))
                else
                    self.rulesById[r.id] = r
                    loaded = loaded + 1
                end
            end
        end)
    end)

    if not ok then
        Log:warning("RLHerdsmanRuleService:loadFromXMLFile: iterate errored after %d rules loaded; keeping partial state (%s)",
            loaded, tostring(err))
    end

    Log:debug("RLHerdsmanRuleService:loadFromXMLFile: baseKey=%s loaded=%d rules", baseKey, loaded)
end

-- =============================================================================
-- MP events
-- =============================================================================

--- Swappable dispatch hook: fire the Create event. Nil-guards the event class so an offline or
--- source-order path is a safe no-op; tests swap this field to observe the payload.
---@param rule table the stored rule snapshot to broadcast
RLHerdsmanRuleService._sendCreateEvent = function(rule)
    if RLHerdsmanRuleCreateEvent == nil then
        Log:trace("RLHerdsmanRuleService._sendCreateEvent: RLHerdsmanRuleCreateEvent not loaded; no dispatch (offline/source-order path)")
        return
    end
    RLHerdsmanRuleCreateEvent.sendEvent(rule)
end

--- Swappable dispatch hook: fire the Update event. @see RLHerdsmanRuleService._sendCreateEvent.
---@param rule table the stored rule snapshot to broadcast
RLHerdsmanRuleService._sendUpdateEvent = function(rule)
    if RLHerdsmanRuleUpdateEvent == nil then
        Log:trace("RLHerdsmanRuleService._sendUpdateEvent: RLHerdsmanRuleUpdateEvent not loaded; no dispatch (offline/source-order path)")
        return
    end
    RLHerdsmanRuleUpdateEvent.sendEvent(rule)
end

--- Swappable dispatch hook: fire the Delete event. @see RLHerdsmanRuleService._sendCreateEvent.
---@param id string the removed rule id to broadcast
RLHerdsmanRuleService._sendDeleteEvent = function(id)
    if RLHerdsmanRuleDeleteEvent == nil then
        Log:trace("RLHerdsmanRuleService._sendDeleteEvent: RLHerdsmanRuleDeleteEvent not loaded; no dispatch (offline/source-order path)")
        return
    end
    RLHerdsmanRuleDeleteEvent.sendEvent(id)
end

--- Apply a rule create received from the network. Unlike `create` it assigns no id - the wire's is
--- authoritative - and re-dispatches nothing. It re-enforces the validity floor, because the typed
--- codec guarantees field TYPES but neither enum validity nor a non-empty name. An id already
--- present locally is overwritten with the authoritative clone.
---@param rule table rule record reconstructed from the wire
---@return boolean applied true when stored, false when dropped
function RLHerdsmanRuleService:applyIncomingCreate(rule)
    if rule == nil or rule.id == nil or rule.id == "" then
        Log:warning("RLHerdsmanRuleService:applyIncomingCreate: malformed payload (id=%s); dropping",
            tostring(rule and rule.id))
        return false
    end

    local ok, reason = validateRuleFields(rule)
    if not ok then
        Log:warning("RLHerdsmanRuleService:applyIncomingCreate: id=%s rejected (%s); not stored (MP floor enforcement)",
            tostring(rule.id), tostring(reason))
        return false
    end

    -- Server-authoritative state wins, but an existing record means something is off upstream.
    if self.rulesById[rule.id] ~= nil then
        Log:warning("RLHerdsmanRuleService:applyIncomingCreate: id=%s already present locally; overwriting with authoritative payload (possible id collision or duplicate broadcast)",
            tostring(rule.id))
    end

    self.rulesById[rule.id] = cloneRule(rule)
    Log:debug("RLHerdsmanRuleService:applyIncomingCreate: id=%s name=%s operation=%s farmId=%s enabled=%s targets=%d filterId=%s",
        tostring(rule.id), tostring(rule.name), tostring(rule.operation),
        tostring(rule.farmId), tostring(rule.enabled),
        type(rule.targetHusbandries) == "table" and #rule.targetHusbandries or 0,
        tostring(rule.filterId))
    return true
end

--- Apply a rule update received from the network: whole-object replacement over any local copy, no
--- re-dispatch, and the same floor re-enforcement `applyIncomingCreate` uses. An id unknown locally
--- is warned - a possible missed create - and UPSERTED, since the payload carries the whole object.
---@param rule table rule record reconstructed from the wire
---@return boolean applied true when stored, false when dropped (malformed / floor violation)
function RLHerdsmanRuleService:applyIncomingUpdate(rule)
    if rule == nil or rule.id == nil or rule.id == "" then
        Log:warning("RLHerdsmanRuleService:applyIncomingUpdate: malformed payload (id=%s); dropping",
            tostring(rule and rule.id))
        return false
    end

    local ok, reason = validateRuleFields(rule)
    if not ok then
        Log:warning("RLHerdsmanRuleService:applyIncomingUpdate: id=%s farmId=%s rejected (%s); not stored (MP floor enforcement)",
            tostring(rule.id), tostring(rule.farmId), tostring(reason))
        return false
    end

    -- The server rejects updates on unknown ids, so a local receiver applying one missed the create.
    if self.rulesById[rule.id] == nil then
        Log:warning("RLHerdsmanRuleService:applyIncomingUpdate: id=%s unknown locally; acting as upsert (possible missed create)",
            tostring(rule.id))
    end

    self.rulesById[rule.id] = cloneRule(rule)
    Log:debug("RLHerdsmanRuleService:applyIncomingUpdate: id=%s name=%s operation=%s farmId=%s enabled=%s targets=%d filterId=%s",
        tostring(rule.id), tostring(rule.name), tostring(rule.operation),
        tostring(rule.farmId), tostring(rule.enabled),
        type(rule.targetHusbandries) == "table" and #rule.targetHusbandries or 0,
        tostring(rule.filterId))
    return true
end

--- Remove a rule in response to the Delete event. A no-op on an unknown id, logged at trace since
--- the server already validated - it just means this peer never had it. Re-dispatches nothing.
---@param id string rule id to remove
---@return boolean applied true when removed, false when malformed or already gone
function RLHerdsmanRuleService:applyIncomingDelete(id)
    if id == nil or id == "" then
        Log:warning("RLHerdsmanRuleService:applyIncomingDelete: nil/empty id; dropping")
        return false
    end

    if self.rulesById[id] == nil then
        Log:trace("RLHerdsmanRuleService:applyIncomingDelete: id=%s not present locally (already gone)",
            tostring(id))
        return false
    end

    self.rulesById[id] = nil
    Log:debug("RLHerdsmanRuleService:applyIncomingDelete: id=%s removed", tostring(id))
    return true
end

-- Eager source-time singleton, so every consumer sees a live registry regardless of the order load
-- hooks wire up. main.lua's source order guarantees this line runs before any consumer.
g_rlHerdsmanRuleService = RLHerdsmanRuleService.new()

Log:trace("RLHerdsmanRuleService: loaded")
