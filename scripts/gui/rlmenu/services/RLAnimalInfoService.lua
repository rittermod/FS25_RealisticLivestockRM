--[[
    RLAnimalInfoService.lua
    Display and mutation service for the RL Tabbed Menu Info tab.

    Read-only:
      * getHusbandryDisplay(husbandry, farmId) -> pen column payload
      * sumFoodTotals(foodInfos, meadowInfo)   -> store, meadow and total food litres
      * getAnimalDisplay(animal, husbandry)    -> animal column payload
      * getFarmBalance(farmId)                 -> integer money or nil

    Mutations:
      * toggleMonitor(animal)         -> active, removed
      * renameAnimal(animal, newName) -> nil
]]

RLAnimalInfoService = {}

local Log = RmLogging.getLogger("RLRM")

-- =============================================================================
-- Internal helpers
-- =============================================================================

--- Return a reference to the animalSystem, or nil if the mission isn't ready.
--- @return table|nil
local function getAnimalSystem()
    if g_currentMission == nil then return nil end
    return g_currentMission.animalSystem
end

--- Build one pedigree row. Missing parents render as a localization key
--- the frame resolves to "unknown".
---
--- Treats both string `"-1"` / `""` and numeric `0` / `-1` as unknown so
--- migration anomalies that store the sentinel as a number don't render
--- a literal "(0)" or "(-1)".
--- @param labelKey string
--- @param id string|number|nil
--- @return table row
local function buildParentRow(labelKey, id)
    local hasId = id ~= nil
        and id ~= "-1" and id ~= ""
        and id ~= 0 and id ~= -1
    -- Explicit if/else: a `hasId and nil or "rl_ui_unknown"` ternary would
    -- always pick the right side because `(true and nil) or "..."` evaluates
    -- to the right side. Lua's `and/or` is not a ternary when the truthy
    -- branch is nil.
    local row = { labelKey = labelKey }
    if hasId then
        row.idText = tostring(id)
    else
        row.unknownKey = "rl_ui_unknown"
    end
    return row
end

--- Build the children pedigree row. Counts entries in animal.children.
--- @param animal table
--- @return table row
local function buildChildrenRow(animal)
    local count = 0
    if type(animal.children) == "table" then count = #animal.children end
    return {
        labelKey = "rl_menu_info_children",
        count    = count,
    }
end

-- Gated on `diseasesEnabled` like the card icons and the HUD box: with diseases off, a frozen
-- record here would claim an animal is sick while every other surface disagrees. The nil-manager
-- arm is cheap symmetry, not a claim the tree is nil-safe.
--- Disease rows for read-only display, one per record a player may see, named from its model entry.
--- @param animal table
--- @return table rows
local function buildDiseaseRows(animal)
    local rows = {}
    if g_diseaseManager == nil or not g_diseaseManager.diseasesEnabled then
        Log:trace("RLAnimalInfoService.buildDiseaseRows: no rows, reason=diseases disabled")
        return rows
    end
    if animal == nil or type(animal.diseases) ~= "table" then return rows end
    -- Only what `Disease.isVisibleToPlayer` admits, the rule the HUD and the dialog share. The
    -- model and getStatus guards only ever cover a hand-built fixture, so an assert against their
    -- fallback measures the fallback rather than the row.
    local hidden = 0
    for _, disease in ipairs(animal.diseases) do
        if disease ~= nil and disease.model ~= nil then
            if not Disease.isVisibleToPlayer(disease) then
                hidden = hidden + 1
            else
                local status = ""
                if disease.getStatus ~= nil then
                    local ok, statusText = pcall(function() return disease:getStatus() end)
                    if ok and statusText ~= nil then status = statusText end
                end
                table.insert(rows, {
                    name   = disease.model.name or "",
                    status = status,
                })
            end
        end
    end
    if hidden > 0 then
        Log:trace("RLAnimalInfoService.buildDiseaseRows: hid %d incubating record(s) (farmId=%s uniqueId=%s)",
            hidden, tostring(animal.farmId), tostring(animal.uniqueId))
    end
    return rows
end

--- Build input rows for monitored animals.
--- @param animal table
--- @return table rows
local function buildInputRows(animal)
    local rows = {}
    if animal == nil or type(animal.input) ~= "table" then return rows end
    local daysPerMonth = g_currentMission.environment.daysPerPeriod
    for fillType, amount in pairs(animal.input) do
        local title = g_i18n:getText("rl_ui_input_" .. fillType)
        local valueText = RLAnimalDisplayHelper.formatAmountPerDay((amount * 24) / daysPerMonth)
        table.insert(rows, { title = title, valueText = valueText })
    end
    return rows
end

--- The label of an animal's pallets output row: a shipped key (by type, GOAT by subtype), else its fill type's title.
--- @param animal table
--- @return string title
local function getPalletsTitle(animal)
    local animalSystem = getAnimalSystem()
    local typeName = animalSystem ~= nil and animalSystem.typeIndexToName[animal.animalTypeIndex] or nil
    local subType = animal.getSubType ~= nil and animal:getSubType() or nil
    local pallets = subType ~= nil and subType.output ~= nil and subType.output.pallets or nil
    local fillTypeTitle = nil
    if pallets ~= nil and pallets.fillType ~= nil then
        fillTypeTitle = g_fillTypeManager:getFillTypeTitleByIndex(pallets.fillType)
    end
    local text, isKey = RLAnimalTypeSupport.palletsOutputLabel(typeName, animal.subType, fillTypeTitle)
    Log:trace("RLAnimalInfoService.getPalletsTitle: type=%s subType=%s -> %s (isKey=%s)",
        tostring(typeName), tostring(animal.subType), tostring(text), tostring(isKey))
    return isKey and g_i18n:getText(text) or text
end

--- Build output rows for monitored animals; a pallets output takes getPalletsTitle's label.
--- @param animal table
--- @return table rows
local function buildOutputRows(animal)
    local rows = {}
    if animal == nil or type(animal.output) ~= "table" then return rows end
    local daysPerMonth = g_currentMission.environment.daysPerPeriod
    for fillType, amount in pairs(animal.output) do
        local title
        if fillType == "pallets" then
            title = getPalletsTitle(animal)
        else
            title = g_i18n:getText("rl_ui_output_" .. fillType)
        end
        local valueText = RLAnimalDisplayHelper.formatAmountPerDay((amount * 24) / daysPerMonth)
        table.insert(rows, { title = title, valueText = valueText })
    end
    return rows
end

-- Reproduce eligibility comes from statRows via getAnimalInfos; not duplicated here.

-- =============================================================================
-- Husbandry display
-- =============================================================================

-- The meadow entry is matched by table identity, never by flag or title. Its capacity is 0 or
-- stale, so it stays out of the store capacity and ratio.
--- Sum a pen's food entries into store and meadow litres.
--- @param foodInfos table entries from getFoodInfos
--- @param meadowInfo table|nil the pen's meadow food entry
--- @return table totals { storeValue, storeCapacity, storeRatio, meadowValue, totalValue }
function RLAnimalInfoService.sumFoodTotals(foodInfos, meadowInfo)
    local storeValue = 0
    local storeCapacity = 0
    local meadowValue = 0
    for _, info in ipairs(foodInfos) do
        if meadowInfo ~= nil and info == meadowInfo then
            meadowValue = meadowValue + (info.value or 0)
        elseif not info.ignoreCapacity then
            storeCapacity = math.max(info.capacity or 0, storeCapacity)
            storeValue = storeValue + (info.value or 0)
        end
    end

    local storeRatio = 0
    if storeCapacity > 0 then
        storeRatio = storeValue / storeCapacity
    end
    local totalValue = storeValue + meadowValue

    Log:trace("RLAnimalInfoService.sumFoodTotals: store=%.2f storeCapacity=%.2f storeRatio=%.4f"
        .. " meadow=%.2f total=%.2f", storeValue, storeCapacity, storeRatio, meadowValue, totalValue)

    return {
        storeValue    = storeValue,
        storeCapacity = storeCapacity,
        storeRatio    = storeRatio,
        meadowValue   = meadowValue,
        totalValue    = totalValue,
    }
end

--- Build the pen-column payload for a husbandry.
---
--- Returns:
---   {
---     name              = string,              -- pen display name
---     countText         = string,              -- "current/max", or "current" if max unknown
---     penImageFilename  = string|nil,          -- nil -> frame hides icon
---     conditionInfos    = table (passed through from husbandry:getConditionInfos),
---     foodInfos         = table (passed through from husbandry:getFoodInfos),
---     foodTotalValue    = number,              -- store litres plus the pen's meadow litres
---     foodTotalCapacity = number,              -- store only
---     foodTotalRatio    = number,              -- store only
---   }
---
--- conditionInfos / foodInfos are pure pass-throughs (RL does not override
--- those husbandry methods); this builder adds the name/count composition and
--- takes the food totals from sumFoodTotals.
---
--- @param husbandry table|nil
--- @param farmId number|nil
--- @return table|nil display, nil if husbandry is nil
function RLAnimalInfoService.getHusbandryDisplay(husbandry, farmId)
    if husbandry == nil then
        Log:trace("RLAnimalInfoService.getHusbandryDisplay: nil husbandry")
        return nil
    end

    local name = ""
    if husbandry.getName ~= nil then
        local ok, result = pcall(function() return husbandry:getName() end)
        if ok and result ~= nil then name = result end
    end

    local current, max = 0, nil
    if husbandry.getNumOfAnimals ~= nil then
        local ok, n = pcall(function() return husbandry:getNumOfAnimals() end)
        if ok and type(n) == "number" then current = n end
    end
    if husbandry.getMaxNumOfAnimals ~= nil then
        local ok, n = pcall(function() return husbandry:getMaxNumOfAnimals(nil) end)
        if ok and type(n) == "number" then max = n end
    end
    local countText = (max ~= nil) and string.format("%d/%d", current, max) or string.format("%d", current)

    local penImageFilename
    if husbandry.storeItem ~= nil then
        penImageFilename = husbandry.storeItem.imageFilename
    end

    local conditionInfos = {}
    if husbandry.getConditionInfos ~= nil then
        local ok, infos = pcall(function() return husbandry:getConditionInfos() end)
        if ok and type(infos) == "table" then conditionInfos = infos end
    end

    local foodInfos = {}
    if husbandry.getFoodInfos ~= nil then
        local ok, infos = pcall(function() return husbandry:getFoodInfos() end)
        if ok and type(infos) == "table" then foodInfos = infos end
    end

    -- The text, the alert colour and both forecasts count the meadow's grass; the bar
    -- (foodTotalRatio) measures the feed store only.
    local meadowInfo
    if husbandry.spec_husbandryMeadow ~= nil then
        meadowInfo = husbandry.spec_husbandryMeadow.foodInfo
    end
    local totals = RLAnimalInfoService.sumFoodTotals(foodInfos, meadowInfo)

    local foodMonthsRemaining
    if RLPenFeedForecast ~= nil and RLPenFeedForecast.getMonthsRemaining ~= nil then
        foodMonthsRemaining = RLPenFeedForecast.getMonthsRemaining(husbandry, totals.totalValue)
    end

    -- Real-days runway drives the low-feed colour alert (daysPerPeriod-stable);
    -- foodMonthsRemaining above still drives the at-a-glance months range label.
    local foodDaysRemaining
    if RLPenFeedForecast ~= nil and RLPenFeedForecast.getDaysRemaining ~= nil then
        foodDaysRemaining = RLPenFeedForecast.getDaysRemaining(husbandry, totals.totalValue)
    end

    Log:debug("RLAnimalInfoService.getHusbandryDisplay: farmId=%s husbandry='%s' count=%s"
        .. " store=%.2f meadow=%.2f total=%.2f",
        tostring(farmId), name, countText, totals.storeValue, totals.meadowValue, totals.totalValue)

    return {
        name                = name,
        countText           = countText,
        penImageFilename    = penImageFilename,
        conditionInfos      = conditionInfos,
        foodInfos           = foodInfos,
        foodTotalValue      = totals.totalValue,
        foodTotalCapacity   = totals.storeCapacity,
        foodTotalRatio      = totals.storeRatio,
        foodMonthsRemaining = foodMonthsRemaining,
        foodDaysRemaining   = foodDaysRemaining,
    }
end

-- =============================================================================
-- Animal display
-- =============================================================================

--- Build the animal-column payload for a cluster/animal.
---
--- Returns:
---   {
---     typeName             = string,
---     animalImageFilename  = string|nil, -- nil -> frame hides image
---     ageText              = string,
---     canReproduceKey      = string|nil, -- nil -> hide row
---     description          = string,
---     diseaseRows          = table,
---     pedigreeMother       = table,      -- { labelKey, idText|nil, unknownKey|nil }
---     pedigreeFather       = table,
---     pedigreeChildren     = table,      -- { labelKey, count }
---     geneticsRows         = table,      -- from RLGeneticsFormatter.format
---     hasMonitor           = boolean,
---     inputRows            = table,      -- { {title, valueText}, ... }
---     outputRows           = table,      -- { {title, valueText}, ... }
---   }
---
--- Calls g_currentMission.animalSystem for visual + subType lookup. Returns
--- nil animalImageFilename when the visual lookup is nil (frame hides the
--- image); other fields still render.
---
--- @param animal table|nil
--- @param husbandry table|nil
--- @return table|nil display, nil if animal is nil
function RLAnimalInfoService.getAnimalDisplay(animal, husbandry)
    if animal == nil then
        Log:trace("RLAnimalInfoService.getAnimalDisplay: nil animal")
        return nil
    end

    Log:debug("RLAnimalInfoService.getAnimalDisplay: farmId=%s uniqueId=%s animalType=%s",
        tostring(animal.farmId), tostring(animal.uniqueId), tostring(animal.animalTypeIndex))

    local animalSystem = getAnimalSystem()
    local subTypeIndex = nil
    if animal.getSubTypeIndex ~= nil then
        local ok, result = pcall(function() return animal:getSubTypeIndex() end)
        if ok then subTypeIndex = result end
    elseif animal.subTypeIndex ~= nil then
        subTypeIndex = animal.subTypeIndex
    end

    local subType
    if animalSystem ~= nil and subTypeIndex ~= nil and animalSystem.getSubTypeByIndex ~= nil then
        subType = animalSystem:getSubTypeByIndex(subTypeIndex)
    end

    local age = 0
    if animal.getAge ~= nil then
        local ok, result = pcall(function() return animal:getAge() end)
        if ok and type(result) == "number" then age = result end
    elseif type(animal.age) == "number" then
        age = animal.age
    end

    local visual
    if animalSystem ~= nil and subTypeIndex ~= nil and animalSystem.getVisualByAge ~= nil then
        visual = animalSystem:getVisualByAge(subTypeIndex, age)
    end

    local animalImageFilename
    if visual ~= nil and visual.store ~= nil then
        animalImageFilename = visual.store.imageFilename
    else
        Log:trace("RLAnimalInfoService.getAnimalDisplay: no visual for subType=%s age=%d",
            tostring(subTypeIndex), age)
    end

    local typeName = ""
    if subType ~= nil and g_fillTypeManager ~= nil and g_fillTypeManager.getFillTypeTitleByIndex ~= nil then
        typeName = g_fillTypeManager:getFillTypeTitleByIndex(subType.fillTypeIndex) or ""
    end
    -- Animal custom name wins over species type name when present.
    if animal.getName ~= nil then
        local ok, customName = pcall(function() return animal:getName() end)
        if ok and customName ~= nil and customName ~= "" then typeName = customName end
    end

    -- Per-animal stat rows, shaped { title, valueText, ratio, invertedBar, disabled }.
    -- Variable length: it depends on monitor state, gender and husbandry capability.
    local statRows = {}
    if husbandry ~= nil and husbandry.getAnimalInfos ~= nil then
        local ok, result = pcall(function() return husbandry:getAnimalInfos(animal) end)
        if ok and type(result) == "table" then statRows = result end
    elseif animal.addInfos ~= nil then
        -- Nil-husbandry fallback for the Buy tab, where dealer animals have no source pen.
        -- forceShowAll includes the monitor-gated rows: a dealer animal carries no monitor,
        -- but the player needs full visibility at purchase time. pcall-guarded, because
        -- some branches reach a cluster system a fresh sale animal has not got.
        local ok, err = pcall(function() animal:addInfos(statRows, true) end)
        if not ok then
            Log:trace("RLAnimalInfoService.getAnimalDisplay: animal:addInfos failed for dealer animal, age-only fallback: %s", tostring(err))
            statRows = {}
        end
    end

    -- Age is always first, ungated. Animal:addInfos does not emit an age row,
    -- so inject it explicitly here for the new menu (which renders the whole
    -- list uniformly from statRows rather than a dedicated age widget).
    table.insert(statRows, 1, {
        title     = g_i18n:getText("ui_age"),
        valueText = g_i18n:formatNumMonth(age),
        value     = 1,
        ratio     = 1,
    })
    Log:trace("RLAnimalInfoService.getAnimalDisplay: injected age row, age=%d", age)

    local description = ""
    if husbandry ~= nil and husbandry.getAnimalDescription ~= nil then
        local ok, result = pcall(function() return husbandry:getAnimalDescription(animal) end)
        if ok and result ~= nil then description = result end
    elseif visual ~= nil and visual.store ~= nil and visual.store.description ~= nil then
        -- Nil-husbandry fallback for the Buy tab: use the breed lore text
        -- from the visual config (visual.store.description).
        description = visual.store.description
    end

    local geneticsRows = {}
    if RLGeneticsFormatter ~= nil and RLGeneticsFormatter.format ~= nil then
        geneticsRows = RLGeneticsFormatter.format(animal.genetics, animal.animalTypeIndex, animal.subType,
            animal.isCastrated)
    end

    local hasMonitor = animal.monitor ~= nil
        and (animal.monitor.active or animal.monitor.removed)

    return {
        typeName             = typeName,
        animalImageFilename  = animalImageFilename,
        statRows             = statRows,
        description          = description,
        diseaseRows          = buildDiseaseRows(animal),
        pedigreeMother       = buildParentRow("rl_ui_mother", animal.motherId),
        pedigreeFather       = buildParentRow("rl_ui_father", animal.fatherId),
        pedigreeChildren     = buildChildrenRow(animal),
        geneticsRows         = geneticsRows,
        hasMonitor           = hasMonitor,
        inputRows            = hasMonitor and buildInputRows(animal) or {},
        outputRows           = hasMonitor and buildOutputRows(animal) or {},
    }
end

-- =============================================================================
-- Farm balance
-- =============================================================================

--- Return the current player's farm id, or nil if no mission context exists.
--- @return number|nil farmId
function RLAnimalInfoService.getCurrentFarmId()
    if g_currentMission == nil or g_currentMission.getFarmId == nil then
        return nil
    end
    return g_currentMission:getFarmId()
end

--- Return the integer money balance for a farm, or nil if the farm is
--- missing (frame hides the money box on nil).
--- @param farmId number|nil
--- @return number|nil money
function RLAnimalInfoService.getFarmBalance(farmId)
    if farmId == nil or farmId == 0 then return nil end
    if g_farmManager == nil or g_farmManager.getFarmById == nil then return nil end

    local farm = g_farmManager:getFarmById(farmId)
    if farm == nil then
        Log:trace("RLAnimalInfoService.getFarmBalance: no farm for farmId=%s", tostring(farmId))
        return nil
    end

    Log:debug("RLAnimalInfoService.getFarmBalance: farmId=%s money=%s",
        tostring(farmId), tostring(farm.money))
    return farm.money
end

-- =============================================================================
-- Mutations
-- =============================================================================

--- Toggle monitor state. Same code path as AnimalScreen:onClickMonitor.
--- @param animal table
--- @return boolean|nil active  New monitor.active, or nil if animal was nil
--- @return boolean|nil removed New monitor.removed
function RLAnimalInfoService.toggleMonitor(animal)
    if animal == nil then
        Log:trace("RLAnimalInfoService.toggleMonitor: nil animal, skipping")
        return nil, nil
    end

    local monitor = animal.monitor
    if monitor == nil then
        Log:trace("RLAnimalInfoService.toggleMonitor: nil monitor, skipping")
        return nil, nil
    end

    monitor.active = not monitor.active
    monitor.removed = not monitor.active

    if animal.updateVisualMonitor ~= nil then
        animal:updateVisualMonitor()
    end

    local owner = animal.clusterSystem and animal.clusterSystem.owner
    if owner ~= nil then
        AnimalMonitorEvent.sendEvent(owner, animal, monitor.active, monitor.removed)
    else
        Log:trace("RLAnimalInfoService.toggleMonitor: no clusterSystem.owner, event skipped")
    end

    Log:debug("RLAnimalInfoService.toggleMonitor: farmId=%s uniqueId=%s active=%s removed=%s",
        tostring(animal.farmId), tostring(animal.uniqueId),
        tostring(monitor.active), tostring(monitor.removed))
    return monitor.active, monitor.removed
end

--- Rename an animal (or clear its name). Same code path as AnimalScreen:changeName.
--- Empty string is treated as nil (deletes the name).
--- @param animal table
--- @param newName string|nil
function RLAnimalInfoService.renameAnimal(animal, newName)
    if animal == nil then
        Log:trace("RLAnimalInfoService.renameAnimal: nil animal, skipping")
        return
    end

    local text = (newName ~= nil and newName ~= "") and newName or nil

    if text ~= nil or animal.name ~= nil then
        if text == nil then
            animal:addMessage("NAME_DELETED", { animal.name })
        elseif animal.name == nil then
            animal:addMessage("NAME_ADDED", { text })
        elseif animal.name ~= text then
            animal:addMessage("NAME_CHANGE", { animal.name, text })
        end
    end

    animal.name = text

    if animal.updateVisualRightEarTag ~= nil then
        animal:updateVisualRightEarTag()
    end

    local owner = animal.clusterSystem and animal.clusterSystem.owner
    if owner ~= nil then
        AnimalNameChangeEvent.sendEvent(owner, animal, text)
    else
        Log:trace("RLAnimalInfoService.renameAnimal: no clusterSystem.owner, event skipped")
    end

    Log:debug("RLAnimalInfoService.renameAnimal: farmId=%s uniqueId=%s name=%s",
        tostring(animal.farmId), tostring(animal.uniqueId), tostring(text))
end

--- Mark or unmark an animal. Same code path as AnimalScreen:onClickMark.
--- Pass key=nil, active=false to clear all marks (including Herdsman) -- by design.
--- @param animal table
--- @param key string|nil  Mark key ("PLAYER") or nil for clear-all
--- @param active boolean
function RLAnimalInfoService.markAnimal(animal, key, active)
    if animal == nil then
        Log:trace("RLAnimalInfoService.markAnimal: nil animal, skipping")
        return
    end

    animal:setMarked(key, active)

    local owner = animal.clusterSystem and animal.clusterSystem.owner
    if owner ~= nil then
        AnimalMarkEvent.sendEvent(owner, animal, key, active)
    else
        Log:trace("RLAnimalInfoService.markAnimal: no clusterSystem.owner, event skipped")
    end

    Log:debug("RLAnimalInfoService.markAnimal: farmId=%s uniqueId=%s key=%s active=%s",
        tostring(animal.farmId), tostring(animal.uniqueId), tostring(key), tostring(active))
end

--- Castrate an animal and send AnimalCastrateEvent when it belongs to a cluster system with an owner.
--- @param animal table|nil animal to castrate; nil is a no-op
--- @return nil
function RLAnimalInfoService.castrateAnimal(animal)
    if animal == nil then
        Log:trace("RLAnimalInfoService.castrateAnimal: nil animal, skipping")
        return
    end

    animal.isCastrated = true

    local owner = animal.clusterSystem and animal.clusterSystem.owner
    if owner ~= nil then
        AnimalCastrateEvent.sendEvent(owner, animal)
    else
        Log:trace("RLAnimalInfoService.castrateAnimal: no clusterSystem.owner, event skipped")
    end

    Log:debug("RLAnimalInfoService.castrateAnimal: farmId=%s uniqueId=%s",
        tostring(animal.farmId), tostring(animal.uniqueId))
end
