local Log = RmLogging.getLogger("RLRM")

--- Surviving routing seam for every `AnimalScreen.show` shape, the standalone
--- livestock-trailer activatable, and any direct `showGui` open (the EPP butcher among
--- them, which bypasses `AnimalScreen.show` and so is caught at `AnimalScreen.onOpen`).
--- Lives OUTSIDE the legacy AnimalScreen monolith so the redirects outlive that file's
--- teardown.
---
--- Contract:
---   * Routing parity - `show()` walks the same `(husbandry, vehicle, isDealer)` branch
---     tree the trigger data produces, so every entry point reaches the RLMenu open that
---     matches its legacy landing.
---   * Mutation parity - each open goes through `RLMenu.openFromBridge` /
---     `openTrailerFromBridge`, which fire the SAME server events the legacy controllers
---     did (AnimalBuyEvent / AnimalSellEvent / AnimalMoveEvent / AnimalLoadEvent /
---     AnimalUnloadEvent). This module introduces no new event class and no new bridge API.
---   * No vanilla fallback - every path here ATTEMPTS an RLMenu open, and no path calls
---     `superFunc`. A call carrying recognizable context opens the matching view; anything
---     else - a foreign caller, an unrouted shape, a controller this seam does not know -
---     opens the DEFAULT view: the full menu on Info, anchored on a husbandry when the call
---     supplied one and unanchored otherwise. A nil `g_rlMenu` is the only state that can
---     open nothing at all: `show` and `run` WARN-no-op, while `onOpen` additionally CLOSES,
---     because there a screen is already displayed and leaving it up is the failure this
---     seam exists to prevent.
---   * Routing tripwire - every routing decision logs an INFO naming it, every refusal a
---     WARN. This is the seam's permanent per-call contract, not diagnostics.
---
--- Load-time inert apart from the three installs at the tail (needs only the base-game
--- `AnimalScreen` / `LivestockTrailerActivatable` / `Utils` tables and the logger;
--- `RLMenu` and `g_rlMenu` are read at call time).
RLAnimalScreenBridge = {}

--- Page the default view lands on (Info, labelled "Manage" in the tab strip). Named rather
--- than repeated as a literal so the fallback call sites share one definition.
local DEFAULT_VIEW_PAGE = 4


--- Open the DEFAULT view - the full menu landing on Info - and report whether it opened.
--- This is the ONLY home for that (page, mode) pair, so the four call sites that fall back
--- to it cannot drift apart.
---
--- Short-circuits on a nil `g_rlMenu` WITHOUT calling `openFromBridge`, matching the top
--- guards the three entry points already carry. WARN ownership stays at the CALL SITES: this
--- helper logs its routing INFO and returns the boolean, so one refusal cannot stack three
--- warnings, and the own-pen walk-up keeps ignoring the result exactly as it did before.
--- @param reason string  routing detail for the INFO line; for a foreign caller this carries
---   the argument shape, which is the only identification a log reader gets
--- @param context table|nil  optional `{ husbandry = <placeable> }` anchor; nil opens unanchored
--- @return boolean opened  false on a nil menu or any refused open
local function openDefaultView(reason, context)
    if g_rlMenu == nil then
        Log:trace("openDefaultView: g_rlMenu nil, refusing without an open attempt (%s)", tostring(reason))
        return false
    end
    -- Name the anchor state: this one helper serves anchored opens (own-pen, and a
    -- gate-failed shape that carried a husbandry) and unanchored ones (foreign onOpen, the
    -- activatable), so a log reader counting these lines cannot otherwise tell them apart.
    Log:info("AnimalScreen -> RLMenu default view (page=%d mode=full anchor=%s): %s",
        DEFAULT_VIEW_PAGE, context ~= nil and "husbandry" or "none", tostring(reason))
    return RLMenu.openFromBridge(DEFAULT_VIEW_PAGE, RLMenu.MODE_FULL, context) == true
end


--- Make the displaced screen CLOSABLE before anything tries to close it.
---
--- Base-game `AnimalScreen:onClose` opens with `self.controller:reset()`, and that is the
--- ONLY controller method it calls (grep-verified against the base screen). A third-party
--- caller that pre-assigns a duck-typed table rather than an `AnimalScreenBase` subclass has
--- no `reset`, so that first statement raises - and everything AFTER it is skipped:
--- `removeActionEvents`, `toggleCustomInputContext(false, ...)` and
--- `g_currentMission:resetGameState()` never run. The player is then left on a screen that
--- neither the redirect nor Esc can clear, because both travel the same `onClose`.
---
--- MEASURED 2026-08-18 under ModTest, not theorised: a `{ someForeignField = true }`
--- controller left `g_gui.currentGuiName == "AnimalScreen"` with a synthesized Esc unable to
--- shift it, and supplying `reset` alone recovered both the redirect and the close.
---
--- Injecting a no-op onto the caller's own table is deliberate and is the smallest fix that
--- works: the swap is what displaces the screen, so RLRM owns the failure, and a controller
--- reaching here without `reset` is ALREADY malformed against the base-game contract this
--- seam is keeping coherent. A real `AnimalScreenBase` subclass resolves `reset` through its
--- metatable, so the nil test never fires for one and no live controller is ever touched.
--- @param controller table|nil  whatever the foreign caller pre-assigned
local function ensureDisplacedScreenCanClose(controller)
    if type(controller) ~= "table" or controller.reset ~= nil then
        return
    end
    controller.reset = function() end
    Log:warning("AnimalScreen.onOpen: foreign controller has no reset(); injected a no-op so " ..
        "the displaced screen can close (base onClose raises on it before restoring input)")
end


--- Close the displaced screen after a refused redirect. Shared by BOTH `onOpen` refusal
--- paths.
---
--- The `pcall` is load-bearing rather than defensive, and this was MEASURED rather than
--- theorised: closing the displaced screen can raise when the controller a foreign caller
--- pre-assigned does not implement everything the close path expects of it. That path is now
--- reached by arbitrary third-party opens, and a bare raise inside a GUI callback names
--- nothing - so the failure is logged with its cause instead of propagating.
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
--- no-husbandry branch and by the failed-pen-gate fall-through, so the two cannot drift.
--- @param vehicle table  a vehicle carrying `spec_livestockTrailer`
--- @param isDealer boolean|nil  true selects the dealer counterpart; anything else is world
--- @param origin string  which branch routed here; the two are indistinguishable in the log
---   otherwise, and only one of them arrived carrying a husbandry argument
--- @return boolean opened
local function openTrailerCounterpart(vehicle, isDealer, origin)
    local counterpart = (isDealer == true) and RLMenu.TRAILER_DEALER or RLMenu.TRAILER_WORLD
    Log:info("AnimalScreen.show: %s-trailer -> RLMenu (mode=trailer, via %s)",
        isDealer == true and "dealer" or "world", tostring(origin))
    return RLMenu.openFromBridge(nil, RLMenu.MODE_TRAILER,
        { trailer = vehicle, counterpart = counterpart }) == true
end


--- Route an `AnimalScreen.show(husbandry, vehicle, isDealer)` call to the mapped RLMenu
--- open. The branch tree keys off the same three arguments the trigger data supplies, so
--- routing keeps legacy parity; a shape whose gates fail no longer no-ops but opens the
--- default view, anchored on the husbandry when the call carried one. The INFO is a
--- routing-DECISION log, independent of the open's outcome - a refused open additionally
--- WARNs inside openFromBridge, so seeing both is expected.
--- @param husbandry table|nil animal-husbandry placeable (own-pen / pen-trailer shapes)
--- @param vehicle table|nil livestock-trailer vehicle (trailer shapes)
--- @param isDealer boolean|nil true for the dealer trailer walk-up; ignored for the
---   husbandry-present and no-argument leaves (the trigger ignores it there too)
function RLAnimalScreenBridge.show(husbandry, vehicle, isDealer)
    if g_rlMenu == nil then
        Log:warning("AnimalScreen.show: g_rlMenu nil, no-op (never vanilla)")
        return
    end

    if husbandry ~= nil then
        if vehicle ~= nil then
            -- Pen-trailer: a livestock trailer triggered AT a real animal pen. Opens the
            -- Transfer tab (pen counterpart), firing the same AnimalMoveEvent legacy did.
            if vehicle.spec_livestockTrailer ~= nil and husbandry.spec_husbandryAnimals ~= nil then
                Log:info("AnimalScreen.show: pen-trailer -> RLMenu (mode=trailer counterpart=pen)")
                RLMenu.openFromBridge(nil, RLMenu.MODE_TRAILER,
                    { trailer = vehicle, counterpart = RLMenu.TRAILER_PEN, counterpartHandle = husbandry })
                return
            end
            -- A real livestock trailer OUTRANKS a failed pen gate: the pen half is what did
            -- not resolve, and the trailer flow is still the right destination. The non-pen
            -- handle is dropped rather than forwarded - TRAILER_PEN is the only counterpart
            -- that consumes a handle, and it requires a real animal husbandry.
            if vehicle.spec_livestockTrailer ~= nil then
                Log:trace("AnimalScreen.show: pen gate failed but the vehicle is a real trailer; routing to its counterpart")
                openTrailerCounterpart(vehicle, isDealer, "failed pen gate")
                return
            end
        else
            -- Own-pen walk-up: the full menu on Info, anchored to THIS pen via the one-shot
            -- husbandry anchor. Forwards ANY non-nil husbandry (isDealer ignored); a
            -- non-animal husbandry opens unanchored with openFromBridge's own WARN. The
            -- return is deliberately ignored - a refusal has already warned inside
            -- openFromBridge and there is nothing on screen to close.
            openDefaultView("own-pen walk-up", { husbandry = husbandry })
            return
        end
    elseif vehicle ~= nil then
        -- Trailer at a dealer (isDealer) or a standalone world trigger (falsy isDealer):
        -- the Transfer tab against the dealer / world counterpart. Same Buy/Sell/load
        -- events legacy fired. A non-livestock vehicle falls to the default view below.
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

    -- Terminal: a shape this seam does not route directly - either one it does not
    -- recognize, or one whose gates failed with no usable trailer. It still opens the menu,
    -- anchored on the husbandry when the call carried one. The reason carries the argument
    -- shape forward, which is the only identification a log reader gets for a foreign caller.
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


--- Pure shape predicate: is this the EPP (butcher) controller? A third-party EPP
--- trigger direct-opens the vanilla AnimalScreen with its own controller whose
--- `.husbandry` IS the production point (its loading trigger assigns itself there), NOT a
--- real animal pen. Detect by SHAPE, never class name (EPP is an optional third-party mod):
--- the pp carries `animalsTypeData` + `addCluster` + `getNumOfFreeAnimalSlots` and has NO
--- `spec_husbandryAnimals`, whereas a pen-trailer controller's `.husbandry` is a real
--- husbandry (`spec_husbandryAnimals` present, no `animalsTypeData`). The
--- `getNumOfFreeAnimalSlots` check makes the gate match the FULL pp contract the redirect
--- then relies on (the sidebar reads it in `getDisplayData`, and the delivery filter calls
--- `target:getNumOfFreeAnimalSlots` for every survivor in `RLAnimalMoveService`), so a
--- partial EPP-like controller cannot be redirected into a slot-API crash. Total + nil-safe:
--- any missing field -> false.
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


--- Wrapper for `AnimalScreen.onOpen` - the redirect for any direct `showGui` open.
--- Such a trigger sets its controller and calls `g_gui:showGui("AnimalScreen")` itself, so
--- the `show()` seam above never catches it; `onOpen` is the earliest hook after the
--- controller is set. No surviving RLRM flow opens `AnimalScreen` that way (every RLRM
--- trigger redirects at `.show` / `run`), so this hook fires only for external opens - the
--- EPP butcher, or any other mod.
---
--- On an EPP-shaped controller: swap to RLMenu MODE_TRAILER with the EPP counterpart;
--- `counterpartHandle` is `controller.husbandry` (the pp itself - no unwrap). On ANY other
--- controller - including none at all - open the unanchored default view instead. Either way
--- the injected `_superFunc` is never called: by the time this runs a screen is already
--- displayed by construction, and the contract is that it is never presented as the working
--- surface. On a refused open (`g_rlMenu` nil / a dialog visible / nil trailer or pp) WARN
--- and `g_gui:changeScreen(nil)` to CLOSE the displaced screen; closing from within onOpen
--- is an observed-supported swap, not a re-entrancy hazard (playtested on the EPP flow).
--- @param self table  the AnimalScreen instance (`self.controller` is pre-assigned)
--- @param _superFunc function  the wrapped base onOpen; deliberately unused - the wrap
---   is kept only so a wrapper installed by a mod loading before RLRM is not destroyed
function RLAnimalScreenBridge.onOpen(self, _superFunc, ...)
    local controller = self ~= nil and self.controller or nil

    -- BEFORE any branch below, because every one of them ends with this screen being
    -- displaced: the successful swap closes it through `showGui("RLMenu")`, and both refusal
    -- paths close it through `closeVanillaScreen`. All three travel base `onClose`, so a
    -- controller without `reset` strands the player whichever way this call goes.
    ensureDisplacedScreenCanClose(controller)

    if not RLAnimalScreenBridge.isEPPControllerShape(controller) then
        -- Any other pre-assigned controller, or none at all. The view is UNANCHORED on
        -- purpose: `controller.husbandry` means different things per controller class (on an
        -- EPP controller it is the production point, not a pen), so only `show()`'s
        -- documented positional argument is ever safe to anchor on. Nothing below may
        -- dereference `self` - a malformed dispatch reaches here with self nil.
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
    -- If in-game testing shows a one-frame flash of the displaced screen, defer this swap
    -- to the next frame via Timer.createOneshot (the documented fallback; primary is this
    -- direct swap).
    if g_rlMenu ~= nil and RLMenu.openFromBridge(nil, RLMenu.MODE_TRAILER,
            { trailer = trailer, counterpart = RLMenu.TRAILER_EPP, counterpartHandle = pp }) == true then
        return
    end

    -- Refused: close the screen rather than leave the cluster-style EPP presentation up.
    Log:warning("AnimalScreen.onOpen: EPP redirect refused (g_rlMenu=%s), closing screen (never vanilla)",
        tostring(g_rlMenu ~= nil))
    closeVanillaScreen("a refused EPP redirect")
end


--- World-trailer redirect for the standalone `LivestockTrailerActivatable` ("Open animal
--- screen" prompt on a parked livestock trailer with no loading trigger). This activatable
--- opens a screen unconditionally once it runs, so a `setController`-level hook cannot
--- suppress it - the interception has to be `run` itself. Redirects to the Transfer tab
--- (world counterpart), firing the same AnimalLoadEvent / AnimalUnloadEvent legacy did.
RL_LivestockTrailerActivatable = {}

--- Keeps its OWN `g_rlMenu` guard (the `show()` top guard does not cover this path). A nil
--- trailer or a refused trailer open falls back to the default view rather than no-opping;
--- only when THAT is refused too does it WARN-no-op, and it never calls `_superFunc`.
--- @param _superFunc function  the wrapped activatable run; deliberately unused, since no
---   branch here may present a screen other than RLMenu
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
    -- UNCONDITIONAL by design rather than conditioned on the refusal cause, because
    -- openTrailerFromBridge's return does not distinguish the causes and widening it is an
    -- RLMenu change this seam does not make. Accepted consequence: the two call-independent
    -- causes (a visible dialog, a showGui throw) refuse this retry for the same reason, so
    -- the player sees nothing either way - which is why the WARN below has to say so. The
    -- two arms are kept apart because on the nil-trailer path no trailer open was ever
    -- attempted, and a WARN claiming one was sends a log reader hunting a second fault.
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


-- Sole installer for all three overrides (the legacy monolith's own installs are removed
-- in the same slice, so there is no source-order-decided double-install / double-wrap).
-- The activatable and the onOpen redirect keep the overwrittenFunction wrap as the
-- interception mechanism; both leave their injected superFunc unused, because no branch in
-- this file may present a screen other than RLMenu. Note what that does and does not buy:
-- the wrap preserves an earlier wrapper's existence but never invokes it, so a mod that
-- wrapped these members before RLRM is bypassed rather than chained.
AnimalScreen.show = RLAnimalScreenBridge.show
LivestockTrailerActivatable.run = Utils.overwrittenFunction(LivestockTrailerActivatable.run,
    RL_LivestockTrailerActivatable.run)
-- EPP butcher direct-open redirect: it bypasses AnimalScreen.show, so the intercept is
-- onOpen (the earliest hook after the controller is set), not the show() seam above.
AnimalScreen.onOpen = Utils.overwrittenFunction(AnimalScreen.onOpen, RLAnimalScreenBridge.onOpen)
