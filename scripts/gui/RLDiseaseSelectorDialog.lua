-- RLDiseaseSelectorDialog.lua
-- Choose Diseases: a flat checkbox list, one row per defined disease. OK returns the checked
-- titles, Back returns nil. Selection-out only: it never touches the override registry or
-- dispatches MP - the caller reconciles and sends. The selection logic lives in the pure
-- RLDiseaseSelectorModel.

local Log = RmLogging.getLogger("RLRM")

RLDiseaseSelectorDialog = {}

local RLDiseaseSelectorDialog_mt = Class(RLDiseaseSelectorDialog, MessageDialog)
local modDirectory = g_currentModDirectory

-- =============================================================================
-- Lifecycle: register + new + show
-- =============================================================================

--- Load the dialog XML and keep the singleton; called from the eager registration block.
function RLDiseaseSelectorDialog.register()
    local dialog = RLDiseaseSelectorDialog.new()
    g_gui:loadGui(modDirectory .. "gui/RLDiseaseSelectorDialog.xml", "RLDiseaseSelectorDialog", dialog)
    RLDiseaseSelectorDialog.INSTANCE = dialog
    Log:debug("RLDiseaseSelectorDialog.register: dialog registered")
end

--- Field-only constructor: it runs at boot on every load, so it reads no registry or manager.
---@param target table|nil
---@param customMt table|nil
---@return table self
function RLDiseaseSelectorDialog.new(target, customMt)
    local self = MessageDialog.new(target, customMt or RLDiseaseSelectorDialog_mt)

    self.model          = nil
    self.selected       = {}
    self.callback       = nil
    self.callbackTarget = nil

    Log:trace("RLDiseaseSelectorDialog.new: fields reset")
    return self
end

--- Open the dialog over a catalog.
---@param callback function fn(target, result) - result is an array of `{ title }` on OK, nil on Back
---@param target table|nil callback target
---@param catalog table|nil `RLDiseaseOverrideCatalog.enumerate()` result
function RLDiseaseSelectorDialog.show(callback, target, catalog)
    local dialog = RLDiseaseSelectorDialog.INSTANCE
    if dialog == nil then
        Log:error("RLDiseaseSelectorDialog.show: INSTANCE is nil (eager registration failed?); cannot open")
        return
    end

    dialog:setData(callback, target, catalog)
    g_gui:showDialog("RLDiseaseSelectorDialog")
end

--- Full per-open rebuild of the model and the working selection.
---@param callback function
---@param target table|nil
---@param catalog table|nil
function RLDiseaseSelectorDialog:setData(callback, target, catalog)
    self.callback       = callback
    self.callbackTarget = target
    self.model          = RLDiseaseSelectorModel.buildModel(catalog)

    self.selected = {}
    for title, checked in pairs(self.model.initialSelected) do
        if checked == true then self.selected[title] = true end
    end

    Log:debug("RLDiseaseSelectorDialog:setData: %d row(s), %d initially checked",
        #self.model.rows, self:_countSelected())
end

-- =============================================================================
-- Element resolution + datasource / delegate wiring
-- =============================================================================

--- Resolve the elements and bind the list's datasource and delegate.
function RLDiseaseSelectorDialog:onGuiSetupFinished()
    RLDiseaseSelectorDialog:superClass().onGuiSetupFinished(self)

    self.diseaseList      = self:getDescendantById("diseaseList")
    self.diseaseSliderBox = self:getDescendantById("diseaseSliderBox")
    self.okButton         = self:getDescendantById("okButton")
    self.backButton       = self:getDescendantById("backButton")
    self.selectButton     = self:getDescendantById("selectButton")
    self.selectAllButton  = self:getDescendantById("selectAllButton")
    self.buttonsPC        = self:getDescendantById("buttonsPC")

    if self.diseaseList ~= nil then
        self.diseaseList:setDataSource(self)
        self.diseaseList:setDelegate(self)
    end

    local missing = {}
    if self.diseaseList == nil then table.insert(missing, "diseaseList") end
    if self.okButton == nil then table.insert(missing, "okButton") end
    if self.selectAllButton == nil then table.insert(missing, "selectAllButton") end
    if #missing > 0 then
        Log:warning("RLDiseaseSelectorDialog:onGuiSetupFinished: missing elements: %s", table.concat(missing, ", "))
    end
end

-- =============================================================================
-- onOpen / onClose
-- =============================================================================

--- Reload, re-anchor to row 1, seed the select-all label and register RL_SELECT when there are rows.
function RLDiseaseSelectorDialog:onOpen()
    RLDiseaseSelectorDialog:superClass().onOpen(self)

    local hasRows = self.model ~= nil and #self.model.rows > 0
    if self.okButton ~= nil then self.okButton:setDisabled(not hasRows) end
    if self.selectButton ~= nil then self.selectButton:setDisabled(not hasRows) end
    if self.selectAllButton ~= nil then self.selectAllButton:setDisabled(not hasRows) end

    -- A mod action does not fire from a profile binding inside a dialog, and a disabled button
    -- does not close its key, so registration itself is the gate.
    if hasRows and g_inputBinding ~= nil then
        if InputAction.RL_SELECT ~= nil then
            g_inputBinding:registerActionEvent(InputAction.RL_SELECT, self, self.onClickSelect,
                false, true, false, true)
            Log:trace("RLDiseaseSelectorDialog:onOpen: registered RL_SELECT action event")
        else
            Log:warning("RLDiseaseSelectorDialog:onOpen: InputAction.RL_SELECT is absent; the Select key is unbound")
        end
    end

    if hasRows and self.diseaseList ~= nil then
        -- The singleton reuses its list, and reloadData only clamps a stale index.
        self.diseaseList:reloadData()
        self.diseaseList:setSelectedItem(1, 1)
    end

    self:_refreshSelectAllLabel()

    Log:debug("RLDiseaseSelectorDialog:onOpen: %d row(s), %d checked",
        self.model ~= nil and #self.model.rows or 0, self:_countSelected())

    if hasRows then
        self:_logGeometry()
    end
end

--- Remove the action events registered with this dialog as target.
function RLDiseaseSelectorDialog:onClose()
    RLDiseaseSelectorDialog:superClass().onClose(self)
    if g_inputBinding ~= nil then
        g_inputBinding:removeActionEventsByTarget(self)
        Log:trace("RLDiseaseSelectorDialog:onClose: removed action events by target")
    end
end

--- Per-open geometry (1920x1080 reference) of both row columns and the button row.
function RLDiseaseSelectorDialog:_logGeometry()
    --- One element's size, absSize and left edge in reference pixels, or a nil line.
    ---@param name string label for the log line
    ---@param e table|nil the element
    local function logElem(name, e)
        if e == nil then
            Log:debug("RLDiseaseSelectorDialog._geom: %s == nil", name)
            return
        end
        local sw = (e.size and e.size[1] or 0) * g_referenceScreenWidth
        local sh = (e.size and e.size[2] or 0) * g_referenceScreenHeight
        local aw = (e.absSize and e.absSize[1] or 0) * g_referenceScreenWidth
        local ah = (e.absSize and e.absSize[2] or 0) * g_referenceScreenHeight
        local ax = (e.absPosition and e.absPosition[1] or 0) * g_referenceScreenWidth
        Log:debug("RLDiseaseSelectorDialog._geom: %s size=(%.1fx%.1f) absSize=(%.1fx%.1f) left=%.1f text=%q",
            name, sw, sh, aw, ah, ax, tostring(e.text))
    end

    logElem("dialogElement", self:getDescendantById("dialogElement"))
    logElem("diseaseList", self.diseaseList)
    logElem("buttonsPC", self.buttonsPC)

    local cell = self.diseaseList ~= nil and self.diseaseList.elements ~= nil and self.diseaseList.elements[1] or nil
    if cell ~= nil and cell.getAttribute ~= nil then
        logElem("row.name", cell:getAttribute("name"))
        logElem("row.types", cell:getAttribute("types"))
    else
        Log:debug("RLDiseaseSelectorDialog._geom: no rendered row cell to measure")
    end
end

-- =============================================================================
-- SmoothList DataSource (single section)
-- =============================================================================

--- One flat section.
---@param list table
---@return number
function RLDiseaseSelectorDialog:getNumberOfSections(list)
    Log:trace("RLDiseaseSelectorDialog:getNumberOfSections: 1")
    return 1
end

--- Row count of the single section.
---@param list table
---@param section number
---@return number
function RLDiseaseSelectorDialog:getNumberOfItemsInSection(list, section)
    if list ~= self.diseaseList or self.model == nil then
        Log:trace("RLDiseaseSelectorDialog:getNumberOfItemsInSection: foreign list or no model; 0")
        return 0
    end
    Log:trace("RLDiseaseSelectorDialog:getNumberOfItemsInSection: %d", #self.model.rows)
    return #self.model.rows
end

--- Populate one row: name, types label, and a checkbox that toggles in place.
---@param list table
---@param section number
---@param index number
---@param cell table
function RLDiseaseSelectorDialog:populateCellForItemInSection(list, section, index, cell)
    if list ~= self.diseaseList or self.model == nil then
        Log:trace("RLDiseaseSelectorDialog:populateCellForItemInSection: foreign list or no model; skipped")
        return
    end
    local row = self.model.rows[index]
    if row == nil then
        Log:trace("RLDiseaseSelectorDialog:populateCellForItemInSection: no row at index=%s; skipped", tostring(index))
        return
    end
    Log:trace("RLDiseaseSelectorDialog:populateCellForItemInSection: index=%s title=%s checked=%s",
        tostring(index), tostring(row.title), tostring(self.selected[row.title] == true))

    local nameCell = cell:getAttribute("name")
    if nameCell ~= nil then nameCell:setText(row.name or row.title) end

    local typesCell = cell:getAttribute("types")
    if typesCell ~= nil then typesCell:setText(row.typesLabel or "") end

    local checkbox = cell:getAttribute("checkbox")
    local check    = cell:getAttribute("check")
    if checkbox ~= nil and check ~= nil then
        local title = row.title
        check:setVisible(self.selected[title] == true)
        checkbox.onClickCallback = function()
            self:_toggle(title)
            check:setVisible(self.selected[title] == true)
            self:_refreshSelectAllLabel()
            Log:debug("RLDiseaseSelectorDialog: checkbox toggle %s -> %s", title, tostring(self.selected[title] == true))
        end
    end
end

--- Row click moves focus only; Select and the checkbox toggle.
---@param list table
---@param section number
---@param index number
function RLDiseaseSelectorDialog:onListClick(list, section, index)
    Log:trace("RLDiseaseSelectorDialog:onListClick: focus index=%s", tostring(index))
end

-- =============================================================================
-- Selection helpers
-- =============================================================================

--- Flip one title's checked state, keeping the map to true / nil.
---@param title string
function RLDiseaseSelectorDialog:_toggle(title)
    if self.selected[title] == true then
        self.selected[title] = nil
    else
        self.selected[title] = true
    end
    Log:trace("RLDiseaseSelectorDialog:_toggle: %s -> %s", tostring(title), tostring(self.selected[title] == true))
end

--- Count checked titles, for the log lines.
---@return number
function RLDiseaseSelectorDialog:_countSelected()
    local n = 0
    for _, v in pairs(self.selected) do
        if v == true then n = n + 1 end
    end
    Log:trace("RLDiseaseSelectorDialog:_countSelected: %d", n)
    return n
end

--- Label the list-wide toggle from whether anything is checked.
function RLDiseaseSelectorDialog:_refreshSelectAllLabel()
    if self.selectAllButton == nil or g_i18n == nil or self.model == nil then
        Log:trace("RLDiseaseSelectorDialog:_refreshSelectAllLabel: no button, i18n or model; skipped")
        return
    end
    local anySelected = RLDiseaseSelectorModel.hasAnySelection(self.selected, self.model)
    self.selectAllButton:setText(g_i18n:getText(anySelected and "rl_ui_selectNone" or "rl_ui_selectAll"))
end

-- =============================================================================
-- Action handlers
-- =============================================================================

--- Toggle the focused row (RL_SELECT or the Select button); reloads without re-anchoring.
function RLDiseaseSelectorDialog:onClickSelect()
    if self.diseaseList == nil or self.model == nil then
        Log:trace("RLDiseaseSelectorDialog:onClickSelect: no list/model")
        return
    end

    local index = self.diseaseList:getSelectedIndexInSection()
    local row = index ~= nil and self.model.rows[index] or nil
    if row == nil then
        Log:trace("RLDiseaseSelectorDialog:onClickSelect: no focused row (index=%s)", tostring(index))
        return
    end

    self:_toggle(row.title)
    self:_refreshSelectAllLabel()
    self.diseaseList:reloadData()
    Log:debug("RLDiseaseSelectorDialog:onClickSelect: %s -> %s", row.title, tostring(self.selected[row.title] == true))
end

--- List-wide select all / none (MENU_ACTIVATE or the button).
function RLDiseaseSelectorDialog:onClickSelectAll()
    if self.model == nil or #self.model.rows == 0 then
        Log:trace("RLDiseaseSelectorDialog:onClickSelectAll: no rows; ignoring")
        return
    end

    self.selected = RLDiseaseSelectorModel.toggleAll(self.selected, self.model)
    self:_refreshSelectAllLabel()
    if self.diseaseList ~= nil then self.diseaseList:reloadData() end
end

--- Commit: close and return the checked titles (possibly `{}`).
function RLDiseaseSelectorDialog:onClickOk()
    RmSafeUtils.safeCall("RLDiseaseSelectorDialog:onClickOk", function()
        if self.model == nil or #self.model.rows == 0 then
            Log:debug("RLDiseaseSelectorDialog:onClickOk: no rows; ignoring OK")
            return
        end

        local result = RLDiseaseSelectorModel.buildResult(self.selected, self.model)
        Log:debug("RLDiseaseSelectorDialog:onClickOk: committing %d checked title(s)", #result)

        self:close()
        if self.callback ~= nil then
            self.callback(self.callbackTarget, result)
        end
    end)
end

--- Cancel: close and return nil.
function RLDiseaseSelectorDialog:onClickBack()
    Log:debug("RLDiseaseSelectorDialog:onClickBack: cancel")
    self:close()
    if self.callback ~= nil then
        self.callback(self.callbackTarget, nil)
    end
end

Log:debug("RLDiseaseSelectorDialog: loaded")
