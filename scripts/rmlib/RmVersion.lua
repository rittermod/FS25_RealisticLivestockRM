-- ============================================================================
-- RmVersion - Mod version / release-channel detection for Ritter Mods
-- ============================================================================
-- Usage:
--   local Log = RmLogging.getLogger("MyModName")
--   local Ver = RmVersion.forMod(g_currentModName, Log)
--   Ver:applyBuildLogLevel()          -- DEBUG unless this is a released stable build
--   if Ver:isDevelopmentVersion() then ... end
--   Log:info("Running %s", Ver:describe())
--
-- Two INDEPENDENT axes, both derived from the modDesc version string:
--
--   Axis 1 - maturity TIER (first non-zero component from the left):
--     >= 1.0.0.0   -> released     (e.g. 1.0.0.0, 2.3.1.0)
--     0.x.x.x      -> beta         (minor > 0,  e.g. 0.6.0.0)
--     0.0.x.x      -> alpha        (patch > 0,  e.g. 0.0.2.0)
--     0.0.0.x      -> experiment   (e.g. 0.0.0.1, 0.0.0.0)
--
--   Axis 2 - release CHANNEL (suffix):
--     x.x.x.x-dev / -dev.N -> development
--     x.x.x.x              -> stable
--
-- The axes do not constrain each other: "1.0.0.0-dev.1" is released +
-- development, "0.0.0.1" is experiment + stable. isStableVersion() therefore
-- answers axis 2 ONLY - use isProductionVersion() for "released AND stable".
--
-- Any suffix that is not a recognized -dev form (e.g. "-rc.1", "-dev 2",
-- "-dev.1-hotfix") is a PARSE FAILURE, not a stable version. Guessing "stable"
-- for an unrecognized suffix would make a release candidate indistinguishable
-- from a shipped release; failing to parse keeps every predicate false instead.
--
-- LOGGING: the caller supplies its own logger, which this module then uses for
-- every message. Nothing is keyed by mod name, so `rmSetLoglevel <YourLogger>`
-- governs these diagnostics like any other line the mod emits.
-- ============================================================================

-- Idempotent initialization (safe to source multiple times)
-- FS25 sandbox: _G is modEnv with setmetatable(modEnv, {__index = realGlobal})
-- Both _G.X= and getfenv(0) write to modEnv. The metatable __index holds the real global.
local _mt = getmetatable(_G)
local _realG = _mt and _mt.__index or _G
_realG.RmVersion = _realG.RmVersion or {}
RmVersion = _realG.RmVersion

-- Maturity tiers (axis 1) - preserve if already set
RmVersion.TIER = RmVersion.TIER or {
    EXPERIMENT = "experiment",
    ALPHA      = "alpha",
    BETA       = "beta",
    RELEASED   = "released"
}

-- Release channels (axis 2) - preserve if already set
RmVersion.CHANNEL = RmVersion.CHANNEL or {
    DEVELOPMENT = "development",
    STABLE      = "stable"
}

-- Registry of per-mod instances (preserve across multiple sources)
RmVersion._mods = RmVersion._mods or {}

-- Maximum number of dot-separated components in a modDesc version (a.b.c.d)
local MAX_COMPONENTS = 4

-- ============================================================================
-- Pure Parsing
-- ============================================================================
-- No game globals, no RmLogging, no side effects of any kind - source this file
-- alone into a bare Lua interpreter and RmVersion.parse works. Callers own the
-- logging of parse outcomes, because only they know which logger to use.

---Trim leading/trailing whitespace
---@param s string
---@return string
local function trim(s)
    return (string.gsub(s, "^%s*(.-)%s*$", "%1"))
end

---Split on a literal "." preserving empty fields, so "1..0" is rejected
---@param s string
---@return table Array of string fields
local function splitOnDot(s)
    local fields = {}
    local startIdx = 1

    while true do
        local dotAt = string.find(s, ".", startIdx, true)
        if dotAt == nil then
            table.insert(fields, string.sub(s, startIdx))
            break
        end
        table.insert(fields, string.sub(s, startIdx, dotAt - 1))
        startIdx = dotAt + 1
    end

    return fields
end

---Classify the maturity tier from the first non-zero component
---@param major number
---@param minor number
---@param patch number
---@return string One of RmVersion.TIER
local function classifyTier(major, minor, patch)
    if major >= 1 then
        return RmVersion.TIER.RELEASED
    elseif minor >= 1 then
        return RmVersion.TIER.BETA
    elseif patch >= 1 then
        return RmVersion.TIER.ALPHA
    end
    return RmVersion.TIER.EXPERIMENT
end

---Parse a modDesc version string into a structured, classified description.
---Pure function: no globals, no logging, no side effects.
---Accepts 1 to 4 dot-separated integer components (missing ones default to 0)
---and an optional development suffix ("dev", "dev.N", "devN", any casing).
---Any other suffix is a parse failure rather than an assumed stable channel.
---
---The returned table's shape is part of this module's contract:
---  raw          string  the input, verbatim and untrimmed
---  tuple        table   exactly 4 numbers, zero-padded
---  major        number  tuple[1]
---  minor        number  tuple[2]
---  patch        number  tuple[3]
---  build        number  tuple[4]
---  suffix       string  the recognized suffix, or nil when there was none
---  tier         string  one of RmVersion.TIER
---  channel      string  one of RmVersion.CHANNEL
---  devIteration number  N from "-dev.N", 0 for a bare "-dev", nil when stable
---@param versionStr string|nil Version string, e.g. "1.0.0.0-dev.1"
---@return table|nil info Parsed info, or nil on failure
---@return string|nil reason Failure reason when info is nil
function RmVersion.parse(versionStr)
    if type(versionStr) ~= "string" then
        return nil, string.format("version must be a string, got %s", type(versionStr))
    end

    local s = trim(versionStr)
    if s == "" then
        return nil, "version is empty"
    end

    -- Split "1.0.0.0-dev.1" into base "1.0.0.0" and suffix "dev.1"
    local base, suffix
    local dashAt = string.find(s, "-", 1, true)
    if dashAt ~= nil then
        base = string.sub(s, 1, dashAt - 1)
        suffix = string.sub(s, dashAt + 1)
        if suffix == "" then
            return nil, string.format("trailing '-' with no suffix in '%s'", s)
        end
    else
        base = s
    end

    -- Numeric components
    local fields = splitOnDot(base)
    if #fields > MAX_COMPONENTS then
        return nil, string.format("more than %d components in '%s'", MAX_COMPONENTS, s)
    end

    local tuple = {}
    for _, field in ipairs(fields) do
        if string.match(field, "^%d+$") == nil then
            return nil, string.format("non-numeric component '%s' in '%s'", field, s)
        end
        table.insert(tuple, tonumber(field))
    end

    while #tuple < MAX_COMPONENTS do
        table.insert(tuple, 0)
    end

    -- Suffix: only a recognized -dev form is accepted. Anything else fails to
    -- parse, so a release candidate never masquerades as a stable release.
    local channel = RmVersion.CHANNEL.STABLE
    local devIteration = nil

    if suffix ~= nil then
        local tag, num = string.match(string.lower(suffix), "^(%a+)%.?(%d*)$")
        if tag ~= "dev" then
            return nil, string.format("unrecognized suffix '%s' in '%s' - only '-dev' and " ..
                "'-dev.N' are recognized", suffix, s)
        end
        channel = RmVersion.CHANNEL.DEVELOPMENT
        devIteration = tonumber(num) or 0
    end

    return {
        raw = versionStr,
        tuple = tuple,
        major = tuple[1],
        minor = tuple[2],
        patch = tuple[3],
        build = tuple[4],
        suffix = suffix,
        tier = classifyTier(tuple[1], tuple[2], tuple[3]),
        channel = channel,
        devIteration = devIteration
    }
end

-- ============================================================================
-- Logger Contract
-- ============================================================================

---Whether a value satisfies the logger contract this module relies on.
---Checked once at construction so no method can half-apply a change and then
---fail on a missing logging call.
---@param logger any
---@return boolean
local function isUsableLogger(logger)
    return type(logger) == "table"
        and logger.level ~= nil
        and type(logger.debug) == "function"
        and type(logger.info) == "function"
        and type(logger.warning) == "function"
        and type(logger.error) == "function"
end

-- ============================================================================
-- RmModVersion Class (per-mod instance)
-- ============================================================================

local RmModVersion = {}
RmModVersion.__index = RmModVersion

---Create an instance around a parsed info table
---@param modName string|nil Mod name this instance describes
---@param info table|nil Parsed info from RmVersion.parse, nil when unresolvable
---@param raw string|nil Raw version string, kept even when parsing failed
---@param logger table|nil The caller's logger, already contract-checked
---@return table Instance
function RmModVersion:new(modName, info, raw, logger)
    local instance = setmetatable({}, RmModVersion)
    instance.modName = modName
    instance.info = info
    instance.raw = raw
    instance.logger = logger
    return instance
end

---Whether the version could not be resolved or parsed.
---An unknown instance answers false to EVERY other predicate, so callers
---fail closed - no development-only behaviour is enabled by accident.
---The one deliberate exception is applyBuildLogLevel; see its note.
---@return boolean
function RmModVersion:isUnknown()
    return self.info == nil
end

---Raw version string as declared in modDesc.xml
---@return string|nil
function RmModVersion:getVersionString()
    return self.raw
end

---Numeric components as a copy, always 4 long
---@return table|nil Array {major, minor, patch, build}
function RmModVersion:getTuple()
    if self.info == nil then
        return nil
    end

    local copy = {}
    for i, v in ipairs(self.info.tuple) do
        copy[i] = v
    end
    return copy
end

---Maturity tier (axis 1)
---@return string|nil One of RmVersion.TIER
function RmModVersion:getTier()
    return self.info ~= nil and self.info.tier or nil
end

---Release channel (axis 2)
---@return string|nil One of RmVersion.CHANNEL
function RmModVersion:getChannel()
    return self.info ~= nil and self.info.channel or nil
end

---Iteration number from a "-dev.N" suffix (0 for a bare "-dev")
---@return number|nil nil when not a development version
function RmModVersion:getDevIteration()
    return self.info ~= nil and self.info.devIteration or nil
end

-- Axis 1 predicates

---@return boolean True for 0.0.0.x (including 0.0.0.0)
function RmModVersion:isExperimentVersion()
    return self:getTier() == RmVersion.TIER.EXPERIMENT
end

---@return boolean True for 0.0.x.x with patch > 0
function RmModVersion:isAlphaVersion()
    return self:getTier() == RmVersion.TIER.ALPHA
end

---@return boolean True for 0.x.x.x with minor > 0
function RmModVersion:isBetaVersion()
    return self:getTier() == RmVersion.TIER.BETA
end

---@return boolean True for >= 1.0.0.0
function RmModVersion:isReleasedVersion()
    return self:getTier() == RmVersion.TIER.RELEASED
end

---@return boolean True for any tier below released (experiment, alpha, beta)
function RmModVersion:isPreReleaseVersion()
    local tier = self:getTier()
    return tier ~= nil and tier ~= RmVersion.TIER.RELEASED
end

-- Axis 2 predicates

---@return boolean True when the version carries a "-dev" suffix
function RmModVersion:isDevelopmentVersion()
    return self:getChannel() == RmVersion.CHANNEL.DEVELOPMENT
end

---@return boolean True when the version carries no "-dev" suffix (axis 2 only)
function RmModVersion:isStableVersion()
    return self:getChannel() == RmVersion.CHANNEL.STABLE
end

-- Combined predicate

---@return boolean True only for a released version with no "-dev" suffix
function RmModVersion:isProductionVersion()
    return self:isReleasedVersion() and self:isStableVersion()
end

---Set this mod's logger level from its build: DEBUG for anything that is not a
---released stable build, INFO otherwise.
---
---DELIBERATE EXCEPTION to fail-closed: an unknown version yields DEBUG, because
---for a log level erring towards more output is the safer failure. Every other
---predicate stays false on an unknown instance.
---
---Note the level is only INFO-by-construction for major >= 1. A 0.x version has
---no -dev suffix once released, yet its tier is alpha/beta/experiment, so it
---still gets DEBUG - which is correct, a 0.x mod is pre-release by definition.
---
---The level is ASSIGNED rather than pushed through logger:setLevel(), deliberately:
---it keeps the mod's call site free of a literal debug level. Do not "simplify" this
---to setLevel().
---@return number|nil level The level applied, or nil when there is no logger
function RmModVersion:applyBuildLogLevel()
    local logger = self.logger
    if logger == nil then
        print(string.format("[RmVersion] applyBuildLogLevel needs a logger; this instance " ..
            "(%s) was built without one. Log level left untouched.", self:describe()))
        return nil
    end

    local isDebugBuild = not self:isReleasedVersion() or self:isDevelopmentVersion()
    logger.level = isDebugBuild and RmLogging.LOG_LEVEL.DEBUG or RmLogging.LOG_LEVEL.INFO

    if isDebugBuild then
        logger:info("Log level set to DEBUG (not a released stable build)")
    else
        logger:info("Log level set to INFO (released stable build)")
    end

    return logger.level
end

---Human-readable summary for log lines
---@return string e.g. "1.0.0.0-dev.1 (released, development)"
function RmModVersion:describe()
    if self.info == nil then
        return string.format("%s (unknown version)",
            self.raw or ("mod " .. tostring(self.modName)))
    end
    return string.format("%s (%s, %s)", self.info.raw, self.info.tier, self.info.channel)
end

-- ============================================================================
-- Version Resolution
-- ============================================================================
-- Split into two named readers so each can be exercised directly by a test
-- against the real game APIs, rather than being reachable only through forMod.

---Read a mod's declared version from the mod manager.
---This is the normal path: loadModDesc() registers every mod (and its version)
---before loadMod() sources any extraSourceFiles, so it resolves even when
---called from a mod's main.lua.
---@param modName string
---@return string|nil version
function RmVersion._readVersionFromModManager(modName)
    if g_modManager == nil or g_modManager.getModByName == nil then
        return nil
    end

    local mod = g_modManager:getModByName(modName)
    if mod == nil or mod.version == nil or mod.version == "" then
        return nil
    end
    return mod.version
end

---Read a mod's declared version straight from its modDesc.xml.
---Fallback for contexts that run before mod registration - an internal mod's
---preLoadSourceFiles block.
---@param modName string
---@return string|nil version
function RmVersion._readVersionFromModDesc(modName)
    local modDir = nil
    if g_modNameToDirectory ~= nil then
        modDir = g_modNameToDirectory[modName]
    end
    if modDir == nil and modName == g_currentModName then
        modDir = g_currentModDirectory
    end
    if modDir == nil or XMLFile == nil then
        return nil
    end

    local path = modDir .. "modDesc.xml"
    if not fileExists(path) then
        return nil
    end

    local xmlFile = XMLFile.load("rmVersionModDesc", path)
    if xmlFile == nil then
        return nil
    end

    local version = xmlFile:getString("modDesc.version")
    xmlFile:delete()

    if version == nil or version == "" then
        return nil
    end
    return version
end

---Resolve the declared version string for a mod, mod manager first.
---@param modName string
---@return string|nil version
---@return string|nil source Where the version came from, for logging
local function resolveVersionString(modName)
    local version = RmVersion._readVersionFromModManager(modName)
    if version ~= nil then
        return version, "g_modManager"
    end

    version = RmVersion._readVersionFromModDesc(modName)
    if version ~= nil then
        return version, "modDesc.xml"
    end

    return nil, nil
end

-- ============================================================================
-- Factory Methods
-- ============================================================================

---Get or create the version instance for a mod, resolved from its modDesc.
---Successful resolutions are cached per mod name; failures are NOT cached, so a
---call made too early (before mod registration) does not poison every later one.
---@param modName string Mod name - g_currentModName, i.e. the archive/directory
---name that g_modManager is keyed by, NOT the mod's title
---@param logger table The mod's own RmLogging instance; used for every message
---this module emits about that mod
---@return table Instance - never nil; use :isUnknown() to detect failure
function RmVersion.forMod(modName, logger)
    if type(modName) ~= "string" or modName == "" then
        print(string.format("[RmVersion] forMod requires a mod name string, got %s (%s)",
            tostring(modName), type(modName)))
        return RmModVersion:new(nil, nil, nil, isUsableLogger(logger) and logger or nil)
    end

    if not isUsableLogger(logger) then
        print(string.format("[RmVersion] forMod('%s') requires the mod's logger (an " ..
            "RmLogging instance), got %s. Returning an unknown version.", modName, type(logger)))
        return RmModVersion:new(modName, nil, nil, nil)
    end

    local cached = RmVersion._mods[modName]
    if cached ~= nil then
        return cached
    end

    local versionStr, source = resolveVersionString(modName)

    if versionStr == nil then
        logger:error("Could not resolve a version for mod '%s' - every RmVersion predicate " ..
            "will answer false. Not cached, so a later call can still succeed.", modName)
        return RmModVersion:new(modName, nil, nil, logger)
    end

    local info, reason = RmVersion.parse(versionStr)
    if info == nil then
        logger:error("Unparseable version '%s' for mod '%s' (from %s): %s - every RmVersion " ..
            "predicate will answer false", versionStr, modName, tostring(source), tostring(reason))
        return RmModVersion:new(modName, nil, versionStr, logger)
    end

    local instance = RmModVersion:new(modName, info, versionStr, logger)
    RmVersion._mods[modName] = instance
    logger:debug("Version %s resolved from %s", instance:describe(), source)
    return instance
end

---Build an uncached instance from an explicit version string.
---For tests, and for classifying a version that is not this mod's own.
---@param versionStr string|nil Version string, e.g. "0.6.0.0-dev.2"
---@param logger table|nil Optional logger; when given, a parse failure is
---reported through it, and applyBuildLogLevel can act on it
---@return table Instance - never nil; use :isUnknown() to detect failure
function RmVersion.forVersionString(versionStr, logger)
    local usableLogger = isUsableLogger(logger) and logger or nil
    local info, reason = RmVersion.parse(versionStr)

    if info == nil and usableLogger ~= nil then
        usableLogger:error("Unparseable version '%s': %s - every RmVersion predicate will " ..
            "answer false", tostring(versionStr), tostring(reason))
    end

    return RmModVersion:new(nil, info,
        type(versionStr) == "string" and versionStr or nil, usableLogger)
end
