RealisticLivestock_LivestockTrailer = {}

local Log = RmLogging.getLogger("RLRM")

--- Bulk-add animals to the trailer through the single-cluster path, flushing the
--- pending queue exactly once. The per-add flush in :addCluster is suppressed for
--- the duration of the loop (rlAddBatchInProgress), so a buy / move batch commits
--- with a single tail updateNow instead of one per animal. The flag is cleared
--- unconditionally before the tail flush so a flush error can never strand it true
--- (which would silently disable every later standalone load on this trailer).
--- @param superFunc function Overwritten-function predecessor (unused; replaced wholesale)
--- @param animals table Array of Animal entities to add
function RealisticLivestock_LivestockTrailer:addAnimals(superFunc, animals)

    local spec = self.spec_livestockTrailer
    local clusterSystem = spec.clusterSystem

    spec.rlAddBatchInProgress = true
    local ok, err = pcall(function()
        for _, animal in pairs(animals) do
            self:addCluster(animal)
        end
    end)
    spec.rlAddBatchInProgress = false

    local ok2, err2 = pcall(function() clusterSystem:updateNow() end)

    if not (ok and ok2) then
        Log:error("Trailer addAnimals: batch failed N=%d queue=%s flush=%s",
            #animals, tostring(err), tostring(err2))
    end

    Log:debug("Trailer addAnimals: queued %d animal(s) through self:addCluster and flushed once",
        #animals)

end

LivestockTrailer.addAnimals = Utils.overwrittenFunction(LivestockTrailer.addAnimals, RealisticLivestock_LivestockTrailer.addAnimals)


--- Add one cluster to the trailer. An already-individual RLRM Animal passes straight
--- through to the pending queue; a vanilla / multi cluster is expanded into individual
--- Animals first. BOTH queueing branches fall through to a shared tail that flushes the
--- pending queue when this is a standalone add (not inside an addAnimals batch).
---
--- The tail flush closes the world-load data-loss path: a world load reaches this
--- override through AnimalLoadEvent (a single addCluster, not addAnimals) and the loose
--- rideable is removed from the world right after addCluster returns. Without a flush here
--- the loaded animal would sit unflushed in the pending queue - absent from getClusters(),
--- uncounted by capacity, and dropped outright if a save lands - while the rideable is
--- already gone. Flushing synchronously makes the animal present before the caller removes
--- the rideable.
--- @param superFunc function Overwritten-function predecessor (unused; replaced wholesale)
--- @param cluster table RLRM Animal (pass-through) or vanilla cluster (expanded)
function RealisticLivestock_LivestockTrailer:addCluster(superFunc, cluster)

    local spec = self.spec_livestockTrailer
    local clusterSystem = spec.clusterSystem

    Log:trace("Trailer addCluster: isIndividual=%s numAnimals=%s name=%s canBeSold=%s id=%s",
        tostring(cluster.isIndividual), tostring(cluster.numAnimals),
        tostring(cluster.name or cluster:getName()), tostring(cluster.canBeSold),
        tostring(cluster.id))

    if cluster.numAnimals > 1 or cluster.isIndividual == nil then

        -- Third-party mods may create rideables with vanilla clusters that have numAnimals=0 (props).
        -- Skip these to prevent phantom animals after conversion sets numAnimals=1.
        -- Nothing is queued, so this branch keeps its early return (no flush).
        if cluster.numAnimals == nil or cluster.numAnimals < 1 then
            Log:warning("Trailer addCluster: skipping cluster with numAnimals=%s subTypeIndex=%s", tostring(cluster.numAnimals), tostring(cluster.subTypeIndex))
            return
        end

        -- Capture sell-protection from vanilla cluster before conversion (e.g. AdditionalContracts mission horses).
        -- NOTE: Use explicit if - Lua and/or ternary fails when the true-branch is false.
        local canBeSoldFlag = nil
        if cluster:getCanBeSold() == false then
            canBeSoldFlag = false
            Log:debug("Trailer addCluster: cluster canBeSold=false (subTypeIndex=%s), preserving on converted animals", tostring(cluster.subTypeIndex))
        end

        for i=1, cluster.numAnimals do
            local subType = g_currentMission.animalSystem:getSubTypeByIndex(cluster.subTypeIndex)
            if subType == nil then
                Log:warning("Trailer expand: cluster subTypeIndex=%d has no matching subtype - will crash", cluster.subTypeIndex)
            else
                Log:debug("Trailer expand: cluster subTypeIndex=%d -> subType=%s gender=%s", cluster.subTypeIndex, subType.name, subType.gender or "?")
            end
            local animal = Animal.new({
                age = cluster.age,
                health = cluster.health,
                gender = subType.gender,
                subTypeIndex = cluster.subTypeIndex,
                reproduction = cluster.reproduction,
                clusterSystem = clusterSystem,
                canBeSold = canBeSoldFlag
            })
            clusterSystem:addPendingAddCluster(animal)
        end

    else

        Log:trace("Trailer addCluster: pass-through RLRM animal (uniqueId=%s canBeSold=%s)",
            tostring(cluster.uniqueId), tostring(cluster.canBeSold))
        clusterSystem:addPendingAddCluster(cluster)

    end

    -- Shared tail flush. A standalone add (the AnimalLoadEvent world load) commits the
    -- pending queue here, so getClusters()/capacity reflect the animal before the caller
    -- removes the world rideable. An addAnimals batch suppresses this (rlAddBatchInProgress)
    -- and flushes once at its loop tail, keeping buy / move batches at one flush instead of
    -- N. isServer-guarded: the pending queue is server-only and this path runs server-side;
    -- updateNow is idempotent (gated on needsUpdate), so a redundant call is a safe no-op.
    -- On flush error the animal stays queued and is recovered by the next flush.
    if self.isServer and not spec.rlAddBatchInProgress then
        local ok, err = pcall(function() clusterSystem:updateNow() end)
        if not ok then
            Log:error("Trailer addCluster: flush failed, animal stays queued (recoverable): %s", tostring(err))
        else
            Log:debug("Trailer addCluster: flushed pending queue, trailer now holds %d animal(s)", #clusterSystem:getClusters())
        end
    end
end

LivestockTrailer.addCluster = Utils.overwrittenFunction(LivestockTrailer.addCluster, RealisticLivestock_LivestockTrailer.addCluster)


function RealisticLivestock_LivestockTrailer:onLoadFinished(success)
    if success == nil then return end

    self.spec_livestockTrailer:updateAnimals()
end

LivestockTrailer.onLoadFinished = Utils.appendedFunction(LivestockTrailer.onLoadFinished, RealisticLivestock_LivestockTrailer.onLoadFinished)



--- The trailer's day tick: ages and breeds the animals in transit on today's calendar date.
---@param superFunc function the base dayChanged
function RealisticLivestock_LivestockTrailer:dayChanged(superFunc)

    superFunc(self)

    if self.isServer then

        local minTemp =  math.floor(g_currentMission.environment.weather.temperatureUpdater.currentMin)

        local environment = g_currentMission.environment
        local currentDayInPeriod = environment.currentDayInPeriod
        local daysPerPeriod = environment.daysPerPeriod
        local day, month, year = RLCalendar.getDate(environment)

        Log:trace("Trailer dayChanged [id=%s]: calendar date %s/%s/%s",
            tostring(self.id), tostring(day), tostring(month), tostring(year))

        local spec = self.spec_livestockTrailer
        local animals = spec.clusterSystem:getAnimals()

        local totalChildren, deadParents, childrenToSell, childrenToSellMoney, lowHealthDeaths, oldAgeDeaths, randomDeaths, randomDeathsMoney = 0, 0, 0, 0, 0, 0, 0, 0

        for _, animal in ipairs(animals) do

            if animal.monthsSinceLastBirth == nil then
                animal.monthsSinceLastBirth = 0
            end

            if animal.isParent == nil then
                animal.isParent = false
            end

            local a, b, c, d, e, f, g, h = animal:onDayChanged(spec, self.isServer, day, month, year, currentDayInPeriod, daysPerPeriod)

            totalChildren = totalChildren + a
            deadParents = deadParents + b
            childrenToSell = childrenToSell + c
            childrenToSellMoney = childrenToSellMoney + d
            lowHealthDeaths = lowHealthDeaths + e
            oldAgeDeaths = oldAgeDeaths + f
            randomDeaths = randomDeaths + g
            randomDeathsMoney = randomDeathsMoney + h

        end

        local animalType = (spec.animalTypeIndex == AnimalType.COW and 1) or (spec.animalTypeIndex == AnimalType.PIG and 2) or (spec.animalTypeIndex == AnimalType.SHEEP and 3) or (spec.animalTypeIndex == AnimalType.CHICKEN and 4) or (spec.animalTypeIndex == AnimalType.HORSE and 5)

        if totalChildren > 0 then
            local msgText = ""

            if animalType == 1 then msgText = totalChildren == 1 and g_i18n:getText("rl_ui_cow_singleBirth") or string.format(g_i18n:getText("rl_ui_cow_multipleBirths"), totalChildren) end
            if animalType == 2 then msgText = totalChildren == 1 and g_i18n:getText("rl_ui_pig_singleBirth") or string.format(g_i18n:getText("rl_ui_pig_multipleBirths"), totalChildren) end
            if animalType == 3 then msgText = totalChildren == 1 and g_i18n:getText("rl_ui_sheep_singleBirth") or string.format(g_i18n:getText("rl_ui_sheep_multipleBirths"), totalChildren) end
            if animalType == 4 then msgText = totalChildren == 1 and g_i18n:getText("rl_ui_chicken_singleBirth") or string.format(g_i18n:getText("rl_ui_chicken_multipleBirths"), totalChildren) end
            if animalType == 5 then msgText = totalChildren == 1 and g_i18n:getText("rl_ui_horse_singleBirth") or string.format(g_i18n:getText("rl_ui_horse_multipleBirths"), totalChildren) end

            g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_CRITICAL, msgText)
        end

        if deadParents > 0 then

            local msgText = ""

            if animalType == 1 then msgText = deadParents == 1 and g_i18n:getText("rl_ui_cow_singleDeath_birth") or string.format(g_i18n:getText("rl_ui_cow_multipleDeaths_birth"), deadParents) end
            if animalType == 2 then msgText = deadParents == 1 and g_i18n:getText("rl_ui_pig_singleDeath_birth") or string.format(g_i18n:getText("rl_ui_pig_multipleDeaths_birth"), deadParents) end
            if animalType == 3 then msgText = deadParents == 1 and g_i18n:getText("rl_ui_sheep_singleDead_birth") or string.format(g_i18n:getText("rl_ui_sheep_multipleDeaths_birth"), deadParents) end
            if animalType == 5 then msgText = deadParents == 1 and g_i18n:getText("rl_ui_horse_singleDeath_birth") or string.format(g_i18n:getText("rl_ui_horse_multipleDeaths_birth"), deadParents) end

            g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_CRITICAL, msgText)
        end

        if childrenToSell > 0 and childrenToSellMoney > 0 then
            local farmIndex = spec:getOwnerFarmId()
            local farm = g_farmManager:getFarmById(farmIndex)

            local msgText = ""

            if animalType == 1 then msgText = childrenToSell == 1 and g_i18n:getText("rl_ui_cow_singleSold_birth") or string.format(g_i18n:getText("rl_ui_cow_multipleSold_birth"), childrenToSell) end
            if animalType == 2 then msgText = childrenToSell == 1 and g_i18n:getText("rl_ui_pig_singleSold_birth") or string.format(g_i18n:getText("rl_ui_pig_multipleSold_birth"), childrenToSell) end
            if animalType == 3 then msgText = childrenToSell == 1 and g_i18n:getText("rl_ui_sheep_singleSold_birth") or string.format(g_i18n:getText("rl_ui_sheep_multipleSold_birth"), childrenToSell) end
            if animalType == 4 then msgText = childrenToSell == 1 and g_i18n:getText("rl_ui_chicken_singleSold_birth") or string.format(g_i18n:getText("rl_ui_chicken_multipleSold_birth"), childrenToSell) end
            if animalType == 5 then msgText = childrenToSell == 1 and g_i18n:getText("rl_ui_horse_singleSold_birth") or string.format(g_i18n:getText("rl_ui_horse_multipleSold_birth"), childrenToSell) end

            g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_CRITICAL, msgText)

            if self.isServer then
                g_currentMission:addMoneyChange(childrenToSellMoney, farmIndex, MoneyType.SOLD_ANIMALS, true)
            else
                g_client:getServerConnection():sendEvent(MoneyChangeEvent.new(childrenToSellMoney, MoneyType.SOLD_ANIMALS, farmIndex))
            end

            if farm ~= nil then
                farm:changeBalance(childrenToSellMoney, MoneyType.SOLD_ANIMALS)
            end
        end

        if lowHealthDeaths > 0 then

            local msgText = ""

            if animalType == 1 then msgText = lowHealthDeaths == 1 and g_i18n:getText("rl_ui_cow_singleDeath_health") or string.format(g_i18n:getText("rl_ui_cow_multipleDeaths_health"), lowHealthDeaths) end
            if animalType == 2 then msgText = lowHealthDeaths == 1 and g_i18n:getText("rl_ui_pig_singleDeath_health") or string.format(g_i18n:getText("rl_ui_pig_multipleDeaths_health"), lowHealthDeaths) end
            if animalType == 3 then msgText = lowHealthDeaths == 1 and g_i18n:getText("rl_ui_sheep_singleDeath_health") or string.format(g_i18n:getText("rl_ui_sheep_multipleDeaths_health"), lowHealthDeaths) end
            if animalType == 4 then msgText = lowHealthDeaths == 1 and g_i18n:getText("rl_ui_chicken_singleDeath_health") or string.format(g_i18n:getText("rl_ui_chicken_multipleDeaths_health"), lowHealthDeaths) end
            if animalType == 5 then msgText = lowHealthDeaths == 1 and g_i18n:getText("rl_ui_horse_singleDeath_health") or string.format(g_i18n:getText("rl_ui_horse_multipleDeaths_health"), lowHealthDeaths) end

            g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_CRITICAL, msgText)

        end

        if oldAgeDeaths > 0 then

            local msgText = ""

            if animalType == 1 then msgText = oldAgeDeaths == 1 and g_i18n:getText("rl_ui_cow_singleDeath_age") or string.format(g_i18n:getText("rl_ui_cow_multipleDeaths_age"), oldAgeDeaths) end
            if animalType == 2 then msgText = oldAgeDeaths == 1 and g_i18n:getText("rl_ui_pig_singleDeath_age") or string.format(g_i18n:getText("rl_ui_pig_multipleDeaths_age"), oldAgeDeaths) end
            if animalType == 3 then msgText = oldAgeDeaths == 1 and g_i18n:getText("rl_ui_sheep_singleDeath_age") or string.format(g_i18n:getText("rl_ui_sheep_multipleDeaths_age"), oldAgeDeaths) end
            if animalType == 4 then msgText = oldAgeDeaths == 1 and g_i18n:getText("rl_ui_chicken_singleDeath_age") or string.format(g_i18n:getText("rl_ui_chicken_multipleDeaths_age"), oldAgeDeaths) end
            if animalType == 5 then msgText = oldAgeDeaths == 1 and g_i18n:getText("rl_ui_horse_singleDeath_age") or string.format(g_i18n:getText("rl_ui_horse_multipleDeaths_age"), oldAgeDeaths) end

            g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_CRITICAL, msgText)

        end

        if randomDeaths > 0 then

            local farmIndex = spec:getOwnerFarmId()
            local farm = g_farmManager:getFarmById(farmIndex)

            local msgText = ""

            if animalType == 1 then msgText = randomDeaths == 1 and string.format(g_i18n:getText("rl_ui_cow_singleDeath_random"), g_i18n:formatMoney(randomDeathsMoney, 2, true, true)) or string.format(g_i18n:getText("rl_ui_cow_multipleDeaths_random"), randomDeaths, g_i18n:formatMoney(randomDeathsMoney, 2, true, true)) end
            if animalType == 2 then msgText = randomDeaths == 1 and string.format(g_i18n:getText("rl_ui_pig_singleDeath_random"), g_i18n:formatMoney(randomDeathsMoney, 2, true, true)) or string.format(g_i18n:getText("rl_ui_pig_multipleDeaths_random"), randomDeaths, g_i18n:formatMoney(randomDeathsMoney, 2, true, true)) end
            if animalType == 3 then msgText = randomDeaths == 1 and string.format(g_i18n:getText("rl_ui_sheep_singleDeath_random"), g_i18n:formatMoney(randomDeathsMoney, 2, true, true)) or string.format(g_i18n:getText("rl_ui_sheep_multipleDeaths_random"), randomDeaths, g_i18n:formatMoney(randomDeathsMoney, 2, true, true)) end
            if animalType == 4 then msgText = randomDeaths == 1 and g_i18n:getText("rl_ui_chicken_singleDeath_random") or string.format(g_i18n:getText("rl_ui_chicken_multipleDeaths_random"), randomDeaths) end
            if animalType == 5 then msgText = randomDeaths == 1 and string.format(g_i18n:getText("rl_ui_horse_singleDeath_random"), g_i18n:formatMoney(randomDeathsMoney, 2, true, true)) or string.format(g_i18n:getText("rl_ui_horse_multipleDeaths_random"), randomDeaths, g_i18n:formatMoney(randomDeathsMoney, 2, true, true)) end

            g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_CRITICAL, msgText)

            if randomDeathsMoney > 0 then

                if self.isServer then
                    g_currentMission:addMoneyChange(randomDeathsMoney, farmIndex, MoneyType.SOLD_ANIMALS, true)
                else
                    g_client:getServerConnection():sendEvent(MoneyChangeEvent.new(randomDeathsMoney, MoneyType.SOLD_ANIMALS, farmIndex))
                end

                if farm ~= nil then
                    farm:changeBalance(randomDeathsMoney, MoneyType.SOLD_ANIMALS)
                end

            end

        end


        spec.minTemp = minTemp

        if randomDeaths > 0 or oldAgeDeaths > 0 or lowHealthDeaths > 0 or deadParents > 0 or totalChildren > 0 then spec:updateAnimals() end

        self:raiseActive()
    end

end