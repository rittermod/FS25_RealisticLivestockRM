-- RLFilterUsage.lua
-- Canonical enum + validator for the saveable-filter `usage` scope axis, which controls
-- which consumer frames a filter appears on in the F-cycle picker. Three states, matching
-- the `nil-or-equal` rule the other scope axes (`animalType`, `farmId`) use:
--
--   * `ANY`    - visible on every consumer frame (Info/Sell/Move/Buy).
--   * `OWNED`  - visible only on owned-herd frames (Info/Sell/Move).
--   * `DEALER` - visible only on dealer frames (Buy).
--
-- The single source of truth for the canonical string values and their wire-byte encoding.
-- Boundary sites - serialization, wire codec, service CRUD, GUI callbacks - reference these
-- constants rather than inline literals, so the rule and its warning live in one place.

local Log = RmLogging.getLogger("RLRM")

RLFilterUsage = {}

-- =============================================================================
-- Canonical constants
-- =============================================================================

--- Visible everywhere. The default for a new filter and for a legacy filter loaded from a
--- save with no `usage` attribute.
RLFilterUsage.ANY = "ANY"

--- Visible on owned-herd frames only (Info / Sell / Move).
RLFilterUsage.OWNED = "OWNED"

--- Visible on dealer frames only (Buy).
RLFilterUsage.DEALER = "DEALER"

--- Forward wire-byte map. FROZEN: 0 = ANY, 1 = OWNED, 2 = DEALER, with 3-255 reserved so the
--- enum can widen later. The default sits at byte zero, so an all-zeroes stream decodes to
--- the wildcard rather than to a bucket.
RLFilterUsage.BYTE = {
    [RLFilterUsage.ANY]    = 0,
    [RLFilterUsage.OWNED]  = 1,
    [RLFilterUsage.DEALER] = 2,
}

--- Inverse wire-byte map. A reserved byte is absent here, and the wire reader coerces it to
--- ANY with a warning at the read site.
RLFilterUsage.FROM_BYTE = {
    [0] = RLFilterUsage.ANY,
    [1] = RLFilterUsage.OWNED,
    [2] = RLFilterUsage.DEALER,
}

-- =============================================================================
-- Validator
-- =============================================================================

--- Validate a NON-NIL `usage` value, failing open: an unrecognised value warns and returns
--- ANY. Callers must guard with an explicit `value ~= nil` branch, because nil means
--- something different at every site - a silent default on create and on an absent XML attr,
--- a rejection on update, and unreachable on the wire, which always carries one UInt8.
--- Calling it with nil warns defensively and returns ANY.
---@param value any non-nil value to validate
---@return string canonical canonical usage string (one of ANY/OWNED/DEALER)
function RLFilterUsage.coerce(value)
    if value == RLFilterUsage.ANY
        or value == RLFilterUsage.OWNED
        or value == RLFilterUsage.DEALER then
        return value
    end

    Log:warning("RLFilterUsage.coerce: unknown value '%s' (%s) coerced to ANY",
        tostring(value), type(value))
    return RLFilterUsage.ANY
end
