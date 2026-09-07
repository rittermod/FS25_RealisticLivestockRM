-- RLScaleHelper.lua
-- The canonical 0-99 genetics scale.

local Log = RmLogging.getLogger("RLRM")

RLScaleHelper = {}

--- Map a raw genetics value onto 0..99, clamped at both ends. Nil is not accepted.
---@param value number Raw genetics value in [0.25, 1.75]
---@return integer scaled 0..99
function RLScaleHelper.scaleToNinetyNine(value)
    local scaled = math.floor(((value - 0.25) / 1.5) * 99 + 0.5)
    if scaled < 0 then return 0 end
    if scaled > 99 then return 99 end
    return scaled
end

Log:trace("RLScaleHelper: loaded")
