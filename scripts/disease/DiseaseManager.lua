--[[
    DiseaseManager.lua
    The disease registry: loads `xml/diseases.xml` through `RLDiseaseDefinition`, keeps
    the title-keyed model map, and resolves a persisted or transmitted title back to it.

    `onDayChanged` rolls spontaneous infection per animal per tick against the authored
    per-month curve. `calculateTransmission` COMPUTES a pen's spread plan through
    `RLDiseaseSpread` and constructs nothing: the pen calls it above its progression loop
    and applies the plan below it through `contractDisease`, the one applier both
    producers share. A genetic record has its own applier, `contractGenetic`, reached by
    the dealer seeding in `setGeneticDiseasesForSaleAnimal` and by inheritance at conception.

    The active difficulty preset (`diseaseDifficulty`, stored by `onDifficultyChanged` on every
    peer) scales the roll, the seed and the spread entries; `diseasesEnabled` is derived from it.
]]

DiseaseManager = {}

local modDirectory = g_currentModDirectory
local diseaseManager_mt = Class(DiseaseManager)

local Log = RmLogging.getLogger("RLRM")

--- Construct the manager and load the disease registry into it.
---@return table
function DiseaseManager.new()

    local self = setmetatable({}, diseaseManager_mt)

	-- Initialised ABOVE the loader call: an init placed below it would clobber the
	-- parsed registry with an empty one, and no test would see it. A title-keyed MAP,
	-- not an array, so `#` on it is always 0.
	self.diseases = {}
	self.diseasesEnabled = true
    self.diseaseDifficulty = RLDiseaseDifficulty.DEFAULT_INDEX

	self:loadDiseases()

    Log:debug("DiseaseManager.new: constructed with preset %s, diseasesEnabled=%s",
        tostring(self.diseaseDifficulty), tostring(self.diseasesEnabled))

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


-- Keyed on the registry TABLE like `getSortedTitles`, and on the preset. Each entry carries the
-- EFFECTIVE window a record seeded under the active preset serves, so the priced R0 holds.
--- The spread pass's per-title entries under the active preset, rebuilt when the registry or the preset changes.
---@return table entries title -> `{ model, maxLifespanMonths, incubationTicks }`; the manager's own, do not mutate
function DiseaseManager:getSpreadEntries()

    if self.spreadEntriesFor == self.diseases and self.spreadEntriesPreset == self.diseaseDifficulty then
        return self.spreadEntries
    end

    local preset = RLDiseaseDifficulty.getPreset(self.diseaseDifficulty)

    local entries = {}
    local count = 0

    for title, model in pairs(self.diseases) do

        -- The lifespan is the DISEASE-level bound (the shortest-lived affected species),
        -- never an animal's own span. Genetic titles ride along and are never priced.
        entries[title] = {
            ["model"] = RLDiseaseDifficulty.spreadModel(model, preset.spread),
            ["maxLifespanMonths"] = RLDiseaseTransmission.diseaseLifespanMonths(model.animals),
            ["incubationTicks"] = RLDiseaseDifficulty.effectiveIncubationTicks(model.incubationTicks,
                preset.incubation)
        }

        count = count + 1

    end

    self.spreadEntries = entries
    self.spreadEntriesFor = self.diseases
    self.spreadEntriesPreset = self.diseaseDifficulty

    Log:debug("getSpreadEntries: rebuilt the spread entries (%s title(s), preset=%s spread=%s incubation=%s)",
        tostring(count), tostring(preset.key), tostring(preset.spread), tostring(preset.incubation))

    return entries

end


-- Authored per MONTH, rolled per TICK, so lifetime risk no longer moves with days-per-month.
-- Titles are walked SORTED: the registry is a title-keyed map and draw order is an outcome.
--- Roll spontaneous infection for one animal against every disease it is eligible for.
---@param animal table the animal rolling; mutated only through `Animal:addDisease` on a hit
---@param ctx table `{ daysPerPeriod, rng }`, built by each call site; `rng` returns `[0, 1)` and
--- defaults to `math.random`. A nil `daysPerPeriod` raises on the conversion, deliberately.
---@return nil
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

    -- Resolved ONCE per call and reused for every log argument below.
    local preset = RLDiseaseDifficulty.getPreset(self.diseaseDifficulty)

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

                    -- The preset scales the MONTHLY chance; the per-tick conversion runs last.
                    local scaled = RLDiseaseDifficulty.scaleInfectionChance(pMonth, preset.infection)

                    if not (scaled > 0) then

                        Log:trace("DiseaseManager:onDayChanged: skipped title=%s, reason=the preset scaled the "
                            .. "chance to 0 (preset=%s pMonth=%s uniqueId=%s)", tostring(title),
                            tostring(preset.key), tostring(pMonth), tostring(animal.uniqueId))

                    else

                        local pTick = RLDiseaseRates.perTick(scaled, ctx.daysPerPeriod)

                        -- Eligibility runs BEFORE the draw, so a refused animal consumes no
                        -- randomness and the draw budget is a pure function of the collection.
                        -- STRICTLY below, never at, which makes a rate of 0 never fire.
                        local draw = rng()

                        if draw < pTick then

                            Log:debug("DiseaseManager:onDayChanged: CONTRACTED title=%s farmId=%s uniqueId=%s "
                                .. "ageMonths=%s pMonth=%s preset=%s scaledPMonth=%s pTick=%s daysPerPeriod=%s "
                                .. "draw=%s", tostring(title), tostring(animal.farmId), tostring(animal.uniqueId),
                                tostring(ageMonths), tostring(pMonth), tostring(preset.key), tostring(scaled),
                                tostring(pTick), tostring(ctx.daysPerPeriod), tostring(draw))

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

end


-- The applier both producers share: the spontaneous roll and the pen's transmission apply.
-- One branch key, the EFFECTIVE window: a positive one is seeded, a zero one (an authored 0 or a zero preset
-- scale) goes straight to INFECTIOUS and is announced here. Fail-loud, no rollback - `addDisease` already inserted.
--- Attach a fresh record in the active preset's starting state, announcing it only when it starts symptomatic.
---@param animal table the animal that just contracted the disease
---@param model table the parsed `<model>` entry it contracted
---@return nil
function DiseaseManager:contractDisease(animal, model)

    animal:addDisease(model)

    local record = animal:getDisease(model.title)

    if record == nil then

        Log:warning("contractDisease: no record immediately after addDisease (title=%s farmId=%s uniqueId=%s)",
            tostring(model.title), tostring(animal.farmId), tostring(animal.uniqueId))

        return

    end

    local preset = RLDiseaseDifficulty.getPreset(self.diseaseDifficulty)
    local ticks = RLDiseaseDifficulty.effectiveIncubationTicks(model.incubationTicks, preset.incubation)

    if ticks > 0 then

        local outcome = RLDiseaseRecord.seedIncubation(record, ticks)

        if outcome ~= RLDiseaseRecord.APPLIED then

            Log:warning("contractDisease: seedIncubation returned %s, the window stays zero (title=%s "
                .. "ticks=%s preset=%s farmId=%s uniqueId=%s)", tostring(outcome), tostring(model.title),
                tostring(ticks), tostring(preset.key), tostring(animal.farmId), tostring(animal.uniqueId))

            return

        end

        Log:trace("contractDisease: seeded a %s-tick hidden window (authored %s, preset=%s, title=%s uniqueId=%s)",
            tostring(record.incubationTicksRemaining), tostring(model.incubationTicks), tostring(preset.key),
            tostring(model.title), tostring(animal.uniqueId))

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

    -- The tick announces at symptom onset, but this transition happens inside the roll or the
    -- transmission apply, both after progression, so no tick sees it and it is announced here.
    animal:addMessage("DISEASE_CONTRACTED", { model.name })

    Log:debug("contractDisease: zero effective incubation (authored %s, preset=%s), symptomatic and announced "
        .. "at once (title=%s farmId=%s uniqueId=%s)", tostring(model.incubationTicks), tostring(preset.key),
        tostring(model.title), tostring(animal.farmId), tostring(animal.uniqueId))

end


-- The one applier for a genetic record: a carrier keeps the EXPOSED `Disease.new` builds, an affected
-- record moves to INFECTIOUS at once. Neither is announced, and `addDisease` already flagged the animal.
--- Attach a genetic record: a carrier at EXPOSED for life, an affected animal at INFECTIOUS.
---@param animal table the animal receiving the record
---@param model table the genetic disease's parsed model entry
---@param genes number copies held, 1 or 2
---@param isCarrier boolean true for a single recessive copy
function DiseaseManager:contractGenetic(animal, model, genes, isCarrier)

    animal:addDisease(model, isCarrier, genes)

    if not isCarrier then

        local outcome = RLDiseaseRecord.transition(animal:getDisease(model.title),
            RLDiseaseRecord.STATE.INFECTIOUS)

        -- Fail-loud with no rollback, like `contractDisease`'s zero-incubation arm.
        if outcome ~= RLDiseaseRecord.APPLIED then

            Log:warning("contractGenetic: the affected transition returned %s, the record stays EXPOSED "
                .. "(title=%s genes=%s farmId=%s uniqueId=%s)", tostring(outcome), tostring(model.title),
                tostring(genes), tostring(animal.farmId), tostring(animal.uniqueId))

            return

        end

    end

    Log:debug("contractGenetic: title=%s genes=%s carrier=%s farmId=%s uniqueId=%s",
        tostring(model.title), tostring(genes), tostring(isCarrier), tostring(animal.farmId),
        tostring(animal.uniqueId))

end


-- The spontaneous roll's three guards, in its order. Only `createNewSaleAnimal` calls this, so an AI
-- stud is never seeded. Titles walk SORTED, and a refused title consumes no draw.
--- Seed a freshly generated sale animal with each genetic disease its type can carry, at the authored chance.
---@param animal table the sale animal `createNewSaleAnimal` just built
function DiseaseManager:setGeneticDiseasesForSaleAnimal(animal)

    if g_server == nil then
        Log:trace("DiseaseManager:setGeneticDiseasesForSaleAnimal: refused, reason=not the authority (uniqueId=%s)",
            tostring(animal.uniqueId))
        return
    end

    if not self.diseasesEnabled then
        Log:trace("DiseaseManager:setGeneticDiseasesForSaleAnimal: refused, reason=diseases disabled (uniqueId=%s)",
            tostring(animal.uniqueId))
        return
    end

    if RealisticLivestock.testAnimalPrefix ~= nil then
        Log:trace("DiseaseManager:setGeneticDiseasesForSaleAnimal: refused, reason=test-prefix run (uniqueId=%s)",
            tostring(animal.uniqueId))
        return
    end

    local typeName = resolveAnimalTypeName(animal)

    for _, title in ipairs(self:getSortedTitles()) do

        local model = self.diseases[title]

        if model.archetype ~= "genetic" then

            Log:trace("DiseaseManager:setGeneticDiseasesForSaleAnimal: skipped title=%s, reason=not genetic "
                .. "(uniqueId=%s)", tostring(title), tostring(animal.uniqueId))

        else

            -- Fail CLOSED on an unresolvable type, exactly as the spontaneous roll does.
            local bound = false

            if typeName ~= nil then
                for i = 1, #model.animals do
                    if model.animals[i] == typeName then
                        bound = true
                        break
                    end
                end
            end

            if not bound then

                Log:trace("DiseaseManager:setGeneticDiseasesForSaleAnimal: skipped title=%s, reason=type not "
                    .. "affected (type=%s uniqueId=%s)", tostring(title), tostring(typeName),
                    tostring(animal.uniqueId))

            elseif animal:getDisease(title) ~= nil then

                Log:trace("DiseaseManager:setGeneticDiseasesForSaleAnimal: skipped title=%s, reason=holds a "
                    .. "record (uniqueId=%s)", tostring(title), tostring(animal.uniqueId))

            else

                local genes, isCarrier = RLDiseaseGenetics.seedForSale(model.genetic)

                if genes == nil then

                    Log:trace("DiseaseManager:setGeneticDiseasesForSaleAnimal: missed title=%s (uniqueId=%s)",
                        tostring(title), tostring(animal.uniqueId))

                else

                    Log:debug("DiseaseManager:setGeneticDiseasesForSaleAnimal: SEEDED title=%s genes=%s "
                        .. "carrier=%s farmId=%s uniqueId=%s", tostring(title), tostring(genes),
                        tostring(isCarrier), tostring(animal.farmId), tostring(animal.uniqueId))

                    self:contractGenetic(animal, model, genes, isCarrier)

                end

            end

        end

    end

end


-- The pass READS here, above the pen's progression loop; the pen applies the plan below it.
-- Every path returns `plan`'s two values - the refusals through `plan(animals, nil)` - so the
-- pen reads nil as "the compute did not return", never as "nothing to infect".
--- Compute one pen's transmission plan for this tick. Constructs nothing.
--- @see RLSettings.applyChange
---@param animals table the pen's animals, as the progression loop walks them
---@param penName string|nil the husbandry's display name, for log attribution only
---@param ctx table REQUIRED `{ daysPerPeriod, rng }`; `rng` is a test seam defaulting to `math.random`
---@return table infections `{ animal, title }` entries in animal-major, title-sorted order
---@return table stats the spread pass's seven-field stats table, forwarded unchanged
function DiseaseManager:calculateTransmission(animals, penName, ctx)

    if g_server == nil then

        Log:trace("calculateTransmission [%s]: refused, reason=not the authority", tostring(penName))

        return RLDiseaseSpread.plan(animals, nil)

    end

    if not self.diseasesEnabled then

        Log:trace("calculateTransmission [%s]: refused, reason=diseases disabled", tostring(penName))

        return RLDiseaseSpread.plan(animals, nil)

    end

    local infections, stats = RLDiseaseSpread.plan(animals, {
        ["diseases"] = self:getSpreadEntries(),
        ["daysPerPeriod"] = ctx.daysPerPeriod,
        ["rng"] = ctx.rng
    })

    local shedTitles = {}

    for title in pairs(stats.shedders) do shedTitles[#shedTitles + 1] = title end

    table.sort(shedTitles)

    local shedders, saturated = {}, {}

    for _, title in ipairs(shedTitles) do

        shedders[#shedders + 1] = string.format("%s=%s", tostring(title), tostring(stats.shedders[title]))

        -- A clamped monthly rate of exactly 1 is the saturation tell the per-tick rate cannot give.
        if stats.monthly[title] == 1 then saturated[#saturated + 1] = tostring(title) end

    end

    if #shedTitles > 0 then

        Log:debug("calculateTransmission [%s]: population=%s shedders=[%s] rolls=%s planned=%s saturated=[%s]",
            tostring(penName), tostring(stats.population), table.concat(shedders, " "),
            tostring(stats.rolls), tostring(#infections), table.concat(saturated, " "))

    else

        Log:trace("calculateTransmission [%s]: population=%s, nothing shedding - empty plan",
            tostring(penName), tostring(stats.population))

    end

    return infections, stats

end


-- Runs on EVERY peer, from the settings full-set, a single-row change and applyDefaultSettings,
-- often inside an unprotected loop over every row - so it must never raise, and it neither
-- persists nor broadcasts. An invalid value resolves to Normal.
--- Settings callback for the `diseaseDifficulty` row: store the preset and derive `diseasesEnabled` from it.
---@param name string the setting key, for log attribution only
---@param value any the preset index the row's values carry; never raises for any input
---@return nil
function DiseaseManager.onDifficultyChanged(name, value)

    if g_diseaseManager == nil then

        Log:trace("DiseaseManager.onDifficultyChanged: no manager yet, nothing to derive (name=%s value=%s)",
            tostring(name), tostring(value))

        return

    end

    local preset = RLDiseaseDifficulty.getPreset(value)

    g_diseaseManager.diseaseDifficulty = value
    g_diseaseManager.diseasesEnabled = RLDiseaseDifficulty.isEnabled(value)

    Log:debug("DiseaseManager.onDifficultyChanged: %s=%s -> preset=%s diseasesEnabled=%s",
        tostring(name), tostring(value), tostring(preset.key), tostring(g_diseaseManager.diseasesEnabled))

end
