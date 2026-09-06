--[[
    RLDiseaseTransmission.lua
    Turns an authored R0 into the per-tick probability a susceptible animal rolls
    against one shedding disease. R0 is authored and the monthly rate is DERIVED, so
    the authored number means the same thing at every period length.

    THE COMPOSITION ORDER IS THE CONTRACT - prevalence multiplies the MONTHLY rate and
    the per-tick conversion happens LAST:
        beta = r0 / contagiousMonths ; monthly = beta * prevalence  -- both per MONTH
        pTick = perTick(min(monthly, 1), daysPerPeriod)
    EXPOSED SHEDS, so the hidden window counts in full. The shedding cap is
    DISEASE-level - the shortest-lived affected species - which is the OPPOSITE
    reading from the vulnerability module's animal-level age term. Pure data-in /
    data-out; the clamp at 1 voids the R0 guarantee above saturation.
]]

RLDiseaseTransmission = {}

local Log = RmLogging.getLogger("RLRM")


--- The shortest lifespan among a disease's affected animal types, in months.
---
--- An unrecognised type is SKIPPED rather than poisoning the minimum, so one
--- map-bridge or pack animal cannot silently switch a shipped disease from bounded
--- to unbounded. Parser output cannot reach that path; hand-built fixtures can.
--- @param animalTypeNames table|nil Ordered array of uppercase type NAMES. A nil
---        or non-table returns nil rather than raising.
--- @return number|nil months The smallest lifespan that resolved, or nil when
---         nothing did
function RLDiseaseTransmission.diseaseLifespanMonths(animalTypeNames)
    if type(animalTypeNames) ~= "table" then return nil end

    -- `ipairs` deliberately - the parser builds an ordered array. A hole therefore
    -- truncates SILENTLY (`{[1]="COW",[3]="CHICKEN"}` returns 240, dropping the very
    -- bound this exists to find) and a hash-keyed table walks nothing at all; the
    -- warning below covers a walked list that resolved NOTHING, never a truncated one.
    local walked = 0
    local resolved = 0
    local smallest = nil
    local firstUnresolved = nil

    for _, animalTypeName in ipairs(animalTypeNames) do
        walked = walked + 1

        local months = RLDiseaseVulnerability.maxLifespanMonthsFor(animalTypeName)

        if months == nil then
            if firstUnresolved == nil then firstUnresolved = animalTypeName end
        else
            resolved = resolved + 1

            if smallest == nil or months < smallest then
                smallest = months
            end
        end
    end

    -- ONE line, and only for TOTAL failure: a nil bound makes an unbounded endpoint
    -- shed forever, driving its transmission rate to zero for the life of the save.
    if walked > 0 and resolved == 0 then
        Log:warning("RLDiseaseTransmission.diseaseLifespanMonths: walked %d type name(s) "
            .. "and resolved none (first was %s) - the disease gets no shedding bound",
            walked, tostring(firstUnresolved))
    end

    return smallest
end


--- The expected number of months a case spends shedding SYMPTOMATICALLY.
---
--- Solves the flat-hazard window over the endpoint's span - a case that dies stops
--- shedding - then caps it by the disease-level species lifespan.
--- @param model table|nil A parsed model entry. TRUSTED INTERNAL input; a nil or
---        non-table returns 0 rather than raising.
--- @param maxLifespanMonths number|nil The DISEASE-level bound, as
---        `diseaseLifespanMonths` returns it. A nil means no bound at all. NOT
---        validated, and unlike the other inputs it reaches `math.min`'s SECOND
---        slot, which KEEPS a NaN - a caller computing the bound another way owes
---        its own finite-positive check.
--- @return number months Expected symptomatic months, 0 on every refusal
function RLDiseaseTransmission.expectedSheddingMonths(model, maxLifespanMonths)
    if type(model) ~= "table" then return 0 end

    local ENDPOINT = RLDiseaseRecord.ENDPOINT
    local endpoint = model.endpoint
    local span

    -- CLOSED dispatch, read through the record module's vocabulary at CALL time.
    -- `span` stays nil for the three endpoints nothing clocks, which the solve below
    -- reads as an unbounded window.
    if endpoint == ENDPOINT.recovers then
        span = model.durationMonths
    elseif endpoint == ENDPOINT.terminal
        or endpoint == ENDPOINT.lifelong
        or endpoint == ENDPOINT.cureOnly then
        span = nil
    else
        Log:debug("RLDiseaseTransmission.expectedSheddingMonths: refused an unrecognised "
            .. "endpoint=%s - returning a window of 0 rather than guessing one",
            tostring(endpoint))

        return 0
    end

    -- The UNSCALED authored rate: the window is a disease-level property, so the
    -- per-animal vulnerability factor does not enter it.
    local hazard = RLDiseaseFatality.monthlyHazard(model)
    local raw

    -- ONE branch chain assigning `raw` and never returning from inside it, so the
    -- guard and the SINGLE trailing cap are reached from every arm. Capping inside
    -- each arm would make the cap three edits to break instead of one.
    if hazard >= 1 then
        -- DECLARED rather than inferred, and behaviourally inert - at a hazard of 1
        -- both solve arms compute `x / inf = 0` anyway.
        raw = 0
    elseif not (hazard > 0) then
        raw = span or math.huge
    else
        local rate = -math.log(1 - hazard)

        if not (rate > 0) then
            -- The underflow arm, and it sits ABOVE both divisions on purpose:
            -- `-log(1 - h)` is exactly 0 for any h at or below about 5.55e-17, which
            -- the parser's probability read accepts.
            raw = span or math.huge
        elseif span == nil then
            raw = 1 / rate
        else
            raw = (1 - (1 - hazard) ^ span) / rate
        end
    end

    -- The NaN filter, and it must precede the fold: a NaN span parses today, and
    -- `math.min` would launder a NaN window into a plausible finite lifespan.
    if not (raw > 0) then
        Log:trace("RLDiseaseTransmission.expectedSheddingMonths: endpoint=%s hazard=%s "
            .. "span=%s raw=%s -> 0 (non-positive or NaN window)",
            tostring(endpoint), tostring(hazard), tostring(span), tostring(raw))

        return 0
    end

    local capped = math.min(raw, maxLifespanMonths or math.huge)

    Log:trace("RLDiseaseTransmission.expectedSheddingMonths: endpoint=%s hazard=%s "
        .. "span=%s raw=%s cap=%s -> %s",
        tostring(endpoint), tostring(hazard), tostring(span), tostring(raw),
        tostring(maxLifespanMonths), tostring(capped))

    return capped
end


--- The per-MONTH transmission rate that realises the authored R0 at this tick size.
---
--- Adds the hidden window to the symptomatic one, converting it at the tick size,
--- because incubation is counted in TICKS and not months.
--- @param model table|nil A parsed model entry. TRUSTED INTERNAL input; a nil or
---        non-table returns `0, 0`. Its own guard, not a borrowed one: the window
---        function returning 0 for a non-table still leaves `months` positive for
---        any nonzero incubation.
--- @param maxLifespanMonths number|nil The DISEASE-level shedding bound.
--- @param incubationTicks number The EFFECTIVE tick count an animal serves - the
---        authored value after the difficulty scale and the record module's floor,
---        composed by the caller. TRUSTED INTERNAL input; a nil RAISES.
--- @param daysPerPeriod number Ticks in one period. TRUSTED INTERNAL input - a nil
---        RAISES on the guard below. Read it at call time; never cache it.
--- @return number beta The per-month rate, 0 on every refusal
--- @return number contagiousMonths The window it divided by; 0 where a guard
---         refused before the window was formed
function RLDiseaseTransmission.betaMonthly(model, maxLifespanMonths, incubationTicks, daysPerPeriod)
    if type(model) ~= "table" then return 0, 0 end

    -- NOT the 1..28 range bound, which no slice owns: this refuses exactly the one
    -- value that would make the division below form an `x/0`.
    if not (daysPerPeriod > 0) then return 0, 0 end

    local months = incubationTicks / daysPerPeriod
        + RLDiseaseTransmission.expectedSheddingMonths(model, maxLifespanMonths)

    if not (months > 0) or months == math.huge then
        Log:trace("RLDiseaseTransmission.betaMonthly: endpoint=%s months=%s -> beta 0 "
            .. "(a zero or infinite window realises no R0)",
            tostring(model.endpoint), tostring(months))

        return 0, months
    end

    local beta = model.r0 / months

    Log:trace("RLDiseaseTransmission.betaMonthly: endpoint=%s ticks=%s dpp=%s months=%s "
        .. "-> beta=%s",
        tostring(model.endpoint), tostring(incubationTicks), tostring(daysPerPeriod),
        tostring(months), tostring(beta))

    return beta, months
end


--- The per-tick probability one susceptible animal rolls against one disease.
---
--- Scales the MONTHLY rate by the pen's prevalence, rejects a zero, negative or NaN
--- product, clamps the rest to 1, and converts LAST.
--- @param model table|nil A parsed model entry. TRUSTED INTERNAL input.
--- @param maxLifespanMonths number|nil The DISEASE-level shedding bound.
--- @param incubationTicks number The EFFECTIVE tick count. TRUSTED INTERNAL input.
--- @param prevalence number The shedding share of the pen. TRUSTED INTERNAL input -
---        a nil RAISES on the multiply. A value above 1 is NOT clamped: the fold
---        below clamps the PRODUCT, so an out-of-domain prevalence passes through
---        untouched whenever `beta * prevalence` stays at or below 1.
--- @param daysPerPeriod number Ticks in one period. TRUSTED INTERNAL input.
--- @return number pTick The per-tick probability, 0 on every refusal
--- @return number monthly The CLAMPED monthly rate actually converted - not beta.
---         That is what lets a caller assert the round trip without writing a
---         second copy of the clamp.
function RLDiseaseTransmission.perTickRate(model, maxLifespanMonths, incubationTicks, prevalence, daysPerPeriod)
    local beta = RLDiseaseTransmission.betaMonthly(model, maxLifespanMonths,
        incubationTicks, daysPerPeriod)

    -- The multiply is FIRST, so a nil prevalence raises here rather than reaching the
    -- conversion. Still a per-MONTH quantity at this point.
    local monthly = beta * prevalence

    -- ONE inverted comparison rejecting zero, a negative product AND a NaN. Read it as
    -- "non-positive or NaN", never "non-finite": an infinite product passes and the
    -- fold takes it to 1, the correct reading of an infinite force of infection.
    if not (monthly > 0) then
        Log:trace("RLDiseaseTransmission.perTickRate: prevalence=%s monthly=%s -> 0 "
            .. "(non-positive or NaN force of infection)",
            tostring(prevalence), tostring(monthly))

        return 0, 0
    end

    -- The fold's argument order is INERT, because the guard above has already excluded
    -- every NaN. It is a clamp and nothing else.
    local clamped = math.min(monthly, 1)
    local pTick = RLDiseaseRates.perTick(clamped, daysPerPeriod)

    Log:trace("RLDiseaseTransmission.perTickRate: prevalence=%s monthly=%s clampBit=%s "
        .. "dpp=%s -> pTick=%s",
        tostring(prevalence), tostring(monthly), tostring(clamped ~= monthly),
        tostring(daysPerPeriod), tostring(pTick))

    return pTick, clamped
end


Log:info("RLDiseaseTransmission loaded")
