--[[
    AnimalSerialization.lua
    Network stream serialization extracted from Animal.lua.

    Provides writeStream, readStream, writeStreamUnborn, readStreamUnborn
    as module functions. Animal.lua retains thin delegates that route to
    this module.

    Sourced BEFORE RealisticLivestock_Animal.lua (same pattern as
    AnimalPersistence).

    CRITICAL: Stream read/write order must match exactly.
    Any field added/removed/reordered on one side without the other
    causes silent MP desync.
]]

AnimalSerialization = {}

local Log = RmLogging.getLogger("RLRM")


-- =============================================================================
-- STREAM SERIALIZATION FUNCTIONS (delegated from Animal)
-- =============================================================================

--- Write full animal state to network stream.
--- Called during client join sync and buy-animal broadcast.
--- CRITICAL: Field order must match readStream exactly.
--- @param animal table Animal instance
--- @param streamId number Network stream handle
--- @param connection table Network connection
--- @return boolean success
function AnimalSerialization.writeStream(animal, streamId, connection)
    streamWriteUInt8(streamId, animal.subTypeIndex)
    streamWriteString(streamId, animal.subType or "")
    streamWriteUInt16(streamId, animal.age)
    streamWriteFloat32(streamId, animal.health)
    streamWriteFloat32(streamId, animal.reproduction)
    streamWriteUInt16(streamId, animal.monthsSinceLastBirth)
    streamWriteString(streamId, animal.gender)

    streamWriteBool(streamId, animal.isParent)
    streamWriteBool(streamId, animal.isPregnant and animal.pregnancy ~= nil)
    streamWriteBool(streamId, animal.isLactating)

    streamWriteBool(streamId, animal.recentlyBoughtByAI or false)

    local numMarks = 0

    for key, mark in pairs(animal.marks) do numMarks = numMarks + 1 end

    streamWriteUInt8(streamId, numMarks)

    for key, mark in pairs(animal.marks) do
        streamWriteString(streamId, key)
        streamWriteBool(streamId, mark.active)
    end

    streamWriteString(streamId, animal.uniqueId)
    streamWriteString(streamId, animal.farmId)
    streamWriteUInt8(streamId, animal.variation or 1)
    streamWriteString(streamId, animal.motherId or "-1")
    streamWriteString(streamId, animal.fatherId or "-1")
    streamWriteFloat32(streamId, animal.weight)
    streamWriteFloat32(streamId, animal.targetWeight)

    streamWriteBool(streamId, animal.name ~= nil and animal.name ~= "")

    if animal.name ~= nil and animal.name ~= "" then streamWriteString(streamId, animal.name) end

    streamWriteFloat32(streamId, animal.dirt or 0)
    streamWriteFloat32(streamId, animal.fitness or 0)
    streamWriteFloat32(streamId, animal.riding or 0)

    if animal.isPregnant and animal.pregnancy ~= nil then
        streamWriteBool(streamId, animal.impregnatedBy ~= nil)

        if animal.impregnatedBy ~= nil then
            local impregnatedBy = animal.impregnatedBy

            streamWriteString(streamId, impregnatedBy.uniqueId or "-1")
            streamWriteFloat32(streamId, impregnatedBy.metabolism or 1)
            streamWriteFloat32(streamId, impregnatedBy.productivity or 1)
            streamWriteFloat32(streamId, impregnatedBy.quality or 1)
            streamWriteFloat32(streamId, impregnatedBy.health or 1)
            streamWriteFloat32(streamId, impregnatedBy.fertility or 1)
        end

        local pregnancy = animal.pregnancy

        streamWriteUInt8(streamId, pregnancy.expected.day)
        streamWriteUInt8(streamId, pregnancy.expected.month)
        streamWriteUInt8(streamId, pregnancy.expected.year)
        streamWriteUInt8(streamId, pregnancy.duration)

        streamWriteUInt8(streamId, pregnancy.pregnancies == nil and 0 or #pregnancy.pregnancies)

        for _, child in pairs(pregnancy.pregnancies or {}) do
            streamWriteFloat32(streamId, child.health)
            streamWriteString(streamId, child.gender)
            streamWriteUInt8(streamId, child.subTypeIndex)
            streamWriteString(streamId, child.subType or "")
            streamWriteString(streamId, child.motherId)
            streamWriteString(streamId, child.fatherId)

            local genetics = child.genetics

            streamWriteFloat32(streamId, genetics.metabolism)
            streamWriteFloat32(streamId, genetics.health)
            streamWriteFloat32(streamId, genetics.fertility)
            streamWriteFloat32(streamId, genetics.quality)
            streamWriteFloat32(streamId, genetics.productivity or 0)
        end
    end

    if animal.isParent then
        streamWriteUInt16(streamId, #animal.children)

        for _, child in pairs(animal.children or {}) do
            streamWriteString(streamId, child.uniqueId or "")
            streamWriteString(streamId, child.farmId or "")
        end
    end

    local birthday = animal.birthday

    streamWriteUInt8(streamId, birthday.day)
    streamWriteUInt8(streamId, birthday.month)
    streamWriteUInt8(streamId, birthday.year)
    streamWriteUInt8(streamId, birthday.country)
    streamWriteUInt8(streamId, birthday.lastAgeMonth)

    local genetics, numGenetics = animal.genetics, 0

    for trait, quality in pairs(genetics) do numGenetics = numGenetics + 1 end

    streamWriteUInt8(streamId, numGenetics)

    for trait, quality in pairs(genetics) do
        streamWriteString(streamId, trait)
        streamWriteFloat32(streamId, quality)
    end

    streamWriteBool(streamId, animal.monitor.active)
    streamWriteBool(streamId, animal.monitor.removed)
    streamWriteFloat32(streamId, animal.monitor.fee or 5)

    streamWriteBool(streamId, animal.isCastrated or false)

    streamWriteUInt8(streamId, #animal.diseases)

    for i = 1, #animal.diseases do
        animal.diseases[i]:writeStream(streamId, connection)
    end

    streamWriteBool(streamId, animal.insemination ~= nil)

    if animal.insemination ~= nil then
        streamWriteUInt8(streamId, animal.insemination.country)
        streamWriteString(streamId, animal.insemination.farmId)
        streamWriteString(streamId, animal.insemination.uniqueId)
        streamWriteString(streamId, animal.insemination.name)
        streamWriteUInt8(streamId, animal.insemination.subTypeIndex)
        streamWriteFloat32(streamId, animal.insemination.success)
        streamWriteFloat32(streamId, animal.insemination.genetics.metabolism)
        streamWriteFloat32(streamId, animal.insemination.genetics.health)
        streamWriteFloat32(streamId, animal.insemination.genetics.fertility)
        streamWriteFloat32(streamId, animal.insemination.genetics.quality)
        streamWriteFloat32(streamId, animal.insemination.genetics.productivity or 0)
    end

    streamWriteBool(streamId, animal.canBeSold == false)

    return true
end

--- Read full animal state from network stream.
--- Called during client join sync and buy-animal receive.
--- CRITICAL: Field order must match writeStream exactly.
--- @param animal table Animal instance to populate
--- @param streamId number Network stream handle
--- @param connection table Network connection
--- @return boolean success
function AnimalSerialization.readStream(animal, streamId, connection)
    local subTypeIndex = streamReadUInt8(streamId)
    local subTypeName = streamReadString(streamId)
    animal.subTypeIndex, _, animal.subType = Animal.resolveSubType(subTypeIndex, subTypeName)
    animal.animalTypeIndex = g_currentMission.animalSystem:getTypeIndexBySubTypeIndex(animal.subTypeIndex) or 1

    animal.age = streamReadUInt16(streamId)
    animal.health = streamReadFloat32(streamId)
    animal.reproduction = streamReadFloat32(streamId)
    animal.monthsSinceLastBirth = streamReadUInt16(streamId)
    animal.gender = streamReadString(streamId)

    animal.isParent = streamReadBool(streamId)
    animal.isPregnant = streamReadBool(streamId)
    animal.isLactating = streamReadBool(streamId)

    animal.recentlyBoughtByAI = streamReadBool(streamId)

    local numMarks = streamReadUInt8(streamId)

    for i = 1, numMarks do
        local key = streamReadString(streamId)
        local active = streamReadBool(streamId)

        if animal.marks[key] ~= nil then
            animal.marks[key].active = active
        else
            Log:warning("readStream: unknown mark key '%s' for animal %s, skipping", key, tostring(animal.uniqueId))
        end
    end

    animal.uniqueId = streamReadString(streamId)
    animal.farmId = streamReadString(streamId)
    animal.variation = streamReadUInt8(streamId)
    animal.motherId = streamReadString(streamId)
    animal.fatherId = streamReadString(streamId)
    animal.weight = streamReadFloat32(streamId)
    animal.targetWeight = streamReadFloat32(streamId)

    local hasName = streamReadBool(streamId)
    animal.name = hasName and streamReadString(streamId) or nil

    animal.dirt = streamReadFloat32(streamId)
    animal.fitness = streamReadFloat32(streamId)
    animal.riding = streamReadFloat32(streamId)

    if animal.isPregnant then
        if streamReadBool(streamId) then
            local uniqueId = streamReadString(streamId)
            local metabolism = streamReadFloat32(streamId)
            local productivity = streamReadFloat32(streamId)
            local quality = streamReadFloat32(streamId)
            local health = streamReadFloat32(streamId)
            local fertility = streamReadFloat32(streamId)

            animal.impregnatedBy = {
                ["uniqueId"] = uniqueId,
                ["metabolism"] = metabolism,
                ["productivity"] = productivity,
                ["quality"] = quality,
                ["health"] = health,
                ["fertility"] = fertility
            }
        end

        local pregnancy = { ["expected"] = {}, ["pregnancies"] = {} }

        pregnancy.expected.day = streamReadUInt8(streamId)
        pregnancy.expected.month = streamReadUInt8(streamId)
        pregnancy.expected.year = streamReadUInt8(streamId)
        pregnancy.duration = streamReadUInt8(streamId)

        local numChildren = streamReadUInt8(streamId)

        for i = 1, numChildren do
            local health = streamReadFloat32(streamId)
            local gender = streamReadString(streamId)
            local childSubTypeIndex = streamReadUInt8(streamId)
            local childSubTypeName = streamReadString(streamId)
            local motherId = streamReadString(streamId)
            local fatherId = streamReadString(streamId)

            childSubTypeIndex = Animal.resolveSubType(childSubTypeIndex, childSubTypeName)

            local genetics = {}

            genetics.metabolism = streamReadFloat32(streamId)
            genetics.health = streamReadFloat32(streamId)
            genetics.fertility = streamReadFloat32(streamId)
            genetics.quality = streamReadFloat32(streamId)

            local productivity = streamReadFloat32(streamId)

            if productivity ~= nil then genetics.productivity = productivity end

            local child = Animal.new({
                age = 0,
                health = health,
                gender = gender,
                subTypeIndex = childSubTypeIndex,
                motherId = motherId,
                fatherId = fatherId,
                genetics = genetics
            })

            table.insert(pregnancy.pregnancies, child)
        end

        animal.pregnancy = pregnancy
    end

    if animal.isParent then
        local children = {}
        local numChildren = streamReadUInt16(streamId)

        for i = 1, numChildren do
            table.insert(children, {
                ["uniqueId"] = streamReadString(streamId),
                ["farmId"] = streamReadString(streamId)
            })
        end

        animal.children = children
    end

    animal.birthday = {
        ["day"] = streamReadUInt8(streamId),
        ["month"] = streamReadUInt8(streamId),
        ["year"] = streamReadUInt8(streamId),
        ["country"] = streamReadUInt8(streamId),
        ["lastAgeMonth"] = streamReadUInt8(streamId)
    }

    animal.genetics = {}
    local numGenetics = streamReadUInt8(streamId)

    for i = 1, numGenetics do
        local trait = streamReadString(streamId)
        local quality = streamReadFloat32(streamId)
        animal.genetics[trait] = quality
    end

    animal.monitor = {
        ["active"] = streamReadBool(streamId),
        ["removed"] = streamReadBool(streamId),
        ["fee"] = streamReadFloat32(streamId)
    }

    animal.isCastrated = streamReadBool(streamId)

    local numDiseases = streamReadUInt8(streamId)
    local diseases = {}

    for i = 1, numDiseases do
        local diseaseTitle = streamReadString(streamId)
        -- Both identifiers are read off the wire well before this block, so they name the animal
        -- this record belongs to rather than whatever the target shell held. tostring on the way
        -- in keeps the key present even when a field is absent, so a grep cannot under-count.
        local diseaseType = g_diseaseManager ~= nil
            and g_diseaseManager:resolveRecordType(diseaseTitle,
                { farmId = tostring(animal.farmId), uniqueId = tostring(animal.uniqueId),
                  context = "stream" })
            or nil

        -- CONSTRUCT and read regardless of whether the type resolved. Disease:readStream is what
        -- consumes the eight fields the sender wrote after the title, so skipping it would leave
        -- them on the wire and every field after this block would decode from the wrong offset.
        -- Only the insert below is gated, and the nil-type record never escapes this loop.
        local disease = Disease.new(diseaseType)

        disease:readStream(streamId, connection)

        if diseaseType ~= nil then table.insert(diseases, disease) end
    end

    if g_diseaseManager == nil and numDiseases > 0 then
        Log:warning("readStream: dropped %s disease record(s), reason=no disease manager (farmId=%s uniqueId=%s)",
            tostring(numDiseases), tostring(animal.farmId), tostring(animal.uniqueId))
    end

    animal.diseases = diseases

    local hasInsemination = streamReadBool(streamId)
    local insemination

    if hasInsemination then
        insemination = {
            ["country"] = streamReadUInt8(streamId),
            ["farmId"] = streamReadString(streamId),
            ["uniqueId"] = streamReadString(streamId),
            ["name"] = streamReadString(streamId),
            ["subTypeIndex"] = streamReadUInt8(streamId),
            ["genetics"] = {},
            ["success"] = streamReadFloat32(streamId)
        }

        insemination.genetics.metabolism = streamReadFloat32(streamId)
        insemination.genetics.health = streamReadFloat32(streamId)
        insemination.genetics.fertility = streamReadFloat32(streamId)
        insemination.genetics.quality = streamReadFloat32(streamId)
        insemination.genetics.productivity = streamReadFloat32(streamId)

        if insemination.genetics.productivity == 0 then insemination.genetics.productivity = nil end

        local animalSystem = g_currentMission.animalSystem
        local st = animalSystem:getSubTypeByIndex(insemination.subTypeIndex)
        Log:debug("readStream insemination: subTypeIndex=%d -> resolved=%s (name=%s)",
            insemination.subTypeIndex, st and st.name or "nil", insemination.name or "?")
        if st == nil then
            Log:warning("readStream insemination: subTypeIndex=%d has no matching subtype", insemination.subTypeIndex)
        end
    end

    animal.insemination = insemination

    -- NOTE: Use explicit if - Lua and/or ternary fails when the true-branch is false.
    local cannotBeSold = streamReadBool(streamId)
    if cannotBeSold then animal.canBeSold = false end

    return true
end

--- Write unborn animal state to network stream.
--- Called during pregnancy event sync.
--- CRITICAL: Field order must match readStreamUnborn exactly.
--- @param animal table Animal instance (unborn child)
--- @param streamId number Network stream handle
--- @param connection table Network connection
--- @return boolean success
function AnimalSerialization.writeStreamUnborn(animal, streamId, connection)
    streamWriteUInt8(streamId, animal.subTypeIndex)
    streamWriteString(streamId, animal.subType or "")

    streamWriteFloat32(streamId, animal.health)
    streamWriteString(streamId, animal.gender)

    streamWriteString(streamId, animal.motherId or "-1")
    streamWriteString(streamId, animal.fatherId or "-1")
    streamWriteFloat32(streamId, animal.targetWeight)

    local genetics, numGenetics = animal.genetics, 0

    for trait, quality in pairs(genetics) do numGenetics = numGenetics + 1 end

    streamWriteUInt8(streamId, numGenetics)

    for trait, quality in pairs(genetics) do
        streamWriteString(streamId, trait)
        streamWriteFloat32(streamId, quality)
    end

    streamWriteUInt8(streamId, #animal.diseases)

    for i = 1, #animal.diseases do
        animal.diseases[i]:writeStream(streamId, connection)
    end

    return true
end

--- Read unborn animal state from network stream.
--- Called during pregnancy event receive.
--- CRITICAL: Field order must match writeStreamUnborn exactly.
--- @param animal table Animal instance to populate
--- @param streamId number Network stream handle
--- @param connection table Network connection
--- @return boolean success
function AnimalSerialization.readStreamUnborn(animal, streamId, connection)
    local subTypeIndex = streamReadUInt8(streamId)
    local subTypeName = streamReadString(streamId)
    animal.subTypeIndex, _, animal.subType = Animal.resolveSubType(subTypeIndex, subTypeName)
    animal.animalTypeIndex = g_currentMission.animalSystem:getTypeIndexBySubTypeIndex(animal.subTypeIndex) or 1

    animal.health = streamReadFloat32(streamId)
    animal.gender = streamReadString(streamId)

    animal.motherId = streamReadString(streamId)
    animal.fatherId = streamReadString(streamId)
    animal.targetWeight = streamReadFloat32(streamId)

    animal.genetics = {}
    local numGenetics = streamReadUInt8(streamId)

    for i = 1, numGenetics do
        local trait = streamReadString(streamId)
        local quality = streamReadFloat32(streamId)
        animal.genetics[trait] = quality
    end

    local numDiseases = streamReadUInt8(streamId)
    local diseases = {}

    for i = 1, numDiseases do
        local diseaseTitle = streamReadString(streamId)
        -- subTypeIndex is the only identifier this path holds: an unborn animal is assigned
        -- neither uniqueId nor farmId, so naming either would put a nil in every warning.
        local diseaseType = g_diseaseManager ~= nil
            and g_diseaseManager:resolveRecordType(diseaseTitle,
                { subTypeIndex = tostring(animal.subTypeIndex), context = "streamUnborn" })
            or nil

        -- Construct and read regardless, exactly as readStream does - the eight fields must leave
        -- the wire whether or not the record survives. This block is the LAST read of the unborn
        -- payload, so a skipped read strands the bytes rather than corrupting a following field.
        local disease = Disease.new(diseaseType)

        disease:readStream(streamId, connection)

        if diseaseType ~= nil then table.insert(diseases, disease) end
    end

    if g_diseaseManager == nil and numDiseases > 0 then
        Log:warning("readStreamUnborn: dropped %s disease record(s), reason=no disease manager (subTypeIndex=%s)",
            tostring(numDiseases), tostring(animal.subTypeIndex))
    end

    animal.diseases = diseases

    return true
end
