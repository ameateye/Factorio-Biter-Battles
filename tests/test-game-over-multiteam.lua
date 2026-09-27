---@diagnostic disable
--
-- What a round of more than two teams says when it ends
-- (`maps/biter_battles_v2/game_over_report.lua`).
--
-- The sentences and the record live in a module of their own precisely so that
-- they can be read here, without Factorio: every string a player, a Discord
-- channel or the league daemon gets out of a three- or four-team game over is
-- pinned below, character for character, together with the arithmetic that
-- decides which place a team took.
--
-- What this suite is here to catch:
--
--   * a **place counted from the wrong end**. The first team out of four is
--     4th, not 1st, and the count it is derived from is the teams that were
--     still playing -- which is not `Teams.count()`, because a team the map
--     gave no silo is out of the round without ever being ranked;
--   * a **wording drift** between the four places the same fact is stated in:
--     the public announcement, the private line to the player who is now
--     spectating, the heading of the team's block in the end-game panel and
--     its Discord embed;
--   * a **`[MATCH-RESULT]` field that changed shape**. The daemon parses it,
--     `version` says which shape it is, and `teams` is in ring order so the
--     line is diffable between rounds.
--
-- The two-team game is not in here because none of this is reachable there:
-- the first silo to fall leaves one team alive, so `Teams.winner()` answers,
-- `eliminate_team` is skipped and every call into the report module sits behind
-- `Teams.count() > 2`. The last test pins that branch on the registry itself.
--
-- `teams.lua` loads outside Factorio (`config.lua` and `utils/force.lua` are
-- pure) and the only thing it touches on `game` is the tick, so the four-team
-- round below is the real registry with a faked clock. The report module
-- touches nothing at all.

local lunatest = require('lunatest')

storage = { ['_TEST'] = true }

local Report = require('maps.biter_battles_v2.game_over_report')
local Teams = require('maps.biter_battles_v2.teams')

--- Nothing but `game.tick`, which is all `Teams.eliminate` reads.
local function mock_game(tick)
    game = { tick = tick or 0 }
end

--- Ask for `count` teams and start the round.
local function round_of(count)
    storage = { ['_TEST'] = true }
    mock_game(0)
    lunatest.assert_true(Teams.set_next_count(count), 'set_next_count(' .. tostring(count) .. ')')
    Teams.begin_round()
end

--- A team's last silo falls at `tick`: the registry records it, and the place
--- it took is what `game_over.lua`'s `eliminate_team` computes right afterwards
--- -- the eliminations so far, the teams still alive, and nothing else.
---@return integer place
local function silo_falls(team, tick)
    game.tick = tick
    Teams.eliminate(team)
    return Report.place_of(Teams.state().eliminated, #Teams.alive(), team)
end

--- The `[MATCH-RESULT]` record of the finished round, built the way
--- `game_over.lua`'s `match_result` builds it: ring order, the registry's
--- display names, the elimination ticks off the round state.
local function match_result_of(round)
    local ticks = {}
    for _, elimination in ipairs(Teams.state().eliminated) do
        ticks[elimination.team] = elimination.tick
    end
    local entries = {}
    for i, team in ipairs(Teams.all()) do
        entries[i] = { name = team, display_name = Teams.display_name(team), eliminated_tick = ticks[team] }
    end
    return Report.match_result({
        teams = entries,
        placement = Teams.placement(),
        winner = Teams.winner(),
        game_start_tick = round.game_start_tick,
        game_end_tick = round.game_end_tick,
        format = round.format,
        format_label = round.format_label,
    })
end

--- 'north=3@200' for every entry of a `[MATCH-RESULT]` teams array, in the
--- order the array has them: one comparable string for name, place and tick.
local function teams_summary(teams)
    local parts = {}
    for i, entry in ipairs(teams) do
        parts[i] = entry.name .. '=' .. tostring(entry.placement) .. '@' .. tostring(entry.eliminated_tick)
    end
    return table.concat(parts, ',')
end

-- == The ordinal =============================================================

function test_the_ordinal_of_every_place_a_round_can_hand_out()
    lunatest.assert_equal('1st', Report.ordinal(1))
    lunatest.assert_equal('2nd', Report.ordinal(2))
    lunatest.assert_equal('3rd', Report.ordinal(3))
    lunatest.assert_equal('4th', Report.ordinal(4))
end

function test_the_ordinal_keeps_the_teens_rule_beyond_the_roster()
    -- Four teams is the roster, so these are not reachable today. They are here
    -- because the rule is cheap and a table of four would be silently wrong the
    -- day somebody plays a bigger game.
    lunatest.assert_equal('11th', Report.ordinal(11))
    lunatest.assert_equal('12th', Report.ordinal(12))
    lunatest.assert_equal('13th', Report.ordinal(13))
    lunatest.assert_equal('21st', Report.ordinal(21))
    lunatest.assert_equal('22nd', Report.ordinal(22))
    lunatest.assert_equal('23rd', Report.ordinal(23))
    lunatest.assert_equal('101st', Report.ordinal(101))
    lunatest.assert_equal('111th', Report.ordinal(111))
end

-- == The four sentences ======================================================

function test_the_elimination_line_names_the_place()
    lunatest.assert_equal('Team Top Left has been eliminated - 4th place', Report.elimination_message('Top Left', 4))
    lunatest.assert_equal(
        'Team Bottom Right has been eliminated - 2nd place',
        Report.elimination_message('Bottom Right', 2)
    )
end

function test_the_elimination_line_without_a_place_is_the_sentence_of_before()
    -- The silo-death path always has a place. This is the handler's floor: it
    -- may not raise, so a place that somehow is not known costs the ranking and
    -- nothing else.
    lunatest.assert_equal('Team Top Left has been eliminated!', Report.elimination_message('Top Left', nil))
end

function test_the_private_line_says_out_where_and_what_now()
    lunatest.assert_equal(
        'Your team has been eliminated - 4th place. You are spectating now and can watch the rest of the game.',
        Report.eliminated_player_message(4)
    )
end

function test_the_private_line_without_a_place_still_reads()
    lunatest.assert_equal(
        'Your team has been eliminated. You are spectating now and can watch the rest of the game.',
        Report.eliminated_player_message(nil)
    )
end

function test_the_winner_line_lists_the_whole_placement()
    lunatest.assert_equal(
        'Team Bottom Right wins! 2nd Top Right, 3rd Top Left, 4th Bottom Left',
        Report.winner_message({ 'Bottom Right', 'Top Right', 'Top Left', 'Bottom Left' })
    )
end

function test_the_winner_line_of_a_three_team_round()
    lunatest.assert_equal(
        'Team Top Right wins! 2nd Top Left, 3rd Bottom Right',
        Report.winner_message({ 'Top Right', 'Top Left', 'Bottom Right' })
    )
end

function test_the_winner_line_when_nobody_else_was_ranked()
    -- Both other teams were out before the round began (no silo on the map), so
    -- the placement is the winner alone: a sentence that ends rather than a
    -- sentence with an empty list after it.
    lunatest.assert_equal('Team Top Left wins!', Report.winner_message({ 'Top Left' }))
end

function test_the_block_heading_of_a_placed_team()
    -- As the end-game panel shows it, and -- upper-cased by `game_over.lua` --
    -- as the team's Discord embed opens.
    lunatest.assert_equal('Top Left - 3rd place', Report.placed_title('Top Left', 3))
    lunatest.assert_equal('TOP LEFT - 3RD PLACE', string.upper(Report.placed_title('Top Left', 3)))
end

-- == Which place a team took =================================================

function test_place_of_counts_back_from_the_teams_that_were_playing()
    local eliminated = { { team = 'west', tick = 100 }, { team = 'north', tick = 200 } }
    -- Two teams are still in it, so four were ranked: the first one out is 4th.
    lunatest.assert_equal(4, Report.place_of(eliminated, 2, 'west'))
    lunatest.assert_equal(3, Report.place_of(eliminated, 2, 'north'))
end

function test_place_of_gives_the_team_that_just_died_the_alive_count_plus_one()
    local eliminated = { { team = 'west', tick = 100 } }
    lunatest.assert_equal(4, Report.place_of(eliminated, 3, 'west'), 'three left, so it came fourth')
    eliminated[2] = { team = 'north', tick = 200 }
    lunatest.assert_equal(3, Report.place_of(eliminated, 2, 'north'), 'two left, so it came third')
end

function test_place_of_is_nil_for_a_team_that_is_not_out()
    local eliminated = { { team = 'west', tick = 100 } }
    lunatest.assert_nil(Report.place_of(eliminated, 3, 'south'), 'still playing')
    lunatest.assert_nil(Report.place_of({}, 4, 'south'), 'nobody is out yet')
end

-- == A four-team round, end to end ===========================================

function test_a_four_team_round_announces_every_place_as_it_falls()
    round_of(4)
    lunatest.assert_equal('north,east,south,west', table.concat(Teams.all(), ','), 'ring order')

    lunatest.assert_equal(
        'Team Bottom Left has been eliminated - 4th place',
        Report.elimination_message(Teams.display_name('west'), silo_falls('west', 100))
    )
    lunatest.assert_equal(
        'Team Top Left has been eliminated - 3rd place',
        Report.elimination_message(Teams.display_name('north'), silo_falls('north', 200))
    )

    -- The third silo ends the round: one team is left, so `game_over.lua` takes
    -- the winner branch instead of announcing a third elimination.
    silo_falls('east', 300)
    lunatest.assert_equal('south', Teams.winner())

    local titles = {}
    for i, team in ipairs(Teams.placement()) do
        titles[i] = Teams.display_name(team)
    end
    lunatest.assert_equal(
        'Team Bottom Right wins! 2nd Top Right, 3rd Top Left, 4th Bottom Left',
        Report.winner_message(titles)
    )
end

function test_the_places_of_a_round_a_team_never_played()
    -- `init.lua`'s `eliminate_teams_without_a_silo`: west got no silo, so three
    -- teams played and the first one out is 3rd, not 4th.
    round_of(4)
    Teams.eliminate('west', true)
    lunatest.assert_equal(3, #Teams.alive())

    lunatest.assert_equal(3, silo_falls('north', 100))
    lunatest.assert_equal(2, silo_falls('east', 200))
    lunatest.assert_equal('south', Teams.winner())
    lunatest.assert_equal('south,east,north', table.concat(Teams.placement(), ','), 'west is not ranked')
end

-- == The [MATCH-RESULT] record ===============================================

function test_the_match_result_of_a_four_team_round()
    round_of(4)
    silo_falls('west', 100)
    silo_falls('north', 200)
    silo_falls('east', 300)

    local result =
        match_result_of({ game_start_tick = 50, game_end_tick = 300, format = '2v2', format_label = '2v2v2v2' })

    lunatest.assert_equal(2, result.version)
    lunatest.assert_equal('south', result.winner)
    lunatest.assert_equal(50, result.game_start_tick)
    lunatest.assert_equal(300, result.game_end_tick)
    lunatest.assert_equal('2v2', result.format)
    -- `format` stays the two-part parameter key; the match as players read it
    -- is `format_label` (added 2026-09-27, the daemons read neither today).
    lunatest.assert_equal('2v2v2v2', result.format_label)
    lunatest.assert_equal(4, #result.teams)
    -- Ring order, each with the place it took and the tick its silo fell on.
    lunatest.assert_equal(
        'north=3@200,east=2@300,south=1@nil,west=4@100',
        teams_summary(result.teams),
        'ring order, places and elimination ticks'
    )
    lunatest.assert_equal('Top Left', result.teams[1].display_name)
    lunatest.assert_equal('Bottom Left', result.teams[4].display_name)
    lunatest.assert_nil(result.teams[3].eliminated_tick, 'the winner lost no silo')
end

function test_the_match_result_leaves_out_what_it_has_no_answer_for()
    -- A team that never played is in the array -- it was dealt in -- with
    -- neither a place nor a tick, and without a league record there is no
    -- format. `helpers.table_to_json` has no null, so an absent answer is an
    -- absent key.
    round_of(3)
    Teams.eliminate('east', true)
    silo_falls('north', 100)

    local result = match_result_of({ game_start_tick = 50, game_end_tick = 100, format = nil })

    lunatest.assert_equal(3, #result.teams)
    lunatest.assert_equal('north=2@100,east=nil@nil,south=1@nil', teams_summary(result.teams))
    lunatest.assert_nil(result.format)
    lunatest.assert_nil(result.format_label)
    lunatest.assert_equal('south', result.winner)
end

function test_the_match_result_ranks_by_the_placement_it_is_given()
    -- The join the record is, without the registry: a team's place is its
    -- position in the placement array it is handed. That array is
    -- `Teams.placement()` of a FINISHED round -- the winner, then the
    -- eliminations in reverse -- and a finished round is the only moment this
    -- line is written; mid-round `placement()` is the dead teams alone and is
    -- not a ranking. The teams array keeps the caller's order, which is the
    -- ring, not the ranking.
    local result = Report.match_result({
        teams = {
            { name = 'north', display_name = 'Top Left', eliminated_tick = 200 },
            { name = 'east', display_name = 'Top Right', eliminated_tick = 300 },
            { name = 'south', display_name = 'Bottom Right' },
            { name = 'west', display_name = 'Bottom Left', eliminated_tick = 100 },
        },
        placement = { 'south', 'east', 'north', 'west' },
        winner = 'south',
        game_start_tick = 50,
        game_end_tick = 300,
    })

    lunatest.assert_equal(2, result.version)
    lunatest.assert_equal('north=3@200,east=2@300,south=1@nil,west=4@100', teams_summary(result.teams))
    lunatest.assert_nil(result.format, 'no league record, no format')
end

-- == The branch none of this is on ===========================================

function test_a_two_team_round_never_reaches_any_of_it()
    -- `game_over.lua`: the loser is eliminated, `Teams.winner()` answers with
    -- the other team, and the `if not winner` branch -- the only caller of
    -- `eliminate_team`, and with it of every sentence above -- is skipped. The
    -- announcements, the private line and the `[MATCH-RESULT]` log sit behind
    -- `Teams.count() > 2` on top of that.
    round_of(2)
    Teams.eliminate('north')
    lunatest.assert_equal(1, #Teams.alive())
    lunatest.assert_equal('south', Teams.winner())
    lunatest.assert_equal(2, Teams.count())
end

function test_the_match_result_carries_the_players_it_is_given()
    -- The players of a dead team are spectators by the time the round ends, so
    -- `game_over.lua` hands the names over per team; the record keeps the list
    -- as it is, and a team with none given has no key rather than a guess.
    local result = Report.match_result({
        teams = {
            { name = 'north', display_name = 'Top Left', players = { 'ann', 'bob' } },
            { name = 'east', display_name = 'Top Right', eliminated_tick = 300, players = {} },
            { name = 'south', display_name = 'Bottom Right', eliminated_tick = 200 },
        },
        placement = { 'north', 'east', 'south' },
        winner = 'north',
        game_start_tick = 50,
        game_end_tick = 300,
    })

    lunatest.assert_equal('ann', result.teams[1].players[1])
    lunatest.assert_equal('bob', result.teams[1].players[2])
    lunatest.assert_equal(0, #result.teams[2].players)
    lunatest.assert_nil(result.teams[3].players)
end

-- == Discord player lists, panel order, team statistics ======================

function test_the_players_line_of_the_discord_embed()
    -- One team's block of the N-team embed: the upper-cased title, the embed's
    -- two-character '\n' sequence, every name followed by three spaces -- the
    -- shape the two-team loop builds from connected players.
    lunatest.assert_equal('TOP LEFT PLAYERS: \\nann   bob   ', Report.players_line('TOP LEFT', { 'ann', 'bob' }))
    lunatest.assert_equal('BOTTOM RIGHT PLAYERS: \\n', Report.players_line('BOTTOM RIGHT', {}))
end

function test_the_players_line_lists_an_eliminated_team_from_its_roster()
    -- The defect: when the round ends, the players of every eliminated team are
    -- spectators, so a list read off each player's force was empty for all but
    -- the winner. The roster keeps them: the elimination mark carries the team.
    round_of(3)
    Teams.mark_player_eliminated('carl', 'east')
    Teams.mark_player_eliminated('dora', 'east')
    silo_falls('east', 100)
    local roster = {}
    for name, team in pairs(Teams.state().eliminated_players) do
        if team == 'east' then
            roster[#roster + 1] = name
        end
    end
    table.sort(roster)
    lunatest.assert_equal(
        'TOP RIGHT PLAYERS: \\ncarl   dora   ',
        Report.players_line(string.upper(Teams.display_name('east')), roster)
    )
end

function test_the_panel_order_follows_the_placement()
    -- Ring order north, east, south; east out first, south second: the blocks
    -- read 1st, 2nd, 3rd from the top, not in ring order.
    lunatest.assert_equal(
        'north,south,east',
        table.concat(Report.placement_order({ 'north', 'east', 'south' }, { 'north', 'south', 'east' }), ',')
    )
    -- A team that never played has no place: it comes last, in ring order.
    lunatest.assert_equal(
        'south,north,east,west',
        table.concat(Report.placement_order({ 'north', 'east', 'south', 'west' }, { 'south', 'north' }), ',')
    )
    -- No placement: ring order. A name that is not a team of the round is not
    -- listed, and no team is listed twice.
    lunatest.assert_equal('north,east,south', table.concat(Report.placement_order({ 'north', 'east', 'south' }), ','))
    lunatest.assert_equal(
        'east,north,south',
        table.concat(Report.placement_order({ 'north', 'east', 'south' }, { 'east', 'west', 'east' }), ',')
    )
end

function test_the_panel_order_of_a_played_four_team_round()
    round_of(4)
    silo_falls('west', 100)
    silo_falls('north', 200)
    silo_falls('east', 300)
    lunatest.assert_equal(
        'south,east,north,west',
        table.concat(Report.placement_order(Teams.all(), Teams.placement()), ',')
    )
end

function test_the_standings_of_the_team_statistics_window()
    round_of(3)
    silo_falls('east', 100)
    silo_falls('south', 200)
    local standings = Report.standings(Teams.all(), Teams.placement(), function(team)
        return Teams.display_name(team)
    end)
    lunatest.assert_equal('north,south,east', table.concat(standings.placement, ','))
    lunatest.assert_equal('Top Left', standings.names.north)
    lunatest.assert_equal('Top Right', standings.names.east)
    lunatest.assert_equal('Bottom Right', standings.names.south)

    local titles = {}
    for i, team in ipairs(standings.placement) do
        titles[i] = standings.names[team]
    end
    local lines = Report.standings_lines(titles)
    lunatest.assert_equal(2, #lines)
    lunatest.assert_equal('2nd: Bottom Right', lines[1])
    lunatest.assert_equal('3rd: Top Right', lines[2])
end

function test_the_standings_are_a_copy()
    -- Kept across the map reset for "Show previous game": the next round's
    -- placement must not rewrite it.
    local placement = { 'north', 'east' }
    local standings = Report.standings({ 'north', 'east' }, placement, function(team)
        return team
    end)
    placement[1] = 'west'
    lunatest.assert_equal('north', standings.placement[1])
    lunatest.assert_equal(0, #Report.standings_lines({ 'Top Left' }))
    lunatest.assert_equal(0, #Report.standings({ 'north' }, nil, tostring).placement)
end

lunatest.run()
