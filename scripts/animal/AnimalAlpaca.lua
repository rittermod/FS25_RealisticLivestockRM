--[[
    AnimalAlpaca.lua
    Alpaca behaviour, reached through the ALPACA entry of RLAnimalTypeModules: the name at creation, and for an
    alpaca whose subtype carries fleece data, happiness and fleece (the daily step, the price and health effects,
    the info, HUD and dealer rows, the save), the animal worker's shearing and leading answers and the leash's
    answers. Without fleece data every hook keeps the base behaviour.
    RLAnimalTypeModules reads this module at its first lookup, never at file scope.
]]

AnimalAlpaca = {}

local Log = RmLogging.getLogger("RLRM")

--- Happiness lost per period; a day takes this times the environment's timeAdjustment.
AnimalAlpaca.HAPPINESS_DECAY_PER_PERIOD = 10
--- A stepped fleece value this close to a whole number becomes it, so the save and the stream agree on 40.
AnimalAlpaca.FLEECE_SNAP_EPSILON = 1e-3


--- Clamp a 0-100 value; a bound is returned as the literal, never a signed zero.
--- @param value number
--- @return number clamped
local function clampPercent(value)
    if value <= 0 then return 0 end
    if value >= 100 then return 100 end
    return value
end


--- Whether the animal's current visual sets the named flag; false when it has no visual.
--- @param animal table Animal instance
--- @param flag string visual field name
--- @return boolean set
local function visualFlag(animal, flag)
    local visual = animal:getVisual()
    local set = visual ~= nil and visual[flag] == true
    Log:trace("AnimalAlpaca: farmId=%s uniqueId=%s visual %s=%s", tostring(animal.farmId), tostring(animal.uniqueId),
        flag, visual ~= nil and tostring(visual[flag]) or "(no visual)")
    return set
end


--- A text from the DLC's own l10n; a DLC's keys live in its mod text environment.
--- @param key string l10n key
--- @return string text
local function getDlcText(key)
    local modName = g_uniqueDlcNamePrefix .. RLAnimalTypeSupport.DLC_BUNDLES[1].dlc
    local text = g_i18n:getText(key, modName)
    Log:trace("AnimalAlpaca: text %s from %s -> %s", key, modName, tostring(text))
    return text
end


--- Whether this machine runs the daily step; the seam a suite swaps to model a client.
--- @return boolean isServer
function AnimalAlpaca.isServer()
    return g_server ~= nil
end


--- Whether the animal carries alpaca happiness and fleece: its subtype has the DLC's fleece regrowth.
--- @param animal table Animal instance
--- @return boolean hasState
function AnimalAlpaca.hasState(animal)
    local subType = animal:getSubType()
    local hasState = subType ~= nil and subType.fleeceRegrowthPerDay ~= nil
    Log:trace("AnimalAlpaca.hasState: farmId=%s uniqueId=%s subType=%s -> %s", tostring(animal.farmId),
        tostring(animal.uniqueId), tostring(animal.subType), tostring(hasState))
    return hasState
end


--- One day of happiness and fleece: happiness falls first, then fleece grows from the lowered happiness.
--- @param happiness number stored happiness, 0-100
--- @param fleece number stored fleece state, 0-100
--- @param regrowthPerDay number the subtype's fleece regrowth per period
--- @param timeAdjustment number the environment's timeAdjustment (1 / daysPerPeriod)
--- @return number happiness the new happiness, 0-100
--- @return number fleece the new fleece state, 0-100
function AnimalAlpaca.stepDay(happiness, fleece, regrowthPerDay, timeAdjustment)
    local newHappiness = clampPercent(happiness + (-AnimalAlpaca.HAPPINESS_DECAY_PER_PERIOD * timeAdjustment))
    local newFleece = clampPercent(fleece + regrowthPerDay * timeAdjustment * (0.5 + 0.5 * (newHappiness / 100)))

    local whole = math.floor(newFleece + 0.5)
    if whole ~= newFleece and math.abs(newFleece - whole) <= AnimalAlpaca.FLEECE_SNAP_EPSILON then
        Log:trace("AnimalAlpaca.stepDay: fleece %.17g snapped to %d", newFleece, whole)
        newFleece = whole
    end

    Log:trace("AnimalAlpaca.stepDay: happiness %s -> %s, fleece %s -> %s (regrowth=%s timeAdjustment=%s)",
        tostring(happiness), tostring(newHappiness), tostring(fleece), tostring(newFleece), tostring(regrowthPerDay),
        tostring(timeAdjustment))
    return newHappiness, newFleece
end


--- A 0-100 value as a whole percent, rounded down; never a negative zero.
--- @param value number 0-100
--- @return number whole
function AnimalAlpaca.wholePercent(value)
    local whole = math.floor(value)
    if whole <= 0 then return 0 end
    return whole
end


--- The ALPACA daily hook: one day of happiness and fleece, on the server, flagging the pen before the writes.
--- @param animal table Animal instance (ALPACA type); the sale guard has already skipped pool animals
function AnimalAlpaca.onDayChanged(animal)
    if not AnimalAlpaca.hasState(animal) then
        Log:trace("AnimalAlpaca.onDayChanged: farmId=%s uniqueId=%s no fleece data, no step", tostring(animal.farmId),
            tostring(animal.uniqueId))
        return
    end
    if not AnimalAlpaca.isServer() then
        Log:trace("AnimalAlpaca.onDayChanged: farmId=%s uniqueId=%s not the server, no step", tostring(animal.farmId),
            tostring(animal.uniqueId))
        return
    end

    local timeAdjustment = g_currentMission.environment.timeAdjustment
    local happiness, fleece = AnimalAlpaca.stepDay(animal.happiness, animal.fleeceState,
        animal:getSubType().fleeceRegrowthPerDay, timeAdjustment)

    if happiness == animal.happiness and fleece == animal.fleeceState then
        Log:trace("AnimalAlpaca.onDayChanged: farmId=%s uniqueId=%s nothing moved", tostring(animal.farmId),
            tostring(animal.uniqueId))
        return
    end

    local happinessBefore, fleeceBefore = animal.happiness, animal.fleeceState
    -- The flag leads the writes, so a raise in a write still leaves the pen flagged for its flush.
    animal:setDirty()
    animal.happiness = happiness
    animal.fleeceState = fleece
    Log:debug("AnimalAlpaca.onDayChanged: farmId=%s uniqueId=%s happiness %s -> %s, fleece %s -> %s",
        tostring(animal.farmId), tostring(animal.uniqueId), tostring(happinessBefore), tostring(happiness),
        tostring(fleeceBefore), tostring(fleece))
end


--- Happiness as a 0-1 factor.
--- @param animal table Animal instance
--- @return number factor
function AnimalAlpaca.getHappinessFactor(animal)
    return animal.happiness / 100
end


--- Change happiness by a delta, clamped to 0-100, never floored; flags the animal before a moving write.
--- @param animal table Animal instance
--- @param delta number points to add
function AnimalAlpaca.changeHappiness(animal, delta)
    local before = animal.happiness
    local after = clampPercent(before + delta)
    if after == before then
        Log:trace("AnimalAlpaca.changeHappiness: farmId=%s uniqueId=%s delta=%s, no change at %s",
            tostring(animal.farmId), tostring(animal.uniqueId), tostring(delta), tostring(before))
        return
    end
    animal:setDirty()
    animal.happiness = after
    Log:trace("AnimalAlpaca.changeHappiness: farmId=%s uniqueId=%s %s -> %s", tostring(animal.farmId),
        tostring(animal.uniqueId), tostring(before), tostring(after))
end


--- The stored fleece state, 0-100.
--- @param animal table Animal instance
--- @return number fleeceState
function AnimalAlpaca.getFleeceState(animal)
    return animal.fleeceState
end


--- Change the fleece state by a delta, clamped to 0-100, never floored; flags the animal before a moving write.
--- @param animal table Animal instance
--- @param delta number points to add
function AnimalAlpaca.changeFleeceState(animal, delta)
    local before = animal.fleeceState
    local after = clampPercent(before + delta)
    if after == before then
        Log:trace("AnimalAlpaca.changeFleeceState: farmId=%s uniqueId=%s delta=%s, no change at %s",
            tostring(animal.farmId), tostring(animal.uniqueId), tostring(delta), tostring(before))
        return
    end
    animal:setDirty()
    animal.fleeceState = after
    Log:debug("AnimalAlpaca.changeFleeceState: farmId=%s uniqueId=%s %s -> %s", tostring(animal.farmId),
        tostring(animal.uniqueId), tostring(before), tostring(after))
end


--- The subtype's daily hiking time in milliseconds, or nil when it has none.
--- @param animal table Animal instance
--- @return number|nil dailyHikingTime
function AnimalAlpaca.getDailyHikingTime(animal)
    local subType = animal:getSubType()
    return subType ~= nil and subType.dailyHikingTime or nil
end


-- =============================================================================
-- LEADING (the leash and the led alpaca)
-- =============================================================================

--- Whether the leash may lead this alpaca: its current visual can be led.
--- @param animal table Animal instance
--- @return boolean canBeLed
function AnimalAlpaca.getCanBeLed(animal)
    if not AnimalAlpaca.hasState(animal) then
        Log:trace("AnimalAlpaca.getCanBeLed: farmId=%s uniqueId=%s no fleece data -> false", tostring(animal.farmId),
            tostring(animal.uniqueId))
        return false
    end
    return visualFlag(animal, "canBeLed")
end


--- The led-alpaca vehicle file for this alpaca's subtype, or nil when it has none.
--- @param animal table Animal instance
--- @return string|nil filename
function AnimalAlpaca.getLeashableFilename(animal)
    if not AnimalAlpaca.hasState(animal) then
        Log:trace("AnimalAlpaca.getLeashableFilename: farmId=%s uniqueId=%s no fleece data -> nil",
            tostring(animal.farmId), tostring(animal.uniqueId))
        return nil
    end
    local filename = animal:getSubType().leadingFilename
    Log:trace("AnimalAlpaca.getLeashableFilename: farmId=%s uniqueId=%s -> %s", tostring(animal.farmId),
        tostring(animal.uniqueId), tostring(filename))
    return filename
end


--- The walking time, in milliseconds, that earns one happiness point: the daily hiking time over 100, else 0.
--- @param animal table Animal instance
--- @return number timePerPoint 0 without hiking data
function AnimalAlpaca.getHikingTimePerHappinessPoint(animal)
    if not AnimalAlpaca.hasState(animal) then
        Log:trace("AnimalAlpaca.getHikingTimePerHappinessPoint: farmId=%s uniqueId=%s no fleece data -> 0",
            tostring(animal.farmId), tostring(animal.uniqueId))
        return 0
    end
    local hikingTime = animal:getDailyHikingTime()
    if hikingTime == nil or not (hikingTime > 0) then
        Log:trace("AnimalAlpaca.getHikingTimePerHappinessPoint: farmId=%s uniqueId=%s hiking time %s -> 0",
            tostring(animal.farmId), tostring(animal.uniqueId), tostring(hikingTime))
        return 0
    end
    local timePerPoint = hikingTime / 100
    Log:trace("AnimalAlpaca.getHikingTimePerHappinessPoint: farmId=%s uniqueId=%s hiking time %s -> %s",
        tostring(animal.farmId), tostring(animal.uniqueId), tostring(hikingTime), tostring(timePerPoint))
    return timePerPoint
end


-- =============================================================================
-- ANIMAL WORKER (the shearing and leading tasks)
-- =============================================================================

--- Whether the shearing task can shear this alpaca at all: its visual supports shearing.
--- @param animal table Animal instance
--- @return boolean supported
function AnimalAlpaca.getSupportsShearing(animal)
    if not AnimalAlpaca.hasState(animal) then
        Log:trace("AnimalAlpaca.getSupportsShearing: farmId=%s uniqueId=%s no fleece data -> false",
            tostring(animal.farmId), tostring(animal.uniqueId))
        return false
    end
    return visualFlag(animal, "supportsShearing")
end


--- Whether the shearing task has work on this alpaca: its visual is the woolly one.
--- @param animal table Animal instance
--- @return boolean canBeSheared
function AnimalAlpaca.getCanBeSheared(animal)
    if not AnimalAlpaca.hasState(animal) then
        Log:trace("AnimalAlpaca.getCanBeSheared: farmId=%s uniqueId=%s no fleece data -> false",
            tostring(animal.farmId), tostring(animal.uniqueId))
        return false
    end
    return visualFlag(animal, "canBeSheared")
end


--- The fleece a shearing yields: the subtype's amount for the age, times fleece / 100, times productivity.
--- @param animal table Animal instance
--- @return number amount litres, 0 without fleece data
function AnimalAlpaca.getFleeceAmount(animal)
    if not AnimalAlpaca.hasState(animal) then
        Log:trace("AnimalAlpaca.getFleeceAmount: farmId=%s uniqueId=%s no fleece data -> 0", tostring(animal.farmId),
            tostring(animal.uniqueId))
        return 0
    end
    local subType = animal:getSubType()
    local forAge = subType.maxFleeceForAge or 0
    if subType.fleeceAmountCurve ~= nil then
        forAge = subType.fleeceAmountCurve:get(animal:getAge())
    end
    local productivity = animal.genetics ~= nil and animal.genetics.productivity or 1
    local amount = animal.fleeceState / 100 * forAge * productivity
    Log:trace("AnimalAlpaca.getFleeceAmount: farmId=%s uniqueId=%s forAge=%s fleece=%s productivity=%s -> %s",
        tostring(animal.farmId), tostring(animal.uniqueId), tostring(forAge), tostring(animal.fleeceState),
        tostring(productivity), tostring(amount))
    return amount
end


--- Set the fleece state, clamped to 0-100, never floored; flags the animal before a moving write.
--- @param animal table Animal instance
--- @param state number the new fleece state
function AnimalAlpaca.setFleeceState(animal, state)
    if not AnimalAlpaca.hasState(animal) then
        Log:trace("AnimalAlpaca.setFleeceState: farmId=%s uniqueId=%s no fleece data, nothing written",
            tostring(animal.farmId), tostring(animal.uniqueId))
        return
    end
    local before = animal.fleeceState
    local after = clampPercent(state)
    if after == before then
        Log:trace("AnimalAlpaca.setFleeceState: farmId=%s uniqueId=%s already %s", tostring(animal.farmId),
            tostring(animal.uniqueId), tostring(before))
        return
    end
    -- The flag leads the write. Accepted trade: a raise in setDirty (a nil owner or another mod's override) writes
    -- nothing and ends the worker's run before it bills or adds the fleece, so alpacas already sheared lose theirs.
    animal:setDirty()
    animal.fleeceState = after
    Log:debug("AnimalAlpaca.setFleeceState: farmId=%s uniqueId=%s fleece %s -> %s", tostring(animal.farmId),
        tostring(animal.uniqueId), tostring(before), tostring(after))
end


--- Whether the leading task can lead this alpaca: its visual can be led.
--- @param animal table Animal instance
--- @return boolean supported
function AnimalAlpaca.getSupportsExercise(animal)
    if not AnimalAlpaca.hasState(animal) then
        Log:trace("AnimalAlpaca.getSupportsExercise: farmId=%s uniqueId=%s no fleece data -> false",
            tostring(animal.farmId), tostring(animal.uniqueId))
        return false
    end
    return visualFlag(animal, "canBeLed")
end


--- Whether the leading task has work on this alpaca: supported and happiness below 100.
--- @param animal table Animal instance
--- @return boolean needed
function AnimalAlpaca.getNeedsExercise(animal)
    local needed = animal:getSupportsExercise() and animal.happiness < 100
    Log:trace("AnimalAlpaca.getNeedsExercise: farmId=%s uniqueId=%s happiness=%s -> %s", tostring(animal.farmId),
        tostring(animal.uniqueId), tostring(animal.happiness), tostring(needed))
    return needed
end


--- Lead the alpaca for the leading task: happiness to 100 when needed.
--- @param animal table Animal instance
--- @return boolean applied true when the alpaca was led
function AnimalAlpaca.applyExercise(animal)
    if not animal:getNeedsExercise() then
        Log:trace("AnimalAlpaca.applyExercise: farmId=%s uniqueId=%s not needed", tostring(animal.farmId),
            tostring(animal.uniqueId))
        return false
    end
    local before = animal.happiness
    -- The flag leads the write. Accepted trade: a raise in setDirty (a nil owner or another mod's override) writes
    -- nothing and ends the worker's run before it bills, so the alpacas that run already led go unbilled.
    animal:setDirty()
    animal.happiness = 100
    Log:debug("AnimalAlpaca.applyExercise: farmId=%s uniqueId=%s happiness %s -> 100", tostring(animal.farmId),
        tostring(animal.uniqueId), tostring(before))
    return true
end


--- The ALPACA price hook: health and happiness weigh the price; nil keeps the base formula without fleece data.
--- @param animal table Animal instance (ALPACA type)
--- @param sellPrice number base sell price after the genetics and disease adjustments
--- @param meatFactor number meat quality genetics factor
--- @param weightFactor number weight deviation factor
--- @return number|nil price
function AnimalAlpaca.getSellPrice(animal, sellPrice, meatFactor, weightFactor)
    if not AnimalAlpaca.hasState(animal) then
        Log:trace("AnimalAlpaca.getSellPrice: farmId=%s uniqueId=%s no fleece data, base price",
            tostring(animal.farmId), tostring(animal.uniqueId))
        return nil
    end
    local price = math.max(
        sellPrice * meatFactor * weightFactor
            * (0.3 + 0.5 * animal:getHealthFactor() + 0.2 * animal:getHappinessFactor()),
        sellPrice * 0.05)
    Log:trace("AnimalAlpaca.getSellPrice: farmId=%s uniqueId=%s base=%.1f meat=%.2f weight=%.2f -> %.1f",
        tostring(animal.farmId), tostring(animal.uniqueId), sellPrice, meatFactor, weightFactor, price)
    return price
end


--- The ALPACA health hook: the hourly health change follows 0.6 food + 0.4 happiness; nil keeps the raw food factor.
--- @param animal table Animal instance (ALPACA type)
--- @param foodFactor number the pen's food factor, 0-1
--- @return number|nil factor
function AnimalAlpaca.getHealthFoodFactor(animal, foodFactor)
    if not AnimalAlpaca.hasState(animal) then
        Log:trace("AnimalAlpaca.getHealthFoodFactor: farmId=%s uniqueId=%s no fleece data, raw food factor",
            tostring(animal.farmId), tostring(animal.uniqueId))
        return nil
    end
    local factor = 0.6 * foodFactor + 0.4 * animal:getHappinessFactor()
    Log:trace("AnimalAlpaca.getHealthFoodFactor: farmId=%s uniqueId=%s food=%s -> %s", tostring(animal.farmId),
        tostring(animal.uniqueId), tostring(foodFactor), tostring(factor))
    return factor
end


--- Add the happiness and fleece rows to the info panel.
--- @param animal table Animal instance (ALPACA type)
--- @param infos table info rows, appended in place
function AnimalAlpaca.addInfos(animal, infos)
    if not AnimalAlpaca.hasState(animal) then
        Log:trace("AnimalAlpaca.addInfos: farmId=%s uniqueId=%s no fleece data, no rows", tostring(animal.farmId),
            tostring(animal.uniqueId))
        return
    end

    if animal.infoHappiness == nil then
        animal.infoHappiness = { text = "", title = getDlcText("ui_alpacaHappiness") }
    end
    local happiness = animal:getHappinessFactor()
    animal.infoHappiness.value = happiness
    animal.infoHappiness.ratio = happiness
    animal.infoHappiness.valueText = string.format("%d %%", AnimalAlpaca.wholePercent(animal.happiness))
    table.insert(infos, animal.infoHappiness)

    if animal.infoFleece == nil then
        animal.infoFleece = { text = "", title = getDlcText("ui_alpacaFleece") }
    end
    local fleece = animal:getFleeceState() / 100
    animal.infoFleece.value = fleece
    animal.infoFleece.ratio = fleece
    animal.infoFleece.valueText = string.format("%d %%", AnimalAlpaca.wholePercent(animal.fleeceState))
    table.insert(infos, animal.infoFleece)

    Log:trace("AnimalAlpaca.addInfos: farmId=%s uniqueId=%s happiness=%s fleece=%s", tostring(animal.farmId),
        tostring(animal.uniqueId), animal.infoHappiness.valueText, animal.infoFleece.valueText)
end


--- Add the happiness and fleece lines to a HUD info box.
--- @param animal table Animal instance (ALPACA type)
--- @param box table HUD info box (addLine)
function AnimalAlpaca.showHudInfo(animal, box)
    if not AnimalAlpaca.hasState(animal) then
        Log:trace("AnimalAlpaca.showHudInfo: farmId=%s uniqueId=%s no fleece data, no lines", tostring(animal.farmId),
            tostring(animal.uniqueId))
        return
    end
    box:addLine(getDlcText("ui_alpacaHappiness"),
        string.format("%d%%", AnimalAlpaca.wholePercent(animal.happiness)))
    box:addLine(getDlcText("ui_alpacaFleece"), string.format("%d%%", AnimalAlpaca.wholePercent(animal.fleeceState)))
    Log:trace("AnimalAlpaca.showHudInfo: farmId=%s uniqueId=%s two lines", tostring(animal.farmId),
        tostring(animal.uniqueId))
end


--- Add the happiness and fleece rows to a dealer item stock's info list.
--- @param animal table Animal instance (ALPACA type)
--- @param infos table the item stock's info rows, appended in place
function AnimalAlpaca.addDealerInfos(animal, infos)
    if not AnimalAlpaca.hasState(animal) then
        Log:trace("AnimalAlpaca.addDealerInfos: farmId=%s uniqueId=%s no fleece data, no rows",
            tostring(animal.farmId), tostring(animal.uniqueId))
        return
    end
    table.insert(infos, { ["title"] = getDlcText("ui_alpacaHappiness"),
        ["value"] = string.format("%d%%", AnimalAlpaca.wholePercent(animal.happiness)) })
    table.insert(infos, { ["title"] = getDlcText("ui_alpacaFleece"),
        ["value"] = string.format("%d%%", AnimalAlpaca.wholePercent(animal.fleeceState)) })
    Log:trace("AnimalAlpaca.addDealerInfos: farmId=%s uniqueId=%s two rows", tostring(animal.farmId),
        tostring(animal.uniqueId))
end


--- Save happiness and fleece as #happiness / #fleeceState floats.
--- @param animal table Animal instance (ALPACA type)
--- @param xmlFile table XML file handle
--- @param key string XML key path for this animal
function AnimalAlpaca.saveFields(animal, xmlFile, key)
    if not AnimalAlpaca.hasState(animal) then
        Log:trace("AnimalAlpaca.saveFields: farmId=%s uniqueId=%s no fleece data, nothing saved",
            tostring(animal.farmId), tostring(animal.uniqueId))
        return
    end
    xmlFile:setFloat(key .. "#happiness", animal.happiness)
    xmlFile:setFloat(key .. "#fleeceState", animal.fleeceState)
    Log:trace("AnimalAlpaca.saveFields: farmId=%s uniqueId=%s happiness=%s fleeceState=%s", tostring(animal.farmId),
        tostring(animal.uniqueId), tostring(animal.happiness), tostring(animal.fleeceState))
end


--- A random default name for a new alpaca; runs mid-constructor, with no birthday yet.
--- @param animal table Animal instance (ALPACA type) under construction
--- @return string|nil name
function AnimalAlpaca.getDefaultName(animal)
    local name = g_currentMission.animalNameSystem:getRandomName(animal.gender)
    Log:trace("AnimalAlpaca.getDefaultName: farmId=%s uniqueId=%s gender=%s -> %s",
        tostring(animal.farmId), tostring(animal.uniqueId), tostring(animal.gender), tostring(name))
    return name
end
