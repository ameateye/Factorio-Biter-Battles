---@diagnostic disable
--
-- Pins `utils/force.lua`, the inverse of the `<team>_biters[_boss]` force
-- naming convention. The convention is already team-count agnostic and is the
-- reason roughly two thirds of the AI code is generic.
--
-- Two things are pinned here and they pull in opposite directions:
--
--   * today's two-team answers, so a refactor that replaces the 'north'/'south'
--     literals by a team registry cannot change what a biter force resolves to;
--   * that the mapping is *prefix-generic* — 'east_biters' already answers
--     'east' — because the N-team design keeps this function rather than
--     replacing it. A "tidy-up" that hard-coded
--     north/south in here would pass every two-team assertion while silently
--     breaking teams 3 and 4.
--
-- utils/force.lua is pure string matching and touches no Factorio API at all.
-- The storage mock below is only the house style of the other suites; nothing
-- in this file needs it.

local lunatest = require('lunatest')

storage = { ['_TEST'] = true }

local Force = require('utils.force')

-- The ring order the N-team design uses.
local RING = { 'north', 'east', 'south', 'west' }

function test_biter_force_names_map_to_their_team()
    lunatest.assert_equal('north', Force.get_player_force_name('north_biters'))
    lunatest.assert_equal('south', Force.get_player_force_name('south_biters'))
end

function test_boss_biter_force_names_map_to_their_team()
    lunatest.assert_equal('north', Force.get_player_force_name('north_biters_boss'))
    lunatest.assert_equal('south', Force.get_player_force_name('south_biters_boss'))
end

function test_player_forces_are_not_biter_forces()
    -- The three forces a player can actually be on, plus the engine ones. All
    -- of them have to answer nil: `ai_strikes.lua:351` and
    -- `team_stats_collect.lua:464` branch on that nil.
    for _, force_name in ipairs({ 'north', 'south', 'spectator', 'player', 'enemy', 'neutral' }) do
        lunatest.assert_nil(Force.get_player_force_name(force_name), force_name .. ' is not a biter force')
    end
end

function test_convention_is_prefix_generic_so_teams_three_and_four_already_work()
    for _, team in ipairs(RING) do
        lunatest.assert_equal(team, Force.get_player_force_name(team .. '_biters'), team .. '_biters')
        lunatest.assert_equal(team, Force.get_player_force_name(team .. '_biters_boss'), team .. '_biters_boss')
    end
end

function test_the_biters_marker_is_an_exact_lowercase_substring()
    -- No normalisation of any kind happens, so a registry that ever produced a
    -- capitalised or abbreviated force name would silently stop resolving.
    lunatest.assert_nil(Force.get_player_force_name('biters'))
    lunatest.assert_nil(Force.get_player_force_name('northbiters'))
    lunatest.assert_nil(Force.get_player_force_name('north_biter'))
    lunatest.assert_nil(Force.get_player_force_name('NORTH_BITERS'))
end

function test_the_prefix_is_lazy_and_unvalidated()
    -- Surprising, and pinned deliberately: the pattern is '^(.-)_biters', so it
    -- returns whatever sits in front of the *first* '_biters' without checking
    -- that it is a team at all. An empty prefix is an empty string, not nil.
    lunatest.assert_equal('', Force.get_player_force_name('_biters'))
    lunatest.assert_equal('a', Force.get_player_force_name('a_biters_b_biters'))
    lunatest.assert_equal('north', Force.get_player_force_name('north_biters_north'))
end

lunatest.run()
