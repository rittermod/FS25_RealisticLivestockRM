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

    -- Each clause means: a record with no authored course, or one already past its infection.
    if disease == nil or disease.model.treatment == nil
        or disease.state == RLDiseaseRecord.STATE.RECOVERED then
        return
    end

    local newState = not disease.treatmentRunning
    local husbandry = self.animal.clusterSystem.owner

    -- The remaining counter is months left, captured before the toggle. It is this peer's own
    -- value, not authoritative course state: the toggle event replicates the running flag and
    -- never the counter, whose per-month decrement is deliberately unsynced.
    Log:trace("DiseaseDialog:onClickOk sending event disease=%s treatment=%s treatmentMonthsRemaining=%s uniqueId=%s",
        disease.title, tostring(newState), tostring(disease.treatmentMonthsRemaining),
        tostring(self.animal.uniqueId))
    DiseaseTreatmentToggleEvent.sendEvent(husbandry, self.animal, disease.title, newState)

    disease.treatmentRunning = newState
    for _, aDisease in pairs(self.animal.diseases) do
        if aDisease.title == disease.title then
            aDisease.treatmentRunning = newState
            break
        end
    end

    if not newState then
        self.animal:addMessage("DISEASE_TREATMENT_STOP", { disease.model.name })
    else
        self.animal:addMessage("DISEASE_TREATMENT_" .. (disease.treatmentMonthsRemaining > 0 and "RESUME" or "START"), { disease.model.name, string.format(g_i18n:getText("rl_ui_feePerMonth"), g_i18n:formatMoney(disease.model.treatment.cost, 2, true, true)) })
    end

    self:onClickListItem(self.diseaseList.selectedIndex)
    self.diseaseList:reloadData()

end


function DiseaseDialog:onClickListItem(index)

    local disease = self.diseases[index]

    -- The same repointed gate as onClickOk's, and the two must stay identical: this one decides
    -- whether the button is offered, that one decides whether the click is honoured.
    if disease == nil or disease.model.treatment == nil
        or disease.state == RLDiseaseRecord.STATE.RECOVERED then

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