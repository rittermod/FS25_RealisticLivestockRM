--[[
    RLLedAlpacaHooks.lua
    Lets the Beans and Alpacas DLC lead an RLRM alpaca out of its shed and back. The led vehicle keeps the RLRM
    Animal on the server, reloads it from a save, and writes it on its streams in the client's cluster layout;
    the lead request carries the animal as its identity key; the leash and the shearing tool find a pen animal
    by its husbandry id. Installed from the animal system's map load, only for the DLC tables that exist.
]]

RLLedAlpacaHooks = {}

local Log = RmLogging.getLogger("RLRM")

--- The DLC's mod name, the prefix of every class this module hooks.
RLLedAlpacaHooks.DLC_MOD_NAME = "pdlc_beansAndAlpacasPack"

-- The DLC tables resolved at install, each replaced function's original, and the table each was installed on.
local captured = {}
local original = {}
local installedOn = {}


--- A DLC class table by name through the real ClassUtil; a mod environment's own ClassUtil cannot resolve one.
--- @param className string class name inside the DLC
--- @return table|nil classObject
local function getDlcClass(className)
    local envMt = getmetatable(_G)
    local realG = envMt and envMt.__index or _G
    local classUtil = realG.ClassUtil
    if classUtil == nil or classUtil.getClassObject == nil then
        Log:trace("RLLedAlpacaHooks: no ClassUtil.getClassObject, '%s' unresolved", className)
        return nil
    end
    local classObject = classUtil.getClassObject(RLLedAlpacaHooks.DLC_MOD_NAME .. "." .. className)
    if type(classObject) ~= "table" then
        Log:trace("RLLedAlpacaHooks: '%s' does not resolve", className)
        return nil
    end
    return classObject
end


--- Put `replacement` at tbl[key] once per table, remembering the function it replaced; a re-install changes nothing.
--- @param tbl table the class or spec table
--- @param key string the function name
--- @param label string the original's name in this module
--- @param replacement function the replacement
--- @return boolean installed false when it was already installed
local function replace(tbl, key, label, replacement)
    if tbl[key] == replacement then
        Log:trace("RLLedAlpacaHooks: %s already installed", label)
        return false
    end
    if installedOn[label] == tbl then
        Log:trace("RLLedAlpacaHooks: %s already installed and wrapped since, left as it is", label)
        return false
    end
    installedOn[label] = tbl
    original[label] = tbl[key]
    tbl[key] = replacement
    return true
end


--- The led vehicle's spec state.
--- @param vehicle table the led vehicle
--- @return table spec
local function vehicleSpec(vehicle)
    return vehicle[captured.animalSpec.SPEC_TABLE_NAME]
end


-- =============================================================================
-- LED VEHICLE
-- =============================================================================

--- The led vehicle's load: the DLC's load, then on the server the RLRM Animal from the save, detached.
--- @param self table the led vehicle
--- @param savegame table|nil { xmlFile, key } when loading from a save
--- @return nil
function RLLedAlpacaHooks.vehicleOnLoad(self, savegame)
    original.onLoad(self, savegame)

    if not self.isServer then
        Log:trace("RLLedAlpacaHooks.vehicleOnLoad: not the server, the DLC's cluster stands")
        return
    end
    local cluster = vehicleSpec(self).cluster
    if cluster == nil then
        Log:trace("RLLedAlpacaHooks.vehicleOnLoad: no cluster after the DLC's load, nothing more")
        return
    end

    local branch = "spawn"
    if savegame ~= nil then
        local key = savegame.key .. "." .. captured.animalSpec.SPEC_NAME .. ".animal"
        -- Only an RLRM save writes the subtype on the animal node; a save from before RLRM keeps the DLC's cluster.
        local animal = nil
        local hasRlrmData = savegame.xmlFile:hasProperty(key .. "#subType")
        if hasRlrmData then
            animal = Animal.loadFromXMLFile(savegame.xmlFile, key)
        else
            Log:trace("RLLedAlpacaHooks.vehicleOnLoad: no #subType at %s, not an RLRM save", key)
        end
        if animal ~= nil and animal.uniqueId ~= nil then
            self:setCluster(animal)
            cluster = animal
            branch = "reload"
        elseif hasRlrmData then
            branch = "RLRM save without an identity, the DLC's cluster kept"
        else
            branch = "save without RLRM data, the DLC's cluster kept"
        end
    end

    if cluster.isIndividual then
        cluster:setClusterSystem(nil)
    end
    Log:debug("RLLedAlpacaHooks.vehicleOnLoad: %s (farmId=%s uniqueId=%s individual=%s)", branch,
        tostring(cluster.farmId), tostring(cluster.uniqueId), tostring(cluster.isIndividual == true))
end


--- The led vehicle's join stream: an RLRM Animal in the client's cluster layout, anything else as the DLC writes it.
--- @param self table the led vehicle
--- @param streamId number the stream to write
--- @param connection table the receiving connection
--- @return nil
function RLLedAlpacaHooks.vehicleOnWriteStream(self, streamId, connection)
    local cluster = vehicleSpec(self).cluster
    if cluster == nil or not cluster.isIndividual then
        Log:trace("RLLedAlpacaHooks.vehicleOnWriteStream: no RLRM Animal, the DLC's writer")
        return original.onWriteStream(self, streamId, connection)
    end
    streamWriteBool(streamId, true)
    streamWriteUIntN(streamId, cluster:getSubTypeIndex(), AnimalCluster.NUM_BITS_SUB_TYPE)
    RLLedAlpacaStream.write(streamId, cluster, captured.alpacaClass)
end


--- The led vehicle's update stream: an RLRM Animal's happiness and fleece toward a client, else the DLC's writer.
--- @param self table the led vehicle
--- @param streamId number the stream to write
--- @param connection table the receiving connection
--- @param dirtyMask number the vehicle's dirty mask
--- @return nil
function RLLedAlpacaHooks.vehicleOnWriteUpdateStream(self, streamId, connection, dirtyMask)
    local cluster = vehicleSpec(self).cluster
    if cluster == nil or not cluster.isIndividual then
        Log:trace("RLLedAlpacaHooks.vehicleOnWriteUpdateStream: no RLRM Animal, the DLC's writer")
        return original.onWriteUpdateStream(self, streamId, connection, dirtyMask)
    end
    if connection:getIsServer() then
        Log:trace("RLLedAlpacaHooks.vehicleOnWriteUpdateStream: toward the server, nothing written")
        return
    end
    streamWriteBool(streamId, true)
    RLLedAlpacaStream.writeUpdate(streamId, cluster, captured.alpacaClass)
end


-- =============================================================================
-- LEAD REQUEST (codec only: the animal travels as its identity key)
-- =============================================================================

--- The identity key of the animal a lead request names, or "" when the pen holds no such animal.
--- @param husbandry table|nil the pen the request names
--- @param clusterId any the request's animal id
--- @return string key
function RLLedAlpacaHooks.resolveLeadKey(husbandry, clusterId)
    local spec = husbandry ~= nil and husbandry.spec_husbandryAnimals or nil
    local animal = nil
    if spec ~= nil and spec.clusterSystem ~= nil then
        animal = spec.clusterSystem:getClusterById(clusterId)
    end
    if animal == nil then
        Log:warning("AnimalLeadingEvent: no animal '%s' in husbandry '%s', the lead request names none",
            tostring(clusterId), tostring(husbandry ~= nil and husbandry.getName ~= nil and husbandry:getName()
                or husbandry))
        return ""
    end
    local key = RLAnimalUtil.resolveClusterId(animal)
    return key ~= nil and tostring(key) or ""
end


--- Write a lead request with the animal as its identity key; every other field keeps its type and order.
--- @param self table the event
--- @param streamId number the stream to write
--- @param connection table the receiving connection
--- @return nil
function RLLedAlpacaHooks.leadingEventWriteStream(self, streamId, connection)
    NetworkUtil.writeNodeObject(streamId, self.husbandry)
    local key = RLLedAlpacaHooks.resolveLeadKey(self.husbandry, self.clusterId)
    streamWriteString(streamId, key)
    NetworkUtil.writeNodeObject(streamId, self.player)
    streamWriteFloat32(streamId, self.x)
    streamWriteFloat32(streamId, self.y)
    streamWriteFloat32(streamId, self.z)
    streamWriteFloat32(streamId, self.rx)
    streamWriteFloat32(streamId, self.ry)
    streamWriteFloat32(streamId, self.rz)
    Log:debug("AnimalLeadingEvent:writeStream: id '%s' -> key '%s'", tostring(self.clusterId), key)
end


--- Read a lead request whose animal travels as its identity key, then run it.
--- @param self table the event
--- @param streamId number the stream to read
--- @param connection table the sending connection
--- @return nil
function RLLedAlpacaHooks.leadingEventReadStream(self, streamId, connection)
    self.husbandry = NetworkUtil.readNodeObject(streamId)
    self.clusterId = streamReadString(streamId)
    self.player = NetworkUtil.readNodeObject(streamId)
    self.x = streamReadFloat32(streamId)
    self.y = streamReadFloat32(streamId)
    self.z = streamReadFloat32(streamId)
    self.rx = streamReadFloat32(streamId)
    self.ry = streamReadFloat32(streamId)
    self.rz = streamReadFloat32(streamId)
    Log:debug("AnimalLeadingEvent:readStream: key '%s'", tostring(self.clusterId))
    self:run(connection)
end


-- =============================================================================
-- LEASH AND SHEARING TOOL (the looked-at pen animal)
-- =============================================================================

--- The pen and the RLRM animal a collision node shows, or nil when the node is not a pen animal.
--- @param node number the targeted collision node
--- @return table|nil placeable
--- @return table|nil animal
local function penAnimalFromNode(node)
    local husbandryId, animalId = getAnimalFromCollisionNode(node)
    if husbandryId == nil or husbandryId == 0 then
        return nil, nil
    end
    local clusterHusbandry = g_currentMission.husbandrySystem:getClusterHusbandryById(husbandryId)
    if clusterHusbandry == nil then
        return nil, nil
    end
    -- One RLRM pen holds several engine husbandries whose animal ids repeat, so the lookup needs the husbandry id.
    return clusterHusbandry:getPlaceable(), clusterHusbandry:getClusterByAnimalId(animalId, husbandryId)
end


--- The pen and alpaca the leash targets: an animal the player's farm may use and the pen may lead.
--- @param carryingPlayer table the player holding the leash
--- @param targetNode number the targeted collision node
--- @return table|nil husbandry
--- @return table|nil animal
function RLLedAlpacaHooks.getTargetedHusbandryAlpaca(carryingPlayer, targetNode)
    local placeable, animal = penAnimalFromNode(targetNode)
    if placeable == nil or animal == nil then
        Log:trace("RLLedAlpacaHooks.getTargetedHusbandryAlpaca: no pen animal at the node")
        return nil, nil
    end
    if not g_currentMission.accessHandler:canFarmAccess(carryingPlayer.farmId, placeable) then
        Log:trace("RLLedAlpacaHooks.getTargetedHusbandryAlpaca: farm %s may not use this pen",
            tostring(carryingPlayer.farmId))
        return nil, nil
    end
    local leadable = placeable.getAnimalSupportsLeading ~= nil and placeable:getAnimalSupportsLeading(animal.id)
    Log:trace("RLLedAlpacaHooks.getTargetedHusbandryAlpaca: farmId=%s uniqueId=%s leadable=%s",
        tostring(animal.farmId), tostring(animal.uniqueId), tostring(leadable))
    if not leadable then
        return nil, nil
    end
    return placeable, animal
end


--- The pen alpaca the shearing tool looks at, when the pen could lead it.
--- @param node number the targeted collision node
--- @return table|nil animal
function RLLedAlpacaHooks.getLeadableAlpacaCluster(node)
    local placeable, animal = penAnimalFromNode(node)
    if placeable == nil or placeable.getAnimalSupportsLeading == nil or animal == nil then
        Log:trace("RLLedAlpacaHooks.getLeadableAlpacaCluster: no leadable pen animal at the node")
        return nil
    end
    if not placeable:getAnimalSupportsLeading(animal.id) then
        Log:trace("RLLedAlpacaHooks.getLeadableAlpacaCluster: farmId=%s uniqueId=%s not leadable",
            tostring(animal.farmId), tostring(animal.uniqueId))
        return nil
    end
    return animal
end


-- =============================================================================
-- INSTALL
-- =============================================================================

--- Install every hook whose DLC table exists; a missing table skips its hooks. Safe to call again.
--- @return nil
function RLLedAlpacaHooks.install()
    local installed = {}
    local animalSpec = getDlcClass("Animal")
    local alpacaClass = getDlcClass("AnimalClusterAlpaca")

    if animalSpec == nil then
        Log:debug("RLLedAlpacaHooks.install: no DLC Animal spec, the led vehicle hooks skip")
    else
        captured.animalSpec = animalSpec
        replace(animalSpec, "onLoad", "onLoad", RLLedAlpacaHooks.vehicleOnLoad)
        installed[#installed + 1] = "vehicle onLoad"
        if alpacaClass == nil then
            Log:debug("RLLedAlpacaHooks.install: no DLC AnimalClusterAlpaca, the led vehicle stream hooks skip")
        else
            captured.alpacaClass = alpacaClass
            replace(animalSpec, "onWriteStream", "onWriteStream", RLLedAlpacaHooks.vehicleOnWriteStream)
            replace(animalSpec, "onWriteUpdateStream", "onWriteUpdateStream",
                RLLedAlpacaHooks.vehicleOnWriteUpdateStream)
            installed[#installed + 1] = "vehicle streams"
        end
    end

    local leadingEvent = getDlcClass("AnimalLeadingEvent")
    if leadingEvent == nil then
        Log:debug("RLLedAlpacaHooks.install: no DLC AnimalLeadingEvent, the lead request codec skips")
    else
        replace(leadingEvent, "writeStream", "eventWriteStream", RLLedAlpacaHooks.leadingEventWriteStream)
        replace(leadingEvent, "readStream", "eventReadStream", RLLedAlpacaHooks.leadingEventReadStream)
        installed[#installed + 1] = "lead request codec"
    end

    local leash = getDlcClass("HandToolLeash")
    if leash == nil then
        Log:debug("RLLedAlpacaHooks.install: no DLC HandToolLeash, the leash lookup skips")
    else
        replace(leash, "getTargetedHusbandryAlpaca", "getTargetedHusbandryAlpaca",
            RLLedAlpacaHooks.getTargetedHusbandryAlpaca)
        installed[#installed + 1] = "leash lookup"
    end

    local shearingMachine = getDlcClass("HandToolShearingMachine")
    if shearingMachine == nil then
        Log:debug("RLLedAlpacaHooks.install: no DLC HandToolShearingMachine, the shearing tool lookup skips")
    else
        replace(shearingMachine, "getLeadableAlpacaCluster", "getLeadableAlpacaCluster",
            RLLedAlpacaHooks.getLeadableAlpacaCluster)
        installed[#installed + 1] = "shearing tool lookup"
    end

    Log:debug("RLLedAlpacaHooks.install: %d hook group(s): %s", #installed,
        #installed > 0 and table.concat(installed, ", ") or "none")
end
