-- RLFilterConditionDialog.lua
-- Modal editor for a single saveable-filter condition (field / cmp / value). The calling
-- frame passes itself as `target` and receives the coerced condition on OK, nil on Cancel.
--
-- Field-change coercion delegates to RLFilterFieldCatalog.coerceConditionOnFieldChange. All
-- number validation - tonumber plus a NaN and Inf reject - happens at OK click.

local Log = RmLogging.getLogger("RLRM")

RLFilterConditionDialog = {}

local RLFilterConditionDialog_mt = Class(RLFilterConditionDialog, MessageDialog)
local modDirectory = g_currentModDirectory

-- Editor-side cmp gate: `in`/`notin` reach ENUM fields only, through
-- RLFilterValueSetDialog. STRING stays scalar-only.
local UNSUPPORTED_CMPS_BY_TYPE = {
    number = { ["in"] = true, ["notin"] = true },  -- multi-value numeric editor never specced
    bool   = {},                                    -- BOOL_CMPS = {"=="} only; no exclusions needed
    enum   = {},                                    -- In/notin now editable
    string = { ["in"] = true, ["notin"] = true },  -- substring cmps only
}

-- Field types this dialog can render: number, bool, enum (gender / subType
-- single-pick), and string (name contains / notcontains). Multi-value
-- editor for in/notin (ENUM only) opens RLFilterValueSetDialog.
local SUPPORTED_TYPES_DIALOG = { number = true, bool = true, enum = true, string = true }

-- =============================================================================
-- Lifecycle: register + new + show
-- =============================================================================

function RLFilterConditionDialog.register()
    local dialog = RLFilterConditionDialog.new()
    g_gui:loadGui(modDirectory .. "gui/rlFilterConditionDialog.xml",
                  "RLFilterConditionDialog", dialog)
    RLFilterConditionDialog.INSTANCE = dialog
    Log:debug("RLFilterConditionDialog.register: dialog registered")
end

function RLFilterConditionDialog.new(target, customMt)
    local self = MessageDialog.new(target, customMt or RLFilterConditionDialog_mt)

    self.callback         = nil
    self.callbackTarget   = nil
    self.initialCondition = nil
    self.rowIndex         = nil
    self.animalType       = nil

    -- Working state (mutated by widget callbacks; flushed to caller on OK).
    self.workingField   = nil
    self.workingCmp     = nil
    self.workingValue   = nil
    self.workingRawText = nil

    -- Cached widget input data (rebuilt per onOpen and per onFieldChanged).
    self.fieldOptions = {}
    self.cmpOptions   = {}

    return self
end

--- Static entry point. Mirrors AnimalMoveDestinationDialog.show.
---@param callback function fn(target, newCondition|nil, rowIndex)
---@param target table callback target (the calling frame)
---@param initialCondition table|nil {field, cmp, value, rawText?} or nil for new
---@param rowIndex number|nil 1-based row index for edit; nil for new
---@param animalType number|nil AnimalType index or nil for ANY
function RLFilterConditionDialog.show(callback, target, initialCondition, rowIndex, animalType)
    if RLFilterConditionDialog.INSTANCE == nil then
        RLFilterConditionDialog.register()
    end

    local dialog = RLFilterConditionDialog.INSTANCE
    dialog.callback         = callback
    dialog.callbackTarget   = target
    dialog.initialCondition = initialCondition
    dialog.rowIndex         = rowIndex
    dialog.animalType       = animalType

    Log:debug("RLFilterConditionDialog.show: rowIndex=%s initialField=%s animalType=%s",
        tostring(rowIndex),
        initialCondition and tostring(initialCondition.field) or "nil(new)",
        tostring(animalType))

    g_gui:showDialog("RLFilterConditionDialog")
end

-- =============================================================================
-- Element resolution (once per clone, before first onOpen)
-- =============================================================================

function RLFilterConditionDialog:onGuiSetupFinished()
    RLFilterConditionDialog:superClass().onGuiSetupFinished(self)

    self.fieldPicker      = self:getDescendantById("fieldPicker")
    self.cmpPicker        = self:getDescendantById("cmpPicker")
    self.valueNumberInput = self:getDescendantById("valueNumberInput")
    self.valueBoolPicker  = self:getDescendantById("valueBoolPicker")
    self.valueEnumPicker  = self:getDescendantById("valueEnumPicker")
    self.valueStringInput = self:getDescendantById("valueStringInput")
    self.valueSetButton   = self:getDescendantById("valueSetButton")
    self.hintText         = self:getDescendantById("hintText")
    self.okButton         = self:getDescendantById("okButton")
    -- Measurement: resolve label elements too so onOpen can log
    -- their rendered geometry for position/width math.
    self.fieldLabel       = self:getDescendantById("fieldLabel")
    self.cmpLabel         = self:getDescendantById("cmpLabel")
    self.valueLabel       = self:getDescendantById("valueLabel")

    local missing = {}
    if self.fieldPicker      == nil then table.insert(missing, "fieldPicker") end
    if self.cmpPicker        == nil then table.insert(missing, "cmpPicker") end
    if self.valueNumberInput == nil then table.insert(missing, "valueNumberInput") end
    if self.valueBoolPicker  == nil then table.insert(missing, "valueBoolPicker") end
    if self.valueEnumPicker  == nil then table.insert(missing, "valueEnumPicker") end
    if self.valueStringInput == nil then table.insert(missing, "valueStringInput") end
    if self.valueSetButton   == nil then table.insert(missing, "valueSetButton") end
    if self.hintText         == nil then table.insert(missing, "hintText") end
    if #missing > 0 then
        Log:warning("RLFilterConditionDialog:onGuiSetupFinished: missing elements: %s",
            table.concat(missing, ","))
    else
        Log:trace("RLFilterConditionDialog:onGuiSetupFinished: all elements resolved")
    end
end

-- =============================================================================
-- Measurement helper: logs absolute on-screen geometry for (name, element) pairs, scaled to
-- a 1920x1080 reference, so position math rests on rendered values rather than guesses.
-- =============================================================================
function RLFilterConditionDialog:_logGeometry(label, items)
    if Log == nil or Log.debug == nil then return end
    for _, pair in ipairs(items) do
        local name, e = pair[1], pair[2]
        if e ~= nil then
            local ax = (e.absPosition and e.absPosition[1] or 0) * g_referenceScreenWidth
            local ay = (e.absPosition and e.absPosition[2] or 0) * g_referenceScreenHeight
            local sw = (e.size and e.size[1] or 0) * g_referenceScreenWidth
            local sh = (e.size and e.size[2] or 0) * g_referenceScreenHeight
            Log:debug("RLFilterConditionDialog._logGeometry[%s]: %s absPos=(%.1f,%.1f) size=(%.1fx%.1f) leftEdge=%.1f rightEdge=%.1f topEdge=%.1f bottomEdge=%.1f",
                label, name, ax, ay, sw, sh, ax, ax + sw, ay + sh, ay)
        else
            Log:debug("RLFilterConditionDialog._logGeometry[%s]: %s == nil", label, name)
        end
    end
end

-- =============================================================================
-- Hint surface
-- =============================================================================

--- Show a translated hint in the dialog's hintText element, from a reject path.
---
--- Varargs are interpolated AFTER the i18n lookup, so a reject can pass numeric bounds into
--- the resolved text.
---@param l10nKey string
---@param ... any optional format arguments interpolated into the resolved text
function RLFilterConditionDialog:showHint(l10nKey, ...)
    if self.hintText == nil then
        Log:warning("RLFilterConditionDialog:showHint: hintText element missing; cannot surface key=%s",
            tostring(l10nKey))
        return
    end
    local text = (g_i18n ~= nil and g_i18n.hasText ~= nil and g_i18n:hasText(l10nKey))
                 and g_i18n:getText(l10nKey)
                 or tostring(l10nKey)
    if select("#", ...) > 0 then
        local ok, formatted = pcall(string.format, text, ...)
        if ok then
            text = formatted
        else
            Log:warning("RLFilterConditionDialog:showHint: string.format failed for key=%s; falling back to raw text. err=%s",
                tostring(l10nKey), tostring(formatted))
        end
    end
    self.hintText:setText(text)
    if self.hintText.setVisible ~= nil then self.hintText:setVisible(true) end
    Log:debug("RLFilterConditionDialog:showHint: key=%s text='%s'",
        tostring(l10nKey), tostring(text))
end

--- Clear the hint surface. Called on field change + cmp change so a stale
--- reject hint doesn't persist across user input.
function RLFilterConditionDialog:clearHint()
    if self.hintText == nil then return end
    self.hintText:setText("")
    if self.hintText.setVisible ~= nil then self.hintText:setVisible(false) end
    Log:trace("RLFilterConditionDialog:clearHint")
end

-- =============================================================================
-- Helpers (pure-ish; read/write working state)
-- =============================================================================

--- Filter newField.cmps down to the editable subset per field type.
--- ENUM now exposes `in`/`notin`; STRING and NUMBER keep the
--- multi-value cmps gated. The catalog has full cmp lists per field type;
--- this gate is the dialog's view of what it can actually edit.
local function editableCmpsFor(field)
    local out = {}
    if field == nil or field.cmps == nil then return out end
    local excludeSet = UNSUPPORTED_CMPS_BY_TYPE[field.type] or {}
    for _, c in ipairs(field.cmps) do
        if not excludeSet[c] then
            table.insert(out, c)
        end
    end
    Log:trace("RLFilterConditionDialog.editableCmpsFor: type=%s cmps=%d (excluded %d)",
        tostring(field.type), #out, #field.cmps - #out)
    return out
end

--- Resolve the index of `field.key` in `self.fieldOptions`. Returns nil if absent.
local function indexOfFieldOption(self, key)
    for i, f in ipairs(self.fieldOptions) do
        if f.key == key then return i end
    end
    return nil
end

--- Resolve the index of `cmp` in `self.cmpOptions`. Returns nil if absent.
local function indexOfCmpOption(self, cmp)
    for i, c in ipairs(self.cmpOptions) do
        if c == cmp then return i end
    end
    return nil
end

-- =============================================================================
-- onOpen: populate widgets from initialCondition (or defaults for new)
-- =============================================================================

function RLFilterConditionDialog:onOpen()
    RLFilterConditionDialog:superClass().onOpen(self)

    -- Field options for the active animalType. An enum field whose domain resolves empty is
    -- dropped, so the picker never offers an unpickable option.
    local catalogFields = RLFilterFieldCatalog.getAllForAnimalType(
        self.animalType, SUPPORTED_TYPES_DIALOG)
    self.fieldOptions = {}
    for _, f in ipairs(catalogFields) do
        if f.type == "enum" then
            -- subType under animalType=nil routes through the cross-species union; gender and
            -- scoped subType use the scoped getEnumDomain. Both drop an empty domain.
            local domain
            if f.key == "subType" and self.animalType == nil then
                domain = RLFilterFieldDisplay.getEnumDomainForUnscopedFilter("subType")
            else
                domain = RLFilterFieldDisplay.getEnumDomain(f.key, self.animalType)
            end
            if domain ~= nil and #domain > 0 then
                table.insert(self.fieldOptions, f)
            else
                Log:trace("RLFilterConditionDialog:onOpen: excluding enum field=%s (empty domain for animalType=%s)",
                    tostring(f.key), tostring(self.animalType))
            end
        else
            table.insert(self.fieldOptions, f)
        end
    end
    if #self.fieldOptions == 0 then
        Log:warning("RLFilterConditionDialog:onOpen: zero field options for animalType=%s; closing",
            tostring(self.animalType))
        self:close()
        return
    end

    -- Seed working state from initialCondition or per-type defaults.
    if self.initialCondition ~= nil then
        self.workingField   = self.initialCondition.field
        self.workingCmp     = self.initialCondition.cmp
        self.workingValue   = self.initialCondition.value
        self.workingRawText = self.initialCondition.rawText
        Log:trace("RLFilterConditionDialog:onOpen: seeded from initialCondition field=%s cmp=%s value=%s",
            tostring(self.workingField), tostring(self.workingCmp), tostring(self.workingValue))
    else
        local firstField = self.fieldOptions[1]
        self.workingField   = firstField.key
        self.workingCmp     = RLFilterFieldCatalog.getDefaultCmpForField(firstField)
        self.workingValue   = RLFilterFieldCatalog.getDefaultValueForType(firstField.type)
        self.workingRawText = nil
        -- Enum default value is domain-driven (catalog returns nil for
        -- enum; RLFilterFieldDisplay owns the domain). Seed domain[1] when the
        -- starting field is enum so refreshValueWidget has something to render.
        if firstField.type == "enum" then
            self.workingValue = self:resolveDefaultEnumValue(firstField.key)
        end
        Log:trace("RLFilterConditionDialog:onOpen: defaults field=%s cmp=%s value=%s",
            tostring(self.workingField), tostring(self.workingCmp), tostring(self.workingValue))
    end

    -- Reset hint surface so a previous reject hint doesn't bleed across dialogs.
    self:clearHint()
    -- Reset the drift flag at open: the dialog is a singleton, so a cancelled drifted edit
    -- would otherwise leak its flag into the next edit and refuse OK on a clean row.
    self.valueDrifted = false

    self:refreshFieldPicker()
    self:refreshCmpPicker()
    self:refreshValueWidget()

    -- One-shot geometry log so position math is grounded in actual
    -- rendered values. Logged on every onOpen (cheap, DEBUG level, only when
    -- dialog is opened).
    self:_logGeometry("onOpen", {
        {"fieldLabel",       self.fieldLabel},
        {"cmpLabel",         self.cmpLabel},
        {"valueLabel",       self.valueLabel},
        {"fieldPicker",      self.fieldPicker},
        {"cmpPicker",        self.cmpPicker},
        {"valueNumberInput", self.valueNumberInput},
        {"valueStringInput", self.valueStringInput},
        {"valueBoolPicker",  self.valueBoolPicker},
        {"valueEnumPicker",  self.valueEnumPicker},
        {"valueSetButton",   self.valueSetButton},
        {"hintText",         self.hintText},
        {"okButton",         self.okButton},
    })
end

--- Resolve domain[1] for an enum field, nil when the domain is empty. subType under an
--- unscoped filter routes through the cross-species union, matching the field picker.
---@param fieldKey string
---@return string|nil
function RLFilterConditionDialog:resolveDefaultEnumValue(fieldKey)
    local domain
    if fieldKey == "subType" and self.animalType == nil then
        domain = RLFilterFieldDisplay.getEnumDomainForUnscopedFilter("subType")
    else
        domain = RLFilterFieldDisplay.getEnumDomain(fieldKey, self.animalType)
    end
    if domain == nil or #domain == 0 then
        Log:trace("RLFilterConditionDialog:resolveDefaultEnumValue: empty domain for fieldKey=%s animalType=%s",
            tostring(fieldKey), tostring(self.animalType))
        return nil
    end
    return domain[1]
end

-- =============================================================================
-- Picker refreshers (rebuild widget contents from working state)
-- =============================================================================

--- Resolve a localized field label using the existing key namespace.
--- Falls back to the raw key when no l10n entry exists.
local function resolveFieldLabel(key)
    if key == nil then return "" end
    local safe = key:gsub("%.", "_")
    local lookup = "rl_menu_filters_field_" .. safe
    if g_i18n:hasText(lookup) then
        return g_i18n:getText(lookup)
    end
    return key
end

function RLFilterConditionDialog:refreshFieldPicker()
    if self.fieldPicker == nil then return end
    local labels = {}
    for i, f in ipairs(self.fieldOptions) do
        labels[i] = resolveFieldLabel(f.key)
    end
    self.fieldPicker:setTexts(labels)
    local idx = indexOfFieldOption(self, self.workingField) or 1
    self.fieldPicker:setState(idx, false)
    Log:trace("RLFilterConditionDialog:refreshFieldPicker: %d options, selected=%d (%s)",
        #labels, idx, tostring(self.workingField))
end

function RLFilterConditionDialog:refreshCmpPicker()
    if self.cmpPicker == nil then return end
    local field = RLFilterFieldCatalog.get(self.workingField)
    self.cmpOptions = editableCmpsFor(field)
    -- Parallel label array: the picker shows plain-English labels while self.cmpOptions stays
    -- the raw symbols. onCmpChanged and indexOfCmpOption key on the symbol, so feeding labels
    -- into cmpOptions would corrupt the stored cmp on the next OK.
    local cmpLabels = {}
    for i, cmp in ipairs(self.cmpOptions) do
        cmpLabels[i] = RLFilterFieldDisplay.getCmpDisplayName(cmp)
    end
    self.cmpPicker:setTexts(cmpLabels)
    local idx = indexOfCmpOption(self, self.workingCmp) or 1
    self.cmpPicker:setState(idx, false)
    Log:trace("RLFilterConditionDialog:refreshCmpPicker: %d cmps, %d labels, selected=%d (%s)",
        #self.cmpOptions, #cmpLabels, idx, tostring(self.workingCmp))
end

--- Hide every value widget, so each type branch in refreshValueWidget only shows its own.
function RLFilterConditionDialog:_hideAllValueWidgets()
    if self.valueNumberInput ~= nil then self.valueNumberInput:setVisible(false) end
    if self.valueBoolPicker  ~= nil then self.valueBoolPicker:setVisible(false)  end
    if self.valueEnumPicker  ~= nil then self.valueEnumPicker:setVisible(false)  end
    if self.valueStringInput ~= nil then self.valueStringInput:setVisible(false) end
    if self.valueSetButton   ~= nil then self.valueSetButton:setVisible(false)   end
end

--- Resolve the active enum domain for the current working field, honoring
--- the subType cross-species union when animalType=nil. Used by the
--- enum picker + list-mode drift check + summary widget.
function RLFilterConditionDialog:_resolveActiveEnumDomain()
    if self.workingField == "subType" and self.animalType == nil then
        return RLFilterFieldDisplay.getEnumDomainForUnscopedFilter("subType")
    end
    return RLFilterFieldDisplay.getEnumDomain(self.workingField, self.animalType)
end

--- Update the summary button text to the current list length. Count-only: the labels
--- themselves live one click away in the value-set dialog.
function RLFilterConditionDialog:refreshValueSetSummary()
    if self.valueSetButton == nil then return end
    local n = 0
    if type(self.workingValue) == "table" then n = #self.workingValue end
    local text
    if g_i18n ~= nil and g_i18n.hasText ~= nil and g_i18n:hasText("rl_menu_filters_valueSet_summary") then
        text = string.format(g_i18n:getText("rl_menu_filters_valueSet_summary"), n)
    else
        text = string.format("%d selected", n)
    end
    self.valueSetButton:setText(text)
    Log:trace("RLFilterConditionDialog:refreshValueSetSummary: n=%d text='%s'",
        n, tostring(text))
end

function RLFilterConditionDialog:refreshValueWidget()
    local field = RLFilterFieldCatalog.get(self.workingField)
    if field == nil then
        Log:warning("RLFilterConditionDialog:refreshValueWidget: workingField=%s not in catalog",
            tostring(self.workingField))
        return
    end

    self:_hideAllValueWidgets()

    -- Clear the drift flag at the top of every refresh; the checks below re-set it only when
    -- the value really falls outside the live domain.
    self.valueDrifted = false

    -- List-shape branch: `in`/`notin` on an enum field shows the summary button instead of a
    -- scalar widget. Any value outside the resolved domain sets valueDrifted, and onClickOk
    -- refuses until the user re-commits through the value-set dialog.
    if field.type == "enum" and (self.workingCmp == "in" or self.workingCmp == "notin") then
        local domain = self:_resolveActiveEnumDomain() or {}
        self.valueEnumDomain = domain
        if #domain == 0 then
            Log:warning("RLFilterConditionDialog:refreshValueWidget: enum domain empty for list-mode field=%s animalType=%s",
                tostring(self.workingField), tostring(self.animalType))
            self:showHint("rl_menu_filters_subtypeRequiresAnimalType")
            return
        end
        -- List-shape drift check: any element of workingValue not in domain
        -- trips valueDrifted. workingValue may be a scalar (e.g. user just
        -- coerced from == to in via cmp change; coerce wraps the scalar so
        -- it's already a table by this point) or nil (fresh in/notin).
        if type(self.workingValue) == "table" then
            local domainSet = {}
            for _, k in ipairs(domain) do domainSet[k] = true end
            local drifted = {}
            for _, v in ipairs(self.workingValue) do
                if not domainSet[v] then table.insert(drifted, tostring(v)) end
            end
            if #drifted > 0 then
                self.valueDrifted = true
                Log:warning("RLFilterConditionDialog:refreshValueWidget: list-mode drift; %d value(s) not in domain: %s",
                    #drifted, table.concat(drifted, ", "))
                self:showHint("rl_menu_filters_enumValueDrifted")
            end
        end
        if self.valueSetButton ~= nil then
            self.valueSetButton:setVisible(true)
            self:refreshValueSetSummary()
        end
        Log:trace("RLFilterConditionDialog:refreshValueWidget: list-mode field=%s cmp=%s domainSize=%d valueCount=%d drifted=%s",
            tostring(self.workingField), tostring(self.workingCmp),
            #domain,
            type(self.workingValue) == "table" and #self.workingValue or 0,
            tostring(self.valueDrifted == true))
        return
    end

    if field.type == "number" then
        if self.valueNumberInput ~= nil then
            self.valueNumberInput:setVisible(true)
            local text = self.workingRawText
            if text == nil then
                if self.workingValue == nil then text = "" else text = tostring(self.workingValue) end
            end
            self.valueNumberInput:setText(text)
        end
        Log:trace("RLFilterConditionDialog:refreshValueWidget: number, text='%s'",
            tostring(self.workingRawText or self.workingValue))
    elseif field.type == "bool" then
        if self.valueBoolPicker ~= nil then
            self.valueBoolPicker:setVisible(true)
            self.valueBoolPicker:setTexts({
                g_i18n:getText("ui_no"),
                g_i18n:getText("ui_yes"),
            })
            local boolState = (self.workingValue == true) and 2 or 1
            self.valueBoolPicker:setState(boolState, false)
        end
        Log:trace("RLFilterConditionDialog:refreshValueWidget: bool, value=%s",
            tostring(self.workingValue))
    elseif field.type == "enum" then
        -- Enum picker. Domain and display name resolve via RLFilterFieldDisplay; storage
        -- keeps the stable internal key only.
        local domain = self:_resolveActiveEnumDomain()
        self.valueEnumDomain = domain or {}
        if #self.valueEnumDomain == 0 then
            -- Empty domain: gender always non-empty in practice, so this is
            -- the subType-when-animalType-nil / scoped-with-zero-subtypes
            -- path. The settings frame's field-picker exclusion should
            -- prevent this from showing up at all, but guard just in case
            -- a legacy condition reaches here.
            Log:warning("RLFilterConditionDialog:refreshValueWidget: enum domain empty for field=%s animalType=%s",
                tostring(self.workingField), tostring(self.animalType))
            self:showHint("rl_menu_filters_subtypeRequiresAnimalType")
            return
        end
        if self.valueEnumPicker ~= nil then
            self.valueEnumPicker:setVisible(true)
            local labels = {}
            for i, key in ipairs(self.valueEnumDomain) do
                labels[i] = RLFilterFieldDisplay.getEnumValueDisplayName(
                    self.workingField, key, self.animalType)
            end
            self.valueEnumPicker:setTexts(labels)
            -- Seed selection: prefer workingValue's domain index; fall back
            -- to 1 (also covers the workingValue=nil case from the catalog's
            -- enum-divergence reseed where the dialog patches in domain[1]).
            local selectedIdx = 1
            local foundInDomain = false
            for i, key in ipairs(self.valueEnumDomain) do
                if key == self.workingValue then
                    selectedIdx = i
                    foundInDomain = true
                    break
                end
            end
            -- A workingValue outside the domain - a renamed subType, map-bridge drift - is
            -- never silently mutated: mark drifted and hint, and onClickOk refuses until the
            -- user picks. The picker still shows domain[1] so the row is not blank.
            if not foundInDomain then
                self.valueDrifted = true
                Log:warning("RLFilterConditionDialog:refreshValueWidget: enum workingValue=%s not in domain for field=%s; require explicit pick",
                    tostring(self.workingValue), tostring(self.workingField))
                self:showHint("rl_menu_filters_enumValueDrifted")
            end
            self.valueEnumPicker:setState(selectedIdx, false)
        end
        Log:trace("RLFilterConditionDialog:refreshValueWidget: enum field=%s domainSize=%d selected='%s'",
            tostring(self.workingField), #self.valueEnumDomain, tostring(self.workingValue))
    elseif field.type == "string" then
        if self.valueStringInput ~= nil then
            self.valueStringInput:setVisible(true)
            local text = self.workingValue
            if text == nil then text = "" end
            self.valueStringInput:setText(tostring(text))
        end
        Log:trace("RLFilterConditionDialog:refreshValueWidget: string, text='%s'",
            tostring(self.workingValue))
    else
        Log:warning("RLFilterConditionDialog:refreshValueWidget: unsupported type=%s (workingField=%s)",
            tostring(field.type), tostring(self.workingField))
    end
end

-- =============================================================================
-- Widget callbacks (MultiTextOption onClick / TextInput passes through)
-- =============================================================================

--- Field picker advanced. Coerce cmp + value via the shared catalog helper.
function RLFilterConditionDialog:onFieldChanged(state, _widget)
    local newField = self.fieldOptions[state]
    if newField == nil then
        Log:warning("RLFilterConditionDialog:onFieldChanged: state=%d out of range (%d options)",
            state, #self.fieldOptions)
        return
    end

    local oldCond = {
        field   = self.workingField,
        cmp     = self.workingCmp,
        value   = self.workingValue,
        rawText = self.workingRawText,
    }
    local editableCmps = editableCmpsFor(newField)
    local result = RLFilterFieldCatalog.coerceConditionOnFieldChange(
        oldCond, newField.key, editableCmps)

    -- Apply patch.
    self.workingField = result.patch.field
    if result.patch.cmp   ~= nil then self.workingCmp   = result.patch.cmp   end
    if result.patch.value ~= nil then self.workingValue = result.patch.value end

    -- Apply clearKeys: a nil-valued key vanishes inside a patch table, so clearing needs its
    -- own set. The catalog adds "value" when enum divergence cannot seed a default.
    if result.clearKeys ~= nil then
        for _, k in ipairs(result.clearKeys) do
            if     k == "rawText" then self.workingRawText = nil
            elseif k == "value"   then self.workingValue   = nil
            end
        end
    end

    -- When divergence cleared value AND the new type is enum, patch
    -- in domain[1] so the picker starts on a real value. For string, the
    -- catalog already returns "" via getDefaultValueForType. For number /
    -- bool, the catalog returns 0 / false directly.
    if self.workingValue == nil and newField.type == "enum" then
        self.workingValue = self:resolveDefaultEnumValue(newField.key)
        Log:trace("RLFilterConditionDialog:onFieldChanged: seeded enum default value=%s for field=%s",
            tostring(self.workingValue), tostring(newField.key))
    end

    -- Reset the hint, and the enum-drift flag with it: the coercion above already wrote a
    -- fresh defaulted value, so any prior drift state is stale.
    self.valueDrifted = false
    self:clearHint()

    Log:debug("RLFilterConditionDialog:onFieldChanged: field=%s cmp=%s value=%s rawText=%s",
        tostring(self.workingField), tostring(self.workingCmp),
        tostring(self.workingValue), tostring(self.workingRawText))

    self:refreshCmpPicker()
    self:refreshValueWidget()
end

function RLFilterConditionDialog:onCmpChanged(state, _widget)
    local cmp = self.cmpOptions[state]
    if cmp == nil then
        Log:warning("RLFilterConditionDialog:onCmpChanged: state=%d out of range (%d cmps)",
            state, #self.cmpOptions)
        return
    end
    if cmp == self.workingCmp then
        -- No-op: picker fires onClick even when state is unchanged (e.g. after
        -- onOpen seed). Skip the coerce pass to avoid logging churn.
        self:clearHint()
        return
    end

    -- Route cmp transitions through the catalog coerce helper so a scalar-to-list shape
    -- change wraps and unwraps the value consistently. A cross-shape transition hits the
    -- helper's illegal-transition branch and clears value and rawText.
    local field = RLFilterFieldCatalog.get(self.workingField)
    if field ~= nil then
        local oldCond = {
            field   = self.workingField,
            cmp     = self.workingCmp,
            value   = self.workingValue,
            rawText = self.workingRawText,
        }
        local result = RLFilterFieldCatalog.coerceConditionOnCmpChange(oldCond, cmp, field)
        if result.patch.value ~= nil then
            self.workingValue = result.patch.value
        end
        if result.clearKeys ~= nil then
            for _, k in ipairs(result.clearKeys) do
                if     k == "rawText" then self.workingRawText = nil
                elseif k == "value"   then self.workingValue   = nil
                end
            end
        end

        -- Drift-aware list-to-scalar collapse. The catalog is pure data and returns value[1]
        -- verbatim, so the skip-drifted rule is applied here, where the live domain is
        -- reachable: take the first element still in the domain, or clear and mark drifted.
        local oldIsList = (oldCond.cmp == "in" or oldCond.cmp == "notin")
        local newIsScalar = (cmp == "==" or cmp == "!=")
        if oldIsList and newIsScalar and field.type == "enum"
           and type(oldCond.value) == "table" and #oldCond.value > 0 then
            local domain = self:_resolveActiveEnumDomain() or {}
            local domainSet = {}
            for _, k in ipairs(domain) do domainSet[k] = true end
            local survivor = nil
            for _, v in ipairs(oldCond.value) do
                if domainSet[v] then survivor = v; break end
            end
            if survivor ~= nil then
                if self.workingValue ~= survivor then
                    Log:debug("RLFilterConditionDialog:onCmpChanged: drift-aware collapse picked '%s' over catalog's '%s'",
                        tostring(survivor), tostring(self.workingValue))
                end
                self.workingValue = survivor
            else
                Log:warning("RLFilterConditionDialog:onCmpChanged: all list values drifted (%d); clearing scalar value + setting valueDrifted",
                    #oldCond.value)
                self.workingValue = nil
                self.valueDrifted = true
            end
        end
    end

    self.workingCmp = cmp
    -- Reset the hint so a stale reject does not bleed across user input.
    self:clearHint()
    -- Refresh value widget AND cmp picker labels - the widget swaps when the
    -- cmp shape changes (scalar enum picker <-> list summary button). Also
    -- re-run drift check (refreshValueWidget owns that for both modes).
    self:refreshValueWidget()
    Log:debug("RLFilterConditionDialog:onCmpChanged: cmp=%s workingValueType=%s",
        tostring(self.workingCmp), type(self.workingValue))
end

-- =============================================================================
-- Value-set dialog handoff
-- =============================================================================

--- Open RLFilterValueSetDialog for the current field + value list. Passes
--- workingValue (a table for in/notin or nil for fresh) as the initial
--- selection; the value-set dialog tolerates drift on initial render and
--- strips drifted keys on commit (the explicit re-commit path that clears
--- valueDrifted).
function RLFilterConditionDialog:onClickOpenValueSet()
    Log:debug("RLFilterConditionDialog:onClickOpenValueSet: field=%s animalType=%s currentCount=%d",
        tostring(self.workingField), tostring(self.animalType),
        type(self.workingValue) == "table" and #self.workingValue or 0)
    local initialList = type(self.workingValue) == "table" and self.workingValue or nil
    RLFilterValueSetDialog.show(
        self.onValueSetCommitted, self,
        self.workingField, self.animalType, initialList)
end

--- Value-set dialog committed back. nil = cancel; non-nil = array of
--- internal keys (drifted keys already stripped by the value-set dialog).
--- Clears valueDrifted on a non-nil commit (the explicit re-commit
--- contract: only an explicit OK from the value-set dialog can clear the
--- drift flag, per spec Boundaries Always #4).
function RLFilterConditionDialog:onValueSetCommitted(list)
    if list == nil then
        Log:trace("RLFilterConditionDialog:onValueSetCommitted: cancel")
        return
    end
    self.workingValue = list
    -- Explicit re-commit through the value-set dialog clears the unified
    -- drift flag (only path that does so for list-mode; scalar mode clears
    -- via onValueEnumChanged at :535).
    self.valueDrifted = false
    self:clearHint()
    Log:debug("RLFilterConditionDialog:onValueSetCommitted: %d key(s)", #list)
    self:refreshValueSetSummary()
end

function RLFilterConditionDialog:onValueBoolChanged(state, _widget)
    -- State 1 = No (false), 2 = Yes (true). Matches the order set in refreshValueWidget.
    self.workingValue = (state == 2)
    self:clearHint()
    Log:debug("RLFilterConditionDialog:onValueBoolChanged: value=%s",
        tostring(self.workingValue))
end

--- Post-triage: any keystroke in the value TextInput (number or
--- string variant) clears the reject hint so it tracks current input.
--- Both XML elements wire `onTextChanged="onTextChanged"`.
function RLFilterConditionDialog:onTextChanged(_element, _text)
    self:clearHint()
end

--- Enum picker advanced. Maps the picker state index to the stable
--- internal key from the cached domain. Never stores the translated label;
--- domain[state] is always a stable key (e.g. "male", "<subtype-name>").
function RLFilterConditionDialog:onValueEnumChanged(state, _widget)
    local domain = self.valueEnumDomain or {}
    local key = domain[state]
    if key == nil then
        Log:warning("RLFilterConditionDialog:onValueEnumChanged: state=%d out of range (%d values in domain)",
            state, #domain)
        return
    end
    self.workingValue = key
    -- User picked a real domain key, so the drift flag clears. Any user
    -- widget interaction also clears the stale reject hint.
    self.valueDrifted = false
    self:clearHint()
    Log:debug("RLFilterConditionDialog:onValueEnumChanged: value=%s (state=%d)",
        tostring(self.workingValue), state)
end

-- =============================================================================
-- OK / Cancel
-- =============================================================================

--- Validate working state, build coerced newCondition, deliver to caller, close.
---
--- Note: an earlier draft intercepted Enter-on-valueSetButton
--- here via a focused-element check, but that guard could also hijack a
--- real mouse click on OK when focus had not yet moved off the button. The
--- guard has been removed; Enter on the multi-value picker button relies
--- on FocusManager's default activation. If that doesn't activate the
--- button in-game, the case is tracked as a follow-up enhancement.
function RLFilterConditionDialog:onClickOk()
    local field = RLFilterFieldCatalog.get(self.workingField)
    if field == nil then
        Log:warning("RLFilterConditionDialog:onClickOk: workingField=%s not in catalog; closing as cancel",
            tostring(self.workingField))
        self:close()
        if self.callback ~= nil and self.callbackTarget ~= nil then
            self.callback(self.callbackTarget, nil, self.rowIndex)
        end
        return
    end

    local newCondition = {
        field = self.workingField,
        cmp   = self.workingCmp,
    }

    if field.type == "number" then
        -- Pull live text from TextInput (handles in-flight keystrokes the
        -- workingRawText cache may not have seen yet if the user typed and
        -- clicked OK before any onChange fired).
        local text = self.valueNumberInput ~= nil
                     and self.valueNumberInput.getText ~= nil
                     and self.valueNumberInput:getText()
                     or self.workingRawText
                     or tostring(self.workingValue or "")
        local num = tonumber(text)
        if num == nil then
            Log:warning("RLFilterConditionDialog:onClickOk: rejecting non-numeric value '%s' for field=%s",
                tostring(text), tostring(self.workingField))
            -- Stay open so user can correct; surface translated hint and
            -- keep workingRawText in sync.
            self.workingRawText = text
            self:showHint("rl_menu_filters_invalidNumber")
            return
        end
        -- NaN+Inf reject: NaN != NaN, Inf == math.huge.
        if num ~= num or num == math.huge or num == -math.huge then
            Log:warning("RLFilterConditionDialog:onClickOk: rejecting NaN/Inf value '%s' for field=%s",
                tostring(text), tostring(self.workingField))
            self.workingRawText = text
            self:showHint("rl_menu_filters_invalidNumber")
            return
        end
        -- Range reject: absurd-but-finite numbers (e.g. age >= 1e+30) refuse to
        -- commit instead of silently producing a no-op filter. Mirrors the
        -- NaN/Inf block above (WARN + preserve workingRawText + translated hint
        -- + return). Bounds live in the catalog (RLFilterFieldCatalog field
        -- entries); evaluator does not consult them.
        local ok, bounds = RLFilterFieldCatalog.isValueInRange(field, num)
        if not ok then
            local minB, maxB = bounds and bounds.min or nil, bounds and bounds.max or nil
            -- Bounds rendering matches AC: table-style with the nil side dropped
            -- for one-sided bounds (so weight rejects log `bounds={min=0}` not
            -- `bounds={min=0,max=nil}`).
            local boundsStr
            if minB ~= nil and maxB ~= nil then
                boundsStr = string.format("{min=%s,max=%s}", tostring(minB), tostring(maxB))
            elseif minB ~= nil then
                boundsStr = string.format("{min=%s}", tostring(minB))
            else
                boundsStr = string.format("{max=%s}", tostring(maxB))
            end
            Log:warning("RLFilterConditionDialog:onClickOk: rejecting out-of-range value '%s' for field=%s (bounds=%s)",
                tostring(text), tostring(self.workingField), boundsStr)
            self.workingRawText = text
            if minB ~= nil and maxB ~= nil then
                self:showHint("rl_menu_filters_valueOutOfRange_both", minB, maxB)
            elseif minB ~= nil then
                self:showHint("rl_menu_filters_valueOutOfRange_min", minB)
            else
                -- maxB ~= nil; one of (min, max) is guaranteed non-nil when ok=false.
                self:showHint("rl_menu_filters_valueOutOfRange_max", maxB)
            end
            return
        end
        newCondition.value = num
        -- rawText carried through so the populate trace sees what the user typed.
        if text ~= tostring(num) then
            newCondition.rawText = text
        end
    elseif field.type == "bool" then
        newCondition.value = (self.workingValue == true)
    elseif field.type == "enum" then
        -- Refuse close when the domain is empty - the field-picker exclusion
        -- should already prevent this case from reaching OK, but guard
        -- against legacy rows.
        local domain = self.valueEnumDomain or {}
        if #domain == 0 then
            Log:warning("RLFilterConditionDialog:onClickOk: enum domain empty for field=%s; refusing commit",
                tostring(self.workingField))
            self:showHint("rl_menu_filters_subtypeRequiresAnimalType")
            return
        end
        -- Drift refuse-commit (unified valueDrifted covers scalar + list).
        -- Scalar mode clears via onValueEnumChanged (user picks via picker);
        -- list mode clears via onValueSetCommitted (user re-commits via the
        -- value-set dialog, which strips drifted keys). Silently snapping
        -- would rewrite stored keys to a different value.
        if self.valueDrifted then
            Log:warning("RLFilterConditionDialog:onClickOk: refusing commit, value drifted (workingValue=%s, field=%s, cmp=%s); pick a replacement",
                tostring(self.workingValue), tostring(self.workingField), tostring(self.workingCmp))
            self:showHint("rl_menu_filters_enumValueDrifted")
            return
        end

        -- List-shape commit for in/notin. workingValue is a table
        -- of stable internal keys (committed via onValueSetCommitted, or
        -- coerceConditionOnCmpChange wrapped a scalar on cmp swap). Empty
        -- list reject mirrors the value-set dialog's own empty-set reject.
        if self.workingCmp == "in" or self.workingCmp == "notin" then
            if type(self.workingValue) ~= "table" or #self.workingValue == 0 then
                Log:warning("RLFilterConditionDialog:onClickOk: refusing empty list commit (field=%s cmp=%s)",
                    tostring(self.workingField), tostring(self.workingCmp))
                self:showHint("rl_menu_filters_emptyValueRejected")
                return
            end
            -- Defensive validation: every element must be in domain. The
            -- value-set dialog strips drifted keys on its OK commit, so
            -- post-onValueSetCommitted this should always hold; if not
            -- it's a real bug, not user data.
            local domainSet = {}
            for _, k in ipairs(domain) do domainSet[k] = true end
            for _, v in ipairs(self.workingValue) do
                if not domainSet[v] then
                    Log:warning("RLFilterConditionDialog:onClickOk: list element %s not in domain post-drift-check; refusing commit",
                        tostring(v))
                    self:showHint("rl_menu_filters_enumValueDrifted")
                    return
                end
            end
            newCondition.value = self.workingValue
            Log:debug("RLFilterConditionDialog:onClickOk: list commit field=%s cmp=%s n=%d",
                tostring(self.workingField), tostring(self.workingCmp), #self.workingValue)
        else
            -- Scalar enum commit (==/!=). Defensive: workingValue must be a
            -- domain key (initial seed from initialCondition or
            -- resolveDefaultEnumValue; onValueEnumChanged only writes
            -- domain[state]; drift caught above).
            local valid = false
            for _, key in ipairs(domain) do
                if key == self.workingValue then valid = true; break end
            end
            if not valid then
                Log:warning("RLFilterConditionDialog:onClickOk: enum workingValue=%s not in domain post-drift-check; refusing commit",
                    tostring(self.workingValue))
                self:showHint("rl_menu_filters_enumValueDrifted")
                return
            end
            newCondition.value = self.workingValue
        end
    elseif field.type == "string" then
        -- Pull live text from TextInput (handles in-flight keystrokes; matches
        -- the number branch's same pattern). Store verbatim - no trim, no
        -- quote-strip, no case-fold (case-fold lives in the evaluator at
        -- match time per RLFilterEvaluator.lua substring path).
        local text = self.valueStringInput ~= nil
                     and self.valueStringInput.getText ~= nil
                     and self.valueStringInput:getText()
                     or self.workingValue
                     or ""
        if text == "" then
            -- Empty needle reject mirrors RLFilterEvaluator's guard - committing
            -- an empty contains/notcontains needle silently produces a no-op
            -- filter. Refuse close, surface hint, WARN. Keeps working state
            -- so the user can correct without re-opening.
            Log:warning("RLFilterConditionDialog:onClickOk: rejecting empty string for field=%s cmp=%s",
                tostring(self.workingField), tostring(self.workingCmp))
            self.workingValue = ""
            self:showHint("rl_menu_filters_emptyValueRejected")
            return
        end
        newCondition.value = text
        -- Keep workingValue in sync with what we committed (so a re-edit
        -- without close-and-reopen starts from the same state).
        self.workingValue = text
    else
        Log:warning("RLFilterConditionDialog:onClickOk: unsupported field.type=%s for workingField=%s; closing as cancel",
            tostring(field.type), tostring(self.workingField))
        self:close()
        if self.callback ~= nil and self.callbackTarget ~= nil then
            self.callback(self.callbackTarget, nil, self.rowIndex)
        end
        return
    end

    Log:debug("RLFilterConditionDialog:onClickOk: committing rowIndex=%s field=%s cmp=%s value=%s",
        tostring(self.rowIndex), tostring(newCondition.field),
        tostring(newCondition.cmp), tostring(newCondition.value))

    self:close()
    if self.callback ~= nil and self.callbackTarget ~= nil then
        self.callback(self.callbackTarget, newCondition, self.rowIndex)
    end
end

function RLFilterConditionDialog:onClickBack()
    Log:debug("RLFilterConditionDialog:onClickBack: cancel (rowIndex=%s)",
        tostring(self.rowIndex))
    self:close()
    if self.callback ~= nil and self.callbackTarget ~= nil then
        self.callback(self.callbackTarget, nil, self.rowIndex)
    end
end

--- Dialog-level input event override.
---
--- Without this override, Enter on a focused Value TextInput or
--- `valueSetButton` commits the dialog (via the OK button) instead of
--- activating the focused widget. This intercept routes MENU_ACCEPT to
--- `onFocusActivate` for the three value widgets so the keyboard path
--- matches the mouse path.
---
--- Gates (all required, in order):
---   1. `not eventUsed`                                  upstream layer hasn't claimed it
---   2. `action == InputAction.MENU_ACCEPT`              only Enter, never affects other actions
---   3. focused element is `valueNumberInput` /          only the three value widgets that need it;
---      `valueStringInput` / `valueSetButton`            every other focused widget falls through
---   4a. TextInput case: `not focused.forcePressed`      skip when IME is already active so the
---                                                       existing IME-Enter (commit) path is not
---                                                       interrupted by a forcePressed toggle
---   4b. Button case: `focused:getIsActive() and guarantee activation will fire a
---                    focused.onClickCallback ~= nil`    callback (no dead-key activation)
---
--- On match: DEBUG log + `focused:onFocusActivate()` + return true.
--- On any miss: fall through via super so the dialog's default Enter
--- handling (OK button commit) is preserved for every Field / Compare /
--- bool / enum picker and for the dialog-open "Enter to accept" shortcut.
---
--- Standard Lua class-method override; not new input-action registration.
---
---@param action number InputAction enum value
---@param value any axis / digital value passed by the dispatcher
---@param eventUsed boolean true when an upstream layer already consumed
---@return boolean true to consume MENU_ACCEPT here, otherwise the super result
function RLFilterConditionDialog:inputEvent(action, value, eventUsed)
    local focused = FocusManager ~= nil
                    and FocusManager.getFocusedElement ~= nil
                    and FocusManager:getFocusedElement()
                    or nil
    Log:trace("RLFilterConditionDialog:inputEvent: entry action=%s eventUsed=%s focusedId=%s",
        tostring(action),
        tostring(eventUsed),
        focused ~= nil and tostring(focused.id) or "nil")

    if not eventUsed and action == InputAction.MENU_ACCEPT then
        local intercept = false
        if focused == self.valueNumberInput or focused == self.valueStringInput then
            -- TextInput: only intercept when (a) the widget is visible /
            -- enabled (getIsActive guards stale identity if focus survives
            -- a refreshValueWidget swap) and (b) IME is inactive. When
            -- the IME is already active, Enter is delivered through the
            -- TextInput's own callback path (our onEnterPressed handler).
            intercept = focused ~= nil
                        and focused.getIsActive ~= nil
                        and focused:getIsActive()
                        and not focused.forcePressed
        elseif focused == self.valueSetButton then
            -- Button: only intercept when activation will actually fire a
            -- callback. Guard against transient inactive states (e.g.
            -- visibility toggled mid-frame, callback dropped during reload).
            intercept = focused ~= nil
                        and focused.getIsActive ~= nil
                        and focused:getIsActive()
                        and focused.onClickCallback ~= nil
        end

        if intercept then
            Log:debug("RLFilterConditionDialog:inputEvent: routing MENU_ACCEPT to onFocusActivate on id=%s",
                tostring(focused.id))
            focused:onFocusActivate()
            return true
        end
    end

    return RLFilterConditionDialog:superClass().inputEvent(self, action, value, eventUsed)
end

--- Enter raised by a TextInputElement callback. `dismiss=true` is the
--- IME-closing gesture (suppresses commit so the user can review the
--- typed value); `dismiss=false`/`nil` is the IME-complete commit path.
--- Mirrors NameInputDialog:onEnterPressed.
---@param _ any unused (the TextInputElement raising the callback)
---@param dismiss boolean|nil true on IME-close gesture, false/nil on commit
---@return boolean true to consume the event, false to fall through
function RLFilterConditionDialog:onEnterPressed(_, dismiss)
    Log:trace("RLFilterConditionDialog:onEnterPressed: dismiss=%s", tostring(dismiss))
    return dismiss and true or self:onClickOk()
end

--- Esc pressed while the TextInput is focused. Routes to onClickBack
--- per the NameInputDialog:onEscPressed pattern.
function RLFilterConditionDialog:onEscPressed(_)
    Log:trace("RLFilterConditionDialog:onEscPressed")
    return self:onClickBack()
end
