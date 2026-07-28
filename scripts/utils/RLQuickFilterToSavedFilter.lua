-- RLQuickFilterToSavedFilter.lua
-- Pure-data conversion from AnimalFilterDialog widget state into the saved-filter
-- payload shape expected by g_rlFilterService:create.
--
-- Mirrors the prune semantics of AnimalFilterDialog:onClickOk (full-range sliders
-- are dropped; "ignore" binaries are dropped) so save-from-QF matches apply-from-QF
-- on identical widget state. Catalog-key renames (`getHasAnyDisease` -> `hasAnyDisease`,
-- `getHasName` -> `hasName`) bridge the QF target string to the RLFilterFieldCatalog key.
-- Layered genetics slider targets are flattened to `genetics.<axis>` and the raw
-- 0.25-1.75 range is mapped to the catalog's 0-99 integer scale via
-- RLScaleHelper.scaleToNinetyNine.
--
-- The `getSellPrice` (Value) row has no catalog counterpart and is dropped from the
-- saved expression; `droppedValue` is set on the return so the caller can surface a
-- one-time warning to the user.
--
-- Consumers: AnimalFilterDialog:onClickSaveFilter (production), the
-- RLQuickFilterToSavedFilterTests suite (rlTest).
--
-- No GUI imports. No global mutations. Frame-agnostic: the `usage` axis is supplied
-- by the caller (OWNED for Info/Sell/Move, DEALER for Buy) and threaded verbatim
-- into the payload.

local Log = RmLogging.getLogger("RLRM")

RLQuickFilterToSavedFilter = {}

-- =============================================================================
-- Catalog key map (QF target -> RLFilterFieldCatalog key)
-- =============================================================================

-- QF binary rows reference live getter functions (`getHasAnyDisease`, `getHasName`);
-- the catalog stores the same data under boolean keys (`hasAnyDisease`, `hasName`).
-- The map is the single source of truth for the rename so a future binary row
-- (e.g. `getHasAnyMark` -> `hasAnyMark`) only needs an entry added here.
local QF_TO_CATALOG_KEY = {
    getHasAnyDisease = "hasAnyDisease",
    getHasName       = "hasName",
}

--- Resolve a single QF row's target to its saved-filter catalog key.
--- Returns nil for `getSellPrice` (intentionally not in catalog; dropped with warning)
--- and for any unknown target (defensive; warn so a future row with no mapping is
--- visible in logs).
---@param filter table the QF row
---@return string|nil catalog key
local function resolveCatalogKey(filter)
    if filter.isLayered then
        -- Layered targets are {"genetics", "<axis>"} -> "genetics.<axis>".
        if type(filter.target) == "table" and filter.target[1] == "genetics" and filter.target[2] ~= nil then
            return "genetics." .. tostring(filter.target[2])
        end
        Log:warning("RLQuickFilterToSavedFilter.resolveCatalogKey: unknown layered target shape (filter=%s)", tostring(filter.name))
        return nil
    end
    if filter.target == "getSellPrice" then
        return nil
    end
    local renamed = QF_TO_CATALOG_KEY[filter.target]
    if renamed ~= nil then return renamed end
    -- Plain catalog-aligned target ("age", "gender", "isPregnant", "isLactating").
    return filter.target
end

-- =============================================================================
-- Per-row conversion
-- =============================================================================

--- Convert one QF slider row to zero or two `>=`/`<=` leaf conditions.
--- Mirrors AnimalFilterDialog:onClickOk prune semantics:
--- a full-range slider (left thumb at 1, right thumb at cachedCount) is pruned.
--- Crossed thumbs are tolerated via math.min/math.max (legacy parity).
---
--- For genetics rows the raw [0.25, 1.75] value is mapped to the catalog's 0-99
--- integer scale via RLScaleHelper.scaleToNinetyNine. For all other slider rows
--- the raw value is used directly (age in months, health 0-100, weight kg).
---
--- `getSellPrice` rows return `dropped=true` so the caller can surface a warning
--- and skip emitting children.
---
---@param filter table QF slider row
---@param appendChild fun(child:table) emit a condition child into the AND group
---@return boolean dropped true iff the row was intentionally not emitted
local function convertSliderRow(filter, appendChild)
    -- Full-range prune. cachedTexts may be nil if the slider was constructed in a
    -- degenerate state (the dialog logs a warning at line ~464 for this); treat it
    -- as full-range (no narrowing) and prune defensively.
    local cachedCount = (filter.cachedTexts ~= nil) and #filter.cachedTexts or 0
    local left  = filter.uiLeftState  or 1
    local right = filter.uiRightState or 1
    if cachedCount == 0 then
        Log:trace("RLQuickFilterToSavedFilter.convertSliderRow: '%s' has empty cachedTexts; pruning",
            tostring(filter.name))
        return false
    end
    if math.min(left, right) == 1 and math.max(left, right) == cachedCount then
        Log:trace("RLQuickFilterToSavedFilter.convertSliderRow: '%s' full-range (left=%d right=%d range=1..%d); pruning",
            tostring(filter.name), left, right, cachedCount)
        return false
    end

    -- getSellPrice -> dropped with warning. The catalog has no `getSellPrice`
    -- field and the QF buy-mode markup (the active dealer-quality preset's,
    -- resolved at evaluation time) is dialog-layer only; saving the raw value
    -- would silently match different animals across Info/Sell/Buy.
    if (not filter.isLayered) and filter.target == "getSellPrice" then
        Log:trace("RLQuickFilterToSavedFilter.convertSliderRow: getSellPrice narrowed (left=%d right=%d); dropping with warning",
            left, right)
        return true
    end

    local multiplier = filter.multiplier or 1
    local rawLow  = (math.min(left, right) - 1) / multiplier
    local rawHigh = (math.max(left, right) - 1) / multiplier

    local key = resolveCatalogKey(filter)
    if key == nil then
        Log:warning("RLQuickFilterToSavedFilter.convertSliderRow: '%s' unresolved catalog key; skipping",
            tostring(filter.name))
        return false
    end

    local valueLow, valueHigh
    if filter.isLayered and type(filter.target) == "table" and filter.target[1] == "genetics" then
        if RLScaleHelper == nil or RLScaleHelper.scaleToNinetyNine == nil then
            Log:warning("RLQuickFilterToSavedFilter.convertSliderRow: RLScaleHelper.scaleToNinetyNine unavailable; skipping genetics row '%s'",
                tostring(filter.name))
            return false
        end
        valueLow  = RLScaleHelper.scaleToNinetyNine(rawLow)
        valueHigh = RLScaleHelper.scaleToNinetyNine(rawHigh)
    else
        valueLow  = rawLow
        valueHigh = rawHigh
    end

    Log:trace("RLQuickFilterToSavedFilter.convertSliderRow: keep '%s' field=%s rawLow=%.4f rawHigh=%.4f -> [%s, %s]",
        tostring(filter.name), key, rawLow, rawHigh, tostring(valueLow), tostring(valueHigh))

    appendChild({ field = key, cmp = ">=", value = valueLow  })
    appendChild({ field = key, cmp = "<=", value = valueHigh })
    return false
end

--- Convert one QF binary row to zero or one `==` leaf condition.
--- Mirrors AnimalFilterDialog:onClickOk: state=2 ("ignore") is
--- pruned; the selected value is read from filter.text[state].value (the row's
--- canonical value, not a localized label).
---
---@param filter table QF binary row
---@param appendChild fun(child:table) emit a condition child into the AND group
local function convertBinaryRow(filter, appendChild)
    local state = filter.uiState or filter.default or 1
    local entry = filter.text and filter.text[state]
    if entry == nil then
        Log:warning("RLQuickFilterToSavedFilter.convertBinaryRow: '%s' state=%s has no filter.text entry; skipping",
            tostring(filter.name), tostring(state))
        return
    end
    local value = entry.value
    if value == "ignore" then
        Log:trace("RLQuickFilterToSavedFilter.convertBinaryRow: '%s' state=%d ignore; pruning",
            tostring(filter.name), state)
        return
    end
    local key = resolveCatalogKey(filter)
    if key == nil then
        Log:warning("RLQuickFilterToSavedFilter.convertBinaryRow: '%s' unresolved catalog key; skipping",
            tostring(filter.name))
        return
    end
    Log:trace("RLQuickFilterToSavedFilter.convertBinaryRow: keep '%s' field=%s value=%s",
        tostring(filter.name), key, tostring(value))
    appendChild({ field = key, cmp = "==", value = value })
end

-- =============================================================================
-- Public entry
-- =============================================================================

--- Build a saved-filter create payload from the QF dialog's per-row widget state.
---
--- `dialogFilters` is the AnimalFilterDialog `self.filters` array post-onOpen. Each
--- row carries `template` ("sliderTemplate"|"binaryOptionTemplate"), `target`,
--- `uiState`/`uiLeftState`/`uiRightState`, `text` (for binaries), `cachedTexts`
--- (for sliders), `multiplier`, `isLayered`, `isFunction`.
---
--- The returned payload is shaped for `RLFilterService:create`:
---   { name = string, animalType = integer|nil, farmId = integer,
---     usage = string (canonical RLFilterUsage), expression = { op="AND", children={...} } }
---
--- `droppedValue` flags whether at least one `getSellPrice` row was narrowed and
--- intentionally dropped from the expression. The caller surfaces a one-time warning
--- to the user when this is true.
---
---@param dialogFilters table[] AnimalFilterDialog.self.filters (post-onOpen)
---@param animalTypeIndex integer|nil AnimalType index for the saved filter (per-frame)
---@param farmId integer farm id for the saved filter
---@param defaultName string seed name (caller computes via the static helper from RLMenuSettingsFrame)
---@param usage string canonical RLFilterUsage value (OWNED for Info/Sell/Move, DEALER for Buy)
---@return table payload create-shape payload
---@return boolean droppedValue true iff a getSellPrice row was narrowed and dropped
function RLQuickFilterToSavedFilter.buildSavedFilterPayload(dialogFilters, animalTypeIndex, farmId, defaultName, usage)
    local children = {}
    local droppedValue = false
    local kept = 0
    local dropped = 0

    local function appendChild(child)
        kept = kept + 1
        table.insert(children, child)
    end

    if dialogFilters ~= nil then
        for _, filter in ipairs(dialogFilters) do
            if filter.template == "sliderTemplate" then
                local rowDropped = convertSliderRow(filter, appendChild)
                if rowDropped then
                    droppedValue = true
                    dropped = dropped + 1
                end
            elseif filter.template == "binaryOptionTemplate" then
                convertBinaryRow(filter, appendChild)
            end
        end
    end

    local payload = {
        name       = defaultName,
        animalType = animalTypeIndex,
        farmId     = farmId,
        usage      = usage,
        expression = { op = "AND", children = children },
    }

    Log:debug("RLQuickFilterToSavedFilter.buildSavedFilterPayload: kept=%d dropped=%d usage=%s droppedValue=%s",
        kept, dropped, tostring(usage), tostring(droppedValue))

    return payload, droppedValue
end

Log:trace("RLQuickFilterToSavedFilter: loaded")
