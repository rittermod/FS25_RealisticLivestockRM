function AnimalSellEvent.new(object, animals, price, transportPrice)

	local event = AnimalSellEvent.emptyNew()

	event.object = object
	event.animals = animals
	event.price = price
	event.transportPrice = transportPrice

	return event

end


function AnimalSellEvent:readStream(streamId, connection)

	if connection:getIsServer() then

		self.errorCode = streamReadUIntN(streamId, 3)

	else

		self.object = NetworkUtil.readNodeObject(streamId)
		local numAnimals = streamReadUInt16(streamId)

		self.animals = {}

		for i = 1, numAnimals do

			local identifiers = RLAnimalUtil.readStreamIdentifiers(streamId, connection)
			table.insert(self.animals, identifiers)

		end

		self.price = streamReadFloat32(streamId)
		self.transportPrice = streamReadFloat32(streamId)

	end

	self:run(connection)

end


function AnimalSellEvent:writeStream(streamId, connection)

	if not connection:getIsServer() then
		streamWriteUIntN(streamId, self.errorCode, 3)
		return
	end

	NetworkUtil.writeNodeObject(streamId, self.object)

	streamWriteUInt16(streamId, #self.animals)

	for i, animal in pairs(self.animals) do
		RLAnimalUtil.writeStreamIdentifiers(animal, streamId, connection)
	end

	streamWriteFloat32(streamId, self.price)
	streamWriteFloat32(streamId, self.transportPrice)

end


--- Client: publish the reply code. Server: validate the whole batch, then remove and pay for it.
---@param connection table The sender's connection (a client when this runs on the server)
function AnimalSellEvent:run(connection)

	if connection:getIsServer() then

		g_messageCenter:publish(AnimalSellEvent, self.errorCode)
		return

	end

	RmSafeUtils.safeCall("AnimalSellEvent:run", function()

		if not g_currentMission:getHasPlayerPermission("tradeAnimals", connection) then

			connection:sendEvent(AnimalSellEvent.newServerToClient(AnimalSellEvent.SELL_ERROR_NO_PERMISSION))
			return

		end

		local userId = g_currentMission.userManager:getUniqueUserIdByConnection(connection)
		local farmId = g_farmManager:getFarmForUniqueUserId(userId).farmId

		local clusterSystem = self.object:getClusterSystem()

		Log:trace("SellEvent:run selling %d animals", #self.animals)

		-- Pass 1: pre-validate all animals before removing any (prevents partial removal on
		-- blocked batch). Collect cluster references here so pass 2 doesn't repeat the
		-- getClusterById linear scan (S2 micro-opt from review).
		local validatedClusters = {}
		for i, identifier in pairs(self.animals) do
			local key = RLAnimalUtil.toKeyFromIdentifiers(identifier)
			Log:trace("SellEvent:run pass1 [%d] key=%s", i, tostring(key))
			if key ~= nil then
				local animal = self.object:getClusterById(key)
				Log:trace("SellEvent:run pass1 [%d] found=%s name=%s canBeSold=%s getCanBeSold=%s",
					i, tostring(animal ~= nil), animal and (animal.name or "?") or "nil",
					tostring(animal and animal.canBeSold), tostring(animal and animal:getCanBeSold()))
				if animal ~= nil and not animal:getCanBeSold() then
					Log:warning("SellEvent:run blocked sell of non-sellable animal (name=%s, uniqueId=%s, farmId=%s)",
						animal.name or "?", animal.uniqueId or "?", animal.farmId or "?")
					connection:sendEvent(AnimalSellEvent.newServerToClient(AnimalSellEvent.SELL_ERROR_CANNOT_BE_SOLD))
					return
				end
				if animal ~= nil then
					-- The client leaves sick animals out, but its disease view can be stale.
					local saleOk, saleReason = RLDiseaseSaleGate.check(animal)
					if not saleOk then
						Log:warning("SellEvent:run blocked sick animal (uniqueId=%s farmId=%s reason=%s userId=%s object=%s)",
							tostring(animal.uniqueId), tostring(animal.farmId), tostring(saleReason), tostring(userId),
							tostring(self.object.getName ~= nil and self.object:getName() or self.object))
						connection:sendEvent(AnimalSellEvent.newServerToClient(AnimalSellEvent.SELL_ERROR_CANNOT_BE_SOLD))
						return
					end
					table.insert(validatedClusters, animal)
				end
			end
		end

		-- Pass 2: queue all validated animals for removal, single flush.
		local ok, err = pcall(function()
			for _, cluster in ipairs(validatedClusters) do
				clusterSystem:addPendingRemoveCluster(cluster)
			end
		end)
		local ok2, err2 = pcall(function() clusterSystem:updateNow() end)

		-- Transaction gate: skip money credit + success notification if anything failed.
		if not (ok and ok2) then
			Log:error("SellEvent:run: removal batch failed N=%d queue=%s flush=%s",
				#validatedClusters, tostring(err), tostring(err2))
			connection:sendEvent(AnimalSellEvent.newServerToClient(AnimalSellEvent.SELL_ERROR_OBJECT_DOES_NOT_EXIST))
			return
		end

		g_currentMission:addMoney(self.price + self.transportPrice, farmId, MoneyType.SOLD_ANIMALS, true, true)
		connection:sendEvent(AnimalSellEvent.newServerToClient(AnimalSellEvent.SELL_SUCCESS))

		-- Object may be a trailer on trailer-based dealer sales; only husbandry
		-- placeables carry addRLMessage.
		if self.object.addRLMessage ~= nil then
			if #self.animals == 1 then
				self.object:addRLMessage("SOLD_ANIMALS_SINGLE", nil, { g_i18n:formatMoney(math.abs(self.price + self.transportPrice), 2, true, true) })
			elseif #self.animals > 0 then
				self.object:addRLMessage("SOLD_ANIMALS_MULTIPLE", nil, { #self.animals, g_i18n:formatMoney(math.abs(self.price + self.transportPrice), 2, true, true) })
			end
		else
			Log:trace("SellEvent:run: skipping addRLMessage (object has no husbandryAnimals spec, likely trailer sale) N=%d", #self.animals)
		end

		Log:debug("SellEvent:run: sold %d animals farmId=%s total=%s",
			#validatedClusters, tostring(farmId), tostring(self.price + self.transportPrice))

	end)

end