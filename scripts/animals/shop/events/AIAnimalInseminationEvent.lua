AIAnimalInseminationEvent = {}

local AIAnimalInseminationEvent_mt = Class(AIAnimalInseminationEvent, Event)
InitEventClass(AIAnimalInseminationEvent, "AIAnimalInseminationEvent")


function AIAnimalInseminationEvent.emptyNew()

    local self = Event.new(AIAnimalInseminationEvent_mt)
    return self

end


function AIAnimalInseminationEvent.new(object, items)

	local event = AIAnimalInseminationEvent.emptyNew()

	event.object = object
	event.items = items

	return event

end


--- Server-context check, factored out so the in-game rlTest can swap it without mutating the root
--- g_server global (rlTest cannot reassign a root g_*, only a level below it - so run()'s
--- server-vs-pure-client branch is driven through this function). Production reads g_server.
--- @return boolean true if this process is the authoritative server
function AIAnimalInseminationEvent.isServer()
	return g_server ~= nil
end


function AIAnimalInseminationEvent:readStream(streamId, connection)

	self.object = NetworkUtil.readNodeObject(streamId)
	local numItems = streamReadUInt16(streamId)

	self.items = {}

	for i = 1, numItems do

		local identifiers = RLAnimalUtil.readStreamIdentifiers(streamId, connection)
		local dewar = NetworkUtil.readNodeObject(streamId)

		self.items[i] = { ["animal"] = identifiers, ["dewar"] = dewar }
		Log:trace("AIInseminationEvent:readStream item=%d dewar=%s", i, tostring(dewar))

	end

	self:run(connection)

end


function AIAnimalInseminationEvent:writeStream(streamId, connection)

	NetworkUtil.writeNodeObject(streamId, self.object)

	streamWriteUInt16(streamId, #self.items)

	-- Dense array (ipairs): the #self.items written here must equal numItems read back. Every
	-- producer emits a dense items array (dialog: one item; herdsman/executor: 1:1 with count;
	-- run()'s rebroadcast: the dense `applied` subset), so ipairs and #self.items always agree.
	for _, item in ipairs(self.items) do

		RLAnimalUtil.writeStreamIdentifiers(item.animal, streamId, connection)
		NetworkUtil.writeNodeObject(streamId, item.dewar)
		Log:trace("AIInseminationEvent:writeStream dewar=%s (node object)", tostring(item.dewar))

	end

end


--- Execute the event on the receiver. Server-authoritative apply + straw decrement.
---
--- Two orthogonal axes decide behavior:
---   * onServer (`g_server ~= nil`): authoritative. Validates each item with
---     getCanBeInseminatedByAnimal, and owns setInsemination + the straw decrement.
---     True on the dedi/host server branch AND on the herdsman loopback - which
---     `broadcastEvent(event, true)` runs through the CLIENT branch (its reverse
---     local connection is isServer=true), so the decrement gates on onServer, not
---     on the branch.
---   * isServerBranch (`not connection:getIsServer()`): the event arrived from a
---     REMOTE client - the menu path. Only then do we rebroadcast the applied
---     subset to the other clients, excluding the sender (Pattern A), so a client
---     never applies a server-rejected item.
--- A pure client (`g_server == nil`) only mirrors setInsemination for prompt
--- visibility (idempotent, no decrement); the dewar dirty-sync delivers the
--- absolute straw count, so clients never race the server on the count.
---@param connection table Network connection the event arrived on
function AIAnimalInseminationEvent:run(connection)

	RmSafeUtils.safeCall("AIAnimalInseminationEvent:run", function()

		local clusterSystem = self.object:getClusterSystem()
		local farmId = self.object:getOwnerFarmId()

		local onServer = AIAnimalInseminationEvent.isServer()
		local isServerBranch = not connection:getIsServer()
		Log:trace("AIInseminationEvent:run onServer=%s branch=%s items=%d",
			tostring(onServer), isServerBranch and "server" or "client", #self.items)

		local applied = {}

		for _, item in ipairs(self.items) do

			local dewar = item.dewar
			local id = item.animal

			if dewar == nil or dewar.animal == nil or dewar.straws <= 0 then

				-- changeStraws auto-deletes a dewar at 0 straws, so a resolved-but-emptied dewar
				-- is a live Lua table with animal/straws cleared - key the guard on those, not identity.
				Log:warning("AIInseminationEvent:run skip: dewar nil/emptied/deleted (dewar=%s) uniqueId=%s",
					tostring(dewar), tostring(id and id.uniqueId))

			elseif dewar:getOwnerFarmId() ~= farmId then

				Log:warning("AIInseminationEvent:run skip: dewar farm %s ~= husbandry farm %s uniqueId=%s",
					tostring(dewar:getOwnerFarmId()), tostring(farmId), tostring(id.uniqueId))

			else

				local animal = RLAnimalUtil.find(clusterSystem.animals, id.farmId, id.uniqueId, id.country or id.birthday.country)

				if onServer then

					if animal == nil then
						-- The animal is gone but the straw was spent - decrement the resolved dewar.
						dewar:changeStraws(-1)
						Log:warning("AIInseminationEvent:run animal not found (still decrementing) uniqueId=%s",
							tostring(id.uniqueId))
					elseif not animal:getCanBeInseminatedByAnimal(dewar.animal) then
						-- Authoritative eligibility gate (type/gender/pregnancy/already-inseminated/age/
						-- incest): reject without applying or spending; not added to the rebroadcast subset.
						Log:debug("AIInseminationEvent:run reject ineligible uniqueId=%s", tostring(id.uniqueId))
					else
						animal:setInsemination(dewar.animal)
						dewar:changeStraws(-1)
						applied[#applied + 1] = item
						Log:info("AIInseminationEvent:run applied uniqueId=%s dewar=%s",
							tostring(id.uniqueId), tostring(dewar:getUniqueId()))
					end

				elseif animal ~= nil and animal.insemination == nil then

					-- Pure client: trust the server, mirror setInsemination for prompt visibility only.
					-- No re-validation (divergent client state must not reach a different verdict) and
					-- no straw decrement (the dewar dirty-sync carries the absolute count).
					animal:setInsemination(dewar.animal)
					Log:debug("AIInseminationEvent:run client-applied uniqueId=%s", tostring(id.uniqueId))

				else

					Log:trace("AIInseminationEvent:run client-skip uniqueId=%s animal=%s inseminated=%s",
						tostring(id.uniqueId), tostring(animal), tostring(animal ~= nil and animal.insemination ~= nil))

				end

			end

		end

		if isServerBranch and #applied > 0 then
			-- Menu path (arrived from a REMOTE client): rebroadcast ONLY the server-applied subset,
			-- excluding the sender (which already mutated optimistically before sendEvent). The
			-- herdsman path does not reach here (its loopback takes the client branch), so its remote
			-- clients apply the full broadcast optimistically and self-heal via the full animal sync.
			g_server:broadcastEvent(
				AIAnimalInseminationEvent.new(self.object, applied),
				nil, connection, nil)
			Log:trace("AIInseminationEvent:run rebroadcast applied=%d ignoreConnection=sender", #applied)
		end

	end)

end


--- Thin dispatch: broadcast to clients if we are the server, otherwise send to the
--- server. Preserve the two-producer asymmetry (do NOT unify): the DIALOG caller
--- (AnimalAIDialog:onClickOk) pre-mutates local dewar + animal and calls this with NO
--- sendLocal (so a listen-server host never runs run() locally - the pre-mutation is its
--- sole apply); the HERDSMAN caller (RLHerdsmanExecutor._doAi / legacy AIAnimalManager, removed 1.3.2.0)
--- does NOT pre-mutate and broadcasts with sendLocal=true, applying server-side through
--- the loopback client branch.
---@param object table Husbandry placeable
---@param items table Array of { animal = identifiers|Animal, dewar = <live dewar node object> }
function AIAnimalInseminationEvent.sendEvent(object, items)
    if g_server ~= nil then
        g_server:broadcastEvent(AIAnimalInseminationEvent.new(object, items))
    else
        g_client:getServerConnection():sendEvent(AIAnimalInseminationEvent.new(object, items))
    end
end
