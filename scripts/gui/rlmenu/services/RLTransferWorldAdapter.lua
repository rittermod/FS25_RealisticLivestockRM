--[[
    RLTransferWorldAdapter.lua
    The WORLD counterpart adapter behind the RLTransferAdapter seam.

    When a trailer is triggered standalone (no pen, no dealer), the Transfer frame's
    other side is the free rideables in the trailer's trigger zone. This adapter ROUTES
    the 4-method seam to RLTrailerWorldService and never builds events or mutates state
    itself; dispatch fires the SAME AnimalLoadEvent / AnimalUnloadEvent the legacy
    AnimalScreenTrailer fired.

    Tier: IN-GAME (derefs RLTrailerWorldService, g_i18n and the engine getters). Stateless
    - it reads everything from the passed context. Registered at load into
    RLTransferAdapter._adapters[RLMenuTabPolicy.WORLD]; the headless harness never sources
    this file, so the seam stays NULL there.
]]

RLTransferWorldAdapter = {}

local Log = RmLogging.getLogger("RLRM")

--- Display data for the world sidebar entry: the resolved name and the rideable count.
--- The world side has no bounded capacity, so used == total, derived from the same
--- builder enumerate uses so the count cannot diverge from the list.
--- @param context table  { trailer = <livestock trailer>, ... }
--- @return table display  { name, used, total }
function RLTransferWorldAdapter:getDisplayData(context)
    local name = g_i18n:getText(RLTransferAdapter.WORLD_NAME_KEY)
    local trailer = context ~= nil and context.trailer or nil
    if trailer == nil then
        Log:trace("RLTransferWorldAdapter:getDisplayData: nil trailer -> empty count")
        return { name = name, used = 0, total = 0 }
    end
    local n = RLTrailerWorldService.countSourceItems(trailer)
    Log:trace("RLTransferWorldAdapter:getDisplayData: name='%s' count=%d", tostring(name), n)
    return { name = name, used = n, total = n }
end

--- Enumerate the trigger rideables as AnimalItemStock items (each exposes .cluster).
---
--- REPLACES context.clusterToVehicle with this build's map each call, so dispatch always
--- recovers rideables from the CURRENT build and selection stays in lockstep with it.
--- @param context table  { trailer = <livestock trailer>, ... }
--- @return table items
function RLTransferWorldAdapter:enumerate(context)
    local trailer = context ~= nil and context.trailer or nil
    if trailer == nil then
        Log:trace("RLTransferWorldAdapter:enumerate: nil trailer -> {}")
        return {}
    end
    local items, clusterToVehicle = RLTrailerWorldService.buildSourceItems(trailer)
    if context ~= nil then
        context.clusterToVehicle = clusterToVehicle
    end
    Log:trace("RLTransferWorldAdapter:enumerate: %d item(s)", #items)
    return items
end

--- The footer action-label i18n KEY for a direction; the frame resolves the key.
--- @param direction string  DIR_INTO_TRAILER | DIR_OUT_OF_TRAILER
--- @return string i18nKey
function RLTransferWorldAdapter:actionLabel(direction)
    return RLTransferAdapter.worldActionLabelKey(direction)
end

--- Route the selected world animals to RLTrailerWorldService for the direction's plan.
---
--- Fail-closed: a false return means nothing dispatched and no completion fires, so the
--- frame releases movePending itself. A true return guarantees the service fires
--- context.onComplete exactly once.
--- @param direction string  DIR_INTO_TRAILER | DIR_OUT_OF_TRAILER
--- @param animals table  the selected clusters (current-build .cluster refs)
--- @param context table  { trailer, clusterToVehicle, onComplete, ... }
--- @return boolean routed
function RLTransferWorldAdapter:dispatch(direction, animals, context)
    local plan = RLTransferAdapter.resolveMovePlan(direction)
    local trailer = context ~= nil and context.trailer or nil

    if plan == nil or trailer == nil or animals == nil or #animals == 0 then
        Log:debug("RLTransferWorldAdapter:dispatch: no-op (plan=%s, trailer=%s, animals=%d)",
            tostring(plan), tostring(trailer), animals ~= nil and #animals or 0)
        return false
    end

    if direction == RLTransferAdapter.DIR_INTO_TRAILER then
        local map = (context ~= nil and context.clusterToVehicle) or {}
        local rideables = {}
        for _, cluster in ipairs(animals) do
            local rideable = map[cluster]
            if rideable ~= nil then
                rideables[#rideables + 1] = rideable
            else
                -- Selection comes from the build that rebuilt the map, so a miss is an
                -- invariant breach rather than a normal condition.
                Log:warning("RLTransferWorldAdapter:dispatch: cluster '%s' has no rideable mapping (invariant breach), dropping it",
                    tostring(cluster ~= nil and cluster.uniqueId or cluster))
            end
        end
        if #rideables == 0 then
            Log:debug("RLTransferWorldAdapter:dispatch: load mapped to 0 rideables after drops, no-op")
            return false
        end
        Log:debug("RLTransferWorldAdapter:dispatch: load %d rideable(s) into trailer", #rideables)
        RLTrailerWorldService.loadRideables(trailer, rideables, context.onComplete)
        return true
    end

    -- Unload by RESOLVED wire id - the 3-part identity toKey that getClusterById matches,
    -- not the never-updated "0-0" placeholder cluster.id.
    local clusterIds = {}
    for _, cluster in ipairs(animals) do
        local id = RLAnimalUtil.resolveClusterId(cluster)
        if id ~= nil then
            clusterIds[#clusterIds + 1] = id
        else
            Log:warning("RLTransferWorldAdapter:dispatch: unload cluster '%s' has no resolvable id, dropping it",
                tostring(cluster ~= nil and cluster.uniqueId or cluster))
        end
    end
    if #clusterIds == 0 then
        Log:debug("RLTransferWorldAdapter:dispatch: unload mapped to 0 cluster ids after drops, no-op")
        return false
    end
    Log:debug("RLTransferWorldAdapter:dispatch: unload %d cluster(s) from trailer", #clusterIds)
    RLTrailerWorldService.unloadClusters(trailer, clusterIds, context.onComplete)
    return true
end

-- Register at load so forCounterpart("world") resolves this adapter in-game. The registry
-- is a plain Lua table, so this is registration ceremony rather than game state.
RLTransferAdapter._adapters[RLMenuTabPolicy.WORLD] = RLTransferWorldAdapter

Log:debug("RLTransferWorldAdapter: loaded and registered for counterpart '%s'", tostring(RLMenuTabPolicy.WORLD))
