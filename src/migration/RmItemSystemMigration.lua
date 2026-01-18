--[[
    RmItemSystemMigration.lua

    NON-DESTRUCTIVE in-memory migration for items.xml and handTools.xml.

    This approach does NOT write to disk files. Instead, it patches the in-memory
    XMLFile objects before items/hand tools are loaded. When the game saves,
    it writes the correct (new mod) references naturally.

    Benefits:
    - User can switch back to old mod anytime (before saving) without data loss
    - No risk of corrupting savegame files during migration
    - Migration is "confirmed" only when user saves the game

    Hooks:
    - HandToolSystem.loadFromXMLFile: Patches handTools.xml in memory
    - ItemSystem.loadItemsFromXML: Patches items.xml in memory (first call only)
]]

RmItemSystemMigration = {}

local OLD_MOD_NAME = "FS25_RealisticLivestock"
local NEW_MOD_NAME = "FS25_RealisticLivestockRM"
local OLD_MOD_DIR = "$moddir$" .. OLD_MOD_NAME .. "/"
local NEW_MOD_DIR = "$moddir$" .. NEW_MOD_NAME .. "/"

-- Flags to track if we've patched each file (only patch once per session)
local handToolsXmlPatched = false
local itemsXmlPatched = false

--[[
    Update in-memory XMLFile with migrated filename values for handTools.xml.
    Changes $moddir$FS25_RealisticLivestock/ to $moddir$FS25_RealisticLivestockRM/
]]
local function updateInMemoryHandToolsXml(xmlFile)
    if xmlFile == nil or type(xmlFile) ~= "table" then
        return 0
    end

    local patchedCount = 0
    local index = 0

    while true do
        local key = string.format("handTools.handTool(%d)", index)
        if not xmlFile:hasProperty(key) then
            break
        end

        local filename = xmlFile:getString(key .. "#filename")
        if filename ~= nil and string.find(filename, OLD_MOD_DIR, 1, true) ~= nil then
            local newFilename = string.gsub(filename, OLD_MOD_DIR, NEW_MOD_DIR)
            xmlFile:setString(key .. "#filename", newFilename)
            print("RmItemSystemMigration: [handTools] Patched filename: " .. filename .. " -> " .. newFilename)
            patchedCount = patchedCount + 1
        end

        index = index + 1
    end

    return patchedCount
end

--[[
    Update in-memory XMLFile with migrated values for items.xml.
    Changes both modName and className attributes from FS25_RealisticLivestock to FS25_RealisticLivestockRM
]]
local function updateInMemoryItemsXml(xmlFile)
    if xmlFile == nil or type(xmlFile) ~= "table" then
        return 0
    end

    local patchedCount = 0
    local index = 0
    local oldClassPrefix = OLD_MOD_NAME .. "."
    local newClassPrefix = NEW_MOD_NAME .. "."

    while true do
        local key = string.format("items.item(%d)", index)
        if not xmlFile:hasProperty(key) then
            break
        end

        local itemPatched = false

        -- Patch modName attribute
        local modName = xmlFile:getString(key .. "#modName")
        if modName == OLD_MOD_NAME then
            xmlFile:setString(key .. "#modName", NEW_MOD_NAME)
            print("RmItemSystemMigration: [items] Patched modName: " .. OLD_MOD_NAME .. " -> " .. NEW_MOD_NAME .. " for " .. key)
            itemPatched = true
        end

        -- Patch className attribute (e.g., "FS25_RealisticLivestock.Dewar" -> "FS25_RealisticLivestockRM.Dewar")
        local className = xmlFile:getString(key .. "#className")
        if className ~= nil and string.find(className, oldClassPrefix, 1, true) == 1 then
            local newClassName = newClassPrefix .. string.sub(className, #oldClassPrefix + 1)
            xmlFile:setString(key .. "#className", newClassName)
            print("RmItemSystemMigration: [items] Patched className: " .. className .. " -> " .. newClassName .. " for " .. key)
            itemPatched = true
        end

        if itemPatched then
            patchedCount = patchedCount + 1
        end

        index = index + 1
    end

    return patchedCount
end

--[[
    Prepended function for HandToolSystem:loadFromXMLFile
    Patches handTools.xml in memory before hand tools are loaded.

    NOTE: Using dot notation because Utils.prependedFunction passes
    the original 'self' as the first explicit parameter.
]]
function RmItemSystemMigration.loadHandToolsPrepend(handToolSystem, xmlFileOrFilename, asyncCallbackFunction, asyncCallbackObject, asyncCallbackArguments)
    -- Only patch once per session
    if handToolsXmlPatched then
        return
    end

    print("RmItemSystemMigration: HandToolSystem:loadFromXMLFile prepend called")

    -- Extract XMLFile object if it's a table
    local xmlFileObj = nil
    if xmlFileOrFilename ~= nil and type(xmlFileOrFilename) == "table" and xmlFileOrFilename.getFilename ~= nil then
        xmlFileObj = xmlFileOrFilename
        print("RmItemSystemMigration: Got XMLFile object for handTools.xml: " .. tostring(xmlFileObj:getFilename()))
    end

    -- Patch the in-memory XMLFile
    if xmlFileObj ~= nil then
        local patchedCount = updateInMemoryHandToolsXml(xmlFileObj)
        handToolsXmlPatched = true

        if patchedCount > 0 then
            print(string.format("RmItemSystemMigration: Patched %d hand tools in memory (no disk write)", patchedCount))
            g_rmPendingMigration = true
        else
            print("RmItemSystemMigration: No hand tools needed patching")
        end
    end
end

--[[
    Prepended function for ItemSystem:loadItemsFromXML
    Patches items.xml in memory before each item is loaded.

    NOTE: This is called for EACH item, but we only patch once (first call).
]]
function RmItemSystemMigration.loadItemsFromXMLPrepend(itemSystem, xmlFile, key)
    -- Only patch once per session
    if itemsXmlPatched then
        return
    end

    print("RmItemSystemMigration: ItemSystem:loadItemsFromXML prepend called (first time)")

    -- Patch the in-memory XMLFile
    if xmlFile ~= nil and type(xmlFile) == "table" then
        local patchedCount = updateInMemoryItemsXml(xmlFile)
        itemsXmlPatched = true

        if patchedCount > 0 then
            print(string.format("RmItemSystemMigration: Patched %d items in memory (no disk write)", patchedCount))
            g_rmPendingMigration = true
        else
            print("RmItemSystemMigration: No items needed patching")
        end
    end
end

-- Hook into HandToolSystem.loadFromXMLFile - patches handTools.xml in memory
if HandToolSystem ~= nil and HandToolSystem.loadFromXMLFile ~= nil then
    HandToolSystem.loadFromXMLFile = Utils.prependedFunction(
        HandToolSystem.loadFromXMLFile,
        RmItemSystemMigration.loadHandToolsPrepend
    )
    print("RmItemSystemMigration: Hook registered for HandToolSystem.loadFromXMLFile")
else
    print("RmItemSystemMigration: WARNING - HandToolSystem.loadFromXMLFile not found!")
end

-- Hook into ItemSystem.loadItemsFromXML - patches items.xml in memory
if ItemSystem ~= nil and ItemSystem.loadItemsFromXML ~= nil then
    ItemSystem.loadItemsFromXML = Utils.prependedFunction(
        ItemSystem.loadItemsFromXML,
        RmItemSystemMigration.loadItemsFromXMLPrepend
    )
    print("RmItemSystemMigration: Hook registered for ItemSystem.loadItemsFromXML")
else
    print("RmItemSystemMigration: WARNING - ItemSystem.loadItemsFromXML not found!")
end
