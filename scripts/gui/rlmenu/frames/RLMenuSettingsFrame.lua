--[[
    RLMenuSettingsFrame.lua
    RL Tabbed Menu Settings tab.

    Horizontal subcategory tab bar with two content panes:
      [General] - placeholder for future non-filter settings.
      [Filters] - single-section SmoothList of saved filters backed by
                  g_rlFilterService:listAvailable, a footer New filter
                  button, and a branched empty-state.

    Tab highlight, pager texts, and focus are seeded in
    initializeSubCategoryPages() called from onFrameOpen on every open,
    so closures stay bound to the live frame instance across opens.

    Selection is id-authoritative: self.selectedFilterId is the source of
    truth, the list's selectedIndex is derived from it on every reload.
    This keeps the cached id consistent with the highlighted row under
    the service's undefined-pairs-order reloads.
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

--- Sentinel marking an explicit "clear to Any" in the pendingChanges overlay
--- for the animalType field. Lua removes nil values from tables, so
--- pendingChanges[id].animalType = nil is indistinguishable from "no pending
--- change". A unique-table marker lets overlayPending distinguish three states:
---   (a) no pending change          (overlay.animalType == nil)
---   (b) pending change to concrete (overlay.animalType is an integer typeIndex)
---   (c) pending change to Any      (overlay.animalType == ANIMAL_TYPE_ANY)
--- Flush converts the sentinel back to nil before service:update so storage
--- + wire never see it. Mirrors Fresh's MAXBENEFIT_CLEAR pattern.
RLMenuSettingsFrame.ANIMAL_TYPE_ANY = {}

--- Construct a new RLMenuSettingsFrame instance.
--- Called once by setupGui() during mod load.
--- @return table self The new frame instance
function RLMenuSettingsFrame.new()
    local self = RLMenuSettingsFrame:superClass().new(nil, RLMenuSettingsFrame_mt)
    self.name = "RLMenuSettingsFrame"

    -- Filter list state. Rows are cloned snapshots from the service so
    -- frame-side mutation stays contract-safe; selection is id-authoritative
    -- (selectedFilterId is the source of truth, list.selectedIndex is
    -- derived on every reload via resolveSelectionById).
    self.rows              = {}
    self.farmId            = nil
    self.isFrameOpen       = false
    self.selectedFilterId  = nil

    -- Guard flag: true while refreshData reconciles selection after a
    -- reload. SmoothList:reloadData fires our onListSelectionChanged
    -- delegate synchronously during its internal clamp. Without this
    -- flag, that callback would overwrite self.selectedFilterId with
    -- whatever row lands at the post-clamp index BEFORE resolveSelectionById
    -- runs, silently breaking the id-authoritative contract.
    -- onListSelectionChanged checks this flag and early-returns.
    self.isReconciling     = false

    -- One-shot flag for the first-visibility measure log on [Filters]. Reset
    -- per frame-open cycle by living on the instance (frames are cloned per
    -- paging lifecycle; see RLMenu:setupMenuPages).
    self.didMeasureFiltersPane = false

    -- Capped at 2 in populateCellForItemInSection: enough to compute inter-row
    -- pitch + per-cell geometry from the measurement log. Reset in onFrameOpen.
    self.didMeasureFilterCellCount = 0

    -- Editor pane measure log flag. Once-per-process (NOT once-per-open):
    -- RLMenuSettingsFrame.new() runs once at setupGui() time and the clone is
    -- reused across every menu open. Pane geometry doesn't change after first
    -- measurement so measuring once is sufficient.
    self.didMeasureEditorPane = false

    -- Conditions list one-shot measure flag. Same once-per-process
    -- semantics as didMeasureEditorPane above. Fires from renderEditor when
    -- the SmoothList becomes visible AND its size axes have settled.
    self.didMeasureConditionsList = false

    -- Conditions editor working state. Filled in by renderEditor when a
    -- filter is selected:
    --   - supportedRows: array of {field, cmp, value, rawText?} representing
    --     the editable (number / bool, non-`in`/`notin`) condition rows.
    --     `rawText` lives only on number rows that received keystrokes since
    --     the last flush.
    --   - preservedChildren: array of expression-node clones that the editor
    --     cannot render (enum / string conditions, in/notin cmps, nested
    --     groups). Round-tripped verbatim through flush so saving never
    --     destroys un-renderable nodes.
    --   - lastRenderedFilterId: id of the filter whose rows are currently in
    --     supportedRows / preservedChildren. Used to discard a stale render
    --     state when selection switches.
    self.conditionEditState = {
        supportedRows         = {},
        preservedChildren     = {},
        lastRenderedFilterId  = nil,
    }

    -- Per-field cached options for the row pickers. Lazy on first access in
    -- populateCellForItemInSection. Reset on renderEditor so a remote
    -- catalog change is reflected on the next render.
    self.conditionFieldOptionsCache = nil

    -- Pending-changes overlay keyed by filter id. Each value is a partial
    -- table {name?=string, animalType?=integer|ANIMAL_TYPE_ANY, op?="AND"|"OR",
    -- usage?=string (canonical RLFilterUsage value)}. Widget callbacks write
    -- into this; service:update is NOT called per keystroke.
    -- flushPendingChanges drains the table on onFrameClose. The per-id
    -- sub-table is created lazily on first write. Unlike animalType, the
    -- usage axis is a 3-state enum where every state has a canonical string
    -- value, so no sentinel is needed - absence-of-key means "no change",
    -- presence means "change to this value".
    self.pendingChanges = {}

    -- AnimalType selector state cache. Populated by seedAnimalTypeStates on
    -- every renderEditor call (cheap, ~5-10 types). Each entry is
    -- {label=string, typeIndex=integer|nil}; index 1 is always the "Any" row
    -- with typeIndex=nil.
    self.animalTypeStates = {}

    -- Custom footer buttons: Back always; New filter + Duplicate + Delete
    -- conditionally appended by updateButtonVisibility.
    -- hasCustomMenuButtons=true forces the first page-switch to use
    -- self.menuButtonInfo rather than RLMenu's default back-only set,
    -- preventing a one-frame flicker.
    self.hasCustomMenuButtons = true

    self.backButtonInfo = {
        inputAction = InputAction.MENU_BACK,
    }
    -- [New filter] unparked. Callback wired to the live handler
    -- shipped (onClickNewFilter). Visibility gated by
    -- updateButtonVisibility on tradeAnimals permission + farmId presence.
    self.newFilterButtonInfo = {
        inputAction = InputAction.MENU_EXTRA_1,
        text = g_i18n:getText("rl_menu_filters_new_button"),
        callback = function() self:onClickNewFilter() end,
    }
    -- [Duplicate] clones the currently selected filter (overlay-merged so
    -- in-flight edits are duplicated too). MENU_EXTRA_2 is the conventional
    -- second extra slot; mirrors RLMenuMessagesFrame's deleteAllButtonInfo
    -- usage pattern.
    self.duplicateButtonInfo = {
        inputAction = InputAction.MENU_EXTRA_2,
        text = g_i18n:getText("rl_menu_filters_duplicate_button"),
        callback = function() self:onClickDuplicate() end,
    }
    -- [Delete] prompts YesNoDialog then dispatches service:delete on Yes.
    -- MENU_CANCEL keeps the destructive action on the cancel/red slot,
    -- matching the RLMenuMessagesFrame convention.
    self.deleteButtonInfo = {
        inputAction = InputAction.MENU_CANCEL,
        text = g_i18n:getText("rl_menu_filters_delete_button"),
        callback = function() self:onClickDelete() end,
    }
    -- v2 modal editor: three-tier action bar.
    --
    -- Tier 1 (filtersList focused): Back / New filter / Duplicate / Delete filter
    -- Tier 2 (metadata or empty conditions list focused): Back / Add condition
    -- Tier 3 (condition row focused): Back / Edit / Add condition / Add group (stub) / Delete condition
    --
    -- Slot collisions across tiers are intentional - only one tier is
    -- active at a time. updateButtonVisibility rebuilds menuButtonInfo from
    -- the active tier so MENU_EXTRA_1 means "New filter" in Tier 1 and
    -- "Add condition" in Tier 2/3 without conflict.
    --
    -- Add condition moved from MENU_ACCEPT to MENU_EXTRA_1 to free
    -- MENU_ACCEPT for "Edit condition" in Tier 3 (the primary positive
    -- action when a row is selected).
    self.addConditionButtonInfo = {
        inputAction = InputAction.MENU_EXTRA_1,
        text = g_i18n:getText("rl_menu_filters_add_condition"),
        callback = function() self:onAddConditionClicked() end,
    }
    -- Edit condition: Tier 3 only. MENU_ACCEPT slot since editing a focused
    -- row is the canonical positive action.
    self.editConditionButtonInfo = {
        inputAction = InputAction.MENU_ACCEPT,
        text = g_i18n:getText("rl_menu_filters_edit_condition"),
        callback = function() self:onEditConditionClicked() end,
    }
    -- Delete condition: Tier 3 only. MENU_CANCEL slot for destructive
    -- action consistency with deleteButtonInfo (Tier 1).
    self.deleteConditionButtonInfo = {
        inputAction = InputAction.MENU_CANCEL,
        text = g_i18n:getText("rl_menu_filters_delete_condition"),
        callback = function() self:onDeleteConditionClicked() end,
    }
    -- Add group: Tier 3 only. MENU_EXTRA_2 slot. v2 stub - callback logs
    -- and no-ops; the group-editing follow-up wires the actual sibling-group insertion.
    self.addGroupButtonInfo = {
        inputAction = InputAction.MENU_EXTRA_2,
        text = g_i18n:getText("rl_menu_filters_add_group_button"),
        callback = function() self:onAddGroupClicked() end,
    }
    self.menuButtonInfo = { self.backButtonInfo }

    -- General subtab control registry. Keyed by RLSettings.SETTINGS name;
    -- value is the BinaryOption/MultiTextOption/Button widget. Tooltip
    -- child Text refs live in self.tooltips[name]. Both populated by
    -- populateGeneralSubtab() during initialize() (per-clone, one-shot).
    -- The page deliberately does NOT touch RLSettings.SETTINGS[*].element
    -- - that ref stays nil (no pause-menu rows are built anymore); the
    -- RL_BroadcastSettingsEvent path nil-guards it. Each page owns its
    -- own widget refs.
    self.controls          = {}
    self.tooltips          = {}
    self.didMeasureGeneralPane = false

    Log:trace("RLMenuSettingsFrame.new: instance created")
    return self
end

--- Load the settings frame XML and register the frame with g_gui.
--- Called from RLMenu.setupGui() before the menu XML is loaded so that
--- rlMenu.xml's FrameReference ref="RLMenuSettingsFrame" resolves.
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

--- Called by the GUI manager after all element references are wired.
--- Do NOT mutate the tree here (fires on both the original and the clone).
--- Closure binding + setTexts live in initializeSubCategoryPages() and are
--- invoked from onFrameOpen() to keep per-clone state fresh on every open.
---
--- Binds the filters SmoothList data source + delegate. Binding here is
--- safe (non-mutating) and necessary so both the original and the clone
--- resolve their own data paths.
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

    -- Cache editor widget refs. getDescendantById walks the tree once
    -- here so renderEditor / flushPendingChanges / widget callbacks can hit
    -- direct field references without repeating the descend on every call.
    -- Per-widget nil-guards downstream: any missing ref logs Log:warning and
    -- skips that widget rather than crashing the frame.
    self.filterEditorContainer  = self:getDescendantById("filterEditorContainer")
    self.filterEditorEmpty      = self:getDescendantById("filterEditorEmpty")
    self.filterEditorLayout     = self:getDescendantById("filterEditorLayout")
    -- No filterEditorSliderBox cache: the metadata layout has 4 fixed rows
    -- and never scrolls, so no docked slider exists for the editor pane.
    self.filterNameInput        = self:getDescendantById("filterNameInput")
    self.filterAnimalTypeSelector = self:getDescendantById("filterAnimalTypeSelector")
    self.filterOpSelector       = self:getDescendantById("filterOpSelector")
    self.filterUsageSelector    = self:getDescendantById("filterUsageSelector")

    -- Conditions editor widget cache. Same nil-guard pattern as the
    -- metadata widgets above; per-widget references downstream guard nil
    -- individually so partial loads degrade rather than crash.
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

    -- Bind the conditions SmoothList to this frame as both data source and
    -- delegate. The shared delegate dispatches by list reference
    -- (`if list == self.filtersList ... elseif list == self.filterConditionsList`)
    -- so the single `self` object can host both lists without confusion.
    if self.filterConditionsList ~= nil then
        self.filterConditionsList:setDataSource(self)
        self.filterConditionsList:setDelegate(self)
        Log:trace("RLMenuSettingsFrame:onGuiSetupFinished: filterConditionsList bound")
    end

    -- Seed the conditions match-logic selector texts once at setup (static,
    -- locale-baked at l10n load time). AnimalType selector is reseeded per
    -- renderEditor because it depends on animal-system state.
    -- Display text is "Match ALL" / "Match ANY" (renamed
    -- from AND/OR for clarity). Stored op string in serialisation/wire stays
    -- "AND"/"OR" - keys preserved end-to-end; only the visible text changed.
    if self.filterOpSelector ~= nil then
        self.filterOpSelector:setTexts({
            g_i18n:getText("rl_menu_filters_op_and"),
            g_i18n:getText("rl_menu_filters_op_or"),
        })
        Log:trace("RLMenuSettingsFrame:onGuiSetupFinished: filterOpSelector texts set (Match ALL / Match ANY)")
    end

    -- v2 modal editor: three-tier action bar focus triggers. Each anchor
    -- element's onFocusEnter is wrapped (via Utils.appendedFunction, so the
    -- inherited focus behavior is preserved) with a tier-refresh call. Without
    -- these triggers the action bar would stay stale when focus moves between
    -- filtersList / metadata / conditionsList via keyboard or gamepad.
    --
    -- Mouse-driven row-selection inside the conditions list is covered by
    -- onListSelectionChanged (chunk C). These hooks cover the cross-section
    -- focus transitions (e.g. arrow-key from filtersList into the editor).
    -- Gotcha: a ScrollingLayoutElement captures each child's onFocusEnter into
    -- scrollingFocusEnter_orig and replaces onFocusEnter with its own
    -- scroll-to-visible wrapper, re-applying that wrapper on every layout
    -- update - which CLOBBERS any wrap we put on onFocusEnter after the first
    -- SL setup. The SL wrapper calls scrollingFocusEnter_orig on each focus
    -- enter, so hooking THAT field survives SL invalidations. For elements not
    -- inside an SL (filtersList, filterConditionsList live in different
    -- containers in our layout), scrollingFocusEnter_orig is nil and the
    -- normal onFocusEnter wrap works.
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
        -- subCategoryPaging gets refresh-only treatment: focus on it is
        -- never one of the editor tiers (it's outside the editor), but the
        -- empty-conditions-list edge case can route focus here when the
        -- BOTTOM link from filterUsageSelector falls through. Without this
        -- wrap, the action bar stays stale at Tier 2 when focus has
        -- actually escaped the editor. With it, resolveActionBarTier
        -- returns nil -> Tier 1 fallback engages -> bar reverts to
        -- filter-level actions, which is correct here.
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

--- Per-clone setup. Called explicitly by RLMenu:setupMenuPages() on the
--- live clone (not the original) after registerPage. Populates the
--- General subtab's settings rows (look up XML element refs, set option
--- texts, register controls). Tree mutation forbidden in onGuiSetupFinished
--- (fires on both original and clone) so we do it here.
---
--- Per-row state push (setState) and cascade run on every onFrameOpen via
--- refreshGeneralSubtab(); this initialize() handles the once-per-clone
--- bindings only.
function RLMenuSettingsFrame:initialize()
    Log:debug("RLMenuSettingsFrame:initialize")
    self:populateGeneralSubtab()
end

--- Called by the Paging element when this tab becomes active.
--- Rebinds tab selection closures, seeds paging texts, resets to General,
--- and parks focus on the tab bar. Rebinding every open (rather than once
--- in onGuiSetupFinished) keeps closures captured against the live frame
--- instance and survives repeated opens.
function RLMenuSettingsFrame:onFrameOpen()
    RLMenuSettingsFrame:superClass().onFrameOpen(self)
    self.isFrameOpen = true
    Log:debug("RLMenuSettingsFrame:onFrameOpen")

    self:initializeSubCategoryPages()

    -- Default to [General] on every open - deliberate, no persistence.
    -- Reset the first-visibility measure flags so the runtime-measure logs
    -- fire once per frame-open cycle (Filters one-shot in updateSubCategoryPages,
    -- General one-shot below).
    self.subCategoryPaging:setState(RLMenuSettingsFrame.SUB_CATEGORY.GENERAL, true)
    self.didMeasureFiltersPane = false
    self.didMeasureGeneralPane = false
    self.didMeasureFilterCellCount = 0

    -- Push current RLSettings state into General subtab widgets and run
    -- the per-row admin gate + dependency cascade. State may have changed
    -- between opens (MP broadcast); re-read every time.
    self:refreshGeneralSubtab()

    -- One-shot first-visibility measure log for the General layout. Mirrors
    -- the Filters pane measure in updateSubCategoryPages - GUI
    -- positioning is computed from profiles but VERIFIED with runtime
    -- measurement before iterating (session rule 4). nil-guards on .size /
    -- size[1] / size[2] cover the case where a stretched layout is briefly
    -- present without committed axes until the next layout pass.
    local genLayout = self:getDescendantById("generalSettingsLayout")
    if genLayout ~= nil and genLayout.size ~= nil
       and genLayout.size[1] ~= nil and genLayout.size[2] ~= nil
       and not self.didMeasureGeneralPane then
        Log:debug("RLMenuSettingsFrame: generalSettingsLayout measured: %.2fpx x %.2fpx",
            genLayout.size[1] * 1920, genLayout.size[2] * 1080)

        -- Measurement: log subCategoryPages[1] (parent of
        -- generalSettingsSliderBox) + the sliderBox itself + the layout, so
        -- we can see the actual right-edge gap and pick a correct anchor /
        -- parent reanchor instead of guessing magic +Npx offsets.
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

    -- Tint each visible row container with an alternating dark shade so the
    -- light-cream row title text reads against a dark backing. Without this,
    -- rows fall back to the default white tint of `gui.colorPreset` from the
    -- baseReference profile and titles are invisible on the new menu chrome.
    -- Runs AFTER refreshGeneralSubtab so the per-row disabled cascade has
    -- settled.
    self:updateAlternatingElements(genLayout)

    -- Save-from-QF handshake: consume any pending-select id from RLMenu BEFORE
    -- refreshData so resolveSelectionById picks the new row in the same pass.
    -- Function-scope local so the trailing subCategoryPaging:setState at the end
    -- of onFrameOpen can branch on it. AnimalFilterDialog:doCreateAndNavigate
    -- stashes the id via g_rlMenu:openSettingsFilter; we clear it on consume
    -- and RLMenu:onClose covers the ESC-during-handshake race.
    local didPendingSelect = false
    if g_rlMenu ~= nil and g_rlMenu.pendingSelectedFilterId ~= nil then
        self.selectedFilterId = g_rlMenu.pendingSelectedFilterId
        g_rlMenu.pendingSelectedFilterId = nil
        didPendingSelect = true
        Log:debug("RLMenuSettingsFrame:onFrameOpen: pending-select filterId=%s",
            tostring(self.selectedFilterId))
    end

    -- Pull filter rows + seed empty-state + footer buttons for whichever
    -- subtab ends up active. Safe to call even though [General] is the
    -- initial pane; rows are cached for when the user switches to [Filters].
    self:refreshData()

    -- Explicit focus edges between the tab bar and the filters list so
    -- DOWN from the tab bar reaches the list and UP from the list returns
    -- to the tab bar. Mirrors the linkElements pattern used by Info/Buy/
    -- Sell/Move/AI frames; without these, FocusManager auto-layout can
    -- resolve arrow keys to elements in other frames.
    if self.subCategoryPaging ~= nil and self.filtersList ~= nil then
        FocusManager:linkElements(self.subCategoryPaging, FocusManager.BOTTOM, self.filtersList)
        FocusManager:linkElements(self.filtersList, FocusManager.TOP, self.subCategoryPaging)
    end

    -- Editor focus chain: list <-> editor row 1 <-> row 2 <-> row 3.
    -- RIGHT/LEFT crosses the list-editor boundary; DOWN/UP chains within
    -- the editor AND falls through from list-bottom into the editor's
    -- Name input (so the full path tab -> list -> name -> animalType -> op
    -- works with DOWN arrow alone). Each link is nil-guarded so a missing
    -- widget downgrades cleanly to the partial chain (warning already
    -- logged in onGuiSetupFinished).
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
    -- Visual row order is now Name -> AnimalType -> Usage
    -- -> Op (filterOpSelector / "Conditions: Match ALL|ANY") -> ConditionsList.
    -- Focus links MUST mirror that order so D-pad / keyboard nav does not
    -- teleport over rows. Prior order (AnimalType -> Op -> Usage) was wired
    -- here pre-reorder; if these links are missed the keyboard chain skips
    -- whichever row was reordered.
    if self.filterAnimalTypeSelector ~= nil and self.filterUsageSelector ~= nil then
        FocusManager:linkElements(self.filterAnimalTypeSelector, FocusManager.BOTTOM, self.filterUsageSelector)
        FocusManager:linkElements(self.filterUsageSelector,      FocusManager.TOP,    self.filterAnimalTypeSelector)
    end
    if self.filterUsageSelector ~= nil and self.filterOpSelector ~= nil then
        FocusManager:linkElements(self.filterUsageSelector, FocusManager.BOTTOM, self.filterOpSelector)
        FocusManager:linkElements(self.filterOpSelector,    FocusManager.TOP,    self.filterUsageSelector)
    end

    -- Focus chain: last metadata row (filterOpSelector) -> conditionsList.
    -- [+ condition] lives on the action bar, not in-pane, so the in-pane
    -- focus chain skips it - DOWN from the last metadata row reaches the
    -- conditions list directly; UP rises straight back.
    if self.filterOpSelector ~= nil and self.filterConditionsList ~= nil then
        FocusManager:linkElements(self.filterOpSelector,     FocusManager.BOTTOM, self.filterConditionsList)
        FocusManager:linkElements(self.filterConditionsList, FocusManager.TOP,    self.filterOpSelector)
    end
    Log:trace("RLMenuSettingsFrame:onFrameOpen: editor focus chain linked")

    -- Reset the once-per-process measure flag so the conditions-list
    -- size logs on first visibility per frame-open cycle (the flag lives on
    -- the instance for consistency with the other measure logs; the spec
    -- bullet is one-shot per frame-open visibility, not once-per-process).
    self.didMeasureConditionsList = false

    -- Initial focus on the tab bar - [General] is the active pane and has
    -- no content to focus. updateSubCategoryPages shifts focus to the list
    -- when the user switches to [Filters].
    FocusManager:setFocus(self.subCategoryPaging)

    -- Save-from-QF handshake tail: when a pending-select fired earlier in this
    -- onFrameOpen, flip the subcategory paging to [Filters]. setState(FILTERS, true)
    -- re-fires updateSubCategoryPages which handles pane visibility, footer
    -- rebuild, AND shifts focus to filtersList - leaving the new
    -- row both visible and focused. The unconditional setState(GENERAL, true) at
    -- the start of onFrameOpen runs first; this override is the final word so the
    -- user lands on the editor for the just-created filter.
    if didPendingSelect then
        Log:debug("RLMenuSettingsFrame:onFrameOpen: pending-select tail; switching to FILTERS subtab")
        self.subCategoryPaging:setState(RLMenuSettingsFrame.SUB_CATEGORY.FILTERS, true)
    end
end

--- Apply an alternating dark tint to each visible row container in the
--- given ScrollingLayout so the light-cream row title text reads against a
--- dark backing. Walks `layout.elements` in source order:
---   - elements named "sectionHeader" (our 20px gap spacers) reset the
---     alternation flag so each section restarts at the darker shade.
---   - other visible elements get tinted via setImageColor(nil, r, g, b, a)
---     with the rgba pulled at runtime from the
---     `InGameMenuSettingsFrame.COLOR_ALTERNATING` runtime global. The flag
---     toggles after each tint so adjacent rows alternate.
---   - hidden elements are skipped entirely (no toggle, no tint).
--- Disabled rows (e.g. dependency-cascade greyed) are still tinted; the
--- disabled-state styling is a separate channel layered on top.
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

    -- ipairs (not pairs) so traversal follows authored XML order strictly.
    -- Section reset and parity toggle both depend on positional order.
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

--- Called by the Paging element when this tab is deactivated.
--- Clears isFrameOpen so refreshIfOpen becomes a no-op, then drains the
--- pendingChanges overlay to service:update.
---
--- Ordering invariant: isFrameOpen=false BEFORE flushPendingChanges. The
--- service dispatches RLFilterUpdateEvent on the server side after each
--- update; a remote rebroadcast arriving mid-flush would re-enter our
--- frame via refreshIfOpen and call refreshData() recursively, fighting
--- the flush loop. Clearing the flag first makes refreshIfOpen early-return
--- and closes the re-entry window.
function RLMenuSettingsFrame:onFrameClose()
    RLMenuSettingsFrame:superClass().onFrameClose(self)
    self.isFrameOpen = false
    Log:debug("RLMenuSettingsFrame:onFrameClose")
    self:flushPendingChanges()
end

--- Seed the subcategory tab bar: bind getIsSelected closures on each tab
--- Button and its background ThreePartBitmap, populate subCategoryPaging
--- texts with stringified indices, and size the pager to the tab box.
---
--- The closures resolve via `tonumber(self.subCategoryPaging.texts[state])`
--- rather than `subCategoryPaging:getState()` directly because `.texts`
--- is the authoritative visible-index-to-semantic-index map - needed so
--- highlight stays correct if tab visibility ever becomes dynamic.
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

--- Pager state-change callback (XML onClick on subCategoryPaging). Resolves
--- visible state to a semantic index via .texts and toggles pane visibility.
--- Nil-guards the .texts lookup - the map is briefly out-of-sync with the
--- state during setTexts, and an early return keeps the pane set stable.
---
--- Tails: one-shot first-visibility measure log for the Filters pane
--- (size is only reliable after the pane becomes visible and layout has
--- settled) + a footer rebuild so the New filter button appears/disappears
--- in lockstep with the active subtab.
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

    -- GeneralSettingsSliderBox now lives at the GUI
    -- root (sibling of the menu container) so its right edge lands at
    -- the screen right edge instead of inside the menu chrome. Because
    -- it's no longer nested inside subCategoryPages[1], it does not
    -- inherit the per-page setVisible toggle above - we must hide it
    -- explicitly when the Filters tab is active. dataElementId binds it
    -- to generalSettingsLayout (still inside subCategoryPages[1]); when
    -- that pane is hidden the slider has no scrollable target and should
    -- not render.
    local sliderBox = self.generalSettingsSliderBox or self:getDescendantById("generalSettingsSliderBox")
    if sliderBox ~= nil then
        self.generalSettingsSliderBox = sliderBox -- cache for next call
        local visible = (idx == RLMenuSettingsFrame.SUB_CATEGORY.GENERAL)
        sliderBox:setVisible(visible)
        Log:trace("RLMenuSettingsFrame:updateSubCategoryPages: generalSettingsSliderBox visible=%s (idx=%d)",
            tostring(visible), idx)
    end

    -- First-visibility measure log. One-shot per frame-open cycle so the
    -- log doesn't spam on every subtab click. Measures after the visibility
    -- toggle above so the layout engine has settled the stretched size.
    -- Guards on size[1] / size[2] nil: a profile-driven stretch can leave
    -- the table present but component axes nil until the next layout pass.
    if idx == RLMenuSettingsFrame.SUB_CATEGORY.FILTERS
       and not self.didMeasureFiltersPane
       and self.filtersListContainer ~= nil
       and self.filtersListContainer.size ~= nil
       and self.filtersListContainer.size[1] ~= nil
       and self.filtersListContainer.size[2] ~= nil then
        Log:debug("RLMenuSettingsFrame: filtersListContainer measured: %.2fpx x %.2fpx",
            self.filtersListContainer.size[1] * 1920,
            self.filtersListContainer.size[2] * 1080)

        -- Measurement: log filterEditorContainer +
        -- filterConditionsListContainer + filterConditionsBanner so the
        -- banner can be anchored relative to the conditions-list TOP
        -- without guessing the 290px reservation.
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

    -- Editor pane measure log. Once-per-process (NOT once-per-open) because
    -- the frame instance is reused across reopens. Target dimensions
    -- ~1088 x 783 px (parent pane width minus the 410px left list). If the
    -- runtime measurement diverges materially from that target, the inline
    -- size="100% 100%" absoluteSizeOffset="-410px 0px" override on the
    -- filterEditorContainer is not producing the expected stretch and the
    -- layout needs investigation.
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

    -- Alphabetical case-insensitive sort with stable id tie-break. Sort
    -- runs on refreshData boundaries only; mid-edit name callbacks do NOT
    -- re-sort (writes go to pendingChanges + reloadData reads the overlay
    -- in populateCellForItemInSection, keeping row positions stable while
    -- the user is typing).
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

    -- isReconciling gate: reloadData synchronously fires onListSelectionChanged
    -- via SmoothList's setSelectedItem(..., true) after clamping; block the
    -- delegate from overwriting selectedFilterId mid-flight. resolveSelectionById
    -- also calls setSelectedIndex which re-enters the delegate; same gate.
    self.isReconciling = true
    if self.filtersList ~= nil then
        self.filtersList:reloadData()
    end
    self:resolveSelectionById()
    self.isReconciling = false

    self:updateEmptyState()
    self:updateButtonVisibility()

    -- Tail renderEditor so the right pane reflects the new selection (or
    -- the empty-state branch) every time the list refreshes. resolveSelectionById
    -- may have cleared self.selectedFilterId for an orphaned id; renderEditor
    -- handles that branch.
    self:renderEditor()
end

--- Refresh only when the frame is currently open. Called by the three
--- RLFilter*Event:run handlers so remote create/update/delete mutations
--- rerender the list without requiring the user to reopen the menu.
function RLMenuSettingsFrame:refreshIfOpen()
    if self.isFrameOpen then
        Log:debug("RLMenuSettingsFrame:refreshIfOpen: refreshing")
        self:refreshData()
    else
        Log:debug("RLMenuSettingsFrame:refreshIfOpen: frame closed, skipping")
    end
end

--- Id-authoritative selection. Walks self.rows for self.selectedFilterId
--- and re-derives list.selectedIndex; clears the cached id (and the list
--- selection) if the id is no longer present. Called from refreshData so
--- undefined pairs-order reloads never silently desync the highlighted
--- row from the cached id that the editor will consume.
function RLMenuSettingsFrame:resolveSelectionById()
    if self.filtersList == nil then return end

    if self.selectedFilterId == nil then
        -- Clear both fields (not just selectedIndex) to match the Info
        -- frame clear pattern. SmoothList expects numeric indices; nil
        -- would crash. The null branch is not a state transition, log
        -- at TRACE.
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

--- Toggle the branched empty-state text + list/slider visibility. Branches
--- the empty-state copy on whether the player has a farm at all; mirrors
--- the Messages frame pattern.
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

    -- Toggle the slider box alongside the list so the empty states don't
    -- leave an orphaned scrollbar next to the "No saved filters" / "You
    -- need a farm" text. Honors the spec's "slider box visibility follows
    -- the list" contract explicitly rather than relying on layout.
    if self.filtersSliderBox ~= nil then
        self.filtersSliderBox:setVisible(hasRows)
    end
end

--- Resolve which action-bar tier should be active given the current focus.
--- Returns 1 / 2 / 3, or nil when no tier-specific buttons apply (FocusManager
--- unavailable, no focus, or focus is on an element we do not track).
---
--- Tier 1 - filtersList scope: focus on filtersList. Filter operations.
--- Tier 2 - inner editor scope: focus on a metadata widget OR on
---          filterConditionsList with no row selected (empty list, or focus
---          landed on the list container without picking a row). Add
---          condition only - destructive filter actions intentionally
---          absent so MENU_CANCEL is not "delete filter" while focus is
---          inside the editor.
--- Tier 3 - condition row scope: focus on filterConditionsList AND a row
---          is selected. Full row-operations bar.
---
--- FocusManager treats SmoothList as one focusable element, so row-selected
--- is distinguished via getSelectedIndexInSection rather than focus state.
function RLMenuSettingsFrame:resolveActionBarTier()
    if FocusManager == nil or FocusManager.getFocusedElement == nil then
        return nil
    end
    local focused = FocusManager:getFocusedElement()
    if focused == nil then return nil end

    -- Walk the focus's parent chain looking for known anchors. Stop at the
    -- first match; the chain is short (a handful of nesting levels).
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

--- Rebuild the footer menu button array per active tier. Back is always
--- present; tier-specific buttons join only when activeSubtab=FILTERS AND
--- the player has a farm AND the tradeAnimals permission. Per-tier rules:
---
--- Tier 1: New filter (always); Duplicate + Delete filter (hasSelection)
--- Tier 2: Add condition (hasSelection) - no destructive slot
--- Tier 3: Edit / Add condition / Add group / Delete condition (hasSelection)
---
--- setMenuButtonInfoDirty triggers TabbedMenu's footer re-render on the
--- next tick.
function RLMenuSettingsFrame:updateButtonVisibility()
    local activeSubtab
    if self.subCategoryPaging ~= nil then
        activeSubtab = self.subCategoryPaging:getState()
    end
    local hasFarm = (self.farmId ~= nil and self.farmId ~= 0)
    local hasPerm = self:hasCreatePermission()
    local hasSelection = (self.selectedFilterId ~= nil)
    local appended = {}

    -- Right-pane editor-widget gate: a worker without tradeAnimals (or any
    -- player without a farm) sees the filter list and footer correctly
    -- restricted to Back, but the Name / Animal Type / Op / Show-on widgets
    -- were still accepting input. The server-side RLFilterUpdateEvent guard
    -- already drops the forged mutation, but the local commit-then-revert
    -- cycle is misleading and dispatches WARN-spammy wire churn. Mirror the
    -- adminOnly pattern used by updateReadonlyState and push
    -- the editable bit to each widget. setDisabled is idempotent, so this
    -- is safe to call on every focus-driven re-entry.
    local editable = hasFarm and hasPerm
    if self.filterNameInput          ~= nil then self.filterNameInput:setDisabled(not editable) end
    if self.filterAnimalTypeSelector ~= nil then self.filterAnimalTypeSelector:setDisabled(not editable) end
    if self.filterOpSelector         ~= nil then self.filterOpSelector:setDisabled(not editable) end
    if self.filterUsageSelector      ~= nil then self.filterUsageSelector:setDisabled(not editable) end
    Log:trace("RLMenuSettingsFrame:updateButtonVisibility: right-pane widgets editable=%s (hasFarm=%s hasPerm=%s)",
        tostring(editable), tostring(hasFarm), tostring(hasPerm))

    self.menuButtonInfo = { self.backButtonInfo }

    -- Tier resolution gated on subtab + permissions. Outside Filters, or
    -- when the player can't create filters, tier stays nil and only Back
    -- is shown - matches the pre-v2 behavior for other subtabs.
    --
    -- Tier 1 fallback: on the Filters subtab with farm + perm, if
    -- resolveActionBarTier returns nil (no focus on any tracked anchor),
    -- default to Tier 1. Without this, the empty state (0 saved filters)
    -- traps the user with only [Back] because filtersList is hidden by
    -- updateEmptyState - the "New filter" affordance vanishes exactly
    -- when it is needed to escape the empty state.
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
            -- "Add group" hidden until group editing is implemented.
            -- addGroupButtonInfo / onAddGroupClicked / addGroupAtSelection stay
            -- defined; re-enable by restoring these two inserts. The stub still
            -- surfaces an InfoDialog if ever invoked directly.
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

--- UX-side permission gate for New filter. The authoritative boundary is
--- the server-side validation inside RLFilter{Create,Update,Delete}Event:run;
--- this check only controls button visibility and the early
--- abort in onClickNewFilter. Mirrors RLMenuMessagesFrame:hasDeletePermission
--- with "updateFarm" swapped for "tradeAnimals".
function RLMenuSettingsFrame:hasCreatePermission()
    if g_currentMission == nil or g_currentMission.getHasPlayerPermission == nil then
        return false
    end
    return g_currentMission:getHasPlayerPermission("tradeAnimals") == true
end

-- =============================================================================
-- Filter list: create handler
-- =============================================================================

--- Disambiguated default name so repeated [New filter] clicks don't produce
--- N identical rows while the inline editor is still in flight. Base is the
--- localized "New filter" string; the " (N)" suffix is numeric so locales
--- can keep the base and get a universal index. "New filter", "New filter (2)",
--- "New filter (3)" in English.
---
--- File-local static so both the Settings-side `:onClickNewFilter` and the
--- QF-side `AnimalFilterDialog:onClickSaveFilter` produce the same sequence
--- without depending on a live RLMenuSettingsFrame instance. Takes a plain
--- name iterator (any array-like with string entries).
---@param names string[] existing filter names
---@return string
local function static_computeDefaultFilterName(names)
    local base = g_i18n:getText("rl_menu_filters_default_name")
    -- Match "<base> (N)" where N is one or more digits, anchored end-to-end
    -- (Lua patterns: %( and %) are literal parens, (%d+) captures digits).
    local pattern = "^" .. base:gsub("(%W)", "%%%1") .. " %((%d+)%)$"
    -- Track the MAX N seen, NOT the count: with sparse rows (e.g. only
    -- "<base> (3)" present after deletes), count-based logic emits "(2)"
    -- and the second click collides on "(3)". Bare base counts as N=1
    -- because user-visible numbering starts at 2.
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

--- Exported static wrapper so AnimalFilterDialog (and any future caller)
--- can produce the same default name from a plain name list, without holding
--- a RLMenuSettingsFrame instance. Pair with `g_rlFilterService:list()` to
--- get the current registry's names.
---@param names string[] existing filter names
---@return string
function RLMenuSettingsFrame.computeDefaultFilterNameForNames(names)
    return static_computeDefaultFilterName(names)
end

--- Instance wrapper: extract names from `self.rows` then delegate to the
--- static helper. Behavioural contract is identical to the previous inline
--- implementation; the refactor only moves the math to a pure function so
--- the QF-side save flow can reuse it.
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

--- Footer New filter handler. Creates a placeholder filter scoped to the
--- local farm with an empty AND expression (vacuous-true),
--- sets selectedFilterId so refreshData auto-selects the new row via
--- resolveSelectionById, then refreshes.
---
--- Nil-guard on create(): service returns nil on malformed input (programming
--- error, per the RLFilterService:create contract). Remote MP-rejection
--- rollback is deferred to a future iteration.
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

    -- Set the id BEFORE refresh so resolveSelectionById auto-selects the
    -- new row without a separate walk.
    self.selectedFilterId = created.id
    Log:debug("RLMenuSettingsFrame:onClickNewFilter: created id=%s name='%s'",
        tostring(created.id), tostring(created.name))

    self:refreshData()
end

-- =============================================================================
-- Filter editor: helpers (file-local)
-- =============================================================================

--- Resolve a localized label for an animal type. Delegates to the canonical
--- helper RLAnimalUtil.getAnimalTypeDisplayName which already handles the
--- groupTitle -> title -> ui_<name>s -> name -> "?" cascade, including the
--- hasText guard that distinguishes a real l10n hit from FS25's
--- "Missing '<key>' in l10n.xml" miss-stringification.
---@param at table animalType entry from animalSystem:getTypes()
---@return string label
local function resolveAnimalTypeLabel(at)
    if RLAnimalUtil ~= nil and RLAnimalUtil.getAnimalTypeDisplayName ~= nil then
        return RLAnimalUtil.getAnimalTypeDisplayName(at)
    end
    -- Defensive fallback if RLAnimalUtil is unavailable for any reason.
    Log:warning("resolveAnimalTypeLabel: RLAnimalUtil.getAnimalTypeDisplayName unavailable; using local fallback")
    if at == nil then return "?" end
    return at.groupTitle or at.name or "?"
end

--- True when `node` looks like an expression group (op + children) rather
--- than a leaf condition. Used by deepEqualFilter to dispatch comparison.
---@param node table|nil
---@return boolean
local function isGroupNode(node)
    return node ~= nil and node.op ~= nil and node.children ~= nil
end

--- Compare a condition's value field. Scalars (number/bool/string) via `==`;
--- list values (table, for `in`/`notin`) by length + ipairs element equality.
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

--- Compare a single expression-tree node. Groups recurse; leaves compare
--- field/cmp/value.
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

--- Deep-compare a merged filter snapshot against a stored filter on the
--- fields a Settings-editor overlay can change: name, animalType, farmId,
--- usage, expression tree. Used by flushPendingChangesForId to short-circuit
--- the wire update when an overlay collapses back to stored state. Skips id / version: id is invariant, version is
--- a server stamp not authored by the editor.
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

--- Apply a pending overlay onto a stored filter, producing a merged snapshot.
--- Immutable fields (id, farmId, version) are copied from stored unchanged so
--- service:update never sees a divergence. animalType has three-state semantics
--- via the ANIMAL_TYPE_ANY sentinel (see module head).
---@param stored table cloned snapshot from getById (never nil at this point)
---@param overlay table|nil per-id partial overlay or nil for "no pending"
---@return table merged shallow-cloned filter with overlay applied
local function overlayPending(stored, overlay)
    -- Stale stored.usage = nil defense. Every normal entry point
    -- (create / update / serialization / wire / applyIncoming) normalises to
    -- a canonical string. Defending here ensures that if a stale record ever
    -- slips through (test fixture, hand-built record), the editor's flush
    -- degrades to a successful service:update instead of triggering the
    -- usage-nil rejection in service:update which would silently drop every
    -- other pending edit on that filter.
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
        -- Sentinel marks an explicit "clear to Any"; converts to nil for
        -- service:update + storage + wire.
        merged.animalType = nil
    elseif overlay.animalType ~= nil then
        merged.animalType = overlay.animalType
    end
    if overlay.usage ~= nil then
        -- 3-state enum, no sentinel needed; presence means "change to this
        -- canonical value" (one of RLFilterUsage.ANY/OWNED/DEALER).
        merged.usage = overlay.usage
    end
    if overlay.op ~= nil then
        -- Build a fresh root group with the new op; preserve any nested
        -- children so a filter authored with sub-groups (group editing / API /
        -- peer) keeps its structure when the user flips the root match
        -- mode in the UI.
        local stored_children = (stored.expression and stored.expression.children) or {}
        local copied = {}
        for i, child in ipairs(stored_children) do copied[i] = child end
        merged.expression = { op = overlay.op, children = copied }
    end
    return merged
end

--- Populate self.animalTypeStates with the canonical "Any" row at index 1 and
--- one row per type returned by animalSystem:getTypes(). Reseeded on every
--- renderEditor call (cheap, ~5-10 types). g_currentMission is guaranteed
--- non-nil here: every settings page is registered behind basePredicate in
--- RLMenu's page setup, so this code path is unreachable pre-mission.
---@param self table frame instance
local function seedAnimalTypeStates(self)
    local entries = {
        { label = g_i18n:getText("rl_menu_filters_animal_type_any"), typeIndex = nil },
    }
    if g_currentMission ~= nil and g_currentMission.animalSystem ~= nil then
        local types = g_currentMission.animalSystem:getTypes()
        if types ~= nil then
            -- getTypes() is keyed by typeIndex (sparse-map shape), not a dense
            -- 1-N array. ipairs would stop at the first gap and silently drop
            -- exotic / map-bridge types. Mirror RLDealerQuery.listDealerTypes:
            -- collect with pairs(), guard against nil entries / missing
            -- typeIndex, then sort by typeIndex for stable ordering.
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

    -- Push labels into the selector. setTexts clamps state to #texts so an
    -- earlier setState(largeIndex) survives a shrink (defense-in-depth).
    if self.filterAnimalTypeSelector ~= nil then
        local labels = {}
        for i, entry in ipairs(entries) do labels[i] = entry.label end
        self.filterAnimalTypeSelector:setTexts(labels)
    end
    Log:trace("seedAnimalTypeStates: %d state(s) seeded", #entries)
end

--- Push the 3-state Usage selector labels (Any / Owned / Dealer) into the
--- MultiTextOption widget. State 1 = ANY, state 2 = OWNED, state 3 = DEALER.
--- Idempotent and cheap; called from renderEditor on every render to mirror
--- seedAnimalTypeStates. No state cache needed because the mapping is
--- constant (3 fixed strings, no runtime variation).
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

--- Drive the right-pane editor widgets from the current selection + pending
--- overlay. Called from refreshData (tail), onListSelectionChanged (tail), and
--- after Duplicate/Delete-Yes mutations. Empty-state branch hides the layout
--- and slider; selected branch builds a merged snapshot via overlayPending
--- and pushes values into the three widgets with callback-suppress flags so
--- the programmatic push doesn't re-enter the click handlers.
-- Forward declaration: renderConditionsForFilter is defined as a local
-- function further down the file (after partitionChildren which it depends
-- on), but renderEditor below needs to call it. Lua 5.1 resolves free
-- variables at parse time against locals declared EARLIER in the same
-- chunk; a local declared later does not retroactively become an upvalue,
-- so without this forward declaration the reference inside renderEditor
-- would resolve to a global at runtime, find nil, and crash on the call
-- ("attempt to call a nil value" at the call site).
-- The later `local function renderConditionsForFilter` line was converted
-- to `renderConditionsForFilter = function` so it assigns to THIS local
-- rather than shadowing with a fresh one.
local renderConditionsForFilter

function RLMenuSettingsFrame:renderEditor()
    if self.selectedFilterId == nil then
        if self.filterEditorEmpty     ~= nil then self.filterEditorEmpty:setVisible(true) end
        if self.filterEditorLayout    ~= nil then self.filterEditorLayout:setVisible(false) end
        if self.filterEditorSliderBox ~= nil then self.filterEditorSliderBox:setVisible(false) end
        -- v2 modal editor: conditions banner + list container are SIBLINGS
        -- of filterEditorLayout (not children), so hiding the layout doesn't
        -- recurse into them. Hide explicitly so a just-deleted filter's
        -- preserved-banner + condition rows don't linger after selection
        -- clears.
        if self.filterConditionsBanner        ~= nil then self.filterConditionsBanner:setVisible(false)        end
        if self.filterConditionsListContainer ~= nil then self.filterConditionsListContainer:setVisible(false) end
        if self.filterConditionsSliderBox     ~= nil then self.filterConditionsSliderBox:setVisible(false)     end
        Log:debug("RLMenuSettingsFrame:renderEditor: no selection")
        return
    end

    -- Hydrate AnimalType selector states first so the index resolution below
    -- maps against the live label set.
    seedAnimalTypeStates(self)

    -- Seed the 3-state Usage selector labels. Constant mapping (Any/Owned/
    -- Dealer); idempotent re-seed is cheap.
    seedUsageSelector(self)

    if g_rlFilterService == nil then
        Log:warning("RLMenuSettingsFrame:renderEditor: g_rlFilterService is nil; aborting render")
        return
    end

    local stored = g_rlFilterService:getById(self.selectedFilterId)
    if stored == nil then
        -- Selected id no longer present (race with remote delete, or a
        -- pending edit reference that survived a refresh). Drop the
        -- selection and fall back to the empty-state branch on the next
        -- render pass. resolveSelectionById will catch this on the next
        -- refreshData but we guard here too.
        Log:debug("RLMenuSettingsFrame:renderEditor: id=%s not in service, falling back to empty",
            tostring(self.selectedFilterId))
        self.selectedFilterId = nil
        if self.filterEditorEmpty     ~= nil then self.filterEditorEmpty:setVisible(true) end
        if self.filterEditorLayout    ~= nil then self.filterEditorLayout:setVisible(false) end
        if self.filterEditorSliderBox ~= nil then self.filterEditorSliderBox:setVisible(false) end
        -- Mirror the no-selection branch above: hide the conditions banner +
        -- list container so stale state from the just-disappeared filter
        -- doesn't linger.
        if self.filterConditionsBanner        ~= nil then self.filterConditionsBanner:setVisible(false)        end
        if self.filterConditionsListContainer ~= nil then self.filterConditionsListContainer:setVisible(false) end
        if self.filterConditionsSliderBox     ~= nil then self.filterConditionsSliderBox:setVisible(false)     end
        return
    end

    local merged = overlayPending(stored, self.pendingChanges[self.selectedFilterId])

    if self.filterEditorEmpty     ~= nil then self.filterEditorEmpty:setVisible(false) end
    if self.filterEditorLayout    ~= nil then self.filterEditorLayout:setVisible(true)  end
    if self.filterEditorSliderBox ~= nil then self.filterEditorSliderBox:setVisible(true) end
    -- Re-show the conditions area whenever a filter is selected. Banner
    -- visibility is then driven by renderConditionsForFilter based on the
    -- partition's preserved count.
    if self.filterConditionsListContainer ~= nil then self.filterConditionsListContainer:setVisible(true) end
    if self.filterConditionsSliderBox     ~= nil then self.filterConditionsSliderBox:setVisible(true)     end

    -- Tint the editor rows so the cream title text reads against a dark
    -- backing. Same fix applied to the General subtab rows -
    -- without it, rows fall back to the default white tint of
    -- gui.colorPreset from baseReference and titles are invisible on the
    -- new menu chrome. updateAlternatingElements skips hidden rows, so
    -- this MUST run after the setVisible(true) above. Idempotent / cheap
    -- to re-run on every render.
    if self.filterEditorLayout ~= nil then
        self:updateAlternatingElements(self.filterEditorLayout)
    end

    -- Name: caret preservation only. A programmatic setText DOES fire
    -- onTextChanged on a value change (the callback is raised by the
    -- inherited TextElement setter, which setText reaches without passing a
    -- skip flag - unlike setState(idx, false) on the option widgets); the
    -- phantom-stash that causes is handled separately by onFilterNameChanged's
    -- value-equality guard. THIS guard is purely about the caret: the input
    -- control resets the caret to text-end on every programmatic value push -
    -- including no-ops. When a remote RLFilterUpdateEvent triggers
    -- refreshIfOpen -> refreshData -> renderEditor while the user is editing in
    -- the middle of the field, that setText stomps the caret. Skip the push
    -- when the input owns focus AND the text is unchanged (the user is editing
    -- it now and the overlay already captures their pending edits).
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

    -- AnimalType: walk animalTypeStates to find the entry matching the
    -- merged animalType (nil for Any). Fallback to state 1 = Any when no
    -- match (covers a stored type the local mission doesn't define, e.g.
    -- a peer save-game with a bridge mod we don't have loaded).
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

    -- Usage: 1 = ANY, 2 = OWNED, 3 = DEALER. Default to state 1 for any value
    -- that doesn't match OWNED or DEALER (covers ANY, nil-from-legacy, and
    -- defensive against an un-normalised in-memory record).
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

    -- Render the conditions list + banner against the merged record.
    -- Re-partitions expression children into supported/preserved, reloads
    -- the SmoothList, and updates the banner.
    renderConditionsForFilter(self, merged)
end

--- TextInput onTextChanged callback. The widget raises this with
--- (target, element, text); with colon-bound `self` absorbing the
--- target, our explicit args are (element, text).
---
--- Per-keystroke flow:
---   1. Stash the typed value into pendingChanges[id].name (lazy sub-table).
---   2. reloadData on the SmoothList so the left-pane cell text reflects
---      the live edit (populateCellForItemInSection reads the overlay).
---   3. Wrap reloadData in isReconciling so the synchronous selection
---      delegate fired by SmoothList:reloadData doesn't tail-call
---      renderEditor and stomp the caret mid-typing.
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

    -- Phantom-rewrite guard: TextInput onChange fires not only on
    -- real typing but also on programmatic setText during selection-change
    -- reconcile and on refocus reemit. In those paths "typed" already
    -- equals stored.name; stashing it produces an overlay the flush layer
    -- cannot tell from a real edit, and service:update broadcasts a
    -- byte-identical Update over the wire. Compare trimmed-typed to
    -- trimmed-stored and short-circuit when they match. If an earlier
    -- keystroke left a stale name in the overlay (user typed, then
    -- reverted), clear it so it can't leak into a subsequent flush; drop
    -- the overlay table entirely if it carries no other pending fields.
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

    -- Reload the left list so the cell shows the pending name. isReconciling
    -- gate prevents the synchronous onListSelectionChanged from re-entering
    -- renderEditor (which would call setText and stomp the caret).
    if self.filtersList ~= nil then
        self.isReconciling = true
        self.filtersList:reloadData()
        self.isReconciling = false
    end
end

--- MultiTextOption onClick callback. The widget raises this with
--- (target, state, widget, isLeftButtonEvent); with colon-bound `self`
--- absorbing the target, our explicit args are (state, widget).
---
--- state == 1 maps to the "Any" row (typeIndex = nil), persisted into the
--- overlay as the ANIMAL_TYPE_ANY sentinel so flush can distinguish
--- "explicit clear" from "no pending change".
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

--- MultiTextOption onClick callback for the Usage scope selector.
--- state 1 -> ANY, state 2 -> OWNED, state 3 -> DEALER (matches the wire-byte
--- order 0/1/2 minus one for cognitive parity with the codec).
---
--- Out-of-range states (4+) are unreachable in practice because the widget
--- is seeded with exactly 3 labels; we log at TRACE and no-op as defence
--- against future label changes.
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

--- Set of field types this slice can render in the conditions editor.
--- Covers number + bool (via the row's read-only Text widget) and enum +
--- string (via the modal RLFilterConditionDialog's MultiTextOption +
--- TextInput widgets, plus RLFilterValueSetDialog for `in`/`notin` over
--- ENUM). The cmp gate inside isSupportedConditionNode is type-conditional:
--- ENUM accepts in/notin; NUMBER/BOOL/STRING route those cmps through
--- partition -> preserved.
local SUPPORTED_TYPES = { number = true, bool = true, enum = true, string = true }

--- True when the given AST node is a flat condition the in-frame editor can
--- render directly. False for groups, conditions on unknown fields,
--- conditions on unsupported field types, and `in`/`notin` cmps on
--- non-enum fields (the multi-value editor only supports enum domains).
---@param node table
---@return boolean
local function isSupportedConditionNode(node)
    if type(node) ~= "table" then return false end
    if node.op ~= nil then return false end -- group, not a condition
    if node.field == nil or node.cmp == nil then return false end
    local field = RLFilterFieldCatalog.get(node.field)
    if field == nil then return false end
    if not SUPPORTED_TYPES[field.type] then return false end
    -- Enum supports in/notin via RLFilterValueSetDialog. All other
    -- field types still route in/notin to preservedChildren (round-trip
    -- only; no multi-value editor for number/string/bool).
    if (node.cmp == "in" or node.cmp == "notin") and field.type ~= "enum" then
        return false
    end
    return true
end

--- Partition `expression.children` into the supported flat conditions the
--- editor can render plus a verbatim list of preserved (unsupported) child
--- nodes. Preserved nodes round-trip through flush unchanged so saving
--- supported edits cannot destroy nested groups or enum/string conditions
--- authored elsewhere (hand-edited XML, peer client, future group-editing UI).
---
--- Returned tables are shallow-cloned at the top level; supported rows are
--- fresh `{ field, cmp, value }` tables so editing one does not mutate the
--- stored expression. Preserved nodes are the existing references; flush
--- treats them as opaque - this is safe because the service performs its
--- own deep-clone before storing the merged record.
---
--- Empty / nil expression returns two empty arrays - the caller treats that
--- as "filter has no conditions yet". The root group's op is NOT mutated
--- here; `pendingChanges[id].op` (set by `onOpChanged`) flows through
--- `overlayPending` separately.
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

--- Resolve a localized label for a catalog field key. Uses
--- `rl_menu_filters_field_<sanitized-key>` where periods in the key are
--- replaced by underscores to match XML attr-name conventions. Falls back
--- to the raw catalog key when the l10n entry is missing.
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

--- Format a condition row for the read-only text display in the v2 conditions
--- list. Delegates to RLFilterFieldDisplay.formatConditionDisplay so enum
--- (subType, gender) labels resolve via FillTypeManager / i18n and the
--- catalog stays free of UI coupling. Local wrapper kept so the
--- populateCell call site doesn't have to thread animalType through.
---
--- animalType resolution is inlined (not via resolveEffectiveAnimalType
--- below) because Lua local-function-declaration ordering: this helper sits
--- ~340 lines before resolveEffectiveAnimalType in source order, and `local
--- function` declarations are only visible from their declaration point
--- onward. Lifting the inline lookup back into resolveEffectiveAnimalType
--- would require moving that helper up; the inline mirror is two lines and
--- carries no extra state.
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

--- Return the list of catalog fields that the conditions editor can render
--- for the given filter, in stable catalog order. Caches the result on the
--- frame instance keyed by animalType (cleared on every renderEditor so a
--- mid-edit animalType change reseeds correctly).
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

--- Locate the row at a given 1-based index inside the editor's working
--- state. Returns nil when the index is out of range; callers MUST nil-guard
--- (every widget callback runs through this).
---@param self table frame instance
---@param index number
---@return table|nil row
local function getConditionRowAt(self, index)
    if self.conditionEditState == nil then return nil end
    local rows = self.conditionEditState.supportedRows
    if rows == nil then return nil end
    return rows[index]
end

--- Reload the conditions SmoothList and restore focus. Captures the focused
--- row's index before the reload (or accepts a caller-supplied preferred
--- index), then re-focuses the same row's field picker after the reload.
--- Falls back to the addConditionButton when the list is now empty or the
--- preferred index is out of range. Without this, deleting a focused row
--- leaves FocusManager pointing at a recycled cell and a field-change
--- reload silently moves focus outside the list.
---@param self table frame instance
---@param preferredIndex number|nil 1-based row index to focus after reload
local function reloadConditionsList(self, preferredIndex)
    if self.filterConditionsList == nil then return end

    -- v2: rows are read-only Text widgets, no in-row focusable widgets.
    -- Capture target row index from the SmoothList's own selection state
    -- (getSelectedIndexInSection) when no override is provided. The old
    -- findRowIndexForWidget walk-up is gone; FocusManager treats the list
    -- as one focusable element, so the list's selection is authoritative.
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
        -- Empty list or no target. Focus the list container itself so the
        -- Tier 2 action bar shows (Back + Add condition); pressing Add
        -- routes through the dialog flow.
        FocusManager:setFocus(self.filterConditionsList)
        Log:trace("reloadConditionsList: empty list / no target; focused filterConditionsList")
        return
    end

    -- Restore selection to targetIndex and focus the list. The list's own
    -- selection drives Tier 3 in the action bar; FocusManager treats the
    -- list as one focusable element so we don't drill into the cell.
    if self.filterConditionsList.setSelectedIndex ~= nil then
        self.filterConditionsList:setSelectedIndex(targetIndex, false, true)
    end
    FocusManager:setFocus(self.filterConditionsList)
    Log:trace("reloadConditionsList: focused filterConditionsList at index=%d (rowCount=%d)",
        targetIndex, rowCount)
end

--- Render the conditions list against the currently-selected filter's
--- merged expression (overlay-aware). Re-partitions `expression.children`
--- into supported + preserved, stashes them on `self.conditionEditState`,
--- updates the preserved-banner visibility / text, and triggers a SmoothList
--- reload. Per-row population happens inside populateCellForItemInSection.
---@param self table frame instance
---@param merged table merged filter record (overlay applied)
-- Body assigned to the forward-declared local near renderEditor; do NOT
-- prefix with `local` here or it would shadow and re-introduce the
-- "attempt to call a nil value" bug from renderEditor.
renderConditionsForFilter = function(self, merged)
    self.conditionFieldOptionsCache = nil
    local supported, preserved = partitionChildren(merged.expression)

    -- Detect remote-update clobber. RLFilterService:update deep-clones the
    -- filter on every successful apply (via cloneFilter), so each new stored
    -- record has a distinct expression-table reference. If the pending
    -- overlay was snapshotted against an OLDER reference than the one we are
    -- about to render, the storage has diverged - either a peer client
    -- updated this filter via RLFilterUpdateEvent or the local user mutated
    -- it through another path while editing. Either way, applying the stale
    -- overlay would destroy the new authoritative state.
    local pending = self.pendingChanges[merged.id]
    if pending ~= nil and pending.conditions ~= nil
       and pending._originExpressionRef ~= nil
       and pending._originExpressionRef ~= merged.expression then
        Log:warning("renderConditionsForFilter: id=%s detected storage divergence (remote update or external mutation); discarding %d pending condition(s) + preserved snapshot to avoid clobber",
            tostring(merged.id), #pending.conditions)
        pending.conditions = nil
        pending.preservedChildren = nil
        pending._originExpressionRef = nil
        -- pending may still hold name/animalType/op/usage edits; keep them.
        -- Re-fetch the pointer to reflect the cleared shape below.
        pending = self.pendingChanges[merged.id]
    end

    -- If pendingChanges[id].conditions exists, it represents the in-flight
    -- edited supported array (e.g. from an Add or per-row edit). Prefer it
    -- over the partition-from-storage so re-renders mid-edit don't lose the
    -- user's pending rows. Preserved children always come from storage -
    -- they aren't editable so there is no pending overlay for them.
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
            -- Defensive pcall around string.format - a translator-supplied
            -- `%f` / `%s` placeholder mismatch on a `%d` template would raise
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

    -- One-shot measure log. Runs once per process per spec Boundaries bullet.
    if not self.didMeasureConditionsList
       and self.filterConditionsList ~= nil
       and self.filterConditionsList.size ~= nil
       and self.filterConditionsList.size[1] ~= nil
       and self.filterConditionsList.size[2] ~= nil then
        Log:debug("RLMenuSettingsFrame: filterConditionsList measured: %.2fpx x %.2fpx",
            self.filterConditionsList.size[1] * 1920,
            self.filterConditionsList.size[2] * 1080)

        -- Diagnostic measurement: log absPosition + absSize for each editor
        -- sub-element so a layout regression (a missing or mispositioned
        -- list / banner / button) can be diagnosed from the log without
        -- additional instrumentation. One-shot via the same flag.
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

--- Lazy-init the per-id pending conditions array from the current edit
--- state. Called by every in-row callback before mutating the pending
--- snapshot so a row-level edit captures the full supported array in one
--- shot (matches the whole-object overlay shape used by `name` and
--- `animalType`).
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
                -- originSnapshot lets the flush path revert an EXISTING
                -- numeric row to its stored value when the user mistypes
                -- (e.g. "abc"), instead of silently deleting the condition.
                -- Newly-added rows from [+ condition] do NOT get
                -- originSnapshot, so an invalid new row is excluded entirely.
                originSnapshot = { field = row.field, cmp = row.cmp, value = row.value },
            }
        end
        self.pendingChanges[id].conditions = snapshot
        -- Snapshot preservedChildren onto the per-id overlay so a close-path
        -- retry after a rejected selection-switch flush still has the
        -- unsupported nodes for filter A even after the user has rendered
        -- filter B (which overwrites conditionEditState).
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
        -- Pin the stored.expression reference the overlay was seeded against.
        -- RLFilterService:update deep-clones on every apply, so the next
        -- renderConditionsForFilter call can detect divergence by
        -- reference-comparing this against `merged.expression`. A mismatch
        -- means the storage moved (peer update via Pattern A, or local
        -- mutation through another path) and the overlay must be discarded
        -- to avoid clobbering authoritative state.
        if self.conditionEditState ~= nil
           and self.conditionEditState.lastRenderedFilterId == id
           and self.conditionEditState.expressionRef ~= nil then
            self.pendingChanges[id]._originExpressionRef = self.conditionEditState.expressionRef
            Log:trace("ensurePendingConditions: id=%s pinned _originExpressionRef for divergence detection",
                tostring(id))
        end
    end
end

--- Sync a single in-memory edit-state row into the pending overlay (and
--- write through to `self.conditionEditState.supportedRows` for live
--- read-back without a full re-render).
---@param self table frame instance
---@param id string filter id
---@param index number 1-based row index
---@param patch table partial fields to apply: {field?, cmp?, value?, rawText?}
---@param clearKeys table|nil optional list of keys to explicitly set to nil
---   on the row + edit-state mirror. Workaround for Lua dropping nil-valued
---   keys from table-literal patches. Used by
---   onConditionFieldChanged when the new field's type diverges from the old
---   and a stale `rawText` must not bleed across.
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
    -- Mirror into edit-state so SmoothList's next populate pass reads the
    -- live values without waiting for a flush + refresh.
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

--- Resolve the filter's effective animalType from stored + pending overlay.
--- Same logic the populate / dialog flow uses. Returns nil for ANY (no
--- per-type restriction on field options).
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

--- v2 modal dialog open. rowIndex nil = new condition; non-nil = edit existing.
--- Looks up the initialCondition + animalType, then hands off to the dialog.
--- Dialog calls back into onConditionDialogClosed with the coerced new
--- condition (or nil on Cancel).
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
        -- Refuse to open the dialog when the row carries an enum
        -- value whose domain is currently empty (subType when the filter
        -- scope has no resolvable animal type, or the scoped type has zero
        -- subtypes loaded). The condition stays intact in pendingChanges /
        -- preservedChildren and round-trips through flush unchanged; the
        -- user can re-author it after switching the filter's animalType.
        -- SubType under unscoped filter (animalType=nil) now resolves
        -- via the cross-species union helper (mirrors the dialog-side
        -- _resolveActiveEnumDomain routing); the multi-value editor handles
        -- the union domain. Other enum reads stay on the scoped resolver.
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
                -- Surface the refuse via the existing filterConditionsBanner
                -- element (same surface used for the "N condition(s) hidden"
                -- preserved-children notice). The next renderConditionsForFilter
                -- pass (driven by any subsequent selection change or
                -- animalType edit) overwrites the banner with its own
                -- content, so this is transient by design - matches the
                -- spec's intent of a non-modal in-frame hint.
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

--- Dialog callback. newCondition is nil on Cancel, non-nil on OK. rowIndex
--- distinguishes Add (nil) from Edit (non-nil). On OK: route through
--- patchConditionRow (edit) or addConditionAtSelection (new), then reload
--- the conditions list so the row text refreshes and focus restores.
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
        -- New condition: insert by selection rules.
        self:addConditionAtSelection(newCondition)
        return
    end

    -- Edit existing row: patch full record. patchConditionRow handles
    -- pendingChanges + conditionEditState mirror + clearKeys plumbing.
    local patch = {
        field = newCondition.field,
        cmp   = newCondition.cmp,
        value = newCondition.value,
    }
    -- rawText is optional; if absent on newCondition the patch omits it
    -- (no clear needed since the dialog only sets it when text != canonical).
    if newCondition.rawText ~= nil then
        patch.rawText = newCondition.rawText
    end
    -- If the dialog did NOT include rawText but the row had one, clear it
    -- so a stale buffer doesn't outlive the edit.
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

--- Walk `expression` (a group node) to locate `node`'s parent group and
--- 1-based index within that parent's children. v2 ships a flat root (no
--- nested groups), so the helper either returns `(expression, k)` for a
--- matching leaf condition in expression.children or `(nil, nil)` when
--- the node isn't present. Group editing will recurse through nested groups.
---
--- Signature takes `expression` explicitly so callers can pass whichever
--- AST they are operating on (stored filter, pending overlay, or
--- conditionEditState merged view). RLFilterService:getById deep-clones,
--- so re-fetching inside this helper would break reference equality
--- with the caller's node ref.
---
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

--- Pure static helper: compute the 1-based index at which a new row should
--- be inserted into `rows`, given the currently-focused row's `selectedIndex`.
--- No GUI dependency; covered by rlTest.
---
--- Rules:
---   - rows nil / empty / no selection / out-of-range selection -> append.
---   - Selection k in [1..#rows] -> k+1 (insert as next sibling).
---
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

--- Selection-aware insertion. For v2 with flat data, "selection" means the
--- 1-based index of the focused row in filterConditionsList. No selection
--- (or empty list) -> append to end. Selected row k -> insert at k+1 (next
--- sibling). Future group rows will route through getParentGroupAndIndex
--- to insert as child of a focused group; v2 always inserts at the root.
function RLMenuSettingsFrame:addConditionAtSelection(newCond)
    if self.selectedFilterId == nil then return end

    ensurePendingConditions(self, self.selectedFilterId)
    local rows = self.pendingChanges[self.selectedFilterId].conditions

    -- Resolve selection. SmoothList:getSelectedIndexInSection returns the
    -- focused row's 1-based index, or 0/nil when nothing is selected.
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

--- Group-editing stub. v2 binding: enabled callback that logs + warns + surfaces
--- an InfoDialog so the user gets visible feedback instead of a silent
--- no-op. Verifies the action-bar context-switching plumbing without
--- committing group semantics. InfoDialog.show gives the action
--- closed-loop feedback that grouping is intentionally unimplemented in
--- this version.
function RLMenuSettingsFrame:addGroupAtSelection(_newGroup)
    Log:warning("RLMenuSettingsFrame:addGroupAtSelection: Add group: placeholder (group editing not implemented) - no state change")
    if InfoDialog ~= nil and InfoDialog.show ~= nil and g_i18n ~= nil then
        Log:debug("RLMenuSettingsFrame:addGroupAtSelection: showing not-yet-implemented InfoDialog")
        InfoDialog.show(g_i18n:getText("rl_menu_filters_add_group_not_implemented"))
    end
end

--- Action-bar Add condition (Tier 2/3, MENU_EXTRA_1 in step 5). Currently
--- still bound to legacy MENU_ACCEPT slot until step 5 flips the slot.
--- Opens the dialog with rowIndex=nil (new condition); OK routes through
--- onConditionDialogClosed -> addConditionAtSelection.
function RLMenuSettingsFrame:onAddConditionClicked()
    self:openConditionEditDialog(nil)
end

--- Action-bar Edit condition (Tier 3, MENU_ACCEPT after step 5). Opens
--- the dialog pre-populated with the focused row's values.
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

--- Action-bar Delete condition (Tier 3, MENU_CANCEL after step 5). Removes
--- the focused row from pendingChanges + edit-state mirror, then reloads
--- the list. Focus restoration falls to the neighbor row via
--- reloadConditionsList's preferredIndex clamp.
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

--- Action-bar Add group stub (Tier 3, MENU_EXTRA_2 slot). The group-editing follow-up
--- replaces this body with selection-aware sibling-group insertion. The
--- v2 binding is enabled-but-no-op; this callback's existence verifies
--- the action-bar context-switching plumbing.
function RLMenuSettingsFrame:onAddGroupClicked()
    self:addGroupAtSelection(nil)
end

-- =============================================================================
-- Filter editor: flush
-- =============================================================================

--- Drain self.pendingChanges to service:update. Called from onFrameClose AFTER
--- isFrameOpen is cleared (so a mid-flush remote RLFilterUpdateEvent rebroadcast
--- early-returns through refreshIfOpen, closing the re-entry window).
---
--- For each pending id:
---   - fetch stored via getById; skip + DEBUG-log if nil (orphan id, e.g.
---     deleted by another client while we held an edit)
---   - overlay pending onto stored to produce the merged record
---   - enforce flush-time name boundary: trim whitespace; revert to stored
---     name + WARNING if the trimmed result is empty (widget callbacks are
---     permissive mid-typing; flush is the enforcement point)
---   - call service:update(id, merged); WARNING on nil return
---
--- service:update dispatches RLFilterUpdateEvent (Pattern A); MP convergence
--- is the service's responsibility.
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
    -- Snapshot ids first so the per-id helper can mutate self.pendingChanges
    -- without iterating-while-mutating semantics. Per-id outcome decides
    -- whether the entry clears or stays for retry.
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

--- Flush a single filter id's pending overlay through `RLFilterService:update`.
--- Extracted from `flushPendingChanges` so `onListSelectionChanged` can
--- flush the previously-selected filter on selection switch without draining
--- the whole table (data-loss avoidance: a rejected edit on filter A must
--- not silently drop edits on filter B when the user clicks B).
---
--- Returns one of three string codes:
---   - `"updated"` -> service:update returned non-nil; caller clears the entry.
---   - `"skipped"` -> orphan id (stored == nil); caller clears the entry.
---   - `"rejected"` -> service:update returned nil; caller MUST KEEP the
---                     entry so the user can retry / observe the next flush
---                     pass on close. WARNING already logged.
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

    -- Rebuild expression.children = validSupported ++ preservedChildren
    -- when the overlay carries `conditions`. Number rows go through
    -- tonumber(rawText) validation.
    --
    -- On parse failure, EXISTING rows (those carrying originSnapshot from
    -- ensurePendingConditions) revert to their stored field/cmp/value so the
    -- user does not lose the condition - they only lose the edit.
    -- NEWLY-ADDED rows (no originSnapshot, came from onAddConditionClicked)
    -- are excluded entirely since there is no stored counterpart to revert to.
    if overlay.conditions ~= nil then
        local validSupported = {}
        for _, row in ipairs(overlay.conditions) do
            local field = RLFilterFieldCatalog.get(row.field)
            local include = true
            local outField, outCmp, outValue = row.field, row.cmp, row.value
            if field ~= nil and field.type == "number" and row.rawText ~= nil then
                local parsed = tonumber(row.rawText)
                -- Lua's tonumber accepts "inf", "-inf", scientific notation
                -- like "1e308" (overflows to math.huge), and unbounded
                -- negatives. Numeric fields in the catalog all have implicit
                -- non-pathological semantics (age, weight, genetics.*,
                -- healthScore). Reject NaN + +-inf the same way as a parse
                -- failure - revert if originSnapshot is present, else exclude.
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

        -- Prefer the per-id overlay snapshot of preservedChildren over the
        -- frame-global conditionEditState. The overlay snapshot was taken
        -- when ensurePendingConditions first created the conditions array
        -- and survives selection-switches; conditionEditState gets clobbered
        -- by every renderEditor so it would be wrong for any id other than
        -- the currently-rendered one.
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

    -- Phantom-rewrite guard: a defensive net for any callsite
    -- that tainted pendingChanges with values identical to stored. Without
    -- this short-circuit a no-op overlay (e.g. retyping a name back to its
    -- original, then closing the frame) would still emit a byte-identical
    -- Update event, triggering fanout to all consumer frames on every
    -- client. Returning "skipped" matches the orphan-id contract:
    -- flushPendingChanges clears the entry rather than retaining for retry.
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

--- Compute a non-colliding duplicate name. Walks self.rows resolving each
--- row's display name via the pending overlay (so renames in flight on
--- OTHER rows still count toward the collision check). Appends the
--- localized `rl_menu_filters_duplicate_suffix` on the first duplicate;
--- subsequent duplicates use `rl_menu_filters_duplicate_suffix_n`, a
--- format string carrying the language's own word order / punctuation
--- around `%d` (e.g. " (copy %d)" in EN). Detection of existing dupes
--- builds a Lua pattern from the same localized template so the count
--- form is recognized regardless of how the translator phrased it.
--- @param baseName string Source filter's merged name
--- @return string
function RLMenuSettingsFrame:computeDuplicateName(baseName)
    local base = baseName or ""
    local suffixFirst = g_i18n:getText("rl_menu_filters_duplicate_suffix")
    local suffixNFmt  = g_i18n:getText("rl_menu_filters_duplicate_suffix_n")
    local first = base .. suffixFirst

    -- Build a detection pattern from the localized numbered template.
    -- Swap the %d placeholder for a sentinel byte first, escape all Lua
    -- pattern specials in the surrounding literal text, then swap the
    -- sentinel back for the (%d+) capture. Escaping `%` is required - it
    -- is Lua's pattern escape char - which is why we cannot escape the
    -- raw format string directly without first lifting the placeholder.
    local function escapePattern(s)
        return (s:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1"))
    end
    local placeholder = "\1"
    local templatePat = escapePattern((suffixNFmt:gsub("%%d", placeholder)))
        :gsub(placeholder, "(%%d+)")
    local countPattern = "^" .. escapePattern(base) .. templatePat .. "$"

    -- Track the MAX N seen, NOT the count: with sparse rows (e.g. only
    -- "<base> (copy 3)" present after deletes), count-based logic emits
    -- "(copy 2)" and the second click collides on "(copy 3)". The bare
    -- suffix form (`<base> (copy)`, no number) counts as N=1 because
    -- user-visible numbering starts at 2 (no "(copy 1)" anywhere). Note:
    -- the source row's bare name (`<base>` alone) is NOT counted - only
    -- existing copies contribute.
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

--- Footer Duplicate handler. Gated on selection + permission + farm.
--- Clones the source filter (overlay-merged so in-flight edits are
--- duplicated too), assigns a non-colliding name, and creates via the
--- same g_rlFilterService:create call onClickNewFilter uses. Auto-selects
--- the new id via the existing resolveSelectionById path on refreshData.
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

    -- _cloneFilter deep-clones the expression (carryover ownership
    -- contract). The service ALSO deep-clones internally; double-clone is
    -- a correctness belt-and-suspenders honoured throughout the filter code.
    -- Preserve the source filter's scope. A global filter (farmId == nil)
    -- stays global; a farm-scoped filter keeps its farmId. Using
    -- self.farmId here would narrow a global copy down to the active
    -- farm.
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

--- Footer Delete handler. Opens a YesNoDialog with the selected filter's
--- name; on Yes calls service:delete via onDeleteConfirmed. No state
--- mutation until the user confirms (mirrors
--- RLMenuMessagesFrame:onClickDeleteAll).
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

    -- YesNoDialog passes (target, yesValue, callbackArgs) to its callback;
    -- with target=self the colon-bound `self` absorbs it and we receive
    -- (yes, id) explicitly. Mirrors RLMenuMessagesFrame's onDeleteAll flow.
    YesNoDialog.show(
        self.onDeleteConfirmed,
        self,
        confirmText,
        g_i18n:getText("ui_attention"),
        nil, nil, nil, nil, nil,
        stored.id
    )
end

--- YesNoDialog confirmation callback for Delete. Yields when the user
--- clicked No. On Yes: call service:delete FIRST and only react on its
--- return - on ok=true clear pending edits + selection; on ok=false
--- (stale id / race with another client) preserve pending edits + selection
--- and log WARNING so the user can retry / observe the next refresh event
--- resolving the divergence. No destructive local cleanup before confirming
--- the service applied the mutation.
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

--- SmoothList delegate: fired when the user picks a different row. The
--- frame hosts two SmoothLists (filtersList + filterConditionsList) on the
--- same `self` delegate; this entry point only handles the filtersList
--- case (left-pane selection switch). Conditions-list selection currently
--- has no side effect - row controls drive the edit state directly via
--- in-row widget callbacks.
---
--- Before advancing selection, flush the previously-selected
--- filter's pending overlay via `flushPendingChangesForId(previousId)`.
--- The advance happens regardless of flush outcome - blocking selection on
--- service rejection would be hostile UX, and a rejected entry stays in
--- `self.pendingChanges[previousId]` for retry / onFrameClose final pass.
--- @param list table The SmoothList instance asking
--- @param _section number Section index (single-section, ignored)
--- @param index number 1-based row index
function RLMenuSettingsFrame:onListSelectionChanged(list, _section, index)
    -- v2 modal editor: conditions list selection IS user-meaningful. Row
    -- selection drives Tier 2 (no row focused) <-> Tier 3 (row focused)
    -- transitions on the action bar. Refresh and return; downstream
    -- autoflush/selection logic below is filtersList-only.
    if list == self.filterConditionsList then
        Log:trace("RLMenuSettingsFrame:onListSelectionChanged: conditions list selection (index=%s) -> refreshing action bar",
            tostring(index))
        self:updateButtonVisibility()
        return
    end
    if list ~= self.filtersList then return end
    if index == nil then return end

    -- Suppress overwrite during reconciliation. refreshData's reloadData +
    -- resolveSelectionById both fire this delegate synchronously via
    -- SmoothList's clamp-and-notify + our own setSelectedIndex call. The
    -- id we'd capture under those paths is the post-clamp row's id, not
    -- the user's intent; the outer path already knows the correct id.
    if self.isReconciling then
        Log:trace("RLMenuSettingsFrame:onListSelectionChanged: suppressed during reconcile (index=%s)",
            tostring(index))
        return
    end

    -- Autoflush the previously-selected filter before advancing.
    -- Outcome is logged inside the helper; advance is unconditional so a
    -- rejected flush does not strand the user on the dirty filter.
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
        -- Rerender the editor (-> empty state) + rebuild footer so Duplicate
        -- and Delete drop with the now-cleared selection. Without these the
        -- right pane keeps showing the previous filter's content and the
        -- destructive buttons stay live until some later refresh reconciles.
        self:renderEditor()
        self:updateButtonVisibility()
        return
    end

    self.selectedFilterId = row.id
    Log:debug("RLMenuSettingsFrame:onListSelectionChanged: index=%d id=%s",
        index, tostring(row.id))

    -- Selection changed: rerender the right pane against the new id and
    -- rebuild the footer so Duplicate/Delete toggle with selection.
    self:renderEditor()
    self:updateButtonVisibility()
end

-- =============================================================================
-- SmoothList data source protocol
--
-- Deliberately NOT logged. SmoothList calls these at draw frequency; tracing
-- them would swamp the log. refreshData + updateEmptyState + the selection
-- path are already logged and cover the render lifecycle.
-- =============================================================================

--- How many items the list should render. Dispatch by list reference so the
--- single `self` delegate can host both filtersList (left-pane saved
--- filters) and filterConditionsList (right-pane condition rows) without
--- crosstalk.
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

--- Populate one data cell from the row at the given index. Dispatch by list
--- reference; conditions-list rows have a richer template (field picker /
--- cmp picker / value widget / delete button).
--- @param list table
--- @param _section number Ignored
--- @param index number 1-based row index
--- @param cell table The ListItem cell to populate
function RLMenuSettingsFrame:populateCellForItemInSection(list, _section, index, cell)
    if list == self.filtersList then
        local row = self.rows[index]
        if row == nil then return end

        -- Resolve display name through the pending overlay so live edits show
        -- in the left list immediately. Sort key (row.name) stays untouched so
        -- row position remains stable mid-edit.
        local pending = self.pendingChanges[row.id]
        local displayName = (pending and pending.name) or row.name or ""

        local nameCell = cell:getAttribute("filterName")
        if nameCell ~= nil then
            nameCell:setText(displayName)
        end

        -- One-shot first-two-cell log: validates rl_filterListItem geometry
        -- (cell + title pos / size + text constraints) against the rendered
        -- row metrics. Two cells = inter-row pitch + per-cell geometry.
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

    -- v2 modal editor: row is a single read-only Text widget showing the
    -- formatted condition. Edits route through RLFilterConditionDialog via
    -- the Tier 3 action bar's Edit button.
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

    -- Pixel-accurate row truncation. String values use middle-truncate
    -- so two long needles that differ only at the suffix render
    -- distinguishably ("VeryLong...ABC" vs "VeryLong...XYZ"); other types
    -- use suffix-truncate via the basegame helper. Width budget is the row's
    -- own NDC width minus the left-indent offset, converted back to pixels.
    -- conditionText.textSize is set by the rl_filterConditionText profile
    -- (textSize 18px); we read it live so profile changes propagate.
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

    -- Indent: depth-aware left position. v2 ships flat (depth=0 for every
    -- row), so the static XML position="20px -10px" already produces the
    -- correct layout and this branch is a no-op. The depth-aware override
    -- is wired NOW so group editing just needs to populate self.conditionRowDepths
    -- alongside its partition pass.
    --
    -- setPosition takes NORMALIZED coordinates; GuiUtils.getNormalizedXValue
    -- is string-aware only - passing a raw number returns it unchanged, so we
    -- convert explicitly via g_referenceScreenWidth * g_aspectScaleX (the same
    -- conversion the string path applies for pixel strings).
    local depth = 0
    if self.conditionRowDepths ~= nil and self.conditionRowDepths[index] ~= nil then
        depth = self.conditionRowDepths[index]
    end
    if depth > 0 and conditionText.setPosition ~= nil
       and g_referenceScreenWidth ~= nil then
        local leftOffsetPx = 20 + depth * 20
        local scaleX = g_aspectScaleX or 1
        local normalizedX = (leftOffsetPx / g_referenceScreenWidth) * scaleX
        -- Preserve Y from XML load (the negative offset that puts text 10px
        -- below the row top). conditionText.position[2] is already normalized.
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

--- Build the per-row option-text arrays a state-row widget needs:
---   setting.getTexts -> the registry entry's own builder (runtime-composed texts)
---   binaryType=offOn -> {"Off", "On"} (localized)
---   valueType=int    -> { "20", "30", "40", ... }
---   valueType=float  -> { "0%", "10%", "20%", ... }
---   else             -> l10n keys "rl_settings_<name>_texts_<i>"
--- RLSettings.SETTINGS is the single source of truth for values and types.
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

--- One-shot per-clone wiring of the General subtab. Looks up each row's
--- widget via getDescendantById, builds option-text arrays for state rows,
--- and stores element + tooltip refs in self.controls / self.tooltips.
--- onClick attributes already wire each widget to the instance methods
--- (onClickGeneralSetting / onClickGeneralAction) at XML load time, so no
--- manual binding is needed.
---
--- Logs Log:error and bails (loud, not silent) if generalSettingsLayout is
--- missing. Per-row missing widgets log Log:warning and are skipped; refresh
--- subsequently no-ops on the missing entry.
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

            -- Stateful rows need their option-text arrays populated; action
            -- rows (setting.ignore == true) keep the static $l10n_..._text
            -- already set in XML.
            if not setting.ignore then
                widget:setTexts(buildSettingTexts(name, setting))
                Log:trace("RLMenuSettingsFrame:populateGeneralSubtab: bound state row '%s'", name)
            else
                Log:trace("RLMenuSettingsFrame:populateGeneralSubtab: bound action row '%s'", name)
            end

            -- Static tooltip text: write once at populate so action rows
            -- (which refreshGeneralSubtab skips) get tooltip text too. Dynamic
            -- tooltips for state rows seed at the default state here and are
            -- updated per-state in refreshGeneralSubtab.
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

    -- Aggregate sanity check: did we bind every setting? Per-row missing
    -- widget already logs Log:warning, but the totals make a partial-bind
    -- (XML drift, renamed setting, etc.) loud at a glance.
    local expected = 0
    for _ in pairs(RLSettings.SETTINGS) do expected = expected + 1 end
    if count ~= expected then
        Log:warning("RLMenuSettingsFrame:populateGeneralSubtab: bound %d/%d rows; XML/SETTINGS drift?", count, expected)
    else
        Log:debug("RLMenuSettingsFrame:populateGeneralSubtab: bound %d/%d row(s)", count, expected)
    end
end

--- Push current RLSettings state into widgets, refresh tooltip text
--- (static or dynamic per setting.dynamicTooltip), then re-run the
--- dependency cascade. Called from onFrameOpen() and from refreshIfGeneralOpen()
--- after MP broadcasts. Click handlers also call this after delegating to
--- RLSettings.applyChange so the widget reflects whatever state.callback
--- side effects produced.
---
--- setState uses forceEvent=false to avoid re-entering onClickGeneralSetting
--- during the programmatic push.
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

--- Per-row admin gate + dependency cascade. Operates on self.controls
--- (this frame's element registry), never on RLSettings.SETTINGS[*].element.
--- Per-row admin gating, not blanket non-admin disable: only rows flagged
--- setting.adminOnly==true are disabled for non-admins; the rest stay
--- enabled with their dependency cascade applied.
---
--- Admin check: g_server ~= nil OR g_currentMission.isMasterUser == true.
function RLMenuSettingsFrame:updateReadonlyState()
    local isAdmin = (g_server ~= nil) or (g_currentMission ~= nil and g_currentMission.isMasterUser == true)
    Log:trace("RLMenuSettingsFrame:updateReadonlyState: isAdmin=%s", tostring(isAdmin))

    for name, setting in pairs(RLSettings.SETTINGS) do
        local widget = self.controls[name]
        if widget ~= nil then
            local disabled = false

            -- The lock arm leads: a locked row is disabled for EVERYONE, admin included,
            -- which is the only visible difference a master user sees. It is what stops a
            -- player toggling a setting whose engine is stubbed out underneath.
            -- Note the arms are exclusive, so a locked row never evaluates its dependency
            -- cascade. Harmless for diseasesEnabled, which declares none; a live constraint
            -- for any future locked row that does.
            if setting.lock then
                disabled = true
            elseif setting.adminOnly and not isAdmin then
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

--- Refresh the General subtab if the frame is open. Called from
--- RL_BroadcastSettingsEvent:run so the page reflects MP-synced state
--- changes without requiring frame reopen. No-op when the frame is
--- closed - matches the refreshIfOpen convention used by the
--- filter-event hooks elsewhere on this branch.
function RLMenuSettingsFrame:refreshIfGeneralOpen()
    if not self.isFrameOpen then
        Log:trace("RLMenuSettingsFrame:refreshIfGeneralOpen: frame closed, skipping")
        return
    end
    Log:debug("RLMenuSettingsFrame:refreshIfGeneralOpen: frame open, refreshing")
    self:refreshGeneralSubtab()
end

--- XML onClick handler for state rows (BinaryOption / MultiTextOption).
--- Extracts the setting name from the widget's id (rlmenuSetting_<name>),
--- delegates to RLSettings.applyChange (the single write path for stateful
--- settings), then refreshes our widgets so the cascade and dynamic-tooltip
--- state stay current.
---
--- The colon syntax binds `self` implicitly; the GUI loader's raiseCallback
--- chain raises onClickCallback for state-row widgets with
--- (target, state, widget, isLeftButtonEvent), and target arrives as `self`
--- here. So the explicit args are (state, widget) - state is the post-click
--- state index, widget is the BinaryOption/MultiTextOption that was clicked.
---
--- Defensive `widget == nil then widget = state` keeps an accidental
--- cross-wire from a Button (which raises with only (target, widget))
--- resolving to a sensible widget reference for the early-return guard
--- below; the ignore-flag check then redirects.
--- @param state number 1-based new state from the widget post-click
--- @param widget table The widget that was clicked
function RLMenuSettingsFrame:onClickGeneralSetting(state, widget)
    if widget == nil then widget = state end
    -- type-check after the shuffle: if `state` was passed as a number (the
    -- documented MultiTextOption case where only state arrives without
    -- widget), the shuffle would otherwise leave `widget` as a number and
    -- the next line would crash on `widget.id`.
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

    -- The widget already advanced its own state on click; read off the
    -- widget for safety (the state arg is also the new value for
    -- MultiTextOption-derived elements per their raiseCallback chain).
    local newState = widget:getState()
    Log:debug("RLMenuSettingsFrame:onClickGeneralSetting: name='%s' newState=%d", name, newState)

    RLSettings.applyChange(name, newState)

    -- Sync the change off this client via RL_BroadcastSettingsEvent in its
    -- single-setting form. The server validates the sender (master-user),
    -- persists, and relays to other clients. Without this the RLMenu
    -- change stays local and the server reverts it on save/reload.
    Log:debug("RLMenuSettingsFrame:onClickGeneralSetting: broadcasting '%s' via RL_BroadcastSettingsEvent.sendEvent", name)
    RL_BroadcastSettingsEvent.sendEvent(name)

    self:refreshGeneralSubtab()
end

--- XML onClick handler for action rows (Button). Resolves the setting name
--- from the button's id and invokes its setting.callback with no args -
--- action rows are self-contained (dialog / export / reset handlers).
---
--- ButtonElement.raiseCallback delivers two args (`target, button`), so
--- the colon-bound `self` absorbs the target and the explicit `button`
--- arg lands at the right slot.
---
--- No state mutation, no cascade refresh - actions are fire-and-forget
--- (open dialog / export / reset).
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
