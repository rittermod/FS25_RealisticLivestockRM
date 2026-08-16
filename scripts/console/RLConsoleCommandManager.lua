RLConsoleCommandManager = {}

local rlConsoleCommandManager_mt = Class(RLConsoleCommandManager)

function RLConsoleCommandManager.new()

	local self = setmetatable({}, rlConsoleCommandManager_mt)

	self.husbandrySystem = g_currentMission.husbandrySystem
	self.animalSystem = g_currentMission.animalSystem
	self.animal = nil
	self.placeable = nil

    if g_currentMission:getIsServer() and not g_currentMission.missionDynamicInfo.isMultiplayer then
        addConsoleCommand("rlSetTargetAnimal", "Set the target animal for future console commands", "setAnimal", self, "[type] [farmId] [uniqueId]")
        addConsoleCommand("rlSetAnimalGenetics", "Set the genetics of the targeted animal", "setGenetics", self, "[geneticType] [value]")
        addConsoleCommand("rlSetAnimalInput", "Set the input of the targeted animal", "setInput", self, "[inputType] [value]")
        addConsoleCommand("rlSetAnimalOutput", "Set the output of the targeted animal", "setOutput", self, "[outputType] [value]")
        -- Saveable filters -- dev commands for manual save/load verification.
        -- Scope hardcoded to COW/farm 1 because the goal is round-trip smoke testing,
        -- not real-world filter authoring (the UI lives in the Settings tab).
        addConsoleCommand("rlFilterCreate", "Create a sample saveable filter (age>=48 AND isPregnant==false, COW/farm 1)", "createFilter", self, "[name]")
        addConsoleCommand("rlFilterList", "List all saveable filters currently in memory", "listFilters", self, "")
        addConsoleCommand("rlFilterClear", "Clear all saveable filters (SP diagnostic only)", "clearFilters", self, "")
        -- Herdsman rules -- dev seed/inspect for the new menu (M-Frame) until the
        -- F7 action bar provides a create UI. The frame reads the real
        -- g_rlHerdsmanRuleService, so seeded rules drive F3 list / F4 detail / F7
        -- actions and persist + sync like real rules.
        addConsoleCommand("rlHerdsmanRuleCreate", "Seed a few disabled herdsman rules (sell/buy/ai x2, farm 1) for menu dev", "createHerdsmanRules", self, "")
        addConsoleCommand("rlHerdsmanRuleList", "List all herdsman rules currently in memory", "listHerdsmanRules", self, "")
        addConsoleCommand("rlHerdsmanRuleClear", "Clear all herdsman rules (SP diagnostic only)", "clearHerdsmanRules", self, "")
        -- Engine cap probe: requires writing to engine husbandries, server-side only.
        addConsoleCommand("rlTestAnimalConfigCap", "Probe engine per-type config slot cap by calling addHusbandryAnimal idx 0..127 on each active husbandry", "testAnimalConfigCap", self, "[maxIdx]")
        addConsoleCommand("rlTestAnimalConfigCapFresh", "Probe whether a fresh createAnimalHusbandry call (different XML / different typeName) gets its own 32-window. Requires AnimalCapProbe pack with heritage config.", "testAnimalConfigCapFresh", self, "[maxIdx]")
    end

    -- Read-only debug commands - safe on SP, MP host, and MP client.
    addConsoleCommand("rlDumpSettings", "Dump effective RL settings to the log", "dumpSettings", self, "")

	return self

end


--- Console handler for rlDumpSettings. Read-only; safe in any context.
---@return string  confirmation message printed to the console
function RLConsoleCommandManager:dumpSettings()
    Log:debug("rlDumpSettings: invoked")
    RLDebugUtils.dumpSettings()
    return "rlDumpSettings: see log.txt"
end


--- Console handler for rlTestAnimalConfigCap. Probes the engine's per-type
--- visual-template cap by calling addHusbandryAnimal(husbandryId, idx) for
--- idx = 0..maxIdx on one active husbandry per animal type. Spawned visual
--- animals are removed before the handler returns; cluster bookkeeping is
--- never mutated.
---
--- Pair with the FS25_AnimalCapProbe RLRM pack to push every per-type config
--- past 32 slots so the cap can be observed.
---@param maxIdxStr string|nil  upper bound for probe idx (default 127)
---@return string                confirmation message printed to the console
function RLConsoleCommandManager:testAnimalConfigCap(maxIdxStr)
    local maxIdx = tonumber(maxIdxStr) or 127
    Log:info("[CapProbe] === rlTestAnimalConfigCap invoked (maxIdx=%d) ===", maxIdx)

    local animalSystem = self.animalSystem
    local husbandrySystem = self.husbandrySystem
    if animalSystem == nil or husbandrySystem == nil then
        Log:warning("[CapProbe] animalSystem or husbandrySystem unavailable; aborting")
        return "rlTestAnimalConfigCap: animalSystem/husbandrySystem unavailable (load a save first)"
    end

    -- Index the first active husbandry per animal type.
    local typeIndexToPlaceable = {}
    for _, placeable in ipairs(husbandrySystem.placeables) do
        local typeIdx = placeable:getAnimalTypeIndex()
        if typeIdx ~= nil and typeIndexToPlaceable[typeIdx] == nil then
            typeIndexToPlaceable[typeIdx] = placeable
        end
    end
    Log:info("[CapProbe] Found active husbandries for %d animal type(s) across %d placeable(s)",
        table.size(typeIndexToPlaceable), #husbandrySystem.placeables)

    local summary = {}

    for typeIdx, animalType in ipairs(animalSystem.types) do
        local typeName = animalType.name or "?"
        local luaCount = (animalType.animals ~= nil) and #animalType.animals or 0
        Log:info("[CapProbe] --- type=%s (typeIdx=%d) luaConfigRows=%d ---", typeName, typeIdx, luaCount)

        local placeable = typeIndexToPlaceable[typeIdx]
        if placeable == nil then
            Log:warning("[CapProbe]   no active husbandry of type %s; skipping engine probe", typeName)
            summary[typeName] = string.format("luaRows=%d  cap=NO-HUSBANDRY", luaCount)
            continue
        end

        local spec = placeable.spec_husbandryAnimals
        if spec == nil or spec.clusterHusbandry == nil then
            Log:warning("[CapProbe]   placeable for %s lacks spec_husbandryAnimals.clusterHusbandry; skipping", typeName)
            summary[typeName] = string.format("luaRows=%d  cap=NO-CLUSTER", luaCount)
            continue
        end

        local husbandryId = spec.clusterHusbandry.husbandryId
        if husbandryId == nil then
            Log:warning("[CapProbe]   clusterHusbandry for %s has nil husbandryId; skipping", typeName)
            summary[typeName] = string.format("luaRows=%d  cap=NO-HUSBANDRY-ID", luaCount)
            continue
        end
        Log:info("[CapProbe]   probing husbandryId=%s with idx=0..%d", tostring(husbandryId), maxIdx)

        local spawned = {}
        local successes = 0
        local failures = {}
        for idx = 0, maxIdx do
            local animalId = addHusbandryAnimal(husbandryId, idx)
            if animalId == nil or animalId == 0 then
                table.insert(failures, idx)
                Log:debug("[CapProbe]     idx=%-3d -> 0 (rejected)", idx)
            else
                successes = successes + 1
                table.insert(spawned, animalId)
                Log:trace("[CapProbe]     idx=%-3d -> animalId=%s", idx, tostring(animalId))
            end
        end

        for _, animalId in ipairs(spawned) do
            removeHusbandryAnimal(husbandryId, animalId)
        end
        Log:debug("[CapProbe]   cleanup: removed %d probe instance(s) from husbandryId=%s", #spawned, tostring(husbandryId))

        local firstFailure = failures[1]
        local lastSuccessIdx
        if #spawned > 0 then
            -- successes accumulated in idx order, so the highest-idx success is the last one we tried
            for idx = maxIdx, 0, -1 do
                if not table.hasElement(failures, idx) then
                    lastSuccessIdx = idx
                    break
                end
            end
        end
        Log:info("[CapProbe]   type=%s luaRows=%d probed=0..%d successes=%d failures=%d firstFailIdx=%s lastSuccessIdx=%s",
            typeName, luaCount, maxIdx, successes, #failures,
            tostring(firstFailure), tostring(lastSuccessIdx))

        summary[typeName] = string.format("luaRows=%-4d  successes=%-4d  firstFailIdx=%s  lastSuccessIdx=%s",
            luaCount, successes, tostring(firstFailure), tostring(lastSuccessIdx))
    end

    Log:info("[CapProbe] === Summary ===")
    for typeName, line in pairs(summary) do
        Log:info("[CapProbe]   %-10s %s", typeName, line)
    end
    Log:info("[CapProbe] === End ===")

    return "rlTestAnimalConfigCap: see log for [CapProbe] lines"
end


--- Console handler for rlTestAnimalConfigCapFresh. Tests whether a fresh
--- createAnimalHusbandry call gets its own 32-template window.
---
--- Two probe legs:
---   1. FreshSameType:    typeName="COW", xmlFilename=heritage (different from the existing cow config)
---   2. FreshNewTypeName: typeName="COW_HERITAGE", xmlFilename=heritage (engine receives an unregistered type string)
---
--- Both legs:
---   - borrow navNode, raycastDistance, collisionMask from an active COW placeable's clusterHusbandry
---   - call createAnimalHusbandry directly (same engine primitive
---     RealisticLivestock_AnimalClusterHusbandry:create uses)
---   - probe addHusbandryAnimal idx 0..maxIdx on the new husbandry
---   - cleanup: removeHusbandryAnimal each spawned + delete(husbandryId)
---
--- Requires the FS25_AnimalCapProbe mod loaded - it ships
--- models/heritage/animals.xml (78 cow rows) used by both legs.
---@param maxIdxStr string|nil  upper bound for probe idx (default 63)
---@return string                confirmation message printed to the console
function RLConsoleCommandManager:testAnimalConfigCapFresh(maxIdxStr)
    local maxIdx = tonumber(maxIdxStr) or 63
    Log:info("[CapProbe-Fresh] === rlTestAnimalConfigCapFresh invoked (maxIdx=%d) ===", maxIdx)

    local husbandrySystem = self.husbandrySystem
    if husbandrySystem == nil then
        Log:warning("[CapProbe-Fresh] husbandrySystem unavailable; aborting")
        return "rlTestAnimalConfigCapFresh: husbandrySystem unavailable (load a save first)"
    end
    if AnimalType == nil or AnimalType.COW == nil then
        Log:warning("[CapProbe-Fresh] AnimalType.COW not registered; aborting")
        return "rlTestAnimalConfigCapFresh: AnimalType.COW unavailable"
    end

    -- Donor lookup: borrow navMesh + raycastDistance + collisionMask + xmlFilename
    -- from an active placeable of the requested type. Used to construct fresh
    -- createAnimalHusbandry calls without authoring placeables of our own.
    local function findDonor(animalTypeName)
        local typeIdx = AnimalType[animalTypeName]
        if typeIdx == nil then return nil end
        for _, p in ipairs(husbandrySystem.placeables) do
            if p:getAnimalTypeIndex() == typeIdx then return p end
        end
        return nil
    end

    -- Heritage XML path is derived from the COW donor's xmlFilename
    -- (heritage config lives next to cow config in the AnimalCapProbe pack).
    local cowDonor = findDonor("COW")
    if cowDonor == nil then
        Log:warning("[CapProbe-Fresh] no active COW placeable; cannot derive heritage XML path")
        return "rlTestAnimalConfigCapFresh: requires a COW placeable to derive heritage path"
    end
    local cowDonorCH = cowDonor.spec_husbandryAnimals and cowDonor.spec_husbandryAnimals.clusterHusbandry
    if cowDonorCH == nil or cowDonorCH.xmlFilename == nil then
        Log:warning("[CapProbe-Fresh] cow donor missing clusterHusbandry/xmlFilename")
        return "rlTestAnimalConfigCapFresh: cow donor clusterHusbandry incomplete"
    end
    local heritageXml = string.gsub(cowDonorCH.xmlFilename, "/models/cow/animals%.xml$", "/models/heritage/animals.xml")
    if heritageXml == cowDonorCH.xmlFilename then
        Log:warning("[CapProbe-Fresh] cow xml '%s' is not the AnimalCapProbe override; load FS25_AnimalCapProbe.", cowDonorCH.xmlFilename)
        return "rlTestAnimalConfigCapFresh: AnimalCapProbe pack not active (cow xml mismatch)"
    end
    Log:info("[CapProbe-Fresh] heritageXml=%s", heritageXml)

    -- Probe matrix: each leg picks (donorType -> borrowed nav data) and
    -- (newTypeName, xmlPath) for the fresh createAnimalHusbandry call.
    --
    -- Three legs:
    --   FreshSameType_CowNav      cow donor's navMesh + new typeName=COW
    --   FreshNewTypeName_CowNav   cow donor's navMesh + new typeName=COW_HERITAGE
    --   FreshNewTypeName_SheepNav sheep donor's navMesh + new typeName=COW_HERITAGE
    -- The third leg disambiguates: if cap is per-navMesh, sheep navMesh has
    -- ~7 sheep templates pre-rendered, so probe should yield ~25. If cap is
    -- per-engine-process, results carry over across probes. If cap is
    -- per-placeable-type, sheep navMesh with cow templates yields ~32.
    local probes = {
        { label = "FreshSameType_CowNav",       donorType = "COW",   newTypeName = "COW",          xmlPath = heritageXml },
        { label = "FreshNewTypeName_CowNav",    donorType = "COW",   newTypeName = "COW_HERITAGE", xmlPath = heritageXml },
        { label = "FreshNewTypeName_SheepNav",  donorType = "SHEEP", newTypeName = "COW_HERITAGE", xmlPath = heritageXml },
    }

    local summary = {}

    for _, probe in ipairs(probes) do
        Log:info("[CapProbe-Fresh] --- %s: donorType=%s newTypeName=%s xml=%s ---",
            probe.label, probe.donorType, probe.newTypeName, probe.xmlPath)

        local donor = findDonor(probe.donorType)
        if donor == nil then
            Log:warning("[CapProbe-Fresh] %s: no active %s placeable; skipping", probe.label, probe.donorType)
            summary[probe.label] = string.format("donor=%-7s newType=%-13s cap=NO-DONOR", probe.donorType, probe.newTypeName)
            continue
        end
        local donorCH = donor.spec_husbandryAnimals and donor.spec_husbandryAnimals.clusterHusbandry
        if donorCH == nil or donorCH.navigationNode == nil then
            Log:warning("[CapProbe-Fresh] %s: %s donor missing clusterHusbandry/navNode; skipping", probe.label, probe.donorType)
            summary[probe.label] = string.format("donor=%-7s newType=%-13s cap=NO-NAVMESH", probe.donorType, probe.newTypeName)
            continue
        end

        local navNode = donorCH.navigationNode
        local raycastDistance = donorCH.raycastDistance or 1.0
        local collisionMask = donorCH.collisionMask

        local newHusbandryId = createAnimalHusbandry(probe.newTypeName, navNode, probe.xmlPath, raycastDistance, CollisionMask.ANIMAL_POSITIONING, collisionMask, AudioGroup.ENVIRONMENT)
        if newHusbandryId == nil or newHusbandryId == 0 then
            Log:warning("[CapProbe-Fresh] %s: createAnimalHusbandry returned 0 (engine rejected typeName=%s on %s navMesh)",
                probe.label, probe.newTypeName, probe.donorType)
            summary[probe.label] = string.format("donor=%-7s newType=%-13s cap=ENGINE-REJECTED", probe.donorType, probe.newTypeName)
            continue
        end
        Log:info("[CapProbe-Fresh] %s: husbandryId=%s; probing idx=0..%d", probe.label, tostring(newHusbandryId), maxIdx)

        local spawned = {}
        local successes = 0
        local failures = {}
        for idx = 0, maxIdx do
            local animalId = addHusbandryAnimal(newHusbandryId, idx)
            if animalId == nil or animalId == 0 then
                table.insert(failures, idx)
                Log:debug("[CapProbe-Fresh]     idx=%-3d -> 0", idx)
            else
                successes = successes + 1
                table.insert(spawned, animalId)
                Log:trace("[CapProbe-Fresh]     idx=%-3d -> animalId=%s", idx, tostring(animalId))
            end
        end

        for _, animalId in ipairs(spawned) do
            removeHusbandryAnimal(newHusbandryId, animalId)
        end
        delete(newHusbandryId)
        Log:debug("[CapProbe-Fresh] %s: cleanup: removed %d instance(s) + deleted husbandryId=%s",
            probe.label, #spawned, tostring(newHusbandryId))

        local firstFail = failures[1]
        Log:info("[CapProbe-Fresh] %s: donor=%s newType=%s successes=%d failures=%d firstFailIdx=%s",
            probe.label, probe.donorType, probe.newTypeName, successes, #failures, tostring(firstFail))
        summary[probe.label] = string.format("donor=%-7s newType=%-13s successes=%-4d firstFailIdx=%s",
            probe.donorType, probe.newTypeName, successes, tostring(firstFail))
    end

    Log:info("[CapProbe-Fresh] === Summary ===")
    for label, line in pairs(summary) do
        Log:info("[CapProbe-Fresh]   %-18s %s", label, line)
    end
    Log:info("[CapProbe-Fresh] === End ===")

    return "rlTestAnimalConfigCapFresh: see log for [CapProbe-Fresh] lines"
end


function RLConsoleCommandManager:setAnimal(animalType, farmId, uniqueId)

	self.animal = nil
	self.placeable = nil

	if animalType == nil or type(animalType) ~= "string" then

		print("rlSetTargetAnimal: no animal type given, accepted types:")

		for name, index in pairs(AnimalType) do print("|--- " .. name) end

		return

	end

	if farmId == nil then return "rlSetTargetAnimal: no farmId given" end
	
	if uniqueId == nil then return "rlSetTargetAnimal: no uniqueId given" end

	local animalTypeIndex = AnimalType[animalType:upper()]

	for _, placeable in pairs(self.husbandrySystem.placeables) do

		if placeable:getAnimalTypeIndex() ~= animalTypeIndex then continue end

		local animals = placeable:getClusters()
		
		for _, animal in pairs(animals) do

			if animal.farmId == farmId and animal.uniqueId == uniqueId then

				self.animal = animal
				self.placeable = placeable

				return "rlSetTargetAnimal: animal set successfully"

			end

		end

	end


	for _, trailer in pairs(self.husbandrySystem.livestockTrailers) do

		local trailerType = trailer:getCurrentAnimalType()

		if trailerType == nil or trailerType.typeIndex ~= animalTypeIndex then continue end

		local animals = trailer:getClusters()
		
		for _, animal in pairs(animals) do

			if animal.farmId == farmId and animal.uniqueId == uniqueId then

				self.animal = animal

				return "rlSetTargetAnimal: animal set successfully"

			end

		end

	end

	return "rlSetTargetAnimal: animal not found"

end


function RLConsoleCommandManager:setGenetics(geneticType, value)

	if self.animal == nil then return "rlSetAnimalGenetics: no targeted animal" end

	if geneticType == nil or type(geneticType) ~= "string" or self.animal.genetics[geneticType] == nil then
		
		print("rlSetAnimalGenetics: invalid genetic type given, accepted types:")

		for key, _ in pairs(self.animal.genetics) do print("|--- " .. key) end

		return
		
	end

	if value == nil then return "rlSetAnimalGenetics: no value given" end

	value = tonumber(value)

	if value == nil then return "rlSetAnimalGenetics: invalid value given" end

	if value < 0.25 or value > 1.75 then return "rlSetAnimalGenetics: invalid value given, must be in range 0.25 - 1.75" end

	self.animal.genetics[geneticType] = value

	return "rlSetAnimalGenetics: animal genetics set successfully"

end


function RLConsoleCommandManager:setInput(inputType, value)

	if self.animal == nil then return "rlSetAnimalInput: no targeted animal" end

	if inputType == nil or type(inputType) ~= "string" or self.animal.input[inputType] == nil then
		
		print("rlSetAnimalInput: invalid input type given, accepted types:")

		for key, _ in pairs(self.animal.input) do print("|--- " .. key) end

		return
		
	end

	if value == nil then return "rlSetAnimalInput: no value given" end

	value = tonumber(value)

	if value == nil then return "rlSetAnimalInput: invalid value given" end

	if value < 0 then return "rlSetAnimalInput: invalid value given, must be higher than or equal to 0" end

	self.animal.input[inputType] = value
	if self.placeable ~= nil then self.placeable:updateInputAndOutput(self.placeable:getClusters()) end

	return "rlSetAnimalInput: animal input set successfully"

end


function RLConsoleCommandManager:setOutput(outputType, value)

	if self.animal == nil then return "rlSetAnimalOutput: no targeted animal" end

	if outputType == nil or type(outputType) ~= "string" or self.animal.output[outputType] == nil then
		
		print("rlSetAnimalOutput: invalid output type given, accepted types:")

		for key, _ in pairs(self.animal.output) do print("|--- " .. key) end

		return
		
	end

	if value == nil then return "rlSetAnimalOutput: no value given" end

	value = tonumber(value)

	if value == nil then return "rlSetAnimalOutput: invalid value given" end

	if value < 0 then return "rlSetAnimalOutput: invalid value given, must be higher than or equal to 0" end

	self.animal.output[outputType] = value
	if self.placeable ~= nil then self.placeable:updateInputAndOutput(self.placeable:getClusters()) end

	return "rlSetAnimalOutput: animal output set successfully"

end


-- =============================================================================
-- Saveable filters -- dev commands for manual save/load verification.
-- These are intentionally minimal: the goal is to smoke-test the save file
-- round-trip by creating a filter in one game session, saving, quitting,
-- reloading, and confirming the filter is still there. The UI path lives
-- in the Settings tab.
-- =============================================================================


--- Create a canned filter (age>=48 AND isPregnant==false, COW/farm 1) so the
--- player can prove the save/load round-trip without having to hand-construct
--- an AST. The returned id is printed and usable with `rlFilterList`.
---@param name string|nil optional filter name (defaults to "rlFilter_test")
---@return string user-facing result
function RLConsoleCommandManager:createFilter(name)

	if g_rlFilterService == nil then
		return "rlFilterCreate: g_rlFilterService is nil (mod load order regression?)"
	end

	local Log = RmLogging.getLogger("RLRM")
	local filterName = (type(name) == "string" and name ~= "") and name or "rlFilter_test"

	local filter = g_rlFilterService:create({
		name = filterName,
		animalType = AnimalType.COW,
		farmId = 1,
		expression = {
			op = "AND",
			children = {
				{ field = "age",        cmp = ">=", value = 48 },
				{ field = "isPregnant", cmp = "==", value = false },
			},
		},
	})

	if filter == nil then
		return "rlFilterCreate: create returned nil (see log for details)"
	end

	Log:info("rlFilterCreate: created id=%s name=%s (total=%d)",
		filter.id, filter.name, #g_rlFilterService:list())

	return string.format("rlFilterCreate: ok id=%s", filter.id)

end


--- Dump every filter currently held by the service. One line per filter,
--- plus a total at the end. Readable in the dev console and also the log.
---@return string user-facing result
function RLConsoleCommandManager:listFilters()

	if g_rlFilterService == nil then
		return "rlFilterList: g_rlFilterService is nil (mod load order regression?)"
	end

	local Log = RmLogging.getLogger("RLRM")
	local filters = g_rlFilterService:list()

	if #filters == 0 then
		Log:info("rlFilterList: no filters in memory")
		return "rlFilterList: 0 filters"
	end

	for _, f in ipairs(filters) do
		local animalType = tostring(f.animalType)
		local farmId = tostring(f.farmId)
		local op = (f.expression and f.expression.op) or "?"
		local numChildren = (f.expression and f.expression.children and #f.expression.children) or 0
		local line = string.format("|--- id=%s name=%s animalType=%s farmId=%s version=%s op=%s #children=%d",
			tostring(f.id), tostring(f.name), animalType, farmId, tostring(f.version), op, numChildren)
		print(line)
		Log:info("rlFilterList: %s", line)
	end

	return string.format("rlFilterList: %d filters", #filters)

end


--- Wipe the in-memory filter registry. Does NOT touch the save file; the
--- next save cycle will persist the cleared state. SP-only by the outer
--- registration guard.
---@return string user-facing result
function RLConsoleCommandManager:clearFilters()

	if g_rlFilterService == nil then
		return "rlFilterClear: g_rlFilterService is nil (mod load order regression?)"
	end

	local Log = RmLogging.getLogger("RLRM")
	local before = #g_rlFilterService:list()
	g_rlFilterService:clear()
	Log:info("rlFilterClear: cleared %d filters from in-memory registry", before)
	return string.format("rlFilterClear: cleared %d filters", before)

end


-- =============================================================================
-- Herdsman rules -- dev seed/inspect for menu development (mirror the filter
-- commands). The Herdsman frame (M-Frame) reads g_rlHerdsmanRuleService, but no
-- create UI exists until F7, so these seed/inspect the registry. Superseded when
-- F7 ships the action bar. SP-only via the outer registration guard.
-- =============================================================================


--- Seed a few disabled herdsman rules (sell/buy/ai x2, farm 1) so the Herdsman
--- menu has data to render before the F7 create UI exists. Two AI rules prove the
--- within-section alpha sort ("AI backup" sorts before "Breed top tier"). All
--- enabled=false so the (future) day-tick stays inert. Routes through the real
--- g_rlHerdsmanRuleService:create -> CRUD event -> persist + MP sync.
---@return string user-facing result
function RLConsoleCommandManager:createHerdsmanRules()

	if g_rlHerdsmanRuleService == nil then
		return "rlHerdsmanRuleCreate: g_rlHerdsmanRuleService is nil (mod load order regression?)"
	end

	local Log = RmLogging.getLogger("RLRM")
	-- Placeholder filterId: the floor accepts a nil filterId for non-naming operations
	-- (an unfiltered draft), but the dev seeds carry a concrete placeholder so the rules
	-- render with a filter summary. It need not resolve to a real saved filter for the
	-- list to render; F4's filter summary will read "missing" until pointed at one.
	local filterId = "rlHerdsmanDev_filter"
	-- Per-operation params mirror the legacy AIAnimalManager defaults
	-- (AIAnimalManager.new, removed 1.3.2.0) so the rules pass RLHerdsmanRuleSerialization's
	-- PARAMS_CODECS completeness gate and actually persist - the service validity
	-- floor accepts empty params, but saveToXMLFile skips incomplete ones.
	-- enabled=false keeps them inert regardless.
	local seeds = {
		{ name = "Cull old cows",   operation = "sell", params = { maxAnimals = 5, mark = false } },
		{ name = "Restock heifers", operation = "buy",  params = { maxAnimals = 5, budget = { type = "fixed", fixed = 5000, percentage = 1 } } },
		{ name = "Breed top tier",  operation = "ai",   params = { maxAnimals = 5, mark = false, semen = "any" } },
		{ name = "AI backup",       operation = "ai",   params = { maxAnimals = 5, mark = false, semen = "any" } },
	}

	local created = 0
	for _, s in ipairs(seeds) do
		local rule = g_rlHerdsmanRuleService:create({
			name              = s.name,
			operation         = s.operation,
			farmId            = 1,
			enabled           = false,
			params            = s.params,
			targetHusbandries = {},
			filterId          = filterId,
		})
		if rule ~= nil then created = created + 1 end
	end

	Log:info("rlHerdsmanRuleCreate: created %d rule(s) (total=%d)", created, #g_rlHerdsmanRuleService:list())
	return string.format("rlHerdsmanRuleCreate: ok, %d rule(s) created", created)

end


--- Dump every herdsman rule currently held by the service. One line per rule,
--- plus a total at the end. Readable in the dev console and the log.
---@return string user-facing result
function RLConsoleCommandManager:listHerdsmanRules()

	if g_rlHerdsmanRuleService == nil then
		return "rlHerdsmanRuleList: g_rlHerdsmanRuleService is nil (mod load order regression?)"
	end

	local Log = RmLogging.getLogger("RLRM")
	local rules = g_rlHerdsmanRuleService:list()

	if #rules == 0 then
		Log:info("rlHerdsmanRuleList: no rules in memory")
		return "rlHerdsmanRuleList: 0 rules"
	end

	for _, r in ipairs(rules) do
		local line = string.format("|--- id=%s name=%s operation=%s farmId=%s enabled=%s filterId=%s",
			tostring(r.id), tostring(r.name), tostring(r.operation), tostring(r.farmId),
			tostring(r.enabled), tostring(r.filterId))
		print(line)
		Log:info("rlHerdsmanRuleList: %s", line)
	end

	return string.format("rlHerdsmanRuleList: %d rules", #rules)

end


--- Wipe the in-memory herdsman rule registry. Does NOT touch the save file; the
--- next save cycle persists the cleared state. SP-only via the outer guard.
---@return string user-facing result
function RLConsoleCommandManager:clearHerdsmanRules()

	if g_rlHerdsmanRuleService == nil then
		return "rlHerdsmanRuleClear: g_rlHerdsmanRuleService is nil (mod load order regression?)"
	end

	local Log = RmLogging.getLogger("RLRM")
	local before = #g_rlHerdsmanRuleService:list()
	g_rlHerdsmanRuleService:clear()
	Log:info("rlHerdsmanRuleClear: cleared %d rules from in-memory registry", before)
	return string.format("rlHerdsmanRuleClear: cleared %d rules", before)

end
