--[[
    main.lua
    The mod loader. Source order is load-bearing wherever a module reads a sibling at
    file scope; those lines say so, and the rest are free.
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

-- SECTION 1: Font Library
source(modDirectory .. "scripts/fontlib/RmFontCharacter.lua")
source(modDirectory .. "scripts/fontlib/RmFontManager.lua")

-- SECTION 2: GUI Loading Screen
source(modDirectory .. "scripts/gui/MPLoadingScreen.lua")

-- SECTION 2b: Utilities
source(modDirectory .. "scripts/utils/RmSafeUtils.lua")
source(modDirectory .. "scripts/utils/RLAnimalUtil.lua")
source(modDirectory .. "scripts/utils/RLPermissionHelper.lua")
source(modDirectory .. "scripts/utils/RLScaleHelper.lua")
source(modDirectory .. "scripts/utils/RLAnimalDisplayHelper.lua")
source(modDirectory .. "scripts/utils/RLMoveDestinationHelper.lua")
source(modDirectory .. "scripts/utils/RLTimeFormat.lua")

-- SECTION 2c: Constants
source(modDirectory .. "scripts/core/RLConstants.lua")

-- SECTION 2d: Map country resolution (needs RLConstants)
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
source(modDirectory .. "scripts/animal/RLGeneticsDraw.lua")
-- Reads RLConstants at file scope, so it must follow SECTION 2c; a consumer binding one of
-- its re-exported tables at file scope must follow this line.
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
-- Depends on RLFilterUsage (above) and RLScaleHelper (SECTION 2b).
source(modDirectory .. "scripts/utils/RLQuickFilterToSavedFilter.lua")

-- SECTION 11h: Herdsman Rules - headless service + persistence + MP events
-- Serializer before service: the service's save/loadFromXMLFile call into it.
-- RLHusbandryTargetKey first - the wire and its consumers key targets through it
-- (uniqueId on the server, net-object-id on a pure client).
source(modDirectory .. "scripts/herdsman/RLHusbandryTargetKey.lua")
source(modDirectory .. "scripts/herdsman/RLHerdsmanRuleSerialization.lua")
source(modDirectory .. "scripts/herdsman/RLHerdsmanRuleService.lua")
source(modDirectory .. "scripts/herdsman/RLHerdsmanRuleWire.lua")
source(modDirectory .. "scripts/events/RLHerdsmanRuleCreateEvent.lua")
source(modDirectory .. "scripts/events/RLHerdsmanRuleUpdateEvent.lua")
source(modDirectory .. "scripts/events/RLHerdsmanRuleDeleteEvent.lua")
source(modDirectory .. "scripts/events/RLHerdsmanRuleStateEvent.lua")

-- SECTION 11i: Herdsman day-tick planner - run order, candidate selection, sequential claim
source(modDirectory .. "scripts/herdsman/RLHerdsmanPlanner.lua")

-- SECTION 11j: Herdsman day-tick executor - applies the planner's actions in-game
source(modDirectory .. "scripts/herdsman/RLHerdsmanExecutor.lua")

-- SECTION 11j2: Herdsman day-tick messages - the player-notification readout
source(modDirectory .. "scripts/herdsman/RLHerdsmanMessages.lua")

-- SECTION 11k: Herdsman day-tick wiring - fires planner then executor once per day, server-side
source(modDirectory .. "scripts/herdsman/RLHerdsmanDayTick.lua")

-- SECTION 11l: Dealer sale-availability. Registry first - the serializer and the apply layer
-- both reference it at load, and the wire codec must precede the two events below.
source(modDirectory .. "scripts/dealer/RLDealerSaleRegistry.lua")
source(modDirectory .. "scripts/dealer/RLDealerSaleSerialization.lua")
source(modDirectory .. "scripts/dealer/RLDealerSaleApply.lua")
source(modDirectory .. "scripts/dealer/RLDealerSaleCatalog.lua")
source(modDirectory .. "scripts/dealer/RLDealerSaleSelectorModel.lua")
source(modDirectory .. "scripts/dealer/RLDealerSaleReconcile.lua")
source(modDirectory .. "scripts/dealer/RLDealerSaleWire.lua")
source(modDirectory .. "scripts/events/RLDealerSaleStateEvent.lua")
source(modDirectory .. "scripts/events/RLDealerSaleSetEvent.lua")

-- SECTION 11m: Dealer quality presets. Reads RLConstants at file scope for the genetics
-- domain, so it must follow SECTION 2c.
source(modDirectory .. "scripts/dealer/RLDealerQualityModel.lua")

-- Dereferences RLDealerQualityModel.DEFAULT_INDEX at file scope, so it must follow the model.
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
source(modDirectory .. "scripts/gui/RLDealerSaleSelectorDialog.lua")
source(modDirectory .. "scripts/gui/FileExplorerDialog.lua")
source(modDirectory .. "scripts/gui/RL_InfoDisplayKeyValueBox.lua")
source(modDirectory .. "scripts/gui/RealisticLivestock_InGameMenuAnimalsFrame.lua")

-- SECTION 13b: RL Tabbed Menu. Services before the frames that call them; frames before the
-- menu, so FrameReference refs resolve.
source(modDirectory .. "scripts/gui/rlmenu/services/RLMessageService.lua")
source(modDirectory .. "scripts/gui/rlmenu/services/RLAnimalQuery.lua")
source(modDirectory .. "scripts/gui/rlmenu/services/RLGeneticsFormatter.lua")
source(modDirectory .. "scripts/gui/rlmenu/services/RLPenFeedForecast.lua")
source(modDirectory .. "scripts/gui/rlmenu/services/RLAnimalInfoService.lua")
source(modDirectory .. "scripts/gui/rlmenu/services/RLDetailPaneHelper.lua")
-- The shared trade-request guard, before the three trade services that dispatch through it.
source(modDirectory .. "scripts/gui/rlmenu/services/RLAnimalEventRequest.lua")
source(modDirectory .. "scripts/gui/rlmenu/services/RLSelectionKey.lua")
source(modDirectory .. "scripts/gui/rlmenu/services/RLAnimalMoveService.lua")
source(modDirectory .. "scripts/gui/rlmenu/services/RLAnimalSellService.lua")
source(modDirectory .. "scripts/gui/rlmenu/services/RLAnimalBuyService.lua")
source(modDirectory .. "scripts/gui/rlmenu/services/RLDealerQuery.lua")
source(modDirectory .. "scripts/gui/rlmenu/services/RLAIStockService.lua")
source(modDirectory .. "scripts/gui/rlmenu/services/RLTrailerEndpointService.lua")
-- The transfer adapter seam, before the three counterpart adapters that register into it.
source(modDirectory .. "scripts/gui/rlmenu/services/RLTransferAdapter.lua")
source(modDirectory .. "scripts/gui/rlmenu/services/RLFilterCycleHelper.lua")
source(modDirectory .. "scripts/gui/rlmenu/services/RLFilterChipHelper.lua")
-- Copies RLHerdsmanRuleService's operation tables and gate names by value at file scope,
-- so it must follow SECTION 11h; sourcing it without the service raises at load.
source(modDirectory .. "scripts/gui/rlmenu/services/RLHerdsmanRulePresenter.lua")
-- Reads the presenter's per-operation defaults, so it must follow it.
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
-- Before RLMenu, whose MODE_TRAILER / TRAILER_* constants re-export the policy's values.
source(modDirectory .. "scripts/gui/rlmenu/RLMenuTabPolicy.lua")
source(modDirectory .. "scripts/gui/rlmenu/RLMenuHusbandryAnchor.lua")
-- The three counterpart adapters register into RLTransferAdapter._adapters at load, keyed by
-- an RLMenuTabPolicy constant, so both must precede them. The AnimalUnloadEvent codec
-- override precedes the world service so the unload dispatch fires the patched event.
source(modDirectory .. "scripts/gui/rlmenu/services/RLTransferPenAdapter.lua")
source(modDirectory .. "scripts/animals/shop/events/AnimalUnloadEvent.lua")
source(modDirectory .. "scripts/gui/rlmenu/services/RLTrailerWorldService.lua")
source(modDirectory .. "scripts/gui/rlmenu/services/RLTransferWorldAdapter.lua")
source(modDirectory .. "scripts/gui/rlmenu/services/RLTransferEppAdapter.lua")
source(modDirectory .. "scripts/gui/rlmenu/RLMenu.lua")
-- Last in 13b: the sole installer of the AnimalScreen.show and LivestockTrailerActivatable.run
-- overrides, and it reads RLMenu's constants at load.
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

-- SECTION 20e: Disease. The pure tier first, then the entities that consume it.
source(modDirectory .. "scripts/disease/RLDiseaseRates.lua")
-- Must precede the parser: RLDiseaseDefinition reads RLDiseaseRecord.ENDPOINT at file scope,
-- so sourcing the parser first raises on a nil global. The headless env sources the record
-- itself, so only the in-game run covers this ordering.
source(modDirectory .. "scripts/disease/RLDiseaseRecord.lua")
source(modDirectory .. "scripts/disease/RLDiseaseDefinition.lua")
-- Reads RLConstants at file scope, so it must follow SECTION 2c.
source(modDirectory .. "scripts/disease/RLDiseaseVulnerability.lua")
source(modDirectory .. "scripts/disease/RLDiseaseFatality.lua")
source(modDirectory .. "scripts/disease/RLDiseaseTransmission.lua")
source(modDirectory .. "scripts/disease/RLDiseaseSpread.lua")
source(modDirectory .. "scripts/disease/RLDiseaseEffects.lua")
source(modDirectory .. "scripts/disease/RLDiseaseProgression.lua")
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
-- RL Tabbed Menu: install hooks, after every source above has loaded.
-- =============================================================================

RLMenu.install()

-- =============================================================================
-- TESTING (conditional - delete tests/ folder for production)
-- =============================================================================

local testRunnerPath = modDirectory .. "scripts/tests/RLTestRunner.lua"
if fileExists(testRunnerPath) then
    source(testRunnerPath)
end
