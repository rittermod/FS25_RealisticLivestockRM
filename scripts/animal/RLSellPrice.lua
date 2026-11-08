--[[
    RLSellPrice.lua
    The sale-price formula every animal type shares, as plain data in and numbers out: no `g_*`, no XML, no
    setting. `Animal:getSellPrice` calls `basePrice`, folds the animal's diseases and offers the type's price
    hook the result, then calls `finalPrice` when no hook answers.
]]

RLSellPrice = {}

local Log = RmLogging.getLogger("RLRM")


--- The pre-disease price: the age curve value adjusted for meat quality, weight and castration.
--- @param subType table the animal's subtype (sellPrice curve, minWeight, targetWeight, reproductionMinAgeMonth)
--- @param age number age in months; an age below 0 reads the curve at 0
--- @param weight number current weight
--- @param targetWeight number the animal's own metabolism-scaled target weight
--- @param quality number the meat quality genetic
--- @param isCastrated boolean|nil whether the animal is castrated
--- @return number sellPrice the price before diseases and the final mix
--- @return number weightFactor current weight over the target weight for this age
function RLSellPrice.basePrice(subType, age, weight, targetWeight, quality, isCastrated)
    local curveValue = subType.sellPrice:get(age < 0 and 0 or age)

    local targetWeightForAge = ((targetWeight - subType.minWeight) / (subType.reproductionMinAgeMonth * 1.5)) *
        math.min(age + 1.5, subType.reproductionMinAgeMonth * 1.5) * 0.85
    local weightFactor = 1 + ((weight - targetWeightForAge) / targetWeightForAge)

    local meatTerm = curveValue * 0.25 * (quality - 1)
    local sellPrice = curveValue + meatTerm

    -- The meat-weight term divides by the subtype's raw target weight, while the weight factor above uses the
    -- animal's metabolism-scaled one; merging the two would move every price.
    local weightTerm = ((sellPrice * 0.6) / subType.targetWeight) * weight * (-1 + quality)
    sellPrice = math.max(sellPrice + weightTerm, 0.5)

    if isCastrated then sellPrice = sellPrice + sellPrice * 0.15 end

    Log:trace("RLSellPrice.basePrice: curve=%.4f targetForAge=%.4f weightFactor=%.4f quality=%.4f meatTerm=%.4f "
        .. "weightTerm=%.4f castrated=%d -> %.4f", curveValue, targetWeightForAge, weightFactor, quality, meatTerm,
        weightTerm, isCastrated and 1 or 0, sellPrice)

    return sellPrice, weightFactor
end


--- The final price from the post-disease price: the weight and health mix, the lactation and pregnancy bonuses.
--- @param sellPrice number the price after basePrice and the disease fold
--- @param weightFactor number the weight factor basePrice returned
--- @param healthFactor number health over 100
--- @param isLactating boolean|nil whether the animal is lactating
--- @param isPregnant boolean|nil whether the animal is pregnant
--- @return number price the sale price, never below 5% of sellPrice
function RLSellPrice.finalPrice(sellPrice, weightFactor, healthFactor, isLactating, isPregnant)
    local fixedShare = sellPrice * 0.6
    local weightShare = sellPrice * 0.4 * weightFactor * (0.75 * healthFactor)
    local lactationBonus = sellPrice * (isLactating and 0.15 or 0)
    local pregnancyBonus = sellPrice * (isPregnant and 0.25 or 0)
    local price = math.max(fixedShare + weightShare + lactationBonus + pregnancyBonus, sellPrice * 0.05)

    Log:trace("RLSellPrice.finalPrice: base=%.4f fixed=%.4f weightShare=%.4f health=%.4f lactation=%.4f "
        .. "pregnancy=%.4f -> %.4f", sellPrice, fixedShare, weightShare, healthFactor, lactationBonus,
        pregnancyBonus, price)

    return price
end
