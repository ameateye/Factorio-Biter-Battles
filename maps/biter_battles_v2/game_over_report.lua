-- What a round of more than two teams says when it ends: the ordinal of a
-- place, the elimination and winner announcements, the private line the player
-- of a dead team gets, and the `[MATCH-RESULT]` record.
--
-- Pure. It is handed titles, numbers and ticks and returns strings and tables;
-- it reads no `game`, no `storage` and no team registry, which is what lets
-- `tests/test-game-over-multiteam.lua` drive every sentence and every field of
-- the record without Factorio. `game_over.lua` looks the arguments up.
--
-- Nothing in here runs in a two-team round. There the first silo to fall ends
-- the game, the loser is the team that is not the winner, and today's outputs --
-- the Discord embed, the MVP panel, `[TEAMSTATS-FINAL]` -- already say it all;
-- they are compared against the baseline byte for byte, so not one of them may
-- gain a word. Every call site in `game_over.lua` is behind `Teams.count() > 2`.

local Public = {}

--- The version of the `[MATCH-RESULT]` record, as the league's match record
--- version 2 it reports on.
local RECORD_VERSION = 2

--- 1st, 2nd, 3rd; everything else takes 'th'.
local ORDINAL_SUFFIX = { 'st', 'nd', 'rd' }

---The English ordinal of a place: '1st', '2nd', '3rd', '4th'.
---
---The teens rule is in here although a round has at most four teams: it costs
---one comparison, and a lookup table of four entries would be a table that is
---right only until somebody plays a bigger game.
---@param place integer
---@return string
function Public.ordinal(place)
    local tens = place % 100
    if tens >= 11 and tens <= 13 then
        return place .. 'th'
    end
    return place .. (ORDINAL_SUFFIX[place % 10] or 'th')
end

---'Team Top Left has been eliminated - 4th place', the chat and Discord line of
---a team that has just lost its last silo while the round goes on.
---
---Without a place -- which cannot happen from the silo-death path, but this
---sentence is printed from a handler that may not raise -- it is today's
---sentence, the one a two-team round has always printed for the loser.
---@param title string The team's display name.
---@param place integer|nil
---@return string
function Public.elimination_message(title, place)
    local message = 'Team ' .. title .. ' has been eliminated'
    if not place then
        return message .. '!'
    end
    return message .. ' - ' .. Public.ordinal(place) .. ' place'
end

---What the players of that team are told privately: their team is out, where it
---placed, and that they are spectating rather than done for the evening.
---@param place integer|nil
---@return string
function Public.eliminated_player_message(place)
    local where = ''
    if place then
        where = ' - ' .. Public.ordinal(place) .. ' place'
    end
    return 'Your team has been eliminated' .. where .. '. You are spectating now and can watch the rest of the game.'
end

---'Team Bottom Right wins! 2nd Top Right, 3rd Top Left, 4th Bottom Left' -- the
---one line that ends a round of more than two teams, in chat and in Discord.
---
---A team that never played is not in the placement and is therefore not listed:
---it did not come fourth, it was not there (`Teams.eliminate(team, true)`).
---@param titles string[] Display names of the placement, winner first.
---@return string
function Public.winner_message(titles)
    local line = 'Team ' .. titles[1] .. ' wins!'
    local places = {}
    for i = 2, #titles do
        places[#places + 1] = Public.ordinal(i) .. ' ' .. titles[i]
    end
    if #places == 0 then
        return line
    end
    return line .. ' ' .. table.concat(places, ', ')
end

---'Top Left - 3rd place', the heading of one team's block in the end-game
---panel, and upper-cased the heading of its Discord embed.
---@param title string
---@param place integer
---@return string
function Public.placed_title(title, place)
    return title .. ' - ' .. Public.ordinal(place) .. ' place'
end

---Where a team that has been eliminated placed: the last team out of a round of
---R teams is Rth, the one before it (R-1)th, and the winner is first.
---
---R is not stored anywhere, because a team that never played -- the map gave it
---no silo -- is out of the round without being ranked. So it is counted here:
---the teams still alive plus the teams eliminated so far. The team eliminated
---last is therefore `alive + 1`, which is the number of teams that were still
---playing when its silo fell.
---@param eliminated { team: string, tick: integer }[] In order of elimination.
---@param alive integer How many teams are still in the round.
---@param team string
---@return integer|nil place nil when the team is not one of the eliminations.
function Public.place_of(eliminated, alive, team)
    local ranked = alive + #eliminated
    for i = 1, #eliminated do
        if eliminated[i].team == team then
            return ranked - i + 1
        end
    end
    return nil
end

---@class MatchResultTeam
---@field name string The force name.
---@field display_name string What the round called it.
---@field placement integer|nil 1 for the winner; nil for a team that never played.
---@field eliminated_tick integer|nil nil for the winner and for a team that never played.

---@class MatchResultInput
---@field teams { name: string, display_name: string, eliminated_tick: integer|nil }[] Ring order.
---@field placement string[] Team names, best first.
---@field winner string|nil The winner's force name.
---@field game_start_tick integer|nil
---@field game_end_tick integer|nil
---@field format string|nil The league's parameter key ('2v2'), when there is a record.
---@field format_label string|nil The match as players read it ('2v2v2'), when there is a record.

---The `[MATCH-RESULT]` record: one entry per playing team in ring order, each
---with the place it took and the tick it lost its silo on, plus the winner, the
---two ticks of the round and the league's format.
---
---A field with no answer is left out rather than set to something that reads
---like an answer: `helpers.table_to_json` has no null, so an absent
---`eliminated_tick` (the winner, a team that never played) and an absent
---`placement` (a team that never played) are the key simply not being there.
---@param round MatchResultInput
---@return table
function Public.match_result(round)
    local place_by_team = {}
    local placement = round.placement
    for i = 1, #placement do
        place_by_team[placement[i]] = i
    end

    ---@type MatchResultTeam[]
    local teams = {}
    for i = 1, #round.teams do
        local entry = round.teams[i]
        teams[i] = {
            name = entry.name,
            display_name = entry.display_name,
            placement = place_by_team[entry.name],
            eliminated_tick = entry.eliminated_tick,
            players = entry.players,
        }
    end

    return {
        version = RECORD_VERSION,
        teams = teams,
        winner = round.winner,
        game_start_tick = round.game_start_tick,
        game_end_tick = round.game_end_tick,
        format = round.format,
        format_label = round.format_label,
    }
end

---'TOP LEFT PLAYERS: \\nalice   bob   ' -- one team's block of the Discord
---game-over embed above two teams: the upper-cased title, the two-character
---'\\n' sequence the embed template uses, then every name followed by three
---spaces, exactly as the two-team loop appends a connected player.
---
---The names are the team's ROSTER (`LeagueState.roster_of`), not the players on
---its force right now: when the round ends, the players of every eliminated team
---have been moved to the spectators, and a list read off the force was empty for
---all but the winner.
---@param title_caps string
---@param names string[]
---@return string
function Public.players_line(title_caps, names)
    local parts = { title_caps, ' PLAYERS: \\n' }
    for i = 1, #names do
        parts[#parts + 1] = names[i]
        parts[#parts + 1] = '   '
    end
    return table.concat(parts)
end

---The teams in the order the end-game panel lists them above two teams: the
---placement (winner first), then any team of the round the placement does not
---hold -- a team that never played -- in ring order. Every team of `teams` once,
---and nothing that is not in `teams`.
---@param teams string[] The round's teams, ring order.
---@param placement string[]|nil Team names, best first.
---@return string[]
function Public.placement_order(teams, placement)
    local in_round, listed, ordered = {}, {}, {}
    for i = 1, #teams do
        in_round[teams[i]] = true
    end
    for _, team in ipairs(placement or {}) do
        if in_round[team] and not listed[team] then
            listed[team] = true
            ordered[#ordered + 1] = team
        end
    end
    for i = 1, #teams do
        if not listed[teams[i]] then
            listed[teams[i]] = true
            ordered[#ordered + 1] = teams[i]
        end
    end
    return ordered
end

---What the team statistics window keeps of a round of more than two teams, so
---that "Show previous game" can still rank it and name its teams as they were
---called then: the placement (a copy, best first) and every team's title.
---@param teams string[] The round's teams, ring order.
---@param placement string[]|nil Team names, best first.
---@param name_of fun(team: string): string The title of a team.
---@return { placement: string[], names: table<string, string> }
function Public.standings(teams, placement, name_of)
    local copy, names = {}, {}
    for i, team in ipairs(placement or {}) do
        copy[i] = team
    end
    for _, team in ipairs(teams) do
        names[team] = name_of(team)
    end
    return { placement = copy, names = names }
end

---The lines under 'Winner:' in the team statistics window above two teams:
---'2nd: Bottom Right', '3rd: Top Right', ... for the placement after the winner.
---The winner's own line is the caller's, unchanged.
---@param titles string[] Display names of the placement, winner first.
---@return string[]
function Public.standings_lines(titles)
    local lines = {}
    for i = 2, #titles do
        lines[#lines + 1] = Public.ordinal(i) .. ': ' .. titles[i]
    end
    return lines
end

return Public
