--[[
    RLTransferPenAdapter.lua
    The PEN counterpart adapter behind the RLTransferAdapter seam.

    When a trailer is triggered at an animal pen, the Transfer frame's other side is that
    pen. This adapter reads the husbandry from context.counterpartHandle and routes a
    confirmed transfer to RLAnimalMoveService.moveAnimals - the SAME AnimalMoveEvent the
    legacy trailer-at-pen controller fired. It ROUTES; it never constructs the event.

    Tier: IN-GAME (derefs RLAnimalQuery, RLAnimalMoveService and the engine husbandry
    getters). Stateless - it reads everything from the passed context. Registered at load
    into RLTransferAdapter._adapters[RLMenuTabPolicy.PEN]; the headless harness never
    sources this file, so the seam stays NULL there.
]]

RLTransferPenAdapter = {}

local Log = RmLogging.getLogger("RLRM")

--- Display data for the pen sidebar entry: the pen's engine name and its used / total
--- counts, where total is `used + getNumOfFreeAnimalSlots()` (the per-pen free total, not
--- the subtype-sensitive getMaxNumOfAnimals form).
--- @param context table  { counterpartHandle = <husbandry placeable>, ... }
--- @return table display  { name, used, total }
function RLTransferPenAdapter:getDisplayData(context)
    local husbandry = context ~= nil and context.counterpartHandle or nil
    if husbandry == nil then
        Log:trace("RLTransferPenAdapter:getDisplayData: nil husbandry -> empty display")
        return { name = "", used = 0, total = 0 }
    end

    local name = (husbandry.getName ~= nil and husbandry:getName()) or ""
    local used = (husbandry.getNumOfAnimals ~= nil and husbandry:getNumOfAnimals()) or 0
    local free = (husbandry.getNumOfFreeAnimalSlots ~= nil and husbandry:getNumOfFreeAnimalSlots()) or 0
    local total = used + free
    Log:trace("RLTransferPenAdapter:getDisplayData: name='%s' used=%d free=%d total=%d",
        tostring(name), used, free, total)
    return { name = name, used = used, total = total }
end

--- Enumerate the pen's animals as sorted AnimalItemStock items, via the same helper the
--- shipped Move frame uses. No pre-filter by the trailer's locked type (legacy
--- initTargetItems parity - the move service is the type and capacity gate).
--- @param context table  { counterpartHandle = <husbandry placeable>, ... }
--- @return table items
function RLTransferPenAdapter:enumerate(context)
    local husbandry = context ~= nil and context.counterpartHandle or nil
    if husbandry == nil then
        Log:trace("RLTransferPenAdapter:enumerate: nil husbandry -> {}")
        return {}
    end
    local items = RLAnimalQuery.listAnimalsForHusbandry(husbandry, nil) or {}
    Log:trace("RLTransferPenAdapter:enumerate: %d item(s)", #items)
    return items
end

--- The footer action-label i18n KEY for a direction; the frame resolves the key.
--- @param direction string  DIR_INTO_TRAILER | DIR_OUT_OF_TRAILER
--- @return string i18nKey
function RLTransferPenAdapter:actionLabel(direction)
    return RLTransferAdapter.penActionLabelKey(direction)
end

--- Route the selected animals to RLAnimalMoveService.moveAnimals for the direction's plan,
--- mapping the resolved sides onto the real objects. Fail-closed on a nil plan or a missing
--- endpoint: no dispatch, and the frame leaves its state unchanged.
--- @param direction string  DIR_INTO_TRAILER | DIR_OUT_OF_TRAILER
--- @param animals table  the selected animals (clusters)
--- @param context table  { trailer, counterpartHandle, onComplete, ... }
--- @return boolean routed
function RLTransferPenAdapter:dispatch(direction, animals, context)
    local plan = RLTransferAdapter.resolveMovePlan(direction)
    local counterpart = context ~= nil and context.counterpartHandle or nil
    local trailer = context ~= nil and context.trailer or nil

    if plan == nil or counterpart == nil or trailer == nil then
        Log:debug("RLTransferPenAdapter:dispatch: no-op (plan=%s, counterpart=%s, trailer=%s)",
            tostring(plan), tostring(counterpart), tostring(trailer))
        return false
    end

    local source = (plan.sourceSide == RLTransferAdapter.SIDE_COUNTERPART) and counterpart or trailer
    local target = (plan.targetSide == RLTransferAdapter.SIDE_COUNTERPART) and counterpart or trailer

    Log:debug("RLTransferPenAdapter:dispatch: direction=%s moveType=%s source='%s' target='%s' animals=%d",
        tostring(direction), plan.moveType,
        tostring(source and source.getName and source:getName()),
        tostring(target and target.getName and target:getName()),
        animals ~= nil and #animals or 0)

    -- The move service's accept/reject boolean is propagated rather than an unconditional
    -- true: a false return (a same-class move already in flight) must reach the frame so it
    -- releases movePending instead of waiting on a completion that will never fire.
    local accepted = RLAnimalMoveService.moveAnimals(source, target, animals, plan.moveType, function(errorCode)
        local success = (errorCode == nil or errorCode == AnimalMoveEvent.MOVE_SUCCESS)
        local errorText = (not success) and RLAnimalMoveService.getErrorText(errorCode) or nil
        if context.onComplete ~= nil then
            context.onComplete(success, errorText)
        end
    end)
    if not accepted then
        Log:debug("RLTransferPenAdapter:dispatch: move service rejected the dispatch (returning false so the frame releases movePending)")
    end
    return accepted
end

-- Register at load so forCounterpart("pen") resolves this adapter in-game. The registry is
-- a plain Lua table, so this is registration ceremony rather than game state.
RLTransferAdapter._adapters[RLMenuTabPolicy.PEN] = RLTransferPenAdapter

Log:debug("RLTransferPenAdapter: loaded and registered for counterpart '%s'", tostring(RLMenuTabPolicy.PEN))
