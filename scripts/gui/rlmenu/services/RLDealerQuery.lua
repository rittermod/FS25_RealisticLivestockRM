--[[
    RLDealerQuery.lua
    Read-only query service for the RL Tabbed Menu Buy tab:
      * list every registered dealer animal type (no stock filter)
      * list sale animals currently available at the dealer for a given type
      * group into SmoothList sections (diseased-first + per-subtype)

    Mirrors the shape of RLAnimalQuery (husbandry-side) without depending on
    it, so Buy can diverge in small ways (e.g., Animal-object items instead
    of AnimalItemStock cluster wrappers).
]]

RLDealerQuery = {}

local Log = RmLogging.getLogger("RLRM")

-- =============================================================================
-- Type enumeration
-- =============================================================================

--- Return every registered animal type, sorted ascending by typeIndex.
--- Does NOT filter by current stock - zero-stock types still appear in the
--- sidebar with an empty list body (matches how Sell renders empty husbandries).
--- @return table types  Array of animal type entries from animalSystem:getTypes()
function RLDealerQuery.listDealerTypes()
    if g_currentMission == nil or g_currentMission.animalSystem == nil then
        Log:warning("RLDealerQuery.listDealerTypes: animalSystem unavailable")
        return {}
    end

    local animalSystem = g_currentMission.animalSystem
    if animalSystem.getTypes == nil then
        Log:warning("RLDealerQuery.listDealerTypes: animalSystem.getTypes unavailable")
        return {}
    end

    local rawTypes = animalSystem:getTypes()
    if rawTypes == nil then return {} end

    local result = {}
    for _, animalType in pairs(rawTypes) do
        if animalType ~= nil and animalType.typeIndex ~= nil then
            table.insert(result, animalType)
        end
    end

    table.sort(result, function(a, b)
        return (a.typeIndex or 0) < (b.typeIndex or 0)
    end)

    Log:debug("RLDealerQuery.listDealerTypes: returned %d types (sorted by typeIndex)", #result)
    return result
end

-- =============================================================================
-- Animal list for a dealer type
-- =============================================================================

--- Wrap a dealer sale Animal in the SAME generic wrapper the other tabs use - it carries
--- no dealer-specific fields, so reusing it here is safe. A swappable field, for tests.
--- @param animal table  Animal object from animalSystem:getSaleAnimalsByTypeIndex
--- @return table|nil item
function RLDealerQuery._wrapSaleAnimal(animal)
    if animal == nil then return nil end
    if AnimalItemStock == nil or AnimalItemStock.new == nil then return nil end
    return AnimalItemStock.new(animal)
end

--- Return sale-animal items for the given dealer type, sorted by subTypeIndex
--- then age for a stable in-section order. Empty for unknown / empty type.
--- @param typeIndex number
--- @return table items
function RLDealerQuery.listDealerAnimalsForType(typeIndex)
    if typeIndex == nil then return {} end

    if g_currentMission == nil or g_currentMission.animalSystem == nil then
        Log:warning("RLDealerQuery.listDealerAnimalsForType: animalSystem unavailable")
        return {}
    end

    local animalSystem = g_currentMission.animalSystem
    if animalSystem.getSaleAnimalsByTypeIndex == nil then
        Log:warning("RLDealerQuery.listDealerAnimalsForType: getSaleAnimalsByTypeIndex unavailable")
        return {}
    end

    local animals = animalSystem:getSaleAnimalsByTypeIndex(typeIndex)
    if animals == nil then
        Log:trace("RLDealerQuery.listDealerAnimalsForType: typeIndex=%s no animals", tostring(typeIndex))
        return {}
    end

    local items = {}
    for _, animal in pairs(animals) do
        local wrapped = RLDealerQuery._wrapSaleAnimal(animal)
        if wrapped ~= nil then
            table.insert(items, wrapped)
        end
    end

    -- The shared comparator, so Buy orders exactly as the other tabs do. The wrapper
    -- already populates the cached genetics average each item is sorted on.
    if RLAnimalDisplayHelper ~= nil and RLAnimalDisplayHelper.sortAnimals ~= nil then
        table.sort(items, RLAnimalDisplayHelper.sortAnimals)
    else
        Log:warning("RLDealerQuery.listDealerAnimalsForType: RLAnimalDisplayHelper.sortAnimals unavailable; returning unsorted")
    end

    Log:debug("RLDealerQuery.listDealerAnimalsForType: typeIndex=%s items=%d",
        tostring(typeIndex), #items)
    return items
end

-- =============================================================================
-- Section grouping (SmoothList multi-section data source)
-- =============================================================================

--- Group dealer items into sections: diseased first when any are present, then one per
--- distinct subType. Sections appear in ENCOUNTER order, so the caller must pre-sort
--- disease-first - the standard list path does; an unsorted caller gets input order.
--- @param items table
--- @return table sectionOrder, table itemsBySection, table titlesBySection
function RLDealerQuery.buildDealerSections(items)
    local sectionOrder    = {}
    local itemsBySection  = {}
    local titlesBySection = {}

    if items == nil or #items == 0 then
        return sectionOrder, itemsBySection, titlesBySection
    end

    local DISEASED_KEY = "__diseased__"

    for _, item in ipairs(items) do
        local cluster = item.cluster
        if cluster ~= nil then
            local isDiseased = cluster.getHasAnyDisease ~= nil
                and cluster:getHasAnyDisease() == true
            local key, title

            if isDiseased then
                key = DISEASED_KEY
                title = (g_i18n ~= nil) and g_i18n:getText("rl_ui_diseasedAnimals")
                    or "Diseased Animals"
            else
                key = "subtype_" .. tostring(cluster.subTypeIndex or 0)
                title = item.title
                if (title == nil or title == "") and g_currentMission ~= nil
                    and g_currentMission.animalSystem ~= nil then
                    local subType = g_currentMission.animalSystem:getSubTypeByIndex(
                        cluster.subTypeIndex)
                    if subType ~= nil and subType.fillTypeIndex ~= nil
                        and g_fillTypeManager ~= nil then
                        title = g_fillTypeManager:getFillTypeTitleByIndex(subType.fillTypeIndex)
                    end
                end
                if title == nil or title == "" then title = "?" end
            end

            if itemsBySection[key] == nil then
                table.insert(sectionOrder, key)
                itemsBySection[key] = {}
                titlesBySection[key] = title
            end
            table.insert(itemsBySection[key], item)
        end
    end

    return sectionOrder, itemsBySection, titlesBySection
end
