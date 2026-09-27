---@diagnostic disable
--
-- The sentences outside the game over that name the other team
-- (`maps/biter_battles_v2/nteam_wording.lua`): the spy fish line, the "no
-- longer spectating" line, the map intro, the Apply and Team Balancing
-- tooltips.
--
-- Two things are pinned for each of them:
--
--   * at two teams, the literal its caller printed before, character for
--     character -- the two-team game is compared against its baseline and may
--     not gain or lose a byte;
--   * above two teams, words that are true of three and four teams: every
--     enemy named by its title, "all teams", the four-square intro.
--
-- The wording module is pure; the registry (`teams.lua`) loads outside
-- Factorio with the usual `storage` mock and supplies the titles a caller
-- would look up.

local lunatest = require('lunatest')

storage = { ['_TEST'] = true }

local Teams = require('maps.biter_battles_v2.teams')
local Wording = require('maps.biter_battles_v2.nteam_wording')

local function round_of(count)
    lunatest.assert_true(Teams.set_next_count(count), 'set_next_count(' .. tostring(count) .. ')')
    Teams.begin_round()
end

function setup()
    storage = { ['_TEST'] = true }
    game = { tick = 0 }
end

--- The file's lines, keyed by the locale key before '='.
local function locale_entries(path)
    local entries = {}
    local file = assert(io.open(path, 'r'))
    for line in file:lines() do
        local key, value = line:match('^([%w_]+)=(.*)$')
        if key then
            entries[key] = value
        end
    end
    file:close()
    return entries
end

-- == Spy fish ================================================================

function test_the_two_team_spy_line_is_the_one_it_always_printed()
    lunatest.assert_equal('bob sent 3 fish to spy on south team!', Wording.spy_fish_message('bob', 3, 2, 'south'))
    lunatest.assert_equal('ann sent 1 fish to spy on north team!', Wording.spy_fish_message('ann', 1, 2, 'north'))
end

function test_the_spy_line_names_every_enemy_by_its_title_above_two_teams()
    -- The defect: 'bob sent 1 fish to spy on east, south team!' -- force names
    -- nobody sees on the four-square map, and "team" for two of them.
    lunatest.assert_equal(
        'bob sent 1 fish to spy on Top Right, Bottom Right teams!',
        Wording.spy_fish_message('bob', 1, 3, nil, { 'Top Right', 'Bottom Right' })
    )
    lunatest.assert_equal(
        'bob sent 5 fish to spy on Bottom Left team!',
        Wording.spy_fish_message('bob', 5, 4, nil, { 'Bottom Left' })
    )
    lunatest.assert_equal('bob sent 1 fish to spy on enemy team!', Wording.spy_fish_message('bob', 1, 3, nil, {}))
    lunatest.assert_equal('bob sent 1 fish to spy on enemy team!', Wording.spy_fish_message('bob', 1, 3, nil, nil))
end

function test_the_spy_line_of_a_played_three_team_round()
    -- What `Functions.spy_fish` hands over: the alive enemies, coloured.
    round_of(3)
    local titles = {}
    for _, enemy in ipairs(Teams.enemies_of('north')) do
        titles[#titles + 1] = Teams.name_with_color(enemy)
    end
    local line = Wording.spy_fish_message('bob', 1, Teams.count(), nil, titles)
    lunatest.assert_true(line:find('Top Right', 1, true) ~= nil, line)
    lunatest.assert_true(line:find('Bottom Right', 1, true) ~= nil, line)
    lunatest.assert_true(line:find(' teams!', 1, true) ~= nil, line)
    lunatest.assert_nil(line:find('east', 1, true), line)
end

-- == No longer spectating ====================================================

function test_the_two_team_spectating_line_is_unchanged_in_chat_and_on_discord()
    local chat, discord = Wording.spectating_messages('north', 'bob', 2, '[color=1,1,1]Team North[/color]')
    lunatest.assert_equal('Team north player bob is no longer spectating.', chat)
    lunatest.assert_equal('Team north player bob is no longer spectating.', discord)
end

function test_the_spectating_line_names_the_title_in_chat_above_two_teams()
    round_of(4)
    local chat, discord = Wording.spectating_messages('east', 'bob', Teams.count(), Teams.name_with_color('east'))
    lunatest.assert_equal('Team ' .. Teams.name_with_color('east') .. ' player bob is no longer spectating.', chat)
    lunatest.assert_true(chat:find('Top Right', 1, true) ~= nil, chat)
    -- Discord keeps the force name: the line travels through the server log.
    lunatest.assert_equal('Team east player bob is no longer spectating.', discord)
    -- No title handed over: today's line.
    lunatest.assert_equal(
        'Team east player bob is no longer spectating.',
        Wording.spectating_messages('east', 'bob', 4)
    )
end

-- == Map intro ===============================================================

function test_the_map_intro_key_follows_the_layout()
    lunatest.assert_equal('biter_battles.map_info', Wording.map_info_key('horizontal2'))
    lunatest.assert_equal('biter_battles.map_info', Wording.map_info_key(nil))
    lunatest.assert_equal('biter_battles.map_info_cross4', Wording.map_info_key('cross4'))
    round_of(3)
    lunatest.assert_equal('biter_battles.map_info_cross4', Wording.map_info_key(Teams.layout()))
    round_of(2)
    lunatest.assert_equal('biter_battles.map_info', Wording.map_info_key(Teams.layout()))
end

function test_the_four_square_intro_exists_and_says_no_river_of_the_two_team_map()
    local en = locale_entries('locale/en/locale.cfg')
    local two, four = en.map_info, en.map_info_cross4
    lunatest.assert_not_nil(two, 'map_info')
    lunatest.assert_not_nil(four, 'map_info_cross4')
    -- The two-team text is still the two-team text.
    lunatest.assert_true(two:find('The horizontal border river', 1, true) ~= nil)
    lunatest.assert_true(two:find('North and South directions', 1, true) ~= nil)
    lunatest.assert_true(two:find('Defeat the other team by', 1, true) ~= nil)
    -- The four-square text says nothing a four-square map contradicts.
    lunatest.assert_nil(four:find('horizontal', 1, true), 'no horizontal river')
    lunatest.assert_nil(four:find('North and South', 1, true), 'no North and South')
    lunatest.assert_nil(four:find('West and East', 1, true), 'no West and East')
    lunatest.assert_nil(four:find('mirrored', 1, true), 'rotated, not mirrored')
    lunatest.assert_true(four:find('Defeat the other teams by', 1, true) ~= nil)
    lunatest.assert_true(four:find('spy on the other teams', 1, true) ~= nil)
    lunatest.assert_true(four:find('four squares', 1, true) ~= nil)
    -- The rest of the window (links, rules) is the same text.
    lunatest.assert_equal(two:sub(1, 200), four:sub(1, 200))
    lunatest.assert_equal(two:sub(-300), four:sub(-300))
end

-- == Tooltips ================================================================

function test_the_apply_tooltip_says_both_teams_at_two_and_all_teams_above()
    local two = 'Apply every box that differs from the value in force, to the format selected above. An emptied'
        .. ' box stops this format overriding that parameter, dropping it back to the Default column.'
        .. ' Announced to both teams.'
    lunatest.assert_equal(two, Wording.apply_tooltip(2))
    lunatest.assert_equal(two:gsub('both teams', 'all teams'), Wording.apply_tooltip(3))
    lunatest.assert_equal(Wording.apply_tooltip(3), Wording.apply_tooltip(4))
end

function test_the_balancing_tooltip_names_the_rule_of_the_round()
    lunatest.assert_equal(
        'Players can only join a team that has less or equal players than the opposing.',
        Wording.balancing_tooltip(2)
    )
    lunatest.assert_equal(
        'Players can only join a team that has less or equal players than the smallest other team.',
        Wording.balancing_tooltip(3)
    )
    lunatest.assert_equal(Wording.balancing_tooltip(3), Wording.balancing_tooltip(4))
end

lunatest.run()
