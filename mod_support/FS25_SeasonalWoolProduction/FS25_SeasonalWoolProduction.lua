--[[
    FS25_SeasonalWoolProduction.lua  (RLRM compat shim)

    Makes RLRM and Seasonal Wool Production (SWP) coexist. Every game-hour it recomputes
    litersPerHour[WOOL] as a stable cluster rate and hands it to SWP's modifyWoolRate, which
    records it and zeroes litersPerHour[WOOL] so no wool spawns between shearing seasons -
    deliberately overwriting RLRM's per-animal output, since SWP's seasonal payout expects a
    rate that does not fluctuate hour to hour.

    In the deferred phase it replaces SWP's countMatureAnimals with a version walking
    clusterSystem:getClusters(), because SWP reads animalsSpec.clusterSystem.clusters as a
    field that RLRM keeps empty and would otherwise count zero sheep. Install order is
    load-bearing: the spec-registration append goes in at module load, before spec init
    captures function references, so it is the LAST line of this file.
]]

-- Source-time safe: only g_server is valid this early. Returning skips every install,
-- the spec-registration append included, which is right on a client - the wool path is
-- server-only.
if g_server == nil then return end

local Log = RmLogging.getLogger("RLRM")
local MOD_NAME = "FS25_SeasonalWoolProduction"
local SWP_NAMESPACE = "FS25_SeasonalWoolProduction"

ShimWoolCompat = {}

--- Resolve SWP's mod environment via the FS25 sandbox pattern. Each mod's
--- top-level globals live at realGlobal[modName]; we read SWP through that
--- because bare `g_seasonalWoolProduction` from inside RLRM's modEnv would
--- never see SWP's write (SWP writes to its own modEnv, not realGlobal).
--- See wiki/patterns/sandbox-global-access.md + cross-mod-overrides.md.
--- @return table|nil swp SWP's env table, or nil if SWP not loaded
local function swpEnv()
    return _G[SWP_NAMESPACE]
end

--- Whole-body safeCall wrapper around the chained updateInputAndOutput
--- overwrite. Runs every game-hour for every pen with the pallets spec.
--- Calls superFunc first (so RLRM's own bookkeeping runs), then overwrites
--- spec.litersPerHour[WOOL] with a stable cluster rate before invoking
--- SWP's modifyWoolRate. Pre-checks fillType, foreign global, and foreign
--- method to avoid noisy work on chicken/cow pallet pens and to no-op
--- cleanly under API drift.
--- @param self      table  the placeable (pallets spec)
--- @param superFunc function the next overwrite in the spec chain
--- @param animals   table  list of animals in the pen
function ShimWoolCompat.overwriteBody(self, superFunc, animals)
    RmSafeUtils.safeCall("ShimWoolCompat.overwriteBody", function()
        superFunc(self, animals)

        local spec = self.spec_husbandryPallets
        if spec == nil or spec.litersPerHour == nil then return end

        local wool = g_fillTypeManager:getFillTypeIndexByName("WOOL")
        if wool == nil or spec.litersPerHour[wool] == nil then
            -- Non-sheep pallet pen (chicken eggs, cow leather, etc.). Drop
            -- through to avoid noisy modifyWoolRate calls + TRACE noise.
            return
        end

        local swp = swpEnv()
        if swp == nil
        or swp.g_seasonalWoolProduction == nil
        or swp.g_seasonalWoolProduction.modifyWoolRate == nil then
            -- SWP absent or API drift. Hook stays installed (we lazy-guard
            -- so no per-tick exception storm); RLModBridge.shimErrors[mod]
            -- carries the explanation set during the deferred phase.
            return
        end

        -- Recompute litersPerHour[WOOL] as a stable cluster rate before
        -- handing off to SWP. Per animal: pallets.curve:get(age) is the
        -- per-day output, /24 for per-hour. Each RLRM cluster represents
        -- one animal (numAnimals=1 implicit), so no getNumAnimals() factor.
        --
        -- A stable rate is required because SWP's seasonal payout formula
        -- expects per-sample rates that don't fluctuate hour-to-hour;
        -- handing it RLRM's volatile per-animal output (temp-gated, drifts
        -- with individual ages, and gets wiped on save/load) caused SWP
        -- to under-shoot wildly on observed shearing days. Trade-off: wool
        -- yield no longer reflects per-animal genetics under this compat;
        -- every mature sheep contributes the same per-hour rate regardless
        -- of breed quality. See spec Change Log for rationale.
        local clusterSystem = self.spec_husbandryAnimals
            and self.spec_husbandryAnimals.clusterSystem
        local totalLitersPerHour = 0
        if clusterSystem ~= nil
        and type(clusterSystem.getClusters) == "function" then
            for _, animal in pairs(clusterSystem:getClusters() or {}) do
                local subType = animal and animal.getSubType and animal:getSubType()
                local pallets = subType and subType.output and subType.output.pallets
                if pallets ~= nil
                and pallets.fillType == wool
                and pallets.curve ~= nil
                and pallets.curve.get ~= nil then
                    local age = animal.age or 0
                    local litersPerDay = pallets.curve:get(age)
                    -- numAnimals=1 implicit in RLRM's per-individual model.
                    totalLitersPerHour = totalLitersPerHour + (litersPerDay / 24)
                end
            end
        end
        spec.litersPerHour[wool] = totalLitersPerHour

        Log:trace("ShimWoolCompat: pen='%s' vanillaRate=%.4f (replaces RLRM rate)",
            tostring(self:getName()), totalLitersPerHour)

        swp.g_seasonalWoolProduction:modifyWoolRate(self)
    end)
end

--- Spec-registration callback. Appended to
--- PlaceableHusbandryPallets.registerOverwrittenFunctions so each placeable
--- with the pallets spec gets a chained overwrite layered on top of RLRM's.
--- @param placeable table the spec being initialized
function ShimWoolCompat.registerOverwrittenFunctions(placeable)
    SpecializationUtil.registerOverwrittenFunction(
        placeable,
        "updateInputAndOutput",
        ShimWoolCompat.overwriteBody
    )
end

--- Late-binding install run by RLModBridge.runDeferredPhase after all mods
--- have sourced. By now SeasonalWoolProduction and g_seasonalWoolProduction
--- exist (if SWP is installed). Two failure modes are observable via
--- shimErrors:
---  - modifyWoolRate missing -> full disable (activeShims left nil); the
---    hourly hook stays installed but its lazy guard makes it a no-op,
---    and continuous wool returns.
---  - countMatureAnimals missing -> degraded mode (activeShims=true): the
---    hourly hook still suppresses continuous wool, but SWP's pen iteration
---    cannot see RLRM sheep and shearing will pay out zero (pens=0).
--- @param bridge table the RLModBridge table (we write activeShims / shimErrors / originalRefs on it)
function ShimWoolCompat.lateInstall(bridge)
    if not g_currentMission:getIsServer() then return end
    if bridge.activeShims[MOD_NAME] then
        Log:trace("ShimWoolCompat: already active, skipping lateInstall")
        return
    end

    local swp = swpEnv()
    if swp == nil then
        bridge.shimErrors[MOD_NAME] = "SWP mod env not found at _G[" .. SWP_NAMESPACE .. "]"
        Log:warning("ShimWoolCompat: SWP env missing; shim disabled")
        return
    end

    if swp.g_seasonalWoolProduction == nil
    or swp.g_seasonalWoolProduction.modifyWoolRate == nil then
        bridge.shimErrors[MOD_NAME] = "g_seasonalWoolProduction.modifyWoolRate missing"
        Log:warning("ShimWoolCompat: modifyWoolRate missing; shim disabled (continuous wool will return)")
        return
    end

    if swp.SeasonalWoolProduction == nil
    or swp.SeasonalWoolProduction.countMatureAnimals == nil then
        bridge.shimErrors[MOD_NAME] = "SeasonalWoolProduction.countMatureAnimals missing - shearing will find 0 pens"
        Log:warning("ShimWoolCompat: countMatureAnimals missing; SWP's pen iteration cannot see RLRM sheep, shearing skipped")
        bridge.activeShims[MOD_NAME] = true
        Log:info("RLModBridge: activated shim %s (degraded - pens=0)", MOD_NAME)
        return
    end

    -- Save original BEFORE patching so tests + same-process scenarios can
    -- restore via RLModBridge.restoreOriginals(MOD_NAME).
    --
    -- We DON'T patch calcHealthAdjustedRate anymore: SWP's
    -- calcHealthAdjustedRate iterates animalsSpec.clusterSystem.clusters
    -- (the field), which RLRM keeps empty (per-individual animals live in
    -- clusterSystem.animals via the overridden :getClusters() method).
    -- With clusters empty, calcHealthAdjustedRate's loop iterates nothing,
    -- totalAnimals stays 0, and the function returns rawRate unchanged -
    -- it self-degrades to identity. One less foreign function to maintain.
    bridge.originalRefs[MOD_NAME] = {
        countMatureAnimals = swp.SeasonalWoolProduction.countMatureAnimals,
        _restoreMap = {
            countMatureAnimals = {
                table = swp.SeasonalWoolProduction,
                key = "countMatureAnimals"
            }
        }
    }

    -- RLRM-aware replacement for SWP's mature-animal count. SWP's
    -- original reads animalsSpec.clusterSystem.clusters FIELD directly;
    -- under RLRM that field stays empty (per-individual animals live in
    -- clusterSystem.animals, exposed via the overridden :getClusters()
    -- method). Walking the method instead lets SWP's pen iteration see
    -- the herd. We return numMature == numTotal == count(age >= 8) so
    -- SWP's mature-fraction scaling step becomes a no-op: our rate
    -- calculation above already gates on the same maturity threshold,
    -- and scaling on top would double-discount. Cost charging stays
    -- semantically correct: SWP multiplies its per-sheep cost by
    -- numMature, which is the count of actually-shearable sheep. The
    -- age threshold (8 months) matches the threshold SWP uses for the
    -- same purpose; the value is not exported by SWP, so we hardcode
    -- it here and re-verify on SWP updates.
    swp.SeasonalWoolProduction.countMatureAnimals = function(_, animalsSpec)
        local mature = 0
        if animalsSpec ~= nil and animalsSpec.clusterSystem ~= nil
        and type(animalsSpec.clusterSystem.getClusters) == "function" then
            local animals = animalsSpec.clusterSystem:getClusters() or {}
            for _, animal in pairs(animals) do
                local age = (animal and animal.age) or 0
                if age >= 8 then
                    mature = mature + 1
                end
            end
        end
        return mature, mature
    end

    bridge.activeShims[MOD_NAME] = true
    Log:info("RLModBridge: activated shim %s", MOD_NAME)
end

Log:debug("ShimWoolCompat: source-loaded; spec-chain install pending")

-- =====================================================================
-- LAST LINE: install the spec-registration append. Per the install-last
-- discipline (docs/architecture/mod-support-bridge.md), this line goes
-- AT THE END so any earlier source-time throw leaves zero partial install.
-- =====================================================================
PlaceableHusbandryPallets.registerOverwrittenFunctions = Utils.appendedFunction(
    PlaceableHusbandryPallets.registerOverwrittenFunctions,
    ShimWoolCompat.registerOverwrittenFunctions
)
