-- Pure compositor for the filter chip state shown in the four RL Menu tabs
-- (Info / Sell / Move / Buy). Resolves the combined Quick filter + saved
-- filter render branch into a flat result struct so each frame's
-- updateFilterChip wrapper duplicates no branch logic.

RLFilterChipHelper = {}

--- Compose the chip render state from the per-frame Quick filter table
--- and the saved filter currently bound to the frame.
---
--- Branch table:
---   neither active -> { visible = false }
---   quick only     -> { visible = true, textKey = "rl_menu_filter_chip_quick" }
---   saved only     -> { visible = true, textKey = "rl_menu_filter_chip_active",
---                       savedName = <name or unnamed fallback> }
---   both active    -> { visible = true, textKey = "rl_menu_filter_chip_quick_plus_saved",
---                       savedName = <name or unnamed fallback> }
---
--- An empty-string saved name resolves to the unnamed fallback, not just a nil one, so it can
--- no longer render as "Filter: " with a trailing space.
---
--- No logging inside; callers log the chosen branch at their own prefix.
---
---@param filters table|nil per-frame Quick filter table (self.filters)
---@param activeFilter table|nil saved filter record (self.activeFilter)
---@return table state { visible:boolean, textKey:string|nil, savedName:string|nil }
function RLFilterChipHelper.composeChipState(filters, activeFilter)
    local quickActive = filters ~= nil and next(filters) ~= nil
    local savedActive = activeFilter ~= nil

    if not quickActive and not savedActive then
        return { visible = false }
    end

    local savedName = nil
    if savedActive then
        savedName = activeFilter.name
        if savedName == nil or savedName == "" then
            savedName = g_i18n:getText("rl_menu_filter_chip_unnamed")
        end
    end

    if quickActive and not savedActive then
        return { visible = true, textKey = "rl_menu_filter_chip_quick" }
    elseif not quickActive and savedActive then
        return { visible = true, textKey = "rl_menu_filter_chip_active", savedName = savedName }
    else
        return { visible = true, textKey = "rl_menu_filter_chip_quick_plus_saved", savedName = savedName }
    end
end
