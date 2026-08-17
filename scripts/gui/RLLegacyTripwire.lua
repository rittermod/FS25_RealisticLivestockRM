-- RLLegacyTripwire.lua
-- Purpose: Loud dev-cycle signal that the dormant-but-still-present legacy
-- AnimalScreen layer is STILL being called. Arms every RLRM-authored function
-- in the to-delete AnimalScreen files with an ERROR + printCallstack() that
-- fires on EVERY call, then delegates to the original. Observe-only: the
-- wrapper never suppresses, redirects, reorders, or swallows an error - it
-- logs, then tail-returns the original so behaviour is byte-identical.
--
-- WHY it exists: once the new RLMenu owns every buy/sell/move/info/trailer/EPP
-- flow, NOTHING should reach the legacy layer. A grep only sees the trees we
-- scanned; this catches a routing path we missed or an external mod using our
-- internals AT RUNTIME. If our own surviving code (RLMenu, FSBaseMission) still
-- touches the doomed layer, the callstack names the exact caller.
--
-- Two arming strategies, because dispatch differs:
--   armMethods(class, names) - re-points the FINAL installed member on a
--     base-game class RLRM patched (AnimalScreen + the 6 controller classes).
--     That final member is the ONLY thing that intercepts `instance:method()`
--     dispatch: Utils.overwrittenFunction/appendedFunction captured the RL body
--     BY VALUE, so re-pointing a namespace slot could never reach a live call.
--   armTable(tbl)            - wraps each function value on a fully-RLRM-owned
--     table that dispatches through ITSELF (AnimalScreenMoveFarm static calls;
--     ProfileDialog / AnimalInfoDialog instances via __index). Re-pointing the
--     table member intercepts those.
--
-- The RL_* namespace tables are deliberately NOT armed: their real bodies are
-- already caught via armMethods on the base class, and arming them would flood
-- on hot sort comparators and re-fire the surviving-helper aliases.
--
-- Coverage is a reproducible gate: armed == dual-pattern-unique(class, method)
-- minus the EXCLUSIONS below. The manifest is derived by grepping BOTH
-- `function <Class>:x()` direct defs AND `<Class>.x = ...` assignment targets
-- across the monolith AND the controllers (a method can be installed from a
-- sibling file; two installs can collapse onto one member). Non-function data
-- fields (AnimalScreen.DEWAR_QUANTITIES, AnimalScreenMoveFarm.MOVE_ERROR_CODE_MAPPING)
-- are not methods, so they are outside the manifest and WARN-skipped if reached.
--
-- TEMPORARY: this module, its one source() line, RLLegacyTripwireTests.lua, and
-- that suite's RLTestRunner registration all die when the legacy AnimalScreen
-- layer is deleted (the migration doc's legacy-layer-removal checklist owns the
-- removal steps). It ships in all builds until the legacy layer is removed;
-- per-call ERROR spam is the intended trade for never masking a later
-- unexpected caller.
--
-- Author: Ritter
-- Usage: self-arms at source time (file tail); no caller needed.

RLLegacyTripwire = {}

local Log = RmLogging.getLogger("RLRM")

-- Identity set of THIS-LOAD wrapper functions, so a double armAll() within one
-- load is a no-op (we never wrap a wrapper). A DEV_RELOAD re-sources this file:
-- the table resets AND the doomed installs are fresh members, so re-arming the
-- fresh members once is correct.
local wrappers = {}

-- Base-game Class() (class.lua) injects these FUNCTION members directly onto any
-- Class()-ified table: class / superClass / isa (always) + copy (unless the table
-- already defines it). They are engine machinery, NOT RLRM-authored doomed members,
-- so armTable must skip them or it over-arms every Class()-based table and fires on
-- internal :superClass()/:isa() calls. `new` is deliberately NOT here: the dialogs
-- define their own new (a real doomed member), and Class keeps an existing new.
local CLASS_MACHINERY = { class = true, superClass = true, isa = true, copy = true }

-- Injectable sink test seam. nil => the default (ERROR + callstack). The
-- interception tests set RLLegacyTripwire.sink to a capture fn before dispatch
-- and restore it after - no spying on the shared RmLogger. Read at CALL time so
-- a sink installed after arming still takes effect.
RLLegacyTripwire.sink = nil

-- Live count of members actually wrapped by the last armAll(), for the log line
-- and a quick eyeball against the documented gate.
RLLegacyTripwire._armedCount = 0

--- Default sink: ERROR naming the doomed member + a callstack that names the
--- caller (mirrors RmSafeUtils.safeCall). Both primitives nil-guarded so an
--- early/odd load context cannot turn the tripwire itself into a crash.
---@param label string  "<Owner>.<method>" of the doomed member that was called
local function defaultSink(label)
    if Log ~= nil and Log.error ~= nil then
        Log:error("[legacy-tripwire] %s called - the doomed legacy AnimalScreen layer is still reachable", tostring(label))
    end
    if printCallstack ~= nil then
        printCallstack()
    end
end

--- Wrap fn so every call fires the sink FIRST, then delegates transparently.
--- The wrapper is a plain varargs tail-return: `return fn(...)`. That preserves
--- self, all args, and the FULL return contract of every install kind -
--- overwrittenFunction's `function(self, ...) return newFunc(self, super, ...) end`
--- (multi-return) AND appendedFunction/prependedFunction's zero-return shape.
--- NO pcall/xpcall around fn: that would swallow the original's errors and break
--- parity. Fire-every-call by design (no dedup).
---@param fn function        the final composed member to intercept
---@param label string       "<Owner>.<method>" for the log line
---@param sink function|nil   optional explicit sink (else RLLegacyTripwire.sink, else default)
---@return function            the wrapper (or fn unchanged if not a function / already wrapped)
function RLLegacyTripwire.wrap(fn, label, sink)
    if type(fn) ~= "function" then return fn end
    if wrappers[fn] then return fn end  -- already a this-load tripwire wrapper
    local function tw(...)
        local emit = sink or RLLegacyTripwire.sink or defaultSink
        -- pcall the SINK only (never the delegate): a buggy injected sink must
        -- not abort the original - that would break the observe-only contract.
        -- fn stays unprotected so its real errors propagate unchanged.
        pcall(emit, label)
        return fn(...)
    end
    wrappers[tw] = true
    return tw
end

--- Arm named members on a base-game class RLRM patched. Skips the EXCLUSIONS
--- for that owner (named render/hot-path callbacks + the cross-ticket onClose),
--- WARN-skips a name that is absent or non-function at arm time (renamed /
--- constant), and is idempotent within a load (wrap() no-ops an already-wrapped
--- member). A nil/non-table class is a WARN-skip, never a load abort.
---@param class table         the base-game class table (AnimalScreen, AnimalScreenDealer, ...)
---@param names table         array of RLRM-authored method names (the manifest)
---@param ownerName string    label owner (also the EXCLUSIONS key)
function RLLegacyTripwire.armMethods(class, names, ownerName)
    if type(class) ~= "table" then
        if Log ~= nil then
            Log:warning("[legacy-tripwire] armMethods: target '%s' is not a table (nil/renamed) - skipped", tostring(ownerName))
        end
        return
    end
    local excl = RLLegacyTripwire.EXCLUSIONS[ownerName]
    for i = 1, #names do
        local name = names[i]
        if excl ~= nil and excl[name] then
            -- Named exclusion: intentionally not armed (see EXCLUSIONS).
            if Log ~= nil then
                Log:trace("[legacy-tripwire] %s.%s excluded (not armed)", ownerName, tostring(name))
            end
        else
            local member = class[name]
            if type(member) ~= "function" then
                if Log ~= nil then
                    Log:warning("[legacy-tripwire] %s.%s absent or non-function at arm time - skipped", ownerName, tostring(name))
                end
            else
                class[name] = RLLegacyTripwire.wrap(member, ownerName .. "." .. name)
                -- Count COVERAGE (member is now a wrapper), not mutation, so a
                -- repeat arm within a load re-reports the full total instead of 0.
                if wrappers[class[name]] then
                    RLLegacyTripwire._armedCount = RLLegacyTripwire._armedCount + 1
                end
            end
        end
    end
end

--- Arm every function value on a fully-RLRM-owned, self-dispatched table.
--- Skips non-function fields (a constant like MOVE_ERROR_CODE_MAPPING) and the
--- owner's EXCLUSIONS (the wholesale-delegation aliases into surviving helpers).
--- Reassigning an EXISTING key's value mid-pairs() is safe in Lua; we never add
--- or remove keys, and wrappers[] guards against re-wrapping.
---@param tbl table           the RLRM-owned table (AnimalScreenMoveFarm, ProfileDialog, AnimalInfoDialog)
---@param ownerName string    label owner (also the EXCLUSIONS key)
function RLLegacyTripwire.armTable(tbl, ownerName)
    if type(tbl) ~= "table" then
        if Log ~= nil then
            Log:warning("[legacy-tripwire] armTable: target '%s' is not a table - skipped", tostring(ownerName))
        end
        return
    end
    local excl = RLLegacyTripwire.EXCLUSIONS[ownerName]
    for name, member in pairs(tbl) do
        if type(member) == "function" and not CLASS_MACHINERY[name] and not (excl ~= nil and excl[name]) then
            tbl[name] = RLLegacyTripwire.wrap(member, ownerName .. "." .. name)
            -- Count coverage, not mutation (see armMethods).
            if wrappers[tbl[name]] then
                RLLegacyTripwire._armedCount = RLLegacyTripwire._armedCount + 1
            end
        end
    end
end

-- =============================================================================
-- EXCLUSIONS - the only members deliberately kept OFF the tripwire, each named
-- so `armed == manifest - exclusions` stays a reproducible count, not an ad-hoc
-- denylist. Three kinds:
--   1. render / hot-path callbacks - fire per cell / per frame; arming floods.
--   2. cross-ticket intentional call - the EPP redirect fires the vanilla
--      onClose on every EPP open; its reset chain (controller:reset /
--      resetGameState) touches NO armed member, so onClose alone silences it.
--   3. wholesale-delegation aliases - bare assignments of a SURVIVING helper
--      (RLMoveDestinationHelper) onto a doomed table; a call runs surviving
--      code, not doomed logic.
--   4. known boot-only doomed calls (empirically pruned) - the dialogs' singleton
--      construction/registration (register/new/onCreate/loadProfiles) fire once at
--      FSBaseMission:onStartMission, and AnimalScreen.onGuiSetupFinished fires once
--      on its loadGui - never on a later show/open. Excluding them is safe AND better
--      signal: actual USE still trips the usage-path members (show -> onOpen ->
--      updateContent/setChildren/setTexts/onClick*/saveProfiles/getProfiles), and a
--      real AnimalScreen open still trips setController - so a foreign mod / base-game
--      caller that actually opens the doomed code still screams, while the boot stays
--      ERROR-free so any fire a tester sees is a TRUE find. The only blind spot is a
--      foreign caller invoking new/register/onCreate directly WITHOUT ever showing the
--      dialog - a pattern no real caller uses.
-- =============================================================================
RLLegacyTripwire.EXCLUSIONS = {
    AnimalScreen = {
        -- (1) render / hot-path callbacks
        populateCellForItemInSection = true,
        getNumberOfItemsInSection    = true,
        getCellTypeForItemInSection  = true,
        updateScreen                 = true,
        updateInfoBox                = true,
        onListSelectionChanged       = true,
        -- (2) cross-ticket intentional call. EVERY redirected open depends on this
        -- exclusion: the onOpen seam redirects any controller shape, and both its success
        -- path (showGui) and its refusal path (changeScreen(nil)) close the displaced
        -- screen, which fires onClose. Removing the exclusion would ERROR on ordinary
        -- third-party opens, not only on the butcher flow.
        onClose                      = true,
        -- (4) boot-only GUI-setup callback (loadGui; never on re-open - setController catches a real open)
        onGuiSetupFinished           = true,
    },
    AnimalScreenMoveFarm = {
        -- (3) wholesale-delegation aliases into a surviving helper
        getValidDestinations      = true,
        buildMoveValidationResult = true,
    },
    -- (4) boot-only singleton construction/registration. Note what this no longer buys:
    -- the seam now redirects every open before the doomed layer is reached, so the armed
    -- usage-path members are not a reachable signal for a foreign caller either - the
    -- remaining coverage is a residual RLRM-internal path, not a third-party one.
    AnimalInfoDialog = {
        register = true,
        new      = true,
        onCreate = true,
    },
    ProfileDialog = {
        register     = true,
        new          = true,
        loadProfiles = true,
    },
}

-- =============================================================================
-- MANIFEST - dual-pattern-unique(class, method), derived by grepping the
-- monolith AND the controllers. Counts (manifest / excluded / armed):
--   AnimalScreen             84 / 8 / 76   (84 = 85 grep-union minus the DEWAR_QUANTITIES constant; excl +onGuiSetupFinished)
--   AnimalScreenBase          4 / 0 /  4
--   AnimalScreenDealer       14 / 0 / 14
--   AnimalScreenDealerFarm   12 / 0 / 12
--   AnimalScreenDealerTrailer 13 / 0 / 13
--   AnimalScreenTrailer       5 / 0 /  5
--   AnimalScreenTrailerFarm   9 / 0 /  9
--   AnimalScreenMoveFarm  (armTable) 11 fns / 2 / 9
--   ProfileDialog         (armTable) 12 fns / 3 / 9   (excl register/new/loadProfiles - boot-only)
--   AnimalInfoDialog      (armTable) 12 fns / 3 / 9   (excl register/new/onCreate - boot-only)
-- Total armed = 160. (Class()-injected machinery on the two dialogs is skipped separately.)
-- =============================================================================
local MANIFEST = {
    AnimalScreen = {
        "buySelected", "changeName", "getCellTypeForItemInSection", "getNumberOfItemsInSection",
        "getPrice", "getSelectedCount", "onAIListSelectionChanged", "onApplyFilters", "onClickAIMode",
        "onClickAnimalInfo", "onClickApplyHerdsmanSettings", "onClickArtificialInsemination", "onClickBack",
        "onClickBuy", "onClickBuyAI", "onClickBuyMode", "onClickBuySelected", "onClickCastrate",
        "onClickChangeAIAnimalType", "onClickChangeAIQuantity", "onClickChangeHerdsmanBudgetType",
        "onClickDeleteMessage", "onClickDiseases", "onClickEnableHerdsman", "onClickFavouriteAnimal",
        "onClickFilter", "onClickHerdsmanLoadProfile", "onClickHerdsmanMode", "onClickHerdsmanPageAI",
        "onClickHerdsmanPageBuy", "onClickHerdsmanPageCastrate", "onClickHerdsmanPageNaming",
        "onClickHerdsmanPageSell", "onClickHerdsmanSaveProfile", "onClickInfoMode", "onClickInfoPrompt",
        "onClickLogMode", "onClickMark", "onClickMessagePageFirst", "onClickMessagePageLast",
        "onClickMessagePageNext", "onClickMessagePagePrevious", "onClickMessageSortButton", "onClickMonitor",
        "onClickMoveMode", "onClickRLSelect", "onClickRename", "onClickSell", "onClickSellMode",
        "onClickToggleSelectAll", "onClose", "onGuiSetupFinished", "onHerdsmanLoadProfileCallback",
        "onHerdsmanSaveProfileCallback", "onHerdsmanTextChangedInt", "onHighlightInfoPrompt",
        "onHighlightRemoveInfoPrompt", "onListSelectionChanged", "onMoneyChange", "onMoveAnimalsChanged",
        "onMoveConfirmed", "onMoveDestinationSelected", "onPageNext", "onPagePrevious", "onSemenBought",
        "onSourceActionFinished", "onSourceBulkActionFinished", "onTargetActionFinished",
        "onTargetBulkActionFinished", "onYesNoSource", "onYesNoTarget", "populateCellForItemInSection",
        "postSemenBought", "reapplyFilters", "resetMessageButtonStates", "sellSelected", "setController",
        "setDefaultHerdsmanOptions", "setMaxNumAnimals", "setSelectionState", "updateBuySelectedButtonText",
        "updateInfoBox", "updateLog", "updateScreen",
    },
    AnimalScreenBase = {
        "getTargetItems", "setCurrentHusbandry",
        "setSourceBulkActionFinishedCallback", "setTargetBulkActionFinishedCallback",
    },
    AnimalScreenDealer = {
        "applySource", "applySourceBulk", "applyTarget", "applyTargetBulk", "getSourceMaxNumAnimals",
        "getSourcePrice", "getTargetMaxNumAnimals", "getTargetPrice", "initItems", "initSourceItems",
        "initTargetItems", "onAnimalBought", "preValidateBuyItem", "setCurrentHusbandry",
    },
    AnimalScreenDealerFarm = {
        "applySource", "applySourceBulk", "applyTarget", "applyTargetBulk", "getSourceMaxNumAnimals",
        "getSourcePrice", "getTargetMaxNumAnimals", "getTargetPrice", "initSourceItems", "initTargetItems",
        "onAnimalBought", "preValidateBuyItem",
    },
    AnimalScreenDealerTrailer = {
        "applySource", "applySourceBulk", "applyTarget", "applyTargetBulk", "getSourceAnimalTypes",
        "getSourceMaxNumAnimals", "getSourcePrice", "initSourceItems", "initTargetItems", "onAnimalBought",
        "onAnimalSold", "onAnimalsChanged", "preValidateBuyItem",
    },
    AnimalScreenTrailer = {
        "getApplySourceConfirmationText", "initSourceItems", "initTargetItems",
        "onAnimalLoadedToTrailer", "onAnimalsChanged",
    },
    AnimalScreenTrailerFarm = {
        "applySource", "applySourceBulk", "applyTarget", "applyTargetBulk", "initSourceItems",
        "initTargetItems", "onAnimalMovedToFarm", "onAnimalMovedToTrailer", "onAnimalsChanged",
    },
}

--- Arm the whole manifest. armMethods for the 7 base-game classes RLRM patched;
--- armTable for the 3 fully-RLRM-owned self-dispatched tables. Idempotent within
--- a load. Safe to call once at file tail; every doomed install is complete by
--- the time this file is sourced (controllers, monolith, and both dialogs all
--- load earlier).
function RLLegacyTripwire.armAll()
    RLLegacyTripwire._armedCount = 0

    RLLegacyTripwire.armMethods(AnimalScreen,              MANIFEST.AnimalScreen,              "AnimalScreen")
    RLLegacyTripwire.armMethods(AnimalScreenBase,          MANIFEST.AnimalScreenBase,          "AnimalScreenBase")
    RLLegacyTripwire.armMethods(AnimalScreenDealer,        MANIFEST.AnimalScreenDealer,        "AnimalScreenDealer")
    RLLegacyTripwire.armMethods(AnimalScreenDealerFarm,    MANIFEST.AnimalScreenDealerFarm,    "AnimalScreenDealerFarm")
    RLLegacyTripwire.armMethods(AnimalScreenDealerTrailer, MANIFEST.AnimalScreenDealerTrailer, "AnimalScreenDealerTrailer")
    RLLegacyTripwire.armMethods(AnimalScreenTrailer,       MANIFEST.AnimalScreenTrailer,       "AnimalScreenTrailer")
    RLLegacyTripwire.armMethods(AnimalScreenTrailerFarm,   MANIFEST.AnimalScreenTrailerFarm,   "AnimalScreenTrailerFarm")

    RLLegacyTripwire.armTable(AnimalScreenMoveFarm, "AnimalScreenMoveFarm")
    RLLegacyTripwire.armTable(ProfileDialog,        "ProfileDialog")
    RLLegacyTripwire.armTable(AnimalInfoDialog,     "AnimalInfoDialog")

    -- The 160 total is the reproducible count gate (see the MANIFEST header). A
    -- live WARN on drift makes a coverage loss during the migration SCREAM rather
    -- than silently shrink - a WARN, never a load abort, per the spec's count-gate
    -- boundary. Coverage-counted (not mutation), so a repeat arm stays at 167.
    local EXPECTED_ARMED = 160
    if Log ~= nil then
        if RLLegacyTripwire._armedCount == EXPECTED_ARMED then
            Log:info("[legacy-tripwire] armed %d/%d doomed AnimalScreen-layer members (temporary; removed with the legacy layer)",
                RLLegacyTripwire._armedCount, EXPECTED_ARMED)
        else
            Log:warning("[legacy-tripwire] armed %d/%d doomed members - COVERAGE DRIFT: a manifest member was renamed/removed, or a target class was nil at arm time; reconcile the manifest before trusting the tripwire",
                RLLegacyTripwire._armedCount, EXPECTED_ARMED)
        end
    end
end

-- Self-arm at source time. All doomed installs are complete by now.
RLLegacyTripwire.armAll()
