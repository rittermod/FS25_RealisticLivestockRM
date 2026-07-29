--[[
    RLMenuBuyFrame.lua
    RL Tabbed Menu - Buy tab.

    Left-sidebar dealer animal-type picker with dot indicators, multi-section
    SmoothList of sale-animal cards with checkboxes for multi-select, and
    right-hand detail pane (pen column + animal column via RLDetailPaneHelper).

    Browsable dealer frame with isolated selection (no shared state with
    Info/Move/Sell), Diseased-first + per-subtype sectioning, per-row
    dealer-marked-up prices, and a running cart summary (count + price +
    transport fee + total). Buy / Buy Selected action buttons are disabled
    placeholders pending buy-logic integration with RLAnimalBuyService and a
    destination picker.
]]

RLMenuBuyFrame = {}
local RLMenuBuyFrame_mt = Class(RLMenuBuyFrame, TabbedMenuFrameElement)

local Log = RmLogging.getLogger("RLRM")

local modDirectory = g_currentModDirectory


--- Construct a new RLMenuBuyFrame instance.
--- @return table self
function RLMenuBuyFrame.new()
    local self = RLMenuBuyFrame:superClass().new(nil, RLMenuBuyFrame_mt)
    self.name = "RLMenuBuyFrame"

    -- Dealer types (Buy-specific: no per-farm husbandries)
    self.sortedTypes       = {}    -- array of animal type entries from animalSystem:getTypes
    self.items             = {}
    self.filters           = {}
    self.farmId            = nil

    self.sectionOrder      = {}
    self.itemsBySection    = {}
    self.titlesBySection   = {}

    self.selectedIdentity  = nil   -- { farmId, uniqueId, country } for focused dealer animal
    self.selectedAnimals   = {}    -- keyed by RLAnimalUtil.toKey identity string

    self.isFrameOpen = false
    self.hasCustomMenuButtons = true

    -- In-flight UI lock for a dispatched buy (mirrors RLMenuTransferFrame.movePending):
    -- set before dispatch, released on the service's false return or on completion, and
    -- reset on frame open so a stranded lock self-heals.
    self.buyPending = false

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
    self.buyButtonInfo = {
        inputAction = InputAction.MENU_EXTRA_1,
        text = g_i18n:getText("button_buy"),
        disabled = true,
        callback = function() self:onClickBuy() end,
    }
    self.buySelectedButtonInfo = {
        inputAction = InputAction.MENU_EXTRA_2,
        text = g_i18n:getText("rl_ui_buySelected"),
        disabled = true,
        callback = function() self:onClickBuySelected() end,
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


--- Load the buy frame XML and register it with g_gui.
function RLMenuBuyFrame.setupGui()
    local frame = RLMenuBuyFrame.new()
    g_gui:loadGui(
        Utils.getFilename("gui/rlmenu/buyFrame.xml", modDirectory),
        "RLMenuBuyFrame",
        frame,
        true
    )
    Log:debug("RLMenuBuyFrame.setupGui: registered")
end


--- Bind the SmoothList datasource/delegate. Fires on both the initial load
--- instance and the FrameReference clone; tree mutation lives in initialize().
function RLMenuBuyFrame:onGuiSetupFinished()
    RLMenuBuyFrame:superClass().onGuiSetupFinished(self)

    if self.animalList ~= nil then
        self.animalList:setDataSource(self)
        self.animalList:setDelegate(self)
    else
        Log:warning("RLMenuBuyFrame:onGuiSetupFinished: animalList element missing from XML")
    end
end


--- One-time per-clone setup. Unlinks the dot template from the element tree
--- so it can be cloned at runtime. Also permanently hides the pen-info row
--- (inherited from sellFrame.xml) because the Buy tab views the dealer, not
--- a pen - "Pen Information: Name / Count / Icon" is semantically meaningless
--- here and no dealer-icon asset is provided to substitute. Hiding once in
--- initialize is cheaper than toggling in every frame-open / reload path.
--- Called by RLMenu:setupMenuPages.
function RLMenuBuyFrame:initialize()
    if self.subCategoryDotTemplate ~= nil then
        self.subCategoryDotTemplate:unlinkElement()
        FocusManager:removeElement(self.subCategoryDotTemplate)
    else
        Log:warning("RLMenuBuyFrame:initialize: subCategoryDotTemplate missing")
    end

    -- Hide inherited pen-info row (no "pen" concept for dealer-side Buy)
    if self.penInformationHeader ~= nil then self.penInformationHeader:setVisible(false) end
    if self.penNameText         ~= nil then self.penNameText:setVisible(false) end
    if self.penCountText        ~= nil then self.penCountText:setVisible(false) end
    if self.penIcon             ~= nil then self.penIcon:setVisible(false) end
    Log:debug("RLMenuBuyFrame:initialize: pen-info row hidden (Buy has no pen concept)")
end


-- =============================================================================
-- Lifecycle
-- =============================================================================

--- Called by the Paging element when this tab becomes active.
--- Isolated selection - does NOT import or export g_rlMenu.sharedSelection.
function RLMenuBuyFrame:onFrameOpen()
    RLMenuBuyFrame:superClass().onFrameOpen(self)
    self.isFrameOpen = true
    -- Self-heal a lock stranded by a buy whose completion never fired (frame closed mid-flight).
    self.buyPending = false
    Log:debug("RLMenuBuyFrame:onFrameOpen")

    self:refreshTypes()

    -- Subscribe to MONEY_CHANGED so the header balance refreshes when a
    -- post-buy balance update arrives asynchronously (MP) or when any other
    -- code path credits/debits the farm while this frame is open. SP is
    -- unaffected because the change is synchronous there.
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

    -- Revalidate active saved filter against current dealer type + render chip.
    self:revalidateActiveFilter()
    self:updateFilterChip()
end


--- Called by the Paging element when this tab is deactivated.
--- Isolated selection - does NOT export to g_rlMenu.sharedSelection.
function RLMenuBuyFrame:onFrameClose()
    Log:debug("RLMenuBuyFrame:onFrameClose")

    -- Quick filter is a per-frame session affordance;
    -- clear it on tab close so a sibling tab open starts clean. Log only
    -- when something was actually cleared to keep tab-switch traffic quiet.
    if next(self.filters) ~= nil then
        local count = 0
        for _ in pairs(self.filters) do count = count + 1 end
        Log:debug("RLMenuBuyFrame:onFrameClose: cleared %d Quick filter condition(s)", count)
        self.filters = {}
    end

    g_messageCenter:unsubscribe(MessageType.MONEY_CHANGED, self)
    RLMenuBuyFrame:superClass().onFrameClose(self)
    self.isFrameOpen = false
end


--- MessageType.MONEY_CHANGED handler. Fires on both server and client
--- contexts: on clients, the message is published locally after the farm
--- balance is updated from a server stream, so subscribing lets the Buy
--- frame refresh its header balance in MP without polling. No farmId
--- gating here because updateMoneyDisplay reads the current player's farm
--- internally.
function RLMenuBuyFrame:onMoneyChanged()
    if not self.isFrameOpen then return end
    Log:trace("RLMenuBuyFrame:onMoneyChanged: refreshing money display")
    RLDetailPaneHelper.updateMoneyDisplay(self)
end


-- =============================================================================
-- Dealer type selector
-- =============================================================================

--- Repopulate the type selector + dot indicators from RLDealerQuery.
--- Shows every registered type, not only types with stock (types with zero
--- stock render the empty-animals text, matching how Sell handles husbandries
--- with zero animals - keeps the sidebar layout stable across restocks).
function RLMenuBuyFrame:refreshTypes()
    local farmId = RLAnimalInfoService.getCurrentFarmId()
    self.farmId = farmId

    self.sortedTypes = RLDealerQuery.listDealerTypes()
    Log:debug("RLMenuBuyFrame:refreshTypes: farmId=%s types=%d",
        tostring(farmId), #self.sortedTypes)

    -- Trailer-dealer: scope the sidebar to trailer-supported types (locked to the current
    -- type once the trailer is non-empty). An empty result falls through to the zero-types
    -- empty-state path below. The non-trailer Buy keeps every registered type (probe nil).
    local trailer = self:getTrailerDealerContext()
    if trailer ~= nil then
        local before = #self.sortedTypes
        self.sortedTypes = RLAnimalBuyService.filterTrailerSupportedTypes(self.sortedTypes, trailer)
        Log:debug("RLMenuBuyFrame:refreshTypes: trailer-dealer type filter %d -> %d",
            before, #self.sortedTypes)
    end

    if self.subCategoryDotBox ~= nil then
        for i, dot in pairs(self.subCategoryDotBox.elements) do
            dot:delete()
            self.subCategoryDotBox.elements[i] = nil
        end
    end

    if #self.sortedTypes == 0 then
        Log:trace("RLMenuBuyFrame:refreshTypes: no types, showing empty state")
        if self.noHusbandriesText ~= nil then self.noHusbandriesText:setVisible(true) end
        if self.subCategoryDotBox ~= nil then self.subCategoryDotBox:setVisible(false) end
        if self.subCategorySelector ~= nil then self.subCategorySelector:setTexts({}) end
        self.activeAnimalTypeIndex = nil
        self.items = {}
        self.selectedAnimals = {}
        -- Clear section state BEFORE reloadData so SmoothList's section-count
        -- callback does not read stale keys from a prior populated type.
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
    for index, animalType in ipairs(self.sortedTypes) do
        names[index] = RLAnimalUtil.getAnimalTypeDisplayName(animalType)

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

    -- Isolated selection: always start on state 1 (first type). No shared
    -- selection import.
    local initialState = 1

    if self.subCategorySelector ~= nil then
        self.subCategorySelector:setTexts(names)
        self.subCategorySelector:setState(initialState, true)
    else
        self:onTypeChanged(initialState)
    end
end


--- MultiTextOption onClick callback. Clears selections on type change.
--- @param state number 1-based type index
function RLMenuBuyFrame:onTypeChanged(state)
    if state == nil or state < 1 or state > #self.sortedTypes then return end

    local animalType = self.sortedTypes[state]
    local newTypeIndex = animalType and animalType.typeIndex or nil

    if self.activeAnimalTypeIndex ~= nil
        and newTypeIndex ~= nil
        and newTypeIndex ~= self.activeAnimalTypeIndex
        and next(self.filters) ~= nil then
        Log:debug("RLMenuBuyFrame:onTypeChanged: animal type changed, clearing filters")
        self.filters = {}
    end
    self.activeAnimalTypeIndex = newTypeIndex

    -- Saved-filter scope revalidation (mirrors ad-hoc clear above).
    self:revalidateActiveFilter()
    self:updateFilterChip()

    -- Clear selections on type switch (new animal set)
    self.selectedAnimals = {}

    Log:debug("RLMenuBuyFrame:onTypeChanged: state=%d typeIndex=%s", state, tostring(newTypeIndex))

    self:reloadAnimalList()
    self:updateCartDisplay()
    RLDetailPaneHelper.updateMoneyDisplay(self)
end


--- SmoothList delegate: fired when the user picks a different row.
--- @param list table
--- @param section number
--- @param index number
function RLMenuBuyFrame:onListSelectionChanged(list, section, index)
    if list ~= self.animalList then return end
    if section == nil or index == nil then return end
    Log:trace("RLMenuBuyFrame:onListSelectionChanged: section=%d index=%d", section, index)

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

    -- Dealer animals have no source husbandry; detail helper tolerates nil.
    RLDetailPaneHelper.updateAnimalDisplay(self, item.cluster, nil)
    self:updateButtonVisibility()
end


-- =============================================================================
-- Animal list
-- =============================================================================

--- Build the dialog source list for the Quick filter dialog.
--- Mirrors reloadAnimalList's universe construction MINUS the Quick filter,
--- so the dialog's slider min/max derivation sees the full dealer pool (or
--- saved-filter-narrowed pool) instead of the already-Quick-filtered subset.
--- Parity with reloadAnimalList is enforceable by eye (the two are stacked).
---@return table base   full dealer-pool universe for active animal type
---@return table narrowed base after saved-filter layer (== base when none)
function RLMenuBuyFrame:buildDialogSourceList()
    if self.activeAnimalTypeIndex == nil then return {}, {} end
    local base = RLDealerQuery.listDealerAnimalsForType(self.activeAnimalTypeIndex)
    local narrowed = RLFilterCycleHelper.applyFilter(base, self.activeFilter)
    return base, narrowed
end


--- Refresh only when the frame is currently open. Called by
--- AnimalSystemStateEvent:run so a wholesale dealer-pool replacement - from a
--- dealer-quality preset change or the Reset Animal Dealer button - rebinds an
--- open list instead of leaving it holding items that no longer exist.
--- Delegates to reloadAnimalList, which already owns selection capture/restore.
function RLMenuBuyFrame:refreshIfOpen()
    if self.isFrameOpen then
        Log:debug("RLMenuBuyFrame:refreshIfOpen: refreshing")
        self:reloadAnimalList()
    else
        Log:debug("RLMenuBuyFrame:refreshIfOpen: frame closed, skipping")
    end
end


--- Requery dealer stock for the active type, group into sections, refresh
--- the SmoothList, restore selection by identity.
--- No canBeSold filter: dealer animals are freshly generated and always
--- saleable by the dealer; the buy-side filter is server-validated.
function RLMenuBuyFrame:reloadAnimalList()
    Log:trace("RLMenuBuyFrame:reloadAnimalList: begin")
    self:captureCurrentSelection()

    if self.activeAnimalTypeIndex == nil then
        self.items = {}
    else
        self.items = RLDealerQuery.listDealerAnimalsForType(self.activeAnimalTypeIndex)

        if self.filters ~= nil and next(self.filters) ~= nil
            and AnimalFilterDialog ~= nil and AnimalFilterDialog.applyFilters ~= nil then
            -- Buy frame is buy-mode by definition. Match the dialog-open path
            -- (onClickFilter passes isBuyMode=true) so the list-rebuild filter
            -- evaluates Value with the active dealer-quality markup, not raw sell-price.
            self.items = AnimalFilterDialog.applyFilters(self.items, self.filters, true)
        end

        -- Saved-filter narrowing (AND with ad-hoc). Dealer animals may fail
        -- monitor-gated catalog fields (expected fail-closed).
        if self.activeFilter ~= nil then
            self.items = RLFilterCycleHelper.applyFilter(self.items, self.activeFilter)
        end
    end

    self.sectionOrder, self.itemsBySection, self.titlesBySection =
        RLDealerQuery.buildDealerSections(self.items)

    if self.animalList ~= nil then
        self.animalList:reloadData()
    end

    self:restoreSelection()
    self:updateEmptyState()
    self:updateButtonVisibility()
    self:updateCartDisplay()

    -- ONE dealer-list digest per population - never per row. This is the
    -- walkthrough oracle for the dealer-quality GUI seams: it carries the
    -- active preset, the resolved markup and the per-row buy prices, so the
    -- named B2 steps can predict prices offline and assert them against a log
    -- line instead of eyeballing the screen. Guarded on the level because the
    -- per-row digest is built eagerly and would otherwise be paid at every level.
    if Log.level >= RmLogging.LOG_LEVEL.TRACE then
        local presetIndex = RLDealerQualityResolver.getActiveIndex()
        local parts = {}

        for _, item in ipairs(self.items or {}) do
            if item.cluster ~= nil then
                parts[#parts + 1] = string.format("%.0f", RLAnimalBuyService.computeBuyPrice(item.cluster))
            end
        end

        Log:trace("RLMenuBuyFrame:reloadAnimalList: dealer list preset=%d(%s) markup=%.3f rows=%d prices=[%s]",
            presetIndex, RLDealerQualityModel.getPreset(presetIndex).key,
            RLDealerQualityResolver.getMarkup(), #parts, table.concat(parts, ","))
    end
end


--- Capture the currently highlighted animal's identity.
function RLMenuBuyFrame:captureCurrentSelection()
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
function RLMenuBuyFrame:restoreSelection()
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
        RLDetailPaneHelper.updateAnimalDisplay(self, item.cluster, nil)
    end
end


-- =============================================================================
-- Empty state / buttons
-- =============================================================================

--- Toggle empty-state text + list chrome based on the current data.
function RLMenuBuyFrame:updateEmptyState()
    local hasTypes = #self.sortedTypes > 0
    local hasItems = #self.items > 0

    if self.noAnimalsText ~= nil then
        self.noAnimalsText:setVisible(hasTypes and not hasItems)
    end
end


--- Get the currently focused animal from the list.
--- @return table|nil cluster
function RLMenuBuyFrame:getSelectedAnimal()
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
function RLMenuBuyFrame:getSelectedCount()
    local count = 0
    for _, selected in pairs(self.selectedAnimals) do
        if selected then
            count = count + 1
        end
    end
    return count
end


--- Rebuild the footer button info. Back + Filter always; Buy/BuySelected/Select/SelectAll
--- conditional on state. Buy requires a focused animal; Buy Selected requires at
--- least one checked animal; both require `tradeAnimals` farm permission
--- (client-side gate - server has matching defense-in-depth in the
--- corresponding event handler).
function RLMenuBuyFrame:updateButtonVisibility()
    self.menuButtonInfo = { self.backButtonInfo }

    local hasTypes = #self.sortedTypes > 0
    local hasItems = #self.items > 0
    local selectedCount = self:getSelectedCount()
    local focusedAnimal = self:getSelectedAnimal()
    local canTrade = g_currentMission ~= nil
        and g_currentMission.getHasPlayerPermission ~= nil
        and g_currentMission:getHasPlayerPermission("tradeAnimals")

    if hasTypes then
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

    if hasItems then
        local buySelText = g_i18n:getText("rl_ui_buySelected")
        if selectedCount > 0 then
            buySelText = buySelText .. " (" .. selectedCount .. ")"
        end
        self.buySelectedButtonInfo.text = buySelText
        self.buySelectedButtonInfo.disabled = (selectedCount == 0) or (not canTrade)
        table.insert(self.menuButtonInfo, self.buySelectedButtonInfo)

        self.buyButtonInfo.disabled = (focusedAnimal == nil) or (not canTrade)
        table.insert(self.menuButtonInfo, self.buyButtonInfo)
    end

    Log:trace("RLMenuBuyFrame:updateButtonVisibility: %d buttons, selectedCount=%d focused=%s canTrade=%s",
        #self.menuButtonInfo, selectedCount, tostring(focusedAnimal ~= nil), tostring(canTrade))
    self:setMenuButtonInfoDirty()
end


-- =============================================================================
-- Buy operations
-- =============================================================================

--- Buy the currently focused (highlighted) dealer animal.
--- Flow: price confirm -> destination picker -> validation -> AnimalBuyEvent.
function RLMenuBuyFrame:onClickBuy()
    local animal = self:getSelectedAnimal()
    if animal == nil then
        Log:trace("RLMenuBuyFrame:onClickBuy: no animal focused")
        return
    end

    local price = RLAnimalBuyService.computeBuyPrice(animal)
    -- Trailer-dealer buys carry no transport fee (legacy AnimalScreenDealerTrailer:getSourcePrice
    -- returns fee 0, and startTrailerBuyFlow dispatches fee 0), so the confirmation is price-only.
    local fee = 0
    if self:getTrailerDealerContext() == nil then
        fee = (animal.getTranportationFee and animal:getTranportationFee(1)) or 0
    end
    local confirmText = RLAnimalBuyService.buildSingleConfirmationText(animal, price, fee)

    Log:debug("RLMenuBuyFrame:onClickBuy: single buy for farmId=%s uniqueId=%s price=%.0f fee=%.0f",
        tostring(animal.farmId), tostring(animal.uniqueId), price, fee)

    self.pendingBuyAnimals = { animal }
    self.pendingBuyPrice = price
    self.pendingBuyFee = fee

    YesNoDialog.show(self.onBuyConfirmed, self, confirmText, g_i18n:getText("ui_attention"))
end


--- Buy all checked dealer animals (same type, enforced by sidebar filtering).
function RLMenuBuyFrame:onClickBuySelected()
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
        Log:trace("RLMenuBuyFrame:onClickBuySelected: no animals checked")
        return
    end

    local totalPrice, totalFee, _, count = RLAnimalBuyService.computeBulkTotal(animals)
    -- Trailer-dealer buys carry no transport fee (legacy parity); the confirmation is price-only.
    if self:getTrailerDealerContext() ~= nil then totalFee = 0 end
    local confirmText = RLAnimalBuyService.buildBulkConfirmationText(count, totalPrice, totalFee)

    Log:debug("RLMenuBuyFrame:onClickBuySelected: bulk buy %d animals, price=%.0f fee=%.0f",
        count, totalPrice, totalFee)

    self.pendingBuyAnimals = animals
    self.pendingBuyPrice = totalPrice
    self.pendingBuyFee = totalFee

    YesNoDialog.show(self.onBuyConfirmed, self, confirmText, g_i18n:getText("ui_attention"))
end


--- YesNoDialog callback for the initial price confirmation.
--- @param clickYes boolean
function RLMenuBuyFrame:onBuyConfirmed(clickYes)
    Log:debug("RLMenuBuyFrame:onBuyConfirmed: clickYes=%s", tostring(clickYes))

    if not clickYes then
        self:clearPendingBuyState()
        return
    end

    if self.pendingBuyAnimals == nil or #self.pendingBuyAnimals == 0 then
        Log:debug("RLMenuBuyFrame:onBuyConfirmed: nil pending animals, aborting")
        self:clearPendingBuyState()
        return
    end

    self:startBuyFlow(self.pendingBuyAnimals, self.pendingBuyPrice or 0, self.pendingBuyFee or 0)
end


--- Resolve the held livestock trailer when the Buy tab is open in MODE_TRAILER + dealer
--- counterpart, else nil. Fail-closed (preserves the trailer-mode safe-default contract): returns
--- the trailer ONLY when g_rlMenu is live, the open mode is MODE_TRAILER, the counterpart is
--- TRAILER_DEALER, and trailerVehicle is a live livestock trailer (the same liveness gate
--- RLMenu.openTrailerFromBridge uses). A torn-down / externally-deleted / non-trailer ref
--- never reaches the raw getNumOfFreeAnimalSlots / getOwnerFarmId reads downstream.
--- @return table|nil trailer The held livestock trailer in trailer-dealer context, or nil
function RLMenuBuyFrame:getTrailerDealerContext()
    if g_rlMenu == nil
        or g_rlMenu.openMode ~= RLMenu.MODE_TRAILER
        or g_rlMenu.trailerCounterpart ~= RLMenu.TRAILER_DEALER then
        Log:trace("RLMenuBuyFrame:getTrailerDealerContext: not trailer-dealer context -> nil")
        return nil
    end

    local trailer = g_rlMenu.trailerVehicle
    if trailer == nil or trailer.spec_livestockTrailer == nil then
        Log:trace("RLMenuBuyFrame:getTrailerDealerContext: trailerVehicle nil or not a livestock trailer -> nil")
        return nil
    end

    Log:trace("RLMenuBuyFrame:getTrailerDealerContext: trailer-dealer context resolved")
    return trailer
end


--- Open the destination picker for the confirmed purchase.
--- EPPs are filtered: AnimalBuyEvent:run dispatches via
--- `self.object:addAnimals(self.animals)`, and RLRM
--- has no `addAnimals(animals)` override for ExtendedProductionPoint - only
--- for PlaceableHusbandryAnimals and LivestockTrailer. Dispatching Buy to an
--- EPP would crash the server. Future enhancement may add EPP support.
--- In trailer-dealer context the trailer IS the destination: route to
--- startTrailerBuyFlow and RETURN before any destination query / dialog.
--- @param animals table Array of cluster objects (same subType)
--- @param price number Positive total buy price (pre-sign-flip)
--- @param fee number Positive total transport fee (pre-sign-flip)
function RLMenuBuyFrame:startBuyFlow(animals, price, fee)
    if animals == nil or #animals == 0 then
        Log:debug("RLMenuBuyFrame:startBuyFlow: no animals")
        return
    end

    -- Trailer-dealer: the trailer is the destination, so skip the destination
    -- dialog and route to the trailer-scoped flow. Absent (FULL/DEALER/husbandry)
    -- the existing destination-dialog path below runs unchanged.
    if self:getTrailerDealerContext() ~= nil then
        Log:debug("RLMenuBuyFrame:startBuyFlow: trailer-dealer context, routing to startTrailerBuyFlow (%d animals)",
            #animals)
        self:startTrailerBuyFlow(animals, price)
        return
    end

    local firstAnimal = animals[1]
    local subTypeIndex = firstAnimal.subTypeIndex
    if subTypeIndex == nil then
        Log:warning("RLMenuBuyFrame:startBuyFlow: first animal has nil subTypeIndex")
        self:clearPendingBuyState()
        return
    end

    local farmId = self.farmId or RLAnimalInfoService.getCurrentFarmId()
    if farmId == nil or farmId == 0 then
        Log:warning("RLMenuBuyFrame:startBuyFlow: invalid farmId=%s", tostring(farmId))
        self:clearPendingBuyState()
        return
    end

    -- Dealer-buy path: nil source. RLAnimalMoveService passes nil through to
    -- the delegate; the `placeable ~= sourceHusbandry` exclusion becomes a
    -- no-op so every farm-owned placeable supporting the subtype is returned.
    local rawEntries = RLAnimalMoveService.getValidDestinations(nil, farmId, subTypeIndex)

    -- EPP filter (see function doc comment for rationale)
    local entries = {}
    for _, entry in ipairs(rawEntries) do
        if entry.isEPP == true then
            Log:trace("RLMenuBuyFrame:startBuyFlow: filtering EPP '%s'",
                tostring(entry.name))
        else
            table.insert(entries, entry)
        end
    end

    if #entries == 0 then
        Log:debug("RLMenuBuyFrame:startBuyFlow: no valid destinations after EPP filter")
        InfoDialog.show(g_i18n:getText("rl_ui_moveNoDestinations"))
        self:clearPendingBuyState()
        return
    end

    Log:debug("RLMenuBuyFrame:startBuyFlow: %d animals, %d destinations (raw=%d), price=%.0f fee=%.0f",
        #animals, #entries, #rawEntries, price, fee)

    self.pendingBuyAnimals = animals
    self.pendingBuyPrice = price
    self.pendingBuyFee = fee

    AnimalMoveDestinationDialog.show(self.onBuyDestinationSelected, self, entries)
end


--- Buy the confirmed batch straight INTO the held trailer (no destination dialog).
--- Mutation parity with legacy AnimalScreenDealerTrailer:applySource/applySourceBulk: the
--- destination is the trailer, the owner farm is trailer:getOwnerFarmId() (NOT self.farmId),
--- the transport fee is 0 (a trailer buy has no transport leg). Runs the cumulative-capacity
--- survivor ledger (RLAnimalBuyService.filterBuyableAnimals); when nothing fits it surfaces the
--- SPECIFIC firstErrorCode (legacy parity) or the generic all-capacity-skip message; otherwise
--- it reuses the shared partial-confirm + dispatch path with the fee forced to 0.
--- @param animals table Array of cluster objects (same subType) the user confirmed
--- @param _price number Positive pre-validation total (unused; price is recomputed for survivors)
function RLMenuBuyFrame:startTrailerBuyFlow(animals, _price)
    local trailer = self:getTrailerDealerContext()
    if trailer == nil then
        Log:warning("RLMenuBuyFrame:startTrailerBuyFlow: trailer context resolved nil, clearing pending state")
        self:clearPendingBuyState()
        return
    end

    local originalCount = (animals ~= nil) and #animals or 0
    local ownerFarmId = trailer:getOwnerFarmId()
    local result = RLAnimalBuyService.filterBuyableAnimals(trailer, animals, ownerFarmId, AnimalBuyEvent.validate)

    local validCount    = #result.valid
    local rejectedCount  = #result.rejected
    local totalCount     = validCount + rejectedCount

    Log:debug("RLMenuBuyFrame:startTrailerBuyFlow: trailer='%s' %d valid, %d rejected (of %d), firstErrorCode=%s",
        tostring(trailer.getName and trailer:getName()),
        validCount, rejectedCount, originalCount, tostring(result.firstErrorCode))

    if validCount == 0 then
        -- Specific error when a validate gate fired (legacy AnimalScreenDealerTrailer parity);
        -- generic message when every animal was a capacity skip.
        if result.firstErrorCode ~= nil then
            InfoDialog.show(RLAnimalBuyService.getErrorText(result.firstErrorCode))
        else
            InfoDialog.show(g_i18n:getText("rl_ui_moveAllRejected"))
        end
        self:clearPendingBuyState()
        return
    end

    if rejectedCount > 0 then
        Log:warning("RLMenuBuyFrame:startTrailerBuyFlow: %d of %d animals skipped (firstErrorCode=%s)",
            rejectedCount, totalCount, tostring(result.firstErrorCode))
    end

    -- Recompute price for the VALID subset (priced through RLAnimalBuyService). A trailer
    -- buy carries NO transport fee: legacy fires AnimalBuyEvent.new(trailer, ..., 0).
    local validPrice = RLAnimalBuyService.computeBulkTotal(result.valid)
    local validFee   = 0

    self.pendingBuyDestination = trailer
    self.pendingBuyAnimals     = result.valid
    self.pendingBuyPrice       = validPrice
    self.pendingBuyFee         = validFee

    -- Selection clearing is DEFERRED to dispatch (no pre-dialog clear): on a successful trailer
    -- buy onBuyComplete re-runs refreshTypes, whose onTypeChanged resets self.selectedAnimals = {}
    -- AFTER the server confirms, so rejected animals never linger; and cancelling the partial-
    -- confirm below preserves the selection (husbandry-path parity). dispatchPendingBuy still
    -- clears the survivors at dispatch as usual.

    if rejectedCount > 0 then
        local text = RLAnimalBuyService.buildPartialConfirmationText(
            validCount, totalCount, result.rejected, validPrice, validFee)
        YesNoDialog.show(self.onBuyPartialConfirmed, self, text, g_i18n:getText("ui_attention"))
        return
    end

    -- Full acceptance: dispatch immediately (reuses the shared dispatch path).
    self:dispatchPendingBuy()
end


--- AnimalMoveDestinationDialog callback.
--- @param entry table|nil Selected destination entry, or nil on cancel
function RLMenuBuyFrame:onBuyDestinationSelected(entry)
    if entry == nil then
        Log:trace("RLMenuBuyFrame:onBuyDestinationSelected: cancelled")
        self:clearPendingBuyState()
        return
    end

    if self.pendingBuyAnimals == nil or #self.pendingBuyAnimals == 0 then
        Log:debug("RLMenuBuyFrame:onBuyDestinationSelected: no pending animals")
        self:clearPendingBuyState()
        return
    end

    Log:trace("RLMenuBuyFrame:onBuyDestinationSelected: dest='%s' (%s/%s)",
        tostring(entry.name), tostring(entry.currentCount), tostring(entry.maxCount))

    local firstAnimal = self.pendingBuyAnimals[1]
    local subType = g_currentMission.animalSystem:getSubTypeByIndex(firstAnimal.subTypeIndex)
    local animalTypeIndex = subType ~= nil and subType.typeIndex or 0

    local result = RLAnimalMoveService.buildMoveValidationResult(
        self.pendingBuyAnimals, entry, animalTypeIndex)

    local validCount    = #result.valid
    local rejectedCount = #result.rejected
    local totalCount    = validCount + rejectedCount

    Log:debug("RLMenuBuyFrame:onBuyDestinationSelected: %d valid, %d rejected (of %d)",
        validCount, rejectedCount, totalCount)

    if validCount == 0 then
        InfoDialog.show(g_i18n:getText("rl_ui_moveAllRejected"))
        self:clearPendingBuyState()
        return
    end

    -- Recompute price + fee for the VALID subset via the service helper
    -- (priced through RLAnimalBuyService.computeBuyPrice).
    local validPrice, validFee = RLAnimalBuyService.computeBulkTotal(result.valid)

    self.pendingBuyDestination = entry.placeable
    self.pendingBuyAnimals = result.valid
    self.pendingBuyPrice = validPrice
    self.pendingBuyFee = validFee

    if rejectedCount > 0 then
        local text = RLAnimalBuyService.buildPartialConfirmationText(
            validCount, totalCount, result.rejected, validPrice, validFee)
        YesNoDialog.show(self.onBuyPartialConfirmed, self, text, g_i18n:getText("ui_attention"))
        return
    end

    -- Full acceptance: dispatch immediately.
    self:dispatchPendingBuy()
end


--- YesNoDialog callback for the partial-rejection confirmation.
--- @param clickYes boolean
function RLMenuBuyFrame:onBuyPartialConfirmed(clickYes)
    Log:debug("RLMenuBuyFrame:onBuyPartialConfirmed: clickYes=%s", tostring(clickYes))
    if not clickYes then
        self:clearPendingBuyState()
        return
    end
    self:dispatchPendingBuy()
end


--- Common dispatch path for both full-acceptance and post-partial-confirm buys.
--- Clears selectedAnimals before dispatching (matches Sell post-dispatch pattern
--- at RLMenuSellFrame:onSellConfirmed).
function RLMenuBuyFrame:dispatchPendingBuy()
    local destination = self.pendingBuyDestination
    local animals     = self.pendingBuyAnimals
    local price       = self.pendingBuyPrice or 0
    local fee         = self.pendingBuyFee or 0

    if destination == nil or animals == nil or #animals == 0 then
        Log:debug("RLMenuBuyFrame:dispatchPendingBuy: nil destination or animals, aborting")
        self:clearPendingBuyState()
        return
    end

    -- In-flight guard: a buy is already awaiting a server reply. Keep the selection +
    -- surface "in progress"; do NOT dispatch a second same-class request.
    if self.buyPending then
        Log:debug("RLMenuBuyFrame:dispatchPendingBuy: a buy is already in flight, ignoring (selection kept)")
        InfoDialog.show(g_i18n:getText("rl_ui_tradeRequestInProgress"))
        return
    end

    Log:debug("RLMenuBuyFrame:dispatchPendingBuy: %d animals to '%s', price=%.0f fee=%.0f",
        #animals, tostring(destination.getName and destination:getName()), price, fee)

    -- Capture the buy list, then clear the pending-buy staging (single-shot).
    self.pendingBuyDestination = nil
    self.pendingBuyAnimals = nil
    self.pendingBuyPrice = nil
    self.pendingBuyFee = nil

    -- Set the in-flight lock BEFORE dispatch (SP fires onBuyComplete synchronously inside
    -- buyAnimals, clearing the lock). Read the service's accept/reject: a false return means
    -- no request is pending - release the lock and KEEP the selection so the player can retry.
    self.buyPending = true
    local accepted = RLAnimalBuyService.buyAnimals(destination, animals, price, fee,
        self.onBuyComplete, self)

    if not accepted then
        self.buyPending = false
        Log:debug("RLMenuBuyFrame:dispatchPendingBuy: dispatch rejected/not-dispatched, keeping selection")
        InfoDialog.show(g_i18n:getText("rl_ui_tradeRequestInProgress"))
        return
    end

    -- Accepted: clear selections (bulk clears all; single removes only the bought animal).
    if #animals > 1 then
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

    -- Re-run the selection-derived refresh AFTER the clear: in SP the completion (onBuyComplete)
    -- already fired synchronously inside buyAnimals and repainted the cart/buttons from the
    -- PRE-clear selection, so recompute them against the now-cleared set. The bought rows were
    -- already dropped by the completion's list reload; only these aggregates were stale.
    self:updateCartDisplay()
    self:updateButtonVisibility()
end


--- Callback from RLAnimalBuyService after the server responds.
--- Stale-frame guard: skips refresh if the frame has closed (tab-switch /
--- menu-close mid-dispatch) OR if the type context was cleared. `isFrameOpen`
--- is set in onFrameOpen and cleared in onFrameClose; `activeAnimalTypeIndex`
--- guards against a type-less state. Either condition means the response
--- arrived too late to safely drive dialogs / list refreshes.
--- Post-buy refresh: reloadAnimalList + updateCartDisplay +
--- RLDetailPaneHelper.updateMoneyDisplay. The pen-info row is permanently hidden
--- by initialize(), so no updateTypeHeader. For the NON-trailer Buy the sidebar
--- types do NOT change - empty types render the empty-animals text. TRAILER-DEALER
--- EXCEPTION: a successful buy into a previously-EMPTY trailer now LOCKS its type,
--- so re-run refreshTypes (which re-applies filterTrailerSupportedTypes) to collapse
--- the sidebar to the locked type; refreshTypes itself reloads list / cart / money,
--- so that branch returns early.
--- @param errorCode number
function RLMenuBuyFrame:onBuyComplete(errorCode)
    -- The dispatched request has completed (reply or watchdog timeout) - always release
    -- the in-flight lock so the frame isn't stranded, even when the refresh is skipped as stale.
    self.buyPending = false

    if not self.isFrameOpen or self.activeAnimalTypeIndex == nil then
        Log:trace("RLMenuBuyFrame:onBuyComplete: stale frame (isFrameOpen=%s typeIndex=%s), ignoring",
            tostring(self.isFrameOpen), tostring(self.activeAnimalTypeIndex))
        return
    end

    if errorCode ~= AnimalBuyEvent.BUY_SUCCESS then
        InfoDialog.show(RLAnimalBuyService.getErrorText(errorCode))
        Log:debug("RLMenuBuyFrame:onBuyComplete: buy failed, errorCode=%s", tostring(errorCode))
    else
        Log:info("RLMenuBuyFrame:onBuyComplete: buy succeeded")
        if self:getTrailerDealerContext() ~= nil then
            Log:debug("RLMenuBuyFrame:onBuyComplete: trailer-dealer success, re-locking sidebar to current type")
            self:refreshTypes()
            return
        end
    end

    self:reloadAnimalList()
    self:updateCartDisplay()
    RLDetailPaneHelper.updateMoneyDisplay(self)
end


--- Clear all pending buy-flow state (cancel, error, or after dispatch).
function RLMenuBuyFrame:clearPendingBuyState()
    self.pendingBuyAnimals = nil
    self.pendingBuyPrice = nil
    self.pendingBuyFee = nil
    self.pendingBuyDestination = nil
end


-- =============================================================================
-- Cart
-- =============================================================================

--- Compute cart totals from checked animals.
--- Iterates visible items (O(V)) and skips orphan keys silently after restock.
--- Sign convention: getTranportationFee(1) returns positive; for Buy the fee is
--- additive (player pays it on top of price), opposite of Sell which negates it.
--- @return number totalPrice Sum of RLAnimalBuyService.computeBuyPrice for checked animals
--- @return number totalFee Sum of getTranportationFee(1) for checked animals (positive cost)
--- @return number count Number of checked animals
function RLMenuBuyFrame:computeCartTotals()
    local totalPrice = 0
    local totalFee = 0
    local count = 0
    -- Trailer-dealer buys carry no transport fee (legacy parity); the cart total is price-only.
    local includeFee = self:getTrailerDealerContext() == nil

    for _, sectionKey in ipairs(self.sectionOrder) do
        local items = self.itemsBySection[sectionKey]
        if items ~= nil then
            for _, item in ipairs(items) do
                if item.cluster ~= nil then
                    local cluster = item.cluster
                    local identityKey = RLSelectionKey.build(cluster.farmId, cluster.uniqueId,
                        cluster.birthday and cluster.birthday.country)
                    if identityKey ~= nil and self.selectedAnimals[identityKey] then
                        -- Priced through the buy service, which is the SAME call
                        -- dispatchPendingBuy hands to AnimalBuyEvent - so the cart
                        -- total and the charged amount cannot disagree.
                        totalPrice = totalPrice + RLAnimalBuyService.computeBuyPrice(cluster)
                        if includeFee then
                            totalFee = totalFee + (cluster:getTranportationFee(1) or 0)
                        end
                        count = count + 1
                    end
                end
            end
        end
    end

    Log:trace("RLMenuBuyFrame:computeCartTotals: count=%d price=%.0f fee=%.0f total=%.0f",
        count, totalPrice, totalFee, totalPrice + totalFee)
    return totalPrice, totalFee, count
end


--- Update the cart display elements with current totals. Buy adds fee to
--- price (player pays both), opposite of Sell which subtracts.
function RLMenuBuyFrame:updateCartDisplay()
    local totalPrice, totalFee, count = self:computeCartTotals()

    if self.cartCountValue ~= nil then
        self.cartCountValue:setText(tostring(count))
    end
    if self.cartPriceValue ~= nil then
        self.cartPriceValue:setText(g_i18n:formatMoney(totalPrice, 0, true, true))
    end
    if self.cartFeeValue ~= nil then
        self.cartFeeValue:setText(g_i18n:formatMoney(totalFee, 0, true, true))
    end
    if self.cartTotalValue ~= nil then
        self.cartTotalValue:setText(g_i18n:formatMoney(totalPrice + totalFee, 0, true, true))
    end

    if self.cartLayout ~= nil and self.cartLayout.invalidateLayout ~= nil then
        self.cartLayout:invalidateLayout()
    end

    Log:trace("RLMenuBuyFrame:updateCartDisplay: %d selected, price=%s fee=%s total=%s",
        count,
        g_i18n:formatMoney(totalPrice, 0, true, true),
        g_i18n:formatMoney(totalFee, 0, true, true),
        g_i18n:formatMoney(totalPrice + totalFee, 0, true, true))
end


-- =============================================================================
-- Checkbox / multi-select
-- =============================================================================

--- Toggle the focused animal's checkbox.
function RLMenuBuyFrame:onClickSelect()
    if not self.isFrameOpen then
        Log:trace("RLMenuBuyFrame:onClickSelect: frame closed, ignoring")
        return
    end
    local animal = self:getSelectedAnimal()
    if animal == nil then
        Log:trace("RLMenuBuyFrame:onClickSelect: no animal focused")
        return
    end

    local key = RLSelectionKey.build(animal.farmId, animal.uniqueId,
        animal.birthday and animal.birthday.country)
    if key == nil then
        Log:trace("RLMenuBuyFrame:onClickSelect: nil selection key, skipping")
        return
    end
    self.selectedAnimals[key] = not self.selectedAnimals[key]
    Log:trace("RLMenuBuyFrame:onClickSelect: key=%s -> %s", key, tostring(self.selectedAnimals[key]))

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
function RLMenuBuyFrame:onClickSelectAll()
    if not self.isFrameOpen then
        Log:trace("RLMenuBuyFrame:onClickSelectAll: frame closed, ignoring")
        return
    end
    local hasSelection = self:getSelectedCount() > 0

    if hasSelection then
        -- Deselect all
        self.selectedAnimals = {}
        Log:debug("RLMenuBuyFrame:onClickSelectAll: deselected all")
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
                            Log:trace("RLMenuBuyFrame:onClickSelectAll: nil key for a cluster, skipping")
                        end
                    end
                end
            end
        end
        Log:debug("RLMenuBuyFrame:onClickSelectAll: selected all (%d)", self:getSelectedCount())
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

--- Open AnimalFilterDialog for the current type's sale animals.
--- Source list is built from the dealer pool MINUS the Quick filter so
--- slider ranges always reflect the full dealer pool (or saved-filter-
--- narrowed pool), never the already-Quick-filtered subset.
--- isBuyMode=true so the Value slider applies the active buy-markup matching
--- AnimalFilterDialog.applyFilters.
function RLMenuBuyFrame:onClickFilter()
    if self.activeAnimalTypeIndex == nil then return end
    if AnimalFilterDialog == nil or AnimalFilterDialog.show == nil then
        Log:warning("RLMenuBuyFrame:onClickFilter: AnimalFilterDialog unavailable")
        return
    end

    local base, narrowed = self:buildDialogSourceList()
    Log:debug("RLMenuBuyFrame:onClickFilter: opening dialog (savedFilterId=%s, base=%d, narrowed=%d, animalTypeIndex=%s)",
        tostring(self.activeFilterId), #base, #narrowed, tostring(self.activeAnimalTypeIndex))

    -- allowSave=true + sourceUsage=DEALER: this frame views the dealer pool, so
    -- saved filters land in the DEALER cycle bucket (Buy only). User can flip to
    -- ANY in the Settings editor that opens post-Save.
    AnimalFilterDialog.show(narrowed, self.activeAnimalTypeIndex, self.onFilterApplied, self, true, true, RLFilterUsage.DEALER)
end


--- AnimalFilterDialog callback. Stores filters, clears selections, and re-queries.
--- @param filters table
--- @param _items table unused
function RLMenuBuyFrame:onFilterApplied(filters, _items)
    Log:debug("RLMenuBuyFrame:onFilterApplied: clearing selections + applying filters")
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
function RLMenuBuyFrame:getNumberOfSections(list)
    if list == self.animalList then return #self.sectionOrder end
    return 0
end

--- @param list table
--- @param section number
--- @return string|nil
function RLMenuBuyFrame:getTitleForSectionHeader(list, section)
    if list ~= self.animalList then return nil end
    local key = self.sectionOrder[section]
    return key and self.titlesBySection[key] or nil
end

--- @param list table
--- @param section number
--- @return number
function RLMenuBuyFrame:getNumberOfItemsInSection(list, section)
    if list ~= self.animalList then return 0 end
    local key = self.sectionOrder[section]
    if key == nil then return 0 end
    local items = self.itemsBySection[key]
    return items ~= nil and #items or 0
end

--- Populate one data cell. Mirrors Sell's populateCellForItemInSection.
--- The inherited `price` cell shows the dealer-marked-up buy price; the
--- inline checkbox callback toggles selectedAnimals and updates the cart
--- totals. The markup math lives in RLAnimalBuyService.computeBuyPrice - this
--- cell calls it rather than multiplying inline, so the row price, the cart
--- total and the amount AnimalBuyEvent charges all come from one place.
--- Deliberately NO log line here: this runs per row per refresh. The
--- once-per-population TRACE digest at the end of reloadAnimalList carries it.
--- @param list table
--- @param section number
--- @param index number
--- @param cell table
function RLMenuBuyFrame:populateCellForItemInSection(list, section, index, cell)
    if list ~= self.animalList then return end

    local key = self.sectionOrder[section]
    if key == nil then return end
    local items = self.itemsBySection[key]
    if items == nil then return end
    local item = items[index]
    if item == nil then return end

    local row = RLAnimalQuery.formatAnimalRow(item)

    -- Cell tint
    if cell.setImageColor ~= nil then
        if row.tint == RLAnimalQuery.TINT_DISEASE then
            cell:setImageColor(GuiOverlay.STATE_NORMAL, 1, 0.08, 0)
        elseif row.tint == RLAnimalQuery.TINT_MARKED then
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

    -- Populate inherited `price` cell with the dealer-marked-up buy price,
    -- resolved through the buy service so the row, the cart total and the
    -- charged amount all come from one call.
    local priceCell = cell:getAttribute("price")
    if priceCell ~= nil and item.cluster ~= nil then
        local buyPrice = RLAnimalBuyService.computeBuyPrice(item.cluster)
        if priceCell.setValue ~= nil then
            priceCell:setValue(buyPrice)
        else
            priceCell:setText(g_i18n:formatMoney(buyPrice, 0, true, true))
        end
    end

    local descriptor = cell:getAttribute("herdsmanPurchase")
    if descriptor ~= nil then
        descriptor:setVisible(row.descriptorVisible)
        if row.descriptorVisible then
            descriptor:setText(row.descriptorText)
        end
    end

    -- Status icons: resolve from row state, right-justify into slots 4..1.
    local icons = RLAnimalQuery.resolveStatusIcons(row)
    local SLOT_NAMES = { "statusIcon1", "statusIcon2", "statusIcon3", "statusIcon4" }
    local slotCount = #SLOT_NAMES
    for i = 1, slotCount do
        local slot = cell:getAttribute(SLOT_NAMES[i])
        if slot ~= nil then
            local iconIndex = i - (slotCount - #icons)
            local def = icons[iconIndex]
            if def ~= nil then
                slot:setImageSlice(GuiOverlay.STATE_NORMAL, def.slice)
                slot:setImageSlice(GuiOverlay.STATE_SELECTED, def.slice)
                slot:setImageSlice(GuiOverlay.STATE_HIGHLIGHTED, def.slice)
                slot:setImageColor(GuiOverlay.STATE_NORMAL, def.r, def.g, def.b)
                slot:setImageColor(GuiOverlay.STATE_SELECTED, 0.015, 0.017, 0.015)
                slot:setImageColor(GuiOverlay.STATE_HIGHLIGHTED, 0.015, 0.017, 0.015)
                slot:setVisible(true)
            else
                slot:setVisible(false)
            end
        end
    end

    -- Checkbox: show check mark + wire onClick callback for direct clicking.
    -- Toggles local selectedAnimals state and recalculates cart totals so a
    -- direct mouse click updates the cart on the same click (no need to
    -- also fire onClickSelect).
    local checkbox = cell:getAttribute("checkbox")
    local check = cell:getAttribute("check")
    if checkbox ~= nil then
        checkbox:setVisible(true)
        if check ~= nil then
            local identityKey = RLSelectionKey.build(row.farmId, row.uniqueId, row.country)
            check:setVisible(identityKey ~= nil and self.selectedAnimals[identityKey] == true)

            checkbox.onClickCallback = function()
                if not self.isFrameOpen then
                    Log:trace("RLMenuBuyFrame checkbox click: frame closed, ignoring")
                    return
                end
                if identityKey == nil then
                    Log:trace("RLMenuBuyFrame checkbox click: nil selection key, skipping")
                    return
                end
                self.selectedAnimals[identityKey] = not self.selectedAnimals[identityKey]
                check:setVisible(self.selectedAnimals[identityKey] == true)
                self:updateButtonVisibility()
                self:updateCartDisplay()
                Log:trace("RLMenuBuyFrame checkbox click: key=%s -> %s",
                    identityKey, tostring(self.selectedAnimals[identityKey]))
            end
        end
    end
end

-- =============================================================================
-- Saved-filter cycle + chip
-- =============================================================================

--- Buy-frame variant: animalType comes from the dealer type selector
--- (self.activeAnimalTypeIndex) rather than a selected husbandry.
function RLMenuBuyFrame:onCycleFilter()
    if self.farmId == nil or self.farmId == 0 then
        Log:trace("RLMenuBuyFrame:onCycleFilter: no farm, aborting")
        return
    end

    local filters = RLFilterCycleHelper.getAvailableFilters(self.activeAnimalTypeIndex, self.farmId, RLFilterCycleHelper.USAGE.DEALER)
    if #filters == 0 then
        if self.activeFilterId ~= nil then
            self.activeFilterId = nil
            self.activeFilter = nil
        end
        Log:trace("RLMenuBuyFrame:onCycleFilter: no filters available, chip reset")
        self:updateFilterChip()
        self:reloadAnimalList()
        return
    end

    local nextId = RLFilterCycleHelper.cycleFilterId(self.activeFilterId, filters)
    local prevId = self.activeFilterId
    self.activeFilterId = nextId
    self.activeFilter = (nextId ~= nil and g_rlFilterService ~= nil
        and g_rlFilterService:getById(nextId)) or nil

    Log:debug("RLMenuBuyFrame:onCycleFilter: from=%s to=%s (count=%d)",
        tostring(prevId), tostring(nextId), #filters)

    self:updateFilterChip()
    self:reloadAnimalList()
end

--- Render the filterChip Text element to reflect the combined Quick filter
--- + saved filter state. Delegates branch resolution to the
--- shared RLFilterChipHelper so all four RL Menu frames render consistently.
--- No-op + WARNING if the XML element is missing.
function RLMenuBuyFrame:updateFilterChip()
    local chip = self.filterChip
    if chip == nil then
        Log:warning("RLMenuBuyFrame:updateFilterChip: filterChip element missing from XML")
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
    Log:trace("RLMenuBuyFrame:updateFilterChip: branch=%s saved=%s",
        branch, tostring(s.savedName))

    if chip.absPosition ~= nil and chip.size ~= nil then
        Log:debug("RLMenuBuyFrame:updateFilterChip: absPos=(%.0f,%.0f)px size=(%.0f,%.0f)px",
            chip.absPosition[1] * 1920, chip.absPosition[2] * 1080,
            (chip.size[1] or 0) * 1920, (chip.size[2] or 0) * 1080)
    end
end

function RLMenuBuyFrame:revalidateActiveFilter()
    if self.activeFilterId == nil then return end

    if self.farmId == nil or self.farmId == 0 then
        self.activeFilterId = nil
        self.activeFilter = nil
        Log:debug("RLMenuBuyFrame:revalidateActiveFilter: no farm, cleared")
        return
    end

    local available = RLFilterCycleHelper.getAvailableFilters(self.activeAnimalTypeIndex, self.farmId, RLFilterCycleHelper.USAGE.DEALER)
    local stillInScope = false
    for _, f in ipairs(available) do
        if f.id == self.activeFilterId then
            stillInScope = true
            break
        end
    end

    if not stillInScope then
        Log:debug("RLMenuBuyFrame:revalidateActiveFilter: id=%s out of scope, cleared",
            tostring(self.activeFilterId))
        self.activeFilterId = nil
        self.activeFilter = nil
    else
        if g_rlFilterService ~= nil then
            self.activeFilter = g_rlFilterService:getById(self.activeFilterId)
        end
        Log:trace("RLMenuBuyFrame:revalidateActiveFilter: id=%s still in scope, snapshot refreshed",
            tostring(self.activeFilterId))
    end
end

--- Remote-change fanout hook fired from RLFilter{Create,Update,Delete}Event:run
--- when a peer mutates a saved filter. Id-match gate short-circuits when the
--- changed filter is not this frame's active filter, preserving user selection
--- and detail-pane state. Otherwise re-runs revalidateActiveFilter +
--- updateFilterChip + reloadAnimalList so the displayed list reflects the
--- new active-filter state. BuyFrame is the isolated island in Cycle-A's
--- shared-selection model (dealer context); it does NOT clear
--- g_rlMenu.sharedSelection.activeFilterId on active-cleared.
---@param filterId string  -- id of the filter that was created/updated/deleted on the network
---@param changeType string  -- "create" | "update" | "delete"
function RLMenuBuyFrame:onRemoteFilterChange(filterId, changeType)
    Log:trace("RLMenuBuyFrame:onRemoteFilterChange: id=%s change=%s activeId=%s isFrameOpen=%s",
        tostring(filterId), tostring(changeType), tostring(self.activeFilterId), tostring(self.isFrameOpen))

    if self.isFrameOpen ~= true then
        Log:trace("RLMenuBuyFrame:onRemoteFilterChange: frame not open, deferring to onFrameOpen")
        return
    end

    if filterId ~= self.activeFilterId then
        Log:trace("RLMenuBuyFrame:onRemoteFilterChange: no-op (non-active change)")
        return
    end

    self:revalidateActiveFilter()
    self:updateFilterChip()
    self:reloadAnimalList()

    if self.activeFilter == nil then
        Log:debug("RLMenuBuyFrame:onRemoteFilterChange: active filter cleared (delete or scope-narrow)")
    else
        Log:debug("RLMenuBuyFrame:onRemoteFilterChange: active filter snapshot refreshed")
    end
end
