-- RLHusbandryTargetKey.lua
-- Context-keyed identity for a herdsman rule's husbandry targets across the MP wire, and the single
-- home for the key<->placeable mapping at the four boundary sites (wire read/write, picker
-- enumeration, frame name resolver).
--
-- A target is a unique STRING on every machine, but its key space depends on network authority:
--   * server / host / dedi (g_server ~= nil): the placeable's persisted getUniqueId().
--   * a pure client (g_server == nil): tostring(NetworkUtil.getObjectId(placeable)).
--
-- getUniqueId() is a SAVEGAME identifier, and the engine streams it to a client ONLY for preplaced
-- placeables - a player-BOUGHT husbandry streams none, so a client regenerates a non-matching local
-- uniqueId and a uniqueId-keyed target can never match. The node-object id is the universal
-- cross-machine handle, so a client keys uniformly by it for both barn origins.
--
-- g_server is a per-machine AUTHORITY constant after load, so one machine evaluates keyFor and
-- resolve on the same side for read and write: a rule's decoded targets and the picker candidates
-- share one key space.

local Log = RmLogging.getLogger("RLRM")

RLHusbandryTargetKey = {}

--- Derive the stable target key for a live husbandry placeable, branched on network authority.
--- Fails CLOSED: nil plus a warning when the side-appropriate id is missing, never a "nil"/"0"
--- string, so an unkeyable target is skipped rather than stored under a bogus key.
---@param placeable table|nil a live husbandry placeable
---@return string|nil key the uniqueId (server) or net-object-id (client) string, or nil if unkeyable
function RLHusbandryTargetKey.keyFor(placeable)
    if placeable == nil then
        Log:warning("RLHusbandryTargetKey.keyFor: nil placeable; no key")
        return nil
    end

    if g_server ~= nil then
        local uniqueId = placeable.getUniqueId ~= nil and placeable:getUniqueId() or nil
        if type(uniqueId) ~= "string" or uniqueId == "" then
            Log:warning("RLHusbandryTargetKey.keyFor: server placeable '%s' has nil/empty uniqueId; skipping target",
                tostring(placeable.getName ~= nil and placeable:getName() or "?"))
            return nil
        end
        Log:trace("RLHusbandryTargetKey.keyFor: server key=%s (uniqueId)", uniqueId)
        return uniqueId
    end

    -- Client keying routes through the g_client node-object registry (NetworkUtil falls to it when
    -- g_server is nil). Fail closed if it is absent rather than indexing a nil global.
    if g_client == nil then
        Log:warning("RLHusbandryTargetKey.keyFor: client context but g_client is nil; cannot key '%s'",
            tostring(placeable.getName ~= nil and placeable:getName() or "?"))
        return nil
    end

    -- nil/0 means unregistered, which can never round-trip.
    local objectId = NetworkUtil.getObjectId(placeable)
    if objectId == nil or objectId == 0 then
        Log:warning("RLHusbandryTargetKey.keyFor: client placeable '%s' has nil/0 net-object-id; skipping target",
            tostring(placeable.getName ~= nil and placeable:getName() or "?"))
        return nil
    end
    local key = tostring(objectId)
    Log:trace("RLHusbandryTargetKey.keyFor: client key=%s (net-object-id)", key)
    return key
end

--- Resolve a stored target key back to its live placeable, branched on network authority. The
--- client path additionally confirms the resolved object's SHAPE, because a reused or stale net-id
--- could land on something else. A MALFORMED key is a fail-closed warning plus nil; a key that
--- simply resolves to nothing right now returns nil QUIETLY, so the caller chooses the loudness.
---@param key string|nil the stored target key (uniqueId on server, net-object-id on client)
---@param allowEPP boolean|nil admit an EPP-shaped placeable on the client path (move-dest sites only)
---@return table|nil placeable the live placeable, or nil if it does not resolve to an admitted shape
local function resolveInternal(key, allowEPP)
    if type(key) ~= "string" or key == "" then
        return nil
    end

    if g_server ~= nil then
        local mission = g_currentMission
        local ps = mission ~= nil and mission.placeableSystem or nil
        if ps == nil or ps.getPlaceableByUniqueId == nil then
            return nil
        end
        local placeable = ps:getPlaceableByUniqueId(key)
        Log:trace("RLHusbandryTargetKey.resolve: server key=%s allowEPP=%s -> resolved=%s",
            key, tostring(allowEPP == true), tostring(placeable ~= nil))
        return placeable
    end

    if g_client == nil then
        Log:warning("RLHusbandryTargetKey.resolve: client context but g_client is nil; cannot resolve key '%s'", tostring(key))
        return nil
    end

    -- keyFor emits exactly tostring(positive int), so a client key is a run of digits. The digit-run
    -- guard also rejects tonumber-accepted forms ("1e3", "0x64", " 12 ") that could alias a
    -- different net-id.
    if key:match("^%d+$") == nil then
        Log:warning("RLHusbandryTargetKey.resolve: client key '%s' is not a numeric net-object-id; skipping", tostring(key))
        return nil
    end
    local objectId = tonumber(key)
    local object = NetworkUtil.getObject(objectId)
    if object == nil then
        Log:trace("RLHusbandryTargetKey.resolve: client key=%s -> no live object (transient/deleted)", key)
        return nil
    end
    -- A husbandry always admits; an EPP-shaped placeable admits only for the move-dest opt-in.
    local isHusbandry = object.spec_husbandryAnimals ~= nil
    local isEPP = object.spec_extendedProductionPoint ~= nil
    if not isHusbandry and not (allowEPP == true and isEPP) then
        Log:warning("RLHusbandryTargetKey.resolve: client key=%s resolved a non-admitted object (husbandry=%s epp=%s allowEPP=%s); skipping",
            key, tostring(isHusbandry), tostring(isEPP), tostring(allowEPP == true))
        return nil
    end
    Log:trace("RLHusbandryTargetKey.resolve: client key=%s -> placeable (husbandry=%s epp=%s)",
        key, tostring(isHusbandry), tostring(isEPP))
    return object
end

--- Resolve a stored TARGET key to its live husbandry placeable. Husbandry-only on the pure client:
--- this is the shape gate that keeps an EPP out of targetHusbandries. @see resolveInternal.
---@param key string|nil the stored target key (uniqueId on server, net-object-id on client)
---@return table|nil placeable the live husbandry placeable, or nil if it does not resolve
function RLHusbandryTargetKey.resolve(key)
    return resolveInternal(key, false)
end

--- Resolve a stored move-DESTINATION key, admitting an EPP butcher in addition to a husbandry on
--- the pure client - the opt-in that widens the shape gate for move-dest sites only.
--- @see resolveInternal.
---@param key string|nil the stored destination key (uniqueId on server, net-object-id on client)
---@return table|nil placeable the live husbandry or EPP placeable, or nil if it does not resolve
function RLHusbandryTargetKey.resolveDestination(key)
    return resolveInternal(key, true)
end

Log:trace("RLHusbandryTargetKey: loaded")
