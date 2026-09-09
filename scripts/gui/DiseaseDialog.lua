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


--- Open the treatment dialog for one animal.
---
--- Refuses while the disease engine is off, and both callers funnel through here, so under
--- the lock no open reaches onClickOk's treatment write, the toggle event or the messages.
--- It does not close an already-open dialog and needs no recheck: under the lock one could
--- never have opened.
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
    dialog.diseases = table.clone(animal.diseases)
    dialog.onCloseCallback = onCloseCallback
    dialog.onCloseTarget = onCloseTarget

    g_gui:showDialog("DiseaseDialog")

end


function DiseaseDialog:onOpen()

    DiseaseDialog:superClass().onOpen(self)

    self.diseaseList:reloadData()

    self:onClickListItem(1)

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

    -- The ANIMAL's record, never the open-time clone: the clone's array is a shallow snapshot
    -- and a daily tick can have removed this record since the dialog opened.
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


function DiseaseDialog:onClickListItem(index)

    local disease = self.diseases[index]

    -- The same gate as onClickOk's, and the two must stay identical: this one decides whether
    -- the button is offered, that one decides whether the click is honoured.
    if disease == nil or disease.model.treatment == nil
        or disease.state ~= RLDiseaseRecord.STATE.INFECTIOUS then

        self.yesButton:setDisabled(true)
        return

    end

    self.yesButton:setDisabled(false)
    self.yesButton:setText(g_i18n:getText("rl_ui_" .. (disease.treatmentRunning and "stop" or (disease.treatmentMonthsRemaining > 0 and "resume" or "start")) .. "Treatment"))

end


function DiseaseDialog:getNumberOfSections()

	return 1

end


function DiseaseDialog:getNumberOfItemsInSection(list, section)

	return #self.animal.diseases

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
        or RealisticLivestock.formatAge(
            disease.treatmentMonthsRemaining > 0 and disease.treatmentMonthsRemaining or treatment.months))
    cell:getAttribute("fee"):setText(treatment == nil and "N/A" or string.format(g_i18n:getText("rl_ui_feePerMonth"), g_i18n:formatMoney(treatment.cost, 2, true, true)))
    cell:getAttribute("status"):setText(disease:getStatus())

    cell.setSelected = Utils.appendedFunction(cell.setSelected, function(cell, selected)
		if selected then self:onClickListItem(index) end
	end)
    
end