---@diagnostic disable
--
-- The admin team manager above two teams: `team_manager_model.lua`, which is
-- everything the multi-team work added to `team_manager.lua` that is not a GUI
-- call.
--
-- The window itself cannot be built outside Factorio, so the layout is tested
-- as the data it is drawn from:
--
--   * the COLUMNS of the window -- the teams of the round in ring order and
--     then the spectators, a team that is out of the round still among them;
--   * the DESTINATIONS an entry of a given column offers -- every other living
--     team and the spectators, never itself, never a team that is out;
--   * the ABBREVIATION on a destination button -- the display name when it
--     fits, the initials of its words when it does not, and never half of a
--     UTF-8 character, because a custom team name may be written in any
--     alphabet;
--   * the CLICK GRAMMAR -- destination and player travel in the button's
--     `tags`, so a player name full of dots, dashes and underscores comes back
--     out exactly as it went in, and a button that outlived its team is
--     recognised as such.
--
-- Two teams draw the +-1 arrow chain instead, from `force_chain()` in
-- `team_manager.lua`, which this module is not part of and does not touch.
--
-- `game` is nil for the whole file except in the two tests that eliminate a
-- team (`Teams.eliminate` timestamps with `game.tick`), so anything in the
-- model that reached for the game state would error rather than pass.

local lunatest = require('lunatest')

storage = { ['_TEST'] = true }

local Model = require('maps.biter_battles_v2.team_manager_model')
local Teams = require('maps.biter_battles_v2.teams')

--- Ask for `count` teams and start the round.
---@param count integer
local function round_of(count)
    lunatest.assert_true(Teams.set_next_count(count), 'set_next_count(' .. tostring(count) .. ')')
    Teams.begin_round()
end

--- Nothing but `game.tick`, which is all `Teams.eliminate` reads.
local function mock_game()
    game = { tick = 600 }
end

--- 'north,east,south,west,spectator' -- the forces of a column or destination
--- list, in order, as one comparable string.
---@param list table[]
---@return string
local function forces_of(list)
    local names = {}
    for i, entry in ipairs(list) do
        names[i] = entry.force
    end
    return table.concat(names, ',')
end

--- The captions of a column or destination list, in order.
---@param list table[]
---@return string
local function captions_of(list)
    local captions = {}
    for i, entry in ipairs(list) do
        captions[i] = entry.caption
    end
    return table.concat(captions, ',')
end

--- The tooltips of a destination list, in order.
---@param list table[]
---@return string
local function tooltips_of(list)
    local tooltips = {}
    for i, entry in ipairs(list) do
        tooltips[i] = entry.tooltip
    end
    return table.concat(tooltips, ' | ')
end

--- 'r,g,b' of a colour, or 'nil'.
---@param color table|nil
---@return string
local function rgb_of(color)
    if not color then
        return 'nil'
    end
    return color.r .. ',' .. color.g .. ',' .. color.b
end

function setup()
    storage = { ['_TEST'] = true }
    game = nil
end

-- ---------------------------------------------------------------------------
-- The columns: the teams of the round, then the spectators
-- ---------------------------------------------------------------------------

function test_four_teams_are_five_columns_in_ring_order_with_the_spectators_last()
    round_of(4)

    local columns = Model.columns()

    lunatest.assert_equal(5, #columns)
    lunatest.assert_equal('north,east,south,west,spectator', forces_of(columns))
    lunatest.assert_equal('TOP LEFT,TOP RIGHT,BOTTOM RIGHT,BOTTOM LEFT,SPECTATOR', captions_of(columns))
    lunatest.assert_equal('Top Left', columns[1].display)
    lunatest.assert_equal('Bottom Left', columns[4].display)
    lunatest.assert_equal('spectator', columns[5].display)
    for i = 1, 4 do
        lunatest.assert_false(columns[i].spectator, columns[i].force)
        lunatest.assert_true(columns[i].alive, columns[i].force)
    end
    lunatest.assert_true(columns[5].spectator)
    lunatest.assert_true(columns[5].alive)
end

function test_three_teams_are_four_columns()
    round_of(3)

    local columns = Model.columns()

    lunatest.assert_equal('north,east,south,spectator', forces_of(columns))
    lunatest.assert_equal('TOP LEFT,TOP RIGHT,BOTTOM RIGHT,SPECTATOR', captions_of(columns))
end

function test_a_column_carries_the_team_colour_and_the_spectators_carry_none()
    -- The window paints the spectator header with the grey the chain's
    -- spectator button has always had; the roster has no colour for a force
    -- that is not a team, and this is where that shows.
    round_of(4)

    local columns = Model.columns()

    lunatest.assert_equal('120,120,255', rgb_of(columns[1].color))
    lunatest.assert_equal('80,215,95', rgb_of(columns[2].color))
    lunatest.assert_equal('255,65,65', rgb_of(columns[3].color))
    lunatest.assert_equal('255,200,50', rgb_of(columns[4].color))
    lunatest.assert_equal('nil', rgb_of(columns[5].color))
end

function test_a_custom_team_name_names_the_column_and_every_button_that_leads_to_it()
    round_of(4)
    storage.tm_custom_name = { north = 'Blue Crew', spectator = 'The Crowd' }

    local columns = Model.columns()
    lunatest.assert_equal('Blue Crew', columns[1].display)
    lunatest.assert_equal('BLUE CREW', columns[1].caption)
    lunatest.assert_equal('The Crowd', columns[5].display)
    lunatest.assert_equal('THE CROWD', columns[5].caption)

    local destinations = Model.destinations('east')
    lunatest.assert_equal('north,south,west,spectator', forces_of(destinations))
    lunatest.assert_equal('BC,BR,BL,TC', captions_of(destinations))
    lunatest.assert_equal(
        'Move to Blue Crew | Move to Bottom Right | Move to Bottom Left | Move to The Crowd',
        tooltips_of(destinations)
    )
end

function test_a_team_that_is_out_of_the_round_is_still_a_column()
    -- Its players were moved to the spectators when it died, but the admin has
    -- to see that the team is there and out.
    mock_game()
    round_of(4)
    Teams.eliminate('east')

    local columns = Model.columns()

    lunatest.assert_equal('north,east,south,west,spectator', forces_of(columns))
    lunatest.assert_true(columns[1].alive)
    lunatest.assert_false(columns[2].alive)
    lunatest.assert_true(columns[3].alive)
    lunatest.assert_true(columns[4].alive)
end

-- ---------------------------------------------------------------------------
-- The destination buttons of one entry
-- ---------------------------------------------------------------------------

function test_an_entry_of_a_team_column_reaches_the_other_teams_and_the_spectators()
    round_of(4)

    local destinations = Model.destinations('north')

    lunatest.assert_equal(4, #destinations)
    lunatest.assert_equal('east,south,west,spectator', forces_of(destinations))
    lunatest.assert_equal('TR,BR,BL,spec', captions_of(destinations))
    lunatest.assert_equal(
        'Move to Top Right | Move to Bottom Right | Move to Bottom Left | Move to spectator',
        tooltips_of(destinations)
    )
    lunatest.assert_equal('80,215,95', rgb_of(destinations[1].color))
    lunatest.assert_equal('nil', rgb_of(destinations[4].color), 'the spectators have no team colour')
end

function test_an_entry_of_the_spectator_column_reaches_every_team_and_not_the_spectators()
    round_of(4)

    local destinations = Model.destinations('spectator')

    lunatest.assert_equal('north,east,south,west', forces_of(destinations))
    lunatest.assert_equal('TL,TR,BR,BL', captions_of(destinations))
end

function test_the_destinations_of_a_three_team_round()
    round_of(3)

    lunatest.assert_equal('east,south,spectator', forces_of(Model.destinations('north')))
    lunatest.assert_equal('north,east,south', forces_of(Model.destinations('spectator')))
    lunatest.assert_equal('north,east,spectator', forces_of(Model.destinations('south')))
end

function test_the_destinations_keep_the_ring_order_whichever_column_asks()
    round_of(4)

    lunatest.assert_equal('north,east,west,spectator', forces_of(Model.destinations('south')))
    lunatest.assert_equal('north,east,south,spectator', forces_of(Model.destinations('west')))
end

function test_a_team_that_is_out_of_the_round_is_nobody_s_destination()
    -- Joining it teleports the player into a quarter with no base and no silo.
    mock_game()
    round_of(4)
    Teams.eliminate('east')

    lunatest.assert_equal('south,west,spectator', forces_of(Model.destinations('north')))
    lunatest.assert_equal('north,south,west', forces_of(Model.destinations('spectator')))
end

function test_the_column_of_a_team_that_is_out_still_offers_the_way_out()
    -- Its players are spectators already, but a player who ends up on a dead
    -- force any other way must still be movable off it.
    mock_game()
    round_of(4)
    Teams.eliminate('east')

    lunatest.assert_equal('north,south,west,spectator', forces_of(Model.destinations('east')))
end

-- ---------------------------------------------------------------------------
-- The caption of a destination button
-- ---------------------------------------------------------------------------

function test_a_display_name_that_fits_is_the_whole_caption()
    lunatest.assert_equal('Red', Model.abbreviate('Red'))
    lunatest.assert_equal('ABBA', Model.abbreviate('ABBA'))
    lunatest.assert_equal('N', Model.abbreviate('N'))
    lunatest.assert_equal('1v1', Model.abbreviate('1v1'))
end

function test_a_name_of_several_words_becomes_their_initials()
    lunatest.assert_equal('TL', Model.abbreviate('Top Left'))
    lunatest.assert_equal('BR', Model.abbreviate('Bottom Right'))
    lunatest.assert_equal('TRB', Model.abbreviate('the red barons'))
    lunatest.assert_equal('ABCD', Model.abbreviate('a-b c_d'), 'dashes and underscores part words too')
end

function test_a_single_long_word_keeps_its_first_letters()
    lunatest.assert_equal('spec', Model.abbreviate('spectator'))
    lunatest.assert_equal('Warr', Model.abbreviate('Warriors'))
end

function test_the_initials_stop_at_four_words()
    lunatest.assert_equal('OTTF', Model.abbreviate('one two three four five six'))
end

function test_a_name_in_another_alphabet_is_not_cut_in_half()
    -- Bytes are not characters: a 4-byte truncation of Cyrillic is two letters
    -- and a broken one. Four characters, or nothing.
    lunatest.assert_equal('Медв', Model.abbreviate('Медведи'))
    lunatest.assert_equal('КА', Model.abbreviate('Красная Армия'))
    lunatest.assert_equal('東', Model.abbreviate('東'))
end

function test_a_blank_name_still_gives_a_clickable_caption()
    lunatest.assert_equal('?', Model.abbreviate(''))
    lunatest.assert_equal('?', Model.abbreviate('   '))
end

function test_a_name_is_trimmed_before_it_is_measured()
    lunatest.assert_equal('Red', Model.abbreviate('  Red  '))
    lunatest.assert_equal('TL', Model.abbreviate(' Top Left '))
end

-- ---------------------------------------------------------------------------
-- The click grammar: tags, not a name that would have to be split
-- ---------------------------------------------------------------------------

function test_the_tags_of_a_button_carry_the_destination_and_the_player()
    local tags = Model.button_tags('south', 'Bob')

    lunatest.assert_equal('south', tags[Model.DESTINATION_TAG])
    lunatest.assert_equal('Bob', tags[Model.PLAYER_TAG])

    local destination, player_name = Model.parse_click(tags)
    lunatest.assert_equal('south', destination)
    lunatest.assert_equal('Bob', player_name)
end

function test_a_player_name_full_of_punctuation_survives_the_round_trip()
    -- The reason the click is read from tags and not from an element name: a
    -- name built from both could not be taken apart again without guessing
    -- where the destination ends and the player begins.
    local names = {
        'a.b',
        'a-b',
        'a_b',
        'Bob.the-builder_1',
        'north',
        'spectator',
        'team_manager_move_north',
        '...',
        'Медведь',
    }
    for _, name in ipairs(names) do
        local destination, player_name = Model.parse_click(Model.button_tags('west', name))
        lunatest.assert_equal('west', destination, name)
        lunatest.assert_equal(name, player_name, name)
    end
end

function test_the_parse_ignores_every_element_that_is_not_a_destination_button()
    lunatest.assert_nil(Model.parse_click(nil))
    lunatest.assert_nil(Model.parse_click('team_manager_move_north'))
    lunatest.assert_nil(Model.parse_click({}))
    lunatest.assert_nil(Model.parse_click({ sort_by = 'x', tech_id = 'y' }), 'the tags of another window')
    lunatest.assert_nil(Model.parse_click({ [Model.DESTINATION_TAG] = 'north' }), 'no player')
    lunatest.assert_nil(Model.parse_click({ [Model.PLAYER_TAG] = 'Bob' }), 'no destination')
    lunatest.assert_nil(Model.parse_click({ [Model.DESTINATION_TAG] = 7, [Model.PLAYER_TAG] = 'Bob' }))
    lunatest.assert_nil(Model.parse_click({ [Model.DESTINATION_TAG] = 'north', [Model.PLAYER_TAG] = true }))
    lunatest.assert_nil(Model.parse_click({ [Model.DESTINATION_TAG] = '', [Model.PLAYER_TAG] = 'Bob' }))
    lunatest.assert_nil(Model.parse_click({ [Model.DESTINATION_TAG] = 'north', [Model.PLAYER_TAG] = '' }))
end

function test_a_destination_is_available_while_its_team_plays_and_lives()
    round_of(4)
    lunatest.assert_true(Model.is_available_destination('north'))
    lunatest.assert_true(Model.is_available_destination('west'))
    lunatest.assert_true(Model.is_available_destination('spectator'))

    mock_game()
    Teams.eliminate('west')
    lunatest.assert_false(Model.is_available_destination('west'))
end

function test_a_force_that_is_not_a_team_of_this_round_is_never_a_destination()
    -- A dormant `east` force left behind by an earlier four-team round exists
    -- and would take the player; the round it is not part of must not offer it.
    round_of(2)

    lunatest.assert_true(Model.is_available_destination('north'))
    lunatest.assert_true(Model.is_available_destination('south'))
    lunatest.assert_true(Model.is_available_destination('spectator'))
    lunatest.assert_false(Model.is_available_destination('east'))
    lunatest.assert_false(Model.is_available_destination('west'))
    lunatest.assert_false(Model.is_available_destination('player'))
    lunatest.assert_false(Model.is_available_destination('north_biters'))
    lunatest.assert_false(Model.is_available_destination(nil))
end

function test_reading_a_click_does_not_decide_whether_its_destination_is_still_there()
    -- The two halves are separate on purpose: a button that outlived its round
    -- still parses, and the window answers the click by saying so and redrawing
    -- itself rather than by silently doing nothing.
    round_of(2)

    local destination, player_name = Model.parse_click(Model.button_tags('east', 'Bob'))

    lunatest.assert_equal('east', destination)
    lunatest.assert_equal('Bob', player_name)
    lunatest.assert_false(Model.is_available_destination(destination))
end

-- ---------------------------------------------------------------------------
-- Element names: unique among siblings, and that is all they have to be
-- ---------------------------------------------------------------------------

function test_the_element_names_of_a_column_an_entry_and_a_button()
    lunatest.assert_equal('team_manager_players_north', Model.column_name('north'))
    lunatest.assert_equal('team_manager_players_spectator', Model.column_name('spectator'))
    lunatest.assert_equal('team_manager_entry_Bob.the-builder', Model.entry_name('Bob.the-builder'))
    lunatest.assert_equal('team_manager_move_spectator', Model.move_button_name('spectator'))
    lunatest.assert_equal('team_manager_move_west', Model.move_button_name('west'))
end

function test_the_buttons_of_one_entry_are_named_apart()
    round_of(4)
    local seen = {}
    for _, destination in ipairs(Model.destinations('north')) do
        local name = Model.move_button_name(destination.force)
        lunatest.assert_nil(seen[name], name)
        seen[name] = true
    end
    lunatest.assert_equal(4, #Model.destinations('north'))
end

-- ---------------------------------------------------------------------------
-- What the model is not
-- ---------------------------------------------------------------------------

function test_a_two_team_round_draws_the_chain_and_asks_this_model_nothing()
    -- `draw_manager_gui` branches on `Teams.count() == 2` and builds the chain
    -- table there, so nothing below is what a two-team window shows. It is
    -- pinned anyway: the day a later change points the two-team window here,
    -- the columns it would get are the teams of the round and the spectators,
    -- in the order the chain has always had them minus the arrows.
    round_of(2)

    local columns = Model.columns()

    lunatest.assert_equal('north,south,spectator', forces_of(columns))
    lunatest.assert_equal('TEAM NORTH,TEAM SOUTH,SPECTATOR', captions_of(columns))
    lunatest.assert_equal('south,spectator', forces_of(Model.destinations('north')))
end

function test_every_answer_is_given_without_a_game()
    -- The module reads the round through `teams.lua` and nothing else: no
    -- `game`, no GUI, no wall clock. `game` is nil here, so a single reach for
    -- it would raise.
    round_of(4)
    game = nil

    lunatest.assert_equal(5, #Model.columns())
    lunatest.assert_equal(4, #Model.destinations('north'))
    lunatest.assert_equal('TL', Model.abbreviate('Top Left'))
    lunatest.assert_true(Model.is_available_destination('north'))
    lunatest.assert_equal('north', Model.parse_click(Model.button_tags('north', 'Bob')))
    lunatest.assert_equal('team_manager_players_north', Model.column_name('north'))
    lunatest.assert_equal('team_manager_entry_Bob', Model.entry_name('Bob'))
    lunatest.assert_equal('team_manager_move_north', Model.move_button_name('north'))
end

lunatest.run()
