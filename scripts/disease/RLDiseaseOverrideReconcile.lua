-- RLDiseaseOverrideReconcile.lua
-- Turns a selector result into the minimal op list: one op per rendered row whose checked state
-- differs from its current `enabled`. `{ title, enabled = false }` switches a title off;
-- `{ title, enabled = true }` switches it back on (the default, so the override is cleared).
-- Only catalog rows are diffed. A nil result emits nothing, while `{}` switches every rendered
-- title off. Data in, data out.

local Log = RmLogging.getLogger("RLRM")

RLDiseaseOverrideReconcile = {}

--- Diff a selector result against the catalog it was opened over.
---@param result table|nil array of `{ title }` (checked rows); nil emits no ops
---@param catalog table|nil array of `{ title, enabled }`
---@return table[] ops array of `{ title, enabled }`
function RLDiseaseOverrideReconcile.diff(result, catalog)
    local ops = {}

    if type(result) ~= "table" then
        Log:trace("RLDiseaseOverrideReconcile.diff: result is not a table (%s); no ops", type(result))
        return ops
    end
    if type(catalog) ~= "table" then
        Log:warning("RLDiseaseOverrideReconcile.diff: catalog is not a table (%s); no ops", type(catalog))
        return ops
    end

    local wanted = {}
    for _, entry in ipairs(result) do
        if type(entry) == "table" and type(entry.title) == "string" then
            wanted[entry.title] = true
        end
    end

    local unchanged = 0
    for _, row in ipairs(catalog) do
        if type(row) == "table" and type(row.title) == "string" then
            local desired = wanted[row.title] == true
            if desired == (row.enabled == true) then
                unchanged = unchanged + 1
            else
                ops[#ops + 1] = { title = row.title, enabled = desired }
                Log:trace("RLDiseaseOverrideReconcile.diff: %s -> enabled=%s", row.title, tostring(desired))
            end
        else
            Log:trace("RLDiseaseOverrideReconcile.diff: skipped a malformed catalog row")
        end
    end

    Log:debug("RLDiseaseOverrideReconcile.diff: %d op(s) from %d catalog row(s); %d unchanged",
        #ops, #catalog, unchanged)
    return ops
end

Log:debug("RLDiseaseOverrideReconcile: loaded")
