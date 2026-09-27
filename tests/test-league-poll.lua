---@diagnostic disable
--
-- The League daemon's TT1 poll, run AS IS.
--
-- `tests/fixtures/league-tt1-poll.lua` is the production daemon's own Lua,
-- copied character for character out of the PHP that sends it over RCON every
-- few seconds. It is a FIXTURE, not scenario code: it is in `.styluaignore`, it
-- is never reformatted, and nothing in the repository requires it. This file
-- loads that very file with `loadfile` and runs it against a fake `storage`, a
-- fake `game` and a fake `rcon`, so that a change to the scenario that would
-- break the daemon fails here rather than in production.
--
-- What it pins:
--
--   * the line has exactly SIXTEEN tab-separated fields. It is not
--     seventeen; the Lua appends `out[#out+1]` sixteen times and that is the
--     number the PHP parser splits on, so 16 is the contract. The count is
--     taken from the file itself as well as from the line, so adding a field to
--     the poll without saying so here fails.
--   * `f[1] == 'TT1'` and the exact value of every one of the sixteen fields
--     for a two-team fixture, before GO and after game over.
--   * the same poll against a FOUR-team fixture: the field count and the
--     north/south values are unchanged, and the players on `east` and `west`
--     land in conn_spec, because the poll asks `p.force.name == 'north'`,
--     `== 'south'`, else spectator. That is what the current daemon SEES on a
--     round of more than two teams, and it is why it must not be used there --
--     the enriched
--     `remote.call('bb_teams', 'match_info')` is the channel for N teams.
--   * a source scan: every `storage` key the poll reads is still assigned
--     somewhere under `maps/biter_battles_v2/`, so a rename inside the scenario
--     is caught by CI instead of by the daemon.
--
-- The force names in the fixtures below are deliberate: the poll is keyed by
-- force name and a fixture that did not name the forces could not exercise it.

local lunatest = require('lunatest')

--- The daemon's poll, exactly as it sends it. Relative to the repository root,
--- like every other path a suite here uses.
local POLL = 'tests/fixtures/league-tt1-poll.lua'

--- The sixteen fields, in the order the poll appends them. The PHP parser reads
--- them positionally, so this list IS the contract.
local FIELDS = {
    'tag',
    'won_by',
    'start_tick',
    'tick',
    'evo_north',
    'evo_south',
    'threat_north',
    'threat_south',
    'victory_time',
    'difficulty',
    'tournament_mode',
    'conn_north',
    'conn_south',
    'conn_spec',
    'force_north',
    'force_south',
}

--- Sixteen. Not seventeen: count the `out[#out+1]` lines of the poll.
local FIELD_COUNT = 16

--- Every `storage` key the poll reads directly.
local POLLED_KEYS = {
    'bb_game_won_by_team',
    'bb_game_start_tick',
    'bb_evolution',
    'bb_threat',
    'victory_time',
    'difficulty_vote_value',
    'tournament_mode',
}

--- A fake player: the two fields the poll touches, `name` and `force.name`.
---@param name string
---@param force_name string
local function player(name, force_name)
    return { name = name, force = { name = force_name } }
end

--- A fake force holding the players the poll would list. `players` is every
--- player of the force, online or not -- that is what `LuaForce.players` is, and
--- the force_north / force_south fields of the poll are built from it.
---@param players table[]
local function force(players)
    return { players = players }
end

--- Split a poll line on tabs, keeping the EMPTY fields: `victory_time` and the
--- three connected lists are empty strings most of the time, and a splitter
--- that dropped them would hide exactly the bug this suite exists for.
---@param line string
---@return string[]
local function split_tabs(line)
    local fields = {}
    for field in (line .. '\t'):gmatch('([^\t]*)\t') do
        fields[#fields + 1] = field
    end
    return fields
end

--- Run the daemon's poll against whatever `storage` and `game` currently are,
--- and return the fields of the line it printed.
---
--- The chunk reads `storage`, `game` and `rcon` as globals, which is what it
--- does inside Factorio's RCON console too, so loading it into the test's own
--- global environment runs it unaltered.
---@return string[] fields
---@return string line
local function run_poll()
    local chunk, err = loadfile(POLL)
    lunatest.assert_true(chunk ~= nil, 'loadfile(' .. POLL .. '): ' .. tostring(err))
    local printed
    rcon = {
        print = function(line)
            printed = line
        end,
    }
    chunk()
    lunatest.assert_true(type(printed) == 'string', 'the poll printed nothing')
    return split_tabs(printed), printed
end

--- `{ won_by = '...', evo_north = '...' }` -- the line by field name, so that a
--- failing assertion says which field is wrong rather than which index.
---@return table<string, string>
local function poll_by_name()
    local fields = run_poll()
    lunatest.assert_equal(FIELD_COUNT, #fields, 'field count')
    local named = {}
    for i = 1, FIELD_COUNT do
        named[FIELDS[i]] = fields[i]
    end
    return named
end

--- The two-team fixture: four players on the two teams, one of them offline,
--- one spectator. `connected_players` is a subset of the force lists, as it is
--- in game.
---
--- `n2` is on the north force but not connected, so force_north and conn_north
--- cannot be confused with one another.
local function two_team_fixture()
    local n1 = player('n1', 'north')
    local n2 = player('n2', 'north')
    local s1 = player('s1', 'south')
    local s2 = player('s2', 'south')
    local spec = player('watcher', 'spectator')
    game = {
        tick = 987654,
        connected_players = { n1, s1, s2, spec },
        forces = {
            ['north'] = force({ n1, n2 }),
            ['south'] = force({ s1, s2 }),
            ['spectator'] = force({ spec }),
        },
    }
end

--- The same round played with four teams: the north and south halves are
--- untouched, and two more teams exist with players of their own.
local function four_team_fixture()
    local n1 = player('n1', 'north')
    local n2 = player('n2', 'north')
    local s1 = player('s1', 'south')
    local s2 = player('s2', 'south')
    local e1 = player('e1', 'east')
    local w1 = player('w1', 'west')
    local spec = player('watcher', 'spectator')
    game = {
        tick = 987654,
        connected_players = { n1, s1, s2, e1, w1, spec },
        forces = {
            ['north'] = force({ n1, n2 }),
            ['east'] = force({ e1 }),
            ['south'] = force({ s1, s2 }),
            ['west'] = force({ w1 }),
            ['spectator'] = force({ spec }),
        },
    }
end

--- A round in progress: evolution and threat on both sides, no winner yet, GO
--- has not happened.
local function round_in_progress()
    storage = {
        bb_evolution = { north_biters = 0.42, south_biters = 0.5 },
        bb_threat = { north_biters = 1500, south_biters = -250 },
        difficulty_vote_value = 0.75,
        tournament_mode = false,
    }
end

function setup()
    storage = {}
    game = nil
    rcon = nil
end

-- ---------------------------------------------------------------------------
-- The shape of the line: sixteen fields, the first of them TT1
-- ---------------------------------------------------------------------------

function test_the_poll_prints_exactly_sixteen_tab_separated_fields()
    two_team_fixture()
    round_in_progress()
    local fields, line = run_poll()
    lunatest.assert_equal(FIELD_COUNT, #fields, line)
    lunatest.assert_equal(FIELD_COUNT, #FIELDS)
end

function test_the_poll_file_appends_exactly_sixteen_fields()
    -- The count read off the SOURCE, not off one line: a seventeenth
    -- `out[#out+1]` added to the daemon's Lua has to be declared here.
    local handle = io.open(POLL, 'r')
    lunatest.assert_true(handle ~= nil, 'cannot read ' .. POLL)
    local text = handle:read('*a')
    handle:close()
    local appends = 0
    for _ in text:gmatch('out%[#out%+1%]=') do
        appends = appends + 1
    end
    lunatest.assert_equal(FIELD_COUNT, appends)
end

function test_the_first_field_is_the_TT1_tag()
    two_team_fixture()
    round_in_progress()
    local fields = run_poll()
    lunatest.assert_equal('TT1', fields[1])
end

function test_an_empty_field_is_kept_rather_than_collapsed()
    -- victory_time is '' for the whole round, so the line carries two tabs in a
    -- row. The PHP parser splits positionally and would read every field after
    -- it one place early if the scenario ever stopped producing it.
    two_team_fixture()
    round_in_progress()
    local _, line = run_poll()
    lunatest.assert_true(line:find('\t\t', 1, true) ~= nil, line)
end

-- ---------------------------------------------------------------------------
-- Every field of a two-team round
-- ---------------------------------------------------------------------------

function test_every_field_of_a_two_team_round_before_GO()
    two_team_fixture()
    round_in_progress()
    local f = poll_by_name()
    lunatest.assert_equal('TT1', f.tag)
    lunatest.assert_equal('', f.won_by)
    lunatest.assert_equal('-1', f.start_tick)
    lunatest.assert_equal('987654', f.tick)
    lunatest.assert_equal('0.42', f.evo_north)
    lunatest.assert_equal('0.5', f.evo_south)
    lunatest.assert_equal('1500', f.threat_north)
    lunatest.assert_equal('-250', f.threat_south)
    lunatest.assert_equal('', f.victory_time)
    lunatest.assert_equal('0.75', f.difficulty)
    lunatest.assert_equal('false', f.tournament_mode)
    lunatest.assert_equal('n1', f.conn_north)
    lunatest.assert_equal('s1,s2', f.conn_south)
    lunatest.assert_equal('watcher', f.conn_spec)
    lunatest.assert_equal('n1,n2', f.force_north)
    lunatest.assert_equal('s1,s2', f.force_south)
end

function test_every_field_of_a_two_team_round_after_game_over()
    two_team_fixture()
    round_in_progress()
    storage.bb_game_start_tick = 120000
    storage.bb_game_won_by_team = 'north'
    storage.victory_time = 'Time - 42 minutes'
    storage.tournament_mode = true
    local f = poll_by_name()
    lunatest.assert_equal('north', f.won_by)
    lunatest.assert_equal('120000', f.start_tick)
    lunatest.assert_equal('Time - 42 minutes', f.victory_time)
    lunatest.assert_equal('true', f.tournament_mode)
end

function test_start_tick_is_minus_one_until_GO_and_the_tick_after_it()
    two_team_fixture()
    round_in_progress()
    lunatest.assert_equal('-1', poll_by_name().start_tick)
    storage.bb_game_start_tick = 0
    -- Not `or -1`: tick 0 is a real start tick and `0` is truthy in Lua.
    lunatest.assert_equal('0', poll_by_name().start_tick)
    storage.bb_game_start_tick = 3600
    lunatest.assert_equal('3600', poll_by_name().start_tick)
end

function test_a_missing_evolution_table_reads_minus_one_and_a_missing_threat_zero()
    two_team_fixture()
    storage = { difficulty_vote_value = 0.5 }
    local f = poll_by_name()
    lunatest.assert_equal('-1', f.evo_north)
    lunatest.assert_equal('-1', f.evo_south)
    lunatest.assert_equal('0', f.threat_north)
    lunatest.assert_equal('0', f.threat_south)
    lunatest.assert_equal('0.5', f.difficulty)
end

function test_a_missing_difficulty_reads_zero()
    two_team_fixture()
    storage = {}
    lunatest.assert_equal('0', poll_by_name().difficulty)
end

function test_evolution_and_threat_are_read_from_the_biter_force_keys()
    -- `storage.bb_evolution` and `storage.bb_threat` are keyed by BITER force
    -- ('north_biters'), not by team. Keying them by team would read nil and the
    -- daemon would see -1 and 0 for a whole match.
    two_team_fixture()
    storage = { bb_evolution = { north = 0.9, south = 0.9 }, bb_threat = { north = 5, south = 5 } }
    local f = poll_by_name()
    lunatest.assert_equal('-1', f.evo_north)
    lunatest.assert_equal('-1', f.evo_south)
    lunatest.assert_equal('0', f.threat_north)
    lunatest.assert_equal('0', f.threat_south)
end

function test_tournament_mode_is_true_only_for_the_boolean()
    two_team_fixture()
    round_in_progress()
    lunatest.assert_equal('false', poll_by_name().tournament_mode)
    storage.tournament_mode = nil
    lunatest.assert_equal('false', poll_by_name().tournament_mode)
    storage.tournament_mode = 'yes'
    lunatest.assert_equal('false', poll_by_name().tournament_mode)
    storage.tournament_mode = true
    lunatest.assert_equal('true', poll_by_name().tournament_mode)
end

function test_a_missing_force_leaves_its_list_empty()
    -- `game.forces['north']` is guarded in the poll, so a host where the force
    -- does not exist yet answers an empty list rather than erroring out. The
    -- connected lists are unguarded and simply find nobody.
    two_team_fixture()
    round_in_progress()
    game.forces['north'] = nil
    local f = poll_by_name()
    lunatest.assert_equal('', f.force_north)
    lunatest.assert_equal('s1,s2', f.force_south)
    lunatest.assert_equal('n1', f.conn_north)
end

function test_the_connected_lists_follow_the_force_of_the_player()
    -- A connected player is filed by `p.force.name`, so a player moved to the
    -- spectators is in conn_spec at once even while the force lists still hold
    -- whatever the fixture says.
    two_team_fixture()
    round_in_progress()
    game.connected_players[1].force.name = 'spectator'
    local f = poll_by_name()
    lunatest.assert_equal('', f.conn_north)
    lunatest.assert_equal('n1,watcher', f.conn_spec)
end

function test_nobody_connected_is_three_empty_lists()
    two_team_fixture()
    round_in_progress()
    game.connected_players = {}
    local f = poll_by_name()
    lunatest.assert_equal('', f.conn_north)
    lunatest.assert_equal('', f.conn_south)
    lunatest.assert_equal('', f.conn_spec)
    lunatest.assert_equal('n1,n2', f.force_north)
end

-- ---------------------------------------------------------------------------
-- What the CURRENT daemon sees on a round of more than two teams
-- ---------------------------------------------------------------------------
--
-- Pinned so it is a documented fact rather than a surprise. None of it is a
-- bug in the poll: the poll asks about two forces because it was written for a
-- two-team game.

function test_a_four_team_round_still_prints_sixteen_fields()
    four_team_fixture()
    round_in_progress()
    local fields = run_poll()
    lunatest.assert_equal(FIELD_COUNT, #fields)
    lunatest.assert_equal('TT1', fields[1])
end

function test_a_four_team_round_files_east_and_west_players_as_spectators()
    four_team_fixture()
    round_in_progress()
    local f = poll_by_name()
    lunatest.assert_equal('n1', f.conn_north)
    lunatest.assert_equal('s1,s2', f.conn_south)
    -- e1 and w1 are neither north nor south, so the poll's `else` branch takes
    -- them: to this daemon a four-team round looks like a two-team round with
    -- three spectators.
    lunatest.assert_equal('e1,w1,watcher', f.conn_spec)
end

function test_a_four_team_round_leaves_the_east_and_west_forces_out_of_the_lists()
    four_team_fixture()
    round_in_progress()
    local f = poll_by_name()
    lunatest.assert_equal('n1,n2', f.force_north)
    lunatest.assert_equal('s1,s2', f.force_south)
end

function test_a_four_team_round_reports_only_the_north_and_south_evolution_and_threat()
    four_team_fixture()
    storage = {
        bb_evolution = { north_biters = 0.42, east_biters = 0.6, south_biters = 0.5, west_biters = 0.7 },
        bb_threat = { north_biters = 1500, east_biters = 9000, south_biters = -250, west_biters = 12 },
        difficulty_vote_value = 0.75,
    }
    local f = poll_by_name()
    lunatest.assert_equal('0.42', f.evo_north)
    lunatest.assert_equal('0.5', f.evo_south)
    lunatest.assert_equal('1500', f.threat_north)
    lunatest.assert_equal('-250', f.threat_south)
    -- The east and west numbers are simply not in the line; they are in
    -- `remote.call('bb_teams', 'match_info')`.
end

function test_a_four_team_round_reports_a_winner_that_may_be_neither_side()
    -- `won_by` is the force name the scenario wrote, whatever it is. The PHP
    -- parser maps anything that is not 'north' or 'south' to null, so a round
    -- won by east reads to the daemon as a round with no winner.
    four_team_fixture()
    round_in_progress()
    storage.bb_game_won_by_team = 'east'
    lunatest.assert_equal('east', poll_by_name().won_by)
end

-- ---------------------------------------------------------------------------
-- The source scan: the keys the poll reads are still written by the scenario
-- ---------------------------------------------------------------------------

--- Every `.lua` source under `maps/biter_battles_v2/`, read once.
---
--- Listing a directory needs a shell in plain Lua 5.2; an empty listing would
--- make every scan below pass for the wrong reason, which is what
--- `test_the_source_scan_really_read_the_scenario` guards.
---@return table<string, string> text_by_path
local function scenario_sources()
    local pipe = io.popen("find maps/biter_battles_v2 -name '*.lua' 2>/dev/null")
    if not pipe then
        return {}
    end
    local sources = {}
    for path in pipe:lines() do
        local handle = io.open(path, 'r')
        if handle then
            sources[path] = handle:read('*a')
            handle:close()
        end
    end
    pipe:close()
    return sources
end

--- True when `text` ASSIGNS `storage.<key>` somewhere: `storage.key` followed by
--- `=` that is not the `==` of a comparison. The assignment may be the last
--- thing on its line (`storage.victory_time =` then a continuation), so the
--- character after the `=` is tested rather than required to be on the line.
---@param text string
---@param key string
---@return boolean
local function assigns(text, key)
    local pattern = 'storage%.' .. key .. '%s*='
    local from = 1
    while true do
        local first, last = text:find(pattern, from)
        if not first then
            return false
        end
        if text:sub(last + 1, last + 1) ~= '=' then
            return true
        end
        from = last + 1
    end
end

function test_the_source_scan_really_read_the_scenario()
    local sources = scenario_sources()
    local count = 0
    for _ in pairs(sources) do
        count = count + 1
    end
    lunatest.assert_true(count > 20, 'the scan found ' .. count .. ' sources under maps/biter_battles_v2')
    lunatest.assert_true(sources['maps/biter_battles_v2/init.lua'] ~= nil, 'init.lua was not read')
end

function test_every_storage_key_the_poll_reads_is_still_assigned_by_the_scenario()
    -- A rename inside the scenario is invisible to the daemon: the poll would
    -- simply start reading nil and report -1, 0 and '' for the rest of the
    -- match. This is the test that catches it at CI time instead.
    local sources = scenario_sources()
    for _, key in ipairs(POLLED_KEYS) do
        local found = nil
        for path, text in pairs(sources) do
            if assigns(text, key) then
                found = path
                break
            end
        end
        lunatest.assert_true(
            found ~= nil,
            'storage.' .. key .. ' is read by the TT1 poll but assigned nowhere under maps/biter_battles_v2/'
        )
    end
end

function test_the_assignment_scan_tells_an_assignment_from_a_comparison()
    lunatest.assert_true(assigns('storage.tournament_mode = false', 'tournament_mode'))
    lunatest.assert_true(assigns('storage.victory_time =\n    table.concat({})', 'victory_time'))
    lunatest.assert_false(assigns('if storage.tournament_mode == true then', 'tournament_mode'))
    lunatest.assert_false(assigns('local x = storage.bb_threat[force]', 'bb_threat'))
    -- `bb_threat_income` is a different key and must not answer for `bb_threat`.
    lunatest.assert_false(assigns('storage.bb_threat_income = {}', 'bb_threat'))
end

lunatest.run()
