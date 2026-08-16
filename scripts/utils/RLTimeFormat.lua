local Log = RmLogging.getLogger("RLRM")

RLTimeFormat = {}

--- Render a month count as a player-facing duration string.
---
--- Domain: a NON-NEGATIVE INTEGER number of months. There is deliberately no runtime
--- validation - every caller passes one of this mod's own integer month fields (an
--- animal's age, a treatment duration, a disease's remaining immunity), and an
--- out-of-domain value is a wiring bug that should stay loud rather than be absorbed
--- here. Note what an absorbing guard would hide: a negative count renders a plausible
--- wrong answer (-1 becomes "11 months") instead of failing.
---
--- The month term is emitted unconditionally once the year term is non-zero, so a
--- whole number of years reads "1 year, 0 months" rather than "1 year".
---@param age number month count; non-negative integer
---@return string localised "N years, M months", or "M months" below one year
function RLTimeFormat.formatAge(age)
    local years = math.floor(age / 12)
    local months = age % 12

    local monthsString = months == 1 and g_i18n:getText("rl_ui_month") or g_i18n:getText("rl_ui_months")

    if years > 0 then
        return string.format("%s %s, %s %s", years,
            years == 1 and g_i18n:getText("rl_ui_year") or g_i18n:getText("rl_ui_years"), months, monthsString)
    end

    return string.format("%s %s", months, monthsString)
end

Log:trace("RLTimeFormat: loaded")
