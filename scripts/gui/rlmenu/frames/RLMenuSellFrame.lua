--[[
    RLMenuSellFrame.lua
    RL Tabbed Menu - Sell tab.

    Left-sidebar husbandry picker with dot indicators, multi-section
    SmoothList of animal cards with checkboxes for multi-select, and
    right-hand detail pane (pen column + animal column via RLDetailPaneHelper).

    Shared selection, canBeSold filter, cart display in the pen column;
    sell logic via RLAnimalSellService.
]]

RLMenuSellFrame = {}
local RLMenuSellFrame_mt = Class(RLMenuSellFrame, TabbedMenuFrameElement)

local Log = RmLogging.getLogger("RLRM")

local modDirectory = g_currentModDirectory


--- Construct a new RLMenuSellFrame instance.
--- @return table self
function RLMenuSellFrame.new()
    local self = RLMenuSellFrame:superClass().new(nil, RLMenuSellFrame_mt)
    self.name = "RLMenuSellFrame"

    self.sortedHusbandries = {}
    self.selectedHusbandry = nil
    self.items             = {}
    self.filters           = {}
    self.farmId            = nil

    self.sectionOrder      = {}
    self.itemsBySection    = {}
    self.titlesBySection   = {}

    self.selectedIdentity  = nil   -- { farmId, uniqueId, country }
    self.selectedAnimals   = {}    -- keyed by RLAnimalUtil.toKey identity string

    self.isFrameOpen = false
    self.hasCustomMenuButtons = true

    -- In-flight UI lock for a dispatched sale (mirrors RLMenuTransferFrame.movePending):
    -- set before dispatch, released on the service's false return or on completion, and
    -- reset on frame open so a stranded lock self-heals.
    self.sellPending = false

    self.activeAnimalTypeIndex = nil

    -- Saved-filter session state.
    self.activeFilterId = nil
    self.activeFilter   = nil

    -- Back button (always present, must be explicit with hasCustomMenuButtons)
    self.backButtonInfo = { inputAction = InputAction.MENU_BACK }

    -- Action bar button definitions
    self.filterButtonInfo = {
        inputAction = InputAction.MENU_CANCEL,
        text = g_i18n:getText("rl_menu_info_filter_button"),
        callback = function() self:onClickFilter() end,
    }
    self.sellButtonInfo = {
        inputAction = InputAction.MENU_EXTRA_1,
        text = g_i18n:getText("button_sell"),
        callback = function() self:onClickSell() end,
    }
    self.sellSelectedButtonInfo = {
        inputAction = InputAction.MENU_EXTRA_2,
        text = g_i18n:getText("rl_ui_sellSelected"),
        callback = function() self:onClickSellSelected() end,
    }
    self.selectButtonInfo = {
        inputAction = InputAction.RL_SELECT,
        text = g_i18n:getText("button_select"),
        callback = function() self:onClickSelect() end,
    }
    self.selectAllButtonInfo = {
        inputAction = InputAction.MENU_ACTIVATE,
        text = g_i18n:getText("rl_ui_selectAll"),
        callback = function() self:onClickSelectAll() end,
    }
    self.cycleFilterButtonInfo = {
        inputAction = InputAction.RL_CYCLE_FILTER,
        text = g_i18n:getText("rl_menu_cycle_filter_button"),
        callback = function() self:onCycleFilter() end,
    }
    self.menuButtonInfo = { self.backButtonInfo }

    return self
end


--- Load the sell frame XML and register it with g_gui.
function RLMenuSellFrame.setupGui()
    local frame = RLMenuSellFrame.new()
    g_gui:loadGui(
        Utils.getFilename("gui/rlmenu/sellFrame.xml", modDirectory),
        "RLMenuSellFrame",
        frame,
        true
    )
    Log:debug("RLMenuSellFrame.setupGui: registered")
end


--- Bind the SmoothList datasource/delegate. Fires on both the initial load
--- instance and the FrameReference clone; tree mutation lives in initialize().
function RLMenuSellFrame:onGuiSetupFinished()
    RLMenuSellFrame:superClass().onGuiSetupFinished(self)

    if self.animalList ~= nil then
        self.animalList:setDataSource(self)
        self.animalList:setDelegate(self)
    else
        Log:warning("RLMenuSellFrame:onGuiSetupFinished: animalList element missing from XML")
    end
end


--- One-time per-clone setup. Unlinks the dot template from the element tree
--- so it can be cloned at runtime. Called by RLMenu:setupMenuPages.
function RLMenuSellFrame:initialize()
    if self.subCategoryDotTemplate ~= nil then
        self.subCategoryDotTemplate:unlinkElement()
        FocusManager:removeElement(self.subCategoryDotTemplate)
    else
        Log:warning("RLMenuSellFrame:initialize: subCategoryDotTemplate missing")
    end
end


-- =============================================================================
-- Lifecycle
-- =============================================================================

--- Called by the Paging element when this tab becomes active.
function RLMenuSellFrame:onFrameOpen()
    RLMenuSellFrame:superClass().onFrameOpen(self)
    self.isFrameOpen = true
    -- Self-heal a lock stranded by a sale whose completion never fired (frame closed mid-flight).
    self.sellPending = false
    Log:debug("RLMenuSellFrame:onFrameOpen")

    -- Import shared selection from sibling frame (Info <-> Move <-> Sell)
    if g_rlMenu ~= nil and g_rlMenu.sharedSelection ~= nil then
        local shared = g_rlMenu.sharedSelection
        if shared.animalIdentity ~= nil then
            self.selectedIdentity = shared.animalIdentity
        end
        -- Saved-filter sharing across Info/Move/Sell (tab-switch
        -- preservation fix). BuyFrame is isolated and never touches this.
        if shared.activeFilterId ~= nil then
            self.activeFilterId = shared.activeFilterId
            self.activeFilter = g_rlFilterService ~= nil
                and g_rlFilterService:getById(shared.activeFilterId) or nil
            Log:debug("RLMenuSellFrame:onFrameOpen: imported shared activeFilterId=%s",
                tostring(shared.activeFilterId))
        end
        Log:debug("RLMenuSellFrame:onFrameOpen: imported shared selection (husbandry=%s animal=%s/%s)",
            tostring(shared.husbandry ~= nil and shared.husbandry:getName() or "nil"),
            tostring(shared.animalIdentity and shared.animalIdentity.farmId),
            tostring(shared.animalIdentity and shared.animalIdentity.uniqueId))
    end

    -- Reset SmoothList's selection sentinels to 0 (the "no selection"
    -- sentinel value) so the chained captureCurrentSelection during
    -- refreshHusbandries -> reloadAnimalList short-circuits via its
    -- sectionOrder guard instead of overwriting the just-imported
    -- selectedIdentity. Must be 0, not nil - SmoothList expects numeric
    -- indices and crashes on nil.
    if self.animalList ~= nil then
        self.animalList.selectedSectionIndex = 0
        self.animalList.selectedIndex = 0
    end

    self:refreshHusbandries()

    -- Subscribe to MONEY_CHANGED so the header balance refreshes when a
    -- post-sell balance update arrives asynchronously (MP) or when any
    -- other code path credits/debits the farm while this frame is open.
    -- SP is unaffected because the change is synchronous there.
    g_messageCenter:subscribe(MessageType.MONEY_CHANGED, self.onMoneyChanged, self)

    -- Explicit focus links for keyboard navigation. Required because multiple
    -- frames share the same sidebar + SmoothList structure, and FocusManager
    -- auto-layout resolves to elements in other frames when element
    -- positions/IDs overlap.
    if self.subCategorySelector ~= nil and self.animalList ~= nil then
        FocusManager:linkElements(self.subCategorySelector, FocusManager.BOTTOM, self.animalList)
        FocusManager:linkElements(self.animalList, FocusManager.TOP, self.subCategorySelector)
    end
    if self.animalList ~= nil then
        FocusManager:setFocus(self.animalList)
    end

    -- Revalidate active saved filter against current scope + render chip.
    self:revalidateActiveFilter()
    self:updateFilterChip()
end


--- Called by the Paging element when this tab is deactivated.
function RLMenuSellFrame:onFrameClose()
    -- Export selection to shared state for sibling frames
    self:captureCurrentSelection()
    if g_rlMenu ~= nil then
        -- In trailer-dealer context the trailer is overloaded into selectedHusbandry;
        -- never export it into sharedSelection.husbandry (a sibling Buy/Info/Move frame
        -- would resolve it as a husbandry via getAnimalTypeIndex / spec_*). Export ONLY a
        -- real husbandry: a trailer lacks spec_husbandryAnimals, so this fails CLOSED even
        -- when getTrailerDealerContext no longer resolves (trailer swapped/deleted before
        -- close) - a live-context probe alone would leak a stale trailer.
        local sharedHusbandry = self.selectedHusbandry
        if sharedHusbandry ~= nil and sharedHusbandry.spec_husbandryAnimals == nil then
            sharedHusbandry = nil
        end
        g_rlMenu.sharedSelection = {
            husbandry      = sharedHusbandry,
            animalIdentity = self.selectedIdentity,
            activeFilterId = self.activeFilterId,
        }
        Log:debug("RLMenuSellFrame:onFrameClose: exported shared selection (husbandry=%s animal=%s/%s filter=%s)",
            tostring(sharedHusbandry ~= nil and sharedHusbandry:getName() or "nil"),
            tostring(self.selectedIdentity and self.selectedIdentity.farmId),
            tostring(self.selectedIdentity and self.selectedIdentity.uniqueId),
            tostring(self.activeFilterId))
    end

    -- Quick filter is a per-frame session affordance;
    -- clear it on tab close so a sibling tab open starts clean. Log only
    -- when something was actually cleared to keep tab-switch traffic quiet.
    if next(self.filters) ~= nil then
        local count = 0
        for _ in pairs(self.filters) do count = count + 1 end
        Log:debug("RLMenuSellFrame:onFrameClose: cleared %d Quick filter condition(s)", count)
        self.filters = {}
    end

    g_messageCenter:unsubscribe(MessageType.MONEY_CHANGED, self)
    RLMenuSellFrame:superClass().onFrameClose(self)
    self.isFrameOpen = false
end


--- MessageType.MONEY_CHANGED handler. Fires on both server and client
--- contexts: on clients, the message is published locally after the farm
--- balance is updated from a server stream, so subscribing lets the Sell
--- frame refresh its header balance in MP without polling. No farmId
--- gating here because updateMoneyDisplay reads the current player's farm
--- internally.
function RLMenuSellFrame:onMoneyChanged()
    if not self.isFrameOpen then return end
    Log:trace("RLMenuSellFrame:onMoneyChanged: refreshing money display")
    RLDetailPaneHelper.updateMoneyDisplay(self)
end


-- =============================================================================
-- Husbandry selector
-- =============================================================================

--- Repopulate the husbandry selector + dot indicators for the player's farm.
function RLMenuSellFrame:refreshHusbandries()
    -- Trailer-dealer context: the single source is the held trailer, labelled with
    -- the capacity suffix. Collapse the sidebar to one entry, hide the dot
    -- box, and let onHusbandryChanged(1) assign selectedHusbandry = trailer. Do NOT
    -- consult g_rlMenu.sharedSelection (it keys husbandries by placeable; the trailer
    -- is not in it).
    local trailer = self:getTrailerDealerContext()
    if trailer ~= nil then
        self.farmId = RLAnimalInfoService.getCurrentFarmId()
        self.sortedHusbandries = { trailer }

        if self.subCategoryDotBox ~= nil then
            for i, dot in pairs(self.subCategoryDotBox.elements) do
                dot:delete()
                self.subCategoryDotBox.elements[i] = nil
            end
            self.subCategoryDotBox:setVisible(false)
        end
        if self.noHusbandriesText ~= nil then self.noHusbandriesText:setVisible(false) end

        local d = RLTrailerEndpointService.getDisplayData(trailer)
        local label = RLTransferAdapter.formatCapacityLabel(d.name, d.used, d.total)
        Log:debug("RLMenuSellFrame:refreshHusbandries: trailer-dealer source '%s' (%d/%d)",
            d.name, d.used, d.total)

        if self.subCategorySelector ~= nil then
            self.subCategorySelector:setTexts({ label })
            self.subCategorySelector:setState(1, true)
        else
            self:onHusbandryChanged(1)
        end
        return
    end

    local farmId = RLAnimalInfoService.getCurrentFarmId()
    self.farmId = farmId

    self.sortedHusbandries = RLAnimalQuery.listHusbandriesForFarm(farmId)
    Log:debug("RLMenuSellFrame:refreshHusbandries: farmId=%s husbandries=%d",
        tostring(farmId), #self.sortedHusbandries)

    -- Capture-and-consume the one-shot MODE_FULL husbandry anchor into a local and
    -- clear the shared field NOW - before the empty-list guard below - so every path
    -- (empty, selector-nil, populated) consumes it exactly once and none leaks it to
    -- a later open. The trailer-dealer early-return above never reaches here, and the
    -- anchor is already nil in trailer mode, so that branch stays untouched.
    local anchorHusbandry = nil
    if g_rlMenu ~= nil then
        anchorHusbandry = g_rlMenu.anchoredHusbandry
        g_rlMenu.anchoredHusbandry = nil
    end

    if self.subCategoryDotBox ~= nil then
        for i, dot in pairs(self.subCategoryDotBox.elements) do
            dot:delete()
            self.subCategoryDotBox.elements[i] = nil
        end
    end

    if #self.sortedHusbandries == 0 then
        Log:trace("RLMenuSellFrame:refreshHusbandries: no husbandries, showing empty state")
        if self.noHusbandriesText ~= nil then self.noHusbandriesText:setVisible(true) end
        if self.subCategoryDotBox ~= nil then self.subCategoryDotBox:setVisible(false) end
        if self.subCategorySelector ~= nil then self.subCategorySelector:setTexts({}) end
        self.selectedHusbandry = nil
        self.items = {}
        self.selectedAnimals = {}
        -- Clear section state BEFORE reloadData so SmoothList's section-count
        -- callback does not read stale keys from a prior populated husbandry
        -- (mirrors the equivalent reset in RLMenuBuyFrame:refreshTypes).
        self.sectionOrder    = {}
        self.itemsBySection  = {}
        self.titlesBySection = {}
        if self.animalList ~= nil then self.animalList:reloadData() end
        self:updateEmptyState()
        self:updateButtonVisibility()
        self:updateCartDisplay()
        RLDetailPaneHelper.updateMoneyDisplay(self)
        RLDetailPaneHelper.clearDetail(self)
        return
    end

    if self.noHusbandriesText ~= nil then self.noHusbandriesText:setVisible(false) end

    local names = {}
    for index, husbandry in ipairs(self.sortedHusbandries) do
        names[index] = RLAnimalQuery.formatHusbandryLabel(husbandry, index)

        if self.subCategoryDotTemplate ~= nil and self.subCategoryDotBox ~= nil then
            local dot = self.subCategoryDotTemplate:clone(self.subCategoryDotBox)
            local dotIndex = index
            function dot.getIsSelected()
                return self.subCategorySelector ~= nil
                    and self.subCategorySelector:getState() == dotIndex
            end
        end
    end

    if self.subCategoryDotBox ~= nil then
        self.subCategoryDotBox:invalidateLayout()
        self.subCategoryDotBox:setVisible(1 < #names)
    end

    -- Resolve initial husbandry: prefer the one-shot anchor, then the persistent
    -- shared selection, then the first pen (all matched by placeable identity).
    local sharedHusbandry = nil
    if g_rlMenu ~= nil and g_rlMenu.sharedSelection ~= nil then
        sharedHusbandry = g_rlMenu.sharedSelection.husbandry
    end
    local initialState, anchorMatched =
        RLMenuHusbandryAnchor.resolveIndex(self.sortedHusbandries, anchorHusbandry, sharedHusbandry)
    if anchorHusbandry ~= nil then
        if anchorMatched then
            Log:debug("RLMenuSellFrame:refreshHusbandries: anchor resolved to state=%d", initialState)
        else
            Log:debug("RLMenuSellFrame:refreshHusbandries: anchor not in current farm list, unanchored (state=%d)", initialState)
        end
    else
        Log:trace("RLMenuSellFrame:refreshHusbandries: husbandry resolved to state=%d (no anchor)", initialState)
    end

    if self.subCategorySelector ~= nil then
        self.subCategorySelector:setTexts(names)
        self.subCategorySelector:setState(initialState, true)
    else
        self:onHusbandryChanged(initialState)
    end
end


--- MultiTextOption onClick callback. Clears filters + selections on animal-type change.
--- @param state number 1-based husbandry index
function RLMenuSellFrame:onHusbandryChanged(state)
    if state == nil or state < 1 or state > #self.sortedHusbandries then return end

    self.selectedHusbandry = self.sortedHusbandries[state]
    local newTypeIndex
    if self.selectedHusbandry ~= nil and self.selectedHusbandry.getAnimalTypeIndex ~= nil then
        newTypeIndex = self.selectedHusbandry:getAnimalTypeIndex()
    end

    if self.activeAnimalTypeIndex ~= nil
        and newTypeIndex ~= nil
        and newTypeIndex ~= self.activeAnimalTypeIndex
        and next(self.filters) ~= nil then
        Log:debug("RLMenuSellFrame:onHusbandryChanged: animal type changed, clearing filters")
        self.filters = {}
    end
    self.activeAnimalTypeIndex = newTypeIndex

    -- Saved-filter scope revalidation (mirrors ad-hoc clear above).
    self:revalidateActiveFilter()
    self:updateFilterChip()

    -- Clear selections on husbandry switch (new animal set)
    self.selectedAnimals = {}

    Log:debug("RLMenuSellFrame:onHusbandryChanged: state=%d husbandry='%s'",
        state,
        (self.selectedHusbandry ~= nil and self.selectedHusbandry.getName ~= nil
            and self.selectedHusbandry:getName()) or "?")

    self:reloadAnimalList()
    self:updatePenHeader()
    self:updateCartDisplay()
    RLDetailPaneHelper.updateMoneyDisplay(self)
end


--- SmoothList delegate: fired when the user picks a different row.
--- @param list table
--- @param section number
--- @param index number
function RLMenuSellFrame:onListSelectionChanged(list, section, index)
    if list ~= self.animalList then return end
    if section == nil or index == nil then return end
    Log:trace("RLMenuSellFrame:onListSelectionChanged: section=%d index=%d", section, index)

    local key = self.sectionOrder[section]
    if key == nil then
        RLDetailPaneHelper.clearAnimalDetail(self)
        return
    end
    local items = self.itemsBySection[key]
    if items == nil then
        RLDetailPaneHelper.clearAnimalDetail(self)
        return
    end
    local item = items[index]
    if item == nil or item.cluster == nil then
        RLDetailPaneHelper.clearAnimalDetail(self)
        return
    end

    -- Trailer-dealer context: the animal detail needs no husbandry; pass nil so a
    -- trailer is never resolved as a husbandry (the helper tolerates nil).
    local detailHusbandry = self.selectedHusbandry
    if self:getTrailerDealerContext() ~= nil then detailHusbandry = nil end
    RLDetailPaneHelper.updateAnimalDisplay(self, item.cluster, detailHusbandry)
    self:updateButtonVisibility()
end


-- =============================================================================
-- Animal list
-- =============================================================================

--- Build the dialog source list for the Quick filter dialog.
--- Mirrors reloadAnimalList's universe construction MINUS the Quick filter:
--- query without Quick filter -> strip unsellable -> apply saved filter.
--- Sellability stripping is load-bearing: otherwise the slider range would
--- widen to include animals the player can never actually sell.
--- Parity with reloadAnimalList is enforceable by eye (the two are stacked).
---@return table base     full unfiltered husbandry universe
---@return table sellable base after dropping cluster:getCanBeSold()==false
---@return table narrowed sellable after saved-filter layer
function RLMenuSellFrame:buildDialogSourceList()
    local base
    if self:getTrailerDealerContext() ~= nil then
        base = self:buildTrailerSellItems()
    elseif self.selectedHusbandry == nil then
        return {}, {}, {}
    else
        base = RLAnimalQuery.listAnimalsForHusbandry(self.selectedHusbandry, nil)
    end
    local sellable = {}
    for _, item in ipairs(base) do
        if item.cluster ~= nil and item.cluster:getCanBeSold() then
            table.insert(sellable, item)
        end
    end
    local narrowed = RLFilterCycleHelper.applyFilter(sellable, self.activeFilter)
    return base, sellable, narrowed
end


--- Requery the current husbandry, filter unsellable animals, group into
--- sections, refresh the SmoothList, restore selection by identity.
function RLMenuSellFrame:reloadAnimalList()
    Log:trace("RLMenuSellFrame:reloadAnimalList: begin")
    self:captureCurrentSelection()

    if self:getTrailerDealerContext() ~= nil then
        -- Trailer source: wrap the trailer's live contents, then reproduce the
        -- sort + Quick (ad-hoc) filter the husbandry path applies INSIDE
        -- listAnimalsForHusbandry (RLAnimalQuery.lua), so the Quick filter still
        -- narrows the trailer list and section grouping order matches.
        self.items = self:buildTrailerSellItems()
        if RLAnimalDisplayHelper ~= nil and RLAnimalDisplayHelper.sortAnimals ~= nil then
            table.sort(self.items, RLAnimalDisplayHelper.sortAnimals)
        end
        if next(self.filters) ~= nil
            and AnimalFilterDialog ~= nil and AnimalFilterDialog.applyFilters ~= nil then
            self.items = AnimalFilterDialog.applyFilters(self.items, self.filters, false)
        end
    elseif self.selectedHusbandry == nil then
        self.items = {}
    else
        self.items = RLAnimalQuery.listAnimalsForHusbandry(self.selectedHusbandry, self.filters)
    end

    -- Filter out unsellable animals (sell frame only)
    local sellableItems = {}
    for _, item in ipairs(self.items) do
        if item.cluster ~= nil and item.cluster:getCanBeSold() then
            table.insert(sellableItems, item)
        end
    end
    local filteredCount = #self.items - #sellableItems
    if filteredCount > 0 then
        Log:debug("RLMenuSellFrame:reloadAnimalList: filtered %d unsellable animals", filteredCount)
    end
    self.items = sellableItems

    -- Saved-filter narrowing (AND with ad-hoc + sellable filter above).
    if self.activeFilter ~= nil then
        self.items = RLFilterCycleHelper.applyFilter(self.items, self.activeFilter)
    end

    self.sectionOrder, self.itemsBySection, self.titlesBySection =
        RLAnimalQuery.buildSections(self.items)

    if self.animalList ~= nil then
        self.animalList:reloadData()
    end

    self:restoreSelection()
    self:updateEmptyState()
    self:updateButtonVisibility()
    self:updateCartDisplay()
end


--- Capture the currently highlighted animal's identity.
function RLMenuSellFrame:captureCurrentSelection()
    if self.animalList == nil then return end
    local section = self.animalList.selectedSectionIndex
    local index   = self.animalList.selectedIndex
    if section == nil or index == nil then return end

    local key = self.sectionOrder[section]
    if key == nil then return end
    local list = self.itemsBySection[key]
    if list == nil or index < 1 or index > #list then return end

    local item = list[index]
    if item == nil or item.cluster == nil then return end

    local cluster = item.cluster
    local country = ""
    if cluster.birthday ~= nil then country = cluster.birthday.country or "" end
    self.selectedIdentity = {
        farmId   = cluster.farmId or 0,
        uniqueId = cluster.uniqueId or 0,
        country  = country,
    }
end


--- Re-highlight the previously selected animal. Falls back to (1, 1).
function RLMenuSellFrame:restoreSelection()
    if self.animalList == nil then return end

    if #self.sectionOrder == 0 then
        self.selectedIdentity = nil
        RLDetailPaneHelper.clearAnimalDetail(self)
        return
    end

    local section, index
    if self.selectedIdentity ~= nil then
        section, index = RLAnimalQuery.findSectionedItemByIdentity(
            self.sectionOrder,
            self.itemsBySection,
            self.selectedIdentity.farmId,
            self.selectedIdentity.uniqueId,
            self.selectedIdentity.country
        )
    end

    if section == nil or index == nil then
        section, index = 1, 1
    end

    self.animalList:setSelectedItem(section, index, false, true)

    local key = self.sectionOrder[section]
    if key == nil then return end
    local items = self.itemsBySection[key]
    if items == nil then return end
    local item = items[index]
    if item ~= nil and item.cluster ~= nil then
        -- Trailer-dealer context passes nil husbandry (same as onListSelectionChanged).
        local detailHusbandry = self.selectedHusbandry
        if self:getTrailerDealerContext() ~= nil then detailHusbandry = nil end
        RLDetailPaneHelper.updateAnimalDisplay(self, item.cluster, detailHusbandry)
    end
end


-- =============================================================================
-- Empty state / buttons
-- =============================================================================

--- Toggle empty-state text + list chrome based on the current data.
function RLMenuSellFrame:updateEmptyState()
    local hasHusbandries = #self.sortedHusbandries > 0
    local hasItems = #self.items > 0

    if self.noAnimalsText ~= nil then
        self.noAnimalsText:setVisible(hasHusbandries and not hasItems)
    end
end


--- Get the currently focused animal from the list.
--- @return table|nil cluster
function RLMenuSellFrame:getSelectedAnimal()
    if self.animalList == nil then return nil end
    local section = self.animalList.selectedSectionIndex
    local index   = self.animalList.selectedIndex
    if section == nil or index == nil then return nil end

    local key = self.sectionOrder[section]
    if key == nil then return nil end
    local items = self.itemsBySection[key]
    if items == nil then return nil end
    local item = items[index]
    if item == nil then return nil end
    return item.cluster
end


--- Count the number of checked animals.
--- @return number
function RLMenuSellFrame:getSelectedCount()
    local count = 0
    for _, selected in pairs(self.selectedAnimals) do
        if selected then
            count = count + 1
        end
    end
    return count
end


--- Rebuild the footer button info. Back + Filter always; Sell/SellSelected/Select/SelectAll
--- conditional on state.
function RLMenuSellFrame:updateButtonVisibility()
    self.menuButtonInfo = { self.backButtonInfo }

    local hasHusbandries = #self.sortedHusbandries > 0
    local hasItems = #self.items > 0
    local animal = self:getSelectedAnimal()
    local selectedCount = self:getSelectedCount()

    if hasHusbandries then
        table.insert(self.menuButtonInfo, self.filterButtonInfo)
    end

    -- Cycle-filter button: always visible when farm is present.
    if self.farmId ~= nil and self.farmId ~= 0 then
        table.insert(self.menuButtonInfo, self.cycleFilterButtonInfo)
    end

    if hasItems then
        -- Select (toggle focused animal's checkbox)
        table.insert(self.menuButtonInfo, self.selectButtonInfo)

        -- Select All / Deselect All
        self.selectAllButtonInfo.text = g_i18n:getText(
            selectedCount > 0 and "rl_ui_selectNone" or "rl_ui_selectAll")
        table.insert(self.menuButtonInfo, self.selectAllButtonInfo)
    end

    -- Sell Selected (N) - enabled when checked animals exist
    if hasItems then
        local sellSelText = g_i18n:getText("rl_ui_sellSelected")
        if selectedCount > 0 then
            sellSelText = sellSelText .. " (" .. selectedCount .. ")"
        end
        self.sellSelectedButtonInfo.text = sellSelText
        self.sellSelectedButtonInfo.disabled = selectedCount == 0
        table.insert(self.menuButtonInfo, self.sellSelectedButtonInfo)
    end

    -- Sell (single focused animal) - enabled when an animal is focused
    if hasItems then
        self.sellButtonInfo.disabled = animal == nil
        table.insert(self.menuButtonInfo, self.sellButtonInfo)
    end

    Log:trace("RLMenuSellFrame:updateButtonVisibility: %d buttons, selectedCount=%d",
        #self.menuButtonInfo, selectedCount)
    self:setMenuButtonInfoDirty()
end


-- =============================================================================
-- Pen header + cart display
-- =============================================================================

--- Populate the pen header (name, count, icon) directly from husbandry display
--- data. Replaces RLDetailPaneHelper.updatePenDisplay for the sell frame since
--- the conditions/food XML was replaced with cart elements.
function RLMenuSellFrame:updatePenHeader()
    if self.penBox == nil then return end

    -- Trailer-dealer context: the sidebar already carries the trailer name +
    -- capacity, and getHusbandryDisplay is husbandry-typed (a trailer must never
    -- reach it). Hide the pen header without calling getHusbandryDisplay at all.
    if self:getTrailerDealerContext() ~= nil then
        self.penBox:setVisible(false)
        Log:trace("RLMenuSellFrame:updatePenHeader: trailer-dealer context, pen header hidden (getHusbandryDisplay not called)")
        return
    end

    local display
    if self.selectedHusbandry ~= nil then
        display = RLAnimalInfoService.getHusbandryDisplay(self.selectedHusbandry, self.farmId)
    end

    if display == nil then
        self.penBox:setVisible(false)
        Log:trace("RLMenuSellFrame:updatePenHeader: no husbandry, pen hidden")
        return
    end

    self.penBox:setVisible(true)
    if self.penNameText ~= nil then self.penNameText:setText(display.name) end
    if self.penCountText ~= nil then self.penCountText:setText(display.countText) end
    if self.penIcon ~= nil then
        if display.penImageFilename ~= nil then
            self.penIcon:setImageFilename(display.penImageFilename)
            self.penIcon:setVisible(true)
        else
            self.penIcon:setVisible(false)
        end
    end

    Log:trace("RLMenuSellFrame:updatePenHeader: '%s' %s", display.name, display.countText)
end


--- Compute cart totals from checked animals.
--- Fee sign convention: getTranportationFee(1) returns positive; negate before summing.
--- @return number totalPrice Sum of getSellPrice() for checked animals
--- @return number totalFee Sum of getTranportationFee(1) for checked animals (positive)
--- @return number count Number of checked animals
function RLMenuSellFrame:computeCartTotals()
    local totalPrice = 0
    local totalFee = 0
    local count = 0

    for _, sectionKey in ipairs(self.sectionOrder) do
        local items = self.itemsBySection[sectionKey]
        if items ~= nil then
            for _, item in ipairs(items) do
                if item.cluster ~= nil then
                    local cluster = item.cluster
                    local identityKey = RLSelectionKey.build(cluster.farmId, cluster.uniqueId,
                        cluster.birthday and cluster.birthday.country)
                    if identityKey ~= nil and self.selectedAnimals[identityKey] then
                        totalPrice = totalPrice + (cluster:getSellPrice() or 0)
                        totalFee = totalFee + (cluster:getTranportationFee(1) or 0)
                        count = count + 1
                    end
                end
            end
        end
    end

    Log:trace("RLMenuSellFrame:computeCartTotals: count=%d price=%.0f fee=%.0f total=%.0f",
        count, totalPrice, totalFee, totalPrice - totalFee)
    return totalPrice, totalFee, count
end


--- Update the cart display elements with current totals.
function RLMenuSellFrame:updateCartDisplay()
    local totalPrice, totalFee, count = self:computeCartTotals()

    if self.cartCountValue ~= nil then
        self.cartCountValue:setText(tostring(count))
    end
    if self.cartPriceValue ~= nil then
        self.cartPriceValue:setText(g_i18n:formatMoney(totalPrice, 0, true, true))
    end
    if self.cartFeeValue ~= nil then
        self.cartFeeValue:setText(g_i18n:formatMoney(-totalFee, 0, true, true))
    end
    if self.cartTotalValue ~= nil then
        self.cartTotalValue:setText(g_i18n:formatMoney(totalPrice - totalFee, 0, true, true))
    end

    if self.cartLayout ~= nil and self.cartLayout.invalidateLayout ~= nil then
        self.cartLayout:invalidateLayout()
    end

    Log:trace("RLMenuSellFrame:updateCartDisplay: %d selected, price=%s fee=%s total=%s",
        count,
        g_i18n:formatMoney(totalPrice, 0, true, true),
        g_i18n:formatMoney(-totalFee, 0, true, true),
        g_i18n:formatMoney(totalPrice - totalFee, 0, true, true))
end


-- =============================================================================
-- Checkbox / multi-select
-- =============================================================================

--- Toggle the focused animal's checkbox.
function RLMenuSellFrame:onClickSelect()
    if not self.isFrameOpen then
        Log:trace("RLMenuSellFrame:onClickSelect: frame closed, ignoring")
        return
    end
    local animal = self:getSelectedAnimal()
    if animal == nil then
        Log:trace("RLMenuSellFrame:onClickSelect: no animal focused")
        return
    end

    local key = RLSelectionKey.build(animal.farmId, animal.uniqueId,
        animal.birthday and animal.birthday.country)
    if key == nil then
        Log:trace("RLMenuSellFrame:onClickSelect: nil selection key, skipping")
        return
    end
    self.selectedAnimals[key] = not self.selectedAnimals[key]
    Log:trace("RLMenuSellFrame:onClickSelect: key=%s -> %s", key, tostring(self.selectedAnimals[key]))

    -- Reload to re-render checkmarks. Do NOT restoreSelection - SmoothList
    -- preserves focus across reloadData. Calling restoreSelection would
    -- reset the highlight to (1,1) via setSelectedItem.
    if self.animalList ~= nil then
        self.animalList:reloadData()
    end
    self:updateButtonVisibility()
    self:updateCartDisplay()
end


--- Toggle all animals: if any are checked, uncheck all; otherwise check all.
function RLMenuSellFrame:onClickSelectAll()
    if not self.isFrameOpen then
        Log:trace("RLMenuSellFrame:onClickSelectAll: frame closed, ignoring")
        return
    end
    local hasSelection = self:getSelectedCount() > 0

    if hasSelection then
        -- Deselect all
        self.selectedAnimals = {}
        Log:debug("RLMenuSellFrame:onClickSelectAll: deselected all")
    else
        -- Select all visible animals
        for _, key in ipairs(self.sectionOrder) do
            local items = self.itemsBySection[key]
            if items ~= nil then
                for _, item in ipairs(items) do
                    if item.cluster ~= nil then
                        local cluster = item.cluster
                        local identityKey = RLSelectionKey.build(cluster.farmId, cluster.uniqueId,
                            cluster.birthday and cluster.birthday.country)
                        if identityKey ~= nil then
                            self.selectedAnimals[identityKey] = true
                        else
                            Log:trace("RLMenuSellFrame:onClickSelectAll: nil key for a cluster, skipping")
                        end
                    end
                end
            end
        end
        Log:debug("RLMenuSellFrame:onClickSelectAll: selected all (%d)", self:getSelectedCount())
    end

    -- Reload to re-render checkmarks. Do NOT restoreSelection.
    if self.animalList ~= nil then
        self.animalList:reloadData()
    end
    self:updateButtonVisibility()
    self:updateCartDisplay()
end


-- =============================================================================
-- Filter
-- =============================================================================

--- Open AnimalFilterDialog for the current husbandry's animals.
--- Source list is built from the render universe MINUS the Quick filter so
--- slider ranges always reflect the full pen (sellability-stripped, then
--- saved-filter-narrowed), never the already-Quick-filtered subset.
function RLMenuSellFrame:onClickFilter()
    if self.selectedHusbandry == nil then return end
    if AnimalFilterDialog == nil or AnimalFilterDialog.show == nil then
        Log:warning("RLMenuSellFrame:onClickFilter: AnimalFilterDialog unavailable")
        return
    end

    -- Trailer-dealer context derives the filter-scope type from the trailer's
    -- current-load lock; husbandry context from getAnimalTypeIndex.
    local animalTypeIndex = self:resolveFilterTypeIndex()

    local base, sellable, narrowed = self:buildDialogSourceList()
    Log:debug("RLMenuSellFrame:onClickFilter: opening dialog (savedFilterId=%s, base=%d, sellable=%d, narrowed=%d, animalTypeIndex=%s)",
        tostring(self.activeFilterId), #base, #sellable, #narrowed, tostring(animalTypeIndex))

    -- allowSave=true + sourceUsage=OWNED: see RLMenuInfoFrame:onClickFilter rationale.
    AnimalFilterDialog.show(narrowed, animalTypeIndex, self.onFilterApplied, self, false, true, RLFilterUsage.OWNED)
end


--- AnimalFilterDialog callback. Stores filters, clears selections, and re-queries.
--- @param filters table
--- @param _items table unused
function RLMenuSellFrame:onFilterApplied(filters, _items)
    Log:debug("RLMenuSellFrame:onFilterApplied: clearing selections + applying filters")
    self.filters = filters or {}
    self.selectedAnimals = {}
    self:updateFilterChip()
    self:reloadAnimalList()
end


-- =============================================================================
-- SmoothList data source / delegate
-- =============================================================================

--- @param list table
--- @return number
function RLMenuSellFrame:getNumberOfSections(list)
    if list == self.animalList then return #self.sectionOrder end
    return 0
end

--- @param list table
--- @param section number
--- @return string|nil
function RLMenuSellFrame:getTitleForSectionHeader(list, section)
    if list ~= self.animalList then return nil end
    local key = self.sectionOrder[section]
    return key and self.titlesBySection[key] or nil
end

--- @param list table
--- @param section number
--- @return number
function RLMenuSellFrame:getNumberOfItemsInSection(list, section)
    if list ~= self.animalList then return 0 end
    local key = self.sectionOrder[section]
    if key == nil then return 0 end
    local items = self.itemsBySection[key]
    return items ~= nil and #items or 0
end

--- Populate one data cell. Mirrors Move tab pattern + checkbox rendering.
--- @param list table
--- @param section number
--- @param index number
--- @param cell table
function RLMenuSellFrame:populateCellForItemInSection(list, section, index, cell)
    if list ~= self.animalList then return end

    local key = self.sectionOrder[section]
    if key == nil then return end
    local items = self.itemsBySection[key]
    if items == nil then return end
    local item = items[index]
    if item == nil then return end

    local row = RLAnimalQuery.formatAnimalRow(item)

    -- Cell tint: marked orange, normal otherwise. Disease is signalled by the
    -- status-icon row, which distinguishes untreated from under-treatment from
    -- carrier - three states a single tint cannot carry.
    if cell.setImageColor ~= nil then
        if row.tint == RLAnimalQuery.TINT_MARKED then
            cell:setImageColor(GuiOverlay.STATE_NORMAL, 1, 0.2, 0)
        else
            cell:setImageColor(GuiOverlay.STATE_NORMAL, 1, 1, 1)
        end
    end

    local iconCell = cell:getAttribute("icon")
    if iconCell ~= nil then
        if row.icon ~= nil then
            iconCell:setImageFilename(row.icon)
            iconCell:setVisible(true)
        else
            iconCell:setVisible(false)
        end
    end

    -- Name split
    local idNoNameCell = cell:getAttribute("idNoName")
    local idCell       = cell:getAttribute("id")
    local nameCell     = cell:getAttribute("name")
    local hasBaseName  = row.baseName ~= ""
    if idNoNameCell ~= nil then
        idNoNameCell:setText(row.displayIdentifier)
        idNoNameCell:setVisible(not hasBaseName)
    end
    if idCell ~= nil then
        idCell:setText(row.identifier)
        idCell:setVisible(hasBaseName)
    end
    if nameCell ~= nil then
        nameCell:setText(row.displayName)
        nameCell:setVisible(hasBaseName)
    end

    local priceCell = cell:getAttribute("price")
    if priceCell ~= nil then
        if priceCell.setValue ~= nil then
            priceCell:setValue(row.price)
        else
            priceCell:setText(tostring(row.price))
        end
    end

    local descriptor = cell:getAttribute("herdsmanPurchase")
    if descriptor ~= nil then
        descriptor:setVisible(row.descriptorVisible)
        if row.descriptorVisible then
            descriptor:setText(row.descriptorText)
        end
    end

    -- Status icons: one right-justified row carrying disease, pregnancy/fertility
    -- and production. The slot names, the ordering and the per-state styling all
    -- live in RLAnimalQuery so the five list frames cannot drift apart.
    RLAnimalQuery.applyStatusIconSlots(cell, RLAnimalQuery.SLOT_NAMES,
        RLAnimalQuery.resolveStatusIcons(row))

    -- Checkbox: show check mark + wire onClick callback for direct clicking.
    local checkbox = cell:getAttribute("checkbox")
    local check = cell:getAttribute("check")
    if checkbox ~= nil then
        checkbox:setVisible(true)
        if check ~= nil then
            local identityKey = RLSelectionKey.build(row.farmId, row.uniqueId, row.country)
            check:setVisible(identityKey ~= nil and self.selectedAnimals[identityKey] == true)

            checkbox.onClickCallback = function()
                if not self.isFrameOpen then
                    Log:trace("RLMenuSellFrame checkbox click: frame closed, ignoring")
                    return
                end
                if identityKey == nil then
                    Log:trace("RLMenuSellFrame checkbox click: nil selection key, skipping")
                    return
                end
                self.selectedAnimals[identityKey] = not self.selectedAnimals[identityKey]
                check:setVisible(self.selectedAnimals[identityKey] == true)
                self:updateButtonVisibility()
                self:updateCartDisplay()
                Log:trace("RLMenuSellFrame checkbox click: key=%s -> %s",
                    identityKey, tostring(self.selectedAnimals[identityKey]))
            end
        end
    end
end


-- =============================================================================
-- Trailer-dealer source
-- =============================================================================
-- When the Sell tab is open in MODE_TRAILER + dealer counterpart, the held
-- livestock trailer becomes the single sell SOURCE (overloaded into
-- self.selectedHusbandry so the existing dispatch path is reused unchanged).
-- Every trailer-specific branch resolves through getTrailerDealerContext() so a
-- torn-down / non-livestock ref falls back to the husbandry path.

--- Resolve the held livestock trailer when the Sell tab is open in MODE_TRAILER
--- + dealer counterpart, else nil. Fail-closed: returns the trailer ONLY when
--- g_rlMenu is live, the open mode is MODE_TRAILER, the counterpart is
--- TRAILER_DEALER, and trailerVehicle is a live livestock trailer (the same
--- liveness gate RLMenu.openTrailerFromBridge uses). Mirrors
--- RLMenuBuyFrame:getTrailerDealerContext.
--- @return table|nil trailer The held livestock trailer in trailer-dealer context, or nil
function RLMenuSellFrame:getTrailerDealerContext()
    if g_rlMenu == nil
        or g_rlMenu.openMode ~= RLMenu.MODE_TRAILER
        or g_rlMenu.trailerCounterpart ~= RLMenu.TRAILER_DEALER then
        Log:trace("RLMenuSellFrame:getTrailerDealerContext: not trailer-dealer context -> nil")
        return nil
    end

    local trailer = g_rlMenu.trailerVehicle
    if trailer == nil or trailer.spec_livestockTrailer == nil then
        Log:trace("RLMenuSellFrame:getTrailerDealerContext: trailerVehicle nil or not a livestock trailer -> nil")
        return nil
    end

    Log:trace("RLMenuSellFrame:getTrailerDealerContext: trailer-dealer context resolved")
    return trailer
end


--- Whether a trailer cluster is a loadable animal (legacy initSourceItems
--- parity). Rejects numAnimals < 1 and an unresolvable subTypeIndex. Reproduced
--- as a Sell-frame method because the equivalent gate lives on RLMenuTransferFrame,
--- not a shared module.
--- @param ref table|nil a live cluster from RLTrailerEndpointService.getContents
--- @return boolean loadable
function RLMenuSellFrame:isLoadableTrailerCluster(ref)
    if ref == nil then return false end

    if ref.numAnimals ~= nil and ref.numAnimals < 1 then
        Log:trace("RLMenuSellFrame:isLoadableTrailerCluster: skip numAnimals=%s", tostring(ref.numAnimals))
        return false
    end

    local subTypeIndex = (ref.getSubTypeIndex ~= nil and ref:getSubTypeIndex()) or ref.subTypeIndex
    if subTypeIndex == nil then
        Log:trace("RLMenuSellFrame:isLoadableTrailerCluster: skip nil subTypeIndex")
        return false
    end

    if g_currentMission ~= nil and g_currentMission.animalSystem ~= nil
        and g_currentMission.animalSystem.getSubTypeByIndex ~= nil then
        if g_currentMission.animalSystem:getSubTypeByIndex(subTypeIndex) == nil then
            Log:trace("RLMenuSellFrame:isLoadableTrailerCluster: skip unresolvable subTypeIndex=%s",
                tostring(subTypeIndex))
            return false
        end
    end

    return true
end


--- Wrap the held trailer's live contents into AnimalItemStock items for the Sell
--- list, skipping non-loadable clusters. Mirrors RLMenuTransferFrame:buildTrailerItems
--- (the loadability gate reproduced above). The existing getCanBeSold strip in
--- reloadAnimalList runs AFTER this, so unsellable animals never list.
--- @return table items
function RLMenuSellFrame:buildTrailerSellItems()
    local trailer = self:getTrailerDealerContext()
    if trailer == nil then
        Log:trace("RLMenuSellFrame:buildTrailerSellItems: no trailer context -> {}")
        return {}
    end

    local refs = RLTrailerEndpointService.getContents(trailer)
    local items = {}
    local skipped = 0
    for _, ref in ipairs(refs) do
        if self:isLoadableTrailerCluster(ref) then
            local wrapped = RLAnimalQuery._wrapCluster(ref)
            if wrapped ~= nil then
                items[#items + 1] = wrapped
            else
                skipped = skipped + 1
            end
        else
            skipped = skipped + 1
        end
    end
    Log:debug("RLMenuSellFrame:buildTrailerSellItems: %d item(s), %d skipped (invalid cluster)",
        #items, skipped)
    return items
end


--- Recompute the single trailer-source sidebar entry's `(used/total)` suffix in
--- place after a sell, WITHOUT re-running refreshHusbandries (which would re-fire
--- onHusbandryChanged(1) and clear selectedAnimals). No-op outside trailer context.
function RLMenuSellFrame:updateTrailerSourceLabel()
    local trailer = self:getTrailerDealerContext()
    if trailer == nil or self.subCategorySelector == nil then return end

    local d = RLTrailerEndpointService.getDisplayData(trailer)
    local label = RLTransferAdapter.formatCapacityLabel(d.name, d.used, d.total)
    self.subCategorySelector:setTexts({ label })
    Log:debug("RLMenuSellFrame:updateTrailerSourceLabel: '%s' (%d/%d)", d.name, d.used, d.total)
end


--- Resolve the animal-type index for saved/Quick filter scope. In trailer-dealer
--- context derive it from the trailer's current-load type lock (the trailer is
--- type-locked when loaded); unlocked/empty -> nil (unscoped, no crash). Else the
--- husbandry's getAnimalTypeIndex.
--- @return number|nil animalTypeIndex
function RLMenuSellFrame:resolveFilterTypeIndex()
    local trailer = self:getTrailerDealerContext()
    if trailer ~= nil then
        local currentType = RLTrailerEndpointService.getCurrentType(trailer)
        return currentType ~= nil and currentType.typeIndex or nil
    end
    if self.selectedHusbandry ~= nil and self.selectedHusbandry.getAnimalTypeIndex ~= nil then
        return self.selectedHusbandry:getAnimalTypeIndex()
    end
    return nil
end


--- Clear all pending sell-flow state (cancel, error, or after dispatch). Preserves
--- self.selectedAnimals (the bulk full-clear happens at confirm, not here).
function RLMenuSellFrame:clearPendingSellState()
    self.pendingSellAnimals = nil
    self.pendingSellPrice = nil
    self.pendingSellFee = nil
    self.pendingSellIsTrailer = nil
    self.pendingSellWasBulk = nil
end


--- Trailer-at-dealer sell flow: filter survivors and confirm the SURVIVOR
--- count/price BEFORE the YesNoDialog, then dispatch through the unchanged
--- sellAnimals path. Mirrors RLMenuBuyFrame:startTrailerBuyFlow. Single + bulk
--- both route here. Forces the transport fee to 0 (a trailer-at-dealer sell has
--- no transport leg, legacy AnimalScreenDealerTrailer parity).
--- @param animals table Array of cluster refs the user selected (single = {animal})
function RLMenuSellFrame:startTrailerSellFlow(animals)
    local trailer = self:getTrailerDealerContext()
    if trailer == nil then
        Log:warning("RLMenuSellFrame:startTrailerSellFlow: trailer context resolved nil, clearing pending state")
        self:clearPendingSellState()
        return
    end

    local originalCount = (animals ~= nil) and #animals or 0

    -- The validate adapter gates on getCanBeSold - exact parity with the
    -- authoritative server leg (AnimalSellEvent:run gates per-animal on
    -- getCanBeSold + permission only). The headless suite injects a mock instead.
    local validate = function(_source, animal)
        if animal ~= nil and animal.getCanBeSold ~= nil and not animal:getCanBeSold() then
            return AnimalSellEvent.SELL_ERROR_CANNOT_BE_SOLD
        end
        return nil
    end

    local result = RLAnimalSellService.filterSellableAnimals(trailer, animals, validate)
    local validCount    = #result.valid
    local rejectedCount  = #result.rejected

    Log:debug("RLMenuSellFrame:startTrailerSellFlow: trailer='%s' %d valid, %d rejected (of %d), firstErrorCode=%s",
        tostring(trailer.getName and trailer:getName()),
        validCount, rejectedCount, originalCount, tostring(result.firstErrorCode))

    if validCount == 0 then
        -- Specific error when a validate gate fired (legacy parity); generic otherwise.
        if result.firstErrorCode ~= nil then
            InfoDialog.show(RLAnimalSellService.getErrorText(result.firstErrorCode))
        else
            InfoDialog.show(g_i18n:getText("rl_ui_moveAllRejected"))
        end
        self:clearPendingSellState()
        return
    end

    if rejectedCount > 0 then
        Log:warning("RLMenuSellFrame:startTrailerSellFlow: %d of %d animals skipped (firstErrorCode=%s)",
            rejectedCount, originalCount, tostring(result.firstErrorCode))
    end

    -- Gross survivor price; fee forced 0 (no transport leg). computeBulkTotal's
    -- FIRST return is the sum of getSellPrice over the survivors.
    local grossPrice = RLAnimalSellService.computeBulkTotal(result.valid)

    self.pendingSellAnimals   = result.valid
    self.pendingSellPrice     = grossPrice
    self.pendingSellFee       = 0
    self.pendingSellIsTrailer = true
    self.pendingSellWasBulk   = originalCount > 1

    -- Confirm the ACTUAL survivors the client will dispatch (the server remains
    -- authoritative and re-validates at run time). Reuses the existing builders -
    -- no new i18n key.
    local confirmText
    if validCount == 1 then
        confirmText = RLAnimalSellService.buildSingleConfirmationText(result.valid[1], grossPrice, 0)
    else
        confirmText = RLAnimalSellService.buildBulkConfirmationText(validCount, grossPrice, 0)
    end

    YesNoDialog.show(self.onSellConfirmed, self, confirmText, g_i18n:getText("ui_attention"))
end


-- =============================================================================
-- Sell operations
-- =============================================================================

--- Sell the currently focused (highlighted) animal.
function RLMenuSellFrame:onClickSell()
    local animal = self:getSelectedAnimal()
    if animal == nil then
        Log:trace("RLMenuSellFrame:onClickSell: no animal focused")
        return
    end

    -- Trailer-dealer context: the held trailer is the sell SOURCE. Route single +
    -- bulk through the same survivor-filtered flow (filter -> survivor confirm ->
    -- dispatch), mirroring the Buy slice's startTrailerBuyFlow.
    if self:getTrailerDealerContext() ~= nil then
        Log:debug("RLMenuSellFrame:onClickSell: trailer-dealer context, routing single to startTrailerSellFlow")
        self:startTrailerSellFlow({ animal })
        return
    end

    local price, fee, _ = RLAnimalSellService.computeSellPrice(animal)
    local confirmText = RLAnimalSellService.buildSingleConfirmationText(animal, price, fee)

    Log:debug("RLMenuSellFrame:onClickSell: single sell for farmId=%s uniqueId=%s price=%.0f fee=%.0f",
        tostring(animal.farmId), tostring(animal.uniqueId), price, fee)

    -- Store pending state for confirmation callback
    self.pendingSellAnimals = { animal }
    self.pendingSellPrice = price
    self.pendingSellFee = fee

    YesNoDialog.show(self.onSellConfirmed, self, confirmText, g_i18n:getText("ui_attention"))
end


--- Sell all checked animals.
function RLMenuSellFrame:onClickSellSelected()
    local animals = {}
    for _, sectionKey in ipairs(self.sectionOrder) do
        local items = self.itemsBySection[sectionKey]
        if items ~= nil then
            for _, item in ipairs(items) do
                if item.cluster ~= nil then
                    local cluster = item.cluster
                    local identityKey = RLSelectionKey.build(cluster.farmId, cluster.uniqueId,
                        cluster.birthday and cluster.birthday.country)
                    if identityKey ~= nil and self.selectedAnimals[identityKey] then
                        table.insert(animals, cluster)
                    end
                end
            end
        end
    end

    if #animals == 0 then
        Log:trace("RLMenuSellFrame:onClickSellSelected: no animals checked")
        return
    end

    -- Trailer-dealer context: route the checked set through startTrailerSellFlow
    -- (filter survivors -> survivor confirm -> dispatch). See onClickSell.
    if self:getTrailerDealerContext() ~= nil then
        Log:debug("RLMenuSellFrame:onClickSellSelected: trailer-dealer context, routing bulk to startTrailerSellFlow (%d animals)",
            #animals)
        self:startTrailerSellFlow(animals)
        return
    end

    local totalPrice, totalFee, _, count = RLAnimalSellService.computeBulkTotal(animals)
    local confirmText = RLAnimalSellService.buildBulkConfirmationText(count, totalPrice, totalFee)

    Log:debug("RLMenuSellFrame:onClickSellSelected: bulk sell %d animals, price=%.0f fee=%.0f",
        count, totalPrice, totalFee)

    -- Store pending state for confirmation callback
    self.pendingSellAnimals = animals
    self.pendingSellPrice = totalPrice
    self.pendingSellFee = totalFee

    YesNoDialog.show(self.onSellConfirmed, self, confirmText, g_i18n:getText("ui_attention"))
end


--- Callback from YesNoDialog confirmation.
--- @param clickYes boolean
function RLMenuSellFrame:onSellConfirmed(clickYes)
    Log:debug("RLMenuSellFrame:onSellConfirmed: clickYes=%s", tostring(clickYes))

    if not clickYes then
        -- Cancel preserves self.selectedAnimals so a rejected partial-confirm does
        -- not force the user to rebuild the selection (Buy-slice parity).
        self:clearPendingSellState()
        return
    end

    if self.pendingSellAnimals == nil or self.selectedHusbandry == nil then
        Log:debug("RLMenuSellFrame:onSellConfirmed: nil pending state")
        self:clearPendingSellState()
        return
    end

    -- In-flight guard: a sale is already awaiting a server reply. Keep the selection +
    -- surface "in progress"; do NOT dispatch a second same-class request.
    if self.sellPending then
        Log:debug("RLMenuSellFrame:onSellConfirmed: a sale is already in flight, ignoring (selection kept)")
        InfoDialog.show(g_i18n:getText("rl_ui_tradeRequestInProgress"))
        return
    end

    local animals  = self.pendingSellAnimals
    local price    = self.pendingSellPrice
    local fee      = self.pendingSellFee
    local isTrailer = self.pendingSellIsTrailer == true
    local wasBulk   = self.pendingSellWasBulk == true

    -- Resolve the dispatch SOURCE. In trailer-dealer context re-resolve the live
    -- trailer immediately before dispatch (a trailer torn down during the dialog
    -- must not dispatch a dead ref); capture it for the post-sell identity guard.
    local source = self.selectedHusbandry
    if isTrailer then
        local trailer = self:getTrailerDealerContext()
        if trailer == nil then
            Log:warning("RLMenuSellFrame:onSellConfirmed: trailer context lost before dispatch, aborting")
            self:clearPendingSellState()
            return
        end
        source = trailer
        self.dispatchedTrailer = trailer
    else
        self.dispatchedTrailer = nil
    end

    -- Selection-clear plan, APPLIED ONLY on an accepted dispatch below so a rejected
    -- same-class sale keeps its selection: a bulk-origin sale clears all (so rejected,
    -- still-checked animals do not linger and re-sell); a single removes only the sold
    -- animal. Trailer keys off the ORIGINAL bulk flag (survivors may be 1).
    local clearAll = isTrailer and wasBulk or (not isTrailer and #animals > 1)

    self:clearPendingSellState()

    -- Trailer dispatch fires AnimalSellEvent.new(trailer, survivors, grossPrice, 0)
    -- via the unchanged sellAnimals (-totalFee makes 0 round-trip) - mutation
    -- parity with legacy AnimalScreenDealerTrailer:applyTarget/applyTargetBulk.
    if isTrailer then
        Log:info("RLMenuSellFrame:onSellConfirmed: trailer-sell dispatch '%s' (%d animals)",
            tostring(source.getName and source:getName()), #animals)
    end

    -- Set the in-flight lock BEFORE dispatch (SP fires onSellComplete synchronously inside
    -- sellAnimals, clearing the lock). Read the service's accept/reject: a false return means
    -- no request is pending - release the lock and KEEP the selection so the player can retry.
    self.sellPending = true
    local accepted = RLAnimalSellService.sellAnimals(
        source, animals, price, fee,
        self.onSellComplete, self)

    if not accepted then
        self.sellPending = false
        Log:debug("RLMenuSellFrame:onSellConfirmed: dispatch rejected/not-dispatched, keeping selection")
        InfoDialog.show(g_i18n:getText("rl_ui_tradeRequestInProgress"))
        return
    end

    -- Accepted: apply the selection-clear plan.
    if clearAll then
        self.selectedAnimals = {}
    else
        for _, animal in ipairs(animals) do
            local key = RLSelectionKey.build(animal.farmId, animal.uniqueId,
                animal.birthday and animal.birthday.country)
            if key ~= nil then
                self.selectedAnimals[key] = nil
            end
        end
    end

    -- Re-run the selection-derived refresh AFTER the clear: in SP the completion (onSellComplete)
    -- already fired synchronously inside sellAnimals and repainted the cart/buttons from the
    -- pre-clear selection, so recompute them against the now-cleared set.
    self:updateCartDisplay()
    self:updateButtonVisibility()
end


--- Callback from RLAnimalSellService after server responds.
--- Stale-frame guard: skips refresh if the frame has closed (tab-switch /
--- menu-close mid-dispatch) OR if the husbandry context was cleared.
--- Trailer guard: a delayed callback after the dispatched trailer was torn down
--- or swapped during the MP round-trip is ignored (no repaint of a stale /
--- husbandry context) - mirrors the onTransferComplete identity guard.
--- @param errorCode number
function RLMenuSellFrame:onSellComplete(errorCode)
    -- The dispatched request has completed (reply or watchdog timeout) - always release
    -- the in-flight lock so the frame isn't stranded, even when a stale-guard skips the refresh.
    self.sellPending = false

    if not self.isFrameOpen or self.selectedHusbandry == nil then
        Log:trace("RLMenuSellFrame:onSellComplete: stale frame (isFrameOpen=%s husbandry=%s), ignoring",
            tostring(self.isFrameOpen), tostring(self.selectedHusbandry ~= nil))
        return
    end

    -- Captured-trailer identity guard: the existing selectedHusbandry check passes
    -- for any non-nil ref (incl. a dead trailer), so check the dispatched trailer
    -- is STILL the live one before repainting a trailer context.
    local wasTrailer = self.dispatchedTrailer ~= nil
    if wasTrailer then
        local liveTrailer = self:getTrailerDealerContext()
        if liveTrailer == nil or liveTrailer ~= self.dispatchedTrailer then
            Log:trace("RLMenuSellFrame:onSellComplete: trailer context flipped/torn down, ignoring stale callback")
            self.dispatchedTrailer = nil
            return
        end
    end

    if errorCode ~= AnimalSellEvent.SELL_SUCCESS then
        InfoDialog.show(RLAnimalSellService.getErrorText(errorCode))
        Log:debug("RLMenuSellFrame:onSellComplete: sell failed, errorCode=%s", tostring(errorCode))
    else
        Log:info("RLMenuSellFrame:onSellComplete: sell succeeded")
    end

    self.dispatchedTrailer = nil

    -- Refresh list + cart + money. In trailer context the list shrinks (empty-state
    -- shows no-ANIMALS since the trailer source stays present), the pen header stays
    -- hidden, and the single sidebar entry's (used/total) suffix updates in place.
    -- The active tab is preserved (no anchor re-eval).
    self:reloadAnimalList()
    if wasTrailer then
        self:updateTrailerSourceLabel()
    end
    self:updatePenHeader()
    self:updateCartDisplay()
    RLDetailPaneHelper.updateMoneyDisplay(self)
end

-- =============================================================================
-- Saved-filter cycle + chip
-- =============================================================================

function RLMenuSellFrame:onCycleFilter()
    if self.farmId == nil or self.farmId == 0 then
        Log:trace("RLMenuSellFrame:onCycleFilter: no farm, aborting")
        return
    end

    -- Trailer-dealer context derives the filter-scope type from the trailer's
    -- current-load lock; husbandry context from getAnimalTypeIndex.
    local animalTypeIndex = self:resolveFilterTypeIndex()

    local filters = RLFilterCycleHelper.getAvailableFilters(animalTypeIndex, self.farmId, RLFilterCycleHelper.USAGE.OWNED)
    if #filters == 0 then
        if self.activeFilterId ~= nil then
            self.activeFilterId = nil
            self.activeFilter = nil
        end
        Log:trace("RLMenuSellFrame:onCycleFilter: no filters available, chip reset")
        self:updateFilterChip()
        self:reloadAnimalList()
        return
    end

    local nextId = RLFilterCycleHelper.cycleFilterId(self.activeFilterId, filters)
    local prevId = self.activeFilterId
    self.activeFilterId = nextId
    self.activeFilter = (nextId ~= nil and g_rlFilterService ~= nil
        and g_rlFilterService:getById(nextId)) or nil

    Log:debug("RLMenuSellFrame:onCycleFilter: from=%s to=%s (count=%d)",
        tostring(prevId), tostring(nextId), #filters)

    self:updateFilterChip()
    self:reloadAnimalList()
end

--- Render the filterChip Text element to reflect the combined Quick filter
--- + saved filter state. Delegates branch resolution to the
--- shared RLFilterChipHelper so all four RL Menu frames render consistently.
--- No-op + WARNING if the XML element is missing.
function RLMenuSellFrame:updateFilterChip()
    local chip = self.filterChip
    if chip == nil then
        Log:warning("RLMenuSellFrame:updateFilterChip: filterChip element missing from XML")
        return
    end

    local s = RLFilterChipHelper.composeChipState(self.filters, self.activeFilter)
    chip:setVisible(s.visible)
    if s.visible then
        if s.savedName ~= nil then
            chip:setText(string.format(g_i18n:getText(s.textKey), s.savedName))
        else
            chip:setText(g_i18n:getText(s.textKey))
        end
    end

    local branch
    if not s.visible then
        branch = "hidden"
    elseif s.textKey == "rl_menu_filter_chip_quick" then
        branch = "quick-only"
    elseif s.textKey == "rl_menu_filter_chip_active" then
        branch = "saved-only"
    else
        branch = "quick+saved"
    end
    Log:trace("RLMenuSellFrame:updateFilterChip: branch=%s saved=%s",
        branch, tostring(s.savedName))

    if chip.absPosition ~= nil and chip.size ~= nil then
        Log:debug("RLMenuSellFrame:updateFilterChip: absPos=(%.0f,%.0f)px size=(%.0f,%.0f)px",
            chip.absPosition[1] * 1920, chip.absPosition[2] * 1080,
            (chip.size[1] or 0) * 1920, (chip.size[2] or 0) * 1080)
    end
end

function RLMenuSellFrame:revalidateActiveFilter()
    if self.activeFilterId == nil then return end

    if self.farmId == nil or self.farmId == 0 then
        self.activeFilterId = nil
        self.activeFilter = nil
        Log:debug("RLMenuSellFrame:revalidateActiveFilter: no farm, cleared")
        return
    end

    -- Trailer-dealer context derives the filter-scope type from the trailer's
    -- current-load lock; husbandry context from getAnimalTypeIndex.
    local animalTypeIndex = self:resolveFilterTypeIndex()

    local available = RLFilterCycleHelper.getAvailableFilters(animalTypeIndex, self.farmId, RLFilterCycleHelper.USAGE.OWNED)
    local stillInScope = false
    for _, f in ipairs(available) do
        if f.id == self.activeFilterId then
            stillInScope = true
            break
        end
    end

    if not stillInScope then
        Log:debug("RLMenuSellFrame:revalidateActiveFilter: id=%s out of scope, cleared",
            tostring(self.activeFilterId))
        self.activeFilterId = nil
        self.activeFilter = nil
    else
        if g_rlFilterService ~= nil then
            self.activeFilter = g_rlFilterService:getById(self.activeFilterId)
        end
        Log:trace("RLMenuSellFrame:revalidateActiveFilter: id=%s still in scope, snapshot refreshed",
            tostring(self.activeFilterId))
    end
end

--- Remote-change fanout hook fired from RLFilter{Create,Update,Delete}Event:run
--- when a peer mutates a saved filter. Id-match gate short-circuits when the
--- changed filter is not this frame's active filter, preserving user selection
--- and detail-pane state. Otherwise re-runs revalidateActiveFilter +
--- updateFilterChip + reloadAnimalList so the displayed list reflects the
--- new active-filter state. Clears g_rlMenu.sharedSelection.activeFilterId
--- when revalidate cleared the active filter (Sell participates in shared
--- selection alongside Info + Move; Buy is isolated).
---@param filterId string  -- id of the filter that was created/updated/deleted on the network
---@param changeType string  -- "create" | "update" | "delete"
function RLMenuSellFrame:onRemoteFilterChange(filterId, changeType)
    Log:trace("RLMenuSellFrame:onRemoteFilterChange: id=%s change=%s activeId=%s isFrameOpen=%s",
        tostring(filterId), tostring(changeType), tostring(self.activeFilterId), tostring(self.isFrameOpen))

    if self.isFrameOpen ~= true then
        Log:trace("RLMenuSellFrame:onRemoteFilterChange: frame not open, deferring to onFrameOpen")
        return
    end

    if filterId ~= self.activeFilterId then
        Log:trace("RLMenuSellFrame:onRemoteFilterChange: no-op (non-active change)")
        return
    end

    self:revalidateActiveFilter()
    self:updateFilterChip()
    self:reloadAnimalList()

    if self.activeFilter == nil then
        if g_rlMenu ~= nil and g_rlMenu.sharedSelection ~= nil then
            g_rlMenu.sharedSelection.activeFilterId = nil
            Log:trace("RLMenuSellFrame:onRemoteFilterChange: sharedSelection.activeFilterId cleared")
        end
        Log:debug("RLMenuSellFrame:onRemoteFilterChange: active filter cleared (delete or scope-narrow)")
    else
        Log:debug("RLMenuSellFrame:onRemoteFilterChange: active filter snapshot refreshed")
    end
end
