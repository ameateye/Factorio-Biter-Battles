---@diagnostic disable
--
-- Science targeting window (maps/biter_battles_v2/science_window.lua): one
-- window per team member in gui.screen, a tick box per enemy team drawn like
-- the end-of-game role buttons (mark + colour on a button); each player has
-- his own ticks and sees the team's live shares and who ticked what. Runs the real
-- build/paint code on a fake element tree and pins what a player sees at 2,
-- 3 and 4 teams, after a tick, after an elimination and on a 4 -> 3 change.

local lunatest = require('lunatest')

storage = { ['_TEST'] = true }

local Teams = require('maps.biter_battles_v2.teams')
local ScienceWindow = require('maps.biter_battles_v2.science_window')

-- A minimal LuaGuiElement: add / children / destroy / lookup by name.
local function element(spec, parent)
    local e = { type = spec.type, name = spec.name, caption = spec.caption, visible = true, style = {} }
    e.valid = true
    e.children = {}
    e.parent = parent
    function e.add(s)
        assert(s.name == nil or rawget(e, s.name) == nil, 'duplicate element ' .. tostring(s.name))
        local c = element(s, e)
        e.children[#e.children + 1] = c
        if s.name then
            rawset(e, s.name, c)
        end
        return c
    end
    function e.destroy()
        e.valid = false
        local p = e.parent
        for i, c in ipairs(p.children) do
            if c == e then
                table.remove(p.children, i)
                break
            end
        end
        if e.name then
            rawset(p, e.name, nil)
        end
    end
    return e
end

local players = {}
local next_index = 0

local function sync_forces()
    local forces = {}
    for _, name in ipairs({ 'north', 'east', 'south', 'west', 'spectator' }) do
        forces[name] = { name = name, connected_players = {} }
    end
    for i = 1, next_index do
        local p = players[i]
        if p and p.connected then
            local list = forces[p.force.name].connected_players
            list[#list + 1] = p
        end
    end
    game.forces = forces
end

local function new_player(name, force)
    local root = element({ type = 'screen' })
    next_index = next_index + 1
    local p = {
        index = next_index,
        name = name,
        valid = true,
        connected = true,
        force = { name = force },
        gui = { screen = root },
    }
    players[next_index] = p
    sync_forces()
    return p
end

local function round_of(count)
    lunatest.assert_true(Teams.set_next_count(count))
    return Teams.begin_round()
end

-- 'caption|visible' of every tick box, in team order
local function boxes(player)
    local f = player.gui.screen[ScienceWindow.NAME]
    local parts = {}
    for _, b in ipairs(f.picks.children) do
        parts[#parts + 1] = b.caption .. (b.visible and '' or '(hidden)')
    end
    return table.concat(parts, ',')
end

function setup()
    storage = { ['_TEST'] = true, chosen_team = {} }
    players = {}
    next_index = 0
    game = {
        tick = 0,
        forces = {},
        get_player = function(index)
            return players[index]
        end,
    }
    sync_forces()
end

function test_two_teams_never_open()
    Teams.begin_round()
    local p = new_player('a', 'north')
    storage.chosen_team.a = 'north'
    lunatest.assert_false(ScienceWindow.allowed(p))
    ScienceWindow.toggle(p)
    lunatest.assert_nil(p.gui.screen[ScienceWindow.NAME])
    ScienceWindow.refresh(p)
    lunatest.assert_equal(0, #p.gui.screen.children)
end

function test_four_teams_window_ticks_and_shares()
    round_of(4)
    local p = new_player('a', 'north')
    storage.chosen_team.a = 'north'
    ScienceWindow.toggle(p)
    local f = p.gui.screen[ScienceWindow.NAME]
    lunatest.assert_not_nil(f)
    lunatest.assert_not_nil(f.bar.bb_science_window_close)
    lunatest.assert_equal('SCIENCE TARGET - ' .. Teams.display_name('north'), f.bar.title.caption)
    local n, e, s, w =
        Teams.display_name('north'), Teams.display_name('east'), Teams.display_name('south'), Teams.display_name('west')
    lunatest.assert_equal('· ' .. n .. '(hidden),· ' .. e .. ',· ' .. s .. ',· ' .. w, boxes(p))
    -- the tick itself goes through teams.lua (the gui.lua click handler); the window repaints from storage
    lunatest.assert_true(Teams.toggle_science_focus('north', 'south', 0, p.index))
    ScienceWindow.refresh(p)
    lunatest.assert_equal('✔ ' .. s, f.picks.bb_science_focus_south.caption)
    lunatest.assert_equal(0.95, f.picks.bb_science_focus_south.style.font_color.g)
    lunatest.assert_equal('· ' .. e, f.picks.bb_science_focus_east.caption)
    -- alone on the team: a steers the whole 30 %
    lunatest.assert_equal(
        'Each send of your team now goes: ' .. e .. ' 23.3 %, ' .. s .. ' 53.3 % (focus 30 %: a), ' .. w .. ' 23.3 %',
        f.shares.caption
    )
    lunatest.assert_equal('Ticks: a: ' .. s, f.backers.caption)
    -- a team mate joins: his own ticks start empty, a now steers 15 %
    local q = new_player('b', 'north')
    storage.chosen_team.b = 'north'
    ScienceWindow.toggle(q)
    local g = q.gui.screen[ScienceWindow.NAME]
    lunatest.assert_equal('· ' .. n .. '(hidden),· ' .. e .. ',· ' .. s .. ',· ' .. w, boxes(q))
    lunatest.assert_equal(
        'Each send of your team now goes: ' .. e .. ' 28.3 %, ' .. s .. ' 43.3 % (focus 15 %: a), ' .. w .. ' 28.3 %',
        g.shares.caption
    )
    lunatest.assert_equal('Ticks: a: ' .. s .. '; b: none', g.backers.caption)
    lunatest.assert_not_nil(string.find(g.head.caption, ' 15 % of every send of your team', 1, true))
    -- b ticks south too: aligned, the full 30 %
    Teams.toggle_science_focus('north', 'south', 0, q.index)
    ScienceWindow.refresh(p)
    ScienceWindow.refresh(q)
    lunatest.assert_equal(boxes(p), boxes(q))
    lunatest.assert_equal(
        'Each send of your team now goes: ' .. e .. ' 23.3 %, ' .. s .. ' 53.3 % (focus 30 %: a, b), ' .. w .. ' 23.3 %',
        f.shares.caption
    )
    -- b switches to east: 15 % each
    Teams.toggle_science_focus('north', 'south', 3600, q.index)
    Teams.toggle_science_focus('north', 'east', 3600, q.index)
    ScienceWindow.refresh(p)
    lunatest.assert_equal(
        'Each send of your team now goes: '
            .. e
            .. ' 38.3 % (focus 15 %: b), '
            .. s
            .. ' 38.3 % (focus 15 %: a), '
            .. w
            .. ' 23.3 %',
        f.shares.caption
    )
    lunatest.assert_equal('Ticks: a: ' .. s .. '; b: ' .. e, f.backers.caption)
    lunatest.assert_equal('✔ ' .. s, f.picks.bb_science_focus_south.caption)
    lunatest.assert_equal('· ' .. e, f.picks.bb_science_focus_east.caption)
    -- b goes offline: his tick stops counting
    q.connected = false
    sync_forces()
    ScienceWindow.refresh(p)
    lunatest.assert_equal('Ticks: a: ' .. s, f.backers.caption)
    lunatest.assert_equal(
        'Each send of your team now goes: ' .. e .. ' 23.3 %, ' .. s .. ' 53.3 % (focus 30 %: a), ' .. w .. ' 23.3 %',
        f.shares.caption
    )
    -- an enemy's window does not show north's ticks
    local r = new_player('c', 'east')
    storage.chosen_team.c = 'east'
    ScienceWindow.toggle(r)
    lunatest.assert_equal('· ' .. s, r.gui.screen[ScienceWindow.NAME].picks.bb_science_focus_south.caption)
    -- the open button toggles it closed
    ScienceWindow.toggle(p)
    lunatest.assert_nil(p.gui.screen[ScienceWindow.NAME])
end

function test_three_teams_and_rebuild_on_count_change()
    round_of(4)
    local p = new_player('a', 'north')
    storage.chosen_team.a = 'north'
    ScienceWindow.toggle(p)
    lunatest.assert_equal(4, #p.gui.screen[ScienceWindow.NAME].picks.children)
    round_of(3)
    ScienceWindow.refresh(p)
    local f = p.gui.screen[ScienceWindow.NAME]
    lunatest.assert_equal(3, #f.picks.children)
    lunatest.assert_nil(f.picks.bb_science_focus_west)
    Teams.toggle_science_focus('north', 'east', 0, p.index)
    ScienceWindow.refresh(p)
    lunatest.assert_equal(
        'Each send of your team now goes: '
            .. Teams.display_name('east')
            .. ' 65.0 % (focus 30 %: a), '
            .. Teams.display_name('south')
            .. ' 35.0 %',
        f.shares.caption
    )
end

function test_eliminations_hide_and_close()
    round_of(4)
    local p = new_player('a', 'north')
    storage.chosen_team.a = 'north'
    ScienceWindow.toggle(p)
    Teams.eliminate('south')
    ScienceWindow.refresh(p)
    lunatest.assert_false(p.gui.screen[ScienceWindow.NAME].picks.bb_science_focus_south.visible)
    Teams.eliminate('north')
    ScienceWindow.refresh(p)
    lunatest.assert_nil(p.gui.screen[ScienceWindow.NAME])
    ScienceWindow.toggle(p)
    lunatest.assert_nil(p.gui.screen[ScienceWindow.NAME])
end

function test_spectator_and_training_mode_refused()
    round_of(4)
    local p = new_player('a', 'spectator')
    lunatest.assert_false(ScienceWindow.allowed(p))
    local q = new_player('b', 'north')
    storage.chosen_team.b = 'north'
    ScienceWindow.toggle(q)
    storage.training_mode = true
    ScienceWindow.refresh(q)
    lunatest.assert_nil(q.gui.screen[ScienceWindow.NAME])
end

lunatest.run()
