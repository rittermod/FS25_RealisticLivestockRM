--[[
    AnimalHealth.lua
    Health updates, death processing, and the daily death rolls - low health,
    old age, random accidents. Old-age and accident chances are per month and
    are converted to a daily chance at the live days per period; the low-health
    chance is already daily. Animal.lua holds one-liner delegates that route
    here, and must be sourced AFTER this module.

    Serialization and XML load/save stay in Animal.lua: health, isDead and
    numAnimals are initialized in the constructor and serialized as part of the
    MP protocol. deathEnabled and accidentsChance are class-level settings owned
    by RLSettings via Animal.onSettingChanged - read here, never managed here.
]]

AnimalHealth = {}

local Log = RmLogging.getLogger("RLRM")


-- =============================================================================
-- HEALTH FUNCTIONS (delegated from Animal prototype)
-- =============================================================================

--- Get health as a 0.0-1.0 factor.
--- @param animal table Animal instance
--- @return number healthFactor Health divided by 100
function AnimalHealth.getHealthFactor(animal)
    return animal.health / 100
end


--- Hourly health: food (or the type's health hook) vs the threshold, loss slowed by 2 - genetics; weight: raw food.
--- @param animal table Animal instance
--- @param foodFactor number Food factor (0.0-1.0)
function AnimalHealth.updateHealth(animal, foodFactor)

    local subType = animal:getSubType()
    local healthThresholdFactor = subType.healthThresholdFactor
    local healthGenetics = animal.genetics.health

    local healthFactor = foodFactor
    local typeModule = animal:getTypeModule()
    if typeModule ~= nil and typeModule.getHealthFoodFactor ~= nil then
        local hooked = typeModule.getHealthFoodFactor(animal, foodFactor)
        if type(hooked) == "number" then healthFactor = hooked end
    end
    Log:trace("updateHealth: farmId=%s uniqueId=%s food=%s healthFactor=%s", tostring(animal.farmId),
        tostring(animal.uniqueId), tostring(foodFactor), tostring(healthFactor))

    local factor, delta, geneticsTerm, branch

    if healthThresholdFactor < healthFactor then
        factor = (healthFactor - healthThresholdFactor) / (1 - healthThresholdFactor)
        delta = subType.healthIncreaseHour
        geneticsTerm = healthGenetics
        branch = "gain"
    else
        factor = healthFactor / healthThresholdFactor - 1
        delta = subType.healthDecreaseHour
        geneticsTerm = 2 - healthGenetics
        branch = "loss"
    end

    local healthDelta = delta * factor * geneticsTerm
    local healthBefore = animal.health

    if healthDelta ~= 0 then animal.health = math.clamp(math.floor(animal.health + healthDelta), 0, 100) end

    Log:trace("updateHealth: farmId=%s uniqueId=%s typeIndex=%s subType=%s food=%s branch=%s geneticsTerm=%s"
        .. " healthDelta=%s health=%s->%s",
        tostring(animal.farmId), tostring(animal.uniqueId), tostring(animal.animalTypeIndex), tostring(subType.name),
        tostring(foodFactor), tostring(branch), tostring(geneticsTerm), tostring(healthDelta), tostring(healthBefore),
        tostring(animal.health))

    animal:updateWeight(foodFactor)

end


-- =============================================================================
-- DEATH FUNCTIONS (delegated from Animal prototype)
-- =============================================================================

--- Kill the animal: set dead state, remove from sale/AI systems, add death message,
--- and queue removal from cluster system.
--- @param animal table Animal instance
--- @param reason string|nil Death reason key (e.g. "rl_death_health", "rl_death_age")
function AnimalHealth.die(animal, reason)

    animal.numAnimals = 0
    animal.isDead = true

    Log:debug("Animal died: %s reason=%s", animal.uniqueId or "?", reason or "unknown")

    if animal.sale ~= nil then g_currentMission.animalSystem:removeSaleAnimal(animal.animalTypeIndex, animal.birthday.country, animal.farmId, animal.uniqueId) end
    if animal.isAIAnimal then g_currentMission.animalSystem:removeAIAnimal(animal.animalTypeIndex, animal.birthday.country, animal.farmId, animal.uniqueId) end

    animal:addMessage("DEATH", { reason or "rl_ui_unknownCauses" })

    if animal.clusterSystem ~= nil then animal.clusterSystem:addPendingRemoveCluster(animal) end

end


--- Clamp a death chance to [0, 1]; zero, a negative and NaN read 0, and nothing above 1 reaches the conversion.
--- @param chance number raw chance
--- @return number clamped chance in [0, 1]
local function clampChance(chance)
    if not (chance > 0) then return 0 end
    if chance > 1 then return 1 end
    return chance
end


--- Daily death chance from low health; better health genetics lower it, and under 6 months reads 10 health worse.
--- @param animal table Animal instance
--- @return number chance daily probability in [0, 1]
function AnimalHealth.getLowHealthDailyDeathChance(animal)

    local health = animal.health

    if health >= 80 then
        Log:trace("getLowHealthDailyDeathChance: farmId=%s uniqueId=%s health=%s >= 80, chance 0",
            tostring(animal.farmId), tostring(animal.uniqueId), tostring(health))
        return 0
    end

    if animal.age < 6 then health = health - 10 end

    local raw = 0.5 * (1.5 - 0.5 * animal.genetics.health) - health / 100
    local chance = clampChance(raw)

    Log:trace("getLowHealthDailyDeathChance: farmId=%s uniqueId=%s health=%s age=%s genetics=%s raw=%s chance=%s",
        tostring(animal.farmId), tostring(animal.uniqueId), tostring(animal.health), tostring(animal.age),
        tostring(animal.genetics.health), tostring(raw), tostring(chance))

    return chance

end


--- Monthly old-age death chance: zero below the type's minimum age, then rising with age, times (2 - health genetics).
--- @param animal table Animal instance
--- @return number chance monthly probability in [0, 1]
function AnimalHealth.getOldAgeMonthlyDeathChance(animal)

    local animalType = animal.animalTypeIndex
    local age = animal.age
    local healthGenetics = animal.genetics.health

    local minAge = 20000
    local maxAge = 30000

    if animalType == AnimalType.COW then
        -- cattle old age min: 15y (180m)
        -- cattle old age max: 20y (240m)
        minAge = 180
        maxAge = 240
    elseif animalType == AnimalType.SHEEP then
        -- sheep old age min: 10y (120m)
        -- sheep old age max: 12y (144m)
        minAge = 120
        maxAge = 144
    elseif animalType == AnimalType.HORSE then
        -- horse old age min: 25y (300m)
        -- horse old age max: 30y (360m)
        minAge = 300
        maxAge = 360
    elseif animalType == AnimalType.PIG then
        -- pig old age min: 15y (180m)
        -- pig old age max: 20y (240m)
        minAge = 180
        maxAge = 240
    elseif animalType == AnimalType.CHICKEN then
        -- chicken old age min: 5y (60m)
        -- chicken old age max: 8y (96m)
        minAge = 60
        maxAge = 96
    elseif animalType == AnimalType.ALPACA then
        -- alpaca old age min: 15y (180m)
        -- alpaca old age max: 20y (240m)
        minAge = 180
        maxAge = 240
    end

    if age < minAge then
        Log:trace("getOldAgeMonthlyDeathChance: farmId=%s uniqueId=%s age=%s < minAge=%s, chance 0",
            tostring(animal.farmId), tostring(animal.uniqueId), tostring(age), tostring(minAge))
        return 0
    end

    local raw = (0.7 - ((maxAge - age) / 100)) * (2 - healthGenetics)
    local chance = clampChance(raw)

    Log:trace("getOldAgeMonthlyDeathChance: farmId=%s uniqueId=%s age=%s minAge=%s maxAge=%s genetics=%s raw=%s"
        .. " chance=%s", tostring(animal.farmId), tostring(animal.uniqueId), tostring(age), tostring(minAge),
        tostring(maxAge), tostring(healthGenetics), tostring(raw), tostring(chance))

    return chance

end


--- Monthly accident chance for the type the spec houses, raised in the cold and scaled by the accidents setting.
--- @param animal table Animal instance
--- @param spec table Husbandry animal spec (provides animalTypeIndex, minTemp)
--- @return number chance monthly probability in [0, 1]
--- @return boolean canBeSold whether the carcass pays a salvage share
function AnimalHealth.getAccidentMonthlyDeathChance(animal, spec)

    local animalType = spec.animalTypeIndex
    local animalsCanBeSold = true
    local deathChance = 0.01
    local temp = spec.minTemp

    if animalType == AnimalType.COW then
        deathChance = 0.002
        if animal.age < 6 then
            deathChance = 0.0035
        elseif animal.age < 18 then
            deathChance = 0.0024
        end
    elseif animalType == AnimalType.SHEEP then
        deathChance = 0.003
        if animal.age < 3 then
            deathChance = 0.0035
        elseif animal.age < 8 then
            deathChance = 0.0032
        end
    elseif animalType == AnimalType.HORSE then
        deathChance = 0.002
    elseif animalType == AnimalType.PIG then
        deathChance = 0.001
        if animal.age < 3 then
            deathChance = 0.018
        elseif animal.age < 6 then
            deathChance = 0.0075
        end
    elseif animalType == AnimalType.CHICKEN then
        if animal.age < 6 then
            deathChance = 0.0012
        else
            deathChance = 0.0016
        end
        animalsCanBeSold = false
    elseif animalType == AnimalType.ALPACA then
        deathChance = 0.003
    end

    -- animals are more likely to die in cold weather, especially young animals due to ice, pneumonia etc

    if temp ~= nil and temp < 10 and temp >= 0 then
        deathChance = deathChance * (1 + (1 - (temp / 12)))
    elseif temp ~= nil and temp < 0 then
        deathChance = deathChance * (1 + (1 - (temp / 10)))
    end

    local raw = deathChance * animal.accidentsChance
    local chance = clampChance(raw)

    Log:trace("getAccidentMonthlyDeathChance: farmId=%s uniqueId=%s type=%s age=%s temp=%s raw=%s chance=%s"
        .. " canBeSold=%s", tostring(animal.farmId), tostring(animal.uniqueId), tostring(animalType),
        tostring(animal.age), tostring(temp), tostring(raw), tostring(chance), tostring(animalsCanBeSold))

    return chance, animalsCanBeSold

end


--- Roll the daily low-health death; no draw is spent when the chance is not above 0.
--- @param animal table Animal instance
--- @return number died 1 if the animal died, 0 otherwise
function AnimalHealth.calculateLowHealthDailyAnimalDeaths(animal)

    if animal.numAnimals <= 0 or animal.isDead then
        Log:trace("calculateLowHealth: skipped (dead=%s numAnimals=%d)",
            tostring(animal.isDead), animal.numAnimals or 0)
        return 0
    end

    local chance = AnimalHealth.getLowHealthDailyDeathChance(animal)

    if not (chance > 0) then
        Log:trace("calculateLowHealth: farmId=%s uniqueId=%s chance=%s, no draw",
            tostring(animal.farmId), tostring(animal.uniqueId), tostring(chance))
        return 0
    end

    local draw = math.random()

    Log:trace("calculateLowHealth: farmId=%s uniqueId=%s chance=%s draw=%s",
        tostring(animal.farmId), tostring(animal.uniqueId), tostring(chance), tostring(draw))

    if draw < chance then
        animal:die("rl_death_health")
        return 1
    end

    return 0

end


--- Roll the old-age death: the monthly chance converted to a daily one; no draw when it is not above 0.
--- @param animal table Animal instance
--- @param daysPerPeriod number days per month, 1..28
--- @return number died 1 if the animal died, 0 otherwise
function AnimalHealth.calculateOldAgeMonthlyAnimalDeaths(animal, daysPerPeriod)

    if animal.numAnimals <= 0 or animal.isDead then
        Log:trace("calculateOldAge: skipped (dead=%s numAnimals=%d)",
            tostring(animal.isDead), animal.numAnimals or 0)
        return 0
    end

    local monthly = AnimalHealth.getOldAgeMonthlyDeathChance(animal)

    if not (monthly > 0) then
        Log:trace("calculateOldAge: farmId=%s uniqueId=%s monthly=%s, no draw",
            tostring(animal.farmId), tostring(animal.uniqueId), tostring(monthly))
        return 0
    end

    local daily = RLDiseaseRates.perTick(monthly, daysPerPeriod)
    local draw = math.random()

    Log:trace("calculateOldAge: farmId=%s uniqueId=%s monthly=%s daily=%s daysPerPeriod=%s draw=%s",
        tostring(animal.farmId), tostring(animal.uniqueId), tostring(monthly), tostring(daily),
        tostring(daysPerPeriod), tostring(draw))

    if draw < daily then
        animal:die("rl_death_age")
        return 1
    end

    return 0

end


--- Roll the accident death like the old-age one; a carcass that can be sold pays a salvage share.
--- @param animal table Animal instance
--- @param spec table Husbandry animal spec (provides animalTypeIndex, minTemp)
--- @param daysPerPeriod number days per month, 1..28
--- @return number deaths 1 if animal died, 0 otherwise
--- @return number money Sale proceeds if animal was sold, 0 otherwise
function AnimalHealth.calculateRandomMonthlyAnimalDeaths(animal, spec, daysPerPeriod)

    if animal.numAnimals <= 0 or animal.isDead then
        Log:trace("calculateRandom: skipped (dead=%s numAnimals=%d)",
            tostring(animal.isDead), animal.numAnimals or 0)
        return 0, 0
    end

    local monthly, animalsCanBeSold = AnimalHealth.getAccidentMonthlyDeathChance(animal, spec)

    if not (monthly > 0) then
        Log:trace("calculateRandom: farmId=%s uniqueId=%s monthly=%s, no draw",
            tostring(animal.farmId), tostring(animal.uniqueId), tostring(monthly))
        return 0, 0
    end

    local daily = RLDiseaseRates.perTick(monthly, daysPerPeriod)
    local draw = math.random()

    Log:trace("calculateRandom: farmId=%s uniqueId=%s monthly=%s daily=%s daysPerPeriod=%s draw=%s",
        tostring(animal.farmId), tostring(animal.uniqueId), tostring(monthly), tostring(daily),
        tostring(daysPerPeriod), tostring(draw))

    if draw < daily then
        local animalPrice = 0
        if animalsCanBeSold then animalPrice = animal:getSellPrice() * 0.33 end

        animal:die("rl_death_accident")
        return 1, animalPrice
    end

    return 0, 0

end


-- =============================================================================
-- DAILY EVALUATION (consolidation of death evaluation block from onDayChanged)
-- =============================================================================

--- Evaluate all death pathways for an animal during daily update.
--- Consolidates the death evaluation block from Animal:onDayChanged, including
--- server/deathEnabled guards and AnimalDeathEvent broadcast.
--- Sequential short-circuit: lowHealth -> oldAge (if alive) -> random (if alive and spec).
--- @param animal table Animal instance
--- @param spec table|nil Husbandry animal spec (nil for sale animals)
--- @param daysPerPeriod number days per month, 1..28, for the old-age and accident conversion
--- @return number lowHealthDeath 1 if died from low health, 0 otherwise
--- @return number oldDeath 1 if died from old age, 0 otherwise
--- @return number randomDeath 1 if died from random accident, 0 otherwise
--- @return number randomDeathMoney Sale proceeds from random death, 0 otherwise
function AnimalHealth.evaluateDaily(animal, spec, daysPerPeriod)

    if not animal.deathEnabled or g_server == nil then
        Log:trace("evaluateDaily: skipped (deathEnabled=%s server=%s)",
            tostring(animal.deathEnabled), tostring(g_server ~= nil))
        return 0, 0, 0, 0
    end

    if animal.clusterSystem ~= nil and animal.clusterSystem.owner:getOwnerFarmId() == FarmManager.INVALID_FARM_ID then
        Log:trace("evaluateDaily: skipped (invalid farm)")
        return 0, 0, 0, 0
    end

    local lowHealthDeath = animal:calculateLowHealthDailyAnimalDeaths()

    local oldDeath = 0
    if lowHealthDeath == 0 then
        oldDeath = animal:calculateOldAgeMonthlyAnimalDeaths(daysPerPeriod)
    end

    local randomDeath, randomDeathMoney = 0, 0
    if spec ~= nil and lowHealthDeath == 0 and oldDeath == 0 then
        randomDeath, randomDeathMoney = animal:calculateRandomMonthlyAnimalDeaths(spec, daysPerPeriod)
    end

    if lowHealthDeath > 0 or oldDeath > 0 or randomDeath > 0 then
        Log:debug("evaluateDaily: death occurred for %s (low=%d old=%d random=%d money=%.2f)",
            animal.uniqueId or "?", lowHealthDeath, oldDeath, randomDeath, randomDeathMoney)
        g_server:broadcastEvent(AnimalDeathEvent.new(
            animal.clusterSystem ~= nil and animal.clusterSystem.owner or nil, animal))
    end

    return lowHealthDeath, oldDeath, randomDeath, randomDeathMoney

end
