RmSafeUtils = {}

--- Run `fn` under xpcall, bracketed by enter/exit trace lines. The exit line carries the
--- elapsed wall-clock time and fires even when the body throws.
---@param context string  identifier for log/error messages (e.g. "AnimalSystem:onDayChanged")
---@param fn function     the function body to protect
---@return boolean ok
function RmSafeUtils.safeCall(context, fn)
    local startSec = getTimeSec()
    local gameTime = (RLDebugUtils and RLDebugUtils.formatGameTime and RLDebugUtils.formatGameTime()) or "?"
    Log:trace("[safeCall] %s: enter (gameTime=%s)", context, gameTime)

    local ok, err = xpcall(fn, function(e) return tostring(e) end)

    local elapsedMs = (getTimeSec() - startSec) * 1000
    Log:trace("[safeCall] %s: exit  (took %.2fms)", context, elapsedMs)

    if not ok then
        Log:error("Error in %s: %s", context, tostring(err))
        printCallstack()
    end
    return ok
end

--- Run `fn` under xpcall, returning `defaults` on error so one bad animal cannot kill a loop.
---@param animal table           the animal (for identity in log)
---@param context string         handler name for log
---@param fn function            function() -> values
---@param defaults table|nil     array of default values on error
---@return ...                   fn results or defaults
function RmSafeUtils.safeAnimalCall(animal, context, fn, defaults)
    local results = { xpcall(fn, function(e) return tostring(e) end) }
    if results[1] then
        return unpack(results, 2)
    else
        Log:error("Error in %s for animal '%s': %s",
            context, tostring(animal.uniqueId or "unknown"), tostring(results[2]))
        printCallstack()
        if defaults then return unpack(defaults) end
    end
end
