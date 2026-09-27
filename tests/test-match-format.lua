---@diagnostic disable
--
-- Pins `maps/biter_battles_v2/match_format.lua` and the format key space of
-- `maps/biter_battles_v2/feeding_params.lua`.
--
-- Both modules were written to load outside Factorio: they read `storage`
-- through `type(store) ~= 'table'` guards and call nothing on `game`, so the
-- usual `storage = { _TEST = true }` mock is the whole harness. Every test
-- rebuilds `storage` in `setup()` because lunatest walks the test table with
-- `pairs`, so the order is not fixed.
--
-- What is pinned and why it matters to the N-team work:
--
--   * the format grammar takes the team sizes joined by 'v' and requires them
--     all to be equal. Every two-part format reads exactly as it always did --
--     that is the whole of the v1 record and it is pinned below, unchanged.
--     What a format naming three or four teams means changed once, with
--     match record version 2: it used to be silently
--     the 'default' set and is now read, and
--     `test_a_three_team_format_string_is_read_and_plays_the_two_part_set`
--     carries the old expectation in a comment so the change stays visible.
--     The N > 2 answers live in tests/test-match-format-multiteam.lua;
--   * `Public.format_keys` is a save schema — `storage.feeding_params` is keyed
--     by it, so renaming or reordering a key orphans the league's tuning;
--   * `describe()` multiplies the wave interval by a literal 2, and that 2 is
--     the team count (match_format.lua:162);
--   * `refresh_threat_income()` walks a two-element literal list of biter
--     forces (match_format.lua:23).

local lunatest = require('lunatest')

storage = { ['_TEST'] = true }

local MatchFormat = require('maps.biter_battles_v2.match_format')
local FeedingParams = require('maps.biter_battles_v2.feeding_params')

local TICKS_PER_MINUTE = 3600

-- main.lua:550-560 + :568-570: the nine tick offsets inside a 3600-tick minute
-- that make up one main attack cycle (setup, seven waves, teardown). These are
-- the only ticks `skip_attack_cycle` is ever consulted about (main.lua:606).
local ATTACK_CYCLE_OFFSETS = {}
for wave = 0, 8 do
    ATTACK_CYCLE_OFFSETS[#ATTACK_CYCLE_OFFSETS + 1] = 300 * 3 + 30 * wave
end

function setup()
    storage = { ['_TEST'] = true }
end

-- ---------------------------------------------------------------------------
-- Which format is in force
-- ---------------------------------------------------------------------------

function test_no_league_record_plays_the_default_set()
    lunatest.assert_nil(MatchFormat.team_size())
    lunatest.assert_equal('default', MatchFormat.format_key())
    lunatest.assert_equal(FeedingParams.BASE_KEY, MatchFormat.format_key())
end

function test_a_record_that_is_not_a_table_plays_the_default_set()
    storage.bb_league_match = 'nonsense'
    lunatest.assert_nil(MatchFormat.team_size())
    lunatest.assert_equal('default', MatchFormat.format_key())

    storage.bb_league_match = { id = 'L17' } -- no format field at all
    lunatest.assert_nil(MatchFormat.team_size())
    lunatest.assert_equal('default', MatchFormat.format_key())
end

function test_symmetric_formats_from_one_to_eight_are_played()
    for size = 1, 8 do
        local format = string.format('%dv%d', size, size)
        storage.bb_league_match = { id = 'L17', format = format }
        lunatest.assert_equal(size, MatchFormat.team_size(), format)
        lunatest.assert_equal(format, MatchFormat.format_key(), format)
        -- The parser and the key space have to agree: format_keys[1] is
        -- 'default', so a team size of n is the (n + 1)th key.
        lunatest.assert_equal(FeedingParams.format_keys[size + 1], MatchFormat.format_key(), format)
    end
end

function test_the_format_string_is_lowercased_and_stripped_of_whitespace()
    storage.bb_league_match = { id = 'L17', format = ' 3V3 ' }
    lunatest.assert_equal(3, MatchFormat.team_size())
    lunatest.assert_equal('3v3', MatchFormat.format_key())

    -- Surprising, pinned as found: `%s` is stripped everywhere, not only at the
    -- ends, so an inner space is accepted too.
    storage.bb_league_match = { id = 'L17', format = '3 v 3' }
    lunatest.assert_equal(3, MatchFormat.team_size())
    lunatest.assert_equal('3v3', MatchFormat.format_key())
end

function test_unreadable_formats_fall_back_to_the_default_set_without_a_word()
    local unreadable = {
        '2v3', -- asymmetric
        '0v0', -- the league's "no roster yet"
        '9v9', -- above MAX_TEAM_SIZE
        '', -- empty
        'north v south',
        '03v3', -- surprising: zero padding fails the left == right test
        123, -- not a string
        {}, -- not a string
    }
    for _, format in ipairs(unreadable) do
        storage.bb_league_match = { id = 'L17', format = format }
        local label = type(format) == 'table' and '{}' or tostring(format)
        lunatest.assert_nil(MatchFormat.team_size(), label)
        lunatest.assert_equal('default', MatchFormat.format_key(), label)
    end
end

function test_a_three_team_format_string_is_read_and_plays_the_two_part_set()
    -- THE ONE EXPECTATION RECORD VERSION 2 CHANGED, AND IT CHANGED IT ON PURPOSE.
    --
    -- Until then the grammar was two sides only, so a league record announcing
    -- three teams read as "a format this scenario does not play" and the game
    -- went on with the 'default' parameter set, saying nothing in the log. That
    -- expectation was:
    --
    --     lunatest.assert_nil(MatchFormat.team_size())
    --     lunatest.assert_equal('default', MatchFormat.format_key())
    --
    -- It is kept here rather than deleted, because it is the behaviour every
    -- league record written before version 2 was read with.
    --
    -- What is NOT allowed to change is the parameter key: two parts whatever
    -- the team count, because `storage.feeding_params` is keyed by it and the
    -- league's tuning overrides live there. A '2v2v2' match plays the '2v2'
    -- set.
    storage.bb_league_match = { id = 'L17', format = '2v2v2' }
    lunatest.assert_equal(2, MatchFormat.team_size())
    lunatest.assert_equal(3, MatchFormat.team_count())
    lunatest.assert_equal('2v2', MatchFormat.format_key())
    lunatest.assert_true(FeedingParams.is_format_key(MatchFormat.format_key()))
end

-- ---------------------------------------------------------------------------
-- The wave cadence
-- ---------------------------------------------------------------------------

function test_the_attack_interval_is_one_minute_in_every_format()
    lunatest.assert_equal(TICKS_PER_MINUTE, MatchFormat.attack_interval_ticks(), 'no league record')
    for _, format_key in ipairs(FeedingParams.format_keys) do
        storage.bb_league_match = { id = 'L17', format = format_key }
        lunatest.assert_equal(TICKS_PER_MINUTE, MatchFormat.attack_interval_ticks(), format_key)
    end
end

function test_the_attack_interval_is_read_without_rebuilding_the_parameter_set()
    -- Above two teams the attack clock asks for this integer 120
    -- times a minute, so `attack_interval_ticks()` reads the one field instead
    -- of allocating and clamping the whole set. The number may not move by one
    -- tick doing it -- a different interval is a different game, and the
    -- two-team dispatcher reads it through `skip_attack_cycle` as well. Every
    -- format key, and every way an override can be right or wrong, must give
    -- the same answer as `get()` does.
    local overrides = {
        TICKS_PER_MINUTE,
        7 * TICKS_PER_MINUTE,
        60 * TICKS_PER_MINUTE,
        600 * TICKS_PER_MINUTE, -- above the ceiling: clamped down
        30, -- below the floor: clamped up
        -1,
        5400, -- not a whole minute: floored to one
        0.5,
        'one minute', -- the wrong type: ignored, the shipped value stands
        true,
        {},
    }

    local function assert_same(format_key, what)
        lunatest.assert_equal(
            FeedingParams.get(format_key).attack_interval,
            FeedingParams.attack_interval(format_key),
            what
        )
        -- ... and through the entry point the dispatcher actually calls.
        storage.bb_league_match = { id = 'L17', format = format_key }
        lunatest.assert_equal(
            FeedingParams.get().attack_interval,
            MatchFormat.attack_interval_ticks(),
            what .. ' (in force)'
        )
    end

    for _, format_key in ipairs(FeedingParams.format_keys) do
        -- Nothing overridden -- the shipped value. A nil cannot sit in a Lua
        -- array, so it is its own pass.
        storage.feeding_params = nil
        assert_same(format_key, format_key .. ' / shipped')

        for _, override in ipairs(overrides) do
            storage.feeding_params = { [format_key] = { attack_interval = override } }
            assert_same(format_key, format_key .. ' / ' .. tostring(override))
        end
    end
end

function test_no_attack_cycle_tick_is_skipped_at_the_default_interval()
    -- At the 3600-tick floor `tick % interval` can never reach a minute, so
    -- every one of the nine cycle ticks runs, every minute, for ever.
    for minute = 0, 179 do
        for _, offset in ipairs(ATTACK_CYCLE_OFFSETS) do
            local tick = minute * TICKS_PER_MINUTE + offset
            lunatest.assert_false(MatchFormat.skip_attack_cycle(tick), 'tick ' .. tick)
        end
    end
    lunatest.assert_false(MatchFormat.skip_attack_cycle(0))
end

function test_a_widened_interval_runs_the_cycle_in_its_first_minute_only()
    -- The only way the interval moves today is an admin override, and it is
    -- pinned here because the attack clock phase-shifts the cadence per
    -- team: the bucketing rule (whole cycle skipped or whole cycle run) is what
    -- keeps setup, the seven waves and teardown agreeing with each other.
    storage.feeding_params = { ['default'] = { attack_interval = 2 * TICKS_PER_MINUTE } }
    lunatest.assert_equal(2 * TICKS_PER_MINUTE, MatchFormat.attack_interval_ticks())

    for minute = 0, 9 do
        local skipped = minute % 2 == 1
        for _, offset in ipairs(ATTACK_CYCLE_OFFSETS) do
            local tick = minute * TICKS_PER_MINUTE + offset
            lunatest.assert_equal(skipped, MatchFormat.skip_attack_cycle(tick), 'tick ' .. tick)
        end
    end
end

-- ---------------------------------------------------------------------------
-- What the format reports about itself
-- ---------------------------------------------------------------------------

function test_describe_without_a_league_record()
    lunatest.assert_equal('no league match — default set', MatchFormat.describe())
end

function test_describe_names_the_format_and_the_match_id()
    storage.bb_league_match = { id = 'L17', format = '2v2' }
    lunatest.assert_equal(
        '2v2 [league match L17] — passive income x1, wave every 3600 ticks (1 min, each side every 2 min)',
        MatchFormat.describe()
    )

    -- 1v1 is the one format the scenario ships a deviation for.
    storage.bb_league_match = { id = 'L17', format = '1v1' }
    lunatest.assert_equal(
        '1v1 [league match L17] — passive income x0.5, wave every 3600 ticks (1 min, each side every 2 min)',
        MatchFormat.describe()
    )
end

function test_describe_quotes_an_unplayable_format_with_its_match_id()
    storage.bb_league_match = { id = 'L17', format = '2v3' }
    lunatest.assert_equal(
        'league match L17 reports "2v3", which this scenario does not play — default set',
        MatchFormat.describe()
    )

    -- A record with no id still reports, with '?' standing in.
    storage.bb_league_match = { format = '2v3' }
    lunatest.assert_equal(
        'league match ? reports "2v3", which this scenario does not play — default set',
        MatchFormat.describe()
    )
end

function test_describe_multiplies_the_interval_by_the_hard_coded_team_count()
    -- "each side every N min" is `interval * 2 / 3600` (match_format.lua:162),
    -- and that 2 is the number of teams: the global wave alternates sides, so
    -- with two teams a side's turn comes round every second interval. With
    -- three or four teams the same sentence would be wrong. Widening the
    -- interval makes the multiplication visible in the text.
    storage.bb_league_match = { id = 'L17', format = '2v2' }
    storage.feeding_params = { ['2v2'] = { attack_interval = 2 * TICKS_PER_MINUTE } }
    lunatest.assert_equal(
        '2v2 [league match L17] — passive income x1, wave every 7200 ticks (2 min, each side every 4 min)',
        MatchFormat.describe()
    )
end

-- ---------------------------------------------------------------------------
-- The parameter key space
-- ---------------------------------------------------------------------------

function test_format_keys_are_exactly_default_plus_1v1_through_8v8_in_order()
    -- A save schema: `storage.feeding_params` is keyed by these strings, so a
    -- rename or a reorder silently orphans every tuning override the league has
    -- stored.
    local expected = { 'default', '1v1', '2v2', '3v3', '4v4', '5v5', '6v6', '7v7', '8v8' }
    lunatest.assert_len(#expected, FeedingParams.format_keys)
    lunatest.assert_equal(9, #FeedingParams.format_keys)
    for index, key in ipairs(expected) do
        lunatest.assert_equal(key, FeedingParams.format_keys[index], 'key ' .. index)
    end
    lunatest.assert_equal('default', FeedingParams.BASE_KEY)
end

function test_is_format_key_accepts_exactly_the_key_space()
    for _, key in ipairs(FeedingParams.format_keys) do
        lunatest.assert_true(FeedingParams.is_format_key(key), key)
        lunatest.assert_true(FeedingParams.is_format_key(string.upper(key)), string.upper(key))
    end
    for _, key in ipairs({ '2v3', '0v0', '9v9', '2v2v2', 'north', '' }) do
        lunatest.assert_false(FeedingParams.is_format_key(key), key)
    end
end

-- ---------------------------------------------------------------------------
-- The BB League server plays its own base (c 260, k 0.9) and its own 1v1 set
-- (c 500, k 0.75, a wave every 7200 ticks -- what its admins had tuned live
-- and lost at every restart, dumped 2026-09-27 and shipped). Every other
-- server that loads this scenario -- BB Captains shares its directory -- plays
-- the classic base (c 200, k 1) with 1v1 at its shipped k = 0.5.
-- ---------------------------------------------------------------------------

local function c_and_k(format_key)
    local params = FeedingParams.get(format_key)
    return params.instant_scale, params.passive_income_scale
end

-- The whole set the classic servers play, per format: the shipped base with
-- 1v1's half income on top. Every other field is the same number everywhere.
-- Written out rather than copied from `FeedingParams.defaults`, so BB main and
-- BB Captains are held to the numbers they played before the League's own were
-- shipped, not to whatever the table says today.
local CLASSIC_BASE = {
    evo_mutagen_at_100 = 277,
    evo_power = 0.3,
    evo_stop_scaling_at_100 = true,
    passive_scale = 100,
    passive_power = 2.5,
    passive_linear = 15,
    instant_scale = 200,
    passive_income_scale = 1,
    attack_interval = 3600,
}

local function classic_set(format_key)
    local set = {}
    for field, value in pairs(CLASSIC_BASE) do
        set[field] = value
    end
    if format_key == '1v1' then
        set.passive_income_scale = 0.5
    end
    return set
end

-- The whole set the League plays, per format: the League base, and for 1v1
-- the live tuning of 2026-09-27 -- the numbers `storage.feeding_params['1v1']`
-- held on the League server (instant_scale 500, passive_income_scale 0.75,
-- attack_interval 7200) and nothing else.
local function league_set(format_key)
    local set = classic_set(format_key)
    set.instant_scale = 260
    set.passive_income_scale = 0.9
    if format_key == '1v1' then
        set.instant_scale = 500
        set.passive_income_scale = 0.75
        set.attack_interval = 7200
    end
    return set
end

local function assert_set(expected, actual, label)
    local seen = 0
    for field, value in pairs(expected) do
        lunatest.assert_equal(value, actual[field], label .. '.' .. field)
        seen = seen + 1
    end
    for field in pairs(actual) do
        lunatest.assert_not_nil(expected[field], label .. ' carries an unexpected field ' .. field)
    end
    lunatest.assert_equal(9, seen, label .. ' field count')
end

function test_off_the_league_every_format_plays_the_classic_base()
    -- Never enabled (nil), and turned off by /tt-disable (false).
    for _, tt_mode in ipairs({ 'never', false }) do
        if tt_mode == 'never' then
            storage.tt_mode = nil
        else
            storage.tt_mode = tt_mode
        end
        lunatest.assert_false(FeedingParams.is_league(), tostring(tt_mode))
        for _, format_key in ipairs(FeedingParams.format_keys) do
            local c, k = c_and_k(format_key)
            lunatest.assert_equal(200, c, format_key)
            lunatest.assert_equal(format_key == '1v1' and 0.5 or 1, k, format_key)
            lunatest.assert_equal(200, FeedingParams.inherited_for('instant_scale', format_key), format_key)
            lunatest.assert_equal(200, FeedingParams.default_for('instant_scale', format_key), format_key)
            lunatest.assert_equal(3600, FeedingParams.attack_interval(format_key), format_key)
        end
    end
    -- The shipped table itself is the classic base.
    lunatest.assert_equal(200, FeedingParams.defaults.instant_scale)
    lunatest.assert_equal(1, FeedingParams.defaults.passive_income_scale)
    lunatest.assert_equal(3600, FeedingParams.defaults.attack_interval)
end

function test_off_the_league_the_whole_set_is_the_classic_one_in_every_format()
    -- BB main and BB Captains: a fresh scenario, Triple Threat never sent,
    -- plays exactly what it played before the League's numbers were shipped --
    -- the classic base in every format, 1v1 at half income, the wave every
    -- minute. Field by field, so a League number leaking into a classic set
    -- is caught whichever field it lands on.
    storage.tt_mode = nil
    for _, format_key in ipairs(FeedingParams.format_keys) do
        assert_set(classic_set(format_key), FeedingParams.get(format_key), 'classic ' .. format_key)
    end
    lunatest.assert_nil(storage.feeding_params)
end

function test_off_the_league_1v1_still_halves_the_passive_income()
    -- The shipped 1v1 rule, unchanged by the League's own 1v1 set: k = 0.5
    -- over the classic curve, c = 200, one wave a minute.
    storage.tt_mode = nil
    local params = FeedingParams.get('1v1')
    lunatest.assert_equal(0.5, params.passive_income_scale)
    lunatest.assert_equal(200, params.instant_scale)
    lunatest.assert_equal(3600, params.attack_interval)
    -- (100 + 15) · 0.5 at 100% evolution.
    lunatest.assert_equal(57.5, FeedingParams.passive_threat(1.0, params))
    lunatest.assert_equal(0.5, FeedingParams.format_default('passive_income_scale', '1v1'))
    lunatest.assert_nil(FeedingParams.format_default('instant_scale', '1v1'))
    lunatest.assert_nil(FeedingParams.format_default('attack_interval', '1v1'))
    -- The League's 1v1 table is not read off the League.
    storage.tt_mode = false
    lunatest.assert_equal(0.5, FeedingParams.format_default('passive_income_scale', '1v1'))
    lunatest.assert_nil(FeedingParams.format_default('instant_scale', '1v1'))
end

function test_on_the_league_every_format_plays_the_league_base_and_1v1_its_own_set()
    storage.tt_mode = true
    lunatest.assert_true(FeedingParams.is_league())
    for _, format_key in ipairs(FeedingParams.format_keys) do
        local c, k = c_and_k(format_key)
        local one = format_key == '1v1'
        lunatest.assert_equal(one and 500 or 260, c, format_key)
        lunatest.assert_equal(one and 0.75 or 0.9, k, format_key)
        lunatest.assert_equal(one and 7200 or 3600, FeedingParams.attack_interval(format_key), format_key)
        lunatest.assert_equal(one and 500 or 260, FeedingParams.inherited_for('instant_scale', format_key), format_key)
        lunatest.assert_equal(one and 500 or 260, FeedingParams.default_for('instant_scale', format_key), format_key)
        lunatest.assert_false(FeedingParams.is_inherited('instant_scale', format_key), format_key)
    end
    -- Only c and k move: every other field is the shipped one.
    local league, classic = FeedingParams.get('3v3'), nil
    storage.tt_mode = nil
    classic = FeedingParams.get('3v3')
    for field, value in pairs(classic) do
        if field ~= 'instant_scale' and field ~= 'passive_income_scale' then
            lunatest.assert_equal(value, league[field], field)
        end
    end
end

function test_a_fresh_league_scenario_plays_exactly_the_live_values_of_2026_09_27()
    -- The defect this pins shut: the League starts a fresh scenario at every
    -- restart, and what its admins had tuned into `storage.feeding_params`
    -- (1v1: c 500, k 0.75, interval 7200 -- the whole of the live overrides,
    -- dumped 2026-09-27) went with it. A fresh League init -- Triple Threat on,
    -- nothing written to `storage.feeding_params` -- now plays those numbers
    -- with no admin write at all, and the other formats the League base.
    storage.tt_mode = true
    lunatest.assert_nil(storage.feeding_params)
    for _, format_key in ipairs(FeedingParams.format_keys) do
        assert_set(league_set(format_key), FeedingParams.get(format_key), 'league ' .. format_key)
    end
    -- To the number: what the live 1v1 set held, and nothing else moved.
    local live = FeedingParams.get('1v1')
    lunatest.assert_equal(500, live.instant_scale)
    lunatest.assert_equal(0.75, live.passive_income_scale)
    lunatest.assert_equal(7200, live.attack_interval)
    lunatest.assert_equal(277, live.evo_mutagen_at_100)
    lunatest.assert_equal(0.3, live.evo_power)
    lunatest.assert_true(live.evo_stop_scaling_at_100)
    lunatest.assert_equal(100, live.passive_scale)
    lunatest.assert_equal(2.5, live.passive_power)
    lunatest.assert_equal(15, live.passive_linear)
    -- Reading them wrote nothing: they are shipped, not overrides.
    lunatest.assert_nil(storage.feeding_params)
    for _, field in ipairs(FeedingParams.order) do
        lunatest.assert_false(FeedingParams.is_overridden(field, '1v1'), field)
    end
    -- And the 1v1 record the League writes plays that set.
    storage.bb_league_match = { id = 'L17', format = '1v1' }
    lunatest.assert_equal('1v1', MatchFormat.format_key())
    lunatest.assert_equal(7200, MatchFormat.attack_interval_ticks())
    assert_set(league_set('1v1'), FeedingParams.get(), 'league in force')
end

function test_the_league_1v1_deviation_is_exactly_c_k_and_the_interval()
    -- A schema pin on the shipped table: one format, three fields. A fourth
    -- field or a second format here is a deliberate change, not a drift.
    local formats = {}
    for format_key, fields in pairs(FeedingParams.league_format_defaults) do
        formats[#formats + 1] = format_key
        local names = {}
        for field in pairs(fields) do
            names[#names + 1] = field
        end
        table.sort(names)
        lunatest.assert_equal(
            'attack_interval,instant_scale,passive_income_scale',
            table.concat(names, ','),
            format_key
        )
    end
    lunatest.assert_equal('1v1', table.concat(formats, ','))
    lunatest.assert_equal(500, FeedingParams.league_format_defaults['1v1'].instant_scale)
    lunatest.assert_equal(0.75, FeedingParams.league_format_defaults['1v1'].passive_income_scale)
    lunatest.assert_equal(7200, FeedingParams.league_format_defaults['1v1'].attack_interval)
    -- The League's 1v1 table is read only on the League.
    storage.tt_mode = true
    lunatest.assert_equal(500, FeedingParams.format_default('instant_scale', '1v1'))
    lunatest.assert_equal(0.75, FeedingParams.format_default('passive_income_scale', '1v1'))
    lunatest.assert_equal(7200, FeedingParams.format_default('attack_interval', '1v1'))
    -- ... and names nothing for the other formats, which follow the base.
    lunatest.assert_nil(FeedingParams.format_default('instant_scale', '2v2'))
    lunatest.assert_nil(FeedingParams.format_default('passive_income_scale', '3v3'))
    lunatest.assert_nil(FeedingParams.format_default('attack_interval', 'default'))
end

function test_only_a_true_tt_mode_is_the_league_signal()
    for _, value in ipairs({ 'true', 1, {} }) do
        storage.tt_mode = value
        lunatest.assert_false(FeedingParams.is_league(), tostring(value))
        lunatest.assert_equal(200, (c_and_k('default')))
        lunatest.assert_equal(200, (c_and_k('1v1')))
    end
    -- A league match record alone is not the signal: the League turns
    -- Triple Threat on at T-15, before any record is written.
    storage.tt_mode = nil
    storage.bb_league_match = { id = 'L17', format = '3v3' }
    lunatest.assert_false(FeedingParams.is_league())
    lunatest.assert_equal(200, (c_and_k()))
    storage.bb_league_match = { id = 'L17', format = '1v1' }
    lunatest.assert_equal(200, (c_and_k()))
    lunatest.assert_equal(3600, MatchFormat.attack_interval_ticks())
end

function test_on_the_league_admin_overrides_still_win()
    storage.tt_mode = true
    storage.feeding_params = {
        ['3v3'] = { instant_scale = 250 },
        ['default'] = { passive_income_scale = 0.8, attack_interval = 10800 },
    }
    local c, k = c_and_k('3v3')
    lunatest.assert_equal(250, c)
    lunatest.assert_equal(0.8, k)
    lunatest.assert_equal(10800, FeedingParams.attack_interval('3v3'))
    lunatest.assert_true(FeedingParams.is_inherited('passive_income_scale', '3v3'))
    lunatest.assert_true(FeedingParams.is_inherited('attack_interval', '3v3'))
    -- The retuned base does not reach the fields the League's 1v1 claims.
    c, k = c_and_k('1v1')
    lunatest.assert_equal(500, c)
    lunatest.assert_equal(0.75, k)
    lunatest.assert_equal(7200, FeedingParams.attack_interval('1v1'))
    lunatest.assert_false(FeedingParams.is_inherited('passive_income_scale', '1v1'))
    lunatest.assert_false(FeedingParams.is_inherited('attack_interval', '1v1'))
    -- ... but does reach the ones it does not: b is the base's everywhere.
    storage.feeding_params['default'].passive_linear = 12
    lunatest.assert_equal(12, FeedingParams.get('1v1').passive_linear)
    lunatest.assert_true(FeedingParams.is_inherited('passive_linear', '1v1'))

    -- Clearing returns to the League base, not to the classic one.
    lunatest.assert_equal(260, FeedingParams.clear('c', '3v3'))
    lunatest.assert_nil(storage.feeding_params['3v3'])
    lunatest.assert_equal(0.9, FeedingParams.clear('k', 'default'))
    lunatest.assert_equal(0.9, FeedingParams.get('3v3').passive_income_scale)
end

function test_on_the_league_1v1_is_still_tunable_and_clears_back_to_its_league_set()
    -- The runtime tools keep working over the shipped numbers: an admin can
    -- move the League's 1v1 further, and a clear lands on the League's 1v1
    -- set -- the number the report quotes as "[... if cleared]" -- not on the
    -- League base and not on the classic half.
    storage.tt_mode = true
    lunatest.assert_equal(700, FeedingParams.set('c', '700', '1v1'))
    lunatest.assert_equal(0.6, FeedingParams.set('k', '0.6', '1v1'))
    lunatest.assert_equal(10800, FeedingParams.set('interval', '10800', '1v1'))
    lunatest.assert_equal(700, FeedingParams.get('1v1').instant_scale)
    lunatest.assert_true(FeedingParams.is_overridden('instant_scale', '1v1'))
    local report = FeedingParams.report(FeedingParams.get('1v1'), '1v1')
    lunatest.assert_true(report:find('instant_scale (c) = 700   [500 if cleared]', 1, true) ~= nil, report)
    lunatest.assert_true(report:find('passive_income_scale (k) = 0.6   [0.75 if cleared]', 1, true) ~= nil, report)
    lunatest.assert_true(report:find('attack_interval = 10800   [7200 if cleared]', 1, true) ~= nil, report)

    lunatest.assert_equal(500, FeedingParams.clear('c', '1v1'))
    lunatest.assert_equal(0.75, FeedingParams.set('k', 'default', '1v1'))
    lunatest.assert_equal(7200, FeedingParams.clear('interval', '1v1'))
    lunatest.assert_nil(storage.feeding_params['1v1'])
    assert_set(league_set('1v1'), FeedingParams.get('1v1'), 'league 1v1 after clears')

    -- A reset of the format lands on the same set.
    FeedingParams.set('c', '700', '1v1')
    FeedingParams.reset('1v1')
    assert_set(league_set('1v1'), FeedingParams.get('1v1'), 'league 1v1 after reset')

    -- What the live server held, written back as overrides, changes nothing:
    -- the shipped 1v1 set IS the live one.
    storage.feeding_params = { ['1v1'] = { instant_scale = 500, passive_income_scale = 0.75, attack_interval = 7200 } }
    assert_set(league_set('1v1'), FeedingParams.get('1v1'), 'league 1v1 with the live overrides')
end

function test_explicit_classic_overrides_off_the_league_are_harmless()
    -- What an admin writes by hand to hold the classic numbers (c = 200 and
    -- k = 1 in every format, k = 0.5 in 1v1) is what the server plays anyway.
    local explicit = {}
    for _, format_key in ipairs(FeedingParams.format_keys) do
        explicit[format_key] = { instant_scale = 200, passive_income_scale = format_key == '1v1' and 0.5 or 1 }
    end
    for _, format_key in ipairs(FeedingParams.format_keys) do
        storage.feeding_params = nil
        local bare = FeedingParams.get(format_key)
        storage.feeding_params = explicit
        local held = FeedingParams.get(format_key)
        for field, value in pairs(bare) do
            lunatest.assert_equal(value, held[field], format_key .. '.' .. field)
        end
    end
end

function test_describe_and_threat_income_follow_the_league_base()
    storage.tt_mode = true
    storage.bb_league_match = { id = 'L17', format = '2v2' }
    lunatest.assert_equal(
        '2v2 [league match L17] — passive income x0.9, wave every 3600 ticks (1 min, each side every 2 min)',
        MatchFormat.describe()
    )
    -- The League's own 1v1 set: three quarters of the income, a wave every
    -- two minutes, so each side every four.
    storage.bb_league_match = { id = 'L17', format = '1v1' }
    lunatest.assert_equal(
        '1v1 [league match L17] — passive income x0.75, wave every 7200 ticks (2 min, each side every 4 min)',
        MatchFormat.describe()
    )
    -- Off the League the same record plays the classic 1v1.
    storage.tt_mode = nil
    lunatest.assert_equal(
        '1v1 [league match L17] — passive income x0.5, wave every 3600 ticks (1 min, each side every 2 min)',
        MatchFormat.describe()
    )
    storage.tt_mode = true

    storage.bb_league_match = nil
    storage.bb_evolution = { north_biters = 1.0, south_biters = 1.0 }
    storage.bb_threat_income = {}
    MatchFormat.refresh_threat_income()
    -- (100 + 15) · 0.9
    lunatest.assert_equal(103.5, storage.bb_threat_income.north_biters)

    -- (100 + 15) · 0.75 under the League's 1v1.
    storage.bb_league_match = { id = 'L17', format = '1v1' }
    MatchFormat.refresh_threat_income()
    lunatest.assert_equal(86.25, storage.bb_threat_income.north_biters)
    storage.bb_league_match = nil

    storage.tt_mode = nil
    MatchFormat.refresh_threat_income()
    lunatest.assert_equal(115, storage.bb_threat_income.north_biters)
end

function test_the_league_1v1_wave_every_two_minutes_skips_every_second_cycle()
    -- The interval the League's 1v1 ships is honoured by the dispatcher the
    -- way an admin's 7200 was: the cycle runs in the interval's first minute
    -- and the second minute is skipped, sides still alternating.
    storage.tt_mode = true
    storage.bb_league_match = { id = 'L17', format = '1v1' }
    for minute = 0, 5 do
        for _, offset in ipairs(ATTACK_CYCLE_OFFSETS) do
            local tick = minute * TICKS_PER_MINUTE + offset
            lunatest.assert_equal(minute % 2 == 1, MatchFormat.skip_attack_cycle(tick), 'tick ' .. tick)
        end
    end
    -- Off the League nothing is skipped for the same record.
    storage.tt_mode = nil
    for minute = 0, 5 do
        lunatest.assert_false(MatchFormat.skip_attack_cycle(minute * TICKS_PER_MINUTE + ATTACK_CYCLE_OFFSETS[1]))
    end
end

-- ---------------------------------------------------------------------------
-- Threat income is rebuilt for a fixed pair of biter forces
-- ---------------------------------------------------------------------------

function test_refresh_threat_income_rewrites_exactly_the_two_biter_forces()
    -- match_format.lua:23 is a literal `{ 'north_biters', 'south_biters' }`.
    -- A third team's income is left at whatever it was: pinned here so the
    -- registry refactor has to come through this list.
    storage.bb_evolution = { north_biters = 1.0, south_biters = 1.0, east_biters = 1.0 }
    storage.bb_threat_income = { north_biters = -1, south_biters = -1, east_biters = -1 }

    MatchFormat.refresh_threat_income()

    -- passive_scale · E^2.5 + passive_linear · E at E = 1, times an income
    -- scale of 1: 100 + 15.
    lunatest.assert_equal(115, storage.bb_threat_income.north_biters)
    lunatest.assert_equal(115, storage.bb_threat_income.south_biters)
    lunatest.assert_equal(-1, storage.bb_threat_income.east_biters)
end

function test_refresh_threat_income_leaves_a_biter_force_with_no_evolution_alone()
    storage.bb_evolution = { north_biters = 1.0 }
    storage.bb_threat_income = { north_biters = -1, south_biters = -1 }

    MatchFormat.refresh_threat_income()

    lunatest.assert_equal(115, storage.bb_threat_income.north_biters)
    lunatest.assert_equal(-1, storage.bb_threat_income.south_biters)
end

function test_refresh_threat_income_does_nothing_before_the_round_tables_exist()
    storage.bb_evolution = nil
    storage.bb_threat_income = nil
    MatchFormat.refresh_threat_income()
    lunatest.assert_nil(storage.bb_threat_income)
end

lunatest.run()
