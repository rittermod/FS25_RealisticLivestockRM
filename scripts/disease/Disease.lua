--[[
    Disease.lua
    One animal's disease record as a live object: the eight SEIR record keys grafted
    FLAT onto it, plus the treatment-running flag and the two genetics markers, with
    both codecs and the player-facing labels.

    Progression is LIVE and runs off the pen's daily tick, deciding through
    `RLDiseaseProgression` and applying nothing itself; a genetic record skips it.
    `affectReproduction` passes a genetic record's copies to the unborn calf at conception through
    `RLDiseaseGenetics`. `modifyValue` scales a sale price while the record reads as sick.
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

	-- Genetics-system markers rather than SEIR state: `affectReproduction` reads the copies; the
	-- carrier fold, the affected death roll, RLDiseaseStatus and Disease.isVisibleToPlayer read isCarrier.
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
-- inside the pure module before returning. All three returns are contract - the caller adds
-- the second to a per-pen total (a bare `return` makes that `number + nil`) and reads the third.
--- Advance this record by one daily tick and report what the caller must do with it.
---@param animal table Host animal, supplying the vulnerability terms and the log identity.
---@param deathEnabled boolean Whether this tick may roll fatality.
---@param daysPerPeriod number The environment's configured days per period, 1..28.
---@return string instruction An `RLDiseaseProgression.INSTRUCTION` value.
---@return number treatmentCost This tick's share of the authored monthly fee; 0 when nothing was served.
---@return string treatmentResult An `RLDiseaseRecord.TREATMENT_RESULT` value; `NONE` when no course advanced.
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

	return instruction, treatmentCost, detail.treatment

end


-- A straw, an insemination and a conception with no live sire arrive with no other parent, and a sire
-- holding no record of this title counts as 0 copies too. Only the genetics module draws.
--- Pass this genetic record's copies, with the other parent's, to the unborn child through the genetic applier.
---@param child table The unborn child, built at conception; given a record through `DiseaseManager:contractGenetic`.
---@param otherParent table|nil The second parent, or nil when there is none.
function Disease:affectReproduction(child, otherParent)

    if not g_diseaseManager.diseasesEnabled then
        Log:trace("Disease:affectReproduction: refused, reason=diseases disabled (disease=%s)",
            tostring(self.title))
        return
    end

    if self.archetype ~= "genetic" then
        Log:trace("Disease:affectReproduction: refused, reason=not genetic (disease=%s)",
            tostring(self.title))
        return
    end

    if not g_diseaseManager:isTitleEnabled(self.title) then
        Log:trace("Disease:affectReproduction: refused, reason=disabled (disease=%s)",
            tostring(self.title))
        return
    end

    local otherGenes = 0

    if otherParent ~= nil then
        for _, record in ipairs(otherParent.diseases) do
            if record.title == self.title then
                otherGenes = record.genes
                break
            end
        end
    end

    local genes, isCarrier = RLDiseaseGenetics.inherit(self.genes, otherGenes, self.model.genetic)

    if genes == 0 then
        Log:trace("Disease:affectReproduction: nothing inherited (disease=%s parents=%s+%s uniqueId=%s)",
            tostring(self.title), tostring(self.genes), tostring(otherGenes), tostring(child.uniqueId))
        return
    end

    Log:debug("Disease:affectReproduction: inherited title=%s genes=%s carrier=%s (parents=%s+%s "
        .. "farmId=%s uniqueId=%s)", tostring(self.title), tostring(genes), tostring(isCarrier),
        tostring(self.genes), tostring(otherGenes), tostring(child.farmId), tostring(child.uniqueId))

    g_diseaseManager:contractGenetic(child, self.model, genes, isCarrier)

end


-- An incubating, recovered or carrier-only record sells at the undiseased price. The sub-lethal
-- resolver has no sale channel; this is the only term in `Animal:getSellPrice` that reads a disease record.
--- Scale a sale price by this record's `salePrice` while it reads as sick, behind the diseases setting.
---@param value number The price so far.
---@return number The price scaled by `salePrice` for an INFECTIOUS record with diseases on, else `value`.
function Disease:modifyValue(value)
    if g_diseaseManager == nil or not g_diseaseManager.diseasesEnabled then
        Log:trace(g_diseaseManager == nil and "Disease:modifyValue: refused, reason=no disease manager"
            or "Disease:modifyValue: refused, reason=diseases off")
        return value
    end

    if not RLDiseaseStatus.isDiseased(self) then
        Log:trace("Disease:modifyValue: unchanged, reason=not diseased")
        return value
    end

    local scaled = value * self.model.salePrice

    if Log.level >= RmLogging.LOG_LEVEL.TRACE then
        Log:trace("Disease:modifyValue: applied, disease=%s salePrice=%s price=%s -> %s",
            tostring(self.title), tostring(self.model.salePrice), tostring(value), tostring(scaled))
    end

    return scaled
end


--- Whether a naming surface shows this record: hidden only at EXPOSED without a carried gene. Unlogged (per-frame).
---@param record table A disease record; a plain table works, which is why this is dot form.
---@return boolean visible False only for a non-carrier record at EXPOSED.
function Disease.isVisibleToPlayer(record)
    return record.isCarrier == true or record.state ~= RLDiseaseRecord.STATE.EXPOSED
end


--- Add this record's HUD line: its name, with whole months elapsed unless genetic, and its status. Unlogged: per-frame.
---@param box table The HUD key/value box being filled.
function Disease:showInfo(box)

    -- A genetic record's elapsed counter never advances, so its line names the disease alone.
    if self.archetype == "genetic" then
        box:addLine(self.model.name, self:getStatus())
        return
    end

    local time
    local elapsed = RLDiseaseStatus.wholeMonthsElapsed(self.monthsElapsed)
    local years = math.floor(elapsed / 12)
    local months = elapsed - years * 12

    if years == 0 then
        time = string.format("%d %s", months,
            months == 1 and g_i18n:getText("rl_ui_month") or g_i18n:getText("rl_ui_months"))
    elseif months == 0 then
        time = string.format("%d %s", years,
            years == 1 and g_i18n:getText("rl_ui_year") or g_i18n:getText("rl_ui_years"))
    else
        time = string.format("%d %s, %d %s",
            years, years == 1 and g_i18n:getText("rl_ui_year") or g_i18n:getText("rl_ui_years"),
            months, months == 1 and g_i18n:getText("rl_ui_month") or g_i18n:getText("rl_ui_months"))
    end

    box:addLine(string.format("%s (%s)", self.model.name, time), self:getStatus())

end


-- Every production caller filters out a record `Disease.isVisibleToPlayer` hides; the Not-treated
-- fallback exists so a direct call on such a record still returns a label, never nil.
--- This record's player-facing status label. No logging: a per-frame formatter.
---@return string localised status label, with whole months for an immune record
function Disease:getStatus()
    local presentation = RLDiseaseStatus.resolve(self)
    local label = g_i18n:getText(presentation.statusKey or RLDiseaseStatus.KEY.NOT_TREATED)

    if presentation.months ~= nil then
        return string.format("%s (%s)", label, RLTimeFormat.formatAge(presentation.months))
    end

    return label
end
