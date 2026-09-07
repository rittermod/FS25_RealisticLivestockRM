--[[
    RLTrailerEndpointService.lua
    Read-only query service: reads a base-game livestock trailer as an animal-collection
    endpoint for the transfer frame's pen / dealer / world slices.

    Wraps the LivestockTrailer getters into plain shapes - numbers, booleans, strings and
    live Animal-ref arrays. Stateless module table, no .new; the trailer is passed in, so
    nothing reaches g_*, GUI or XML at load or call time, which is what makes the
    primitives dual-runnable against a mock trailer. Every primitive is nil-safe and
    returns its per-row default rather than crashing.

    Structural support (getSupportsAnimalType) and the current-load lock
    (getCurrentAnimalType) stay DISTINCT: a trailer can structurally support a type it is
    not currently locked to. The fit predicate mirrors legacy applySourceBulk exactly.
]]

RLTrailerEndpointService = {}

local Log = RmLogging.getLogger("RLRM")

-- =============================================================================
-- Internal helper
-- =============================================================================

--- Call a single engine getter under pcall, returning `(true, value)` on a clean call and
--- `(false, nil)` when the trailer is nil, the method is absent, or the call errors. The
--- caller type-checks `value`, so one malformed getter never propagates a crash.
--- @param trailer table|nil
--- @param methodName string
--- @param arg any|nil  single optional argument (every wrapped getter takes 0 or 1)
--- @return boolean ok, any value
local function callGetter(trailer, methodName, arg)
    if trailer == nil or type(trailer[methodName]) ~= "function" then
        return false, nil
    end
    local ok, result = pcall(trailer[methodName], trailer, arg)
    if not ok then
        return false, nil
    end
    return true, result
end

-- =============================================================================
-- Pure predicate (shared with the husbandry side)
-- =============================================================================

--- Capacity predicate: room exists when free slots strictly exceed the already-queued
--- count. The operator is `>` and not `>=` because legacy applySourceBulk rejects when
--- `free <= queued`, so the slot a queued item will occupy is not offered to the next one.
--- @param freeSlots number
--- @param alreadyQueued number
--- @return boolean room
function RLTrailerEndpointService.hasRoom(freeSlots, alreadyQueued)
    return (freeSlots or 0) > (alreadyQueued or 0)
end

-- =============================================================================
-- Read-only primitives
-- =============================================================================

--- The trailer's live contents as an array of Animal refs in engine order.
---
--- Each element of `getClusters()` IS a live Animal in RLRM, and the mutation events need
--- those raw refs, so this returns them rather than a display descriptor. Consumers must
--- not assume positional stability across reads.
--- @param trailer table|nil
--- @return table animals  array of Animal refs ({} when empty / unreadable)
function RLTrailerEndpointService.getContents(trailer)
    if trailer == nil then
        Log:trace("RLTrailerEndpointService.getContents: nil trailer -> {}")
        return {}
    end

    local ok, clusters = callGetter(trailer, "getClusters")
    if not ok then
        Log:warning("RLTrailerEndpointService.getContents: getClusters missing/errored -> {}")
        return {}
    end
    if type(clusters) ~= "table" then
        Log:trace("RLTrailerEndpointService.getContents: no clusters -> {}")
        return {}
    end

    local contents = {}
    for _, animal in ipairs(clusters) do
        contents[#contents + 1] = animal
    end
    Log:trace("RLTrailerEndpointService.getContents: %d animal(s)", #contents)
    return contents
end

--- The trailer's current-load type lock, or nil when empty / unlocked. The lock follows
--- the type of the first loaded cluster.
--- @param trailer table|nil
--- @return table|nil animalType  type table (`.typeIndex` guaranteed) or nil
function RLTrailerEndpointService.getCurrentType(trailer)
    if trailer == nil then
        Log:trace("RLTrailerEndpointService.getCurrentType: nil trailer -> nil")
        return nil
    end

    local ok, animalType = callGetter(trailer, "getCurrentAnimalType")
    if not ok then
        Log:warning("RLTrailerEndpointService.getCurrentType: getCurrentAnimalType missing/errored -> nil")
        return nil
    end
    if animalType == nil then
        Log:trace("RLTrailerEndpointService.getCurrentType: empty/unlocked -> nil")
        return nil
    end
    if type(animalType) ~= "table" or animalType.typeIndex == nil then
        Log:warning("RLTrailerEndpointService.getCurrentType: malformed type table (no .typeIndex) -> nil")
        return nil
    end

    Log:debug("RLTrailerEndpointService.getCurrentType: locked to typeIndex=%s", tostring(animalType.typeIndex))
    return animalType
end

--- Whether the trailer STRUCTURALLY supports a type, independent of what is aboard: a
--- multi-capable trailer keeps supporting every type it was built for once loaded, while
--- getCurrentType narrows to one.
--- @param trailer table|nil
--- @param typeIndex number
--- @return boolean supported
function RLTrailerEndpointService.supportsType(trailer, typeIndex)
    if trailer == nil then
        Log:trace("RLTrailerEndpointService.supportsType: nil trailer -> false")
        return false
    end

    local ok, supported = callGetter(trailer, "getSupportsAnimalType", typeIndex)
    if not ok or type(supported) ~= "boolean" then
        Log:warning("RLTrailerEndpointService.supportsType: malformed trailer/result (typeIndex=%s) -> false",
            tostring(typeIndex))
        return false
    end
    Log:trace("RLTrailerEndpointService.supportsType: typeIndex=%s -> %s", tostring(typeIndex), tostring(supported))
    return supported
end

--- Whether a subtype can still be added given a running queued count, wrapping
--- `getNumOfFreeAnimalSlots(subTypeIndex)` through hasRoom for legacy parity.
--- @param trailer table|nil
--- @param subTypeIndex number
--- @param alreadyQueued number|nil  running count already committed this transfer (default 0)
--- @return boolean hasRoom
function RLTrailerEndpointService.trailerHasFreeSlot(trailer, subTypeIndex, alreadyQueued)
    alreadyQueued = alreadyQueued or 0

    if trailer == nil then
        Log:trace("RLTrailerEndpointService.trailerHasFreeSlot: nil trailer -> false")
        return false
    end

    local ok, freeSlots = callGetter(trailer, "getNumOfFreeAnimalSlots", subTypeIndex)
    if not ok or type(freeSlots) ~= "number" then
        Log:warning("RLTrailerEndpointService.trailerHasFreeSlot: malformed trailer/result (subTypeIndex=%s) -> false",
            tostring(subTypeIndex))
        return false
    end

    local room = RLTrailerEndpointService.hasRoom(freeSlots, alreadyQueued)
    Log:debug("RLTrailerEndpointService.trailerHasFreeSlot: subTypeIndex=%s free=%d queued=%d -> %s",
        tostring(subTypeIndex), freeSlots, alreadyQueued, tostring(room))
    return room
end

--- Display payload for a trailer row: name plus used / total slot counts. Capacity is
--- per-type, so `total` is 0 for an empty or unlocked trailer - engine truth, not a bug;
--- how that renders is the frame's call.
--- @param trailer table|nil
--- @return table display  { name = string, used = number, total = number }
function RLTrailerEndpointService.getDisplayData(trailer)
    if trailer == nil then
        Log:trace("RLTrailerEndpointService.getDisplayData: nil trailer -> defaults")
        return { name = "", used = 0, total = 0 }
    end

    local name = ""
    local okName, n = callGetter(trailer, "getName")
    if okName and type(n) == "string" then name = n end

    local used = 0
    local okUsed, u = callGetter(trailer, "getNumOfAnimals")
    if okUsed and type(u) == "number" then used = u end

    -- total is keyed to the current lock; getMaxNumOfAnimals(nil) is 0 when unlocked.
    local total = 0
    local currentType = RLTrailerEndpointService.getCurrentType(trailer)
    local okTotal, t = callGetter(trailer, "getMaxNumOfAnimals", currentType)
    if okTotal and type(t) == "number" then total = t end

    Log:trace("RLTrailerEndpointService.getDisplayData: name='%s' used=%d total=%d", name, used, total)
    return { name = name, used = used, total = total }
end

--- Whether the trailer holds zero animals; a nil or unreadable trailer reads as empty.
--- @param trailer table|nil
--- @return boolean empty
function RLTrailerEndpointService.isEmpty(trailer)
    local ok, used = callGetter(trailer, "getNumOfAnimals")
    if not ok or type(used) ~= "number" then
        Log:trace("RLTrailerEndpointService.isEmpty: invalid trailer -> true")
        return true
    end
    return used == 0
end

--- Whether the trailer is at capacity for its current load; an empty or unlocked trailer
--- is never full. `used >= total` is exactly `getNumOfFreeAnimalSlots(currentSubType) <= 0`
--- without needing a subtype handle, which would mean reaching the animalSystem this
--- service deliberately never touches.
--- @param trailer table|nil
--- @return boolean full
function RLTrailerEndpointService.isFull(trailer)
    local currentType = RLTrailerEndpointService.getCurrentType(trailer)
    if currentType == nil then
        Log:trace("RLTrailerEndpointService.isFull: empty/unlocked -> false")
        return false
    end

    local okUsed, used = callGetter(trailer, "getNumOfAnimals")
    local okTotal, total = callGetter(trailer, "getMaxNumOfAnimals", currentType)
    if not okUsed or type(used) ~= "number" or not okTotal or type(total) ~= "number" then
        Log:warning("RLTrailerEndpointService.isFull: invalid trailer -> false")
        return false
    end

    local full = used >= total
    Log:debug("RLTrailerEndpointService.isFull: used=%d total=%d -> %s", used, total, tostring(full))
    return full
end
