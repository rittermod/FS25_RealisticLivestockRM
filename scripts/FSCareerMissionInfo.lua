RL_FSCareerMissionInfo = {}

function RL_FSCareerMissionInfo:saveToXMLFile()
    if self.xmlFile ~= nil and g_currentMission ~= nil and g_currentMission.animalSystem ~= nil then
        -- AnimalSystem:saveToXMLFile now ignores path parameter and saves to rm_RlAnimalSystem.xml
        g_currentMission.animalSystem:saveToXMLFile(self.savegameDirectory .. "/rm_RlAnimalSystem.xml")
        RLSettings.saveToXMLFile()
    end
end

FSCareerMissionInfo.saveToXMLFile = Utils.appendedFunction(FSCareerMissionInfo.saveToXMLFile, RL_FSCareerMissionInfo.saveToXMLFile)