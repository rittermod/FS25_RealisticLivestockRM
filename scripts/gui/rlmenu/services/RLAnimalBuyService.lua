--[[
    RLAnimalBuyService.lua
    Stateless service for dealer-buy operations, wrapping AnimalBuyEvent dispatch with the
    same subscription pattern as the sell and move services. Every buy is server-authoritative
    - the server calls removeSaleAnimal, addAnimals and addMoney - so the client MUST NOT
    mutate dealer stock, husbandry contents or farm money directly.

    SIGN CONVENTION, critical: AnimalBuyEvent:run passes the values straight to addMoney,
    which ADDS them, so both the buy price and the transport price MUST be dispatched as
    NEGATIVE numbers; a positive dispatch credits the farm. The MoneyType is a statistics
    label and the server's abs() is display-only. The buy price is the cluster's sell price
    times the active dealer-quality markup, read through the same accessor the dealer list
    uses, so displayed and charged prices cannot drift apart.
]]

local Log = RmLogging.getLogger("RLRM")

RLAnimalBuyService = {}


--- Compute the dealer-marked-up buy price for a single animal.
--- Deliberately TRACE-FREE: the dealer row-render path calls this once per row
--- per refresh, so a per-call log line would fire per row. The once-per-population
--- TRACE digest in RLMenuBuyFrame carries this information instead.
--- @param animal table Animal/cluster object
--- @return number price Dealer buy price (positive): getSellPrice() * the active preset's markup
function RLAnimalBuyService.computeBuyPrice(animal)
    if animal == nil then
        Log:warning("RLAnimalBuyService.computeBuyPrice: nil animal")
        return 0
    end

    -- Buy-side dealer markup, resolved from the active dealer-quality preset
    -- (matches AnimalItemNew, which resolves through the same accessor).
    return (animal:getSellPrice() or 0) * RLDealerQualityResolver.getMarkup()
end


--- Compute aggregate buy totals for an array of animals.
--- Buy adds fee to price (player pays both), opposite of Sell which
--- subtracts fee from price.
--- @param animals table Array of Animal/cluster objects
--- @return number totalPrice Sum of dealer buy prices (positive)
--- @return number totalFee Sum of transportation fees (positive)
--- @return number total Gross cost (totalPrice + totalFee)
--- @return number count Number of animals
function RLAnimalBuyService.computeBulkTotal(animals)
    if animals == nil or #animals == 0 then
        return 0, 0, 0, 0
    end

    -- Resolve the markup ONCE for the whole batch rather than per animal: it is
    -- a single active preset, and the accessor logs on change.
    local markup = RLDealerQualityResolver.getMarkup()
    local totalPrice = 0
    local totalFee = 0
    for _, animal in ipairs(animals) do
        totalPrice = totalPrice + (animal:getSellPrice() or 0) * markup
        totalFee = totalFee + (animal:getTranportationFee(1) or 0)
    end

    local total = totalPrice + totalFee
    Log:debug("RLAnimalBuyService.computeBulkTotal: %d animals, price=%.0f fee=%.0f total=%.0f",
        #animals, totalPrice, totalFee, total)
    return totalPrice, totalFee, total, #animals
end


--- Build the single-animal confirmation text using existing rl_ui_buyConfirmation.
--- Format: "Are you sure you want to buy %s animals for %s?" (count, total-money).
--- @param _animal table Animal/cluster object (unused today; reserved for future naming)
--- @param price number Dealer buy price (positive)
--- @param fee number Transportation fee (positive)
--- @return string Formatted confirmation text
function RLAnimalBuyService.buildSingleConfirmationText(_animal, price, fee)
    local total = (price or 0) + (fee or 0)
    local formatted = g_i18n:formatMoney(total, 0, true, true)
    return string.format(g_i18n:getText("rl_ui_buyConfirmation"), 1, formatted)
end


--- Build the bulk buy confirmation text.
--- @param count number Number of animals
--- @param totalPrice number Sum of buy prices (positive)
--- @param totalFee number Sum of transportation fees (positive)
--- @return string Formatted confirmation text
function RLAnimalBuyService.buildBulkConfirmationText(count, totalPrice, totalFee)
    local total = (totalPrice or 0) + (totalFee or 0)
    local formatted = g_i18n:formatMoney(total, 0, true, true)
    return string.format(g_i18n:getText("rl_ui_buyConfirmation"), count, formatted)
end


--- Confirmation text for a destination that cannot accept every selected animal. The
--- dialog uses only the counts and the price; `rejected` is iterated for grouped logging.
--- @param validCount number Number of animals that passed validation
--- @param totalCount number Number of animals originally selected
--- @param rejected table Array of { animal, reason } rejection tuples
--- @param totalPrice number Sum of buy prices for the valid subset (positive)
--- @param totalFee number Sum of transportation fees for the valid subset (positive)
--- @return string Formatted confirmation text
function RLAnimalBuyService.buildPartialConfirmationText(validCount, totalCount, rejected, totalPrice, totalFee)
    validCount = validCount or 0
    totalCount = totalCount or 0
    totalPrice = totalPrice or 0
    totalFee = totalFee or 0

    -- Group rejection reasons for TRACE-level diagnostics (future UX enhancement).
    if rejected ~= nil and #rejected > 0 then
        local counts = {}
        for _, entry in ipairs(rejected) do
            local reason = entry and entry.reason or "UNKNOWN"
            counts[reason] = (counts[reason] or 0) + 1
        end
        for reason, c in pairs(counts) do
            Log:trace("RLAnimalBuyService.buildPartialConfirmationText: rejection reason %s x%d",
                tostring(reason), c)
        end
    end

    local total = totalPrice + totalFee
    local formatted = g_i18n:formatMoney(total, 0, true, true)
    return string.format(g_i18n:getText("rl_ui_buyPartialConfirmation"),
        validCount, totalCount, formatted)
end


--- Send the buy event and subscribe to the response, which fires the callback once.
--- CRITICAL SIGN CONVENTION: the server ADDS both values to the farm balance, so both are
--- dispatched NEGATIVE. A positive dispatch credits the farm instead of charging it.
--- @param destination table The destination placeable (entry.placeable from getValidDestinations)
--- @param animals table Array of Animal/cluster objects to buy
--- @param totalPrice number Sum of buy prices (POSITIVE input; negated on dispatch)
--- @param totalFee number Sum of transportation fees (POSITIVE input; negated on dispatch)
--- @param callback function Callback function(target, errorCode)
--- @param target table Callback target (typically the frame)
--- @param deps table|nil Optional RLAnimalEventRequest injection seam (in-game recorder test); nil -> real g_*
--- @return boolean accepted True when the request was armed + dispatched; false when nothing was dispatched
---   (no animals, nil destination, or a same-class request already in flight). Caller keeps selection + releases lock on false.
function RLAnimalBuyService.buyAnimals(destination, animals, totalPrice, totalFee, callback, target, deps)
    if animals == nil or #animals == 0 then
        Log:debug("RLAnimalBuyService.buyAnimals: no animals, skipping")
        return false
    end
    if destination == nil then
        Log:warning("RLAnimalBuyService.buyAnimals: nil destination")
        return false
    end

    Log:debug("RLAnimalBuyService.buyAnimals: %d animals to '%s' (price=%.0f fee=%.0f)",
        #animals,
        tostring(destination.getName and destination:getName()),
        totalPrice or 0, totalFee or 0)

    -- Response handler. On success it mirrors the server's authoritative sale-list
    -- removal locally (see the sale-list-mirror block below); the request helper owns
    -- unsubscribe + cleanup. errorCode may be RLAnimalEventRequest.TIMEOUT_CODE on
    -- watchdog expiry (!= BUY_SUCCESS, so getErrorText maps it to the timeout text).
    local function onBuyResponse(errorCode)
        Log:trace("RLAnimalBuyService.onBuyResponse: errorCode=%s", tostring(errorCode))

        if errorCode == AnimalBuyEvent.BUY_SUCCESS then
            Log:info("RLAnimalBuyService.onBuyResponse: buy succeeded (%d animals)", #animals)

            -- MP client-side mirror of the server's authoritative removal: the client's
            -- own animal list is never auto-synced, so without this the buying client
            -- sees the just-bought animals reappear on the next list reload.
            if g_currentMission ~= nil
                and g_currentMission.animalSystem ~= nil
                and g_currentMission.animalSystem.removeSaleAnimal ~= nil then
                for _, animal in ipairs(animals) do
                    if animal.animalTypeIndex ~= nil
                        and animal.birthday ~= nil
                        and animal.birthday.country ~= nil then
                        g_currentMission.animalSystem:removeSaleAnimal(
                            animal.animalTypeIndex,
                            animal.birthday.country,
                            animal.farmId,
                            animal.uniqueId)
                        Log:trace("RLAnimalBuyService.onBuyResponse: local removeSaleAnimal typeIdx=%s farmId=%s uniqueId=%s",
                            tostring(animal.animalTypeIndex),
                            tostring(animal.farmId),
                            tostring(animal.uniqueId))
                    end
                end
            end
        else
            Log:debug("RLAnimalBuyService.onBuyResponse: buy failed, errorCode=%s", tostring(errorCode))
        end

        if callback ~= nil then
            if target ~= nil then
                callback(target, errorCode)
            else
                callback(errorCode)
            end
        end
    end

    -- Pre-negate both price and fee. See file header for full rationale.
    local negPrice = -(totalPrice or 0)
    local negFee = -(totalFee or 0)
    Log:trace("RLAnimalBuyService.buyAnimals: dispatching AnimalBuyEvent price=%.0f fee=%.0f",
        negPrice, negFee)

    -- Route the subscribe + dispatch through the shared request helper: one in-flight
    -- request per event CLASS, a cancellable watchdog, and a single-consume completion.
    local accepted = RLAnimalEventRequest.dispatch(
        AnimalBuyEvent,
        AnimalBuyEvent.new(destination, animals, negPrice, negFee),
        onBuyResponse, nil, deps)
    if not accepted then
        Log:debug("RLAnimalBuyService.buyAnimals: dispatch rejected (same-class request in flight)")
    end
    return accepted
end


--- Filter a dealer-buy batch to the survivors a trailer can accept: the per-animal
--- validate, plus a RUNNING-COUNT capacity ledger that caps survivors at the free slots
--- before dispatch. The filter is ADVISORY - the server re-validates the whole batch, so
--- this does not predict its verdict. A single survivor counter against the per-type free
--- read is correct here, because the capacity read is per-type: a per-subtype counter
--- would over-fill a shared place. Returns the same { valid, rejected } shape the shared
--- partial-confirm path expects, plus firstErrorCode for the all-rejected surface.
--- @param destination table Buy destination (the held trailer); capacity read via getNumOfFreeAnimalSlots
--- @param animals table|nil Array of Animal/cluster refs to buy (nil -> empty result)
--- @param ownerFarmId number Owning farm id passed to the validator (trailer:getOwnerFarmId())
--- @param validate function (object, subTypeIndex, age, numAnimals, buyPrice, feePrice, farmId) -> errorCode|nil (AnimalBuyEvent.validate in production)
--- @return table result { valid = {<animal>...}, rejected = {{animal, reason}...}, firstErrorCode = <code|nil> }
function RLAnimalBuyService.filterBuyableAnimals(destination, animals, ownerFarmId, validate)
    local result = { valid = {}, rejected = {}, firstErrorCode = nil }

    -- NET-NEW nil guard (the mirrored filters do not guard nil): a caller whose
    -- trailer context resolved no animals gets the empty result, never a crash.
    if animals == nil then
        Log:debug("RLAnimalBuyService.filterBuyableAnimals: nil animals -> empty result")
        return result
    end

    for _, animal in ipairs(animals) do
        local label = animal.name or animal.uniqueId or "?"

        if animal.subTypeIndex == nil then
            Log:warning("RLAnimalBuyService.filterBuyableAnimals: animal '%s' has nil subTypeIndex, skipping",
                tostring(label))
        else
            -- Negated price + numAnimals = 1, exactly as legacy applySource/applySourceBulk.
            local price = -RLAnimalBuyService.computeBuyPrice(animal)
            local errorCode = validate(destination, animal.subTypeIndex, animal.age, 1, price, 0, ownerFarmId)

            if errorCode ~= nil then
                if result.firstErrorCode == nil then result.firstErrorCode = errorCode end
                result.rejected[#result.rejected + 1] = { animal = animal, reason = errorCode }
                Log:trace("RLAnimalBuyService.filterBuyableAnimals: '%s' rejected by validate (errorCode=%s)",
                    tostring(label), tostring(errorCode))
            else
                local freeSlots = destination:getNumOfFreeAnimalSlots(animal.subTypeIndex)
                if not RLTrailerEndpointService.hasRoom(freeSlots, #result.valid) then
                    result.rejected[#result.rejected + 1] = { animal = animal, reason = "NO_CAPACITY" }
                    Log:trace("RLAnimalBuyService.filterBuyableAnimals: '%s' rejected by capacity (free=%s, queued=%d)",
                        tostring(label), tostring(freeSlots), #result.valid)
                else
                    result.valid[#result.valid + 1] = animal
                    Log:trace("RLAnimalBuyService.filterBuyableAnimals: '%s' passed (queued=%d)",
                        tostring(label), #result.valid)
                end
            end
        end
    end

    Log:debug("RLAnimalBuyService.filterBuyableAnimals: %d valid, %d rejected, firstErrorCode=%s",
        #result.valid, #result.rejected, tostring(result.firstErrorCode))
    return result
end


--- Filter a stock-type list to what the trailer can hold. A LOADED trailer keeps ONLY its
--- current type's entry, UNCONDITIONALLY: that type is structurally aboard already, and
--- re-testing support could fail on a mixed-type trailer and collapse the sidebar to
--- empty. An empty trailer keeps every entry it structurally supports.
--- @param types table|nil Array of type entries (each carries .typeIndex; from RLDealerQuery.listDealerTypes)
--- @param trailer table The held livestock trailer
--- @return table kept Subset of `types` the trailer can hold (the single locked type, or all supported)
function RLAnimalBuyService.filterTrailerSupportedTypes(types, trailer)
    local kept = {}

    if types == nil then
        Log:debug("RLAnimalBuyService.filterTrailerSupportedTypes: nil types -> {}")
        return kept
    end

    local currentType = RLTrailerEndpointService.getCurrentType(trailer)
    if currentType ~= nil then
        -- Locked: keep only the current type's entry, unconditionally.
        for _, entry in ipairs(types) do
            if entry.typeIndex == currentType.typeIndex then
                kept[#kept + 1] = entry
            end
        end
        Log:debug("RLAnimalBuyService.filterTrailerSupportedTypes: locked to typeIndex=%s, %d of %d kept",
            tostring(currentType.typeIndex), #kept, #types)
        return kept
    end

    -- Unlocked: keep each structurally-supported type.
    for _, entry in ipairs(types) do
        if RLTrailerEndpointService.supportsType(trailer, entry.typeIndex) then
            kept[#kept + 1] = entry
        end
    end
    Log:debug("RLAnimalBuyService.filterTrailerSupportedTypes: unlocked, %d of %d supported", #kept, #types)
    return kept
end


--- Map an AnimalBuyEvent error code to a localized error string.
--- Delegates to AnimalScreenDealerFarm.BUY_ERROR_CODE_MAPPING (shape
--- `[code] = { warning = bool, text = i18n_key }`).
--- @param errorCode number The error code from AnimalBuyEvent
--- @return string Localized error text, or a generic fallback for unknown codes
function RLAnimalBuyService.getErrorText(errorCode)
    if errorCode == RLAnimalEventRequest.TIMEOUT_CODE then
        Log:trace("RLAnimalBuyService.getErrorText: synthetic timeout code -> rl_ui_tradeRequestTimeout")
        return g_i18n:getText("rl_ui_tradeRequestTimeout")
    end
    local mapping = AnimalScreenDealerFarm.BUY_ERROR_CODE_MAPPING[errorCode]
    if mapping ~= nil and mapping.text ~= nil then
        Log:trace("RLAnimalBuyService.getErrorText: code=%s -> key='%s'",
            tostring(errorCode), mapping.text)
        return g_i18n:getText(mapping.text)
    end
    Log:warning("RLAnimalBuyService.getErrorText: unknown errorCode=%s, using fallback",
        tostring(errorCode))
    return g_i18n:getText("shop_messageNoPermissionToTradeAnimals")
end
