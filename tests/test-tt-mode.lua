---@diagnostic disable
--
-- Pins `maps/biter_battles_v2/tt_mode_model.lua`, the pure half of Triple
-- Threat once the mode plays with three and four teams.
--
-- `tt_mode.lua` itself cannot be loaded here -- it calls `commands.add_command`
-- at load -- so the answers that are arithmetic or strings live in the model
-- module and are pinned here. What this suite is here to catch:
--
--   * the TWO-TEAM answers, which must stay today's to the character: the power
--     kit six tiles east and six tiles outward of the silo, {6,-6} for north
--     and {6,6} for south (the literals `tt_mode.lua` carried), and the
--     `/tt-status` line with its `N=` and `S=` columns, its double spaces
--     between groups and its `%.1f%%` / `%.3f` fields;
--   * that the four-team offsets are the canonical one TURNED and nothing else
--     -- a hand-written per-team table would drift from `Layout`;
--   * the ramp, which is team-count independent: the +3%/min slope applies
--     forward from the first laser and never re-prices the minutes already
--     ramped at +5%/min (a global slope switch would make difficulty, and
--     through it both teams' evolution, DROP the instant a laser goes up);
--   * that an eliminated team is dropped from the evolution recompute above two
--     teams and that with two teams both forces are still restated.
--
-- The model requires only `layout.lua` and `teams.lua`, both pure and both
-- loadable outside Factorio. `storage` is the usual mock; the elimination test
-- installs a `game` of one field, `tick`, which is all `Teams.eliminate` reads.

local lunatest = require('lunatest')

storage = { ['_TEST'] = true }

local Model = require('maps.biter_battles_v2.tt_mode_model')
local Teams = require('maps.biter_battles_v2.teams')

--- Ask for `count` teams and start the round.
local function round_of(count)
    lunatest.assert_true(Teams.set_next_count(count), 'set_next_count(' .. tostring(count) .. ')')
    Teams.begin_round()
end

--- Both components of the kit offset at once. The message comes first so the
--- two-value call can be written last, where Lua expands it to both values.
--- `assert_equal` on numbers is a tolerance test, so the IEEE negative zero a
--- negation can produce compares equal to 0 here.
local function assert_offset(what, expected_x, expected_y, x, y)
    lunatest.assert_equal(expected_x, x, what .. ' [dx]')
    lunatest.assert_equal(expected_y, y, what .. ' [dy]')
end

-- ---------------------------------------------------------------------------
-- The power kit's position
-- ---------------------------------------------------------------------------

function test_two_teams_keep_the_hardcoded_offsets()
    round_of(2)
    local teams = Teams.all()
    assert_offset('north: +6 east, 6 north of the silo', 6, -6, Model.kit_offset(teams[1]))
    assert_offset('south: the reflection of it', 6, 6, Model.kit_offset(teams[2]))
end

function test_four_teams_turn_the_canonical_offset()
    round_of(4)
    local teams = Teams.all()
    assert_offset('north is the canonical square', 6, -6, Model.kit_offset(teams[1]))
    assert_offset('east is one quarter turn on', 6, 6, Model.kit_offset(teams[2]))
    assert_offset('south is two', -6, 6, Model.kit_offset(teams[3]))
    assert_offset('west is three', -6, -6, Model.kit_offset(teams[4]))
end

function test_three_teams_place_the_three_squares_that_play()
    round_of(3)
    local teams = Teams.all()
    lunatest.assert_equal(3, #teams)
    assert_offset('the third team is still two quarter turns on', -6, 6, Model.kit_offset(teams[3]))
    lunatest.assert_nil(Model.kit_offset('nobody'), 'a name that is not a team has no square')
end

function test_the_offset_is_the_same_distance_from_every_silo()
    round_of(4)
    for _, team in ipairs(Teams.all()) do
        local dx, dy = Model.kit_offset(team)
        lunatest.assert_equal(72, dx * dx + dy * dy, team .. ': a turn does not move the kit further out')
    end
end

-- ---------------------------------------------------------------------------
-- The difficulty ramp
-- ---------------------------------------------------------------------------

function test_the_ramp_is_flat_until_minute_sixty()
    lunatest.assert_equal(0, Model.ramp(0, nil))
    lunatest.assert_equal(0, Model.ramp(60, nil))
    lunatest.assert_equal(0, Model.ramp(59.9, 30), 'a laser before the ramp does not start it')
end

function test_the_ramp_climbs_five_percent_a_minute()
    lunatest.assert_equal(0.05 * 10, Model.ramp(70, nil))
    lunatest.assert_equal(0.05 * 40, Model.ramp(100, nil))
end

function test_a_laser_switches_the_slope_forward_only()
    -- Laser at minute 80: twenty minutes at 5%, then 3%.
    lunatest.assert_equal((80 - 60) * 0.05, Model.ramp(80, 80), 'nothing moves at the laser minute')
    lunatest.assert_equal((80 - 60) * 0.05 + 10 * 0.03, Model.ramp(90, 80))
    -- And the difficulty never drops when the laser goes up.
    lunatest.assert_true(Model.ramp(90, 80) > Model.ramp(80, 80), 'monotone across the switch')
end

function test_an_early_laser_counts_from_minute_sixty()
    lunatest.assert_equal(30 * 0.03, Model.ramp(90, 10), 'a laser before minute 60 is read as minute 60')
    lunatest.assert_equal(30 * 0.03, Model.ramp(90, 60))
end

function test_the_ramp_does_not_read_the_round()
    round_of(2)
    local two = Model.ramp(123.5, 77)
    round_of(4)
    lunatest.assert_equal(two, Model.ramp(123.5, 77), 'team-count independent, as the difficulty lock is')
end

-- ---------------------------------------------------------------------------
-- Which biter forces the evolution recompute restates
-- ---------------------------------------------------------------------------

function test_two_teams_restate_both_forces()
    round_of(2)
    local forces = Model.recompute_forces()
    lunatest.assert_equal(2, #forces)
    lunatest.assert_equal('north_biters', forces[1])
    lunatest.assert_equal('south_biters', forces[2])
end

function test_above_two_teams_an_eliminated_team_is_dropped()
    game = { tick = 1 }
    round_of(4)
    lunatest.assert_equal(4, #Model.recompute_forces())
    Teams.eliminate(Teams.all()[2])
    local forces = Model.recompute_forces()
    lunatest.assert_equal(3, #forces)
    for _, name in ipairs(forces) do
        lunatest.assert_not_equal('east_biters', name, 'a dead team is not fed and not restated')
    end
    game = nil
end

-- ---------------------------------------------------------------------------
-- /tt-status
-- ---------------------------------------------------------------------------

local function status_of(raw, bonus, eei)
    return Model.status_line(Teams.all(), 'ON', 0.8, 'NO', function(team)
        return raw[team] or 0
    end, function(team)
        return bonus[team]
    end, function(team)
        return eei[team] or 'inert'
    end)
end

function test_the_two_team_status_line_is_the_one_it_always_printed()
    round_of(2)
    lunatest.assert_equal(
        '[TT] mode=ON  diff=80.0%  laser_placed=NO  raw_mutagen N=1.500 S=0.000'
            .. '  power_bonus N=true S=false  eei N=50MW S=inert',
        status_of({ north = 1.5 }, { north = true }, { north = '50MW' })
    )
end

function test_four_teams_get_four_columns_in_ring_order()
    round_of(4)
    lunatest.assert_equal(
        '[TT] mode=ON  diff=80.0%  laser_placed=NO  raw_mutagen N=0.000 E=2.250 S=0.000 W=0.000'
            .. '  power_bonus N=false E=false S=false W=false  eei N=inert E=inert S=inert W=inert',
        status_of({ east = 2.25 }, {}, {})
    )
end

function test_the_column_letter_is_the_initial_of_the_force()
    lunatest.assert_equal('N', Model.column('north'))
    lunatest.assert_equal('S', Model.column('south'))
    lunatest.assert_equal('E', Model.column('east'))
    lunatest.assert_equal('W', Model.column('west'))
end

-- ---------------------------------------------------------------------------
-- The League's settings (`bb_settings` on the League server)
-- ---------------------------------------------------------------------------

-- `storage.bb_settings` as init.lua ships it (init.lua `initial_setup`), key
-- for key: what a fresh scenario -- every League restart -- holds before the
-- daemon's `/tt-enable`.
local function shipped_bb_settings()
    return {
        team_balancing = true,
        only_admins_vote = false,
        science_send_score_restriction = true,
        new_year_island = false,
        bb_map_reveal_toggle = true,
        automatic_captain = true,
        map_reroll = true,
        burners_balance = true,
        classic_pathfinding = true,
        daytime_cycle = 'always_day',
    }
end

---The text of a scenario file, read from the repository root (where the suites
---run).
---@param path string
---@return string
local function source_of(path)
    local handle = io.open(path, 'r')
    lunatest.assert_true(handle ~= nil, 'cannot read ' .. path)
    local text = handle:read('*a')
    handle:close()
    return text
end

function test_init_still_ships_the_classic_settings()
    -- BB main and BB Captains load the same scenario and never send
    -- `/tt-enable`, so what init.lua writes is what they play: read off the
    -- source, key for key, automatic captain still on.
    local text = source_of('maps/biter_battles_v2/init.lua')
    local block = text:match('storage%.bb_settings = (%b{})')
    lunatest.assert_not_nil(block, 'no storage.bb_settings table in init.lua')
    local shipped = {}
    local count = 0
    for name, value in block:gmatch("%['([%w_]+)'%]%s*=%s*([^,\n]+),") do
        if value == 'true' or value == 'false' then
            shipped[name] = value == 'true'
        else
            shipped[name] = value:match("^'(.*)'$") or value
        end
        count = count + 1
    end
    local expected = shipped_bb_settings()
    for name, value in pairs(expected) do
        lunatest.assert_equal(value, shipped[name], name)
    end
    lunatest.assert_equal(10, count)
    lunatest.assert_true(shipped.automatic_captain)
end

function test_only_tt_enable_applies_the_league_settings()
    -- The one writer of the League's settings is the `/tt-enable` handler, on
    -- the off -> on transition: a server that never sends the command (BB main,
    -- BB Captains) never has them applied.
    local pipe = io.popen("find . -name '*.lua' -not -path './tests/*' 2>/dev/null")
    lunatest.assert_not_nil(pipe)
    local calls = {}
    local scanned = 0
    for path in pipe:lines() do
        scanned = scanned + 1
        -- Every call, whatever the module is bound to; the definition is not one.
        local text = source_of(path):gsub('function Public%.apply_league_settings%(', '')
        for _ in text:gmatch('%.apply_league_settings%(') do
            calls[#calls + 1] = path
        end
    end
    pipe:close()
    lunatest.assert_true(scanned > 100, 'the source scan read ' .. scanned .. ' files')
    lunatest.assert_equal('./maps/biter_battles_v2/tt_mode.lua', table.concat(calls, ','))
    local text = source_of('maps/biter_battles_v2/tt_mode.lua')
    local enable = text:find("commands.add_command('tt-enable'", 1, true)
    local disable = text:find("commands.add_command('tt-disable'", 1, true)
    local gate = text:find('if was_off then', 1, true)
    local call = text:find('Model.apply_league_settings(', 1, true)
    lunatest.assert_true(enable ~= nil and disable ~= nil and gate ~= nil and call ~= nil)
    lunatest.assert_true(enable < gate and gate < call and call < disable)
end

function test_the_league_settings_are_exactly_automatic_captain_off()
    -- The live League server's `bb_settings` (dumped 2026-09-27) differed from
    -- the shipped table in one value: automatic captain off. A schema pin, so a
    -- second League setting is a deliberate addition here and in the dump.
    local names = {}
    for name in pairs(Model.league_bb_settings) do
        names[#names + 1] = name
    end
    lunatest.assert_equal('automatic_captain', table.concat(names, ','))
    lunatest.assert_false(Model.league_bb_settings.automatic_captain)
end

function test_a_fresh_scenario_gets_the_league_settings_and_nothing_else_moves()
    local settings = shipped_bb_settings()
    local moved = Model.apply_league_settings(settings)
    lunatest.assert_equal(1, #moved)
    lunatest.assert_equal('automatic_captain = false', moved[1])
    lunatest.assert_false(settings.automatic_captain)
    -- The nine other settings are what init.lua shipped, key for key.
    local expected = shipped_bb_settings()
    expected.automatic_captain = false
    local count = 0
    for name, value in pairs(expected) do
        lunatest.assert_equal(value, settings[name], name)
        count = count + 1
    end
    for name in pairs(settings) do
        lunatest.assert_not_nil(expected[name], 'unexpected setting ' .. name)
    end
    lunatest.assert_equal(10, count)
end

function test_the_league_settings_already_in_force_report_nothing()
    -- What the live server held, handed in as is: nothing moves and nothing
    -- is announced -- the shipped League table IS the live one.
    local settings = shipped_bb_settings()
    settings.automatic_captain = false
    local moved = Model.apply_league_settings(settings)
    lunatest.assert_equal(0, #moved)
    lunatest.assert_false(settings.automatic_captain)
end

function test_a_settings_table_that_predates_a_league_setting_gains_it()
    local settings = { team_balancing = true }
    local moved = Model.apply_league_settings(settings)
    lunatest.assert_equal('automatic_captain = false', table.concat(moved, ','))
    lunatest.assert_false(settings.automatic_captain)
    lunatest.assert_true(settings.team_balancing)
end

function test_no_settings_table_is_left_alone()
    lunatest.assert_equal(0, #Model.apply_league_settings(nil))
    lunatest.assert_equal(0, #Model.apply_league_settings('bb_settings'))
end

-- ---------------------------------------------------------------------------
-- The chat lines: the mode's name and the laser bonus
-- ---------------------------------------------------------------------------

function test_the_mode_keeps_its_name_at_two_teams_and_drops_the_format_above()
    lunatest.assert_equal('Triple Threat (3v3)', Model.mode_label(2))
    lunatest.assert_equal('Triple Threat', Model.mode_label(3))
    lunatest.assert_equal('Triple Threat', Model.mode_label(4))
    -- The /tt-enable announcement at two teams, character for character.
    lunatest.assert_equal(
        '>> [TT] Triple Threat (3v3) mode ENABLED. Custom 80% difficulty, vote locked, e-miner unlocked, steam-power kit on team-join.',
        '>> [TT] '
            .. Model.mode_label(2)
            .. ' mode ENABLED. Custom 80% difficulty, vote locked, e-miner unlocked, steam-power kit on team-join.'
    )
end

function test_the_laser_bonus_line_names_the_force_at_two_teams_and_the_title_above()
    lunatest.assert_equal(
        '>> [TT] north team built first laser-turret — +50 MW bonus power live at the pre-placed power interface next to your silo.',
        Model.laser_bonus_line('north', 2, 'Team North')
    )
    lunatest.assert_equal(
        '>> [TT] Top Right team built first laser-turret — +50 MW bonus power live at the pre-placed power interface next to your silo.',
        Model.laser_bonus_line('east', 3, 'Top Right')
    )
    round_of(4)
    lunatest.assert_equal(
        '>> [TT] Bottom Left team built first laser-turret — +50 MW bonus power live at the pre-placed power interface next to your silo.',
        Model.laser_bonus_line('west', Teams.count(), Teams.display_name('west'))
    )
    -- No title given: the force name, whatever the count.
    lunatest.assert_equal(
        '>> [TT] east team built first laser-turret — +50 MW bonus power live at the pre-placed power interface next to your silo.',
        Model.laser_bonus_line('east', 4, nil)
    )
end

lunatest.run()
