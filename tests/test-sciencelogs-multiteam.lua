---@diagnostic disable
--
-- The science-log tab above two teams: `sciencelogs_model.lua`, which is
-- everything the multi-team work added to `sciencelogs_tab.lua` that is not a
-- GUI call.
--
-- The tab itself cannot be built outside Factorio, so the summary block and the
-- force filter are tested as the data they are drawn from:
--
--   * the COLUMNS of the summary block -- one per team of the round in ring
--     order, a team that is out of the round still among them, greyed;
--   * their ELEMENT NAMES, which are today's rule to the byte, the south row's
--     missing underscore included: the first row separates the index from the
--     team, the rows below it do not. The client gate does not dump this tab,
--     so this is the pin that holds those names;
--   * the ENTRIES of the force filter -- `Tables.forces_list` itself at two
--     teams, compared here against the registry rather than against a copy of
--     it, and the round's display names above two teams;
--   * reading a CHOICE back -- by position, because a display name is not a Lua
--     pattern and two teams may be given the same one.
--
-- A two-team round draws none of this: `draw_legacy_summary_rows()` in the tab
-- builds the summary block and the filter entries are the force names. The
-- two-team answers are pinned all the same, because they are what says that the
-- N-team block changed nothing but the heading it was meant to change.
--
-- `game` is nil for the whole file except in the tests that eliminate a team
-- (`Teams.eliminate` timestamps with `game.tick`), so anything in the model
-- that reached for the game state would error rather than pass.

local lunatest = require('lunatest')

storage = { ['_TEST'] = true }

local Model = require('maps.biter_battles_v2.sciencelogs_model')
local Tables = require('maps.biter_battles_v2.tables')
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

--- One field of a list of records, in order, as one comparable string.
---@param list table[]
---@param field string
---@return string
local function field_of(list, field)
    local values = {}
    for i, entry in ipairs(list) do
        values[i] = tostring(entry[field])
    end
    return table.concat(values, ',')
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
-- The columns of the summary block
-- ---------------------------------------------------------------------------

function test_four_teams_are_four_rows_in_ring_order()
    round_of(4)

    local columns = Model.columns()

    lunatest.assert_equal(4, #columns)
    lunatest.assert_equal('north,east,south,west', field_of(columns, 'team'))
    lunatest.assert_equal(
        'Total sent by Top Left,Total sent by Top Right,Total sent by Bottom Right,Total sent by Bottom Left',
        field_of(columns, 'caption')
    )
    for i = 1, 4 do
        lunatest.assert_true(columns[i].alive, columns[i].team)
    end
end

function test_three_teams_are_three_rows()
    round_of(3)

    local columns = Model.columns()

    lunatest.assert_equal(3, #columns)
    lunatest.assert_equal('north,east,south', field_of(columns, 'team'))
    lunatest.assert_equal(
        'Total sent by Top Left,Total sent by Top Right,Total sent by Bottom Right',
        field_of(columns, 'caption')
    )
end

function test_the_storage_key_is_todays_key_name()
    round_of(4)

    local columns = Model.columns()

    lunatest.assert_equal(
        'science_logs_total_north,science_logs_total_east,science_logs_total_south,science_logs_total_west',
        field_of(columns, 'key')
    )
    lunatest.assert_equal('science_logs_total_west', Model.totals_key('west'))
end

function test_the_element_names_follow_todays_rule_the_first_row_separates()
    -- The south row has never put an underscore between the
    -- team and the column index, unlike the north row above it. Today's tab is
    -- those two rows, so the rule -- not the defect's two team names -- is what
    -- the block above two teams has to keep.
    round_of(4)

    local columns = Model.columns()

    lunatest.assert_equal(
        'science_logs_total_north_header,science_logs_total_east_header,'
            .. 'science_logs_total_south_header,science_logs_total_west_header',
        field_of(columns, 'header_name')
    )
    lunatest.assert_equal(
        'science_logs_total_north_,science_logs_total_east,science_logs_total_south,science_logs_total_west',
        field_of(columns, 'cell_prefix')
    )
end

function test_two_teams_keep_todays_element_names_to_the_byte()
    -- What the tab's own `draw_legacy_summary_rows()` builds, and the whole
    -- reason the N-team block is a separate function: only the heading differs.
    round_of(2)

    local columns = Model.columns()

    lunatest.assert_equal(2, #columns)
    lunatest.assert_equal('north,south', field_of(columns, 'team'))
    lunatest.assert_equal('science_logs_total_north,science_logs_total_south', field_of(columns, 'key'))
    lunatest.assert_equal(
        'science_logs_total_north_header,science_logs_total_south_header',
        field_of(columns, 'header_name')
    )
    lunatest.assert_equal('science_logs_total_north_,science_logs_total_south', field_of(columns, 'cell_prefix'))
end

function test_a_column_carries_the_team_colour_scaled_to_the_gui_range()
    round_of(4)

    local columns = Model.columns()

    -- teams.lua's roster, in 0..255, divided by 255 as gui.lua does: a colour
    -- with every component below 1 is never read back as a 0..255 one.
    lunatest.assert_equal(rgb_of({ r = 120 / 255, g = 120 / 255, b = 255 / 255 }), rgb_of(columns[1].color))
    lunatest.assert_equal(rgb_of({ r = 80 / 255, g = 215 / 255, b = 95 / 255 }), rgb_of(columns[2].color))
    lunatest.assert_equal(rgb_of({ r = 255 / 255, g = 65 / 255, b = 65 / 255 }), rgb_of(columns[3].color))
    lunatest.assert_equal(rgb_of({ r = 255 / 255, g = 200 / 255, b = 50 / 255 }), rgb_of(columns[4].color))
end

function test_a_team_that_is_out_keeps_its_row_greyed()
    round_of(4)
    mock_game()
    Teams.eliminate('east')
    game = nil

    local columns = Model.columns()

    lunatest.assert_equal(4, #columns)
    lunatest.assert_equal('north,east,south,west', field_of(columns, 'team'))
    lunatest.assert_false(columns[2].alive)
    lunatest.assert_equal(rgb_of(Model.OUT_COLOR), rgb_of(columns[2].color))
    lunatest.assert_equal('Total sent by Top Right', columns[2].caption)
    -- Its neighbours are untouched: only the team that died is greyed.
    lunatest.assert_true(columns[1].alive)
    lunatest.assert_not_equal(rgb_of(Model.OUT_COLOR), rgb_of(columns[1].color))
end

function test_a_custom_name_is_what_the_heading_says()
    round_of(4)
    storage.tm_custom_name = { east = 'Les Verts' }

    local columns = Model.columns()

    lunatest.assert_equal('Total sent by Les Verts', columns[2].caption)
    lunatest.assert_equal('Total sent by Top Left', columns[1].caption)
    -- The custom name renames the heading, never the element name or the key.
    lunatest.assert_equal('science_logs_total_east_header', columns[2].header_name)
    lunatest.assert_equal('science_logs_total_east', columns[2].key)
end

-- ---------------------------------------------------------------------------
-- The force filter
-- ---------------------------------------------------------------------------

function test_two_teams_get_the_registrys_own_list()
    round_of(2)

    local items = Model.force_filter_items(Tables.forces_list[1])

    lunatest.assert_equal(#Tables.forces_list, #items)
    for i = 1, #Tables.forces_list do
        lunatest.assert_equal(Tables.forces_list[i], items[i], 'entry ' .. i)
    end
end

function test_above_two_teams_the_entries_are_the_names_the_round_shows()
    round_of(4)

    local items = Model.force_filter_items(Tables.forces_list[1])

    lunatest.assert_equal(5, #items)
    lunatest.assert_equal('all teams', items[1])
    lunatest.assert_equal('all teams,Top Left,Top Right,Bottom Right,Bottom Left', table.concat(items, ','))
end

function test_three_teams_get_four_entries()
    round_of(3)

    local items = Model.force_filter_items(Tables.forces_list[1])

    lunatest.assert_equal('all teams,Top Left,Top Right,Bottom Right', table.concat(items, ','))
end

function test_a_custom_name_reaches_the_filter_too()
    round_of(3)
    storage.tm_custom_name = { north = 'Les Bleus' }

    local items = Model.force_filter_items(Tables.forces_list[1])

    lunatest.assert_equal('all teams,Les Bleus,Top Right,Bottom Right', table.concat(items, ','))
end

function test_the_first_entry_is_no_filter_and_the_others_are_their_team()
    round_of(4)

    lunatest.assert_nil(Model.filtered_team(1))
    lunatest.assert_equal('north', Model.filtered_team(2))
    lunatest.assert_equal('east', Model.filtered_team(3))
    lunatest.assert_equal('south', Model.filtered_team(4))
    lunatest.assert_equal('west', Model.filtered_team(5))
end

function test_a_choice_outside_the_list_is_no_filter()
    -- A choice survives a map reset, so a round of two teams can inherit the
    -- index of a four-team round; the tab resets it, and reading it back must
    -- not error or point at a team that is not playing either way.
    round_of(2)

    lunatest.assert_nil(Model.filtered_team(4))
    lunatest.assert_nil(Model.filtered_team(0))
    lunatest.assert_nil(Model.filtered_team(-1))
    lunatest.assert_nil(Model.filtered_team(nil))
    lunatest.assert_nil(Model.filtered_team('north'))
    lunatest.assert_equal('south', Model.filtered_team(3))
end

function test_the_choice_is_read_by_position_not_by_text()
    -- Two teams under the same custom name is a filter that no text match can
    -- tell apart; the entry a player picked still says which team they meant.
    round_of(4)
    storage.tm_custom_name = { east = 'Team A', west = 'Team A' }

    local items = Model.force_filter_items(Tables.forces_list[1])

    lunatest.assert_equal('Team A', items[3])
    lunatest.assert_equal('Team A', items[5])
    lunatest.assert_equal('east', Model.filtered_team(3))
    lunatest.assert_equal('west', Model.filtered_team(5))
end

-- ---------------------------------------------------------------------------
-- Purity
-- ---------------------------------------------------------------------------

function test_every_answer_is_given_without_a_game()
    -- The module reads the round through `teams.lua` and nothing else: no
    -- `game`, no science-log array, no GUI. `game` is nil here, so a single
    -- reach for it would raise.
    round_of(4)
    game = nil

    lunatest.assert_equal(4, #Model.columns())
    lunatest.assert_equal(5, #Model.force_filter_items('all teams'))
    lunatest.assert_equal('south', Model.filtered_team(4))
    lunatest.assert_equal('science_logs_total_north', Model.totals_key('north'))
end

lunatest.run()
