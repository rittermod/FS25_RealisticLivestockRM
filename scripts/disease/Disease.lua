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


--- Advance this record by one month and report what it did to its host.
---
--- The player-facing cured notification is emitted HERE, by whichever of the two
--- transitions actually cures the record - a completed treatment or the natural-recovery
--- roll. That is the contract: the notification marks the CURE, so the two sites below own
--- it and record removal is silent. Immunity expiry is deliberately silent too - it ends
--- protection rather than granting it, so a notification there would tell the player they
--- are safe at the exact moment they stop being safe.
---
--- The two restore paths must never emit. `loadFromXMLFile` and `readStream` both assign
--- `cured`, and neither is a transition: one rebuilds a saved record, the other applies
--- server state on a client. Emitting there would re-announce every cured animal on every
--- load and on every client join.
---
--- Placement WITHIN this function is load-bearing. The treatment emission belongs in the
--- NESTED `treatmentDuration <= 0` block, never at the end of the enclosing `beingTreated`
--- branch - at the branch end it would fire once per treated month.
---@param animal table Host animal. Must carry the notification entry point and the identity
---       fields behind it: both cure sites notify through it, so a table lacking it raises here.
---@param deathEnabled boolean Whether the fatality roll may run at all.
---@return boolean died True when this record killed its host on this tick.
---@return number treatmentCost This month's configured treatment cost; 0 when not treating.
---       The caller accumulates it per pen - what it does with the total is the caller's
---       concern, so do not read this as money already taken from the farm.
function Disease:onPeriodChanged(animal, deathEnabled)

	if not g_diseaseManager.diseasesEnabled then return false, 0 end

	self.time = self.time + 1
	local treatmentCost = 0

	if self.cured then

		self.immunity = self.immunity - 1

		if self.immunity <= 0 then
			-- Name the transition HERE: removeDisease is generic and cannot know which caller
			-- reached it, and this branch is its only production caller. Its own trace records
			-- the removal; this one records why.
			Log:trace("Disease:onPeriodChanged: immunity EXPIRED, removing record (disease=%s farmId=%s uniqueId=%s)",
				tostring(self.type.title), tostring(animal.farmId), tostring(animal.uniqueId))

			animal:removeDisease(self.type.title)
			return false, 0
		end

	elseif self.beingTreated and self.type.treatment ~= nil then

		-- A course that has made no progress is a fresh enrolment, so seed it with the
		-- configured length; without this the counter never leaves 0 and every treatment
		-- cures on its first tick. Guarding on no-progress rather than seeding every tick
		-- is what lets a player stop and restart a course without losing the months
		-- already served.
		if self.treatmentDuration <= 0 then

			self.treatmentDuration = self.type.treatment.duration

			Log:trace("Disease:onPeriodChanged: seeded treatment duration (disease=%s duration=%s uniqueId=%s)",
				tostring(self.type.title), tostring(self.treatmentDuration), tostring(animal.uniqueId))

		end

		self.treatmentDuration = math.max(self.treatmentDuration - 1, 0)

		treatmentCost = self.type.treatment.cost

		if self.treatmentDuration <= 0 then
			-- Flag BEFORE the three writes: the flag is the only thing that schedules the pen
			-- flush, so behind them it would be the first thing lost to a raise, leaving the
			-- server cured and every client still showing the animal sick indefinitely.
			animal:setDirty()

			self.cured = true
			self.beingTreated = false
			self.immunity = self.type.immunity - 0

			animal:addMessage("DISEASE_CURED", { self.type.name })

			Log:trace("Disease:onPeriodChanged: cured by TREATMENT, animal flagged dirty (disease=%s farmId=%s uniqueId=%s)",
				tostring(self.type.title), tostring(animal.farmId), tostring(animal.uniqueId))
		end

	end

	if not self.cured and self.type.recovery ~= nil then

		self.recovery = self.recovery + 1

		if self.recovery >= self.type.recovery and math.random() >= 0.25 then

			-- Flag first, same contract as the treatment cure above.
			animal:setDirty()

			self.cured = true
			self.immunity = self.type.immunity - 0
			self.beingTreated = false

			animal:addMessage("DISEASE_CURED", { self.type.name })

			Log:trace("Disease:onPeriodChanged: cured by RECOVERY, animal flagged dirty (disease=%s farmId=%s uniqueId=%s)",
				tostring(self.type.title), tostring(animal.farmId), tostring(animal.uniqueId))

		end

	end

	if not self.isCarrier and deathEnabled then

		-- A cured record never rolls fatality, on the cure tick or anywhere inside
		-- the immunity window: the animal has already beaten this disease. The skip
		-- is a branch rather than an extra term on the guard above so that it can be
		-- observed in a log - a silent skip is undiagnosable.
		if self.cured then

			Log:trace("Disease:onPeriodChanged: cured record skips the fatality roll (disease=%s uniqueId=%s)",
				tostring(self.type.title), tostring(animal.uniqueId))

		else

			local fatality = self.type.fatality
			local fatalityChance = 0

			for i = 1, #fatality do

				if self.time <= fatality[i].time or i == #fatality then
					fatalityChance = fatality[i].value
					break
				end

			end

			if math.random() < fatalityChance then

				animal:die(self.type.key)
				return true, treatmentCost

			end

		end

	end

	return false, treatmentCost

end


function Disease:affectReproduction(child, otherParent)

	if not g_diseaseManager.diseasesEnabled then return end

	local genetic = self.type.genetic

	if genetic == nil or (not genetic.recessive and not genetic.dominant) then return end

	local pDisease = otherParent ~= nil and otherParent:getDisease(self.type.title) or nil
	
	local parents = {
		self.genes,
		pDisease ~= nil and pDisease.genes or 0
	}

	local numAffectedGenes = 0

	for _, genes in pairs(parents) do

		if genes == 2 then
			numAffectedGenes = numAffectedGenes + 1
		elseif genes == 1 then
			if math.random() <= 0.5 then numAffectedGenes = numAffectedGenes + 1 end
		end

	end

	if numAffectedGenes == 2 then

		child:addDisease(self.type, false, 2)

	elseif numAffectedGenes == 1 then

		if genetic.recessive then

			child:addDisease(self.type, true, 1)

		elseif genetic.dominant then

			child:addDisease(self.type, false, 1)

		end

	end

end


function Disease:modifyValue(value)

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