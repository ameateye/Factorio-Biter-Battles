-- The attack-turn clock: when a main attack cycle runs, above two teams.
--
-- Today one cycle runs per interval and serves one team, so with two teams each
-- side is attacked every `2 x interval`. Walking that same one-cycle-per-
-- interval schedule round a ring of three or four teams would halve the
-- pressure on each of them, so above two teams the cycle runs N/2 times as
-- often instead -- period
--
--     P = 2 x interval / N
--
-- -- which is 1800 ticks with four teams and 2400 with three at the default
-- interval of 3600. Every team is then attacked exactly every `2 x interval`,
-- whatever N is, and N is the team count of the ROUND: the cursor walks the ring
-- of all the teams playing it, not only the ones still alive, and the turn of an
-- eliminated team is an idle turn (`Ai.pre_main_attack` gives it a budget of
-- zero). An elimination must not bring the survivors' turns round any faster
-- than the two intervals the curves are tuned for.
--
-- A cycle is nine steps 30 ticks apart -- setup, seven waves, teardown -- so it
-- occupies 240 ticks, and the dispatcher only offers a slot every 30 ticks.
-- Hence the two constraints on P: a multiple of 30, and at least 270, so that a
-- cycle has always finished before the next one starts. Every interval a league
-- format can set is a multiple of 3600 (`feeding_params.lua:199-210`), so at
-- N = 2, 3 or 4 P is a multiple of 600 and both constraints already hold;
-- `period()` still rounds UP to the next multiple of 30 and holds the floor, so
-- a format that one day sets something else gets a marginally faster clock
-- rather than a cycle that never runs or one that overlaps itself.
--
-- The phase is the same 900 the dispatcher has always used -- a cycle starts
-- when `(tick - 900) % P == 0` -- so with four teams the cycle starts at ticks
-- 900 and 2700 of every minute, and with three teams it drifts through the
-- minute (900, 3300, 5700, ...). Absolute ticks, as `tick % 3600` is today: the
-- schedule does not depend on when the round started.
--
-- The switch `storage.bb_attack_clock_mode` selects the clock ('per_team', the
-- default, which is also what nil means) or the fallback ('shared': one cycle
-- per interval, the first multi-team behaviour, half of today's pressure per team at four
-- teams). It is deliberately not part of the round state in `storage.bb_teams`
-- and nothing in `Init.tables()` touches it: it is a measurement switch, and it
-- has to survive a map reset. An operator sets it over RCON through the
-- `bb_teams` remote interface (`commands/team_count.lua`).
--
-- Everything here but the three mode accessors is a pure function of its
-- arguments: no `game`, no event, nothing read or written at load, and the tick,
-- the interval and the team count are passed in. Two teams never reach this
-- module -- `main.lua` keeps the legacy dispatcher and `ai.lua` the legacy
-- toggle -- but it answers for them all the same (P = interval = 3600, the nine
-- keys of `tick_minute_functions` at their vanilla ticks), which is how
-- `tests/test-attack-clock.lua` pins the clock against the schedule it has to
-- reproduce.

local Public = {}

--- One cycle per interval, walking the alive teams: the first multi-team schedule.
Public.SHARED = 'shared'
--- The clock of this module: today's per-team cadence at any team count.
Public.PER_TEAM = 'per_team'

---@type table<string, true>
local MODES = {
    [Public.SHARED] = true,
    [Public.PER_TEAM] = true,
}

--- Ticks between two steps of a cycle; also the dispatcher's own resolution.
local STEP_SPACING = 30
--- Setup, seven waves, teardown.
local STEPS = 9
--- From the setup to the teardown: 240 ticks.
local CYCLE_LENGTH = STEP_SPACING * (STEPS - 1)
--- `tick % 3600` of the setup step -- `300 * 3`, as `main.lua` writes it. The
--- clock's steps carry the keys 900..1140 of `tick_minute_functions`, whatever
--- tick they run on, so the table lookup and the profiler entry are the ones the
--- vanilla dispatcher would have produced.
local CYCLE_START_KEY = 300 * 3
--- The shortest period that fits a whole cycle plus one free slot.
local MIN_PERIOD = CYCLE_LENGTH + STEP_SPACING

Public.STEP_SPACING = STEP_SPACING
Public.STEPS = STEPS
Public.CYCLE_LENGTH = CYCLE_LENGTH
Public.CYCLE_START_KEY = CYCLE_START_KEY
Public.MIN_PERIOD = MIN_PERIOD

---Ticks between two consecutive attack cycles.
---
---`2 x interval / team_count`, rounded up to a multiple of the 30 ticks the
---dispatcher works in and floored at one cycle plus a slot. Nothing a league
---format can set needs either correction (see the header).
---@param interval integer Ticks between global attack waves (`MatchFormat.attack_interval_ticks()`).
---@param team_count integer Teams of the round, not the number still alive.
---@return integer
function Public.period(interval, team_count)
    -- A round always has at least one team; the guard is only here so that a
    -- nonsense count cannot divide by zero and hand back an infinite period that
    -- no tick would ever match.
    if not team_count or team_count < 1 then
        team_count = 1
    end
    local period = math.ceil(2 * interval / (team_count * STEP_SPACING)) * STEP_SPACING
    if period < MIN_PERIOD then
        return MIN_PERIOD
    end
    return period
end

---How far into its cycle this tick is, or nil when it is not a step of one.
---@param tick integer
---@param period integer
---@return integer|nil offset 0, 30 ... 240.
local function offset_at(tick, period)
    local offset = (tick - CYCLE_START_KEY) % period
    if offset > CYCLE_LENGTH then
        return nil
    end
    if offset % STEP_SPACING ~= 0 then
        return nil
    end
    return offset
end

---Which step of a cycle this tick is, if any: 1 the setup, 2..8 the seven
---waves, 9 the teardown.
---@param tick integer
---@param interval integer
---@param team_count integer
---@return integer|nil
function Public.step_at(tick, interval, team_count)
    local offset = offset_at(tick, Public.period(interval, team_count))
    if not offset then
        return nil
    end
    return offset / STEP_SPACING + 1
end

---The `tick_minute_functions` key this tick's step is, if any: 900 for the
---setup, 930..1110 for the seven waves, 1140 for the teardown -- the keys the
---vanilla dispatcher fires at those ticks of the minute.
---@param tick integer
---@param interval integer
---@param team_count integer
---@return integer|nil
function Public.step_key(tick, interval, team_count)
    local offset = offset_at(tick, Public.period(interval, team_count))
    if not offset then
        return nil
    end
    return CYCLE_START_KEY + offset
end

---Whose turn comes after `team`: the next entry of `playing`, wrapping round.
---
---Every team of the round has a turn, the eliminated ones included -- theirs is
---idle. A cursor that is not in the list at all (a fresh round, a save from a
---round with more teams) restarts the rotation at the first team.
---@param playing string[] The teams of the round, in ring order (`Teams.all()`).
---@param team string|nil The team whose turn it is now.
---@return string|nil
function Public.next_turn(playing, team)
    local count = #playing
    if count == 0 then
        return nil
    end
    local index = count
    for i = 1, count do
        if playing[i] == team then
            index = i
            break
        end
    end
    return playing[index % count + 1]
end

---Which schedule is selected. Anything the save does not recognise -- nil, or a
---hand-edited value -- reads as the clock, so there is one answer for "nothing
---was ever set".
---@return string
function Public.mode()
    local mode = storage.bb_attack_clock_mode
    if MODES[mode] then
        return mode
    end
    return Public.PER_TEAM
end

---Select a schedule. `nil` clears the switch, which leaves the default clock.
---
---Not guarded against being called mid-round: the two schedules differ only in
---which tick the next cycle starts on and whose turn it is, and both keep the
---cursor in `storage.next_attack`. Switched between a cycle's setup and its
---teardown, what is left of that one cycle is dropped -- the next setup step
---rebuilds the budget before any wave slot reads it, so nothing is left
---half-armed and no state has to be repaired here.
---@param mode any
---@return boolean ok
---@return string|nil reason Why it was refused, when it was.
function Public.set_mode(mode)
    if mode == nil then
        storage.bb_attack_clock_mode = nil
        return true
    end
    if not MODES[mode] then
        return false, "attack clock mode must be 'per_team' or 'shared'"
    end
    storage.bb_attack_clock_mode = mode
    return true
end

---True when the clock drives the cycle rather than the vanilla dispatcher.
---
---Two teams are never on the clock, whatever the switch says: their schedule is
---the one the baseline replay records, tick for tick.
---@param team_count integer Teams of the round (`Teams.count()`).
---@return boolean
function Public.is_on(team_count)
    return team_count > 2 and Public.mode() == Public.PER_TEAM
end

return Public
