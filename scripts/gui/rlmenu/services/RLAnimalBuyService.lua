--[[
    RLAnimalBuyService.lua
    Stateless service for dealer-buy operations in the RL Tabbed Menu.

    Wraps AnimalBuyEvent dispatch with the same subscription pattern as
    RLAnimalSellService / RLAnimalMoveService. All buys route through
    AnimalBuyEvent (server-authoritative in AnimalBuyEvent:run): the server
    calls animalSystem:removeSaleAnimal, self.object:addAnimals, and addMoney.
    The client MUST NOT mutate dealer stock, husbandry contents, or farm
    money directly - MUTATION PARITY with legacy AnimalScreenDealer.

    Sign convention (CRITICAL):
    AnimalBuyEvent:run calls
        g_currentMission:addMoney(buyPrice + transportPrice, ...)
    so both values MUST be dispatched as NEGATIVE numbers. addMoney adds
    the value to the balance; the MoneyType is a statistics label and does
    not change the sign. Legacy AnimalScreenDealer negates both values before
    dispatch, and the server abs()-wraps them purely for display - confirming
    it expects stored values to be negative. A positive dispatch credits the
    farm.

    Price markup: dealer buy price = cluster:getSellPrice() *
    RLDealerQualityResolver.getMarkup(), i.e. the markup of the active
    dealer-quality preset (see AnimalItemNew, which resolves through the same
    accessor, so the displayed and charged prices cannot drift apart).

    Error mapping: delegates to AnimalScreenDealerFarm.BUY_ERROR_CODE_MAPPING
    (shape `[code] = { warning = bool, text = i18n_key }`). Do NOT define a
    parallel table - the base-game map already covers every
    AnimalBuyEvent error code and is shared by AnimalScreenDealer,
    AnimalScreenDealerFarm, and AnimalScreenDealerTrailer.

    All methods are static (module-level functions). The service does not
    hold state between calls; the messageCenter subscription for buy
    responses is scoped to each buyAnimals() invocation via closure.
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


--- Build the partial-confirmation text for a destination that cannot accept every
--- selected animal (capacity or EPP age rejection). The dialog text uses
--- validCount + totalCount + total-price only (existing key
--- `rl_ui_buyPartialConfirmation`). The `rejected` array (full {animal, reason}
--- tuples from RLMoveDestinationHelper.buildMoveValidationResult) is accepted for
--- future UX enhancement; today it is iterated for grouped TRACE
--- logging only.
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


--- Send the buy event to the server and subscribe to the response.
--- Mirrors RLAnimalSellService.sellAnimals subscription pattern.
--- The callback fires once with (target, errorCode) when the server responds.
---
--- CRITICAL SIGN CONVENTION: AnimalBuyEvent:run server-side does
---   g_currentMission:addMoney(buyPrice + transportPrice, ...)
--- so BOTH values are dispatched as NEGATIVE numbers (matches legacy
--- AnimalScreenDealer). A positive dispatch credits the farm.
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

            -- MP client-side sale-list mirror. Server did the authoritative
            -- removal (in AnimalBuyEvent:run) before firing this response,
            -- but in MP the client's local g_currentMission.animalSystem.animals
            -- list is never auto-synced - so the buying client would see the
            -- just-bought animals reappear on reloadAnimalList until some
            -- other sync. Legacy mirrors this exact loop in
            -- RL_AnimalScreenDealerFarm:onAnimalBought.
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


--- Filter a dealer-buy batch to the survivors a trailer destination can accept.
--- Contract: reproduces the legacy AnimalScreenDealerTrailer:applySourceBulk pre-filter
--- (per-animal base-game validate, numAnimals = 1, fee 0) AND adds the running-count
--- capacity ledger the legacy controller lacks (the over-queue gap the legacy bulk
--- pre-filter has for the dealer-trailer leg). The client filter is advisory: the injected validate is the
--- authoritative base-game gate and the server AnimalBuyEvent:run re-validates the whole
--- batch, so this caps the survivors at the trailer's free slots before dispatch, it does
--- not predict the server verdict.
---
--- For each animal, in order: skip a nil subTypeIndex (warn; counted in neither result);
--- run validate(destination, subTypeIndex, age, 1, -computeBuyPrice, 0, ownerFarmId) and on a
--- non-nil error record { animal, reason = errorCode } (capturing the FIRST code); then a
--- running-count capacity check that rejects { animal, reason = "NO_CAPACITY" } when the
--- destination's per-(sub)type free slots do NOT strictly exceed the survivors queued so far.
--- A single #valid counter against the per-(sub)type free read is correct for the trailer's
--- per-TYPE capacity (getNumOfFreeAnimalSlots is per-type total-used; a per-subtype
--- counter would over-fill a shared per-type place).
---
--- Returns the { valid, rejected } shape of RLMoveDestinationHelper.buildMoveValidationResult so
--- the frame's shared partial-confirm + dispatch path binds unchanged, PLUS firstErrorCode for
--- the all-rejected error surface (the LEDGER MECHANISM mirrors RLAnimalMoveService.filterMovableAnimals,
--- which returns a tuple - a different shape, deliberately not copied here).
---
--- Pure / dual-run: takes the destination + validate as parameters. computeBuyPrice reads
--- animal:getSellPrice AND, since the dealer-quality preset landed, two module globals
--- (RLDealerQualityResolver -> RLDealerQualityModel) which in turn read RLSettings behind a
--- nil guard; it stays dual-runnable because the resolver degrades to DEFAULT_INDEX when no
--- settings global is present, which is exactly the headless state. The only call onto the
--- destination is getNumOfFreeAnimalSlots, so a headless test drives it with a mock
--- destination and an injected validator.
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


--- Filter a stock-type list to the subset a trailer can hold for the Buy sidebar.
--- Contract: mirrors legacy AnimalScreenDealerTrailer:getSourceAnimalTypes. When the trailer
--- is LOCKED to a current type (non-empty), keep ONLY that type's entry, UNCONDITIONALLY - the
--- current type is structurally aboard, so never re-test supportsType (a degenerate / mixed-type
--- trailer could fail it and collapse the sidebar to empty). When UNLOCKED (empty), keep each
--- entry the trailer structurally supports.
---
--- Pure / dual-run: takes the trailer as a parameter and routes both reads through the nil-safe
--- RLTrailerEndpointService getters (getCurrentType / supportsType), which reach no g_*, so a
--- headless test drives it with a mock trailer.
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
