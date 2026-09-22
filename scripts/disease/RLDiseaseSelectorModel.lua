-- RLDiseaseSelectorModel.lua
-- Pure, dual-run core for the disease selector dialog: turns the catalog into the flat checkbox
-- model the dialog renders, and collects the checked rows back into a result. Data in / data
-- out - no g_*, GUI, XML or engine natives. Titles are unique by construction, so rows key by
-- title and nothing is deduped.

local Log = RmLogging.getLogger("RLRM")

RLDiseaseSelectorModel = {}

--- Build the flat checkbox model from a catalog, in catalog order.
---@param catalog table|nil array of `{ title, name, typesLabel, enabled }`
---@return table model `{ rows, initialSelected = {title->true}, keyMeta = {title->{title}} }`
function RLDiseaseSelectorModel.buildModel(catalog)
    local model = { rows = {}, initialSelected = {}, keyMeta = {} }

    if type(catalog) ~= "table" then
        Log:trace("RLDiseaseSelectorModel.buildModel: catalog is not a table (%s); empty model", type(catalog))
        return model
    end

    for _, entry in ipairs(catalog) do
        if type(entry) == "table" and type(entry.title) == "string" and entry.title ~= "" then
            model.rows[#model.rows + 1] = {
                title      = entry.title,
                name       = entry.name,
                typesLabel = entry.typesLabel,
            }
            model.keyMeta[entry.title] = { title = entry.title }
            if entry.enabled == true then
                model.initialSelected[entry.title] = true
            end
        else
            Log:trace("RLDiseaseSelectorModel.buildModel: dropped a malformed catalog entry")
        end
    end

    Log:debug("RLDiseaseSelectorModel.buildModel: %d row(s)", #model.rows)
    return model
end

--- True when any rendered row is checked.
---@param selected table {title->true}
---@param model table from buildModel
---@return boolean
function RLDiseaseSelectorModel.hasAnySelection(selected, model)
    if type(selected) ~= "table" or type(model) ~= "table" or type(model.rows) ~= "table" then
        Log:trace("RLDiseaseSelectorModel.hasAnySelection: malformed args; false")
        return false
    end
    for _, row in ipairs(model.rows) do
        if selected[row.title] == true then return true end
    end
    return false
end

--- List-wide toggle: any row checked clears all, none checked checks all. Returns a NEW map.
---@param selected table {title->true} (never mutated)
---@param model table from buildModel
---@return table newSelected
function RLDiseaseSelectorModel.toggleAll(selected, model)
    local result = {}
    if type(selected) ~= "table" then
        Log:trace("RLDiseaseSelectorModel.toggleAll: selected is not a table (%s); empty selection", type(selected))
        return result
    end
    for key, value in pairs(selected) do
        if value == true then result[key] = true end
    end
    if type(model) ~= "table" or type(model.rows) ~= "table" then
        Log:trace("RLDiseaseSelectorModel.toggleAll: malformed model; selection unchanged")
        return result
    end

    local clearing = RLDiseaseSelectorModel.hasAnySelection(selected, model)
    local newValue = (not clearing) and true or nil
    for _, row in ipairs(model.rows) do
        result[row.title] = newValue
    end

    Log:debug("RLDiseaseSelectorModel.toggleAll: %s %d row(s)", clearing and "cleared" or "selected", #model.rows)
    return result
end

--- Collect the checked rows in row order. `{}` is a legal result (every title switched off).
---@param selected table {title->true}
---@param model table from buildModel
---@return table[] result array of `{ title }`
function RLDiseaseSelectorModel.buildResult(selected, model)
    local result = {}
    if type(selected) ~= "table" or type(model) ~= "table" or type(model.rows) ~= "table" then
        Log:trace("RLDiseaseSelectorModel.buildResult: malformed args; empty result")
        return result
    end
    for _, row in ipairs(model.rows) do
        if selected[row.title] == true then
            result[#result + 1] = { title = row.title }
        end
    end
    Log:debug("RLDiseaseSelectorModel.buildResult: %d checked row(s) of %d", #result, #model.rows)
    return result
end

Log:debug("RLDiseaseSelectorModel: loaded")
