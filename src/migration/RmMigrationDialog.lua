--[[
    RmMigrationDialog.lua
    Dialog for prompting user about data migration from old RealisticLivestock mod
]]

RmMigrationDialog = {}

local RmMigrationDialog_mt = Class(RmMigrationDialog, MessageDialog)
local modDirectory = g_currentModDirectory

-- Singleton instance
RmMigrationDialog.INSTANCE = nil


function RmMigrationDialog.register()
    local dialog = RmMigrationDialog.new()
    g_gui:loadGui(modDirectory .. "gui/RmMigrationDialog.xml", "RmMigrationDialog", dialog)
    RmMigrationDialog.INSTANCE = dialog
end


function RmMigrationDialog.new(target, customMt)
    local self = MessageDialog.new(target, customMt or RmMigrationDialog_mt)
    self.files = {}
    return self
end


function RmMigrationDialog.show(files)
    if RmMigrationDialog.INSTANCE == nil then
        RmMigrationDialog.register()
    end

    local dialog = RmMigrationDialog.INSTANCE
    dialog.files = files or {}
    dialog:setDialogType(DialogElement.TYPE_INFO)
    dialog:updateContent()

    g_gui:showDialog("RmMigrationDialog")
end


function RmMigrationDialog:onOpen()
    RmMigrationDialog:superClass().onOpen(self)
    FocusManager:setFocus(self.continueButton)
end


function RmMigrationDialog:onClose()
    RmMigrationDialog:superClass().onClose(self)
    self.files = {}
end


function RmMigrationDialog:onCreate()
    RmMigrationDialog:superClass().onCreate(self)
end


function RmMigrationDialog:updateContent()
    -- Update title
    if self.titleElement ~= nil then
        self.titleElement:setText(g_i18n:getText("rm_rl_migration_title"))
    end

    -- Update message
    if self.messageElement ~= nil then
        self.messageElement:setText(g_i18n:getText("rm_rl_migration_message"))
    end

    -- Update file list
    if self.fileListElement ~= nil then
        local fileText = ""
        for _, file in ipairs(self.files) do
            fileText = fileText .. "- " .. file.name .. " (" .. file.type .. ")\n"
        end
        self.fileListElement:setText(fileText)
    end
end


--[[
    User clicked "Continue" button
    Close the dialog and continue loading - migration happens automatically via dual-read/new-save
]]
function RmMigrationDialog:onClickContinue()
    self:close()
end


--[[
    User clicked "Quit" button
    Exit to main menu
]]
function RmMigrationDialog:onClickQuit()
    doRestart(false, "")
end
