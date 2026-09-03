--[[
    main.lua
    Main loader for RealisticLivestockRM mod.
    Loads all dependencies in the correct order.

    IMPORTANT: The loading order is critical - do not reorder without testing.
]]

local modDirectory = g_currentModDirectory

-- SECTION 0: Logging
source(modDirectory .. "scripts/rmlib/RmLogging.lua")
Log = RmLogging.getLogger("RLRM")
source(modDirectory .. "scripts/rmlib/RmVersion.lua")
local Ver = RmVersion.forMod(g_currentModName, Log)
Log:info("Build: %s", Ver:describe())
-- DEBUG unless this is a released stable version (>= 1.0.0.0 with no -dev suffix).
Ver:applyBuildLogLevel()
-- Log:setLevel(RmLogging.LOG_LEVEL.DEBUG) -- Manual override of log level

-- SECTION 1: Font Library
source(modDirectory .. "scripts/fontlib/RmFontCharacter.lua")
source(modDirectory .. "scripts/fontlib/RmFontManager.lua")

-- SECTION 2: GUI Loading Screen
source(modDirectory .. "scripts/gui/MPLoadingScreen.lua")

-- SECTION 2b: Utilities
source(modDirectory .. "scripts/utils/RmSafeUtils.lua")
source(modDirectory .. "scripts/utils/RLAnimalUtil.lua")
-- Reads FarmManager at call time only, so this early slot is safe. Consumed by the
-- server-side event validation and by the Info frame's client-side button gate.
source(modDirectory .. "scripts/utils/RLPermissionHelper.lua")
source(modDirectory .. "scripts/utils/RLScaleHelper.lua")
source(modDirectory .. "scripts/utils/RLAnimalDisplayHelper.lua")
source(modDirectory .. "scripts/utils/RLMoveDestinationHelper.lua")
-- Shared month-count formatter. Consumed by Disease (SECTION 20e) and by the
-- RealisticLivestock.formatAge delegate (SECTION 20f), both of which load later.
source(modDirectory .. "scripts/utils/RLTimeFormat.lua")

-- SECTION 2c: Constants
source(modDirectory .. "scripts/core/RLConstants.lua")

-- SECTION 2d: Map country resolution (needs RLConstants; consumed by
-- RealisticLivestock.lua and RLSettings.lua much later in the order)
source(modDirectory .. "scripts/core/RLMapCountry.lua")

-- SECTION 3: Animal Husbandry - Cluster System
source(modDirectory .. "scripts/animals/husbandry/cluster/RealisticLivestock_AnimalCluster.lua")
source(modDirectory .. "scripts/animals/husbandry/cluster/RealisticLivestock_AnimalClusterHusbandry.lua")
source(modDirectory .. "scripts/animals/husbandry/cluster/RealisticLivestock_AnimalClusterSystem.lua")
source(modDirectory .. "scripts/animals/husbandry/cluster/VisualAnimal.lua")

-- SECTION 4: Animal Husbandry - Placeables
source(modDirectory .. "scripts/animals/husbandry/placeables/PlaceableHusbandry.lua")
source(modDirectory .. "scripts/animals/husbandry/placeables/PlaceableHusbandryLiquidManure.lua")
source(modDirectory .. "scripts/animals/husbandry/placeables/PlaceableHusbandryStraw.lua")
source(modDirectory .. "scripts/animals/husbandry/placeables/PlaceableHusbandryWater.lua")
source(modDirectory .. "scripts/animals/husbandry/placeables/RealisticLivestock_PlaceableHusbandryAnimals.lua")
source(modDirectory .. "scripts/animals/husbandry/placeables/RealisticLivestock_PlaceableHusbandryMilk.lua")
source(modDirectory .. "scripts/animals/husbandry/placeables/RealisticLivestock_PlaceableHusbandryFood.lua")
source(modDirectory .. "scripts/animals/husbandry/placeables/RealisticLivestock_PlaceableHusbandryPallets.lua")

-- SECTION 5: Animal Husbandry - Core Systems
source(modDirectory .. "scripts/events/AnimalSystemStateEvent.lua")
source(modDirectory .. "scripts/animals/husbandry/RealisticLivestock_HusbandrySystem.lua")
source(modDirectory .. "scripts/animals/husbandry/RealisticLivestock_AnimalNameSystem.lua")
source(modDirectory .. "scripts/animals/husbandry/RealisticLivestock_AnimalSystem.lua")

-- SECTION 7: Animal Shop - Events
source(modDirectory .. "scripts/animals/shop/events/AIAnimalBuyEvent.lua")
source(modDirectory .. "scripts/animals/shop/events/AIAnimalInseminationEvent.lua")
source(modDirectory .. "scripts/animals/shop/events/AIAnimalMoveEvent.lua")
source(modDirectory .. "scripts/animals/shop/events/AIAnimalSellEvent.lua")
source(modDirectory .. "scripts/animals/shop/events/AnimalBuyEvent.lua")
source(modDirectory .. "scripts/animals/shop/events/AnimalInseminationEvent.lua")
source(modDirectory .. "scripts/animals/shop/events/AnimalInseminationResultEvent.lua")
source(modDirectory .. "scripts/animals/shop/events/AnimalMoveEvent.lua")
source(modDirectory .. "scripts/animals/shop/events/AnimalSellEvent.lua")
source(modDirectory .. "scripts/animals/shop/events/SemenBuyEvent.lua")

-- SECTION 8: Animal Shop - Core
source(modDirectory .. "scripts/animals/shop/RealisticLivestock_AnimalItemStock.lua")

-- SECTION 9: Events (General)
source(modDirectory .. "scripts/events/HusbandryMessageStateEvent.lua")
source(modDirectory .. "scripts/events/HusbandryMessageAddEvent.lua")
source(modDirectory .. "scripts/events/HusbandryMessageDeleteEvent.lua")
source(modDirectory .. "scripts/events/ReturnStrawEvent.lua")
source(modDirectory .. "scripts/events/TakeStrawEvent.lua")
source(modDirectory .. "scripts/events/DiseaseTreatmentToggleEvent.lua")

-- SECTION 10: Farms
source(modDirectory .. "scripts/farms/FarmManager.lua")
source(modDirectory .. "scripts/farms/RealisticLivestock_FarmStats.lua")

-- SECTION 11: Fill Types
source(modDirectory .. "scripts/fillTypes/RealisticLivestock_FillTypeManager.lua")

-- SECTION 11a: Map Bridge System
source(modDirectory .. "scripts/bridge/RLVersionSpec.lua")
source(modDirectory .. "scripts/bridge/RLMapBridge.lua")
source(modDirectory .. "scripts/bridge/RLModBridge.lua")

-- SECTION 11b: Breeding Mathematics
source(modDirectory .. "scripts/animal/BreedingMath.lua")
-- Pure sale-animal genetics draw. Leaf module (RmLogging + RLConstants only) and
-- resolved at call time by AnimalSystem:createNewSaleAnimal, so this later slot
-- is safe despite AnimalSystem sourcing earlier.
source(modDirectory .. "scripts/animal/RLGeneticsDraw.lua")
-- Genetics banding ladders + the domain predicate. Two real ordering
-- constraints, and neither is "consumers resolve at call time":
--   * it READS RLConstants at file scope, so it must follow SECTION 2c;
--   * any consumer that binds one of its re-exported TABLES at file scope is
--     pinned AFTER this line - today that is RLGeneticsFormatter (SECTION 13b).
-- Consumers that only call its functions are unconstrained.
source(modDirectory .. "scripts/animal/RLGenetics.lua")

-- SECTION 11c: Horse Logic (delegate module, sourced before Animal.lua)
source(modDirectory .. "scripts/animal/AnimalHorse.lua")

-- SECTION 11d: Reproduction Logic (delegate module, sourced before Animal.lua)
source(modDirectory .. "scripts/animal/AnimalReproduction.lua")

-- SECTION 11e: Health/Death Logic (delegate module, sourced before Animal.lua)
source(modDirectory .. "scripts/animal/AnimalHealth.lua")

-- SECTION 11f: Persistence & Serialization (delegate modules, sourced before Animal.lua)
source(modDirectory .. "scripts/animal/AnimalPersistence.lua")
source(modDirectory .. "scripts/animal/AnimalSerialization.lua")

-- SECTION 11g: Saveable Filters - headless service + MP events
source(modDirectory .. "scripts/filters/RLFilterFieldCatalog.lua")
source(modDirectory .. "scripts/filters/RLFilterFieldDisplay.lua")
source(modDirectory .. "scripts/filters/RLFilterEvaluator.lua")
source(modDirectory .. "scripts/filters/RLFilterUsage.lua")
source(modDirectory .. "scripts/filters/RLFilterSerialization.lua")
source(modDirectory .. "scripts/filters/RLFilterWire.lua")
source(modDirectory .. "scripts/filters/RLFilterService.lua")
source(modDirectory .. "scripts/events/RLFilterCreateEvent.lua")
source(modDirectory .. "scripts/events/RLFilterUpdateEvent.lua")
source(modDirectory .. "scripts/events/RLFilterDeleteEvent.lua")
source(modDirectory .. "scripts/events/RLFilterStateEvent.lua")
-- QF -> saved-filter conversion module. Depends on RLFilterUsage (above) and
-- RLScaleHelper (SECTION 2b); placed at the tail of 11g for legibility next to
-- the filter stack it serves. Consumed by AnimalFilterDialog:onClickSaveFilter
-- and the RLQuickFilterToSavedFilterTests suite.
source(modDirectory .. "scripts/utils/RLQuickFilterToSavedFilter.lua")

-- SECTION 11h: Herdsman Rules - headless service + persistence + MP events
-- In-memory rule registry (sibling of RLFilterService). Serializer before
-- service (mirrors 11g): the service's saveToXMLFile/loadFromXMLFile call into
-- RLHerdsmanRuleSerialization. Wire + Create/Update/Delete/State events after the
-- service (the service references them only at call time, nil-guarded). Create ->
-- Update -> Delete -> State order mirrors 11g's filter events. RLHusbandryTargetKey first:
-- the wire (readTargets/writeTargets) + RLAnimalQuery (13b) + the Herdsman frame (13) all
-- key husbandry targets through it (uniqueId on server, net-object-id on a pure client).
source(modDirectory .. "scripts/herdsman/RLHusbandryTargetKey.lua")
source(modDirectory .. "scripts/herdsman/RLHerdsmanRuleSerialization.lua")
source(modDirectory .. "scripts/herdsman/RLHerdsmanRuleService.lua")
source(modDirectory .. "scripts/herdsman/RLHerdsmanRuleWire.lua")
source(modDirectory .. "scripts/events/RLHerdsmanRuleCreateEvent.lua")
source(modDirectory .. "scripts/events/RLHerdsmanRuleUpdateEvent.lua")
source(modDirectory .. "scripts/events/RLHerdsmanRuleDeleteEvent.lua")
source(modDirectory .. "scripts/events/RLHerdsmanRuleStateEvent.lua")

-- SECTION 11i: Herdsman day-tick planner (M-Tick T1). Pure run-order + candidate
-- selection + sequential claim; consumes RLHerdsmanRuleService.OPERATION_ORDER, its
-- comparator and the operation x animalType gate - all from 11h -
-- plus RLFilterEvaluator (11g), RLAnimalUtil (top of file). No game state at load.
source(modDirectory .. "scripts/herdsman/RLHerdsmanPlanner.lua")

-- SECTION 11j: Herdsman day-tick executor (M-Tick T3). Applies the planner's actions in-game
-- (the in-game wall): dispatches the AI sell/buy/insemination events, mutates castrate/naming
-- directly, sets marks for mark-mode, deducts the per-farm wage. References the AI events +
-- RLHerdsmanRuleService only at call time (dependency-injected ctx), so it loads after 11i with
-- no game state at load. Ships DORMANT - no day-tick hook (T4 wires the tick + ctx build).
source(modDirectory .. "scripts/herdsman/RLHerdsmanExecutor.lua")

-- SECTION 11j2: Herdsman day-tick messages (M-Tick T5). The player-notification readout: a pure
-- buildMessages (summary.results -> AI_MANAGER_* records) + a thin emit that drives the server-local
-- addRLMessage sink per husbandry (MP transport now rides the addRLMessageDirect chokepoint's
-- incremental broadcast). References the aggregator only at call time, so it loads after 11j
-- and before the 11k tick that invokes emit.
source(modDirectory .. "scripts/herdsman/RLHerdsmanMessages.lua")

-- SECTION 11k: Herdsman day-tick wiring (M-Tick T4). The tick that fires the planner (11i) ->
-- executor (11j) once per day server-side: a MessageType.DAY_CHANGED subscriber (registered from
-- RealisticLivestock_FSBaseMission:onStartMission) assembles the env from g_* and calls the
-- dual-run run(env). Loads after 11j (consumes both at call time); no game state at load.
source(modDirectory .. "scripts/herdsman/RLHerdsmanDayTick.lua")

-- SECTION 11l: Dealer sale-availability - headless registry. Pure override map
-- (canBeBought per subTypeName+minAge stage) + effective-state resolver; no game
-- state at load. Sourced here so the global class table exists for the in-game
-- rlTest suite; persistence, apply, the selector chain and the MP wire + events
-- follow below in dependency order.
source(modDirectory .. "scripts/dealer/RLDealerSaleRegistry.lua")
-- Flat XML codec for the override map + the shared g_rlDealerSaleRegistry
-- singleton bootstrap. Loads after the registry class it references.
source(modDirectory .. "scripts/dealer/RLDealerSaleSerialization.lua")
-- Apply layer: folds the override registry onto the live store.canBeBought flags
-- (Model A). References RLDealerSaleRegistry (above) at load; RL_ResetDealerEvent
-- only at call time inside applyAndRepopulate, so its later source order is safe.
source(modDirectory .. "scripts/dealer/RLDealerSaleApply.lua")
-- Catalog: live per-open view-model (type/subType/age-stage + buyability) for the
-- sale-availability selector. Pure build(types, deps) + in-game enumerate() shell;
-- reads the live store.canBeBought (no mutation). Binds the RLAnimalUtil +
-- RLFilterFieldDisplay label seams (both sourced earlier) only inside the shell.
source(modDirectory .. "scripts/dealer/RLDealerSaleCatalog.lua")
-- Selector model: pure sectioned checkbox model + result collector (buildSectionModel /
-- buildResult) the sale-availability selector dialog (B2) wraps. Env-free data-in/data-out;
-- sourced here in the dealer group, before the GUI dialog that consumes it (SECTION 13).
source(modDirectory .. "scripts/dealer/RLDealerSaleSelectorModel.lua")
-- Reconcile helper: pure result-vs-catalog diff that resolves the selector's committed
-- set into registry set/clear ops against each stage's shipped default. Env-free
-- data-in/data-out; reaches no sibling dealer module at load or call time.
source(modDirectory .. "scripts/dealer/RLDealerSaleReconcile.lua")
-- Wire codec: one four-field record shape (subTypeName / minAge / isSet / canBeBought)
-- shared by both dealer sale MP events, carrying its own count-prefix framing so the
-- two events cannot drift apart. Pure stream IO; no sibling dealer module at load time.
source(modDirectory .. "scripts/dealer/RLDealerSaleWire.lua")
-- MP events. Both reference the wire codec (above) at load; the State event reaches
-- RLDealerSaleRegistry + RLDealerSaleApply (both above) and the Set event reaches
-- RL_ResetDealerEvent (via applyAndRepopulate) only at CALL time, so its later source
-- order is safe. The Set event's executeOnServer references the State event's
-- broadcaster at call time, so State-before-Set is not required either.
source(modDirectory .. "scripts/events/RLDealerSaleStateEvent.lua")
source(modDirectory .. "scripts/events/RLDealerSaleSetEvent.lua")

-- SECTION 11m: Dealer quality - pure preset model. Preset table (genetics band +
-- price markup + outlier chance) and the reshape math; data-in/data-out, no game
-- state at load. Reads RLConstants (SECTION 2c) at file scope for the genetics
-- domain, so it must load after it. Nothing calls it yet; it is sourced so the
-- global class table exists for the in-game rlTest suite, and the generation and
-- price call sites reach it at CALL time only, which is why its order relative to
-- RealisticLivestock_AnimalSystem and AnimalItemNew does not matter.
source(modDirectory .. "scripts/dealer/RLDealerQualityModel.lua")

-- The active-preset resolver: which preset this machine is on, and the buy-side
-- markup that follows. Sourced after the model because it dereferences
-- RLDealerQualityModel.DEFAULT_INDEX at file scope to seed its log memo; every
-- other reference is at CALL time, so the order is defensive, not load-bearing.
-- Reads RLSettings only through a nil guard, so it loads before settings exist.
source(modDirectory .. "scripts/dealer/RLDealerQualityResolver.lua")

-- SECTION 12: GUI Elements
source(modDirectory .. "scripts/gui/elements/DoubleOptionSliderElement.lua")
source(modDirectory .. "scripts/gui/elements/RenderElement.lua")
source(modDirectory .. "scripts/gui/elements/TripleOptionElement.lua")

-- SECTION 13: GUI Dialogs and Frames
source(modDirectory .. "scripts/gui/VisualAnimalsDialog.lua")
source(modDirectory .. "scripts/gui/NameInputDialog.lua")
source(modDirectory .. "scripts/gui/RealisticLivestockFrame.lua")
source(modDirectory .. "scripts/gui/AnimalAIDialog.lua")
source(modDirectory .. "scripts/gui/AnimalFilterDialog.lua")
source(modDirectory .. "scripts/gui/AnimalMoveDestinationDialog.lua")
source(modDirectory .. "scripts/gui/DiseaseDialog.lua")
source(modDirectory .. "scripts/gui/EarTagColourPickerDialog.lua")
source(modDirectory .. "scripts/gui/RLFilterConditionDialog.lua")
source(modDirectory .. "scripts/gui/RLFilterValueSetDialog.lua")
source(modDirectory .. "scripts/gui/RLHerdsmanFilterPickerDialog.lua")
source(modDirectory .. "scripts/gui/RLHerdsmanHusbandryPickerDialog.lua")
source(modDirectory .. "scripts/gui/RLHerdsmanDestinationPickerDialog.lua")
-- Dealer sale-availability selector dialog (B2): sectioned icon + age-range checkbox list.
-- Thin GUI wiring over the pure RLDealerSaleSelectorModel (sourced in the dealer group above).
source(modDirectory .. "scripts/gui/RLDealerSaleSelectorDialog.lua")
source(modDirectory .. "scripts/gui/FileExplorerDialog.lua")
source(modDirectory .. "scripts/gui/RL_InfoDisplayKeyValueBox.lua")
source(modDirectory .. "scripts/gui/RealisticLivestock_InGameMenuAnimalsFrame.lua")

-- SECTION 13b: RL Tabbed Menu (the standalone TabbedMenu - now the only animal UI)
-- Services must be sourced before frames that call them; frames must be
-- sourced before the menu so FrameReference refs resolve.
source(modDirectory .. "scripts/gui/rlmenu/services/RLMessageService.lua")
source(modDirectory .. "scripts/gui/rlmenu/services/RLAnimalQuery.lua")
source(modDirectory .. "scripts/gui/rlmenu/services/RLGeneticsFormatter.lua")
source(modDirectory .. "scripts/gui/rlmenu/services/RLPenFeedForecast.lua")
source(modDirectory .. "scripts/gui/rlmenu/services/RLAnimalInfoService.lua")
source(modDirectory .. "scripts/gui/rlmenu/services/RLDetailPaneHelper.lua")
-- Shared trade-request guard: one in-flight g_messageCenter request per event
-- class + a cancellable Timer watchdog + single-consume token. Sourced BEFORE the three
-- trade services (Move/Sell/Buy) that route their dispatch through it.
source(modDirectory .. "scripts/gui/rlmenu/services/RLAnimalEventRequest.lua")
-- GUI-local nil-safe selection-key builder: used by the four multi-select frames'
-- selection paths. Pure (delegates to RLAnimalUtil.toKey, SECTION 2b); sourced before the frames.
source(modDirectory .. "scripts/gui/rlmenu/services/RLSelectionKey.lua")
source(modDirectory .. "scripts/gui/rlmenu/services/RLAnimalMoveService.lua")
source(modDirectory .. "scripts/gui/rlmenu/services/RLAnimalSellService.lua")
source(modDirectory .. "scripts/gui/rlmenu/services/RLAnimalBuyService.lua")
source(modDirectory .. "scripts/gui/rlmenu/services/RLDealerQuery.lua")
source(modDirectory .. "scripts/gui/rlmenu/services/RLAIStockService.lua")
-- Trailer endpoint read service (transfer keystone). Stateless reader that
-- wraps the base-game LivestockTrailer getters into transfer primitives; depends on
-- nothing but the trailer passed in. Loaded now but invoked by no shipped path until
-- the M2 transfer frame consumes it.
source(modDirectory .. "scripts/gui/rlmenu/services/RLTrailerEndpointService.lua")
-- Transfer-frame adapter seam. Pure data-in/data-out (no g_*/getText);
-- the headless dual-run boundary. Loaded with the services, before the Transfer
-- frame and RLMenu consume it.
source(modDirectory .. "scripts/gui/rlmenu/services/RLTransferAdapter.lua")
source(modDirectory .. "scripts/gui/rlmenu/services/RLFilterCycleHelper.lua")
source(modDirectory .. "scripts/gui/rlmenu/services/RLFilterChipHelper.lua")
-- Herdsman rule view-model (M-Frame F1). Pure presenter consumed by the Herdsman
-- frame; depends on RLFilterUsage (SECTION 11g) + RLHerdsmanRuleService (SECTION 11h),
-- both sourced above. The service dependency is read at SOURCE TIME and is load-bearing:
-- besides OPERATIONS it copies OPERATION_ORDER and the three public gate
-- names (OPERATION_ANIMAL_TYPES, getDeclaredAnimalTypeNames, isOperationAnimalTypeCompatible)
-- by value at file scope. Sourcing the presenter without the service raises at load.
source(modDirectory .. "scripts/gui/rlmenu/services/RLHerdsmanRulePresenter.lua")
-- Herdsman rule edit-model (M-Frame F4b). Pure overlay-merge + op-change carry-over
-- for the detail pane; depends on RLHerdsmanRulePresenter (above) for the per-operation
-- default params. Consumed by RLMenuHerdsmanFrame (below).
source(modDirectory .. "scripts/gui/rlmenu/services/RLHerdsmanRuleEditModel.lua")
source(modDirectory .. "scripts/gui/rlmenu/frames/RLMenuMessagesFrame.lua")
source(modDirectory .. "scripts/gui/rlmenu/frames/RLMenuInfoFrame.lua")
source(modDirectory .. "scripts/gui/rlmenu/frames/RLMenuMoveFrame.lua")
source(modDirectory .. "scripts/gui/rlmenu/frames/RLMenuSellFrame.lua")
source(modDirectory .. "scripts/gui/rlmenu/frames/RLMenuBuyFrame.lua")
source(modDirectory .. "scripts/gui/rlmenu/frames/RLMenuAIFrame.lua")
source(modDirectory .. "scripts/gui/rlmenu/frames/RLMenuSettingsFrame.lua")
source(modDirectory .. "scripts/gui/rlmenu/frames/RLMenuHerdsmanFrame.lua")
source(modDirectory .. "scripts/gui/rlmenu/frames/RLMenuTransferFrame.lua")
-- Pure tab-visibility + anchor policy (no g_*). Loaded before RLMenu so the
-- RLMenu.MODE_TRAILER / TRAILER_* constants can re-export the policy's values.
source(modDirectory .. "scripts/gui/rlmenu/RLMenuTabPolicy.lua")
-- Pure MODE_FULL husbandry-anchor index resolver (no g_*, load-time inert). The
-- Info/Move/Sell frames (sourced above) reference it at runtime only, so it can
-- load here alongside RLMenuTabPolicy (same pure tier), before RLMenu.
source(modDirectory .. "scripts/gui/rlmenu/RLMenuHusbandryAnchor.lua")
-- Concrete PEN counterpart adapter. In-game tier; registers itself
-- into RLTransferAdapter._adapters[RLMenuTabPolicy.PEN] at load, so it must follow
-- RLMenuTabPolicy (PEN constant) and the services it calls (RLTransferAdapter,
-- RLAnimalQuery, RLAnimalMoveService, all sourced above). No RLMenu dependency.
source(modDirectory .. "scripts/gui/rlmenu/services/RLTransferPenAdapter.lua")
-- WORLD counterpart service + adapter. The service owns the vanilla-
-- cluster -> Animal conversion + the base-game load/unload dispatch; the adapter
-- routes the seam to it and registers into RLTransferAdapter._adapters[RLMenuTabPolicy
-- .WORLD] at load, so both must follow RLMenuTabPolicy (WORLD constant) + RLTransferAdapter
-- (sourced above), and the adapter must follow the service it calls. Animal /
-- AnimalItemStock / AnimalLoadEvent / AnimalUnloadEvent load earlier (base-game / Animal
-- stack). No RLMenu dependency.
-- Codec-only override of base-game AnimalUnloadEvent (string cluster id over the wire);
-- sourced before the world service so the unload dispatch fires the patched event. Base-game
-- AnimalUnloadEvent is already loaded by this point, which the override asserts at load.
source(modDirectory .. "scripts/animals/shop/events/AnimalUnloadEvent.lua")
source(modDirectory .. "scripts/gui/rlmenu/services/RLTrailerWorldService.lua")
source(modDirectory .. "scripts/gui/rlmenu/services/RLTransferWorldAdapter.lua")
-- EPP (butcher) counterpart adapter. In-game sink adapter; registers
-- into RLTransferAdapter._adapters[RLMenuTabPolicy.EPP] at load, so it must follow
-- RLMenuTabPolicy (EPP constant) and the services it calls (RLTransferAdapter,
-- RLAnimalMoveService, RLTrailerEndpointService, all sourced above). No RLMenu dependency.
source(modDirectory .. "scripts/gui/rlmenu/services/RLTransferEppAdapter.lua")
source(modDirectory .. "scripts/gui/rlmenu/RLMenu.lua")
-- Surviving AnimalScreen routing seam. Sourced last in 13b (after RLMenu) so it is the
-- SOLE installer of the AnimalScreen.show + LivestockTrailerActivatable.run overrides and
-- reads RLMenu's constants at load.
source(modDirectory .. "scripts/gui/rlmenu/RLAnimalScreenBridge.lua")

-- SECTION 14: Migration System
source(modDirectory .. "scripts/migration/RmMigrationManager.lua")
source(modDirectory .. "scripts/migration/RmMigrationDialog.lua")
source(modDirectory .. "scripts/migration/RmItemSystemMigration.lua")

-- SECTION 15: Hand Tools
source(modDirectory .. "scripts/handTools/specializations/HandToolHorseBrush.lua")
source(modDirectory .. "scripts/handTools/HandTool.lua")
source(modDirectory .. "scripts/handTools/HandToolSystem.lua")
source(modDirectory .. "scripts/handTools/RLHandTools.lua")

-- SECTION 16: Insemination - Dewar (DewarData specialization and rlDewar vehicle type registered in Lua)
source(modDirectory .. "scripts/insemination/DewarMigration.lua")
source(modDirectory .. "scripts/insemination/DewarTypeRegistration.lua")
source(modDirectory .. "scripts/insemination/DewarObjectStorageHook.lua")

-- SECTION 17: Placeables
source(modDirectory .. "scripts/placeables/RealisticLivestock_PlaceableSystem.lua")

-- SECTION 18: Player
source(modDirectory .. "scripts/player/RealisticLivestock_PlayerHUDUpdater.lua")
source(modDirectory .. "scripts/player/RealisticLivestock_PlayerInputComponent.lua")

-- SECTION 19: Vehicles
source(modDirectory .. "scripts/vehicles/specializations/RealisticLivestock_LivestockTrailer.lua")
source(modDirectory .. "scripts/vehicles/specializations/Rideable.lua")
source(modDirectory .. "scripts/vehicles/RealisticLivestock_VehicleSystem.lua")

-- SECTION 20b: Insemination (dewar/straw infrastructure)
source(modDirectory .. "scripts/insemination/AIStrawUpdater.lua")

-- SECTION 20c: Events (general lifecycle events)
source(modDirectory .. "scripts/events/AnimalBirthEvent.lua")
source(modDirectory .. "scripts/events/AnimalDeathEvent.lua")
source(modDirectory .. "scripts/events/AnimalCastrateEvent.lua")
source(modDirectory .. "scripts/events/AnimalMarkEvent.lua")
source(modDirectory .. "scripts/events/AnimalMonitorEvent.lua")
source(modDirectory .. "scripts/events/AnimalNameChangeEvent.lua")
source(modDirectory .. "scripts/events/AnimalPregnancyEvent.lua")
source(modDirectory .. "scripts/events/AnimalUpdateEvent.lua")
source(modDirectory .. "scripts/events/RL_BroadcastSettingsEvent.lua")
source(modDirectory .. "scripts/events/RL_ResetDealerEvent.lua")

-- SECTION 20d: Insemination (dewar manager)
source(modDirectory .. "scripts/insemination/DewarManager.lua")

-- SECTION 20e: Disease
-- The rate primitive first: it is pure arithmetic with no dependency of its own,
-- and it precedes the entities that will consume it.
source(modDirectory .. "scripts/disease/RLDiseaseRates.lua")
-- The SEIR record next, and its position AHEAD of the parser is REQUIRED, not
-- stylistic: it owns the endpoint vocabulary and RLDiseaseDefinition reads
-- RLDiseaseRecord.ENDPOINT at FILE SCOPE, so sourcing the parser first raises on a
-- nil global and takes RLDiseaseDefinition.parse down with it. Nothing in the
-- headless tier can catch a mistake here - that env sources the record itself - so
-- this line's position is in-game-only coverage. RmLogging from SECTION 0 stays its
-- only dependency.
source(modDirectory .. "scripts/disease/RLDiseaseRecord.lua")
-- The definition parser then: DiseaseManager reaches it at CALL time from
-- loadDiseases, which runs inside DiseaseManager.new(), so it only has to precede
-- the construction below rather than the manager's own source line - but it must
-- follow the record above.
source(modDirectory .. "scripts/disease/RLDiseaseDefinition.lua")
-- The vulnerability factor is the third pure primitive, and it reads RLConstants
-- at file scope, so it has to follow SECTION 2c. Like the rate primitive it
-- precedes the entities that will consume it.
source(modDirectory .. "scripts/disease/RLDiseaseVulnerability.lua")
-- The fatality hazard last of the pure primitives. It reads RLDiseaseRates and
-- RLDiseaseRecord at CALL time only - no file-scope capture of either - which is
-- precisely WHY this position is ordinary rather than required: the file-scope read
-- that forces the record ahead of the parser above has no counterpart here. It still
-- precedes the entities that will consume it, like its three siblings.
source(modDirectory .. "scripts/disease/RLDiseaseFatality.lua")
source(modDirectory .. "scripts/disease/Disease.lua")
source(modDirectory .. "scripts/disease/DiseaseManager.lua")

-- SECTION 20f: Core (lifecycle, settings, i18n)
source(modDirectory .. "scripts/core/FSCareerMissionInfo.lua")
source(modDirectory .. "scripts/core/I18N.lua")
source(modDirectory .. "scripts/core/RealisticLivestock.lua")

-- SECTION 20g: Animal entity
source(modDirectory .. "scripts/animal/RealisticLivestock_Animal.lua")

-- SECTION 20h: Core (FS base mission hooks)
source(modDirectory .. "scripts/core/RealisticLivestock_FSBaseMission.lua")

-- SECTION 20i: Console commands
source(modDirectory .. "scripts/console/RLConsoleCommandManager.lua")

-- SECTION 20j: Messaging
source(modDirectory .. "scripts/messaging/RLMessage.lua")
source(modDirectory .. "scripts/messaging/RLMessageAggregator.lua")

-- SECTION 20k: Core (settings)
source(modDirectory .. "scripts/core/RLSettings.lua")
source(modDirectory .. "scripts/utils/RLDebugUtils.lua")

-- =============================================================================
-- RL Tabbed Menu: install hooks (end-of-file, after all sources are loaded).
-- RLMenu.install() appends hooks onto PlayerInputComponent and RealisticLivestock.loadMap.
-- setupGui runs AFTER loadMap so rlExtra texture config is available; see RLMenu.install() docs.
-- =============================================================================

RLMenu.install()

-- =============================================================================
-- TESTING (conditional - delete tests/ folder for production)
-- =============================================================================

local testRunnerPath = modDirectory .. "scripts/tests/RLTestRunner.lua"
if fileExists(testRunnerPath) then
    source(testRunnerPath)
end
