-- RLHerdsmanRuleService.lua
-- Singleton CRUD service for the Herdsman rule registry.
--
-- Owns the in-memory rule registry `self.rulesById` and assigns stable ids on
-- create via `Utils.getUniqueId`. A rule binds at most one saved filter (nil = an
-- unfiltered draft) + operation params to a set of target husbandry placeables. Structural sibling
-- of `RLFilterService`: same in-memory CRUD + immutability + defensive-clone
-- discipline, PLUS XML persistence and MP create/update/delete/state sync.
--
-- Rule record (frozen / mutable split):
--   * `id`, `farmId`, `version` are frozen after create.
--   * `name`, `operation`, `enabled`, `filterId`, `targetHusbandries`, `params`
--     are mutable via `update`.
--   * Violations are rejected with `:warning` and leave state unchanged.
--
-- Validity floor (enforced on BOTH create and update):
--   * `name`              non-empty string
--   * `operation`         one of sell|move|buy|castrate|naming|ai|horseCare
--   * `farmId`            integer (the owning farm)
--   * `enabled`           boolean
--   * `params`            table (opaque here; the per-operation codec is S2)
--   * `targetHusbandries` array (may be empty -> inert rule, no targets)
--   * `filterId`          every operation except naming: nil (incomplete draft) OR a
--                          non-empty (non-whitespace) string; naming: MUST be nil
--
-- Scope boundary (deliberately NOT here):
--   * No per-operation `params` validation, no filterId resolution against
--     RLFilterService, no targetHusbandries uniqueId -> live-placeable
--     resolution. Those belong to the M-Frame picker/validator and the M-Tick
--     day-tick respectively; the service stores the strings as given.
--
-- Ownership contract:
--   * Every boundary into/out of the registry performs a defensive deep copy of
--     the rule record (scalars shallow-copied, `targetHusbandries` array-copied,
--     `params` recursively deep-cloned). Callers cannot mutate stored state by
--     retaining a reference to a returned record. Applies to:
--       - `create`  (clone input before storing)
--       - `getById` / `list` / `listForFarm` (clone stored before returning)
--   * Internal calls that need the live reference use `_rawGetById`.

local Log = RmLogging.getLogger("RLRM")

RLHerdsmanRuleService = {}
local RLHerdsmanRuleService_mt = { __index = RLHerdsmanRuleService }

--- Prefix used by `Utils.getUniqueId` for rule ids. Follows the
--- `UNIQUE_ID_PREFIX` convention (mirrors `RLFilterService.UNIQUE_ID_PREFIX`).
RLHerdsmanRuleService.UNIQUE_ID_PREFIX = "rlHerdRule_"

--- Canonical operation set. A rule's `operation` MUST be one of these keys.
--- Kept as a set for O(1) validation. The canonical run / visual ORDER of these
--- operations lives in `OPERATION_ORDER` below - the service owns it now (M-Tick T1)
--- so the M-Frame presenter and the M-Tick planner share one source of truth.
RLHerdsmanRuleService.OPERATIONS = {
    sell      = true,
    move      = true,
    buy       = true,
    castrate  = true,
    naming    = true,
    ai        = true,
    horseCare = true,
}

--- Canonical run / visual order for the operations (D3 "visual order = run
--- order"): Sell frees herd space before Buy fills it, mirroring legacy
--- `AIAnimalManager:onDayChanged`. The single source of truth for all THREE consumers -
--- the M-Frame presenter (section placement), the M-Tick planner (run order), and the
--- presenter's legacy-active banner sweep. Each consumer derives its own operation ->
--- rank map from this list (no shared rank table, so a consumer's load order can never
--- read a half-built map).
---
--- APPEND-ONLY at the TAIL. The frame binds the operation selector's widget state to the
--- ARRAY INDEX, so inserting anywhere but the end silently reassigns every later
--- operation's state.
RLHerdsmanRuleService.OPERATION_ORDER = { "sell", "move", "buy", "castrate", "naming", "ai", "horseCare" }

--- Within-operation comparator: alphabetical by name (case-insensitive), with a
--- nil-safe `tostring(id)` tie-break. Persisted records always carry an id, so the
--- tie-break is deterministic (mirrors `saveToXMLFile`'s id sort). Hoisted here from
--- the presenter (M-Tick T1) so the presenter's section sort and the planner's
--- within-op run-order sort cannot drift. Generic over any `{ name, id }` record, so
--- the presenter reuses it for filter lists too.
---@param a table record with `name` + `id`
---@param b table record with `name` + `id`
---@return boolean
function RLHerdsmanRuleService.compareRulesByName(a, b)
    local an = string.lower(tostring(a.name or ""))
    local bn = string.lower(tostring(b.name or ""))
    if an ~= bn then return an < bn end
    return tostring(a.id) < tostring(b.id)
end

--- Default `version` assigned on create when the caller omits one. Frozen after
--- create; exists for the S3 wire / S5 state-convergence layers (UInt16 later),
--- mirroring `RLFilterService`. Not bumped on update in S1.
RLHerdsmanRuleService.DEFAULT_VERSION = 1

--- On-disk root for the rule registry inside `rm_RlSettings.xml` (S2). Mirrors
--- `RLFilterService.XML_BASE_KEY`; both registries share that one file (the
--- filters under `rm_RlSettings.filters`, the rules under this key), each with
--- its own error boundary on load.
RLHerdsmanRuleService.XML_BASE_KEY = "rm_RlSettings.herdsmanRules"

-- =============================================================================
-- Deep copy
-- =============================================================================

--- Recursively deep-copy an opaque value. Scalars pass by value; tables are
--- cloned key-by-key (recursing into nested tables, e.g. Buy `budget`). The
--- `params` table is opaque to S1, so this makes no assumptions about its shape.
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

--- Shallow-clone the rule's top-level scalars, array-copy `targetHusbandries`,
--- and deep-clone `params`. Matches the ownership contract: a returned record
--- can never mutate stored state.
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

--- Exposed for tests + future event handlers that need the same clone contract.
RLHerdsmanRuleService._cloneRule = cloneRule

-- =============================================================================
-- Validity floor
-- =============================================================================

--- True when `t` is a dense array (contiguous integer keys 1..#t, no map-shaped
--- or sparse keys). An empty table counts as a (degenerate) dense array. Used to
--- enforce the floor's "targetHusbandries is an array" rule: a map-shaped value
--- like `{ main = "x" }` or a sparse value like `{ [2] = "x" }` would otherwise
--- pass a bare `type == "table"` check and then be silently collapsed to `{}` by
--- `cloneRule`'s `ipairs` copy - data loss masquerading as an inert rule. The
--- floor rejects it instead (state unchanged).
---@param t table
---@return boolean
local function isDenseArray(t)
    local count = 0
    for _ in pairs(t) do count = count + 1 end
    return count == #t
end

--- Validate a candidate rule against the validity floor (the record rules).
--- Used by BOTH `create` and `update` so the same constraints gate every write.
--- Returns `true` on success, or `false` plus a short reason string a caller can
--- surface in a `:warning`. Does NOT mutate the rule.
---
--- Enforces: non-empty string `name`; `operation` in the canonical set; integer
--- `farmId`; boolean `enabled`; table `params`; array (table) `targetHusbandries`;
--- and the filterId-vs-operation rule (naming MUST have nil filterId; every other
--- operation may carry a nil filterId - an incomplete draft - or, when present, a
--- non-empty (non-whitespace) string filterId). Element typing of `targetHusbandries`
--- and per-operation `params` shape are intentionally NOT checked here (M-Tick /
--- S2 concerns).
---@param r table|nil
---@return boolean ok
---@return string|nil reason
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
    -- filterId-vs-operation (D6): naming carries no filter; a non-naming rule
    -- binds at most one filter by id - nil is a legal incomplete draft (the rule is
    -- inert until a filter is picked), and a present filterId must stay a non-empty
    -- (non-whitespace) string. Resolution against RLFilterService is deferred to
    -- M-Frame; "needs a filter to actually run" is enforced at the day-tick.
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

--- Exposed for tests that want to assert the floor directly.
RLHerdsmanRuleService._validateRuleFields = validateRuleFields

-- =============================================================================
-- Record equality (no-op-diff support)
-- =============================================================================

--- Shared empty-table sentinel for `deepEqual`'s nil-as-empty arm, so that path
--- allocates nothing. Read-only: never mutated.
local EMPTY = {}

--- Order-insensitive multiset equality for two arrays of strings (the rule's
--- `targetHusbandries`). nil is treated as the empty set, so an absent list and an
--- empty `{}` compare equal. Compares element multiplicity, not order: a re-ordered
--- but same-membership set is equal; an added / removed / duplicated element is not.
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

--- Deep value-equality with the registry's two conventions: nil and an empty table
--- compare equal (an absent `params` key == an empty `params`, including a nested
--- `budget`), and non-table leaves fall back to `==`. Recurses every key of both
--- tables, treating an absent key as a nil value. NOT multiset-aware - the caller
--- routes `targetHusbandries` through `multisetEqual`.
---@param a any
---@param b any
---@return boolean equal
local function deepEqual(a, b)
    local ta, tb = type(a), type(b)
    if ta ~= "table" and tb ~= "table" then
        return a == b
    end
    -- One side is a table; treat a nil counterpart as an empty table. A non-nil,
    -- non-table counterpart stays a `==` mismatch (-> false).
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

--- Whole-record equality for two rule records - the no-op-diff predicate behind
--- `update`'s "a byte-identical update never broadcasts" invariant. Pure: plain data
--- in, boolean out. Deep over every key, so it needs NO hand-maintained field list
--- that could drift from `validateRuleFields` / `cloneRule`; the immutable
--- id / farmId / version are equal by construction at the no-op site, so the only
--- differences it can surface are mutable. Two conventions: `targetHusbandries` is
--- compared as an order-insensitive multiset, and every other key (scalars plus the
--- nested `params` / `budget` tables) by deep value-equality with nil == empty-table.
--- Non-table arguments fall back to `==`.
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

--- Construct a new, empty service instance. There is conceptually one per game
--- session (`g_rlHerdsmanRuleService`), but the constructor is instance-safe so
--- tests can spin up isolated services.
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

--- Return the stored record WITHOUT cloning. Internal use only -- callers must
--- not mutate the returned table. Used by the validation paths in `update` /
--- `delete` where a clone would just be thrown away.
---@param id string|nil
---@return table|nil stored
function RLHerdsmanRuleService:_rawGetById(id)
    if id == nil then return nil end
    return self.rulesById[id]
end

-- =============================================================================
-- CRUD
-- =============================================================================

--- Create a new rule. Validates the validity floor FIRST (rejecting with
--- `:warning` and storing nothing on failure), then assigns a unique `id` via
--- `Utils.getUniqueId` with the registry as the collision table, defaults
--- `version` to `DEFAULT_VERSION` when absent, and stores a defensive clone.
---
--- Returns a cloned snapshot of the stored record on success (with `id`
--- populated), or nil when the input was nil or failed the floor.
---@param rule table rule record (without id)
---@return table|nil rule cloned snapshot of the stored record
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

    -- Assign id on the caller's table so `Utils.getUniqueId`'s collision-table
    -- semantics work, then clone into the registry.
    rule.id = Utils.getUniqueId(rule, self.rulesById, RLHerdsmanRuleService.UNIQUE_ID_PREFIX)
    rule.version = rule.version or RLHerdsmanRuleService.DEFAULT_VERSION

    local stored = cloneRule(rule)
    self.rulesById[stored.id] = stored

    Log:debug("RLHerdsmanRuleService:create: id=%s name=%s operation=%s farmId=%s enabled=%s targets=%d filterId=%s",
        tostring(stored.id), tostring(stored.name), tostring(stored.operation),
        tostring(stored.farmId), tostring(stored.enabled),
        #stored.targetHusbandries, tostring(stored.filterId))

    -- Dispatch the Create event AFTER the local store (Pattern A: the caller mutates
    -- first, then the event rebroadcasts the snapshot to remote machines). Called
    -- module-qualified, not via self, so a test swap of the hook field is observed.
    RLHerdsmanRuleService._sendCreateEvent(stored)

    return cloneRule(stored)
end

--- Look up a rule by id. Returns a cloned snapshot of the stored record so
--- callers cannot mutate state via the returned reference.
---@param id string
---@return table|nil
function RLHerdsmanRuleService:getById(id)
    local r = self.rulesById[id]
    Log:trace("RLHerdsmanRuleService:getById: id=%s found=%s", tostring(id), tostring(r ~= nil))
    return cloneRule(r)
end

--- Apply a whole-object update. Replaces only the mutable fields (name,
--- operation, enabled, filterId, targetHusbandries, params). Rejects the call
--- (and logs `:warning`, state unchanged) when:
---   * id or payload is nil,
---   * the id is unknown,
---   * `payload.id` / `payload.farmId` / `payload.version` differ from the
---     stored record (those fields are immutable post-create), or
---   * the payload omits any required field / violates the validity floor.
---
--- Whole-object replacement: a partial payload that omits a mutable field would
--- silently collapse the rule, so it is rejected rather than merged. Returns a
--- cloned snapshot of the new stored record on success.
---
--- No-op skip: when the re-pinned payload equals the stored record (`equals`), the
--- update is a no-op - it leaves state unchanged, skips the `RLHerdsmanRuleUpdateEvent`
--- broadcast, and returns a clone of the existing record. This is still a success
--- (NOT a rejection); the return type is unchanged.
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

    -- Completeness + floor: `update` is whole-object replacement, so every
    -- required field must be present and valid (a missing field would silently
    -- nil out a mutable property on the next read).
    local ok, reason = validateRuleFields(payload)
    if not ok then
        Log:warning("RLHerdsmanRuleService:update: id=%s rejected (%s); state unchanged", tostring(id), tostring(reason))
        return nil
    end

    -- Build the new stored record. Immutable fields are re-pinned from the
    -- existing record so even a divergent payload could not persist a change.
    local stored = cloneRule(payload)
    stored.id      = id
    stored.farmId  = existing.farmId
    stored.version = existing.version

    -- No-op diff: a byte-identical update must not broadcast. Compare the re-pinned
    -- `stored` against `existing` (not the raw payload) so the immutable re-pinning can
    -- never fabricate a false diff. On a match, leave the registry untouched, skip the
    -- broadcast, and return the existing snapshot - callers still see a normal success.
    if RLHerdsmanRuleService.equals(stored, existing) then
        Log:debug("RLHerdsmanRuleService:update: id=%s payload == stored; skipping RLHerdsmanRuleUpdateEvent (no-op)", tostring(id))
        return cloneRule(existing)
    end

    self.rulesById[id] = stored

    Log:debug("RLHerdsmanRuleService:update: id=%s applied (name=%s operation=%s enabled=%s targets=%d filterId=%s)",
        id, tostring(stored.name), tostring(stored.operation), tostring(stored.enabled),
        #stored.targetHusbandries, tostring(stored.filterId))

    -- Dispatch the Update event AFTER the local store (Pattern A: the caller mutates first,
    -- then the event rebroadcasts the snapshot to remote machines). Called module-qualified,
    -- not via self, so a test swap of the hook field is observed.
    RLHerdsmanRuleService._sendUpdateEvent(stored)

    return cloneRule(stored)
end

--- Remove the rule with the given id. Returns true on success, false when the
--- id was unknown (logged at `:warning`).
---@param id string
---@return boolean removed
function RLHerdsmanRuleService:delete(id)
    if id == nil or self:_rawGetById(id) == nil then
        Log:warning("RLHerdsmanRuleService:delete: unknown id '%s'; no-op", tostring(id))
        return false
    end

    self.rulesById[id] = nil
    Log:debug("RLHerdsmanRuleService:delete: id=%s removed", tostring(id))

    -- Dispatch the Delete event AFTER the local removal (Pattern A). Module-qualified so a
    -- test swap of the hook field is observed.
    RLHerdsmanRuleService._sendDeleteEvent(id)

    return true
end

-- =============================================================================
-- Queries
-- =============================================================================

--- All stored rules as an array. Order is undefined (Lua `pairs`); the
--- Herdsman run/visual order is computed by the M-Frame presenter and applied
--- by the M-Tick day-tick, NOT here. Returned records are defensive clones.
---@return table[] rules cloned snapshots
function RLHerdsmanRuleService:list()
    local out = {}
    for _, r in pairs(self.rulesById) do
        table.insert(out, cloneRule(r))
    end
    Log:trace("RLHerdsmanRuleService:list: #=%d", #out)
    return out
end

--- Rules whose frozen `farmId` equals `farmId` (farmId is the owning farm),
--- as cloned snapshots. Order is undefined (see `list`).
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

--- Empty the registry. Provided for symmetry with `RLFilterService` and so the
--- persistence-load path (S2) can clear before reading.
function RLHerdsmanRuleService:clear()
    self.rulesById = {}
    Log:debug("RLHerdsmanRuleService:clear: state emptied")
end

-- =============================================================================
-- Naming cursor (M-Tick T3) - server-only day-tick state
-- =============================================================================

--- Advance the stored alphabetical-naming cursor for a rule, in place on the LIVE record.
--- Additive M-Tick write: `getById` / `list` / `listForFarm` all return defensive clones, so
--- the day-tick executor cannot persist the advanced cursor through the plan it received -
--- this `_rawGetById` write is the single in-place path. The cursor is server-authoritative
--- day-tick state (clients never run the naming tick), so it persists via `saveToXMLFile` on
--- the next save and broadcasts NO `RLHerdsmanRuleUpdateEvent`. Honest consequence: client
--- replicas hold a stale `params.previous` until the next full state sync - intended and
--- harmless. Fails closed: an unknown id (rule deleted mid-tick) or a missing `params` table
--- warns + returns false, never raising.
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
-- XML IO (S2)
-- =============================================================================

--- Serialize every stored rule under `baseKey` via
--- `RLHerdsmanRuleSerialization.writeRule`. No-op when xmlFile is nil
--- (defensive; the RLSettings caller already guards).
---
--- Rules are sorted by id before writing so the on-disk key order
--- (`rule(0)`, `rule(1)`, ...) is deterministic across save cycles. Assumes a
--- FRESH (or caller-cleared) subtree under `baseKey`: it does NOT clear stale
--- `rule(i)` nodes (same contract as `RLFilterService:saveToXMLFile`;
--- production always passes a freshly `XMLFile.create`d handle via
--- `RLSettings.saveToXMLFile`).
---@param xmlFile table XMLFile handle
---@param baseKey string e.g. `RLHerdsmanRuleService.XML_BASE_KEY`
function RLHerdsmanRuleService:saveToXMLFile(xmlFile, baseKey)
    if xmlFile == nil then
        Log:warning("RLHerdsmanRuleService:saveToXMLFile: nil xmlFile; skipping")
        return
    end

    local rules = self:list()
    table.sort(rules, function(a, b) return tostring(a.id) < tostring(b.id) end)

    -- Contiguous write-index: `writeRule` fail-closes (returns false, writes
    -- nothing) on a malformed record, so advancing the on-disk `rule(i)` index
    -- only on success keeps the indexed sequence gap-free (a gap would truncate
    -- the iterate on load). Mirrors RLFilterSerialization.writeGroup's condIdx.
    local written = 0
    for _, r in ipairs(rules) do
        local ruleKey = string.format("%s.rule(%d)", baseKey, written)
        if RLHerdsmanRuleSerialization.writeRule(xmlFile, ruleKey, r) then
            written = written + 1
        end
    end

    Log:debug("RLHerdsmanRuleService:saveToXMLFile: baseKey=%s listed=%d wrote=%d rules (sorted by id)", baseKey, #rules, written)
end

--- Clear existing state then deserialize every rule under `baseKey` via
--- `RLHerdsmanRuleSerialization.readRule`. Records that fail the serializer's
--- fail-closed guards (missing id / unknown operation / missing farmId /
--- operation-invalid filterId / missing required param) are skipped (the
--- serializer logs the warning).
---
--- A duplicate `#id` on load is SKIPPED (not last-write-wins): duplicate ids are
--- corruption, so the first record wins and the duplicate is logged at
--- `:warning` - deliberately stronger than the filter precedent.
---
--- `iterate` is wrapped in `pcall`: a malformed rule that hard-errors deep in
--- the serializer must not propagate out and abort the surrounding
--- `RLSettings.loadRulesFromXMLFile`. Partial survivors are kept (non-atomic by
--- design, mirroring `RLFilterService:loadFromXMLFile`); the warning surfaces
--- the specific failure.
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
-- MP events (S3)
-- =============================================================================

--- Swappable dispatch hook: fire the Create event for `rule`. Nil-guards the event
--- class so an offline / source-order path (mod tests, constructor wiring before the
--- event is sourced) is a safe no-op. Tests swap this field to observe the create
--- payload without firing a real event.
---@param rule table the stored rule snapshot to broadcast
RLHerdsmanRuleService._sendCreateEvent = function(rule)
    if RLHerdsmanRuleCreateEvent == nil then
        Log:trace("RLHerdsmanRuleService._sendCreateEvent: RLHerdsmanRuleCreateEvent not loaded; no dispatch (offline/source-order path)")
        return
    end
    RLHerdsmanRuleCreateEvent.sendEvent(rule)
end

--- Swappable dispatch hook: fire the Update event for `rule`. Nil-guards the event class so
--- an offline / source-order path (mod tests, constructor wiring before the event is sourced)
--- is a safe no-op. Tests swap this field to observe the update payload without firing a real
--- event.
---@param rule table the stored rule snapshot to broadcast
RLHerdsmanRuleService._sendUpdateEvent = function(rule)
    if RLHerdsmanRuleUpdateEvent == nil then
        Log:trace("RLHerdsmanRuleService._sendUpdateEvent: RLHerdsmanRuleUpdateEvent not loaded; no dispatch (offline/source-order path)")
        return
    end
    RLHerdsmanRuleUpdateEvent.sendEvent(rule)
end

--- Swappable dispatch hook: fire the Delete event for `id`. Nil-guards the event class so an
--- offline / source-order path is a safe no-op. Tests swap this field to observe the deleted
--- id without firing a real event.
---@param id string the removed rule id to broadcast
RLHerdsmanRuleService._sendDeleteEvent = function(id)
    if RLHerdsmanRuleDeleteEvent == nil then
        Log:trace("RLHerdsmanRuleService._sendDeleteEvent: RLHerdsmanRuleDeleteEvent not loaded; no dispatch (offline/source-order path)")
        return
    end
    RLHerdsmanRuleDeleteEvent.sendEvent(id)
end

--- Apply a rule create received from the network (Pattern A receiver entry). Unlike
--- `create`, this does NOT assign an id (the id is authoritative from the wire) and
--- does NOT re-dispatch an event. It re-enforces the S1 validity floor so a crafted
--- payload that satisfied the typed codec (which guarantees field TYPES, not enum
--- validity or a non-empty name) cannot bypass the rule invariants -- the same
--- fail-closed posture the persistence load path uses. An id already present locally
--- is overwritten with the authoritative clone (`:warning`, convergence signal).
---@param rule table rule record reconstructed from the wire
---@return boolean applied true when stored, false when dropped
function RLHerdsmanRuleService:applyIncomingCreate(rule)
    if rule == nil or rule.id == nil or rule.id == "" then
        Log:warning("RLHerdsmanRuleService:applyIncomingCreate: malformed payload (id=%s); dropping",
            tostring(rule and rule.id))
        return false
    end

    -- MP must not bypass the S1 floor. The codec round-trips type-correct values but
    -- guarantees neither a valid operation enum nor a non-empty name, so re-validate
    -- and drop (no store) on failure.
    local ok, reason = validateRuleFields(rule)
    if not ok then
        Log:warning("RLHerdsmanRuleService:applyIncomingCreate: id=%s rejected (%s); not stored (MP floor enforcement)",
            tostring(rule.id), tostring(reason))
        return false
    end

    -- Surface a silent clobber. Server-authoritative state wins, but an existing
    -- record means something is off upstream (id collision, duplicate broadcast, or
    -- a state event arriving after create); overwrite with the authoritative clone.
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

--- Apply a rule update received from the network (Pattern A receiver entry). Whole-object
--- replacement: stores the wire-decoded record over any local copy. Does NOT re-dispatch an
--- event (the server's broadcast already fanned out). Re-enforces the S1 field floor -- the
--- typed codec guarantees field TYPES, not operation-enum validity or a non-empty name, so a
--- crafted payload that satisfied the codec must not bypass the rule invariants (the same
--- fail-closed posture `applyIncomingCreate` uses; wire-inbound and XML-inbound agree). An id
--- unknown locally is logged at `:warning` (a possible missed create) and UPSERTED, since the
--- update payload carries the whole object and reconstructs cleanly.
---@param rule table rule record reconstructed from the wire
---@return boolean applied true when stored, false when dropped (malformed / floor violation)
function RLHerdsmanRuleService:applyIncomingUpdate(rule)
    if rule == nil or rule.id == nil or rule.id == "" then
        Log:warning("RLHerdsmanRuleService:applyIncomingUpdate: malformed payload (id=%s); dropping",
            tostring(rule and rule.id))
        return false
    end

    -- MP must not bypass the S1 field floor (operation enum, non-empty name, integer farmId,
    -- params table, dense-array targets, filterId-vs-operation). Re-validate and drop (no
    -- store) on failure. NOTE: the floor validates FIELDS only, not per-operation params
    -- VALUES or targetHusbandries element typing (M-Tick / codec concerns).
    local ok, reason = validateRuleFields(rule)
    if not ok then
        Log:warning("RLHerdsmanRuleService:applyIncomingUpdate: id=%s farmId=%s rejected (%s); not stored (MP floor enforcement)",
            tostring(rule.id), tostring(rule.farmId), tostring(reason))
        return false
    end

    -- Surface update-acting-as-upsert: the server rejects updates on unknown ids, so a local
    -- receiver applying one means it missed the original create. Audible, then upsert.
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

--- Remove a rule in response to RLHerdsmanRuleDeleteEvent (Pattern A receiver entry). No-op
--- when the id is unknown locally (logged at `:trace` since the server already
--- authoritatively validated; an unknown id here just means this peer never had it). Does
--- NOT re-dispatch an event.
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

-- Eager source-time singleton. Constructing the service at source-time means
-- every consumer (the frame, the day-tick, the future event/persistence slices)
-- sees a live registry regardless of the order in which load hooks happen to
-- wire up - no consumer nil-check needed. main.lua's source order (RmLogging
-- first; utilities/services before consumers) guarantees this line runs before
-- any consumer.
g_rlHerdsmanRuleService = RLHerdsmanRuleService.new()

Log:trace("RLHerdsmanRuleService: loaded")
