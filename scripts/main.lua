--[[
    main.lua
    Main loader for RealisticLivestockRM mod.
    Loads all dependencies in the correct order.

    IMPORTANT: The loading order is critical - do not reorder without testing.
    Author: Ritter (based on Arrow-kb's Realistic Livestock)
]]

local modDirectory = g_currentModDirectory

-- SECTION 1: Font Library
source(modDirectory .. "scripts/fontlib/RmFontCharacter.lua")
source(modDirectory .. "scripts/fontlib/RmFontManager.lua")

-- SECTION 2: GUI Loading Screen
source(modDirectory .. "scripts/gui/MPLoadingScreen.lua")

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
source(modDirectory .. "scripts/animals/husbandry/AnimalSystemStateEvent.lua")
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
source(modDirectory .. "scripts/events/DewarManagerStateEvent.lua")
source(modDirectory .. "scripts/events/HusbandryMessageStateEvent.lua")
source(modDirectory .. "scripts/events/ReturnStrawEvent.lua")

-- SECTION 10: Farms
source(modDirectory .. "scripts/farms/FarmManager.lua")
source(modDirectory .. "scripts/farms/RealisticLivestock_FarmStats.lua")

-- SECTION 11: Fill Types
source(modDirectory .. "scripts/fillTypes/RealisticLivestock_FillTypeManager.lua")

-- SECTION 11b: Breeding Mathematics
source(modDirectory .. "scripts/BreedingMath.lua")

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
source(modDirectory .. "scripts/gui/AnimalInfoDialog.lua")
source(modDirectory .. "scripts/gui/DiseaseDialog.lua")
source(modDirectory .. "scripts/gui/EarTagColourPickerDialog.lua")
source(modDirectory .. "scripts/gui/FileExplorerDialog.lua")
source(modDirectory .. "scripts/gui/InGameMenuSettingsFrame.lua")
source(modDirectory .. "scripts/gui/ProfileDialog.lua")
source(modDirectory .. "scripts/gui/RL_InfoDisplayKeyValueBox.lua")
source(modDirectory .. "scripts/gui/RealisticLivestock_InGameMenuAnimalsFrame.lua")

-- SECTION 14: Migration System
source(modDirectory .. "scripts/migration/RmMigrationManager.lua")
source(modDirectory .. "scripts/migration/RmMigrationDialog.lua")
source(modDirectory .. "scripts/migration/RmItemSystemMigration.lua")

-- SECTION 15: Hand Tools
source(modDirectory .. "scripts/handTools/specializations/HandToolHorseBrush.lua")
source(modDirectory .. "scripts/handTools/HandTool.lua")
source(modDirectory .. "scripts/handTools/HandToolSystem.lua")
source(modDirectory .. "scripts/handTools/RLHandTools.lua")

-- SECTION 16: Objects
source(modDirectory .. "scripts/objects/Dewar.lua")

-- SECTION 17: Placeables
source(modDirectory .. "scripts/placeables/RealisticLivestock_PlaceableSystem.lua")

-- SECTION 18: Player
source(modDirectory .. "scripts/player/RealisticLivestock_PlayerHUDUpdater.lua")
source(modDirectory .. "scripts/player/RealisticLivestock_PlayerInputComponent.lua")

-- SECTION 19: Vehicles
source(modDirectory .. "scripts/vehicles/specializations/RealisticLivestock_LivestockTrailer.lua")
source(modDirectory .. "scripts/vehicles/specializations/Rideable.lua")
source(modDirectory .. "scripts/vehicles/RealisticLivestock_VehicleSystem.lua")

-- SECTION 20: Core Mod Files
source(modDirectory .. "scripts/AIAnimalManager.lua")
source(modDirectory .. "scripts/AIStrawUpdater.lua")
source(modDirectory .. "scripts/AnimalBirthEvent.lua")
source(modDirectory .. "scripts/AnimalDeathEvent.lua")
source(modDirectory .. "scripts/AnimalMonitorEvent.lua")
source(modDirectory .. "scripts/AnimalNameChangeEvent.lua")
source(modDirectory .. "scripts/AnimalPregnancyEvent.lua")
source(modDirectory .. "scripts/AnimalUpdateEvent.lua")
source(modDirectory .. "scripts/DewarManager.lua")
source(modDirectory .. "scripts/Disease.lua")
source(modDirectory .. "scripts/DiseaseManager.lua")
source(modDirectory .. "scripts/FSCareerMissionInfo.lua")
source(modDirectory .. "scripts/I18N.lua")
source(modDirectory .. "scripts/RealisticLivestock.lua")
source(modDirectory .. "scripts/RealisticLivestock_Animal.lua")
source(modDirectory .. "scripts/RealisticLivestock_FSBaseMission.lua")
source(modDirectory .. "scripts/RLConsoleCommandManager.lua")
source(modDirectory .. "scripts/RLMessage.lua")
source(modDirectory .. "scripts/RLSettings.lua")
source(modDirectory .. "scripts/RL_BroadcastSettingsEvent.lua")
