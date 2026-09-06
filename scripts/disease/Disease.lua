Disease = {}

local disease_mt = Class(Disease)

local Log = RmLogging.getLogger("RLRM")


--- The persisted record-shape version, written by `saveToXMLFile` and read by the save-load
--- site that decides whether a stored record can be reconstructed at all.
---
--- ONE home for both halves, because they must agree exactly and they live in different files:
--- a writer stamping a version the reader refuses drops every record the build writes, and a
--- reader accepting a version the writer never stamps admits legacy records as zombies.
---
--- Absent means 1 - the legacy shape, which carried no version attribute and no state. There is
--- deliberately no mapping from it: a legacy record is dropped, not migrated.
Disease.RECORD_VERSION = 2

--- Build a disease record attached to one animal.
---
--- The eight record keys are GRAFTED FLAT onto this object rather than nested under a
--- `self.record` field, and that shape is load-bearing: the spread pass and the sub-lethal
--- resolver already read `record.state` and `record.title` flat off `animal.diseases`, so a
--- nested reading breaks both shipped consumers with no raise and no red assert.
---
--- The graft is what keeps the record's OWN contract intact. `RLDiseaseRecord.new` returns
--- exactly eight keys; the ninth - the treatment running flag - is assigned here, on the
--- object, because a paused and a running course are otherwise indistinguishable from the
--- record alone (both carry a non-zero counter, since enrolment refuses a non-zero one).
---
--- `self.model` is the ONLY registry reference. There is no `self.type`: the registry entry
--- is a model entry now, so the two names would describe the same table and a reader could
--- not tell which vocabulary a given field belongs to.
---
--- A nil `model` RAISES here, deliberately and on every path. The savegame reader refuses an
--- unresolvable title before it ever calls this, and the stream reader cannot see one under
--- identical mod files - which the game enforces at join - so the branch that would guard it
--- has no producer. Constructing unconditionally and letting an impossible value raise is the
--- deliberate choice: a tolerance branch here would be dead code hiding a wiring fault behind
--- a silent nil.
---@param model table A parsed disease model entry, carrying `title`, `archetype` and `endpoint`.
---@param isCarrier boolean|nil True for an asymptomatic genetic carrier record.
---@param genes number|nil Count of affected genes inherited, 0 when not genetic.
---@return table disease A record at EXPOSED with its counters at zero.
function Disease.new(model, isCarrier, genes)

	local self = setmetatable(RLDiseaseRecord.new(model, model.title), disease_mt)

	self.model = model

	-- The ninth key. Pausing is the caller withholding the advance, so this says whether a
	-- course is RUNNING; `treatmentMonthsRemaining` says whether one holds progress. Both are
	-- needed - neither answers the other's question.
	self.treatmentRunning = false

	-- Genetics-system markers rather than SEIR state. Nothing in the SEIR pipeline reads
	-- either; they persist and stream so the genetics slice inherits them intact.
	self.isCarrier = isCarrier or false
	self.genes = genes or 0

	return self

end


--- Restore this record's state from a savegame.
---
--- EVERY read is attribute-KEYED and carries a default, which is what makes adding or
--- dropping a field a non-event for a save written by another build: a field this codec stops
--- writing leaves an attribute nobody reads, and one it stops reading defaults to exactly what
--- the older save holds. The STREAM is the positional half, and the one a shape change breaks.
---
--- `title`, `archetype` and `endpoint` are deliberately NOT read. All three are carried from
--- the model at construction, and the caller has already resolved that model from the stored
--- title - so re-deriving them is strictly more correct here than trusting a persisted copy,
--- which can go stale against a re-authored model while the model itself cannot.
---
--- The version discriminator is the CALLER's to read, above the construction: by the time this
--- runs the record already exists, so a refusal here could only blank a record rather than
--- decline to build one.
---@param xmlFile table An open XML document.
---@param key string This record's element key.
function Disease:loadFromXMLFile(xmlFile, key)

	self.state = xmlFile:getString(key .. "#state", RLDiseaseRecord.STATE.EXPOSED)
	self.incubationTicksRemaining = xmlFile:getInt(key .. "#incubationTicksRemaining", 0)
	-- FLOAT, all three of them, and the elapsed counter joined them when the progression
	-- driver landed: it is advanced by `1 / daysPerPeriod` per daily tick, so an integer
	-- slot would silently truncate every fractional month at each save and each join -
	-- discarding almost a whole illness at the longer period lengths. The treatment
	-- counter is fractional by the same construction, and the immunity counter shares the
	-- slot because a float survives whichever cadence decrements it.
	self.monthsElapsed = xmlFile:getFloat(key .. "#monthsElapsed", 0)
	self.treatmentMonthsRemaining = xmlFile:getFloat(key .. "#treatmentMonthsRemaining", 0)
	self.immunityMonthsRemaining = xmlFile:getFloat(key .. "#immunityMonthsRemaining", 0)
	self.treatmentRunning = xmlFile:getBool(key .. "#treatmentRunning", false)
	self.isCarrier = xmlFile:getBool(key .. "#isCarrier", false)
	self.genes = xmlFile:getInt(key .. "#genes", 0)

end


--- Persist this record.
---
--- `#version` is written UNCONDITIONALLY and is the whole point of the attribute. The loader
--- drops anything below 2, so a writer that forgets it drops every record this build ever
--- wrote on the very next load - silently, totally, and with the save looking clean in
--- between. There is no path on which omitting it is correct.
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
--- POSITIONAL, and the read half must stay its exact mirror - there is no key to resynchronise
--- on, so a field added to one half decodes every later field of every later record from the
--- wrong offset.
---
--- THE TITLE IS WRITTEN HERE AND READ BY THE CALLER. That asymmetry is deliberate and
--- pre-existing: the reader needs the title to resolve a model BEFORE it can construct the
--- object this method belongs to, so it consumes the string itself and hands the resolved
--- model to the constructor. Moving the write to the caller for symmetry would put the two
--- halves of one field in two files.
---
--- `archetype` and `endpoint` are not on the wire at all. Both come from the model, the reader
--- resolves the same model from the title, and identical mod files guarantee the two peers
--- resolve the same one - so sending them would cost a string each per record to transmit a
--- value the receiver already has.
---
--- The state crosses as a UInt8 ORDINAL over the append-only order in `RLDiseaseRecord`, read
--- at CALL time rather than aliased at file scope. The alias would work - this file is sourced
--- after that one - but a file-scope read of another module's global is exactly the load-order
--- hazard the disease group already carries once, and it is invisible to every automated tier
--- because the headless env sources its own dependencies whatever the loader says. One
--- instance of that hazard is enough.
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


--- Read this record off a network stream. The exact mirror of `writeStream`, minus the title,
--- which the caller consumed to resolve the model it constructed this object from.
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


--- Refuse to advance this record: the legacy progression engine is switched off for the
--- SEIR switchover, so a record freezes exactly as it stands - a part-served treatment
--- included - and nothing cures it, expires its immunity, kills its host, or bills the farm.
---
--- The refusal is unconditional rather than keyed on `diseasesEnabled`, and that is the
--- point: the setting is forced off beside it but stays writable, so the two mechanisms fail
--- in OPPOSITE directions. The setting fails open, this fails closed, and only this one still
--- holds once something turns the setting back on.
---
--- Both return values are the contract and must stay two: the caller destructures them and
--- adds the second to a running per-pen total, so a bare `return` makes that `number + nil`.
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
--- switched off for the switchover, so a child is born carrying no record and no `genes`.
---
--- The Mendelian fold's `math.random` draws go with it - between zero and two per call, one
--- per parent holding a single affected gene, and none at all for a type declaring no
--- `genetic` block. State the range rather than a count: the switchover's RNG-stream
--- accounting is only useful if the numbers in it are exact.
---
--- Unconditional for the same reason as `onPeriodChanged`: this half must keep holding once
--- something turns `diseasesEnabled` back on.
---@param child table The newborn. Never mutated while the engine is off.
---@param otherParent table|nil The second parent. Unread while the engine is off.
function Disease:affectReproduction(child, otherParent)

	Log:trace("Disease:affectReproduction: refused, reason=legacy engine off (disease=%s)",
		tostring(self.title))

end


--- Refuse to scale a sale price: the legacy multiplier is switched off for the SEIR
--- switchover, so a diseased animal sells for the undiseased price.
---
--- STAYS NEUTERED, and that is a decision rather than unfinished work. `model.salePrice` is
--- sitting right there, so repointing this body looks like the obvious completion - and it
--- would build a second implementation of a contract the sub-lethal resolver already holds,
--- over the same authored numbers. Wire a consumer to that resolver afterwards and every
--- modifier applies TWICE. The neutering is what closes the gate this function used to leak,
--- and it closes it without creating that duplicate.
---
--- Unconditional rather than keyed on `diseasesEnabled`, matching the sibling refusals:
--- the setting is forced off beside them but stays writable, so the two mechanisms fail
--- in OPPOSITE directions and only this one still holds once something turns the setting
--- back on.
---
--- The TRACE passes no FORMAT arguments, deliberately. Lua evaluates a log call's
--- arguments before the logger tests the level, and this runs per record per
--- `getSellPrice`; a bare message has nothing to evaluate, so the diagnostic costs a
--- level test rather than a `tostring` per record per price read.
---@param value number The undiseased price.
---@return number `value`, always and unconditionally.
function Disease:modifyValue(value)

	Log:trace("Disease:modifyValue: refused, reason=legacy engine off")

	return value

end


--- Refuse to scale a production output: the legacy multiplier is switched off for the
--- SEIR switchover, so a diseased animal produces at its undiseased rate.
---
--- STAYS NEUTERED, for the same reason as `modifyValue` above and one more that is specific to
--- this body. The old one read a carrier output map, and a model entry carries one at an
--- IDENTICAL path shape with cvm authored at `milk = 1.5` - so a repoint here would silently
--- grant the +50% milk that has never applied in any shipped build, with no raise and no red
--- assert to surface it. The sub-lethal resolver owns the real fold over these four channels,
--- and it deliberately cannot reach the carrier profile at all.
---
--- Unconditional, for the same fail-closed reason as `modifyValue` above.
---@param type any The fill type being produced. Unread.
---@param value number The undiseased output.
---@return number `value`, always and unconditionally.
function Disease:modifyOutput(type, value)

	Log:trace("Disease:modifyOutput: refused, reason=legacy engine off")

	return value

end


function Disease:showInfo(box)

	local time
	-- The elapsed counter starts at 0 and only ever rises, so the clamp is a floor over a
	-- domain that cannot go below it - kept because this renders whatever a codec produced,
	-- and a hand-edited save is the one shape that can hand it a negative.
	--
	-- KNOWN DEFECT, DEFERRED TO THE SLICE THAT WIRES THE PEN TICK, and unreachable in this
	-- build for the same reason `getStatus`'s own marker gives: `monthsElapsed` is now a
	-- FRACTION (the codec carries a float), but nothing advances it yet. Once it does,
	-- `%d` truncates while the plural predicate `months == 1` runs on the UNROUNDED value, so
	-- 1.0357 renders "1 months" and a record in its first sub-month renders "0 months". The
	-- rounding decision belongs to whoever wires the tick; it is not made here.
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
--- CRUDE BUT TRUTHFUL, and deliberately temporary. It says something true about every state a
--- record can hold without inventing vocabulary; the real five-state status language belongs to
--- the display slice, which replaces this whole function. Do not invest in the wording.
---
--- Two properties are easy to get backwards. The immune arm's parenthetical is
--- REMAINING immunity, whereas showInfo's parenthetical is elapsed infection age - the
--- two render alike and answer opposite questions, so they read from different fields
--- on purpose. And RECOVERED is tested before `isCarrier`, so a record that is both reads
--- Immune; the card icons and the transmission collector answer their own questions
--- about that same record and give different answers, which is deliberate rather than
--- an inconsistency to unify.
---
--- THE FALLBACK ARM IS LOAD-BEARING rather than tidy. DEAD, SUSCEPTIBLE and any value a later
--- codec revision retires all land on it, and the alternative is not a missing label - it is a
--- nil passed straight into `box:addLine` by the caller two lines above.
---
--- THE PAUSED ARM CANNOT KEY ON `state` ALONE. Every paused course sits at INFECTIOUS, which is
--- also where every untreated record sits, so a state-keyed reading orphans the paused string
--- entirely and renders a half-served course as untreated.
---
--- THE IMMUNE PARENTHETICAL ASSUMES A WHOLE NUMBER OF MONTHS. `RLTimeFormat.formatAge` takes
--- `age % 12` and formats it with `%s`, so a fractional counter renders its full decimal
--- expansion rather than a rounded month. The counter's slot is a float, because the cadence
--- that decrements it is not decided and a float survives either answer - so whichever slice
--- starts advancing it owns either counting in whole months or rounding at this call. Nothing
--- advances it today, so every record reaches here at 0 and the case is unreachable in this
--- build.
---
--- The immunity a player watches decrease is computed SERVER-side: the pen's period tick
--- gates disease progression on `isServer`, so a client renders whatever its last animal sync
--- carried. Each disease TRANSITION flags its animal and the pen flushes, so a client's copy
--- is accurate as of the most recent contract, cure or expiry. The per-month decrement BETWEEN
--- those transitions is deliberately not synced - flagging every live record every period
--- would rebroadcast the whole pen for the life of any record that never resolves. So
--- "counts down" is not a per-peer guarantee: the label is exact at each transition and
--- drifts until the next one.
---
--- The paused arm keys on the record's own counter ALONE and must not learn about the model:
--- the question is whether THIS record carries unfinished progress, which the model's
--- configuration cannot answer, and reaching for it would make the label depend on data the
--- record does not hold. It sits above `isCarrier` deliberately, on the same reasoning as the
--- running arm two above - that already outranks `isCarrier`, so a suspended course of the same
--- treatment does too. `or 0` is nil tolerance, not type safety: it is the only numeric
--- comparison in this function, and a partially-deserialized record reaches it with the field
--- absent.
---
--- That ordering extends the divergence above to a FOURTH answer, and it is deliberate. The
--- card icons test `isCarrier` first, so a carrier holding progress shows the carrier icon
--- while this label reads paused; and a plain paused record still shows the untreated icon,
--- because that icon answers "is a treatment running" and this label answers "does this
--- record hold progress". Do not unify them.
---
--- Add NO logging in here. This is a per-frame formatter - the HUD info box re-renders it
--- every frame a player stands near a diseased animal - so a TRACE in any arm emits
--- continuously. The diagnostic that explains a paused course belongs where the state is
--- produced, which is the dialog's toggle handler.
---@return string localised status label
function Disease:getStatus()

	local status

	if self.treatmentRunning then
		status = g_i18n:getText("rl_ui_beingTreated")
	elseif self.state == RLDiseaseRecord.STATE.RECOVERED then

		status = string.format("%s (%s)", g_i18n:getText("rl_ui_immune"), RLTimeFormat.formatAge(self.immunityMonthsRemaining))

	elseif (self.treatmentMonthsRemaining or 0) > 0 then

		status = g_i18n:getText("rl_ui_treatmentPaused")

	elseif self.isCarrier then

		status = g_i18n:getText("rl_ui_carrier")

	else
		status = g_i18n:getText("rl_ui_notTreated")
	end

	return status

end