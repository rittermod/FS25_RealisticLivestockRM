DiseaseDialog = {}

local diseaseDialog_mt = Class(DiseaseDialog, MessageDialog)
local modDirectory = g_currentModDirectory

--- The row icon's profiles by shape, sized for this dialog's 32px rows.
DiseaseDialog.SEVERITY_PROFILES = {
    ["circle"] = "rl_diseaseSeverityCircle",
    ["triangle"] = "rl_diseaseSeverityTriangle"
}

--- Dev-only layout spike: cycle every severity down the rows so each icon shape is on screen.
--- Never commit true.
DiseaseDialog.DEV_FORCE_ALL_SEVERITIES = false

--- Row-index cycle the dev switch uses, one of each severity.
DiseaseDialog.FORCED_SEVERITY_CYCLE = { "warning", "notice", "success", "info" }

function DiseaseDialog.register()

    local dialog = DiseaseDialog.new()
    g_gui:loadGui(modDirectory .. "gui/DiseaseDialog.xml", "DiseaseDialog", dialog)
    DiseaseDialog.INSTANCE = dialog

end


--- Construct the dialog; `measuredProfiles` scopes the icon measurement line to one per profile per reload.
---@param target table|nil
---@param customMt table|nil
---@return table self
function DiseaseDialog.new(target, customMt)

    local self = MessageDialog.new(target, customMt or diseaseDialog_mt)
    self.measuredProfiles = {}

    return self

end


function DiseaseDialog.createFromExistingGui(gui)

    DiseaseDialog.register()
    DiseaseDialog.show()

end


-- Only VISIBLE records become rows and are subtracted from the vaccine rows, so an animal incubating
-- a disease is still offered its vaccine, exactly as a healthy one is. RLDiseaseStatus.sortRows owns the order.
--- The rows for one animal, sorted: its visible records and the vaccines it can take that no visible record names.
---@param animal table The animal being shown.
---@return table rows A fresh array of `{ record = <visible record or nil>, model = <registry entry> }`.
local function buildRows(animal)

    local rows = {}
    local listed = {}
    for _, record in ipairs(animal:getVisibleDiseases()) do
        listed[record.title] = true
        rows[#rows + 1] = { record = record, model = record.model }
    end

    local recordRows = #rows
    for _, model in ipairs(g_diseaseManager:getVaccineModelsFor(animal)) do
        if not listed[model.title] then rows[#rows + 1] = { model = model } end
    end

    -- Read at call time: this file is sourced before RLDiseaseStatus.
    rows = RLDiseaseStatus.sortRows(rows)

    local order = {}
    for i, row in ipairs(rows) do
        order[i] = string.format("%s(%s)", tostring(row.model.title),
            tostring(RLDiseaseStatus.rowGroup(row.record, row.model)))
    end

    Log:debug("DiseaseDialog: rows built, %s of %s records and %s vaccine row(s), order %s (uniqueId=%s)",
        tostring(recordRows), tostring(animal.diseases ~= nil and #animal.diseases or nil),
        tostring(#rows - recordRows), table.concat(order, ","), tostring(animal.uniqueId))

    return rows

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

    local row = dialog.rows[index]
    if row == nil then
        Log:trace("DiseaseDialog rowAt: no row, index=%s past the last of %s (uniqueId=%s)", tostring(index),
            tostring(#dialog.rows), tostring(uniqueId))
        return nil, nil
    end

    Log:trace("DiseaseDialog rowAt: %s row index=%s title=%s uniqueId=%s",
        row.record ~= nil and "record" or "vaccine", tostring(index), tostring(row.model.title), tostring(uniqueId))
    return row.record, row.model

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


-- Asks the button's own offer rule; the not-treated and paused groups are the button's treatment gate
-- minus a running course, so the selected row offers Start, Resume or Vaccinate whenever any row does.
--- The first row whose OK button offers Start, Resume or Vaccinate, else row 1.
---@param dialog table The dialog instance, its `rows` built.
---@return number index
local function firstActionIndex(dialog)

    local animal = dialog.animal
    local uniqueId = animal ~= nil and animal.uniqueId or nil
    -- Read at call time: this file is sourced before RLDiseaseStatus.
    local GROUP = RLDiseaseStatus.ROW_GROUP

    for index, row in ipairs(dialog.rows) do
        local group = RLDiseaseStatus.rowGroup(row.record, row.model)
        if offersDose(animal, row.record, row.model) or group == GROUP.NOT_TREATED
            or group == GROUP.TREATMENT_PAUSED then
            Log:trace("DiseaseDialog firstActionIndex: index=%s title=%s, first action (uniqueId=%s)",
                tostring(index), tostring(row.model.title), tostring(uniqueId))
            return index
        end
    end

    local first = dialog.rows[1]
    Log:trace("DiseaseDialog firstActionIndex: index=1 title=%s, no action, row 1 (uniqueId=%s)",
        tostring(first ~= nil and first.model.title or nil), tostring(uniqueId))
    return 1

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


-- The OK button's label and the confirm it opens both ask this, so the two always name the same action.
--- The treatment action a record's status calls for: "stop" on a running course, "resume" on a paused one.
---@param disease table A visible record at INFECTIOUS whose model has `treatment`.
---@return string action "start", "resume" or "stop".
local function treatmentAction(disease)

    -- Read at call time: this file is sourced before RLDiseaseStatus.
    local KEY = RLDiseaseStatus.KEY
    local statusKey = RLDiseaseStatus.resolve(disease).statusKey
    local action = statusKey == KEY.BEING_TREATED and "stop"
        or (statusKey == KEY.TREATMENT_PAUSED and "resume" or "start")

    Log:trace("DiseaseDialog treatmentAction: %s (statusKey=%s title=%s)", action, tostring(statusKey),
        tostring(disease.title))
    return action

end


-- Shared by the Duration cell and the Start / Resume confirms, so the confirm names the months the row shows.
--- A course's Duration: the whole months left once a course is under way, the authored total otherwise.
---@param disease table A record at INFECTIOUS.
---@param treatment table The record's `treatment` block.
---@return string duration
local function courseDuration(disease, treatment)

    -- Read at call time: this file is sourced before RLDiseaseStatus.
    return RealisticLivestock.formatAge(disease.treatmentMonthsRemaining > 0
        and RLDiseaseStatus.wholeMonthsRemaining(disease.treatmentMonthsRemaining) or treatment.months)

end


--- One element's absolute x and width in reference pixels, or nil when it has no settled geometry.
---@param element table|nil
---@return string|nil span "x/width"
local function spanOf(element)

    if element == nil or element.absPosition == nil or element.absSize == nil then return nil end

    return string.format("%.1f/%.1f", element.absPosition[1] * g_referenceScreenWidth,
        element.absSize[1] * g_referenceScreenWidth)

end


-- The first row comes from the list's own cell lookup, never from counting its pooled child cells.
--- Log the measured geometry: dialog, list and header labels, then the first row's four cells when it has them.
---@param dialog table The open dialog instance.
local function logGeometry(dialog)

    local list = dialog.diseaseList

    local headers = {}
    for i, id in ipairs({ "titleHeader", "statusHeader", "durationHeader", "feeHeader" }) do
        headers[i] = string.format("%s=%s", id, tostring(spanOf(dialog[id])))
    end

    local cells = "none"
    local row = list:getItemCount() > 0 and list:getElementAtSectionIndex(1, 1) or nil
    if row == nil then
        Log:trace("DiseaseDialog:onOpen: geometry has no first row to measure (items=%s)",
            tostring(list:getItemCount()))
    else
        local parts = {}
        for _, name in ipairs({ "title", "status", "duration", "fee" }) do
            local span = spanOf(row:getAttribute(name))
            if span == nil then
                Log:trace("DiseaseDialog:onOpen: geometry first row has no settled %s cell", name)
                parts = nil
                break
            end
            parts[#parts + 1] = string.format("%s=%s", name, span)
        end
        if parts ~= nil then cells = table.concat(parts, " ") end
    end

    Log:debug("DiseaseDialog:onOpen: geometry dialog=%s list=%s headers %s cells %s (uniqueId=%s)",
        tostring(spanOf(dialog.dialogElement)), tostring(spanOf(list)), table.concat(headers, " "), cells,
        tostring(dialog.animal ~= nil and dialog.animal.uniqueId or nil))

end


-- Refuses while diseases are off, and both callers funnel through here. It does not close a dialog
-- already open, and the rows are a snapshot, rebuilt only on open and after the player's own action.
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
    -- A fresh array: the row count and the cells both read it, never the animal's live array.
    dialog.rows = buildRows(animal)
    dialog.onCloseCallback = onCloseCallback
    dialog.onCloseTarget = onCloseTarget

    g_gui:showDialog("DiseaseDialog")

end


--- Load the list, select `firstActionIndex`'s row, set the OK and Cull buttons, then log the geometry.
function DiseaseDialog:onOpen()

    DiseaseDialog:superClass().onOpen(self)

    self.isColorBlindMode = RLSeverityIcon.readColorBlindMode()
    Log:debug("DiseaseDialog:onOpen: colorBlind=%s forced=%s (uniqueId=%s)", tostring(self.isColorBlindMode),
        tostring(DiseaseDialog.DEV_FORCE_ALL_SEVERITIES), tostring(self.animal ~= nil and self.animal.uniqueId))

    -- The singleton reuses its list and reloadData only clamps a stale index, so the highlight is
    -- set and the button seeded explicitly: setSelectedItem fires the selection delegate only when
    -- the index changes. reloadData populates synchronously, so the reset scopes the measurement to it.
    self.measuredProfiles = {}
    self.diseaseList:reloadData()
    local index = firstActionIndex(self)
    self.diseaseList:setSelectedItem(1, index)

    self:onClickListItem(index)

    self:updateCullButton()

    logGeometry(self)

    Log:trace("DiseaseDialog:onOpen: opened, selected index=%s (uniqueId=%s)", tostring(index),
        tostring(self.animal ~= nil and self.animal.uniqueId))

end


--- Fire optional close callback so the parent screen can refresh.
function DiseaseDialog:onClose()
    DiseaseDialog:superClass().onClose(self)

    if self.onCloseCallback ~= nil then
        Log:trace("DiseaseDialog:onClose: firing close callback")
        self.onCloseCallback(self.onCloseTarget)
    end
end


--- The OK button: a dose row opens the vaccinate confirm, a treatable record row the treatment confirm.
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

    self:confirmTreatment(disease, treatmentAction(disease))

end


--- Label the OK button for one row: Vaccinate on a dose row, the course label on a treatable record, else disabled.
---@param index number|nil The row's index in `rows`.
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
    -- the button is offered, that one decides whether the click is honoured. RLDiseaseStatus.rowGroup
    -- copies it minus a running course, and must agree too.
    if disease == nil or disease.model.treatment == nil
        or disease.state ~= RLDiseaseRecord.STATE.INFECTIOUS then

        self.yesButton:setDisabled(true)
        -- Reset, or the disabled button keeps the label the previously selected row gave it.
        self.yesButton:setText(g_i18n:getText("rl_ui_startTreatment"))
        Log:trace("DiseaseDialog:onClickListItem: button disabled, label reset (index=%s)", tostring(index))
        return

    end

    self.yesButton:setDisabled(false)

    local label = treatmentAction(disease)

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

    self:rebuildRows()

end


--- Ask the player to confirm starting, resuming or stopping one course, naming the animal and the disease.
---@param disease table The row's record, at INFECTIOUS with a `treatment`.
---@param action string "start", "resume" or "stop", as `treatmentAction` labels the button.
function DiseaseDialog:confirmTreatment(disease, action)

    local animal = self.animal
    local model = disease.model
    local cost = model.treatment.cost
    local label = animalLabel(animal)
    local text, title, dialogType, duration

    if action == "stop" then
        text = string.format(g_i18n:getText("rl_ui_stopTreatmentConfirm"), label, model.name)
        title = g_i18n:getText("ui_attention")
        dialogType = DialogElement.TYPE_WARNING
    else
        local textKey = action == "resume" and "rl_ui_resumeTreatmentConfirm" or "rl_ui_startTreatmentConfirm"
        local titleKey = action == "resume" and "rl_ui_resumeTreatment" or "rl_ui_startTreatment"
        duration = courseDuration(disease, model.treatment)
        text = string.format(g_i18n:getText(textKey), label, model.name, duration,
            g_i18n:formatMoney(cost, 0, true, true))
        title = g_i18n:getText(titleKey)
        dialogType = DialogElement.TYPE_QUESTION
    end

    Log:debug("DiseaseDialog:confirmTreatment: confirming title=%s action=%s duration=%s cost=%s "
        .. "uniqueId=%s farmId=%s", tostring(disease.title), tostring(action), tostring(duration), tostring(cost),
        tostring(animal.uniqueId), tostring(animal.farmId))
    YesNoDialog.show(self.onTreatmentConfirmed, self, text, title, nil, nil, dialogType, nil, nil,
        { title = disease.title, action = action })

end


-- The confirm can stay open across a daily tick, so Yes re-reads the ANIMAL's record: a course can end, or
-- the animal recover or die, meanwhile. A Stop confirmed on a course that already ended must not start one.
--- The confirm's answer: on Yes toggle the course when the live record still calls for it; on No do nothing.
---@param yes boolean True when the player confirmed.
---@param args table `{ title = <disease title>, action = "start" | "resume" | "stop" }` from the confirm.
function DiseaseDialog:onTreatmentConfirmed(yes, args)

    local animal = self.animal
    local title, action = args.title, args.action

    if not yes then
        Log:trace("DiseaseDialog:onTreatmentConfirmed: declined (title=%s action=%s uniqueId=%s)", tostring(title),
            tostring(action), tostring(animal.uniqueId))
        return
    end

    if animal.clusterSystem == nil or animal.clusterSystem.owner == nil then
        Log:warning("DiseaseDialog:onTreatmentConfirmed: the animal is in no pen, no toggle sent "
            .. "(title=%s action=%s uniqueId=%s clusterSystem=%s)", tostring(title), tostring(action),
            tostring(animal.uniqueId), tostring(animal.clusterSystem))
        self:close()
        return
    end

    local liveDisease = animal:getDisease(title)
    local wantRunning = action == "stop"
    local reason

    if liveDisease == nil then
        reason = "gone"
    elseif liveDisease.state ~= RLDiseaseRecord.STATE.INFECTIOUS then
        reason = "not-infectious"
    elseif liveDisease.model.treatment == nil then
        reason = "untreatable"
    elseif (liveDisease.treatmentRunning == true) ~= wantRunning then
        reason = "running-state-moved"
    end

    if reason ~= nil then
        Log:debug("DiseaseDialog:onTreatmentConfirmed: refused, reason=%s (title=%s action=%s uniqueId=%s)",
            reason, tostring(title), tostring(action), tostring(animal.uniqueId))
        self:rebuildRows()
        return
    end

    local newState = not liveDisease.treatmentRunning
    local husbandry = animal.clusterSystem.owner

    -- Read BEFORE the seed, or a fresh start reads its own seeded counter and says RESUME.
    local isResuming = liveDisease.treatmentMonthsRemaining > 0

    Log:debug("DiseaseDialog:onTreatmentConfirmed: sending title=%s action=%s treatment=%s "
        .. "treatmentMonthsRemaining=%s uniqueId=%s farmId=%s", tostring(title), tostring(action), tostring(newState),
        tostring(liveDisease.treatmentMonthsRemaining), tostring(animal.uniqueId), tostring(animal.farmId))
    DiseaseTreatmentToggleEvent.sendEvent(husbandry, animal, title, newState)

    -- The flag LEADS the writes, as everywhere else on this path: it is the sole cause of
    -- replication, so writing it last puts it behind every statement that can raise.
    animal:setDirty()

    liveDisease.treatmentRunning = newState

    -- START only. On a RESUME the refusal of a non-zero counter IS the pause contract - the
    -- served months survive because nothing writes the counter down.
    if newState then
        RLDiseaseRecord.enrolTreatment(liveDisease, liveDisease.model.treatment)
    end

    local model = liveDisease.model
    if not newState then
        animal:addMessage("DISEASE_TREATMENT_STOP", { model.name })
    else
        local fee = g_i18n:formatMoney(model.treatment.cost, 2, true, true)
        animal:addMessage("DISEASE_TREATMENT_" .. (isResuming and "RESUME" or "START"),
            { model.name, string.format(g_i18n:getText("rl_ui_feePerMonth"), fee) })
    end

    self:rebuildRows()

end


-- After a dose on a pure client the record arrives with the pen's next flush, so the rows rebuilt here
-- still show the old state until the dialog is opened again; a treatment toggle writes its record locally first.
--- Rebuild and re-sort the rows from the live animal, select `firstActionIndex`'s row and relabel the button.
function DiseaseDialog:rebuildRows()

    self.rows = buildRows(self.animal)
    self.measuredProfiles = {}
    self.diseaseList:reloadData()

    local index = firstActionIndex(self)

    -- Explicit relabel: setSelectedItem fires the selection delegate only when the index changes.
    self.diseaseList:setSelectedItem(1, index)
    self:onClickListItem(index)

    Log:trace("DiseaseDialog:rebuildRows: selected index=%s (uniqueId=%s)", tostring(index),
        tostring(self.animal.uniqueId))

end


function DiseaseDialog:getNumberOfSections()

	return 1

end


--- Count the rows from the same sorted array the cells are populated from.
---@param list table The dialog's list.
---@param section number The one section.
---@return number count
function DiseaseDialog:getNumberOfItemsInSection(list, section)

    return #self.rows

end


function DiseaseDialog:getTitleForSectionHeader(list, section)

    return ""

end


--- Fill one row's cells: the severity icon, then Duration and Fee for what the row's button acts on, else a dash.
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

    -- Applied on every row, so an INFO row hides an icon its recycled cell still carries.
    -- Read at call time: this file is sourced before RLDiseaseStatus.
    local severity = RLDiseaseStatus.rowSeverity(disease, model)
    if DiseaseDialog.DEV_FORCE_ALL_SEVERITIES then
        local cycle = DiseaseDialog.FORCED_SEVERITY_CYCLE
        severity = cycle[(index - 1) % #cycle + 1]
    end
    local icon = cell:getAttribute("severity")
    local shown = RLSeverityIcon.apply(icon, severity, self.isColorBlindMode, DiseaseDialog.SEVERITY_PROFILES)
    local measured = shown and not self.measuredProfiles[icon.profile]
    if measured then
        self.measuredProfiles[icon.profile] = true
        Log:debug("DiseaseDialog: severity icon profile=%s size=%.1fx%.1f pos=%.1f,%.1f abs=%.1f,%.1f",
            tostring(icon.profile), icon.size[1] * 1920, icon.size[2] * 1080,
            icon.position[1] * 1920, icon.position[2] * 1080,
            icon.absPosition[1] * 1920, icon.absPosition[2] * 1080)
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
        -- Two shipped diseases carry no treatment block, so the model.treatment clause keeps them on the dash arm.
        duration = courseDuration(disease, treatment)
        fee = string.format(g_i18n:getText("rl_ui_feePerMonth"), g_i18n:formatMoney(treatment.cost, 2, true, true))
        arm = "treatment"
    end

    Log:trace("DiseaseDialog:populateCellForItemInSection: %s cells %s|%s severity=%s shown=%s measured=%s "
        .. "forced=%s (index=%s title=%s uniqueId=%s)", arm, tostring(duration), tostring(fee), tostring(severity),
        tostring(shown), tostring(measured), tostring(DiseaseDialog.DEV_FORCE_ALL_SEVERITIES), tostring(index),
        tostring(model.title),
        tostring(self.animal ~= nil and self.animal.uniqueId or nil))

    cell:getAttribute("title"):setText(model.name)
    cell:getAttribute("duration"):setText(duration)
    cell:getAttribute("fee"):setText(fee)

    if disease == nil then
        cell:getAttribute("status"):setText(g_i18n:getText("rl_ui_notVaccinated"))
    else
        cell:getAttribute("status"):setText(disease:getStatus())
    end

    -- Pooled cells outlive a reload, so the hook goes on once per cell and reads the row the list
    -- assigned last; a captured index would go stale on the next populate.
    if not cell.rlDiseaseSelectHooked then
        cell.rlDiseaseSelectHooked = true
        cell.setSelected = Utils.appendedFunction(cell.setSelected, function(cell, selected)
            if selected then self:onClickListItem(cell.indexInSection) end
        end)
        Log:trace("DiseaseDialog:populateCellForItemInSection: select hook installed (index=%s)", tostring(index))
    end

end