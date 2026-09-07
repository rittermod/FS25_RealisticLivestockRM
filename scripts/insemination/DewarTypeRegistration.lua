--[[
    DewarTypeRegistration.lua

    Registers the DewarData vehicle specialization and the rlDewar vehicle type
    (extending base-game "pallet") in Lua rather than through modDesc.xml. The XML
    registration path cannot resolve the parent "pallet" type's script under the mod
    directory and logs a resource-load error for it; registering here resolves the
    parent through the mod env metatable fallback instead.
]]

local modDirectory = g_currentModDirectory
local modName = g_currentModName
local dewarDataPath = Utils.getFilename("scripts/insemination/DewarData.lua", modDirectory)

-- The mod-scoped addSpecialization proxy auto-prefixes name and className with modName,
-- so this registers as "<modName>.dewarData" / "<modName>.DewarData".
g_specializationManager:addSpecialization(
    "dewarData",
    "DewarData",
    dewarDataPath,
    nil
)

-- DewarData.lua doubles as the type's script filename; re-sourcing it is idempotent, the
-- file holding only definitions. addType takes no parent argument, so the pallet type's
-- specialization list is inherited by hand below.
g_vehicleTypeManager:addType(
    "rlDewar",
    "Vehicle",
    dewarDataPath,
    nil
)

local fullTypeName = modName .. ".rlDewar"
local palletType = g_vehicleTypeManager:getTypeByName("pallet")
if palletType ~= nil then
    for _, specName in ipairs(palletType.specializationNames) do
        g_vehicleTypeManager:addSpecialization(fullTypeName, specName)
    end
else
    Log:error("DewarTypeRegistration: pallet type not found - rlDewar will be missing base specializations")
end

g_vehicleTypeManager:addSpecialization(fullTypeName, "dewarData")

Log:info("DewarTypeRegistration: registered rlDewar vehicle type with dewarData specialization")
