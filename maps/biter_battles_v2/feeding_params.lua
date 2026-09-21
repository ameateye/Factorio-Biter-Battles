-- The constants of the feeding curves, as data rather than as literals, and one
-- set of them per match format.
--
-- Three equations, seven numbers:
--
--   evolution   E = (M / S) ^ p                 S = evo_mutagen_at_100, p = evo_power
--   passive     P = (a·E^n + b·E) · k  per sec  a, n, b, k = passive_income_scale
--   instant     T = c·M                         c = instant_scale
--
-- Plus two rules a format imposes on top of them: `passive_income_scale`, which
-- is how 1v1 gets half the income off the same curve, and `attack_interval`,
-- the ticks between global attack waves.
--
-- Every number is per format. `storage.feeding_params` is keyed by format --
--
--   storage.feeding_params = {
--     ['1v1'] = { passive_linear = 12 },
--     ['3v3'] = { instant_scale = 250 },
--   }
--
-- -- so a retune of 1v1 leaves 3v3 exactly where it was. Three layers resolve a
-- field, most specific first: the admin's override for that format, whatever
-- the scenario ships differently for it (`format_defaults`), then the base
-- `defaults`. A partial override is a legitimate state rather than a half-built
-- table, so a save made before a field existed still loads.

local Public = {}

-- The global attack wave is dispatched once a minute, alternating sides, so a
-- minute is the granularity any wave interval can land on. Intervals are stored
-- in ticks because that is the unit the dispatcher counts in, and constrained to
-- multiples of this because nothing finer is reachable.
local TICKS_PER_MINUTE = 3600

-- The format a game with nothing reported plays under. A real key rather than a
-- nil case, so sandbox games are tunable like any other format.
local BASE_KEY = 'default'

Public.BASE_KEY = BASE_KEY

-- Every set an admin can reach. Bounded by the team sizes match_format accepts.
local format_keys = { BASE_KEY }
for size = 1, 8 do
    format_keys[#format_keys + 1] = string.format('%dv%d', size, size)
end

Public.format_keys = format_keys

local is_format_key = {}
for _, key in ipairs(format_keys) do
    is_format_key[key] = true
end

---@param key string
---@return boolean
function Public.is_format_key(key)
    return is_format_key[string.lower(key)] == true
end

---@class FeedingParams
---@field evo_mutagen_at_100 number Mutagen that buys exactly 100% evolution.
---@field evo_power number `p` in E = (M / S) ^ p.
---@field evo_stop_scaling_at_100 boolean True: tangent past 100%. False: the power law runs on.
---@field passive_scale number `a`, the coefficient of the powered term of passive income.
---@field passive_power number `n`, its exponent, before the past-100% correction.
---@field passive_linear number `b`, the linear term — the floor at low evolution.
---@field instant_scale number `c`, instant threat per unit of mutagen sent.
---@field passive_income_scale number `k`, a multiplier on the whole passive curve.
---@field attack_interval integer Ticks between global attack waves.

---The same numbers in every format unless `format_defaults` says otherwise.
---@type FeedingParams
local defaults = {
    evo_mutagen_at_100 = 277,
    evo_power = 0.3,
    evo_stop_scaling_at_100 = true,
    passive_scale = 100,
    passive_power = 2.5,
    -- Lowered from 25 (2026-09-17). Permanent and format-independent: the floor
    -- was carrying too much of the early game at every team size.
    passive_linear = 15,
    -- 200 -> 260 (2026-09-22). Instant threat is the half of a send a team can
    -- see coming and play around; the passive income it buys is the half it
    -- cannot. Raising c shifts weight toward the former without touching what a
    -- flask is worth in evolution.
    instant_scale = 260,
    -- 1 -> 0.9 (2026-09-22). A broad damp on passive income across the board,
    -- left as a multiplier rather than folded into a and b so the curve
    -- underneath stays the shape those constants describe. Note 1v1 is
    -- unaffected: `format_defaults` REPLACES this rather than composing with
    -- it, so 1v1 stays at 0.5 rather than becoming 0.45.
    passive_income_scale = 0.9,
    attack_interval = TICKS_PER_MINUTE,
}

Public.defaults = defaults

---What the scenario ships differently for one format. Anything not named here
---is the same number everywhere, so this stays a list of deliberate deviations
---rather than a second copy of the defaults per format.
local format_defaults = {
    ['1v1'] = {
        -- Two players hold the frontage a whole team otherwise holds, so the
        -- vanilla income lands much harder on them. Expressed as a multiplier
        -- rather than as halved a and b so that it survives a retune of the
        -- curve underneath it.
        passive_income_scale = 0.5,
    },
}

Public.format_defaults = format_defaults

---What the scenario *ships* for a field in a format: its deviation if it has
---one, the base default otherwise. Deliberately blind to anything an admin has
---tuned, which is what makes it the number a reset returns to.
---
---For what a format actually falls back to in a running game -- which includes a
---retuned base -- see `inherited_for`.
---@param field string
---@param format_key string
---@return number|boolean
function Public.default_for(field, format_key)
    local per_format = format_defaults[format_key]
    if per_format and per_format[field] ~= nil then
        return per_format[field]
    end
    return defaults[field]
end

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
    k = 'passive_income_scale',
    income_scale = 'passive_income_scale',
    interval = 'attack_interval',
}

Public.aliases = aliases

-- Print order. Grouped by what the numbers mean together rather than
-- alphabetically: the first group is read as three formulas, the second as
-- what a format does on top of them.
local groups = {
    {
        title = 'Curve constants',
        fields = {
            'evo_mutagen_at_100',
            'evo_power',
            'evo_stop_scaling_at_100',
            'passive_scale',
            'passive_power',
            'passive_linear',
            'instant_scale',
        },
    },
    {
        title = 'Format rules',
        note = 'What this format does on top of the curves above.',
        fields = {
            'passive_income_scale',
            'attack_interval',
        },
    },
}

Public.groups = groups

-- The groups flattened. Every loop that applies or reports a whole set walks
-- this, and the order matters in one place: p has to come before n, because n's
-- window depends on p and a change to both at once must store the new p first
-- or the new n is judged against the window the old one opened.
local order = {}
for _, group in ipairs(groups) do
    for _, field in ipairs(group.fields) do
        order[#order + 1] = field
    end
end

Public.order = order

-- Bounds. Two of the nine are not free parameters but intervals.
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
    -- A multiplier, so 1 is "nothing different from the base curve" and the
    -- useful range sits below it. The ceiling is well clear of 1 rather than at
    -- it, so a format that wants *more* income than the curve is expressible.
    passive_income_scale = { min = 0, max = 10 },
    -- One minute is the vanilla cadence and the floor; an hour is the ceiling,
    -- past which a match would end before the second wave landed.
    attack_interval = { min = TICKS_PER_MINUTE, max = 60 * TICKS_PER_MINUTE },
    -- passive_power is deliberately absent: its window depends on evo_power and
    -- is computed by passive_power_bounds below.
}

-- Fields that only mean anything on a multiple of something. The wave interval
-- is the one: the dispatcher offers a wave once a minute, so an interval of
-- 5400 ticks cannot be honoured and would quietly behave as 3600. Refused on
-- the way in rather than rounded, for the same reason an out-of-range number is.
local steps = {
    attack_interval = TICKS_PER_MINUTE,
}

Public.steps = steps

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

---The interval a field is accepted in, or nil for the one that is a switch.
---
---`passive_power`'s window moves with `evo_power`, so the set in force has to be
---passed in rather than read here: a caller applying several fields at once is
---mid-change, and the window that matters is the one the *new* `p` opens.
---@param field string
---@param params FeedingParams
---@return number|nil min
---@return number|nil max
function Public.bounds(field, params)
    if field == 'passive_power' then
        return Public.passive_power_bounds(params.evo_power)
    end
    local limit = limits[field]
    if not limit then
        return nil, nil
    end
    return limit.min, limit.max
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
    for field, step in pairs(steps) do
        params[field] = math.floor(params[field] / step) * step
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

---The format whose set is in force.
---
---match_format requires this module at load, so the dependency can only run
---this direction at runtime -- hence the local require. `require` on a module
---already in package.loaded is a table lookup, and this is reached a few times
---a minute, not per tick.
---@return string
function Public.current_key()
    if type(storage) ~= 'table' then
        return BASE_KEY
    end
    return require('maps.biter_battles_v2.match_format').format_key()
end

---The override table for one format, or nil when there is none. Tolerates
---`storage` being absent so the pure-Lua tests can require this outside Factorio.
---@param format_key string
---@return table|nil
local function overrides(format_key)
    local store = storage
    if type(store) ~= 'table' then
        return nil
    end
    local all = store.feeding_params
    if type(all) ~= 'table' then
        return nil
    end
    local set = all[format_key]
    if type(set) ~= 'table' then
        return nil
    end
    return set
end

---What `field` falls back to for a format that is not overriding it: the
---format's shipped deviation, then the retuned base, then the shipped base.
---
---This layer is what makes `default` a base rather than a tenth sibling. The
---common case -- "this number is wrong everywhere" -- is one command against
---`default` instead of nine against each format.
---
---The shipped deviation sits ABOVE the retuned base on purpose. `format_defaults`
---records what a format *must* do differently -- 1v1 halves the passive income
---because two players hold the frontage a whole team otherwise holds -- and a
---base retune quietly erasing that is the kind of thing nobody notices until the
---match feels wrong. So a base change reaches every field a format has not
---claimed, and none that it has. A format that would rather follow the base on
---such a field can still say so by setting it explicitly.
---@param field string
---@param format_key string
---@return number|boolean
function Public.inherited_for(field, format_key)
    local per_format = format_defaults[format_key]
    if per_format and per_format[field] ~= nil then
        return per_format[field]
    end
    if format_key ~= BASE_KEY then
        local base = overrides(BASE_KEY)
        local tuned = base and base[field]
        -- The same type guard `get` applies: `storage` survives across versions.
        if tuned ~= nil and type(tuned) == type(defaults[field]) then
            return tuned
        end
    end
    return defaults[field]
end

---True when a format is taking `field` from the retuned base rather than from
---anything of its own or anything shipped. Reported, so an admin reading 1v1 can
---tell why a number is not the one the scenario ships.
---@param field string
---@param format_key string
---@return boolean
function Public.is_inherited(field, format_key)
    if format_key == BASE_KEY or Public.is_overridden(field, format_key) then
        return false
    end
    local per_format = format_defaults[format_key]
    if per_format and per_format[field] ~= nil then
        return false
    end
    local base = overrides(BASE_KEY)
    local tuned = base and base[field]
    return tuned ~= nil and type(tuned) == type(defaults[field])
end

---The parameters in force for a format: what it inherits, with its own admin
---overrides on top. `inherited_for` has the fallback chain.
---
---Always a fresh table, including when nothing is overridden. Handing back a
---shared table would be cheaper, but one caller poking a field would then
---silently rewrite it for the rest of the session — and the callers are balance
---experiments, which is exactly the code that pokes fields.
---
---An override of the wrong type is ignored rather than trusted: `storage`
---survives across versions, and a field that changed shape must not be able to
---feed a string into the evolution curve.
---@param format_key string|nil Defaults to the format in force.
---@return FeedingParams
function Public.get(format_key)
    format_key = format_key or Public.current_key()
    local set = overrides(format_key)
    local resolved = {}
    for key, value in pairs(defaults) do
        local override = set and set[key]
        if override ~= nil and type(override) == type(value) then
            resolved[key] = override
        else
            resolved[key] = Public.inherited_for(key, format_key)
        end
    end
    return Public.clamp(resolved)
end

-- What an admin types to stop overriding a field rather than to give it a new
-- value. Accepted anywhere a value is, so `/feeding-params 1v1 b=default` and an
-- emptied box in the panel are one operation rather than two spellings of it.
local clear_words = { default = true, inherit = true, reset = true, ['-'] = true }

---@param raw any
---@return boolean
function Public.is_clear_word(raw)
    return type(raw) == 'string' and clear_words[string.lower(raw)] == true
end

---Drop one field's override for one format, so it falls back to whatever it
---inherits. Returns the value now in force.
---
---A set emptied of its last override is removed rather than left behind as an
---empty table, so `storage.feeding_params` stays a record of what has actually
---been moved and nothing downstream needs a special case for the husk.
---@param key string Field name or symbol.
---@param format_key string|nil Defaults to the format in force.
---@return number|boolean|nil value
---@return string|nil error
function Public.clear(key, format_key)
    format_key = format_key or Public.current_key()
    local field = Public.resolve_key(key)
    if not field then
        return nil, string.format('unknown parameter %q', key)
    end
    local set = overrides(format_key)
    if set then
        set[field] = nil
        if next(set) == nil then
            storage.feeding_params[format_key] = nil
        end
    end
    return Public.get(format_key)[field]
end

---Set one parameter for one format. Returns the stored value, or nil plus a
---reason.
---
---A clear word in place of a value drops the override instead, which is how a
---single parameter is returned to what it inherits without resetting the set
---around it.
---@param key string Field name or symbol.
---@param raw string|number|boolean
---@param format_key string|nil Defaults to the format in force.
---@return number|boolean|nil value
---@return string|nil error
function Public.set(key, raw, format_key)
    format_key = format_key or Public.current_key()
    local field = Public.resolve_key(key)
    if not field then
        return nil, string.format('unknown parameter %q', key)
    end

    -- Routed here rather than handled by each caller, so the command and the
    -- panel cannot end up meaning different things by an erased value.
    if Public.is_clear_word(raw) then
        return Public.clear(field, format_key)
    end

    local current = Public.get(format_key)
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
        local low, high = Public.bounds(field, current)
        if value < low or value > high then
            return nil, string.format('%s must be between %.4g and %.4g', field, low, high)
        end
        local step = steps[field]
        if step and value % step ~= 0 then
            return nil,
                string.format(
                    '%s must be a multiple of %d ticks — the global wave is offered once a minute, so nothing finer lands',
                    field,
                    step
                )
        end
    end

    if type(storage) ~= 'table' then
        return nil, 'no storage to write to'
    end
    if type(storage.feeding_params) ~= 'table' then
        storage.feeding_params = {}
    end
    if type(storage.feeding_params[format_key]) ~= 'table' then
        storage.feeding_params[format_key] = {}
    end
    storage.feeding_params[format_key][field] = value

    -- `n` lives in (1, 1/p), so moving `p` moves the window under it. Drag it
    -- rather than leaving the pair somewhere no curve is defined; the caller
    -- re-reads and reports the whole set, so the change is visible.
    if field == 'evo_power' then
        local n_min, n_max = Public.passive_power_bounds(value)
        local dragged = math.min(math.max(current.passive_power, n_min), n_max)
        if dragged ~= current.passive_power then
            storage.feeding_params[format_key].passive_power = dragged
        end
    end
    return value
end

---Drop one format's overrides, returning it to what the scenario ships.
---@param format_key string
function Public.reset(format_key)
    if type(storage) ~= 'table' or type(storage.feeding_params) ~= 'table' then
        return
    end
    storage.feeding_params[format_key] = nil
end

---Drop every format's overrides.
function Public.reset_all()
    if type(storage) == 'table' then
        storage.feeding_params = nil
    end
end

---True when `field` is overridden for `format_key` rather than shipped.
---@param field string
---@param format_key string
---@return boolean
function Public.is_overridden(field, format_key)
    local set = overrides(format_key)
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
---
---The format's multiplier is applied here rather than at the call sites, so
---nothing downstream can compute an income that forgot about it.
---@param evo number
---@param params FeedingParams
---@return number
function Public.passive_threat(evo, params)
    if evo <= 0 then
        return 0
    end
    local income = params.passive_scale * evo ^ Public.effective_passive_power(params) + params.passive_linear * evo
    return income * params.passive_income_scale
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
---
---Halving the income doubles this, which is the point of quoting it: it is what
---a format's multiplier does to the worth of a send, in one number.
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
    passive_per_evo = passive_per_evo * params.passive_income_scale
    local passive_per_minute = passive_per_evo * Public.evo_slope(evo, params) * 60
    if passive_per_minute <= 0 or passive_per_minute == math.huge then
        return 0
    end
    return params.instant_scale / passive_per_minute
end

-- ---------------------------------------------------------------------------
-- Presentation.
--
-- Shared by the two things that can move these numbers -- /feeding-params and
-- the Feeding tab -- so the two cannot drift into quoting a flask at different
-- values. Everything here is pure: it formats a parameter set, it does not read
-- or write the one in force.
-- ---------------------------------------------------------------------------

-- Evolutions the summary quotes at -- the span the balance is argued over.
Public.quote_at = { 0.5, 1.0, 1.5, 2.5 }

---Human-readable value, without Lua's trailing ".0" on whole numbers.
---
---Also the canonical text of a field: the panel fills its boxes with this and
---calls a box unedited when it still reads back the same, so what counts as a
---change is exactly what the admin can see.
---@param value number|boolean
---@return string
function Public.show(value)
    if type(value) == 'boolean' then
        return value and 'true' or 'false'
    end
    if value == math.floor(value) and math.abs(value) < 1e15 then
        return string.format('%d', value)
    end
    return (string.format('%.4f', value):gsub('0+$', ''):gsub('%.$', ''))
end

---The letter a field is called by in the formulas, or nil for the switch, which
---has none. The long aliases are skipped -- they are for typing, not for naming.
---@param field string
---@return string|nil
function Public.symbol(field)
    for alias, target in pairs(aliases) do
        if target == field and #alias <= 2 then
            return alias
        end
    end
    return nil
end

---The three formulas, with the numbers in force substituted in. The income
---multiplier only appears when it is doing something, so the common case reads
---as the plain sum it is.
---@param params FeedingParams
---@return string
function Public.formulas(params)
    local passive = string.format(
        '%s·E^%s + %s·E',
        Public.show(params.passive_scale),
        Public.show(Public.effective_passive_power(params)),
        Public.show(params.passive_linear)
    )
    if params.passive_income_scale ~= 1 then
        passive = string.format('(%s) × %s', passive, Public.show(params.passive_income_scale))
    end

    return string.format(
        'E = (M / %s) ^ %s%s   |   P = %s per sec   |   T = %s·M',
        Public.show(params.evo_mutagen_at_100),
        Public.show(params.evo_power),
        params.evo_stop_scaling_at_100 and ', tangent past 100%' or ', power law throughout',
        passive,
        Public.show(params.instant_scale)
    )
end

---What the curves come to at one evolution -- the row a candidate set is judged
---on. `ratio` is the number the balance pass is actually tuning; see
---`instant_over_passive`. Both already carry the format's multiplier, because
---the curves themselves do.
---@param evo number
---@param params FeedingParams
---@return { evo: number, mutagen: number, threat_per_minute: number, ratio: number }
function Public.summary_at(evo, params)
    return {
        evo = evo,
        mutagen = Public.mutagen_for_evo(evo, params),
        threat_per_minute = Public.passive_threat(evo, params) * 60,
        ratio = Public.instant_over_passive(evo, params),
    }
end

---Every parameter of one format's set, one per line, marked where it has been
---moved, followed by what the set comes to across the span.
---@param params FeedingParams
---@param format_key string Which set this is.
---@param live string|nil What the match format is right now, for the header.
---@return string
function Public.report(params, format_key, live)
    local lines = { '[feeding-params] ' .. Public.formulas(params) }
    lines[#lines + 1] = string.format('  showing: %s%s', format_key, live and ('   |   live: ' .. live) or '')

    for _, group in ipairs(groups) do
        lines[#lines + 1] = '  — ' .. group.title
        for _, field in ipairs(group.fields) do
            local symbol = Public.symbol(field)
            -- Not the shipped number but the one a clear would actually produce:
            -- an admin about to undo a change is owed where it lands, and with a
            -- retuned base underneath, the two are no longer the same.
            local note = ''
            if Public.is_overridden(field, format_key) then
                note = string.format('   [%s if cleared]', Public.show(Public.inherited_for(field, format_key)))
            elseif Public.is_inherited(field, format_key) then
                note = '   [from default]'
            end
            lines[#lines + 1] = string.format(
                '    %s%s = %s%s',
                field,
                symbol and (' (' .. symbol .. ')') or '',
                Public.show(params[field]),
                note
            )
        end
    end

    local row = {}
    for _, evo in ipairs(Public.quote_at) do
        local at = Public.summary_at(evo, params)
        row[#row + 1] = string.format(
            '%d%%: %.0f mutagen, %.0f threat/min, ratio %.1f min',
            at.evo * 100,
            at.mutagen,
            at.threat_per_minute,
            at.ratio
        )
    end
    lines[#lines + 1] = '  ' .. table.concat(row, ' | ')
    return table.concat(lines, '\n')
end

-- ---------------------------------------------------------------------------
-- Applying a change.
--
-- Not part of `set`, which is one field and nothing else. This is what has to
-- happen around a retune however it was asked for, and it is shared so the
-- command and the panel cannot do half of it each.
-- ---------------------------------------------------------------------------

---Tell both teams what moved, and re-derive anything that was computed from the
---old constants.
---
---Announced rather than applied quietly: a retune moves what a send is worth
---for both teams at once, and a silent one mid-game would read to players as
---the scenario misbehaving.
---@param lead string The first line, already naming who did what.
---@param format_key string Which set was touched.
local function announce(lead, format_key)
    -- Required here rather than at the top of the file: match_format requires
    -- this module at load, so a top-level require would close the loop.
    local MatchFormat = require('maps.biter_battles_v2.match_format')

    game.print(
        lead .. '\n' .. Public.report(Public.get(format_key), format_key, MatchFormat.describe()),
        { r = 1, g = 0.85, b = 0.2 }
    )

    -- bb_threat_income is only rewritten when someone feeds, so a retune of the
    -- passive terms would otherwise keep paying the old rate until the next
    -- send -- for minutes, silently, after an announcement saying it changed.
    MatchFormat.refresh_threat_income()

    -- Evolution is reconstructed from each team's *current* evolution on every
    -- feed, so moving S or p re-prices future sends without moving anyone's
    -- evolution now. Triple Threat keeps the raw mutagen instead and derives
    -- evolution from it, so there the change is retroactive and the canonical
    -- value has to be recomputed or the two would disagree until the next send.
    if storage.tt_mode then
        require('maps.biter_battles_v2.tt_mode').tt_recompute_all()
        game.print('>> [feeding-params] Triple Threat is on — evolution recomputed from raw mutagen fed.')
    end
end

---@param actor string Who moved them.
---@param applied string[] Already formatted as "field = value".
---@param format_key string Which set they moved.
function Public.announce_changed(actor, applied, format_key)
    announce(
        string.format('>> [feeding-params] %s changed %s for %s', actor, table.concat(applied, ', '), format_key),
        format_key
    )
end

---@param actor string Who reset them.
---@param format_key string Which set was reset.
function Public.announce_reset(actor, format_key)
    announce(string.format('>> [feeding-params] %s reset %s to defaults.', actor, format_key), format_key)
end

return Public
