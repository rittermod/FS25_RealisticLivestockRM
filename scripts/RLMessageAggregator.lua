--[[
    RLMessageAggregator.lua
    Message aggregation system for consolidating noisy individual messages
    (births, deaths, sales, purchases) into daily summaries per husbandry.

    Part of RIT-165: Message Log Consolidation
    Author: Ritter
]]

RLMessageAggregator = {}

-- Pending messages per husbandry, keyed by placeable reference
RLMessageAggregator.pending = {}

-- Message types that should be aggregated and their categories
RLMessageAggregator.AGGREGATABLE = {
    PREGNANCY_SINGLE = "births",
    PREGNANCY_MULTIPLE = "births",
    PREGNANCY_SOLD = "overcrowding",  -- Separate category for visibility
    DEATH = "deaths",
    SOLD_ANIMALS_SINGLE = "sales",
    SOLD_ANIMALS_MULTIPLE = "sales",
    BOUGHT_ANIMALS_SINGLE = "purchases",
    BOUGHT_ANIMALS_MULTIPLE = "purchases",
    AI_MANAGER_SOLD_SINGLE = "sales",
    AI_MANAGER_SOLD_MULTIPLE = "sales",
    AI_MANAGER_BOUGHT_SINGLE = "purchases",
    AI_MANAGER_BOUGHT_MULTIPLE = "purchases"
}


function RLMessageAggregator.initialize()
    -- Subscribe to day change, defer consolidation to next frame
    -- Timer.createOneshot(0) ensures we run AFTER all day change operations
    g_messageCenter:subscribe(MessageType.DAY_CHANGED, function()
        if g_server ~= nil then
            Timer.createOneshot(0, RLMessageAggregator.consolidateDay)
        end
    end)
end


function RLMessageAggregator.isSummaryMode()
    local setting = RLSettings.SETTINGS.messageSummary
    if setting == nil then
        return false -- Default to individual mode if setting doesn't exist
    end
    return setting.state == 2 -- state 2 = "On" (Summary mode)
end


function RLMessageAggregator.queueMessage(husbandry, id, animal, args, date)
    -- If summary mode disabled, pass through directly
    if not RLMessageAggregator.isSummaryMode() then
        husbandry:addRLMessageDirect(id, animal, args, date)
        return
    end

    local category = RLMessageAggregator.AGGREGATABLE[id]
    if category == nil then
        -- Non-aggregatable message, pass through
        husbandry:addRLMessageDirect(id, animal, args, date)
        return
    end

    -- Use husbandry as key directly (Lua tables can use any value as key)
    local pending = RLMessageAggregator.pending[husbandry]

    -- Initialize pending structure for this husbandry
    if pending == nil then
        pending = {
            husbandry = husbandry,
            births = { count = 0 },
            deaths = { count = 0, reasons = {} },
            sales = { count = 0, totalValue = 0 },
            purchases = { count = 0, totalValue = 0 },
            overcrowding = { count = 0, totalValue = 0 }
        }
        RLMessageAggregator.pending[husbandry] = pending
    end

    -- Aggregate based on category
    if category == "births" then
        local count = 1
        if id == "PREGNANCY_MULTIPLE" and args ~= nil and args[1] ~= nil then
            count = tonumber(args[1]) or 1
        end
        pending.births.count = pending.births.count + count

    elseif category == "deaths" then
        pending.deaths.count = pending.deaths.count + 1
        local reason = (args ~= nil and args[1]) or "rl_ui_unknownCauses"
        pending.deaths.reasons[reason] = (pending.deaths.reasons[reason] or 0) + 1

    elseif category == "sales" then
        local count = 1
        local value = 0

        if id == "SOLD_ANIMALS_MULTIPLE" or id == "AI_MANAGER_SOLD_MULTIPLE" then
            -- These have format: [count, money]
            count = (args ~= nil and tonumber(args[1])) or 1
            if args ~= nil and args[2] ~= nil then
                value = RLMessageAggregator.parseMoneyValue(args[2])
            end
        else
            -- SINGLE messages have format: [money]
            if args ~= nil and args[1] ~= nil then
                value = RLMessageAggregator.parseMoneyValue(args[1])
            end
        end

        pending.sales.count = pending.sales.count + count
        pending.sales.totalValue = pending.sales.totalValue + value

    elseif category == "overcrowding" then
        -- PREGNANCY_SOLD has format: [count, money]
        local count = (args ~= nil and tonumber(args[1])) or 1
        local value = 0
        if args ~= nil and args[2] ~= nil then
            value = RLMessageAggregator.parseMoneyValue(args[2])
        end

        pending.overcrowding.count = pending.overcrowding.count + count
        pending.overcrowding.totalValue = pending.overcrowding.totalValue + value

    elseif category == "purchases" then
        local count = 1
        local value = 0

        if id == "BOUGHT_ANIMALS_MULTIPLE" or id == "AI_MANAGER_BOUGHT_MULTIPLE" then
            count = (args ~= nil and tonumber(args[1])) or 1
            -- Money is in args[2] for MULTIPLE messages
            if args ~= nil and args[2] ~= nil then
                value = RLMessageAggregator.parseMoneyValue(args[2])
            end
        else
            -- Money is in args[1] for SINGLE messages
            if args ~= nil and args[1] ~= nil then
                value = RLMessageAggregator.parseMoneyValue(args[1])
            end
        end

        pending.purchases.count = pending.purchases.count + count
        pending.purchases.totalValue = pending.purchases.totalValue + value
    end
end


function RLMessageAggregator.parseMoneyValue(formattedMoney)
    -- Parse money from formatted string like "$1,500" or "1.500 EUR"
    -- This is a best-effort approach - strips non-digit chars except decimal point
    if formattedMoney == nil then return 0 end

    local str = tostring(formattedMoney)
    -- Remove currency symbols and thousands separators, keep digits and decimal point
    -- Handle both "." and "," as potential decimal separators
    local cleaned = string.gsub(str, "[^%d.,]", "")

    -- If there's both . and ,, assume the last one is the decimal separator
    local dotPos = string.find(cleaned, "%.", nil) or 0
    local commaPos = string.find(cleaned, ",", nil) or 0

    if dotPos > 0 and commaPos > 0 then
        if dotPos > commaPos then
            -- Format: 1,234.56 - dot is decimal
            cleaned = string.gsub(cleaned, ",", "")
        else
            -- Format: 1.234,56 - comma is decimal
            cleaned = string.gsub(cleaned, "%.", "")
            cleaned = string.gsub(cleaned, ",", ".")
        end
    elseif commaPos > 0 then
        -- Only comma present - could be decimal or thousands
        -- Assume decimal if exactly 2 digits after comma
        local afterComma = string.sub(cleaned, commaPos + 1)
        if #afterComma == 2 then
            cleaned = string.gsub(cleaned, ",", ".")
        else
            cleaned = string.gsub(cleaned, ",", "")
        end
    end

    return tonumber(cleaned) or 0
end


function RLMessageAggregator.consolidateDay()
    for _, pending in pairs(RLMessageAggregator.pending) do
        local husbandry = pending.husbandry

        -- Verify husbandry is still valid
        if husbandry ~= nil and husbandry.addRLMessageDirect ~= nil then
            local husbandryName = husbandry:getName() or "Unknown"

            -- Args order matches translation format: "%s [action] at %s [details]"
            -- Format: [count, husbandryName, ...]
            if pending.births.count > 0 then
                husbandry:addRLMessageDirect("DAILY_BIRTHS_SUMMARY", nil,
                    { tostring(pending.births.count), husbandryName })
            end

            if pending.deaths.count > 0 then
                -- Format reasons string: "2 from old age, 1 from disease"
                local reasonParts = {}
                for reason, count in pairs(pending.deaths.reasons) do
                    local reasonText = g_i18n:getText(reason) or reason
                    table.insert(reasonParts, tostring(count) .. " from " .. reasonText)
                end
                local reasonsStr = table.concat(reasonParts, ", ")

                husbandry:addRLMessageDirect("DAILY_DEATHS_SUMMARY", nil,
                    { tostring(pending.deaths.count), husbandryName, reasonsStr })
            end

            if pending.sales.count > 0 then
                local moneyStr = g_i18n:formatMoney(pending.sales.totalValue, 2, true, true)
                husbandry:addRLMessageDirect("DAILY_SALES_SUMMARY", nil,
                    { tostring(pending.sales.count), husbandryName, moneyStr })
            end

            if pending.overcrowding.count > 0 then
                local moneyStr = g_i18n:formatMoney(pending.overcrowding.totalValue, 2, true, true)
                husbandry:addRLMessageDirect("DAILY_OVERCROWDING_SUMMARY", nil,
                    { tostring(pending.overcrowding.count), husbandryName, moneyStr })
            end

            if pending.purchases.count > 0 then
                local moneyStr = g_i18n:formatMoney(pending.purchases.totalValue, 2, true, true)
                husbandry:addRLMessageDirect("DAILY_PURCHASES_SUMMARY", nil,
                    { tostring(pending.purchases.count), husbandryName, moneyStr })
            end
        end
    end

    -- Clear pending for next day
    RLMessageAggregator.pending = {}
end


-- Callback for setting changes (optional - mode affects next messages only)
function RLMessageAggregator.onSettingChanged(name, value)
    -- When switching from Summary to Individual mode, flush any pending messages
    -- as individual messages (they won't be consolidated)
    -- Note: 'name' param unused but required by callback signature
    if value == false and next(RLMessageAggregator.pending) ~= nil then
        -- Just clear pending - we can't reconstruct individual messages
        RLMessageAggregator.pending = {}
    end
end
