--[[
    RLAIStockService.lua
    Read-only query + presentation service for the RL Tabbed Menu AI tab:
      * list every registered animal species (no stock filter)
      * list AI stock bulls for a given species
      * group into SmoothList sections (per-subtype; no "Diseased" section -
        AI stock bulls are never sick in normal play)
      * overall-quality label computation for the row (carries forward legacy
        behavior - the overall-quality label in the "price" slot of each row)
      * per-quantity semen price computation for the middle-column display
        (the quantity stepper drives the quantity argument)

    Disjoint from RLAnimalQuery / RLDealerQuery: AI stock comes from
    animalSystem:getAIAnimalsByTypeIndex, not from husbandries or dealer stock.
]]

RLAIStockService = {}

local Log = RmLogging.getLogger("RLRM")

--- Resolve the local player object. Defaults to the `g_localPlayer` global;
--- exposed as a field so tests can swap in a nil-returning stub.
---
--- The FS25 runtime protects `g_*` root-key writes, so a test cannot nil
--- out `g_localPlayer` directly. This seam gives the nil-player guard in
--- `toggleFavourite` a way to be exercised from tests.
--- @return table|nil
RLAIStockService._getLocalPlayer = function()
    return g_localPlayer
end

-- =============================================================================
-- Species enumeration
-- =============================================================================

--- Every registered species, SORTED by typeIndex rather than left to `pairs`, whose order
--- is not guaranteed. Does NOT filter by stock: a zero-stock species still appears in the
--- cycler with an empty body, as every other frame handles its empty state.
--- @return table types  Array of animal type entries from animalSystem:getTypes()
function RLAIStockService.listSpecies()
    if g_currentMission == nil or g_currentMission.animalSystem == nil then
        Log:warning("RLAIStockService.listSpecies: animalSystem unavailable")
        return {}
    end

    local animalSystem = g_currentMission.animalSystem
    if animalSystem.getTypes == nil then
        Log:warning("RLAIStockService.listSpecies: animalSystem.getTypes unavailable")
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

    Log:trace("RLAIStockService.listSpecies: returned %d species (sorted by typeIndex)", #result)
    return result
end

-- =============================================================================
-- AI bulls for a species
-- =============================================================================

--- Wrap an AI stock bull in an AnimalItemStock - the same base-game wrapper
--- Sell/Move/Info/Buy use via the other query services. Gives us
--- `getFilename()` (animal portrait), `title`, and `.cluster` for free.
--- Exposed as a field so tests can swap in a lightweight stub.
--- @param animal table  Animal object from animalSystem:getAIAnimalsByTypeIndex
--- @return table|nil item
function RLAIStockService._wrapBull(animal)
    if animal == nil then return nil end
    if AnimalItemStock == nil or AnimalItemStock.new == nil then return nil end
    return AnimalItemStock.new(animal)
end

--- Return AI-stock items for the given species, sorted by subTypeIndex
--- ascending then age descending (mirrors the legacy comparator). Empty for
--- unknown / empty species.
--- @param typeIndex number
--- @return table items
function RLAIStockService.listBullsForSpecies(typeIndex)
    if typeIndex == nil then return {} end

    if g_currentMission == nil or g_currentMission.animalSystem == nil then
        Log:warning("RLAIStockService.listBullsForSpecies: animalSystem unavailable")
        return {}
    end

    local animalSystem = g_currentMission.animalSystem
    if animalSystem.getAIAnimalsByTypeIndex == nil then
        Log:warning("RLAIStockService.listBullsForSpecies: getAIAnimalsByTypeIndex unavailable")
        return {}
    end

    local animals = animalSystem:getAIAnimalsByTypeIndex(typeIndex)
    if animals == nil then
        Log:trace("RLAIStockService.listBullsForSpecies: typeIndex=%s no animals", tostring(typeIndex))
        return {}
    end

    local items = {}
    for _, animal in pairs(animals) do
        local wrapped = RLAIStockService._wrapBull(animal)
        if wrapped ~= nil then
            table.insert(items, wrapped)
        end
    end

    -- Legacy comparator:
    --   (a.subTypeIndex == b.subTypeIndex) and (a.age > b.age) or (a.subTypeIndex < b.subTypeIndex)
    -- Same subtype -> older first; different subtype -> lower subtype first.
    table.sort(items, function(a, b)
        local aSub = a.cluster and a.cluster.subTypeIndex or 0
        local bSub = b.cluster and b.cluster.subTypeIndex or 0
        if aSub == bSub then
            local aAge = a.cluster and a.cluster.age or 0
            local bAge = b.cluster and b.cluster.age or 0
            return aAge > bAge
        end
        return aSub < bSub
    end)

    Log:trace("RLAIStockService.listBullsForSpecies: typeIndex=%s items=%d",
        tostring(typeIndex), #items)
    return items
end

-- =============================================================================
-- Section grouping (SmoothList multi-section data source)
-- =============================================================================

--- Group bull items into one section per distinct subTypeIndex, in encounter order - which
--- the caller's own comparator makes ascending. No "Diseased" section: AI stock bulls
--- carry no disease state, and one that somehow did would just sort into its subtype.
--- @param items table
--- @return table sectionOrder, table itemsBySection, table titlesBySection
function RLAIStockService.buildSections(items)
    Log:trace("RLAIStockService.buildSections: items=%d",
        (items ~= nil and #items) or 0)

    local sectionOrder    = {}
    local itemsBySection  = {}
    local titlesBySection = {}

    if items == nil or #items == 0 then
        return sectionOrder, itemsBySection, titlesBySection
    end

    for _, item in ipairs(items) do
        local cluster = item.cluster
        if cluster ~= nil then
            local key = "subtype_" .. tostring(cluster.subTypeIndex or 0)
            local title = item.title
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

-- =============================================================================
-- Overall-quality label (row "price" slot)
-- =============================================================================

--- The overall-quality i18n key for a bull, from its average genetics:
---
---   avgGenetics >= 1.65 -> extremelyGood
---   avgGenetics >= 1.35 -> veryGood
---   avgGenetics >= 1.15 -> good
---   avgGenetics >= 0.85 -> average
---   avgGenetics >= 0.65 -> bad
---   avgGenetics >= 0.35 -> veryBad
---   else                 -> extremelyBad
---
--- The return is the FULL key, ready to pass straight to g_i18n:getText.
--- @param animal table  Raw Animal (not wrapped) - needs `animal.genetics` table
--- @return string i18nKey
function RLAIStockService.getQualityLabel(animal)
    if animal == nil or animal.genetics == nil then
        Log:trace("RLAIStockService.getQualityLabel: nil animal or genetics -> extremelyBad")
        return "rl_ui_genetics_extremelyBad"
    end

    local genetics = 0
    local numGenetics = 0
    for _, value in pairs(animal.genetics) do
        genetics = genetics + value
        numGenetics = numGenetics + 1
    end

    local avgGenetics = (numGenetics > 0 and genetics / numGenetics) or 0
    local label = "extremelyBad"

    if avgGenetics >= 1.65 then
        label = "extremelyGood"
    elseif avgGenetics >= 1.35 then
        label = "veryGood"
    elseif avgGenetics >= 1.15 then
        label = "good"
    elseif avgGenetics >= 0.85 then
        label = "average"
    elseif avgGenetics >= 0.65 then
        label = "bad"
    elseif avgGenetics >= 0.35 then
        label = "veryBad"
    end

    Log:trace("RLAIStockService.getQualityLabel: uniqueId=%s avg=%.3f -> %s",
        tostring(animal.uniqueId), avgGenetics, label)
    return "rl_ui_genetics_" .. label
end

-- =============================================================================
-- Semen price (middle-column total-price display)
-- =============================================================================

--- The total semen price for a bull and straw quantity. Returns the FINAL price including
--- PRICE_PER_STRAW, not an intermediate the caller must finish:
---
---   price = getFarmSemenPrice(country, farmId)
---         * quantity
---         * PRICE_PER_STRAW
---         * animal.success
---         * 2.25
---         * product(animal.genetics)
---
--- @param animal table  Raw Animal with `.birthday.country`, `.farmId`, `.success`, `.genetics`
--- @param quantity number  Positive integer straw count
--- @return number price
function RLAIStockService.getPriceForQuantity(animal, quantity)
    if animal == nil or quantity == nil or quantity <= 0 then
        return 0
    end

    if g_currentMission == nil or g_currentMission.animalSystem == nil then
        Log:warning("RLAIStockService.getPriceForQuantity: animalSystem unavailable")
        return 0
    end

    local animalSystem = g_currentMission.animalSystem
    if animalSystem.getFarmSemenPrice == nil then
        Log:warning("RLAIStockService.getPriceForQuantity: getFarmSemenPrice unavailable")
        return 0
    end

    local country = (animal.birthday ~= nil and animal.birthday.country) or 0
    local farmId  = animal.farmId or 0

    local pricePerStraw = (DewarData ~= nil and DewarData.PRICE_PER_STRAW) or 0.85
    local success = animal.success or 0

    local price = animalSystem:getFarmSemenPrice(country, farmId)
        * quantity
        * pricePerStraw
        * success
        * 2.25

    if type(animal.genetics) == "table" then
        for _, value in pairs(animal.genetics) do
            price = price * value
        end
    end

    Log:trace("RLAIStockService.getPriceForQuantity: uniqueId=%s quantity=%d price=%.2f",
        tostring(animal.uniqueId), quantity, price)
    return price
end

-- =============================================================================
-- Favourite toggle (local-only; mirrors the legacy favourite handler)
-- =============================================================================

--- Toggle the local player's favourite mark on a bull. The bit is stored per player and
--- never network-synced, so a rejoining client loses its favourites. A nil return means
--- FAILURE, distinct from false, so the caller can tell it apart from "unfavourited".
--- @param animal table  Raw Animal with a `favouritedBy` table (lazily created)
--- @return boolean|nil isFavourite
function RLAIStockService.toggleFavourite(animal)
    if animal == nil then
        Log:warning("RLAIStockService.toggleFavourite: nil animal")
        return nil
    end

    local localPlayer = RLAIStockService._getLocalPlayer()
    if localPlayer == nil then
        Log:warning("RLAIStockService.toggleFavourite: g_localPlayer unavailable; skipping toggle")
        return nil
    end

    local uniqueId = localPlayer:getUniqueId()
    if uniqueId == nil then
        Log:warning("RLAIStockService.toggleFavourite: localPlayer uniqueId nil")
        return nil
    end

    if type(animal.favouritedBy) ~= "table" then
        animal.favouritedBy = {}
    end

    -- Collapse legacy's three-branch nil/true/false logic into one write.
    -- Both nil -> true and false -> true land on true; true -> false.
    local newState = not (animal.favouritedBy[uniqueId] == true)
    animal.favouritedBy[uniqueId] = newState

    Log:debug("RLAIStockService.toggleFavourite: uniqueId=%s farmId=%s bullUid=%s -> %s",
        tostring(uniqueId), tostring(animal.farmId), tostring(animal.uniqueId),
        tostring(newState))
    return newState
end


--- Resolve the Favourite button's i18n key for the given favourite state.
--- Shared by selection-change (read) and toggle (post-write) call sites so
--- both fall through the same mapping. Mirrors the label choice in the legacy
--- selection handler (the only site legacy gets right; the legacy toggle site
--- has a latent bug we deliberately do not replicate).
--- @param isFavourite boolean|nil
--- @return string i18nKey  Pass to g_i18n:getText
function RLAIStockService.getFavouriteButtonText(isFavourite)
    Log:trace("RLAIStockService.getFavouriteButtonText: isFavourite=%s", tostring(isFavourite))
    if isFavourite == true then
        return "rl_ui_unFavourite"
    end
    return "rl_ui_favourite"
end
