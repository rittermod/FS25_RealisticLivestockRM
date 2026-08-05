-- RLHerdsmanRuleSerialization.lua
-- Flat-record XML writer/reader for Herdsman rule records.
--
-- Canonical XML key contract (under RLHerdsmanRuleService.XML_BASE_KEY =
-- "rm_RlSettings.herdsmanRules"):
--
--   rm_RlSettings.herdsmanRules.rule(i)
--     @id, @name, @farmId(int), @version(int), @operation, @enabled(bool)
--     @filterId                        -- omitted when nil (naming rules + unfiltered non-naming drafts)
--     .targetHusbandries.target(k)     -- @uniqueId per target string; none when empty
--     .params                          -- operation-specific subtree (PARAMS_CODECS)
--
-- A param-free operation (horseCare) emits NO `.params` node at all - its codec writes
-- nothing and reads back an empty table. The codec entry still has to exist: `writeRule`
-- resolves it before emitting any XML and skips the whole record when there is none, so a
-- missing entry silently drops the rule at save time rather than failing loudly.
--
-- Structural sibling of RLFilterSerialization (TYPE_CODECS -> PARAMS_CODECS,
-- writeFilter/readFilter -> writeRule/readRule) MINUS the recursive group/AST:
-- rule records are flat (scalars + a target list + an operation-keyed params
-- table), so there is no nested-group recursion here.
--
-- Per-operation params types are grounded in the legacy AI-animal job save/load
-- behavior. The rule keeps ONLY the operation params; the legacy
-- age/gender/disease/genetics selection block now lives in the rule's saved
-- filter, so it is intentionally absent here.
--
-- Defensive contracts (fail-closed; mirrors RLFilterSerialization skipping a
-- filter whose mandatory .group subtree is absent):
--  * readRule returns nil + :warning (the record is SKIPPED) when @id is
--    missing/empty, @operation is not a known operation, @farmId is absent,
--    @filterId violates the operation (present-but-empty/whitespace for non-naming,
--    or present at all for naming - the read-side twin of the service write floor;
--    an absent non-naming @filterId is a legal nil draft, NOT a skip), or ANY
--    required params field for the operation is absent. Required fields are
--    read with NO default: a nil read signals corruption, NOT a silent default
--    (diverges from legacy, which read params with defaults). A skipped record
--    never aborts the surrounding load.
--  * naming @previous is written ONLY when convention=="alphabetical" AND it is
--    a non-empty string (legacy parity); it is OPTIONAL
--    on read (absent -> nil).
--  * move @maxAnimals and @mark are required fields (nil on read -> record skipped); move
--    @destinationHusbandry mirrors @filterId - written ONLY when a non-empty/non-whitespace
--    string (absent -> an inert draft), an absent value reads back nil, and a present-but-
--    empty/whitespace value makes the codec read return nil so the WHOLE record is dropped
--    (the params-internal twin of the @filterId skip; enforced on write too via validate).
--  * a target whose @uniqueId is nil/empty is skipped on read (:trace), keeping
--    order and the non-empty strings. Duplicate-target dedup, uniqueId validity
--    and placeable resolution stay M-Tick (the S1 contract).

local Log = RmLogging.getLogger("RLRM")

RLHerdsmanRuleSerialization = {}

-- =============================================================================
-- Per-operation params codecs
-- =============================================================================

--- Per-operation params read/write functions, keyed by a rule's `operation`.
--- The set of keys IS the canonical operation whitelist used by `readRule` to
--- fail-closed on an unknown `@operation` (no codec -> skip the record), so it
--- stays in lockstep with `RLHerdsmanRuleService.OPERATIONS` without coupling
--- the serializer to the service at source time (serializer loads first).
---
--- `validate(params)` returns true iff `params` carries every REQUIRED field for
--- the operation (the same set `read` rejects a nil on). The service's validity
--- floor deliberately accepts ANY table-shaped `params` (per-op shape is an
--- M-Frame concern), so a structurally-incomplete record (e.g. `buy` with
--- `params={}`) can reach `writeRule`. `validate` lets `writeRule` fail-closed
--- BEFORE emitting any XML instead of dereferencing a nil sub-table (which would
--- crash the whole `RLSettings.saveToXMLFile`). Symmetric with `read`'s
--- required-field set; NOT value validation (that stays the picker's job).
--- `write(xmlFile, paramsKey, params)` emits the op's params under `paramsKey`.
--- `read(xmlFile, paramsKey)` returns the params table, or nil when a REQUIRED
--- field is absent (nil = corruption; the caller skips the whole record).
---@type table<string, { validate: fun(p:table):boolean, write: fun(x:table, k:string, p:table), read: fun(x:table, k:string):table|nil }>
local PARAMS_CODECS = {
    sell = {
        validate = function(p) return p.maxAnimals ~= nil and p.mark ~= nil end,
        write = function(x, k, p)
            x:setInt(k .. "#maxAnimals", p.maxAnimals)
            x:setBool(k .. "#mark", p.mark)
        end,
        read = function(x, k)
            local maxAnimals = x:getInt(k .. "#maxAnimals")
            local mark = x:getBool(k .. "#mark")
            if maxAnimals == nil or mark == nil then return nil end
            return { maxAnimals = maxAnimals, mark = mark }
        end,
    },
    move = {
        -- `maxAnimals` and `mark` are required fields. `maxAnimals` is required because the
        -- planner caps a move on it; a move that round-trips with no cap would silently no-op
        -- (the persistence gap this slice closes). `destinationHusbandry` mirrors the serializer's
        -- `filterId` floor: OPTIONAL (absent = an inert draft), but when present it must be a
        -- non-empty (non-whitespace) string - enforced at BOTH ends so an invalid in-memory dest
        -- is never silently laundered to disk (validate fails -> writeRule skips + :warning) and a
        -- present-but-empty/whitespace dest on load returns nil so readRule drops the WHOLE record.
        validate = function(p)
            return p.maxAnimals ~= nil and p.mark ~= nil
                and (p.destinationHusbandry == nil
                    or (type(p.destinationHusbandry) == "string" and p.destinationHusbandry:gsub("%s", "") ~= ""))
        end,
        write = function(x, k, p)
            x:setInt(k .. "#maxAnimals", p.maxAnimals)
            x:setBool(k .. "#mark", p.mark)
            -- Emit the dest only when a non-empty/non-whitespace string (absent -> draft, no attr).
            -- validate already blocks an invalid in-memory dest, so this guard's live job is the
            -- absent/draft case; it also keeps write defensive on its own.
            if type(p.destinationHusbandry) == "string" and p.destinationHusbandry:gsub("%s", "") ~= "" then
                x:setString(k .. "#destinationHusbandry", p.destinationHusbandry)
            end
        end,
        read = function(x, k)
            local maxAnimals = x:getInt(k .. "#maxAnimals")
            local mark = x:getBool(k .. "#mark")
            if maxAnimals == nil or mark == nil then return nil end
            -- dest: absent -> nil (legal inert draft); present-but-empty/whitespace -> nil return so
            -- the whole record is dropped (params-internal twin of readRule's #filterId skip - the
            -- top-level #filterId is floored in readRule, but dest lives inside params so the skip
            -- must originate here).
            local dest = x:getString(k .. "#destinationHusbandry")
            if dest ~= nil and dest:gsub("%s", "") == "" then return nil end
            return { maxAnimals = maxAnimals, mark = mark, destinationHusbandry = dest }
        end,
    },
    buy = {
        validate = function(p)
            return p.maxAnimals ~= nil and type(p.budget) == "table"
                and p.budget.type ~= nil and p.budget.fixed ~= nil and p.budget.percentage ~= nil
        end,
        write = function(x, k, p)
            x:setInt(k .. "#maxAnimals", p.maxAnimals)
            x:setString(k .. ".budget#type", p.budget.type)
            x:setInt(k .. ".budget#fixed", p.budget.fixed)
            x:setFloat(k .. ".budget#percentage", p.budget.percentage)
        end,
        read = function(x, k)
            local maxAnimals = x:getInt(k .. "#maxAnimals")
            local budgetType = x:getString(k .. ".budget#type")
            local fixed = x:getInt(k .. ".budget#fixed")
            local percentage = x:getFloat(k .. ".budget#percentage")
            if maxAnimals == nil or budgetType == nil or fixed == nil or percentage == nil then
                return nil
            end
            return {
                maxAnimals = maxAnimals,
                budget = { type = budgetType, fixed = fixed, percentage = percentage },
            }
        end,
    },
    castrate = {
        validate = function(p) return p.mark ~= nil end,
        write = function(x, k, p)
            x:setBool(k .. "#mark", p.mark)
        end,
        read = function(x, k)
            local mark = x:getBool(k .. "#mark")
            if mark == nil then return nil end
            return { mark = mark }
        end,
    },
    naming = {
        validate = function(p) return p.convention ~= nil end,
        write = function(x, k, p)
            x:setString(k .. "#convention", p.convention)
            -- Legacy parity: persist the cursor only
            -- for alphabetical naming and only when non-empty, so a random rule
            -- (or a fresh alphabetical one) reloads with previous=nil.
            if p.convention == "alphabetical" and type(p.previous) == "string" and p.previous ~= "" then
                x:setString(k .. "#previous", p.previous)
            end
        end,
        read = function(x, k)
            local convention = x:getString(k .. "#convention")
            if convention == nil then return nil end
            local params = { convention = convention }
            -- previous is OPTIONAL: absent -> nil (the alphabetical sequence
            -- restarts at "A" rather than skipping the record).
            local previous = x:getString(k .. "#previous")
            if previous ~= nil then params.previous = previous end
            return params
        end,
    },
    ai = {
        validate = function(p) return p.maxAnimals ~= nil and p.mark ~= nil and p.semen ~= nil end,
        write = function(x, k, p)
            x:setInt(k .. "#maxAnimals", p.maxAnimals)
            x:setBool(k .. "#mark", p.mark)
            x:setString(k .. "#semen", p.semen)
        end,
        read = function(x, k)
            local maxAnimals = x:getInt(k .. "#maxAnimals")
            local mark = x:getBool(k .. "#mark")
            local semen = x:getString(k .. "#semen")
            if maxAnimals == nil or mark == nil or semen == nil then return nil end
            return { maxAnimals = maxAnimals, mark = mark, semen = semen }
        end,
    },
    horseCare = {
        -- ZERO params: the operation is enabled or it is not. The entry is NOT optional even
        -- though it emits nothing - `writeRule` looks the codec up BEFORE writing any XML and
        -- returns false when there is none, so an absent entry would make every horseCare rule
        -- work for a whole session and then vanish on save, with no error a player could see.
        -- The three halves are symmetric: nothing required, nothing written, an EMPTY table read
        -- back. `read` must return `{}` and never nil - a nil read means "a required field is
        -- missing" and makes `readRule` drop the whole record.
        validate = function(_p) return true end,
        write = function(_x, _k, _p) end,
        read = function(_x, _k) return {} end,
    },
}

--- Exposed read-only for tests + future callers that want to assert the
--- canonical operation whitelist without reaching into RLHerdsmanRuleService.
RLHerdsmanRuleSerialization._PARAMS_CODECS = PARAMS_CODECS

-- =============================================================================
-- targetHusbandries (flat string list) IO
-- =============================================================================

--- Write the rule's target husbandry uniqueIds as `target(k)#uniqueId` siblings
--- under `ruleKey .. ".targetHusbandries"`. An empty list writes nothing (the
--- rule reloads with `targetHusbandries = {}` -> inert, no targets).
---@param xmlFile table XMLFile handle
---@param ruleKey string path prefix for this rule
---@param targets string[] uniqueId strings (dense array)
local function writeTargets(xmlFile, ruleKey, targets)
    if type(targets) ~= "table" then return end
    for k, uniqueId in ipairs(targets) do
        local targetKey = string.format("%s.targetHusbandries.target(%d)", ruleKey, k - 1)
        xmlFile:setString(targetKey .. "#uniqueId", uniqueId)
    end
end

--- Read the rule's target husbandry uniqueIds, preserving order. A `target(k)`
--- whose `#uniqueId` is nil/empty is skipped (:trace) rather than stored as an
--- empty string; uniqueId validity + placeable resolution stay M-Tick.
---@param xmlFile table XMLFile handle
---@param ruleKey string path prefix for this rule
---@return string[] targets non-empty uniqueId strings in document order
local function readTargets(xmlFile, ruleKey)
    local targets = {}
    xmlFile:iterate(ruleKey .. ".targetHusbandries.target", function(_, targetKey)
        local uniqueId = xmlFile:getString(targetKey .. "#uniqueId")
        if uniqueId == nil or uniqueId == "" then
            Log:trace("RLHerdsmanRuleSerialization.readTargets: %s has nil/empty #uniqueId; skipping entry", targetKey)
        else
            table.insert(targets, uniqueId)
        end
    end)
    return targets
end

-- =============================================================================
-- Rule record IO (public)
-- =============================================================================

--- Write one rule record at `ruleKey`. Returns `true` when the record was
--- written, `false` when it was skipped (nothing emitted). `@filterId` is
--- omitted when nil so the XML cleanly reflects a naming rule (no filter)
--- without a sentinel; every other scalar is always written. Dispatches the
--- operation's `params` codec for the `.params` subtree.
---
--- Fail-closed BEFORE emitting any XML (mirrors RLFilterSerialization's
--- "validate shape before writing" lesson in `writeCondition`):
--- an unknown `operation` (no codec) or structurally-incomplete `params` (the
--- service floor accepts any table-shaped params, so e.g. `buy` with `params={}`
--- can arrive) returns `false` with a `:warning` and writes nothing - so a
--- malformed record never leaves orphan scalars on disk and never crashes the
--- surrounding `RLSettings.saveToXMLFile` by dereferencing a nil sub-table. The
--- caller (`saveToXMLFile`) advances its on-disk `rule(i)` index only on `true`,
--- keeping the indexed sequence gap-free.
---@param xmlFile table XMLFile handle
---@param ruleKey string path prefix for this rule, e.g. `"...herdsmanRules.rule(0)"`
---@param rule table rule record (id/name/farmId/version/operation/enabled/filterId/targetHusbandries/params)
---@return boolean wrote
function RLHerdsmanRuleSerialization.writeRule(xmlFile, ruleKey, rule)
    -- Validate FIRST (no XML emitted yet) so a skip leaves no orphan node.
    local codec = PARAMS_CODECS[rule.operation]
    if codec == nil then
        Log:warning("RLHerdsmanRuleSerialization.writeRule: rule id=%s has unknown operation '%s'; skipping (no XML written)",
            tostring(rule.id), tostring(rule.operation))
        return false
    end
    if not codec.validate(rule.params or {}) then
        Log:warning("RLHerdsmanRuleSerialization.writeRule: rule id=%s (operation=%s) has incomplete params; skipping (no XML written)",
            tostring(rule.id), tostring(rule.operation))
        return false
    end

    xmlFile:setString(ruleKey .. "#id", rule.id or "")
    xmlFile:setString(ruleKey .. "#name", rule.name or "")
    xmlFile:setInt(ruleKey .. "#farmId", rule.farmId)
    xmlFile:setInt(ruleKey .. "#version", rule.version or 1)
    xmlFile:setString(ruleKey .. "#operation", rule.operation)
    xmlFile:setBool(ruleKey .. "#enabled", rule.enabled)

    -- Omit @filterId when nil (naming, or an unfiltered non-naming draft). A valid
    -- non-naming filterId round-trips verbatim; a present-but-empty/whitespace
    -- non-naming filterId (or a stray naming filterId) is fail-closed on READ (in
    -- readRule), not here - the write-side floor already blocks creating one, so
    -- writeRule never emits a bad filterId.
    if rule.filterId ~= nil then
        xmlFile:setString(ruleKey .. "#filterId", rule.filterId)
    end

    writeTargets(xmlFile, ruleKey, rule.targetHusbandries)
    codec.write(xmlFile, ruleKey .. ".params", rule.params)

    Log:trace("RLHerdsmanRuleSerialization.writeRule: %s id=%s name=%s operation=%s farmId=%s enabled=%s filterId=%s targets=%d",
        ruleKey, tostring(rule.id), tostring(rule.name), tostring(rule.operation),
        tostring(rule.farmId), tostring(rule.enabled), tostring(rule.filterId),
        type(rule.targetHusbandries) == "table" and #rule.targetHusbandries or 0)
    return true
end

--- Read one rule record from `ruleKey`. Returns the record on success, or nil +
--- `:warning` (the record is SKIPPED) when fail-closed: missing/empty `@id`, an
--- unknown `@operation` (no params codec), an absent `@farmId`, a `@filterId` that
--- violates the operation (present-but-empty/whitespace for non-naming, or present
--- at all for naming - the read-side twin of the service write floor; an absent
--- non-naming `@filterId` reads back as a legal nil draft), or any required
--- params field absent (read with no default; nil = corruption). `name`,
--- `enabled` and `version` carry defaults (`""` / `false` / `1`); `filterId` is
--- nil for a (valid) naming rule OR an unfiltered non-naming draft. The caller
--- stores the returned record (the service preserves id/farmId/version, never reassigns).
---@param xmlFile table XMLFile handle
---@param ruleKey string path prefix for this rule
---@return table|nil rule
function RLHerdsmanRuleSerialization.readRule(xmlFile, ruleKey)
    local id = xmlFile:getString(ruleKey .. "#id")
    if id == nil or id == "" then
        Log:warning("RLHerdsmanRuleSerialization.readRule: missing/empty #id at %s; skipping rule", tostring(ruleKey))
        return nil
    end

    local operation = xmlFile:getString(ruleKey .. "#operation")
    local codec = operation ~= nil and PARAMS_CODECS[operation] or nil
    if codec == nil then
        Log:warning("RLHerdsmanRuleSerialization.readRule: rule id=%s at %s has unknown/missing #operation '%s'; skipping (no params codec)",
            tostring(id), tostring(ruleKey), tostring(operation))
        return nil
    end

    -- farmId is fail-closed (no default): a rule without an owning farm is
    -- corrupt, not a global rule.
    local farmId = xmlFile:getInt(ruleKey .. "#farmId")
    if farmId == nil then
        Log:warning("RLHerdsmanRuleSerialization.readRule: rule id=%s at %s missing #farmId; skipping", tostring(id), tostring(ruleKey))
        return nil
    end

    local name = xmlFile:getString(ruleKey .. "#name", "")
    -- enabled is always written on a well-formed record; the default only
    -- applies to a truncated record (which is not fail-closed on enabled) and is
    -- conservatively false so a corrupt rule never silently runs an operation.
    local enabled = xmlFile:getBool(ruleKey .. "#enabled", false)
    local version = xmlFile:getInt(ruleKey .. "#version", 1)
    -- filterId: read raw, then floored against the operation just below.
    local filterId = xmlFile:getString(ruleKey .. "#filterId")

    -- Load-time floor: read-side twin of validateRuleFields' filterId-vs-operation
    -- rule. naming carries no filter; a non-naming rule binds at most one (D6) -
    -- an absent #filterId reads back nil (a legal incomplete draft), but a
    -- present-but-empty/whitespace non-naming filterId, or any filterId on a naming
    -- rule, is corruption -> skip (fail-closed, like the missing-id / unknown-op /
    -- missing-param guards above). writeRule already omits a nil #filterId.
    if operation == "naming" then
        if filterId ~= nil then
            Log:warning("RLHerdsmanRuleSerialization.readRule: naming rule id=%s at %s carries a #filterId (naming has no filter); skipping",
                tostring(id), tostring(ruleKey))
            return nil
        end
    elseif filterId ~= nil and filterId:gsub("%s", "") == "" then
        Log:warning("RLHerdsmanRuleSerialization.readRule: rule id=%s (operation=%s) at %s has a present-but-empty/whitespace #filterId; skipping (a non-naming filterId, when present, must be non-empty (non-whitespace))",
            tostring(id), tostring(operation), tostring(ruleKey))
        return nil
    end

    local targetHusbandries = readTargets(xmlFile, ruleKey)

    local params = codec.read(xmlFile, ruleKey .. ".params")
    if params == nil then
        Log:warning("RLHerdsmanRuleSerialization.readRule: rule id=%s (operation=%s) at %s missing a required params field; skipping",
            tostring(id), tostring(operation), tostring(ruleKey))
        return nil
    end

    Log:trace("RLHerdsmanRuleSerialization.readRule: %s id=%s name=%s operation=%s farmId=%s enabled=%s filterId=%s targets=%d version=%d",
        ruleKey, id, tostring(name), operation, tostring(farmId), tostring(enabled),
        tostring(filterId), #targetHusbandries, version)

    return {
        id = id,
        name = name,
        farmId = farmId,
        version = version,
        operation = operation,
        enabled = enabled,
        filterId = filterId,
        targetHusbandries = targetHusbandries,
        params = params,
    }
end

Log:trace("RLHerdsmanRuleSerialization: loaded")
