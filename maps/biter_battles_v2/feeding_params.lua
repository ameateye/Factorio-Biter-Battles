-- The constants of the feeding curves, as data rather than as literals.
--
-- Three equations, seven numbers:
--
--   evolution   E = (M / S) ^ p                 S = evo_mutagen_at_100, p = evo_power
--   passive     P = a·E^n + b·E   per second    a, n, b
--   instant     T = c·M                         c = instant_scale
--
-- Defaults live in `defaults` below and are the only block worth editing by
-- hand. Admins retune a running game with /feeding-params, which writes into
-- storage.feeding_params; anything absent there falls back to the default, so a
-- save made before a field existed still loads and a partial override is a
-- legitimate state rather than a half-built table.
--
-- What the set is tuned against is the *marginal* ratio of the last two curves:
-- instant threat per unit of mutagen over the passive income per minute the same
-- mutagen buys. `instant_over_passive` computes it and /feeding-params prints it
-- at four evolutions, so a candidate can be judged without leaving the game.

local Public = {}

---@class FeedingParams
---@field evo_mutagen_at_100 number Mutagen that buys exactly 100% evolution.
---@field evo_power number `p` in E = (M / S) ^ p.
---@field evo_stop_scaling_at_100 boolean True: tangent past 100%. False: the power law runs on.
---@field passive_scale number `a`, the coefficient of the powered term of passive income.
---@field passive_power number `n`, its exponent, before the past-100% correction.
---@field passive_linear number `b`, the linear term — the floor at low evolution.
---@field instant_scale number `c`, instant threat per unit of mutagen sent.

---@type FeedingParams
local defaults = {
    evo_mutagen_at_100 = 277,
    evo_power = 0.3,
    evo_stop_scaling_at_100 = true,
    passive_scale = 100,
    passive_power = 2.5,
    passive_linear = 25,
    instant_scale = 200,
}

Public.defaults = defaults

-- Field name -> the symbol it is called by in the formulas and in the lab, so
-- an admin can type either. `stop` is the odd one out because the boolean has
-- no symbol; it reads as a switch in both places.
local aliases = {
    s = 'evo_mutagen_at_100',
    mutagen_at_100 = 'evo_mutagen_at_100',
    p = 'evo_power',
    stop = 'evo_stop_scaling_at_100',
    a = 'passive_scale',
    n = 'passive_power',
    b = 'passive_linear',
    c = 'instant_scale',
}

Public.aliases = aliases

-- Print order. Grouped by equation rather than alphabetically: the numbers are
-- read as three formulas, not as seven unrelated settings.
local order = {
    'evo_mutagen_at_100',
    'evo_power',
    'evo_stop_scaling_at_100',
    'passive_scale',
    'passive_power',
    'passive_linear',
    'instant_scale',
}

Public.order = order

-- Bounds. Two of the seven are not free parameters but intervals.
--
-- `p` is the diminishing return itself, so the family only means anything
-- strictly inside (0, 1): at 1 evolution is linear in mutagen and the price of a
-- point never moves, and above it every flask buys more than the last. The
-- reachable ends are one step short of each, which is what an open interval
-- amounts to on a control with a step.
local EVO_POWER_STEP = 0.01
local PASSIVE_POWER_STEP = 0.01

local limits = {
    evo_mutagen_at_100 = { min = 0.01, max = 1e9 },
    evo_power = { min = EVO_POWER_STEP, max = 1 - EVO_POWER_STEP },
    passive_scale = { min = 0, max = 1e9 },
    passive_linear = { min = 0, max = 1e9 },
    instant_scale = { min = 0, max = 1e9 },
    -- passive_power is deliberately absent: its window depends on evo_power and
    -- is computed by passive_power_bounds below.
}

local function clamp(value, low, high)
    return math.min(math.max(value, low), high)
end

---The window `n` lives in, which is (1, 1/p) and therefore moves with `p`.
---
---Below 1 the powered term bends *downward* and the linear term b·E is left
---doing all the work -- there is no reason to carry a·E^n at all. At 1/p the
---exponent in mutagen reaches 1: under the tangent E^n grows like (M/S)^(n·p),
---so n·p = 1 is where passive income stops diminishing in the mutagen fed, and
---past it income per flask climbs without limit.
---
---The margin is a quarter of the window rather than a fixed step, so the bounds
---stay ordered as `p` approaches 1 and the window closes to almost nothing.
---@param evo_power number
---@return number min
---@return number max
function Public.passive_power_bounds(evo_power)
    local ceiling = 1 / clamp(evo_power, limits.evo_power.min, limits.evo_power.max)
    local margin = math.min(PASSIVE_POWER_STEP, (ceiling - 1) / 4)
    return 1 + margin, ceiling - margin
end

---Put a parameter set inside those bounds.
---
---Every field goes through here rather than only the ones that look risky: `n`'s
---window depends on `p`, so raising `p` far enough has to drag `n` down with it
---instead of leaving the pair somewhere no curve is defined. Applied on read as
---well as on write, so a save hand-edited to something undefined still produces
---a drawable game rather than a NaN evolution.
---@param params FeedingParams
---@return FeedingParams
function Public.clamp(params)
    for field, limit in pairs(limits) do
        params[field] = clamp(params[field], limit.min, limit.max)
    end
    local n_min, n_max = Public.passive_power_bounds(params.evo_power)
    params.passive_power = clamp(params.passive_power, n_min, n_max)
    return params
end

---Resolve a field name or symbol to a field name, or nil if it is neither.
---@param key string
---@return string|nil
function Public.resolve_key(key)
    key = string.lower(key)
    if defaults[key] ~= nil then
        return key
    end
    return aliases[key]
end

---The overrides table, or nil when there is none. Tolerates `storage` being
---absent so the pure-Lua tests can require this module outside Factorio.
---@return table|nil
local function overrides()
    local store = storage
    if type(store) ~= 'table' then
        return nil
    end
    local set = store.feeding_params
    if type(set) ~= 'table' then
        return nil
    end
    return set
end

---The parameters in force: defaults with any admin overrides applied.
---
---Always a fresh table, including when nothing is overridden. Handing back
---`defaults` itself would be cheaper, but one caller poking a field would then
---silently rewrite the defaults for the rest of the session — and the callers
---are balance experiments, which is exactly the code that pokes fields.
---
---An override of the wrong type is ignored rather than trusted: `storage`
---survives across versions, and a field that changed shape must not be able to
---feed a string into the evolution curve.
---@return FeedingParams
function Public.get()
    local set = overrides()
    local resolved = {}
    for key, value in pairs(defaults) do
        local override = set and set[key]
        if override ~= nil and type(override) == type(value) then
            resolved[key] = override
        else
            resolved[key] = value
        end
    end
    return Public.clamp(resolved)
end

---Set one parameter. Returns the stored value, or nil plus a reason.
---@param key string Field name or symbol.
---@param raw string|number|boolean
---@return number|boolean|nil value
---@return string|nil error
function Public.set(key, raw)
    local field = Public.resolve_key(key)
    if not field then
        return nil, string.format('unknown parameter %q', key)
    end

    local current = Public.get()
    local value
    if type(defaults[field]) == 'boolean' then
        local text = string.lower(tostring(raw))
        if text == 'true' or text == '1' or text == 'yes' or text == 'on' then
            value = true
        elseif text == 'false' or text == '0' or text == 'no' or text == 'off' then
            value = false
        else
            return nil, string.format('%s takes true or false, got %q', field, tostring(raw))
        end
    else
        value = tonumber(raw)
        if value == nil then
            return nil, string.format('%s takes a number, got %q', field, tostring(raw))
        end
        -- Out of range is refused rather than clamped: an admin who typed a
        -- number is owed the reason it will not be taken, not a different one
        -- applied silently.
        local low, high
        if field == 'passive_power' then
            low, high = Public.passive_power_bounds(current.evo_power)
        else
            low, high = limits[field].min, limits[field].max
        end
        if value < low or value > high then
            return nil, string.format('%s must be between %.4g and %.4g', field, low, high)
        end
    end

    if type(storage) ~= 'table' then
        return nil, 'no storage to write to'
    end
    if type(storage.feeding_params) ~= 'table' then
        storage.feeding_params = {}
    end
    storage.feeding_params[field] = value

    -- `n` lives in (1, 1/p), so moving `p` moves the window under it. Drag it
    -- rather than leaving the pair somewhere no curve is defined; the caller
    -- re-reads and reports the whole set, so the change is visible.
    if field == 'evo_power' then
        local n_min, n_max = Public.passive_power_bounds(value)
        local dragged = math.min(math.max(current.passive_power, n_min), n_max)
        if dragged ~= current.passive_power then
            storage.feeding_params.passive_power = dragged
        end
    end
    return value
end

---Drop every override, returning the game to `defaults`.
function Public.reset()
    if type(storage) == 'table' then
        storage.feeding_params = nil
    end
end

---True when `field` is currently overridden rather than defaulted.
---@param field string
---@return boolean
function Public.is_overridden(field)
    local set = overrides()
    return set ~= nil and set[field] ~= nil and type(set[field]) == type(defaults[field])
end

-- ---------------------------------------------------------------------------
-- The curves themselves.
--
-- They live beside the constants rather than in feeding_calculations so that
-- the admin command can quote what a change did without duplicating any of the
-- algebra, and so the whole family is one file to read.
-- ---------------------------------------------------------------------------

---The exponent passive income actually runs at.
---
---With the tangent on, evolution eventually goes linear in mutagen, so `E^n` is
---already degree n in mutagen and n needs no correction.
---
---With it off, evolution stays (M/S)^p forever, and since p < 1 the term would
---grow like M^(n·p) -- with the defaults that is M^0.6, i.e. income per flask
---*falling away* rather than climbing. Dividing by p cancels it exactly, since
---E^(n/p) is identically (M/S)^n, so "n = 2" means the same thing to a player
---under either switch position.
---@param params FeedingParams
---@return number
function Public.effective_passive_power(params)
    if params.evo_stop_scaling_at_100 then
        return params.passive_power
    end
    return params.passive_power / params.evo_power
end

---Total mutagen behind an evolution level. Inverse of `evo_for_mutagen`.
---@param evo number
---@param params FeedingParams
---@return number
function Public.mutagen_for_evo(evo, params)
    if evo <= 0 then
        return 0
    end
    local scale = params.evo_mutagen_at_100
    if params.evo_stop_scaling_at_100 and evo > 1 then
        return scale + (evo - 1) * scale / params.evo_power
    end
    return (evo ^ (1.0 / params.evo_power)) * scale
end

---Evolution reached by a total mutagen amount. Inverse of `mutagen_for_evo`.
---
---Past 100% the curve continues along the power law's own tangent, so the two
---segments meet with no kink: the marginal cost of an evo point is continuous
---across the boundary rather than stepping. The tangent slope is dE/dM at
---M = scale, which for E = (M/S)^p is p/S -- so +100% evo costs a flat S/p
---mutagen however high evolution already is (923 at the defaults).
---@param mutagen number
---@param params FeedingParams
---@return number
function Public.evo_for_mutagen(mutagen, params)
    if mutagen <= 0 then
        return 0
    end
    local scale = params.evo_mutagen_at_100
    if params.evo_stop_scaling_at_100 and mutagen > scale then
        return 1 + (mutagen - scale) * params.evo_power / scale
    end
    return (mutagen / scale) ^ params.evo_power
end

---Passive threat income per second at `evo`. Anchored at zero: no evolution,
---no income.
---@param evo number
---@param params FeedingParams
---@return number
function Public.passive_threat(evo, params)
    if evo <= 0 then
        return 0
    end
    return params.passive_scale * evo ^ Public.effective_passive_power(params) + params.passive_linear * evo
end

---dE/dM at `evo` -- what the next unit of mutagen is worth in evolution.
---@param evo number
---@param params FeedingParams
---@return number
function Public.evo_slope(evo, params)
    local rate = params.evo_power / params.evo_mutagen_at_100
    if params.evo_stop_scaling_at_100 and evo > 1 then
        return rate
    end
    if evo <= 0 then
        return math.huge
    end
    -- M/S = E^(1/p) substituted into dE/dM = (p/S)(M/S)^(p-1).
    return rate * evo ^ (1 - 1 / params.evo_power)
end

---Minutes of passive income that the instant threat of one flask is worth, at
---the margin. Both sides are per unit of mutagen, so the mutagen cancels and
---what is left is a time: 10 means a send lands like ten minutes of the income
---that same send also buys. This is the number the balance pass is tuning.
---@param evo number
---@param params FeedingParams
---@return number
function Public.instant_over_passive(evo, params)
    local n = Public.effective_passive_power(params)
    local passive_per_evo
    if evo > 0 then
        passive_per_evo = params.passive_scale * n * evo ^ (n - 1) + params.passive_linear
    else
        passive_per_evo = params.passive_linear
    end
    local passive_per_minute = passive_per_evo * Public.evo_slope(evo, params) * 60
    if passive_per_minute <= 0 or passive_per_minute == math.huge then
        return 0
    end
    return params.instant_scale / passive_per_minute
end

return Public
