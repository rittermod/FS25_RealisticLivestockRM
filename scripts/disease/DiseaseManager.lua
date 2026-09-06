--[[
    DiseaseManager.lua
    The disease registry: loads `xml/diseases.xml` through `RLDiseaseDefinition`, keeps
    the title-keyed model map, and resolves a persisted or transmitted title back to it.

    Four of its behaviour methods are SWITCHED OFF for the SEIR switchover and refuse
    unconditionally rather than keying on `diseasesEnabled`, and `collectTransmissionSources`
    is inert with no production caller. The slice that re-arms the transmission pass must
    ADD a guard rather than restore one.
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


--- Refuse the daily spontaneous-infection roll: the legacy engine is switched off, so no
--- animal contracts a new disease from this path. Its `math.random` draw is gone with it.
---
--- Unconditional rather than keyed on `diseasesEnabled`, so it keeps holding once
--- something turns the setting back on.
---@param animal table The animal that would have rolled. Read for log identity only.
function DiseaseManager:onDayChanged(animal)

	Log:trace("DiseaseManager:onDayChanged: refused, reason=legacy engine off (farmId=%s uniqueId=%s)",
		tostring(animal and animal.farmId or nil), tostring(animal and animal.uniqueId or nil))

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
--- THE ONLY ENTRY POINT to the transmission pass, called once per pen from the period
--- tick, ABOVE that tick's per-animal progression loop.
---
--- NOTHING ON THIS PATH READS THE PLAYER'S DISEASE SETTING ANY MORE, and what makes that
--- safe is that this body is a STUB rather than that the setting is unreachable, so the
--- slice that re-arms the pass must ADD a guard here rather than restore one.
--- @see RLSettings.applyChange
---@param animals table the pen's animals. Unread while the engine is off.
---@param penName string|nil the husbandry's display name, for log attribution only
function DiseaseManager:calculateTransmission(animals, penName)

	Log:trace("calculateTransmission [%s]: refused, reason=legacy engine off", tostring(penName))

end


function DiseaseManager.onSettingChanged(name, state)

	if g_diseaseManager ~= nil then g_diseaseManager[name] = state end

end
