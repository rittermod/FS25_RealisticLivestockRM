--[[
    RLAnimalTypeSupport.lua
    Pure helpers for animal types beyond RLRM's five core types: the cluster class, dealer-farm
    seeding, offspring subtype resolution inside the parent's type, the pallets output label, the
    load-time report lines, and the DLC-gated bundle files (a type RLRM ships only while its DLC is
    active). Data in, data out: no g_* reads, no XML, lookups, rng and the active-mod set injected.
]]

RLAnimalTypeSupport = {}

local Log = RmLogging.getLogger("RLRM")

--- Bundle files RLRM loads only while their DLC is active. Paths are relative to RLRM's mod directory.
RLAnimalTypeSupport.DLC_BUNDLES = {
    {
        dlc = "beansAndAlpacasPack",
        types = { "ALPACA" },
        animalsFile = "xml/animals_alpaca.xml",
        fillTypesFile = "xml/fillTypes_alpaca.xml"
    }
}


--- Pick one entry of a list, drawing the rng only when there is a choice to make.
---@param list table array of candidate values
---@param rng function function(lo, hi) -> integer
---@return any|nil value nil for an empty list
local function pickOne(list, rng)
    if #list == 0 then return nil end
    if #list == 1 then return list[1] end
    return list[rng(1, #list)]
end


--- A subtype's name for a log line, "?" when it does not resolve or carries none.
---@param getSubType function function(subTypeIndex) -> subType table or nil
---@param subTypeIndex number|nil
---@return string name
local function subTypeLabel(getSubType, subTypeIndex)
    local subType = subTypeIndex ~= nil and getSubType(subTypeIndex) or nil
    return subType ~= nil and subType.name ~= nil and tostring(subType.name) or "?"
end


--- The cluster class a type's declared clusterClass name resolves to, else the fallback class.
---@param className string the XML-declared class name (a global, or `<ModName>.<Class>`)
---@param getClassObject function function(className) -> the table the name reaches, or nil
---@param fallbackClass table the class used when the name reaches no table
---@return table classObject the resolved class, or fallbackClass
---@return string reason "named" | "fallback"
function RLAnimalTypeSupport.resolveClusterClass(className, getClassObject, fallbackClass)
    local classObject = getClassObject(className)

    if type(classObject) == "table" then
        Log:trace("RLAnimalTypeSupport.resolveClusterClass: '%s' resolves to a class", tostring(className))
        return classObject, "named"
    end

    Log:trace("RLAnimalTypeSupport.resolveClusterClass: '%s' resolves to nothing, using the fallback",
        tostring(className))
    return fallbackClass, "fallback"
end


--- Give every listed type no farm of `country` carries one source farm, writing ids[typeIndex] = 0.
---@param country table { index, farms = { { id, quality, ids }, ... } } - written in place
---@param types table array of { typeIndex = number, hasMale = boolean, name = string|nil }
---@param rng function|nil function(lo, hi) -> integer; defaults to math.random
---@param studQuality number|nil farm quality a male type's farm should reach when one does
---@return table seeded array of { typeIndex, farmId, quality, studFarm } - empty when nothing was missing
function RLAnimalTypeSupport.seedMissingTypeFarms(country, types, rng, studQuality)
    local seeded = {}
    rng = rng or math.random

    if country == nil or type(country.farms) ~= "table" or #country.farms == 0 or type(types) ~= "table" then
        Log:trace("RLAnimalTypeSupport.seedMissingTypeFarms: nothing to seed (no farms or no types)")
        return seeded
    end

    for _, entry in ipairs(types) do
        local typeIndex = entry.typeIndex
        local carried = false

        for _, farm in ipairs(country.farms) do
            if farm.ids ~= nil and farm.ids[typeIndex] ~= nil then
                carried = true
                break
            end
        end

        if carried then
            Log:trace("RLAnimalTypeSupport.seedMissingTypeFarms: type %s(%s) already carried in country %s",
                tostring(entry.name), tostring(typeIndex), tostring(country.index))
        else
            local candidates = {}

            if entry.hasMale == true and studQuality ~= nil then
                for i, farm in ipairs(country.farms) do
                    if (farm.quality or 0) >= studQuality then table.insert(candidates, i) end
                end
            end

            local studFarm = #candidates > 0

            if not studFarm then
                for i = 1, #country.farms do table.insert(candidates, i) end
            end

            local farmIndex = pickOne(candidates, rng)
            local farm = country.farms[farmIndex]

            if farm.ids == nil then farm.ids = {} end
            farm.ids[typeIndex] = 0

            table.insert(seeded,
                { typeIndex = typeIndex, farmId = farm.id, quality = farm.quality, studFarm = studFarm })

            Log:trace("RLAnimalTypeSupport.seedMissingTypeFarms: type %s(%s) seeded on farm %s "
                .. "(quality=%s, studFarm=%s, of %d candidates)",
                tostring(entry.name), tostring(typeIndex), tostring(farm.id), tostring(farm.quality),
                tostring(studFarm), #candidates)
        end
    end

    return seeded
end


--- The subtype and gender a child takes, always from the parent's own type.
---@param typeIndex number the parent's type index
---@param typeSubTypes table|nil the type's subtype indices
---@param getSubType function function(subTypeIndex) -> subType table or nil
---@param candidateIndex number|nil the call site's arithmetic result
---@param parentSubTypeIndex number the mother's subtype index
---@param parentBreed string|nil the mother's breed
---@param gender string the child's rolled gender, "male" or "female"
---@param rng function|nil function(lo, hi) -> integer; defaults to math.random
---@return number subTypeIndex the child's subtype index
---@return string gender the gender of that subtype
---@return string reason "candidate" | "sameBreed" | "sameGender" | "parentSubType" | "noSubTypeList"
function RLAnimalTypeSupport.resolveOffspringSubType(typeIndex, typeSubTypes, getSubType, candidateIndex,
    parentSubTypeIndex, parentBreed, gender, rng)

    rng = rng or math.random

    local parent = getSubType(parentSubTypeIndex)
    local parentGender = (parent ~= nil and parent.gender) or gender

    if typeSubTypes == nil or #typeSubTypes == 0 then
        Log:trace("RLAnimalTypeSupport.resolveOffspringSubType: type %s has no subtype list, keeping parent %s(%s)",
            tostring(typeIndex), parent ~= nil and tostring(parent.name) or "?", tostring(parentSubTypeIndex))
        return parentSubTypeIndex, parentGender, "noSubTypeList"
    end

    local candidateInType = false
    for _, subTypeIndex in ipairs(typeSubTypes) do
        if subTypeIndex == candidateIndex then
            candidateInType = true
            break
        end
    end

    if candidateInType then
        local candidate = getSubType(candidateIndex)
        if candidate ~= nil and candidate.gender == gender then
            Log:trace("RLAnimalTypeSupport.resolveOffspringSubType: candidate %s(%s) kept (gender=%s)",
                subTypeLabel(getSubType, candidateIndex), tostring(candidateIndex), gender)
            return candidateIndex, gender, "candidate"
        end
    end

    local sameBreed, sameGender = {}, {}

    for _, subTypeIndex in ipairs(typeSubTypes) do
        local subType = getSubType(subTypeIndex)
        if subType ~= nil and subType.gender == gender then
            table.insert(sameGender, subTypeIndex)
            if parentBreed ~= nil and subType.breed == parentBreed then table.insert(sameBreed, subTypeIndex) end
        end
    end

    local picked = pickOne(sameBreed, rng)
    if picked ~= nil then
        Log:trace("RLAnimalTypeSupport.resolveOffspringSubType: candidate %s(%s) rejected, same breed %s pick %s(%s)"
            .. " of %d", subTypeLabel(getSubType, candidateIndex), tostring(candidateIndex), tostring(parentBreed),
            subTypeLabel(getSubType, picked), tostring(picked), #sameBreed)
        return picked, gender, "sameBreed"
    end

    picked = pickOne(sameGender, rng)
    if picked ~= nil then
        Log:trace("RLAnimalTypeSupport.resolveOffspringSubType: candidate %s(%s) rejected, gender %s pick %s(%s) of %d",
            subTypeLabel(getSubType, candidateIndex), tostring(candidateIndex), gender,
            subTypeLabel(getSubType, picked), tostring(picked), #sameGender)
        return picked, gender, "sameGender"
    end

    Log:trace("RLAnimalTypeSupport.resolveOffspringSubType: type %s has no %s subtype, keeping parent %s(%s) (%s)",
        tostring(typeIndex), gender, parent ~= nil and tostring(parent.name) or "?", tostring(parentSubTypeIndex),
        tostring(parentGender))
    return parentSubTypeIndex, parentGender, "parentSubType"
end


--- The label of an animal's pallets output: a shipped l10n key, else the fill type's own title.
---@param typeName string|nil the animal type name (COW, SHEEP, ...)
---@param subTypeName string|nil the subtype name (GOAT, ...)
---@param fillTypeTitle string|nil the title of the subtype's pallets fill type
---@return string text an l10n key when isKey, else display text
---@return boolean isKey true when text is an l10n key to resolve
function RLAnimalTypeSupport.palletsOutputLabel(typeName, subTypeName, fillTypeTitle)
    if typeName == "COW" then return "rl_ui_output_pallets_milk", true end
    if typeName == "SHEEP" then
        return subTypeName == "GOAT" and "rl_ui_output_pallets_goatMilk" or "rl_ui_output_pallets_wool", true
    end
    if typeName == "CHICKEN" then return "rl_ui_output_pallets_eggs", true end

    if fillTypeTitle ~= nil and fillTypeTitle ~= "" then
        Log:trace("RLAnimalTypeSupport.palletsOutputLabel: type %s uses its fill-type title '%s'",
            tostring(typeName), fillTypeTitle)
        return fillTypeTitle, false
    end

    Log:trace("RLAnimalTypeSupport.palletsOutputLabel: type %s has no fill-type title, using the generic key",
        tostring(typeName))
    return "rl_ui_output_pallets", true
end


--- The load-time report lines for a type that is not in the RLRM bundle; empty for a bundled one.
---@param animalType table|nil { name, typeIndex, subTypes, isRLBundled }
---@param getSubType function function(subTypeIndex) -> subType table or nil
---@return table lines array of { level = "info" | "warning", text = string }
function RLAnimalTypeSupport.describeUnbundledType(animalType, getSubType)
    local lines = {}

    if animalType == nil or animalType.isRLBundled ~= false then
        Log:trace("RLAnimalTypeSupport.describeUnbundledType: %s is bundled or unknown, no report",
            animalType ~= nil and tostring(animalType.name) or "nil")
        return lines
    end

    local subTypeCount, maleCount = 0, 0

    for _, subTypeIndex in ipairs(animalType.subTypes or {}) do
        subTypeCount = subTypeCount + 1
        local subType = getSubType(subTypeIndex)
        if subType ~= nil and subType.gender == "male" then maleCount = maleCount + 1 end
    end

    table.insert(lines, { level = "info", text = string.format(
        "AnimalSystem: type %s (index %d) is not in the Realistic Livestock bundle - %d subtypes, %d male; "
            .. "it uses base behaviour",
        tostring(animalType.name), animalType.typeIndex or 0, subTypeCount, maleCount) })

    if maleCount == 0 then
        table.insert(lines, { level = "warning", text = string.format(
            "AnimalSystem: type %s has no male subtype, so its animals cannot breed under Realistic Livestock",
            tostring(animalType.name)) })
    end

    Log:trace("RLAnimalTypeSupport.describeUnbundledType: %s -> %d line(s)", tostring(animalType.name), #lines)
    return lines
end


--- Whether a DLC is active in this session: its prefixed mod name is in the active-mod set.
---@param modIsLoaded table|nil the session's active-mod set (g_modIsLoaded)
---@param prefix string|nil the DLC mod-name prefix (g_uniqueDlcNamePrefix)
---@param dlcName string the DLC's name without the prefix, such as "beansAndAlpacasPack"
---@return boolean active
function RLAnimalTypeSupport.isDlcActive(modIsLoaded, prefix, dlcName)
    if type(modIsLoaded) ~= "table" or prefix == nil or dlcName == nil then
        Log:trace("RLAnimalTypeSupport.isDlcActive: %s inactive (no active-mod set or prefix)", tostring(dlcName))
        return false
    end

    local active = modIsLoaded[prefix .. dlcName] ~= nil
    Log:trace("RLAnimalTypeSupport.isDlcActive: %s%s -> %s", tostring(prefix), tostring(dlcName), tostring(active))
    return active
end


--- The DLC bundles whose DLC is active, in DLC_BUNDLES order.
---@param modIsLoaded table|nil the session's active-mod set (g_modIsLoaded)
---@param prefix string|nil the DLC mod-name prefix (g_uniqueDlcNamePrefix)
---@return table bundles array of DLC_BUNDLES entries
function RLAnimalTypeSupport.getActiveDlcBundles(modIsLoaded, prefix)
    local bundles = {}

    for _, bundle in ipairs(RLAnimalTypeSupport.DLC_BUNDLES) do
        if RLAnimalTypeSupport.isDlcActive(modIsLoaded, prefix, bundle.dlc) then
            table.insert(bundles, bundle)
        end
    end

    Log:trace("RLAnimalTypeSupport.getActiveDlcBundles: %d of %d active", #bundles, #RLAnimalTypeSupport.DLC_BUNDLES)
    return bundles
end


--- The type names of every DLC bundle whose DLC is inactive, as a name set.
---@param modIsLoaded table|nil the session's active-mod set (g_modIsLoaded)
---@param prefix string|nil the DLC mod-name prefix (g_uniqueDlcNamePrefix)
---@return table names { [typeName] = true }
function RLAnimalTypeSupport.getInactiveGatedTypes(modIsLoaded, prefix)
    local names, count = {}, 0

    for _, bundle in ipairs(RLAnimalTypeSupport.DLC_BUNDLES) do
        if not RLAnimalTypeSupport.isDlcActive(modIsLoaded, prefix, bundle.dlc) then
            for _, typeName in ipairs(bundle.types) do
                names[typeName] = true
                count = count + 1
            end
        end
    end

    Log:trace("RLAnimalTypeSupport.getInactiveGatedTypes: %d type name(s) gated off", count)
    return names
end


Log:debug("RLAnimalTypeSupport loaded")
