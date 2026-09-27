---@diagnostic disable
--
-- Pins the static two-team tables and the pure team-shaped helpers that load
-- outside Factorio, so a refactor that replaces the 'north'/'south' literals by
-- a team registry has to change these answers on purpose.
--
-- Covered here:
--   * `maps/biter_battles_v2/tables.lua`      — enemy_team_of, forces_list,
--                                               ammo_modified_forces_list, the
--                                               seven-science arrays
--   * `maps/biter_battles_v2/config.lua`      — the team-name key space
--   * `maps/biter_battles_v2/functions.lua`   — per-team display colours
--   * `comfy_panel/special_games/captain_community_pick.lua` — the two-team draft
--   * `maps/biter_battles_v2/feeding_restriction.lua` — one gate for every team
--
-- The mock is the usual `storage = { _TEST = true }`, rebuilt per test because
-- lunatest walks the test table with `pairs`. No Factorio API is faked.
--
-- One wrinkle that used to matter: `functions.lua:1-11` skips
-- `require('config')` when `storage._TEST` is set, so `Functions.team_name`
-- used to index a nil `Config` and raise for a force with no custom name.
-- Since the two display helpers became wrappers over `teams.lua` (which
-- requires `config.lua` itself) that is no longer so; the shipped default
-- names are still pinned directly on `config.lua` below.

local lunatest = require('lunatest')

storage = { ['_TEST'] = true }

local Tables = require('maps.biter_battles_v2.tables')
local Config = require('maps.biter_battles_v2.config')
local Functions = require('maps.biter_battles_v2.functions')
local FeedingRestriction = require('maps.biter_battles_v2.feeding_restriction')
local CaptainCommunityPick = require('comfy_panel.special_games.captain_community_pick')

local function sorted_keys(t)
    local keys = {}
    for key in pairs(t) do
        keys[#keys + 1] = key
    end
    table.sort(keys)
    return keys
end

function setup()
    storage = { ['_TEST'] = true, tm_custom_name = {} }
end

-- ---------------------------------------------------------------------------
-- tables.lua — "exactly one enemy"
-- ---------------------------------------------------------------------------

function test_enemy_team_of_is_an_involution_over_exactly_two_teams()
    lunatest.assert_equal('south', Tables.enemy_team_of['north'])
    lunatest.assert_equal('north', Tables.enemy_team_of['south'])
    lunatest.assert_equal('north,south', table.concat(sorted_keys(Tables.enemy_team_of), ','))
    for _, team in ipairs({ 'north', 'south' }) do
        lunatest.assert_equal(team, Tables.enemy_team_of[Tables.enemy_team_of[team]], team)
    end
end

function test_enemy_team_of_has_no_answer_for_a_third_team()
    -- Not a harmless nil: `feeding.lua:292` concatenates the result straight
    -- into a force name, so a third team is a crash there.
    lunatest.assert_nil(Tables.enemy_team_of['east'])
    lunatest.assert_nil(Tables.enemy_team_of['west'])
    lunatest.assert_nil(Tables.enemy_team_of['spectator'])
end

function test_forces_list_is_the_science_log_dropdown_in_order()
    -- Consumed positionally: `sciencelogs_tab.lua:165-166` feeds it to a
    -- dropdown and `:207` treats index 1 as "no filter", matching any other
    -- entry against the force name as a Lua pattern.
    lunatest.assert_len(3, Tables.forces_list)
    lunatest.assert_equal('all teams', Tables.forces_list[1])
    lunatest.assert_equal('north', Tables.forces_list[2])
    lunatest.assert_equal('south', Tables.forces_list[3])
end

function test_ammo_modified_forces_list_is_the_two_teams_plus_spectator()
    -- Walked at `init.lua:550,556` to seed and apply the combat balance.
    lunatest.assert_len(3, Tables.ammo_modified_forces_list)
    lunatest.assert_equal('north', Tables.ammo_modified_forces_list[1])
    lunatest.assert_equal('south', Tables.ammo_modified_forces_list[2])
    lunatest.assert_equal('spectator', Tables.ammo_modified_forces_list[3])
end

function test_food_long_and_short_has_seven_entries_in_science_order()
    -- The science-log arrays are sized from this: `sciencelogs_tab.lua:46-62`
    -- builds a per-team totals array of `#food_long_and_short + 1`.
    local expected = {
        { short_name = 'automation', long_name = 'automation-science-pack' },
        { short_name = 'logistic', long_name = 'logistic-science-pack' },
        { short_name = 'military', long_name = 'military-science-pack' },
        { short_name = 'chemical', long_name = 'chemical-science-pack' },
        { short_name = 'production', long_name = 'production-science-pack' },
        { short_name = 'utility', long_name = 'utility-science-pack' },
        { short_name = 'space', long_name = 'space-science-pack' },
    }
    lunatest.assert_len(7, Tables.food_long_and_short)
    lunatest.assert_len(#expected, Tables.food_long_and_short)
    for index, entry in ipairs(expected) do
        lunatest.assert_equal(entry.short_name, Tables.food_long_and_short[index].short_name, 'short ' .. index)
        lunatest.assert_equal(entry.long_name, Tables.food_long_and_short[index].long_name, 'long ' .. index)
    end
end

function test_the_four_science_tables_agree_on_the_same_seven_packs()
    lunatest.assert_len(7, Tables.food_value_table_version)
    lunatest.assert_len(7, sorted_keys(Tables.food_values))
    lunatest.assert_len(7, sorted_keys(Tables.food_names))
    lunatest.assert_len(7, sorted_keys(Tables.food_long_to_short))

    for index, entry in ipairs(Tables.food_long_and_short) do
        local long_name = entry.long_name
        local short = Tables.food_long_to_short[long_name]
        lunatest.assert_equal(index, short.indexScience, long_name)
        lunatest.assert_equal(entry.short_name, short.short_name, long_name)
        lunatest.assert_true(Tables.food_names[long_name], long_name)
        lunatest.assert_equal(Tables.food_values[long_name].value, Tables.food_value_table_version[index], long_name)
    end
end

-- ---------------------------------------------------------------------------
-- config.lua — the team-name key space
-- ---------------------------------------------------------------------------

function test_config_carries_exactly_two_team_name_keys()
    local teams = {}
    for key in pairs(Config) do
        local team = key:match('^(%a+)_side_team_name$')
        if team then
            teams[#teams + 1] = team
        end
    end
    table.sort(teams)
    lunatest.assert_equal('north,south', table.concat(teams, ','))
    lunatest.assert_equal('Team North', Config.north_side_team_name)
    lunatest.assert_equal('Team South', Config.south_side_team_name)
end

-- ---------------------------------------------------------------------------
-- functions.lua — per-team display colours
-- ---------------------------------------------------------------------------

function test_team_display_colours_are_hard_coded_for_north_and_south_only()
    -- The colour tags are the contract: they were literals inside
    -- `Functions.team_name_with_color` and the team registry now owns them
    -- (`teams.lua`, ROSTER). The two tags below are byte for byte the old ones,
    -- spaces after the commas included.
    storage.tm_custom_name = { north = 'Blue Crew', south = 'Red Crew', east = 'Green Crew' }
    lunatest.assert_equal('Blue Crew', Functions.team_name('north'))
    lunatest.assert_equal('Red Crew', Functions.team_name('south'))
    lunatest.assert_equal('[color=120, 120, 255]Blue Crew[/color]', Functions.team_name_with_color('north'))
    lunatest.assert_equal('[color=255, 65, 65]Red Crew[/color]', Functions.team_name_with_color('south'))
    -- Changed on purpose with the team registry: a team of the roster is coloured even
    -- when it does not play this round, because the colour comes from the
    -- roster and not from an if/elseif on 'north'/'south'. It used to read
    -- `assert_equal('Green Crew', ...)`.
    lunatest.assert_equal('[color=80, 215, 95]Green Crew[/color]', Functions.team_name_with_color('east'))
end

function test_team_name_falls_back_to_the_force_name_for_anything_else()
    lunatest.assert_equal('spectator', Functions.team_name('spectator'))
    -- No positional name in a two-team round for a team that does not play, and
    -- no custom one here, so the force name is still what is shown.
    lunatest.assert_equal('east', Functions.team_name('east'))
    -- A force that is not a team of the roster stays uncoloured, as before.
    lunatest.assert_equal('spectator', Functions.team_name_with_color('spectator'))
    -- Changed on purpose with the team registry: this used to pin
    -- `assert_equal('east', ...)`, i.e. an uncoloured third team, because the
    -- colour tag was an if/elseif on 'north'/'south' inside functions.lua. The
    -- roster gives every team of the four a colour, so 'east' is now coloured
    -- (its display name is still the bare force name in a two-team round).
    lunatest.assert_equal('[color=80, 215, 95]east[/color]', Functions.team_name_with_color('east'))
end

-- ---------------------------------------------------------------------------
-- captain_community_pick.lua — the two-team draft
-- ---------------------------------------------------------------------------

function test_the_community_draft_assigns_exactly_two_teams_in_a_snake_order()
    -- `assign_teams` builds `{ {}, {} }` and flips with `3 - next` — two teams
    -- by construction (captain_community_pick.lua:146,154). Which team wins the
    -- opening coin flip is a `math.random` draw, so the test
    -- reads the flip off the result instead of seeding the global stream.
    local teams = CaptainCommunityPick.assign_teams({ 'p1', 'p2', 'p3', 'p4', 'p5', 'p6', 'p7', 'p8' })
    lunatest.assert_len(2, teams)

    local first = (teams[1][1] == 'p1') and 1 or 2
    local second = 3 - first
    lunatest.assert_equal('p1', teams[first][1])
    -- 1, 2, 2, 1, 1, 2, 2, 1 — the "1 then 2-2" snake.
    lunatest.assert_equal('p1,p4,p5,p8', table.concat(teams[first], ','))
    lunatest.assert_equal('p2,p3,p6,p7', table.concat(teams[second], ','))
end

function test_the_community_draft_splits_an_odd_roster_by_one()
    local teams = CaptainCommunityPick.assign_teams({ 'a', 'b', 'c', 'd', 'e' })
    lunatest.assert_len(2, teams)

    local first = (teams[1][1] == 'a') and 1 or 2
    local second = 3 - first
    lunatest.assert_equal('a,d,e', table.concat(teams[first], ','))
    lunatest.assert_equal('b,c', table.concat(teams[second], ','))
end

function test_the_community_draft_of_an_empty_roster_is_two_empty_teams()
    local teams = CaptainCommunityPick.assign_teams({})
    lunatest.assert_len(2, teams)
    lunatest.assert_len(0, teams[1])
    lunatest.assert_len(0, teams[2])
end

-- ---------------------------------------------------------------------------
-- feeding_restriction.lua — team-agnostic today, and pinned that way
-- ---------------------------------------------------------------------------

function test_the_build_score_gate_is_one_number_for_every_team()
    -- No force or team is an input: the requirement is derived from the
    -- difficulty vote alone, so every team is held to the same number. Pinned
    -- so a per-team gate cannot appear by accident.
    storage.bb_settings = nil
    lunatest.assert_equal(0, FeedingRestriction.get_required_build_score(), 'no settings')

    storage.bb_settings = { science_send_score_restriction = false }
    lunatest.assert_equal(0, FeedingRestriction.get_required_build_score(), 'restriction off')

    storage.bb_settings = { science_send_score_restriction = true }
    -- No difficulty voted yet: falls back to Easy (0.75) → ceil(48 / 0.75).
    lunatest.assert_equal(64, FeedingRestriction.get_required_build_score(), 'default difficulty')

    for _, difficulty in ipairs(Tables.difficulties) do
        storage.difficulty_vote_value = difficulty.value
        lunatest.assert_equal(
            FeedingRestriction.calc_required_score(difficulty.value),
            FeedingRestriction.get_required_build_score(),
            difficulty.short_name
        )
    end
end

lunatest.run()
