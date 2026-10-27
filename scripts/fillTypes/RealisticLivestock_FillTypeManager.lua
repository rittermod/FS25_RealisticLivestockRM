RealisticLivestock_FillTypeManager = {}

local Log = RmLogging.getLogger("RLRM")

local modDir = g_currentModDirectory
local modName = g_currentModName

if FillTypeManager.SEND_NUM_BITS < 10 then FillTypeManager.SEND_NUM_BITS = 10 end


--- Load the fill-type file of every DLC bundle whose DLC is active, after RLRM's own fill types.
---@return nil
function RealisticLivestock_FillTypeManager.loadDlcBundleFillTypes()

    for _, bundle in ipairs(RLAnimalTypeSupport.DLC_BUNDLES) do

        if not RLAnimalTypeSupport.isDlcActive(g_modIsLoaded, g_uniqueDlcNamePrefix, bundle.dlc) then
            Log:debug("FillTypeManager: DLC '%s' not active, skipping '%s'", tostring(bundle.dlc),
                tostring(bundle.fillTypesFile))
        else
            local path = modDir .. bundle.fillTypesFile
            local xml = fileExists(path) and loadXMLFile("fillTypes", path) or nil

            if xml == nil or xml == 0 then
                Log:warning("FillTypeManager: DLC '%s' is active but '%s' did not load; its fill types are missing",
                    tostring(bundle.dlc), tostring(path))
            else
                g_fillTypeManager:loadFillTypes(xml, modDir, false, modName)
                delete(xml)
                Log:info("FillTypeManager: loaded '%s' for DLC '%s'", tostring(bundle.fillTypesFile),
                    tostring(bundle.dlc))
            end
        end

    end

end


--- Load RLRM's fill types, the active DLC bundles' fill types, then the map bridge's (appended to loadMapData).
---@param xmlFile table|nil the map's fill-type XML (unused)
---@param missionInfo table|nil the mission info (unused)
---@param baseDir string|nil the map's base directory (unused)
---@return nil
function RealisticLivestock_FillTypeManager.loadFillTypes(xmlFile, missionInfo, baseDir)

    local xml = loadXMLFile("fillTypes", modDir .. "xml/fillTypes.xml")
    g_fillTypeManager:loadFillTypes(xml, modDir , false, modName)

    RealisticLivestock_FillTypeManager.loadDlcBundleFillTypes()

    -- Load bridge fill types for detected maps (must happen before AnimalSystem.loadMapData)
    RLMapBridge.loadBridgeFillTypes()

end

FillTypeManager.loadMapData = Utils.appendedFunction(FillTypeManager.loadMapData, RealisticLivestock_FillTypeManager.loadFillTypes)
