local Color = require('utils.color_presets')
local Teams = require('maps.biter_battles_v2.teams')

--- The teams the config row's left/both/right switch selects, in `Teams.all()`
--- order: `left` is the first active team, `right` the last, and the none state
--- (the middle of the switch) is every team. With two teams that is the
--- `{ left = 'north', right = 'south' }` map this replaced, and the none state
--- is the "both" branch.
---
--- Exported at the bottom of this file for `tests/test-special-guards.lua`;
--- `disabled_entities.lua` has the same function, which cannot be tested there
--- because that file does not load outside Factorio.
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

--- How a message names the teams the switch selected: 'team north' -- the force
--- name, as the two-team messages spelled it -- for one of them, and for the
--- whole round 'both teams' when there are two, or 'all teams' above two.
---
--- Above two teams a single team is named by its display name instead. The
--- force name of a corner team says nothing about which corner just lost a
--- technology, and the switch itself can only ever pick the first playing team
--- or the last, which is exactly what the admin needs told. The two-team
--- strings are the ones the baseline compares byte for byte, so they are kept
--- verbatim under the count test.
---@param teams string[]
---@return string
local function scope_of_switch(teams)
    if #teams == 1 then
        if Teams.count() > 2 then
            return 'team ' .. Teams.display_name(teams[1])
        end
        return 'team ' .. teams[1]
    end
    if #teams == 2 then
        return 'both teams'
    end
    return 'all teams'
end

---Set `enabled` on one technology of one team, when both exist. A team of this
---round always has its force; a name left in the list by an earlier round of
---more teams may not.
---@param team string
---@param tech_name string
---@param enabled boolean
local function set_technology_enabled(team, tech_name, enabled)
    local force = game.forces[team]
    if not force then
        return
    end
    local technology = force.technologies[tech_name]
    if not technology then
        return
    end
    technology.enabled = enabled
end

local function generate_disabled_research(team, eq)
    if not storage.special_games_variables['disabled_research'] then
        storage.special_games_variables['disabled_research'] = Teams.per_team(function()
            return {}
        end)
    end
    storage.active_special_games['disabled_research'] = true
    local per_team = storage.special_games_variables['disabled_research']
    local teams = teams_of_switch(team)

    for i = 1, #teams do
        local name = teams[i]
        per_team[name] = per_team[name] or {}
        for k, v in pairs(eq) do
            table.insert(per_team[name], v)
            set_technology_enabled(name, v, false)
        end
    end
    game.print(
        'Special game Disabled research: '
            .. table.concat(eq, ', ')
            .. ' for '
            .. scope_of_switch(teams)
            .. ' is being generated!',
        { color = Color.warning }
    )
end

local function reset_disabled_research(team)
    if not storage.active_special_games['disabled_research'] then
        return
    end
    local per_team = storage.special_games_variables['disabled_research']
    if not per_team then
        return
    end
    local teams = teams_of_switch(team)

    for i = 1, #teams do
        local name = teams[i]
        for k, v in pairs(per_team[name] or {}) do
            set_technology_enabled(name, v, true)
        end
        per_team[name] = {}
    end
    game.print('All disabled research has been enabled again for ' .. scope_of_switch(teams), { color = Color.warning })
end

local Public = {
    name = {
        type = 'label',
        caption = 'Disabled research',
        tooltip = 'Disables chosen technologies from being researched',
    },
    config = {
        [1] = { name = 'eq1', type = 'choose-elem-button', elem_type = 'technology' },
        [2] = { name = 'eq2', type = 'choose-elem-button', elem_type = 'technology' },
        [3] = { name = 'eq3', type = 'choose-elem-button', elem_type = 'technology' },
        [4] = { name = 'eq4', type = 'choose-elem-button', elem_type = 'technology' },
        [5] = { name = 'eq5', type = 'choose-elem-button', elem_type = 'technology' },
        [6] = { name = 'eq6', type = 'choose-elem-button', elem_type = 'technology' },
        [7] = { name = 'eq7', type = 'choose-elem-button', elem_type = 'technology' },
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
        [9] = {
            name = 'reset_disabled_research',
            type = 'button',
            caption = 'Reset',
            tooltip = 'Enable all the disabled research again',
        },
    },
    button = { name = 'apply', type = 'button', caption = 'Apply' },
    generate = function(config, player)
        local team = config['team'].switch_state
        local eq = {
            config['eq1'].elem_value,
            config['eq2'].elem_value,
            config['eq3'].elem_value,
            config['eq4'].elem_value,
            config['eq5'].elem_value,
            config['eq6'].elem_value,
            config['eq7'].elem_value,
        }

        generate_disabled_research(team, eq)
    end,
    gui_click = function(element, config, player)
        if element.name == 'reset_disabled_research' then
            config = element.parent.parent.children[2]
            local team = config['team'].switch_state
            reset_disabled_research(team)
        end
    end,
}

-- Pure, and the only two things of these guards that can be exercised outside
-- Factorio: `tests/test-special-guards.lua` pins them.
Public.teams_of_switch = teams_of_switch
Public.scope_of_switch = scope_of_switch

return Public
