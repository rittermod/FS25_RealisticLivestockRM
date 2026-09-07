local Log = RmLogging.getLogger("RLRM")

--- Routing seam for every `AnimalScreen.show` shape, the standalone trailer activatable, and
--- any direct `showGui` open - the EPP butcher among them, which bypasses `show` and so is
--- caught at `onOpen`. Lives OUTSIDE the legacy monolith so the redirects outlive its teardown.
---
--- NO VANILLA FALLBACK: every path attempts an RLMenu open and none calls `superFunc`, with
--- anything unrecognized landing on the default view. A nil `g_rlMenu` is the only state
--- that opens nothing - and `onOpen` additionally CLOSES there, because a screen is already
--- displayed and leaving it up is the failure this seam exists to prevent. Every routing
--- decision logs an INFO and every refusal a WARN: that is a contract, not diagnostics.
RLAnimalScreenBridge = {}

--- Page the default view lands on (Info, labelled "Manage" in the tab strip). Named so the
--- fallback call sites share one definition.
local DEFAULT_VIEW_PAGE = 4


--- Open the DEFAULT view and report whether it opened - the ONLY home for that (page, mode)
--- pair, so the four call sites that fall back to it cannot drift. WARN ownership stays at
--- the CALL SITES, so one refusal cannot stack three warnings.
--- @param reason string  routing detail for the INFO line; for a foreign caller this carries the
---   argument shape, which is the only identification a log reader gets
--- @param context table|nil  optional `{ husbandry = <placeable> }` anchor; nil opens unanchored
--- @return boolean opened  false on a nil menu or any refused open
local function openDefaultView(reason, context)
    if g_rlMenu == nil then
        Log:trace("openDefaultView: g_rlMenu nil, refusing without an open attempt (%s)", tostring(reason))
        return false
    end
    -- Name the anchor state: this helper serves both anchored and unanchored opens.
    Log:info("AnimalScreen -> RLMenu default view (page=%d mode=full anchor=%s): %s",
        DEFAULT_VIEW_PAGE, context ~= nil and "husbandry" or "none", tostring(reason))
    return RLMenu.openFromBridge(DEFAULT_VIEW_PAGE, RLMenu.MODE_FULL, context) == true
end


--- Make the displaced screen CLOSABLE before anything tries to close it. Base-game onClose
--- calls `controller:reset()` first, so a duck-typed controller with no `reset` raises there
--- and skips the input restore below it, stranding the player on a screen neither the
--- redirect nor Esc can clear - both travel that same onClose. Injecting a no-op onto the
--- caller's table is the smallest fix; a real subclass resolves `reset` through its
--- metatable, so the nil test never fires for one.
--- @param controller table|nil  whatever the foreign caller pre-assigned
local function ensureDisplacedScreenCanClose(controller)
    if type(controller) ~= "table" or controller.reset ~= nil then
        return
    end
    controller.reset = function() end
    Log:warning("AnimalScreen.onOpen: foreign controller has no reset(); injected a no-op so " ..
        "the displaced screen can close (base onClose raises on it before restoring input)")
end


--- Close the displaced screen after a refused redirect, shared by BOTH onOpen refusal paths.
--- The pcall is load-bearing, not defensive: the close can raise when a foreign controller
--- does not implement everything that path expects, and a bare raise inside a GUI callback
--- names nothing.
--- @param reason string  the refusal that led here, named in the error line
local function closeVanillaScreen(reason)
    local ok, err = pcall(function() g_gui:changeScreen(nil) end)
    if not ok then
        Log:error("AnimalScreen.onOpen: changeScreen(nil) failed after %s (err=%s); a screen may still be displayed",
            tostring(reason), tostring(err))
        return
    end
    Log:trace("AnimalScreen.onOpen: closed the displaced screen after %s", tostring(reason))
end


--- Route a real livestock-trailer shape to its dealer / world counterpart. Shared by the
--- no-husbandry branch and the failed-pen-gate fall-through, so the two cannot drift.
--- @param vehicle table  a vehicle carrying `spec_livestockTrailer`
--- @param isDealer boolean|nil  true selects the dealer counterpart; anything else is world
--- @param origin string  which branch routed here; only one of them carried a husbandry argument
--- @return boolean opened
local function openTrailerCounterpart(vehicle, isDealer, origin)
    local counterpart = (isDealer == true) and RLMenu.TRAILER_DEALER or RLMenu.TRAILER_WORLD
    Log:info("AnimalScreen.show: %s-trailer -> RLMenu (mode=trailer, via %s)",
        isDealer == true and "dealer" or "world", tostring(origin))
    return RLMenu.openFromBridge(nil, RLMenu.MODE_TRAILER,
        { trailer = vehicle, counterpart = counterpart }) == true
end


--- Route a `show(husbandry, vehicle, isDealer)` call to the mapped RLMenu open. A shape whose
--- gates fail opens the default view, anchored on the husbandry when the call carried one.
--- The INFO is a routing-DECISION log independent of the outcome, so a refused open logging
--- both it and a WARN is expected.
--- @param husbandry table|nil animal-husbandry placeable (own-pen / pen-trailer shapes)
--- @param vehicle table|nil livestock-trailer vehicle (trailer shapes)
--- @param isDealer boolean|nil true for the dealer trailer walk-up; ignored for the
---   husbandry-present and no-argument leaves, as the trigger ignores it there too
function RLAnimalScreenBridge.show(husbandry, vehicle, isDealer)
    if g_rlMenu == nil then
        Log:warning("AnimalScreen.show: g_rlMenu nil, no-op (never vanilla)")
        return
    end

    if husbandry ~= nil then
        if vehicle ~= nil then
            -- Pen-trailer: a livestock trailer triggered AT a real animal pen. Opens the Transfer
            -- tab, firing the same AnimalMoveEvent legacy did.
            if vehicle.spec_livestockTrailer ~= nil and husbandry.spec_husbandryAnimals ~= nil then
                Log:info("AnimalScreen.show: pen-trailer -> RLMenu (mode=trailer counterpart=pen)")
                RLMenu.openFromBridge(nil, RLMenu.MODE_TRAILER,
                    { trailer = vehicle, counterpart = RLMenu.TRAILER_PEN, counterpartHandle = husbandry })
                return
            end
            -- A real livestock trailer OUTRANKS a failed pen gate: the pen half is what did not
            -- resolve, and the trailer flow is still the right destination. The non-pen handle is
            -- dropped rather than forwarded - TRAILER_PEN is the only counterpart that consumes
            -- one, and it requires a real animal husbandry.
            if vehicle.spec_livestockTrailer ~= nil then
                Log:trace("AnimalScreen.show: pen gate failed but the vehicle is a real trailer; routing to its counterpart")
                openTrailerCounterpart(vehicle, isDealer, "failed pen gate")
                return
            end
        else
            -- Own-pen walk-up: the full menu on Info, anchored to THIS pen. Forwards any non-nil
            -- husbandry; a non-animal one opens unanchored with openFromBridge's own warning. The
            -- return is ignored deliberately - a refusal has already warned there, and there is
            -- nothing on screen to close.
            openDefaultView("own-pen walk-up", { husbandry = husbandry })
            return
        end
    elseif vehicle ~= nil then
        -- Trailer at a dealer, or a standalone world trigger: the Transfer tab against the
        -- matching counterpart, firing the same events legacy did. A non-livestock vehicle falls
        -- to the default view below.
        if vehicle.spec_livestockTrailer ~= nil then
            openTrailerCounterpart(vehicle, isDealer, "no-husbandry trailer shape")
            return
        end
    else
        -- Dealer shape: the shop "Buy Animals" button and the on-foot no-husbandry trigger.
        -- Anchors the Buy tab in dealer mode; same AnimalBuyEvent legacy fired.
        Log:info("AnimalScreen.show: dealer-shape -> RLMenu (page=1 mode=dealer)")
        RLMenu.openFromBridge(1, RLMenu.MODE_DEALER)
        return
    end

    -- Terminal: a shape this seam does not route directly, either unrecognized or one whose gates
    -- failed with no usable trailer. It still opens the menu, anchored on the husbandry when the
    -- call carried one, and the reason carries the argument shape forward as the only
    -- identification a log reader gets for a foreign caller.
    local reason = string.format("unrouted shape h=%s v=%s isDealer=%s",
        tostring(husbandry ~= nil), tostring(vehicle ~= nil), tostring(isDealer))
    local context = nil
    if husbandry ~= nil then
        context = { husbandry = husbandry }
    end
    if not openDefaultView(reason, context) then
        Log:warning("AnimalScreen.show: default view refused for %s, no-op (never vanilla)", reason)
    end
end


--- Is this the EPP (butcher) controller, whose `.husbandry` is the production point rather
--- than a real pen? Detected by SHAPE, never class name, since EPP is an optional
--- third-party mod. The slot-API check makes the gate match the FULL contract the redirect
--- then relies on, so a partial EPP-like controller cannot be redirected into a crash.
--- @param controller table|nil  the AnimalScreen's pre-assigned controller
--- @return boolean isEPP
function RLAnimalScreenBridge.isEPPControllerShape(controller)
    return controller ~= nil
        and controller.trailer ~= nil
        and controller.husbandry ~= nil
        and controller.husbandry.animalsTypeData ~= nil
        and controller.husbandry.spec_husbandryAnimals == nil
        and type(controller.husbandry.addCluster) == "function"
        and type(controller.husbandry.getNumOfFreeAnimalSlots) == "function"
end


--- Redirect for any DIRECT `showGui` open, which sets its own controller and so is never
--- caught by the `show()` seam; onOpen is the earliest hook after the controller is set.
--- An EPP-shaped controller swaps to trailer mode against the EPP counterpart, anything
--- else opens the default view. `_superFunc` is never called either way: a screen is
--- already displayed by now and is never presented as the working surface.
--- @param self table  the AnimalScreen instance (`self.controller` is pre-assigned)
--- @param _superFunc function  the wrapped base onOpen; deliberately unused - the wrap is kept
---   only so a wrapper installed by a mod loading before RLRM is not destroyed
function RLAnimalScreenBridge.onOpen(self, _superFunc, ...)
    local controller = self ~= nil and self.controller or nil

    -- BEFORE any branch below, because every one of them ends with this screen displaced - the
    -- successful swap closes it through `showGui("RLMenu")` and both refusal paths through
    -- `closeVanillaScreen`. All three travel base `onClose`, so a controller without `reset`
    -- strands the player whichever way this call goes.
    ensureDisplacedScreenCanClose(controller)

    if not RLAnimalScreenBridge.isEPPControllerShape(controller) then
        -- UNANCHORED on purpose: `controller.husbandry` means different things per controller
        -- class, so only `show()`'s documented positional argument is ever safe to anchor on.
        -- Nothing below may dereference `self` - a malformed dispatch reaches here with self nil.
        Log:trace("AnimalScreen.onOpen: controller is not EPP-shaped; routing to the default view")
        if openDefaultView("foreign AnimalScreen open (non-EPP controller)", nil) then
            return
        end
        Log:warning("AnimalScreen.onOpen: non-EPP redirect refused (g_rlMenu=%s), closing screen (never vanilla)",
            tostring(g_rlMenu ~= nil))
        closeVanillaScreen("a refused non-EPP redirect")
        return
    end

    local trailer = controller.trailer
    local pp = controller.husbandry
    Log:info("AnimalScreen.onOpen: EPP butcher direct-open -> RLMenu (mode=trailer counterpart=epp)")

    -- Direct swap: openFromBridge -> showGui("RLMenu") replaces the just-shown screen.
    if g_rlMenu ~= nil and RLMenu.openFromBridge(nil, RLMenu.MODE_TRAILER,
            { trailer = trailer, counterpart = RLMenu.TRAILER_EPP, counterpartHandle = pp }) == true then
        return
    end

    -- Refused: close the screen rather than leave the cluster-style EPP presentation up.
    Log:warning("AnimalScreen.onOpen: EPP redirect refused (g_rlMenu=%s), closing screen (never vanilla)",
        tostring(g_rlMenu ~= nil))
    closeVanillaScreen("a refused EPP redirect")
end


--- World-trailer redirect for the standalone activatable - the prompt on a parked trailer
--- with no loading trigger. It opens a screen unconditionally once it runs, so a
--- controller-level hook cannot suppress it and the interception has to be `run` itself.
RL_LivestockTrailerActivatable = {}

--- Keeps its OWN `g_rlMenu` guard, since the `show()` top guard does not cover this path.
--- A nil or refused trailer open falls back to the default view, and only a refusal of
--- THAT warns and no-ops.
--- @param _superFunc function  the wrapped activatable run; deliberately unused, since no branch
---   here may present a screen other than RLMenu
--- @return nil
function RL_LivestockTrailerActivatable:run(_superFunc)
    if g_rlMenu == nil then
        Log:warning("LivestockTrailerActivatable:run: g_rlMenu nil, no-op (never vanilla)")
        return
    end

    local hasTrailer = self.livestockTrailer ~= nil
    if hasTrailer and RLMenu.openFromBridge(nil, RLMenu.MODE_TRAILER,
            { trailer = self.livestockTrailer, counterpart = RLMenu.TRAILER_WORLD }) == true then
        Log:info("LivestockTrailerActivatable:run: world-trailer -> RLMenu (mode=trailer counterpart=world)")
        return
    end

    -- The retry is UNCONDITIONAL, because the refusal's return value does not distinguish
    -- its causes. The two arms stay apart because on the nil-trailer path no trailer open
    -- was ever attempted, and a warning claiming one was sends a reader hunting a second fault.
    if openDefaultView(hasTrailer and "standalone-trailer activatable (trailer open refused)"
            or "standalone-trailer activatable (no trailer on the activatable)", nil) then
        return
    end
    if hasTrailer then
        Log:warning("LivestockTrailerActivatable:run: trailer open AND default view both refused, no-op (never vanilla)")
    else
        Log:warning("LivestockTrailerActivatable:run: no trailer to open, and the default view was refused, no-op (never vanilla)")
    end
end


-- Sole installer for all three overrides. Both wraps leave their injected superFunc unused,
-- because no branch here may present a screen other than RLMenu - so an earlier wrapper's
-- existence is preserved but never invoked, bypassed rather than chained.
AnimalScreen.show = RLAnimalScreenBridge.show
LivestockTrailerActivatable.run = Utils.overwrittenFunction(LivestockTrailerActivatable.run,
    RL_LivestockTrailerActivatable.run)
-- The EPP butcher direct-open bypasses AnimalScreen.show, so its intercept is onOpen.
AnimalScreen.onOpen = Utils.overwrittenFunction(AnimalScreen.onOpen, RLAnimalScreenBridge.onOpen)
