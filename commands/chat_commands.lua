local Server = require('utils.server')
local Muted = require('utils.muted')
local String = require('utils.string')
local Event = require('utils.event')
local Functions = require('maps.biter_battles_v2.functions')
local Teams = require('maps.biter_battles_v2.teams')

local Public = {}

local function chat_with_team(message, team)
    local player = game.player
    if player and player.valid then
        local player_name = player.name

        local tag = player.tag
        if not tag then
            tag = ''
        else
            tag = ' ' .. tag
        end
        local color = player.chat_color

        -- Drop messages with gps tag not meant for spectators.
        local sane_msg = String.sanitize_gps_tags(message)
        if String.has_sanitized_gps_tag(sane_msg) and team ~= 'spectator' then
            player.print('A message with GPS tag is not allowed')
            return
        end

        local preamble = '[To ' .. team .. '] ' .. player_name .. tag .. ' (' .. player.force.name .. '): '
        local msg = preamble .. message
        if not Muted.is_muted(player_name) then
            Functions.print_message_to_players(
                game.forces.spectator.connected_players,
                player_name,
                msg,
                color,
                do_ping
            )
            -- Spectators above, then the playing teams in round order, each one
            -- hearing the message when it is the addressee or the sender's own
            -- force: at two teams that is today's north block then south block.
            for _, name in ipairs(Teams.all()) do
                if team == name or player.force.name == name then
                    Functions.print_message_to_players(
                        game.forces[name].connected_players,
                        player_name,
                        msg,
                        color,
                        do_ping
                    )
                end
            end
        else
            Muted.print_muted_message(player)
        end

        -- Do not pass messages to discord with just a GPS ping to avoid spam.
        if String.only_sanitized_gps_tag(sane_msg) then
            return
        end

        msg = preamble .. sane_msg
        if Muted.is_muted(player_name) then
            msg = '[muted] ' .. msg
        end

        Server.to_discord_player_chat(msg)
    end
end

--- The teams whose chat commands every build of this scenario has always had,
--- in the order `commands.add_command` was called for them before teams became
--- a parameter (`git show 56ee520b:commands/chat_commands.lua`): `/sth`,
--- `/south-chat`, `/nth`, `/north-chat`.
---
--- This literal list IS the compatibility contract -- a two-team server's
--- `/help`, and the completion list a player gets from typing `/`, must read
--- exactly as they always did -- so it is spelled out here rather than derived
--- from `Teams.roster()`, which would hand four commands for teams that are not
--- playing to a game that never plays them.
---@type string[]
local LEGACY_CHAT_TEAMS = { 'south', 'north' }

---@type table<string, true>
local LEGACY_CHAT_TEAM = {}
for _, team in ipairs(LEGACY_CHAT_TEAMS) do
    LEGACY_CHAT_TEAM[team] = true
end

--- The pair of commands a team is addressed with: the short alias, first letter
--- plus 'th' (`/nth`, `/sth`, and so `/eth`, `/wth`), and the long `<team>-chat`
--- -- the four names of today spelled out of the team name instead of quoted.
---
--- The short name comes first, which is the order the legacy file called
--- `commands.add_command` in and so the order `commands.commands` is built in.
---@param team string
---@return { name: string, help: string }[] pair
local function team_chat_pair(team)
    local short_name = team:sub(1, 1) .. 'th'
    local long_name = team .. '-chat'
    return {
        { name = short_name, help = 'Chat with ' .. team .. '. Same as /' .. long_name },
        { name = long_name, help = 'Chat with ' .. team .. '. You can also use /' .. short_name },
    }
end

---The whole team-chat registration plan, in registration order: the legacy
---pairs first, then the pair of every other roster team -- the ones only a
---round of more than two teams ever registers.
---
---Pure, and the single source of the names and help strings
---`add_team_chat_commands` hands to `commands.add_command`, so that the two
---cannot drift; `tests/test-chat-commands.lua` pins it against the command
---surface the module actually registers.
---@return { name: string, help: string, team: string, legacy: boolean }[]
function Public.command_plan()
    local plan = {}
    local function append(team, legacy)
        for _, command in ipairs(team_chat_pair(team)) do
            plan[#plan + 1] = { name = command.name, help = command.help, team = team, legacy = legacy }
        end
    end
    for _, team in ipairs(LEGACY_CHAT_TEAMS) do
        append(team, true)
    end
    for _, team in ipairs(Teams.roster()) do
        if not LEGACY_CHAT_TEAM[team] then
            append(team, false)
        end
    end
    return plan
end

--- The names this module has already handed to `commands.add_command`, which
--- raises on a duplicate: `register_extra_team_chat()` runs again on every reset
--- of a round of more than two teams, and on a load of such a save.
---@type table<string, true>
local registered = {}

--- A command exists from the moment it is registered, when the round's team
--- count may still change, so a team that turns out not to be playing says so
--- rather than chat to a force nobody is on.
---@param team string
local function add_team_chat_commands(team)
    local pair = team_chat_pair(team)
    local short_name, long_name = pair[1].name, pair[2].name

    ---@return boolean playing True when the team is in this round.
    local function playing()
        if Teams.is_active(team) then
            return true
        end
        local player = game.player
        if player and player.valid then
            player.print('Team ' .. team .. ' is not playing this round')
        end
        return false
    end

    if not registered[short_name] then
        registered[short_name] = true
        commands.add_command(short_name, pair[1].help, function(cmd)
            if not playing() then
                return
            end
            local message = tostring(cmd.parameter)
            chat_with_team(message, team)
        end)
    end

    if not registered[long_name] then
        registered[long_name] = true
        commands.add_command(long_name, pair[2].help, function(cmd)
            if not playing() then
                return
            end
            game.player.print('System: You can also you /' .. short_name)
            local message = tostring(cmd.parameter)
            chat_with_team(message, team)
        end)
    end
end

---Register the chat commands of the roster teams outside the legacy pair --
---`/eth`, `/east-chat`, `/wth`, `/west-chat`. Idempotent: a name that is
---already registered is skipped, because `commands.add_command` raises on a
---duplicate and this runs again on every later reset and on every load.
---
---Every peer has to end up with the same command list. The reset path calls
---this right after `Teams.begin_round()`, and a map reset runs in the same tick
---on the server and on every client that is connected, so they all register
---together; a client that joins afterwards never runs that reset and registers
---from `on_load` below instead.
function Public.register_extra_team_chat()
    for _, team in ipairs(Teams.roster()) do
        if not LEGACY_CHAT_TEAM[team] then
            add_team_chat_commands(team)
        end
    end
end

for _, team in ipairs(LEGACY_CHAT_TEAMS) do
    add_team_chat_commands(team)
end

commands.add_command('spectator-chat', 'Chat with spectators.', function(cmd)
    local message = tostring(cmd.parameter)
    chat_with_team(message, 'spectator')
end)

-- The other half of the "same command list on every peer" rule: a client that
-- loads a save in which a round of more than two teams has already begun.
-- `on_load` may read `storage` but not write it and has no `game`, which is why
-- the latch is read through `Teams.extra_chat_commands()` -- a defensive read of
-- `storage.bb_teams` that creates no state. A two-team save has no latch, reads
-- false and registers nothing.
--
-- The handler itself is added at module load, on every peer, so the set of
-- registered handlers is the same everywhere; it is an `on_load` handler, which
-- lives in its own list, so the order of the `defines.events` handlers is
-- untouched.
Event.on_load(function()
    if Teams.extra_chat_commands() then
        Public.register_extra_team_chat()
    end
end)

return Public
