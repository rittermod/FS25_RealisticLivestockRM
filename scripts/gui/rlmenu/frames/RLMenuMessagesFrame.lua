--[[
    RLMenuMessagesFrame.lua
    RL Tabbed Menu Messages tab. Read-only SmoothList of messages pulled
    from RLMessageService, with Delete (Backspace) and Delete All
    (rebindable) footer buttons. Buttons are hidden when the list is
    empty or the local player lacks the `updateFarm` permission on their
    own farm; server-side validation in HusbandryMessageDeleteEvent is
    the authoritative security boundary, the frame's permission check is
    only a UX helper.
]]

RLMenuMessagesFrame = {}
local RLMenuMessagesFrame_mt = Class(RLMenuMessagesFrame, TabbedMenuFrameElement)

local Log = RmLogging.getLogger("RLRM")

-- Store mod directory at source time (g_currentModDirectory only valid during source())
local modDirectory = g_currentModDirectory

--- Construct a new RLMenuMessagesFrame instance.
--- Called once by setupGui() during mod load.
--- @return table self The new frame instance
function RLMenuMessagesFrame.new()
    local self = RLMenuMessagesFrame:superClass().new(nil, RLMenuMessagesFrame_mt)
    self.name = "RLMenuMessagesFrame"
    self.rows = {}
    self.farmId = nil
    self.isFrameOpen = false

    -- hasCustomMenuButtons makes the first page switch use self.menuButtonInfo, or the
    -- Delete buttons appear a frame late and flicker.
    self.hasCustomMenuButtons = true

    self.backButtonInfo = {
        inputAction = InputAction.MENU_BACK,
    }
    self.deleteButtonInfo = {
        inputAction = InputAction.MENU_CANCEL,
        text = g_i18n:getText("rl_menu_messages_delete_button"),
        callback = function() self:onClickDelete() end,
    }
    self.deleteAllButtonInfo = {
        inputAction = InputAction.MENU_EXTRA_1,
        text = g_i18n:getText("rl_menu_messages_delete_all_button"),
        callback = function() self:onClickDeleteAll() end,
    }
    self.menuButtonInfo = { self.backButtonInfo }

    Log:trace("RLMenuMessagesFrame.new: instance created")
    return self
end

--- Load the messages frame XML and register the frame with g_gui.
--- Called from RLMenu.setupGui() before the menu XML is loaded so that
--- rlMenu.xml's FrameReference ref="RLMenuMessagesFrame" resolves.
function RLMenuMessagesFrame.setupGui()
    local frame = RLMenuMessagesFrame.new()
    g_gui:loadGui(
        Utils.getFilename("gui/rlmenu/messagesFrame.xml", modDirectory),
        "RLMenuMessagesFrame",
        frame,
        true  -- frame-only load
    )
    Log:debug("RLMenuMessagesFrame.setupGui: registered")
end

--- Bind the SmoothList data source/delegate after XML parsing completes.
--- Called by the GUI manager once all element references are wired.
function RLMenuMessagesFrame:onGuiSetupFinished()
    RLMenuMessagesFrame:superClass().onGuiSetupFinished(self)

    if self.messagesList ~= nil then
        self.messagesList:setDataSource(self)
        self.messagesList:setDelegate(self)
        Log:trace("RLMenuMessagesFrame:onGuiSetupFinished: SmoothList bound")
    else
        Log:warning("RLMenuMessagesFrame:onGuiSetupFinished: messagesList element missing from XML")
    end
end

--- Called by the Paging element when this tab becomes active. Refreshes on every open,
--- then clears the unread flag FARM-WIDE, because this tab is a unioned farm view -
--- without it the per-husbandry unread notification re-fires on every day change.
function RLMenuMessagesFrame:onFrameOpen()
    RLMenuMessagesFrame:superClass().onFrameOpen(self)
    self.isFrameOpen = true
    Log:debug("RLMenuMessagesFrame:onFrameOpen")
    self:refreshData()

    -- Acknowledge unread state for every pen on the local farm. Iterating
    -- all placeables (not just rows that contributed to the list) is
    -- intentional - saves carrying the pre-fix stale flag (flag=true,
    -- spec.messages empty) auto-heal on first open.
    Log:trace("RLMenuMessagesFrame:onFrameOpen: clearing unread flags for farmId=%s",
        tostring(self.farmId))
    RLMessageService.markAllReadForFarm(self.farmId)

    -- Explicit focus required for multi-tab TabbedMenu navigation (Fresh
    -- mod pattern). Without this, FocusManager auto-layout can resolve
    -- arrow keys to elements in other tabs' frames.
    if self.messagesList ~= nil then
        FocusManager:setFocus(self.messagesList)
    end
end

--- Called by the Paging element when this tab is deactivated.
--- Clears the isFrameOpen flag so the event's refreshIfOpen hook is a no-op
--- until the tab is opened again.
function RLMenuMessagesFrame:onFrameClose()
    RLMenuMessagesFrame:superClass().onFrameClose(self)
    self.isFrameOpen = false
    Log:trace("RLMenuMessagesFrame:onFrameClose")
end

--- Pull fresh rows from the service for the local player's farm and
--- reload the SmoothList. Updates the empty-state, summary, selection clamp,
--- and footer buttons.
function RLMenuMessagesFrame:refreshData()
    local farmId
    if g_currentMission ~= nil and g_currentMission.getFarmId ~= nil then
        farmId = g_currentMission:getFarmId()
    end
    self.farmId = farmId

    self.rows = RLMessageService.getMessagesForFarm(farmId)
    Log:debug("RLMenuMessagesFrame:refreshData: farmId=%s rows=%d",
        tostring(farmId), #self.rows)

    if self.messagesList ~= nil then
        self.messagesList:reloadData()
    end

    self:clampSelection()
    self:updateEmptyState()
    self:updateSummaryText()
    self:updateButtonVisibility()
end

--- Refresh only if the frame is currently open. Called by
--- HusbandryMessageDeleteEvent:run on delete receivers so the UI reflects
--- mutations applied by the network event without polling.
function RLMenuMessagesFrame:refreshIfOpen()
    if self.isFrameOpen then
        Log:trace("RLMenuMessagesFrame:refreshIfOpen: refreshing")
        self:refreshData()
    else
        Log:trace("RLMenuMessagesFrame:refreshIfOpen: frame closed, skipping")
    end
end

--- Clamp the SmoothList selection to a valid row after reloadData. When
--- rows are deleted the previously-focused index may now point past the
--- end of the list; SmoothList does not auto-clamp so we do it here.
function RLMenuMessagesFrame:clampSelection()
    if self.messagesList == nil then return end
    local rowCount = #self.rows
    if rowCount == 0 then return end
    local selected = self.messagesList.selectedIndex
    if selected == nil then return end
    if selected > rowCount then
        self.messagesList:setSelectedIndex(rowCount)
    elseif selected < 1 then
        self.messagesList:setSelectedIndex(1)
    end
end

--- Toggle the empty-state text and surrounding chrome based on row count.
--- Branches the empty-state copy on whether the player has a farm at all.
function RLMenuMessagesFrame:updateEmptyState()
    local hasRows = #self.rows > 0
    local hasFarm = (self.farmId ~= nil and self.farmId ~= 0)
    Log:trace("RLMenuMessagesFrame:updateEmptyState: hasRows=%s hasFarm=%s",
        tostring(hasRows), tostring(hasFarm))

    if self.emptyState ~= nil then
        if not hasFarm then
            self.emptyState:setText(g_i18n:getText("rl_menu_messages_no_farm"))
        else
            self.emptyState:setText(g_i18n:getText("rl_menu_messages_empty"))
        end
        self.emptyState:setVisible(not hasRows)
    end

    if self.messagesList ~= nil then
        self.messagesList:setVisible(hasRows)
    end
    if self.tableHeader ~= nil then
        self.tableHeader:setVisible(hasRows)
    end
    if self.summaryRow ~= nil then
        self.summaryRow:setVisible(hasRows)
    end
end

--- Update the summary text under the table with the total row count.
function RLMenuMessagesFrame:updateSummaryText()
    Log:trace("RLMenuMessagesFrame:updateSummaryText: rows=%d", #self.rows)
    if self.summaryText == nil then return end
    self.summaryText:setText(string.format(
        g_i18n:getText("rl_menu_messages_summary"), tostring(#self.rows)))
end

--- UX-side delete permission gate; the server revalidates every event.
--- @return boolean
function RLMenuMessagesFrame:hasDeletePermission()
    if g_currentMission == nil or g_currentMission.getHasPlayerPermission == nil then
        return false
    end
    return g_currentMission:getHasPlayerPermission("updateFarm") == true
end

--- Build the footer button info array based on current state and mark it
--- dirty so the button bar is re-rendered.
--- Back is always present. Delete + Delete All are added only when there are
--- rows AND the local player has updateFarm permission.
function RLMenuMessagesFrame:updateButtonVisibility()
    local hasRows = #self.rows > 0
    local hasPerm = self:hasDeletePermission()
    Log:trace("RLMenuMessagesFrame:updateButtonVisibility: hasRows=%s hasPerm=%s",
        tostring(hasRows), tostring(hasPerm))

    self.menuButtonInfo = { self.backButtonInfo }
    if hasRows and hasPerm then
        table.insert(self.menuButtonInfo, self.deleteButtonInfo)
        table.insert(self.menuButtonInfo, self.deleteAllButtonInfo)
    end
    self:setMenuButtonInfoDirty()
end

-- =============================================================================
-- Delete handlers
-- =============================================================================

--- Delete the focused row, with no confirmation - messages are low-stakes and bulk
--- delete covers the destructive path. The index is resolved to (husbandryRef, uniqueId)
--- BEFORE any dispatch: those are stable across the wire, and a row index never leaves
--- this function.
function RLMenuMessagesFrame:onClickDelete()
    if self.messagesList == nil then
        Log:trace("RLMenuMessagesFrame:onClickDelete: no messagesList, aborting")
        return
    end

    if not self:hasDeletePermission() then
        Log:trace("RLMenuMessagesFrame:onClickDelete: no updateFarm permission, aborting")
        return
    end

    local index = self.messagesList.selectedIndex
    if index == nil or index < 1 or index > #self.rows then
        Log:trace("RLMenuMessagesFrame:onClickDelete: no focused row, aborting")
        return
    end

    local row = self.rows[index]
    if row == nil or row.husbandryRef == nil or row.uniqueId == nil then
        Log:warning("RLMenuMessagesFrame:onClickDelete: row missing delete metadata at index %d", index)
        return
    end

    Log:debug("RLMenuMessagesFrame:onClickDelete: deleting uniqueId=%s from husbandry='%s'",
        tostring(row.uniqueId), tostring(row.husbandryRef:getName()))

    RLMessageService.deleteMessages(row.husbandryRef, { row.uniqueId })
    self:refreshData()
end

--- Delete every displayed row, grouped so one event fires per husbandry. The snapshot is
--- captured at CLICK time and carried through the confirmation, so the deletion set
--- still matches the count the dialog showed if a peer's delete lands in between; a
--- stale uniqueId is idempotent server-side.
function RLMenuMessagesFrame:onClickDeleteAll()
    if #self.rows == 0 then
        Log:trace("RLMenuMessagesFrame:onClickDeleteAll: no rows, aborting")
        return
    end

    if not self:hasDeletePermission() then
        Log:trace("RLMenuMessagesFrame:onClickDeleteAll: no updateFarm permission, aborting")
        return
    end

    if g_gui:getIsDialogVisible() then
        Log:trace("RLMenuMessagesFrame:onClickDeleteAll: dialog already open, ignoring re-entry")
        return
    end

    -- Snapshot at click time: group rows now (by data-level husbandryRef +
    -- uniqueId) so the deletion set is frozen even if self.rows changes
    -- while the confirm dialog is open.
    local snapshotGroups = RLMessageService.groupRowsByHusbandry(self.rows)
    local snapshotCount = #self.rows

    Log:debug("RLMenuMessagesFrame:onClickDeleteAll: opening confirmation for %d row(s) across %d husbandry group(s)",
        snapshotCount, #snapshotGroups)

    local text = string.format(
        g_i18n:getText("rl_menu_messages_confirm_delete_all"), tostring(snapshotCount))

    -- Passing self as the target means onDeleteAllConfirmed is invoked as a
    -- method and receives (self, confirmed, groups).
    YesNoDialog.show(
        self.onDeleteAllConfirmed,  -- callback
        self,                        -- target (becomes `self` in callback)
        text,                        -- text
        nil, nil, nil, nil, nil, nil,
        snapshotGroups               -- callbackArgs (becomes `groups` in callback)
    )
end

--- Confirmation callback for Delete All. Yields when the user clicked No.
--- @param confirmed boolean True when the user clicked Yes
--- @param groups table Snapshot of `{ husbandry, uniqueIds[] }` groups captured at click time
function RLMenuMessagesFrame:onDeleteAllConfirmed(confirmed, groups)
    if not confirmed then
        Log:trace("RLMenuMessagesFrame:onDeleteAllConfirmed: user cancelled")
        return
    end

    Log:debug("RLMenuMessagesFrame:onDeleteAllConfirmed: firing %d group(s) from click-time snapshot", #groups)

    for i = 1, #groups do
        RLMessageService.deleteMessages(groups[i].husbandry, groups[i].uniqueIds)
    end

    self:refreshData()
end

-- =============================================================================
-- SmoothList data source / delegate protocol
--
-- Deliberately NOT logged: SmoothList calls these at draw frequency and tracing them
-- would swamp the log.
-- =============================================================================

--- Return how many items the SmoothList should render in the given section.
--- @param list table The SmoothList instance asking
--- @param _section number Section index (single-section list, ignored)
--- @return number
function RLMenuMessagesFrame:getNumberOfItemsInSection(list, _section)
    if list == self.messagesList then
        return #self.rows
    end
    return 0
end

--- Populate one cell from a row table.
--- @param list table The SmoothList instance asking
--- @param _section number Section index (ignored)
--- @param index number 1-based row index
--- @param cell table The ListItem cell to populate
function RLMenuMessagesFrame:populateCellForItemInSection(list, _section, index, cell)
    if list ~= self.messagesList then return end

    local row = self.rows[index]
    if row == nil then return end

    local importance = cell:getAttribute("importance")
    if importance ~= nil then
        importance:setImageSlice(nil, row.importanceSlice)
    end

    local typeCell = cell:getAttribute("type")
    if typeCell ~= nil then typeCell:setText(row.typeText) end

    local animalCell = cell:getAttribute("animal")
    if animalCell ~= nil then animalCell:setText(row.animalText) end

    local textCell = cell:getAttribute("text")
    if textCell ~= nil then textCell:setText(row.messageText) end

    local husbandryCell = cell:getAttribute("husbandry")
    if husbandryCell ~= nil then husbandryCell:setText(row.husbandryName) end

    local dateCell = cell:getAttribute("date")
    if dateCell ~= nil then dateCell:setText(row.date) end
end
