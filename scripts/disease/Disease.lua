--[[
    Disease.lua
    One animal's disease record as a live object: the eight SEIR record keys grafted
    FLAT onto it, plus the treatment-running flag and the two genetics markers, with
    both codecs and the player-facing labels.

    The legacy progression engine is SWITCHED OFF for the SEIR switchover, so the four
    behaviour methods refuse unconditionally rather than keying on `diseasesEnabled` -
    the setting is forced off beside them but stays writable, so the two mechanisms
    fail in OPPOSITE directions and only these still hold if it is turned back on.
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


--- Refuse to advance this record: the legacy progression engine is off, so a record
--- freezes exactly as it stands - a part-served treatment included.
---
--- Both return values are the contract and must stay two: the caller destructures them
--- and adds the second to a running per-pen total, so a bare `return` makes that
--- `number + nil`.
---@param animal table Host animal. Read for log identity only while the engine is off.
---@param deathEnabled boolean Whether the fatality roll may run. Unread while the engine is off.
---@return boolean died Always false - a frozen record kills nobody.
---@return number treatmentCost Always 0 - a frozen record bills nothing.
function Disease:onPeriodChanged(animal, deathEnabled)

	Log:trace("Disease:onPeriodChanged: refused, reason=legacy engine off (disease=%s farmId=%s uniqueId=%s)",
		tostring(self.title),
		tostring(animal and animal.farmId or nil),
		tostring(animal and animal.uniqueId or nil))

	return false, 0

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


--- Refuse to scale a production output: the legacy multiplier is off, so a diseased
--- animal produces at its undiseased rate.
---
--- STAYS NEUTERED for `modifyValue`'s reason plus one specific to this body: the old one
--- read a carrier output map, and a model entry carries one at an IDENTICAL path shape
--- with cvm authored at `milk = 1.5`, so a repoint would silently grant a milk bonus
--- that has never applied in any shipped build.
---@param type any The fill type being produced. Unread.
---@param value number The undiseased output.
---@return number `value`, always and unconditionally.
function Disease:modifyOutput(type, value)

	Log:trace("Disease:modifyOutput: refused, reason=legacy engine off")

	return value

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
