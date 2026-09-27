-- The team model: the roster, the round's team state, and every answer that
-- depends on a team name.
--
-- Nothing else in the scenario is meant to know that a team is called 'north':
-- names, order, colours, display names, force names, who may be fed and who is
-- still alive all come from here.
--
-- Three rules this module lives by:
--
--   * per-team iteration is `ipairs(Teams.all())`, never `pairs` over a
--     team-keyed table -- a hash order is not the same on two clients, and the
--     bodies of those loops print, accumulate and draw random numbers;
--   * the only state is `storage.bb_teams`, written by `begin_round()`,
--     `set_next_count()`, `set_feed_policy()`, `eliminate()` and
--     `mark_player_eliminated()` and by nothing else. No `Global.register`, no
--     event handler, nothing written at load;
--   * the team count changes in one place, `begin_round()`, which runs at
--     `on_init` and at every in-save map reset -- so no per-team table is ever
--     resized while a round is using it.
--
-- `state()` creates the two-team default the first time it is asked, so code
-- running before the first `begin_round()` sees today's game rather than nil.
-- That first call writes to `storage`, which means it must not be the thing
-- that runs inside `on_load`.

local Config = require('maps.biter_battles_v2.config')
local Force = require('utils.force')

local Public = {}

---@class TeamEntry
---@field name string The force name of the team.
---@field k integer The quadrant of this team's zone, and the transform onto it (cross layout; layout.lua).
---@field color { r: integer, g: integer, b: integer } Components in 0..255.
---@field text_color string The same colour as the payload of a `[color=...]` rich-text tag.
---@field cross_name string Display name in the four-square layout, when `Config.cross_team_names` has none.
---@field config_key string|nil Key of the operator's custom name in `config.lua`, for the teams that have one.
---@field biter_force string `<name>_biters`, precomputed: this is read from tick handlers.
---@field boss_force string `<name>_biters_boss`.

--- Ring order -- north, east, south, west, clockwise. Index - 1 is `k`.
---@type TeamEntry[]
local ROSTER = {
    {
        name = 'north',
        k = 0,
        color = { r = 120, g = 120, b = 255 },
        text_color = '120, 120, 255',
        cross_name = 'Top Left',
        config_key = 'north_side_team_name',
        biter_force = 'north_biters',
        boss_force = 'north_biters_boss',
    },
    {
        name = 'east',
        k = 1,
        color = { r = 80, g = 215, b = 95 },
        text_color = '80, 215, 95',
        cross_name = 'Top Right',
        config_key = nil,
        biter_force = 'east_biters',
        boss_force = 'east_biters_boss',
    },
    {
        name = 'south',
        k = 2,
        color = { r = 255, g = 65, b = 65 },
        text_color = '255, 65, 65',
        cross_name = 'Bottom Right',
        config_key = 'south_side_team_name',
        biter_force = 'south_biters',
        boss_force = 'south_biters_boss',
    },
    {
        name = 'west',
        k = 3,
        color = { r = 255, g = 200, b = 50 },
        text_color = '255, 200, 50',
        cross_name = 'Bottom Left',
        config_key = nil,
        biter_force = 'west_biters',
        boss_force = 'west_biters_boss',
    },
}

---@type table<string, TeamEntry>
local BY_NAME = {}
---@type table<string, integer> Position in the ring, 1..4.
local RING_INDEX = {}
for index, entry in ipairs(ROSTER) do
    BY_NAME[entry.name] = entry
    RING_INDEX[entry.name] = index
end

--- Who plays, by team count. This is THE iteration order of the scenario.
---@type table<integer, string[]>
local ACTIVE_BY_COUNT = {
    [2] = { 'north', 'south' },
    [3] = { 'north', 'east', 'south' },
    [4] = { 'north', 'east', 'south', 'west' },
}

---@type table<integer, string>
local LAYOUT_BY_COUNT = {
    [2] = 'horizontal2',
    [3] = 'cross4',
    [4] = 'cross4',
}

local DEFAULT_COUNT = 2
local DEFAULT_FEED_POLICY = 'split'

--- The policies `feed_targets` knows, as a set.
---@type table<string, true>
local FEED_POLICIES = {
    split = true,
    target = true,
    ring = true,
}

---@class TeamsState
---@field count integer Teams of the current round.
---@field layout string 'horizontal2' | 'cross4'.
---@field active string[] Ordered; the iteration order everywhere.
---@field alive table<string, true> The active teams that still have a silo.
---@field alive_list string[] The same set, in `active` order.
---@field biter_force_list string[] `<team>_biters` of `active`, in that order.
---@field boss_force_list string[] `<team>_biters_boss` of `active`, in that order.
---@field alive_biter_force_list string[] `<team>_biters` of `alive_list`, in that order.
---@field eliminated { team: string, tick: integer }[] In order of elimination.
---@field eliminated_players table<string, string|true> Players whose team died this round, and which team it was.
---@field next_count integer|nil Requested for the next round.
---@field feed_policy string 'split' | 'target' | 'ring'; only consulted above two teams.
---@field extra_chat_commands boolean|nil A round of more than two teams has begun in this save.
---@field science_focus table<string, table<integer, { picks: table<string, true>, until_tick: table<string, integer> }>>|nil
---  Science targeting: per sender team, per player index, the enemies that
---  player ticked and the tick each of his buttons is locked until. Created by the first click of a round of more
---  than two teams; never at two.

---Write the round fields of `state` for a round of `count` teams. The single
---writer of who is playing and who is alive.
---
---The three force-name arrays are derived from `active` and are stored rather
---than rebuilt per call: `biter_forces()` is read from `on_tick` and from the
---wave dispatcher, and a fresh array per tick is garbage the round does not
---need. Nothing but this function and `eliminate()` writes them.
---@param state TeamsState
---@param count integer
---@param feed_policy string
---@return TeamsState state
local function rebuild(state, count, feed_policy)
    local active = {}
    local alive = {}
    local alive_list = {}
    local biter_force_list = {}
    local boss_force_list = {}
    local alive_biter_force_list = {}
    for i, name in ipairs(ACTIVE_BY_COUNT[count]) do
        local entry = BY_NAME[name]
        active[i] = name
        alive_list[i] = name
        alive[name] = true
        biter_force_list[i] = entry.biter_force
        boss_force_list[i] = entry.boss_force
        alive_biter_force_list[i] = entry.biter_force
    end
    state.count = count
    state.layout = LAYOUT_BY_COUNT[count]
    state.active = active
    state.alive = alive
    state.alive_list = alive_list
    state.biter_force_list = biter_force_list
    state.boss_force_list = boss_force_list
    state.alive_biter_force_list = alive_biter_force_list
    state.eliminated = {}
    state.eliminated_players = {}
    state.next_count = nil
    state.feed_policy = feed_policy
    -- Science targeting is a round's choice: a new map starts with nothing
    -- ticked. Absent at two teams, so this assignment changes nothing there.
    state.science_focus = nil
    return state
end

---The round's team state, lazily created as a two-team round when the key is
---missing -- so a reader that runs before the first `begin_round()` sees today's
---game. The table is the live one: `all()`, `alive()` and `eliminated` hand out
---its arrays, and callers read them.
---@return TeamsState
function Public.state()
    local state = storage.bb_teams
    if not state then
        state = rebuild({}, DEFAULT_COUNT, DEFAULT_FEED_POLICY)
        storage.bb_teams = state
    end
    return state
end

---Ask for `n` teams from the next `begin_round()` on. A refused request leaves
---the pending one alone, so a mistyped admin command cannot spoil the reset.
---@param n any
---@return boolean ok
---@return string|nil reason Why it was refused, when it was.
function Public.set_next_count(n)
    if type(n) ~= 'number' then
        return false, 'team count must be a number'
    end
    if n ~= math.floor(n) then
        return false, 'team count must be a whole number'
    end
    if not ACTIVE_BY_COUNT[n] then
        return false, 'team count must be 2, 3 or 4'
    end
    Public.state().next_count = n
    return true
end

---The count requested for the next round, or nil when none is pending.
---@return integer|nil
function Public.next_count()
    return Public.state().next_count
end

---How a science send is shared out above two teams. It
---takes effect at once -- unlike the team count there is no table to resize --
---and survives the round boundary, so an operator sets it once.
---
---Two teams ignore the policy: `feed_targets` answers "the other one" whatever
---it says, so this setter cannot change a two-team game.
---@param policy any
---@return boolean ok
---@return string|nil reason Why it was refused, when it was.
function Public.set_feed_policy(policy)
    if not FEED_POLICIES[policy] then
        return false, "feeding policy must be 'split', 'target' or 'ring'"
    end
    Public.state().feed_policy = policy
    return true
end

---Whether the science Focus row is offered: above two teams and only under
---the 'split' policy ('ring' and 'target' answer before the focus is read).
---@return boolean
function Public.science_focus_offered()
    return Public.count() > 2 and Public.feed_policy() == 'split'
end

---How a science send is shared out above two teams.
---@return string
function Public.feed_policy()
    return Public.state().feed_policy or DEFAULT_FEED_POLICY
end

---Start a round: apply a pending `set_next_count()`, otherwise keep the count
---of the round that just ended (2 the first time). The active list, the alive
---set and the layout are rebuilt and the eliminations are forgotten; the
---feeding policy survives the round boundary.
---
---This is the one point where the team count changes, and it is a statement of
---`Init.tables()`, so every per-team table is built after it.
---@return TeamsState
function Public.begin_round()
    local state = Public.state()
    local count = state.next_count or state.count or DEFAULT_COUNT
    if not ACTIVE_BY_COUNT[count] then
        count = DEFAULT_COUNT
    end
    local round = rebuild(state, count, state.feed_policy or DEFAULT_FEED_POLICY)
    if count > 2 then
        -- A latch, never cleared: `commands/chat_commands.lua` registers the
        -- chat commands of the teams outside the legacy pair the first time a
        -- round needs them, and a command cannot be unregistered again. A save
        -- that has only ever played two teams never gains the key, so its
        -- storage -- and its command list -- are exactly today's.
        round.extra_chat_commands = true
    end
    return round
end

---True once a round of more than two teams has begun in this save: the chat
---commands of the other roster teams were registered then and stay registered.
---
---A plain, defensive read of `storage.bb_teams`. Unlike every other reader here
---it deliberately does NOT go through `state()`: `on_load` asks this question,
---and `state()` would write the default round state into `storage`, which
---`on_load` may not do.
---@return boolean
function Public.extra_chat_commands()
    local state = storage.bb_teams
    return state ~= nil and state.extra_chat_commands == true
end

---@return integer
function Public.count()
    return Public.state().count
end

---@return string layout 'horizontal2' or 'cross4'.
function Public.layout()
    return Public.state().layout
end

---The active teams, in ring order. THE iteration order: `ipairs(Teams.all())`.
---
---This is the live array in `storage`, handed out rather than copied because
---tick handlers walk it: read it, never write to it.
---@return string[]
function Public.all()
    return Public.state().active
end

---The active teams that have not been eliminated, in ring order. Live array as
---`all()` is, but `eliminate()` replaces it instead of editing it, so a loop
---that is already running keeps the list it started with.
---@return string[]
function Public.alive()
    return Public.state().alive_list
end

---The four roster names in ring order, whether or not they play this round.
---
---What `all()` is to a round, this is to the scenario: the list a reader that
---runs *before* a round needs -- a command registered at load time, a static
---click-dispatch table -- because it must already cover the teams a later round
---may bring. Unlike every other list here it is static, so it answers without
---creating the round state; a fresh array each call, the caller may keep it.
---@return string[]
function Public.roster()
    local names = {}
    for i = 1, #ROSTER do
        names[i] = ROSTER[i].name
    end
    return names
end

---True for one of the four roster names, whether or not it plays this round.
---@param name any
---@return boolean
function Public.is_team(name)
    return BY_NAME[name] ~= nil
end

---@param name any
---@return boolean
function Public.is_active(name)
    return Public.index_of(name) ~= nil
end

---@param name any
---@return boolean
function Public.is_alive(name)
    return Public.state().alive[name] == true
end

---Position of `name` in `all()`, or nil when it does not play this round.
---@param name any
---@return integer|nil
function Public.index_of(name)
    local active = Public.state().active
    for i = 1, #active do
        if active[i] == name then
            return i
        end
    end
    return nil
end

---Position in the ring (1 north, 2 east, 3 south, 4 west), whatever the round.
---@param name any
---@return integer|nil
function Public.ring_index(name)
    return RING_INDEX[name]
end

---The quadrant of this team's zone, 0..3, clockwise from the top left; also the
---transform from the canonical zone to it (`layout.lua`).
---@param name any
---@return integer|nil
function Public.k_of(name)
    local entry = BY_NAME[name]
    if not entry then
        return nil
    end
    return entry.k
end

---@param team string
---@return string
function Public.biter_force(team)
    local entry = BY_NAME[team]
    if entry then
        return entry.biter_force
    end
    return team .. '_biters'
end

---@param team string
---@return string
function Public.boss_force(team)
    local entry = BY_NAME[team]
    if entry then
        return entry.boss_force
    end
    return team .. '_biters_boss'
end

---Biter force names of the active teams, in ring order.
---
---The live array that `begin_round()` built, handed out rather than copied for
---the same reason `all()` is: the threat tick and the wave dispatcher walk it.
---Read it, never write to it.
---@return string[]
function Public.biter_forces()
    return Public.state().biter_force_list
end

---Boss biter force names of the active teams, in ring order. Live array, as
---`biter_forces()` is.
---@return string[]
function Public.boss_forces()
    return Public.state().boss_force_list
end

---Biter force names of the teams that have not been eliminated, in ring order.
---Live array; `eliminate()` replaces it instead of editing it, so a loop that
---is already running keeps the list it started with.
---@return string[]
function Public.alive_biter_forces()
    return Public.state().alive_biter_force_list
end

---The team a biter force belongs to, or nil when the name is not a roster
---team's biter force.
---
---`utils/force.lua` is prefix-lazy and unvalidated: it answers '' for '_biters'
---and 'foo' for 'foo_biters' (tests/test-force.lua pins that), so the answer is
---checked against the roster here.
---@param force_name any
---@return string|nil
function Public.team_of_biter_force(force_name)
    if type(force_name) ~= 'string' then
        return nil
    end
    local team = Force.get_player_force_name(force_name)
    if team ~= nil and BY_NAME[team] ~= nil then
        return team
    end
    return nil
end

---The alive teams other than `team`, in `all()` order. With two teams both
---alive this is exactly the one enemy of today's `enemy_team_of`.
---
---Each consumer states its own policy on top of this: the list says who is
---playing against `team`, not what should happen to them.
---@param team string
---@return string[]
function Public.enemies_of(team)
    local state = Public.state()
    local active = state.active
    local alive = state.alive
    local enemies = {}
    for i = 1, #active do
        local name = active[i]
        if name ~= team and alive[name] then
            enemies[#enemies + 1] = name
        end
    end
    return enemies
end

---The next alive team clockwise after `team`, or nil when there is none --
---`team` is the last one standing, or not a roster team at all. Teams that do
---not play this round are stepped over: they are not in the alive set.
---@param team string
---@return string|nil
function Public.next_alive_clockwise(team)
    local from = RING_INDEX[team]
    if not from then
        return nil
    end
    local alive = Public.state().alive
    local ring = #ROSTER
    for step = 1, ring - 1 do
        local candidate = ROSTER[(from + step - 1) % ring + 1].name
        if alive[candidate] then
            return candidate
        end
    end
    return nil
end

---@class FeedTarget
---@field team string Who receives the send.
---@field share number Fraction of it; the shares of a non-empty list sum to 1.
---@field focused boolean|nil Science targeting: some player of the sender steers focus to this team.
---@field focus number|nil Science targeting: the part of `share` that is focus, f(e) (0 .. FOCUS_SHARE).

---Who receives a science send, and in what proportion -- the only place that
---decides it. The order is `all()` order, so every
---client does the same arithmetic in the same sequence.
---
---With two teams the answer is the other team with share 1 whatever the alive
---flags say: today's `enemy_team_of` knows nothing about elimination, and the
---single target means the multiplication is skipped and the rounding of a send
---is bit-for-bit today's.
---@param sender_team string The force name of the team that sent.
---@param choice string|nil The picked enemy, for the 'target' policy.
---@return FeedTarget[] targets Empty when the send has nowhere to go.
function Public.feed_targets(sender_team, choice)
    if storage.training_mode then
        -- Feed your own biters, as today (feeding.lua:45-51), sender unchecked.
        return { { team = sender_team, share = 1 } }
    end

    local state = Public.state()
    if state.count == 2 then
        local active = state.active
        for i = 1, #active do
            if active[i] == sender_team then
                return { { team = active[3 - i], share = 1 } } -- the other one of two
            end
        end
        return {}
    end

    if state.alive[sender_team] ~= true or not Public.is_active(sender_team) then
        return {}
    end

    local policy = state.feed_policy or DEFAULT_FEED_POLICY
    if policy == 'ring' then
        local target = Public.next_alive_clockwise(sender_team)
        if not target then
            return {}
        end
        return { { team = target, share = 1 } }
    end
    if policy == 'target' and choice ~= sender_team and state.alive[choice] then
        return { { team = choice, share = 1 } }
    end

    -- 'split', and the fallback of a 'target' send with no usable choice.
    local enemies = Public.enemies_of(sender_team)
    local count = #enemies
    if count == 0 then
        return {}
    end
    -- Science targeting: each connected player of the
    -- sender team steers 1/N of FOCUS_SHARE, split evenly over the enemies he
    -- ticked; the rest goes to all enemies equally. Nobody ticking anything
    -- (or one enemy left) is the plain split, on the plain split's code path.
    local weights, voters = nil, 0
    local team_focus = state.science_focus and state.science_focus[sender_team]
    if team_focus and count > 1 then
        weights, voters = Public.focus_weights(sender_team, enemies)
    end
    local targets = {}
    if weights then
        local focus = {}
        local focus_total = 0
        for i = 1, count do
            local w = weights[enemies[i]]
            local f = w and Public.FOCUS_SHARE * (w / voters) or 0
            focus[i] = f
            focus_total = focus_total + f
        end
        local base = (1 - focus_total) / count
        for i = 1, count do
            local f = focus[i]
            targets[i] = { team = enemies[i], share = base + f, focused = f > 0, focus = f }
        end
        return targets
    end
    local share = 1 / count
    for i = 1, count do
        targets[i] = { team = enemies[i], share = share }
    end
    return targets
end

---Whether `player` counts for `team`'s science focus: a valid player who is
---connected and plays on that team's force right now.
---@param team string
---@param index integer
---@return LuaPlayer|nil
local function focus_voter(team, index)
    local player = game.get_player(index)
    if player and player.valid and player.connected and player.force.name == team then
        return player
    end
    return nil
end

---The per-player science focus of `team` against `enemies` (its alive enemies,
---in `all()` order): for each enemy e, w(e) = sum over the counted players p who
---ticked e of 1 / k_p (k_p = how many of `enemies` p ticked), and N = the number
---of connected players on the team's force. f(e) = FOCUS_SHARE * w(e) / N, so
---the focus of a team never exceeds FOCUS_SHARE. Returns nil when no counted
---player ticks any of `enemies`. A pure read.
---@param team string
---@param enemies string[]
---@return table<string, number>|nil weights
---@return integer voters N
function Public.focus_weights(team, enemies)
    local all = Public.state().science_focus
    local team_focus = all and all[team]
    if not team_focus then
        return nil, 0
    end
    local force = game.forces[team]
    local voters = force and #force.connected_players or 0
    if voters == 0 then
        return nil, 0
    end
    local weights = nil
    for index, entry in pairs(team_focus) do
        local k = 0
        for i = 1, #enemies do
            if entry.picks[enemies[i]] then
                k = k + 1
            end
        end
        if k > 0 and focus_voter(team, index) then
            weights = weights or {}
            for i = 1, #enemies do
                local e = enemies[i]
                if entry.picks[e] then
                    weights[e] = (weights[e] or 0) + 1 / k
                end
            end
        end
    end
    return weights, voters
end

---Who steers `team`'s focus toward each enemy: { [enemy] = { names... } },
---counted players only (connected, on the team), by player index. A pure read.
---@param team string
---@return table<string, string[]>
function Public.focus_backers(team)
    local out = {}
    local all = Public.state().science_focus
    local team_focus = all and all[team]
    if not team_focus then
        return out
    end
    local indexes = {}
    for index in pairs(team_focus) do
        indexes[#indexes + 1] = index
    end
    table.sort(indexes)
    for _, index in ipairs(indexes) do
        local player = focus_voter(team, index)
        if player then
            for _, e in ipairs(Public.enemies_of(team)) do
                if team_focus[index].picks[e] then
                    local names = out[e] or {}
                    names[#names + 1] = player.name
                    out[e] = names
                end
            end
        end
    end
    return out
end

---Most of a send a team can steer to the teams its players tick (science targeting).
Public.FOCUS_SHARE = 0.3
---A fraction as a percent for chat and the science window: '20', '7.5',
---'43.3' (one decimal at most, no trailing '.0').
---@param x number
---@return string
function Public.format_percent(x)
    local tenths = math.floor(x * 1000 + 0.5)
    if tenths % 10 == 0 then
        return string.format('%d', math.floor(tenths / 10))
    end
    return string.format('%.1f', tenths / 10)
end

---Ticks a focus button stays locked after it was clicked (60 s).
Public.FOCUS_COOLDOWN = 3600

---The enemies player `index` of `team` has ticked this round, as a set, or
---nil when none. A pure read: never creates the state.
---@param team string
---@param index integer
---@return table<string, true>|nil
function Public.science_focus(team, index)
    local all = Public.state().science_focus
    local entry = all and all[team] and all[team][index]
    if not entry or next(entry.picks) == nil then
        return nil
    end
    return entry.picks
end

---Tick or untick `enemy` in the science focus of player `index` of `team`.
---Only above two teams, only between two alive active teams, not in training
---mode, and not while that player's button is locked by its cooldown.
---@param team string
---@param enemy string
---@param tick integer
---@param index integer The clicking player's index.
---@return boolean ok
---@return string|boolean result The new state of the button when ok, else why not.
function Public.toggle_science_focus(team, enemy, tick, index)
    local state = Public.state()
    if state.count <= 2 then
        return false, 'science targeting needs three or four teams'
    end
    if (state.feed_policy or DEFAULT_FEED_POLICY) ~= 'split' then
        return false, "science targeting only works with the 'split' feeding policy"
    end
    if storage.training_mode then
        return false, 'science targeting is off in training mode'
    end
    if team == enemy or not state.alive[team] or not state.alive[enemy] then
        return false, 'that team cannot be targeted'
    end
    if not Public.is_active(team) or not Public.is_active(enemy) then
        return false, 'that team cannot be targeted'
    end
    if type(index) ~= 'number' then
        return false, 'no player'
    end
    local all = state.science_focus
    if not all then
        all = {}
        state.science_focus = all
    end
    local team_focus = all[team]
    if not team_focus then
        team_focus = {}
        all[team] = team_focus
    end
    local focus = team_focus[index]
    if not focus then
        focus = { picks = {}, until_tick = {} }
        team_focus[index] = focus
    end
    local locked = focus.until_tick[enemy]
    if locked and tick < locked then
        return false, 'wait ' .. math.ceil((locked - tick) / 60) .. ' s before switching it again'
    end
    focus.until_tick[enemy] = tick + Public.FOCUS_COOLDOWN
    if focus.picks[enemy] then
        focus.picks[enemy] = nil
        return true, false
    end
    focus.picks[enemy] = true
    return true, true
end

---The name to show for a force: the operator's custom name if there is one,
---else the layout's name for the team, else the force name itself.
---
---Same shape as `Functions.team_name` (functions.lua:449-459), extended to the
---two new teams and to the four-square layout, where a compass name would point
---at the wrong corner.
---
---`layout` names the team as another layout would -- the team statistics of a
---previous round played on the other map; omitted, it is the round's layout.
---@param team string
---@param layout string|nil 'horizontal2' or 'cross4'.
---@return string
function Public.display_name(team, layout)
    local custom = storage.tm_custom_name
    local name = custom and custom[team]
    if name ~= nil then
        return name
    end
    local entry = BY_NAME[team]
    if entry then
        layout = layout or Public.state().layout
        if layout == 'cross4' then
            local corners = Config['cross_team_names']
            local corner = corners and corners[team]
            if corner then
                return corner
            end
            return entry.cross_name
        end
        if layout == 'horizontal2' and entry.config_key then
            local configured = Config[entry.config_key]
            if configured then
                return configured
            end
        end
    end
    return team
end

---The team's colour, components in 0..255. A fresh table each call, so a caller
---may keep it or scale it without touching the roster.
---@param team string
---@return { r: integer, g: integer, b: integer }|nil
function Public.color(team)
    local entry = BY_NAME[team]
    if not entry then
        return nil
    end
    local rgb = entry.color
    return { r = rgb.r, g = rgb.g, b = rgb.b }
end

---The same colour as the payload of a `[color=...]` rich-text tag.
---@param team string
---@return string|nil
function Public.text_color(team)
    local entry = BY_NAME[team]
    if not entry then
        return nil
    end
    return entry.text_color
end

---The display name wrapped in the team's colour tag. Byte-identical to
---`Functions.team_name_with_color` (functions.lua:461-470) for north and south,
---spaces after the commas included; anything that is not a team is returned
---uncoloured, as there.
---@param team string
---@return string
function Public.name_with_color(team)
    local name = Public.display_name(team)
    local entry = BY_NAME[team]
    if not entry then
        return name
    end
    return '[color=' .. entry.text_color .. ']' .. name .. '[/color]'
end

---`{ [team] = fn(team) }` over the active teams -- the per-team literals of
---`Init.tables()`.
---@param fn fun(name: string): any
---@return table<string, any>
function Public.per_team(fn)
    local active = Public.state().active
    local built = {}
    for i = 1, #active do
        local name = active[i]
        built[name] = fn(name)
    end
    return built
end

---`{ ['<team>_biters'] = fn('<team>_biters') }` over the active teams. Boss
---forces are not in it: the per-force tables of the round are keyed by the
---regular biter forces.
---@param fn fun(force_name: string): any
---@return table<string, any>
function Public.per_biter_force(fn)
    local active = Public.state().active
    local built = {}
    for i = 1, #active do
        local force_name = Public.biter_force(active[i])
        built[force_name] = fn(force_name)
    end
    return built
end

---Create the forces the round needs, in `all()` order and only when they are
---missing: the team, then its biters, then its boss biters.
---
---`Init.initial_setup()` still creates the seven legacy forces itself, before
---this ever runs, so a two-team game has exactly today's force list and today's
---force indices. 'spectator' is not this module's business.
---@return string[] created The teams whose *team* force this call made, in
---order -- what the caller has to run its one-shot per-force setup on.
function Public.ensure_forces()
    local forces = game.forces
    local active = Public.state().active
    local created = {}
    for i = 1, #active do
        local team = active[i]
        if not forces[team] then
            game.create_force(team)
            created[#created + 1] = team
        end
        local biters = Public.biter_force(team)
        if not forces[biters] then
            game.create_force(biters)
        end
        local boss = Public.boss_force(team)
        if not forces[boss] then
            game.create_force(boss)
        end
    end
    return created
end

---Record that `team` lost its last silo: it stops being alive, the elimination
---is timestamped for the placement and the two alive lists are rebuilt. Doing
---it twice, or to a team that is not playing this round, changes nothing.
---
---`never_played` is for a team that is out before the round starts, because the
---map gave it no silo at all (`init.lua`'s `eliminate_teams_without_a_silo`).
---It leaves the alive set in exactly the same way, but it is not appended to the
---eliminations: a team that never played did not come fourth, and the game-over
---report reads `placement()` as a ranking. Nothing is timestamped for it either, so this form
---does not read `game`.
---@param team string
---@param never_played boolean|nil True when the team is out before the round began.
---@return integer alive How many teams are still alive.
function Public.eliminate(team, never_played)
    local state = Public.state()
    if state.alive[team] ~= true or not Public.is_active(team) then
        return #state.alive_list
    end

    state.alive[team] = nil
    -- A dead team is no longer a science target, nor does it target anyone.
    local all_focus = state.science_focus
    if all_focus then
        all_focus[team] = nil
        for _, team_focus in pairs(all_focus) do
            for _, focus in pairs(team_focus) do
                focus.picks[team] = nil
            end
        end
    end
    if not never_played then
        state.eliminated[#state.eliminated + 1] = { team = team, tick = game.tick }
    end

    local active = state.active
    local alive_list = {}
    local alive_biter_force_list = {}
    for i = 1, #active do
        local name = active[i]
        if state.alive[name] then
            alive_list[#alive_list + 1] = name
            alive_biter_force_list[#alive_biter_force_list + 1] = BY_NAME[name].biter_force
        end
    end
    state.alive_list = alive_list
    state.alive_biter_force_list = alive_biter_force_list
    return #alive_list
end

---Remember that `name` played for a team that was eliminated this round.
---
---Above two teams the round goes on without them: they are moved to the
---spectators and their team choice is cleared, and this flag is what stops them
---joining another team with the choice gone. Forgotten by `begin_round()`, like
---the eliminations themselves -- the next map is a clean slate.
---
---`team` is kept as the value so that the round's result can still say who
---played for a team whose players have long been moved to the spectators
---(`[MATCH-RESULT]`, game_over.lua). Without it the mark is a plain `true`.
---@param name any
---@param team string|nil The team that died, when the caller knows it.
function Public.mark_player_eliminated(name, team)
    if type(name) ~= 'string' then
        return
    end
    Public.state().eliminated_players[name] = type(team) == 'string' and team or true
end

---Everybody who plays or played for a team this round, name => team: `chosen`
---(the caller passes `storage.chosen_team`) and, above two teams, the players an
---elimination moved to the spectators -- their choice was cleared, and the mark
---`mark_player_eliminated` left keeps the team they died with. The scoreboard
---lists from this, so a dead team's players do not vanish from it.
---
---Two teams have no elimination step: `chosen` itself is returned, the very
---table, so a two-team caller iterates exactly what it iterated before. Above
---two teams a fresh table when there is anyone to add, `chosen` otherwise; a
---name with a team choice keeps that choice, and a mark without a team (a plain
---`true`) adds nobody.
---@param chosen table<string, string>|nil
---@return table<string, string>
function Public.round_players(chosen)
    chosen = chosen or {}
    if Public.count() <= 2 then
        return chosen
    end
    local marks = Public.state().eliminated_players
    if next(marks) == nil then
        return chosen
    end
    local merged = {}
    for name, team in pairs(chosen) do
        merged[name] = team
    end
    for name, team in pairs(marks) do
        if merged[name] == nil and type(team) == 'string' then
            merged[name] = team
        end
    end
    return merged
end

---True while `name` is sitting out the round because their team died. Always
---false in a two-team round: it has no elimination step, so nothing marks
---anybody.
---@param name any
---@return boolean
function Public.is_player_eliminated(name)
    return Public.state().eliminated_players[name] ~= nil
end

---The last team standing, or nil while more than one is alive.
---@return string|nil
function Public.winner()
    local alive_list = Public.state().alive_list
    if #alive_list == 1 then
        return alive_list[1]
    end
    return nil
end

---Best first: the winner if there is one, then the eliminated teams in reverse
---order of elimination.
---@return string[]
function Public.placement()
    local state = Public.state()
    local placed = {}
    local winner = Public.winner()
    if winner then
        placed[1] = winner
    end
    local eliminated = state.eliminated
    for i = #eliminated, 1, -1 do
        placed[#placed + 1] = eliminated[i].team
    end
    return placed
end

return Public
