--[[
    RLSelectionKey.lua
    GUI-local nil-safe selection-key builder for the multi-select frames (Buy / Move /
    Sell / Transfer). RLAnimalUtil.toKey concatenates unconditionally, so a nil farmId
    or uniqueId there yields a colliding key or a nil-concat crash; this hardens the
    selection paths and DELEGATES to toKey on the happy path, keeping the key
    byte-identical to those already in selectedAnimals. Pure, so it dual-runs.
]]

local Log = RmLogging.getLogger("RLRM")

RLSelectionKey = {}

--- Build a nil-safe 3-part selection key; a nil country coerces to "" so the happy-path
--- key equals RLAnimalUtil.toKey(farmId, uniqueId, country) exactly.
--- @param farmId string|number|nil Farm ID
--- @param uniqueId string|number|nil Unique ID
--- @param country string|number|nil Birthday country index (nil -> "")
--- @return string|nil key "farmId uniqueId country", or nil when farmId/uniqueId is missing
function RLSelectionKey.build(farmId, uniqueId, country)
    if farmId == nil or uniqueId == nil then
        Log:debug("RLSelectionKey.build: missing identity (farmId=%s uniqueId=%s), returning nil (treated as no selection)",
            tostring(farmId), tostring(uniqueId))
        return nil
    end
    return RLAnimalUtil.toKey(farmId, uniqueId, country or "")
end

Log:debug("RLSelectionKey: loaded")
