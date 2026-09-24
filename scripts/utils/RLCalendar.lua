--[[
    RLCalendar - the one home of the period-to-calendar projection.

    The engine has no month field: period 1 is March, so a month is the period plus two, wrapped.
    The engine year turns at period 1, not in January, so January and February (periods 11 and
    12) belong to the calendar year after currentYear. Pure: plain data in and out, no g_* read,
    no random draw, no setting.
]]

local Log = RmLogging.getLogger("RLRM")

RLCalendar = {}

--- Project the environment's period and engine year onto a calendar month and year.
---@param environment table engine environment; reads currentPeriod and currentYear
---@return number month calendar month, 1..12
---@return number year calendar year in engine-year numbering
function RLCalendar.getMonthAndYear(environment)
    local month = environment.currentPeriod + 2
    if month > 12 then month = month - 12 end

    local year = environment.currentYear
    if month <= 2 then year = year + 1 end

    Log:trace("RLCalendar.getMonthAndYear: period=%s engineYear=%s -> month=%s year=%s",
        tostring(environment.currentPeriod), tostring(environment.currentYear), tostring(month), tostring(year))

    return month, year
end

--- Project the environment's calendar position onto a calendar day, month and year.
---@param environment table engine environment; also reads currentDayInPeriod and daysPerPeriod
---@return number day day of the month
---@return number month calendar month, 1..12
---@return number year calendar year in engine-year numbering
function RLCalendar.getDate(environment)
    local month, year = RLCalendar.getMonthAndYear(environment)
    local currentDayInPeriod = environment.currentDayInPeriod
    local daysPerPeriod = environment.daysPerPeriod
    local day = 1 + math.floor((currentDayInPeriod - 1) * (RLConstants.DAYS_PER_MONTH[month] / daysPerPeriod))

    Log:trace("RLCalendar.getDate: dayInPeriod=%s/%s -> %s/%s/%s",
        tostring(currentDayInPeriod), tostring(daysPerPeriod), tostring(day), tostring(month), tostring(year))

    return day, month, year
end

--- Step a calendar month and year back by a number of months, borrowing years across the wrap.
---@param month number calendar month, 1..12
---@param year number calendar year; may go negative
---@param months number non-negative month count to subtract
---@return number month calendar month, 1..12
---@return number year calendar year
function RLCalendar.subtractMonths(month, year, months)
    local total = year * 12 + (month - 1) - months
    local resultYear = math.floor(total / 12)
    local resultMonth = total % 12 + 1

    Log:trace("RLCalendar.subtractMonths: %s/%s - %s months -> %s/%s",
        tostring(month), tostring(year), tostring(months), tostring(resultMonth), tostring(resultYear))

    return resultMonth, resultYear
end

Log:debug("RLCalendar: loaded")
