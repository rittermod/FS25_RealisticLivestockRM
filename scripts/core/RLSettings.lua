RLSettings = {}
local modDirectory = g_currentModDirectory
local modName = g_currentModName
local modSettingsDirectory = g_currentModSettingsDirectory

local modDirectoryPath = string.split(modDirectory, "/")
local baseDirectory = ""

for i = 1, #modDirectoryPath - 2 do

	baseDirectory = baseDirectory .. (i == 1 and "" or "/") .. modDirectoryPath[i]

end

g_gui:loadProfiles(modDirectory .. "gui/guiProfiles.xml")


function RLSettings.onClickTagColour()

	EarTagColourPickerDialog.show()

end


--- Open the visual-animals dialog from the General-tab action row (mirrors the
--- tagColour -> EarTagColourPickerDialog pattern). Client-local control: the
--- dialog mutates RealisticLivestock_AnimalClusterHusbandry.MAX_HUSBANDRIES and
--- persists it per-machine, so this row carries no adminOnly gate. Invoked with
--- no args by onClickGeneralAction.
---
--- The INSTANCE guard uses rawget: VisualAnimalsDialog is a Class() of
--- YesNoDialog whose base carries a non-nil INSTANCE, so a plain
--- VisualAnimalsDialog.INSTANCE read falls through __index to that inherited
--- instance and would never report nil - masking a failed eager registration
--- and pushing show() onto the wrong dialog. rawget inspects only the own field
--- that register() sets. Eager registration in RealisticLivestock_FSBaseMission
--- is the sole contract, so a nil own INSTANCE is a defect (log ERROR, no crash).
function RLSettings.onClickVisualAnimals()

	if rawget(VisualAnimalsDialog, "INSTANCE") == nil then
		Log:error("RLSettings.onClickVisualAnimals: VisualAnimalsDialog.INSTANCE is nil (eager registration failed?); cannot open dialog")
		return
	end

	Log:debug("RLSettings.onClickVisualAnimals: opening VisualAnimalsDialog")
	VisualAnimalsDialog.show()

end


--- Open the dealer sale-availability selector from the General-tab action row
--- (mirrors the onClickVisualAnimals opener). The freshly enumerated catalog is
--- passed twice - once as the dialog's data, once as the opaque callback target -
--- so the Confirm handler reconciles against exactly the catalog the player saw,
--- with no module-level state a second open could stomp.
---
--- A plain INSTANCE read is correct here, unlike the VisualAnimalsDialog rawget
--- carve-out: RLDealerSaleSelectorDialog is a Class() of MessageDialog, whose base
--- carries no INSTANCE to inherit, so a nil read genuinely means the eager
--- registration failed rather than falling through to a wrong dialog.
function RLSettings.onClickDealerSale()

	if RLDealerSaleSelectorDialog.INSTANCE == nil then
		Log:error("RLSettings.onClickDealerSale: RLDealerSaleSelectorDialog.INSTANCE is nil (eager registration failed?); cannot open dialog")
		return
	end

	local catalog = RLDealerSaleCatalog.enumerate()

	Log:debug("RLSettings.onClickDealerSale: opening selector over %d catalog entr(ies)", #catalog)
	RLDealerSaleSelectorDialog.show(RLSettings.onDealerSaleConfirmed, catalog, catalog)

end


--- Confirm handler for the dealer sale-availability selector: reconcile the
--- committed set into a minimal op list and hand it to the server.
---
--- `result` is nil on Back/cancel. Otherwise the pure diff turns it into the
--- minimal set/clear ops against each stage's shipped default, so a stage toggled
--- back to its default is UNMANAGED (override cleared) rather than pinned, and
--- keeps tracking future default changes. Only CHANGED rows produce an op, so an
--- unchanged Confirm dispatches nothing and costs the player nothing.
---
--- Dispatch only: the ops travel to the server through `RLDealerSaleSetEvent`,
--- which owns the registry write, the state broadcast and the dealer re-roll. This
--- shell mutates nothing on any peer, so singleplayer, host and pure client all
--- funnel through one server entry point.
---@param catalog table the catalog the dialog was opened over (round-tripped as the callback target)
---@param result table|nil checked in-scope rows { { subTypeName=, minAge= }, ... }, or nil on cancel
function RLSettings.onDealerSaleConfirmed(catalog, result)

	if result == nil then
		Log:debug("RLSettings.onDealerSaleConfirmed: cancelled; no change")
		return
	end

	if g_rlDealerSaleRegistry == nil then
		Log:warning("RLSettings.onDealerSaleConfirmed: g_rlDealerSaleRegistry is nil; ignoring the committed set")
		return
	end

	local baseline = RLDealerSaleApply.sessionBaseline
	if type(baseline) ~= "table" then baseline = {} end

	local ops = RLDealerSaleReconcile.diff(result, catalog, baseline)

	if #ops == 0 then
		Log:debug("RLSettings.onDealerSaleConfirmed: no changes; nothing dispatched and the dealer is left as-is")
		return
	end

	Log:debug("RLSettings.onDealerSaleConfirmed: dispatching %d reconcile op(s) to the server", #ops)
	RLDealerSaleSetEvent.sendEvent(ops)

end


function RLSettings.onClickExportCSV()

	local file = io.open(modSettingsDirectory .. "animals.csv", "w")

	file:write("Type,Subtype,Country,Farm Id,Unique Id,Age,Health,Weight,Value,Value / kg,Pregnant,Expected Offspring,Lactating,Food,Water,Straw,Product,Manure,Liquid Manure")

	local husbandrySystem = g_currentMission.husbandrySystem
	local animalSystem = g_currentMission.animalSystem

	for _, placeable in pairs(husbandrySystem.placeables) do

		local animals = placeable:getClusters()

		for _, animal in pairs(animals) do

			local hasMonitor = animal.monitor.active or animal.monitor.removed

			local foodInput = animal:getInput("food") * 24
			local waterInput = animal:getInput("water") * 24
			local strawInput = animal:getInput("straw") * 24
			local manureOutput = animal:getOutput("manure") * 24
			local liquidManureOutput = animal:getOutput("liquidManure") * 24
			local milkOutput = animal:getOutput("milk") * 24
			local palletsOutput = animal:getOutput("pallets") * 24

			local productOutput = milkOutput > palletsOutput and milkOutput or palletsOutput

			local value = animal:getSellPrice()
			local valuePerKg = hasMonitor and (value / animal.weight) or "no monitor"
			
			local expectedOffspring = animal.pregnancy ~= nil and animal.pregnancy.pregnancies ~= nil and #animal.pregnancy.pregnancies or 0

			file:write(string.format("\n%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s", animalSystem.types[animal.animalTypeIndex].name, animal.subType, RLConstants.AREA_CODES[animal.birthday.country].code, animal.farmId, animal.uniqueId, animal.age, hasMonitor and animal.health or "no monitor", hasMonitor and animal.weight or "no monitor", value, valuePerKg, animal.isPregnant and "yes" or "no", expectedOffspring, (hasMonitor and (animal.isLactating and "yes" or "no") or "no monitor"), hasMonitor and foodInput or "no monitor", hasMonitor and waterInput or "no monitor", hasMonitor and strawInput or "no monitor", hasMonitor and productOutput or "no monitor", hasMonitor and manureOutput or "no monitor", hasMonitor and liquidManureOutput or "no monitor"))

		end

	end

	file:close()

	InfoDialog.show(modSettingsDirectory .. "animals.csv")

end


local function getFilesRecursively(path, parent)

	local files = Files.new(path).files

	for _, file in pairs(files) do

		if file.isDirectory then
		
			table.insert(parent.folders, { ["folders"] = {}, ["files"] = {}, ["name"] = file.filename, ["path"] = file.path })
			getFilesRecursively(file.path, parent.folders[#parent.folders])
			continue

		end

		local name = file.filename

		if #name >= 4 and string.sub(name, #name - 3) == ".xml" then table.insert(parent.files, { ["name"] = name, ["valid"] = true }) end

	end

end


function RLSettings.onClickChangeAnimalsXML()

	local files = { { ["folders"] = {}, ["files"] = {}, ["name"] = baseDirectory, ["path"] = baseDirectory } }

	getFilesRecursively(baseDirectory, files[1])

	FileExplorerDialog.show(files, baseDirectory, RLSettings.onFileExplorerCallback)

end


function RLSettings.onFileExplorerCallback(path)

	RLSettings.animalsXMLPath = path

end


-- Render order comes from the authored row order in gui/rlmenu/settingsFrame.xml,
-- NOT from this table: populateGeneralSubtab walks SETTINGS with pairs() and binds
-- each row by its rlmenuSetting_<name> element id. setting.index is consumed by
-- RLDebugUtils.dumpSettings, which prints state rows in index order (it skips
-- ignore==true rows), so index must stay a faithful mirror of the XML order below.
-- Keep the two in step when adding or moving a row. Sections (1..21):
-- Mortality (1-2), Health & Disease (3-4), Husbandry & Economy (5-8),
-- Custom Animals (9-10), Message Log (11-12), Display Preferences (13-16),
-- Tools & Admin (17-20), Visual Animals (21, client-local, no admin gate).
RLSettings.SETTINGS = {

	["deathEnabled"] = {
		["index"] = 1,
		["adminOnly"] = true,
		["type"] = "BinaryOption",
		["dynamicTooltip"] = true,
		["default"] = 2,
		["binaryType"] = "offOn",
		["values"] = { false, true },
		["callback"] = Animal.onSettingChanged
	},

	["accidentsChance"] = {
		["index"] = 2,
		["adminOnly"] = true,
		["type"] = "MultiTextOption",
		["default"] = 11,
		["valueType"] = "float",
		["values"] = { 0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1, 1.1, 1.2, 1.3, 1.4, 1.5, 1.6, 1.7, 1.8, 1.9, 2.0 },
		["callback"] = Animal.onSettingChanged,
		["dependancy"] = {
			["name"] = "deathEnabled",
			["state"] = 2
		}
	},

	["diseasesEnabled"] = {
		["index"] = 3,
		["adminOnly"] = true,
		["type"] = "BinaryOption",
		["dynamicTooltip"] = true,
		["default"] = 2,
		["binaryType"] = "offOn",
		["values"] = { false, true },
		["callback"] = DiseaseManager.onSettingChanged
	},

	["diseasesChance"] = {
		["index"] = 4,
		["adminOnly"] = true,
		["type"] = "MultiTextOption",
		["default"] = 4,
		["valueType"] = "float",
		["values"] = { 0.25, 0.5, 0.75, 1, 1.5, 2, 2.5, 3, 3.5, 4, 4.5, 5 },
		["callback"] = DiseaseManager.onSettingChanged,
		["dependancy"] = {
			["name"] = "diseasesEnabled",
			["state"] = 2
		}
	},

	["foodScale"] = {
		["index"] = 5,
		["adminOnly"] = true,
		["type"] = "MultiTextOption",
		["default"] = 2,
		["valueType"] = "float",
		["values"] = { 0.5, 1, 1.5, 2, 2.5, 3, 3.5, 4, 4.5, 5 },
		["callback"] = RealisticLivestock_PlaceableHusbandryFood.onSettingChanged
	},

	["maxDealerAnimals"] = {
		["index"] = 6,
		["adminOnly"] = true,
		["type"] = "MultiTextOption",
		["default"] = 4,
		["valueType"] = "int",
		["values"] = { 20, 30, 40, 50, 60, 70, 80, 90, 100, 110, 120, 130, 140, 150, 160, 170, 180, 190, 200 },
		["callback"] = AnimalSystem.onSettingChanged
	},

	-- Admin-gated because the dealer pool is shared world state, not a per-player
	-- display preference. Changing it REPOPULATES the dealer (genetics are baked
	-- into each animal at generation, so the existing stock cannot be re-banded);
	-- the AI insemination pool is deliberately left untouched (decided by Ritter
	-- 2026-07-28). State index IS the preset index - the callback
	-- and every reader depend on values[i] == i, which RLSettingsTests pins
	-- against RLDealerQualityModel.DEFAULT_INDEX / PRESET_COUNT.
	["dealerQuality"] = {
		["index"] = 7,
		["adminOnly"] = true,
		["type"] = "MultiTextOption",
		["default"] = 2,
		["values"] = { 1, 2, 3 },
		["callback"] = AnimalSystem.onDealerQualityChanged
	},

	-- Persisted as the RL area-code VALUE string (state 1 -> "default"), never
	-- the index; values is the ONE table shared with RLMapCountry so the codec
	-- and the resolver cannot drift. Option texts are runtime-built (getTexts):
	-- only "Map default" is localized, country names render in English.
	["mapCountry"] = {
		["index"] = 8,
		["adminOnly"] = true,
		["type"] = "MultiTextOption",
		["default"] = 1,
		["valueType"] = "string",
		["values"] = RLMapCountry.VALUES,
		["getTexts"] = function()
			local texts = { g_i18n:getText("rl_settings_mapCountry_texts_1") }

			for _, entry in ipairs(RLConstants.AREA_CODES) do
				texts[#texts + 1] = string.format("%s (%s)", entry.country, entry.code)
			end

			return texts
		end
	},

	["useCustomAnimals"] = {
		["index"] = 9,
		["adminOnly"] = true,
		["type"] = "BinaryOption",
		["dynamicTooltip"] = true,
		["default"] = 1,
		["binaryType"] = "offOn",
		["values"] = { false, true }
	},

	["animalsXML"] = {
		["index"] = 10,
		["adminOnly"] = true,
		["type"] = "Button",
		["ignore"] = true,
		["callback"] = RLSettings.onClickChangeAnimalsXML,
		["dependancy"] = {
			["name"] = "useCustomAnimals",
			["state"] = 2
		}
	},

	["messageSummary"] = {
		["index"] = 11,
		["adminOnly"] = true,
		["type"] = "BinaryOption",
		["dynamicTooltip"] = true,
		["default"] = 1,  -- Individual (current behavior) as default
		["binaryType"] = "offOn",
		["values"] = { false, true },
		["callback"] = RLMessageAggregator.onSettingChanged
	},

	["maxNumMessages"] = {
		["index"] = 12,
		["adminOnly"] = true,
		["type"] = "MultiTextOption",
		["default"] = 5,
		["valueType"] = "int",
		["values"] = { 100, 200, 300, 400, 500, 600, 700, 800, 900, 1000, 1250, 1500, 1750, 2000, 2250, 2500, 2750, 3000, 3500, 4000, 4500, 5000 },
		["callback"] = RealisticLivestock_PlaceableHusbandryAnimals.onSettingChanged
	},

	["geneticsDisplay"] = {
		["index"] = 13,
		["adminOnly"] = true,
		["type"] = "MultiTextOption",
		["default"] = 1,
		["values"] = { 1, 2, 3 }
	},

	["geneticsPosition"] = {
		["index"] = 14,
		["adminOnly"] = true,
		["type"] = "BinaryOption",
		["default"] = 1,
		["values"] = { 1, 2 }
	},

	["sortByGenetics"] = {
		["index"] = 15,
		["adminOnly"] = true,
		["type"] = "BinaryOption",
		["dynamicTooltip"] = true,
		["default"] = 1,
		["binaryType"] = "offOn",
		["values"] = { false, true }
	},

	["tagColour"] = {
		["index"] = 16,
		["adminOnly"] = true,
		["type"] = "Button",
		["ignore"] = true,
		["callback"] = RLSettings.onClickTagColour
	},

	["exportCSV"] = {
		["index"] = 17,
		["adminOnly"] = true,
		["type"] = "Button",
		["ignore"] = true,
		["callback"] = RLSettings.onClickExportCSV
	},

	["resetDealer"] = {
		["index"] = 18,
		["type"] = "Button",
		["ignore"] = true,
		["adminOnly"] = true,
		["callback"] = AnimalSystem.onClickResetDealer
	},

	-- Opens the sale-availability selector: which subTypes / age stages the animal
	-- dealer offers. Server-authoritative (the Confirm handler writes the override
	-- registry and regenerates the dealer), hence the admin gate.
	["dealerSale"] = {
		["index"] = 19,
		["type"] = "Button",
		["ignore"] = true,
		["adminOnly"] = true,
		["callback"] = RLSettings.onClickDealerSale
	},

	["resetAIAnimals"] = {
		["index"] = 20,
		["type"] = "Button",
		["ignore"] = true,
		["adminOnly"] = true,
		["callback"] = AnimalSystem.onClickResetAIAnimals
	},

	-- Client-local display preference (per-machine MAX_HUSBANDRIES). Deliberately
	-- NOT adminOnly, so any MP client (admin or not) can adjust its own visual
	-- density; ignore=true keeps it off the RL_BroadcastSettingsEvent wire codec
	-- and out of rm_RlSettings.xml. The dialog persists the value per peer to
	-- modSettings/Settings.xml.
	["maxVisualAnimals"] = {
		["index"] = 21,
		["type"] = "Button",
		["ignore"] = true,
		["callback"] = RLSettings.onClickVisualAnimals
	}

}


--- Read persisted setting states from an already-open settings XML document
--- into RLSettings.SETTINGS. The codec seam behind the disk wrapper
--- (loadFromXMLFile): takes the document as a dependency so the branches are
--- testable with an in-memory XMLFile (in-game disk IO is engine-gated).
--- Int-coded settings read the state index (range-clamped); string-coded
--- settings (valueType == "string") match the persisted VALUE string against
--- setting.values - an absent element keeps the default silently (every
--- pre-feature save lacks it), an unmatched value keeps the default with one
--- warning.
--- @param xmlFile table Open XMLFile document carrying the settings
--- @param key string Root element key ("rm_RlSettings", or "settings" for the legacy file)
function RLSettings.readSettingStates(xmlFile, key)

	for name, setting in pairs(RLSettings.SETTINGS) do

		if setting.ignore then continue end

		if setting.valueType == "string" then

			local value = xmlFile:getString(key .. "." .. name .. "#value")

			setting.state = setting.default

			if value ~= nil then

				local matched = nil

				for i = 1, #setting.values do
					if setting.values[i] == value then
						matched = i
						break
					end
				end

				if matched ~= nil then
					setting.state = matched
				else
					Log:warning("RLSettings.readSettingStates: '%s' has unknown persisted value '%s'; keeping default", name, tostring(value))
				end

			end

			if setting.state ~= setting.default then
				Log:info("RLSettings.readSettingStates: '%s' loaded non-default value '%s'", name, tostring(setting.values[setting.state]))
			end

		else

			setting.state = xmlFile:getInt(key .. "." .. name .. "#value", setting.default)

			if setting.state > #setting.values then setting.state = #setting.values end

		end

		if name == "useCustomAnimals" and setting.state == 2 then RLSettings.animalsXMLPath = xmlFile:getString(key .. ".useCustomAnimals#path") end

	end

end


--- Load persisted setting states from the savegame (rm_RlSettings.xml, with
--- legacy rlSettings.xml fallback). Disk wrapper: resolves the file, then
--- delegates the per-setting codec to readSettingStates.
function RLSettings.loadFromXMLFile()

	if g_currentMission.missionInfo == nil or g_currentMission.missionInfo.savegameDirectory == nil then return end

	local savegameDir = g_currentMission.missionInfo.savegameDirectory

	-- Try new filename first, fall back to old filename (migration support)
	local path = savegameDir .. "/rm_RlSettings.xml"
	local xmlFile = XMLFile.loadIfExists("rm_RlSettings", path)
	local rootKey = "rm_RlSettings"

	if xmlFile == nil then
		-- Fall back to legacy filename
		path = savegameDir .. "/rlSettings.xml"
		xmlFile = XMLFile.loadIfExists("rlSettings", path)
		rootKey = "settings"
	end

	if xmlFile ~= nil then

		Log:debug("RLSettings.loadFromXMLFile: loading from '%s' (rootKey=%s)", path, rootKey)

		RLSettings.readSettingStates(xmlFile, rootKey)

		xmlFile:delete()

	else

		Log:debug("RLSettings.loadFromXMLFile: no rm_RlSettings.xml or rlSettings.xml found; settings stay at defaults")

	end

end


--- Deferred filter-load entry point. Called from AnimalSystem:loadFromXMLFile,
--- ahead of the animal-data early-return, so it runs regardless of whether
--- rm_RlAnimalSystem.xml exists. Filter scope resolution
--- (RLFilterSerialization.animalTypeNameToIndex) needs the AnimalType registry
--- to turn scope strings ("CHICKEN" / "COW" / ...) into indices; that registry
--- is built at loadMapData, which completes before this hook runs. Do NOT move
--- this to RLSettings.initialize (also loadMapData, but earlier than the
--- registry build): loading filters before the registry exists drops every
--- filter to global scope, so the cycle pulls every saved filter regardless of
--- the active animal type. Server-only - matches the saveToXMLFile gate.
function RLSettings.loadFiltersFromXMLFile()

	if g_currentMission.missionInfo == nil or g_currentMission.missionInfo.savegameDirectory == nil then return end
	if g_server == nil then return end

	if g_rlFilterService == nil then
		Log:warning("RLSettings.loadFiltersFromXMLFile: g_rlFilterService is nil; skipping filter load (load-order regression?)")
		return
	end

	local path = g_currentMission.missionInfo.savegameDirectory .. "/rm_RlSettings.xml"
	local xmlFile = XMLFile.loadIfExists("rm_RlSettings", path)
	if xmlFile == nil then
		Log:debug("RLSettings.loadFiltersFromXMLFile: no rm_RlSettings.xml on disk; filter registry stays empty")
		return
	end

	g_rlFilterService:loadFromXMLFile(xmlFile, RLFilterService.XML_BASE_KEY)
	xmlFile:delete()
end


--- Deferred rule-load entry point. Sibling of
--- loadFiltersFromXMLFile: server-only, GUI-free, called from
--- AnimalSystem:loadFromXMLFile (NOT from the GUI-coupled RLSettings.initialize,
--- which is reached only through the in-game-menu builder). Rules carry no
--- animalType, so the AnimalType-registry timing reason that drives the filter
--- load does not apply here - rules just need a GUI-free, server-side,
--- once-per-load savegame hook, which AnimalSystem:loadFromXMLFile already is.
--- Re-opens rm_RlSettings.xml once more so the rule registry owns its own error
--- boundary (a corrupt filters subtree cannot abort rule load, or vice versa).
function RLSettings.loadRulesFromXMLFile()

	if g_currentMission.missionInfo == nil or g_currentMission.missionInfo.savegameDirectory == nil then return end
	if g_server == nil then return end

	if g_rlHerdsmanRuleService == nil then
		Log:warning("RLSettings.loadRulesFromXMLFile: g_rlHerdsmanRuleService is nil; skipping rule load (load-order regression?)")
		return
	end

	local path = g_currentMission.missionInfo.savegameDirectory .. "/rm_RlSettings.xml"
	local xmlFile = XMLFile.loadIfExists("rm_RlSettings", path)
	if xmlFile == nil then
		-- No file: clear so a previously-populated singleton cannot leak across a
		-- second savegame load in the same session (g_rlHerdsmanRuleService is an
		-- eager source-time singleton that persists between loads). The non-nil
		-- xmlFile path clears via the service's own loadFromXMLFile; this branch
		-- short-circuits before that, so clear here to honour "registry empty".
		g_rlHerdsmanRuleService:clear()
		Log:debug("RLSettings.loadRulesFromXMLFile: no rm_RlSettings.xml on disk; rule registry cleared (empty)")
		return
	end

	g_rlHerdsmanRuleService:loadFromXMLFile(xmlFile, RLHerdsmanRuleService.XML_BASE_KEY)
	xmlFile:delete()
end


--- loadDealerSaleFromXMLFile: server-only, GUI-free sibling of
--- loadRulesFromXMLFile. Reconstructs the g_rlDealerSaleRegistry singleton (A1's
--- documented per-savegame reset - the pure registry owns no clear-all), then
--- repopulates it from rm_RlSettings.xml via the additive codec load seam. Rides
--- AnimalSystem:loadFromXMLFile alongside the filter/rule loaders - RLRM's
--- GUI-free, server-side, once-per-load savegame hook - NOT the GUI-coupled
--- RLSettings.initialize. Re-opens rm_RlSettings.xml for its OWN error boundary
--- so a corrupt dealer subtree cannot abort filter or rule load, or vice versa.
--- The codec stores subtype names verbatim and resolves no index, so unlike the
--- filter load this hook carries no AnimalType-registry timing dependency; the
--- position is chosen for consistency and to co-locate with A3's apply.
function RLSettings.loadDealerSaleFromXMLFile()

	if g_currentMission.missionInfo == nil or g_currentMission.missionInfo.savegameDirectory == nil then return end
	if g_server == nil then return end

	-- Reconstruct fresh: this IS the per-savegame reset (reconstruction, not a
	-- clear-all), so a singleton populated by a prior load in the same session
	-- cannot leak, and the no-file branch below is left an empty registry.
	g_rlDealerSaleRegistry = RLDealerSaleRegistry.new()

	local path = g_currentMission.missionInfo.savegameDirectory .. "/rm_RlSettings.xml"
	local xmlFile = XMLFile.loadIfExists("rm_RlSettings", path)
	if xmlFile == nil then
		Log:debug("RLSettings.loadDealerSaleFromXMLFile: no rm_RlSettings.xml on disk; dealer override registry stays empty")
		return
	end

	RLDealerSaleSerialization.loadFromXMLFile(xmlFile, RLDealerSaleSerialization.XML_BASE_KEY, g_rlDealerSaleRegistry)
	xmlFile:delete()
end


--- Write every setting state as rm_RlSettings child elements on an
--- already-open XML document. The codec seam behind the disk wrapper
--- (saveToXMLFile): takes the document as a dependency so the branches are
--- testable with an in-memory XMLFile. Int-coded settings write the state
--- index; string-coded settings (valueType == "string") write the VALUE
--- string (state 1 writes "default") so an AREA_CODES reorder can never
--- re-map saves.
--- @param xmlFile table Open XMLFile document to write into
function RLSettings.writeSettingStates(xmlFile)

	for settingName, setting in pairs(RLSettings.SETTINGS) do

		if setting.ignore then continue end

		if setting.valueType == "string" then
			local value = setting.values[setting.state or setting.default]

			-- A state outside values (bad wire commit, corrupt caller) must
			-- never feed nil into setString; persist the default value instead.
			if value == nil then
				Log:warning("RLSettings.writeSettingStates: '%s' state %s has no value entry; persisting the default", settingName, tostring(setting.state))
				value = setting.values[setting.default]
			end

			xmlFile:setString("rm_RlSettings." .. settingName .. "#value", value)
		else
			xmlFile:setInt("rm_RlSettings." .. settingName .. "#value", setting.state or setting.default)
		end

		if settingName == "useCustomAnimals" and setting.state == 2 and RLSettings.animalsXMLPath ~= nil then xmlFile:setString("rm_RlSettings.useCustomAnimals#path", RLSettings.animalsXMLPath) end

	end

end


--- Persist every setting state plus the filter and herdsman-rule subtrees to
--- the savegame's rm_RlSettings.xml (server only). Disk wrapper: creates the
--- file, delegates the per-setting codec to writeSettingStates, then appends
--- the service subtrees and saves.
--- @param name string|nil Changed-setting name (log context only)
--- @param state number|nil Changed-setting state (log context only)
function RLSettings.saveToXMLFile(name, state)

	Log:debug("RLSettings.saveToXMLFile: called (name=%s state=%s g_server=%s isSaving=%s)",
		tostring(name), tostring(state), tostring(g_server ~= nil), tostring(RLSettings.isSaving))

	if RLSettings.isSaving or g_currentMission.missionInfo == nil or g_currentMission.missionInfo.savegameDirectory == nil then
		Log:debug("RLSettings.saveToXMLFile: early return (isSaving, or no missionInfo/savegameDirectory)")
		return
	end

	if g_server ~= nil then

		RLSettings.isSaving = true

		-- Always save to new filename with versioning
		local path = g_currentMission.missionInfo.savegameDirectory .. "/rm_RlSettings.xml"
		local xmlFile = XMLFile.create("rm_RlSettings", path, "rm_RlSettings")

		if xmlFile ~= nil then

			-- Add version attribute for future migrations
			xmlFile:setInt("rm_RlSettings#version", 1)

			RLSettings.writeSettingStates(xmlFile)

			-- Saveable filters share rm_RlSettings.xml as their on-disk
			-- home. Server-only by virtue of the surrounding g_server
			-- branch above.
			if g_rlFilterService ~= nil then
				g_rlFilterService:saveToXMLFile(xmlFile, RLFilterService.XML_BASE_KEY)
			else
				Log:warning("RLSettings.saveToXMLFile: g_rlFilterService is nil; skipping filter save (load-order regression?)")
			end

			-- Herdsman rules share the same rm_RlSettings.xml file (their own
			-- subtree under RLHerdsmanRuleService.XML_BASE_KEY).
			-- Symmetric with the filter save above; server-only.
			if g_rlHerdsmanRuleService ~= nil then
				g_rlHerdsmanRuleService:saveToXMLFile(xmlFile, RLHerdsmanRuleService.XML_BASE_KEY)
			else
				Log:warning("RLSettings.saveToXMLFile: g_rlHerdsmanRuleService is nil; skipping rule save (load-order regression?)")
			end

			-- Dealer sale-availability overrides share the same rm_RlSettings.xml
			-- (their own subtree). The seam is a DOT-function taking the registry
			-- as the third arg - the pure RLDealerSaleRegistry owns no XML method.
			-- Symmetric with the filter/herdsman appends above; server-only.
			if g_rlDealerSaleRegistry ~= nil then
				RLDealerSaleSerialization.saveToXMLFile(xmlFile, RLDealerSaleSerialization.XML_BASE_KEY, g_rlDealerSaleRegistry)
			else
				Log:warning("RLSettings.saveToXMLFile: g_rlDealerSaleRegistry is nil; skipping dealer-sale save (load-order regression?)")
			end

			local saved = xmlFile:save(false, true)

			xmlFile:delete()

		end

	end

	RLSettings.isSaving = false

end


--- Build the RLRM launcher row on the base-game pause-menu Settings page.
--- The server-side settings load runs first and unconditionally, followed
--- by an unconditional defaulting pass for states the savegame did not
--- provide; the GUI part clones the section header plus a single button
--- row whose click opens the RL Menu Settings tab - the sole RLRM
--- settings editor. The GUI build is skipped (load and defaulting already
--- done) when the menu tree chain is absent.
function RLSettings.initialize()

	if g_server ~= nil then RLSettings.loadFromXMLFile() end

	-- Default any state the savegame did not provide (fresh save / newly
	-- added setting). Runs BEFORE the GUI guard so no-GUI contexts get
	-- defaulted states too; applyDefaultSettings and the RL Menu builder
	-- read setting.state directly.
	local defaulted = 0

	for _, setting in pairs(RLSettings.SETTINGS) do
		if not setting.ignore and setting.state == nil then
			setting.state = setting.default
			defaulted = defaulted + 1
		end
	end

	if defaulted > 0 then Log:debug("RLSettings.initialize: defaulted %d setting state(s) missing from the savegame", defaulted) end

	if g_inGameMenu == nil or g_inGameMenu.pageSettings == nil or g_inGameMenu.pageSettings.gameSettingsLayout == nil then
		Log:info("RLSettings.initialize: no pause-menu settings layout (g_inGameMenu chain nil); skipping launcher button build")
		return
	end

	local scrollPanel = g_inGameMenu.pageSettings.gameSettingsLayout

	-- Template scan only; cloning happens after the loop so the elements
	-- array is not mutated while pairs() walks it.
	local sectionHeaderTemplate, buttonRowTemplate

	for _, element in pairs(scrollPanel.elements) do

		if element.name == "sectionHeader" and sectionHeaderTemplate == nil then sectionHeaderTemplate = element end

		if element.typeName == "Bitmap" and element.elements[1] ~= nil and element.elements[1].typeName == "Button" and buttonRowTemplate == nil then buttonRowTemplate = element end

		if sectionHeaderTemplate ~= nil and buttonRowTemplate ~= nil then break end

	end

	if sectionHeaderTemplate == nil or buttonRowTemplate == nil then
		Log:warning("RLSettings.initialize: base-game templates missing (sectionHeader=%s buttonRow=%s); skipping launcher button build",
			tostring(sectionHeaderTemplate ~= nil), tostring(buttonRowTemplate ~= nil))
		return
	end

	local sectionHeader = sectionHeaderTemplate:clone(scrollPanel)
	sectionHeader:setText(g_i18n:getText("rl_settings"))
	sectionHeader.id = nil

	local buttonRow = buttonRowTemplate:clone(scrollPanel)
	buttonRow.id = nil

	local buttonsWired = 0

	for _, element in pairs(buttonRow.elements) do

		if element.typeName == "Text" then
			element:setText(g_i18n:getText("rl_settings_openMenu_label"))
			element.id = nil
		end

		if element.typeName == "Button" then
			element:setText(g_i18n:getText("rl_settings_openMenu_button"))
			element:applyProfile("rl_settingsButton")
			element.isAlwaysFocusedOnOpen = false
			element.focused = false
			element.id = nil
			element.onClickCallback = RLSettings.onClickOpenMenu
			buttonsWired = buttonsWired + 1
		end

	end

	if buttonsWired ~= 1 then
		-- Fail closed: leave the base-game page untouched rather than ship
		-- a broken or duplicated launcher row.
		buttonRow:delete()
		sectionHeader:delete()
		Log:warning("RLSettings.initialize: self-check FAILED - expected 1 launcher button, wired %d (base-game button-row template shape changed?); removed the cloned header/row", buttonsWired)
		return
	end

	Log:debug("RLSettings.initialize: self-check - 1 launcher button wired, 0 setting rows added")

end


--- Open the RL Menu on the Settings tab (General subtab) from the
--- pause-menu launcher button. On a refused open (menu not ready or a
--- dialog visible) the pause menu stays; the refusal is log-only by design.
function RLSettings.onClickOpenMenu()

	Log:info("RLSettings.onClickOpenMenu: opening RL Menu Settings tab (page 8, MODE_FULL)")

	if RLMenu.openFromBridge(8, RLMenu.MODE_FULL) == false then
		Log:warning("RLSettings.onClickOpenMenu: openFromBridge refused; staying on the pause menu")
	end

end


--- Apply a state change to a stateful setting.
--- Single write path for stateful settings, driven by the RL Tabbed Menu
--- Settings -> General subtab (RLMenuSettingsFrame's row click handlers).
--- The order is:
---   (1) run the per-setting callback with the NEW value (the callback
---       sees newState before setting.state has been written; callbacks
---       read the new value via the second arg, not via setting.state)
---   (2) write setting.state = newState
---   (3) cascade-disable children of this setting on setting.element refs
---   (4) refresh the element's dynamic tooltip if applicable
---
--- Steps (3)-(4) and the trailing widget push operate on setting.element,
--- which stays nil now that the pause menu builds no setting rows; every
--- consumer nil-guards, so they are dormant no-ops. The RL menu page
--- maintains its OWN element registry and runs ITS OWN cascade after this
--- call returns; this function does not know about the frame's elements.
---
--- Action rows (setting.ignore == true) skip this path; their callers
--- invoke setting.callback directly.
--- @param name string The key of the setting in RLSettings.SETTINGS
--- @param newState number 1-based state index into setting.values
--- @return boolean true on successful state write; false if the setting is
---                 unknown (caller passed a bad name) OR if it is an action
---                 row (setting.ignore == true) - both failure modes are
---                 conflated under the same false return because the caller
---                 (onClickGeneralSetting) never needs to distinguish them.
function RLSettings.applyChange(name, newState)

	local setting = RLSettings.SETTINGS[name]

	if setting == nil then
		Log:warning("RLSettings.applyChange: unknown setting '%s'", tostring(name))
		return false
	end

	if setting.ignore then
		Log:trace("RLSettings.applyChange: '%s' is an ignored/action row, skipping state write", name)
		return false
	end

	Log:debug("RLSettings.applyChange: name='%s' newState=%s (was=%s)",
		name, tostring(newState), tostring(setting.state))

	if setting.callback then setting.callback(name, setting.values[newState]) end

	setting.state = newState

	if name == "mapCountry" then
		if newState == 1 then
			Log:info("RLSettings.applyChange: map country override cleared to map default")
		else
			Log:info("RLSettings.applyChange: map country override set to %s", tostring(setting.values[newState]))
		end
	end

	-- Cascade to children whose dependancy parent is this setting.
	-- Operates on setting.element refs (nil for every setting now that the
	-- pause menu builds no rows - dormant no-op); the RL menu page runs an
	-- equivalent cascade on its own controls registry.
	for childName, s in pairs(RLSettings.SETTINGS) do
		if s.dependancy and s.dependancy.name == name and s.element ~= nil then
			local shouldDisable = (s.dependancy.state ~= newState)
			Log:trace("RLSettings.applyChange: cascading -> '%s' setDisabled(%s)",
				childName, tostring(shouldDisable))
			s.element:setDisabled(shouldDisable)
		end
	end

	if setting.dynamicTooltip and setting.element ~= nil then
		Log:trace("RLSettings.applyChange: refreshing dynamic tooltip for '%s' state=%d", name, newState)
		setting.element.elements[1]:setText(g_i18n:getText("rl_settings_" .. name .. "_tooltip_" .. newState))
	end

	-- Push new state to a bound widget ref if one exists. setting.element
	-- stays nil now that the pause menu builds no setting rows, so this is
	-- a dormant no-op; forceEvent=false keeps a re-bound widget from
	-- re-raising its click callback.
	if setting.element ~= nil then
		Log:trace("RLSettings.applyChange: pushing newState=%d to legacy element for '%s'", newState, name)
		setting.element:setState(newState, false)
	end

	return true

end


function RLSettings.applyDefaultSettings()

	if g_server == nil then

	else

		for name, setting in pairs(RLSettings.SETTINGS) do
		
			if setting.ignore then continue end

			if setting.callback ~= nil then setting.callback(name, setting.values[setting.state]) end

			if setting.dynamicTooltip and setting.element ~= nil then setting.element.elements[1]:setText(g_i18n:getText("rl_settings_" .. name .. "_tooltip_" .. setting.state)) end

			for _, s in pairs(RLSettings.SETTINGS) do
				if s.dependancy and s.dependancy.name == name and s.element ~= nil then
					s.element:setDisabled(s.dependancy.state ~= state)
				end
			end
		end

	end
end


function RLSettings.getAnimalsXMLPath()
	
	if RLSettings.customAnimals == nil then return nil end

	return RLSettings.customAnimals.basePath .. RLSettings.customAnimals.animals

end


function RLSettings.getFillTypesXMLPath()
	
	if RLSettings.customAnimals == nil then return nil end

	return RLSettings.customAnimals.basePath .. RLSettings.customAnimals.fillTypes

end


function RLSettings.getTranslationsFolderPath()
	
	if RLSettings.customAnimals == nil then return nil end

	return RLSettings.customAnimals.basePath .. RLSettings.customAnimals.translations

end


function RLSettings.getAnimalsBasePath()
	
	if RLSettings.customAnimals == nil then return nil end

	return RLSettings.customAnimals.basePath

end


function RLSettings.getOverrideVanillaAnimals()

	if RLSettings.customAnimals == nil then return false end

	return RLSettings.customAnimals.override

end


function RLSettings.validateCustomAnimalsConfiguration()

	if RLSettings.SETTINGS.useCustomAnimals.state == 1 or RLSettings.animalsXMLPath == nil or g_currentMission.missionDynamicInfo.isMultiplayer then return end

	local xmlFile = XMLFile.loadIfExists("customAnimalsConfig", RLSettings.animalsXMLPath)

	if xmlFile == nil then return end

	local basePath
	local splitPath = string.split(RLSettings.animalsXMLPath, "/")

	for i = #splitPath, 1, -1 do

		local path = table.concat(splitPath, "/", 1, i)

		if path == baseDirectory then
			basePath = table.concat(splitPath, "/", 1, i + 1) .. "/"
			break
		end

	end

	if basePath == nil then return end

	RLSettings.customAnimals = {
		["basePath"] = basePath,
		["animals"] = xmlFile:getString("RealisticLivestock#animals", "animals.xml"),
		["fillTypes"] = xmlFile:getString("RealisticLivestock#fillTypes", "fillTypes.xml"),
		["translations"] = xmlFile:getString("RealisticLivestock#translations", "l10n/"),
		["override"] = xmlFile:getBool("RealisticLivestock#override", false)
	}

	xmlFile:delete()

	local l10nNames = {
		g_languageShort,
		"en",
		"de"
	}

	local l10nXML
	
	for _, l10nName in pairs(l10nNames) do
		l10nXML = XMLFile.loadIfExists("l10n", basePath .. RLSettings.customAnimals.translations .. "_" .. l10nName .. ".xml")
		if l10nXML ~= nil then break end
	end

	if l10nXML ~= nil then

		l10nXML:iterate("l10n.texts.text", function(_, key)
		
			local name = l10nXML:getString(key .. "#name")
			local text = l10nXML:getString(key .. "#text")

			if name ~= nil and text ~= nil then
				
				if g_i18n:hasModText(name) then
					printWarning("Warning: Duplicate l10n entry \'" .. name .. "\'. Ignoring this definition.")
				else
					g_i18n:setText(name, text:gsub("\r\n", "\n"))
				end
			
			end
		
		end)

		l10nXML:delete()

	end

	local fillTypesXML = loadXMLFile("fillTypes", basePath .. RLSettings.customAnimals.fillTypes)
	g_fillTypeManager:loadFillTypes(fillTypesXML, basePath, false, modName)

end