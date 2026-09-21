DiseaseDialog = {}

local diseaseDialog_mt = Class(DiseaseDialog, MessageDialog)
local modDirectory = g_currentModDirectory

function DiseaseDialog.register()

    local dialog = DiseaseDialog.new()
    g_gui:loadGui(modDirectory .. "gui/DiseaseDialog.xml", "DiseaseDialog", dialog)
    DiseaseDialog.INSTANCE = dialog

end


function DiseaseDialog.new(target, customMt)

    local self = MessageDialog.new(target, customMt or diseaseDialog_mt)

    return self

end


function DiseaseDialog.createFromExistingGui(gui)

    DiseaseDialog.register()
    DiseaseDialog.show()

end


-- Refuses while diseases are off, and both callers funnel through here. It does not close a dialog
-- already open, and the list is an open-time snapshot the next open reads again.
--- Open the treatment dialog for one animal, listing only the records a player may see.
---@param animal table|nil The animal whose records to show.
---@param onCloseCallback function|nil Invoked on close so the parent can refresh.
---@param onCloseTarget table|nil `self` for the close callback.
function DiseaseDialog.show(animal, onCloseCallback, onCloseTarget)

    if g_diseaseManager == nil or not g_diseaseManager.diseasesEnabled then
        Log:trace("DiseaseDialog.show: refused, reason=diseases disabled (uniqueId=%s)",
            tostring(animal ~= nil and animal.uniqueId))
        return
    end

    if DiseaseDialog.INSTANCE == nil then DiseaseDialog.register() end

    local dialog = DiseaseDialog.INSTANCE

    dialog.animal = animal
    -- A fresh array: the row count and the cells both read this one table, never the animal's
    -- live array.
    dialog.diseases = animal:getVisibleDiseases()
    Log:debug("DiseaseDialog.show: listing %d of %d records (uniqueId=%s)",
        #dialog.diseases, #animal.diseases, tostring(animal.uniqueId))
    dialog.onCloseCallback = onCloseCallback
    dialog.onCloseTarget = onCloseTarget

    g_gui:showDialog("DiseaseDialog")

end


--- Load the list, then set the treatment and Cull buttons for the animal being shown.
function DiseaseDialog:onOpen()

    DiseaseDialog:superClass().onOpen(self)

    self.diseaseList:reloadData()

    self:onClickListItem(1)

    self:updateCullButton()

    Log:trace("DiseaseDialog:onOpen: opened (uniqueId=%s)", tostring(self.animal ~= nil and self.animal.uniqueId))

end


--- Fire optional close callback so the parent screen can refresh.
function DiseaseDialog:onClose()
    DiseaseDialog:superClass().onClose(self)

    if self.onCloseCallback ~= nil then
        Log:trace("DiseaseDialog:onClose: firing close callback")
        self.onCloseCallback(self.onCloseTarget)
    end
end


function DiseaseDialog:onClickOk()

    local disease = self.diseases[self.diseaseList.selectedIndex]

    -- A record with no authored course, or one not currently symptomatic. INFECTIOUS mirrors
    -- what enrolTreatment accepts, so the flag can never go true with no course behind it.
    if disease == nil or disease.model.treatment == nil
        or disease.state ~= RLDiseaseRecord.STATE.INFECTIOUS then
        return
    end

    -- The ANIMAL's record, never the open-time list: that list is a shallow snapshot and a daily
    -- tick can have removed this record since the dialog opened.
    local liveDisease = self.animal:getDisease(disease.title)

    if liveDisease == nil then
        Log:warning("DiseaseDialog:onClickOk: the animal no longer carries that record, refusing (disease=%s uniqueId=%s)",
            tostring(disease.title), tostring(self.animal.uniqueId))
        return
    end

    local newState = not liveDisease.treatmentRunning
    local husbandry = self.animal.clusterSystem.owner

    -- Read BEFORE the seed, or a fresh start reads its own seeded counter and says RESUME.
    local isResuming = liveDisease.treatmentMonthsRemaining > 0

    Log:trace("DiseaseDialog:onClickOk sending event disease=%s treatment=%s treatmentMonthsRemaining=%s uniqueId=%s",
        disease.title, tostring(newState), tostring(liveDisease.treatmentMonthsRemaining),
        tostring(self.animal.uniqueId))
    DiseaseTreatmentToggleEvent.sendEvent(husbandry, self.animal, disease.title, newState)

    -- The flag LEADS the writes, as everywhere else on this path: it is the sole cause of
    -- replication, so writing it last puts it behind every statement that can raise.
    self.animal:setDirty()

    disease.treatmentRunning = newState
    liveDisease.treatmentRunning = newState

    -- START only. On a RESUME the refusal of a non-zero counter IS the pause contract - the
    -- served months survive because nothing writes the counter down.
    if newState then
        RLDiseaseRecord.enrolTreatment(liveDisease, liveDisease.model.treatment)
    end

    if not newState then
        self.animal:addMessage("DISEASE_TREATMENT_STOP", { disease.model.name })
    else
        self.animal:addMessage("DISEASE_TREATMENT_" .. (isResuming and "RESUME" or "START"), { disease.model.name, string.format(g_i18n:getText("rl_ui_feePerMonth"), g_i18n:formatMoney(disease.model.treatment.cost, 2, true, true)) })
    end

    self:onClickListItem(self.diseaseList.selectedIndex)
    self.diseaseList:reloadData()

end


--- Offer the course for one listed row: enabled only for a treatable symptomatic record, labelled by its status.
---@param index number|nil The row's index in the open-time list.
function DiseaseDialog:onClickListItem(index)

    local disease = self.diseases[index]

    -- The same gate as onClickOk's, and the two must stay identical: this one decides whether
    -- the button is offered, that one decides whether the click is honoured.
    if disease == nil or disease.model.treatment == nil
        or disease.state ~= RLDiseaseRecord.STATE.INFECTIOUS then

        self.yesButton:setDisabled(true)
        -- Reset, or the disabled button keeps the label the previously selected row gave it.
        self.yesButton:setText(g_i18n:getText("rl_ui_startTreatment"))
        Log:trace("DiseaseDialog:onClickListItem: button disabled, label reset (index=%s)", tostring(index))
        return

    end

    self.yesButton:setDisabled(false)

    -- Read at call time: this file is sourced before RLDiseaseStatus.
    local KEY = RLDiseaseStatus.KEY
    local statusKey = RLDiseaseStatus.resolve(disease).statusKey
    local label = statusKey == KEY.BEING_TREATED and "stop"
        or (statusKey == KEY.TREATMENT_PAUSED and "resume" or "start")

    Log:trace("DiseaseDialog:onClickListItem: button enabled, label=%s (index=%s)", label, tostring(index))
    self.yesButton:setText(g_i18n:getText("rl_ui_" .. label .. "Treatment"))

end


-- The Cull button is animal-level: it reads the one cull rule, never the selected row. Every
-- RLDiseaseCull read in this file is at call time, since this file is sourced before that module.
--- Enable the Cull button only while the animal passes the cull rule.
function DiseaseDialog:updateCullButton()

    local ok, reason = RLDiseaseCull.check(self.animal)

    self.cullButton:setDisabled(not ok)
    Log:trace("DiseaseDialog:updateCullButton: %s (reason=%s uniqueId=%s)", ok and "enabled" or "disabled",
        tostring(reason), tostring(self.animal.uniqueId))

end


--- Ask the player to confirm a cull, naming the animal and the salvage it pays.
function DiseaseDialog:onClickCull()

    local animal = self.animal
    local ok, reason = RLDiseaseCull.check(animal)

    if not ok then
        Log:debug("DiseaseDialog:onClickCull: refused, reason=%s (uniqueId=%s)", tostring(reason),
            tostring(animal.uniqueId))
        self:updateCullButton()
        return
    end

    -- The label the single-animal sell confirm shows: the type, then the name when one is set.
    local label = RLAnimalSellService.getAnimalTypeTitle(animal)
    local name = RLAnimalSellService.getAnimalName(animal)
    if name ~= "" then label = label .. ", " .. name end

    local salvage = RLDiseaseCull.salvageFor(animal)
    local text = string.format(g_i18n:getText("rl_ui_cullConfirm"), label,
        g_i18n:formatMoney(salvage, 0, true, true))

    Log:debug("DiseaseDialog:onClickCull: confirming uniqueId=%s farmId=%s salvage=%s", tostring(animal.uniqueId),
        tostring(animal.farmId), tostring(salvage))
    YesNoDialog.show(self.onCullConfirmed, self, text, g_i18n:getText("ui_attention"), nil, nil,
        DialogElement.TYPE_WARNING)

end


--- The confirm's answer: on Yes cull through the event and close; on No leave this dialog open.
---@param yes boolean True when the player confirmed.
function DiseaseDialog:onCullConfirmed(yes)

    local animal = self.animal

    if not yes then
        Log:trace("DiseaseDialog:onCullConfirmed: declined (uniqueId=%s)", tostring(animal.uniqueId))
        return
    end

    -- Checked again: the animal can have died or recovered while the confirm was open.
    local ok, reason = RLDiseaseCull.check(animal)

    if not ok then
        Log:debug("DiseaseDialog:onCullConfirmed: refused, reason=%s (uniqueId=%s)", tostring(reason),
            tostring(animal.uniqueId))
    elseif animal.clusterSystem == nil or animal.clusterSystem.owner == nil then
        Log:warning("DiseaseDialog:onCullConfirmed: the animal is in no pen, nothing culled "
            .. "(uniqueId=%s clusterSystem=%s)", tostring(animal.uniqueId), tostring(animal.clusterSystem))
    else
        local accepted = DiseaseCullEvent.sendEvent(animal.clusterSystem.owner, animal)
        Log:debug("DiseaseDialog:onCullConfirmed: sent uniqueId=%s accepted=%s", tostring(animal.uniqueId),
            tostring(accepted))
    end

    self:close()

end


function DiseaseDialog:getNumberOfSections()

	return 1

end


--- Count the rows from the same open-time table the cells are populated from.
---@param list table The dialog's list.
---@param section number The one section.
---@return number count
function DiseaseDialog:getNumberOfItemsInSection(list, section)

	return #self.diseases

end


function DiseaseDialog:getTitleForSectionHeader(list, section)

    return ""

end


function DiseaseDialog:populateCellForItemInSection(list, section, index, cell)

	local disease = self.diseases[index]

    if disease == nil then return end

    local model = disease.model
    local treatment = model.treatment

    cell:getAttribute("title"):setText(model.name)
    -- Months remaining once a course is under way, the authored total otherwise. The
    -- nil-treatment arm must stay short-circuited: two shipped diseases carry no treatment
    -- block, so the duration term below may not be evaluated for them.
    cell:getAttribute("duration"):setText(treatment == nil and "N/A"
        or RealisticLivestock.formatAge(disease.treatmentMonthsRemaining > 0
            and RLDiseaseStatus.wholeMonthsRemaining(disease.treatmentMonthsRemaining) or treatment.months))
    cell:getAttribute("fee"):setText(treatment == nil and "N/A" or string.format(g_i18n:getText("rl_ui_feePerMonth"), g_i18n:formatMoney(treatment.cost, 2, true, true)))
    cell:getAttribute("status"):setText(disease:getStatus())

    cell.setSelected = Utils.appendedFunction(cell.setSelected, function(cell, selected)
		if selected then self:onClickListItem(index) end
	end)
    
end