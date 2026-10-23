--[[
    RLSavedTypeRef.lua
    Resolves an animal type or subtype reference read from a savegame. A present name decides:
    it resolves or the reference drops. The saved index is read only when no name was saved
    (a save written before names were). Pure: the caller hands in the registry, no g_* reads.
]]

RLSavedTypeRef = {}

local Log = RmLogging.getLogger("RLRM")


--- Resolve a saved animal type reference.
---@param registry table animal system (getTypeIndexByName, typeIndexToName)
---@param name string|nil saved type name; nil means the attribute was ABSENT, any string means present
---@param index number|nil saved type index, read only when name is nil
---@return number|nil typeIndex
---@return string source "name", "legacy-index", "unknown-name", "unknown-index" or "missing"
function RLSavedTypeRef.resolveType(registry, name, index)
    if name ~= nil then
        local typeIndex = registry:getTypeIndexByName(name)
        if typeIndex == nil then
            Log:trace("RLSavedTypeRef.resolveType: name=%s not registered", tostring(name))
            return nil, "unknown-name"
        end
        Log:trace("RLSavedTypeRef.resolveType: name=%s -> %s", tostring(name), tostring(typeIndex))
        return typeIndex, "name"
    end

    if index == nil then
        Log:trace("RLSavedTypeRef.resolveType: no name and no index saved")
        return nil, "missing"
    end

    if registry.typeIndexToName[index] == nil then
        Log:trace("RLSavedTypeRef.resolveType: index=%s not registered", tostring(index))
        return nil, "unknown-index"
    end

    Log:trace("RLSavedTypeRef.resolveType: no name saved, index=%s kept", tostring(index))
    return index, "legacy-index"
end


--- Resolve a saved animal subtype reference, optionally requiring it to sit under one type.
---@param registry table animal system (getSubTypeIndexByName, getSubTypeByIndex)
---@param name string|nil saved subtype name; nil means the attribute was ABSENT, any string means present
---@param index number|nil saved subtype index, read only when name is nil
---@param expectedTypeIndex number|nil when set, a subtype registered under another type drops
---@return number|nil subTypeIndex
---@return string source "name", "legacy-index", "unknown-name", "unknown-index", "type-mismatch" or "missing"
function RLSavedTypeRef.resolveSubType(registry, name, index, expectedTypeIndex)
    local subTypeIndex, source

    if name ~= nil then
        subTypeIndex = registry:getSubTypeIndexByName(name)
        if subTypeIndex == nil then
            Log:trace("RLSavedTypeRef.resolveSubType: name=%s not registered", tostring(name))
            return nil, "unknown-name"
        end
        source = "name"
    elseif index == nil then
        Log:trace("RLSavedTypeRef.resolveSubType: no name and no index saved")
        return nil, "missing"
    elseif registry:getSubTypeByIndex(index) == nil then
        Log:trace("RLSavedTypeRef.resolveSubType: index=%s not registered", tostring(index))
        return nil, "unknown-index"
    else
        subTypeIndex, source = index, "legacy-index"
    end

    if expectedTypeIndex ~= nil then
        local subType = registry:getSubTypeByIndex(subTypeIndex)
        if subType.typeIndex ~= expectedTypeIndex then
            Log:trace("RLSavedTypeRef.resolveSubType: subtype %s sits under type %s, expected %s",
                tostring(subTypeIndex), tostring(subType.typeIndex), tostring(expectedTypeIndex))
            return nil, "type-mismatch"
        end
    end

    Log:trace("RLSavedTypeRef.resolveSubType: -> %s (source=%s)", tostring(subTypeIndex), source)
    return subTypeIndex, source
end


--- The registered name of a type index, for a writer.
---@param registry table animal system (typeIndexToName)
---@param index number|nil
---@return string|nil name nil when the index is nil or not registered
function RLSavedTypeRef.typeNameOf(registry, index)
    if index == nil then return nil end
    return registry.typeIndexToName[index]
end


--- The registered name of a subtype index, for a writer.
---@param registry table animal system (getSubTypeByIndex)
---@param index number|nil
---@return string|nil name nil when the index is nil or not registered
function RLSavedTypeRef.subTypeNameOf(registry, index)
    if index == nil then return nil end
    local subType = registry:getSubTypeByIndex(index)
    return subType ~= nil and subType.name or nil
end


Log:trace("RLSavedTypeRef: loaded")
