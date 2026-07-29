function AnimalBuyEvent.new(object, animals, buyPrice, transportPrice)

	local event = AnimalBuyEvent.emptyNew()

	event.object = object
	event.animals = animals
	event.buyPrice = buyPrice
	event.transportPrice = transportPrice

	return event

end


function AnimalBuyEvent:readStream(streamId, connection)

	if connection:getIsServer() then

		self.errorCode = streamReadUIntN(streamId, 3)

	else

		self.object = NetworkUtil.readNodeObject(streamId)
		local numAnimals = streamReadUInt16(streamId)

		self.animals = {}

		for i = 1, numAnimals do

			local animal = Animal.new()
			animal:readStream(streamId, connection)
			table.insert(self.animals, animal)

		end

		self.buyPrice = streamReadFloat32(streamId)
		self.transportPrice = streamReadFloat32(streamId)

	end

	self:run(connection)

end


function AnimalBuyEvent:writeStream(streamId, connection)

	if not connection:getIsServer() then
		streamWriteUIntN(streamId, self.errorCode, 3)
		return
	end

	NetworkUtil.writeNodeObject(streamId, self.object)

	streamWriteUInt16(streamId, #self.animals)

	for _, animal in pairs(self.animals) do animal:writeStream(streamId, connection) end

	streamWriteFloat32(streamId, self.buyPrice)
	streamWriteFloat32(streamId, self.transportPrice)

end


function AnimalBuyEvent:run(connection)

	if connection:getIsServer() then

		g_messageCenter:publish(AnimalBuyEvent, self.errorCode)
		return

	end

	RmSafeUtils.safeCall("AnimalBuyEvent:run", function()

		-- Phase timing: per-phase TRACE lines (setup / validate / removeSale /
		-- addAnimals / addMoney+sendEvent) so a slow buy can be localised to one phase.
		-- TRACE-only because the surrounding safeCall enter/exit (also TRACE) gives the
		-- elapsed-ms total via its own log.
		local phaseStart = getTimeSec()
		local function phaseDoneMs() return (getTimeSec() - phaseStart) * 1000 end
		local function phaseReset() phaseStart = getTimeSec() end

		if not g_currentMission:getHasPlayerPermission("tradeAnimals", connection) then

			connection:sendEvent(AnimalBuyEvent.newServerToClient(AnimalBuyEvent.BUY_ERROR_NO_PERMISSION))
			return

		end

		local userId = g_currentMission.userManager:getUniqueUserIdByConnection(connection)
		local farmId = g_farmManager:getFarmForUniqueUserId(userId).farmId

		Log:trace("AnimalBuyEvent:run phase: setup took %.2fms (N=%d, dest=%s)",
			phaseDoneMs(),
			#self.animals,
			tostring(self.object and self.object.getName and self.object:getName() or self.object))

		-- The charged price is the SERVER's, never the client's. The dispatched
		-- float is computed on the sending peer, whose dealer-quality preset can
		-- lag authority (a demoted admin, or the ordering gap between the stock
		-- and settings events), so it is treated as display-only from here on.
		-- Recomputed BEFORE the validation loop so affordability and the charge
		-- below both use the same server number. Sign follows the dispatch
		-- convention: computeBuyPrice returns a positive price, the event
		-- carries it negated. transportPrice is deliberately left alone.
		-- Priced under pcall because getSellPrice dereferences getSubType(),
		-- genetics.quality and targetWeight with no guards, and self.animals is
		-- a client-supplied payload. Without this a malformed animal raises
		-- BEFORE the validation loop, the enclosing safeCall swallows it, and no
		-- response is ever sent - the client just waits out its watchdog. Falling
		-- back to the dispatched price keeps the validation loop reachable so it
		-- returns its normal BUY_ERROR_* code instead.
		local serverBuyPrice = 0
		local priced = pcall(function()
			local total = 0
			for _, animal in pairs(self.animals) do
				total = total - RLAnimalBuyService.computeBuyPrice(animal)
			end
			serverBuyPrice = total
		end)

		-- NaN is its own check: every comparison against NaN is false, so it
		-- would silently take the "agrees" branch below AND pass the
		-- affordability test, reaching addMoney and turning the farm balance into
		-- NaN. Corrupt genetics reaching getSellPrice is a real failure mode
		-- here, so this is a guard, not ceremony. `x ~= x` is the NaN test.
		if priced and serverBuyPrice ~= serverBuyPrice then
			Log:warning("AnimalBuyEvent:run: server price recompute produced NaN (corrupt animal data?); keeping the dispatched price")
			priced = false
		end

		if not priced then
			Log:warning("AnimalBuyEvent:run: server price recompute failed for %d animal(s); keeping the dispatched price so validation can reject the payload normally",
				#self.animals)
		else
			-- Epsilon, not equality: the client's figure arrived as a float32
			-- (streamReadFloat32) while this sum is a full-precision double, and
			-- the two sides accumulate in pairs() order, which differs per
			-- machine. An exact comparison would report a divergence on
			-- essentially every multi-animal purchase and destroy the value of
			-- this line as a tamper signal. One currency unit is far below
			-- anything worth flagging.
			local clientBuyPrice = self.buyPrice or 0
			if math.abs(serverBuyPrice - clientBuyPrice) > 1 then
				Log:debug("AnimalBuyEvent:run: client price %.2f differs from server recompute %.2f; charging the server's",
					clientBuyPrice, serverBuyPrice)
			else
				Log:trace("AnimalBuyEvent:run: server price recompute agrees with the client (%.2f)", serverBuyPrice)
			end

			self.buyPrice = serverBuyPrice
		end

		phaseReset()
		for _, animal in pairs(self.animals) do

			local errorCode = AnimalBuyEvent.validate(self.object, animal.subTypeIndex, animal.age, #self.animals, self.buyPrice, self.transportPrice, farmId)

			if errorCode ~= nil then
				Log:trace("AnimalBuyEvent:run phase: validate FAILED took %.2fms errorCode=%d", phaseDoneMs(), errorCode)
				connection:sendEvent(AnimalBuyEvent.newServerToClient(errorCode))
				return
			end

		end
		Log:trace("AnimalBuyEvent:run phase: validate took %.2fms", phaseDoneMs())

		phaseReset()
		for _, animal in pairs(self.animals) do

			g_currentMission.animalSystem:removeSaleAnimal(animal.animalTypeIndex, animal.birthday.country, animal.farmId, animal.uniqueId)

		end
		Log:trace("AnimalBuyEvent:run phase: removeSale took %.2fms", phaseDoneMs())

		phaseReset()
		self.object:addAnimals(self.animals)
		Log:trace("AnimalBuyEvent:run phase: addAnimals took %.2fms", phaseDoneMs())

		phaseReset()
		g_currentMission:addMoney(self.buyPrice + self.transportPrice, farmId, MoneyType.NEW_ANIMALS_COST, true, true)
		connection:sendEvent(AnimalBuyEvent.newServerToClient(AnimalBuyEvent.BUY_SUCCESS))

		-- Object may be a trailer on trailer-based dealer buys; only husbandry
		-- placeables carry addRLMessage.
		if self.object.addRLMessage ~= nil then
			if #self.animals == 1 then
				self.object:addRLMessage("BOUGHT_ANIMALS_SINGLE", nil, { g_i18n:formatMoney(math.abs(self.buyPrice + self.transportPrice), 2, true, true) })
			elseif #self.animals > 0 then
				self.object:addRLMessage("BOUGHT_ANIMALS_MULTIPLE", nil, { #self.animals, g_i18n:formatMoney(math.abs(self.buyPrice + self.transportPrice), 2, true, true) })
			end
		else
			Log:trace("AnimalBuyEvent:run: skipping addRLMessage (object has no husbandryAnimals spec, likely trailer buy) N=%d", #self.animals)
		end
		Log:trace("AnimalBuyEvent:run phase: addMoney+sendEvent+addRLMessage took %.2fms", phaseDoneMs())

	end)

end