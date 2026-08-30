DiseaseManager = {}

local modDirectory = g_currentModDirectory
local diseaseManager_mt = Class(DiseaseManager)

local Log = RmLogging.getLogger("RLRM")

function DiseaseManager.new()

    local self = setmetatable({}, diseaseManager_mt)

	self.diseases = {}
	-- Initialised ABOVE the loader call. loadDiseases assigns it unconditionally,
	-- so this is a guard against a future edit that stops doing so rather than a
	-- value anything reads today - but an init placed BELOW the call would clobber
	-- the parsed table with an empty one, and no test would see it.
	self.diseaseModels = {}
	self.diseasesEnabled = true
	self.diseasesChance = 1

	self:loadDiseases()

	return self

end


--- Load the disease definition file into the legacy registry and the model map.
---
--- Runs from `new()`, which the mod re-runs on every map load, so both tables are
--- rebuilt from the archive each time and neither can carry a previous save's
--- contents.
---
--- The single emission point for the parser's authoring warnings: the parse
--- RETURNS them rather than logging them, so each rule stays assertable without a
--- logger spy, and every line a malformed definition file produces comes from
--- here.
---@return nil
function DiseaseManager:loadDiseases()

    -- Thin wrapper: open, parse, assign, log, delete. The parse itself lives in
    -- RLDiseaseDefinition so both halves of the registry are built in one place
    -- and a later teardown deletes a branch rather than untangling one.
    --
    -- Deliberately NO pcall around parse. Its contract is that it does not raise
    -- for any input, so a raise here is a wiring bug that must crash loudly
    -- rather than be swallowed into a silently empty registry.
    --
    -- A nil xmlFile is handed straight to parse rather than short-circuited here:
    -- the absent-file case is one of parse's own warning rules, which keeps this
    -- function the SINGLE emission point for the whole vocabulary.
    local xmlFile = XMLFile.loadIfExists("diseases", modDirectory .. "xml/diseases.xml")

    local legacy, models, warnings = RLDiseaseDefinition.parse(xmlFile, {
        ["animalTypes"] = AnimalType,
        ["i18n"] = g_i18n
    })

    self.diseases = legacy
    self.diseaseModels = models

    -- Every value goes through %s + tostring(): the headless harness formats with
    -- a bare string.format and RAISES where the in-game logger degrades, so a
    -- typed specifier here would turn a malformed-input warning into a suite
    -- crash on one runner only.
    for _, authoringWarning in ipairs(warnings) do
        Log:warning("loadDiseases: %s (disease=%s) - %s",
            tostring(authoringWarning.rule),
            tostring(authoringWarning.title),
            tostring(authoringWarning.detail))
    end

    local modelCount = 0
    local titles = {}

    for title in pairs(models) do
        modelCount = modelCount + 1
        table.insert(titles, title)
    end

    -- Sorted at BOTH levels, and for the same reason: pairs order is undefined, so
    -- an unsorted walk names the same diseases and the same channels in a
    -- different order on every load, which defeats a grep across two logs and
    -- would make any ordered log pin flaky the moment a second carrier exists.
    table.sort(titles)

    for _, title in ipairs(titles) do

        local model = models[title]

        if model.carrier ~= nil and next(model.carrier.output) ~= nil then

            local channels = {}

            -- %.6g, not tostring: the engine reads these as 32-bit floats, so
            -- tostring renders 0.35 as 0.3499999940395355 in-game and 0.35
            -- headless. Six significant digits round that away and still carry
            -- every authored value.
            for channel, modifier in pairs(model.carrier.output) do
                table.insert(channels, string.format("%s=%.6g", tostring(channel), modifier))
            end

            table.sort(channels)

            Log:debug("loadDiseases: %s carrier output modifiers loaded (%s)",
                tostring(title), table.concat(channels, " "))

        end

    end

    Log:info("loadDiseases: %s disease(s) defined, %s with a model block, %s authoring warning(s)",
        tostring(#legacy), tostring(modelCount), tostring(#warnings))

    if xmlFile ~= nil then xmlFile:delete() end

end


function DiseaseManager:getDiseaseByTitle(title)

	for _, disease in pairs(self.diseases) do
		if disease.title == title then return disease end
	end

	return nil

end


--- Render a caller-supplied identity table as a stable "key=value" list for a warning line.
---
--- The sort is load-bearing rather than cosmetic: pairs order is undefined, so an unsorted line
--- names the same fields in a different order on every call and defeats a grep across a load.
---
--- TOTAL by construction, and that is the point rather than defensiveness: this renders the
--- argument of a WARNING, so a raise in here would turn a benign dropped record into an aborted
--- stream read - the one outcome the drop exists to avoid. Two things buy it. A non-table
--- identity degrades instead of reaching `pairs`, and the sort keys through `tostring` rather
--- than comparing raw keys, because `table.sort` raises on a mixed-type key set and a caller
--- that hands over a table with one positional entry would otherwise take the read down with it.
--- Values go through `tostring` because a bare `string.format` raises on an argument that does not
--- match its specifier, and not every runtime this code has to survive wraps that call.
---@param identity table|nil whatever the call site holds; nil and a non-table both degrade
---@return string a sorted "key=value ..." list, or "no identity" when there is nothing to name
local function formatIdentity(identity)

    if type(identity) ~= "table" then
        if identity == nil then return "no identity" end
        return tostring(identity)
    end

    local rendered = {}

    for key, value in pairs(identity) do
        table.insert(rendered, string.format("%s=%s", tostring(key), tostring(value)))
    end

    if #rendered == 0 then return "no identity" end

    table.sort(rendered)

    return table.concat(rendered, " ")

end


--- Resolve a persisted or transmitted disease title to its registry type, refusing any title the
--- shipped definition file no longer carries.
---
--- Every reconstruction path routes through here, so no `Disease` carrying a nil `type` is ever
--- RETAINED. That is what lets `saveToXMLFile`, `writeStream`, `onPeriodChanged`, `modifyValue`,
--- `modifyOutput`, `showInfo`, `affectReproduction` and `collectTransmissionSources` dereference
--- `self.type` unguarded. Do NOT add nil-type tolerance to any of them; the one pre-existing
--- guard, in `RLAnimalInfoService.buildDiseaseRows`, is now dead against these paths rather than
--- load-bearing. Note "retained" rather than "exists": both stream paths deliberately CONSTRUCT a
--- nil-type record and read it off the wire before discarding it, because the bytes have to leave
--- the stream either way.
---
--- The reachable producer is a savegame or a join snapshot naming a title the registry has since
--- lost - a disease renamed or removed between sessions. Refusing the record costs the animal its
--- immunity window, its `genes` and its `isCarrier` state, and because `Animal:getHasAnyDisease`
--- then reads it as healthy it also changes what a herdsman rule bound to the saved-filter
--- `hasAnyDisease` field does with that animal. The alternative is a save that RAISES on the next
--- write, because `Disease:saveToXMLFile` opens with `self.type.title`.
---
--- A migration that RENAMES a title must install its old-to-new mapping AHEAD of this call: the
--- record is discarded here, inside the codec, before any consumer could map it.
---
--- WARNING rather than ERROR: the load continues, the animal's other records survive, and the
--- audience is a player or a server admin rather than a developer.
---
--- Deliberately does NOT validate the definition file itself. A malformed definition is authored
--- inside the mod archive and reaches its author on the first run.
---@param title string|nil the title as it was persisted or transmitted
---@param identity table|nil whatever the calling path can actually name - farmId, uniqueId,
--- subTypeIndex, context - rendered verbatim into the warning. A path holding none of them passes
--- nil rather than inventing a field it does not have. Callers `tostring` their values on the way
--- in, so an absent field renders as nil rather than vanishing from the line.
---@return table|nil the registry's own type table, or nil when the record must be dropped. NEVER
--- `false`: both stream call sites fold the result through an `and`/`or` chain that would turn a
--- false into nil, so the two outcomes must stay distinguishable by nilness alone.
function DiseaseManager:resolveRecordType(title, identity)

    if title == nil or title == "" then

        Log:warning("resolveRecordType: dropping a disease record, reason=no title (title=%s %s)",
            tostring(title), formatIdentity(identity))

        return nil

    end

    local diseaseType = self:getDiseaseByTitle(title)

    if diseaseType == nil then

        Log:warning("resolveRecordType: dropping a disease record, reason=title is not a defined disease (title=%s %s)",
            tostring(title), formatIdentity(identity))

        return nil

    end

    -- No line on the RESOLVED path, deliberately. Lua evaluates a log call's arguments before the
    -- logger tests the level, so a trace here would render the identity - a table walk, a sort and
    -- a concat - for every record of every animal on every savegame load and every join, at every
    -- level including production INFO. The two refusal arms above are where the diagnosis lives.
    return diseaseType

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
--- not just the transmission pass. `type` is read unguarded on purpose: the reachable
--- producer of a nil one - a savegame or a join snapshot naming a title the registry no
--- longer carries - is refused at the reconstruction paths instead, so no record here can
--- carry one.
--- @see DiseaseManager.resolveRecordType
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