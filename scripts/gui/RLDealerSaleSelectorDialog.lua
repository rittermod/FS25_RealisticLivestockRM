-- RLDealerSaleSelectorDialog.lua
-- Dealer sale-availability selector (B2): a sectioned icon + age-range checkbox
-- list. One SECTION per catalog subType, one ROW per age stage (icon + age-range text +
-- checkbox, checked = currently buyable). A plain SELECTION-OUT control:
-- OK returns the checked in-scope for-sale set, Back returns nil. It never mutates the
-- registry / store, applies, or dispatches MP - the caller (B3/C1) reconciles the returned
-- set against baseline and owns the persistence side.
--
-- MERGES the RLHerdsmanHusbandryPickerDialog skeleton (MessageDialog lifecycle, in-place
-- checkbox toggle, RL_SELECT wiring, select-all, OK/Back callback, RmSafeUtils.safeCall)
-- with an engine-sectioned SmoothList (a listSectionHeader name-keyed header cell + row
-- cells), driven by the three-parallel-table delegate model (sectionOrder / itemsBySection
-- / titlesBySection).
--
-- The off-by-one-prone section/collect logic lives in the pure, dual-run
-- RLDealerSaleSelectorModel; this file is thin GUI wiring over it: buildSectionModel on
-- show, buildResult on OK, and toggleAll / toggleSection plus their predicates for the two
-- select-all controls.
--
-- TWO toggle scopes, deliberately: SPACE (MENU_ACTIVATE) is LIST-WIDE, matching every other
-- RL multi-select surface, while RL_SELECT_SECTION acts on the focused section alone. Both
-- carry a stateful label, and both labels are refreshed at EVERY mutation site rather than
-- left to the list delegate - that hook fires on focus movement only, never on a re-render.

local Log = RmLogging.getLogger("RLRM")

RLDealerSaleSelectorDialog = {}

local RLDealerSaleSelectorDialog_mt = Class(RLDealerSaleSelectorDialog, MessageDialog)
local modDirectory = g_currentModDirectory

-- =============================================================================
-- Lifecycle: register + new + show
-- =============================================================================

function RLDealerSaleSelectorDialog.register()
    local dialog = RLDealerSaleSelectorDialog.new()
    g_gui:loadGui(modDirectory .. "gui/RLDealerSaleSelectorDialog.xml",
                  "RLDealerSaleSelectorDialog", dialog)
    RLDealerSaleSelectorDialog.INSTANCE = dialog
    Log:debug("RLDealerSaleSelectorDialog.register: dialog registered")
end

function RLDealerSaleSelectorDialog.new(target, customMt)
    local self = MessageDialog.new(target, customMt or RLDealerSaleSelectorDialog_mt)

    self.model          = nil   -- { sectionOrder, itemsBySection, titlesBySection, initialSelected, keyMeta }
    self.selected       = {}    -- working copy: map composite-key -> true (nil = unchecked)
    self.callback       = nil
    self.callbackTarget = nil

    return self
end

--- Static entry point. The caller passes the B1 catalog view-model; the dialog FULLY
--- rebuilds its per-session state (section model + selection seeded from initial buyability)
--- on EVERY call, so a prior open's toggles never leak into this one.
---@param callback function fn(target, result) - result is the checked in-scope for-sale set (array of {subTypeName, minAge}, possibly {}) on OK, or nil on cancel
---@param target table|nil callback target (the caller frame); may be nil
---@param catalog table|nil B1 catalog: RLDealerSaleCatalog.enumerate() result
function RLDealerSaleSelectorDialog.show(callback, target, catalog)
    if RLDealerSaleSelectorDialog.INSTANCE == nil then
        RLDealerSaleSelectorDialog.register()
    end

    local dialog = RLDealerSaleSelectorDialog.INSTANCE
    dialog:setData(callback, target, catalog)
    g_gui:showDialog("RLDealerSaleSelectorDialog")
end

--- Full per-open rebuild: derive the section model from the catalog and seed the working
--- selection from each row's initial (effective) buyability. Never reuses prior state.
function RLDealerSaleSelectorDialog:setData(callback, target, catalog)
    self.callback       = callback
    self.callbackTarget = target
    self.model          = RLDealerSaleSelectorModel.buildSectionModel(catalog)

    self.selected = {}
    for key, checked in pairs(self.model.initialSelected) do
        if checked == true then self.selected[key] = true end
    end

    Log:debug("RLDealerSaleSelectorDialog:setData: %d section(s), %d initially-checked",
        #self.model.sectionOrder, self:_countSelected())
end

-- =============================================================================
-- Element resolution + datasource / delegate wiring
-- =============================================================================

function RLDealerSaleSelectorDialog:onGuiSetupFinished()
    RLDealerSaleSelectorDialog:superClass().onGuiSetupFinished(self)

    self.dealerSaleList      = self:getDescendantById("dealerSaleList")
    self.emptyListText       = self:getDescendantById("emptyListText")
    self.okButton            = self:getDescendantById("okButton")
    self.backButton          = self:getDescendantById("backButton")
    self.selectButton        = self:getDescendantById("selectButton")
    self.selectAllButton     = self:getDescendantById("selectAllButton")
    self.selectSectionButton = self:getDescendantById("selectSectionButton")
    self.dealerSaleSliderBox = self:getDescendantById("dealerSaleSliderBox")
    self.buttonsPC           = self:getDescendantById("buttonsPC")

    if self.dealerSaleList ~= nil then
        self.dealerSaleList:setDataSource(self)
        self.dealerSaleList:setDelegate(self)
    end

    -- Warn loudly on any missing critical element so an XML id drift is caught at load, not as
    -- silent mis-behaviour (a missing list = no rows; a missing okButton = un-disable-able OK on
    -- the empty state). BOTH select-all buttons are listed: each now carries a STATEFUL label, so
    -- an id drift on either leaves a button whose text nothing ever writes, with no other symptom.
    -- buttonsPC and backButton are deliberately absent - they feed the geometry log only, which is
    -- diagnostic and does not run at all on the empty state.
    local missing = {}
    if self.dealerSaleList == nil then table.insert(missing, "dealerSaleList") end
    if self.emptyListText == nil then table.insert(missing, "emptyListText") end
    if self.okButton == nil then table.insert(missing, "okButton") end
    if self.selectAllButton == nil then table.insert(missing, "selectAllButton") end
    if self.selectSectionButton == nil then table.insert(missing, "selectSectionButton") end
    if #missing > 0 then
        Log:warning("RLDealerSaleSelectorDialog:onGuiSetupFinished: missing elements: %s", table.concat(missing, ", "))
    end

    Log:trace("RLDealerSaleSelectorDialog:onGuiSetupFinished: elements resolved (list=%s empty=%s ok=%s section=%s)",
        tostring(self.dealerSaleList ~= nil), tostring(self.emptyListText ~= nil),
        tostring(self.okButton ~= nil), tostring(self.selectSectionButton ~= nil))
end

-- =============================================================================
-- onOpen: visibility + action events + per-open geometry log
-- =============================================================================

--- Toggle the list vs the empty-state text + the OK/Select/SelectAll/Section disabled state,
--- register the RL_SELECT and RL_SELECT_SECTION action events (only with rows to toggle -
--- keyboard routing needs an explicit registerActionEvent in this dialog context), reload,
--- seed BOTH toggle labels, then emit a PER-OPEN screen-space geometry log so the
--- sectioned-list-in-a-modal layout and the button row are provable from the log.
function RLDealerSaleSelectorDialog:onOpen()
    RLDealerSaleSelectorDialog:superClass().onOpen(self)

    local hasRows = self.model ~= nil and #self.model.sectionOrder > 0
    if self.dealerSaleList ~= nil then self.dealerSaleList:setVisible(hasRows) end
    if self.dealerSaleSliderBox ~= nil then self.dealerSaleSliderBox:setVisible(hasRows) end
    if self.emptyListText ~= nil then self.emptyListText:setVisible(not hasRows) end
    if self.okButton ~= nil then self.okButton:setDisabled(not hasRows) end
    if self.selectButton ~= nil then self.selectButton:setDisabled(not hasRows) end
    if self.selectAllButton ~= nil then self.selectAllButton:setDisabled(not hasRows) end
    -- The two select-all buttons close by DIFFERENT routes, and it matters which:
    --   * SPACE is a menu navigation action, so it reaches selectAllButton through the dialog's
    --     own button dispatch, which skips a disabled button. Disabling that button therefore
    --     closes its key as well as its click.
    --   * The section key does NOT arrive that way. A mod action is not part of a dialog's
    --     navigation set, which is why it needs the explicit registerActionEvent below - and a
    --     registered action event keeps firing regardless of the button's disabled state. What
    --     closes the section key on an empty catalog is the `hasRows` REGISTRATION gate below,
    --     not this line.
    if self.selectSectionButton ~= nil then self.selectSectionButton:setDisabled(not hasRows) end

    -- RL_SELECT (KEY_a) / RL_SELECT_SECTION (KEY_s): custom mod actions do not fire from a
    -- profile binding alone in a dialog context; register explicitly + clean up in onClose.
    -- Only with rows to toggle. Never added to Gui.NAV_ACTIONS - a permanently-registered
    -- action collides with the map frame's scroll axis.
    if hasRows and g_inputBinding ~= nil and InputAction ~= nil then
        g_inputBinding:registerActionEvent(
            InputAction.RL_SELECT, self, self.onClickSelect,
            false, true, false, true)
        Log:trace("RLDealerSaleSelectorDialog:onOpen: registered RL_SELECT action event")

        -- Guard the MEMBER, not just InputAction. A dropped or misspelled modDesc action
        -- otherwise reaches registerActionEvent(nil, ...), and the button absorbs the same fault
        -- independently: an action name that does not resolve leaves the button with no glyph
        -- and no keybind while raising nothing. Without this WARNING there is no symptom at all.
        if InputAction.RL_SELECT_SECTION ~= nil then
            g_inputBinding:registerActionEvent(
                InputAction.RL_SELECT_SECTION, self, self.onClickSelectSection,
                false, true, false, true)
            Log:trace("RLDealerSaleSelectorDialog:onOpen: registered RL_SELECT_SECTION action event")
        else
            Log:warning("RLDealerSaleSelectorDialog:onOpen: InputAction.RL_SELECT_SECTION is absent; " ..
                "the section toggle has no keybind (check the <actions> block in modDesc.xml)")
        end
    end

    if hasRows and self.dealerSaleList ~= nil then
        self.dealerSaleList:reloadData()
        -- Re-anchor focus to the first section/row on EACH open. The singleton reuses the
        -- SmoothList across opens; without this a prior open's focused section leaks in
        -- (reloadData only clamps a stale index into range, it does not reset it). This is the
        -- sanctioned reset-to-(1,1) on OPEN - distinct from the post-toggle restore the toggle
        -- paths avoid (SmoothList preserves focus across a toggle reload).
        self.dealerSaleList:setSelectedItem(1, 1)
    end

    -- Seed BOTH labels AFTER the reload + re-anchor. They cannot be left to the delegate:
    -- setSelectedItem fires onListSelectionChanged only when the index actually CHANGED, so on
    -- a repeat open that re-anchors to the same (1,1) the labels would survive from the prior
    -- open and describe a selection that no longer exists.
    self:_refreshListWideLabel()
    self:_refreshSectionLabel()

    Log:debug("RLDealerSaleSelectorDialog:onOpen: %d section(s), %d checked%s",
        self.model ~= nil and #self.model.sectionOrder or 0, self:_countSelected(),
        hasRows and "" or " (empty catalog; OK disabled)")

    -- Per-open geometry log (screen-space, 1920x1080 reference). Skipped when empty - there
    -- is no list to measure. FS25 is Y-up, so top = absPos.y + height.
    if hasRows then
        self:_logGeometry()
    end
end

--- onClose: unregister any action events registered with self as target. Without this the
--- RL_SELECT binding leaks across dialog opens.
function RLDealerSaleSelectorDialog:onClose()
    RLDealerSaleSelectorDialog:superClass().onClose(self)
    if g_inputBinding ~= nil then
        g_inputBinding:removeActionEventsByTarget(self)
        Log:trace("RLDealerSaleSelectorDialog:onClose: removed action events by target")
    end
end

--- Per-open screen-space geometry of the top-level list container + slider + OK button, so
--- the modal-context layout of the sectioned list is provable from the log (not eyeballed).
function RLDealerSaleSelectorDialog:_logGeometry()
    local function logElem(name, e)
        if e == nil then
            Log:debug("RLDealerSaleSelectorDialog._geom: %s == nil", name); return
        end
        local sw = (e.size and e.size[1] or 0) * g_referenceScreenWidth
        local sh = (e.size and e.size[2] or 0) * g_referenceScreenHeight
        local ax = (e.absPosition and e.absPosition[1] or 0) * g_referenceScreenWidth
        local ay = (e.absPosition and e.absPosition[2] or 0) * g_referenceScreenHeight
        Log:debug("RLDealerSaleSelectorDialog._geom: %s size=(%.1fx%.1f) absPos=(%.1f,%.1f) top=%.1f bottom=%.1f",
            name, sw, sh, ax, ay, ay + sh, ay)
    end
    logElem("dialogElement",       self:getDescendantById("dialogElement"))
    logElem("dealerSaleList",      self.dealerSaleList)
    logElem("dealerSaleSliderBox", self.dealerSaleSliderBox)
    logElem("okButton",            self.okButton)
    logElem("buttonsPC",           self.buttonsPC)

    -- The button row, measured rather than eyeballed. These buttons size themselves to their
    -- label text and the row re-lays itself out whenever they change, so BOTH stateful labels
    -- re-flow the whole row horizontally on every toggle. Logging each button's own extent plus
    -- the row's total span is what makes "does it still fit the dialog" answerable from the log
    -- - a single container size cannot show it.
    local names = { "selectButton", "selectAllButton", "selectSectionButton", "okButton", "backButton" }
    local minLeft, maxRight = nil, nil
    for _, name in ipairs(names) do
        local e = self[name]
        if e == nil then
            Log:debug("RLDealerSaleSelectorDialog._geom: %s == nil (not in the row)", name)
        elseif e.absPosition == nil or e.absSize == nil then
            -- Say so rather than skipping silently: an unmeasured button is excluded from the
            -- span below, which would otherwise report a narrower row than is really drawn -
            -- precisely when layout is the thing being investigated.
            Log:debug("RLDealerSaleSelectorDialog._geom: %s has no absPosition/absSize; EXCLUDED from the span", name)
        else
            local left   = e.absPosition[1] * g_referenceScreenWidth
            local width  = e.absSize[1] * g_referenceScreenWidth
            -- Y as well as X: a multi-flow row overflows VERTICALLY, and an X-only line cannot
            -- see two flows drawn on top of each other. FS25 is Y-up, so top = bottom + height.
            local bottom = e.absPosition[2] * g_referenceScreenHeight
            local height = e.absSize[2] * g_referenceScreenHeight
            Log:debug("RLDealerSaleSelectorDialog._geom: %s left=%.1f width=%.1f right=%.1f bottom=%.1f top=%.1f h=%.1f text=%q",
                name, left, width, left + width, bottom, bottom + height, height, tostring(e.text))
            if minLeft == nil or left < minLeft then minLeft = left end
            if maxRight == nil or (left + width) > maxRight then maxRight = left + width end
        end
    end
    if minLeft ~= nil then
        -- Compare against the row container's OWN measured width rather than a copy of the
        -- dialog's XML size: a hardcoded number silently describes the wrong dialog the moment
        -- anyone resizes it, and this line exists to answer the fit question honestly.
        local rowWidth = (self.buttonsPC ~= nil and self.buttonsPC.absSize ~= nil)
            and (self.buttonsPC.absSize[1] * g_referenceScreenWidth) or nil
        Log:debug("RLDealerSaleSelectorDialog._geom: buttonRow span=%.1f (left=%.1f right=%.1f) container=%s",
            maxRight - minLeft, minLeft, maxRight,
            rowWidth ~= nil and string.format("%.1f", rowWidth) or "unmeasured")
    end
end

-- =============================================================================
-- SmoothList DataSource (sectioned)
-- =============================================================================

function RLDealerSaleSelectorDialog:getNumberOfSections(list)
    if list ~= self.dealerSaleList or self.model == nil then return 0 end
    return #self.model.sectionOrder
end

function RLDealerSaleSelectorDialog:getNumberOfItemsInSection(list, section)
    if list ~= self.dealerSaleList or self.model == nil then return 0 end
    local key = self.model.sectionOrder[section]
    if key == nil then return 0 end
    local items = self.model.itemsBySection[key]
    -- Type-check, not just nil-check, so the datasource and the model's transition walk agree on
    -- what a section contains. A non-table with a length would otherwise render phantom rows here
    -- that every toggle and predicate skips.
    return type(items) == "table" and #items or 0
end

function RLDealerSaleSelectorDialog:getTitleForSectionHeader(list, section)
    if list ~= self.dealerSaleList or self.model == nil then return nil end
    local key = self.model.sectionOrder[section]
    return key and self.model.titlesBySection[key] or nil
end

--- Populate one data row: icon (hidden on nil OR empty), subType label (self-identifying
--- while scrolling), age-range text, and a checkbox reflecting the per-key selection. The
--- checkbox onClickCallback toggles in place and re-renders without reloadData (SmoothList
--- preserves focus; mirror the picker / buy-frame).
function RLDealerSaleSelectorDialog:populateCellForItemInSection(list, section, index, cell)
    if list ~= self.dealerSaleList or self.model == nil then return end
    local sectionKey = self.model.sectionOrder[section]
    if sectionKey == nil then return end
    local items = self.model.itemsBySection[sectionKey]
    if items == nil then return end
    local row = items[index]
    if row == nil then return end

    local iconCell = cell:getAttribute("icon")
    if iconCell ~= nil then
        if row.iconFilename ~= nil and row.iconFilename ~= "" then
            iconCell:setImageFilename(row.iconFilename)
            iconCell:setVisible(true)
        else
            iconCell:setVisible(false)
        end
    end

    -- Row label = the age band ("N-M months"); the subType is named by the section header, so it
    -- is not repeated per row (few rows per subType - repetition beside the header reads as clutter).
    -- Reuses the shared rl_ui_formatMonths ("%s months") key; age bands are always plural ranges.
    local ageCell = cell:getAttribute("ageRange")
    if ageCell ~= nil then
        local text = row.ageRangeLabel or ""
        if text ~= "" and g_i18n ~= nil then
            text = string.format(g_i18n:getText("rl_ui_formatMonths"), row.ageRangeLabel)
        end
        ageCell:setText(text)
    end

    local checkbox = cell:getAttribute("checkbox")
    local check    = cell:getAttribute("check")
    if checkbox ~= nil then
        checkbox:setVisible(true)
        if check ~= nil then
            local cellKey = row.key
            -- Log the DECOMPOSED (subTypeName, minAge) - never the composite key, whose U+001F
            -- separator has no glyph in the console texture font ("Character '31' not found").
            local rowSubType, rowMinAge = row.subTypeName, row.minAge
            check:setVisible(self.selected[cellKey] == true)
            checkbox.onClickCallback = function()
                self:_toggle(cellKey)
                check:setVisible(self.selected[cellKey] == true)
                -- BOTH labels, at this mutation site. The delegate does not cover it: this path
                -- deliberately does not move focus, and the list's selection-changed hook fires
                -- on focus movement only - never on a re-render.
                self:_refreshListWideLabel()
                self:_refreshSectionLabel()
                Log:debug("RLDealerSaleSelectorDialog: checkbox toggle %s @%s -> %s",
                    tostring(rowSubType), tostring(rowMinAge), tostring(self.selected[cellKey] == true))
            end
        end
    end
end

--- Delegate hook the SmoothList fires when focus MOVES - never on a re-render. Only the SECTION
--- label can change here: moving focus alters which section is scoped, but not whether anything
--- is checked list-wide.
function RLDealerSaleSelectorDialog:onListSelectionChanged(list, section, index)
    if list ~= self.dealerSaleList then return end
    self:_refreshSectionLabel()
    Log:trace("RLDealerSaleSelectorDialog:onListSelectionChanged: section=%s index=%s",
        tostring(section), tostring(index))
end

--- List row clicked: moves focus only - selection toggles via the Select action or the
--- checkbox onClickCallback (matches the picker / sell-frame UX).
function RLDealerSaleSelectorDialog:onListClick(_list, section, index, _cell)
    Log:trace("RLDealerSaleSelectorDialog:onListClick: focus section=%s index=%s",
        tostring(section), tostring(index))
end

-- =============================================================================
-- Selection helpers
-- =============================================================================

--- Flip one key's checked state, keeping the map to true / nil (never false).
function RLDealerSaleSelectorDialog:_toggle(key)
    if self.selected[key] == true then
        self.selected[key] = nil
    else
        self.selected[key] = true
    end
end

--- Total checked keys (for the open/debug log). Only `true` values count.
function RLDealerSaleSelectorDialog:_countSelected()
    local n = 0
    for _, v in pairs(self.selected) do
        if v == true then n = n + 1 end
    end
    return n
end

--- The focused section INDEX, or nil when there is no list/model yet.
---
--- Deliberately does NOT default to 1. The model treats nil, the documented 0 sentinel and a
--- stale out-of-range index alike as "no usable section", and a press in that state is a
--- no-op; defaulting would let a mis-resolved section clear the wrong subType outright.
---@return number|nil
function RLDealerSaleSelectorDialog:_focusedSectionIndex()
    if self.dealerSaleList == nil or self.model == nil then return nil end
    return self.dealerSaleList.selectedSectionIndex
end

--- Update the LIST-WIDE select-all/none label from whether anything is checked ANYWHERE.
--- Reuses the shared rl_ui_selectAll / rl_ui_selectNone keys.
function RLDealerSaleSelectorDialog:_refreshListWideLabel()
    if self.selectAllButton == nil or g_i18n == nil or self.model == nil then return end
    local anySelected = RLDealerSaleSelectorModel.hasAnySelection(
        self.selected, self.model.sectionOrder, self.model.itemsBySection)
    self.selectAllButton:setText(g_i18n:getText(anySelected and "rl_ui_selectNone" or "rl_ui_selectAll"))
end

--- Update the SECTION-scoped button label from whether the FOCUSED section holds a check.
function RLDealerSaleSelectorDialog:_refreshSectionLabel()
    if self.selectSectionButton == nil or g_i18n == nil or self.model == nil then return end
    local sectionSelected = RLDealerSaleSelectorModel.hasSectionSelection(
        self.selected, self.model.sectionOrder, self.model.itemsBySection, self:_focusedSectionIndex())
    self.selectSectionButton:setText(g_i18n:getText(sectionSelected and "rl_ui_deselectSection" or "rl_ui_selectSection"))
end

-- =============================================================================
-- Action handlers
-- =============================================================================

--- Toggle the focused row's selection. Triggered by RL_SELECT (KEY_a) or the Select button.
--- SECTION-AWARE: resolve BOTH the focused section and the row within it (a single flat
--- index is wrong once there are multiple sections). Reload to re-render the checkmark; do
--- NOT restoreSelection (SmoothList preserves focus across reloadData).
function RLDealerSaleSelectorDialog:onClickSelect()
    if self.dealerSaleList == nil or self.model == nil then
        Log:trace("RLDealerSaleSelectorDialog:onClickSelect: no list/model")
        return
    end
    local section = self.dealerSaleList.selectedSectionIndex
    local index   = self.dealerSaleList:getSelectedIndexInSection()
    -- Section resolution is SECTION-AWARE and three-armed, each arm named in its own TRACE:
    -- nil, the documented 0 sentinel, and an index with no sectionOrder entry. The last is the
    -- REACHABLE one here - buildSectionModel never emits a row-less section, so the engine's 0
    -- is documented rather than produced, while a stale out-of-range index survives a reopen.
    if section == nil then
        Log:trace("RLDealerSaleSelectorDialog:onClickSelect: no usable section (nil)")
        return
    end
    if section == 0 then
        Log:trace("RLDealerSaleSelectorDialog:onClickSelect: no usable section (0 sentinel)")
        return
    end
    local key = self.model.sectionOrder[section]
    if key == nil then
        Log:trace("RLDealerSaleSelectorDialog:onClickSelect: no usable section (index %s has no sectionOrder entry)",
            tostring(section))
        return
    end
    if index == nil or index <= 0 then
        Log:trace("RLDealerSaleSelectorDialog:onClickSelect: no focused row (index=%s)", tostring(index))
        return
    end
    local rows = self.model.itemsBySection[key]
    local row  = rows and rows[index]
    if row == nil then
        Log:trace("RLDealerSaleSelectorDialog:onClickSelect: (section=%s,index=%s) out of range",
            tostring(section), tostring(index))
        return
    end

    self:_toggle(row.key)
    self:_refreshListWideLabel()
    self:_refreshSectionLabel()
    self.dealerSaleList:reloadData()
    -- Decomposed, not the composite key (its U+001F separator is a non-glyph in the console font).
    Log:debug("RLDealerSaleSelectorDialog:onClickSelect: %s @%s -> %s",
        tostring(row.subTypeName), tostring(row.minAge), tostring(self.selected[row.key] == true))
end

--- LIST-WIDE select-all / none, on SPACE (MENU_ACTIVATE) or the button. Every row in every
--- section flips together; mixed state deselects first, matching the six sibling surfaces.
--- Focus is irrelevant here - the transition never consults a focused section.
---
--- The transition itself lives in the pure model, which owns the counts and logs them; this
--- handler iterates nothing.
function RLDealerSaleSelectorDialog:onClickSelectAll()
    -- Empty-catalog defence-in-depth, mirroring onClickOk: the button is setDisabled and the key
    -- route is gated, but do not rely solely on that to keep a toggle off an empty list.
    if self.model == nil or #self.model.sectionOrder == 0 then
        Log:trace("RLDealerSaleSelectorDialog:onClickSelectAll: no model / empty catalog; ignoring")
        return
    end

    self.selected = RLDealerSaleSelectorModel.toggleAll(
        self.selected, self.model.sectionOrder, self.model.itemsBySection)

    self:_refreshListWideLabel()
    self:_refreshSectionLabel()
    if self.dealerSaleList ~= nil then self.dealerSaleList:reloadData() end
end

--- SECTION-SCOPED select-all / none, on RL_SELECT_SECTION (KEY_s) or the section button.
--- Acts on the FOCUSED section; every other section is untouched. A press with no usable
--- focused section is a no-op. Both labels refresh - clearing a section can empty the whole
--- list, which flips the list-wide label too.
function RLDealerSaleSelectorDialog:onClickSelectSection()
    if self.model == nil or #self.model.sectionOrder == 0 then
        Log:trace("RLDealerSaleSelectorDialog:onClickSelectSection: no model / empty catalog; ignoring")
        return
    end

    self.selected = RLDealerSaleSelectorModel.toggleSection(
        self.selected, self.model.sectionOrder, self.model.itemsBySection, self:_focusedSectionIndex())

    self:_refreshListWideLabel()
    self:_refreshSectionLabel()
    if self.dealerSaleList ~= nil then self.dealerSaleList:reloadData() end
end

--- Commit: collect the checked in-scope rows and return them. NO empty-set reject - an
--- all-unchecked commit returns {} ("nothing for sale" is legitimate). The dialog is free
--- of registry / apply / MP knowledge - it returns a set, full stop.
function RLDealerSaleSelectorDialog:onClickOk()
    RmSafeUtils.safeCall("RLDealerSaleSelectorDialog:onClickOk", function()
        -- Empty-catalog defence-in-depth: OK is setDisabled on the empty state, but do not rely
        -- solely on the disabled button routing MENU_ACCEPT - ignore an OK with no sections.
        if self.model == nil or #self.model.sectionOrder == 0 then
            Log:debug("RLDealerSaleSelectorDialog:onClickOk: empty catalog; ignoring OK (no commit)")
            return
        end

        local result = RLDealerSaleSelectorModel.buildResult(
            self.selected, self.model.keyMeta, self.model.sectionOrder, self.model.itemsBySection)

        Log:debug("RLDealerSaleSelectorDialog:onClickOk: committing %d in-scope row(s) (no empty reject)", #result)

        self:close()
        if self.callback ~= nil then
            self.callback(self.callbackTarget, result)
        end
    end)
end

--- Cancel: close + return nil (the caller treats nil as "no change").
function RLDealerSaleSelectorDialog:onClickBack()
    Log:debug("RLDealerSaleSelectorDialog:onClickBack: cancel")
    self:close()
    if self.callback ~= nil then
        self.callback(self.callbackTarget, nil)
    end
end

Log:debug("RLDealerSaleSelectorDialog: loaded")
