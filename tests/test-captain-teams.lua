---@diagnostic disable
--
-- Pins `comfy_panel/special_games/captain_teams.lua`: the pure part of a
-- captain game with 3 or 4 captains.
--
-- What it is here to catch:
--   * the SNAKE pick order: 1,2,..,N,N,..,2,1,1,2,.. -- the team at each end
--     picks twice in a row, so nobody keeps the first-pick advantage;
--   * the catch-up rule when a group is picked (a team that already holds more
--     players than the smallest team is skipped until the others catch up),
--     which is today's 2-team rule generalised;
--   * the pick order after the initial phase: the smallest team, ties by ring
--     order;
--   * which team a captain or vice-captain belongs to (captainList[i] is the
--     captain of the i-th team of the round);
--   * the automatic start verdict, with 2 as today's literal thresholds.
--
-- The module needs neither `game` nor `storage`.

local lunatest = require('lunatest')

local CT = require('comfy_panel.special_games.captain_teams')

local function seq(snake, counts, n, picked)
    local out = {}
    for _ = 1, n do
        local t = CT.snake_next(snake, counts)
        out[#out + 1] = t
        counts[t] = counts[t] + (picked or 1)
    end
    return table.concat(out, ',')
end

function test_snake_three_teams()
    local s = CT.new_snake({ 'north', 'east', 'south' })
    local counts = { north = 0, east = 0, south = 0 }
    lunatest.assert_equal('north,east,south,south,east,north,north,east,south', seq(s, counts, 9))
end

function test_snake_four_teams()
    local s = CT.new_snake({ 'east', 'south', 'west', 'north' })
    local counts = { north = 0, east = 0, south = 0, west = 0 }
    lunatest.assert_equal('east,south,west,north,north,west,south,east', seq(s, counts, 8))
end

function test_snake_first_pick_is_first_of_order()
    local s = CT.new_snake({ 'south', 'north', 'east' })
    lunatest.assert_equal('south', CT.snake_next(s, { north = 0, east = 0, south = 0 }))
end

function test_snake_skips_team_ahead_after_group_pick()
    local s = CT.new_snake({ 'north', 'east', 'south' })
    local counts = { north = 0, east = 0, south = 0 }
    lunatest.assert_equal('north', CT.snake_next(s, counts))
    counts.north = 3 -- north picked a group of three
    lunatest.assert_equal('east', CT.snake_next(s, counts))
    counts.east = 1
    lunatest.assert_equal('south', CT.snake_next(s, counts))
    counts.south = 1
    -- south's double pick: south (1) is still the smallest, it picks
    lunatest.assert_equal('south', CT.snake_next(s, counts))
    counts.south = 2
    lunatest.assert_equal('east', CT.snake_next(s, counts))
    counts.east = 2
    -- north (3) is ahead of east/south (2): skipped, the snake bounces back
    local t = CT.snake_next(s, counts)
    lunatest.assert_true(t ~= 'north', 'north must be skipped, got ' .. t)
end

function test_snake_never_loops_forever()
    local s = CT.new_snake({ 'north', 'east', 'south', 'west' })
    -- inconsistent counts (a team missing) still answer a team of the order
    local t = CT.snake_next(s, { north = 5, east = 5, south = 5 })
    lunatest.assert_equal('west', t)
end

function test_fewest_ties_by_ring_order()
    lunatest.assert_equal(
        'east',
        CT.fewest({ 'north', 'east', 'south', 'west' }, { north = 3, east = 2, south = 2, west = 4 })
    )
    lunatest.assert_equal('north', CT.fewest({ 'north', 'east', 'south' }, { north = 1, east = 1, south = 1 }))
end

function test_rotate()
    lunatest.assert_equal(
        'south,west,north,east',
        table.concat(CT.rotate({ 'north', 'east', 'south', 'west' }, 2), ',')
    )
    lunatest.assert_equal('north,east,south', table.concat(CT.rotate({ 'north', 'east', 'south' }, 0), ','))
end

function test_captain_team()
    local teams = { 'north', 'east', 'south' }
    local vice = { north = {}, east = { dave = true }, south = {} }
    local list = { 'ann', 'bob', 'cid' }
    lunatest.assert_equal('north', CT.captain_team(list, vice, teams, 'ann'))
    lunatest.assert_equal('east', CT.captain_team(list, vice, teams, 'bob'))
    lunatest.assert_equal('south', CT.captain_team(list, vice, teams, 'cid'))
    lunatest.assert_equal('east', CT.captain_team(list, vice, teams, 'dave'))
    lunatest.assert_nil(CT.captain_team(list, vice, teams, 'zed'))
end

function test_captain_index()
    lunatest.assert_equal(1, CT.captain_index({ 'north', 'south' }, 'north'))
    lunatest.assert_equal(2, CT.captain_index({ 'north', 'south' }, 'south'))
    lunatest.assert_equal(4, CT.captain_index({ 'north', 'east', 'south', 'west' }, 'west'))
    lunatest.assert_nil(CT.captain_index({ 'north', 'south' }, 'spectator'))
end

function test_is_captain_counts_only_first_n()
    -- volunteers beyond the round's count are not captains yet
    lunatest.assert_true(CT.is_captain({ 'a', 'b', 'c', 'd' }, 3, 'c'))
    lunatest.assert_false(CT.is_captain({ 'a', 'b', 'c', 'd' }, 3, 'd'))
end

function test_auto_start_verdict()
    lunatest.assert_equal('too_few_captains', CT.auto_start_verdict(1, 9, 2))
    lunatest.assert_equal('too_few_players', CT.auto_start_verdict(2, 1, 2))
    lunatest.assert_equal('start', CT.auto_start_verdict(2, 2, 2))
    lunatest.assert_equal('too_many', CT.auto_start_verdict(3, 9, 2))
    lunatest.assert_equal('too_few_captains', CT.auto_start_verdict(2, 9, 3))
    lunatest.assert_equal('too_few_players', CT.auto_start_verdict(3, 2, 3))
    lunatest.assert_equal('start', CT.auto_start_verdict(3, 3, 3))
    lunatest.assert_equal('start', CT.auto_start_verdict(4, 12, 4))
    lunatest.assert_equal('too_many', CT.auto_start_verdict(5, 12, 4))
end

function test_shuffle_keeps_members()
    local calls = 0
    local function rnd(a, b)
        calls = calls + 1
        return a
    end
    local out = CT.shuffle({ 'a', 'b', 'c', 'd' }, rnd)
    table.sort(out)
    lunatest.assert_equal('a,b,c,d', table.concat(out, ','))
    lunatest.assert_equal(3, calls)
end

function test_vs_text()
    lunatest.assert_equal(
        'Team ann (North) vs Team bob (East) vs Team cid (South)',
        CT.vs_text({ 'ann', 'bob', 'cid' }, { 'north', 'east', 'south' })
    )
    lunatest.assert_equal('Team ann (North) vs Team West', CT.vs_text({ 'ann' }, { 'north', 'west' }))
end

lunatest.run()
