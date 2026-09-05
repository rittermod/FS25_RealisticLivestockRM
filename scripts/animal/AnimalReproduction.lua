--[[
    AnimalReproduction.lua
    Reproduction, fertility, and insemination logic extracted from Animal.lua.

    Provides helper functions for pregnancy creation, birth processing,
    fertility management, and insemination. Animal.lua retains one-liner
    delegates that route to this module.

    Sourced BEFORE RealisticLivestock_Animal.lua (same pattern as AnimalHorse).

    NOTE: Serialization (writeStream/readStream) and XML load/save remain
    in Animal.lua. Reproduction state fields are initialized in the constructor
    and serialized as part of the MP protocol.
]]

AnimalReproduction = {}

local Log = RmLogging.getLogger("RLRM")


-- =============================================================================
-- LOCAL HELPERS (not exposed on module table)
-- =============================================================================

local function sortChildSellPrices(a, b)
    return a.sellPrice > b.sellPrice
end


--- Resolve pending insemination: attempt pregnancy from stored semen, broadcast result.
--- Always clears animal.insemination regardless of success/fail.
--- @param animal table Animal instance
--- @param month number Current month
--- @param year number Current year
local function resolveInsemination(animal, month, year)
    local insemination = animal.insemination

    if insemination == nil or g_server == nil then
        animal.insemination = nil
        return
    end

    Log:trace("resolveInsemination: animal=%s insemination from %s/%s",
        animal.uniqueId or "?", tostring(insemination.farmId), tostring(insemination.uniqueId))

    local fertility = animal.genetics.fertility
    local childNum = animal:generateRandomOffspring()

    if childNum > 0
        and math.random() >= (2 - fertility) * 0.25
        and math.random() <= insemination.success * (math.random(80, 120) / 100)
    then
        animal:addMessage("INSEMINATION_SUCCESS")
        g_server:broadcastEvent(AnimalInseminationResultEvent.new(
            animal.clusterSystem.owner, animal, true))

        animal:createPregnancy(childNum, month, year, {
            ["uniqueId"] = string.format("%s %s %s",
                RLConstants.AREA_CODES[insemination.country].code,
                insemination.farmId, insemination.uniqueId),
            ["metabolism"] = insemination.genetics.metabolism,
            ["quality"] = insemination.genetics.quality,
            ["health"] = insemination.genetics.health,
            ["fertility"] = insemination.genetics.fertility,
            ["productivity"] = insemination.genetics.productivity,
        })

        Log:trace("  insemination success, pregnancy created")
    else
        animal:addMessage("INSEMINATION_FAIL")
        g_server:broadcastEvent(AnimalInseminationResultEvent.new(
            animal.clusterSystem.owner, animal, false))

        Log:trace("  insemination failed (childNum=%d)", childNum)
    end

    animal.insemination = nil
end


--- Advance pregnancy or attempt natural conception.
--- Handles pregnancy state cleanup, reproduction meter advancement, birth when
--- meter >= 100, and natural conception for eligible non-pregnant females.
--- The orphaned-pregnancy cleanup branch delegates to
--- AnimalReproduction._clearOrphanedPregnancy so the four-field invariant
--- (isPregnant <=> pregnancy ~= nil, plus impregnatedBy + reproduction reset)
--- is restored in one place; no inline cleanup remains here.
--- @param animal table Animal instance
--- @param spec table|nil Husbandry spec (for maxNumAnimals, getNumOfAnimals)
--- @param day number Current day
--- @param month number Current month
--- @param year number Current year
--- @param isSaleAnimal boolean Whether this is a sale animal
--- @return number children Count of offspring born
--- @return number deadAnimals 1 if parent died during birth, 0 otherwise
--- @return number childrenSold Count of offspring auto-sold (no space)
--- @return number childrenSoldAmount Total money from auto-sold offspring
local function advancePregnancy(animal, spec, day, month, year, isSaleAnimal)
    local children = 0
    local deadAnimals = 0
    local childrenSold = 0
    local childrenSoldAmount = 0

    if not isSaleAnimal and animal.clusterSystem == nil then
        return children, deadAnimals, childrenSold, childrenSoldAmount
    end

    -- Orphaned pregnancy state cleanup: reproduction > 0 but no usable pregnancy data.
    -- Delegate to the shared helper so the canonical four-field clear runs
    -- (pregnancy + impregnatedBy + isPregnant + reproduction). orphanReason is
    -- computed at the call site so the debug log carries which subcondition fired.
    if animal.reproduction > 0 and (animal.pregnancy == nil or animal.pregnancy.pregnancies == nil) then
        local orphanReason = (animal.pregnancy == nil) and "pregnancy-nil" or "pregnancies-nil"
        AnimalReproduction._clearOrphanedPregnancy(animal, orphanReason)
    end

    if animal.isPregnant then
        animal:changeReproduction(animal:getReproductionDelta())

        Log:trace("advancePregnancy: animal=%s pregnant, reproduction=%d",
            animal.uniqueId or "?", animal.reproduction)

        if animal.reproduction >= 100 and g_server ~= nil and animal.pregnancy ~= nil and spec ~= nil then
            -- Fill in missing impregnatedBy data (defensive)
            if animal.impregnatedBy == nil then
                animal.impregnatedBy = {
                    uniqueId = "-1",
                    metabolism = animal.genetics.metabolism,
                    quality = animal.genetics.quality,
                    health = animal.genetics.health,
                    fertility = animal.genetics.fertility,
                    productivity = animal.genetics.productivity or 1.0,
                }
            end

            if animal.impregnatedBy.uniqueId == nil then animal.impregnatedBy.uniqueId = "-1" end
            if animal.impregnatedBy.metabolism == nil then animal.impregnatedBy.metabolism = animal.genetics.metabolism end
            if animal.impregnatedBy.quality == nil then animal.impregnatedBy.quality = animal.genetics.quality end
            if animal.impregnatedBy.health == nil then animal.impregnatedBy.health = animal.genetics.health end
            if animal.impregnatedBy.fertility == nil then animal.impregnatedBy.fertility = animal.genetics.fertility end
            if animal.impregnatedBy.productivity == nil then
                animal.impregnatedBy.productivity = animal.genetics.productivity or 1.0
                Log:trace("advancePregnancy: backfilled impregnatedBy.productivity for animal %s (genetics.productivity was %s)",
                    animal.uniqueId or "?", tostring(animal.genetics.productivity))
            end

            animal.isPregnant = false

            local parentDied = false
            children, parentDied, childrenSold, childrenSoldAmount =
                animal:reproduce(spec, day, month, year, isSaleAnimal)

            animal.reproduction = 0

            if parentDied then deadAnimals = 1 end
            animal.impregnatedBy = nil
            animal.pregnancy = nil

            Log:trace("  birth complete: children=%d parentDied=%s sold=%d",
                children, tostring(parentDied), childrenSold)
        end

    elseif g_server ~= nil and not isSaleAnimal and animal:getCanReproduce() then
        -- Natural conception attempt
        local fertility = animal.genetics.fertility
        local childNum = animal:generateRandomOffspring()

        Log:trace("advancePregnancy: animal=%s natural conception attempt fertility=%.2f childNum=%d",
            animal.uniqueId or "?", fertility, childNum)

        if math.random() >= (2 - fertility) * 0.5 and childNum > 0 then
            animal:createPregnancy(childNum, month, year)
            Log:trace("  natural conception success")
        end
    end

    return children, deadAnimals, childrenSold, childrenSoldAmount
end


-- =============================================================================
-- PREGNANCY STATE CLEANUP
-- =============================================================================

--- Clear the four pregnancy-state fields on an animal that landed in the
--- orphaned state (reproduction > 0 but no usable pregnancy data).
--- Mirrors the canonical post-birth clear at AnimalBirthEvent's parent-clear
--- block: pregnancy + impregnatedBy + isPregnant + reproduction reset together.
---
--- Restoring the invariant `isPregnant <=> pregnancy ~= nil` at the source
--- prevents the MP wire-side compound-bool guard
--- (streamWriteBool(streamId, animal.isPregnant and animal.pregnancy ~= nil))
--- from ever needing to defend against the orphaned state. Receiver and sender
--- agree on isPregnant because the orphaned window no longer exists.
---
--- Module-level on purpose: called from this file's local advancePregnancy
--- (one consumer in-file) AND from AnimalSystem:createNewSaleAnimal (the
--- second consumer in another file). Both call sites delegate; no inline
--- four-field assignment remains anywhere in the codebase.
---
--- The orphanReason parameter is forwarded to the debug log untouched (the
--- helper does not re-evaluate which subcondition fired); callers compute it
--- from the cleanup-condition branch they took. Keeps the helper signature
--- minimal (animal, orphanReason) so unit tests stay simple.
--- @param animal table Animal instance with the four pregnancy-state fields
--- @param orphanReason string Triage tag for which subcondition fired
---   ("pregnancy-nil" | "pregnancies-nil" | call-site-specific variant)
function AnimalReproduction._clearOrphanedPregnancy(animal, orphanReason)
    local wasPregnant = animal.isPregnant
    local wasImpregnatedByPresent = animal.impregnatedBy ~= nil

    animal.pregnancy = nil
    animal.reproduction = 0
    animal.isPregnant = false
    animal.impregnatedBy = nil

    Log:debug("AnimalReproduction._clearOrphanedPregnancy: cleared orphaned pregnancy state for animal farmId=%s uniqueId=%s country=%s isPregnantWasTrue=%s orphanReason=%s impregnatedByPresent=%s",
        tostring(animal.farmId),
        tostring(animal.uniqueId),
        tostring(animal.birthday and animal.birthday.country),
        tostring(wasPregnant),
        tostring(orphanReason),
        tostring(wasImpregnatedByPresent))
end


-- =============================================================================
-- FERTILITY GETTERS/SETTERS (from Animal.lua)
-- =============================================================================

--- Get reproduction progress as a 0-1 factor.
--- @param animal table Animal instance
--- @return number factor Reproduction progress (0.0-1.0)
function AnimalReproduction.getReproductionFactor(animal)
    return animal.reproduction / 100
end

--- Check if this animal's subtype supports reproduction.
--- @param animal table Animal instance
--- @return boolean supportsReproduction
function AnimalReproduction.getSupportsReproduction(animal)
    return animal:getSubType().supportsReproduction
end

--- Change reproduction meter by delta, clamped to 0-100.
--- Minimum effective delta is 1 (math.max).
--- @param animal table Animal instance
--- @param delta number Amount to change reproduction by
function AnimalReproduction.changeReproduction(animal, delta)
    animal.reproduction = math.clamp((math.floor((animal.reproduction + math.max(delta, 1)) * 100)/100), 0, 100)
end

--- Calculate the daily reproduction delta based on gestation duration.
--- Uses pregnancy-specific duration if pregnant, otherwise subtype default.
--- Formula: floor((100 / duration) / daysPerPeriod)
--- @param animal table Animal instance
--- @return number delta Daily reproduction delta (0 if duration is 0)
function AnimalReproduction.getReproductionDelta(animal)
    local duration

    if animal.pregnancy ~= nil then duration = animal.pregnancy.duration end

    if duration == nil then
        local subType = animal:getSubType()
        duration = subType.reproductionDurationMonth
    end

    if duration > 0 then
        return math.floor(((100 / duration) / g_currentMission.environment.daysPerPeriod)*100)/100
    end

    return 0
end

--- Check if this animal can naturally reproduce.
--- Requires: female gender, not castrated, sufficient age, health above threshold,
--- male of compatible type in same pen, and past recovery period.
--- @param animal table Animal instance
--- @return boolean canReproduce
function AnimalReproduction.getCanReproduce(animal)
    if animal.gender ~= "female" then return false end

    if animal.isPregnant or animal.pregnancy ~= nil then return true end

    local subType = animal:getSubType()

    if not subType.supportsReproduction or animal.clusterSystem == nil then return false end

    local canReproduce = RealisticLivestock.hasMaleAnimalInPen(
        animal.clusterSystem.owner.spec_husbandryAnimals, animal.subType, animal)
        and (animal.monthsSinceLastBirth > 2 or not animal.isParent)

    if animal:getHealthFactor() >= subType.reproductionMinHealth then
        canReproduce = canReproduce and animal.age >= subType.reproductionMinAgeMonth
    else
        canReproduce = false
    end

    return canReproduce
end


-- =============================================================================
-- CORE REPRODUCTION METHODS (from Animal.lua)
-- =============================================================================

--- Create a pregnancy for an animal with the given number of offspring.
--- Selects a father from eligible males in pen (or uses defaults if father provided).
--- Creates child Animal objects with inherited genetics via BreedingMath.
--- Broadcasts AnimalPregnancyEvent to clients.
--- ASSUMES: called server-side (broadcasts events via g_server)
--- @param animal table Animal instance (female)
--- @param childNum number Number of offspring to create
--- @param month number Current month (1-12)
--- @param year number Current year
--- @param father table|nil Optional father data {uniqueId, metabolism, quality, health, fertility, productivity}.
---   The productivity field is coalesced to 1.0 at the impregnatedBy-assignment boundary regardless
---   of caller, covering both the eligible-father selection branch (where the selected pig/horse male
---   has genetics.productivity == nil) and resolveInsemination's explicit-father path (where AI-straw
---   semen for pigs/horses has insemination.genetics.productivity == nil) uniformly.
function AnimalReproduction.createPregnancy(animal, childNum, month, year, father)

    local fertility = animal.genetics.fertility

    animal.isPregnant = true

    local fatherSubTypeIndex

    if father == nil then

        father = {
            uniqueId = "-1",
            metabolism = 1.0,
            quality = 1.0,
            health = 1.0,
            fertility = 1.0,
            productivity = 1.0,
        }

        local eligibleFathers = {}

        -- Collect all eligible fathers
        for _, otherAnimal in pairs(animal.clusterSystem:getAnimals()) do

            if otherAnimal.gender ~= "male" or otherAnimal.isCastrated or otherAnimal.genetics.fertility <= 0 or otherAnimal:getIdentifiers() == animal.fatherId then continue end

            if otherAnimal.subType == "BULL_WATERBUFFALO" and animal.subType ~= "COW_WATERBUFFALO" then continue end
            if otherAnimal.subType == "RAM_GOAT" and animal.subType ~= "GOAT" then continue end
            if animal.subType == "COW_WATERBUFFALO" and otherAnimal.subType ~= "BULL_WATERBUFFALO" then continue end
            if animal.subType == "GOAT" and otherAnimal.subType ~= "RAM_GOAT" then continue end

            -- Bridge breeding compatibility check
            if RLMapBridge.isBreedingCompatible(otherAnimal.subType, animal.subType) == false then
                Log:debug("createPregnancy: Bridge says '%s' incompatible with '%s', skipping father",
                    otherAnimal.subType, animal.subType)
                continue
            end

            local animalType = otherAnimal.animalTypeIndex

            local animalSubType = otherAnimal:getSubType()
            local bridgeMaxAge = RLMapBridge.getMaxFertilityAge(otherAnimal.subType)
            local maxFertilityMonth = bridgeMaxAge
                or (animalType == AnimalType.COW and 132)
                or (animalType == AnimalType.SHEEP and 72)
                or (animalType == AnimalType.HORSE and 300)
                or (animalType == AnimalType.CHICKEN and 72)
                or (animalType == AnimalType.PIG and 48)
                or 120

            -- Rooster siring is an absolute 72-month cap; the fertility multiplier
            -- must not lift a high-fertility rooster past it.
            if animalType ~= AnimalType.CHICKEN then
                maxFertilityMonth = maxFertilityMonth * otherAnimal.genetics.fertility
            end

            if animalSubType.reproductionMinAgeMonth ~= nil
                and otherAnimal:getAge() >= animalSubType.reproductionMinAgeMonth
                and otherAnimal:getAge() < maxFertilityMonth
            then
                table.insert(eligibleFathers, otherAnimal)
            end

        end

        -- Random selection from eligible fathers
        if #eligibleFathers > 0 then
            local selectedFather = eligibleFathers[math.random(1, #eligibleFathers)]

            fatherSubTypeIndex = selectedFather.subTypeIndex

            father.uniqueId = selectedFather:getIdentifiers()
            father.metabolism = selectedFather.genetics.metabolism
            father.quality = selectedFather.genetics.quality
            father.health = selectedFather.genetics.health
            father.fertility = selectedFather.genetics.fertility
            father.productivity = selectedFather.genetics.productivity
            father.animal = selectedFather

            Log:trace("createPregnancy: selected father %s (subType=%s) genetics m=%s q=%s h=%s f=%s p=%s",
                father.uniqueId, selectedFather.subType or "?",
                tostring(father.metabolism), tostring(father.quality), tostring(father.health),
                tostring(father.fertility), tostring(father.productivity))
        else
            Log:trace("createPregnancy: no eligible father found, using defaults")
        end

    end

    -- Coalesce productivity to 1.0 for paternal-snapshot field. genetics.productivity
    -- is nil for PIG and HORSE; without this both eligible-father selection and
    -- resolveInsemination's explicit-father path would assign nil here, crashing
    -- AnimalPregnancyEvent:writeStream's streamWriteFloat32 call.
    father.productivity = father.productivity or 1.0

    animal.impregnatedBy = father
    animal.reproduction = 0

    animal:changeReproduction(animal:getReproductionDelta())

    local genetics = animal.genetics

    local mDiseases, fDiseases = animal.diseases, father.animal ~= nil and father.animal.diseases or {}

    local diseases = {}

    for _, disease in pairs(mDiseases) do table.insert(diseases, { ["parent"] = father.animal, ["disease"] = disease }) end

    for _, disease in pairs(fDiseases) do

        local hasDisease = false

        for _, mDisease in pairs(mDiseases) do
            if mDisease.title == disease.title then
                hasDisease = true
                break
            end
        end

        if not hasDisease then table.insert(diseases, { ["parent"] = animal, ["disease"] = disease }) end

    end


    local children = {}
    local hasMale, hasFemale = false, false


    for i = 1, childNum do


        local gender = math.random() >= 0.5 and "male" or "female"
        local subTypeIndex

        if fatherSubTypeIndex ~= nil and math.random() >= 0.5 then

            subTypeIndex = fatherSubTypeIndex + (gender == "male" and 0 or -1)

        else

            subTypeIndex = animal.subTypeIndex + (gender == "male" and 1 or 0)

        end

        -- Validate subtype index: must be correct gender and same animal type.
        -- If index arithmetic produced a wrong result (e.g. bridge subtypes with non-adjacent indices),
        -- fall back to breed-aware search: prefer same breed + gender, then any gender match in type.
        local animalSystem = g_currentMission.animalSystem
        local candidateSubType = animalSystem:getSubTypeByIndex(subTypeIndex)

        if candidateSubType == nil or candidateSubType.gender ~= gender or candidateSubType.typeIndex ~= animal.animalTypeIndex then
            local animalTypeObj = animalSystem:getTypeByIndex(animal.animalTypeIndex)
            local breedFallback = nil
            local genderFallback = nil

            if animalTypeObj ~= nil then
                -- First pass: find matching breed + gender (preferred)
                -- Second pass: any matching gender (fallback)
                for _, stIndex in pairs(animalTypeObj.subTypes) do
                    local st = animalSystem:getSubTypeByIndex(stIndex)
                    if st ~= nil and st.gender == gender then
                        if genderFallback == nil then
                            genderFallback = stIndex
                        end
                        if st.breed == animal.breed then
                            breedFallback = stIndex
                            break
                        end
                    end
                end
            end

            local fallbackIndex = breedFallback or genderFallback

            if fallbackIndex ~= nil then
                Log:debug("createPregnancy: Offspring subtype fallback for gender '%s' breed '%s': index %d -> %d (type=%s, breedMatch=%s)",
                    gender, animal.breed or "?", subTypeIndex, fallbackIndex, animalTypeObj and animalTypeObj.name or "?",
                    tostring(breedFallback ~= nil))
                subTypeIndex = fallbackIndex
            else
                Log:debug("createPregnancy: No fallback subtype found for gender '%s' in type %d, keeping index %d",
                    gender, animal.animalTypeIndex, subTypeIndex)
            end
        else
            Log:debug("createPregnancy: Offspring subtype index %d valid (gender=%s, type=%s)",
                subTypeIndex, gender, candidateSubType.name or "?")
        end

        local resolvedSubType = animalSystem:getSubTypeByIndex(subTypeIndex)
        local childBreed = resolvedSubType and resolvedSubType.breed or "?"
        local childSubTypeName = resolvedSubType and resolvedSubType.name or "?"
        local fatherBreed = father.animal and father.animal.breed or "?"
        local fatherSubTypeName = father.animal and father.animal.subType or "?"
        local fatherIdx = fatherSubTypeIndex or -1

        Log:debug("createPregnancy child[%d]: gender=%s, mother=%s(idx=%d) breed=%s, father=%s(idx=%d) breed=%s -> child=%s(idx=%d) breed=%s",
            i, gender,
            animal.subType, animal.subTypeIndex, animal.breed or "?",
            fatherSubTypeName, fatherIdx, fatherBreed,
            childSubTypeName, subTypeIndex, childBreed)

        -- Breed switch detection: warn if child breed differs from BOTH parents
        if childBreed ~= "?" and childBreed ~= (animal.breed or "") and childBreed ~= fatherBreed then
            Log:warning("Breed switch in offspring: mother=%s father=%s child got %s (idx=%d %s)",
                animal.breed or "?", fatherBreed, childBreed, subTypeIndex, childSubTypeName)
        end

        local child = Animal.new({
            age = -1, health = 100, gender = gender,
            subTypeIndex = subTypeIndex,
            motherId = animal:getIdentifiers(),
            fatherId = father.uniqueId,
        })

        -- Use BreedingMath for Gaussian genetic inheritance (allows offspring to exceed parent ranges)
        local metabolism = BreedingMath.breedOffspring(genetics.metabolism, father.metabolism, { sd = BreedingMath.SD_CONST })
        local quality = BreedingMath.breedOffspring(genetics.quality, father.quality, { sd = BreedingMath.SD_CONST })
        local healthGenetics = BreedingMath.breedOffspring(genetics.health, father.health, { sd = BreedingMath.SD_CONST })

        local childFertility = 0

        if math.random() > 0.001 then
            childFertility = BreedingMath.breedOffspring(genetics.fertility, father.fertility, { sd = BreedingMath.SD_CONST })
        end

        local productivity = nil

        if genetics.productivity ~= nil then
            productivity = BreedingMath.breedOffspring(genetics.productivity, father.productivity or 1, { sd = BreedingMath.SD_CONST })
        end


        child:setGenetics({
            ["metabolism"] = metabolism,
            ["quality"] = quality,
            ["health"] = healthGenetics,
            ["fertility"] = childFertility,
            ["productivity"] = productivity,
        })


        for _, disease in pairs(diseases) do

            disease.disease:affectReproduction(child, disease.parent)

        end


        table.insert(children, child)

        if gender == "male" then
            hasMale = true
        else
            hasFemale = true
        end

    end

    -- Freemartin condition: when a cow has mixed-gender twins, female calves
    -- have 97% chance of fertility=0 (biological detail)
    if animal.animalTypeIndex == AnimalType.COW and hasMale and hasFemale then

        for _, child in pairs(children) do

            if child.gender == "female" and math.random() >= 0.03 then
                child.genetics.fertility = 0
                Log:debug("createPregnancy: Freemartin condition applied to child %s (gender=%s, fertility set to 0)", child.uniqueId or "?", child.gender)
            end

        end

    end


    local reproductionDuration = animal:getSubType().reproductionDurationMonth

    if math.random() >= 0.99 then

        if math.random() >= 0.95 then
            reproductionDuration = reproductionDuration + (math.random() >= 0.75 and -2 or 2)
        else
            reproductionDuration = reproductionDuration + (math.random() >= 0.85 and -1 or 1)
        end

        reproductionDuration = math.clamp(reproductionDuration, 2, 12)

    end

    local expectedYear = year + math.floor(reproductionDuration / 12)
    local expectedMonth = month + (reproductionDuration % 12)

    while expectedMonth > 12 do
        expectedMonth = expectedMonth - 12
        expectedYear = expectedYear + 1
    end

    local expectedDay = math.random(1, RLConstants.DAYS_PER_MONTH[expectedMonth])


    animal.pregnancy = {
        ["duration"] = reproductionDuration,
        ["expected"] = {
            ["day"] = expectedDay,
            ["month"] = expectedMonth,
            ["year"] = expectedYear,
        },
        ["pregnancies"] = children,
    }

    Log:trace("createPregnancy: animal=%s children=%d expected=%d/%d/%d duration=%d",
        animal.uniqueId or "?", childNum, expectedDay, expectedMonth, expectedYear, reproductionDuration)

    g_server:broadcastEvent(AnimalPregnancyEvent.new(
        animal.clusterSystem ~= nil and animal.clusterSystem.owner or nil, animal))

end


--- Generate random offspring count based on animal's fertility and type pregnancy data.
--- @param animal table Animal instance
--- @return number count Number of offspring (0 if fertility check fails)
function AnimalReproduction.generateRandomOffspring(animal)

    local animalSystem = g_currentMission.animalSystem
    local animalType = animalSystem:getTypeByIndex(animal.animalTypeIndex)

    local fertility = animal.genetics.fertility

    local fertilityValue = fertility * (animalType.fertility:get(animal.age) / 100)

    if math.random() >= fertilityValue then return 0 end

    local factor = 0.75 + fertility / 4

    if math.random() >= 0.25 then return animalType.pregnancy.average end

    local amount = animalType.pregnancy.get(math.random() * factor)

    return amount

end


--- Process birth for a pregnant animal whose reproduction meter reached 100.
--- Handles infant mortality, free slot calculations, auto-selling excess offspring,
--- farm stats, and parent death chance.
--- ASSUMES: called server-side (broadcasts events via g_server)
--- @param animal table Animal instance (mother)
--- @param spec table Husbandry spec (for maxNumAnimals, getNumOfAnimals, getOwnerFarmId)
--- @param day number Current day
--- @param month number Current month
--- @param year number Current year
--- @param isSaleAnimal boolean Whether this is a sale animal
--- @return number childNum Count of surviving offspring added to pen
--- @return boolean parentDied Whether the parent died during birth
--- @return number animalsToSell Count of offspring auto-sold
--- @return number totalAnimalPrice Total money from auto-sold offspring
function AnimalReproduction.reproduce(animal, spec, day, month, year, isSaleAnimal)

    if animal.pregnancy == nil or animal.pregnancy.pregnancies == nil then return 0, false, 0, 0 end

    local pregnancies = animal.pregnancy.pregnancies

    -- Sample the cluster-system pending queues so successive mothers in the
    -- same onDayChanged tick see each other's already-queued newborns.
    -- Without this, every mother reads the same pre-loop getNumOfAnimals()
    -- snapshot and the pen overflows past maxNumAnimals.
    local pendingAdds, pendingRemoves, pendingDelta = 0, 0, 0
    if not isSaleAnimal and animal.clusterSystem ~= nil
        and type(animal.clusterSystem.getPendingDelta) == "function" then
        pendingAdds, pendingRemoves, pendingDelta = animal.clusterSystem:getPendingDelta()
    end

    local freeSlots = isSaleAnimal and 100
        or (spec.maxNumAnimals - (spec:getNumOfAnimals() + pendingDelta))
    local childNum = #pregnancies
    local animalsToSell = 0
    local subType = animal:getSubType()
    local animalType = animal:getAnimalTypeIndex()
    local parentDied = false

    Log:trace("reproduce freeSlots: maxNum=%d numOf=%d pendingDelta=%d -> freeSlots=%d",
        spec.maxNumAnimals, spec:getNumOfAnimals(), pendingDelta, freeSlots)
    Log:trace("reproduce: animal=%s childNum=%d freeSlots=%d isSaleAnimal=%s",
        animal.uniqueId or "?", childNum, freeSlots, tostring(isSaleAnimal))

    if pendingDelta ~= 0 then
        local motherKey = RLAnimalUtil.toKey(
            animal.farmId or "?",
            animal.uniqueId or "?",
            (animal.birthday and animal.birthday.country) or "?")
        Log:debug("reproduce: pending-delta path active: motherKey=%s delta=%d",
            motherKey, pendingDelta)
    end

    -- Rate-gated overcap WARNING (once per pen per day-change). Legacy saves
    -- can enter the day-change already past maxNumAnimals; the clamp below
    -- prevents further childNum corruption. Gate is cleared at the start of
    -- PlaceableHusbandryAnimals:onDayChanged (spec.rlOvercapWarnedThisTick).
    if not isSaleAnimal
        and spec:getNumOfAnimals() > spec.maxNumAnimals
        and spec.rlOvercapWarnedThisTick ~= true then
        spec.rlOvercapWarnedThisTick = true
        local penName = (animal.clusterSystem ~= nil
            and animal.clusterSystem.owner ~= nil
            and type(animal.clusterSystem.owner.getName) == "function")
            and animal.clusterSystem.owner:getName() or "?"
        local motherKey = RLAnimalUtil.toKey(
            animal.farmId or "?",
            animal.uniqueId or "?",
            (animal.birthday and animal.birthday.country) or "?")
        Log:warning("reproduce: pen %s entered day-change overcap (numOf=%d > max=%d) mother=%s; preventing further overflow",
            tostring(penName), spec:getNumOfAnimals(), spec.maxNumAnimals,
            tostring(motherKey))
    end

    if freeSlots - childNum < 0 then
        animalsToSell = childNum - freeSlots
    end

    -- Clamp animalsToSell to [0, litterSize] so a negative freeSlots from a
    -- legacy-overshoot save cannot drive childNum negative (root cause for
    -- the negative accumulator symptom).
    local clampedSell = math.max(0, math.min(animalsToSell, #pregnancies))
    if clampedSell ~= animalsToSell then
        Log:debug("reproduce: animalsToSell clamped from %d to %d (litterSize=%d)",
            animalsToSell, clampedSell, #pregnancies)
    end
    animalsToSell = clampedSell

    animal.monthsSinceLastBirth = 0

    if childNum > 0 then
        animal.isParent = true
        if animalType == AnimalType.COW or animal.subType == "GOAT" then animal.isLactating = true end
    end

    childNum = childNum - animalsToSell


    local fatherFull

    if not isSaleAnimal and animal.impregnatedBy ~= nil and animal.impregnatedBy.uniqueId ~= nil and animal.impregnatedBy.uniqueId ~= "-1" then

        local placeables = g_currentMission.placeableSystem.placeables
        local motherTypeIndex = animal.animalTypeIndex
        local crossSpeciesSkips = 0

        for _, placeable in ipairs(placeables) do

            if placeable.spec_husbandryAnimals == nil and placeable.spec_livestockTrailer == nil then continue end

            local clusterSystem = nil

            if placeable.spec_husbandryAnimals ~= nil then
                clusterSystem = placeable.spec_husbandryAnimals.clusterSystem
            elseif placeable.spec_livestockTrailer ~= nil then
                clusterSystem = placeable.spec_livestockTrailer.clusterSystem
            end

            if clusterSystem == nil then continue end

            local animals = clusterSystem:getAnimals()
            for _, otherAnimal in ipairs(animals) do
                -- Identity guard: identifiers are not species-unique because
                -- FarmStats keeps per-species id counters, so the Nth sheep and the Nth
                -- chicken on the same farm can share the (country,farmId,uniqueId) triple.
                -- Skip cross-species matches before the identifier compare so the wrong
                -- species cannot be selected as fatherFull and absorb childInfo via the
                -- table.insert below.
                if otherAnimal.animalTypeIndex ~= motherTypeIndex then
                    if otherAnimal:getIdentifiers() == animal.impregnatedBy.uniqueId then
                        crossSpeciesSkips = crossSpeciesSkips + 1
                        Log:debug("reproduce: fatherFull lookup skipped cross-species collision (motherType=%s otherType=%s identifiers=%s)",
                            tostring(motherTypeIndex), tostring(otherAnimal.animalTypeIndex), tostring(animal.impregnatedBy.uniqueId))
                    end
                    continue
                end

                if otherAnimal:getIdentifiers() ~= animal.impregnatedBy.uniqueId then continue end

                fatherFull = otherAnimal
                break
            end

            if fatherFull ~= nil then break end

        end

        Log:trace("reproduce: fatherFull lookup result motherType=%s impregnatedBy=%s found=%s crossSpeciesSkips=%d",
            tostring(motherTypeIndex), tostring(animal.impregnatedBy.uniqueId),
            tostring(fatherFull ~= nil), crossSpeciesSkips)

    end

    if fatherFull ~= nil then fatherFull.isParent = true end


    local sellPrices = {}
    local childrenToRemove = {}
    local deadChildrenCount = 0
    local birthday = animal.pregnancy.expected
    local country = isSaleAnimal and animal.birthday.country or RealisticLivestock.getMapCountryIndex()


    for i, child in pairs(pregnancies) do

        local genetics = child.genetics
        local weightChance = math.random() * genetics.metabolism
        local minWeight = child:getSubType().minWeight
        local weight = minWeight + 0.5

        if weightChance < 0.05 then
            weight = weight * (math.random(70, 90) / 100)
        elseif weightChance <= 0.95 then
            weight = weight * (math.random(90, 110) / 100)
        else
            weight = weight * (math.random(110, 130) / 100)
        end

        if animal.deathEnabled and math.random() >= genetics.health * (weight / minWeight) * 1.15 then

            childNum = childNum - 1
            animalsToSell = animalsToSell - 1

            table.insert(childrenToRemove, i)
            deadChildrenCount = deadChildrenCount + 1

            child.isDead = true

            Log:trace("  child %d died at birth (weight=%.1f minWeight=%.1f)", i, weight, minWeight)

            continue

        end

        child.weight = weight
        child.age = 0

        child:setBirthday({["day"] = day, ["month"] = month, ["year"] = year, ["country"] = country, ["lastAgeMonth"] = month})

        if not isSaleAnimal then
            child:setClusterSystem(animal.clusterSystem)
            child:setUniqueId()
        else
            child:setUniqueId(animal.farmId)
        end

        local childInfo = {
            farmId = child.farmId,
            uniqueId = child.uniqueId,
        }

        table.insert(animal.children, childInfo)
        if fatherFull ~= nil then table.insert(fatherFull.children, childInfo) end


        table.insert(sellPrices, {
            ["index"] = i,
            ["sellPrice"] = child:getSellPrice(),
        })

    end

    if deadChildrenCount > 0 and math.random() >= 0.35 + animal.genetics.health * 1.25 then parentDied = true end


    table.sort(sellPrices, sortChildSellPrices)

    local totalAnimalPrice = 0


    for i = 1, animalsToSell do

        local childToSell = sellPrices[i]

        if childToSell == nil or pregnancies[childToSell.index] == nil then break end

        table.insert(childrenToRemove, childToSell.index)
        totalAnimalPrice = totalAnimalPrice + childToSell.sellPrice

    end

    table.sort(childrenToRemove)

    for i = #childrenToRemove, 1, -1 do

        table.remove(pregnancies, childrenToRemove[i])

    end

    local animalSystem = g_currentMission.animalSystem
    local clusterSystem = animal.clusterSystem
    local clusterChildren = 0

    local ok, err = pcall(function()
        for _, child in pairs(pregnancies) do
            if isSaleAnimal then
                animalSystem:addExistingSaleAnimal(child)
            else
                clusterSystem:addPendingAddCluster(child)
                clusterChildren = clusterChildren + 1
            end
        end
    end)

    -- Birth queueing is unconditional. The per-pen tail flush in
    -- PlaceableHusbandryAnimals:onDayChanged commits the queue once per
    -- day-change, so HUSBANDRY_ANIMALS_CHANGED listeners see one batched
    -- update per pen instead of one per pregnant mother. addPendingAddCluster
    -- already set needsUpdate; the engine's update(dt) is the safety net if
    -- the day-change tail flush is somehow missed.
    if not ok then
        Log:error("AnimalReproduction: birth queue failed mother=%s farmId=%s queue=%s",
            tostring(animal.uniqueId), tostring(animal.farmId), tostring(err))
    end

    if clusterChildren > 0 then
        Log:trace("AnimalReproduction: birth queued mother=%s farmId=%s clusterChildren=%d totalPregnancies=%d (flush deferred to onDayChanged tail)",
            tostring(animal.uniqueId), tostring(animal.farmId),
            clusterChildren, #pregnancies)
    end

    Log:debug("AnimalReproduction: birth batch queued mother=%s farmId=%s clusterChildren=%d totalPregnancies=%d isSaleAnimal=%s",
        tostring(animal.uniqueId), tostring(animal.farmId),
        clusterChildren, #pregnancies, tostring(isSaleAnimal))

    -- Build scannable birth summary line
    local fatherId = animal.impregnatedBy and animal.impregnatedBy.uniqueId or "?"
    local fatherSubType = fatherFull and fatherFull.subType or "?"
    local fatherIdx = fatherFull and fatherFull.subTypeIndex or -1
    local fatherBreedName = fatherFull and fatherFull.breed or "?"

    local childSummary = {}
    for _, child in pairs(pregnancies) do
        local genderChar = child.gender == "male" and "M" or "F"
        table.insert(childSummary, string.format("%s(%s idx=%d/%s %s)",
            child.uniqueId or "?", child.subType or "?", child.subTypeIndex or -1,
            child.breed or "?", genderChar))
    end

    Log:info("BIRTH: mother=%s(%s idx=%d/%s) father=%s(%s idx=%d/%s) -> %d children [%s]",
        animal.uniqueId or "?", animal.subType, animal.subTypeIndex, animal.breed or "?",
        fatherId, fatherSubType, fatherIdx, fatherBreedName,
        #pregnancies, table.concat(childSummary, ", "))

    if not isSaleAnimal then

        local farmIndex = spec:getOwnerFarmId()
        local animalTypeReal = animalSystem:getTypeByIndex(subType.typeIndex)

        if animalTypeReal.statsBreedingName ~= nil then
            local stats = g_currentMission:farmStats(farmIndex)
            stats:updateStats(animalTypeReal.statsBreedingName, childNum)
        end

    end


    animal.impregnatedBy = nil

    g_server:broadcastEvent(AnimalBirthEvent.new(
        animal.clusterSystem ~= nil and animal.clusterSystem.owner or nil,
        animal, pregnancies, parentDied))

    if #pregnancies > 0 then

        if #pregnancies == 1 then
            animal:addMessage("PREGNANCY_SINGLE")
        else
            animal:addMessage("PREGNANCY_MULTIPLE", { #pregnancies })
        end

    end

    if animalsToSell > 0 then animal:addMessage("PREGNANCY_SOLD", { animalsToSell, g_i18n:formatMoney(totalAnimalPrice, 2, true, true) }) end

    if deadChildrenCount > 0 then animal:addMessage("PREGNANCY_DIED", { deadChildrenCount }) end

    if parentDied then animal:die("rl_death_pregnancy") end

    Log:trace("reproduce: result children=%d parentDied=%s sold=%d soldAmount=%.0f deadChildren=%d",
        childNum, tostring(parentDied), animalsToSell, totalAnimalPrice, deadChildrenCount)

    return childNum, parentDied, animalsToSell, totalAnimalPrice

end


-- =============================================================================
-- INSEMINATION METHODS (from Animal.lua)
-- =============================================================================

--- Check if this animal can be inseminated by the given straw/semen record.
--- Checks 7 rejection conditions: male gender, already pregnant, wrong animal type,
--- already inseminated, too young, recovering from birth, same father.
--- @param animal table Animal instance
--- @param otherAnimal table Straw/semen record with typeIndex, country, farmId, uniqueId
--- @return boolean canInseminate
--- @return string|nil reason Rejection reason i18n text (nil if can inseminate)
function AnimalReproduction.getCanBeInseminatedByAnimal(animal, otherAnimal)

    if animal.gender == "male" then return false, g_i18n:getText("rl_insemination_male") end

    if animal.pregnancy ~= nil or animal.isPregnant then return false, g_i18n:getText("rl_insemination_pregnant") end

    if animal.animalTypeIndex ~= otherAnimal.typeIndex then return false, g_i18n:getText("rl_insemination_animalType") end

    if animal.insemination ~= nil then return false, g_i18n:getText("rl_insemination_inseminated") end

    if animal.age < animal:getSubType().reproductionMinAgeMonth then return false, g_i18n:getText("rl_insemination_young") end

    if animal.isParent and animal.monthsSinceLastBirth <= 2 then return false, g_i18n:getText("rl_insemination_recovering") end

    if string.format("%s %s %s", RLConstants.AREA_CODES[otherAnimal.country].code, otherAnimal.farmId, otherAnimal.uniqueId) == animal.fatherId then return false, g_i18n:getText("rl_insemination_father") end

    return true

end


--- Store insemination data from a straw/semen record on this animal.
--- @param animal table Animal instance
--- @param strawAnimal table Straw record with country, farmId, uniqueId, genetics, name, subTypeIndex, success
function AnimalReproduction.setInsemination(animal, strawAnimal)

    animal.insemination = {
        ["country"] = strawAnimal.country,
        ["farmId"] = strawAnimal.farmId,
        ["uniqueId"] = strawAnimal.uniqueId,
        ["genetics"] = strawAnimal.genetics,
        ["name"] = strawAnimal.name,
        ["subTypeIndex"] = strawAnimal.subTypeIndex,
        ["success"] = strawAnimal.success,
    }

end


-- =============================================================================
-- DAILY PROCESSING (consolidated from Animal:onDayChanged)
-- =============================================================================

--- Process daily reproduction logic: insemination resolution, pregnancy
--- progression, and natural conception.
--- Called from Animal:onDayChanged after aging/horse updates, before death evaluation.
--- @param animal table Animal instance
--- @param spec table|nil Husbandry spec (for maxNumAnimals, getNumOfAnimals)
--- @param day number Current day
--- @param month number Current month
--- @param year number Current year
--- @param isSaleAnimal boolean Whether this is a sale animal
--- @return number children Count of offspring born
--- @return number deadAnimals 1 if parent died during birth, 0 otherwise
--- @return number childrenSold Count of offspring auto-sold (no space)
--- @return number childrenSoldAmount Total money from auto-sold offspring
function AnimalReproduction.processDaily(animal, spec, day, month, year, isSaleAnimal)
    Log:trace("processDaily: animal=%s isPregnant=%s insemination=%s",
        animal.uniqueId or "?", tostring(animal.isPregnant),
        animal.insemination ~= nil and "pending" or "none")

    -- Sub-step 1: Resolve pending insemination (always clears insemination, may create pregnancy)
    resolveInsemination(animal, month, year)

    -- Sub-step 2: Advance pregnancy or attempt natural conception (always runs)
    local children, deadAnimals, childrenSold, childrenSoldAmount =
        advancePregnancy(animal, spec, day, month, year, isSaleAnimal)

    return children, deadAnimals, childrenSold, childrenSoldAmount
end
