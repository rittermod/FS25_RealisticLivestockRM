--[[
    RLDiseaseDefinition.lua
    The one home for parsing xml/diseases.xml. `parse` walks the file once and returns
    the disease REGISTRY - a map keyed by title - plus an array of authoring warnings;
    `DiseaseManager:loadDiseases` is the thin wrapper that renders them. Being a MAP,
    emptiness is `next(registry) == nil` and a count is a walk - `#` silently reads 0.

    ONE FORMAT, ALL OR NOTHING: an absent or refused `<model>` drops the whole disease. A
    `genetic` archetype REQUIRES a `<model><genetic>` block and every other one FORBIDS it.
    WARNINGS ARE RETURNED, NEVER LOGGED HERE, as structured `{ title, rule, detail }`
    values in document order, because a logger spy is banned portfolio-wide and that is
    what makes every authoring rule a value assertion.
    THE ONE MODULE-LOAD GLOBAL READ IS `RLDiseaseRecord.ENDPOINT`, so that file MUST be
    sourced first, in `main.lua` and in the headless env alike; the headless tier cannot
    see that mistake, because its env sources the record whatever the loader says.
]]

RLDiseaseDefinition = {}

local Log = RmLogging.getLogger("RLRM")


--- Archetype is an OPEN vocabulary: an unknown value warns and is carried through
--- verbatim rather than rejected, so a future kind needs no schema churn, and the
--- warning is what stops a typo becoming a silent third archetype. `management` covers
--- the non-transmissible, non-inherited conditions - wear, diet, parasites.
local ARCHETYPES = {
    ["infectious"] = true,
    ["genetic"] = true,
    ["management"] = true
}


--- The endpoint NAMES, read from their one home on `RLDiseaseRecord` rather than
--- re-declared here. That module depends on nothing but RmLogging, so it can own a
--- vocabulary this XML-reading one reads; the reverse would give the pure,
--- dual-running module a dependency on the parser. See the header for the load-order
--- requirement this file-scope read imposes.
---
--- Named `RECORD_ENDPOINT` rather than `ENDPOINT` deliberately: `ENDPOINTS` below is
--- a DIFFERENT table with an almost identical name, and both index legally for any
--- key, so a typo between the two would return a silent nil rather than raise.
local RECORD_ENDPOINT = RLDiseaseRecord.ENDPOINT


--- Which duration attribute each endpoint's INFECTIOUS phase is clocked by - `false`
--- where nothing clocks it. Keyed off `RECORD_ENDPOINT` so the NAMES live in one
--- place while the endpoint-to-duration MAPPING, a parsing concern, lives here.
---
--- CLOSED, unlike `ARCHETYPES`, and membership is tested with `~= nil` rather than
--- for truthiness - `false` is a legal entry and the clockless pair would otherwise
--- read as unknown. The two durations are NOT interchangeable and must never be
--- merged: `durationMonths` is a fractional MINIMUM before a recovery draw at a per-month chance,
--- `chronicMonthsToDeath` a MEDIAN its consumer converts into a hazard, so merging them
--- reads one as the other, with plausible numbers on either side.
local ENDPOINTS = {
    -- the minimum elapses, then a per-month chance ends it naturally
    [RECORD_ENDPOINT.recovers] = "durationMonths",
    -- the hazard kills on its own clock; only a completed, successful curative
    -- course ends it any other way (see `RLDiseaseRecord.RECOVERY_EXITS`)
    [RECORD_ENDPOINT.terminal] = "chronicMonthsToDeath",
    -- nothing ends it; the animal sheds for life
    [RECORD_ENDPOINT.lifelong] = false,
    -- only a completed curative course ends it
    [RECORD_ENDPOINT.cureOnly] = false
}


--- The duration attributes the pairing rule walks: exactly one is required per endpoint
--- and every other one is FORBIDDEN, so the walk needs the whole set.
---
--- DERIVED from `ENDPOINTS`, never hand-written beside it: an endpoint mapped to an
--- attribute missing from the walk matches no iteration, so the model would load with no
--- duration AND no warning. Sorted, so the first detail string an author sees is stable.
local DURATION_ATTRIBUTES = {}

do
    local seen = {}

    for _, attribute in pairs(ENDPOINTS) do
        -- `false` is a legal value: the clockless endpoints require no attribute.
        if attribute ~= false and not seen[attribute] then
            seen[attribute] = true
            table.insert(DURATION_ATTRIBUTES, attribute)
        end
    end

    table.sort(DURATION_ATTRIBUTES)
end


--- What a completed treatment achieves. CLOSED for the same reason `ENDPOINTS` is:
--- the value decides which endpoints the block is legal against.
---
--- `cure` clears the record; `relief` eases the symptoms and leaves it in place,
--- which is the axis an incurable-but-manageable condition needs and the only
--- reason this attribute exists.
local OUTCOMES = {
    ["cure"] = true,
    ["relief"] = true
}

--- Prerequisite value types, as an ALLOWLIST rather than a `type(fn) == "function"`
--- probe: the reader below indexes `XMLFile["get" .. valueType]`, so a typo is a
--- nil call, and a probe would admit any XMLFile method whose name happens to start
--- with "get".
local PREREQUISITE_VALUE_TYPES = {
    ["Bool"] = true,
    ["Int"] = true,
    ["Float"] = true,
    ["String"] = true
}

--- The `<model>` scalars that are ALWAYS required. There are no defaults: a silent
--- default in a contract the later slices read is worse than a warning, and the
--- design archive names the endpoint specifically as a field that must be declared
--- rather than inferred from absence - an absent attribute is indistinguishable
--- from a typo. The duration pair and the recovery chance are required separately,
--- selected by `endpoint`.
local MODEL_REQUIRED_SCALARS = {
    "archetype", "endpoint", "cullRequired", "incubationTicks",
    "r0", "caseFatality", "immunityMonths", "salePrice"
}


--- Append one structured authoring warning.
---@param warnings table the accumulator, in document order
---@param title string|nil the disease's title, or nil where the row has none
---@param rule string stable rule id the suite field-compares
---@param detail string human-readable specifics for the rendered line
local function warn(warnings, title, rule, detail)
    table.insert(warnings, { ["title"] = title, ["rule"] = rule, ["detail"] = detail })
end


-- Read at CALL time, never captured at file scope: this file is sourced before the resolver,
-- so a load-time read of its list would index nil.
--- Whether `channel` is one of the output channels `RLDiseaseEffects.OUTPUT_CHANNELS` names.
---@param channel string the `#type` read off an `<output>` row
---@return boolean true when the resolver's list carries the name
local function isOutputChannel(channel)
    for _, name in ipairs(RLDiseaseEffects.OUTPUT_CHANNELS) do
        if name == channel then return true end
    end

    return false
end


--- Read one non-negative scalar.
---
--- Negativity is ONE rule rather than a per-field matrix - no scalar in this schema
--- has a meaningful negative value. The reader is selected with an explicit branch
--- rather than `asInt and getInt or getFloat`, which falls through to the float reader
--- whenever the int reader returns nil.
---@param xmlFile table open XMLFile document
---@param path string full attribute path
---@param label string field name for the warning
---@param title string|nil the owning disease
---@param warnings table the accumulator
---@param asInt boolean|nil read with getInt rather than getFloat
---@return number|nil the value, or nil when absent or refused
local function readNonNegative(xmlFile, path, label, title, warnings, asInt)

    local value

    if asInt then
        value = xmlFile:getInt(path)
    else
        value = xmlFile:getFloat(path)
    end

    if value == nil then return nil end

    if value < 0 then
        warn(warnings, title, "negative-value",
            string.format("%s is %s, which is negative; field skipped", label, tostring(value)))
        return nil
    end

    return value

end


--- Read one probability-domain scalar, refusing anything outside [0, 1].
---@param xmlFile table open XMLFile document
---@param path string full attribute path
---@param label string field name for the warning
---@param title string|nil the owning disease
---@param warnings table the accumulator
---@return number|nil the value, or nil when absent or refused
local function readProbability(xmlFile, path, label, title, warnings)

    local value = xmlFile:getFloat(path)

    if value == nil then return nil end

    if value < 0 or value > 1 then
        warn(warnings, title, "probability-out-of-range",
            string.format("%s is %s, outside [0, 1]; field skipped", label, tostring(value)))
        return nil
    end

    return value

end


--- Read an `<output>` list against `RLDiseaseEffects.OUTPUT_CHANNELS`; refuse unlisted, incomplete, negative rows.
---
--- The carrier profile and the base effects profile are read by THIS function
--- against different base keys, which is what makes the class of bug it repairs -
--- a carrier block silently reading the wrong subtree - hard to reintroduce.
---
--- A modifier MAY exceed 1 (PED gives four times the slurry), so this is "what the
--- disease does to output" rather than a penalty channel. It may not be negative:
--- there is no such thing as negative production.
---@param xmlFile table open XMLFile document
---@param baseKey string key whose `.output` children are read
---@param title string the owning disease, for warning attribution
---@param warnings table the accumulator
---@return table map of channel name to modifier; may be empty
local function readModelOutputs(xmlFile, baseKey, title, warnings)

    local output = {}

    xmlFile:iterate(baseKey .. ".output", function(_, outputKey)

        local channel = xmlFile:getString(outputKey .. "#type")

        if channel == nil then
            warn(warnings, title, "output-missing-type",
                string.format("an <output> row under %s has no #type; row skipped",
                    tostring(baseKey)))
            return
        end

        if not isOutputChannel(channel) then
            warn(warnings, title, "output-unknown-channel",
                string.format("output channel %s is not one of %s; row skipped",
                    tostring(channel), table.concat(RLDiseaseEffects.OUTPUT_CHANNELS, "/")))
            return
        end

        local modifier = readNonNegative(xmlFile, outputKey .. "#modifier",
            string.format("output %s modifier", tostring(channel)), title, warnings)

        if modifier == nil then
            warn(warnings, title, "output-missing-modifier",
                string.format("output channel %s has no usable #modifier; row skipped",
                    tostring(channel)))
            return
        end

        output[channel] = modifier

        Log:trace("RLDiseaseDefinition.readModelOutputs: title=%s channel=%s modifier=%s",
            tostring(title), tostring(channel), tostring(modifier))

    end)

    return output

end


--- Read a `<prerequisites>` list, refusing an incomplete or badly-typed entry.
---
--- The `valueType` check is an allowlist rather than a callable probe, because the
--- read below indexes `XMLFile["get" .. valueType]` and a typo is otherwise a nil
--- call - a raise.
---@param xmlFile table open XMLFile document
---@param baseKey string key whose `.prerequisite` children are read
---@param title string the owning disease, for warning attribution
---@param rulePrefix string warning-rule prefix. One caller today
--- (`model-prerequisite-`); kept as a parameter so the rule ids stay declared at
--- the call site rather than baked into this reader.
---@param warnings table the accumulator
---@return table array of `{ path, value }`
local function readPrerequisites(xmlFile, baseKey, title, rulePrefix, warnings)

    local prerequisites = {}

    xmlFile:iterate(baseKey .. ".prerequisite", function(_, prerequisiteKey)

        local valueType = xmlFile:getString(prerequisiteKey .. "#valueType", "Int")
        local path = xmlFile:getString(prerequisiteKey .. "#path")

        if path == nil then
            warn(warnings, title, rulePrefix .. "missing-path",
                "a <prerequisite> has no #path; prerequisite skipped")
            return
        end

        if not PREREQUISITE_VALUE_TYPES[valueType] then
            warn(warnings, title, rulePrefix .. "bad-value-type",
                string.format("prerequisite %s declares #valueType %s, which is not "
                    .. "Bool/Int/Float/String; prerequisite skipped",
                    tostring(path), tostring(valueType)))
            return
        end

        local value = XMLFile["get" .. valueType](xmlFile, prerequisiteKey .. "#value")

        -- A nil value silently makes the disease permanently ineligible today,
        -- because the eligibility loop compares the animal's field against it.
        if value == nil then
            warn(warnings, title, rulePrefix .. "missing-value",
                string.format("prerequisite %s has no #value; prerequisite skipped",
                    tostring(path)))
            return
        end

        table.insert(prerequisites, {
            ["path"] = string.split(path, "."),
            ["value"] = value
        })

    end)

    return prerequisites

end


--- Read the `<model><treatment>` child onto `model`, or refuse it.
---
--- All four fields are required together, because there are no silent defaults here
--- and a consumer doing arithmetic on a nil cost raises far from this function.
---
--- ONE ARM OF THE COMPATIBILITY TABLE IS DELIBERATELY SILENT, and it is the single
--- trap here: a `cureOnly` model whose block declares `relief` returns WITHOUT a
--- warning, because `buildModelEntry`'s endpoint gate emits the one that case earns.
---@param xmlFile table open XMLFile document
---@param modelKey string the `<model>` element key
---@param model table the model entry being built, carrying a validated `endpoint`
---@param title string the owning disease
---@param warnings table the accumulator
local function readModelTreatment(xmlFile, modelKey, model, title, warnings)

    if not xmlFile:hasProperty(modelKey .. ".treatment") then return end

    local outcome = xmlFile:getString(modelKey .. ".treatment#outcome")

    -- Checked BEFORE the allowlist so "you forgot it" and "you mistyped it" stay
    -- distinguishable; they need different corrections, and one rule covering both
    -- sends an author looking for an attribute that is not in the file.
    if outcome == nil then
        warn(warnings, title, "treatment-missing-outcome",
            "<treatment> declares no #outcome; it must be cure or relief; treatment skipped")
        return
    end

    if not OUTCOMES[outcome] then
        warn(warnings, title, "treatment-unknown-outcome",
            string.format("treatment #outcome %s is not one of cure/relief; treatment skipped",
                tostring(outcome)))
        return
    end

    -- FIELD-local: the treatment is dropped and the model survives as an
    -- untreatable `lifelong`. Clearing a lifelong infection is a contradiction in
    -- the endpoint's own terms, where relieving one is exactly the case the
    -- outcome axis exists for.
    if model.endpoint == RECORD_ENDPOINT.lifelong and outcome == "cure" then
        warn(warnings, title, "treatment-outcome-contradicts-endpoint",
            "a lifelong disease cannot be cured; declare outcome=relief or change the "
                .. "endpoint; treatment skipped")
        return
    end

    -- The silent arm. See the header: `buildModelEntry` refuses the whole disease
    -- for a `cureOnly` that ends up with no treatment, and this is one of the
    -- three shapes that reaches it.
    if model.endpoint == RECORD_ENDPOINT.cureOnly and outcome == "relief" then
        return
    end

    -- Read as a FLOAT so the whole-number check below can actually fire: the
    -- engine's native int read truncates a fractional lexical first, so on an
    -- int-read value this guard is dead in-game and live headless.
    local months = xmlFile:getFloat(modelKey .. ".treatment#months")
    local cost = readNonNegative(xmlFile, modelKey .. ".treatment#cost",
        "treatment cost", title, warnings)
    local efficacy = readProbability(xmlFile, modelKey .. ".treatment#efficacy",
        "treatment efficacy", title, warnings)

    -- A whole number of months, minimum 1: a fractional course cannot be
    -- represented at one day per month, where a tick IS a month.
    if months == nil or months < 1 or months ~= math.floor(months) then
        warn(warnings, title, "treatment-months-invalid",
            string.format("treatment #months is %s; must be a whole number of months, "
                .. "minimum 1; treatment skipped", tostring(months)))
        return
    end

    if cost == nil or efficacy == nil then
        warn(warnings, title, "treatment-incomplete",
            string.format("treatment declares months but not a usable #cost and "
                .. "#efficacy (cost=%s efficacy=%s); treatment skipped",
                tostring(cost), tostring(efficacy)))
        return
    end

    model.treatment = {
        ["months"] = months,
        ["cost"] = cost,
        ["efficacy"] = efficacy,
        ["outcome"] = outcome
    }

end


-- REQUIRED on a `genetic` archetype and FORBIDDEN on every other one. The forbidden half is tested
-- by PRESENCE, so a declared block is refused even where its own reads below would fail.
--- Read the `<model><genetic>` block onto `model`, or refuse the disease.
---@param xmlFile table open XMLFile document
---@param modelKey string the `<model>` element key
---@param model table the model entry being built, carrying its `archetype`
---@param title string the owning disease
---@param warnings table the accumulator
---@return boolean ok false when the disease must be dropped
local function readModelGenetic(xmlFile, modelKey, model, title, warnings)

    local geneticKey = modelKey .. ".genetic"
    local declared = xmlFile:hasProperty(geneticKey)

    if model.archetype ~= "genetic" then

        if declared then
            warn(warnings, title, "genetic-block-forbidden",
                string.format("archetype %s forbids a <model><genetic> block, which is declared; "
                    .. "disease dropped", tostring(model.archetype)))
            return false
        end

        return true

    end

    if not declared then
        warn(warnings, title, "genetic-missing-block",
            "archetype genetic requires a <model><genetic> block, which is missing; disease dropped")
        return false
    end

    local saleChance = readProbability(xmlFile, geneticKey .. "#saleChance", "genetic saleChance",
        title, warnings)

    -- "missing OR REFUSED": an out-of-range value reaches here as nil too, and has said why already.
    if saleChance == nil then
        warn(warnings, title, "genetic-missing-sale-chance",
            "<genetic> is missing or refused required attribute #saleChance; disease dropped")
        return false
    end

    local recessive = xmlFile:getBool(geneticKey .. "#recessive", false)
    local dominant = xmlFile:getBool(geneticKey .. "#dominant", false)

    if recessive == dominant then
        warn(warnings, title, "genetic-mode-invalid",
            string.format("<genetic> must set exactly one of #recessive and #dominant true "
                .. "(recessive=%s dominant=%s); disease dropped", tostring(recessive), tostring(dominant)))
        return false
    end

    model.genetic = {
        ["recessive"] = recessive,
        ["dominant"] = dominant,
        ["saleChance"] = saleChance
    }

    return true

end


-- REQUIRED on `recovers`, FORBIDDEN (by PRESENCE) elsewhere; read with `getFloat` so a defect warns once.
--- Read `#recoveryChancePerMonth` onto `model`, or refuse the disease.
---@param xmlFile table open XMLFile document
---@param modelKey string the `<model>` element key
---@param model table the model entry being built, carrying a validated `endpoint`
---@param title string the owning disease
---@param warnings table the accumulator
---@return boolean ok false when the disease must be dropped
local function readModelRecoveryChance(xmlFile, modelKey, model, title, warnings)

    local path = modelKey .. "#recoveryChancePerMonth"

    if model.endpoint ~= RECORD_ENDPOINT.recovers then

        if xmlFile:hasProperty(path) then
            warn(warnings, title, "model-recovery-chance-forbidden",
                string.format("endpoint %s forbids #recoveryChancePerMonth, which is declared; "
                    .. "disease dropped", tostring(model.endpoint)))
            return false
        end

        return true

    end

    local chance = xmlFile:getFloat(path)

    if chance == nil then
        warn(warnings, title, "model-recovery-chance-missing",
            "endpoint recovers requires #recoveryChancePerMonth, which is missing or unreadable; "
                .. "disease dropped")
        return false
    end

    -- Inverted so a NaN refuses too: a chance outside (0, 1] would silently make the illness lifelong.
    if not (chance > 0) or chance > 1 then
        warn(warnings, title, "model-recovery-chance-out-of-range",
            string.format("endpoint recovers: #recoveryChancePerMonth is %s, outside (0, 1]; disease dropped",
                tostring(chance)))
        return false
    end

    model.recoveryChancePerMonth = chance

    return true

end


--- Build the registry entry for one disease, or nil where the disease is dropped.
---
--- EVERY nil return here drops the whole disease. The animal rules run FIRST, so a
--- row with neither a usable `#animals` nor a `<model>` reports the animal defect
--- rather than the missing model - a disease bound to no type is unreachable
--- whatever its model would have said.
---
--- The entry carries its own identity (`title`, `key`, `name`) so that nothing
--- downstream needs a second table to render or persist a record.
---@param xmlFile table open XMLFile document
---@param key string this disease's element key
---@param title string resolved, non-empty title
---@param deps table `{ animalTypes = <name-to-index map>, i18n = <text resolver> }`
---@param warnings table the accumulator
---@return table|nil the registry entry, or nil when the disease must be dropped
local function buildModelEntry(xmlFile, key, title, deps, warnings)

    local translationKey = "rl_disease_" .. title
    local animalNames = xmlFile:getString(key .. "#animals")

    -- Row-fatal: without this attribute `string.split(nil, " ")` raises, which
    -- aborts DiseaseManager.new() and leaves g_diseaseManager nil for the session.
    if animalNames == nil then
        warn(warnings, title, "missing-animals", "no #animals attribute; disease dropped")
        return nil
    end

    -- `ipairs`, not `pairs`, and that is load-bearing rather than tidy: the array
    -- built below is stored as `model.animals`, whose contract is DOCUMENT ORDER,
    -- while `pairs` traversal order is undefined. Both runners' splits return a
    -- contiguous sequence, so the two walk the same tokens.
    local animals = {}

    for _, animalName in ipairs(string.split(animalNames, " ")) do

        -- An empty token is skipped rather than resolved. The engine's split
        -- yields one for a leading, trailing or doubled space while the headless
        -- one drops it, so without this the two runners emit different warning
        -- sets for the same file.
        if animalName ~= "" then

            -- Resolved for its SIDE EFFECT of validating the name: the entry
            -- stores NAMES, because its consumers are pure modules that may not
            -- reach the animal-type registry. Warns once per unresolvable
            -- OCCURRENCE, so `animals="FOO FOO"` warns twice.
            if deps.animalTypes[animalName] == nil then
                warn(warnings, title, "unknown-animal-type",
                    string.format("animal type %s does not resolve; name skipped",
                        tostring(animalName)))
            else
                table.insert(animals, animalName)
            end

        end

    end

    -- Row-fatal: a disease bound to no animal type is unreachable, so keeping it
    -- would put an entry in the registry that nothing can ever match.
    if #animals == 0 then
        warn(warnings, title, "no-animal-types",
            string.format("no name in '%s' resolves to an animal type; disease dropped",
                tostring(animalNames)))
        return nil
    end

    local modelKey = key .. ".model"

    -- Row-fatal. One format, all or nothing: the legacy engine that could have run
    -- a model-less disease is gone, so a row with no <model> describes nothing any
    -- consumer can read.
    if not xmlFile:hasProperty(modelKey) then
        warn(warnings, title, "missing-model",
            "no <model> block; the definition file carries one format and a disease "
                .. "must be fully expressed in it; disease dropped")
        return nil
    end

    local model = {
        ["title"] = title,
        ["key"] = translationKey,
        ["name"] = deps.i18n:getText(translationKey),
        ["animals"] = animals,
        ["archetype"] = xmlFile:getString(modelKey .. "#archetype"),
        ["endpoint"] = xmlFile:getString(modelKey .. "#endpoint"),
        ["cullRequired"] = xmlFile:getBool(modelKey .. "#cullRequired"),
        ["incubationTicks"] = readNonNegative(xmlFile, modelKey .. "#incubationTicks",
            "incubationTicks", title, warnings, true),
        ["r0"] = readNonNegative(xmlFile, modelKey .. "#r0", "r0", title, warnings),
        ["caseFatality"] = readProbability(xmlFile, modelKey .. "#caseFatality",
            "caseFatality", title, warnings),
        ["immunityMonths"] = readNonNegative(xmlFile, modelKey .. "#immunityMonths",
            "immunityMonths", title, warnings, true),
        ["salePrice"] = readNonNegative(xmlFile, modelKey .. "#salePrice",
            "salePrice", title, warnings)
    }

    for _, field in ipairs(MODEL_REQUIRED_SCALARS) do
        if model[field] == nil then
            -- "or refused": a present-but-negative attribute reaches here as nil
            -- too, and reporting that one as missing sends the author looking for
            -- an attribute that is in the file.
            warn(warnings, title, "model-missing-scalar",
                string.format("<model> is missing or refused required attribute #%s; "
                    .. "disease dropped", field))
            return nil
        end
    end

    if not ARCHETYPES[model.archetype] then
        warn(warnings, title, "model-unknown-archetype",
            string.format("archetype %s is not one of infectious/genetic/management; "
                .. "carried through verbatim", tostring(model.archetype)))
    end

    if not readModelGenetic(xmlFile, modelKey, model, title, warnings) then return nil end

    -- The endpoint gates the pairing rule below, so an unrecognised one is refused
    -- HERE and the pairing never runs: it has no required attribute to select, and
    -- letting it run would report a spurious mismatch beside the real defect.
    -- Membership by `== nil`, never by truthiness - `lifelong` and `cureOnly` map
    -- to `false` and would otherwise read as unknown.
    if ENDPOINTS[model.endpoint] == nil then
        warn(warnings, title, "model-unknown-endpoint",
            string.format("endpoint %s is not one of recovers/terminal/lifelong/"
                .. "cureOnly; disease dropped", tostring(model.endpoint)))
        return nil
    end

    -- Exactly one duration attribute, selected by `endpoint`, and every other one
    -- FORBIDDEN. The FORBIDDEN half is tested by PRESENCE, not by the parsed value: a
    -- refused negative also reads as nil, so a value test would pass a
    -- declared-but-negative forbidden attribute while refusing a merely wrong positive
    -- one. The walk returns on the FIRST offence, so a model earns one mismatch warning.
    local requiredDuration = ENDPOINTS[model.endpoint]

    local durationDeclared = {}
    local durationValues = {}

    for _, attribute in ipairs(DURATION_ATTRIBUTES) do
        durationDeclared[attribute] = xmlFile:hasProperty(modelKey .. "#" .. attribute)
        durationValues[attribute] = readNonNegative(xmlFile, modelKey .. "#" .. attribute,
            attribute, title, warnings)
    end

    for _, attribute in ipairs(DURATION_ATTRIBUTES) do

        if attribute == requiredDuration then

            if durationValues[attribute] == nil then
                -- "missing OR REFUSED", the same wording MODEL_REQUIRED_SCALARS uses
                -- and for the same reason: a present-but-negative attribute reaches
                -- here as nil too, and rendering that as "(got nil)" sends the
                -- author looking for an attribute that is in the file. Where it was
                -- refused, `readNonNegative` has already said why.
                warn(warnings, title, "model-endpoint-duration-mismatch",
                    string.format("endpoint %s requires a usable #%s, which is "
                        .. "missing or refused; disease dropped",
                        tostring(model.endpoint), attribute))
                return nil
            end

            model[attribute] = durationValues[attribute]

        elseif durationDeclared[attribute] then

            warn(warnings, title, "model-endpoint-duration-mismatch",
                string.format("endpoint %s forbids #%s, which is declared; "
                    .. "disease dropped", tostring(model.endpoint), attribute))
            return nil

        end

    end

    if not readModelRecoveryChance(xmlFile, modelKey, model, title, warnings) then return nil end

    local infection = {}
    local lastAge = nil

    xmlFile:iterate(modelKey .. ".infection.key", function(_, infectionKey)

        local ageMonths = readNonNegative(xmlFile, infectionKey .. "#ageMonths",
            "infection ageMonths", title, warnings, true)
        local perMonth = readProbability(xmlFile, infectionKey .. "#perMonth",
            "infection perMonth", title, warnings)

        if ageMonths == nil or perMonth == nil then
            warn(warnings, title, "infection-key-incomplete",
                string.format("an <infection><key> is missing or refused #ageMonths or "
                    .. "#perMonth (age=%s perMonth=%s); key skipped",
                    tostring(ageMonths), tostring(perMonth)))
            return
        end

        -- The age-banded consumer walks its curve assuming ascending age, so an
        -- out-of-order pair silently selects the wrong band. A DUPLICATE age is
        -- deliberately NOT flagged: two rows at one age resolve to a hard step
        -- rather than an interpolation, which is a deliberate authoring idiom.
        if lastAge ~= nil and ageMonths < lastAge then
            warn(warnings, title, "infection-keys-unordered",
                string.format("<infection> key ageMonths %s follows %s; keys must "
                    .. "ascend by age", tostring(ageMonths), tostring(lastAge)))
        end

        lastAge = ageMonths

        table.insert(infection, { ["ageMonths"] = ageMonths, ["perMonth"] = perMonth })

    end)

    model.infection = infection

    readModelTreatment(xmlFile, modelKey, model, title, warnings)

    -- ROW-FATAL, and it cannot live inside `readModelTreatment`: that function
    -- early-returns when `<treatment>` is absent, so a `cureOnly` model carrying no
    -- block never reaches a line of it. Testing the ASSIGNED field catches all three
    -- failing shapes with one predicate - no block, a refused block, and a block
    -- declaring `relief`, which is why that arm above returns silently.
    if model.endpoint == RECORD_ENDPOINT.cureOnly and model.treatment == nil then
        warn(warnings, title, "endpoint-requires-curative-treatment",
            "endpoint cureOnly requires a <treatment outcome=\"cure\">, and none was "
                .. "usable; disease dropped")
        return nil
    end

    model.effects = {
        ["weightGain"] = readNonNegative(xmlFile, modelKey .. ".effects#weightGain",
            "effects weightGain", title, warnings),
        ["fertility"] = readNonNegative(xmlFile, modelKey .. ".effects#fertility",
            "effects fertility", title, warnings),
        ["output"] = readModelOutputs(xmlFile, modelKey .. ".effects", title, warnings)
    }

    if xmlFile:hasProperty(modelKey .. ".carrier") then

        -- The carrier profile is read against the CARRIER key by the same helper
        -- the base effects use.
        model.carrier = {
            ["output"] = readModelOutputs(xmlFile, modelKey .. ".carrier.effects",
                title, warnings)
        }

        -- A carrier that declares itself and then resolves to nothing is a silent
        -- empty table - and the usual cause is putting <output> directly under
        -- <carrier> instead of inside its <effects> wrapper. Nothing downstream can
        -- tell that apart from a carrier with no production effect, and the
        -- wrapper's confirming DEBUG line is gated on a non-empty profile, so
        -- without this it is invisible.
        if next(model.carrier.output) == nil then
            warn(warnings, title, "carrier-empty-profile",
                "<model><carrier> declares no usable output; check that <output> sits "
                    .. "inside a <carrier><effects> wrapper")
        end

    end

    model.prerequisites = readPrerequisites(xmlFile, modelKey .. ".prerequisites", title,
        "model-prerequisite-", warnings)

    return model

end


--- Parse the disease definition document into the registry and the authoring
--- warnings.
---
--- Never raises for any DOCUMENT, however malformed - which is what lets the wrapper
--- call it without a `pcall`, and what keeps a malformed file reaching its author as a
--- readable warning rather than as an aborted `DiseaseManager.new()` that leaves
--- `g_diseaseManager` nil. A nil `xmlFile` is a legitimate input, not a caller error:
--- routing it through here keeps ONE emission point for the whole rule vocabulary.
---@param xmlFile table|nil open XMLFile document, or nil where the file is absent
---@param deps table `{ animalTypes = <name-to-index map>, i18n = <text resolver> }`.
--- Injected, never read from the environment - a module-load read of either is the
--- load-order trap that reads populated headless and empty in-game.
---@return table registry map of title to disease entry. A MAP, not an array: use
--- `next(registry) == nil` for emptiness and a walk for a count, never `#`.
---@return table warnings array of `{ title, rule, detail }`, in document order
function RLDiseaseDefinition.parse(xmlFile, deps)

    local registry = {}
    local warnings = {}
    local seenTitles = {}

    if xmlFile == nil then
        warn(warnings, nil, "no-definition-file",
            "the disease definition file is absent; no disease is defined")
        return registry, warnings
    end

    xmlFile:iterate("diseases.disease", function(_, key)

        local title = xmlFile:getString(key .. "#title")

        -- Row-fatal, and it mirrors resolveRecordType's own predicate so the
        -- registry and its readers agree on what a usable title is.
        if title == nil or title == "" then
            warn(warnings, nil, "missing-title",
                string.format("a <disease> has no usable #title (got %s); disease dropped",
                    tostring(title)))
            return
        end

        -- First wins, matching the lookup's own contract. The title is reserved
        -- only once a row actually BUILDS - see below.
        if seenTitles[title] then
            warn(warnings, title, "duplicate-title",
                "a later <disease> repeats this title; the first definition wins and "
                    .. "this one is dropped")
            return
        end

        local entry = buildModelEntry(xmlFile, key, title, deps, warnings)

        if entry == nil then return end

        -- The reservation sits BELOW the build deliberately: a dropped first row
        -- holds no place, so a duplicate title behind a dropped row wins rather
        -- than being suppressed by a definition that is not in the registry.
        seenTitles[title] = true
        registry[title] = entry

        Log:trace("RLDiseaseDefinition: parsed %s", tostring(title))

    end)

    -- `next`, never `#`: the registry is a map and `#` on a map is always 0, so a
    -- length test here would emit this warning on every successful load.
    if next(registry) == nil then
        warn(warnings, nil, "no-diseases",
            "the definition file defines no usable disease; the registry is empty")
    end

    return registry, warnings

end


Log:info("RLDiseaseDefinition loaded")
