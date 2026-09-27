---@diagnostic disable
--
-- Pins `maps/biter_battles_v2/attack_clock.lua`, the attack-turn clock: when a
-- main attack cycle runs above two teams, whose turn it is, and which of the
-- two schedules is selected.
--
-- The one property the whole clock exists for is the LAST simulation here:
-- with three or four teams every team is attacked every `2 x interval`, exactly
-- as both sides are today -- and it stays every `2 x interval` after a team is
-- eliminated, because a dead team keeps its place in the rotation and its turn
-- is simply idle. Get that wrong in either direction and the round is played at
-- half or twice the pressure the evolution curves are tuned for, which nothing
-- downstream would notice.
--
-- What else it is here to catch:
--
--   * a period the DISPATCHER CANNOT RUN. `main.lua` only offers a slot every 30
--     ticks and a cycle occupies 240 of them, so a period that is not a multiple
--     of 30 loses steps and a period under 270 starts a cycle before the last
--     one has torn down. Every interval a league format can set (a multiple of
--     3600 between 3600 and 216000, `feeding_params.lua:199-210`) is checked at
--     two, three and four teams, and so is the rounding that catches anything
--     else;
--   * the VANILLA SCHEDULE. At two teams the clock's answers are the keys of
--     `tick_minute_functions` at the ticks the dispatcher fires them, 900..1140
--     of each minute. Two teams never reach the clock in the game -- that is the
--     point of the clock -- so this is the check that the arithmetic agrees
--     with the schedule it generalises;
--   * the EXACT tick lists of the two team counts that do reach it: 900 and 2700
--     of every minute at four teams, 900 / 3300 / 5700 drifting through the
--     minutes at three;
--   * that a step NEVER COINCIDES with one of the four `tick_minute_functions`
--     keys outside the cycle (300 raise_evo, 1170 autotagging, 1200
--     send_near_biters_to_silo, 1230 anti_afk). `main.lua` runs the minute's own
--     slot and then asks the clock for a step in the same 30-tick branch, so a
--     collision would run two of the minute's functions on one tick. It holds
--     only because `feeding_params.steps.attack_interval` is 3600 -- an interval
--     that is not a multiple of a minute collides at once -- which is exactly
--     the kind of fact that belongs in a test;
--   * the mode switch, against a fake `storage`: nil and anything a hand-edited
--     save might hold read as the clock, `set_mode` refuses the rest, and two
--     teams are never on the clock whatever it says.
--
-- The module loads outside Factorio: it requires nothing, touches no `game`, and
-- reads `storage` only in the three mode accessors. `storage` is the usual mock,
-- rebuilt per test because lunatest walks the test table with `pairs`.

local lunatest = require('lunatest')

storage = { ['_TEST'] = true }

local AttackClock = require('maps.biter_battles_v2.attack_clock')

local TICKS_PER_MINUTE = 3600

--- The intervals a league format can actually produce: a multiple of a minute,
--- from the vanilla cadence to the one-hour ceiling (`feeding_params.lua` limits
--- `attack_interval` to [3600, 216000] and steps it by 3600).
local function league_intervals()
    local intervals = {}
    for interval = TICKS_PER_MINUTE, 60 * TICKS_PER_MINUTE, TICKS_PER_MINUTE do
        intervals[#intervals + 1] = interval
    end
    return intervals
end

--- Four of them, spread over the range: the ones the tick-by-tick scans use, so
--- that a scan costs thousands of ticks rather than tens of millions.
local SAMPLE_INTERVALS = {
    TICKS_PER_MINUTE,
    2 * TICKS_PER_MINUTE,
    3 * TICKS_PER_MINUTE,
    60 * TICKS_PER_MINUTE,
}

--- Every tick of `[0, last_tick]` that starts a cycle, as an array.
local function cycle_starts(interval, team_count, last_tick)
    local starts = {}
    for tick = 0, last_tick do
        if AttackClock.step_at(tick, interval, team_count) == 1 then
            starts[#starts + 1] = tick
        end
    end
    return starts
end

--- The keys of `main.lua`'s `tick_minute_functions` that are NOT part of the
--- attack cycle, by what they run: the four slots the clock must leave alone.
--- `main.lua` runs them on their own `tick % 3600` key and then asks the clock
--- for a step in the same 30-tick slot, so a step that fell on one of these
--- ticks would run two of the minute's functions at once.
local NON_CYCLE_MINUTE_KEYS = {
    [300 * 1] = 'raise_evo',
    [300 * 3 + 30 * 9] = 'autotagging_outposters',
    [300 * 4] = 'send_near_biters_to_silo',
    [300 * 4 + 30 * 1] = 'anti_afk_system',
}

--- The nine keys the cycle owns, 900..1140.
local CYCLE_MINUTE_KEYS = {}
for wave = 0, 8 do
    CYCLE_MINUTE_KEYS[300 * 3 + 30 * wave] = true
end

local function gcd(a, b)
    while b ~= 0 do
        a, b = b, a % b
    end
    return a
end

--- After `lcm(period, 3600)` ticks both the clock's phase and the minute's
--- start again together, so a scan of that many ticks is the WHOLE schedule and
--- not a sample of it.
local function schedule_length(period)
    return period / gcd(period, TICKS_PER_MINUTE) * TICKS_PER_MINUTE
end

--- '900, 2700, 4500' -- a tick list as one comparable string.
local function ticks(list)
    local parts = {}
    for i = 1, #list do
        parts[i] = tostring(list[i])
    end
    return table.concat(parts, ', ')
end

--- The nine ticks a cycle starting at `start` runs its steps on.
local function cycle_from(start)
    local list = {}
    for step = 1, AttackClock.STEPS do
        list[step] = start + (step - 1) * AttackClock.STEP_SPACING
    end
    return list
end

function setup()
    storage = { ['_TEST'] = true }
    game = nil
end

-- ---------------------------------------------------------------------------
-- The period
-- ---------------------------------------------------------------------------

function test_the_period_is_two_intervals_shared_out_over_the_teams()
    -- The whole decision in three numbers: one cycle per interval at two teams,
    -- one and a half at three, two at four -- so a team's turn always comes
    -- round after two intervals.
    lunatest.assert_equal(3600, AttackClock.period(TICKS_PER_MINUTE, 2), 'two teams, default interval')
    lunatest.assert_equal(2400, AttackClock.period(TICKS_PER_MINUTE, 3), 'three teams, default interval')
    lunatest.assert_equal(1800, AttackClock.period(TICKS_PER_MINUTE, 4), 'four teams, default interval')

    -- A longer interval stretches the clock by the same factor; whole cycles are
    -- never dropped by `skip_attack_cycle` above two teams.
    lunatest.assert_equal(4800, AttackClock.period(2 * TICKS_PER_MINUTE, 3), 'three teams, two-minute interval')
    lunatest.assert_equal(3600, AttackClock.period(2 * TICKS_PER_MINUTE, 4), 'four teams, two-minute interval')
    lunatest.assert_equal(7200, AttackClock.period(3 * TICKS_PER_MINUTE, 3), 'three teams, three-minute interval')
    lunatest.assert_equal(108000, AttackClock.period(60 * TICKS_PER_MINUTE, 4), 'four teams, the hour ceiling')
end

function test_every_interval_a_league_format_can_set_gives_a_usable_period()
    for _, interval in ipairs(league_intervals()) do
        for team_count = 2, 4 do
            local what = 'interval ' .. interval .. ', ' .. team_count .. ' teams'
            local period = AttackClock.period(interval, team_count)

            -- None of them needs the rounding: twice a multiple of 3600 divides
            -- exactly by 2, 3 and 4.
            lunatest.assert_equal(2 * interval / team_count, period, what .. ': exactly two intervals a team')
            lunatest.assert_equal(0, period % AttackClock.STEP_SPACING, what .. ': lands on a dispatcher slot')
            lunatest.assert_true(period >= AttackClock.MIN_PERIOD, what .. ': room for a whole cycle')
        end
    end
end

function test_a_period_that_does_not_land_on_the_dispatcher_is_rounded_up()
    -- Nothing reachable today, but the interval is a tunable number: one that
    -- does not divide gives a marginally FASTER clock rather than steps the
    -- 30-tick dispatcher would silently drop.
    lunatest.assert_equal(690, AttackClock.period(1000, 3), '2000/3 = 666.7 rounds up to 690')
    lunatest.assert_equal(2010, AttackClock.period(3000, 3), '2000 rounds up to 2010')

    -- And the floor: a cycle is 240 ticks, so two cycles can never be closer
    -- together than 270 however short the interval gets.
    lunatest.assert_equal(270, AttackClock.MIN_PERIOD, 'the floor is one cycle plus a slot')
    lunatest.assert_equal(270, AttackClock.period(30, 4), 'an absurd interval is held at the floor')
    lunatest.assert_equal(270, AttackClock.period(0, 4), 'and so is no interval at all')
    lunatest.assert_true(
        AttackClock.MIN_PERIOD > AttackClock.CYCLE_LENGTH,
        'the floor is longer than the cycle it has to fit'
    )
end

-- ---------------------------------------------------------------------------
-- The nine steps
-- ---------------------------------------------------------------------------

function test_the_nine_steps_of_a_cycle_are_the_nine_keys_of_the_minute()
    -- Setup, seven waves, teardown -- and the keys are the ones `main.lua` keys
    -- `tick_minute_functions` by, so the clock runs the same nine functions
    -- under the same nine profiler entries.
    lunatest.assert_equal(9, AttackClock.STEPS, 'nine steps')
    lunatest.assert_equal(240, AttackClock.CYCLE_LENGTH, 'spanning 240 ticks')
    lunatest.assert_equal(900, AttackClock.CYCLE_START_KEY, 'from the vanilla setup slot')

    for step, tick in ipairs(cycle_from(900)) do
        local what = 'step ' .. step .. ' at tick ' .. tick
        lunatest.assert_equal(step, AttackClock.step_at(tick, TICKS_PER_MINUTE, 3), what .. ' (three teams)')
        lunatest.assert_equal(step, AttackClock.step_at(tick, TICKS_PER_MINUTE, 4), what .. ' (four teams)')
        lunatest.assert_equal(
            900 + (step - 1) * 30,
            AttackClock.step_key(tick, TICKS_PER_MINUTE, 4),
            what .. ': the tick_minute_functions key'
        )
    end

    -- The second cycle of a four-team minute carries the same nine keys at
    -- different ticks: that is the whole trick of the dispatch.
    for step, tick in ipairs(cycle_from(2700)) do
        lunatest.assert_equal(
            900 + (step - 1) * 30,
            AttackClock.step_key(tick, TICKS_PER_MINUTE, 4),
            'the cycle at 2700 reuses key ' .. (900 + (step - 1) * 30)
        )
    end

    lunatest.assert_nil(AttackClock.step_at(1170, TICKS_PER_MINUTE, 4), 'the slot after the teardown is not a step')
    lunatest.assert_nil(AttackClock.step_key(1170, TICKS_PER_MINUTE, 4), 'and has no key')
    lunatest.assert_nil(AttackClock.step_at(915, TICKS_PER_MINUTE, 4), 'nor is a tick between two slots')
end

function test_four_teams_run_a_cycle_at_tick_900_and_2700_of_every_minute()
    lunatest.assert_equal(
        '900, 2700, 4500, 6300',
        ticks(cycle_starts(TICKS_PER_MINUTE, 4, 2 * TICKS_PER_MINUTE - 1)),
        'two cycles a minute, the first on the vanilla tick'
    )
end

function test_three_teams_drift_through_the_minute()
    -- 2400 does not divide 3600, so the cycle walks: 900, 3300, 5700, and back
    -- to 900 three minutes later. Nothing depends on where in the minute a cycle
    -- falls -- the other slots of the table are elsewhere.
    lunatest.assert_equal(
        '900, 3300, 5700',
        ticks(cycle_starts(TICKS_PER_MINUTE, 3, 2 * TICKS_PER_MINUTE - 1)),
        'three cycles in two minutes'
    )
    lunatest.assert_equal(
        '900, 3300, 5700, 8100, 10500, 12900',
        ticks(cycle_starts(TICKS_PER_MINUTE, 3, 4 * TICKS_PER_MINUTE - 1)),
        'and the phase returns after three minutes'
    )
end

function test_two_teams_reproduce_the_vanilla_dispatcher()
    -- The game never puts two teams on the clock. This is the check that the
    -- generalisation IS one: at two teams the clock fires the same keys on the
    -- same ticks as `tick % 3600` does today.
    for tick = 0, 4 * TICKS_PER_MINUTE - 1 do
        local key = tick % TICKS_PER_MINUTE
        local vanilla = nil
        if tick % 30 == 0 and key >= 900 and key <= 1140 then
            vanilla = key
        end
        lunatest.assert_equal(vanilla, AttackClock.step_key(tick, TICKS_PER_MINUTE, 2), 'tick ' .. tick)
    end
end

function test_every_step_tick_is_a_multiple_of_thirty()
    -- A step on any other tick is a step that never runs: `main.lua` only asks
    -- the clock inside `tick % 30 == 0`. Every tick of two periods is tried, the
    -- 29 out of 30 the dispatcher never offers included.
    for _, interval in ipairs({ TICKS_PER_MINUTE, 2 * TICKS_PER_MINUTE }) do
        for team_count = 2, 4 do
            local period = AttackClock.period(interval, team_count)
            for tick = 0, 2 * period do
                if AttackClock.step_at(tick, interval, team_count) then
                    lunatest.assert_equal(
                        0,
                        tick % AttackClock.STEP_SPACING,
                        'interval ' .. interval .. ', ' .. team_count .. ' teams: step at tick ' .. tick
                    )
                end
            end
        end
    end
end

function test_a_cycle_never_overlaps_the_next()
    -- Exactly nine steps per period, in order, and a free slot between the
    -- teardown and the next setup. Scanned over the slots the dispatcher offers
    -- (the test above is what rules out a step between two of them).
    for _, interval in ipairs(SAMPLE_INTERVALS) do
        for team_count = 2, 4 do
            local what = 'interval ' .. interval .. ', ' .. team_count .. ' teams'
            local period = AttackClock.period(interval, team_count)
            local seen = 0
            local last_step = 0
            for tick = 900, 900 + 2 * period - 1, AttackClock.STEP_SPACING do
                local step = AttackClock.step_at(tick, interval, team_count)
                if step then
                    seen = seen + 1
                    if last_step ~= 0 then
                        local expected = last_step % AttackClock.STEPS + 1
                        lunatest.assert_equal(expected, step, what .. ': the steps run in order at tick ' .. tick)
                    end
                    last_step = step
                end
            end
            lunatest.assert_equal(2 * AttackClock.STEPS, seen, what .. ': nine steps per period, no more')
            lunatest.assert_true(
                period - AttackClock.CYCLE_LENGTH >= AttackClock.STEP_SPACING,
                what .. ': a free slot between the teardown and the next setup'
            )
        end
    end
end

function test_a_step_never_collides_with_a_minute_key_outside_the_cycle()
    -- `main.lua` dispatches the minute's own slots first and then
    -- asks the clock for a step, in the same `tick % 30 == 0` branch. The
    -- dispatch only holds together while the clock's steps and the four
    -- non-cycle keys of `tick_minute_functions` never fall on the same tick --
    -- and that is not something `attack_clock.lua` checks, it is something the
    -- arithmetic happens to give: the period is a multiple of 600 for every
    -- interval the parameter set allows, so `gcd(period, 3600)` is at least
    -- 1200 and the reachable `tick % 3600` of a step stays in 900..1140,
    -- 2100..2340, 2700..2940 or 3300..3540. Scanned exhaustively rather than
    -- argued: every interval a league format can set, three and four teams, a
    -- whole schedule each (the clock's phase and the minute realign after
    -- `lcm(period, 3600)` ticks), at the 30-tick slots the dispatcher offers.
    local problems = {}
    for _, interval in ipairs(league_intervals()) do
        for _, team_count in ipairs({ 3, 4 }) do
            local period = AttackClock.period(interval, team_count)
            local what = 'interval ' .. interval .. ', ' .. team_count .. ' teams'
            for tick = 0, schedule_length(period) - 1, AttackClock.STEP_SPACING do
                local step_key = AttackClock.step_key(tick, interval, team_count)
                if step_key then
                    local minute_key = tick % TICKS_PER_MINUTE
                    if NON_CYCLE_MINUTE_KEYS[minute_key] then
                        problems[#problems + 1] = what
                            .. ': a step at tick '
                            .. tick
                            .. ' collides with '
                            .. NON_CYCLE_MINUTE_KEYS[minute_key]
                            .. ' (key '
                            .. minute_key
                            .. ')'
                    end
                    if not CYCLE_MINUTE_KEYS[step_key] then
                        problems[#problems + 1] = what .. ': step at tick ' .. tick .. ' carries key ' .. step_key
                    end
                end
            end
        end
    end
    lunatest.assert_equal(0, #problems, problems[1] or 'no collision')
end

-- ---------------------------------------------------------------------------
-- The turn cursor
-- ---------------------------------------------------------------------------

function test_the_turn_walks_every_playing_team_including_the_dead()
    local four = { 'north', 'east', 'south', 'west' }

    lunatest.assert_equal('east', AttackClock.next_turn(four, 'north'), 'clockwise round the ring')
    lunatest.assert_equal('south', AttackClock.next_turn(four, 'east'))
    lunatest.assert_equal('west', AttackClock.next_turn(four, 'south'))
    lunatest.assert_equal('north', AttackClock.next_turn(four, 'west'), 'and wraps')

    -- The point of the clock: the list is the teams PLAYING the round, and
    -- nothing here asks who is still alive. An eliminated team keeps its slot --
    -- its turn is the idle one -- so the others wait exactly as long as before.
    local three = { 'north', 'east', 'south' }
    lunatest.assert_equal('north', AttackClock.next_turn(three, 'south'), 'three teams wrap at the third')

    -- A cursor that is not playing this round -- a save from a four-team round,
    -- or nothing set yet -- restarts the rotation rather than sticking.
    lunatest.assert_equal('north', AttackClock.next_turn(three, 'west'), 'a cursor that is not playing restarts')
    lunatest.assert_equal('north', AttackClock.next_turn(three, nil), 'and so does no cursor at all')
    lunatest.assert_nil(AttackClock.next_turn({}, 'north'), 'nobody playing, nobody next')
end

function test_every_team_is_attacked_every_two_intervals()
    -- The design rule, simulated: run the clock and the cursor over the
    -- dispatcher's slots and measure the gap between two attacks on the same
    -- team. It must be two intervals for every team at every team count, and it
    -- must STAY two intervals after a team is eliminated -- the survivors' turns
    -- may not come round any faster because someone died.
    local ROTATIONS = 8
    for _, interval in ipairs({ TICKS_PER_MINUTE, 3 * TICKS_PER_MINUTE }) do
        for _, playing in ipairs({ { 'north', 'east', 'south' }, { 'north', 'east', 'south', 'west' } }) do
            local team_count = #playing
            local period = AttackClock.period(interval, team_count)
            local what = 'interval ' .. interval .. ', ' .. team_count .. ' teams'

            -- `east` falls two full rotations in; from its next turn on it is
            -- scheduled exactly as before and attacked no longer.
            local eliminated_at = 900 + 2 * team_count * period
            local cursor = playing[1]
            local last_attack = {}
            local attacks = {}
            for _, team in ipairs(playing) do
                attacks[team] = 0
            end

            local first = 900
            local last = 900 + ROTATIONS * team_count * period - 1
            for tick = first, last, AttackClock.STEP_SPACING do
                local step = AttackClock.step_at(tick, interval, team_count)
                if step == 1 then
                    if not (cursor == 'east' and tick > eliminated_at) then
                        attacks[cursor] = attacks[cursor] + 1
                        local previous = last_attack[cursor]
                        if previous then
                            lunatest.assert_equal(
                                2 * interval,
                                tick - previous,
                                what .. ': ' .. cursor .. ' attacked again at tick ' .. tick
                            )
                        end
                        last_attack[cursor] = tick
                    end
                elseif step == AttackClock.STEPS then
                    cursor = AttackClock.next_turn(playing, cursor)
                end
            end

            -- One turn a rotation for the survivors; `east` had two before it
            -- died and its idle turns count for nothing.
            lunatest.assert_equal(ROTATIONS, attacks['north'], what .. ': north attacked once a rotation')
            lunatest.assert_equal(ROTATIONS, attacks['south'], what .. ': south attacked once a rotation')
            lunatest.assert_equal(2, attacks['east'], what .. ': east stopped being attacked when it died')
            lunatest.assert_equal(
                team_count * period,
                2 * interval,
                what .. ': a rotation of the ring is two intervals long'
            )
        end
    end
end

-- ---------------------------------------------------------------------------
-- The switch
-- ---------------------------------------------------------------------------

function test_the_mode_defaults_to_the_clock()
    lunatest.assert_nil(storage.bb_attack_clock_mode, 'nothing is written until someone sets it')
    lunatest.assert_equal(AttackClock.PER_TEAM, AttackClock.mode(), 'nil reads as the clock')

    storage.bb_attack_clock_mode = AttackClock.SHARED
    lunatest.assert_equal('shared', AttackClock.mode(), 'and a set value reads back')

    storage.bb_attack_clock_mode = 'one cycle per fortnight'
    lunatest.assert_equal(AttackClock.PER_TEAM, AttackClock.mode(), 'a value no version wrote reads as the clock')
end

function test_setting_the_mode_is_validated()
    lunatest.assert_true(AttackClock.set_mode(AttackClock.SHARED), "'shared' is accepted")
    lunatest.assert_equal('shared', storage.bb_attack_clock_mode, 'and stored as it is')

    local ok, reason = AttackClock.set_mode('per-team')
    lunatest.assert_false(ok, 'a near miss is refused')
    lunatest.assert_equal("attack clock mode must be 'per_team' or 'shared'", reason)
    lunatest.assert_equal('shared', storage.bb_attack_clock_mode, 'and leaves the switch where it was')

    lunatest.assert_false(AttackClock.set_mode(2), 'a number is refused')
    lunatest.assert_false(AttackClock.set_mode(true), 'a boolean is refused')
    lunatest.assert_equal('shared', storage.bb_attack_clock_mode, 'still where it was')

    lunatest.assert_true(AttackClock.set_mode(AttackClock.PER_TEAM), "'per_team' is accepted")
    lunatest.assert_equal('per_team', storage.bb_attack_clock_mode)

    lunatest.assert_true(AttackClock.set_mode(nil), 'and no mode at all clears the switch')
    lunatest.assert_nil(storage.bb_attack_clock_mode, 'back to the key never having been written')
    lunatest.assert_equal(AttackClock.PER_TEAM, AttackClock.mode(), 'which is the clock')
end

function test_two_teams_are_never_on_the_clock()
    -- Whatever the switch says, a two-team round is dispatched by the table and
    -- turned by the legacy toggle: that schedule is the baseline replay.
    lunatest.assert_false(AttackClock.is_on(2), 'two teams, default mode')
    lunatest.assert_true(AttackClock.is_on(3), 'three teams, default mode')
    lunatest.assert_true(AttackClock.is_on(4), 'four teams, default mode')

    AttackClock.set_mode(AttackClock.SHARED)
    lunatest.assert_false(AttackClock.is_on(2), 'two teams, shared')
    lunatest.assert_false(AttackClock.is_on(3), 'three teams, shared')
    lunatest.assert_false(AttackClock.is_on(4), 'four teams, shared')

    AttackClock.set_mode(AttackClock.PER_TEAM)
    lunatest.assert_false(AttackClock.is_on(2), 'two teams, the clock asked for by name')
    lunatest.assert_true(AttackClock.is_on(4), 'four teams, the clock asked for by name')
end

lunatest.run()
