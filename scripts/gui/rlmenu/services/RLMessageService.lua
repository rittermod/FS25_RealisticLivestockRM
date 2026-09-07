--[[
    RLMessageService.lua
    Query + delete service for the RL Tabbed Menu Messages tab.

    getMessagesForFarm builds a unioned, newest-first, display-ready list
    of husbandry messages for a farm; it's read-only and safe on both
    server and client (clients receive messages via HusbandryMessageStateEvent).

    deleteMessages is the mutation path, using Pattern A
    (caller mutates local state first, then dispatches
    HusbandryMessageDeleteEvent for rebroadcast).
]]

RLMessageService = {}

local Log = RmLogging.getLogger("RLRM")

--- Parse a "d/m/yyyy" date string into integer (year, month, day) parts.
--- Malformed or nil input returns (0, 0, 0) and emits a single warning.
--- The (0,0,0) sentinel keeps malformed entries in the list but sorts them
--- to the bottom under the newest-first comparator.
--- @param dateStr string|nil Raw message.date string from PlaceableHusbandryAnimals
--- @return number year
--- @return number month
--- @return number day
function RLMessageService.parseDate(dateStr)
    if dateStr == nil then
        Log:warning("RLMessageService.parseDate: nil date string")
        return 0, 0, 0
    end

    local d, m, y = string.match(dateStr, "^(%d+)/(%d+)/(%d+)$")
    if d == nil or m == nil or y == nil then
        Log:warning("RLMessageService.parseDate: malformed date '%s'", tostring(dateStr))
        return 0, 0, 0
    end

    return tonumber(y), tonumber(m), tonumber(d)
end

--- Substitute the tokens in a localized message template from message.args, resolving an
--- rl_*-prefixed arg through g_i18n first. The space-split approach is fragile for
--- punctuation-heavy templates, but every existing translation was authored against this
--- exact behaviour, so diverging would silently break translated text.
--- TODO: rework the substitution once translations can be regenerated.
--- @param template string Localized template string (output of g_i18n:getText)
--- @param args table|nil Argument list from the raw message record
--- @return string Substituted text
local function substituteTokens(template, args)
    Log:trace("RLMessageService.substituteTokens: template='%s'", tostring(template))
    local tokens = string.split(template, " ")
    local argI = 1

    -- ipairs (not pairs) because the token table is a contiguous array and
    -- substitution order must match the positional %s argument sequence.
    for i, token in ipairs(tokens) do
        if token == "%s" then
            local arg = (args and args[argI]) or ""
            if string.contains(arg, "rl_") then
                tokens[i] = g_i18n:getText(arg)
            else
                tokens[i] = arg
            end
            argI = argI + 1
        elseif token == "'%s'" then
            local arg = (args and args[argI]) or ""
            if string.contains(arg, "rl_") then
                tokens[i] = "'" .. g_i18n:getText(arg) .. "'"
            else
                tokens[i] = "'" .. arg .. "'"
            end
            argI = argI + 1
        end
    end

    return table.concat(tokens, " ")
end

--- Format one message record into a display-ready row; an unknown id falls back to a
--- sentinel row plus a single warning.
---
--- Row schema (contract for the frame layer):
---   importanceSlice  : "realistic_livestock.importance_<1|2|3>"
---   typeText         : localized rl_messageTitle_<title>
---   animalText       : message.animal or "N/A"
---   messageText      : localized + token-substituted body
---   husbandryName    : placeable:getName() captured by caller (display-only)
---   date             : raw message.date string for display
---   sortKey          : { year, month, day, husbandryIndex, insertionIndex } desc
---   husbandryRef     : placeable reference (opaque delete token; frame MUST treat as opaque)
---   uniqueId         : int (raw message.uniqueId; used for delete routing)
--- @param message table Raw message record (id/animal/args/date/uniqueId)
--- @param husbandry table Source husbandry placeable (stored as opaque delete token)
--- @param husbandryIndex number Stable per-call index of the husbandry within getPlaceablesByFarm
--- @param insertionIndex number 1-based position of the message inside its source list
--- @return table row
function RLMessageService.formatMessage(message, husbandry, husbandryIndex, insertionIndex)
    local year, month, day = RLMessageService.parseDate(message.date)
    local sortKey = { year, month, day, husbandryIndex, insertionIndex }
    local husbandryName = (husbandry ~= nil and husbandry.getName and husbandry:getName()) or "Unknown"

    local baseMessage = RLMessage[message.id]
    if baseMessage == nil then
        Log:warning("RLMessageService.formatMessage: unknown message id '%s' (date=%s)",
            tostring(message.id), tostring(message.date))
        return {
            importanceSlice = "realistic_livestock.importance_3",
            typeText        = "?",
            animalText      = message.animal or "N/A",
            messageText     = string.format(g_i18n:getText("rl_menu_messages_unknown"), tostring(message.id)),
            husbandryName   = husbandryName,
            date            = message.date or "",
            sortKey         = sortKey,
            husbandryRef    = husbandry,
            uniqueId        = message.uniqueId,
        }
    end

    local template    = g_i18n:getText("rl_message_" .. baseMessage.text)
    local messageText = substituteTokens(template, message.args)

    return {
        importanceSlice = string.format("realistic_livestock.importance_%d", baseMessage.importance),
        typeText        = g_i18n:getText("rl_messageTitle_" .. baseMessage.title),
        animalText      = message.animal or "N/A",
        messageText     = messageText,
        husbandryName   = husbandryName,
        date            = message.date or "",
        sortKey         = sortKey,
        husbandryRef    = husbandry,
        uniqueId        = message.uniqueId,
    }
end

--- Newest-first comparator over the sortKey tuple. The cross-husbandry tie-break is
--- heuristic and can drift between host and client, since placeable iteration order is
--- not guaranteed identical - the content matches, only same-day ordering differs.
--- Deliberately NOT logged: table.sort calls this thousands of times per refresh.
--- @param a table Row a (must have sortKey)
--- @param b table Row b (must have sortKey)
--- @return boolean
function RLMessageService.compareRows(a, b)
    local ka = a.sortKey
    local kb = b.sortKey
    for i = 1, 5 do
        if ka[i] ~= kb[i] then
            return ka[i] > kb[i]
        end
    end
    return false
end

--- Resolve a farm's placeables through the standard guard chain, returning nil on any
--- miss so callers early-out on one check. A swappable field, so a test can inject a
--- deterministic array without standing up the mission fakes. Both the read and the clear
--- path consume this one resolver, so their guards cannot drift.
--- @type function
--- @param farmId number|nil Farm id (typically g_currentMission:getFarmId())
--- @return table|nil placeables Array of placeables on the farm, or nil if any guard fired
RLMessageService._resolvePlaceables = function(farmId)
    Log:trace("RLMessageService._resolvePlaceables: farmId=%s", tostring(farmId))

    if farmId == nil or farmId == 0 then
        Log:trace("RLMessageService._resolvePlaceables: no farm, returning nil")
        return nil
    end

    if g_currentMission == nil or g_currentMission.husbandrySystem == nil then
        Log:warning("RLMessageService._resolvePlaceables: husbandrySystem unavailable")
        return nil
    end

    local placeables = g_currentMission.husbandrySystem:getPlaceablesByFarm(farmId)
    if placeables == nil then
        Log:trace("RLMessageService._resolvePlaceables: no placeables for farm %d", farmId)
        return nil
    end

    return placeables
end

--- Build the unioned, display-ready, newest-first list of messages for a farm.
--- Walks every husbandry placeable on the farm (resolved via the shared
--- _resolvePlaceables hook), unions their getRLMessages() via formatMessage,
--- and sorts the result. Read-only and side-effect-free on both server
--- and client.
--- @param farmId number|nil Farm id (typically g_currentMission:getFarmId())
--- @return table rows[] Array of formatted row tables; empty if the resolver returns nil
function RLMessageService.getMessagesForFarm(farmId)
    Log:debug("RLMessageService.getMessagesForFarm: farmId=%s", tostring(farmId))

    local placeables = RLMessageService._resolvePlaceables(farmId)
    if placeables == nil then
        return {}
    end

    local rows = {}
    local husbandryIndex = 0

    for _, placeable in pairs(placeables) do
        husbandryIndex = husbandryIndex + 1
        if placeable.getRLMessages ~= nil then
            local messages = placeable:getRLMessages() or {}
            for i = 1, #messages do
                table.insert(rows, RLMessageService.formatMessage(
                    messages[i], placeable, husbandryIndex, i))
            end
        end
    end

    table.sort(rows, RLMessageService.compareRows)

    Log:debug("RLMessageService.getMessagesForFarm: %d rows from %d husbandries",
        #rows, husbandryIndex)
    return rows
end

-- =============================================================================
-- Unread-flag clear
-- =============================================================================

--- Clear the unread flag on every flagged placeable in the array. A pure helper: no farm
--- resolution and no per-placeable logging, since the caller logs the aggregate. Skips an
--- entry lacking the flag accessors, matching the read path's own guard.
--- @param placeables table|nil Array of placeables; nil-safe
--- @return number count Number of placeables whose flag was cleared this call
--- @return table names Display names (placeable:getName()) of the cleared placeables, in iteration order
function RLMessageService._clearUnreadFlagsForPlaceables(placeables)
    if placeables == nil then
        return 0, {}
    end

    local count = 0
    local names = {}

    for _, placeable in pairs(placeables) do
        if placeable.getHasUnreadRLMessages ~= nil
            and placeable.setHasUnreadRLMessages ~= nil
            and placeable:getHasUnreadRLMessages() then
            placeable:setHasUnreadRLMessages(false)
            count = count + 1
            local name = (placeable.getName ~= nil and placeable:getName()) or "Unknown"
            table.insert(names, name)
        end
    end

    return count, names
end

--- Treat every husbandry on the farm as acknowledged, for a Messages tab open.
--- PERMISSIONLESS by design: the flag is informational acknowledgement, not destructive
--- content removal, so deletion is permissioned and this is not. Clears the LOCAL
--- placeable replicas only - server-authoritative unread sync is out of scope.
--- @param farmId number|nil Farm id (typically g_currentMission:getFarmId())
function RLMessageService.markAllReadForFarm(farmId)
    Log:debug("RLMessageService.markAllReadForFarm: farmId=%s", tostring(farmId))

    local placeables = RLMessageService._resolvePlaceables(farmId)
    if placeables == nil then
        return
    end

    local count, names = RLMessageService._clearUnreadFlagsForPlaceables(placeables)
    Log:debug("RLMessageService.markAllReadForFarm: farmId=%s cleared=%d names=[%s]",
        tostring(farmId), count, table.concat(names, ", "))
end

-- =============================================================================
-- Mutation path (delete)
-- =============================================================================

--- Dispatch hook for unit tests. Production code sends through HusbandryMessageDeleteEvent.
--- Tests can swap this field (RLMessageService._sendDeleteEvent = stub) to assert
--- deleteMessages calls it with the expected payload WITHOUT requiring a real network.
--- @type function
RLMessageService._sendDeleteEvent = function(husbandry, uniqueIds)
    HusbandryMessageDeleteEvent.sendEvent(husbandry, uniqueIds)
end

--- Delete one or more messages from a husbandry. Caller-mutates-first: local state changes
--- immediately on every originator, then the event dispatches and remote receivers apply
--- the same mutation in run(). Idempotent - an unknown uniqueId is silently skipped.
--- @param husbandry table Target husbandry placeable (must have spec_husbandryAnimals)
--- @param uniqueIds table Array of uniqueIds to delete (non-empty)
function RLMessageService.deleteMessages(husbandry, uniqueIds)
    if husbandry == nil or husbandry.spec_husbandryAnimals == nil then
        Log:warning("RLMessageService.deleteMessages: invalid husbandry, aborting")
        return
    end
    if uniqueIds == nil or #uniqueIds == 0 then
        Log:warning("RLMessageService.deleteMessages: empty uniqueIds, aborting")
        return
    end

    Log:debug("RLMessageService.deleteMessages: husbandry='%s' count=%d",
        tostring(husbandry:getName()), #uniqueIds)

    -- 1. Mutate local state first (caller-mutates-first per Pattern A).
    for i = 1, #uniqueIds do
        husbandry:deleteRLMessage(uniqueIds[i])
    end

    -- 2. Dispatch the event via the swappable hook (production path calls
    --    HusbandryMessageDeleteEvent.sendEvent, tests can stub).
    RLMessageService._sendDeleteEvent(husbandry, uniqueIds)
end

--- Group display rows by source husbandry, so a bulk delete fires one event per husbandry.
--- Returns an ORDERED ARRAY rather than a map, so the dispatch order is deterministic.
--- @param rows table Array of display rows with `husbandryRef` + `uniqueId`
--- @return table groups Array of `{ husbandry = <placeable>, uniqueIds = {...} }`
function RLMessageService.groupRowsByHusbandry(rows)
    local groups = {}
    local indexByHusbandry = {}

    if rows == nil then return groups end

    for i = 1, #rows do
        local row = rows[i]
        if row.husbandryRef ~= nil and row.uniqueId ~= nil then
            local groupIdx = indexByHusbandry[row.husbandryRef]
            if groupIdx == nil then
                table.insert(groups, { husbandry = row.husbandryRef, uniqueIds = {} })
                groupIdx = #groups
                indexByHusbandry[row.husbandryRef] = groupIdx
            end
            table.insert(groups[groupIdx].uniqueIds, row.uniqueId)
        end
    end

    Log:trace("RLMessageService.groupRowsByHusbandry: %d row(s) -> %d group(s)", #rows, #groups)
    return groups
end
