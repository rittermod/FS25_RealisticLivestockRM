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

    `deps` arrives as a PARAMETER with no default: `{ animalTypes, i18n }`. No
    RUNTIME global is read here and none is cached at module load - that is the
    load-order trap that reads populated headless and empty in-game.

    THE ONE MODULE-LOAD GLOBAL READ IS `RLDiseaseRecord.ENDPOINT`, and it is the
    exception that proves the rule above rather than a breach of it: a sibling
    module's CONSTANT is populated the moment that file is sourced and never moves
    afterwards, where the trap is about runtime state that fills later. The cost is
    a hard ordering requirement - `RLDiseaseRecord.lua` MUST be sourced before this
    file, in `main.lua` and in `tests/headless/animal_env.lua` alike. Get it wrong
    and the read below raises on a nil global, which takes `parse` with it and is
    loud in-game; the headless tier cannot see the mistake at all, because its env
    sources the record itself whatever `main.lua` says.

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
---
--- `management` covers the non-transmissible, non-inherited conditions - wear,
--- diet, parasites. The archive's vaccination taxonomy names a degenerative kind
--- beside it, but mechanically the two are one class (neither transmits, neither
--- is inherited), so this is one value rather than two.
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
--- CLOSED, unlike `ARCHETYPES`: an endpoint decides which OTHER attributes are
--- required and forbidden, so an unrecognised one has no defined parse at all.
--- Membership is tested with `~= nil`, never for truthiness - `false` is a legal
--- entry and the clockless pair would otherwise read as unknown.
---
--- The two durations are NOT interchangeable and must never be merged into one
--- attribute. `durationMonths` is a fractional SPAN - how long the infectious
--- phase runs before natural recovery. `chronicMonthsToDeath` is a MEDIAN,
--- converted `1 - 0.5 ^ (1/m)` into a per-month hazard by its consumer. Merging
--- them turns a geometric tail into a deterministic death at the clock boundary,
--- with no error and plausible numbers on either side.
local ENDPOINTS = {
    -- the span elapses and the animal recovers naturally
    [RECORD_ENDPOINT.recovers] = "durationMonths",
    -- the hazard kills on its own clock; only a completed, successful curative
    -- course ends it any other way (see `RLDiseaseRecord.RECOVERY_EXITS`)
    [RECORD_ENDPOINT.terminal] = "chronicMonthsToDeath",
    -- nothing ends it; the animal sheds for life
    [RECORD_ENDPOINT.lifelong] = false,
    -- only a completed curative course ends it
    [RECORD_ENDPOINT.cureOnly] = false
}


--- The duration attributes the pairing rule walks: exactly one is required per
--- endpoint and every other one is FORBIDDEN, so the walk needs the whole set
--- rather than just the required member.
---
--- DERIVED from `ENDPOINTS` rather than hand-written beside it, which is what makes
--- the "one home" claim above true instead of aspirational. A second hand-kept list
--- drifts in one direction silently: an endpoint mapped to an attribute missing
--- from the walk matches no iteration, so its required check never runs, its value
--- is never assigned, and the model half loads with no duration AND no warning -
--- the exact silent-default class this module exists to prevent.
---
--- Sorted for a stable walk order. Order does not change any verdict - the required
--- attribute is matched by name and every other declared one is refused - but it
--- decides WHICH detail string an author sees first, and a `pairs` order would make
--- that differ per process and between the two runners.
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
--- design archive names the endpoint specifically as a field that must be declared
--- rather than inferred from absence - an absent attribute is indistinguishable
--- from a typo. The duration pair is required separately, selected by `endpoint`.
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
---@return table|nil the type NAMES that resolved, in document order, for the MODEL
--- half to carry. Nil exactly when the entry is nil, so a caller that checks the
--- first return never has to check this one.
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

    -- The same resolve, collected a second way for the MODEL half. The legacy set
    -- is keyed by type INDEX because that is what its consumers walk; the model
    -- half needs NAMES, and the two shapes coexist until the legacy half is torn
    -- down. Collected HERE rather than re-read inside `buildModelEntry`: a second
    -- read of the attribute would emit every unknown-name warning a second time
    -- under a second rule, and resolving once at load keeps the name-to-index hop
    -- off every later path.
    local resolvedNames = {}

    -- `ipairs`, not `pairs`, and that is load-bearing rather than tidy: the array
    -- built below is stored as `model.animals`, whose contract is DOCUMENT ORDER,
    -- while `pairs` traversal order is undefined. Both runners' splits return a
    -- contiguous sequence, so the two walk the same tokens.
    for _, animalName in ipairs(string.split(animalNames, " ")) do

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
                table.insert(resolvedNames, animalName)
            end

        end

    end

    -- Row-fatal: a disease bound to no animal type is unreachable, so keeping it
    -- would put an entry in the registry that nothing can ever match.
    if #resolvedNames == 0 then
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

    return disease, resolvedNames

end


--- Read the `<model><treatment>` child onto `model`, or refuse it.
---
--- All four fields are required together. A partially-populated record is worse
--- than none: the module's contract is that there are no silent defaults, and a
--- consumer doing arithmetic on a nil cost raises far from here.
---
--- `efficacy` is the probability that a COMPLETED course achieves its `outcome`,
--- rolled once at completion - not per tick, and not a partial-effect multiplier.
--- Its consumer owns the failure path; this function only pins the domain.
---
--- ONE ARM OF THE COMPATIBILITY TABLE IS DELIBERATELY SILENT, and that is the
--- single trap in this function. A `cureOnly` model whose block declares `relief`
--- is refused by returning without assigning `model.treatment` and WITHOUT a
--- warning, because the caller's endpoint gate emits the one warning that case
--- earns - see `buildModelEntry`. Warning here as well would report the same
--- authoring mistake twice under two different rules.
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

    -- The silent arm. See the header: `buildModelEntry` refuses the whole model
    -- half for a `cureOnly` that ends up with no treatment, and this is one of the
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

    -- The archive's real rule, and it holds for exactly ONE cell of the endpoint x
    -- outcome table. Its reason - the animal recovers naturally before the course
    -- completes, so treating is pointless - is true only where recovery is what
    -- ends the illness AND the course is trying to beat it there. Against a
    -- `terminal` model the course races a median rather than a deadline, and a
    -- `relief` course is not trying to clear anything, so neither is pointless at
    -- any length. Both fields are DECLARED, so this gate reads no absence.
    if model.endpoint == RECORD_ENDPOINT.recovers and outcome == "cure"
        and months >= model.durationMonths then
        warn(warnings, title, "treatment-not-shorter-than-illness",
            string.format("treatment runs %s month(s) against a %s-month illness; the "
                .. "course must be strictly shorter; treatment skipped",
                tostring(months), tostring(model.durationMonths)))
        return
    end

    model.treatment = {
        ["months"] = months,
        ["cost"] = cost,
        ["efficacy"] = efficacy,
        ["outcome"] = outcome
    }

end


--- Build the MODEL entry for one disease, or nil where the model half is skipped.
---
--- A refusal here costs the disease only its MODEL half; its legacy entry is built
--- by the caller and survives regardless.
---@param xmlFile table open XMLFile document
---@param key string this disease's element key
---@param title string resolved, non-empty title
---@param animalTypeNames table the type NAMES that resolved for this disease, from
--- `buildLegacyEntry`. Stored verbatim as `model.animals` - never re-read from the
--- attribute here, and never uppercased, since the resolve that produced it already
--- required the authored casing.
---@param warnings table the accumulator
---@return table|nil the model entry, or nil where absent or refused
local function buildModelEntry(xmlFile, key, title, animalTypeNames, warnings)

    local modelKey = key .. ".model"

    -- A file mid-migration must still load: no <model> is not a defect.
    if not xmlFile:hasProperty(modelKey) then
        Log:trace("RLDiseaseDefinition: %s carries no <model> block, legacy half only",
            tostring(title))
        return nil
    end

    local model = {
        -- The affected type NAMES, threaded from the legacy resolve rather than
        -- re-read here. The shedding bound a chronic disease needs is the
        -- shortest-lived affected species, and its consumer is a pure module that
        -- may not reach the animal-type registry - so the resolve stays where it
        -- already happens, at LOAD, and the model carries the result. The legacy
        -- half's own set stays INDEX-keyed; the two shapes coexist until it goes.
        ["animals"] = animalTypeNames,
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
                    .. "model half skipped", field))
            return nil
        end
    end

    if not ARCHETYPES[model.archetype] then
        warn(warnings, title, "model-unknown-archetype",
            string.format("archetype %s is not one of infectious/genetic/management; "
                .. "carried through verbatim", tostring(model.archetype)))
    end

    -- The endpoint gates the pairing rule below, so an unrecognised one is refused
    -- HERE and the pairing never runs: it has no required attribute to select, and
    -- letting it run would report a spurious mismatch beside the real defect.
    -- Membership by `== nil`, never by truthiness - `lifelong` and `cureOnly` map
    -- to `false` and would otherwise read as unknown.
    if ENDPOINTS[model.endpoint] == nil then
        warn(warnings, title, "model-unknown-endpoint",
            string.format("endpoint %s is not one of recovers/terminal/lifelong/"
                .. "cureOnly; model half skipped", tostring(model.endpoint)))
        return nil
    end

    -- Exactly one duration attribute, selected by `endpoint`, and every other one
    -- FORBIDDEN. The pair stays two attributes rather than one overloaded field
    -- because they are different quantities - a span and a median - and a consumer
    -- that forgot to branch would read one as the other and get plausible wrong
    -- numbers with no error.
    --
    -- The FORBIDDEN half is tested by PRESENCE, not by the parsed value. A refused
    -- value (a negative one) also reads as nil, so a value test would let a
    -- declared-but-negative forbidden attribute through while refusing a merely
    -- wrong positive one - a more corrupt file passing where a less corrupt one
    -- fails.
    --
    -- Both are read unconditionally, so a negative one still reports itself; the
    -- walk then returns on the FIRST offence, so a model earns exactly one mismatch
    -- warning however many attributes it got wrong.
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
                        .. "missing or refused; model half skipped",
                        tostring(model.endpoint), attribute))
                return nil
            end

            model[attribute] = durationValues[attribute]

        elseif durationDeclared[attribute] then

            warn(warnings, title, "model-endpoint-duration-mismatch",
                string.format("endpoint %s forbids #%s, which is declared; "
                    .. "model half skipped", tostring(model.endpoint), attribute))
            return nil

        end

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

    -- MODEL-local, and it cannot live inside `readModelTreatment`: that function
    -- early-returns when `<treatment>` is absent, so a `cureOnly` model carrying no
    -- block at all never reaches a single line of it. Testing the ASSIGNED field
    -- here instead catches all three failing shapes with one predicate, because
    -- `model.treatment` is written only on that function's success path: no block,
    -- a block refused for its months / cost / efficacy, and a block declaring
    -- `relief` (which returns silently for exactly this reason).
    --
    -- Refusing the whole model half is the right severity: the endpoint says the
    -- infection ends only through a completed cure, so without one it never ends
    -- at all and the model describes an animal nothing can ever help.
    -- Tests the assigned RESULT, not the outcome attribute, and that is the spec's
    -- prescribed shape rather than an accident. A second clause reading
    -- `model.treatment.outcome ~= "cure"` was written here at code review and
    -- REVERTED: it is unreachable, because the relief arm above returns before
    -- assigning, so nothing can construct a `model.treatment` whose outcome is not
    -- `cure`. An unreachable defensive clause cannot be tested or break-proved, and
    -- it made this line contradict the Design Note that explains why one predicate
    -- covers all three shapes. The coupling to the relief arm is real and is
    -- documented at BOTH sites instead.
    if model.endpoint == RECORD_ENDPOINT.cureOnly and model.treatment == nil then
        warn(warnings, title, "endpoint-requires-curative-treatment",
            "endpoint cureOnly requires a <treatment outcome=\"cure\">, and none was "
                .. "usable; model half skipped")
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

        local entry, animalTypeNames = buildLegacyEntry(xmlFile, key, title, deps, warnings)

        if entry == nil then return end

        seenTitles[title] = true
        table.insert(legacy, entry)

        local model = buildModelEntry(xmlFile, key, title, animalTypeNames, warnings)

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
