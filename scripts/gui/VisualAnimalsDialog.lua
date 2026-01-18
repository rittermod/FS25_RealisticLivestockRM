VisualAnimalsDialog = {}

local visualAnimalsDialog_mt = Class(VisualAnimalsDialog, YesNoDialog)
local modDirectory = g_currentModDirectory

function VisualAnimalsDialog.register()
    local dialog = VisualAnimalsDialog.new()
    g_gui:loadGui(modDirectory .. "gui/VisualAnimalsDialog.xml", "VisualAnimalsDialog", dialog)
    VisualAnimalsDialog.INSTANCE = dialog
end


function VisualAnimalsDialog.show()

    if VisualAnimalsDialog.INSTANCE == nil then VisualAnimalsDialog.register() end

    if VisualAnimalsDialog.INSTANCE ~= nil then
        local instance = VisualAnimalsDialog.INSTANCE
        local profile = Utils.getPerformanceClassId()

        local recommendedAnimals = (profile == GS_PROFILE_VERY_LOW and 8) or (profile == GS_PROFILE_LOW and 10) or (profile == GS_PROFILE_MEDIUM and 16) or (profile == GS_PROFILE_HIGH and 20) or (profile == GS_PROFILE_VERY_HIGH and 25) or (profile == GS_PROFILE_ULTRA and 25) or 8
        local maxHusbandries = RealisticLivestock_AnimalClusterHusbandry.MAX_HUSBANDRIES

        --local currentMaxAnimals = recommendedAnimals * maxHusbandries
        local currentMaxAnimals = 1 * maxHusbandries
        local maxAnimals = recommendedAnimals * 8

        instance.recommendedAnimals = recommendedAnimals

        instance:setQuantity(maxAnimals)
        instance.quantityElement:setState(maxHusbandries)

        g_gui:showDialog("VisualAnimalsDialog")
    end
end


function VisualAnimalsDialog.new(target, customMt)
    local dialog = YesNoDialog.new(target, customMt or visualAnimalsDialog_mt)
    dialog.areButtonsDisabled = false
    dialog.recommendedAnimals = 8
    return dialog
end


function VisualAnimalsDialog.createFromExistingGui(gui, _)

    VisualAnimalsDialog.register()
    VisualAnimalsDialog.show()

end


function VisualAnimalsDialog:onOpen()

    VisualAnimalsDialog:superClass().onOpen(self)
    FocusManager:setFocus(self.itemsElement)

end


function VisualAnimalsDialog:onClose()
    VisualAnimalsDialog:superClass().onClose(self)
end


function VisualAnimalsDialog:onRecommended()

    if self.areButtonsDisabled then return true end

    self.quantityElement:setState(self.recommendedAnimals * 2)

    return false

end


function VisualAnimalsDialog:onYes()

    if self.areButtonsDisabled then return true end

    local maxHusbandries = RealisticLivestock_AnimalClusterHusbandry.MAX_HUSBANDRIES
    local newMaxHusbandries = self.quantityElement:getState()


    local husbandrySystem = g_currentMission.husbandrySystem

    if maxHusbandries ~= newMaxHusbandries then

        RealisticLivestock_AnimalClusterHusbandry.MAX_HUSBANDRIES = newMaxHusbandries
        for _, clusterHusbandry in ipairs(husbandrySystem.clusterHusbandries) do
            clusterHusbandry.nextUpdateClusters = clusterHusbandry.placeable.spec_husbandryAnimals.clusterSystem:getAnimals()
            clusterHusbandry:updateVisuals(maxHusbandries > newMaxHusbandries)
        end

    end

    self:close()

    return false

end


function VisualAnimalsDialog:onNo(_, _)

    self:close()
    return false

end


function VisualAnimalsDialog:setQuantity(quantity)

    if quantity < 1 then quantity = 1 end
    self.maxQuantity = quantity

    local texts = {}

    for i=1, quantity do
        local text = tostring(i)
        table.insert(texts, text)
    end

    self.quantityElement:setTexts(texts)

end


function VisualAnimalsDialog:setButtonDisabled(disabled)
    self.areButtonsDisabled = disabled
    self.yesButton:setDisabled(disabled)
end