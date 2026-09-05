--[[
    RLAnimalInfoService.lua
    Display and mutation service for the RL Tabbed Menu Info tab.

    Read-only:
      * getHusbandryDisplay(husbandry, farmId) -> pen column payload
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

--- Build disease rows for read-only display. Uses disease.type.name which
--- is already localized by DiseaseManager. Empty list when the animal has
--- no diseases.
---
--- Gated on `diseasesEnabled` like the card icons and the HUD box: with diseases off a
--- frozen record must not render here either, or the pane claims an animal is sick while
--- every other surface says otherwise.
---
--- The nil-manager arm is this gate's own, not shared: `Disease:modifyOutput` and the HUD box
--- both dereference `g_diseaseManager.diseasesEnabled` bare, so the parity above is about the
--- SETTING and not about a nil manager. That state has one producer - a parse raise leaving the
--- global nil for the session - and it already takes the mission down, so this is cheap
--- symmetry with the other gates in this slice rather than a claim the tree is nil-safe.
--- @param animal table
--- @return table rows
local function buildDiseaseRows(animal)
    local rows = {}
    if g_diseaseManager == nil or not g_diseaseManager.diseasesEnabled then
        Log:trace("RLAnimalInfoService.buildDiseaseRows: no rows, reason=diseases disabled")
        return rows
    end
    if animal == nil or type(animal.diseases) ~= "table" then return rows end
    for _, disease in ipairs(animal.diseases) do
        if disease ~= nil and disease.type ~= nil then
            local status = ""
            if disease.getStatus ~= nil then
                local ok, statusText = pcall(function() return disease:getStatus() end)
                if ok and statusText ~= nil then status = statusText end
            end
            table.insert(rows, {
                name   = disease.type.name or "",
                status = status,
            })
        end
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
        local valueText = string.format(g_i18n:getText("rl_ui_amountPerDay"), (amount * 24) / daysPerMonth)
        table.insert(rows, { title = title, valueText = valueText })
    end
    return rows
end

--- Build output rows for monitored animals. Maps "pallets" fillType to
--- species-specific l10n key (pallets_milk, pallets_wool, etc.).
--- @param animal table
--- @return table rows
local function buildOutputRows(animal)
    local rows = {}
    if animal == nil or type(animal.output) ~= "table" then return rows end
    local daysPerMonth = g_currentMission.environment.daysPerPeriod
    for fillType, amount in pairs(animal.output) do
        local outputText = fillType
        if fillType == "pallets" then
            if animal.animalTypeIndex == AnimalType.COW then outputText = "pallets_milk" end
            if animal.animalTypeIndex == AnimalType.SHEEP then
                outputText = (animal.subType == "GOAT") and "pallets_goatMilk" or "pallets_wool"
            end
            if animal.animalTypeIndex == AnimalType.CHICKEN then outputText = "pallets_eggs" end
        end
        local title = g_i18n:getText("rl_ui_output_" .. outputText)
        local valueText = string.format(g_i18n:getText("rl_ui_amountPerDay"), (amount * 24) / daysPerMonth)
        table.insert(rows, { title = title, valueText = valueText })
    end
    return rows
end

-- Reproduce eligibility comes from statRows via getAnimalInfos; not duplicated here.

-- =============================================================================
-- Husbandry display
-- =============================================================================

--- Build the pen-column payload for a husbandry.
---
--- Returns:
---   {
---     name              = string,              -- pen display name
---     countText         = string,              -- "current/max", or "current" if max unknown
---     penImageFilename  = string|nil,          -- nil -> frame hides icon
---     conditionInfos    = table (passed through from husbandry:getConditionInfos),
---     foodInfos         = table (passed through from husbandry:getFoodInfos),
---     foodTotalValue    = number,              -- sum of food values (non-ignoreCapacity only)
---     foodTotalCapacity = number,
---     foodTotalRatio    = number,
---   }
---
--- conditionInfos / foodInfos are pure pass-throughs (RL does not override
--- those husbandry methods); this builder adds the name/count composition and
--- food-total summation.
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

    -- Sum food values, skipping ignoreCapacity entries; capacity tracks the
    -- largest of the per-entry capacities. foodTotalRatio drives the pen-fill
    -- bar in the Info frame.
    local foodTotalValue = 0
    local foodTotalCapacity = 0
    for _, info in ipairs(foodInfos) do
        if not info.ignoreCapacity then
            foodTotalCapacity = math.max(info.capacity or 0, foodTotalCapacity)
            foodTotalValue = foodTotalValue + (info.value or 0)
        end
    end
    local foodTotalRatio = (foodTotalCapacity > 0) and (foodTotalValue / foodTotalCapacity) or 0

    local foodMonthsRemaining
    if RLPenFeedForecast ~= nil and RLPenFeedForecast.getMonthsRemaining ~= nil then
        foodMonthsRemaining = RLPenFeedForecast.getMonthsRemaining(husbandry, foodTotalValue)
    end

    -- Real-days runway drives the low-feed colour alert (daysPerPeriod-stable);
    -- foodMonthsRemaining above still drives the at-a-glance months range label.
    local foodDaysRemaining
    if RLPenFeedForecast ~= nil and RLPenFeedForecast.getDaysRemaining ~= nil then
        foodDaysRemaining = RLPenFeedForecast.getDaysRemaining(husbandry, foodTotalValue)
    end

    Log:debug("RLAnimalInfoService.getHusbandryDisplay: farmId=%s husbandry='%s' count=%s",
        tostring(farmId), name, countText)

    return {
        name                = name,
        countText           = countText,
        penImageFilename    = penImageFilename,
        conditionInfos      = conditionInfos,
        foodInfos           = foodInfos,
        foodTotalValue      = foodTotalValue,
        foodTotalCapacity   = foodTotalCapacity,
        foodTotalRatio      = foodTotalRatio,
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

    -- Per-animal stat rows from husbandry:getAnimalInfos. Row shape:
    -- { {title, valueText, ratio, invertedBar, disabled}, ... }. Variable
    -- length depending on monitor state, gender, husbandry capability.
    -- Walks Animal:addInfos which RL extends with Health, Weight, Target
    -- Weight, Reproduction, Pregnant, Expecting, Expected, Lactating,
    -- Can Reproduce, etc.
    local statRows = {}
    if husbandry ~= nil and husbandry.getAnimalInfos ~= nil then
        local ok, result = pcall(function() return husbandry:getAnimalInfos(animal) end)
        if ok and type(result) == "table" then statRows = result end
    elseif animal.addInfos ~= nil then
        -- Nil-husbandry fallback for the Buy tab (dealer animals have no source
        -- husbandry). Animal:addInfos mutates the table with animal-intrinsic
        -- rows (health, weight, reproduction, etc.) that do not need a
        -- husbandry context. Pass `forceShowAll=true` so monitor-gated rows
        -- (Health, Weight, Lactation) are included - dealer animals carry no
        -- monitor but players need full visibility at purchase time.
        -- pcall-guarded because some Animal:addInfos branches reference
        -- self.clusterSystem which may be nil on a fresh sale animal;
        -- degrading to age-only is acceptable.
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
        geneticsRows = RLGeneticsFormatter.format(animal.genetics, animal.animalTypeIndex, animal.subType)
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

--- Castrate an animal. Same code path as AnimalScreen:onClickCastrate.
--- @param animal table
function RLAnimalInfoService.castrateAnimal(animal)
    if animal == nil then
        Log:trace("RLAnimalInfoService.castrateAnimal: nil animal, skipping")
        return
    end

    animal.isCastrated = true
    animal.genetics.fertility = 0

    local owner = animal.clusterSystem and animal.clusterSystem.owner
    if owner ~= nil then
        AnimalCastrateEvent.sendEvent(owner, animal)
    else
        Log:trace("RLAnimalInfoService.castrateAnimal: no clusterSystem.owner, event skipped")
    end

    Log:debug("RLAnimalInfoService.castrateAnimal: farmId=%s uniqueId=%s",
        tostring(animal.farmId), tostring(animal.uniqueId))
end
