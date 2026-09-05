Disease = {}

local disease_mt = Class(Disease)

local Log = RmLogging.getLogger("RLRM")

function Disease.new(type, isCarrier, genes)

	local self = setmetatable({}, disease_mt)

	self.type = type
	self.cured = false
	self.beingTreated = false
	self.treatmentDuration = 0
	self.immunity = 0
	self.time = -1
	self.isCarrier = isCarrier or false
	self.genes = genes or 0
	self.recovery = 0

	return self

end


function Disease:loadFromXMLFile(xmlFile, key)

	self.cured = xmlFile:getBool(key .. "#cured", false)
	self.beingTreated = xmlFile:getBool(key .. "#beingTreated", false)
	self.treatmentDuration = xmlFile:getInt(key .. "#treatmentDuration", 0)
	self.immunity = xmlFile:getInt(key .. "#immunity", 0)
	self.time = xmlFile:getInt(key .. "#time", 0)
	self.isCarrier = xmlFile:getBool(key .. "#isCarrier", false)
	self.genes = xmlFile:getInt(key .. "#genes", 0)
	self.recovery = xmlFile:getInt(key .. "#recovery", 0)

end


function Disease:saveToXMLFile(xmlFile, key)

	xmlFile:setString(key .. "#title", self.type.title)
	xmlFile:setBool(key .. "#cured", self.cured)
	xmlFile:setBool(key .. "#beingTreated", self.beingTreated)
	xmlFile:setInt(key .. "#treatmentDuration", self.treatmentDuration)
	xmlFile:setInt(key .. "#immunity", self.immunity)
	xmlFile:setInt(key .. "#time", self.time)
	xmlFile:setBool(key .. "#isCarrier", self.isCarrier)
	xmlFile:setInt(key .. "#genes", self.genes)
	xmlFile:setInt(key .. "#recovery", self.recovery)

end


function Disease:writeStream(streamId, connection)

	streamWriteString(streamId, self.type.title)
	streamWriteBool(streamId, self.cured)
	streamWriteBool(streamId, self.beingTreated)
	streamWriteUInt8(streamId, self.treatmentDuration)
	streamWriteUInt8(streamId, self.immunity)
	-- SIGNED because the field's domain is signed: a record starts at -1 and only becomes
	-- non-negative on its first period tick, so the sentinel is a live value the wire carries.
	streamWriteInt16(streamId, self.time)
	streamWriteBool(streamId, self.isCarrier)
	streamWriteUInt8(streamId, self.genes)
	streamWriteUInt8(streamId, self.recovery)

end


function Disease:readStream(streamId, connection)

	self.cured = streamReadBool(streamId)
	self.beingTreated = streamReadBool(streamId)
	self.treatmentDuration = streamReadUInt8(streamId)
	self.immunity = streamReadUInt8(streamId)
	self.time = streamReadInt16(streamId)
	self.isCarrier = streamReadBool(streamId)
	self.genes = streamReadUInt8(streamId)
	self.recovery = streamReadUInt8(streamId)

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
		tostring(self.type and self.type.title or nil),
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
		tostring(self.type and self.type.title or nil))

end


--- Scale a sale price by this record's configured multiplier.
---
--- Gated on `diseasesEnabled` ALONE, deliberately. The sibling `modifyOutput` also tests
--- `cured`, and matching it here would be a latent sell-price change that outlives the
--- switchover for no benefit now - under the lock nothing reaches this arm anyway. The
--- symptomatic shaping of both functions belongs to the record slice.
---
--- No TRACE here, and that is not an oversight: Lua evaluates a log call's arguments before
--- the logger tests the level, and this runs per record per `getSellPrice`.
---@param value number The undiseased price.
---@return number The price after this record's multiplier, or `value` unchanged while the
---        engine is off.
function Disease:modifyValue(value)

	if g_diseaseManager == nil or not g_diseaseManager.diseasesEnabled then return value end

	return value * self.type.value

end


function Disease:modifyOutput(type, value)

	if self.cured or not g_diseaseManager.diseasesEnabled then return value end

	if self.isCarrier and self.type.carrier ~= nil and self.type.carrier.output ~= nil then return value * (self.type.carrier.output[type] or 1) end

	return value * (self.type.output[type] or 1)

end


function Disease:showInfo(box)

	local time
	-- DISPLAY clamp only. A record starts at -1 and stays there until its first period tick,
	-- and the raw arithmetic renders that as "-1 years, 11 months" rather than a fresh
	-- infection. The stored field and the wire slot both keep the sentinel - it is the lookup
	-- key for the fatality curve and the recovery threshold, so shifting it would move every
	-- disease timeline by a period.
	local elapsed = math.max(self.time, 0)
	local years = math.floor(elapsed / 12)
	local months = elapsed - years * 12

	if years == 0 then
		time = string.format("%d %s", months, months == 1 and g_i18n:getText("rl_ui_month") or g_i18n:getText("rl_ui_months"))
	elseif months == 0 then
		time = string.format("%d %s", years, years == 1 and g_i18n:getText("rl_ui_year") or g_i18n:getText("rl_ui_years"))
	else
		time = string.format("%d %s, %d %s", years, years == 1 and g_i18n:getText("rl_ui_year") or g_i18n:getText("rl_ui_years"), months, months == 1 and g_i18n:getText("rl_ui_month") or g_i18n:getText("rl_ui_months"))
	end

	box:addLine(string.format("%s (%s)", self.type.name, time), self:getStatus())

end


--- This record's player-facing status label.
---
--- Two properties are easy to get backwards. The immune arm's parenthetical is
--- REMAINING immunity, whereas showInfo's parenthetical is elapsed infection age - the
--- two render alike and answer opposite questions, so they read from different fields
--- on purpose. And `cured` is tested before `isCarrier`, so a record that is both reads
--- Immune; the card icons and the transmission collector answer their own questions
--- about that same record and give different answers, which is deliberate rather than
--- an inconsistency to unify.
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
--- The paused arm keys on `self.treatmentDuration` ALONE and must not learn about
--- `self.type`: the question is whether THIS record carries unfinished progress, which the
--- type's configuration cannot answer, and reaching for it would make the label depend on a
--- field the record does not hold. It sits above `isCarrier` deliberately, on the same
--- reasoning as `beingTreated` two arms up - that already outranks `isCarrier`, so a
--- suspended course of the same treatment does too. `or 0` is nil tolerance, not type
--- safety: it is the only numeric comparison in this function, and a partially-deserialized
--- record reaches it with the field absent.
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

	if self.beingTreated then
		status = g_i18n:getText("rl_ui_beingTreated")
	elseif self.cured then

		status = string.format("%s (%s)", g_i18n:getText("rl_ui_immune"), RLTimeFormat.formatAge(self.immunity))

	elseif (self.treatmentDuration or 0) > 0 then

		status = g_i18n:getText("rl_ui_treatmentPaused")

	elseif self.isCarrier then

		status = g_i18n:getText("rl_ui_carrier")

	else
		status = g_i18n:getText("rl_ui_notTreated")
	end

	return status

end