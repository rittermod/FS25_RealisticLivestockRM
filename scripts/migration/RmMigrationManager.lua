--[[
    RmMigrationManager.lua
    Migration from FS25_RealisticLivestock to FS25_RealisticLivestockRM: detect the old mod,
    detect whether migration is needed, and prompt.

    The migration itself is non-destructive and happens through dual-read in the loading
    code - each loader tries the rm_-prefixed filename first and falls back to the old one.
    The game then saves under the new names only, which completes the migration, so a user
    can revert to the old mod before saving without losing data.

    No state file: FS25 replaces the whole savegame folder on save and keeps only what the
    save callback wrote, so detection asks whether the new files exist.
]]

local Log = RmLogging.getLogger("RLRM")

RmMigrationManager = {}

local RmMigrationManager_mt = Class(RmMigrationManager)

-- Legacy mod name, for the in-file items.xml / handTools.xml old-data detection.
local LEGACY_MOD_NAME = "FS25_RealisticLivestock"

-- Known-incompatible mods, partitioned by :checkModCompatibility() into blockingMods
-- (doRestart) and warningMods (dismissible InfoDialog). A block entry shares one message
-- body so its reasonKey is nil; a warn entry needs a per-mod reasonKey.
RmMigrationManager.KNOWN_INCOMPATIBLE_MODS = {
    { name = "FS25_RealisticLivestock",     severity = "block", reasonKey = nil },
    { name = "FS25_MoreVisualAnimals",      severity = "block", reasonKey = nil },
    { name = "FS25_EnhancedLivestock",      severity = "block", reasonKey = nil },
    { name = "FS25_EnhancedAnimalSystem",   severity = "block", reasonKey = nil },
    { name = "FS25_AnimalFoodCalculator",   severity = "block", reasonKey = nil },
}

g_rmMigrationManager = nil

-- Pending dialog flags (set during checkModCompatibility, consumed by the startup
-- dialog queue in RealisticLivestock_FSBaseMission:onStartMission).
g_rmPendingMigration = false
g_rmMigrationConflict = false
g_rmPendingModWarning = false


function RmMigrationManager.new()
    local self = setmetatable({}, RmMigrationManager_mt)
    self.savegameDir = nil
    return self
end

function RmMigrationManager:initialize(overrideSavegameDir)
    -- Allow override of savegame directory (used for early migration before g_currentMission is ready)
    if overrideSavegameDir ~= nil then
        self.savegameDir = overrideSavegameDir
        return true
    end

    if g_currentMission == nil or g_currentMission.missionInfo == nil then
        return false
    end

    self.savegameDir = g_currentMission.missionInfo.savegameDirectory
    if self.savegameDir == nil then
        return false
    end

    return true
end

-- Set the savegame directory directly (for early migration)
function RmMigrationManager:setSavegameDir(savegameDir)
    self.savegameDir = savegameDir
end

--[[
    Check known-incompatible mods loaded on this peer and partition into
    blocking (severity="block") and warning (severity="warn") buckets.

    Sets self.blockingMods + self.warningMods (arrays of registry entries) and
    unconditionally re-assigns the global flags from the partition counts so
    they reset on every check (no stale flags between mission loads).

    Detection is peer-agnostic: g_modIsLoaded is authoritative per peer, so
    every peer (server, listen-server host, pure client, dediserver) runs this
    against its own modset. FS25 enforces identical mod sets in MP, so each
    peer effectively sees the same partition.

    Log levels per docs/conventions/logging-levels.md:
    - Per-warn: WARNING (advisory; not fatal but the user should know)
    - Block summary: ERROR (save-data/MP-corruption hazard; dediserver has no
      dialog surface so the log line is the admin-visible signal)
    - Final summary: INFO (informational trace that the check ran, regardless of state)
]]
function RmMigrationManager:checkModCompatibility()
    Log:info("Checking mod compatibility...")

    self.blockingMods = {}
    self.warningMods = {}

    if g_modIsLoaded == nil then
        Log:warning("g_modIsLoaded is nil!")
        g_rmMigrationConflict = false
        g_rmPendingModWarning = false
        Log:info("Mod compatibility check: 0 blocker(s), 0 warning(s)")
        return false
    end

    for _, entry in ipairs(RmMigrationManager.KNOWN_INCOMPATIBLE_MODS) do
        if g_modIsLoaded[entry.name] == true then
            if entry.severity == "block" then
                table.insert(self.blockingMods, entry)
                Log:debug("  block-tier match: %s", entry.name)
            elseif entry.severity == "warn" then
                table.insert(self.warningMods, entry)
                -- Fall back to entry.name on a nil or unresolved reasonKey: getText returns
                -- a "Missing 'KEY'" placeholder that would otherwise render as visible text.
                local reasonText = entry.name
                if entry.reasonKey ~= nil and g_i18n:hasText(entry.reasonKey) then
                    reasonText = g_i18n:getText(entry.reasonKey)
                end
                Log:warning("Mod warning: %s - %s", entry.name, reasonText)
            else
                Log:warning("Unknown severity '%s' for mod '%s' in KNOWN_INCOMPATIBLE_MODS",
                    tostring(entry.severity), entry.name)
            end
        end
    end

    if #self.blockingMods > 0 then
        local names = {}
        for _, e in ipairs(self.blockingMods) do table.insert(names, e.name) end
        -- A dedicated server has no dialog surface, so this line is the only admin-visible
        -- signal that a hard-conflict mod is present.
        Log:error("Conflicting mods found: %s", table.concat(names, ", "))
    end

    g_rmMigrationConflict = #self.blockingMods > 0
    g_rmPendingModWarning = #self.warningMods > 0

    Log:info("Mod compatibility check: %d blocker(s), %d warning(s)",
        #self.blockingMods, #self.warningMods)

    return g_rmMigrationConflict or g_rmPendingModWarning
end

--[[
    Show conflict dialog listing ALL blocking-tier mods and force a restart.

    The optional callback parameter exists for queue symmetry only (so the
    startup-dialog queue can pass `showNext` in for every kind uniformly) -
    it is intentionally never invoked from this path because the dialog's OK
    handler calls doRestart(false, "") which ends the Lua state. The queue is
    abandoned at that point.

    Uses a short timer delay so the dialog overlays on the gameplay screen
    rather than getting lost during the loading->gameplay transition.

    @param callback function|nil Unused on the conflict path; doRestart wins.
]]
function RmMigrationManager:showConflictDialog(callback)
    Log:info("Scheduling conflict dialog...")

    -- Skip rather than present an empty mod list, which would mislead.
    if self.blockingMods == nil or #self.blockingMods == 0 then
        Log:warning("showConflictDialog called with no blockingMods; skipping dialog")
        return
    end

    Timer.createOneshot(100, function()
        -- Mid-startup unload guard: the chain is abandoned rather than continued, since
        -- doRestart could not fire anyway with no dialog to acknowledge.
        if g_currentMission == nil or g_gui == nil then
            Log:debug("showConflictDialog timer fired post-unload; skipping")
            return
        end
        Log:info("Showing conflict dialog")

        local title = g_i18n:getText("rm_rl_conflict_title")
        local modList = ""
        for _, entry in ipairs(self.blockingMods) do
            modList = modList .. "\n- " .. entry.name
        end
        local message = string.format(g_i18n:getText("rm_rl_mod_conflict_message"), modList)

        InfoDialog.show(title .. "\n\n" .. message, function()
            Log:info("User acknowledged conflict, restarting game")
            -- Restart the game so user can disable the conflicting mod(s).
            -- callback is intentionally NOT invoked here - doRestart ends the chain.
            doRestart(false, "")
        end, self)
    end)
end

--[[
    Show warning dialog listing all warn-tier mods detected on this peer.

    Non-blocking: the user dismisses with OK and gameplay continues. The
    callback (typically the queue's `showNext`) fires after dismissal so the
    next startup dialog can present.

    Caller is responsible for guarding against headless dedicated servers
    (where InfoDialog cannot render) - see RealisticLivestock_FSBaseMission's
    queue builder, which suppresses warn-kind enqueue when g_dedicatedServer
    is set.

    @param callback function|nil Invoked after the user dismisses the dialog.
]]
function RmMigrationManager:showWarningDialog(callback)
    Log:info("Scheduling warning dialog...")

    -- Defensive: if there's nothing to warn about, advance the queue immediately
    -- rather than rendering an empty-bullet dialog with title + URL but no entries.
    if self.warningMods == nil or #self.warningMods == 0 then
        Log:warning("showWarningDialog called with no warningMods; skipping dialog")
        if callback ~= nil then callback() end
        return
    end

    Timer.createOneshot(100, function()
        -- Mid-startup unload guard: advance the queue from the timer so it is not stalled.
        if g_currentMission == nil or g_gui == nil then
            Log:debug("showWarningDialog timer fired post-unload; skipping dialog")
            if callback ~= nil then callback() end
            return
        end
        Log:info("Showing warning dialog (%d warning(s))", #self.warningMods)

        -- getText on a missing key returns a "Missing 'KEY'" placeholder that would leak
        -- into the UI, so route through hasText first.
        local title = g_i18n:hasText("rl_mod_warn_title")
            and g_i18n:getText("rl_mod_warn_title")
            or "Mod Compatibility Warning"
        local urlLine = g_i18n:hasText("rl_mod_compat_url")
            and g_i18n:getText("rl_mod_compat_url")
            or "https://rittermod.github.io/FS25_RealisticLivestockRM/user-guide/reference-mod-compatibility"

        -- Same fallback contract as checkModCompatibility.
        local bullets = ""
        for _, entry in ipairs(self.warningMods) do
            local reasonText = entry.name
            if entry.reasonKey ~= nil and g_i18n:hasText(entry.reasonKey) then
                reasonText = g_i18n:getText(entry.reasonKey)
            end
            bullets = bullets .. "\n- " .. reasonText
            Log:debug("  warn entry presented: %s -> reasonKey=%s",
                entry.name, tostring(entry.reasonKey))
        end

        -- rl_mod_warn_message expects exactly two %s. A community translator dropping one
        -- would crash string.format and abort the dispatch chain, so it runs under pcall
        -- with a plain-concatenation fallback.
        local fmtTemplate = g_i18n:hasText("rl_mod_warn_message")
            and g_i18n:getText("rl_mod_warn_message")
            or "The following mod(s) loaded with Realistic Livestock RM may cause issues:%s\n\nSee %s for details. The game will continue."
        local ok, body = pcall(string.format, fmtTemplate, bullets, urlLine)
        if not ok then
            Log:warning("rl_mod_warn_message format failed (translator dropped a %%s placeholder?): %s; falling back to plain concatenation",
                tostring(body))
            body = "The following mod(s) loaded with Realistic Livestock RM may cause issues:"
                .. bullets .. "\n\nSee " .. urlLine .. " for details. The game will continue."
        end

        InfoDialog.show(title .. "\n\n" .. body, function()
            Log:info("User dismissed warning dialog")
            if callback ~= nil then callback() end
        end, self)
    end)
end

--[[
    Check if migration is needed
    Returns true if:
    - Old data files exist AND
    - New data files don't exist
]]
function RmMigrationManager:shouldMigrate()
    if not self:initialize() then
        return false
    end

    -- Check for old data
    local hasOldSettings = fileExists(self.savegameDir .. "/rlSettings.xml")
    local hasOldAnimalSystem = fileExists(self.savegameDir .. "/animalSystem.xml")
    local hasOld = hasOldSettings or hasOldAnimalSystem

    if not hasOld then
        return false
    end

    -- Check for new data (if exists, no migration needed - user already saved with new mod)
    local hasNewSettings = fileExists(self.savegameDir .. "/rm_RlSettings.xml")
    if hasNewSettings then
        return false
    end

    return true
end

--[[
    Get list of old data files that exist
    Returns table with file info for display in migration dialog
]]
function RmMigrationManager:getOldDataFiles()
    if not self:initialize() then
        return {}
    end

    local files = {}

    if fileExists(self.savegameDir .. "/rlSettings.xml") then
        table.insert(files, { name = "rlSettings.xml", type = "Settings" })
    end

    if fileExists(self.savegameDir .. "/animalSystem.xml") then
        table.insert(files, { name = "animalSystem.xml", type = "Animal System" })
    end

    -- Check for Dewar items in items.xml (modName=LEGACY_MOD_NAME)
    if self:hasOldItemsData() then
        table.insert(files, { name = "items.xml", type = "Dewars" })
    end

    -- Check for AI Straw hand tools in handTools.xml (filename contains $moddir$<legacy>/)
    if self:hasOldHandToolsData() then
        table.insert(files, { name = "handTools.xml", type = "AI Straw Hand Tools" })
    end

    -- Check for HandToolAIStraw namespace data in items.xml (legacy namespace migration)
    local itemsPath = self.savegameDir .. "/items.xml"
    if fileExists(itemsPath) then
        local itemsXml = XMLFile.loadIfExists("items", itemsPath)
        if itemsXml ~= nil then
            local hasOldNamespace = false
            itemsXml:iterate("items.item", function(_, key)
                local oldKey = key .. ".FS25_RealisticLivestock.aiStraw"
                if itemsXml:hasProperty(oldKey) then
                    hasOldNamespace = true
                    return false -- Stop iteration
                end
            end)
            itemsXml:delete()

            if hasOldNamespace then
                table.insert(files, { name = "items.xml (namespace)", type = "AI Straw Data" })
            end
        end
    end

    return files
end

--[[
    Check if items.xml has old mod references (className/modName)
    This is different from namespace migration - this is about the item registration itself
]]
function RmMigrationManager:hasOldItemsData()
    if not self:initialize() then
        return false
    end

    local itemsPath = self.savegameDir .. "/items.xml"
    if not fileExists(itemsPath) then
        return false
    end

    local xmlFile = XMLFile.loadIfExists("items_check", itemsPath)
    if xmlFile == nil then
        return false
    end

    local hasOldData = false
    xmlFile:iterate("items.item", function(_, key)
        local modName = xmlFile:getString(key .. "#modName")
        if modName == LEGACY_MOD_NAME then
            hasOldData = true
            return false -- Stop iteration
        end
    end)

    xmlFile:delete()
    return hasOldData
end

--[[
    Check if handTools.xml has old mod references in filename attribute
    Note: Hand tools don't have a modName attribute, they use filename with $moddir$ModName/ path
]]
function RmMigrationManager:hasOldHandToolsData()
    if not self:initialize() then
        return false
    end

    local handToolsPath = self.savegameDir .. "/handTools.xml"
    if not fileExists(handToolsPath) then
        return false
    end

    local xmlFile = XMLFile.loadIfExists("handTools_check", handToolsPath)
    if xmlFile == nil then
        return false
    end

    local hasOldData = false
    local oldModPath = "$moddir$" .. LEGACY_MOD_NAME .. "/"

    xmlFile:iterate("handTools.handTool", function(_, key)
        local filename = xmlFile:getString(key .. "#filename")
        if filename ~= nil and string.find(filename, oldModPath, 1, true) then
            hasOldData = true
            return false -- Stop iteration
        end
    end)

    xmlFile:delete()
    return hasOldData
end

--[[
    Show migration dialog to user.
    Uses a short timer delay for consistency with showConflictDialog.

    @param callback function|nil Forwarded to RmMigrationDialog.show as the
        Continue-path callback so the startup-dialog queue can chain. The Quit
        path inside RmMigrationDialog calls doRestart and short-circuits the
        queue; the callback is not invoked in that case.
]]
function RmMigrationManager:showMigrationDialog(callback)
    Log:info("Scheduling migration dialog...")

    Timer.createOneshot(100, function()
        -- Mid-startup unload guard:
        -- if the user backed out during the 100ms window, advance the queue
        -- (callback is the queue's showNext). The next showNext will hit its
        -- own teardown guard if needed.
        if g_currentMission == nil or g_gui == nil then
            Log:debug("showMigrationDialog timer fired post-unload; skipping dialog")
            if callback ~= nil then callback() end
            return
        end
        Log:info("Showing migration dialog")

        if RmMigrationDialog ~= nil and RmMigrationDialog.show ~= nil then
            local files = self:getOldDataFiles()
            RmMigrationDialog.show(files, callback)
        else
            Log:error("RmMigrationDialog not available")
            if callback ~= nil then callback() end
        end
    end)
end
