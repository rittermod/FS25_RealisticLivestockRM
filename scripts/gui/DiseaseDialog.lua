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


-- Only VISIBLE records are subtracted, so an animal incubating a disease is still offered its
-- vaccine, exactly as a healthy one is.
--- The rows for one animal: its visible records, then the vaccines it can take that no visible record names.
---@param animal table The animal being shown.
---@return table diseases A fresh array of visible records.
---@return table vaccineModels A fresh array of registry entries for the vaccine rows.
local function buildRows(animal)

    local diseases = animal:getVisibleDiseases()
    local listed = {}
    for _, record in ipairs(diseases) do listed[record.title] = true end

    local vaccineModels = {}
    for _, model in ipairs(g_diseaseManager:getVaccineModelsFor(animal)) do
        if not listed[model.title] then vaccineModels[#vaccineModels + 1] = model end
    end

    Log:debug("DiseaseDialog: rows built, %s of %s records and %s vaccine row(s) (uniqueId=%s)",
        tostring(#diseases), tostring(animal.diseases ~= nil and #animal.diseases or nil), tostring(#vaccineModels),
        tostring(animal.uniqueId))

    return diseases, vaccineModels

end


--- The row at `index`: its record (nil on a vaccine row) and its model, or nil, nil past either end.
---@param dialog table The dialog instance.
---@param index number|nil The row index; the list uses 0 for no selection.
---@return table|nil record The visible record, nil on a vaccine row.
---@return table|nil model The row's registry entry.
local function rowAt(dialog, index)

    if index == nil or index < 1 then
        Log:trace("DiseaseDialog rowAt: no row, index=%s", tostring(index))
        return nil, nil
    end

    local uniqueId = dialog.animal ~= nil and dialog.animal.uniqueId or nil

    local record = dialog.diseases[index]
    if record ~= nil then
        Log:trace("DiseaseDialog rowAt: record row index=%s title=%s uniqueId=%s", tostring(index),
            tostring(record.title), tostring(uniqueId))
        return record, record.model
    end

    local model = dialog.vaccineModels[index - #dialog.diseases]
    Log:trace("DiseaseDialog rowAt: vaccine row index=%s title=%s uniqueId=%s", tostring(index),
        tostring(model ~= nil and model.title or nil), tostring(uniqueId))
    return nil, model

end


--- Whether a row offers a dose: a vaccine row, or a visible record at RECOVERED whose disease has a vaccine.
---@param animal table The animal being shown.
---@param record table|nil The row's record, nil on a vaccine row.
---@param model table|nil The row's registry entry.
---@return boolean offers True when the row's button vaccinates.
local function offersDose(animal, record, model)

    if model == nil or model.vaccine == nil then
        Log:trace("DiseaseDialog offersDose: no, no vaccine (title=%s uniqueId=%s)",
            tostring(model ~= nil and model.title or nil), tostring(animal ~= nil and animal.uniqueId or nil))
        return false
    end

    if record ~= nil and record.state ~= RLDiseaseRecord.STATE.RECOVERED then
        Log:trace("DiseaseDialog offersDose: no, record state=%s (title=%s uniqueId=%s)", tostring(record.state),
            tostring(model.title), tostring(animal ~= nil and animal.uniqueId or nil))
        return false
    end

    local ok, reason = RLDiseaseVaccination.check(animal, model)
    Log:trace("DiseaseDialog offersDose: %s (title=%s reason=%s uniqueId=%s)", ok and "yes" or "no",
        tostring(model.title), tostring(reason), tostring(animal.uniqueId))
    return ok

end


--- A dose row's Duration and Fee: the vaccine's protection in whole months, never years, and its price per dose.
---@param model table The row's registry entry, carrying `vaccine`.
---@return string duration
---@return string fee
local function doseCells(model)

    -- Read at call time: this file is sourced before RLDiseaseStatus.
    local months = RLDiseaseStatus.wholeMonthsRemaining(model.vaccine.protectionMonths)
    local unitKey = months == 1 and "rl_ui_month" or "rl_ui_months"

    Log:debug("DiseaseDialog doseCells: title=%s months=%s cost=%s", tostring(model.title), tostring(months),
        tostring(model.vaccine.cost))

    return string.format("%s %s", months, g_i18n:getText(unitKey)),
        string.format(g_i18n:getText("rl_ui_feePerDose"), g_i18n:formatMoney(model.vaccine.cost, 2, true, true))

end


--- The animal as the confirms name it: the type, then the name when one is set.
---@param animal table The animal being shown.
---@return string label
local function animalLabel(animal)

    local label = RLAnimalSellService.getAnimalTypeTitle(animal)
    local name = RLAnimalSellService.getAnimalName(animal)
    if name ~= "" then label = label .. ", " .. name end

    return label

end


-- Refuses while diseases are off, and both callers funnel through here. It does not close a dialog
-- already open, and the list is an open-time snapshot the next open reads again.
--- Open the Diseases dialog for one animal; its rows come from `buildRows`.
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
    -- Fresh arrays: the row count and the cells both read these, never the animal's live array.
    dialog.diseases, dialog.vaccineModels = buildRows(animal)
    dialog.onCloseCallback = onCloseCallback
    dialog.onCloseTarget = onCloseTarget

    g_gui:showDialog("DiseaseDialog")

end


--- Load the list, select row 1, then set the OK and Cull buttons for the animal being shown.
function DiseaseDialog:onOpen()

    DiseaseDialog:superClass().onOpen(self)

    -- The singleton reuses its list and reloadData only clamps a stale index, so the highlight is
    -- re-anchored and the button seeded explicitly: neither fires the selection delegate here.
    self.diseaseList:reloadData()
    self.diseaseList:setSelectedItem(1, 1)

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


--- The OK button: a dose row opens the vaccinate confirm, a treatable record row toggles its course.
function DiseaseDialog:onClickOk()

    local disease, model = rowAt(self, self.diseaseList.selectedIndex)

    if offersDose(self.animal, disease, model) then
        Log:trace("DiseaseDialog:onClickOk: dose row (index=%s title=%s)", tostring(self.diseaseList.selectedIndex),
            tostring(model.title))
        self:confirmVaccinate(model)
        return
    end

    -- A record with no authored course, or one not currently symptomatic. INFECTIOUS mirrors
    -- what enrolTreatment accepts, so the flag can never go true with no course behind it.
    if disease == nil or disease.model.treatment == nil
        or disease.state ~= RLDiseaseRecord.STATE.INFECTIOUS then
        Log:trace("DiseaseDialog:onClickOk: row offers nothing (index=%s title=%s uniqueId=%s)",
            tostring(self.diseaseList.selectedIndex), tostring(disease ~= nil and disease.title or nil),
            tostring(self.animal ~= nil and self.animal.uniqueId or nil))
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


--- Label the OK button for one row: Vaccinate on a dose row, the course label on a treatable record, else disabled.
---@param index number|nil The row's index in the open-time list.
function DiseaseDialog:onClickListItem(index)

    local disease, model = rowAt(self, index)

    if offersDose(self.animal, disease, model) then
        self.yesButton:setDisabled(false)
        self.yesButton:setText(g_i18n:getText("rl_ui_vaccinate"))
        Log:trace("DiseaseDialog:onClickListItem: button enabled, label=vaccinate (index=%s title=%s)",
            tostring(index), tostring(model.title))
        return
    end

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

    -- The label the single-animal sell confirm shows.
    local label = animalLabel(animal)

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


-- One fixed dialog type and text shape for every dose, so a dose on an animal already incubating
-- the disease looks exactly like any other.
--- Ask the player to confirm one dose, naming the animal, the disease and the dose price.
---@param model table The disease's registry entry, carrying `vaccine`.
function DiseaseDialog:confirmVaccinate(model)

    local animal = self.animal
    local cost = model.vaccine.cost
    local text = string.format(g_i18n:getText("rl_ui_vaccinateConfirm"), animalLabel(animal), model.name,
        g_i18n:formatMoney(cost, 0, true, true))

    Log:debug("DiseaseDialog:confirmVaccinate: confirming title=%s cost=%s uniqueId=%s farmId=%s",
        tostring(model.title), tostring(cost), tostring(animal.uniqueId), tostring(animal.farmId))
    YesNoDialog.show(self.onVaccinateConfirmed, self, text, g_i18n:getText("rl_ui_vaccinate"), nil, nil,
        DialogElement.TYPE_QUESTION, nil, nil, model.title)

end


-- A Yes always sends: no re-check, so a disease that surfaced while the confirm was open takes a
-- charged dose that does nothing, as every dose on an infected animal does.
--- The confirm's answer: on Yes send one dose and rebuild the rows; on No leave the dialog as it is.
---@param yes boolean True when the player confirmed.
---@param title string The disease title the confirm was opened for.
function DiseaseDialog:onVaccinateConfirmed(yes, title)

    local animal = self.animal

    if not yes then
        Log:trace("DiseaseDialog:onVaccinateConfirmed: declined (title=%s uniqueId=%s)", tostring(title),
            tostring(animal.uniqueId))
        return
    end

    if animal.clusterSystem == nil or animal.clusterSystem.owner == nil then
        Log:warning("DiseaseDialog:onVaccinateConfirmed: the animal is in no pen, no dose sent "
            .. "(title=%s uniqueId=%s clusterSystem=%s)", tostring(title), tostring(animal.uniqueId),
            tostring(animal.clusterSystem))
        self:close()
        return
    end

    local accepted = DiseaseVaccinateEvent.sendEvent(animal.clusterSystem.owner, animal, title)
    Log:debug("DiseaseDialog:onVaccinateConfirmed: sent title=%s uniqueId=%s farmId=%s accepted=%s",
        tostring(title), tostring(animal.uniqueId), tostring(animal.farmId), tostring(accepted))

    self:rebuildRows(title)

end


-- On a pure client the server's change arrives with the pen's next flush, so the rows rebuilt here
-- still show the old state until the dialog is opened again.
--- Rebuild the rows from the live animal, keep the selection on `title`'s row and relabel the button.
---@param title string The title whose row stays selected; the clamped previous row when none carries it.
function DiseaseDialog:rebuildRows(title)

    self.diseases, self.vaccineModels = buildRows(self.animal)
    self.diseaseList:reloadData()

    local index = self.diseaseList.selectedIndex
    for i = 1, #self.diseases + #self.vaccineModels do
        local _, model = rowAt(self, i)
        if model.title == title then
            index = i
            break
        end
    end

    -- Explicit relabel: setSelectedItem fires the selection delegate only when the index changes.
    self.diseaseList:setSelectedItem(1, index)
    self:onClickListItem(index)

    Log:trace("DiseaseDialog:rebuildRows: selected index=%s for title=%s (uniqueId=%s)", tostring(index),
        tostring(title), tostring(self.animal.uniqueId))

end


function DiseaseDialog:getNumberOfSections()

	return 1

end


--- Count the rows from the same open-time tables the cells are populated from: records, then vaccines.
---@param list table The dialog's list.
---@param section number The one section.
---@return number count
function DiseaseDialog:getNumberOfItemsInSection(list, section)

    return #self.diseases + #self.vaccineModels

end


function DiseaseDialog:getTitleForSectionHeader(list, section)

    return ""

end


--- Fill one row's cells; Duration and Fee show what the row's button acts on, else a dash.
---@param list table The dialog's list.
---@param section number The one section.
---@param index number The row index.
---@param cell table The row's cell.
function DiseaseDialog:populateCellForItemInSection(list, section, index, cell)

    local disease, model = rowAt(self, index)

    if model == nil then
        Log:trace("DiseaseDialog:populateCellForItemInSection: no row at index=%s", tostring(index))
        return
    end

    -- Duration and Fee ask the same offersDose rule the button asks, so a dose row shows the vaccine and
    -- only an INFECTIOUS row with a course shows the treatment. Both cells are written on every arm,
    -- because list cells are recycled across rows.
    local duration, fee, arm = "-", "-", "dash"

    if offersDose(self.animal, disease, model) then
        duration, fee = doseCells(model)
        arm = "dose"
    elseif disease ~= nil and disease.state == RLDiseaseRecord.STATE.INFECTIOUS and model.treatment ~= nil then
        local treatment = model.treatment
        -- Months remaining once a course is under way, the authored total otherwise. Two shipped
        -- diseases carry no treatment block, so the model.treatment clause keeps them on the dash arm.
        duration = RealisticLivestock.formatAge(disease.treatmentMonthsRemaining > 0
            and RLDiseaseStatus.wholeMonthsRemaining(disease.treatmentMonthsRemaining) or treatment.months)
        fee = string.format(g_i18n:getText("rl_ui_feePerMonth"), g_i18n:formatMoney(treatment.cost, 2, true, true))
        arm = "treatment"
    end

    Log:trace("DiseaseDialog:populateCellForItemInSection: %s cells %s|%s (index=%s title=%s uniqueId=%s)", arm,
        tostring(duration), tostring(fee), tostring(index), tostring(model.title),
        tostring(self.animal ~= nil and self.animal.uniqueId or nil))

    cell:getAttribute("title"):setText(model.name)
    cell:getAttribute("duration"):setText(duration)
    cell:getAttribute("fee"):setText(fee)

    if disease == nil then
        cell:getAttribute("status"):setText(g_i18n:getText("rl_ui_notVaccinated"))
    else
        cell:getAttribute("status"):setText(disease:getStatus())
    end

    cell.setSelected = Utils.appendedFunction(cell.setSelected, function(cell, selected)
		if selected then self:onClickListItem(index) end
	end)
    
end