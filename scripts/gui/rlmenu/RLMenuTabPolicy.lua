-- RLMenuTabPolicy.lua
-- Pure decision layer for RL Tabbed Menu tab visibility and the trailer-mode anchor. Plain data
-- in, plain data out - no g_*, no GUI, no XML handles - so the whole module runs headless.
--
-- Two concerns live here so RLMenu's setupMenuPages closures stay thin wiring:
--   1. isVisible(pageKey, openMode, counterpart) -> bool   (which tabs show)
--   2. anchorPage(counterpart, trailerIsEmpty)  -> index  (which tab lands first)
--
-- Both functions are TOTAL: an unrecognized openMode, counterpart or pageKey resolves to a safe
-- default - hidden, or Buy - rather than erroring.
--
-- Open-mode and counterpart string values are owned here, because the pure layer loads first,
-- and re-exported by RLMenu; any string drift between the two owners fails the in-game suite.

local Log = RmLogging.getLogger("RLRM")

RLMenuTabPolicy = {}

-- =============================================================================
-- Constants
-- =============================================================================

-- MODE_FULL = keyboard-shortcut path (all tabs); MODE_DEALER = shop / walk-up dealer redirect;
-- MODE_TRAILER = a livestock trailer drives visibility per its counterpart.
RLMenuTabPolicy.MODE_FULL = "full"
RLMenuTabPolicy.MODE_DEALER = "dealer"
RLMenuTabPolicy.MODE_TRAILER = "trailer"

-- Trailer counterparts - where the trailer is parked. PEN = husbandry pen, DEALER = animal
-- dealer, WORLD = walk-up / activatable, EPP = butcher direct-open sink.
RLMenuTabPolicy.PEN = "pen"
RLMenuTabPolicy.DEALER = "dealer"
RLMenuTabPolicy.WORLD = "world"
RLMenuTabPolicy.EPP = "epp"

-- Collapsed visible-tab anchor indices used by RLMenu.restorePageIndex. In the trailer-dealer
-- placement the visible set is exactly {Buy, Sell}, so Buy = 1 and Sell = 2 map cleanly.
RLMenuTabPolicy.ANCHOR_BUY = 1
RLMenuTabPolicy.ANCHOR_SELL = 2

-- =============================================================================
-- Visibility tables
-- =============================================================================

-- Per-mode visible-tab sets keyed by pageKey. A key absent from a table reads as hidden, since
-- the `== true` test below makes nil false. "transfer" never appears in a full or dealer set - it
-- is a trailer pen/world tab. MODE_TRAILER is counterpart-dependent, handled in trailerVisible.
local FULL_VISIBLE = {
    buy = true, sell = true, move = true, info = true,
    ai = true, messages = true, herdsman = true, settings = true,
}

local DEALER_VISIBLE = {
    buy = true, sell = true, info = true, ai = true,
    -- move / messages / herdsman / settings hidden in dealer mode
}

--- Trailer-mode visibility, split by counterpart: dealer shows {Buy, Sell}, with in-tab detail
--- panes carrying Info parity for that placement; pen, world and epp show {Transfer} only, the
--- butcher sink sharing that branch with an adapter that enumerates nothing. Any other or nil
--- counterpart shows nothing.
---@param pageKey string
---@param counterpart string|nil
---@return boolean
local function trailerVisible(pageKey, counterpart)
    if counterpart == RLMenuTabPolicy.DEALER then
        return pageKey == "buy" or pageKey == "sell"
    elseif counterpart == RLMenuTabPolicy.PEN
        or counterpart == RLMenuTabPolicy.WORLD
        or counterpart == RLMenuTabPolicy.EPP then
        return pageKey == "transfer"
    end
    return false
end

-- =============================================================================
-- Public API
-- =============================================================================

--- Whether a tab is visible for the given open mode and trailer counterpart. Total: an
--- unrecognized argument returns false, and counterpart is consulted only in MODE_TRAILER.
---@param pageKey string  one of: buy, sell, move, info, ai, messages, herdsman, settings, transfer
---@param openMode string  MODE_FULL | MODE_DEALER | MODE_TRAILER
---@param counterpart string|nil  PEN | DEALER | WORLD (MODE_TRAILER only)
---@return boolean visible
function RLMenuTabPolicy.isVisible(pageKey, openMode, counterpart)
    if openMode == RLMenuTabPolicy.MODE_FULL then
        return FULL_VISIBLE[pageKey] == true
    elseif openMode == RLMenuTabPolicy.MODE_DEALER then
        return DEALER_VISIBLE[pageKey] == true
    elseif openMode == RLMenuTabPolicy.MODE_TRAILER then
        return trailerVisible(pageKey, counterpart)
    end
    return false
end

--- The collapsed visible-tab index a trailer open should land on. Dealer placement only: an empty
--- trailer anchors Buy, since loading it is the likely action, and a loaded trailer anchors Sell.
--- The caller passes the already-resolved emptiness bool, so this stays pure. Any non-dealer
--- counterpart returns Buy defensively - unreachable, because the bridge rejects an invalid
--- counterpart and pen/world never computes an anchor.
---@param counterpart string|nil  PEN | DEALER | WORLD
---@param trailerIsEmpty boolean
---@return number anchorIndex  ANCHOR_BUY (1) or ANCHOR_SELL (2)
function RLMenuTabPolicy.anchorPage(counterpart, trailerIsEmpty)
    local anchor
    if counterpart == RLMenuTabPolicy.DEALER then
        anchor = trailerIsEmpty and RLMenuTabPolicy.ANCHOR_BUY or RLMenuTabPolicy.ANCHOR_SELL
    else
        anchor = RLMenuTabPolicy.ANCHOR_BUY
    end
    Log:trace("RLMenuTabPolicy.anchorPage: counterpart=%s isEmpty=%s -> %d",
        tostring(counterpart), tostring(trailerIsEmpty), anchor)
    return anchor
end
