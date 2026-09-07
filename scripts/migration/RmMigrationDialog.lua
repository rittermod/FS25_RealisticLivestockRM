--[[
    RmMigrationDialog.lua
    Dialog for prompting user about data migration from old RealisticLivestock mod
]]

RmMigrationDialog = {}

local RmMigrationDialog_mt = Class(RmMigrationDialog, MessageDialog)
local modDirectory = g_currentModDirectory
local Log = RmLogging.getLogger("RLRM")

RmMigrationDialog.INSTANCE = nil


function RmMigrationDialog.register()
    local dialog = RmMigrationDialog.new()
    g_gui:loadGui(modDirectory .. "gui/RmMigrationDialog.xml", "RmMigrationDialog", dialog)
    RmMigrationDialog.INSTANCE = dialog
end


function RmMigrationDialog.new(target, customMt)
    local self = MessageDialog.new(target, customMt or RmMigrationDialog_mt)
    self.files = {}
    self.continueCallback = nil
    return self
end


--[[
    Show the migration dialog.

    @param files table|nil List of {name, type} entries shown to the user.
    @param callback function|nil Invoked after the dialog closes via Continue, so a
        queued follow-up dialog never shows while this one is still up. The Quit path
        restarts and never fires it.
]]
function RmMigrationDialog.show(files, callback)
    if RmMigrationDialog.INSTANCE == nil then
        RmMigrationDialog.register()
    end

    local dialog = RmMigrationDialog.INSTANCE
    dialog.files = files or {}
    dialog.continueCallback = callback
    dialog:setDialogType(DialogElement.TYPE_INFO)
    dialog:updateContent()

    Log:debug("RmMigrationDialog.show: files=%d, callback=%s",
        #dialog.files, tostring(callback ~= nil))
    g_gui:showDialog("RmMigrationDialog")
end


function RmMigrationDialog:onOpen()
    RmMigrationDialog:superClass().onOpen(self)
    FocusManager:setFocus(self.continueButton)
end


function RmMigrationDialog:onClose()
    RmMigrationDialog:superClass().onClose(self)
    self.files = {}
    -- Drop a pending continueCallback so an ESC or back-button dismiss does not leak it
    -- into the next show(). Deliberately not fired here: stalling the queue beats showing
    -- the next dialog from an already-closing context.
    if self.continueCallback ~= nil then
        Log:debug("Migration dialog: onClose dropped pending continueCallback")
        self.continueCallback = nil
    end
end


function RmMigrationDialog:onCreate()
    RmMigrationDialog:superClass().onCreate(self)
end


function RmMigrationDialog:updateContent()
    if self.titleElement ~= nil then
        self.titleElement:setText(g_i18n:getText("rm_rl_migration_title"))
    end

    if self.messageElement ~= nil then
        self.messageElement:setText(g_i18n:getText("rm_rl_migration_message"))
    end

    if self.fileListElement ~= nil then
        local fileText = ""
        for _, file in ipairs(self.files) do
            fileText = fileText .. "- " .. file.name .. " (" .. file.type .. ")\n"
        end
        self.fileListElement:setText(fileText)
    end
end


--[[
    Continue: close and carry on loading; migration happens on the dual-read new save.

    The callback is captured into a local and the field nulled BEFORE close, because
    self:close() runs onClose, which clears the field as its own fail-safe.
]]
function RmMigrationDialog:onClickContinue()
    Log:info("Migration dialog: user clicked Continue")
    local callback = self.continueCallback
    self.continueCallback = nil
    self:close()
    if callback ~= nil then
        Log:debug("Migration dialog: firing continue callback")
        callback()
    end
end


--[[
    Quit: exit to the main menu, short-circuiting any queued startup dialogs.
]]
function RmMigrationDialog:onClickQuit()
    Log:info("Migration dialog: user clicked Quit, restarting game")
    self.continueCallback = nil
    doRestart(false, "")
end
