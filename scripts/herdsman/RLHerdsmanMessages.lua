-- RLHerdsmanMessages.lua
-- The player-notification readout for the herdsman day-tick. RLHerdsmanExecutor applies the planned
-- mutations and returns a per-action summary.results but emits no notifications; this module maps
-- those rows to AI_MANAGER_* messages, one per executed or marked op.
--
-- Two halves, split on the dual-run seam:
--   * buildMessages(results, formatMoney) is PURE - no g_* reads, no input mutation, no logging.
--     It takes an injected formatMoney closure so money formatting is testable without g_i18n, and
--     returns { records, skips } so emit can emit the records and log every dropped row.
--   * emit(summary, ctx) is the thin in-game wiring: it reads g_i18n and g_server, groups the
--     records by husbandry in first-seen order, resolves each placeable via
--     ctx.husbandryPlaceablesById, and drives the server-local addRLMessage sink.
--
-- Message order follows PLAN order within a husbandry, and the multi-rule model can emit more than
-- one message per husbandry per op - both intended.
--
-- Every message goes through placeable:addRLMessage, so RLMessageAggregator owns the
-- individual-vs-summary fork and this module is unaware of the mode. MP transport rides the
-- addRLMessageDirect chokepoint's incremental broadcast; emit builds no wire payload.
--
-- Server-only: emit is called from RLHerdsmanDayTick.run, which returns early when g_server is nil.

local Log = RmLogging.getLogger("RLRM")

RLHerdsmanMessages = {}

-- =============================================================================
-- Constants
-- =============================================================================

--- Greppable prefix on every message log line.
local LOG_PREFIX = "[herdsmanMessages]"

--- operation -> the AI_MANAGER_* id families. `exec` is the executed-op family and, for sell/buy,
--- names the money amount field; `mark` is the mark-mode family, count-only, and nil for the ops
--- that have none (a corrupt row carrying mark on one of those is WARNed and skipped before the id
--- lookup).
---
--- Every id here is one link of a three-link chain - ID_FAMILY -> RLMessage[id] ->
--- rl_message_<text> - and nothing in the runtime gates it: a break at the second link discards the
--- player's saved messages at load, a break at the third renders the missing-key fallback. The
--- registry cross-check in the dual-run suite walks this table and asserts both links.
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
        -- Count-only: the wage is charged by the executor, never reported here, and a
        -- buy/sell-template copy would read a nil amount field and emit a formatted 0. The count is
        -- the ARMED count - the care write defers and its callback re-validates membership, so this
        -- family alone is optimistic (@see RLHerdsmanExecutor._doHorseCare).
        exec = { single = "AI_MANAGER_HORSE_CARE_SINGLE", multiple = "AI_MANAGER_HORSE_CARE_MULTIPLE" },
        mark = nil,
    },
}

-- =============================================================================
-- Internal helpers (pure)
-- =============================================================================

--- Finite-number guard: rejects nil / non-number / NaN / +-inf.
--- @see RLHerdsmanExecutor isFiniteNumber.
---@param v any
---@return boolean
local function isFiniteNumber(v)
    return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

--- Shallow-copy an args array. In INDIVIDUAL mode placeable:addRLMessage forwards to
--- addRLMessageDirect, which tostring-coerces its args IN PLACE, so the record must keep its own
--- pristine table and the two sinks must never share one.
---@param args table
---@return table
local function copyArgs(args)
    local out = {}
    for i = 1, #args do out[i] = args[i] end
    return out
end

-- Exposed for the dual-run suite.
RLHerdsmanMessages._isFiniteNumber = isFiniteNumber
RLHerdsmanMessages._copyArgs       = copyArgs
RLHerdsmanMessages.ID_FAMILY       = ID_FAMILY

-- =============================================================================
-- Pure builder (data in / data out - no g_*, no logging, no input mutation)
-- =============================================================================

--- Map the executor's summary.results rows to AI_MANAGER_* message records, in plan order. emit
--- consumes the return: `records` are emitted and logged in order, `skips` are logged so a dropped
--- row is never silent.
---
--- Predicate per row (mark precedence is load-bearing):
---   1. no husbandryId            -> skip (nowhere to emit)
---   2. unmapped / nil operation  -> skip (no nil-index)
---   3. mark == true              -> the MARK id family; a mark on an op with none -> skip
---   4. elseif dispatched == true -> the EXEC id family
---   5. else                      -> genuine skip (no record)
--- then count-normalize: n = tonumber(movedCount or count); nil/non-number or n < 1 -> skip;
--- floor(n) == 1 -> _SINGLE else _MULTIPLE. Args: sell/buy exec carry money (SINGLE {money},
--- MULTIPLE {count,money}); all others SINGLE {}, MULTIPLE {count}; the count arg is a STRING while
--- record.count stays numeric.
---
--- Independently of that chain, a move row (mark=false) with skippedAge>0 ALSO emits an
--- AI_MANAGER_MOVE_SKIPPED_AGE_* record regardless of `dispatched` - it can accompany the moved
--- record or stand alone.
---@see RLHerdsmanExecutor._doSell
---@see RLHerdsmanExecutor._doBuy
---@param results table|nil executor summary.results (array of result rows)
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
            -- A nil group key would also crash emit's grouping.
            addSkip(row, "no-husbandryId", "warn")
        elseif family == nil then
            addSkip(row, "unmapped-operation:" .. tostring(op), "warn")
        else
            local mark = row.mark == true
            local idSet, isMoney

            if mark then
                if family.mark == nil then
                    -- Contract violation: the executor never sets mark on these ops. Skip BEFORE
                    -- the id lookup so there is no nil-index.
                    addSkip(row, "mark-on-no-mark-op:" .. tostring(op), "warn")
                else
                    idSet, isMoney = family.mark, false
                end
            elseif row.dispatched == true then
                idSet, isMoney = family.exec, (family.exec.amountField ~= nil)
            else
                -- Expected, so DEBUG: carries the executor's skipReason.
                addSkip(row, "genuine-skip:" .. tostring(row.skipReason), "debug")
            end

            if idSet ~= nil then
                -- movedCount when present (an EPP butcher move can dispatch fewer than planned after
                -- the delivery-time age filter); every other row falls back to count. A 0 movedCount
                -- never reaches here - such a row is dispatched=false - so `or` cannot mis-fall.
                local countSource = row.movedCount or row.count
                local n = tonumber(countSource)
                if n == nil then
                    addSkip(row, "count-not-a-number:" .. tostring(countSource), "warn")
                elseif n < 1 then
                    addSkip(row, "count-below-one:" .. tostring(countSource), "debug")
                else
                    local count = math.floor(n)         -- fractional (corrupt) -> floor; legacy counts are integers
                    local single = count == 1
                    local id = single and idSet.single or idSet.multiple
                    -- The count rides as a STRING, the canonical RL message arg type: readStream
                    -- reads strings, addRLMessageDirect tostring-coerces, the savegame uses setString.
                    local fmtCount = string.format("%d", count)
                    local args, warn

                    if isMoney then
                        local amount = row[family.exec.amountField]
                        local money
                        if isFiniteNumber(amount) then
                            money = formatMoney(amount)
                        else
                            -- The executor fail-closes non-finite amounts before dispatch, so this is
                            -- defensive: format 0 and flag it for emit to WARN.
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

            -- Skipped-for-age (EPP butcher move), independent of `dispatched`: it accompanies the
            -- moved record on a partial-age move, or stands alone when every candidate was
            -- age-ineligible. INDIVIDUAL only - these ids are deliberately not aggregatable.
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

--- Emit the day-tick's notifications from the executor summary: build the records with the real
--- g_i18n:formatMoney closure, log every skip, then per husbandry in first-seen plan order resolve
--- the placeable and drive placeable:addRLMessage. Reads no summary fields beyond results and never
--- mutates summary.
---@param summary table|nil executor summary ({ results = {...} })
---@param ctx table executor ctx; only ctx.husbandryPlaceablesById is read
function RLHerdsmanMessages.emit(summary, ctx)
    local results = (summary ~= nil and summary.results) or {}
    -- Bound to g_i18n so formatMoney keeps its `self`.
    local formatMoney = function(amount) return g_i18n:formatMoney(amount, 2, true, true) end

    local built = RLHerdsmanMessages.buildMessages(results, formatMoney)
    Log:trace("%s built %d record(s), %d skip(s) from %d result row(s)",
        LOG_PREFIX, #built.records, #built.skips, #results)

    -- Log every dropped row so a missing message is never silent.
    for _, skip in ipairs(built.skips) do
        if skip.level == "warn" then
            Log:warning("%s skipped row: %s (rule=%s husbandry=%s op=%s)", LOG_PREFIX, skip.reason,
                tostring(skip.row.ruleId), tostring(skip.row.husbandryId), tostring(skip.row.operation))
        else
            Log:debug("%s skipped row: %s (rule=%s husbandry=%s op=%s)", LOG_PREFIX, skip.reason,
                tostring(skip.row.ruleId), tostring(skip.row.husbandryId), tostring(skip.row.operation))
        end
    end

    -- Group by husbandryId preserving first-seen (plan) order, NOT pairs(), which is
    -- nondeterministic.
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
            Log:warning("%s husbandry '%s' not in ctx.husbandryPlaceablesById - %d message(s) dropped, no broadcast",
                LOG_PREFIX, tostring(husbandryId), #recs)
        elseif placeable.addRLMessage == nil then
            Log:warning("%s husbandry '%s' placeable lacks addRLMessage (wrong-type object) - %d message(s) dropped, no broadcast",
                LOG_PREFIX, tostring(husbandryId), #recs)
        else
            for _, rec in ipairs(recs) do
                -- Server-local sink only; copyArgs keeps the record's args pristine because the sink
                -- coerces in place.
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
