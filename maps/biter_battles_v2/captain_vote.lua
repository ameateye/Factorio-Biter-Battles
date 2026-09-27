-- The in-game CAPTAIN VOTE window: when a BB Captains game is
-- called with more than two captain volunteers, the called players choose how
-- many captains the game has (2 minimum) and may KICK candidates out of the
-- captain list by half of the present electorate.
--
-- INVISIBLE BY DEFAULT, like `count_vote.lua` whose pattern this copies.
-- Nothing runs unless the captain orchestrator opens a vote over RCON
-- (`remote.call('bb_teams', 'open_captain_vote', {...})`). Until then
-- `storage.bb_captain_vote` does not exist, nothing is drawn, nothing is
-- printed and every hook returns at its first test: a server that never votes
-- is byte-identical to the one before this module.
--
-- The three hooks (tick, click, join) are called from `main.lua`, where the
-- scenario's handlers have always been: nothing is registered at runtime.
--
-- The window has NO effect on the game: it does not reset the map, does not
-- set the team count and does not touch the scenario's captain lists. It
-- collects ballots; the orchestrator reads them (`captain_vote_result`),
-- decides and drives the existing flow.

local Color = require('utils.color_presets')
local Model = require('maps.biter_battles_v2.captain_vote_model')
local closable_frame = require('utils.ui.closable_frame')

local Public = {}

local FRAME = 'bb_captain_vote'
local TITLE = 'Captain vote'
local CHOICE = FRAME .. '_choice_'
local KICK = FRAME .. '_kick_'
local CLOSE = FRAME .. '_close'

Public.FRAME_NAME = FRAME

---@return table|nil
local function state()
    return storage.bb_captain_vote
end

---@param vote table
---@return integer
local function seconds_left(vote)
    local left = math.ceil((vote.closes_tick - game.tick) / 60)
    if left < 0 then
        return 0
    end
    return left
end

---The voters connected right now, in the daemon's order.
---@param vote table
---@return string[]
local function present_now(vote)
    local out = {}
    for _, name in ipairs(vote.voters) do
        local p = game.get_player(name)
        if p and p.valid and p.connected then
            out[#out + 1] = name
        end
    end
    return out
end

---@param player LuaPlayer
---@return LuaGuiElement|nil
local function frame_of(player)
    local frame = player.gui.screen[FRAME]
    if frame and frame.valid then
        return frame
    end
    return nil
end

---@param vote table
---@param player LuaPlayer
---@return boolean
local function is_voter(vote, player)
    return Model.has(vote.voters, player.name)
end

---@param vote table
---@param player LuaPlayer
---@param present string[]
---@return string
local function status_caption(vote, player, present)
    if vote.state ~= 'open' then
        return 'Closed. The server announces the captains in a moment.'
    end
    local mine = vote.counts[player.name]
    local n, kept = Model.preview(vote, present)
    return 'Closing in '
        .. seconds_left(vote)
        .. 's. Your vote: '
        .. (mine and (mine .. ' captains') or 'none')
        .. '. If it closed now: '
        .. n
        .. ' captains among '
        .. table.concat(kept, ', ')
        .. '.'
end

---@param vote table
---@param player LuaPlayer
---@param present string[]
local function fill(frame, vote, player, present)
    local tally = Model.tally(vote.counts, vote.choices, present)
    local counts = frame[FRAME .. '_counts']
    if counts then
        for _, n in ipairs(vote.choices) do
            local b = counts[CHOICE .. n]
            if b then
                b.caption = n .. ' captains (' .. tally[n] .. ')'
                b.style.font_color = (vote.counts[player.name] == n) and { r = 0.2, g = 0.8, b = 0.2 }
                    or { r = 0, g = 0, b = 0 }
            end
        end
    end
    local kt = Model.kick_tally(vote.kicks, vote.cands, present)
    local mine = vote.kicks[player.name] or {}
    local grid = frame[FRAME .. '_cands']
    for i, c in ipairs(vote.cands) do
        local l = grid[FRAME .. '_tally_' .. i]
        if l then
            l.caption = 'kick ' .. kt[c] .. '/' .. Model.need(c, present)
        end
        local b = grid[KICK .. i]
        if b then
            b.caption = mine[c] and 'Undo kick' or 'Kick'
        end
    end
    frame[FRAME .. '_status'].caption = status_caption(vote, player, present)
end

---@param player LuaPlayer
local function draw(player)
    local vote = state()
    if not vote or vote.state ~= 'open' or not is_voter(vote, player) or frame_of(player) then
        return
    end
    local frame = closable_frame.create_draggable_frame(player, FRAME, TITLE, { no_dragger = true })
    local intro = frame.add({
        type = 'label',
        name = FRAME .. '_intro',
        caption = 'More than 2 captain volunteers for this game: choose how many captains, and kick the ones you do not want (half of the players here kicks).',
    })
    intro.style.single_line = false
    intro.style.maximal_width = 420
    if #vote.choices > 1 then
        frame.add({ type = 'label', name = FRAME .. '_counts_label', caption = 'How many captains (= teams)?' })
        local counts = frame.add({ type = 'flow', name = FRAME .. '_counts', direction = 'horizontal' })
        for _, n in ipairs(vote.choices) do
            local b = counts.add({ type = 'button', name = CHOICE .. n, caption = n .. ' captains' })
            b.style.minimal_width = 110
        end
    else
        frame.add({
            type = 'label',
            name = FRAME .. '_counts_label',
            caption = 'This game is played with ' .. vote.choices[1] .. ' captains.',
        })
    end
    frame.add({ type = 'label', name = FRAME .. '_cands_label', caption = 'Captain candidates:' })
    local grid = frame.add({ type = 'table', name = FRAME .. '_cands', column_count = 3 })
    for i, c in ipairs(vote.cands) do
        local name = grid.add({ type = 'label', name = FRAME .. '_name_' .. i, caption = c })
        name.style.minimal_width = 140
        grid.add({ type = 'label', name = FRAME .. '_tally_' .. i, caption = '' })
        if c == player.name then
            grid.add({ type = 'label', name = FRAME .. '_self_' .. i, caption = '(you)' })
        else
            grid.add({ type = 'button', name = KICK .. i, caption = 'Kick' })
        end
    end
    local status = frame.add({ type = 'label', name = FRAME .. '_status', caption = '' })
    status.style.single_line = false
    status.style.maximal_width = 420
    if is_admin(player) then
        frame.add({ type = 'button', name = CLOSE, caption = 'Close now (admin)' })
    end
    fill(frame, vote, player, present_now(vote))
end

---@param player LuaPlayer
---@param present string[]
local function refresh(player, present)
    local frame = frame_of(player)
    if not frame then
        return
    end
    local vote = state()
    if not vote or vote.state ~= 'open' then
        frame.destroy()
        return
    end
    fill(frame, vote, player, present)
end

local function refresh_all()
    local vote = state()
    local present = vote and present_now(vote) or {}
    for _, player in ipairs(game.connected_players) do
        refresh(player, present)
    end
end

---@param closed_by string|nil
local function close(closed_by)
    local vote = state()
    if not vote or vote.state ~= 'open' then
        return
    end
    vote.present = present_now(vote)
    vote.state = 'closed'
    vote.closed_by = closed_by
    vote.closes_tick = game.tick
    refresh_all()
    game.print(
        '[captain-vote] The captain vote is closed'
            .. (closed_by and (' (by ' .. closed_by .. ')') or '')
            .. ' — the captains are announced in a moment.',
        { color = Color.info }
    )
end

---Open a vote. Refused while one is open.
---@param options any
---@return boolean ok
---@return string|nil reason
function Public.open(options)
    local vote = state()
    if vote and vote.state == 'open' then
        return false, 'a captain vote is already open'
    end
    local o, reason = Model.normalise_open(options)
    if not o then
        return false, reason
    end
    storage.bb_captain_vote = {
        state = 'open',
        game = o.game,
        cands = o.cands,
        voters = o.voters,
        choices = o.choices,
        default_n = o.default_n,
        counts = {},
        kicks = {},
        closes_tick = game.tick + o.seconds * 60,
    }
    for _, player in ipairs(game.connected_players) do
        draw(player)
    end
    game.print(
        '[captain-vote] Captain vote for BB Captains game #'
            .. o.game
            .. ' among '
            .. table.concat(o.cands, ', ')
            .. ' — the called players vote now, '
            .. o.seconds
            .. 's.',
        { color = Color.info }
    )
    return true
end

---@param closed_by string|nil
---@return boolean ok
---@return string|nil reason
function Public.close(closed_by)
    local vote = state()
    if not vote or vote.state ~= 'open' then
        return false, 'no captain vote is open'
    end
    close(closed_by)
    return true
end

---The raw ballots, as the orchestrator reads them.
---`kicks` is voter -> list of candidates (a JSON-friendly array).
---@return table
function Public.result()
    local vote = state()
    if not vote then
        return { state = 'idle' }
    end
    local kicks = {}
    for voter, set in pairs(vote.kicks) do
        local l = {}
        for _, c in ipairs(vote.cands) do
            if set[c] then
                l[#l + 1] = c
            end
        end
        if #l > 0 then
            kicks[voter] = l
        end
    end
    local counts = {}
    for voter, n in pairs(vote.counts) do
        counts[voter] = n
    end
    return {
        state = vote.state,
        game = vote.game,
        cands = vote.cands,
        choices = vote.choices,
        counts = counts,
        kicks = kicks,
        present = vote.state == 'open' and present_now(vote) or vote.present,
        closed_by = vote.closed_by,
        left_s = vote.state == 'open' and seconds_left(vote) or 0,
    }
end

-- ---------------------------------------------------------------------------
-- The hooks `main.lua` calls. Each returns at its first test with no vote open.
-- ---------------------------------------------------------------------------

---@param tick integer
function Public.on_tick(tick)
    local vote = state()
    if not vote or vote.state ~= 'open' then
        return
    end
    if tick >= vote.closes_tick then
        close(nil)
        return
    end
    if tick % 60 == 0 then
        refresh_all()
    end
end

---@param player LuaPlayer|nil
---@param element LuaGuiElement
---@return boolean handled
function Public.on_gui_click(player, element)
    local name = element.name
    if name:sub(1, #FRAME) ~= FRAME then
        return false
    end
    local vote = state()
    if not player or not vote or vote.state ~= 'open' then
        return false
    end
    if name == CLOSE then
        if not is_admin(player) then
            player.print("[ERROR] You're not admin!", { color = Color.fail })
            return true
        end
        close(player.name)
        return true
    end
    if not is_voter(vote, player) then
        return true
    end
    local choice = name:match('^' .. CHOICE .. '(%d+)$')
    if choice then
        local n = tonumber(choice)
        if Model.offers(n, vote.choices) then
            vote.counts[player.name] = n
            refresh_all()
        end
        return true
    end
    local idx = name:match('^' .. KICK .. '(%d+)$')
    if idx then
        local c = vote.cands[tonumber(idx)]
        if c and c ~= player.name then
            local mine = vote.kicks[player.name] or {}
            if mine[c] then
                mine[c] = nil
            else
                mine[c] = true
            end
            vote.kicks[player.name] = mine
            refresh_all()
        end
        return true
    end
    return false
end

---A voter joining while the vote is open gets the window.
---@param player LuaPlayer
function Public.on_player_joined_game(player)
    local vote = state()
    if not vote or vote.state ~= 'open' then
        return
    end
    draw(player)
end

return Public
