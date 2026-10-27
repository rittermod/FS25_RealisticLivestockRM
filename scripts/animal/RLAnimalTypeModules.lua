--[[
    RLAnimalTypeModules.lua
    The per-type behaviour table: an animal type NAME maps to a hook table that the Animal routing points ask.
    A type with no entry, or an entry without a hook, keeps base behaviour, and a worker method answers false.
    Entries are built on the first lookup, never at file scope, and capture the module functions they name.
    Load, stream and clone are not hooks: the horse and alpaca fields load, stream and clone for every type.
    A getSellPrice or getHealthFoodFactor hook returning nil keeps the base value, as getVisual does.
]]

RLAnimalTypeModules = {}

local Log = RmLogging.getLogger("RLRM")

--- The hook contract by name; every hook takes the animal first.
RLAnimalTypeModules.HOOKS = {
    "getDefaultName",      -- () -> string|nil, mid-constructor: no birthday yet
    "addInfos",            -- (infos)
    "showHudInfo",         -- (box)
    "onDayChanged",        -- ()
    "getSellPrice",        -- (sellPrice, meatFactor, weightFactor) -> number|nil, nil keeps the base formula
    "getHealthFoodFactor", -- (foodFactor) -> number|nil, nil keeps the raw food factor
    "saveFields",          -- (xmlFile, key)
    "addDealerInfos",      -- (infos)
    "getVisual",           -- (visual|nil) -> table|nil, nil keeps the base visual
    "getSupportsExercise", -- () -> boolean, as are the five below
    "getNeedsExercise",
    "applyExercise",
    "getSupportsGrooming",
    "getNeedsGrooming",
    "applyGrooming",
}

--- The built entries, keyed by type name; nil until the first get.
RLAnimalTypeModules.entries = nil


--- Build every entry. A missing type module raises here, before anything is memoized.
--- @return table entries type name -> hook table
local function buildEntries()
    local entries = {
        HORSE = {
            getDefaultName = AnimalHorse.getDefaultName,
            addInfos = AnimalHorse.addHorseInfos,
            showHudInfo = AnimalHorse.showHorseHudInfo,
            onDayChanged = AnimalHorse.processRidingUpdate,
            getSellPrice = AnimalHorse.getHorseSellPrice,
            saveFields = AnimalHorse.saveHorseFields,
            addDealerInfos = AnimalHorse.addDealerInfos,
            getSupportsExercise = AnimalHorse.getSupportsExercise,
            getNeedsExercise = AnimalHorse.getNeedsExercise,
            applyExercise = AnimalHorse.applyExercise,
            getSupportsGrooming = AnimalHorse.getSupportsGrooming,
            getNeedsGrooming = AnimalHorse.getNeedsGrooming,
            applyGrooming = AnimalHorse.applyGrooming,
        },
        ALPACA = {
            getDefaultName = AnimalAlpaca.getDefaultName,
            addInfos = AnimalAlpaca.addInfos,
            showHudInfo = AnimalAlpaca.showHudInfo,
            onDayChanged = AnimalAlpaca.onDayChanged,
            getSellPrice = AnimalAlpaca.getSellPrice,
            getHealthFoodFactor = AnimalAlpaca.getHealthFoodFactor,
            saveFields = AnimalAlpaca.saveFields,
            addDealerInfos = AnimalAlpaca.addDealerInfos,
        },
    }

    local summary = {}
    for typeName, entry in pairs(entries) do
        local count = 0
        for _ in pairs(entry) do count = count + 1 end
        summary[#summary + 1] = string.format("%s=%d", typeName, count)
    end
    table.sort(summary)
    Log:debug("RLAnimalTypeModules: built entries %s", table.concat(summary, ", "))

    return entries
end


--- The hook table for an animal type name, or nil for nil or a type with no entry.
--- @param typeName string|nil animal type name (typeIndexToName of the animal's type)
--- @return table|nil entry
function RLAnimalTypeModules.get(typeName)
    if typeName == nil then
        Log:trace("RLAnimalTypeModules.get: nil type name -> none")
        return nil
    end

    if RLAnimalTypeModules.entries == nil then
        RLAnimalTypeModules.entries = buildEntries()
    end

    local entry = RLAnimalTypeModules.entries[typeName]
    Log:trace("RLAnimalTypeModules.get: %s -> %s", tostring(typeName), entry ~= nil and "entry" or "none")
    return entry
end
