--[[
    RLMenuSettingsFrame.lua
    RL Tabbed Menu Settings tab: a horizontal subcategory tab bar with two content panes.
      [General] - placeholder for future non-filter settings.
      [Filters] - single-section SmoothList of saved filters backed by
                  g_rlFilterService:listAvailable, a footer New filter button, and a
                  branched empty-state.

    Tab highlight, pager texts and focus are seeded in initializeSubCategoryPages(), called
    from onFrameOpen on every open, so closures stay bound to the live frame instance.
    Selection is id-authoritative: self.selectedFilterId is the source of truth and the
    list's selectedIndex is derived from it on every reload, keeping the cached id consistent
    with the highlighted row under the service's undefined pairs-order reloads.
]]

RLMenuSettingsFrame = {}
local RLMenuSettingsFrame_mt = Class(RLMenuSettingsFrame, TabbedMenuFrameElement)

local Log = RmLogging.getLogger("RLRM")

-- Store mod directory at source time (g_currentModDirectory only valid during source())
local modDirectory = g_currentModDirectory

--- Subcategory enum. Indices match XML subCategoryTabs[] and subCategoryPages[].
RLMenuSettingsFrame.SUB_CATEGORY = {
    GENERAL = 1,
    FILTERS = 2,
}

--- Marks an explicit "clear to Any" in pendingChanges; nil cannot express it,
--- since Lua drops nil values. Flush restores nil before storage sees it.
RLMenuSettingsFrame.ANIMAL_TYPE_ANY = {}

--- Construct a new RLMenuSettingsFrame instance.
--- @return table self The new frame instance
function RLMenuSettingsFrame.new()
    local self = RLMenuSettingsFrame:superClass().new(nil, RLMenuSettingsFrame_mt)
    self.name = "RLMenuSettingsFrame"

    -- Filter list state. Rows are cloned snapshots from the service; selection
    -- is id-authoritative, with list.selectedIndex derived on every reload.
    self.rows              = {}
    self.farmId            = nil
    self.isFrameOpen       = false
    self.selectedFilterId  = nil

    -- True while refreshData reconciles selection: SmoothList:reloadData fires
    -- onListSelectionChanged synchronously during its clamp, which would
    -- overwrite selectedFilterId with the post-clamp row before we resolve it.
    self.isReconciling     = false

    -- One-shot flag for the first-visibility measure log on [Filters]. Reset
    -- per frame-open cycle by living on the instance (frames are cloned per
    -- paging lifecycle; see RLMenu:setupMenuPages).
    self.didMeasureFiltersPane = false

    -- Capped at 2 in populateCellForItemInSection: enough to compute inter-row
    -- pitch + per-cell geometry from the measurement log. Reset in onFrameOpen.
    self.didMeasureFilterCellCount = 0

    -- Editor pane measure log flag. Once per process, not per open: new() runs
    -- once at setupGui() time and the clone is reused across every menu open.
    self.didMeasureEditorPane = false

    -- Conditions list one-shot measure flag. Fires from renderEditor once the
    -- SmoothList is visible and its size axes have settled.
    self.didMeasureConditionsList = false

    -- Conditions editor working state, filled in by renderEditor. supportedRows
    -- are the editable number/bool rows; preservedChildren are nodes the editor
    -- cannot render, round-tripped verbatim so a save never destroys them.
    self.conditionEditState = {
        supportedRows         = {},
        preservedChildren     = {},
        lastRenderedFilterId  = nil,
    }

    -- Per-field cached options for the row pickers. Lazy on first access in
    -- populateCellForItemInSection. Reset on renderEditor so a remote
    -- catalog change is reflected on the next render.
    self.conditionFieldOptionsCache = nil

    -- Pending-changes overlay keyed by filter id: widget callbacks write here
    -- and flushPendingChanges drains it on close, so service:update is not
    -- called per keystroke. An absent key means "no change".
    self.pendingChanges = {}

    -- AnimalType selector cache, repopulated on every renderEditor call. Index
    -- 1 is always the "Any" row, with typeIndex=nil.
    self.animalTypeStates = {}

    -- Custom footer buttons: Back always, the rest appended conditionally by
    -- updateButtonVisibility. hasCustomMenuButtons makes the first page switch
    -- use self.menuButtonInfo, avoiding a one-frame flicker.
    self.hasCustomMenuButtons = true

    self.backButtonInfo = {
        inputAction = InputAction.MENU_BACK,
    }
    -- [New filter]: visibility gated by updateButtonVisibility on the
    -- tradeAnimals permission and farmId presence.
    self.newFilterButtonInfo = {
        inputAction = InputAction.MENU_EXTRA_1,
        text = g_i18n:getText("rl_menu_filters_new_button"),
        callback = function() self:onClickNewFilter() end,
    }
    -- [Duplicate] clones the selected filter, overlay-merged so in-flight edits
    -- are duplicated too.
    self.duplicateButtonInfo = {
        inputAction = InputAction.MENU_EXTRA_2,
        text = g_i18n:getText("rl_menu_filters_duplicate_button"),
        callback = function() self:onClickDuplicate() end,
    }
    -- [Delete] prompts YesNoDialog then dispatches service:delete on Yes.
    -- MENU_CANCEL keeps the destructive action on the cancel slot.
    self.deleteButtonInfo = {
        inputAction = InputAction.MENU_CANCEL,
        text = g_i18n:getText("rl_menu_filters_delete_button"),
        callback = function() self:onClickDelete() end,
    }
    -- Three-tier action bar. Slot collisions across tiers are intentional -
    -- only one tier is active at a time, and updateButtonVisibility rebuilds
    -- menuButtonInfo from the tier resolveActionBarTier returns.
    self.addConditionButtonInfo = {
        inputAction = InputAction.MENU_EXTRA_1,
        text = g_i18n:getText("rl_menu_filters_add_condition"),
        callback = function() self:onAddConditionClicked() end,
    }
    -- Edit condition: Tier 3 only, on the MENU_ACCEPT slot.
    self.editConditionButtonInfo = {
        inputAction = InputAction.MENU_ACCEPT,
        text = g_i18n:getText("rl_menu_filters_edit_condition"),
        callback = function() self:onEditConditionClicked() end,
    }
    -- Delete condition: Tier 3 only, on the MENU_CANCEL slot.
    self.deleteConditionButtonInfo = {
        inputAction = InputAction.MENU_CANCEL,
        text = g_i18n:getText("rl_menu_filters_delete_condition"),
        callback = function() self:onDeleteConditionClicked() end,
    }
    -- Add group: Tier 3 only, on MENU_EXTRA_2. Stub - the callback logs and
    -- no-ops; sibling-group insertion is not implemented.
    self.addGroupButtonInfo = {
        inputAction = InputAction.MENU_EXTRA_2,
        text = g_i18n:getText("rl_menu_filters_add_group_button"),
        callback = function() self:onAddGroupClicked() end,
    }
    self.menuButtonInfo = { self.backButtonInfo }

    -- General subtab control registry keyed by RLSettings.SETTINGS name, with
    -- tooltip child Text refs in self.tooltips. The page deliberately leaves
    -- RLSettings.SETTINGS[*].element nil; each page owns its own widget refs.
    self.controls          = {}
    self.tooltips          = {}
    self.didMeasureGeneralPane = false

    Log:trace("RLMenuSettingsFrame.new: instance created")
    return self
end

--- Load the settings frame XML and register the frame with g_gui. Must run
--- before the menu XML loads, so its FrameReference resolves.
function RLMenuSettingsFrame.setupGui()
    local frame = RLMenuSettingsFrame.new()
    g_gui:loadGui(
        Utils.getFilename("gui/rlmenu/settingsFrame.xml", modDirectory),
        "RLMenuSettingsFrame",
        frame,
        true  -- frame-only load
    )
    Log:debug("RLMenuSettingsFrame.setupGui: registered")
end

--- Called by the GUI manager once element references are wired. Must not mutate
--- the tree: it fires on both the original and the clone.
function RLMenuSettingsFrame:onGuiSetupFinished()
    RLMenuSettingsFrame:superClass().onGuiSetupFinished(self)
    Log:trace("RLMenuSettingsFrame:onGuiSetupFinished")

    if self.filtersList ~= nil then
        self.filtersList:setDataSource(self)
        self.filtersList:setDelegate(self)
        Log:trace("RLMenuSettingsFrame:onGuiSetupFinished: filtersList bound")
    else
        Log:warning("RLMenuSettingsFrame:onGuiSetupFinished: filtersList missing from XML")
    end

    -- Cache editor widget refs once so the render and flush paths hit direct
    -- fields. A missing ref logs a warning and skips that widget downstream.
    self.filterEditorContainer  = self:getDescendantById("filterEditorContainer")
    self.filterEditorEmpty      = self:getDescendantById("filterEditorEmpty")
    self.filterEditorLayout     = self:getDescendantById("filterEditorLayout")
    -- No filterEditorSliderBox cache: the metadata layout has 4 fixed rows
    -- and never scrolls, so no docked slider exists for the editor pane.
    self.filterNameInput        = self:getDescendantById("filterNameInput")
    self.filterAnimalTypeSelector = self:getDescendantById("filterAnimalTypeSelector")
    self.filterOpSelector       = self:getDescendantById("filterOpSelector")
    self.filterUsageSelector    = self:getDescendantById("filterUsageSelector")

    -- Conditions editor widget cache, nil-guarded per widget downstream so a
    -- partial load degrades rather than crashes.
    self.filterConditionsBanner       = self:getDescendantById("filterConditionsBanner")
    self.filterConditionsListContainer = self:getDescendantById("filterConditionsListContainer")
    self.filterConditionsList         = self:getDescendantById("filterConditionsList")
    self.filterConditionsSliderBox    = self:getDescendantById("filterConditionsSliderBox")
    -- No filterAddConditionButton cache: [+ condition] lives on the action
    -- bar (addConditionButtonInfo in the constructor + updateButtonVisibility),
    -- not as an in-pane footer button.

    local missing = {}
    if self.filterEditorContainer  == nil then table.insert(missing, "filterEditorContainer")  end
    if self.filterEditorEmpty      == nil then table.insert(missing, "filterEditorEmpty")      end
    if self.filterEditorLayout     == nil then table.insert(missing, "filterEditorLayout")     end
    if self.filterNameInput        == nil then table.insert(missing, "filterNameInput")        end
    if self.filterAnimalTypeSelector == nil then table.insert(missing, "filterAnimalTypeSelector") end
    if self.filterOpSelector       == nil then table.insert(missing, "filterOpSelector")       end
    if self.filterUsageSelector    == nil then table.insert(missing, "filterUsageSelector")    end
    if self.filterConditionsBanner        == nil then table.insert(missing, "filterConditionsBanner")        end
    if self.filterConditionsListContainer == nil then table.insert(missing, "filterConditionsListContainer") end
    if self.filterConditionsList          == nil then table.insert(missing, "filterConditionsList")          end
    if self.filterConditionsSliderBox     == nil then table.insert(missing, "filterConditionsSliderBox")     end
    if #missing > 0 then
        Log:warning("RLMenuSettingsFrame:onGuiSetupFinished: editor widget(s) missing: %s",
            table.concat(missing, ", "))
    else
        Log:trace("RLMenuSettingsFrame:onGuiSetupFinished: editor widgets cached (13/13)")
    end

    -- Bind the conditions SmoothList as data source and delegate. The shared
    -- delegate dispatches by list reference, so one self hosts both lists.
    if self.filterConditionsList ~= nil then
        self.filterConditionsList:setDataSource(self)
        self.filterConditionsList:setDelegate(self)
        Log:trace("RLMenuSettingsFrame:onGuiSetupFinished: filterConditionsList bound")
    end

    -- Seed the match-logic selector texts once; they are static. The visible
    -- text is "Match ALL"/"Match ANY" while the stored op stays "AND"/"OR".
    if self.filterOpSelector ~= nil then
        self.filterOpSelector:setTexts({
            g_i18n:getText("rl_menu_filters_op_and"),
            g_i18n:getText("rl_menu_filters_op_or"),
        })
        Log:trace("RLMenuSettingsFrame:onGuiSetupFinished: filterOpSelector texts set (Match ALL / Match ANY)")
    end

    -- Action-bar focus triggers, so the bar cannot go stale when focus moves
    -- between sections. A ScrollingLayoutElement re-replaces a child's
    -- onFocusEnter on every layout update, so hook scrollingFocusEnter_orig
    -- where it exists - a wrap on onFocusEnter is clobbered.
    local function makeFocusTrigger(frame)
        return function(_elem)
            frame:updateButtonVisibility()
        end
    end
    local trigger = makeFocusTrigger(self)
    local anchors = {
        { name = "filtersList",              elem = self.filtersList },
        { name = "filterConditionsList",     elem = self.filterConditionsList },
        { name = "filterNameInput",          elem = self.filterNameInput },
        { name = "filterAnimalTypeSelector", elem = self.filterAnimalTypeSelector },
        { name = "filterOpSelector",         elem = self.filterOpSelector },
        { name = "filterUsageSelector",      elem = self.filterUsageSelector },
        -- Refresh-only: focus here means the editor was escaped, so
        -- resolveActionBarTier returns nil and the Tier 1 fallback engages.
        { name = "subCategoryPaging",        elem = self.subCategoryPaging },
    }
    local wired = {}
    for _, a in ipairs(anchors) do
        if a.elem ~= nil then
            if a.elem.scrollingFocusEnter_orig ~= nil then
                a.elem.scrollingFocusEnter_orig = Utils.appendedFunction(
                    a.elem.scrollingFocusEnter_orig, trigger)
                table.insert(wired, a.name .. "(SL)")
            else
                a.elem.onFocusEnter = Utils.appendedFunction(a.elem.onFocusEnter, trigger)
                table.insert(wired, a.name)
            end
        end
    end
    Log:trace("RLMenuSettingsFrame:onGuiSetupFinished: tier focus triggers wired on [%s]",
        table.concat(wired, ","))
end

--- Per-clone setup: populates the General subtab. Tree mutation is forbidden
--- in onGuiSetupFinished, so it happens here.
function RLMenuSettingsFrame:initialize()
    Log:debug("RLMenuSettingsFrame:initialize")
    self:populateGeneralSubtab()
end

--- Called by the Paging element when this tab becomes active. Rebinding every
--- open keeps closures captured against the live frame instance.
function RLMenuSettingsFrame:onFrameOpen()
    RLMenuSettingsFrame:superClass().onFrameOpen(self)
    self.isFrameOpen = true
    Log:debug("RLMenuSettingsFrame:onFrameOpen")

    self:initializeSubCategoryPages()

    -- Default to [General] on every open - deliberate, no persistence. Reset
    -- the measure flags so their logs fire once per frame-open cycle.
    self.subCategoryPaging:setState(RLMenuSettingsFrame.SUB_CATEGORY.GENERAL, true)
    self.didMeasureFiltersPane = false
    self.didMeasureGeneralPane = false
    self.didMeasureFilterCellCount = 0

    -- Re-read RLSettings on every open: an MP broadcast can change state
    -- between opens.
    self:refreshGeneralSubtab()

    -- One-shot first-visibility measure log for the General layout. The size
    -- nil-guards cover a stretched layout whose axes are not committed until
    -- the next layout pass.
    local genLayout = self:getDescendantById("generalSettingsLayout")
    if genLayout ~= nil and genLayout.size ~= nil
       and genLayout.size[1] ~= nil and genLayout.size[2] ~= nil
       and not self.didMeasureGeneralPane then
        Log:debug("RLMenuSettingsFrame: generalSettingsLayout measured: %.2fpx x %.2fpx",
            genLayout.size[1] * 1920, genLayout.size[2] * 1080)

        -- Log the page container, the slider box and the layout so the
        -- right-edge gap is measured rather than guessed.
        local function _logBox(name, e)
            if e == nil then Log:debug("RLMenuSettingsFrame._geom: %s == nil", name); return end
            local ax = (e.absPosition and e.absPosition[1] or 0) * g_referenceScreenWidth
            local ay = (e.absPosition and e.absPosition[2] or 0) * g_referenceScreenHeight
            local sw = (e.size and e.size[1] or 0) * g_referenceScreenWidth
            local sh = (e.size and e.size[2] or 0) * g_referenceScreenHeight
            Log:debug("RLMenuSettingsFrame._geom: %s absPos=(%.1f,%.1f) size=(%.1fx%.1f) right=%.1f bottom=%.1f",
                name, ax, ay, sw, sh, ax + sw, ay)
        end
        local pageContainer = self:getDescendantById("subCategoryPages[1]")
        local sliderBox     = self:getDescendantById("generalSettingsSliderBox")
        _logBox("subCategoryPages[1]",     pageContainer)
        _logBox("generalSettingsLayout",   genLayout)
        _logBox("generalSettingsSliderBox", sliderBox)
        if pageContainer ~= nil and sliderBox ~= nil
           and pageContainer.absPosition and sliderBox.absPosition
           and pageContainer.size and sliderBox.size then
            local parentRight  = (pageContainer.absPosition[1] + pageContainer.size[1]) * g_referenceScreenWidth
            local sliderRight  = (sliderBox.absPosition[1] + sliderBox.size[1]) * g_referenceScreenWidth
            Log:debug("RLMenuSettingsFrame._geom: scrollbar gap = parentRight(%.1f) - sliderRight(%.1f) = %.1f px",
                parentRight, sliderRight, parentRight - sliderRight)
        end

        self.didMeasureGeneralPane = true
    end

    -- Tint the rows so the cream title text reads; without it they fall back
    -- to a white tint and the titles are invisible. Runs after
    -- refreshGeneralSubtab so the disabled cascade has settled.
    self:updateAlternatingElements(genLayout)

    -- Consume any pending-select id BEFORE refreshData, so resolveSelectionById
    -- picks the new row in the same pass. Function-scope local so the trailing
    -- setState can branch on it.
    local didPendingSelect = false
    if g_rlMenu ~= nil and g_rlMenu.pendingSelectedFilterId ~= nil then
        self.selectedFilterId = g_rlMenu.pendingSelectedFilterId
        g_rlMenu.pendingSelectedFilterId = nil
        didPendingSelect = true
        Log:debug("RLMenuSettingsFrame:onFrameOpen: pending-select filterId=%s",
            tostring(self.selectedFilterId))
    end

    -- Pull filter rows for whichever subtab ends up active; rows are cached
    -- for the switch to [Filters].
    self:refreshData()

    -- Explicit focus edges between the tab bar and the filters list; without
    -- them FocusManager auto-layout can resolve arrow keys into other frames.
    if self.subCategoryPaging ~= nil and self.filtersList ~= nil then
        FocusManager:linkElements(self.subCategoryPaging, FocusManager.BOTTOM, self.filtersList)
        FocusManager:linkElements(self.filtersList, FocusManager.TOP, self.subCategoryPaging)
    end

    -- Editor focus chain: RIGHT/LEFT crosses the list-editor boundary, DOWN/UP
    -- chains within the editor and falls through from list-bottom into Name.
    -- Each link is nil-guarded so a missing widget degrades to a partial chain.
    if self.filtersList ~= nil and self.filterNameInput ~= nil then
        FocusManager:linkElements(self.filtersList,    FocusManager.RIGHT,  self.filterNameInput)
        FocusManager:linkElements(self.filterNameInput, FocusManager.LEFT,  self.filtersList)
        FocusManager:linkElements(self.filtersList,    FocusManager.BOTTOM, self.filterNameInput)
        FocusManager:linkElements(self.filterNameInput, FocusManager.TOP,   self.filtersList)
    end
    if self.filterNameInput ~= nil and self.filterAnimalTypeSelector ~= nil then
        FocusManager:linkElements(self.filterNameInput,         FocusManager.BOTTOM, self.filterAnimalTypeSelector)
        FocusManager:linkElements(self.filterAnimalTypeSelector, FocusManager.TOP,   self.filterNameInput)
    end
    -- Focus links must mirror the visual row order Name -> AnimalType -> Usage
    -- -> Op -> ConditionsList, or keyboard nav teleports over a row.
    if self.filterAnimalTypeSelector ~= nil and self.filterUsageSelector ~= nil then
        FocusManager:linkElements(self.filterAnimalTypeSelector, FocusManager.BOTTOM, self.filterUsageSelector)
        FocusManager:linkElements(self.filterUsageSelector,      FocusManager.TOP,    self.filterAnimalTypeSelector)
    end
    if self.filterUsageSelector ~= nil and self.filterOpSelector ~= nil then
        FocusManager:linkElements(self.filterUsageSelector, FocusManager.BOTTOM, self.filterOpSelector)
        FocusManager:linkElements(self.filterOpSelector,    FocusManager.TOP,    self.filterUsageSelector)
    end

    -- [+ condition] lives on the action bar, not in-pane, so DOWN from the last
    -- metadata row reaches the conditions list directly.
    if self.filterOpSelector ~= nil and self.filterConditionsList ~= nil then
        FocusManager:linkElements(self.filterOpSelector,     FocusManager.BOTTOM, self.filterConditionsList)
        FocusManager:linkElements(self.filterConditionsList, FocusManager.TOP,    self.filterOpSelector)
    end
    Log:trace("RLMenuSettingsFrame:onFrameOpen: editor focus chain linked")

    -- Reset the conditions-list measure flag so its size log fires once per
    -- frame-open cycle.
    self.didMeasureConditionsList = false

    -- Initial focus on the tab bar: [General] has no content to focus.
    FocusManager:setFocus(self.subCategoryPaging)

    -- Pending-select tail: flip to [Filters] so the user lands on the editor
    -- for the just-created filter. This overrides the setState(GENERAL) above,
    -- which runs first on every open.
    if didPendingSelect then
        Log:debug("RLMenuSettingsFrame:onFrameOpen: pending-select tail; switching to FILTERS subtab")
        self.subCategoryPaging:setState(RLMenuSettingsFrame.SUB_CATEGORY.FILTERS, true)
    end
end

--- Alternately tint `layout`'s visible rows so the cream title text reads;
--- "sectionHeader" spacers restart the alternation and hidden rows are skipped.
--- @param layout table The ScrollingLayout whose child elements to tint
function RLMenuSettingsFrame:updateAlternatingElements(layout)
    Log:debug("RLMenuSettingsFrame:updateAlternatingElements: enter")

    if layout == nil or layout.elements == nil then
        Log:warning("RLMenuSettingsFrame:updateAlternatingElements: layout or layout.elements is nil; skipping tint pass (rows will remain unreadable)")
        return
    end

    local colorTable = InGameMenuSettingsFrame ~= nil and InGameMenuSettingsFrame.COLOR_ALTERNATING or nil
    if colorTable == nil or colorTable[true] == nil or colorTable[false] == nil then
        Log:warning("RLMenuSettingsFrame:updateAlternatingElements: InGameMenuSettingsFrame.COLOR_ALTERNATING unavailable; skipping tint pass (rows will remain unreadable)")
        return
    end

    Log:debug("RLMenuSettingsFrame:updateAlternatingElements: layout id=%s, %d child element(s)",
        tostring(layout.id), #layout.elements)

    local alternate = true
    local tintedCount = 0
    local resetCount = 0

    -- ipairs, not pairs: the section reset and the parity toggle both depend
    -- on authored XML order.
    for _, row in ipairs(layout.elements) do
        if row.name == "sectionHeader" then
            alternate = true
            resetCount = resetCount + 1
        elseif row.visible and row.setImageColor ~= nil then
            row:setImageColor(nil, unpack(colorTable[alternate]))
            alternate = not alternate
            tintedCount = tintedCount + 1
        end
    end

    layout:invalidateLayout()
    Log:debug("RLMenuSettingsFrame:updateAlternatingElements: tinted=%d resets=%d", tintedCount, resetCount)
    Log:debug("RLMenuSettingsFrame:updateAlternatingElements: exit")
end

--- Deactivation hook: clears isFrameOpen BEFORE flushing, or a rebroadcast
--- arriving mid-flush re-enters refreshData recursively.
function RLMenuSettingsFrame:onFrameClose()
    RLMenuSettingsFrame:superClass().onFrameClose(self)
    self.isFrameOpen = false
    Log:debug("RLMenuSettingsFrame:onFrameClose")
    self:flushPendingChanges()
end

--- Seed the subcategory tab bar: getIsSelected closures, pager texts, and the
--- pager size. The closures resolve through `.texts`, the authoritative map.
function RLMenuSettingsFrame:initializeSubCategoryPages()
    Log:debug("RLMenuSettingsFrame:initializeSubCategoryPages: binding %d tab(s)",
        #self.subCategoryTabs)

    local subCategories = {}

    for index, button in ipairs(self.subCategoryTabs) do
        -- Tab Button's highlight (outer click surface)
        button.getIsSelected = function()
            return index == tonumber(self.subCategoryPaging.texts[self.subCategoryPaging:getState()])
        end

        -- Tab background ThreePartBitmap (renders the selected/unselected slices)
        local bg = button:getDescendantByName("background")
        if bg ~= nil then
            bg.getIsSelected = function()
                return index == tonumber(self.subCategoryPaging.texts[self.subCategoryPaging:getState()])
            end
        else
            Log:warning("RLMenuSettingsFrame:initializeSubCategoryPages: tab %d missing 'background' descendant",
                index)
        end

        table.insert(subCategories, tostring(index))
    end

    self.subCategoryBox:invalidateLayout()
    self.subCategoryPaging:setTexts(subCategories)
    self.subCategoryPaging:setSize(self.subCategoryBox.maxFlowSize + 140 * g_pixelSizeScaledX)
end

--- Pager state-change callback. `.texts` is briefly out of sync during
--- setTexts, so a nil lookup returns early.
--- @param state number The paging state index (1..#texts)
function RLMenuSettingsFrame:updateSubCategoryPages(state)
    local idx = tonumber(self.subCategoryPaging.texts[state])
    if idx == nil then
        Log:trace("RLMenuSettingsFrame:updateSubCategoryPages: state=%s resolved to nil idx, skipping",
            tostring(state))
        return
    end

    Log:debug("RLMenuSettingsFrame:updateSubCategoryPages: state=%d idx=%d", state, idx)

    for index, page in ipairs(self.subCategoryPages) do
        page:setVisible(index == idx)
    end

    -- The slider box lives at the GUI root, not inside subCategoryPages[1], so
    -- it does not inherit the per-page setVisible above and must be hidden
    -- explicitly when the Filters tab is active.
    local sliderBox = self.generalSettingsSliderBox or self:getDescendantById("generalSettingsSliderBox")
    if sliderBox ~= nil then
        self.generalSettingsSliderBox = sliderBox -- cache for next call
        local visible = (idx == RLMenuSettingsFrame.SUB_CATEGORY.GENERAL)
        sliderBox:setVisible(visible)
        Log:trace("RLMenuSettingsFrame:updateSubCategoryPages: generalSettingsSliderBox visible=%s (idx=%d)",
            tostring(visible), idx)
    end

    -- First-visibility measure log, one-shot per frame-open cycle and taken
    -- after the visibility toggle so the stretched size has settled. A stretch
    -- can leave the size table present but its axes nil until the next pass.
    if idx == RLMenuSettingsFrame.SUB_CATEGORY.FILTERS
       and not self.didMeasureFiltersPane
       and self.filtersListContainer ~= nil
       and self.filtersListContainer.size ~= nil
       and self.filtersListContainer.size[1] ~= nil
       and self.filtersListContainer.size[2] ~= nil then
        Log:debug("RLMenuSettingsFrame: filtersListContainer measured: %.2fpx x %.2fpx",
            self.filtersListContainer.size[1] * 1920,
            self.filtersListContainer.size[2] * 1080)

        -- Log the editor container, conditions list and banner so the banner
        -- anchor comes from a measurement rather than a guessed reservation.
        local function _logBox(name, e)
            if e == nil then Log:debug("RLMenuSettingsFrame._geom: %s == nil", name); return end
            local ax = (e.absPosition and e.absPosition[1] or 0) * g_referenceScreenWidth
            local ay = (e.absPosition and e.absPosition[2] or 0) * g_referenceScreenHeight
            local sw = (e.size and e.size[1] or 0) * g_referenceScreenWidth
            local sh = (e.size and e.size[2] or 0) * g_referenceScreenHeight
            Log:debug("RLMenuSettingsFrame._geom: %s absPos=(%.1f,%.1f) size=(%.1fx%.1f) top=%.1f bottom=%.1f",
                name, ax, ay, sw, sh, ay + sh, ay)
        end
        local editorContainer = self:getDescendantById("filterEditorContainer")
        local editorLayout    = self:getDescendantById("filterEditorLayout")
        _logBox("filterEditorContainer",        editorContainer)
        _logBox("filterEditorLayout(metadata)", editorLayout)
        _logBox("filterConditionsListContainer", self.filterConditionsListContainer)
        _logBox("filterConditionsBanner",        self.filterConditionsBanner)
        if editorContainer ~= nil and self.filterConditionsListContainer ~= nil
           and editorContainer.absPosition and self.filterConditionsListContainer.absPosition
           and editorContainer.size and self.filterConditionsListContainer.size then
            local containerTop   = (editorContainer.absPosition[2] + editorContainer.size[2]) * g_referenceScreenHeight
            local listTop        = (self.filterConditionsListContainer.absPosition[2] + self.filterConditionsListContainer.size[2]) * g_referenceScreenHeight
            Log:debug("RLMenuSettingsFrame._geom: containerTop=%.1f conditionsListTop=%.1f -> metadata block height=%.1fpx",
                containerTop, listTop, containerTop - listTop)
        end

        self.didMeasureFiltersPane = true
    end

    -- Editor pane measure log, once per process since the frame instance is
    -- reused across reopens. A material divergence from ~1088 x 783 px means
    -- the container's size override is not producing the expected stretch.
    if idx == RLMenuSettingsFrame.SUB_CATEGORY.FILTERS
       and not self.didMeasureEditorPane
       and self.filterEditorContainer ~= nil
       and self.filterEditorContainer.size ~= nil
       and self.filterEditorContainer.size[1] ~= nil
       and self.filterEditorContainer.size[2] ~= nil then
        Log:debug("RLMenuSettingsFrame: filterEditorContainer measured: %.2fpx x %.2fpx",
            self.filterEditorContainer.size[1] * 1920,
            self.filterEditorContainer.size[2] * 1080)
        self.didMeasureEditorPane = true
    end

    -- Rebuild the footer menu buttons so New filter appears only on
    -- [Filters] with farm + tradeAnimals; [General] collapses to Back.
    self:updateButtonVisibility()

    -- Focus shift on subtab change. On [Filters] focus lands on the list
    -- so gamepad/keyboard users can immediately arrow through rows;
    -- on [General] focus returns to the tab bar (empty pane, no list).
    -- Matches the linkElements + setFocus pattern used across Info/Buy/
    -- Sell/Move/AI frames.
    if idx == RLMenuSettingsFrame.SUB_CATEGORY.FILTERS and self.filtersList ~= nil then
        FocusManager:setFocus(self.filtersList)
    elseif self.subCategoryPaging ~= nil then
        FocusManager:setFocus(self.subCategoryPaging)
    end
end

--- XML onClick handler for the [General] tab button.
function RLMenuSettingsFrame:onClickGeneralTab()
    Log:trace("RLMenuSettingsFrame:onClickGeneralTab")
    self.subCategoryPaging:setState(RLMenuSettingsFrame.SUB_CATEGORY.GENERAL, true)
end

--- XML onClick handler for the [Filters] tab button.
function RLMenuSettingsFrame:onClickFiltersTab()
    Log:trace("RLMenuSettingsFrame:onClickFiltersTab")
    self.subCategoryPaging:setState(RLMenuSettingsFrame.SUB_CATEGORY.FILTERS, true)
end

-- =============================================================================
-- Filter list: data + lifecycle
-- =============================================================================

--- Pull filter rows from the service for the local player's farm and
--- reload the SmoothList. Rebuilds empty-state, footer buttons, and
--- re-resolves the id-authoritative selection against the new rows.
function RLMenuSettingsFrame:refreshData()
    local farmId
    if g_currentMission ~= nil and g_currentMission.getFarmId ~= nil then
        farmId = g_currentMission:getFarmId()
    end
    self.farmId = farmId

    local hasFarm = (farmId ~= nil and farmId ~= 0)
    if hasFarm and g_rlFilterService ~= nil then
        -- animalType=nil: settings UI is type-agnostic.
        -- farmId=localFarmId: nil-or-equal returns globals + own-farm only,
        -- never other farms' per-farm filters.
        self.rows = g_rlFilterService:listAvailable(nil, farmId)
    else
        self.rows = {}
    end

    -- Case-insensitive sort with a stable id tie-break, on refreshData
    -- boundaries only, so row positions stay put while the user is typing.
    table.sort(self.rows, function(a, b)
        local an = (a.name or ""):lower()
        local bn = (b.name or ""):lower()
        if an == bn then
            return (a.id or "") < (b.id or "")
        end
        return an < bn
    end)

    Log:debug("RLMenuSettingsFrame:refreshData: farmId=%s rows=%d",
        tostring(farmId), #self.rows)

    -- isReconciling gate: reloadData fires onListSelectionChanged synchronously
    -- after clamping, and resolveSelectionById re-enters it the same way.
    self.isReconciling = true
    if self.filtersList ~= nil then
        self.filtersList:reloadData()
    end
    self:resolveSelectionById()
    self.isReconciling = false

    self:updateEmptyState()
    self:updateButtonVisibility()

    -- Tail renderEditor so the right pane follows the new selection, including
    -- the empty-state branch when resolveSelectionById cleared an orphaned id.
    self:renderEditor()
end

--- Refresh only when the frame is open, so a remote mutation rerenders the
--- list without the user reopening the menu.
function RLMenuSettingsFrame:refreshIfOpen()
    if self.isFrameOpen then
        Log:debug("RLMenuSettingsFrame:refreshIfOpen: refreshing")
        self:refreshData()
    else
        Log:debug("RLMenuSettingsFrame:refreshIfOpen: frame closed, skipping")
    end
end

--- Re-derive list.selectedIndex from selectedFilterId, clearing both when the
--- id has gone. Undefined pairs-order reloads would otherwise desync them.
function RLMenuSettingsFrame:resolveSelectionById()
    if self.filtersList == nil then return end

    if self.selectedFilterId == nil then
        -- Clear both fields, not just selectedIndex: SmoothList expects
        -- numeric indices and a nil would crash.
        self.filtersList.selectedSectionIndex = 0
        self.filtersList.selectedIndex = 0
        Log:trace("RLMenuSettingsFrame:resolveSelectionById: no id cached, cleared")
        return
    end

    for i, row in ipairs(self.rows) do
        if row.id == self.selectedFilterId then
            self.filtersList:setSelectedIndex(i)
            Log:debug("RLMenuSettingsFrame:resolveSelectionById: id=%s resolved to index=%d",
                tostring(self.selectedFilterId), i)
            return
        end
    end

    Log:debug("RLMenuSettingsFrame:resolveSelectionById: id=%s no longer in rows, clearing",
        tostring(self.selectedFilterId))
    self.selectedFilterId = nil
    self.filtersList.selectedSectionIndex = 0
    self.filtersList.selectedIndex = 0
end

--- Toggle the empty-state text and the list/slider visibility, branching the
--- copy on whether the player has a farm at all.
function RLMenuSettingsFrame:updateEmptyState()
    local hasRows = #self.rows > 0
    local hasFarm = (self.farmId ~= nil and self.farmId ~= 0)
    Log:debug("RLMenuSettingsFrame:updateEmptyState: hasFarm=%s hasRows=%s",
        tostring(hasFarm), tostring(hasRows))

    if self.filtersEmptyState ~= nil then
        if not hasFarm then
            self.filtersEmptyState:setText(g_i18n:getText("rl_menu_filters_empty_no_farm"))
        else
            self.filtersEmptyState:setText(g_i18n:getText("rl_menu_filters_empty"))
        end
        self.filtersEmptyState:setVisible(not hasRows)
    end

    if self.filtersList ~= nil then
        self.filtersList:setVisible(hasRows)
    end

    -- Toggle the slider box alongside the list, so an empty state does not
    -- leave an orphaned scrollbar beside the message.
    if self.filtersSliderBox ~= nil then
        self.filtersSliderBox:setVisible(hasRows)
    end
end

--- Resolve the active action-bar tier from the current focus: 1 for the filter
--- list, 2 for the editor, 3 for a selected condition row, nil for untracked.
--- FocusManager treats a SmoothList as one element, so a selected row is
--- distinguished by getSelectedIndexInSection rather than by focus state.
function RLMenuSettingsFrame:resolveActionBarTier()
    if FocusManager == nil or FocusManager.getFocusedElement == nil then
        return nil
    end
    local focused = FocusManager:getFocusedElement()
    if focused == nil then return nil end

    -- Walk the focus's parent chain for a known anchor, stopping at the first.
    local node = focused
    while node ~= nil do
        if node == self.filterConditionsList then
            local idx = nil
            if node.getSelectedIndexInSection ~= nil then
                idx = node:getSelectedIndexInSection()
            end
            local rowCount = (self.conditionEditState and self.conditionEditState.supportedRows)
                             and #self.conditionEditState.supportedRows or 0
            if rowCount > 0 and idx ~= nil and idx > 0 then
                return 3
            end
            return 2
        end
        if node == self.filtersList then return 1 end
        if node == self.filterNameInput
           or node == self.filterAnimalTypeSelector
           or node == self.filterOpSelector
           or node == self.filterUsageSelector then
            return 2
        end
        node = node.parent
    end
    return nil
end

--- Rebuild the footer button array for the active tier. Back is always there;
--- tier buttons need the Filters subtab, a farm, and the tradeAnimals right.
function RLMenuSettingsFrame:updateButtonVisibility()
    local activeSubtab
    if self.subCategoryPaging ~= nil then
        activeSubtab = self.subCategoryPaging:getState()
    end
    local hasFarm = (self.farmId ~= nil and self.farmId ~= 0)
    local hasPerm = self:hasCreatePermission()
    local hasSelection = (self.selectedFilterId ~= nil)
    local appended = {}

    -- Right-pane editor-widget gate: without it the metadata widgets accept
    -- input the server then drops, giving a misleading commit-then-revert.
    -- setDisabled is idempotent, so re-entry on every focus change is safe.
    local editable = hasFarm and hasPerm
    if self.filterNameInput          ~= nil then self.filterNameInput:setDisabled(not editable) end
    if self.filterAnimalTypeSelector ~= nil then self.filterAnimalTypeSelector:setDisabled(not editable) end
    if self.filterOpSelector         ~= nil then self.filterOpSelector:setDisabled(not editable) end
    if self.filterUsageSelector      ~= nil then self.filterUsageSelector:setDisabled(not editable) end
    Log:trace("RLMenuSettingsFrame:updateButtonVisibility: right-pane widgets editable=%s (hasFarm=%s hasPerm=%s)",
        tostring(editable), tostring(hasFarm), tostring(hasPerm))

    self.menuButtonInfo = { self.backButtonInfo }

    -- Tier 1 is the fallback when no tracked anchor holds focus. Without it the
    -- empty state traps the user on [Back] alone, because filtersList is hidden
    -- and "New filter" would vanish exactly when it is needed to escape.
    local tier = nil
    if activeSubtab == RLMenuSettingsFrame.SUB_CATEGORY.FILTERS
       and hasFarm and hasPerm then
        tier = self:resolveActionBarTier()
        if tier == nil then
            tier = 1
            Log:trace("RLMenuSettingsFrame:updateButtonVisibility: fallback to Tier 1 (no tracked anchor focused)")
        end
    end

    if tier == 1 then
        table.insert(self.menuButtonInfo, self.newFilterButtonInfo)
        table.insert(appended, "New")
        if hasSelection then
            table.insert(self.menuButtonInfo, self.duplicateButtonInfo)
            table.insert(self.menuButtonInfo, self.deleteButtonInfo)
            table.insert(appended, "Duplicate")
            table.insert(appended, "Delete")
        end
    elseif tier == 2 then
        if hasSelection then
            table.insert(self.menuButtonInfo, self.addConditionButtonInfo)
            table.insert(appended, "AddCondition")
        end
    elseif tier == 3 then
        if hasSelection then
            table.insert(self.menuButtonInfo, self.editConditionButtonInfo)
            table.insert(self.menuButtonInfo, self.addConditionButtonInfo)
            -- "Add group" is hidden until group editing exists; restoring these
            -- two inserts re-enables it.
            -- table.insert(self.menuButtonInfo, self.addGroupButtonInfo)
            table.insert(self.menuButtonInfo, self.deleteConditionButtonInfo)
            table.insert(appended, "Edit")
            table.insert(appended, "AddCondition")
            -- table.insert(appended, "AddGroup")
            table.insert(appended, "DeleteCondition")
        end
    end

    Log:debug("RLMenuSettingsFrame:updateButtonVisibility: subtab=%s tier=%s hasFarm=%s hasPerm=%s hasSelection=%s appended=[%s]",
        tostring(activeSubtab), tostring(tier),
        tostring(hasFarm), tostring(hasPerm), tostring(hasSelection),
        table.concat(appended, ","))
    self:setMenuButtonInfoDirty()
end

--- UX-side permission gate for New filter. The authoritative boundary is the
--- server-side validation in the RLFilter events; this only gates the button.
function RLMenuSettingsFrame:hasCreatePermission()
    if g_currentMission == nil or g_currentMission.getHasPlayerPermission == nil then
        return false
    end
    return g_currentMission:getHasPlayerPermission("tradeAnimals") == true
end

-- =============================================================================
-- Filter list: create handler
-- =============================================================================

--- Disambiguated default name, so repeated [New filter] clicks do not produce
--- identical rows. Static, so both callers produce the same sequence.
---@param names string[] existing filter names
---@return string
local function static_computeDefaultFilterName(names)
    local base = g_i18n:getText("rl_menu_filters_default_name")
    -- Match "<base> (N)" where N is one or more digits, anchored end-to-end.
    local pattern = "^" .. base:gsub("(%W)", "%%%1") .. " %((%d+)%)$"
    -- Track the MAX N seen, not the count: after deletes leave sparse rows, a
    -- count would emit a name that collides. The bare base counts as N=1.
    local maxN = 0
    if names ~= nil then
        for _, name in ipairs(names) do
            local n = name or ""
            if n == base then
                if maxN < 1 then maxN = 1 end
            else
                local capture = n:match(pattern)
                if capture ~= nil then
                    local num = tonumber(capture)
                    if num ~= nil and num > maxN then
                        maxN = num
                    end
                end
            end
        end
    end
    local result
    if maxN == 0 then
        result = base
    else
        result = string.format("%s (%d)", base, maxN + 1)
    end
    Log:trace("static_computeDefaultFilterName: base='%s' maxN=%d result='%s'",
        base, maxN, result)
    return result
end

--- Exported static wrapper, so a caller without a frame instance can produce
--- the same default name from a plain name list.
---@param names string[] existing filter names
---@return string
function RLMenuSettingsFrame.computeDefaultFilterNameForNames(names)
    return static_computeDefaultFilterName(names)
end

--- Instance wrapper: take the names from `self.rows` and delegate.
---@return string
function RLMenuSettingsFrame:computeDefaultFilterName()
    local names = {}
    if self.rows ~= nil then
        for _, row in ipairs(self.rows) do
            table.insert(names, row.name or "")
        end
    end
    return static_computeDefaultFilterName(names)
end

--- Footer New filter handler: creates a farm-scoped placeholder with an empty
--- (vacuous-true) AND expression, then refreshes onto the new row.
function RLMenuSettingsFrame:onClickNewFilter()
    if not self:hasCreatePermission() then
        Log:trace("RLMenuSettingsFrame:onClickNewFilter: no tradeAnimals permission, aborting")
        return
    end
    if self.farmId == nil or self.farmId == 0 then
        Log:trace("RLMenuSettingsFrame:onClickNewFilter: no farm, aborting")
        return
    end
    if g_rlFilterService == nil then
        Log:warning("RLMenuSettingsFrame:onClickNewFilter: g_rlFilterService is nil; aborting")
        return
    end

    local name = self:computeDefaultFilterName()
    Log:debug("RLMenuSettingsFrame:onClickNewFilter: creating filter name='%s' farmId=%s",
        name, tostring(self.farmId))

    local created = g_rlFilterService:create({
        name       = name,
        animalType = nil,
        farmId     = self.farmId,
        usage      = RLFilterUsage.ANY,
        expression = { op = "AND", children = {} },
    })
    if created == nil then
        Log:warning("RLMenuSettingsFrame:onClickNewFilter: service rejected create (nil return)")
        return
    end

    -- Set the id BEFORE refresh so resolveSelectionById picks the new row.
    self.selectedFilterId = created.id
    Log:debug("RLMenuSettingsFrame:onClickNewFilter: created id=%s name='%s'",
        tostring(created.id), tostring(created.name))

    self:refreshData()
end

-- =============================================================================
-- Filter editor: helpers (file-local)
-- =============================================================================

--- Resolve a localized label for an animal type.
---@param at table animalType entry from animalSystem:getTypes()
---@return string label
---@see RLAnimalUtil.getAnimalTypeDisplayName
local function resolveAnimalTypeLabel(at)
    if RLAnimalUtil ~= nil and RLAnimalUtil.getAnimalTypeDisplayName ~= nil then
        return RLAnimalUtil.getAnimalTypeDisplayName(at)
    end
    -- Defensive fallback if RLAnimalUtil is unavailable for any reason.
    Log:warning("resolveAnimalTypeLabel: RLAnimalUtil.getAnimalTypeDisplayName unavailable; using local fallback")
    if at == nil then return "?" end
    return at.groupTitle or at.name or "?"
end

--- True when `node` is an expression group (op + children), not a leaf.
---@param node table|nil
---@return boolean
local function isGroupNode(node)
    return node ~= nil and node.op ~= nil and node.children ~= nil
end

--- Compare a condition's value: scalars by `==`, list values element-wise.
--- Mixed types are unequal.
---@param va any
---@param vb any
---@return boolean
local function deepEqualConditionValue(va, vb)
    if type(va) ~= type(vb) then return false end
    if type(va) == "table" then
        if #va ~= #vb then return false end
        for j = 1, #va do
            if va[j] ~= vb[j] then return false end
        end
        return true
    end
    return va == vb
end

local deepEqualGroup -- forward decl for mutual recursion with deepEqualNode

--- Compare one expression node: groups recurse, leaves compare field/cmp/value.
---@param a table|nil
---@param b table|nil
---@return boolean
local function deepEqualNode(a, b)
    if a == nil or b == nil then return a == b end
    local ag = isGroupNode(a)
    if ag ~= isGroupNode(b) then return false end
    if ag then return deepEqualGroup(a, b) end
    if a.field ~= b.field then return false end
    if a.cmp ~= b.cmp then return false end
    return deepEqualConditionValue(a.value, b.value)
end

deepEqualGroup = function(a, b)
    if a == nil or b == nil then return a == b end
    if a.op ~= b.op then return false end
    local ac = a.children or {}
    local bc = b.children or {}
    if #ac ~= #bc then return false end
    for i = 1, #ac do
        if not deepEqualNode(ac[i], bc[i]) then return false end
    end
    return true
end

--- Deep-compare a merged snapshot against a stored filter on the fields an
--- overlay can change, so a collapsed overlay skips the wire update. Id and
--- version are skipped: neither is authored by the editor.
---@param merged table
---@param stored table
---@return boolean equal
local function deepEqualFilter(merged, stored)
    if merged == nil or stored == nil then return merged == stored end
    if merged.name ~= stored.name then return false end
    if merged.animalType ~= stored.animalType then return false end
    if merged.farmId ~= stored.farmId then return false end
    if merged.usage ~= stored.usage then return false end
    return deepEqualGroup(merged.expression, stored.expression)
end

--- Apply a pending overlay onto a stored filter. Immutable fields are copied
--- unchanged, so service:update never sees a divergence.
---@param stored table cloned snapshot from getById (never nil at this point)
---@param overlay table|nil per-id partial overlay or nil for "no pending"
---@return table merged shallow-cloned filter with overlay applied
local function overlayPending(stored, overlay)
    -- A nil stored.usage would make service:update reject, silently dropping
    -- every other pending edit on that filter; default it instead.
    local mergedUsage = stored.usage or RLFilterUsage.ANY
    local merged = {
        id         = stored.id,
        farmId     = stored.farmId,
        version    = stored.version,
        name       = stored.name,
        animalType = stored.animalType,
        usage      = mergedUsage,
        expression = stored.expression,
    }
    if overlay == nil then
        return merged
    end
    if overlay.name ~= nil then
        merged.name = overlay.name
    end
    if overlay.animalType == RLMenuSettingsFrame.ANIMAL_TYPE_ANY then
        -- Sentinel marks an explicit "clear to Any"; storage wants nil.
        merged.animalType = nil
    elseif overlay.animalType ~= nil then
        merged.animalType = overlay.animalType
    end
    if overlay.usage ~= nil then
        -- No sentinel needed: every usage state has a canonical string value.
        merged.usage = overlay.usage
    end
    if overlay.op ~= nil then
        -- Fresh root group with the new op, preserving nested children so a
        -- filter authored with sub-groups keeps its structure.
        local stored_children = (stored.expression and stored.expression.children) or {}
        local copied = {}
        for i, child in ipairs(stored_children) do copied[i] = child end
        merged.expression = { op = overlay.op, children = copied }
    end
    return merged
end

--- Populate self.animalTypeStates: the "Any" row at index 1, then one row per
--- type from animalSystem:getTypes().
---@param self table frame instance
local function seedAnimalTypeStates(self)
    local entries = {
        { label = g_i18n:getText("rl_menu_filters_animal_type_any"), typeIndex = nil },
    }
    if g_currentMission ~= nil and g_currentMission.animalSystem ~= nil then
        local types = g_currentMission.animalSystem:getTypes()
        if types ~= nil then
            -- getTypes() is a sparse map keyed by typeIndex, not a dense array:
            -- ipairs would stop at the first gap and drop map-bridge types.
            -- Collect with pairs(), then sort by typeIndex for stable order.
            local collected = {}
            for _, at in pairs(types) do
                if at ~= nil and at.typeIndex ~= nil then
                    table.insert(collected, at)
                end
            end
            table.sort(collected, function(a, b)
                return (a.typeIndex or 0) < (b.typeIndex or 0)
            end)
            for _, at in ipairs(collected) do
                table.insert(entries, {
                    label = resolveAnimalTypeLabel(at),
                    typeIndex = at.typeIndex,
                })
            end
        end
    end
    self.animalTypeStates = entries

    -- setTexts clamps state to #texts, so an earlier setState survives a shrink.
    if self.filterAnimalTypeSelector ~= nil then
        local labels = {}
        for i, entry in ipairs(entries) do labels[i] = entry.label end
        self.filterAnimalTypeSelector:setTexts(labels)
    end
    Log:trace("seedAnimalTypeStates: %d state(s) seeded", #entries)
end

--- Push the Usage selector labels: state 1 ANY, 2 OWNED, 3 DEALER.
---@param self table frame instance
local function seedUsageSelector(self)
    if self.filterUsageSelector == nil then
        return
    end
    self.filterUsageSelector:setTexts({
        g_i18n:getText("rl_menu_filters_usage_any"),
        g_i18n:getText("rl_menu_filters_usage_owned"),
        g_i18n:getText("rl_menu_filters_usage_dealer"),
    })
    Log:trace("seedUsageSelector: 3 state(s) seeded")
end

-- =============================================================================
-- Filter editor: render + widget callbacks
-- =============================================================================

--- Drive the right-pane editor widgets from the selection and pending overlay.
--- The programmatic pushes carry callback-suppress flags so they do not
--- re-enter the click handlers.
-- Forward declaration: renderConditionsForFilter is defined below, and Lua
-- resolves free variables against locals declared EARLIER in the chunk, so
-- without this the reference inside renderEditor would find a nil global.
local renderConditionsForFilter

function RLMenuSettingsFrame:renderEditor()
    if self.selectedFilterId == nil then
        if self.filterEditorEmpty     ~= nil then self.filterEditorEmpty:setVisible(true) end
        if self.filterEditorLayout    ~= nil then self.filterEditorLayout:setVisible(false) end
        if self.filterEditorSliderBox ~= nil then self.filterEditorSliderBox:setVisible(false) end
        -- The banner and list container are SIBLINGS of filterEditorLayout, so
        -- hiding the layout does not recurse into them - hide them explicitly
        -- or a deleted filter's rows linger after the selection clears.
        if self.filterConditionsBanner        ~= nil then self.filterConditionsBanner:setVisible(false)        end
        if self.filterConditionsListContainer ~= nil then self.filterConditionsListContainer:setVisible(false) end
        if self.filterConditionsSliderBox     ~= nil then self.filterConditionsSliderBox:setVisible(false)     end
        Log:debug("RLMenuSettingsFrame:renderEditor: no selection")
        return
    end

    -- Hydrate the selector states first, so the index resolution below maps
    -- against the live label set.
    seedAnimalTypeStates(self)
    seedUsageSelector(self)

    if g_rlFilterService == nil then
        Log:warning("RLMenuSettingsFrame:renderEditor: g_rlFilterService is nil; aborting render")
        return
    end

    local stored = g_rlFilterService:getById(self.selectedFilterId)
    if stored == nil then
        -- Selected id is gone - a race with a remote delete. Drop the
        -- selection and fall through to the empty-state branch.
        Log:debug("RLMenuSettingsFrame:renderEditor: id=%s not in service, falling back to empty",
            tostring(self.selectedFilterId))
        self.selectedFilterId = nil
        if self.filterEditorEmpty     ~= nil then self.filterEditorEmpty:setVisible(true) end
        if self.filterEditorLayout    ~= nil then self.filterEditorLayout:setVisible(false) end
        if self.filterEditorSliderBox ~= nil then self.filterEditorSliderBox:setVisible(false) end
        -- As in the no-selection branch: hide the conditions banner and list
        -- container so the vanished filter's rows do not linger.
        if self.filterConditionsBanner        ~= nil then self.filterConditionsBanner:setVisible(false)        end
        if self.filterConditionsListContainer ~= nil then self.filterConditionsListContainer:setVisible(false) end
        if self.filterConditionsSliderBox     ~= nil then self.filterConditionsSliderBox:setVisible(false)     end
        return
    end

    local merged = overlayPending(stored, self.pendingChanges[self.selectedFilterId])

    if self.filterEditorEmpty     ~= nil then self.filterEditorEmpty:setVisible(false) end
    if self.filterEditorLayout    ~= nil then self.filterEditorLayout:setVisible(true)  end
    if self.filterEditorSliderBox ~= nil then self.filterEditorSliderBox:setVisible(true) end
    -- Re-show the conditions area; renderConditionsForFilter then drives the
    -- banner from the partition's preserved count.
    if self.filterConditionsListContainer ~= nil then self.filterConditionsListContainer:setVisible(true) end
    if self.filterConditionsSliderBox     ~= nil then self.filterConditionsSliderBox:setVisible(true)     end

    -- Tint the editor rows so the cream title text reads. This MUST run after
    -- the setVisible(true) above, because updateAlternatingElements skips
    -- hidden rows.
    if self.filterEditorLayout ~= nil then
        self:updateAlternatingElements(self.filterEditorLayout)
    end

    -- Caret preservation: the input resets the caret to text-end on every
    -- programmatic push, no-ops included, so a remote update arriving mid-edit
    -- would stomp it. Skip the push while the input is focused and unchanged.
    if self.filterNameInput ~= nil then
        local desired = merged.name or ""
        local isFocused = self.filterNameInput.getIsFocused ~= nil
            and self.filterNameInput:getIsFocused()
        local current = self.filterNameInput.getText ~= nil
            and self.filterNameInput:getText() or nil
        if isFocused and current == desired then
            Log:trace("RLMenuSettingsFrame:renderEditor: skipping setText (focused + unchanged) for id=%s",
                tostring(merged.id))
        else
            self.filterNameInput:setText(desired)
        end
    end

    -- AnimalType: fall back to state 1 (Any) when nothing matches, which
    -- covers a stored type this mission does not define.
    local atStateIndex = 1
    for i, entry in ipairs(self.animalTypeStates) do
        if entry.typeIndex == merged.animalType then
            atStateIndex = i
            break
        end
    end
    if self.filterAnimalTypeSelector ~= nil then
        self.filterAnimalTypeSelector:setState(atStateIndex, false)
    end

    -- Op: 1 = AND, 2 = OR. Default to AND when expression has no root op.
    local opStateIndex = 1
    if merged.expression ~= nil and merged.expression.op == "OR" then
        opStateIndex = 2
    end
    if self.filterOpSelector ~= nil then
        self.filterOpSelector:setState(opStateIndex, false)
    end

    -- Usage: 1 = ANY, 2 = OWNED, 3 = DEALER; anything unrecognised means ANY.
    local usageStateIndex = 1
    if merged.usage == RLFilterUsage.OWNED then
        usageStateIndex = 2
    elseif merged.usage == RLFilterUsage.DEALER then
        usageStateIndex = 3
    end
    if self.filterUsageSelector ~= nil then
        self.filterUsageSelector:setState(usageStateIndex, false)
    end

    Log:debug("RLMenuSettingsFrame:renderEditor: id=%s name=%s animalType=%s op=%s usage=%s",
        tostring(merged.id), tostring(merged.name),
        tostring(merged.animalType),
        tostring(merged.expression and merged.expression.op),
        tostring(merged.usage))

    renderConditionsForFilter(self, merged)
end

--- TextInput onTextChanged callback: stash the typed name in the overlay and
--- reload the left list so the cell tracks the live edit.
--- @param element table The TextInput element
--- @param _text string The new text (read from element for consistency)
function RLMenuSettingsFrame:onFilterNameChanged(element, _text)
    if self.selectedFilterId == nil then
        Log:trace("RLMenuSettingsFrame:onFilterNameChanged: no selection, ignoring")
        return
    end
    if element == nil then
        Log:trace("RLMenuSettingsFrame:onFilterNameChanged: nil element, ignoring")
        return
    end
    local typed = element:getText() or ""
    local id = self.selectedFilterId

    -- Phantom-rewrite guard: onChange also fires on programmatic setText, where
    -- the typed value already equals stored.name. Stashing that would look like
    -- a real edit and broadcast a byte-identical update over the wire.
    if g_rlFilterService ~= nil then
        local stored = g_rlFilterService:getById(id)
        if stored ~= nil then
            local trimmedTyped = typed:match("^%s*(.-)%s*$") or ""
            local trimmedStored = (stored.name or ""):match("^%s*(.-)%s*$") or ""
            if trimmedTyped == trimmedStored then
                local overlay = self.pendingChanges[id]
                if overlay ~= nil and overlay.name ~= nil then
                    overlay.name = nil
                    if next(overlay) == nil then
                        self.pendingChanges[id] = nil
                    end
                end
                Log:trace("RLMenuSettingsFrame:onFilterNameChanged: id=%s value='%s' equals stored; skipping stash",
                    tostring(id), typed)
                return
            end
        end
    end

    if self.pendingChanges[id] == nil then self.pendingChanges[id] = {} end
    self.pendingChanges[id].name = typed
    Log:debug("RLMenuSettingsFrame:onFilterNameChanged: id=%s value='%s'", tostring(id), typed)

    -- The isReconciling gate stops the synchronous onListSelectionChanged from
    -- re-entering renderEditor, whose setText would stomp the caret.
    if self.filtersList ~= nil then
        self.isReconciling = true
        self.filtersList:reloadData()
        self.isReconciling = false
    end
end

--- AnimalType selector callback. State 1 is the "Any" row, stored in the
--- overlay as the ANIMAL_TYPE_ANY sentinel rather than as nil.
--- @param state number 1-based selector state
--- @param _widget table The widget that was clicked
function RLMenuSettingsFrame:onAnimalTypeChanged(state, _widget)
    if self.selectedFilterId == nil then
        Log:trace("RLMenuSettingsFrame:onAnimalTypeChanged: no selection, ignoring (state=%s)",
            tostring(state))
        return
    end
    local entry = self.animalTypeStates[state]
    if entry == nil then
        Log:warning("RLMenuSettingsFrame:onAnimalTypeChanged: state=%s out of range (%d state(s) seeded); ignoring",
            tostring(state), #self.animalTypeStates)
        return
    end
    local id = self.selectedFilterId
    if self.pendingChanges[id] == nil then self.pendingChanges[id] = {} end
    if entry.typeIndex == nil then
        self.pendingChanges[id].animalType = RLMenuSettingsFrame.ANIMAL_TYPE_ANY
    else
        self.pendingChanges[id].animalType = entry.typeIndex
    end
    Log:debug("RLMenuSettingsFrame:onAnimalTypeChanged: id=%s state=%d typeIndex=%s",
        tostring(id), state, tostring(entry.typeIndex))
end

--- MultiTextOption onClick callback for the AND/OR root op selector.
--- state == 1 -> AND, state == 2 -> OR.
--- @param state number 1-based selector state
--- @param _widget table The widget that was clicked
function RLMenuSettingsFrame:onOpChanged(state, _widget)
    if self.selectedFilterId == nil then
        Log:trace("RLMenuSettingsFrame:onOpChanged: no selection, ignoring (state=%s)",
            tostring(state))
        return
    end
    local id = self.selectedFilterId
    if self.pendingChanges[id] == nil then self.pendingChanges[id] = {} end
    local op = (state == 2) and "OR" or "AND"
    self.pendingChanges[id].op = op
    Log:debug("RLMenuSettingsFrame:onOpChanged: id=%s state=%d op=%s",
        tostring(id), state, op)
end

--- Usage scope selector callback: state 1 ANY, 2 OWNED, 3 DEALER.
--- @param state number 1-based selector state
--- @param _widget table The widget that was clicked
function RLMenuSettingsFrame:onUsageChanged(state, _widget)
    if self.selectedFilterId == nil then
        Log:trace("RLMenuSettingsFrame:onUsageChanged: no selection, ignoring (state=%s)",
            tostring(state))
        return
    end
    local newUsage
    if state == 1 then
        newUsage = RLFilterUsage.ANY
    elseif state == 2 then
        newUsage = RLFilterUsage.OWNED
    elseif state == 3 then
        newUsage = RLFilterUsage.DEALER
    else
        Log:trace("RLMenuSettingsFrame:onUsageChanged: state=%s out of range; ignoring",
            tostring(state))
        return
    end
    local id = self.selectedFilterId
    if self.pendingChanges[id] == nil then self.pendingChanges[id] = {} end
    self.pendingChanges[id].usage = newUsage
    Log:debug("RLMenuSettingsFrame:onUsageChanged: id=%s state=%d usage=%s",
        tostring(id), state, newUsage)
end

-- =============================================================================
-- Filter editor: conditions list
-- =============================================================================

--- Field types the conditions editor can render. The cmp gate in
--- isSupportedConditionNode is type-conditional: only enum accepts in/notin.
local SUPPORTED_TYPES = { number = true, bool = true, enum = true, string = true }

--- True when the node is a flat condition the in-frame editor can render.
---@param node table
---@return boolean
local function isSupportedConditionNode(node)
    if type(node) ~= "table" then return false end
    if node.op ~= nil then return false end -- group, not a condition
    if node.field == nil or node.cmp == nil then return false end
    local field = RLFilterFieldCatalog.get(node.field)
    if field == nil then return false end
    if not SUPPORTED_TYPES[field.type] then return false end
    -- Only enum has a multi-value editor; every other type routes in/notin to
    -- preservedChildren for round-trip only.
    if (node.cmp == "in" or node.cmp == "notin") and field.type ~= "enum" then
        return false
    end
    return true
end

--- Split `expression.children` into rows the editor can render and preserved
--- nodes it cannot. Supported rows are fresh tables, so editing one never
--- mutates the stored expression; preserved nodes round-trip verbatim.
---@param expression table|nil root group node
---@return table[] supported list of {field, cmp, value} editable rows
---@return table[] preserved list of opaque child nodes to round-trip
local function partitionChildren(expression)
    local supported, preserved = {}, {}
    if expression == nil or type(expression.children) ~= "table" then
        return supported, preserved
    end
    for _, child in ipairs(expression.children) do
        if isSupportedConditionNode(child) then
            table.insert(supported, {
                field = child.field,
                cmp   = child.cmp,
                value = child.value,
            })
        else
            table.insert(preserved, child)
        end
    end
    Log:trace("partitionChildren: supported=%d preserved=%d",
        #supported, #preserved)
    return supported, preserved
end

--- Localized label for a catalog field key, via
--- `rl_menu_filters_field_<key with periods as underscores>`, else the key.
---@param key string
---@return string
local function resolveFieldLabel(key)
    local safe = key:gsub("%.", "_")
    local lookup = "rl_menu_filters_field_" .. safe
    if g_i18n:hasText(lookup) then
        return g_i18n:getText(lookup)
    end
    return key
end

--- Format a condition row for the read-only list display. The animalType
--- lookup is inlined because resolveEffectiveAnimalType is declared later in
--- the file and so is not visible from here.
---@param self table frame instance (used to resolve the filter's animalType scope)
---@param row table {field, cmp, value}
---@param field table catalog entry resolved from row.field
---@return string display
local function formatConditionDisplay(self, row, field)
    local animalType = nil
    if self ~= nil and self.selectedFilterId ~= nil and g_rlFilterService ~= nil then
        local stored = g_rlFilterService:getById(self.selectedFilterId)
        if stored ~= nil then
            animalType = stored.animalType
            local pendingForId = self.pendingChanges and self.pendingChanges[self.selectedFilterId]
            if pendingForId ~= nil and pendingForId.animalType ~= nil then
                if pendingForId.animalType == RLMenuSettingsFrame.ANIMAL_TYPE_ANY then
                    animalType = nil
                else
                    animalType = pendingForId.animalType
                end
            end
        end
    end
    return RLFilterFieldDisplay.formatConditionDisplay(row, field, animalType)
end

--- Renderable catalog fields for the filter, in catalog order. Cached on the
--- frame keyed by animalType, and cleared on every renderEditor.
---@param self table frame instance
---@param animalTypeIndex number|nil
---@return table[]
local function getEditableFieldOptions(self, animalTypeIndex)
    if self.conditionFieldOptionsCache ~= nil
       and self.conditionFieldOptionsCache.animalTypeIndex == animalTypeIndex then
        return self.conditionFieldOptionsCache.fields
    end
    local fields = RLFilterFieldCatalog.getAllForAnimalType(
        animalTypeIndex, SUPPORTED_TYPES)
    self.conditionFieldOptionsCache = {
        animalTypeIndex = animalTypeIndex,
        fields          = fields,
    }
    return fields
end

--- Row at a 1-based index in the editor's working state, or nil when out of
--- range - every widget callback runs through this, so callers must nil-guard.
---@param self table frame instance
---@param index number
---@return table|nil row
local function getConditionRowAt(self, index)
    if self.conditionEditState == nil then return nil end
    local rows = self.conditionEditState.supportedRows
    if rows == nil then return nil end
    return rows[index]
end

--- Reload the conditions list and restore focus to the same row. Without this,
--- deleting a focused row leaves FocusManager pointing at a recycled cell.
---@param self table frame instance
---@param preferredIndex number|nil 1-based row index to focus after reload
local function reloadConditionsList(self, preferredIndex)
    if self.filterConditionsList == nil then return end

    -- Rows carry no focusable widgets, and FocusManager treats the list as one
    -- element, so the list's own selection is the authoritative target.
    local targetIndex = preferredIndex
    if targetIndex == nil
       and self.filterConditionsList.getSelectedIndexInSection ~= nil then
        local idx = self.filterConditionsList:getSelectedIndexInSection()
        if idx ~= nil and idx > 0 then
            targetIndex = idx
        end
    end

    self.filterConditionsList:reloadData()

    local rowCount = (self.conditionEditState and self.conditionEditState.supportedRows)
                     and #self.conditionEditState.supportedRows or 0

    if targetIndex ~= nil then
        if targetIndex < 1 then targetIndex = 1 end
        if targetIndex > rowCount then targetIndex = rowCount end
    end

    if targetIndex == nil or rowCount == 0 then
        -- Empty list or no target: focus the container so Tier 2 shows.
        FocusManager:setFocus(self.filterConditionsList)
        Log:trace("reloadConditionsList: empty list / no target; focused filterConditionsList")
        return
    end

    -- The list's own selection drives Tier 3, so focus the list, not the cell.
    if self.filterConditionsList.setSelectedIndex ~= nil then
        self.filterConditionsList:setSelectedIndex(targetIndex, false, true)
    end
    FocusManager:setFocus(self.filterConditionsList)
    Log:trace("reloadConditionsList: focused filterConditionsList at index=%d (rowCount=%d)",
        targetIndex, rowCount)
end

--- Render the conditions list against the merged expression: re-partition the
--- children, stash them on conditionEditState, and update the banner.
---@param self table frame instance
---@param merged table merged filter record (overlay applied)
-- Assigned to the forward-declared local near renderEditor. Do NOT prefix with
-- `local` - that would shadow it and leave renderEditor calling a nil global.
renderConditionsForFilter = function(self, merged)
    self.conditionFieldOptionsCache = nil
    local supported, preserved = partitionChildren(merged.expression)

    -- Remote-update clobber check. Each successful update deep-clones the
    -- filter, so a new stored record has a distinct expression reference; an
    -- overlay snapshotted against an older one would destroy the new state.
    local pending = self.pendingChanges[merged.id]
    if pending ~= nil and pending.conditions ~= nil
       and pending._originExpressionRef ~= nil
       and pending._originExpressionRef ~= merged.expression then
        Log:warning("renderConditionsForFilter: id=%s detected storage divergence (remote update or external mutation); discarding %d pending condition(s) + preserved snapshot to avoid clobber",
            tostring(merged.id), #pending.conditions)
        pending.conditions = nil
        pending.preservedChildren = nil
        pending._originExpressionRef = nil
        -- Keep any name/animalType/op/usage edits pending still holds.
        pending = self.pendingChanges[merged.id]
    end

    -- Prefer the in-flight edited array over the partition from storage, so a
    -- re-render mid-edit does not lose pending rows. Preserved children are
    -- not editable, so they always come from storage.
    if pending ~= nil and pending.conditions ~= nil then
        supported = {}
        for i, row in ipairs(pending.conditions) do
            supported[i] = {
                field   = row.field,
                cmp     = row.cmp,
                value   = row.value,
                rawText = row.rawText,
            }
        end
    end

    self.conditionEditState = {
        supportedRows         = supported,
        preservedChildren     = preserved,
        lastRenderedFilterId  = merged.id,
        expressionRef         = merged.expression,  -- pinned for divergence detection
    }

    if self.filterConditionsBanner ~= nil then
        if #preserved > 0 then
            -- pcall: a translator-supplied placeholder mismatch would raise
            -- and abort the render mid-frame.
            local fmt = g_i18n:getText("rl_menu_filters_preserved_banner")
            local ok, rendered = pcall(string.format, fmt, #preserved)
            if not ok or rendered == nil then
                Log:warning("renderConditionsForFilter: banner string.format failed (fmt='%s' count=%d); falling back to plain count",
                    tostring(fmt), #preserved)
                rendered = tostring(#preserved)
            end
            self.filterConditionsBanner:setText(rendered)
            self.filterConditionsBanner:setVisible(true)
        else
            self.filterConditionsBanner:setVisible(false)
        end
    end

    if self.filterConditionsList ~= nil then
        self.filterConditionsList:reloadData()
    end

    Log:debug("renderConditionsForFilter: id=%s supported=%d preserved=%d",
        tostring(merged.id), #supported, #preserved)

    -- One-shot measure log.
    if not self.didMeasureConditionsList
       and self.filterConditionsList ~= nil
       and self.filterConditionsList.size ~= nil
       and self.filterConditionsList.size[1] ~= nil
       and self.filterConditionsList.size[2] ~= nil then
        Log:debug("RLMenuSettingsFrame: filterConditionsList measured: %.2fpx x %.2fpx",
            self.filterConditionsList.size[1] * 1920,
            self.filterConditionsList.size[2] * 1080)

        -- Log absPosition and absSize per editor sub-element, so a layout
        -- regression is diagnosable from the log alone.
        local function measure(name, el)
            if el == nil then
                Log:debug("MEASURE: %s = nil ref", name)
                return
            end
            local ap = el.absPosition
            local as = el.absSize
            local px = ap and ap[1] or nil
            local py = ap and ap[2] or nil
            local sw = as and as[1] or nil
            local sh = as and as[2] or nil
            Log:debug("MEASURE: %s absPos=(%.4f,%.4f) absSize=(%.4f,%.4f) px=(%.1f,%.1f) sizePx=(%.1f,%.1f) visible=%s",
                name,
                px or -1, py or -1, sw or -1, sh or -1,
                (px or 0) * 1920, (py or 0) * 1080,
                (sw or 0) * 1920, (sh or 0) * 1080,
                tostring(el.visible))
        end
        measure("filterEditorContainer", self.filterEditorContainer)
        measure("filterEditorLayout", self:getDescendantById("filterEditorLayout"))
        measure("filterConditionsBanner", self.filterConditionsBanner)
        measure("filterConditionsListContainer", self:getDescendantById("filterConditionsListContainer"))
        measure("filterConditionsList", self.filterConditionsList)
        measure("filterAddConditionButton", self.filterAddConditionButton)

        self.didMeasureConditionsList = true
    end
end

--- Lazy-init the per-id pending conditions array, so a row-level edit captures
--- the whole supported array in one shot.
---@param self table frame instance
---@param id string filter id
local function ensurePendingConditions(self, id)
    if self.pendingChanges[id] == nil then self.pendingChanges[id] = {} end
    if self.pendingChanges[id].conditions == nil then
        local snapshot = {}
        local rows = (self.conditionEditState and self.conditionEditState.supportedRows) or {}
        for i, row in ipairs(rows) do
            snapshot[i] = {
                field   = row.field,
                cmp     = row.cmp,
                value   = row.value,
                rawText = row.rawText,
                -- originSnapshot lets flush revert an EXISTING numeric row to
                -- its stored value on a mistype rather than delete it. New rows
                -- get none, so an invalid new row is excluded entirely.
                originSnapshot = { field = row.field, cmp = row.cmp, value = row.value },
            }
        end
        self.pendingChanges[id].conditions = snapshot
        -- Snapshot preservedChildren per id, so a retry after a rejected flush
        -- still has filter A's nodes once filter B has overwritten
        -- conditionEditState.
        if self.conditionEditState ~= nil
           and self.conditionEditState.lastRenderedFilterId == id
           and self.conditionEditState.preservedChildren ~= nil then
            local preservedSnap = {}
            for i, c in ipairs(self.conditionEditState.preservedChildren) do
                preservedSnap[i] = c
            end
            self.pendingChanges[id].preservedChildren = preservedSnap
            Log:trace("ensurePendingConditions: id=%s snapshotted preservedChildren=%d onto overlay",
                tostring(id), #preservedSnap)
        end
        -- Pin the expression reference the overlay was seeded against, so the
        -- next render can detect divergence by reference comparison.
        if self.conditionEditState ~= nil
           and self.conditionEditState.lastRenderedFilterId == id
           and self.conditionEditState.expressionRef ~= nil then
            self.pendingChanges[id]._originExpressionRef = self.conditionEditState.expressionRef
            Log:trace("ensurePendingConditions: id=%s pinned _originExpressionRef for divergence detection",
                tostring(id))
        end
    end
end

--- Sync one edit-state row into the pending overlay, writing through to the
--- supportedRows mirror for live read-back without a full re-render.
---@param self table frame instance
---@param id string filter id
---@param index number 1-based row index
---@param patch table partial fields to apply: {field?, cmp?, value?, rawText?}
---@param clearKeys table|nil keys to set to nil on the row and its mirror,
---   since Lua drops nil-valued keys from a table-literal patch
local function patchConditionRow(self, id, index, patch, clearKeys)
    ensurePendingConditions(self, id)
    local rows = self.pendingChanges[id].conditions
    if rows[index] == nil then
        Log:warning("patchConditionRow: index=%d out of range (%d row(s)); ignoring patch",
            index, #rows)
        return
    end
    for k, v in pairs(patch) do
        rows[index][k] = v
    end
    if clearKeys ~= nil then
        for _, k in ipairs(clearKeys) do
            rows[index][k] = nil
        end
    end
    -- Mirror into edit-state so the next populate pass reads live values.
    if self.conditionEditState and self.conditionEditState.supportedRows then
        self.conditionEditState.supportedRows[index] = self.conditionEditState.supportedRows[index] or {}
        for k, v in pairs(patch) do
            self.conditionEditState.supportedRows[index][k] = v
        end
        if clearKeys ~= nil then
            for _, k in ipairs(clearKeys) do
                self.conditionEditState.supportedRows[index][k] = nil
            end
        end
    end
    Log:trace("patchConditionRow: id=%s index=%d patch=%s clear=%s",
        tostring(id), index, table.concat({
            patch.field and "field" or nil,
            patch.cmp and "cmp" or nil,
            patch.value ~= nil and "value" or nil,
            patch.rawText and "rawText" or nil,
        }, ","),
        clearKeys ~= nil and table.concat(clearKeys, ",") or "-")
end

--- The filter's effective animalType from stored plus overlay; nil means ANY.
local function resolveEffectiveAnimalType(self, filterId)
    if g_rlFilterService == nil then return nil end
    local stored = g_rlFilterService:getById(filterId)
    if stored == nil then return nil end
    local animalType = stored.animalType
    local pendingForId = self.pendingChanges[filterId]
    if pendingForId ~= nil and pendingForId.animalType ~= nil then
        if pendingForId.animalType == RLMenuSettingsFrame.ANIMAL_TYPE_ANY then
            animalType = nil
        else
            animalType = pendingForId.animalType
        end
    end
    return animalType
end

--- Open the condition dialog: rowIndex nil adds, non-nil edits. The dialog
--- calls back into onConditionDialogClosed, with nil on Cancel.
function RLMenuSettingsFrame:openConditionEditDialog(rowIndex)
    if self.selectedFilterId == nil then
        Log:trace("RLMenuSettingsFrame:openConditionEditDialog: no selection, ignoring")
        return
    end

    local animalType = resolveEffectiveAnimalType(self, self.selectedFilterId)

    local initialCondition = nil
    if rowIndex ~= nil then
        local row = getConditionRowAt(self, rowIndex)
        if row == nil then
            Log:warning("RLMenuSettingsFrame:openConditionEditDialog: rowIndex=%d not in supportedRows; aborting",
                rowIndex)
            return
        end
        -- Refuse to open on an enum row whose domain is currently empty. The
        -- condition stays intact and round-trips through flush, so the user
        -- can re-author it after switching the filter's animalType.
        local field = RLFilterFieldCatalog.get(row.field)
        if field ~= nil and field.type == "enum" then
            local domain
            if row.field == "subType" and animalType == nil then
                domain = RLFilterFieldDisplay.getEnumDomainForUnscopedFilter("subType")
            else
                domain = RLFilterFieldDisplay.getEnumDomain(row.field, animalType)
            end
            if domain == nil or #domain == 0 then
                Log:warning("RLMenuSettingsFrame:openConditionEditDialog: refusing edit on rowIndex=%d field=%s (empty enum domain for animalType=%s)",
                    rowIndex, tostring(row.field), tostring(animalType))
                -- Surface the refusal on the conditions banner. The next
                -- render overwrites it, so the hint is transient by design.
                if self.filterConditionsBanner ~= nil and g_i18n ~= nil then
                    self.filterConditionsBanner:setText(
                        g_i18n:getText("rl_menu_filters_subtypeRequiresAnimalType"))
                    self.filterConditionsBanner:setVisible(true)
                end
                return
            end
        end
        initialCondition = {
            field   = row.field,
            cmp     = row.cmp,
            value   = row.value,
            rawText = row.rawText,
        }
    end

    Log:debug("RLMenuSettingsFrame:openConditionEditDialog: id=%s rowIndex=%s animalType=%s seedField=%s",
        tostring(self.selectedFilterId), tostring(rowIndex),
        tostring(animalType),
        initialCondition and tostring(initialCondition.field) or "nil(new)")

    RLFilterConditionDialog.show(
        RLMenuSettingsFrame.onConditionDialogClosed,  -- bound method
        self,                                          -- target
        initialCondition,
        rowIndex,
        animalType)
end

--- Dialog callback: nil newCondition means Cancel, and a nil rowIndex means
--- Add rather than Edit.
function RLMenuSettingsFrame:onConditionDialogClosed(newCondition, rowIndex)
    if newCondition == nil then
        Log:debug("RLMenuSettingsFrame:onConditionDialogClosed: cancelled (rowIndex=%s)",
            tostring(rowIndex))
        return
    end
    if self.selectedFilterId == nil then
        Log:warning("RLMenuSettingsFrame:onConditionDialogClosed: no selectedFilterId; dropping commit")
        return
    end

    if rowIndex == nil then
        self:addConditionAtSelection(newCondition)
        return
    end

    local patch = {
        field = newCondition.field,
        cmp   = newCondition.cmp,
        value = newCondition.value,
    }
    if newCondition.rawText ~= nil then
        patch.rawText = newCondition.rawText
    end
    -- Clear a rawText the row had but the dialog did not return, so a stale
    -- buffer cannot outlive the edit.
    local existing = getConditionRowAt(self, rowIndex)
    local clearKeys = nil
    if newCondition.rawText == nil and existing ~= nil and existing.rawText ~= nil then
        clearKeys = { "rawText" }
    end

    patchConditionRow(self, self.selectedFilterId, rowIndex, patch, clearKeys)
    Log:debug("RLMenuSettingsFrame:onConditionDialogClosed: edit committed rowIndex=%d field=%s cmp=%s value=%s",
        rowIndex, tostring(patch.field), tostring(patch.cmp), tostring(patch.value))
    reloadConditionsList(self, rowIndex)
end

--- Locate `node`'s parent group and its 1-based index in that group. The AST
--- root is a parameter because getById deep-clones, so re-fetching here would
--- break reference equality with the caller's node.
---@param expression table the AST root the caller wants searched
---@param node table the AST node to locate (a condition or group reference)
---@return table|nil parentGroup the group whose children list contains node
---@return number|nil indexInParent 1-based index of node in parentGroup.children
function RLMenuSettingsFrame:getParentGroupAndIndex(expression, node)
    if node == nil or expression == nil then return nil, nil end
    if expression.children == nil then return nil, nil end
    for i, child in ipairs(expression.children) do
        if child == node then
            Log:trace("RLMenuSettingsFrame:getParentGroupAndIndex: matched node at root index=%d", i)
            return expression, i
        end
    end
    Log:trace("RLMenuSettingsFrame:getParentGroupAndIndex: node not found in expression.children (#=%d)",
        #expression.children)
    return nil, nil
end

--- 1-based index at which a new row is inserted: k+1 for a selected row k,
--- otherwise append.
---@param rows table|nil array of existing condition rows
---@param selectedIndex number|nil 1-based focused row index, or nil
---@return number 1-based insertion index for table.insert(rows, idx, newCond)
function RLMenuSettingsFrame.computeInsertionIndex(rows, selectedIndex)
    local n = (rows ~= nil) and #rows or 0
    if selectedIndex == nil or selectedIndex <= 0 or selectedIndex > n then
        return n + 1
    end
    return selectedIndex + 1
end

--- Selection-aware insertion at the root: after the focused row, or appended
--- when nothing is selected.
function RLMenuSettingsFrame:addConditionAtSelection(newCond)
    if self.selectedFilterId == nil then return end

    ensurePendingConditions(self, self.selectedFilterId)
    local rows = self.pendingChanges[self.selectedFilterId].conditions

    -- getSelectedIndexInSection returns 0 or nil when nothing is selected.
    local selectedIndex = nil
    if self.filterConditionsList ~= nil
       and self.filterConditionsList.getSelectedIndexInSection ~= nil then
        local idx = self.filterConditionsList:getSelectedIndexInSection()
        if idx ~= nil and idx > 0 and idx <= #rows then
            selectedIndex = idx
        end
    end

    local insertAt = RLMenuSettingsFrame.computeInsertionIndex(rows, selectedIndex)
    table.insert(rows, insertAt, newCond)

    -- Mirror into edit-state.
    if self.conditionEditState and self.conditionEditState.supportedRows then
        table.insert(self.conditionEditState.supportedRows, insertAt, {
            field   = newCond.field,
            cmp     = newCond.cmp,
            value   = newCond.value,
            rawText = newCond.rawText,
        })
    end

    Log:debug("RLMenuSettingsFrame:addConditionAtSelection: id=%s inserted at index=%d (selected=%s) field=%s cmp=%s value=%s total=%d",
        tostring(self.selectedFilterId), insertAt, tostring(selectedIndex),
        tostring(newCond.field), tostring(newCond.cmp), tostring(newCond.value),
        #rows)

    reloadConditionsList(self, insertAt)
end

--- Group-editing stub: shows an InfoDialog so the user gets visible feedback
--- rather than a silent no-op.
function RLMenuSettingsFrame:addGroupAtSelection(_newGroup)
    Log:warning("RLMenuSettingsFrame:addGroupAtSelection: Add group: placeholder (group editing not implemented) - no state change")
    if InfoDialog ~= nil and InfoDialog.show ~= nil and g_i18n ~= nil then
        Log:debug("RLMenuSettingsFrame:addGroupAtSelection: showing not-yet-implemented InfoDialog")
        InfoDialog.show(g_i18n:getText("rl_menu_filters_add_group_not_implemented"))
    end
end

--- Action-bar Add condition: opens the dialog with no row index.
function RLMenuSettingsFrame:onAddConditionClicked()
    self:openConditionEditDialog(nil)
end

--- Action-bar Edit condition: opens the dialog on the focused row.
function RLMenuSettingsFrame:onEditConditionClicked()
    if self.selectedFilterId == nil then return end
    if self.filterConditionsList == nil
       or self.filterConditionsList.getSelectedIndexInSection == nil then
        Log:trace("RLMenuSettingsFrame:onEditConditionClicked: list / API unavailable")
        return
    end
    local idx = self.filterConditionsList:getSelectedIndexInSection()
    if idx == nil or idx == 0 then
        Log:trace("RLMenuSettingsFrame:onEditConditionClicked: no row selected; ignoring")
        return
    end
    self:openConditionEditDialog(idx)
end

--- Action-bar Delete condition: drops the focused row from the overlay and the
--- edit-state mirror, then reloads; focus clamps to the neighbouring row.
function RLMenuSettingsFrame:onDeleteConditionClicked()
    if self.selectedFilterId == nil then return end
    if self.filterConditionsList == nil
       or self.filterConditionsList.getSelectedIndexInSection == nil then
        Log:trace("RLMenuSettingsFrame:onDeleteConditionClicked: list / API unavailable")
        return
    end
    local idx = self.filterConditionsList:getSelectedIndexInSection()
    if idx == nil or idx == 0 then
        Log:trace("RLMenuSettingsFrame:onDeleteConditionClicked: no row selected; ignoring")
        return
    end

    ensurePendingConditions(self, self.selectedFilterId)
    local rows = self.pendingChanges[self.selectedFilterId].conditions
    if rows[idx] == nil then
        Log:warning("RLMenuSettingsFrame:onDeleteConditionClicked: idx=%d out of range (%d rows)",
            idx, #rows)
        return
    end
    table.remove(rows, idx)
    if self.conditionEditState and self.conditionEditState.supportedRows then
        table.remove(self.conditionEditState.supportedRows, idx)
    end
    Log:debug("RLMenuSettingsFrame:onDeleteConditionClicked: id=%s removed index=%d remaining=%d",
        tostring(self.selectedFilterId), idx, #rows)
    reloadConditionsList(self, idx)
end

--- Action-bar Add group: enabled but a no-op, pending group editing.
function RLMenuSettingsFrame:onAddGroupClicked()
    self:addGroupAtSelection(nil)
end

-- =============================================================================
-- Filter editor: flush
-- =============================================================================

--- Drain self.pendingChanges to service:update. Flush is the name-boundary
--- enforcement point: the widget callbacks stay permissive mid-typing, so an
--- empty trimmed name reverts to the stored one here.
function RLMenuSettingsFrame:flushPendingChanges()
    local idsIn = 0
    for _ in pairs(self.pendingChanges) do idsIn = idsIn + 1 end
    if idsIn == 0 then
        Log:debug("RLMenuSettingsFrame:flushPendingChanges: count=0")
        return
    end
    if g_rlFilterService == nil then
        Log:warning("RLMenuSettingsFrame:flushPendingChanges: g_rlFilterService is nil; %d pending change(s) dropped",
            idsIn)
        self.pendingChanges = {}
        return
    end

    local updated, skipped = 0, 0
    local toClear = {}
    -- Snapshot ids first, so the per-id helper can mutate self.pendingChanges
    -- without iterating while mutating.
    local ids = {}
    for id in pairs(self.pendingChanges) do table.insert(ids, id) end
    for _, id in ipairs(ids) do
        local result = self:flushPendingChangesForId(id)
        if result == "updated" then
            updated = updated + 1
            table.insert(toClear, id)
        elseif result == "skipped" then
            skipped = skipped + 1
            table.insert(toClear, id)
        end
        -- "rejected": leave the entry in self.pendingChanges for retry.
    end
    for _, id in ipairs(toClear) do
        self.pendingChanges[id] = nil
    end
    Log:debug("RLMenuSettingsFrame:flushPendingChanges: count=%d updated=%d skipped=%d retained=%d",
        idsIn, updated, skipped, idsIn - updated - skipped)
end

--- Flush ONE id's overlay, so a rejected edit on one filter cannot drop edits
--- on another. "updated" and "skipped" let the caller clear the entry;
--- "rejected" means the caller MUST keep it for the next pass to retry.
---@param id string filter id
---@return string outcome code
function RLMenuSettingsFrame:flushPendingChangesForId(id)
    if id == nil then
        Log:warning("RLMenuSettingsFrame:flushPendingChangesForId: nil id; treating as skipped")
        return "skipped"
    end
    if g_rlFilterService == nil then
        Log:warning("RLMenuSettingsFrame:flushPendingChangesForId: g_rlFilterService is nil; treating id=%s as skipped",
            tostring(id))
        return "skipped"
    end
    local overlay = self.pendingChanges[id]
    if overlay == nil then
        Log:trace("RLMenuSettingsFrame:flushPendingChangesForId: no pending overlay for id=%s",
            tostring(id))
        return "skipped"
    end

    local stored = g_rlFilterService:getById(id)
    if stored == nil then
        Log:debug("RLMenuSettingsFrame:flushPendingChangesForId: skipped orphan id=%s",
            tostring(id))
        return "skipped"
    end

    local merged = overlayPending(stored, overlay)
    -- Flush-time name boundary enforcement.
    local trimmed = (merged.name or ""):match("^%s*(.-)%s*$")
    if trimmed == "" then
        merged.name = stored.name
        Log:warning("RLMenuSettingsFrame:flushPendingChangesForId: empty/whitespace name for id=%s reverted to stored '%s'",
            tostring(id), tostring(stored.name))
    else
        merged.name = trimmed
    end

    -- Rebuild children as validSupported ++ preserved. On a number parse
    -- failure an EXISTING row reverts to its originSnapshot, so the user loses
    -- the edit rather than the condition; a NEW row is excluded outright.
    if overlay.conditions ~= nil then
        local validSupported = {}
        for _, row in ipairs(overlay.conditions) do
            local field = RLFilterFieldCatalog.get(row.field)
            local include = true
            local outField, outCmp, outValue = row.field, row.cmp, row.value
            if field ~= nil and field.type == "number" and row.rawText ~= nil then
                local parsed = tonumber(row.rawText)
                -- tonumber accepts "inf" and overflowing exponents, which no
                -- catalog field means; treat those as a parse failure.
                local isPathological = parsed ~= nil and (
                    parsed ~= parsed                 -- NaN
                    or parsed == math.huge
                    or parsed == -math.huge
                )
                if parsed == nil or isPathological then
                    if row.originSnapshot ~= nil then
                        outField = row.originSnapshot.field
                        outCmp   = row.originSnapshot.cmp
                        outValue = row.originSnapshot.value
                        Log:warning("RLMenuSettingsFrame:flushPendingChangesForId: id=%s row field=%s rejected literal '%s' (not numeric); reverting to stored value=%s",
                            tostring(id), tostring(row.field), tostring(row.rawText), tostring(outValue))
                    else
                        include = false
                        Log:warning("RLMenuSettingsFrame:flushPendingChangesForId: id=%s NEW row field=%s rejected literal '%s' (not numeric); excluding (no stored counterpart)",
                            tostring(id), tostring(row.field), tostring(row.rawText))
                    end
                else
                    outValue = parsed
                end
            end
            if include then
                table.insert(validSupported, {
                    field = outField,
                    cmp   = outCmp,
                    value = outValue,
                })
            end
        end

        -- Prefer the per-id snapshot: it survives selection switches, while
        -- conditionEditState is clobbered by every renderEditor and so is
        -- wrong for any id other than the one currently rendered.
        local preserved = overlay.preservedChildren
                          or (self.conditionEditState
                              and self.conditionEditState.lastRenderedFilterId == id
                              and self.conditionEditState.preservedChildren)
                          or {}
        local rebuiltChildren = {}
        for i, c in ipairs(validSupported) do rebuiltChildren[i] = c end
        local baseLen = #validSupported
        for i, c in ipairs(preserved) do rebuiltChildren[baseLen + i] = c end

        -- Determine the root op: overlay.op wins, else keep the stored op.
        local rootOp = (merged.expression and merged.expression.op) or "AND"
        merged.expression = { op = rootOp, children = rebuiltChildren }
        Log:debug("RLMenuSettingsFrame:flushPendingChangesForId: id=%s rebuilt children: supported=%d preserved=%d",
            tostring(id), #validSupported, #preserved)
    end

    -- Phantom-rewrite guard: without it a no-op overlay still emits a
    -- byte-identical Update, fanning out to every consumer frame on every
    -- client. "skipped" clears the entry rather than retaining it.
    if deepEqualFilter(merged, stored) then
        Log:debug("RLMenuSettingsFrame:flushPendingChangesForId: id=%s overlay matches stored; skipping wire update",
            tostring(id))
        return "skipped"
    end

    local result = g_rlFilterService:update(id, merged)
    if result == nil then
        Log:warning("RLMenuSettingsFrame:flushPendingChangesForId: service:update returned nil for id=%s (validation rejection?); retaining pendingChanges for retry",
            tostring(id))
        return "rejected"
    end
    Log:debug("RLMenuSettingsFrame:flushPendingChangesForId: applied id=%s name='%s' animalType=%s op=%s usage=%s children=%d",
        tostring(id), tostring(merged.name),
        tostring(merged.animalType),
        tostring(merged.expression and merged.expression.op),
        tostring(merged.usage),
        (merged.expression and merged.expression.children) and #merged.expression.children or 0)
    return "updated"
end

-- =============================================================================
-- Filter editor: Duplicate
-- =============================================================================

--- Compute a non-colliding duplicate name. Collision detection resolves names
--- through the pending overlay, so a rename in flight on another row counts.
--- @param baseName string Source filter's merged name
--- @return string
function RLMenuSettingsFrame:computeDuplicateName(baseName)
    local base = baseName or ""
    local suffixFirst = g_i18n:getText("rl_menu_filters_duplicate_suffix")
    local suffixNFmt  = g_i18n:getText("rl_menu_filters_duplicate_suffix_n")
    local first = base .. suffixFirst

    -- Lift the %d placeholder to a sentinel byte before escaping, because `%`
    -- is itself Lua's pattern escape char, then restore it as a capture.
    local function escapePattern(s)
        return (s:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1"))
    end
    local placeholder = "\1"
    local templatePat = escapePattern((suffixNFmt:gsub("%%d", placeholder)))
        :gsub(placeholder, "(%%d+)")
    local countPattern = "^" .. escapePattern(base) .. templatePat .. "$"

    -- Track the MAX N seen, not the count: after deletes leave sparse copies,
    -- a count would collide. The bare suffix form counts as N=1, and the
    -- source row's own name contributes nothing.
    local maxN = 0
    for _, row in ipairs(self.rows) do
        local pending = self.pendingChanges[row.id]
        local name = (pending and pending.name) or row.name or ""
        if name == first then
            if maxN < 1 then maxN = 1 end
        else
            local capture = name:match(countPattern)
            if capture ~= nil then
                local num = tonumber(capture)
                if num ~= nil and num > maxN then
                    maxN = num
                end
            end
        end
    end
    local result
    if maxN == 0 then
        result = first
    else
        result = base .. suffixNFmt:format(maxN + 1)
    end
    Log:trace("RLMenuSettingsFrame:computeDuplicateName: base='%s' maxN=%d result='%s'",
        base, maxN, result)
    return result
end

--- Footer Duplicate handler: clones the selected filter overlay-merged, names
--- it without collision, and creates it, then selects the new row.
function RLMenuSettingsFrame:onClickDuplicate()
    if self.selectedFilterId == nil then
        Log:trace("RLMenuSettingsFrame:onClickDuplicate: no selection, aborting")
        return
    end
    if not self:hasCreatePermission() then
        Log:trace("RLMenuSettingsFrame:onClickDuplicate: no tradeAnimals permission, aborting")
        return
    end
    if self.farmId == nil or self.farmId == 0 then
        Log:trace("RLMenuSettingsFrame:onClickDuplicate: no farm, aborting")
        return
    end
    if g_rlFilterService == nil then
        Log:warning("RLMenuSettingsFrame:onClickDuplicate: g_rlFilterService is nil; aborting")
        return
    end

    local stored = g_rlFilterService:getById(self.selectedFilterId)
    if stored == nil then
        Log:warning("RLMenuSettingsFrame:onClickDuplicate: getById returned nil for id=%s; aborting",
            tostring(self.selectedFilterId))
        return
    end

    local merged = overlayPending(stored, self.pendingChanges[self.selectedFilterId])
    local dupName = self:computeDuplicateName(merged.name)

    -- Carry the SOURCE filter's scope, not self.farmId: that would narrow a
    -- global filter (farmId == nil) down to the active farm.
    local cloned = RLFilterService._cloneFilter(merged)
    local newFilter = g_rlFilterService:create({
        name       = dupName,
        animalType = merged.animalType,
        farmId     = merged.farmId,
        usage      = merged.usage,
        expression = cloned.expression,
    })
    if newFilter == nil then
        Log:warning("RLMenuSettingsFrame:onClickDuplicate: service rejected create (nil return) for source id=%s",
            tostring(self.selectedFilterId))
        return
    end

    Log:debug("RLMenuSettingsFrame:onClickDuplicate: source=%s name='%s' farmId=%s usage=%s -> new id=%s",
        tostring(self.selectedFilterId), tostring(dupName), tostring(merged.farmId),
        tostring(merged.usage), tostring(newFilter.id))
    self.selectedFilterId = newFilter.id
    self:refreshData()
end

-- =============================================================================
-- Filter editor: Delete
-- =============================================================================

--- Footer Delete handler: opens a YesNoDialog naming the filter. Nothing
--- mutates until the user confirms.
function RLMenuSettingsFrame:onClickDelete()
    if self.selectedFilterId == nil then
        Log:trace("RLMenuSettingsFrame:onClickDelete: no selection, aborting")
        return
    end
    if not self:hasCreatePermission() then
        Log:trace("RLMenuSettingsFrame:onClickDelete: no tradeAnimals permission, aborting")
        return
    end
    if self.farmId == nil or self.farmId == 0 then
        Log:trace("RLMenuSettingsFrame:onClickDelete: no farm, aborting")
        return
    end
    if g_rlFilterService == nil then
        Log:warning("RLMenuSettingsFrame:onClickDelete: g_rlFilterService is nil; aborting")
        return
    end

    if g_gui:getIsDialogVisible() then
        Log:trace("RLMenuSettingsFrame:onClickDelete: dialog already open, ignoring re-entry")
        return
    end

    local stored = g_rlFilterService:getById(self.selectedFilterId)
    if stored == nil then
        Log:warning("RLMenuSettingsFrame:onClickDelete: getById returned nil for id=%s; aborting",
            tostring(self.selectedFilterId))
        return
    end

    local confirmText = string.format(
        g_i18n:getText("rl_menu_filters_delete_confirm_text"),
        tostring(stored.name or ""))

    Log:debug("RLMenuSettingsFrame:onClickDelete: opening YesNoDialog for id=%s name='%s'",
        tostring(stored.id), tostring(stored.name))

    -- YesNoDialog passes (target, yesValue, callbackArgs), and the colon-bound
    -- `self` absorbs the target, so the callback receives (yes, id).
    YesNoDialog.show(
        self.onDeleteConfirmed,
        self,
        confirmText,
        g_i18n:getText("ui_attention"),
        nil, nil, nil, nil, nil,
        stored.id
    )
end

--- Delete confirmation callback. service:delete runs FIRST and local cleanup
--- only follows a true return, so a rejected delete keeps the pending edits.
--- @param yes boolean True when the user clicked Yes
--- @param id string The filter id captured at click time
function RLMenuSettingsFrame:onDeleteConfirmed(yes, id)
    Log:trace("RLMenuSettingsFrame:onDeleteConfirmed: yes=%s id=%s", tostring(yes), tostring(id))
    if not yes then return end
    if g_rlFilterService == nil then
        Log:warning("RLMenuSettingsFrame:onDeleteConfirmed: g_rlFilterService is nil; aborting")
        return
    end
    local ok = g_rlFilterService:delete(id)
    if ok then
        self.pendingChanges[id] = nil
        if self.selectedFilterId == id then
            self.selectedFilterId = nil
        end
        Log:debug("RLMenuSettingsFrame:onDeleteConfirmed: deleted id=%s", tostring(id))
        self:refreshData()
    else
        Log:warning("RLMenuSettingsFrame:onDeleteConfirmed: service:delete returned false for id=%s; preserving pending edits + selection (stale id or race with another client)",
            tostring(id))
    end
end

--- SmoothList row-change delegate, shared by both lists and dispatched by list
--- reference. The outgoing filter is flushed first, but the advance happens
--- regardless: a rejected entry waits in pendingChanges for the close pass.
--- @param list table The SmoothList instance asking
--- @param _section number Section index (single-section, ignored)
--- @param index number 1-based row index
function RLMenuSettingsFrame:onListSelectionChanged(list, _section, index)
    -- Conditions-list selection drives the Tier 2 / Tier 3 transition on the
    -- action bar; everything below this is filtersList-only.
    if list == self.filterConditionsList then
        Log:trace("RLMenuSettingsFrame:onListSelectionChanged: conditions list selection (index=%s) -> refreshing action bar",
            tostring(index))
        self:updateButtonVisibility()
        return
    end
    if list ~= self.filtersList then return end
    if index == nil then return end

    -- Suppress during reconciliation: the id captured on those paths is the
    -- post-clamp row, not the user's intent, and the caller knows the right one.
    if self.isReconciling then
        Log:trace("RLMenuSettingsFrame:onListSelectionChanged: suppressed during reconcile (index=%s)",
            tostring(index))
        return
    end

    -- Autoflush the outgoing filter; the advance is unconditional so a
    -- rejected flush cannot strand the user on the dirty filter.
    local previousId = self.selectedFilterId
    if previousId ~= nil and self.pendingChanges[previousId] ~= nil then
        local outcome = self:flushPendingChangesForId(previousId)
        if outcome == "updated" or outcome == "skipped" then
            self.pendingChanges[previousId] = nil
        end
        Log:debug("RLMenuSettingsFrame:onListSelectionChanged: autoflush previousId=%s outcome=%s",
            tostring(previousId), tostring(outcome))
    end

    local row = self.rows[index]
    if row == nil then
        self.selectedFilterId = nil
        Log:debug("RLMenuSettingsFrame:onListSelectionChanged: index=%s out of range, cleared",
            tostring(index))
        -- Rerender and rebuild the footer, or the right pane keeps the old
        -- filter's content and the destructive buttons stay live.
        self:renderEditor()
        self:updateButtonVisibility()
        return
    end

    self.selectedFilterId = row.id
    Log:debug("RLMenuSettingsFrame:onListSelectionChanged: index=%d id=%s",
        index, tostring(row.id))

    self:renderEditor()
    self:updateButtonVisibility()
end

-- =============================================================================
-- SmoothList data source protocol
--
-- Deliberately NOT logged: these are called at draw frequency and tracing them
-- would swamp the log.
-- =============================================================================

--- How many items the list should render, dispatched by list reference.
--- @param list table
--- @param _section number Ignored
--- @return number
function RLMenuSettingsFrame:getNumberOfItemsInSection(list, _section)
    if list == self.filtersList then
        return #self.rows
    elseif list == self.filterConditionsList then
        if self.conditionEditState == nil
           or self.conditionEditState.supportedRows == nil then
            return 0
        end
        return #self.conditionEditState.supportedRows
    end
    return 0
end

--- Populate one data cell from the row at the given index, dispatched by list.
--- @param list table
--- @param _section number Ignored
--- @param index number 1-based row index
--- @param cell table The ListItem cell to populate
function RLMenuSettingsFrame:populateCellForItemInSection(list, _section, index, cell)
    if list == self.filtersList then
        local row = self.rows[index]
        if row == nil then return end

        -- Display through the overlay so a live edit shows at once, while the
        -- sort key stays row.name so the row does not move mid-edit.
        local pending = self.pendingChanges[row.id]
        local displayName = (pending and pending.name) or row.name or ""

        local nameCell = cell:getAttribute("filterName")
        if nameCell ~= nil then
            nameCell:setText(displayName)
        end

        -- Two cells is enough to derive both inter-row pitch and per-cell
        -- geometry from the log.
        local idx = self.didMeasureFilterCellCount or 0
        if idx < 2 then
            self.didMeasureFilterCellCount = idx + 1
            local cellAX = (cell.absPosition and cell.absPosition[1] or 0) * g_referenceScreenWidth
            local cellAY = (cell.absPosition and cell.absPosition[2] or 0) * g_referenceScreenHeight
            local cellW = (cell.size and cell.size[1] or 0) * g_referenceScreenWidth
            local cellH = (cell.size and cell.size[2] or 0) * g_referenceScreenHeight
            local titleAX = (nameCell and nameCell.absPosition and nameCell.absPosition[1] or 0) * g_referenceScreenWidth
            local titleAY = (nameCell and nameCell.absPosition and nameCell.absPosition[2] or 0) * g_referenceScreenHeight
            local titleW = (nameCell and nameCell.size and nameCell.size[1] or 0) * g_referenceScreenWidth
            local titleH = (nameCell and nameCell.size and nameCell.size[2] or 0) * g_referenceScreenHeight
            local wrap = nameCell and nameCell.textWrapWidth or nil
            local maxw = nameCell and nameCell.maxInputTextWidth or nil
            local lm   = nameCell and nameCell.textLayoutMode or nil
            local twa  = nameCell and nameCell.textWrapAtPunctuation or nil
            Log:debug("RLMenuSettingsFrame:populateCellForItemInSection: filterListCell[%d] cell.absPos=(%.1f,%.1f) cell=%.1fx%.1f title.absPos=(%.1f,%.1f) title=%.1fx%.1f textWrapWidth=%s maxInputTextWidth=%s textLayoutMode=%s textWrapAtPunct=%s name=%q",
                idx, cellAX, cellAY, cellW, cellH, titleAX, titleAY, titleW, titleH,
                tostring(wrap), tostring(maxw), tostring(lm), tostring(twa), displayName)
        end
        return
    end

    if list ~= self.filterConditionsList then return end

    -- A row is one read-only Text widget; edits route through the dialog.
    local row = getConditionRowAt(self, index)
    if row == nil then return end

    local field = RLFilterFieldCatalog.get(row.field)
    if field == nil then
        Log:warning("populateCell: row index=%d carries unknown field '%s'; skipping",
            index, tostring(row.field))
        return
    end

    local conditionText = cell:getAttribute("conditionText")
    if conditionText == nil then
        Log:warning("populateCell: row index=%d - conditionText widget missing from cell template (XML drift?)",
            index)
        return
    end

    local displayText = formatConditionDisplay(self, row, field)

    -- Pixel-accurate truncation. String values truncate in the MIDDLE, so two
    -- long values differing only at the suffix stay distinguishable. textSize
    -- is read live from the widget so a profile change propagates.
    local textSize = conditionText.textSize
    local budgetPx = nil
    if cell ~= nil and cell.size ~= nil and cell.size[1] ~= nil
       and g_referenceScreenWidth ~= nil then
        local rowWidthPx = cell.size[1] * g_referenceScreenWidth
        local leftOffsetPx = 20  -- matches the XML position="20px ..."
        budgetPx = rowWidthPx - leftOffsetPx - 8 -- 8px right padding so the
                                                 -- truncation sentinel isn't
                                                 -- flush against the row edge
    end
    if textSize ~= nil and budgetPx ~= nil and budgetPx > 0 then
        displayText = RLFilterFieldDisplay.limitConditionRowText(
            displayText, textSize, budgetPx, field.type)
    end

    conditionText:setText(displayText)

    -- Depth-aware indent, inert while every row is at depth 0. setPosition
    -- takes NORMALIZED coordinates, and GuiUtils.getNormalizedXValue is
    -- string-aware only, so the pixel offset is converted here explicitly.
    local depth = 0
    if self.conditionRowDepths ~= nil and self.conditionRowDepths[index] ~= nil then
        depth = self.conditionRowDepths[index]
    end
    if depth > 0 and conditionText.setPosition ~= nil
       and g_referenceScreenWidth ~= nil then
        local leftOffsetPx = 20 + depth * 20
        local scaleX = g_aspectScaleX or 1
        local normalizedX = (leftOffsetPx / g_referenceScreenWidth) * scaleX
        -- Preserve the Y offset from XML load; it is already normalized.
        local normalizedY = (conditionText.position and conditionText.position[2]) or 0
        conditionText:setPosition(normalizedX, normalizedY)
    end

    Log:trace("populateCell: conditions row index=%d field=%s cmp=%s value=%s depth=%d text='%s'",
        index, tostring(row.field), tostring(row.cmp), tostring(row.value),
        depth, displayText)
end

-- =============================================================================
-- General subtab: populate, refresh, cascade, click dispatch
-- =============================================================================

--- Build the option-text array a state-row widget needs, from the setting's own
--- builder, its binary type, its value type, or its l10n keys.
--- @param name string Setting key in RLSettings.SETTINGS
--- @param setting table The setting entry
--- @return table The texts array indexed by state
local function buildSettingTexts(name, setting)
    if setting.getTexts ~= nil then
        return setting.getTexts()
    end

    local texts = {}
    local prefix = "rl_settings_" .. name .. "_"

    if setting.binaryType == "offOn" then
        texts[1] = g_i18n:getText("rl_settings_off")
        texts[2] = g_i18n:getText("rl_settings_on")
    else
        for i, value in pairs(setting.values) do
            if setting.valueType == "int" then
                texts[i] = tostring(value)
            elseif setting.valueType == "float" then
                texts[i] = string.format("%.0f%%", value * 100)
            else
                texts[i] = g_i18n:getText(prefix .. "texts_" .. i)
            end
        end
    end

    return texts
end

--- One-shot per-clone wiring of the General subtab: widget lookup, option-text
--- arrays, and the element and tooltip registries. The XML onClick attributes
--- already bind the handlers, so no manual binding happens here.
function RLMenuSettingsFrame:populateGeneralSubtab()
    Log:debug("RLMenuSettingsFrame:populateGeneralSubtab: enter")

    local layout = self:getDescendantById("generalSettingsLayout")
    if layout == nil then
        Log:error("RLMenuSettingsFrame:populateGeneralSubtab: generalSettingsLayout missing from XML; General subtab will be empty")
        return
    end

    local count = 0
    for name, setting in pairs(RLSettings.SETTINGS) do
        local widget = self:getDescendantById("rlmenuSetting_" .. name)
        if widget == nil then
            Log:warning("RLMenuSettingsFrame:populateGeneralSubtab: widget rlmenuSetting_%s missing", name)
        else
            self.controls[name] = widget

            local tooltip = widget:getDescendantByName("tooltip")
            if tooltip == nil then
                Log:trace("RLMenuSettingsFrame:populateGeneralSubtab: '%s' has no tooltip child", name)
            else
                self.tooltips[name] = tooltip
            end

            -- Action rows keep the static text XML already set.
            if not setting.ignore then
                widget:setTexts(buildSettingTexts(name, setting))
                Log:trace("RLMenuSettingsFrame:populateGeneralSubtab: bound state row '%s'", name)
            else
                Log:trace("RLMenuSettingsFrame:populateGeneralSubtab: bound action row '%s'", name)
            end

            -- Write the tooltip once here so action rows, which
            -- refreshGeneralSubtab skips, get one too.
            if tooltip ~= nil then
                local tooltipKey
                if setting.dynamicTooltip then
                    local seedState = setting.state or setting.default
                    tooltipKey = "rl_settings_" .. name .. "_tooltip_" .. seedState
                else
                    tooltipKey = "rl_settings_" .. name .. "_tooltip"
                end
                tooltip:setText(g_i18n:getText(tooltipKey))
            end

            count = count + 1
        end
    end

    -- The totals make a partial bind from XML drift loud at a glance.
    local expected = 0
    for _ in pairs(RLSettings.SETTINGS) do expected = expected + 1 end
    if count ~= expected then
        Log:warning("RLMenuSettingsFrame:populateGeneralSubtab: bound %d/%d rows; XML/SETTINGS drift?", count, expected)
    else
        Log:debug("RLMenuSettingsFrame:populateGeneralSubtab: bound %d/%d row(s)", count, expected)
    end
end

--- Push RLSettings state into the widgets, refresh their tooltips, and re-run
--- the dependency cascade. setState passes forceEvent=false, so the
--- programmatic push cannot re-enter onClickGeneralSetting.
function RLMenuSettingsFrame:refreshGeneralSubtab()
    Log:debug("RLMenuSettingsFrame:refreshGeneralSubtab: enter")

    for name, setting in pairs(RLSettings.SETTINGS) do
        local widget = self.controls[name]
        if widget ~= nil and not setting.ignore then
            local state = setting.state or setting.default
            widget:setState(state, false)

            local tooltip = self.tooltips[name]
            if tooltip ~= nil then
                local key
                if setting.dynamicTooltip then
                    key = "rl_settings_" .. name .. "_tooltip_" .. state
                else
                    key = "rl_settings_" .. name .. "_tooltip"
                end
                tooltip:setText(g_i18n:getText(key))
            end
        end
    end

    self:updateReadonlyState()
end

--- Admin gate, then dependancy cascade: adminOnly disables a row for a non-admin, else a child follows its parent.
function RLMenuSettingsFrame:updateReadonlyState()
    local isAdmin = (g_server ~= nil) or (g_currentMission ~= nil and g_currentMission.isMasterUser == true)
    Log:trace("RLMenuSettingsFrame:updateReadonlyState: isAdmin=%s", tostring(isAdmin))

    for name, setting in pairs(RLSettings.SETTINGS) do
        local widget = self.controls[name]
        if widget ~= nil then
            local disabled = false

            if setting.adminOnly and not isAdmin then
                disabled = true
            elseif setting.dependancy ~= nil then
                local parent = RLSettings.SETTINGS[setting.dependancy.name]
                if parent ~= nil then
                    local parentState = parent.state or parent.default
                    disabled = (parentState ~= setting.dependancy.state)
                end
            end

            widget:setDisabled(disabled)
            Log:trace("RLMenuSettingsFrame:updateReadonlyState: '%s' disabled=%s", name, tostring(disabled))
        end
    end
end

--- Refresh the General subtab when open, so an MP-synced state change shows
--- without a frame reopen.
function RLMenuSettingsFrame:refreshIfGeneralOpen()
    if not self.isFrameOpen then
        Log:trace("RLMenuSettingsFrame:refreshIfGeneralOpen: frame closed, skipping")
        return
    end
    Log:debug("RLMenuSettingsFrame:refreshIfGeneralOpen: frame open, refreshing")
    self:refreshGeneralSubtab()
end

--- onClick handler for state rows: delegate to RLSettings.applyChange, the
--- single write path, then refresh. A Button raises with only (target, widget),
--- so the `widget == nil` fallback keeps a cross-wire resolving to a widget.
--- @param state number 1-based new state from the widget post-click
--- @param widget table The widget that was clicked
function RLMenuSettingsFrame:onClickGeneralSetting(state, widget)
    if widget == nil then widget = state end
    -- Type-check after the shuffle: when only a numeric state arrived, the
    -- shuffle leaves `widget` a number and `widget.id` would crash.
    if type(widget) ~= "table" or widget.id == nil then return end

    local name = widget.id:match("^rlmenuSetting_(.+)$")
    if name == nil then
        Log:warning("RLMenuSettingsFrame:onClickGeneralSetting: id '%s' did not match rlmenuSetting_<name>", tostring(widget.id))
        return
    end

    local setting = RLSettings.SETTINGS[name]
    if setting == nil then
        Log:warning("RLMenuSettingsFrame:onClickGeneralSetting: unknown setting '%s'", name)
        return
    end
    if setting.ignore then
        Log:warning("RLMenuSettingsFrame:onClickGeneralSetting: '%s' is an action row; misrouted click", name)
        return
    end

    -- The widget already advanced its own state on click, so read it back.
    local newState = widget:getState()
    Log:debug("RLMenuSettingsFrame:onClickGeneralSetting: name='%s' newState=%d", name, newState)

    RLSettings.applyChange(name, newState)

    -- Sync off this client: the server validates the sender, persists and
    -- relays. Without it the change stays local and reverts on save/reload.
    Log:debug("RLMenuSettingsFrame:onClickGeneralSetting: broadcasting '%s' via RL_BroadcastSettingsEvent.sendEvent", name)
    RL_BroadcastSettingsEvent.sendEvent(name)

    self:refreshGeneralSubtab()
end

--- onClick handler for action rows: invoke the setting's callback with no
--- args. Fire-and-forget - no state mutation and no cascade refresh.
--- @param button table The Button widget that was clicked
function RLMenuSettingsFrame:onClickGeneralAction(button)
    if button == nil or button.id == nil then return end

    local name = button.id:match("^rlmenuSetting_(.+)$")
    if name == nil then
        Log:warning("RLMenuSettingsFrame:onClickGeneralAction: id '%s' did not match rlmenuSetting_<name>", tostring(button.id))
        return
    end

    local setting = RLSettings.SETTINGS[name]
    if setting == nil then
        Log:warning("RLMenuSettingsFrame:onClickGeneralAction: unknown setting '%s'", name)
        return
    end
    if not setting.ignore then
        Log:warning("RLMenuSettingsFrame:onClickGeneralAction: '%s' is a state row; misrouted click", name)
        return
    end
    if setting.callback == nil then
        Log:warning("RLMenuSettingsFrame:onClickGeneralAction: '%s' has no callback registered", name)
        return
    end

    Log:debug("RLMenuSettingsFrame:onClickGeneralAction: invoking callback for '%s'", name)
    setting.callback()
end
