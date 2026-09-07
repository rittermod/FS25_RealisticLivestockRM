-- RLDealerSaleCatalog.lua
-- Live, per-open view of every loaded animal type / subType / age-stage with its current dealer
-- buyability, icon and labels - the read model the sale-availability selector dialog consumes.
-- Reads only the EFFECTIVE `store.canBeBought` that the apply layer already folded onto the live
-- flags, and never mutates the registry, the store or the subtype set.
--
-- Split like the apply layer: a PURE core `build(types, deps)` that composes the view-model from
-- plain tables plus injected `deps` - no `g_*`, GUI, XML or engine natives - and a thin in-game
-- shell `enumerate()` that reads the live `animalSystem` and binds the real label seams.
--
-- Each stage entry is keyed by (subTypeName, minAge), the SAME separate-arg key the override
-- registry takes, so a consumer toggles the registry directly off an entry with no decoding.
--
-- Age ranges MIRROR the real sale generator `_pickSaleAnimalAge`, so the displayed band equals
-- what the dealer actually sells: a store-bearing stage spans `[minAge, nextRawVisual.minAge - 1]`
-- and the LAST raw visual extends to `animalType.maxBuyAge`, or 60 when a bridge type ships no
-- max. A store-less visual is a BOUNDARY, not a stage - it bounds the preceding stage but emits
-- nothing. A stage whose upper bound falls below its `minAge` is DROPPED rather than clamped,
-- exactly as the generator's `hi >= lo` guard drops an empty band; that drop also collapses a
-- duplicate `minAge`, so each surviving key stays unique.

local Log = RmLogging.getLogger("RLRM")

RLDealerSaleCatalog = {}

-- =============================================================================
-- Pure core (data in / data out) - the dual-run unit
-- =============================================================================

--- True when `deps` carries the three lookups the core needs, all callable.
---@param deps any
---@return boolean
local function hasDeps(deps)
    return type(deps) == "table"
        and type(deps.getSubTypeByIndex) == "function"
        and type(deps.typeLabel) == "function"
        and type(deps.subTypeLabel) == "function"
end

--- Collect the sparse `getTypes()` map into a dense array, then sort by `typeIndex` with a
--- `name` tie-break so ordering never flakes on a fixture or mod tie. `pairs()`, never `ipairs`:
--- the map is keyed by `typeIndex`, and a hole would truncate an `ipairs` walk, silently
--- dropping map-bridge and exotic types.
---@param types table getTypes() result (sparse map)
---@param counters table { typesSkipped= }
---@return table[] sorted dense array of animalType tables
local function sortedTypes(types, counters)
    local collected = {}
    for _, animalType in pairs(types) do
        if animalType ~= nil and animalType.typeIndex ~= nil then
            collected[#collected + 1] = animalType
        else
            counters.typesSkipped = counters.typesSkipped + 1
            Log:trace("RLDealerSaleCatalog.build: dropped a type with nil entry or nil typeIndex")
        end
    end
    table.sort(collected, function(a, b)
        if a.typeIndex ~= b.typeIndex then
            return a.typeIndex < b.typeIndex
        end
        return (a.name or "") < (b.name or "")
    end)
    return collected
end

--- Gate-equivalent buyable boolean, mirroring the apply layer: an absent or falsy
--- `canBeBought` reads `false`, so the field is always a boolean.
---@param store table visual.store
---@return boolean
local function buyableOf(store)
    return store.canBeBought and true or false
end

--- Icon path, normalized so an empty string collapses to nil - the dialog treats both "no icon"
--- cases the same and must not try to load "".
---@param store table visual.store
---@return string|nil
local function iconOf(store)
    local f = store.imageFilename
    return (f ~= nil and f ~= "") and f or nil
end

--- Build the per-stage view-model for one subtype, per the age-range rule in the file header. A
--- visual with a non-numeric `minAge` can be neither stage nor boundary and is dropped.
---@param subType table { name=, visuals= }
---@param maxBuyAge number last-stage upper bound (already numeric-guarded)
---@param counters table { visualsSkipped=, stagesDropped= }
---@return table[] stage view-models (possibly empty)
local function buildStages(subType, maxBuyAge, counters)
    -- The boundary array is every numeric-minAge visual, store-bearing or not, ascending - the
    -- same raw array the generator walks.
    local ordered = {}
    for _, visual in ipairs(subType.visuals) do
        if type(visual.minAge) == "number" then
            ordered[#ordered + 1] = visual
        else
            counters.visualsSkipped = counters.visualsSkipped + 1
            Log:trace("RLDealerSaleCatalog.build: %s dropped a visual with non-numeric minAge (%s)",
                tostring(subType.name), tostring(visual.minAge))
        end
    end
    table.sort(ordered, function(a, b) return a.minAge < b.minAge end)

    local stages = {}
    local n = #ordered
    for i = 1, n do
        local visual = ordered[i]
        if visual.store ~= nil then
            local lo = visual.minAge
            local hi
            if i < n then
                hi = ordered[i + 1].minAge - 1
            else
                hi = maxBuyAge
            end
            if hi >= lo then
                stages[#stages + 1] = {
                    minAge        = lo,
                    maxAge        = hi,
                    ageRangeLabel = string.format("%d-%d", lo, hi),
                    iconFilename  = iconOf(visual.store),
                    buyable       = buyableOf(visual.store),
                }
            else
                counters.stagesDropped = counters.stagesDropped + 1
                Log:trace("RLDealerSaleCatalog.build: %s dropped empty stage @%d (hi=%d < lo; mirrors generator hi>=lo)",
                    tostring(subType.name), lo, hi)
            end
        end
    end
    return stages
end

--- Build the catalog view-model from a `getTypes()` map and an injected `deps` bundle. Pure:
--- every live lookup arrives through `deps`, so the core reaches no global, and it never mutates
--- `types`, any subtype or any store flag.
---
--- Each type's `subTypes` is a DENSE array of subtype INDICES resolved via
--- `deps.getSubTypeByIndex`, so `ipairs` is correct there - the sparse-map ban applies to
--- `getTypes()` only. A subtype with no resolvable entry, no name, or no store-bearing stage
--- contributes no entry.
---@param types table|nil getTypes() result (sparse map keyed by typeIndex)
---@param deps table { getSubTypeByIndex=fn(idx)->subType|nil, typeLabel=fn(animalType)->string, subTypeLabel=fn(name,typeIndex)->string }
---@return table[] catalog array of { typeIndex, typeLabel, subTypeIndex, subTypeName, subTypeLabel, visuals={...} }
function RLDealerSaleCatalog.build(types, deps)
    if type(types) ~= "table" then
        Log:warning("RLDealerSaleCatalog.build: types is not a table (%s); returning empty", type(types))
        return {}
    end
    if not hasDeps(deps) then
        Log:warning("RLDealerSaleCatalog.build: deps missing a required lookup (getSubTypeByIndex/typeLabel/subTypeLabel); returning empty")
        return {}
    end

    local counters = { typesSkipped = 0, subTypesSkipped = 0, visualsSkipped = 0, stagesDropped = 0 }
    local orderedTypes = sortedTypes(types, counters)
    local catalog = {}

    for _, animalType in ipairs(orderedTypes) do
        local typeLabel = deps.typeLabel(animalType)
        -- Numeric-guarded like `minAge`: a mod shipping a non-number must not reach math here.
        local maxBuyAge = type(animalType.maxBuyAge) == "number" and animalType.maxBuyAge or 60
        if type(animalType.subTypes) ~= "table" then
            Log:trace("RLDealerSaleCatalog.build: type %s has no subTypes array; skipped",
                tostring(animalType.name))
        else
            for _, subTypeIdx in ipairs(animalType.subTypes) do
                local subType = deps.getSubTypeByIndex(subTypeIdx)
                local name = subType ~= nil and subType.name or nil
                if subType == nil or type(name) ~= "string" or name == "" then
                    counters.subTypesSkipped = counters.subTypesSkipped + 1
                    Log:trace("RLDealerSaleCatalog.build: subType index %s unresolved or unnamed; skipped",
                        tostring(subTypeIdx))
                elseif type(subType.visuals) ~= "table" or #subType.visuals == 0 then
                    counters.subTypesSkipped = counters.subTypesSkipped + 1
                    Log:trace("RLDealerSaleCatalog.build: subType %s has nil/empty visuals; skipped", name)
                else
                    local stages = buildStages(subType, maxBuyAge, counters)
                    if #stages == 0 then
                        counters.subTypesSkipped = counters.subTypesSkipped + 1
                        Log:trace("RLDealerSaleCatalog.build: subType %s has no buyable-stage visuals; skipped", name)
                    else
                        catalog[#catalog + 1] = {
                            typeIndex    = animalType.typeIndex,
                            typeLabel    = typeLabel,
                            subTypeIndex = subType.subTypeIndex or subTypeIdx,
                            subTypeName  = name,
                            subTypeLabel = deps.subTypeLabel(name, animalType.typeIndex),
                            visuals      = stages,
                        }
                    end
                end
            end
        end
    end

    Log:debug("RLDealerSaleCatalog.build: %d entr(ies) from %d type(s); %d type(s), %d subtype(s), %d visual(s), %d stage(s) skipped",
        #catalog, #orderedTypes, counters.typesSkipped, counters.subTypesSkipped, counters.visualsSkipped, counters.stagesDropped)
    return catalog
end

-- =============================================================================
-- In-game shell (binds the live animalSystem + real label seams)
-- =============================================================================

--- Build the catalog from the live animal system: resolve the animalSystem, bind
--- `getSubTypeByIndex` and the two env-coupled label seams into `deps`, then delegate. Returns
--- `{}` with a warning on any unavailable dependency. The `build` call is wrapped in a
--- last-resort `pcall` so a throwing label seam surfaces as `{}` plus an error rather than
--- reaching the dialog opener; the seams are load-order guaranteed, so that is defence in depth.
---@return table[] catalog (empty on any unavailable dependency or build error)
function RLDealerSaleCatalog.enumerate()
    if g_currentMission == nil or g_currentMission.animalSystem == nil then
        Log:warning("RLDealerSaleCatalog.enumerate: animalSystem unavailable; returning empty")
        return {}
    end

    local animalSystem = g_currentMission.animalSystem
    if animalSystem.getTypes == nil then
        Log:warning("RLDealerSaleCatalog.enumerate: animalSystem.getTypes unavailable; returning empty")
        return {}
    end

    local types = animalSystem:getTypes()
    if types == nil then
        Log:warning("RLDealerSaleCatalog.enumerate: getTypes() returned nil; returning empty")
        return {}
    end

    local deps = {
        getSubTypeByIndex = function(idx) return animalSystem:getSubTypeByIndex(idx) end,
        typeLabel         = RLAnimalUtil.getAnimalTypeDisplayName,
        subTypeLabel      = function(name, typeIndex)
            return RLFilterFieldDisplay.getEnumValueDisplayName("subType", name, typeIndex)
        end,
    }

    local ok, result = pcall(RLDealerSaleCatalog.build, types, deps)
    if not ok then
        Log:error("RLDealerSaleCatalog.enumerate: build failed; returning empty: %s", tostring(result))
        return {}
    end

    Log:debug("RLDealerSaleCatalog.enumerate: built %d catalog entr(ies) from live animalSystem", #result)
    return result
end

Log:debug("RLDealerSaleCatalog: loaded")
