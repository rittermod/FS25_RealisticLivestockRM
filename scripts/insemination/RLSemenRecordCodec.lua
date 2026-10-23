--[[
    RLSemenRecordCodec.lua
    Reads and writes the `.animal` semen record a dewar and a straw carry. The type and subtype
    are saved by name beside their index and resolved through RLSavedTypeRef: a record whose
    references do not resolve, or whose subtype sits under another type, is not returned.
]]

RLSemenRecordCodec = {}

local Log = RmLogging.getLogger("RLRM")

RLSemenRecordCodec.GENETICS_FIELDS = { "metabolism", "fertility", "health", "quality", "productivity" }


--- A name attribute's value when present (the empty string included), nil when absent.
---@param xmlFile table XMLFile object
---@param path string attribute path
---@return string|nil
local function readPresentName(xmlFile, path)
    if not xmlFile:hasProperty(path) then return nil end
    return xmlFile:getString(path, "")
end


--- Read the semen record under `key .. ".animal"`.
---@param xmlFile table XMLFile object
---@param key string path of the element that holds `.animal`
---@param registry table animal system the references resolve against
---@return table|nil record nil when absent or unresolved
---@return string|nil reason the RLSavedTypeRef source that failed; nil when absent or resolved
---@return string|nil ref "type" or "subType", the reference that failed
function RLSemenRecordCodec.read(xmlFile, key, registry)
    local animalKey = key .. ".animal"
    if not xmlFile:hasProperty(animalKey) then
        Log:trace("RLSemenRecordCodec.read: no record at %s", animalKey)
        return nil
    end

    local typeName = readPresentName(xmlFile, animalKey .. "#typeName")
    local savedTypeIndex = xmlFile:getInt(animalKey .. "#typeIndex")
    local typeIndex, typeSource = RLSavedTypeRef.resolveType(registry, typeName, savedTypeIndex)
    if typeIndex == nil then
        Log:trace("RLSemenRecordCodec.read: %s type unresolved (%s)", animalKey, typeSource)
        return nil, typeSource, "type"
    end

    local subTypeName = readPresentName(xmlFile, animalKey .. "#subTypeName")
    local savedSubTypeIndex = xmlFile:getInt(animalKey .. "#subTypeIndex")
    local subTypeIndex, subTypeSource = RLSavedTypeRef.resolveSubType(registry, subTypeName,
        savedSubTypeIndex, typeIndex)
    if subTypeIndex == nil then
        Log:trace("RLSemenRecordCodec.read: %s subtype unresolved (%s)", animalKey, subTypeSource)
        return nil, subTypeSource, "subType"
    end

    local record = {
        country = xmlFile:getInt(animalKey .. "#country"),
        farmId = xmlFile:getString(animalKey .. "#farmId"),
        uniqueId = xmlFile:getString(animalKey .. "#uniqueId"),
        name = xmlFile:getString(animalKey .. "#name"),
        typeIndex = typeIndex,
        subTypeIndex = subTypeIndex,
        success = xmlFile:getFloat(animalKey .. "#success"),
        genetics = {},
    }
    for _, gene in ipairs(RLSemenRecordCodec.GENETICS_FIELDS) do
        record.genetics[gene] = xmlFile:getFloat(animalKey .. ".genetics#" .. gene)
    end

    Log:debug("RLSemenRecordCodec.read: %s -> type %s (source=%s) subtype %s (source=%s) uniqueId=%s",
        animalKey, tostring(typeIndex), typeSource, tostring(subTypeIndex), subTypeSource,
        tostring(record.uniqueId))
    return record
end


--- Write a semen record under `key .. ".animal"`, each reference with its index and, when
--- registered, its name.
---@param xmlFile table XMLFile object
---@param key string path of the element that holds `.animal`
---@param record table semen record (country, farmId, uniqueId, name, typeIndex, subTypeIndex, success, genetics)
---@param registry table animal system the indices are named from
function RLSemenRecordCodec.write(xmlFile, key, record, registry)
    local animalKey = key .. ".animal"
    local typeName = RLSavedTypeRef.typeNameOf(registry, record.typeIndex)
    local subTypeName = RLSavedTypeRef.subTypeNameOf(registry, record.subTypeIndex)

    xmlFile:setInt(animalKey .. "#country", record.country)
    xmlFile:setString(animalKey .. "#farmId", record.farmId)
    xmlFile:setString(animalKey .. "#uniqueId", record.uniqueId)
    xmlFile:setString(animalKey .. "#name", record.name or "")
    xmlFile:setInt(animalKey .. "#typeIndex", record.typeIndex)
    if typeName ~= nil then xmlFile:setString(animalKey .. "#typeName", typeName) end
    xmlFile:setInt(animalKey .. "#subTypeIndex", record.subTypeIndex)
    if subTypeName ~= nil then xmlFile:setString(animalKey .. "#subTypeName", subTypeName) end
    xmlFile:setFloat(animalKey .. "#success", record.success)

    for gene, value in pairs(record.genetics) do
        xmlFile:setFloat(animalKey .. ".genetics#" .. gene, value)
    end

    Log:trace("RLSemenRecordCodec.write: %s typeName=%s subTypeName=%s", animalKey,
        tostring(typeName), tostring(subTypeName))
end


Log:trace("RLSemenRecordCodec: loaded")
