-- Evo and threat setup — the nine constants of the feeding curves, per match
-- format, in the gearwheel menu.
--
-- The same numbers /feeding-params prints, laid out rather than wrapped in chat.
-- Everyone gets the tab: once an admin has moved anything, this and the command
-- are the only honest account of what a flask is worth, and a player owed that
-- account should not have to know a command exists to get it. Admins get a box
-- per number, a checkbox for the one that is a switch, and two buttons.
--
-- The format being edited is chosen from a dropdown and defaults to the one
-- being played. Everyone can look at any format's set; only admins can move it.
--
-- The panel owns no state -- the dropdown holds the only choice there is to
-- make, and it is read back off the element. Everything else is drawn from
-- `FeedingParams.get(key)` every time and written through `FeedingParams.set`,
-- so the bounds, the p -> n drag, the report and the announcement are the
-- command's, not a second copy of them.

local FeedingParams = require('maps.biter_battles_v2.feeding_params')
local MatchFormat = require('maps.biter_battles_v2.match_format')
local Tabs = require('comfy_panel.main')
local Gui = require('utils.gui')

-- Doubles as the tab caption, the tab's flow element name and its key in
-- comfy_panel_tabs, which is how the panel finds its way back to this module.
local TAB_NAME = 'Evo and threat setup'

-- Element names. The root is found by walking a clicked button's parents, so the
-- handlers need no state of their own to reach the boxes.
local ROOT = 'bb_feeding_params_root'
local FORMULAS = 'bb_feeding_params_formulas'
local FORMAT = 'bb_feeding_params_format'
local SELECT_ROW = 'bb_feeding_params_select_row'
local SELECT = 'bb_feeding_params_select'
local INPUTS = 'bb_feeding_params_inputs'
local SUMMARY = 'bb_feeding_params_summary'
local STATUS = 'bb_feeding_params_status'
local APPLY = 'bb_feeding_params_apply'
local RESET = 'bb_feeding_params_reset'
local INPUT_PREFIX = 'bb_feeding_params_in_'
local ROW_PREFIX = 'bb_feeding_params_row_'
local CLEAR_PREFIX = 'bb_feeding_params_clear_'

local HEADING_COLOR = { 0.55, 0.55, 0.99 }
local HEADER_COLOR = { 0.88, 0.88, 0.99 }
local VALUE_COLOR = { 0.9, 0.9, 0.9 }
local MOVED_COLOR = { 1, 0.85, 0.2 }
local INHERITED_COLOR = { 0.6, 0.78, 1 }
local MUTED_COLOR = { 0.7, 0.7, 0.7 }
local ERROR_COLOR = { 1, 0.35, 0.35 }
local OK_COLOR = { 0.4, 0.9, 0.4 }

local ROW_HEIGHT = 24

local SELECTOR_TOOLTIP = 'Each match format carries its own set of these numbers, so retuning one leaves every other'
    .. ' format exactly where it was. "default" is the exception: it is both what a server with no league match plays'
    .. ' and the base the others inherit from, so moving a number there moves it for every format that has not claimed'
    .. ' that parameter for itself. The format being played is marked.'

-- Under a retuned base, "the default" and "what the scenario ships" stop being
-- the same number. The column shows the first, because that is the one emptying
-- a box actually produces.
local DEFAULT_TOOLTIP = 'What this parameter falls back to if this format stops overriding it: the format own shipped'
    .. ' deviation if it has one, otherwise whatever the "default" set has been tuned to, otherwise the number the'
    .. ' scenario ships. Empty a box and Apply to drop back to it.'

-- Position of each format key in the dropdown, which is how a selection is
-- turned back into a key.
local key_index = {}
for index, key in ipairs(FeedingParams.format_keys) do
    key_index[key] = index
end

-- What each number does, in the terms a balance argument is had in rather than
-- in the terms of the algebra -- the algebra is on the line above the table.
local descriptions = {
    evo_mutagen_at_100 = 'Mutagen that buys exactly 100% evolution. Raise it and every flask is worth less evolution.',
    evo_power = 'The diminishing return on evolution. Lower means the first flasks buy far more than the later ones.',
    evo_stop_scaling_at_100 = 'On: past 100% evolution the curve continues along its own tangent, so a further +100% costs a flat S/p mutagen however high evolution already is. Off: the power law runs on forever and evolution keeps getting cheaper per point.',
    passive_scale = 'Coefficient of the powered term of passive threat income — what dominates at high evolution.',
    passive_power = 'Its exponent. Lives strictly inside (1, 1/p), so raising p closes the window and drags this down with it.',
    passive_linear = 'The linear term: the income floor, which is most of the income while evolution is low.',
    instant_scale = 'Instant threat per unit of mutagen, landed the moment a send resolves rather than earned over time.',
    passive_income_scale = 'Multiplies the whole passive curve for this format. 1 is the curve as written; 0.5 is half the income off the same shape, which is how a small-team format is damped without rewriting a and b. Instant threat is not touched, so lowering this makes a send worth relatively more.',
    attack_interval = 'Ticks between global attack waves. The wave alternates sides, so each side is hit every twice this. Must be a multiple of 3600 — a wave is only offered once a minute — and 3600 itself is the vanilla cadence.',
}

-- The parameter table. "In force" is the column to read; "New value" is only what
-- has been typed and not applied yet, which is why the two are separate rather
-- than one editable cell that would lie about the state of the game.
local ADMIN_COLUMNS = {
    { 230, 'Parameter' },
    { 90, 'In force' },
    { 110, 'New value' },
    { 80, 'Default', DEFAULT_TOOLTIP },
    { 110, 'Range' },
}
local READONLY_COLUMNS = {
    { 230, 'Parameter' },
    { 90, 'In force' },
    { 80, 'Default', DEFAULT_TOOLTIP },
    { 110, 'Range' },
}

-- The summary is transposed against the parameter table -- evolution across,
-- metric down -- because the span is four wide and only three deep, and this way
-- the whole tab fits without scrolling at the usual UI scale.
local SUMMARY_ROWS = {
    {
        'Mutagen fed',
        'Total mutagen behind that evolution, from zero.',
        function(at)
            return string.format('%.0f', at.mutagen)
        end,
    },
    {
        'Passive threat / min',
        'Threat the biters earn per minute once that evolution is reached, with this format\'s multiplier applied.',
        function(at)
            return string.format('%.0f', at.threat_per_minute)
        end,
    },
    {
        'Instant ≈ passive',
        'What the instant threat of a send is worth in minutes of the passive income that same send buys, at the margin. This is the number the constants are chosen against.',
        function(at)
            return string.format('%.1f min', at.ratio)
        end,
    },
}

---Almost every element here is a label with a colour and a column width, so
---adding one is worth a helper rather than four lines each time.
---@param parent LuaGuiElement
---@param caption string
---@param color table
---@param width number|nil
---@param tooltip string|nil
---@return LuaGuiElement
local function cell(parent, caption, color, width, tooltip)
    local label = parent.add({ type = 'label', caption = caption, tooltip = tooltip })
    label.style.font_color = color
    if width then
        label.style.minimal_width = width
    end
    return label
end

---@param parent LuaGuiElement
---@param caption string
---@param tooltip string|nil
---@param width number|nil
local function header(parent, caption, tooltip, width)
    cell(parent, caption, HEADER_COLOR, width, tooltip).style.font = 'heading-2'
end

---Dropdown captions, with the format actually being played called out. Rebuilt
---on every draw because the league record can arrive after the panel is open.
---@param live_key string
---@return string[]
local function selector_items(live_key)
    local items = {}
    for _, key in ipairs(FeedingParams.format_keys) do
        items[#items + 1] = (key == live_key) and (key .. '  — being played') or key
    end
    return items
end

---Which format's set the panel is showing.
---@param root LuaGuiElement
---@return string
local function selected_key(root)
    local row = root[SELECT_ROW]
    local dropdown = row and row.valid and row[SELECT] or nil
    if dropdown and dropdown.valid then
        local key = FeedingParams.format_keys[dropdown.selected_index]
        if key then
            return key
        end
    end
    return MatchFormat.format_key()
end

---@param field string
---@param params FeedingParams
---@return string
local function range_for(field, params)
    local low, high = FeedingParams.bounds(field, params)
    if not low then
        return 'on / off'
    end
    return string.format('%.4g – %.4g', low, high)
end

---A group's title across the parameter table. Factorio tables have no column
---spanning, so the rest of the row is padded with empty cells.
---@param t LuaGuiElement
---@param group table
---@param columns table
local function group_heading(t, group, columns)
    cell(t, group.title, HEADING_COLOR, columns[1][1], group.note).style.font = 'default-bold'
    for i = 2, #columns do
        cell(t, '', MUTED_COLOR, columns[i][1])
    end
end

---@param t LuaGuiElement
---@param params FeedingParams
---@param admin boolean
---@param format_key string
local function fill_params(t, params, admin, format_key)
    local columns = admin and ADMIN_COLUMNS or READONLY_COLUMNS
    for _, column in ipairs(columns) do
        header(t, column[2], column[3], column[1])
    end

    for _, group in ipairs(FeedingParams.groups) do
        group_heading(t, group, columns)

        for _, field in ipairs(group.fields) do
            local symbol = FeedingParams.symbol(field)
            local name = string.format('%s%s [img=info]', field, symbol and (' (' .. symbol .. ')') or '')
            cell(t, name, VALUE_COLOR, columns[1][1], descriptions[field])

            -- Three states worth telling apart: this format's own number, a
            -- number coming from the retuned base, and the one the scenario
            -- ships. Only the first is undone by resetting this format.
            local moved = FeedingParams.is_overridden(field, format_key)
            local inherited = FeedingParams.is_inherited(field, format_key)
            cell(
                t,
                FeedingParams.show(params[field]) .. (inherited and ' *' or ''),
                moved and MOVED_COLOR or (inherited and INHERITED_COLOR or VALUE_COLOR),
                columns[2][1],
                moved and 'Set for this format. Empty the box and Apply to drop back to the Default column.'
                    or (inherited and 'Not set for this format - following the retuned "default" set.' or nil)
            )

            if admin then
                -- The control and its reset share one cell. Factorio tables have
                -- no column spanning, and a sixth column carrying one small
                -- button would cost more width than a tab this tall has to give.
                local row = t.add({ type = 'flow', name = ROW_PREFIX .. field, direction = 'horizontal' })
                row.style.vertical_align = 'center'
                row.style.horizontal_spacing = 2

                if type(FeedingParams.defaults[field]) == 'boolean' then
                    row.add({ type = 'checkbox', name = INPUT_PREFIX .. field, state = params[field] })
                else
                    local box = row.add({
                        type = 'textfield',
                        name = INPUT_PREFIX .. field,
                        text = FeedingParams.show(params[field]),
                        numeric = true,
                        allow_decimal = not FeedingParams.steps[field],
                        allow_negative = false,
                    })
                    box.style.width = 76
                    box.style.height = ROW_HEIGHT
                end

                -- Disabled rather than omitted when there is nothing to drop, so
                -- the column keeps its shape as rows are moved and cleared, and
                -- so the button itself reports whether this format is holding
                -- this number.
                local clear = row.add({
                    type = 'sprite-button',
                    name = CLEAR_PREFIX .. field,
                    sprite = 'utility/reset_white',
                    style = 'tool_button',
                    enabled = moved,
                    tooltip = moved
                            and string.format(
                                'Drop this format\'s %s and fall back to %s. Takes effect at once and is announced,'
                                    .. ' like any other retune.',
                                field,
                                FeedingParams.show(FeedingParams.inherited_for(field, format_key))
                            )
                        or string.format('%s is not set for this format — nothing to drop.', field),
                })
                clear.style.size = ROW_HEIGHT
                clear.style.padding = 0
            end

            -- Where emptying this box would land, not what the scenario ships:
            -- with a retuned base underneath, naming the shipped number would be
            -- naming a value a clear does not produce.
            cell(
                t,
                FeedingParams.show(FeedingParams.inherited_for(field, format_key)),
                MUTED_COLOR,
                columns[admin and 4 or 3][1]
            )
            cell(t, range_for(field, params), MUTED_COLOR, columns[admin and 5 or 4][1])
        end
    end
end

---@param s LuaGuiElement
---@param params FeedingParams
local function fill_summary(s, params)
    header(s, '', nil, 170)
    local at = {}
    for _, evo in ipairs(FeedingParams.quote_at) do
        header(s, string.format('%d%% evo', evo * 100), nil, 110)
        at[#at + 1] = FeedingParams.summary_at(evo, params)
    end

    for _, row in ipairs(SUMMARY_ROWS) do
        cell(s, row[1] .. ' [img=info]', VALUE_COLOR, 170, row[2])
        for _, values in ipairs(at) do
            cell(s, row[3](values), VALUE_COLOR, 110)
        end
    end
end

---A table whose rows are all one height, with no padding to spare: the tab is a
---fixed 480px tall and everything here has to fit inside it.
---@param parent LuaGuiElement
---@param name string
---@param column_count number
---@return LuaGuiElement
local function compact_table(parent, name, column_count)
    local t = parent.add({ type = 'table', name = name, column_count = column_count })
    t.style.top_cell_padding = 0
    t.style.bottom_cell_padding = 0
    t.style.vertical_align = 'center'
    return t
end

---@param player LuaPlayer
---@param frame LuaGuiElement
local function build(player, frame)
    frame.clear()
    local admin = is_admin(player)
    local live_key = MatchFormat.format_key()
    local format_key = live_key
    local params = FeedingParams.get(format_key)

    local root = frame.add({ type = 'scroll-pane', name = ROOT, horizontal_scroll_policy = 'never' })
    root.style.vertically_squashable = true
    root.style.padding = 4

    cell(root, 'Feeding curves', HEADING_COLOR).style.font = 'default-bold'

    local formulas = root.add({ type = 'label', name = FORMULAS, caption = FeedingParams.formulas(params) })
    formulas.style.font_color = VALUE_COLOR
    formulas.style.single_line = false
    formulas.style.font = 'default-semibold'

    -- What is actually being played, which is a fact about the match rather than
    -- anything set here -- hence a label and not a control.
    local format = root.add({ type = 'label', name = FORMAT, caption = 'Match: ' .. MatchFormat.describe() })
    format.style.font_color = MUTED_COLOR
    format.style.single_line = false

    local select_row = root.add({ type = 'flow', name = SELECT_ROW, direction = 'horizontal' })
    select_row.style.vertical_align = 'center'
    select_row.style.bottom_padding = 4
    cell(select_row, 'Editing format [img=info]', VALUE_COLOR, nil, SELECTOR_TOOLTIP)
    select_row.add({
        type = 'drop-down',
        name = SELECT,
        items = selector_items(live_key),
        selected_index = key_index[format_key] or 1,
    })

    fill_params(
        compact_table(root, INPUTS, admin and #ADMIN_COLUMNS or #READONLY_COLUMNS),
        params,
        admin,
        format_key
    )

    if admin then
        local buttons = root.add({ type = 'flow', direction = 'horizontal' })
        buttons.style.top_padding = 4
        buttons.style.vertical_align = 'center'
        buttons.add({
            type = 'button',
            name = APPLY,
            caption = 'Apply',
            tooltip = 'Apply every box that differs from the value in force, to the format selected above. An emptied'
                .. ' box stops this format overriding that parameter, dropping it back to the Default column.'
                .. ' Announced to both teams.',
        })
        buttons.add({
            type = 'button',
            name = RESET,
            caption = 'Reset this format',
            tooltip = 'Drop the overrides for the selected format only. Every other format is left alone.',
        })
    else
        cell(root, 'Admins can retune these. /feeding-params prints the same numbers in chat.', MUTED_COLOR).style.top_padding =
            4
    end

    -- Kept out of the buttons flow so it sits at a fixed path from the root, and
    -- so a long error wraps under the buttons rather than pushing them along.
    local status = root.add({ type = 'label', name = STATUS, caption = '' })
    status.style.single_line = false

    cell(root, 'What that comes to', HEADING_COLOR).style.font = 'default-bold'
    fill_summary(compact_table(root, SUMMARY, #FeedingParams.quote_at + 1), params)
end

---Redraw the numbers without destroying anything a click is still inside.
---
---`frame.clear()` would take the Apply button with it, and this scenario runs
---every on_gui_click handler off one dispatcher: a handler further down the list
---would then be handed an element that had gone invalid under it. So only the
---two tables are rebuilt, and the buttons the click came from are left alone.
---@param player LuaPlayer
---@param frame LuaGuiElement
local function refresh(player, frame)
    local root = frame[ROOT]
    local admin = is_admin(player)
    local expected = admin and #ADMIN_COLUMNS or #READONLY_COLUMNS
    if not (root and root.valid) or root[INPUTS].column_count ~= expected then
        -- Promoted or demoted with the panel open: the layout itself changed.
        build(player, frame)
        return
    end

    local live_key = MatchFormat.format_key()
    local format_key = selected_key(root)
    local params = FeedingParams.get(format_key)

    root[FORMULAS].caption = FeedingParams.formulas(params)
    root[FORMAT].caption = 'Match: ' .. MatchFormat.describe()

    -- The captions carry the "being played" marker, so they are rebuilt in case
    -- the league record arrived while the panel was open. The selection is read
    -- back rather than reset, so this cannot yank an admin off the format they
    -- were part way through editing.
    local select_row = root[SELECT_ROW]
    local dropdown = select_row and select_row.valid and select_row[SELECT] or nil
    if dropdown and dropdown.valid then
        local selection = dropdown.selected_index
        dropdown.items = selector_items(live_key)
        dropdown.selected_index = selection
    end

    root[INPUTS].clear()
    fill_params(root[INPUTS], params, admin, format_key)
    root[SUMMARY].clear()
    fill_summary(root[SUMMARY], params)
end

---A retune moves what a send is worth for both teams, so a panel left open must
---not go on showing the old numbers until its owner happens to click something.
local function refresh_open_panels()
    for _, player in pairs(game.connected_players) do
        local frame = Tabs.comfy_panel_get_active_frame(player)
        if frame and frame.name == TAB_NAME then
            refresh(player, frame)
        end
    end
end

---@param player LuaPlayer
---@param caption string
---@param color table
local function set_status(player, caption, color)
    local frame = Tabs.comfy_panel_get_active_frame(player)
    if not frame or frame.name ~= TAB_NAME then
        return
    end
    local status = frame[ROOT] and frame[ROOT][STATUS]
    if status and status.valid then
        status.caption = caption
        status.style.font_color = color
    end
end

---Walk up from a clicked control to the panel it belongs to.
---@param element LuaGuiElement
---@return LuaGuiElement|nil
local function find_root(element)
    while element and element.valid do
        if element.name == ROOT then
            return element
        end
        element = element.parent
    end
    return nil
end

---What is in the box for `field`, in the same text form `show` produces, so it
---can be compared against what was drawn there.
---@param inputs LuaGuiElement
---@param field string
---@return string|nil
local function typed_value(inputs, field)
    local row = inputs[ROW_PREFIX .. field]
    local element = row and row.valid and row[INPUT_PREFIX .. field] or nil
    if not (element and element.valid) then
        return nil
    end
    if element.type == 'checkbox' then
        return element.state and 'true' or 'false'
    end
    return element.text
end

Gui.on_selection_state_changed(SELECT, function(event)
    local root = find_root(event.element)
    if not root then
        return
    end
    -- Only the tables move; the dropdown the event came from is left alone.
    refresh(event.player, root.parent)
end)

Gui.on_click(APPLY, function(event)
    local player = event.player
    -- Re-checked rather than trusted to the fact that the button was not drawn:
    -- a player can be demoted with the panel already open in front of them.
    if not is_admin(player) then
        return
    end
    local root = find_root(event.element)
    if not root then
        return
    end
    local inputs = root[INPUTS]
    local format_key = selected_key(root)

    local applied, errors = {}, {}
    -- In `order`, which puts p before n. n's window depends on p, so a change to
    -- both at once has to store the new p first or the new n is judged against
    -- the window the old one opened.
    for _, field in ipairs(FeedingParams.order) do
        local typed = typed_value(inputs, field)
        local before = FeedingParams.get(format_key)
        if typed == '' then
            -- An emptied box reads as "this format should stop having an opinion
            -- about this number", not as zero -- the boxes are numeric, so there
            -- is no word to type and this is the only gesture available. Guarded
            -- on the format actually holding an override, so blanking a row that
            -- was already inheriting is not announced as a change.
            if FeedingParams.is_overridden(field, format_key) then
                local stored = FeedingParams.clear(field, format_key)
                applied[#applied + 1] = string.format('%s = %s (inherited)', field, FeedingParams.show(stored))
            end
        elseif typed and typed ~= FeedingParams.show(before[field]) then
            local stored, err = FeedingParams.set(field, typed, format_key)
            if err then
                errors[#errors + 1] = err
            else
                applied[#applied + 1] = string.format('%s = %s', field, FeedingParams.show(stored))
            end
        end
    end

    if #applied > 0 then
        FeedingParams.announce_changed(player.name, applied, format_key)
    end
    refresh_open_panels()

    if #errors > 0 then
        -- Also to chat: the status line is one place in one panel, and a refused
        -- value is worth keeping next to the ones that went through.
        for _, err in ipairs(errors) do
            player.print('[feeding-params] ' .. err)
        end
        set_status(player, 'Not applied: ' .. table.concat(errors, '; '), ERROR_COLOR)
    elseif #applied > 0 then
        set_status(player, string.format('Applied to %s: %s.', format_key, table.concat(applied, ', ')), OK_COLOR)
    else
        set_status(player, 'Nothing to apply — no box differs from the value in force.', MUTED_COLOR)
    end
end)

Gui.on_click(RESET, function(event)
    local player = event.player
    if not is_admin(player) then
        return
    end
    local root = find_root(event.element)
    if not root then
        return
    end
    local format_key = selected_key(root)
    FeedingParams.reset(format_key)
    FeedingParams.announce_reset(player.name, format_key)
    refresh_open_panels()
    set_status(player, 'Reset ' .. format_key .. ' to defaults.', OK_COLOR)
end)

-- One registration per field rather than one handler matching a prefix: the
-- dispatcher keys on the exact element name, and nine names is cheaper than
-- teaching it patterns. Bound at load, so every panel drawn later is covered.
for _, field in ipairs(FeedingParams.order) do
    Gui.on_click(CLEAR_PREFIX .. field, function(event)
        local player = event.player
        if not is_admin(player) then
            return
        end
        local root = find_root(event.element)
        if not root then
            return
        end
        local format_key = selected_key(root)

        -- Drawn disabled when there is nothing to drop, but a click can still
        -- arrive from a panel that was open when someone else cleared the same
        -- row. Redraw rather than announce a change that did not happen.
        if not FeedingParams.is_overridden(field, format_key) then
            refresh_open_panels()
            return
        end

        local stored = FeedingParams.clear(field, format_key)
        FeedingParams.announce_changed(
            player.name,
            { string.format('%s = %s (inherited)', field, FeedingParams.show(stored)) },
            format_key
        )
        refresh_open_panels()
        set_status(
            player,
            string.format('Dropped %s from %s — now %s.', field, format_key, FeedingParams.show(stored)),
            OK_COLOR
        )
    end)
end

comfy_panel_tabs[TAB_NAME] = { gui = build, admin = false }
