---@diagnostic disable
--
-- Pins the ROUTING of `/calc-send` above two teams, i.e. which biter force
-- `feeding_calculations.calc_send_command` prices a send against once the round
-- has three or four teams.
--
-- `tests/test-calc-send-routing.lua` is the two-team half of this and stays
-- exactly as it was: everything it pins -- north -> south, `force=east` refused,
-- the help text -- has to keep holding, and it does, because the round this file
-- builds is the only thing that differs. The curves belong to
-- `tests/test-feeding.lua`; nothing here repeats one of their assertions.
--
-- How the routing is read back, as in the two-team file: `calc_send_command`
-- echoes the evolution it used in its first line, so four distinct evolutions
-- turn that number into the name of the force that was priced.
--
-- `player` is a one-field stub: only `player.force.name` is reached, because
-- every call below names a colour and a count and so never falls through to the
-- `player.character.get_main_inventory()` branch. `game` is faked only where
-- `Teams.eliminate` needs a tick.

local lunatest = require('lunatest')

storage = { ['_TEST'] = true }

local FeedingCalculations = require('maps.biter_battles_v2.feeding_calculations')
local Teams = require('maps.biter_battles_v2.teams')

local DIFFICULTY_VOTE_VALUE = 0.3
local MAX_REANIM_THRESH = 250
local PLAYER_COUNT = 4

-- One evolution per team of a four-team round, all distinct and none a round
-- percentage of another.
local BB_EVOLUTION = {
    ['north_biters'] = 0.11,
    ['east_biters'] = 0.33,
    ['south_biters'] = 0.22,
    ['west_biters'] = 0.44,
}
local BITER_FORCE_OF_ECHOED_EVO = {
    ['11.0'] = 'north_biters',
    ['33.0'] = 'east_biters',
    ['22.0'] = 'south_biters',
    ['44.0'] = 'west_biters',
}

-- Byte for byte the help text of the two-team game (and of today's code).
local HELP_TEXT = '\nUsage: /calc-send evo=20.0 difficulty=30 players=4 color=green count=1000'
    .. '\nUsage: /calc-send force=north color=white count=1000'

function setup()
    storage = { ['_TEST'] = true }
    game = nil
end

---@param params string the text typed after /calc-send
---@param opts table|nil { force_name = string|nil, training_mode = boolean|nil }
---@return string
local function send(params, opts)
    opts = opts or {}
    local player = opts.force_name and { force = { name = opts.force_name } } or nil
    return FeedingCalculations.calc_send_command(
        params,
        DIFFICULTY_VOTE_VALUE,
        BB_EVOLUTION,
        MAX_REANIM_THRESH,
        opts.training_mode or false,
        PLAYER_COUNT,
        player
    )
end

---The biter force the command priced the send against, or -- when it refused to
---route at all -- the first line of the error it returned instead.
---@param output string
---@return string
local function target_of(output)
    local echoed_evo = output:match('^/calc%-send evo=([%d%.]+) ')
    if not echoed_evo then
        return (output:gsub('\nUsage:.*$', ''))
    end
    return BITER_FORCE_OF_ECHOED_EVO[echoed_evo] or ('evo=' .. echoed_evo)
end

---Ask for `count` teams and start the round.
local function round_of(count)
    lunatest.assert_true(Teams.set_next_count(count), 'set_next_count(' .. tostring(count) .. ')')
    Teams.begin_round()
end

-- ---------------------------------------------------------------------------
-- The default target above two teams
-- ---------------------------------------------------------------------------

function test_a_split_send_has_no_single_target_to_price()
    -- Four teams, the default 'split' policy: north feeds three enemies at once,
    -- so there is no one evolution to price the send against and the command
    -- asks for `force=` with today's message.
    round_of(4)
    for _, force_name in ipairs({ 'north', 'east', 'south', 'west' }) do
        lunatest.assert_equal(
            'Must specify evo (or force)',
            target_of(send('color=green count=1000', { force_name = force_name })),
            force_name
        )
    end
end

function test_three_teams_also_refuse_a_default_target()
    round_of(3)
    lunatest.assert_equal(
        'Must specify evo (or force)',
        target_of(send('color=green count=1000', { force_name = 'north' }))
    )
end

function test_a_one_target_policy_keeps_its_default()
    -- 'ring' sends to the next alive team clockwise, one target with share 1, so
    -- the command can price it without being told which.
    round_of(4)
    Teams.state().feed_policy = 'ring'
    lunatest.assert_equal('east_biters', target_of(send('color=green count=1000', { force_name = 'north' })))
    lunatest.assert_equal('south_biters', target_of(send('color=green count=1000', { force_name = 'east' })))
    lunatest.assert_equal('north_biters', target_of(send('color=green count=1000', { force_name = 'west' })))
end

function test_the_last_enemy_left_is_a_default_target_again()
    -- Three teams, two of them eliminated: the survivor has exactly one enemy,
    -- so a split send is a single send and prices itself.
    game = { tick = 1 }
    round_of(3)
    Teams.eliminate('north')
    lunatest.assert_equal('south_biters', target_of(send('color=green count=1000', { force_name = 'east' })))
    lunatest.assert_equal('east_biters', target_of(send('color=green count=1000', { force_name = 'south' })))
end

function test_training_mode_still_routes_a_send_back_at_the_senders_own_team()
    round_of(4)
    lunatest.assert_equal(
        'east_biters',
        target_of(send('color=green count=1000', { force_name = 'east', training_mode = true }))
    )
    lunatest.assert_equal(
        'west_biters',
        target_of(send('color=green count=1000', { force_name = 'west', training_mode = true }))
    )
end

function test_a_sender_on_no_team_still_gets_no_default_target()
    round_of(4)
    for _, force_name in ipairs({ 'spectator', 'player' }) do
        lunatest.assert_equal(
            'Must specify evo (or force)',
            target_of(send('color=green count=1000', { force_name = force_name })),
            force_name
        )
    end
end

-- ---------------------------------------------------------------------------
-- The `force=` argument
-- ---------------------------------------------------------------------------

function test_force_accepts_the_same_three_spellings_for_the_two_new_teams()
    round_of(4)
    for _, spelling in ipairs({ 'e', 'eth', 'east' }) do
        lunatest.assert_equal(
            'east_biters',
            target_of(send('force=' .. spelling .. ' color=green count=1000')),
            spelling
        )
    end
    for _, spelling in ipairs({ 'w', 'wth', 'west' }) do
        lunatest.assert_equal(
            'west_biters',
            target_of(send('force=' .. spelling .. ' color=green count=1000')),
            spelling
        )
    end
end

function test_force_still_accepts_the_two_old_teams()
    round_of(4)
    for _, spelling in ipairs({ 'n', 'nth', 'north' }) do
        lunatest.assert_equal(
            'north_biters',
            target_of(send('force=' .. spelling .. ' color=green count=1000')),
            spelling
        )
    end
    for _, spelling in ipairs({ 's', 'sth', 'south' }) do
        lunatest.assert_equal(
            'south_biters',
            target_of(send('force=' .. spelling .. ' color=green count=1000')),
            spelling
        )
    end
end

function test_force_names_only_a_team_that_plays_this_round()
    -- Three teams is north, east, south: west does not play and is refused
    -- exactly as east is in a two-team game.
    round_of(3)
    for _, spelling in ipairs({ 'w', 'wth', 'west' }) do
        lunatest.assert_equal(
            'Invalid force',
            target_of(send('force=' .. spelling .. ' color=green count=1000')),
            spelling
        )
    end
    lunatest.assert_equal('east_biters', target_of(send('force=east color=green count=1000')))
end

function test_the_new_spellings_are_refused_again_once_the_round_is_two_teams()
    -- A round of four inside the same save, then a round of two: what `force=`
    -- accepts follows the round, so the two-team game is today's game again.
    round_of(4)
    lunatest.assert_equal('east_biters', target_of(send('force=east color=green count=1000')))
    round_of(2)
    for _, spelling in ipairs({ 'e', 'eth', 'east', 'w', 'wth', 'west' }) do
        lunatest.assert_equal(
            'Invalid force',
            target_of(send('force=' .. spelling .. ' color=green count=1000')),
            spelling
        )
    end
    lunatest.assert_equal('south_biters', target_of(send('color=green count=1000', { force_name = 'north' })))
end

function test_force_refuses_every_other_value_above_two_teams_too()
    round_of(4)
    for _, spelling in ipairs({ 'nor', 'eas', 'East', 'EAST', 'east_biters', 'ne', '1' }) do
        lunatest.assert_equal(
            'Invalid force',
            target_of(send('force=' .. spelling .. ' color=green count=1000')),
            spelling
        )
    end
    -- The whole message, once.
    lunatest.assert_equal('Invalid force' .. HELP_TEXT, send('force=nor color=green count=1000'))
end

-- ---------------------------------------------------------------------------
-- The help text
-- ---------------------------------------------------------------------------

function test_the_help_text_is_the_same_whatever_the_team_count()
    for _, count in ipairs({ 2, 3, 4 }) do
        round_of(count)
        lunatest.assert_equal(
            'Must specify evo (or force)' .. HELP_TEXT,
            send('color=green count=1000'),
            'teams=' .. count
        )
    end
end

lunatest.run()
