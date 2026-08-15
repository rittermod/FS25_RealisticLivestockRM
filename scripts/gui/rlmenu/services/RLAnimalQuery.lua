--[[
    RLAnimalQuery.lua
    Read-only query service for the RL Tabbed Menu Info tab:
      * list husbandries on a farm
      * list animals inside a husbandry, sorted + filtered
      * format one display row per animal
      * group sorted items into SmoothList sections
]]

RLAnimalQuery = {}

local Log = RmLogging.getLogger("RLRM")

-- =============================================================================
-- Husbandry list
-- =============================================================================

--- Return placeable husbandries owned by the given farm. Empty if farmId is nil or 0.
--- @param farmId number|nil
--- @return table husbandries
function RLAnimalQuery.listHusbandriesForFarm(farmId)
    if farmId == nil or farmId == 0 then return {} end

    if g_currentMission == nil or g_currentMission.husbandrySystem == nil then
        Log:warning("RLAnimalQuery.listHusbandriesForFarm: husbandrySystem unavailable")
        return {}
    end

    local placeables = g_currentMission.husbandrySystem:getPlaceablesByFarm(farmId)
    if placeables == nil then return {} end

    local result = {}
    for _, placeable in ipairs(placeables) do
        table.insert(result, placeable)
    end

    table.sort(result, function(a, b)
        local nameA = (a.getName ~= nil and a:getName()) or ""
        local nameB = (b.getName ~= nil and b:getName()) or ""
        return nameA < nameB
    end)

    Log:debug("RLAnimalQuery.listHusbandriesForFarm: farmId=%s -> %d husbandries (sorted by name)",
        tostring(farmId), #result)
    return result
end

-- =============================================================================
-- Husbandry label
-- =============================================================================

--- Return the husbandry's display name, falling back to "Husbandry N" when empty.
--- @param husbandry table
--- @param fallbackIndex number
--- @return string
function RLAnimalQuery.formatHusbandryLabel(husbandry, fallbackIndex)
    if husbandry == nil then return "" end
    local name
    if husbandry.getName ~= nil then name = husbandry:getName() end
    if name == nil or name == "" then
        name = string.format("Husbandry %d", fallbackIndex or 0)
    end
    return name
end

--- Project the farm's live husbandries into plain `{ uniqueId, animalType, name }` descriptors for
--- the F6 husbandry picker + the pure target gate (RLHerdsmanRulePresenter). Reuses
--- listHusbandriesForFarm (one enumeration source, already name-sorted) so the picker cannot drift
--- from the Info tab (M12). The `uniqueId` field holds the STABLE TARGET KEY from
--- RLHusbandryTargetKey.keyFor (the placeable's uniqueId on server/host, its net-object-id on a pure
--- client) - the field name is kept because the picker / presenter / wire treat it as one opaque
--- unique string, and keying it the SAME way the decoded targets are keyed is what makes the
--- picker's pre-check match. `animalType` is getAnimalTypeIndex() (nil for a not-fully-loaded /
--- non-animal placeable - the pure gate excludes nil-type from typed lists); `name` uses the
--- formatHusbandryLabel "Husbandry N" fallback so the picker + sort never see an empty label. A
--- husbandry with no usable key (keyFor returns nil + :warning) is SKIPPED (it could never
--- round-trip as a stored target). Returns a fresh array (empty for nil / farmless).
---@param farmId number|nil
---@return table descriptors array of { uniqueId = string, animalType = number|nil, name = string } (uniqueId = stable target key)
function RLAnimalQuery.listHusbandryDescriptorsForFarm(farmId)
    local placeables = RLAnimalQuery.listHusbandriesForFarm(farmId)
    local descriptors = {}
    local skipped = 0
    for i, placeable in ipairs(placeables) do
        local key = RLHusbandryTargetKey.keyFor(placeable)
        if type(key) ~= "string" or key == "" then
            -- keyFor already :warning'd the unkeyable placeable (nil/empty uniqueId on server,
            -- nil/0 net-object-id on a pure client); just count it for the summary.
            skipped = skipped + 1
        else
            local animalType = placeable.getAnimalTypeIndex ~= nil and placeable:getAnimalTypeIndex() or nil
            if animalType == nil then
                -- A nil-type husbandry (not-fully-loaded / non-animal placeable) is excluded
                -- from typed picker lists by the pure gate and never matches the castrate
                -- exclusion; log it per-case so its disappearance from the picker is traceable.
                Log:debug("RLAnimalQuery.listHusbandryDescriptorsForFarm: husbandry '%s' (key=%s) has nil animalType; excluded from typed lists",
                    RLAnimalQuery.formatHusbandryLabel(placeable, i), tostring(key))
            end
            descriptors[#descriptors + 1] = {
                -- field name kept (picker/presenter domain); value is the stable target key.
                uniqueId   = key,
                animalType = animalType,
                name       = RLAnimalQuery.formatHusbandryLabel(placeable, i),
            }
        end
    end
    Log:debug("RLAnimalQuery.listHusbandryDescriptorsForFarm: farmId=%s -> %d descriptor(s), %d skipped (no usable target key)",
        tostring(farmId), #descriptors, skipped)
    return descriptors
end

--- Compose a move-destination display label: the base placeable name plus a localized "(butcher)"
--- suffix for an EPP destination, so the picker rows and the rule's destination button label agree
--- (one suffix home shared by this descriptor projection AND the frame's resolvePlaceableName).
--- A husbandry destination gets the bare name. Falls back to a literal "(butcher)" only if g_i18n is
--- unavailable (the key is seeded in every locale, so a live game resolves it).
---@param name string|nil base placeable name
---@param isEPP boolean|nil true for an EPP butcher destination
---@return string label
function RLAnimalQuery.composeDestinationLabel(name, isEPP)
    local base = name or ""
    if isEPP ~= true then return base end
    local suffix = (g_i18n ~= nil and g_i18n:getText("rl_menu_herdsman_destination_butcher_suffix")) or "(butcher)"
    return base .. " " .. suffix
end

--- Project the farm's live MOVE DESTINATIONS into descriptors for the herdsman move-dest picker + the
--- frame's dest-revalidation map. The husbandry half REUSES listHusbandryDescriptorsForFarm verbatim
--- (scalar `animalType`, name-sorted, same stable target keys); the EPP half scans
--- placeableSystem.placeables for owner-farm butchers - mirroring RLMoveDestinationHelper.getValidDestinations'
--- placeable scan, but enumerating the PLACEABLE (MP-stable key) rather than the production point, and
--- reporting the SET of supported type indices (`animalTypes` = keys of pp.animalsTypeData) so a
--- multi-type butcher is ONE picker row under an ANY-type filter. An EPP whose type set is EMPTY is
--- EXCLUDED (it can never accept the pen's animals), as is one with no usable target key.
--- EPP is an OPTIONAL third-party mod: every hop nil-guards spec_extendedProductionPoint /
--- productionPoint / animalsTypeData, so an absent mod yields exactly the husbandry descriptors (zero
--- behavior change). EPP descriptors are appended (unsorted); the presenter re-sorts the candidate set.
---@param farmId number|nil
---@return table descriptors husbandry { uniqueId, animalType, name } + EPP { uniqueId, animalTypes, name, isEPP }
function RLAnimalQuery.listMoveDestinationDescriptorsForFarm(farmId)
    local descriptors = RLAnimalQuery.listHusbandryDescriptorsForFarm(farmId)
    local husbandryCount = #descriptors

    if farmId == nil or farmId == 0 then return descriptors end
    if g_currentMission == nil or g_currentMission.placeableSystem == nil then
        Log:warning("RLAnimalQuery.listMoveDestinationDescriptorsForFarm: placeableSystem unavailable; husbandry dests only")
        return descriptors
    end

    local eppCount, skipped = 0, 0
    for _, placeable in ipairs(g_currentMission.placeableSystem.placeables) do
        local eppSpec = placeable.spec_extendedProductionPoint
        if eppSpec ~= nil and placeable.getOwnerFarmId ~= nil and placeable:getOwnerFarmId() == farmId then
            local pp = eppSpec.productionPoint
            local typeData = pp ~= nil and pp.animalsTypeData or nil
            if type(typeData) == "table" then
                local animalTypes = {}
                for typeIndex in pairs(typeData) do
                    animalTypes[#animalTypes + 1] = typeIndex
                end
                if #animalTypes == 0 then
                    -- A butcher that accepts no animal types can never be a valid dest.
                    skipped = skipped + 1
                    Log:debug("RLAnimalQuery.listMoveDestinationDescriptorsForFarm: EPP '%s' has empty animalsTypeData; excluded",
                        tostring(placeable.getName ~= nil and placeable:getName() or "?"))
                else
                    local key = RLHusbandryTargetKey.keyFor(placeable)
                    if type(key) ~= "string" or key == "" then
                        -- keyFor already :warning'd the unkeyable placeable (nil/empty uniqueId server, nil/0 net-id client).
                        skipped = skipped + 1
                    else
                        table.sort(animalTypes)  -- deterministic set order
                        descriptors[#descriptors + 1] = {
                            uniqueId    = key,
                            animalTypes = animalTypes,
                            name        = RLAnimalQuery.composeDestinationLabel(
                                (placeable.getName ~= nil and placeable:getName()) or "", true),
                            isEPP       = true,
                        }
                        eppCount = eppCount + 1
                    end
                end
            end
        end
    end
    Log:debug("RLAnimalQuery.listMoveDestinationDescriptorsForFarm: farmId=%s -> %d husbandry + %d EPP descriptor(s), %d EPP skipped",
        tostring(farmId), husbandryCount, eppCount, skipped)
    return descriptors
end

-- =============================================================================
-- Animal list + sort + filter
-- =============================================================================

--- Wrap a cluster in an AnimalItemStock. Exposed as a field so unit tests can
--- swap in a lightweight stub without the full animalSystem lookups.
--- @param cluster table
--- @return table|nil
function RLAnimalQuery._wrapCluster(cluster)
    if AnimalItemStock == nil or AnimalItemStock.new == nil then return nil end
    return AnimalItemStock.new(cluster)
end

--- Return the sorted, filtered list of AnimalItemStock items for a husbandry.
--- Sorted via RLAnimalDisplayHelper.sortAnimals (disease-first, then subType,
--- optional genetics, then age). Filtered via AnimalFilterDialog.applyFilters.
--- @param husbandry table
--- @param filters table|nil
--- @return table items
function RLAnimalQuery.listAnimalsForHusbandry(husbandry, filters)
    if husbandry == nil or husbandry.spec_husbandryAnimals == nil then return {} end

    local clusterSystem = husbandry.spec_husbandryAnimals
    if clusterSystem.getClusters == nil then
        Log:warning("RLAnimalQuery.listAnimalsForHusbandry: clusterSystem has no getClusters")
        return {}
    end

    local clusters = clusterSystem:getClusters()
    if clusters == nil then return {} end

    local items = {}
    for _, cluster in pairs(clusters) do
        local wrapped = RLAnimalQuery._wrapCluster(cluster)
        if wrapped ~= nil then
            table.insert(items, wrapped)
        end
    end

    -- Fail-fast if the shared comparator is missing. Unreachable in practice;
    -- main.lua load order puts RLAnimalDisplayHelper in SECTION 2b before rlmenu in 13b.
    if RLAnimalDisplayHelper == nil or RLAnimalDisplayHelper.sortAnimals == nil then
        Log:error("RLAnimalQuery.listAnimalsForHusbandry: RLAnimalDisplayHelper.sortAnimals unavailable; returning empty")
        return {}
    end
    table.sort(items, RLAnimalDisplayHelper.sortAnimals)

    if filters ~= nil and next(filters) ~= nil
        and AnimalFilterDialog ~= nil and AnimalFilterDialog.applyFilters ~= nil then
        items = AnimalFilterDialog.applyFilters(items, filters, false)
    end

    Log:debug("RLAnimalQuery.listAnimalsForHusbandry: husbandry='%s' items=%d filters=%s",
        (husbandry.getName ~= nil and husbandry:getName()) or "?",
        #items,
        (filters ~= nil and next(filters) ~= nil) and "yes" or "no")

    return items
end

-- =============================================================================
-- Row formatting
-- =============================================================================

RLAnimalQuery.TINT_NORMAL  = "normal"
RLAnimalQuery.TINT_DISEASE = "disease"
RLAnimalQuery.TINT_MARKED  = "marked"

--- Format an AnimalItemStock into a display-ready row for the frame layer.
---
--- Row schema:
---   uniqueId, farmId, country : selection identity (three-field animal id)
---   subTypeIndex              : section boundary key
---   icon                      : store image filename
---   baseName                  : raw cluster:getName(), empty = no custom name
---   identifier                : raw cluster:getIdentifiers()
---   displayName               : baseName with genetics tag applied
---   displayIdentifier         : identifier with genetics tag applied
---   price                     : sell price (setValue on the currency cell)
---   hasDisease, isMarked, recentlyBoughtByAI : state flags
---   hasUntreatedDisease, hasTreatedDisease, isDiseaseCarrier : disease icon flags
---   descriptorVisible, descriptorText         : herdsman/mark badge
---   tint                      : "normal" | "marked"
---
--- Malformed cluster returns a sentinel row with "?" placeholders + a warning.
--- @param item table|nil
--- @return table row
function RLAnimalQuery.formatAnimalRow(item)
    local row = {
        uniqueId           = 0,
        farmId             = 0,
        country            = "",
        subTypeIndex       = 0,
        icon               = nil,
        baseName           = "",
        identifier         = "",
        displayName        = "?",
        displayIdentifier  = "?",
        price              = 0,
        hasDisease         = false,
        -- Initialized false, not left nil: the malformed-cluster early return
        -- below and an animal shape without the accessor both reach the icon
        -- resolver, which reads these as plain booleans.
        hasUntreatedDisease = false,
        hasTreatedDisease   = false,
        isDiseaseCarrier    = false,
        isMarked           = false,
        recentlyBoughtByAI = false,
        descriptorVisible  = false,
        descriptorText     = "",
        tint               = RLAnimalQuery.TINT_NORMAL,
    }

    if item == nil or item.cluster == nil then
        Log:warning("RLAnimalQuery.formatAnimalRow: item or cluster missing")
        return row
    end

    local cluster = item.cluster

    row.uniqueId = cluster.uniqueId or 0
    row.farmId   = cluster.farmId or 0
    if cluster.birthday ~= nil then
        row.country = cluster.birthday.country or ""
    end
    row.subTypeIndex = (cluster.getSubTypeIndex ~= nil and cluster:getSubTypeIndex())
        or cluster.subTypeIndex or 0

    if item.getFilename ~= nil then
        row.icon = item:getFilename()
    end

    if cluster.getName ~= nil then
        row.baseName = cluster:getName() or ""
    end
    if cluster.getIdentifiers ~= nil then
        row.identifier = cluster:getIdentifiers() or ""
    end

    if RLAnimalDisplayHelper ~= nil and RLAnimalDisplayHelper.formatDisplayName ~= nil then
        row.displayName       = RLAnimalDisplayHelper.formatDisplayName(row.baseName, cluster)
        row.displayIdentifier = RLAnimalDisplayHelper.formatDisplayName(row.identifier, cluster)
    else
        row.displayName       = row.baseName
        row.displayIdentifier = row.identifier
    end

    if cluster.getSellPrice ~= nil then
        row.price = cluster:getSellPrice() or 0
    end

    if cluster.getHasAnyDisease ~= nil then
        row.hasDisease = cluster:getHasAnyDisease() == true
    end
    -- Nil-guarded because a row's cluster is not always an RLRM Animal: a
    -- vanilla world-trailer cluster before conversion, and a Buy-frame store
    -- item of the same shape, both reach here and render no icons.
    if cluster.getDiseaseStatusFlags ~= nil then
        local untreated, treated, carrier = cluster:getDiseaseStatusFlags()
        row.hasUntreatedDisease = untreated == true
        row.hasTreatedDisease   = treated == true
        row.isDiseaseCarrier    = carrier == true
    end
    if cluster.getMarked ~= nil then
        row.isMarked = cluster:getMarked() == true
    end
    if cluster.getRecentlyBoughtByAI ~= nil then
        row.recentlyBoughtByAI = cluster:getRecentlyBoughtByAI() == true
    end

    -- Descriptor: recently-bought beats mark text when both are set.
    if row.recentlyBoughtByAI then
        row.descriptorVisible = true
        if g_i18n ~= nil then
            row.descriptorText = g_i18n:getText("rl_ui_herdsmanRecentlyBought")
        end
    elseif row.isMarked then
        row.descriptorVisible = true
        if cluster.getHighestPriorityMark ~= nil and RLConstants ~= nil and RLConstants.MARKS ~= nil then
            local markIndex = cluster:getHighestPriorityMark()
            local markEntry = markIndex ~= nil and RLConstants.MARKS[markIndex] or nil
            if markEntry ~= nil and markEntry.text ~= nil and g_i18n ~= nil then
                row.descriptorText = g_i18n:getText("rl_mark_" .. markEntry.text)
            end
        end
    end

    -- Tint: marked beats normal. Disease is carried by the status-icon row
    -- rather than the tint, because it needs to distinguish untreated from
    -- under-treatment from carrier and a single tint cannot. A marked animal
    -- keeps its orange tint whether or not it is also diseased.
    if row.isMarked then
        row.tint = RLAnimalQuery.TINT_MARKED
    end

    -- Status icon fields (Category 1: pregnancy/fertility).
    local isFemale = cluster.gender == "female"
    row.isPregnant = isFemale and (cluster.isPregnant == true)
    row.isRecoveringFromBirth = isFemale
        and (cluster.isParent == true)
        and (cluster.monthsSinceLastBirth ~= nil and cluster.monthsSinceLastBirth <= 2)
    row.isInfertile = cluster.genetics ~= nil
        and cluster.genetics.fertility ~= nil
        and cluster.genetics.fertility <= 0

    -- Status icon fields (Category 2: production, monitor-gated).
    -- Follows the buildOutputRows pattern from RLAnimalInfoService.
    local hasMonitor = cluster.monitor ~= nil
        and (cluster.monitor.active == true or cluster.monitor.removed == true)
    row.hasMonitor = hasMonitor
    row.productionIcon = nil
    if hasMonitor and type(cluster.output) == "table" then
        if (cluster.output["milk"] or 0) > 0 then
            row.productionIcon = "milk"
        elseif (cluster.output["pallets"] or 0) > 0 then
            if cluster.animalTypeIndex == AnimalType.SHEEP then
                row.productionIcon = (cluster.subType == "GOAT") and "milk" or "scissors"
            elseif cluster.animalTypeIndex == AnimalType.CHICKEN then
                row.productionIcon = "egg"
            elseif cluster.animalTypeIndex == AnimalType.COW then
                row.productionIcon = "milk"
            end
        end
    end

    return row
end

-- =============================================================================
-- Status icon resolution
-- =============================================================================

--- Slot names for the card's status-icon row, left to right. ONE module-level
--- constant rather than a literal per frame: five copies of a slot-name list is
--- five places for a rename to miss one, and a missed one shows as a silently
--- absent icon rather than an error.
RLAnimalQuery.SLOT_NAMES = {
    "statusIcon1", "statusIcon2", "statusIcon3",
    "statusIcon4", "statusIcon5", "statusIcon6",
}

--- Dev-only: emit every icon for every row, so a layout spike can measure a
--- fully-populated row against the card's other content without hunting for an
--- animal in each state. A misspelled slot name shows up as a missing icon
--- under forced fill, which is the other thing it proves.
---
--- Never commit true, and the suite enforces that rather than trusting it: the
--- resolver's own asserts redden while this is set, so a run with it left on
--- cannot go green.
RLAnimalQuery.DEV_FORCE_ALL_ICONS = false

--- Resolve 0-5 status icons for an animal row.
--- Returns an array of {slice, r, g, b} entries, ordered for right-justified
--- rendering: first entry = leftmost icon, last entry = rightmost icon.
---
--- Order is disease, then pregnancy/fertility, then production, so health reads
--- at the left of the row while the production marker keeps the right edge it
--- has always had. Disease contributes up to three INDEPENDENT icons; the other
--- two groups are internally exclusive and contribute at most one each - five
--- concurrent worst case, against six slots.
--- @param row table  Row from formatAnimalRow
--- @return table icons  Array of {slice=string, r=number, g=number, b=number}
function RLAnimalQuery.resolveStatusIcons(row)
    local icons = {}

    -- Dev-only layout fill: one distinct icon per slot, so a spike sees the row
    -- at full width and an unwired slot shows as a gap. Deliberately exceeds the
    -- five-icon production worst case - the point is the row's geometry, not a
    -- reachable animal state - and it takes the whole branch rather than
    -- widening each real condition, because ORing the flags leaves the
    -- exclusive groups resolving from live state and under-fills the row.
    if RLAnimalQuery.DEV_FORCE_ALL_ICONS then
        return {
            { slice = "rlStatus.briefcase_medical", r = 0.92, g = 0.34, b = 0.30 },
            { slice = "rlStatus.pill_bottle",       r = 0.47, g = 0.71, b = 0.91 },
            { slice = "rlStatus.dna",               r = 0.65, g = 0.65, b = 0.65 },
            { slice = "rlStatus.baby",              r = 0.85, g = 0.47, b = 0.75 },
            { slice = "rlStatus.circle_off",        r = 0.65, g = 0.65, b = 0.65 },
            { slice = "rlStatus.milk",              r = 0.47, g = 0.71, b = 0.91 },
        }
    end

    -- Disease: three INDEPENDENT flags, so an animal carrying an untreated
    -- infection AND a carried gene shows both.
    if row.hasUntreatedDisease then
        icons[#icons + 1] = { slice = "rlStatus.briefcase_medical", r = 0.92, g = 0.34, b = 0.30 }
    end
    if row.hasTreatedDisease then
        icons[#icons + 1] = { slice = "rlStatus.pill_bottle", r = 0.47, g = 0.71, b = 0.91 }
    end
    if row.isDiseaseCarrier then
        icons[#icons + 1] = { slice = "rlStatus.dna", r = 0.65, g = 0.65, b = 0.65 }
    end

    -- Category 1: Pregnancy / Fertility (mutually exclusive)
    if row.isPregnant then
        icons[#icons + 1] = { slice = "rlStatus.baby", r = 0.85, g = 0.47, b = 0.75 }
    elseif row.isRecoveringFromBirth then
        icons[#icons + 1] = { slice = "rlStatus.timer_reset", r = 0.95, g = 0.65, b = 0.30 }
    elseif row.isInfertile then
        icons[#icons + 1] = { slice = "rlStatus.circle_off", r = 0.65, g = 0.65, b = 0.65 }
    end

    -- Category 2: Production (from productionIcon, already monitor-gated in formatAnimalRow)
    if row.productionIcon == "milk" then
        icons[#icons + 1] = { slice = "rlStatus.milk", r = 0.47, g = 0.71, b = 0.91 }
    elseif row.productionIcon == "scissors" then
        icons[#icons + 1] = { slice = "rlStatus.scissors", r = 0.47, g = 0.71, b = 0.91 }
    elseif row.productionIcon == "egg" then
        icons[#icons + 1] = { slice = "rlStatus.egg", r = 0.47, g = 0.71, b = 0.91 }
    end

    Log:trace("RLAnimalQuery.resolveStatusIcons: uniqueId=%s count=%d untreated=%s treated=%s carrier=%s pregnant=%s recovering=%s infertile=%s production=%s",
        tostring(row.uniqueId), #icons,
        tostring(row.hasUntreatedDisease), tostring(row.hasTreatedDisease),
        tostring(row.isDiseaseCarrier), tostring(row.isPregnant),
        tostring(row.isRecoveringFromBirth), tostring(row.isInfertile),
        tostring(row.productionIcon))

    return icons
end

--- Fill a row of icon slots on a cell, right-justified: the LAST icon lands in
--- the LAST slot, so a partially-filled row hugs the same edge as a full one.
---
--- Two boundaries the callers depend on. A nil slot is skipped rather than
--- raising, because a frame may legitimately not declare every slot. And when
--- there are more icons than slots the RIGHTMOST slots win, so the icons that
--- fall off are the leading ones rather than the trailing ones.
---
--- Slices are set per visual state because setImageSlice writes one state only;
--- an unset state falls back to the normal slice, which is why FOCUSED is left
--- alone and renders through the profile's own focused colour.
--- @param cell table  SmoothList cell
--- @param slotNames table  Array of slot attribute names, left to right
--- @param icons table  Array of {slice, r, g, b} from a resolve* function
function RLAnimalQuery.applyStatusIconSlots(cell, slotNames, icons)
    if cell == nil or slotNames == nil or icons == nil then return end

    local slotCount = #slotNames
    for i = 1, slotCount do
        local slot = cell:getAttribute(slotNames[i])
        if slot ~= nil then
            -- Right-justify: icon N fills slot (slotCount - #icons + N).
            local iconIndex = i - (slotCount - #icons)
            local def = icons[iconIndex]
            if def ~= nil then
                slot:setImageSlice(GuiOverlay.STATE_NORMAL, def.slice)
                slot:setImageSlice(GuiOverlay.STATE_SELECTED, def.slice)
                slot:setImageSlice(GuiOverlay.STATE_HIGHLIGHTED, def.slice)
                slot:setImageColor(GuiOverlay.STATE_NORMAL, def.r, def.g, def.b)
                -- Bitmap gamma workaround: 0.015/0.017/0.015 produces #212321
                -- matching card text (preset_fs25_colorMainDark renders #0E0E0D via bitmaps).
                slot:setImageColor(GuiOverlay.STATE_SELECTED, 0.015, 0.017, 0.015)
                slot:setImageColor(GuiOverlay.STATE_HIGHLIGHTED, 0.015, 0.017, 0.015)
                slot:setVisible(true)
            else
                slot:setVisible(false)
            end
        end
    end
end

-- =============================================================================
-- Section grouping (SmoothList multi-section data source)
-- =============================================================================

--- Group a sorted item list into sections:
---   1. Diseased Animals (if any diseased items exist, regardless of subType)
---   2. One section per distinct subType, in first-seen order
---
--- Returns three parallel tables:
---   sectionOrder[]  : opaque section keys in display order
---   itemsBySection  : section key -> items array
---   titlesBySection : section key -> localized title string
---
--- Pure function on the items array; no mutation of the input.
--- @param items table
--- @return table sectionOrder, table itemsBySection, table titlesBySection
function RLAnimalQuery.buildSections(items)
    local sectionOrder    = {}
    local itemsBySection  = {}
    local titlesBySection = {}

    if items == nil or #items == 0 then
        return sectionOrder, itemsBySection, titlesBySection
    end

    local DISEASED_KEY = "__diseased__"

    for _, item in ipairs(items) do
        local cluster = item.cluster
        if cluster ~= nil then
            local isDiseased = cluster.getHasAnyDisease ~= nil and cluster:getHasAnyDisease() == true
            local key, title

            if isDiseased then
                key = DISEASED_KEY
                title = (g_i18n ~= nil) and g_i18n:getText("rl_ui_diseasedAnimals") or "Diseased Animals"
            else
                key = "subtype_" .. tostring(cluster.subTypeIndex or 0)
                -- Prefer wrapper's cached title; fall back to animalSystem lookup
                -- so test stubs with minimal item tables still produce something.
                title = item.title
                if (title == nil or title == "") and g_currentMission ~= nil
                    and g_currentMission.animalSystem ~= nil then
                    local subType = g_currentMission.animalSystem:getSubTypeByIndex(cluster.subTypeIndex)
                    if subType ~= nil and subType.fillTypeIndex ~= nil and g_fillTypeManager ~= nil then
                        title = g_fillTypeManager:getFillTypeTitleByIndex(subType.fillTypeIndex)
                    end
                end
                if title == nil or title == "" then title = "?" end
            end

            if itemsBySection[key] == nil then
                table.insert(sectionOrder, key)
                itemsBySection[key] = {}
                titlesBySection[key] = title
            end
            table.insert(itemsBySection[key], item)
        end
    end

    return sectionOrder, itemsBySection, titlesBySection
end

--- Find (section, index) for an item by stable animal identity.
--- @param sectionOrder table
--- @param itemsBySection table
--- @param farmId number|nil
--- @param uniqueId number|nil
--- @param country string|nil
--- @return number|nil section, number|nil indexInSection
function RLAnimalQuery.findSectionedItemByIdentity(sectionOrder, itemsBySection, farmId, uniqueId, country)
    if sectionOrder == nil or itemsBySection == nil
        or farmId == nil or uniqueId == nil then
        return nil, nil
    end

    for sectionIdx, key in ipairs(sectionOrder) do
        local list = itemsBySection[key]
        if list ~= nil then
            for i = 1, #list do
                local cluster = list[i] ~= nil and list[i].cluster or nil
                if cluster ~= nil
                    and cluster.farmId == farmId
                    and cluster.uniqueId == uniqueId then
                    local clusterCountry = cluster.birthday ~= nil and cluster.birthday.country or nil
                    if country == nil or clusterCountry == country then
                        return sectionIdx, i
                    end
                end
            end
        end
    end

    return nil, nil
end
