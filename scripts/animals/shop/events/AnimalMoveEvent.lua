local Log = RmLogging.getLogger("RLRM")

--- Log a one-line snapshot of a cluster husbandry's visual-count state.
--- Used by AnimalMoveEvent:run to make source/target visual-count drift
--- observable in the log on every move.
--- Trailer cluster systems have no clusterHusbandry; logged as "no clusterHusbandry".
--- @param side string "source" | "target"
--- @param stage string "before" | "after"
--- @param clusterSystem table The cluster system to inspect
function AnimalMoveEvent._logVisualCountSnapshot(side, stage, clusterSystem)
	local owner = clusterSystem and clusterSystem.owner
	local spec = owner and owner.spec_husbandryAnimals
	local clusterHusbandry = spec and spec.clusterHusbandry
	local ownerName = owner and owner.getName and owner:getName() or tostring(owner)

	if clusterHusbandry == nil then
		Log:debug("AnimalMoveEvent snapshot: side=%s stage=%s owner=%s (no clusterHusbandry)",
			side, stage, tostring(ownerName))
		return
	end

	local visualCount = clusterHusbandry.visualAnimalCount or 0
	local slotsParts = {}
	if type(clusterHusbandry.husbandryIdsToVisualAnimalCount) == "table" then
		for engineId, count in pairs(clusterHusbandry.husbandryIdsToVisualAnimalCount) do
			table.insert(slotsParts, string.format("%s=%s", tostring(engineId), tostring(count)))
		end
	end
	Log:debug("AnimalMoveEvent snapshot: side=%s stage=%s owner=%s visualCount=%d slots=[%s]",
		side, stage, tostring(ownerName), visualCount, table.concat(slotsParts, ","))
end

--- Deliver animals to an extended-production-point target via per-animal-atomic
--- addCluster calls.
---
--- Production-points exposing animalsTypeData and a per-instance addCluster (with
--- no spec_husbandryAnimals) accept animals via that override which bumps storage
--- fillLevel; their internal cluster system is a placeholder, so cluster-system
--- flush would never reach the override. Each animal gets a single-animal cluster
--- shim; addCluster runs inside a per-animal pcall so a failure aborts the batch
--- with state consistency: every animal is either still in source (and uncredited)
--- or removed and credited. RLRM owns source-side bookkeeping in the staged
--- source-flush step the caller runs after this returns, so the shim's
--- changeNumAnimals is a no-op.
---
--- @param targetObject table Production-point factory exposing per-instance addCluster
--- @param transferList table Array of {animal, sourceCluster} entries to deliver
--- @return table deliveredList Subset of transferList that addCluster accepted (in order)
--- @return string|nil abortError Pcall error from the failed call, or nil if all succeeded
function AnimalMoveEvent._deliverToEPPTarget(targetObject, transferList)
	local deliveredList = {}
	for i, entry in ipairs(transferList) do
		local shim = {
			subTypeIndex = entry.animal.subTypeIndex,
			numAnimals = 1,
			changeNumAnimals = function() end,
		}
		local ok, err = pcall(function()
			targetObject:addCluster(shim)
		end)
		if ok then
			-- Clear engine identity only on the delivered branch. A failed addCluster
			-- leaves the animal in source; stripping its idFull there would orphan
			-- the source husbandry's visual-count bookkeeping for that animal.
			entry.animal.id, entry.animal.idFull = nil, nil
			table.insert(deliveredList, entry)
			Log:trace("AnimalMoveEvent._deliverToEPPTarget: i=%d subTypeIndex=%s ok",
				i, tostring(entry.animal.subTypeIndex))
		else
			Log:error("AnimalMoveEvent._deliverToEPPTarget: i=%d subTypeIndex=%s FAILED, aborting batch: %s",
				i, tostring(entry.animal.subTypeIndex), tostring(err))
			return deliveredList, err
		end
	end
	Log:debug("AnimalMoveEvent._deliverToEPPTarget: all %d animals delivered", #deliveredList)
	return deliveredList, nil
end


--- Dispatch animal delivery to the target object based on target type.
---
--- For EPP targets (animalsTypeData + callable addCluster + nil spec_husbandryAnimals)
--- delegates to _deliverToEPPTarget for per-animal-atomic delivery; the caller is
--- expected to stage source-flush against the returned deliveredList AFTER this call
--- so partial failure does not strand animals out of state. For husbandry targets
--- queues animals on the cluster system and flushes via updateNow with before/after
--- visual-count snapshots; the caller runs source-flush BEFORE this call to preserve
--- the husbandry-target source-first invariant (target's updateClusters tail-calls
--- updateVisualAnimals which reassigns idFull on the shared Animal entity, so source
--- bookkeeping must complete first).
---
--- @param targetObject table The destination of the move (husbandry placeable or EPP factory)
--- @param transferList table Array of {animal, sourceCluster} entries to deliver
--- @param targetClusterSystem table Cluster system retrieved from targetObject:getClusterSystem()
--- @return boolean ok True if all delivery succeeded
--- @return string|nil err Error message from the failing step, or nil
--- @return table deliveredList Entries successfully delivered (subset for EPP, equals transferList for husbandry)
--- Queue source-side cluster removals for the animals that were actually
--- delivered to the target. Caller is responsible for the eventual
--- updateNow() commit.
---
--- Extracted from :run's EPP branch so the staged-flush behavior can be
--- exercised by unit tests without stubbing the entire :run execution
--- context.
---
--- @param clusterSystemSource table Source cluster system retrieved from sourceObject:getClusterSystem()
--- @param deliveredList table Subset of transferList that the target accepted
function AnimalMoveEvent._stageSourceFlushForDelivered(clusterSystemSource, deliveredList)
	for _, entry in ipairs(deliveredList) do
		clusterSystemSource:addPendingRemoveCluster(entry.sourceCluster)
	end
	Log:trace("AnimalMoveEvent._stageSourceFlushForDelivered: queued %d source removes",
		#deliveredList)
end


function AnimalMoveEvent._dispatchTargetDelivery(targetObject, transferList, targetClusterSystem)
	local isEPPTarget = targetObject.animalsTypeData ~= nil
		and type(targetObject.addCluster) == "function"
		and targetObject.spec_husbandryAnimals == nil

	if isEPPTarget then
		Log:debug("AnimalMoveEvent._dispatchTargetDelivery: EPP target detected, delivering via addCluster (animals=%d)",
			#transferList)
		local deliveredList, abortError = AnimalMoveEvent._deliverToEPPTarget(targetObject, transferList)
		return abortError == nil, abortError, deliveredList
	end

	Log:trace("AnimalMoveEvent._dispatchTargetDelivery: husbandry target, using cluster system path (animals=%d)",
		#transferList)
	local ok1, err1 = pcall(function()
		for _, entry in ipairs(transferList) do
			entry.animal.id, entry.animal.idFull = nil, nil
			targetClusterSystem:addPendingAddCluster(entry.animal)
		end
	end)
	AnimalMoveEvent._logVisualCountSnapshot("target", "before", targetClusterSystem)
	local ok2, err2 = pcall(function() targetClusterSystem:updateNow() end)
	AnimalMoveEvent._logVisualCountSnapshot("target", "after", targetClusterSystem)

	local ok = ok1 and ok2
	local err = (not ok1) and err1 or err2
	return ok, err, transferList
end


function AnimalMoveEvent.new(sourceObject, targetObject, animals, moveType)

	local event = AnimalMoveEvent.emptyNew()

	event.sourceObject = sourceObject
	event.targetObject = targetObject
	event.animals = animals
	event.moveType = moveType

	return event

end


function AnimalMoveEvent:readStream(streamId, connection)

	if connection:getIsServer() then

		self.errorCode = streamReadUIntN(streamId, 3)
		Log:trace("AnimalMoveEvent:readStream (client): errorCode=%d", self.errorCode)

	else

		self.moveType = streamReadString(streamId)

		self.sourceObject = NetworkUtil.readNodeObject(streamId)
		self.targetObject = NetworkUtil.readNodeObject(streamId)

		local numAnimals = streamReadUInt16(streamId)
		Log:trace("AnimalMoveEvent:readStream (server): moveType='%s' numAnimals=%d source=%s target=%s",
			tostring(self.moveType), numAnimals,
			tostring(self.sourceObject), tostring(self.targetObject))

		self.animals = {}

		for i = 1, numAnimals do

			local animal = Animal.new()
			local success = animal:readStream(streamId, connection)
			table.insert(self.animals, animal)
			Log:trace("AnimalMoveEvent:readStream: animal %d read success=%s id='%s'",
				i, tostring(success), tostring(animal.uniqueId))

		end

	end

	self:run(connection)

end


function AnimalMoveEvent:writeStream(streamId, connection)

	if not connection:getIsServer() then
		Log:trace("AnimalMoveEvent:writeStream (server->client): errorCode=%d", self.errorCode)
		streamWriteUIntN(streamId, self.errorCode, 3)
		return
	end

	Log:trace("AnimalMoveEvent:writeStream (client->server): moveType='%s' numAnimals=%d",
		tostring(self.moveType), #self.animals)

	streamWriteString(streamId, self.moveType)

	NetworkUtil.writeNodeObject(streamId, self.sourceObject)
	NetworkUtil.writeNodeObject(streamId, self.targetObject)

	streamWriteUInt16(streamId, #self.animals)

	for i, animal in pairs(self.animals) do
		Log:trace("AnimalMoveEvent:writeStream: writing animal %d id='%s'", i, tostring(animal.uniqueId))
		local success = animal:writeStream(streamId, connection)
		Log:trace("AnimalMoveEvent:writeStream: animal %d write success=%s", i, tostring(success))
	end

end


function AnimalMoveEvent:run(connection)

	if connection:getIsServer() then
		Log:trace("AnimalMoveEvent:run (client): publishing errorCode=%d", self.errorCode)
		g_messageCenter:publish(AnimalMoveEvent, self.errorCode)
		return

	end

	RmSafeUtils.safeCall("AnimalMoveEvent:run", function()

		Log:debug("AnimalMoveEvent:run (server): moveType='%s' animals=%d source=%s target=%s",
			tostring(self.moveType), #self.animals,
			tostring(self.sourceObject and self.sourceObject.getName and self.sourceObject:getName()),
			tostring(self.targetObject and self.targetObject.getName and self.targetObject:getName()))

		local userId = g_currentMission.userManager:getUniqueUserIdByConnection(connection)
		local farmId = g_farmManager:getFarmForUniqueUserId(userId).farmId
		Log:trace("AnimalMoveEvent:run: userId=%s farmId=%d", tostring(userId), farmId)

		local validatedCount = 0

		for i, animal in pairs(self.animals) do

			Log:trace("AnimalMoveEvent:run: validating animal %d subTypeIndex=%s", i, tostring(animal.subTypeIndex))
			local errorCode = AnimalMoveEvent.validate(self.sourceObject, self.targetObject, farmId, animal.subTypeIndex)

			if errorCode ~= nil then
				Log:debug("AnimalMoveEvent:run: validation failed for animal %d, errorCode=%d", i, errorCode)
				connection:sendEvent(AnimalMoveEvent.newServerToClient(errorCode))
				return
			end

			validatedCount = validatedCount + 1

			if self.targetObject:getNumOfFreeAnimalSlots(animal.subTypeIndex) < validatedCount then
				Log:debug("AnimalMoveEvent:run: not enough space at target (need=%d)", validatedCount)
				connection:sendEvent(AnimalMoveEvent.newServerToClient(AnimalMoveEvent.MOVE_ERROR_NOT_ENOUGH_SPACE))
				return
			end

		end

		Log:debug("AnimalMoveEvent:run: all %d animals validated, starting transfer", validatedCount)

		local clusterSystemSource = self.sourceObject:getClusterSystem()
		Log:trace("AnimalMoveEvent:run: got source cluster system: %s", tostring(clusterSystemSource))

		-- Check for EPP age constraints on target
		local eppTypeData = nil
		if self.targetObject.animalsTypeData ~= nil and #self.animals > 0 then
			local subType = g_currentMission.animalSystem:getSubTypeByIndex(self.animals[1].subTypeIndex)
			if subType ~= nil then
				eppTypeData = self.targetObject.animalsTypeData[subType.typeIndex]
			end
			Log:trace("AnimalMoveEvent:run: EPP typeData=%s", tostring(eppTypeData))
		end

		-- Pass 1: EPP filter + source-cluster lookup. Pre-resolving source references here
		-- avoids a second linear scan inside addPendingRemoveCluster, and skipping EPP-failed
		-- animals at this stage keeps them out of both pending queues entirely.
		local targetClusterSystem = self.targetObject:getClusterSystem()
		local transferList = {}
		for i, animal in pairs(self.animals) do
			Log:trace("AnimalMoveEvent:run: processing animal %d id='%s' age=%s",
				i, tostring(animal.uniqueId), tostring(animal.age))

			local skip = false
			if eppTypeData ~= nil then
				local age = animal.age or 0
				local minAge = eppTypeData.minimumAge or 0
				local maxAge = eppTypeData.maximumAge or 999
				if age < minAge or age > maxAge then
					Log:trace("AnimalMoveEvent:run: skipping animal '%s' age=%d (EPP range %d-%d)",
						animal.uniqueId or "?", age, minAge, maxAge)
					skip = true
				end
			end

			if not skip then
				local clusterId = RLAnimalUtil.toKey(animal.farmId, animal.uniqueId, animal.birthday.country)
				local sourceCluster = clusterSystemSource:getClusterById(clusterId)
				if sourceCluster ~= nil then
					table.insert(transferList, { animal = animal, sourceCluster = sourceCluster })
				else
					Log:warning("AnimalMoveEvent:run: source cluster not found for clusterId='%s' (skipping)",
						tostring(clusterId))
				end
			end
		end

		-- Pass 2: ordering depends on target type.
		-- Husbandry target: source-first is mandatory. Target's updateClusters tail-calls
		-- updateVisualAnimals which reassigns animal.idFull on the shared entity; source's
		-- removeCluster must read source-side handles before that rewrite to keep
		-- husbandryIdsToVisualAnimalCount in sync.
		-- EPP target (animalsTypeData + per-instance addCluster, no spec_husbandryAnimals):
		-- target-first per-animal-atomic. Source-flush is staged for delivered animals only,
		-- so a per-animal failure leaves un-delivered animals in source uncredited (no loss,
		-- no duplication). EPP targets do not run updateVisualAnimals so the husbandry
		-- ordering hazard does not apply.
		local isEPPTarget = self.targetObject.animalsTypeData ~= nil
			and type(self.targetObject.addCluster) == "function"
			and self.targetObject.spec_husbandryAnimals == nil

		local ok1, err1, ok2, err2 = true, nil, true, nil
		local okTarget, errTarget, deliveredList = true, nil, transferList

		if isEPPTarget then
			okTarget, errTarget, deliveredList = AnimalMoveEvent._dispatchTargetDelivery(
				self.targetObject, transferList, targetClusterSystem)

			ok1, err1 = pcall(function()
				AnimalMoveEvent._stageSourceFlushForDelivered(clusterSystemSource, deliveredList)
			end)
			AnimalMoveEvent._logVisualCountSnapshot("source", "before", clusterSystemSource)
			ok2, err2 = pcall(function() clusterSystemSource:updateNow() end)
			AnimalMoveEvent._logVisualCountSnapshot("source", "after", clusterSystemSource)

			-- Source-flush failure after target credit means animals are credited to
			-- the target AND still in source = duplication. Source-flush is RLRM-internal
			-- (cluster bookkeeping) and idempotent under normal conditions, so this is
			-- a rare residual risk. When it happens, enumerate affected animals so the
			-- player can clean up. Duplication is a player-favoured failure mode in a
			-- leisure game; loss would not be.
			if (not ok1 or not ok2) and #deliveredList > 0 then
				local idList = {}
				for _, entry in ipairs(deliveredList) do
					table.insert(idList, string.format("farmId=%s uniqueId=%s",
						tostring(entry.animal.farmId), tostring(entry.animal.uniqueId)))
				end
				Log:error("AnimalMoveEvent:run: EPP source-flush FAILED after target credit; %d animal(s) duplicated (credited to target AND still in source): %s",
					#deliveredList, table.concat(idList, "; "))
			end
		else
			ok1, err1 = pcall(function()
				for _, entry in ipairs(transferList) do
					clusterSystemSource:addPendingRemoveCluster(entry.sourceCluster)
				end
			end)
			AnimalMoveEvent._logVisualCountSnapshot("source", "before", clusterSystemSource)
			ok2, err2 = pcall(function() clusterSystemSource:updateNow() end)
			AnimalMoveEvent._logVisualCountSnapshot("source", "after", clusterSystemSource)

			okTarget, errTarget, deliveredList = AnimalMoveEvent._dispatchTargetDelivery(
				self.targetObject, transferList, targetClusterSystem)
		end

		local okAll = ok1 and ok2 and okTarget

		if okAll then
			Log:debug("AnimalMoveEvent:run: transfer complete path=%s delivered=%d source=%s target=%s, sending success",
				isEPPTarget and "epp" or "cluster",
				#deliveredList,
				tostring(self.sourceObject and self.sourceObject.getName and self.sourceObject:getName()),
				tostring(self.targetObject and self.targetObject.getName and self.targetObject:getName()))
			connection:sendEvent(AnimalMoveEvent.newServerToClient(AnimalMoveEvent.MOVE_SUCCESS))
		else
			Log:error("AnimalMoveEvent:run: batch failed path=%s delivered=%d sourceQueue=%s sourceFlush=%s target=%s",
				isEPPTarget and "epp" or "cluster",
				#deliveredList,
				tostring(err1), tostring(err2), tostring(errTarget))
			connection:sendEvent(AnimalMoveEvent.newServerToClient(AnimalMoveEvent.MOVE_ERROR_INVALID_CLUSTER))
			return
		end

		if g_server ~= nil and not g_server.netIsRunning then return end

		local husbandry, trailer

		if self.moveType == "SOURCE" then
			husbandry, trailer = self.sourceObject, self.targetObject
		else
			husbandry, trailer = self.targetObject, self.sourceObject
		end

		if husbandry.addRLMessage ~= nil then
			if #self.animals == 1 then
				husbandry:addRLMessage(string.format("MOVED_ANIMALS_%s_SINGLE", self.moveType), nil, { trailer:getName() })
			elseif #self.animals > 0 then
				husbandry:addRLMessage(string.format("MOVED_ANIMALS_%s_MULTIPLE", self.moveType), nil, { #self.animals, trailer:getName() })
			end
		end

		Log:debug("AnimalMoveEvent:run: complete")

	end)

end


function AnimalMoveEvent.validate(sourceObject, targetObject, farmId, subTypeIndex)

	if sourceObject == nil then return AnimalMoveEvent.MOVE_ERROR_SOURCE_OBJECT_DOES_NOT_EXIST end

	if targetObject == nil then return AnimalMoveEvent.MOVE_ERROR_TARGET_OBJECT_DOES_NOT_EXIST end

	if not g_currentMission.accessHandler:canFarmAccess(farmId, sourceObject) or not g_currentMission.accessHandler:canFarmAccess(farmId, targetObject) then return AnimalMoveEvent.MOVE_ERROR_NO_PERMISSION end

	if not targetObject:getSupportsAnimalSubType(subTypeIndex) then return AnimalMoveEvent.MOVE_ERROR_ANIMAL_NOT_SUPPORTED end

	if targetObject:getNumOfFreeAnimalSlots(subTypeIndex) < 1 then return AnimalMoveEvent.MOVE_ERROR_NOT_ENOUGH_SPACE end

	return nil

end
