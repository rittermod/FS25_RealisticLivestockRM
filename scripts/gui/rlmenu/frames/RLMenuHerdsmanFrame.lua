--[[
    RLMenuHerdsmanFrame.lua
    RL Tabbed Menu Herdsman tab - rule list (master) + rule editor (detail).

    The list binds to the real rule registry; the right pane edits name / operation / enabled
    / op-params plus read-only filter and husbandry summaries. Edits stash to a per-id pending
    overlay and flush through g_rlHerdsmanRuleService:update, so MP syncs through the
    resulting RLHerdsmanRuleUpdateEvent.

    Bind-only by design: visibility, validation, domains and summaries route to
    RLHerdsmanRulePresenter, the overlay merge and op-change carry-over to
    RLHerdsmanRuleEditModel. The frame holds only element read/write, lookups over the
    presenter domains, the live dewar enumeration, label formatting, nil-guards and logging.
]]

RLMenuHerdsmanFrame = {}
local RLMenuHerdsmanFrame_mt = Class(RLMenuHerdsmanFrame, TabbedMenuFrameElement)

local Log = RmLogging.getLogger("RLRM")

-- Store mod directory at source time (g_currentModDirectory only valid during source())
local modDirectory = g_currentModDirectory

-- operation -> section-header i18n key, for the list headers and the Operation selector.
-- Both readers TOLERATE a missing entry, because a nil key once crashed the game through
-- the I18N.getText override. The map is expected COMPLETE over OPERATION_ORDER, and a
-- test sweep is what enforces that - which is why it is exported below.
local OPERATION_TITLE_KEY = {
    sell      = "rl_menu_herdsman_section_sell",
    move      = "rl_menu_herdsman_section_move",
    buy       = "rl_menu_herdsman_section_buy",
    castrate  = "rl_menu_herdsman_section_castrate",
    naming    = "rl_menu_herdsman_section_naming",
    ai        = "rl_menu_herdsman_section_ai",
    horseCare = "rl_menu_herdsman_section_horsecare",
}

-- Exported read-only so a test can sweep it against OPERATION_ORDER: a declaration table
-- no test can see is a declaration nothing checks. Read it; never mutate it.
RLMenuHerdsmanFrame.OPERATION_TITLE_KEY = OPERATION_TITLE_KEY

-- Row field -> the bounds string an "invalid" row marker renders. Only the two numeric rows
-- can ever be invalid, so a field absent here is not a gap. The args are read from the
-- presenter at CALL time, so the sentence and the rule that rejected the value cannot drift.
local REASON_INVALID = {
    maxAnimals = {
        key = "rl_menu_herdsman_detail_wholeNumberRange",
        args = function()
            return RLHerdsmanRulePresenter.MAXANIMALS_MIN, RLHerdsmanRulePresenter.MAXANIMALS_MAX
        end,
    },
    -- budget.fixed has a lower bound only, so it uses the one-placeholder string.
    ["budget|fixed"] = {
        key = "rl_menu_herdsman_detail_wholeNumberMin",
        args = function() return RLHerdsmanRulePresenter.BUDGET_FIXED_MIN end,
    },
}

-- Exported read-only for the same reason as OPERATION_TITLE_KEY. Never mutate it.
RLMenuHerdsmanFrame.REASON_INVALID = REASON_INVALID

-- =============================================================================
-- Module-local helpers (pure wiring; no decisions)
-- =============================================================================

--- Resolve the declared animal type NAMES into live indices as a `name -> index` map. An
--- unresolved name is OMITTED rather than mapped to nil, which gives the gate its polarity
--- for free. Resolution is per call, never memoized: `AnimalType` is populated after this
--- file is sourced, so a cached empty map would close the horse gate for the session.
---@return table animalTypeIndexByName map of resolved NAME -> live animalType index (possibly empty)
function RLMenuHerdsmanFrame.buildAnimalTypeIndexMap()
    -- The nil check comes FIRST: past it the names would be computed and thrown away. A
    -- missing registry is a load-order fault, which an empty map alone cannot express.
    if AnimalType == nil then
        Log:warning("RLMenuHerdsmanFrame.buildAnimalTypeIndexMap: AnimalType registry is nil; the operation x animalType gate gets an EMPTY map (allow-lists admit nothing, exclude-lists exclude nothing) - check AnimalSystem load order")
        return {}
    end

    local map, missing = RLHerdsmanRuleService.resolveAnimalTypeIndexMap(AnimalType)

    -- Rendered sorted so the line is reproducible between runs (a `pairs` walk is hash-ordered).
    local resolved = {}
    for name, idx in pairs(map) do
        resolved[#resolved + 1] = string.format("%s=%s", name, tostring(idx))
    end
    table.sort(resolved)

    if #missing > 0 then
        Log:debug("RLMenuHerdsmanFrame.buildAnimalTypeIndexMap: %d/%d declared type(s) absent from this map [%s]; the gate treats each as no-match",
            #missing, #resolved + #missing, table.concat(missing, ","))
    end
    Log:trace("RLMenuHerdsmanFrame.buildAnimalTypeIndexMap: resolved [%s]", table.concat(resolved, " "))
    return map
end

--- 1-based index of `value` in `values`, or nil: the bridge between the presenter's value
--- domains and a widget state.
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

--- Caret-safe setText: a value push resets the caret to text-end, stomping the user
--- mid-edit, so skip it while the input is focused and already matches.
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

--- Force a BinaryOption's slider onto `targetState`. A bare setState short-circuits when
--- the state already matches and never re-seats a slider stranded while the row was hidden,
--- so this toggles THROUGH the opposite state to make the terminal push a real change.
--- CALL ONLY ON A VISIBLE toggle: a hidden one gets no update(dt) and the push strands.
--- The toggle-through emits TWO notifyIndexChange notifications, so never attach an
--- index-change observer to a toggle seated this way.
---@param toggle table|nil BinaryOptionElement
---@param targetState number BinaryOptionElement.STATE_LEFT (1) or STATE_RIGHT (2)
local function forceSeatToggle(toggle, targetState)
    if toggle == nil or toggle.setState == nil then return end
    local opposite = targetState == BinaryOptionElement.STATE_RIGHT
        and BinaryOptionElement.STATE_LEFT or BinaryOptionElement.STATE_RIGHT
    toggle:setState(opposite, false, true)
    toggle:setState(targetState, false, true)
end

--- Injected filter resolver for the presenter summaries. nil-safe: a missing service or
--- unknown id yields nil, and the presenter substitutes its own label.
---@param filterId any
---@return table|nil filter record
local function resolveFilterById(filterId)
    if filterId == nil or g_rlFilterService == nil then return nil end
    return g_rlFilterService:getById(filterId)
end

--- Injected placeable-name resolver for the target summary and the destination button. An
--- EPP-shaped placeable gets the shared "(butcher)" suffix so the button label agrees with
--- the picker rows. A stale or unresolvable key returns nil rather than crashing.
---@param key any stable target/dest key (uniqueId server / net-object-id client)
---@return string|nil placeable name (with the "(butcher)" suffix for an EPP dest)
local function resolvePlaceableName(key)
    local placeable = RLHusbandryTargetKey.resolveDestination(key)
    if placeable == nil or placeable.getName == nil then return nil end
    local isEPP = placeable.spec_extendedProductionPoint ~= nil
    return RLAnimalQuery.composeDestinationLabel(placeable:getName(), isEPP)
end

--- Order-insensitive multiset equality, for the husbandry-pick no-op check: the picker
--- commits in name-sorted order, so comparing as arrays would broadcast a re-order that
--- changed no membership. Duplicates count, so a genuine add or remove still registers.
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
--- @return table self The new frame instance
function RLMenuHerdsmanFrame.new()
    local self = RLMenuHerdsmanFrame:superClass().new(nil, RLMenuHerdsmanFrame_mt)
    self.name = "RLMenuHerdsmanFrame"
    self.isFrameOpen = false
    -- One-shot layout-measurement guard, flipped once the stretched containers settle.
    self.didMeasureLayout = false
    -- Open-time stored rules (the flush baseline), the overlay-merged display sections,
    -- per-id pending edits, and the current selection.
    self.storedRules = {}
    self.sections = {}
    self.pendingChanges = {}
    self.selectedRuleId = nil
    -- The rule id captured when each picker OPENS, so the pick stashes against THAT id even
    -- if the list selection moves while the modal is up.
    self.filterPickTargetId = nil
    self.husbandryPickTargetId = nil
    self.destinationPickTargetId = nil
    self.isReconciling = false
    -- Set while refreshRuleDetail pushes values in: the TextInput handlers early-return on
    -- it, so a programmatic setText is not mistaken for a user edit.
    self.isPopulating = false
    self.didMeasureFirstRow = false
    -- One-shot seat-observation guard, armed per selection and drained at the update seam
    -- once the re-seated sliders settle. Starts drained.
    self.didLogSeat = true
    self.seatLogExpected = nil
    Log:trace("RLMenuHerdsmanFrame.new: instance created")
    return self
end

--- Load the herdsman frame XML and register the frame with g_gui. Must run before the menu
--- XML loads, so its FrameReference resolves.
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

--- Resolve element references, bind the rule list, and seed the fixed-domain selector texts
--- once. The semen selector is rebuilt per render, from the live dewar pool.
function RLMenuHerdsmanFrame:onGuiSetupFinished()
    RLMenuHerdsmanFrame:superClass().onGuiSetupFinished(self)

    self.rulesList           = self:getDescendantById("rulesList")
    self.rulesListContainer  = self:getDescendantById("rulesListContainer")
    self.rulesSliderBox      = self:getDescendantById("rulesSliderBox")
    self.ruleEditorContainer = self:getDescendantById("ruleEditorContainer")
    self.rulesEmptyState     = self:getDescendantById("rulesEmptyState")
    self.headerPanel         = self:getDescendantById("headerPanel")

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

    -- Seed the fixed-domain selector texts once, in OPERATION_ORDER.
    if self.ruleOperationSelector ~= nil then
        local opTexts = {}
        for i, op in ipairs(RLHerdsmanRulePresenter.OPERATION_ORDER) do
            -- Backstop, not a supported state: a missing title key falls back to the raw
            -- name rather than crashing getText. Reaching it in a shipped build is a defect.
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
        -- The Mark row is the Action selector: state 1 Perform (mark=false), state 2
        -- Mark only (mark=true).
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

    -- Per-row tooltip help lines. The tooltip Text hangs off each row's VALUE WIDGET, not
    -- the row container, which clips to its bounds; getDescendantByName is recursive, so
    -- grabbing off the row still finds it. setVisible(true) covers a profile defaulting hidden.
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

    -- Per-row REASON lines: a second Text stacked in the same value widget, carrying the
    -- required / out-of-range marker, grabbed only for the six rows that carry one. A
    -- missing node on a covered row is a wiring defect, so it is an ERROR, not a trace.
    self.reasons = {}
    local function grabReason(row, field)
        if row == nil then return end
        local r = row:getDescendantByName("reason")
        if r == nil then
            Log:error("RLMenuHerdsmanFrame:onGuiSetupFinished: covered row '%s' has no reason child; the row marker cannot render (herdsmanFrame.xml out of sync with this file)", field)
            return
        end
        r:setVisible(true)
        self.reasons[field] = r
    end
    grabReason(self.ruleNameRow, "name")
    grabReason(self.ruleMaxAnimalsRow, "maxAnimals")
    grabReason(self.ruleBudgetFixedRow, "budget|fixed")
    grabReason(self.ruleFilterRow, "filter")
    grabReason(self.ruleHusbandriesRow, "husbandries")
    grabReason(self.ruleDestinationRow, "destination")

    -- Single-tier action bar: Back / New / Duplicate / Delete, rebuilt per selection and
    -- permission by updateButtonVisibility. hasCustomMenuButtons makes the first page switch
    -- use self.menuButtonInfo, avoiding a one-frame flicker.
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

--- Called by the Paging element when this tab becomes active: read the registry, build the
--- sections, seed the selection, focus the list. Pending edits reset per open.
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
    -- Start drained so a no-rule open logs nothing; the seeded selection re-arms it.
    self.didLogSeat = true
    self.seatLogExpected = nil
    self.pendingChanges = {}

    -- Edits and create/delete write back through this same service, and MP syncs through
    -- it. RLHerdsmanRulePresenter owns grouping, order and sort.
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

    if self.rulesList ~= nil then
        FocusManager:setFocus(self.rulesList)
    end
end

--- Deactivation hook: clears isFrameOpen BEFORE draining the overlays, or a rebroadcast
--- arriving mid-flush re-enters the refresh path and fights the drain loop.
function RLMenuHerdsmanFrame:onFrameClose()
    RLMenuHerdsmanFrame:superClass().onFrameClose(self)
    self.isFrameOpen = false
    self:flushAllPending()
    -- Drop the picker open-time ids: an ESC dismiss closes the dialog without firing the
    -- cancel callback, so they would dangle until the next open re-captured them.
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

--- Log the containers' size and top edge against the header baseline, so the master-detail
--- placement is provable from the log. Returns false while either container is unsettled,
--- so update()'s one-shot guard retries. absPosition is the BOTTOM edge (FS25 is Y-up).
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

    return true
end

--- One-shot proof that the op-param sliders seated on their stored option. The physical move
--- runs in BinaryOptionElement:update(dt), so this returns false while any slider is still
--- moving and the update seam retries. Hidden toggles are never in the list.
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

--- Rebuild the display sections from the stored snapshot with each rule's overlay applied,
--- so a pending op-change moves the rule and a pending name re-sorts it.
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

--- Rebuild the sections, reload the list and re-highlight `id`, under the isReconciling
--- guard so the synchronous selection delegate cannot re-enter the render and stomp the caret.
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

--- Populate one rule row. The sections already carry the overlay-merged record, so the row
--- name reflects pending edits live.
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

--- Selection delegate: autoflush the outgoing rule, then refresh the detail pane from the
--- STORED baseline, which re-applies the overlay. Suppressed during a programmatic reload.
--- @param list table
--- @param section number
--- @param index number
function RLMenuHerdsmanFrame:onListSelectionChanged(list, section, index)
    if list ~= self.rulesList then return end
    if self.isReconciling then
        Log:trace("RLMenuHerdsmanFrame:onListSelectionChanged: suppressed during reconcile")
        return
    end

    -- The advance is unconditional, so a rejected flush cannot strand the user.
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

--- Populate the rule editor from the overlay-merged record. The pushes are programmatic:
--- setState is silent, but setText fires onTextChanged, so the whole block runs under
--- isPopulating and the TextInput handlers early-return while it is set.
--- @param stored table|nil the STORED rule record (overlay is re-applied here), or nil
function RLMenuHerdsmanFrame:refreshRuleDetail(stored)
    if stored == nil then
        setRowVisible(self.ruleEditorLayout, false)
        if self.ruleEditorEmpty ~= nil then self.ruleEditorEmpty:setVisible(true) end
        -- Disarm the seat proof: the toggles are hidden now, so a still-armed expectation
        -- would drain stale proof at the update seam. A real selection re-arms it.
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

    -- Op-param target states, derived ONCE so the value push, the re-seat and the tooltip
    -- block read one source and cannot drift.
    local markState       = (p.mark == true) and 2 or 1
    local conventionState = indexOfValue(self.conventionValues, p.convention) or 1
    local budgetTypeState = indexOfValue(self.budgetTypeValues, budget and budget.type) or 1

    -- Save/restore rather than set/clear, because refreshRuleDetail re-enters from genuine
    -- option edits. The pcall guarantees the flag clears even if an engine push raises;
    -- the re-raise preserves the existing propagation.
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
        -- Always push a deterministic state, so a buy rule with no budget table cannot show
        -- a stale toggle or input.
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

    -- Re-seat the toggles now that visibility is final. The value pushes above ran while the
    -- rows still carried the PREVIOUS rule's visibility, and setState short-circuits on an
    -- unchanged state, so a hidden or same-value push leaves the slider stranded. A hidden
    -- toggle is left alone: it gets no update(dt), and re-seats when it next shows.
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

    -- Arm the seat-observation log, drained at the update seam once the sliders settle. Only
    -- VISIBLE toggles are proven; a hidden one receives no update, so there is nothing to prove.
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
        -- Both empty states invite a pick on an actionable button, so they collapse to one
        -- CTA rather than keeping the (none) / (missing) wording.
        local selectText = g_i18n:getText("rl_menu_herdsman_filter_select")
        self.ruleFilterButton:setText(RLHerdsmanRulePresenter.getFilterSummary(
            merged.filterId, resolveFilterById, { none = selectText, missing = selectText }))
    end
    -- One-shot Filter-row geometry, so the in-row button vs title layout is provable from
    -- the log. absPosition is the bottom-left edge (FS25 is Y-up).
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
        -- Label: 0 targets is a CTA, 1 is that husbandry's name, 2+ is the count form.
        local selectText = g_i18n:getText("rl_menu_herdsman_husbandry_select")
        self.ruleHusbandriesButton:setText(RLHerdsmanRulePresenter.formatHusbandryButtonLabel(
            merged.targetHusbandries, resolvePlaceableName, {
                none     = selectText,
                missing  = labels.missing,
                selected = g_i18n:getText("rl_menu_herdsman_husbandry_count"),
            }))
    end
    -- One-shot Husbandries-row geometry, as for the Filter row above.
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
        -- Label (move only): the destination name, a CTA when none is picked, or (missing).
        local selectText = g_i18n:getText("rl_menu_herdsman_destination_select")
        self.ruleDestinationButton:setText(RLHerdsmanRulePresenter.formatDestinationButtonLabel(
            p.destinationHusbandry, resolvePlaceableName, { none = selectText, missing = labels.missing }))
    end
    -- One-shot Destination-row geometry, as for the Husbandries row above.
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

    -- Per-row help text, re-resolved every render because an op-change swaps the strings.
    -- Conditional rows are gated exactly as their setVisible toggles above.
    local enabledState    = (merged.enabled == true) and 2 or 1
    -- Resolve semen from the SELECTOR's snapped index, not raw p.semen: the selector snaps a
    -- stale dewar id to "any", so the tooltip must follow the DISPLAYED option or a stale
    -- dewar renders the dewar tooltip filled with the "any" label.
    local semenIdx        = indexOfValue(self.semenValues, p.semen or RLHerdsmanRulePresenter.SEMEN_ANY) or 1
    local semenValue      = self.semenValues[semenIdx] or RLHerdsmanRulePresenter.SEMEN_ANY
    local semenOptionText = (self.semenTexts ~= nil and self.semenTexts[semenIdx]) or ""

    -- Clear every covered row FIRST. tip() runs only for rows this render shows, so a row
    -- hidden by an op-change would keep its last marker and show it again on return; and the
    -- editor is already visible, so a raise below would strand the PREVIOUS rule's markers on
    -- the pane. Clearing first makes either failure blank rather than wrong.
    for field in pairs(self.reasons) do
        self:applyRowReason(field, nil)
    end

    -- Repair markers resolved ONCE for the pane and written inside tip(), so the marker and
    -- the help line share one gating decision and one write path. The resolvers are the ones
    -- the summaries use, so a reference the button renders as a CTA is the one marked.
    local issues = RLHerdsmanRulePresenter.rowIssues(merged, resolveFilterById, resolvePlaceableName)

    local tipKeys = {}
    local reasonMarks = {}
    local function tip(field, state, value, raw)
        local key = self:applyRowTooltip(self.tooltips[field], field, op, state, value, raw)
        if key ~= nil then tipKeys[#tipKeys + 1] = field .. "=" .. key end
        local issue = issues[field]
        self:applyRowReason(field, issue)
        if issue ~= nil then reasonMarks[#reasonMarks + 1] = field .. "=" .. issue end
    end
    -- ORDER IS LOAD-BEARING and pinned outside this file: the reason marks reach the debug
    -- line in the order these calls run, and an ordered log assertion requires husbandries
    -- before filter. Reordering for readability turns that red with no signal here.
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
    Log:debug("RLMenuHerdsmanFrame:refreshRuleDetail: tooltips op=%s keys[%s] reasons[%s]",
        tostring(op), table.concat(tipKeys, " "), table.concat(reasonMarks, " "))

    -- One-shot in-row geometry of the TextInput rows and their tooltip Text.
    self:logTooltipRowGeometryOnce("ruleNameRow", self.ruleNameRow, self.tooltips["name"], "didMeasureNameRow")
    if vis.maxAnimals then
        self:logTooltipRowGeometryOnce("ruleMaxAnimalsRow", self.ruleMaxAnimalsRow, self.tooltips["maxAnimals"], "didMeasureMaxAnimalsRow")
    end
    if bvis.fixed then
        self:logTooltipRowGeometryOnce("ruleBudgetFixedRow", self.ruleBudgetFixedRow, self.tooltips["budget|fixed"], "didMeasureBudgetFixedRow")
    end

    -- Tint the visible rows and reflow, so the hidden rows collapse rather than leave gaps.
    -- MUST run after the setVisible toggles above.
    self:updateAlternatingElements(self.ruleEditorLayout)

    Log:debug("RLMenuHerdsmanFrame:refreshRuleDetail: ruleId=%s op=%s visible[maxAnimals=%s mark=%s convention=%s budget=%s budgetFixed=%s budgetPct=%s semen=%s filter=%s]",
        tostring(merged.id), tostring(op), tostring(vis.maxAnimals), tostring(vis.mark),
        tostring(vis.convention), tostring(vis.budget), tostring(bvis.fixed), tostring(bvis.percentage),
        tostring(vis.semen), tostring(vis.filter))
end

--- Format a live param value into a tooltip's single `%s`, per the descriptor's `arg`. The
--- percent branch mirrors how the selector is seeded, so a non-member value reads the
--- selector's displayed whitelist value rather than a bare 0.
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

--- Resolve and write ONE row's tooltip from the presenter descriptor. A nil descriptor or a
--- missing element writes nothing; the written key is returned for the per-render log.
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

--- Write ONE row's REASON line from its issue token. Touches ONLY self.reasons, never
--- self.tooltips: separate write paths are what makes the two Texts unable to clobber each
--- other, so no precedence rule between them is needed.
--- @param field string row field token
--- @param issue string|nil "required" | "invalid" | nil
function RLMenuHerdsmanFrame:applyRowReason(field, issue)
    local elem = self.reasons[field]
    if elem == nil then return end

    if issue == nil then
        elem:setText("")
        return
    end

    if issue == "required" then
        elem:setText(g_i18n:getText("rl_menu_herdsman_detail_required"))
        return
    end

    local bounds = REASON_INVALID[field]
    if bounds == nil then
        -- Unreachable today, and warned rather than silently blank so a row that starts
        -- reporting it is visible. ONE-SHOT per field: this sits on the per-keystroke path,
        -- so an unlatched warning would write a line per character typed.
        self._warnedNoBounds = self._warnedNoBounds or {}
        if not self._warnedNoBounds[field] then
            self._warnedNoBounds[field] = true
            Log:warning("RLMenuHerdsmanFrame:applyRowReason: field '%s' reported issue '%s' with no bounds string; row left blank (warned once per field)",
                tostring(field), tostring(issue))
        end
        elem:setText("")
        return
    end

    elem:setText(string.format(g_i18n:getText(bounds.key), bounds.args()))
end

--- Live-update ONE value row's tooltip and marker after a TextInput edit, WITHOUT a full
--- refreshRuleDetail: a re-render would push the canonicalised number into the FOCUSED
--- input and stomp the caret on partial input like "05" or "5.".
--- @param field string the row field token ("name" | "maxAnimals" | "budget|fixed")
--- @param raw any the live value to format into the tooltip %s
function RLMenuHerdsmanFrame:refreshValueRowTooltip(field, raw)
    local id = self.selectedRuleId
    if id == nil then return end
    local stored = self:getStoredRuleById(id)
    if stored == nil then return end
    local merged = RLHerdsmanRuleEditModel.overlayRule(stored, self.pendingChanges[id])
    self:applyRowTooltip(self.tooltips[field], field, merged.operation, nil, nil, raw)
    -- The caller already stashed the keystroke, so the merged draft carries what was typed.
    local issues = RLHerdsmanRulePresenter.rowIssues(merged, resolveFilterById, resolvePlaceableName)
    self:applyRowReason(field, issues[field])
end

--- One-shot geometry of a TextInput row and its tooltip Text, so the anchoring is provable
--- from the log rather than eyeballed. absPosition is the bottom-left edge (FS25 is Y-up).
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

--- Alternately tint the visible editor rows and reflow, so the per-operation hidden rows
--- collapse rather than leave gaps. Rows without setImageColor are left untinted.
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

--- Build the semen selector options: "any" plus the live dewar pool for the rule's filter
--- animalType. Every hop is nil-guarded, so it degrades to just "any". A stored semen no
--- longer in the pool snaps the selector to "any" SILENTLY, so the stored id survives a flush.
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
    -- Parallel to semenValues: the tooltip's %s is the dewar's label at the same index.
    self.semenTexts = texts
    self.ruleSemenSelector:setTexts(texts)
    local storedSemen = (merged.params and merged.params.semen) or RLHerdsmanRulePresenter.SEMEN_ANY
    self.ruleSemenSelector:setState(indexOfValue(values, storedSemen) or 1, false)
    Log:trace("RLMenuHerdsmanFrame:populateSemenSelector: %d option(s), selected=%s", #values, tostring(storedSemen))
end

--- The rule's animalType gate: the filter's animalType, or nil for ANY. The single source
--- for both the husbandry-target gate and the semen dewar pool.
--- @param filterId any
--- @return number|nil
function RLMenuHerdsmanFrame:resolveFilterAnimalType(filterId)
    if filterId == nil then return nil end
    local filter = resolveFilterById(filterId)
    if filter == nil then return nil end
    return filter.animalType
end

--- The animalType index for the semen dewar pool: the rule's filter animalType.
--- @param filterId any
--- @return number|nil
function RLMenuHerdsmanFrame:resolveSemenAnimalTypeIndex(filterId)
    return self:resolveFilterAnimalType(filterId)
end

-- =============================================================================
-- FILTER PICKER (in-row button -> dialog -> stash filterId)
-- =============================================================================

--- Filter row button click: open the single-select picker scoped to the rule's operation. A
--- nil usage, farmId or service would make listAvailable a list-everything WILDCARD, so the
--- picker refuses to open in that case.
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

    -- listAvailable folds ANY filters in, so a non-nil usage and farmId yield exactly the
    -- operation's pool. Then drop filters whose animalType the operation forbids, keeping
    -- ANY-type, and sort alphabetically for the picker.
    local animalTypeIndexByName = RLMenuHerdsmanFrame.buildAnimalTypeIndexMap()
    local scoped = RLHerdsmanRulePresenter.filterCandidateFilters(
        g_rlFilterService:listAvailable(nil, farmId, pickerUsage), merged.operation, animalTypeIndexByName)
    local candidates = RLHerdsmanRulePresenter.sortFiltersByName(scoped)

    -- A current binding the gate dropped is no longer in the list; flag it so the picker
    -- says "current unavailable" rather than preselecting row 1 and rebinding on OK.
    local currentUnavailable = false
    if merged.filterId ~= nil then
        currentUnavailable = true
        for _, f in ipairs(candidates) do
            if f.id == merged.filterId then currentUnavailable = false; break end
        end
    end

    -- Capture at OPEN: the pick stashes against THIS id even if the selection moves.
    self.filterPickTargetId = id

    Log:debug("RLMenuHerdsmanFrame:onClickRuleFilter: id=%s operation=%s usage=%s farmId=%s -> %d candidate(s) currentFilterId=%s currentUnavailable=%s",
        tostring(id), tostring(merged.operation), tostring(pickerUsage), tostring(farmId), #candidates, tostring(merged.filterId), tostring(currentUnavailable))

    RLHerdsmanFilterPickerDialog.show(self.onFilterPicked, self, candidates, merged.filterId, currentUnavailable)
end

--- Filter picker result: nil cancels, and a re-pick of the current binding with nothing else
--- pending is a no-op rather than a redundant update. Flush stays on the selection-change
--- and close paths.
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

    -- Revalidate against the NEW merged record, pinned so two edits compose.
    local newMerged = RLHerdsmanRuleEditModel.overlayRule(stored, self.pendingChanges[id])
    self:revalidatePendingTargetsAndSemen(id, newMerged)
    -- Recompute first, so the destination sees the post-revalidation source set.
    local afterTargets = RLHerdsmanRuleEditModel.overlayRule(stored, self.pendingChanges[id])
    self:revalidatePendingDestination(id, afterTargets, afterTargets.targetHusbandries)
    -- Demote before the render, so the toggle already shows off if the rebind stranded it.
    self:demoteEnableIfInvalidated(id)
    self:refreshRuleDetail(stored)
end

-- =============================================================================
-- HUSBANDRY PICKER (in-row button -> dialog -> stash targetHusbandries)
-- =============================================================================

--- Husbandries row button click: open the multi-select picker scoped to the rule's filter
--- animalType and operation. Refuses to open without a farm or husbandry system.
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

    -- Capture at OPEN: the pick stashes against THIS id even if the selection moves.
    self.husbandryPickTargetId = id

    Log:debug("RLMenuHerdsmanFrame:onClickRuleHusbandries: id=%s operation=%s filterType=%s farmId=%s -> %d candidate(s), %d current target(s)",
        tostring(id), tostring(merged.operation), tostring(filterAnimalType), tostring(farmId),
        #candidates, #(merged.targetHusbandries or {}))

    RLHerdsmanHusbandryPickerDialog.show(self.onHusbandriesPicked, self, candidates, merged.targetHusbandries or {})
end

--- Husbandry picker result: nil cancels. The dialog already preserved out-of-scope and
--- unresolvable targets, so the set is stashed as-is and NOT re-stripped - the
--- type-incompatible drop is a rebind concern, not a pick concern.
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

    -- Set compare, not array: the picker commits in name-sorted order, so an array compare
    -- would broadcast a re-order that changed no membership.
    if sameStringSet(merged.targetHusbandries, uniqueIds) then
        Log:debug("RLMenuHerdsmanFrame:onHusbandriesPicked: id=%s unchanged target set; no-op", tostring(id))
        return
    end

    self:ensurePending(id).targetHusbandries = uniqueIds
    Log:debug("RLMenuHerdsmanFrame:onHusbandriesPicked: id=%s targetHusbandries stashed (%d target(s))",
        tostring(id), #uniqueIds)
    -- Drop a move destination the new source set just turned into a source.
    local afterPick = RLHerdsmanRuleEditModel.overlayRule(stored, self.pendingChanges[id])
    self:revalidatePendingDestination(id, afterPick, uniqueIds)
    -- The pick cannot empty the targets, but it CAN absorb the destination as a source.
    self:demoteEnableIfInvalidated(id)
    self:refreshRuleDetail(stored)
end

--- Build a uniqueId -> animalType map for the farm's LIVE husbandries. Shares the picker's
--- descriptor source, so a uid absent here is exactly an unresolvable target.
--- @param farmId number|nil
--- @return table typeByUid map uniqueId(string) -> animalType index
function RLMenuHerdsmanFrame:buildHusbandryTypeByUid(farmId)
    local typeByUid = {}
    for _, d in ipairs(RLAnimalQuery.listHusbandryDescriptorsForFarm(farmId)) do
        if d.animalType ~= nil then typeByUid[d.uniqueId] = d.animalType end
    end
    return typeByUid
end

--- Build a uniqueId -> type-spec map for the farm's LIVE move destinations. A husbandry maps
--- to its scalar animalType, an EPP butcher to its type-index SET, so an EPP destination is
--- gated set-aware rather than treated as unresolvable and preserved forever.
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

--- True when dewar `semenUid` is still in the farm's pool for `filterAnimalType`. A nil
--- filterAnimalType has no typed pool, so any real dewar is out of pool.
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

--- Cross-type revalidation after a filter rebind or an op change: drop type-incompatible
--- RESOLVABLE targets, preserving unresolvable ones, and reset a non-"any" semen only when
--- its dewar left the new pool, so a widening edit keeps a still-valid dewar.
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

    -- ai only: a dewar that left the new animalType pool snaps to "any".
    local semen = merged.params and merged.params.semen
    if merged.operation == "ai" and type(semen) == "string" and semen ~= RLHerdsmanRulePresenter.SEMEN_ANY then
        if not self:isSemenInPool(semen, filterAnimalType, farmId) then
            self:ensurePendingParams(id).params.semen = RLHerdsmanRulePresenter.SEMEN_ANY
            Log:debug("RLMenuHerdsmanFrame:revalidatePendingTargetsAndSemen: id=%s semen %s left the new pool; reset to any",
                tostring(id), tostring(semen))
        end
    end
end

--- The destination twin of revalidatePendingTargetsAndSemen: drop a now-type-incompatible
--- RESOLVABLE destination, or one that became a source, preserving an unresolvable one.
--- @param id any rule id
--- @param merged table the current overlay-merged record (filter/targets already applied)
--- @param sourceUids table|nil the rule's source target uniqueIds AFTER the edit
function RLMenuHerdsmanFrame:revalidatePendingDestination(id, merged, sourceUids)
    if merged.operation ~= "move" then return end
    local dest = merged.params and merged.params.destinationHusbandry or nil
    if dest == nil then return end
    local farmId = RLAnimalInfoService.getCurrentFarmId()
    local typeByUid = self:buildDestinationTypeByUid(farmId)
    -- 4th arg, NOT 5th: revalidateDestination carries no `operation`, so the type map sits
    -- one slot left of its position in revalidateTargets.
    local animalTypeIndexByName = RLMenuHerdsmanFrame.buildAnimalTypeIndexMap()
    local filterAnimalType = self:resolveFilterAnimalType(merged.filterId)
    local kept = RLHerdsmanRulePresenter.revalidateDestination(dest, typeByUid, filterAnimalType, animalTypeIndexByName, sourceUids)
    if kept ~= dest then
        self:ensurePendingParams(id).params.destinationHusbandry = kept
        Log:debug("RLMenuHerdsmanFrame:revalidatePendingDestination: id=%s dest %s -> %s (revalidated)",
            tostring(id), tostring(dest), tostring(kept))
    end
end

--- Demote an ENABLED rule the edit just invalidated, so it survives as a disabled draft
--- rather than being thrown away whole at flush. A WRITE of `false`, never `nil`:
--- `overlayRule` only overrides on a non-nil value, so `nil` would demote nothing. Call it
--- AFTER the site's revalidations and BEFORE its first render.
--- @param id any rule id
--- @return boolean demoted true when the enable was written false
function RLMenuHerdsmanFrame:demoteEnableIfInvalidated(id)
    local stored = self:getStoredRuleById(id)
    if stored == nil then return false end

    local merged = RLHerdsmanRuleEditModel.overlayRule(stored, self.pendingChanges[id])
    local axes = RLHerdsmanRulePresenter.enableDemotionAxes(
        RLHerdsmanRulePresenter.validateFlush(merged))
    if axes == nil then return false end

    self:ensurePending(id).enabled = false
    -- Name the AXES: "my task switched itself off" is diagnosed off this line, and the axis
    -- list is what says which field the player has to repair.
    Log:debug("RLMenuHerdsmanFrame:demoteEnableIfInvalidated: id=%s demoted enable (axes=%s)",
        tostring(id), table.concat(axes, ","))
    return true
end

-- =============================================================================
-- DESTINATION PICKER (move only; in-row button -> single-select dialog -> stash dest)
-- =============================================================================

--- Destination row button click (move only): open the single-select picker, scoped to the
--- rule's filter animalType and excluding its own sources. Opens even on an empty candidate
--- set, because empty-text with OK disabled is feedback where a dead click is not.
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

    -- Destinations are husbandries PLUS owner-farm EPP butchers; a husbandry-only source
    -- would never offer a butcher.
    local descriptors = RLAnimalQuery.listMoveDestinationDescriptorsForFarm(farmId)
    -- 3rd arg, NOT 4th: selectDestinationHusbandries carries no `operation`, so the type map
    -- sits one slot left of its position in selectTargetableHusbandries.
    local animalTypeIndexByName = RLMenuHerdsmanFrame.buildAnimalTypeIndexMap()
    local filterAnimalType = self:resolveFilterAnimalType(merged.filterId)
    local candidates = RLHerdsmanRulePresenter.selectDestinationHusbandries(
        descriptors, filterAnimalType, animalTypeIndexByName, merged.targetHusbandries or {})

    -- A stored destination the gate dropped is no longer in the list; flag it so the picker
    -- says "current unavailable" rather than preselecting row 1.
    local currentDest = merged.params and merged.params.destinationHusbandry or nil
    local currentUnavailable = false
    if currentDest ~= nil then
        currentUnavailable = true
        for _, c in ipairs(candidates) do
            if c.uniqueId == currentDest then currentUnavailable = false; break end
        end
    end

    -- Capture at OPEN: the pick stashes against THIS id even if the selection moves.
    self.destinationPickTargetId = id

    Log:debug("RLMenuHerdsmanFrame:onClickRuleDestination: id=%s filterType=%s farmId=%s -> %d candidate(s), currentDest=%s currentUnavailable=%s",
        tostring(id), tostring(filterAnimalType), tostring(farmId), #candidates, tostring(currentDest), tostring(currentUnavailable))

    RLHerdsmanDestinationPickerDialog.show(self.onDestinationPicked, self, candidates, currentDest, currentUnavailable)
end

--- Destination picker result: nil cancels, and a re-pick of the current destination with
--- nothing else pending is a no-op rather than a redundant flush.
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

--- Lazily get/create the pending overlay, with pending.params a COMPLETE copy of the merged
--- params, so a partial edit never drops nested budget siblings before the whole-object update.
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
    -- Clearing the name marks the row required. The input holds focus while the player clears
    -- it, so the write has to happen here or the marker never appears at all.
    self:refreshValueRowTooltip("name", typed)
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
    -- Live tooltip update; a full re-render would stomp the caret mid-type.
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
    -- Live tooltip update; a full re-render would stomp the caret mid-type.
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
    -- Re-render so the tooltip follows; the silent setState push does not re-fire this.
    self:refreshRuleDetail(self:getStoredRuleById(id))
end

--- semen MultiTextOption: state -> the per-render semenValues[state] (any | dewar uid).
function RLMenuHerdsmanFrame:onRuleSemenChanged(state, _widget)
    local id = self.selectedRuleId
    if id == nil then return end
    self:ensurePendingParams(id).params.semen = self.semenValues[state]
    Log:debug("RLMenuHerdsmanFrame:onRuleSemenChanged: id=%s semen=%s", tostring(id), tostring(self.semenValues[state]))
    -- Re-render so the semen tooltip follows the new value.
    self:refreshRuleDetail(self:getStoredRuleById(id))
end

--- operation MultiTextOption: reshape params, clear a now-forbidden filter, re-section.
function RLMenuHerdsmanFrame:onRuleOperationChanged(state, _widget)
    local id = self.selectedRuleId
    if id == nil then return end
    local newOp = RLHerdsmanRulePresenter.OPERATION_ORDER[state]
    if newOp == nil then return end
    self:applyOperationChange(id, newOp)
end

--- Apply an operation change: stash it, reshape the params, and clear a filter the new
--- operation forbids. The clear MUST precede revalidatePendingTargetsAndSemen, which reads
--- the merged record: reverse the two and a switch revalidates against the OLD filter's type.
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

    local filter = resolveFilterById(merged.filterId)
    local clearReason = RLHerdsmanRulePresenter.filterClearReasonForOperation(
        newOp, filter, RLMenuHerdsmanFrame.buildAnimalTypeIndexMap())
    if clearReason ~= nil then
        pending.filterId = RLHerdsmanRuleEditModel.CLEAR
        -- Name the rejected VALUES: "my filter disappeared" is diagnosed off this line, and a
        -- player reporting it will not be running at TRACE.
        Log:debug("RLMenuHerdsmanFrame:applyOperationChange: id=%s -> %s; filterId cleared (reason=%s usage=%s animalType=%s)",
            tostring(id), tostring(newOp), tostring(clearReason),
            tostring(type(filter) == "table" and filter.usage or nil),
            tostring(type(filter) == "table" and filter.animalType or nil))
    end

    -- Re-read merged so the op and the filter-clear are both reflected.
    local newMerged = RLHerdsmanRuleEditModel.overlayRule(stored, self.pendingChanges[id])
    self:revalidatePendingTargetsAndSemen(id, newMerged)
    -- BEFORE refreshList, not just before refreshRuleDetail: the demote must precede EVERY
    -- render here, or the list is built from an overlay the pane is about to contradict.
    self:demoteEnableIfInvalidated(id)

    Log:debug("RLMenuHerdsmanFrame:applyOperationChange: id=%s newOp=%s (re-sectioning)", tostring(id), newOp)
    self:refreshList(id)
    self:refreshRuleDetail(stored)
end

-- =============================================================================
-- FLUSH (pending overlay -> g_rlHerdsmanRuleService:update)
-- =============================================================================

--- Flush one id's overlay through the service, gated by validateFlush. A disabled or
--- incomplete rule persists as a draft; a validation skip or a service reject clears the
--- overlay and reverts the display to the stored record.
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
    -- Demote backstop: when the ONLY thing blocking the flush is an enable-gated axis, write
    -- the enable off and re-evaluate rather than discard the overlay, so the rule persists as
    -- a disabled draft carrying every edit. The edit sites demote as they happen, so the
    -- player sees the toggle move; this catches the frame-close flush and a rule already
    -- persisted enabled-but-incomplete, which would otherwise stay blocked forever.
    local demotionAxes = RLHerdsmanRulePresenter.enableDemotionAxes(g)
    if demotionAxes ~= nil then
        pending.enabled = false
        merged = RLHerdsmanRuleEditModel.overlayRule(stored, pending)
        g = RLHerdsmanRulePresenter.validateFlush(merged)
        Log:debug("RLMenuHerdsmanFrame:flushPendingForId: id=%s demoted enable (axes=%s); re-evaluating remaining edits (ok=%s)",
            tostring(id), table.concat(demotionAxes, ","), tostring(g.ok))
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

--- Drain every pending overlay. Snapshots the id set first, so clearing entries
--- mid-iteration is safe.
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
--- the detail seam by hand.
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
--- validation in the rule events; this only gates button visibility and the early abort.
--- @return boolean
function RLMenuHerdsmanFrame:hasCreatePermission()
    if g_currentMission == nil or g_currentMission.getHasPlayerPermission == nil then
        return false
    end
    return g_currentMission:getHasPlayerPermission("tradeAnimals") == true
end

--- Rebuild the footer from the selection and permission. New is never gated on selection, so
--- the empty state stays escapable; Duplicate and Delete additionally need one.
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

--- The live rule names for the name-collision helpers, with each rule's overlay applied so an
--- in-flight rename on another row still counts.
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

--- Footer New handler, gated on permission and farm only, never selection. Autoflushes the
--- current pending first, so a dirty edit is not lost when New steals the selection.
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

--- Footer Duplicate handler. Autoflushes first, then clones the STORED record, NOT the
--- overlay-merged view, which can be floor-invalid under the draft model.
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

--- Footer Delete handler: opens a YesNoDialog naming the rule. The dialog-visible check also
--- suppresses Delete while a picker is open.
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

    -- YesNoDialog passes (target, yesValue, callbackArgs), and the colon-bound `self` absorbs
    -- the target, so the callback receives (yes, id).
    YesNoDialog.show(
        self.onDeleteConfirmed,
        self,
        confirmText,
        g_i18n:getText("ui_attention"),
        nil, nil, nil, nil, nil,
        stored.id
    )
end

--- Delete confirmation callback. A false return preserves the selection and the pending
--- edits, so a stale id or a race resolves on the next refresh rather than losing work.
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

--- Re-read the rule registry for the current farm, KEEPING the local pending overlay. Drops
--- pending whose id has gone and clears the selection when the selected id was pruned, so a
--- stale focused input cannot re-stash a resurrected orphan.
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

    -- Orphan prune: drop any overlay whose id a remote delete has removed.
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
