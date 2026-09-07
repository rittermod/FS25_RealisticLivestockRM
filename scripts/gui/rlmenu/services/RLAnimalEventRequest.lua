--[[
    RLAnimalEventRequest.lua
    Shared cross-fire guard + timeout watchdog for the RL Tabbed Menu trade
    services (RLAnimalBuyService / RLAnimalSellService / RLAnimalMoveService).

    The three services each open a per-call g_messageCenter subscription whose reply carries
    only an errorCode and NO correlation id. Base game avoids cross-fire structurally - one
    shop screen means one live subscriber per MessageType - so letting every in-flight
    service open its own subscriber made the first server reply fire EVERY live subscriber
    of that class, and a dropped reply leaked its closure for the lifetime of
    g_messageCenter.

    This restores the one-live-subscriber-per-class invariant by serializing to a SINGLE
    in-flight request per event class: a second same-class request is REJECTED rather than
    queued, so the caller keeps its selection, and each request arms a cancellable watchdog
    that fires the callback once with a synthetic timeout code if the server never replies.
    A single-consume token means the callback never fires twice for one request.

    No MP wire change - it wraps the existing subscribe / sendEvent seam only. Accepted
    residual: a late reply after a timeout can still cross-fire into the NEXT same-class
    request, because it carries no correlation id; the generous timeout makes it rare.

    dispatch() takes an optional `deps` table so a test can inject fakes without touching a
    root global. Keying is per event CLASS, so a Buy and a Move in flight together never
    collide.
]]

local Log = RmLogging.getLogger("RLRM")

RLAnimalEventRequest = {}

--- Default watchdog duration (ms). A generous 10s makes the accepted late-reply residual
--- rare while still self-healing a genuinely dropped reply.
RLAnimalEventRequest.DEFAULT_TIMEOUT_MS = 10000

--- Synthetic error code the watchdog fires when the server never replies. Chosen
--- distinct from every real Buy/Sell/Move error code (those are small non-negative
--- ints) so it can never be mistaken for a real reply; each service's getErrorText
--- maps it to the shared rl_ui_tradeRequestTimeout text.
RLAnimalEventRequest.TIMEOUT_CODE = -1

--- Per-event-class in-flight registry: [eventClass] = requestToken while a request
--- of that class awaits a reply; nil = idle. Module-level so all three services
--- share one gate per class.
RLAnimalEventRequest._inFlight = {}


--- Default dispatch seam: send the event over the real server connection.
--- @param event table The constructed event to send
function RLAnimalEventRequest._defaultSendEvent(event)
    g_client:getServerConnection():sendEvent(event)
end


--- Default watchdog seam: a real cancellable one-shot Timer.
--- @param durationMs number Watchdog duration in ms
--- @param callback function Fired once when the timer elapses
--- @return table timer A Timer with :stop() (removes it from updateables before finish)
function RLAnimalEventRequest._defaultTimerFactory(durationMs, callback)
    return Timer.createOneshot(durationMs, callback)
end


--- Serialize an animal-trade event dispatch to one in-flight request per event class,
--- with a cancellable timeout watchdog and a single-consume completion.
---
--- Contract:
---  * Rejects (returns false, no dispatch, no subscription) when a request of the
---    SAME eventClass is already in flight - the caller keeps its selection.
---  * Otherwise subscribes, arms the watchdog, and sends the event (all inside a
---    pcall so an engine throw during arm/send can't strand the in-flight flag);
---    returns true. In SP the reply publishes SYNCHRONOUSLY inside sendEvent, so
---    onReply has already run (and the flag cleared) by the time this returns true.
---  * onReply fires EXACTLY ONCE, with the server errorCode on a real reply or
---    RLAnimalEventRequest.TIMEOUT_CODE on watchdog expiry. State (timer / subscription
---    / flag) is always cleared BEFORE onReply, and onReply is pcall-guarded so a
---    side-effect throw cannot bubble into the arm pcall or strand state.
--- @param eventClass table The MessageType / event class (AnimalBuyEvent / AnimalSellEvent / AnimalMoveEvent)
--- @param event table The constructed event to dispatch
--- @param onReply function Response handler fired once with the errorCode (real reply or synthetic timeout)
--- @param timeoutMs number|nil Watchdog duration (default DEFAULT_TIMEOUT_MS)
--- @param deps table|nil { messageCenter, sendEvent, timerFactory } injection seam (default real g_*)
--- @return boolean accepted False when a same-class request is already in flight (rejected, not queued)
function RLAnimalEventRequest.dispatch(eventClass, event, onReply, timeoutMs, deps)
    deps = deps or {}
    local messageCenter = deps.messageCenter or g_messageCenter
    local sendEvent = deps.sendEvent or RLAnimalEventRequest._defaultSendEvent
    local timerFactory = deps.timerFactory or RLAnimalEventRequest._defaultTimerFactory
    timeoutMs = timeoutMs or RLAnimalEventRequest.DEFAULT_TIMEOUT_MS

    if eventClass == nil then
        Log:warning("RLAnimalEventRequest.dispatch: nil eventClass, aborting (no dispatch)")
        return false
    end

    -- A dispatch with no completion handler can never release the caller's UI lock (the lock
    -- is released only inside onReply), and the boolean contract "true => a completion will
    -- fire" would break. Reject rather than accept-and-strand.
    if onReply == nil then
        Log:warning("RLAnimalEventRequest.dispatch: nil onReply for eventClass=%s, rejecting (no completion could release the caller's lock)",
            tostring(eventClass))
        return false
    end

    -- Per-class one-in-flight: reject a second same-class request (do NOT queue).
    if RLAnimalEventRequest._inFlight[eventClass] ~= nil then
        Log:debug("RLAnimalEventRequest.dispatch: eventClass=%s already in flight, rejecting (caller keeps selection)",
            tostring(eventClass))
        return false
    end

    local requestToken = {}
    local consumed = false
    local timer = nil

    RLAnimalEventRequest._inFlight[eventClass] = requestToken

    -- Single-consume completion: reply OR timeout, whichever lands first, exactly once.
    -- Always clears state (timer / subscription / flag) BEFORE invoking onReply, and
    -- pcall-guards onReply so a side-effect throw can't strand state or bubble upward.
    local function finish(errorCode, reason)
        if consumed then
            Log:trace("RLAnimalEventRequest: eventClass=%s finish ignored (already consumed, reason=%s)",
                tostring(eventClass), tostring(reason))
            return
        end
        consumed = true
        -- Stop the watchdog ONLY on a reply: a one-shot timer that already elapsed has removed
        -- itself before invoking this callback, so on the timeout branch a second stop() is a
        -- redundant no-op (and an extra reach into mission state for no effect).
        if reason ~= "timeout" and timer ~= nil and timer.stop ~= nil then
            timer:stop()
        end
        messageCenter:unsubscribe(eventClass, requestToken)
        if RLAnimalEventRequest._inFlight[eventClass] == requestToken then
            RLAnimalEventRequest._inFlight[eventClass] = nil
        end
        Log:debug("RLAnimalEventRequest: eventClass=%s completed via %s (errorCode=%s)",
            tostring(eventClass), tostring(reason), tostring(errorCode))
        if onReply ~= nil then
            local cbOk, cbErr = pcall(onReply, errorCode)
            if not cbOk then
                Log:error("RLAnimalEventRequest: eventClass=%s onReply threw: %s", tostring(eventClass), tostring(cbErr))
            end
        end
    end

    -- Arm the subscription + watchdog and send, all guarded: in SP the reply fires
    -- synchronously inside sendEvent (finish runs here); a throw during arm/send must
    -- not leave the in-flight flag set. onReply's own throws are contained in finish.
    local ok, err = pcall(function()
        messageCenter:subscribe(eventClass, function(_token, errorCode)
            finish(errorCode, "reply")
        end, requestToken)
        timer = timerFactory(timeoutMs, function()
            finish(RLAnimalEventRequest.TIMEOUT_CODE, "timeout")
        end)
        Log:trace("RLAnimalEventRequest.dispatch: eventClass=%s subscribed + watchdog armed (%dms), sending",
            tostring(eventClass), timeoutMs)
        sendEvent(event)
        Log:trace("RLAnimalEventRequest.dispatch: eventClass=%s sendEvent returned", tostring(eventClass))
    end)

    if not ok then
        -- Throw before/at send: tear down so the flag isn't stranded. Do NOT fire
        -- onReply (nothing dispatched); return false so the caller releases its lock.
        Log:error("RLAnimalEventRequest.dispatch: eventClass=%s threw during arm/send: %s",
            tostring(eventClass), tostring(err))
        if timer ~= nil and timer.stop ~= nil then
            timer:stop()
        end
        messageCenter:unsubscribe(eventClass, requestToken)
        if RLAnimalEventRequest._inFlight[eventClass] == requestToken then
            RLAnimalEventRequest._inFlight[eventClass] = nil
        end
        return false
    end

    return true
end


--- Whether a request of the given event class is currently in flight. Read-only
--- helper for tests / diagnostics; production callers rely on the false return.
--- @param eventClass table The event class to query
--- @return boolean inFlight
function RLAnimalEventRequest.isInFlight(eventClass)
    return RLAnimalEventRequest._inFlight[eventClass] ~= nil
end


--- Clear all in-flight state. Called on mission load/teardown so a request stranded by a
--- mission teardown (exit-to-menu / disconnect before its reply or watchdog landed - once
--- g_currentMission is gone the watchdog Timer never fires) cannot reject the first same-class
--- trade of the next session. Symmetric with the frames resetting their *Pending lock in onFrameOpen.
function RLAnimalEventRequest.reset()
    RLAnimalEventRequest._inFlight = {}
    Log:debug("RLAnimalEventRequest.reset: cleared in-flight state")
end


-- Mission-lifecycle hooks (mod event listener): a fresh mission has no in-flight network
-- requests, and a teardown abandons any pending ones - both reset the per-class gate. The
-- functions ignore the self/node args the engine passes (mirrors RLTestRunner's listener shape).
-- This is load-time registration ceremony (registers against the mission manager, not game
-- state) - the sanctioned load-time escape; it is why the helper is NOT sourced by the headless
-- suites (addModEventListener is engine-only).
function RLAnimalEventRequest.loadMap()
    RLAnimalEventRequest.reset()
end

function RLAnimalEventRequest.deleteMap()
    RLAnimalEventRequest.reset()
end

addModEventListener(RLAnimalEventRequest)

Log:debug("RLAnimalEventRequest: loaded")
