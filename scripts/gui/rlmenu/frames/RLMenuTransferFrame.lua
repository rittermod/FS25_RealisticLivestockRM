--[[
    RLMenuTransferFrame.lua
    RL Tabbed Menu - Transfer tab (pen/world trailer placements).

    One frame for every trailer placement. The left sidebar is a fixed two-entry
    source picker - the counterpart (a pen/world endpoint) and the trailer - each
    labelled `name (used/total)`. Selecting a side lists that side's animals in a
    multi-select SmoothList (checkbox cell, shared detail pane on the right). A
    single footer action button (Load / Unload by side) routes the checked
    animals to the counterpart adapter.

    Where the counterpart's animals come from and what a confirmed transfer does
    is the adapter's job (RLTransferAdapter); the frame only talks to that seam.
    This shell ships the NULL adapter: the counterpart side lists nothing and the
    action is a logged no-op (no mutation). Concrete pen/world adapters + the
    trigger redirects land in later slices.

    Chrome mirrors RLMenuInfoFrame (sidebar + list container); the multi-select
    data row + footer mirror RLMenuMoveFrame (checkbox cell, onClickSelect /
    onClickSelectAll, the populateCell checkbox callback). The pen + animal detail
    columns reuse RLDetailPaneHelper unchanged; the pen column stays hidden while
    no side supplies a husbandry.
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

    -- In-flight lock: a transfer is a server round-trip in MP, so the action
    -- button (selection-gated, not request-gated) is locked between dispatch and
    -- onTransferComplete to block a duplicate submit. Re-initialized on every open.
    self.movePending       = false

    -- World-counterpart refresh hook (Bug A). The world redirect skips the legacy
    -- controller set, so the trailer's animalScreenController slot is nil and nothing
    -- refreshes the world list when its trigger contents change. On open we claim that
    -- slot (world only) so the trailer drives onAnimalsChanged on this frame after a
    -- load; on close we restore the prior owner. Capture-once + restore-if-self keep it
    -- ownership-safe.
    self.worldRefreshHookInstalled  = false
    self.priorAnimalScreenController = nil

    self.isFrameOpen = false
    self.hasCustomMenuButtons = true

    -- Footer buttons. Back is always present; Select / SelectAll show when the
    -- side has rows. The action splits into two like Move/Buy/Sell: X (EXTRA_1)
    -- transfers the highlighted single row, C (EXTRA_2) transfers the checked set.
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
    -- Single action (X) on EXTRA_1 - the highlighted row - matching the slot the
    -- sibling tabs reserve for the single action. Selected action (C) on EXTRA_2 -
    -- the checked set. Both route through the same dispatchTransfer; the seed text
    -- is the generic load key and updateButtonVisibility overwrites it with the
    -- adapter's dynamic verb per direction.
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


--- Bind the SmoothList datasource/delegate. Fires on both the initial load
--- instance and the FrameReference clone; tree mutation lives in initialize().
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

    -- Per-session reset of the world-refresh hook state. The frame is a reused
    -- singleton; if a prior session's onFrameClose was skipped (RLMenu:onClose wraps
    -- super in pcall, and super is what fires onFrameClose - so a throw before it skips
    -- our uninstall), a stale installed flag would make installWorldRefreshHook below a
    -- no-op and strand the prior capture. Clear (do NOT restore): a leftover self in some
    -- other trailer's slot is harmless - onAnimalsChanged is gated on obj == self.trailer.
    self.worldRefreshHookInstalled  = false
    self.priorAnimalScreenController = nil

    if g_rlMenu ~= nil then
        self.trailer     = g_rlMenu.trailerVehicle
        self.counterpart = g_rlMenu.trailerCounterpart
        -- counterpartHandle is the engine ref a concrete adapter enumerates; the
        -- trigger-redirect slices populate it. nil here (the shell ignores it).
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

    -- Completion callback handed to the move service via the adapter. The closure
    -- captures BOTH the trailer and the counterpart (pen) at open time - the
    -- stale-callback guard: if the frame is closed, OR reopened on a different
    -- trailer, OR reopened on the SAME trailer at a different pen before the server
    -- responds, onTransferComplete drops the callback (no repaint of a reopened
    -- session - the counterpart handle is what varies per session, like the Move
    -- frame's selectedHusbandry identity).
    local dispatchedTrailer = self.trailer
    local dispatchedCounterpart = self.context.counterpartHandle
    self.context.onComplete = function(success, errorText)
        self:onTransferComplete(success, errorText, dispatchedTrailer, dispatchedCounterpart)
    end

    local trailerName = RLTrailerEndpointService.getDisplayData(self.trailer).name
    Log:info("RLMenuTransferFrame:onFrameOpen: counterpart=%s trailer='%s'",
        tostring(self.counterpart), tostring(trailerName))

    -- Reset SmoothList selection sentinels to 0 (the "no selection" sentinel) so
    -- a stale focus index does not leak into the first reload.
    if self.animalList ~= nil then
        self.animalList.selectedSectionIndex = 0
        self.animalList.selectedIndex = 0
    end

    self:refreshSources()

    -- Explicit focus links for keyboard navigation (shared sidebar/list structure
    -- across frames; FocusManager auto-layout otherwise resolves to other frames).
    if self.subCategorySelector ~= nil and self.animalList ~= nil then
        FocusManager:linkElements(self.subCategorySelector, FocusManager.BOTTOM, self.animalList)
        FocusManager:linkElements(self.animalList, FocusManager.TOP, self.subCategorySelector)
    end
    if self.animalList ~= nil then
        FocusManager:setFocus(self.animalList)
    end

    -- Claim the trailer's controller slot (world counterpart only) so the trailer
    -- refreshes the loose-rideable list after a load. Runs after self.trailer/
    -- self.counterpart are set; no-op otherwise.
    self:installWorldRefreshHook()
end


--- Called by the Paging element when this tab is deactivated. Transfer has no
--- sibling tab in MODE_TRAILER, so there is no shared-selection export. Releases
--- the world-refresh controller hook (restore-if-self) before the frame goes idle.
function RLMenuTransferFrame:onFrameClose()
    RLMenuTransferFrame:superClass().onFrameClose(self)
    self.isFrameOpen = false
    self:uninstallWorldRefreshHook()
end


-- =============================================================================
-- World-counterpart refresh hook (Bug A)
-- =============================================================================

--- Whether self.trailer is a live, controller-capable livestock trailer. Guards
--- every trailer/spec deref in the world-refresh lifecycle (install, restore,
--- onAnimalsChanged) so a sold/deleted trailer no-ops instead of dereferencing a
--- torn-down spec. GUI-free (reads self.trailer fields only) so it is unit-testable.
--- @return boolean live
function RLMenuTransferFrame:isTrailerLive()
    return self.trailer ~= nil
        and self.trailer.spec_livestockTrailer ~= nil
        and not self.trailer.isDeleted
        and self.trailer.setAnimalScreenController ~= nil
end


--- Register this frame as the trailer's animalScreenController (via the public
--- setAnimalScreenController setter) so the trailer drives onAnimalsChanged on this
--- frame when its trigger contents change - the world refresh after a load. WORLD
--- counterpart only: the world redirect skips the legacy controller set, so the slot is
--- otherwise nil and the loose-rideable list never refreshes after a load. Ownership-
--- safe: captures the prior controller EXACTLY ONCE (skipped if already installed, or if
--- the slot already holds self) by reading the slot, then installs self through the
--- public setter (never poke the slot to set). No-op for a non-world counterpart or a
--- dead/stale trailer. GUI-free (operates on self.trailer + self.counterpart only) so it
--- is unit-testable.
function RLMenuTransferFrame:installWorldRefreshHook()
    if self.counterpart ~= RLMenu.TRAILER_WORLD then return end
    if not self:isTrailerLive() then
        Log:debug("RLMenuTransferFrame:installWorldRefreshHook: trailer not live, skipping")
        return
    end

    local spec = self.trailer.spec_livestockTrailer
    -- Capture-once within a session: already installed -> nothing to do.
    if self.worldRefreshHookInstalled then return end

    if spec.animalScreenController == self then
        -- The slot already holds self (e.g. a prior cycle left it and the open-time
        -- reset cleared the flag). Adopt it WITHOUT capturing self as the prior - the
        -- paired uninstall reclaims it - so the flag and the slot cannot desync.
        -- (Spec: "skip re-capture if the current controller is already self".)
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


--- Release the controller slot this frame claimed on open. No-op unless installed.
--- Reads the FRAME's captured self.trailer, NEVER g_rlMenu (RLMenu:onClose nils the
--- g_rlMenu trailer fields before super onClose fires onFrameClose). Ownership-safe:
--- restores the captured prior controller ONLY IF the trailer's current controller is
--- still self (a newer owner that claimed the slot while the frame was open is left
--- alone); always clears the frame's own installed flag + prior capture. GUI-free.
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


--- Controller callback the trailer invokes (via setAnimalScreenController) when its
--- trigger contents change: a loaded rideable leaving (the world LOAD case - the loaded
--- animal is removed end-of-frame, then this fires), or a rideable entering/leaving the
--- trigger. Re-enumerates the world source from now-fresh engine state so the list + both
--- (n/n) headers self-correct with no manual flip; prunes any checked identity the
--- mutation removed so the Action button stays honest. Guarded by isFrameOpen +
--- obj == self.trailer + trailer-liveness (our frame outlives a single screen).
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


--- Drop any checked identity no longer present in the freshly rebuilt list. A live
--- trigger mutation (the loaded rideable's deferred delete, or an animal leaving the
--- trigger) can remove a checked animal; pruning keeps updateButtonVisibility honest so
--- the Action button hides when nothing valid remains. Collect-then-delete avoids
--- mutating self.selectedAnimals mid-iteration.
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

--- Recompute the two sidebar entry labels (counterpart + trailer) as
--- `name (used/total)` and push them to the selector WITHOUT re-seeding the side.
--- Keeps the NULL discrimination: a concrete adapter's display NAME is an engine
--- string used verbatim, while the NULL adapter returns an i18n KEY the frame must
--- resolve. Called on open (via refreshSources) and after a transfer completes
--- (counts refresh in place; the active side is preserved - no heuristic re-seed).
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
        -- setState(_, true) fires the onClick (onSourceChanged) UNCONDITIONALLY:
        -- the forced-event flag raises the callback whether or not the index
        -- changed, so this seeds the side in one call for both the index-1 and
        -- index-2 cases (mirrors the Info/Move husbandry seed, which likewise rely
        -- on the forced event and add no no-change branch).
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
    -- Recompute BOTH (n/n) sidebar headers on a side flip (Bug B). Label counts are
    -- capacity-based and selection-independent, so order vs the selection clear is
    -- cosmetic; it belongs with the refresh trio, not above the side assignment.
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


--- The husbandry to pass to the detail-pane animal renderer. Side-aware: the
--- counterpart (pen) side returns context.counterpartHandle so the pen detail
--- column populates; the trailer side returns nil (the trailer has no husbandry,
--- so the pen column stays hidden - the invariant). getAnimalDisplay /
--- updatePenDisplay both tolerate nil.
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

--- Toggle the empty-state text when the active side has no rows. Both sides
--- always have a sidebar entry, so the text gates on rows alone. The list itself
--- stays visible (an empty SmoothList renders no rows but remains a valid focus
--- target, which onFrameOpen sets focus to) - mirrors RLMenuMoveFrame.
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

--- Rebuild the footer button info (Hybrid B visibility). Back always;
--- Select/SelectAll when the side has rows. The two action buttons share the
--- adapter's dynamic verb: the single (X / EXTRA_1) is shown whenever rows exist,
--- disabled with no focused row; the selected (C / EXTRA_2) stays selection-gated -
--- shown only when something is checked, labelled `verb (N)`. (Deliberate divergence
--- from the always-shown-disabled Move/Buy/Sell siblings: the dynamic verb would
--- render two identical buttons at 0 checked.)
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


--- Shared dispatch path for single + bulk (mirrors RLMenuMoveFrame:startMoveFlow).
--- Owns the WHOLE mutation sequence so neither handler touches movePending directly:
--- the in-flight guard, the empty-check, then movePending=true -> adapter:dispatch ->
--- false-return release, in that order. A concrete adapter routes to the move service /
--- load-unload events (async in MP); completion (onTransferComplete) owns the refresh +
--- lock release. The shell NULL adapter logs + returns false, so the frame leaves all
--- state unchanged (no event, no list change).
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

    -- Set the in-flight lock BEFORE dispatch: in SP the move service fires
    -- onTransferComplete SYNCHRONOUSLY inside dispatch (clearing the lock), so
    -- setting it afterwards would strand it true. A `false` return (NULL/world
    -- shell, or a fail-closed guard) means NO completion callback will fire, so
    -- release the lock here.
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


--- Completion callback for an async transfer (mirrors RLMenuMoveFrame:onMoveComplete).
--- The transfer is a server round-trip in MP, so error surfacing + the refresh MUST
--- happen here, not synchronously after dispatch. Guarded against a stale callback on
--- the FULL dispatch context: ignored when the frame is closed, the trailer changed,
--- OR the same trailer reopened on a different counterpart (the counterpart handle is
--- the per-session identity, like the Move frame's selectedHusbandry) - a delayed
--- callback from session A must not repaint a reopened session B. The active adapter
--- resolves its result into a uniform (success, errorText) pair, so this frame is
--- adapter-agnostic: the pen adapter maps its AnimalMoveEvent result and the world
--- service its load/unload result through the SAME contract (the frame references
--- neither result space directly). On failure with text it shows an InfoDialog; either
--- way it releases the in-flight lock, refreshes the (used/total) labels in place (active
--- side preserved - no heuristic re-seed), reloads the list + pen column + buttons, and
--- prunes the selection to the rebuilt list - a successful transfer drops the moved rows
--- while any un-transferred checked rows survive; a failure (list unchanged) leaves the
--- selection intact for a retry.
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
        -- Branch on success FIRST so a failure with NO mapped error text (an unmapped
        -- load/unload code - getErrorText returns nil for those) is still logged as a
        -- failure rather than misclassified as success. The dialog only shows when text
        -- exists (the spec's surface contract); a text-less failure stays silent to the
        -- player but is recorded in the log.
        if errorText ~= nil then
            InfoDialog.show(errorText)
        end
        Log:debug("RLMenuTransferFrame:onTransferComplete: transfer failed (errorText=%s)", tostring(errorText))
    else
        Log:info("RLMenuTransferFrame:onTransferComplete: transfer succeeded")
    end

    self:updateSourceLabels()
    self:reloadAnimalList()
    -- Cardinality-aware selection clear (reuses pruneSelectionToList): the rebuilt list
    -- drops the just-transferred animals, so pruning removes exactly those checked
    -- identities and keeps any un-transferred checked rows (single keeps the rest;
    -- bulk empties). On failure the list is unchanged, so prune is a no-op and the
    -- selection survives for a retry.
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
