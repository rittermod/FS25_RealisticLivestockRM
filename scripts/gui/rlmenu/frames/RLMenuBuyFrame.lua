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

    -- In-flight UI lock for a dispatched buy, reset on frame open so a stranded lock heals.
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


--- Bind the SmoothList datasource and delegate. Fires on both the original and the clone,
--- so tree mutation lives in initialize().
function RLMenuBuyFrame:onGuiSetupFinished()
    RLMenuBuyFrame:superClass().onGuiSetupFinished(self)

    if self.animalList ~= nil then
        self.animalList:setDataSource(self)
        self.animalList:setDelegate(self)
    else
        Log:warning("RLMenuBuyFrame:onGuiSetupFinished: animalList element missing from XML")
    end
end


--- One-time per-clone setup: unlink the dot template so it can be cloned at runtime, and
--- hide the inherited pen-info row, which has no meaning on the dealer side.
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

    -- MONEY_CHANGED keeps the header balance current when an MP balance update arrives
    -- asynchronously; in SP the change is synchronous and this is inert.
    g_messageCenter:subscribe(MessageType.MONEY_CHANGED, self.onMoneyChanged, self)

    -- Explicit focus links: several frames share this sidebar and list structure, so
    -- FocusManager auto-layout can otherwise resolve into another frame's elements.
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

    -- Quick filter is per-frame session state, so a sibling tab opens clean.
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


--- MONEY_CHANGED handler. Clients publish it locally once the balance arrives from the
--- server, so the header refreshes in MP without polling.
function RLMenuBuyFrame:onMoneyChanged()
    if not self.isFrameOpen then return end
    Log:trace("RLMenuBuyFrame:onMoneyChanged: refreshing money display")
    RLDetailPaneHelper.updateMoneyDisplay(self)
end


-- =============================================================================
-- Dealer type selector
-- =============================================================================

--- Repopulate the type selector and dot indicators. Every registered type is shown, not
--- only stocked ones, so the sidebar layout stays stable across restocks.
function RLMenuBuyFrame:refreshTypes()
    local farmId = RLAnimalInfoService.getCurrentFarmId()
    self.farmId = farmId

    self.sortedTypes = RLDealerQuery.listDealerTypes()
    Log:debug("RLMenuBuyFrame:refreshTypes: farmId=%s types=%d",
        tostring(farmId), #self.sortedTypes)

    -- Trailer-dealer: scope the sidebar to trailer-supported types, locked to the current
    -- type once the trailer is non-empty. A non-trailer Buy keeps every registered type.
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

--- The Quick filter dialog's source list: reloadAnimalList's universe MINUS the Quick
--- filter, so the slider ranges see the full pool rather than the filtered subset.
---@return table base   full dealer-pool universe for active animal type
---@return table narrowed base after saved-filter layer (== base when none)
function RLMenuBuyFrame:buildDialogSourceList()
    if self.activeAnimalTypeIndex == nil then return {}, {} end
    local base = RLDealerQuery.listDealerAnimalsForType(self.activeAnimalTypeIndex)
    local narrowed = RLFilterCycleHelper.applyFilter(base, self.activeFilter)
    return base, narrowed
end


--- Refresh only when the frame is open, so a wholesale dealer-pool replacement rebinds the
--- list instead of leaving it holding items that no longer exist.
function RLMenuBuyFrame:refreshIfOpen()
    if self.isFrameOpen then
        Log:debug("RLMenuBuyFrame:refreshIfOpen: refreshing")
        self:reloadAnimalList()
    else
        Log:debug("RLMenuBuyFrame:refreshIfOpen: frame closed, skipping")
    end
end


--- Requery dealer stock for the active type, section it, and restore selection by identity.
--- DELIBERATELY does not clear the pendingBuy trio, even though this can run under the
--- confirmation dialog: a pending buy is a RESERVATION, and a restock replaces the shelf,
--- not the cart. Clearing it here would cancel a confirmed purchase out from under the player.
function RLMenuBuyFrame:reloadAnimalList()
    Log:trace("RLMenuBuyFrame:reloadAnimalList: begin")
    self:captureCurrentSelection()

    if self.activeAnimalTypeIndex == nil then
        self.items = {}
    else
        self.items = RLDealerQuery.listDealerAnimalsForType(self.activeAnimalTypeIndex)

        if self.filters ~= nil and next(self.filters) ~= nil
            and AnimalFilterDialog ~= nil and AnimalFilterDialog.applyFilters ~= nil then
            -- Buy-mode, matching the dialog-open path, so Value is evaluated with the
            -- active dealer markup rather than the raw sell price.
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

    -- ONE digest per population, never per row: it carries the active preset, the resolved
    -- markup and the per-row prices, so they can be predicted offline and asserted against
    -- a log line. Level-guarded because the digest is built eagerly.
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


--- Rebuild the footer buttons. Buy needs a focused animal, Buy Selected at least one
--- checked; both need the tradeAnimals permission, which the server also enforces.
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
    -- A trailer-dealer buy has no transport leg, so its confirmation is price-only.
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


--- The held livestock trailer in trailer-dealer context, else nil. Fail-closed, so a torn
--- down or non-trailer reference never reaches the raw capacity reads downstream.
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


--- Open the destination picker for the confirmed purchase. EPPs are filtered out: there is
--- no addAnimals override for ExtendedProductionPoint, so dispatching a Buy to one would
--- crash the server. In trailer-dealer context the trailer IS the destination.
--- @param animals table Array of cluster objects (same subType)
--- @param price number Positive total buy price (pre-sign-flip)
--- @param fee number Positive total transport fee (pre-sign-flip)
function RLMenuBuyFrame:startBuyFlow(animals, price, fee)
    if animals == nil or #animals == 0 then
        Log:debug("RLMenuBuyFrame:startBuyFlow: no animals")
        return
    end

    -- The trailer is the destination, so skip the dialog entirely.
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

    -- A nil source makes the source-exclusion a no-op, so every farm-owned placeable
    -- supporting the subtype is returned.
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


--- Buy the confirmed batch straight into the held trailer. The owner farm is the TRAILER's,
--- not self.farmId, and the transport fee is 0. When nothing fits it surfaces the specific
--- first error code, else the generic all-skipped message.
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
        -- Specific error when a validate gate fired; generic on a pure capacity skip.
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

    -- Reprice for the VALID subset only; a trailer buy carries no transport fee.
    local validPrice = RLAnimalBuyService.computeBulkTotal(result.valid)
    local validFee   = 0

    self.pendingBuyDestination = trailer
    self.pendingBuyAnimals     = result.valid
    self.pendingBuyPrice       = validPrice
    self.pendingBuyFee         = validFee

    -- Selection clearing is DEFERRED to dispatch, so cancelling the partial confirm below
    -- preserves the selection.

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

    -- Reprice for the VALID subset only.
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


--- Common dispatch path for full-acceptance and post-partial-confirm buys alike.
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

    -- A buy is already awaiting a server reply: keep the selection, dispatch nothing.
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

    -- Lock BEFORE dispatch: in SP the completion fires synchronously inside buyAnimals. A
    -- false return means nothing is pending, so release and keep the selection for a retry.
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

    -- Recompute AFTER the clear: in SP the completion already repainted these from the
    -- PRE-clear selection, leaving the aggregates stale.
    self:updateCartDisplay()
    self:updateButtonVisibility()
end


--- Post-response callback. A closed frame or a cleared type means the reply arrived too
--- late to drive dialogs safely, so the refresh is skipped. Trailer-dealer exception: a buy
--- into a previously empty trailer LOCKS its type, so the sidebar has to be rebuilt.
--- @param errorCode number
function RLMenuBuyFrame:onBuyComplete(errorCode)
    -- Always release the lock, even when the refresh below is skipped as stale.
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

--- Cart totals from the checked animals. The transport fee is ADDITIVE here - the player
--- pays it on top of the price - the opposite sign to Sell.
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
                        -- The SAME call dispatch hands to the event, so the cart total
                        -- and the charged amount cannot disagree.
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


--- Update the cart display: Buy ADDS the fee to the price, where Sell subtracts it.
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

    -- Reload to re-render the checkmarks. Do NOT restoreSelection: SmoothList already
    -- preserves focus across reloadData, and it would reset the highlight to (1,1).
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

--- Open the Quick filter dialog. The source list excludes the Quick filter, so the slider
--- ranges reflect the full pool; buy-mode makes the Value slider apply the buy markup.
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

--- Populate one data cell. The price comes from the buy service rather than an inline
--- multiply, so the row, the cart and the charged amount share one source. Deliberately
--- UNLOGGED: this runs per row per refresh, and reloadAnimalList carries the digest.
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

    -- Status icons: one right-justified row carrying disease, pregnancy/fertility
    -- and production. The slot names, the ordering and the per-state styling all
    -- live in RLAnimalQuery so the five list frames cannot drift apart.
    RLAnimalQuery.applyStatusIconSlots(cell, RLAnimalQuery.SLOT_NAMES,
        RLAnimalQuery.resolveStatusIcons(row))

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

--- Remote-change hook for a peer mutating a saved filter. The id-match gate short-circuits
--- for any filter but this frame's active one, preserving the selection and detail pane.
--- This frame's selection is isolated, so it never clears the shared active filter id.
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
