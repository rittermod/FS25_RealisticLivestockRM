local Log = RmLogging.getLogger("RLRM")

--- Surviving routing seam for every `AnimalScreen.show` shape, the standalone livestock-trailer
--- activatable, and any direct `showGui` open - the EPP butcher among them, which bypasses
--- `AnimalScreen.show` and so is caught at `AnimalScreen.onOpen`. Lives OUTSIDE the legacy
--- AnimalScreen monolith so the redirects outlive that file's teardown.
---
--- Contract:
---   * Routing parity - `show()` walks the same `(husbandry, vehicle, isDealer)` branch tree the
---     trigger data produces, so every entry point reaches the RLMenu open matching its legacy
---     landing.
---   * Mutation parity - each open goes through `RLMenu.openFromBridge` /
---     `openTrailerFromBridge`, which fire the SAME server events the legacy controllers did.
---     This module introduces no new event class and no new bridge API.
---   * No vanilla fallback - every path ATTEMPTS an RLMenu open and none calls `superFunc`.
---     Anything unrecognized opens the DEFAULT view: the full menu on Info, anchored on a
---     husbandry when the call supplied one. A nil `g_rlMenu` is the only state that opens
---     nothing: `show` and `run` WARN-no-op, while `onOpen` additionally CLOSES, because there a
---     screen is already displayed and leaving it up is the failure this seam prevents.
---   * Routing tripwire - every routing decision logs an INFO naming it, every refusal a WARN.
---     That is the seam's permanent per-call contract, not diagnostics.
---
--- Load-time inert apart from the three installs at the tail; `RLMenu` and `g_rlMenu` are read at
--- call time.
RLAnimalScreenBridge = {}

--- Page the default view lands on (Info, labelled "Manage" in the tab strip). Named so the
--- fallback call sites share one definition.
local DEFAULT_VIEW_PAGE = 4


--- Open the DEFAULT view - the full menu landing on Info - and report whether it opened. The ONLY
--- home for that (page, mode) pair, so the four call sites that fall back to it cannot drift.
---
--- Short-circuits on a nil `g_rlMenu` WITHOUT calling `openFromBridge`. WARN ownership stays at
--- the CALL SITES: this helper logs its routing INFO and returns the boolean, so one refusal
--- cannot stack three warnings.
--- @param reason string  routing detail for the INFO line; for a foreign caller this carries the
---   argument shape, which is the only identification a log reader gets
--- @param context table|nil  optional `{ husbandry = <placeable> }` anchor; nil opens unanchored
--- @return boolean opened  false on a nil menu or any refused open
local function openDefaultView(reason, context)
    if g_rlMenu == nil then
        Log:trace("openDefaultView: g_rlMenu nil, refusing without an open attempt (%s)", tostring(reason))
        return false
    end
    -- Name the anchor state: this helper serves both anchored and unanchored opens, which a log
    -- reader counting these lines could not otherwise tell apart.
    Log:info("AnimalScreen -> RLMenu default view (page=%d mode=full anchor=%s): %s",
        DEFAULT_VIEW_PAGE, context ~= nil and "husbandry" or "none", tostring(reason))
    return RLMenu.openFromBridge(DEFAULT_VIEW_PAGE, RLMenu.MODE_FULL, context) == true
end


--- Make the displaced screen CLOSABLE before anything tries to close it.
---
--- Base-game `AnimalScreen:onClose` opens with `self.controller:reset()`, and that is the only
--- controller method it calls. A third-party caller that pre-assigns a duck-typed table rather
--- than an `AnimalScreenBase` subclass has no `reset`, so that first statement raises and
--- everything after it is skipped: `removeActionEvents`, `toggleCustomInputContext(false, ...)`
--- and `g_currentMission:resetGameState()` never run. The player is then stranded on a screen
--- neither the redirect nor Esc can clear, because both travel the same `onClose`. Measured: a
--- `{ someForeignField = true }` controller left `g_gui.currentGuiName == "AnimalScreen"` with a
--- synthesized Esc unable to shift it, and supplying `reset` alone recovered both.
---
--- Injecting a no-op onto the caller's own table is the smallest fix that works: the swap is what
--- displaces the screen, so RLRM owns the failure, and a controller reaching here without `reset`
--- is already malformed against the base-game contract. A real `AnimalScreenBase` subclass
--- resolves `reset` through its metatable, so the nil test never fires for one.
--- @param controller table|nil  whatever the foreign caller pre-assigned
local function ensureDisplacedScreenCanClose(controller)
    if type(controller) ~= "table" or controller.reset ~= nil then
        return
    end
    controller.reset = function() end
    Log:warning("AnimalScreen.onOpen: foreign controller has no reset(); injected a no-op so " ..
        "the displaced screen can close (base onClose raises on it before restoring input)")
end


--- Close the displaced screen after a refused redirect. Shared by BOTH `onOpen` refusal paths.
---
--- The `pcall` is load-bearing rather than defensive, and measured: closing the displaced screen
--- can raise when the controller a foreign caller pre-assigned does not implement everything the
--- close path expects. That path is reached by arbitrary third-party opens, and a bare raise
--- inside a GUI callback names nothing, so the failure is logged with its cause instead.
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


--- Route an `AnimalScreen.show(husbandry, vehicle, isDealer)` call to the mapped RLMenu open. The
--- branch tree keys off the same three arguments the trigger data supplies, so routing keeps
--- legacy parity; a shape whose gates fail opens the default view, anchored on the husbandry when
--- the call carried one. The INFO is a routing-DECISION log independent of the open's outcome, so
--- a refused open logging both that and a WARN from openFromBridge is expected.
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


--- Pure shape predicate: is this the EPP (butcher) controller? A third-party EPP trigger
--- direct-opens the vanilla AnimalScreen with its own controller whose `.husbandry` IS the
--- production point, not a real animal pen. Detect by SHAPE, never class name, since EPP is an
--- optional third-party mod: the pp carries `animalsTypeData`, `addCluster` and
--- `getNumOfFreeAnimalSlots` and has NO `spec_husbandryAnimals`, whereas a pen-trailer
--- controller's `.husbandry` is a real husbandry. The `getNumOfFreeAnimalSlots` check makes the
--- gate match the FULL pp contract the redirect then relies on, so a partial EPP-like controller
--- cannot be redirected into a slot-API crash. Total and nil-safe: any missing field is false.
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


--- Wrapper for `AnimalScreen.onOpen` - the redirect for any direct `showGui` open. Such a trigger
--- sets its controller and calls `g_gui:showGui("AnimalScreen")` itself, so the `show()` seam
--- never catches it, and `onOpen` is the earliest hook after the controller is set. No surviving
--- RLRM flow opens `AnimalScreen` that way, so this fires only for external opens.
---
--- An EPP-shaped controller swaps to RLMenu MODE_TRAILER with the EPP counterpart, its
--- `counterpartHandle` being `controller.husbandry` - the pp itself, no unwrap. Any other
--- controller, including none, opens the unanchored default view. Either way the injected
--- `_superFunc` is never called: by the time this runs a screen is already displayed, and it is
--- never presented as the working surface. A refused open WARNs and closes the displaced screen;
--- closing from within onOpen is an observed-supported swap, not a re-entrancy hazard.
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


--- World-trailer redirect for the standalone `LivestockTrailerActivatable` - the "Open animal
--- screen" prompt on a parked livestock trailer with no loading trigger. This activatable opens a
--- screen unconditionally once it runs, so a `setController`-level hook cannot suppress it and
--- the interception has to be `run` itself. Redirects to the Transfer tab against the world
--- counterpart, firing the same load and unload events legacy did.
RL_LivestockTrailerActivatable = {}

--- Keeps its OWN `g_rlMenu` guard, since the `show()` top guard does not cover this path. A nil
--- trailer or a refused trailer open falls back to the default view rather than no-opping; only
--- when THAT is refused too does it WARN-no-op, and it never calls `_superFunc`.
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

    -- Nil trailer, or the trailer open was refused: attempt the default view. The retry is
    -- UNCONDITIONAL rather than conditioned on the cause, because openTrailerFromBridge's return
    -- does not distinguish them. Accepted consequence: a visible dialog or a showGui throw
    -- refuses this retry for the same reason, so the player sees nothing either way - which is
    -- why the warning below says so. The two arms stay apart because on the nil-trailer path no
    -- trailer open was ever attempted, and a warning claiming one was sends a reader hunting a
    -- second fault.
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


-- Sole installer for all three overrides. The activatable and the onOpen redirect keep the
-- overwrittenFunction wrap as the interception mechanism, and both leave their injected superFunc
-- unused, because no branch in this file may present a screen other than RLMenu. Note what that
-- does and does not buy: the wrap preserves an earlier wrapper's existence but never invokes it,
-- so a mod that wrapped these members before RLRM is bypassed rather than chained.
AnimalScreen.show = RLAnimalScreenBridge.show
LivestockTrailerActivatable.run = Utils.overwrittenFunction(LivestockTrailerActivatable.run,
    RL_LivestockTrailerActivatable.run)
-- The EPP butcher direct-open bypasses AnimalScreen.show, so its intercept is onOpen.
AnimalScreen.onOpen = Utils.overwrittenFunction(AnimalScreen.onOpen, RLAnimalScreenBridge.onOpen)
