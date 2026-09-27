local ClosableFrame = require('utils.ui.closable_frame')
local Functions = require('maps.biter_battles_v2.functions')
local Gui = require('utils.gui')
local Model = require('maps.biter_battles_v2.team_manager_model')
local Server = require('utils.server')
local Teams = require('maps.biter_battles_v2.teams')
local gui_style = require('utils.utils').gui_style

local Public = {}

--- The button colour of the two legacy teams, by position in the ring (north is
--- 1, south is 3): darker than the roster's own colours and kept to the value
--- it has always had here. A team without an entry uses the roster colour.
local legacy_button_color = {
    [1] = { r = 0, g = 0, b = 200 },
    [3] = { r = 200, g = 0, b = 0 },
}
local spectator_button_color = { r = 111, g = 111, b = 111 }

--- The manager's chain of destinations, left to right: the teams of the round
--- with 'spectator' in the middle, after the first ceil(N/2) of them. With two
--- teams that is today's { north, spectator, south }, same order, same colours.
--- A redesign of the 1-D chain is left for later.
---@return { name: string, color: { r: integer, g: integer, b: integer } }[]
local function force_chain()
    local teams = Teams.all()
    local spectator_after = math.ceil(#teams / 2)
    local chain = {}
    for i = 1, #teams do
        local team = teams[i]
        chain[#chain + 1] = {
            name = team,
            color = legacy_button_color[Teams.ring_index(team)] or Teams.color(team),
        }
        if i == spectator_after then
            chain[#chain + 1] = { name = 'spectator', color = spectator_button_color }
        end
    end
    return chain
end

local function get_player_array(force_name)
    local a = {}
    for _, p in pairs(game.forces[force_name].connected_players) do
        a[#a + 1] = p.name
    end
    return a
end

function Public.freeze_players()
    if not storage.freeze_players then
        return
    end
    storage.team_manager_default_permissions = {}
    local p = game.permissions.get_group('Default')
    for action_name, _ in pairs(defines.input_action) do
        storage.team_manager_default_permissions[action_name] = p.allows_action(defines.input_action[action_name])
        p.set_allows_action(defines.input_action[action_name], false)
    end
    local defs = {
        defines.input_action.delete_custom_tag,
        defines.input_action.edit_custom_tag,
        defines.input_action.edit_permission_group,
        defines.input_action.gui_checked_state_changed,
        defines.input_action.gui_click,
        defines.input_action.gui_confirmed,
        defines.input_action.gui_elem_changed,
        defines.input_action.gui_location_changed,
        defines.input_action.gui_selected_tab_changed,
        defines.input_action.gui_selection_state_changed,
        defines.input_action.gui_switch_state_changed,
        defines.input_action.gui_text_changed,
        defines.input_action.gui_value_changed,
        defines.input_action.remote_view_surface,
        defines.input_action.write_to_console,
    }
    for _, d in pairs(defs) do
        p.set_allows_action(d, true)
    end
    require('comfy_panel.special_games.captain').resync_no_research_group()
end

function Public.unfreeze_players()
    local p = game.permissions.get_group('Default')
    for action_name, _ in pairs(defines.input_action) do
        if storage.team_manager_default_permissions[action_name] then
            p.set_allows_action(defines.input_action[action_name], true)
        end
    end
    require('comfy_panel.special_games.captain').resync_no_research_group()
end

local function leave_corpse(player)
    if not player.character then
        return
    end

    local inventories = {
        player.character.get_inventory(defines.inventory.character_main),
        player.character.get_inventory(defines.inventory.character_guns),
        player.character.get_inventory(defines.inventory.character_ammo),
        player.character.get_inventory(defines.inventory.character_armor),
        player.character.get_inventory(defines.inventory.character_vehicle),
        player.character.get_inventory(defines.inventory.character_trash),
    }

    local corpse = false
    for _, i in pairs(inventories) do
        for index = 1, #i, 1 do
            if not i[index].valid then
                break
            end
            corpse = true
            break
        end
        if corpse then
            player.character.die()
            break
        end
    end

    if player.character then
        player.character.destroy()
    end
    player.character = nil
    player.set_controller({ type = defines.controllers.god })
    -- In a situtation when player looks at chunk which was not generated yet
    -- removing the character and subsequent attempt to create it will fail
    -- silently. Reposition the view to middle of the surface.
    player.teleport({ 0, 0 })
    player.create_character()
end

---@param player_name Name of the player that will be switched.
---@param force_name Name of the force where the player will be switched.
---@param origin LuaPlayer|nil Player that executed the action.
function Public.switch_force(player_name, force_name, origin)
    if not game.get_player(player_name) then
        game.print(
            'Team Manager >> Player ' .. player_name .. ' does not exist.',
            { color = { r = 0.98, g = 0.66, b = 0.22 } }
        )
        return
    end
    if not game.forces[force_name] then
        game.print(
            'Team Manager >> Force ' .. force_name .. ' does not exist.',
            { color = { r = 0.98, g = 0.66, b = 0.22 } }
        )
        return
    end

    local player = game.get_player(player_name)
    player.force = game.forces[force_name]
    local trace
    if origin then
        trace = player_name .. ' has been switched by ' .. origin.name .. ' into '
    else
        trace = player_name .. ' has been switched into '
    end

    trace = trace .. Functions.team_name_with_color(force_name) .. '.'
    game.print(trace, { color = { r = 0.98, g = 0.66, b = 0.22 } })
    Server.to_discord_bold(player_name .. ' has joined team ' .. force_name .. '!')

    leave_corpse(player)

    storage.chosen_team[player_name] = nil
    if force_name == 'spectator' then
        spectate(player, true)
    else
        join_team(player, force_name, true)
    end
end

function Public.draw_top_toggle_button(player)
    local button = Gui.add_top_element(player, {
        type = 'sprite-button',
        name = 'team_manager_toggle_button',
        sprite = 'utility/force_editor_icon',
        tooltip = { 'gui.team_manager_top_button' },
    })
end

---Today's window, and the only one a two-team round ever draws: one column per
---entry of the chain -- the teams with the spectators in the middle -- and
---between two columns the pair of arrows that walks the selected player one
---step along it. Every element, name, caption, colour and style here is what it
---has always been, and the numbers the arrows are named after are what the
---click arithmetic of `team_manager_gui_click` reads.
---@param frame LuaGuiElement
local function draw_chain_table(frame)
    local forces = force_chain()
    local t = frame.add({ type = 'table', name = 'team_manager_root_table', column_count = #forces * 2 - 1 })

    local i2 = 1
    for i = 1, #forces * 2 - 1, 1 do
        if i % 2 == 1 then
            local l = t.add({
                type = 'sprite-button',
                caption = string.upper(forces[i2].name),
                name = forces[i2].name,
                style = 'frame_button',
            })
            l.style.minimal_width = 160
            l.style.maximal_width = 160
            l.style.font_color = forces[i2].color
            l.style.font = 'heading-1'
            i2 = i2 + 1
        else
            local tt = t.add({ type = 'label', caption = ' ' })
        end
    end

    local i2 = 1
    for i = 1, #forces * 2 - 1, 1 do
        if i % 2 == 1 then
            local list_box = t.add({
                type = 'list-box',
                name = 'team_manager_list_box_' .. i2,
                items = get_player_array(forces[i2].name),
            })
            list_box.style.minimal_height = 360
            list_box.style.minimal_width = 160
            list_box.style.maximal_height = 480
            i2 = i2 + 1
        else
            local tt = t.add({ type = 'table', column_count = 1 })
            local b = tt.add({ type = 'sprite-button', name = i2 - 1, caption = '→' })
            b.style.font = 'heading-1'
            b.style.maximal_height = 38
            b.style.maximal_width = 38
            local b = tt.add({ type = 'sprite-button', name = i2, caption = '←' })
            b.style.font = 'heading-1'
            b.style.maximal_height = 38
            b.style.maximal_width = 38
        end
    end
end

---A column of the window above two teams is this wide: four destination buttons
---side by side at their widest ('spec' in bold takes 48 px), the scrollbar of
---the list and its padding. Five columns make the window about 1050 px wide,
---inside the 1366 px screen the windows are laid out for.
local destination_column_width = 200

---One player of a column above two teams: the name, and under it the row of
---buttons that sends them straight to any other destination. The buttons carry
---the destination and the player in their `tags`; their names only have to tell
---siblings apart, which is why a player name -- dots, dashes and underscores
---included -- is never parsed out of one.
---@param pane LuaGuiElement The column's player list.
---@param player_name string
---@param destinations TeamManagerDestination[] Shared by every entry of the column.
local function draw_player_entry(pane, player_name, destinations)
    local entry = pane.add({ type = 'flow', name = Model.entry_name(player_name), direction = 'vertical' })
    entry.style.vertical_spacing = 0
    entry.style.bottom_margin = 4

    local label = entry.add({ type = 'label', name = 'team_manager_name', caption = player_name })
    label.style.single_line = false
    label.style.maximal_width = destination_column_width - 24
    if Teams.is_player_eliminated(player_name) then
        -- Only ever set above two teams: a two-team round has no elimination
        -- step, so nobody is ever marked. The admin can still move them -- a
        -- forced join is not refused (gui.lua:1365-1389) -- but they are in the
        -- spectator column for a reason and it is not their own choice.
        label.tooltip = 'Played for a team that is out of this round.'
    end

    if #destinations == 0 then
        return
    end
    local moves = entry.add({ type = 'table', name = 'team_manager_moves', column_count = #destinations })
    moves.style.horizontal_spacing = 2
    for _, destination in ipairs(destinations) do
        local b = moves.add({
            type = 'button',
            name = Model.move_button_name(destination.force),
            caption = destination.caption,
            tooltip = destination.tooltip,
            style = 'tool_button',
            tags = Model.button_tags(destination.force, player_name),
        })
        b.style.height = 28
        b.style.padding = 2
        b.style.minimal_width = 36
        b.style.maximal_width = 48
        b.style.font = 'default-bold'
        b.style.font_color = destination.color or spectator_button_color
    end
end

---Above two teams: one column per team of the round plus the spectators, no
---arrow columns. Moving a player from one corner to the opposite one is one
---click here, where the chain needed a walk through every team in between.
---
---A team that is out of the round keeps its column -- its players were moved to
---the spectators when it died, but the admin has to see that it is there and
---out -- and is nobody's destination.
---@param frame LuaGuiElement
local function draw_destination_table(frame)
    local columns = Model.columns()
    local t = frame.add({ type = 'table', name = 'team_manager_root_table', column_count = #columns })

    for _, column in ipairs(columns) do
        local l = t.add({
            type = 'sprite-button',
            caption = column.caption,
            name = column.force,
            style = 'frame_button',
        })
        l.style.minimal_width = destination_column_width
        l.style.maximal_width = destination_column_width
        l.style.font_color = column.color or spectator_button_color
        l.style.font = 'heading-1'
        if not column.alive then
            l.tooltip = column.display .. ' is out of this round.'
        end
    end

    for _, column in ipairs(columns) do
        local pane = t.add({
            type = 'scroll-pane',
            name = Model.column_name(column.force),
            horizontal_scroll_policy = 'never',
            vertical_scroll_policy = 'auto',
        })
        pane.style.minimal_width = destination_column_width
        pane.style.maximal_width = destination_column_width
        pane.style.minimal_height = 360
        pane.style.maximal_height = 480
        local destinations = Model.destinations(column.force)
        for _, player_name in ipairs(get_player_array(column.force)) do
            draw_player_entry(pane, player_name, destinations)
        end
    end
end

local function draw_manager_gui(player)
    if player.gui.screen['team_manager_gui'] then
        player.gui.screen['team_manager_gui'].destroy()
    end

    local frame = ClosableFrame.create_main_closable_frame(player, 'team_manager_gui', 'Manage Teams')

    if Teams.count() == 2 then
        draw_chain_table(frame)
    else
        draw_destination_table(frame)
    end

    local flow = frame.add({ type = 'flow' })
    flow.style.horizontal_align = 'center'
    flow.style.horizontally_stretchable = true
    flow.style.top_margin = 8
    local t = flow.add({ type = 'table', name = 'team_manager_bottom_buttons', column_count = 3 })

    local button
    if storage.tournament_mode then
        button = t.add({
            type = 'button',
            name = 'team_manager_activate_tournament',
            caption = 'Tournament Mode Enabled',
            tooltip = 'Only admins can move players and vote for difficulty.\nActive players can no longer go spectate.\nNew joining players are spectators.',
        })
        button.style.font_color = { r = 222, g = 22, b = 22 }
    else
        button = t.add({
            type = 'button',
            name = 'team_manager_activate_tournament',
            caption = 'Tournament Mode Disabled',
            tooltip = 'Only admins can move players. Active players can no longer go spectate. New joining players are spectators.',
        })
        button.style.font_color = { r = 55, g = 55, b = 55 }
    end
    button.style.font = 'heading-2'

    if storage.freeze_players then
        button = t.add({
            type = 'button',
            name = 'team_manager_freeze_players',
            caption = 'Unfreeze Players',
            tooltip = 'Releases all players.',
        })
        button.style.font_color = { r = 222, g = 22, b = 22 }
    else
        button = t.add({
            type = 'button',
            name = 'team_manager_freeze_players',
            caption = 'Freeze Players',
            tooltip = 'Freezes all players, unable to perform actions, until released.',
        })
        button.style.font_color = { r = 55, g = 55, b = 222 }
    end
    button.style.font = 'heading-2'

    if storage.training_mode then
        button = t.add({
            type = 'button',
            name = 'team_manager_activate_training',
            caption = 'Training Mode Activated',
            tooltip = "Feed your own team's biters and only teams with players gain threat & evo.",
        })
        button.style.font_color = { r = 222, g = 22, b = 22 }
    else
        button = t.add({
            type = 'button',
            name = 'team_manager_activate_training',
            caption = 'Training Mode Disabled',
            tooltip = "Feed your own team's biters and only teams with players gain threat & evo.",
        })
        button.style.font_color = { r = 55, g = 55, b = 55 }
    end
    button.style.font = 'heading-2'
end

local function set_custom_team_name(force_name, team_name)
    if team_name == '' then
        storage.tm_custom_name[force_name] = nil
        return
    end
    if not team_name then
        storage.tm_custom_name[force_name] = nil
        return
    end
    storage.tm_custom_name[force_name] = tostring(team_name)
end

---Make the top statistics strip show a name that has just changed.
---
---Above two teams the strip captions each block with `Teams.display_name`,
---which is written once when the strip is built: `refresh_statistics` only ever
---rewrites the tooltip, so a name set here would not appear until the next map
---reset. Rebuild the strip -- the rebuild already used when the
---team count changes -- for every player, offline ones included, exactly as
---`generate_new_map` does. With two teams the strip is captioned with the
---literal compass words and the custom name has only ever reached the tooltip,
---which every refresh rewrites, so nothing is rebuilt there.
---
---`rebuild_team_guis` keeps a hidden strip hidden, but it rebuilds the main
---panel too, and a main panel that is not there is one the player CLOSED --
---`bb_toggle_main_gui` destroys it rather than hiding it. A rename is not a map
---reset, so a panel that was closed is closed again afterwards.
---
---`gui.lua` reaches this file through `captain.lua`, so the module is fetched at
---call time rather than at load: at runtime `require` of a module the control
---stage already loaded is a table lookup (control.lua's lockdown), the way
---`feeding_params.lua` reaches `match_format`.
local function rebuild_team_captions()
    if Teams.count() == 2 then
        return
    end
    local BBGui = require('maps.biter_battles_v2.gui')
    for _, player in pairs(game.players) do
        local had_main_gui = Gui.get_left_element(player, 'bb_main_gui') ~= nil
        BBGui.rebuild_team_guis(player)
        if not had_main_gui then
            local main_gui = Gui.get_left_element(player, 'bb_main_gui')
            if main_gui and main_gui.valid then
                main_gui.destroy()
            end
        end
    end
end

function Public.custom_team_name_gui(player, force_name)
    local frame = ClosableFrame.create_secondary_closable_frame(player, 'custom_team_name_gui', 'Set custom team name:')
    if not frame then
        return
    end
    local text = Functions.team_name(force_name)

    local textfield = frame.add({ type = 'textfield', name = 'textfield' .. force_name, text = text })
    local button = frame.add({
        type = 'button',
        name = 'custom_team_name_gui_set',
        caption = 'Set',
        tooltip = 'Set custom team name.',
    })
    button.style.font = 'heading-2'
end

local function isReferee(player)
    if
        storage.active_special_games['captain_mode']
        and storage.special_games_variables['captain_mode']['refereeName'] == player.name
    then
        return true
    else
        return false
    end
end

local function team_manager_gui_click(event)
    local player = game.get_player(event.player_index)
    local name = event.element.name

    if game.forces[name] then
        if not is_admin(player) then
            player.print('Only admins can change team names.', { color = { r = 175, g = 0, b = 0 } })
            return
        end
        Public.custom_team_name_gui(player, name)
        return
    end

    if name == 'team_manager_activate_tournament' then
        if not is_admin(player) then
            player.print('Only admins can switch tournament mode.', { color = { r = 175, g = 0, b = 0 } })
            return
        end
        if
            storage.active_special_games['captain_mode'] == true
            and storage.special_games_variables['captain_mode']['prepaPhase'] == true
        then
            player.print(
                'You cant disable tournament mode during prepa phase of captain event !',
                { color = { r = 175, g = 0, b = 0 } }
            )
            return
        end
        if storage.tournament_mode then
            storage.tournament_mode = false
            draw_manager_gui(player)
            game.print(
                '>>> Tournament Mode has been disabled by ' .. player.name,
                { color = { r = 111, g = 111, b = 111 } }
            )
            return
        end
        storage.tournament_mode = true
        draw_manager_gui(player)
        game.print('>>> Tournament Mode has been enabled by ' .. player.name, { color = { r = 225, g = 0, b = 0 } })
        if storage.bb_settings.classic_pathfinding then
            game.print(">>> WARNING: Classic pathfinding is enabled and is not recommended for captain's games")
        end
        return
    end

    if name == 'team_manager_freeze_players' then
        if storage.freeze_players then
            if not is_admin(player) then
                player.print('Only admins can unfreeze players.', { color = { r = 175, g = 0, b = 0 } })
                return
            end
            if
                storage.active_special_games['captain_mode'] == true
                and storage.special_games_variables['captain_mode']['prepaPhase'] == true
            then
                player.print(
                    'You cant unfreeze during prepa phase of captain event !',
                    { color = { r = 175, g = 0, b = 0 } }
                )
                return
            end
            storage.freeze_players = false
            draw_manager_gui(player)
            game.print('>>> Players have been unfrozen by ' .. player.name, { color = { r = 255, g = 77, b = 77 } })
            Public.unfreeze_players()
            return
        end
        if not is_admin(player) then
            player.print('Only admins can freeze players.', { color = { r = 175, g = 0, b = 0 } })
            return
        end
        storage.freeze_players = true
        draw_manager_gui(player)
        game.print('>>> Players have been frozen by ' .. player.name, { color = { r = 111, g = 111, b = 255 } })
        Public.freeze_players()
        return
    end

    if name == 'team_manager_activate_training' then
        if not is_admin(player) then
            player.print('Only admins can switch training mode.', { color = { r = 175, g = 0, b = 0 } })
            return
        end
        if storage.training_mode then
            storage.training_mode = false
            draw_manager_gui(player)
            game.print(
                '>>> Training Mode has been disabled by ' .. player.name,
                { color = { r = 111, g = 111, b = 111 } }
            )
            return
        end
        storage.training_mode = true
        draw_manager_gui(player)
        game.print('>>> Training Mode has been enabled by ' .. player.name, { color = { r = 225, g = 0, b = 0 } })
        return
    end

    -- Above two teams every player entry carries its own destination buttons.
    -- A button says where it sends whom in its `tags`, not in its name: player
    -- names may contain dots, dashes and underscores, so a name built from both
    -- could not be taken apart again without guessing.
    local move_to, moved_player = Model.parse_click(event.element.tags)
    if move_to then
        if not is_admin(player) and not isReferee(player) then
            player.print('Only admins can manage teams.', { color = { r = 175, g = 0, b = 0 } })
            return
        end
        if not Model.is_available_destination(move_to) then
            -- The window is destroyed when the team count changes, not when a
            -- team dies under it: the button outlived its destination.
            player.print(
                Functions.team_name_with_color(move_to) .. ' is out of this round.',
                { color = { r = 0.98, g = 0.66, b = 0.22 } }
            )
            draw_manager_gui(player)
            return
        end
        -- A move from one team straight to another is new: the arrow chain only
        -- ever moved one step, so every team change went through the spectators,
        -- and `join_team` -- which `switch_force` ends in -- does the teleport to
        -- the new spawn and the starting items only for a spectator. So a button
        -- from team to team makes the two moves the chain made: out to the
        -- spectators, then in, with the two chat lines the admin's two clicks
        -- printed.
        local moved = game.get_player(moved_player)
        if moved and Teams.is_team(moved.force.name) and Teams.is_team(move_to) then
            Public.switch_force(moved_player, 'spectator', player)
        end
        Public.switch_force(moved_player, move_to, player)
        draw_manager_gui(player)
        return
    end

    if Teams.count() > 2 then
        -- Everything below reads today's chain window, where the only elements
        -- two levels under the root table are the arrows and their names are
        -- chain positions. Above two teams that place is held by the player
        -- entries, whose names are not numbers, so the walk stops here. The
        -- window cannot be the other round's one: it is destroyed when the team
        -- count changes (game_over.lua `TEAM_SHAPED_SCREEN_GUIS`).
        return
    end

    if not event.element.parent then
        return
    end
    local element = event.element.parent
    if not element.parent then
        return
    end
    local element = element.parent
    if element.name ~= 'team_manager_root_table' then
        return
    end
    if not is_admin(player) and not isReferee(player) then
        player.print('Only admins can manage teams.', { color = { r = 175, g = 0, b = 0 } })
        return
    end

    local listbox =
        player.gui.screen['team_manager_gui']['team_manager_root_table']['team_manager_list_box_' .. tonumber(name)]
    local selected_index = listbox.selected_index
    if selected_index == 0 then
        player.print('No player selected.', { color = { r = 175, g = 0, b = 0 } })
        return
    end
    local player_name = listbox.items[selected_index]

    local m = -1
    if event.element.caption == '→' then
        m = 1
    end
    -- A window drawn for a round with more teams keeps its arrows after a
    -- reset; with two teams every arrow always lands inside the chain.
    local destination = force_chain()[tonumber(name) + m]
    if not destination then
        return
    end
    local force_name = destination.name

    Public.switch_force(player_name, force_name, player)

    draw_manager_gui(player)
end

function Public.gui_click(event)
    if not event.element then
        return
    end
    if not event.element.valid then
        return
    end
    local player = game.get_player(event.player_index)
    local name = event.element.name

    if name == 'team_manager_toggle_button' then
        if player.gui.screen['team_manager_gui'] then
            player.gui.screen['team_manager_gui'].destroy()
            return
        end
        draw_manager_gui(player)
        return
    end

    if player.gui.screen['team_manager_gui'] then
        team_manager_gui_click(event)
    end

    if player.gui.screen['custom_team_name_gui'] then
        if name == 'custom_team_name_gui_set' then
            local custom_name = player.gui.screen['custom_team_name_gui'].children[2].text
            local force_name = string.sub(player.gui.screen['custom_team_name_gui'].children[2].name, 10)
            set_custom_team_name(force_name, custom_name)
            rebuild_team_captions()
            player.gui.screen['custom_team_name_gui'].destroy()
            return
        end
    end
end

return Public
