--[[
    main.lua
    Main loader for RealisticLivestockRM mod.
    Loads all dependencies in the correct order.

    IMPORTANT: The loading order is critical - do not reorder without testing.
    Author: Ritter (based on Arrow-kb's Realistic Livestock)
]]

local modDirectory = g_currentModDirectory

-- SECTION 0: Logging
source(modDirectory .. "scripts/rmlib/RmLogging.lua")
Log = RmLogging.getLogger("RLRM")
Log:setLevel(RmLogging.LOG_LEVEL.DEBUG)

-- SECTION 1: Font Library
source(modDirectory .. "scripts/fontlib/RmFontCharacter.lua")
source(modDirectory .. "scripts/fontlib/RmFontManager.lua")

-- SECTION 2: GUI Loading Screen
source(modDirectory .. "scripts/gui/MPLoadingScreen.lua")

-- SECTION 2b: Utilities
source(modDirectory .. "scripts/utils/RmSafeUtils.lua")
source(modDirectory .. "scripts/utils/RLAnimalUtil.lua")
source(modDirectory .. "scripts/utils/RLScaleHelper.lua")

-- SECTION 2c: Constants
source(modDirectory .. "scripts/core/RLConstants.lua")

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

-- SECTION 6: Animal Shop - Controllers
source(modDirectory .. "scripts/animals/shop/controllers/AnimalScreenBase.lua")
source(modDirectory .. "scripts/animals/shop/controllers/AnimalScreenDealer.lua")
source(modDirectory .. "scripts/animals/shop/controllers/AnimalScreenDealerFarm.lua")
source(modDirectory .. "scripts/animals/shop/controllers/AnimalScreenDealerTrailer.lua")
source(modDirectory .. "scripts/animals/shop/controllers/AnimalScreenTrailer.lua")
source(modDirectory .. "scripts/animals/shop/controllers/AnimalScreenTrailerFarm.lua")
source(modDirectory .. "scripts/animals/shop/controllers/AnimalScreenMoveFarm.lua")

-- SECTION 7: Animal Shop - Events
source(modDirectory .. "scripts/animals/shop/events/AIAnimalBuyEvent.lua")
source(modDirectory .. "scripts/animals/shop/events/AIAnimalInseminationEvent.lua")
source(modDirectory .. "scripts/animals/shop/events/AIAnimalSellEvent.lua")
source(modDirectory .. "scripts/animals/shop/events/AIBulkMessageEvent.lua")
source(modDirectory .. "scripts/animals/shop/events/AnimalBuyEvent.lua")
source(modDirectory .. "scripts/animals/shop/events/AnimalInseminationEvent.lua")
source(modDirectory .. "scripts/animals/shop/events/AnimalInseminationResultEvent.lua")
source(modDirectory .. "scripts/animals/shop/events/AnimalMoveEvent.lua")
source(modDirectory .. "scripts/animals/shop/events/AnimalSellEvent.lua")
source(modDirectory .. "scripts/animals/shop/events/SemenBuyEvent.lua")

-- SECTION 8: Animal Shop - Core
source(modDirectory .. "scripts/animals/shop/AnimalItemNew.lua")
source(modDirectory .. "scripts/animals/shop/RealisticLivestock_AnimalItemStock.lua")

-- SECTION 9: Events (General)
source(modDirectory .. "scripts/events/HusbandryMessageStateEvent.lua")
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

-- SECTION 11c: Horse Logic (delegate module, sourced before Animal.lua)
source(modDirectory .. "scripts/animal/AnimalHorse.lua")

-- SECTION 11d: Reproduction Logic (delegate module, sourced before Animal.lua)
source(modDirectory .. "scripts/animal/AnimalReproduction.lua")

-- SECTION 11e: Health/Death Logic (delegate module, sourced before Animal.lua)
source(modDirectory .. "scripts/animal/AnimalHealth.lua")

-- SECTION 11f: Persistence & Serialization (delegate modules, sourced before Animal.lua)
source(modDirectory .. "scripts/animal/AnimalPersistence.lua")
source(modDirectory .. "scripts/animal/AnimalSerialization.lua")

-- SECTION 11g: Saveable Filters - headless service + MP events (Phase 0)
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

-- SECTION 11h: Herdsman Rules - headless service + persistence (M-Service S1-S2)
-- In-memory rule registry (sibling of RLFilterService). Serializer before
-- service (mirrors 11g): the service's saveToXMLFile/loadFromXMLFile call into
-- RLHerdsmanRuleSerialization. MP events (S3-S5) append here in later slices.
source(modDirectory .. "scripts/herdsman/RLHerdsmanRuleSerialization.lua")
source(modDirectory .. "scripts/herdsman/RLHerdsmanRuleService.lua")

-- SECTION 12: GUI Elements
source(modDirectory .. "scripts/gui/elements/DoubleOptionSliderElement.lua")
source(modDirectory .. "scripts/gui/elements/RenderElement.lua")
source(modDirectory .. "scripts/gui/elements/TripleOptionElement.lua")

-- SECTION 13: GUI Dialogs and Frames
source(modDirectory .. "scripts/gui/RealisticLivestock_AnimalScreen.lua")
source(modDirectory .. "scripts/gui/VisualAnimalsDialog.lua")
source(modDirectory .. "scripts/gui/NameInputDialog.lua")
source(modDirectory .. "scripts/gui/RealisticLivestockFrame.lua")
source(modDirectory .. "scripts/gui/AnimalAIDialog.lua")
source(modDirectory .. "scripts/gui/AnimalFilterDialog.lua")
source(modDirectory .. "scripts/gui/AnimalMoveDestinationDialog.lua")
source(modDirectory .. "scripts/gui/AnimalInfoDialog.lua")
source(modDirectory .. "scripts/gui/DiseaseDialog.lua")
source(modDirectory .. "scripts/gui/EarTagColourPickerDialog.lua")
source(modDirectory .. "scripts/gui/RLFilterConditionDialog.lua")
source(modDirectory .. "scripts/gui/RLFilterValueSetDialog.lua")
source(modDirectory .. "scripts/gui/FileExplorerDialog.lua")
source(modDirectory .. "scripts/gui/InGameMenuSettingsFrame.lua")
source(modDirectory .. "scripts/gui/ProfileDialog.lua")
source(modDirectory .. "scripts/gui/RL_InfoDisplayKeyValueBox.lua")
source(modDirectory .. "scripts/gui/RealisticLivestock_InGameMenuAnimalsFrame.lua")

-- SECTION 13b: RL Tabbed Menu (new standalone TabbedMenu - migration in progress)
-- Services must be sourced before frames that call them; frames must be
-- sourced before the menu so FrameReference refs resolve.
source(modDirectory .. "scripts/gui/rlmenu/services/RLMessageService.lua")
source(modDirectory .. "scripts/gui/rlmenu/services/RLAnimalQuery.lua")
source(modDirectory .. "scripts/gui/rlmenu/services/RLGeneticsFormatter.lua")
source(modDirectory .. "scripts/gui/rlmenu/services/RLPenFeedForecast.lua")
source(modDirectory .. "scripts/gui/rlmenu/services/RLAnimalInfoService.lua")
source(modDirectory .. "scripts/gui/rlmenu/services/RLDetailPaneHelper.lua")
source(modDirectory .. "scripts/gui/rlmenu/services/RLAnimalMoveService.lua")
source(modDirectory .. "scripts/gui/rlmenu/services/RLAnimalSellService.lua")
source(modDirectory .. "scripts/gui/rlmenu/services/RLAnimalBuyService.lua")
source(modDirectory .. "scripts/gui/rlmenu/services/RLDealerQuery.lua")
source(modDirectory .. "scripts/gui/rlmenu/services/RLAIStockService.lua")
source(modDirectory .. "scripts/gui/rlmenu/services/RLFilterCycleHelper.lua")
source(modDirectory .. "scripts/gui/rlmenu/services/RLFilterChipHelper.lua")
source(modDirectory .. "scripts/gui/rlmenu/frames/RLMenuMessagesFrame.lua")
source(modDirectory .. "scripts/gui/rlmenu/frames/RLMenuInfoFrame.lua")
source(modDirectory .. "scripts/gui/rlmenu/frames/RLMenuMoveFrame.lua")
source(modDirectory .. "scripts/gui/rlmenu/frames/RLMenuSellFrame.lua")
source(modDirectory .. "scripts/gui/rlmenu/frames/RLMenuBuyFrame.lua")
source(modDirectory .. "scripts/gui/rlmenu/frames/RLMenuAIFrame.lua")
source(modDirectory .. "scripts/gui/rlmenu/frames/RLMenuSettingsFrame.lua")
source(modDirectory .. "scripts/gui/rlmenu/RLMenu.lua")

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

-- SECTION 20a: Herdsman (automated herd management)
source(modDirectory .. "scripts/herdsman/AIAnimalManager.lua")

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
