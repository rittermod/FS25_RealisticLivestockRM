--[[
    BreedingMath.lua
    Mathematical functions for genetic inheritance calculations using Gaussian distribution.

    Allows offspring genetics to exceed or fall below parent ranges through
    probabilistic inheritance based on normal distribution.

    Based on RLAdjust implementation by Ritter.
    Integrated into RealisticLivestockRM.
]]

BreedingMath = {}

-- Module constants
-- Choose a constant within-family SD (here: 10% of range 0.25..1.75)
BreedingMath.SD_CONST = 0.10 * (1.75 - 0.25) -- 0.15

---Clamps a value between low and high bounds
---@param x number Value to clamp
---@param lo number Lower bound
---@param hi number Upper bound
---@return number Clamped value
local function clamp(x, lo, hi)
    if x < lo then return lo end
    if x > hi then return hi end
    return x
end

---Standard normal RNG using Box-Muller transform
---@return number Standard normal random value
local function randn()
    local u1, u2 = 0.0, 0.0
    repeat u1 = math.random() until u1 > 0.0 -- avoid log(0)
    u2 = math.random()
    return math.sqrt(-2.0 * math.log(u1)) * math.cos(2.0 * math.pi * u2)
end

---Error function approximation (Abramowitz & Stegun 7.1.26)
---@param x number Input value
---@return number Error function value
local function erf(x)
    local sign = 1.0
    if x < 0 then
        sign = -1.0
        x = -x
    end
    local t = 1.0 / (1.0 + 0.3275911 * x)
    local a1, a2, a3, a4, a5 = 0.254829592, -0.284496736, 1.421413741, -1.453152027, 1.061405429
    local y = 1.0 - (((((a5 * t + a4) * t) + a3) * t + a2) * t + a1) * t * math.exp(-x * x)
    return sign * y
end

---Standard normal CDF (cumulative distribution function)
---@param x number Input value
---@return number Probability P(X <= x)
local function normal_cdf(x)
    return 0.5 * (1.0 + erf(x / math.sqrt(2.0)))
end

---Inverse standard normal CDF using Acklam's approximation
---@param p number Probability in (0,1)
---@return number x such that P(X <= x) = p
local function inv_norm_cdf(p)
    assert(p > 0.0 and p < 1.0, "p must be in (0,1)")

    -- Coefficients
    local a = {
        -3.969683028665376e+01, 2.209460984245205e+02,
        -2.759285104469687e+02, 1.383577518672690e+02,
        -3.066479806614716e+01, 2.506628277459239e+00
    }
    local b = {
        -5.447609879822406e+01, 1.615858368580409e+02,
        -1.556989798598866e+02, 6.680131188771972e+01,
        -1.328068155288572e+01, 1.0
    }
    local c = {
        -7.784894002430293e-03, -3.223964580411365e-01,
        -2.400758277161838e+00, -2.549732539343734e+00,
        4.374664141464968e+00, 2.938163982698783e+00
    }
    local d = {
        7.784695709041462e-03, 3.224671290700398e-01,
        2.445134137142996e+00, 3.754408661907416e+00, 1.0
    }

    -- Horner evaluator for polynomial
    local function horner(x, coeffs)
        local r = coeffs[1]
        for i = 2, #coeffs do r = r * x + coeffs[i] end
        return r
    end

    local plow, phigh = 0.02425, 1.0 - 0.02425

    if p < plow then
        local q = math.sqrt(-2.0 * math.log(p))
        local num = horner(q, c)
        local den = horner(q, d)
        return -(num / den)
    elseif p > phigh then
        local q = math.sqrt(-2.0 * math.log(1.0 - p))
        local num = horner(q, c)
        local den = horner(q, d)
        return -(num / den)
    else
        local q = p - 0.5
        local r = q * q
        local num = horner(r, a)
        local den = horner(r, b)
        return (num * q) / den
    end
end

---Convert desired probability of landing outside parents' range to within-family SD
---p_outside = 2*(1 - Phi(delta/(2*sd))) => sd = delta / (2 * Phi^{-1}(1 - p_outside/2))
---@param delta number Difference between parent values
---@param p_outside number Target probability of exceeding parent range
---@return number|nil Standard deviation, or nil if delta <= 0
local function sd_from_poutside(delta, p_outside)
    assert(p_outside > 0.0 and p_outside < 1.0, "p_outside must be in (0,1)")
    if delta <= 0.0 then return nil end -- undefined when parents are equal
    local alpha = 1.0 - 0.5 * p_outside
    local z = inv_norm_cdf(alpha)
    return delta / (2.0 * z)
end

---Samples offspring genetics using Gaussian distribution
---Offspring value is drawn from N(mid-parent, sd^2) where mid-parent = (p1+p2)/2
---This allows offspring to exceed or fall below parent ranges probabilistically
---@param parent1 number Parent 1 genetics value in [min_val, max_val]
---@param parent2 number Parent 2 genetics value in [min_val, max_val]
---@param opts table|nil Optional parameters:
---  - sd: within-family standard deviation (overrides p_outside)
---  - p_outside: target P(child < min(parent) or child > max(parent))
---  - min_val: default 0.25
---  - max_val: default 1.75
---  - clamp: default true; clamp into [min_val, max_val]
---@return number child_value The calculated child genetics value
---@return table probabilities Table with above_best, between, below_worst, sd values
function BreedingMath.breedOffspring(parent1, parent2, opts)
    opts = opts or {}
    local min_val = opts.min_val or 0.25
    local max_val = opts.max_val or 1.75
    local clamp_out = (opts.clamp ~= false)

    -- Mid-parent and parent spread
    local mid = 0.5 * (parent1 + parent2)
    local delta = math.abs(parent1 - parent2)

    -- Choose within-family SD
    local sd = opts.sd
    if not sd then
        if opts.p_outside and opts.p_outside > 0.0 and opts.p_outside < 1.0 and delta > 0.0 then
            sd = sd_from_poutside(delta, opts.p_outside)
        else
            -- Fallback default: moderate within-family variance (~12% of range)
            sd = 0.12 * (max_val - min_val)
        end
    end
    sd = math.max(sd, 1e-9) -- guard against zero

    -- Sample offspring phenotype ~ N(mid, sd^2)
    local child = mid + sd * randn()
    if clamp_out then
        child = clamp(child, min_val, max_val)
    end

    -- Outcome probabilities implied by sd (before clamping)
    local z = delta / (2.0 * sd)
    local p_above = 1.0 - normal_cdf(z)
    local p_below = p_above
    local p_between = 1.0 - (p_above + p_below)

    return child, { above_best = p_above, between = p_between, below_worst = p_below, sd = sd }
end
