---@diagnostic disable
--
-- Pins the command surface of `commands/chat_commands.lua`: which names it
-- hands to `commands.add_command`, in which order, and with which help strings.
--
-- Why this suite exists: the command list of a two-team server is part of the
-- "nothing changes at two teams" contract, and nothing in the in-game harness
-- looks at it. A build that registered the chat commands of the whole roster
-- gave every two-team game four commands it never had (`/eth`, `/east-chat`,
-- `/wth`, `/west-chat`) and reordered the four it did have, and no test noticed.
-- So the two-team surface is spelled out below, byte for byte, in order:
--
--     sth, south-chat, nth, north-chat, spectator-chat
--
-- The commands of the other roster teams are registered lazily, the first time
-- a round of more than two teams begins in a save, and again on `on_load` for a
-- client that joins such a save later.
--
-- The module is a Factorio module: it calls `commands.add_command` at load and
-- its requires reach for `script` and `defines`. Everything it needs at load is
-- stubbed here -- the stubs are only ever touched by a command body, and no
-- test runs one -- so that the registration itself can be observed. `teams.lua`
-- is the real module; it loads outside Factorio.

local lunatest = require('lunatest')

storage = { ['_TEST'] = true }

--- Every name handed to `commands.add_command`, in call order, and its help
--- string. `add_command` raises on a duplicate name in Factorio, so the stub
--- does too: that is what makes the idempotence of `register_extra_team_chat()`
--- testable rather than a claim.
local order = {}
local help_of = {}

commands = {
    add_command = function(name, help, handler)
        if help_of[name] ~= nil then
            error('command already registered: ' .. tostring(name), 2)
        end
        help_of[name] = help
        order[#order + 1] = name
    end,
}

--- The handlers `Event.on_load` was given, in registration order.
local on_load_handlers = {}

package.loaded['utils.server'] = { to_discord_player_chat = function() end }
package.loaded['utils.muted'] = {
    is_muted = function()
        return false
    end,
    print_muted_message = function() end,
}
package.loaded['utils.string'] = {
    sanitize_gps_tags = function(message)
        return message
    end,
    has_sanitized_gps_tag = function()
        return false
    end,
    only_sanitized_gps_tag = function()
        return false
    end,
}
package.loaded['maps.biter_battles_v2.functions'] = { print_message_to_players = function() end }
package.loaded['utils.event'] = {
    on_load = function(handler)
        on_load_handlers[#on_load_handlers + 1] = handler
    end,
}

local ChatCommands = require('commands.chat_commands')
local Teams = require('maps.biter_battles_v2.teams')

--- The surface at load, frozen before any test can add to it: the module is
-- required once for the whole file, so `order` keeps growing as tests register
-- the extra pairs. Every assertion below is written against this snapshot or
-- against the full surface, both of which are the same whatever order lunatest
-- walks the tests in.
local AT_LOAD = {}
for i, name in ipairs(order) do
    AT_LOAD[i] = name
end

local LEGACY_SURFACE = 'sth,south-chat,nth,north-chat,spectator-chat'
local FULL_SURFACE = LEGACY_SURFACE .. ',eth,east-chat,wth,west-chat'

local function joined(array)
    return table.concat(array, ',')
end

local function surface()
    return joined(order)
end

local function plan_names()
    local names = {}
    for i, entry in ipairs(ChatCommands.command_plan()) do
        names[i] = entry.name
    end
    return joined(names)
end

function setup()
    storage = { ['_TEST'] = true }
end

-- ---------------------------------------------------------------------------
-- The two-team surface: exactly today's, in today's order
-- ---------------------------------------------------------------------------

function test_a_two_team_server_registers_exactly_the_four_legacy_names()
    -- The order `git show 56ee520b:commands/chat_commands.lua` registered them
    -- in, which is the order `commands.commands` is built in and `/help` lists.
    lunatest.assert_equal(LEGACY_SURFACE, joined(AT_LOAD))
end

function test_the_legacy_help_strings_are_byte_for_byte_the_old_ones()
    lunatest.assert_equal('Chat with south. Same as /south-chat', help_of['sth'])
    lunatest.assert_equal('Chat with south. You can also use /sth', help_of['south-chat'])
    lunatest.assert_equal('Chat with north. Same as /north-chat', help_of['nth'])
    lunatest.assert_equal('Chat with north. You can also use /nth', help_of['north-chat'])
    lunatest.assert_equal('Chat with spectators.', help_of['spectator-chat'])
end

function test_no_command_of_a_team_that_never_plays_is_registered_at_load()
    for _, name in ipairs({ 'eth', 'east-chat', 'wth', 'west-chat' }) do
        for _, at_load in ipairs(AT_LOAD) do
            lunatest.assert_not_equal(name, at_load, name .. ' must not exist on a two-team server')
        end
    end
end

-- ---------------------------------------------------------------------------
-- The registration plan
-- ---------------------------------------------------------------------------

function test_the_plan_lists_the_legacy_pairs_first_then_the_rest_of_the_roster()
    lunatest.assert_equal('sth,south-chat,nth,north-chat,eth,east-chat,wth,west-chat', plan_names())

    local plan = ChatCommands.command_plan()
    lunatest.assert_equal(8, #plan)
    for i = 1, 4 do
        lunatest.assert_true(plan[i].legacy, plan[i].name .. ' is one of the four legacy commands')
    end
    for i = 5, 8 do
        lunatest.assert_false(plan[i].legacy, plan[i].name .. ' is registered lazily')
    end
    local teams = {}
    for i, entry in ipairs(plan) do
        teams[i] = entry.team
    end
    lunatest.assert_equal('south,south,north,north,east,east,west,west', joined(teams))
end

function test_the_plan_is_what_was_registered()
    -- One source for the names and the help strings: a plan that drifted from
    -- the registration would make this suite pass while /help changed.
    for _, entry in ipairs(ChatCommands.command_plan()) do
        if entry.legacy then
            lunatest.assert_equal(entry.help, help_of[entry.name], entry.name)
        end
    end
end

function test_the_plan_does_not_depend_on_the_round()
    lunatest.assert_true(Teams.set_next_count(4))
    Teams.begin_round()
    lunatest.assert_equal('sth,south-chat,nth,north-chat,eth,east-chat,wth,west-chat', plan_names())

    lunatest.assert_true(Teams.set_next_count(2))
    Teams.begin_round()
    lunatest.assert_equal('sth,south-chat,nth,north-chat,eth,east-chat,wth,west-chat', plan_names())
end

-- ---------------------------------------------------------------------------
-- The extra pairs
-- ---------------------------------------------------------------------------

function test_the_extra_pairs_are_appended_when_a_bigger_round_asks_for_them()
    ChatCommands.register_extra_team_chat()

    lunatest.assert_equal(FULL_SURFACE, surface())
    lunatest.assert_equal('Chat with east. Same as /east-chat', help_of['eth'])
    lunatest.assert_equal('Chat with east. You can also use /eth', help_of['east-chat'])
    lunatest.assert_equal('Chat with west. Same as /west-chat', help_of['wth'])
    lunatest.assert_equal('Chat with west. You can also use /wth', help_of['west-chat'])
end

function test_registering_them_again_adds_nothing()
    -- Called from every later reset and from on_load; the stub would raise on a
    -- duplicate, as Factorio does.
    ChatCommands.register_extra_team_chat()
    local after_first = #order
    ChatCommands.register_extra_team_chat()
    ChatCommands.register_extra_team_chat()

    lunatest.assert_equal(after_first, #order)
    lunatest.assert_equal(FULL_SURFACE, surface())
end

-- ---------------------------------------------------------------------------
-- The on_load hook: a client that joins a save that already grew them
-- ---------------------------------------------------------------------------

function test_exactly_one_on_load_handler_is_registered_at_module_load()
    -- At module load, on every peer: the handler set is the same everywhere,
    -- and it is an on_load handler, so no `defines.events` handler moves.
    lunatest.assert_equal(1, #on_load_handlers)
end

function test_a_two_team_save_registers_nothing_on_load()
    local before = #order
    on_load_handlers[1]()
    lunatest.assert_equal(before, #order, 'no round state at all')
    lunatest.assert_nil(storage.bb_teams, 'on_load created no state')

    Teams.begin_round()
    local after_round = #order
    on_load_handlers[1]()
    lunatest.assert_equal(after_round, #order, 'a two-team round keeps the legacy list')
    lunatest.assert_nil(storage.bb_teams.extra_chat_commands)
end

function test_a_save_that_once_had_more_teams_registers_them_on_load()
    lunatest.assert_true(Teams.set_next_count(3))
    Teams.begin_round()
    lunatest.assert_true(Teams.extra_chat_commands())

    on_load_handlers[1]()
    lunatest.assert_equal(FULL_SURFACE, surface())

    -- The latch survives a round that is two teams again, so the command list
    -- of that save does too -- a command cannot be unregistered.
    lunatest.assert_true(Teams.set_next_count(2))
    Teams.begin_round()
    lunatest.assert_true(Teams.extra_chat_commands())
    on_load_handlers[1]()
    lunatest.assert_equal(FULL_SURFACE, surface())
end

lunatest.run()
