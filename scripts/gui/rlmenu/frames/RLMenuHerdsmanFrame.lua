--[[
    RLMenuHerdsmanFrame.lua
    RL Tabbed Menu Herdsman tab - rule list (master) + rule editor (detail).

    The list binds to the real rule registry (F3) and the right pane is the rule
    editor (F4b): name / operation / enabled / op-params + read-only filter and
    husbandries summaries. Edits stash to a per-id pending overlay and flush through
    the real g_rlHerdsmanRuleService:update (Approach B); MP syncs through the
    resulting RLHerdsmanRuleUpdateEvent.

    Bind-only by design: every policy decision routes to a pure module -
    visibility / validation / domains / summaries to RLHerdsmanRulePresenter, the
    overlay-merge + op-change carry-over to RLHerdsmanRuleEditModel. This frame holds
    only element read/write, index<->value lookups over the presenter domains, the
    engine-coupled live dewar enumeration (semen options), the tostring(v).."%"
    percentage labels, the fixed interim flush gate, nil-guards, and logging.
]]

RLMenuHerdsmanFrame = {}
local RLMenuHerdsmanFrame_mt = Class(RLMenuHerdsmanFrame, TabbedMenuFrameElement)

local Log = RmLogging.getLogger("RLRM")

-- Store mod directory at source time (g_currentModDirectory only valid during source())
local modDirectory = g_currentModDirectory

-- operation -> section-header i18n key. Localization wiring for the multi-section
-- list AND the Operation selector's state labels: the presenter stays key-free, so the
-- frame owns the label map. A value lookup, not decision logic.
--
-- This map is deliberately allowed to be a SUBSET of the canonical OPERATION_ORDER: an
-- operation registered before it is surfaced to players carries no entry yet. Both readers
-- already cope - the selector seed falls back to the raw operation name, and
-- getTitleForSectionHeader returns nil so the section header renders untitled. `horseCare`
-- is in that state until its player-facing pass lands.
local OPERATION_TITLE_KEY = {
    sell     = "rl_menu_herdsman_section_sell",
    move     = "rl_menu_herdsman_section_move",
    buy      = "rl_menu_herdsman_section_buy",
    castrate = "rl_menu_herdsman_section_castrate",
    naming   = "rl_menu_herdsman_section_naming",
    ai       = "rl_menu_herdsman_section_ai",
}

-- =============================================================================
-- Module-local helpers (pure wiring; no decisions)
-- =============================================================================

--- Resolve the animal type NAMES the presenter's operation x animalType declarations reference
--- into live indices, as a `name -> index` map for the presenter's gate. A name the registry
--- does not carry is OMITTED rather than mapped to nil, which is what gives the gate its
--- polarity for free: an allow-list with an unresolved name admits nothing, an exclude-list
--- with one excludes nothing.
---
--- This is the frame's job precisely because it is the `AnimalType` READ. The presenter stays
--- pure and stateless and simply consumes whatever map it is handed - so an absent registry is
--- diagnosed HERE, once per build (menu-open frequency), rather than by a latch in a pure module.
--- Resolution is per call, never memoized: `AnimalType` is populated after this file is sourced.
---@return table animalTypeIndexByName map of resolved NAME -> live animalType index (possibly empty)
function RLMenuHerdsmanFrame.buildAnimalTypeIndexMap()
    local names = RLHerdsmanRulePresenter.getDeclaredAnimalTypeNames()
    local map = {}
    if AnimalType == nil then
        Log:warning("RLMenuHerdsmanFrame.buildAnimalTypeIndexMap: AnimalType registry is nil; the operation x animalType gate gets an EMPTY map (allow-lists admit nothing, exclude-lists exclude nothing) - check AnimalSystem load order")
        return map
    end

    local resolved, missing = {}, {}
    for _, name in ipairs(names) do
        local idx = AnimalType[name]
        if idx ~= nil then
            map[name] = idx
            resolved[#resolved + 1] = string.format("%s=%s", name, tostring(idx))
        else
            missing[#missing + 1] = name
        end
    end

    if #missing > 0 then
        Log:debug("RLMenuHerdsmanFrame.buildAnimalTypeIndexMap: %d/%d declared type(s) absent from this map [%s]; the gate treats each as no-match",
            #missing, #names, table.concat(missing, ","))
    end
    Log:trace("RLMenuHerdsmanFrame.buildAnimalTypeIndexMap: resolved [%s]", table.concat(resolved, " "))
    return map
end

--- 1-based index of `value` in the ordered `values` array (==), or nil. The
--- index<->value bridge between the presenter's value domains and a MultiTextOption /
--- BinaryOption state.
---@param values table
---@param value any
---@return number|nil
local function indexOfValue(values, value)
    if type(values) ~= "table" then return nil end
    for i, v in ipairs(values) do
        if v == value then return i end
    end
    return nil
end

--- Caret-safe programmatic setText for a TextInput: a value push resets the caret to
--- text-end, which stomps the user mid-edit. Skip the push when the input owns focus AND
--- the text already matches (the overlay already captures the pending edit). Mirrors
--- RLMenuSettingsFrame:renderEditor's name-input guard.
---@param input table|nil TextInput element
---@param desired string|nil
local function setTextCaretSafe(input, desired)
    if input == nil then return end
    desired = desired or ""
    local isFocused = input.getIsFocused ~= nil and input:getIsFocused()
    local current = input.getText ~= nil and input:getText() or nil
    if isFocused and current == desired then return end
    input:setText(desired)
end

--- setVisible the whole row container (widget + its sibling title) so a hidden param
--- never leaves a dangling label.
---@param row table|nil row container element
---@param visible any truthy -> visible
local function setRowVisible(row, visible)
    if row ~= nil then row:setVisible(visible == true) end
end

--- Force a BinaryOption's green slider onto `targetState`, even when the toggle already
--- reports that state. A bare BinaryOptionElement:setState(target) short-circuits on
--- `state == self.state` and never runs updateSelection, so it cannot re-seat a slider that
--- was stranded while the row was hidden (a freshly-cloned toggle starts at state 1, so
--- pushing the state-1 default is inert). Toggle THROUGH the opposite state so the terminal
--- push is always a real change: updateSelection then points sliderMovingDirection at the
--- target and skipAnimation (3rd arg) snaps it in the next update(dt). Both pushes are
--- forceEvent=false, so MultiTextOptionElement:setState never raises the click callback -
--- the frame's onRule*Changed handlers do not fire and no pending edit is stashed.
--- CALL ONLY ON A VISIBLE toggle: a hidden BinaryOption gets no update(dt)
--- (getIsActiveNonRec == getIsVisibleNonRec), so a push there strands until it next shows.
--- NOTE: the toggle-through performs TWO real state changes, so it emits two notifyIndexChange
--- notifications per seat (MultiTextOptionElement:setState notifies on any change, regardless of
--- forceEvent). Harmless for these op-param toggles (no IndexChangeSubjectMixin observers) - but
--- do NOT attach an index-change observer (e.g. a page-dot indicator) to a toggle seated this way.
---@param toggle table|nil BinaryOptionElement
---@param targetState number BinaryOptionElement.STATE_LEFT (1) or STATE_RIGHT (2)
local function forceSeatToggle(toggle, targetState)
    if toggle == nil or toggle.setState == nil then return end
    local opposite = targetState == BinaryOptionElement.STATE_RIGHT
        and BinaryOptionElement.STATE_LEFT or BinaryOptionElement.STATE_RIGHT
    toggle:setState(opposite, false, true)
    toggle:setState(targetState, false, true)
end

--- Injected filter resolver for the presenter summaries / D5 revalidation / semen
--- animalType gate. nil-safe: a missing service or unknown id -> nil (the presenter then
--- substitutes labels.missing / labels.none).
---@param filterId any
---@return table|nil filter record
local function resolveFilterById(filterId)
    if filterId == nil or g_rlFilterService == nil then return nil end
    return g_rlFilterService:getById(filterId)
end

--- Injected placeable-name resolver for the target summary AND the move destination button.
--- Resolves the rule's stored key (uniqueId on server, net-object-id on a pure client) via
--- RLHusbandryTargetKey.resolveDestination - the move-dest opt-in that also admits an EPP butcher on
--- the client, so the destination button renders the butcher name (targets are always husbandries, so
--- widening is a no-op for them). An EPP-shaped resolved placeable gets the shared "(butcher)" suffix
--- (RLAnimalQuery.composeDestinationLabel) so the button label agrees with the picker rows.
--- NIL-GUARDED: a deleted / stale / unresolvable key returns nil (NOT a crash) so the presenter
--- substitutes labels.missing - resolveDestination stays quiet on a clean not-found, so this
--- render-path resolver does not spam the log.
---@param key any stable target/dest key (uniqueId server / net-object-id client)
---@return string|nil placeable name (with the "(butcher)" suffix for an EPP dest)
local function resolvePlaceableName(key)
    local placeable = RLHusbandryTargetKey.resolveDestination(key)
    if placeable == nil or placeable.getName == nil then return nil end
    local isEPP = placeable.spec_extendedProductionPoint ~= nil
    return RLAnimalQuery.composeDestinationLabel(placeable:getName(), isEPP)
end

--- Multiset (order-insensitive) equality of two arrays of plain strings, for the husbandry-
--- pick no-op check. The picker commits in name-sorted DOMAIN order, which can differ from the
--- stored array order even when the membership is identical; comparing as SETS avoids a
--- spurious re-order stash -> flush -> MP broadcast on an OK that changed nothing. Counts
--- duplicates so a genuine add/remove still registers. nil-safe.
---@param a any
---@param b any
---@return boolean
local function sameStringSet(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then return a == b end
    if #a ~= #b then return false end
    local counts = {}
    for _, v in ipairs(a) do counts[v] = (counts[v] or 0) + 1 end
    for _, v in ipairs(b) do
        local n = counts[v]
        if n == nil or n == 0 then return false end
        counts[v] = n - 1
    end
    return true
end

--- Construct a new RLMenuHerdsmanFrame instance.
--- Called once by setupGui() during mod load.
--- @return table self The new frame instance
function RLMenuHerdsmanFrame.new()
    local self = RLMenuHerdsmanFrame:superClass().new(nil, RLMenuHerdsmanFrame_mt)
    self.name = "RLMenuHerdsmanFrame"
    self.isFrameOpen = false
    -- One-shot guard for the layout measurement: reset on every onFrameOpen,
    -- flipped once the stretched containers report settled sizes (see update).
    self.didMeasureLayout = false
    -- Open-time stored rule snapshot (the flush baseline; F7 owns refresh-while-open),
    -- the sectioned DISPLAY model (overlay-merged), per-id pending edit overlays, the
    -- current selection id, the reload re-entry guard, and a one-shot first-row log guard.
    self.storedRules = {}
    self.sections = {}
    self.pendingChanges = {}
    self.selectedRuleId = nil
    -- The rule id captured when the filter picker OPENS; the pick stashes against THIS id even
    -- if the list selection moves while the modal is up (cleared by onFilterPicked).
    self.filterPickTargetId = nil
    -- The same capture for the husbandry picker (cleared by onHusbandriesPicked / onFrameClose).
    self.husbandryPickTargetId = nil
    -- The same capture for the single-select destination picker (cleared by onDestinationPicked).
    self.destinationPickTargetId = nil
    self.isReconciling = false
    -- Set while refreshRuleDetail pushes values into the editor widgets: the three rule
    -- TextInput handlers early-return on it so a programmatic setText (which fires
    -- onTextChanged on a value change) is not mistaken for a user edit (mirrors the option
    -- widgets' setState(idx, false) suppression).
    self.isPopulating = false
    self.didMeasureFirstRow = false
    -- One-shot seat-observation guard: armed per selection by refreshRuleDetail,
    -- drained at the update seam once the re-seated op-param sliders settle. Starts drained.
    self.didLogSeat = true
    self.seatLogExpected = nil
    Log:trace("RLMenuHerdsmanFrame.new: instance created")
    return self
end

--- Load the herdsman frame XML and register the frame with g_gui.
--- Called from RLMenu.setupGui() before the menu XML is loaded so that
--- rlMenu.xml's FrameReference ref="RLMenuHerdsmanFrame" resolves.
function RLMenuHerdsmanFrame.setupGui()
    local frame = RLMenuHerdsmanFrame.new()
    g_gui:loadGui(
        Utils.getFilename("gui/rlmenu/herdsmanFrame.xml", modDirectory),
        "RLMenuHerdsmanFrame",
        frame,
        true  -- frame-only load
    )
    Log:debug("RLMenuHerdsmanFrame.setupGui: registered")
end

--- Resolve element references, bind the rule list, and seed the fixed-domain selector
--- option texts (operation / enabled / mark / convention / budget-type / budget-percentage)
--- once after XML parsing. The semen selector is rebuilt per render (live dewar pool).
function RLMenuHerdsmanFrame:onGuiSetupFinished()
    RLMenuHerdsmanFrame:superClass().onGuiSetupFinished(self)

    self.rulesList           = self:getDescendantById("rulesList")
    self.rulesListContainer  = self:getDescendantById("rulesListContainer")
    self.rulesSliderBox      = self:getDescendantById("rulesSliderBox")
    self.ruleEditorContainer = self:getDescendantById("ruleEditorContainer")
    self.rulesEmptyState     = self:getDescendantById("rulesEmptyState")
    self.headerPanel         = self:getDescendantById("headerPanel")
    -- Legacy-active coexistence banner (D13): a fixed-text warning in the header, below the
    -- title. Hidden by default; refreshBanner toggles it. nil until the XML element ships.
    self.legacyBanner        = self:getDescendantById("legacyBanner")

    -- Editor layout + empty-state (toggled together: a selection shows the layout,
    -- no selection shows the empty text).
    self.ruleEditorLayout = self:getDescendantById("ruleEditorLayout")
    self.ruleEditorEmpty  = self:getDescendantById("ruleEditorEmpty")

    -- Row containers (setVisible targets these so the title hides with the widget).
    self.ruleNameRow              = self:getDescendantById("ruleNameRow")
    self.ruleOperationRow         = self:getDescendantById("ruleOperationRow")
    self.ruleEnabledRow           = self:getDescendantById("ruleEnabledRow")
    self.ruleMaxAnimalsRow        = self:getDescendantById("ruleMaxAnimalsRow")
    self.ruleMarkRow              = self:getDescendantById("ruleMarkRow")
    self.ruleConventionRow        = self:getDescendantById("ruleConventionRow")
    self.ruleBudgetTypeRow        = self:getDescendantById("ruleBudgetTypeRow")
    self.ruleBudgetFixedRow       = self:getDescendantById("ruleBudgetFixedRow")
    self.ruleBudgetPercentageRow  = self:getDescendantById("ruleBudgetPercentageRow")
    self.ruleSemenRow             = self:getDescendantById("ruleSemenRow")
    self.ruleFilterRow            = self:getDescendantById("ruleFilterRow")
    self.ruleHusbandriesRow       = self:getDescendantById("ruleHusbandriesRow")
    self.ruleDestinationRow       = self:getDescendantById("ruleDestinationRow")

    -- Widgets.
    self.ruleNameInput               = self:getDescendantById("ruleNameInput")
    self.ruleOperationSelector       = self:getDescendantById("ruleOperationSelector")
    self.ruleEnabledToggle           = self:getDescendantById("ruleEnabledToggle")
    self.ruleMaxAnimalsInput         = self:getDescendantById("ruleMaxAnimalsInput")
    self.ruleMarkToggle              = self:getDescendantById("ruleMarkToggle")
    self.ruleConventionToggle        = self:getDescendantById("ruleConventionToggle")
    self.ruleBudgetTypeToggle        = self:getDescendantById("ruleBudgetTypeToggle")
    self.ruleBudgetFixedInput        = self:getDescendantById("ruleBudgetFixedInput")
    self.ruleBudgetPercentageSelector= self:getDescendantById("ruleBudgetPercentageSelector")
    self.ruleSemenSelector           = self:getDescendantById("ruleSemenSelector")
    self.ruleFilterButton            = self:getDescendantById("ruleFilterButton")
    self.ruleHusbandriesButton       = self:getDescendantById("ruleHusbandriesButton")
    self.ruleDestinationButton       = self:getDescendantById("ruleDestinationButton")

    local missing = {}
    if self.rulesList == nil then table.insert(missing, "rulesList") end
    if self.ruleEditorContainer == nil then table.insert(missing, "ruleEditorContainer") end
    if self.ruleEditorLayout == nil then table.insert(missing, "ruleEditorLayout") end
    if self.ruleNameInput == nil then table.insert(missing, "ruleNameInput") end
    if self.ruleOperationSelector == nil then table.insert(missing, "ruleOperationSelector") end
    if #missing > 0 then
        Log:warning("RLMenuHerdsmanFrame:onGuiSetupFinished: missing elements: %s",
            table.concat(missing, ", "))
    end

    -- Cache the presenter value domains once (fresh arrays; used for index<->value).
    self.conventionValues       = RLHerdsmanRulePresenter.getConventionValues()
    self.budgetTypeValues       = RLHerdsmanRulePresenter.getBudgetTypeValues()
    self.budgetPercentageValues = RLHerdsmanRulePresenter.getBudgetPercentageValues()
    -- semenValues is rebuilt per render in populateSemenSelector.
    self.semenValues = { RLHerdsmanRulePresenter.SEMEN_ANY }

    -- Seed the fixed-domain selector texts once. Operation = the section labels in
    -- OPERATION_ORDER; the binary on/off + 2-value option labels reuse existing i18n;
    -- budget-percentage = the frame's tostring(v).."%" render of the whitelist.
    if self.ruleOperationSelector ~= nil then
        local opTexts = {}
        for i, op in ipairs(RLHerdsmanRulePresenter.OPERATION_ORDER) do
            -- An operation without a section title key (a not-yet-UI-wired op) falls back to its
            -- raw name instead of crashing getText on a nil key - mirrors the nil-key guard in
            -- getTitleForSectionHeader. The real label is seeded when that op's UI is wired.
            local key = OPERATION_TITLE_KEY[op]
            opTexts[i] = key ~= nil and g_i18n:getText(key) or op
        end
        self.ruleOperationSelector:setTexts(opTexts)
    end
    if self.ruleEnabledToggle ~= nil then
        self.ruleEnabledToggle:setTexts({
            g_i18n:getText("setting_disasterDestructionState_disabled"),
            g_i18n:getText("setting_disasterDestructionState_enabled"),
        })
    end
    if self.ruleMarkToggle ~= nil then
        -- The Mark row is the Action selector (decision 2b): state 1 Perform
        -- (mark=false), state 2 Mark only (mark=true). The manual per-animal Mark/Unmark button
        -- keeps reading the untouched rl_ui_mark / rl_ui_dontMark strings.
        self.ruleMarkToggle:setTexts({
            g_i18n:getText("rl_menu_herdsman_action_perform"),
            g_i18n:getText("rl_menu_herdsman_action_markOnly"),
        })
    end
    if self.ruleConventionToggle ~= nil then
        self.ruleConventionToggle:setTexts({
            g_i18n:getText("rl_button_random"),
            g_i18n:getText("rl_ui_alphabetical"),
        })
    end
    if self.ruleBudgetTypeToggle ~= nil then
        self.ruleBudgetTypeToggle:setTexts({
            g_i18n:getText("rl_ui_fixed"),
            g_i18n:getText("rl_ui_percentage"),
        })
    end
    if self.ruleBudgetPercentageSelector ~= nil then
        local pctTexts = {}
        for i, v in ipairs(self.budgetPercentageValues) do
            pctTexts[i] = tostring(v) .. "%"
        end
        self.ruleBudgetPercentageSelector:setTexts(pctTexts)
    end

    if self.rulesList ~= nil then
        self.rulesList:setDataSource(self)
        self.rulesList:setDelegate(self)
        Log:trace("RLMenuHerdsmanFrame:onGuiSetupFinished: rulesList bound")
    end

    -- Per-row tooltip help lines. The tooltip Text lives INSIDE each row's value widget
    -- (the legacy rl_aiTooltip home - the row container clips to its bounds, so a right-margin tooltip
    -- must hang off the non-clipping widget); getDescendantByName is recursive, so grabbing off the
    -- ROW still finds it wherever it sits in the row subtree (mirrors
    -- RLMenuSettingsFrame:populateGeneralSubtab). setVisible(true) on grab in case the profile
    -- defaults hidden (as legacy RealisticLivestock_AnimalScreen does). The text is (re)set per render
    -- in refreshRuleDetail via the pure RLHerdsmanRulePresenter.getTooltipDescriptor.
    self.tooltips = {}
    local function grabTooltip(row, field)
        if row == nil then return end
        local t = row:getDescendantByName("tooltip")
        if t == nil then
            Log:trace("RLMenuHerdsmanFrame:onGuiSetupFinished: row '%s' has no tooltip child", field)
            return
        end
        t:setVisible(true)
        self.tooltips[field] = t
    end
    grabTooltip(self.ruleOperationRow, "operation")
    grabTooltip(self.ruleNameRow, "name")
    grabTooltip(self.ruleEnabledRow, "enabled")
    grabTooltip(self.ruleMaxAnimalsRow, "maxAnimals")
    grabTooltip(self.ruleMarkRow, "mark")
    grabTooltip(self.ruleConventionRow, "convention")
    grabTooltip(self.ruleBudgetTypeRow, "budget|type")
    grabTooltip(self.ruleBudgetFixedRow, "budget|fixed")
    grabTooltip(self.ruleBudgetPercentageRow, "budget|percentage")
    grabTooltip(self.ruleSemenRow, "semen")
    grabTooltip(self.ruleFilterRow, "filter")
    grabTooltip(self.ruleHusbandriesRow, "husbandries")
    grabTooltip(self.ruleDestinationRow, "destination")

    -- Action bar (single-tier; no Filters Tier 2/3 - the herdsman frame has no conditions
    -- sub-list): Back / New / Duplicate / Delete. Code-driven footer (menuButtonInfo), not XML,
    -- mirroring RLMenuSettingsFrame; updateButtonVisibility rebuilds the set per selection +
    -- permission. hasCustomMenuButtons=true forces the first page-switch to use
    -- self.menuButtonInfo over RLMenu's back-only default (avoids a one-frame flicker).
    self.hasCustomMenuButtons = true
    self.backButtonInfo = { inputAction = InputAction.MENU_BACK }
    self.newRuleButtonInfo = {
        inputAction = InputAction.MENU_EXTRA_1,
        text = g_i18n:getText("rl_menu_herdsman_new_button"),
        callback = function() self:onClickNewRule() end,
    }
    self.duplicateButtonInfo = {
        inputAction = InputAction.MENU_EXTRA_2,
        text = g_i18n:getText("rl_menu_herdsman_duplicate_button"),
        callback = function() self:onClickDuplicate() end,
    }
    self.deleteButtonInfo = {
        inputAction = InputAction.MENU_CANCEL,
        text = g_i18n:getText("rl_menu_herdsman_delete_button"),
        callback = function() self:onClickDelete() end,
    }
    self.menuButtonInfo = { self.backButtonInfo }
end

--- Called by the Paging element when this tab becomes active. Reads the rule registry,
--- builds the display sections, reloads the list, seeds the initial selection, and focuses
--- the list. Pending edits reset per open (this frame is a fresh edit session; F7 owns
--- refresh-while-open).
function RLMenuHerdsmanFrame:onFrameOpen()
    RLMenuHerdsmanFrame:superClass().onFrameOpen(self)
    self.isFrameOpen = true
    self.didMeasureLayout = false
    self.didMeasureFirstRow = false
    self.didMeasureFilterRow = false
    self.didMeasureHusbandriesRow = false
    self.didMeasureNameRow = false
    self.didMeasureMaxAnimalsRow = false
    self.didMeasureBudgetFixedRow = false
    -- Seat-observation guard: the seeded selection below re-arms it via
    -- refreshRuleDetail; start drained so a no-rule open logs nothing.
    self.didLogSeat = true
    self.seatLogExpected = nil
    self.pendingChanges = {}

    -- Real read path: F4 edits + F7 create/delete write back through the same
    -- g_rlHerdsmanRuleService, and MP syncs through it. RLHerdsmanRulePresenter owns
    -- grouping/order/sort. Dev rules are seeded with rlHerdsmanRuleCreate (SP).
    local farmId = RLAnimalInfoService.getCurrentFarmId()
    local rules = {}
    if farmId == nil or farmId == 0 then
        Log:debug("RLMenuHerdsmanFrame:onFrameOpen: no farm (farmId=%s); empty rule list", tostring(farmId))
    elseif g_rlHerdsmanRuleService == nil then
        Log:warning("RLMenuHerdsmanFrame:onFrameOpen: g_rlHerdsmanRuleService is nil; empty rule list (load-order regression?)")
    else
        rules = g_rlHerdsmanRuleService:listForFarm(farmId)
    end
    self.storedRules = rules
    self:rebuildDisplaySections()
    Log:debug("RLMenuHerdsmanFrame:onFrameOpen: farmId=%s, %d rule(s) -> %d section(s)", tostring(farmId), #rules, #self.sections)

    if self.rulesList ~= nil then
        self.rulesList:reloadData()
    end
    self:updateEmptyState()
    self:selectInitialRule()
    self:updateButtonVisibility()
    self:refreshBanner(farmId)

    if self.rulesList ~= nil then
        FocusManager:setFocus(self.rulesList)
    end
end

--- Called by the Paging element when this tab is deactivated. Clears isFrameOpen BEFORE
--- draining the pending overlays: g_rlHerdsmanRuleService:update dispatches an Update
--- event on success, and a remote rebroadcast arriving mid-flush would re-enter the
--- refresh path and fight the drain loop. Clearing the flag first closes that window
--- (mirrors RLMenuSettingsFrame:onFrameClose's ordering invariant).
function RLMenuHerdsmanFrame:onFrameClose()
    RLMenuHerdsmanFrame:superClass().onFrameClose(self)
    self.isFrameOpen = false
    self:flushAllPending()
    -- Drop any picker open-time id (an ESC/back dismiss closes the dialog without firing the
    -- cancel callback, so it would otherwise dangle until the next open re-captures it).
    self.filterPickTargetId = nil
    self.husbandryPickTargetId = nil
    self.destinationPickTargetId = nil
    Log:trace("RLMenuHerdsmanFrame:onFrameClose")
end

--- Per-frame hook. Emits the one-shot layout measurement once the stretched containers
--- have settled; the guard resets on each onFrameOpen so reopening re-measures.
function RLMenuHerdsmanFrame:update(dt)
    RLMenuHerdsmanFrame:superClass().update(self, dt)
    if not self.didMeasureLayout and self:logLayoutMeasurements() then
        self.didMeasureLayout = true
    end
    -- Drain the one-shot op-param seat proof once the re-seated sliders settle. The
    -- physical move ran in the child BinaryOptionElement:update above (superClass:update), so a
    -- settle-retry (mirrors logLayoutMeasurements) observes the final position, not mid-slide.
    if not self.didLogSeat and self:logToggleSeatOnce() then
        self.didLogSeat = true
    end
end

-- =============================================================================
-- LAYOUT MEASUREMENT (verification only - no layout decisions)
-- =============================================================================

--- Log the size + top edge of the list + editor containers plus the header panel's
--- bottom edge as the baseline, so the master-detail placement under the (tab-bar-less)
--- header is provable from the log. Returns true once BOTH stretched containers report
--- settled, non-zero sizes and the measurement was emitted; false while unsettled, so
--- update()'s one-shot guard retries. absPosition is the element's bottom edge (FS25
--- Y-up), so top = bottom + height; reference screen is 1920x1080.
--- @return boolean measured
function RLMenuHerdsmanFrame:logLayoutMeasurements()
    local function settled(e)
        return e ~= nil and e.size ~= nil and e.absPosition ~= nil
            and e.size[1] ~= nil and e.size[1] > 0
            and e.size[2] ~= nil and e.size[2] > 0
    end
    if not (settled(self.rulesListContainer) and settled(self.ruleEditorContainer)) then
        return false
    end

    local function logBox(name, e)
        Log:debug("RLMenuHerdsmanFrame: %s measured: %.1fpx x %.1fpx, top=%.1fpx",
            name,
            e.size[1] * g_referenceScreenWidth,
            e.size[2] * g_referenceScreenHeight,
            (e.absPosition[2] + e.size[2]) * g_referenceScreenHeight)
    end
    logBox("rulesListContainer", self.rulesListContainer)
    logBox("ruleEditorContainer", self.ruleEditorContainer)

    if self.headerPanel ~= nil and self.headerPanel.absPosition ~= nil then
        Log:debug("RLMenuHerdsmanFrame: header baseline bottom=%.1fpx",
            self.headerPanel.absPosition[2] * g_referenceScreenHeight)
    end

    -- Banner placement verification (it sits in the header, below the title): log its size +
    -- top edge so the orange caution's position is provable from the log, not eyeballed. Only
    -- meaningful when the banner is visible (enable a legacy op to surface it for measurement).
    if self.legacyBanner ~= nil and self.legacyBanner.absPosition ~= nil and self.legacyBanner.size ~= nil then
        Log:debug("RLMenuHerdsmanFrame: legacyBanner measured: %.1fpx x %.1fpx, top=%.1fpx, visible=%s",
            (self.legacyBanner.size[1] or 0) * g_referenceScreenWidth,
            (self.legacyBanner.size[2] or 0) * g_referenceScreenHeight,
            ((self.legacyBanner.absPosition[2] or 0) + (self.legacyBanner.size[2] or 0)) * g_referenceScreenHeight,
            tostring(self.legacyBanner.getIsVisible ~= nil and self.legacyBanner:getIsVisible()))
    end
    return true
end

--- One-shot proof that the op-param BinaryOption sliders seated on their stored option after a
--- refreshRuleDetail. Armed per selection (refreshRuleDetail fills seatLogExpected +
--- clears didLogSeat); drained here once every seated toggle's slider has SETTLED. The physical
--- move runs in BinaryOptionElement:update(dt) - applied this frame by superClass:update in the
--- update seam - so retry (return false) while any slider still moves, mirroring
--- logLayoutMeasurements' settle-retry. Proves POSITION (sliderState: 0=left, NUM_SLIDER_STATES=
--- right, plus the slider's screen-space left edge in px) AND each button's getIsSelected()
--- against the expected state; hidden toggles are never in the list. TRACE + one-shot, so
--- production INFO/WARN runs and idle frames stay quiet.
--- @return boolean logged true once emitted (or nothing to prove); false while a slider still moves
function RLMenuHerdsmanFrame:logToggleSeatOnce()
    local expected = self.seatLogExpected
    if expected == nil or #expected == 0 then return true end
    for _, entry in ipairs(expected) do
        local toggle = entry.toggle
        if toggle ~= nil and toggle.sliderMovingDirection ~= nil and toggle.sliderMovingDirection ~= 0 then
            return false
        end
    end
    for _, entry in ipairs(expected) do
        local toggle = entry.toggle
        if toggle ~= nil then
            local leftSel = toggle.leftButtonElement ~= nil and toggle.leftButtonElement.getIsSelected ~= nil
                and toggle.leftButtonElement:getIsSelected()
            local rightSel = toggle.rightButtonElement ~= nil and toggle.rightButtonElement.getIsSelected ~= nil
                and toggle.rightButtonElement:getIsSelected()
            local sliderPx = (toggle.sliderElement ~= nil and toggle.sliderElement.absPosition ~= nil)
                and (toggle.sliderElement.absPosition[1] * g_referenceScreenWidth) or -1
            Log:trace("RLMenuHerdsmanFrame: seat[%s] expected=%d state=%s sliderState=%s sliderLeftPx=%.1f leftSel=%s rightSel=%s",
                entry.name, entry.expected, tostring(toggle.state), tostring(toggle.sliderState),
                sliderPx, tostring(leftSel), tostring(rightSel))
        end
    end
    return true
end

-- =============================================================================
-- DISPLAY MODEL (stored snapshot + pending overlay -> sections)
-- =============================================================================

--- Rebuild the sectioned DISPLAY model from the stored snapshot with each rule's pending
--- overlay applied, so the list reflects live edits (a pending op-change moves the rule to
--- its new section; a pending name re-sorts within the section). buildSections owns all
--- grouping/order/sort. Called on open, op-change, and name-edit.
function RLMenuHerdsmanFrame:rebuildDisplaySections()
    local overlaid = {}
    for i, stored in ipairs(self.storedRules) do
        overlaid[i] = RLHerdsmanRuleEditModel.overlayRule(stored, self.pendingChanges[stored.id])
    end
    self.sections = RLHerdsmanRulePresenter.buildSections(overlaid)
end

--- Find the (section, index) of a rule id in the current display sections, or nil.
--- @param id any rule id
--- @return number|nil section
--- @return number|nil index
function RLMenuHerdsmanFrame:findSelectionById(id)
    for s, sec in ipairs(self.sections) do
        for i, rule in ipairs(sec.rules) do
            if rule.id == id then return s, i end
        end
    end
    return nil, nil
end

--- The stored (un-overlaid) baseline record for an id, from the open-time snapshot.
--- @param id any
--- @return table|nil
function RLMenuHerdsmanFrame:getStoredRuleById(id)
    for _, stored in ipairs(self.storedRules) do
        if stored.id == id then return stored end
    end
    return nil
end

--- Replace the stored snapshot entry for an id after a successful flush, so re-selecting
--- the rule renders the persisted values (the snapshot is otherwise open-time-only).
--- @param id any
--- @param record table the service's returned stored record
function RLMenuHerdsmanFrame:replaceStoredRule(id, record)
    for i, stored in ipairs(self.storedRules) do
        if stored.id == id then self.storedRules[i] = record; return end
    end
end

--- Rebuild the display sections, reload the list, and re-highlight `id` by id - all under
--- the isReconciling guard so the synchronous onListSelectionChanged does not re-enter the
--- editor render (caret stomp). Used after a name-edit and an op-change.
--- @param id any rule id to keep selected
function RLMenuHerdsmanFrame:refreshList(id)
    self:rebuildDisplaySections()
    if self.rulesList ~= nil then
        self.isReconciling = true
        self.rulesList:reloadData()
        local s, i = self:findSelectionById(id)
        if s ~= nil then
            self.rulesList:setSelectedItem(s, i, false, true)
        end
        self.isReconciling = false
    end
    self:updateEmptyState()
end

-- =============================================================================
-- SMOOTHLIST DATA SOURCE / DELEGATE (multi-section, display-model-backed)
-- =============================================================================

--- @param list table
--- @return number
function RLMenuHerdsmanFrame:getNumberOfSections(list)
    if list ~= self.rulesList then return 0 end
    return #self.sections
end

--- Localized section-header title = the operation label (localization wiring).
--- @param list table
--- @param section number
--- @return string|nil
function RLMenuHerdsmanFrame:getTitleForSectionHeader(list, section)
    if list ~= self.rulesList then return nil end
    local sec = self.sections[section]
    if sec == nil then return nil end
    local key = OPERATION_TITLE_KEY[sec.operation]
    if key == nil then return nil end
    return g_i18n:getText(key)
end

--- @param list table
--- @param section number
--- @return number
function RLMenuHerdsmanFrame:getNumberOfItemsInSection(list, section)
    if list ~= self.rulesList then return 0 end
    local sec = self.sections[section]
    return sec ~= nil and #sec.rules or 0
end

--- Populate one rule row. The display sections already carry the overlay-merged record,
--- so the row name reflects pending edits live (read element -> setText; no decisions).
--- @param list table
--- @param section number
--- @param index number
--- @param cell table
function RLMenuHerdsmanFrame:populateCellForItemInSection(list, section, index, cell)
    if list ~= self.rulesList then return end
    local sec = self.sections[section]
    if sec == nil then return end
    local rule = sec.rules[index]
    if rule == nil then return end

    local nameCell = cell:getAttribute("ruleName")
    if nameCell ~= nil then
        nameCell:setText(rule.name)
    end

    if not self.didMeasureFirstRow then
        self.didMeasureFirstRow = true
        local cellW = (cell.size and cell.size[1] or 0) * g_referenceScreenWidth
        local cellH = (cell.size and cell.size[2] or 0) * g_referenceScreenHeight
        Log:debug("RLMenuHerdsmanFrame:populateCellForItemInSection: first row (s=%d,i=%d) cell=%.1fx%.1fpx name=%q",
            section, index, cellW, cellH, tostring(rule.name))
    end
end

--- Selection delegate: autoflush the previously-selected rule, then store the new
--- selection id and refresh the detail pane from the STORED baseline (refreshRuleDetail
--- re-applies the overlay). Suppressed during a programmatic reload (isReconciling).
--- @param list table
--- @param section number
--- @param index number
function RLMenuHerdsmanFrame:onListSelectionChanged(list, section, index)
    if list ~= self.rulesList then return end
    if self.isReconciling then
        Log:trace("RLMenuHerdsmanFrame:onListSelectionChanged: suppressed during reconcile")
        return
    end

    -- Autoflush the previously-selected rule before advancing (advance is
    -- unconditional so a rejected flush does not strand the user on the dirty rule).
    local previousId = self.selectedRuleId
    if previousId ~= nil and self.pendingChanges[previousId] ~= nil then
        local outcome = self:flushPendingForId(previousId)
        Log:debug("RLMenuHerdsmanFrame:onListSelectionChanged: autoflush previousId=%s outcome=%s",
            tostring(previousId), tostring(outcome))
    end

    local sec = self.sections[section]
    local rule = sec ~= nil and sec.rules[index] or nil
    if rule == nil then
        self.selectedRuleId = nil
        Log:debug("RLMenuHerdsmanFrame:onListSelectionChanged: section=%s index=%s out of range; selection cleared",
            tostring(section), tostring(index))
        self:refreshRuleDetail(nil)
        self:updateButtonVisibility()
        return
    end

    self.selectedRuleId = rule.id
    Log:debug("RLMenuHerdsmanFrame:onListSelectionChanged: section=%d index=%d -> ruleId=%s name=%q",
        section, index, tostring(rule.id), tostring(rule.name))
    self:refreshRuleDetail(self:getStoredRuleById(rule.id))
    self:updateButtonVisibility()
end

-- =============================================================================
-- DETAIL PANE (read element -> presenter/edit-model call -> write element)
-- =============================================================================

--- Populate the rule editor from the overlay-merged record. The value pushes are
--- programmatic, not user edits: setState pushes are silent (forceEvent=false), but a
--- TextInput's setText fires onTextChanged on a value change, so they run under the
--- isPopulating guard and the three rule TextInput handlers early-return while it is set,
--- so a stale stored value snapping to a default is not persisted. Row visibility comes
--- from getParamVisibility + getBudgetFieldVisibility; the summaries from getFilterSummary
--- / getHusbandrySummary. nil rule -> hide the editor, show the empty-state.
--- @param stored table|nil the STORED rule record (overlay is re-applied here), or nil
function RLMenuHerdsmanFrame:refreshRuleDetail(stored)
    if stored == nil then
        setRowVisible(self.ruleEditorLayout, false)
        if self.ruleEditorEmpty ~= nil then self.ruleEditorEmpty:setVisible(true) end
        -- Disarm the seat proof: the editor (and its op-param toggles) is now hidden,
        -- so a still-armed seatLogExpected would drain stale proof for hidden toggles at the update
        -- seam. A real selection re-arms it.
        self.seatLogExpected = nil
        self.didLogSeat = true
        Log:debug("RLMenuHerdsmanFrame:refreshRuleDetail: no selection; editor hidden, empty-state shown")
        return
    end
    if self.ruleEditorEmpty ~= nil then self.ruleEditorEmpty:setVisible(false) end
    setRowVisible(self.ruleEditorLayout, true)

    local merged = RLHerdsmanRuleEditModel.overlayRule(stored, self.pendingChanges[stored.id])
    local op = merged.operation
    local p = merged.params or {}
    local budget = p.budget

    -- Op-param BinaryOption target states, derived ONCE here so the value push below, the
    -- visible-toggle re-seat, and the tooltip block all read one source and cannot
    -- drift. (budgetTypeState is only consumed when the budget row is visible, i.e. budget ~= nil.)
    local markState       = (p.mark == true) and 2 or 1
    local conventionState = indexOfValue(self.conventionValues, p.convention) or 1
    local budgetTypeState = indexOfValue(self.budgetTypeValues, budget and budget.type) or 1

    -- Values. These are programmatic pushes, NOT user edits: setState gates its callback on
    -- forceEvent (the false here is silent), but a TextInput's setText fires onTextChanged on
    -- a value change, so the whole push block runs under isPopulating and the three rule
    -- TextInput handlers early-return while it is set. save/restore keeps it reentrancy-safe
    -- (refreshRuleDetail is re-entered from genuine option edits, whose re-render text pushes
    -- are also not user edits); the pcall + unconditional reset guarantees the flag is cleared
    -- even if an engine layout push raises - then re-raise to preserve today's propagation.
    local wasPopulating = self.isPopulating
    self.isPopulating = true
    local pushOk, pushErr = pcall(function()
        setTextCaretSafe(self.ruleNameInput, merged.name or "")
        if self.ruleOperationSelector ~= nil then
            self.ruleOperationSelector:setState(indexOfValue(RLHerdsmanRulePresenter.OPERATION_ORDER, op) or 1, false)
        end
        if self.ruleEnabledToggle ~= nil then
            self.ruleEnabledToggle:setState(merged.enabled == true and 2 or 1, false)
        end
        setTextCaretSafe(self.ruleMaxAnimalsInput, p.maxAnimals ~= nil and tostring(p.maxAnimals) or "")
        if self.ruleMarkToggle ~= nil then
            self.ruleMarkToggle:setState(markState, false)
        end
        if self.ruleConventionToggle ~= nil then
            self.ruleConventionToggle:setState(conventionState, false)
        end
        -- Budget widgets: ALWAYS push a deterministic state (a malformed buy rule with no
        -- budget table must never show a stale toggle/input); real values only when a budget
        -- table exists.
        if self.ruleBudgetTypeToggle ~= nil then
            self.ruleBudgetTypeToggle:setState(budgetTypeState, false)
        end
        setTextCaretSafe(self.ruleBudgetFixedInput, (budget and budget.fixed ~= nil) and tostring(budget.fixed) or "")
        if self.ruleBudgetPercentageSelector ~= nil then
            self.ruleBudgetPercentageSelector:setState(indexOfValue(self.budgetPercentageValues, budget and budget.percentage) or 1, false)
        end
        self:populateSemenSelector(merged)
    end)
    self.isPopulating = wasPopulating
    if not pushOk then
        Log:error("RLMenuHerdsmanFrame:refreshRuleDetail: populate push error: %s", tostring(pushErr))
        error(pushErr)
    end

    -- Visibility.
    local vis = RLHerdsmanRulePresenter.getParamVisibility(op)
    setRowVisible(self.ruleMaxAnimalsRow, vis.maxAnimals)
    setRowVisible(self.ruleMarkRow, vis.mark)
    setRowVisible(self.ruleConventionRow, vis.convention)
    setRowVisible(self.ruleSemenRow, vis.semen)
    setRowVisible(self.ruleFilterRow, vis.filter)
    setRowVisible(self.ruleDestinationRow, vis.destination)
    setRowVisible(self.ruleBudgetTypeRow, vis.budget and budget ~= nil)
    local bvis = (vis.budget and budget ~= nil)
        and RLHerdsmanRulePresenter.getBudgetFieldVisibility(budget.type)
        or { fixed = false, percentage = false }
    setRowVisible(self.ruleBudgetFixedRow, bvis.fixed)
    setRowVisible(self.ruleBudgetPercentageRow, bvis.percentage)

    -- Op-param BinaryOption seating. The value pushes above ran while these rows
    -- still carried the PREVIOUS rule's visibility, and BinaryOptionElement:setState short-
    -- circuits on state == self.state, so a hidden or same-value push leaves the green slider
    -- stranded on the wrong option. Now that visibility is final, re-seat every currently-
    -- VISIBLE op-param toggle on its stored state via forceSeatToggle (toggle-through +
    -- skipAnimation). A hidden toggle is left untouched - it gets no update(dt), so seating it
    -- would re-strand the next show; it re-seats when it next becomes visible. Uses the same
    -- hoisted *State locals as the value push and the tooltip block (one source, no drift). The
    -- pushes stay forceEvent=false inside isPopulating so no pending edit is stashed.
    local seatWasPopulating = self.isPopulating
    self.isPopulating = true
    local seatOk, seatErr = pcall(function()
        if vis.mark and self.ruleMarkToggle ~= nil then
            forceSeatToggle(self.ruleMarkToggle, markState)
        end
        if vis.convention and self.ruleConventionToggle ~= nil then
            forceSeatToggle(self.ruleConventionToggle, conventionState)
        end
        if (vis.budget and budget ~= nil) and self.ruleBudgetTypeToggle ~= nil then
            forceSeatToggle(self.ruleBudgetTypeToggle, budgetTypeState)
        end
    end)
    self.isPopulating = seatWasPopulating
    if not seatOk then
        Log:error("RLMenuHerdsmanFrame:refreshRuleDetail: op-param toggle re-seat error: %s", tostring(seatErr))
    end

    -- Arm the one-shot seat-observation log, drained at the update seam once the sliders settle.
    -- Only currently-VISIBLE op-param toggles are proven; hidden ones are excluded (nothing to
    -- prove while they receive no update). An unknown op hides all three -> empty list -> no log.
    local seatLog = {}
    if vis.mark and self.ruleMarkToggle ~= nil then
        seatLog[#seatLog + 1] = { name = "mark", toggle = self.ruleMarkToggle, expected = markState }
    end
    if vis.convention and self.ruleConventionToggle ~= nil then
        seatLog[#seatLog + 1] = { name = "convention", toggle = self.ruleConventionToggle, expected = conventionState }
    end
    if (vis.budget and budget ~= nil) and self.ruleBudgetTypeToggle ~= nil then
        seatLog[#seatLog + 1] = { name = "budgetType", toggle = self.ruleBudgetTypeToggle, expected = budgetTypeState }
    end
    self.seatLogExpected = seatLog
    self.didLogSeat = false

    -- Read-only summaries.
    local labels = {
        none    = g_i18n:getText("rl_menu_herdsman_detail_none"),
        missing = g_i18n:getText("rl_menu_herdsman_detail_missing"),
    }
    if self.ruleFilterButton ~= nil then
        -- Button label: the bound filter's name, or a "Select filter" CTA when nothing usable
        -- is bound (nil OR deleted / out-of-scope). On an actionable button both empty states
        -- invite a pick, so they collapse to one CTA - unlike the read-only husbandries summary
        -- below, which keeps the (none) / (missing) wording.
        local selectText = g_i18n:getText("rl_menu_herdsman_filter_select")
        self.ruleFilterButton:setText(RLHerdsmanRulePresenter.getFilterSummary(
            merged.filterId, resolveFilterById, { none = selectText, missing = selectText }))
    end
    -- One-shot screen-space geometry of the (interactive) Filter row, so the in-row button
    -- vs title layout is provable from the log. absPosition is the element's bottom-left edge
    -- (FS25 Y-up); reference screen 1920x1080. Per-open guard.
    if vis.filter and not self.didMeasureFilterRow
        and self.ruleFilterRow ~= nil and self.ruleFilterRow.elements ~= nil then
        self.didMeasureFilterRow = true
        for _, e in ipairs(self.ruleFilterRow.elements) do
            if e.absPosition ~= nil and e.size ~= nil then
                local x = e.absPosition[1] * g_referenceScreenWidth
                local w = e.size[1] * g_referenceScreenWidth
                Log:debug("RLMenuHerdsmanFrame: ruleFilterRow child profile=%s: left=%.1fpx width=%.1fpx right=%.1fpx",
                    tostring(e.profile), x, w, x + w)
            end
        end
    end
    if self.ruleHusbandriesButton ~= nil then
        -- Button label: 0 targets -> a "select husbandries" CTA (mirrors the Filter button's
        -- empty CTA); 1 -> that husbandry's resolved name (or (missing)); >= 2 -> "N selected"
        -- (the count form; the full name list is the deferred Ask-First area below).
        local selectText = g_i18n:getText("rl_menu_herdsman_husbandry_select")
        self.ruleHusbandriesButton:setText(RLHerdsmanRulePresenter.formatHusbandryButtonLabel(
            merged.targetHusbandries, resolvePlaceableName, {
                none     = selectText,
                missing  = labels.missing,
                selected = g_i18n:getText("rl_menu_herdsman_husbandry_count"),
            }))
    end
    -- One-shot screen-space geometry of the (interactive, always-visible) Husbandries row, so
    -- the in-row button vs title layout is provable from the log. absPosition is the element's
    -- bottom-left edge (FS25 Y-up); reference screen 1920x1080. Per-open guard (mirror the
    -- Filter row measurement above).
    if not self.didMeasureHusbandriesRow
        and self.ruleHusbandriesRow ~= nil and self.ruleHusbandriesRow.elements ~= nil then
        self.didMeasureHusbandriesRow = true
        for _, e in ipairs(self.ruleHusbandriesRow.elements) do
            if e.absPosition ~= nil and e.size ~= nil then
                local x = e.absPosition[1] * g_referenceScreenWidth
                local w = e.size[1] * g_referenceScreenWidth
                Log:debug("RLMenuHerdsmanFrame: ruleHusbandriesRow child profile=%s: left=%.1fpx width=%.1fpx right=%.1fpx",
                    tostring(e.profile), x, w, x + w)
            end
        end
    end

    if self.ruleDestinationButton ~= nil then
        -- Button label (move only): the chosen destination husbandry name, a "Select destination"
        -- CTA when none is picked (the blank-trim CTA), or (missing) for an unresolvable stored dest.
        local selectText = g_i18n:getText("rl_menu_herdsman_destination_select")
        self.ruleDestinationButton:setText(RLHerdsmanRulePresenter.formatDestinationButtonLabel(
            p.destinationHusbandry, resolvePlaceableName, { none = selectText, missing = labels.missing }))
    end
    -- One-shot screen-space geometry of the Destination row (mirror the Husbandries row), so the
    -- in-row button vs title layout is provable from the log. Per-open guard; only when shown.
    if vis.destination and not self.didMeasureDestinationRow
        and self.ruleDestinationRow ~= nil and self.ruleDestinationRow.elements ~= nil then
        self.didMeasureDestinationRow = true
        for _, e in ipairs(self.ruleDestinationRow.elements) do
            if e.absPosition ~= nil and e.size ~= nil then
                local x = e.absPosition[1] * g_referenceScreenWidth
                local w = e.size[1] * g_referenceScreenWidth
                Log:debug("RLMenuHerdsmanFrame: ruleDestinationRow child profile=%s: left=%.1fpx width=%.1fpx right=%.1fpx",
                    tostring(e.profile), x, w, x + w)
            end
        end
    end

    -- Per-row help text. Re-resolved every render (op-dynamic: an op-change swaps the
    -- strings); the always-visible rows set unconditionally, the conditional rows only when their
    -- row is shown (the SAME gating as the setVisible toggles above). Content + arg come from the
    -- pure RLHerdsmanRulePresenter.getTooltipDescriptor; the frame formats the live value per arg.
    local enabledState    = (merged.enabled == true) and 2 or 1
    -- markState / conventionState / budgetTypeState are hoisted to the top of refreshRuleDetail
    -- (one source shared by the value push, the seat, and this tooltip block; they cannot drift).
    -- Resolve semen from the SELECTOR's snapped index, not raw p.semen: populateSemenSelector
    -- snaps a stale / absent dewar id to "any" (state 1), so the tooltip key family AND the option
    -- label must follow the DISPLAYED option - else a stale dewar yields the dewar tooltip ("...from
    -- %s") filled with the fallback "any" label, disagreeing with what the selector shows.
    local semenIdx        = indexOfValue(self.semenValues, p.semen or RLHerdsmanRulePresenter.SEMEN_ANY) or 1
    local semenValue      = self.semenValues[semenIdx] or RLHerdsmanRulePresenter.SEMEN_ANY
    local semenOptionText = (self.semenTexts ~= nil and self.semenTexts[semenIdx]) or ""

    local tipKeys = {}
    local function tip(field, state, value, raw)
        local key = self:applyRowTooltip(self.tooltips[field], field, op, state, value, raw)
        if key ~= nil then tipKeys[#tipKeys + 1] = field .. "=" .. key end
    end
    tip("operation")
    tip("name")
    tip("enabled", enabledState)
    tip("husbandries")
    if vis.maxAnimals then tip("maxAnimals", nil, nil, p.maxAnimals) end
    if vis.mark then tip("mark", markState) end
    if vis.convention then tip("convention", conventionState) end
    if vis.semen then tip("semen", nil, semenValue, semenOptionText) end
    if vis.filter then tip("filter") end
    if vis.destination then tip("destination") end
    if vis.budget and budget ~= nil then tip("budget|type", budgetTypeState) end
    if bvis.fixed then tip("budget|fixed", nil, nil, budget and budget.fixed) end
    if bvis.percentage then tip("budget|percentage", nil, nil, budget and budget.percentage) end
    Log:debug("RLMenuHerdsmanFrame:refreshRuleDetail: tooltips op=%s keys[%s]", tostring(op), table.concat(tipKeys, " "))

    -- One-shot in-row geometry of the TextInput rows + their tooltip Text (Ask-First:
    -- does fs25_multiTextOptionTooltip anchor cleanly inside a TextInput row?). Per-open guards.
    self:logTooltipRowGeometryOnce("ruleNameRow", self.ruleNameRow, self.tooltips["name"], "didMeasureNameRow")
    if vis.maxAnimals then
        self:logTooltipRowGeometryOnce("ruleMaxAnimalsRow", self.ruleMaxAnimalsRow, self.tooltips["maxAnimals"], "didMeasureMaxAnimalsRow")
    end
    if bvis.fixed then
        self:logTooltipRowGeometryOnce("ruleBudgetFixedRow", self.ruleBudgetFixedRow, self.tooltips["budget|fixed"], "didMeasureBudgetFixedRow")
    end

    -- Tint the visible rows (dark alternating settings shade) AND reflow the layout so the
    -- per-operation hidden rows collapse instead of leaving gaps. MUST run after the
    -- setVisible toggles above (mirror RLMenuSettingsFrame:renderEditor).
    self:updateAlternatingElements(self.ruleEditorLayout)

    Log:debug("RLMenuHerdsmanFrame:refreshRuleDetail: ruleId=%s op=%s visible[maxAnimals=%s mark=%s convention=%s budget=%s budgetFixed=%s budgetPct=%s semen=%s filter=%s]",
        tostring(merged.id), tostring(op), tostring(vis.maxAnimals), tostring(vis.mark),
        tostring(vis.convention), tostring(vis.budget), tostring(bvis.fixed), tostring(bvis.percentage),
        tostring(vis.semen), tostring(vis.filter))
end

--- Format a live param value into a tooltip string's single `%s`, per the presenter descriptor's
--- `arg`. number -> g_i18n:formatNumber; money -> g_i18n:formatMoney; percent -> the selector's
--- displayed "N%" (indexOfValue(...) or 1 mirrors how refreshRuleDetail seeds the percentage
--- selector, so a nil/non-member percentage reads the selector's current/first whitelist value,
--- not a bare 0); option -> the semen selector's current option label (passed in). Unknown arg -> "".
--- @param arg string|nil descriptor arg
--- @param raw any the live value (number for number/money/percent; option label for option)
--- @return string formatted
function RLMenuHerdsmanFrame:formatTooltipArg(arg, raw)
    if arg == "number" then
        return g_i18n:formatNumber(tonumber(raw) or 0, 0)
    elseif arg == "money" then
        return g_i18n:formatMoney(tonumber(raw) or 0, 0, true)
    elseif arg == "percent" then
        local pct = self.budgetPercentageValues[indexOfValue(self.budgetPercentageValues, tonumber(raw)) or 1]
        return tostring(pct or 0) .. "%"
    elseif arg == "option" then
        return tostring(raw or "")
    end
    return ""
end

--- Resolve + write ONE detail row's tooltip from the pure presenter descriptor. Reads the
--- descriptor for (op, field, state, value); arg=nil writes getText(key) verbatim, else
--- string.format(getText(key), formatTooltipArg(arg, raw)). A nil descriptor (the presenter
--- already trace-logged why) or a missing tooltip element writes nothing. Returns the written
--- key (or nil) for refreshRuleDetail's per-render summary log. Mirrors the Settings frame's
--- per-render tooltip:setText (RLMenuSettingsFrame:refreshGeneralSubtab), NOT the legacy
--- focus-gated updateTooltip.
--- @param tooltipElem table|nil the row's tooltip Text element
--- @param field string row field token
--- @param op string rule operation
--- @param state any selector state (state-keyed rows)
--- @param value any live value used by the descriptor (semen any-vs-dewar)
--- @param raw any live value to format into %s (per descriptor arg)
--- @return string|nil key the written i18n key, or nil
function RLMenuHerdsmanFrame:applyRowTooltip(tooltipElem, field, op, state, value, raw)
    if tooltipElem == nil then return nil end
    local d = RLHerdsmanRulePresenter.getTooltipDescriptor(op, field, state, value)
    if d == nil then return nil end
    if d.arg == nil then
        tooltipElem:setText(g_i18n:getText(d.key))
    else
        tooltipElem:setText(string.format(g_i18n:getText(d.key), self:formatTooltipArg(d.arg, raw)))
    end
    return d.key
end

--- Live-update ONE value-row's tooltip after a TextInput edit, WITHOUT a full refreshRuleDetail -
--- a re-render would push setText(tostring(tonumber(typed))) into the FOCUSED input and stomp the
--- caret on partial input ("05", "5."). Resolves the merged operation for the current selection,
--- then re-resolves just that row's tooltip via applyRowTooltip with the freshly-typed value.
--- No-op if nothing is selected / the rule is not in the snapshot.
--- @param field string the row field token ("maxAnimals" | "budget|fixed")
--- @param raw any the live value to format into the tooltip %s
function RLMenuHerdsmanFrame:refreshValueRowTooltip(field, raw)
    local id = self.selectedRuleId
    if id == nil then return end
    local stored = self:getStoredRuleById(id)
    if stored == nil then return end
    local merged = RLHerdsmanRuleEditModel.overlayRule(stored, self.pendingChanges[id])
    self:applyRowTooltip(self.tooltips[field], field, merged.operation, nil, nil, raw)
end

--- One-shot geometry of a TextInput editor row + its tooltip Text, so the Ask-First (does
--- fs25_multiTextOptionTooltip anchor cleanly inside a TextInput row?) is provable from the log,
--- not eyeballed. Mirrors the Filter/Husbandries/Destination row measurement (absPosition is the
--- element's bottom-left edge, FS25 Y-up; reference screen 1920x1080). Per-open guard via
--- `guardField` (reset in onFrameOpen).
--- @param rowName string log label
--- @param row table|nil row container
--- @param tooltipElem table|nil the row's tooltip Text
--- @param guardField string the self[guardField] one-shot flag
function RLMenuHerdsmanFrame:logTooltipRowGeometryOnce(rowName, row, tooltipElem, guardField)
    if self[guardField] or row == nil then return end
    self[guardField] = true
    local rw = (row.size and row.size[1] or 0) * g_referenceScreenWidth
    local rh = (row.size and row.size[2] or 0) * g_referenceScreenHeight
    Log:debug("RLMenuHerdsmanFrame: %s measured: row=%.1fx%.1fpx", rowName, rw, rh)
    if tooltipElem ~= nil and tooltipElem.absPosition ~= nil and tooltipElem.size ~= nil then
        local x = tooltipElem.absPosition[1] * g_referenceScreenWidth
        local w = tooltipElem.size[1] * g_referenceScreenWidth
        Log:debug("RLMenuHerdsmanFrame: %s tooltip: left=%.1fpx width=%.1fpx right=%.1fpx visible=%s",
            rowName, x, w, x + w,
            tostring(tooltipElem.getIsVisible ~= nil and tooltipElem:getIsVisible()))
    end
end

--- Apply the alternating dark settings-row tint to the visible editor rows AND reflow
--- the layout so the per-operation hidden rows collapse instead of leaving gaps. Mirrors
--- RLMenuSettingsFrame:updateAlternatingElements: walk layout.elements in XML order, tint
--- each VISIBLE row that exposes setImageColor via InGameMenuSettingsFrame.COLOR_ALTERNATING
--- (parity toggles per tinted row), skip hidden rows, then invalidateLayout() to re-flow.
--- The read-only summary rows have no setImageColor and are left untinted (on the dark pane).
--- @param layout table|nil the editor ScrollingLayout
function RLMenuHerdsmanFrame:updateAlternatingElements(layout)
    if layout == nil or layout.elements == nil then
        Log:warning("RLMenuHerdsmanFrame:updateAlternatingElements: layout/elements nil; skipping tint (rows unreadable)")
        return
    end

    local colorTable = InGameMenuSettingsFrame ~= nil and InGameMenuSettingsFrame.COLOR_ALTERNATING or nil
    if colorTable == nil or colorTable[true] == nil or colorTable[false] == nil then
        Log:warning("RLMenuHerdsmanFrame:updateAlternatingElements: InGameMenuSettingsFrame.COLOR_ALTERNATING unavailable; skipping tint")
        return
    end

    local alternate = true
    local tinted = 0
    for _, row in ipairs(layout.elements) do
        if row.visible and row.setImageColor ~= nil then
            row:setImageColor(nil, unpack(colorTable[alternate]))
            alternate = not alternate
            tinted = tinted + 1
        end
    end

    layout:invalidateLayout()
    Log:trace("RLMenuHerdsmanFrame:updateAlternatingElements: tinted=%d row(s)", tinted)
end

--- Build the semen MultiTextOption options for an ai rule: "any" (prepended by the
--- frame, the presenter owns only the SEMEN_ANY value) + the live dewar pool for the
--- rule's filter animalType, enumerated from g_dewarManager (engine state; mirrors
--- RealisticLivestock_AnimalScreen). Every hop is nil-guarded -> degrades to just "any".
--- The per-dewar LABEL goes through F4a's formatSemenOption; the per-dewar VALUE is the
--- dewar uniqueId. A stored semen no longer in the live pool snaps the selector to "any"
--- (legacy parity); the setState push is silent (forceEvent=false), so this snap does not
--- stash and the stored id survives a flush.
--- @param merged table the overlay-merged rule record
function RLMenuHerdsmanFrame:populateSemenSelector(merged)
    if self.ruleSemenSelector == nil then return end

    local texts  = { g_i18n:getText("rl_ui_any") }
    local values = { RLHerdsmanRulePresenter.SEMEN_ANY }

    local animalTypeIndex = self:resolveSemenAnimalTypeIndex(merged.filterId)
    local farmId = RLAnimalInfoService.getCurrentFarmId()
    if animalTypeIndex ~= nil and farmId ~= nil and g_dewarManager ~= nil then
        local farmDewars = g_dewarManager:getDewarsByFarm(farmId)
        local dewars = farmDewars ~= nil and farmDewars[animalTypeIndex] or nil
        if dewars ~= nil then
            local strawLabels = {
                strawSingular = g_i18n:getText("rl_ui_strawSingle"),
                strawPlural   = g_i18n:getText("rl_ui_strawMultiple"),
            }
            for _, dewar in pairs(dewars) do
                local a = dewar.animal
                texts[#texts + 1]  = RLHerdsmanRulePresenter.formatSemenOption(a.country, a.farmId, a.uniqueId, dewar.straws, strawLabels)
                values[#values + 1] = dewar:getUniqueId()
            end
        end
    end

    self.semenValues = values
    -- Parallel option-text array: the tooltip's %s for a dewar semen value is that
    -- dewar's option label, looked up by the same index as semenValues.
    self.semenTexts = texts
    self.ruleSemenSelector:setTexts(texts)
    local storedSemen = (merged.params and merged.params.semen) or RLHerdsmanRulePresenter.SEMEN_ANY
    self.ruleSemenSelector:setState(indexOfValue(values, storedSemen) or 1, false)
    Log:trace("RLMenuHerdsmanFrame:populateSemenSelector: %d option(s), selected=%s", #values, tostring(storedSemen))
end

--- The rule's animalType gate (D8): the chosen filter's animalType, or nil (ANY = all
--- types) when there is no filter / it is unresolvable / it is an Any-type filter. The single
--- source for both the husbandry-target gate (selectTargetableHusbandries / revalidateTargets)
--- and the semen dewar pool.
--- @param filterId any
--- @return number|nil
function RLMenuHerdsmanFrame:resolveFilterAnimalType(filterId)
    if filterId == nil then return nil end
    local filter = resolveFilterById(filterId)
    if filter == nil then return nil end
    return filter.animalType
end

--- The animalType index for the semen dewar pool == the rule's filter animalType (delegates
--- to resolveFilterAnimalType). No filter / unresolvable / Any-type -> nil (options = "any").
--- @param filterId any
--- @return number|nil
function RLMenuHerdsmanFrame:resolveSemenAnimalTypeIndex(filterId)
    return self:resolveFilterAnimalType(filterId)
end

-- =============================================================================
-- FILTER PICKER (in-row button -> dialog -> stash filterId)
-- =============================================================================

--- Filter row button click: open the single-select picker scoped to the rule's operation.
--- The presenter owns the scope decision (getFilterPickerUsage, derived from ALLOWED_USAGES)
--- and the candidate ordering (sortFiltersByName); this frame computes farmId, nil-guards, and
--- issues ONE listAvailable(nil, farmId, usage) query (animalType = nil: a rule has no type
--- until a filter is bound; usage is the only DoD scope). A nil usage / farmId / service would
--- be a list-everything WILDCARD in listAvailable, so the picker does NOT open in that case.
--- @param _button table the ruleFilterButton element (unused; selection comes from selectedRuleId)
function RLMenuHerdsmanFrame:onClickRuleFilter(_button)
    local id = self.selectedRuleId
    if id == nil then
        Log:debug("RLMenuHerdsmanFrame:onClickRuleFilter: no selected rule; ignoring")
        return
    end
    local stored = self:getStoredRuleById(id)
    if stored == nil then
        Log:debug("RLMenuHerdsmanFrame:onClickRuleFilter: id=%s no stored baseline; ignoring", tostring(id))
        return
    end
    local merged = RLHerdsmanRuleEditModel.overlayRule(stored, self.pendingChanges[id])

    local pickerUsage = RLHerdsmanRulePresenter.getFilterPickerUsage(merged.operation)
    local farmId = RLAnimalInfoService.getCurrentFarmId()
    if pickerUsage == nil or farmId == nil or g_rlFilterService == nil then
        Log:warning("RLMenuHerdsmanFrame:onClickRuleFilter: not opening (operation=%s pickerUsage=%s farmId=%s serviceNil=%s)",
            tostring(merged.operation), tostring(pickerUsage), tostring(farmId), tostring(g_rlFilterService == nil))
        return
    end

    -- usageMatch folds ANY/nil filters in (RLFilterService:listAvailable), so a non-nil usage
    -- AND farmId yield exactly the operation's { ANY, X } pool. Then drop filters whose
    -- animalType the operation forbids (castrate excludes chicken, horse care allows only
    -- horses) keeping ANY-type, and sort alpha for the picker.
    local animalTypeIndexByName = RLMenuHerdsmanFrame.buildAnimalTypeIndexMap()
    local scoped = RLHerdsmanRulePresenter.filterCandidateFilters(
        g_rlFilterService:listAvailable(nil, farmId, pickerUsage), merged.operation, animalTypeIndexByName)
    local candidates = RLHerdsmanRulePresenter.sortFiltersByName(scoped)

    -- M4: a current binding the retrofit dropped (e.g. a chicken filter on a castrate rule) is
    -- no longer in the list; flag it so the picker surfaces "current unavailable" rather than
    -- silently preselecting row 1 (a silent rebind on OK).
    local currentUnavailable = false
    if merged.filterId ~= nil then
        currentUnavailable = true
        for _, f in ipairs(candidates) do
            if f.id == merged.filterId then currentUnavailable = false; break end
        end
    end

    -- Capture the target id at OPEN; the pick stashes against THIS id (selection may move).
    self.filterPickTargetId = id

    Log:debug("RLMenuHerdsmanFrame:onClickRuleFilter: id=%s operation=%s usage=%s farmId=%s -> %d candidate(s) currentFilterId=%s currentUnavailable=%s",
        tostring(id), tostring(merged.operation), tostring(pickerUsage), tostring(farmId), #candidates, tostring(merged.filterId), tostring(currentUnavailable))

    RLHerdsmanFilterPickerDialog.show(self.onFilterPicked, self, candidates, merged.filterId, currentUnavailable)
end

--- Picker result (target-first via the dialog). nil -> cancel (rule unchanged). A pick equal to
--- the current binding with NOTHING else pending -> no-op (no redundant :update). Otherwise stash
--- pending.filterId against the OPEN-TIME id and re-render the overlay (the semen pool re-derives
--- from merged.filterId on refreshRuleDetail). Flush happens on the existing selection-change/close
--- path through g_rlHerdsmanRuleService:update.
--- @param filterId string|nil chosen filter id, or nil on cancel
function RLMenuHerdsmanFrame:onFilterPicked(filterId)
    local id = self.filterPickTargetId
    self.filterPickTargetId = nil
    if id == nil then
        Log:debug("RLMenuHerdsmanFrame:onFilterPicked: no captured target id; ignoring (filterId=%s)", tostring(filterId))
        return
    end
    if filterId == nil then
        Log:debug("RLMenuHerdsmanFrame:onFilterPicked: id=%s cancelled (no change)", tostring(id))
        return
    end

    local stored = self:getStoredRuleById(id)
    if stored == nil then
        Log:debug("RLMenuHerdsmanFrame:onFilterPicked: id=%s no stored baseline; ignoring", tostring(id))
        return
    end
    local merged = RLHerdsmanRuleEditModel.overlayRule(stored, self.pendingChanges[id])

    if filterId == merged.filterId and self.pendingChanges[id] == nil then
        Log:debug("RLMenuHerdsmanFrame:onFilterPicked: id=%s re-picked current filter %s; no-op", tostring(id), tostring(filterId))
        return
    end

    self:ensurePending(id).filterId = filterId
    Log:debug("RLMenuHerdsmanFrame:onFilterPicked: id=%s filterId stashed %s -> %s",
        tostring(id), tostring(merged.filterId), tostring(filterId))

    -- Cross-type revalidation against the NEW merged (filterId now applied): drop
    -- type-incompatible RESOLVABLE targets (preserve unresolvable) + reset semen if its
    -- dewar leaves the new animalType pool. Pinned to current merged so two edits compose.
    local newMerged = RLHerdsmanRuleEditModel.overlayRule(stored, self.pendingChanges[id])
    self:revalidatePendingTargetsAndSemen(id, newMerged)
    -- Drop a now-type-incompatible move destination (the filter-rebind axis). Recompute the
    -- merged record first so the dest sees the post-target-revalidation source set.
    local afterTargets = RLHerdsmanRuleEditModel.overlayRule(stored, self.pendingChanges[id])
    self:revalidatePendingDestination(id, afterTargets, afterTargets.targetHusbandries)
    self:refreshRuleDetail(stored)
end

-- =============================================================================
-- HUSBANDRY PICKER (in-row button -> dialog -> stash targetHusbandries)
-- =============================================================================

--- Husbandries row button click: open the multi-select picker scoped to the rule's filter
--- animalType + operation (D8). The presenter owns the gate + sort (selectTargetableHusbandries);
--- this frame enumerates the farm's live husbandries (RLAnimalQuery descriptors - one source,
--- M12), resolves the filter animalType + the CHICKEN index, nil-guards farm / husbandrySystem
--- (mirror onClickRuleFilter's refuse-to-open), and hands plain data to the dialog.
--- @param _button table the ruleHusbandriesButton element (unused; selection = selectedRuleId)
function RLMenuHerdsmanFrame:onClickRuleHusbandries(_button)
    local id = self.selectedRuleId
    if id == nil then
        Log:debug("RLMenuHerdsmanFrame:onClickRuleHusbandries: no selected rule; ignoring")
        return
    end
    local stored = self:getStoredRuleById(id)
    if stored == nil then
        Log:debug("RLMenuHerdsmanFrame:onClickRuleHusbandries: id=%s no stored baseline; ignoring", tostring(id))
        return
    end
    local merged = RLHerdsmanRuleEditModel.overlayRule(stored, self.pendingChanges[id])

    local farmId = RLAnimalInfoService.getCurrentFarmId()
    local noHusbandrySystem = g_currentMission == nil or g_currentMission.husbandrySystem == nil
    if farmId == nil or farmId == 0 or noHusbandrySystem then
        Log:warning("RLMenuHerdsmanFrame:onClickRuleHusbandries: not opening (farmId=%s husbandrySystemNil=%s)",
            tostring(farmId), tostring(noHusbandrySystem))
        return
    end

    local descriptors = RLAnimalQuery.listHusbandryDescriptorsForFarm(farmId)
    local animalTypeIndexByName = RLMenuHerdsmanFrame.buildAnimalTypeIndexMap()
    local filterAnimalType = self:resolveFilterAnimalType(merged.filterId)
    local candidates = RLHerdsmanRulePresenter.selectTargetableHusbandries(
        descriptors, filterAnimalType, merged.operation, animalTypeIndexByName)

    -- Capture the target id at OPEN; the pick stashes against THIS id (selection may move).
    self.husbandryPickTargetId = id

    Log:debug("RLMenuHerdsmanFrame:onClickRuleHusbandries: id=%s operation=%s filterType=%s farmId=%s -> %d candidate(s), %d current target(s)",
        tostring(id), tostring(merged.operation), tostring(filterAnimalType), tostring(farmId),
        #candidates, #(merged.targetHusbandries or {}))

    RLHerdsmanHusbandryPickerDialog.show(self.onHusbandriesPicked, self, candidates, merged.targetHusbandries or {})
end

--- Picker result (target-first via the dialog). nil -> cancel (rule unchanged; targets
--- preserved). Otherwise re-read the merged baseline at commit and stash the picked set
--- as pending targetHusbandries. The dialog already PRESERVED checked-but-out-of-scope /
--- unresolvable targets and guaranteed non-empty strings, so this frame stashes the
--- set as-is - it does NOT re-strip (the type-incompatible drop is a rebind/op-change concern,
--- not a pick concern). A pick equal to the current targets with nothing else pending -> no-op
--- (no redundant :update). Flush happens on the existing selection-change / close path.
--- @param uniqueIds table|nil chosen target uniqueIds, or nil on cancel
function RLMenuHerdsmanFrame:onHusbandriesPicked(uniqueIds)
    local id = self.husbandryPickTargetId
    self.husbandryPickTargetId = nil
    if id == nil then
        Log:debug("RLMenuHerdsmanFrame:onHusbandriesPicked: no captured target id; ignoring")
        return
    end
    if uniqueIds == nil then
        Log:debug("RLMenuHerdsmanFrame:onHusbandriesPicked: id=%s cancelled (no change)", tostring(id))
        return
    end

    local stored = self:getStoredRuleById(id)
    if stored == nil then
        Log:debug("RLMenuHerdsmanFrame:onHusbandriesPicked: id=%s no stored baseline; ignoring", tostring(id))
        return
    end
    local merged = RLHerdsmanRuleEditModel.overlayRule(stored, self.pendingChanges[id])

    -- No-op when the chosen SET matches the current targets (order-insensitive): the picker
    -- commits in name-sorted order, which can differ from the stored order even with identical
    -- membership; a set compare avoids a spurious re-order flush + MP broadcast, and is correct
    -- whether or not other pending edits already exist for this rule.
    if sameStringSet(merged.targetHusbandries, uniqueIds) then
        Log:debug("RLMenuHerdsmanFrame:onHusbandriesPicked: id=%s unchanged target set; no-op", tostring(id))
        return
    end

    self:ensurePending(id).targetHusbandries = uniqueIds
    Log:debug("RLMenuHerdsmanFrame:onHusbandriesPicked: id=%s targetHusbandries stashed (%d target(s))",
        tostring(id), #uniqueIds)
    -- Drop a move destination that the new source set turned into a source (the source-set axis).
    local afterPick = RLHerdsmanRuleEditModel.overlayRule(stored, self.pendingChanges[id])
    self:revalidatePendingDestination(id, afterPick, uniqueIds)
    self:refreshRuleDetail(stored)
end

--- Build a uniqueId -> animalType map for the farm's LIVE husbandries (non-nil types only),
--- the typeByUid input to revalidateTargets. Reuses the same RLAnimalQuery descriptor source
--- as the picker (M12), so a uid the picker would gate is gated identically on rebind cleanup,
--- and a uid absent here is exactly an unresolvable target (revalidateTargets preserves it).
--- @param farmId number|nil
--- @return table typeByUid map uniqueId(string) -> animalType index
function RLMenuHerdsmanFrame:buildHusbandryTypeByUid(farmId)
    local typeByUid = {}
    for _, d in ipairs(RLAnimalQuery.listHusbandryDescriptorsForFarm(farmId)) do
        if d.animalType ~= nil then typeByUid[d.uniqueId] = d.animalType end
    end
    return typeByUid
end

--- Build a uniqueId -> type-spec map for the farm's LIVE move DESTINATIONS (husbandries + EPP
--- butchers), the dest-axis SIBLING of buildHusbandryTypeByUid feeding revalidatePendingDestination
---A husbandry maps to its scalar animalType; an EPP butcher maps to its type-index SET
--- (animalTypes) so revalidateDestination gates an EPP dest set-aware instead of treating it as
--- unresolvable and preserving it forever. Reuses listMoveDestinationDescriptorsForFarm so this
--- map and the dest picker share ONE enumeration source. A descriptor with no usable type-spec is
--- omitted - an omitted uid is exactly an unresolvable dest, which revalidateDestination preserves.
--- @param farmId number|nil
--- @return table typeByUid map uniqueId(string) -> animalType index (husbandry) or type-index set (EPP)
function RLMenuHerdsmanFrame:buildDestinationTypeByUid(farmId)
    local typeByUid = {}
    local count = 0
    for _, d in ipairs(RLAnimalQuery.listMoveDestinationDescriptorsForFarm(farmId)) do
        if d.animalTypes ~= nil then
            typeByUid[d.uniqueId] = d.animalTypes
            count = count + 1
        elseif d.animalType ~= nil then
            typeByUid[d.uniqueId] = d.animalType
            count = count + 1
        end
    end
    Log:trace("RLMenuHerdsmanFrame:buildDestinationTypeByUid: farmId=%s -> %d dest type-specs (husbandry scalar + EPP set)",
        tostring(farmId), count)
    return typeByUid
end

--- True when dewar `semenUid` is still in the farm's dewar pool for `filterAnimalType` -
--- mirrors populateSemenSelector's g_dewarManager enumeration exactly. An ANY / nil
--- filterAnimalType has no typed pool (only the "any" sentinel), so any real dewar is out of
--- pool. Every hop nil-guarded.
--- @param semenUid string the selected dewar uniqueId
--- @param filterAnimalType number|nil the new filter animalType
--- @param farmId number|nil
--- @return boolean
function RLMenuHerdsmanFrame:isSemenInPool(semenUid, filterAnimalType, farmId)
    if filterAnimalType == nil or farmId == nil or g_dewarManager == nil then return false end
    local farmDewars = g_dewarManager:getDewarsByFarm(farmId)
    local dewars = farmDewars ~= nil and farmDewars[filterAnimalType] or nil
    if dewars == nil then return false end
    for _, dewar in pairs(dewars) do
        if dewar:getUniqueId() == semenUid then return true end
    end
    return false
end

--- Cross-type revalidation after a filter rebind OR an operation change, pinned to the
--- passed `merged` baseline (current stored+pending). Drops type-incompatible RESOLVABLE
--- targets via the pure revalidateTargets (preserving unresolvable), and resets a non-"any"
--- ai semen to "any" ONLY when its dewar left the new animalType pool (a widen / ANY keeps a
--- valid dewar). Stashes results into pending against `id`; logs the dropped-target count.
--- @param id any rule id
--- @param merged table the current overlay-merged record (filter/op already applied)
function RLMenuHerdsmanFrame:revalidatePendingTargetsAndSemen(id, merged)
    local farmId = RLAnimalInfoService.getCurrentFarmId()
    local animalTypeIndexByName = RLMenuHerdsmanFrame.buildAnimalTypeIndexMap()
    local filterAnimalType = self:resolveFilterAnimalType(merged.filterId)
    local typeByUid = self:buildHusbandryTypeByUid(farmId)

    local before = merged.targetHusbandries or {}
    local kept = RLHerdsmanRulePresenter.revalidateTargets(before, typeByUid, filterAnimalType, merged.operation, animalTypeIndexByName)
    if #kept ~= #before then
        self:ensurePending(id).targetHusbandries = kept
        Log:debug("RLMenuHerdsmanFrame:revalidatePendingTargetsAndSemen: id=%s targets %d -> %d (dropped %d type-incompatible resolvable)",
            tostring(id), #before, #kept, #before - #kept)
    end

    -- Semen reset (ai only): a non-"any" dewar that left the new animalType pool snaps to "any".
    local semen = merged.params and merged.params.semen
    if merged.operation == "ai" and type(semen) == "string" and semen ~= RLHerdsmanRulePresenter.SEMEN_ANY then
        if not self:isSemenInPool(semen, filterAnimalType, farmId) then
            self:ensurePendingParams(id).params.semen = RLHerdsmanRulePresenter.SEMEN_ANY
            Log:debug("RLMenuHerdsmanFrame:revalidatePendingTargetsAndSemen: id=%s semen %s left the new pool; reset to any",
                tostring(id), tostring(semen))
        end
    end
end

--- Revalidate a move rule's pending destination after a filter rebind OR a source-set change -
--- the dest twin of revalidatePendingTargetsAndSemen. Drops a now-type-incompatible RESOLVABLE dest
--- (the picker's gate) or a dest that became a source (preserving an unresolvable one), and stashes
--- the survivor. No-op for a non-move rule or a nil dest. `sourceUids` is the rule's source target
--- set AFTER the edit (the live targets on a filter rebind; the just-picked set on a husbandries change).
--- @param id any rule id
--- @param merged table the current overlay-merged record (filter/targets already applied)
--- @param sourceUids table|nil the rule's source target uniqueIds after the edit
function RLMenuHerdsmanFrame:revalidatePendingDestination(id, merged, sourceUids)
    if merged.operation ~= "move" then return end
    local dest = merged.params and merged.params.destinationHusbandry or nil
    if dest == nil then return end
    local farmId = RLAnimalInfoService.getCurrentFarmId()
    -- Dest-axis map (husbandries + EPP butchers): an EPP dest resolves to its type-index SET here, so
    -- revalidateDestination type-gates it instead of treating it as unresolvable-preserved-forever.
    local typeByUid = self:buildDestinationTypeByUid(farmId)
    -- 4th arg, NOT 5th: revalidateDestination carries no `operation` (it applies "move"), so the
    -- type map sits one slot left of its position in revalidateTargets above.
    local animalTypeIndexByName = RLMenuHerdsmanFrame.buildAnimalTypeIndexMap()
    local filterAnimalType = self:resolveFilterAnimalType(merged.filterId)
    local kept = RLHerdsmanRulePresenter.revalidateDestination(dest, typeByUid, filterAnimalType, animalTypeIndexByName, sourceUids)
    if kept ~= dest then
        self:ensurePendingParams(id).params.destinationHusbandry = kept
        Log:debug("RLMenuHerdsmanFrame:revalidatePendingDestination: id=%s dest %s -> %s (revalidated)",
            tostring(id), tostring(dest), tostring(kept))
    end
end

-- =============================================================================
-- DESTINATION PICKER (move only; in-row button -> single-select dialog -> stash dest)
-- =============================================================================

--- Destination row button click (move only): open the SINGLE-select destination picker scoped to the
--- rule's filter animalType (D8) and EXCLUDING the rule's own source husbandries (decision 3b). The
--- presenter owns the gate + sort + source-exclusion (selectDestinationHusbandries); this frame
--- enumerates the farm's live husbandries (the same RLAnimalQuery source as the husbandry picker),
--- resolves the filter animalType + CHICKEN index, nil-guards farm / husbandrySystem (mirror
--- onClickRuleHusbandries' refuse-to-open), and flags a stored dest the gate dropped as
--- currentUnavailable so the picker requires an explicit pick. Opens even on an empty candidate set
--- (the dialog shows empty-text + disabled OK - feedback, never a dead click).
--- @param _button table the ruleDestinationButton element (unused; selection = selectedRuleId)
function RLMenuHerdsmanFrame:onClickRuleDestination(_button)
    local id = self.selectedRuleId
    if id == nil then
        Log:debug("RLMenuHerdsmanFrame:onClickRuleDestination: no selected rule; ignoring")
        return
    end
    local stored = self:getStoredRuleById(id)
    if stored == nil then
        Log:debug("RLMenuHerdsmanFrame:onClickRuleDestination: id=%s no stored baseline; ignoring", tostring(id))
        return
    end
    local merged = RLHerdsmanRuleEditModel.overlayRule(stored, self.pendingChanges[id])

    local farmId = RLAnimalInfoService.getCurrentFarmId()
    local noHusbandrySystem = g_currentMission == nil or g_currentMission.husbandrySystem == nil
    if farmId == nil or farmId == 0 or noHusbandrySystem then
        Log:warning("RLMenuHerdsmanFrame:onClickRuleDestination: not opening (farmId=%s husbandrySystemNil=%s)",
            tostring(farmId), tostring(noHusbandrySystem))
        return
    end

    -- Move-dest enumeration = husbandries + owner-farm EPP butchers; the presenter's
    -- set-aware gate keeps a multi-type butcher under an ANY filter and a type-matching one under a
    -- typed filter. Husbandry-only picker sources would never offer a butcher.
    local descriptors = RLAnimalQuery.listMoveDestinationDescriptorsForFarm(farmId)
    -- 3rd arg, NOT 4th: selectDestinationHusbandries carries no `operation`, so the type map sits
    -- one slot left of its position in selectTargetableHusbandries.
    local animalTypeIndexByName = RLMenuHerdsmanFrame.buildAnimalTypeIndexMap()
    local filterAnimalType = self:resolveFilterAnimalType(merged.filterId)
    local candidates = RLHerdsmanRulePresenter.selectDestinationHusbandries(
        descriptors, filterAnimalType, animalTypeIndexByName, merged.targetHusbandries or {})

    -- A stored dest the gate dropped (its type left the filter scope, or it became a source) is no
    -- longer in the list; flag it so the picker surfaces "current unavailable" rather than silently
    -- preselecting row 1 (mirror onClickRuleFilter).
    local currentDest = merged.params and merged.params.destinationHusbandry or nil
    local currentUnavailable = false
    if currentDest ~= nil then
        currentUnavailable = true
        for _, c in ipairs(candidates) do
            if c.uniqueId == currentDest then currentUnavailable = false; break end
        end
    end

    -- Capture the target id at OPEN; the pick stashes against THIS id (selection may move).
    self.destinationPickTargetId = id

    Log:debug("RLMenuHerdsmanFrame:onClickRuleDestination: id=%s filterType=%s farmId=%s -> %d candidate(s), currentDest=%s currentUnavailable=%s",
        tostring(id), tostring(filterAnimalType), tostring(farmId), #candidates, tostring(currentDest), tostring(currentUnavailable))

    RLHerdsmanDestinationPickerDialog.show(self.onDestinationPicked, self, candidates, currentDest, currentUnavailable)
end

--- Picker result (target-first via the dialog). nil -> cancel (rule unchanged). A pick equal to the
--- overlay-merged dest with NOTHING else pending -> no-op (no redundant flush). Otherwise stash
--- pending.params.destinationHusbandry against the OPEN-TIME id and re-render. Flush happens on the
--- existing selection-change / close path.
--- @param destKey string|nil chosen destination uniqueId, or nil on cancel
function RLMenuHerdsmanFrame:onDestinationPicked(destKey)
    local id = self.destinationPickTargetId
    self.destinationPickTargetId = nil
    if id == nil then
        Log:debug("RLMenuHerdsmanFrame:onDestinationPicked: no captured target id; ignoring (destKey=%s)", tostring(destKey))
        return
    end
    if destKey == nil then
        Log:debug("RLMenuHerdsmanFrame:onDestinationPicked: id=%s cancelled (no change)", tostring(id))
        return
    end

    local stored = self:getStoredRuleById(id)
    if stored == nil then
        Log:debug("RLMenuHerdsmanFrame:onDestinationPicked: id=%s no stored baseline; ignoring", tostring(id))
        return
    end
    local merged = RLHerdsmanRuleEditModel.overlayRule(stored, self.pendingChanges[id])
    local currentDest = merged.params and merged.params.destinationHusbandry or nil

    if destKey == currentDest and self.pendingChanges[id] == nil then
        Log:debug("RLMenuHerdsmanFrame:onDestinationPicked: id=%s re-picked current dest %s; no-op", tostring(id), tostring(destKey))
        return
    end

    self:ensurePendingParams(id).params.destinationHusbandry = destKey
    Log:debug("RLMenuHerdsmanFrame:onDestinationPicked: id=%s destinationHusbandry stashed %s -> %s",
        tostring(id), tostring(currentDest), tostring(destKey))
    self:refreshRuleDetail(stored)
end

-- =============================================================================
-- EDIT CALLBACKS (read widget -> stash pending -> live render)
-- Bound from herdsmanFrame.xml. TextInput: (element, _text). MultiTextOption /
-- BinaryOption: (state, widget). Each stashes to self.pendingChanges[id]; no decisions.
-- =============================================================================

--- Lazily get/create the pending overlay for an id.
--- @param id any
--- @return table pending
function RLMenuHerdsmanFrame:ensurePending(id)
    local pending = self.pendingChanges[id]
    if pending == nil then pending = {}; self.pendingChanges[id] = pending end
    return pending
end

--- Lazily get/create the pending overlay AND ensure pending.params is a COMPLETE copy of
--- the current overlay-merged params (so a partial param edit never drops nested-budget
--- siblings before the whole-object update). The first param edit deep-copies via the
--- edit-model's overlayRule, then the caller mutates the single field.
--- @param id any
--- @return table pending (with pending.params populated)
function RLMenuHerdsmanFrame:ensurePendingParams(id)
    local pending = self:ensurePending(id)
    if pending.params == nil then
        local stored = self:getStoredRuleById(id)
        local merged = RLHerdsmanRuleEditModel.overlayRule(stored, pending)
        pending.params = merged.params or {}
    end
    return pending
end

--- Name TextInput. Stash + refresh the list row (overlay-merged name) under the reconcile
--- guard; do NOT re-render the detail (the input already shows the typed text).
function RLMenuHerdsmanFrame:onRuleNameChanged(element, _text)
    if self.isPopulating then
        Log:trace("RLMenuHerdsmanFrame:onRuleNameChanged: suppressed programmatic populate (isPopulating)")
        return
    end
    local id = self.selectedRuleId
    if id == nil or element == nil then return end
    local typed = element:getText() or ""
    self:ensurePending(id).name = typed
    Log:debug("RLMenuHerdsmanFrame:onRuleNameChanged: id=%s value=%q", tostring(id), typed)
    self:refreshList(id)
end

--- maxAnimals TextInput. Parse to a number and stash; tonumber failure stashes nil ->
--- validateParams marks it absent -> the flush gate skips (and reverts).
function RLMenuHerdsmanFrame:onRuleMaxAnimalsChanged(element, _text)
    if self.isPopulating then
        Log:trace("RLMenuHerdsmanFrame:onRuleMaxAnimalsChanged: suppressed programmatic populate (isPopulating)")
        return
    end
    local id = self.selectedRuleId
    if id == nil or element == nil then return end
    local typed = element:getText() or ""
    self:ensurePendingParams(id).params.maxAnimals = tonumber(typed)
    Log:debug("RLMenuHerdsmanFrame:onRuleMaxAnimalsChanged: id=%s typed=%q parsed=%s", tostring(id), typed, tostring(tonumber(typed)))
    -- Live tooltip update WITHOUT a full re-render (which would stomp the caret mid-type) - F1.
    self:refreshValueRowTooltip("maxAnimals", tonumber(typed))
end

--- budget.fixed TextInput. Parse + stash into the nested budget (params kept complete).
function RLMenuHerdsmanFrame:onRuleBudgetFixedChanged(element, _text)
    if self.isPopulating then
        Log:trace("RLMenuHerdsmanFrame:onRuleBudgetFixedChanged: suppressed programmatic populate (isPopulating)")
        return
    end
    local id = self.selectedRuleId
    if id == nil or element == nil then return end
    local typed = element:getText() or ""
    local pending = self:ensurePendingParams(id)
    if type(pending.params.budget) ~= "table" then pending.params.budget = {} end
    pending.params.budget.fixed = tonumber(typed)
    Log:debug("RLMenuHerdsmanFrame:onRuleBudgetFixedChanged: id=%s typed=%q parsed=%s", tostring(id), typed, tostring(tonumber(typed)))
    -- Live tooltip update WITHOUT a full re-render (which would stomp the caret mid-type) - F1.
    self:refreshValueRowTooltip("budget|fixed", tonumber(typed))
end

--- Enabled BinaryOption: state 1=false, 2=true (top-level field).
function RLMenuHerdsmanFrame:onRuleEnabledChanged(state, _widget)
    local id = self.selectedRuleId
    if id == nil then return end
    self:ensurePending(id).enabled = (state == 2)
    Log:debug("RLMenuHerdsmanFrame:onRuleEnabledChanged: id=%s enabled=%s", tostring(id), tostring(state == 2))
    self:refreshRuleDetail(self:getStoredRuleById(id))
end

--- mark BinaryOption: state 1=false, 2=true.
function RLMenuHerdsmanFrame:onRuleMarkChanged(state, _widget)
    local id = self.selectedRuleId
    if id == nil then return end
    self:ensurePendingParams(id).params.mark = (state == 2)
    Log:debug("RLMenuHerdsmanFrame:onRuleMarkChanged: id=%s mark=%s", tostring(id), tostring(state == 2))
    self:refreshRuleDetail(self:getStoredRuleById(id))
end

--- convention BinaryOption (2-value): state -> conventionValues[state].
function RLMenuHerdsmanFrame:onRuleConventionChanged(state, _widget)
    local id = self.selectedRuleId
    if id == nil then return end
    self:ensurePendingParams(id).params.convention = self.conventionValues[state]
    Log:debug("RLMenuHerdsmanFrame:onRuleConventionChanged: id=%s convention=%s", tostring(id), tostring(self.conventionValues[state]))
    self:refreshRuleDetail(self:getStoredRuleById(id))
end

--- budget.type BinaryOption (2-value): state -> budgetTypeValues[state]; re-render to
--- toggle the fixed vs percentage amount row (getBudgetFieldVisibility).
function RLMenuHerdsmanFrame:onRuleBudgetTypeChanged(state, _widget)
    local id = self.selectedRuleId
    if id == nil then return end
    local pending = self:ensurePendingParams(id)
    if type(pending.params.budget) ~= "table" then pending.params.budget = {} end
    pending.params.budget.type = self.budgetTypeValues[state]
    Log:debug("RLMenuHerdsmanFrame:onRuleBudgetTypeChanged: id=%s budgetType=%s", tostring(id), tostring(self.budgetTypeValues[state]))
    self:refreshRuleDetail(self:getStoredRuleById(id))
end

--- budget.percentage MultiTextOption: state -> budgetPercentageValues[state] (whitelist).
function RLMenuHerdsmanFrame:onRuleBudgetPercentageChanged(state, _widget)
    local id = self.selectedRuleId
    if id == nil then return end
    local pending = self:ensurePendingParams(id)
    if type(pending.params.budget) ~= "table" then pending.params.budget = {} end
    pending.params.budget.percentage = self.budgetPercentageValues[state]
    Log:debug("RLMenuHerdsmanFrame:onRuleBudgetPercentageChanged: id=%s percentage=%s", tostring(id), tostring(self.budgetPercentageValues[state]))
    -- Re-render so the budget% tooltip follows the new value (F1; mirrors the sibling selector
    -- handlers - the silent setState push during re-render does not re-fire this handler).
    self:refreshRuleDetail(self:getStoredRuleById(id))
end

--- semen MultiTextOption: state -> the per-render semenValues[state] (any | dewar uid).
function RLMenuHerdsmanFrame:onRuleSemenChanged(state, _widget)
    local id = self.selectedRuleId
    if id == nil then return end
    self:ensurePendingParams(id).params.semen = self.semenValues[state]
    Log:debug("RLMenuHerdsmanFrame:onRuleSemenChanged: id=%s semen=%s", tostring(id), tostring(self.semenValues[state]))
    -- Re-render so the semen tooltip follows the new value (F1; mirrors the sibling selector handlers).
    self:refreshRuleDetail(self:getStoredRuleById(id))
end

--- operation MultiTextOption: the D5 op-change. Reshape params via the edit-model, clear
--- the filter when the new op forbids it, re-section live, and re-render.
function RLMenuHerdsmanFrame:onRuleOperationChanged(state, _widget)
    local id = self.selectedRuleId
    if id == nil then return end
    local newOp = RLHerdsmanRulePresenter.OPERATION_ORDER[state]
    if newOp == nil then return end
    self:applyOperationChange(id, newOp)
end

--- Apply an operation change (D5): stash the operation, reshape pending.params via the
--- edit-model (shared scalars carried, op-specific reseeded), and revalidate the filter -
--- naming clears filterId (the service floor rejects a naming rule with a filter); a
--- non-naming op clears filterId when the current filter's usage is not allowed for it
--- (an unresolvable/deleted filter is left as-is). Then re-section live + re-render.
--- @param id any
--- @param newOp string
function RLMenuHerdsmanFrame:applyOperationChange(id, newOp)
    local stored = self:getStoredRuleById(id)
    if stored == nil then return end
    local merged = RLHerdsmanRuleEditModel.overlayRule(stored, self.pendingChanges[id])
    if merged.operation == newOp then return end

    local pending = self:ensurePending(id)
    pending.operation = newOp
    pending.params = RLHerdsmanRuleEditModel.reshapeParamsForOperation(merged.params, newOp)

    if newOp == "naming" then
        pending.filterId = RLHerdsmanRuleEditModel.CLEAR
        Log:debug("RLMenuHerdsmanFrame:applyOperationChange: id=%s -> naming; filterId cleared", tostring(id))
    elseif merged.filterId ~= nil then
        local filter = resolveFilterById(merged.filterId)
        if filter ~= nil and not RLHerdsmanRulePresenter.isFilterUsageAllowed(newOp, filter.usage) then
            pending.filterId = RLHerdsmanRuleEditModel.CLEAR
            Log:debug("RLMenuHerdsmanFrame:applyOperationChange: id=%s -> %s; filter usage %s not allowed, filterId cleared",
                tostring(id), newOp, tostring(filter.usage))
        end
    end

    -- Cross-type revalidation against the NEW merged op/filter - the SAME path a filter
    -- rebind runs: a switch to castrate drops chicken targets/semen; a filter cleared above
    -- widens the gate. Re-read merged so the op + filter-clear are both reflected.
    local newMerged = RLHerdsmanRuleEditModel.overlayRule(stored, self.pendingChanges[id])
    self:revalidatePendingTargetsAndSemen(id, newMerged)

    Log:debug("RLMenuHerdsmanFrame:applyOperationChange: id=%s newOp=%s (re-sectioning)", tostring(id), newOp)
    self:refreshList(id)
    self:refreshRuleDetail(stored)
end

-- =============================================================================
-- FLUSH (pending overlay -> g_rlHerdsmanRuleService:update)
-- =============================================================================

--- Flush one id's pending overlay through the real service update. Gates via the presenter's
--- enabled-conditional RLHerdsmanRulePresenter.validateFlush: nameOk + operationOk +
--- paramsOk always required; AND both husbandriesOk (>= 1 target) and a bound non-naming filter
--- are required ONLY when the rule is enabled (F7's enabled-conditional filter, the frame-side
--- twin of the relaxed service floor). A disabled / incomplete rule therefore persists as a draft (nil filterId
--- / 0 targets = no-op); enabling an unfiltered or 0-target rule SKIPs here (the narrow-revert
--- below drops just the enable, keeping unrelated edits). On a validation skip OR a service
--- reject, clears the pending overlay and reverts the display to the stored record (the next
--- render shows stored). On success, clears the overlay and refreshes the stored snapshot to
--- the persisted record.
--- @param id any
--- @return string outcome "updated" | "skipped" | "rejected"
function RLMenuHerdsmanFrame:flushPendingForId(id)
    local pending = self.pendingChanges[id]
    if pending == nil then return "skipped" end

    local stored = self:getStoredRuleById(id)
    if stored == nil then
        self.pendingChanges[id] = nil
        Log:debug("RLMenuHerdsmanFrame:flushPendingForId: id=%s no stored baseline; dropped", tostring(id))
        return "skipped"
    end

    local merged = RLHerdsmanRuleEditModel.overlayRule(stored, pending)
    local g = RLHerdsmanRulePresenter.validateFlush(merged)
    -- Gate: nameOk + operationOk + paramsOk always; husbandriesOk (>= 1 target) AND a
    -- bound non-naming filter required ONLY when enabled (F7's enabled-conditional filter, the
    -- frame-side twin of the relaxed service floor). A disabled / incomplete rule persists as a draft (nil
    -- filterId / 0 targets = no-op); an enabled rule missing either is handled by the
    -- narrow-revert below (drop just the enable), not a service reject.

    -- Narrow-revert (S2b, reconciled with the F7 enabled-conditional filter gate): if the user
    -- toggled enable this session (pending.enabled set) and the ONLY failing axes are the
    -- enable-gated ones - a 0-target rule (husbandriesRequired), an unfiltered non-naming rule
    -- (filterRequired), AND/OR a destination-less move (destinationRequired) - while name /
    -- operation / params are all valid, revert JUST the enable toggle and re-evaluate. So an
    -- unrelated name / mark / budget / maxAnimals edit made alongside an illegal enable is NOT
    -- discarded with it. Dropping enable relaxes ALL three gates, so an unfiltered / 0-target /
    -- dest-less draft then flushes (the re-eval below; a residual malformed value still falls
    -- through to the full revert). (A pre-F6 rule already persisted enabled-but-incomplete has no
    -- pending.enabled to drop, so it falls through to the full revert and stays flush-blocked
    -- until completed or disabled.)
    if not g.ok and pending.enabled ~= nil
        and g.nameOk and g.operationOk and g.paramsOk
        and ((g.husbandriesRequired and not g.husbandriesOk)
            or (g.filterRequired and not g.filterOk)
            or (g.destinationRequired and not g.destinationOk)) then
        pending.enabled = nil
        merged = RLHerdsmanRuleEditModel.overlayRule(stored, pending)
        g = RLHerdsmanRulePresenter.validateFlush(merged)
        Log:debug("RLMenuHerdsmanFrame:flushPendingForId: id=%s reverted illegal enable (missing filter, husbandry, and/or destination); re-evaluating remaining edits (ok=%s)",
            tostring(id), tostring(g.ok))
    end

    if not g.ok then
        self.pendingChanges[id] = nil
        Log:debug("RLMenuHerdsmanFrame:flushPendingForId: id=%s skipped (nameOk=%s operationOk=%s paramsOk=%s filterOk=%s husbandriesOk=%s husbandriesRequired=%s destinationOk=%s destinationRequired=%s); reverted",
            tostring(id), tostring(g.nameOk), tostring(g.operationOk), tostring(g.paramsOk),
            tostring(g.filterOk), tostring(g.husbandriesOk), tostring(g.husbandriesRequired),
            tostring(g.destinationOk), tostring(g.destinationRequired))
        return "skipped"
    end

    if g_rlHerdsmanRuleService == nil then
        self.pendingChanges[id] = nil
        Log:warning("RLMenuHerdsmanFrame:flushPendingForId: g_rlHerdsmanRuleService is nil; id=%s dropped", tostring(id))
        return "skipped"
    end

    local result = g_rlHerdsmanRuleService:update(id, merged)
    self.pendingChanges[id] = nil
    if result == nil then
        Log:warning("RLMenuHerdsmanFrame:flushPendingForId: id=%s rejected by service; reverted to stored", tostring(id))
        return "rejected"
    end

    self:replaceStoredRule(id, result)
    Log:debug("RLMenuHerdsmanFrame:flushPendingForId: id=%s update applied (name=%q operation=%s)",
        tostring(id), tostring(result.name), tostring(result.operation))
    return "updated"
end

--- Drain every pending overlay (frame close). Snapshots the id set first so clearing
--- entries mid-iteration is safe.
function RLMenuHerdsmanFrame:flushAllPending()
    local ids = {}
    for id in pairs(self.pendingChanges) do ids[#ids + 1] = id end
    for _, id in ipairs(ids) do
        local outcome = self:flushPendingForId(id)
        Log:debug("RLMenuHerdsmanFrame:flushAllPending: id=%s outcome=%s", tostring(id), tostring(outcome))
    end
end

-- =============================================================================
-- SELECTION + EMPTY STATE
-- =============================================================================

--- Seed the initial selection on open. reloadData does NOT reliably fire
--- onListSelectionChanged when the clamped section has items, so highlight row 1 AND drive
--- the detail seam by hand (mirror RLMenuInfoFrame:restoreSelection). No rules -> clear the
--- cached id + the list's visual selection and show the editor empty-state.
function RLMenuHerdsmanFrame:selectInitialRule()
    if self.rulesList == nil then return end

    local section = self.sections[1]
    local rule = section ~= nil and section.rules[1] or nil
    if rule == nil then
        self.selectedRuleId = nil
        self.rulesList.selectedSectionIndex = 0
        self.rulesList.selectedIndex = 0
        Log:debug("RLMenuHerdsmanFrame:selectInitialRule: no rules; selection cleared")
        self:refreshRuleDetail(nil)
        return
    end

    self.rulesList:setSelectedItem(1, 1, false, true)
    self.selectedRuleId = rule.id
    Log:debug("RLMenuHerdsmanFrame:selectInitialRule: row 1 -> ruleId=%s name=%q",
        tostring(rule.id), tostring(rule.name))
    self:refreshRuleDetail(self:getStoredRuleById(rule.id))
end

--- Toggle list + slider vs empty-state visibility (mirrors RLMenuSettingsFrame).
function RLMenuHerdsmanFrame:updateEmptyState()
    local hasRules = #self.sections > 0
    Log:debug("RLMenuHerdsmanFrame:updateEmptyState: sections=%d hasRules=%s", #self.sections, tostring(hasRules))
    if self.rulesList ~= nil then
        self.rulesList:setVisible(hasRules)
    end
    if self.rulesSliderBox ~= nil then
        self.rulesSliderBox:setVisible(hasRules)
    end
    if self.rulesEmptyState ~= nil then
        self.rulesEmptyState:setVisible(not hasRules)
    end
end

-- =============================================================================
-- ACTION BAR (New / Duplicate / Delete) + permission gate
-- =============================================================================

--- UX-side permission gate for the action bar. The authoritative boundary is the server-side
--- validation inside RLHerdsmanRule{Create,Update,Delete}Event:run; this only controls button
--- visibility + the per-handler early abort. Mirrors RLMenuSettingsFrame:hasCreatePermission.
--- @return boolean
function RLMenuHerdsmanFrame:hasCreatePermission()
    if g_currentMission == nil or g_currentMission.getHasPlayerPermission == nil then
        return false
    end
    return g_currentMission:getHasPlayerPermission("tradeAnimals") == true
end

--- Rebuild the single-tier footer from the current selection + permission and mark it dirty.
--- Back is always present; New on farm + tradeAnimals ONLY (never gated on selection, so the
--- empty state stays escapable); Duplicate + Delete additionally need a selection. Mirrors
--- RLMenuSettingsFrame:updateButtonVisibility (Tier 1, minus Tier 2/3).
function RLMenuHerdsmanFrame:updateButtonVisibility()
    local farmId = RLAnimalInfoService.getCurrentFarmId()
    local hasFarm = (farmId ~= nil and farmId ~= 0)
    local hasPerm = self:hasCreatePermission()
    local hasSelection = (self.selectedRuleId ~= nil)
    self.menuButtonInfo = { self.backButtonInfo }
    local appended = {}
    if hasFarm and hasPerm then
        table.insert(self.menuButtonInfo, self.newRuleButtonInfo)
        table.insert(appended, "New")
        if hasSelection then
            table.insert(self.menuButtonInfo, self.duplicateButtonInfo)
            table.insert(self.menuButtonInfo, self.deleteButtonInfo)
            table.insert(appended, "Duplicate")
            table.insert(appended, "Delete")
        end
    end
    Log:debug("RLMenuHerdsmanFrame:updateButtonVisibility: hasFarm=%s hasPerm=%s hasSelection=%s appended=[%s]",
        tostring(hasFarm), tostring(hasPerm), tostring(hasSelection), table.concat(appended, ","))
    self:setMenuButtonInfoDirty()
end

--- Collect the live rule names for the collision-incrementing default/duplicate name helpers,
--- with each rule's pending overlay applied so an in-flight rename on another row still counts.
--- @return string[] names
function RLMenuHerdsmanFrame:collectRuleNames()
    local names = {}
    for _, stored in ipairs(self.storedRules) do
        local pending = self.pendingChanges[stored.id]
        local merged = (pending ~= nil) and RLHerdsmanRuleEditModel.overlayRule(stored, pending) or stored
        names[#names + 1] = merged.name or ""
    end
    return names
end

--- Footer New handler. Gated on permission + farm ONLY (never selection). Autoflushes the
--- current selection's pending first (so a dirty edit is not lost when New steals the
--- selection), then creates a disabled Sell draft via the SAME g_rlHerdsmanRuleService:create
--- the console command + Pattern-A receivers use. On create == nil (rejected payload) warns and
--- leaves the list/selection unchanged. On success selects the new rule and refreshes.
function RLMenuHerdsmanFrame:onClickNewRule()
    if not self:hasCreatePermission() then
        Log:trace("RLMenuHerdsmanFrame:onClickNewRule: no tradeAnimals permission, aborting")
        return
    end
    local farmId = RLAnimalInfoService.getCurrentFarmId()
    if farmId == nil or farmId == 0 then
        Log:trace("RLMenuHerdsmanFrame:onClickNewRule: no farm (farmId=%s), aborting", tostring(farmId))
        return
    end
    if g_rlHerdsmanRuleService == nil then
        Log:warning("RLMenuHerdsmanFrame:onClickNewRule: g_rlHerdsmanRuleService is nil; aborting")
        return
    end

    if self.selectedRuleId ~= nil and self.pendingChanges[self.selectedRuleId] ~= nil then
        local outcome = self:flushPendingForId(self.selectedRuleId)
        Log:debug("RLMenuHerdsmanFrame:onClickNewRule: autoflush selectedId=%s outcome=%s",
            tostring(self.selectedRuleId), tostring(outcome))
    end

    local name = RLHerdsmanRulePresenter.computeDefaultRuleName(
        self:collectRuleNames(), g_i18n:getText("rl_menu_herdsman_default_name"))
    local draft = RLHerdsmanRulePresenter.buildNewRule(farmId, name)
    Log:debug("RLMenuHerdsmanFrame:onClickNewRule: creating sell draft name=%q farmId=%s", tostring(name), tostring(farmId))

    local created = g_rlHerdsmanRuleService:create(draft)
    if created == nil then
        Log:warning("RLMenuHerdsmanFrame:onClickNewRule: service rejected create (nil return); list/selection unchanged")
        return
    end
    self.selectedRuleId = created.id
    Log:debug("RLMenuHerdsmanFrame:onClickNewRule: created id=%s name=%q", tostring(created.id), tostring(created.name))
    self:refreshData()
end

--- Footer Duplicate handler. Gated on selection + permission + farm. Autoflushes the current
--- pending first (so the STORED baseline reflects the user's intent), then clones the STORED
--- record (NOT the overlay-merged view, which can be floor-invalid under the draft model) with
--- a collision-free `(copy)` name and the source's immutable farmId, via the SAME
--- g_rlHerdsmanRuleService:create. create == nil -> warn + abort. On success selects the clone.
function RLMenuHerdsmanFrame:onClickDuplicate()
    if self.selectedRuleId == nil then
        Log:trace("RLMenuHerdsmanFrame:onClickDuplicate: no selection, aborting")
        return
    end
    if not self:hasCreatePermission() then
        Log:trace("RLMenuHerdsmanFrame:onClickDuplicate: no tradeAnimals permission, aborting")
        return
    end
    local farmId = RLAnimalInfoService.getCurrentFarmId()
    if farmId == nil or farmId == 0 then
        Log:trace("RLMenuHerdsmanFrame:onClickDuplicate: no farm, aborting")
        return
    end
    if g_rlHerdsmanRuleService == nil then
        Log:warning("RLMenuHerdsmanFrame:onClickDuplicate: g_rlHerdsmanRuleService is nil; aborting")
        return
    end

    local sourceId = self.selectedRuleId
    if self.pendingChanges[sourceId] ~= nil then
        local outcome = self:flushPendingForId(sourceId)
        Log:debug("RLMenuHerdsmanFrame:onClickDuplicate: autoflush sourceId=%s outcome=%s",
            tostring(sourceId), tostring(outcome))
    end

    local stored = g_rlHerdsmanRuleService:getById(sourceId)
    if stored == nil then
        Log:warning("RLMenuHerdsmanFrame:onClickDuplicate: getById nil for id=%s; aborting", tostring(sourceId))
        return
    end

    local dupName = RLHerdsmanRulePresenter.computeDuplicateName(
        stored.name, self:collectRuleNames(),
        g_i18n:getText("rl_menu_herdsman_duplicate_suffix"),
        g_i18n:getText("rl_menu_herdsman_duplicate_suffix_n"))
    local draft = RLHerdsmanRuleEditModel.duplicateRule(stored, dupName)
    Log:debug("RLMenuHerdsmanFrame:onClickDuplicate: source=%s -> name=%q farmId=%s operation=%s",
        tostring(sourceId), tostring(dupName), tostring(stored.farmId), tostring(stored.operation))

    local created = g_rlHerdsmanRuleService:create(draft)
    if created == nil then
        Log:warning("RLMenuHerdsmanFrame:onClickDuplicate: service rejected create (nil return) for source=%s", tostring(sourceId))
        return
    end
    self.selectedRuleId = created.id
    Log:debug("RLMenuHerdsmanFrame:onClickDuplicate: created id=%s name=%q", tostring(created.id), tostring(created.name))
    self:refreshData()
end

--- Footer Delete handler. Gated on selection + permission + farm, with a g_gui dialog-visible
--- re-entry guard (also suppresses Delete while a picker dialog is open). Opens a YesNoDialog
--- with the rule name; the actual delete happens in onDeleteConfirmed on Yes. Mirrors
--- RLMenuSettingsFrame:onClickDelete (YesNoDialog is base-game, no registration).
function RLMenuHerdsmanFrame:onClickDelete()
    if self.selectedRuleId == nil then
        Log:trace("RLMenuHerdsmanFrame:onClickDelete: no selection, aborting")
        return
    end
    if not self:hasCreatePermission() then
        Log:trace("RLMenuHerdsmanFrame:onClickDelete: no tradeAnimals permission, aborting")
        return
    end
    local farmId = RLAnimalInfoService.getCurrentFarmId()
    if farmId == nil or farmId == 0 then
        Log:trace("RLMenuHerdsmanFrame:onClickDelete: no farm, aborting")
        return
    end
    if g_rlHerdsmanRuleService == nil then
        Log:warning("RLMenuHerdsmanFrame:onClickDelete: g_rlHerdsmanRuleService is nil; aborting")
        return
    end
    if g_gui:getIsDialogVisible() then
        Log:trace("RLMenuHerdsmanFrame:onClickDelete: dialog already open, ignoring re-entry")
        return
    end

    local stored = g_rlHerdsmanRuleService:getById(self.selectedRuleId)
    if stored == nil then
        Log:warning("RLMenuHerdsmanFrame:onClickDelete: getById nil for id=%s; aborting", tostring(self.selectedRuleId))
        return
    end

    local confirmText = string.format(
        g_i18n:getText("rl_menu_herdsman_delete_confirm_text"), tostring(stored.name or ""))
    Log:debug("RLMenuHerdsmanFrame:onClickDelete: opening YesNoDialog for id=%s name=%q",
        tostring(stored.id), tostring(stored.name))

    -- YesNoDialog passes (target, yesValue, callbackArgs) to its callback; target=self absorbs
    -- the colon-bound self so onDeleteConfirmed receives (yes, id). Mirrors the Settings flow.
    YesNoDialog.show(
        self.onDeleteConfirmed,
        self,
        confirmText,
        g_i18n:getText("ui_attention"),
        nil, nil, nil, nil, nil,
        stored.id
    )
end

--- YesNoDialog confirmation callback for Delete. No-ops on No. On Yes: call the SAME
--- g_rlHerdsmanRuleService:delete the console command + Pattern-A receivers use; on success
--- drop pending[id], clear the selection if it matched, refresh; on false (stale id / race)
--- preserve selection + pending and warn (the next refresh event resolves the divergence).
--- @param yes boolean
--- @param id string the rule id captured at click time
function RLMenuHerdsmanFrame:onDeleteConfirmed(yes, id)
    Log:trace("RLMenuHerdsmanFrame:onDeleteConfirmed: yes=%s id=%s", tostring(yes), tostring(id))
    if not yes then return end
    if g_rlHerdsmanRuleService == nil then
        Log:warning("RLMenuHerdsmanFrame:onDeleteConfirmed: g_rlHerdsmanRuleService is nil; aborting")
        return
    end
    local ok = g_rlHerdsmanRuleService:delete(id)
    if ok then
        self.pendingChanges[id] = nil
        if self.selectedRuleId == id then self.selectedRuleId = nil end
        Log:debug("RLMenuHerdsmanFrame:onDeleteConfirmed: deleted id=%s", tostring(id))
        self:refreshData()
    else
        Log:warning("RLMenuHerdsmanFrame:onDeleteConfirmed: service:delete returned false for id=%s; preserving selection + pending (stale id or race)",
            tostring(id))
    end
end

-- =============================================================================
-- REFRESH (local CRUD + remote MP event hook)
-- =============================================================================

--- Re-read the rule registry for the current farm, KEEPING the local pending overlay
--- (local-pending-wins for F7; the authoritative-surface mid-edit reconcile is deferred).
--- Drops pending whose id is gone from the re-read snapshot (orphan prune) and clears the
--- selection to the empty-state when the selected id was pruned (so a stale focused input
--- cannot re-stash a resurrected orphan). Rebuilds + reloads under isReconciling, re-pins the
--- selection by id (so a remotely re-sectioned rule re-pins), then refreshes empty-state +
--- footer + banner + detail. Mirrors RLMenuSettingsFrame:refreshData.
function RLMenuHerdsmanFrame:refreshData()
    local farmId = RLAnimalInfoService.getCurrentFarmId()
    local rules = {}
    if farmId == nil or farmId == 0 then
        Log:debug("RLMenuHerdsmanFrame:refreshData: no farm (farmId=%s); empty rule list", tostring(farmId))
    elseif g_rlHerdsmanRuleService == nil then
        Log:warning("RLMenuHerdsmanFrame:refreshData: g_rlHerdsmanRuleService is nil; empty rule list")
    else
        rules = g_rlHerdsmanRuleService:listForFarm(farmId)
    end
    self.storedRules = rules

    -- Orphan prune: drop any pending overlay whose id is no longer present (a remote delete),
    -- and clear the selection to the empty-state if its id went.
    local liveIds = {}
    for _, stored in ipairs(self.storedRules) do liveIds[stored.id] = true end
    local pruned = 0
    for pid in pairs(self.pendingChanges) do
        if not liveIds[pid] then
            self.pendingChanges[pid] = nil
            pruned = pruned + 1
        end
    end
    if self.selectedRuleId ~= nil and not liveIds[self.selectedRuleId] then
        Log:debug("RLMenuHerdsmanFrame:refreshData: selected id=%s gone remotely; clearing selection", tostring(self.selectedRuleId))
        self.selectedRuleId = nil
    end

    self:rebuildDisplaySections()
    self.isReconciling = true
    if self.rulesList ~= nil then
        self.rulesList:reloadData()
        if self.selectedRuleId ~= nil then
            local s, i = self:findSelectionById(self.selectedRuleId)
            if s ~= nil then
                self.rulesList:setSelectedItem(s, i, false, true)
            end
        else
            -- No selection (pruned to empty, or nothing was selected): clear the SmoothList's
            -- own visual selection too, so the left pane does not keep a stale row highlighted
            -- over the empty-state detail pane (mirror selectInitialRule's no-rules branch).
            self.rulesList.selectedSectionIndex = 0
            self.rulesList.selectedIndex = 0
        end
    end
    self.isReconciling = false

    self:updateEmptyState()
    self:updateButtonVisibility()
    self:refreshBanner(farmId)

    -- Tail the detail render so the right pane reflects the re-pinned selection (or the empty
    -- state when the selection was pruned). refreshRuleDetail re-applies the kept overlay.
    local stored = (self.selectedRuleId ~= nil) and self:getStoredRuleById(self.selectedRuleId) or nil
    self:refreshRuleDetail(stored)

    Log:debug("RLMenuHerdsmanFrame:refreshData: farmId=%s rules=%d pruned=%d selectedId=%s",
        tostring(farmId), #self.storedRules, pruned, tostring(self.selectedRuleId))
end

--- Refresh only when the frame is currently open. Called by the RLHerdsmanRule{Create,Update,
--- Delete,State}Event:run handlers AND the RLFilter{Create,Update,Delete}Event:run handlers
--- (a remote filter rename/delete changes rule filter-summaries) so remote mutations re-render
--- without reopening the menu. Idempotent (Pattern-A guarantees the originator never enters its
--- own CRUD run()). Mirrors RLMenuSettingsFrame:refreshIfOpen.
function RLMenuHerdsmanFrame:refreshIfOpen()
    if self.isFrameOpen then
        Log:debug("RLMenuHerdsmanFrame:refreshIfOpen: refreshing")
        self:refreshData()
    else
        Log:debug("RLMenuHerdsmanFrame:refreshIfOpen: frame closed, skipping")
    end
end

-- =============================================================================
-- LEGACY-ACTIVE BANNER (read-only coexistence warning, D13)
-- =============================================================================

--- Read-only enumeration of the farm's live husbandries' legacy AI settings into the plain
--- `{ name, settings }` entries RLHerdsmanRulePresenter.isLegacyActive consumes. Every hop is
--- nil-guarded: a husbandry whose manager / getSettings is missing (unloaded placeable)
--- contributes nothing. getAIManager returns the manager built at onLoad (no save/sync side
--- effect); getSettings() (no arg) returns the whole per-op `settings` table keyed by operation.
--- @param farmId number|nil
--- @return table entries array of { name = string, settings = table }
function RLMenuHerdsmanFrame:gatherLegacyEntries(farmId)
    local entries = {}
    if farmId == nil or farmId == 0 then return entries end
    local husbandries = RLAnimalQuery.listHusbandriesForFarm(farmId)
    for i, h in ipairs(husbandries) do
        local settings = nil
        if h ~= nil and h.getAIManager ~= nil then
            local mgr = h:getAIManager()
            if mgr ~= nil and mgr.getSettings ~= nil then
                settings = mgr:getSettings()
            end
        end
        if type(settings) == "table" then
            entries[#entries + 1] = { name = RLAnimalQuery.formatHusbandryLabel(h, i), settings = settings }
        end
    end
    return entries
end

--- Re-evaluate + toggle the fixed-text legacy-active banner. Gathers the read-only legacy
--- entries for the given farm, asks the pure RLHerdsmanRulePresenter.isLegacyActive, and
--- setVisible the banner. The caller passes the SAME farmId it read for the rule list so the
--- banner and the list never disagree within one refresh (resolves it itself only if omitted).
--- Best-effort: re-evaluated on frame open + rule/filter refresh only, and AIAnimalManager has
--- no read/writeStream, so a client reflects savegame-loaded legacy state (not an in-session
--- server toggle).
--- @param farmId number|nil owning farm id (resolved from the current farm when nil)
function RLMenuHerdsmanFrame:refreshBanner(farmId)
    if self.legacyBanner == nil then return end
    if AIAnimalManager.FREEZE_LEGACY_HERDSMAN then
        self.legacyBanner:setVisible(false)
        Log:trace("RLMenuHerdsmanFrame:refreshBanner: legacy-herdsman-freeze active; banner hidden")
        return
    end
    if farmId == nil then farmId = RLAnimalInfoService.getCurrentFarmId() end
    local entries = self:gatherLegacyEntries(farmId)
    local active, affectedNames = RLHerdsmanRulePresenter.isLegacyActive(entries)
    self.legacyBanner:setVisible(active == true)
    Log:debug("RLMenuHerdsmanFrame:refreshBanner: farmId=%s entries=%d active=%s affected=%d",
        tostring(farmId), #entries, tostring(active), #affectedNames)
end
