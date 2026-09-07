--[[
    RLModBridge.lua
    Mod-compat bridge: lets RLRM coexist with a foreign mod that overlaps the same hooks.

    Two-phase install. The module-load phase sources every shim unconditionally on the
    server, because a shim's hooks must be installed before SpecializationUtil captures
    function references, and g_modIsLoaded is not yet populated for mods that load
    alphabetically after RLRM. The deferred phase, on Mission00.loadMission00Finished,
    checks g_modIsLoaded and calls each shim's lateInstall now that the foreign class
    tables exist.
]]

RLModBridge = {}

local Log = RmLogging.getLogger("RLRM")
local modDirectory = g_currentModDirectory

--- Registry of compat shims. Each entry is
--- `{ modName, shimPath, shimGlobal, name }`; the deferred phase looks up
--- `_G[shimGlobal].lateInstall(bridge)`.
RLModBridge.SUPPORTED_MODS = {
    {
        modName = "FS25_SeasonalWoolProduction",
        shimPath = "mod_support/FS25_SeasonalWoolProduction/FS25_SeasonalWoolProduction.lua",
        shimGlobal = "ShimWoolCompat",
        name = "Seasonal Wool Production"
    }
}

RLModBridge.activeShims = {}
RLModBridge.shimErrors = {}
RLModBridge.originalRefs = {}
RLModBridge._sourced = false
RLModBridge._deferredRan = false

--- Server-context check, an overridable seam so a test can swap it without touching g_server.
--- @return boolean true if this process is acting as a server
function RLModBridge.isServer()
    return g_server ~= nil
end

--- Indirect handle on the global `source`, so a test can swap it without mutating the global.
RLModBridge._sourceLoader = source

--- Source-load every shim file once; later calls are no-ops. Server-only.
function RLModBridge.runModuleLoadPhase()
    if RLModBridge._sourced then
        Log:trace("RLModBridge: runModuleLoadPhase already ran, skipping")
        return
    end
    RLModBridge._sourced = true

    if not RLModBridge.isServer() then
        Log:info("RLModBridge: client context, skipping shim source-load")
        return
    end

    for _, entry in ipairs(RLModBridge.SUPPORTED_MODS) do
        local ctx = "RLModBridge.source:" .. entry.modName
        local ok = RmSafeUtils.safeCall(ctx, function()
            RLModBridge._sourceLoader(modDirectory .. entry.shimPath)
        end)
        if not ok then
            RLModBridge.shimErrors[entry.modName] = "source-load failed"
            Log:warning("RLModBridge: source-load failed for %s (%s); other shims unaffected",
                entry.name, entry.modName)
        else
            Log:debug("RLModBridge: sourced shim %s", entry.modName)
        end
    end
end

--- State-population and late-binding-patch phase, from Mission00.loadMission00Finished.
--- Idempotent, and server-only at the first line so client bookkeeping stays empty.
function RLModBridge.runDeferredPhase()
    if not g_currentMission:getIsServer() then return end

    if RLModBridge._deferredRan then
        Log:trace("RLModBridge: runDeferredPhase already ran, skipping")
        return
    end
    RLModBridge._deferredRan = true

    for _, entry in ipairs(RLModBridge.SUPPORTED_MODS) do
        if not g_modIsLoaded[entry.modName] then
            Log:info("RLModBridge: skipped %s (mod not loaded)", entry.modName)
        else
            local shim = _G[entry.shimGlobal]
            if shim == nil or type(shim.lateInstall) ~= "function" then
                RLModBridge.shimErrors[entry.modName] = "shim global or lateInstall missing"
                Log:warning("RLModBridge: shim %s (%s) has no lateInstall; activeShims left nil",
                    entry.shimGlobal, entry.modName)
            else
                local ctx = "RLModBridge.lateInstall:" .. entry.modName
                local ok = RmSafeUtils.safeCall(ctx, function()
                    shim.lateInstall(RLModBridge)
                end)
                if not ok then
                    RLModBridge.shimErrors[entry.modName] = "lateInstall threw"
                    Log:warning("RLModBridge: lateInstall threw for %s; check error log above",
                        entry.modName)
                end
            end
        end
    end
end

--- Restore the originals a shim's lateInstall saved. Idempotent.
--- @param modName string e.g. "FS25_SeasonalWoolProduction"
function RLModBridge.restoreOriginals(modName)
    local refs = RLModBridge.originalRefs[modName]
    if refs == nil then return end
    local restoreMap = refs._restoreMap
    if restoreMap ~= nil then
        for fieldName, location in pairs(restoreMap) do
            local saved = refs[fieldName]
            if location.table ~= nil and saved ~= nil then
                location.table[location.key] = saved
            end
        end
    end
    RLModBridge.originalRefs[modName] = nil
    RLModBridge.activeShims[modName] = nil
    Log:info("RLModBridge: restored originals for %s", modName)
end

-- ============================================================
-- Module-load + deferred-phase wiring
-- ============================================================

RLModBridge.runModuleLoadPhase()

Mission00.loadMission00Finished = Utils.appendedFunction(
    Mission00.loadMission00Finished,
    function()
        RLModBridge.runDeferredPhase()
    end
)
