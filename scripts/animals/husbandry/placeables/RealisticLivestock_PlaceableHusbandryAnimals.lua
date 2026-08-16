RealisticLivestock_PlaceableHusbandryAnimals = {}


-- Per-animal onDayChanged outlier threshold. Animals exceeding this elapsed
-- cost during the per-pen day-change loop emit a TRACE line. Module scope so
-- the value is allocated once and visible to any future helper.
local SLOW_ANIMAL_MS = 50.0


function RealisticLivestock_PlaceableHusbandryAnimals.registerFunctions(placeable)
	SpecializationUtil.registerFunction(placeable, "setHasUnreadRLMessages", PlaceableHusbandryAnimals.setHasUnreadRLMessages)
	SpecializationUtil.registerFunction(placeable, "getHasUnreadRLMessages", PlaceableHusbandryAnimals.getHasUnreadRLMessages)
	SpecializationUtil.registerFunction(placeable, "getRLMessages", PlaceableHusbandryAnimals.getRLMessages)
	SpecializationUtil.registerFunction(placeable, "addRLMessage", PlaceableHusbandryAnimals.addRLMessage)
	SpecializationUtil.registerFunction(placeable, "addRLMessageDirect", PlaceableHusbandryAnimals.addRLMessageDirect)
	SpecializationUtil.registerFunction(placeable, "deleteRLMessage", PlaceableHusbandryAnimals.deleteRLMessage)
	SpecializationUtil.registerFunction(placeable, "getNextRLMessageUniqueId", PlaceableHusbandryAnimals.getNextRLMessageUniqueId)
	SpecializationUtil.registerFunction(placeable, "setNextRLMessageUniqueId", PlaceableHusbandryAnimals.setNextRLMessageUniqueId)
	SpecializationUtil.registerFunction(placeable, "_flushPenDayChange", PlaceableHusbandryAnimals._flushPenDayChange)
end

PlaceableHusbandryAnimals.registerFunctions = Utils.appendedFunction(PlaceableHusbandryAnimals.registerFunctions, RealisticLivestock_PlaceableHusbandryAnimals.registerFunctions)


function PlaceableHusbandryAnimals:setHasUnreadRLMessages(hasUnreadMessages)
    
    self.spec_husbandryAnimals.unreadMessages = hasUnreadMessages

end


function PlaceableHusbandryAnimals:getHasUnreadRLMessages()
    
    return self.spec_husbandryAnimals.unreadMessages or false

end


function PlaceableHusbandryAnimals:getRLMessages()

    return self.spec_husbandryAnimals.messages or {}

end


-- Direct message insertion, bypassing the aggregator
function PlaceableHusbandryAnimals:addRLMessageDirect(id, animal, args, date, uniqueId, isLoading)

    local spec = self.spec_husbandryAnimals

    if spec.messages == nil then spec.messages = {} end

    if date == nil then

        local environment = g_currentMission.environment
        local month = environment.currentPeriod + 2
        local currentDayInPeriod = environment.currentDayInPeriod

        if month > 12 then month = month - 12 end

        local daysPerPeriod = environment.daysPerPeriod
        local day = 1 + math.floor((currentDayInPeriod - 1) * (RLConstants.DAYS_PER_MONTH[month] / daysPerPeriod))
        local year = environment.currentYear

        date = string.format("%s/%s/%s", day, month, year + RLConstants.START_YEAR.FULL)

    end

    args = args or {}
    for i, arg in pairs(args) do args[i] = tostring(arg) end

    -- Resolve the uniqueId into a local BEFORE the insert so the incremental broadcast (below) carries
    -- the SAME server-assigned id the client must insert verbatim. A broadcast/apply message passes its
    -- uniqueId in; a fresh server add mints the next one from the per-husbandry counter.
    local resolvedUniqueId = uniqueId or spec:getNextRLMessageUniqueId()

    table.insert(spec.messages, {
        ["id"] = id,
        ["animal"] = animal,
        ["args"] = args,
        ["date"] = date,
        ["uniqueId"] = resolvedUniqueId
    })

    if not isLoading and #spec.messages > PlaceableHusbandryAnimals.maxNumMessages then table.remove(spec.messages, 1) end

    spec.unreadMessages = true

    -- Incremental MP sync: broadcast this server-added message to connected clients so their
    -- Messages tab stays current during play - the join snapshot (HusbandryMessageStateEvent) only
    -- covers connect time. Server-authoritative + netIsRunning; skipped on savegame load (server-local,
    -- predates any join - the join snapshot covers loaded messages). NO sendLocal: the host already
    -- inserted above, so the event :run fires only on clients (g_server == nil) and never re-broadcasts.
    if not isLoading and g_server ~= nil and g_server.netIsRunning then
        Log:debug("addRLMessageDirect: broadcasting id='%s' uniqueId=%s to clients", tostring(id), tostring(resolvedUniqueId))
        HusbandryMessageAddEvent.sendEvent(self, resolvedUniqueId, id, animal, args, date)
    end

    -- Refresh an open Messages tab on EVERY machine (host, SP, and client-via-:run) - mirrors
    -- HusbandryMessageDeleteEvent:run so there is no host/client asymmetry. Nil-guarded: g_rlMenu /
    -- messagesFrame may be absent during early lifecycle or if the menu was never opened.
    if g_rlMenu ~= nil and g_rlMenu.messagesFrame ~= nil
       and g_rlMenu.messagesFrame.refreshIfOpen ~= nil then
        g_rlMenu.messagesFrame:refreshIfOpen()
    end

end


-- Main message entry point - routes through aggregator when in summary mode
function PlaceableHusbandryAnimals:addRLMessage(id, animal, args, date, uniqueId, isLoading)
    if isLoading then
        -- Loading from save - bypass aggregator
        self:addRLMessageDirect(id, animal, args, date, uniqueId, isLoading)
    else
        -- Route through aggregator (handles summary mode check)
        RLMessageAggregator.queueMessage(self, id, animal, args, date)
    end
end


function PlaceableHusbandryAnimals:deleteRLMessage(uniqueId)

    local spec = self.spec_husbandryAnimals

    for i, message in pairs(spec.messages or {}) do

        if message.uniqueId == uniqueId then
            table.remove(spec.messages, i)
            return
        end

    end

end


function PlaceableHusbandryAnimals:setNextRLMessageUniqueId(nextUniqueId)

    self.spec_husbandryAnimals.rlMessageUniqueId = nextUniqueId or 0

end


function PlaceableHusbandryAnimals:getNextRLMessageUniqueId()

    local spec = self.spec_husbandryAnimals

    if spec.rlMessageUniqueId == nil then spec.rlMessageUniqueId = 0 end

    spec.rlMessageUniqueId = spec.rlMessageUniqueId + 1

    return spec.rlMessageUniqueId

end


function RealisticLivestock_PlaceableHusbandryAnimals:saveToXMLFile(xmlFile, key)

    local spec = self.spec_husbandryAnimals

    xmlFile:setInt(key .. ".messages#uniqueId", spec.rlMessageUniqueId or 0)
    xmlFile:setBool(key .. ".messages#unreadMessages", spec.unreadMessages or false)

    for i, message in pairs(spec.messages or {}) do

        local messageKey = string.format("%s.messages.message(%d)", key, i - 1)

        xmlFile:setString(messageKey .. "#id", message.id)
        xmlFile:setString(messageKey .. "#date", message.date)
        if message.animal ~= nil then xmlFile:setString(messageKey .. "#animal", message.animal) end
        xmlFile:setInt(messageKey .. "#uniqueId", message.uniqueId)
        
        for j, arg in pairs(message.args) do

            xmlFile:setString(string.format("%s.args.arg(%d)#value", messageKey, j - 1), arg)

        end

    end

end

PlaceableHusbandryAnimals.saveToXMLFile = Utils.prependedFunction(PlaceableHusbandryAnimals.saveToXMLFile, RealisticLivestock_PlaceableHusbandryAnimals.saveToXMLFile)


function RealisticLivestock_PlaceableHusbandryAnimals:loadFromXMLFile(xmlFile, key)

    local spec = self.spec_husbandryAnimals
    
    spec.rlMessageUniqueId = xmlFile:getInt(key .. ".messages#uniqueId", 0)

    xmlFile:iterate(key .. ".messages.message", function(_, messageKey)
    
        local id = xmlFile:getString(messageKey .. "#id")
        local date = xmlFile:getString(messageKey .. "#date")
        local animal = xmlFile:getString(messageKey .. "#animal")
        local uniqueId = xmlFile:getInt(messageKey .. "#uniqueId")
        local args = {}

        xmlFile:iterate(messageKey .. ".args.arg", function(_, argKey)

            table.insert(args, xmlFile:getString(argKey .. "#value"))

        end)
        
        if RLMessage[id] == nil then
            Log:warning("Discarding unknown message id '%s' from savegame (date=%s)", tostring(id), tostring(date))
        else
            self:addRLMessage(id, animal, args, date, uniqueId, true)
        end
    
    end)

    spec.unreadMessages = xmlFile:getBool(key .. ".messages#unreadMessages", false)

end

PlaceableHusbandryAnimals.loadFromXMLFile = Utils.prependedFunction(PlaceableHusbandryAnimals.loadFromXMLFile, RealisticLivestock_PlaceableHusbandryAnimals.loadFromXMLFile)


function RealisticLivestock_PlaceableHusbandryAnimals:onLoad()

    RLMapBridge.onHusbandryLoad(self)

end

PlaceableHusbandryAnimals.onLoad = Utils.appendedFunction(PlaceableHusbandryAnimals.onLoad, RealisticLivestock_PlaceableHusbandryAnimals.onLoad)


function RealisticLivestock_PlaceableHusbandryAnimals.onSettingChanged(name, state)

    PlaceableHusbandryAnimals[name] = state

end


function RealisticLivestock_PlaceableHusbandryAnimals:updateVisualAnimals(_)
    local spec = self.spec_husbandryAnimals
    local animals = spec.clusterSystem:getAnimals()

    -- Phase timing: setClusters just stores the next cluster set (cheap);
    -- updateVisuals does the engine work. Splitting them lets us pair this
    -- log with the matching updateVisuals 4-phase summary.
    local tStart = getTimeSec()
    spec.clusterHusbandry:setClusters(animals)
    local tSetMs = (getTimeSec() - tStart) * 1000

    local tUpdateStart = getTimeSec()
    spec.clusterHusbandry:updateVisuals()
    local tUpdateMs = (getTimeSec() - tUpdateStart) * 1000

    Log:debug("updateVisualAnimals [%s anim=%d]: setClusters=%.2fms updateVisuals=%.2fms total=%.2fms",
        tostring(self.getName and self:getName() or self),
        #animals,
        tSetMs, tUpdateMs, tSetMs + tUpdateMs)

    self:raiseActive()
end

PlaceableHusbandryAnimals.updateVisualAnimals = Utils.overwrittenFunction(PlaceableHusbandryAnimals.updateVisualAnimals, RealisticLivestock_PlaceableHusbandryAnimals.updateVisualAnimals)



--- Handle both RLRM internal calls (table of Animal objects) and external API calls
--- (subTypeIndex, numAnimals, age) used by other mods like HB's CFTA incubator system.
--- The RLRM path queues every animal via the cluster system's pending API and flushes
--- once at the end. The external-signature path delegates to superFunc which lands
--- in RealisticLivestock.addAnimals (also queue-based).
function RealisticLivestock_PlaceableHusbandryAnimals:addAnimals(superFunc, animals, ...)

    if type(animals) == "table" then
        Log:trace("addAnimals: RLRM path - %d animal(s) in table", #animals)
        local clusterSystem = self.spec_husbandryAnimals.clusterSystem

        local ok, err = pcall(function()
            for _, animal in pairs(animals) do
                clusterSystem:addPendingAddCluster(animal)
            end
        end)
        local ok2, err2 = pcall(function() clusterSystem:updateNow() end)

        if not (ok and ok2) then
            Log:error("addAnimals: RLRM path batch failed N=%d queue=%s flush=%s",
                #animals, tostring(err), tostring(err2))
        end
    else
        -- External API signature: addAnimals(subTypeIndex, numAnimals, age)
        local numAnimals, age = ...
        Log:trace("addAnimals: external path - subTypeIndex=%s numAnimals=%s age=%s",
            tostring(animals), tostring(numAnimals), tostring(age))
        superFunc(self, animals, numAnimals, age)
    end

end

PlaceableHusbandryAnimals.addAnimals = Utils.overwrittenFunction(PlaceableHusbandryAnimals.addAnimals, RealisticLivestock_PlaceableHusbandryAnimals.addAnimals)




--- Tail flush at the end of a pen-day-change.
---
--- Births and deaths during the per-animal loop in `onDayChanged` queue mutations
--- via `addPendingAddCluster` / `addPendingRemoveCluster` but do NOT call
--- `updateNow` per-animal. Flushing here once per pen-day-change collapses what
--- would be N publish chains (one per pregnant mother and one per dying animal)
--- into 1 - so `HUSBANDRY_ANIMALS_CHANGED` listeners (food calculators, the
--- in-game menu, third-party mods) recompute once instead of N times per pen-day.
---
--- `pcall` isolates per-pen failure: an exception in `updateNow` would otherwise
--- kill the day-change loop and skip downstream pens. With the wrap, ERROR is
--- logged with pen name + (births, deaths) and execution continues.
---
--- Failure-recovery model: our `updateClusters` override commits queue mutations
--- into `self.animals` before the publish / broadcast / visual tail. So if
--- `updateNow` raises later in the tail (e.g. a foreign-mod listener throwing
--- on the `HUSBANDRY_ANIMALS_CHANGED` publish, or `updateVisualAnimals` throwing):
---   - cluster contents are correct (committed before the failure point)
---   - the publish chain may have only partially fired
---   - `updateVisualAnimals` may not have fired
---   - listeners and visuals resync at the next cluster mutation that runs a
---     fresh flush (sale, move, manual edit, next day-change with deltas)
---
--- Caller must skip `spec.clusterHusbandry:updateVisuals()` when this returns
--- false, to avoid rendering against a partially-published state.
---
--- Atomicity tradeoff vs prior per-mother flush: money commits in `onDayChanged`
--- (auto-sold offspring, dead-animal cash) happen during the per-animal loop and
--- commit per-mother regardless of the tail flush. On flush failure, farm balance
--- is correct but listeners may be momentarily stale. This is a deliberate
--- semantic change vs the prior flush-per-mother behaviour, justified by the
--- N-to-1 reduction in publish-chain firings on heavy mod loadouts. Listener
--- desync window closes at the next cluster mutation. Cluster contents stay
--- correct in either case.
---
--- @param spec table The husbandryAnimals spec (provides `clusterSystem`)
--- @param totalChildren number Count of newborns kept in the pen (excludes auto-sold)
--- @param totalDeaths number `randomDeaths + oldAgeDeaths + lowHealthDeaths + deadParents`
--- @return boolean okFlush True if `updateNow` succeeded (or no-deltas no-op); false on pcall failure
function PlaceableHusbandryAnimals:_flushPenDayChange(spec, totalChildren, totalDeaths)
    if totalChildren == 0 and totalDeaths == 0 then return true end

    local penName = tostring(self.getName and self:getName() or self)
    local tFlushStart = getTimeSec()
    local okFlush, errFlush = pcall(function() spec.clusterSystem:updateNow() end)
    local tFlushMs = (getTimeSec() - tFlushStart) * 1000

    if okFlush then
        Log:debug("onDayChanged tail flush [%s]: updateNow took %.2fms (births=%d deaths=%d)",
            penName, tFlushMs, totalChildren, totalDeaths)
    else
        Log:error("onDayChanged tail flush [%s]: updateNow FAILED after %.2fms: %s (births=%d deaths=%d)",
            penName, tFlushMs, tostring(errFlush), totalChildren, totalDeaths)
    end

    return okFlush
end


function RealisticLivestock_PlaceableHusbandryAnimals:onDayChanged()
    RmSafeUtils.safeCall("PlaceableHusbandryAnimals:onDayChanged", function()

        local minTemp = math.floor(g_currentMission.environment.weather.temperatureUpdater.currentMin)

        local environment = g_currentMission.environment
        local month = environment.currentPeriod + 2
        local currentDayInPeriod = environment.currentDayInPeriod

        if month > 12 then month = month - 12 end

        local daysPerPeriod = environment.daysPerPeriod
        local day = 1 + math.floor((currentDayInPeriod - 1) * (RLConstants.DAYS_PER_MONTH[month] / daysPerPeriod))
        local year = environment.currentYear

        local spec = self.spec_husbandryAnimals
        local animals = spec.clusterSystem:getAnimals()

        -- Per-pen, per-day-change gate for the overcap WARNING in
        -- AnimalReproduction.reproduce. Reset here so successive mothers in
        -- this tick emit at most one WARNING line per pen.
        spec.rlOvercapWarnedThisTick = false

        local totalChildren, deadParents, childrenToSell, childrenToSellMoney, lowHealthDeaths, oldAgeDeaths, randomDeaths, randomDeathsMoney = 0, 0, 0, 0, 0, 0, 0, 0

        -- Per-pen day-change instrumentation: per-iteration timer feeds
        -- nIterated/nSlow/maxAnimal* trackers; outliers (>SLOW_ANIMAL_MS) emit
        -- a TRACE line; per-pen DEBUG summary fires unconditionally at the tail.
        local tLoopStart = getTimeSec()
        local nIterated, nSlow, maxAnimalMs = 0, 0, 0
        local maxAnimalUid, maxAnimalSubType = nil, nil

        for _, animal in ipairs(animals) do

            if self.isServer and RealisticLivestock.testAnimalPrefix ~= nil then
                if not string.startsWith(animal.uniqueId, RealisticLivestock.testAnimalPrefix) then
                    continue
                end
            end

            if animal.monthsSinceLastBirth == nil then
                animal.monthsSinceLastBirth = 0
            end

            if animal.isParent == nil then
                animal.isParent = false
            end

            local tAnimalStart = getTimeSec()
            local a, b, c, d, e, f, g, h = RmSafeUtils.safeAnimalCall(animal, "onDayChanged", function()
                return animal:onDayChanged(spec, self.isServer, day, month, year, currentDayInPeriod, daysPerPeriod)
            end, {0, 0, 0, 0, 0, 0, 0, 0})
            local tAnimalMs = (getTimeSec() - tAnimalStart) * 1000

            nIterated = nIterated + 1
            -- pcall-guard the subType lookup: telemetry must NOT break the per-animal
            -- isolation that safeAnimalCall provides above. On lookup failure we fall
            -- back to subTypeIndex (still uniquely identifying for support reports).
            local function _safeSubTypeName()
                local ok, subType = pcall(function() return animal.getSubType ~= nil and animal:getSubType() or nil end)
                return (ok and subType ~= nil) and subType.name or tostring(animal.subTypeIndex)
            end
            if tAnimalMs > maxAnimalMs then
                maxAnimalMs = tAnimalMs
                maxAnimalUid = animal.uniqueId
                maxAnimalSubType = _safeSubTypeName()
            end
            if tAnimalMs > SLOW_ANIMAL_MS then
                nSlow = nSlow + 1
                Log:trace("onDayChanged SLOW animal: husbandry=%s uniqueId=%s subType=%s took %.2fms",
                    tostring(self.getName and self:getName() or self),
                    tostring(animal.uniqueId),
                    _safeSubTypeName(),
                    tAnimalMs)
            end

            totalChildren = totalChildren + (a or 0)
            deadParents = deadParents + (b or 0)
            childrenToSell = childrenToSell + (c or 0)
            childrenToSellMoney = childrenToSellMoney + (d or 0)
            lowHealthDeaths = lowHealthDeaths + (e or 0)
            oldAgeDeaths = oldAgeDeaths + (f or 0)
            randomDeaths = randomDeaths + (g or 0)
            randomDeathsMoney = randomDeathsMoney + (h or 0)

        end

        local tLoopMs = (getTimeSec() - tLoopStart) * 1000
        local tPostStart = getTimeSec()

        if self.isServer then

            if childrenToSell > 0 and childrenToSellMoney > 0 then
                local farmIndex = spec:getOwnerFarmId()
                local farm = g_farmManager:getFarmById(farmIndex)

                g_currentMission:addMoneyChange(childrenToSellMoney, farmIndex, MoneyType.SOLD_ANIMALS, true)

                if farm ~= nil then
                    farm:changeBalance(childrenToSellMoney, MoneyType.SOLD_ANIMALS)
                end
            end

            if randomDeaths > 0 then

                local farmIndex = spec:getOwnerFarmId()
                local farm = g_farmManager:getFarmById(farmIndex)

                if randomDeathsMoney > 0 then

                    g_currentMission:addMoneyChange(randomDeathsMoney, farmIndex, MoneyType.SOLD_ANIMALS, true)

                    if farm ~= nil then
                        farm:changeBalance(randomDeathsMoney, MoneyType.SOLD_ANIMALS)
                    end

                end

            end

        end

        spec.minTemp = minTemp

        local totalDeaths = randomDeaths + oldAgeDeaths + lowHealthDeaths + deadParents
        local okFlush = self:_flushPenDayChange(spec, totalChildren, totalDeaths)

        if okFlush and (totalChildren > 0 or totalDeaths > 0) then spec.clusterHusbandry:updateVisuals() end

        self:raiseActive()

        if self:getHasUnreadRLMessages() and g_localPlayer ~= nil and g_localPlayer.farmId == self:getOwnerFarmId() then

            g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_CRITICAL, string.format(g_i18n:getText("rl_ui_unreadMessages"), self:getName()))

        end

        local tPostMs = (getTimeSec() - tPostStart) * 1000
        local meanLoopMs = (nIterated > 0) and (tLoopMs / nIterated) or 0

        Log:debug("onDayChanged summary [%s nAnim=%d]: ms_loop=%.2f ms_post=%.2f mean_per_animal=%.3fms slowAnimals=%d worst=%s(%s)@%.2fms births=%d deadParents=%d childrenToSell=%d lowHealth=%d oldAge=%d randomDeaths=%d",
            tostring(self.getName and self:getName() or self),
            nIterated,
            tLoopMs, tPostMs, meanLoopMs,
            nSlow,
            tostring(maxAnimalUid),
            tostring(maxAnimalSubType),
            maxAnimalMs,
            totalChildren, deadParents, childrenToSell,
            lowHealthDeaths, oldAgeDeaths, randomDeaths)

    end)
end

PlaceableHusbandryAnimals.onDayChanged = Utils.overwrittenFunction(PlaceableHusbandryAnimals.onDayChanged, RealisticLivestock_PlaceableHusbandryAnimals.onDayChanged)


--- Advance every animal in this pen by one month and bill the accumulated treatment fee.
---
--- Wired by `Utils.overwrittenFunction` and never calls its base: the per-animal model owns ageing
--- and reproduction, so the cluster-level tick must not also run.
---
--- The fee is charged with `addMoney`, which is the call that moves a farm balance. `addMoneyChange`
--- produces the HUD entry and the notification but leaves the balance untouched, so a cost billed
--- through it is free. Passing `addChange` and `forceShowChange` keeps the player-visible half - one
--- HUD entry plus its broadcast notification - alongside the balance movement.
---
--- The amount is NEGATED because the amount is signed and a cost must be negative; positive renders
--- the charge to the player as income.
---
--- The charge is aggregated PER PEN, not per animal: a player treating six animals sees one money
--- entry, which is what the DEBUG line below exists to reconcile against the animals that produced
--- it.
---
--- The owner farm id is checked against the reserved ids before charging. `addMoney` refuses farm 0
--- with an error plus a callstack rather than returning quietly, and farm 0 is REACHABLE - deleting
--- a farm in multiplayer reassigns its placeables to the spectator farm, so a surviving pen holding
--- a treated animal would emit two error lines every period forever. The test is on the ID, not on
--- the lookup: resolving farm 0 returns the spectator farm OBJECT, non-nil, so a nil-check does not
--- catch it.
---@param _ function Overwritten-function predecessor; deliberately unused.
function RealisticLivestock_PlaceableHusbandryAnimals:onPeriodChanged(_)
    RmSafeUtils.safeCall("PlaceableHusbandryAnimals:onPeriodChanged", function()

        local penName = tostring(self.getName and self:getName() or self)

        if self.isServer then

            Log:trace("onPeriodChanged [%s]: server branch - disease progression, treatment billing and transmission", penName)

            local animals = self.spec_husbandryAnimals.clusterSystem:getClusters()
            local totalTreatmentCost = 0

            for _, animal in pairs(animals) do
                if RealisticLivestock.testAnimalPrefix ~= nil then
                    if not string.startsWith(animal.uniqueId, RealisticLivestock.testAnimalPrefix) then
                        continue
                    end
                end
                local treatmentCost = RmSafeUtils.safeAnimalCall(animal, "onPeriodChanged", function()
                    return animal:onPeriodChanged()
                end, {0})
                totalTreatmentCost = totalTreatmentCost + (treatmentCost or 0)
            end

            if totalTreatmentCost > 0 then

                local ownerFarmId = self.spec_husbandryAnimals:getOwnerFarmId()

                if type(ownerFarmId) ~= "number" or ownerFarmId <= 0 or ownerFarmId > FarmManager.MAX_NUM_FARMS then
                    Log:warning("onPeriodChanged [%s]: skipping treatment charge of %s - owner farm id %s is not a real farm",
                        penName, tostring(totalTreatmentCost), tostring(ownerFarmId))
                else
                    g_currentMission:addMoney(0 - totalTreatmentCost, ownerFarmId, MoneyType.MEDICINE, true, true)
                    Log:debug("onPeriodChanged [%s]: charged treatment fee %s to farmId=%s",
                        penName, tostring(totalTreatmentCost), tostring(ownerFarmId))
                end

            else
                Log:trace("onPeriodChanged [%s]: no treatment fee accrued this period", penName)
            end

            if RealisticLivestock.testAnimalPrefix == nil then
                g_diseaseManager:calculateTransmission(animals, penName)
            else
                Log:trace("onPeriodChanged [%s]: test-prefix run - skipping disease transmission", penName)
            end

        else

            Log:trace("onPeriodChanged [%s]: client branch - recovery only, no billing or transmission", penName)

            -- MP client branch: recovery (monthsSinceLastBirth) is
            -- deterministic and unsynced, so a client advances it locally in
            -- lockstep with the server -- the same reason aging runs client-side
            -- in onDayChanged (no server guard around its per-animal loop).
            -- Recovery ONLY: disease progression, treatment-cost money, and
            -- disease transmission stay server-authoritative in the branch above.
            -- No testAnimalPrefix filter (nil on clients; mirrors onDayChanged,
            -- which gates that filter on self.isServer).
            local animals = self.spec_husbandryAnimals.clusterSystem:getClusters()
            local nAdvanced = 0

            for _, animal in pairs(animals) do
                RmSafeUtils.safeAnimalCall(animal, "advanceRecoveryPeriod", function()
                    animal:advanceRecoveryPeriod()
                end)
                nAdvanced = nAdvanced + 1
            end

            Log:debug("onPeriodChanged client recovery [%s]: advanced monthsSinceLastBirth for %d animal(s)",
                penName, nAdvanced)

        end

    end)
end

PlaceableHusbandryAnimals.onPeriodChanged = Utils.overwrittenFunction(PlaceableHusbandryAnimals.onPeriodChanged, RealisticLivestock_PlaceableHusbandryAnimals.onPeriodChanged)