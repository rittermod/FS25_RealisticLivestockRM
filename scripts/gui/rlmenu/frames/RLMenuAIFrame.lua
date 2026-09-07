--[[
    RLMenuAIFrame.lua
    RL Tabbed Menu - AI (Artificial Insemination) tab.

    A top-of-column species cycler with dot indicators, a multi-section SmoothList of
    AI-stock bull cards, a middle `aiPurchasePanel` (Average Success + Quantity + stepper +
    total price), and a right-hand detail pane reusing RLDetailPaneHelper (bulls have no
    husbandry). The cell's "price" slot carries the overall-QUALITY label, not a money
    amount - legacy parity.

    Footer wiring: the quantity stepper recomputes the total price, the Favourite toggle is
    local with no network event, and Buy dispatches SemenBuyEvent then spawns via
    PlacementUtil. AI bulls are not farm-owned, so selection is isolated from sharedSelection.
]]

RLMenuAIFrame = {}
local RLMenuAIFrame_mt = Class(RLMenuAIFrame, TabbedMenuFrameElement)

local Log = RmLogging.getLogger("RLRM")

local modDirectory = g_currentModDirectory


--- Construct a new RLMenuAIFrame instance.
--- @return table self
function RLMenuAIFrame.new()
    local self = RLMenuAIFrame:superClass().new(nil, RLMenuAIFrame_mt)
    self.name = "RLMenuAIFrame"

    self.sortedSpecies        = {}    -- array of animal type entries from animalSystem:getTypes
    self.items                = {}    -- wrapped AI bulls for the active species
    self.farmId               = nil   -- set per-onFrameOpen via refreshSpecies; consumed by RLDetailPaneHelper.updateMoneyDisplay

    self.sectionOrder         = {}
    self.itemsBySection       = {}
    self.titlesBySection      = {}

    self.selectedIdentity     = nil   -- { farmId, uniqueId, country } for focused bull
    self.isFrameOpen          = false
    self.hasCustomMenuButtons = true

    self.activeSpeciesTypeIndex = nil

    -- Dedupe cache: a re-selection of the same bull early-returns, so a spurious
    -- selection re-fire cannot reset the stepper and the price. The key carries the
    -- species index too, so a cross-species id collision does not suppress a render.
    self.lastSelectedBullIdentity = nil

    -- Reentrancy flag for Buy: without it a rapid second Enter double-dispatches the
    -- event and double-consumes spawn slots while the modal dialog is pending.
    self.buyInFlight = false

    -- Back button (always present, required with hasCustomMenuButtons)
    self.backButtonInfo = { inputAction = InputAction.MENU_BACK }

    -- Action bar button definitions. Buttons are enabled when a bull is
    -- focused; the gating mirrors the legacy AI screen's selection-only check
    -- (see RealisticLivestock_AnimalScreen:onAIListSelectionChanged).
    self.favouriteButtonInfo = {
        inputAction = InputAction.MENU_EXTRA_1,
        text = g_i18n:getText("rl_ui_favourite"),
        callback = function() self:onClickFavourite() end,
    }
    self.buyButtonInfo = {
        inputAction = InputAction.MENU_ACCEPT,
        text = g_i18n:getText("button_buy"),
        callback = function() self:onClickBuy() end,
    }
    self.menuButtonInfo = { self.backButtonInfo }

    return self
end


--- Load the AI frame XML and register it with g_gui.
function RLMenuAIFrame.setupGui()
    local frame = RLMenuAIFrame.new()
    g_gui:loadGui(
        Utils.getFilename("gui/rlmenu/aiFrame.xml", modDirectory),
        "RLMenuAIFrame",
        frame,
        true
    )
    Log:debug("RLMenuAIFrame.setupGui: registered")
end


--- Bind the SmoothList datasource/delegate. Fires on both the initial load
--- instance and the FrameReference clone; tree mutation lives in initialize().
function RLMenuAIFrame:onGuiSetupFinished()
    RLMenuAIFrame:superClass().onGuiSetupFinished(self)

    if self.animalList ~= nil then
        self.animalList:setDataSource(self)
        self.animalList:setDelegate(self)
    else
        Log:warning("RLMenuAIFrame:onGuiSetupFinished: animalList element missing from XML")
    end
end


--- One-time per-clone setup: unlink the dot template so it can be cloned, hide the
--- inherited pen-info elements, seed the quantity stepper, and hide the purchase panel.
function RLMenuAIFrame:initialize()
    if self.subCategoryDotTemplate ~= nil then
        self.subCategoryDotTemplate:unlinkElement()
        FocusManager:removeElement(self.subCategoryDotTemplate)
    else
        Log:warning("RLMenuAIFrame:initialize: subCategoryDotTemplate missing")
    end

    -- Hide inherited pen-info row (AI has no pen concept)
    if self.penInformationHeader ~= nil then self.penInformationHeader:setVisible(false) end
    if self.penNameText         ~= nil then self.penNameText:setVisible(false) end
    if self.penCountText        ~= nil then self.penCountText:setVisible(false) end
    if self.penIcon             ~= nil then self.penIcon:setVisible(false) end

    -- Populate quantity stepper labels from RLConstants.DEWAR_QUANTITIES.
    -- State resets to 1 here so a fresh frame open shows "1 Straw" regardless
    -- of the last value left in the element.
    if self.aiQuantitySelector ~= nil
        and RLConstants ~= nil
        and RLConstants.DEWAR_QUANTITIES ~= nil then
        local texts = {}
        for _, quantity in pairs(RLConstants.DEWAR_QUANTITIES) do
            table.insert(texts, string.format("%s %s",
                quantity,
                g_i18n:getText("rl_ui_straw" .. (quantity == 1 and "Single" or "Multiple"))))
        end
        self.aiQuantitySelector:setTexts(texts)
        self.aiQuantitySelector:setState(1)
    else
        Log:warning("RLMenuAIFrame:initialize: aiQuantitySelector or DEWAR_QUANTITIES unavailable")
    end

    -- Middle column hidden until a bull is selected (mirrors the legacy
    -- aiInfoContainer hide-until-selection behaviour).
    if self.aiPurchasePanel ~= nil then
        self.aiPurchasePanel:setVisible(false)
    end

    Log:debug("RLMenuAIFrame:initialize: template unlinked, pen-info hidden, quantity stepper seeded, aiPurchasePanel hidden")
end


-- =============================================================================
-- Lifecycle
-- =============================================================================

--- Called by the Paging element when this tab becomes active.
--- Isolated selection - does NOT import or export g_rlMenu.sharedSelection.
function RLMenuAIFrame:onFrameOpen()
    RLMenuAIFrame:superClass().onFrameOpen(self)
    self.isFrameOpen = true
    -- Clear selection-identity dedupe cache so the first onBullSelectionChanged
    -- after a fresh open always renders (no stale cache from previous session).
    self.lastSelectedBullIdentity = nil
    -- Belt-and-suspenders clear of the Buy reentrancy flag. The callback path
    -- normally clears it, but a stale-frame guard in onPostSemenBuy can skip
    -- the clear; resetting here guarantees Buy is usable on every frame open.
    self.buyInFlight = false
    Log:debug("RLMenuAIFrame:onFrameOpen")

    self:refreshSpecies()

    -- Subscribe to MONEY_CHANGED so the header balance refreshes when an
    -- MP balance update arrives asynchronously. Matches the pattern Buy/Sell/
    -- Info use.
    g_messageCenter:subscribe(MessageType.MONEY_CHANGED, self.onMoneyChanged, self)

    -- Explicit focus links. Without these, FocusManager auto-layout can
    -- trap focus in other frames' cloned elements (multiple frames share
    -- the same sidebar + SmoothList structure).
    if self.subCategorySelector ~= nil and self.animalList ~= nil then
        FocusManager:linkElements(self.subCategorySelector, FocusManager.BOTTOM, self.animalList)
        FocusManager:linkElements(self.animalList, FocusManager.TOP, self.subCategorySelector)
    end
    if self.animalList ~= nil then
        FocusManager:setFocus(self.animalList)
    end
end


--- Called by the Paging element when this tab is deactivated.
function RLMenuAIFrame:onFrameClose()
    Log:debug("RLMenuAIFrame:onFrameClose")
    g_messageCenter:unsubscribe(MessageType.MONEY_CHANGED, self)
    RLMenuAIFrame:superClass().onFrameClose(self)
    self.isFrameOpen = false
end


--- MessageType.MONEY_CHANGED handler. Fires on both server and client
--- contexts; subscribing lets the AI frame refresh its header balance in MP
--- without polling. Delegates to RLDetailPaneHelper for the actual update.
function RLMenuAIFrame:onMoneyChanged()
    if not self.isFrameOpen then return end
    Log:trace("RLMenuAIFrame:onMoneyChanged: refreshing money display")
    RLDetailPaneHelper.updateMoneyDisplay(self)
end


-- =============================================================================
-- Species cycler
-- =============================================================================

--- Repopulate the species cycler + dot indicators from RLAIStockService.
--- Shows every registered species, not only species with stock (species with
--- zero stock render the empty-animals text).
function RLMenuAIFrame:refreshSpecies()
    -- Cache the farm id for the money display: without it the helper sees a nil farmId,
    -- resolves a nil balance, and hides the money box entirely.
    self.farmId = RLAnimalInfoService.getCurrentFarmId()

    self.sortedSpecies = RLAIStockService.listSpecies()
    Log:debug("RLMenuAIFrame:refreshSpecies: farmId=%s species=%d",
        tostring(self.farmId), #self.sortedSpecies)

    -- Clean out any previously-cloned dots (onFrameOpen may be called multiple
    -- times in a session; without cleanup dots accumulate).
    if self.subCategoryDotBox ~= nil then
        for i, dot in pairs(self.subCategoryDotBox.elements) do
            dot:delete()
            self.subCategoryDotBox.elements[i] = nil
        end
    end

    if #self.sortedSpecies == 0 then
        Log:trace("RLMenuAIFrame:refreshSpecies: no species, showing empty state")
        if self.noHusbandriesText ~= nil then self.noHusbandriesText:setVisible(true) end
        if self.subCategoryDotBox ~= nil then self.subCategoryDotBox:setVisible(false) end
        if self.subCategorySelector ~= nil then self.subCategorySelector:setTexts({}) end
        self.activeSpeciesTypeIndex = nil
        self.items = {}
        self.sectionOrder    = {}
        self.itemsBySection  = {}
        self.titlesBySection = {}
        if self.animalList ~= nil then self.animalList:reloadData() end
        self:updateEmptyState()
        self:updateButtonVisibility()
        RLDetailPaneHelper.updateMoneyDisplay(self)
        RLDetailPaneHelper.clearAnimalDetail(self)
        if self.aiPurchasePanel ~= nil then self.aiPurchasePanel:setVisible(false) end
        return
    end

    if self.noHusbandriesText ~= nil then self.noHusbandriesText:setVisible(false) end

    local names = {}
    for index, animalType in ipairs(self.sortedSpecies) do
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

    -- Always start on species 1. No shared-selection import.
    local initialState = 1

    if self.subCategorySelector ~= nil then
        self.subCategorySelector:setTexts(names)
        self.subCategorySelector:setState(initialState, true)
    else
        self:onSpeciesChanged(initialState)
    end
end


--- MultiTextOption onClick callback. Fires on species change.
--- @param state number 1-based species index
function RLMenuAIFrame:onSpeciesChanged(state)
    if state == nil or state < 1 or state > #self.sortedSpecies then return end

    local animalType = self.sortedSpecies[state]
    local newTypeIndex = animalType and animalType.typeIndex or nil
    self.activeSpeciesTypeIndex = newTypeIndex

    Log:debug("RLMenuAIFrame:onSpeciesChanged: state=%d typeIndex=%s", state, tostring(newTypeIndex))

    self:reloadBullList()
    RLDetailPaneHelper.updateMoneyDisplay(self)
end


--- SmoothList delegate: fired when the user picks a different row.
--- @param list table
--- @param section number
--- @param index number
function RLMenuAIFrame:onListSelectionChanged(list, section, index)
    if list ~= self.animalList then return end
    if section == nil or index == nil then return end
    Log:trace("RLMenuAIFrame:onListSelectionChanged: section=%d index=%d", section, index)
    self:onBullSelectionChanged()
end


-- =============================================================================
-- Bull list
-- =============================================================================

--- Requery AI stock for the active species, group into sections, refresh
--- the SmoothList, restore selection by identity.
function RLMenuAIFrame:reloadBullList()
    Log:trace("RLMenuAIFrame:reloadBullList: begin")
    self:captureCurrentSelection()

    if self.activeSpeciesTypeIndex == nil then
        self.items = {}
    else
        self.items = RLAIStockService.listBullsForSpecies(self.activeSpeciesTypeIndex)
    end

    self.sectionOrder, self.itemsBySection, self.titlesBySection =
        RLAIStockService.buildSections(self.items)

    if self.animalList ~= nil then
        self.animalList:reloadData()
    end

    self:restoreSelection()
    self:updateEmptyState()
    self:updateButtonVisibility()
end


--- Capture the currently highlighted bull's identity.
function RLMenuAIFrame:captureCurrentSelection()
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


--- Re-highlight the previously selected bull. Falls back to (1, 1).
function RLMenuAIFrame:restoreSelection()
    if self.animalList == nil then return end

    if #self.sectionOrder == 0 then
        self.selectedIdentity = nil
        RLDetailPaneHelper.clearAnimalDetail(self)
        if self.aiPurchasePanel ~= nil then self.aiPurchasePanel:setVisible(false) end
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
    -- setSelectedItem does not always fire onListSelectionChanged, so
    -- force the middle-column + detail-pane refresh explicitly.
    self:onBullSelectionChanged()
end


-- =============================================================================
-- Bull selection change: updates detail pane + middle column + Favourite label
-- =============================================================================

--- Refresh dependent UI for the focused bull - the central entry point for every
--- selection path. The identity cache early-returns before the stepper or detail pane is
--- touched, so a reloadData that re-fires the selection callback cannot reset them.
function RLMenuAIFrame:onBullSelectionChanged()
    local animal = self:getSelectedAnimal()

    if animal == nil then
        RLDetailPaneHelper.clearAnimalDetail(self)
        if self.aiPurchasePanel ~= nil then self.aiPurchasePanel:setVisible(false) end
        self.lastSelectedBullIdentity = nil
        self:updateButtonVisibility()
        Log:trace("RLMenuAIFrame:onBullSelectionChanged: no animal focused")
        return
    end

    local country = (animal.birthday ~= nil and animal.birthday.country) or ""
    local speciesTypeIndex = self.activeSpeciesTypeIndex
    local cached = self.lastSelectedBullIdentity
    if cached ~= nil
        and cached.farmId           == animal.farmId
        and cached.uniqueId         == animal.uniqueId
        and cached.country          == country
        and cached.speciesTypeIndex == speciesTypeIndex then
        Log:trace("RLMenuAIFrame:onBullSelectionChanged: dedupe hit farmId=%s uniqueId=%s species=%s - skipping re-render",
            tostring(animal.farmId), tostring(animal.uniqueId), tostring(speciesTypeIndex))
        return
    end

    Log:trace("RLMenuAIFrame:onBullSelectionChanged: farmId=%s uniqueId=%s country=%s species=%s",
        tostring(animal.farmId), tostring(animal.uniqueId), tostring(country),
        tostring(speciesTypeIndex))

    -- AI bulls have no source husbandry; the helper tolerates nil.
    RLDetailPaneHelper.updateAnimalDisplay(self, animal, nil)

    -- Middle column. Price flows through onQuantityStateChanged so bull-change
    -- and stepper-click share a single render path.
    self:updateMiddleColumn(animal)

    -- Favourite button label (legacy parity).
    self:refreshFavouriteButtonLabel(animal)

    self:updateButtonVisibility()

    -- The key carries the species index, so two bulls in different species sharing id
    -- fields cannot suppress a render when the cycler moves between them.
    self.lastSelectedBullIdentity = {
        farmId           = animal.farmId,
        uniqueId         = animal.uniqueId,
        country          = country,
        speciesTypeIndex = speciesTypeIndex,
    }
end


--- Populate the middle column for a bull. The price display routes through
--- onQuantityStateChanged, so a bull change and a stepper click share one render path.
--- @param animal table Raw Animal
function RLMenuAIFrame:updateMiddleColumn(animal)
    if animal == nil then return end

    if self.aiPurchasePanel ~= nil then
        self.aiPurchasePanel:setVisible(true)
    end

    -- setState without the forceEvent arg updates silently, so onQuantityStateChanged
    -- is invoked explicitly below to reprice for the newly selected bull.
    if self.aiQuantitySelector ~= nil and self.aiQuantitySelector.setState ~= nil then
        self.aiQuantitySelector:setState(1)
    end

    -- Average Success: legacy pattern. math.round (not %d) matches the
    -- rounding used in DewarData and AnimalAIDialog.
    if self.averageSuccessValue ~= nil then
        local successPct = math.round((animal.success or 0) * 100)
        self.averageSuccessValue:setText(string.format("%s%%", tostring(successPct)))
    end

    -- Price: canonical path through the stepper handler so selection-change
    -- and stepper clicks run through the exact same recompute + render.
    self:onQuantityStateChanged(1)
end


--- Set the Favourite button label from the bull's state, through the service's own
--- text helper so the read site and the toggle site share one key mapping.
--- @param animal table Raw Animal
function RLMenuAIFrame:refreshFavouriteButtonLabel(animal)
    if animal == nil or self.favouriteButtonInfo == nil then return end

    local uniqueUserId = g_localPlayer ~= nil and g_localPlayer:getUniqueId() or nil
    local isFavourite = uniqueUserId ~= nil
        and type(animal.favouritedBy) == "table"
        and animal.favouritedBy[uniqueUserId] == true

    self.favouriteButtonInfo.text =
        g_i18n:getText(RLAIStockService.getFavouriteButtonText(isFavourite))
    Log:trace("RLMenuAIFrame:refreshFavouriteButtonLabel: isFavourite=%s", tostring(isFavourite))
end


-- =============================================================================
-- Empty state / buttons
-- =============================================================================

--- Toggle empty-state text based on the current data.
function RLMenuAIFrame:updateEmptyState()
    local hasSpecies = #self.sortedSpecies > 0
    local hasItems = #self.items > 0

    if self.noAnimalsText ~= nil then
        self.noAnimalsText:setVisible(hasSpecies and not hasItems)
    end
end


--- Get the currently focused bull from the list.
--- @return table|nil cluster
function RLMenuAIFrame:getSelectedAnimal()
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


--- Rebuild the footer buttons. Favourite disables on no-bull; Buy additionally needs the
--- tradeAnimals permission, so an MP client never sees an active button it cannot use.
--- The click-time permission check stays in place behind it.
function RLMenuAIFrame:updateButtonVisibility()
    self.menuButtonInfo = { self.backButtonInfo }

    local focusedAnimal = self:getSelectedAnimal()
    local hasBull = focusedAnimal ~= nil

    -- Client-side tradeAnimals gate for Buy only. Favourite is a purely local
    -- mark with no permission requirement.
    local hasTradePermission = g_currentMission ~= nil
        and g_currentMission.getHasPlayerPermission ~= nil
        and g_currentMission:getHasPlayerPermission("tradeAnimals") == true

    self.favouriteButtonInfo.disabled = not hasBull
    self.buyButtonInfo.disabled = not hasBull or not hasTradePermission
    table.insert(self.menuButtonInfo, self.favouriteButtonInfo)
    table.insert(self.menuButtonInfo, self.buyButtonInfo)

    Log:trace("RLMenuAIFrame:updateButtonVisibility: buttons=%d hasBull=%s tradePerm=%s favDisabled=%s buyDisabled=%s",
        #self.menuButtonInfo, tostring(hasBull), tostring(hasTradePermission),
        tostring(self.favouriteButtonInfo.disabled), tostring(self.buyButtonInfo.disabled))
    self:setMenuButtonInfoDirty()
end


-- =============================================================================
-- Quantity stepper: recompute displayed total price for current state
-- =============================================================================

--- Quantity selector callback: reprice for the new state. Also invoked directly on a
--- bull-selection change, so both paths share one price render.
--- @param state number 1-based DEWAR_QUANTITIES index
function RLMenuAIFrame:onQuantityStateChanged(state)
    if state == nil then
        Log:warning("RLMenuAIFrame:onQuantityStateChanged: nil state")
        return
    end
    if RLConstants == nil or RLConstants.DEWAR_QUANTITIES == nil then
        Log:warning("RLMenuAIFrame:onQuantityStateChanged: DEWAR_QUANTITIES unavailable")
        return
    end
    local quantity = RLConstants.DEWAR_QUANTITIES[state]
    if quantity == nil then
        Log:warning("RLMenuAIFrame:onQuantityStateChanged: unknown state %s", tostring(state))
        return
    end

    local animal = self:getSelectedAnimal()
    if animal == nil then
        Log:trace("RLMenuAIFrame:onQuantityStateChanged: state=%d quantity=%d no animal focused",
            state, quantity)
        return
    end

    local price = RLAIStockService.getPriceForQuantity(animal, quantity)
    if self.aiQuantityPrice ~= nil then
        self.aiQuantityPrice:setText(g_i18n:formatMoney(price, 2, true, true))
    end
    Log:trace("RLMenuAIFrame:onQuantityStateChanged: state=%d quantity=%d price=%.2f farmId=%s uniqueId=%s",
        state, quantity, price, tostring(animal.farmId), tostring(animal.uniqueId))
end


-- =============================================================================
-- Favourite + Buy handlers
-- =============================================================================

--- Favourite footer action: toggles locally, with no network event, then refreshes the
--- row tint and the button label from the toggle's own return value.
function RLMenuAIFrame:onClickFavourite()
    local animal = self:getSelectedAnimal()
    if animal == nil then
        Log:trace("RLMenuAIFrame:onClickFavourite: no animal focused")
        return
    end

    local isFav = RLAIStockService.toggleFavourite(animal)
    if isFav == nil then
        -- Service logged the WARNING; skip UI updates so the button label
        -- does not lie about the state we failed to write.
        Log:debug("RLMenuAIFrame:onClickFavourite: toggle failed (service returned nil)")
        return
    end

    -- Refresh the row tint. A bare reloadData usually preserves the highlight without
    -- re-firing the selection callback, and the identity dedupe catches it if it does.
    if self.animalList ~= nil then
        self.animalList:reloadData()
    end

    -- Label refresh. Fixes legacy's latent bug by binding from the fresh
    -- return value. menuButtonInfo is marked dirty so the footer redraws.
    if self.favouriteButtonInfo ~= nil then
        self.favouriteButtonInfo.text =
            g_i18n:getText(RLAIStockService.getFavouriteButtonText(isFav))
        self:setMenuButtonInfoDirty()
    end

    Log:debug("RLMenuAIFrame:onClickFavourite: farmId=%s bullUid=%s isFavourite=%s",
        tostring(animal.farmId), tostring(animal.uniqueId), tostring(isFav))
end


--- Buy footer action. Reserves a store spawn lane ONLY on the dispatch path, so a
--- rejected pre-flight leaves the lane cursor untouched and a failed click leaks no lane
--- space; looking the slot up beforehand is safe, because that only reads the usage.
--- With no free lane it shows a warning dialog and dispatches nothing.
function RLMenuAIFrame:onClickBuy()
    -- Reentrancy guard: InfoDialog is async, so a second Enter press between
    -- dispatch and dialog-dismiss would double-fire SemenBuyEvent and
    -- double-consume store spawn slots. Clear in onPostSemenBuy + onFrameOpen.
    if self.buyInFlight == true then
        Log:trace("RLMenuAIFrame:onClickBuy: buy in flight, ignoring re-entry")
        return
    end

    local animal = self:getSelectedAnimal()
    if animal == nil then
        Log:trace("RLMenuAIFrame:onClickBuy: no animal focused")
        return
    end

    -- Guard BEFORE markPlaceUsed, so a no-farm click cannot leak a store spawn slot.
    if g_localPlayer == nil
        or g_localPlayer.farmId == nil
        or g_localPlayer.farmId == 0 then
        Log:warning("RLMenuAIFrame:onClickBuy: no valid local player farm (player=%s farmId=%s)",
            tostring(g_localPlayer), tostring(g_localPlayer and g_localPlayer.farmId))
        return
    end

    -- Step 1: spawn-slot lookup.
    local spawnPlaces = g_currentMission and g_currentMission.storeSpawnPlaces
    local usedPlaces  = g_currentMission and g_currentMission.usedStorePlaces
    if spawnPlaces == nil or usedPlaces == nil then
        Log:warning("RLMenuAIFrame:onClickBuy: storeSpawnPlaces / usedStorePlaces unavailable")
        return
    end

    local x, y, z, place, width = PlacementUtil.getPlace(
        spawnPlaces,
        { width = 1, height = 2.5, length = 1, widthOffset = 0.5, lengthOffset = 0.5 },
        usedPlaces,
        true, true, false, true
    )

    if x == nil then
        Log:warning("RLMenuAIFrame:onClickBuy: no free spawn slot")
        -- Reuse the vanilla Shop's "delivery space blocked" text so the
        -- no-space warning matches the rest of the vanilla Shop UX and
        -- comes pre-localized in every base-game language.
        InfoDialog.show(g_i18n:getText("shop_messageNoSpace"),
            nil, nil, DialogElement.TYPE_WARNING)
        return
    end

    -- Commit to opening a result dialog. Flag blocks reentrant Enter clicks.
    self.buyInFlight = true

    -- Step 3: compute quantity + price.
    local farmId = g_localPlayer.farmId
    local state = (self.aiQuantitySelector ~= nil and self.aiQuantitySelector:getState()) or 1
    local quantity = (RLConstants ~= nil and RLConstants.DEWAR_QUANTITIES ~= nil
        and RLConstants.DEWAR_QUANTITIES[state]) or 1
    local price = RLAIStockService.getPriceForQuantity(animal, quantity)

    Log:debug("RLMenuAIFrame:onClickBuy: pre-flight farmId=%d state=%d quantity=%d price=%.2f spawn=(%.2f,%.2f,%.2f)",
        farmId, state, quantity, price, x, y, z)

    -- Step 4 + 5: permission + money.
    local errorCode
    if not g_currentMission:getHasPlayerPermission("tradeAnimals") then
        errorCode = AnimalBuyEvent.BUY_ERROR_NO_PERMISSION
        Log:warning("RLMenuAIFrame:onClickBuy: no tradeAnimals permission")
    elseif g_currentMission:getMoney(farmId) - price < 0 then
        errorCode = AnimalBuyEvent.BUY_ERROR_NOT_ENOUGH_MONEY
        Log:warning("RLMenuAIFrame:onClickBuy: money-check triggered (balance-price<0) price=%.2f",
            price)
    else
        -- Step 6: reserve the lane, then dispatch. The lane cursor advances
        -- only on a real dispatch, so a rejected pre-flight never leaks lane
        -- space; the {x,y,z} sent stays the position getPlace returned.
        PlacementUtil.markPlaceUsed(usedPlaces, place, width)
        Log:debug("RLMenuAIFrame:onClickBuy: lane cursor advanced place=%s width=%.2f",
            tostring(place), width)

        errorCode = AnimalBuyEvent.BUY_SUCCESS
        g_client:getServerConnection():sendEvent(
            SemenBuyEvent.new(animal, quantity, -price, farmId, { x, y, z }, { 0, 0, 0 }),
            true)
        Log:info("RLMenuAIFrame:onClickBuy: SemenBuyEvent dispatched farmId=%d bullUid=%s quantity=%d price=%.2f",
            farmId, tostring(animal.uniqueId), quantity, price)
    end

    -- Step 7: always render the result dialog.
    self:onBuyComplete(errorCode)
end


--- Client-side pre-flight handler: maps the error code to a dialog. The name is
--- misleading - success here means the event was DISPATCHED, not that the dewar spawned.
--- @param errorCode number  One of AnimalBuyEvent.BUY_* constants
function RLMenuAIFrame:onBuyComplete(errorCode)
    local dialogType = DialogElement.TYPE_INFO
    local text = "rl_ui_semenPurchase_successful"

    if errorCode == AnimalBuyEvent.BUY_ERROR_NOT_ENOUGH_MONEY then
        dialogType = DialogElement.TYPE_WARNING
        text = "rl_ui_semenPurchaseNoMoney"
    elseif errorCode == AnimalBuyEvent.BUY_ERROR_NO_PERMISSION then
        dialogType = DialogElement.TYPE_WARNING
        text = "rl_ui_semenPurchaseNoPermission"
    elseif errorCode ~= AnimalBuyEvent.BUY_SUCCESS then
        dialogType = DialogElement.TYPE_WARNING
        text = "rl_ui_semenPurchase_unsuccessful"
    end

    Log:debug("RLMenuAIFrame:onBuyComplete: errorCode=%s text=%s",
        tostring(errorCode), text)

    -- Full positional InfoDialog.show signature. The trailing `true` is a positional
    -- artifact the callbacks declare no parameter for and ignore.
    InfoDialog.show(g_i18n:getText(text), self.onPostSemenBuy, self,
        dialogType, nil, nil, true)
end


--- InfoDialog dismissal callback: reloads the bull list so a stock change shows at once.
--- The dialog survives frame teardown, so the player can buy, close the menu and then
--- dismiss it - hence the stale-frame guard before the reload.
function RLMenuAIFrame:onPostSemenBuy()
    -- Always clear the reentrancy flag regardless of frame state, so a stale
    -- callback on a torn-down frame does not leave Buy permanently disabled
    -- when the frame is reopened. onFrameOpen defensively clears it too.
    self.buyInFlight = false

    if not self.isFrameOpen or self.activeSpeciesTypeIndex == nil then
        Log:trace("RLMenuAIFrame:onPostSemenBuy: stale frame (isFrameOpen=%s speciesTypeIndex=%s); skipping",
            tostring(self.isFrameOpen), tostring(self.activeSpeciesTypeIndex))
        return
    end

    -- Invalidate the dedupe cache first, or the same-identity bull skips its re-render
    -- after the reload and the middle column keeps stale stock and price.
    self.lastSelectedBullIdentity = nil

    Log:debug("RLMenuAIFrame:onPostSemenBuy: reloading bull list")
    self:reloadBullList()
end


-- =============================================================================
-- SmoothList data source / delegate
-- =============================================================================

--- @param list table
--- @return number
function RLMenuAIFrame:getNumberOfSections(list)
    if list == self.animalList then return #self.sectionOrder end
    return 0
end

--- @param list table
--- @param section number
--- @return string|nil
function RLMenuAIFrame:getTitleForSectionHeader(list, section)
    if list ~= self.animalList then return nil end
    local key = self.sectionOrder[section]
    return key and self.titlesBySection[key] or nil
end

--- @param list table
--- @param section number
--- @return number
function RLMenuAIFrame:getNumberOfItemsInSection(list, section)
    if list ~= self.animalList then return 0 end
    local key = self.sectionOrder[section]
    if key == nil then return 0 end
    local items = self.itemsBySection[key]
    return items ~= nil and #items or 0
end

--- Populate one data cell. The "price" cell carries the overall-quality label rather
--- than a money amount, and a favourited bull tints the row orange.
--- @param list table
--- @param section number
--- @param index number
--- @param cell table
function RLMenuAIFrame:populateCellForItemInSection(list, section, index, cell)
    if list ~= self.animalList then return end

    local key = self.sectionOrder[section]
    if key == nil then return end
    local items = self.itemsBySection[key]
    if items == nil then return end
    local item = items[index]
    if item == nil then return end

    local cluster = item.cluster
    if cluster == nil then return end

    -- The shared formatter, so the layout matches the other frames' rows.
    local row = RLAnimalQuery.formatAnimalRow(item)

    -- Favourite (orange) takes priority over the default tint.
    local uniqueUserId = g_localPlayer ~= nil and g_localPlayer:getUniqueId() or nil
    local isFavourite = uniqueUserId ~= nil
        and type(cluster.favouritedBy) == "table"
        and cluster.favouritedBy[uniqueUserId] == true

    local tintBranch
    if cell.setImageColor ~= nil then
        if isFavourite then
            cell:setImageColor(GuiOverlay.STATE_NORMAL, 1, 0.2, 0)
            tintBranch = "favourite"
        elseif row.tint == RLAnimalQuery.TINT_DISEASE then
            cell:setImageColor(GuiOverlay.STATE_NORMAL, 1, 0.08, 0)
            tintBranch = "disease"
        elseif row.tint == RLAnimalQuery.TINT_MARKED then
            cell:setImageColor(GuiOverlay.STATE_NORMAL, 1, 0.2, 0)
            tintBranch = "marked"
        else
            cell:setImageColor(GuiOverlay.STATE_NORMAL, 1, 1, 1)
            tintBranch = "normal"
        end
    end
    Log:trace("RLMenuAIFrame:populateCellForItemInSection: uniqueId=%s tint=%s isFavourite=%s",
        tostring(cluster.uniqueId), tostring(tintBranch), tostring(isFavourite))

    local iconCell = cell:getAttribute("icon")
    if iconCell ~= nil then
        if row.icon ~= nil then
            iconCell:setImageFilename(row.icon)
            iconCell:setVisible(true)
        else
            iconCell:setVisible(false)
        end
    end

    -- Name split (id/name vs id-without-name)
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

    -- "price" cell: overall-quality label (legacy parity, not money).
    local priceCell = cell:getAttribute("price")
    if priceCell ~= nil then
        local qualityKey = RLAIStockService.getQualityLabel(cluster)
        priceCell:setText(g_i18n:getText(qualityKey))
        Log:trace("RLMenuAIFrame:populateCellForItemInSection: uniqueId=%s qualityKey=%s",
            tostring(cluster.uniqueId), qualityKey)
    end
end
