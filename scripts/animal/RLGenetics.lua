--[[
    RLGenetics.lua
    The one home for genetics banding: the two tier ladders, the single-value
    domain predicate, the guarded domain entries on top of them, and the
    whole-table layer - the validity verdict and the aggregate.

    Engine-free apart from RmLogging and RLConstants, so it dual-runs headless.
    Not side-effect-free: five rejection counters with latest-offender snapshots,
    a one-shot statKeys latch and warning output are its mutable state, and a map
    load resets them.

    Each KEYS array holds full localisation keys and is exactly one longer than
    its thresholds array; the extra key is the fall-through band.
]]

RLGenetics = {}

local Log = RmLogging.getLogger("RLRM")


RLGenetics.MIN = RLConstants.GENETICS_MIN
RLGenetics.MAX = RLConstants.GENETICS_MAX

-- The one value outside [MIN, MAX] that is legitimate rather than corrupt, and
-- only for fertility: a castrated male, a freemartin heifer or an animal bred
-- sterile stores exactly 0.
RLGenetics.INFERTILE_VALUE = 0


-- Ordered highest-first, so a scan stops at the first rung the value meets.
-- READ-ONLY by contract: RLGeneticsFormatter re-exports these very tables, same
-- objects and no copy, so mutating one mutates every consumer.
RLGenetics.PER_TRAIT_THRESHOLDS = { 1.65, 1.4, 1.1, 0.9, 0.7, 0.35 }

RLGenetics.PER_TRAIT_KEYS = {
    "rl_ui_genetics_extremelyHigh",
    "rl_ui_genetics_veryHigh",
    "rl_ui_genetics_high",
    "rl_ui_genetics_average",
    "rl_ui_genetics_low",
    "rl_ui_genetics_veryLow",
    "rl_ui_genetics_extremelyLow",
}

-- Aggregate ladder for the Overall row. Its input is a normalised FACTOR, not a
-- trait value, so the two ladders are never interchangeable. Read-only likewise.
RLGenetics.OVERALL_THRESHOLDS = { 0.95, 0.8, 0.6, 0.4, 0.2, 0.05 }

RLGenetics.OVERALL_KEYS = {
    "rl_ui_genetics_extremelyGood",
    "rl_ui_genetics_veryGood",
    "rl_ui_genetics_good",
    "rl_ui_genetics_average",
    "rl_ui_genetics_bad",
    "rl_ui_genetics_veryBad",
    "rl_ui_genetics_extremelyBad",
}

-- Fertility's extra band, outside both ladders.
RLGenetics.INFERTILE_KEY = "rl_ui_genetics_infertile"


-- The stat set a whole-table walk covers, in CANONICAL order. That order is
-- contract: the walk follows it rather than the caller's array order, which is
-- what makes `badKey` a property of the DATA and keeps a reordered subset
-- summing bit-for-bit identically. Read-only likewise.
RLGenetics.DEFAULT_STAT_KEYS = { "metabolism", "quality", "health", "fertility", "productivity" }

-- Stats whose ABSENCE is normal rather than a partial load, so they drop out of
-- the denominator when the key is missing.
RLGenetics.OPTIONAL_STATS = { productivity = true }


local LOWEST_PER_TRAIT = RLGenetics.PER_TRAIT_KEYS[#RLGenetics.PER_TRAIT_KEYS]
local LOWEST_OVERALL   = RLGenetics.OVERALL_KEYS[#RLGenetics.OVERALL_KEYS]

-- A table READ against this set is raise-safe for every key type including NaN,
-- which is what lets the resolver reject a malformed entry BEFORE it would have
-- to write one.
local DEFAULT_MEMBER = {}
for _, key in ipairs(RLGenetics.DEFAULT_STAT_KEYS) do DEFAULT_MEMBER[key] = true end


-- One counter per DATA-rejection cause. Banding runs several times per rendered
-- row, so each cause reports its first occurrence and then power-of-ten
-- milestones. Counting is per CAUSE, never per context or per animal - those key
-- spaces are unbounded - and the two aggregate causes count separately so a
-- malformed container cannot absorb the first report of a corrupt trait table.
local warnCounts = {
    perTrait = 0,
    fertility = 0,
    overall = 0,
    container = 0,
    member = 0,
}
local warnLatestValueText = {}
local warnLatestContext = {}

-- One-shot rather than counted: `aggregate` resolves statKeys twice per call, so
-- a counter would book two occurrences for one mistake.
local warnedStatKeys = false


local EXPECTED_PER_TRAIT = string.format("a trait value in [%s, %s], or exactly %s (infertile)",
    tostring(RLGenetics.MIN), tostring(RLGenetics.MAX), tostring(RLGenetics.INFERTILE_VALUE))
local EXPECTED_FERTILITY = EXPECTED_PER_TRAIT
local EXPECTED_OVERALL = "a finite number (an aggregate factor is open-ended, NOT clamped to the trait domain)"
local EXPECTED_CONTAINER = "a genetics table"

-- A FORMAT string, not a finished one: the `%%s` survives this outer
-- `string.format` and is filled with the offending stat name at the warn site.
local EXPECTED_MEMBER = string.format(
    "stat '%%s' to be absent, or a value in [%s, %s], or exactly %s for fertility",
    tostring(RLGenetics.MIN), tostring(RLGenetics.MAX), tostring(RLGenetics.INFERTILE_VALUE))

local EXPECTED_STAT_KEYS = "a dense array of distinct DEFAULT_STAT_KEYS members"


--- Report the first occurrence of a cause and then every power-of-ten milestone.
--- @param count number Occurrence number for one cause, starting at 1
--- @return boolean emits True when this occurrence must be reported
--- @return number nextReport The next occurrence number that will be reported
function RLGenetics.isReportedOccurrence(count)
    local rung = 1
    while rung < count do rung = rung * 10 end

    if rung == count then return true, rung * 10 end

    return false, rung
end


--- Compose the first-occurrence rejection line for a cause.
---
--- Every slot renders via `%s` + `tostring`, never `%d`/`%f`: the headless
--- harness calls `string.format` bare where the in-game logger pcalls it, so a
--- numeric verb on a non-numeric value would raise headless only.
--- @param entry string Name of the entry, for the log line
--- @param value any The rejected value
--- @param fallback any What is returned instead - a band key, or a phrase
--- @param expectation string What this entry accepts, phrased for this entry
--- @param verb string|nil How the fallback is delivered; defaults to "banding as"
--- @param context any|nil Caller context; omitted from the line when nil
--- @param nextReport number|nil Next reported occurrence; NIL for a latched cause,
---        whose tail states the latch instead of promising a next report
--- @return string line
function RLGenetics.buildRejectionLine(entry, value, fallback, expectation, verb, context, nextReport)
    local contextSegment = ""
    if context ~= nil then
        contextSegment = string.format(" Context: %s.", tostring(context))
    end

    local tail = "Further occurrences of this kind are silent until the next map load."
    if nextReport ~= nil then
        tail = string.format("Next report at %s.", tostring(nextReport))
    end

    return string.format("RLGenetics.%s: rejected value %s (type %s) - %s %s. Expected %s.%s %s",
        entry, tostring(value), type(value), verb or "banding as", tostring(fallback),
        expectation, contextSegment, tail)
end


--- Compose a milestone rollup line, naming the cause's total and latest offender.
--- @param entry string Name of the entry, for the log line
--- @param count number Total occurrences since the counters reset
--- @param latestValueText string The latest rejected value, already stringified
--- @param latestContext string|nil Latest context snapshot; omitted when nil
--- @param nextReport number The next occurrence number that will be reported
--- @return string line
function RLGenetics.buildRollupLine(entry, count, latestValueText, latestContext, nextReport)
    local contextSegment = ""
    if latestContext ~= nil then
        contextSegment = string.format(", context %s", tostring(latestContext))
    end

    return string.format(
        "RLGenetics.%s: %s rejections of this kind since map load; latest: value %s%s. Next report at %s.",
        entry, tostring(count), tostring(latestValueText), contextSegment, tostring(nextReport))
end


--- Count one rejection for a cause and report it when the milestone says so.
---
--- Snapshots are taken before the milestone check and overwritten on every
--- occurrence, nil context included, so a rollup names the newest offender.
--- @param cause string Key into the counter tables; an unknown key RAISES at the
---        increment, deliberately - that is a coding bug in this module
--- @param entry string Name of the entry, for the log line
--- @param value any The rejected value
--- @param fallback any What is being returned instead
--- @param expectation string What this entry accepts, phrased for this entry
--- @param verb string|nil How the fallback is being delivered
--- @param context any|nil Caller-supplied diagnostic context
local function warnRejected(cause, entry, value, fallback, expectation, verb, context)
    local count = warnCounts[cause] + 1
    warnCounts[cause] = count
    warnLatestValueText[cause] = tostring(value)

    if context ~= nil then
        warnLatestContext[cause] = tostring(context)
    else
        warnLatestContext[cause] = nil
    end

    local emits, nextReport = RLGenetics.isReportedOccurrence(count)
    if not emits then return end

    local line
    if count == 1 then
        line = RLGenetics.buildRejectionLine(entry, value, fallback, expectation, verb, context, nextReport)
    else
        line = RLGenetics.buildRollupLine(entry, count,
            warnLatestValueText[cause], warnLatestContext[cause], nextReport)
    end

    Log:warning("%s", line)
end


--- Is this a value a well-formed save can hold for a genetics trait?
---
--- The `type` test is mandatory AND first - `"x" >= 0.25` raises - and with the
--- range test it already rejects NaN and both infinities.
--- @param value any The value to check; `nil` counts as valid, because an absent
---        trait is a normal load path rather than corruption
--- @param traitKey string|nil `nil` means the trait-agnostic UNION, which admits
---        the infertile 0; only `"fertility"` or `nil` unlock it
--- @return boolean isValid
function RLGenetics.isValidTraitValue(value, traitKey)
    if value == nil then return true end
    if type(value) ~= "number" then return false end

    if value >= RLGenetics.MIN and value <= RLGenetics.MAX then return true end

    -- `-0.0 == 0` in Lua, so a negative zero passes here too.
    return value == RLGenetics.INFERTILE_VALUE
        and (traitKey == nil or traitKey == "fertility")
end


--- Pick a band key by scanning a threshold ladder highest-first.
---
--- The raw primitive: unguarded, and it RAISES on a nil or non-number value
--- rather than inventing a band. Use it directly only for a value that is not a
--- genetics trait; genetics callers want the domain entries below.
--- @param value number Compared with `>=`, so a value on a rung takes that rung
--- @param thresholds table Rungs, highest first. TRUSTED INTERNAL input
--- @param keys table Band keys, same order, exactly one longer than `thresholds`
--- @return string|nil key The last key when the value is below every rung, or nil
---         when `keys` cannot supply one
function RLGenetics.resolve(value, thresholds, keys)
    for i, threshold in ipairs(thresholds) do
        if value >= threshold then return keys[i] end
    end

    return keys[#keys]
end


--- Band any single genetics trait value against the per-trait ladder.
---
--- Trait-AGNOSTIC by signature, so it validates against the UNION and accepts the
--- infertile 0 silently; tightening it to [MIN, MAX] would warn on every
--- castrated male, because generic loops feed it `animal.genetics` wholesale. Two
--- consequences are contract: an absent trait bands lowest silently, and
--- fertility 0 bands lowest here while `fertility` bands it infertile.
--- @param value number|nil Trait value; `nil` is treated as absent
--- @param context any|nil DIAGNOSTIC-ONLY caller context for the rejection
---        warning: never branches behaviour, ignored on the silent absent path.
---        Grammar "<trait> of <farmId> <uniqueId> <country>", composed by the
---        caller; ids only, never player-entered text, and nil rather than ""
--- @return string key Never nil, never raises
function RLGenetics.perTrait(value, context)
    -- Absent short-circuits before the allowlist and before resolve, which would
    -- raise on nil.
    if value == nil then return LOWEST_PER_TRAIT end

    if not RLGenetics.isValidTraitValue(value, nil) then
        warnRejected("perTrait", "perTrait", value, LOWEST_PER_TRAIT, EXPECTED_PER_TRAIT, nil, context)

        return LOWEST_PER_TRAIT
    end

    return RLGenetics.resolve(value, RLGenetics.PER_TRAIT_THRESHOLDS, RLGenetics.PER_TRAIT_KEYS)
end


--- Band a fertility value, honouring the infertile band at exactly 0.
---
--- Guard order is contract: `nil` yields the lowest band and NOT infertile, so an
--- animal with no fertility recorded is not reported sterile, and validation runs
--- before the exactly-0 test, so a negative value is rejected rather than read as
--- sterile. This entry is the one owner of the infertile band.
--- @param value number|nil Fertility value; `nil` is treated as absent
--- @param context any|nil Diagnostic-only caller context; see RLGenetics.perTrait
--- @return string key Never nil, never raises
function RLGenetics.fertility(value, context)
    if value == nil then return LOWEST_PER_TRAIT end

    if not RLGenetics.isValidTraitValue(value, "fertility") then
        warnRejected("fertility", "fertility", value, LOWEST_PER_TRAIT, EXPECTED_FERTILITY, nil, context)

        return LOWEST_PER_TRAIT
    end

    if value == RLGenetics.INFERTILE_VALUE then return RLGenetics.INFERTILE_KEY end

    return RLGenetics.resolve(value, RLGenetics.PER_TRAIT_THRESHOLDS, RLGenetics.PER_TRAIT_KEYS)
end


--- Band an aggregate genetics FACTOR against the overall ladder.
---
--- A factor is not a trait value - 0.19 is a legal factor and an invalid trait -
--- so the guard is finite-number-only and banding never clamps. Unlike an absent
--- trait, an absent factor is a caller bug, so `nil` warns here.
--- @param factor number|nil Aggregate factor, typically `sum / (MAX * statCount)`
--- @param context any|nil Diagnostic-only caller context; see RLGenetics.perTrait
--- @return string key Never nil, never raises
function RLGenetics.overall(factor, context)
    -- `factor ~= factor` is the NaN test; both infinities need their own, because
    -- they compare normally against the rungs.
    if type(factor) ~= "number"
        or factor ~= factor
        or factor == math.huge
        or factor == -math.huge then

        warnRejected("overall", "overall", factor, LOWEST_OVERALL, EXPECTED_OVERALL, nil, context)

        return LOWEST_OVERALL
    end

    return RLGenetics.resolve(factor, RLGenetics.OVERALL_THRESHOLDS, RLGenetics.OVERALL_KEYS)
end


-- =========================================================================
-- The whole-table layer: one stat-set resolver, one validity verdict, one
-- aggregate.
-- =========================================================================

--- Count every entry in a table, array part and map part alike.
---
--- `#` and `ipairs` both stop at the first hole and so AGREE on
--- `{"metabolism", nil, "health"}`; only a `pairs` count detects that shape.
--- @param t table
--- @return number count
local function pairsCount(t)
    local count = 0
    for _ in pairs(t) do count = count + 1 end
    return count
end


--- Emit the shared, latched `statKeys` fallback warning.
---
--- Context-free by design: it reports a call-site coding bug, not animal data.
--- @param statKeys any The rejected argument
--- @param rule string Which rule it broke, for the log line
local function warnStatKeys(statKeys, rule)
    if warnedStatKeys then return end

    warnedStatKeys = true

    local line = RLGenetics.buildRejectionLine("resolveStatKeys", statKeys,
        "the default stat set", EXPECTED_STAT_KEYS .. " - this one " .. rule,
        "falling back to", nil, nil)
    Log:warning("%s", line)
end


--- Build a fresh, canonically ordered stat array - always a copy, since
--- `DEFAULT_STAT_KEYS` is read-only and is never handed out.
--- @param seen table|nil Membership set to filter by; `nil` means every member
--- @return table keys Canonically ordered
local function canonicalCopy(seen)
    local keys = {}

    for _, key in ipairs(RLGenetics.DEFAULT_STAT_KEYS) do
        if seen == nil or seen[key] then keys[#keys + 1] = key end
    end

    return keys
end


--- Resolve a caller's `statKeys` argument to a canonical stat set.
---
--- The order of the checks is contract: membership is tested before any
--- `seen[key]` write, because `DEFAULT_MEMBER[0/0]` is a table read and is fine
--- while `seen[0/0] = true` raises "table index is NaN".
--- @param statKeys table|nil Caller's stat array, or nil for the default set
--- @return table keys A fresh canonically ordered array. Never raises
local function resolveStatKeys(statKeys)
    -- Not a malformation: the overwhelmingly common call passes nothing.
    if statKeys == nil then return canonicalCopy(nil) end

    if type(statKeys) ~= "table" then
        warnStatKeys(statKeys, "is not a table")
        return canonicalCopy(nil)
    end

    local seen, walked = {}, 0

    -- `ipairs`, so a hole ends the walk rather than raising. The index goes into
    -- the warning because `tostring(statKeys)` is a per-run table address.
    for i, key in ipairs(statKeys) do
        if DEFAULT_MEMBER[key] == nil then
            warnStatKeys(statKeys, string.format(
                "carries an entry that is not a DEFAULT_STAT_KEYS member (index %s: %s)",
                tostring(i), tostring(key)))
            return canonicalCopy(nil)
        end

        if seen[key] then
            warnStatKeys(statKeys, string.format("repeats an entry (index %s: %s)",
                tostring(i), tostring(key)))
            return canonicalCopy(nil)
        end

        seen[key] = true
        walked = walked + 1
    end

    if walked == 0 then
        warnStatKeys(statKeys, "is empty, or begins with a hole")
        return canonicalCopy(nil)
    end

    if pairsCount(statKeys) ~= walked then
        warnStatKeys(statKeys, "has a hole or a map-style entry")
        return canonicalCopy(nil)
    end

    return canonicalCopy(seen)
end


--- Is every stat in the resolved set readable?
---
--- An ALLOWLIST evaluated per NAMED trait key, so `0` passes for `fertility` and
--- fails everywhere else. Silent about `genetics` by contract: it returns a
--- verdict and leaves reporting to whoever acts on it.
--- @param genetics any The genetics table. A non-table is a verdict, not a raise
--- @param statKeys table|nil Stat set to check; defaults to DEFAULT_STAT_KEYS
--- @return boolean ok
--- @return string|nil badKey First offending key in canonical order; NIL while
---         `ok` is false means the CONTAINER itself was unusable
--- @return any badValue The offending value, or the container argument
function RLGenetics.validateGenetics(genetics, statKeys)
    -- Load-bearing, not defensive habit: `(7).metabolism`, `(true).metabolism`
    -- and `(nil).metabolism` all raise in LuaJIT, while `("x").metabolism` does
    -- not.
    if type(genetics) ~= "table" then return false, nil, genetics end

    for _, key in ipairs(resolveStatKeys(statKeys)) do
        local value = genetics[key]

        if not RLGenetics.isValidTraitValue(value, key) then
            return false, key, value
        end
    end

    return true, nil, nil
end


--- Aggregate a genetics table into both dialects at once.
---
--- POISON, NOT SKIP: one invalid member discards the whole aggregate, so a
--- plausible average built from the survivors cannot hide the corruption. The
--- denominator and `presentCount` differ only over ABSENT stats - an absent stat
--- still divides unless it is optional, so a missing `metabolism` counts against
--- the animal while a missing `productivity` narrows the set.
--- @param genetics any The genetics table. A non-table returns the zero triple
--- @param statKeys table|nil Stat set to walk; defaults to DEFAULT_STAT_KEYS
--- @param context any|nil Diagnostic-only caller context; see RLGenetics.perTrait.
---        POSITION TRAP: context is argument THREE - `aggregate(g, ctx)` lands ctx
---        in `statKeys` and spends the one-shot latch on it
--- @return number factor `sum / (MAX * denominator)`, or 0
--- @return number mean `sum / denominator`, or 0
--- @return number presentCount How many stats OF THE RESOLVED SET held a value
function RLGenetics.aggregate(genetics, statKeys, context)
    if type(genetics) ~= "table" then
        warnRejected("container", "aggregate", genetics, "0, 0, 0", EXPECTED_CONTAINER,
            "returning", context)

        return 0, 0, 0
    end

    local keys = resolveStatKeys(statKeys)

    -- Calls the public helper rather than inlining the check, so the poison
    -- behaviour is definitionally whatever validateGenetics says. The accepted
    -- cost is a second resolveStatKeys pass.
    local ok, badKey, badValue = RLGenetics.validateGenetics(genetics, statKeys)

    if not ok then
        warnRejected("member", "aggregate", badValue, "0, 0, 0",
            string.format(EXPECTED_MEMBER, tostring(badKey)), "returning", context)

        return 0, 0, 0
    end

    local sum, denominator, presentCount = 0, 0, 0

    for _, key in ipairs(keys) do
        local value = genetics[key]

        -- Presence is `~= nil`, never truthiness: `false` is present and would
        -- already have poisoned above.
        if value ~= nil then
            sum = sum + value
            presentCount = presentCount + 1
            denominator = denominator + 1
        elseif not RLGenetics.OPTIONAL_STATS[key] then
            denominator = denominator + 1
        end
    end

    -- Branches on the DENOMINATOR: `aggregate({})` has denominator 4 and
    -- legitimately divides to 0.
    if denominator == 0 then return 0, 0, 0 end

    -- Each dialect gets its own expression against the shared sum. Never derive
    -- one from the other: float addition is not associative, so that moves the
    -- result by an ulp, which is invisible except at an exact rung.
    return sum / (RLGenetics.MAX * denominator), sum / denominator, presentCount
end


--- Reset every rejection counter, both snapshot tables, and the statKeys latch.
---
--- TEST SEAM. Production never calls it - the counters are meant to survive a
--- session and are reset by the per-map-load re-source.
--- @return nil
function RLGenetics._resetWarnLatches()
    for cause in pairs(warnCounts) do
        warnCounts[cause] = 0
        warnLatestValueText[cause] = nil
        warnLatestContext[cause] = nil
    end

    warnedStatKeys = false
end


Log:info("RLGenetics loaded")
