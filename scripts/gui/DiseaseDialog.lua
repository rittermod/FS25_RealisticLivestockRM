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
--- Refuses while the disease engine is off. Both callers funnel through here - the RL Menu Info
--- frame's button and `createFromExistingGui` - so while the lock holds, no open reaches
--- `onClickOk`, its `beingTreated` write, the treatment toggle event or the three treatment
--- messages.
---
--- "While the lock holds" is the honest scope, not "every future open". `createFromExistingGui`
--- passes no animal at all, so with the setting back ON it still raises on the clone below -
--- a pre-existing defect this gate MASKS rather than fixes. The record slice rewrites the
--- dialog and owns it; do not read the refusal as having closed it.
---
--- It does NOT close an already-open dialog: `onClickOk` carries no recheck. Under the lock
--- the dialog can never have opened in the first place, so that residual has no
--- player-reachable path and no recheck is added for it.
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

    if disease == nil or disease.type.treatment == nil or disease.cured then return end

    local newState = not disease.beingTreated
    local husbandry = self.animal.clusterSystem.owner

    -- Send network event (server broadcasts, client sends to server)
    -- treatmentDuration is months REMAINING, captured before the toggle: on a stop it is what
    -- the paused course resumes from, on a start it is whatever a previous course left behind.
    -- It is the local machine's value, so read it as "what THIS peer will render" rather than as
    -- the authoritative course state: the toggle event replicates beingTreated and never this
    -- field. A client's copy arrives on the pen flush that each disease transition schedules, so
    -- it is accurate as of the last contract, cure or expiry and drifts from there, because the
    -- per-month decrement is deliberately not synced. A course STARTED since that flush is the
    -- widest gap: seeding this counter is itself an unflagged tick, so a client reads 0 for the
    -- whole course.
    -- uniqueId names the animal so the line stands on its own. It used to be the half that
    -- correlated it with the course-seeding trace in Disease:onPeriodChanged; that trace went
    -- with the progression stub, so there is nothing to correlate against while the lock holds.
    Log:trace("DiseaseDialog:onClickOk sending event disease=%s treatment=%s treatmentDuration=%s uniqueId=%s",
        disease.type.title, tostring(newState), tostring(disease.treatmentDuration),
        tostring(self.animal.uniqueId))
    DiseaseTreatmentToggleEvent.sendEvent(husbandry, self.animal, disease.type.title, newState)

    -- Local UI feedback (immediate)
    disease.beingTreated = newState
    for _, aDisease in pairs(self.animal.diseases) do
        if aDisease.type.title == disease.type.title then
            aDisease.beingTreated = newState
            break
        end
    end

    -- Messages (keep existing logic)
    if not newState then
        self.animal:addMessage("DISEASE_TREATMENT_STOP", { disease.type.name })
    else
        self.animal:addMessage("DISEASE_TREATMENT_" .. (disease.treatmentDuration > 0 and "RESUME" or "START"), { disease.type.name, string.format(g_i18n:getText("rl_ui_feePerMonth"), g_i18n:formatMoney(disease.type.treatment.cost, 2, true, true)) })
    end

    self:onClickListItem(self.diseaseList.selectedIndex)
    self.diseaseList:reloadData()

end


function DiseaseDialog:onClickListItem(index)

    local disease = self.diseases[index]

    if disease == nil or disease.type.treatment == nil or disease.cured then

        self.yesButton:setDisabled(true)
        return

    end

    self.yesButton:setDisabled(false)
    self.yesButton:setText(g_i18n:getText("rl_ui_" .. (disease.beingTreated and "stop" or (disease.treatmentDuration > 0 and "resume" or "start")) .. "Treatment"))

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

    local type = disease.type
    local treatment = type.treatment

    cell:getAttribute("title"):setText(type.name)
    -- Months REMAINING once a course is under way, the configured total otherwise. A
    -- paused course still counts as under way and reads as remaining; a cured or
    -- never-started record is back at zero and reads as the total. The nil-treatment
    -- arm must stay short-circuited - two shipped diseases carry no treatment block,
    -- so the duration term below may not be evaluated for them.
    cell:getAttribute("duration"):setText(treatment == nil and "N/A"
        or RealisticLivestock.formatAge(
            disease.treatmentDuration > 0 and disease.treatmentDuration or treatment.duration))
    cell:getAttribute("fee"):setText(treatment == nil and "N/A" or string.format(g_i18n:getText("rl_ui_feePerMonth"), g_i18n:formatMoney(treatment.cost, 2, true, true)))
    cell:getAttribute("status"):setText(disease:getStatus())

    cell.setSelected = Utils.appendedFunction(cell.setSelected, function(cell, selected)
		if selected then self:onClickListItem(index) end
	end)
    
end