-- RLPermissionHelper.lua
-- The permission + farm-scope decision for server-side event validation, and the matching
-- client-side read. FarmManager is read at call time only, so the module load stays
-- game-state-free.

local Log = RmLogging.getLogger("RLRM")

RLPermissionHelper = {}

--- Rejection reasons returned by `authorize`, and the text a caller renders into its
--- rejection warning so a server log says which arm refused a request.
RLPermissionHelper.REASON = {
    NO_PERMISSION = "NO_PERMISSION",
    INVALID_REQUESTER = "INVALID_REQUESTER",
    INVALID_OWNER = "INVALID_OWNER",
    SCOPE_MISMATCH = "SCOPE_MISMATCH",
}


--- Test whether a farm id denotes a real, actionable player farm.
---
--- `> 0` rejects the spectator farm and the upper bound rejects the reserved guided-tour
--- and invalid ids; all three reach a permission check as ordinary-looking numbers.
---@param id any Candidate farm id
---@return boolean valid True when the id denotes a real player farm
local function isRealFarmId(id)
    return type(id) == "number" and id > 0 and id <= FarmManager.MAX_NUM_FARMS
end


--- The whole authorization decision, as a pure function over plain data.
---
--- Both ids are validated before they are compared: farm id 0 reaches both sides at once -
--- a requester lookup falls through to the spectator farm, an unowned pen reports owner 0 -
--- so a bare `~=` evaluates `0 ~= 0` and authorizes.
---@param hasPermission any The permission read for the requester; anything but `true` rejects
---@param requesterFarmId any The requesting player's resolved farm id
---@param ownerFarmId any The target object's owning farm id
---@return boolean ok True when the request is authorized
---@return string|nil reason A `RLPermissionHelper.REASON` value when rejected, nil when authorized
function RLPermissionHelper.authorize(hasPermission, requesterFarmId, ownerFarmId)
    if hasPermission ~= true then
        Log:trace("RLPermissionHelper.authorize: rejected NO_PERMISSION (hasPermission=%s)",
            tostring(hasPermission))
        return false, RLPermissionHelper.REASON.NO_PERMISSION
    end

    if not isRealFarmId(requesterFarmId) then
        Log:trace("RLPermissionHelper.authorize: rejected INVALID_REQUESTER (requesterFarmId=%s)",
            tostring(requesterFarmId))
        return false, RLPermissionHelper.REASON.INVALID_REQUESTER
    end

    if not isRealFarmId(ownerFarmId) then
        Log:trace("RLPermissionHelper.authorize: rejected INVALID_OWNER (ownerFarmId=%s)",
            tostring(ownerFarmId))
        return false, RLPermissionHelper.REASON.INVALID_OWNER
    end

    if requesterFarmId ~= ownerFarmId then
        Log:trace("RLPermissionHelper.authorize: rejected SCOPE_MISMATCH (requesterFarmId=%s ownerFarmId=%s)",
            tostring(requesterFarmId), tostring(ownerFarmId))
        return false, RLPermissionHelper.REASON.SCOPE_MISMATCH
    end

    Log:trace("RLPermissionHelper.authorize: authorized (farmId=%s)", tostring(requesterFarmId))
    return true, nil
end


--- Resolve the requesting user and farm from a connection, then authorize against a target's
--- owning farm.
---@param connection table The network connection the request arrived on
---@param permissionKey string Permission name, e.g. "tradeAnimals"
---@param ownerFarmId any The target object's owning farm id
---@return boolean ok True when the request is authorized
---@return string|nil reason A `RLPermissionHelper.REASON` value when rejected, nil when authorized
---@return string userName The requesting player's nickname, or "unknown"
---@return any userId The requesting player's unique user id
---@return any requesterFarmId The requester's resolved farm id, as fed to `authorize`
function RLPermissionHelper.authorizeConnection(connection, permissionKey, ownerFarmId)
    local userId = g_currentMission.userManager:getUniqueUserIdByConnection(connection)
    local userName = (g_currentMission.userManager:getUserByConnection(connection) or {}).nickname or "unknown"
    Log:trace("RLPermissionHelper.authorizeConnection: resolved user '%s' (userId=%s)",
        tostring(userName), tostring(userId))

    local hasPermission = g_currentMission:getHasPlayerPermission(permissionKey, connection)
    Log:trace("RLPermissionHelper.authorizeConnection: permission '%s' = %s",
        tostring(permissionKey), tostring(hasPermission))

    local userFarm = g_farmManager:getFarmForUniqueUserId(userId)
    local requesterFarmId = userFarm ~= nil and userFarm.farmId or nil
    Log:trace("RLPermissionHelper.authorizeConnection: resolved requesterFarmId=%s ownerFarmId=%s",
        tostring(requesterFarmId), tostring(ownerFarmId))

    local ok, reason = RLPermissionHelper.authorize(hasPermission, requesterFarmId, ownerFarmId)
    return ok, reason, userName, userId, requesterFarmId
end


--- Read a permission for the local player, for client-side UX gating only.
---
--- Never a security boundary - the server revalidates every request regardless.
---@param permissionKey string Permission name, e.g. "tradeAnimals"
---@return boolean granted True only when the local player holds the permission
function RLPermissionHelper.hasLocalPermission(permissionKey)
    local granted = g_currentMission ~= nil
        and g_currentMission.getHasPlayerPermission ~= nil
        and g_currentMission:getHasPlayerPermission(permissionKey) == true

    Log:trace("RLPermissionHelper.hasLocalPermission: '%s' = %s",
        tostring(permissionKey), tostring(granted))
    return granted
end

Log:trace("RLPermissionHelper: loaded")
