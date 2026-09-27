---@diagnostic disable
--
-- Pins the pure half of the guards that keep the special games
-- honest once a round can have more than two teams.
--
-- What is tested here is the **team selector of the left/both/right switch**
-- that `disabled_entities.lua` and `disabled_research.lua` share, and the words
-- their messages use for it. Two things matter:
--
--   * with two teams the selector has to answer exactly what the
--     `{ left = 'north', right = 'south' }` map and the "both" branch answered,
--     and `scope_of_switch` has to produce the same substrings the two-team
--     `game.print` lines were built from ('team north', 'both teams') -- those
--     lines are compared byte for byte against the baseline;
--   * above two teams the switch keeps a meaning instead of crashing: left is
--     the first active team, right the last, the none state every team.
--
-- BOTH files are loaded here. `disabled_research.lua` needs nothing but data
-- (`utils.color_presets`, and `teams.lua` needs only `config.lua`);
-- `disabled_entities.lua` pulls in `utils.event`, which reaches for `defines` at
-- load, so that one require is stubbed below. Their `teams_of_switch` are the
-- same function byte for byte, but their `scope_of_switch` are NOT -- research
-- says 'team north', entities says 'team North' -- and the capitalised one is
-- the one that has to reproduce '... for team North is being generated!'
-- exactly. Two near-identical copies in two files is the drift this suite is
-- here to catch, so both are pinned.
--
-- The rest of the guards are refusals inside Factorio-only code paths
-- (`SpecialGames.disable_unsupported`, the `generate()` guard, `/team-count`),
-- none of which can be loaded here: `special_games.lua` requires all thirteen
-- special games and `commands/team_count.lua` calls `commands.add_command` at
-- load. The `/tt-enable` refusal this comment used to name is gone: Triple Threat
-- now plays at three and four teams, and what is left of its pure
-- half is pinned in `tests/test-tt-mode.lua`.

local lunatest = require('lunatest')

storage = { ['_TEST'] = true }

-- What `disabled_entities.lua` touches at load, and nothing more: it registers
-- three handlers and never calls one from anything tested here.
defines = {
    events = {
        on_built_entity = 1,
        on_marked_for_upgrade = 2,
        on_pre_ghost_upgraded = 3,
    },
}
package.loaded['utils.event'] = { add = function() end }

local DisabledResearch = require('comfy_panel.special_games.disabled_research')
local DisabledEntities = require('comfy_panel.special_games.disabled_entities')
local Teams = require('maps.biter_battles_v2.teams')

local teams_of_switch = DisabledResearch.teams_of_switch
local scope_of_switch = DisabledResearch.scope_of_switch

--- Ask for `count` teams and start the round.
local function round_of(count)
    lunatest.assert_true(Teams.set_next_count(count), 'set_next_count(' .. tostring(count) .. ')')
    Teams.begin_round()
end

local function joined(array)
    return table.concat(array, ',')
end

--- The substring the two `game.print` lines of a generate are built around.
local function selected(switch_state)
    return scope_of_switch(teams_of_switch(switch_state))
end

--- The same, for the other copy of the pair: the messages of Disabled entities.
local function selected_entities(switch_state)
    return DisabledEntities.scope_of_switch(DisabledEntities.teams_of_switch(switch_state))
end

function setup()
    storage = { ['_TEST'] = true }
end

-- ---------------------------------------------------------------------------
-- Two teams: exactly the switch of today
-- ---------------------------------------------------------------------------

function test_two_teams_left_is_north_right_is_south_none_is_both()
    round_of(2)

    lunatest.assert_equal('north', joined(teams_of_switch('left')))
    lunatest.assert_equal('south', joined(teams_of_switch('right')))
    lunatest.assert_equal('north,south', joined(teams_of_switch('none')))
end

function test_two_teams_is_also_what_a_reader_sees_before_the_first_round()
    -- `Teams.state()` creates the two-team default lazily, so the switch
    -- answers today's game even before `begin_round()` has ever run.
    lunatest.assert_nil(storage.bb_teams)

    lunatest.assert_equal('north', joined(teams_of_switch('left')))
    lunatest.assert_equal('south', joined(teams_of_switch('right')))
    lunatest.assert_equal('north,south', joined(teams_of_switch('none')))
end

function test_two_team_messages_read_exactly_as_they_did()
    round_of(2)

    -- 'Special game Disabled research: … for team north is being generated!'
    lunatest.assert_equal('team north', selected('left'))
    lunatest.assert_equal('team south', selected('right'))
    -- '… for both teams is being generated!'
    lunatest.assert_equal('both teams', selected('none'))
end

function test_an_unknown_switch_state_selects_every_team_as_the_none_state_did()
    round_of(2)

    -- The old code reached the "both" branch through `if tab[team] then`, so
    -- anything that was not 'left' or 'right' -- nil included -- meant both.
    lunatest.assert_equal('north,south', joined(teams_of_switch('none')))
    lunatest.assert_equal('north,south', joined(teams_of_switch(nil)))
    lunatest.assert_equal('north,south', joined(teams_of_switch('middle')))
end

-- ---------------------------------------------------------------------------
-- Above two teams
-- ---------------------------------------------------------------------------

function test_three_teams_left_is_the_first_right_is_the_last()
    round_of(3)

    lunatest.assert_equal('north', joined(teams_of_switch('left')))
    lunatest.assert_equal('south', joined(teams_of_switch('right')), 'the last of north,east,south')
    lunatest.assert_equal('north,east,south', joined(teams_of_switch('none')))
end

function test_four_teams_left_is_the_first_right_is_the_last()
    round_of(4)

    lunatest.assert_equal('north', joined(teams_of_switch('left')))
    lunatest.assert_equal('west', joined(teams_of_switch('right')))
    lunatest.assert_equal('north,east,south,west', joined(teams_of_switch('none')))
end

function test_above_two_teams_the_whole_round_is_all_teams_not_both()
    round_of(3)
    lunatest.assert_equal('all teams', selected('none'))

    round_of(4)
    lunatest.assert_equal('all teams', selected('none'))
end

function test_above_two_teams_a_single_team_is_named_by_its_display_name()
    -- The force name of a corner team says nothing about which corner just
    -- lost a technology, and left/right are the only two the switch can pick.
    round_of(3)
    lunatest.assert_equal('team Top Left', selected('left'))
    lunatest.assert_equal('team Bottom Right', selected('right'), 'the last of north,east,south')

    round_of(4)
    lunatest.assert_equal('team Top Left', selected('left'))
    lunatest.assert_equal('team Bottom Left', selected('right'))

    -- The team manager's custom name wins here as everywhere else.
    storage.tm_custom_name = { west = 'Yellow' }
    lunatest.assert_equal('team Yellow', selected('right'))
end

-- ---------------------------------------------------------------------------
-- The other copy: Disabled entities, whose messages capitalise the team
-- ---------------------------------------------------------------------------

function test_the_two_team_disabled_entities_messages_read_exactly_as_they_did()
    round_of(2)

    -- 'Special game Disabled entities: … for team North is being generated!'
    lunatest.assert_equal('team North', selected_entities('left'))
    lunatest.assert_equal('team South', selected_entities('right'))
    lunatest.assert_equal('both teams', selected_entities('none'))
    lunatest.assert_equal('both teams', selected_entities(nil), 'anything but left/right is both')
end

function test_the_two_selectors_are_the_same_function()
    for _, count in ipairs({ 2, 3, 4 }) do
        round_of(count)
        for _, state in ipairs({ 'left', 'right', 'none' }) do
            lunatest.assert_equal(
                joined(teams_of_switch(state)),
                joined(DisabledEntities.teams_of_switch(state)),
                count .. ' teams, ' .. state
            )
        end
    end
end

function test_disabled_entities_also_names_a_single_team_by_display_name_above_two()
    round_of(4)
    lunatest.assert_equal('team Top Left', selected_entities('left'))
    lunatest.assert_equal('team Bottom Left', selected_entities('right'))
    lunatest.assert_equal('all teams', selected_entities('none'))

    -- The capitalising branch is the two-team one and nothing else reaches it.
    round_of(3)
    lunatest.assert_equal('team Bottom Right', selected_entities('right'))
end

-- ---------------------------------------------------------------------------
-- The selector never hands out the live array
-- ---------------------------------------------------------------------------

function test_the_selected_list_is_a_copy_of_the_rounds_team_list()
    round_of(4)

    local selection = teams_of_switch('none')
    lunatest.assert_equal('north,east,south,west', joined(selection))

    selection[1] = 'clobbered'
    table.remove(selection)

    lunatest.assert_equal('north,east,south,west', joined(Teams.all()), 'the round is untouched')
end

function test_the_count_of_the_round_follows_begin_round_and_nothing_else()
    round_of(4)
    lunatest.assert_equal('north,east,south,west', joined(teams_of_switch('none')))

    -- A pending request is not the round: the switch keeps answering for the
    -- teams that are playing until the next reset.
    lunatest.assert_true(Teams.set_next_count(2))
    lunatest.assert_equal('north,east,south,west', joined(teams_of_switch('none')))
    lunatest.assert_equal('west', joined(teams_of_switch('right')))

    Teams.begin_round()
    lunatest.assert_equal('north,south', joined(teams_of_switch('none')))
    lunatest.assert_equal('south', joined(teams_of_switch('right')))
end

lunatest.run()
