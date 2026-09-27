-- The in-game window "Number of teams for this match": three
-- buttons, one ballot per player, a countdown, and an admin-only Force row.
--
-- INVISIBLE BY DEFAULT, and that is the contract. Nothing here runs unless
-- someone opens a vote -- `remote.call('bb_teams', 'open_count_vote', ...)` or
-- the admin command `/team-count vote [seconds]`. Until then
-- `storage.bb_count_vote` does not exist, no element is added to any player's
-- screen, nothing is printed and every entry point below returns at its first
-- test. A two-team server that never opens the vote is byte-identical to the
-- one before this window existed.
--
-- The three hooks (tick, click, join) are called from `main.lua`, which is
-- where the scenario's on_tick / on_gui_click / on_player_joined_game handlers
-- have always been: no event and no nth-tick is registered at runtime, so a
-- client joining mid-vote runs exactly the handler set the server does.
--
-- What the vote does NOT do: it does not reset the map and it does not touch
-- the round being played. Its whole effect is one `Teams.set_next_count(n)`,
-- the pending request the daemon or an admin turns into a map at the next
-- reset.
--
-- The tally and the winner are `count_vote_model.lua`, which has no Factorio in
-- it and is unit-tested.

local Color = require('utils.color_presets')
local Model = require('maps.biter_battles_v2.count_vote_model')
local Teams = require('maps.biter_battles_v2.teams')
local closable_frame = require('utils.ui.closable_frame')

local Public = {}

--- The window, and the prefix every element of it is named with. No element of
--- the scenario has ever started with it, which is what makes the click hook a
--- single string compare on a server that never votes.
local FRAME = 'bb_count_vote'
local TITLE = 'Number of teams for this match'
local CHOICE = FRAME .. '_choice_'
local FORCE = FRAME .. '_force_'

Public.FRAME_NAME = FRAME

---The vote, or nil when there has never been one in this save.
---@return table|nil
local function state()
    return storage.bb_count_vote
end

---@param n integer
---@param tally table<integer, integer>
---@return string
local function choice_caption(n, tally)
    return n .. ' teams (' .. tally[n] .. ')'
end

---@param vote table
---@return integer seconds
local function seconds_left(vote)
    local left = math.ceil((vote.closes_tick - game.tick) / 60)
    if left < 0 then
        return 0
    end
    return left
end

---The one line under the buttons: how long is left and what this player voted.
---@param vote table
---@param player LuaPlayer
---@return string
local function status_caption(vote, player)
    if vote.state ~= 'open' then
        return 'Closed. This match is played with ' .. vote.count .. ' teams.'
    end
    local mine = vote.votes[player.name]
    return 'Closing in ' .. seconds_left(vote) .. 's. Your vote: ' .. (mine and (mine .. ' teams') or 'none') .. '.'
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

---Draw the window for one player. Admins get the Force row and nobody else
---does: the row is built only inside `is_admin`, so a non-admin's element tree
---does not carry it at all.
---@param player LuaPlayer
local function draw(player)
    local vote = state()
    if not vote or vote.state ~= 'open' then
        return
    end
    if frame_of(player) then
        return
    end

    local frame = closable_frame.create_draggable_frame(player, FRAME, TITLE, { no_dragger = true })

    local choices = frame.add({ type = 'flow', name = FRAME .. '_choices', direction = 'horizontal' })
    local tally = Model.tally(vote.votes, vote.choices)
    for _, n in ipairs(vote.choices) do
        local button = choices.add({
            type = 'button',
            name = CHOICE .. n,
            caption = choice_caption(n, tally),
        })
        button.style.minimal_width = 110
    end

    frame.add({ type = 'label', name = FRAME .. '_status', caption = status_caption(vote, player) })

    if is_admin(player) then
        local row = frame.add({ type = 'flow', name = FRAME .. '_admin', direction = 'horizontal' })
        row.add({ type = 'label', name = FRAME .. '_admin_label', caption = 'Force (admin):' })
        for _, n in ipairs(vote.choices) do
            row.add({ type = 'button', name = FORCE .. n, caption = tostring(n) })
        end
    end
end

---Bring one player's window up to date, or destroy it once the vote is over.
---@param player LuaPlayer
local function refresh(player)
    local frame = frame_of(player)
    if not frame then
        return
    end
    local vote = state()
    if not vote or vote.state ~= 'open' then
        frame.destroy()
        return
    end

    local tally = Model.tally(vote.votes, vote.choices)
    local choices = frame[FRAME .. '_choices']
    for _, n in ipairs(vote.choices) do
        local button = choices[CHOICE .. n]
        if button then
            button.caption = choice_caption(n, tally)
        end
    end
    frame[FRAME .. '_status'].caption = status_caption(vote, player)
end

---Every connected player, in `game.connected_players` order -- the order the
---engine hands out, the same on every peer.
---@param fn fun(player: LuaPlayer)
local function for_each_player(fn)
    for _, player in ipairs(game.connected_players) do
        fn(player)
    end
end

---Close the vote: read the ballots, record the count and say so. `forced_by` is
---the admin's name when the Force row ended it, nil when the countdown did.
---@param forced_by string|nil
---@param count integer|nil The count an admin forced; nil to count the ballots.
local function close(forced_by, count)
    local vote = state()
    if not vote or vote.state ~= 'open' then
        return
    end

    local elected = count
    if not elected then
        elected = Model.result(vote.votes, vote.choices)
    end

    vote.state = 'closed'
    vote.count = elected
    vote.forced_by = forced_by
    vote.closes_tick = game.tick

    -- The one effect of the whole vote: a pending request, applied by
    -- `Teams.begin_round()` at the next map reset. Nothing here resets the map.
    local ok, reason = Teams.set_next_count(elected)

    for_each_player(refresh)

    if not ok then
        game.print('[team-count] the vote elected ' .. elected .. ' teams but it was refused: ' .. reason, {
            color = Color.fail,
        })
        return
    end

    local tally = Model.tally(vote.votes, vote.choices)
    local parts = {}
    for _, n in ipairs(vote.choices) do
        parts[#parts + 1] = n .. ': ' .. tally[n]
    end
    game.print(
        '[team-count] Number of teams for this match: '
            .. elected
            .. (forced_by and (' (forced by ' .. forced_by .. ')') or '')
            .. ' ['
            .. table.concat(parts, ', ')
            .. ']. It applies at the next map reset.',
        { color = Color.success }
    )
end

---Open a vote. Refuses while one is already open.
---@param options table|nil `{ timeout_s = 60, choices = { 2, 3, 4 } }`
---@return boolean ok
---@return string|nil reason Why the call was refused, when it was.
function Public.open(options)
    if options ~= nil and type(options) ~= 'table' then
        return false, 'open_count_vote takes a table of options'
    end
    options = options or {}

    local vote = state()
    if vote and vote.state == 'open' then
        return false, 'a team-count vote is already open'
    end

    local seconds, reason = Model.normalise_timeout(options.timeout_s)
    if not seconds then
        return false, reason
    end
    local choices
    choices, reason = Model.normalise_choices(options.choices)
    if not choices then
        return false, reason
    end

    -- The first and only write to `storage` this window ever makes.
    storage.bb_count_vote = {
        state = 'open',
        choices = choices,
        votes = {},
        closes_tick = game.tick + seconds * 60,
        count = nil,
        forced_by = nil,
    }

    for_each_player(draw)
    game.print('[team-count] ' .. TITLE .. ': vote now, ' .. seconds .. 's.', { color = Color.info })
    return true
end

---Close an open vote early. `count` forces a count, nil counts the ballots.
---@param forced_by string|nil
---@param count integer|nil
---@return boolean ok
---@return string|nil reason
function Public.close(forced_by, count)
    local vote = state()
    if not vote or vote.state ~= 'open' then
        return false, 'no team-count vote is open'
    end
    if count ~= nil and not Model.offers(count, vote.choices) then
        return false, 'this vote does not offer ' .. tostring(count) .. ' teams'
    end
    close(forced_by, count)
    return true
end

---The vote as the daemon reads it.
---@return table
function Public.result()
    local vote = state()
    if not vote then
        return { state = 'idle', votes = {} }
    end
    local tally = Model.tally(vote.votes, vote.choices)
    return {
        state = vote.state,
        count = vote.count,
        forced_by = vote.forced_by,
        votes = tally,
        closes_tick = vote.closes_tick,
    }
end

-- ---------------------------------------------------------------------------
-- The three hooks `main.lua` calls. Each one returns at its first test when no
-- vote has ever been opened.
-- ---------------------------------------------------------------------------

---@param tick integer
function Public.on_tick(tick)
    local vote = state()
    if not vote or vote.state ~= 'open' then
        return
    end
    if tick >= vote.closes_tick then
        close(nil, nil)
        return
    end
    if tick % 60 == 0 then
        for_each_player(refresh)
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

    local choice = name:match('^' .. CHOICE .. '(%d+)$')
    if choice then
        local n = tonumber(choice)
        if Model.offers(n, vote.choices) then
            vote.votes[player.name] = n
            for_each_player(refresh)
        end
        return true
    end

    local forced = name:match('^' .. FORCE .. '(%d+)$')
    if forced then
        if not is_admin(player) then
            player.print("[ERROR] You're not admin!", { color = Color.fail })
            return true
        end
        Public.close(player.name, tonumber(forced))
        return true
    end

    return false
end

---A player joining while a vote is open gets the window.
---@param player LuaPlayer
function Public.on_player_joined_game(player)
    local vote = state()
    if not vote or vote.state ~= 'open' then
        return
    end
    draw(player)
end

return Public
