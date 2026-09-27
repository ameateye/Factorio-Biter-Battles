-- `/team-count` and the `bb_teams` remote interface: the handshake the League
-- daemon uses to pick how many teams the next round is played with. The
-- scenario never decides the count by itself -- the lobby vote does, the daemon
-- relays it, and this file is the only way in.
--
-- Nothing here changes the running round. `Teams.set_next_count(n)` records a
-- request and no more; `Teams.begin_round()`, the first statement of
-- `Init.tables()`, is what turns it into the round's count. So a change always
-- lands on a map reset and no per-team table is ever resized while a round is
-- reading it.
--
-- The command and the interface are registered here at load time, during the
-- control stage, so that every peer has both from the first tick -- which is
-- also why this file is required from `commands.lua` rather than created on
-- demand (`control.lua` replaces `require` with a lookup once the control stage
-- is over).
--
-- The interface also carries the attack-clock switch (`attack_clock.lua`),
-- which is the other thing the operator side sets from outside the game and
-- has, like the team count, no command and no GUI. Unlike the team count it
-- takes effect at the next attack cycle rather than at the next map reset.

local AttackClock = require('maps.biter_battles_v2.attack_clock')
local CaptainVote = require('maps.biter_battles_v2.captain_vote')
local Color = require('utils.color_presets')
local CountVote = require('maps.biter_battles_v2.count_vote')
local LeagueState = require('maps.biter_battles_v2.league_state')
local Teams = require('maps.biter_battles_v2.teams')

local Public = {}

---Answer whoever asked. A player sees it in chat; a caller with no player --
---the League daemon, which runs this over RCON -- gets it back on its own
---connection. `rcon` is guarded because it does not exist in every host.
---@param player LuaPlayer|nil
---@param message string
---@param color table|nil
local function reply(player, message, color)
    if player then
        player.print(message, { color = color or Color.info })
        return
    end
    if rcon then
        rcon.print(message)
    end
end

---A copy of one of `Teams`' live arrays: `all()` and `alive()` hand out the
---arrays that live in `storage`, and a remote caller must not be given those.
---@param list string[]
---@return string[]
local function copy_list(list)
    local copy = {}
    for i = 1, #list do
        copy[i] = list[i]
    end
    return copy
end

---What the round plays with, and what the next one will play with.
---@return string
local function status_line()
    local pending = Teams.next_count()
    return '[team-count] '
        .. Teams.count()
        .. ' teams: '
        .. table.concat(Teams.all(), ', ')
        .. ' (layout '
        .. Teams.layout()
        .. '). Next round: '
        .. (pending and (pending .. ' teams requested') or 'no request pending, the same count')
end

---`/team-count [2|3|4]`. Admin only when a player typed it; a caller with no
---player is RCON and is trusted, which is how `commands/instant_map_reset.lua`
---reads `cmd.player_index` too. `is_admin` accepts a quasi-admin, and unlike
---`/instant-map-reset` this command has no reason to promote one first: it
---writes one number into `storage`, it does not touch permission groups.
---@param cmd CustomCommandData
function Public.team_count(cmd)
    local player = cmd.player_index and game.get_player(cmd.player_index)
    if player and not is_admin(player) then
        player.print("[ERROR] You're not admin!", { color = Color.fail })
        return
    end

    local param = cmd.parameter
    if param == nil or param:match('^%s*$') then
        reply(player, status_line())
        return
    end

    -- The team-count vote window is a SUB-ARGUMENT of this command rather
    -- than a command of its own: `/help` and the completion list a player gets
    -- from typing `/` are part of the two-team baseline, and `/team-count` is
    -- already in it (it is registered at load on every server). Adding
    -- `/team-count-vote` would add a line to that list on a server that never
    -- votes; `vote` and `force` add nothing to it.
    local word, rest = param:match('^%s*(%S+)%s*(.-)%s*$')
    if word == 'vote' then
        if rest == 'close' then
            local ok, reason = CountVote.close(player and player.name or 'rcon', nil)
            reply(player, '[team-count] ' .. (ok and 'vote closed.' or reason), ok and Color.success or Color.fail)
            return
        end
        -- `vote [seconds] [choices]`: the choices as digits, e.g. `vote 45 24` or
        -- `vote 45 2,4` -- only the counts the players of the match can fill
        -- (equal teams). Without them the window offers 2, 3 and 4.
        local seconds, offered = rest:match('^(%S*)%s*(.-)$')
        if seconds ~= '' and not tonumber(seconds) then
            reply(player, "[team-count] '" .. seconds .. "' is not a number of seconds.", Color.fail)
            return
        end
        local choices
        if offered ~= '' then
            if offered:find('[^%d,%s]') then
                reply(player, "[team-count] '" .. offered .. "' is not a list of team counts.", Color.fail)
                return
            end
            choices = {}
            for digit in offered:gmatch('%d') do
                choices[#choices + 1] = tonumber(digit)
            end
        end
        local ok, reason =
            CountVote.open({ timeout_s = (seconds ~= '' and tonumber(seconds)) or nil, choices = choices })
        if not ok then
            reply(player, '[team-count] ' .. reason .. '.', Color.fail)
        elseif not player then
            reply(nil, '[team-count] vote opened.')
        end
        return
    elseif word == 'close-empty' then
        -- A lookup, not a load: `control.lua` has replaced `require` by now.
        local closed, reason = require('maps.biter_battles_v2.game_over').close_empty_teams()
        if not closed then
            reply(player, '[team-count] ' .. reason .. '.', Color.fail)
        else
            reply(
                player,
                '[team-count] '
                    .. (
                        #closed == 0 and 'every team has a player, nothing closed.'
                        or ('closed: ' .. table.concat(closed, ', ') .. '.')
                    ),
                Color.success
            )
        end
        return
    elseif word == 'force' then
        local ok, reason = CountVote.close(player and player.name or 'rcon', tonumber(rest))
        reply(
            player,
            '[team-count] ' .. (ok and ('forced to ' .. rest .. ' teams.') or reason),
            ok and Color.success or Color.fail
        )
        return
    end

    -- `set_next_count` is the one validator: it refuses anything that is not
    -- 2, 3 or 4 and leaves the pending request alone when it does, so a
    -- mistyped command cannot spoil the reset.
    local ok, reason = Teams.set_next_count(tonumber(param))
    if not ok then
        reply(player, '[team-count] ' .. reason .. " (got '" .. param .. "').", Color.fail)
        return
    end

    reply(
        player,
        '[team-count] '
            .. Teams.next_count()
            .. ' teams requested. It applies at the next map reset, not to the round being played.',
        Color.success
    )
end

commands.add_command(
    'team-count',
    'Admin only - print the team count of this round, or request 2, 3 or 4 teams for the next map reset.',
    Public.team_count
)

-- The daemon's other half. Added at load time, as every remote interface must
-- be; `utils/server_commands.lua` registers 'ServerCommands' the same way,
-- including the guard against a double registration.
if not remote.interfaces['bb_teams'] then
    remote.add_interface('bb_teams', {
        ---@param n any
        ---@return boolean ok
        ---@return string|nil reason Why the request was refused, when it was.
        set_next_count = function(n)
            return Teams.set_next_count(n)
        end,
        ---Open the "Number of teams for this match" window on every connected
        ---player's screen, and on that of anyone who joins while it is open:
        ---three buttons (2 / 3 / 4), one changeable ballot per player, live
        ---tallies, a countdown, and a Force row only admins are drawn.
        ---
        ---`{ timeout_s = 60, choices = { 2, 3, 4 } }`; both fields optional.
        ---When the countdown runs out (or an admin forces a count) the winner
        ----- most ballots, a tie to the smaller count, no ballot at all to 2 --
        ---goes to `Teams.set_next_count`, which is a request for the NEXT map
        ---reset. This call never resets the map and never touches the round
        ---being played.
        ---@param options any
        ---@return boolean ok
        ---@return string|nil reason Why the call was refused, when it was.
        open_count_vote = function(options)
            return CountVote.open(options)
        end,
        ---Close an open vote at once. `count` forces one of the offered counts;
        ---nil counts the ballots as the countdown would have.
        ---@param count any
        ---@param forced_by any A name for the `[team-count]` line and for `forced_by`.
        ---@return boolean ok
        ---@return string|nil reason
        close_count_vote = function(count, forced_by)
            return CountVote.close(forced_by or 'rcon', count)
        end,
        ---`{ state = 'idle'|'open'|'closed', count, forced_by, votes = { [2] = n,
        ---[3] = n, [4] = n }, closes_tick }`. `idle` until the first vote of the
        ---save is opened, and then `count`/`forced_by` are nil; `closed` carries
        ---the elected count and the tick the vote ended on. `votes` holds one
        ---entry per OFFERED choice, zero included.
        ---@return table
        count_vote_result = function()
            return CountVote.result()
        end,
        ---(BB Captains) Open the CAPTAIN VOTE window for the called players:
        ---`{ game = id, timeout_s = 60, choices = { 2, 3, 4 subset }, cands = { 3..4 names },
        ---voters = { names }, default_n = n }`. It only collects ballots; the
        ---orchestrator reads them and decides. Refused while one is open.
        ---@param options any
        ---@return boolean ok
        ---@return string|nil reason
        open_captain_vote = function(options)
            return CaptainVote.open(options)
        end,
        ---Close an open captain vote now (ballots kept for `captain_vote_result`).
        ---@param closed_by any
        ---@return boolean ok
        ---@return string|nil reason
        close_captain_vote = function(closed_by)
            return CaptainVote.close(type(closed_by) == 'string' and closed_by or 'rcon')
        end,
        ---`{ state = 'idle'|'open'|'closed', game, cands, choices, counts = {voter = n},
        ---kicks = {voter = {cand, ...}}, present = {voters connected}, closed_by, left_s }`.
        ---@return table
        captain_vote_result = function()
            return CaptainVote.result()
        end,
        ---Put a connected player on a team of this round, the way the Team
        ---Manager does it (`team_manager.switch_force`), and make sure they are
        ---in the `Default` permission group -- the two statements the League's
        ---late-join assist sends today, as one call that names no internal
        ---module. A player already on another team goes through the spectators
        ---first, as the Team Manager window does, so that they land on the new
        ---team's spawn. A characterless spectator (the state everybody is in
        ---right after a map reset) leaves no corpse and gets the starting pack
        ---once; a player who already has a character DOES leave a corpse with
        ---their inventory -- place people right after the reset.
        ---
        ---`{ player = 'name', force = 'north'|'east'|'south'|'west' }` ->
        ---`{ ok = true, force = 'east' }`, the force the player really is on,
        ---or `{ ok = false, reason = '...' }` and nothing was done.
        ---@param args any
        ---@return table
        place_player = function(args)
            if type(args) ~= 'table' or type(args.player) ~= 'string' or type(args.force) ~= 'string' then
                return { ok = false, reason = "expected { player = 'name', force = 'team' }" }
            end
            local player = game.get_player(args.player)
            if not player then
                return { ok = false, reason = 'no such player' }
            end
            if not player.connected then
                return { ok = false, reason = 'player is not connected' }
            end
            if not Teams.is_active(args.force) then
                return { ok = false, reason = 'not a team of this round' }
            end
            if not Teams.is_alive(args.force) then
                return { ok = false, reason = 'team is out of this round' }
            end
            if player.force.name ~= args.force then
                -- A lookup, not a load: `control.lua` has replaced `require` by now.
                local TeamManager = require('maps.biter_battles_v2.team_manager')
                if Teams.is_team(player.force.name) then
                    TeamManager.switch_force(args.player, 'spectator')
                end
                TeamManager.switch_force(args.player, args.force)
            end
            game.permissions.get_group('Default').add_player(player)
            return { ok = player.force.name == args.force, force = player.force.name }
        end,
        ---Close every team of a 3-4 team round that has no player at all, just
        ---before GO: out of the alive set like a team the map gave no silo (no
        ---share of the sends, idle attack turns, not ranked), biters frozen,
        ---silo made indestructible. Never automatic. Returns the array of the
        ---teams closed by this call (possibly empty), or nil and a reason: a
        ---two-team round, a round already won, fewer than two teams manned.
        ---@return string[]|nil closed
        ---@return string|nil reason
        close_empty_teams = function()
            return require('maps.biter_battles_v2.game_over').close_empty_teams()
        end,
        ---Select the attack schedule used above two teams: 'per_team' (the
        ---default clock -- every team attacked every two intervals) or 'shared'
        ---(one cycle per interval, shared out over the teams). No argument
        ---clears the switch back to the default. Two teams ignore it.
        ---@param mode any
        ---@return boolean ok
        ---@return string|nil reason Why the request was refused, when it was.
        set_attack_clock = function(mode)
            return AttackClock.set_mode(mode)
        end,
        get = function()
            return {
                count = Teams.count(),
                layout = Teams.layout(),
                teams = copy_list(Teams.all()),
                alive = copy_list(Teams.alive()),
                next_count = Teams.next_count(),
                attack_clock = AttackClock.mode(),
            }
        end,
        ---What the scenario made of `storage.bb_league_match` AND the state of
        ---the round, so that the daemon can read a round of more than two teams
        ---instead of guessing at it through a poll written for two.
        ---
        ---`version`, `team_count` and `team_size` are the record as read (nil
        ---when there is none or it cannot be read), `format_key` is the
        ---parameter set that follows and `recognised` the one `[LEAGUE] ...`
        ---line that also goes to the log -- the five original fields,
        ---unchanged. Added to them: `layout`, `won_by`, `start_tick`, `tick`,
        ---`victory_time`, `difficulty`, `tournament_mode`, `tt_mode`,
        ---`placement` and `teams`, one entry per playing team in ring order.
        ---
        ---The record's contract is the header of `match_format.lua`; the reply's
        ---is this module and `league_state.lua`.
        ---@return table
        ---`{ names = false }` drops `teams[].connected`, `teams[].members` and
        ---`teams[].roster` from the answer (absent, not empty): they are the
        ---only part that grows with the number of players, and the reply is one
        ---RCON packet, which a client cuts at 4096 bytes. Everything else is
        ---unchanged, and a caller that passes nothing gets the full answer.
        ---@param options any
        match_info = function(options)
            return LeagueState.match_state(options)
        end,
        ---Hide the teams from the spectators for the length of a match, or show
        ---them again: `true` drops the spectator force's friendship with every
        ---team of the round, `false` restores it -- which is what a map reset
        ---writes anyway.
        ---
        ---At two teams these are the daemon's own
        ---`game.forces['spectator'].set_friend('north'/'south', …)` calls, in
        ---that order; a daemon that keeps sending its own pair is doing the
        ---same thing. Above two teams this is the only form that can name the
        ---teams a two-team daemon cannot.
        ---@param on any True to hide the teams, false to show them again.
        ---@return string[]|nil touched The teams written, in ring order.
        ---@return string|nil reason Why the call was refused, when it was.
        spectator_privacy = function(on)
            return LeagueState.spectator_privacy(on)
        end,
    })
end

return Public
