--[[
    AnimalHealth.lua
    Health, death, and death evaluation logic extracted from Animal.lua.

    Provides helper functions for health updates, death processing, and
    monthly death evaluations (low health, old age, random accidents).
    Animal.lua retains one-liner delegates that route to this module.

    Sourced BEFORE RealisticLivestock_Animal.lua (same pattern as AnimalHorse,
    AnimalReproduction).

    NOTE: Serialization (writeStream/readStream) and XML load/save remain
    in Animal.lua. Health state fields (health, isDead, numAnimals) are
    initialized in the constructor and serialized as part of the MP protocol.
    Class-level settings (deathEnabled, accidentsChance) are managed by
    RLSettings via Animal.onSettingChanged - AnimalHealth reads but does
    not manage them.
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


--- Update animal health based on food factor relative to subType threshold.
--- Food above threshold increases health; below threshold decreases it.
--- Also triggers weight update via animal:updateWeight().
--- @param animal table Animal instance
--- @param foodFactor number Food factor (0.0-1.0)
function AnimalHealth.updateHealth(animal, foodFactor)

    local subType = animal:getSubType()
    local healthThresholdFactor = subType.healthThresholdFactor
    local healthGenetics = animal.genetics.health

    local factor, delta = nil

    if healthThresholdFactor < foodFactor then
        factor = (foodFactor - healthThresholdFactor) / (1 - healthThresholdFactor)
        delta = subType.healthIncreaseHour
    else
        factor = foodFactor / healthThresholdFactor - 1
        delta = subType.healthDecreaseHour
    end

    local healthDelta = delta * factor * healthGenetics

    if healthDelta ~= 0 then animal.health = math.clamp(math.floor(animal.health + healthDelta), 0, 100) end

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


--- Evaluate monthly death chance from low health. Animals below 80 health
--- face increasing death probability scaled by health genetics.
--- Called from evaluateDaily (server-side only).
--- @param animal table Animal instance
--- @return number 1 if animal died, 0 otherwise
function AnimalHealth.calculateLowHealthMonthlyAnimalDeaths(animal)

    if animal.numAnimals <= 0 or animal.isDead then
        Log:trace("calculateLowHealth: skipped (dead=%s numAnimals=%d)",
            tostring(animal.isDead), animal.numAnimals or 0)
        return 0
    end

    local deathChance = 0.01
    local health = animal.health
    local healthGenetics = animal.genetics.health

    if health >= 80 then
        Log:trace("calculateLowHealth: health=%d >= 80, no risk", health)
        return 0
    end

    if animal.age < 6 then health = health - 10 end
    deathChance = (0.5 * (2 - healthGenetics)) - (health / 100)

    Log:trace("calculateLowHealth: health=%d genetics=%.2f deathChance=%.4f",
        animal.health, healthGenetics, deathChance)

    if math.random() <= deathChance then
        animal:die("rl_death_health")
        return 1
    end

    return 0

end


--- Evaluate monthly death chance from old age. Each animal type has a
--- min/max age range; death probability increases once past minAge.
--- Called from evaluateDaily (server-side only).
--- @param animal table Animal instance
--- @return number 1 if animal died, 0 otherwise
function AnimalHealth.calculateOldAgeMonthlyAnimalDeaths(animal)

    if animal.numAnimals <= 0 or animal.isDead then
        Log:trace("calculateOldAge: skipped (dead=%s numAnimals=%d)",
            tostring(animal.isDead), animal.numAnimals or 0)
        return 0
    end

    local animalType = animal.animalTypeIndex
    local deathChance = 0.01
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
    end

    if age < minAge then
        Log:trace("calculateOldAge: age=%d < minAge=%d, no risk", age, minAge)
        return 0
    end

    deathChance = 0.7 - ((maxAge - age) / 100)

    Log:trace("calculateOldAge: age=%d minAge=%d maxAge=%d genetics=%.2f deathChance=%.4f",
        age, minAge, maxAge, healthGenetics, deathChance)

    if math.random() <= deathChance * (2 - healthGenetics) then
        animal:die("rl_death_age")
        return 1
    end

    return 0

end


--- Evaluate monthly random death chance (e.g., broken legs, accidents).
--- Dead animals may be sold at reduced price (lower quality meat).
--- Called from evaluateDaily (server-side only).
--- @param animal table Animal instance
--- @param spec table Husbandry animal spec (provides animalTypeIndex, minTemp)
--- @return number deaths 1 if animal died, 0 otherwise
--- @return number money Sale proceeds if animal was sold, 0 otherwise
function AnimalHealth.calculateRandomMonthlyAnimalDeaths(animal, spec)

    if animal.numAnimals <= 0 or animal.isDead then
        Log:trace("calculateRandom: skipped (dead=%s numAnimals=%d)",
            tostring(animal.isDead), animal.numAnimals or 0)
        return 0, 0
    end

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
    end

    -- animals are more likely to die in cold weather, especially young animals due to ice, pneumonia etc

    if temp ~= nil and temp < 10 and temp >= 0 then
        deathChance = deathChance * (1 + (1 - (temp / 12)))
    elseif temp ~= nil and temp < 0 then
        deathChance = deathChance * (1 + (1 - (temp / 10)))
    end

    deathChance = deathChance * animal.accidentsChance

    Log:trace("calculateRandom: type=%s age=%d temp=%s deathChance=%.6f",
        tostring(animalType), animal.age, tostring(temp), deathChance)

    if math.random() <= deathChance then
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
--- @return number lowHealthDeath 1 if died from low health, 0 otherwise
--- @return number oldDeath 1 if died from old age, 0 otherwise
--- @return number randomDeath 1 if died from random accident, 0 otherwise
--- @return number randomDeathMoney Sale proceeds from random death, 0 otherwise
function AnimalHealth.evaluateDaily(animal, spec)

    if not animal.deathEnabled or g_server == nil then
        Log:trace("evaluateDaily: skipped (deathEnabled=%s server=%s)",
            tostring(animal.deathEnabled), tostring(g_server ~= nil))
        return 0, 0, 0, 0
    end

    if animal.clusterSystem ~= nil and animal.clusterSystem.owner:getOwnerFarmId() == FarmManager.INVALID_FARM_ID then
        Log:trace("evaluateDaily: skipped (invalid farm)")
        return 0, 0, 0, 0
    end

    local lowHealthDeath = animal:calculateLowHealthMonthlyAnimalDeaths()

    local oldDeath = 0
    if lowHealthDeath == 0 then
        oldDeath = animal:calculateOldAgeMonthlyAnimalDeaths()
    end

    local randomDeath, randomDeathMoney = 0, 0
    if spec ~= nil and lowHealthDeath == 0 and oldDeath == 0 then
        randomDeath, randomDeathMoney = animal:calculateRandomMonthlyAnimalDeaths(spec)
    end

    if lowHealthDeath > 0 or oldDeath > 0 or randomDeath > 0 then
        Log:debug("evaluateDaily: death occurred for %s (low=%d old=%d random=%d money=%.2f)",
            animal.uniqueId or "?", lowHealthDeath, oldDeath, randomDeath, randomDeathMoney)
        g_server:broadcastEvent(AnimalDeathEvent.new(
            animal.clusterSystem ~= nil and animal.clusterSystem.owner or nil, animal))
    end

    return lowHealthDeath, oldDeath, randomDeath, randomDeathMoney

end
