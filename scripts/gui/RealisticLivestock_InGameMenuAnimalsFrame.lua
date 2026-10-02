local Log = RmLogging.getLogger("RLRM")

RealisticLivestock_InGameMenuAnimalsFrame = {}


local function computeAvgGenetics(animal)
    local genetics = animal.genetics
    if genetics == nil or type(genetics) ~= "table" then return 0 end
    local total = 0
    local count = 0
    for _, value in pairs(genetics) do
        if value ~= nil then
            total = total + value
            count = count + 1
        end
    end
    return count > 0 and (total / count) or 0
end


local function sortRawAnimals(a, b)
    local aDisease = a:getHasAnyDisease()
    local bDisease = b:getHasAnyDisease()
    if aDisease and not bDisease then return true end
    if bDisease and not aDisease then return false end

    local sortByGenetics = RLSettings.SETTINGS.sortByGenetics
    if sortByGenetics ~= nil and sortByGenetics.state == 2 then
        local aGen = computeAvgGenetics(a)
        local bGen = computeAvgGenetics(b)
        if aGen ~= bGen then return aGen > bGen end
    end

    return a.age < b.age
end


--- Resolve the animal object at the list's current selection indices.
--- Must be called while husbandrySubTypes/subTypeIndexToClusters still hold the
--- data that matches the list's selectedSectionIndex/selectedIndex.
local function getSelectedAnimal(frame)
    local list = frame.list
    local section = list.selectedSectionIndex
    local index = list.selectedIndex
    if section == nil or index == nil then return nil end

    local subTypes = frame.husbandrySubTypes
    if subTypes == nil or subTypes[section] == nil then return nil end

    local subType = subTypes[section]
    local animals = frame.subTypeIndexToClusters[subType]
    if animals == nil or animals[index] == nil then return nil end

    return animals[index]
end


--- Find an animal's (section, index) position in the current sorted data.
local function findAnimalPosition(frame, animal)
    if animal == nil then return nil, nil end

    for sectionIdx, subType in ipairs(frame.husbandrySubTypes) do
        local animals = frame.subTypeIndexToClusters[subType]
        if animals ~= nil then
            for animalIdx, candidate in ipairs(animals) do
                if RLAnimalUtil.compare(candidate, animal) then
                    return sectionIdx, animalIdx
                end
            end
        end
    end

    return nil, nil
end


--- Count the frame's HUSBANDRY_ANIMALS_CHANGED subscriptions: 1 while the page is open, 0 once closed.
--- @param frame table the in-game menu's Animals page
--- @return integer count
function RealisticLivestock_InGameMenuAnimalsFrame.countDataChangedSubscriptions(frame)
    local byType = g_messageCenter.subscribers or {}
    local count = 0
    for _, info in ipairs(byType[MessageType.HUSBANDRY_ANIMALS_CHANGED] or {}) do
        if info.callbackTarget == frame then
            count = count + 1
        end
    end
    return count
end


--- @param frame table the in-game menu's Animals page
--- @return boolean shown  true when the in-game menu is on screen with this page current
local function isShownPage(frame)
    return g_gui.currentGuiName == "InGameMenu" and g_inGameMenu ~= nil and g_inGameMenu.currentPage == frame
end


-- Per-call counter so consecutive reloadList fires can be distinguished in
-- the log when triaging menu-refresh churn (a single user action can fan out
-- to many reloads via the publish chain).
RealisticLivestock_InGameMenuAnimalsFrame._reloadListCount = 0


--- Rebuild the animal list in RLRM order, keeping the selected animal; a page not on screen skips it.
--- @param superFunc function the base reloadList
function RealisticLivestock_InGameMenuAnimalsFrame:reloadList(superFunc)
    RealisticLivestock_InGameMenuAnimalsFrame._reloadListCount =
        RealisticLivestock_InGameMenuAnimalsFrame._reloadListCount + 1
    local callId = RealisticLivestock_InGameMenuAnimalsFrame._reloadListCount

    -- The page rebuilds when it opens, so a rebuild while closed is wasted work - and a
    -- data-changed listener left behind by another mod calls this on every pen change.
    if not isShownPage(self) then
        Log:debug("InGameMenuAnimalsFrame:reloadList #%d skipped: page not shown (gui=%s, frame=%s)",
            callId, tostring(g_gui.currentGuiName), tostring(self))
        return
    end

    -- No printCallstack() here - it always emits an engine [ERROR] line, which
    -- would surface phantom ERRORs in support logs on this hot path.
    -- No safeCall wrap either: it would silence GUI errors AND leak the
    -- reloadData/soundDisabled mutations on throw (not finally-safe under xpcall).
    -- Errors propagate up as expected.
    Log:debug("InGameMenuAnimalsFrame:reloadList #%d enter: selectorState=%s, frame=%s",
        callId,
        tostring(self.subCategorySelector and self.subCategorySelector.getState and self.subCategorySelector:getState() or "?"),
        tostring(self))

    -- Save selected animal BEFORE superFunc rebuilds data in base order.
    -- After superFunc, the numeric selection index still points at the old
    -- position but a different animal may now occupy that slot.
    local selectedAnimal = getSelectedAnimal(self)

    -- Prevent superFunc from calling reloadData() with unsorted data.
    -- The base game's reloadList() seems to call list:reloadData() internally,
    -- which would scroll and fire selection events based on wrong order.
    local tSuperStart = getTimeSec()
    local origReloadData = self.list.reloadData
    self.list.reloadData = function() end
    superFunc(self)
    self.list.reloadData = origReloadData
    local tSuperMs = (getTimeSec() - tSuperStart) * 1000

    if self.husbandrySubTypes == nil or #self.husbandrySubTypes == 0 then
        self.list:reloadData()
        Log:debug("InGameMenuAnimalsFrame:reloadList #%d exit: empty (super=%.2fms)", callId, tSuperMs)
        return
    end

    local tSortStart = getTimeSec()
    if #self.husbandrySubTypes > 1 then
        table.sort(self.husbandrySubTypes)
    end

    for _, subTypeIndex in ipairs(self.husbandrySubTypes) do
        local animals = self.subTypeIndexToClusters[subTypeIndex]
        if animals ~= nil and #animals > 1 then
            table.sort(animals, sortRawAnimals)
        end
    end
    local tSortMs = (getTimeSec() - tSortStart) * 1000

    -- Pre-set list selection indices to the saved animal's new position BEFORE
    -- reloadData(). The list picks up these indices during reload, so we avoid
    -- a post-reload correction call and its scroll/selection-change side effects.
    local tFindStart = getTimeSec()
    local newSection, newIndex = findAnimalPosition(self, selectedAnimal)
    if newSection ~= nil then
        self.list.selectedSectionIndex = newSection
        self.list.selectedIndex = newIndex
        Log:trace("AnimalsFrame: pre-set selection to section %d index %d", newSection, newIndex)
    end
    local tFindMs = (getTimeSec() - tFindStart) * 1000

    -- Suppress click sound during reload.
    local tReloadDataStart = getTimeSec()
    self.list.soundDisabled = true
    self.list:reloadData()
    self.list.soundDisabled = false
    local tReloadDataMs = (getTimeSec() - tReloadDataStart) * 1000

    Log:debug("InGameMenuAnimalsFrame:reloadList #%d exit: subTypes=%d super=%.2fms sort=%.2fms find=%.2fms reloadData=%.2fms",
        callId,
        #self.husbandrySubTypes,
        tSuperMs, tSortMs, tFindMs, tReloadDataMs)

    Log:debug("AnimalsFrame: reloadList sorted %d subTypes", #self.husbandrySubTypes)
end

InGameMenuAnimalsFrame.reloadList = Utils.overwrittenFunction(
    InGameMenuAnimalsFrame.reloadList,
    RealisticLivestock_InGameMenuAnimalsFrame.reloadList
)


function RealisticLivestock_InGameMenuAnimalsFrame:displayCluster(superFunc, animal, husbandry)
    if g_currentMission.isRunning or Platform.isMobile then
        local animalSystem = g_currentMission.animalSystem
        local subTypeIndex = animal:getSubTypeIndex()
        local age = animal:getAge()
        local visual = animalSystem:getVisualByAge(subTypeIndex, age)

        if visual ~= nil then
            local subType = animal:getSubType()

            local name = animal:getName()
            name = name ~= "" and (" (" .. name .. ")") or ""

            local displayName = RLAnimalDisplayHelper.formatDisplayName(animal.uniqueId .. name, animal)
            self.animalDetailTypeNameText:setText(displayName)
            self.animalDetailTypeImage:setImageFilename(visual.store.imageFilename)

            local ageMonth = g_i18n:formatNumMonth(age)
            self.animalAgeText:setText(ageMonth)

            local animalInfo = husbandry:getAnimalInfos(animal)

            for a, b in ipairs(self.infoRow) do
                local row = animalInfo[a]
                b:setVisible(row ~= nil)

                if row ~= nil then
                    local valueText = row.valueText or g_i18n:formatVolume(row.value, 0, row.customUnitText)
                    self.infoLabel[a]:setText(row.title)
                    self.infoValue[a]:setText(valueText)
                    self:setStatusBarValue(self.infoStatusBar[a], row.ratio, row.invertedBar, row.disabled)
                end
            end

            local description = husbandry:getAnimalDescription(animal)
            self.detailDescriptionText:setText(description)
        end
    end
end

InGameMenuAnimalsFrame.displayCluster = Utils.overwrittenFunction(InGameMenuAnimalsFrame.displayCluster,
    RealisticLivestock_InGameMenuAnimalsFrame.displayCluster)



function RealisticLivestock_InGameMenuAnimalsFrame:populateCellForItemInSection(_, subTypeIndex, animalIndex, cell)
    local subType = self.husbandrySubTypes[subTypeIndex]
    local animal = self.subTypeIndexToClusters[subType][animalIndex]

    if g_currentMission.animalSystem:getVisualByAge(subType, animal:getAge()) ~= nil then
        local baseName = animal.uniqueId .. (animal:getName() == "" and "" or (" (" .. animal:getName() .. ")"))
        cell:getAttribute("name"):setText(RLAnimalDisplayHelper.formatDisplayName(baseName, animal))
        cell:getAttribute("count"):setVisible(false)
    end
end

InGameMenuAnimalsFrame.populateCellForItemInSection = Utils.appendedFunction(
InGameMenuAnimalsFrame.populateCellForItemInSection,
    RealisticLivestock_InGameMenuAnimalsFrame.populateCellForItemInSection)


-- RL_OPEN_ANIMAL_SCREEN is in NAV_ACTIONS only while the Animals page is open, so the R key
-- does not interfere with other frames (such as RemoveContract on the contracts page).

--- Add the R action to NAV_ACTIONS and log the page's data-changed subscription count.
function RealisticLivestock_InGameMenuAnimalsFrame:onFrameOpen()
    table.insert(Gui.NAV_ACTIONS, InputAction.RL_OPEN_ANIMAL_SCREEN)
    Log:debug("InGameMenuAnimalsFrame:onFrameOpen: frame=%s, dataChangedSubscriptions=%d",
        tostring(self), RealisticLivestock_InGameMenuAnimalsFrame.countDataChangedSubscriptions(self))
end

InGameMenuAnimalsFrame.onFrameOpen = Utils.appendedFunction(
    InGameMenuAnimalsFrame.onFrameOpen,
    RealisticLivestock_InGameMenuAnimalsFrame.onFrameOpen
)

--- Remove the R action from NAV_ACTIONS and log the page's data-changed subscription count.
function RealisticLivestock_InGameMenuAnimalsFrame:onFrameClose()
    for i = #Gui.NAV_ACTIONS, 1, -1 do
        if Gui.NAV_ACTIONS[i] == InputAction.RL_OPEN_ANIMAL_SCREEN then
            table.remove(Gui.NAV_ACTIONS, i)
            break
        end
    end
    Log:debug("InGameMenuAnimalsFrame:onFrameClose: frame=%s, dataChangedSubscriptions=%d",
        tostring(self), RealisticLivestock_InGameMenuAnimalsFrame.countDataChangedSubscriptions(self))
end

InGameMenuAnimalsFrame.onFrameClose = Utils.appendedFunction(
    InGameMenuAnimalsFrame.onFrameClose,
    RealisticLivestock_InGameMenuAnimalsFrame.onFrameClose
)


function RealisticLivestock_InGameMenuAnimalsFrame:onUpdateMenuButtons()
    local selectedHusbandry = self.selectedHusbandry
    if selectedHusbandry == nil then return end

    table.insert(self.menuButtonInfo, {
        inputAction = InputAction.RL_OPEN_ANIMAL_SCREEN,
        text = g_i18n:getText("rl_ui_openAnimalScreen"),
        callback = function()
            -- Open the standalone RLMenu in MODE_FULL, anchored to this pen (page 4,
            -- the own-pen landing). Call openFromBridge DIRECTLY (not via the
            -- AnimalScreen.show parity seam) so this in-game-menu-originated open can
            -- carry the one-shot fromInGameMenu flag: it makes Esc/Back return to the
            -- in-game menu (Animals page) instead of closing to gameplay, restoring the
            -- affordance the vanilla animal screen had. The flag is consumed on Back and
            -- cleared on every other open path, so no other RLMenu open is affected.
            Log:debug("AnimalsFrame: opening RLMenu from in-game menu (fromInGameMenu=true, husbandry=%s)",
                tostring(selectedHusbandry))
            RLMenu.openFromBridge(4, RLMenu.MODE_FULL, { husbandry = selectedHusbandry, fromInGameMenu = true })
        end
    })
end

InGameMenuAnimalsFrame.updateMenuButtons = Utils.appendedFunction(
    InGameMenuAnimalsFrame.updateMenuButtons,
    RealisticLivestock_InGameMenuAnimalsFrame.onUpdateMenuButtons
)
