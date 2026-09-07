--[[
    RLTrailerWorldService.lua
    The WORLD trailer-placement mechanics behind the RLTransferWorldAdapter seam: when a
    trailer is triggered standalone, the Transfer frame's other side is the free rideables
    in the trailer's trigger zone.

    Load and unload dispatch is SEQUENTIAL - one base-game AnimalLoadEvent /
    AnimalUnloadEvent in flight at a time, advancing on each reply and aggregated into one
    completion. That is forced: base-game replies publish a class-keyed message with NO
    correlation id and code 0 means SUCCESS rather than nil, so concurrent dispatch could
    not attribute replies. Every engaged path reaches onComplete EXACTLY ONCE, so the
    frame's movePending lock never strands. convertRideableCluster and errorKey dual-run;
    the source-item builders, the dispatchers and getErrorText are in-game only.
]]

RLTrailerWorldService = {}

local Log = RmLogging.getLogger("RLRM")

-- =============================================================================
-- Error-code -> i18n KEY mapping (mirrors base-game AnimalScreenTrailer)
-- =============================================================================
-- Built at load from the real base-game AnimalLoadEvent.LOAD_* / AnimalUnloadEvent
-- .UNLOAD_* constants (NOT magic numbers), mirroring AnimalScreenTrailer's
-- LOAD_ERROR_CODE_MAPPING / UNLOAD_ERROR_CODE_MAPPING .text fields. The SUCCESS code
-- is DELIBERATELY OMITTED from both tables: a successful reply must yield NO error
-- text (errorKey returns nil), so we never surface base-game's success string as an
-- error. The two tables MUST stay separate - code 4 means LOAD_ERROR_INVALID_CLUSTER
-- on load but UNLOAD_ERROR_DOES_NOT_SUPPORT_UNLOADING on unload. UNLOAD code 5
-- (TRAILER_DOES_NOT_EXIST) is absent from base-game's table too -> nil here (no crash;
-- the dispatcher guards a nil trailer before it can be reported).

RLTrailerWorldService.LOAD_ERROR_KEYS = {
    [AnimalLoadEvent.LOAD_ERROR_NO_PERMISSION]           = "shop_messageNoPermissionToTradeAnimals",
    [AnimalLoadEvent.LOAD_ERROR_RIDEABLE_DOES_NOT_EXIST] = "shop_messageRideableDoesNotExist",
    [AnimalLoadEvent.LOAD_ERROR_TRAILER_DOES_NOT_EXIST]  = "shop_messageTrailerDoesNotExist",
    [AnimalLoadEvent.LOAD_ERROR_INVALID_CLUSTER]         = "shop_messageInvalidCluster",
    [AnimalLoadEvent.LOAD_ERROR_ANIMAL_NOT_SUPPORTED]    = "shop_messageAnimalTypeNotSupportedByTrailer",
    [AnimalLoadEvent.LOAD_ERROR_NOT_ENOUGH_ANIMALS]      = "shop_messageNotEnoughAnimals",
    [AnimalLoadEvent.LOAD_ERROR_NOT_ENOUGH_SPACE]        = "shop_messageNotEnoughSpaceAnimalsTrailer",
}

RLTrailerWorldService.UNLOAD_ERROR_KEYS = {
    [AnimalUnloadEvent.UNLOAD_ERROR_NO_PERMISSION]             = "shop_messageNoPermissionToTradeAnimals",
    [AnimalUnloadEvent.UNLOAD_ERROR_INVALID_CLUSTER]          = "shop_messageInvalidCluster",
    [AnimalUnloadEvent.UNLOAD_ERROR_NOT_ENOUGH_ANIMALS]      = "shop_messageNotEnoughAnimals",
    [AnimalUnloadEvent.UNLOAD_ERROR_DOES_NOT_SUPPORT_UNLOADING] = "shop_messageAnimalDoesNotSupportUnloading",
    [AnimalUnloadEvent.UNLOAD_ERROR_NO_SPACE]                = "shop_messageNotEnoughSpaceAnimalsArea",
    [AnimalUnloadEvent.UNLOAD_ERROR_COULD_NOT_BE_LOADED]     = "shop_messageAnimalCouldNotBeUnloaded",
    [AnimalUnloadEvent.UNLOAD_ERROR_RIDEABLE_LIMIT_REACHED]  = "shop_messageAnimalRideableLimitReached",
}

--- The i18n KEY for a base-game load/unload error code, or nil for SUCCESS / an
--- unmapped code. Direction-aware via isLoad (the load/unload code spaces collide).
--- PURE: a plain table lookup, no g_*, so it dual-runs.
--- @param errorCode number  an AnimalLoadEvent.LOAD_* / AnimalUnloadEvent.UNLOAD_* code
--- @param isLoad boolean    true for the load table, false for the unload table
--- @return string|nil i18nKey  the error string key, or nil on SUCCESS / unmapped
function RLTrailerWorldService.errorKey(errorCode, isLoad)
    local tbl = isLoad and RLTrailerWorldService.LOAD_ERROR_KEYS or RLTrailerWorldService.UNLOAD_ERROR_KEYS
    return tbl[errorCode]
end

--- The localized error TEXT for a base-game load/unload error code, or nil on
--- SUCCESS / an unmapped code (so a successful reply shows no dialog). IN-GAME leaf:
--- resolves errorKey through g_i18n:getText.
--- @param errorCode number
--- @param isLoad boolean
--- @return string|nil errorText  localized text, or nil on SUCCESS / unmapped
function RLTrailerWorldService.getErrorText(errorCode, isLoad)
    local key = RLTrailerWorldService.errorKey(errorCode, isLoad)
    if key == nil then return nil end
    return g_i18n:getText(key)
end

-- =============================================================================
-- Vanilla-cluster -> RLRM Animal conversion (the dual-run leaf)
-- =============================================================================

--- Resolve a single trigger rideable to the cluster the Transfer list should show,
--- converting a vanilla AnimalCluster into a real RLRM Animal in place. Ported
--- verbatim from legacy RL_AnimalScreenTrailer:initSourceItems so the subsequent
--- AnimalLoadEvent loads the converted identity:
---   * nil cluster -> nil (skip).
---   * numAnimals < 1 (riding-mission props) -> nil (skip).
---   * already-individual (cluster.isIndividual ~= nil) -> the cluster AS-IS
---     (idempotent: a re-enumerate after conversion does not re-convert). The
---     unknown-subtype skip is INSIDE the conversion branch (legacy parity), so an
---     already-Animal whose subtype later became unknown is listed and fails at
---     AnimalLoadEvent.validate (server authority), not pre-skipped here.
---   * vanilla cluster (isIndividual == nil) with an unknown subType -> nil (warn +
---     skip); otherwise convert: resolve farmHerdId (farm.stats.statistics.farmId or
---     ownerFarmId, with the legacy math.random fallback persisted back), rawId
---     (farm.stats:getNextAnimalId(typeIndex) or the math.random fallback), uniqueId
---     via RLAnimalUtil.generateUniqueId, capture canBeSold with an explicit if
---     (Lua and/or fails on a false true-branch), build the Animal, and write it back
---     onto the rideable via setCluster.
---
--- Takes animalSystem + farmManager as parameters (not g_*) so it dual-runs under
--- animal_env against a real Animal + a fixture farm. MUTATES the rideable
--- (setCluster) and may persist a farmHerdId fallback into farm.stats - the
--- documented legacy side effect, idempotent for already-individual clusters.
--- @param rideable table        engine rideable (getCluster / getOwnerFarmId / setCluster)
--- @param animalSystem table    g_currentMission.animalSystem (subtype/type resolution)
--- @param farmManager table     g_farmManager (farmIdToFarm)
--- @return table|nil cluster     the Animal/cluster to list, or nil to skip
function RLTrailerWorldService.convertRideableCluster(rideable, animalSystem, farmManager)
    local cluster = rideable:getCluster()
    if cluster == nil then
        Log:trace("RLTrailerWorldService.convertRideableCluster: nil cluster, skipping")
        return nil
    end

    if cluster.numAnimals ~= nil and cluster.numAnimals < 1 then
        Log:debug("RLTrailerWorldService.convertRideableCluster: skipping numAnimals=%d (non-loadable, e.g. riding-mission horse)",
            cluster.numAnimals)
        return nil
    end

    -- Already an RLRM Animal (or otherwise individual) -> use as-is. The vanilla
    -- conversion (incl. the unknown-subtype skip) is gated behind isIndividual == nil,
    -- so this is idempotent and an already-Animal is never pre-skipped on subtype.
    if cluster.isIndividual ~= nil then
        return cluster
    end

    local subType = animalSystem:getSubTypeByIndex(cluster.subTypeIndex)
    if subType == nil then
        Log:warning("RLTrailerWorldService.convertRideableCluster: skipping rideable with unknown subTypeIndex=%s",
            tostring(cluster.subTypeIndex))
        return nil
    end

    local ownerFarmId = rideable:getOwnerFarmId()
    local farm = farmManager.farmIdToFarm[ownerFarmId]
    local farmHerdId = farm and farm.stats and farm.stats.statistics.farmId or ownerFarmId
    if farmHerdId == nil then
        farmHerdId = math.random(100000, 999999)
        if farm and farm.stats then farm.stats.statistics.farmId = farmHerdId end
    end
    local animalTypeIndex = animalSystem:getTypeIndexBySubTypeIndex(cluster.subTypeIndex)
    local rawId = farm and farm.stats and farm.stats:getNextAnimalId(animalTypeIndex) or math.random(1, 99999)
    local uniqueId = RLAnimalUtil.generateUniqueId(farmHerdId, rawId)

    -- Capture sell-protection from the vanilla cluster before conversion. Explicit
    -- if, NOT `and/or` - the ternary trick collapses when the true-branch is false.
    local canBeSoldFlag = nil
    if cluster:getCanBeSold() == false then canBeSoldFlag = false end

    local animal = Animal.new({
        age = cluster.age,
        health = cluster.health,
        gender = subType.gender,
        subTypeIndex = cluster.subTypeIndex,
        name = cluster:getName(),
        dirt = cluster.dirt,
        fitness = cluster.fitness,
        riding = cluster.riding,
        farmId = tostring(farmHerdId),
        uniqueId = uniqueId,
        canBeSold = canBeSoldFlag,
    })

    Log:debug("RLTrailerWorldService.convertRideableCluster: converted vanilla cluster to Animal (subType=%s, uniqueId=%s, name=%s, canBeSold=%s)",
        subType.name, uniqueId, tostring(animal.name), tostring(canBeSoldFlag))

    rideable:setCluster(animal)
    return animal
end

-- =============================================================================
-- Source-item build over the trigger rideables (in-game)
-- =============================================================================

--- Build the world source list: convert each trigger rideable, wrap the survivors
--- in AnimalItemStock (the SAME wrapper the legacy + Move/pen frames use, each
--- exposing .cluster), and return them in a STABLE order grouped by animalTypeIndex
--- (ascending) then getRideablesInTrigger() iteration order within a type. The frame
--- groups items into sections but does NOT sort the counterpart side, so this builder
--- MUST impose the order. Also returns the cluster -> rideable map so dispatch can
--- recover each rideable; the caller stores it on the open context REPLACING any prior
--- map, keeping selection (current-build .cluster refs) and the map in lockstep.
--- Nil trailer / nil-or-empty trigger -> ({}, {}).
--- @param trailer table|nil  the livestock trailer (getRideablesInTrigger)
--- @return table items              array of AnimalItemStock
--- @return table clusterToVehicle   cluster -> rideable for the current build
function RLTrailerWorldService.buildSourceItems(trailer)
    local clusterToVehicle = {}
    if trailer == nil or trailer.getRideablesInTrigger == nil then
        Log:trace("RLTrailerWorldService.buildSourceItems: nil trailer -> {}")
        return {}, clusterToVehicle
    end

    local rideables = trailer:getRideablesInTrigger()
    if rideables == nil then
        Log:trace("RLTrailerWorldService.buildSourceItems: nil rideable list -> {}")
        return {}, clusterToVehicle
    end

    local animalSystem = g_currentMission.animalSystem
    local byType = {}        -- animalTypeIndex -> { clusters in trigger order }
    local typeOrder = {}     -- type indices, first-encounter order (sorted below)

    for _, rideable in ipairs(rideables) do
        local cluster = RLTrailerWorldService.convertRideableCluster(rideable, animalSystem, g_farmManager)
        if cluster ~= nil then
            -- Bucket by animal type (ascending, for a stable flat order). A vanilla
            -- cluster with an unknown subtype was already skipped during conversion; an
            -- already-individual cluster whose subtype later became unknown (a
            -- near-impossible state - a subtype removed mid-save for a rideable Animal)
            -- crashes here at getTypeIndexBySubTypeIndex, exactly as legacy
            -- RL_AnimalScreenTrailer:initSourceItems does - inherited parity, not a new
            -- failure mode. getTypeIndexBySubTypeIndex never returns nil (it derefs the
            -- subType), so no sentinel guard is reachable.
            local animalTypeIndex = animalSystem:getTypeIndexBySubTypeIndex(cluster.subTypeIndex)
            if byType[animalTypeIndex] == nil then
                byType[animalTypeIndex] = {}
                typeOrder[#typeOrder + 1] = animalTypeIndex
            end
            table.insert(byType[animalTypeIndex], cluster)
            clusterToVehicle[cluster] = rideable
        end
    end

    table.sort(typeOrder)
    local items = {}
    for _, animalTypeIndex in ipairs(typeOrder) do
        for _, cluster in ipairs(byType[animalTypeIndex]) do
            items[#items + 1] = AnimalItemStock.new(cluster)
        end
    end

    Log:debug("RLTrailerWorldService.buildSourceItems: %d item(s) across %d type(s)", #items, #typeOrder)
    return items, clusterToVehicle
end

--- The number of world rideables the list WOULD emit. Derived from the same builder
--- the list uses (buildSourceItems) rather than a parallel predicate, so the sidebar
--- count can never diverge from the listed item count. Nil trailer -> 0.
--- @param trailer table|nil
--- @return number count
function RLTrailerWorldService.countSourceItems(trailer)
    local items = RLTrailerWorldService.buildSourceItems(trailer)
    return #items
end

-- =============================================================================
-- Sequential single-item dispatch (in-game)
-- =============================================================================

--- Process `items` one at a time through `EventClass`, advancing on each reply, and
--- call onComplete(success, errorText) EXACTLY ONCE after the last. validateItem
--- pre-checks the current item (an error there is recorded as the first error and the
--- item is skipped WITHOUT sending); makeEvent builds the single-item event to send.
--- The reply code (0 = SUCCESS for both events, NOT nil) is checked against
--- successCode; the first error (pre-validation or reply) wins. Trailer validity is
--- guarded before each deref so a trailer deleted mid-sequence (MP) aborts the
--- remaining sends and completes with the captured state. Mirrors base-game's
--- per-item subscribe -> send -> reply -> unsubscribe; the multi-item aggregation is
--- the RLMenu enhancement.
--- @param trailer table
--- @param items table          rideables (load) or clusterIds (unload)
--- @param onComplete function|nil  fired once with (success, errorText)
--- @param isLoad boolean       true=load (AnimalLoadEvent), false=unload (AnimalUnloadEvent)
--- @param EventClass table     AnimalLoadEvent | AnimalUnloadEvent (the messageCenter key)
--- @param successCode number   LOAD_SUCCESS | UNLOAD_SUCCESS
--- @param validateItem function (trailer, item) -> errorCode|nil
--- @param makeEvent function    (trailer, item) -> event
local function runSequential(trailer, items, onComplete, isLoad, EventClass, successCode, validateItem, makeEvent)
    local label = isLoad and "load" or "unload"
    local subscriber = {}   -- unique subscription identity (a level below g_messageCenter)
    local idx = 0
    local firstErrorText = nil
    local errored = false

    local function recordError(code)
        if not errored then
            errored = true
            firstErrorText = RLTrailerWorldService.getErrorText(code, isLoad)
        end
    end

    local function finish()
        local success = not errored
        Log:info("RLTrailerWorldService: %s sequence complete (success=%s, items=%d, firstError=%s)",
            label, tostring(success), #items, tostring(firstErrorText))
        if onComplete ~= nil then onComplete(success, firstErrorText) end
    end

    local processNext   -- forward declaration

    local function onReply(_, replyCode)
        g_messageCenter:unsubscribe(EventClass, subscriber)
        Log:debug("RLTrailerWorldService: %s reply code=%s (item %d/%d)", label, tostring(replyCode), idx, #items)
        if replyCode ~= successCode then
            recordError(replyCode)
        end
        processNext()
    end

    processNext = function()
        idx = idx + 1
        if idx > #items then
            finish()
            return
        end

        -- Trailer-validity guard before any deref (a trailer deleted mid-sequence in
        -- MP): abort the remaining sends and complete with the captured state. A deleted
        -- FS25 vehicle is NOT nil'd - the handle persists with isDeleted set - so check
        -- both, else a stale deref (getOwnerFarmId / validate) could fault on the dead node.
        if trailer == nil or trailer.isDeleted then
            Log:warning("RLTrailerWorldService: %s trailer invalid/deleted mid-sequence, aborting at item %d/%d", label, idx, #items)
            finish()
            return
        end

        local item = items[idx]
        local errorCode = validateItem(trailer, item)
        if errorCode ~= nil then
            Log:debug("RLTrailerWorldService: %s item %d/%d pre-validate error code=%s, advancing without send",
                label, idx, #items, tostring(errorCode))
            recordError(errorCode)
            processNext()
            return
        end

        g_messageCenter:subscribe(EventClass, onReply, subscriber)
        Log:debug("RLTrailerWorldService: %s sending item %d/%d", label, idx, #items)
        g_client:getServerConnection():sendEvent(makeEvent(trailer, item))
    end

    processNext()
end

--- Load N trigger rideables into the trailer, one base-game AnimalLoadEvent in flight
--- at a time (each byte-identical to one legacy AnimalScreenTrailer:applySource send),
--- pre-validating with AnimalLoadEvent.validate(trailer, rideable, ownerFarmId). Fires
--- onComplete(success, errorText) exactly once. IN-GAME only (MP wire / g_messageCenter).
--- @param trailer table
--- @param rideables table        the selected rideables
--- @param onComplete function|nil  (success, errorText)
function RLTrailerWorldService.loadRideables(trailer, rideables, onComplete)
    Log:debug("RLTrailerWorldService.loadRideables: %d rideable(s)", rideables ~= nil and #rideables or 0)
    runSequential(trailer, rideables or {}, onComplete, true,
        AnimalLoadEvent, AnimalLoadEvent.LOAD_SUCCESS,
        function(t, rideable) return AnimalLoadEvent.validate(t, rideable, t:getOwnerFarmId()) end,
        function(t, rideable) return AnimalLoadEvent.new(t, rideable) end)
end

--- Unload N trailer clusters back to the trailer's spawn places, one base-game
--- AnimalUnloadEvent in flight at a time (each byte-identical to one legacy
--- AnimalScreenTrailer:applyTarget send), pre-validating with AnimalUnloadEvent.validate
--- (trailer, clusterId). Fires onComplete(success, errorText) exactly once. IN-GAME only.
--- @param trailer table
--- @param clusterIds table       the selected clusters' ids
--- @param onComplete function|nil  (success, errorText)
function RLTrailerWorldService.unloadClusters(trailer, clusterIds, onComplete)
    Log:debug("RLTrailerWorldService.unloadClusters: %d cluster(s)", clusterIds ~= nil and #clusterIds or 0)
    runSequential(trailer, clusterIds or {}, onComplete, false,
        AnimalUnloadEvent, AnimalUnloadEvent.UNLOAD_SUCCESS,
        function(t, clusterId) return AnimalUnloadEvent.validate(t, clusterId) end,
        function(t, clusterId) return AnimalUnloadEvent.new(t, clusterId) end)
end

Log:debug("RLTrailerWorldService: loaded")
