---@diagnostic disable
--
-- The N > 2 half of `maps/biter_battles_v2/match_format.lua`.
--
-- `tests/test-match-format.lua` pins the module as the two-team scenario uses
-- it and must keep doing exactly that, so the answers that only exist above two
-- teams live here instead:
--
--   * `describe()` names the match as it is played ('2v2v2', not the two-part
--     key of its parameter set) and says "each team every N min" above two
--     teams ("each side" is the two-team sentence, pinned unchanged in
--     tests/test-match-format.lua and below at two teams); N is the cadence of the
--     schedule that is actually running. Under the attack clock -- the default
--     above two teams -- a rotation of the ring is two intervals
--     whatever the team count is, so a 4-team round is told 2 min, not 4; under
--     the 'shared' fallback the wave serves one team per interval and N is
--     `interval * Teams.count()`. This file used to pin the fallback for both,
--     which was wrong: the sentence is what the operator
--     tunes the passive income curve against;
--   * `refresh_threat_income()` rebuilds the passive income of every biter
--     force from its evolution, and is called on every `/feeding-params`
--     change. Above two teams it must skip an ELIMINATED team: rebuilding its
--     income from the evolution it died with would undo `eliminate_team` and
--     start its threat pool growing again for the rest of the round. That was
--     a real bug, and this file is the test that would have caught it;
--   * the league's match record version 2:
--     the N-part format grammar, the `teams` array and every way it can be
--     wrong, what `team_count()` answers, the `[LEAGUE]` recognition line, what
--     `remote.call('bb_teams', 'match_info')` hands the daemon back, and -- the
--     one that guards the baseline -- the rule that a v1 record in a two-team
--     round logs NOTHING and writes no storage key, exactly as today;
--   * the MAP form of that record: `teams` keyed by force
--     name instead of ordered by hand. Same version, same contract, and ring
--     order supplied by the reader -- including the two things a hash table
--     would otherwise decide for it, which key an error names and which team is
--     checked first. The recognition line names the form it read, so the two
--     cannot be confused in a log.
--
-- Everything here is reachable outside Factorio: match_format, feeding_params
-- and teams all load with the usual `storage` mock, and the only thing
-- `Teams.eliminate` touches on `game` is the tick. `game` is nil for the whole
-- file, so anything that reached for it would error rather than pass.

local lunatest = require('lunatest')

storage = { ['_TEST'] = true }

local AttackClock = require('maps.biter_battles_v2.attack_clock')
local FeedingParams = require('maps.biter_battles_v2.feeding_params')
local MatchFormat = require('maps.biter_battles_v2.match_format')
local Teams = require('maps.biter_battles_v2.teams')

local TICKS_PER_MINUTE = 3600

--- Evolution 1.0 pays `passive_scale * 1 + passive_linear * 1` = 100 + 15 at an
--- income scale of 1 (the same number test-match-format.lua pins).
local INCOME_AT_EVO_ONE = 115

--- Nothing but `game.tick`, which is all `Teams.eliminate` reads.
local function mock_game(tick)
    game = { tick = tick or 0 }
end

--- Ask for `count` teams and start the round.
local function round_of(count)
    lunatest.assert_true(Teams.set_next_count(count), 'set_next_count(' .. tostring(count) .. ')')
    Teams.begin_round()
end

--- Every biter force of the roster at evolution 1.0, with an income of -1 so
--- that "was rewritten" and "was left alone" cannot be confused.
local function all_biter_forces_at_evo_one()
    storage.bb_evolution = {}
    storage.bb_threat_income = {}
    for _, team in ipairs(Teams.roster()) do
        storage.bb_evolution[Teams.biter_force(team)] = 1.0
        storage.bb_threat_income[Teams.biter_force(team)] = -1
    end
end

--- 'north_biters=115,east_biters=-1,...' -- the income of the whole roster, in
--- ring order, as one comparable string.
local function income_summary()
    local parts = {}
    for i, team in ipairs(Teams.roster()) do
        local force = Teams.biter_force(team)
        parts[i] = force .. '=' .. tostring(storage.bb_threat_income[force])
    end
    return table.concat(parts, ',')
end

--- What `log()` was handed. `log` is a Factorio global that does not exist out
--- here, so every test installs a capture and the ones that must stay silent
--- assert that it is still empty.
local logged = {}

--- The v2 record a daemon would write for the round now being played: one entry
--- per team of `Teams.all()`, in play order, `size` players each, and a format
--- of that many equal sizes joined by 'v'. The validation tests take one of
--- these and break exactly one field of it.
---@param size integer
---@return table
local function v2_record(size)
    local teams = {}
    local sizes = {}
    for i, team in ipairs(Teams.all()) do
        local players = {}
        for p = 1, size do
            players[p] = team .. '-' .. p
        end
        teams[i] = { name = team, players = players }
        sizes[i] = tostring(size)
    end
    return {
        id = 'L17',
        version = 2,
        ladder = 'main',
        go_tick = 123456,
        format = table.concat(sizes, 'v'),
        teams = teams,
    }
end

--- The same record with `teams` written as a MAP of force name to roster --
--- the shorter form a backend may write. It carries no
--- order of its own, so the reader supplies ring order.
---@param size integer
---@return table
local function v2_map_record(size)
    local teams = {}
    local sizes = {}
    for i, team in ipairs(Teams.all()) do
        local players = {}
        for p = 1, size do
            players[p] = team .. '-' .. p
        end
        teams[team] = players
        sizes[i] = tostring(size)
    end
    return {
        id = 'L18',
        version = 2,
        ladder = 'main',
        go_tick = 123456,
        format = table.concat(sizes, 'v'),
        teams = teams,
    }
end

--- Every violation of the v2 contract has the same consequence: the `teams`
--- array is dropped, the record is read from its `format` alone, and the line
--- names what was wrong. `parts` is how many teams that format names.
---@param reason string
---@param parts integer
---@param format string
local function assert_invalid(reason, parts, format)
    lunatest.assert_equal(parts, MatchFormat.team_count(), reason)
    lunatest.assert_equal(2, MatchFormat.team_size(), reason)
    lunatest.assert_equal('2v2', MatchFormat.format_key(), reason)
    lunatest.assert_equal(
        string.format(
            '[LEAGUE] record v2 invalid (%s) -> read from format alone: %d teams, format %s, params 2v2',
            reason,
            parts,
            format
        ),
        MatchFormat.recognised(),
        reason
    )
end

function setup()
    storage = { ['_TEST'] = true }
    game = nil
    logged = {}
    log = function(line)
        logged[#logged + 1] = line
    end
end

-- ---------------------------------------------------------------------------
-- describe(): "each side every N min" counts the teams of the round
-- ---------------------------------------------------------------------------

function test_describe_reports_two_intervals_a_team_under_the_attack_clock()
    -- MAJOR-3. The clock runs the cycle `count` times per rotation at a period
    -- of `2 * interval / count`, so a rotation is two intervals at every team
    -- count and the sentence says the same 2 min for 2, 3 and 4 teams. It used
    -- to say 3 and 4 -- the cadence of the schedule the attack clock replaced -- and
    -- this test was what pinned the wrong number in place.
    storage.bb_league_match = { id = 'L17', format = '2v2' }

    local expected = {
        [2] = '2v2 [league match L17] — passive income x1, wave every 3600 ticks (1 min, each side every 2 min)',
        [3] = '2v2v2 [league match L17] — passive income x1, wave every 3600 ticks (1 min, each team every 2 min)',
        [4] = '2v2v2v2 [league match L17] — passive income x1, wave every 3600 ticks (1 min, each team every 2 min)',
    }
    for _, count in ipairs({ 2, 3, 4 }) do
        round_of(count)
        lunatest.assert_equal(expected[count], MatchFormat.describe(), count .. ' teams')
    end
end

function test_describe_reports_the_shared_cadence_when_the_fallback_is_selected()
    -- `interval * count`, the first multi-team schedule: one cycle per interval, the
    -- cursor walking the ring. The measurement switch is the only way to reach
    -- it above two teams, and the sentence has to follow the switch.
    storage.bb_league_match = { id = 'L17', format = '2v2' }
    AttackClock.set_mode(AttackClock.SHARED)

    local expected = {
        [2] = '2v2 [league match L17] — passive income x1, wave every 3600 ticks (1 min, each side every 2 min)',
        [3] = '2v2v2 [league match L17] — passive income x1, wave every 3600 ticks (1 min, each team every 3 min)',
        [4] = '2v2v2v2 [league match L17] — passive income x1, wave every 3600 ticks (1 min, each team every 4 min)',
    }
    for _, count in ipairs({ 2, 3, 4 }) do
        round_of(count)
        lunatest.assert_equal(expected[count], MatchFormat.describe(), count .. ' teams')
    end
end

function test_a_widened_interval_stretches_both_schedules()
    storage.bb_league_match = { id = 'L17', format = '2v2' }
    storage.feeding_params = { ['2v2'] = { attack_interval = 2 * TICKS_PER_MINUTE } }

    -- Two intervals a team, whatever the count: 4 min at a two-minute interval.
    round_of(3)
    lunatest.assert_equal(
        '2v2v2 [league match L17] — passive income x1, wave every 7200 ticks (2 min, each team every 4 min)',
        MatchFormat.describe()
    )

    round_of(4)
    lunatest.assert_equal(
        '2v2v2v2 [league match L17] — passive income x1, wave every 7200 ticks (2 min, each team every 4 min)',
        MatchFormat.describe()
    )

    -- ... against `interval * count` under the fallback.
    AttackClock.set_mode(AttackClock.SHARED)
    round_of(3)
    lunatest.assert_equal(
        '2v2v2 [league match L17] — passive income x1, wave every 7200 ticks (2 min, each team every 6 min)',
        MatchFormat.describe()
    )

    round_of(4)
    lunatest.assert_equal(
        '2v2v2v2 [league match L17] — passive income x1, wave every 7200 ticks (2 min, each team every 8 min)',
        MatchFormat.describe()
    )
end

function test_an_elimination_does_not_change_what_the_format_says_about_itself()
    -- `describe()` reports the format, not the state of the round: the cadence
    -- of the dispatcher is a property of the match. Pinned so that a later
    -- change that wants "every #alive min" makes it deliberately.
    mock_game(600)
    storage.bb_league_match = { id = 'L17', format = '2v2' }
    round_of(4)
    local before = MatchFormat.describe()

    Teams.eliminate('east')

    lunatest.assert_equal(before, MatchFormat.describe())
    lunatest.assert_true(before:find('each team every 2 min', 1, true) ~= nil, before)
end

function test_an_unplayable_format_reports_the_same_above_two_teams()
    -- CHANGED WITH RECORD VERSION 2: this test used to use '2v2v2', which is now read.
    -- An ASYMMETRIC format never was playable and still is not -- one parameter
    -- set serves every team, so all the sizes must be equal -- which makes
    -- '2v2v1' exactly as unplayable above two teams as '2v3' is at two.
    storage.bb_league_match = { id = 'L17', format = '2v2v1' }
    round_of(3)
    lunatest.assert_equal(
        'league match L17 reports "2v2v1", which this scenario does not play — default set',
        MatchFormat.describe()
    )
    lunatest.assert_equal('default', MatchFormat.format_key())
end

function test_a_readable_three_team_format_describes_the_match_as_it_is_played()
    -- CHANGED 2026-09-27 (owner: "in a match with more than 2 teams we still
    -- see 2 teams"): `describe()` -- the Evo and threat panel's "Match:" line,
    -- the /feeding-params report and the retune announcement -- used to name
    -- the two-part parameter key ('2v2') of a '2v2v2' match. It now names the
    -- match as it is played; the parameter set it plays is still the '2v2'
    -- one (`format_key()`, pinned below), and the report names that key on a
    -- line of its own.
    storage.bb_league_match = { id = 'L17', format = '2v2v2' }
    round_of(3)
    lunatest.assert_equal(
        '2v2v2 [league match L17] — passive income x1, wave every 3600 ticks (1 min, each team every 2 min)',
        MatchFormat.describe()
    )
    lunatest.assert_equal('2v2', MatchFormat.format_key())
end

-- ---------------------------------------------------------------------------
-- display_label() / format_label(): the format as players read it
-- ---------------------------------------------------------------------------

function test_display_label_repeats_the_team_size_once_per_team()
    lunatest.assert_equal('2v2', MatchFormat.display_label(2, 2))
    lunatest.assert_equal('2v2v2', MatchFormat.display_label(2, 3))
    lunatest.assert_equal('1v1v1v1', MatchFormat.display_label(1, 4))
    lunatest.assert_equal('3v3v3', MatchFormat.display_label(3, 3))
    -- A count below two (or none) is read as two: the label never names fewer
    -- teams than a match has.
    lunatest.assert_equal('4v4', MatchFormat.display_label(4, 1))
    lunatest.assert_equal('4v4', MatchFormat.display_label(4, nil))
end

function test_display_label_at_two_teams_is_the_parameter_key()
    -- The rule that keeps every two-team sentence built from the label
    -- unchanged: at two teams the label IS '%dv%d', the key's spelling.
    for size = 1, 8 do
        lunatest.assert_equal(string.format('%dv%d', size, size), MatchFormat.display_label(size, 2))
    end
end

function test_format_label_follows_the_round_and_the_key_stays_two_parts()
    storage.bb_league_match = { id = 'L17', format = '2v2v2' }
    round_of(3)
    lunatest.assert_equal('2v2v2', MatchFormat.format_label())
    lunatest.assert_equal('2v2', MatchFormat.format_key())

    storage.bb_league_match = { id = 'L18', format = '1v1v1v1' }
    round_of(4)
    lunatest.assert_equal('1v1v1v1', MatchFormat.format_label())
    lunatest.assert_equal('1v1', MatchFormat.format_key())

    storage.bb_league_match = { id = 'L19', format = '2v2' }
    round_of(2)
    lunatest.assert_equal('2v2', MatchFormat.format_label())
    lunatest.assert_equal('2v2', MatchFormat.format_key())
end

function test_format_label_is_nil_without_a_readable_record()
    round_of(3)
    storage.bb_league_match = nil
    lunatest.assert_nil(MatchFormat.format_label())
    storage.bb_league_match = { id = 'L17', format = '2v2v1' }
    lunatest.assert_nil(MatchFormat.format_label())
    lunatest.assert_equal('default', MatchFormat.format_key())
end

-- ---------------------------------------------------------------------------
-- refresh_threat_income(): the active teams, minus the dead ones
-- ---------------------------------------------------------------------------

function test_refresh_threat_income_rewrites_the_three_biter_forces_of_a_three_team_round()
    round_of(3)
    all_biter_forces_at_evo_one()

    MatchFormat.refresh_threat_income()

    lunatest.assert_equal(
        'north_biters=115,east_biters=115,south_biters=115,west_biters=-1',
        income_summary(),
        'west does not play this round'
    )
end

function test_refresh_threat_income_rewrites_all_four_biter_forces_of_a_four_team_round()
    round_of(4)
    all_biter_forces_at_evo_one()

    MatchFormat.refresh_threat_income()

    lunatest.assert_equal('north_biters=115,east_biters=115,south_biters=115,west_biters=115', income_summary())
end

function test_refresh_threat_income_leaves_an_eliminated_team_at_zero()
    -- M3: `eliminate_team` sets the dead team's income to 0 and freezes its
    -- biters. A `/feeding-params` change must not rebuild it from the
    -- evolution the team died with.
    mock_game(900)
    round_of(4)
    all_biter_forces_at_evo_one()

    Teams.eliminate('east')
    storage.bb_threat_income[Teams.biter_force('east')] = 0 -- what eliminate_team does

    MatchFormat.refresh_threat_income()

    lunatest.assert_equal('north_biters=115,east_biters=0,south_biters=115,west_biters=115', income_summary())

    -- A second death changes nothing for the first one.
    Teams.eliminate('west')
    storage.bb_threat_income[Teams.biter_force('west')] = 0
    storage.bb_threat_income[Teams.biter_force('north')] = -1
    MatchFormat.refresh_threat_income()
    lunatest.assert_equal('north_biters=115,east_biters=0,south_biters=115,west_biters=0', income_summary())
end

function test_refresh_threat_income_covers_every_team_of_a_two_team_round()
    -- The alive/active switch is above two teams only: a two-team round walks
    -- `Teams.biter_forces()` whatever the alive flags say, exactly as the
    -- literal list it replaced did. (A two-team round cannot have a dead team
    -- while it is still being played -- the first silo to fall ends it.)
    mock_game(120)
    round_of(2)
    all_biter_forces_at_evo_one()
    Teams.eliminate('north')

    MatchFormat.refresh_threat_income()

    lunatest.assert_equal('north_biters=115,east_biters=-1,south_biters=115,west_biters=-1', income_summary())
end

function test_the_income_of_a_round_that_shrank_is_left_where_the_big_round_left_it()
    -- 4 -> 2 inside one save: east and west are not playing, so nothing
    -- rewrites their income. Nothing reads it either -- the threat tick, the
    -- wave dispatcher and the GUI all walk the round's team list.
    round_of(4)
    all_biter_forces_at_evo_one()
    MatchFormat.refresh_threat_income()
    lunatest.assert_equal(INCOME_AT_EVO_ONE, storage.bb_threat_income.east_biters)

    round_of(2)
    storage.bb_threat_income.north_biters = -1
    storage.bb_threat_income.south_biters = -1

    MatchFormat.refresh_threat_income()

    lunatest.assert_equal('north_biters=115,east_biters=115,south_biters=115,west_biters=115', income_summary())
end

-- ---------------------------------------------------------------------------
-- The format grammar above two teams (record v2)
-- ---------------------------------------------------------------------------

function test_a_format_names_one_size_per_team_for_two_three_and_four_teams()
    local formats = { [2] = '2v2', [3] = '2v2v2', [4] = '2v2v2v2' }
    for _, count in ipairs({ 2, 3, 4 }) do
        storage.bb_league_match = { id = 'L17', format = formats[count] }
        lunatest.assert_equal(count, MatchFormat.team_count(), formats[count])
        lunatest.assert_equal(2, MatchFormat.team_size(), formats[count])
    end
end

function test_the_parameter_key_stays_two_parts_whatever_the_team_count()
    -- `storage.feeding_params` is keyed by these strings (feeding_params.lua
    -- :42-47) and the league's tuning overrides live under them, so the key may
    -- not grow a team-count axis: a 3v3v3v3 match plays the '3v3' set.
    local formats = { '1v1v1', '3v3v3', '1v1v1v1', '8v8v8v8' }
    local keys = { '1v1', '3v3', '1v1', '8v8' }
    for i, format in ipairs(formats) do
        storage.bb_league_match = { id = 'L17', format = format }
        lunatest.assert_equal(keys[i], MatchFormat.format_key(), format)
        lunatest.assert_true(FeedingParams.is_format_key(MatchFormat.format_key()), format)
    end
end

function test_the_n_part_grammar_keeps_the_tolerance_the_two_part_one_had()
    -- Case folded and every space stripped anywhere in the string -- exactly
    -- what ' 3V3 ' and '3 v 3' get at two teams (test-match-format.lua:80-90).
    for _, format in ipairs({ ' 2V2V2 ', '2 v 2 v 2', '2V2 v2' }) do
        storage.bb_league_match = { id = 'L17', format = format }
        lunatest.assert_equal(3, MatchFormat.team_count(), format)
        lunatest.assert_equal(2, MatchFormat.team_size(), format)
        lunatest.assert_equal('2v2', MatchFormat.format_key(), format)
    end
end

function test_the_sizes_of_an_n_part_format_must_all_be_equal()
    -- Asymmetric formats are not needed and are not played: one parameter set
    -- serves every team, so '2v2v1' is unreadable the way '2v3' always was.
    for _, format in ipairs({ '2v2v1', '1v2v2', '2v3v2', '2v2v2v1' }) do
        storage.bb_league_match = { id = 'L17', format = format }
        lunatest.assert_nil(MatchFormat.team_size(), format)
        lunatest.assert_nil(MatchFormat.team_count(), format)
        lunatest.assert_equal('default', MatchFormat.format_key(), format)
    end
end

function test_a_format_outside_two_to_four_teams_or_one_to_eight_players_is_unreadable()
    for _, format in ipairs({ '2v2v2v2v2', '1v1v1v1v1v1', '0v0v0', '9v9v9', '2v2v', '2vv2', 'v2v2', '2' }) do
        storage.bb_league_match = { id = 'L17', format = format }
        lunatest.assert_nil(MatchFormat.team_size(), format)
        lunatest.assert_nil(MatchFormat.team_count(), format)
        lunatest.assert_equal('default', MatchFormat.format_key(), format)
    end
end

-- ---------------------------------------------------------------------------
-- team_count(): what the RECORD says, not what the round plays
-- ---------------------------------------------------------------------------

function test_team_count_is_nil_with_no_record_and_with_an_unreadable_one()
    lunatest.assert_nil(MatchFormat.team_count())

    storage.bb_league_match = { id = 'L17', format = '2v3' }
    lunatest.assert_nil(MatchFormat.team_count())

    storage.bb_league_match = 'nonsense'
    lunatest.assert_nil(MatchFormat.team_count())
end

function test_team_count_of_a_v1_record_is_the_parts_of_its_format()
    storage.bb_league_match = { id = 'L17', format = '2v2', north = { 'a', 'b' }, south = { 'c', 'd' } }
    lunatest.assert_equal(2, MatchFormat.team_count())
end

function test_team_count_of_a_valid_v2_record_is_the_length_of_its_teams_array()
    round_of(4)
    storage.bb_league_match = v2_record(2)
    lunatest.assert_equal(4, MatchFormat.team_count())
end

-- ---------------------------------------------------------------------------
-- Validating a version 2 record: every violation falls back to `format` alone
-- ---------------------------------------------------------------------------

function test_a_valid_v2_record_is_read_for_two_three_and_four_teams()
    for _, count in ipairs({ 2, 3, 4 }) do
        round_of(count)
        storage.bb_league_match = v2_record(3)
        local label = count .. ' teams'
        lunatest.assert_equal(count, MatchFormat.team_count(), label)
        lunatest.assert_equal(3, MatchFormat.team_size(), label)
        lunatest.assert_equal('3v3', MatchFormat.format_key(), label)
        lunatest.assert_equal(
            string.format(
                '[LEAGUE] record v2: %d teams as array, format %s, params 3v3',
                count,
                storage.bb_league_match.format
            ),
            MatchFormat.recognised(),
            label
        )
    end
end

function test_a_v2_record_with_no_teams_array_is_read_from_its_format()
    round_of(3)
    local record = v2_record(2)
    record.teams = nil
    storage.bb_league_match = record
    assert_invalid('no teams array', 3, '2v2v2')
end

function test_a_v2_teams_array_of_the_wrong_length_is_refused()
    round_of(3)
    local short = v2_record(2)
    short.teams[3] = nil
    short.teams[2] = nil
    storage.bb_league_match = short
    assert_invalid('teams array is 1 long, not 2..4', 3, '2v2v2')

    round_of(4)
    local long = v2_record(2)
    long.teams[5] = { name = 'north', players = { 'x', 'y' } }
    storage.bb_league_match = long
    assert_invalid('teams array is 5 long, not 2..4', 4, '2v2v2v2')
end

function test_a_v2_record_whose_team_count_is_not_its_formats_is_refused()
    -- The case to guard against: a backend that grew a `teams` array but
    -- still writes the two-team spelling. Read from the format alone it is a
    -- two-team match, and the mismatch clause says so.
    round_of(3)
    local record = v2_record(2)
    record.teams[3] = nil
    storage.bb_league_match = record
    assert_invalid("2 teams but format '2v2v2' names 3", 3, '2v2v2')
end

function test_a_v2_entry_that_is_not_a_table_is_refused()
    round_of(3)
    local record = v2_record(2)
    record.teams[2] = 'east'
    storage.bb_league_match = record
    assert_invalid('teams[2] is not a table', 3, '2v2v2')
end

function test_a_v2_team_name_off_the_roster_is_refused()
    round_of(3)
    local record = v2_record(2)
    record.teams[2].name = 'northwest'
    storage.bb_league_match = record
    assert_invalid("teams[2].name 'northwest' is not a team", 3, '2v2v2')

    record.teams[2].name = nil
    assert_invalid("teams[2].name 'nil' is not a team", 3, '2v2v2')
end

function test_a_repeated_v2_team_name_is_refused()
    round_of(3)
    local record = v2_record(2)
    record.teams[2].name = record.teams[1].name
    storage.bb_league_match = record
    assert_invalid("teams[2] repeats 'north'", 3, '2v2v2')
end

function test_a_v2_roster_that_is_not_an_array_is_refused()
    round_of(3)
    local record = v2_record(2)
    record.teams[2].players = nil
    storage.bb_league_match = record
    assert_invalid('teams[2] (east) has no players array', 3, '2v2v2')
end

function test_a_v2_roster_of_the_wrong_length_is_refused()
    -- Uneven rosters are refused by the league today and stay refused here: the
    -- format's size is the size of every team.
    round_of(3)
    local record = v2_record(2)
    record.teams[2].players = { 'only-one' }
    storage.bb_league_match = record
    assert_invalid('teams[2] (east) roster is 1, the format says 2', 3, '2v2v2')
end

function test_a_v2_player_that_is_not_a_name_is_refused()
    round_of(3)
    local record = v2_record(2)
    record.teams[2].players[2] = 7
    storage.bb_league_match = record
    assert_invalid('teams[2] (east) player 2 is not a name', 3, '2v2v2')
end

function test_a_v2_record_with_an_unreadable_format_is_simply_unreadable()
    -- With no readable format there is no size to measure the rosters against,
    -- so the `teams` array is not held to a contract it cannot be checked
    -- against. The record reads as unreadable, like any other, and the match
    -- plays 'default'.
    round_of(3)
    local record = v2_record(2)
    record.format = '2v2v1'
    storage.bb_league_match = record
    lunatest.assert_nil(MatchFormat.team_count())
    lunatest.assert_nil(MatchFormat.team_size())
    lunatest.assert_equal('default', MatchFormat.format_key())
    lunatest.assert_equal("[LEAGUE] record unreadable (format '2v2v1') -> default parameters", MatchFormat.recognised())
end

-- ---------------------------------------------------------------------------
-- The MAP form of a version 2 record: `teams` keyed by force name
-- ---------------------------------------------------------------------------
--
-- Same version, same contract, no order of its own -- so the reader supplies
-- ring order and the recognition line says which of the two forms it read.

function test_a_map_form_record_is_read_for_two_three_and_four_teams()
    for _, count in ipairs({ 2, 3, 4 }) do
        round_of(count)
        storage.bb_league_match = v2_map_record(3)
        local label = count .. ' teams'
        lunatest.assert_equal(count, MatchFormat.team_count(), label)
        lunatest.assert_equal(3, MatchFormat.team_size(), label)
        lunatest.assert_equal('3v3', MatchFormat.format_key(), label)
        lunatest.assert_equal(
            string.format(
                '[LEAGUE] record v2: %d teams as map, format %s, params 3v3',
                count,
                storage.bb_league_match.format
            ),
            MatchFormat.recognised(),
            label
        )
    end
end

function test_the_recognition_line_tells_the_two_forms_apart()
    round_of(3)
    storage.bb_league_match = v2_record(2)
    lunatest.assert_equal('[LEAGUE] record v2: 3 teams as array, format 2v2v2, params 2v2', MatchFormat.recognised())
    storage.bb_league_match = v2_map_record(2)
    lunatest.assert_equal('[LEAGUE] record v2: 3 teams as map, format 2v2v2, params 2v2', MatchFormat.recognised())
end

function test_a_two_team_map_form_record_reads_as_the_two_team_match_it_is()
    -- The form the daemon would write for today's match if it dropped the
    -- `north =` / `south =` mirror. Two teams, the '2v2' parameter set.
    round_of(2)
    storage.bb_league_match = v2_map_record(2)
    lunatest.assert_equal('2v2', storage.bb_league_match.format)
    lunatest.assert_equal(2, MatchFormat.team_count())
    lunatest.assert_equal('[LEAGUE] record v2: 2 teams as map, format 2v2, params 2v2', MatchFormat.recognised())
end

function test_match_info_hands_the_map_form_back_to_the_daemon()
    round_of(4)
    storage.bb_league_match = v2_map_record(2)
    local info = MatchFormat.match_info()
    lunatest.assert_equal(2, info.version)
    lunatest.assert_equal(4, info.team_count)
    lunatest.assert_equal(2, info.team_size)
    lunatest.assert_equal('2v2', info.format_key)
    lunatest.assert_equal('[LEAGUE] record v2: 4 teams as map, format 2v2v2v2, params 2v2', info.recognised)
end

function test_a_map_key_that_is_not_a_team_is_refused()
    round_of(3)
    local record = v2_map_record(2)
    record.teams['northwest'] = { 'x', 'y' }
    record.teams['east'] = nil
    storage.bb_league_match = record
    assert_invalid("teams key 'northwest' is not a team", 3, '2v2v2')
end

function test_the_unknown_key_named_is_the_first_in_sorted_order()
    -- `pairs` over a table written by another process has no order this
    -- scenario controls, and the line it produces goes to the log. Sorting the
    -- offending names is what makes the line the same on every host.
    round_of(3)
    local record = v2_map_record(2)
    record.teams['zulu'] = { 'x', 'y' }
    record.teams['alpha'] = { 'x', 'y' }
    storage.bb_league_match = record
    assert_invalid("teams key 'alpha' is not a team", 3, '2v2v2')
end

function test_a_map_missing_a_team_is_refused()
    round_of(3)
    local record = v2_map_record(2)
    record.teams['east'] = nil
    storage.bb_league_match = record
    assert_invalid("2 teams but format '2v2v2' names 3", 3, '2v2v2')
end

function test_a_map_with_a_team_too_many_is_refused()
    round_of(3)
    local record = v2_map_record(2)
    record.teams['west'] = { 'w-1', 'w-2' }
    storage.bb_league_match = record
    assert_invalid("4 teams but format '2v2v2' names 3", 3, '2v2v2')
end

function test_a_map_of_one_team_is_refused_for_its_length()
    -- A map can never be longer than the roster, so the length check only ever
    -- fires below the floor -- which is what a record written before its second
    -- team had signed up looks like.
    round_of(3)
    local record = v2_map_record(2)
    record.teams['east'] = nil
    record.teams['south'] = nil
    storage.bb_league_match = record
    assert_invalid('teams map is 1 long, not 2..4', 3, '2v2v2')
end

function test_a_map_roster_that_is_not_an_array_is_refused()
    round_of(3)
    local record = v2_map_record(2)
    record.teams['east'] = 'e-1,e-2'
    storage.bb_league_match = record
    assert_invalid("teams['east'] has no players array", 3, '2v2v2')
end

function test_a_map_roster_of_the_wrong_size_is_refused()
    round_of(3)
    local record = v2_map_record(2)
    record.teams['east'] = { 'only-one' }
    storage.bb_league_match = record
    assert_invalid("teams['east'] roster is 1, the format says 2", 3, '2v2v2')
end

function test_a_map_player_that_is_not_a_name_is_refused()
    round_of(3)
    local record = v2_map_record(2)
    record.teams['east'][2] = 7
    storage.bb_league_match = record
    assert_invalid("teams['east'] player 2 is not a name", 3, '2v2v2')
end

function test_a_map_is_read_in_ring_order()
    -- Two teams are broken at once. The one the line names is the one that
    -- comes first in the ring -- north before east, east before south -- and
    -- not whichever `pairs` happened to reach first.
    round_of(3)
    local record = v2_map_record(2)
    record.teams['north'] = { 'only-one' }
    record.teams['south'] = { 'only-one' }
    storage.bb_league_match = record
    assert_invalid("teams['north'] roster is 1, the format says 2", 3, '2v2v2')

    record = v2_map_record(2)
    record.teams['east'] = { 'only-one' }
    record.teams['south'] = { 'only-one' }
    storage.bb_league_match = record
    assert_invalid("teams['east'] roster is 1, the format says 2", 3, '2v2v2')
end

function test_a_map_naming_a_team_outside_the_round_is_read_and_the_mismatch_named()
    -- The record describes a match, `Teams.count()` is what is being played.
    -- The map form accepts a roster team that is not in this round, exactly as
    -- the array form does, and the mismatch clause is what says so.
    round_of(2)
    storage.bb_league_match = {
        id = 'L18',
        version = 2,
        format = '2v2v2',
        teams = {
            north = { 'a', 'b' },
            east = { 'c', 'd' },
            south = { 'e', 'f' },
        },
    }
    lunatest.assert_equal(3, MatchFormat.team_count())
    lunatest.assert_equal(
        '[LEAGUE] record v2: 3 teams as map, format 2v2v2, params 2v2; mismatch: record says 3 teams, the round has 2',
        MatchFormat.recognised()
    )
end

function test_a_map_form_record_with_an_unreadable_format_is_simply_unreadable()
    round_of(3)
    local record = v2_map_record(2)
    record.format = '2v2v1'
    storage.bb_league_match = record
    lunatest.assert_nil(MatchFormat.team_count())
    lunatest.assert_nil(MatchFormat.team_size())
    lunatest.assert_equal('default', MatchFormat.format_key())
    lunatest.assert_equal("[LEAGUE] record unreadable (format '2v2v1') -> default parameters", MatchFormat.recognised())
end

function test_an_empty_teams_table_is_still_read_as_an_array()
    -- Neither form: no first element and no key at all. It stays an array, so
    -- the violation is the one version 2 first produced for it, word for word.
    round_of(3)
    local record = v2_record(2)
    record.teams = {}
    storage.bb_league_match = record
    assert_invalid('teams array is 0 long, not 2..4', 3, '2v2v2')
end

function test_a_map_form_record_with_no_version_field_is_still_read_as_v2()
    round_of(3)
    local record = v2_map_record(2)
    record.version = nil
    storage.bb_league_match = record
    lunatest.assert_equal(3, MatchFormat.team_count())
    lunatest.assert_equal('[LEAGUE] record v2: 3 teams as map, format 2v2v2, params 2v2', MatchFormat.recognised())
end

function test_a_map_form_record_logs_once_per_round_like_the_array_form()
    round_of(2)
    storage.bb_game_start_tick = 100
    storage.bb_league_match = v2_map_record(2)
    MatchFormat.log_recognised_once()
    MatchFormat.log_recognised_once()
    lunatest.assert_equal(1, #logged)
    lunatest.assert_equal('[LEAGUE] record v2: 2 teams as map, format 2v2, params 2v2', logged[1])
end

-- ---------------------------------------------------------------------------
-- recognised(): the one line that says what the scenario made of the record
-- ---------------------------------------------------------------------------

function test_recognised_with_no_record_and_with_a_v1_record()
    lunatest.assert_equal('[LEAGUE] no record -> default parameters', MatchFormat.recognised())

    storage.bb_league_match = { id = 'L17', format = '2v2', north = { 'a', 'b' }, south = { 'c', 'd' } }
    lunatest.assert_equal('[LEAGUE] record v1: format 2v2, params 2v2', MatchFormat.recognised())
end

function test_recognised_quotes_an_unreadable_format()
    storage.bb_league_match = { id = 'L17', format = '2v3' }
    lunatest.assert_equal("[LEAGUE] record unreadable (format '2v3') -> default parameters", MatchFormat.recognised())

    storage.bb_league_match = { id = 'L17' }
    lunatest.assert_equal("[LEAGUE] record unreadable (format 'nil') -> default parameters", MatchFormat.recognised())
end

function test_recognised_appends_a_mismatch_between_the_record_and_the_round()
    -- The daemon wrote a record for three teams and the map was reset to four.
    -- Today that is silent for the whole match; this clause is the cure.
    round_of(3)
    local record = v2_record(2)
    round_of(4)
    storage.bb_league_match = record
    lunatest.assert_equal(
        '[LEAGUE] record v2: 3 teams as array, format 2v2v2, params 2v2; mismatch: record says 3 teams, the round has 4',
        MatchFormat.recognised()
    )

    -- A v1 record in a three-team round says two teams, and that is a mismatch
    -- too -- the only one a v1 record can raise on its own.
    round_of(3)
    storage.bb_league_match = { id = 'L17', format = '2v2' }
    lunatest.assert_equal(
        '[LEAGUE] record v1: format 2v2, params 2v2; mismatch: record says 2 teams, the round has 3',
        MatchFormat.recognised()
    )
end

function test_an_unreadable_record_is_never_a_mismatch()
    -- Nothing is known about what it meant, so there is nothing for it to
    -- disagree with the round about.
    round_of(4)
    storage.bb_league_match = { id = 'L17', format = 'nonsense' }
    lunatest.assert_equal(
        "[LEAGUE] record unreadable (format 'nonsense') -> default parameters",
        MatchFormat.recognised()
    )
end

function test_a_later_version_is_read_with_the_v2_rules_and_named_as_itself()
    -- Forward tolerance, the rule this module has lived by since it was
    -- written: a record from a daemon newer than this code must not stop the
    -- game. It is read the best way known and the line says what it claimed.
    round_of(3)
    local record = v2_record(2)
    record.version = 3
    storage.bb_league_match = record
    lunatest.assert_equal(3, MatchFormat.team_count())
    lunatest.assert_equal('[LEAGUE] record v3: 3 teams as array, format 2v2v2, params 2v2', MatchFormat.recognised())
end

function test_a_version_that_is_not_a_version_is_ignored_rather_than_believed()
    -- The record comes from another process and this reader may not raise on
    -- anything in it. Lua 5.2's '%d' refuses an infinity and anything out of
    -- integer range, so a corrupt `version` must never reach the line: it is
    -- ignored, and what decides the reading is whether there is a `teams`
    -- array.
    round_of(3)
    for _, version in ipairs({ 1 / 0, 0 / 0, -1, 0, 1e300, 'two', true }) do
        local record = v2_record(2)
        record.version = version
        storage.bb_league_match = record
        local label = tostring(version)
        lunatest.assert_equal(3, MatchFormat.team_count(), label)
        lunatest.assert_equal(
            '[LEAGUE] record v2: 3 teams as array, format 2v2v2, params 2v2',
            MatchFormat.recognised(),
            label
        )
    end

    -- Truncated rather than refused: a fractional version is the whole number
    -- below it, so the test and the text cannot disagree about which it is.
    local fractional = v2_record(2)
    fractional.version = 2.7
    storage.bb_league_match = fractional
    lunatest.assert_equal('[LEAGUE] record v2: 3 teams as array, format 2v2v2, params 2v2', MatchFormat.recognised())

    -- With no `teams` array, a corrupt version leaves today's record.
    storage.bb_league_match = { id = 'L17', format = '2v2v2', version = 1 / 0 }
    lunatest.assert_equal('[LEAGUE] record v1: format 2v2v2, params 2v2', MatchFormat.recognised())
end

function test_a_teams_array_without_a_version_field_is_still_read_as_v2()
    round_of(3)
    local record = v2_record(2)
    record.version = nil
    storage.bb_league_match = record
    lunatest.assert_equal(3, MatchFormat.team_count())
    lunatest.assert_equal('[LEAGUE] record v2: 3 teams as array, format 2v2v2, params 2v2', MatchFormat.recognised())
end

-- ---------------------------------------------------------------------------
-- match_info(): the handshake the daemon reads back over RCON
-- ---------------------------------------------------------------------------

function test_match_info_is_what_the_daemon_reads_back()
    round_of(3)
    storage.bb_league_match = v2_record(2)

    local info = MatchFormat.match_info()

    lunatest.assert_equal(2, info.version)
    lunatest.assert_equal(3, info.team_count)
    lunatest.assert_equal(2, info.team_size)
    lunatest.assert_equal('2v2', info.format_key)
    lunatest.assert_equal('[LEAGUE] record v2: 3 teams as array, format 2v2v2, params 2v2', info.recognised)
end

function test_match_info_answers_without_a_record()
    local info = MatchFormat.match_info()

    lunatest.assert_nil(info.version)
    lunatest.assert_nil(info.team_count)
    lunatest.assert_nil(info.team_size)
    lunatest.assert_equal('default', info.format_key)
    lunatest.assert_equal('[LEAGUE] no record -> default parameters', info.recognised)
end

-- ---------------------------------------------------------------------------
-- Logging what was recognised: once per round, and never in today's game
-- ---------------------------------------------------------------------------

function test_a_v1_record_in_a_two_team_round_logs_nothing_and_writes_no_key()
    -- THE RULE THAT PROTECTS THE BASELINE. The two-team regression check compares the
    -- scenario's log lines and the storage layout of a two-team round byte for
    -- byte against today's, so the recognition line may not appear there and
    -- the idempotence key may not be created.
    round_of(2)
    storage.bb_game_start_tick = 5400
    storage.bb_league_match = { id = 'L17', format = '2v2', north = { 'a', 'b' }, south = { 'c', 'd' } }

    MatchFormat.log_recognised_once()

    lunatest.assert_equal(0, #logged)
    lunatest.assert_nil(storage.bb_league_recognised)
end

function test_a_two_team_round_with_no_record_at_all_logs_nothing()
    -- Every non-league server: no record, two teams, silence.
    round_of(2)
    storage.bb_game_start_tick = 5400

    MatchFormat.log_recognised_once()

    lunatest.assert_equal(0, #logged)
    lunatest.assert_nil(storage.bb_league_recognised)
end

function test_an_unreadable_record_in_a_two_team_round_still_logs_nothing()
    -- It is silent today and the two-team log may not gain a line. An operator
    -- who wants to know asks `remote.call('bb_teams', 'match_info')`.
    round_of(2)
    storage.bb_game_start_tick = 5400
    storage.bb_league_match = { id = 'L17', format = '2v3' }

    MatchFormat.log_recognised_once()

    lunatest.assert_equal(0, #logged)
    lunatest.assert_nil(storage.bb_league_recognised)
end

function test_a_v2_record_logs_once_per_round()
    round_of(2)
    storage.bb_game_start_tick = 5400
    storage.bb_league_match = v2_record(2)

    MatchFormat.log_recognised_once()
    MatchFormat.log_recognised_once()
    MatchFormat.log_recognised_once()

    lunatest.assert_equal(1, #logged)
    lunatest.assert_equal('[LEAGUE] record v2: 2 teams as array, format 2v2, params 2v2', logged[1])
end

function test_a_round_of_more_than_two_teams_logs_even_with_no_record()
    round_of(3)
    storage.bb_game_start_tick = 5400

    MatchFormat.log_recognised_once()
    MatchFormat.log_recognised_once()

    lunatest.assert_equal(1, #logged)
    lunatest.assert_equal('[LEAGUE] no record -> default parameters', logged[1])
end

function test_a_v1_record_naming_three_teams_in_a_two_team_round_logs_the_mismatch()
    -- No `version` and no `teams` makes it a v1 record, but its format names
    -- three teams and the round has two. That disagreement is the third reason
    -- to log, and the only one that can fire on a record of today's shape.
    round_of(2)
    storage.bb_game_start_tick = 5400
    storage.bb_league_match = { id = 'L17', format = '2v2v2' }

    MatchFormat.log_recognised_once()

    lunatest.assert_equal(1, #logged)
    lunatest.assert_equal(
        '[LEAGUE] record v1: format 2v2v2, params 2v2; mismatch: record says 3 teams, the round has 2',
        logged[1]
    )
end

function test_the_next_round_logs_again()
    -- The stamp carries the round's start tick, which the reset nils and the
    -- next GO sets to a later tick, so nothing has to clear the key -- which is
    -- why `Init.tables()` does not need to know it exists.
    round_of(3)
    storage.bb_game_start_tick = 5400
    MatchFormat.log_recognised_once()
    MatchFormat.log_recognised_once()
    lunatest.assert_equal(1, #logged)

    round_of(3)
    storage.bb_game_start_tick = 99000
    MatchFormat.log_recognised_once()
    lunatest.assert_equal(2, #logged)
end

function test_a_record_rewritten_under_a_new_id_is_recognised_again()
    round_of(2)
    storage.bb_game_start_tick = 5400
    storage.bb_league_match = v2_record(2)
    MatchFormat.log_recognised_once()
    lunatest.assert_equal(1, #logged)

    local rewritten = v2_record(3)
    rewritten.id = 'L18'
    storage.bb_league_match = rewritten

    MatchFormat.log_recognised_once()

    lunatest.assert_equal(2, #logged)
    lunatest.assert_equal('[LEAGUE] record v2: 2 teams as array, format 3v3, params 3v3', logged[2])
end

function test_log_recognised_once_is_nil_safe_without_storage()
    -- It is only ever called from inside the game, but the module is written to
    -- survive being loaded without one and this entry point keeps that promise.
    local saved = storage
    storage = nil
    MatchFormat.log_recognised_once()
    storage = saved
    lunatest.assert_equal(0, #logged)
end

lunatest.run()
