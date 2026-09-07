-- RLDealerSaleSerialization.lua
-- Flat XML codec for dealer sale-availability overrides, plus the shared
-- g_rlDealerSaleRegistry singleton bootstrap.
--
-- Canonical XML key contract (under RLDealerSaleSerialization.XML_BASE_KEY =
-- "rm_RlSettings.dealerSaleOverrides"):
--
--   rm_RlSettings.dealerSaleOverrides.override(i)
--     @subType(string)    -- verbatim subType.name, used as-is (no name<->index step)
--     @minAge(int)        -- >= 0
--     @canBeBought(bool)  -- either polarity is a valid override
--     @version(int)       -- migration seam (writes/reads 1)
--
-- A flat scalar record, so none of the nested-group machinery the sibling codecs carry. Since
-- the state holder is the pure registry, which owns no XML, the iteration wrappers live here.
--
-- Both seams take an ALREADY-OPEN XMLFile and encode/decode in memory - the disk transport
-- lives only in the RLSettings wrappers, because an in-game disk round-trip inside a codec
-- fails silently under the engine's sandbox.
--
-- FAIL-CLOSED on read: required attributes are read with NO default, so a nil read is
-- corruption. @canBeBought is tested for PRESENCE, not truthiness, so a stored `false`
-- round-trips and only a genuinely absent attribute counts as corrupt.

local Log = RmLogging.getLogger("RLRM")

RLDealerSaleSerialization = {}

--- Sub-tree root under RLSettings' save root, shared by both seams and the wrappers.
RLDealerSaleSerialization.XML_BASE_KEY = "rm_RlSettings.dealerSaleOverrides"

--- On-disk record schema version.
local RECORD_VERSION = 1

-- =============================================================================
-- Per-record IO (file-local)
-- =============================================================================

--- Write one override record at `overrideKey`. Every field is a validated scalar - the caller
--- only ever passes `registry:enumerate()` records - so there is no fail-closed branch here.
---@param xmlFile table XMLFile handle
---@param overrideKey string path prefix for this record, e.g. `"...dealerSaleOverrides.override(0)"`
---@param record table `{ subTypeName=string, minAge=integer, canBeBought=boolean }`
local function writeOverride(xmlFile, overrideKey, record)
    xmlFile:setString(overrideKey .. "#subType", record.subTypeName)
    xmlFile:setInt(overrideKey .. "#minAge", record.minAge)
    xmlFile:setBool(overrideKey .. "#canBeBought", record.canBeBought)
    xmlFile:setInt(overrideKey .. "#version", RECORD_VERSION)
    Log:trace("RLDealerSaleSerialization.writeOverride: %s subType=%s minAge=%d canBeBought=%s version=%d",
        overrideKey, tostring(record.subTypeName), record.minAge, tostring(record.canBeBought), RECORD_VERSION)
end

--- Read one override record, or nil plus a warning when the record is corrupt - see the
--- fail-closed rule in the file header. @version is the sole defaulted attribute and is read
--- for diagnostics and forward compatibility, not returned.
---@param xmlFile table XMLFile handle
---@param overrideKey string path prefix for this record
---@return table|nil record `{ subTypeName=, minAge=, canBeBought= }`, or nil when corrupt
local function readOverride(xmlFile, overrideKey)
    local subType = xmlFile:getString(overrideKey .. "#subType")
    local minAge = xmlFile:getInt(overrideKey .. "#minAge")
    local canBeBought = xmlFile:getBool(overrideKey .. "#canBeBought")  -- NO default: nil => corrupt, not false
    local version = xmlFile:getInt(overrideKey .. "#version", 1)         -- tolerated-absent -> v1 (migration seam)

    if subType == nil or subType:gsub("%s", "") == "" or minAge == nil or canBeBought == nil then
        Log:warning("RLDealerSaleSerialization.readOverride: incomplete record at %s (subType=%s minAge=%s canBeBought=%s); skipping",
            tostring(overrideKey), tostring(subType), tostring(minAge), tostring(canBeBought))
        return nil
    end

    Log:trace("RLDealerSaleSerialization.readOverride: %s subType=%s minAge=%d canBeBought=%s version=%d",
        overrideKey, subType, minAge, tostring(canBeBought), version)
    return { subTypeName = subType, minAge = minAge, canBeBought = canBeBought }
end

-- =============================================================================
-- Iteration wrappers (public seams)
-- =============================================================================

--- Serialize every override under `baseKey` in `registry:enumerate()` order, already sorted,
--- so the indexed keys are deterministic across save cycles.
---@param xmlFile table XMLFile handle (already open)
---@param baseKey string e.g. `RLDealerSaleSerialization.XML_BASE_KEY`
---@param registry table an RLDealerSaleRegistry instance
function RLDealerSaleSerialization.saveToXMLFile(xmlFile, baseKey, registry)
    if xmlFile == nil then
        Log:warning("RLDealerSaleSerialization.saveToXMLFile: nil xmlFile; skipping")
        return
    end
    if registry == nil then
        Log:warning("RLDealerSaleSerialization.saveToXMLFile: nil registry; skipping")
        return
    end

    local records = registry:enumerate()
    for i, record in ipairs(records) do
        writeOverride(xmlFile, string.format("%s.override(%d)", baseKey, i - 1), record)
    end

    Log:debug("RLDealerSaleSerialization.saveToXMLFile: baseKey=%s wrote=%d overrides", baseKey, #records)
end

--- Deserialize every override under `baseKey` into `registry`. ADDITIVE, set-only: the caller
--- reconstructs the singleton first. A corrupt or invalid record is skipped with a warning
--- and never aborts the loop, and a duplicate key upserts last-write-wins, so `loaded` can
--- exceed the deduped count on a hand-corrupted file.
---@param xmlFile table XMLFile handle (already open)
---@param baseKey string e.g. `RLDealerSaleSerialization.XML_BASE_KEY`
---@param registry table an RLDealerSaleRegistry instance (freshly reconstructed by the caller)
function RLDealerSaleSerialization.loadFromXMLFile(xmlFile, baseKey, registry)
    if xmlFile == nil then
        Log:warning("RLDealerSaleSerialization.loadFromXMLFile: nil xmlFile; skipping")
        return
    end
    if registry == nil then
        Log:warning("RLDealerSaleSerialization.loadFromXMLFile: nil registry; skipping")
        return
    end

    local loaded = 0
    local ok, err = pcall(function()
        xmlFile:iterate(baseKey .. ".override", function(_, overrideKey)
            local rec = readOverride(xmlFile, overrideKey)  -- expected corruption -> nil, no throw
            if rec ~= nil and registry:set(rec.subTypeName, rec.minAge, rec.canBeBought) then
                loaded = loaded + 1
            end
        end)
    end)

    if not ok then
        Log:warning("RLDealerSaleSerialization.loadFromXMLFile: iterate errored after %d loaded; partial state kept (%s)",
            loaded, tostring(err))
    end

    Log:debug("RLDealerSaleSerialization.loadFromXMLFile: baseKey=%s loaded=%d overrides", baseKey, loaded)
end

-- =============================================================================
-- Shared singleton bootstrap
-- =============================================================================

-- Eager create, mirroring g_rlFilterService / g_rlHerdsmanRuleService. The g_* write belongs
-- to the persistence layer rather than the pure registry, and the `or` guard keeps a re-source
-- from clobbering a live instance.
g_rlDealerSaleRegistry = g_rlDealerSaleRegistry or RLDealerSaleRegistry.new()

Log:trace("RLDealerSaleSerialization: loaded")
