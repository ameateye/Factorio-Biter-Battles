---@diagnostic disable
--
-- `maps/biter_battles_v2/league_state.lua` -- the enriched channel the League
-- daemon reads a round of 2, 3 or 4 teams through.
--
-- `remote.call('bb_teams', 'match_info')` used to answer five fields
-- (`version`, `team_count`, `team_size`, `format_key`,
-- `recognised`), which describe the league's RECORD. This module keeps those
-- five untouched and adds what the record does not say: which teams are
-- playing, where on the map, whether they are still alive, where they
-- finished, their evolution and threat, and who is on them.
--
-- The one hard invariant this file guards is the last of those. With two teams
-- `members` must be exactly the TT1 poll's force_north / force_south list, and
-- `connected` its conn_north / conn_south list -- so two tests here build one
-- fixture, run `tests/fixtures/league-tt1-poll.lua` against it as
-- `tests/test-league-poll.lua` does, and compare the poll's own output with the
-- remote's field for field. If the two ever disagree the daemon would read two
-- different rosters from the same round.
--
-- The other half of the file is `spectator_privacy`, the one call in this
-- module that WRITES: it hides the teams of the round from the spectator force
-- for the length of a match. The fake forces record their `set_friend` calls,
-- so what it writes -- which forces, in which order, with which value -- is
-- asserted rather than described. At two teams that must be the daemon's own
-- `set_friend('north', …)` / `set_friend('south', …)` pair and nothing else.
--
-- Nothing else here touches the running game: `match_state()` writes nothing,
-- the scenario calls neither function, and a two-team round is unaffected by
-- the module's existence.
--
-- `game` is a fake with `tick`, `forces` and `connected_players`; `storage` is
-- a plain table. The force names in the fixtures are deliberate -- the forces
-- ARE the teams and a fixture that did not name them could not build a round.

local lunatest = require('lunatest')

storage = { ['_TEST'] = true }

local LeagueState = require('maps.biter_battles_v2.league_state')
local MatchFormat = require('maps.biter_battles_v2.match_format')
local Teams = require('maps.biter_battles_v2.teams')

--- The daemon's own poll, for the two-team roster comparison.
local POLL = 'tests/fixtures/league-tt1-poll.lua'

--- The order the fixture builds the forces in. The four teams in ring order,
--- then the spectators -- the same five forces the poll asks about.
local FORCE_ORDER = { 'north', 'east', 'south', 'west', 'spectator' }

--- Ask for `count` teams and start the round.
---@param count integer
local function round_of(count)
    lunatest.assert_true(Teams.set_next_count(count), 'set_next_count(' .. tostring(count) .. ')')
    Teams.begin_round()
end

--- Every `set_friend` the last `mock_game()` has seen, in order, as
--- 'spectator.north=false' -- the force it was called on, the force it names
--- and the value. `spectator_privacy` is a write, and what it writes is the
--- whole of its contract.
---@type string[]
local friend_writes = {}

--- A fake `game` holding one force per entry of `rosters` (force name -> array
--- of player names), with `online` the subset that is connected.
---
--- Each force carries `players` and `connected_players`, and
--- `game.connected_players` is every online player in force order -- the three
--- collections the poll and `league_state` read. Each also records its
--- `set_friend` calls into `friend_writes`.
---@param rosters table<string, string[]>
---@param online string[]|nil
---@param tick integer|nil
local function mock_game(rosters, online, tick)
    local is_online = {}
    for _, name in ipairs(online or {}) do
        is_online[name] = true
    end
    friend_writes = {}
    game = { tick = tick or 4242, forces = {}, connected_players = {} }
    for _, force_name in ipairs(FORCE_ORDER) do
        local roster = rosters[force_name]
        if roster then
            local players, connected = {}, {}
            for i, name in ipairs(roster) do
                local player = { name = name, force = { name = force_name } }
                players[i] = player
                if is_online[name] then
                    connected[#connected + 1] = player
                    game.connected_players[#game.connected_players + 1] = player
                end
            end
            local written_by = force_name
            game.forces[force_name] = {
                players = players,
                connected_players = connected,
                set_friend = function(other, value)
                    friend_writes[#friend_writes + 1] = written_by .. '.' .. tostring(other) .. '=' .. tostring(value)
                end,
            }
        end
    end
end

--- The `set_friend` calls of the test so far, as one comparable string.
---@return string
local function writes()
    return table.concat(friend_writes, ',')
end

--- The round's teams by force name, so a test can ask for one without counting
--- array indices.
---@return table<string, LeagueTeamState>
local function teams_by_force(state)
    local by_force = {}
    for _, team in ipairs(state.teams) do
        by_force[team.force] = team
    end
    return by_force
end

--- 'north,east,south' -- the `teams` array in the order it came, as one
--- comparable string.
---@param state table
---@return string
local function force_order(state)
    local names = {}
    for i, team in ipairs(state.teams) do
        names[i] = team.force
    end
    return table.concat(names, ',')
end

--- The same, for the quadrants.
---@param state table
---@return string
local function quadrant_order(state)
    local names = {}
    for i, team in ipairs(state.teams) do
        names[i] = team.quadrant
    end
    return table.concat(names, ',')
end

--- Run the daemon's TT1 poll against the current `storage` and `game`, and
--- return its sixteen fields. Identical in method to
--- `tests/test-league-poll.lua`, which is what pins the poll itself.
---@return string[]
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
    local fields = {}
    for field in (printed .. '\t'):gmatch('([^\t]*)\t') do
        fields[#fields + 1] = field
    end
    lunatest.assert_equal(16, #fields, printed)
    return fields
end

--- Evolution and threat for every roster team, so that a value read from the
--- wrong key is a wrong number rather than a nil.
local function evolution_and_threat()
    storage.bb_evolution = {}
    storage.bb_threat = {}
    for i, team in ipairs(Teams.roster()) do
        storage.bb_evolution[Teams.biter_force(team)] = i / 10
        storage.bb_threat[Teams.biter_force(team)] = i * 1000
    end
end

function setup()
    storage = { ['_TEST'] = true }
    game = nil
    rcon = nil
end

-- ---------------------------------------------------------------------------
-- The five original fields are still there, unchanged
-- ---------------------------------------------------------------------------

function test_match_state_keeps_every_field_of_match_info()
    round_of(3)
    mock_game({ north = { 'a' }, east = { 'b' }, south = { 'c' } })
    storage.bb_league_match = {
        id = 'L17',
        version = 2,
        format = '2v2v2',
        teams = {
            { name = 'north', players = { 'a', 'b' } },
            { name = 'east', players = { 'c', 'd' } },
            { name = 'south', players = { 'e', 'f' } },
        },
    }
    local info = MatchFormat.match_info()
    local state = LeagueState.match_state()
    lunatest.assert_equal(info.version, state.version)
    lunatest.assert_equal(info.team_count, state.team_count)
    lunatest.assert_equal(info.team_size, state.team_size)
    lunatest.assert_equal(info.format_key, state.format_key)
    -- The recognition line is `match_format`'s, whatever it says today: this
    -- asserts it is the SAME line, not a second reading of the record.
    lunatest.assert_equal(info.recognised, state.recognised)
end

function test_the_record_fields_are_nil_without_a_record()
    round_of(2)
    mock_game({ north = {}, south = {} })
    local state = LeagueState.match_state()
    lunatest.assert_nil(state.version)
    lunatest.assert_nil(state.team_count)
    lunatest.assert_nil(state.team_size)
    lunatest.assert_equal('default', state.format_key)
    lunatest.assert_equal('[LEAGUE] no record -> default parameters', state.recognised)
end

-- ---------------------------------------------------------------------------
-- The round's own fields
-- ---------------------------------------------------------------------------

function test_the_round_fields_of_a_two_team_round_before_GO()
    round_of(2)
    mock_game({ north = { 'n1' }, south = { 's1' } }, { 'n1' }, 987654)
    storage.difficulty_vote_value = 0.75
    local state = LeagueState.match_state()
    lunatest.assert_equal('horizontal2', state.layout)
    lunatest.assert_nil(state.won_by)
    lunatest.assert_nil(state.start_tick)
    lunatest.assert_equal(987654, state.tick)
    lunatest.assert_nil(state.victory_time)
    lunatest.assert_equal(0.75, state.difficulty)
    lunatest.assert_false(state.tournament_mode)
    lunatest.assert_false(state.tt_mode)
    lunatest.assert_equal(0, #state.placement)
    lunatest.assert_equal(2, #state.teams)
end

function test_the_round_fields_are_read_from_storage()
    round_of(2)
    mock_game({ north = { 'n1' }, south = { 's1' } })
    storage.bb_game_start_tick = 120000
    storage.bb_game_won_by_team = 'north'
    storage.victory_time = 'Time - 42 minutes'
    storage.difficulty_vote_value = 1.5
    local state = LeagueState.match_state()
    lunatest.assert_equal('north', state.won_by)
    lunatest.assert_equal(120000, state.start_tick)
    lunatest.assert_equal('Time - 42 minutes', state.victory_time)
    lunatest.assert_equal(1.5, state.difficulty)
end

function test_tournament_mode_and_tt_mode_are_always_booleans()
    -- Both are nil rather than false on a fresh save; the daemon should not
    -- have to know that, and the TT1 poll applies the same `== true` test.
    round_of(2)
    mock_game({ north = {}, south = {} })
    local state = LeagueState.match_state()
    lunatest.assert_false(state.tournament_mode)
    lunatest.assert_false(state.tt_mode)

    storage.tournament_mode = 'yes'
    storage.tt_mode = 1
    state = LeagueState.match_state()
    lunatest.assert_false(state.tournament_mode)
    lunatest.assert_false(state.tt_mode)

    storage.tournament_mode = true
    storage.tt_mode = true
    state = LeagueState.match_state()
    lunatest.assert_true(state.tournament_mode)
    lunatest.assert_true(state.tt_mode)
end

function test_the_layout_is_the_rounds_layout()
    mock_game({ north = {}, east = {}, south = {}, west = {} })
    round_of(2)
    lunatest.assert_equal('horizontal2', LeagueState.match_state().layout)
    round_of(3)
    lunatest.assert_equal('cross4', LeagueState.match_state().layout)
    round_of(4)
    lunatest.assert_equal('cross4', LeagueState.match_state().layout)
end

-- ---------------------------------------------------------------------------
-- The teams array: ring order and the square of the map
-- ---------------------------------------------------------------------------

function test_the_teams_array_is_the_ring_order_of_the_round()
    mock_game({ north = {}, east = {}, south = {}, west = {} })
    round_of(2)
    lunatest.assert_equal('north,south', force_order(LeagueState.match_state()))
    round_of(3)
    lunatest.assert_equal('north,east,south', force_order(LeagueState.match_state()))
    round_of(4)
    lunatest.assert_equal('north,east,south,west', force_order(LeagueState.match_state()))
end

function test_the_quadrant_of_a_two_team_round_is_the_side_itself()
    round_of(2)
    mock_game({ north = {}, south = {} })
    lunatest.assert_equal('north,south', quadrant_order(LeagueState.match_state()))
end

function test_the_quadrant_of_a_four_team_round_is_the_square()
    round_of(4)
    mock_game({ north = {}, east = {}, south = {}, west = {} })
    lunatest.assert_equal('top_left,top_right,bottom_right,bottom_left', quadrant_order(LeagueState.match_state()))
end

function test_a_three_team_round_leaves_the_bottom_left_square_unclaimed()
    -- With three teams the bottom-left quadrant is water
    -- and belongs to nobody, so it is in no entry of the array.
    round_of(3)
    mock_game({ north = {}, east = {}, south = {} })
    lunatest.assert_equal('top_left,top_right,bottom_right', quadrant_order(LeagueState.match_state()))
end

function test_the_display_name_is_the_registrys_name_for_the_layout()
    round_of(2)
    mock_game({ north = {}, south = {} })
    local by_force = teams_by_force(LeagueState.match_state())
    lunatest.assert_equal(Teams.display_name('north'), by_force.north.name)
    lunatest.assert_equal('Team North', by_force.north.name)
    lunatest.assert_equal('Team South', by_force.south.name)

    -- On the four-square map a compass name would point at the wrong corner,
    -- so the registry answers with the square's name instead.
    round_of(4)
    by_force = teams_by_force(LeagueState.match_state())
    lunatest.assert_equal('Top Left', by_force.north.name)
    lunatest.assert_equal('Bottom Left', by_force.west.name)
end

function test_a_custom_team_name_is_what_the_daemon_is_told()
    round_of(2)
    mock_game({ north = {}, south = {} })
    storage.tm_custom_name = { north = 'Les Bleus' }
    local by_force = teams_by_force(LeagueState.match_state())
    lunatest.assert_equal('Les Bleus', by_force.north.name)
    lunatest.assert_equal('Team South', by_force.south.name)
end

function test_the_dormant_forces_of_an_earlier_round_are_not_in_the_array()
    -- A save that once played four teams keeps its `east` and `west` forces,
    -- players and all. They are not in this round and must not be reported.
    round_of(2)
    mock_game({ north = { 'n1' }, east = { 'ghost' }, south = { 's1' }, west = { 'spook' } })
    local state = LeagueState.match_state()
    lunatest.assert_equal(2, #state.teams)
    lunatest.assert_equal('north,south', force_order(state))
end

-- ---------------------------------------------------------------------------
-- alive / eliminated_tick / place
-- ---------------------------------------------------------------------------

function test_every_team_of_a_fresh_round_is_alive_with_no_tick_and_no_place()
    round_of(4)
    mock_game({ north = {}, east = {}, south = {}, west = {} })
    local state = LeagueState.match_state()
    lunatest.assert_equal(0, #state.placement)
    for _, team in ipairs(state.teams) do
        lunatest.assert_true(team.alive, team.force)
        lunatest.assert_nil(team.eliminated_tick, team.force)
        lunatest.assert_nil(team.place, team.force)
    end
end

function test_an_elimination_is_reported_with_its_tick_and_its_place()
    round_of(4)
    mock_game({ north = {}, east = {}, south = {}, west = {} })

    game.tick = 1000
    Teams.eliminate('east')
    game.tick = 2000
    Teams.eliminate('west')

    local state = LeagueState.match_state()
    local by_force = teams_by_force(state)
    lunatest.assert_false(by_force.east.alive)
    lunatest.assert_equal(1000, by_force.east.eliminated_tick)
    lunatest.assert_false(by_force.west.alive)
    lunatest.assert_equal(2000, by_force.west.eliminated_tick)
    lunatest.assert_true(by_force.north.alive)
    lunatest.assert_nil(by_force.north.eliminated_tick)

    -- Two teams are still alive. `placement` (the registry's array) holds only
    -- the teams already out, last eliminated first; `place` is the final place
    -- each of them has secured: the first of four out is 4th, the second 3rd,
    -- whatever the survivors do -- the elimination line's own computation --
    -- and the teams still playing have no place until the round is decided.
    lunatest.assert_equal('west,east', table.concat(state.placement, ','))
    lunatest.assert_equal(3, by_force.west.place)
    lunatest.assert_equal(4, by_force.east.place)
    lunatest.assert_nil(by_force.north.place)
    lunatest.assert_nil(by_force.south.place)
    lunatest.assert_nil(state.won_by)
end

function test_the_places_of_a_finished_four_team_round_are_best_first()
    round_of(4)
    mock_game({ north = {}, east = {}, south = {}, west = {} })
    game.tick = 1000
    Teams.eliminate('east')
    game.tick = 2000
    Teams.eliminate('west')
    game.tick = 3000
    Teams.eliminate('south')

    local state = LeagueState.match_state()
    -- The winner, then the eliminated in reverse order of elimination.
    lunatest.assert_equal('north,south,west,east', table.concat(state.placement, ','))
    local by_force = teams_by_force(state)
    lunatest.assert_equal(1, by_force.north.place)
    lunatest.assert_equal(2, by_force.south.place)
    lunatest.assert_equal(3, by_force.west.place)
    lunatest.assert_equal(4, by_force.east.place)
    lunatest.assert_equal(3000, by_force.south.eliminated_tick)
end

function test_a_team_that_never_played_has_neither_a_tick_nor_a_place()
    -- `eliminate(team, true)` is the team the map gave no silo at all: it is out
    -- of the alive set but it did not come last, so it is in no ranking and
    -- nothing is timestamped for it.
    round_of(4)
    mock_game({ north = {}, east = {}, south = {}, west = {} })
    Teams.eliminate('west', true)
    game.tick = 1000
    Teams.eliminate('east')
    game.tick = 2000
    Teams.eliminate('south')

    local state = LeagueState.match_state()
    lunatest.assert_equal('north,south,east', table.concat(state.placement, ','))
    local by_force = teams_by_force(state)
    lunatest.assert_false(by_force.west.alive)
    lunatest.assert_nil(by_force.west.eliminated_tick)
    lunatest.assert_nil(by_force.west.place)
    lunatest.assert_equal(4, #state.teams)
end

function test_the_placement_array_is_a_copy_the_caller_may_keep()
    round_of(2)
    mock_game({ north = {}, south = {} })
    game.tick = 500
    Teams.eliminate('south')
    local state = LeagueState.match_state()
    lunatest.assert_equal('north,south', table.concat(state.placement, ','))
    state.placement[1] = 'tampered'
    lunatest.assert_equal('north', LeagueState.match_state().placement[1])
end

-- ---------------------------------------------------------------------------
-- evolution and threat
-- ---------------------------------------------------------------------------

function test_evo_and_threat_come_from_the_biter_force_of_the_team()
    round_of(4)
    mock_game({ north = {}, east = {}, south = {}, west = {} })
    evolution_and_threat()
    local by_force = teams_by_force(LeagueState.match_state())
    lunatest.assert_equal(0.1, by_force.north.evo)
    lunatest.assert_equal(0.2, by_force.east.evo)
    lunatest.assert_equal(0.3, by_force.south.evo)
    lunatest.assert_equal(0.4, by_force.west.evo)
    lunatest.assert_equal(1000, by_force.north.threat)
    lunatest.assert_equal(4000, by_force.west.threat)
end

function test_the_two_team_evo_and_threat_are_the_numbers_the_poll_reports()
    round_of(2)
    mock_game({ north = { 'n1' }, south = { 's1' } })
    storage.bb_evolution = { north_biters = 0.42, south_biters = 0.5 }
    storage.bb_threat = { north_biters = 1500, south_biters = -250 }
    local fields = run_poll()
    local by_force = teams_by_force(LeagueState.match_state())
    lunatest.assert_equal(fields[5], tostring(by_force.north.evo))
    lunatest.assert_equal(fields[6], tostring(by_force.south.evo))
    lunatest.assert_equal(fields[7], tostring(by_force.north.threat))
    lunatest.assert_equal(fields[8], tostring(by_force.south.threat))
end

function test_a_team_with_no_evolution_entry_reports_nothing_rather_than_a_number()
    round_of(3)
    mock_game({ north = {}, east = {}, south = {} })
    storage.bb_evolution = { north_biters = 0.1 }
    local by_force = teams_by_force(LeagueState.match_state())
    lunatest.assert_equal(0.1, by_force.north.evo)
    lunatest.assert_nil(by_force.east.evo)
    lunatest.assert_nil(by_force.north.threat)
end

-- ---------------------------------------------------------------------------
-- connected / members
-- ---------------------------------------------------------------------------

function test_members_is_the_force_roster_and_connected_the_online_subset()
    round_of(3)
    mock_game({
        north = { 'n1', 'n2' },
        east = { 'e1' },
        south = { 's1', 's2', 's3' },
        spectator = { 'watcher' },
    }, { 'n1', 'e1', 's2', 'watcher' })
    local by_force = teams_by_force(LeagueState.match_state())
    lunatest.assert_equal('n1,n2', table.concat(by_force.north.members, ','))
    lunatest.assert_equal('n1', table.concat(by_force.north.connected, ','))
    lunatest.assert_equal('s1,s2,s3', table.concat(by_force.south.members, ','))
    lunatest.assert_equal('s2', table.concat(by_force.south.connected, ','))
    lunatest.assert_equal('e1', table.concat(by_force.east.members, ','))
end

function test_the_roster_never_empties_when_a_team_is_eliminated()
    -- `members` is the force's list, and the players of a dead team are moved
    -- to the spectators with their choice cleared: from then on it is empty.
    -- `roster` keeps them, through the mark the elimination leaves (it holds the
    -- team), and also counts whoever is merely watching (choice kept). Sorted.
    round_of(4)
    mock_game({
        north = { 'n2', 'n1' },
        east = {},
        south = { 's1' },
        spectator = { 'e1', 'e2', 'n3', 'stranger' },
    }, { 'n1', 's1', 'e1' })
    Teams.mark_player_eliminated('e2', 'east')
    Teams.mark_player_eliminated('e1', 'east')
    storage.chosen_team = { n3 = 'north', n1 = 'north' }

    local by_force = teams_by_force(LeagueState.match_state())
    lunatest.assert_equal(0, #by_force.east.members)
    lunatest.assert_equal('e1,e2', table.concat(by_force.east.roster, ','))
    lunatest.assert_equal('n1,n2,n3', table.concat(by_force.north.roster, ','), 'force players and watchers, once each')
    lunatest.assert_equal('s1', table.concat(by_force.south.roster, ','))
    lunatest.assert_equal(0, #by_force.west.roster)
    storage.chosen_team = nil
end

function test_names_false_drops_the_three_name_lists_and_nothing_else()
    -- The reply is one RCON packet, cut at 4096 bytes by the client: a poll asks
    -- without the names. The keys are ABSENT, not empty, so a reader can tell
    -- "not asked" from "nobody there"; everything else is the same answer.
    round_of(4)
    mock_game({ north = { 'n1', 'n2' }, east = { 'e1' }, south = { 's1' }, west = {} }, { 'n1', 'e1' })
    local full = LeagueState.match_state()
    local lean = LeagueState.match_state({ names = false })

    local by_force = {}
    for _, team in ipairs(lean.teams) do
        by_force[team.force] = team
    end
    lunatest.assert_nil(by_force.north.members)
    lunatest.assert_nil(by_force.north.connected)
    lunatest.assert_nil(by_force.north.roster)
    lunatest.assert_equal(#full.teams, #lean.teams)
    lunatest.assert_equal(full.teams[1].force, lean.teams[1].force)
    lunatest.assert_equal(full.teams[1].name, lean.teams[1].name)
    lunatest.assert_equal(full.teams[1].alive, lean.teams[1].alive)
    lunatest.assert_equal(full.layout, lean.layout)
    lunatest.assert_equal(full.team_count, lean.team_count)

    -- Anything that is not `{ names = false }` is the full answer.
    for _, options in ipairs({ {}, { names = true }, 'names=false' }) do
        local other = LeagueState.match_state(options)
        lunatest.assert_equal('n1,n2', table.concat(other.teams[1].members, ','), type(options))
    end
end

function test_a_force_that_does_not_exist_yet_reports_empty_lists()
    -- The round is decided by `Teams.begin_round()`; the forces are created by
    -- `Teams.ensure_forces()` at the reset. A caller between the two -- or a
    -- host where a force was never made -- gets empty lists, not an error.
    round_of(3)
    mock_game({ north = { 'n1' }, south = { 's1' } })
    local by_force = teams_by_force(LeagueState.match_state())
    lunatest.assert_equal(0, #by_force.east.members)
    lunatest.assert_equal(0, #by_force.east.connected)
    lunatest.assert_equal('n1', table.concat(by_force.north.members, ','))
end

function test_members_of_a_two_team_round_is_exactly_the_polls_force_lists()
    -- THE invariant of this file. `storage.chosen_team` is deliberately not in
    -- `members`: the poll builds force_north / force_south from
    -- `game.forces[<force>].players` and so does this module, so the two lists
    -- are equal by construction and the daemon cannot read two different
    -- rosters from the same round.
    round_of(2)
    mock_game({
        north = { 'n1', 'n2', 'n3' },
        south = { 's1', 's2' },
        spectator = { 'watcher' },
    }, { 'n1', 's1', 's2', 'watcher' })
    -- A choice recorded for a player who is not on the force any more: it must
    -- change nothing at all.
    storage.chosen_team = { ghost = 'north', n1 = 'north' }

    local fields = run_poll()
    local by_force = teams_by_force(LeagueState.match_state())
    lunatest.assert_equal(fields[15], table.concat(by_force.north.members, ','))
    lunatest.assert_equal(fields[16], table.concat(by_force.south.members, ','))
    lunatest.assert_equal('n1,n2,n3', table.concat(by_force.north.members, ','))
    lunatest.assert_equal('s1,s2', table.concat(by_force.south.members, ','))
end

function test_connected_of_a_two_team_round_is_exactly_the_polls_connected_lists()
    round_of(2)
    mock_game({
        north = { 'n1', 'n2', 'n3' },
        south = { 's1', 's2' },
        spectator = { 'watcher' },
    }, { 'n1', 's1', 's2', 'watcher' })
    local fields = run_poll()
    local by_force = teams_by_force(LeagueState.match_state())
    lunatest.assert_equal(fields[12], table.concat(by_force.north.connected, ','))
    lunatest.assert_equal(fields[13], table.concat(by_force.south.connected, ','))
    -- The poll files everyone else as a spectator; the remote simply does not
    -- report the spectators as a team.
    lunatest.assert_equal('watcher', fields[14])
end

function test_a_four_team_round_reports_the_rosters_the_poll_cannot()
    round_of(4)
    mock_game({
        north = { 'n1' },
        east = { 'e1', 'e2' },
        south = { 's1' },
        west = { 'w1' },
    }, { 'e1', 'w1' })
    local fields = run_poll()
    -- The poll sees the east and west players as spectators ...
    lunatest.assert_equal('e1,w1', fields[14])
    -- ... the remote sees them on their own teams.
    local by_force = teams_by_force(LeagueState.match_state())
    lunatest.assert_equal('e1,e2', table.concat(by_force.east.members, ','))
    lunatest.assert_equal('e1', table.concat(by_force.east.connected, ','))
    lunatest.assert_equal('w1', table.concat(by_force.west.members, ','))
end

-- ---------------------------------------------------------------------------
-- The table crosses the remote boundary
-- ---------------------------------------------------------------------------

function test_every_call_builds_a_fresh_table()
    round_of(2)
    mock_game({ north = { 'n1' }, south = { 's1' } })
    local first = LeagueState.match_state()
    first.teams[1].members[1] = 'tampered'
    first.layout = 'tampered'
    local second = LeagueState.match_state()
    lunatest.assert_equal('n1', second.teams[1].members[1])
    lunatest.assert_equal('horizontal2', second.layout)
end

-- ---------------------------------------------------------------------------
-- spectator_privacy: the same two writes the two-team daemon sends
-- ---------------------------------------------------------------------------

function test_spectator_privacy_hides_the_two_teams_exactly_as_the_daemon_does()
    -- The daemon's own pair, today:
    --   local f = game.forces['spectator']
    --   f.set_friend('north', false) f.set_friend('south', false)
    -- Same two writes, same order, nothing else.
    round_of(2)
    mock_game({ north = {}, south = {}, spectator = {} })
    local touched = LeagueState.spectator_privacy(true)
    lunatest.assert_equal('north,south', table.concat(touched, ','))
    lunatest.assert_equal('spectator.north=false,spectator.south=false', writes())
end

function test_spectator_privacy_off_shows_the_teams_again()
    -- The other half of the daemon's match, and what `Init.forces()` writes at
    -- every map reset.
    round_of(2)
    mock_game({ north = {}, south = {}, spectator = {} })
    local touched = LeagueState.spectator_privacy(false)
    lunatest.assert_equal('north,south', table.concat(touched, ','))
    lunatest.assert_equal('spectator.north=true,spectator.south=true', writes())
end

function test_spectator_privacy_covers_every_team_of_a_four_team_round()
    round_of(4)
    mock_game({ north = {}, east = {}, south = {}, west = {}, spectator = {} })
    local touched = LeagueState.spectator_privacy(true)
    lunatest.assert_equal('north,east,south,west', table.concat(touched, ','))
    lunatest.assert_equal(
        'spectator.north=false,spectator.east=false,spectator.south=false,spectator.west=false',
        writes()
    )
end

function test_spectator_privacy_covers_the_three_teams_of_a_three_team_round()
    round_of(3)
    mock_game({ north = {}, east = {}, south = {}, spectator = {} })
    LeagueState.spectator_privacy(true)
    lunatest.assert_equal('spectator.north=false,spectator.east=false,spectator.south=false', writes())
end

function test_spectator_privacy_leaves_the_dormant_forces_of_an_earlier_round_alone()
    -- `Teams.all()`, never `game.forces`: a two-team round in a save that once
    -- played four must not write relations for teams nobody is playing.
    round_of(2)
    mock_game({ north = {}, east = {}, south = {}, west = {}, spectator = {} })
    local touched = LeagueState.spectator_privacy(true)
    lunatest.assert_equal('north,south', table.concat(touched, ','))
    lunatest.assert_equal('spectator.north=false,spectator.south=false', writes())
end

function test_an_eliminated_team_is_still_hidden()
    -- Its silo is gone; its chart is not, and the round is still being played
    -- on its half of the map.
    round_of(4)
    mock_game({ north = {}, east = {}, south = {}, west = {}, spectator = {} })
    game.tick = 1000
    Teams.eliminate('east')
    LeagueState.spectator_privacy(true)
    lunatest.assert_equal(
        'spectator.north=false,spectator.east=false,spectator.south=false,spectator.west=false',
        writes()
    )
end

function test_spectator_privacy_refuses_anything_that_is_not_a_boolean()
    -- `spectator_privacy()` with no argument would otherwise read as "show
    -- them", and opening a match up by accident is the one mistake this call
    -- must not make easy.
    round_of(2)
    mock_game({ north = {}, south = {}, spectator = {} })
    for _, bad in ipairs({ 'true', 1, 0 }) do
        local touched, reason = LeagueState.spectator_privacy(bad)
        lunatest.assert_nil(touched, tostring(bad))
        lunatest.assert_equal('spectator_privacy takes true (hide the teams) or false (show them)', reason)
    end
    local touched, reason = LeagueState.spectator_privacy()
    lunatest.assert_nil(touched)
    lunatest.assert_equal('spectator_privacy takes true (hide the teams) or false (show them)', reason)
    lunatest.assert_equal('', writes())
end

function test_spectator_privacy_refuses_when_there_is_no_spectator_force()
    round_of(2)
    mock_game({ north = {}, south = {} })
    local touched, reason = LeagueState.spectator_privacy(true)
    lunatest.assert_nil(touched)
    lunatest.assert_equal("there is no 'spectator' force", reason)
    lunatest.assert_equal('', writes())
end

function test_spectator_privacy_hands_out_a_copy_of_the_team_list()
    round_of(3)
    mock_game({ north = {}, east = {}, south = {}, spectator = {} })
    local touched = LeagueState.spectator_privacy(true)
    lunatest.assert_false(rawequal(touched, Teams.all()))
    touched[1] = 'tampered'
    lunatest.assert_equal('north', Teams.all()[1])
end

function test_the_live_team_arrays_are_not_handed_out()
    -- `Teams.all()` is the array that lives in `storage`; a remote caller must
    -- not be given it.
    round_of(3)
    mock_game({ north = {}, east = {}, south = {} })
    local state = LeagueState.match_state()
    lunatest.assert_false(rawequal(state.teams, Teams.all()))
    lunatest.assert_false(rawequal(state.placement, Teams.all()))
end

lunatest.run()
