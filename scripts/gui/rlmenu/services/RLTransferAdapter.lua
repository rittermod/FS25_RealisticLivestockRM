--[[
    RLTransferAdapter.lua
    The counterpart-adapter seam for the RL Tabbed Menu Transfer frame.

    One Transfer frame serves every trailer placement; the part that varies - where the
    other side's animals come from, what the action button says, and what a confirmed
    transfer does - lives behind this data-in/data-out seam. The frame talks only to the
    contract, never to a placement directly.

    Purity contract, the headless dual-run boundary: no g_*, GUI, engine class or getText,
    at load or in any function. A display NAME is an ENGINE STRING for a concrete adapter and
    an i18n KEY for NULL, and the FRAME resolves that key, so this module never calls getText
    - which would drag in g_i18n and break the pure run.

    Adapter contract (each method takes self via `:`):
      * adapter:getDisplayData()                  -> { name, used, total }
            name = engine string (concrete) | i18n KEY string (NULL).
      * adapter:enumerate(context)                -> array of list items
            context = { trailer, counterpart, counterpartHandle } - see below.
      * adapter:actionLabel(direction)            -> i18n KEY for the footer button
      * adapter:dispatch(direction, animals, context) -> boolean
            true when the transfer was performed; the shell NULL logs + returns
            false (no mutation), and the frame leaves all state unchanged on false.

    `context.counterpartHandle` is the engine ref a concrete adapter enumerates
    (a husbandry placeable for pen, a spawn-place/world set for world); the
    trigger-redirect slices populate it, and the shell + NULL adapter ignore it.

    DIR_INTO_TRAILER is the direction when the counterpart side is selected
    (animals flow counterpart -> trailer); DIR_OUT_OF_TRAILER when the trailer
    side is selected (trailer -> counterpart).
]]

RLTransferAdapter = {}

local Log = RmLogging.getLogger("RLRM")

-- =============================================================================
-- Constants
-- =============================================================================

-- Source-picker sides. The sidebar holds exactly two entries: the counterpart
-- and the trailer.
RLTransferAdapter.SIDE_COUNTERPART = "counterpart"
RLTransferAdapter.SIDE_TRAILER     = "trailer"

-- Transfer directions, derived from the selected side. Counterpart side selected
-- means loading the trailer; trailer side selected means unloading it.
RLTransferAdapter.DIR_INTO_TRAILER   = "into_trailer"
RLTransferAdapter.DIR_OUT_OF_TRAILER = "out_of_trailer"

-- i18n KEYS the frame resolves (kept here as keys, never getText'd, so the seam
-- stays pure). COUNTERPART_NAME_KEY is the NULL adapter's display name; the
-- load/unload keys are the footer action labels.
RLTransferAdapter.COUNTERPART_NAME_KEY = "rl_menu_transfer_counterpart"
RLTransferAdapter.LOAD_LABEL_KEY       = "rl_menu_transfer_load"
RLTransferAdapter.UNLOAD_LABEL_KEY     = "rl_menu_transfer_unload"

-- Shop action-label keys for the trailer move buttons. A concrete adapter
-- overrides the generic load/unload keys above with these so it needs no new
-- translation key (these keys ship in every locale).
RLTransferAdapter.MOVE_TO_TRAILER_KEY     = "shop_moveToTrailer"
RLTransferAdapter.MOVE_TO_FARM_KEY        = "shop_moveToFarm"
-- The world counterpart unloads rideables back to their spawn place, so its
-- unload label reads the base-game "move to spawn place" string instead of the
-- pen's "move to farm" (base-game AnimalScreenTrailer.L10N_SYMBOL.MOVE_TO_SPAWN_PLACE;
-- ships in every locale, so no new translation key).
RLTransferAdapter.MOVE_TO_SPAWN_PLACE_KEY = "shop_moveToSpawnPlace"

-- The world counterpart's sidebar display name (free rideables in the trigger
-- zone). The world adapter is in-game tier, so it getTexts this key itself and
-- returns an engine string; this constant just names the key in one place.
RLTransferAdapter.WORLD_NAME_KEY = "rl_menu_transfer_world"

-- The EPP (butcher) counterpart's footer action-label key. The butcher is a pure
-- sink - the only real action is delivering OUT of the trailer to it - so this key
-- reads "Deliver" rather than the pen's "move to farm" / world's "move to spawn
-- place". A NEW translation key (the deliver verb has no base-game analog), seeded
-- in every locale.
RLTransferAdapter.DELIVER_LABEL_KEY = "rl_menu_transfer_deliver"

-- =============================================================================
-- Pure helpers (dual-run boundary)
-- =============================================================================

--- The transfer direction implied by the selected source side. Trailer side
--- selected -> unload (out of trailer); any other side (counterpart) -> load.
--- @param side string  SIDE_COUNTERPART | SIDE_TRAILER
--- @return string direction  DIR_INTO_TRAILER | DIR_OUT_OF_TRAILER
function RLTransferAdapter.directionForSide(side)
    if side == RLTransferAdapter.SIDE_TRAILER then
        return RLTransferAdapter.DIR_OUT_OF_TRAILER
    end
    return RLTransferAdapter.DIR_INTO_TRAILER
end

--- The i18n KEY for the footer action label of a direction. OUT -> unload;
--- anything else (IN) -> load. Returns the KEY; the frame resolves it.
--- @param direction string  DIR_INTO_TRAILER | DIR_OUT_OF_TRAILER
--- @return string i18nKey
function RLTransferAdapter.actionLabelKey(direction)
    if direction == RLTransferAdapter.DIR_OUT_OF_TRAILER then
        return RLTransferAdapter.UNLOAD_LABEL_KEY
    end
    return RLTransferAdapter.LOAD_LABEL_KEY
end

--- Which source side to seed on open. An empty trailer biases toward the
--- counterpart side (the likely action is to load it); a loaded trailer biases
--- toward the trailer side (the likely action is to unload it). A nil / non-bool
--- emptiness (treated as "not known to be loaded") biases to the counterpart.
--- @param trailerIsEmpty boolean
--- @return string side  SIDE_COUNTERPART | SIDE_TRAILER
function RLTransferAdapter.initialSourceSide(trailerIsEmpty)
    if trailerIsEmpty == false then
        return RLTransferAdapter.SIDE_TRAILER
    end
    return RLTransferAdapter.SIDE_COUNTERPART
end

--- Compose a sidebar entry label as `name (used/total)`. Takes an ALREADY
--- RESOLVED name (engine string, or the frame-resolved NULL key text). Nil-safe:
--- a nil/empty name drops to a bare `(used/total)`; nil counts read as 0. Counts
--- render verbatim - `(0/0)` for an empty trailer and `used > total` are both
--- acceptable engine truths, not errors.
--- @param name string|nil  already-resolved display name
--- @param used number|nil
--- @param total number|nil
--- @return string label
function RLTransferAdapter.formatCapacityLabel(name, used, total)
    local safeUsed = used or 0
    local safeTotal = total or 0
    if name == nil or name == "" then
        return string.format("(%d/%d)", safeUsed, safeTotal)
    end
    return string.format("%s (%d/%d)", name, safeUsed, safeTotal)
end

--- Resolve the move plan - which side is source/target and the AnimalMoveEvent
--- moveType string - for a transfer direction. This carries the parity-critical
--- SOURCE/TARGET routing the legacy trailer-at-pen controller hard-coded: loading
--- the trailer fires moveType "SOURCE" (counterpart -> trailer); unloading fires
--- "TARGET" (trailer -> counterpart). A concrete adapter maps sourceSide /
--- targetSide onto its real objects and hands them to RLAnimalMoveService.
--- Fail-closed: any unknown / nil direction returns nil (the caller treats nil as
--- a no-op and never guesses an endpoint). Pure: dual-run boundary.
--- @param direction string  DIR_INTO_TRAILER | DIR_OUT_OF_TRAILER
--- @return table|nil plan  { sourceSide, targetSide, moveType } or nil
function RLTransferAdapter.resolveMovePlan(direction)
    if direction == RLTransferAdapter.DIR_INTO_TRAILER then
        return {
            sourceSide = RLTransferAdapter.SIDE_COUNTERPART,
            targetSide = RLTransferAdapter.SIDE_TRAILER,
            moveType   = "SOURCE",
        }
    elseif direction == RLTransferAdapter.DIR_OUT_OF_TRAILER then
        return {
            sourceSide = RLTransferAdapter.SIDE_TRAILER,
            targetSide = RLTransferAdapter.SIDE_COUNTERPART,
            moveType   = "TARGET",
        }
    end
    return nil
end

--- The legacy-parity i18n KEY for a pen transfer's footer action label. Loading
--- the trailer reads "move to trailer"; unloading reads "move to farm". Returns
--- the KEY (the frame resolves it); an unknown / nil direction defaults to the
--- move-to-trailer key (mirrors actionLabelKey's load default). Pure: dual-run.
--- @param direction string  DIR_INTO_TRAILER | DIR_OUT_OF_TRAILER
--- @return string i18nKey
function RLTransferAdapter.penActionLabelKey(direction)
    if direction == RLTransferAdapter.DIR_OUT_OF_TRAILER then
        return RLTransferAdapter.MOVE_TO_FARM_KEY
    end
    return RLTransferAdapter.MOVE_TO_TRAILER_KEY
end

--- The legacy-parity i18n KEY for a WORLD transfer's footer action label. Loading
--- the trailer reads "move to trailer"; unloading reads "move to spawn place" (the
--- base-game rideable-unload label, distinct from the pen's "move to farm"). Returns
--- the KEY (the frame resolves it); an unknown / nil direction defaults to the
--- move-to-trailer key (mirrors actionLabelKey / penActionLabelKey). Pure: dual-run.
--- @param direction string  DIR_INTO_TRAILER | DIR_OUT_OF_TRAILER
--- @return string i18nKey
function RLTransferAdapter.worldActionLabelKey(direction)
    if direction == RLTransferAdapter.DIR_OUT_OF_TRAILER then
        return RLTransferAdapter.MOVE_TO_SPAWN_PLACE_KEY
    end
    return RLTransferAdapter.MOVE_TO_TRAILER_KEY
end

--- The footer action-label i18n KEY for an EPP (butcher) transfer. The butcher is
--- a pure SINK: the only real action is delivering OUT of the trailer, which reads
--- "Deliver" (DELIVER_LABEL_KEY) - deliberately NOT a mirror of penActionLabelKey's
--- OUT (move-to-farm) / worldActionLabelKey's OUT (move-to-spawn-place). The reverse
--- (IN) direction is dead here (the counterpart enumerate is {}, so the butcher side
--- never has a live selection), but still returns the same valid key so a stray
--- layout read never getTexts nil. Returns the KEY (the frame resolves it). Pure:
--- dual-run boundary.
--- @param direction string  DIR_INTO_TRAILER | DIR_OUT_OF_TRAILER
--- @return string i18nKey
function RLTransferAdapter.eppActionLabelKey(direction)
    return RLTransferAdapter.DELIVER_LABEL_KEY
end

-- =============================================================================
-- NULL adapter (shell) - empty display, empty enumeration, no-op dispatch
-- =============================================================================

--- The shell adapter: lists nothing on the counterpart side and never mutates.
--- Used for both pen and world until the concrete adapters land. getDisplayData
--- returns an i18n KEY name (the frame resolves it) so the contract stays pure.
RLTransferAdapter.NULL = {
    --- @param _context table|nil  { trailer, counterpart, counterpartHandle } (ignored)
    --- @return table display  { name = i18n KEY, used = 0, total = 0 }
    getDisplayData = function(_self, _context)
        return {
            name  = RLTransferAdapter.COUNTERPART_NAME_KEY,
            used  = 0,
            total = 0,
        }
    end,

    --- @param _context table  { trailer, counterpart, counterpartHandle } (ignored)
    --- @return table items  always empty for the shell
    enumerate = function(_self, _context)
        return {}
    end,

    --- @param direction string  DIR_INTO_TRAILER | DIR_OUT_OF_TRAILER
    --- @return string i18nKey  generic load/unload label key
    actionLabel = function(_self, direction)
        return RLTransferAdapter.actionLabelKey(direction)
    end,

    --- No-op dispatch: logs and returns false so the frame leaves state
    --- unchanged (no event, no list change). Never mutates.
    --- @param direction string
    --- @param animals table|nil  selected animals (counted only)
    --- @param _context table
    --- @return boolean handled  always false
    dispatch = function(_self, direction, animals, _context)
        Log:debug("RLTransferAdapter.NULL:dispatch: no-op (direction=%s, %d animal(s)) - shell performs no transfer",
            tostring(direction), animals ~= nil and #animals or 0)
        return false
    end,
}

-- =============================================================================
-- Adapter selection
-- =============================================================================

-- Registry of concrete adapters keyed by counterpart string. Empty in the shell;
-- the pen / world slices register their adapters here. forCounterpart falls back
-- to NULL for any counterpart with no registered adapter.
RLTransferAdapter._adapters = {}

--- Pick the adapter for a counterpart. Returns the registered concrete adapter,
--- or NULL when none is registered (the shell registers none, so every
--- counterpart - including nil - resolves to NULL).
--- @param counterpart string|nil  RLMenu.TRAILER_PEN / TRAILER_WORLD / ...
--- @return table adapter
function RLTransferAdapter.forCounterpart(counterpart)
    local adapter = RLTransferAdapter._adapters[counterpart]
    if adapter == nil then
        Log:trace("RLTransferAdapter.forCounterpart: counterpart=%s -> NULL (no concrete adapter)",
            tostring(counterpart))
        return RLTransferAdapter.NULL
    end
    Log:trace("RLTransferAdapter.forCounterpart: counterpart=%s -> concrete adapter", tostring(counterpart))
    return adapter
end

Log:debug("RLTransferAdapter: loaded (shell - NULL adapter only)")
