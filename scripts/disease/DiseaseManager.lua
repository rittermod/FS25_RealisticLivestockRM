--[[
    DiseaseManager.lua
    The disease registry: loads `xml/diseases.xml` through `RLDiseaseDefinition`, keeps
    the title-keyed model map, and resolves a persisted or transmitted title back to it.

    `onDayChanged` is LIVE: it rolls spontaneous infection per animal per tick against the
    authored per-month curve and constructs the record. `setGeneticDiseasesForSaleAnimal`
    and `calculateTransmission` are still SWITCHED OFF and refuse unconditionally rather
    than keying on `diseasesEnabled`, and `collectTransmissionSources` is inert with no
    production caller. The slice that re-arms the transmission pass must ADD a guard rather
    than restore one.
]]

DiseaseManager = {}

local modDirectory = g_currentModDirectory
local diseaseManager_mt = Class(DiseaseManager)

local Log = RmLogging.getLogger("RLRM")

function DiseaseManager.new()

    local self = setmetatable({}, diseaseManager_mt)

	-- Initialised ABOVE the loader call: an init placed below it would clobber the
	-- parsed registry with an empty one, and no test would see it. A title-keyed MAP,
	-- not an array, so `#` on it is always 0.
	self.diseases = {}
	self.diseasesEnabled = true
	self.diseasesChance = 1

	self:loadDiseases()

	return self

end


--- Load the disease definition file into the registry.
---
--- The SINGLE emission point for the parser's authoring warnings: the parse RETURNS
--- them rather than logging them, so each rule stays assertable without a logger spy.
---@return nil
function DiseaseManager:loadDiseases()

    -- Deliberately NO pcall around parse: its contract is that it does not raise for
    -- any input, so a raise here is a wiring bug that must crash loudly rather than be
    -- swallowed into a silently empty registry. A nil xmlFile is handed straight to it
    -- because the absent-file case is one of parse's own warning rules.
    local xmlFile = XMLFile.loadIfExists("diseases", modDirectory .. "xml/diseases.xml")

    local registry, warnings = RLDiseaseDefinition.parse(xmlFile, {
        ["animalTypes"] = AnimalType,
        ["i18n"] = g_i18n
    })

    self.diseases = registry

    -- Every value goes through %s + tostring(): the headless harness formats bare and
    -- RAISES where the in-game logger degrades, so a typed specifier here would turn a
    -- malformed-input warning into a suite crash on one runner only.
    for _, authoringWarning in ipairs(warnings) do
        Log:warning("loadDiseases: %s (disease=%s) - %s",
            tostring(authoringWarning.rule),
            tostring(authoringWarning.title),
            tostring(authoringWarning.detail))
    end

    -- Counted by WALKING, never with `#`: the registry is a title-keyed map, so a
    -- length here would report every load as empty.
    local diseaseCount = 0
    local titles = {}

    for title in pairs(registry) do
        diseaseCount = diseaseCount + 1
        table.insert(titles, title)
    end

    -- Sorted at BOTH levels: `pairs` order is undefined, so an unsorted walk names the
    -- same diseases and channels in a different order on every load, defeating a grep
    -- across two logs and making any ordered log pin flaky.
    table.sort(titles)

    for _, title in ipairs(titles) do

        local model = registry[title]

        if model.carrier ~= nil and next(model.carrier.output) ~= nil then

            local channels = {}

            -- %.6g, not tostring: the engine reads these as 32-bit floats, so tostring
            -- renders 0.35 as 0.3499999940395355 in-game and 0.35 headless.
            for channel, modifier in pairs(model.carrier.output) do
                table.insert(channels, string.format("%s=%.6g", tostring(channel), modifier))
            end

            table.sort(channels)

            Log:debug("loadDiseases: %s carrier output modifiers loaded (%s)",
                tostring(title), table.concat(channels, " "))

        end

    end

    -- One count, not two: a disease is in the registry only if its model built.
    Log:info("loadDiseases: %s disease(s) defined, %s authoring warning(s)",
        tostring(diseaseCount), tostring(#warnings))

    if xmlFile ~= nil then xmlFile:delete() end

end


--- Resolve a title to its registry entry.
---
--- Returns the registry's own entry table, or nil - never `false`. A nil or empty title
--- is a legal read that returns nil, which is what lets `resolveRecordType`'s guard
--- above it keep working unchanged.
---@param title string|nil the title as persisted, transmitted or authored
---@return table|nil the registry entry, or nil when the title is not defined
function DiseaseManager:getDiseaseByTitle(title)

	return self.diseases[title]

end


--- Render a caller-supplied identity table as a stable "key=value" list for a warning line.
---
--- TOTAL by construction rather than defensive: this renders a WARNING's argument, so a
--- raise here would turn a benign dropped record into an aborted stream read. The sort
--- keys through `tostring` because `table.sort` raises on a mixed-type key set.
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


--- Resolve a persisted or transmitted disease title to its registry entry, refusing any
--- title the shipped definition file no longer carries.
---
--- Every reconstruction path routes through here, so no `Disease` carrying a nil model is
--- ever RETAINED - which is what lets the codecs and the behaviour methods dereference it
--- unguarded. Do NOT add tolerance to any of them. A migration that RENAMES a title must
--- install its old-to-new mapping AHEAD of this call, because the record is discarded
--- here, inside the codec, before any consumer could map it.
---@param title string|nil the title as it was persisted or transmitted
---@param identity table|nil whatever the calling path can actually name - farmId, uniqueId,
--- subTypeIndex, context - rendered verbatim into the warning. A path holding none of them
--- passes nil rather than inventing a field it does not have.
---@return table|nil the registry's own entry table, or nil when the record must be dropped.
--- NEVER `false`: the two outcomes must stay distinguishable by nilness alone.
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

    -- No line on the RESOLVED path, deliberately: Lua evaluates a log call's arguments
    -- before the level is tested, so a trace here would render the identity - a table
    -- walk, a sort and a concat - for every record of every animal on every load and
    -- every join, at every level including production INFO.
    return diseaseType

end


-- `ageMonths` on a key is the TOP of its band: the first key not exceeded wins, the last is the
-- catch-all. A one-key model reads the same under the floor reading, so only a multi-key one
-- separates them. An empty list answers 0 explicitly - `{}` walks like any other table.
--- Resolve the authored per-month infection chance at an age.
---@param infection table|nil ARRAY of `{ ageMonths, perMonth }` in document order; trusted internal
---@param ageMonths number the animal's integer month count
---@return number perMonth the authored probability, and 0 when the model authors no key
local function infectionChanceFor(infection, ageMonths)

    if type(infection) ~= "table" or #infection == 0 then

        Log:trace("infectionChanceFor: no authored <infection> key, chance is 0 (ageMonths=%s)",
            tostring(ageMonths))

        return 0

    end

    for i = 1, #infection do
        if ageMonths <= infection[i].ageMonths then return infection[i].perMonth end
    end

    return infection[#infection].perMonth

end


-- Keyed on the TYPE index, so a goat resolves to SHEEP.
--- Resolve an animal's uppercase type name, the key `model.animals` is written in.
---@param animal table the animal being rolled
---@return string|nil typeName uppercase type name, nil when the registry cannot answer
local function resolveAnimalTypeName(animal)

    -- Ordered: `Animal:getSubType` indexes `animalSystem` itself, so testing it after the
    -- call would raise instead of refusing.
    local animalSystem = g_currentMission ~= nil and g_currentMission.animalSystem or nil

    if animalSystem == nil or animalSystem.typeIndexToName == nil then
        Log:trace("resolveAnimalTypeName: no animal-type registry, cannot resolve (uniqueId=%s)",
            tostring(animal.uniqueId))
        return nil
    end

    local subType = animal.getSubType ~= nil and animal:getSubType() or nil

    if subType == nil then
        Log:trace("resolveAnimalTypeName: animal answers no subType (uniqueId=%s)",
            tostring(animal.uniqueId))
        return nil
    end

    return animalSystem.typeIndexToName[subType.typeIndex]

end


-- Keyed on the registry TABLE, not a dirty flag: `loadDiseases` replaces the table, and so does
-- a suite swapping in a probe registry, so identity catches both without either having to know.
--- The registry's titles in sorted order, rebuilt only when the registry table changes.
---@return table titles a sorted array of title strings; the manager's own, do not mutate
function DiseaseManager:getSortedTitles()

    if self.sortedTitlesFor == self.diseases then return self.sortedTitles end

    local titles = {}

    for title in pairs(self.diseases) do titles[#titles + 1] = title end

    table.sort(titles)

    self.sortedTitles = titles
    self.sortedTitlesFor = self.diseases

    Log:trace("getSortedTitles: rebuilt the sorted walk for a new registry (%d title(s))", #titles)

    return titles

end


-- Authored per MONTH, rolled per TICK, so lifetime risk no longer moves with days-per-month.
-- Titles are walked SORTED: the registry is a title-keyed map and draw order is an outcome.
--- Roll spontaneous infection for one animal against every disease it is eligible for.
---@param animal table the animal rolling; mutated only through `Animal:addDisease` on a hit
---@param ctx table `{ daysPerPeriod, rng }`, built by each call site; `rng` returns `[0, 1)` and
--- defaults to `math.random`. A nil `daysPerPeriod` raises on the conversion, deliberately.
function DiseaseManager:onDayChanged(animal, ctx)

    -- No call site is contractually server-only, so the authority guard lives here
    -- rather than at the callers.
    if g_server == nil then

        Log:trace("DiseaseManager:onDayChanged: refused, reason=not the authority (uniqueId=%s)",
            tostring(animal.uniqueId))

        return

    end

    if not self.diseasesEnabled then

        Log:trace("DiseaseManager:onDayChanged: refused, reason=diseases disabled (uniqueId=%s)",
            tostring(animal.uniqueId))

        return

    end

    -- ONE evaluation bound to a local, mirroring the pen's transmission gate, so an rlTest run
    -- does not infect its own fixture animals.
    local testPrefix = RealisticLivestock.testAnimalPrefix

    if testPrefix ~= nil then

        Log:trace("DiseaseManager:onDayChanged: refused, reason=test-prefix run (uniqueId=%s)",
            tostring(animal.uniqueId))

        return

    end

    if animal.numAnimals <= 0 or animal.isDead then

        Log:trace("DiseaseManager:onDayChanged: refused, reason=not a live animal (uniqueId=%s dead=%s count=%s)",
            tostring(animal.uniqueId), tostring(animal.isDead), tostring(animal.numAnimals))

        return

    end

    local titles = self:getSortedTitles()

    local ageMonths = animal.age
    local typeName = resolveAnimalTypeName(animal)
    local rng = ctx.rng or math.random

    for _, title in ipairs(titles) do

        local model = self.diseases[title]

        -- Every archetype is admitted except `genetic`, whose records belong to the genetics
        -- slice. An unrecognised one rides along: the parser owns that vocabulary's warning.
        if model.archetype == "genetic" then

            Log:trace("DiseaseManager:onDayChanged: skipped title=%s, reason=genetic archetype (uniqueId=%s)",
                tostring(title), tostring(animal.uniqueId))

        else

            -- Fail CLOSED on an unresolvable type, the opposite direction from `isAdherent`:
            -- there a skip protects an existing herd's records, here refusing only declines to
            -- create a new one.
            local bound = false

            if typeName ~= nil then
                for i = 1, #model.animals do
                    if model.animals[i] == typeName then
                        bound = true
                        break
                    end
                end
            end

            local eligible, reason

            if bound then eligible, reason = RLDiseaseSpread.isEligible(animal, title, model) end

            if not bound then

                Log:trace("DiseaseManager:onDayChanged: skipped title=%s, reason=type not affected "
                    .. "(type=%s uniqueId=%s)", tostring(title), tostring(typeName), tostring(animal.uniqueId))

            elseif not eligible then

                -- Alive, holds no record of this title in ANY state - which is where immunity
                -- lives - and every prerequisite matches. Reused rather than re-answered.
                Log:trace("DiseaseManager:onDayChanged: skipped title=%s, reason=%s (uniqueId=%s)",
                    tostring(title), tostring(reason), tostring(animal.uniqueId))

            else

                local pMonth = infectionChanceFor(model.infection, ageMonths)

                -- The inverted comparison rejects zero, a negative and a NaN in one test.
                if not (pMonth > 0) then

                    Log:trace("DiseaseManager:onDayChanged: skipped title=%s, reason=no chance at this age "
                        .. "(ageMonths=%s pMonth=%s uniqueId=%s)", tostring(title), tostring(ageMonths),
                        tostring(pMonth), tostring(animal.uniqueId))

                else

                    local pTick = RLDiseaseRates.perTick(pMonth, ctx.daysPerPeriod)

                    -- Eligibility runs BEFORE the draw, so a refused animal consumes no
                    -- randomness and the draw budget is a pure function of the collection.
                    -- STRICTLY below, never at, which makes a rate of 0 never fire.
                    local draw = rng()

                    if draw < pTick then

                        Log:debug("DiseaseManager:onDayChanged: CONTRACTED title=%s farmId=%s uniqueId=%s "
                            .. "ageMonths=%s pMonth=%s pTick=%s daysPerPeriod=%s draw=%s",
                            tostring(title), tostring(animal.farmId), tostring(animal.uniqueId),
                            tostring(ageMonths), tostring(pMonth), tostring(pTick),
                            tostring(ctx.daysPerPeriod), tostring(draw))

                        self:contractDisease(animal, model)

                    else

                        Log:trace("DiseaseManager:onDayChanged: missed title=%s, draw=%s pTick=%s (uniqueId=%s)",
                            tostring(title), tostring(draw), tostring(pTick), tostring(animal.uniqueId))

                    end

                end

            end

        end

    end

end


-- `incubationTicksFor` floors at MIN_INCUBATION_TICKS, so the seeder cannot express zero: an
-- authored 0 transitions straight to INFECTIOUS. Fail-loud, no rollback - `addDisease` has
-- already flagged, inserted and messaged by the time this runs.
--- Attach a fresh record and put it into its authored starting state.
---@param animal table the animal that just contracted the disease
---@param model table the parsed `<model>` entry it contracted
function DiseaseManager:contractDisease(animal, model)

    animal:addDisease(model)

    local record = animal:getDisease(model.title)

    if record == nil then

        Log:warning("contractDisease: no record immediately after addDisease (title=%s farmId=%s uniqueId=%s)",
            tostring(model.title), tostring(animal.farmId), tostring(animal.uniqueId))

        return

    end

    if model.incubationTicks > 0 then

        local outcome = RLDiseaseRecord.seedIncubation(record, model.incubationTicks)

        if outcome ~= RLDiseaseRecord.APPLIED then

            Log:warning("contractDisease: seedIncubation returned %s, the window stays zero (title=%s "
                .. "ticks=%s farmId=%s uniqueId=%s)", tostring(outcome), tostring(model.title),
                tostring(model.incubationTicks), tostring(animal.farmId), tostring(animal.uniqueId))

            return

        end

        Log:trace("contractDisease: seeded a %s-tick hidden window (title=%s uniqueId=%s)",
            tostring(model.incubationTicks), tostring(model.title), tostring(animal.uniqueId))

        return

    end

    -- Transitions dirty; `Animal:addDisease` already flagged the animal at the top of this
    -- call, so the lock is satisfied without a second flush here.
    local outcome = RLDiseaseRecord.transition(record, RLDiseaseRecord.STATE.INFECTIOUS)

    if outcome ~= RLDiseaseRecord.APPLIED then

        Log:warning("contractDisease: the zero-incubation transition returned %s, the record stays EXPOSED "
            .. "(title=%s farmId=%s uniqueId=%s)", tostring(outcome), tostring(model.title),
            tostring(animal.farmId), tostring(animal.uniqueId))

        return

    end

    Log:trace("contractDisease: authored zero incubation, symptomatic at once (title=%s uniqueId=%s)",
        tostring(model.title), tostring(animal.uniqueId))

end


--- Refuse to seed a genetic record onto a freshly generated sale animal: the legacy
--- engine is switched off, so dealer stock carries no carrier and no `genes`.
---
--- This is the only one of the five refusals whose body had no `diseasesEnabled` guard,
--- so its draws ran even with the setting OFF. Removing them re-rolls every later draw in
--- sale-animal generation, so dealer stock differs from a pre-slice save at the same seed.
--- That is expected, not a defect.
---@param animal table The sale animal that would have been seeded. Read for log identity only.
function DiseaseManager:setGeneticDiseasesForSaleAnimal(animal)

	Log:trace("DiseaseManager:setGeneticDiseasesForSaleAnimal: refused, reason=legacy engine off (uniqueId=%s)",
		tostring(animal and animal.uniqueId or nil))

end


--- Collect the contagious disease sources across a pen.
---
--- INERT, and with NO production caller: the gate it applies per record reads a key the
--- shipped model entry does not carry, so it returns an empty source set for any input.
--- The slice that wires spread replaces the whole body with a delegation to
--- `RLDiseaseSpread` rather than re-answering the shedding question here.
---
--- Call it with the DOT form. DiseaseManager carries a `Class()` metatable, so a colon
--- call passes the manager itself as `animals` and the walk RAISES on `animal.isDead`.
--- @see RLFilterFieldCatalog.FIELDS hasAnyDisease
--- @see Animal.getHasAnyDisease
--- @see DiseaseManager.resolveRecordType
---
---@param animals table|nil the pen's animals; nil yields no sources rather than raising
---@return table sources keyed by disease title -> { type = <model entry>, amount = <integer> }; ALWAYS a table, and ALWAYS empty while the gate below is unsatisfiable
---@return boolean hasSources true when at least one record was counted; always false today
---@return table stats { curedSkipped, deadSkipped, animals }. The two skip counters are
--- DIFFERENT UNITS: `curedSkipped` counts RECORDS and `deadSkipped` counts ANIMALS,
--- because a corpse is skipped whole before its records are read. `curedSkipped` can no
--- longer move at all, so it reports a real zero.
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

			local model = disease.model

			-- THIS GATE NOW SHORT-CIRCUITS EVERY RECORD: a model entry carries its
			-- authored spread figure under a different name and no `transmission` key at
			-- all, so the walk reaches this `continue` for every record.
			if model.transmission == nil or model.transmission <= 0 then continue end

			-- Reads NO record field beyond the title, deliberately: deciding what sheds
			-- is the spread module's contract, and answering it a second time here would
			-- make this a sixth predicate over the same records.
			if sources[disease.title] == nil then
				sources[disease.title] = { ["type"] = model, ["amount"] = 0 }
				hasSources = true
			end

			sources[disease.title].amount = sources[disease.title].amount + 1

		end

	end

	return sources, hasSources, stats

end


--- Refuse one pen's transmission pass: the legacy engine is switched off, so no animal
--- catches anything from a pen mate until the SEIR spread pass lands.
---
--- THE ONLY ENTRY POINT to the transmission pass, called once per pen from the DAILY
--- tick, ABOVE that tick's per-animal progression loop.
---
--- This body reads no setting. The pen's own `diseasesEnabled` gate is what stops the
--- call, so a second entry point here would walk straight past it.
--- @see RLSettings.applyChange
---@param animals table the pen's animals. Unread while the engine is off.
---@param penName string|nil the husbandry's display name, for log attribution only
function DiseaseManager:calculateTransmission(animals, penName)

	Log:trace("calculateTransmission [%s]: refused, reason=legacy engine off", tostring(penName))

end


function DiseaseManager.onSettingChanged(name, state)

	if g_diseaseManager ~= nil then g_diseaseManager[name] = state end

end
