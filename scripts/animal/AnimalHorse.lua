--[[
    AnimalHorse.lua
    Horse riding, fitness, dirt, sell price, info display, HUD display and XML
    save. Animal.lua holds one-liner delegates that route here, and must be
    sourced AFTER this module.

    Serialization and XML load stay in Animal.lua: dirt/fitness/riding are
    initialized in the constructor and serialized unconditionally for ALL animal
    types, so they are part of the MP protocol and must not change without a
    protocol version bump.
]]

AnimalHorse = {}

local Log = RmLogging.getLogger("RLRM")


-- =============================================================================
-- PURE HORSE METHODS (delegated from Animal prototype)
-- =============================================================================

--- Calculate health change factor for horses, incorporating fitness and optionally dirt.
--- @param animal table Animal instance
--- @param foodFactor number Food factor (0.0-1.0)
--- @return number healthChangeFactor Weighted factor combining food, fitness, and dirt
-- NOTE: Currently unused - defined but no callers found. Candidate for removal.
function AnimalHorse.getHealthChangeFactor(animal, foodFactor)
    local fitnessFactor = AnimalHorse.getFitnessFactor(animal)

    if not Platform.gameplay.needHorseCleaning then
        return 0.6 * foodFactor + 0.4 * fitnessFactor
    end

    local dirtFactor = 1 - AnimalHorse.getDirtFactor(animal)
    return 0.5 * foodFactor + 0.4 * fitnessFactor + 0.1 * dirtFactor
end

--- Get fitness as a 0-1 factor.
--- @param animal table Animal instance
--- @return number fitness Factor (0.0-1.0)
function AnimalHorse.getFitnessFactor(animal)
    return animal.fitness / 100
end

--- Change fitness by delta, clamped to 0-100 and floored.
--- @param animal table Animal instance
--- @param delta number Amount to change fitness by
function AnimalHorse.changeFitness(animal, delta)
    animal.fitness = math.clamp(math.floor(animal.fitness + delta), 0, 100)
end

--- Get riding progress as a 0-1 factor.
--- @param animal table Animal instance
--- @return number riding Factor (0.0-1.0)
function AnimalHorse.getRidingFactor(animal)
    return animal.riding / 100
end

--- Set riding to an absolute value.
--- @param animal table Animal instance
--- @param riding number New riding value
function AnimalHorse.setRiding(animal, riding)
    animal.riding = math.clamp(math.floor(riding), 0, 100)
end

--- Reset riding to zero.
--- @param animal table Animal instance
function AnimalHorse.resetRiding(animal)
    animal.riding = 0
end

--- Change riding by delta, clamped to 0-100 and floored.
--- @param animal table Animal instance
--- @param delta number Amount to change riding by
function AnimalHorse.changeRiding(animal, delta)
    animal.riding = math.clamp(math.floor(animal.riding + delta), 0, 100)
end

--- Get dirt as a 0-1 factor.
--- @param animal table Animal instance
--- @return number dirt Factor (0.0-1.0)
function AnimalHorse.getDirtFactor(animal)
    return animal.dirt / 100
end

--- Change dirt by delta, clamped to 0-100 and floored.
--- @param animal table Animal instance
--- @param delta number Amount to change dirt by
function AnimalHorse.changeDirt(animal, delta)
    animal.dirt = math.clamp(math.floor(animal.dirt + delta), 0, 100)
end

--- Get the daily riding time constant (milliseconds).
--- @param animal table Animal instance
--- @return number ridingTime Daily riding time in milliseconds
function AnimalHorse.getDailyRidingTime(animal)
    return 300000
end

-- =============================================================================
-- EXTRACTED CONDITIONAL BLOCKS
-- =============================================================================

--- Process riding update during onDayChanged. Updates fitness based on riding
--- relative to threshold, resets riding, and increases dirt.
--- Called from Animal:onDayChanged when animal is HORSE and not a sale animal.
--- @param animal table Animal instance (HORSE type)
function AnimalHorse.processRidingUpdate(animal)
    local ridingFactor = AnimalHorse.getRidingFactor(animal)
    local ridingThresholdFactor = animal:getSubType().ridingThresholdFactor
    local factor, delta

    Log:trace("AnimalHorse.processRidingUpdate: riding=%.2f threshold=%.2f",
        ridingFactor, ridingThresholdFactor)

    if ridingThresholdFactor <= 0 then
        -- No threshold: skip fitness adjustment (avoids 0/0 division)
        factor = 0
        delta = 0
    elseif ridingThresholdFactor >= 1.0 then
        -- Threshold at/above max: use below-threshold formula (safe when denominator >= 1)
        factor = ridingFactor / ridingThresholdFactor - 1
        delta = 10
    elseif ridingThresholdFactor < ridingFactor then
        factor = (ridingFactor - ridingThresholdFactor) / (1 - ridingThresholdFactor)
        delta = 25
    else
        factor = ridingFactor / ridingThresholdFactor - 1
        delta = 10
    end

    Log:trace("  fitness delta=%.2f (base=%d factor=%.3f timeAdj=%.3f)",
        delta * factor * g_currentMission.environment.timeAdjustment,
        delta, factor, g_currentMission.environment.timeAdjustment)

    AnimalHorse.changeFitness(animal, delta * factor * g_currentMission.environment.timeAdjustment)
    AnimalHorse.resetRiding(animal)
    AnimalHorse.changeDirt(animal, 10)
end

--- Calculate horse-specific sell price.
--- Horses use a combined factor of health, riding, fitness, and dirt instead
--- of the standard livestock formula.
--- @param animal table Animal instance (HORSE type)
--- @param sellPrice number Base sell price after genetics/disease adjustments
--- @param meatFactor number Meat quality genetics factor
--- @param weightFactor number Weight deviation factor
--- @return number finalPrice Horse sell price (minimum 5% of base)
function AnimalHorse.getHorseSellPrice(animal, sellPrice, meatFactor, weightFactor)
    local price = math.max(
        sellPrice * meatFactor * weightFactor * (
            0.3
            + 0.5 * animal:getHealthFactor()
            + 0.3 * AnimalHorse.getRidingFactor(animal)
            + 0.2 * AnimalHorse.getFitnessFactor(animal)
            - 0.2 * AnimalHorse.getDirtFactor(animal)
        ),
        sellPrice * 0.05
    )
    Log:trace("AnimalHorse.getHorseSellPrice: base=%.1f meat=%.2f weight=%.2f -> %.1f",
        sellPrice, meatFactor, weightFactor, price)
    return price
end

--- Add horse-specific info rows (fitness, riding, cleanliness) to the info panel.
--- Called from Animal:updateInfos when animal is HORSE type.
--- @param animal table Animal instance (HORSE type)
--- @param infos table Info rows array to append to
function AnimalHorse.addHorseInfos(animal, infos)
    if animal.infoFitness == nil then
        animal.infoFitness = {
            text = "",
            title = g_i18n:getText("ui_horseFitness")
        }
    end

    local fitness = AnimalHorse.getFitnessFactor(animal)
    animal.infoFitness.value = fitness
    animal.infoFitness.ratio = fitness
    animal.infoFitness.valueText = string.format("%d %%", g_i18n:formatNumber(fitness * 100, 0))
    table.insert(infos, animal.infoFitness)

    if animal.infoRiding == nil then
        animal.infoRiding = {
            text = "",
            title = g_i18n:getText("ui_horseDailyRiding")
        }
    end

    local riding = AnimalHorse.getRidingFactor(animal)
    animal.infoRiding.value = riding
    animal.infoRiding.ratio = riding
    animal.infoRiding.valueText = string.format("%d %%", g_i18n:formatNumber(riding * 100, 0))
    table.insert(infos, animal.infoRiding)

    if Platform.gameplay.needHorseCleaning then
        if animal.infoCleanliness == nil then
            animal.infoCleanliness = {
                text = "",
                title = g_i18n:getText("statistic_cleanliness")
            }
        end

        local cleanliness = 1 - AnimalHorse.getDirtFactor(animal)
        animal.infoCleanliness.value = cleanliness
        animal.infoCleanliness.ratio = cleanliness
        animal.infoCleanliness.valueText = string.format("%d %%", g_i18n:formatNumber(cleanliness * 100, 0))
        table.insert(infos, animal.infoCleanliness)
    end
end

--- Add horse-specific HUD info lines (riding, fitness, cleanliness).
--- Called from Animal:showInfo when animal:isHorse() is true.
--- @param animal table Animal instance (HORSE type)
--- @param box table HUD info box
function AnimalHorse.showHorseHudInfo(animal, box)
    box:addLine(g_i18n:getText("infohud_riding"), string.format("%d%%", animal.riding))
    box:addLine(g_i18n:getText("infohud_fitness"), string.format("%d%%", animal.fitness))
    if Platform.gameplay.needHorseCleaning then
        box:addLine(g_i18n:getText("statistic_cleanliness"), string.format("%d%%", 100 - animal.dirt))
    end
end

--- Save horse-specific fields (dirt, fitness, riding) to XML.
--- Called from Animal:saveToXMLFile when animal is HORSE type.
--- @param animal table Animal instance (HORSE type)
--- @param xmlFile table XML file handle
--- @param key string XML key path for this animal
function AnimalHorse.saveHorseFields(animal, xmlFile, key)
    xmlFile:setFloat(key .. "#dirt", animal.dirt)
    xmlFile:setFloat(key .. "#fitness", animal.fitness)
    xmlFile:setFloat(key .. "#riding", animal.riding)
end
