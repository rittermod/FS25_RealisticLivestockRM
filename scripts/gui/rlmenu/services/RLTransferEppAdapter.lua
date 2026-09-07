--[[
    RLTransferEppAdapter.lua
    The EPP (butcher) counterpart adapter behind the RLTransferAdapter seam, reached when
    RLAnimalScreenBridge's onOpen redirect reroutes a third-party EPP butcher trigger into
    RLMenu MODE_TRAILER.

    The butcher is a pure SINK - you deliver a loaded trailer to it and never pull animals
    back out - so this adapter is ONE-WAY: it enumerates nothing, and dispatch guards the
    reverse direction BEFORE any move, then routes the deliver to
    RLAnimalMoveService.moveAnimals, the SAME AnimalMoveEvent leg the vanilla EPP screen
    fires. context.counterpartHandle IS the production point. moveAnimals auto-detects a pp
    target by its animalsTypeData and age/type-filters before dispatch, with the server
    rechecking, so no new validation lives here. Tier: IN-GAME; stateless; registered at load.
]]

RLTransferEppAdapter = {}

local Log = RmLogging.getLogger("RLRM")

--- Resolve the subtype the trailer is carrying so the butcher's per-subtype free-slot
--- count can be read. The EPP trigger only activates with a loaded trailer, so a real
--- subtype is normally present; scans the live contents for the first animal with a
--- real subTypeIndex (all animals aboard share one type). nil when empty / unreadable.
--- @param trailer table|nil
--- @return number|nil subTypeIndex
local function resolveTrailerSubTypeIndex(trailer)
    if trailer == nil then
        return nil
    end
    local contents = RLTrailerEndpointService.getContents(trailer)
    for _, animal in ipairs(contents) do
        if animal.subTypeIndex ~= nil then
            return animal.subTypeIndex
        end
    end
    return nil
end

--- Sidebar display data for the butcher: its engine name and free slots for the trailer's
--- subtype. `used` is 0, because a butcher consumes deliveries and exposes no meaningful
--- current count, so a FULL butcher renders (0/0) and the capacity error surfaces on the
--- confirmed deliver. The name is an ENGINE STRING, used verbatim by the frame.
--- @param context table  { counterpartHandle = <production point>, trailer = <trailer>, ... }
--- @return table display  { name, used, total }
function RLTransferEppAdapter:getDisplayData(context)
    local pp = context ~= nil and context.counterpartHandle or nil
    if pp == nil then
        Log:trace("RLTransferEppAdapter:getDisplayData: nil pp -> empty display")
        return { name = "", used = 0, total = 0 }
    end

    local placeable = pp.owningPlaceable
    local name = (placeable ~= nil and placeable.getName ~= nil and placeable:getName()) or ""

    local free = 0
    local subTypeIndex = resolveTrailerSubTypeIndex(context ~= nil and context.trailer or nil)
    if subTypeIndex ~= nil and pp.getNumOfFreeAnimalSlots ~= nil then
        free = pp:getNumOfFreeAnimalSlots(subTypeIndex) or 0
    end

    Log:trace("RLTransferEppAdapter:getDisplayData: name='%s' subTypeIndex=%s free=%d",
        tostring(name), tostring(subTypeIndex), free)
    return { name = name, used = 0, total = free }
end

--- The butcher side lists NOTHING - it is a sink, you never pull animals out of it.
--- Always returns {} (the frame renders empty-state text and hides the action button
--- on this side, the same as the NULL adapter). Nil-safe by construction.
--- @param _context table  ignored
--- @return table items  always empty
function RLTransferEppAdapter:enumerate(_context)
    Log:trace("RLTransferEppAdapter:enumerate: sink -> {} (butcher lists nothing)")
    return {}
end

--- The footer action-label i18n KEY for a direction. Delegates to the pure
--- eppActionLabelKey ("Deliver"); the frame resolves the returned KEY.
--- @param direction string  DIR_INTO_TRAILER | DIR_OUT_OF_TRAILER
--- @return string i18nKey
function RLTransferEppAdapter:actionLabel(direction)
    return RLTransferAdapter.eppActionLabelKey(direction)
end

--- Deliver the selected animals to the butcher. ONE-WAY: pulling FROM the butcher is
--- refused BEFORE any plan resolution or dispatch, so the sink can never mutate the
--- trailer. The deliver direction routes to the SAME move event the vanilla EPP screen
--- fires. The result is wrapped into the frame's uniform completion contract, and the
--- accept flag propagates so the frame releases its lock on a false return.
--- @param direction string  DIR_INTO_TRAILER | DIR_OUT_OF_TRAILER
--- @param animals table  the selected trailer animals (clusters)
--- @param context table  { trailer, counterpartHandle = <pp>, onComplete, ... }
--- @return boolean routed
function RLTransferEppAdapter:dispatch(direction, animals, context)
    -- One-way sink: NEVER pull animals FROM the butcher back into the trailer. Guard
    -- the reverse direction FIRST, before resolving a plan or touching moveAnimals.
    if direction == RLTransferAdapter.DIR_INTO_TRAILER then
        Log:debug("RLTransferEppAdapter:dispatch: reverse (into-trailer) refused - butcher is a sink, no move")
        return false
    end

    local plan = RLTransferAdapter.resolveMovePlan(direction)
    local pp = context ~= nil and context.counterpartHandle or nil
    local trailer = context ~= nil and context.trailer or nil

    if plan == nil or pp == nil or trailer == nil then
        Log:debug("RLTransferEppAdapter:dispatch: no-op (plan=%s, pp=%s, trailer=%s)",
            tostring(plan), tostring(pp), tostring(trailer))
        return false
    end

    -- Source is the trailer, target the production point. The move service filters
    -- CLIENT-side before dispatch and the server rechecks; one request goes out only if
    -- survivors exist, and the callback fires exactly once, synchronously if none do.
    Log:debug("RLTransferEppAdapter:dispatch: deliver %d animal(s) trailer -> butcher '%s' (moveType=%s)",
        animals ~= nil and #animals or 0,
        tostring(pp.owningPlaceable ~= nil and pp.owningPlaceable.getName ~= nil and pp.owningPlaceable:getName()),
        plan.moveType)

    local accepted = RLAnimalMoveService.moveAnimals(trailer, pp, animals, plan.moveType, function(errorCode)
        local success = (errorCode == nil or errorCode == AnimalMoveEvent.MOVE_SUCCESS)
        local errorText = (not success) and RLAnimalMoveService.getErrorText(errorCode) or nil
        if context.onComplete ~= nil then
            context.onComplete(success, errorText)
        end
    end)
    if not accepted then
        Log:debug("RLTransferEppAdapter:dispatch: move service rejected the dispatch (returning false so the frame releases movePending)")
    end
    return accepted
end

-- Register at load so forCounterpart("epp") resolves this adapter in-game. The registry
-- is a plain Lua table (assigning into it is registration ceremony, not game state - the
-- sanctioned load-time escape). Keyed by RLMenuTabPolicy.EPP, which equals
-- g_rlMenu.trailerCounterpart for the EPP onOpen redirect.
RLTransferAdapter._adapters[RLMenuTabPolicy.EPP] = RLTransferEppAdapter

Log:debug("RLTransferEppAdapter: loaded and registered for counterpart '%s'", tostring(RLMenuTabPolicy.EPP))
