-- RLMoveDestinationHelper.lua
-- Move-destination enumeration and validation for the animal move flows.
-- g_currentMission is read at call time only, so the module load stays game-state-free.

local Log = RmLogging.getLogger("RLRM")

RLMoveDestinationHelper = {}

--- Enumerate the move destinations a farm offers for one animal subtype: owner-farm
--- husbandries supporting it, plus any EPP (butcher) whose production point accepts it.
---
--- Husbandry entries carry live capacity; EPP entries also carry the production point's age
--- bounds. A nil sourceHusbandry makes the source-exclusion a no-op, so every owner-farm
--- placeable supporting the subtype is returned - the dealer-buy case.
---@param sourceHusbandry table|nil Source husbandry excluded from the results (nil admits every owner-farm placeable)
---@param farmId number Owning farm ID the destinations must belong to
---@param animalSubTypeIndex number Animal subtype the destination must support
---@return table Array of entries {placeable, name, currentCount, maxCount, freeSlots, isEPP, minAge?, maxAge?}
function RLMoveDestinationHelper.getValidDestinations(sourceHusbandry, farmId, animalSubTypeIndex)
    Log:trace("getValidDestinations: farmId=%d subTypeIndex=%d", farmId, animalSubTypeIndex)

    local destinations = {}

    local subType = g_currentMission.animalSystem:getSubTypeByIndex(animalSubTypeIndex)
    if subType == nil then
        Log:warning("getValidDestinations: no subType for index %d", animalSubTypeIndex)
        return destinations
    end
    local animalTypeIndex = subType.typeIndex
    local animalType = g_currentMission.animalSystem:getTypeByIndex(animalTypeIndex)

    for _, placeable in ipairs(g_currentMission.placeableSystem.placeables) do
        if placeable:getOwnerFarmId() ~= farmId then
            -- skip: wrong farm
        elseif placeable.spec_husbandryAnimals ~= nil
               and placeable:getSupportsAnimalSubType(animalSubTypeIndex)
               and placeable ~= sourceHusbandry then
            -- Regular husbandry
            local currentCount = placeable:getNumOfAnimals()
            local maxCount = placeable:getMaxNumOfAnimals(animalType)
            local freeSlots = placeable:getNumOfFreeAnimalSlots(animalSubTypeIndex)

            local entry = {
                placeable = placeable,
                name = placeable:getName(),
                currentCount = currentCount,
                maxCount = maxCount,
                freeSlots = freeSlots,
                isEPP = false,
            }

            table.insert(destinations, entry)
            Log:trace("  husbandry: '%s' (%d/%d)", entry.name, currentCount, maxCount)

        elseif placeable.spec_extendedProductionPoint ~= nil then
            -- EPP (butcher) - methods live on the production point, not the placeable
            local eppSpec = placeable.spec_extendedProductionPoint
            local pp = eppSpec.productionPoint

            if pp ~= nil and pp.animalsTypeData ~= nil then
                local eppTypeData = pp.animalsTypeData[animalTypeIndex]

                if eppTypeData ~= nil and pp:getSupportsAnimalSubType(animalSubTypeIndex) then
                    local freeSlots = pp:getNumOfFreeAnimalSlots(animalSubTypeIndex)
                    local maxCount = eppTypeData.maxNumAnimals or 0
                    local currentCount = maxCount - freeSlots

                    local entry = {
                        placeable = pp,
                        name = placeable:getName(),
                        currentCount = currentCount,
                        maxCount = maxCount,
                        freeSlots = freeSlots,
                        isEPP = true,
                        minAge = eppTypeData.minimumAge,
                        maxAge = eppTypeData.maximumAge,
                    }

                    table.insert(destinations, entry)
                    Log:trace("  EPP: '%s' (%d/%d) ages %s-%s",
                        entry.name, currentCount, maxCount,
                        tostring(entry.minAge), tostring(entry.maxAge))
                end
            end
        end
    end

    Log:trace("getValidDestinations: found %d destinations", #destinations)
    return destinations
end


--- Split animals into valid and rejected against one destination entry, in input order.
---
--- The EPP age gate applies only when the entry is an EPP advertising BOTH bounds - a single
--- missing bound skips it. `destination.name` and `.freeSlots` are indexed unconditionally,
--- so the caller guards a nil destination.
---@param animals table Array of animals to validate (each may carry age, name, uniqueId)
---@param destination table Destination entry from getValidDestinations
---@param animalTypeIndex number Animal type index (logged only)
---@return table Validation result { valid = {animal...}, rejected = {{animal, reason}...}, destination }
function RLMoveDestinationHelper.buildMoveValidationResult(animals, destination, animalTypeIndex)
    Log:trace("buildMoveValidationResult: %d animals, dest='%s' typeIndex=%d",
        #animals, destination.name, animalTypeIndex)

    local result = { valid = {}, rejected = {}, destination = destination }

    local slotsUsed = 0
    local freeSlots = destination.freeSlots

    for _, animal in ipairs(animals) do
        local age = animal.age or 0
        local rejected = false

        -- Keyed on isEPP alone, so a butcher missing an age bound still refuses a sick animal.
        if destination.isEPP and not RLDiseaseSaleGate.check(animal) then
            table.insert(result.rejected, { animal = animal, reason = "SICK" })
            Log:trace("  rejected '%s': SICK", tostring(animal.name or animal.uniqueId or "?"))
            rejected = true
        elseif destination.isEPP and destination.minAge ~= nil and destination.maxAge ~= nil then
            local minAge = destination.minAge
            local maxAge = destination.maxAge

            if age < minAge then
                table.insert(result.rejected, { animal = animal, reason = "AGE_TOO_YOUNG" })
                Log:trace("  rejected '%s': AGE_TOO_YOUNG (age=%d, min=%d)",
                    animal.name or animal.uniqueId or "?", age, minAge)
                rejected = true
            elseif age > maxAge then
                table.insert(result.rejected, { animal = animal, reason = "AGE_TOO_OLD" })
                Log:trace("  rejected '%s': AGE_TOO_OLD (age=%d, max=%d)",
                    animal.name or animal.uniqueId or "?", age, maxAge)
                rejected = true
            end
        end

        if not rejected then
            if slotsUsed >= freeSlots then
                table.insert(result.rejected, { animal = animal, reason = "NO_CAPACITY" })
                Log:trace("  rejected '%s': NO_CAPACITY (used=%d, free=%d)",
                    animal.name or animal.uniqueId or "?", slotsUsed, freeSlots)
            else
                slotsUsed = slotsUsed + 1
                table.insert(result.valid, animal)
                Log:trace("  valid '%s' (slot %d/%d)",
                    animal.name or animal.uniqueId or "?", slotsUsed, freeSlots)
            end
        end
    end

    Log:trace("buildMoveValidationResult: %d valid, %d rejected", #result.valid, #result.rejected)
    return result
end

Log:trace("RLMoveDestinationHelper: loaded")
