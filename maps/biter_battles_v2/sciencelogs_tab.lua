-- science logs tab --

local Tabs = require('comfy_panel.main')
local tables = require('maps.biter_battles_v2.tables')
local Functions = require('maps.biter_battles_v2.functions')
local Model = require('maps.biter_battles_v2.sciencelogs_model')
local Teams = require('maps.biter_battles_v2.teams')
local event = require('utils.event')
local bb_config = require('maps.biter_battles_v2.config')
local food_values = tables.food_values
local food_long_and_short = tables.food_long_and_short
local food_long_to_short = tables.food_long_to_short
local forces_list = tables.forces_list
local science_list = tables.science_list
local evofilter_list = tables.evofilter_list
local food_value_table_version = tables.food_value_table_version

local function initialize_dropdown_users_choice()
    storage.dropdown_users_choice_force = {}
    storage.dropdown_users_choice_science = {}
    storage.dropdown_users_choice_evo_filter = {}
end

local function get_science_text(food_name, food_short_name)
    return table.concat({
        '[img=item/',
        food_name,
        '][color=',
        food_values[food_name].color,
        ']',
        food_short_name,
        '[/color]',
    })
end

---Today's summary block, and the only one a two-team round ever draws: one
---table per team of the round, the heading naming the force and seven cells of
---running totals beside it, a line under each. Every element, name, caption and
---width here is what it has always been -- the loop, which at
---two teams hands out north and then south and builds exactly the two rows the
---tab has always had, the south row's missing underscore included.
---@param science_scrollpanel LuaGuiElement
---@param teams string[]
---@param column_widths integer[]
---@param width_summary_first_column integer
---@param width_summary_columns integer
local function draw_legacy_summary_rows(
    science_scrollpanel,
    teams,
    column_widths,
    width_summary_first_column,
    width_summary_columns
)
    for team_index, team in ipairs(teams) do
        local totals = storage['science_logs_total_' .. team] or {}
        local summary_panel_table = science_scrollpanel.add({ type = 'table', column_count = #column_widths })
        local label = summary_panel_table.add({
            type = 'label',
            name = 'science_logs_total_' .. team .. '_header',
            caption = 'Total sent by ' .. team,
        })
        label.style.minimal_width = width_summary_first_column
        label.style.maximal_width = width_summary_first_column
        -- The south row has never put an underscore between the team and the
        -- column index in its element names, unlike the north row above it
        -- (INVENTORY defect). Keeping today's names to the byte means keeping
        -- that: the first row separates, the rows below it do not.
        local cell_prefix = 'science_logs_total_' .. team .. (team_index == 1 and '_' or '')
        for i = 1, #food_long_and_short do
            local label = summary_panel_table.add({
                type = 'label',
                name = cell_prefix .. i,
                caption = totals[i],
            })
            label.style.minimal_width = width_summary_columns
            label.style.maximal_width = width_summary_columns
        end
        science_scrollpanel.add({ type = 'line' })
    end
end

---The same block above two teams, from `Model.columns()`: the same tables, the
---same element names and the same seven cells, with the heading the round's
---display name in the team's colour -- greyed for a team that is out, which
---keeps its row -- because a compass name is not what the four-square map calls
---that team anywhere else. The heading wraps inside today's 110 px rather than
---widening the block, so the summary keeps its width and the panel keeps its
---scrollbars.
---@param science_scrollpanel LuaGuiElement
---@param column_widths integer[]
---@param width_summary_first_column integer
---@param width_summary_columns integer
local function draw_team_summary_rows(
    science_scrollpanel,
    column_widths,
    width_summary_first_column,
    width_summary_columns
)
    for _, column in ipairs(Model.columns()) do
        local totals = storage[column.key] or {}
        local summary_panel_table = science_scrollpanel.add({ type = 'table', column_count = #column_widths })
        local label = summary_panel_table.add({
            type = 'label',
            name = column.header_name,
            caption = column.caption,
        })
        label.style.minimal_width = width_summary_first_column
        label.style.maximal_width = width_summary_first_column
        label.style.single_line = false
        label.style.font_color = column.color
        for i = 1, #food_long_and_short do
            local label = summary_panel_table.add({
                type = 'label',
                name = column.cell_prefix .. i,
                caption = totals[i],
            })
            label.style.minimal_width = width_summary_columns
            label.style.maximal_width = width_summary_columns
        end
        science_scrollpanel.add({ type = 'line' })
    end
end

---@param player LuaPlayer
---@param element LuaGuiElement
local function add_science_logs(player, element)
    local science_scrollpanel = element.add({
        type = 'scroll-pane',
        name = 'scroll_pane',
        direction = 'vertical',
        horizontal_scroll_policy = 'never',
        vertical_scroll_policy = 'auto',
    })
    science_scrollpanel.style.maximal_height = 530

    if storage.science_logs_category_potion == nil then
        storage.science_logs_category_potion = {}
        for i = 1, #food_long_and_short do
            table.insert(
                storage.science_logs_category_potion,
                get_science_text(food_long_and_short[i].long_name, food_long_and_short[i].short_name)
            )
        end
    end
    -- One array per active team under today's key name. The gate is still the
    -- first team's array, and the arrays are still one entry longer than
    -- `feeding.lua` makes them (INVENTORY defect, generalised, not fixed).
    local teams = Teams.all()
    -- Today's tab is the two-team tab: every multi-team branch keeps it
    -- verbatim, and this is the only thing that turns the others on. Read once,
    -- so the summary block and the force filter cannot disagree about it.
    local two_teams = Teams.count() == 2
    if storage['science_logs_total_' .. teams[1]] == nil then
        for _, team in ipairs(teams) do
            local key = 'science_logs_total_' .. team
            storage[key] = { 0 }
            for _ = 1, #food_long_and_short do
                table.insert(storage[key], 0)
            end
        end
    end

    local width_summary_columns = tonumber(94)
    local width_summary_first_column = tonumber(110)
    local column_widths = { width_summary_first_column }
    for i = 1, #food_long_and_short do
        column_widths[#column_widths + 1] = width_summary_columns
    end

    local t_summary = science_scrollpanel.add({
        type = 'table',
        name = 'science_logs_summary_header_table',
        column_count = #column_widths,
    })
    local headersSummary = { '', table.unpack(storage.science_logs_category_potion) }
    for _, w in ipairs(column_widths) do
        local label = t_summary.add({ type = 'label', caption = headersSummary[_] })
        label.style.minimal_width = w
        label.style.maximal_width = w
    end

    if two_teams then
        draw_legacy_summary_rows(
            science_scrollpanel,
            teams,
            column_widths,
            width_summary_first_column,
            width_summary_columns
        )
    else
        draw_team_summary_rows(science_scrollpanel, column_widths, width_summary_first_column, width_summary_columns)
    end

    local summary_panel_table3 = science_scrollpanel.add({ type = 'table', column_count = #column_widths })
    local label = summary_panel_table3.add({
        type = 'label',
        name = 'science_logs_total_passive_feed_header',
        caption = 'Total passive feed',
    })
    label.style.minimal_width = width_summary_first_column
    label.style.maximal_width = width_summary_first_column
    for i = 1, #food_long_and_short do
        local text_passive_feed = '0'
        if storage.total_passive_feed_redpotion ~= nil then
            text_passive_feed = math.round(
                storage.total_passive_feed_redpotion * food_value_table_version[1] / food_value_table_version[i],
                1
            )
        end
        local label = summary_panel_table3.add({
            type = 'label',
            name = 'science_logs_passive_feed' .. i,
            caption = text_passive_feed,
        })
        label.style.minimal_width = width_summary_columns
        label.style.maximal_width = width_summary_columns
    end
    science_scrollpanel.add({ type = 'line' })

    if storage.dropdown_users_choice_force == nil then
        initialize_dropdown_users_choice()
    end
    if storage.dropdown_users_choice_force[player.name] == nil then
        storage.dropdown_users_choice_force[player.name] = 1
    end
    if storage.dropdown_users_choice_science[player.name] == nil then
        storage.dropdown_users_choice_science[player.name] = 1
    end
    if storage.dropdown_users_choice_evo_filter[player.name] == nil then
        storage.dropdown_users_choice_evo_filter[player.name] = 1
    end

    local t_filter = science_scrollpanel.add({ type = 'table', name = 'science_logs_filter_table', column_count = 3 })

    -- The registry's 'all teams' entry kept first -- index 1 means "no filter"
    -- at the bottom of this function -- then one entry per active team, which
    -- for two teams is `Tables.forces_list` itself
    -- (tests/test-sciencelogs-multiteam.lua pins that against the registry).
    local force_filter_items = Model.force_filter_items(forces_list[1])
    -- A choice survives a map reset, so a round with fewer teams can inherit an
    -- index that no longer exists; that would be a hard error on `add`.
    local force_choice = storage.dropdown_users_choice_force[player.name]
    if force_choice > #force_filter_items then
        force_choice = 1
        storage.dropdown_users_choice_force[player.name] = force_choice
    end

    local dropdown_force = t_filter.add({
        name = 'dropdown-force',
        type = 'drop-down',
        items = force_filter_items,
        selected_index = force_choice,
    })
    local dropdown_science = t_filter.add({
        name = 'dropdown-science',
        type = 'drop-down',
        items = science_list,
        selected_index = storage.dropdown_users_choice_science[player.name],
    })
    local dropdown_evofilter = t_filter.add({
        name = 'dropdown-evofilter',
        type = 'drop-down',
        items = evofilter_list,
        selected_index = storage.dropdown_users_choice_evo_filter[player.name],
    })

    local t = science_scrollpanel.add({ type = 'table', name = 'science_logs_header_table', column_count = 4 })
    local column_widths = { tonumber(75), tonumber(310), tonumber(165), tonumber(230) }
    local headers = {
        [1] = 'Time',
        [2] = 'Details',
        [3] = 'Evo jump',
        [4] = 'Threat jump',
    }
    for _, w in ipairs(column_widths) do
        local label = t.add({ type = 'label', caption = headers[_] })
        label.style.minimal_width = w
        label.style.maximal_width = w
        label.style.font = 'default-bold'
        label.style.font_color = { r = 0.98, g = 0.66, b = 0.22 }
        if _ == 1 then
            label.style.horizontal_align = 'center'
        end
    end

    -- The team the force filter is set to above two teams, nil when it is on
    -- 'all teams'. The entry is a display name there, which is neither a Lua
    -- pattern nor necessarily unique, so the row is matched against the team
    -- the entry stands for instead of against its text; two teams keep today's
    -- entries and today's text match, below, to the byte.
    local force_filter = Model.filtered_team(dropdown_force.selected_index)

    if storage.science_logs_text then
        for i = 1, #storage.science_logs_date, 1 do
            local real_force_name = storage.science_logs_fed_team[i]
            local custom_force_name = Functions.team_name_with_color(real_force_name)
            local easy_food_name = food_long_to_short[storage.science_logs_food_name[i]].short_name

            local force_match
            if two_teams then
                force_match = dropdown_force.selected_index == 1
                    or real_force_name:match(dropdown_force.get_item(dropdown_force.selected_index))
            else
                force_match = force_filter == nil or real_force_name == force_filter
            end
            if force_match then
                if
                    dropdown_science.selected_index == 1
                    or (dropdown_science.selected_index == 2 and (easy_food_name:match('space') or easy_food_name:match(
                        'utility'
                    ) or easy_food_name:match('production')))
                    or (dropdown_science.selected_index == 3 and (easy_food_name:match('space') or easy_food_name:match(
                        'utility'
                    ) or easy_food_name:match('production') or easy_food_name:match('chemical')))
                    or (dropdown_science.selected_index == 4 and (easy_food_name:match('space') or easy_food_name:match(
                        'utility'
                    ) or easy_food_name:match('production') or easy_food_name:match('chemical') or easy_food_name:match(
                        'military'
                    )))
                    or easy_food_name:match(dropdown_science.get_item(dropdown_science.selected_index))
                then
                    if
                        dropdown_evofilter.selected_index == 1
                        or (dropdown_evofilter.selected_index == 2 and (storage.science_logs_evo_jump_difference[i] > 0))
                        or (dropdown_evofilter.selected_index == 3 and (storage.science_logs_evo_jump_difference[i] >= 10))
                        or (dropdown_evofilter.selected_index == 4 and (storage.science_logs_evo_jump_difference[i] >= 5))
                        or (dropdown_evofilter.selected_index == 5 and (storage.science_logs_evo_jump_difference[i] >= 4))
                        or (dropdown_evofilter.selected_index == 6 and (storage.science_logs_evo_jump_difference[i] >= 3))
                        or (dropdown_evofilter.selected_index == 7 and (storage.science_logs_evo_jump_difference[i] >= 2))
                        or (
                            dropdown_evofilter.selected_index == 8
                            and (storage.science_logs_evo_jump_difference[i] >= 1)
                        )
                    then
                        science_panel_table = science_scrollpanel.add({ type = 'table', column_count = 4 })
                        local label = science_panel_table.add({
                            type = 'label',
                            name = 'science_logs_date' .. i,
                            caption = storage.science_logs_date[i],
                        })
                        label.style.minimal_width = column_widths[1]
                        label.style.maximal_width = column_widths[1]
                        label.style.horizontal_align = 'center'
                        local label = science_panel_table.add({
                            type = 'label',
                            name = 'science_logs_text' .. i,
                            caption = storage.science_logs_text[i] .. custom_force_name,
                        })
                        label.style.minimal_width = column_widths[2]
                        label.style.maximal_width = column_widths[2]
                        local label = science_panel_table.add({
                            type = 'label',
                            name = 'science_logs_evo_jump' .. i,
                            caption = storage.science_logs_evo_jump[i]
                                .. '   [color=200,200,200](+'
                                .. storage.science_logs_evo_jump_difference[i]
                                .. ')[/color]',
                        })
                        label.style.minimal_width = column_widths[3]
                        label.style.maximal_width = column_widths[3]
                        local label = science_panel_table.add({
                            type = 'label',
                            name = 'science_logs_threat' .. i,
                            caption = storage.science_logs_threat[i]
                                .. '   [color=200,200,200](+'
                                .. storage.science_logs_threat_jump_difference[i]
                                .. ')[/color]',
                        })
                        label.style.minimal_width = column_widths[4]
                        label.style.maximal_width = column_widths[4]
                        science_scrollpanel.add({ type = 'line' })
                    end
                end
            end
        end
    end
end

local build_config_gui = function(player)
    local frame_sciencelogs = Tabs.comfy_panel_get_active_frame(player)
    if not frame_sciencelogs then
        return
    end
    frame_sciencelogs.clear()
    add_science_logs(player, frame_sciencelogs)
end

local function on_gui_selection_state_changed(event)
    local player = game.get_player(event.player_index)
    if not event.element.valid then
        return
    end
    local name = event.element.name
    if storage.dropdown_users_choice_force == nil then
        initialize_dropdown_users_choice()
    end
    if name == 'dropdown-force' then
        storage.dropdown_users_choice_force[player.name] = event.element.selected_index
        build_config_gui(player)
    end
    if name == 'dropdown-science' then
        storage.dropdown_users_choice_science[player.name] = event.element.selected_index
        build_config_gui(player)
    end
    if name == 'dropdown-evofilter' then
        storage.dropdown_users_choice_evo_filter[player.name] = event.element.selected_index
        build_config_gui(player)
    end
end

event.add(defines.events.on_gui_selection_state_changed, on_gui_selection_state_changed)

comfy_panel_tabs['MutagenLog'] = { gui = build_config_gui, admin = false }
