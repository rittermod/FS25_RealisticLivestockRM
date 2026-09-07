--[[
    RLSelectionKey.lua
    GUI-local nil-safe selection-key builder for the RL Tabbed Menu multi-select frames
    (Buy / Move / Sell / Transfer).

    The frames key their selectedAnimals set by a 3-part identity string. The repo-wide
    RLAnimalUtil.toKey concatenates unconditionally, so a nil farmId or uniqueId would produce a
    colliding key or a nil-concat crash. Rather than change that shared primitive's contract,
    this GUI-local builder hardens exactly the selection paths: it returns nil when farmId or
    uniqueId is missing, so the caller skips the write as "no selection", and coerces a nil
    country to "". On the happy path it DELEGATES to RLAnimalUtil.toKey, so the key is
    byte-identical to the keys already in selectedAnimals and read and write paths stay
    compatible.

    Pure logic - no g_*, GUI or XML, its only dependency being the pure RLAnimalUtil.toKey - so
    it dual-runs.
]]

local Log = RmLogging.getLogger("RLRM")

RLSelectionKey = {}

--- Build a nil-safe 3-part selection key from identity fields. A nil country coerces to "",
--- matching the frames' inline fallback, so the happy-path key equals
--- RLAnimalUtil.toKey(farmId, uniqueId, country) exactly.
--- @param farmId string|number|nil Farm ID
--- @param uniqueId string|number|nil Unique ID
--- @param country string|number|nil Birthday country index (nil -> "")
--- @return string|nil key "farmId uniqueId country", or nil when farmId/uniqueId is missing
function RLSelectionKey.build(farmId, uniqueId, country)
    if farmId == nil or uniqueId == nil then
        -- DEBUG, not WARNING: the caller treats a nil key as "no selection" and skips it, so this
        -- is expected control flow, and build runs once per cluster in select-all and render
        -- loops - a warning would flood on the very condition the guard exists for.
        Log:debug("RLSelectionKey.build: missing identity (farmId=%s uniqueId=%s), returning nil (treated as no selection)",
            tostring(farmId), tostring(uniqueId))
        return nil
    end
    return RLAnimalUtil.toKey(farmId, uniqueId, country or "")
end

Log:debug("RLSelectionKey: loaded")
