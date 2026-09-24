--[[
    RLPenFeedForecast.lua
    Read-only pen feed forecast: a month-by-month simulation of the current herd's feed
    consumption, estimating how many full game-months a pen's food stock lasts.

    The daily-food formula's single source of truth is Animal._computeDailyFood; this
    module works only on scratch state and never mutates live Animal entities. Scheduled
    births respect free pen slots (excess offspring auto-sell and add no feed demand), and
    newborn metabolism is the deterministic midparent value, so re-rendering the same pen
    yields the same monthsRemaining.

    Returns an integer in [0, MAX_MONTHS], rendered by the UI as a range "~M-(M+1)m" since
    the sim proves M full months survive and busts mid-(M+1); 0 renders "<1m", MAX "~12+m".
]]

RLPenFeedForecast = {}

local Log = RmLogging.getLogger("RLRM")

RLPenFeedForecast.MAX_MONTHS         = 12   -- Projection cap; UI maps this to "~12+m".
RLPenFeedForecast.LACTATION_CUTOFF   = 10   -- Mirrors Animal:onPeriodChanged.
RLPenFeedForecast.WARNING_DAYS       = 2    -- < this many real days of feed -> orange alert (RLDetailPaneHelper).
RLPenFeedForecast.DANGER_DAYS        = 1    -- < this many real days of feed -> red alert.


-- =============================================================================
-- Internals
-- =============================================================================

--- Build per-animal scratch state. All advancing fields are copied off the
--- live entity; live references are kept only for read-only data (subType,
--- impregnatedBy snapshot). Newborns share their mother's subType reference.
--- @param animal table live Animal entity
--- @return table scratch
local function buildScratch(animal)
    local pregCopy = nil
    if animal.pregnancy ~= nil then
        pregCopy = {
            expected    = animal.pregnancy.expected,
            pregnancies = animal.pregnancy.pregnancies,
            duration    = animal.pregnancy.duration,
        }
    end

    local metabolism
    if animal.genetics ~= nil then metabolism = animal.genetics.metabolism end

    local fatherMetabolism = metabolism
    if animal.impregnatedBy ~= nil and animal.impregnatedBy.metabolism ~= nil then
        fatherMetabolism = animal.impregnatedBy.metabolism
    end

    return {
        age                  = animal.age or 0,
        isLactating          = animal.isLactating == true,
        monthsSinceLastBirth = animal.monthsSinceLastBirth or 0,
        isPregnant           = animal.isPregnant == true,
        reproduction         = animal.reproduction,
        pregnancy            = pregCopy,
        metabolism           = metabolism,
        fatherMetabolism     = fatherMetabolism,
        subTypeRef           = animal:getSubType(),
        subTypeName          = animal.subType,
        animalTypeIndex      = animal.animalTypeIndex,
    }
end


--- Sum the food-curve draw across the scratch herd using Animal._computeDailyFood.
--- NOTE: the summed value is a per-PERIOD ration (invariant to daysPerPeriod),
--- despite the "daily" naming - see the getMonthsRemaining/getDaysRemaining unit
--- notes. Callers must NOT scale it by daysPerPeriod.
--- @param scratch table list of per-animal scratch tables
--- @param foodScale number|nil global foodScale setting
--- @return number litersPerPeriod food-curve sum (per period, not per real day)
local function sumDailyFood(scratch, foodScale)
    local total = 0
    for i = 1, #scratch do
        local s = scratch[i]
        if s.subTypeRef ~= nil and s.subTypeRef.input ~= nil and s.subTypeRef.input.food ~= nil then
            local baseCurveValue = s.subTypeRef.input.food:get(s.age)
            local numPregnancies = (s.pregnancy ~= nil and s.pregnancy.pregnancies ~= nil)
                and #s.pregnancy.pregnancies or 0
            total = total + Animal._computeDailyFood(
                s.age,
                s.isLactating,
                s.reproduction,
                numPregnancies,
                s.metabolism,
                baseCurveValue,
                foodScale
            )
        end
    end
    return total
end


--- Per-tick state advance: age, months since last birth, the lactation cutoff, and a
--- pregnant animal's reproduction counter. Age collapses to one increment per simulated
--- game-month.
--- @param scratch table
--- @param daysPerPeriod number game-days per game-month (>=1)
local function tickStateAdvance(scratch, daysPerPeriod)
    for i = 1, #scratch do
        local s = scratch[i]
        s.age = s.age + 1
        s.monthsSinceLastBirth = s.monthsSinceLastBirth + 1
        if s.isLactating and s.monthsSinceLastBirth >= RLPenFeedForecast.LACTATION_CUTOFF then
            s.isLactating = false
        end

        -- Advance gestation, clamped at 100. Without it the food formula's gestation
        -- surge factor stays at its snapshot value and late-term mothers undercount draw.
        if s.isPregnant and s.pregnancy ~= nil then
            local duration = s.pregnancy.duration
            if duration == nil and s.subTypeRef ~= nil then
                duration = s.subTypeRef.reproductionDurationMonth
            end
            if duration ~= nil and duration > 0 then
                local perDayDelta = math.floor((100 / duration) / daysPerPeriod)
                s.reproduction = math.min((s.reproduction or 0) + perDayDelta * daysPerPeriod, 100)
            end
        end
    end
end


--- Fire scheduled births in the current simulated month. Clamps newborn count
--- by free pen slots (matches the live-game pen-overflow handling). Returns
--- the count of newborns added (for trace logging).
--- @param scratch table herd scratch list (mutated)
--- @param simMonth number 1..12
--- @param simYear number
--- @param maxNumAnimals number|nil pen capacity; nil => unlimited
--- @return number addedNewborns
local function tickBirths(scratch, simMonth, simYear, maxNumAnimals)
    local addedTotal = 0

    -- Iterate the pre-existing list only; newborns appended in-loop must not
    -- give birth themselves this tick (age=0, isPregnant=false anyway).
    local originalCount = #scratch

    for i = 1, originalCount do
        local s = scratch[i]
        if s.isPregnant and s.pregnancy ~= nil and s.pregnancy.expected ~= nil
            and s.pregnancy.pregnancies ~= nil
            and s.pregnancy.expected.month == simMonth
            and s.pregnancy.expected.year == simYear
        then
            local desired = #s.pregnancy.pregnancies
            local freeSlots
            if maxNumAnimals == nil then
                freeSlots = desired
            else
                freeSlots = math.max(maxNumAnimals - #scratch, 0)
            end
            local actual = math.min(desired, freeSlots)

            for _ = 1, actual do
                local newbornMetabolism = (s.metabolism + s.fatherMetabolism) / 2
                table.insert(scratch, {
                    age                  = 0,
                    isLactating          = false,
                    monthsSinceLastBirth = 0,
                    isPregnant           = false,
                    reproduction         = 0,
                    pregnancy            = nil,
                    metabolism           = newbornMetabolism,
                    fatherMetabolism     = newbornMetabolism,
                    subTypeRef           = s.subTypeRef,
                    subTypeName          = s.subTypeName,
                    animalTypeIndex      = s.animalTypeIndex,
                })
            end

            -- Mother post-birth state per AnimalReproduction (COW or GOAT lactates).
            s.isPregnant           = false
            s.pregnancy            = nil
            s.reproduction         = 0
            s.monthsSinceLastBirth = 0
            if (AnimalType ~= nil and s.animalTypeIndex == AnimalType.COW)
                or s.subTypeName == "GOAT"
            then
                s.isLactating = true
            end

            addedTotal = addedTotal + actual
        end
    end

    return addedTotal
end


-- =============================================================================
-- Public API
-- =============================================================================

--- Estimate how many full game-months the pen's current food covers given
--- the current herd's projected feed draw. Integer return; the UI renders
--- the value as a range "~M-(M+1)m"; MAX_MONTHS maps to "~12+m"; 0 maps to
--- "<1m".
--- @param husbandry table placeable husbandry instance
--- @param foodTotalLiters number current pen food (sum across mixes)
--- @return number monthsRemaining integer in [0, MAX_MONTHS]
function RLPenFeedForecast.getMonthsRemaining(husbandry, foodTotalLiters)
    foodTotalLiters = foodTotalLiters or 0

    if husbandry == nil or husbandry.spec_husbandryAnimals == nil
        or husbandry.spec_husbandryAnimals.getClusters == nil
    then
        Log:warning("RLPenFeedForecast.getMonthsRemaining: cluster system unreachable; returning MAX_MONTHS")
        Log:debug("RLPenFeedForecast.getMonthsRemaining: animals=0 foodTotalLiters=%.1f -> monthsRemaining=%d (no cluster system)",
            foodTotalLiters, RLPenFeedForecast.MAX_MONTHS)
        return RLPenFeedForecast.MAX_MONTHS
    end

    local clusterSystem = husbandry.spec_husbandryAnimals
    local animals = clusterSystem:getClusters() or {}

    -- Empty herd: nothing to drain; clamp to cap.
    if #animals == 0 then
        Log:debug("RLPenFeedForecast.getMonthsRemaining: animals=0 foodTotalLiters=%.1f -> monthsRemaining=%d",
            foodTotalLiters, RLPenFeedForecast.MAX_MONTHS)
        return RLPenFeedForecast.MAX_MONTHS
    end

    -- Environment snapshot used for calendar-keyed birth firing.
    local environment      = (g_currentMission ~= nil) and g_currentMission.environment or nil
    local daysPerPeriod    = (environment ~= nil and environment.daysPerPeriod) or 3
    local foodScale        = (RealisticLivestock_PlaceableHusbandryFood ~= nil)
        and RealisticLivestock_PlaceableHusbandryFood.foodScale or 1
    local maxNumAnimals    = clusterSystem.maxNumAnimals

    -- The start is a calendar date; the loop below advances it a month at a time.
    local simMonth, simYear = 2, 0
    if environment ~= nil then
        simMonth, simYear = RLCalendar.getMonthAndYear(environment)
    end

    Log:trace("RLPenFeedForecast.getMonthsRemaining: projection starts %s/%s", tostring(simMonth), tostring(simYear))

    -- Build scratch state. Live Animal entities are never mutated below.
    local scratch = {}
    for _, animal in pairs(animals) do
        table.insert(scratch, buildScratch(animal))
    end

    local initialCount = #scratch
    local liters       = foodTotalLiters
    local monthsCompleted = 0

    for m = 1, RLPenFeedForecast.MAX_MONTHS do
        -- Fire any births due at the current simulated month BEFORE drain so
        -- newborns join the herd for this month's food consumption. Mirrors
        -- the live game where reproduce() fires on the due day and the
        -- newborns start eating from that day.
        local added = tickBirths(scratch, simMonth, simYear, maxNumAnimals)
        if added > 0 then
            Log:trace("RLPenFeedForecast: m=%d births=%d herdAfter=%d (cal=%d/%d)",
                m, added, #scratch, simMonth, simYear)
        end

        local daily = sumDailyFood(scratch, foodScale)
        -- `daily` is ALREADY a per-PERIOD ration, invariant to daysPerPeriod, so it must
        -- NOT be multiplied by it. See the unit note on getDaysRemaining.
        local drain = daily

        Log:trace("RLPenFeedForecast: m=%d herd=%d daily=%.2f drain=%.2f daysPerPeriod=%d litersBefore=%.1f",
            m, #scratch, daily, drain, daysPerPeriod, liters)

        if liters - drain < 0 then
            Log:debug("RLPenFeedForecast.getMonthsRemaining: animals=%d foodTotalLiters=%.1f -> monthsRemaining=%d (mid-month %d bust)",
                initialCount, foodTotalLiters, monthsCompleted, m)
            return monthsCompleted
        end

        liters = liters - drain
        monthsCompleted = m

        tickStateAdvance(scratch, daysPerPeriod)

        -- Advance calendar for next iteration's tickBirths.
        simMonth = simMonth + 1
        if simMonth > 12 then
            simMonth = simMonth - 12
            simYear  = simYear + 1
        end
    end

    Log:debug("RLPenFeedForecast.getMonthsRemaining: animals=%d foodTotalLiters=%.1f -> monthsRemaining=%d (cap)",
        initialCount, foodTotalLiters, RLPenFeedForecast.MAX_MONTHS)
    return RLPenFeedForecast.MAX_MONTHS
end


--- How many real game-DAYS the pen's food covers at the herd's current draw - the basis
--- for the low-feed alert, in days the player experiences rather than periods, since a
--- period-count threshold fires far too early at high days-per-period.
---
--- UNIT NOTE: the summed food-curve value is consumed PER PERIOD, not per real day, so
--- the real per-day draw is that value over daysPerPeriod and the runway is
--- foodTotalLiters * daysPerPeriod / dailyFood. Uses the CURRENT herd only: over a
--- one-to-two-day horizon its composition does not change.
--- @param husbandry table placeable husbandry instance
--- @param foodTotalLiters number current pen food (sum across mixes)
--- @return number daysRemaining >= 0; math.huge when there is no draw (empty
---         herd or zero daily consumption) so callers treat the pen as "plenty"
function RLPenFeedForecast.getDaysRemaining(husbandry, foodTotalLiters)
    foodTotalLiters = foodTotalLiters or 0

    if husbandry == nil or husbandry.spec_husbandryAnimals == nil
        or husbandry.spec_husbandryAnimals.getClusters == nil
    then
        Log:warning("RLPenFeedForecast.getDaysRemaining: cluster system unreachable; returning math.huge")
        return math.huge
    end

    local clusterSystem = husbandry.spec_husbandryAnimals
    local animals = clusterSystem:getClusters() or {}

    -- Empty herd: nothing drains; treat as unlimited runway.
    if #animals == 0 then
        Log:debug("RLPenFeedForecast.getDaysRemaining: animals=0 foodTotalLiters=%.1f -> daysRemaining=inf",
            foodTotalLiters)
        return math.huge
    end

    local foodScale = (RealisticLivestock_PlaceableHusbandryFood ~= nil)
        and RealisticLivestock_PlaceableHusbandryFood.foodScale or 1

    -- Build scratch state (read-only copy) and sum the herd's current daily draw.
    local scratch = {}
    for _, animal in pairs(animals) do
        table.insert(scratch, buildScratch(animal))
    end

    local dailyFood = sumDailyFood(scratch, foodScale)

    -- No draw (e.g. foodScale 0, or all animals off the food curve) => unlimited.
    if dailyFood <= 0 then
        Log:debug("RLPenFeedForecast.getDaysRemaining: animals=%d dailyFood=0 -> daysRemaining=inf (no draw)",
            #scratch)
        return math.huge
    end

    -- dailyFood (food-curve value) is consumed PER PERIOD, not per real day, so
    -- the real per-day draw is dailyFood / daysPerPeriod and the real-days runway
    -- scales with daysPerPeriod. Mirror getMonthsRemaining's environment read.
    local environment   = (g_currentMission ~= nil) and g_currentMission.environment or nil
    local daysPerPeriod = (environment ~= nil and environment.daysPerPeriod) or 3

    local daysRemaining = foodTotalLiters / dailyFood * daysPerPeriod
    Log:debug("RLPenFeedForecast.getDaysRemaining: animals=%d foodTotalLiters=%.1f dailyFood=%.2f daysPerPeriod=%d -> daysRemaining=%.2f",
        #scratch, foodTotalLiters, dailyFood, daysPerPeriod, daysRemaining)
    return daysRemaining
end
