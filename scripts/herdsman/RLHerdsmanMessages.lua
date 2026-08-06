-- RLHerdsmanMessages.lua
-- M-Tick T5 - the player-notification readout for the new rule-driven herdsman
-- day-tick. T3 (RLHerdsmanExecutor.executeActions) applies the planned mutations and returns a
-- per-action summary.results but, by decision 1a, emits NO notifications. Legacy
-- AIAnimalManager:onDayChanged surfaced every executed/marked op as an AI_MANAGER_* message via
-- husbandry:addRLMessage per husbandry. This module restores
-- that readout (the SAME AI_MANAGER_* ids + args legacy used, per executed/marked op), driven off
-- summary.results instead of re-deriving it. Parity is on the id/args mapping, NOT a byte-identical
-- wire order: intra-husbandry message order follows PLAN order, and the new multi-rule model can
-- emit more than one message per husbandry per op where legacy (one settings block) emitted one -
-- both intended; summary mode folds the duplicates into the daily summary.
--
-- Two halves, split on the dual-run seam (the SAME split T3/T4 use):
--   * buildMessages(results, formatMoney) is PURE (data in / data out): it maps each result row
--     to the SAME AI_MANAGER_* id(s) + args legacy used, with NO g_* reads, NO mutation of the
--     input, and NO logging (logging is emit's job - M1). It takes an injected formatMoney closure
--     so the money formatting is testable without g_i18n, and returns { records, skips } so emit
--     can both emit the records and log every dropped row.
--   * emit(summary, ctx) is the thin in-game wiring: it reads g_i18n (to build the real
--     formatMoney closure) + g_server, groups the records by husbandry in first-seen order,
--     resolves each placeable via ctx.husbandryPlaceablesById (the SAME handle T3 dispatched its
--     events against), drives the server-local addRLMessage sink per husbandry (MP transport rides
--     the addRLMessageDirect chokepoint's incremental broadcast), and logs every emission
--     decision + skip cause.
--
-- Parity anchor: AIAnimalManager:onDayChanged - its per-operation emission legs (the SELL / BUY /
-- CASTRATE / NAMING / AI sections) each do `husbandry:addRLMessage(id, nil, args)` for the local
-- sink. Both this module and legacy now rely on the addRLMessageDirect chokepoint to broadcast each
-- server-added message to connected clients (one incremental HusbandryMessageAddEvent per message,
-- server-authoritative); emit itself no longer builds or broadcasts a wire payload.
--
-- Summary mode (decision 1b): every message goes through placeable:addRLMessage so the aggregator
-- decides individual-vs-summary. RLMessageAggregator is extended (separately) so castrate / named /
-- inseminated / mark also aggregate into new daily-summary categories (sold / bought already did).
-- This module is unaware of the mode - it always calls addRLMessage; the aggregator owns the fork.
--
-- Server-only: emit is called from RLHerdsmanDayTick.run, which already returns when g_server is
-- nil, so emit runs server-side only. The broadcast is additionally guarded on g_server.netIsRunning
-- (SP has no network, so SP emits the server-local message only - no broadcast).

local Log = RmLogging.getLogger("RLRM")

RLHerdsmanMessages = {}

-- =============================================================================
-- Constants
-- =============================================================================

--- Greppable prefix on every message log line (emit's emission / skip / broadcast rows are the
--- verification surface; the mutation-parity trace lives in the executor's [executeActions] rows).
local LOG_PREFIX = "[herdsmanMessages]"

--- operation -> the AI_MANAGER_* id families. sell/buy/castrate/naming/ai mirror the ids
--- AIAnimalManager:onDayChanged emits; move and horseCare follow the SAME count-only shape but are
--- net-new (the legacy day-tick emits neither). `exec` is the executed-op family (and, for sell/buy,
--- carries the money amount field name; move and horseCare are count-only, no amountField); `mark` is
--- the mark-mode family (count-only; nil for buy/naming/horseCare, which have no mark family - T3
--- never sets mark on them, but a corrupt row that does is WARNed + skipped before the id lookup).
--- Mapped ops: sell, buy, castrate, naming, ai, move, horseCare.
---
--- Every id here is one link of a THREE-link chain - ID_FAMILY -> RLMessage[id] ->
--- rl_message_<text> - and nothing in the runtime gates it: a break at the second link discards the
--- player's saved messages at load, a break at the third renders the missing-key fallback. The
--- registry cross-check in the dual-run suite walks this table and asserts both links for every
--- operation, so a new entry is covered the moment it is added here.
local ID_FAMILY = {
    sell = {
        exec = { single = "AI_MANAGER_SOLD_SINGLE",   multiple = "AI_MANAGER_SOLD_MULTIPLE",   amountField = "amountGained" },
        mark = { single = "AI_MANAGER_MARK_SELL_SINGLE", multiple = "AI_MANAGER_MARK_SELL_MULTIPLE" },
    },
    buy = {
        exec = { single = "AI_MANAGER_BOUGHT_SINGLE", multiple = "AI_MANAGER_BOUGHT_MULTIPLE", amountField = "amountSpent" },
        mark = nil,
    },
    castrate = {
        exec = { single = "AI_MANAGER_CASTRATED_SINGLE",      multiple = "AI_MANAGER_CASTRATED_MULTIPLE" },
        mark = { single = "AI_MANAGER_MARK_CASTRATE_SINGLE",  multiple = "AI_MANAGER_MARK_CASTRATE_MULTIPLE" },
    },
    naming = {
        exec = { single = "AI_MANAGER_NAMED_SINGLE", multiple = "AI_MANAGER_NAMED_MULTIPLE" },
        mark = nil,
    },
    ai = {
        exec = { single = "AI_MANAGER_INSEMINATED_SINGLE",      multiple = "AI_MANAGER_INSEMINATED_MULTIPLE" },
        mark = { single = "AI_MANAGER_MARK_INSEMINATED_SINGLE", multiple = "AI_MANAGER_MARK_INSEMINATED_MULTIPLE" },
    },
    move = {
        exec = { single = "AI_MANAGER_MOVED_SINGLE",     multiple = "AI_MANAGER_MOVED_MULTIPLE" },   -- count-only, no amountField
        mark = { single = "AI_MANAGER_MARK_MOVE_SINGLE", multiple = "AI_MANAGER_MARK_MOVE_MULTIPLE" },
    },
    horseCare = {
        -- Count-only, no amountField: the wage is charged by the executor, not reported here. A
        -- buy/sell-template copy would read a nil amount field and emit a formatted 0 with a WARN.
        -- The count reported is the ARMED count - the care write is deferred and its callback
        -- re-validates membership, so this family alone is optimistic (@see RLHerdsmanExecutor._doHorseCare).
        -- mark = nil is DOCUMENTATION: a table constructor stores no key for a nil value, so the
        -- WARN-skip routing for a corrupt mark row is a property of the lookup, not of this line.
        exec = { single = "AI_MANAGER_HORSE_CARE_SINGLE", multiple = "AI_MANAGER_HORSE_CARE_MULTIPLE" },
        mark = nil,
    },
}

-- =============================================================================
-- Internal helpers (pure)
-- =============================================================================

--- Finite-number guard: rejects nil / non-number / NaN / +-inf. Mirrors the executor's guard
--- (@see RLHerdsmanExecutor isFiniteNumber); used to fail-soft on a corrupt money amount (format 0).
---@param v any
---@return boolean
local function isFiniteNumber(v)
    return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

--- Shallow-copy an args array. emit hands the LOCAL sink its own copy because in INDIVIDUAL mode
--- placeable:addRLMessage forwards to PlaceableHusbandryAnimals:addRLMessageDirect, which
--- tostring-coerces its args IN PLACE; the wire record must keep its own pristine args table, so
--- the two sinks must never share one - exactly as
--- AIAnimalManager:onDayChanged builds two separate arg literals per op. (In SUMMARY mode the
--- aggregator buckets the message and never calls addRLMessageDirect, so the copy is a harmless
--- no-op there; the copy is load-bearing only on the individual-mode path.)
---@param args table
---@return table
local function copyArgs(args)
    local out = {}
    for i = 1, #args do out[i] = args[i] end
    return out
end

-- Exposed for the dual-run suite (test the predicate's helpers in isolation if needed).
RLHerdsmanMessages._isFiniteNumber = isFiniteNumber
RLHerdsmanMessages._copyArgs       = copyArgs
RLHerdsmanMessages.ID_FAMILY       = ID_FAMILY

-- =============================================================================
-- Pure builder (data in / data out - no g_*, no logging, no input mutation)
-- =============================================================================

--- Map T3's summary.results rows to the legacy AI_MANAGER_* message records (in plan order).
--- PURE: reads only `results` + the injected `formatMoney`, mutates nothing, logs nothing. emit
--- consumes the return: `records` are emitted (and logged) in order; `skips` are logged by emit so
--- a dropped row is never silent. Each record carries the emission payload (husbandryId, id, args)
--- plus diagnostics (mark, count, warn) that emit logs but never puts on the wire / sink.
---
--- Predicate per row (mark precedence is load-bearing):
---   1. no husbandryId            -> skip (nowhere to emit; defensive - T3 always sets it)
---   2. unmapped / nil operation  -> skip (no nil-index)
---   3. mark == true              -> the MARK id family (subsumes T3's skipReason="mark-mode"
---                                   rows, which carry mark=true, before any skip check); a mark
---                                   on buy/naming (no mark family) -> skip
---   4. elseif dispatched == true -> the EXEC id family
---   5. else                      -> genuine skip (no record)
--- then count-normalize: n = tonumber(movedCount or count); nil/non-number or n < 1 -> skip;
--- floor(n) == 1 -> _SINGLE else _MULTIPLE. Args: sell/buy exec carry money (SINGLE {money}, MULTIPLE
--- {count,money}); all others SINGLE {}, MULTIPLE {count}; the count arg is a STRING (the canonical RL
--- message arg type), while record.count stays numeric. A move row uses movedCount when present (an
--- EPP butcher move can dispatch fewer than planned after the age filter); husbandry-move +
--- every other row fall back to count.
--- SEPARATE branch (independent of the above, move rows only): a move row (mark=false) with
--- skippedAge>0 ALSO emits an AI_MANAGER_MOVE_SKIPPED_AGE_SINGLE/MULTIPLE record REGARDLESS of
--- dispatched (count arg = skippedAge) - it can accompany the moved record (partial-age) or stand
--- alone (all-age-ineligible / partial-age+no-space).
---@param results table|nil T3 summary.results (array of executor result rows)
---@param formatMoney fun(amount:number):string injected money formatter (g_i18n:formatMoney closure)
---@return table built { records = {{husbandryId,id,args,mark,count,warn}, ...}, skips = {{row,reason,level}, ...} }
function RLHerdsmanMessages.buildMessages(results, formatMoney)
    local records, skips = {}, {}

    local function addSkip(row, reason, level)
        skips[#skips + 1] = { row = row, reason = reason, level = level }
    end

    for _, row in ipairs(results or {}) do
        local op = row.operation
        local family = op ~= nil and ID_FAMILY[op] or nil

        if row.husbandryId == nil then
            -- Nowhere to emit (a nil group key would also crash emit's grouping). Defensive: T3
            -- always copies action.husbandryId onto the row.
            addSkip(row, "no-husbandryId", "warn")
        elseif family == nil then
            -- Unmapped / nil operation: WARN + skip rather than nil-index ID_FAMILY[op].
            addSkip(row, "unmapped-operation:" .. tostring(op), "warn")
        else
            local mark = row.mark == true
            local idSet, isMoney

            if mark then
                if family.mark == nil then
                    -- mark on buy/naming: contract violation (T3 never sets it) - WARN + skip
                    -- BEFORE the id lookup so there is no nil-index.
                    addSkip(row, "mark-on-no-mark-op:" .. tostring(op), "warn")
                else
                    idSet, isMoney = family.mark, false
                end
            elseif row.dispatched == true then
                idSet, isMoney = family.exec, (family.exec.amountField ~= nil)
            else
                -- Genuine skip (dispatched=false, mark~=true): no message. Carries T3's skipReason
                -- (no-space / no-money / missing-placeable / bad-data, plus horse care's
                -- not-in-husbandry / defer-failed). Expected, so DEBUG.
                addSkip(row, "genuine-skip:" .. tostring(row.skipReason), "debug")
            end

            if idSet ~= nil then
                -- The moved record's count comes from movedCount when present (an EPP butcher move can
                -- dispatch fewer than planned after the delivery-time age filter); every
                -- other row - including husbandry-move rows, which carry no movedCount - falls back to
                -- count (unchanged). 0 is a valid movedCount but never reaches here (dispatched=false
                -- on a 0-moved EPP row -> the genuine-skip branch above), so `or` cannot mis-fall to count.
                local countSource = row.movedCount or row.count
                local n = tonumber(countSource)
                if n == nil then
                    addSkip(row, "count-not-a-number:" .. tostring(countSource), "warn")
                elseif n < 1 then
                    -- 0 / negative count: nothing to report. Expected-ish, so DEBUG.
                    addSkip(row, "count-below-one:" .. tostring(countSource), "debug")
                else
                    local count = math.floor(n)         -- fractional (corrupt) -> floor; legacy counts are integers
                    local single = count == 1
                    local id = single and idSet.single or idSet.multiple
                    -- MULTIPLE messages carry the count as a STRING (the canonical RL message arg
                    -- type: readStream reads strings, addRLMessageDirect tostring-coerces, the
                    -- savegame uses setString); SINGLE omits it. record.count below stays numeric.
                    local fmtCount = string.format("%d", count)
                    local args, warn

                    if isMoney then
                        local amount = row[family.exec.amountField]
                        local money
                        if isFiniteNumber(amount) then
                            money = formatMoney(amount)
                        else
                            -- Defensive: T3 fail-closes non-finite amounts before dispatch
                            -- (@see RLHerdsmanExecutor._doSell / ._doBuy), so a dispatched sell/buy
                            -- always has a finite amount; format 0 + flag for emit to WARN.
                            money = formatMoney(0)
                            warn = "nil/non-number amount on dispatched " .. tostring(op)
                                .. " (husbandry=" .. tostring(row.husbandryId) .. ") - formatted 0"
                        end
                        args = single and { money } or { fmtCount, money }
                    else
                        args = single and {} or { fmtCount }
                    end

                    records[#records + 1] = {
                        husbandryId = row.husbandryId,
                        id          = id,
                        args        = args,
                        mark        = mark,
                        count       = count,
                        warn        = warn,
                    }
                end
            end

            -- Skipped-for-age (EPP butcher move): a move row (mark=false) with skippedAge>0
            -- emits the skipped-age record REGARDLESS of `dispatched` - it ACCOMPANIES the moved record
            -- on a partial-age move, or stands ALONE on an all-age-ineligible / partial-age+no-space
            -- move (dispatched=false, no moved record). Count arg = skippedAge. INDIVIDUAL only (the ids
            -- are deliberately NOT in RLMessageAggregator.AGGREGATABLE - exceptional + actionable).
            if op == "move" and not mark then
                local skippedAge = tonumber(row.skippedAge)
                if skippedAge ~= nil and skippedAge >= 1 then
                    local sa = math.floor(skippedAge)
                    local single = sa == 1
                    local id = single and "AI_MANAGER_MOVE_SKIPPED_AGE_SINGLE" or "AI_MANAGER_MOVE_SKIPPED_AGE_MULTIPLE"
                    records[#records + 1] = {
                        husbandryId = row.husbandryId,
                        id          = id,
                        args        = single and {} or { string.format("%d", sa) },
                        mark        = false,
                        count       = sa,
                        warn        = nil,
                    }
                end
            end
        end
    end

    return { records = records, skips = skips }
end

-- =============================================================================
-- In-game wiring (reads g_* - the only non-dual-run layer)
-- =============================================================================

--- Emit the herdsman day-tick's notifications from T3's summary. Builds the records via the pure
--- buildMessages (with the REAL g_i18n:formatMoney closure - bound to g_i18n so `self` is not
--- dropped), logs every skip, then per husbandry (in first-seen plan order) resolves the placeable
--- and drives the server-local sink: placeable:addRLMessage (so the aggregator decides
--- individual-vs-summary). MP transport to clients rides the addRLMessageDirect chokepoint's
--- incremental HusbandryMessageAddEvent broadcast; emit no longer builds a wire payload.
--- Reads no summary fields beyond results; never mutates summary.
---@param summary table|nil T3 executor summary ({ results = {...} })
---@param ctx table executor ctx; only ctx.husbandryPlaceablesById ({ [uniqueId] = placeable }) is read
function RLHerdsmanMessages.emit(summary, ctx)
    local results = (summary ~= nil and summary.results) or {}
    -- Bind to g_i18n so formatMoney keeps its `self` (g_i18n.formatMoney unbound would drop it).
    local formatMoney = function(amount) return g_i18n:formatMoney(amount, 2, true, true) end

    local built = RLHerdsmanMessages.buildMessages(results, formatMoney)
    Log:trace("%s built %d record(s), %d skip(s) from %d result row(s)",
        LOG_PREFIX, #built.records, #built.skips, #results)

    -- Log every dropped row so a missing message is never silent (logging is emit's job).
    for _, skip in ipairs(built.skips) do
        if skip.level == "warn" then
            Log:warning("%s skipped row: %s (rule=%s husbandry=%s op=%s)", LOG_PREFIX, skip.reason,
                tostring(skip.row.ruleId), tostring(skip.row.husbandryId), tostring(skip.row.operation))
        else
            Log:debug("%s skipped row: %s (rule=%s husbandry=%s op=%s)", LOG_PREFIX, skip.reason,
                tostring(skip.row.ruleId), tostring(skip.row.husbandryId), tostring(skip.row.operation))
        end
    end

    -- Group records by husbandryId, preserving first-seen (plan) order - NOT pairs(), which is
    -- nondeterministic; husbandries broadcast in the order their first record appeared.
    local order, groups = {}, {}
    for _, rec in ipairs(built.records) do
        if groups[rec.husbandryId] == nil then
            groups[rec.husbandryId] = {}
            order[#order + 1] = rec.husbandryId
        end
        local g = groups[rec.husbandryId]
        g[#g + 1] = rec
    end

    local placeablesById = (ctx ~= nil and ctx.husbandryPlaceablesById) or {}

    for _, husbandryId in ipairs(order) do
        local recs = groups[husbandryId]
        local placeable = placeablesById[husbandryId]

        if placeable == nil then
            -- The SAME handle T3 dispatched against is absent - skip the husbandry, no broadcast.
            Log:warning("%s husbandry '%s' not in ctx.husbandryPlaceablesById - %d message(s) dropped, no broadcast",
                LOG_PREFIX, tostring(husbandryId), #recs)
        elseif placeable.addRLMessage == nil then
            -- Wrong-type object (lacks the husbandryAnimals spec) - mirror the husbandry-message events' run guard.
            Log:warning("%s husbandry '%s' placeable lacks addRLMessage (wrong-type object) - %d message(s) dropped, no broadcast",
                LOG_PREFIX, tostring(husbandryId), #recs)
        else
            for _, rec in ipairs(recs) do
                -- Server-local sink only. addRLMessage -> addRLMessageDirect coerces args in place, so
                -- copyArgs keeps the record's args pristine. MP transport to clients now rides that
                -- chokepoint's incremental HusbandryMessageAddEvent broadcast, so emit no
                -- longer builds a wire payload here.
                placeable:addRLMessage(rec.id, nil, copyArgs(rec.args))

                Log:debug("%s emit husbandry=%s id=%s count=%d mark=%s",
                    LOG_PREFIX, tostring(husbandryId), rec.id, rec.count, tostring(rec.mark))
                if rec.warn ~= nil then
                    Log:warning("%s %s", LOG_PREFIX, rec.warn)
                end
            end
        end
    end
end
