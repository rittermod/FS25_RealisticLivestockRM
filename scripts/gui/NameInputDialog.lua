NameInputDialog = {}

local nameInputDialog_mt = Class(NameInputDialog, YesNoDialog)
local function nameInputDialog_callback() end
local modDirectory = g_currentModDirectory


function NameInputDialog.register()
    local dialog = NameInputDialog.new()
    g_gui:loadGui(modDirectory .. "gui/NameInputDialog.xml", "NameInputDialog", dialog)
    NameInputDialog.INSTANCE = dialog
    dialog.textElement.maxCharacters = 20
end


function NameInputDialog.show(callback, target, text, prompt, maxCharacters, args, gender)
    if NameInputDialog.INSTANCE ~= nil then
        local dialog = NameInputDialog.INSTANCE
        dialog:setText(text)
        dialog:setCallback(callback, target, text, prompt, maxCharacters, args, gender)
        g_gui:showDialog("NameInputDialog")
    end
end


function NameInputDialog.new(target, customMt)
    local dialog = YesNoDialog.new(target, customMt or nameInputDialog_mt)
    dialog.onTextEntered = nameInputDialog_callback
    dialog.callbackArgs = nil
    dialog.extraInputDisableTime = 0
    local dismiss = GS_IS_CONSOLE_VERSION
    if dismiss then dismiss = imeIsSupported() end
    dialog.doHide = dismiss
    dialog.disableOpenSound = true
    dialog.animalGender = "female"
    return dialog
end


function NameInputDialog.createFromExistingGui(gui, _)
    NameInputDialog.register()
    local callback = gui.onTextEntered
    local target = gui.target
    local text = gui.defaultText
    local prompt = gui.dialogPrompt
    local maxCharacters = gui.maxCharacters
    local args = gui.callbackArgs
    NameInputDialog.show(callback, target, text, prompt, maxCharacters, args)
end


function NameInputDialog:onOpen()
    NameInputDialog:superClass().onOpen(self)
    self.extraInputDisableTime = getPlatformId() == PlatformId.SWITCH and 0 or 100
    FocusManager:setFocus(self.textElement)
    self.textElement.blockTime = 0
    self.textElement:onFocusActivate()
    self:updateButtonVisibility()
end


function NameInputDialog:onClose()
    NameInputDialog:superClass().onClose(self)
    if not GS_IS_CONSOLE_VERSION then self.textElement:setForcePressed(false) end
    self:updateButtonVisibility()
end


function NameInputDialog:onClickRandom()

    local system = g_currentMission.animalNameSystem
    if system == nil then return end

    local attempts = 0

    local name = system:getRandomName(self.animalGender)
    while attempts < 10 and (name == nil or name == "" or name == self.textElement.text) do
        name = system:getRandomName(self.animalGender)
        attempts = attempts + 1
    end

    if name == nil or name == "" then return end

    self.textElement:setText(name)

end


function NameInputDialog:setText(text)
    NameInputDialog:superClass().setText(self,text)
    self.inputText = text
end


function NameInputDialog:setCallback(callback, target, text, prompt, maxCharacters, args, gender)

    self.onTextEntered = callback or nameInputDialog_callback
    self.target = target
    self.callbackArgs = args
    self.textElement:setText(text or "")
    self.textElement.maxCharacters = maxCharacters or self.textElement.maxCharacters

    if prompt ~= nil then self.dialogTextElement:setText(prompt) end

    self.dialogPrompt = prompt
    self.maxCharacters = maxCharacters
    self.animalGender = gender

end


function NameInputDialog:sendCallback(clickOk)
    local text = self.textElement.text
    self:close()

    local words = string.split(text, " ")

    while #words > 2 do

        words[2] = words[2] .. words[3]
        table.remove(words, 3)

    end

    if #words == 2 then text = words[1] .. " " .. words[2] end

    if self.target == nil then
        self.onTextEntered(text, clickOk, self.callbackArgs)
    else
        self.onTextEntered(self.target, text, clickOk, self.callbackArgs)
    end
end


function NameInputDialog:onEnterPressed( _, dismiss)
    return dismiss and true or self:onClickOk()
end


function NameInputDialog:onEscPressed(_)
    return self:onClickBack()
end


function NameInputDialog:onClickBack(_, _)
    if self:isInputDisabled() then return true end

    self:sendCallback(false)
    return false
end


function NameInputDialog:onClickOk()
    if self:isInputDisabled() then return true end

    self:sendCallback(true)
    self:updateButtonVisibility()
    return false
end


function NameInputDialog:updateButtonVisibility()
    if self.yesButton ~= nil then self.yesButton:setVisible(not self.textElement.imeActive) end
    if self.noButton ~= nil then self.noButton:setVisible(not self.textElement.imeActive) end
end


function NameInputDialog:update(dT)
    NameInputDialog:superClass().update(self, dT)

    if self.reactivateNextFrame then
        self.textElement.blockTime = 0
        self.textElement:onFocusActivate()
        self.reactivateNextFrame = false
        self:updateButtonVisibility()
    end
    if self.extraInputDisableTime > 0 then
        self.extraInputDisableTime = self.extraInputDisableTime - dT
    end
end


function NameInputDialog:isInputDisabled()
    local disabled

    if self.extraInputDisableTime > 0 then
        disabled = not self.doHide
    else
        disabled = false
    end

    return disabled
end


function NameInputDialog:disableInputForDuration(_) end


function NameInputDialog:getIsVisible()
    if self.doHide then return false end

    return NameInputDialog:superClass().getIsVisible(self)
end