--[[
    RLAnimalSellService.lua
    Stateless service for animal sell operations, wrapping AnimalSellEvent dispatch with
    the same subscription pattern as RLAnimalMoveService. Single and bulk sells both route
    through AnimalSellEvent, so the MoneyType is always SOLD_ANIMALS.

    Fee sign convention: Animal:getTranportationFee(1) returns a POSITIVE number. This
    service stores fees positive internally and negates when passing them to
    AnimalSellEvent, which expects a negative transportPrice.

    RL messages are added server-side by AnimalSellEvent:run - this service adds none,
    unlike RLAnimalMoveService's client-side move message.
]]

local Log = RmLogging.getLogger("RLRM")

RLAnimalSellService = {}


--- Compute sell price, transportation fee, and net total for a single animal.
--- @param animal table Animal/cluster object
--- @return number price Sell price (positive)
--- @return number fee Transportation fee (positive)
--- @return number total Net proceeds (price - fee)
function RLAnimalSellService.computeSellPrice(animal)
    if animal == nil then
        Log:warning("RLAnimalSellService.computeSellPrice: nil animal")
        return 0, 0, 0
    end

    local price = animal:getSellPrice() or 0
    local fee = animal:getTranportationFee(1) or 0
    local total = price - fee

    Log:trace("RLAnimalSellService.computeSellPrice: price=%.0f fee=%.0f total=%.0f",
        price, fee, total)
    return price, fee, total
end


--- Compute aggregate sell totals for an array of animals.
--- @param animals table Array of Animal/cluster objects
--- @return number totalPrice Sum of sell prices (positive)
--- @return number totalFee Sum of transportation fees (positive)
--- @return number total Net proceeds (totalPrice - totalFee)
--- @return number count Number of animals
function RLAnimalSellService.computeBulkTotal(animals)
    if animals == nil or #animals == 0 then
        return 0, 0, 0, 0
    end

    local totalPrice = 0
    local totalFee = 0
    for _, animal in ipairs(animals) do
        totalPrice = totalPrice + (animal:getSellPrice() or 0)
        totalFee = totalFee + (animal:getTranportationFee(1) or 0)
    end

    local total = totalPrice - totalFee
    Log:debug("RLAnimalSellService.computeBulkTotal: %d animals, price=%.0f fee=%.0f total=%.0f",
        #animals, totalPrice, totalFee, total)
    return totalPrice, totalFee, total, #animals
end


--- Get the animal's breed/type title (e.g., "Holstein", "Landrace").
--- @param animal table Animal/cluster object
--- @return string Type title, or empty string if unavailable
function RLAnimalSellService.getAnimalTypeTitle(animal)
    if animal == nil then return "" end

    local subTypeIndex = animal.subTypeIndex
    if subTypeIndex == nil and animal.getSubTypeIndex ~= nil then
        subTypeIndex = animal:getSubTypeIndex()
    end
    if subTypeIndex == nil then return "" end

    local animalSystem = g_currentMission and g_currentMission.animalSystem
    if animalSystem == nil then return "" end

    local subType = animalSystem:getSubTypeByIndex(subTypeIndex)
    if subType == nil then return "" end

    if g_fillTypeManager ~= nil and g_fillTypeManager.getFillTypeTitleByIndex ~= nil then
        return g_fillTypeManager:getFillTypeTitleByIndex(subType.fillTypeIndex) or ""
    end
    return ""
end


--- Get the animal's custom name (e.g., "Bessie").
--- @param animal table Animal/cluster object
--- @return string Custom name, or empty string if none
function RLAnimalSellService.getAnimalName(animal)
    if animal == nil or animal.getName == nil then return "" end
    return animal:getName() or ""
end


--- Build the single-animal confirmation text using base-game namedFormat pattern.
--- Packs type + name into {animalType} to match AnimalScreenDealerFarm:getApplyTargetConfirmationText.
--- @param animal table Animal/cluster object
--- @param price number Sell price (positive)
--- @param fee number Transportation fee (positive)
--- @return string Formatted confirmation text
function RLAnimalSellService.buildSingleConfirmationText(animal, price, fee)
    local typeTitle = RLAnimalSellService.getAnimalTypeTitle(animal)
    local animalName = RLAnimalSellService.getAnimalName(animal)

    local animalType
    if animalName ~= "" then
        animalType = typeTitle .. ", " .. animalName
    else
        animalType = typeTitle
    end

    local total = price - fee
    local formattedPrice = g_i18n:formatMoney(math.abs(total), 0, true, true)

    local text = g_i18n:getText("shop_doYouWantToSellAnimalsSingular")
    return string.namedFormat(text, "numAnimals", 1, "animalType", animalType, "price", formattedPrice)
end


--- Build the bulk sell confirmation text.
--- @param count number Number of animals
--- @param totalPrice number Sum of sell prices (positive)
--- @param totalFee number Sum of transportation fees (positive)
--- @return string Formatted confirmation text
function RLAnimalSellService.buildBulkConfirmationText(count, totalPrice, totalFee)
    local total = totalPrice - totalFee
    local formattedTotal = g_i18n:formatMoney(math.abs(total), 0, true, true)
    return string.format(g_i18n:getText("rl_ui_sellConfirmation"), count, formattedTotal)
end


--- Send the sell event to the server and subscribe to the response.
--- Mirrors RLAnimalMoveService.moveAnimals subscription pattern.
--- The callback fires once with (target, errorCode) when the server responds.
--- @param husbandry table The source husbandry placeable
--- @param animals table Array of Animal/cluster objects to sell
--- @param totalPrice number Sum of sell prices (positive)
--- @param totalFee number Sum of transportation fees (positive)
--- @param callback function Callback function(target, errorCode)
--- @param target table Callback target (typically the frame)
--- @param deps table|nil Optional RLAnimalEventRequest injection seam (in-game recorder test); nil -> real g_*
--- @return boolean accepted True when the request was armed + dispatched; false when nothing was dispatched
---   (no animals, or a same-class request already in flight). The caller keeps its selection + releases its lock on false.
function RLAnimalSellService.sellAnimals(husbandry, animals, totalPrice, totalFee, callback, target, deps)
    if animals == nil or #animals == 0 then
        Log:debug("RLAnimalSellService.sellAnimals: no animals, skipping")
        return false
    end

    Log:debug("RLAnimalSellService.sellAnimals: %d animals from '%s' (price=%.0f fee=%.0f)",
        #animals,
        tostring(husbandry and husbandry.getName and husbandry:getName()),
        totalPrice, totalFee)

    -- Route the subscribe + dispatch through the shared request helper: one in-flight
    -- request per event CLASS, a cancellable watchdog, and a single-consume completion.
    -- The helper owns unsubscribe + cleanup; onSellResponse keeps the caller-callback shape.
    -- errorCode may be RLAnimalEventRequest.TIMEOUT_CODE on watchdog expiry (!= SELL_SUCCESS,
    -- so it surfaces as a failure and getErrorText maps it to the timeout text).
    local function onSellResponse(errorCode)
        Log:trace("RLAnimalSellService.onSellResponse: errorCode=%s", tostring(errorCode))
        if errorCode ~= AnimalSellEvent.SELL_SUCCESS then
            Log:debug("RLAnimalSellService.onSellResponse: sell failed, errorCode=%s", tostring(errorCode))
        else
            Log:info("RLAnimalSellService.onSellResponse: sell succeeded (%d animals)", #animals)
        end

        if callback ~= nil then
            if target ~= nil then
                callback(target, errorCode)
            else
                callback(errorCode)
            end
        end
    end

    -- AnimalSellEvent expects transportPrice as NEGATIVE (fee sign convention).
    local accepted = RLAnimalEventRequest.dispatch(
        AnimalSellEvent,
        AnimalSellEvent.new(husbandry, animals, totalPrice, -totalFee),
        onSellResponse, nil, deps)
    if not accepted then
        Log:debug("RLAnimalSellService.sellAnimals: dispatch rejected (same-class request in flight)")
    end
    return accepted
end


--- Partition a sell batch into the survivors that pass a per-animal verdict and
--- the rejects, for the trailer-at-dealer Sell flow.
--- Contract: the survivor SHAPE of RLAnimalBuyService.filterBuyableAnimals
--- (`{ valid, rejected, firstErrorCode }`), reproducing legacy
--- AnimalScreenDealerTrailer:applyTargetBulk's per-item skip-invalid-sell-the-rest
--- behaviour - but with NO running-count capacity ledger: selling fills no
--- destination, and the server AnimalSellEvent:run gate is per-animal-independent
--- (it blocks on the first non-sellable animal; there is no cumulative dimension
--- to track). This is a per-animal survivor partition only.
---
--- Pure / dual-run: takes the source + the verdict function as parameters and
--- does NO price math, NO g_*, NO capacity counter - it only partitions by the
--- injected per-animal verdict. The in-game caller injects an adapter that gates
--- on `animal:getCanBeSold()` (returning AnimalSellEvent.SELL_ERROR_CANNOT_BE_SOLD),
--- which is exact parity with the authoritative server leg (AnimalSellEvent:run
--- gates per-animal on getCanBeSold + permission only). A headless test injects a
--- mock validate returning plain sentinel codes, so this loads no AnimalSellEvent.
--- @param source table The sell SOURCE object (the held trailer); passed through to validate
--- @param animals table|nil Array of Animal/cluster refs to sell (nil -> empty result)
--- @param validate function (source, animal) -> errorCode|nil per-animal verdict
--- @return table result { valid = {<animal>...}, rejected = {{animal, reason}...}, firstErrorCode = <code|nil> }
function RLAnimalSellService.filterSellableAnimals(source, animals, validate)
    local result = { valid = {}, rejected = {}, firstErrorCode = nil }

    -- Net-new nil guard (mirror the Buy filter): a caller whose trailer context
    -- resolved no animals gets the empty result, never a crash.
    if animals == nil then
        Log:debug("RLAnimalSellService.filterSellableAnimals: nil animals -> empty result")
        return result
    end

    for _, animal in ipairs(animals) do
        local label = (animal ~= nil and (animal.name or animal.uniqueId)) or "?"
        local errorCode = validate(source, animal)

        if errorCode ~= nil then
            if result.firstErrorCode == nil then result.firstErrorCode = errorCode end
            result.rejected[#result.rejected + 1] = { animal = animal, reason = errorCode }
            Log:trace("RLAnimalSellService.filterSellableAnimals: '%s' rejected by validate (errorCode=%s)",
                tostring(label), tostring(errorCode))
        else
            result.valid[#result.valid + 1] = animal
            Log:trace("RLAnimalSellService.filterSellableAnimals: '%s' passed (queued=%d)",
                tostring(label), #result.valid)
        end
    end

    Log:debug("RLAnimalSellService.filterSellableAnimals: %d valid, %d rejected, firstErrorCode=%s",
        #result.valid, #result.rejected, tostring(result.firstErrorCode))
    return result
end


--- Map an AnimalSellEvent error code to a localized error string.
--- @param errorCode number The error code from AnimalSellEvent
--- @return string Localized error text, or a generic fallback for unknown codes
function RLAnimalSellService.getErrorText(errorCode)
    if errorCode == RLAnimalEventRequest.TIMEOUT_CODE then
        Log:trace("RLAnimalSellService.getErrorText: synthetic timeout code -> rl_ui_tradeRequestTimeout")
        return g_i18n:getText("rl_ui_tradeRequestTimeout")
    end
    local mapping = AnimalScreenDealerFarm.SELL_ERROR_CODE_MAPPING[errorCode]
    if mapping ~= nil and mapping.text ~= nil then
        Log:trace("RLAnimalSellService.getErrorText: code=%d -> key='%s'", errorCode, mapping.text)
        return g_i18n:getText(mapping.text)
    end
    Log:warning("RLAnimalSellService.getErrorText: unknown errorCode=%s, using fallback", tostring(errorCode))
    return g_i18n:getText("shop_messageCannotSellAnimal")
end
