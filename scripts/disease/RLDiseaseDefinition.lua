--[[
    RLDiseaseDefinition.lua
    The one home for parsing xml/diseases.xml.

    `parse` walks the definition file once and returns three things: the LEGACY
    type list exactly as the old inline loader built it, a new `models` table
    keyed by title carrying the redesign's parameter set, and an array of
    authoring warnings. `DiseaseManager:loadDiseases` is a thin wrapper that
    opens the file, calls parse, assigns both tables and logs the warnings.

    Two halves, one pass, on purpose. The legacy half is what the shipped model
    runs on today and must stay byte-equivalent for the shipped file; the model
    half is what the later slices read and nothing consumes yet. Keeping both in
    one walk is what lets the teardown delete a branch rather than untangle one.

    WARNINGS ARE RETURNED, NEVER LOGGED HERE. A logger spy on the shared logger
    is banned portfolio-wide, so a rule asserted through the log is unassertable;
    returning the array makes every authoring rule a value assertion and leaves
    `loadDiseases` as the single emission point, which is what keeps the ModTest
    error-line prediction honest. Read the thin TRACE coverage below as that
    rather than as under-logging: every branch that REFUSES something already
    reports itself through a structured warning carrying the title, the rule and
    the detail - strictly more than a trace line would say. TRACE covers only the
    branches that produce no warning.

    A warning is a STRUCTURED value, never a formatted string:
    `{ title = <string|nil>, rule = <string>, detail = <string> }`. The suite
    field-compares `rule` and `title`; the wrapper renders the line. Warnings are
    emitted in document order.

    ROW-FATAL VERSUS FIELD-LOCAL is explicit. A disease missing `#title` or
    `#animals` is dropped from BOTH tables. Every other defect is field-local:
    the offending field or child is skipped, one warning is emitted, and the
    disease still loads. A malformed `<model>` never costs the disease its
    LEGACY entry - a new-half authoring error must not regress shipped gameplay.

    `deps` arrives as a PARAMETER with no default: `{ animalTypes, i18n }`. This
    module never reads a root global and never caches one at module load - that
    is the load-order trap that reads populated headless and empty in-game.

    Pure data-in / data-out apart from that: no GUI, no engine natives beyond the
    XMLFile the caller hands over, so the module dual-runs headless.

    SHARP EDGES, named so the next reader does not rediscover them.

    The per-disease closure must NEVER `return false`: `XMLFile:iterate` stops on
    an exact `false`, so a skip written that way would drop every LATER disease
    too and leave the registry short with no error. Every skip path here falls
    off the end of the closure instead.

    Read every value that must be validated for INTEGRALITY as a float, never as
    an int. The engine's native integer read TRUNCATES a fractional lexical
    before the guard can see it, while the headless XML shim is `tonumber()` and
    preserves it - so a whole-number check on an int-read value can only ever
    fire on one of the two runners, and the dual-run count gate is blind to the
    split because the divergence is in values.

    THE LEGACY CARRIER PATH IS DELIBERATELY WRONG. `readLegacyOutputs` is called
    for the carrier block against the BASE key, not the carrier key, reproducing
    the shipped defect exactly. Repairing it would hand every cvm carrier +50%
    milk immediately, which contradicts "the shipped model behaves identically".
    The MODEL half reads the carrier profile correctly, through the same helper
    as `<effects>` against a different base key. Do not unify them into one
    "fixed" reader.
]]

RLDiseaseDefinition = {}

local Log = RmLogging.getLogger("RLRM")


--- The four output channels the design archive locks. A typo outside this set is
--- otherwise a permanently inert multiplier, which is exactly the silent failure
--- the archetype warning also exists to prevent.
local OUTPUT_CHANNELS = {
    ["milk"] = true,
    ["pallets"] = true,
    ["manure"] = true,
    ["liquidManure"] = true
}

--- Archetype is an OPEN vocabulary: an unknown value warns and is carried through
--- verbatim rather than rejected, so a future kind needs no schema churn. The
--- warning is what stops a typo becoming a silent third archetype.
local ARCHETYPES = {
    ["infectious"] = true,
    ["genetic"] = true
}

--- Prerequisite value types, as an ALLOWLIST rather than a `type(fn) == "function"`
--- probe: the legacy loader indexes `XMLFile["get" .. valueType]`, so a typo is a
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
--- design archive names `chronic` specifically as a field that must be declared
--- rather than inferred from absence. The duration pair is required separately,
--- selected by `chronic`.
local MODEL_REQUIRED_SCALARS = {
    "archetype", "chronic", "cullRequired", "incubationTicks",
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


--- Read one non-negative scalar.
---
--- Negativity is ONE rule rather than a per-field matrix: every scalar in this
--- schema is a count, a duration, a rate or a multiplier, and none of them has a
--- meaningful negative value.
---
--- The reader is selected with an explicit branch rather than `asInt and getInt or
--- getFloat`: that idiom falls through to the float reader whenever the int reader
--- returns nil, so a caller asking for an int would silently get a float.
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


--- Read a `<fillType type modifier>` list into a `type -> modifier` map.
---
--- Used by the LEGACY half against the disease's own `.output` and, deliberately,
--- against the SAME base key for the legacy carrier block - see the header. The
--- model half has its own reader, which additionally applies the channel
--- allowlist; this one deliberately does not, because an unknown channel here is
--- a pre-existing inert multiplier rather than something this slice may change.
---
--- Byte-equivalent for the SHIPPED file, where all eight rows carry both
--- attributes. The two guards below change behaviour only for malformed input:
--- a missing `#type` makes the shipped loader evaluate `output[nil] = v` and
--- RAISE inside `DiseaseManager.new()`, leaving `g_diseaseManager` nil and
--- silently skipping every registration below it, and a missing `#modifier`
--- writes a nil that reads as "no penalty" forever.
---@param xmlFile table open XMLFile document
---@param baseKey string key whose `.fillType` children are read
---@param title string the owning disease, for warning attribution
---@param warnings table the accumulator
---@return table map of channel name to modifier
local function readLegacyOutputs(xmlFile, baseKey, title, warnings)

    local output = {}

    xmlFile:iterate(baseKey .. ".fillType", function(_, outputKey)

        local channel = xmlFile:getString(outputKey .. "#type")
        local modifier = xmlFile:getFloat(outputKey .. "#modifier")

        if channel == nil then
            warn(warnings, title, "legacy-output-missing-type",
                string.format("a <fillType> row under %s has no #type; row skipped",
                    tostring(baseKey)))
            return
        end

        if modifier == nil then
            warn(warnings, title, "legacy-output-missing-modifier",
                string.format("<fillType> %s has no #modifier; row skipped", tostring(channel)))
            return
        end

        output[channel] = modifier

    end)

    return output

end


--- Read a `<output type modifier>` list for the MODEL half, refusing an unknown
--- channel, an incomplete row and a negative multiplier.
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

        if not OUTPUT_CHANNELS[channel] then
            warn(warnings, title, "output-unknown-channel",
                string.format("output channel %s is not one of milk/pallets/manure/"
                    .. "liquidManure; row skipped", tostring(channel)))
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

    end)

    return output

end


--- Read a `<prerequisites>` list, refusing an incomplete or badly-typed entry.
---
--- Shared by both halves against different base keys. The `valueType` check is an
--- allowlist rather than a callable probe, because the read below indexes
--- `XMLFile["get" .. valueType]` and a typo is otherwise a nil call - a raise.
---@param xmlFile table open XMLFile document
---@param baseKey string key whose `.prerequisite` children are read
---@param title string the owning disease, for warning attribution
---@param rulePrefix string warning-rule prefix, so each half is attributable
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


--- Build the LEGACY type entry for one disease, or nil where the row is dropped.
---
--- Every key the old inline loader produced is produced here, with the same
--- defaults and the same optional-key nilness, because `Disease.lua` dereferences
--- eleven distinct type fields and the three readers of `self.diseases` are out of
--- scope for this slice.
---@param xmlFile table open XMLFile document
---@param key string this disease's element key
---@param title string resolved, non-empty title
---@param deps table `{ animalTypes, i18n }`
---@param warnings table the accumulator
---@return table|nil the legacy entry, or nil when the row must be dropped
local function buildLegacyEntry(xmlFile, key, title, deps, warnings)

    local translationKey = "rl_disease_" .. title
    local animalNames = xmlFile:getString(key .. "#animals")

    -- Row-fatal: today `string.split(nil, " ")` raises here, which aborts
    -- DiseaseManager.new() and leaves g_diseaseManager nil for the whole session.
    if animalNames == nil then
        warn(warnings, title, "missing-animals", "no #animals attribute; disease dropped")
        return nil
    end

    local animals = {}
    local resolvedAny = false

    for _, animalName in pairs(string.split(animalNames, " ")) do

        -- An empty token is skipped rather than resolved. The engine's split
        -- yields one for a leading, trailing or doubled space while the headless
        -- one drops it, so without this the two runners emit different warning
        -- sets for the same file.
        if animalName ~= "" then

            local typeIndex = deps.animalTypes[animalName]

            -- Today `animals[nil] = true` raises here, with the same blast radius.
            if typeIndex == nil then
                warn(warnings, title, "unknown-animal-type",
                    string.format("animal type %s does not resolve; name skipped",
                        tostring(animalName)))
            else
                animals[typeIndex] = true
                resolvedAny = true
            end

        end

    end

    -- Row-fatal: a disease bound to no animal type is unreachable, so keeping it
    -- would put an entry in the registry that nothing can ever match.
    if not resolvedAny then
        warn(warnings, title, "no-animal-types",
            string.format("no name in '%s' resolves to an animal type; disease dropped",
                tostring(animalNames)))
        return nil
    end

    local prerequisites = readPrerequisites(xmlFile, key .. ".prerequisites", title,
        "prerequisite-", warnings)

    local probability = {}

    xmlFile:iterate(key .. ".probability.key", function(_, probabilityKey)

        local age = xmlFile:getInt(probabilityKey .. "#age")
        local value = xmlFile:getFloat(probabilityKey .. "#value")

        -- Today an absent attribute here raises during GAMEPLAY rather than at
        -- load, in the per-animal probability walk.
        if age == nil or value == nil then
            warn(warnings, title, "probability-key-incomplete",
                string.format("a <probability><key> is missing #age or #value "
                    .. "(age=%s value=%s); key skipped", tostring(age), tostring(value)))
            return
        end

        table.insert(probability, { ["age"] = age, ["value"] = value })

    end)

    local fatality = {}

    xmlFile:iterate(key .. ".fatality.key", function(_, fatalityKey)

        local time = xmlFile:getInt(fatalityKey .. "#time")
        local value = xmlFile:getFloat(fatalityKey .. "#value")

        if time == nil or value == nil then
            warn(warnings, title, "fatality-key-incomplete",
                string.format("a <fatality><key> is missing #time or #value "
                    .. "(time=%s value=%s); key skipped", tostring(time), tostring(value)))
            return
        end

        table.insert(fatality, { ["time"] = time, ["value"] = value })

    end)

    local treatment = {
        ["cost"] = xmlFile:getFloat(key .. ".treatment#cost"),
        ["duration"] = xmlFile:getInt(key .. ".treatment#duration")
    }

    if treatment.cost == nil or treatment.duration == nil then treatment = nil end

    local disease = {
        ["title"] = title,
        ["key"] = translationKey,
        ["name"] = deps.i18n:getText(translationKey),
        ["animals"] = animals,
        ["value"] = xmlFile:getFloat(key .. "#value", 1.0),
        ["transmission"] = xmlFile:getFloat(key .. "#transmission", 0),
        ["immunity"] = xmlFile:getInt(key .. "#immunity", 12),
        ["prerequisites"] = prerequisites,
        ["probability"] = probability,
        ["fatality"] = fatality,
        ["output"] = readLegacyOutputs(xmlFile, key .. ".output", title, warnings),
        ["treatment"] = treatment,
        ["recovery"] = xmlFile:getFloat(key .. "#recovery")
    }

    if xmlFile:hasProperty(key .. ".carrier") then

        local carrier = {}

        if xmlFile:hasProperty(key .. ".carrier.output") then
            -- DELIBERATELY the base key, not the carrier key. See the header:
            -- this reproduces the shipped defect so the legacy half stays
            -- byte-equivalent; the model half reads the carrier correctly.
            carrier.output = readLegacyOutputs(xmlFile, key .. ".output", title, warnings)
        end

        disease.carrier = carrier

    end

    if xmlFile:hasProperty(key .. ".genetic") then

        -- Row-fatal: the sale-animal pass dereferences `probability[1].value`
        -- unguarded, so a genetic disease with no probability keys raises there.
        if #probability == 0 then
            warn(warnings, title, "genetic-empty-probability",
                "a <genetic> disease declares no <probability><key>; disease dropped")
            return nil
        end

        disease.genetic = {
            ["recessive"] = xmlFile:getBool(key .. ".genetic#recessive", false),
            ["dominant"] = xmlFile:getBool(key .. ".genetic#dominant", false),
            ["saleChance"] = xmlFile:getFloat(key .. ".genetic#saleChance", 0)
        }

    end

    return disease

end


--- Read the `<model><treatment>` child onto `model`, or refuse it.
---
--- All three fields are required together. A partially-populated record is worse
--- than none: the module's contract is that there are no silent defaults, and a
--- consumer doing arithmetic on a nil cost raises far from here.
---@param xmlFile table open XMLFile document
---@param modelKey string the `<model>` element key
---@param model table the model entry being built
---@param title string the owning disease
---@param warnings table the accumulator
local function readModelTreatment(xmlFile, modelKey, model, title, warnings)

    if not xmlFile:hasProperty(modelKey .. ".treatment") then return end

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

    -- The archive's real rule: a course no shorter than the illness means the
    -- animal recovers naturally before it completes, so treating is pointless. A
    -- chronic disease has no duration to compare against.
    if not model.chronic and months >= model.durationMonths then
        warn(warnings, title, "treatment-not-shorter-than-illness",
            string.format("treatment runs %s month(s) against a %s-month illness; the "
                .. "course must be strictly shorter; treatment skipped",
                tostring(months), tostring(model.durationMonths)))
        return
    end

    model.treatment = { ["months"] = months, ["cost"] = cost, ["efficacy"] = efficacy }

end


--- Build the MODEL entry for one disease, or nil where the model half is skipped.
---
--- A refusal here costs the disease only its MODEL half; its legacy entry is built
--- by the caller and survives regardless.
---@param xmlFile table open XMLFile document
---@param key string this disease's element key
---@param title string resolved, non-empty title
---@param warnings table the accumulator
---@return table|nil the model entry, or nil where absent or refused
local function buildModelEntry(xmlFile, key, title, warnings)

    local modelKey = key .. ".model"

    -- A file mid-migration must still load: no <model> is not a defect.
    if not xmlFile:hasProperty(modelKey) then
        Log:trace("RLDiseaseDefinition: %s carries no <model> block, legacy half only",
            tostring(title))
        return nil
    end

    local model = {
        ["archetype"] = xmlFile:getString(modelKey .. "#archetype"),
        ["chronic"] = xmlFile:getBool(modelKey .. "#chronic"),
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
                    .. "model half skipped", field))
            return nil
        end
    end

    if not ARCHETYPES[model.archetype] then
        warn(warnings, title, "model-unknown-archetype",
            string.format("archetype %s is not one of infectious/genetic; carried "
                .. "through verbatim", tostring(model.archetype)))
    end

    -- Exactly one of the duration pair, selected by `chronic`. Overloading one
    -- attribute to mean both under a flag was rejected: a consumer that forgot to
    -- branch would read a median as a duration and get plausible wrong numbers.
    --
    -- The FORBIDDEN half is tested by PRESENCE, not by the parsed value. A refused
    -- value (a negative one) also reads as nil, so a value test would let a
    -- declared-but-negative forbidden attribute through while refusing a merely
    -- wrong positive one - a more corrupt file passing where a less corrupt one
    -- fails.
    local declaresDuration = xmlFile:hasProperty(modelKey .. "#durationMonths")
    local declaresChronicMonths = xmlFile:hasProperty(modelKey .. "#chronicMonthsToDeath")

    local durationMonths = readNonNegative(xmlFile, modelKey .. "#durationMonths",
        "durationMonths", title, warnings)
    local chronicMonthsToDeath = readNonNegative(xmlFile, modelKey .. "#chronicMonthsToDeath",
        "chronicMonthsToDeath", title, warnings)

    if model.chronic then

        if chronicMonthsToDeath == nil or declaresDuration then
            warn(warnings, title, "model-duration-mismatch",
                string.format("chronic=true requires a usable #chronicMonthsToDeath and "
                    .. "forbids #durationMonths (got %s / declares durationMonths=%s); "
                    .. "model half skipped",
                    tostring(chronicMonthsToDeath), tostring(declaresDuration)))
            return nil
        end

        model.chronicMonthsToDeath = chronicMonthsToDeath

    else

        if durationMonths == nil or declaresChronicMonths then
            warn(warnings, title, "model-duration-mismatch",
                string.format("chronic=false requires a usable #durationMonths and "
                    .. "forbids #chronicMonthsToDeath (got %s / declares "
                    .. "chronicMonthsToDeath=%s); model half skipped",
                    tostring(durationMonths), tostring(declaresChronicMonths)))
            return nil
        end

        model.durationMonths = durationMonths

    end

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

        -- The legacy age-banded consumer walks its curve assuming ascending age,
        -- so an out-of-order pair silently selects the wrong band. A DUPLICATE age
        -- is deliberately NOT flagged: two rows at one age resolve to a hard step
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

    model.effects = {
        ["weightGain"] = readNonNegative(xmlFile, modelKey .. ".effects#weightGain",
            "effects weightGain", title, warnings),
        ["fertility"] = readNonNegative(xmlFile, modelKey .. ".effects#fertility",
            "effects fertility", title, warnings),
        ["output"] = readModelOutputs(xmlFile, modelKey .. ".effects", title, warnings)
    }

    if xmlFile:hasProperty(modelKey .. ".carrier") then

        -- The carrier profile is read against the CARRIER key by the same helper
        -- the base effects use. This is the carrier repair, and it lives only on
        -- this half.
        model.carrier = {
            ["output"] = readModelOutputs(xmlFile, modelKey .. ".carrier.effects",
                title, warnings)
        }

        -- A carrier that declares itself and then resolves to nothing is the same
        -- silent-empty-table failure this half exists to repair, one level down -
        -- and the usual cause is putting <output> directly under <carrier> instead
        -- of inside its <effects> wrapper. Nothing downstream can tell that apart
        -- from a carrier with no production effect, and the wrapper's confirming
        -- DEBUG line is gated on a non-empty profile, so without this it is
        -- invisible.
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


--- Parse the disease definition document into the legacy list, the model map and
--- the authoring warnings.
---
--- Never raises for any DOCUMENT, however malformed - which is what lets the
--- wrapper call it without a `pcall`. A definition file is authored inside the mod
--- archive, so a malformed one must reach its author as a readable warning at the
--- next launch rather than as an aborted `DiseaseManager.new()` that leaves
--- `g_diseaseManager` nil and silently skips every registration below it. The
--- `deps` contract is a caller concern and is not defended here: it is supplied by
--- the wrapper two lines up, and a wiring bug there should crash loudly.
---
--- A nil `xmlFile` is a legitimate input, not a caller error: `loadIfExists`
--- returns nil for an absent file, and routing that case through here rather than
--- through the wrapper keeps ONE emission point for the whole rule vocabulary.
---@param xmlFile table|nil open XMLFile document, or nil where the file is absent
---@param deps table `{ animalTypes = <name-to-index map>, i18n = <text resolver> }`.
--- Injected, never read from the environment - a module-load read of either is the
--- load-order trap that reads populated headless and empty in-game.
---@return table legacy array of legacy type entries, in document order
---@return table models map of title to model entry, for the diseases that carry one
---@return table warnings array of `{ title, rule, detail }`, in document order
function RLDiseaseDefinition.parse(xmlFile, deps)

    local legacy = {}
    local models = {}
    local warnings = {}
    local seenTitles = {}

    if xmlFile == nil then
        warn(warnings, nil, "no-definition-file",
            "the disease definition file is absent; no disease is defined")
        return legacy, models, warnings
    end

    xmlFile:iterate("diseases.disease", function(_, key)

        local title = xmlFile:getString(key .. "#title")

        -- Row-fatal, and it mirrors resolveRecordType's own predicate so the two
        -- halves of the registry agree on what a usable title is.
        if title == nil or title == "" then
            warn(warnings, nil, "missing-title",
                string.format("a <disease> has no usable #title (got %s); disease dropped",
                    tostring(title)))
            return
        end

        -- First wins, matching getDiseaseByTitle's existing linear scan, so the
        -- legacy array and the models map resolve a duplicate the same way. The
        -- title is reserved only once a row actually BUILDS: a dropped first row
        -- holds no place, or a malformed one would suppress a valid successor and
        -- the title would resolve to nothing at all.
        if seenTitles[title] then
            warn(warnings, title, "duplicate-title",
                "a later <disease> repeats this title; the first definition wins and "
                    .. "this one is dropped")
            return
        end

        local entry = buildLegacyEntry(xmlFile, key, title, deps, warnings)

        if entry == nil then return end

        seenTitles[title] = true
        table.insert(legacy, entry)

        local model = buildModelEntry(xmlFile, key, title, warnings)

        if model ~= nil then models[title] = model end

        Log:trace("RLDiseaseDefinition: parsed %s (model=%s)",
            tostring(title), tostring(model ~= nil))

    end)

    if #legacy == 0 then
        warn(warnings, nil, "no-diseases",
            "the definition file defines no usable disease; the registry is empty")
    end

    return legacy, models, warnings

end


Log:info("RLDiseaseDefinition loaded")
