-- Science targeting window: above two
-- teams under the 'split' policy, each team member can open one window in
-- gui.screen with a tick box per enemy team. The ticks are the player's own
-- (each connected player steers 1/N of the team's focus); the window also
-- shows the team's live shares and who ticked what. The tick boxes are drawn
-- like the end-of-game role buttons: a button whose mark and colour flip, never a
-- checkbox element (buttons only, for multiplayer safety). The click itself is
-- handled in gui.lua ('bb_science_focus_<team>' -> Teams.toggle_science_focus);
-- this module only builds and paints the window from storage.
local Teams = require('maps.biter_battles_v2.teams')
local gui_style = require('utils.utils').gui_style

local math_floor = math.floor
local string_format = string.format

local Public = {}

local SCIENCE_WINDOW = 'bb_science_window'
Public.NAME = SCIENCE_WINDOW
local SCIENCE_MARK_ON = '✔ '
local SCIENCE_MARK_OFF = '· '
local SCIENCE_ON_COLOR = { r = 0.35, g = 0.95, b = 0.45 }
local SCIENCE_OFF_COLOR = { r = 0.85, g = 0.85, b = 0.85 }

---True when `player` may see the science window: the focus is offered, the
---player plays for a team that is alive, and it is not training mode.
function Public.allowed(player)
    local mine = player.force.name
    return Teams.science_focus_offered()
        and not storage.training_mode
        and storage.chosen_team[player.name] ~= nil
        and Teams.index_of(mine) ~= nil
        and Teams.is_alive(mine)
end

local function build_science_window(player)
    local f = player.gui.screen.add({ type = 'frame', name = SCIENCE_WINDOW, direction = 'vertical' })
    f.auto_center = true
    local bar = f.add({ type = 'flow', name = 'bar', style = 'frame_header_flow', direction = 'horizontal' })
    bar.drag_target = f
    local title = bar.add({ type = 'label', name = 'title', style = 'frame_title' })
    title.drag_target = f
    local fil = bar.add({ type = 'empty-widget', style = 'draggable_space_header' })
    fil.drag_target = f
    gui_style(fil, { horizontally_stretchable = true, height = 24 })
    local x = bar.add({ type = 'button', name = 'bb_science_window_close', caption = 'X', tooltip = 'Close' })
    gui_style(x, { width = 32, height = 24, padding = 0 })
    local head = f.add({ type = 'label', name = 'head' })
    gui_style(head, { single_line = false, maximal_width = 360 })
    local row = f.add({ type = 'flow', name = 'picks', direction = 'horizontal' })
    for _, team in ipairs(Teams.all()) do
        row.add({ type = 'button', name = 'bb_science_focus_' .. team, caption = Teams.display_name(team) })
    end
    local shares = f.add({ type = 'label', name = 'shares' })
    gui_style(shares, { single_line = false, maximal_width = 360 })
    local backers = f.add({ type = 'label', name = 'backers' })
    gui_style(backers, { single_line = false, maximal_width = 360 })
    return f
end

---Keeps `player`'s science window in step with storage: destroys it when it
---is not allowed any more, rebuilds it when the round's teams changed, and
---repaints marks and shares. No-op when the window is closed.
function Public.refresh(player)
    local f = player.gui.screen[SCIENCE_WINDOW]
    if not f then
        return
    end
    if not Public.allowed(player) then
        f.destroy()
        return
    end
    local stale = #f.picks.children ~= #Teams.all()
    for _, team in ipairs(Teams.all()) do
        stale = stale or not f.picks['bb_science_focus_' .. team]
    end
    if stale then
        f.destroy()
        f = build_science_window(player)
    end
    local mine = player.force.name
    local share = math_floor(Teams.FOCUS_SHARE * 100 + 0.5)
    f.bar.title.caption = 'SCIENCE TARGET - ' .. Teams.display_name(mine)
    f.head.caption = "Tick enemy teams to steer your part of your team's "
        .. share
        .. ' % focus: '
        .. Teams.format_percent(Public.player_part(mine))
        .. ' % of every send of your team, split evenly over the teams you tick (each connected player of your'
        .. ' team steers an equal part, with his own ticks). The rest is split evenly over all enemy teams.'
    local picks = Teams.science_focus(mine, player.index)
    for _, team in ipairs(Teams.all()) do
        local b = f.picks['bb_science_focus_' .. team]
        local visible = team ~= mine and Teams.is_alive(team)
        b.visible = visible
        local on = visible and picks ~= nil and picks[team] == true
        b.caption = (on and SCIENCE_MARK_ON or SCIENCE_MARK_OFF) .. Teams.display_name(team)
        b.style.font_color = on and SCIENCE_ON_COLOR or SCIENCE_OFF_COLOR
    end
    f.shares.caption = 'Each send of your team now goes: ' .. Public.shares_text(mine, false)
    f.backers.caption = 'Ticks: ' .. Public.ticks_text(mine)
end

---Who of `team` ticked what, per connected player: 'Alice: East; Bob: East,
---South; Carol: none'. Only the counted players (connected, on the team).
---@param team string
---@return string
function Public.ticks_text(team)
    local force = game.forces[team]
    local parts = {}
    for _, p in ipairs(force and force.connected_players or {}) do
        local picks = Teams.science_focus(team, p.index)
        local names = {}
        for _, e in ipairs(Teams.enemies_of(team)) do
            if picks and picks[e] then
                names[#names + 1] = Teams.display_name(e)
            end
        end
        parts[#parts + 1] = p.name .. ': ' .. (#names > 0 and table.concat(names, ', ') or 'none')
    end
    return table.concat(parts, '; ')
end

---The part of every send one connected player of `team` steers:
---FOCUS_SHARE / N, N = the connected players on the team's force (at least 1).
---@param team string
---@return number
function Public.player_part(team)
    local force = game.forces[team]
    local n = force and #force.connected_players or 0
    return Teams.FOCUS_SHARE / math.max(n, 1)
end

---What the next send of `team` does: 'East 43.3 % (focus 20 %: Alice, Bob),
---South 26.7 %, West 30 %'.
---@param team string
---@param colored boolean Rich-text team names (chat) or plain (window).
---@return string
function Public.shares_text(team, colored)
    local backers = Teams.focus_backers(team)
    local parts = {}
    for _, target in ipairs(Teams.feed_targets(team)) do
        local text = (colored and Teams.name_with_color(target.team) or Teams.display_name(target.team))
            .. ' '
            .. string_format('%.1f', target.share * 100)
            .. ' %'
        if target.focused then
            text = text .. ' (focus ' .. Teams.format_percent(target.focus) .. ' %'
            if backers[target.team] then
                text = text .. ': ' .. table.concat(backers[target.team], ', ')
            end
            text = text .. ')'
        end
        parts[#parts + 1] = text
    end
    return table.concat(parts, ', ')
end

---Opens (or closes, when open) `player`'s science window.
function Public.toggle(player)
    local f = player.gui.screen[SCIENCE_WINDOW]
    if f then
        f.destroy()
        return
    end
    if not Public.allowed(player) then
        return
    end
    build_science_window(player)
    Public.refresh(player)
end

return Public
