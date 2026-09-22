-- RLDiseaseOverrideSerialization.lua
-- XML codec for the per-title disease overrides, plus the shared g_rlDiseaseOverrideRegistry
-- singleton bootstrap.
--
--   rm_RlSettings.diseaseOverrides.disease(i)
--     @title(string)    -- verbatim disease title; an unknown title is kept
--     @enabled(bool)    -- the override value
--     @version(int)     -- migration seam (writes/reads 1)
--
-- Both seams take an ALREADY-OPEN XMLFile; the disk transport lives in the RLSettings wrappers.
-- FAIL-CLOSED on read: @enabled is tested for PRESENCE, so a stored `false` round-trips and
-- only an absent or garbage attribute skips the record.

local Log = RmLogging.getLogger("RLRM")

RLDiseaseOverrideSerialization = {}

--- Sub-tree root under RLSettings' save root, shared by both seams and the wrappers.
RLDiseaseOverrideSerialization.XML_BASE_KEY = "rm_RlSettings.diseaseOverrides"

--- On-disk record schema version.
local RECORD_VERSION = 1

-- =============================================================================
-- Per-record IO (file-local)
-- =============================================================================

--- Write one override record at `recordKey`.
---@param xmlFile table XMLFile handle
---@param recordKey string path prefix for this record
---@param record table `{ title=string, enabled=boolean }`
local function writeRecord(xmlFile, recordKey, record)
    xmlFile:setString(recordKey .. "#title", record.title)
    xmlFile:setBool(recordKey .. "#enabled", record.enabled)
    xmlFile:setInt(recordKey .. "#version", RECORD_VERSION)
    Log:trace("RLDiseaseOverrideSerialization.writeRecord: %s title=%s enabled=%s version=%d",
        recordKey, tostring(record.title), tostring(record.enabled), RECORD_VERSION)
end

--- Read one override record, or nil plus a warning when it is corrupt.
---@param xmlFile table XMLFile handle
---@param recordKey string path prefix for this record
---@return table|nil record `{ title=, enabled= }`, or nil when corrupt
local function readRecord(xmlFile, recordKey)
    local title = xmlFile:getString(recordKey .. "#title")
    local enabled = xmlFile:getBool(recordKey .. "#enabled")
    local version = xmlFile:getInt(recordKey .. "#version", 1)

    if title == nil or title:gsub("%s", "") == "" then
        Log:warning("RLDiseaseOverrideSerialization.readRecord: record at %s has no title (title=%s); skipping",
            tostring(recordKey), tostring(title))
        return nil
    end

    if enabled == nil then
        Log:warning("RLDiseaseOverrideSerialization.readRecord: record at %s (title=%s) has no valid enabled; skipping",
            tostring(recordKey), tostring(title))
        return nil
    end

    Log:trace("RLDiseaseOverrideSerialization.readRecord: %s title=%s enabled=%s version=%s",
        recordKey, title, tostring(enabled), tostring(version))
    return { title = title, enabled = enabled }
end

-- =============================================================================
-- Iteration wrappers (public seams)
-- =============================================================================

--- Serialize every override under `baseKey` in `registry:enumerate()` order.
---@param xmlFile table XMLFile handle (already open)
---@param baseKey string e.g. `RLDiseaseOverrideSerialization.XML_BASE_KEY`
---@param registry table an RLDiseaseOverrideRegistry instance
function RLDiseaseOverrideSerialization.saveToXMLFile(xmlFile, baseKey, registry)
    if xmlFile == nil then
        Log:warning("RLDiseaseOverrideSerialization.saveToXMLFile: nil xmlFile; skipping")
        return
    end
    if registry == nil then
        Log:warning("RLDiseaseOverrideSerialization.saveToXMLFile: nil registry; skipping")
        return
    end

    local records = registry:enumerate()
    for i, record in ipairs(records) do
        writeRecord(xmlFile, string.format("%s.disease(%d)", baseKey, i - 1), record)
    end

    Log:debug("RLDiseaseOverrideSerialization.saveToXMLFile: baseKey=%s wrote=%d override(s)", baseKey, #records)
end

--- Additively load every override under `baseKey` into a caller-reconstructed registry.
---@param xmlFile table XMLFile handle (already open)
---@param baseKey string e.g. `RLDiseaseOverrideSerialization.XML_BASE_KEY`
---@param registry table an RLDiseaseOverrideRegistry instance
---@return number loaded records the registry accepted
function RLDiseaseOverrideSerialization.loadFromXMLFile(xmlFile, baseKey, registry)
    if xmlFile == nil then
        Log:warning("RLDiseaseOverrideSerialization.loadFromXMLFile: nil xmlFile; skipping")
        return 0
    end
    if registry == nil then
        Log:warning("RLDiseaseOverrideSerialization.loadFromXMLFile: nil registry; skipping")
        return 0
    end

    local loaded = 0
    local ok, err = pcall(function()
        xmlFile:iterate(baseKey .. ".disease", function(_, recordKey)
            local rec = readRecord(xmlFile, recordKey)
            if rec ~= nil and registry:set(rec.title, rec.enabled) then
                loaded = loaded + 1
            end
        end)
    end)

    if not ok then
        Log:warning("RLDiseaseOverrideSerialization.loadFromXMLFile: iterate errored after %d loaded; partial state kept (%s)",
            loaded, tostring(err))
    end

    Log:debug("RLDiseaseOverrideSerialization.loadFromXMLFile: baseKey=%s loaded=%d override(s)", baseKey, loaded)
    return loaded
end

-- =============================================================================
-- Shared singleton bootstrap
-- =============================================================================

-- The `or` guard keeps a re-source from clobbering a live instance; the loader reconstructs it.
g_rlDiseaseOverrideRegistry = g_rlDiseaseOverrideRegistry or RLDiseaseOverrideRegistry.new()

Log:trace("RLDiseaseOverrideSerialization: loaded")
