--[[
    RLMenuTransferFrame.lua
    RL Tabbed Menu - Transfer tab, one frame for every trailer placement.

    The left sidebar is a fixed two-entry source picker - the counterpart (a pen, EPP or
    world endpoint) and the trailer - each labelled `name (used/total)`. Selecting a side
    lists that side's animals in a multi-select SmoothList, and a single footer action
    button (Load / Unload by side) routes the checked animals to the counterpart adapter.
    Where those animals come from and what a confirmed transfer does is the adapter's job
    (RLTransferAdapter); the frame only talks to that seam.

    Chrome mirrors RLMenuInfoFrame; the multi-select data row and footer mirror
    RLMenuMoveFrame. The pen and animal detail columns reuse RLDetailPaneHelper, and the
    pen column stays hidden while no side supplies a husbandry.
]]

RLMenuTransferFrame = {}
local RLMenuTransferFrame_mt = Class(RLMenuTransferFrame, TabbedMenuFrameElement)

local Log = RmLogging.getLogger("RLRM")

local modDirectory = g_currentModDirectory


--- Construct a new RLMenuTransferFrame instance.
--- @return table self
function RLMenuTransferFrame.new()
    local self = RLMenuTransferFrame:superClass().new(nil, RLMenuTransferFrame_mt)
    self.name = "RLMenuTransferFrame"

    -- Trailer context, read from g_rlMenu on open.
    self.trailer           = nil
    self.counterpart       = nil
    self.adapter           = RLTransferAdapter.NULL
    self.context           = nil   -- { trailer, counterpart, counterpartHandle }
    self.currentSide       = RLTransferAdapter.SIDE_COUNTERPART
    self.farmId            = nil

    -- List + section state (rebuilt per side).
    self.items             = {}
    self.sectionOrder      = {}
    self.itemsBySection    = {}
    self.titlesBySection   = {}

    -- Multi-select state, keyed by RLAnimalUtil.toKey. Cleared on every side
    -- switch (the two sides are different animal universes).
    self.selectedAnimals   = {}

    -- In-flight lock between dispatch and completion: the action button is
    -- selection-gated, not request-gated, so nothing else blocks a duplicate submit.
    self.movePending       = false

    -- World-counterpart refresh hook. The world redirect skips the legacy controller
    -- set, so the trailer's controller slot is nil and nothing refreshes the world list
    -- when its trigger contents change; this frame claims the slot while open.
    self.worldRefreshHookInstalled  = false
    self.priorAnimalScreenController = nil

    self.isFrameOpen = false
    self.hasCustomMenuButtons = true

    -- Footer buttons. Back always; Select and SelectAll once the side has rows.
    self.backButtonInfo = { inputAction = InputAction.MENU_BACK }
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
    -- EXTRA_1 transfers the highlighted row, EXTRA_2 the checked set; both route
    -- through dispatchTransfer. updateButtonVisibility overwrites the seed text with
    -- the adapter's verb for the current direction.
    self.actionSingleButtonInfo = {
        inputAction = InputAction.MENU_EXTRA_1,
        text = g_i18n:getText(RLTransferAdapter.LOAD_LABEL_KEY),
        callback = function() self:onClickActionSingle() end,
    }
    self.actionSelectedButtonInfo = {
        inputAction = InputAction.MENU_EXTRA_2,
        text = g_i18n:getText(RLTransferAdapter.LOAD_LABEL_KEY),
        callback = function() self:onClickActionSelected() end,
    }
    self.menuButtonInfo = { self.backButtonInfo }

    return self
end


--- Load the transfer frame XML and register it with g_gui so the host menu's
--- FrameReference can resolve it.
function RLMenuTransferFrame.setupGui()
    local frame = RLMenuTransferFrame.new()
    g_gui:loadGui(
        Utils.getFilename("gui/rlmenu/transferFrame.xml", modDirectory),
        "RLMenuTransferFrame",
        frame,
        true
    )
    Log:debug("RLMenuTransferFrame.setupGui: registered")
end


--- Bind the SmoothList datasource and delegate. Fires on both the original and the clone,
--- so tree mutation lives in initialize().
function RLMenuTransferFrame:onGuiSetupFinished()
    RLMenuTransferFrame:superClass().onGuiSetupFinished(self)

    if self.animalList ~= nil then
        self.animalList:setDataSource(self)
        self.animalList:setDelegate(self)
    else
        Log:warning("RLMenuTransferFrame:onGuiSetupFinished: animalList element missing from XML")
    end
end


--- One-time per-clone setup. Unlinks the dot template from the element tree so
--- it can be cloned at runtime. Called by RLMenu:setupMenuPages on the clone.
function RLMenuTransferFrame:initialize()
    if self.subCategoryDotTemplate ~= nil then
        self.subCategoryDotTemplate:unlinkElement()
        FocusManager:removeElement(self.subCategoryDotTemplate)
    else
        Log:warning("RLMenuTransferFrame:initialize: subCategoryDotTemplate missing - dots will not render")
    end
end


-- =============================================================================
-- Lifecycle
-- =============================================================================

--- Called by the Paging element when this tab becomes active. Reads the trailer
--- context from g_rlMenu, picks the counterpart adapter, builds the two-entry
--- source picker, and seeds the side via the emptiness heuristic.
function RLMenuTransferFrame:onFrameOpen()
    RLMenuTransferFrame:superClass().onFrameOpen(self)
    self.isFrameOpen = true

    -- Reset the hook state per session: the frame is a reused singleton, and a prior
    -- close skipped by a throw would leave a stale flag that makes the install below a
    -- no-op. Clear rather than restore - a leftover self in another trailer's slot is
    -- harmless, since onAnimalsChanged is gated on the trailer matching.
    self.worldRefreshHookInstalled  = false
    self.priorAnimalScreenController = nil

    if g_rlMenu ~= nil then
        self.trailer     = g_rlMenu.trailerVehicle
        self.counterpart = g_rlMenu.trailerCounterpart
        -- counterpartHandle is the engine ref a concrete adapter enumerates.
        self.context = {
            trailer           = self.trailer,
            counterpart       = self.counterpart,
            counterpartHandle = g_rlMenu.trailerCounterpartHandle,
        }
    else
        self.context = { trailer = nil, counterpart = nil, counterpartHandle = nil }
    end

    self.adapter = RLTransferAdapter.forCounterpart(self.counterpart)
    self.farmId  = RLAnimalInfoService.getCurrentFarmId()
    self.selectedAnimals = {}
    self.movePending = false

    -- The closure captures BOTH the trailer and the counterpart at open time, so a
    -- reply arriving after a close - or after a reopen on a different trailer or pen -
    -- is dropped rather than repainting the new session.
    local dispatchedTrailer = self.trailer
    local dispatchedCounterpart = self.context.counterpartHandle
    self.context.onComplete = function(success, errorText)
        self:onTransferComplete(success, errorText, dispatchedTrailer, dispatchedCounterpart)
    end

    local trailerName = RLTrailerEndpointService.getDisplayData(self.trailer).name
    Log:info("RLMenuTransferFrame:onFrameOpen: counterpart=%s trailer='%s'",
        tostring(self.counterpart), tostring(trailerName))

    -- Reset the selection sentinels so a stale focus index cannot leak into the reload.
    if self.animalList ~= nil then
        self.animalList.selectedSectionIndex = 0
        self.animalList.selectedIndex = 0
    end

    self:refreshSources()

    -- Explicit focus links: several frames share this sidebar and list structure, so
    -- FocusManager auto-layout can otherwise resolve into another frame's elements.
    if self.subCategorySelector ~= nil and self.animalList ~= nil then
        FocusManager:linkElements(self.subCategorySelector, FocusManager.BOTTOM, self.animalList)
        FocusManager:linkElements(self.animalList, FocusManager.TOP, self.subCategorySelector)
    end
    if self.animalList ~= nil then
        FocusManager:setFocus(self.animalList)
    end

    -- Runs after trailer and counterpart are set; a no-op for any other counterpart.
    self:installWorldRefreshHook()
end


--- Deactivation hook: releases the world-refresh controller slot. There is no
--- shared-selection export, since Transfer has no sibling tab in trailer mode.
function RLMenuTransferFrame:onFrameClose()
    RLMenuTransferFrame:superClass().onFrameClose(self)
    self.isFrameOpen = false
    self:uninstallWorldRefreshHook()
end


-- =============================================================================
-- World-counterpart refresh hook (Bug A)
-- =============================================================================

--- Whether self.trailer is a live, controller-capable livestock trailer. Guards every
--- deref in the world-refresh lifecycle, so a sold trailer no-ops rather than
--- dereferencing a torn-down spec.
--- @return boolean live
function RLMenuTransferFrame:isTrailerLive()
    return self.trailer ~= nil
        and self.trailer.spec_livestockTrailer ~= nil
        and not self.trailer.isDeleted
        and self.trailer.setAnimalScreenController ~= nil
end


--- Register this frame as the trailer's animalScreenController, so the trailer drives
--- onAnimalsChanged here when its trigger contents change. World counterpart only.
--- Ownership-safe: the prior controller is captured EXACTLY ONCE, and self is installed
--- through the public setter rather than by poking the slot.
function RLMenuTransferFrame:installWorldRefreshHook()
    if self.counterpart ~= RLMenu.TRAILER_WORLD then return end
    if not self:isTrailerLive() then
        Log:debug("RLMenuTransferFrame:installWorldRefreshHook: trailer not live, skipping")
        return
    end

    local spec = self.trailer.spec_livestockTrailer
    if self.worldRefreshHookInstalled then return end

    if spec.animalScreenController == self then
        -- The slot already holds self. Adopt it WITHOUT capturing self as the prior,
        -- so the flag and the slot cannot desync.
        self.worldRefreshHookInstalled = true
        self.priorAnimalScreenController = nil
        Log:debug("RLMenuTransferFrame:installWorldRefreshHook: adopted existing self in controller slot")
        return
    end

    self.priorAnimalScreenController = spec.animalScreenController
    self.worldRefreshHookInstalled = true
    self.trailer:setAnimalScreenController(self)
    Log:debug("RLMenuTransferFrame:installWorldRefreshHook: installed (prior controller=%s)",
        tostring(self.priorAnimalScreenController))
end


--- Release the controller slot this frame claimed on open. Reads the FRAME's captured
--- trailer, never g_rlMenu, whose trailer fields are nilled before onFrameClose fires.
--- Restores the prior controller ONLY IF the slot still holds self, so a newer owner
--- that claimed it while the frame was open is left alone.
function RLMenuTransferFrame:uninstallWorldRefreshHook()
    if not self.worldRefreshHookInstalled then return end

    if self:isTrailerLive() then
        local spec = self.trailer.spec_livestockTrailer
        if spec.animalScreenController == self then
            self.trailer:setAnimalScreenController(self.priorAnimalScreenController)
            Log:trace("RLMenuTransferFrame:uninstallWorldRefreshHook: restored prior controller=%s",
                tostring(self.priorAnimalScreenController))
        else
            Log:trace("RLMenuTransferFrame:uninstallWorldRefreshHook: slot reclaimed by a newer owner, leaving it")
        end
    else
        Log:trace("RLMenuTransferFrame:uninstallWorldRefreshHook: trailer not live, nothing to restore")
    end

    self.worldRefreshHookInstalled = false
    self.priorAnimalScreenController = nil
end


--- Controller callback the trailer fires when its trigger contents change. Re-enumerates
--- the world source from fresh engine state so the list and both headers self-correct,
--- and prunes any checked identity the mutation removed.
--- @param obj table  the trailer firing the callback (must match self.trailer)
--- @param clusters table|nil  deliberately unused: the callback re-enumerates from scratch (passed nil)
function RLMenuTransferFrame:onAnimalsChanged(obj, clusters)
    if not self.isFrameOpen or obj ~= self.trailer or not self:isTrailerLive() then
        Log:trace("RLMenuTransferFrame:onAnimalsChanged: ignored (frameOpen=%s, sameTrailer=%s, live=%s)",
            tostring(self.isFrameOpen), tostring(obj == self.trailer), tostring(self:isTrailerLive()))
        return
    end

    self:reloadAnimalList()
    self:pruneSelectionToList()
    self:updateSourceLabels()
    self:updatePenDisplay()
    self:updateButtonVisibility()
    Log:debug("RLMenuTransferFrame:onAnimalsChanged: refreshed world source (selected now %d)",
        self:getSelectedCount())
end


--- Drop any checked identity the rebuilt list no longer carries, so the Action button
--- hides when nothing valid remains. Collect-then-delete avoids mutating mid-iteration.
function RLMenuTransferFrame:pruneSelectionToList()
    local live = {}
    for _, item in ipairs(self.items) do
        if item.cluster ~= nil then
            local c = item.cluster
            local key = RLSelectionKey.build(c.farmId, c.uniqueId, c.birthday and c.birthday.country)
            if key ~= nil then
                live[key] = true
            end
        end
    end
    local stale = {}
    for key, selected in pairs(self.selectedAnimals) do
        if selected and not live[key] then
            stale[#stale + 1] = key
        end
    end
    for _, key in ipairs(stale) do
        self.selectedAnimals[key] = nil
        Log:trace("RLMenuTransferFrame:pruneSelectionToList: dropped stale selection key=%s", key)
    end
end


-- =============================================================================
-- Source picker (two fixed entries: counterpart, trailer)
-- =============================================================================

--- Recompute both sidebar labels as `name (used/total)` WITHOUT re-seeding the side. A
--- concrete adapter's name is an engine string used verbatim, while the NULL adapter
--- returns an i18n KEY this frame must resolve.
--- @return string cpLabel, string trLabel  the composed labels (for logging)
function RLMenuTransferFrame:updateSourceLabels()
    -- Counterpart entry. context-aware getDisplayData so a concrete adapter knows
    -- its pen; NULL accepts and ignores the context.
    local cpData = self.adapter:getDisplayData(self.context)
    local cpName = cpData.name
    if self.adapter == RLTransferAdapter.NULL then
        cpName = g_i18n:getText(cpData.name)
    end
    local cpLabel = RLTransferAdapter.formatCapacityLabel(cpName, cpData.used, cpData.total)

    -- Trailer entry (engine name string from the endpoint service).
    local trData = RLTrailerEndpointService.getDisplayData(self.trailer)
    local trLabel = RLTransferAdapter.formatCapacityLabel(trData.name, trData.used, trData.total)

    if self.subCategorySelector ~= nil then
        self.subCategorySelector:setTexts({ cpLabel, trLabel })
    end
    Log:trace("RLMenuTransferFrame:updateSourceLabels: counterpart='%s' trailer='%s'", cpLabel, trLabel)
    return cpLabel, trLabel
end


--- Rebuild the two-entry sidebar selector + dots and seed the initial side.
--- Entry 1 = counterpart (adapter), entry 2 = trailer (endpoint service). Each
--- label is `name (used/total)`. Label compute + setTexts live in updateSourceLabels.
function RLMenuTransferFrame:refreshSources()
    local cpLabel, trLabel = self:updateSourceLabels()
    local labels = { cpLabel, trLabel }

    -- Clear existing dot clones, then clone one dot per entry.
    if self.subCategoryDotBox ~= nil then
        for i, dot in pairs(self.subCategoryDotBox.elements) do
            dot:delete()
            self.subCategoryDotBox.elements[i] = nil
        end
    end
    for index = 1, #labels do
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
        self.subCategoryDotBox:setVisible(1 < #labels)
    end

    if self.subCategorySelector ~= nil then
        self.subCategorySelector:setTexts(labels)
    end

    -- Seed the side via the pure heuristic: empty trailer -> counterpart (load),
    -- loaded -> trailer (unload).
    local trailerEmpty = RLTrailerEndpointService.isEmpty(self.trailer)
    local side = RLTransferAdapter.initialSourceSide(trailerEmpty)
    local seedIndex = (side == RLTransferAdapter.SIDE_TRAILER) and 2 or 1
    Log:info("RLMenuTransferFrame:refreshSources: counterpart='%s' trailer='%s' trailerEmpty=%s -> seed side=%s (index %d)",
        cpLabel, trLabel, tostring(trailerEmpty), side, seedIndex)

    if self.subCategorySelector ~= nil then
        -- The forced-event flag raises onSourceChanged whether or not the index
        -- changed, so one call seeds the side for either index.
        self.subCategorySelector:setState(seedIndex, true)
    else
        self:onSourceChanged(seedIndex)
    end
end


--- MultiTextOption onClick callback. Switches the active side, clears the
--- cross-side selection, and rebuilds the list + detail + buttons.
--- @param state number 1 = counterpart, 2 = trailer
function RLMenuTransferFrame:onSourceChanged(state)
    if state == nil or state < 1 or state > 2 then return end

    self.currentSide = (state == 2) and RLTransferAdapter.SIDE_TRAILER
        or RLTransferAdapter.SIDE_COUNTERPART

    -- Two sides are different animal universes - clear any checkbox selection so
    -- it cannot leak across the switch.
    self.selectedAnimals = {}

    Log:debug("RLMenuTransferFrame:onSourceChanged: state=%d side=%s (selection cleared, labels refreshed)",
        state, self.currentSide)

    self:reloadAnimalList()
    -- Recompute BOTH sidebar headers on a side flip; the counts are capacity-based.
    self:updateSourceLabels()
    self:updatePenDisplay()
    self:updateButtonVisibility()
end


-- =============================================================================
-- Animal list
-- =============================================================================

--- Build the item list for the active side, group into sections, refresh the
--- SmoothList, and seed the detail pane for the first row.
function RLMenuTransferFrame:reloadAnimalList()
    self.items = self:buildSideItems(self.currentSide)
    self.sectionOrder, self.itemsBySection, self.titlesBySection =
        RLAnimalQuery.buildSections(self.items)

    if self.animalList ~= nil then
        self.animalList:reloadData()
    end

    self:seedDetailForFirstRow()
    self:updateEmptyState()
end


--- Build the list items for a side. Trailer side: wrap + validate the trailer's
--- live contents. Counterpart side: the adapter enumerates (NULL -> {}).
--- @param side string SIDE_COUNTERPART | SIDE_TRAILER
--- @return table items
function RLMenuTransferFrame:buildSideItems(side)
    if side == RLTransferAdapter.SIDE_TRAILER then
        return self:buildTrailerItems()
    end
    local items = self.adapter:enumerate(self.context) or {}
    Log:debug("RLMenuTransferFrame:buildSideItems: counterpart side -> %d item(s)", #items)
    return items
end


--- Wrap the trailer's live contents into AnimalItemStock items, skipping
--- non-loadable clusters (numAnimals < 1, e.g. riding-mission horses) and
--- unresolvable subtypes (props / vanilla items) - mirrors the legacy
--- AnimalScreenTrailer:initSourceItems validity gate.
--- @return table items
function RLMenuTransferFrame:buildTrailerItems()
    local refs = RLTrailerEndpointService.getContents(self.trailer)
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
    Log:debug("RLMenuTransferFrame:buildTrailerItems: %d item(s), %d skipped (invalid cluster)",
        #items, skipped)
    return items
end


--- Whether a trailer cluster is a loadable animal (legacy initSourceItems
--- parity). Rejects numAnimals < 1 and an unresolvable subTypeIndex.
--- @param ref table|nil  a live cluster from getContents
--- @return boolean loadable
function RLMenuTransferFrame:isLoadableTrailerCluster(ref)
    if ref == nil then return false end

    if ref.numAnimals ~= nil and ref.numAnimals < 1 then
        Log:trace("RLMenuTransferFrame:isLoadableTrailerCluster: skip numAnimals=%s", tostring(ref.numAnimals))
        return false
    end

    local subTypeIndex = (ref.getSubTypeIndex ~= nil and ref:getSubTypeIndex()) or ref.subTypeIndex
    if subTypeIndex == nil then
        Log:trace("RLMenuTransferFrame:isLoadableTrailerCluster: skip nil subTypeIndex")
        return false
    end

    if g_currentMission ~= nil and g_currentMission.animalSystem ~= nil
        and g_currentMission.animalSystem.getSubTypeByIndex ~= nil then
        if g_currentMission.animalSystem:getSubTypeByIndex(subTypeIndex) == nil then
            Log:trace("RLMenuTransferFrame:isLoadableTrailerCluster: skip unresolvable subTypeIndex=%s",
                tostring(subTypeIndex))
            return false
        end
    end

    return true
end


--- Seed the detail pane for the auto-selected first row (setSelectedItem does
--- NOT fire onListSelectionChanged). Clears the animal column when the side is
--- empty.
function RLMenuTransferFrame:seedDetailForFirstRow()
    if self.animalList == nil then return end

    if #self.sectionOrder == 0 then
        RLDetailPaneHelper.clearAnimalDetail(self)
        return
    end

    self.animalList:setSelectedItem(1, 1, false, true)

    local key = self.sectionOrder[1]
    local items = key and self.itemsBySection[key] or nil
    local item = items and items[1] or nil
    if item ~= nil and item.cluster ~= nil then
        RLDetailPaneHelper.updateAnimalDisplay(self, item.cluster, self:detailHusbandry())
    end
end


--- The husbandry for the detail pane. The trailer side returns nil - a trailer has no
--- husbandry, so the pen column stays hidden - and both consumers tolerate nil.
--- @return table|nil
function RLMenuTransferFrame:detailHusbandry()
    if self.currentSide == RLTransferAdapter.SIDE_COUNTERPART then
        return self.context ~= nil and self.context.counterpartHandle or nil
    end
    return nil
end


--- SmoothList delegate: fired when the user focuses a different row.
--- @param list table
--- @param section number
--- @param index number
function RLMenuTransferFrame:onListSelectionChanged(list, section, index)
    if list ~= self.animalList then return end
    if section == nil or index == nil then return end
    Log:trace("RLMenuTransferFrame:onListSelectionChanged: section=%d index=%d", section, index)

    local key = self.sectionOrder[section]
    if key == nil then RLDetailPaneHelper.clearAnimalDetail(self); return end
    local items = self.itemsBySection[key]
    if items == nil then RLDetailPaneHelper.clearAnimalDetail(self); return end
    local item = items[index]
    if item == nil or item.cluster == nil then RLDetailPaneHelper.clearAnimalDetail(self); return end

    RLDetailPaneHelper.updateAnimalDisplay(self, item.cluster, self:detailHusbandry())
    self:updateButtonVisibility()
end


-- =============================================================================
-- Empty state / detail pane
-- =============================================================================

--- Toggle the empty-state text when the active side has no rows. The list stays visible:
--- an empty SmoothList renders nothing but is still the valid focus target.
function RLMenuTransferFrame:updateEmptyState()
    local hasItems = #self.items > 0
    if self.noAnimalsText ~= nil then
        self.noAnimalsText:setVisible(not hasItems)
    end
end


--- Refresh the pen detail column. Shell: no side supplies a husbandry, so the
--- pen column stays hidden (updatePenDisplay hides penBox on nil husbandry).
function RLMenuTransferFrame:updatePenDisplay()
    RLDetailPaneHelper.updatePenDisplay(self, self:detailHusbandry(), self.farmId)
end


-- =============================================================================
-- Multi-select
-- =============================================================================

--- The currently focused row's animal, or nil.
--- @return table|nil cluster
function RLMenuTransferFrame:getSelectedAnimal()
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


--- Count the checked animals.
--- @return number
function RLMenuTransferFrame:getSelectedCount()
    local count = 0
    for _, selected in pairs(self.selectedAnimals) do
        if selected then count = count + 1 end
    end
    return count
end


--- Collect the checked animals into an array (display order).
--- @return table animals
function RLMenuTransferFrame:collectSelectedAnimals()
    local animals = {}
    for _, key in ipairs(self.sectionOrder) do
        local items = self.itemsBySection[key]
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
    return animals
end


--- Toggle the focused animal's checkbox.
function RLMenuTransferFrame:onClickSelect()
    if not self.isFrameOpen then
        Log:trace("RLMenuTransferFrame:onClickSelect: frame closed, ignoring")
        return
    end
    local animal = self:getSelectedAnimal()
    if animal == nil then
        Log:trace("RLMenuTransferFrame:onClickSelect: no animal focused")
        return
    end

    local key = RLSelectionKey.build(animal.farmId, animal.uniqueId,
        animal.birthday and animal.birthday.country)
    if key == nil then
        Log:trace("RLMenuTransferFrame:onClickSelect: nil selection key, skipping")
        return
    end
    self.selectedAnimals[key] = not self.selectedAnimals[key]
    Log:trace("RLMenuTransferFrame:onClickSelect: key=%s -> %s", key, tostring(self.selectedAnimals[key]))

    -- Reload to re-render checkmarks; SmoothList preserves focus across reloadData
    -- so do NOT re-seed the selection (that would reset focus to (1,1)).
    if self.animalList ~= nil then
        self.animalList:reloadData()
    end
    self:updateButtonVisibility()
end


--- Toggle all rows: if any are checked, clear; otherwise check all on this side.
function RLMenuTransferFrame:onClickSelectAll()
    if not self.isFrameOpen then
        Log:trace("RLMenuTransferFrame:onClickSelectAll: frame closed, ignoring")
        return
    end
    local hasSelection = self:getSelectedCount() > 0

    if hasSelection then
        self.selectedAnimals = {}
        Log:debug("RLMenuTransferFrame:onClickSelectAll: deselected all")
    else
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
                            Log:trace("RLMenuTransferFrame:onClickSelectAll: nil key for a cluster, skipping")
                        end
                    end
                end
            end
        end
        Log:debug("RLMenuTransferFrame:onClickSelectAll: selected all (%d)", self:getSelectedCount())
    end

    if self.animalList ~= nil then
        self.animalList:reloadData()
    end
    self:updateButtonVisibility()
end


-- =============================================================================
-- Footer action (Load / Unload)
-- =============================================================================

--- Rebuild the footer buttons. Both action buttons share the adapter's verb: the single
--- shows whenever rows exist, the selected one only once something is checked. That
--- divergence from the always-shown siblings is deliberate - a shared verb would
--- otherwise render two identical buttons at zero checked.
function RLMenuTransferFrame:updateButtonVisibility()
    self.menuButtonInfo = { self.backButtonInfo }

    local hasItems = #self.items > 0
    local selectedCount = self:getSelectedCount()

    if hasItems then
        table.insert(self.menuButtonInfo, self.selectButtonInfo)
        self.selectAllButtonInfo.text = g_i18n:getText(
            selectedCount > 0 and "rl_ui_selectNone" or "rl_ui_selectAll")
        table.insert(self.menuButtonInfo, self.selectAllButtonInfo)

        -- The action verb (Load/Unload, or a concrete adapter's move-to-trailer /
        -- move-to-farm / move-to-spawn-place) shared by both buttons, per direction.
        local direction = RLTransferAdapter.directionForSide(self.currentSide)
        local verb = g_i18n:getText(self.adapter:actionLabel(direction))

        -- Selected (C / EXTRA_2): selection-gated, `verb (N)`. Inserted before the
        -- single, matching the sibling order (selected then single).
        if selectedCount > 0 then
            self.actionSelectedButtonInfo.text = verb .. " (" .. selectedCount .. ")"
            table.insert(self.menuButtonInfo, self.actionSelectedButtonInfo)
        end

        -- Single (X / EXTRA_1): always available when rows exist, disabled when no
        -- row is focused (its handler is a safe no-op either way).
        self.actionSingleButtonInfo.text = verb
        self.actionSingleButtonInfo.disabled = self:getSelectedAnimal() == nil
        table.insert(self.menuButtonInfo, self.actionSingleButtonInfo)
    end

    Log:debug("RLMenuTransferFrame:updateButtonVisibility: %d buttons, side=%s selectedCount=%d",
        #self.menuButtonInfo, tostring(self.currentSide), selectedCount)
    self:setMenuButtonInfoDirty()
end


--- Transfer the highlighted single row (X / MENU_EXTRA_1). Mirrors
--- RLMenuMoveFrame:onClickMove: act on the focused animal only, a no-op trace when
--- nothing is focused. Routes through the shared dispatchTransfer.
function RLMenuTransferFrame:onClickActionSingle()
    local animal = self:getSelectedAnimal()
    if animal == nil then
        Log:trace("RLMenuTransferFrame:onClickActionSingle: no row focused, no-op")
        return
    end
    Log:debug("RLMenuTransferFrame:onClickActionSingle: single transfer for farmId=%s uniqueId=%s",
        tostring(animal.farmId), tostring(animal.uniqueId))
    self:dispatchTransfer({ animal })
end


--- Transfer the checked set (C / MENU_EXTRA_2). Mirrors
--- RLMenuMoveFrame:onClickMoveSelected: collect the checked animals, a no-op trace
--- when none are checked. Routes through the shared dispatchTransfer.
function RLMenuTransferFrame:onClickActionSelected()
    local animals = self:collectSelectedAnimals()
    if #animals == 0 then
        Log:trace("RLMenuTransferFrame:onClickActionSelected: no animals checked, no-op")
        return
    end
    Log:debug("RLMenuTransferFrame:onClickActionSelected: bulk transfer for %d animal(s)", #animals)
    self:dispatchTransfer(animals)
end


--- Shared dispatch path for single and bulk. Owns the WHOLE mutation sequence so neither
--- handler touches movePending directly; the completion callback owns the refresh and
--- the lock release.
--- @param animals table  the clusters to transfer (a 1-element array for the single case)
function RLMenuTransferFrame:dispatchTransfer(animals)
    -- Duplicate-submit guard: the action buttons are selection/focus-gated, not
    -- request-gated, so block a second dispatch while a move is in flight.
    if self.movePending then
        Log:debug("RLMenuTransferFrame:dispatchTransfer: a transfer is already in flight, ignoring (selection kept)")
        InfoDialog.show(g_i18n:getText("rl_ui_tradeRequestInProgress"))
        return
    end

    local direction = RLTransferAdapter.directionForSide(self.currentSide)
    Log:debug("RLMenuTransferFrame:dispatchTransfer: side=%s direction=%s count=%d",
        tostring(self.currentSide), direction, #animals)

    if #animals == 0 then
        Log:trace("RLMenuTransferFrame:dispatchTransfer: no animals, no-op")
        return
    end

    -- Lock BEFORE dispatch: in SP the completion fires synchronously inside dispatch and
    -- clears it, so setting it afterwards would strand it true. A false return means no
    -- completion will fire at all, so the lock is released here.
    self.movePending = true
    local handled = self.adapter:dispatch(direction, animals, self.context)
    if not handled then
        self.movePending = false
        Log:debug("RLMenuTransferFrame:dispatchTransfer: dispatch returned false, state unchanged (shell no-op)")
        return
    end

    -- Routed to the move service: completion (onTransferComplete) owns the refresh
    -- + lock release. Do NOT reload synchronously - the move is a server round-trip
    -- in MP and a synchronous reload would show stale contents / miss server errors.
    Log:debug("RLMenuTransferFrame:dispatchTransfer: dispatched, awaiting completion")
end


--- Completion callback for an async transfer. In MP this is a server round-trip, so the
--- error surfacing and the refresh MUST happen here rather than after dispatch. Guarded
--- on the FULL dispatch context - trailer AND counterpart - so a delayed callback from
--- one session cannot repaint a reopened one. The adapter resolves its own result space
--- into the uniform (success, errorText) pair, keeping this frame adapter-agnostic.
--- @param success boolean  whether the transfer succeeded
--- @param errorText string|nil  localized error text on failure (nil on success)
--- @param dispatchedTrailer table  the trailer captured at dispatch time (stale guard)
--- @param dispatchedCounterpart table|nil  the counterpart captured at dispatch (stale guard)
function RLMenuTransferFrame:onTransferComplete(success, errorText, dispatchedTrailer, dispatchedCounterpart)
    -- The dispatched request has completed - always release the in-flight lock first so the
    -- frame isn't stranded, even when the stale-callback guard below skips the repaint (matches
    -- onBuyComplete / onMoveComplete, which release before their stale-return).
    self.movePending = false

    if not self.isFrameOpen or self.trailer ~= dispatchedTrailer
        or self.context == nil or self.context.counterpartHandle ~= dispatchedCounterpart then
        Log:debug("RLMenuTransferFrame:onTransferComplete: stale callback (frameOpen=%s, sameTrailer=%s, sameCounterpart=%s), ignoring",
            tostring(self.isFrameOpen), tostring(self.trailer == dispatchedTrailer),
            tostring(self.context ~= nil and self.context.counterpartHandle == dispatchedCounterpart))
        return
    end

    if not success then
        -- Branch on success FIRST, so a failure carrying no mapped error text is still
        -- logged as a failure rather than misclassified. The dialog needs text, so a
        -- text-less failure stays silent to the player but is recorded.
        if errorText ~= nil then
            InfoDialog.show(errorText)
        end
        Log:debug("RLMenuTransferFrame:onTransferComplete: transfer failed (errorText=%s)", tostring(errorText))
    else
        Log:info("RLMenuTransferFrame:onTransferComplete: transfer succeeded")
    end

    self:updateSourceLabels()
    self:reloadAnimalList()
    -- The rebuilt list has dropped the transferred animals, so pruning removes exactly
    -- those checked identities. On failure the list is unchanged, so this is a no-op and
    -- the selection survives for a retry.
    self:pruneSelectionToList()
    self:updatePenDisplay()
    self:updateButtonVisibility()
end


-- =============================================================================
-- SmoothList data source / delegate
-- =============================================================================

--- @param list table
--- @return number
function RLMenuTransferFrame:getNumberOfSections(list)
    if list == self.animalList then return #self.sectionOrder end
    return 0
end

--- @param list table
--- @param section number
--- @return string|nil
function RLMenuTransferFrame:getTitleForSectionHeader(list, section)
    if list ~= self.animalList then return nil end
    local key = self.sectionOrder[section]
    return key and self.titlesBySection[key] or nil
end

--- @param list table
--- @param section number
--- @return number
function RLMenuTransferFrame:getNumberOfItemsInSection(list, section)
    if list ~= self.animalList then return 0 end
    local key = self.sectionOrder[section]
    if key == nil then return 0 end
    local items = self.itemsBySection[key]
    return items ~= nil and #items or 0
end

--- Populate one data cell. Mirrors the Move tab pattern (animal row + status
--- icons + the multi-select checkbox).
--- @param list table
--- @param section number
--- @param index number
--- @param cell table
function RLMenuTransferFrame:populateCellForItemInSection(list, section, index, cell)
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

    -- Name split: baseName empty -> show idNoName only; else show id + name.
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

    -- Checkbox: show the tick when this row's identity is checked; wire the
    -- direct-click toggle (mirrors the Move tab onClickCallback pattern).
    local checkbox = cell:getAttribute("checkbox")
    local check = cell:getAttribute("check")
    if checkbox ~= nil then
        checkbox:setVisible(true)
        if check ~= nil then
            local identityKey = RLSelectionKey.build(row.farmId, row.uniqueId, row.country)
            check:setVisible(identityKey ~= nil and self.selectedAnimals[identityKey] == true)

            checkbox.onClickCallback = function()
                if not self.isFrameOpen then
                    Log:trace("RLMenuTransferFrame checkbox click: frame closed, ignoring")
                    return
                end
                if identityKey == nil then
                    Log:trace("RLMenuTransferFrame checkbox click: nil selection key, skipping")
                    return
                end
                self.selectedAnimals[identityKey] = not self.selectedAnimals[identityKey]
                check:setVisible(self.selectedAnimals[identityKey] == true)
                self:updateButtonVisibility()
                Log:trace("RLMenuTransferFrame checkbox click: key=%s -> %s",
                    identityKey, tostring(self.selectedAnimals[identityKey]))
            end
        end
    end
end
