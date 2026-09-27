---@diagnostic disable
--
-- Science targeting: above two teams
-- each connected player of a team ticks enemies with his own ticks and steers
-- 1/N of FOCUS_SHARE (30 %), split evenly over his ticks; the rest goes to all
-- alive enemies equally: f(e) = 0.3 * sum_p [e in K_p] / (k_p * N),
-- share(e) = (1 - F) / n + f(e). Pins the shares, the two-team immunity, the
-- cooldown, elimination, offline players, team changes and reset.

local lunatest = require('lunatest')

storage = { ['_TEST'] = true }

local Teams = require('maps.biter_battles_v2.teams')

local function round_of(count)
    lunatest.assert_true(Teams.set_next_count(count))
    return Teams.begin_round()
end

local function summary(targets)
    local parts = {}
    for i, t in ipairs(targets) do
        parts[i] = string.format('%s=%.6f', t.team, t.share)
    end
    return table.concat(parts, ',')
end

local function total(targets)
    local sum = 0
    for _, t in ipairs(targets) do
        sum = sum + t.share
    end
    return sum
end

local players

-- game.forces[<team>].connected_players, rebuilt from `players` (index order)
local function sync_forces()
    local forces = {}
    for _, name in ipairs({ 'north', 'east', 'south', 'west', 'spectator' }) do
        forces[name] = { name = name, connected_players = {} }
    end
    local indexes = {}
    for index in pairs(players) do
        indexes[#indexes + 1] = index
    end
    table.sort(indexes)
    for _, index in ipairs(indexes) do
        local p = players[index]
        if p.connected then
            local list = forces[p.force.name].connected_players
            list[#list + 1] = p
        end
    end
    game.forces = forces
end

-- player `index` named `name` on `force`, connected unless `offline`
local function add_player(index, name, force, offline)
    players[index] = { index = index, name = name, valid = true, connected = not offline, force = { name = force } }
    sync_forces()
    return players[index]
end

function setup()
    storage = { ['_TEST'] = true }
    players = {}
    game = {
        tick = 0,
        forces = {},
        get_player = function(index)
            return players[index]
        end,
    }
    sync_forces()
    -- one connected player per team, index 1..4 (north, east, south, west)
    add_player(1, 'n1', 'north')
    add_player(2, 'e1', 'east')
    add_player(3, 's1', 'south')
    add_player(4, 'w1', 'west')
end

function test_two_teams_refuse_and_keep_no_state()
    Teams.begin_round()
    local ok, reason = Teams.toggle_science_focus('north', 'south', 0, 1)
    lunatest.assert_false(ok)
    lunatest.assert_string(reason)
    lunatest.assert_nil(storage.bb_teams.science_focus)
    lunatest.assert_equal('south=1.000000', summary(Teams.feed_targets('north')))
end

function test_nothing_ticked_is_the_plain_split()
    round_of(4)
    lunatest.assert_equal('east=0.333333,south=0.333333,west=0.333333', summary(Teams.feed_targets('north')))
    lunatest.assert_nil(Teams.science_focus('north', 1))
end

function test_one_tick_at_four_teams_one_player()
    round_of(4)
    lunatest.assert_true(Teams.toggle_science_focus('north', 'south', 0, 1))
    local t = Teams.feed_targets('north')
    -- 0.7/3 = 0.233333 each, +0.3 on south
    lunatest.assert_equal('east=0.233333,south=0.533333,west=0.233333', summary(t))
    lunatest.assert_true(math.abs(total(t) - 1) < 1e-12)
    lunatest.assert_true(t[2].focused)
    lunatest.assert_false(t[1].focused)
end

function test_two_ticks_share_the_30_percent()
    round_of(4)
    Teams.toggle_science_focus('north', 'east', 0, 1)
    Teams.toggle_science_focus('north', 'west', 0, 1)
    lunatest.assert_equal('east=0.383333,south=0.233333,west=0.383333', summary(Teams.feed_targets('north')))
end

function test_all_ticked_equals_plain_split()
    round_of(3)
    Teams.toggle_science_focus('north', 'east', 0, 1)
    Teams.toggle_science_focus('north', 'south', 0, 1)
    lunatest.assert_equal('east=0.500000,south=0.500000', summary(Teams.feed_targets('north')))
end

function test_three_teams_one_tick()
    round_of(3)
    Teams.toggle_science_focus('east', 'north', 0, 2)
    lunatest.assert_equal('north=0.650000,south=0.350000', summary(Teams.feed_targets('east')))
    -- another team's choice does not leak
    lunatest.assert_equal('north=0.500000,east=0.500000', summary(Teams.feed_targets('south')))
end

function test_cooldown_then_untick()
    round_of(4)
    lunatest.assert_true(Teams.toggle_science_focus('north', 'south', 100, 1))
    local ok, reason = Teams.toggle_science_focus('north', 'south', 100 + 3599, 1)
    lunatest.assert_false(ok)
    lunatest.assert_equal('wait 1 s before switching it again', reason)
    -- another button is not locked
    lunatest.assert_true(Teams.toggle_science_focus('north', 'east', 200, 1))
    local ok2, on = Teams.toggle_science_focus('north', 'south', 100 + 3600, 1)
    lunatest.assert_true(ok2)
    lunatest.assert_false(on)
    lunatest.assert_equal('east=0.533333,south=0.233333,west=0.233333', summary(Teams.feed_targets('north')))
end

function test_refusals()
    round_of(4)
    lunatest.assert_false(Teams.toggle_science_focus('north', 'north', 0, 1))
    lunatest.assert_false(Teams.toggle_science_focus('spectator', 'north', 0, 9))
    lunatest.assert_false(Teams.toggle_science_focus('north', 'spectator', 0, 1))
    round_of(3)
    lunatest.assert_false(Teams.toggle_science_focus('north', 'west', 0, 1), 'west does not play at three')
    storage.training_mode = true
    lunatest.assert_false(Teams.toggle_science_focus('north', 'east', 0, 1))
end

function test_eliminated_target_is_unticked_and_dead_sender_forgotten()
    round_of(4)
    Teams.toggle_science_focus('north', 'south', 0, 1)
    Teams.toggle_science_focus('east', 'north', 0, 2)
    Teams.eliminate('south')
    lunatest.assert_nil(Teams.science_focus('north', 1))
    lunatest.assert_equal('east=0.500000,west=0.500000', summary(Teams.feed_targets('north')))
    lunatest.assert_false(Teams.toggle_science_focus('north', 'south', 5000, 1))
    Teams.eliminate('east')
    lunatest.assert_nil(storage.bb_teams.science_focus.east)
end

function test_last_enemy_gets_everything()
    round_of(3)
    Teams.toggle_science_focus('north', 'east', 0, 1)
    Teams.eliminate('south')
    lunatest.assert_equal('east=1.000000', summary(Teams.feed_targets('north')))
end

function test_other_policies_ignore_the_focus()
    round_of(4)
    Teams.toggle_science_focus('north', 'south', 0, 1)
    Teams.set_feed_policy('ring')
    lunatest.assert_equal('east=1.000000', summary(Teams.feed_targets('north')))
    Teams.set_feed_policy('split')
end

function test_reset_forgets_the_focus()
    round_of(4)
    Teams.toggle_science_focus('north', 'south', 0, 1)
    Teams.begin_round()
    lunatest.assert_nil(storage.bb_teams.science_focus)
    lunatest.assert_equal('east=0.333333,south=0.333333,west=0.333333', summary(Teams.feed_targets('north')))
    round_of(2)
    lunatest.assert_nil(storage.bb_teams.science_focus)
end

function test_focus_offered_only_above_two_teams_with_split()
    round_of(2)
    lunatest.assert_false(Teams.science_focus_offered())
    round_of(3)
    lunatest.assert_true(Teams.science_focus_offered())
    Teams.set_feed_policy('ring')
    lunatest.assert_false(Teams.science_focus_offered())
    Teams.set_feed_policy('target')
    lunatest.assert_false(Teams.science_focus_offered())
    Teams.set_feed_policy('split')
    lunatest.assert_true(Teams.science_focus_offered())
end

function test_other_policies_refuse_the_click()
    round_of(3)
    Teams.set_feed_policy('ring')
    local ok, reason = Teams.toggle_science_focus('north', 'south', 0, 1)
    lunatest.assert_false(ok)
    lunatest.assert_string(reason)
    lunatest.assert_nil(storage.bb_teams.science_focus)
    Teams.set_feed_policy('target')
    lunatest.assert_false((Teams.toggle_science_focus('north', 'south', 0, 1)))
    lunatest.assert_nil(storage.bb_teams.science_focus)
    Teams.set_feed_policy('split')
    lunatest.assert_true(Teams.toggle_science_focus('north', 'south', 0, 1))
end

-- Per player: three players on north, indexes 1, 11, 12.
local function north_three()
    add_player(11, 'n2', 'north')
    add_player(12, 'n3', 'north')
end

local function focus_total(targets)
    local sum = 0
    for _, t in ipairs(targets) do
        sum = sum + (t.focus or 0)
    end
    return sum
end

function test_three_players_all_aligned_get_the_full_30_percent()
    round_of(3)
    north_three()
    for _, i in ipairs({ 1, 11, 12 }) do
        lunatest.assert_true(Teams.toggle_science_focus('north', 'east', 0, i))
    end
    local t = Teams.feed_targets('north')
    lunatest.assert_equal('east=0.650000,south=0.350000', summary(t))
    lunatest.assert_equal(0.3, t[1].focus)
    lunatest.assert_equal(0, t[2].focus)
    lunatest.assert_true(math.abs(total(t) - 1) < 1e-12)
    round_of(4)
    north_three()
    for _, i in ipairs({ 1, 11, 12 }) do
        Teams.toggle_science_focus('north', 'east', 0, i)
    end
    lunatest.assert_equal('east=0.533333,south=0.233333,west=0.233333', summary(Teams.feed_targets('north')))
end

function test_two_of_three_aligned_get_20_percent()
    round_of(3)
    north_three()
    Teams.toggle_science_focus('north', 'east', 0, 1)
    Teams.toggle_science_focus('north', 'east', 0, 12)
    local t = Teams.feed_targets('north')
    lunatest.assert_equal('east=0.600000,south=0.400000', summary(t))
    lunatest.assert_true(math.abs(t[1].focus - 0.2) < 1e-15)
    round_of(4)
    north_three()
    Teams.toggle_science_focus('north', 'east', 0, 1)
    Teams.toggle_science_focus('north', 'east', 0, 11)
    -- F = 0.2: base 0.8 / 3 = 0.266667, east + 0.2
    lunatest.assert_equal('east=0.466667,south=0.266667,west=0.266667', summary(Teams.feed_targets('north')))
end

function test_one_player_each_on_a_different_enemy()
    round_of(4)
    north_three()
    Teams.toggle_science_focus('north', 'east', 0, 1)
    Teams.toggle_science_focus('north', 'south', 0, 11)
    -- 10 % each, F = 0.2, the third player's part stays in the split
    lunatest.assert_equal('east=0.366667,south=0.366667,west=0.266667', summary(Teams.feed_targets('north')))
    Teams.toggle_science_focus('north', 'west', 0, 12)
    -- 10 % on each of the three: the equal split again
    local t = Teams.feed_targets('north')
    lunatest.assert_equal('east=0.333333,south=0.333333,west=0.333333', summary(t))
    lunatest.assert_true(math.abs(focus_total(t) - 0.3) < 1e-12)
end

function test_one_player_with_two_ticks_splits_his_part()
    round_of(4)
    north_three()
    Teams.toggle_science_focus('north', 'east', 0, 1)
    Teams.toggle_science_focus('north', 'south', 0, 1)
    Teams.toggle_science_focus('north', 'east', 0, 11)
    -- n1: 5 % east + 5 % south; n2: 10 % east -> f = 0.15 / 0.05 / 0, F = 0.2
    local t = Teams.feed_targets('north')
    lunatest.assert_equal('east=0.416667,south=0.316667,west=0.266667', summary(t))
    lunatest.assert_true(math.abs(t[1].focus - 0.15) < 1e-15)
    lunatest.assert_true(math.abs(t[2].focus - 0.05) < 1e-15)
    lunatest.assert_true(t[2].focused)
    lunatest.assert_false(t[3].focused)
end

function test_offline_player_ticks_do_not_count_nor_does_he()
    round_of(4)
    north_three()
    Teams.toggle_science_focus('north', 'east', 0, 1)
    Teams.toggle_science_focus('north', 'west', 0, 12)
    players[12].connected = false
    sync_forces()
    -- N = 2 connected: n1 steers 15 % to east, the offline n3 nothing
    lunatest.assert_equal('east=0.433333,south=0.283333,west=0.283333', summary(Teams.feed_targets('north')))
    players[12].connected = true
    sync_forces()
    lunatest.assert_equal('east=0.366667,south=0.266667,west=0.366667', summary(Teams.feed_targets('north')))
    -- nobody connected: the plain split
    for _, i in ipairs({ 1, 11, 12 }) do
        players[i].connected = false
    end
    sync_forces()
    lunatest.assert_equal('east=0.333333,south=0.333333,west=0.333333', summary(Teams.feed_targets('north')))
end

function test_player_who_leaves_the_team_stops_counting()
    round_of(3)
    north_three()
    Teams.toggle_science_focus('north', 'east', 0, 1)
    Teams.toggle_science_focus('north', 'south', 0, 11)
    lunatest.assert_equal('east=0.500000,south=0.500000', summary(Teams.feed_targets('north')))
    players[11].force = { name = 'spectator' }
    sync_forces()
    -- N = 2 (n1, n3): n1 steers 15 % to east, base 0.85 / 2
    lunatest.assert_equal('east=0.575000,south=0.425000', summary(Teams.feed_targets('north')))
    lunatest.assert_nil(Teams.focus_backers('north').south)
    -- he joins east: his north ticks do not follow him
    players[11].force = { name = 'east' }
    sync_forces()
    lunatest.assert_equal('north=0.500000,south=0.500000', summary(Teams.feed_targets('east')))
end

function test_elimination_cleans_every_players_picks()
    round_of(4)
    add_player(11, 'n2', 'north')
    Teams.toggle_science_focus('north', 'south', 0, 1)
    Teams.toggle_science_focus('north', 'south', 0, 11)
    Teams.toggle_science_focus('north', 'east', 0, 11)
    Teams.eliminate('south')
    lunatest.assert_nil(Teams.science_focus('north', 1))
    lunatest.assert_true(Teams.science_focus('north', 11).east)
    lunatest.assert_nil(Teams.science_focus('north', 11).south)
    -- n2 now steers his whole 15 % to east; n1 has nothing ticked
    lunatest.assert_equal('east=0.575000,west=0.425000', summary(Teams.feed_targets('north')))
end

function test_lock_is_per_player_and_per_enemy()
    round_of(4)
    add_player(11, 'n2', 'north')
    lunatest.assert_true(Teams.toggle_science_focus('north', 'south', 100, 1))
    lunatest.assert_true(Teams.toggle_science_focus('north', 'south', 101, 11), 'a team mate is not locked')
    local ok, reason = Teams.toggle_science_focus('north', 'south', 101, 1)
    lunatest.assert_false(ok)
    lunatest.assert_equal('wait 60 s before switching it again', reason)
    lunatest.assert_true(Teams.toggle_science_focus('north', 'east', 101, 1))
end

function test_backers_name_the_counted_players()
    round_of(4)
    north_three()
    Teams.toggle_science_focus('north', 'east', 0, 12)
    Teams.toggle_science_focus('north', 'east', 0, 1)
    Teams.toggle_science_focus('north', 'west', 0, 11)
    local b = Teams.focus_backers('north')
    lunatest.assert_equal('n1,n3', table.concat(b.east, ','))
    lunatest.assert_equal('n2', table.concat(b.west, ','))
    lunatest.assert_nil(b.south)
end

function test_nothing_steered_is_bit_identical_to_the_plain_split()
    round_of(4)
    Teams.toggle_science_focus('north', 'east', 0, 1)
    Teams.toggle_science_focus('north', 'east', 3600, 1)
    local t = Teams.feed_targets('north')
    for i = 1, 3 do
        lunatest.assert_true(t[i].share == 1 / 3)
        lunatest.assert_nil(t[i].focused)
    end
end

function test_focus_never_exceeds_30_percent()
    -- every combination of picks of three players at four teams
    round_of(4)
    north_three()
    local enemies = { 'east', 'south', 'west' }
    local worst = 0
    for mask = 0, 511 do
        local team_focus = {}
        for j, index in ipairs({ 1, 11, 12 }) do
            local sub = math.floor(mask / 8 ^ (j - 1)) % 8
            local picks = {}
            for b = 1, 3 do
                if math.floor(sub / 2 ^ (b - 1)) % 2 == 1 then
                    picks[enemies[b]] = true
                end
            end
            team_focus[index] = { picks = picks, until_tick = {} }
        end
        storage.bb_teams.science_focus = { north = team_focus }
        local t = Teams.feed_targets('north')
        local f = focus_total(t)
        worst = math.max(worst, f)
        lunatest.assert_true(f <= 0.3 + 1e-12)
        lunatest.assert_true(math.abs(total(t) - 1) < 1e-12)
        for _, target in ipairs(t) do
            lunatest.assert_true(target.share >= 0.7 / 3 - 1e-12)
        end
    end
    lunatest.assert_true(math.abs(worst - 0.3) < 1e-12)
end

function test_format_percent()
    lunatest.assert_equal('20', Teams.format_percent(0.2))
    lunatest.assert_equal('7.5', Teams.format_percent(0.075))
    lunatest.assert_equal('10', Teams.format_percent(0.3 / 3))
    lunatest.assert_equal('43.3', Teams.format_percent(0.4333333))
end

lunatest.run()
