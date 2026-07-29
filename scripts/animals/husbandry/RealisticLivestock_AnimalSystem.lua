RealisticLivestock_AnimalSystem = {}

local Log = RmLogging.getLogger("RLRM")
local modName = g_currentModName
local modDirectory = g_currentModDirectory

-- One-shot warning latch for the dealer-quality reshape, matching the per-site
-- latches RLDealerQualityModel carries. The warn site sits inside the per-animal
-- generation loop, so an unlatched WARNING would fire once per animal per type on
-- every hourly restock and on every dealer reset. Lifetime is the MAP LOAD: FS25
-- re-sources every mod file on each load, so this resets to false then.
local warnedReshapeReturnedNil = false


local function getDaysInMonth(month)
    -- Nil-guard retained as defensive pattern for load-order safety
    local daysPerMonth = RLConstants ~= nil and RLConstants.DAYS_PER_MONTH or nil
    if daysPerMonth == nil then
        Log:warning("DAYS_PER_MONTH not available, using fallback of 1")
        return 1
    end
    local days = daysPerMonth[month]
    if days == nil then
        Log:warning("No days defined for month %d, using fallback of 1", month)
        return 1
    end
    return days
end


local function logSubTypeRegistry(self, label)
    Log:debug("SubType registry after %s (%d subtypes):", label, #self.subTypes)
    for i, st in ipairs(self.subTypes) do
        local typeName = self.typeIndexToName[st.typeIndex] or "?"
        Log:debug("  [%d]  %-28s type=%-8s(%d)  gender=%-6s  breed=%s",
            i, st.name, typeName, st.typeIndex, st.gender or "?", st.breed or "?")
    end
end


table.insert(FinanceStats.statNames, "monitorSubscriptions")
FinanceStats.statNameToIndex["monitorSubscriptions"] = #FinanceStats.statNames



AnimalSystem.BREED_TO_NAME = {
    ["HOLSTEIN"] = "Holstein",
    ["SWISS_BROWN"] = "Swiss Brown",
    ["ANGUS"] = "Angus",
    ["LIMOUSIN"] = "Limousin",
    ["HEREFORD"] = "Hereford",
    ["HIGHLAND"] = "Highland",
    ["WATER_BUFFALO"] = "Water Buffalo",
    ["LANDRACE"] = "Landrace",
    ["BLACK_PIED"] = "Black Pied",
    ["BERKSHIRE"] = "Berkshire",
    ["STEINSCHAF"] = "Steinschaf",
    ["SWISS_MOUNTAIN"] = "Swiss Mountain",
    ["BLACK_WELSH"] = "Black Welsh",
    ["GOAT"] = "Goat",
    ["GRAY"] = "Gray",
    ["PINTO"] = "Pinto",
    ["PALOMINO"] = "Palomino",
    ["CHESTNUT"] = "Chestnut",
    ["BAY"] = "Bay",
    ["BLACK"] = "Black",
    ["SEAL_BROWN"] = "Seal Brown",
    ["DUN"] = "Dun",
    ["CHICKEN"] = "Chicken",
    ["OTHER"] = "Unknown"
}


AnimalSystem.BREED_TO_MARKER_COLOUR = {
    ["HOLSTEIN"] = { 1, 0, 0 },
    ["SWISS_BROWN"] = { 1, 1, 0 },
    ["ANGUS"] = { 1, 1, 1 },
    ["LIMOUSIN"] = { 0, 0, 1 },
    ["HEREFORD"] = { 0, 0, 1 },
    ["WATER_BUFFALO"] = { 1, 1, 1 },
    ["HIGHLAND"] = { 0.6, 0.3, 0.1 }
}


function RealisticLivestock_AnimalSystem:loadMapData(_, mapXml, mission, baseDirectory)

    RLSettings.initialize()
    RLSettings.validateCustomAnimalsConfiguration()

    self.customEnvironment = modName

    self.baseColours = {
        ["earTagLeft"] = { 0.8, 0.7, 0 },
        ["earTagRight"] = { 0.8, 0.7, 0 },
        ["earTagLeft_text"] = { 0, 0, 0 },
        ["earTagRight_text"] = { 0, 0, 0 }
    }

    -- Visual node-path defaults harvested from RL's authoritative bundle XML during Phase 1.
    -- Keyed by [animalType.name][visualAnimalIndex] -> { marker, monitor, earTagLeft, earTagRight, noseRing, bumId }.
    -- Map and bridge subtypes (Phase 2/3) that reuse an RL visualAnimalIndex without these
    -- attributes get their nil paths filled from this registry, so RL's i3d marker/monitor/
    -- earTag/noseRing/bumId meshes hide correctly instead of staying at default visibility.
    -- Reset every loadMapData so save reloads start fresh.
    self.defaultVisualPathsByIndex = {}
    -- Snapshot of animalType.configFilename per type at end of Phase 1. If a later phase
    -- replaces the husbandry config (non-dataS map config), live config != snapshot and
    -- defaults are skipped to avoid resolving paths against an unknown i3d.
    self.configFilenameSnapshot = {}

    local path = RLSettings.getAnimalsXMLPath() or (modDirectory .. "xml/animals.xml")

    Log:info("AnimalSystem: Using animals XML path '%s'", path)

    Log:info("AnimalSystem: === PHASE 1 START === RL bundled animals from '%s'", path)
    local xmlFile = XMLFile.load("animals", path)

    if xmlFile ~= nil then

        local basePath = RLSettings.getAnimalsBasePath() or modDirectory

        Log:info("AnimalSystem: Using animals base path '%s'", basePath)

        -- Scope flag: true ONLY around Phase 1 loadAnimals. loadVisualData uses it to
        -- distinguish "populate registry from RL bundle" (true) from "fill nil paths
        -- from registry" (false). Works regardless of where the bundle lives on disk
        -- (default modDirectory or RLSettings.customAnimals override).
        self.isLoadingRLBundle = true
        self:loadAnimals(xmlFile, basePath)
        self.isLoadingRLBundle = false
        xmlFile:delete()

    end

    Log:info("AnimalSystem: === PHASE 1 END === %d types, %d subtypes registered", #self.types, #self.subTypes)
    logSubTypeRegistry(self, "Phase 1")

    -- Snapshot per-type configFilename so Phase 2/3 fill can detect when a later phase
    -- replaced the husbandry config (e.g. a future map shipping a non-dataS cow config).
    for _, animalType in pairs(self.types) do
        self.configFilenameSnapshot[animalType.name] = animalType.configFilename
        Log:trace("AnimalSystem: snapshot configFilename type=%s '%s'", animalType.name, tostring(animalType.configFilename))
    end

    self.customEnvironment = mission.customEnvironment

    local baseFilename = getXMLString(mapXml, "map.animals#filename")

	if baseFilename == nil or baseFilename == "" then

		Logging.xmlInfo(mapXml, "No animals xml given at \'map.animals#filename\'")

    elseif #self.types == 0 or not RLSettings.getOverrideVanillaAnimals() then

        Log:info("AnimalSystem: === PHASE 2 START === map animals from '%s'", baseFilename)
	    local baseXmlFile = XMLFile.load("animals", Utils.getFilename(baseFilename, baseDirectory))

	    if baseXmlFile ~= nil then

            self:loadAnimals(baseXmlFile, baseDirectory)
            baseXmlFile:delete()

	    end

        Log:info("AnimalSystem: === PHASE 2 END === %d types, %d subtypes after map animals", #self.types, #self.subTypes)

    else

        Log:info("AnimalSystem: === PHASE 2 SKIPPED === (OverrideVanillaAnimals=true)")

    end

    -- Phase 3: Load bridge animal subtypes for detected maps
    -- Reset customEnvironment to RLRM before bridge loading so the C++ engine's
    -- $l10n_ resolution finds bridge translations in the global texts table
    -- (with customEnv = MAP, the engine only checks the map's mod texts and misses them)
    self.customEnvironment = modName

    Log:info("AnimalSystem: === PHASE 3 START === bridge/pack loading (%d active bridges)", #RLMapBridge.activeBridges)
    RLMapBridge.loadBridgeAnimals(self)
    Log:info("AnimalSystem: === PHASE 3 END === %d total subtypes after bridge loading", #self.subTypes)
    logSubTypeRegistry(self, "Phase 3")

    Log:info("AnimalSystem: Loaded %s animals:", #self.types)

    for _, type in pairs(self.types) do
        Log:info("  - Animal Type: %s (%s subTypes)", type.name, #type.subTypes)
        for i, subTypeIndex in pairs(type.subTypes) do
            Log:info("    |--- SubType (%s): %s (%s)", i, self.subTypes[subTypeIndex].name, self.subTypes[subTypeIndex].gender)
        end
    end

    self:loadColourConfigurations()

	return #self.types > 0

end

AnimalSystem.loadMapData = Utils.overwrittenFunction(AnimalSystem.loadMapData, RealisticLivestock_AnimalSystem.loadMapData)


function RealisticLivestock_AnimalSystem:loadAnimals(_, xmlFile, directory)

	for _, key in xmlFile:iterator("animals.animal") do

		if #self.types >= 2 ^ AnimalSystem.SEND_NUM_BITS - 1 then
			Logging.xmlWarning(xmlFile, "Maximum number of supported animal types reached. Ignoring remaining types")
			return
		end

		local rawName = xmlFile:getString(key .. "#type")

		if rawName == nil then
			Logging.xmlError(xmlFile, "Missing animal type. \'%s\'", key)
			return
		end

		local name = rawName:upper()
        local rawConfigFilename = xmlFile:getString(key .. ".configFilename")

		if rawConfigFilename == nil then
			Logging.xmlError(xmlFile, "Missing config file for animal type \'%s\'. \'%s\'", name, key)
			return
		end

        local configFilename = Utils.getFilename(rawConfigFilename, directory)
        local animalType

        local isExistingType = self.nameToTypeIndex[name] ~= nil

		if isExistingType then

			animalType = self.nameToType[name]

			-- Skip dataS-prefixed config reloads: RLRM ships its own bundled
			-- animal configs (the superset of every base-game + DLC animal type),
			-- and reloading the shipped dataS config over the top would drop
			-- RLRM's additional models. Only clear+reload for map-mod overrides
			-- (non-dataS configs).
			-- ASSUMES: RLRM bundles configs for every base-game + DLC animal type.
			-- If a new DLC adds an animal type, RLRM must update its bundled
			-- configs to include it.
			if string.startsWith(configFilename, "dataS") then
				Log:trace("loadAnimals: skipping base game config reload for existing type '%s' (keeping %d models)",
					name, #animalType.animals)

				-- Still process map subtypes - map may define new subtypes for existing types
				-- (e.g. COW_JERSEY on Witcombe) using RLRM's bundled model config
				local beforeCount = #self.subTypes
				self:loadSubTypes(animalType, xmlFile, key, directory)
				local addedCount = #self.subTypes - beforeCount

				if addedCount > 0 then
					Log:debug("loadAnimals: added %d map subtype(s) to existing type '%s' (total now %d)",
						addedCount, name, #animalType.subTypes)
				else
					Log:trace("loadAnimals: no new subtypes from map for existing type '%s'", name)
				end

				continue
			end

			Log:debug("loadAnimals: reloading existing type '%s' - clearing %d animals, config '%s' -> '%s'",
				name, #animalType.animals, tostring(animalType.configFilename), tostring(configFilename))
			animalType.animals = {}
			animalType.configFilename = configFilename

        else

            local clusterClass = xmlFile:getString(key .. "#clusterClass")

		    if clusterClass == nil then
			    Logging.xmlError(xmlFile, "Missing animal clusterClass for \'%s\'!", key)
			    return
		    end

		    local statsBreedingName = xmlFile:getString(key .. "#statsBreeding")
		    local title = g_i18n:convertText(xmlFile:getString(key .. "#groupTitle"), self.customEnvironment)
		    local height = xmlFile:getFloat(key .. ".navMeshAgent#height")
		    local radius = xmlFile:getFloat(key .. ".navMeshAgent#radius")
		    local maxClimbMeters = xmlFile:getFloat(key .. ".navMeshAgent#maxClimbMeters")
		    local maxSlope = math.rad(xmlFile:getFloat(key .. ".navMeshAgent#maxSlope") or 15)
		    local sqmPerAnimal = xmlFile:getFloat(key .. ".pasture#sqmPerAnimal", 100)
            local averageBuyAge = xmlFile:getInt(key .. "#averageBuyAge", 12)
            local maxBuyAge = xmlFile:getInt(key .. "#maxBuyAge", 60)

            local averageChildren = xmlFile:getInt(key .. ".pregnancy#average", 1)
            local maxChildren = xmlFile:getInt(key .. ".pregnancy#max", 3)

            local pregnancy = {}
            local totalChance = 0

            for i = 0, averageChildren - 1 do

                totalChance = totalChance + (i / averageChildren) / maxChildren

                table.insert(pregnancy, totalChance)

            end

            totalChance = totalChance + 0.5
            table.insert(pregnancy, totalChance)

            for i = averageChildren + 1, maxChildren - 1 do

                totalChance = totalChance + (1 - totalChance) * 0.8

                table.insert(pregnancy, totalChance)

            end

            table.insert(pregnancy, 1)

            local function pregnancyFunction(value)

                for i = 0, #pregnancy - 1 do

                    if pregnancy[i + 1] > value then return i end

                end

                return 0

            end

            local fertility = self:loadAnimCurve(xmlFile, key .. ".fertility")

            if fertility == nil then

                fertility = AnimCurve.new(linearInterpolator1)

                for i = 0, 120, 6 do

                    fertility:addKeyframe({
                        i <= 12 and 0 or (i <= 30 and (900 + i)) or (900 - i * 3),
                        ["time"] = i
                    })

                end

                fertility:addKeyframe({
                    0,
                    ["time"] = 121
                })

            end

		    animalType = {
			    ["name"] = name,
			    ["groupTitle"] = title,
			    ["typeIndex"] = #self.types + 1,
			    ["configFilename"] = configFilename,
			    ["clusterClass"] = clusterClass == "AnimalCluster" and AnimalCluster or AnimalClusterHorse,
			    ["statsBreedingName"] = statsBreedingName,
			    ["navMeshAgentAttributes"] = {
				    ["height"] = height,
				    ["radius"] = radius,
				    ["maxClimbMeters"] = maxClimbMeters,
				    ["maxSlope"] = maxSlope
			    },
                ["sqmPerAnimal"] = sqmPerAnimal,
			    ["subTypes"] = {},
                ["animals"] = {},
                ["averageBuyAge"] = averageBuyAge,
                ["maxBuyAge"] = maxBuyAge,
                ["colours"] = {
                    ["earTagLeft"] = { 0.8, 0.7, 0 },
                    ["earTagRight"] = { 0.8, 0.7, 0 },
                    ["earTagLeft_text"] = { 0, 0, 0 },
                    ["earTagRight_text"] = { 0, 0, 0 }
                },
                ["pregnancy"] = {
                    ["get"] = pregnancyFunction,
                    ["average"] = averageChildren
                },
                ["fertility"] = fertility,
                ["breeds"] = {}
		    }

            Log:debug("loadAnimals: new type '%s' (typeIndex=%d, config='%s')", name, animalType.typeIndex, configFilename)

		end

		if self:loadAnimalConfig(animalType, directory, configFilename) then
			Log:trace("loadAnimals: '%s' - animals after loadAnimalConfig=%d", name, #animalType.animals)

		    if self:loadSubTypes(animalType, xmlFile, key, directory) then

                --- Re-link visual.visualAnimal references for ALL subtypes of reloaded type.
                --- After clearing and reloading animalType.animals, existing subtypes' visual
                --- references point to stale objects. Re-link using their original visualAnimalIndex.
                --- Visual stage definitions (minAge thresholds) are preserved from RLRM's Phase 1.
                if isExistingType then
                    for _, subTypeIndex in ipairs(animalType.subTypes) do
                        local subType = self.subTypes[subTypeIndex]
                        if subType ~= nil and subType.visuals ~= nil then
                            Log:trace("loadAnimals: re-linking visuals for subType '%s'", subType.name)
                            for _, visual in pairs(subType.visuals) do
                                if visual.visualAnimalIndex ~= nil and animalType.animals[visual.visualAnimalIndex] ~= nil then
                                    visual.visualAnimal = animalType.animals[visual.visualAnimalIndex]
                                    -- Re-apply texture filtering if present
                                    if visual.textureIndexes ~= nil then
                                        local filteredAnimal = table.clone(visual.visualAnimal, 10)
                                        filteredAnimal.variations = {}
                                        for _, textureIndex in pairs(visual.textureIndexes) do
                                            table.insert(filteredAnimal.variations, visual.visualAnimal.variations[textureIndex])
                                        end
                                        if #filteredAnimal.variations > 0 then
                                            visual.visualAnimal = filteredAnimal
                                        end
                                    end
                                else
                                    Log:warning("loadAnimals: subType '%s' visual has invalid index %s after reload",
                                        subType.name, tostring(visual.visualAnimalIndex))
                                end
                            end
                        end
                    end
                end

			    if self.nameToType[name] == nil then

                    table.insert(self.types, animalType)
			        self.nameToType[name] = animalType
			        self.nameToTypeIndex[name] = animalType.typeIndex
			        self.typeIndexToName[animalType.typeIndex] = name

                end

		    end

        end

	end

end

AnimalSystem.loadAnimals = Utils.overwrittenFunction(AnimalSystem.loadAnimals, RealisticLivestock_AnimalSystem.loadAnimals)


function RealisticLivestock_AnimalSystem:loadAnimalConfig(_, animalType, directory, configFilename)

    local xmlFile = XMLFile.load("animalsConfig", configFilename)

	if xmlFile == nil then return false end

	for _, key in xmlFile:iterator("animalHusbandry.animals.animal") do

        local filename = xmlFile:getString(key .. ".assets#filename")
        local filenamePosed = xmlFile:getString(key .. ".assets#filenamePosed")

		local animal = {
			["filename"] = Utils.getFilename(filename, directory),
			["filenamePosed"] = Utils.getFilename(filenamePosed, directory)
		}

        if not fileExists(animal.filename) and string.contains(filename, "dataS") then animal.filename = filename end
        if not fileExists(animal.filenamePosed) and string.contains(filenamePosed, "dataS") then animal.filenamePosed = filenamePosed end

		if animal.filenamePosed == nil then
			Logging.xmlError(xmlFile, "Missing \'filenamePosed\' for animal \'%s\'", key)
			animal.filenamePosed = animal.filename
		end

		animal.variations = {}

		for _, variationKey in xmlFile:iterator(key .. ".assets.texture") do

			local variation = {}

			local numTilesU = xmlFile:getInt(variationKey .. "#numTilesU", 1)
			variation.numTilesU = math.max(numTilesU, 1)

			local tileUIndex = xmlFile:getInt(variationKey .. "#tileUIndex", 0)
			variation.tileUIndex = math.clamp(tileUIndex, 0, variation.numTilesU - 1)

			local numTilesV = xmlFile:getInt(variationKey .. "#numTilesV", 1)
			variation.numTilesV = math.max(numTilesV, 1)

			local tileVIndex = xmlFile:getInt(variationKey .. "#tileVIndex", 0)
			variation.tileVIndex = math.clamp(tileVIndex, 0, variation.numTilesV - 1)

			variation.mirrorV = xmlFile:getBool(variationKey .. "#mirrorV", false)
			variation.multi = xmlFile:getBool(variationKey .. "#multi", true)

			table.insert(animal.variations, variation)

		end

		table.insert(animalType.animals, animal)

	end

	xmlFile:delete()

	return true

end

AnimalSystem.loadAnimalConfig = Utils.overwrittenFunction(AnimalSystem.loadAnimalConfig, RealisticLivestock_AnimalSystem.loadAnimalConfig)


function RealisticLivestock_AnimalSystem:loadSubTypes(_, animalType, xmlFile, key, directory)

    for _, subTypeKey in xmlFile:iterator(key .. ".subType") do

		local rawName = xmlFile:getString(subTypeKey .. "#subType")
        local requiredDLC = xmlFile:getString(subTypeKey .. "#requiredDLC")
        local dlcModName = requiredDLC ~= nil and (g_uniqueDlcNamePrefix .. requiredDLC) or nil

        -- Register a requiredDLC subtype only when its DLC is ACTIVE in the session
        -- (g_modIsLoaded), not merely installed on disk (g_modNameToDirectory). Install
        -- state is not synchronized across MP peers, so gating on it let a server register
        -- a DLC subtype while its session had the DLC inactive; peers without the DLC then
        -- mis-resolved the streamed subtype and corrupted animals on write-back.
        -- Gating on the active set keeps the registry identical across peers; when the DLC
        -- is inactive the subtype is skipped and its saved animals are dropped on load.
        if requiredDLC == nil or g_modIsLoaded[dlcModName] ~= nil then

		    if rawName == nil then
			    Logging.xmlError(xmlFile, "Missing animal subtype. \'%s\'", subTypeKey)
			    Log:warning("loadSubTypes: missing subType name at '%s', skipping entry (type '%s')",
				    subTypeKey, animalType.name)
			    continue
		    end

		    local name = rawName:upper()

		    if self.nameToSubTypeIndex[name] ~= nil then
				Log:trace("loadSubTypes: skipping existing subType '%s' (index=%d) for type '%s'",
					name, self.nameToSubTypeIndex[name], animalType.name)
				continue
			end

		    local fillTypeName = xmlFile:getString(subTypeKey .. "#fillTypeName")
		    local fillTypeIndex = g_fillTypeManager:getFillTypeIndexByName(fillTypeName)

		    if fillTypeIndex == nil then
			    Logging.xmlError(xmlFile, "FillType \'%s\' for animal subtype \'%s\' not defined!", fillTypeName, subTypeKey)
			    Log:warning("loadSubTypes: fillType '%s' not found for subType '%s', skipping entry (type '%s')",
				    tostring(fillTypeName), name, animalType.name)
			    continue
		    end

		    local subType = {
			    ["name"] = name,
			    ["subTypeIndex"] = #self.subTypes + 1,
			    ["fillTypeIndex"] = fillTypeIndex,
			    ["typeIndex"] = animalType.typeIndex,
			    ["statsBreedingName"] = xmlFile:getString(subTypeKey .. "#statsBreeding") or animalType.statsBreedingName
		    }

		    if self:loadSubType(animalType, subType, xmlFile, subTypeKey, directory) then

			    table.insert(animalType.subTypes, subType.subTypeIndex)
			    table.insert(self.subTypes, subType)
			    self.nameToSubType[name] = subType
			    self.nameToSubTypeIndex[name] = subType.subTypeIndex
			    self.fillTypeIndexToSubType[fillTypeIndex] = subType

                local breed = xmlFile:getString(subTypeKey .. "#breed", name)
                subType.breed = breed

                if animalType.breeds[breed] == nil then animalType.breeds[breed] = {} end

                table.insert(animalType.breeds[breed], subType)

                Log:trace("loadSubTypes: registered subType '%s' (index=%d, fillType=%s, breed=%s) for type '%s'",
                    name, subType.subTypeIndex, tostring(fillTypeName), breed, animalType.name)

		    else
                Log:warning("loadSubTypes: loadSubType returned false for '%s' (type '%s'), skipping",
                    name, animalType.name)
		    end

        else
            Log:debug("loadSubTypes: skipping subType '%s' - required DLC '%s' not active (installed=%s)",
                tostring(rawName), tostring(requiredDLC), tostring(g_modNameToDirectory[dlcModName] ~= nil))
        end

	end

	return true

end

AnimalSystem.loadSubTypes = Utils.overwrittenFunction(AnimalSystem.loadSubTypes, RealisticLivestock_AnimalSystem.loadSubTypes)


function RealisticLivestock_AnimalSystem:loadSubType(superFunc, animalType, subType, xmlFile, key, directory)

    local returnValue = superFunc(self, animalType, subType, xmlFile, key, directory)

    -- Log visual indices for debugging
    if subType.visuals ~= nil then
        for vi, visual in pairs(subType.visuals) do
            Log:trace("loadSubType: '%s' visual[%d] minAge=%s visualAnimalIndex=%s",
                subType.name, vi, tostring(visual.minAge), tostring(visual.visualAnimalIndex))
        end
    end

    local height, radius = animalType.navMeshAgentAttributes.height, animalType.navMeshAgentAttributes.radius

    subType.gender = xmlFile:getString(key .. "#gender", "female")

    if directory ~= modDirectory and subType.gender == "female" then subType.gender = (string.contains(subType.name, "_MALE") or string.contains(subType.name, "BULL_") or string.contains(subType.name, "BOAR_") or string.contains(subType.name, "RAM_") or string.contains(subType.name, "BUCK_") or string.contains(subType.name, "STALLION_") or string.contains(subType.name, "ROOSTER_")) and "male" or "female" end

    subType.maxWeight = xmlFile:getFloat(key .. "#maxWeight", height * radius * 750)
    subType.targetWeight = xmlFile:getFloat(key .. "#targetWeight", height * radius * 300)
    subType.minWeight = xmlFile:getFloat(key .. "#minWeight", height * radius * 50)

    for _, visual in pairs(subType.visuals) do

        if visual.textureIndexes == nil then continue end

        local visualAnimal = table.clone(visual.visualAnimal, 10)
        visualAnimal.variations = {}

        for _, textureIndex in pairs(visual.textureIndexes) do table.insert(visualAnimal.variations, visual.visualAnimal.variations[textureIndex]) end

        if #visualAnimal.variations > 0 then visual.visualAnimal = visualAnimal end

    end

    return returnValue

end

AnimalSystem.loadSubType = Utils.overwrittenFunction(AnimalSystem.loadSubType, RealisticLivestock_AnimalSystem.loadSubType)


--- Visual node-path attributes that the registry tracks. Order matches the order
--- VisualAnimal:load reads them in. Treated uniformly by the populate/fill code.
local VISUAL_PATH_KEYS = { "earTagLeft", "earTagRight", "noseRing", "bumId", "monitor", "marker" }


--- Returns true when a and b are both non-nil strings and equal.
local function pathEquals(a, b)
    return a ~= nil and b ~= nil and a == b
end


function RealisticLivestock_AnimalSystem:loadVisualData(superFunc, animalType, xmlFile, key, baseDirectory)

    local visualData = superFunc(self, animalType, xmlFile, key, baseDirectory)

    if visualData == nil then return nil end

    -- xmlFile:getString returns nil for both missing AND empty attributes, so an
    -- explicit `marker=""` map override is treated identically to a missing attribute
    -- (no fill, no resolve).
    local earTagLeft = xmlFile:getString(key .. "#earTagLeft", nil)
    local earTagRight = xmlFile:getString(key .. "#earTagRight", nil)
    local noseRing = xmlFile:getString(key .. "#noseRing", nil)
    local bumId = xmlFile:getString(key .. "#bumId", nil)
    local monitor = xmlFile:getString(key .. "#monitor", nil)
    local marker = xmlFile:getString(key .. "#marker", nil)

    if earTagLeft ~= nil then visualData.earTagLeft = earTagLeft end
    if earTagRight ~= nil then visualData.earTagRight = earTagRight end
    if noseRing ~= nil then visualData.noseRing = noseRing end
    if bumId ~= nil then visualData.bumId = bumId end
    if monitor ~= nil then visualData.monitor = monitor end
    if marker ~= nil then visualData.marker = marker end

    -- Registry populate (Phase 1: RL bundle) or fill (Phase 2/3: map / bridge).
    -- The scope flag captures Phase-1 semantics regardless of where the bundle lives
    -- on disk, so RLSettings.customAnimals power-users get the same fix as default users.
    local typeName = animalType ~= nil and animalType.name or nil
    local idx = visualData.visualAnimalIndex
    if typeName ~= nil and idx ~= nil then
        if self.isLoadingRLBundle then
            self:rlrmStoreVisualDefaults(typeName, idx, visualData)
        else
            self:rlrmFillVisualDefaults(typeName, idx, visualData, animalType)
        end
    elseif self.isLoadingRLBundle then
        Log:trace("loadVisualData: skipping registry insert (typeName=%s idx=%s)",
            tostring(typeName), tostring(idx))
    end

    if xmlFile:hasProperty(key .. ".textureIndexes") then

        visualData.textureIndexes = {}

        xmlFile:iterate(key .. ".textureIndexes.value", function(_, textureKey)

            table.insert(visualData.textureIndexes, xmlFile:getInt(textureKey, 1))

        end)

    end

    return visualData

end

AnimalSystem.loadVisualData = Utils.overwrittenFunction(AnimalSystem.loadVisualData, RealisticLivestock_AnimalSystem.loadVisualData)


--- Store this Phase-1 visualData's node paths into the registry under (typeName, idx).
--- Called only when self.isLoadingRLBundle is true.
--- Idempotent for equal-value re-inserts; emits Log:warning when a re-insert disagrees
--- with an existing stored value (catches XML drift between same-index <visual> entries).
function AnimalSystem:rlrmStoreVisualDefaults(typeName, idx, visualData)
    if self.defaultVisualPathsByIndex[typeName] == nil then
        self.defaultVisualPathsByIndex[typeName] = {}
    end
    local existing = self.defaultVisualPathsByIndex[typeName][idx]
    local stored = {}
    local storedKeys = {}
    for _, k in ipairs(VISUAL_PATH_KEYS) do
        local v = visualData[k]
        if v ~= nil then
            stored[k] = v
            table.insert(storedKeys, k)
            if existing ~= nil and existing[k] ~= nil and not pathEquals(existing[k], v) then
                Log:warning("registry: conflicting write type=%s index=%d key=%s existing='%s' new='%s'",
                    typeName, idx, k, tostring(existing[k]), tostring(v))
            end
        end
    end
    if existing == nil then
        self.defaultVisualPathsByIndex[typeName][idx] = stored
        Log:trace("registry: type=%s index=%d stored {%s}", typeName, idx, table.concat(storedKeys, ","))
    else
        -- Merge: keep existing keys; add any new keys this entry has that the existing one didn't.
        local addedKeys = {}
        for _, k in ipairs(VISUAL_PATH_KEYS) do
            if existing[k] == nil and stored[k] ~= nil then
                existing[k] = stored[k]
                table.insert(addedKeys, k)
            end
        end
        if #addedKeys > 0 then
            Log:trace("registry: type=%s index=%d merged {%s}", typeName, idx, table.concat(addedKeys, ","))
        end
    end
end


--- Fill nil paths in visualData from the registry entry at (typeName, idx).
--- Called only when self.isLoadingRLBundle is false (Phase 2/3).
--- Skips entirely when animalType.configFilename != Phase-1 snapshot (a later phase
--- replaced the husbandry config; live i3d node tree is no longer guaranteed to match
--- registry paths, so leave paths nil and let the visual setters early-return rather
--- than resolve against wrong nodes).
function AnimalSystem:rlrmFillVisualDefaults(typeName, idx, visualData, animalType)
    local snapshot = self.configFilenameSnapshot[typeName]
    local live = animalType ~= nil and animalType.configFilename or nil
    if snapshot ~= nil and live ~= nil and snapshot ~= live then
        Log:debug("defaults skipped: configFilename mismatch type=%s snapshot='%s' live='%s'",
            typeName, tostring(snapshot), tostring(live))
        return
    end
    local typeRegistry = self.defaultVisualPathsByIndex[typeName]
    if typeRegistry == nil then
        Log:debug("defaults skipped: no registry entries for type=%s (Phase 1 didn't run or this species had no <visual> with paths)",
            typeName)
        return
    end
    local entry = typeRegistry[idx]
    if entry == nil then
        Log:debug("defaults skipped: no registry entry for type=%s index=%d", typeName, idx)
        return
    end
    local filledKeys = {}
    for _, k in ipairs(VISUAL_PATH_KEYS) do
        if visualData[k] == nil and entry[k] ~= nil then
            visualData[k] = entry[k]
            table.insert(filledKeys, k)
        end
    end
    if #filledKeys > 0 then
        Log:trace("defaults: type=%s index=%d minAge=%s filled {%s}",
            typeName, idx, tostring(visualData.minAge), table.concat(filledKeys, ","))
    end
end


function AnimalSystem:initialiseCountries()

    self.maxDealerAnimals = self.maxDealerAnimals or 40
    self.countries = {}
    self.animals = {}
    self.aiAnimals = {}

    for _, animalType in pairs(self.types) do
        self.animals[animalType.typeIndex] = {}
        self.aiAnimals[animalType.typeIndex] = {}
    end


    for countryIndex, country in pairs(RLConstants.AREA_CODES) do

        self.countries[countryIndex] = {
            ["index"] = countryIndex,
            ["farms"] = {}
        }

    end

    MoneyType.MONITOR_SUBSCRIPTIONS = MoneyType.register("monitorSubscriptions", "rl_ui_monitorSubscriptions")
    MoneyType.LAST_ID = MoneyType.LAST_ID + 1

    if self.isServer then g_messageCenter:subscribe(MessageType.HOUR_CHANGED, self.onHourChanged, self) end
    g_messageCenter:subscribe(MessageType.DAY_CHANGED, self.onDayChanged, self)
    g_messageCenter:subscribe(MessageType.PERIOD_CHANGED, self.onPeriodChanged, self)

end


function AnimalSystem:validateFarms(hasData)

    if self.countries == nil then self.countries = {} end

    local animalTypeIndexes = {}

    for _, animalType in pairs(self.types) do table.insert(animalTypeIndexes, animalType.typeIndex) end

    
    -- validate every country exists


    for countryIndex, info in pairs(RLConstants.AREA_CODES) do

        if self.countries[countryIndex] == nil then

            self.countries[countryIndex] = {
                ["index"] = countryIndex,
                ["farms"] = {}
            }

        end

    end


    -- validate all countries have at least 20 unique farms

    local mapCountryIndex = RealisticLivestock.getMapCountryIndex()


    for _, country in pairs(self.countries) do

        local farmIds = {}
        local farmsRequireId = {}

        if country.index == mapCountryIndex then

            for i, farm in pairs(g_farmManager.farms) do

                local statistics = farm.stats.statistics

                if statistics.farmId ~= nil then table.insert(farmIds, statistics.farmId) end

            end

        end

        local isFirstCreation = #country.farms == 0

        if #country.farms < 20 then

            for i = #country.farms + 1, 20 do

                local farm = { ["quality"] = math.random(250, 1750) / 1000, ["ids"] = {} }

                farm.semenPrice = (math.random(75, 125) / 100) * farm.quality

                for i = 0, math.random(0, math.min(3, #animalTypeIndexes)) do

                    local randomAnimalTypeIndex = animalTypeIndexes[math.random(1, #animalTypeIndexes)]
                    local attempts = 0

                    while farm.ids[randomAnimalTypeIndex] ~= nil do

                        randomAnimalTypeIndex = animalTypeIndexes[math.random(1, #animalTypeIndexes)]
                        attempts = attempts + 1

                        if attempts > 20 then break end

                    end

                    farm.ids[randomAnimalTypeIndex] = 0

                end

                table.insert(country.farms, farm)

            end

            if isFirstCreation and country.index == mapCountryIndex then
                
                -- validate there is at least 1 farm that produces each animal type

                for i = 1, #animalTypeIndexes do

                    local randomFarmIndex = math.random(1, #country.farms)
                    country.farms[randomFarmIndex].ids[i] = country.farms[randomFarmIndex].ids[i] or 0

                end

            end

        end


        for i, farm in pairs(country.farms) do
            if farm.id ~= nil then
                table.insert(farmIds, farm.id) 
            else
                table.insert(farmsRequireId, i) 
            end
        end


        for _, farmIndex in pairs(farmsRequireId) do

            local farmId = math.random(100000, 999999)

            while table.find(farmIds, farmId) ~= nil do farmId = math.random(100000, 999999) end

            country.farms[farmIndex].id = farmId
            table.insert(farmIds, farmId)

        end

    end



    -- validate there are at least 25 animals of each type for sale

    if not hasData then
    
        for animalTypeIndex, animals in pairs(self.animals) do

            if #animals < self.maxDealerAnimals then

                for i = #animals + 1, self.maxDealerAnimals do

                    local animal = self:createNewSaleAnimal(animalTypeIndex)

                    if animal ~= nil then table.insert(animals, animal) end

                end

            end

            self.animals[animalTypeIndex] = animals

        end
    
        for animalTypeIndex, animals in pairs(self.aiAnimals) do

            if #animals < 15 then

                for i = #animals + 1, 15 do

                    local animal = self:createNewAIAnimal(animalTypeIndex)

                    if animal ~= nil then table.insert(animals, animal) end

                end

            end

            self.aiAnimals[animalTypeIndex] = animals

        end
   
    end

end


function AnimalSystem:loadColourConfigurations()

    local savegameIndex = g_careerScreen.savegameList.selectedIndex
    local savegame = g_savegameController:getSavegame(savegameIndex)

    if savegame == nil or savegame.savegameDirectory == nil then return false end

    -- Try new filename first, fall back to old filename (migration support)
    local xmlFile = XMLFile.loadIfExists("rm_RlAnimalSystem", savegame.savegameDirectory .. "/rm_RlAnimalSystem.xml")
    local rootKey = "rm_RlAnimalSystem"

    if xmlFile == nil then
        -- Fall back to legacy filename
        xmlFile = XMLFile.loadIfExists("animalSystem", savegame.savegameDirectory .. "/animalSystem.xml")
        rootKey = "animalSystem"
    end

    if xmlFile == nil then return false end

    xmlFile:iterate(rootKey .. ".animalTypes.type", function(_, key)

        local name = xmlFile:getString(key .. "#name")
        local earTagLeft = xmlFile:getVector(key .. "#earTagLeft", { 0.8, 0.7, 0 })
        local earTagRight = xmlFile:getVector(key .. "#earTagRight", { 0.8, 0.7, 0 })
        local earTagLeftText = xmlFile:getVector(key .. "#earTagLeftText", { 0, 0, 0 })
        local earTagRightText = xmlFile:getVector(key .. "#earTagRightText", { 0, 0, 0 })

        if self.nameToType[name] ~= nil then
            self.nameToType[name].colours.earTagLeft = earTagLeft
            self.nameToType[name].colours.earTagRight = earTagRight
            self.nameToType[name].colours.earTagLeft_text = earTagLeftText
            self.nameToType[name].colours.earTagRight_text = earTagRightText
        end

    end)

    xmlFile:delete()

end


function AnimalSystem:loadFromXMLFile()

    if g_currentMission.missionInfo == nil or g_currentMission.missionInfo.savegameDirectory == nil then return end

    local savegameDir = g_currentMission.missionInfo.savegameDirectory

    -- Try new filename first, fall back to old filename (migration support)
    local xmlFile = XMLFile.loadIfExists("rm_RlAnimalSystem", savegameDir .. "/rm_RlAnimalSystem.xml")
    local rootKey = "rm_RlAnimalSystem"

    if xmlFile == nil then
        -- Fall back to legacy filename
        xmlFile = XMLFile.loadIfExists("animalSystem", savegameDir .. "/animalSystem.xml")
        rootKey = "animalSystem"
    end

    -- RLRM settings registries own rm_RlSettings.xml and re-open it themselves.
    -- They run (and reset) regardless of the animal-data file: deleting
    -- rm_RlAnimalSystem.xml is a supported dealer-reroll workaround, and the
    -- registries must still restore (filters/rules/dealer) and reset (the
    -- or-persisted dealer registry) so nothing leaks or gets wiped. The
    -- AnimalType/subTypes registry they resolve against is built at loadMapData,
    -- not from the savegame parse below, so this position is timing-safe.
    RLSettings.loadFiltersFromXMLFile()
    RLSettings.loadRulesFromXMLFile()
    RLSettings.loadDealerSaleFromXMLFile()
    RLDealerSaleApply.resetBaseline()
    RLDealerSaleApply.applyToLiveSubTypes()

    if xmlFile == nil then return false end


    local hasData = false


    xmlFile:iterate(rootKey .. ".countries.country", function(_, key)

        local countryIndex = xmlFile:getInt(key .. "#index")
        
        local farms = self.countries[countryIndex].farms

        xmlFile:iterate(key .. ".farm", function(_, farmKey)

            hasData = true

            local farmId = xmlFile:getInt(farmKey .. "#id")
            local cowId = xmlFile:getInt(farmKey .. "#cowId", nil)
            local pigId = xmlFile:getInt(farmKey .. "#pigId", nil)
            local sheepId = xmlFile:getInt(farmKey .. "#sheepId", nil)
            local horseId = xmlFile:getInt(farmKey .. "#horseId", nil)
            local chickenId = xmlFile:getInt(farmKey .. "#chickenId", nil)
            local quality = xmlFile:getFloat(farmKey .. "#quality", math.random(250, 1750) / 1000)
            local semenPrice = xmlFile:getFloat(farmKey .. "#semenPrice", (math.random(75, 125) / 100) * quality)
            
            local ids = {}

            -- compatibility with previous builds

            if cowId ~= nil then ids[1] = cowId end
            if pigId ~= nil then ids[2] = pigId end
            if sheepId ~= nil then ids[3] = sheepId end
            if horseId ~= nil then ids[4] = horseId end
            if chickenId ~= nil then ids[5] = chickenId end

            xmlFile:iterate(farmKey .. ".id", function(_, idKey)
            
                local animalTypeIndex = xmlFile:getInt(idKey .. "#type", 1)
                local lastId = xmlFile:getInt(idKey .. "#id", 0)

                ids[animalTypeIndex] = lastId
            
            end)
            
            table.insert(farms, { ["id"] = farmId, ["quality"] = quality, ["ids"] = ids, ["semenPrice"] = semenPrice })

        end)

        self.countries[countryIndex].farms = farms

    end)


    xmlFile:iterate(rootKey .. ".animals.animal", function(_, key)

        local animal = Animal.loadFromXMLFile(xmlFile, key)

        if animal ~= nil then
            local animalTypeIndex = animal.animalTypeIndex

            animal.sale = {
                ["day"] = xmlFile:getInt(key .. ".sale#day", 1),
                --["month"] = xmlFile:getInt(key .. ".sale#month"),
                --["year"] = xmlFile:getInt(key .. ".sale#year")
            }

            table.insert(self.animals[animalTypeIndex], animal)
        end

    end)


    xmlFile:iterate(rootKey .. ".aiAnimals.animal", function(_, key)

        local animal = Animal.loadFromXMLFile(xmlFile, key)

        if animal ~= nil then

            animal.favouritedBy = {}
            animal.success = xmlFile:getFloat(key .. "#success", 0.65)
            animal.isAIAnimal = true

            xmlFile:iterate(key .. ".favourites.player", function(_, favKey)
                local userId = xmlFile:getString(favKey .. "#userId", nil)
                local value = xmlFile:getBool(favKey .. "#value", false)
                if userId ~= nil then animal.favouritedBy[userId] = value end
            end)

            local animalTypeIndex = animal.animalTypeIndex
            table.insert(self.aiAnimals[animalTypeIndex], animal)

        end

    end)


    xmlFile:delete()

    return hasData

end


function AnimalSystem:saveToXMLFile(_)

    -- Always save to new filename with versioning (ignore path parameter)
    local savegameDir = g_currentMission.missionInfo.savegameDirectory
    if savegameDir == nil then return end

    local newPath = savegameDir .. "/rm_RlAnimalSystem.xml"
    local xmlFile = XMLFile.create("rm_RlAnimalSystem", newPath, "rm_RlAnimalSystem")
    if xmlFile == nil then return end

    -- Add version attribute for future migrations
    xmlFile:setInt("rm_RlAnimalSystem#version", 1)


    xmlFile:setSortedTable("rm_RlAnimalSystem.animalTypes.type", self.types, function (key, type)

        xmlFile:setString(key .. "#name", type.name)
        xmlFile:setVector(key .. "#earTagLeft", type.colours.earTagLeft)
        xmlFile:setVector(key .. "#earTagLeftText", type.colours.earTagLeft_text)
        xmlFile:setVector(key .. "#earTagRight", type.colours.earTagRight)
        xmlFile:setVector(key .. "#earTagRightText", type.colours.earTagRight_text)

    end)


    xmlFile:setSortedTable("rm_RlAnimalSystem.countries.country", self.countries, function (key, country)

        xmlFile:setInt(key .. "#index", country.index)

        for i = 1, #country.farms do

            local farmKey = string.format("%s.farm(%d)", key, i - 1)
            local farm = country.farms[i]

            xmlFile:setInt(farmKey .. "#id", farm.id)
            xmlFile:setFloat(farmKey .. "#quality", farm.quality)
            xmlFile:setFloat(farmKey .. "#semenPrice", farm.semenPrice)

            local j = 0

            for animalTypeIndex, id in pairs(farm.ids) do

                local idKey = farmKey .. ".id( " .. j .. ")"

                xmlFile:setInt(idKey .. "#type", animalTypeIndex)
                xmlFile:setInt(idKey .. "#id", id)

                j = j + 1

            end

        end

    end)


    local allAnimals = {}

    for _, animals in pairs(self.animals) do

        for _, animal in pairs(animals) do
            if animal.sale ~= nil and animal.sale.day ~= nil then table.insert(allAnimals, animal) end
        end

    end


    xmlFile:setSortedTable("rm_RlAnimalSystem.animals.animal", allAnimals, function (key, animal)

        animal:saveToXMLFile(xmlFile, key)
        xmlFile:setInt(key .. ".sale#day", animal.sale.day)

    end)


    local allAIAnimals = {}

    for _, animals in pairs(self.aiAnimals) do

        for _, animal in pairs(animals) do table.insert(allAIAnimals, animal) end

    end


    xmlFile:setSortedTable("rm_RlAnimalSystem.aiAnimals.animal", allAIAnimals, function (key, animal)

        animal:saveToXMLFile(xmlFile, key)

        xmlFile:setFloat(key .. "#success", animal.success or 0.65)
        
        local i = 0

        for userId, value in pairs(animal.favouritedBy) do
            
            if not value then continue end

            local favKey = string.format("%s.favourites.player(%s)", key, i)
            xmlFile:setString(favKey .. "#userId", userId)
            xmlFile:setBool(favKey .. "#value", true)

            i = i + 1

        end

    end)

    xmlFile:save(false, true)
    xmlFile:delete()

end


--- Pick a sale-animal age that honours per-visual `canBeBought`.
---
--- Builds the buyable-age union from `subType.visuals` (each buyable visual
--- contributes `[v.minAge, nextMinAge-1]`; the last buyable visual extends to
--- `maxBuyAge`). Intersects today's three skew buckets with that union, drops
--- empty buckets and renormalises remaining weights, then uniformly draws an
--- integer age across the chosen bucket's intersected integer ages. When a
--- bucket's intersection splits into multiple disjoint segments, the segment
--- choice is weighted by integer count so the draw is uniform over the union.
---
--- Helper is `g_currentMission`-free so it can be unit-tested with synthetic
--- subTypes and a deterministic `randomFn`. Visuals are assumed ascending by
--- minAge (an invariant maintained by the XML loader).
---
--- @param subType table SubType table with `visuals = { {minAge, store={canBeBought}}, ... }`
--- @param averageBuyAge number Animal-type average buy age (cluster centre)
--- @param maxBuyAge number Animal-type maximum buy age (upper bound)
--- @param randomFn function|nil `function(lo, hi) -> int` for integer draws; defaults to math.random
--- @return number|nil age Integer age in months, or nil if no buyable visuals exist
function AnimalSystem:_pickSaleAnimalAge(subType, averageBuyAge, maxBuyAge, randomFn)
    randomFn = randomFn or math.random

    -- 1. Build buyable union: ascending list of [lo, hi] integer intervals.
    local union = {}
    if subType ~= nil and subType.visuals ~= nil then
        local n = #subType.visuals
        for i = 1, n do
            local visual = subType.visuals[i]
            if visual.store ~= nil and visual.store.canBeBought then
                local lo = visual.minAge
                local hi
                if i < n then
                    hi = subType.visuals[i + 1].minAge - 1
                else
                    hi = maxBuyAge
                end
                if hi >= lo then
                    -- Merge with previous if adjacent / overlapping.
                    local last = union[#union]
                    if last ~= nil and lo <= last[2] + 1 then
                        last[2] = math.max(last[2], hi)
                    else
                        table.insert(union, { lo, hi })
                    end
                end
            end
        end
    end

    if #union == 0 then
        Log:warning("_pickSaleAnimalAge: empty buyable union for subType=%s (buyableSubTypes filter should have excluded this)",
            subType and subType.name or "?")
        return nil
    end

    Log:trace("_pickSaleAnimalAge: subType=%s union segments=%d avg=%s max=%s",
        subType.name, #union, tostring(averageBuyAge), tostring(maxBuyAge))

    -- 2. Three skew buckets with today's weights and boundary formulae.
    --    math.floor matches Lua 5.1 trunc-to-int semantics used by the
    --    legacy inline picker (math.random(a, b) coerces via tonumber+floor).
    local nearLo = math.floor(averageBuyAge * 0.85)
    local nearHi = math.floor(averageBuyAge * 1.15)
    local buckets = {
        { name = "near",  lo = nearLo, hi = nearHi,    weight = 0.500 },
        { name = "below", lo = 0,      hi = nearLo,    weight = 0.375 },
        { name = "above", lo = nearHi, hi = maxBuyAge, weight = 0.125 },
    }

    -- 3. Intersect each bucket with the union. Drop empties; renormalise.
    local kept = {}
    local totalWeight = 0
    for _, bucket in ipairs(buckets) do
        local segments = {}
        local segmentTotal = 0
        for _, iv in ipairs(union) do
            local lo = math.max(bucket.lo, iv[1])
            local hi = math.min(bucket.hi, iv[2])
            if hi >= lo then
                table.insert(segments, { lo, hi })
                segmentTotal = segmentTotal + (hi - lo + 1)
            end
        end
        if segmentTotal > 0 then
            table.insert(kept, {
                name = bucket.name,
                segments = segments,
                segmentTotal = segmentTotal,
                weight = bucket.weight,
            })
            totalWeight = totalWeight + bucket.weight
        end
    end

    if #kept == 0 then
        -- Defensive: a non-empty union means [0, nearLo] (the "below" bucket)
        -- must intersect it, so this branch should be unreachable in practice.
        Log:warning("_pickSaleAnimalAge: all three buckets empty after intersection (subType=%s)",
            subType and subType.name or "?")
        return nil
    end

    -- Renormalise weights of surviving buckets.
    for _, b in ipairs(kept) do
        b.weight = b.weight / totalWeight
    end

    Log:trace("_pickSaleAnimalAge: kept buckets=%d totalWeightPre=%.4f", #kept, totalWeight)
    -- Post-redistribution per-bucket weights (one TRACE line per kept bucket).
    for _, b in ipairs(kept) do
        Log:trace("_pickSaleAnimalAge:   bucket=%s weight=%.4f segments=%d segmentTotal=%d",
            b.name, b.weight, #b.segments, b.segmentTotal)
    end

    -- 4. Pick a bucket by weight. randomFn returns ints, so scale to 1e6 grid.
    local roll = randomFn(1, 1000000)
    local cumulative = 0
    local chosen
    for _, b in ipairs(kept) do
        cumulative = cumulative + b.weight * 1000000
        if roll <= cumulative then
            chosen = b
            break
        end
    end
    -- Floating-point safety: if rounding leaves roll past cumulative, take last.
    if chosen == nil then chosen = kept[#kept] end

    Log:trace("_pickSaleAnimalAge: bucket-roll=%d cumulative=%.0f chosen=%s",
        roll, cumulative, chosen.name)

    -- 5. Pick a segment within the bucket, weighted by integer count.
    local segChoice = randomFn(1, chosen.segmentTotal)
    local chosenSeg
    local seen = 0
    for _, seg in ipairs(chosen.segments) do
        local count = seg[2] - seg[1] + 1
        if segChoice <= seen + count then
            chosenSeg = seg
            break
        end
        seen = seen + count
    end

    Log:trace("_pickSaleAnimalAge: seg-roll=%d of segmentTotal=%d chosen=[%d,%d]",
        segChoice, chosen.segmentTotal, chosenSeg[1], chosenSeg[2])

    -- 6. Uniform integer draw within the chosen segment.
    local age = randomFn(chosenSeg[1], chosenSeg[2])

    -- TRACE (not DEBUG) because this fires per dealer-spawn animal (~1200 per
    -- dealer reset across all types). The dealer-reset event emits a single
    -- INFO summary at the loop boundary, so DEBUG-level dealer signal is
    -- preserved without flooding. Investigation: `rmSetLoglevel * TRACE`.
    Log:trace("_pickSaleAnimalAge: subType=%s age=%d (bucket=%s segment=[%d,%d])",
        subType.name, age, chosen.name, chosenSeg[1], chosenSeg[2])

    return age
end


--- Build a new sale animal for the dealer of the given animal type.
--- Selects a buyable subtype (respecting bridge `canBeBought` overrides), assigns
--- random genetics + age, and may create an in-progress pregnancy. If the
--- pregnancy block produces no children, the orphaned-state cleanup at the
--- tail of this function delegates to AnimalReproduction._clearOrphanedPregnancy
--- so the canonical four-field clear runs (pregnancy + impregnatedBy +
--- isPregnant + reproduction) - mirrors the in-game pen-side cleanup so the
--- invariant `isPregnant <=> pregnancy ~= nil` holds for sale animals too.
--- Age picker honours per-visual `canBeBought` via `_pickSaleAnimalAge`.
--- Genetics come from `RLGeneticsDraw.draw`, which is called before `Animal.new`
--- so stored health, genetic diseases and offspring all derive from them.
--- @param animalTypeIndex number Index into the animal-type registry
--- @return table|nil animal Newly built sale animal, or nil if the animal-type lookup fails
function AnimalSystem:createNewSaleAnimal(animalTypeIndex)

    local animalType = self:getTypeByIndex(animalTypeIndex)

    if animalType == nil then return nil end

    -- Filter to subtypes with at least one buyable visual (respects bridge canBeBought overrides)
    local buyableSubTypes = {}
    for _, stIdx in ipairs(animalType.subTypes) do
        local st = self:getSubTypeByIndex(stIdx)
        if st ~= nil and st.visuals ~= nil then
            for _, visual in ipairs(st.visuals) do
                if visual.store ~= nil and visual.store.canBeBought then
                    table.insert(buyableSubTypes, stIdx)
                    break
                end
            end
        end
    end

    if #buyableSubTypes == 0 then return nil end

    local subTypeIndex = buyableSubTypes[math.random(1, #buyableSubTypes)]
    local subType = self:getSubTypeByIndex(subTypeIndex)
    
    local farmId, farmQuality, farmCountryIndex, lastAnimalId
    local attemptedCountryIndexes = {}

    
    while farmId == nil do

        if #attemptedCountryIndexes == #self.countries then return nil end

        local countryIndex
        local wasMapPick = false

        if #attemptedCountryIndexes == 0 and math.random() >= 0.12 then
            countryIndex = RealisticLivestock.getMapCountryIndex()
            wasMapPick = true
        else
            countryIndex = math.random(1, #self.countries)
            while table.find(attemptedCountryIndexes, countryIndex) ~= nil do
                countryIndex = math.random(1, #self.countries)
            end
        end

        table.insert(attemptedCountryIndexes, countryIndex)

        local country = self.countries[countryIndex]
        local validFarms = {}

        for i = 1, #country.farms do
        
            local farm = country.farms[i]

            if farm.ids[animalTypeIndex] ~= nil then table.insert(validFarms, i) end

        end

        if #validFarms == 0 then
            if wasMapPick then
                Log:debug("createNewSaleAnimal: map/override country %d has no valid farms for animalTypeIndex=%d; cycling random countries", countryIndex, animalTypeIndex)
            end
            continue
        end

        local farmIndex = validFarms[math.random(1, #validFarms)]
        local farm = country.farms[farmIndex]

        farmId = farm.id
        farmQuality = farm.quality
        farmCountryIndex = countryIndex

        farm.ids[animalTypeIndex] = (farm.ids[animalTypeIndex] or 0) + 1
        lastAnimalId = farm.ids[animalTypeIndex]

    end


    local averageBuyAge = animalType.averageBuyAge or 12
    local maxBuyAge = animalType.maxBuyAge or 60

    -- per-stage canBeBought-aware age picker. Helper guarantees range and
    -- returns nil only if subType has zero buyable visuals (which the
    -- buyableSubTypes filter above already excludes).
    local age = self:_pickSaleAnimalAge(subType, averageBuyAge, maxBuyAge)
    if age == nil then return nil end
    local viableReproductionMonths = age - (subType.reproductionMinAgeMonth + subType.reproductionDurationMonth)
    local isParent, isPregnant, monthsSinceLastBirth = false, false, 12
    local animalGender = subType.gender


    if viableReproductionMonths >= 0 and math.random(0, 100) <= viableReproductionMonths then
        isParent = true
        monthsSinceLastBirth = math.random(0, viableReproductionMonths)
    end

    -- Guard against pregnancy for non-reproductive subtypes (e.g. BULL, DOG).
    -- Without this, gender auto-detection mismatches can create pregnant males.
    if subType.supportsReproduction and animalGender == "female" and age - subType.reproductionMinAgeMonth >= 0 and math.random() >= 0.95 then
        isPregnant = true
        Log:debug("createNewSaleAnimal: pregnant %s(%d) age=%d", subType.name or "?", subTypeIndex, age)
    end



    local uniqueId = RLAnimalUtil.generateUniqueId(farmId, lastAnimalId)


    -- Genetics come from the shared bell draw, which centres every sale animal
    -- on its own base quality rather than on the source farm's. Productivity is
    -- drawn only for the types that carry it.
    local traitKeys = (animalTypeIndex == AnimalType.COW or animalTypeIndex == AnimalType.SHEEP
        or animalTypeIndex == AnimalType.CHICKEN)
        and RLGeneticsDraw.TRAITS_WITH_PRODUCTIVITY or RLGeneticsDraw.TRAITS_BASE

    local genetics = RLGeneticsDraw.draw(traitKeys)

    -- Reshape the base draw into the active dealer-quality preset's band. This
    -- MUST sit before Animal.new: the stored health argument, the targetWeight
    -- derivation in the constructor, the disease pass and the pregnant-offspring
    -- bands all read this table, so reshaping afterwards would leave them on the
    -- unreshaped values. It must also stay BEFORE the name draw below: under a
    -- non-default preset the reshape consumes an outlier draw from the SHARED
    -- math.random stream, so moving it past the name draw would change which
    -- animals get names. Standard is the identity preset - it returns the table
    -- unchanged and consumes no draw at all.
    local presetIndex = RLDealerQualityResolver.getActiveIndex()
    local reshaped, wasOutlier = RLDealerQualityModel.reshapeGenetics(genetics, presetIndex)

    if reshaped ~= nil then
        genetics = reshaped                     -- MUST reassign: reshapeGenetics is non-mutating

        -- Level-guarded: Lua evaluates call arguments before the logger can check
        -- its level, so the getPreset lookup and the string.format below would be
        -- paid on every generated animal even at ERROR. Mirrors the dealer-list
        -- digest guard in RLMenuBuyFrame.
        if Log.level >= RmLogging.LOG_LEVEL.DEBUG then
            Log:debug("createNewSaleAnimal: reshaped genetics preset=%d(%s) outlier=%s met=%.3f qua=%.3f fer=%.3f hea=%.3f prd=%s",
                presetIndex, RLDealerQualityModel.getPreset(presetIndex).key, tostring(wasOutlier),
                genetics.metabolism, genetics.quality, genetics.fertility, genetics.health,
                genetics.productivity ~= nil and string.format("%.3f", genetics.productivity) or "-")
        end
    elseif not warnedReshapeReturnedNil then
        warnedReshapeReturnedNil = true
        Log:warning("createNewSaleAnimal: reshapeGenetics returned nil (preset=%s); keeping raw genetics",
            tostring(presetIndex))
    end


    local name
    
    if math.random() >= 0.85 then name = g_currentMission.animalNameSystem:getRandomName(animalGender) end


    local animal = Animal.new({
        age = age,
        health = math.clamp((math.random(650, 1000) / 10) * genetics.health, 0, 100),
        monthsSinceLastBirth = monthsSinceLastBirth,
        gender = animalGender,
        subTypeIndex = subTypeIndex,
        isParent = isParent,
        isPregnant = isPregnant,
        isLactating = animalTypeIndex == AnimalType.COW and animalGender == "female"
            and isParent and monthsSinceLastBirth < 10,
        name = name,
        genetics = genetics
    })

    animal.farmId = tostring(farmId)
    animal.uniqueId = uniqueId
    animal.birthday.country = farmCountryIndex

    local variations = self:getVisualByAge(subTypeIndex, age).visualAnimal.variations
    local variationIndex = 1

    if #variations > 1 then variationIndex = math.random(1, #variations) end

    animal.variation = variationIndex

    local environment = g_currentMission.environment
    local month = environment.currentPeriod + 2

    if month > 12 then month = month - 12 end

    local day = 1 + math.floor((environment.currentDayInPeriod - 1) * (getDaysInMonth(month) / environment.daysPerPeriod))
    local year = environment.currentYear


    animal.diseases = {}

    g_diseaseManager:onDayChanged(animal)
    g_diseaseManager:setGeneticDiseasesForSaleAnimal(animal)


    if isPregnant then

        local childNum = animal:generateRandomOffspring()
        local children = {}

        Log:trace("createNewSaleAnimal: generating %d offspring for %s(%d)",
            childNum, subType.name or "?", subTypeIndex)

        local minMetabolism, maxMetabolism = genetics.metabolism * 0.9, genetics.metabolism * 1.1
        local minMeat, maxMeat = genetics.quality * 0.9, genetics.quality * 1.1
        local minHealth, maxHealth = genetics.health * 0.9, genetics.health * 1.1
        local minFertility, maxFertility = genetics.fertility * 0.9, genetics.fertility * 1.1
        local minProductivity, maxProductivity
        
        if genetics.productivity ~= nil then minProductivity, maxProductivity = genetics.productivity * 0.9, genetics.productivity * 1.1 end

        for i = 1, childNum do

            local gender = math.random() >= 0.5 and "male" or "female"
            local childSubTypeIndex = subTypeIndex + (gender == "male" and 1 or 0)

            -- Validate subtype index - the +1 arithmetic assumes adjacent
            -- male/female subtypes, which fails for bridge-added exotic types.
            local candidateSubType = self:getSubTypeByIndex(childSubTypeIndex)

            if candidateSubType == nil or candidateSubType.gender ~= gender or candidateSubType.typeIndex ~= animalType.typeIndex then
                local breedFallback = nil
                local genderFallback = nil

                for _, stIndex in pairs(animalType.subTypes) do
                    local st = self:getSubTypeByIndex(stIndex)
                    if st ~= nil and st.gender == gender then
                        if genderFallback == nil then
                            genderFallback = stIndex
                        end
                        if st.breed == subType.breed then
                            breedFallback = stIndex
                            break
                        end
                    end
                end

                local fallbackIndex = breedFallback or genderFallback

                if fallbackIndex ~= nil then
                    Log:debug("createNewSaleAnimal: child[%d] subtype fallback for gender '%s' breed '%s': index %d -> %d (breedMatch=%s)",
                        i, gender, subType.breed or "?", childSubTypeIndex, fallbackIndex, tostring(breedFallback ~= nil))
                    childSubTypeIndex = fallbackIndex
                else
                    Log:debug("createNewSaleAnimal: child[%d] no fallback found for gender '%s' in type %d, keeping index %d",
                        i, gender, animalType.typeIndex, childSubTypeIndex)
                end
            end

            local resolvedSubType = self:getSubTypeByIndex(childSubTypeIndex)
            local childBreed = resolvedSubType and resolvedSubType.breed or "?"
            local childSubTypeName = resolvedSubType and resolvedSubType.name or "?"
            Log:debug("createNewSaleAnimal child[%d]: gender=%s, parent=%s(idx=%d) breed=%s -> child=%s(idx=%d) breed=%s",
                i, gender, subType.name, subTypeIndex, subType.breed or "?",
                childSubTypeName, childSubTypeIndex, childBreed)

            if childBreed ~= "?" and childBreed ~= (subType.breed or "") then
                Log:warning("Sale animal breed switch: parent=%s child got %s (idx=%d %s)",
                    subType.breed or "?", childBreed, childSubTypeIndex, childSubTypeName)
            end

            local child = Animal.new({
                age = -1, health = 100, gender = gender,
                subTypeIndex = childSubTypeIndex,
                motherId = animal:getIdentifiers()
            })

            local metabolism = math.random(minMetabolism * 100, maxMetabolism * 100) / 100
            local quality = math.random(minMeat * 100, maxMeat * 100) / 100
            local healthGenetics = math.random(minHealth * 100, maxHealth * 100) / 100
            local fertility = math.random(minFertility * 100, maxFertility * 100) / 100
            local productivity = nil
                        
            if genetics.productivity ~= nil then productivity = math.clamp(math.random(minProductivity * 100, maxProductivity * 100) / 100, 0.25, 1.75) end


            child:setGenetics({
                ["metabolism"] = math.clamp(metabolism, 0.25, 1.75),
                ["quality"] = math.clamp(quality, 0.25, 1.75),
                ["health"] = math.clamp(healthGenetics, 0.25, 1.75),
                ["fertility"] = math.clamp(fertility, 0.25, 1.75),
                ["productivity"] = productivity
            })
        
        
            for _, disease in pairs(animal.diseases) do

                disease:affectReproduction(child)

            end


            table.insert(children, child)

        end


        local reproductionDuration = subType.reproductionDurationMonth
                    
        if math.random() >= 0.99 then

            if math.random() >= 0.95 then
                reproductionDuration = reproductionDuration + math.random() >= 0.75 and -2 or 2
            else
                reproductionDuration = reproductionDuration + math.random() >= 0.85 and -1 or 1
            end

            reproductionDuration = math.max(reproductionDuration, 2)

        end

        local expectedYear = year + math.floor(reproductionDuration / 12)
        local expectedMonth = month + (reproductionDuration % 12)

        while expectedMonth > 12 do
            expectedMonth = expectedMonth - 12
            expectedYear = expectedYear + 1
        end

        local expectedDay = math.random(1, getDaysInMonth(expectedMonth))

        if #children > 0 then

            animal.pregnancy = {
                ["duration"] = reproductionDuration,
                ["expected"] = {
                    ["day"] = expectedDay,
                    ["month"] = expectedMonth,
                    ["year"] = expectedYear
                },
                ["pregnancies"] = children
            }

        end

    end

    animal.sale = {
        --["day"] = day,
        --["month"] = month,
        --["year"] = year
        ["day"] = environment.currentMonotonicDay
    }

    -- Orphaned pregnancy state cleanup for sale animals: the children
    -- generation block produced no usable children, so the pregnancy table
    -- assignment was skipped while animal.isPregnant was set true earlier
    -- in this function. Delegate to the shared helper so the canonical
    -- four-field clear runs (pregnancy + impregnatedBy + isPregnant +
    -- reproduction).
    --
    -- Guard differs from site 1 (advancePregnancy) on purpose: this flow
    -- never assigns animal.reproduction, so the pen-side `reproduction > 0`
    -- precondition would be unreachable here (Animal.new defaults
    -- reproduction to 0). Gate on the actual invariant violation instead:
    -- isPregnant=true paired with no usable pregnancy data.
    if animal.isPregnant and (animal.pregnancy == nil or #animal.pregnancy.pregnancies == 0) then
        AnimalReproduction._clearOrphanedPregnancy(animal, "pregnancy-nil")
    end

    return animal

end


function AnimalSystem:getSaleAnimalsByTypeIndex(animalTypeIndex)

    return self.animals[animalTypeIndex] or {}

end


function AnimalSystem:getAIAnimalsByTypeIndex(animalTypeIndex)

    return self.aiAnimals[animalTypeIndex] or {}

end


function AnimalSystem:getFarmQuality(country, farmId)

    if self.countries[country] ~= nil then

        local farms = self.countries[country].farms

        if type(farmId) == "string" then farmId = tonumber(farmId) end

        for _, farm in pairs(farms) do

            if farm.id == farmId then return farm.quality end

        end

    end

    return 1

end


function AnimalSystem:getFarmSemenPrice(country, farmId)

    if self.countries[country] ~= nil then

        local farms = self.countries[country].farms

        if type(farmId) == "string" then farmId = tonumber(farmId) end

        for _, farm in pairs(farms) do

            if farm.id == farmId then return farm.semenPrice end

        end

    end

    return 1

end


function AnimalSystem:getNextAnimalIdForFarm(countryIndex, animalTypeIndex, farmId)

    local country = self.countries[countryIndex]

    if country == nil then return 1 end

    local farms = country.farms

    if type(farmId) == "string" then farmId = tonumber(farmId) end

    for _, farm in pairs(farms) do

        if farm.id == farmId then

            if farm.ids[animalTypeIndex] ~= nil then

                farm.ids[animalTypeIndex] = farm.ids[animalTypeIndex] + 1
                return farm.ids[animalTypeIndex]

            end

            return 1

        end

    end

    return 1

end


function AnimalSystem:removeSaleAnimal(animalTypeIndex, countryIndex, farmId, uniqueId)
    RLAnimalUtil.findAndRemove(self.animals[animalTypeIndex], farmId, uniqueId, countryIndex)
end


function AnimalSystem:removeAIAnimal(animalTypeIndex, countryIndex, farmId, uniqueId)
    RLAnimalUtil.findAndRemove(self.aiAnimals[animalTypeIndex], farmId, uniqueId, countryIndex)
end


function AnimalSystem:onHourChanged()
    RmSafeUtils.safeCall("AnimalSystem:onHourChanged", function()

        local day = g_currentMission.environment.currentMonotonicDay
        local hasChanges = false

        -- Retention below divides by the animal's mean genetics, so reshaping the
        -- generated genetics into a preset band would silently reprogram how fast the
        -- dealer rotates: budget pushes the threshold to or past 1.0, which makes the
        -- removal branch unreachable and freezes the shelf, and premium roughly halves
        -- shelf life. Normalising by the band midpoint keeps the rotation rate matched
        -- to the identity preset under every preset, while an animal that is better
        -- than its own preset's peers still turns over faster. The identity band's
        -- midpoint is exactly 1.0, so standard saves are unchanged.
        -- The pool is regenerated whenever the preset changes, so the active preset is
        -- the one this stock was generated under.
        local activePreset = RLDealerQualityModel.getPreset(RLDealerQualityResolver.getActiveIndex())
        local bandMidpoint = (activePreset.lo + activePreset.hi) / 2

        for animalTypeIndex, animals in pairs(self.animals) do

            local indexesToRemove = {}

            for i, animal in pairs(animals) do

                if animal.sale ~= nil then

                    local saleDay = animal.sale.day

                    if saleDay == day then continue end

                    local geneticQuality = 0
                    local totalGenetics = 0

                    for _, value in pairs(animal.genetics) do
                        if value ~= nil then
                            totalGenetics = totalGenetics + 1
                            geneticQuality = geneticQuality + value
                        end
                    end

                    local averageGenetics = geneticQuality / totalGenetics

                    if math.random() >= (saleDay / day) / ((averageGenetics / bandMidpoint) * 1.45) then
                        table.insert(indexesToRemove, i)
                        hasChanges = true
                    end

                end

            end

            for i = #indexesToRemove, 1, -1 do
                table.remove(animals, indexesToRemove[i])
            end

            local threshold = math.random(10, self.maxDealerAnimals)

            if #animals < threshold then

                for i = #animals + 1, threshold do

                    local animal = self:createNewSaleAnimal(animalTypeIndex)

                    if animal ~= nil then
                        table.insert(animals, animal)
                        hasChanges = true
                    end

                end

            end

        end

        for animalTypeIndex, animals in pairs(self.aiAnimals) do

            if #animals < 15 then

                for i = #animals + 1, 15 do

                    local animal = self:createNewAIAnimal(animalTypeIndex)

                    if animal ~= nil then
                        table.insert(animals, animal)
                        hasChanges = true
                    end

                end

            end

        end

        if hasChanges then g_server:broadcastEvent(AnimalSystemStateEvent.new(self.countries, self.animals, self.aiAnimals)) end

    end)
end


function AnimalSystem:onDayChanged()
    RmSafeUtils.safeCall("AnimalSystem:onDayChanged", function()

        local environment = g_currentMission.environment
        local month = environment.currentPeriod + 2
        local currentDayInPeriod = environment.currentDayInPeriod

        if month > 12 then month = month - 12 end

        local daysPerPeriod = environment.daysPerPeriod
        local day = 1 + math.floor((currentDayInPeriod - 1) * (getDaysInMonth(month) / daysPerPeriod))
        local year = environment.currentYear

        for _, animals in pairs(self.animals) do

            for _, animal in pairs(animals) do

                animal.reserved = false

                RmSafeUtils.safeAnimalCall(animal, "AnimalSystem:onDayChanged", function()
                    animal:onDayChanged(nil, self.isServer, day, month, year, currentDayInPeriod, daysPerPeriod, true)
                end)

            end

        end

        for _, animals in pairs(self.aiAnimals) do

            for _, animal in pairs(animals) do
                RmSafeUtils.safeAnimalCall(animal, "AnimalSystem:onDayChanged(ai)", function()
                    animal:onDayChanged(nil, self.isServer, day, month, year, currentDayInPeriod, daysPerPeriod, true)
                end)
            end

        end

    end)
end


function AnimalSystem:onPeriodChanged()
    RmSafeUtils.safeCall("AnimalSystem:onPeriodChanged", function()

        for _, animals in pairs(self.animals) do

            for _, animal in pairs(animals) do
                RmSafeUtils.safeAnimalCall(animal, "onPeriodChanged", function()
                    animal:onPeriodChanged()
                end)
            end

        end

        for _, animals in pairs(self.aiAnimals) do

            for _, animal in pairs(animals) do
                RmSafeUtils.safeAnimalCall(animal, "onPeriodChanged", function()
                    animal:onPeriodChanged()
                end)
            end

        end

        if self.isServer then

            local monitorCosts = {}

            for _, placeable in pairs(g_currentMission.husbandrySystem.placeables) do

                local animals = placeable:getClusters()
                local ownerFarmId = placeable:getOwnerFarmId()

                for _, animal in pairs(animals) do

                    if animal.monitor == nil then continue end

                    if not animal.monitor.active and not animal.monitor.removed then continue end

                    if animal.monitor.removed and not animal.monitor.active then

                        local visualData = self:getVisualByAge(animal.subTypeIndex, animal.age)

                        if visualData.monitor ~= nil and animal.idFull ~= nil and animal.idFull ~= "1-1" then

                            local sep = string.find(animal.idFull, "-")
                            local husbandry = tonumber(string.sub(animal.idFull, 1, sep - 1))
                            local animalId = tonumber(string.sub(animal.idFull, sep + 1))

                            if husbandry ~= 0 and animalId ~= 0 then

                                local rootNode = getAnimalRootNode(husbandry, animalId)

                                if rootNode ~= 0 then

                                    local monitorNode = I3DUtil.indexToObject(rootNode, visualData.monitor)

                                    if monitorNode ~= nil and monitorNode ~= 0 then setVisibility(monitorNode, false) end

                                end

                            end

                        end

                        animal.monitor.removed = false

                    end

                    if monitorCosts[ownerFarmId] == nil then monitorCosts[ownerFarmId] = 0 end

                    monitorCosts[ownerFarmId] = monitorCosts[ownerFarmId] + animal.monitor.fee

                end

            end

            for ownerFarmId, cost in pairs(monitorCosts) do

                local ownerFarm = g_farmManager:getFarmById(ownerFarmId)

                g_currentMission:addMoneyChange(0 - cost, ownerFarmId, MoneyType.MONITOR_SUBSCRIPTIONS, true)
                ownerFarm:changeBalance(0 - cost, MoneyType.MONITOR_SUBSCRIPTIONS)

            end

        end

    end)
end


function AnimalSystem:addExistingSaleAnimal(animal)

    local animalTypeIndex = animal.animalTypeIndex or 0

    if self.animals[animalTypeIndex] ~= nil then table.insert(self.animals[animalTypeIndex], animal) end

end


function AnimalSystem:removeAllSaleAnimals(animalTypeIndex)

    if animalTypeIndex == nil then

        for index, animals in pairs(self.animals) do self.animals[index] = {} end

    elseif self.animals[animalTypeIndex] ~= nil then

        self.animals[animalTypeIndex] = {}

    end

end


function AnimalSystem.onSettingChanged(name, state)

    g_currentMission.animalSystem[name] = state

end


function AnimalSystem.onClickResetDealer()
    RL_ResetDealerEvent.sendEvent(RL_ResetDealerEvent.TYPE_DEALER)
end


function AnimalSystem.onClickResetAIAnimals()
    RL_ResetDealerEvent.sendEvent(RL_ResetDealerEvent.TYPE_AI_ANIMALS)
end


function AnimalSystem:getBreedsByAnimalTypeIndex(animalTypeIndex)

    return self.types[animalTypeIndex].breeds

end


--- Build a new AI-stock sire of the given animal type.
--- Male subtypes only; the source farm must carry the animal type and a farm
--- quality of at least 1.35, so AI sires skew toward high-genetics origins.
--- @param animalTypeIndex number Index into the animal-type registry
--- @return table|nil animal Newly built AI animal, or nil if no male subtype or source farm resolves
function AnimalSystem:createNewAIAnimal(animalTypeIndex)

     local animalType = self:getTypeByIndex(animalTypeIndex)

    if animalType == nil then return nil end

    local validSubTypes = {}

    for _, subTypeIndex in pairs(animalType.subTypes) do

        local subType = self:getSubTypeByIndex(subTypeIndex)

        if subType.gender == "male" then table.insert(validSubTypes, subType) end

    end

    if #validSubTypes == 0 then return nil end

    local subType = validSubTypes[math.random(1, #validSubTypes)]

    if subType == nil then return end

    local subTypeIndex = subType.subTypeIndex
    
    local farmId, farmQuality, farmCountryIndex, lastAnimalId
    local attemptedCountryIndexes = {}
    
    while farmId == nil do

        if #attemptedCountryIndexes == #self.countries then return nil end

        local countryIndex
        local wasMapPick = false

        if #attemptedCountryIndexes == 0 and math.random() >= 0.12 then
            countryIndex = RealisticLivestock.getMapCountryIndex()
            wasMapPick = true
        else
            countryIndex = math.random(1, #self.countries)
            while table.find(attemptedCountryIndexes, countryIndex) ~= nil do
                countryIndex = math.random(1, #self.countries)
            end
        end

        table.insert(attemptedCountryIndexes, countryIndex)

        local country = self.countries[countryIndex]
        local validFarms = {}

        for i = 1, #country.farms do
        
            local farm = country.farms[i]

            if farm.ids[animalTypeIndex] ~= nil and farm.quality >= 1.35 then table.insert(validFarms, i) end

        end

        if #validFarms == 0 then
            if wasMapPick then
                Log:debug("createNewAIAnimal: map/override country %d has no valid farms for animalTypeIndex=%d; cycling random countries", countryIndex, animalTypeIndex)
            end
            continue
        end

        local farmIndex = validFarms[math.random(1, #validFarms)]
        local farm = country.farms[farmIndex]

        farmId = farm.id
        farmQuality = farm.quality
        farmCountryIndex = countryIndex

        farm.ids[animalTypeIndex] = (farm.ids[animalTypeIndex] or 0) + 1
        lastAnimalId = farm.ids[animalTypeIndex]

    end

    local age = math.random(subType.reproductionMinAgeMonth, subType.reproductionMinAgeMonth * 3)

    local uniqueId = RLAnimalUtil.generateUniqueId(farmId, lastAnimalId)


    local geneticsModifier = farmQuality * 1000
    local genetics = {
        ["metabolism"] = math.clamp(math.random(geneticsModifier - 300, geneticsModifier + 300) / 1000, 1.15, 1.75),
        ["quality"] = math.clamp(math.random(geneticsModifier - 300, geneticsModifier + 300) / 1000, 1.15, 1.75),
        ["fertility"] = math.clamp(math.random(geneticsModifier - 300, geneticsModifier + 300) / 1000, 1.15, 1.75),
        ["health"] = math.clamp(math.random(geneticsModifier - 300, geneticsModifier + 300) / 1000, 1.15, 1.75)
    }

    if animalTypeIndex == AnimalType.COW or animalTypeIndex == AnimalType.SHEEP or animalTypeIndex == AnimalType.CHICKEN then genetics.productivity = math.clamp(math.random(geneticsModifier - 300, geneticsModifier + 300) / 1000, 1.15, 1.75) end

  
    local name = g_currentMission.animalNameSystem:getRandomName("male")


    local animal = Animal.new({
        age = age,
        health = math.clamp((math.random(650, 1000) / 10) * genetics.health, 75, 100),
        gender = "male",
        subTypeIndex = subTypeIndex,
        name = name,
        genetics = genetics
    })

    animal.farmId = tostring(farmId)
    animal.uniqueId = uniqueId
    animal.birthday.country = farmCountryIndex

    local variations = self:getVisualByAge(subTypeIndex, age).visualAnimal.variations
    local variationIndex = 1

    if #variations > 1 then variationIndex = math.random(1, #variations) end

    animal.variation = variationIndex

    animal.favouritedBy = {}
    animal.success = math.clamp((math.random(35, 50) * genetics.fertility) / 100, 0.5, 1)
    animal.isAIAnimal = true

    return animal

end