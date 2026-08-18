--[[
    RLMenu.lua
    Root controller for the RL Tabbed Menu (standalone TabbedMenu subclass).

    Opened via the RL_MENU input action (default-bound Right Shift + O,
    remappable in Settings -> Controls). ESC closes via the standard FS25
    back-button pattern; the menu does NOT implement toggle-to-close (Fresh's
    quick-view pattern is unsuitable for a destination menu).

    Tabs (Buy, Sell, Move, Manage, AI, Messages, Settings) live under
    frames/ with shared logic under services/.
]]

RLMenu = RLMenu or {}
local RLMenu_mt = Class(RLMenu, TabbedMenu)

-- Store mod directory at source time (g_currentModDirectory is only valid during source())
local modDirectory = g_currentModDirectory

-- Input action name for opening the menu. Declared in modDesc.xml, default-bound Right Shift + O (remappable).
RLMenu.ACTION_NAME = "RL_MENU"

-- Open-mode constants. MODE_FULL is the default; MODE_DEALER hides Move/
-- Messages/Settings tabs via predicate gating so the menu acts as the
-- destination for shop "Buy Animals" and walk-up dealer triggers (the
-- legacy AnimalScreen.show dealer-shape entry redirects here).
RLMenu.MODE_FULL = "full"
RLMenu.MODE_DEALER = "dealer"

-- MODE_TRAILER: a livestock trailer (held as menu context, like dealer mode)
-- drives tab visibility + the anchor per its counterpart. The string value and
-- the visibility/anchor logic are owned by the pure RLMenuTabPolicy (sourced
-- before this file); the menu plumbing (validate, store, open, reset) lives
-- here. M1 keystone: dev/test-reachable only, and only the dealer counterpart
-- actually opens this slice (pen/world rendering lands with the Transfer frame
-- in a later slice).
RLMenu.MODE_TRAILER = RLMenuTabPolicy.MODE_TRAILER

-- Trailer counterparts (where the trailer is parked) re-exported from the pure
-- policy so call sites read RLMenu.TRAILER_* while the policy stays the single
-- source of the string values.
RLMenu.TRAILER_PEN = RLMenuTabPolicy.PEN
RLMenu.TRAILER_DEALER = RLMenuTabPolicy.DEALER
RLMenu.TRAILER_WORLD = RLMenuTabPolicy.WORLD
-- EPP (butcher) direct-open sink counterpart. Routes through the non-dealer
-- Transfer branch of openTrailerFromBridge exactly like pen/world.
RLMenu.TRAILER_EPP = RLMenuTabPolicy.EPP

-- Highest page id registered in setupMenuPages. Used as the upper bound for
-- openFromBridge's startPageId validation. If a tab is added/removed, bump
-- this and renumber setupMenuPages in lockstep -- the spec ASKS to halt on
-- such changes.
RLMenu.PAGE_COUNT = 9

-- Dev-only GUI hot-reload (Mechanism B). When true, open() re-runs the full
-- setupGui() parse so on-disk XML/profile edits show up on reopen with no game
-- restart. Each reload leaks the prior element tree and double-registers its
-- message-center subscriptions, so it is a local-iteration tool only: never commit true.
RLMenu.DEV_RELOAD_XML = false

--- Construct a new RLMenu instance. Called once from setupGui() during mod load.
--- @param target table|nil
--- @param custom_mt table|nil
--- @return table self
function RLMenu.new(target, custom_mt)
    local self = TabbedMenu.new(target, custom_mt or RLMenu_mt)
    self.isOpen = false

    -- Shared selection state across husbandry-based tabs (Info, Move, Sell).
    -- Exported on frame close, imported on frame open. Frames that share the
    -- same husbandry selector pattern can participate by reading/writing this.
    -- { husbandry = placeable ref, animalIdentity = { farmId, uniqueId, country } }
    self.sharedSelection = nil

    -- Open mode: MODE_FULL exposes all 8 tabs (keyboard-shortcut path);
    -- MODE_DEALER hides Move/Messages/Settings via predicate gating
    -- (set by RLMenu.openFromBridge for the AnimalScreen dealer-shape redirect).
    -- Reset to MODE_FULL on every onClose so the next keyboard open is unaffected.
    self.openMode = RLMenu.MODE_FULL

    -- Trailer context (MODE_TRAILER only): the livestock trailer passed at open,
    -- its counterpart (TRAILER_PEN/DEALER/WORLD), and the optional counterpart
    -- engine handle a concrete adapter enumerates (a husbandry placeable / world
    -- set; populated by the per-counterpart trigger-redirect slices, nil in the
    -- shell). Read only at open time for the anchor; all cleared on every onClose
    -- so the next open does not inherit a stale trailer. nil in MODE_FULL / MODE_DEALER.
    self.trailerVehicle = nil
    self.trailerCounterpart = nil
    self.trailerCounterpartHandle = nil

    -- One-shot MODE_FULL husbandry anchor: a caller may land the first husbandry
    -- frame (Info/Move/Sell) on a specific pen by passing context.husbandry to
    -- openFromBridge. The frames capture-and-consume it on their first refresh; it
    -- is also cleared on every onClose and on keyboard open() so a no-anchor open
    -- is byte-for-byte unchanged. nil in MODE_DEALER / MODE_TRAILER. Init here (not
    -- only in openFromBridge) so the DEV_RELOAD re-instantiation - where open() runs
    -- against a fresh instance - starts from a known nil.
    self.anchoredHusbandry = nil

    -- One-shot "opened from the in-game menu Animals frame" flag. When true, a Back/Esc
    -- in onButtonBack returns to the in-game menu (Animals page) instead of closing to
    -- gameplay - restoring the affordance the vanilla animal screen had. Set ONLY in
    -- openFromBridge's committed block (MODE_FULL + context.fromInGameMenu); cleared on
    -- every other open path (open(), onClose, both openTrailerFromBridge store blocks) and
    -- consumed on Back, so no other open is affected. Init here (not only in openFromBridge)
    -- so a DEV_RELOAD re-instantiation starts from a known false.
    self.openedFromInGameMenu = false

    Log:trace("RLMenu.new: instance created (openMode=%s)", tostring(self.openMode))
    return self
end

--- One-time mod-load setup: profiles, frames, and the menu XML.
--- Order matters:
---   1. Profiles must load before any GUI XML that references them
---   2. Frame XMLs must load before the menu XML so FrameReference refs resolve
---   3. Menu XML loads last, linking everything together
--- Called from main.lua at end-of-file after all source() calls complete.
function RLMenu.setupGui()
    Log:debug("RLMenu.setupGui: begin")

    -- 1. Load RL menu profiles (separate file from gui/guiProfiles.xml)
    g_gui:loadProfiles(Utils.getFilename("gui/rlmenu/rlMenuProfiles.xml", modDirectory))

    -- 2. Register frames
    RLMenuMessagesFrame.setupGui()
    RLMenuInfoFrame.setupGui()
    RLMenuMoveFrame.setupGui()
    RLMenuSellFrame.setupGui()
    RLMenuBuyFrame.setupGui()
    RLMenuAIFrame.setupGui()
    RLMenuHerdsmanFrame.setupGui()
    RLMenuSettingsFrame.setupGui()
    RLMenuTransferFrame.setupGui()

    -- 3. Create the menu instance and load its XML
    g_rlMenu = RLMenu.new()
    g_gui:loadGui(
        Utils.getFilename("gui/rlmenu/rlMenu.xml", modDirectory),
        "RLMenu",
        g_rlMenu,
        false -- false = full GUI (not a frame)
    )

    Log:debug("RLMenu.setupGui complete")
end

--- Called by TabbedMenu after all GUI XML has been parsed and bound.
--- Registers tabs with the Paging element.
function RLMenu:onGuiSetupFinished()
    Log:debug("RLMenu:onGuiSetupFinished: binding menu pages")
    RLMenu:superClass().onGuiSetupFinished(self)
    self:setupMenuPages()
end

--- Register each tab with the TabbedMenu Paging system and run its
--- per-instance initialize() on the clone. At this point
--- `self.messagesFrame` / `self.infoFrame` are the live clones produced
--- by Gui:resolveFrameReference. initialize() is optional on frames and
--- no-op when not overridden.
function RLMenu:setupMenuPages()
    local basePredicate = function() return g_currentMission ~= nil end

    -- Closure-captured instance reference. We read self.openMode /
    -- self.trailerCounterpart through this upvalue (NOT g_rlMenu) so the gating
    -- stays bound to the instance and tests can mock without touching globals.
    -- TabbedMenu:updatePages() re-runs predicates on every onOpen, so each is a
    -- pure function of (openMode, counterpart) - no leaks across opens.
    local rlMenu = self

    -- A tab is visible when the engine guard holds AND the pure RLMenuTabPolicy
    -- says so for the current (openMode, counterpart). The policy owns the full
    -- / dealer / trailer matrix (dealer + full behavior is pinned by
    -- the regression suite); this closure is the thin wiring.
    local function visible(pageKey)
        return basePredicate()
            and RLMenuTabPolicy.isVisible(pageKey, rlMenu.openMode, rlMenu.trailerCounterpart)
    end

    -- Wrap each registered predicate so its final per-tab decision is logged at
    -- TRACE. The spec invariant ("every predicate decision logs Log:trace")
    -- means the policy delegation alone is insufficient -- each tab's pass/fail
    -- needs an observable trail at TabbedMenu:updatePages() time, with the
    -- counterpart alongside openMode.
    local function traced(name, fn)
        return function()
            local result = fn()
            Log:trace("RLMenu predicate %s: %s (openMode=%s, counterpart=%s)",
                name, tostring(result), tostring(rlMenu.openMode),
                tostring(rlMenu.trailerCounterpart))
            return result
        end
    end

    -- Buy tab (leftmost - most frequent commerce entry point)
    self:registerPage(self.buyFrame, 1, traced("buy", function() return visible("buy") end))
    self:addPageTab(self.buyFrame, nil, nil, "rlMenu.buy_animal")
    if self.buyFrame ~= nil and self.buyFrame.initialize ~= nil then
        self.buyFrame:initialize()
    end

    -- Sell tab
    self:registerPage(self.sellFrame, 2, traced("sell", function() return visible("sell") end))
    self:addPageTab(self.sellFrame, nil, nil, "rlMenu.sell_animal")
    if self.sellFrame ~= nil and self.sellFrame.initialize ~= nil then
        self.sellFrame:initialize()
    end

    -- Move tab (full mode only)
    self:registerPage(self.moveFrame, 3, traced("move", function() return visible("move") end))
    self:addPageTab(self.moveFrame, nil, nil, "rlMenu.move_animal")
    if self.moveFrame ~= nil and self.moveFrame.initialize ~= nil then
        self.moveFrame:initialize()
    end

    -- Manage tab (Info)
    self:registerPage(self.infoFrame, 4, traced("info", function() return visible("info") end))
    self:addPageTab(self.infoFrame, nil, nil, "rlMenu.info_animal")
    if self.infoFrame ~= nil and self.infoFrame.initialize ~= nil then
        self.infoFrame:initialize()
    end

    -- AI tab
    self:registerPage(self.aiFrame, 5, traced("ai", function() return visible("ai") end))
    self:addPageTab(self.aiFrame, nil, nil, "rlMenu.manage_animal")
    if self.aiFrame ~= nil and self.aiFrame.initialize ~= nil then
        self.aiFrame:initialize()
    end

    -- Messages tab (full mode only)
    self:registerPage(self.messagesFrame, 6, traced("messages", function() return visible("messages") end))
    self:addPageTab(self.messagesFrame, nil, nil, "rlMenu.notify_animal")
    if self.messagesFrame ~= nil and self.messagesFrame.initialize ~= nil then
        self.messagesFrame:initialize()
    end

    -- Herdsman tab (automated rules editor; full mode only)
    self:registerPage(self.herdsmanFrame, 7, traced("herdsman", function() return visible("herdsman") end))
    self:addPageTab(self.herdsmanFrame, nil, nil, "rlMenu.herdsman")
    if self.herdsmanFrame ~= nil and self.herdsmanFrame.initialize ~= nil then
        self.herdsmanFrame:initialize()
    end

    -- Settings tab (tail - hosts the saveable-filters editor; full mode only)
    self:registerPage(self.settingsFrame, 8, traced("settings", function() return visible("settings") end))
    self:addPageTab(self.settingsFrame, nil, nil, "gui.icon_options_generalSettings")
    if self.settingsFrame ~= nil and self.settingsFrame.initialize ~= nil then
        self.settingsFrame:initialize()
    end

    -- Transfer tab (page 9; visible only in MODE_TRAILER pen/world). Reuses the
    -- move_animal icon (Move and Transfer never appear together on screen).
    self:registerPage(self.transferFrame, 9, traced("transfer", function() return visible("transfer") end))
    self:addPageTab(self.transferFrame, nil, nil, "rlMenu.move_animal")
    if self.transferFrame ~= nil and self.transferFrame.initialize ~= nil then
        self.transferFrame:initialize()
    end

    Log:debug(
        "RLMenu:setupMenuPages: 9 pages registered (buy, sell, move, manage, ai, messages, herdsman, settings, transfer); visibility delegated to RLMenuTabPolicy per (openMode, counterpart)")
end

--- Configure the bottom button bar.
--- ESC-only Back button; no toggle-to-close action. The footer shows
--- "ESC - Back" while the menu is open, matching every other FS25 tabbed menu.
function RLMenu:setupMenuButtonInfo()
    Log:debug("RLMenu:setupMenuButtonInfo: wiring back button")
    RLMenu:superClass().setupMenuButtonInfo(self)

    self.clickBackCallback = self:makeSelfCallback(self.onButtonBack)

    self.backButtonInfo = {
        inputAction = InputAction.MENU_BACK,
        text = g_i18n:getText("button_back"),
        callback = self.clickBackCallback,
    }

    self.defaultMenuButtonInfo = { self.backButtonInfo }
    self.defaultMenuButtonInfoByActions[InputAction.MENU_BACK] = self.backButtonInfo
    self.defaultButtonActionCallbacks = {
        [InputAction.MENU_BACK] = self.clickBackCallback,
    }
end

--- Back button callback (ESC or clicking the Back footer button).
--- If this open originated from the in-game menu Animals frame (openedFromInGameMenu),
--- redirect Back/Esc to the in-game menu (Animals page) instead of closing to gameplay,
--- mirroring the vanilla animal screen's onClickBack. Consume the one-shot flag FIRST so
--- the redirect-driven onClose sees it false; on a showGui throw, fall back to exitMenu
--- (close to gameplay) rather than strand the player. Every other open leaves the flag
--- false and closes to gameplay as before.
function RLMenu:onButtonBack()
    if self.openedFromInGameMenu then
        self.openedFromInGameMenu = false
        Log:debug("RLMenu:onButtonBack: opened from in-game menu -> returning to InGameMenu")
        local ok = pcall(function() g_gui:showGui("InGameMenu") end)
        if not ok then
            Log:warning("RLMenu:onButtonBack: showGui(InGameMenu) threw, falling back to exitMenu")
            self:exitMenu()
        end
        return
    end
    Log:debug("RLMenu:onButtonBack: closing menu via back")
    self:exitMenu()
end

--- Called by the GUI manager when the menu becomes visible.
--- Tracks open state for the open() no-op guard.
function RLMenu:onOpen()
    RLMenu:superClass().onOpen(self)
    self.isOpen = true
    Log:info("RLMenu opened")
end

--- Called by the GUI manager when the menu is closing.
--- Clears open state + resets per-frame saved-filter session state
---.
function RLMenu:onClose()
    -- Saved-filter session reset across the 4 consumer frames. Runs before
    -- superClass().onClose so frame references are still live. Nil-guards
    -- each frame (early-init edge case: menu close before a frame finished
    -- .new()).
    local frames = { self.infoFrame, self.buyFrame, self.sellFrame, self.moveFrame }
    local cleared = 0
    for _, f in ipairs(frames) do
        if f ~= nil and f.activeFilterId ~= nil then
            f.activeFilterId = nil
            f.activeFilter = nil
            cleared = cleared + 1
        end
    end
    if cleared > 0 then
        Log:debug("RLMenu:onClose: reset activeFilterId on %d frame(s)", cleared)
    end

    -- Save-from-QF handshake cleanup. openSettingsFilter stashes pendingSelectedFilterId
    -- and then asks the page selector to switch to Settings. RLMenuSettingsFrame:onFrameOpen
    -- consumes-and-clears the id on the next open. If the user ESCs out of the menu
    -- between the Save and Settings paint (or any failure interleaves), a leftover id
    -- would hijack-select an unrelated filter on the next legitimate menu open.
    -- Cleared here so the next open always starts clean.
    if self.pendingSelectedFilterId ~= nil then
        Log:debug("RLMenu:onClose: clearing leftover pendingSelectedFilterId=%s",
            tostring(self.pendingSelectedFilterId))
        self.pendingSelectedFilterId = nil
    end

    -- Clear the cross-frame shared filter id too so the next menu open starts
    -- clean. Info/Move/Sell read + write sharedSelection.activeFilterId for
    -- tab-switch preservation.
    if self.sharedSelection ~= nil and self.sharedSelection.activeFilterId ~= nil then
        Log:debug("RLMenu:onClose: clearing sharedSelection.activeFilterId=%s",
            tostring(self.sharedSelection.activeFilterId))
        self.sharedSelection.activeFilterId = nil
    end

    -- Capture dealer-mode state BEFORE super onClose so we can decide whether
    -- to force a Buy-tab anchor on next open. Reset openMode here too so any
    -- frame close hooks invoked by super see MODE_FULL (predicate-gated tabs
    -- that may run logic on close should not see leaked dealer state).
    local wasDealer = (self.openMode == RLMenu.MODE_DEALER)
    local wasTrailer = (self.openMode == RLMenu.MODE_TRAILER)
    self.openMode = RLMenu.MODE_FULL

    -- Clear trailer context here too (nil already in non-trailer modes): a
    -- trailer close must not leak the trailer/counterpart/handle into the next
    -- open, and frame-close hooks invoked by super should see no stale trailer.
    self.trailerVehicle = nil
    self.trailerCounterpart = nil
    self.trailerCounterpartHandle = nil

    -- Clear the one-shot husbandry anchor here too (pre-pcall, beside the trailer
    -- fields so a super-onClose throw cannot skip it): a bridged MODE_FULL open
    -- that never reached a husbandry frame must not leak its anchor into the next
    -- open. hadAnchor is surfaced in the log below so a dropped-unconsumed anchor
    -- is visible.
    local hadAnchor = (self.anchoredHusbandry ~= nil)
    self.anchoredHusbandry = nil

    -- Clear the from-menu flag defensively for ANY non-Back close (Back consumes it in
    -- onButtonBack before triggering this onClose; this also covers a close that bypasses
    -- onButtonBack, e.g. a changeScreen from elsewhere) so it never leaks into the next
    -- open. Pre-pcall, beside the anchor clear, so a super-onClose throw cannot skip it.
    self.openedFromInGameMenu = false

    -- Wrap super-onClose in pcall: base TabbedMenu:onClose touches
    -- currentPage:onFrameClose(), g_inputBinding, pageSelector:getState(),
    -- and g_currentMission:resetGameState(). Any one of those can nil-deref
    -- in a torn-down session and would skip the wasDealer force-reset below,
    -- leaking dealer-mode page anchoring into the next open. pcall makes the
    -- force-reset unconditional.
    local superOk, superErr = pcall(function() RLMenu:superClass().onClose(self) end)
    if not superOk then
        Log:warning("RLMenu:onClose: super-onClose threw (err=%s); continuing close",
            tostring(superErr))
    end

    -- Force restorePageIndex = 1 AFTER super onClose: TabbedMenu:onClose
    -- overwrites self.restorePageIndex with self.pageSelector:getState() (a
    -- VISIBLE-tab index). Dealer-mode visible indices differ from full-mode
    -- (e.g. dealer AI sits at visible index 4 where full-mode index 4 is
    -- Info), so a naive snapshot would mode-cross the next shortcut-open onto
    -- the wrong tab. Anchoring at 1 (Buy) is predictable for both modes.
    -- Trailer mode shares the dealer force: its collapsed visible set (e.g.
    -- {Buy, Sell} at the dealer counterpart) also differs from full-mode
    -- indices, and TabbedMenu:onOpen reads restorePage before restorePageIndex,
    -- so BOTH must be cleared or a stale restorePage re-introduces the mode-cross.
    if wasDealer or wasTrailer then
        self.restorePageIndex = 1
        self.restorePage = nil
    end
    Log:debug("RLMenu:onClose: openMode reset (wasDealer=%s, wasTrailer=%s, hadAnchor=%s, restorePageIndex=%s, superOk=%s)",
        tostring(wasDealer), tostring(wasTrailer), tostring(hadAnchor), tostring(self.restorePageIndex), tostring(superOk))

    self.isOpen = false
    Log:info("RLMenu closed")
end

--- Show the menu. No-op if any GUI is already visible to avoid stacking.
--- Invoked by the RL_MENU input action callback.
function RLMenu.open()
    if g_gui:getIsGuiVisible() then
        Log:trace("RLMenu.open: skipped, a GUI is already visible")
        return
    end

    -- Dev hot-reload: re-parse profiles + frames + menu so on-disk XML edits
    -- appear on reopen (gated by DEV_RELOAD_XML, off in release). The
    -- g_gui.currentlyReloading flag MUST bracket the re-parse: without it,
    -- re-loading rlMenuProfiles.xml silently keeps the previously-loaded
    -- profile values, so on-disk edits to existing profiles are dropped. Reset
    -- it on BOTH the success and the throw path -- a stuck `true` makes later
    -- loadProfiles calls silently keep the prior values, so the pcall
    -- guarantees the reset even if setupGui() errors.
    if RLMenu.DEV_RELOAD_XML then
        Log:debug("RLMenu.open: DEV reloading GUI XML (profiles + frames + menu)")
        g_gui.currentlyReloading = true
        local ok, err = pcall(RLMenu.setupGui)
        g_gui.currentlyReloading = false
        if not ok then
            Log:error("RLMenu.open: DEV reload failed (err=%s)", tostring(err))
        end
    end

    -- Keyboard open always starts unanchored: drop any one-shot husbandry anchor a
    -- prior bridged-then-ESC'd MODE_FULL session may have left. UNCONDITIONAL (only
    -- guarded on g_rlMenu ~= nil) - it MUST sit OUTSIDE the stale-mode reset below,
    -- which fires only for a parked non-FULL openMode; a normal FULL keyboard open
    -- would otherwise inherit the anchor and hijack the next husbandry frame.
    if g_rlMenu ~= nil then
        g_rlMenu.anchoredHusbandry = nil
        -- Same one-shot discipline as the anchor: a prior bridged-then-ESC'd from-menu
        -- session must not leak its flag into a keyboard open. UNCONDITIONAL, OUTSIDE the
        -- stale-mode block below, so a normal FULL keyboard open still clears it -> Back
        -- closes to gameplay.
        g_rlMenu.openedFromInGameMenu = false
    end

    -- Keyboard-open stale-mode reset. A parked non-FULL openMode (e.g. a
    -- MODE_TRAILER whose onClose never fired) would otherwise strand the full
    -- menu on a collapsed tab set with no valid landing tab. Reset to MODE_FULL +
    -- clear the trailer context + anchor Buy. Placed AFTER the DEV_RELOAD re-setup
    -- (which reassigns g_rlMenu) so the reset is not wiped, and immediately before
    -- showGui. An already-FULL open is left untouched (its restore state is the
    -- intended one).
    if g_rlMenu ~= nil and g_rlMenu.openMode ~= RLMenu.MODE_FULL then
        Log:debug("RLMenu.open: stale openMode=%s on keyboard open, resetting to MODE_FULL",
            tostring(g_rlMenu.openMode))
        g_rlMenu.openMode = RLMenu.MODE_FULL
        g_rlMenu.trailerVehicle = nil
        g_rlMenu.trailerCounterpart = nil
        g_rlMenu.trailerCounterpartHandle = nil
        g_rlMenu.restorePageIndex = 1
        g_rlMenu.restorePage = nil
    end

    Log:debug("RLMenu.open: showing menu")
    g_gui:showGui("RLMenu")
end

--- Open the RL Menu from another GUI surface (the AnimalScreen routing bridge). Calls
--- `g_gui:showGui` directly to REPLACE a non-dialog screen (e.g. the shop menu). Dialog
--- gating still applies: if a modal dialog (YesNoDialog, AnimalFilterDialog, etc.) is up,
--- the bridge bails (returns false) -- replacing the underlying screen would leave the
--- dialog floating over RLMenu with no owner. State mutations to g_rlMenu happen ONLY after
--- we've decided to show, and are rolled back if showGui throws (so a partial show does not
--- poison the next legitimate open). There is NO vanilla fallback: a refused open returns
--- false and the caller WARN-no-ops.
---
--- @param startPageId number Page index in [1, RLMenu.PAGE_COUNT] to land on (Buy=1).
---   IGNORED for MODE_TRAILER (the anchor is heuristic-derived; callers pass nil).
--- @param mode string RLMenu.MODE_FULL, RLMenu.MODE_DEALER, or RLMenu.MODE_TRAILER.
--- @param context table|nil For MODE_TRAILER: { trailer = <livestock-trailer vehicle>,
---   counterpart = RLMenu.TRAILER_PEN | TRAILER_DEALER | TRAILER_WORLD, counterpartHandle =
---   <optional pen husbandry the concrete adapter enumerates; nil for dealer/world> }. For
---   MODE_FULL: an optional { husbandry = <local animal-husbandry placeable>, fromInGameMenu =
---   <boolean> } table. `husbandry` is a one-shot anchor that lands the first husbandry frame
---   (Info/Move/Sell) on that pen (ignored unless it is a real animal husbandry).
---   `fromInGameMenu = true` marks an open originating from the in-game menu Animals frame so
---   Back/Esc returns there (via onButtonBack) instead of closing to gameplay; one-shot, cleared
---   on every other open path. Ignored for MODE_DEALER (no state stored).
--- @return boolean opened  true when the menu was shown; false on any refused open
---   (g_rlMenu nil, bad args, a dialog visible, or a showGui rollback) so a caller may branch
---   on it (the LivestockTrailerActivatable redirect logs its decision only on true and
---   WARN-no-ops on false -- there is no vanilla fallback). The MODE_TRAILER branch
---   propagates openTrailerFromBridge's result.
function RLMenu.openFromBridge(startPageId, mode, context)
    -- Mod load order regression: setupGui() not yet completed when bridge
    -- fires. Caller WARN-no-ops if we early-out (there is no vanilla fallback).
    if g_rlMenu == nil then
        Log:warning("openFromBridge: g_rlMenu nil, no-op (no vanilla fallback)")
        return false
    end

    -- MODE_TRAILER takes a dedicated, context-driven path (ordered validation,
    -- heuristic anchor, no startPageId). Branch here so the existing FULL /
    -- DEALER callers below stay byte-identical. Propagate its opened/refused result.
    if mode == RLMenu.MODE_TRAILER then
        return RLMenu.openTrailerFromBridge(context)
    end

    local validMode = (mode == RLMenu.MODE_FULL or mode == RLMenu.MODE_DEALER)
    local validPage = (type(startPageId) == "number"
        and startPageId >= 1 and startPageId <= RLMenu.PAGE_COUNT)

    if not validMode or not validPage then
        Log:warning("openFromBridge: bad args mode=%s page=%s",
            tostring(mode), tostring(startPageId))
        return false
    end

    -- Dialog gate: replacing the underlying screen via showGui leaves any
    -- active dialog floating, with input focus stuck on the dialog and no
    -- valid owner-screen. Bail (return false; the caller WARN-no-ops) rather
    -- than paint RLMenu under a stale dialog.
    if g_gui.getIsDialogVisible ~= nil and g_gui:getIsDialogVisible() then
        Log:warning("openFromBridge: a dialog is visible, no-op (no vanilla fallback)")
        return false
    end

    -- Snapshot prior state so we can roll back if showGui throws. Without
    -- this, a failed open leaves g_rlMenu poisoned -- the next keyboard
    -- open would inherit dealer-mode tab gating and page-1 anchor.
    local priorOpenMode = g_rlMenu.openMode
    local priorRestorePageIndex = g_rlMenu.restorePageIndex
    local priorRestorePage = g_rlMenu.restorePage
    local priorAnchoredHusbandry = g_rlMenu.anchoredHusbandry
    local priorOpenedFromInGameMenu = g_rlMenu.openedFromInGameMenu

    -- MODE_FULL husbandry anchor (one-shot): a caller may pass context.husbandry
    -- to land the first husbandry frame (Info/Move/Sell) on a specific pen. Set
    -- fail-closed - ONLY a table context carrying a real animal husbandry anchors:
    --   * mode ~= MODE_FULL (i.e. MODE_DEALER) never anchors;
    --   * a non-table context is never dereferenced (no crash);
    --   * a context.husbandry that is not an animal husbandry (no
    --     spec_husbandryAnimals) opens unanchored with a WARNING.
    -- Otherwise nil, so no stale anchor leaks into a later open. The husbandry
    -- frames capture-and-consume it once; onClose / open() clear it. context.husbandry
    -- MUST be the caller's LOCAL placeable (frames match by ==, so a server handle
    -- on a pure client would miss); no MP sync - the anchor is per-client GUI state.
    local anchorHusbandry = nil
    if mode == RLMenu.MODE_FULL and type(context) == "table" and context.husbandry ~= nil then
        -- Guard the deref: a non-table context.husbandry (a number / boolean
        -- sentinel) must fail closed to an unanchored open, never crash - the
        -- spec_husbandryAnimals read below would otherwise throw outside the pcall.
        if type(context.husbandry) == "table" and context.husbandry.spec_husbandryAnimals ~= nil then
            anchorHusbandry = context.husbandry
        else
            Log:warning("openFromBridge: husbandry anchor invalid (not an animal husbandry), opening unanchored")
        end
    end

    -- Force restorePageIndex over restorePage: TabbedMenu:onOpen reads
    -- restorePage first, so clearing it makes
    -- pageSelector:setState(restorePageIndex, true) the authoritative path.
    g_rlMenu.openMode = mode
    g_rlMenu.restorePageIndex = startPageId
    g_rlMenu.restorePage = nil
    g_rlMenu.anchoredHusbandry = anchorHusbandry

    -- One-shot in-game-menu origin flag: set ONLY here (after the arg/dialog refusal gates
    -- above, so a refused open is zero-mutation). True only for a MODE_FULL open whose context
    -- explicitly carries fromInGameMenu = true (the in-game menu Animals frame's open action);
    -- every other open (keyboard, dealer, trailer) leaves it false, so Back closes to gameplay.
    -- Consumed + cleared in onButtonBack; also cleared on open()/onClose/both trailer blocks;
    -- snapshotted as priorOpenedFromInGameMenu above + restored on the showGui-throw rollback.
    g_rlMenu.openedFromInGameMenu =
        (mode == RLMenu.MODE_FULL and type(context) == "table" and context.fromInGameMenu == true)
    if g_rlMenu.openedFromInGameMenu then
        Log:debug("openFromBridge: opened from the in-game menu -> Back will return to InGameMenu")
    end

    if anchorHusbandry ~= nil then
        Log:info("openFromBridge: page=%d mode=%s (husbandry anchor set for the next husbandry frame)",
            startPageId, tostring(mode))
    else
        Log:info("openFromBridge: page=%d mode=%s", startPageId, tostring(mode))
    end

    local ok, err = pcall(function() g_gui:showGui("RLMenu") end)
    if not ok then
        Log:warning("openFromBridge: showGui threw, rolling back state (err=%s)",
            tostring(err))
        g_rlMenu.openMode = priorOpenMode
        g_rlMenu.restorePageIndex = priorRestorePageIndex
        g_rlMenu.restorePage = priorRestorePage
        g_rlMenu.anchoredHusbandry = priorAnchoredHusbandry
        g_rlMenu.openedFromInGameMenu = priorOpenedFromInGameMenu
        return false
    end
    return true
end

--- MODE_TRAILER entry: validate the trailer context, store it, and open the
--- menu. The DEALER counterpart anchors Buy or Sell per the trailer's emptiness;
--- the PEN / WORLD counterparts anchor the Transfer tab (their sole visible tab).
---
--- Validation runs in order and warns-and-returns with ZERO state change on any
--- failure (the caller WARN-no-ops; there is no vanilla fallback): (1) nil/invalid
--- context, BEFORE any context.* deref; (2) trailer nil or not a livestock trailer; (3)
--- counterpart not one of TRAILER_PEN/DEALER/WORLD; (4) a dialog is visible. The
--- dealer anchor reads emptiness via RLTrailerEndpointService.isEmpty - mandatory,
--- no fallback. Step (2) checks the livestock-trailer spec is
--- present (a real such trailer always exposes the count getter), so in practice
--- "empty" means a real empty trailer; the service's safe default for an
--- unreadable count (-> empty -> Buy) is the intended fallback, not a bug.
--- @param context table|nil { trailer = <livestock-trailer vehicle>, counterpart = TRAILER_*,
---   counterpartHandle = <optional pen husbandry the PEN adapter enumerates; nil for dealer/world> }
--- @return boolean opened  true when the menu was shown; false on any refused open
---   (invalid context / trailer / counterpart, a dialog visible, or a showGui
---   rollback) with ZERO state change, so the caller WARN-no-ops (no vanilla fallback).
function RLMenu.openTrailerFromBridge(context)
    -- (1) nil/invalid context guard - returns BEFORE any context.* index.
    if type(context) ~= "table" then
        Log:warning("openFromBridge[trailer]: nil/invalid context, no-op (no vanilla fallback)")
        return false
    end

    -- (2) trailer must be a readable livestock trailer (the getter surface the
    -- RLTrailerEndpointService resolves). A non-livestock vehicle is rejected
    -- here, never reaching the anchor read.
    local trailer = context.trailer
    if trailer == nil or trailer.spec_livestockTrailer == nil then
        Log:warning("openFromBridge[trailer]: context.trailer nil or not a livestock trailer, no-op (no vanilla fallback)")
        return false
    end

    -- (3) counterpart must be exactly one of the four constants (nil or any
    -- other value is invalid). EPP (butcher sink) is accepted here and then routed
    -- through the non-dealer Transfer branch below (restorePageIndex = 1), the same
    -- as pen/world.
    local counterpart = context.counterpart
    if counterpart ~= RLMenu.TRAILER_PEN
        and counterpart ~= RLMenu.TRAILER_DEALER
        and counterpart ~= RLMenu.TRAILER_WORLD
        and counterpart ~= RLMenu.TRAILER_EPP then
        Log:warning("openFromBridge[trailer]: invalid counterpart=%s, no-op (no vanilla fallback)",
            tostring(counterpart))
        return false
    end

    -- (4) Dialog gate: same rationale as the FULL/DEALER path - replacing the
    -- underlying screen would strand a floating dialog with no owner.
    if g_gui.getIsDialogVisible ~= nil and g_gui:getIsDialogVisible() then
        Log:warning("openFromBridge[trailer]: a dialog is visible, no-op (no vanilla fallback)")
        return false
    end

    local trailerName = RLTrailerEndpointService.getDisplayData(trailer).name

    if counterpart ~= RLMenu.TRAILER_DEALER then
        -- pen/world: Transfer (their only tab) is registered, so the resolved
        -- visible set is exactly {Transfer} = visible index 1. Open anchored there.
        -- restorePageIndex AND restorePage must BOTH be set: TabbedMenu:onOpen reads
        -- restorePage first, so a stale restorePage would mode-cross onto a wrong
        -- collapsed index. The index-1 anchor rests on Transfer being the SOLE
        -- pen/world tab (the policy hides all 8 others); a future pen/world tab
        -- must revisit this. Snapshot for rollback if showGui throws (mirrors the
        -- dealer branch below).
        local priorOpenMode = g_rlMenu.openMode
        local priorRestorePageIndex = g_rlMenu.restorePageIndex
        local priorRestorePage = g_rlMenu.restorePage
        local priorTrailerVehicle = g_rlMenu.trailerVehicle
        local priorTrailerCounterpart = g_rlMenu.trailerCounterpart
        local priorTrailerCounterpartHandle = g_rlMenu.trailerCounterpartHandle
        local priorAnchoredHusbandry = g_rlMenu.anchoredHusbandry
        local priorOpenedFromInGameMenu = g_rlMenu.openedFromInGameMenu

        g_rlMenu.openMode = RLMenu.MODE_TRAILER
        g_rlMenu.trailerVehicle = trailer
        g_rlMenu.trailerCounterpart = counterpart
        -- The counterpart engine handle a concrete adapter enumerates (the pen
        -- husbandry for the pen redirect; nil for world). Moves in
        -- lockstep with the other two trailer fields - stored here, cleared in
        -- onClose + the keyboard reset, rolled back below on a showGui throw.
        g_rlMenu.trailerCounterpartHandle = context.counterpartHandle
        -- Trailer mode never anchors a husbandry; clear defensively so this entry
        -- point establishes a known anchor state (a prior unconsumed MODE_FULL
        -- anchor must not survive into a trailer open).
        g_rlMenu.anchoredHusbandry = nil
        -- Trailer mode never returns to the in-game menu; clear the from-menu flag in
        -- lockstep with the anchor so a prior from-menu open cannot leak Back-to-InGameMenu.
        g_rlMenu.openedFromInGameMenu = false
        g_rlMenu.restorePageIndex = 1
        g_rlMenu.restorePage = nil

        Log:info("openFromBridge[trailer]: counterpart=%s trailer='%s' -> Transfer (page 1)",
            tostring(counterpart), tostring(trailerName))

        local ok, err = pcall(function() g_gui:showGui("RLMenu") end)
        if not ok then
            Log:warning("openFromBridge[trailer]: showGui threw, rolling back state (err=%s)",
                tostring(err))
            g_rlMenu.openMode = priorOpenMode
            g_rlMenu.restorePageIndex = priorRestorePageIndex
            g_rlMenu.restorePage = priorRestorePage
            g_rlMenu.trailerVehicle = priorTrailerVehicle
            g_rlMenu.trailerCounterpart = priorTrailerCounterpart
            g_rlMenu.trailerCounterpartHandle = priorTrailerCounterpartHandle
            g_rlMenu.anchoredHusbandry = priorAnchoredHusbandry
            g_rlMenu.openedFromInGameMenu = priorOpenedFromInGameMenu
            return false
        end
        return true
    end

    -- DEALER counterpart: snapshot for rollback (incl. trailer-context fields),
    -- anchor Buy (empty) / Sell (loaded) via the pure policy off the mandatory
    -- isEmpty read, then open. restorePage cleared so TabbedMenu:onOpen uses
    -- restorePageIndex (it reads restorePage first).
    local priorOpenMode = g_rlMenu.openMode
    local priorRestorePageIndex = g_rlMenu.restorePageIndex
    local priorRestorePage = g_rlMenu.restorePage
    local priorTrailerVehicle = g_rlMenu.trailerVehicle
    local priorTrailerCounterpart = g_rlMenu.trailerCounterpart
    local priorTrailerCounterpartHandle = g_rlMenu.trailerCounterpartHandle
    local priorAnchoredHusbandry = g_rlMenu.anchoredHusbandry
    local priorOpenedFromInGameMenu = g_rlMenu.openedFromInGameMenu

    local isEmpty = RLTrailerEndpointService.isEmpty(trailer)
    local anchor = RLMenuTabPolicy.anchorPage(counterpart, isEmpty)

    g_rlMenu.openMode = RLMenu.MODE_TRAILER
    g_rlMenu.trailerVehicle = trailer
    g_rlMenu.trailerCounterpart = counterpart
    -- nil for the dealer counterpart (no pen/world handle); stored in lockstep
    -- with the other two trailer fields so the reset sites clear all three.
    g_rlMenu.trailerCounterpartHandle = context.counterpartHandle
    -- Trailer mode never anchors a husbandry; clear defensively so this entry
    -- point establishes a known anchor state (a prior unconsumed MODE_FULL anchor
    -- must not survive into a trailer open).
    g_rlMenu.anchoredHusbandry = nil
    -- Trailer mode never returns to the in-game menu; clear the from-menu flag in
    -- lockstep with the anchor so a prior from-menu open cannot leak Back-to-InGameMenu.
    g_rlMenu.openedFromInGameMenu = false
    g_rlMenu.restorePageIndex = anchor
    g_rlMenu.restorePage = nil

    Log:debug("openFromBridge[trailer]: dealer anchor isEmpty=%s -> page %d",
        tostring(isEmpty), anchor)
    Log:info("openFromBridge[trailer]: counterpart=%s trailer='%s' anchor=%d",
        tostring(counterpart), tostring(trailerName), anchor)

    local ok, err = pcall(function() g_gui:showGui("RLMenu") end)
    if not ok then
        Log:warning("openFromBridge[trailer]: showGui threw, rolling back state (err=%s)",
            tostring(err))
        g_rlMenu.openMode = priorOpenMode
        g_rlMenu.restorePageIndex = priorRestorePageIndex
        g_rlMenu.restorePage = priorRestorePage
        g_rlMenu.trailerVehicle = priorTrailerVehicle
        g_rlMenu.trailerCounterpart = priorTrailerCounterpart
        g_rlMenu.trailerCounterpartHandle = priorTrailerCounterpartHandle
        g_rlMenu.anchoredHusbandry = priorAnchoredHusbandry
        g_rlMenu.openedFromInGameMenu = priorOpenedFromInGameMenu
        return false
    end
    return true
end

--- Switch the menu to Settings -> Filters with a specific saved-filter id
--- pre-selected. Invoked from AnimalFilterDialog:doCreateAndNavigate after the
--- service `:create` succeeds.
---
--- The handshake is a two-step relay:
---   1. Here: stash `pendingSelectedFilterId` on the menu instance, then ask
---      the pageSelector to switch to Settings (page id 8).
---   2. RLMenuSettingsFrame:onFrameOpen consumes-and-clears the id BEFORE its
---      refreshData call so resolveSelectionById lights the new row in the
---      same pass; at the end of onFrameOpen it flips the subCategoryPaging
---      to FILTERS so the editor lands on the new filter.
---
--- `MultiTextOptionElement:setState(state, true)` returns nil (no refusal value
--- to branch on); the MODE_FULL gate on the Save filter button guarantees Settings
--- is reachable when this fires, so there is no "setState refused" path to clean
--- up from. The matched cleanup for the ESC-during-handshake race lives in `onClose`.
--- @param filterId string saved-filter id (return value of g_rlFilterService:create)
function RLMenu:openSettingsFilter(filterId)
    if self.pageSelector == nil then
        Log:warning("RLMenu:openSettingsFilter: pageSelector nil; aborting (filterId=%s)",
            tostring(filterId))
        return
    end
    self.pendingSelectedFilterId = filterId
    self.pageSelector:setState(8, true)
    Log:info("RLMenu:openSettingsFilter: filterId=%s (switched to Settings tab)",
        tostring(filterId))
end

-- =============================================================================
-- INPUT BINDING
-- =============================================================================

--- Input action callback registered via PlayerInputComponent hook.
--- Called by FS25's input system when the user presses the key bound to RL_MENU.
--- @param playerInputComponent table The player input component (unused)
--- @param controlling string Input context ("VEHICLE", "PLAYER", etc.)
function RLMenu.addPlayerActionEvents(playerInputComponent, controlling)
    local triggerUp = false     -- Don't trigger on key release
    local triggerDown = true    -- Trigger on key press
    local triggerAlways = false -- Not continuous
    local startActive = true    -- Active from start
    local callbackState = nil
    local disableConflictingBindings = true

    local success, actionEventId = g_inputBinding:registerActionEvent(
        RLMenu.ACTION_NAME,
        RLMenu,
        RLMenu.open,
        triggerUp, triggerDown, triggerAlways, startActive,
        callbackState, disableConflictingBindings
    )

    if not success then
        -- registerActionEvent has been observed to return false even when
        -- registration succeeded for the VEHICLE context. A non-empty
        -- actionEventId on failure usually means a duplicate registration (benign).
        if controlling == "VEHICLE" or (actionEventId ~= nil and actionEventId ~= "") then
            Log:trace("RLMenu.addPlayerActionEvents: registration returned false (controlling=%s, eventId=%s)",
                tostring(controlling), tostring(actionEventId))
        else
            Log:debug("RLMenu.addPlayerActionEvents: RL_MENU action NOT registered (controlling=%s)",
                tostring(controlling))
        end
        return
    end

    -- Hide the action event text from the HUD (we don't want a screen-edge hint)
    g_inputBinding:setActionEventTextVisibility(actionEventId, false)
    Log:debug("RLMenu.addPlayerActionEvents: RL_MENU action registered, eventId=%s",
        tostring(actionEventId))
end

--- Install the PlayerInputComponent and loadMap hooks.
--- Called once from main.lua at end-of-file before the TESTING block.
---
--- Two hooks installed:
---   1. PlayerInputComponent.registerGlobalPlayerActionEvents - so `RL_MENU` is
---      registered whenever a player input context is created.
---   2. RealisticLivestock.loadMap - defers `RLMenu.setupGui()` until AFTER
---      RealisticLivestock.loadMap has registered the `rlMenu` texture
---      config. Without this hook ordering, setupGui parses rlMenu.xml's
---      `imageSliceId="rlMenu.buy_animal"` before the texture namespace
---      exists, emitting `Warning: No texture config with prefix 'rlMenu'
---      found` at mod load. The warning was harmless in practice but noisy.
---      Hooking into loadMap resolves the ordering cleanly.
---
--- Idempotency: main.lua sources this file exactly once, so install() runs exactly once;
--- re-entry is not a supported scenario and would double-append both hooks.
function RLMenu.install()
    PlayerInputComponent.registerGlobalPlayerActionEvents = Utils.appendedFunction(
        PlayerInputComponent.registerGlobalPlayerActionEvents,
        RLMenu.addPlayerActionEvents
    )

    RealisticLivestock.loadMap = Utils.appendedFunction(
        RealisticLivestock.loadMap,
        RLMenu.setupGui
    )

    Log:debug("RLMenu.install: PlayerInputComponent + loadMap hooks installed")
end
