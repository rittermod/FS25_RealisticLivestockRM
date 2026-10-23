--[[
    DewarData.lua

    Vehicle specialization for the dewar (semen container).
    Replaces the old PhysicsObject-based Dewar.lua with a proper Vehicle/pallet
    that gets engine-provided physics, network sync, pickup, and persistence for free.

    Requires parent type "pallet" (Pallet specialization).

    NOTE: Vehicle base already provides getUniqueId/setUniqueId (self.uniqueId).
    We use Vehicle's built-in uniqueId field directly -- no spec.uniqueId needed.
]]

local Log = RmLogging.getLogger("RLRM")

DewarData = {}

DewarData.SPEC_TABLE_NAME = "spec_FS25_RealisticLivestockRM.dewarData"
DewarData.CAPACITY = 1000
DewarData.PRICE_PER_STRAW = 0.85


function DewarData.prerequisitesPresent(specializations)
    return SpecializationUtil.hasSpecialization(Pallet, specializations)
end


function DewarData.registerFunctions(vehicleType)
    -- getUniqueId/setUniqueId are on Vehicle base -- do NOT register here
    SpecializationUtil.registerFunction(vehicleType, "setAnimal", DewarData.setAnimal)
    SpecializationUtil.registerFunction(vehicleType, "getAnimal", DewarData.getAnimal)
    SpecializationUtil.registerFunction(vehicleType, "setStraws", DewarData.setStraws)
    SpecializationUtil.registerFunction(vehicleType, "changeStraws", DewarData.changeStraws)
end


function DewarData.registerOverwrittenFunctions(vehicleType)
    -- showInfo is on Vehicle base -- override, not register
    SpecializationUtil.registerOverwrittenFunction(vehicleType, "showInfo", DewarData.showInfo)
end


function DewarData.registerEventListeners(vehicleType)
    SpecializationUtil.registerEventListener(vehicleType, "onLoad", DewarData)
    SpecializationUtil.registerEventListener(vehicleType, "onDelete", DewarData)
    SpecializationUtil.registerEventListener(vehicleType, "onReadStream", DewarData)
    SpecializationUtil.registerEventListener(vehicleType, "onWriteStream", DewarData)
    SpecializationUtil.registerEventListener(vehicleType, "onReadUpdateStream", DewarData)
    SpecializationUtil.registerEventListener(vehicleType, "onWriteUpdateStream", DewarData)
    SpecializationUtil.registerEventListener(vehicleType, "saveToXMLFile", DewarData)
end


-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

function DewarData:onLoad(savegame)
    local spec = self[DewarData.SPEC_TABLE_NAME]
    spec.animal = nil
    spec.straws = 0
    spec.texts = {}
    spec.dirtyFlag = self:getNextDirtyFlag()
    spec.isRegistered = false

    -- Resolve 3D text parent nodes via component hierarchy
    -- i3d structure: component1 > dewarMesh > stickyNote_animal (child 0), stickyNote_straws (child 1)
    local componentNode = self.components[1].node
    local meshNode = getChildAt(componentNode, 0)
    if meshNode ~= nil and meshNode ~= 0 then
        spec.stickyNoteAnimal = getChildAt(meshNode, 0)
        spec.stickyNoteStraws = getChildAt(meshNode, 1)
    else
        spec.stickyNoteAnimal = nil
        spec.stickyNoteStraws = nil
        Log:warning("DewarData:onLoad could not resolve mesh node for 3D text")
    end

    -- Compatibility properties on the vehicle table for consumer access
    -- (self.uniqueId is managed by Vehicle base via setUniqueId/getUniqueId)
    self.isDewar = true
    self.animal = nil
    self.straws = 0

    -- Load from savegame if available
    if savegame ~= nil and savegame.xmlFile ~= nil then
        local key = savegame.key .. ".FS25_RealisticLivestockRM.dewarData"
        if savegame.xmlFile:hasProperty(key) then
            DewarData.loadDewarFromSavegame(self, savegame.xmlFile, key)
        end
    end

    Log:debug("DewarData:onLoad vehicle=%s uniqueId=%s straws=%d",
        tostring(self.rootNode), tostring(self:getUniqueId()), spec.straws)
end


function DewarData:onDelete()
    local spec = self[DewarData.SPEC_TABLE_NAME]

    if spec.isRegistered then
        g_dewarManager:removeDewar(self:getOwnerFarmId(), self)
        spec.isRegistered = false
    end

    -- Clean up 3D text overlays
    if spec.texts.straws ~= nil then
        RealisticLivestock.delete3DLinkedText(spec.texts.straws)
        spec.texts.straws = nil
    end
    if spec.texts.animal ~= nil then
        RealisticLivestock.delete3DLinkedText(spec.texts.animal)
        spec.texts.animal = nil
    end

    Log:info("DewarData:onDelete uniqueId=%s", tostring(self:getUniqueId()))
end


-- ---------------------------------------------------------------------------
-- Savegame persistence
-- ---------------------------------------------------------------------------

--- Restore straws and semen record; an unresolved record zeroes the straws so the empty-dewar delete runs.
---@param xmlFile table XMLFile object
---@param key string path of the dewarData element
function DewarData:loadDewarFromSavegame(xmlFile, key)
    local spec = self[DewarData.SPEC_TABLE_NAME]

    local uniqueId = xmlFile:getString(key .. "#uniqueId")
    if uniqueId ~= nil then
        self:setUniqueId(uniqueId)
    end
    spec.straws = xmlFile:getInt(key .. "#straws") or 0

    local animal, reason, ref = RLSemenRecordCodec.read(xmlFile, key, g_currentMission.animalSystem)
    if animal ~= nil then
        spec.animal = animal
        DewarData.syncCompatProperties(self)
        DewarData.registerWithManager(self)
    elseif reason ~= nil then
        local animalKey = key .. ".animal"
        Log:warning("DewarData:loadDewarFromSavegame: removing dewar uniqueId=%s, its semen record's %s does not "
            .. "resolve (%s) (typeName=%s subTypeName=%s typeIndex=%s subTypeIndex=%s)",
            tostring(self:getUniqueId()), tostring(ref), tostring(reason),
            tostring(xmlFile:getString(animalKey .. "#typeName")),
            tostring(xmlFile:getString(animalKey .. "#subTypeName")),
            tostring(xmlFile:getInt(animalKey .. "#typeIndex")),
            tostring(xmlFile:getInt(animalKey .. "#subTypeIndex")))
        spec.straws = 0
    else
        Log:trace("DewarData:loadDewarFromSavegame: uniqueId=%s carries no semen record",
            tostring(self:getUniqueId()))
    end

    -- Mirror straws even if no animal
    self.straws = spec.straws

    Log:info("DewarData:loadDewarFromSavegame uniqueId=%s farmId=%d straws=%d animal=%s",
        tostring(self:getUniqueId()), self:getOwnerFarmId(), spec.straws,
        spec.animal and tostring(spec.animal.typeIndex) or "nil")

    DewarData.updateStrawVisuals(self)
    DewarData.updateAnimalVisuals(self)

    -- Zero-straw zombie cleanup at load time.
    -- Direct self:delete() here is unsafe because the vehicle is still
    -- mid-load - synchronous delete would leave subsequent spec callbacks
    -- firing on a partially-torn vehicle. Defer via Timer.createOneshot(0, ...)
    -- so cleanup runs after the load chain completes - the same idiom
    -- RLMessageAggregator uses for post-day-change consolidation.
    if g_server ~= nil and spec.straws <= 0 then
        Log:warning("DewarData:loadDewarFromSavegame zombie uniqueId=%s straws=%d, scheduling deferred delete",
            tostring(self:getUniqueId()), spec.straws)
        local target = self
        Timer.createOneshot(0, function()
            if target ~= nil and target.isDeleted ~= true then
                Log:info("DewarData:loadDewarFromSavegame deferred-delete fired uniqueId=%s",
                    tostring(target:getUniqueId()))
                target:delete()
            end
        end)
    end
end


--- Write the dewar's straw count and semen record into its vehicle savegame block.
---@param xmlFile table XMLFile object
---@param key string path of the dewarData element
---@param usedModNames table|nil unused
function DewarData:saveToXMLFile(xmlFile, key, usedModNames)
    local spec = self[DewarData.SPEC_TABLE_NAME]

    local dewarUniqueId = self:getUniqueId()
    if dewarUniqueId ~= nil then
        xmlFile:setString(key .. "#uniqueId", dewarUniqueId)
    end
    xmlFile:setInt(key .. "#straws", spec.straws)

    if spec.animal ~= nil then
        RLSemenRecordCodec.write(xmlFile, key, spec.animal, g_currentMission.animalSystem)
    else
        Log:trace("DewarData:saveToXMLFile: uniqueId=%s has no semen record", tostring(dewarUniqueId))
    end
end


-- ---------------------------------------------------------------------------
-- Network serialization - full sync (client join)
-- ---------------------------------------------------------------------------

function DewarData:onWriteStream(streamId, connection)
    local spec = self[DewarData.SPEC_TABLE_NAME]

    streamWriteUInt16(streamId, spec.straws)
    streamWriteBool(streamId, spec.animal ~= nil)

    if spec.animal ~= nil then
        local animal = spec.animal
        streamWriteUInt8(streamId, animal.country)
        streamWriteString(streamId, animal.farmId)
        streamWriteString(streamId, animal.uniqueId)
        streamWriteString(streamId, animal.name or "")
        streamWriteUInt8(streamId, animal.typeIndex)
        streamWriteUInt8(streamId, animal.subTypeIndex)
        streamWriteFloat32(streamId, animal.success)
        streamWriteFloat32(streamId, animal.genetics.metabolism)
        streamWriteFloat32(streamId, animal.genetics.fertility)
        streamWriteFloat32(streamId, animal.genetics.health)
        streamWriteFloat32(streamId, animal.genetics.quality)
        streamWriteFloat32(streamId, animal.genetics.productivity or -1)
    end

    Log:trace("DewarData:onWriteStream uniqueId=%s straws=%d hasAnimal=%s",
        tostring(self:getUniqueId()), spec.straws, tostring(spec.animal ~= nil))
end


function DewarData:onReadStream(streamId, connection)
    local spec = self[DewarData.SPEC_TABLE_NAME]

    spec.straws = streamReadUInt16(streamId)

    local hasAnimal = streamReadBool(streamId)
    if hasAnimal then
        local animal = { genetics = {} }
        animal.country = streamReadUInt8(streamId)
        animal.farmId = streamReadString(streamId)
        animal.uniqueId = streamReadString(streamId)
        animal.name = streamReadString(streamId)
        animal.typeIndex = streamReadUInt8(streamId)
        animal.subTypeIndex = streamReadUInt8(streamId)
        animal.success = streamReadFloat32(streamId)
        animal.genetics.metabolism = streamReadFloat32(streamId)
        animal.genetics.fertility = streamReadFloat32(streamId)
        animal.genetics.health = streamReadFloat32(streamId)
        animal.genetics.quality = streamReadFloat32(streamId)
        animal.genetics.productivity = streamReadFloat32(streamId)
        if animal.genetics.productivity < 0 then animal.genetics.productivity = nil end

        spec.animal = animal
    end

    DewarData.syncCompatProperties(self)
    if spec.animal ~= nil then
        DewarData.registerWithManager(self)
    end

    DewarData.updateStrawVisuals(self)
    DewarData.updateAnimalVisuals(self)

    Log:info("DewarData:onReadStream uniqueId=%s straws=%d hasAnimal=%s",
        tostring(self:getUniqueId()), spec.straws, tostring(hasAnimal))
end


-- ---------------------------------------------------------------------------
-- Network serialization - update stream (mid-game dirty flag sync)
-- ---------------------------------------------------------------------------

function DewarData:onWriteUpdateStream(streamId, connection, dirtyMask)
    local spec = self[DewarData.SPEC_TABLE_NAME]

    if not connection:getIsServer() then
        if streamWriteBool(streamId, bitAND(dirtyMask, spec.dirtyFlag) ~= 0) then
            streamWriteUInt16(streamId, spec.straws)
            Log:trace("DewarData:onWriteUpdateStream straws=%d", spec.straws)
        end
    end
end


function DewarData:onReadUpdateStream(streamId, timestamp, connection)
    local spec = self[DewarData.SPEC_TABLE_NAME]

    if connection:getIsServer() then
        if streamReadBool(streamId) then
            spec.straws = streamReadUInt16(streamId)
            self.straws = spec.straws
            DewarData.updateStrawVisuals(self)
            Log:trace("DewarData:onReadUpdateStream straws=%d", spec.straws)
        end
    end
end


-- ---------------------------------------------------------------------------
-- Public API (consumer-compatible names)
-- ---------------------------------------------------------------------------
-- NOTE: getUniqueId/setUniqueId are provided by Vehicle base class.
-- Consumers call dewar:getUniqueId() which returns self.uniqueId (Vehicle field).

function DewarData:getAnimal()
    return self[DewarData.SPEC_TABLE_NAME].animal
end


function DewarData:setAnimal(animal)
    local spec = self[DewarData.SPEC_TABLE_NAME]

    -- Accept either a live Animal object or a raw table
    if animal.birthday ~= nil then
        -- Live Animal object - extract snapshot
        spec.animal = {
            ["country"] = animal.birthday.country,
            ["farmId"] = animal.farmId,
            ["uniqueId"] = animal.uniqueId,
            ["name"] = animal:getName(),
            ["typeIndex"] = animal.animalTypeIndex,
            ["subTypeIndex"] = animal.subTypeIndex,
            ["genetics"] = table.clone(animal.genetics, 3),
            ["success"] = animal.success
        }
    else
        -- Raw table (from network/migration) - store directly
        spec.animal = animal
    end

    DewarData.syncCompatProperties(self)
    DewarData.registerWithManager(self)
    DewarData.updateAnimalVisuals(self)

    Log:debug("DewarData:setAnimal uniqueId=%s animalType=%s animalId=%s",
        tostring(self:getUniqueId()), tostring(spec.animal.typeIndex),
        tostring(spec.animal.uniqueId))
end


--- Set the straw count to an absolute value.
---
--- Server-side: if `value <= 0`, synchronously deletes the dewar via self:delete().
--- **Contract: callers MUST NOT touch `self` after setStraws(0) returns** - the
--- vehicle has been deleted. This mirrors the changeStraws zero-path contract.
---
--- Safe to call at runtime (vehicle fully registered). NOT safe during the
--- savegame load chain - use loadDewarFromSavegame's deferred path instead.
---@param value number Target straw count (clamped to >= 0; nil treated as 0)
function DewarData:setStraws(value)
    local spec = self[DewarData.SPEC_TABLE_NAME]
    spec.straws = value or 0
    self.straws = spec.straws

    if g_server ~= nil and spec.straws <= 0 then
        DewarData.updateStrawVisuals(self)
        Log:info("DewarData:setStraws(0) auto-deleting empty dewar uniqueId=%s",
            tostring(self:getUniqueId()))
        self:delete()
        return
    end

    if self.isServer then
        self:raiseDirtyFlags(spec.dirtyFlag)
        Log:debug("DewarData:setStraws value=%d dirtyFlag raised", spec.straws)
    end

    DewarData.updateStrawVisuals(self)
end


function DewarData:changeStraws(delta)
    local spec = self[DewarData.SPEC_TABLE_NAME]
    spec.straws = math.clamp(spec.straws + delta, 0, DewarData.CAPACITY)
    self.straws = spec.straws

    if spec.straws <= 0 then
        -- Update visuals to the "0 straws" frame on BOTH server and client BEFORE
        -- exit so the 3D sticky note shows empty for the last frame before delete
        -- (server) or before the early-return (client; the vehicle survives
        -- locally until the server's onWriteUpdateStream / onDelete arrives).
        DewarData.updateStrawVisuals(self)
        if g_server ~= nil then
            Log:info("DewarData:changeStraws auto-deleting empty dewar uniqueId=%s", tostring(self:getUniqueId()))
            self:delete()
        end
        return
    end

    if self.isServer then
        self:raiseDirtyFlags(spec.dirtyFlag)
    end

    DewarData.updateStrawVisuals(self)
end


function DewarData:showInfo(superFunc, box)
    local spec = self[DewarData.SPEC_TABLE_NAME]

    if spec.animal == nil then
        superFunc(self, box)
        return
    end

    local animal = spec.animal
    local animalSystem = g_currentMission.animalSystem
    local subType = animalSystem:getSubTypeByIndex(animal.subTypeIndex)

    box:addLine(g_i18n:getText("rl_ui_strawMultiple"), tostring(spec.straws))
    box:addLine(g_i18n:getText("rl_ui_averageSuccess"), string.format("%s%%", tostring(math.round(animal.success * 100))))
    box:addLine(g_i18n:getText("rl_ui_species"), animalSystem:getTypeByIndex(animal.typeIndex).groupTitle)
    box:addLine(g_i18n:getText("infohud_type"), g_fillTypeManager:getFillTypeTitleByIndex(subType.fillTypeIndex))
    box:addLine(g_i18n:getText("infohud_name"), animal.name)
    box:addLine(g_i18n:getText("rl_ui_earTag"), string.format("%s %s %s", RLConstants.AREA_CODES[animal.country].code, animal.farmId, animal.uniqueId))

    for type, value in pairs(animal.genetics) do
        local valueText

        if value >= 1.65 then
            valueText = "extremelyHigh"
        elseif value >= 1.4 then
            valueText = "veryHigh"
        elseif value >= 1.1 then
            valueText = "high"
        elseif value >= 0.9 then
            valueText = "average"
        elseif value >= 0.7 then
            valueText = "low"
        elseif value >= 0.35 then
            valueText = "veryLow"
        else
            valueText = "extremelyLow"
        end

        box:addLine(g_i18n:getText("rl_ui_" .. type), g_i18n:getText("rl_ui_genetics_" .. valueText))
    end
end


-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

function DewarData:syncCompatProperties()
    local spec = self[DewarData.SPEC_TABLE_NAME]
    self.animal = spec.animal
    self.straws = spec.straws
    -- self.uniqueId is managed by Vehicle base class
end


function DewarData:registerWithManager()
    local spec = self[DewarData.SPEC_TABLE_NAME]

    if spec.isRegistered then
        return
    end

    if spec.animal == nil then
        Log:debug("DewarData:registerWithManager skipped - no animal data yet")
        return
    end

    g_dewarManager:addDewar(self:getOwnerFarmId(), self)
    spec.isRegistered = true

    Log:debug("DewarData:registerWithManager farmId=%d typeIndex=%d uniqueId=%s",
        self:getOwnerFarmId(), spec.animal.typeIndex, tostring(self:getUniqueId()))
end


function DewarData:updateStrawVisuals()
    local spec = self[DewarData.SPEC_TABLE_NAME]
    local parent = spec.stickyNoteStraws

    if parent == nil or parent == 0 then return end

    RealisticLivestock.set3DTextRemoveSpaces(true)
    RealisticLivestock.setTextVerticalAlignment(RenderText.VERTICAL_ALIGN_MIDDLE)
    RealisticLivestock.setTextAlignment(RenderText.ALIGN_CENTER)
    RealisticLivestock.setTextColor(1, 0.1, 0.1, 1)
    RealisticLivestock.set3DTextWordsPerLine(1)
    RealisticLivestock.setTextLineHeightScale(0.75)
    RealisticLivestock.setTextFont(RealisticLivestock.FONTS.toms_handwritten)

    if spec.texts.straws ~= nil then RealisticLivestock.delete3DLinkedText(spec.texts.straws) end
    spec.texts.straws = RealisticLivestock.create3DLinkedText(parent, 0.003, 0.01, 0.003, 0, math.rad(-90), 0, 0.025, string.format("%s %s", spec.straws, spec.straws == 1 and "straw" or "straws"))

    RealisticLivestock.set3DTextRemoveSpaces(false)
    RealisticLivestock.setTextVerticalAlignment(RenderText.VERTICAL_ALIGN_BASELINE)
    RealisticLivestock.setTextAlignment(RenderText.ALIGN_LEFT)
    RealisticLivestock.setTextColor(1, 1, 1, 1)
    RealisticLivestock.set3DTextWordsPerLine(0)
    RealisticLivestock.setTextLineHeightScale(1.1)
    RealisticLivestock.setTextFont()

    Log:trace("DewarData:updateStrawVisuals straws=%d", spec.straws)
end


function DewarData:updateAnimalVisuals()
    local spec = self[DewarData.SPEC_TABLE_NAME]

    if spec.animal == nil then return end

    local parent = spec.stickyNoteAnimal
    if parent == nil or parent == 0 then return end

    local country = RLConstants.AREA_CODES[spec.animal.country].code
    local farmId = spec.animal.farmId
    local uniqueId = spec.animal.uniqueId

    RealisticLivestock.set3DTextRemoveSpaces(true)
    RealisticLivestock.setTextVerticalAlignment(RenderText.VERTICAL_ALIGN_MIDDLE)
    RealisticLivestock.setTextAlignment(RenderText.ALIGN_CENTER)
    RealisticLivestock.setTextColor(1, 0.1, 0.1, 1)
    RealisticLivestock.set3DTextWordsPerLine(1)
    RealisticLivestock.setTextLineHeightScale(1.25)
    RealisticLivestock.setTextFont(RealisticLivestock.FONTS.toms_handwritten)

    if spec.texts.animal ~= nil then RealisticLivestock.delete3DLinkedText(spec.texts.animal) end
    spec.texts.animal = RealisticLivestock.create3DLinkedText(parent, -0.01, -0.002, 0.008, 0, math.rad(-170), 0, 0.02, string.format("%s %s %s", country, uniqueId, farmId))

    RealisticLivestock.set3DTextAutoScale(false)
    RealisticLivestock.set3DTextRemoveSpaces(false)
    RealisticLivestock.setTextVerticalAlignment(RenderText.VERTICAL_ALIGN_BASELINE)
    RealisticLivestock.setTextAlignment(RenderText.ALIGN_LEFT)
    RealisticLivestock.setTextColor(1, 1, 1, 1)
    RealisticLivestock.set3DTextWordsPerLine(0)
    RealisticLivestock.setTextLineHeightScale(1.1)
    RealisticLivestock.setTextFont()

    Log:trace("DewarData:updateAnimalVisuals country=%s uniqueId=%s", country, uniqueId)
end
