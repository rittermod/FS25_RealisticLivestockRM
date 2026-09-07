AnimalPregnancyEvent = {}

local AnimalPregnancyEvent_mt = Class(AnimalPregnancyEvent, Event)
InitEventClass(AnimalPregnancyEvent, "AnimalPregnancyEvent")


function AnimalPregnancyEvent.emptyNew()
    local self = Event.new(AnimalPregnancyEvent_mt)
    return self
end


function AnimalPregnancyEvent.new(object, animal)

    local self = AnimalPregnancyEvent.emptyNew()

    self.object = object
    self.animal = animal

    return self

end


--- Read a pregnancy event from the network stream, then dispatch via :run(connection).
--- @param streamId number Network stream identifier
--- @param connection Connection|nil Network connection sending this event
function AnimalPregnancyEvent:readStream(streamId, connection)

    local hasObject = streamReadBool(streamId)

    self.object = hasObject and NetworkUtil.readNodeObject(streamId) or nil
    self.animal = RLAnimalUtil.readStreamIdentifiers(streamId, connection)

    local pregnancy = { ["expected"] = {}, ["pregnancies"] = {} }
    local impregnatedBy = {}

    pregnancy.duration = streamReadUInt8(streamId)
    pregnancy.expected.day = streamReadUInt8(streamId)
    pregnancy.expected.month = streamReadUInt8(streamId)
    pregnancy.expected.year = streamReadUInt8(streamId)

    local numChildren = streamReadUInt8(streamId)

    for i = 1, numChildren do

        local child = Animal.new()
        child:readStreamUnborn(streamId, connection)

        if child ~= nil then table.insert(pregnancy.pregnancies, child) end

    end

    impregnatedBy.uniqueId = streamReadString(streamId)
    impregnatedBy.metabolism = streamReadFloat32(streamId)
    impregnatedBy.health = streamReadFloat32(streamId)
    impregnatedBy.fertility = streamReadFloat32(streamId)
    impregnatedBy.quality = streamReadFloat32(streamId)
    impregnatedBy.productivity = streamReadFloat32(streamId)

    self.pregnancy = pregnancy
    self.impregnatedBy = impregnatedBy

    self:run(connection)

end


--- Write a pregnancy event to the network stream. Productivity is coalesced to 1.0 on write,
--- matching the serializer: pigs and horses do not track it, so the field can be nil.
--- @param streamId number Network stream identifier
--- @param connection Connection|nil Network connection receiving this event
function AnimalPregnancyEvent:writeStream(streamId, connection)

    streamWriteBool(streamId, self.object ~= nil)

    if self.object ~= nil then

        NetworkUtil.writeNodeObject(streamId, self.object)

    end
    
    RLAnimalUtil.writeStreamIdentifiers(self.animal, streamId, connection)
    
    local pregnancy = self.animal.pregnancy
    local impregnatedBy = self.animal.impregnatedBy

    streamWriteUInt8(streamId, pregnancy.duration)
    streamWriteUInt8(streamId, pregnancy.expected.day)
    streamWriteUInt8(streamId, pregnancy.expected.month)
    streamWriteUInt8(streamId, pregnancy.expected.year)

    streamWriteUInt8(streamId, #pregnancy.pregnancies)

    for _, child in pairs(pregnancy.pregnancies) do

        child:writeStreamUnborn(streamId, connection)

    end

    streamWriteString(streamId, impregnatedBy.uniqueId)
    streamWriteFloat32(streamId, impregnatedBy.metabolism)
    streamWriteFloat32(streamId, impregnatedBy.health)
    streamWriteFloat32(streamId, impregnatedBy.fertility)
    streamWriteFloat32(streamId, impregnatedBy.quality)
    streamWriteFloat32(streamId, impregnatedBy.productivity or 1)

end


function AnimalPregnancyEvent:run(connection)

    local identifiers = self.animal
    local animals

    if self.object == nil then
        animals = g_currentMission.animalSystem.animals[identifiers.animalTypeIndex]
    else
        animals = self.object:getClusterSystem().animals
    end

    Log:trace("PregnancyEvent:run uniqueId=%s", tostring(identifiers.uniqueId))

    local animal = RLAnimalUtil.find(animals, identifiers.farmId, identifiers.uniqueId, identifiers.country or identifiers.birthday.country)

    if animal ~= nil then
        animal.isPregnant = true
        animal.pregnancy = self.pregnancy
        animal.impregnatedBy = self.impregnatedBy
        animal.reproduction = 0

        animal:changeReproduction(animal:getReproductionDelta())
        Log:trace("PregnancyEvent:run applied pregnancy to %s", tostring(animal.uniqueId))
    else
        Log:trace("PregnancyEvent:run animal not found uniqueId=%s", tostring(identifiers.uniqueId))
    end

end