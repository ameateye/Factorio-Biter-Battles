-- Biter Battles v2 -- by MewMew

local Ai = require('maps.biter_battles_v2.ai')
local AiStrikes = require('maps.biter_battles_v2.ai_strikes')
local AiTargets = require('maps.biter_battles_v2.ai_targets')
local AttackClock = require('maps.biter_battles_v2.attack_clock')
local MultiSilo = require('comfy_panel.special_games.multi_silo')
local bb_config = require('maps.biter_battles_v2.config')
local Functions = require('maps.biter_battles_v2.functions')
local Game_over = require('maps.biter_battles_v2.game_over')
local Gui = require('maps.biter_battles_v2.gui')
local Init = require('maps.biter_battles_v2.init')
local Layout = require('maps.biter_battles_v2.layout')
local MatchFormat = require('maps.biter_battles_v2.match_format')
local Mirror_terrain = require('maps.biter_battles_v2.mirror_terrain')
local Rotate_terrain = require('maps.biter_battles_v2.rotate_terrain')
local Muted = require('utils.muted')
local Team_manager = require('maps.biter_battles_v2.team_manager')
local Teams = require('maps.biter_battles_v2.teams')
local Shortcuts = require('maps.biter_battles_v2.shortcuts')
local Terrain = require('maps.biter_battles_v2.terrain')
local FeederChest = require('maps.biter_battles_v2.feeder_chest')
local BossUnit = require('functions.boss_unit')
local Session = require('utils.datastore.session_data')
local Server = require('utils.server')
local Task = require('utils.task')
local String = require('utils.string')
local Token = require('utils.token')
local Color = require('utils.color_presets')
local CaptainVote = require('maps.biter_battles_v2.captain_vote')
local CountVote = require('maps.biter_battles_v2.count_vote')
local ResearchInfo = require('maps.biter_battles_v2.research_info')
local DifficultyVote = require('maps.biter_battles_v2.difficulty_vote')
local ComfyMain = require('comfy_panel.main')
local ComfyPoll = require('comfy_panel.poll')
local autoTagWestOutpost = '[West]'
local autoTagEastOutpost = '[East]'
local autoTagDistance = 600
local antiAfkTimeBeforeEnabled = 60 * 60 * 5 -- in tick : 5 minutes
local antiAfkTimeBeforeWarning = 60 * 60 * 3 + 60 * 40 -- in tick : 3 minutes 40s
require('maps.biter_battles_v2.sciencelogs_tab')
require('maps.biter_battles_v2.feed_values_tab')
require('maps.biter_battles_v2.feeding_params_tab')
require('maps.biter_battles_v2.changelog_tab')
require('maps.biter_battles_v2.commands')
require('maps.biter_battles_v2.tt_mode')
require('modules.spawners_contain_biters')

local function on_player_joined_game(event)
    local surface = game.surfaces[storage.bb_surface_name]
    local player = game.get_player(event.player_index)
    if not player then
        return
    end
    if player.online_time == 0 or player.force.name == 'player' then
        -- When player joins a game for the first time they'll spawn on nauvis.
        -- Workaround within init_player function will cause player to disassociate
        -- from character without destroying it. Not destroying it at this point
        -- will fill nauvis surface with orphaned entities that bring down
        -- performance. On top of it, check if character is still associated
        -- as not connected player will be moved to 'player' force during map
        -- reset without reinitializing their state.
        if player.character and player.character.valid then
            player.character.destroy()
        end

        Functions.init_player(player)
    end
    Gui.clear_copy_history(player)

    -- GUIs
    Gui.create_feature_flags_container(player)
    Gui.refresh_feature_flags(player)
    ComfyMain.comfy_panel_add_top_element(player)
    ComfyPoll.create_top_button(player)
    DifficultyVote.add_difficulty_gui_top_button(player)
    Gui.create_biter_gui_button(player)
    Functions.create_map_intro_button(player)
    --SimpleTags.create_simple_tags_button(player)
    --ResearchInfo.create_research_info_button(player)
    Team_manager.draw_top_toggle_button(player)
    Gui.create_statistics_gui_button(player)
    Shortcuts.get_main_frame(player)

    local ping_messages = player.gui.screen.ping_messages
    if ping_messages then
        ping_messages.destroy()
    end
    local ping_header = player.gui.screen.ping_header
    if ping_header then
        ping_header.destroy()
    end

    Gui.burners_balance(player)  -- tt_mode handoff lives inside this fn (see gui.lua)

    -- Above two teams a team can die while its players are offline: they come
    -- back standing in a base that lost the round, so they are moved to the
    -- spectators here, like the team mates who were connected at the time. With
    -- two teams nobody is ever marked and this returns at its first test.
    Game_over.spectate_if_eliminated(player)

    -- The team-count vote window, when one is open: a player joining mid-vote
    -- gets it and can vote. No vote open -- the case of every two-team server
    -- that never calls for one -- and this adds nothing to the GUI tree.
    CountVote.on_player_joined_game(player)

    -- The captain vote window (BB Captains), same contract: nothing without a vote open.
    CaptainVote.on_player_joined_game(player)
end

local function on_gui_click(event)
    local player = game.get_player(event.player_index)
    local element = event.element
    if not element then
        return
    end
    if not element.valid then
        return
    end

    if Functions.map_intro_click(player, element) then
        return
    end
    -- The team-count vote window. Its elements are the only ones
    -- named `bb_count_vote...`, so with no vote open this is one string compare.
    if CountVote.on_gui_click(player, element) then
        return
    end
    -- The captain vote window: elements named `bb_captain_vote...` only.
    if CaptainVote.on_gui_click(player, element) then
        return
    end

    Team_manager.gui_click(event)
end

local function on_research_finished(event)
    Functions.combat_balance(event)

    local name = event.research.name
    local force = event.research.force
    if name == 'uranium-processing' then
        force.technologies['uranium-ammo'].researched = true
        force.technologies['kovarex-enrichment-process'].researched = true
    elseif name == 'stone-wall' then
        force.technologies['gate'].researched = true
    end
    game.forces.spectator.print(
        Functions.team_name_with_color(force.name) .. ' completed research [technology=' .. name .. ']'
    )
    ResearchInfo.research_finished(name, force)
end

local function on_research_started(event)
    local name = event.research.name
    local force = event.research.force
    ResearchInfo.research_started(name, force)
end

local function on_research_reversed(event)
    -- Note that this will not really work for Functions.combat_balance, so don't go reversing technologies.
    local name = event.research.name
    local force = event.research.force
    ResearchInfo.research_reversed(name, force)
end

local clear_pings_token = Token.register(function()
    local tick = game.tick
    while #storage.pings_to_remove > 0 do
        local ping = storage.pings_to_remove[1]
        if ping.tick <= tick then
            if ping.label.valid then
                if #ping.label.parent.children == 1 then
                    ping.label.gui.screen['ping_header'].destroy()
                    ping.label.parent.destroy()
                else
                    ping.label.destroy()
                end
            end
            table.remove(storage.pings_to_remove, 1)
        else
            break
        end
    end
end)

---@param from_player_name string
---@param to_player_name string
---@return boolean
local function ignore_message(from_player_name, to_player_name)
    local ignore_list = storage.ignore_lists[to_player_name]
    return ignore_list and ignore_list[from_player_name]
end

---@param from_player_name string
---@param to_player LuaPlayer
---@param message string
function do_ping(from_player_name, to_player, message)
    if Muted.is_muted(from_player_name) then
        local p = game.get_player(from_player_name)
        if p then
            Muted.print_muted_message(p)
        end

        return
    end

    local to_player_name = to_player.name
    if ignore_message(from_player_name, to_player_name) then
        return
    end
    if not player_wants_pings(to_player_name) then
        return
    end
    if to_player.character and to_player.character.get_health_ratio() > 0.99 then
        to_player.character.damage(0.001, 'player')
    end
    Sounds.notify_player(to_player, 'utility/undo')
    -- to_player.play_sound({path = "utility/new_objective", volume_modifier = 0.6})
    -- to_player.physical_surface.create_entity({name = 'big-explosion', position = to_player.physical_position})
    local ping_header = to_player.gui.screen['ping_header']
    local uis = to_player.display_scale
    if not ping_header then
        ping_header = to_player.gui.screen.add({
            type = 'frame',
            caption = 'Message',
            name = 'ping_header',
            direction = 'vertical',
        })
        ping_header.style.width = 110
        ping_header.style.height = 38

        local line = ping_header.add({ type = 'line' })
        line.style.width = 400
        line.style.right_margin = -400
        line.style.left_margin = -12
        line.style.top_margin = -5

        if storage.ping_gui_locations[to_player.name] then
            local saved_location = storage.ping_gui_locations[to_player.name]
            saved_location.x = math.min(saved_location.x, to_player.display_resolution.width - 200 * uis)
            saved_location.y = math.min(saved_location.y, to_player.display_resolution.height - 100 * uis)
            ping_header.location = saved_location
        else
            local res = to_player.display_resolution
            local uis = to_player.display_scale
            ping_header.location = { x = res.width / 2 - 200 * uis, y = 100 * uis }
        end
    end

    local ping_messages = to_player.gui.screen['ping_messages']
    if not ping_messages then
        ping_messages = to_player.gui.screen.add({ type = 'flow', name = 'ping_messages', direction = 'vertical' })
        ping_messages.style.width = 400
        ping_messages.style.left_padding = 10
        ping_messages.location = { x = ping_header.location.x, y = ping_header.location.y + 42 * uis }
    end

    local label = ping_messages.add({ type = 'label', caption = message })
    label.style.single_line = false
    label.style.font = 'default-large-semibold'

    local remove_delay = 600
    table.insert(storage.pings_to_remove, { player = to_player, label = label, tick = game.tick + remove_delay })
    Task.set_timeout_in_ticks(remove_delay, clear_pings_token)
end

local function on_gui_location_changed(event)
    local element = event.element
    if not element.valid then
        return
    end
    if element.name == 'ping_header' then
        local player = game.get_player(event.player_index)
        if not player then
            return
        end
        storage.ping_gui_locations[player.name] = element.location

        player.gui.screen['ping_messages'].location =
            { x = element.location.x, y = element.location.y + 42 * player.display_scale }
    end
end

---@param message string
---@param from_player_name string
---@param filter_fn fun(player: LuaPlayer): boolean
local function possibly_do_pings(message, from_player_name, filter_fn)
    for name, _ in pairs(Functions.extract_possible_pings(message)) do
        local player = game.get_player(name)
        if player and filter_fn(player) then
            do_ping(from_player_name, player, message)
        end
    end
end

local function on_console_chat(event)
    --Share chat with spectator force
    if not event.message or not event.player_index then
        return
    end
    local player = game.get_player(event.player_index)
    local player_name = player.name
    local player_force_name = player.force.name
    local tag = player.tag
    if not tag then
        tag = ''
    else
        tag = ' ' .. tag
    end
    local color = player.chat_color

    local muted = Muted.is_muted(player_name)
    local mute_tag = ''
    if muted then
        mute_tag = '[muted] '
    end

    local msg = player_name .. tag .. ' (' .. player_force_name .. '): ' .. event.message
    possibly_do_pings(msg, player_name, function(ping_player)
        return player_force_name == ping_player.force.name
    end)
    if not muted and Teams.is_active(player_force_name) then
        -- Do not share team's chat with spectators during CPT preparation phase
        local special = storage.special_games_variables.captain_mode
        if special and special.prepaPhase then
            return
        end

        Functions.print_message_to_players(game.forces.spectator.connected_players, player_name, msg, color, do_ping)
    end

    if storage.tournament_mode then
        return
    end

    local discord_msg = ''
    if muted then
        discord_msg = mute_tag
        Muted.print_muted_message(player)
    end

    -- Don't pass spectator messages to teams which contain GPS tags or if they
    -- were created by muted players.
    local sane_message = String.sanitize_gps_tags(event.message)
    local gps = String.has_sanitized_gps_tag(sane_message)
    if not gps and not muted and player_force_name == 'spectator' then
        -- Same recipients in the same order as the two unrolled calls: north, then south.
        for _, team in ipairs(Teams.all()) do
            Functions.print_message_to_players(game.forces[team].connected_players, player_name, msg, nil, do_ping)
        end
    end

    -- Don't pass messages to discord with just a gps tag to avoid spam.
    if String.only_sanitized_gps_tag(sane_message) then
        return
    end

    -- Only pass messages to discord with sanitized gps tags.
    discord_msg = discord_msg .. player_name .. ' (' .. player_force_name .. '): ' .. sane_message
    Server.to_discord_player_chat(discord_msg)
end

local function on_console_command(event)
    local cmd = event.command
    if not event.player_index then
        return
    end
    local player = game.get_player(event.player_index)
    local param = event.parameters
    if cmd == 'ignore' then
        -- verify in argument of command that there is no space, quote, semicolon, backtick, and that it's not just whitespace
        if param and not string.match(param, '[ \'";`]') and not param:match('^%s*$') then
            if not storage.ignore_lists[player.name] then
                storage.ignore_lists[player.name] = {}
            end
            if not storage.ignore_lists[player.name][param] then
                storage.ignore_lists[player.name][param] = true
                player.print('You have ignored ' .. param, { color = { r = 0, g = 1, b = 1 } })
            else
                player.print('You are already ignoring ' .. param, { color = { r = 0, g = 1, b = 1 } })
            end
        else
            player.print(
                'Invalid input. Make sure the name contains no spaces, quotes, semicolons, backticks, or any spaces.',
                { color = { r = 1, g = 0, b = 0 } }
            )
        end
    elseif cmd == 'unignore' then
        -- verify in argument of command that there is no space, quote, semicolon, backtick, and that it's not just whitespace, and that the player was someone ignored
        if
            param
            and not string.match(param, '[ \'";`]')
            and not param:match('^%s*$')
            and storage.ignore_lists[player.name]
        then
            if storage.ignore_lists[player.name][param] then
                storage.ignore_lists[player.name][param] = nil
                player.print('You have unignored ' .. param, { color = { r = 0, g = 1, b = 1 } })
            else
                player.print('You are not currently ignoring ' .. param, { color = { r = 0, g = 1, b = 1 } })
            end
        else
            player.print(
                'Invalid input. Make sure the name contains no spaces, quotes, semicolons, backticks, or any spaces.',
                { color = { r = 1, g = 0, b = 0 } }
            )
        end
    elseif cmd == 'w' or cmd == 'whisper' then
        -- split param into first word and rest of the message
        local to_player_name, rest_of_message = string.match(param, '^%s*(%S+)%s*(.*)')
        local to_player = game.get_player(to_player_name)
        if to_player then
            do_ping(player.name, to_player, player.name .. ' (whisper): ' .. rest_of_message)
            -- to_player_name is case insensitive, so use to_player.name instead
            storage.reply_target[to_player.name] = player.name
        end
    elseif cmd == 'r' or cmd == 'reply' then
        local to_player_name = storage.reply_target[player.name]
        if to_player_name then
            storage.reply_target[to_player_name] = player.name
            local to_player = game.get_player(to_player_name)
            if to_player then
                do_ping(player.name, to_player, player.name .. ' (whisper): ' .. param)
            end
        end
    elseif cmd == 's' or cmd == 'shout' then
        possibly_do_pings(
            table.concat({ '[shout] ', player.name, ' (', player.force.name, '): ', param }),
            player.name,
            function(ping_player)
                return true
            end
        )
    end
end

local function on_built_entity(event)
    Functions.maybe_set_game_start_tick(event)
    Functions.no_landfill_by_untrusted_user(event, Session.get_trusted_table())
    Functions.no_turret_creep(event)
    Terrain.deny_enemy_side_ghosts(event)
    AiTargets.start_tracking(event.entity)
    if storage.tt_mode then
        require('maps.biter_battles_v2.tt_mode').on_laser_built(event.entity)
    end
end

local function on_robot_built_entity(event)
    Functions.no_turret_creep(event)
    Terrain.deny_construction_bots(event)
    AiTargets.start_tracking(event.entity)
    if storage.tt_mode then
        require('maps.biter_battles_v2.tt_mode').on_laser_built(event.entity)
    end
end

local function on_robot_built_tile(event)
    Terrain.deny_bot_landfill(event)
end

local function unit_death(entity)
    if Ai.subtract_threat(entity) then
        Gui.refresh_threat()
    end
    if Functions.biters_landfill(entity) then
        return
    end
end

local function on_entity_died(event)
    local entity = event.entity
    if not entity.valid then
        return
    end

    if entity.type == 'unit' or entity.type == 'unit-spawner' or entity.type == 'turret' then
        unit_death(entity)
    elseif entity.type == 'rocket-silo' then
        Game_over.on_entity_died(entity)
    end
end

local function on_entity_damaged(event)
    local entity = event.entity
    if not entity.valid then
        return
    end

    if entity.type == 'unit' then
        BossUnit.on_entity_damaged(entity)
    elseif entity.type == 'rocket-silo' then
        Game_over.on_entity_damaged(event)
    end
end

local function on_ai_command_completed(event)
    if not event.was_distracted then
        AiStrikes.step(event.unit_number, event.result)
    end
end

local function getTagOutpostName(pos)
    if pos < 0 then
        return autoTagWestOutpost
    else
        return autoTagEastOutpost
    end
end

local function hasOutpostTag(tagName)
    return (string.find(tagName, '%' .. autoTagWestOutpost) or string.find(tagName, '%' .. autoTagEastOutpost))
end

local function autotagging_outposters()
    for _, p in pairs(game.connected_players) do
        if Teams.is_active(p.force.name) then
            if math.abs(p.physical_position.x) < autoTagDistance then
                if hasOutpostTag(p.tag) then
                    p.tag = p.tag:gsub('%' .. autoTagWestOutpost, '')
                    p.tag = p.tag:gsub('%' .. autoTagEastOutpost, '')
                end
            else
                if not hasOutpostTag(p.tag) then
                    p.tag = p.tag .. getTagOutpostName(p.physical_position.x)
                end
            end
        end

        if p.force.name == 'spectator' and hasOutpostTag(p.tag) then
            p.tag = p.tag:gsub('%' .. autoTagWestOutpost, '')
            p.tag = p.tag:gsub('%' .. autoTagEastOutpost, '')
        end
    end
end

local function afk_kick(player)
    if player.physical_controller_type == defines.controllers.editor then
        return
    end
    local afk_time = math.min(player.afk_time, Functions.get_ticks_since_game_start())
    if afk_time > antiAfkTimeBeforeWarning and afk_time < antiAfkTimeBeforeEnabled then
        player.print(
            'Please move within the next minute or you will be sent back to spectator island ! But even if you keep staying afk and sent back to spectator island, you will be able to join back to your position with your equipment'
        )
    end
    if afk_time > antiAfkTimeBeforeEnabled then
        player.print(
            'You were sent back to spectator island as you were afk for too long, you can still join to come back at your position with all your equipment'
        )
        spectate(player, false, true)
    end
end

local function anti_afk_system()
    -- Team by team in Teams.all() order -- north then south -- so the sweep
    -- visits the same players in the same order as the two unrolled loops did.
    for _, team in ipairs(Teams.all()) do
        for _, player in pairs(game.forces[team].connected_players) do
            afk_kick(player)
        end
    end
end

local tick_minute_functions = {
    [300 * 1] = Ai.raise_evo,
    [300 * 3 + 30 * 0] = Ai.pre_main_attack, -- setup for main_attack
    [300 * 3 + 30 * 1] = Ai.perform_main_attack, -- call perform_main_attack 7 times on different ticks
    [300 * 3 + 30 * 2] = Ai.perform_main_attack, -- some of these might do nothing (if there are no wave left)
    [300 * 3 + 30 * 3] = Ai.perform_main_attack,
    [300 * 3 + 30 * 4] = Ai.perform_main_attack,
    [300 * 3 + 30 * 5] = Ai.perform_main_attack,
    [300 * 3 + 30 * 6] = Ai.perform_main_attack,
    [300 * 3 + 30 * 7] = Ai.perform_main_attack,
    [300 * 3 + 30 * 8] = Ai.post_main_attack,
    [300 * 3 + 30 * 9] = autotagging_outposters,
    [300 * 4] = Ai.send_near_biters_to_silo,
    [300 * 4 + 30 * 1] = anti_afk_system,
}

-- The keys above that make up one main attack cycle: setup, the seven waves,
-- teardown. MatchFormat can widen the interval between cycles past the vanilla
-- minute; the rest of the table (evo raise, silo pokes, autotagging, afk sweep)
-- keeps its own cadence. Above two teams these nine are the keys the attack
-- clock owns and the table no longer dispatches (see on_tick).
local attack_cycle_keys = {}
for wave = 0, 8 do
    attack_cycle_keys[300 * 3 + 30 * wave] = true
end

local on_tick_profilers = {}
local function profile(profilers, key, fn)
    if not storage.event_profiler_enabled then
        fn()
        return
    end

    local profiler = profilers[key]
    if not profiler then
        profiler = { profiler = game.create_profiler(), count = 1 }
        profilers[key] = profiler
    else
        profiler.profiler.restart()
    end
    fn()
    profiler.profiler.stop()
end
local function on_tick()
    local tick = game.tick

    -- The team-count vote's countdown. It returns on its first
    -- test unless a vote is open, so it costs one table lookup per tick and
    -- writes nothing on a server that never votes.
    CountVote.on_tick(tick)
    -- The captain vote's countdown: one table lookup per tick with no vote open.
    CaptainVote.on_tick(tick)

    if tick % 60 == 0 then
        profile(on_tick_profilers, 'threat', function()
            -- One add per active biter force, in Teams order (north_biters then
            -- south_biters) -- exactly the two unrolled statements this replaces.
            for _, bf in ipairs(Teams.biter_forces()) do
                storage.bb_threat[bf] = storage.bb_threat[bf] + storage.bb_threat_income[bf]
            end
        end)
    end

    if tick % 600 == 0 then
        FeederChest.autofeed()
        if tick % 3600 == 0 then
            FeederChest.print_autofeed_message()
        end
    end

    if (tick + 11) % 300 == 0 then
        profile(on_tick_profilers, 'fish', function()
            Gui.spy_fish()

            if storage.bb_game_won_by_team then
                Game_over.reveal_map()
                Game_over.server_restart()
            end
        end)
    end

    if tick % 30 == 0 then
        local key = tick % 3600
        -- Above two teams, unless the shared-cycle fallback is selected, the
        -- nine keys of the attack cycle belong to the attack-turn clock: it
        -- starts a cycle every `2 * interval / N` ticks so that every team is
        -- still attacked every two intervals (attack_clock.lua). The clock hands
        -- back the key of the step, 900..1140, so the function it runs and the
        -- profiler entry it runs under are the ones this table would have
        -- produced at that step of a vanilla minute. The other slots of the
        -- table keep their per-minute cadence, and are run first so that the
        -- minute's own schedule is never displaced by the clock's extra cycle;
        -- with the intervals a league format can set the two never fall on the
        -- same tick anyway. skip_attack_cycle has no part here -- the period
        -- already carries the interval.
        if AttackClock.is_on(Teams.count()) then
            if tick_minute_functions[key] and not attack_cycle_keys[key] then
                profile(on_tick_profilers, key, function()
                    tick_minute_functions[key]()
                end)
            end
            local step_key = AttackClock.step_key(tick, MatchFormat.attack_interval_ticks(), Teams.count())
            if step_key then
                profile(on_tick_profilers, step_key, function()
                    tick_minute_functions[step_key]()
                end)
            end
        else
            local skip = attack_cycle_keys[key] and MatchFormat.skip_attack_cycle(tick)
            if tick_minute_functions[key] and not skip then
                profile(on_tick_profilers, key, function()
                    tick_minute_functions[key]()
                end)
            end
        end
    end

    if (tick + 5) % 180 == 0 then
        profile(on_tick_profilers, 'gui', function()
            Gui.refresh()
            Shortcuts.refresh()
            ResearchInfo.update_research_info_ui()
        end)
    end

    --[[
		Map width: 750 tiles (~24 chunks) each direction (League: was 2000, Carl 06/09)
		Map height: 500 tiles (~16 chunks) each direction
		Estimated time for complete reveal: 90s (5400 ticks)

		pop_chunk_request will chart the queued chunk requests issued during a new map reveal.
		We chart 65 chunks each iteration because of 16-chunks-tall zones NE, NW, SE, SW, + 1 bonus chunk which is the starting area.
		To fully reveal the new map within the time window, the time interval between requests should be ~84 ticks (5400 / 64-chunks-length),
		plus + 24 ticks as offset to avoid tick_0
	]]
    if (tick + 24) % 84 == 0 then
        profile(on_tick_profilers, 'pop_chunk_request', function()
            Init.pop_chunk_request(65)
        end)
    end
    if tick % 3600 == 0 then
        for key, profiler in pairs(on_tick_profilers) do
            log({ '', 'on_tick_profilers[', key, ']: ', profiler.count, ' times, ', profiler.profiler })
        end
        on_tick_profilers = {}
    end
end

local function on_marked_for_deconstruction(event)
    if not event.entity.valid then
        return
    end
    if not event.player_index then
        return
    end
    local force_name = game.get_player(event.player_index).force.name
    if event.entity.name == 'fish' then
        event.entity.cancel_deconstruction(force_name)
        return
    end
    -- Terrain.deconstruction_denied keeps this rule, which is NOT the robot
    -- build rule: with two teams it is today's half-a-river-width test on the
    -- ENEMY side, on the four-square map it is "your own quadrant only".
    if Terrain.deconstruction_denied(force_name, event.entity.position) then
        event.entity.cancel_deconstruction(force_name)
    end
end

local function on_player_built_tile(event)
    local player = game.get_player(event.player_index)
    if event.item ~= nil and event.item.name == 'landfill' then
        Terrain.restrict_landfill(player.physical_surface, player, event.tiles)
    end
end

---Handles inserter drop protection.
---See init::default_player_settings for more information.
---@param event LuaOnPlayerDroppedItemIntoEntity
local function on_player_dropped_item_into_entity(event)
    local p = game.get_player(event.player_index)
    local p_settings = storage.player_settings[p.name]
    if p_settings.inserter_drop then
        return
    end

    local entity = event.entity
    if entity.type ~= 'inserter' then
        return
    end

    local stack = entity.held_stack
    p.get_main_inventory().insert(stack)
    stack.clear()
end

-- The four-square map of three and four teams: one quadrant is generated by the
-- script and the other three are that quadrant turned.
--
-- The chunk's quadrant says what to do with it. The canonical quadrant runs the
-- generator and the carve pass that cuts its side river; an image chunk waits
-- for its canonical chunk and is then cloned from it; a chunk of the quadrant a
-- three-team round leaves closed is water and nothing else.
--
-- The rules of the two-team path hold here unchanged, quadrant for half: never
-- clone into a chunk the engine has not generated (entity truncation on the
-- chunk border), keep the orbit in lockstep by requesting the members that do
-- not exist yet, and lay a strip of water on the pre-generated tiles that the
-- biter pathfinder could otherwise cross the river on -- on both arms now.

-- The water barriers of both arms of the cross, the horizontal one exactly as
-- the two-team map draws it and the vertical one its twin: a one-tile strip of
-- deepwater along the axis in the chunks the engine has pre-generated tiles for
-- but has not generated, which is the only place the rivers themselves are not
-- there yet.
---@param surface LuaSurface
---@param cx integer
---@param cy integer
local function draw_river_end_barriers(surface, cx, cy)
    if cy >= 0 and cy <= 3 then
        for x = -3, 3 do
            local chunk_pos = { x = cx + x, y = 0 }
            if not surface.is_chunk_generated(chunk_pos) then
                Terrain.draw_water_for_river_ends(surface, chunk_pos)
            end
        end
    end
    if cx >= 0 and cx <= 3 then
        for y = -3, 3 do
            local chunk_pos = { x = 0, y = cy + y }
            if not surface.is_chunk_generated(chunk_pos) then
                Terrain.draw_water_for_vertical_river_ends(surface, chunk_pos)
            end
        end
    end
end

---@param event EventData.on_chunk_generated
---@param surface LuaSurface
local function on_chunk_generated_cross4(event, surface)
    local cx, cy = event.position.x, event.position.y
    local k = Layout.quadrant_of_chunk(cx, cy)

    if Layout.is_closed_quadrant(k) then
        Terrain.fill_chunk_with_water(surface, event.position)
        -- The closed square draws the strips as well. A three-team
        -- round closes the bottom-left quadrant, so every chunk that would
        -- trigger the horizontal loop west of the axis returns here: without
        -- this call the strip stops at chunk column -3, and the band of tiles
        -- the engine pre-generates beyond the generated area -- where neither
        -- Top Left's own river nor this quadrant's water exists yet -- is land
        -- on both sides of y = 0, which the two-team and four-team maps both
        -- cover. Nothing changes with four teams: no quadrant is closed there.
        draw_river_end_barriers(surface, cx, cy)
        return
    end

    local orbit = Layout.chunk_orbit(cx, cy)
    local canonical = orbit[1]

    if k == 0 then
        Terrain.generate(event)
        Terrain.carve_side_river(event)

        -- The canonical chunk is now finished, so every image of it that the
        -- engine has already made can take its copy.
        for i = 2, 4 do
            local image = orbit[i]
            if not Layout.is_closed_quadrant(image.k) and surface.is_chunk_generated({ image.x, image.y }) then
                Rotate_terrain.clone(surface, canonical, image, image.k)
            end
        end
    elseif surface.is_chunk_generated({ canonical.x, canonical.y }) then
        -- An image chunk whose canonical chunk exists: it has been through the
        -- generator, since that happens inside its own on_chunk_generated.
        Rotate_terrain.clone(surface, canonical, orbit[k + 1], k)
    end

    -- Request the rest of the orbit, maintain the lockstep. A closed quadrant is
    -- not part of anyone's orbit and is generated only if something else asks.
    for i = 1, 4 do
        local member = orbit[i]
        if not Layout.is_closed_quadrant(member.k) and not surface.is_chunk_generated({ member.x, member.y }) then
            surface.request_to_generate_chunks({ member.x * 32, member.y * 32 }, 0)
        end
    end

    -- The water barriers of both arms of the cross.
    draw_river_end_barriers(surface, cx, cy)

    -- The new year island decorations are not drawn on this map: they are ~40
    -- positions around the origin placed with the global random generator, so
    -- they are neither a quarter of anything nor reproducible by a turn.
end

local function on_chunk_generated(event)
    local surface = event.surface

    -- Check if we're out of init.
    if not surface or not surface.valid then
        return
    end

    -- Necessary check to ignore nauvis surface.
    if surface.name ~= storage.bb_surface_name then
        return
    end

    if Teams.layout() == 'cross4' then
        on_chunk_generated_cross4(event, surface)
        return
    end

    -- Generate structures for north only.
    local pos = event.area.left_top
    if pos.y < 0 then
        Terrain.generate(event)

        -- If we mirror-clone chunk here it may cause entity truncation on a chunk border
        -- duo to receiving chunk empty neighbors. Also for some reason additional tile
        -- correction would be required. So we wait for native generation occurrence,
        -- and this will guarantee existing of neighboring chunks
    end

    local opposite_chunk_pos = { event.position.x, -event.position.y - 1 }
    if surface.is_chunk_generated(opposite_chunk_pos) then
        -- Notice that this will trigger for both paired chunks if they were force generated together, which is rare.
        -- Otherwise first chunk will delay cloning until after the second one is generated
        Mirror_terrain.clone(event)
    end

    -- Request chunk for opposite side, maintain the lockstep.
    -- NOTE: There is still a window where user can place down a structure
    -- and it will be mirrored. However this window is so tiny - user would
    -- need to fly in god mode and spam entities in partially generated
    -- chunks.
    -- Setting position in the middle of a chunk sometimes doesn't
    -- do a request, but seems to work for the left top corner, maybe an api bug?
    surface.request_to_generate_chunks({ pos.x, -pos.y - 32 }, 0)

    -- The game pregenerate tiles within a radius of 3 chunks from the generated chunk.
    -- Bites can use these tiles for pathing.
    -- This creates a problem that bites pathfinder can cross the river at the edge of the map.
    -- To prevent this, divide the north and south land by drawing a strip of water on these pregenerated tiles.
    if event.position.y >= 0 and event.position.y <= 3 then
        for x = -3, 3 do
            local chunk_pos = { x = event.position.x + x, y = 0 }
            if not surface.is_chunk_generated(chunk_pos) then
                Terrain.draw_water_for_river_ends(surface, chunk_pos)
            end
        end
    end

    -- add decorations only after the south part of the island is generated
    if event.position.y == 0 and event.position.x == 1 and storage.bb_settings['new_year_island'] then
        Terrain.add_new_year_island_decorations(surface)
    end
end

local function on_entity_cloned(event)
    local source = event.source
    local destination = event.destination

    -- In case entity dies between clone and this event we
    -- have to ensure south doesn't get additional objects.
    if not source.valid then
        if destination.valid then
            destination.destroy()
        end

        return
    end

    if Teams.layout() == 'cross4' then
        Rotate_terrain.rotate_entity(event)
        return
    end

    Mirror_terrain.invert_entity(event)
end

local function on_area_cloned(event)
    local surface = event.destination_surface

    -- Check if we're out of init and not between surface hot-swap.
    if not surface or not surface.valid then
        return
    end

    if Teams.layout() == 'cross4' then
        -- The destination quadrant says how far the canonical chunk turned; the
        -- hidden tiles come with the visible ones, so there is no counterpart of
        -- the remove_hidden_tiles repair below.
        Rotate_terrain.rotate_tiles(event)
        Rotate_terrain.rotate_decoratives(event)
        return
    end

    -- Event is fired only for south side.
    Mirror_terrain.invert_tiles(event)
    Mirror_terrain.invert_decoratives(event)

    -- Check chunks around southen silo to remove water tiles under refined-concrete.
    -- Silo can be removed by picking bricks from under it in a situation where
    -- refined-concrete tiles were placed directly onto water tiles. This scenario does
    -- not appear for north as water is removed during silo generation.
    local position = event.destination_area.left_top
    if position.y >= 0 and position.y <= 192 and math.abs(position.x) <= 192 then
        Mirror_terrain.remove_hidden_tiles(event)
    end
end

local function on_init()
    Init.tables()
    Init.initial_setup()
    Init.reset_feature_flags()
    Init.playground_surface()
    Init.forces()
    Init.draw_structures()
    Init.queue_reveal_map()
end

local Event = require('utils.event')
Event.add(defines.events.on_area_cloned, on_area_cloned)
Event.add(defines.events.on_entity_cloned, on_entity_cloned)
Event.add(defines.events.on_built_entity, on_built_entity)
Event.add(defines.events.on_chunk_generated, on_chunk_generated)
Event.add(defines.events.on_console_chat, on_console_chat)
Event.add(defines.events.on_console_command, on_console_command)
Event.add(defines.events.on_entity_died, on_entity_died)
Event.add(defines.events.on_ai_command_completed, on_ai_command_completed)
Event.add(defines.events.on_gui_click, on_gui_click)
Event.add(defines.events.on_gui_location_changed, on_gui_location_changed)
Event.add(defines.events.on_marked_for_deconstruction, on_marked_for_deconstruction)
Event.add(defines.events.on_player_built_tile, on_player_built_tile)
Event.add(defines.events.on_player_joined_game, on_player_joined_game)
Event.add(defines.events.on_research_finished, on_research_finished)
Event.add(defines.events.on_research_started, on_research_started)
Event.add(defines.events.on_research_reversed, on_research_reversed)
Event.add(defines.events.on_robot_built_entity, on_robot_built_entity)
Event.add(defines.events.on_robot_built_tile, on_robot_built_tile)
Event.add(defines.events.on_player_dropped_item_into_entity, on_player_dropped_item_into_entity)
Event.add(defines.events.on_tick, on_tick)
Event.on_init(on_init)

script.on_event(defines.events.on_entity_damaged, on_entity_damaged, {
    {
        filter = 'type',
        type = 'unit',
    },
    {
        filter = 'final-health',
        comparison = '=',
        value = 0,
        mode = 'and',
    },
    {
        filter = 'type',
        type = 'rocket-silo',
        mode = 'or',
    },
    {
        filter = 'final-health',
        comparison = '=',
        value = 0,
        mode = 'and',
    },
})

require('utils.ui.gui-lite').handle_events()
