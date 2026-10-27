--[[
    RLLedAlpacaStream.lua
    A led alpaca's cluster on the led vehicle's join and update streams, written from an RLRM Animal in the
    layout the client reads into the DLC's alpaca cluster class: the base cluster part, then the name,
    happiness and fleece. Every integer field is floored and clamped to its slot, since an over-width value
    does not survive the wire. Widths and the pending-spawn flag are read from the classes at call time.
]]

RLLedAlpacaStream = {}

local Log = RmLogging.getLogger("RLRM")


--- Floor a value and clamp it to what an unsigned field of `bits` bits holds.
--- @param value number|nil the value to send; nil sends 0
--- @param bits number field width
--- @return number sent
local function toWidth(value, bits)
    local whole = math.floor(value or 0)
    local max = 2 ^ bits - 1
    if whole <= 0 then return 0 end
    if whole >= max then return max end
    return whole
end


--- Floor a 0-100 value and clamp it to 0-100 and to its field width.
--- @param value number|nil the value to send; nil sends 0
--- @param bits number field width
--- @return number sent
local function toPercent(value, bits)
    local sent = toWidth(value, bits)
    if sent >= 100 then return 100 end
    return sent
end


--- Write the led alpaca's cluster in the client class's full layout.
--- @param streamId number the stream to write
--- @param animal table the vehicle's RLRM Animal
--- @param clusterClass table the client's cluster class (its NUM_BITS_HAPPINESS / NUM_BITS_FLEECE)
--- @return nil
function RLLedAlpacaStream.write(streamId, animal, clusterClass)
    streamWriteUIntN(streamId, toWidth(animal.numAnimals or 1, AnimalCluster.NUM_BITS_NUM_ANIMALS),
        AnimalCluster.NUM_BITS_NUM_ANIMALS)
    local age = toWidth(animal.age, AnimalCluster.NUM_BITS_AGE)
    streamWriteUIntN(streamId, age, AnimalCluster.NUM_BITS_AGE)
    streamWriteUIntN(streamId, toWidth(animal.health, AnimalCluster.NUM_BITS_HEALTH), AnimalCluster.NUM_BITS_HEALTH)
    streamWriteUIntN(streamId, toWidth(animal.reproduction, AnimalCluster.NUM_BITS_REPRODUCTION),
        AnimalCluster.NUM_BITS_REPRODUCTION)

    local withFlag = AnimalCluster.getPendingSpawnWorldPosition ~= nil
    if withFlag then
        local x, y, z, rx, ry, rz = animal:getPendingSpawnWorldPosition()
        if streamWriteBool(streamId, x ~= nil) then
            streamWriteFloat32(streamId, x)
            streamWriteFloat32(streamId, y)
            streamWriteFloat32(streamId, z)
            streamWriteFloat32(streamId, rx)
            streamWriteFloat32(streamId, ry)
            streamWriteFloat32(streamId, rz)
        end
    end

    streamWriteString(streamId, animal.name or "")
    local happiness = toPercent(animal.happiness, clusterClass.NUM_BITS_HAPPINESS)
    local fleece = toPercent(animal.fleeceState, clusterClass.NUM_BITS_FLEECE)
    streamWriteUIntN(streamId, happiness, clusterClass.NUM_BITS_HAPPINESS)
    streamWriteUIntN(streamId, fleece, clusterClass.NUM_BITS_FLEECE)

    Log:debug("LedAlpacaStream: wrote led alpaca layout=%s age=%d happiness=%d fleece=%d (farmId=%s uniqueId=%s)",
        withFlag and "with-flag" or "without-flag", age, happiness, fleece, tostring(animal.farmId),
        tostring(animal.uniqueId))
end


--- Write the led alpaca's update: happiness and fleece.
--- @param streamId number the stream to write
--- @param animal table the vehicle's RLRM Animal
--- @param clusterClass table the client's cluster class (its NUM_BITS_HAPPINESS / NUM_BITS_FLEECE)
--- @return nil
function RLLedAlpacaStream.writeUpdate(streamId, animal, clusterClass)
    local happiness = toPercent(animal.happiness, clusterClass.NUM_BITS_HAPPINESS)
    local fleece = toPercent(animal.fleeceState, clusterClass.NUM_BITS_FLEECE)
    streamWriteUIntN(streamId, happiness, clusterClass.NUM_BITS_HAPPINESS)
    streamWriteUIntN(streamId, fleece, clusterClass.NUM_BITS_FLEECE)

    Log:trace("LedAlpacaStream: wrote led alpaca update happiness=%d fleece=%d (farmId=%s uniqueId=%s)",
        happiness, fleece, tostring(animal.farmId), tostring(animal.uniqueId))
end
