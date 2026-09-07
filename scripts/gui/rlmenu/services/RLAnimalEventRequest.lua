--[[
    RLAnimalEventRequest.lua
    Shared cross-fire guard + timeout watchdog for the trade services (Buy / Sell / Move).
    It wraps the existing subscribe / sendEvent seam and changes no MP wire format.

    Each service opens a per-call g_messageCenter subscription whose reply carries only an
    errorCode and NO correlation id, so the first server reply fires EVERY live subscriber
    of that class. This holds the one-live-subscriber-per-class invariant by serializing to
    a SINGLE in-flight request per event class: a second same-class request is REJECTED
    rather than queued, and each request arms a cancellable watchdog that fires the callback
    once with a synthetic timeout code if the server never replies. A single-consume token
    stops the callback firing twice; keying is per event CLASS, so a Buy and a Move in
    flight together never collide.
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


--- Serialize an animal-trade dispatch to ONE in-flight request per event class, with a
--- cancellable watchdog and a single-consume completion. A same-class request already in
--- flight is REJECTED without dispatching, so the caller keeps its selection. Arming and
--- sending sit inside a pcall, so an engine throw cannot strand the in-flight flag. In SP
--- the reply publishes synchronously, so onReply has already run on return. onReply fires
--- EXACTLY ONCE, with the server code or the timeout code, and all state clears BEFORE it.
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


--- Clear all in-flight state on mission load and teardown. A request stranded by a
--- teardown never fires its watchdog - the timer needs the mission - so without this it
--- would reject the first same-class trade of the next session.
function RLAnimalEventRequest.reset()
    RLAnimalEventRequest._inFlight = {}
    Log:debug("RLAnimalEventRequest.reset: cleared in-flight state")
end


-- Mission-lifecycle hooks: a fresh mission has no in-flight requests and a teardown
-- abandons any pending ones, so both reset the per-class gate. Registering against the
-- mission manager is engine-only, which is why the headless suites do not source this.
function RLAnimalEventRequest.loadMap()
    RLAnimalEventRequest.reset()
end

function RLAnimalEventRequest.deleteMap()
    RLAnimalEventRequest.reset()
end

addModEventListener(RLAnimalEventRequest)

Log:debug("RLAnimalEventRequest: loaded")
