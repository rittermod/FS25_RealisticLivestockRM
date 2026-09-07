local Log = RmLogging.getLogger("RLRM")

RLTimeFormat = {}

--- Render a month count as a player-facing duration string. Unvalidated: the domain is a
--- non-negative integer.
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
