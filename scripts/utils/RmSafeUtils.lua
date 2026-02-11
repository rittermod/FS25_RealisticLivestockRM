RmSafeUtils = {}

--- Wraps a function body in xpcall with traceback logging.
--- Use for outer protection of entire callback handlers.
--- Prevents errors from propagating up and killing the FS25 event dispatch chain
--- (MessageCenter and SpecializationUtil have no pcall protection).
---@param context string  identifier for error messages (e.g. "onDayChanged")
---@param fn function     the function body to protect
---@return boolean ok
function RmSafeUtils.safeCall(context, fn)
    local ok, err = xpcall(fn, function(e)
        return tostring(e) .. "\n" .. debug.traceback("", 2)
    end)
    if not ok then
        Logging.error("RealisticLivestock: Error in %s: %s", context, tostring(err))
    end
    return ok
end

--- Calls fn inside xpcall; returns defaults on error.
--- Use inside animal loops where one bad animal shouldn't kill all.
---@param animal table           the animal (for identity in log)
---@param context string         handler name for log
---@param fn function            function() -> values
---@param defaults table|nil     array of default values on error
---@return ...                   fn results or defaults
function RmSafeUtils.safeAnimalCall(animal, context, fn, defaults)
    local results = { xpcall(fn, function(e)
        return tostring(e) .. "\n" .. debug.traceback("", 2)
    end) }
    if results[1] then
        return unpack(results, 2)
    else
        Logging.error("RealisticLivestock: Error in %s for animal '%s': %s",
            context, tostring(animal.uniqueId or "unknown"), tostring(results[2]))
        if defaults then return unpack(defaults) end
    end
end
