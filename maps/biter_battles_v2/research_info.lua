local flui = require('utils.ui.gui-lite')
local uic = require('utils.ui.fcomponents')
local Event = require('utils.event')
local Functions = require('maps.biter_battles_v2.functions')
local Teams = require('maps.biter_battles_v2.teams')
local Layout = require('maps.biter_battles_v2.layout')
local closable_frame = require('utils.ui.closable_frame')
local string_format = string.format
local table_sort = table.sort
local table_concat = table.concat
local table_insert = table.insert

local MAXHEIGHT_PADDING = 50

---The window's static skeleton: one panel per active team, then the shared
---bucket. Built on demand rather than once at load, because the panel list
---comes from the round's team registry and reading it creates the round state.
---With two teams this is the same tree in the same order as the literal
---`{ 'north', 'south' }` it replaces.
---@return GuiElemDef
local function ui_template()
    --[[
        research_info_ui
            scroll
                main
    ]]
    local container = uic.blocks.vflow('main')
    -- Two teams keep the one-row `hflow` they have always had. Above two teams
    -- the panels go in a two-column grid -- 2x2 with four teams, 2+1 with three
    -- -- so that no panel is ever more than half the window wide: four 365 px
    -- panels in a row are ~1500 px and the window's scroll pane has no
    -- horizontal axis to recover them with (`horizontal_scroll_policy =
    -- 'never'`), so the fourth was simply cut off by the edge of the screen
    -- (screenshot gui4-before/02-research-info.png).
    --
    -- That grid is a picture of the map, so the panels go in it in MAP order
    -- (`Layout.grid_order`), not in the ring order the rest of the scenario
    -- iterates in: the ring is a pinwheel, and laying it out row by row put the
    -- bottom-right team in the bottom-left cell -- seen in the client on
    -- 2026-09-20. With three teams the bottom-left cell is the closed quadrant
    -- and gets an empty widget, so the bottom-right panel stays bottom right.
    -- With two teams `grid_order` is `Teams.all()` and there is no hole, so the
    -- one-row strip below is the tree it has always been.
    local teams
    if Teams.count() == 2 then
        teams = uic.add(container, uic.blocks.hflow('teams'))
    else
        teams = uic.add(container, uic.blocks.table(2, 'teams'))
    end
    teams.style_mods = { vertically_stretchable = true }
    for cell, name in ipairs(Layout.grid_order()) do
        if not name then
            uic.add(teams, {
                type = 'empty-widget',
                name = 'empty_cell_' .. cell,
            })
            goto continue
        end
        uic.add(teams, {
            type = 'frame',
            style = 'inside_shallow_frame_with_padding',
            direction = 'vertical',
            name = name,
            style_mods = {
                natural_width = 365,
                padding = { 8, 12, 12, 12 },
                vertically_stretchable = true,
            },
            children = {
                {
                    type = 'label',
                    caption = 'UPDATE ME',
                    name = 'team_name_' .. name,
                    style_mods = {
                        font = 'heading-1',
                    },
                },
                {
                    type = 'label',
                    caption = 'Current Queue',
                    style_mods = {
                        font = 'heading-2',
                    },
                },
                {
                    type = 'frame',
                    direction = 'vertical',
                    name = 'queue_frame',
                    style = 'deep_frame_in_shallow_frame',
                    style_mods = {
                        padding = 4,
                        horizontally_stretchable = true,
                        bottom_margin = 4,
                    },
                    {
                        type = 'flow',
                        name = 'queue',
                        style_mods = {
                            padding = 0,
                        },
                        {
                            type = 'label',
                            caption = 'Loading...',
                        },
                    },
                },
                {
                    type = 'frame',
                    direction = 'vertical',
                    name = 'progress_frame',
                    style = 'deep_frame_in_shallow_frame',
                    style_mods = {
                        padding = 4,
                        horizontally_stretchable = true,
                        bottom_margin = 4,
                    },
                    {
                        type = 'table',
                        name = 'progress',
                        column_count = 15,
                        style_mods = {
                            horizontally_stretchable = false,
                        },
                        {
                            type = 'label',
                            caption = 'Loading...',
                        },
                    },
                },
                {
                    type = 'label',
                    caption = 'Researched (exclusive)',
                    style_mods = {
                        font = 'heading-2',
                    },
                },
                {
                    type = 'frame',
                    direction = 'vertical',
                    name = 'completed_frame',
                    style = 'deep_frame_in_shallow_frame',
                    style_mods = {
                        padding = 4,
                        horizontally_stretchable = true,
                        bottom_margin = 4,
                    },
                    {
                        type = 'table',
                        name = 'completed',
                        column_count = 8,
                        {
                            type = 'label',
                            caption = 'Loading...',
                        },
                    },
                },
            },
        })
        ::continue::
    end
    uic.add(container, {
        type = 'frame',
        style = 'inside_shallow_frame_with_padding',
        direction = 'vertical',
        name = 'both_teams',
        {
            type = 'label',
            caption = Teams.count() == 2 and 'Researched (both)' or 'Researched (all teams)',
            style_mods = {
                font = 'heading-1',
            },
        },
        {
            type = 'frame',
            direction = 'vertical',
            name = 'completed_frame',
            style = 'deep_frame_in_shallow_frame',
            style_mods = {
                padding = 4,
                horizontally_stretchable = true,
                bottom_margin = 4,
            },
            {
                type = 'table',
                name = 'completed_both',
                column_count = 18,
                {
                    type = 'label',
                    caption = 'Loading...',
                },
            },
        },
    })
    return container
end

---@alias research_info.tech_state { desc: string | nil, pct: number | nil, active: boolean }

---The name a tech tooltip gives a team's line: the force name with its first
---letter capitalised, which is the 'North' / 'South' of today to the byte.
---@param team string
---@return string
local function tooltip_name(team)
    return team:sub(1, 1):upper() .. team:sub(2)
end

---One line per active team, in `Teams.all()` order -- for two teams exactly the
---two fixed lines this replaces, same order, same separator.
---@param info table<string, research_info.tech_state>
---@return string
local function tech_tooltip(info)
    local tooltip_items = {}
    for _, team in ipairs(Teams.all()) do
        local team_info = info[team]
        table_insert(tooltip_items, tooltip_name(team) .. ': ' .. ((team_info and team_info.desc) or 'Not started'))
    end
    return table_concat(tooltip_items, '\n')
end

---@param tech_id string
---@param info table<string, research_info.tech_state>
---@return GuiElemDef
local function research_item(tech_id, info)
    ---@type GuiElemDef
    return {
        type = 'sprite',
        sprite = 'technology/' .. tech_id,
        tooltip = tech_tooltip(info),
        elem_tooltip = { type = 'technology', name = tech_id },
        name = '_' .. tech_id,
        tags = {
            -- match compatibility with progress_research_item
            sort_by = tech_id,
            tech_id = tech_id,
        },
        style_mods = {
            width = 38,
            height = 38,
            padding = 0,
            stretch_image_to_widget_size = true,
        },
    }
end

---Research item with progress percentage.
---@param tech_id string
---@param this_progress number
---@param is_active boolean
---@param info table<string, research_info.tech_state>
---@return GuiElemDef
local function progress_research_item(tech_id, this_progress, is_active, info)
    ---@type GuiElemDef
    local el = {
        type = 'flow',
        direction = 'vertical',
        name = '_' .. tech_id,
        style_mods = {
            vertical_spacing = 0,
            width = 38,
        },
        tags = {
            sort_by = tech_id,
            tech_id = tech_id,
        },
        research_item(tech_id, info),
        {
            type = 'progressbar',
            value = this_progress,
            tooltip = tech_tooltip(info),
            style_mods = {
                color = is_active and { 0, 1, 0 } or { 1, 1, 0 },
            },
        },
    }
    return el
end

local ResearchInfo = {}

---@param evt GuiEventData
function ResearchInfo.show_research_info_handler(evt)
    local player = game.get_player(evt.player_index)
    if not player then
        return
    end
    ResearchInfo.show_research_info(player)
end
local show_research_info_handler = ResearchInfo.show_research_info_handler

flui.add_handlers({
    research_info_button_click = show_research_info_handler,
})

function ResearchInfo.create_research_info_button(element)
    ---@type GuiElemDef
    local template = {
        type = 'sprite-button',
        sprite = 'utility/technology_white',
        name = 'research_info_button',
        tooltip = 'Science Info',
        style = 'transparent_slot',
        style_mods = {
            width = 26,
            height = 26,
            padding = 2,
        },
        handler = show_research_info_handler,
    }
    local _, button = flui.add(element, template)
    return button
end

---@param force LuaForce
---@param tech_name string
function ResearchInfo.research_finished(tech_name, force)
    local force_name = force.name
    if not Teams.is_active(force_name) then
        return
    end
    local tech_info = storage.research_info.completed[tech_name]
    if not tech_info then
        tech_info = {}
        storage.research_info.completed[tech_name] = tech_info
    end
    local ticks = Functions.get_ticks_since_game_start()
    tech_info[force_name] = Functions.format_ticks_as_time(ticks)
    storage.research_info.current_progress[force_name][tech_name] = nil

    ResearchInfo.update_research_info_ui(true)
end

---@param force LuaForce
---@param tech_name string
function ResearchInfo.research_started(tech_name, force)
    local force_name = force.name
    if not Teams.is_active(force_name) then
        return
    end
    storage.research_info.current_progress[force_name][tech_name] = true
    ResearchInfo.update_research_info_ui()
end

---@param force LuaForce
---@param tech_name string
function ResearchInfo.research_reversed(tech_name, force)
    if not Teams.is_active(force.name) then
        return
    end
    local tech_info = storage.research_info.completed[tech_name]
    if not tech_info then
        return
    end
    tech_info[force.name] = nil
    ResearchInfo.update_research_info_ui(true)
end

---What every active team has done with `tech_id`, keyed by force name and built
---in `Teams.all()` order -- the hand-written two-key record this replaces, with
---the two forces read in the same order.
---@param tech_id string
---@return table<string, research_info.tech_state>
local function get_research_info(tech_id)
    local tech_info = storage.research_info.completed[tech_id]

    ---@param force LuaForce
    ---@return string?, number?, boolean
    local function format(force)
        local force_name = force.name
        ---@type string?
        local result = nil
        ---@type number?
        local progress
        local active = false
        if tech_info and tech_info[force_name] then
            result = tech_info[force_name]
        else
            local current = force.current_research
            ---@type string?
            local type
            if current and current.name == tech_id then
                type = 'In progress - '
                progress = force.research_progress
                active = true
            else
                type = 'Paused - '
                progress = force.technologies[tech_id].saved_progress
            end
            if progress then
                result = type .. string_format('%.0f%% complete', progress * 100)
            end
        end
        return result, progress, active
    end

    local info = {}
    for _, team in ipairs(Teams.all()) do
        local desc, pct, active = format(game.forces[team])
        info[team] = {
            desc = desc,
            pct = pct,
            active = active,
        }
    end
    return info
end

---@param filter fun(tech_name: string, tech_info: unknown): boolean
---@return GuiElemDef[]
local function construct_completed(filter)
    ---@type GuiElemDef[]
    local elements = {}
    for tech_name, tech_info in pairs(storage.research_info.completed) do
        if filter(tech_name, tech_info) then
            local info = get_research_info(tech_name)
            elements[#elements + 1] = research_item(tech_name, info)
        end
    end
    table_sort(elements, function(a, b)
        return a.tags.sort_by < b.tags.sort_by
    end)
    if #elements == 0 then
        elements[#elements + 1] = uic.blocks.label('No results')
    end
    return elements
end

---@param force LuaForce
---@return GuiElemDef
local function construct_research_queue(force)
    local queue_data = force.research_queue
    local queue_elem = uic.blocks.hflow('queue')

    if not queue_data or #queue_data == 0 then
        uic.add(queue_elem, uic.blocks.label('Nothing queued'))
    else
        for _, tech in ipairs(queue_data) do
            local research_info = get_research_info(tech.name)
            uic.add(queue_elem, research_item(tech.name, research_info))
        end
    end
    return queue_elem
end

---@param force LuaForce
---@return GuiElemDef
local function construct_progress(force)
    local progress_info = storage.research_info.current_progress[force.name]
    local el = uic.blocks.table(15, 'progress')
    local matches = 0
    for tech_name, _ in pairs(progress_info) do
        local tech_info = get_research_info(tech_name)
        local progress = tech_info[force.name].pct
        local active = tech_info[force.name].active or false
        if progress then
            matches = matches + 1
            uic.add(el, progress_research_item(tech_name, progress, active, tech_info))
        end
    end
    if matches == 0 then
        uic.add(el, uic.blocks.label('No partially complete research'))
    end
    return el
end

---@alias research_info.ui_update_package.team { queue: GuiElemDef, progress: GuiElemDef, excl_completed: GuiElemDef[] }

---One `research_info.ui_update_package.team` per active team, keyed by force
---name, plus the bucket shared by all of them.
---@class research_info.ui_update_package
---@field both_completed GuiElemDef[]

---@param element LuaGuiElement
---@param package research_info.ui_update_package
---@param completed_technologies_changed boolean?
local function update_research_info_element(element, package, completed_technologies_changed)
    local frame_teams = element.teams
    for _, force in ipairs(Teams.all()) do
        local team_data = package[force] --[[@as research_info.ui_update_package.team]]
        local team_frame = frame_teams[force]
        -- An open window is not rebuilt by a map reset (INVENTORY 2.7), so a
        -- window from a round with other teams has no panel for this one. Both
        -- panels are always there for a two-team round.
        if team_frame and team_data then
            team_frame.queue_frame.queue.destroy()
            flui.add(team_frame.queue_frame, team_data.queue)
            team_frame.progress_frame.progress.destroy()
            flui.add(team_frame.progress_frame, team_data.progress)

            if completed_technologies_changed then
                team_frame.completed_frame.completed.clear()
                for _, v in pairs(team_data.excl_completed) do
                    flui.add(team_frame.completed_frame.completed, v)
                end
            end
        end
    end

    local both = element.both_teams
    if not both then
        return
    end

    if completed_technologies_changed then
        both.completed_frame.completed_both.clear()
        for _, v in pairs(package.both_completed) do
            flui.add(both.completed_frame.completed_both, v)
        end
    end
end

---@param player LuaPlayer
---@param element LuaGuiElement
local function update_research_info_size(player, element)
    local eff = player.display_resolution.height / player.display_scale
    element.style.maximal_height = eff - (MAXHEIGHT_PADDING * 2)
end

---@return research_info.ui_update_package
local function calculate_ui()
    local teams = Teams.all()
    ---@type research_info.ui_update_package
    local data = {}
    for _, team in ipairs(teams) do
        local force = game.forces[team]
        data[team] = {
            queue = construct_research_queue(force),
            progress = construct_progress(force),
            -- 'exclusive' = researched by this team and by no other active one;
            -- with two teams that is 'mine and not the other's', unchanged.
            excl_completed = construct_completed(function(_, info)
                if not info[team] then
                    return false
                end
                for _, other in ipairs(teams) do
                    if other ~= team and info[other] then
                        return false
                    end
                end
                return true
            end),
        }
    end
    -- The shared bucket is what every active team has researched; with two
    -- teams, `info.north and info.south` tested in that order.
    data.both_completed = construct_completed(function(_, info)
        for _, team in ipairs(teams) do
            if not info[team] then
                return false
            end
        end
        return true
    end)
    return data
end

---@param completed_technologies_changed boolean?
function ResearchInfo.update_research_info_ui(completed_technologies_changed)
    local data = calculate_ui()
    for _, player in pairs(game.connected_players) do
        if player.gui.screen['research_info_frame'] then
            update_research_info_element(
                player.gui.screen['research_info_frame'].scroll.main,
                data,
                completed_technologies_changed
            )
        end
    end
end

---@param player LuaPlayer
function ResearchInfo.show_research_info(player)
    local frame = player.gui.screen['research_info_frame']

    if frame and frame.valid then
        frame.destroy()
        return
    end

    local title = Teams.count() == 2 and 'Research summary for both teams' or 'Research summary for all teams'
    frame = closable_frame.create_main_closable_frame(player, 'research_info_frame', title)
    local scroll = frame.add({
        type = 'scroll-pane',
        horizontal_scroll_policy = 'never',
        vertical_scroll_policy = 'always',
        name = 'scroll',
    })
    local named_elements = flui.add(scroll, ui_template())
    for _, team in ipairs(Teams.all()) do
        named_elements['team_name_' .. team].caption = Functions.team_name_with_color(team)
    end
    local el = player.gui.screen['research_info_frame']
    update_research_info_size(player, el)
    local data = calculate_ui()
    -- full refresh needed to populate the UI
    update_research_info_element(el.scroll.main, data, true)
end

---@param evtd EventData.on_player_display_resolution_changed | EventData.on_player_display_scale_changed
local function on_display_changed(evtd)
    local player = game.get_player(evtd.player_index)
    if not player then
        return
    end
    local el = player.gui.screen['research_info_frame']
    if not el then
        return
    end
    update_research_info_size(player, el)
    el.force_auto_center()
end

Event.add(defines.events.on_player_display_resolution_changed, on_display_changed)
Event.add(defines.events.on_player_display_scale_changed, on_display_changed)

return ResearchInfo
