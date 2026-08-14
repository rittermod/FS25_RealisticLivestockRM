--[[
    RLVersionSpec.lua
    Version parsing, normalization, comparison, and specifier matching.

    Implements a subset of the Python packaging version spec:
    - Pre-release normalization (alpha/beta/rc/dev with case/separator tolerance)
    - Structured comparison (dev < a < b < rc < release)
    - Specifier matching with < exclusion rule for pre-releases
    - Operators: >=, <=, >, <, ==, !=

    Most map/mod versions seems to match something like the Python packaging spec,
    so this should provide robust handling of version strings and constraints in mod metadata.
    Reference: https://packaging.python.org/en/latest/specifications/version-specifiers/
    Reference impl: https://github.com/pypa/packaging/blob/main/src/packaging/specifiers.py
]]

RLVersionSpec = {}

local Log = RmLogging.getLogger("RLRM")


--- Pre-release tag normalization table.
--- Maps recognized tags (lowercase) to a numeric type order for comparison.
--- Ordering: dev(0) < alpha(1) < beta(2) < rc(3) < release(nil)
--- Tags per Python packaging spec regex: a|b|c|rc|alpha|beta|pre|preview + dev
local PRE_RELEASE_TAGS = {
    alpha = 1,
    a = 1,
    beta = 2,
    b = 2,
    preview = 3,
    pre = 3,
    c = 3,
    rc = 3,
    dev = 0
}


--- Supported operators for version specifier matching.
--- Maps operator string to a function that evaluates a compareVersions result.
local VERSION_SPEC_OPS = {
    [">="] = function(cmp) return cmp >= 0 end,
    ["<="] = function(cmp) return cmp <= 0 end,
    [">"]  = function(cmp) return cmp > 0 end,
    ["<"]  = function(cmp) return cmp < 0 end,
    ["=="] = function(cmp) return cmp == 0 end,
    ["!="] = function(cmp) return cmp ~= 0 end
}


--- Normalize a raw pre-release suffix string into a structured object.
--- Strips separator characters (dot, dash, underscore), extracts the tag and optional number,
--- and maps to a canonical type order for comparison.
--- @param rawSuffix string|nil Raw suffix (e.g. "Beta1", "b.1", "RC-1", "dev3", "alpha")
--- @return table|nil pre { typeOrder = number, num = number } or nil if unrecognized
function RLVersionSpec.normalizeSuffix(rawSuffix)
    if rawSuffix == nil then
        return nil
    end

    -- Strip dots, dashes, underscores used as separators within the suffix
    -- "b.1" -> "b1", "beta-1" -> "beta1", "RC_1" -> "RC1"
    local cleaned = rawSuffix:gsub("[%.%-_]", "")

    -- Extract alpha tag and optional numeric part: "Beta1" -> "Beta","1"; "b2" -> "b","2"; "dev" -> "dev",""
    local tag, numStr = cleaned:match("^(%a+)(%d*)$")
    if tag == nil then
        return nil
    end

    local typeOrder = PRE_RELEASE_TAGS[tag:lower()]
    if typeOrder == nil then
        return nil
    end

    local num = tonumber(numStr) or 0
    return { typeOrder = typeOrder, num = num }
end

--- Parse a version string into a structured version object.
--- Handles version strings with pre-release suffixes in various formats:
---   Space/dash/underscore separator: "1.4.0.0 Beta1", "1.4.0.0-RC1", "1.4.0.0_beta1"
---   No separator (attached):         "1.4.0.0a1", "1.4.0.0beta1"
---   Dot-separated suffix:            "1.4.0.0.beta1", "1.4.0.0.b.1"
--- Strips optional leading 'v'/'V' prefix and surrounding whitespace.
--- @param versionStr string|nil Version string (e.g. "1.3.0.1", "v1.4.0.0 Beta1", "1.4.0.0.b.1")
--- @return table|nil version { tuple={numbers}, suffix=string|nil, pre={typeOrder,num}|nil }
function RLVersionSpec.parseVersion(versionStr)
    if versionStr == nil then
        return nil
    end

    -- Trim whitespace and strip optional 'v' prefix (per packaging spec)
    local s = versionStr:match("^%s*[vV]?(.-)%s*$")
    if s == nil or s == "" then
        return nil
    end

    local parts = string.split(s, ".")
    local tuple = {}
    local suffix = nil

    for i, part in ipairs(parts) do
        local num = tonumber(part)
        if num ~= nil then
            table.insert(tuple, num)
        else
            -- Try extracting leading digits with space/dash/underscore separator:
            -- "0 Beta1" -> 0, "Beta1"; "0-RC1" -> 0, "RC1"; "0_beta1" -> 0, "beta1"
            local digits, trail = part:match("^(%d+)[%s%-_](.+)$")
            if digits == nil then
                -- Try digits directly followed by alpha (no separator):
                -- "0beta1" -> 0, "beta1"; "0a1" -> 0, "a1"
                digits, trail = part:match("^(%d+)(%a.+)$")
            end

            if digits ~= nil then
                table.insert(tuple, tonumber(digits))
                -- trail + remaining dot-parts form the raw suffix
                local remaining = { trail }
                for j = i + 1, #parts do
                    table.insert(remaining, parts[j])
                end
                suffix = table.concat(remaining, ".")
            else
                -- No leading digits - part + remaining parts are the suffix
                -- e.g., "beta1" from "1.4.0.0.beta1", or "b" from "1.4.0.0.b.1"
                local remaining = {}
                for j = i, #parts do
                    table.insert(remaining, parts[j])
                end
                suffix = table.concat(remaining, ".")
            end

            -- Validate: suffix must normalize to a recognized pre-release tag
            local pre = RLVersionSpec.normalizeSuffix(suffix)
            if pre == nil then
                Log:debug("VersionSpec: Unrecognized version suffix '%s' in '%s'", suffix, versionStr)
                return nil
            end

            break
        end
    end

    -- Build pre-release object from suffix (nil for release versions)
    local pre = nil
    if suffix ~= nil then
        pre = RLVersionSpec.normalizeSuffix(suffix)
    end

    return { tuple = tuple, suffix = suffix, pre = pre }
end

--- Compare two version objects component by component.
--- Accepts both structured format ({ tuple, suffix, pre }) and plain arrays (backward compat).
--- Treats missing tuple components as 0 (e.g. {1,3} == {1,3,0,0}).
--- When tuples are equal, uses normalized pre-release comparison:
---   nil (release) > any pre-release
---   dev(0) < alpha(1) < beta(2) < rc(3) < release(nil)
--- Falls back to lexicographic suffix comparison for unrecognized suffixes.
--- @param a table Version object or plain tuple
--- @param b table Version object or plain tuple
--- @return number result Negative if a < b, 0 if equal, positive if a > b
function RLVersionSpec.compareVersions(a, b)
    -- Extract tuple, suffix, and pre - supporting both formats
    local aTuple = a.tuple or a
    local aSuffix = a.tuple and a.suffix or nil
    local aPre = a.tuple and a.pre or nil
    local bTuple = b.tuple or b
    local bSuffix = b.tuple and b.suffix or nil
    local bPre = b.tuple and b.pre or nil

    local maxLen = math.max(#aTuple, #bTuple)
    for i = 1, maxLen do
        local ai = aTuple[i] or 0
        local bi = bTuple[i] or 0
        if ai ~= bi then
            return ai - bi
        end
    end

    -- Tuples equal - compare pre-release status
    -- nil (release) > any suffix (pre-release)
    if aSuffix == nil and bSuffix == nil then
        return 0
    elseif aSuffix == nil then
        return 1  -- a is release, b has suffix -> a > b
    elseif bSuffix == nil then
        return -1 -- a has suffix, b is release -> a < b
    end

    -- Both have suffixes - use normalized pre-release comparison when available
    if aPre ~= nil and bPre ~= nil then
        if aPre.typeOrder ~= bPre.typeOrder then
            return aPre.typeOrder - bPre.typeOrder
        end
        return aPre.num - bPre.num
    end

    -- Fallback: lexicographic comparison for unrecognized suffixes
    if aSuffix < bSuffix then
        return -1
    elseif aSuffix > bSuffix then
        return 1
    else
        return 0
    end
end

--- Check if a version satisfies a Python-style version specifier string.
--- Spec format: comma-separated constraints (AND logic), each is <operator><version>.
--- Supported operators: >=, <=, >, <, ==, !=
--- The < operator excludes pre-releases of the specified version (per packaging spec):
---   <1.4.0.0 returns false for 1.4.0.0 Beta1 (same base, pre-release excluded)
---   <1.4.0.0 returns true for 1.3.0.0 dev1 (different base, not excluded)
--- Whitespace around operators and between constraints is tolerated.
--- @param versionStr string|nil Version to check (e.g. "1.4.0.0", "1.4.0.0 Beta1")
--- @param specStr string|nil Specifier (e.g. ">=1.3.0.0,<1.5.0.0")
--- @return boolean matches True if version satisfies ALL constraints (nil/empty spec = true)
function RLVersionSpec.matchesVersionSpec(versionStr, specStr)
    if specStr == nil or specStr == "" then
        return true
    end

    local version = RLVersionSpec.parseVersion(versionStr)
    if version == nil then
        return false
    end

    local constraints = string.split(specStr, ",")

    for _, constraint in ipairs(constraints) do
        -- Trim surrounding whitespace
        constraint = constraint:match("^%s*(.-)%s*$")
        if constraint ~= "" then
            -- Extract operator (one or two chars from ><=!) and version string
            local op, verStr = constraint:match("^([><=!]+)%s*(.+)$")
            if op == nil then
                Log:warning("VersionSpec: malformed version constraint: '%s' in spec '%s'", constraint, specStr)
                return false
            end

            local evalOp = VERSION_SPEC_OPS[op]
            if evalOp == nil then
                Log:warning("VersionSpec: unknown version operator '%s' in spec '%s'", op, specStr)
                return false
            end

            local specVersion = RLVersionSpec.parseVersion(verStr)
            if specVersion == nil then
                Log:warning("VersionSpec: unparseable version '%s' in spec '%s'", verStr, specStr)
                return false
            end

            local cmp = RLVersionSpec.compareVersions(version, specVersion)

            -- PEP 440 < exclusion: pre-releases of the spec version are excluded from <V
            -- when V is a release (no pre-release suffix). This prevents ">=1.3,<1.4" from
            -- capturing 1.4 betas. Reference: pypa/packaging specifiers.py _compare_less_than
            if op == "<" and version.pre ~= nil and specVersion.pre == nil then
                local tupleCmp = RLVersionSpec.compareVersions(
                    { tuple = version.tuple },
                    { tuple = specVersion.tuple }
                )
                if tupleCmp == 0 then
                    return false
                end
            end

            if not evalOp(cmp) then
                return false
            end
        end
    end

    return true
end
