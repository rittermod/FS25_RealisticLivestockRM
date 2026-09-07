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

-- Fixed gender domain. Two stable internal keys; UI translates at render
-- time via getEnumValueDisplayName. Order matters - it drives the
-- MultiTextOption picker's option ordering, which then maps to the index
-- the dialog persists. Male first matches the catalog's natural-language
-- "male"/"female" ordering at Animal entity definition.
local GENDER_DOMAIN = { "male", "female" }

-- Middle-truncate sentinel inserted between head + tail when a string value
-- exceeds the row's pixel budget. ASCII so the no-typographic-unicode hook
-- doesn't trip on a typographic ellipsis (U+2026). Pixel cost is measured
-- via getTextWidth like every other character.
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

--- Look up the AnimalType struct for a given typeIndex via the live mission.
--- Returns nil when the mission / animalSystem isn't loaded yet or the
--- index is unknown. The lookup matches RLMenuSettingsFrame.seedAnimalTypeStates:
--- `g_currentMission.animalSystem:getTypes()` returns a
--- sparse map keyed by typeIndex, so we look up directly by index rather
--- than ipairs-iterating.
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

--- Return the ordered list of stable internal-key values for an enum field.
--- gender: fixed `{ "male", "female" }`. subType: per-animal-type, drawn from
--- `g_currentMission.animalSystem.types[idx].subTypes` (a numeric array of
--- subTypeIndex values) and mapped via `animalSystem:getSubTypeByIndex(idx)`
--- to extract `subType.name`. Order follows XML-load-order and is
--- deterministic within a session.
---
--- Returns an empty table when the domain is unresolvable: animalTypeIndex is nil, the live
--- mission is not loaded, or the scoped type has zero subtypes. Callers treat empty as "the
--- field picker omits this field" and "an edit attempt on a legacy row of it is refused".
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

--- Cross-species union of subTypes for unscoped filters
--- (filter.animalType == nil). Returns the flat global subType-name array
--- straight off `g_currentMission.animalSystem.subTypes`. Subtype names are
--- globally unique (the AnimalSystem XML loader rejects duplicates), so the
--- returned keys are safe to use as map keys without collision.
---
--- Order matches XML-load-order across all animal types and is deterministic
--- within a session. Returns an empty table when the mission / animalSystem
--- isn't loaded or the global array is empty (loadOrder gap).
---
--- gender is not relevant for the unscoped path - the fixed-domain caller
--- still uses getEnumDomain("gender", nil). This helper is subType-only.
---
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

--- Return the translated display name for an enum value. Falls back to the
--- capitalised internal key when the l10n lookup fails so a missing
--- translation never renders as a blank cell or a raw lowercase identifier.
---
--- gender: `g_i18n:getText("rl_menu_filters_gender_" .. key)`, fallback to
--- `capitalise(key)` -> "Male" / "Female".
---
--- subType: `g_fillTypeManager:getFillTypeByIndex(subType.fillTypeIndex).title`
--- (the .title is already i18n-resolved by FillTypeManager during load, so
--- no extra g_i18n:getText call is needed). Fallback chain: fillType.title
--- missing or empty -> capitalised subType.name. Subtype lookup goes through
--- the public AnimalSystem `getSubTypeByIndex` API; the fillTypeIndex is set
--- by the subType-load machinery.
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
        -- Walk the scoped animalType's subTypes to find the one whose name
        -- matches `value`, then read its fillTypeIndex to look up the title.
        -- Unscoped (animalTypeIndex=nil): walk every animalType. This keeps
        -- the helper useful for the conditions-list row formatter, which
        -- has to render labels even when the filter scope is ANY (the row
        -- legitimately exists from a hand-edited XML or a peer client).
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

-- Raw comparator symbol -> i18n key suffix. XML l10n key names cannot contain
-- < > = ! characters, so each symbol maps to an ASCII suffix and the localized
-- label lives at "rl_menu_filters_cmp_<suffix>". This map is display-only: the
-- stored / serialized / wire / evaluated cmp stays the raw symbol.
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

--- Resolve a plain-English display label for a raw comparator symbol. Guards
--- g_i18n exactly like resolveFieldLabel; a nil-OR-empty getText result counts
--- as a miss and falls back to the raw symbol so a label is never blank. An
--- unknown symbol passes through via tostring; a nil cmp preserves the "?"
--- sentinel the row formatter used before this resolver existed. Display-only:
--- callers keep the raw symbol for storage / serialization / wire / evaluation.
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

--- Format a condition row for the read-only Text widget in the v2 conditions
--- list. Returns a localised "FieldLabel cmp value" string. The caller
--- (RLMenuSettingsFrame populateCell) passes the raw result through
--- limitConditionRowText before calling setText.
---
--- Value rendering by type:
---   bool   -> ui_yes / ui_no (standard i18n keys; matches the legacy formatter).
---   number -> tostring(value) - rawText is intentionally NOT used here;
---             persistence and display always show the canonical numeric
---             form, not the in-flight TextInput buffer.
---   enum   -> getEnumValueDisplayName(field.key, value, animalTypeIndex)
---             (translated label, capitalised-key fallback on l10n miss).
---   string -> value verbatim (case-fold lives in the evaluator at match
---             time; row display preserves what the user typed).
---@param condition table {field, cmp, value}
---@param fieldEntry table catalog entry resolved from condition.field
---@param animalTypeIndex number|nil filter's scope (for subType labels)
---@return string display
function RLFilterFieldDisplay.formatConditionDisplay(condition, fieldEntry, animalTypeIndex)
    if condition == nil or fieldEntry == nil then return "(invalid)" end
    local fieldLabel = resolveFieldLabel(condition.field)
    local cmpDisplay = RLFilterFieldDisplay.getCmpDisplayName(condition.cmp)
    local valueDisplay
    -- List-shaped values (cmp = in/notin) render as "[Lab1, Lab2, ...]"
    -- with each element passed through the enum label resolver. Only enum
    -- fields use list-shape today (in/notin gated to enum); number lists
    -- would render via tostring per element if/when a future cmp adds them.
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
    -- Bool rows drop the operator segment when (and only when) cmp == "==" -
    -- bool's sole valid comparator - so the row reads "Pregnant No" instead of
    -- "Pregnant is No". Gating on cmp (not just type == "bool") keeps a
    -- malformed non-"==" bool visible as the 3-part form ("Pregnant is not No")
    -- rather than silently reading as its opposite.
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

--- Middle-truncate a string under a pixel budget. Preserves both head and
--- tail so two long values that differ only at the suffix render
--- distinguishably ("VeryLong...ABC" vs "VeryLong...XYZ"). When the input
--- already fits, returns it unchanged.
---
--- Implementation:
---   1. Use the basegame helper twice - once with trimFront=false (keeps
---      head, drops tail), once with trimFront=true (keeps tail, drops
---      head) - then join with the sentinel between. Each half gets half
---      the available budget (minus the sentinel cost).
---   2. If the sentinel itself doesn't fit, fall back to a plain suffix-
---      truncate so the row at least shows something.
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

--- Limit a conditions-list row text under the row's pixel width. Strings
--- use middle-truncate to preserve both head + tail (distinguishability for
--- long needles); every other value type uses suffix-truncate via the public
--- Utils.limitTextToWidth helper.
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
