local bb_config = require('maps.biter_battles_v2.config')
local FeedingCalculations = require('maps.biter_battles_v2.feeding_calculations')
local FeedingRestriction = require('maps.biter_battles_v2.feeding_restriction')
local Functions = require('maps.biter_battles_v2.functions')
local Server = require('utils.server')
local Teams = require('maps.biter_battles_v2.teams')

local tables = require('maps.biter_battles_v2.tables')
local Force = require('utils.force')
local food_values = tables.food_values
-- Only the shared_science_throw mirror below still asks "the other team":
-- 2-team only special (guarded by max_teams).
local enemy_team_of = tables.enemy_team_of
local math_floor = math.floor
local math_round = math.round
local safe_wrap_with_player_print = require('utils.utils').safe_wrap_with_player_print
local malloc = require('maps.biter_battles_v2.pool').malloc
local food_long_and_short = tables.food_long_and_short

local Public = {}

local function update_boss_modifiers(force_name_biter, damage_mod_mult, speed_mod_mult)
    local damage_mod = math_round(storage.bb_evolution[force_name_biter] * 1.0, 3) * damage_mod_mult
    local speed_mod = math_round(storage.bb_evolution[force_name_biter] * 0.25, 3) * speed_mod_mult
    local force = game.forces[force_name_biter .. '_boss']
    force.set_ammo_damage_modifier('melee', damage_mod)
    force.set_ammo_damage_modifier('biological', damage_mod)
    force.set_ammo_damage_modifier('artillery-shell', damage_mod)
    force.set_ammo_damage_modifier('flamethrower', damage_mod)
    force.set_gun_speed_modifier('melee', speed_mod)
    force.set_gun_speed_modifier('biological', speed_mod)
    force.set_gun_speed_modifier('artillery-shell', speed_mod)
    force.set_gun_speed_modifier('flamethrower', speed_mod)
end

local function set_biter_endgame_modifiers(force)
    if force.get_evolution_factor(storage.bb_surface_name) ~= 1 then
        return
    end

    local damage_mod = math_round((storage.bb_evolution[force.name] - 1) * 1.0, 3)
    force.set_ammo_damage_modifier('melee', damage_mod)
    force.set_ammo_damage_modifier('biological', damage_mod)
    force.set_ammo_damage_modifier('artillery-shell', damage_mod)
    force.set_ammo_damage_modifier('flamethrower', damage_mod)
end

--- Connected players on every team of the round, in `Teams.all()` order --
--- north's then south's with two teams, which is what the two literal terms
--- this replaces added up. Only echoed back by /calc-send; the feeding curves
--- ignore it (feeding_calculations.lua:23).
--- @return integer
local function connected_team_player_count()
    local count = 0
    local teams = Teams.all()
    for index = 1, #teams do
        local force = game.forces[teams[index]]
        if force then
            count = count + #force.connected_players
        end
    end
    return count
end

-- How a send's recipients are named in the three outputs. One target -- always
-- the case with two teams -- is named exactly as it always was; a send split
-- over several enemies names them collectively. The possessive is part of the
-- answer because "all enemy teams" takes a bare apostrophe where a team name
-- takes "'s".

--- @param targets FeedTarget[]
--- @return string
local function targets_chat_name(targets)
    if #targets == 1 then
        return Functions.team_name_with_color(targets[1].team) .. "'s"
    end
    return "all enemy teams'"
end

-- Science targeting: the focus of a split send, per
-- enemy, " (focus: East 20 %, South 10 %)", or '' when nobody ticks anything
-- -- always the case with two teams, where a send has one target and this is
-- never reached.
--- @param targets FeedTarget[]
--- @param colored boolean
--- @return string
local function targets_focus_suffix(targets, colored)
    local parts = {}
    for index = 1, #targets do
        local target = targets[index]
        if target.focused then
            parts[#parts + 1] = (colored and Teams.name_with_color(target.team) or Teams.display_name(target.team))
                .. ' '
                .. Teams.format_percent(target.focus)
                .. ' %'
        end
    end
    if #parts == 0 then
        return ''
    end
    return ' (focus: ' .. table.concat(parts, ', ') .. ')'
end

--- @param targets FeedTarget[]
--- @return string
local function targets_discord_name(targets)
    if #targets == 1 then
        return 'team ' .. targets[1].team
    end
    return 'all enemy teams' .. targets_focus_suffix(targets, false)
end

--- @param targets FeedTarget[]
--- @return string
local function targets_private_name(targets)
    if storage.training_mode then
        return "your own team's"
    end
    if #targets > 1 then
        return "all enemy teams'"
    end
    return "the enemy team's"
end

--- @param player LuaPlayer
--- @param food string
--- @param flask_amount number
--- @param targets FeedTarget[]
local function print_feeding_msg(player, food, flask_amount, targets)
    if #targets == 0 then
        return
    end

    local colored_player_name = table.concat({
        '[color=',
        player.color.r * 0.6 + 0.35,
        ',',
        player.color.g * 0.6 + 0.35,
        ',',
        player.color.b * 0.6 + 0.35,
        ']',
        player.name,
        '[/color]',
    })
    local formatted_food = table.concat({
        '[color=',
        food_values[food].color,
        ']',
        food_values[food].name,
        ' juice[/color]',
        '[img=item/',
        food,
        ']',
    })
    local formatted_amount = table.concat({ '[font=heading-1][color=255,255,255]', flask_amount, '[/color][/font]' })

    if flask_amount >= 20 then
        game.print(
            table.concat({
                colored_player_name,
                ' fed ',
                formatted_amount,
                ' flasks of ',
                formatted_food,
                ' to ',
                targets_chat_name(targets),
                ' biters',
                #targets > 1 and targets_focus_suffix(targets, true) or '',
                '!',
            }),
            { color = { r = 0.9, g = 0.9, b = 0.9 } }
        )
        Server.to_discord_bold(table.concat({
            player.name,
            ' fed ',
            flask_amount,
            ' flasks of ',
            food_values[food].name,
            ' to ',
            targets_discord_name(targets),
            ' biters!',
        }))
    else
        local target_team_text = targets_private_name(targets)
        if flask_amount == 1 then
            player.print(
                'You fed one flask of ' .. formatted_food .. ' to ' .. target_team_text .. ' biters.',
                { color = { r = 0.98, g = 0.66, b = 0.22 } }
            )
        else
            player.print(
                'You fed '
                    .. formatted_amount
                    .. ' flasks of '
                    .. formatted_food
                    .. ' to '
                    .. target_team_text
                    .. ' biters.',
                { color = { r = 0.98, g = 0.66, b = 0.22 } }
            )
        end
    end
end

--- @param player LuaPlayer?
--- @param feeding_force_name string
--- @param food string
--- @param flask_amount number What this one target received -- a share of the send when it was split.
--- @param biter_force_name string
--- @param evo_before_science_feed number
--- @param threat_before_science_feed number
--- @param sender_flask_amount number? What to book to the sender's own running
--- totals: the whole send on the first target and 0 on the others, so a split
--- send is counted once. Defaults to `flask_amount`, which is what a single
--- target -- always the case with two teams -- passes.
function Public.add_feeding_stats(
    player,
    feeding_force_name,
    food,
    flask_amount,
    biter_force_name,
    evo_before_science_feed,
    threat_before_science_feed,
    sender_flask_amount
)
    if sender_flask_amount == nil then
        sender_flask_amount = flask_amount
    end
    local colored_player_name = 'unknown player'
    if player then
        colored_player_name = table.concat({
            '[color=',
            player.color.r * 0.6 + 0.35,
            ',',
            player.color.g * 0.6 + 0.35,
            ',',
            player.color.b * 0.6 + 0.35,
            ']',
            player.name,
            '[/color]',
        })
    end
    local formatted_food = table.concat({ '[color=', food_values[food].color, '][/color]', '[img=item/', food, ']' })
    -- Above two teams a send is split across the alive enemies, so the amount
    -- recorded here is one share and can be a third of a flask; the row shows
    -- it to two decimals. Two teams keep today's whole number as it is.
    local shown_amount = flask_amount
    if Teams.count() ~= 2 then
        shown_amount = math_round(flask_amount, 2)
    end
    local formatted_amount = table.concat({ '[font=heading-1][color=255,255,255]', shown_amount, '[/color][/font]' })
    if flask_amount > 0 then
        local tick = Functions.get_ticks_since_game_start()
        local feed_time_mins = math_round(tick / (60 * 60), 0)
        local minute_unit = ''
        if feed_time_mins <= 1 then
            minute_unit = 'min'
        else
            minute_unit = 'mins'
        end

        local shown_feed_time_hours = ''
        local shown_feed_time_mins = ''
        shown_feed_time_mins = feed_time_mins .. minute_unit
        local formatted_feed_time = shown_feed_time_hours .. shown_feed_time_mins
        evo_before_science_feed = math_round(evo_before_science_feed * 100, 1)
        threat_before_science_feed = math_round(threat_before_science_feed, 0)
        local formatted_evo_after_feed = math_round(storage.bb_evolution[biter_force_name] * 100, 1)
        local formatted_threat_after_feed = math_round(storage.bb_threat[biter_force_name], 0)
        local evo_jump = table.concat({ evo_before_science_feed, ' to ', formatted_evo_after_feed })
        local threat_jump = table.concat({ threat_before_science_feed, ' to ', formatted_threat_after_feed })
        local evo_jump_difference = math_round(formatted_evo_after_feed - evo_before_science_feed, 1)
        local threat_jump_difference = math_round(formatted_threat_after_feed - threat_before_science_feed, 0)
        local line_log_stats_to_add =
            table.concat({ formatted_amount, ' ', formatted_food, ' by ', colored_player_name, ' to ' })
        -- The receiver is the team behind the biter force that was just fed,
        -- which is what deriving it from the sender came to: the one enemy with
        -- two teams, the sender itself in training mode.
        local team_name_fed_by_science = Teams.team_of_biter_force(biter_force_name)

        -- One totals array per team, each under its own storage key
        -- ('science_logs_total_north', ...): the key is built instead of
        -- written out, so the arrays follow the round's teams. Allocation is in
        -- `Teams.all()` order and is triggered by the first team's array being
        -- missing -- north's, and then north's and south's are made, with two.
        local teams = Teams.all()
        if storage['science_logs_total_' .. teams[1]] == nil then
            for index = 1, #teams do
                storage['science_logs_total_' .. teams[index]] = malloc(#food_long_and_short)
            end
        end

        -- A sender that is not a team of this round has no array and books
        -- nothing. Today it fell through to south's totals; the path is
        -- unreachable either way, as every sender that gets here is on a team.
        local total_science_of_player_force = storage['science_logs_total_' .. feeding_force_name]
        if total_science_of_player_force then
            local indexScience = tables.food_long_to_short[food].indexScience
            total_science_of_player_force[indexScience] = total_science_of_player_force[indexScience]
                + sender_flask_amount
        end

        if storage.science_logs_text then
            table.insert(storage.science_logs_date, 1, formatted_feed_time)
            table.insert(storage.science_logs_text, 1, line_log_stats_to_add)
            table.insert(storage.science_logs_evo_jump, 1, evo_jump)
            table.insert(storage.science_logs_evo_jump_difference, 1, evo_jump_difference)
            table.insert(storage.science_logs_threat, 1, threat_jump)
            table.insert(storage.science_logs_threat_jump_difference, 1, threat_jump_difference)
            table.insert(storage.science_logs_fed_team, 1, team_name_fed_by_science)
            table.insert(storage.science_logs_food_name, 1, food)
        else
            storage.science_logs_date = { formatted_feed_time }
            storage.science_logs_text = { line_log_stats_to_add }
            storage.science_logs_evo_jump = { evo_jump }
            storage.science_logs_evo_jump_difference = { evo_jump_difference }
            storage.science_logs_threat = { threat_jump }
            storage.science_logs_threat_jump_difference = { threat_jump_difference }
            storage.science_logs_fed_team = { team_name_fed_by_science }
            storage.science_logs_food_name = { food }
        end
    end
end

-- Set the canonical evo-derived state for a biter force. Used by do_raw_feed
-- (in-line, additive evo path) AND by tt_mode.tt_recompute_evo (which SETS
-- the absolute target). NEVER touches storage.bb_threat (instantaneous threat
-- pool); only bb_threat_income, the passive income derived from evo.
local function apply_evo_state(biter_force_name, evo, biter_health_factor, passive_threat)
    local force_index = game.forces[biter_force_name].index
    storage.biter_health_factor[force_index] = biter_health_factor
    -- cojito_3v3_balance_testing (2026-09-04): passive threat income comes from
    -- cumulative mutagen (calc_feed_effects.passive_threat), no longer evo*25.
    storage.bb_threat_income[biter_force_name] = passive_threat
    game.forces[biter_force_name].set_evolution_factor(math.min(evo, 1), storage.bb_surface_name)
    storage.bb_evolution[biter_force_name] = evo
    set_biter_endgame_modifiers(game.forces[biter_force_name])
    if evo > 1 then
        update_boss_modifiers(biter_force_name, 2, 1)
    end
    if evo > 3.3 then
        storage.max_group_size[biter_force_name] = 50
    elseif evo > 2.3 then
        storage.max_group_size[biter_force_name] = 75
    elseif evo > 1.3 then
        storage.max_group_size[biter_force_name] = 100
    elseif evo > 0.7 then
        storage.max_group_size[biter_force_name] = 200
    end
end

Public.apply_evo_state = apply_evo_state

function Public.do_raw_feed(flask_amount, food, biter_force_name)
    local decimals = 9

    -- tt_mode: bake rocket-x3 into the food value (plan §E, default interpretation)
    -- AND accumulate RAW mutagen for the retroactive-send recompute (plan §D).
    local raw_food_unit = food_values[food].value
    if storage.tt_mode and food == 'space-science-pack' then
        raw_food_unit = raw_food_unit * 3
    end
    if storage.tt_mode then
        -- Triple Threat plays at two, three and four teams. The
        -- fallback table is the round's biter forces rather than the two
        -- literals; with two teams `per_biter_force` builds exactly
        -- { north_biters = 0, south_biters = 0 }, and the key written below is
        -- the sender's target force either way. Reached only when the mode was
        -- switched on without a reset, since reset_state() seeds it.
        storage.tt_raw_mutagen = storage.tt_raw_mutagen
            or Teams.per_biter_force(function()
                return 0
            end)
        storage.tt_raw_mutagen[biter_force_name] = (storage.tt_raw_mutagen[biter_force_name] or 0)
            + raw_food_unit * flask_amount
    end

    local food_value = raw_food_unit * storage.difficulty_vote_value

    local evo = storage.bb_evolution[biter_force_name]
    local threat = 0.0

    local current_player_count = connected_team_player_count()
    local effects = FeedingCalculations.calc_feed_effects(
        evo,
        food_value,
        flask_amount,
        current_player_count,
        storage.max_reanim_thresh
    )
    evo = evo + effects.evo_increase
    threat = threat + effects.threat_increase * (storage.threat_multiplier or 1)
    evo = math_round(evo, decimals)

    apply_evo_state(biter_force_name, evo, effects.biter_health_factor, effects.passive_threat)

    storage.bb_threat[biter_force_name] = math_round(storage.bb_threat[biter_force_name] + threat, decimals)

    if storage.active_special_games['shared_science_throw'] then
        -- 2-team only special (guarded by max_teams)
        local enemyBitersForceName = enemy_team_of[Force.get_player_force_name(biter_force_name)] .. '_biters'
        game.forces[enemyBitersForceName].set_evolution_factor(
            game.forces[biter_force_name].get_evolution_factor(storage.bb_surface_name),
            storage.bb_surface_name
        )
        storage.bb_evolution[enemyBitersForceName] = storage.bb_evolution[biter_force_name]
        storage.bb_threat_income[enemyBitersForceName] = storage.bb_threat_income[biter_force_name]
        storage.bb_threat[enemyBitersForceName] = math_round(storage.bb_threat[enemyBitersForceName] + threat, decimals)
    end
end

--- Feed one send to each of `targets`, in the order `Teams.feed_targets` gave
--- them, and log every one of them.
---
--- A single target -- always the case with two teams, in training mode and
--- under the one-target feeding policies -- receives the unmodified flask
--- amount through exactly one `do_raw_feed` call, so the arithmetic, the
--- rounding and the number of calls of a two-team send are untouched. Several
--- targets each get their `share` of it, one call apiece, in order.
---
--- The sender's cumulative totals count the whole send once, on the first
--- target; each log row carries what that target actually received.
--- @param player LuaPlayer?
--- @param sender_force_name string
--- @param food string
--- @param flask_amount number
--- @param targets FeedTarget[]
local function feed_the_targets(player, sender_force_name, food, flask_amount, targets)
    local split = #targets > 1
    for index = 1, #targets do
        local target = targets[index]
        local biter_force_name = Teams.biter_force(target.team)
        local fed_amount = flask_amount
        if split then
            fed_amount = flask_amount * target.share
        end

        local evolution_before_feed = storage.bb_evolution[biter_force_name]
        local threat_before_feed = storage.bb_threat[biter_force_name]

        Public.do_raw_feed(fed_amount, food, biter_force_name)

        Public.add_feeding_stats(
            player,
            sender_force_name,
            food,
            fed_amount,
            biter_force_name,
            evolution_before_feed,
            threat_before_feed,
            index == 1 and flask_amount or 0
        )
    end
end

--- @param chest LuaEntity
--- @param food string
function Public.feed_biters_from_autofeed_chest(chest, food)
    local tick = Functions.get_ticks_since_game_start()
    if storage.active_special_games['captain_mode'] then
        tick = game.ticks_played
    end
    if tick <= storage.difficulty_votes_timeout then
        return
    end

    local targets = Teams.feed_targets(chest.force.name)
    if #targets == 0 then
        -- Nowhere to send, so nothing is taken out of the chest. Unreachable
        -- with two teams: feeder_chest.lua only offers chests of an active
        -- team, and one of two teams always has its one enemy.
        return
    end

    local i = chest.get_inventory(defines.inventory.chest)
    if not i then
        return
    end

    local flask_amount = i.get_item_count(food)
    if flask_amount == 0 then
        return
    end

    i.remove({ name = food, count = flask_amount })
    local pending_feeds = storage.pending_autofeed_counts[chest.force.name]
    if not pending_feeds then
        -- init.lua seeds one table per team; a team it has not seeded gets one
        -- here instead of faulting. With two teams both keys always exist.
        pending_feeds = {}
        storage.pending_autofeed_counts[chest.force.name] = pending_feeds
    end
    pending_feeds[food] = (pending_feeds[food] and flask_amount + pending_feeds[food]) or flask_amount

    feed_the_targets(nil, chest.force.name, food, flask_amount, targets)

    if food == 'space-science-pack' then
        storage.spy_fish_timeout[chest.force.name] = game.tick + 99999999
    end
end

--- @param player LuaPlayer
--- @param food string
function Public.feed_biters_from_inventory(player, food)
    local tick = Functions.get_ticks_since_game_start()
    if storage.active_special_games['captain_mode'] then
        tick = game.tick
    end
    if tick <= storage.difficulty_votes_timeout then
        player.print('Please wait for voting to finish before feeding')
        return
    end

    -- Build score restriction
    if not FeedingRestriction.can_player_send_science(player) then
        player.print({ 'info.science_send_restriction' })
        return
    end

    local targets = Teams.feed_targets(player.force.name)
    if #targets == 0 then
        -- Unreachable with two teams: one of two teams always has its one
        -- enemy, and gui.lua hides the science panel from everyone else.
        player.print('There is no team to send science to.', { color = { r = 0.98, g = 0.66, b = 0.22 } })
        return
    end

    -- A player can be here with no character: a spectator of a team that was
    -- eliminated, and anyone waiting to respawn. Reading through `character`
    -- raised, which the event wrapper caught and logged in bursts while the
    -- clicking went on (seen in production at four teams, 2026-09-20).
    local character = player.character
    if not character then
        player.print(
            'You need a character to send science: respawn or rejoin a team first.',
            { color = { r = 0.98, g = 0.66, b = 0.22 } }
        )
        return
    end
    local i = character.get_main_inventory()
    if not i then
        return
    end
    local flask_amount = i.get_item_count(food)
    if flask_amount == 0 then
        player.print(
            'You have no ' .. food_values[food].name .. ' flask in your inventory.',
            { color = { r = 0.98, g = 0.66, b = 0.22 } }
        )
        return
    end

    i.remove({ name = food, count = flask_amount })

    print_feeding_msg(player, food, flask_amount, targets)

    feed_the_targets(player, player.force.name, food, flask_amount, targets)

    if food == 'space-science-pack' then
        storage.spy_fish_timeout[player.force.name] = game.tick + 99999999
    end
end

--- @param player LuaPlayer
--- @param button defines.mouse_button_type
function Public.feed_biters_mixed_from_inventory(player, button)
    local tick = Functions.get_ticks_since_game_start()
    if storage.active_special_games['captain_mode'] then
        tick = game.tick
    end
    if tick <= storage.difficulty_votes_timeout then
        player.print('Please wait for voting to finish before feeding')
        return
    end

    -- Build score restriction
    if not FeedingRestriction.can_player_send_science(player) then
        player.print({ 'info.science_send_restriction' })
        return
    end

    local targets = Teams.feed_targets(player.force.name)
    if #targets == 0 then
        -- Unreachable with two teams, as in feed_biters_from_inventory.
        player.print('There is no team to send science to.', { color = { r = 0.98, g = 0.66, b = 0.22 } })
        return
    end
    local food = {
        'automation-science-pack',
        'logistic-science-pack',
        'military-science-pack',
        'chemical-science-pack',
        'production-science-pack',
        'utility-science-pack',
        'space-science-pack',
    }
    if button == defines.mouse_button_type.right then
        food = {
            'space-science-pack',
            'utility-science-pack',
            'production-science-pack',
            'chemical-science-pack',
            'military-science-pack',
            'logistic-science-pack',
            'automation-science-pack',
        }
    end
    -- A player can be here with no character: a spectator of a team that was
    -- eliminated, and anyone waiting to respawn. Reading through `character`
    -- raised, which the event wrapper caught and logged in bursts while the
    -- clicking went on (seen in production at four teams, 2026-09-20).
    local character = player.character
    if not character then
        player.print(
            'You need a character to send science: respawn or rejoin a team first.',
            { color = { r = 0.98, g = 0.66, b = 0.22 } }
        )
        return
    end
    local i = character.get_main_inventory()
    if not i then
        return
    end
    local colored_player_name = table.concat({
        '[color=',
        player.color.r * 0.6 + 0.35,
        ',',
        player.color.g * 0.6 + 0.35,
        ',',
        player.color.b * 0.6 + 0.35,
        ']',
        player.name,
        '[/color]',
    })
    local message = { colored_player_name, ' fed ' }
    local discord_target_name = targets_discord_name(targets)
    for k, v in pairs(food) do
        local flask_amount = i.get_item_count(v)
        if flask_amount ~= 0 then
            table.insert(
                message,
                '[font=heading-1][color=255,255,255]' .. flask_amount .. '[/color][/font]' .. '[img=item.' .. v .. '], '
            )
            Server.to_discord_bold(table.concat({
                player.name,
                ' fed ',
                flask_amount,
                ' flasks of ',
                food_values[v].name,
                ' to ',
                discord_target_name,
                ' biters!',
            }))
            feed_the_targets(player, player.force.name, v, flask_amount, targets)
            i.remove({ name = v, count = flask_amount })
            if v == 'space-science-pack' then
                storage.spy_fish_timeout[player.force.name] = game.tick + 99999999
            end
        end
    end
    if #message == 2 then
        player.print('You have no flasks in your inventory', { color = { r = 0.98, g = 0.66, b = 0.22 } })
        return
    end
    local focus_suffix = #targets > 1 and targets_focus_suffix(targets, true) or ''
    table.insert(message, 'to ' .. targets_chat_name(targets) .. ' biters' .. focus_suffix .. '!')
    game.print(table.concat(message), { color = { r = 0.9, g = 0.9, b = 0.9 } })
end

local function calc_send(cmd)
    local player
    if cmd.player_index then
        player = game.get_player(cmd.player_index)
    end
    local player_count = connected_team_player_count()
    local result = safe_wrap_with_player_print(
        player,
        FeedingCalculations.calc_send_command,
        cmd.parameter,
        storage.difficulty_vote_value,
        storage.bb_evolution,
        storage.max_reanim_thresh,
        storage.training_mode,
        player_count,
        player
    )
    if not result then
        return
    end
    if player then
        player.print(result)
    else
        game.print(result)
    end
end

commands.add_command('calc-send', 'Calculate the impact of sending science', calc_send)

return Public
