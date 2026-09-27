local Event = require('utils.event')
local Color = require('utils.color_presets')
local Teams = require('maps.biter_battles_v2.teams')
local Public = {}
storage.active_special_games = {}
storage.special_games_variables = {}
storage.next_special_games = {}
storage.next_special_games_variables = {}

--- The registry of special games. Besides `name`, `config`, `button`,
--- `generate` and `gui_click` (see `special_games/example.lua`), a module may
--- declare one optional field:
---
---   `max_teams` -- the largest team count the special game is played with.
---   Absent means no limit, which is the answer for every special game that
---   does not say otherwise, so a two-team round refuses nothing and behaves
---   exactly as it always did.
---
--- `max_teams = 2` is set on the seven whose *mechanics* are pairwise, not just
--- their wording: captain mode (a two-sided
--- draft), shared_science_throw (a pairwise max of two evolutions), turtle,
--- infinity_chest and mk2_fordeka (their second team IS the `y -> -y` mirror of
--- the first), threat_farm_threshold (excess threat goes to "the" opponent) and
--- multi_silo (silo placement is an x-distance test, which with cross rivers
--- would let a team plant a silo in someone else's quadrant).
local valid_special_games = {
    turtle = require('comfy_panel.special_games.turtle'),
    multi_silo = require('comfy_panel.special_games.multi_silo'),
    infinity_chest = require('comfy_panel.special_games.infinity_chest'),
    disabled_research = require('comfy_panel.special_games.disabled_research'),
    disabled_entities = require('comfy_panel.special_games.disabled_entities'),
    shared_science_throw = require('comfy_panel.special_games.shared_science_throw'),
    limited_lives = require('comfy_panel.special_games.limited_lives'),
    mixed_ore_map = require('comfy_panel.special_games.mixed_ore_map'),
    disable_sciences = require('comfy_panel.special_games.disable_sciences'),
    send_to_external_server = require('comfy_panel.special_games.send_to_external_server'),
    captain = require('comfy_panel.special_games.captain'),
    threat_farm_threshold = require('comfy_panel.special_games.threat_farm_threshold'),
    special_combo = require('comfy_panel.special_games.mk2_fordeka'),
    --[[
    Add your special game here.
    Syntax:
    <game_name> = require 'comfy_panel.special_games.<game_name>',

    Create file special_games/<game_name>.lua
    See file special_games/example.lua for an example
    ]]
}

--- The key a special game sets in `storage.active_special_games`, for the two
--- that do not use their own registry name: captain mode stores itself under
--- `captain_mode` (captain.lua:763) and the mk2 combo raises the infinity-chest
--- flag (mk2_fordeka.lua:48). Every other special game uses its registry key.
local active_game_key = {
    captain = 'captain_mode',
    special_combo = 'infinity_chest',
}

---Why a round of `count` teams may not start `special`, or nil when it may.
---@param special table An entry of `valid_special_games`.
---@param count integer
---@return string|nil reason
local function unsupported_reason(special, count)
    local max_teams = special.max_teams
    if not max_teams or count <= max_teams then
        return nil
    end
    local label = special.name and special.name.caption or 'This special game'
    return '[SPECIAL GAMES] '
        .. label
        .. ' is played with at most '
        .. max_teams
        .. ' teams and this round has '
        .. count
        .. '. It was not started.'
end

---Switch off every active special game that a round of `count` teams cannot
---play. Meant for the reset path, where a round of a different size is about to
---start under whatever was left switched on.
---
---Nothing is ever switched off for a two-team round: no special game declares a
---limit below two. The names are sorted so that two clients reporting the same
---set report it in the same order -- `valid_special_games` is a hash.
---
---Two registry entries can share one key: `infinity_chest` and `special_combo`
---(mk2 fordeka) both raise the `infinity_chest` flag and write the same
---variables, so which of them was actually started cannot be read back out of
---`storage`. The sorted walk clears the flag under the first of the two, and
---the line would then name `infinity_chest` for a round where only mk2 fordeka
---ran. Rather than guess, the entry names both, once, in the slot of the first.
---@param count integer Teams of the round that is about to start.
---@return string[] disabled Registry names of the special games switched off.
function Public.disable_unsupported(count)
    local names = {}
    for name in pairs(valid_special_games) do
        names[#names + 1] = name
    end
    table.sort(names)

    local disabled = {}
    ---@type table<string, integer> Where in `disabled` a storage key was reported.
    local reported_at = {}
    for _, name in ipairs(names) do
        local max_teams = valid_special_games[name].max_teams
        if max_teams and count > max_teams then
            local key = active_game_key[name] or name
            if storage.active_special_games[key] then
                storage.active_special_games[key] = nil
                disabled[#disabled + 1] = name
                reported_at[key] = #disabled
            elseif reported_at[key] then
                local at = reported_at[key]
                disabled[at] = disabled[at] .. '/' .. name
            end
        end
    end
    return disabled
end

local function clear_gui_specials()
    local captain_event = require('comfy_panel.special_games.captain')
    captain_event.clear_gui_special()
end

function Public.reset_special_games()
    storage.active_special_games = storage.next_special_games
    storage.special_games_variables = storage.next_special_games_variables
    storage.next_special_games = {}
    storage.next_special_games_variables = {}
    clear_gui_specials()
    local captain_event = require('comfy_panel.special_games.captain')
    captain_event.reset_special_games()

    -- The round that is about to start, not the one that just ended:
    -- `Teams.begin_round()` has not run yet -- it is the first statement of
    -- `Init.tables()`, which the reset path calls after this -- so a pending
    -- request is the count the specials above have to survive. Two teams, the
    -- only count that can be pending without a `/team-count`, switch nothing
    -- off and print nothing.
    local count = Teams.next_count() or Teams.count()
    local disabled = Public.disable_unsupported(count)
    if #disabled > 0 then
        game.print(
            '[SPECIAL GAMES] Not playable with ' .. count .. ' teams, switched off: ' .. table.concat(disabled, ', '),
            { color = Color.warning }
        )
    end
end

---The element a special game's config row adds for one of its entries.
---
---Everything is passed through untouched but the left/both/right team switch of
---`disabled_research` and `disabled_entities` above two teams. Its tooltip is
---the literal 'North / Both / South', which is a lie in a round where `left`
---selects the first playing team, `right` the last and nothing selects the ones
---in between: there the tooltip is rewritten to say so.
---
---With two teams -- and for every other config element, at any count -- the
---very table the special game declared is returned, so the panel adds today's
---element.
---
---Later: the honest fix is a per-team selector (the drop-down
---`calc_send_ui.lua` builds for its receiving team), not a three-position
---switch; see the `-- Later:` note at both config rows.
---@param element table One entry of a special game's `config`.
---@return table
local function config_element(element)
    if element.name ~= 'team' or element.type ~= 'switch' or Teams.count() <= 2 then
        return element
    end
    local active = Teams.all()
    local copy = {}
    for key, value in pairs(element) do
        copy[key] = value
    end
    copy.tooltip = Teams.display_name(active[1]) .. ' / all teams / ' .. Teams.display_name(active[#active])
    return copy
end

local create_special_games_panel = function(player, frame)
    frame.clear()
    frame.add({ type = 'label', caption = 'Configure and apply special games here' }).style.single_line = false
    local sp = frame.add({ type = 'scroll-pane', horizontal_scroll_policy = 'never' })
    sp.style.vertically_squashable = true
    sp.style.padding = 2
    for k, v in pairs(valid_special_games) do
        local a = sp.add({ type = 'frame' })
        a.style.horizontally_stretchable = true
        local table = a.add({ name = k, type = 'table', column_count = 3, draw_vertical_lines = true })
        table.add(v.name).style.width = 110
        local config = table.add({ name = k .. '_config', type = 'flow', direction = 'horizontal' })
        config.style.horizontally_stretchable = true
        config.style.left_padding = 3
        for _, i in ipairs(v.config) do
            config.add(config_element(i))
            config[i.name].style.width = i.width
        end
        table.add({ name = v.button.name, type = v.button.type, caption = v.button.caption })
        table[k .. '_config'].style.vertical_align = 'center'
    end
end

local function is_element_child_of(element, parent_name)
    if element.parent then
        if element.parent.name == parent_name then
            return true
        end

        return is_element_child_of(element.parent, parent_name)
    end

    return false
end

local function get_sepecial_game_table(element)
    if element.parent then
        if element.parent.type == 'table' and valid_special_games[element.parent.name] then
            return element.parent
        end

        return get_sepecial_game_table(element.parent)
    end

    return nil
end

local function on_gui_click(event)
    local element = event.element
    if not element then
        return
    end
    if not element.valid then
        return
    end
    if not (element.type == 'button') then
        return
    end
    if not is_element_child_of(element, 'Special games') then
        return
    end

    local special_game_gui = get_sepecial_game_table(element)
    if not special_game_gui then
        return
    end

    local config = special_game_gui.children[2]
    local player = game.get_player(event.player_index)

    if element.name == 'confirm' or element.name == 'cancel' then
        if element.name == 'confirm' then
            local special = valid_special_games[special_game_gui.name]
            -- The round the special game would be played in, not the one being
            -- played now: the same expression `reset_special_games()` validates
            -- against, so an admin who ran /team-count and then confirms is
            -- refused on the spot instead of learning at the reset that it was
            -- switched off again. With two teams and nothing pending this is
            -- `nil or 2` = 2, today's value -- and 2 refuses nothing anyway.
            local refusal = unsupported_reason(special, Teams.next_count() or Teams.count())
            if refusal then
                if player then
                    player.print(refusal, { color = Color.warning })
                else
                    game.print(refusal, { color = Color.warning })
                end
            else
                special.generate(config, player)
            end
        end

        if not element.valid then
            return
        end
        special_game_gui.children[3].visible = true -- shows back Apply button
        element.parent.destroy() -- removes confirm/Cancel buttons
    elseif element.name == 'apply' then
        local flow = element.parent.add({ type = 'flow', direction = 'vertical' })
        flow.add({ type = 'button', name = 'confirm', caption = 'Confirm' })
        flow.add({ type = 'button', name = 'cancel', caption = 'Cancel' })
        element.visible = false -- hides Apply button
        player.print(
            '[SPECIAL GAMES] Are you sure? This change will be reversed only on map restart!',
            { color = Color.cyan }
        )
    elseif valid_special_games[special_game_gui.name]['gui_click'] then
        valid_special_games[special_game_gui.name].gui_click(element, config, player)
    end
end

comfy_panel_tabs['Special games'] = { gui = create_special_games_panel, admin = true }

Event.add(defines.events.on_gui_click, on_gui_click)

return Public
