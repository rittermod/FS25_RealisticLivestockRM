-- RLFilterFieldDisplay.lua
-- UI-layer helper for the saveable-filter editor. Owns everything the
-- pure-data RLFilterFieldCatalog deliberately refuses to know about: i18n
-- key lookup, FillTypeManager resolution for subType labels, pixel-accurate
-- truncation for conditions-list rows. Loading this module pulls in no
-- additional runtime state; every helper is callable from a stub frame as
-- long as g_currentMission / g_i18n / g_fillTypeManager / getTextWidth are
-- mockable (the tests mock them).
--
-- Split from RLFilterFieldCatalog so the catalog stays mockable + runtime-free
-- and can be tested without a live mission.

local Log = RmLogging.getLogger("RLRM")

RLFilterFieldDisplay = {}

-- =============================================================================
-- Constants
-- =============================================================================

-- Fixed gender domain, as stable internal keys the UI translates at render time. ORDER
-- MATTERS: it drives the picker's option order, which maps to the index the dialog persists.
local GENDER_DOMAIN = { "male", "female" }

-- Middle-truncate sentinel between head and tail when a string value exceeds the
-- row's pixel budget. ASCII, and its pixel cost is measured like any other text.
local MIDDLE_TRUNCATE_SENTINEL = "..."

-- =============================================================================
-- Internal helpers
-- =============================================================================

--- Capitalise the first letter of `s`. Used as the l10n-miss fallback for
--- enum value display names so a missing translation produces "Male" /
--- "Female" / "<subtype-name>" rather than the raw internal key.
---@param s string
---@return string
local function capitalise(s)
    if type(s) ~= "string" or #s == 0 then return s or "" end
    return s:sub(1, 1):upper() .. s:sub(2)
end

--- The AnimalType struct for a typeIndex, or nil when the mission is not loaded or the
--- index is unknown. getTypes() returns a SPARSE map keyed by index, so this looks up
--- directly rather than iterating.
---@param animalTypeIndex number|nil
---@return table|nil animalType
local function resolveAnimalType(animalTypeIndex)
    if animalTypeIndex == nil then return nil end
    if g_currentMission == nil then return nil end
    local animalSystem = g_currentMission.animalSystem
    if animalSystem == nil then return nil end
    local types = animalSystem.types
    if types == nil then return nil end
    for _, at in pairs(types) do
        if at ~= nil and at.typeIndex == animalTypeIndex then
            return at
        end
    end
    return nil
end

-- =============================================================================
-- Enum domain resolution
-- =============================================================================

--- The ordered internal-key values for an enum field: gender fixed, subType per animal type
--- in XML-load order. An unresolvable domain returns EMPTY, which callers read as "omit this
--- field from the picker, and refuse an edit on an existing row of it".
---@param fieldKey string "gender" or "subType"
---@param animalTypeIndex number|nil filter's animalType scope (nil = ANY)
---@return string[] ordered internal keys (empty if unresolvable)
function RLFilterFieldDisplay.getEnumDomain(fieldKey, animalTypeIndex)
    if fieldKey == "gender" then
        -- Shallow-copy so callers can mutate the result without polluting
        -- the module-level constant.
        return { GENDER_DOMAIN[1], GENDER_DOMAIN[2] }
    end

    if fieldKey == "subType" then
        local animalType = resolveAnimalType(animalTypeIndex)
        if animalType == nil then
            Log:trace("RLFilterFieldDisplay.getEnumDomain: subType unresolvable for animalTypeIndex=%s (animalSystem not ready or unknown index)",
                tostring(animalTypeIndex))
            return {}
        end
        local subTypeIndices = animalType.subTypes
        if subTypeIndices == nil or #subTypeIndices == 0 then
            Log:trace("RLFilterFieldDisplay.getEnumDomain: subType domain empty for animalTypeIndex=%s",
                tostring(animalTypeIndex))
            return {}
        end
        local animalSystem = g_currentMission.animalSystem
        local out = {}
        for _, subTypeIdx in ipairs(subTypeIndices) do
            local subType = animalSystem:getSubTypeByIndex(subTypeIdx)
            if subType ~= nil and subType.name ~= nil then
                table.insert(out, subType.name)
            end
        end
        Log:trace("RLFilterFieldDisplay.getEnumDomain: subType animalTypeIndex=%s -> %d value(s)",
            tostring(animalTypeIndex), #out)
        return out
    end

    Log:trace("RLFilterFieldDisplay.getEnumDomain: unknown enum fieldKey=%s; returning empty",
        tostring(fieldKey))
    return {}
end

--- Cross-species union of subTypes, for a filter with no animal-type scope. Subtype names are
--- GLOBALLY UNIQUE, so the returned keys are safe as map keys. subType-only.
---@param fieldKey string "subType" (any other key returns empty + logs)
---@return string[] ordered internal keys (empty if unresolvable)
function RLFilterFieldDisplay.getEnumDomainForUnscopedFilter(fieldKey)
    if fieldKey ~= "subType" then
        Log:trace("RLFilterFieldDisplay.getEnumDomainForUnscopedFilter: only subType supported, got %s",
            tostring(fieldKey))
        return {}
    end
    if g_currentMission == nil or g_currentMission.animalSystem == nil then
        Log:trace("RLFilterFieldDisplay.getEnumDomainForUnscopedFilter: animalSystem unavailable")
        return {}
    end
    local subTypes = g_currentMission.animalSystem.subTypes
    if subTypes == nil or #subTypes == 0 then
        Log:trace("RLFilterFieldDisplay.getEnumDomainForUnscopedFilter: global subTypes empty")
        return {}
    end
    local out = {}
    for _, subType in ipairs(subTypes) do
        if subType ~= nil and subType.name ~= nil then
            table.insert(out, subType.name)
        end
    end
    Log:trace("RLFilterFieldDisplay.getEnumDomainForUnscopedFilter: %d cross-species subType(s)",
        #out)
    return out
end

-- =============================================================================
-- Enum value display name resolution
-- =============================================================================

--- The translated display name for an enum value, falling back to the capitalised internal key
--- so a missing translation never renders blank. A subType's label is its fill type's title.
---@param fieldKey string "gender" or "subType"
---@param value string internal key (e.g. "male", "<subtype-name>")
---@param animalTypeIndex number|nil filter's animalType scope (used to
---       resolve subType label even when the animal entity scope mismatches)
---@return string display name (capitalised internal key on l10n miss)
function RLFilterFieldDisplay.getEnumValueDisplayName(fieldKey, value, animalTypeIndex)
    if value == nil then return "" end

    if fieldKey == "gender" then
        local lookup = "rl_menu_filters_gender_" .. tostring(value)
        if g_i18n ~= nil and g_i18n.hasText ~= nil and g_i18n:hasText(lookup) then
            return g_i18n:getText(lookup)
        end
        Log:trace("RLFilterFieldDisplay.getEnumValueDisplayName: gender l10n miss key=%s; using capitalise fallback",
            lookup)
        return capitalise(tostring(value))
    end

    if fieldKey == "subType" then
        -- Walk the scoped type's subTypes for a name match, or every type when unscoped -
        -- the row formatter must render labels even at ANY scope.
        local fillTypeIndex
        if g_currentMission ~= nil and g_currentMission.animalSystem ~= nil then
            local animalSystem = g_currentMission.animalSystem
            local function scanType(at)
                if at == nil or at.subTypes == nil then return nil end
                for _, subTypeIdx in ipairs(at.subTypes) do
                    local subType = animalSystem:getSubTypeByIndex(subTypeIdx)
                    if subType ~= nil and subType.name == value then
                        return subType.fillTypeIndex
                    end
                end
                return nil
            end
            if animalTypeIndex ~= nil then
                fillTypeIndex = scanType(resolveAnimalType(animalTypeIndex))
            else
                for _, at in pairs(animalSystem.types or {}) do
                    fillTypeIndex = scanType(at)
                    if fillTypeIndex ~= nil then break end
                end
            end
        end

        if fillTypeIndex ~= nil and g_fillTypeManager ~= nil
           and g_fillTypeManager.getFillTypeByIndex ~= nil then
            local fillType = g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
            if fillType ~= nil and fillType.title ~= nil and fillType.title ~= "" then
                return fillType.title
            end
        end

        Log:trace("RLFilterFieldDisplay.getEnumValueDisplayName: subType title miss value=%s; using capitalise fallback",
            tostring(value))
        return capitalise(tostring(value))
    end

    Log:trace("RLFilterFieldDisplay.getEnumValueDisplayName: unknown enum fieldKey=%s value=%s",
        tostring(fieldKey), tostring(value))
    return tostring(value)
end

-- =============================================================================
-- Field label resolution (used by formatConditionDisplay)
-- =============================================================================

--- Resolve a localised label for a catalog field key. Mirrors the matching
--- helper inside RLMenuSettingsFrame so both call sites agree on
--- key namespace and fallback shape.
---@param key string
---@return string
local function resolveFieldLabel(key)
    if key == nil then return "" end
    local safe = key:gsub("%.", "_")
    local lookup = "rl_menu_filters_field_" .. safe
    if g_i18n ~= nil and g_i18n.hasText ~= nil and g_i18n:hasText(lookup) then
        return g_i18n:getText(lookup)
    end
    return key
end

-- =============================================================================
-- Comparator display-name resolution
-- =============================================================================

-- Raw comparator symbol -> i18n key suffix, the label living at
-- "rl_menu_filters_cmp_<suffix>", because an XML l10n key cannot contain < > = ! .
-- DISPLAY-ONLY: the stored, serialized, wire and evaluated cmp stays the raw symbol.
local CMP_KEY_SUFFIX = {
    ["<"]           = "lt",
    ["<="]          = "le",
    ["=="]          = "eq",
    ["!="]          = "ne",
    [">="]          = "ge",
    [">"]           = "gt",
    ["in"]          = "in",
    ["notin"]       = "notin",
    ["contains"]    = "contains",
    ["notcontains"] = "notcontains",
}

--- A plain-English label for a comparator symbol. A nil OR EMPTY lookup counts as a miss
--- and falls back to the raw symbol, so a label is never blank. DISPLAY-ONLY: callers keep
--- the raw symbol for storage, the wire and evaluation.
---@param cmp string|nil raw comparator symbol
---@return string display label (raw symbol on l10n miss, "?" for nil)
function RLFilterFieldDisplay.getCmpDisplayName(cmp)
    if cmp == nil then return "?" end
    local suffix = CMP_KEY_SUFFIX[cmp]
    if suffix ~= nil and g_i18n ~= nil and g_i18n.hasText ~= nil then
        local lookup = "rl_menu_filters_cmp_" .. suffix
        if g_i18n:hasText(lookup) then
            local label = g_i18n:getText(lookup)
            if label ~= nil and label ~= "" then
                return label
            end
        end
    end
    Log:trace("RLFilterFieldDisplay.getCmpDisplayName: no label resolved for cmp=%s (unmapped symbol or absent/empty key); using raw-symbol fallback",
        tostring(cmp))
    return tostring(cmp)
end

-- =============================================================================
-- Condition row display formatting
-- =============================================================================

--- Format a condition row as a localised "FieldLabel cmp value" string; the caller truncates
--- it. A number renders CANONICALLY, never the in-flight text buffer, and a string renders
--- verbatim - case-folding lives in the evaluator, so the row shows what the user typed.
---@param condition table {field, cmp, value}
---@param fieldEntry table catalog entry resolved from condition.field
---@param animalTypeIndex number|nil filter's scope (for subType labels)
---@return string display
function RLFilterFieldDisplay.formatConditionDisplay(condition, fieldEntry, animalTypeIndex)
    if condition == nil or fieldEntry == nil then return "(invalid)" end
    local fieldLabel = resolveFieldLabel(condition.field)
    local cmpDisplay = RLFilterFieldDisplay.getCmpDisplayName(condition.cmp)
    local valueDisplay
    -- List-shaped values (in/notin) render as "[Lab1, Lab2, ...]", each element through
    -- the enum label resolver. Only enum fields are list-shaped today; a number list
    -- would fall through to tostring per element.
    if type(condition.value) == "table" and (condition.cmp == "in" or condition.cmp == "notin") then
        local parts = {}
        if fieldEntry.type == "enum" then
            for _, key in ipairs(condition.value) do
                table.insert(parts, RLFilterFieldDisplay.getEnumValueDisplayName(
                    fieldEntry.key, key, animalTypeIndex))
            end
        else
            for _, v in ipairs(condition.value) do
                table.insert(parts, tostring(v))
            end
        end
        valueDisplay = "[" .. table.concat(parts, ", ") .. "]"
        Log:trace("RLFilterFieldDisplay.formatConditionDisplay: list field=%s cmp=%s n=%d",
            tostring(condition.field), tostring(condition.cmp), #parts)
    elseif fieldEntry.type == "bool" then
        valueDisplay = (condition.value == true)
            and (g_i18n and g_i18n:getText("ui_yes") or "Yes")
            or  (g_i18n and g_i18n:getText("ui_no")  or "No")
    elseif fieldEntry.type == "number" then
        valueDisplay = tostring(condition.value or 0)
    elseif fieldEntry.type == "enum" then
        valueDisplay = RLFilterFieldDisplay.getEnumValueDisplayName(
            fieldEntry.key, condition.value, animalTypeIndex)
    elseif fieldEntry.type == "string" then
        valueDisplay = tostring(condition.value or "")
    else
        valueDisplay = tostring(condition.value or "")
    end
    -- Bool rows drop the operator ONLY for "==", bool's sole valid comparator, so the row
    -- reads "Pregnant No". Gating on the cmp rather than the type keeps a malformed bool
    -- visible in the three-part form instead of silently reading as its opposite.
    if fieldEntry.type == "bool" and condition.cmp == "==" then
        Log:trace("RLFilterFieldDisplay.formatConditionDisplay: bool operator-drop field=%s value=%s",
            tostring(condition.field), tostring(valueDisplay))
        return string.format("%s %s", fieldLabel, valueDisplay)
    end
    return string.format("%s %s %s", fieldLabel, cmpDisplay, valueDisplay)
end

-- =============================================================================
-- Row truncation (pixel-accurate, locale-correct)
-- =============================================================================

--- Middle-truncate under a pixel budget, keeping BOTH head and tail so two long values
--- differing only at the suffix stay distinguishable. Falls back to a suffix truncate when
--- the sentinel itself will not fit.
---@param text string
---@param textSize number
---@param widthPx number
---@return string truncated text
local function middleTruncate(text, textSize, widthPx)
    if text == nil then return "" end
    if widthPx <= 0 then return text end
    local totalWidth = getTextWidth(textSize, text)
    if totalWidth <= widthPx then return text end

    local sentinelWidth = getTextWidth(textSize, MIDDLE_TRUNCATE_SENTINEL)
    if sentinelWidth >= widthPx then
        -- No room for the sentinel; fall back to suffix-truncate.
        return Utils.limitTextToWidth(text, textSize, widthPx, false, MIDDLE_TRUNCATE_SENTINEL)
    end

    -- Each half gets half of (widthPx - sentinelWidth). The helper itself
    -- subtracts its own sentinel width, so we pass the half budget and an
    -- empty trim sentinel; we add MIDDLE_TRUNCATE_SENTINEL ourselves when
    -- joining.
    local halfBudget = (widthPx - sentinelWidth) / 2
    local head = Utils.limitTextToWidth(text, textSize, halfBudget, false, "")
    local tail = Utils.limitTextToWidth(text, textSize, halfBudget, true,  "")
    Log:trace("RLFilterFieldDisplay.middleTruncate: budget=%.1fpx head='%s' tail='%s'",
        widthPx, tostring(head), tostring(tail))
    return head .. MIDDLE_TRUNCATE_SENTINEL .. tail
end

--- Limit a row's text to its pixel width: strings middle-truncate to stay
--- distinguishable, every other type suffix-truncates.
---@param text string the full "field cmp value" row text
---@param textSize number font size in normalised units (caller resolves
---       via element.textSize)
---@param widthPx number row content width budget in pixels
---@param valueType string|nil "number"|"bool"|"enum"|"string" - drives the
---       truncate strategy. nil = suffix-truncate (safe default).
---@return string truncated text
function RLFilterFieldDisplay.limitConditionRowText(text, textSize, widthPx, valueType)
    if text == nil then return "" end
    if widthPx == nil or widthPx <= 0 then return text end
    if valueType == "string" then
        return middleTruncate(text, textSize, widthPx)
    end
    return Utils.limitTextToWidth(text, textSize, widthPx, false, MIDDLE_TRUNCATE_SENTINEL)
end

Log:debug("RLFilterFieldDisplay: loaded")
