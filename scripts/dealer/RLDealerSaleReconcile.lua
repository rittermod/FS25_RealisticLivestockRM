-- RLDealerSaleReconcile.lua
-- Turns a selector-dialog result into the minimal set of override-registry operations, resolved
-- against the animal's SHIPPED default.
--
-- The registry is a SPARSE store of non-default entries, so a toggle landing back on the
-- shipped default must CLEAR its override rather than pin the current value: a cleared stage
-- keeps tracking future default changes (a map, DLC or update moving that flag).
--
-- Two comparisons drive one op:
--   desired vs `visual.buyable`    -> is this row a real CHANGE at all?
--   desired vs the shipped default -> is that change a `set` or a `clear`?
--
-- A key absent from `baseline` has no override, so its LIVE value IS its shipped default and
-- `visual.buyable` is the exact fallback. Only CHANGED rows are emitted, so the caller can
-- gate its dealer re-roll on "any op applied". Data in, data out: no engine access.

local Log = RmLogging.getLogger("RLRM")

RLDealerSaleReconcile = {}

--- True when `minAge` can key a stage: a non-NaN number. NaN is refused because `minAge` is a
--- TABLE KEY below and `t[0/0] = v` raises. The registry's stricter finite-integer rule is not
--- applied here - a fractional catalog `minAge` must still match, or its row reads unchecked.
---@param minAge any
---@return boolean
local function isKeyableMinAge(minAge)
    return type(minAge) == "number" and minAge == minAge
end

--- True when `subTypeName` can key a stage.
---@param subTypeName any
---@return boolean
local function isKeyableName(subTypeName)
    return type(subTypeName) == "string" and subTypeName ~= ""
end

--- Collect the dialog result into a nested lookup `set[subTypeName][minAge] = true`. Nested
--- tables, not an encoded string key, keep the match EXACT for any numeric `minAge` - a
--- rendered key would alias a fractional stage onto its neighbour.
---@param result any dialog result: array of { subTypeName=, minAge= }
---@return table lookup
local function checkedSet(result)
    local set = {}

    if type(result) ~= "table" then
        Log:trace("RLDealerSaleReconcile.diff: result is not a table (%s); treating as all-unchecked",
            type(result))
        return set
    end

    for _, entry in ipairs(result) do
        if type(entry) ~= "table" then
            Log:trace("RLDealerSaleReconcile.diff: skipped a non-table result entry (%s)", type(entry))
        elseif not isKeyableName(entry.subTypeName) or not isKeyableMinAge(entry.minAge) then
            Log:trace("RLDealerSaleReconcile.diff: skipped a malformed result entry (subTypeName=%s, minAge=%s)",
                tostring(entry.subTypeName), tostring(entry.minAge))
        else
            set[entry.subTypeName] = set[entry.subTypeName] or {}
            set[entry.subTypeName][entry.minAge] = true
        end
    end

    return set
end

--- Shipped default for one stage: the `baseline` entry when boolean, else the live value - a
--- key with no baseline entry has no override, so its live flag IS its default.
---@param baseline table|nil captured-default map: baseline[subTypeName][minAge] = boolean
---@param subTypeName string
---@param minAge number
---@param liveBuyable boolean current effective value (the fallback)
---@return boolean shipped
local function shippedDefault(baseline, subTypeName, minAge, liveBuyable)
    if baseline == nil then
        return liveBuyable
    end

    local ages = baseline[subTypeName]
    if type(ages) ~= "table" or type(ages[minAge]) ~= "boolean" then
        return liveBuyable
    end

    return ages[minAge]
end

--- Diff a selector result against the catalog it was opened over, emitting one registry op per
--- CHANGED stage: `desired` equal to the visual's `buyable` emits nothing, else matching the
--- shipped default emits `clear` and anything else emits `set`.
---
--- A duplicate `subTypeName` is dropped at ENTRY granularity, matching the selector model,
--- which skips a repeated section key BEFORE building rows: whatever the dialog did not show
--- is not its answer, so diffing it would turn off stages the player never touched.
---@param result any dialog result: array of { subTypeName=, minAge= }; nil-safe
---@param catalog any catalog view-model: array of { subTypeName=, visuals={ { minAge=, buyable= }, ... } }
---@param baseline any captured-default map: baseline[subTypeName][minAge] = boolean; may be empty/nil
---@return table[] ops array of { subTypeName=, minAge=, action="set"|"clear", canBeBought=boolean? }
function RLDealerSaleReconcile.diff(result, catalog, baseline)
    local ops = {}

    if type(catalog) ~= "table" then
        Log:warning("RLDealerSaleReconcile.diff: catalog is not a table (%s); no ops", type(catalog))
        return ops
    end

    local base = baseline
    if base ~= nil and type(base) ~= "table" then
        Log:trace("RLDealerSaleReconcile.diff: baseline is not a table (%s); falling back to live values",
            type(base))
        base = nil
    end

    local checked = checkedSet(result)
    local seen = {}
    local skipped, duplicates, unchanged = 0, 0, 0

    for _, entry in ipairs(catalog) do
        if type(entry) ~= "table" then
            skipped = skipped + 1
            Log:trace("RLDealerSaleReconcile.diff: skipped a non-table catalog entry (%s)", type(entry))
        elseif not isKeyableName(entry.subTypeName) or type(entry.visuals) ~= "table" then
            skipped = skipped + 1
            Log:trace("RLDealerSaleReconcile.diff: skipped catalog entry with bad subTypeName (%s) or visuals (%s)",
                tostring(entry.subTypeName), type(entry.visuals))
        elseif seen[entry.subTypeName] ~= nil then
            skipped = skipped + 1
            Log:trace("RLDealerSaleReconcile.diff: duplicate subTypeName %s; later entry skipped whole (never rendered)",
                tostring(entry.subTypeName))
        else
            local name = entry.subTypeName
            local checkedAges = checked[name]
            seen[name] = {}

            for _, visual in ipairs(entry.visuals) do
                if type(visual) ~= "table" then
                    skipped = skipped + 1
                    Log:trace("RLDealerSaleReconcile.diff: %s skipped a non-table visual (%s)", name, type(visual))
                elseif not isKeyableMinAge(visual.minAge) or type(visual.buyable) ~= "boolean" then
                    skipped = skipped + 1
                    Log:trace("RLDealerSaleReconcile.diff: %s skipped a visual with bad minAge (%s) or buyable (%s)",
                        name, tostring(visual.minAge), tostring(visual.buyable))
                elseif seen[name][visual.minAge] then
                    duplicates = duplicates + 1
                    Log:trace("RLDealerSaleReconcile.diff: %s @%s seen twice; first occurrence wins",
                        name, tostring(visual.minAge))
                else
                    local minAge = visual.minAge
                    seen[name][minAge] = true

                    local current = visual.buyable
                    local desired = checkedAges ~= nil and checkedAges[minAge] == true

                    if desired == current then
                        unchanged = unchanged + 1
                    else
                        local shipped = shippedDefault(base, name, minAge, current)
                        if desired == shipped then
                            ops[#ops + 1] = { subTypeName = name, minAge = minAge, action = "clear" }
                            Log:trace("RLDealerSaleReconcile.diff: %s @%s -> clear (desired %s is the shipped default)",
                                name, tostring(minAge), tostring(desired))
                        else
                            ops[#ops + 1] = { subTypeName = name, minAge = minAge, action = "set", canBeBought = desired }
                            Log:trace("RLDealerSaleReconcile.diff: %s @%s -> set %s (shipped default is %s)",
                                name, tostring(minAge), tostring(desired), tostring(shipped))
                        end
                    end
                end
            end
        end
    end

    Log:debug("RLDealerSaleReconcile.diff: %d op(s) from %d catalog entr(ies); %d unchanged, %d skipped, %d duplicate(s)",
        #ops, #catalog, unchanged, skipped, duplicates)
    return ops
end

Log:debug("RLDealerSaleReconcile: loaded")
