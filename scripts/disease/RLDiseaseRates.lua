--[[
    RLDiseaseRates.lua
    The per-month to per-tick probability conversion the disease model needs, plus
    its inverse, so a monthly probability delivers the same cumulative risk
    whatever period length the player runs.

    Pure data-in / data-out - RmLogging at file scope is the only dependency, so
    the module dual-runs headless. `daysPerPeriod` arrives as a PARAMETER, read at
    call time and never cached: the setting is player-changeable mid-game.

    Nothing is validated and the round trip is not bit-exact, so never compare a
    round-tripped value with `==`. Any tolerance claim here is ABSOLUTE.
]]

RLDiseaseRates = {}

local Log = RmLogging.getLogger("RLRM")


--- Convert a per-month probability to the per-tick probability that compounds
--- back to it over one period.
--- @param pMonth number Probability in [0, 1]. TRUSTED INTERNAL input.
--- @param daysPerPeriod number Ticks per period, 1..28. TRUSTED INTERNAL input.
--- @return number pTick Probability in [0, 1] for in-domain input
function RLDiseaseRates.perTick(pMonth, daysPerPeriod)
    return 1 - (1 - pMonth) ^ (1 / daysPerPeriod)
end


--- Compound a per-tick probability back over a whole period. Inverse of perTick.
--- @param pTick number Probability in [0, 1]. TRUSTED INTERNAL input.
--- @param daysPerPeriod number Ticks per period, 1..28. TRUSTED INTERNAL input.
--- @return number pMonth Probability in [0, 1] for in-domain input
function RLDiseaseRates.compound(pTick, daysPerPeriod)
    return 1 - (1 - pTick) ^ daysPerPeriod
end


Log:info("RLDiseaseRates loaded")
