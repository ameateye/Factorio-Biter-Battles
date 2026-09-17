-- Match format (team size), read from the league's own record for this match.
--
--   storage.bb_league_match = { id, format = '1v1', ladder, north, south, go_tick }
--
-- The web server writes that into the instance it booted, and it is nil outside
-- a league match. There is no way to set it from in game: the format is a fact
-- about the match rather than a setting, and the league is the one thing that
-- knows it. A game with no record plays the 'default' parameter set, which is
-- tunable like any other.
--
-- The rules a format imposes are not here -- they are parameters in
-- feeding_params, one set per format, retuned with /feeding-params or the Evo
-- and threat setup tab. This module only says which format is in force.

local FeedingParams = require('maps.biter_battles_v2.feeding_params')

local Public = {}

local MIN_TEAM_SIZE = 1
local MAX_TEAM_SIZE = 8

local TICKS_PER_MINUTE = 3600
local BITER_FORCES = { 'north_biters', 'south_biters' }

---Team size from the league's `format` string, or nil if it is not a shape this
---scenario plays.
---
---Unreadable is nil rather than an error, and deliberately so: the league
---reports '0v0' for a record with no roster yet, and will one day report
---formats written after this code. An odd record has to leave the game playing
---the default set, not stop it.
---@param format any
---@return integer|nil
local function team_size_of(format)
    if type(format) ~= 'string' then
        return nil
    end
    local left, right = format:lower():gsub('%s', ''):match('^(%d+)v(%d+)$')
    if not left or left ~= right then
        return nil
    end
    local size = tonumber(left)
    if size < MIN_TEAM_SIZE or size > MAX_TEAM_SIZE then
        return nil
    end
    return size
end

---The league's record for this match, or nil when there is none. Tolerates
---`storage` being absent so the module loads outside Factorio.
---@return table|nil
local function league_match()
    local store = storage
    if type(store) ~= 'table' then
        return nil
    end
    local match = store.bb_league_match
    if type(match) ~= 'table' then
        return nil
    end
    return match
end

---@return integer|nil team_size nil outside a league match, or on a record this
---scenario cannot read.
function Public.team_size()
    local match = league_match()
    if not match then
        return nil
    end
    return team_size_of(match.format)
end

---The key the parameter sets are stored under: '1v1', '2v2', ... or 'default'.
---@return string
function Public.format_key()
    local size = Public.team_size()
    if not size then
        return FeedingParams.BASE_KEY
    end
    return string.format('%dv%d', size, size)
end

---Ticks between consecutive global attack waves, for the format in force.
---
---Vanilla offers a wave every minute and the wave alternates sides, so 3600 is
---"each side every two minutes" and is the floor: the dispatcher has nothing
---finer to offer.
---@return integer
function Public.attack_interval_ticks()
    return FeedingParams.get().attack_interval
end

---True on the minutes where the whole main attack cycle should be skipped.
---
---The cycle occupies ticks 900..1140 of each 3600-tick minute, so a wave runs
---in the interval's *first* minute and the rest of the interval is skipped.
---Bucketing this way keeps setup, the seven waves and teardown agreeing with
---each other -- a cycle is never half-run. Skipping teardown too is the point:
---it is post_main_attack that flips sides, so a skipped minute leaves
---next_attack alone and the sides keep alternating, just further apart.
---
---At the 3600 floor `tick % interval` is always under a minute, so nothing is
---ever skipped and this costs one modulo.
---@param tick integer
---@return boolean
function Public.skip_attack_cycle(tick)
    local interval = Public.attack_interval_ticks()
    if interval <= TICKS_PER_MINUTE then
        return false
    end
    return (tick % interval) >= TICKS_PER_MINUTE
end

---bb_threat_income is only rewritten when someone feeds, so a parameter changed
---mid-game would otherwise keep paying the old rate until the next send.
---Rebuild both sides from current evolution so a change takes effect at once.
---
---`passive_threat` already carries the format's income multiplier, so there is
---nothing to apply on top of it here.
function Public.refresh_threat_income()
    if not storage.bb_threat_income or not storage.bb_evolution then
        return
    end
    local params = FeedingParams.get()
    for _, biter_force in ipairs(BITER_FORCES) do
        local evo = storage.bb_evolution[biter_force]
        if evo then
            storage.bb_threat_income[biter_force] = FeedingParams.passive_threat(evo, params)
        end
    end
end

---What the format is and what it is doing, for the report and the panel to
---quote. One call so the two cannot describe it from different reads.
---@return string
function Public.describe()
    local match = league_match()
    local size = Public.team_size()

    if not size then
        if match then
            return string.format(
                'league match %s reports %q, which this scenario does not play — default set',
                tostring(match.id or '?'),
                tostring(match.format)
            )
        end
        return 'no league match — default set'
    end

    local params = FeedingParams.get()
    local interval = params.attack_interval
    return string.format(
        '%dv%d [league match %s] — passive income x%s, wave every %d ticks (%s min, each side every %s min)',
        size,
        size,
        tostring(match.id or '?'),
        FeedingParams.show(params.passive_income_scale),
        interval,
        FeedingParams.show(interval / TICKS_PER_MINUTE),
        FeedingParams.show((interval * 2) / TICKS_PER_MINUTE)
    )
end

return Public
