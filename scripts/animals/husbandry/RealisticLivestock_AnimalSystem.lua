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

-- Absolute upper bound, in game days, on how long one animal may sit on the
-- dealer's shelf. It backstops the genetics retention roll in onHourChanged,
-- whose threshold can reach or exceed 1.0 and then never rotates that listing
-- again for the rest of the playthrough.
--
-- Why 2 and not some other number: `animal.sale.day` is a whole-day counter, so
-- nothing below 1 day is expressible without adding a persisted field. 1 day
-- wipes and regenerates the entire shelf daily, and 7/14/30 leave the runaway
-- essentially unbounded - which leaves 2 and 3 as the only usable values, with 2
-- measuring the flatter shelf at a generation rate the mod already sustains.
--
-- What the constant actually bounds is the FROZEN tail, not ordinary stock: a
-- healthy listing at a mean around 1.0 is rotated by the roll long before it
-- reaches either candidate value, so 2-vs-3 is nearly inert for it. The cap
-- earns its place only where the roll cannot act at all.
local SALE_LISTING_MAX_AGE_DAYS = 2

-- Published so tests pin the boundary against the real value instead of a magic
-- offset, and so raising it does not turn every age fixture into a silent lie.
AnimalSystem.SALE_LISTING_MAX_AGE_DAYS = SALE_LISTING_MAX_AGE_DAYS

-- One-shot warning latches for the hourly sale-pool rotation. ONE flag PER
-- DETECTION SITE, never one shared flag: these causes are independent, and a
-- fired warning must not silence a different diagnostic. The sites sit inside
-- the per-listing loop, so an unlatched WARNING would fire once per bad listing
-- per type every game hour. Lifetime is the MAP LOAD: FS25 re-sources every mod
-- file on each load, so every flag resets then.
--
-- Grouped in one table only so the suite can restore them after driving a
-- deliberately-malformed fixture through the real tick; each key is still its
-- own independent latch.
local saleRotationWarnLatches = {
    badDay = false,
    saleDay = false,
    age = false,
    band = false,
    genetics = false,
    geneticsEmpty = false,
    geneticsMean = false,
}


-- One-shot latches for the reasons sale-animal GENERATION declines to produce an
-- animal. Keyed "<site>:<animalTypeIndex>" rather than by site alone: one type
-- being unable to generate must not silence the notice for a different type.
-- Same MAP LOAD lifetime as the rotation latches above (re-sourced on each load).
--
-- Why this exists: the restock loop calls createNewSaleAnimal up to
-- math.random(10, maxDealerAnimals) times an hour and only checks for nil, so
-- every decline looked identical from the log. The hourly summary reports
-- "restocked 0 of N attempted", which says generation produced nothing but not
-- WHICH of the three declines fired - and that distinction is the whole
-- diagnosis.
local saleGenerationBailLatches = {}


--- Name the reason a sale-animal generation attempt produced nothing, ONCE per
--- (site, animal type) per map load.
---
--- Level is the caller's to choose because the audiences differ: an owner having
--- switched a whole animal type off is a PLAYER-facing answer to "why does the
--- dealer never stock cows", so it goes out at INFO where it is visible without
--- turning on debug logging. The other declines are maintainer-facing and stay at
--- DEBUG. None of them is a WARNING - every one is a legitimate configuration,
--- not a defect.
---
--- The latch is set AFTER the log call returns, matching warnMalformedSaleListing:
--- setting it first means a diagnostic that raises leaves the latch burnt, having
--- silenced every later attempt while never producing the message it consumed.
---@param site string Detection-site key - one per decline branch
---@param animalTypeIndex number The type that could not be generated
---@param level string "info" for the player-facing decline, "debug" otherwise
---@param message string Fully-formatted message
local function noteSaleGenerationBail(site, animalTypeIndex, level, message)
    local latchKey = site .. ":" .. tostring(animalTypeIndex)
    if saleGenerationBailLatches[latchKey] then return end

    if level == "info" then
        Log:info(message)
    else
        Log:debug(message)
    end

    saleGenerationBailLatches[latchKey] = true
end


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

    if animalType == nil then
        noteSaleGenerationBail("noAnimalType", animalTypeIndex, "debug", string.format(
            "createNewSaleAnimal: no animal type is registered at index %d, so the dealer cannot "
            .. "generate stock for it. Further attempts this map load are silent.",
            animalTypeIndex))
        return nil
    end

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

    -- Player-facing (INFO): this is the answer to "why does the dealer never have
    -- any cows". Every subtype of the type is marked not-buyable - by the dealer
    -- sale-availability settings, or by a map/bridge canBeBought override - so the
    -- hourly restock will keep attempting and keep producing nothing.
    if #buyableSubTypes == 0 then
        noteSaleGenerationBail("noBuyableSubTypes", animalTypeIndex, "info", string.format(
            "The animal dealer will not stock %s: every subtype is currently set to not buyable "
            .. "(dealer sale-availability settings, or a map/mod override). Change it in the "
            .. "Realistic Livestock settings if that was not intended. Said once per map load.",
            RLAnimalUtil.getAnimalTypeDisplayName(animalType)))
        return nil
    end

    local subTypeIndex = buyableSubTypes[math.random(1, #buyableSubTypes)]
    local subType = self:getSubTypeByIndex(subTypeIndex)

    local farmId, farmQuality, farmCountryIndex, lastAnimalId
    local attemptedCountryIndexes = {}


    while farmId == nil do

        if #attemptedCountryIndexes == #self.countries then
            noteSaleGenerationBail("noValidFarms", animalTypeIndex, "debug", string.format(
                "createNewSaleAnimal: no country has a source farm that keeps %s (%d attempted), "
                .. "so generation produces nothing until the country/farm data changes. "
                .. "Further attempts this map load are silent.",
                RLAnimalUtil.getAnimalTypeDisplayName(animalType), #attemptedCountryIndexes))
            return nil
        end

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
    elseif not warnedReshapeReturnedNil then
        warnedReshapeReturnedNil = true
        Log:warning("createNewSaleAnimal: reshapeGenetics returned nil (preset=%s); keeping raw genetics",
            tostring(presetIndex))
    end


    local name

    if math.random() >= 0.85 then name = g_currentMission.animalNameSystem:getRandomName(animalGender) end


    -- Bound to a local so the value handed to the constructor can be logged beside
    -- the genetics it derives from - the two numbers whose ratio shows whether the
    -- reshape preceded construction. Its position is load-bearing in THREE ways and
    -- each has a different failure mode:
    --   AFTER the reshape above  - otherwise stored health derives from unreshaped
    --                              genetics, which IS the post-hoc dealer-quality
    --                              defect this whole seam exists to prevent.
    --   AFTER the name draw      - the name gate directly above draws from the same
    --                              math.random stream, so lifting this roll over it
    --                              swaps the two draws and silently changes WHICH
    --                              animals get names for a given seed.
    --   BEFORE Animal.new        - the constructor consumes the value.
    local storedHealth = math.clamp((math.random(650, 1000) / 10) * genetics.health, 0, 100)

    -- Level-guarded: Lua evaluates call arguments before the logger can check its
    -- level, so the getPreset lookup and the string.format below would be paid on
    -- every generated animal even at ERROR. Exactly ONE line per generated animal,
    -- carrying the health as it was BEFORE the disease pass. Triage aid, not a
    -- pass/fail surface - the values are rounded, and the ratio only discriminates
    -- on rows below the 100 clamp.
    if Log.level >= RmLogging.LOG_LEVEL.DEBUG then
        Log:debug("createNewSaleAnimal: reshaped genetics preset=%d(%s) outlier=%s met=%.3f qua=%.3f fer=%.3f hea=%.3f health=%.2f prd=%s",
            presetIndex, RLDealerQualityModel.getPreset(presetIndex).key, tostring(wasOutlier),
            genetics.metabolism, genetics.quality, genetics.fertility, genetics.health, storedHealth,
            genetics.productivity ~= nil and string.format("%.3f", genetics.productivity) or "-")
    end


    local animal = Animal.new({
        age = age,
        health = storedHealth,
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


--- Read an animal's birth country without ever raising. A listing corrupt enough
--- to reach a malformed branch may carry a `birthday` that is not a table at all,
--- and `tostring` protects the RESULT of an index, not the index itself - so a
--- bare `birthday.country` in a diagnostic would raise on exactly the animals the
--- diagnostic exists to describe.
---@param animal table The listing
---@return any country The birth country, or nil when it cannot be read
local function safeBirthCountry(animal)
    local birthday = animal.birthday
    if type(birthday) ~= "table" then return nil end
    return birthday.country
end


--- Name a listing whose rotation inputs could not be evaluated, ONCE per map load
--- per detection site.
---
--- The latch is set AFTER the log call returns, not before: setting it first means
--- a diagnostic that raises leaves the latch burnt, silencing every later listing
--- that hits the same site while never having produced the message it consumed.
---@param latchKey string Key into `saleRotationWarnLatches` - one per detection site
---@param animal table The listing being rotated
---@param detail string What specifically could not be read
local function warnMalformedSaleListing(latchKey, animal, detail)
    if saleRotationWarnLatches[latchKey] then return end

    Log:warning("Dealer listing could not be evaluated and was rotated off the shelf (%s): "
        .. "farmId=%s uniqueId=%s country=%s. Further listings failing the same check "
        .. "this map load rotate silently.",
        tostring(detail), tostring(animal.farmId), tostring(animal.uniqueId),
        tostring(safeBirthCountry(animal)))

    saleRotationWarnLatches[latchKey] = true
end


--- Reset every rotation warning latch. Test-only seam: the wiring suite drives a
--- deliberately-malformed fixture through the real tick, which would otherwise
--- consume a production latch and silence the first genuine corrupt listing of the
--- session.
function AnimalSystem._resetSaleRotationWarnLatches()
    for key in pairs(saleRotationWarnLatches) do
        saleRotationWarnLatches[key] = false
    end
end


--- Reset every sale-generation bail latch. Test-only seam, and the keys are DYNAMIC
--- ("<site>:<typeIndex>"), so this clears the table rather than setting known keys
--- false - a suite that drove type 5 must not leave a latch that silences the first
--- genuine decline for type 5 later in the session.
function AnimalSystem._resetSaleGenerationBailLatches()
    for key in pairs(saleGenerationBailLatches) do
        saleGenerationBailLatches[key] = nil
    end
end


--- Whether a sale-generation bail latch has already fired. Test-only seam: the
--- latch is invisible from outside, and a suite proving "said once" needs to read
--- the flag rather than spy the logger.
---@param site string Detection-site key
---@param animalTypeIndex number
---@return boolean fired
function AnimalSystem._hasSaleGenerationBailLatch(site, animalTypeIndex)
    return saleGenerationBailLatches[site .. ":" .. tostring(animalTypeIndex)] == true
end


--- Per-listing rotation decision at TRACE. Every argument is passed raw and
--- formatted only past the level check, so below TRACE the loop pays the call and
--- not the formatting.
---
--- `listed-today` is deliberately NOT traced. It is by far the most common reason
--- on a healthy shelf and the least informative, and at a large `maxDealerAnimals`
--- across five types tracing it would put five figures of lines per game day into
--- the log a maintainer just enabled to investigate something else.
---@param animal table The listing being decided
---@param reason string The decision reason
---@param age number|nil Listing age in days, when it could be computed
---@param averageGenetics number|nil Mean genetics, when it could be read
---@param threshold number|nil Retention threshold, when the roll was reached
---@param roll number|nil The value drawn, when the roll was reached
local function traceSaleDecision(animal, reason, age, averageGenetics, threshold, roll)
    if reason == "listed-today" then return end
    if Log.level < RmLogging.LOG_LEVEL.TRACE then return end

    Log:trace("Dealer rotation: reason=%s farmId=%s uniqueId=%s country=%s age=%s genetics=%s threshold=%s roll=%s",
        reason, tostring(animal.farmId), tostring(animal.uniqueId),
        tostring(safeBirthCountry(animal)),
        tostring(age), tostring(averageGenetics), tostring(threshold), tostring(roll))
end


--- Decide whether one dealer sale listing rotates off the shelf this tick.
---
--- TOTAL over every listing the caller hands it, the same-day case included, so
--- there is exactly one decision site. Reasons, in the order they are tested:
---
---   `bad-day`      keep. The tick's own day counter is unusable. That is a
---                  whole-tick condition rather than this animal's fault, so it
---                  carries its own latch rather than spending a per-listing one.
---   `malformed`    rotate. This listing's own inputs cannot be evaluated -
---                  absent sale day, age running backwards, unreadable genetics,
---                  or an unusable band. Rotating it is what unsticks it; the
---                  latched WARNING is what makes it visible instead of being
---                  silently absorbed by the age cap below.
---   `listed-today` keep. Reads no genetics and consumes no roll.
---   `age`          rotate. At or over the absolute cap, whatever the genetics
---                  say. Consumes no roll.
---   `genetics`     the inherited retention roll, arithmetic unchanged.
---
--- Malformed is tested BEFORE the AGE CAP on purpose: the cap alone would evict
--- an unevaluable listing after two days with no diagnostic at all, which is
--- precisely the silent freeze this branch exists to surface. It is NOT tested
--- before `listed-today` - a listing made today reads no genetics at all, so an
--- unevaluable one is classified on the next day's tick rather than this one.
---
---@param animal table Sale listing; the caller has already proven `animal.sale` exists
---@param day number Current monotonic day
---@param bandMidpoint number Midpoint of the active dealer-quality band
---@param randomFn function|nil Zero-arg, returning a float in `[0, 1)`; defaults to
---       `math.random`. This is NOT the `_pickSaleAnimalAge` seam, which is
---       `function(lo, hi) -> int` - injecting that shape here compares an integer
---       against a fraction and rotates every listing.
---@return boolean shouldRotate
---@return string reason One of `bad-day`, `malformed`, `listed-today`, `age`, `genetics`
function AnimalSystem._shouldRotateSaleAnimal(animal, day, bandMidpoint, randomFn)

    -- A whole-tick condition, so it gets its own latch rather than spending a
    -- per-listing one. It still WARNS: without that, an unusable day counter keeps
    -- every listing every hour forever with nothing above TRACE ever saying so -
    -- the same silent freeze this predicate exists to end, merely relocated.
    -- `not (day > 0)` also rejects a NaN day.
    if type(day) ~= "number" or not (day > 0) then
        if not saleRotationWarnLatches.badDay then
            Log:warning("Dealer rotation is halted: the current day is %s, so no listing age can be "
                .. "computed and nothing will rotate off the shelf until it is usable again.",
                tostring(day))
            saleRotationWarnLatches.badDay = true
        end
        traceSaleDecision(animal, "bad-day")
        return false, "bad-day"
    end

    local saleDay = animal.sale.day

    -- The caller's `animal.sale ~= nil` guard proves the TABLE exists, not the
    -- field; the savegame writer tests `sale.day ~= nil` separately for the same
    -- reason. `day - nil` would raise.
    if type(saleDay) ~= "number" then
        warnMalformedSaleListing("saleDay", animal, "sale day is " .. type(saleDay))
        traceSaleDecision(animal, "malformed")
        return true, "malformed"
    end

    local age = day - saleDay

    -- `not (age >= 0)` rather than `age < 0`, because this test also has to catch a
    -- NaN age - and every comparison against NaN is false, so `age < 0` would wave
    -- it through. A NaN age then fails `== 0` and `>= the cap` too, reaching the
    -- roll where `roll >= NaN` is false as well: a listing that never rotates for
    -- any reason and never warns. That is precisely the permanent freeze this
    -- predicate exists to bound, so the cap must not be the only thing guarding it.
    --
    -- A negative age is reachable from a dealer pool carried into a save whose day
    -- counter is lower than the one the listing was stamped under.
    if not (age >= 0) then
        warnMalformedSaleListing("age", animal,
            string.format("listing age is unusable (saleDay=%s, day=%s, age=%s)",
                tostring(saleDay), tostring(day), tostring(age)))
        traceSaleDecision(animal, "malformed", age)
        return true, "malformed"
    end

    if age == 0 then
        traceSaleDecision(animal, "listed-today", age)
        return false, "listed-today"
    end

    -- Band before genetics: it divides the threshold, so an unusable one would
    -- otherwise reach the arithmetic as a nil operand or a division by zero.
    if type(bandMidpoint) ~= "number" or not (bandMidpoint > 0) then
        warnMalformedSaleListing("band", animal, "dealer band midpoint is " .. tostring(bandMidpoint))
        traceSaleDecision(animal, "malformed", age)
        return true, "malformed"
    end

    -- Checked before `pairs`, which raises on a nil table.
    if type(animal.genetics) ~= "table" then
        warnMalformedSaleListing("genetics", animal, "genetics is " .. type(animal.genetics))
        traceSaleDecision(animal, "malformed", age)
        return true, "malformed"
    end

    -- Numeric traits only. The inherited loop tested `value ~= nil`, which `pairs`
    -- can never falsify, so it admitted anything - and a string or table trait then
    -- raised inside the arithmetic. Skipping non-numbers keeps a corrupt entry from
    -- taking the tick down, at the cost of computing the mean over the survivors; a
    -- table with NO numeric trait still lands in the malformed branch below.
    local geneticQuality = 0
    local totalGenetics = 0

    for _, value in pairs(animal.genetics) do
        if type(value) == "number" then
            totalGenetics = totalGenetics + 1
            geneticQuality = geneticQuality + value
        end
    end

    if totalGenetics == 0 then
        warnMalformedSaleListing("geneticsEmpty", animal, "genetics carries no readable traits")
        traceSaleDecision(animal, "malformed", age)
        return true, "malformed"
    end

    local averageGenetics = geneticQuality / totalGenetics

    -- `not (x > 0)` rather than `x == 0`, to catch three separate bad means in one
    -- test. Zero and NaN (one NaN trait poisons the sum) both drive the threshold
    -- somewhere no roll can reach, freezing the listing. A NEGATIVE mean does the
    -- opposite - the threshold goes negative and every roll clears it, so the
    -- listing would churn out on its first tick while being reported as an ordinary
    -- `genetics` rotation. Neither outcome should be silent, so all three are
    -- malformed. Never math.min/math.max to tame this - LuaJIT's are argument-order
    -- dependent on NaN and would hide it rather than catch it.
    if not (averageGenetics > 0) then
        warnMalformedSaleListing("geneticsMean", animal, "genetics mean is " .. tostring(averageGenetics))
        traceSaleDecision(animal, "malformed", age, averageGenetics)
        return true, "malformed"
    end

    if age >= SALE_LISTING_MAX_AGE_DAYS then
        traceSaleDecision(animal, "age", age, averageGenetics)
        return true, "age"
    end

    -- Inherited retention roll, arithmetic deliberately untouched. The 1.45 factor
    -- is exactly the premium band's midpoint, which makes the expression a double
    -- normalisation under that preset; that is inherited too, and retuning it is not
    -- what bounds the runaway - the cap above is.
    local threshold = (saleDay / day) / ((averageGenetics / bandMidpoint) * 1.45)
    local roll = (randomFn or math.random)()
    local shouldRotate = roll >= threshold

    traceSaleDecision(animal, "genetics", age, averageGenetics, threshold, roll)

    return shouldRotate, "genetics"

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

            -- Pool size counts entries carrying a sale block, which is exactly the
            -- set the loop below decides on - so the reported size and the number
            -- of decisions can never disagree.
            local poolBefore = 0
            local rotatedByAge, rotatedByGenetics, rotatedMalformed = 0, 0, 0
            local rotatedUnclassified = 0

            for i, animal in pairs(animals) do

                if animal.sale ~= nil then

                    poolBefore = poolBefore + 1

                    -- Per-listing containment. This handler's whole body is one
                    -- safeCall xpcall, so an unguarded raise here would abort
                    -- rotation, restock AND the broadcast for every animal type -
                    -- a harder freeze than the one being fixed, and a silent one.
                    -- Two defaults, not one: the failure branch returns them
                    -- positionally, so a single-element default would hand the
                    -- summary below a nil reason to special-case. The failure
                    -- branch also logs an error and a callstack per animal per
                    -- tick; that is loud by design, and the malformed guards
                    -- inside the predicate exist so it never fires for the
                    -- known-bad shapes. A recurring one is a real defect signal.
                    local shouldRotate, reason = RmSafeUtils.safeAnimalCall(animal, "AnimalSystem:onHourChanged", function()
                        return AnimalSystem._shouldRotateSaleAnimal(animal, day, bandMidpoint)
                    end, { false, "error" })

                    if shouldRotate then

                        table.insert(indexesToRemove, i)

                        -- Every rotation reason sets this: it is what triggers the
                        -- state broadcast, and an age or malformed eviction that
                        -- skipped it would leave clients showing listings the
                        -- server has already removed.
                        hasChanges = true

                        -- Explicit on every reason rather than an `else` catch-all:
                        -- a catch-all silently files any future reason under
                        -- genetics, which is invisible in the summary below and
                        -- exactly the kind of drift a counter is supposed to expose.
                        if reason == "age" then
                            rotatedByAge = rotatedByAge + 1
                        elseif reason == "malformed" then
                            rotatedMalformed = rotatedMalformed + 1
                        elseif reason == "genetics" then
                            rotatedByGenetics = rotatedByGenetics + 1
                        else
                            rotatedUnclassified = rotatedUnclassified + 1
                        end

                    end

                end

            end

            for i = #indexesToRemove, 1, -1 do
                table.remove(animals, indexesToRemove[i])
            end

            local threshold = math.random(10, self.maxDealerAnimals)
            local creationsAttempted, creationsSucceeded = 0, 0

            if #animals < threshold then

                for i = #animals + 1, threshold do

                    creationsAttempted = creationsAttempted + 1

                    local animal = self:createNewSaleAnimal(animalTypeIndex)

                    if animal ~= nil then
                        table.insert(animals, animal)
                        creationsSucceeded = creationsSucceeded + 1
                        hasChanges = true
                    end

                end

            end

            local rotatedTotal = rotatedByAge + rotatedByGenetics + rotatedMalformed + rotatedUnclassified

            -- Never expected: every reason the predicate can return is counted
            -- above. Reaching this means a reason was added without updating the
            -- summary, so say it out loud rather than let the numbers quietly
            -- stop adding up.
            if rotatedUnclassified > 0 then
                Log:warning("Dealer rotation type=%d: %d listings rotated for an unrecognised reason - "
                    .. "the per-reason counters no longer cover every branch",
                    animalTypeIndex, rotatedUnclassified)
            end

            -- Suppressed on a quiet tick: without this the summary alone is five
            -- lines an hour, 120 a game day, at the dev DEBUG default.
            if rotatedTotal > 0 or creationsAttempted > 0 then

                local poolAfter = 0

                for _, animal in pairs(animals) do
                    if animal.sale ~= nil then poolAfter = poolAfter + 1 end
                end

                -- Attempted and succeeded diverge when createNewSaleAnimal returns
                -- nil - a legitimate outcome when an owner has disabled every
                -- buyable subtype for this type - and that divergence is the thing
                -- a reader is diagnosing, so report both rather than one "created".
                Log:debug("Dealer rotation type=%d: pool %d -> %d, rotated %d (age=%d genetics=%d malformed=%d), restocked %d of %d attempted",
                    animalTypeIndex, poolBefore, poolAfter, rotatedTotal,
                    rotatedByAge, rotatedByGenetics, rotatedMalformed,
                    creationsSucceeded, creationsAttempted)

                -- A tick that clears more than half the shelf is worth finding by
                -- grep rather than inferring from the counters above: it is what a
                -- silted or pre-cap save does on its first tick. DEBUG, not INFO -
                -- nothing here is actionable by a player or an admin, and in steady
                -- state a day-granular cap makes this fire more often than "rare"
                -- would suggest.
                if poolBefore > 0 and rotatedTotal * 2 > poolBefore then
                    Log:debug("Dealer shelf turnover: type=%d evicted %d of %d listings in a single tick",
                        animalTypeIndex, rotatedTotal, poolBefore)
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


--- Settings callback for the dealer-quality preset row.
---
--- Genetics are BAKED into each sale animal at construction, so a preset change
--- only becomes visible once the pool is regenerated - the markup follows the
--- preset live, the stock does not. This callback owns that regeneration and
--- nothing else: persistence rides the generic RLSettings scalar codec and the
--- broadcast is already sent by RLMenuSettingsFrame:onClickGeneralSetting, so
--- doing either here would double up.
---
--- Invoked on EVERY peer and on several non-change paths (applyDefaultSettings
--- at mission start, the full-set push on join, the relay to other clients).
--- The guard chain below reduces that to exactly one server-side regeneration
--- per real preset transition.
---
--- The regeneration enters RL_ResetDealerEvent.executeOnServer directly, NOT
--- sendEvent / onClickResetDealer: those are the client-side REQUEST
--- dispatchers, and from a path that has already passed the g_server gate a
--- request would fan out one repopulate per peer and race the settings commit.
---
---@param name string  settings key ("dealerQuality")
---@param value number|nil resolved option value; the preset index, or nil when
---                       the committed state is out of range
function AnimalSystem.onDealerQualityChanged(name, value)

    local animalSystem = g_currentMission ~= nil and g_currentMission.animalSystem or nil

    -- Logging rule for this function: resolve an index through getPreset ONLY
    -- where it is already known valid - i.e. on the change path below, after the
    -- range bail, where both indices are guaranteed in range. `previous` must be
    -- formatted bare (tostring) on the entry line, because it is nil on every
    -- seed - mission start and every client join - and getPreset latches a
    -- one-shot WARNING on an invalid index. Resolving it there would warn on a
    -- perfectly healthy install AND spend the latch, swallowing a later genuine
    -- invalid-index warning. Log lines must not change program-visible state.
    if animalSystem == nil then

        if g_server ~= nil then
            Log:warning("AnimalSystem.onDealerQualityChanged: animalSystem unreachable on the server (load-order regression); the preset was not applied to the stock - run Reset Animal Dealer once after the change")
        else
            -- Pure client: the join full-set landing before animalSystem is
            -- built is routine timing, not a defect.
            Log:debug("AnimalSystem.onDealerQualityChanged: animalSystem not built yet (client join timing), skipping")
        end

        return

    end

    -- Nil-guarded because every caller invokes this from inside an unprotected
    -- `for name, setting in pairs(SETTINGS)` loop: raising here would abort the
    -- REST of that loop, so every setting later in pairs() order would silently
    -- lose its callback. Matches the nil-guard applyChange and
    -- onClickGeneralSetting already use on the same lookup.
    local setting = RLSettings.SETTINGS[name]
    if setting == nil then
        Log:warning("AnimalSystem.onDealerQualityChanged: no settings row named '%s'; ignoring", tostring(name))
        return
    end

    -- (0) Validity bail. RL_BroadcastSettingsEvent commits the raw wire byte with
    -- no range check, so a master client can put 0 or 4..255 into state, and the
    -- caller then resolves values[state] to nil. Bailing here keeps that nil out
    -- of the early commit below, where the next full-set streamWriteUInt8 could
    -- not serialise it.
    --
    -- isValidIndex rather than a hand-rolled range test: it also rejects
    -- non-numbers (a bare `value < 1` RAISES on a string) and non-integers (2.5
    -- passes any 1..#values test, then poisons state with a value
    -- streamWriteUInt8 truncates, and spends RLDealerQualityModel's one-shot
    -- invalid-index warning latch from inside a log argument). It is also the
    -- predicate the preset table itself uses, so row and model cannot disagree.
    if not RLDealerQualityModel.isValidIndex(value) then

        -- Deliberately does NOT claim "nothing was committed": on the wire path
        -- RL_BroadcastSettingsEvent has already written the raw byte into
        -- setting.state before this callback runs. What this bail guarantees is
        -- that the callback does not commit it a second time (which is how a nil
        -- would reach state and break the next full-set serialise) and does not
        -- seed the tracker or regenerate from it.
        Log:warning("AnimalSystem.onDealerQualityChanged: invalid preset index %s (want an integer 1..%d); not applied and the tracker was not seeded, so the NEXT preset change will be treated as a seed and will not restock either - correct the preset in Settings, then run Reset Animal Dealer",
            tostring(value), RLDealerQualityModel.PRESET_COUNT)

        return

    end

    local previous = animalSystem.dealerQualityApplied

    Log:debug("AnimalSystem.onDealerQualityChanged: name='%s' value=%d previous=%s isServer=%s",
        name, value, tostring(previous), tostring(g_server ~= nil))

    -- (1) Seed. The first callback on any peer is not a change: on the server it
    -- is applyDefaultSettings at mission start, on a client the join full-set
    -- push. Regenerating here would discard the saved dealer pool on every load.
    if previous == nil then

        animalSystem.dealerQualityApplied = value
        Log:debug("AnimalSystem.onDealerQualityChanged: seeding tracker to %d (%s); no repopulate",
            value, RLDealerQualityModel.getPreset(value).key)

        return

    end

    -- (2) No-op. A full-set rebroadcast re-fires every callback unchanged, and a
    -- local click can land back on the already-applied index.
    if previous == value then

        Log:debug("AnimalSystem.onDealerQualityChanged: preset unchanged at %d (%s); no repopulate",
            value, RLDealerQualityModel.getPreset(value).key)

        return

    end

    -- (3) Server gate. Clients never generate - they receive the new pool via
    -- AnimalSystemStateEvent. The tracker still advances so the DEBUG trail on
    -- that peer stays truthful.
    if g_server == nil then

        animalSystem.dealerQualityApplied = value
        Log:debug("AnimalSystem.onDealerQualityChanged: client defers regeneration to the server; tracker %s -> %d (%s)",
            tostring(previous), value, RLDealerQualityModel.getPreset(value).key)

        return

    end

    Log:debug("AnimalSystem.onDealerQualityChanged: preset %d(%s) -> %d(%s); repopulating the dealer",
        previous, RLDealerQualityModel.getPreset(previous).key,
        value, RLDealerQualityModel.getPreset(value).key)

    -- (4) Early commit, BEFORE the reset. RLSettings.applyChange runs this
    -- callback and only then writes setting.state, but the regeneration resolves
    -- the active preset FROM that state - so without this a local click would
    -- rebuild the pool under the OLD preset. applyChange writes the identical
    -- value immediately afterwards, and on the wire path the state is already
    -- committed, so this is a no-op everywhere except the local click path. It
    -- is correct only because values[i] == i; a test pins that.
    -- Separate concern from the tracker advance below - do not collapse them.
    setting.state = value

    -- Persistence is deliberately NOT triggered here: the index is written by
    -- the generic scalar codec, driven by the savegame save or by the settings
    -- event when the change arrived from a remote client.
    Log:debug("AnimalSystem.onDealerQualityChanged: state committed to %d; persistence rides the RLSettings scalar codec, no explicit save here",
        value)
    Log:debug("AnimalSystem.onDealerQualityChanged: dispatching RL_ResetDealerEvent.executeOnServer(TYPE_DEALER)")

    local ok = RmSafeUtils.safeCall("AnimalSystem.onDealerQualityChanged: repopulate", function()
        RL_ResetDealerEvent.executeOnServer(RL_ResetDealerEvent.TYPE_DEALER)
    end)

    -- (5) Failure exit. safeCall has already logged the ERROR and callstack, so
    -- this adds only the player-facing recovery.
    if not ok then

        Log:warning("AnimalSystem.onDealerQualityChanged: repopulate failed; the preset moved to %d (%s) but the stock did not - run Reset Animal Dealer, or re-select the same preset to retry",
            value, RLDealerQualityModel.getPreset(value).key)

        return

    end

    -- (6) Advance only AFTER the reset returned. A failed or partial reset
    -- therefore leaves the tracker at the OLD preset, so re-selecting the same
    -- preset takes the real-transition path and RETRIES instead of being
    -- swallowed by guard (2). Safe because executeOnServer is synchronous.
    animalSystem.dealerQualityApplied = value

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