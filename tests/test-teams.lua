---@diagnostic disable
--
-- Pins `maps/biter_battles_v2/teams.lua`, the team model:
-- the roster, the round state, and every answer that depends on a team name.
--
-- This suite is the whole specification of the module. What it is here to catch:
--
--   * the **order** of the active teams, of the biter force lists and of the
--     feed targets. It is the iteration order of the whole scenario and a
--     reordered loop is a desync, not a cosmetic change;
--   * the **two-team answers**, which must stay today's: one enemy with share 1
--     (the multiplication is skipped, so the rounding of a send is unchanged),
--     'Team North'/'Team South' from config.lua, and colour tags byte-identical
--     to `Functions.team_name_with_color` (functions.lua:461-470) down to the
--     spaces after the commas — tests/test-team-contracts.lua pins the same two
--     strings on the function this one will replace;
--   * that the team count only ever changes in `begin_round()`, and that a
--     round forgets the previous round's eliminations but keeps the count that
--     nobody changed.
--
-- The module loads outside Factorio: it requires only `config.lua` (pure data)
-- and `utils/force.lua` (pure string matching) and touches `game` inside
-- `ensure_forces()` and `eliminate()` only. `storage` is the usual mock, rebuilt
-- per test because lunatest walks the test table with `pairs`; `game` is faked
-- below, and only with what those two functions read.

local lunatest = require('lunatest')

storage = { ['_TEST'] = true }

local Teams = require('maps.biter_battles_v2.teams')
local Config = require('maps.biter_battles_v2.config')

-- init.lua:80-86, in that order: the forces a two-team save already has when
-- `ensure_forces()` is first called.
local LEGACY_FORCES = {
    'north',
    'south',
    'north_biters',
    'south_biters',
    'north_biters_boss',
    'south_biters_boss',
    'spectator',
}

--- A `game` with exactly what teams.lua reads: the tick, the force table and
--- `create_force`. Returns the log of created force names, in call order (that
--- order is what a save's force indices are), and the force table itself.
---@param tick integer|nil
local function mock_game(tick)
    local forces = {}
    local created = {}
    for _, name in ipairs(LEGACY_FORCES) do
        forces[name] = { name = name }
    end
    game = {
        tick = tick or 0,
        forces = forces,
        create_force = function(name)
            lunatest.assert_nil(forces[name], 'create_force called for an existing force: ' .. tostring(name))
            forces[name] = { name = name }
            created[#created + 1] = name
            return forces[name]
        end,
    }
    return created, forces
end

--- Ask for `count` teams and start the round.
local function round_of(count)
    lunatest.assert_true(Teams.set_next_count(count), 'set_next_count(' .. tostring(count) .. ')')
    return Teams.begin_round()
end

local function joined(array)
    return table.concat(array, ',')
end

--- 'east=0.333333,south=0.333333' — targets and shares as one comparable string.
local function feed_summary(targets)
    local parts = {}
    for i, target in ipairs(targets) do
        parts[i] = string.format('%s=%.6f', target.team, target.share)
    end
    return table.concat(parts, ',')
end

local function fed_teams(targets)
    local names = {}
    for i, target in ipairs(targets) do
        names[i] = target.team
    end
    return table.concat(names, ',')
end

local function total_share(targets)
    local total = 0
    for _, target in ipairs(targets) do
        total = total + target.share
    end
    return total
end

function setup()
    storage = { ['_TEST'] = true }
    game = nil
end

-- ---------------------------------------------------------------------------
-- The lazily created default round
-- ---------------------------------------------------------------------------

function test_a_reader_before_the_first_round_sees_todays_two_team_game()
    lunatest.assert_nil(storage.bb_teams)

    local state = Teams.state()

    lunatest.assert_equal(2, state.count)
    lunatest.assert_equal('horizontal2', state.layout)
    lunatest.assert_equal('north,south', joined(state.active))
    lunatest.assert_equal('north,south', joined(state.alive_list))
    lunatest.assert_true(state.alive.north)
    lunatest.assert_true(state.alive.south)
    lunatest.assert_equal(0, #state.eliminated)
    lunatest.assert_nil(state.next_count)
    lunatest.assert_equal('split', state.feed_policy)

    -- ...and the default is now the round state, not rebuilt on every read.
    lunatest.assert_equal(state, storage.bb_teams)
    lunatest.assert_equal(state, Teams.state())
end

function test_the_getters_agree_with_the_default_state()
    lunatest.assert_equal(2, Teams.count())
    lunatest.assert_equal('horizontal2', Teams.layout())
    lunatest.assert_equal('north,south', joined(Teams.all()))
    lunatest.assert_equal('north,south', joined(Teams.alive()))
    lunatest.assert_nil(Teams.next_count())
    lunatest.assert_nil(Teams.winner())
    lunatest.assert_equal(0, #Teams.placement())
end

function test_all_hands_out_the_live_array_that_callers_must_not_write_to()
    -- Documented contract: tick handlers walk it, so it is not copied.
    lunatest.assert_equal(Teams.state().active, Teams.all())
    lunatest.assert_equal(Teams.state().alive_list, Teams.alive())
end

-- ---------------------------------------------------------------------------
-- begin_round and set_next_count — the one place the count changes
-- ---------------------------------------------------------------------------

function test_a_round_started_with_no_request_is_a_two_team_round()
    local state = Teams.begin_round()
    lunatest.assert_equal(2, state.count)
    lunatest.assert_equal('horizontal2', state.layout)
    lunatest.assert_equal('north,south', joined(state.active))
end

function test_the_count_is_applied_once_and_then_kept_across_rounds()
    -- 2 -> 4 -> 4 -> 3 -> 2, the sequence an admin drives with /team-count.
    Teams.begin_round()
    lunatest.assert_equal(2, Teams.count())

    lunatest.assert_true(Teams.set_next_count(4))
    lunatest.assert_equal(4, Teams.next_count())
    lunatest.assert_equal(2, Teams.count(), 'the request only lands at the reset')

    Teams.begin_round()
    lunatest.assert_equal(4, Teams.count())
    lunatest.assert_nil(Teams.next_count(), 'the request is consumed')
    lunatest.assert_equal('cross4', Teams.layout())

    Teams.begin_round()
    lunatest.assert_equal(4, Teams.count(), 'no request means no change')
    lunatest.assert_equal('north,east,south,west', joined(Teams.all()))

    round_of(3)
    lunatest.assert_equal(3, Teams.count())
    lunatest.assert_equal('cross4', Teams.layout())
    lunatest.assert_equal('north,east,south', joined(Teams.all()))

    round_of(2)
    lunatest.assert_equal(2, Teams.count())
    lunatest.assert_equal('horizontal2', Teams.layout())
    lunatest.assert_equal('north,south', joined(Teams.all()))
end

function test_a_round_forgets_the_eliminations_of_the_previous_one()
    mock_game(1000)
    round_of(4)
    Teams.eliminate('east')
    Teams.eliminate('north')
    lunatest.assert_equal(2, #Teams.state().eliminated)
    lunatest.assert_equal('south,west', joined(Teams.alive()))

    local state = Teams.begin_round()

    lunatest.assert_equal(0, #state.eliminated)
    lunatest.assert_equal(4, state.count, 'the count survives the round, the deaths do not')
    lunatest.assert_equal('north,east,south,west', joined(Teams.alive()))
    lunatest.assert_true(Teams.is_alive('east'))
    lunatest.assert_nil(Teams.winner())
    lunatest.assert_equal(0, #Teams.placement())
end

function test_a_round_keeps_the_feeding_policy()
    round_of(4)
    Teams.state().feed_policy = 'ring'
    Teams.begin_round()
    lunatest.assert_equal('ring', Teams.state().feed_policy)
    round_of(3)
    lunatest.assert_equal('ring', Teams.state().feed_policy)
end

function test_only_a_round_of_more_than_two_teams_latches_the_extra_chat_commands()
    -- The latch `commands/chat_commands.lua` registers `/eth` and `/wth` from.
    -- A two-team save must never gain the key: its storage, and so its command
    -- list, are exactly today's.
    Teams.begin_round()
    lunatest.assert_false(Teams.extra_chat_commands())
    lunatest.assert_nil(Teams.state().extra_chat_commands, 'the key is not even written')

    round_of(3)
    lunatest.assert_true(Teams.extra_chat_commands())

    -- Never cleared: a command cannot be unregistered, so a save that once had
    -- them keeps them for good, two-team rounds included.
    round_of(2)
    lunatest.assert_equal(2, Teams.count())
    lunatest.assert_true(Teams.extra_chat_commands())

    round_of(4)
    lunatest.assert_true(Teams.extra_chat_commands())
end

function test_the_extra_chat_command_latch_can_be_read_without_creating_the_round_state()
    -- It is read from `on_load`, where `storage` may be read but not written:
    -- unlike every other reader this one must not go through `state()`.
    lunatest.assert_nil(storage.bb_teams)
    lunatest.assert_false(Teams.extra_chat_commands())
    lunatest.assert_nil(storage.bb_teams, 'no round state was created')

    -- And it is defensive about what it finds there.
    storage.bb_teams = {}
    lunatest.assert_false(Teams.extra_chat_commands())
    storage.bb_teams = { extra_chat_commands = false }
    lunatest.assert_false(Teams.extra_chat_commands())
    storage.bb_teams = { extra_chat_commands = true }
    lunatest.assert_true(Teams.extra_chat_commands())
end

function test_begin_round_falls_back_to_two_teams_when_the_saved_count_is_corrupt()
    -- The one guard that protects a save whose `bb_teams` was mangled (a bad
    -- migration, a console edit): an unplayable count is not carried into the
    -- new round, it becomes today's two-team game rather than an
    -- `ipairs(nil)` in the first per-team builder of `Init.tables()`.
    round_of(4)
    Teams.state().count = 7

    local state = Teams.begin_round()

    lunatest.assert_equal(2, state.count)
    lunatest.assert_equal('horizontal2', state.layout)
    lunatest.assert_equal('north,south', joined(state.active))
    lunatest.assert_equal('north,south', joined(state.alive_list))
    lunatest.assert_equal('north_biters,south_biters', joined(Teams.biter_forces()))

    -- Same for a pending count that never came through `set_next_count`.
    Teams.state().next_count = 0
    lunatest.assert_equal(2, Teams.begin_round().count)
    Teams.state().next_count = 'four'
    lunatest.assert_equal(2, Teams.begin_round().count)
    Teams.state().count = nil
    lunatest.assert_equal(2, Teams.begin_round().count)
end

function test_the_feeding_policy_is_set_through_the_setter()
    lunatest.assert_equal('split', Teams.feed_policy(), 'the default')

    for _, policy in ipairs({ 'target', 'ring', 'split' }) do
        local ok, reason = Teams.set_feed_policy(policy)
        lunatest.assert_true(ok, policy)
        lunatest.assert_nil(reason)
        lunatest.assert_equal(policy, Teams.feed_policy(), policy)
        lunatest.assert_equal(policy, Teams.state().feed_policy, policy)
    end
end

function test_the_feeding_policy_refuses_anything_else_and_keeps_the_current_one()
    lunatest.assert_true(Teams.set_feed_policy('ring'))

    for _, bad in ipairs({ 'Ring', 'even', '', 'north', 2, true, {} }) do
        local ok, reason = Teams.set_feed_policy(bad)
        lunatest.assert_false(ok, tostring(bad) .. ' must be refused')
        lunatest.assert_equal('string', type(reason), 'a refusal says why')
        lunatest.assert_equal('ring', Teams.feed_policy(), 'a refused policy leaves the current one alone')
    end

    local ok, reason = Teams.set_feed_policy(nil)
    lunatest.assert_false(ok, 'nil must be refused')
    lunatest.assert_equal('string', type(reason))
    lunatest.assert_equal('ring', Teams.feed_policy())
end

function test_a_policy_set_before_a_round_is_the_policy_of_that_round()
    -- The count is applied at the reset; the policy is not queued at all, and
    -- the round boundary keeps it (`rebuild` copies it forward).
    round_of(4)
    lunatest.assert_true(Teams.set_feed_policy('ring'))
    lunatest.assert_equal('east=1.000000', feed_summary(Teams.feed_targets('north')))

    round_of(3)
    lunatest.assert_equal('ring', Teams.feed_policy())
    lunatest.assert_equal('east=1.000000', feed_summary(Teams.feed_targets('north')))

    -- Two teams answer "the other one" whatever the policy says.
    round_of(2)
    lunatest.assert_equal('ring', Teams.feed_policy())
    lunatest.assert_equal('south=1.000000', feed_summary(Teams.feed_targets('north')))
    lunatest.assert_equal('north=1.000000', feed_summary(Teams.feed_targets('south')))
end

function test_set_next_count_accepts_two_three_and_four()
    for _, count in ipairs({ 2, 3, 4 }) do
        local ok, reason = Teams.set_next_count(count)
        lunatest.assert_true(ok, tostring(count))
        lunatest.assert_nil(reason)
        lunatest.assert_equal(count, Teams.next_count())
    end
end

function test_set_next_count_refuses_anything_that_is_not_two_three_or_four()
    lunatest.assert_true(Teams.set_next_count(3))

    for _, bad in ipairs({ 1, 5, 0, -2, 2.5, '3', true, {} }) do
        local ok, reason = Teams.set_next_count(bad)
        lunatest.assert_false(ok, tostring(bad) .. ' must be refused')
        lunatest.assert_equal('string', type(reason), 'a refusal says why')
        lunatest.assert_equal(3, Teams.next_count(), 'a refused request leaves the pending one alone')
    end

    local ok, reason = Teams.set_next_count(nil)
    lunatest.assert_false(ok, 'nil must be refused')
    lunatest.assert_equal('string', type(reason))
    lunatest.assert_equal(3, Teams.next_count())
end

-- ---------------------------------------------------------------------------
-- The roster: order, forces, ring
-- ---------------------------------------------------------------------------

function test_the_active_teams_of_every_count()
    round_of(2)
    lunatest.assert_equal('north,south', joined(Teams.all()))
    round_of(3)
    lunatest.assert_equal('north,east,south', joined(Teams.all()))
    round_of(4)
    lunatest.assert_equal('north,east,south,west', joined(Teams.all()))
end

function test_the_biter_and_boss_force_lists_of_every_count()
    round_of(2)
    lunatest.assert_equal('north_biters,south_biters', joined(Teams.biter_forces()))
    lunatest.assert_equal('north_biters_boss,south_biters_boss', joined(Teams.boss_forces()))

    round_of(3)
    lunatest.assert_equal('north_biters,east_biters,south_biters', joined(Teams.biter_forces()))
    lunatest.assert_equal('north_biters_boss,east_biters_boss,south_biters_boss', joined(Teams.boss_forces()))

    round_of(4)
    lunatest.assert_equal('north_biters,east_biters,south_biters,west_biters', joined(Teams.biter_forces()))
    lunatest.assert_equal(
        'north_biters_boss,east_biters_boss,south_biters_boss,west_biters_boss',
        joined(Teams.boss_forces())
    )
end

function test_the_force_lists_are_the_live_arrays_that_callers_must_not_write_to()
    -- Same contract as `all()`, and for the same reason: `biter_forces()` is
    -- read from the threat tick and from the wave dispatcher, so it hands out
    -- the array `begin_round()` built instead of allocating one per call.
    round_of(4)
    local state = Teams.state()
    lunatest.assert_equal(state.biter_force_list, Teams.biter_forces())
    lunatest.assert_equal(state.boss_force_list, Teams.boss_forces())
    lunatest.assert_equal(state.alive_biter_force_list, Teams.alive_biter_forces())
    lunatest.assert_equal(Teams.biter_forces(), Teams.biter_forces(), 'the same array on every call')

    -- ...and a new round hands out a new one, built for the new team list.
    local four_team_list = Teams.biter_forces()
    round_of(2)
    lunatest.assert_false(four_team_list == Teams.biter_forces())
    lunatest.assert_equal('north_biters,south_biters', joined(Teams.biter_forces()))
    lunatest.assert_equal('north_biters_boss,south_biters_boss', joined(Teams.boss_forces()))
end

function test_the_alive_biter_forces_of_every_count()
    round_of(2)
    lunatest.assert_equal('north_biters,south_biters', joined(Teams.alive_biter_forces()))
    round_of(3)
    lunatest.assert_equal('north_biters,east_biters,south_biters', joined(Teams.alive_biter_forces()))
    round_of(4)
    lunatest.assert_equal('north_biters,east_biters,south_biters,west_biters', joined(Teams.alive_biter_forces()))
end

function test_an_eliminated_team_leaves_the_alive_biter_force_list()
    mock_game(64)
    round_of(4)

    Teams.eliminate('east')
    lunatest.assert_equal('north_biters,south_biters,west_biters', joined(Teams.alive_biter_forces()))
    lunatest.assert_equal(
        'north_biters,east_biters,south_biters,west_biters',
        joined(Teams.biter_forces()),
        'the active list is not touched by an elimination'
    )

    Teams.eliminate('north')
    lunatest.assert_equal('south_biters,west_biters', joined(Teams.alive_biter_forces()))

    -- Eliminating what cannot be eliminated rebuilds nothing.
    local list = Teams.alive_biter_forces()
    Teams.eliminate('north')
    Teams.eliminate('spectator')
    lunatest.assert_equal(list, Teams.alive_biter_forces())

    -- The next round starts with everybody alive again.
    Teams.begin_round()
    lunatest.assert_equal('north_biters,east_biters,south_biters,west_biters', joined(Teams.alive_biter_forces()))
end

function test_the_roster_is_the_whole_ring_whatever_the_round()
    -- Read before there is a round at all: a command registration runs at load
    -- time, so this answer may not depend on -- or create -- the round state.
    lunatest.assert_equal('north,east,south,west', joined(Teams.roster()))
    lunatest.assert_nil(storage.bb_teams, 'the roster is static: reading it starts no round')

    for _, count in ipairs({ 2, 3, 4 }) do
        round_of(count)
        lunatest.assert_equal('north,east,south,west', joined(Teams.roster()), 'round of ' .. count)
    end

    for _, team in ipairs(Teams.roster()) do
        lunatest.assert_true(Teams.is_team(team), team)
    end
end

function test_the_roster_is_a_copy_the_caller_may_keep()
    local names = Teams.roster()
    names[1] = 'nowhere'
    names[#names + 1] = 'nowhere'
    lunatest.assert_equal('north,east,south,west', joined(Teams.roster()))
end

function test_a_teams_force_names_do_not_depend_on_the_round()
    -- Two-team round, but the names of the dormant teams still answer.
    for _, team in ipairs({ 'north', 'east', 'south', 'west' }) do
        lunatest.assert_equal(team .. '_biters', Teams.biter_force(team), team)
        lunatest.assert_equal(team .. '_biters_boss', Teams.boss_force(team), team)
    end
end

function test_index_of_is_the_position_in_this_round()
    round_of(4)
    lunatest.assert_equal(1, Teams.index_of('north'))
    lunatest.assert_equal(2, Teams.index_of('east'))
    lunatest.assert_equal(3, Teams.index_of('south'))
    lunatest.assert_equal(4, Teams.index_of('west'))

    round_of(3)
    lunatest.assert_equal(3, Teams.index_of('south'), 'south moves up when west does not play')
    lunatest.assert_nil(Teams.index_of('west'))

    round_of(2)
    lunatest.assert_equal(1, Teams.index_of('north'))
    lunatest.assert_equal(2, Teams.index_of('south'))
    lunatest.assert_nil(Teams.index_of('east'))
    lunatest.assert_nil(Teams.index_of('spectator'))
    lunatest.assert_nil(Teams.index_of(nil))
end

function test_the_ring_is_the_same_whatever_the_round()
    local ring = { 'north', 'east', 'south', 'west' }
    for _, count in ipairs({ 2, 3, 4 }) do
        round_of(count)
        for position, team in ipairs(ring) do
            lunatest.assert_equal(position, Teams.ring_index(team), team)
            lunatest.assert_equal(position - 1, Teams.k_of(team), team)
        end
    end
    lunatest.assert_nil(Teams.ring_index('spectator'))
    lunatest.assert_nil(Teams.k_of('spectator'))
    lunatest.assert_nil(Teams.k_of(nil))
end

function test_k_of_is_the_quarter_turn_of_a_roster_team_and_nothing_else()
    -- `k` is what the cross layout rotates a zone by, so it is a property of
    -- the ring position and not of the round: north 0, east 1, south 2, west 3
    -- whether or not the team plays.
    local expected = { north = 0, east = 1, south = 2, west = 3 }
    for _, count in ipairs({ 2, 3, 4 }) do
        round_of(count)
        for team, k in pairs(expected) do
            lunatest.assert_equal(k, Teams.k_of(team), team .. ' in a round of ' .. count)
        end
    end
    lunatest.assert_nil(Teams.k_of('north_biters'))
    lunatest.assert_nil(Teams.k_of('spectator'))
    lunatest.assert_nil(Teams.k_of('NORTH'))
    lunatest.assert_nil(Teams.k_of(nil))
    lunatest.assert_nil(Teams.k_of(1))
end

function test_is_team_is_active_and_is_alive()
    round_of(3)
    for _, team in ipairs({ 'north', 'east', 'south', 'west' }) do
        lunatest.assert_true(Teams.is_team(team), team)
    end
    lunatest.assert_false(Teams.is_team('spectator'))
    lunatest.assert_false(Teams.is_team('north_biters'))
    lunatest.assert_false(Teams.is_team(nil))

    lunatest.assert_true(Teams.is_active('east'))
    lunatest.assert_false(Teams.is_active('west'), 'a roster team that does not play this round')
    lunatest.assert_false(Teams.is_active('spectator'))

    mock_game(7)
    Teams.eliminate('east')
    lunatest.assert_true(Teams.is_active('east'), 'an eliminated team still plays this round')
    lunatest.assert_false(Teams.is_alive('east'))
    lunatest.assert_true(Teams.is_alive('north'))
    lunatest.assert_false(Teams.is_alive('west'), 'not playing is not alive')
    lunatest.assert_false(Teams.is_alive('spectator'))
end

function test_team_of_biter_force_answers_for_roster_teams_only()
    lunatest.assert_equal('north', Teams.team_of_biter_force('north_biters'))
    lunatest.assert_equal('north', Teams.team_of_biter_force('north_biters_boss'))
    lunatest.assert_equal('west', Teams.team_of_biter_force('west_biters_boss'), 'a dormant team still resolves')
    lunatest.assert_equal('east', Teams.team_of_biter_force('east_biters'))

    -- utils/force.lua is prefix-lazy: '' and 'foo' are what it returns here,
    -- and neither is a team (tests/test-force.lua).
    lunatest.assert_nil(Teams.team_of_biter_force('_biters'))
    lunatest.assert_nil(Teams.team_of_biter_force('foo_biters'))
    lunatest.assert_nil(Teams.team_of_biter_force('north'))
    lunatest.assert_nil(Teams.team_of_biter_force('spectator'))
    lunatest.assert_nil(Teams.team_of_biter_force('NORTH_BITERS'))
    lunatest.assert_nil(Teams.team_of_biter_force(nil))
end

function test_every_team_has_a_colour_and_its_rich_text_spelling()
    local expected = {
        north = { r = 120, g = 120, b = 255, text = '120, 120, 255' },
        east = { r = 80, g = 215, b = 95, text = '80, 215, 95' },
        south = { r = 255, g = 65, b = 65, text = '255, 65, 65' },
        west = { r = 255, g = 200, b = 50, text = '255, 200, 50' },
    }
    for _, team in ipairs({ 'north', 'east', 'south', 'west' }) do
        local want = expected[team]
        local color = Teams.color(team)
        lunatest.assert_equal(want.r, color.r, team)
        lunatest.assert_equal(want.g, color.g, team)
        lunatest.assert_equal(want.b, color.b, team)
        lunatest.assert_equal(want.text, Teams.text_color(team), team)
        -- The tag payload is the same colour, comma-space separated.
        lunatest.assert_equal(string.format('%d, %d, %d', color.r, color.g, color.b), Teams.text_color(team), team)
        -- A fresh table each call: a caller may keep or scale it.
        lunatest.assert_false(Teams.color(team) == Teams.color(team))
    end
    lunatest.assert_nil(Teams.color('spectator'))
    lunatest.assert_nil(Teams.text_color('spectator'))
end

-- ---------------------------------------------------------------------------
-- Enemies and the ring
-- ---------------------------------------------------------------------------

function test_two_teams_have_exactly_one_enemy_each()
    lunatest.assert_equal('south', joined(Teams.enemies_of('north')))
    lunatest.assert_equal('north', joined(Teams.enemies_of('south')))
end

function test_enemies_are_listed_in_round_order_and_drop_out_when_eliminated()
    mock_game(500)
    round_of(4)
    lunatest.assert_equal('east,south,west', joined(Teams.enemies_of('north')))
    lunatest.assert_equal('north,east,west', joined(Teams.enemies_of('south')))

    Teams.eliminate('east')
    lunatest.assert_equal('south,west', joined(Teams.enemies_of('north')))
    lunatest.assert_equal('north,south', joined(Teams.enemies_of('west')))

    Teams.eliminate('west')
    lunatest.assert_equal('south', joined(Teams.enemies_of('north')))
    lunatest.assert_equal('north', joined(Teams.enemies_of('south')))

    Teams.eliminate('north')
    lunatest.assert_equal('', joined(Teams.enemies_of('south')), 'the winner has no enemy left')
end

function test_the_next_team_clockwise_wraps_round_the_ring()
    round_of(4)
    lunatest.assert_equal('east', Teams.next_alive_clockwise('north'))
    lunatest.assert_equal('south', Teams.next_alive_clockwise('east'))
    lunatest.assert_equal('west', Teams.next_alive_clockwise('south'))
    lunatest.assert_equal('north', Teams.next_alive_clockwise('west'))
    lunatest.assert_nil(Teams.next_alive_clockwise('spectator'))
end

function test_the_next_team_clockwise_steps_over_dead_and_dormant_teams()
    -- Three teams: west never plays, so the ring is north -> east -> south.
    round_of(3)
    lunatest.assert_equal('north', Teams.next_alive_clockwise('south'), 'west does not play')

    mock_game(42)
    Teams.eliminate('east')
    lunatest.assert_equal('south', Teams.next_alive_clockwise('north'))
    lunatest.assert_equal('north', Teams.next_alive_clockwise('south'))

    Teams.eliminate('north')
    lunatest.assert_nil(Teams.next_alive_clockwise('south'), 'the last one standing has nobody to feed')
end

-- ---------------------------------------------------------------------------
-- feed_targets — who receives a send
-- ---------------------------------------------------------------------------

function test_two_teams_feed_each_other_with_the_whole_send()
    lunatest.assert_equal('south=1.000000', feed_summary(Teams.feed_targets('north')))
    lunatest.assert_equal('north=1.000000', feed_summary(Teams.feed_targets('south')))
    lunatest.assert_equal(1, #Teams.feed_targets('north'), 'one target, so no multiplication happens')
    lunatest.assert_equal(1, Teams.feed_targets('north')[1].share)
end

function test_two_teams_feed_each_other_whatever_the_alive_flags_say()
    -- Today's `enemy_team_of` does not know about elimination and the game is
    -- over the moment a team dies; a send in flight must resolve the same way.
    mock_game(10)
    Teams.eliminate('south')
    lunatest.assert_equal('south=1.000000', feed_summary(Teams.feed_targets('north')))
    lunatest.assert_equal('north=1.000000', feed_summary(Teams.feed_targets('south')))
end

function test_a_sender_that_is_not_a_team_feeds_nobody()
    lunatest.assert_equal(0, #Teams.feed_targets('spectator'))
    lunatest.assert_equal(0, #Teams.feed_targets('east'), 'east does not play a two-team round')
    lunatest.assert_equal(0, #Teams.feed_targets(nil))

    round_of(4)
    lunatest.assert_equal(0, #Teams.feed_targets('spectator'))
end

function test_training_mode_feeds_your_own_biters()
    storage.training_mode = true
    lunatest.assert_equal('north=1.000000', feed_summary(Teams.feed_targets('north')))
    lunatest.assert_equal('south=1.000000', feed_summary(Teams.feed_targets('south')))

    round_of(4)
    lunatest.assert_equal('west=1.000000', feed_summary(Teams.feed_targets('west')))
    lunatest.assert_equal('east=1.000000', feed_summary(Teams.feed_targets('east', 'south')), 'the choice is ignored')
end

function test_split_shares_the_send_between_every_alive_enemy()
    round_of(4)
    local targets = Teams.feed_targets('north')
    lunatest.assert_equal(3, #targets)
    lunatest.assert_equal('east,south,west', fed_teams(targets), 'round order')
    for _, target in ipairs(targets) do
        lunatest.assert_equal(1 / 3, target.share, target.team)
    end
    lunatest.assert_equal(1, total_share(targets), 'the shares are a whole send')

    lunatest.assert_equal('north,east,west', fed_teams(Teams.feed_targets('south')))
end

function test_split_hands_the_share_of_an_eliminated_team_to_the_survivors()
    mock_game(900)
    round_of(4)
    Teams.eliminate('west')

    local targets = Teams.feed_targets('north')
    lunatest.assert_equal(2, #targets)
    lunatest.assert_equal('east,south', fed_teams(targets))
    lunatest.assert_equal(0.5, targets[1].share)
    lunatest.assert_equal(0.5, targets[2].share)
    lunatest.assert_equal(1, total_share(targets))

    Teams.eliminate('east')
    lunatest.assert_equal('south=1.000000', feed_summary(Teams.feed_targets('north')))
end

function test_an_eliminated_sender_feeds_nobody()
    mock_game(900)
    round_of(4)
    Teams.eliminate('north')
    lunatest.assert_equal(0, #Teams.feed_targets('north'))
end

function test_the_target_policy_needs_an_alive_enemy_and_falls_back_to_split()
    mock_game(900)
    round_of(4)
    Teams.state().feed_policy = 'target'

    lunatest.assert_equal('west=1.000000', feed_summary(Teams.feed_targets('north', 'west')))

    -- No choice, the sender itself, a team that does not play, a dead team:
    -- all four are an even split rather than a lost send.
    Teams.eliminate('east')
    for _, choice in ipairs({ 'north', 'east' }) do
        lunatest.assert_equal('south=0.500000,west=0.500000', feed_summary(Teams.feed_targets('north', choice)), choice)
    end
    lunatest.assert_equal('south=0.500000,west=0.500000', feed_summary(Teams.feed_targets('north')))
    lunatest.assert_equal('south=0.500000,west=0.500000', feed_summary(Teams.feed_targets('north', 'spectator')))
end

function test_the_ring_policy_feeds_the_next_team_clockwise()
    mock_game(900)
    round_of(4)
    Teams.state().feed_policy = 'ring'

    lunatest.assert_equal('east=1.000000', feed_summary(Teams.feed_targets('north')))
    lunatest.assert_equal('north=1.000000', feed_summary(Teams.feed_targets('west', 'south')), 'the choice is ignored')

    Teams.eliminate('east')
    lunatest.assert_equal('south=1.000000', feed_summary(Teams.feed_targets('north')))

    Teams.eliminate('south')
    Teams.eliminate('west')
    lunatest.assert_equal(0, #Teams.feed_targets('north'), 'nobody left to feed')
end

-- ---------------------------------------------------------------------------
-- Display names and colours
-- ---------------------------------------------------------------------------

function test_the_two_team_layout_shows_the_configured_team_names()
    lunatest.assert_equal(Config.north_side_team_name, Teams.display_name('north'))
    lunatest.assert_equal(Config.south_side_team_name, Teams.display_name('south'))
    lunatest.assert_equal('Team North', Teams.display_name('north'))
    lunatest.assert_equal('Team South', Teams.display_name('south'))
    -- No compass name is invented for the teams that do not play.
    lunatest.assert_equal('east', Teams.display_name('east'))
    lunatest.assert_equal('west', Teams.display_name('west'))
end

function test_the_cross_layout_names_the_corners()
    round_of(4)
    lunatest.assert_equal('Top Left', Teams.display_name('north'))
    lunatest.assert_equal('Top Right', Teams.display_name('east'))
    lunatest.assert_equal('Bottom Right', Teams.display_name('south'))
    lunatest.assert_equal('Bottom Left', Teams.display_name('west'))

    round_of(3)
    lunatest.assert_equal('Top Left', Teams.display_name('north'))
    lunatest.assert_equal('Bottom Right', Teams.display_name('south'))
    lunatest.assert_equal('Bottom Left', Teams.display_name('west'), 'named even though it does not play')
end

function test_a_custom_name_wins_in_every_layout()
    -- functions.lua:450 reads storage.tm_custom_name unguarded; here the table
    -- may simply be absent, as it is before Init.tables() runs.
    lunatest.assert_nil(storage.tm_custom_name)
    lunatest.assert_equal('Team North', Teams.display_name('north'))

    storage.tm_custom_name = { north = 'Blue Crew', south = 'Red Crew', spectator = 'The Crowd' }
    lunatest.assert_equal('Blue Crew', Teams.display_name('north'))
    lunatest.assert_equal('Red Crew', Teams.display_name('south'))
    lunatest.assert_equal('The Crowd', Teams.display_name('spectator'))

    round_of(4)
    lunatest.assert_equal('Blue Crew', Teams.display_name('north'))
    lunatest.assert_equal('Top Right', Teams.display_name('east'), 'no custom name, so the corner')
end

function test_an_unknown_force_is_shown_by_its_own_name()
    lunatest.assert_equal('spectator', Teams.display_name('spectator'))
    lunatest.assert_equal('player', Teams.display_name('player'))
    lunatest.assert_equal('north_biters', Teams.display_name('north_biters'))
    lunatest.assert_equal('spectator', Teams.name_with_color('spectator'))
    lunatest.assert_equal('north_biters', Teams.name_with_color('north_biters'))
end

function test_the_two_team_colour_tags_are_byte_identical_to_todays()
    -- functions.lua:461-470, and the same two strings as
    -- tests/test-team-contracts.lua — spaces after the commas included.
    lunatest.assert_equal('[color=120, 120, 255]Team North[/color]', Teams.name_with_color('north'))
    lunatest.assert_equal('[color=255, 65, 65]Team South[/color]', Teams.name_with_color('south'))

    storage.tm_custom_name = { north = 'Blue Crew', south = 'Red Crew' }
    lunatest.assert_equal('[color=120, 120, 255]Blue Crew[/color]', Teams.name_with_color('north'))
    lunatest.assert_equal('[color=255, 65, 65]Red Crew[/color]', Teams.name_with_color('south'))
end

function test_the_four_teams_are_coloured_in_the_cross_layout()
    round_of(4)
    lunatest.assert_equal('[color=120, 120, 255]Top Left[/color]', Teams.name_with_color('north'))
    lunatest.assert_equal('[color=80, 215, 95]Top Right[/color]', Teams.name_with_color('east'))
    lunatest.assert_equal('[color=255, 65, 65]Bottom Right[/color]', Teams.name_with_color('south'))
    lunatest.assert_equal('[color=255, 200, 50]Bottom Left[/color]', Teams.name_with_color('west'))
end

-- ---------------------------------------------------------------------------
-- Per-team table builders
-- ---------------------------------------------------------------------------

function test_per_team_and_per_biter_force_build_one_entry_per_active_team()
    round_of(3)

    local seen = {}
    local by_team = Teams.per_team(function(team)
        seen[#seen + 1] = team
        return team .. '!'
    end)
    lunatest.assert_equal('north,east,south', table.concat(seen, ','), 'built in round order')
    lunatest.assert_equal('north!', by_team.north)
    lunatest.assert_equal('east!', by_team.east)
    lunatest.assert_equal('south!', by_team.south)
    lunatest.assert_nil(by_team.west)

    local by_force = Teams.per_biter_force(function(force_name)
        return force_name:upper()
    end)
    lunatest.assert_equal('NORTH_BITERS', by_force.north_biters)
    lunatest.assert_equal('EAST_BITERS', by_force.east_biters)
    lunatest.assert_equal('SOUTH_BITERS', by_force.south_biters)
    lunatest.assert_nil(by_force.west_biters)
    lunatest.assert_nil(by_force.north, 'keyed by the biter force, not the team')
    lunatest.assert_nil(by_force.north_biters_boss, 'boss forces are not in it')

    -- The usual Init.tables() shape: a constant per team.
    local zeroes = Teams.per_biter_force(function()
        return 0
    end)
    lunatest.assert_equal(0, zeroes.north_biters)
    lunatest.assert_equal(0, zeroes.south_biters)
end

-- ---------------------------------------------------------------------------
-- ensure_forces
-- ---------------------------------------------------------------------------

function test_a_two_team_round_needs_no_force_created()
    local created = mock_game()
    local new_teams = Teams.begin_round()
    lunatest.assert_equal(2, new_teams.count)
    lunatest.assert_equal(0, #Teams.ensure_forces())
    lunatest.assert_equal(0, #created, 'a server that never plays more than two teams keeps todays force list')
end

function test_ensure_forces_creates_the_missing_forces_team_by_team()
    local created = mock_game()
    round_of(4)

    local new_teams = Teams.ensure_forces()

    lunatest.assert_equal('east,west', joined(new_teams), 'only the team forces this call made, in round order')
    lunatest.assert_equal(
        'east,east_biters,east_biters_boss,west,west_biters,west_biters_boss',
        joined(created),
        'team, then biters, then boss biters, team by team'
    )

    -- Idempotent: a second round of the same size creates nothing more.
    local again = Teams.ensure_forces()
    lunatest.assert_equal(0, #again)
    lunatest.assert_equal(6, #created)
end

function test_ensure_forces_reports_only_the_team_forces_it_created()
    local created, forces = mock_game()
    forces['east'] = { name = 'east' } -- left over from an earlier round
    round_of(3)

    local new_teams = Teams.ensure_forces()

    lunatest.assert_equal(0, #new_teams, 'east already had its team force, so it needs no one-shot setup')
    lunatest.assert_equal('east_biters,east_biters_boss', joined(created))
end

-- ---------------------------------------------------------------------------
-- Elimination, winner, placement
-- ---------------------------------------------------------------------------

function test_a_four_team_round_is_placed_in_reverse_elimination_order()
    mock_game(100)
    round_of(4)

    lunatest.assert_equal(3, Teams.eliminate('east'))
    lunatest.assert_equal('north,south,west', joined(Teams.alive()))
    lunatest.assert_nil(Teams.winner())

    game.tick = 200
    lunatest.assert_equal(2, Teams.eliminate('north'))
    lunatest.assert_equal('south,west', joined(Teams.alive()))
    lunatest.assert_nil(Teams.winner())

    game.tick = 300
    lunatest.assert_equal(1, Teams.eliminate('west'))
    lunatest.assert_equal('south', joined(Teams.alive()))
    lunatest.assert_equal('south', Teams.winner())
    lunatest.assert_equal('south,west,north,east', joined(Teams.placement()))

    local eliminated = Teams.state().eliminated
    lunatest.assert_equal(3, #eliminated)
    lunatest.assert_equal('east', eliminated[1].team)
    lunatest.assert_equal(100, eliminated[1].tick)
    lunatest.assert_equal('north', eliminated[2].team)
    lunatest.assert_equal(200, eliminated[2].tick)
    lunatest.assert_equal('west', eliminated[3].team)
    lunatest.assert_equal(300, eliminated[3].tick)
end

function test_placement_before_the_end_is_the_dead_teams_only()
    mock_game(100)
    round_of(4)
    Teams.eliminate('east')
    lunatest.assert_equal('east', joined(Teams.placement()), 'no winner yet')
    Teams.eliminate('west')
    lunatest.assert_equal('west,east', joined(Teams.placement()))
end

function test_the_first_silo_to_fall_ends_a_two_team_round()
    mock_game(4242)
    Teams.begin_round()
    lunatest.assert_equal(1, Teams.eliminate('north'))
    lunatest.assert_equal('south', Teams.winner())
    lunatest.assert_equal('south,north', joined(Teams.placement()))
    lunatest.assert_equal(4242, Teams.state().eliminated[1].tick)
end

function test_the_players_of_a_dead_team_are_remembered_until_the_next_round()
    -- The flag `gui.lua`'s `join_team` refuses on: their team choice is cleared
    -- when the team dies, so without it they could pick a living team.
    mock_game(100)
    round_of(4)
    lunatest.assert_false(Teams.is_player_eliminated('carl'))

    Teams.mark_player_eliminated('carl')
    Teams.mark_player_eliminated('dora')
    Teams.mark_player_eliminated('carl') -- twice is once
    lunatest.assert_true(Teams.is_player_eliminated('carl'))
    lunatest.assert_true(Teams.is_player_eliminated('dora'))
    lunatest.assert_false(Teams.is_player_eliminated('erik'))
    lunatest.assert_false(Teams.is_player_eliminated('Carl'), 'player names are compared as they are')

    -- The mark remembers the team when the caller gives it, so the round's
    -- result can still name the players of a team that died long ago.
    Teams.mark_player_eliminated('fred', 'east')
    lunatest.assert_true(Teams.is_player_eliminated('fred'))
    lunatest.assert_equal('east', Teams.state().eliminated_players['fred'])
    lunatest.assert_equal(true, Teams.state().eliminated_players['carl'], 'no team given: a plain mark')
    Teams.mark_player_eliminated('gina', 7)
    lunatest.assert_equal(true, Teams.state().eliminated_players['gina'], 'a team that is not a name is not kept')

    -- Nothing that is not a player name is recorded, and asking about one is
    -- false rather than an error: this is called on the join path.
    for _, bad in ipairs({ 0, true, {} }) do
        Teams.mark_player_eliminated(bad)
        lunatest.assert_false(Teams.is_player_eliminated(bad), tostring(bad))
    end
    Teams.mark_player_eliminated(nil)
    lunatest.assert_false(Teams.is_player_eliminated(nil))

    -- A new map is a clean slate, like the eliminations themselves.
    Teams.begin_round()
    lunatest.assert_false(Teams.is_player_eliminated('carl'))
    lunatest.assert_false(Teams.is_player_eliminated('dora'))
    lunatest.assert_false(Teams.is_player_eliminated('fred'))
end

function test_a_two_team_round_marks_nobody_because_nothing_calls_the_marker()
    -- Where the two-team guarantee actually lives: not in the registry, which
    -- has no count test of its own, but in its callers. The only writer is
    -- `eliminate_team` (game_over.lua:495-498), which a two-team round never
    -- reaches -- the first silo to fall ends the game -- and the only reader,
    -- `join_team` (gui.lua:1303), asks the question only above two teams.
    --
    -- So both halves are pinned here: a two-team round marks nobody, and a
    -- caller that did mark somebody would get a flag rather than a no-op. A
    -- future caller that forgets its count test is then a test failure and not
    -- a player silently refused their team.
    round_of(2)
    lunatest.assert_equal(0, #Teams.state().eliminated)
    lunatest.assert_nil(next(Teams.state().eliminated_players), 'nothing marked anybody')
    for _, name in ipairs({ 'carl', 'dora' }) do
        lunatest.assert_false(Teams.is_player_eliminated(name), name)
    end

    Teams.mark_player_eliminated('carl')

    lunatest.assert_true(Teams.is_player_eliminated('carl'), 'the registry itself is count-blind')
    lunatest.assert_false(Teams.is_player_eliminated('dora'))
    lunatest.assert_equal(0, #Teams.state().eliminated, 'a player is not a team')
    lunatest.assert_equal('north,south', joined(Teams.alive()), 'and no team left the round')

    -- Forgotten by the next map, as the eliminations are.
    round_of(2)
    lunatest.assert_false(Teams.is_player_eliminated('carl'))
    lunatest.assert_nil(next(Teams.state().eliminated_players))
end

function test_a_team_that_never_played_leaves_the_alive_set_but_is_not_ranked()
    -- `init.lua`'s `eliminate_teams_without_a_silo`: on the legacy map east and
    -- west get no silo, so a three- or four-team round starts without them.
    -- They are out, but they are not third and fourth -- they never played.
    mock_game(100)
    round_of(4)

    lunatest.assert_equal(3, Teams.eliminate('east', true))
    lunatest.assert_equal(2, Teams.eliminate('west', true))
    lunatest.assert_equal('north,south', joined(Teams.alive()))
    lunatest.assert_equal('north_biters,south_biters', joined(Teams.alive_biter_forces()))
    lunatest.assert_equal(0, #Teams.state().eliminated, 'nothing to rank yet')
    lunatest.assert_equal('', joined(Teams.placement()))

    -- What is left is an ordinary two-sided round, placed as one.
    game.tick = 200
    lunatest.assert_equal(1, Teams.eliminate('north'))
    lunatest.assert_equal('south', Teams.winner())
    lunatest.assert_equal('south,north', joined(Teams.placement()), 'only the teams that played')
end

function test_eliminating_a_team_that_never_played_does_not_read_the_tick()
    -- It is called from the map-generation path; nothing is timestamped, so
    -- there is nothing to read `game` for.
    mock_game(100)
    round_of(3)

    local saved_game = game
    game = nil
    lunatest.assert_equal(2, Teams.eliminate('east', true))
    game = saved_game

    lunatest.assert_equal('north,south', joined(Teams.alive()))
    lunatest.assert_equal(0, #Teams.state().eliminated)
end

function test_the_default_elimination_is_unchanged_by_the_new_option()
    mock_game(100)
    round_of(4)

    -- Every falsy second argument is today's call.
    lunatest.assert_equal(3, Teams.eliminate('east'))
    game.tick = 200
    lunatest.assert_equal(2, Teams.eliminate('west', false))
    game.tick = 300
    lunatest.assert_equal(1, Teams.eliminate('north', nil))

    lunatest.assert_equal('south,north,west,east', joined(Teams.placement()))
    local eliminated = Teams.state().eliminated
    lunatest.assert_equal(3, #eliminated)
    lunatest.assert_equal(100, eliminated[1].tick)
    lunatest.assert_equal(200, eliminated[2].tick)
    lunatest.assert_equal(300, eliminated[3].tick)
end

function test_eliminating_a_team_that_cannot_be_eliminated_changes_nothing()
    mock_game(100)
    round_of(3)

    lunatest.assert_equal(2, Teams.eliminate('east'))
    lunatest.assert_equal(1, #Teams.state().eliminated)

    game.tick = 200
    lunatest.assert_equal(2, Teams.eliminate('east'), 'already dead')
    lunatest.assert_equal(2, Teams.eliminate('west'), 'not playing this round')
    lunatest.assert_equal(2, Teams.eliminate('spectator'), 'not a team')
    lunatest.assert_equal(2, Teams.eliminate(nil))

    lunatest.assert_equal(1, #Teams.state().eliminated, 'nothing was recorded')
    lunatest.assert_equal(100, Teams.state().eliminated[1].tick)
    lunatest.assert_equal('north,south', joined(Teams.alive()))
    lunatest.assert_equal('east', joined(Teams.placement()))
end

-- ---------------------------------------------------------------------------
-- round_players(): the scoreboard keeps the players of a dead team
-- ---------------------------------------------------------------------------

local function count_keys(t)
    local n = 0
    for _ in pairs(t) do
        n = n + 1
    end
    return n
end

function test_round_players_is_the_choice_table_itself_at_two_teams()
    -- The very table: a two-team scoreboard iterates exactly what it did.
    local chosen = { ann = 'north', bob = 'south' }
    lunatest.assert_equal(chosen, Teams.round_players(chosen))
    round_of(2)
    lunatest.assert_equal(chosen, Teams.round_players(chosen))
    lunatest.assert_equal(0, count_keys(Teams.round_players(nil)))
end

function test_round_players_adds_the_eliminated_players_above_two_teams()
    round_of(3)
    local chosen = { ann = 'north', bob = 'south' }
    -- Nobody out yet: the table itself.
    lunatest.assert_equal(chosen, Teams.round_players(chosen))

    Teams.mark_player_eliminated('carl', 'east')
    Teams.mark_player_eliminated('dora', true) -- a mark without a team adds nobody
    Teams.mark_player_eliminated('ann', 'east') -- a live choice wins over a mark
    local merged = Teams.round_players(chosen)
    lunatest.assert_false(merged == chosen, 'a fresh table')
    lunatest.assert_equal('north', merged.ann)
    lunatest.assert_equal('south', merged.bob)
    lunatest.assert_equal('east', merged.carl)
    lunatest.assert_nil(merged.dora)
    lunatest.assert_equal(3, count_keys(merged))
    lunatest.assert_equal(2, count_keys(chosen), 'the choice table is not written')
end

function test_display_name_can_name_a_team_as_another_layout_would()
    -- "Show previous game" of a two-team game, on a four-square round today.
    round_of(4)
    lunatest.assert_equal('Top Left', Teams.display_name('north'))
    lunatest.assert_equal('Team North', Teams.display_name('north', 'horizontal2'))
    lunatest.assert_equal('Team South', Teams.display_name('south', 'horizontal2'))
    round_of(2)
    lunatest.assert_equal('Team North', Teams.display_name('north'))
    lunatest.assert_equal('Top Left', Teams.display_name('north', 'cross4'))
    lunatest.assert_equal('Bottom Right', Teams.display_name('south', 'cross4'))
    storage.tm_custom_name = { north = 'Blue Crew' }
    lunatest.assert_equal('Blue Crew', Teams.display_name('north', 'cross4'), 'a custom name still wins')
end

lunatest.run()
