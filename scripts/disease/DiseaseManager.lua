DiseaseManager = {}

local modDirectory = g_currentModDirectory
local diseaseManager_mt = Class(DiseaseManager)

local Log = RmLogging.getLogger("RLRM")

function DiseaseManager.new()

    local self = setmetatable({}, diseaseManager_mt)

	self.diseases = {}
	self.diseasesEnabled = true
	self.diseasesChance = 1

	self:loadDiseases()

	return self

end


function DiseaseManager:loadDiseases()

	local xmlFile = XMLFile.loadIfExists("diseases", modDirectory .. "xml/diseases.xml")

	if xmlFile == nil then return end

	xmlFile:iterate("diseases.disease", function(_, key)
	
		local title = xmlFile:getString(key .. "#title")
		local translationKey = "rl_disease_" .. title
		local name = g_i18n:getText(translationKey)

		local animals = {}
		local animalTitles = string.split(xmlFile:getString(key .. "#animals"), " ")

		for _, animalTitle in pairs(animalTitles) do animals[AnimalType[animalTitle]] = true end

		local valueModifier = xmlFile:getFloat(key .. "#value", 1.0)
		local transmission = xmlFile:getFloat(key .. "#transmission", 0)
		local immunity = xmlFile:getInt(key .. "#immunity", 12)

		local prerequisites = {}

		xmlFile:iterate(key .. ".prerequisites.prerequisite", function(_, prerequisiteKey)

			local valueType = xmlFile:getString(prerequisiteKey .. "#valueType", "Int")
		
			table.insert(prerequisites, {
				["path"] = string.split(xmlFile:getString(prerequisiteKey .. "#path"), "."),
				["value"] = XMLFile["get" .. valueType](xmlFile, prerequisiteKey .. "#value")
			})
		
		end)

		local probability = {}

		xmlFile:iterate(key .. ".probability.key", function(_, probabilityKey)

			table.insert(probability, {
				["age"] = xmlFile:getInt(probabilityKey .. "#age"),
				["value"] = xmlFile:getFloat(probabilityKey .. "#value")
			})
		
		end)

		local fatality = {}

		xmlFile:iterate(key .. ".fatality.key", function(_, fatalityKey)

			table.insert(fatality, {
				["time"] = xmlFile:getInt(fatalityKey .. "#time"),
				["value"] = xmlFile:getFloat(fatalityKey .. "#value")
			})
		
		end)

		local output = {}

		xmlFile:iterate(key .. ".output.fillType", function(_, outputKey)

			output[xmlFile:getString(outputKey .. "#type")] = xmlFile:getFloat(outputKey .. "#modifier")
		
		end)

		local treatment = {
			["cost"] = xmlFile:getFloat(key .. ".treatment#cost"),
			["duration"] = xmlFile:getInt(key .. ".treatment#duration")
		}

		if treatment.cost == nil or treatment.duration == nil then treatment = nil end

		local recovery = xmlFile:getFloat(key .. "#recovery")

		local disease = {
			["title"] = title,
			["key"] = translationKey,
			["name"] = name,
			["animals"] = animals,
			["value"] = valueModifier,
			["transmission"] = transmission,
			["immunity"] = immunity,
			["prerequisites"] = prerequisites,
			["probability"] = probability,
			["fatality"] = fatality,
			["output"] = output,
			["treatment"] = treatment,
			["recovery"] = recovery
		}

		if xmlFile:hasProperty(key .. ".carrier") then

			local carrier = {}

			if xmlFile:hasProperty(key .. ".carrier.output") then

				local carrierOutput = {}

				xmlFile:iterate(key .. ".output.fillType", function(_, outputKey)

					carrierOutput[xmlFile:getString(outputKey .. "#type")] = xmlFile:getFloat(outputKey .. "#modifier")
		
				end)

				carrier.output = carrierOutput

			end

			disease.carrier = carrier

		end

		if xmlFile:hasProperty(key .. ".genetic") then

			disease.genetic = {
				["recessive"] = xmlFile:getBool(key .. ".genetic#recessive", false),
				["dominant"] = xmlFile:getBool(key .. ".genetic#dominant", false),
				["saleChance"] = xmlFile:getFloat(key .. ".genetic#saleChance", 0)
			}

		end

		table.insert(self.diseases, disease)
	
	end)

	xmlFile:delete()

end


function DiseaseManager:getDiseaseByTitle(title)

	for _, disease in pairs(self.diseases) do
		if disease.title == title then return disease end
	end

	return nil

end


function DiseaseManager:onDayChanged(animal)

	if not self.diseasesEnabled then return end

	for _, disease in pairs(self.diseases) do

		if not disease.animals[animal.animalTypeIndex] then continue end

		local eligible = true

		for _, existingDisease in pairs(animal.diseases) do

			if existingDisease.type.title == disease.title then
				eligible = false
				break
			end

		end

		if not eligible then continue end

		for _, prerequisite in pairs(disease.prerequisites) do

			local currentValue = animal

			for _, path in pairs(prerequisite.path) do

				currentValue = currentValue[path]

				if currentValue == nil then eligible = false break end

			end

			if currentValue ~= prerequisite.value then
				eligible = false
				break
			end

		end

		if not eligible then continue end

		local probability = 0

		for i = 1, #disease.probability do

			if animal.age <= disease.probability[i].age or i == #disease.probability then
				probability = disease.probability[i].value
				break
			end

		end

		if math.random() >= probability * self.diseasesChance then continue end

		animal:addDisease(disease)

	end

end


function DiseaseManager:setGeneticDiseasesForSaleAnimal(animal)

	for _, disease in pairs(self.diseases) do

		if not disease.animals[animal.animalTypeIndex] or disease.genetic == nil or disease.probability[1].value ~= 0 or #disease.probability > 1 then continue end

		local eligible = true

		for _, existingDisease in pairs(animal.diseases) do

			if existingDisease.type.title == disease.title then
				eligible = false
				break
			end

		end

		if not eligible then continue end

		if math.random() < disease.genetic.saleChance then

			local numGenes = 1

			if math.random() <= 0.25 then numGenes = 2 end

			animal:addDisease(disease, disease.genetic.recessive and numGenes == 1, numGenes)

		end

	end

end


--- Render the collected sources as a stable "title=amount" list for the per-pen
--- summary. The sort is load-bearing rather than cosmetic: pairs order is undefined,
--- and the summary lines are compared across successive months.
---@param sources table|nil the collector's source set
---@return string a sorted "title=amount ..." list, or "none" when there are no sources
local function formatSources(sources)

	-- Unreachable from the single call site, whose input is contract-guaranteed to be
	-- a table. Kept because a raise here would land OUTSIDE the logger's own pcall and
	-- abandon the pen's period tick, which is a worse trade than one dead branch.
	if sources == nil then return "none" end

	local titles = {}

	for title in pairs(sources) do table.insert(titles, title) end

	if #titles == 0 then return "none" end

	table.sort(titles)

	local parts = {}

	for _, title in ipairs(titles) do
		local entry = sources[title]
		table.insert(parts, string.format("%s=%s", title, tostring(entry ~= nil and entry.amount or "?")))
	end

	return table.concat(parts, " ")

end


--- Collect the contagious disease sources across a pen.
---
--- A record contributes when its type transmits AND the record is not cured, or is
--- a genetic carrier - an asymptomatic shedder is still shedding. A dead animal is
--- skipped whole: a corpse does not shed, and it remains in the array until the
--- pending cluster removal runs.
---
--- Deliberately NOT the display predicate. The list surfaces and the saveable-filter
--- catalog ask "should a player see this animal as sick" and exclude carriers; this
--- asks "is this animal shedding" and includes them. Folding the two into one shared
--- helper silently stops carriers transmitting.
--- @see RLFilterFieldCatalog.FIELDS hasAnyDisease
--- @see Animal.getHasAnyDisease
---
--- Call it with the DOT form. DiseaseManager carries a Class() metatable, so a colon
--- call resolves and passes the manager itself as `animals`; the walk then reaches a
--- scalar field and RAISES on `animal.isDead`. Loud rather than silent - but the pen's
--- period tick runs inside a safe-call that swallows the raise, so the mistake still
--- costs a tick.
---
--- The sole production caller is `snapshotTransmission`, and the blast radius of a raise
--- here is wider than it looks: the pen takes that snapshot ABOVE its per-animal loop, so
--- a raise abandons disease progression and the treatment charge for that pen that period,
--- not just the transmission pass. The reachable producer is a savegame naming a disease
--- title absent from `xml/diseases.xml` - a mod removed or downgraded between sessions -
--- which yields `disease.type == nil`. Guarding that loader is deliberately not done here.
---
---@param animals table|nil the pen's animals; nil yields no sources rather than raising
---@return table sources keyed by disease title -> { type = <type table>, amount = <integer> }; ALWAYS a table
---@return boolean hasSources true when at least one record was counted
---@return table stats { curedSkipped, deadSkipped, animals } - tallies the caller cannot recover
--- without re-walking. The two skip counters are DIFFERENT UNITS and must be rendered as such:
--- `curedSkipped` counts RECORDS (one animal can contribute several), while `deadSkipped` counts
--- ANIMALS, because a corpse is skipped whole before its records are read.
function DiseaseManager.collectTransmissionSources(animals)

	local sources = {}
	local hasSources = false
	local stats = { curedSkipped = 0, deadSkipped = 0, animals = 0 }

	if animals == nil then

		Log:trace("collectTransmissionSources: nil animals table, no sources")

		return sources, hasSources, stats

	end

	for _, animal in pairs(animals) do

		stats.animals = stats.animals + 1

		if animal.isDead then

			stats.deadSkipped = stats.deadSkipped + 1

			Log:trace("collectTransmissionSources: skipped dead animal, reason=dead (uniqueId=%s)", tostring(animal.uniqueId))

			continue

		end

		if animal.diseases == nil then

			Log:trace("collectTransmissionSources: skipped animal, reason=no diseases table (uniqueId=%s)", tostring(animal.uniqueId))

			continue

		end

		for _, disease in pairs(animal.diseases) do

			local type = disease.type

			if type.transmission == nil or type.transmission <= 0 then continue end

			local isSource = (not disease.cured) or disease.isCarrier

			if not isSource then

				stats.curedSkipped = stats.curedSkipped + 1

				Log:trace("collectTransmissionSources: skipped record, reason=cured (disease=%s uniqueId=%s)",
					tostring(type.title), tostring(animal.uniqueId))

				continue

			end

			if sources[type.title] == nil then
				sources[type.title] = { ["type"] = type, ["amount"] = 0 }
				hasSources = true
			end

			sources[type.title].amount = sources[type.title].amount + 1

		end

	end

	return sources, hasSources, stats

end


--- Take a pen's contagious-source snapshot, for a caller that must roll the susceptibles
--- LATER in the same tick.
---
--- The pen's period tick advances every disease record before it rolls transmission, and
--- the collector skips cured records and dead animals whole - so a snapshot taken after
--- progression has already dropped every infection that resolved during it. The animal was
--- contagious for the whole month and shed to nobody. Snapshotting ahead of the progression
--- loop and handing the result to `calculateTransmission` restores that month.
---
--- Carries the SAME `diseasesEnabled` guard as `calculateTransmission`, deliberately. This is the
--- SOLE production caller of the collector - `calculateTransmission` reaches it only through here -
--- so an unguarded path at this level is what a player who toggled diseases off would fall through.
---
--- Calls the collector in the DOT form, from inside the manager, which is what stops any
--- caller becoming its first production colon-caller - see the call-shape warning on
--- `collectTransmissionSources`.
---
--- `penName` is DISPLAY-ONLY and carries the same weight it does on `calculateTransmission`: these
--- lines report per-pen facts, and a multi-pen save otherwise emits a stream of them with nothing
--- to attribute them to.
---@param animals table|nil the pen's animals; nil yields an empty snapshot rather than raising
---@param penName string|nil the husbandry's display name, for log attribution only
---@return table|nil snapshot `{ sources = <table>, hasSources = <boolean>, stats = <table> }`
--- carrying the collector's three return values verbatim, or nil when diseases are disabled
function DiseaseManager:snapshotTransmission(animals, penName)

	if not self.diseasesEnabled then

		Log:trace("snapshotTransmission [%s]: no snapshot, reason=diseases disabled", tostring(penName))

		return nil

	end

	local sources, hasSources, stats = DiseaseManager.collectTransmissionSources(animals)

	Log:trace("snapshotTransmission [%s]: %s animal(s), hasSources=%s (skipped %s cured record(s), %s dead animal(s))",
		tostring(penName), tostring(stats.animals), tostring(hasSources),
		tostring(stats.curedSkipped), tostring(stats.deadSkipped))

	return { sources = sources, hasSources = hasSources, stats = stats }

end


--- Run one pen's transmission pass: collect the shedding sources, then roll each
--- susceptible animal against them.
---
--- `penName` is DISPLAY-ONLY, and exists because the summary line below is the manual
--- walkthrough's oracle: without it a multi-pen save emits a stream of indistinguishable
--- lines and "this pen reached zero sources" cannot be attributed to the pen under test.
--- Nil-tolerant on purpose - a missing name degrades the line, never the pass.
---
--- `snapshot` is how the pen tick rolls against the state the pen was in BEFORE its own
--- progression loop ran. Every other caller omits it and gets today's behaviour unchanged:
--- the sources are collected here, from the pen as it stands now.
---@param animals table the pen's animals
---@param penName string|nil the husbandry's display name, for log attribution only
---@param snapshot table|nil a record from `DiseaseManager:snapshotTransmission` taken earlier
--- in this tick; nil collects the sources now
function DiseaseManager:calculateTransmission(animals, penName, snapshot)

	if not self.diseasesEnabled then

		Log:trace("calculateTransmission [%s]: nothing to roll, reason=diseases disabled", tostring(penName))

		return

	end

	if snapshot == nil then

		-- The guard above has already returned when diseases are off, so the nil arm of
		-- snapshotTransmission is unreachable from here and needs no second guard.
		snapshot = self:snapshotTransmission(animals, penName)

		Log:trace("calculateTransmission [%s]: no snapshot supplied, collected the sources now",
			tostring(penName))

	else

		Log:trace("calculateTransmission [%s]: rolling against the caller's pre-progression snapshot",
			tostring(penName))

	end

	local diseases, hasDiseases, stats = snapshot.sources, snapshot.hasSources, snapshot.stats

	-- Emitted BEFORE the early return below: the walkthrough's terminal condition is
	-- the source count reaching zero, which a summary placed after it could never
	-- report. The rendered list is built into a local first, so no argument
	-- expression here can raise inside the caller's safeCall wrapper.
	local sourceSummary = formatSources(diseases)

	Log:debug("calculateTransmission [%s]: %d animal(s), sources: %s (skipped %d cured record(s), %d dead animal(s))",
		tostring(penName), stats.animals, sourceSummary, stats.curedSkipped, stats.deadSkipped)

	if not hasDiseases then

		Log:trace("calculateTransmission [%s]: nothing to roll, reason=no shedding source in the snapshot",
			tostring(penName))

		return

	end


	for _, animal in pairs(animals) do

		for title, disease in pairs(diseases) do

			local eligible = true

			for _, existingDisease in pairs(animal.diseases) do

				if existingDisease.type.title == title then
					eligible = false
					break
				end

			end

			if not eligible then continue end

			for _, prerequisite in pairs(disease.type.prerequisites) do

				local currentValue = animal

				for _, path in pairs(prerequisite.path) do

					currentValue = currentValue[path]

					if currentValue == nil then eligible = false break end

				end

				if currentValue ~= prerequisite.value then
					eligible = false
					break
				end

			end

			if not eligible then continue end

			if math.random() <= disease.type.transmission * (disease.amount / #animals) then
				animal:addDisease(disease.type)
			end

		end

	end


end


function DiseaseManager.onSettingChanged(name, state)

	if g_diseaseManager ~= nil then g_diseaseManager[name] = state end

end