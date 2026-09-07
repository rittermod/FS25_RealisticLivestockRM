-- RLMenuHusbandryAnchor.lua
-- Pure decision helper for the RL Tabbed Menu's one-shot MODE_FULL husbandry anchor. Plain data
-- in, plain data out - no g_*, no GUI, no XML handles - so the whole module loads and runs under
-- the headless harness.
--
-- resolveIndex answers ONE question for a husbandry frame's refresh: which entry in the farm's
-- sorted husbandry list should land selected. It prefers the caller-supplied one-shot anchor,
-- then the persistent shared selection, then the first entry, and returns the 1-based index plus
-- an anchorMatched boolean so the caller can log a resolved-to-anchor open distinctly from an
-- anchor MISS - a valid pen that is not in this farm's list, foreign, stale or sold, which
-- silently falls back.
--
-- Comparison is object identity on the placeable refs, matching the frames' shared-selection
-- match. TOTAL: a nil or empty list, or nil refs, resolve to (1, false) rather than erroring.

RLMenuHusbandryAnchor = {}

--- Resolve which husbandry index a frame should land on, preferring the one-shot anchor over the
--- persistent shared selection over the first entry.
--- @param sortedHusbandries table|nil ordered husbandry placeables (the frame's list)
--- @param anchorHusbandry table|nil the one-shot anchor placeable (nil when unanchored)
--- @param sharedHusbandry table|nil the persistent shared-selection placeable (nil when none)
--- @return integer index 1-based index into sortedHusbandries (1 when the list is empty)
--- @return boolean anchorMatched true iff the anchor was found in the list
function RLMenuHusbandryAnchor.resolveIndex(sortedHusbandries, anchorHusbandry, sharedHusbandry)
    local n = (sortedHusbandries ~= nil) and #sortedHusbandries or 0
    if n == 0 then return 1, false end

    local function indexOf(ref)
        if ref == nil then return nil end
        for i = 1, n do
            if sortedHusbandries[i] == ref then return i end
        end
        return nil
    end

    local anchorIndex = indexOf(anchorHusbandry)
    if anchorIndex ~= nil then return anchorIndex, true end

    return (indexOf(sharedHusbandry) or 1), false
end
