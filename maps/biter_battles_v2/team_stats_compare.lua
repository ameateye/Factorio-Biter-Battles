local gui_style = require('utils.utils').gui_style
local Functions = require('maps.biter_battles_v2.functions')
local Tables = require('maps.biter_battles_v2.tables')
local Teams = require('maps.biter_battles_v2.teams')
local closable_frame = require('utils.ui.closable_frame')
local TeamStatsCollect = require('maps.biter_battles_v2.team_stats_collect')
local safe_wrap_with_player_print = require('utils.utils').safe_wrap_with_player_print
local safe_wrap_cmd = require('utils.utils').safe_wrap_cmd
local Event = require('utils.event')
local Report = require('maps.biter_battles_v2.game_over_report')

local math_floor = math.floor
local math_max = math.max
local string_format = string.format

local TeamStatsCompare = {}

---The ranking and the titles of the round that has just ended, above two teams
---and once it has a winner; nil otherwise -- a two-team round has neither a
---placement to show nor a layout that could rename its teams.
---@return { placement: string[], names: table<string, string> }|nil
local function live_standings()
    if Teams.count() <= 2 or not storage.bb_game_won_by_team then
        return nil
    end
    return Report.standings(Teams.all(), storage.bb_placement, function(team)
        return Teams.display_name(team)
    end)
end

---A title inside its team's colour tag, as `Teams.name_with_color` writes it.
---@param team string
---@param title string
---@return string
local function colored_title(team, title)
    local color = Teams.text_color(team)
    if not color then
        return title
    end
    return '[color=' .. color .. ']' .. title .. '[/color]'
end

---What a force with no record in `stats.forces` renders as. Five sites read
---that table without a guard today; a snapshot from another round, or a team
---the collector has never written, would nil-index them. `total_players` and
---`max_players` are in it because their call site formats them with `%d` and
---has no fallback of its own. Read-only: nothing here writes into a force's
---record.
---@type ForceStats
local EMPTY_FORCE_STATS = {
    items = {},
    food = {},
    damage_types = {},
    total_players = 0,
    max_players = 0,
}

---@alias TeamstatsPreferences {show_hidden: boolean?, show_fluids: boolean?, show_prev: boolean?}

---@param player LuaPlayer
---@return TeamstatsPreferences
local function get_preferences(player)
    local res = storage.teamstats_preferences[player.name]
    if not res then
        res = {}
        storage.teamstats_preferences[player.name] = res
    end
    return res
end

---@param parent LuaGuiElement
---@param a LuaGuiElement.add_param
---@return LuaGuiElement
local function add_small_label(parent, a)
    a.type = 'label'
    local l = parent.add(a)
    l.style.font = 'default-small'
    return l
end

local function ticks_to_hh_mm(ticks)
    local total_minutes = math_floor(ticks / (60 * 60))
    local total_hours = math_floor(total_minutes / 60)
    local minutes = total_minutes - (total_hours * 60)
    return string_format('%02d:%02d', total_hours, minutes)
end

---@param num number?
---@return string
local function format_with_thousands_sep(num)
    num = math_floor(num or 0)
    local str = tostring(num)
    local reversed = str:reverse()
    local formatted_reversed = reversed:gsub('(%d%d%d)', '%1,')
    return (formatted_reversed:reverse():gsub('^,', ''))
end

---@param num number
---@return string
local function format_one_sig_fig(num)
    if num < 0.1 then
        return string_format('%.2f', num)
    elseif num < 1 then
        return string_format('%.1f', num)
    else
        return format_with_thousands_sep(num)
    end
end

---@param player LuaPlayer
function TeamStatsCompare.show_stats(player)
    local preferences = get_preferences(player)
    local show_hidden = preferences.show_hidden and true or false
    local show_fluids = preferences.show_fluids and true or false
    local show_prev = preferences.show_prev and true or false
    ---@type table<string, boolean>
    local exclude_forces = {}
    ---@type TeamStats
    local stats
    if not storage.prev_game_team_stats then
        show_prev = false
    end
    ---@param force_names string[]
    local function exclude(force_names)
        for _, force_name in ipairs(force_names) do
            exclude_forces[force_name] = true
        end
    end
    if show_prev then
        stats = storage.prev_game_team_stats
    else
        stats = TeamStatsCollect.compute_stats()
        -- allow it always in single player, or if the game is over
        -- "The other team" of today, which above two teams is every active team
        -- but the player's own; empty when they have no team of their own,
        -- which is the case the last branch below falls back for.
        local own_force = storage.chosen_team[player.name]
        local other_forces = {}
        if Teams.is_active(own_force) then
            for _, force_name in ipairs(Teams.all()) do
                if force_name ~= own_force then
                    other_forces[#other_forces + 1] = force_name
                end
            end
        end
        if not storage.bb_game_won_by_team then
            if storage.allow_teamstats == 'spectator' then
                if other_forces[1] and player.force.name ~= 'spectator' then
                    exclude(other_forces)
                end
            elseif storage.allow_teamstats == 'pure-spectator' then
                if other_forces[1] then
                    exclude(other_forces)
                end
            elseif storage.allow_teamstats ~= 'always' then
                if other_forces[1] then
                    exclude(other_forces)
                else
                    exclude(Teams.all())
                end
            end
        end
    end

    -- Which forces get a column, in order. A live snapshot describes this
    -- round; `prev_game_team_stats` survives resets and may describe a round
    -- with another team count, so it is rendered from its own keys: this
    -- round's teams first in ring order, then whatever else it holds, sorted so
    -- that every client draws the same columns in the same order.
    local render_forces = {}
    for _, force_name in ipairs(Teams.all()) do
        if not show_prev or stats.forces[force_name] then
            render_forces[#render_forces + 1] = force_name
        end
    end
    if show_prev then
        local extra = {}
        for force_name in pairs(stats.forces) do
            if not Teams.is_active(force_name) then
                extra[#extra + 1] = force_name
            end
        end
        table.sort(extra)
        for _, force_name in ipairs(extra) do
            render_forces[#render_forces + 1] = force_name
        end
    end
    -- Above two teams: the ranking and the titles the view names teams by. The
    -- previous game's were kept when it ended (a previous two-team game kept
    -- none); the current game's exist once it has a winner.
    local standings
    if show_prev then
        standings = storage.prev_game_team_standings
    else
        standings = live_standings()
    end
    ---A column's heading: the title the round gave the team. A previous game
    ---with no standings was a two-team game, and on a four-square round today
    ---its 'north' is named as the two-team map named it, not 'Top Left'.
    ---@param force_name string
    ---@return string
    local function team_caption(force_name)
        local title = standings and standings.names[force_name]
        if title then
            return colored_title(force_name, title)
        end
        if show_prev and Teams.count() > 2 then
            return colored_title(force_name, Teams.display_name(force_name, 'horizontal2'))
        end
        return Functions.team_name_with_color(force_name)
    end

    -- Today's layout -- the three-column top table and the two-column body --
    -- is kept exactly for a two-team round described by a two-team snapshot.
    local two_team_layout = Teams.count() == 2 and #render_forces == 2
    local column_count = math_max(#render_forces, 1)

    ---@param force_name string
    ---@return ForceStats
    local function force_stats_of(force_name)
        return stats.forces[force_name] or EMPTY_FORCE_STATS
    end

    ---The paddings of one per-team grid. Two teams get today's numbers to the
    ---pixel. Above two teams the cells are packed instead: four columns of the
    ---loose grid are ~1400 px (screenshot gui4-before/03-team-stats.png, taken
    ---on a 1600 px screen) and would run off a 1366 px one, and most of that
    ---width is spacing, not text.
    ---@param element LuaGuiElement
    local function pack_grid(element)
        if two_team_layout then
            gui_style(element, { left_cell_padding = 3, right_cell_padding = 3, vertical_spacing = 0 })
        else
            gui_style(element, {
                left_cell_padding = 1,
                right_cell_padding = 1,
                horizontal_spacing = 2,
                vertical_spacing = 0,
            })
        end
    end

    ---@type LuaGuiElement
    local frame = player.gui.screen['teamstats_frame']
    if frame then
        frame.destroy()
    end
    frame = closable_frame.create_main_closable_frame(player, 'teamstats_frame', 'Team statistics')
    gui_style(frame, { padding = two_team_layout and 8 or 4 })
    local scrollpanel = frame.add({
        type = 'scroll-pane',
        name = 'scroll_pane',
        direction = 'vertical',
        -- The horizontal axis is the last resort, and only above two teams: the
        -- packed grid fits four columns in ~1150 px, but a fifth food, a long
        -- custom team name or a bigger UI scale must scroll inside the window
        -- rather than push the window off the screen.
        horizontal_scroll_policy = two_team_layout and 'never' or 'auto',
        vertical_scroll_policy = 'auto',
    })
    if not two_team_layout then
        -- Client-local, and written into this player's own element only -- the
        -- same lane as research_info.lua's `update_research_info_size`. It caps
        -- the window at what this player's screen can show; nothing shared is
        -- read or written, so peers stay in step.
        local eff_width = player.display_resolution.width / player.display_scale
        gui_style(scrollpanel, { maximal_width = math_max(eff_width - 80, 320) })
    end

    ---@param force_name string
    ---@param top_table LuaGuiElement
    local function add_simple_force_stats(force_name, top_table)
        --- @type ForceStats
        local force_stats = force_stats_of(force_name)
        local team_frame = top_table.add({ type = 'frame', name = 'summary_' .. force_name, direction = 'vertical' })
        gui_style(team_frame, { padding = two_team_layout and 8 or 4 })
        local team_label = team_frame.add({ type = 'label', caption = team_caption(force_name) })
        gui_style(team_label, { font = 'heading-2', single_line = false, maximal_width = 150 })
        local simple_stats = {
            { 'Final evo:', string_format('%d%%', (force_stats.final_evo or 0) * 100) },
            { 'Peak threat:', threat_to_pretty_string(force_stats.peak_threat or 0) },
            { 'Lowest threat:', threat_to_pretty_string(force_stats.lowest_threat or 0) },
        }
        if stats.ticks and stats.ticks > 0 then
            table.insert(simple_stats, {
                'Average players:',
                string_format('%.1f [img=info]', (force_stats.player_ticks or 0) / (stats.ticks or 1)),
                string_format(
                    'Total players: %d, Max players: %d',
                    force_stats.total_players or 0,
                    force_stats.max_players or 0
                ),
            })
        end
        local top_simple_table = team_frame.add({ type = 'table', name = 'top_simple_table', column_count = 2 })
        for _, stat in ipairs(simple_stats) do
            top_simple_table.add({ type = 'label', caption = stat[1] })
            top_simple_table.add({ type = 'label', caption = stat[2], tooltip = stat[3] })
        end
    end
    ---The panel between the teams: difficulty, duration and, once there is one,
    ---the winner. Sits in the middle column of the two-team table and last of
    ---all above two teams.
    ---@param top_table LuaGuiElement
    local function add_shared_stats(top_table)
        local shared_frame = top_table.add({ type = 'frame', name = 'summary_shared', direction = 'vertical' })
        local centering_table = shared_frame.add({ type = 'table', name = 'centering_table', column_count = 1 })
        centering_table.style.column_alignments[1] = 'center'
        add_small_label(centering_table, {
            caption = string_format(
                'Difficulty: %s (%d%%)',
                (stats.difficulty or ''),
                (stats.difficulty_value or 0) * 100
            ),
        })
        add_small_label(centering_table, { caption = string_format('Duration: %s', ticks_to_hh_mm(stats.ticks or 0)) })
        if stats.won_by_team then
            -- The force name with its first letter capitalised: 'North' and
            -- 'South' to the byte, as the two-branch ternary this replaces.
            -- Above two teams the winner is named as everywhere else on that
            -- map ('Top Left'), seen wrong in the client on 2026-09-20.
            -- The places below it follow the winner above two teams, in the
            -- titles the round used (a previous game keeps its own).
            local winner = stats.won_by_team
            local winner_caption = winner:sub(1, 1):upper() .. winner:sub(2)
            if standings then
                winner_caption = standings.names[winner] or winner_caption
            elseif not show_prev and Teams.count() > 2 and Teams.is_team(winner) then
                winner_caption = Teams.display_name(winner)
            end
            add_small_label(centering_table, {
                caption = string_format('Winner: %s', winner_caption),
            })
            if standings then
                local titles = {}
                for i, team in ipairs(standings.placement) do
                    titles[i] = standings.names[team] or team
                end
                for _, line in ipairs(Report.standings_lines(titles)) do
                    add_small_label(centering_table, { caption = line })
                end
            end
        end
    end
    local top_centering_table = scrollpanel.add({ type = 'table', name = 'top_centering_table', column_count = 1 })
    top_centering_table.style.column_alignments[1] = 'center'
    local space_sci_mutagen = Tables.food_values['space-science-pack'].value
    if two_team_layout then
        local top_table =
            top_centering_table.add({ type = 'table', name = 'top_table', column_count = 3, vertical_centering = true })
        top_table.style.column_alignments[1] = 'right'
        top_table.style.column_alignments[2] = 'center'
        top_table.style.column_alignments[3] = 'left'
        add_simple_force_stats(render_forces[1], top_table)
        add_shared_stats(top_table)
        add_simple_force_stats(render_forces[2], top_table)
    else
        local top_table = top_centering_table.add({
            type = 'table',
            name = 'top_table',
            column_count = column_count + 1,
            vertical_centering = true,
        })
        for _, force_name in ipairs(render_forces) do
            add_simple_force_stats(force_name, top_table)
        end
        add_shared_stats(top_table)
    end

    local two_table = top_centering_table.add({
        type = 'table',
        name = 'two_table',
        column_count = column_count,
        vertical_centering = true,
    })
    two_table.style.column_alignments[1] = 'right'
    if two_team_layout then
        two_table.style.left_cell_padding = 4
        two_table.style.right_cell_padding = 4
    else
        two_table.style.left_cell_padding = 2
        two_table.style.right_cell_padding = 2
        two_table.style.horizontal_spacing = 4
    end
    for _, force_name in ipairs(render_forces) do
        local science_flow =
            two_table.add({ type = 'flow', name = 'science_flow_' .. force_name, direction = 'vertical' })
        gui_style(science_flow, { horizontal_align = 'center' })
        local cols = {
            { '' },
            { 'First [img=info]', 'The time that the first item was produced.' },
            { 'Produced' },
            { 'Consumed' },
            { 'Sent' },
        }
        local science_table = science_flow.add({ type = 'table', name = 'science_table', column_count = #cols })
        pack_grid(science_table)
        for idx, col_info in ipairs(cols) do
            science_table.style.column_alignments[idx] = 'right'
            add_small_label(science_table, { caption = col_info[1], tooltip = col_info[2] })
        end
        local total_sent_mutagen = 0
        local total_produced_mutagen = 0
        for _, food in ipairs(Tables.food_long_and_short) do
            local force_stats = force_stats_of(force_name)
            local food_stats = force_stats.food[food.long_name] or {}
            local food_mutagen = Tables.food_values[food.long_name].value
            local produced = food_stats.produced or 0
            local consumed = food_stats.consumed or 0
            local sent = food_stats.sent or 0
            add_small_label(science_table, { caption = string_format('[item=%s]', food.long_name) })
            add_small_label(
                science_table,
                { caption = (food_stats.first_at and ticks_to_hh_mm(food_stats.first_at) or '') }
            )
            if not exclude_forces[force_name] then
                add_small_label(science_table, {
                    caption = format_with_thousands_sep(produced),
                    tooltip = '[item=space-science-pack] equivalent: '
                        .. format_one_sig_fig(produced * food_mutagen / space_sci_mutagen),
                })
                add_small_label(science_table, {
                    caption = format_with_thousands_sep(consumed),
                    tooltip = '[item=space-science-pack] equivalent: '
                        .. format_one_sig_fig(consumed * food_mutagen / space_sci_mutagen),
                })
            else
                add_small_label(science_table, { caption = '' })
                add_small_label(science_table, { caption = '' })
            end
            add_small_label(science_table, {
                caption = format_with_thousands_sep(sent),
                tooltip = '[item=space-science-pack] equivalent: '
                    .. format_one_sig_fig(sent * food_mutagen / space_sci_mutagen),
            })
            total_sent_mutagen = total_sent_mutagen + (food_stats.sent or 0) * food_mutagen
            total_produced_mutagen = total_produced_mutagen + (food_stats.produced or 0) * food_mutagen
        end
        local produced_info = ''
        if not exclude_forces[force_name] then
            produced_info =
                string_format(' produced: %s', format_one_sig_fig(total_produced_mutagen / space_sci_mutagen))
        end
        add_small_label(science_flow, {
            caption = string_format(
                '[item=space-science-pack] equivalent%s sent: %s',
                produced_info,
                format_one_sig_fig(total_sent_mutagen / space_sci_mutagen)
            ),
        })
    end

    -- One separator per column, so the grid stays aligned: the pair of today.
    for _ = 1, column_count do
        two_table.add({ type = 'line' })
    end
    for _, force_name in ipairs(render_forces) do
        local force_stats = force_stats_of(force_name)
        local cols = {
            { '[img=info]', 'Hover over icons for full details' },
            { 'First [img=info]', 'The time that the first item was produced.' },
            { 'Produced' },
            { 'Placed [img=info]', 'The highest value of (constructed-deconstructed) over time.' },
            { 'Lost' },
        }
        if show_hidden then
            table.insert(cols, 4, {
                'Buffered [img=info]',
                'Produced - Consumed - Placed - Lost. This can double-count placed+lost, so might be too low.',
            })
        end
        local item_table = two_table.add({
            type = 'table',
            name = 'item_table_' .. force_name,
            column_count = #cols,
            vertical_centering = false,
        })
        pack_grid(item_table)
        if not exclude_forces[force_name] then
            for idx, col_info in ipairs(cols) do
                item_table.style.column_alignments[idx] = 'right'
                add_small_label(item_table, { caption = col_info[1], tooltip = col_info[2] })
            end
        end

        for _, item_info in ipairs(TeamStatsCollect.items_to_show_summaries_of) do
            if
                not exclude_forces[force_name]
                and (show_hidden or not item_info.hide_by_default)
                and (show_fluids or not item_info.fluid)
            then
                local item_stats = force_stats.items[item_info.item] or {}
                ---@type number?
                local killed_or_lost = (item_stats.kill_count or 0) + (item_stats.lost or 0)
                if killed_or_lost == 0 then
                    killed_or_lost = nil
                end
                local buffered = math_max(
                    0,
                    (item_stats.produced or 0)
                        - (item_stats.consumed or 0)
                        - (item_stats.placed or 0)
                        - (item_stats.lost or 0)
                )
                local tooltip = string_format(
                    'Produced: %s, Consumed: %s, Lost: %s, Buffered: %s',
                    format_with_thousands_sep(item_stats.produced or 0),
                    format_with_thousands_sep(item_stats.consumed or 0),
                    format_with_thousands_sep(item_stats.lost or 0),
                    format_with_thousands_sep(buffered)
                )
                local fmt = '[item=%s]'
                if item_info.fluid then
                    fmt = '[fluid=%s]'
                end

                local l =
                    add_small_label(item_table, { caption = string_format(fmt, item_info.item), tooltip = tooltip })
                if item_info.space_after then
                    l.style.bottom_padding = 12
                end
                add_small_label(
                    item_table,
                    { caption = (item_stats.first_at and ticks_to_hh_mm(item_stats.first_at) or '') }
                )
                add_small_label(item_table, { caption = format_with_thousands_sep(item_stats.produced or 0) })
                if show_hidden then
                    add_small_label(item_table, { caption = format_with_thousands_sep(buffered) })
                end
                add_small_label(
                    item_table,
                    { caption = item_stats.placed and format_with_thousands_sep(item_stats.placed) or '' }
                )
                add_small_label(
                    item_table,
                    { caption = killed_or_lost and format_with_thousands_sep(killed_or_lost) or '' }
                )
            end
        end
    end

    local damage_types_to_render = {}
    local show_damage_table = false
    for _, force_name in ipairs(render_forces) do
        local force_stats = force_stats_of(force_name)
        for damage_name, damage_info in pairs(force_stats.damage_types) do
            if (damage_info.damage or 0) > 0 then
                damage_types_to_render[damage_name] = true
                show_damage_table = true
            end
        end
    end

    if show_damage_table then
        for _ = 1, column_count do
            two_table.add({ type = 'line' })
        end
        for _, force_name in ipairs(render_forces) do
            local cols = {
                { '' },
                { 'Kills' },
                { 'Damage [img=info]', 'Approximate total damage.' },
            }
            local damage_table =
                two_table.add({ type = 'table', name = 'damage_table_' .. force_name, column_count = #cols })
            pack_grid(damage_table)
            for idx, col_info in ipairs(cols) do
                if idx > 1 then
                    damage_table.style.column_alignments[idx] = 'right'
                end
                add_small_label(damage_table, { caption = col_info[1], tooltip = col_info[2] })
            end

            local force_stats = force_stats_of(force_name)
            local total_kills = 0
            local total_damage = 0
            for _, damage_render_info in ipairs(TeamStatsCollect.damage_render_info) do
                if damage_types_to_render[damage_render_info[1]] then
                    local damage_info = force_stats.damage_types[damage_render_info[1]] or {}
                    total_kills = total_kills + (damage_info.kills or 0)
                    total_damage = total_damage + (damage_info.damage or 0)
                    add_small_label(damage_table, { caption = damage_render_info[2], tooltip = damage_render_info[3] })
                    add_small_label(damage_table, { caption = format_with_thousands_sep(damage_info.kills or 0) })
                    add_small_label(damage_table, { caption = format_with_thousands_sep(damage_info.damage or 0) })
                end
            end
            add_small_label(damage_table, { caption = 'Total' })
            add_small_label(damage_table, { caption = format_with_thousands_sep(total_kills) })
            add_small_label(damage_table, { caption = format_with_thousands_sep(total_damage) })
        end
    end
    top_centering_table.add({ type = 'line' })
    local checkbox_flow = top_centering_table.add({ type = 'flow', name = 'checkbox_flow', direction = 'horizontal' })
    checkbox_flow.add({
        type = 'checkbox',
        name = 'teamstats_show_hidden',
        caption = 'Show more',
        state = show_hidden,
    })
    checkbox_flow.add({
        type = 'checkbox',
        name = 'teamstats_show_fluids',
        caption = 'Show fluids',
        state = show_fluids,
    })
    checkbox_flow.add({
        type = 'checkbox',
        name = 'teamstats_show_prev',
        caption = 'Show previous game',
        state = show_prev,
    })
end

function TeamStatsCompare.game_over()
    for _, player in pairs(game.connected_players) do
        safe_wrap_with_player_print(player, TeamStatsCompare.show_stats, player)
    end
    storage.prev_game_team_stats = storage.team_stats
    -- Kept beside the snapshot above, not inside it: `storage.team_stats` is
    -- logged as `[TEAMSTATS-FINAL]` right after this. nil for a two-team game,
    -- which writes no key and clears the one a previous game may have left.
    storage.prev_game_team_standings = live_standings()
end

function TeamStatsCompare.toggle_team_stats(player)
    local frame = player.gui.screen.teamstats_frame

    if frame and frame.valid then
        frame.destroy()
        return
    end

    TeamStatsCompare.show_stats(player)
end

local function teamstats_cmd(cmd)
    if not cmd.player_index then
        return
    end
    local player = game.get_player(cmd.player_index)
    if not player then
        return
    end
    if cmd.parameter and cmd.parameter ~= '' then
        player.print("Unsupported argument to /teamstats. Run just '/teamstats'")
        return
    end
    TeamStatsCompare.toggle_team_stats(player)
end

commands.add_command('teamstats', 'Show team stats', function(cmd)
    safe_wrap_cmd(cmd, teamstats_cmd, cmd)
end)

---@param event EventData.on_gui_checked_state_changed
local function on_gui_checked_state_changed(event)
    local player = game.get_player(event.player_index)
    if not player then
        return
    end
    if not event.element.valid then
        return
    end
    if event.element.name == 'teamstats_show_hidden' then
        get_preferences(player).show_hidden = event.element.state
        safe_wrap_with_player_print(player, TeamStatsCompare.show_stats, player)
    elseif event.element.name == 'teamstats_show_fluids' then
        get_preferences(player).show_fluids = event.element.state
        safe_wrap_with_player_print(player, TeamStatsCompare.show_stats, player)
    elseif event.element.name == 'teamstats_show_prev' then
        get_preferences(player).show_prev = event.element.state
        safe_wrap_with_player_print(player, TeamStatsCompare.show_stats, player)
    end
end

Event.add(defines.events.on_gui_checked_state_changed, on_gui_checked_state_changed)

return TeamStatsCompare
