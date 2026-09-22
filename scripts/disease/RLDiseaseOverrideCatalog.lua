-- RLDiseaseOverrideCatalog.lua
-- Per-open view of every defined disease with its display name, affected-types label and current
-- enabled state - the read model the disease selector dialog consumes. Never mutates the
-- registry or the definitions.
--
-- Split like the dealer catalog: a PURE core `build(diseases, overrides, deps)` over plain tables
-- plus injected `deps`, and a thin shell `enumerate()` that binds the live globals.

local Log = RmLogging.getLogger("RLRM")

RLDiseaseOverrideCatalog = {}

-- =============================================================================
-- Pure core (data in / data out) - the dual-run unit
-- =============================================================================

--- Join the resolved labels of `animals` with ", " in authored order, omitting unlabelled names.
---@param animals table|nil array of uppercase type names
---@param typeLabel function fn(typeName) -> string|nil
---@return string label possibly empty
local function typesLabelOf(animals, typeLabel)
    local labels = {}
    if type(animals) ~= "table" then
        Log:trace("RLDiseaseOverrideCatalog.build: animals is not a table (%s); empty types label", type(animals))
        return ""
    end

    for _, typeName in ipairs(animals) do
        local label = typeLabel(typeName)
        if type(label) == "string" and label ~= "" then
            labels[#labels + 1] = label
        else
            Log:trace("RLDiseaseOverrideCatalog.build: type %s has no label; omitted", tostring(typeName))
        end
    end

    return table.concat(labels, ", ")
end

--- Build one row per title in the definition map, sorted by display name then title.
---@param diseases table|nil title-keyed definition map (`g_diseaseManager.diseases`)
---@param overrides table|nil an RLDiseaseOverrideRegistry instance
---@param deps table|nil `{ typeLabel = fn(typeName) -> string|nil }`
---@return table[] rows `{ title, name, typesLabel, archetype, enabled }`
function RLDiseaseOverrideCatalog.build(diseases, overrides, deps)
    if type(diseases) ~= "table" then
        Log:warning("RLDiseaseOverrideCatalog.build: diseases is not a table (%s); returning empty", type(diseases))
        return {}
    end
    if type(overrides) ~= "table" or type(overrides.isEnabled) ~= "function" then
        Log:warning("RLDiseaseOverrideCatalog.build: overrides has no isEnabled; returning empty")
        return {}
    end
    if type(deps) ~= "table" or type(deps.typeLabel) ~= "function" then
        Log:warning("RLDiseaseOverrideCatalog.build: deps missing typeLabel; returning empty")
        return {}
    end

    local rows = {}
    for title, model in pairs(diseases) do
        if type(title) == "string" and type(model) == "table" then
            local name = model.name
            if type(name) ~= "string" or name == "" then name = title end

            rows[#rows + 1] = {
                title      = title,
                name       = name,
                typesLabel = typesLabelOf(model.animals, deps.typeLabel),
                archetype  = model.archetype,
                enabled    = overrides:isEnabled(title),
            }
        else
            Log:trace("RLDiseaseOverrideCatalog.build: skipped a malformed entry (title=%s)", tostring(title))
        end
    end

    table.sort(rows, function(a, b)
        if a.name ~= b.name then return a.name < b.name end
        return a.title < b.title
    end)

    local disabled = 0
    for _, row in ipairs(rows) do
        if not row.enabled then disabled = disabled + 1 end
    end

    Log:debug("RLDiseaseOverrideCatalog.build: %d row(s), %d disabled", #rows, disabled)
    return rows
end

-- =============================================================================
-- In-game shell (binds the live registries + the type-label lookup)
-- =============================================================================

--- Build the catalog from the live disease registry and override registry.
---@return table[] rows (empty on any unavailable dependency or build error)
function RLDiseaseOverrideCatalog.enumerate()
    if g_diseaseManager == nil or type(g_diseaseManager.diseases) ~= "table" then
        Log:warning("RLDiseaseOverrideCatalog.enumerate: disease registry unavailable; returning empty")
        return {}
    end
    if g_rlDiseaseOverrideRegistry == nil then
        Log:warning("RLDiseaseOverrideCatalog.enumerate: override registry unavailable; returning empty")
        return {}
    end
    if g_currentMission == nil or g_currentMission.animalSystem == nil then
        Log:warning("RLDiseaseOverrideCatalog.enumerate: animalSystem unavailable; returning empty")
        return {}
    end

    local animalSystem = g_currentMission.animalSystem
    local deps = {
        typeLabel = function(typeName)
            local animalType = animalSystem:getTypeByName(typeName)
            if animalType == nil then return nil end
            return RLAnimalUtil.getAnimalTypeDisplayName(animalType)
        end,
    }

    local ok, result = pcall(RLDiseaseOverrideCatalog.build, g_diseaseManager.diseases,
        g_rlDiseaseOverrideRegistry, deps)
    if not ok then
        Log:error("RLDiseaseOverrideCatalog.enumerate: build failed; returning empty: %s", tostring(result))
        return {}
    end

    Log:debug("RLDiseaseOverrideCatalog.enumerate: built %d row(s) from the live registries", #result)
    return result
end

Log:debug("RLDiseaseOverrideCatalog: loaded")
