local Feeding = require('maps.biter_battles_v2.feeding')
local Tables = require('maps.biter_battles_v2.tables')
local Functions = require('maps.biter_battles_v2.functions')
local Server = require('utils.server')
local Teams = require('maps.biter_battles_v2.teams')

local Public = {}

Public.autofeed = function()
    local surface = game.surfaces[storage.bb_surface_name]
    local steel_chests = surface.find_entities_filtered({ name = 'steel-chest' })
    for i, chest in pairs(steel_chests) do
        local chest_inventory = chest.get_inventory(defines.inventory.chest)
        if chest_inventory and not chest_inventory.is_empty() and Teams.is_active(chest.force.name) then
            for science_pack, _ in pairs(Tables.food_values) do
                local science_count = chest_inventory.get_item_count_filtered({ name = science_pack })
                if science_count > 0 then
                    Feeding.feed_biters_from_autofeed_chest(chest, science_pack)
                end
            end
        end
    end
end

Public.print_autofeed_message = function()
    -- Ring order, which is north then south with two teams: it is the order of
    -- the chat summary, of the Discord summary and of the clearing pass.
    local forces = Teams.all()
    local autofeed_rgb = { r = 0, g = 0.7, b = 1 }

    local header_r = autofeed_rgb.r * 0.6 + 0.35
    local header_g = autofeed_rgb.g * 0.6 + 0.35
    local header_b = autofeed_rgb.b * 0.6 + 0.35
    local header = string.format('[color=%f,%f,%f]Autofeed[/color]', header_r, header_g, header_b)

    local force_summaries = {}
    local has_any = false

    for _, force in ipairs(forces) do
        local counts = storage.pending_autofeed_counts[force]
        if counts and next(counts) then
            has_any = true

            local items = {}
            for food, amount in pairs(counts) do
                table.insert(items, '[img=item.' .. food .. '] x' .. amount)
            end

            local team_label = Functions.team_name_with_color(force) or force
            table.insert(force_summaries, team_label .. ': ' .. table.concat(items, ', '))
        end
    end

    if not has_any then
        return
    end

    local full_message = header .. ' summary: ' .. table.concat(force_summaries, ' | ')
    game.print(full_message, { color = { r = 0.9, g = 0.9, b = 0.9 } })

    local plain_summaries = {}
    for _, force in ipairs(forces) do
        local counts = storage.pending_autofeed_counts[force]
        if counts and next(counts) then
            local items = {}
            for food, amount in pairs(counts) do
                local food_data = Tables.food_values[food]
                local name = food_data and food_data.name or food
                table.insert(items, name .. ' x' .. amount)
            end
            table.insert(plain_summaries, string.upper(force) .. ': ' .. table.concat(items, ', '))
        end
    end
    Server.to_discord_bold('Autofeed: ' .. table.concat(plain_summaries, ' | '))

    for _, force in ipairs(forces) do
        local counts = storage.pending_autofeed_counts[force]
        if counts then
            for food, _ in pairs(counts) do
                counts[food] = nil
            end
        end
    end
end

return Public
