RealisticLivestock_InGameMenuAnimalsFrame = {}


function RealisticLivestock_InGameMenuAnimalsFrame:displayCluster(superFunc, animal, husbandry)

    if g_currentMission.isRunning or Platform.isMobile then

        local animalSystem = g_currentMission.animalSystem
        local subTypeIndex = animal:getSubTypeIndex()
        local age = animal:getAge()
        local visual = animalSystem:getVisualByAge(subTypeIndex, age)

        if visual ~= nil then

            local subType = animal:getSubType()
            --local fillTypeTitle = g_fillTypeManager:getFillTypeTitleByIndex(subType.fillTypeIndex)

            local name = animal:getName()
            name = name ~= "" and (" (" .. name .. ")") or ""

            self.animalDetailTypeNameText:setText(animal.uniqueId .. name)
            self.animalDetailTypeImage:setImageFilename(visual.store.imageFilename)

            local ageMonth = g_i18n:formatNumMonth(age)
            self.animalAgeText:setText(ageMonth)

            local animalInfo = husbandry:getAnimalInfos(animal)

            for a, b in ipairs(self.infoRow) do

                local row = animalInfo[a]
                b:setVisible(row ~= nil)

                if row ~= nil then
                    local valueText = row.valueText or g_i18n:formatVolume(row.value, 0, row.customUnitText)
                    self.infoLabel[a]:setText(row.title)
                    self.infoValue[a]:setText(valueText)
                    self:setStatusBarValue(self.infoStatusBar[a], row.ratio, row.invertedBar, row.disabled)
                end

            end

            local description = husbandry:getAnimalDescription(animal)
            self.detailDescriptionText:setText(description)

        end

    end

end

InGameMenuAnimalsFrame.displayCluster = Utils.overwrittenFunction(InGameMenuAnimalsFrame.displayCluster, RealisticLivestock_InGameMenuAnimalsFrame.displayCluster)



function RealisticLivestock_InGameMenuAnimalsFrame:populateCellForItemInSection(_, subTypeIndex, animalIndex, cell)

    local subType = self.husbandrySubTypes[subTypeIndex]
    local animal = self.subTypeIndexToClusters[subType][animalIndex]

    if g_currentMission.animalSystem:getVisualByAge(subType, animal:getAge()) ~= nil then
        cell:getAttribute("name"):setText(animal.uniqueId .. (animal:getName() == "" and "" or (" (" .. animal:getName() .. ")")))
        cell:getAttribute("count"):setVisible(false)
    end

end

InGameMenuAnimalsFrame.populateCellForItemInSection = Utils.appendedFunction(InGameMenuAnimalsFrame.populateCellForItemInSection, RealisticLivestock_InGameMenuAnimalsFrame.populateCellForItemInSection)