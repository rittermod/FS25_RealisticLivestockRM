-- RLDealerSaleSelectorModel.lua
-- Pure, dual-run core for the dealer sale-availability selector dialog: turns the catalog
-- view-model into the sectioned checkbox model the dialog renders, and collects the checked rows
-- back into a caller-facing for-sale set. Data in / data out - no g_*, GUI, XML or engine
-- natives - so the same file runs under in-game rlTest and the headless harness.
--
-- Three groups, all pure; the GUI wiring lives in RLDealerSaleSelectorDialog:
--   * buildSectionModel(catalog) - one SECTION per catalog subType, dropping any that yields no
--     keyable row, with each row keyed by a composite (subTypeName, minAge) string.
--   * buildResult(selected, keyMeta, sectionOrder, itemsBySection) - the checked in-scope rows
--     as a deduped, section/row-ordered array of {subTypeName, minAge}.
--   * the selection transitions and their predicates. They live here rather than in the dialog
--     because the section arithmetic is off-by-one-prone and no automated tier reaches a dialog
--     handler.
--
-- Composite key scheme: `subTypeName .. U+001F .. tostring(minAge)`. U+001F cannot occur in a
-- subType identifier, so the join is unambiguous. The key is an INTERNAL handle; the PUBLIC row
-- identity the dialog and caller see stays the decomposed (subTypeName, minAge) pair.
--
-- Selection-out only: this model never mutates the registry, the store or the catalog, and never
-- round-trips out-of-scope keys - it only knows the in-scope catalog it was handed.

local Log = RmLogging.getLogger("RLRM")

RLDealerSaleSelectorModel = {}

-- ASCII unit separator, which cannot appear in a subType identifier, so the composite join is
-- lossless and collision-free.
local KEY_SEP = "\31"

--- Build the internal composite key for a (subTypeName, minAge) row.
---@param subTypeName any
---@param minAge any
---@return string
local function rowKey(subTypeName, minAge)
    return tostring(subTypeName) .. KEY_SEP .. tostring(minAge)
end

--- Section title, falling through the resolved subTypeLabel, the raw subTypeName, then "?". A
--- non-string or empty value at a level falls to the next.
---@param subTypeLabel any
---@param subTypeName any
---@return string
local function titleOf(subTypeLabel, subTypeName)
    if type(subTypeLabel) == "string" and subTypeLabel ~= "" then return subTypeLabel end
    if type(subTypeName) == "string" and subTypeName ~= "" then return subTypeName end
    return "?"
end

-- =============================================================================
-- buildSectionModel - catalog view-model -> sectioned checkbox model
-- =============================================================================

--- Compose the sectioned checkbox model from a catalog view-model: one SECTION per catalog
--- subType keyed by subTypeName, each visual becoming one row. A row whose composite key was
--- already emitted anywhere in this build is SKIPPED, so no checkbox aliasing or keyMeta
--- overwrite occurs, and a subType that yields ZERO keyable rows emits NO section rather than a
--- headed, row-less one.
---
--- `initialSelected[key]` is the catalog's effective buyability, and `keyMeta[key]` decodes a key
--- back to its public pair for buildResult. Order is catalog order for sections and visual order
--- within a section - never sorted here, since the catalog already ordered them.
---@param catalog table|nil catalog: array of { subTypeName, subTypeLabel, visuals=[{minAge, ageRangeLabel, iconFilename, buyable}] }
---@return table model { sectionOrder=[key], itemsBySection={key->rows}, titlesBySection={key->title}, initialSelected={key->bool}, keyMeta={key->{subTypeName,minAge}} }
function RLDealerSaleSelectorModel.buildSectionModel(catalog)
    local model = {
        sectionOrder    = {},
        itemsBySection  = {},
        titlesBySection = {},
        initialSelected = {},
        keyMeta         = {},
    }

    if type(catalog) ~= "table" then
        Log:trace("RLDealerSaleSelectorModel.buildSectionModel: catalog is not a table (%s); empty model", type(catalog))
        return model
    end

    local counters = { entriesSkipped = 0, rowsSkipped = 0, dupSkipped = 0 }

    for _, entry in ipairs(catalog) do
        if type(entry) ~= "table" then
            counters.entriesSkipped = counters.entriesSkipped + 1
            Log:trace("RLDealerSaleSelectorModel.buildSectionModel: dropped a non-table catalog entry")
        elseif type(entry.subTypeName) ~= "string" or entry.subTypeName == "" then
            -- Sections are keyed by subTypeName, and `t[nil]` would crash on write.
            counters.entriesSkipped = counters.entriesSkipped + 1
            Log:trace("RLDealerSaleSelectorModel.buildSectionModel: dropped an entry with nil/empty subTypeName (%s)",
                tostring(entry.subTypeName))
        elseif type(entry.visuals) ~= "table" then
            counters.entriesSkipped = counters.entriesSkipped + 1
            Log:trace("RLDealerSaleSelectorModel.buildSectionModel: %s has nil/non-table visuals; skipped",
                tostring(entry.subTypeName))
        elseif model.itemsBySection[entry.subTypeName] ~= nil then
            -- Skip a duplicate section key BEFORE building its rows: registering it would
            -- overwrite the first entry's rows and double-append the section key, and deferring
            -- the row build keeps keyMeta and initialSelected free of its stray keys.
            counters.entriesSkipped = counters.entriesSkipped + 1
            Log:trace("RLDealerSaleSelectorModel.buildSectionModel: duplicate section key %s; later entry skipped",
                tostring(entry.subTypeName))
        else
            local subTypeName = entry.subTypeName
            local rows = {}
            for _, visual in ipairs(entry.visuals) do
                if type(visual) ~= "table" or type(visual.minAge) ~= "number" then
                    counters.rowsSkipped = counters.rowsSkipped + 1
                    Log:trace("RLDealerSaleSelectorModel.buildSectionModel: %s dropped a row with non-numeric minAge (%s)",
                        tostring(subTypeName), tostring(type(visual) == "table" and visual.minAge or visual))
                else
                    local key = rowKey(subTypeName, visual.minAge)
                    if model.keyMeta[key] ~= nil then
                        counters.dupSkipped = counters.dupSkipped + 1
                        Log:trace("RLDealerSaleSelectorModel.buildSectionModel: %s dropped a duplicate key row (%s @%s)",
                            tostring(subTypeName), tostring(subTypeName), tostring(visual.minAge))
                    else
                        rows[#rows + 1] = {
                            subTypeName   = subTypeName,
                            minAge        = visual.minAge,
                            ageRangeLabel = visual.ageRangeLabel,
                            iconFilename  = visual.iconFilename,
                            key           = key,
                        }
                        model.keyMeta[key]         = { subTypeName = subTypeName, minAge = visual.minAge }
                        model.initialSelected[key] = visual.buyable == true
                    end
                end
            end

            if #rows == 0 then
                counters.entriesSkipped = counters.entriesSkipped + 1
                Log:trace("RLDealerSaleSelectorModel.buildSectionModel: %s yielded no keyable row; section dropped",
                    tostring(subTypeName))
            else
                model.sectionOrder[#model.sectionOrder + 1] = subTypeName
                model.itemsBySection[subTypeName]           = rows
                model.titlesBySection[subTypeName]          = titleOf(entry.subTypeLabel, subTypeName)
            end
        end
    end

    Log:debug("RLDealerSaleSelectorModel.buildSectionModel: %d section(s); %d entr(ies), %d row(s), %d dup(s) skipped",
        #model.sectionOrder, counters.entriesSkipped, counters.rowsSkipped, counters.dupSkipped)
    return model
end

-- =============================================================================
-- buildResult - checked rows -> caller-facing for-sale set
-- =============================================================================

--- Collect the checked in-scope rows into the caller's for-sale set, in section then row order,
--- deduped by key. Order and dedup both come from walking `sectionOrder` x `itemsBySection`. A
--- checked key whose meta is missing or malformed is dropped, never emitted.
---
--- May return `{}` - the caller treats an empty array as a legitimate "nothing for sale",
--- distinct from the dialog's nil for cancel.
---@param selected table {key->true} checked composite keys
---@param keyMeta table {key->{subTypeName, minAge}} from buildSectionModel
---@param sectionOrder table [key] section order from buildSectionModel
---@param itemsBySection table {key->rows} from buildSectionModel
---@return table[] result array of {subTypeName, minAge}
function RLDealerSaleSelectorModel.buildResult(selected, keyMeta, sectionOrder, itemsBySection)
    local result = {}
    if type(selected) ~= "table" or type(keyMeta) ~= "table"
        or type(sectionOrder) ~= "table" or type(itemsBySection) ~= "table" then
        Log:trace("RLDealerSaleSelectorModel.buildResult: malformed args; empty result")
        return result
    end

    local emitted = {}
    for _, sectionKey in ipairs(sectionOrder) do
        local rows = itemsBySection[sectionKey]
        if type(rows) == "table" then
            for _, row in ipairs(rows) do
                local key = row.key
                if selected[key] == true and not emitted[key] then
                    local meta = keyMeta[key]
                    if type(meta) == "table"
                        and type(meta.subTypeName) == "string" and meta.subTypeName ~= ""
                        and type(meta.minAge) == "number" then
                        emitted[key] = true
                        result[#result + 1] = { subTypeName = meta.subTypeName, minAge = meta.minAge }
                    else
                        -- Sanitize the key for logging: U+001F has no glyph in the console
                        -- texture font and would warn "Character '31' not found".
                        Log:trace("RLDealerSaleSelectorModel.buildResult: dropped checked key with malformed meta (%s)",
                            (tostring(key):gsub("\31", "|")))
                    end
                end
            end
        end
    end

    Log:debug("RLDealerSaleSelectorModel.buildResult: %d checked in-scope row(s)", #result)
    return result
end

-- =============================================================================
-- Selection transitions + predicates
-- =============================================================================

-- The DOMAIN of every transition and predicate below is `sectionOrder` x `itemsBySection` - the
-- rows the dialog actually rendered. A checked key unreachable from `sectionOrder` is therefore
-- invisible to every DECISION here: it can neither be cleared by a toggle nor pin a predicate
-- true, which is what stops a leftover key from making "is anything selected" permanently true
-- and select-all unable to fire again. The transitions still COPY the incoming map first, so
-- such a key survives the round-trip untouched - a preservation step, not a domain walk.

--- Shallow copy of a selection map, normalizing to the `true`/`nil`-never-`false` invariant.
---@param selected table {key->true}
---@return table a NEW map; the argument is never mutated
local function copySelection(selected)
    local copy = {}
    for key, value in pairs(selected) do
        if value == true then copy[key] = true end
    end
    return copy
end

--- Walk the rows reachable from `sectionOrder` x `itemsBySection`, optionally restricted to one
--- section index. `visit` returning true stops the walk. A section with a nil/non-table rows
--- entry, and a row that is not a table with a string key, are skipped rather than crashing on a
--- nil-key write.
---@param sectionOrder table [sectionKey]
---@param itemsBySection table {sectionKey->rows}
---@param visit function fn(row, sectionKey, sectionIndex) -> boolean stop
---@param onlySectionIndex number|nil restrict the walk to this sectionOrder index
---@param context string caller name, for the TRACE lines
---@return number sectionsVisited count of sections with a usable rows table
---@return boolean stopped whether `visit` stopped the walk
local function walkReachable(sectionOrder, itemsBySection, visit, onlySectionIndex, context)
    local sectionsVisited = 0
    for sectionIndex, sectionKey in ipairs(sectionOrder) do
        if onlySectionIndex == nil or sectionIndex == onlySectionIndex then
            local rows = itemsBySection[sectionKey]
            if type(rows) ~= "table" then
                Log:trace("RLDealerSaleSelectorModel.%s: section %d (%s) has a nil/non-table rows entry; skipped",
                    context, sectionIndex, tostring(sectionKey))
            else
                sectionsVisited = sectionsVisited + 1
                for rowIndex, row in ipairs(rows) do
                    if type(row) ~= "table" or type(row.key) ~= "string" then
                        Log:trace("RLDealerSaleSelectorModel.%s: section %d (%s) row %d is malformed; skipped",
                            context, sectionIndex, tostring(sectionKey), rowIndex)
                    elseif visit(row, sectionKey, sectionIndex) then
                        return sectionsVisited, true
                    end
                end
            end
        end
    end
    return sectionsVisited, false
end

--- Resolve a section INDEX to its `sectionOrder` key, or nil when there is no usable section:
--- nil, the documented `0` sentinel, a non-numeric index, or an index with no entry - the
--- reachable case being a stale out-of-range index left by a prior open.
---@param sectionOrder table [sectionKey]
---@param section any section index
---@param context string caller name, for the TRACE lines
---@return string|nil sectionKey nil when no usable section
local function resolveSectionKey(sectionOrder, section, context)
    if section == nil then
        Log:trace("RLDealerSaleSelectorModel.%s: no usable section (nil)", context)
        return nil
    end
    if type(section) ~= "number" then
        Log:trace("RLDealerSaleSelectorModel.%s: no usable section (non-numeric index, %s)", context, type(section))
        return nil
    end
    if section == 0 then
        Log:trace("RLDealerSaleSelectorModel.%s: no usable section (0 sentinel)", context)
        return nil
    end
    local sectionKey = sectionOrder[section]
    if sectionKey == nil then
        Log:trace("RLDealerSaleSelectorModel.%s: no usable section (index %s has no sectionOrder entry)",
            context, tostring(section))
        return nil
    end
    return sectionKey
end

--- True when ANY row anywhere in the rendered list is checked.
---@param selected table {key->true} the working selection
---@param sectionOrder table [sectionKey] from buildSectionModel
---@param itemsBySection table {sectionKey->rows} from buildSectionModel
---@return boolean
function RLDealerSaleSelectorModel.hasAnySelection(selected, sectionOrder, itemsBySection)
    if type(selected) ~= "table" or type(sectionOrder) ~= "table" or type(itemsBySection) ~= "table" then
        Log:trace("RLDealerSaleSelectorModel.hasAnySelection: malformed args; false")
        return false
    end
    local _, found = walkReachable(sectionOrder, itemsBySection, function(row)
        return selected[row.key] == true
    end, nil, "hasAnySelection")
    return found
end

--- True when any row in ONE section is checked. No usable section reads as false.
---@param selected table {key->true} the working selection
---@param sectionOrder table [sectionKey] from buildSectionModel
---@param itemsBySection table {sectionKey->rows} from buildSectionModel
---@param section any section index into sectionOrder
---@return boolean
function RLDealerSaleSelectorModel.hasSectionSelection(selected, sectionOrder, itemsBySection, section)
    if type(selected) ~= "table" or type(sectionOrder) ~= "table" or type(itemsBySection) ~= "table" then
        Log:trace("RLDealerSaleSelectorModel.hasSectionSelection: malformed args; false")
        return false
    end
    if resolveSectionKey(sectionOrder, section, "hasSectionSelection") == nil then
        return false
    end
    local _, found = walkReachable(sectionOrder, itemsBySection, function(row)
        return selected[row.key] == true
    end, section, "hasSectionSelection")
    return found
end

--- LIST-WIDE toggle: any row checked anywhere clears EVERY row in EVERY section, none checked
--- checks them all. Mixed state deselects first, matching the sibling select-all surfaces, and
--- focus is irrelevant - this never consults a focused section.
---@param selected table {key->true} the working selection (never mutated)
---@param sectionOrder table [sectionKey] from buildSectionModel
---@param itemsBySection table {sectionKey->rows} from buildSectionModel
---@return table newSelected a NEW map
function RLDealerSaleSelectorModel.toggleAll(selected, sectionOrder, itemsBySection)
    if type(selected) ~= "table" then
        Log:trace("RLDealerSaleSelectorModel.toggleAll: selected is not a table (%s); empty selection", type(selected))
        return {}
    end
    local result = copySelection(selected)
    if type(sectionOrder) ~= "table" or type(itemsBySection) ~= "table" then
        Log:trace("RLDealerSaleSelectorModel.toggleAll: malformed domain (sectionOrder=%s itemsBySection=%s); selection unchanged",
            type(sectionOrder), type(itemsBySection))
        return result
    end

    local clearing  = RLDealerSaleSelectorModel.hasAnySelection(selected, sectionOrder, itemsBySection)
    local newValue  = (not clearing) and true or nil
    local transitioned = 0
    local sectionsVisited = walkReachable(sectionOrder, itemsBySection, function(row)
        if result[row.key] ~= newValue then transitioned = transitioned + 1 end
        result[row.key] = newValue
        return false
    end, nil, "toggleAll")

    -- Rows TRANSITIONED, not rows now checked, plus the SECTION count: together they distinguish
    -- a true list-wide sweep from a focused-section-only regression.
    Log:debug("RLDealerSaleSelectorModel.toggleAll: %s %d row(s) across %d section(s)",
        clearing and "cleared" or "selected", transitioned, sectionsVisited)
    return result
end

--- SECTION-SCOPED toggle: any row in the focused section checked clears that section, none
--- checks it, and every other section is untouched. No usable section is a no-op returning a new
--- map equal to the input.
---@param selected table {key->true} the working selection (never mutated)
---@param sectionOrder table [sectionKey] from buildSectionModel
---@param itemsBySection table {sectionKey->rows} from buildSectionModel
---@param section any section index into sectionOrder
---@return table newSelected a NEW map
function RLDealerSaleSelectorModel.toggleSection(selected, sectionOrder, itemsBySection, section)
    if type(selected) ~= "table" then
        Log:trace("RLDealerSaleSelectorModel.toggleSection: selected is not a table (%s); empty selection", type(selected))
        return {}
    end
    local result = copySelection(selected)
    if type(sectionOrder) ~= "table" or type(itemsBySection) ~= "table" then
        Log:trace("RLDealerSaleSelectorModel.toggleSection: malformed domain (sectionOrder=%s itemsBySection=%s); selection unchanged",
            type(sectionOrder), type(itemsBySection))
        return result
    end

    local sectionKey = resolveSectionKey(sectionOrder, section, "toggleSection")
    if sectionKey == nil then
        return result
    end

    local clearing = RLDealerSaleSelectorModel.hasSectionSelection(selected, sectionOrder, itemsBySection, section)
    local newValue = (not clearing) and true or nil
    local transitioned = 0
    local sectionsVisited = walkReachable(sectionOrder, itemsBySection, function(row)
        if result[row.key] ~= newValue then transitioned = transitioned + 1 end
        result[row.key] = newValue
        return false
    end, section, "toggleSection")

    -- Report whether the section was actually WALKED: without it, a section whose rows entry is
    -- malformed logs "0 row(s)" identically to a genuinely empty one, and the trace that
    -- distinguishes them is off at the default level.
    Log:debug("RLDealerSaleSelectorModel.toggleSection: section %s (%s) -> %s %d row(s)%s",
        tostring(section), tostring(sectionKey), clearing and "cleared" or "selected", transitioned,
        sectionsVisited == 0 and " (section skipped: no usable rows table)" or "")
    return result
end

Log:debug("RLDealerSaleSelectorModel: loaded")
