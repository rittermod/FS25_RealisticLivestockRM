--[[
    RLMapCountry.lua
    Resolves the country (RLConstants.AREA_CODES index or code) new animals are registered
    in. The per-savegame "mapCountry" setting, when active, overrides the map-resolved area
    code; state 1 leaves the map chain untouched. Headless-loadable: no engine or GUI reads
    at load time, and RLSettings is read nil-safely per call.
]]

RLMapCountry = {}

local Log = RmLogging.getLogger("RLRM")

-- The option value space shared with the RLSettings "mapCountry" entry: state 1 is the
-- "default" sentinel, the rest are area codes in AREA_CODES order. The persistence codec
-- and the resolver both key off this table.
RLMapCountry.VALUES = { "default" }

for _, entry in ipairs(RLConstants.AREA_CODES) do
    RLMapCountry.VALUES[#RLMapCountry.VALUES + 1] = entry.code
end

--- Read the mapCountry setting state nil-safely.
---
--- A pre-initialize window and a pure client before the join snapshot both have no setting
--- state yet, and must resolve to 1 rather than crash.
--- @return number state 1-based index into RLMapCountry.VALUES
local function getSettingState()
    local setting = RLSettings ~= nil and RLSettings.SETTINGS ~= nil and RLSettings.SETTINGS.mapCountry or nil
    return (setting ~= nil and (setting.state or setting.default)) or 1
end

--- Resolve the AREA_CODES index new animals are stamped with.
--- @param mapAreaCode number|nil Map-resolved area code index
--- @return number index Override index when the setting is active; else mapAreaCode, 1 as fallback
function RLMapCountry.resolveIndex(mapAreaCode)
    local state = getSettingState()

    if state > 1 then
        local code = RLMapCountry.VALUES[state]
        local index = code ~= nil and RLConstants.AREA_CODES_BY_CODE[code] or nil

        if index ~= nil then
            Log:trace("RLMapCountry.resolveIndex: override active (state=%d code=%s index=%d)", state, code, index)
            return index
        end
    end

    return mapAreaCode or 1
end

--- Resolve the two-letter RL area code new animals are stamped with.
--- The value space is RL-internal, not ISO ("CH" is China, "SW" Sweden).
--- @param mapAreaCode number|nil Map-resolved area code index
--- @return string code Override code when the setting is active; else the AREA_CODES entry's code, "UK" as fallback
function RLMapCountry.resolveCode(mapAreaCode)
    local state = getSettingState()

    if state > 1 then
        local code = RLMapCountry.VALUES[state]

        if code ~= nil and RLConstants.AREA_CODES_BY_CODE[code] ~= nil then
            Log:trace("RLMapCountry.resolveCode: override active (state=%d code=%s)", state, code)
            return code
        end
    end

    local entry = RLConstants.AREA_CODES[mapAreaCode]

    if entry ~= nil then return entry.code end

    return "UK"
end

Log:info("RLMapCountry loaded")
