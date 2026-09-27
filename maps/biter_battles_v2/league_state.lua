-- The League daemon's view of the round, for 2, 3 or 4 teams.
--
-- The daemon has two channels into this scenario and they are not the same
-- thing:
--
--   * the TT1 poll it composes itself and sends over RCON every few seconds
--     (`tests/fixtures/league-tt1-poll.lua`). It reads `storage` and the forces
--     `north` / `south` / `spectator` DIRECTLY, it knows nothing about a third
--     team, and it must keep working unchanged -- so nothing here may rename a
--     key it reads. `tests/test-league-poll.lua` runs it as it is and pins
--     every field of it.
--   * `remote.call('bb_teams', 'match_info')`, which is this module. It is the
--     channel for a round of more than two teams: it names the teams that are
--     actually playing, their square on the map, whether they are still alive
--     and where they finished, and their evolution, threat and rosters.
--
-- It also carries `spectator_privacy`, the match-preparation call that hides
-- the teams of the round from the spectator force -- the N-team form of the two
-- `set_friend` calls the daemon sends today.
--
-- Nothing here is called by the scenario itself, and a two-team round behaves
-- exactly as it does without this module: `match_state()` writes nothing at
-- all, and `spectator_privacy` writes only what the daemon already writes by
-- hand, when the daemon asks for it.
--
-- Pure enough to unit-test outside Factorio (`tests/test-league-state.lua`):
-- it reads `storage`, `game.tick` and `game.forces`, and draws no random
-- numbers.

local MatchFormat = require('maps.biter_battles_v2.match_format')
local Report = require('maps.biter_battles_v2.game_over_report')
local Teams = require('maps.biter_battles_v2.teams')

local Public = {}

---The four-square map's squares, by the transform that takes the canonical
---zone to the team's own (`Teams.k_of`).
---
---`layout.lua` numbers the quadrants and says a quadrant number IS the `k` of
---the team whose zone it is (layout.lua:197-201): 0 top left, then clockwise
---1 top right, 2 bottom right, 3 bottom left. It has no NAME for them, so the
---names are defined here, agreeing with the registry's own display names for
---the four-square layout ('Top Left', 'Top Right', ... -- teams.lua ROSTER).
---
---Because the answer is the team's `k`, this module needs the registry and not
---the geometry: it does not require `layout.lua`.
---@type table<integer, string>
local QUADRANT_NAME = {
    [0] = 'top_left',
    [1] = 'top_right',
    [2] = 'bottom_right',
    [3] = 'bottom_left',
}

---The layout whose squares are the four quadrants. On the other one there are
---no quadrants at all.
local CROSS4 = 'cross4'

---The force the spectators watch from. Not a team: it is not in the roster,
---no round plays it, and `teams.lua` says it is none of its business.
local SPECTATOR = 'spectator'

---The square of the map this team plays.
---
---On 'cross4' it is the quadrant name above. On 'horizontal2' there is one
---square per side and the side IS the force -- the daemon already calls them
---`north` and `south` in the poll -- so the answer is the force name itself,
---which is also why no team-name literal is written here.
---@param team string
---@param layout string
---@return string
local function quadrant_of(team, layout)
    if layout ~= CROSS4 then
        return team
    end
    local k = Teams.k_of(team)
    if k == nil then
        return team
    end
    return QUADRANT_NAME[k]
end

---The names of a force's players, in the order `pairs` walks them.
---
---Deliberately the same expression as the TT1 poll's
---`for _,p in pairs(FN.players) do fn[#fn+1]=p.name end`: with two teams
---`members` has to be the poll's force_north / force_south list, and the only
---way to guarantee that is to read the same collection the same way.
---@param players LuaPlayer[]
---@return string[]
local function names_of(players)
    local names = {}
    for _, player in pairs(players) do
        names[#names + 1] = player.name
    end
    return names
end

---@class LeagueTeamState
---@field force string The force name: 'north', 'east', 'south' or 'west'.
---@field name string The display name the chat lines and the panel use.
---@field quadrant string The square of the map (see `quadrant_of`).
---@field alive boolean Still has a silo.
---@field eliminated_tick integer|nil The tick its last silo fell on, when it did.
---@field place integer|nil The final place already secured: Rth for the first team out of R, 1 for the winner; nil while the team is still playing.
---@field evo number|nil `storage.bb_evolution['<force>_biters']`.
---@field threat number|nil `storage.bb_threat['<force>_biters']`.
---@field connected string[] The names of the force's connected players.
---@field members string[] The names of the force's players, connected or not.

---One team's entry, built for the team `team` of the round.
---
---`members` is `game.forces[team].players` and nothing else -- NOT
---`storage.chosen_team`. Three reasons, in order of weight:
---
---  1. with two teams `members` must be the TT1 poll's force_north /
---     force_south list, and the poll builds those from `LuaForce.players`.
---     Same collection, same traversal, same order: equal by construction
---     rather than by coincidence.
---  2. `chosen_team` is a shadow of force membership, not a second source of
---     truth. `join_team` sets the force and the choice in the same breath
---     (gui.lua:1500 and :1528), every path that leaves a team clears the
---     choice (team_manager.lua:168, game_over.lua:548), and a map reset
---     clears both -- `Init.tables()` empties `chosen_team` (init.lua:585) and
---     `Functions.init_player()` puts every player back on the spectator force
---     (functions.lua:382-384). There is no state the one has and the other
---     has not.
---  3. it is keyed by player NAME and nothing prunes a name whose player is
---     gone, so a union could hand the daemon a roster entry that is not a
---     player any more.
---
---`connected` is the same list restricted to the players who are online, from
---`LuaForce.connected_players`.
---@param team string
---Everybody who plays or played for `team` this round, sorted by name. Unlike
---the force's own player list this never empties: when a team is eliminated its
---players become spectators with their choice cleared, and what is left of them
---is the mark of the elimination, which keeps the team (`teams.lua`
---`mark_player_eliminated`). Merged from that mark, the force's players
---(connected or not) and the choice of whoever is watching. Sorted, so the list
---does not depend on a `pairs` order.
---@param team string
---@return string[]
function Public.roster_of(team)
    local seen, names = {}, {}
    local function add(name)
        if not seen[name] then
            seen[name] = true
            names[#names + 1] = name
        end
    end
    for name, marked in pairs(Teams.state().eliminated_players) do
        if marked == team then
            add(name)
        end
    end
    local force = game.forces[team]
    if force then
        for _, player in pairs(force.players) do
            add(player.name)
        end
    end
    for name, chosen in pairs(storage.chosen_team or {}) do
        if chosen == team then
            add(name)
        end
    end
    table.sort(names)
    return names
end

---@param layout string
---@param eliminated_ticks table<string, integer>
---@param place_of table<string, integer>
---@return LeagueTeamState
---@param names boolean Include the three player-name lists.
local function team_state(team, layout, eliminated_ticks, place_of, names)
    local biter_force = Teams.biter_force(team)
    local evolution = storage.bb_evolution
    local threat = storage.bb_threat
    local force = game.forces[team]
    return {
        force = team,
        name = Teams.display_name(team),
        quadrant = quadrant_of(team, layout),
        alive = Teams.is_alive(team),
        eliminated_tick = eliminated_ticks[team],
        place = place_of[team],
        evo = evolution and evolution[biter_force],
        threat = threat and threat[biter_force],
        connected = names and (force and names_of(force.connected_players) or {}) or nil,
        members = names and (force and names_of(force.players) or {}) or nil,
        roster = names and Public.roster_of(team) or nil,
    }
end

---One entry per ACTIVE team, in ring order (`Teams.all()`).
---
---The round's teams, not `game.forces`: a save that once played four teams
---keeps its dormant `east` and `west` forces, and they are not in this round.
---
---`place` is the place a team has already secured. A team that is out has its
---final place from the moment its silo fell: the last team out of a round of R
---teams is Rth whatever the survivors do -- the very computation the elimination
---line prints (game_over_report.lua `place_of`), so the two channels cannot rank
---a round differently. The winner is 1st once there is one (`Teams.winner()`,
---the same test `Teams.placement()` uses); a team still playing has no place.
---@param layout string
---@return LeagueTeamState[]
---@param names boolean
local function teams_of(layout, names)
    local eliminated = Teams.state().eliminated
    local eliminated_ticks = {}
    for _, elimination in ipairs(eliminated) do
        eliminated_ticks[elimination.team] = elimination.tick
    end

    local alive = #Teams.alive()
    local place_of = {}
    for _, elimination in ipairs(eliminated) do
        place_of[elimination.team] = Report.place_of(eliminated, alive, elimination.team)
    end
    local winner = Teams.winner()
    if winner then
        place_of[winner] = 1
    end

    local active = Teams.all()
    local states = {}
    for i = 1, #active do
        states[i] = team_state(active[i], layout, eliminated_ticks, place_of, names)
    end
    return states
end

---Everything the daemon reads back over RCON: what the scenario made of the
---league's record, plus the state of the round itself.
---
---`MatchFormat.match_info()` is merged in unchanged -- `version`, `team_count`,
---`team_size`, `format_key` and `recognised` keep the values and the meanings
---they have always had, and a daemon that only reads those five is
---unaffected. It hands out a fresh table every call (match_format.lua:407-416),
---so the extra fields are written straight into it.
---
---Every array is fresh and every string is a copy of a `storage` value: the
---table crosses the remote boundary and the caller keeps it.
---`options.names == false` leaves out the three name lists of every team
---(`connected`, `members`, `roster`): the keys are ABSENT, not empty. They are
---the only part of the answer that grows with the number of players, and a poll
---does not need them -- but a reply is read as ONE RCON packet and the client
---cuts one at 4096 bytes, so a daemon that polls a full server drops them and
---asks for them when it needs them (at GO, and at the end of a round). Anything
---else is nil/absent-safe already, so an old caller passing nothing is
---unchanged.
---@param options table|nil `{ names = false }`
---@return table state
function Public.match_state(options)
    local names = not (type(options) == 'table' and options.names == false)
    local state = MatchFormat.match_info()
    local layout = Teams.layout()

    state.layout = layout
    state.won_by = storage.bb_game_won_by_team
    state.start_tick = storage.bb_game_start_tick
    state.tick = game.tick
    state.victory_time = storage.victory_time
    state.difficulty = storage.difficulty_vote_value
    -- Booleans, not the raw value: `storage.tournament_mode` is nil rather than
    -- false on a fresh save and the daemon should not have to know that. This
    -- is also the test the TT1 poll applies (`== true`).
    state.tournament_mode = storage.tournament_mode == true
    state.tt_mode = storage.tt_mode == true
    state.placement = Teams.placement()
    state.teams = teams_of(layout, names)
    return state
end

---Hide the teams from the spectators for the length of a match, or show them
---again.
---
---`on == true` is the privacy the league plays under: the spectator force stops
---being a friend of each playing team. `on == false` puts the friendship back,
---which is exactly what `Init.forces()` writes at a map reset (init.lua:761-763
----- `for _, team in ipairs(teams) do f.set_friend(team, true) end`), so the two
---halves of the daemon's match are the two halves of this call.
---
---At two teams it is the daemon's own
---`f.set_friend('north', …)` / `f.set_friend('south', …)` pair: the same two
---writes, in that order, and nothing else. The daemon may keep sending its own;
---above two teams this is the only form that can name the teams it cannot.
---
---Only `Teams.all()` is written -- the teams of the ROUND, in ring order. A save
---that has played four teams keeps its dormant `east` and `west` forces, and
---writing relations for teams nobody is playing is exactly what iterating
---`game.forces` would do. A team eliminated mid-round is still one of the
---round's teams and is still written: its silo is gone, its chart is not.
---
---One direction only, as the daemon's calls are: what the teams make of the
---spectators is not touched.
---
---Never called by the scenario itself; the League daemon calls it over RCON.
---@param on any True to hide the teams, false to show them again.
---@return string[]|nil touched The teams written, in ring order.
---@return string|nil reason Why the call was refused, when it was.
function Public.spectator_privacy(on)
    -- A boolean or nothing: `spectator_privacy()` with no argument would
    -- otherwise read as "show them", and opening a match up by accident is the
    -- one mistake this call must not make easy.
    if on ~= true and on ~= false then
        return nil, 'spectator_privacy takes true (hide the teams) or false (show them)'
    end
    local spectator = game.forces[SPECTATOR]
    if not spectator then
        return nil, "there is no '" .. SPECTATOR .. "' force"
    end

    local friend = not on
    local teams = Teams.all()
    local touched = {}
    for i = 1, #teams do
        spectator.set_friend(teams[i], friend)
        touched[i] = teams[i]
    end
    return touched
end

return Public
