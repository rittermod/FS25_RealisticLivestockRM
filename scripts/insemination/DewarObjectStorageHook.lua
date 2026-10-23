--[[
    DewarObjectStorageHook.lua

    Makes rlDewar vehicles round-trip through PlaceableObjectStorage without losing their
    DewarData spec state (uniqueId, straw count, stored animal), which the storage otherwise
    drops - only the standard pallet attributes survive. The extra state rides on the
    abstractObject instance and persists under a namespaced nested XML key; the restore path
    goes through DewarData's public setters only.

    Timing: Placeable.xmlSchemaSavegame and ABSTRACT_OBJECTS_BY_CLASS_NAME are not populated
    when main.lua runs, so every hook is installed from an addInitSchemaFunction callback.
]]

DewarObjectStorageHook = {}
DewarObjectStorageHook.SAVEGAME_KEY = "dewarData"
DewarObjectStorageHook.GENETICS_FIELDS = { "metabolism", "fertility", "health", "quality", "productivity" }

--- Ensure a stored-pallet attribute table exposes non-nil fillLevel and fillType.
---
--- Third-party mods reading palletAttributes assume both are populated and crash on a nil
--- comparison. A backstop for dewar.xml's placeholder fillUnit block.
---@param palletAttributes table|nil Attribute table to normalise
function DewarObjectStorageHook.ensurePalletAttributesShape(palletAttributes)
    if palletAttributes == nil then return end
    if palletAttributes.fillLevel == nil then
        palletAttributes.fillLevel = 0
    end
    if palletAttributes.fillType == nil then
        palletAttributes.fillType = FillType.UNKNOWN
    end
end

--- Returns a plain-table snapshot of the vehicle's DewarData spec state, or nil when the
--- vehicle is not a dewar or has no spec table.
---@param vehicle table|nil Live vehicle (or mock with the same surface)
---@return table|nil state
function DewarObjectStorageHook.snapshot(vehicle)
    if vehicle == nil or not vehicle.isDewar then return nil end
    local spec = vehicle[DewarData.SPEC_TABLE_NAME]
    if spec == nil then return nil end

    -- Zero-straw zombie guard: refuse to capture, so the round-trip cannot resurrect one.
    if (spec.straws or 0) <= 0 then
        Log:warning("DewarStorage SNAPSHOT: refusing zero-straw dewar uniqueId=%s",
            tostring(vehicle:getUniqueId()))
        return nil
    end

    local state = {
        uniqueId = vehicle:getUniqueId(),
        straws = spec.straws or 0,
    }
    if spec.animal ~= nil then
        local a = spec.animal
        state.animal = {
            country = a.country,
            farmId = a.farmId,
            uniqueId = a.uniqueId,
            name = a.name,
            typeIndex = a.typeIndex,
            subTypeIndex = a.subTypeIndex,
            success = a.success,
            genetics = a.genetics and table.clone(a.genetics, 3) or nil,
        }
    end
    return state
end

--- Apply a captured snapshot onto a dewar vehicle through its public setters.
---@param vehicle table Live vehicle
---@param state table|nil Snapshot from DewarObjectStorageHook.snapshot
function DewarObjectStorageHook.restore(vehicle, state)
    if vehicle == nil or state == nil then return end
    if not vehicle.isDewar then return end

    -- Zero-straw zombie guard. The delete is deferred through Timer.createOneshot(0, ...)
    -- because this runs inside the storage-exit load chain, where a direct delete is unsafe.
    if g_server ~= nil and (state.straws or 0) <= 0 then
        Log:warning("DewarStorage RESTORE: refusing zero-straw state uniqueId=%s, scheduling deferred delete",
            tostring(state.uniqueId))
        local target = vehicle
        Timer.createOneshot(0, function()
            if target ~= nil and target.isDeleted ~= true then
                Log:info("DewarStorage RESTORE: deferred-delete fired uniqueId=%s",
                    tostring(state.uniqueId))
                target:delete()
            end
        end)
        return
    end

    if state.uniqueId ~= nil and vehicle.setUniqueId ~= nil then
        vehicle:setUniqueId(state.uniqueId)
    end
    if vehicle.setStraws ~= nil then
        vehicle:setStraws(state.straws or 0)
    end
    if state.animal ~= nil and vehicle.setAnimal ~= nil then
        -- Raw table form - DewarData:setAnimal stores it directly and triggers
        -- syncCompatProperties + registerWithManager + updateAnimalVisuals.
        vehicle:setAnimal(state.animal)
    end
end

--- Write the nested dewar state XML block under `baseKey`.
---@param state table|nil Snapshot to write
---@param xmlFile table XMLFile handle (must support setValue)
---@param baseKey string Path prefix (e.g. "placeables.placeable(1).objectStorage.object(0)")
---@param registry table animal system the type and subtype indices are named from
function DewarObjectStorageHook.writeStateToXML(state, xmlFile, baseKey, registry)
    if state == nil then return end
    local base = baseKey .. "." .. DewarObjectStorageHook.SAVEGAME_KEY

    if state.uniqueId ~= nil then
        xmlFile:setValue(base .. "#uniqueId", state.uniqueId)
    end
    xmlFile:setValue(base .. "#straws", state.straws or 0)

    if state.animal ~= nil then
        local a = state.animal
        local animalBase = base .. ".animal"
        local typeName = RLSavedTypeRef.typeNameOf(registry, a.typeIndex)
        local subTypeName = RLSavedTypeRef.subTypeNameOf(registry, a.subTypeIndex)
        if a.country      ~= nil then xmlFile:setValue(animalBase .. "#country",      a.country)      end
        if a.farmId       ~= nil then xmlFile:setValue(animalBase .. "#farmId",       a.farmId)       end
        if a.uniqueId     ~= nil then xmlFile:setValue(animalBase .. "#uniqueId",     a.uniqueId)     end
        if a.name         ~= nil then xmlFile:setValue(animalBase .. "#name",         a.name)         end
        if a.typeIndex    ~= nil then xmlFile:setValue(animalBase .. "#typeIndex",    a.typeIndex)    end
        if typeName       ~= nil then xmlFile:setValue(animalBase .. "#typeName",     typeName)       end
        if a.subTypeIndex ~= nil then xmlFile:setValue(animalBase .. "#subTypeIndex", a.subTypeIndex) end
        if subTypeName    ~= nil then xmlFile:setValue(animalBase .. "#subTypeName",  subTypeName)    end
        if a.success      ~= nil then xmlFile:setValue(animalBase .. "#success",      a.success)      end
        Log:trace("DewarStorage WRITE: uniqueId=%s typeName=%s subTypeName=%s",
            tostring(state.uniqueId), tostring(typeName), tostring(subTypeName))
        if a.genetics ~= nil then
            for _, gene in ipairs(DewarObjectStorageHook.GENETICS_FIELDS) do
                if a.genetics[gene] ~= nil then
                    xmlFile:setValue(animalBase .. ".genetics#" .. gene, a.genetics[gene])
                end
            end
        end
    end
end

--- A name attribute's value when present (the empty string included), nil when absent.
---@param xmlFile table XMLFile handle (getValue + hasProperty)
---@param path string attribute path
---@return string|nil
local function readPresentName(xmlFile, path)
    if not xmlFile:hasProperty(path) then return nil end
    return xmlFile:getValue(path) or ""
end


--- Read the nested dewar state under `baseKey`, or nil; an unresolved semen record drops and zeroes straws.
---@param xmlFile table XMLFile handle (must support getValue + hasProperty)
---@param baseKey string Path prefix
---@param registry table animal system the type and subtype references resolve against
---@return table|nil state
function DewarObjectStorageHook.readStateFromXML(xmlFile, baseKey, registry)
    local base = baseKey .. "." .. DewarObjectStorageHook.SAVEGAME_KEY
    if not xmlFile:hasProperty(base) then return nil end

    local state = {
        uniqueId = xmlFile:getValue(base .. "#uniqueId"),
        straws = xmlFile:getValue(base .. "#straws") or 0,
    }

    local animalBase = base .. ".animal"
    if not xmlFile:hasProperty(animalBase) then
        Log:trace("DewarStorage READ: uniqueId=%s carries no semen record", tostring(state.uniqueId))
        return state
    end

    local typeName = readPresentName(xmlFile, animalBase .. "#typeName")
    local savedTypeIndex = xmlFile:getValue(animalBase .. "#typeIndex")
    local typeIndex, typeSource = RLSavedTypeRef.resolveType(registry, typeName, savedTypeIndex)

    -- Read before the type check so a drop WARNING names the saved subtype either way.
    local subTypeName = readPresentName(xmlFile, animalBase .. "#subTypeName")
    local savedSubTypeIndex = xmlFile:getValue(animalBase .. "#subTypeIndex")
    local subTypeIndex, subTypeSource
    if typeIndex ~= nil then
        subTypeIndex, subTypeSource = RLSavedTypeRef.resolveSubType(registry, subTypeName, savedSubTypeIndex,
            typeIndex)
    end

    if subTypeIndex == nil then
        local ref, reason = "subType", subTypeSource
        if typeIndex == nil then ref, reason = "type", typeSource end
        Log:warning("DewarStorage READ: removing stored dewar uniqueId=%s, its semen record's %s does not resolve "
            .. "(%s) (typeName=%s typeIndex=%s subTypeName=%s subTypeIndex=%s)",
            tostring(state.uniqueId), ref, tostring(reason),
            tostring(typeName), tostring(savedTypeIndex), tostring(subTypeName), tostring(savedSubTypeIndex))
        state.straws = 0
        return state
    end

    local animal = {
        country      = xmlFile:getValue(animalBase .. "#country"),
        farmId       = xmlFile:getValue(animalBase .. "#farmId"),
        uniqueId     = xmlFile:getValue(animalBase .. "#uniqueId"),
        name         = xmlFile:getValue(animalBase .. "#name"),
        typeIndex    = typeIndex,
        subTypeIndex = subTypeIndex,
        success      = xmlFile:getValue(animalBase .. "#success"),
        genetics = {},
    }
    for _, gene in ipairs(DewarObjectStorageHook.GENETICS_FIELDS) do
        animal.genetics[gene] = xmlFile:getValue(animalBase .. ".genetics#" .. gene)
    end
    state.animal = animal

    Log:debug("DewarStorage READ: uniqueId=%s type %s (source=%s) subtype %s (source=%s)",
        tostring(state.uniqueId), tostring(typeIndex), typeSource, tostring(subTypeIndex), subTypeSource)
    return state
end

-- =============================================================================
-- DEFERRED HOOK INSTALLATION
--
-- Runs via g_xmlManager:addInitSchemaFunction, by which time Placeable.xmlSchemaSavegame
-- and PlaceableObjectStorage.ABSTRACT_OBJECTS_BY_CLASS_NAME are both ready.
-- =============================================================================

local function installHooks()
    -- Idempotency guard: addInitSchemaFunction can fire more than once during startup, and
    -- re-applying would double-wrap the targets so each callback ran twice.
    if DewarObjectStorageHook._installed then return end
    DewarObjectStorageHook._installed = true

    -- AbstractPalletObject is not exposed as a global; the class-name table is the way in.
    if PlaceableObjectStorage == nil
        or PlaceableObjectStorage.ABSTRACT_OBJECTS_BY_CLASS_NAME == nil
    then
        Log:error("DewarObjectStorageHook: PlaceableObjectStorage or its ABSTRACT_OBJECTS_BY_CLASS_NAME table not available - hooks NOT installed")
        return
    end
    local AbstractPalletObject = PlaceableObjectStorage.ABSTRACT_OBJECTS_BY_CLASS_NAME["Vehicle"]
    if AbstractPalletObject == nil then
        Log:error("DewarObjectStorageHook: AbstractPalletObject ('Vehicle') not found in ABSTRACT_OBJECTS_BY_CLASS_NAME - hooks NOT installed")
        return
    end

    -- -------------------------------------------------------------------------
    -- Schema registration
    -- -------------------------------------------------------------------------
    local schemaOk, schemaErr = pcall(function()
        local schema = Placeable.xmlSchemaSavegame
        if schema == nil then
            error("Placeable.xmlSchemaSavegame is nil")
        end
        local base = "placeables.placeable(?).objectStorage.object(?)." .. DewarObjectStorageHook.SAVEGAME_KEY
        schema:register(XMLValueType.STRING, base .. "#uniqueId", "Dewar uniqueId")
        schema:register(XMLValueType.INT,    base .. "#straws",   "Dewar straw count")

        local animalBase = base .. ".animal"
        schema:register(XMLValueType.INT,    animalBase .. "#country",      "Stored animal country")
        schema:register(XMLValueType.STRING, animalBase .. "#farmId",       "Stored animal farmId")
        schema:register(XMLValueType.STRING, animalBase .. "#uniqueId",     "Stored animal uniqueId")
        schema:register(XMLValueType.STRING, animalBase .. "#name",         "Stored animal name")
        schema:register(XMLValueType.INT,    animalBase .. "#typeIndex",    "Stored animal type index")
        schema:register(XMLValueType.STRING, animalBase .. "#typeName",     "Stored animal type name")
        schema:register(XMLValueType.INT,    animalBase .. "#subTypeIndex", "Stored animal subtype index")
        schema:register(XMLValueType.STRING, animalBase .. "#subTypeName",  "Stored animal subtype name")
        schema:register(XMLValueType.FLOAT,  animalBase .. "#success",      "Stored animal breeding success")
        for _, gene in ipairs(DewarObjectStorageHook.GENETICS_FIELDS) do
            schema:register(XMLValueType.FLOAT, animalBase .. ".genetics#" .. gene, "Stored animal genetics " .. gene)
        end
    end)
    if not schemaOk then
        Log:warning("DewarObjectStorageHook: schema registration failed (%s) - continuing without strict validation", tostring(schemaErr))
    end

    -- -------------------------------------------------------------------------
    -- Entry hook: capture state before super deletes the vehicle
    -- -------------------------------------------------------------------------
    AbstractPalletObject.addToStorage = Utils.overwrittenFunction(
        AbstractPalletObject.addToStorage,
        function(self, superFunc, storage, object, loadedFromSavegame)
            local state = DewarObjectStorageHook.snapshot(object)
            superFunc(self, storage, object, loadedFromSavegame)

            if state ~= nil then
                DewarObjectStorageHook.ensurePalletAttributesShape(self.palletAttributes)
                self.rlDewarData = state
                Log:debug("DewarStorage ENTRY: captured uniqueId=%s straws=%d hasAnimal=%s",
                    tostring(state.uniqueId), state.straws, tostring(state.animal ~= nil))
            end
        end
    )

    -- -------------------------------------------------------------------------
    -- Exit hook: restore state onto freshly spawned vehicle
    -- -------------------------------------------------------------------------
    AbstractPalletObject.palletVehicleLoaded = Utils.appendedFunction(
        AbstractPalletObject.palletVehicleLoaded,
        function(self, vehicles, vehicleLoadState, asyncCallbackArguments)
            if vehicleLoadState ~= VehicleLoadingState.OK then return end
            if self.rlDewarData == nil then return end
            local vehicle = vehicles and vehicles[1]
            if vehicle == nil or not vehicle.isDewar then return end

            DewarObjectStorageHook.restore(vehicle, self.rlDewarData)
            Log:info("DewarStorage EXIT: restored uniqueId=%s straws=%d hasAnimal=%s",
                tostring(self.rlDewarData.uniqueId), self.rlDewarData.straws or 0,
                tostring(self.rlDewarData.animal ~= nil))
        end
    )

    -- -------------------------------------------------------------------------
    -- Savegame save: write nested keys after super writes palletAttributes
    -- -------------------------------------------------------------------------
    AbstractPalletObject.saveToXMLFile = Utils.appendedFunction(
        AbstractPalletObject.saveToXMLFile,
        function(self, storage, xmlFile, key)
            if self.rlDewarData == nil then return end
            DewarObjectStorageHook.writeStateToXML(self.rlDewarData, xmlFile, key, g_currentMission.animalSystem)
            Log:debug("DewarStorage SAVE: wrote uniqueId=%s straws=%d hasAnimal=%s",
                tostring(self.rlDewarData.uniqueId), self.rlDewarData.straws or 0,
                tostring(self.rlDewarData.animal ~= nil))
        end
    )

    -- -------------------------------------------------------------------------
    -- Savegame load: annotate the newly-inserted abstractObject
    --
    -- loadFromXMLFile is called without a `self` argument, so it is wrapped by hand rather
    -- than through Utils.overwrittenFunction, and #storedObjects is snapshotted before
    -- delegating so the new entry is identified by index, not by "last element".
    -- -------------------------------------------------------------------------
    local origLoadFromXMLFile = AbstractPalletObject.loadFromXMLFile
    AbstractPalletObject.loadFromXMLFile = function(storage, xmlFile, key)
        local specOS = storage and storage.spec_objectStorage
        local priorCount = (specOS and specOS.storedObjects) and #specOS.storedObjects or 0

        origLoadFromXMLFile(storage, xmlFile, key)

        local state = DewarObjectStorageHook.readStateFromXML(xmlFile, key, g_currentMission.animalSystem)
        if state == nil then return end
        if specOS == nil or specOS.storedObjects == nil then return end
        if #specOS.storedObjects <= priorCount then return end

        -- Zero-straw zombie guard: strip the freshly appended stored-object
        -- entry so the rack never offers an empty dewar back to the player.
        -- Runs immediately after origLoadFromXMLFile so no other code reads
        -- the entry first.
        if (state.straws or 0) <= 0 then
            Log:warning("DewarStorage LOAD: stripping zero-straw stored dewar uniqueId=%s from storedObjects[%d]",
                tostring(state.uniqueId), priorCount + 1)
            table.remove(specOS.storedObjects, priorCount + 1)
            return
        end

        local stored = specOS.storedObjects[priorCount + 1]
        if stored == nil or stored.REFERENCE_CLASS_NAME ~= AbstractPalletObject.REFERENCE_CLASS_NAME then return end

        stored.rlDewarData = state
        Log:debug("DewarStorage LOAD: annotated stored dewar uniqueId=%s straws=%d hasAnimal=%s",
            tostring(state.uniqueId), state.straws, tostring(state.animal ~= nil))
    end

    Log:info("DewarObjectStorageHook: installed")
end

-- Defer installation until Placeable.xmlSchemaSavegame is built and the
-- placeable spec file has populated ABSTRACT_OBJECTS_BY_CLASS_NAME.
g_xmlManager:addInitSchemaFunction(installHooks)
