--[[
    RLDealerFarmIdCodec.lua
    Reads and writes a dealer farm's per-type last-animal ids (`<farm><id type typeName id/>`).
    Each entry is resolved through RLSavedTypeRef, so a name decides and the index is read only
    from a save written before names were. An entry that does not resolve is counted, not kept.
]]

RLDealerFarmIdCodec = {}

local Log = RmLogging.getLogger("RLRM")

-- Attributes builds before the `<id>` entries wrote, read by type name.
RLDealerFarmIdCodec.LEGACY_ATTRIBUTES = {
    { attribute = "#cowId", typeName = "COW" },
    { attribute = "#pigId", typeName = "PIG" },
    { attribute = "#sheepId", typeName = "SHEEP" },
    { attribute = "#horseId", typeName = "HORSE" },
    { attribute = "#chickenId", typeName = "CHICKEN" },
}


--- Count one dropped entry under its key.
---@param dropped table|nil key -> count, written in place
---@param key string saved name, or "#type=<index>" when no name was saved
local function countDrop(dropped, key)
    if dropped == nil then return end
    dropped[key] = (dropped[key] or 0) + 1
end


--- Read one farm's ids table, keyed by the live type index.
---@param xmlFile table XMLFile object
---@param farmKey string path of the `<farm>` element
---@param registry table animal system the entries resolve against
---@param dropped table|nil key -> count of unresolved entries, written in place
---@return table ids typeIndex -> last animal id
function RLDealerFarmIdCodec.read(xmlFile, farmKey, registry, dropped)
    local ids = {}

    for _, legacy in ipairs(RLDealerFarmIdCodec.LEGACY_ATTRIBUTES) do
        local lastId = xmlFile:getInt(farmKey .. legacy.attribute)
        if lastId ~= nil then
            local typeIndex = RLSavedTypeRef.resolveType(registry, legacy.typeName, nil)
            if typeIndex ~= nil then
                ids[typeIndex] = lastId
                Log:debug("RLDealerFarmIdCodec.read: %s %s -> type %s id %s (source=legacy-attribute)",
                    farmKey, legacy.attribute, tostring(typeIndex), tostring(lastId))
            else
                countDrop(dropped, legacy.typeName)
                Log:trace("RLDealerFarmIdCodec.read: %s %s names unregistered type %s; dropped",
                    farmKey, legacy.attribute, legacy.typeName)
            end
        end
    end

    xmlFile:iterate(farmKey .. ".id", function(_, idKey)
        local name = nil
        if xmlFile:hasProperty(idKey .. "#typeName") then
            name = xmlFile:getString(idKey .. "#typeName", "")
        end
        local savedIndex = xmlFile:getInt(idKey .. "#type")
        local lastId = xmlFile:getInt(idKey .. "#id", 0)

        local typeIndex, source = RLSavedTypeRef.resolveType(registry, name, savedIndex)
        if typeIndex == nil then
            countDrop(dropped, name ~= nil and name or ("#type=" .. tostring(savedIndex)))
            Log:trace("RLDealerFarmIdCodec.read: %s typeName=%s type=%s unresolved (%s); dropped",
                idKey, tostring(name), tostring(savedIndex), source)
            return
        end

        ids[typeIndex] = lastId
        Log:debug("RLDealerFarmIdCodec.read: %s -> type %s id %s (source=%s)",
            idKey, tostring(typeIndex), tostring(lastId), source)
    end)

    return ids
end


--- Write one farm's ids table, each entry with its type index and, when registered, its name.
---@param xmlFile table XMLFile object
---@param farmKey string path of the `<farm>` element
---@param ids table typeIndex -> last animal id
---@param registry table animal system the indices are named from
function RLDealerFarmIdCodec.write(xmlFile, farmKey, ids, registry)
    local j = 0

    for typeIndex, lastId in pairs(ids) do
        local idKey = string.format("%s.id(%d)", farmKey, j)
        local name = RLSavedTypeRef.typeNameOf(registry, typeIndex)

        xmlFile:setInt(idKey .. "#type", typeIndex)
        if name ~= nil then
            xmlFile:setString(idKey .. "#typeName", name)
        else
            Log:trace("RLDealerFarmIdCodec.write: %s type %s has no registered name; index only",
                idKey, tostring(typeIndex))
        end
        xmlFile:setInt(idKey .. "#id", lastId)

        j = j + 1
    end

    Log:trace("RLDealerFarmIdCodec.write: %s wrote %d entries", farmKey, j)
end


Log:trace("RLDealerFarmIdCodec: loaded")
