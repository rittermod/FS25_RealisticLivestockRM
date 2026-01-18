RealisticLivestock_PlaceableSystem = {}

local modSettingsDirectory = g_currentModSettingsDirectory

function RealisticLivestock_PlaceableSystem:saveToXML(_, _)

    createFolder(modSettingsDirectory)
    local xmlFile = XMLFile.loadIfExists("RealisticLivestock", modSettingsDirectory .. "Settings.xml")

    if xmlFile == nil then xmlFile = XMLFile.create("RealisticLivestock", modSettingsDirectory .. "Settings.xml", "Settings") end

    if xmlFile ~= nil then

        xmlFile:setInt("Settings.setting(0)#maxHusbandries", RealisticLivestock_AnimalClusterHusbandry.MAX_HUSBANDRIES)
        xmlFile:save(false, true)
        xmlFile:delete()

    end

end

PlaceableSystem.saveToXML = Utils.prependedFunction(PlaceableSystem.saveToXML, RealisticLivestock_PlaceableSystem.saveToXML)