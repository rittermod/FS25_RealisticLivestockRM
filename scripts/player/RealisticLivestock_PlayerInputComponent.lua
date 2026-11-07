RealisticLivestock_PlayerInputComponent = {}

local modName = g_currentModName


--- Show the ride or Take straw prompt for the looked-at animal or dewar, after the base update.
--- @param _ number Frame time (unused)
function RealisticLivestock_PlayerInputComponent:update(_)

    self.dewar = nil

    if self.player.isOwner then

        if g_inputBinding:getContextName() == PlayerInputComponent.INPUT_CONTEXT_NAME then

            local currentMission = g_currentMission
            local accessHandler = currentMission.accessHandler
            local vehicleInRange = currentMission.interactiveVehicleInRange
            local canAccess

            if vehicleInRange == nil then
                canAccess = false
            else
                canAccess = accessHandler:canPlayerAccess(vehicleInRange, self.player)
            end

            local vehicleTakesEnter = RLEnterActionPolicy.getVehicleTakesEnter(vehicleInRange, canAccess)

            local closestNode = self.player.targeter:getClosestTargetedNodeFromType(PlayerInputComponent)
            self.player.hudUpdater:setCurrentRaycastTarget(closestNode)

            if not vehicleTakesEnter and closestNode ~= nil then

                local husbandryId, animalId = getAnimalFromCollisionNode(closestNode)

                if husbandryId ~= nil and husbandryId ~= 0 then

                    local clusterHusbandry = currentMission.husbandrySystem:getClusterHusbandryById(husbandryId)
                    if clusterHusbandry ~= nil and not canAccess then
                        local placeable = clusterHusbandry:getPlaceable()
                        local animal = clusterHusbandry:getClusterByAnimalId(animalId, husbandryId)

                        if animal ~= nil and (accessHandler:canFarmAccess(self.player.farmId, placeable) and animal:getRidableFilename() ~= nil) then
                            self.rideablePlaceable = placeable
                            self.rideableCluster = animal

                            local name = animal.getName == nil and "" or animal:getName()
                            local text = string.format(g_i18n:getText("action_rideAnimal"), name)

                            g_inputBinding:setActionEventText(self.enterActionId, text)
                            g_inputBinding:setActionEventActive(self.enterActionId, true)
                        end

                    end

                else

                    local object = g_currentMission:getNodeObject(closestNode)

                    if object ~= nil and object.isDewar == true and object.straws > 0 then

                        self.dewar = object

                        g_inputBinding:setActionEventText(self.enterActionId, g_i18n:getText("rl_ui_takeStraw"))
                        g_inputBinding:setActionEventActive(self.enterActionId, true)

                        if self.rlPromptDewar ~= object then
                            local enterable = vehicleInRange ~= nil and vehicleInRange.spec_enterable ~= nil
                            local vehicleId = nil
                            if vehicleInRange ~= nil and vehicleInRange.getUniqueId ~= nil then
                                vehicleId = vehicleInRange:getUniqueId()
                            end
                            Log:trace("update: Take straw prompt shown, dewar=%s straws=%s"
                                .. " vehicleInRange=%s enterable=%s canAccess=%s",
                                tostring(object:getUniqueId()), tostring(object.straws),
                                tostring(vehicleId), tostring(enterable), tostring(canAccess))
                        end

                    end

                end

            end

        end

    end

    if self.dewar == nil and self.rlPromptDewar ~= nil then
        Log:trace("update: Take straw prompt cleared")
    end
    self.rlPromptDewar = self.dewar

end

PlayerInputComponent.update = Utils.appendedFunction(PlayerInputComponent.update, RealisticLivestock_PlayerInputComponent.update)


--- Take a straw from the targeted dewar: spawn hand tool, decrement count, sync to server.
function RealisticLivestock_PlayerInputComponent:onInputEnter()

    local mission = g_currentMission

    if g_time <= mission.lastInteractionTime + 200 then
        Log:trace("onInputEnter: skipped, within the interaction cooldown")
        return
    end

    local vehicleInRange = mission.interactiveVehicleInRange
    local canAccess = vehicleInRange ~= nil and mission.accessHandler:canPlayerAccess(vehicleInRange, self.player)
    if RLEnterActionPolicy.getVehicleTakesEnter(vehicleInRange, canAccess) then
        Log:trace("onInputEnter: skipped, a usable vehicle took the press")
        return
    end

    if self.rideablePlaceable ~= nil then
        Log:trace("onInputEnter: skipped, a rideable animal took the press")
        return
    end

    if self.dewar == nil then
        Log:trace("onInputEnter: skipped, no dewar targeted")
        return
    end

    if HandToolAIStraw.numHeldStraws > 10 then
        Log:trace("onInputEnter: skipped, holding %d straws already", HandToolAIStraw.numHeldStraws)
        return
    end

    local strawType = g_handToolTypeManager:getTypeByName(modName .. ".aiStraw")
    local handTool = _G[strawType.className].new(g_currentMission:getIsServer(), g_currentMission:getIsClient())

    handTool:setType(strawType)
    handTool:setLoadCallback(self.onFinishedLoadStraw, self, { ["animal"] = self.dewar:getAnimal(), ["dewarUniqueId"] = self.dewar:getUniqueId() })
    handTool:loadNonStoreItem({ ["ownerFarmId"] = g_localPlayer.farmId, ["isRegistered"] = false, ["holder"] = g_localPlayer }, RLHandTools.xmlPaths.aiStraw)

    self.dewar:changeStraws(-1)

    if g_server ~= nil then
        g_server:broadcastEvent(TakeStrawEvent.new(self.dewar))
    elseif g_client ~= nil then
        g_client:getServerConnection():sendEvent(TakeStrawEvent.new(self.dewar))
    end

    Log:debug("onInputEnter: took straw from dewar=%s straws=%d", tostring(self.dewar:getUniqueId()), self.dewar.straws or -1)

end

PlayerInputComponent.onInputEnter = Utils.appendedFunction(PlayerInputComponent.onInputEnter, RealisticLivestock_PlayerInputComponent.onInputEnter)


function PlayerInputComponent:onFinishedLoadStraw(handTool, loadingState, args)

    if loadingState == HandToolLoadingState.OK then
        handTool:setAnimal(args.animal)
        handTool:setDewarUniqueId(args.dewarUniqueId)
    end

end


function RealisticLivestock_PlayerInputComponent.onFinishedRideBlending(superFunc, _, args)
    local placeable = args[1]
    placeable:startRiding(RLAnimalUtil.toShortKey(args[2].farmId, args[2].uniqueId), args[3])
end

PlayerInputComponent.onFinishedRideBlending = Utils.overwrittenFunction(PlayerInputComponent.onFinishedRideBlending, RealisticLivestock_PlayerInputComponent.onFinishedRideBlending)


-- Fix MP horse riding/cleaning: RL identifies animals with a string
-- ("farmId uniqueId"), not the int clusterId the AnimalRidingEvent /
-- AnimalCleanEvent stream signatures expect. Override their write/read to
-- string semantics so the wire format matches what RL ships on the other
-- side.

function AnimalRidingEvent:writeStream(streamId, _)
    NetworkUtil.writeNodeObject(streamId, self.husbandry)
    streamWriteString(streamId, tostring(self.clusterId))
    NetworkUtil.writeNodeObject(streamId, self.player)
end

function AnimalRidingEvent:readStream(streamId, _)
    self.husbandry = NetworkUtil.readNodeObject(streamId)
    self.clusterId = streamReadString(streamId)
    self.player = NetworkUtil.readNodeObject(streamId)
    self:run(nil)
end

function AnimalCleanEvent:writeStream(streamId, _)
    NetworkUtil.writeNodeObject(streamId, self.husbandry)
    streamWriteString(streamId, tostring(self.clusterId))
    streamWriteUIntN(streamId, self.delta, AnimalClusterHorse.NUM_BITS_DIRT)
end

function AnimalCleanEvent:readStream(streamId, connection)
    self.husbandry = NetworkUtil.readNodeObject(streamId)
    self.clusterId = streamReadString(streamId)
    self.delta = streamReadUIntN(streamId, AnimalClusterHorse.NUM_BITS_DIRT)
    self:run(connection)
end

function AnimalCleanEvent:run(connection)
    if self.husbandry ~= nil then
        local cluster = self.husbandry:getClusterById(self.clusterId)
        if cluster ~= nil and cluster.changeDirt ~= nil then
            cluster:changeDirt(-self.delta)
        end
    end

    -- RL Animal:changeDirt() doesn't sync to clients (no raiseUpdate).
    -- If on server, broadcast to all clients so they update their local dirt.
    if connection ~= nil and not connection:getIsServer() then
        g_server:broadcastEvent(AnimalCleanEvent.new(self.husbandry, self.clusterId, self.delta))
    end
end


-- The client reads a horse vehicle's cluster with the base horse-cluster reader, so the server
-- writes an RLRM Animal in that same layout rather than its own.

--- Write a horse vehicle's join stream: ground state, the cluster in base layout, the rider to enter.
---@param streamId number the stream to write
---@param connection table the receiving connection
---@return nil
function Rideable:onWriteStream(streamId, connection)
    local spec = self.spec_rideable

    if not connection:getIsServer() then
        streamWriteBool(streamId, spec.isOnGround)
    end

    local cluster = spec.cluster
    if streamWriteBool(streamId, cluster ~= nil) then
        streamWriteUIntN(streamId, cluster:getSubTypeIndex(), AnimalCluster.NUM_BITS_SUB_TYPE)
        RLRideableClusterStream.write(streamId, cluster)
    else
        Log:trace("Rideable:onWriteStream: no cluster yet, wrote cluster-present false")
    end

    if streamWriteBool(streamId, spec.playerToEnter ~= nil) then
        NetworkUtil.writeNodeObject(streamId, spec.playerToEnter)
    end
end

-- Also fix update stream: RL Animal has no writeUpdateStream method,
-- so provide one matching the AnimalClusterHorse format the client expects.

function Rideable:onWriteUpdateStream(streamId, connection, _)
    local spec = self.spec_rideable
    if connection:getIsServer() then
        streamWriteFloat32(streamId, spec.inputValues.axisSteerSend)
        streamWriteUInt8(streamId, spec.inputValues.currentGait)
    else
        streamWriteFloat32(streamId, spec.haltTimer)
        local cluster = spec.cluster
        if streamWriteBool(streamId, cluster ~= nil) then
            -- Write AnimalClusterHorse update format: fitness, riding, dirt
            streamWriteUIntN(streamId, math.floor(cluster.fitness or 0), AnimalClusterHorse.NUM_BITS_FITNESS)
            streamWriteUIntN(streamId, math.floor(cluster.riding or 0), AnimalClusterHorse.NUM_BITS_RIDING)
            streamWriteUIntN(streamId, math.floor(cluster.dirt or 0), AnimalClusterHorse.NUM_BITS_DIRT)
        end
    end
end