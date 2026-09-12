--[[
    Disease.lua
    One animal's disease record as a live object: the eight SEIR record keys grafted
    FLAT onto it, plus the treatment-running flag and the two genetics markers, with
    both codecs and the player-facing labels.

    Progression is LIVE and runs off the pen's daily tick, deciding through
    `RLDiseaseProgression` and applying nothing itself. The two remaining legacy
    behaviour methods - reproduction and sale value - still refuse unconditionally
    rather than keying on `diseasesEnabled`, so they stay off even in a save with
    diseases switched on.
]]

Disease = {}

local disease_mt = Class(Disease)

local Log = RmLogging.getLogger("RLRM")


--- The persisted record-shape version, written by `saveToXMLFile` and read by the
--- save-load site that decides whether a stored record can be reconstructed at all.
---
--- ONE home for both halves, because they live in different files and must agree
--- exactly. Absent means 1 - the legacy shape - and there is deliberately no mapping
--- from it: a legacy record is dropped, not migrated.
Disease.RECORD_VERSION = 2

--- Build a disease record attached to one animal.
---
--- The eight record keys are GRAFTED FLAT rather than nested under `self.record`,
--- because the spread pass and the sub-lethal resolver already read them flat off
--- `animal.diseases`. The ninth key, the treatment running flag, is assigned here
--- because a paused and a running course are otherwise indistinguishable.
---@param model table A parsed disease model entry, carrying `title`, `archetype` and `endpoint`.
---@param isCarrier boolean|nil True for an asymptomatic genetic carrier record.
---@param genes number|nil Count of affected genes inherited, 0 when not genetic.
---@return table disease A record at EXPOSED with its counters at zero. A nil `model`
---        RAISES, deliberately: neither reader can produce one, so a tolerance branch
---        would be dead code hiding a wiring fault behind a silent nil.
function Disease.new(model, isCarrier, genes)

	local self = setmetatable(RLDiseaseRecord.new(model, model.title), disease_mt)

	-- The ONLY registry reference, and there is deliberately no `self.type`: both names
	-- would describe the same table now that the entry is a model entry.
	self.model = model

	self.treatmentRunning = false

	-- Genetics-system markers rather than SEIR state. Nothing in the SEIR pipeline reads
	-- either; they persist and stream so the genetics slice inherits them intact.
	self.isCarrier = isCarrier or false
	self.genes = genes or 0

	return self

end


--- Restore this record's state from a savegame.
---
--- Every read is attribute-KEYED and carries a default, so adding or dropping a field is
--- a non-event for a save written by another build. `title`, `archetype` and `endpoint`
--- are deliberately NOT read: all three come from the model the caller already resolved,
--- and a persisted copy can go stale against a re-authored model while the model cannot.
---@param xmlFile table An open XML document.
---@param key string This record's element key.
function Disease:loadFromXMLFile(xmlFile, key)

	self.state = xmlFile:getString(key .. "#state", RLDiseaseRecord.STATE.EXPOSED)
	self.incubationTicksRemaining = xmlFile:getInt(key .. "#incubationTicksRemaining", 0)
	-- FLOAT, all three: each is advanced by a fraction of a month per daily tick, so an
	-- integer slot would truncate at every save and every join.
	self.monthsElapsed = xmlFile:getFloat(key .. "#monthsElapsed", 0)
	self.treatmentMonthsRemaining = xmlFile:getFloat(key .. "#treatmentMonthsRemaining", 0)
	self.immunityMonthsRemaining = xmlFile:getFloat(key .. "#immunityMonthsRemaining", 0)
	self.treatmentRunning = xmlFile:getBool(key .. "#treatmentRunning", false)
	self.isCarrier = xmlFile:getBool(key .. "#isCarrier", false)
	self.genes = xmlFile:getInt(key .. "#genes", 0)

end


--- Persist this record.
---
--- `#version` is written UNCONDITIONALLY: the loader drops anything below 2, so a writer
--- that forgets it silently drops every record this build wrote, on the next load.
---@param xmlFile table An open XML document.
---@param key string This record's element key.
function Disease:saveToXMLFile(xmlFile, key)

	xmlFile:setString(key .. "#title", self.model.title)
	xmlFile:setInt(key .. "#version", Disease.RECORD_VERSION)
	xmlFile:setString(key .. "#state", self.state)
	xmlFile:setInt(key .. "#incubationTicksRemaining", self.incubationTicksRemaining)
	xmlFile:setFloat(key .. "#monthsElapsed", self.monthsElapsed)
	xmlFile:setFloat(key .. "#treatmentMonthsRemaining", self.treatmentMonthsRemaining)
	xmlFile:setFloat(key .. "#immunityMonthsRemaining", self.immunityMonthsRemaining)
	xmlFile:setBool(key .. "#treatmentRunning", self.treatmentRunning)
	xmlFile:setBool(key .. "#isCarrier", self.isCarrier)
	xmlFile:setInt(key .. "#genes", self.genes)

end


--- Write this record onto a network stream.
---
--- POSITIONAL, and the read half must stay its exact mirror - there is no key to
--- resynchronise on. THE TITLE IS WRITTEN HERE AND READ BY THE CALLER, which needs it to
--- resolve a model before it can construct this object at all. The state crosses as a
--- UInt8 ORDINAL read at CALL time, never aliased at file scope.
---@param streamId number Network stream handle.
---@param connection table Network connection.
function Disease:writeStream(streamId, connection)

	streamWriteString(streamId, self.model.title)
	streamWriteUInt8(streamId, RLDiseaseRecord.STATE_WIRE_ORDINAL[self.state])
	streamWriteUInt16(streamId, self.incubationTicksRemaining)
	streamWriteFloat32(streamId, self.monthsElapsed)
	streamWriteFloat32(streamId, self.treatmentMonthsRemaining)
	streamWriteFloat32(streamId, self.immunityMonthsRemaining)
	streamWriteBool(streamId, self.treatmentRunning)
	streamWriteBool(streamId, self.isCarrier)
	streamWriteUInt8(streamId, self.genes)

end


--- Read this record off a network stream. The exact mirror of `writeStream`, minus the
--- title, which the caller consumed to resolve the model it constructed this object from.
---@param streamId number Network stream handle.
---@param connection table Network connection.
function Disease:readStream(streamId, connection)

	self.state = RLDiseaseRecord.STATE_WIRE_ORDER[streamReadUInt8(streamId)]
	self.incubationTicksRemaining = streamReadUInt16(streamId)
	self.monthsElapsed = streamReadFloat32(streamId)
	self.treatmentMonthsRemaining = streamReadFloat32(streamId)
	self.immunityMonthsRemaining = streamReadFloat32(streamId)
	self.treatmentRunning = streamReadBool(streamId)
	self.isCarrier = streamReadBool(streamId)
	self.genes = streamReadUInt8(streamId)

end


-- Keyed on the TYPE index, so a goat resolves to SHEEP: goats are a subtype under that
-- type and the lifespan table carries no GOAT row to find.
--- Resolve an animal's uppercase type name, the key the lifespan table uses.
---@param animal table Host animal.
---@return string|nil typeName Uppercase type name, nil when the registry cannot answer.
local function resolveAnimalTypeName(animal)

	local animalSystem = g_currentMission ~= nil and g_currentMission.animalSystem or nil
	local subType = animal.getSubType ~= nil and animal:getSubType() or nil

	if animalSystem == nil or animalSystem.typeIndexToName == nil or subType == nil then
		return nil
	end

	return animalSystem.typeIndexToName[subType.typeIndex]

end


-- `deathEnabled` picks the ENTRY POINT, never a discarded return: the roll writes DEAD
-- inside the pure module before returning. Both return values are contract - the caller
-- adds the second to a per-pen total, so a bare `return` makes that `number + nil`.
--- Advance this record by one daily tick and report what the caller must do with it.
---@param animal table Host animal, supplying the vulnerability terms and the log identity.
---@param deathEnabled boolean Whether this tick may roll fatality.
---@param daysPerPeriod number The environment's configured days per period, 1..28.
---@return string instruction An `RLDiseaseProgression.INSTRUCTION` value.
---@return number treatmentCost This tick's share of the authored monthly fee; 0 when nothing was served.
function Disease:onDayChanged(animal, deathEnabled, daysPerPeriod)

	local typeName = resolveAnimalTypeName(animal)
	local maxLifespanMonths = typeName ~= nil
		and RLDiseaseVulnerability.maxLifespanMonthsFor(typeName) or nil

	if maxLifespanMonths == nil then
		-- `factor` drops the age term for a nil span, so this degrades rather than failing.
		Log:warning("Disease:onDayChanged: no lifespan resolved, skipping the vulnerability "
			.. "age term (disease=%s type=%s farmId=%s uniqueId=%s)",
			tostring(self.title), tostring(typeName),
			tostring(animal.farmId), tostring(animal.uniqueId))
	end

	-- The running flag lives on this object, not in the eight-key record, so it can only
	-- reach the driver as call context. `rng` stays absent: it is a test seam.
	local ctx = {
		["daysPerPeriod"] = daysPerPeriod,
		["vulnerability"] = RLDiseaseVulnerability.factor(animal.health, animal.genetics.health,
			animal.age, maxLifespanMonths),
		["treatmentRunning"] = self.treatmentRunning
	}

	local instruction, detail

	if deathEnabled then
		instruction, detail = RLDiseaseProgression.advance(self, self.model, ctx)
	else
		Log:trace("Disease:onDayChanged: deaths off, skipping the fatality roll (disease=%s "
			.. "farmId=%s uniqueId=%s)",
			tostring(self.title), tostring(animal.farmId), tostring(animal.uniqueId))

		instruction, detail = RLDiseaseProgression.advanceWithoutFatality(self, self.model, ctx)
	end

	local treatmentCost = 0

	-- `served` covers completions too - that tick is billed - and implies an authored
	-- block, since the counter cannot move without one.
	if detail.served then
		treatmentCost = self.model.treatment.cost / daysPerPeriod

		Log:trace("Disease:onDayChanged: served a treatment tick accruing %s of %s per month "
			.. "(disease=%s farmId=%s uniqueId=%s)",
			tostring(treatmentCost), tostring(self.model.treatment.cost),
			tostring(self.title), tostring(animal.farmId), tostring(animal.uniqueId))
	end

	return instruction, treatmentCost

end


--- Refuse to pass this record's genetics to a newborn: the legacy inheritance path is
--- off, so a child is born carrying no record and no `genes`.
---
--- The Mendelian fold's `math.random` draws go with it - between zero and two per call,
--- one per parent holding a single affected gene, and none for a type declaring no
--- `genetic` block.
---@param child table The newborn. Never mutated while the engine is off.
---@param otherParent table|nil The second parent. Unread while the engine is off.
function Disease:affectReproduction(child, otherParent)

	Log:trace("Disease:affectReproduction: refused, reason=legacy engine off (disease=%s)",
		tostring(self.title))

end


--- Refuse to scale a sale price: the legacy multiplier is off, so a diseased animal
--- sells for the undiseased price.
---
--- STAYS NEUTERED, a decision rather than unfinished work: repointing this body at
--- `model.salePrice` would duplicate a contract the sub-lethal resolver already holds,
--- and wiring a consumer to that resolver afterwards would apply every modifier TWICE.
--- The TRACE passes no FORMAT arguments deliberately - this runs per record per
--- `getSellPrice`, and Lua evaluates a log call's arguments before the level is tested.
---@param value number The undiseased price.
---@return number `value`, always and unconditionally.
function Disease:modifyValue(value)

	Log:trace("Disease:modifyValue: refused, reason=legacy engine off")

	return value

end


--- Whether a naming surface shows this record: hidden only at EXPOSED without a carried gene. Unlogged (per-frame).
---@param record table A disease record; a plain table works, which is why this is dot form.
---@return boolean visible False only for a non-carrier record at EXPOSED.
function Disease.isVisibleToPlayer(record)
    return record.isCarrier == true or record.state ~= RLDiseaseRecord.STATE.EXPOSED
end


function Disease:showInfo(box)

	local time
	-- A floor over a domain that cannot go below it, kept because this renders whatever a
	-- codec produced and a hand-edited save is the one shape that can hand it a negative.
	local elapsed = math.max(self.monthsElapsed, 0)
	local years = math.floor(elapsed / 12)
	local months = elapsed - years * 12

	if years == 0 then
		time = string.format("%d %s", months, months == 1 and g_i18n:getText("rl_ui_month") or g_i18n:getText("rl_ui_months"))
	elseif months == 0 then
		time = string.format("%d %s", years, years == 1 and g_i18n:getText("rl_ui_year") or g_i18n:getText("rl_ui_years"))
	else
		time = string.format("%d %s, %d %s", years, years == 1 and g_i18n:getText("rl_ui_year") or g_i18n:getText("rl_ui_years"), months, months == 1 and g_i18n:getText("rl_ui_month") or g_i18n:getText("rl_ui_months"))
	end

	box:addLine(string.format("%s (%s)", self.model.name, time), self:getStatus())

end


--- This record's player-facing status label.
---
--- CRUDE BUT TRUTHFUL, and deliberately temporary - the display slice replaces this
--- whole function, so do not invest in the wording. The fallback arm is load-bearing:
--- the alternative is a nil passed straight into `box:addLine` two lines up.
---
--- Add NO logging in here - this is a per-frame formatter, so a TRACE in any arm emits
--- continuously while a player stands near a diseased animal.
---@return string localised status label
function Disease:getStatus()

	local status

	if self.treatmentRunning then
		status = g_i18n:getText("rl_ui_beingTreated")
	elseif self.state == RLDiseaseRecord.STATE.RECOVERED then

		status = string.format("%s (%s)", g_i18n:getText("rl_ui_immune"), RLTimeFormat.formatAge(self.immunityMonthsRemaining))

	elseif (self.treatmentMonthsRemaining or 0) > 0 then

		-- The paused arm keys on the record's own counter ALONE: the question is whether
		-- THIS record holds unfinished progress, which the model cannot answer. `or 0` is
		-- nil tolerance for a partially-deserialized record, not type safety.
		status = g_i18n:getText("rl_ui_treatmentPaused")

	elseif self.isCarrier then

		status = g_i18n:getText("rl_ui_carrier")

	else
		status = g_i18n:getText("rl_ui_notTreated")
	end

	return status

end
