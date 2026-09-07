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
-- A param-free operation (horseCare) emits NO `.params` node at all. Its codec entry still has to
-- exist: `writeRule` resolves the codec before emitting any XML and skips the whole record when
-- there is none, so a missing entry silently drops the rule at save time.
--
-- Structural sibling of RLFilterSerialization minus the recursive group/AST - rule records are flat.
-- The rule keeps ONLY the operation params; the age/gender/disease/genetics selection block lives
-- in the rule's saved filter, so it is intentionally absent here.
--
-- Fail-closed contracts. readRule returns nil plus a warning - the record is SKIPPED, never the
-- surrounding load - when @id is missing/empty, @operation is not a known operation, @farmId is
-- absent, @filterId violates the operation (present-but-empty/whitespace for non-naming, or present
-- at all for naming; an absent non-naming @filterId is a legal nil draft), or any required params
-- field is absent. Required fields are read with NO default: a nil read signals corruption rather
-- than a silent default. A target whose @uniqueId is nil/empty is skipped on read, keeping order and
-- the non-empty strings; duplicate dedup and placeable resolution belong to the day-tick.

local Log = RmLogging.getLogger("RLRM")

RLHerdsmanRuleSerialization = {}

-- =============================================================================
-- Per-operation params codecs
-- =============================================================================

--- Per-operation params read/write functions, keyed by a rule's `operation`. The key set IS the
--- canonical operation whitelist `readRule` fails closed on, kept in lockstep with
--- `RLHerdsmanRuleService.OPERATIONS` without coupling the serializer to the service, which loads
--- later.
---
--- `validate(params)` returns true iff `params` carries every REQUIRED field for the operation - the
--- same set `read` rejects a nil on. The service's validity floor accepts ANY table-shaped params,
--- so a structurally-incomplete record can reach `writeRule`; validate lets it fail closed BEFORE
--- emitting XML instead of dereferencing a nil sub-table and crashing the whole save. It is not
--- value validation, which stays the picker's job.
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
        -- `maxAnimals` is required because the planner caps a move on it: one that round-tripped
        -- with no cap would silently no-op. `destinationHusbandry` mirrors the `filterId` floor -
        -- optional, but when present a non-empty (non-whitespace) string, enforced at BOTH ends so
        -- an invalid in-memory dest is never laundered to disk and a corrupt one on load drops the
        -- whole record.
        validate = function(p)
            return p.maxAnimals ~= nil and p.mark ~= nil
                and (p.destinationHusbandry == nil
                    or (type(p.destinationHusbandry) == "string" and p.destinationHusbandry:gsub("%s", "") ~= ""))
        end,
        write = function(x, k, p)
            x:setInt(k .. "#maxAnimals", p.maxAnimals)
            x:setBool(k .. "#mark", p.mark)
            -- validate already blocks an invalid in-memory dest, so this guard's live job is the
            -- absent/draft case.
            if type(p.destinationHusbandry) == "string" and p.destinationHusbandry:gsub("%s", "") ~= "" then
                x:setString(k .. "#destinationHusbandry", p.destinationHusbandry)
            end
        end,
        read = function(x, k)
            local maxAnimals = x:getInt(k .. "#maxAnimals")
            local mark = x:getBool(k .. "#mark")
            if maxAnimals == nil or mark == nil then return nil end
            -- The dest lives inside params, so its skip must originate here rather than in
            -- readRule's top-level #filterId floor.
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
            -- The cursor persists only for alphabetical naming and only when non-empty, so a random
            -- rule (or a fresh alphabetical one) reloads with previous=nil.
            if p.convention == "alphabetical" and type(p.previous) == "string" and p.previous ~= "" then
                x:setString(k .. "#previous", p.previous)
            end
        end,
        read = function(x, k)
            local convention = x:getString(k .. "#convention")
            if convention == nil then return nil end
            local params = { convention = convention }
            -- Optional: absent -> nil, and the alphabetical sequence restarts at "A" rather than the
            -- record being skipped.
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
        -- ZERO params, and the entry is NOT optional even though it emits nothing: `writeRule` looks
        -- the codec up before writing any XML and returns false when there is none, so an absent
        -- entry would make every horseCare rule work for a session and then vanish on save. `read`
        -- must return `{}` and never nil - nil means a required field is missing and drops the
        -- record.
        validate = function(_p) return true end,
        write = function(_x, _k, _p) end,
        read = function(_x, _k) return {} end,
    },
}

--- Exposed read-only for tests that assert the canonical operation whitelist.
RLHerdsmanRuleSerialization._PARAMS_CODECS = PARAMS_CODECS

-- =============================================================================
-- targetHusbandries (flat string list) IO
-- =============================================================================

--- Write the rule's target husbandry uniqueIds as `target(k)#uniqueId` siblings. An empty list
--- writes nothing, and the rule reloads inert with `targetHusbandries = {}`.
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

--- Read the rule's target husbandry uniqueIds, preserving order and skipping a nil/empty entry.
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

--- Write one rule record at `ruleKey`, dispatching the operation's params codec for the `.params`
--- subtree. Validation runs BEFORE any XML is emitted, so a skipped record leaves no orphan scalars
--- and cannot crash the surrounding save. The caller advances its on-disk `rule(i)` index only on
--- `true`, keeping the indexed sequence gap-free.
---@param xmlFile table XMLFile handle
---@param ruleKey string path prefix for this rule, e.g. `"...herdsmanRules.rule(0)"`
---@param rule table rule record (id/name/farmId/version/operation/enabled/filterId/targetHusbandries/params)
---@return boolean wrote
function RLHerdsmanRuleSerialization.writeRule(xmlFile, ruleKey, rule)
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

    -- Omitted when nil, so the XML reflects a naming rule or an unfiltered draft without a sentinel.
    -- A bad filterId is fail-closed on READ; the write-side floor already blocks creating one.
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

--- Read one rule record from `ruleKey`, or nil when the fail-closed contract above rejects it.
--- `name`, `enabled` and `version` carry defaults (`""` / `false` / `1`); `filterId` is nil for a
--- naming rule or an unfiltered draft. The caller stores the record as returned - the service
--- preserves id/farmId/version and never reassigns them.
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

    -- A rule without an owning farm is corrupt, not a global rule.
    local farmId = xmlFile:getInt(ruleKey .. "#farmId")
    if farmId == nil then
        Log:warning("RLHerdsmanRuleSerialization.readRule: rule id=%s at %s missing #farmId; skipping", tostring(id), tostring(ruleKey))
        return nil
    end

    local name = xmlFile:getString(ruleKey .. "#name", "")
    -- The default applies only to a truncated record, and is conservatively false so a corrupt rule
    -- never silently runs an operation.
    local enabled = xmlFile:getBool(ruleKey .. "#enabled", false)
    local version = xmlFile:getInt(ruleKey .. "#version", 1)
    local filterId = xmlFile:getString(ruleKey .. "#filterId")

    -- Load-time floor: the read-side twin of validateRuleFields' filterId-vs-operation rule.
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
