-- RLDealerSaleApply.lua
-- Folds the dealer sale-availability override registry onto the live per-visual
-- `store.canBeBought` flags. Writing the real base-game flag is the point: the two dealer gates
-- - `_pickSaleAnimalAge` and the `createNewSaleAnimal` subtype filter - then read the applied
-- state with no edits of their own.
--
-- Split into a PURE core (`apply`) that takes plain tables and mutates them, plus a thin in-game
-- shell (`applyToLiveSubTypes` / `applyAndRepopulate`) that locates the live subTypes and drives
-- the dealer regeneration. The pure core dual-runs.
--
-- Baseline contract: the FIRST time an overridden (subTypeName, minAge) is seen with a live
-- store, its loaded `canBeBought` is captured BEFORE any write, and that captured value is the
-- default the stage restores to when its override is cleared. The baseline is lazy, in-memory,
-- per-session and NOT persisted; it resets at each savegame-load apply so it re-derives from the
-- freshly-reloaded values.

local Log = RmLogging.getLogger("RLRM")

RLDealerSaleApply = {}

--- Per-session captured defaults: sessionBaseline[subTypeName][minAge] = boolean. A plain
--- literal, so there is no game read at source time.
RLDealerSaleApply.sessionBaseline = {}

-- =============================================================================
-- Pure core (data in / data out) - the dual-run unit
-- =============================================================================

--- Fold `registry` over `subTypes`, writing the effective sale-availability onto each
--- overridden visual's `store.canBeBought` and lazily capturing its default into `baseline`.
--- Mutates `subTypes` store flags and `baseline` in place; no `g_*`, XML or GUI.
---
--- Phase 1 captures each override's gate-equivalent default, but only the FIRST time the key is
--- seen, so the snapshot survives set -> clear -> set toggles within a session. Phase 2 writes
--- `effective(override, default)` for every baseline-tracked visual. Iterating the BASELINE
--- rather than the registry is what makes un-marking restore: a cleared key has
--- `registry:get -> nil`, so `effective(nil, default)` is the default.
---
--- `minAge` is unique and ascending per subtype (the base loader enforces it), so Phase 1's
--- break-on-first-match and Phase 2's write-all-matching are equivalent.
---@param subTypes table[] animalSystem.subTypes: array of { name=, visuals={ { minAge=, store={ canBeBought= } }, ... } }
---@param registry table an RLDealerSaleRegistry instance
---@param baseline table captured-default map: baseline[subTypeName][minAge] = boolean
function RLDealerSaleApply.apply(subTypes, registry, baseline)
    local byName = {}
    for _, st in ipairs(subTypes) do
        byName[st.name] = st
    end

    local captured = 0

    -- Phase 1: capture the gate-equivalent default for each override, once, before any write.
    for _, rec in ipairs(registry:enumerate()) do
        local st = byName[rec.subTypeName]
        if st ~= nil and st.visuals ~= nil then
            local matched = false
            local minAgeSeenButNoStore = false
            for _, visual in ipairs(st.visuals) do
                if visual.minAge == rec.minAge then
                    if visual.store ~= nil then
                        baseline[rec.subTypeName] = baseline[rec.subTypeName] or {}
                        if baseline[rec.subTypeName][rec.minAge] == nil then
                            baseline[rec.subTypeName][rec.minAge] = visual.store.canBeBought and true or false
                            captured = captured + 1
                            Log:trace("RLDealerSaleApply.apply: captured baseline %s@%d = %s",
                                rec.subTypeName, rec.minAge, tostring(baseline[rec.subTypeName][rec.minAge]))
                        end
                        matched = true
                        break  -- minAge is unique per subtype (loader-enforced); first match is the only match
                    else
                        minAgeSeenButNoStore = true  -- keep scanning; a store-bearing match still wins
                    end
                end
            end
            if not matched then
                if minAgeSeenButNoStore then
                    Log:trace("RLDealerSaleApply.apply: override %s@%d matched a visual with no store; skipped",
                        rec.subTypeName, rec.minAge)
                else
                    Log:trace("RLDealerSaleApply.apply: no live visual for override %s@%d (stale minAge); skipped",
                        rec.subTypeName, rec.minAge)
                end
            end
        else
            Log:trace("RLDealerSaleApply.apply: subtype %s absent or has no visuals; override @%d skipped",
                tostring(rec.subTypeName), rec.minAge)
        end
    end

    -- Phase 2: write effective(override, default) for every baseline-tracked visual.
    local written = 0
    for subTypeName, ages in pairs(baseline) do
        local st = byName[subTypeName]
        if st ~= nil and st.visuals ~= nil then
            for _, visual in ipairs(st.visuals) do
                if visual.store ~= nil and ages[visual.minAge] ~= nil then
                    local override = registry:get(subTypeName, visual.minAge)
                    visual.store.canBeBought = RLDealerSaleRegistry.effective(override, ages[visual.minAge])
                    written = written + 1
                    Log:trace("RLDealerSaleApply.apply: wrote %s@%d canBeBought=%s (override=%s, default=%s)",
                        subTypeName, visual.minAge, tostring(visual.store.canBeBought),
                        tostring(override), tostring(ages[visual.minAge]))
                end
            end
        end
    end

    Log:debug("RLDealerSaleApply.apply: %d visual(s) written, %d baseline(s) captured this pass",
        written, captured)
end

-- =============================================================================
-- In-game shell (peer-agnostic apply + on-change repopulate)
-- =============================================================================

--- Reset the per-session baseline so the next apply re-derives it from the freshly-reloaded
--- live values. Called at each savegame-load apply.
function RLDealerSaleApply.resetBaseline()
    RLDealerSaleApply.sessionBaseline = {}
    Log:debug("RLDealerSaleApply.resetBaseline: session baseline cleared")
end

--- Apply the registry to the live subTypes. Peer-agnostic - writing local store flags is safe
--- on any peer, so there is no `g_server` guard - and every dependency is guarded, no-opping
--- with a warning on a miss.
function RLDealerSaleApply.applyToLiveSubTypes()
    if g_currentMission == nil then
        Log:warning("RLDealerSaleApply.applyToLiveSubTypes: g_currentMission is nil; skipping")
        return
    end

    local animalSystem = g_currentMission.animalSystem
    if animalSystem == nil then
        Log:warning("RLDealerSaleApply.applyToLiveSubTypes: g_currentMission.animalSystem is nil; skipping")
        return
    end

    if g_rlDealerSaleRegistry == nil then
        Log:warning("RLDealerSaleApply.applyToLiveSubTypes: g_rlDealerSaleRegistry is nil; skipping")
        return
    end

    if type(animalSystem.subTypes) ~= "table" then
        Log:warning("RLDealerSaleApply.applyToLiveSubTypes: animalSystem.subTypes is not a table (%s); skipping",
            type(animalSystem.subTypes))
        return
    end

    Log:debug("RLDealerSaleApply.applyToLiveSubTypes: applying overrides to %d live subtype(s)",
        #animalSystem.subTypes)

    -- Last-resort error boundary: this rides savegame load and a GUI callback, so a malformed
    -- live subtype must never abort the caller. Catch, log, and leave the flags as loaded.
    local ok, err = pcall(RLDealerSaleApply.apply,
        animalSystem.subTypes, g_rlDealerSaleRegistry, RLDealerSaleApply.sessionBaseline)
    if not ok then
        Log:error("RLDealerSaleApply.applyToLiveSubTypes: apply failed; live flags left at loaded values: %s",
            tostring(err))
    end
end

--- On-change entry: apply the overrides to the live flags, then regenerate the dealer so the new
--- stock reflects them, reusing the exact path the "Reset animal dealer" button takes -
--- host/SP routes to executeOnServer plus a broadcast, a client to a server request. Must NOT
--- call `executeOnServer` directly, which dereferences `g_server` unconditionally and would
--- crash on a client.
function RLDealerSaleApply.applyAndRepopulate()
    Log:debug("RLDealerSaleApply.applyAndRepopulate: apply then full dealer reset")
    RLDealerSaleApply.applyToLiveSubTypes()
    RL_ResetDealerEvent.sendEvent(RL_ResetDealerEvent.TYPE_DEALER)
end

Log:debug("RLDealerSaleApply: loaded")
