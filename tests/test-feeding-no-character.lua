---@diagnostic disable
-- A player with NO CHARACTER clicking a feed button.
--
-- Seen in production on 2026-09-20 at four teams, as a caught error repeating
-- in bursts: `feeding.lua: attempt to index field 'character' (a nil value)`.
-- The two inventory entry points read `player.character.get_main_inventory()`
-- with no guard, and a player can be characterless in ordinary play: a
-- spectator of a team that was eliminated, and anyone waiting to respawn --
-- which is why this is an UPSTREAM defect, present at two teams in the
-- baseline (`81c1d12f`, same two lines) and merely made easy to reach by the
-- elimination step of a three- or four-team round.
--
-- The functions cannot be loaded without the Factorio API, so the API they use
-- on the way to the guard is stubbed here, and nothing else: what is pinned is
-- that a characterless player is TOLD why nothing happened and that the
-- function returns without raising.
local lunatest = require('lunatest')

storage = { ['_TEST'] = true }

defines = {
    events = {},
    inventory = { character_main = 1 },
    mouse_button_type = { left = 2, right = 4 },
    direction = {},
    controllers = { spectator = 1, character = 2 },
}
package.loaded['utils.event'] = { add = function() end, on_nth_tick = function() end }
commands = { add_command = function() end }
package.loaded['utils.server'] = { to_discord_embed = function() end, to_discord_bold = function() end }

local Feeding = require('maps.biter_battles_v2.feeding')
local Teams = require('maps.biter_battles_v2.teams')

--- A player who is on a team, may send, and has no character.
local function characterless_player()
    local printed = {}
    return {
        name = 'ghost',
        index = 7,
        character = nil,
        force = { name = 'north', index = 2 },
        color = { r = 1, g = 1, b = 1 },
        print = function(_, message)
            printed[#printed + 1] = type(message) == 'table' and (message[1] or '?') or tostring(message)
        end,
        printed = printed,
    }
end

function setup()
    storage = { ['_TEST'] = true }
    storage.difficulty_votes_timeout = -1
    storage.active_special_games = {}
    storage.bb_settings = { science_send_score_restriction = false }
    Teams.set_next_count(4)
    Teams.begin_round()
end

function test_a_player_without_a_character_is_told_instead_of_raising()
    local player = characterless_player()
    local ok, err = pcall(Feeding.feed_biters_from_inventory, player, 'automation-science-pack')
    lunatest.assert_true(ok, 'feed_biters_from_inventory raised: ' .. tostring(err))
    lunatest.assert_true(#player.printed > 0, 'the player is told why nothing happened')
end

function test_the_mixed_send_of_a_player_without_a_character_does_not_raise()
    local player = characterless_player()
    local ok, err = pcall(Feeding.feed_biters_mixed_from_inventory, player, defines.mouse_button_type.left)
    lunatest.assert_true(ok, 'feed_biters_mixed_from_inventory raised: ' .. tostring(err))
    lunatest.assert_true(#player.printed > 0, 'the player is told why nothing happened')
end

lunatest.run()
