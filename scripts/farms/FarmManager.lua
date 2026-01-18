RL_FarmManager = {}


function RL_FarmManager:loadFromXMLFile(superFunc, path)

    print("RL_FarmManager: loadFromXMLFile called")

    -- Initialize migration manager and check for conflicts/migration needs (server only)
    -- NOTE: Early migration (items.xml, handTools.xml) is now handled by RmItemSystemMigration
    -- which hooks into ItemSystem.loadItems and runs BEFORE items are loaded.
    -- Here we only check for mod conflicts and set flags for showing dialogs.
    if g_currentMission:getIsServer() then
        print("RL_FarmManager: Running on server, checking migration state...")

        -- Create migration manager instance if not already created by RmItemSystemMigration
        if g_rmMigrationManager == nil then
            print("RL_FarmManager: Creating RmMigrationManager instance")
            g_rmMigrationManager = RmMigrationManager.new()
        end

        -- Check for mod conflict (both old and new mod installed)
        if g_rmMigrationManager:checkModConflict() then
            -- Conflict detected - will show dialog in onStartMission
            print("RL_FarmManager: Conflict detected!")
            g_rmMigrationConflict = true
        elseif not g_rmPendingMigration and g_rmMigrationManager:shouldMigrate() then
            -- Migration needed but wasn't handled by RmItemSystemMigration (shouldn't happen normally)
            -- This is a fallback in case ItemSystem hook didn't run
            print("RL_FarmManager: Migration needed (fallback path)!")
            g_rmPendingMigration = true
        else
            print("RL_FarmManager: No conflict detected, migration state = " .. tostring(g_rmPendingMigration))
        end

        print("RL_FarmManager: g_rmMigrationConflict = " .. tostring(g_rmMigrationConflict))
        print("RL_FarmManager: g_rmPendingMigration = " .. tostring(g_rmPendingMigration))
    else
        print("RL_FarmManager: Not running on server, skipping migration check")
    end

    local returnValue = superFunc(self, path)

    local animalSystem = g_currentMission.animalSystem
    animalSystem:initialiseCountries()

    if g_currentMission:getIsServer() then
        local hasData = animalSystem:loadFromXMLFile()
        animalSystem:validateFarms(hasData)
    end

    return returnValue

end

FarmManager.loadFromXMLFile = Utils.overwrittenFunction(FarmManager.loadFromXMLFile, RL_FarmManager.loadFromXMLFile)