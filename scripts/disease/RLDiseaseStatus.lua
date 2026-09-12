--[[
    RLDiseaseStatus.lua
    What one disease record tells the player: whether a naming surface lists it, its status
    label key, the whole months of an immune label, its card icon token, and whether it groups
    the animal as diseased. An incubating non-carrier record resolves exactly as a healthy animal does.

    Pure: no setting, no g_*, no GUI - callers gate diseasesEnabled. Reads Disease.isVisibleToPlayer,
    RLDiseaseRecord.STATE and RLDiseaseProgression.COMPLETION_EPSILON at CALL time only; nothing
    here reads them at file scope.
]]

RLDiseaseStatus = {}

local Log = RmLogging.getLogger("RLRM")


--- The five status label keys `resolve` can return. READ-ONLY by contract.
RLDiseaseStatus.KEY = {
    ["BEING_TREATED"] = "rl_ui_beingTreated",
    ["IMMUNE"] = "rl_ui_immune",
    ["TREATMENT_PAUSED"] = "rl_ui_treatmentPaused",
    ["CARRIER"] = "rl_ui_carrier",
    ["NOT_TREATED"] = "rl_ui_notTreated"
}

--- The three card icon tokens `resolve` can return. READ-ONLY by contract.
RLDiseaseStatus.ICON = {
    ["UNTREATED"] = "untreated",
    ["TREATED"] = "treated",
    ["CARRIER"] = "carrier"
}


--- The presentation of an animal with no record, and of any record a naming surface hides.
---@return table presentation A fresh table.
local function healthy()
    return { ["visible"] = false, ["diseased"] = false }
end


--- Whole months left on a count-down counter, rounded UP across the completion epsilon. Unlogged: per-frame.
---@param months number Months remaining, possibly fractional and codec-quantised.
---@return number whole Whole months, at least 1 above the epsilon and exactly 0 at or below it.
function RLDiseaseStatus.wholeMonthsRemaining(months)
    local whole = math.ceil(months - RLDiseaseProgression.COMPLETION_EPSILON)

    -- A branch rather than math.max, which can return a negative zero that renders as "-0".
    if whole <= 0 then return 0 end

    return whole
end


--- Whole months elapsed on a count-up counter, rounded DOWN across the completion epsilon. Unlogged: per-frame.
---@param months number Months elapsed, possibly fractional and codec-quantised.
---@return number whole Whole months, never below 0.
function RLDiseaseStatus.wholeMonthsElapsed(months)
    local whole = math.floor(months + RLDiseaseProgression.COMPLETION_EPSILON)

    -- Only a hand-edited save can hand this a negative counter.
    if whole < 0 then return 0 end

    return whole
end


-- The label arms keep the shipped order: a running course, RECOVERED, a paused course, a carrier,
-- then the fallback. The icon is carrier-first and ignores a pause, so card and pane can differ.
--- Resolve what one record tells the player. A fresh table every call. Unlogged: per-frame callers.
---@param record table|nil A disease record, or nil for an animal without one.
---@return table presentation `visible`, `statusKey`, `months` (immune arm only), `icon` and `diseased`.
function RLDiseaseStatus.resolve(record)
    if record == nil or not Disease.isVisibleToPlayer(record) then
        return healthy()
    end

    local STATE = RLDiseaseRecord.STATE
    local KEY = RLDiseaseStatus.KEY
    local ICON = RLDiseaseStatus.ICON

    local presentation = {
        ["visible"] = true,
        ["diseased"] = record.state == STATE.INFECTIOUS
    }

    if record.treatmentRunning then
        presentation.statusKey = KEY.BEING_TREATED
    elseif record.state == STATE.RECOVERED then
        presentation.statusKey = KEY.IMMUNE
        presentation.months = RLDiseaseStatus.wholeMonthsRemaining(record.immunityMonthsRemaining)
    -- This record's own counter alone; `or 0` tolerates a partially-deserialized record.
    elseif (record.treatmentMonthsRemaining or 0) > 0 then
        presentation.statusKey = KEY.TREATMENT_PAUSED
    elseif record.isCarrier then
        presentation.statusKey = KEY.CARRIER
    else
        presentation.statusKey = KEY.NOT_TREATED
    end

    if record.isCarrier then
        presentation.icon = ICON.CARRIER
    elseif record.state == STATE.INFECTIOUS then
        presentation.icon = record.treatmentRunning and ICON.TREATED or ICON.UNTREATED
    end

    return presentation
end


Log:trace("RLDiseaseStatus: loaded")
