--[[
    RLGenetics.lua
    The one home for genetics BANDING: the two tier ladders, the single-value
    domain predicate, the guarded domain entries that sit on top of them, and
    the whole-table layer - the validity verdict and the aggregate.

    Engine-free and deterministic in what it returns: no g_* access, no GUI, no
    XML, no engine natives. RmLogging and RLConstants at file scope are the only
    couplings, so the module dual-runs headless.

    It is NOT side-effect-free, and calling it "pure" without that qualifier is
    wrong: six module-scope warn latches are its mutable state, and the failure
    paths log.

    Three layers, deliberately separated:

      resolve()   the raw ladder primitive - any number against any ladder, no
                  domain opinion, and it RAISES on a nil or non-number value. A
                  caller whose value is not a genetics trait uses this directly.

      perTrait() / fertility() / overall()
                  the SINGLE-VALUE domain entries. Each guards its input, NEVER
                  raises, and falls back to its ladder's lowest band with one
                  latched warning.

      validateGenetics() / aggregate()
                  the WHOLE-TABLE entries. Both take a genetics table plus an
                  optional stat set, never raise on any argument of any type,
                  and share one canonical walk order.

    KEYS arrays hold FULL localisation keys, and there is always exactly one
    more key than there are thresholds - the extra key is the fall-through band
    for values below the last rung.
]]

RLGenetics = {}

local Log = RmLogging.getLogger("RLRM")


-- Genetics domain, read from the mod's one constants home rather than restated
-- as literals here, so this module follows a bounds change instead of silently
-- disagreeing with RLGeneticsDraw and RLDealerQualityModel.
RLGenetics.MIN = RLConstants.GENETICS_MIN
RLGenetics.MAX = RLConstants.GENETICS_MAX

-- The one value outside [MIN, MAX] that is legitimate rather than corrupt, and
-- only for fertility: a castrated male, a freemartin heifer or an animal bred
-- sterile stores exactly 0. Every other trait treats 0 as corrupt.
RLGenetics.INFERTILE_VALUE = 0


-- Per-trait ladder: metabolism, health, fertility, meat quality, productivity.
-- Ordered highest-first, so a linear scan stops at the first rung the value
-- meets.
--
-- READ-ONLY by contract. RLGeneticsFormatter re-exports these very tables (same
-- objects, no copy), so mutating one mutates every consumer. There is
-- deliberately no defensive copy and no metatable freeze - both sit on the row-
-- render path, and the contract is upheld by review.
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

-- Aggregate ladder for the Overall row. Same shape, different vocabulary
-- (good/bad rather than high/low) and a different scale: its input is a
-- normalised FACTOR, not a trait value, so the two ladders are never
-- interchangeable.
--
-- READ-ONLY by contract - see PER_TRAIT_THRESHOLDS.
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
-- itself contract: the walk always follows it (filtered to the resolved set),
-- never the caller's array order, which is what makes `badKey` a property of
-- the DATA rather than of the call site and keeps a reordered subset summing
-- bit-for-bit identically.
--
-- A fourth named trait array, deliberately NOT reused from RLGeneticsDraw: the
-- draw arrays say what to GENERATE and split productivity by animal type, while
-- this says what to AGGREGATE and marks productivity optional per member.
-- Reusing them would also give this module a file-scope dependency it excludes
-- on purpose.
--
-- READ-ONLY by contract - see PER_TRAIT_THRESHOLDS.
RLGenetics.DEFAULT_STAT_KEYS = { "metabolism", "quality", "health", "fertility", "productivity" }

-- Stats whose ABSENCE is normal rather than a partial load, so they drop out of
-- the denominator when the key is missing. Optionality is inferred from key
-- presence, not animal type - the whole-table entries receive no
-- animalTypeIndex, and `statKeys` is the escape hatch for a caller that knows
-- the species.
--
-- READ-ONLY by contract - see PER_TRAIT_THRESHOLDS.
RLGenetics.OPTIONAL_STATS = { productivity = true }


-- The fall-through band of each ladder, resolved once. Both domain entries use
-- their ladder's lowest key as the guarded fallback, so a corrupt value reads
-- as the worst band rather than as a plausible middling one.
local LOWEST_PER_TRAIT = RLGenetics.PER_TRAIT_KEYS[#RLGenetics.PER_TRAIT_KEYS]
local LOWEST_OVERALL   = RLGenetics.OVERALL_KEYS[#RLGenetics.OVERALL_KEYS]

-- Membership set over DEFAULT_STAT_KEYS, built once. A table READ against it is
-- raise-safe for every key type including NaN, which is what lets the resolver
-- reject a malformed entry BEFORE it would have to write one.
local DEFAULT_MEMBER = {}
for _, key in ipairs(RLGenetics.DEFAULT_STAT_KEYS) do DEFAULT_MEMBER[key] = true end


-- One latch per reporting cause: the first offender each cause meets is
-- reported, the rest are silent. Banding runs several times per rendered row,
-- so an unlatched warning would flood the log from a single bad animal.
--
-- The two aggregate causes latch SEPARATELY on purpose. A single shared latch
-- would let one `aggregate(nil)` at map load - reachable through
-- `Animal:setGenetics`, which validates nothing - silence every genuinely
-- corrupt trait table for the rest of the session, which is the exact failure
-- this layer exists to surface.
--
-- Module scope, NOT an `RLGenetics = RLGenetics or {}` idiom: main.lua re-sources
-- per map load, so these reset when a save is loaded. Accepted cost - on a
-- long-running dedicated server only the first offender per cause is reported.
local warnedPerTrait = false
local warnedFertility = false
local warnedOverall = false
local warnedStatKeys = false
local warnedContainer = false
local warnedMember = false


-- What each entry actually accepts, in the entry's own terms. These are NOT
-- interchangeable: `overall` bands a normalised FACTOR and deliberately does
-- not apply the trait domain, so quoting [MIN, MAX] in its warning would send a
-- maintainer to the wrong rule for a legal factor like 0.19.
local EXPECTED_PER_TRAIT = string.format("a trait value in [%s, %s], or exactly %s (infertile)",
    tostring(RLGenetics.MIN), tostring(RLGenetics.MAX), tostring(RLGenetics.INFERTILE_VALUE))
local EXPECTED_FERTILITY = EXPECTED_PER_TRAIT
local EXPECTED_OVERALL = "a finite number (an aggregate factor is open-ended, NOT clamped to the trait domain)"
local EXPECTED_CONTAINER = "a genetics table"

-- A FORMAT string, not a finished one: the `%%s` survives this outer
-- `string.format` and is filled with the offending stat name at the warn site.
-- The key belongs in the expectation rather than in the entry name, because the
-- latch is per CAUSE and not per key - naming the entry `aggregate[quality]`
-- would tell a maintainer that only `quality` was suppressed, when in fact the
-- first corrupt member of ANY stat silences every later one.
local EXPECTED_MEMBER = string.format(
    "stat '%%s' to be absent, or a value in [%s, %s], or exactly %s for fertility",
    tostring(RLGenetics.MIN), tostring(RLGenetics.MAX), tostring(RLGenetics.INFERTILE_VALUE))

local EXPECTED_STAT_KEYS = "a dense array of distinct DEFAULT_STAT_KEYS members"


--- Emit one latched warning describing a rejected value.
---
--- Formats with `%s` + `tostring` throughout, never `%d`/`%f`: the offending
--- value can be a string, a boolean or a table, and the headless harness calls
--- `string.format` BARE (the in-game logger pcalls it), so a numeric verb would
--- raise headless only - breaking dual-run parity and the never-raises contract
--- at the same time.
---
--- The tail says "of this kind" rather than "from this entry" because each latch
--- covers one CAUSE, and causes do not map one-to-one onto entries: `aggregate`
--- owns two (malformed container, malformed member), and the `statKeys` fallback
--- latch is shared across both public entries.
--- @param entry string Name of the entry, for the log line
--- @param value any The rejected value
--- @param fallback any What is being returned instead - a band key for the
---        single-value entries, a phrase for the whole-table ones
--- @param expectation string What this entry accepts, phrased for this entry
--- @param verb string|nil How the fallback is being delivered. Defaults to
---        "banding as", which is what every single-value entry means; the
---        whole-table entries return a triple rather than a band, so they pass
---        their own verb rather than describing a band that does not exist
local function warnRejected(entry, value, fallback, expectation, verb)
    Log:warning(
        "RLGenetics.%s: rejected value %s (type %s) - %s %s. Expected %s. Further occurrences of this kind are silent until the next map load.",
        entry, tostring(value), type(value), verb or "banding as", tostring(fallback), expectation)
end


--- Is this a value a well-formed save can hold for a genetics trait?
---
--- The allowlist needs no special cases: one `type` test plus one range test
--- already rejects NaN (every comparison against it is false), both infinities,
--- and every out-of-range finite number. The `type` test is mandatory AND first
--- - `"x" >= 0.25` raises.
---
--- `nil` is VALID: an absent trait is a normal load path, not corruption (a pig
--- carries no productivity). Callers that need "absent" and "present" to differ
--- must test for nil themselves.
---
--- @param value any The value to check; `nil` counts as valid (absent)
--- @param traitKey string|nil Trait name. `nil` means the trait-agnostic UNION,
---        which admits the infertile 0 because the caller cannot tell a legal
---        infertile fertility from a corrupt quality. Only `"fertility"` or
---        `nil` unlock 0; any other key rejects it.
--- @return boolean isValid
function RLGenetics.isValidTraitValue(value, traitKey)
    if value == nil then return true end
    if type(value) ~= "number" then return false end

    if value >= RLGenetics.MIN and value <= RLGenetics.MAX then return true end

    -- The infertile carve-out is the only value admitted from outside the
    -- domain. `-0.0 == 0` in Lua, so a negative zero passes here too.
    return value == RLGenetics.INFERTILE_VALUE
        and (traitKey == nil or traitKey == "fertility")
end


--- Pick a band key by scanning a threshold ladder highest-first.
---
--- STRICT AND UNGUARDED, deliberately: this is the raw primitive, and it RAISES
--- on a nil or non-number value rather than inventing a band for it. The domain
--- entries below are what a genetics caller should reach for; use this directly
--- only for a value that is not a genetics trait.
---
--- @param value number Compared with `>=`, so a value sitting exactly on a rung
---        takes that rung's key
--- @param thresholds table Rungs, highest first. TRUSTED INTERNAL input - not
---        validated; a nil or non-table raises inside `ipairs`
--- @param keys table Band keys, same order, exactly one longer than
---        `thresholds`. A mismatched length silently collapses or skips a band
--- @return string|nil key The band key, or the last key when the value is below
---         every rung. NIL when `keys` cannot supply one - an empty list, or a
---         list too short for the matched rung - which flows on as a nil
---         localisation key rather than raising
function RLGenetics.resolve(value, thresholds, keys)
    for i, threshold in ipairs(thresholds) do
        if value >= threshold then return keys[i] end
    end

    return keys[#keys]
end


--- Band any single genetics trait value against the per-trait ladder.
---
--- Trait-AGNOSTIC by signature: it receives a bare number and cannot tell which
--- trait it belongs to, so it validates against the UNION and accepts the
--- infertile 0 silently. Do NOT tighten this to [MIN, MAX] - generic loops feed
--- it `animal.genetics` wholesale, so every castrated male and freemartin
--- heifer would warn on every render.
---
--- Two consequences are CONTRACT, decided rather than accidental:
---
---   * ABSENT bands as the lowest band, silently, indistinguishable from a
---     genuinely terrible trait. There is deliberately no nil or
---     not-applicable return for it: no production caller can feed an absent
---     trait (generic loops iterate `pairs`, so an absent key never reaches
---     the call, and the row formatter coalesces or omits before banding), and
---     a sentinel would break the never-nil guarantee for a case nobody
---     produces. A caller that needs absent and present to differ tests for
---     nil BEFORE calling - see `isValidTraitValue`.
---
---   * Fertility 0 bands as the lowest band HERE and as infertile via
---     `fertility` - which entry a surface calls is a preserved per-call-site
---     choice. Unifying that vocabulary across surfaces is a decision owned
---     outside this module; do not "fix" it here by teaching this entry a
---     trait key. A generic loop already holds the trait key and can branch
---     to `fertility` at the call site when that decision lands.
---
--- @param value number|nil Trait value; `nil` is treated as absent
--- @return string key Never nil, never raises
function RLGenetics.perTrait(value)
    -- Absent is normal, so it short-circuits BEFORE the allowlist and before
    -- resolve (which would raise on nil) - and it stays silent.
    if value == nil then return LOWEST_PER_TRAIT end

    if not RLGenetics.isValidTraitValue(value, nil) then
        if not warnedPerTrait then
            warnedPerTrait = true
            warnRejected("perTrait", value, LOWEST_PER_TRAIT, EXPECTED_PER_TRAIT)
        end

        return LOWEST_PER_TRAIT
    end

    return RLGenetics.resolve(value, RLGenetics.PER_TRAIT_THRESHOLDS, RLGenetics.PER_TRAIT_KEYS)
end


--- Band a fertility value, honouring the infertile band at exactly 0.
---
--- Guard order is the contract. `nil` short-circuits FIRST and yields the
--- lowest band, NOT infertile: coalescing to 0 before the exactly-0 test would
--- report every animal with no fertility recorded as sterile. Validation then
--- runs BEFORE the infertile test, so the allowlist stays symmetric with
--- `perTrait` and a negative value is rejected instead of being read as
--- sterile.
---
--- This entry is the ONE owner of the infertile BAND: `perTrait(0)` bands
--- lowest because it cannot know the value is fertility, so a surface that
--- wants "infertile" calls THIS entry. That split is contract, not accident -
--- see `perTrait`.
---
--- @param value number|nil Fertility value; `nil` is treated as absent
--- @return string key Never nil, never raises
function RLGenetics.fertility(value)
    if value == nil then return LOWEST_PER_TRAIT end

    if not RLGenetics.isValidTraitValue(value, "fertility") then
        if not warnedFertility then
            warnedFertility = true
            warnRejected("fertility", value, LOWEST_PER_TRAIT, EXPECTED_FERTILITY)
        end

        return LOWEST_PER_TRAIT
    end

    if value == RLGenetics.INFERTILE_VALUE then return RLGenetics.INFERTILE_KEY end

    return RLGenetics.resolve(value, RLGenetics.PER_TRAIT_THRESHOLDS, RLGenetics.PER_TRAIT_KEYS)
end


--- Band an aggregate genetics FACTOR against the overall ladder.
---
--- Takes a normalised factor, not a trait value, so it cannot reuse the trait
--- allowlist: 0.19 and 0.04 are perfectly legal factors and invalid trait
--- values, and a shared predicate would make the ladder's own just-below
--- fixtures self-trip. Its guard is therefore finite-number-only.
---
--- Banding is OPEN-ENDED and never clamps: a factor above 1 bands as the top
--- key and a negative factor as the bottom one, silently. Unlike an absent
--- trait, an absent FACTOR is a caller bug, so `nil` warns here.
---
--- @param factor number|nil Aggregate factor, typically `sum / (MAX * statCount)`
--- @return string key Never nil, never raises
function RLGenetics.overall(factor)
    -- `factor ~= factor` is the NaN test; the two explicit infinity tests are
    -- needed because both infinities compare normally against the rungs and
    -- would otherwise band as a real value.
    if type(factor) ~= "number"
        or factor ~= factor
        or factor == math.huge
        or factor == -math.huge then

        if not warnedOverall then
            warnedOverall = true
            warnRejected("overall", factor, LOWEST_OVERALL, EXPECTED_OVERALL)
        end

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
--- `#` and `ipairs` both stop at the first hole and therefore AGREE with each
--- other on `{"metabolism", nil, "health"}` (both say 1) - so only a `pairs`
--- count detects that shape. `pairs` is banned over a `genetics` table, whose
--- out-of-schema keys must be ignored; it is not banned over `statKeys`, which
--- is a caller argument being validated rather than data being read.
--- @param t table
--- @return number count
local function pairsCount(t)
    local count = 0
    for _ in pairs(t) do count = count + 1 end
    return count
end


--- Emit the shared, latched `statKeys` fallback warning.
---
--- One latch for both whole-table entries, so a single bad argument is reported
--- once even though `aggregate` resolves twice.
--- @param statKeys any The rejected argument
--- @param rule string Which rule it broke, for the log line
local function warnStatKeys(statKeys, rule)
    if warnedStatKeys then return end

    warnedStatKeys = true
    warnRejected("resolveStatKeys", statKeys, "the default stat set",
        EXPECTED_STAT_KEYS .. " - this one " .. rule, "falling back to")
end


--- Build a fresh, canonically ordered stat array.
---
--- Always a COPY: the module's own `DEFAULT_STAT_KEYS` is read-only by contract
--- and is never handed out, not even internally, so no later edit can turn a
--- walk into a mutation of the constant.
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
--- The ORDER of the checks is the contract, not just the rules themselves.
--- Membership is tested BEFORE any `seen[key]` write because `DEFAULT_MEMBER[0/0]`
--- is a table READ and is fine, while `seen[0/0] = true` RAISES "table index is
--- NaN". Verified in LuaJIT.
---
--- `nil` is the ORDINARY call and is silent; every genuine malformation falls
--- back to the full default set with one shared latched warning.
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

    -- `ipairs`, so a hole simply ends the walk rather than raising. The index is
    -- carried into the warning because `tostring(statKeys)` is a per-run table
    -- address - useless in a log - so the rule text is the only actionable part.
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
--- Validity is an ALLOWLIST evaluated per NAMED trait key, so `0` passes for
--- `fertility` and fails everywhere else. It is scoped to the RESOLVED stat set:
--- a corrupt member outside a narrowed set neither validates nor fails, and an
--- out-of-schema key is ignored for the same reason.
---
--- SILENT about `genetics` by contract - it returns a verdict and leaves the
--- reporting to whoever acts on it. Only the shared `statKeys` resolver may warn
--- from here.
---
--- @param genetics any The genetics table. A non-table is a verdict, not a raise
--- @param statKeys table|nil Stat set to check; defaults to DEFAULT_STAT_KEYS
--- @return boolean ok
--- @return string|nil badKey First offending key in canonical order. NIL when
---         `ok` is false means the CONTAINER itself was unusable
--- @return any badValue The offending value, or the container argument
function RLGenetics.validateGenetics(genetics, statKeys)
    -- FIRST statement, and load-bearing rather than defensive habit:
    -- `(7).metabolism`, `(true).metabolism` and `(nil).metabolism` all raise in
    -- LuaJIT, while `("x").metabolism` does not.
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
--- Returns the normalised `factor` the Overall ladder bands, the raw `mean` the
--- `[NN]` name tag scales, and how many stats were actually readable.
---
--- **Poison, not skip.** A single invalid member discards the whole aggregate -
--- one corrupt trait costs four good ones, deliberately, because a plausible
--- average built from the survivors hides the corruption instead of surfacing it.
---
--- **The denominator and `presentCount` are different counts, and the asymmetry
--- is entirely about ABSENT stats.** A present stat always joins both. An absent
--- stat joins the denominator only when it is NOT optional - so a missing
--- `metabolism` still divides (the animal is scored as having lost it), while a
--- missing `productivity` simply narrows the set (a pig never had one).
---
--- Stating it as "the KEY is present" would be vacuous: in Lua a nil-valued key
--- does not exist, so key-presence and value-presence are the same test. The
--- real rule is the optionality one above.
---
--- Consequences: a castrated male's `fertility = 0` raises `presentCount` and
--- contributes 0 to the sum; `presentCount` is always <= the denominator; and the
--- empty table divides by 4 rather than short-circuiting.
---
--- **Known artifact: a BAND derived from `factor` depends on the TERM COUNT,
--- not only on the trait values.** Float addition is not associative, so
--- accumulating n copies of one value and dividing does not reproduce the exact
--- quotient: four literal `0.35` values sum to 1.3999999999999999 while five
--- sum to exactly 1.75, and those straddle a rung - so the same nominal animal
--- can band one tier apart purely by stat count. That is a rounding
--- consequence, NOT a design decision; whether banding should round or compare
--- with an epsilon is an open question owned outside this module. The artifact
--- is harmless per stat set: one animal under one `statKeys` set yields the
--- same factor at every call site, so no two consumers can disagree on its
--- band - but a caller passing a NARROWED `statKeys` changes the denominator
--- and legitimately gets a different factor, so that guarantee is per-stat-set,
--- not universal. The three returns below are unaffected either way - only a
--- ladder applied to `factor` sees it. The suite pins the two straddling
--- doubles as `%.17g` strings (which arithmetic ran) and keeps its own
--- band-key fixtures off the rungs; the band SPLIT itself is not a contract.
---
--- Separately, and not to be confused with the above, that same non-associativity
--- is why the walk order is canonical rather than the caller's, and why `factor`
--- and `mean` each get their OWN expression from the shared sum - deriving one
--- from the other moves the result by an ulp, which is invisible everywhere
--- except at an exact rung.
---
--- @param genetics any The genetics table. A non-table returns the zero triple
--- @param statKeys table|nil Stat set to walk; defaults to DEFAULT_STAT_KEYS
--- @return number factor `sum / (MAX * denominator)`, or 0
--- @return number mean `sum / denominator`, or 0
--- @return number presentCount How many stats OF THE RESOLVED SET held a value -
---         scoped, so a narrowed `statKeys` lowers it even when the table is
---         fully populated. Never nil, never raises
function RLGenetics.aggregate(genetics, statKeys)
    if type(genetics) ~= "table" then
        if not warnedContainer then
            warnedContainer = true
            warnRejected("aggregate", genetics, "0, 0, 0", EXPECTED_CONTAINER, "returning")
        end

        return 0, 0, 0
    end

    local keys = resolveStatKeys(statKeys)

    -- Calls the public helper rather than inlining the check, so the poison
    -- behaviour here is definitionally whatever validateGenetics says and the
    -- two can never disagree. The accepted cost is a second resolveStatKeys
    -- pass; it is idempotent, and the shared latch still warns at most once.
    local ok, badKey, badValue = RLGenetics.validateGenetics(genetics, statKeys)

    if not ok then
        if not warnedMember then
            warnedMember = true
            warnRejected("aggregate", badValue, "0, 0, 0",
                string.format(EXPECTED_MEMBER, tostring(badKey)), "returning")
        end

        return 0, 0, 0
    end

    local sum, denominator, presentCount = 0, 0, 0

    for _, key in ipairs(keys) do
        local value = genetics[key]

        -- Presence is `~= nil`, never truthiness: `false` is present (and would
        -- already have poisoned above), absent is absent.
        if value ~= nil then
            sum = sum + value
            presentCount = presentCount + 1
            denominator = denominator + 1
        elseif not RLGenetics.OPTIONAL_STATS[key] then
            denominator = denominator + 1
        end
    end

    -- Branches on the DENOMINATOR, not on presentCount: `aggregate({})` has
    -- denominator 4 and legitimately divides to 0, while a stat set of only
    -- optional absent members has nothing to divide by at all.
    if denominator == 0 then return 0, 0, 0 end

    -- Each dialect from its own expression against the shared sum. Never derive
    -- one from the other - see the term-count note above.
    return sum / (RLGenetics.MAX * denominator), sum / denominator, presentCount
end


--- Clear all six warn latches so the next offender is reported again.
---
--- TEST SEAM. Production never calls it: the latches are meant to survive a
--- session and are reset by the per-map-load re-source. It exists so a suite
--- can exercise a rejection path without leaving the latches spent for whatever
--- runs next.
--- @return nil
function RLGenetics._resetWarnLatches()
    warnedPerTrait = false
    warnedFertility = false
    warnedOverall = false
    warnedStatKeys = false
    warnedContainer = false
    warnedMember = false
end


Log:info("RLGenetics loaded")
