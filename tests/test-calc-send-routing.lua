---@diagnostic disable
--
-- Pins the ROUTING of `/calc-send`, i.e. which biter force
-- `feeding_calculations.calc_send_command` prices a send against
-- (feeding_calculations.lua:104-123, 211-216).
--
-- The gap this file closes: the tests pinned the curves but never the routing
-- (north's send lands on `south_biters`). The curves stay
-- where they are — `tests/test-feeding.lua` owns those, and nothing here
-- repeats one of its assertions.
--
-- How the routing is read back: `calc_send_command` echoes the evolution it
-- used in its first line. Giving the two biter forces distinct evolutions makes
-- that number a name, so `target_of()` can report which force the command chose
-- without asserting anything about the feeding curves.
--
-- `player` is a one-field stub: only `player.force.name` is reached, because
-- every call below names a colour and a count and so never falls through to the
-- `player.character.get_main_inventory()` branch at feeding_calculations.lua:201.
-- No Factorio global is faked.

local lunatest = require('lunatest')

-- calc_send_command reads storage.tt_mode (the white-science x3), and
-- feeding_params reads storage.feeding_params; an empty table is the "nothing
-- overridden" case.
storage = { ['_TEST'] = true }

local FeedingCalculations = require('maps.biter_battles_v2.feeding_calculations')

local DIFFICULTY_VOTE_VALUE = 0.3
local MAX_REANIM_THRESH = 250
local PLAYER_COUNT = 4

-- Deliberately distinct, and neither is a round percentage of the other.
local BB_EVOLUTION = { ['north_biters'] = 0.11, ['south_biters'] = 0.22 }
local BITER_FORCE_OF_ECHOED_EVO = { ['11.0'] = 'north_biters', ['22.0'] = 'south_biters' }

local HELP_TEXT = '\nUsage: /calc-send evo=20.0 difficulty=30 players=4 color=green count=1000'
    .. '\nUsage: /calc-send force=north color=white count=1000'

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

---The biter force the command priced the send against, or — when it refused to
---route at all — the first line of the error it returned instead.
---@param output string
---@return string
local function target_of(output)
    local echoed_evo = output:match('^/calc%-send evo=([%d%.]+) ')
    if not echoed_evo then
        return (output:gsub('\nUsage:.*$', ''))
    end
    return BITER_FORCE_OF_ECHOED_EVO[echoed_evo] or ('evo=' .. echoed_evo)
end

-- ---------------------------------------------------------------------------
-- Routing derived from the sender
-- ---------------------------------------------------------------------------

function test_a_north_senders_send_is_priced_against_south_biters()
    lunatest.assert_equal('south_biters', target_of(send('color=green count=1000', { force_name = 'north' })))
end

function test_a_south_senders_send_is_priced_against_north_biters()
    lunatest.assert_equal('north_biters', target_of(send('color=green count=1000', { force_name = 'south' })))
end

function test_training_mode_routes_a_send_back_at_the_senders_own_team()
    lunatest.assert_equal(
        'north_biters',
        target_of(send('color=green count=1000', { force_name = 'north', training_mode = true }))
    )
    lunatest.assert_equal(
        'south_biters',
        target_of(send('color=green count=1000', { force_name = 'south', training_mode = true }))
    )
end

function test_a_sender_on_neither_team_gets_no_default_target()
    -- The branch is `== 'north'` / `== 'south'` and nothing else
    -- (feeding_calculations.lua:106-110), so a spectator — and, after the
    -- N-team work, any player on team 3 or 4 — has to type an evo or a force.
    for _, force_name in ipairs({ 'spectator', 'player', 'east', 'west' }) do
        lunatest.assert_equal(
            'Must specify evo (or force)',
            target_of(send('color=green count=1000', { force_name = force_name })),
            force_name
        )
    end
end

function test_without_a_sender_and_without_a_force_there_is_no_target()
    lunatest.assert_equal('Must specify evo (or force)', target_of(send('color=green count=1000')))
    lunatest.assert_equal(
        'Must specify evo (or force)',
        target_of(send('color=green count=1000', { training_mode = true }))
    )
end

function test_an_explicit_evo_needs_no_target_at_all()
    -- The one escape hatch a third team already has today.
    lunatest.assert_equal('evo=50.0', target_of(send('evo=50 color=green count=1000', { force_name = 'east' })))
    lunatest.assert_equal('evo=50.0', target_of(send('evo=50 color=green count=1000')))
end

-- ---------------------------------------------------------------------------
-- The `force=` argument
-- ---------------------------------------------------------------------------

function test_force_accepts_exactly_three_spellings_per_team()
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

function test_force_refuses_every_other_value_with_a_hard_error()
    -- Not ignored, not defaulted: parsing stops and the command returns
    -- "Invalid force" plus the usage text. Pinned as found — the interesting
    -- cases are 'east'/'west', which a team registry would have to start
    -- accepting, and the capitalised spellings, which are refused today because
    -- the comparison is case-sensitive.
    for _, spelling in ipairs({ 'east', 'west', 'e', 'w', 'nor', 'sou', 'North', 'NORTH', 'north_biters', '1' }) do
        lunatest.assert_equal(
            'Invalid force',
            target_of(send('force=' .. spelling .. ' color=green count=1000')),
            spelling
        )
    end
    -- The whole message, once.
    lunatest.assert_equal('Invalid force' .. HELP_TEXT, send('force=east color=green count=1000'))
end

function test_force_east_is_refused_even_when_an_evo_was_given()
    -- The refusal is a hard stop on the whole command, wherever `force=` sits
    -- in the line and whether or not the rest of it would have been enough.
    lunatest.assert_equal('Invalid force', target_of(send('force=east evo=50 color=green count=1000')))
    lunatest.assert_equal('Invalid force', target_of(send('evo=50 color=green count=1000 force=east')))
    lunatest.assert_equal(
        'Invalid force',
        target_of(send('force=east color=green count=1000', { force_name = 'north' }))
    )
end

function test_force_overrides_the_routing_the_sender_would_have_got()
    -- A north player can price a send against their own biters, and `force=`
    -- beats training mode too.
    lunatest.assert_equal(
        'north_biters',
        target_of(send('force=north color=green count=1000', { force_name = 'north' }))
    )
    lunatest.assert_equal(
        'south_biters',
        target_of(send('force=south color=green count=1000', { force_name = 'north', training_mode = true }))
    )
end

lunatest.run()
