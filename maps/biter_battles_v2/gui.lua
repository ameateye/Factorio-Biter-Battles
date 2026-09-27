local _DEBUG = false

local Admin = require('utils.admin')
local Captain_event = require('comfy_panel.special_games.captain')
local Color = require('utils.color_presets')
local DifficultyVote = require('maps.biter_battles_v2.difficulty_vote')
local Event = require('utils.event')
local Feeding = require('maps.biter_battles_v2.feeding')
local FeedingRestriction = require('maps.biter_battles_v2.feeding_restriction')
local Functions = require('maps.biter_battles_v2.functions')
local Init = require('maps.biter_battles_v2.init')
local Gui = require('utils.gui')
local PlayerUtils = require('utils.player')
local ResearchInfo = require('maps.biter_battles_v2.research_info')
local Server = require('utils.server')
local ScienceWindow = require('maps.biter_battles_v2.science_window')
local Shortcuts = require('maps.biter_battles_v2.shortcuts')
local Tables = require('maps.biter_battles_v2.tables')
local Teams = require('maps.biter_battles_v2.teams')
local TeamStatsCompare = require('maps.biter_battles_v2.team_stats_compare')
local gui_style = require('utils.utils').gui_style
local has_life = require('comfy_panel.special_games.limited_lives').has_life
local MultiSilo = require('comfy_panel.special_games.multi_silo')
local NteamWording = require('maps.biter_battles_v2.nteam_wording')
local FeatureFlags = require('maps.biter_battles_v2.feature_flags')
local CraftingQueueList = require('commands.crafting_queue_list')

local food_names = Tables.gui_foods

local math_random = math.random
local math_abs = math.abs
local math_ceil = math.ceil
local math_floor = math.floor
local string_format = string.format
local string_match = string.match

local Public = {}
storage.player_data_afk = {}

--- This file's own team palette, by ring position (1 north, 2 east, 3 south,
--- 4 west). Positions 1 and 3 are the two shades the legacy `gui_values` table
--- drew with; they are deliberately not `Teams.color()`, which is the chat
--- palette (`functions.lua:461-470`) and a different colour. A team without a
--- legacy shade gets the registry colour scaled to 0..1.
local ring_color1 = {
    [1] = { r = 0.55, g = 0.55, b = 0.99 },
    [3] = { r = 0.99, g = 0.33, b = 0.33 },
}

--- One entry of the old `gui_values` table, generated from the registry at use
--- time so that every team of the round has one. With two teams every field is
--- byte for byte what the literal table held:
---
---   * `biter_force` -- '<team>_biters';
---   * `t1` -- 'Evolution of north side biters.': with two teams the force name
---     *is* the compass side, so the sentence rebuilds itself; above two teams
---     a compass word would point at the wrong corner and the display name is
---     used instead;
---   * `t2` -- the same sentence for every team;
---   * `color1` -- the palette above;
---   * `cpt_idx` -- the team's slot in the captain list: 1 and 2 with two
---     teams, and `Teams.index_of()` above (captainList[i] is the captain of
---     the i-th team of the round).
---
--- The dead `n1` and `color2` fields of the old table are gone: nothing read them.
---@param team string
---@return { biter_force: string, t1: string, t2: string, color1: table, cpt_idx: integer? }
local function team_gui_values(team)
    local two_teams = Teams.count() == 2
    local color1 = ring_color1[Teams.ring_index(team)]
    if not color1 then
        local rgb = Teams.color(team) or { r = 225, g = 225, b = 225 }
        color1 = { r = rgb.r / 255, g = rgb.g / 255, b = rgb.b / 255 }
    end
    local t1
    if two_teams then
        t1 = 'Evolution of ' .. team .. ' side biters.'
    else
        t1 = 'Evolution of ' .. Teams.display_name(team) .. ' biters.'
    end
    return {
        biter_force = Teams.biter_force(team),
        t1 = t1,
        t2 = 'Threat causes biters to attack. \nReduces when biters are slain.',
        color1 = color1,
        cpt_idx = Teams.index_of(team),
    }
end

local style = {
    bold = function(str)
        return '[font=default-bold]' .. str .. '[/font]'
    end,
    listbox = function(str)
        return '[font=default-listbox]' .. str .. '[/font]'
    end,
    stat = function(str)
        return '[font=count-font]' .. str .. '[/font]'
    end,
    green = function(str)
        return '[color=green]' .. str .. '[/color]'
    end,
    yellow = function(str)
        return '[color=yellow]' .. str .. '[/color]'
    end,
    red = function(str)
        return '[color=red]' .. str .. '[/color]'
    end,
    blue = function(str)
        return '[color=blue]' .. str .. '[/color]'
    end,
}

local TEST_1 =
    '[color=acid]Zyphorix[/color] [color=red]NibbleWorm[/color] [color=white]Velocisphere[/color] [color=pink]Currygeist[/color] [color=blue]QuarkBlaster[/color] [color=red]Drogoat[/color] [color=acid]Froozowizzle[/color] [color=gray]Tinkershadow[/color] [color=red]Axtorm[/color] [color=yellow]Vexonalux[/color] [color=green]Glimwiggle[/color] [color=cyan]Borqee[/color] [color=cyan]Zyglot[/color] [color=orange]Crimboxnattle[/color] [color=pink]TwinklePuff[/color] [color=green]Jumboborax[/color] [color=red]Fizzywerp[/color] [color=cyan]MocachinoBeast[/color]'

-- The on_player_joined_team event is raised only once when a player joins a team for the first time
-- at this stage, the player already has a character and starting items
-- @usage
-- local Gui = require "maps.biter_battles_v2.gui"
-- local Event = require 'utils.event'
--
-- Event.add(Gui.events.on_player_joined_team,
-- function(event)
--      local player = game.get_player(event.player_index)
-- end)
Public.events = { on_player_joined_team = Event.generate_event_name() }

local function get_format_time()
    local time_caption = 'Not started'
    local total_ticks = Functions.get_ticks_since_game_start()
    if total_ticks > 0 then
        local total_minutes = math_floor(total_ticks / (60 * 60))
        local total_hours = math_floor(total_minutes / 60)
        local minutes = total_minutes - (total_hours * 60)
        time_caption = string_format('%02d:%02d', total_hours, minutes)
    end
    return time_caption
end

local function get_player_data(player, remove)
    if remove and storage.player_data_afk[player.name] then
        storage.player_data_afk[player.name] = nil
        return
    end
    if not storage.player_data_afk[player.name] then
        storage.player_data_afk[player.name] = {}
    end
    return storage.player_data_afk[player.name]
end

local function drop_burners(player, forced_join)
    if forced_join then
        storage.got_burners[player.name] = nil
        return
    end
    if storage.training_mode or not storage.bb_settings.burners_balance then
        return
    end
    local burners_to_drop = player.get_item_count('burner-mining-drill')
    if burners_to_drop ~= 0 then
        local items = player.physical_surface.spill_item_stack({
            position = player.physical_position,
            stack = { name = 'burner-mining-drill', count = burners_to_drop },
            enable_looted = false,
            force = nil,
            allow_belts = false,
        })
        player.remove_item({ name = 'burner-mining-drill', count = burners_to_drop })
    end
end

---@param force string
---@return string
local function get_player_list_caption(force)
    if _DEBUG then
        return TEST_1
    end
    local players_with_colors = PlayerUtils.get_sorted_colored_player_list(game.forces[force].connected_players)
    return table.concat(players_with_colors, '    ')
end

---@param threat_value number
---@return string
function threat_to_pretty_string(threat_value)
    if math_abs(threat_value) >= 1e12 then
        return string_format('%.1fT', threat_value / 1e12)
    elseif math_abs(threat_value) >= 1e9 then
        return string_format('%.1fG', threat_value / 1e9)
    elseif math_abs(threat_value) >= 1e6 then
        return string_format('%.2fM', threat_value / 1e6)
    elseif math_abs(threat_value) >= 1e5 then
        return string_format('%.0fk', threat_value / 1e3)
    else
        return string_format('%.0f', threat_value)
    end
end

---@param evolution number
---@return string
local function get_evo_sprite(evolution)
    if evolution < 20 then
        return 'entity/small-biter'
    elseif evolution < 50 then
        return 'entity/medium-biter'
    elseif evolution < 90 then
        return 'entity/big-biter'
    end
    return 'entity/behemoth-biter'
end

---@param force string
---@param verbose boolean
---@return string
local function get_evo_tooltip(force, verbose)
    local prefix = ''
    if verbose then
        prefix = style.bold('Evolution') .. ' - ' .. team_gui_values(force).t1 .. '\n'
    end
    local biter_force = game.forces[Teams.biter_force(force)]
    local damage = (biter_force.get_ammo_damage_modifier('melee') + 1) * 100
    return prefix
        .. style.listbox('Evolution: ')
        .. style.yellow(style.stat(string_format('%.2f', (storage.bb_evolution[biter_force.name] * 100))))
        .. style.listbox('%\nDamage: ')
        .. style.yellow(style.stat(damage))
        .. style.listbox('%\nHealth: ')
        .. style.yellow(style.stat(string_format('%.0f', (storage.biter_health_factor[biter_force.index] * 100))))
        .. style.listbox('%')
end

---@param force string
---@param verbose boolean
---@return string
local function get_threat_tooltip(force, verbose)
    local prefix = ''
    if verbose then
        prefix = style.bold('Threat') .. ' - ' .. team_gui_values(force).t2 .. '\n'
    end
    local threat_income = storage.bb_threat_income[Teams.biter_force(force)] * 60
    -- technically we could also include the threat-income-from-passive-feed here, but it is
    -- generally much much lower than bb_threat_income's contribution
    return prefix
        .. style.listbox('Passive feed:')
        .. style.yellow(style.stat(' +' .. math_ceil(threat_income)))
        .. style.listbox(' threat/min')
end

---@param force string
---@return string
local function get_captain_caption(force)
    local is_cpt = storage.active_special_games.captain_mode
    if is_cpt then
        local cpt_name = '---'
        local p_name = storage.special_games_variables.captain_mode.captainList[team_gui_values(force).cpt_idx]
        local p = p_name and storage.chosen_team[p_name] and game.get_player(p_name)
        if p then
            cpt_name = string_format(
                '[color=%.2f,%.2f,%.2f]%s[/color]',
                p.color.r * 0.6 + 0.4,
                p.color.g * 0.6 + 0.4,
                p.color.b * 0.6 + 0.4,
                p.name
            )
        end
        return style.listbox('[color=0.9,0.9,0.9]CAPTAIN:[/color] ') .. style.bold(cpt_name) .. '\n'
    end
    return ''
end

---@param player LuaPlayer
function Public.clear_copy_history(player)
    if player and player.valid and player.cursor_stack then
        player.clear_cursor() -- move items from cursor stack to inventory otherwise they would be lost
        for i = 1, 21 do
            -- Imports blueprint of single burner miner into the cursor stack
            stack = player.cursor_stack.import_stack(
                '0eNp9jkEKgzAURO8y67jQhsbmKqUUrR/5kHwliVKR3L3GbrrqcoaZN7OjdwvNgSXB7uDXJBH2viPyKJ0rXtpmggUn8lCQzhfVL0EoVJ6FZayGwM4hK7AM9Iat80OBJHFi+uJOsT1l8T2FI/AXpDBP8ehOUvYPnjYKG2x1bXMhn1fsz3OFlUI8801ba3NrzEVroxud8wdvA0sn'
            )
            player.add_to_clipboard(player.cursor_stack)
            player.clear_cursor()
        end
    end
end

function Public.reset_tables_gui()
    storage.player_data_afk = {}
end

---@param player LuaPlayer
function Public.create_biter_gui_button(player)
    local button = Gui.add_top_element(player, {
        type = 'sprite-button',
        name = 'bb_toggle_main_gui',
        sprite = 'entity/big-biter',
        tooltip = { 'gui.main_gui_top_button' },
    })
end

---@class RefreshStatisticsData
---@field clock_caption string
---@field clock_tooltip string
---@field team_frame table<string,{team_caption:string, players_caption:string, players_tooltip:string, evolution_caption:string, evolution_tooltip:string, threat_caption:string, threat_tooltip:string}>

---The per-team half of `RefreshStatisticsData`, one block per team in
---`Teams.all()` order -- with two teams the north block then the south block,
---the same order and the same seven expressions the literal table used.
---@return table<string, table>
local function get_statistics_team_frames()
    local team_frame = {}
    for _, team in ipairs(Teams.all()) do
        local biter_force = Teams.biter_force(team)
        team_frame[team] = {
            team_caption = style.bold(Functions.team_name(team)),
            players_caption = '(' .. style.green(#game.forces[team].connected_players) .. ')',
            players_tooltip = get_captain_caption(team) .. get_player_list_caption(team),
            evolution_caption = (math_floor(1000 * storage.bb_evolution[biter_force]) * 0.1) .. '%',
            evolution_tooltip = get_evo_tooltip(team, false),
            threat_caption = threat_to_pretty_string(math_floor(storage.bb_threat[biter_force])),
            threat_tooltip = get_threat_tooltip(team, false),
        }
    end
    return team_frame
end

---@return RefreshStatisticsData
local function get_data_for_refresh_statistics()
    local color = DifficultyVote.difficulty_chat_color()
    return {
        clock_caption = get_format_time(),
        clock_tooltip = style.listbox('Difficulty: ') .. style.stat(
            string_format(
                '[color=%.2f,%.2f,%.2f]%s[/color]',
                color.r,
                color.g,
                color.b,
                DifficultyVote.difficulty_name()
            )
        ) .. string_format(style.listbox('\nGame speed: ') .. style.yellow(style.stat('%.2f')), game.speed),
        team_frame = get_statistics_team_frames(),
    }
end

---Creates GUI element that displays flags/icons depicting enabled features
---@param player LuaPlayer
function Public.create_feature_flags_container(player)
    local t = Gui.add_top_element(player, {
        type = 'table',
        name = 'bb_feature_flags',
        column_count = 1,
    })

    t.style.maximal_width = 25
    t.style.maximal_height = 25 * 3
end

---Evaluates all registered feature flags and updates the GUI for a given player
---@param player LuaPlayer
function Public.refresh_feature_flags(player)
    FeatureFlags.evaluate_feature_flags(player)
end

---The height the statistics strip needs. Two teams keep today's single 36 px
---row; above two teams every team is a two-row block (see
---`build_statistics_strip`), so the strip is twice as tall plus its padding.
---@return integer
local function statistics_strip_height()
    if Teams.count() == 2 then
        return 36
    end
    return 56
end

---Fills the top statistics strip with one block of labels per team plus the
---clock, in creation order -- `Public.refresh_statistics` finds them again by
---`<team>_name | _players | _evolution | _threat`.
---
---With two teams this is today's strip, verbatim: mirrored (the first team left
---to right, the clock, the second team right to left) and captioned with the
---literal compass words, which are what the public server has always shown; the
---custom team name reaches the tooltip only.
---
---Above two teams one row does not fit: the strip shares the top bar with the
---fixed buttons (~590 px of them on a 1366 px screen) and four blocks of four
---`heading-2` labels are ~1050 px on their own. So each team becomes one
---compact two-row block in `default-bold` -- name and player count over
---evolution and threat -- the blocks are parted by thin lines and the clock
---closes the row. Half the width, twice the height, no scroll.
---@param frame LuaGuiElement
local function build_statistics_strip(frame)
    local teams = Teams.all()
    local label, line

    if Teams.count() == 2 then
        local first, second = teams[1], teams[2]
        local first_values, second_values = team_gui_values(first), team_gui_values(second)

        do -- North
            label = frame.add({ type = 'label', caption = 'North', name = first .. '_name' })
            gui_style(
                label,
                { font = 'heading-2', right_padding = 4, left_padding = 4, font_color = first_values.color1 }
            )

            label = frame.add({ type = 'label', caption = ' ', name = first .. '_players' })
            gui_style(
                label,
                { font = 'heading-2', right_padding = 4, left_padding = 4, font_color = { 225, 225, 225 } }
            )

            line = frame.add({ type = 'line', direction = 'vertical', style = 'dark_line' })

            label = frame.add({
                type = 'label',
                caption = ' ',
                name = first .. '_evolution',
                font_color = { 225, 225, 225 },
            })
            gui_style(
                label,
                { font = 'heading-2', right_padding = 4, left_padding = 4, font_color = first_values.color1 }
            )

            line = frame.add({ type = 'line', direction = 'vertical', style = 'dark_line' })

            label = frame.add({ type = 'label', caption = ' ', name = first .. '_threat' })
            gui_style(
                label,
                { font = 'heading-2', right_padding = 4, left_padding = 4, font_color = first_values.color1 }
            )
        end

        line = frame.add({ type = 'line', direction = 'vertical' })

        label = frame.add({ type = 'label', caption = '00:00', name = 'clock' })
        gui_style(label, { font = 'heading-2', right_padding = 4, left_padding = 4, font_color = { 225, 225, 225 } })

        line = frame.add({ type = 'line', direction = 'vertical' })

        do -- South
            label = frame.add({ type = 'label', caption = ' ', name = second .. '_threat' })
            gui_style(
                label,
                { font = 'heading-2', right_padding = 4, left_padding = 4, font_color = second_values.color1 }
            )

            line = frame.add({
                type = 'line',
                direction = 'vertical',
                style = 'dark_line',
                font_color = { 225, 225, 225 },
            })

            label = frame.add({ type = 'label', caption = ' ', name = second .. '_evolution' })
            gui_style(
                label,
                { font = 'heading-2', right_padding = 4, left_padding = 4, font_color = second_values.color1 }
            )

            line = frame.add({ type = 'line', direction = 'vertical', style = 'dark_line' })

            label = frame.add({ type = 'label', caption = ' ', name = second .. '_players' })
            gui_style(
                label,
                { font = 'heading-2', right_padding = 4, left_padding = 4, font_color = { 225, 225, 225 } }
            )

            label = frame.add({ type = 'label', caption = 'South', name = second .. '_name' })
            gui_style(
                label,
                { font = 'heading-2', right_padding = 4, left_padding = 4, font_color = second_values.color1 }
            )
        end
        return
    end

    for index, team in ipairs(teams) do
        local values = team_gui_values(team)

        if index > 1 then
            line = frame.add({ type = 'line', direction = 'vertical', style = 'dark_line' })
        end

        -- The four labels are the direct children of a container named after
        -- the team, two per row, so `Public.refresh_statistics` still addresses
        -- every one of them by '<team>_name | _players | _evolution | _threat'.
        local block = frame.add({ type = 'table', name = team .. '_block', column_count = 2 })
        gui_style(block, { horizontal_spacing = 0, vertical_spacing = 0 })

        label = block.add({ type = 'label', caption = Teams.display_name(team), name = team .. '_name' })
        gui_style(label, {
            font = 'default-bold',
            right_padding = 4,
            left_padding = 4,
            font_color = values.color1,
            maximal_width = 110,
        })

        label = block.add({ type = 'label', caption = ' ', name = team .. '_players' })
        gui_style(label, { font = 'default-bold', right_padding = 4, left_padding = 4, font_color = { 225, 225, 225 } })

        label = block.add({ type = 'label', caption = ' ', name = team .. '_evolution' })
        gui_style(label, { font = 'default-bold', right_padding = 4, left_padding = 4, font_color = values.color1 })

        label = block.add({ type = 'label', caption = ' ', name = team .. '_threat' })
        gui_style(label, { font = 'default-bold', right_padding = 4, left_padding = 4, font_color = values.color1 })
    end

    line = frame.add({ type = 'line', direction = 'vertical' })

    label = frame.add({ type = 'label', caption = '00:00', name = 'clock' })
    gui_style(label, { font = 'default-bold', right_padding = 4, left_padding = 4, font_color = { 225, 225, 225 } })
end

---@param player LuaPlayer
function Public.create_statistics_gui_button(player)
    if Gui.get_top_element(player, 'bb_toggle_statistics') then
        return
    end

    local summary = Gui.add_top_element(player, {
        type = 'sprite-button',
        name = 'bb_toggle_statistics',
        sprite = 'utility/expand',
        -- hovered_sprite = 'utility/expand_dark',
        tooltip = 'Show game status!',
    })

    local frame = summary.parent.add({ type = 'frame', name = 'bb_frame_statistics', style = 'subheader_frame' })
    frame.location = { x = 1, y = 38 }
    local height = statistics_strip_height()
    gui_style(frame, { minimal_height = height, maximal_height = height })

    build_statistics_strip(frame)

    Public.refresh_statistics(player, get_data_for_refresh_statistics())
    frame.visible = false
end

---@class RefreshMainGuiData
---@field clock_caption string
---@field game_speed_caption string
---@field is_cpt boolean
---@field main_frame table<string, {teamname:string, playerlist_number:integer, evolution_number:integer, evolution_sprite:string, evolution_tooltip:string, threat_number:integer, threat_tooltip:string, captain:string, members:string}>

---The per-team half of `RefreshMainGuiData`, one block per team in
---`Teams.all()` order -- with two teams the north block then the south block,
---the same order and the same nine expressions the literal table used.
---@return table<string, table>
local function get_main_gui_team_frames()
    local main_frame = {}
    for _, team in ipairs(Teams.all()) do
        local biter_force = Teams.biter_force(team)
        main_frame[team] = {
            teamname = Functions.team_name(team),
            playerlist_number = #game.forces[team].connected_players,
            evolution_number = math_floor(1000 * storage.bb_evolution[biter_force]) * 0.1,
            evolution_sprite = get_evo_sprite(math_floor(1000 * storage.bb_evolution[biter_force]) * 0.1),
            evolution_tooltip = get_evo_tooltip(team, true),
            threat_number = math_floor(storage.bb_threat[biter_force]),
            threat_tooltip = get_threat_tooltip(team, true),
            captain = get_captain_caption(team),
            members = get_player_list_caption(team),
        }
    end
    return main_frame
end

---@return RefreshMainGuiData
-- Science targeting: above two teams under the 'split'
-- policy, the Feeding flow ends with one 'Science target' button that opens the
-- team's science window (gui.screen): one tick box per enemy team, drawn
-- like the end-of-game role buttons (a mark + colour flip on a button, never
-- a checkbox element, see science_window.lua). refresh_main_gui builds the
-- row or drops it, and keeps an open window in step with storage. Nothing
-- of this is ever built at two teams. Element names must not be LuaGuiElement
-- methods ('focus' is one).
local function add_science_focus_row(flow)
    local focus = flow.add({ type = 'flow', name = 'science_focus_row', direction = 'horizontal' })
    gui_style(focus, { vertical_align = 'center', horizontal_spacing = 2 })
    local b = focus.add({
        type = 'button',
        name = 'bb_science_window_open',
        caption = 'Science target',
        style = 'button',
        tooltip = 'Each player steers his part of the '
            .. math_floor(Teams.FOCUS_SHARE * 100 + 0.5)
            .. ' % focus of every science send toward the enemy teams he ticks.',
    })
    gui_style(b, { height = 24, padding = 0, font = 'default-small' })
    return focus
end

local function get_data_for_refresh_main_gui()
    return {
        clock_caption = string_format('Time: %s', get_format_time()),
        game_speed_caption = string_format('Speed: %.2f', game.speed),
        is_cpt = storage.active_special_games.captain_mode,
        main_frame = get_main_gui_team_frames(),
    }
end
---@param player LuaPlayer
function Public.create_main_gui(player)
    local is_spec = player.force.name == 'spectator' or not storage.chosen_team[player.name]

    local main_frame = Gui.get_left_element(player, 'bb_main_gui')
    if main_frame and main_frame.valid then
        main_frame.destroy()
    end

    local main_frame =
        Gui.add_left_element(player, { type = 'frame', name = 'bb_main_gui', direction = 'vertical', index = 1 })
    gui_style(main_frame, { maximal_width = 325 })

    local flow = main_frame.add({ type = 'flow', name = 'flow', style = 'vertical_flow', direction = 'vertical' })
    local inner_frame = flow.add({
        type = 'frame',
        name = 'inner_frame',
        style = 'inside_shallow_frame_packed',
        direction = 'vertical',
    })

    -- == SUBHEADER =================================================================
    do
        local subheader = inner_frame.add({ type = 'frame', name = 'subheader', style = 'subheader_frame' })
        gui_style(subheader, { horizontally_squashable = true, maximal_height = 40 })

        local label = subheader.add({ type = 'label', name = 'clock' })
        gui_style(label, { font = 'default-semibold', font_color = { 225, 225, 225 }, left_margin = 4 })

        Gui.add_pusher(subheader)
        local line = subheader.add({ type = 'line', direction = 'vertical' })
        Gui.add_pusher(subheader)

        local label = subheader.add({ type = 'label', name = 'game_speed' })
        gui_style(label, { font = 'default-semibold', font_color = { 225, 225, 225 }, right_margin = 4 })
    end

    -- == MAIN FRAME ================================================================
    local sp = inner_frame.add({
        type = 'scroll-pane',
        name = 'scroll_pane',
        style = 'scroll_pane_under_subheader',
        direction = 'vertical',
    })

    do -- Team overview, one frame per team in Teams.all() order (north, then south, with two teams)
        for _, force_name in ipairs(Teams.all()) do
            local gui_value = team_gui_values(force_name)
            local team_frame =
                sp.add({ type = 'frame', name = force_name, style = 'bordered_frame', direction = 'vertical' })

            local flow = team_frame.add({ type = 'flow', name = 'flow', direction = 'horizontal' })
            gui_style(flow, { horizontal_align = 'center' })

            local caption_flow = flow.add({ type = 'flow', name = 'caption_flow', direction = 'vertical' })

            local label = caption_flow.add({ type = 'label', name = 'team_name', style = 'caption_label' })
            -- 125 px of name is what two teams have always had. Above two teams
            -- the header row also carries the join button, so the name gets 100
            -- and the row stays inside the 325 px panel (it wraps, it does not
            -- widen: `single_line = false`).
            gui_style(label, {
                font_color = gui_value.color1,
                single_line = false,
                maximal_width = Teams.count() == 2 and 125 or 100,
            })

            Gui.add_pusher(flow)

            local t = flow.add({ type = 'table', name = 'table', column_count = 3, style = 'compact_slot_table' })

            local players_button = t.add({
                type = 'sprite-button',
                style = 'slot_button_in_shallow_frame',
                sprite = 'entity/character',
                name = 'bb_toggle_player_list',
                auto_toggle = true,
                tooltip = style.bold('Player list') .. ' - Show player list',
            })

            local evolution_button = t.add({
                type = 'sprite-button',
                style = 'slot_button_in_shallow_frame',
                sprite = 'entity/small-biter',
                name = 'evolution',
                tooltip = style.bold('Evolution') .. ' - ' .. gui_value.t1,
            })

            local threat_button = t.add({
                type = 'sprite-button',
                style = 'slot_button_in_shallow_frame',
                sprite = 'utility/enemy_force_icon',
                name = 'threat',
                tooltip = style.bold('Threat') .. ' - ' .. gui_value.t2,
            })

            local size = 36
            for _, b in pairs({ players_button, evolution_button, threat_button }) do
                gui_style(
                    b,
                    { minimal_height = size, minimal_width = size, maximal_height = size, maximal_width = size }
                )
            end

            if Teams.count() > 2 then
                -- Above two teams the join button of a team lives at the right
                -- end of that team's header row: a row of four caption buttons
                -- at the bottom of the panel is wider than its 325 px and puts
                -- a horizontal scrollbar under the whole panel (screenshot
                -- gui4-before/01-main-gui-spectator.png).
                --
                -- A team that is out of the round gets the marker instead of a
                -- button, for the reason the bottom row skipped it before:
                -- joining it teleports the player into a quarter with no base,
                -- no silo and nobody to feed.
                if Teams.is_alive(force_name) then
                    local join_button = flow.add({
                        type = 'button',
                        name = 'join_' .. force_name,
                        caption = 'Join',
                        tooltip = style.bold('Join ' .. Teams.display_name(force_name)),
                        style = 'tool_button',
                    })
                    gui_style(join_button, { height = 28, padding = 2, left_margin = 4, font = 'default-bold' })
                else
                    local out_label = flow.add({ type = 'label', name = 'out_marker', caption = 'out' })
                    gui_style(out_label, { font = 'default-bold', font_color = { 180, 180, 180 }, left_margin = 4 })
                end
            end

            local players_frame = team_frame.add({
                type = 'frame',
                name = 'players',
                direction = 'vertical',
                style = 'deep_frame_in_shallow_frame',
            }) --quick_bar_window_frame
            gui_style(
                players_frame,
                { horizontal_align = 'center', maximal_width = 285, padding = 5, horizontally_stretchable = true }
            )

            local label = players_frame.add({ type = 'label', name = 'captain', caption = 'Captain: ---' })
            local label = players_frame.add({ type = 'label', name = 'members', caption = TEST_1 })
            gui_style(label, { single_line = false, font = 'default-small', horizontal_align = 'center' })

            players_frame.visible = players_button.toggled
        end
    end

    do -- Science sending GUI
        local science_frame = sp.add({
            type = 'frame',
            name = 'science_frame',
            style = 'bordered_frame',
            direction = 'vertical',
            caption = 'Feeding',
        })
        gui_style(science_frame, { horizontal_align = 'center' })

        local flow = science_frame.add({ type = 'flow', name = 'flow', direction = 'vertical' })
        gui_style(flow, { horizontal_align = 'center' })

        local table_frame = flow.add({
            type = 'frame',
            name = 'table_frame',
            direction = 'horizontal',
            style = 'quick_bar_inner_panel',
        }) --slot_button_deep_frame, quick_bar_window_frame, quick_bar_inner_panel
        gui_style(table_frame, { minimal_height = 40 })

        local t =
            table_frame.add({ type = 'table', name = 'send_table', column_count = 5, style = 'filter_slot_table' })
        gui_style(t, { horizontally_stretchable = true })

        for food_name, tooltip in pairs(food_names) do
            local f = t.add({
                type = 'sprite-button',
                name = food_name,
                sprite = 'item/' .. food_name,
                style = 'slot_button',
                tooltip = tooltip,
            })
            gui_style(f, { padding = 0 })
        end
        local f = t.add({
            type = 'sprite-button',
            name = 'send_all',
            caption = 'All',
            style = 'slot_button',
            tooltip = { 'info.send_all_tooltip' },
        })
        gui_style(f, { padding = 0, font_color = { r = 0.9, g = 0.9, b = 0.9 } })
        local f = t.add({
            type = 'sprite-button',
            name = 'info',
            style = 'slot_button',
            sprite = 'utility/warning_white',
            tooltip = { 'info.info_button_tooltip' },
        })
        gui_style(f, { padding = 0 })

        if Teams.science_focus_offered() then
            add_science_focus_row(flow)
        end
    end

    do -- Join/Resume
        local join_frame =
            sp.add({ type = 'frame', name = 'join_frame', style = 'bordered_frame', direction = 'vertical' })
        gui_style(join_frame, { vertical_align = 'center' })

        local flow = join_frame.add({ type = 'flow', name = 'assign', direction = 'horizontal' })
        gui_style(flow, { vertical_align = 'center', horizontal_spacing = 4 })

        local label = flow.add({ type = 'label', caption = 'Join', style = 'caption_label' })
        Gui.add_pusher(flow)

        local teams = Teams.all()
        if Teams.count() == 2 then
            -- Today's three buttons in today's order, sprites and wording: the
            -- up arrow for the first team, the shuffle, the down arrow for the
            -- second. The element names are 'join_north' / 'join_south' as they
            -- have always been -- the click handler builds them the same way.
            local button = flow.add({
                type = 'sprite-button',
                name = 'join_' .. teams[1],
                sprite = 'utility/speed_up',
                tooltip = style.bold('Join North team'),
                style = 'tool_button',
            })
            gui_style(button, { size = 28, padding = 1 })

            local button = flow.add({
                type = 'sprite-button',
                name = 'join_random',
                sprite = 'utility/shuffle',
                tooltip = style.bold('Join random team'),
                style = 'tool_button',
            })
            gui_style(button, { size = 28, padding = 3 })

            local button = flow.add({
                type = 'sprite-button',
                name = 'join_' .. teams[2],
                sprite = 'utility/speed_down',
                tooltip = style.bold('Join South team'),
                style = 'tool_button',
            })
            gui_style(button, { size = 28, padding = 1 })
        else
            -- Three or four teams: the per-team buttons moved up into the team
            -- blocks ('join_<team>' at the right end of each header row), so
            -- this row is the shuffle alone -- four captioned buttons side by
            -- side did not fit the panel. No compass sprite fits a corner, and
            -- the shuffle needs no team name of its own.
            local button = flow.add({
                type = 'sprite-button',
                name = 'join_random',
                sprite = 'utility/shuffle',
                tooltip = style.bold('Join the smallest team'),
                style = 'tool_button',
            })
            gui_style(button, { size = 28, padding = 3 })
        end

        local flow = join_frame.add({ type = 'flow', name = 'resume', direction = 'horizontal' })
        gui_style(flow, { vertical_align = 'center', horizontal_spacing = 4 })

        local label = flow.add({ type = 'label', caption = 'Options', style = 'caption_label' })
        Gui.add_pusher(flow)

        local button = flow.add({
            type = 'sprite-button',
            name = 'bb_resume',
            sprite = 'utility/reset',
            tooltip = style.bold('Rejoin team'),
            style = 'back_button',
        })
        gui_style(button, { padding = 2, maximal_width = 38, maximal_height = 28 })

        local button = flow.add({
            type = 'sprite-button',
            name = 'bb_spectate',
            sprite = 'utility/create_ghost_on_entity_death_modifier_icon',
            tooltip = style.bold('Spectate'),
            style = 'forward_button',
        })
        gui_style(button, { padding = 2, maximal_width = 38, maximal_height = 28 })
    end

    do -- Pause buttons
        local pause_frame =
            sp.add({ type = 'frame', name = 'pause_frame', style = 'bordered_frame', direction = 'vertical' })
        gui_style(pause_frame, { vertical_align = 'center' })

        local flow = pause_frame.add({ type = 'flow', name = 'pause_flow', direction = 'horizontal' })
        gui_style(flow, { vertical_align = 'center', horizontal_spacing = 4 })

        local label = flow.add({ type = 'label', caption = 'Pause', style = 'caption_label' })
        Gui.add_pusher(flow)

        local button = flow.add({
            type = 'sprite-button',
            name = 'bb_pause',
            sprite = 'utility/pause',
            tooltip = style.bold('Pause game'),
            style = 'tool_button',
        })
        gui_style(button, { size = 28, padding = 1 })

        local button = flow.add({
            type = 'sprite-button',
            name = 'bb_resume_game',
            sprite = 'utility/play',
            tooltip = style.bold('Resume game'),
            style = 'tool_button',
        })
        gui_style(button, { size = 28, padding = 1 })
    end

    -- == SUBFOOTER ===============================================================
    do
        local subfooter =
            inner_frame.add({ type = 'frame', name = 'subfooter', style = 'subfooter_frame', direction = 'horizontal' })
        gui_style(subfooter, { horizontally_squashable = true, vertical_align = 'center' })

        Gui.add_pusher(subfooter)

        local button = subfooter.add({
            type = 'sprite-button',
            name = 'bb_floating_shortcut_button',
            style = 'transparent_slot', -- 'quick_bar_slot_button', 'frame_action_button',
            sprite = 'utility/empty_module_slot',
            tooltip = { 'gui.floating_shortcuts' },
        })
        gui_style(button, { size = 26 })

        local button = ResearchInfo.create_research_info_button(subfooter)
        button.tooltip = { 'gui.research_info' }
        gui_style(button, { size = 26, left_margin = 4 })

        local button = subfooter.add({
            type = 'sprite-button',
            name = 'bb_floating_shortcuts_team_statistics',
            style = 'transparent_slot', -- 'quick_bar_slot_button', 'frame_action_button',
            sprite = 'utility/side_menu_production_icon',
            tooltip = { 'gui.team_statistics' },
        })
        gui_style(button, { size = 26, left_margin = 4 })

        local button = subfooter.add({
            type = 'sprite-button',
            name = 'bb_floating_shortcuts_clear_corpses',
            style = 'transparent_slot',
            sprite = 'utility/trash_white',
            tooltip = { 'gui.clear_corpses' },
        })
        gui_style(button, { size = 26, left_margin = 4, padding = 6 })

        local button = subfooter.add({
            type = 'sprite-button',
            name = 'bb_floating_shortcuts_calc_send',
            style = 'transparent_slot',
            sprite = 'utility/add_white',
            tooltip = { 'gui.calc_send' },
        })
        gui_style(button, { size = 26, left_margin = 4, padding = 5 })

        Gui.add_pusher(subfooter)
    end

    -- ============================================================================

    Public.refresh_main_gui(player, get_data_for_refresh_main_gui())
end

---Rebuild every team-shaped element this file owns for one player: the blocks
---of the top statistics strip and the whole of `bb_main_gui`.
---
---For the map-reset path to call, once per connected player, when the team
---count of the new round differs from the one the GUI was built for.
---`generate_new_map()` (game_over.lua) rebuilds only `bb_main_gui` today, and
---`Public.create_statistics_gui_button` builds the strip once per player and
---then always returns early -- so a strip built for two teams would otherwise
---survive into a four-team round with no labels for the two new teams.
---
---Nothing in this file calls it: wiring it into the reset is game_over.lua's
---business. It keeps the toggle button, the strip frame
---and its place in the top flow, so the players who do not need it see nothing.
---@param player LuaPlayer
function Public.rebuild_team_guis(player)
    local frame = Gui.get_top_element(player, 'bb_frame_statistics')
    if frame and frame.valid then
        local was_visible = frame.visible
        frame.clear()
        -- The frame itself survives the rebuild, so its height has to follow
        -- the new team count the way create_statistics_gui_button sets it.
        local height = statistics_strip_height()
        gui_style(frame, { minimal_height = height, maximal_height = height })
        build_statistics_strip(frame)
        -- refresh_statistics skips a hidden strip, so fill it the way
        -- create_statistics_gui_button does: while it is still visible.
        frame.visible = true
        Public.refresh_statistics(player, get_data_for_refresh_statistics())
        frame.visible = was_visible
    end

    Public.create_main_gui(player)
end

---@param player LuaPlayer
---@param data RefreshStatisticsData
function Public.refresh_statistics(player, data)
    local frame = Gui.get_top_element(player, 'bb_frame_statistics')
    if not frame or not frame.visible then
        return
    end

    frame.clock.caption = data.clock_caption
    frame.clock.tooltip = data.clock_tooltip

    for _, force_name in ipairs(Teams.all()) do
        -- Above two teams the four labels of a team sit in a two-row block
        -- named after it (`build_statistics_strip`); with two teams they are
        -- the direct children of the strip they have always been and there is
        -- no block, so the lookup below is the frame itself.
        local block = frame[force_name .. '_block'] or frame
        local name_label = block[force_name .. '_name']
        -- A strip built for a round of a different team count outlives the map
        -- reset until Public.rebuild_team_guis() is called: skip the teams it
        -- has no labels for rather than index a nil element.
        if name_label then
            local local_data = data.team_frame[force_name]
            name_label.tooltip = local_data.team_caption

            block[force_name .. '_players'].caption = local_data.players_caption
            block[force_name .. '_players'].tooltip = local_data.players_tooltip

            block[force_name .. '_evolution'].caption = local_data.evolution_caption
            block[force_name .. '_evolution'].tooltip = local_data.evolution_tooltip

            block[force_name .. '_threat'].caption = local_data.threat_caption
            block[force_name .. '_threat'].tooltip = local_data.threat_tooltip
        end
    end
end

---@param player LuaPlayer
---@param data RefreshMainGuiData
function Public.refresh_main_gui(player, data)
    ScienceWindow.refresh(player)
    local frame = Gui.get_left_element(player, 'bb_main_gui')
    if not frame or not frame.visible then
        return
    end

    frame = frame.flow.inner_frame
    local header, main, footer = frame.subheader, frame.scroll_pane, frame.subfooter
    local is_spec = player.force.name == 'spectator' or not storage.chosen_team[player.name]
    -- Above two teams a player whose team died sits the rest of the round out
    -- and `join_team` refuses them (`Teams.is_player_eliminated`), so the Join
    -- row and the per-team join buttons would be a prompt they cannot follow.
    -- A two-team round marks nobody, so this is false there and both rules
    -- below are today's expression with a term that cannot change it.
    local is_out = Teams.count() > 2 and Teams.is_player_eliminated(player.name)

    -- == SUBHEADER =================================================================
    header.clock.caption = data.clock_caption
    header.game_speed.caption = data.game_speed_caption

    -- == MAIN FRAME ================================================================
    do -- Team overview, in the same order create_main_gui built the frames in
        local is_cpt = data.is_cpt
        for _, force_name in ipairs(Teams.all()) do
            local local_data = data.main_frame[force_name]
            local team = main[force_name]
            -- The same guard the two sibling loops have (`refresh_statistics`,
            -- `refresh_threat`): a frame this round has a team for but the GUI
            -- on screen does not. Every reset rebuilds the whole main GUI, so
            -- with two teams the frame is always there and nothing changes.
            if team then
                team.flow.caption_flow.team_name.caption = local_data.teamname

                local team_info = team.flow.table

                team_info.bb_toggle_player_list.number = local_data.playerlist_number
                team_info.bb_toggle_player_list.tooltip = style.bold('Player list')
                    .. (team_info.bb_toggle_player_list.toggled and ' - Hide player list' or ' - Show player list')

                team_info.evolution.number = local_data.evolution_number
                team_info.evolution.sprite = local_data.evolution_sprite
                team_info.evolution.tooltip = local_data.evolution_tooltip

                team_info.threat.number = local_data.threat_number
                team_info.threat.tooltip = local_data.threat_tooltip

                -- Above two teams the join button of a team sits in the team's
                -- own header row, so it needs the rule the bottom 'Join' row
                -- gets further down -- the same expression, verbatim, plus the
                -- one thing that row cannot need: the button is decided at
                -- BUILD time against `Teams.is_alive`, and a team can die while
                -- a panel that was built before is still on screen, so it is
                -- hidden here as well. (The 'out' marker cannot be created
                -- retroactively without a rebuild; the click is refused either
                -- way.) With two teams there is no such button and nothing here
                -- runs; the added term is true there in any case.
                local join_button = team.flow['join_' .. force_name]
                if join_button then
                    join_button.visible = _DEBUG
                        or (
                            storage.bb_game_won_by_team == nil
                            and storage.chosen_team[player.name] == nil
                            and not is_out
                            and (Teams.count() == 2 or Teams.is_alive(force_name))
                        )
                end

                if team.players.visible then
                    team.players.captain.visible = is_cpt ~= nil
                    team.players.captain.caption = local_data.captain
                    team.players.members.caption = local_data.members
                end
            end
        end
    end

    do -- Science sending
        if is_spec or storage.bb_game_won_by_team then
            main.science_frame.visible = _DEBUG or false
        else
            main.science_frame.visible = true
            local t = main.science_frame.flow.table_frame.send_table

            -- Calculate restriction states once
            local is_special_game_restricted = storage.active_special_games.disable_sciences
            local is_captain_restricted = Captain_event.captain_is_player_prohibited_to_throw(player)
            local is_score_restricted = not FeedingRestriction.can_player_send_science(player)

            local any_restricted = false

            -- Update food buttons
            for food_name, tooltip in pairs(food_names) do
                local button = t[food_name]
                local is_fish = food_name == 'raw-fish'

                -- Determine visibility (captain/special game hides buttons)
                local hidden = (is_special_game_restricted and storage.special_games_variables.disabled_food[food_name])
                    or (is_captain_restricted and not is_fish)
                button.visible = not hidden

                -- Determine enabled state (score restriction disables but keeps visible)
                local disabled = is_score_restricted and not is_fish
                button.enabled = not disabled
                button.tooltip = disabled and { 'info.science_send_restriction' } or tooltip

                any_restricted = any_restricted or hidden or disabled
            end

            -- Update send_all button
            local send_all = t.send_all
            local hidden = is_special_game_restricted or is_captain_restricted
            send_all.visible = not hidden
            send_all.enabled = not is_score_restricted
            send_all.tooltip = is_score_restricted and { 'info.science_send_restriction' }
                or { 'info.send_all_tooltip' }
            any_restricted = any_restricted or hidden or is_score_restricted

            local science_flow = main.science_frame.flow
            local focus = science_flow.science_focus_row
            if Teams.science_focus_offered() then
                if not focus then
                    focus = add_science_focus_row(science_flow)
                end
            elseif focus then
                focus.destroy()
                focus = nil
            end
            if focus then
                focus.visible = ScienceWindow.allowed(player)
            end

            -- Update info button
            t.info.visible = any_restricted
            if is_captain_restricted or is_special_game_restricted then
                t.info.tooltip = { 'info.info_button_tooltip' }
            elseif is_score_restricted then
                t.info.tooltip = { 'info.science_send_restriction_tooltip' }
            else
                t.info.tooltip = { 'info.info_button_tooltip' }
            end
        end
    end

    do -- Pause buttons
        local pause_frame = main.pause_frame
        pause_frame.visible = _DEBUG or ((not is_spec or player.admin) and not storage.bb_game_won_by_team)

        local flow = pause_frame.pause_flow
        flow.bb_pause.visible = _DEBUG or (not game.tick_paused and not storage.bb_game_won_by_team)
        flow.bb_resume_game.visible = _DEBUG or (game.tick_paused and not storage.bb_game_won_by_team)
    end

    do -- Join/Resume
        local assign, resume = main.join_frame.assign, main.join_frame.resume
        assign.visible = _DEBUG
            or (storage.bb_game_won_by_team == nil and storage.chosen_team[player.name] == nil and not is_out)
        resume.visible = _DEBUG or (storage.bb_game_won_by_team == nil and storage.chosen_team[player.name] ~= nil)
        resume.bb_resume.visible = _DEBUG or is_spec
        resume.bb_spectate.visible = _DEBUG or not is_spec
        main.join_frame.visible = assign.visible or resume.visible
    end

    -- == SUBFOOTER ===============================================================
    do
        footer.research_info_button.visible = _DEBUG
            or storage.bb_show_research_info == 'always'
            or (storage.bb_show_research_info == 'spec' and player.force.name == 'spectator')
            or (storage.bb_show_research_info == 'pure-spec' and not storage.chosen_team[player.name])
    end
end

function Public.refresh()
    local main_data = get_data_for_refresh_main_gui()
    local statistics_data = get_data_for_refresh_statistics()
    for _, player in pairs(game.connected_players) do
        Public.refresh_statistics(player, statistics_data)
        Public.refresh_main_gui(player, main_data)
        DifficultyVote.difficulty_gui(player)
    end
    storage.gui_refresh_delay = game.tick + 30
end

function Public.refresh_threat()
    if storage.gui_refresh_delay > game.tick then
        return
    end
    local updates = {}
    for _, team in ipairs(Teams.all()) do
        updates[#updates + 1] = {
            team = team,
            number = storage.bb_threat[Teams.biter_force(team)],
            tooltip = get_threat_tooltip(team, true),
        }
    end
    for _, player in pairs(game.connected_players) do
        local frame = Gui.get_left_element(player, 'bb_main_gui')
        if frame and frame.visible then
            local teams = frame.flow.inner_frame.scroll_pane
            for _, v in ipairs(updates) do
                local team_frame = teams[v.team]
                if team_frame then
                    local info = team_frame.flow.table
                    info.threat.number = v.number
                    info.threat.tooltip = v.tooltip
                end
            end
        end
    end
    storage.gui_refresh_delay = game.tick + 30
end

---@param player LuaPlayer
function Public.burners_balance(player)
    if player.force.name == 'spectator' then
        return
    end
    if storage.tt_mode then
        -- tt_mode owns the starting-kit handout entirely (plan §A — single source of truth).
        require('maps.biter_battles_v2.tt_mode').give_starting_pack(player)
        return
    end
    if storage.got_burners[player.name] then
        return
    end
    if storage.training_mode or not storage.bb_settings.burners_balance then
        storage.got_burners[player.name] = true
        player.insert({ name = 'burner-mining-drill', count = 10 })
        return
    end
    if Teams.count() ~= 2 then
        -- The compensation below hands one player's ten drills to one player of
        -- the one enemy team: the whole 1:1 idea is two-team-shaped.
        -- Above two teams nobody is paired and nothing is
        -- handed out; the player is left waiting for a partner, as they are
        -- today when no enemy is waiting. Balancing N teams is a later phase.
        storage.got_burners[player.name] = false
        return
    end
    local teams = Teams.all()
    local enemy_force = teams[1]
    if player.force.name == teams[1] then
        enemy_force = teams[2]
    end
    local player2
    -- factorio Lua promises that pairs() iterates in insertion order
    for enemy_player_name, _ in pairs(storage.got_burners) do
        if
            not storage.got_burners[enemy_player_name]
            and (game.get_player(enemy_player_name).force.name == enemy_force)
            and game.get_player(enemy_player_name).connected
        then
            player2 = game.get_player(enemy_player_name)
            break
        end
    end
    if not player2 then
        storage.got_burners[player.name] = false
        return
    end
    local burners_to_insert = 10
    for i = 1, 0, -1 do
        local inserted
        storage.got_burners[player.name] = true
        inserted = player.insert({ name = 'burner-mining-drill', count = burners_to_insert })
        if inserted < burners_to_insert then
            player.physical_surface.spill_item_stack({
                position = player.physical_position,
                stack = { name = 'burner-mining-drill', count = burners_to_insert - inserted },
                enable_looted = false,
                force = nil,
                allow_belts = false,
            })
        end
        player.print({ 'info.burner_balance', burners_to_insert }, { r = 1, g = 1, b = 0 })
        player.create_local_flying_text({
            text = { 'info.burner_balance', burners_to_insert },
            position = player.position,
        })
        player = player2
    end
end

local function on_player_left_game(event)
    local player = game.get_player(event.player_index)
    drop_burners(player)
end

---@param player LuaPlayer
---Finds a suitable position to put back player into land from spectator in case
---they were put there by AFK timer.
---@return { x: number, y: number }|nil
local function get_stored_position(player, _)
    local p = nil
    local surface = player.surface
    local p_data = get_player_data(player)
    if p_data and p_data.position then
        p = surface.find_non_colliding_position('character', p_data.position, 16, 0.5)
        get_player_data(player, true)
    end

    return p
end

---@param player LuaPlayer
---@param force LuaForce
---Finds a suitable position to put back player into land from spectator
---@return { x: number, y: number }|nil
local function get_spawn_position(player, force)
    local surface = player.surface
    return surface.find_non_colliding_position('character', force.get_spawn_position(surface), 16, 0.5)
end

---@param player LuaPlayer
---@param force LuaForce
---Finds a suitable position to teleport player from the island
---@return { x: number, y: number }|nil
local function get_teleport_position(player, force)
    local clbk = {
        get_stored_position,
        MultiSilo.get_spawn_position,
        get_spawn_position,
    }

    for _, fn in ipairs(clbk) do
        local position = fn(player, force)
        if position then
            return position
        end
    end

    return nil
end

---Would joining `force_name` make it the too-big team? Today's test with two
---teams, verbatim: more connected players than the one other team, eliminated
---or not (the legacy `enemy_team` ternary knew nothing about elimination).
---
---Above two teams the same rule against the *smallest* other team still alive,
---which is the generalisation that agrees with today's answer at two teams; an
---average would not.
---@param force_name string
---@return boolean
local function is_over_balance_limit(force_name)
    local teams = Teams.all()
    if Teams.count() == 2 then
        local enemy_team = teams[2]
        if force_name == teams[2] then
            enemy_team = teams[1]
        end
        return #game.forces[force_name].connected_players > #game.forces[enemy_team].connected_players
    end

    local limit
    for _, enemy in ipairs(Teams.enemies_of(force_name)) do
        local players = #game.forces[enemy].connected_players
        if not limit or players < limit then
            limit = players
        end
    end
    if not limit then
        return false
    end
    return #game.forces[force_name].connected_players > limit
end

function join_team(player, force_name, forced_join, auto_join)
    if not player.character then
        return
    end
    if not player.spectator then
        return
    end
    if not forced_join and storage.reroll_time_left and storage.reroll_time_left > 0 then
        player.print(' Wait until reroll ends. ', { color = { r = 0.98, g = 0.66, b = 0.22 } })
        return
    end
    if not forced_join then
        if
            (storage.tournament_mode and not storage.active_special_games.captain_mode)
            or (storage.active_special_games.captain_mode and not storage.chosen_team[player.name])
        then
            player.print(
                'The game is set to tournament mode. Teams can only be changed via team manager.',
                { color = { r = 0.98, g = 0.66, b = 0.22 } }
            )
            return
        end
        -- Above two teams a team can die while the round goes on, and its
        -- players sit the rest of it out: `eliminate_team` cleared their team
        -- choice, so nothing else would stop them joining one of the teams
        -- still playing. The team manager, the captain draft and the daemon
        -- pass forced_join and are not refused. Two teams have no elimination
        -- step, so nobody is ever marked and this cannot fire.
        if Teams.count() > 2 and Teams.is_player_eliminated(player.name) then
            player.print(
                'Your team was eliminated this round - you are spectating until the next map.',
                { color = { r = 0.98, g = 0.66, b = 0.22 } }
            )
            return
        end
    end
    if not force_name then
        return
    end
    local surface = player.physical_surface

    if not storage.training_mode and storage.bb_settings.team_balancing then
        if not forced_join then
            if is_over_balance_limit(force_name) then
                if not storage.chosen_team[player.name] then
                    player.print(
                        Functions.team_name_with_color(force_name) .. ' has too many players currently.',
                        { color = { r = 0.98, g = 0.66, b = 0.22 } }
                    )
                    return
                end
            end
        end
    end

    if storage.chosen_team[player.name] then
        if not forced_join then
            if storage.active_special_games.limited_lives and not has_life(player.name) then
                player.print(
                    'Special game in progress. You have no lives left until the end of the game.',
                    { color = { r = 0.98, g = 0.66, b = 0.22 } }
                )
                return
            end
            if
                storage.suspended_players[player.name]
                and (game.tick - storage.suspended_players[player.name]) < storage.suspended_time
            then
                player.print(
                    'Not ready to return to your team yet as you are still suspended. Please wait '
                        .. math_ceil(
                            (
                                storage.suspended_time
                                - (math_floor((game.tick - storage.suspended_players[player.name])))
                            ) / 60
                        )
                        .. ' seconds.',
                    { color = { r = 0.98, g = 0.66, b = 0.22 } }
                )
                return
            end
            if
                storage.spectator_rejoin_delay[player.name]
                and game.tick - storage.spectator_rejoin_delay[player.name] < 3600
            then
                player.print(
                    'Not ready to return to your team yet. Please wait '
                        .. 60 - (math_floor((game.tick - storage.spectator_rejoin_delay[player.name]) / 60))
                        .. ' seconds.',
                    { color = { r = 0.98, g = 0.66, b = 0.22 } }
                )
                return
            end
        end
        local force = game.forces[force_name]
        local position = get_teleport_position(player, force)
        if not position then
            local msg = 'No spawn position found for ' .. player.name .. '!'
            game.print(msg, { color = { 255, 0, 0 } })
            log(msg)
            return
        end

        player.character.teleport(position)
        player.force = force
        player.character.destructible = true
        Public.refresh()
        game.permissions.get_group('Default').add_player(player)
        Captain_event.on_player_joined_team(player)
        -- Two teams: the force name, in chat and on Discord, as always. Above two
        -- teams the chat line names the team's coloured title; Discord keeps the
        -- force name (relayed through the log, where a bot may parse it).
        local team = player.force.name
        local msg, discord_msg =
            NteamWording.spectating_messages(team, player.name, Teams.count(), Teams.name_with_color(team))
        game.print(msg, { color = { r = 0.98, g = 0.66, b = 0.22 } })
        Sounds.notify_allies(player.force, 'utility/build_blueprint_large')
        Server.to_discord_bold(discord_msg)
        storage.spectator_rejoin_delay[player.name] = game.tick
        player.spectator = false
        player.show_on_map = true
        Public.burners_balance(player)
        if storage.quasi_admin_mode then
            Admin.switch_to_quasi_admin_mode(player, false)
        end
        return
    end
    local pos =
        surface.find_non_colliding_position('character', game.forces[force_name].get_spawn_position(surface), 8, 1)
    if not pos then
        pos = game.forces[force_name].get_spawn_position(surface)
    end
    player.character.teleport(pos)
    player.force = game.forces[force_name]
    player.character.destructible = true
    game.permissions.get_group('Default').add_player(player)
    if not forced_join then
        -- In case bots are parsing discord messages, we always refer to teams as 'north' or 'south'
        Server.to_discord_bold(table.concat({ player.name, ' has joined team ', player.force.name, '!' }))
        local join_text = 'has joined'
        if auto_join then
            join_text = 'was automatically assigned to'
        end
        local message =
            table.concat({ player.name, ' ', join_text, ' ', Functions.team_name_with_color(player.force.name), '!' })
        game.print(message, { color = { r = 0.98, g = 0.66, b = 0.22 } })
    end

    local i = player.character.get_inventory(defines.inventory.character_main)
    i.clear()

    if storage.quasi_admin_mode then
        Admin.switch_to_quasi_admin_mode(player, false)
    end

    player.insert({ name = 'pistol', count = 1 })
    player.insert({ name = 'raw-fish', count = 3 })
    player.insert({ name = 'firearm-magazine', count = 32 })
    player.insert({ name = 'iron-gear-wheel', count = 8 })
    player.insert({ name = 'iron-plate', count = 16 })
    player.insert({ name = 'wood', count = 2 })
    storage.chosen_team[player.name] = force_name
    storage.spectator_rejoin_delay[player.name] = game.tick
    player.spectator = false
    player.show_on_map = true
    Public.burners_balance(player)
    MultiSilo.on_player_changed_force(player)
    CraftingQueueList.on_team_changed(player)
    Captain_event.on_player_joined_team(player)
    Public.clear_copy_history(player)
    Public.refresh()

    script.raise_event(Public.events.on_player_joined_team, {
        player_index = player.index,
    })
end

function spectate(player, forced_join, stored_position)
    -- Player might not have a body if captain ejected them, was waiting
    -- for a respawn or has alternative controller set.
    if not player.character then
        -- Reposition camera to chunk which is guaranteed to exists to avoid
        -- any issue with character positioning. Repositioning is performed
        -- only for cases where character is to be created.
        local origin = { 0, 0 }
        if player.ticks_to_respawn then
            -- Character cannot be created while dead, we can only speed up
            -- respawn and pray it doesn't race.
            player.teleport(origin)
            player.ticks_to_respawn = nil
            if not player.character then
                log('WARN: spectate: player ' .. player.name .. ' still without a character')
                log('WARN: spectate: fallback to old behavior')
                return
            end
        else
            -- Is player missing a body due to unrelated bug/accidental removal?
            -- Maybe admin tries to recover situation.
            if player.physical_controller_type ~= defines.controllers.editor then
                log('INFO: spectate: player ' .. player.name .. ' was without a character')
                -- We cannot trust LuaPlayer::physical_surface as they might be trapped
                -- on another surface.
                local s = game.surfaces[storage.bb_surface_name]
                player.teleport(origin, s)
                local ch = s.create_entity({
                    name = 'character',
                    position = origin,
                })
                player.set_controller({
                    type = defines.controllers.character,
                    character = ch,
                })
            else
                -- Non-admin player should never reach this state.
                -- If it's an admin, best to not interfere (leave old behavior).
                log('WARN: spectate: player ' .. player.name .. " doesn't have associated character")
                log('WARN: spectate: fallback to old behavior')
                return
            end
        end
    end

    if not forced_join then
        if storage.tournament_mode and not storage.active_special_games.captain_mode then
            player.print(
                'The game is set to tournament mode. Teams can only be changed via team manager.',
                { color = { r = 0.98, g = 0.66, b = 0.22 } }
            )
            return
        end
        if storage.active_special_games.captain_mode and storage.special_games_variables.captain_mode.prepaPhase then
            player.print(
                'The game is in preparation phase of captain event, no spectating allowed until the captain game started',
                { color = { r = 0.98, g = 0.66, b = 0.22 } }
            )
            return
        end
    end

    while player.crafting_queue_size > 0 do
        player.cancel_crafting(player.crafting_queue[1])
    end

    player.driving = false
    player.character.driving = false
    player.clear_cursor()
    drop_burners(player, forced_join)
    MultiSilo.save_position(player)
    if stored_position then
        local p_data = get_player_data(player)
        p_data.position = player.physical_position
    end
    player.character.teleport(player.physical_surface.find_non_colliding_position('character', { 0, 0 }, 4, 1))
    Sounds.notify_player(player, 'utility/build_blueprint_large')
    player.force = game.forces.spectator
    player.character.destructible = false
    if not forced_join then
        local msg = player.name .. ' is spectating.'
        game.print(msg, { color = { r = 0.98, g = 0.66, b = 0.22 } })
        Server.to_discord_bold(msg)
    end
    game.permissions.get_group('spectator').add_player(player)
    Admin.switch_to_admin_mode(player, false)
    storage.spectator_rejoin_delay[player.name] = game.tick
    Public.create_main_gui(player)
    player.spectator = true
    player.show_on_map = false
    CraftingQueueList.on_team_changed(player)
end

local function join_gui_click(name, player, auto_join)
    if not name then
        return
    end

    join_team(player, name, false, auto_join)
end

---The ordered (friendly, enemy) pairs a spy fish charts: for every team of the
---round, in `Teams.all()` order, every other team in the same order. With two
---teams that is today's matrix, in today's order:
---`{ { 'north', 'south' }, { 'south', 'north' } }`. Elimination is deliberately
---not consulted -- the legacy matrix was a constant, and the loop below writes
---`storage.spy_fish_timeout` for every friendly team it visits.
---@return string[][]
local function spy_force_pairs()
    local teams = Teams.all()
    local forces = {}
    for i = 1, #teams do
        for j = 1, #teams do
            if i ~= j then
                forces[#forces + 1] = { teams[i], teams[j] }
            end
        end
    end
    return forces
end

function Public.spy_fish()
    for _, f in ipairs(spy_force_pairs()) do
        local friendly = f[1]
        local enemy = f[2]
        if (storage.spy_fish_timeout[friendly] or 0) - game.tick > 0 then
            local r = 96
            local surface = game.surfaces[storage.bb_surface_name]
            for _, player in pairs(game.forces[enemy].connected_players) do
                game.forces[friendly].chart(surface, {
                    { player.physical_position.x - r, player.physical_position.y - r },
                    { player.physical_position.x + r, player.physical_position.y + r },
                })
            end

            if not MultiSilo.is_disabled() then
                for _, silo in ipairs(storage.rocket_silo[enemy] or {}) do
                    local pos = silo.position
                    game.forces[friendly].chart(surface, {
                        { pos.x - r, pos.y - r },
                        { pos.x + r, pos.y + r },
                    })
                end
            end
        else
            storage.spy_fish_timeout[friendly] = 0
        end
    end
end

local function on_gui_click(event)
    local element = event.element
    if not (element and element.valid) then
        return
    end

    local player = game.get_player(event.player_index)
    if not (player and player.valid) then
        return
    end

    local name = element.name

    if name == 'bb_toggle_main_gui' then
        local main_frame = Gui.get_left_element(player, 'bb_main_gui')
        if main_frame then
            main_frame.destroy()
        else
            Public.create_main_gui(player)
        end
        return
    end

    if name == 'bb_toggle_statistics' then
        local default = element.sprite == 'utility/expand'
        element.sprite = default and 'utility/collapse' or 'utility/expand'
        -- element.hovered_sprite = default and 'utility/collapse_dark' or 'utility/expand_dark'
        element.tooltip = default and 'Hide game status!' or 'Show game status!'

        local frame = Gui.get_top_element(player, 'bb_frame_statistics')
        if frame then
            frame.visible = not frame.visible
            Public.refresh_statistics(player, get_data_for_refresh_statistics())
        end
        return
    end

    if name == 'bb_toggle_player_list' then
        local team_frame = element.parent.parent.parent
        team_frame.players.visible = element.toggled
        Public.refresh_main_gui(player, get_data_for_refresh_main_gui())
        return
    end

    if name == 'raw-fish' then
        Functions.spy_fish(player, event)
        return
    end

    if food_names[name] then
        if not Captain_event.captain_is_player_prohibited_to_throw(player) then
            Feeding.feed_biters_from_inventory(player, name)
        end
        return
    end

    if name == 'bb_science_window_open' or name == 'bb_science_window_close' then
        ScienceWindow.toggle(player)
        return
    end

    local focus_target = string_match(name, '^bb_science_focus_(.+)$')
    if focus_target then
        local team = player.force.name
        local ok, result = Teams.toggle_science_focus(team, focus_target, game.tick, player.index)
        if not ok then
            player.print(result, { color = { r = 0.98, g = 0.66, b = 0.22 } })
        else
            player.force.print(
                player.name
                    .. (result and ' ticked ' or ' unticked ')
                    .. Teams.name_with_color(focus_target)
                    .. ' (each player steers '
                    .. Teams.format_percent(ScienceWindow.player_part(team))
                    .. ' % of every send). Next send: '
                    .. ScienceWindow.shares_text(team, true)
                    .. '.',
                { color = { r = 0.98, g = 0.66, b = 0.22 } }
            )
        end
        local data = get_data_for_refresh_main_gui()
        for _, p in pairs(player.force.connected_players) do
            Public.refresh_main_gui(p, data)
        end
        return
    end

    if name == 'send_all' then
        if not Captain_event.captain_is_player_prohibited_to_throw(player) then
            Feeding.feed_biters_mixed_from_inventory(player, event.button)
        end
        return
    end

    -- One 'join_<team>' button per team of the round; with two teams those are
    -- the 'join_north' and 'join_south' of old. 'join_random' is never a team
    -- name, so it falls through to its own handler below.
    local join_target = string_match(name, '^join_(.+)$')
    if join_target and Teams.is_active(join_target) then
        -- Above two teams a button can outlive its team: the strip is rebuilt
        -- on a reset, not on an elimination. Branch on the count rather than on
        -- the alive flag alone -- a two-team game over may or may not have
        -- marked the loser dead, and that path must stay exactly today's.
        if Teams.count() > 2 and not Teams.is_alive(join_target) then
            player.print(
                Functions.team_name_with_color(join_target) .. ' is out of this round.',
                { color = { r = 0.98, g = 0.66, b = 0.22 } }
            )
            return
        end
        join_gui_click(join_target, player)
        return
    end

    if name == 'join_random' then
        local teams = Teams.all()
        if Teams.count() == 2 then
            local north_connected_players = #game.forces[teams[1]].connected_players
            local south_connected_players = #game.forces[teams[2]].connected_players

            -- choosing a team at random if teams are equal
            if north_connected_players == south_connected_players then
                join_gui_click(teams[math_random(#teams)], player, true)
            else -- checking which team is smaller and joining it
                local smallest_team = north_connected_players < south_connected_players and teams[1] or teams[2]
                join_gui_click(smallest_team, player, true)
            end
            return
        end

        -- Above two teams: the smallest team still in the round, the first one
        -- of Teams.alive() on a tie. Dead teams are skipped for the same reason
        -- they get no button of their own -- the shuffle must not be the way
        -- into a team with no base. No draw: the two-team tie-break is the only
        -- math_random of this file and the global stream is shared by the whole
        -- scenario.
        local smallest_team, smallest_players
        for _, team in ipairs(Teams.alive()) do
            local players = #game.forces[team].connected_players
            if not smallest_team or players < smallest_players then
                smallest_team, smallest_players = team, players
            end
        end
        join_gui_click(smallest_team, player, true)
        return
    end

    if name == 'bb_resume' then
        local chosen = storage.chosen_team[player.name]
        -- The same refusal the per-team join buttons give, for the same reason:
        -- a Resume row can outlive the team it points at, since the panel is
        -- rebuilt on a reset and not on an elimination. Two teams never mark a
        -- team dead while the round runs, so the count test alone keeps today's
        -- single line; and `chosen` may be nil, which `join_team` already
        -- treats as nothing to do.
        if Teams.count() > 2 and chosen and not Teams.is_alive(chosen) then
            player.print(
                Functions.team_name_with_color(chosen) .. ' is out of this round.',
                { color = { r = 0.98, g = 0.66, b = 0.22 } }
            )
            return
        end
        join_team(player, chosen)
        return
    end

    if name == 'bb_spectate' then
        local distance = player.physical_position.y ^ 2 + player.physical_position.x ^ 2
        if distance < 12000 or MultiSilo.can_spectate(player) then
            spectate(player)
        else
            player.print('You are too far away from spawn to spectate.', { color = { r = 0.98, g = 0.66, b = 0.22 } })
        end
        return
    end

    if name == 'bb_floating_shortcut_button' then
        local shortcuts_frame = Shortcuts.get_main_frame(player)
        if shortcuts_frame and shortcuts_frame.valid then
            shortcuts_frame.visible = not shortcuts_frame.visible
            shortcuts_frame.bring_to_front()
        end
        return
    end

    if name == 'suspend_yes' then
        local suspend_info = storage.suspend_target_info
        if suspend_info then
            if player.force.name == suspend_info.target_force_name then
                if suspend_info.suspend_votes_by_player[player.name] ~= 1 then
                    suspend_info.suspend_votes_by_player[player.name] = 1
                    game.print(
                        player.name .. ' wants to suspend ' .. suspend_info.suspendee_player_name,
                        { color = { r = 0.1, g = 0.9, b = 0.0 } }
                    )
                end
            else
                player.print('You cannot vote from a different force!', { color = { r = 0.9, g = 0.1, b = 0.1 } })
            end
        end
    end

    if name == 'suspend_no' then
        local suspend_info = storage.suspend_target_info
        if suspend_info then
            if player.force.name == suspend_info.target_force_name then
                if suspend_info.suspend_votes_by_player[player.name] ~= 0 then
                    suspend_info.suspend_votes_by_player[player.name] = 0
                    game.print(
                        player.name .. " doesn't want to suspend " .. suspend_info.suspendee_player_name,
                        { color = { r = 0.9, g = 0.1, b = 0.1 } }
                    )
                end
            else
                player.print('You cannot vote from a different force!', { color = { r = 0.9, g = 0.1, b = 0.1 } })
            end
        end
    end

    if name == 'reroll_yes' then
        if storage.reroll_map_voting[player.name] ~= 1 then
            storage.reroll_map_voting[player.name] = 1
            game.print(player.name .. ' wants to reroll map ', { color = { r = 0.1, g = 0.9, b = 0.0 } })
        end
    end

    if name == 'reroll_no' then
        if storage.reroll_map_voting[player.name] ~= 0 then
            storage.reroll_map_voting[player.name] = 0
            game.print(player.name .. ' wants to keep this map', { color = { r = 0.9, g = 0.1, b = 0.1 } })
        end
    end

    if name == 'automatic_captain_yes' then
        if storage.automatic_captain_voting[player.name] ~= 1 then
            storage.automatic_captain_voting[player.name] = 1
            game.print(player.name .. ' wants to play a captain game', { color = { r = 0.1, g = 0.9, b = 0.0 } })
        end
    end

    if name == 'automatic_captain_no' then
        if storage.automatic_captain_voting[player.name] ~= 0 then
            storage.automatic_captain_voting[player.name] = 0
            game.print(
                player.name .. ' does not want to play a captain game',
                { color = { r = 0.9, g = 0.1, b = 0.1 } }
            )
        end
    end

    if name == 'bb_pause' then
        if
            not storage.bb_game_won_by_team
            and (not storage.gui_bb_pause_cooldown or storage.gui_bb_pause_cooldown < game.ticks_played)
        then
            game.print(
                'Game paused by ' .. player.name,
                { color = { r = 0.98, g = 0.66, b = 0.22 }, skip = defines.print_skip.never }
            )

            game.tick_paused = true
            storage.gui_bb_pause_cooldown = game.ticks_played + 60
            Public.refresh()
        end
    end

    if name == 'bb_resume_game' then
        if
            not storage.bb_game_won_by_team
            and (not storage.gui_bb_pause_cooldown or storage.gui_bb_pause_cooldown < game.ticks_played)
        then
            game.print(
                'Game resumed by ' .. player.name,
                { color = { r = 0.98, g = 0.66, b = 0.22 }, skip = defines.print_skip.never }
            )

            game.tick_paused = false
            storage.gui_bb_pause_cooldown = game.ticks_played + 60
            Public.refresh()
        end
    end
end

local function on_player_joined_game(event)
    local player = game.get_player(event.player_index)
    if player.online_time == 0 then
        Init.set_default_settings(player)
        Functions.set_random_color(player)
        -- tt_mode: skip the map-intro popup for newcomers (requested 2026-06-30).
        -- The top-bar map_intro_button still lets them open it manually.
        if not storage.tt_mode then
            Functions.show_intro(player)
        end
    end

    Public.create_main_gui(player)
end

Event.add(defines.events.on_gui_click, on_gui_click)
Event.add(defines.events.on_player_joined_game, on_player_joined_game)
Event.add(defines.events.on_player_left_game, on_player_left_game)

return Public
