local Event = require('utils.event')
local Color = require('utils.color_presets')
local Teams = require('maps.biter_battles_v2.teams')

--- The teams the config row's left/both/right switch selects, in `Teams.all()`
--- order: `left` is the first active team, `right` the last, and the none state
--- (the middle of the switch) is every team. With two teams that is north /
--- south / both, which is the switch of today.
---
--- `disabled_research.lua` carries the same function, byte for byte. Both are
--- exported at the bottom of their file and both are pinned by
--- `tests/test-special-guards.lua`, which loads this one with `utils.event`
--- stubbed -- the two copies are only safe while each is tested, and the
--- `scope_of_switch` beneath them are NOT the same function.
---@param switch_state string 'left', 'right', or 'none'.
---@return string[] teams
local function teams_of_switch(switch_state)
    local active = Teams.all()
    if switch_state == 'left' then
        return { active[1] }
    end
    if switch_state == 'right' then
        return { active[#active] }
    end
    local all = {}
    for i = 1, #active do
        all[i] = active[i]
    end
    return all
end

--- How the message names the teams the switch selected: 'team North' for one of
--- them, and for the whole round 'both teams' when there are two -- today's
--- word, kept for today's round -- or 'all teams' above two.
---
--- Above two teams a single team is named by its display name instead, as in
--- `disabled_research.lua`: the switch can only pick the first playing team or
--- the last, and a corner team's force name does not say which corner. The
--- two-team spelling is the capitalised force name this message has always
--- used, kept verbatim under the count test -- it is compared byte for byte.
---@param teams string[]
---@return string
local function scope_of_switch(teams)
    if #teams == 1 then
        local name = teams[1]
        if Teams.count() > 2 then
            return 'team ' .. Teams.display_name(name)
        end
        return 'team ' .. name:sub(1, 1):upper() .. name:sub(2)
    end
    if #teams == 2 then
        return 'both teams'
    end
    return 'all teams'
end

--- The entities this force may not place, or nil when the force is not one this
--- special game was configured for -- a spectator, or a team of a round that
--- started after the table was built.
---@param force_name string
---@return table<string, true>|nil
local function disabled_entities_of(force_name)
    local per_team = storage.special_games_variables['disabled_entities']
    if not per_team then
        return nil
    end
    return per_team[force_name]
end

local function generate_disabled_entities(team, eq)
    if not storage.special_games_variables['disabled_entities'] then
        storage.special_games_variables['disabled_entities'] = Teams.per_team(function()
            return {}
        end)
    end
    local tab = {}
    for k, v in pairs(eq) do
        if v then
            tab[v] = true
            if v == 'rail' then
                tab['straight-rail'] = true
                tab['curved-rail'] = true
            end
        end
    end
    local teams = teams_of_switch(team)
    local per_team = storage.special_games_variables['disabled_entities']
    for i = 1, #teams do
        -- The same table for every selected team, as the 'both' branch of the
        -- two-team code stored it.
        per_team[teams[i]] = tab
    end
    game.print(
        'Special game Disabled entities: '
            .. table.concat(eq, ', ')
            .. ' for '
            .. scope_of_switch(teams)
            .. ' is being generated!',
        { color = Color.warning }
    )
    storage.active_special_games['disabled_entities'] = true
end

local function on_built_entity(event)
    if not storage.active_special_games['disabled_entities'] then
        return
    end
    local entity = event.entity
    if not entity then
        return
    end
    if not entity.valid then
        return
    end

    local player = game.get_player(event.player_index)
    local force = player.force
    local disabled = disabled_entities_of(force.name)
    if not disabled then
        return
    end
    if disabled[entity.name] then
        player.create_local_flying_text({ text = 'Disabled by special game', position = entity.position })
        if entity.name == 'straight-rail' or entity.name == 'curved-rail' then
            player.character.get_inventory(defines.inventory.character_main).insert({ name = 'rail', count = 1 })
        else
            player.character.get_inventory(defines.inventory.character_main).insert({ name = entity.name, count = 1 })
        end
        entity.destroy()
    elseif entity.name == 'entity-ghost' and disabled[entity.ghost_name] then
        player.create_local_flying_text({ text = 'Disabled by special game', position = entity.position })
        entity.destroy()
    end
end

local function on_marked_for_upgrade(event)
    if not storage.active_special_games['disabled_entities'] then
        return
    end
    local entity = event.entity
    if not entity or not entity.valid then
        return
    end
    if not entity.get_upgrade_target() then
        return
    end
    local player = game.get_player(event.player_index)
    local disabled = disabled_entities_of(player.force.name)
    if not disabled then
        return
    end

    if disabled[entity.get_upgrade_target().name] then
        entity.cancel_upgrade(player.force)
        player.create_local_flying_text({ text = 'Disabled by special game', position = entity.position })
    end
end

local function on_pre_ghost_upgraded(event)
    if not storage.active_special_games['disabled_entities'] then
        return
    end
    local entity = event.ghost
    if not entity or not entity.valid then
        return
    end
    local player = game.get_player(event.player_index)
    local disabled = disabled_entities_of(player.force.name)
    if not disabled then
        return
    end

    if disabled[event.target.name] then
        local entityName = entity.ghost_name
        local entitySurface = entity.surface
        local entityPosition = entity.position
        local entityForce = entity.force
        entity.destroy()
        entitySurface.create_entity({
            name = 'entity-ghost',
            ghost_name = entityName,
            position = entityPosition,
            force = entityForce,
        })
        player.create_local_flying_text({ text = 'Disabled by special game', position = entityPosition })
    end
end

local Public = {
    name = { type = 'label', caption = 'Disabled entities', tooltip = 'Disables chosen entities from being placed' },
    config = {
        [1] = { name = 'eq1', type = 'choose-elem-button', elem_type = 'item' },
        [2] = { name = 'eq2', type = 'choose-elem-button', elem_type = 'item' },
        [3] = { name = 'eq3', type = 'choose-elem-button', elem_type = 'item' },
        [4] = { name = 'eq4', type = 'choose-elem-button', elem_type = 'item' },
        [5] = { name = 'eq5', type = 'choose-elem-button', elem_type = 'item' },
        [6] = { name = 'eq6', type = 'choose-elem-button', elem_type = 'item' },
        [7] = { name = 'eq7', type = 'choose-elem-button', elem_type = 'item' },
        -- Later: three positions cannot select the team in the middle of a
        -- three- or four-team round -- left is the first playing team, right the
        -- last. The real fix is a per-team selector like the drop-down of
        -- `calc_send_ui.lua`; until then `comfy_panel/special_games.lua` gives
        -- this switch a truthful tooltip above two teams, and the two-team
        -- caption below is kept byte for byte.
        [8] = {
            name = 'team',
            type = 'switch',
            switch_state = 'none',
            allow_none_state = true,
            tooltip = 'North / Both / South',
        },
    },
    button = { name = 'apply', type = 'button', caption = 'Apply' },
    generate = function(config, player)
        local team = config['team'].switch_state
        local eq = {}
        for v = 1, 1, 7 do
            if config['eq' .. v].elem_value then
                eq[config['eq' .. v].elem_value] = true
            end
        end
        eq = {
            config['eq1'].elem_value,
            config['eq2'].elem_value,
            config['eq3'].elem_value,
            config['eq4'].elem_value,
            config['eq5'].elem_value,
            config['eq6'].elem_value,
            config['eq7'].elem_value,
        }
        generate_disabled_entities(team, eq)
    end,
}

-- Pure, and the only two things in this file that can be exercised outside
-- Factorio: `tests/test-special-guards.lua` pins them, `scope_of_switch`
-- especially -- it is the one that has to reproduce
-- '... for team North is being generated!' byte for byte.
Public.teams_of_switch = teams_of_switch
Public.scope_of_switch = scope_of_switch

Event.add(defines.events.on_built_entity, on_built_entity)
Event.add(defines.events.on_marked_for_upgrade, on_marked_for_upgrade)
Event.add(defines.events.on_pre_ghost_upgraded, on_pre_ghost_upgraded)

return Public
