local Terrain = require('maps.biter_battles_v2.terrain')
local Daytime = require('maps.biter_battles_v2.daytime')
local Score = require('comfy_panel.score')
local Tables = require('maps.biter_battles_v2.tables')
local Blueprint = require('maps.biter_battles_v2.blueprints')
local Functions = require('maps.biter_battles_v2.functions')
local AiTargets = require('maps.biter_battles_v2.ai_targets')
local Layout = require('maps.biter_battles_v2.layout')
local Teams = require('maps.biter_battles_v2.teams')
local Pathfinder = require('commands.set_pathfinder')
local Queue = require('utils.queue')
local FeatureFlags = require('maps.biter_battles_v2.feature_flags')
local q_size = Queue.size
local q_push = Queue.push
local q_pop = Queue.pop

local Public = {}

local function createTrollSong(forceName, offset)
    local bp_string = Blueprint.get_blueprint('jail_song')
    local jailSurface = game.surfaces['gulag']
    local bp_entity = jailSurface.create_entity({ name = 'item-on-ground', position = offset, stack = 'blueprint' })
    bp_entity.stack.import_stack(bp_string)
    local bp_entities = bp_entity.stack.get_blueprint_entities()
    local bpInfo = { surface = jailSurface, force = forceName, position = offset, force_build = 'true' }
    local bpResult = bp_entity.stack.build_blueprint(bpInfo)
    bp_entity.destroy()
    for k, v in pairs(bpResult) do
        if k == 27 then
            v.get_control_behavior().enabled = false
        end
        if k == 28 then
            v.get_control_behavior().enabled = true
        end
        v.revive()
    end
    local songBuildings = jailSurface.find_entities_filtered({
        area = { { -11 + offset.x, -23 + offset.y }, { 12 + offset.x, 25 + offset.y } },
        name = {
            'constant-combinator',
            'decider-combinator',
            'substation',
            'programmable-speaker',
            'arithmetic-combinator',
            'electric-energy-interface',
        },
    })
    for k, v in pairs(songBuildings) do
        v.minable_flag = false
        v.destructible = false
        v.operable = false
    end
end

---Surfaces no human force may see. `initial_setup()` hides them from the forces
---it creates, once per save; a team force created later by
---`Teams.ensure_forces()` gets exactly the same treatment.
local HIDDEN_SURFACES = { 'gulag', 'nauvis' }

---Hides `HIDDEN_SURFACES` from every force of `force_names`, one surface at a
---time -- with the three human forces of a two-team game this is the call order
---of the scenario before teams were a parameter.
---@param force_names string[]
local function hide_system_surfaces(force_names)
    for _, surface_name in ipairs(HIDDEN_SURFACES) do
        for _, force_name in ipairs(force_names) do
            game.forces[force_name].set_surface_hidden(surface_name, true)
        end
    end
end

---The jail "troll song" slots on the `gulag` surface, one per human force, in
---the order they are BUILT: the songs are real entities, so that order is the
---order of their unit numbers. The first three entries are the three calls of
---the two-team scenario, with their offsets and their order (south, north,
---spectator) unchanged.
---
---`ring` is the roster position of the team a slot belongs to (1 north, 2 east,
---3 south, 4 west); the slot without one is the spectators'. The two new slots
---continue the 40-tile spacing eastwards rather than westwards: the gulag arena
---is walled at x = +-128 (utils/datastore/jail_data.lua:139-156) and a song
---spans [x - 11, x + 12], so x = -120 would sit on the wall and x = -160
---outside the surface.
---@type { x: number, ring: integer? }[]
local JAIL_SONG_SLOTS = {
    { x = 6, ring = 3 },
    { x = -40, ring = 1 },
    { x = -80 },
    { x = 46, ring = 2 },
    { x = 86, ring = 4 },
}

---The x offset of the jail song slot of `team`, or nil when it has none.
---@param team string
---@return number|nil
local function jail_song_x(team)
    local ring = Teams.ring_index(team)
    if not ring then
        return nil
    end
    for _, slot in ipairs(JAIL_SONG_SLOTS) do
        if slot.ring == ring then
            return slot.x
        end
    end
    return nil
end

---The team playing at ring position `ring` this round, or nil when there is
---none.
---@param ring integer
---@return string|nil
local function active_team_at_ring(ring)
    for _, team in ipairs(Teams.all()) do
        if Teams.ring_index(team) == ring then
            return team
        end
    end
    return nil
end

---The one-shot, per-save setup of a team force: the system surfaces stay hidden
---from it and it gets its own jail song slot. `initial_setup()` does this work
---for the forces it creates, with the two helpers above and in the order the
---two-team scenario did it in; this is the same work for a team force that
---`Teams.ensure_forces()` created later, at a map reset.
---@param team string
local function setup_new_team_force(team)
    hide_system_surfaces({ team })
    local x = jail_song_x(team)
    if x then
        createTrollSong(team, { x = x, y = 0 })
    end
end

---Where a team's players spawn: the geometry model's answer (`layout.lua`).
---
---Two teams get today's two literals, {0, -44} and {0, 44}, one on each side of
---the river along y = 0 -- `Layout` returns them in the `{ x =, y = }` form
---rather than the array one, which `set_spawn_position` reads the same way. The
---four-square map gets the canonical spawn {-44, -44} turned into each team's
---quadrant, off both of its rivers.
---@param team string
---@return MapPosition|nil nil for a team with no zone on this map.
local function team_spawn_position(team)
    return Layout.spawn_position(team)
end

---The forces of the roster teams that do NOT play this round and that some
---earlier round created: the team force, its biters and its boss biters, in
---roster order. Empty in a save that never played more than two teams -- east
---and west simply do not exist there.
---@return string[]
local function dormant_team_force_names()
    local forces = game.forces
    local names = {}
    for _, team in ipairs(Teams.roster()) do
        if not Teams.is_active(team) then
            local own = { team, Teams.biter_force(team), Teams.boss_force(team) }
            for _, name in ipairs(own) do
                if forces[name] then
                    names[#names + 1] = name
                end
            end
        end
    end
    return names
end

---Take the diplomacy of those dormant forces back to nothing, both ways,
---against every force that exists.
---
---`Public.forces()` only ever sets relations to TRUE and `LuaForce.reset()`
---does not touch diplomacy, so without this the friendships of a four-team
---round would survive into every later round: `north_biters` would stay friends
---with a dormant `east`, and the first change that puts an entity on a dormant
---force would inherit that silently. The forces of the teams that DO play are
---not touched -- the block below rebuilds their whole matrix anyway.
---
---`set_friend` / `set_cease_fire` are one-way writes with no side effect, so
---the resulting matrix does not depend on the order the forces come back in.
local function clear_dormant_team_relations()
    for _, name in ipairs(dormant_team_force_names()) do
        local f = game.forces[name]
        for _, other in pairs(game.forces) do
            if other.name ~= name then
                f.set_friend(other, false)
                f.set_cease_fire(other, false)
                other.set_friend(f, false)
                other.set_cease_fire(f, false)
            end
        end
    end
end

---A fresh empty table, for the per-team builders of `Public.tables()`.
---@return table
local function new_table()
    return {}
end

---The biter spawn types a side has not been shown yet at the start of a round.
---@return table<string, boolean>
local function unseen_biter_spawns()
    return {
        ['medium-spitter'] = true,
        ['medium-biter'] = true,
        ['big-spitter'] = true,
        ['big-biter'] = true,
        ['behemoth-spitter'] = true,
        ['behemoth-biter'] = true,
    }
end

---Creates a default settings structure
local function default_player_settings()
    return {
        --If disabled, then any item dropped into an inserter will be transferred
        --back to player inventory. e.g. Prevents a situation where a player can
        --accidentally clog a machine whose recipe doesn't accept a particular
        --ingredient. The setting has no effect on inserting fuel into burner-inserter
        --By default, setting is set to true as it's a vanilla behavior.
        ['inserter_drop'] = true,
    }
end

---Initializes player settings with defaults.
---@param player LuaPlayer
function Public.set_default_settings(player)
    storage.player_settings[player.name] = default_player_settings()
end

function Public.initial_setup()
    game.map_settings.enemy_evolution.time_factor = 0
    game.map_settings.enemy_evolution.destroy_factor = 0
    game.map_settings.enemy_evolution.pollution_factor = 0
    game.map_settings.pollution.enabled = false
    game.map_settings.enemy_expansion.enabled = false

    Pathfinder.apply()

    -- The teams, then their biters, then their boss biters, then the
    -- spectators: the creation order of the two-team scenario, and force
    -- indices depend on it (`storage.biter_health_factor` is keyed by index).
    -- `Public.tables()` has already run `Teams.begin_round()`, so this is the
    -- round's team list; forces for teams that only a later round needs are
    -- created by `Teams.ensure_forces()` in `Public.forces()`, after these.
    for _, team in ipairs(Teams.all()) do
        game.create_force(team)
    end
    for _, biter_force in ipairs(Teams.biter_forces()) do
        game.create_force(biter_force)
    end
    for _, boss_force in ipairs(Teams.boss_forces()) do
        game.create_force(boss_force)
    end
    game.create_force('spectator')

    local human_forces = { 'spectator' }
    for _, team in ipairs(Teams.all()) do
        human_forces[#human_forces + 1] = team
    end
    hide_system_surfaces(human_forces)
    game.forces.spectator.research_all_technologies()
    local defs = {
        defines.input_action.import_blueprint_string,
        defines.input_action.open_blueprint_library_gui,
    }
    local p = game.permissions.get_group('Default')
    for k, v in pairs(defs) do
        p.set_allows_action(v, false)
    end

    p = game.permissions.create_group('spectator')
    for action_name, _ in pairs(defines.input_action) do
        p.set_allows_action(defines.input_action[action_name], false)
    end

    defs = {
        defines.input_action.admin_action,
        defines.input_action.change_active_item_group_for_filters,
        defines.input_action.change_active_quick_bar,
        defines.input_action.change_multiplayer_config,
        defines.input_action.clear_cursor,
        defines.input_action.edit_permission_group,
        defines.input_action.gui_checked_state_changed,
        defines.input_action.gui_click,
        defines.input_action.gui_confirmed,
        defines.input_action.gui_elem_changed,
        defines.input_action.gui_location_changed,
        defines.input_action.gui_selected_tab_changed,
        defines.input_action.gui_selection_state_changed,
        defines.input_action.gui_switch_state_changed,
        defines.input_action.gui_text_changed,
        defines.input_action.gui_value_changed,
        defines.input_action.map_editor_action,
        defines.input_action.open_character_gui,
        defines.input_action.quick_bar_set_selected_page,
        defines.input_action.quick_bar_set_slot,
        defines.input_action.remote_view_surface,
        defines.input_action.set_filter,
        defines.input_action.set_player_color,
        defines.input_action.spawn_item,
        defines.input_action.start_walking,
        defines.input_action.toggle_map_editor,
        defines.input_action.toggle_show_entity_info,
        defines.input_action.write_to_console,
    }
    for _, d in pairs(defs) do
        p.set_allows_action(d, true)
    end

    storage.suspend_time_limit = 3600
    storage.automatic_captain_time_left = 0
    storage.reroll_time_limit = 45 * 60 -- 45 seconds
    storage.automatic_captain_time_limit = 45 * 60 -- 45 seconds
    storage.automatic_captain_time_to_start_it = 5 * 60 * 60 -- 5 minutes
    storage.automatic_captain_time_remaining_for_start = 5 * 60 * 60 -- 5 minutes
    storage.automatic_captain_prepa_time_to_start_it = 10 * 60 * 60 -- 10 minutes
    storage.automatic_captain_prepa_time_remaining_for_start = 10 * 60 * 60 -- 10 minutes
    storage.automatic_captain_min_connected_players_for_vote = 25

    storage.chart_queue = Queue.new()
    storage.feature_flags = {}
    storage.gui_refresh_delay = 0
    storage.bb_debug = false
    storage.bb_draw_revive_count_text = false
    storage.bb_show_research_info = 'always' -- "always", "spec", nil
    storage.ignore_lists = {}
    storage.reply_target = {}
    ---Stores player settings that persist through map resets.
    storage.player_settings = {}
    storage.bb_settings = {
        --TEAM SETTINGS--
        ['team_balancing'] = true, --Should players only be able to join a team that has less or equal members than the opposing team?
        ['only_admins_vote'] = false, --Are only admins able to vote on the global difficulty?
        ['science_send_score_restriction'] = true, --Require minimum build score to send science (scales with difficulty)
        --MAP SETTINGS--
        ['new_year_island'] = false,
        ['bb_map_reveal_toggle'] = true,
        -- false on the BB League server, written over this at `/tt-enable`
        -- (tt_mode_model.lua `league_bb_settings`).
        ['automatic_captain'] = true,
        ['map_reroll'] = true,
        ['burners_balance'] = true,
        ['classic_pathfinding'] = true,
        ['daytime_cycle'] = 'always_day',
    }
    storage.gui_theme = {}
    storage.want_pings = {}
    storage.want_pings_default_value = true
    storage.default_clear_corpses_radius = 160
    storage.total_time_online_players = {}
    storage.already_logged_current_session_time_online_players = {}
    ---Holds information about announcement
    ---@class AnnouncementData
    ---@field entity LuaEntity? Reference to speech-bubble entity
    ---@field text string? Text for speech-bubble
    storage.announcement = {}
    ---@type table<string, TeamstatsPreferences>
    storage.teamstats_preferences = {}
    storage.allow_teamstats = 'always'
    storage.allow_crafting_queue_list = 'spectators'
    --Flag for Player/quasi-admin mode.
    --When enabled, admins will automatically switch to Player/quasi-admin mode on joining a team.
    storage.quasi_admin_mode = false
    --Enables event profiler and logging
    storage.event_profiler_enabled = false
    --Disable Nauvis
    local surface = game.surfaces[1]
    local map_gen_settings = surface.map_gen_settings
    map_gen_settings.height = 3
    map_gen_settings.width = 3
    surface.map_gen_settings = map_gen_settings
    for chunk in surface.get_chunks() do
        surface.delete_chunk({ chunk.x, chunk.y })
    end
    for _, slot in ipairs(JAIL_SONG_SLOTS) do
        local force_name
        if slot.ring then
            force_name = active_team_at_ring(slot.ring)
        else
            force_name = 'spectator'
        end
        if force_name then
            createTrollSong(force_name, { x = slot.x, y = 0 })
        end
    end
    AiTargets.refresh_target_types()
end

--Terrain Playground Surface
function Public.playground_surface()
    local map_gen_settings = {}
    map_gen_settings.seed = storage.next_map_seed
    -- reset next_map_seed for next round
    storage.next_map_seed = 1
    Terrain.adjust_map_gen_settings(map_gen_settings)
    local surface = game.create_surface(storage.bb_surface_name, map_gen_settings)
    surface.brightness_visual_weights = { -1.17, -0.975, -0.52 }
    Daytime.apply_daytime_settings(surface)
end

---A team that has no silo cannot lose one, and the round ends when one team is
---left: on a map that gave only some of the teams a silo the others would be
---immortal and the round could never finish, reset or arm the restart timer.
---
---So, ABOVE TWO TEAMS ONLY, a team the map put no silo down for is out before
---the round starts. On the legacy two-team map that is east and west, and a
---three- or four-team round there degenerates to the two teams that do have a
---base rather than hanging for ever. On the four-square map every team gets a
---silo and this rule does not fire.
---
---Silently: the players have not joined yet and there is nobody to tell, so the
---only trace is one log line. Called at the end of `Public.draw_structures()`,
---the one point where the initial structures exist in both reset paths
---(`main.lua` on_init and `game_over.lua` `generate_new_map`).
local function eliminate_teams_without_a_silo()
    if Teams.count() <= 2 then
        return
    end
    local eliminated = {}
    for _, team in ipairs(Teams.all()) do
        local silos = storage.rocket_silo[team]
        if not silos or #silos == 0 then
            -- Out before the round started, so not ranked: `Teams.placement()`
            -- is a ranking of the teams that played, and a team with no base
            -- did not come last, it did not take part.
            Teams.eliminate(team, true)
            eliminated[#eliminated + 1] = team
        end
    end
    if #eliminated > 0 then
        log(
            'This map has no rocket silo for '
                .. table.concat(eliminated, ', ')
                .. ': eliminated before the round starts so that it can end.'
        )
    end
end

function Public.draw_structures()
    local surface = game.surfaces[storage.bb_surface_name]
    if Teams.layout() == 'cross4' then
        Terrain.generate_initial_structures_cross4(surface)
    else
        Terrain.generate_initial_structures(surface)
    end
    eliminate_teams_without_a_silo()
end

function Public.queue_reveal_map()
    local chart_queue = storage.chart_queue
    -- important to flush the queue upon resetting a map or chunk requests from previous maps could overlap
    Queue.clear(chart_queue)

    local width = 750 -- for one side (Carl 06/09: was 2000; smaller download, lighter autosaves)
    local height = 500 -- for one side
    if Teams.layout() == 'cross4' then
        -- Two halves become four quadrants, so the map is as tall as it is wide
        -- and the reveal is a square. The push loop below is already four-fold
        -- symmetric and needs nothing else.
        height = width
    end

    for x = 16, width, 32 do
        for y = 16, height, 32 do
            q_push(chart_queue, { { -x, -y }, { -x, -y } })
            q_push(chart_queue, { { x, -y }, { x, -y } })
            q_push(chart_queue, { { -x, y }, { -x, y } })
            q_push(chart_queue, { { x, y }, { x, y } })

            if x == 496 and y == 496 then
                -- request whole starting area at the end again to clear any charting hiccup
                q_push(chart_queue, { { -height, -height }, { height, height } })
            end
        end
        -- spectator island (guarantees sounds to be played during map reveal)
        q_push(chart_queue, { { -16, -16 }, { 16, 16 } })
    end
end

---Clears all feature flags and registers the classic pathfinding flag
---when a new game starts.
function Public.reset_feature_flags()
    storage.feature_flags = {}

    FeatureFlags.register_feature_flag(
        'classic_pathfinding_flag',
        'item/stone-wall',
        'Classic pathfinding enabled!\n' .. 'Classic pathfinding gives attacks simpler paths coming from nests',
        storage.bb_settings.classic_pathfinding
    )
end

---@param max_requests number
function Public.pop_chunk_request(max_requests)
    if not storage.bb_settings.bb_map_reveal_toggle then
        return
    end
    max_requests = max_requests or 1
    local chart_queue = storage.chart_queue
    local surface = game.surfaces[storage.bb_surface_name]
    local spectator = game.forces.spectator

    while max_requests > 0 and q_size(chart_queue) > 0 do
        spectator.chart(surface, q_pop(chart_queue))
        max_requests = max_requests - 1
    end
end

function Public.tables()
    -- The one point where the team count of a round changes: everything below
    -- is built for the teams it settles on, and so is everything `Public.forces()`
    -- does afterwards.
    Teams.begin_round()

    -- The chat commands of the teams outside the legacy pair. They are not
    -- registered at load, so that a two-team server keeps exactly today's
    -- command list, and appear the first time a round needs them -- in the same
    -- tick on the server and on every connected client, since they all run this
    -- reset; a client that joins later registers them from the same latch in
    -- `on_load` (commands/chat_commands.lua). The require is lazy: `commands.lua`
    -- loads that module long before this one, and a two-team round does not even
    -- look it up.
    if Teams.extra_chat_commands() then
        require('commands.chat_commands').register_extra_team_chat()
    end

    local get_score = Score.get_table()
    get_score.score_table = {}
    storage.research_info = { completed = {}, current_progress = Teams.per_team(new_table) }
    storage.science_logs_text = nil
    -- Every ROSTER team, not only the ones playing: after a four-team round
    -- `science_logs_total_east` and `..._west` would otherwise sit in the save
    -- for ever. Clearing a key that was never written is a no-op, so a save
    -- that only ever plays two teams clears exactly the two keys it has.
    for _, team in ipairs(Teams.roster()) do
        storage['science_logs_total_' .. team] = nil
    end
    ---@type TeamStats
    storage.team_stats = {
        forces = Teams.per_team(function()
            return { items = {}, food = {}, damage_types = {} }
        end),
    }
    storage.last_teamstats_print_at = 0
    -- Name of main BB surface within game.surfaces
    -- We hot-swap here between 2 surfaces.
    if storage.bb_surface_name == 'bb0' then
        storage.bb_surface_name = 'bb1'
    else
        storage.bb_surface_name = 'bb0'
    end

    storage.suspended_time = 36000
    storage.pings_to_remove = {}

    ---@class SuspendTargetInfo
    ---@field suspendee_player_name string
    ---@field suspendee_force_name string
    ---@field suspender_player_name string
    ---@field suspend_votes_by_player table<string, int>

    ---@type SuspendTargetInfo|nil
    storage.suspend_target_info = nil
    ---Name and tick suspended at
    ---@type table<string, int>
    storage.suspended_players = {}
    if storage.next_map_seed == nil or storage.next_map_seed < 341 then
        -- Seeds 1-341 inclusive are the same
        -- https://lua-api.factorio.com/latest/classes/LuaRandomGenerator.html#re_seed
        storage.next_map_seed = math.random(341, 4294967294)
    end
    storage.reroll_map_voting = {}
    storage.automatic_captain_voting = {}
    storage.bb_evolution = {}
    storage.benchmark_mode = false
    storage.bb_game_won_by_team = nil
    -- Written by the game-over path: it is
    -- cleared here so that the placement of a four-team round cannot outlive it
    -- into the save and into a later two-team round.
    storage.bb_placement = nil
    storage.bb_game_start_tick = nil
    storage.bb_threat = {}
    storage.bb_threat_income = {}
    storage.chosen_team = {}
    storage.got_burners = {}
    storage.combat_balance = {}
    storage.difficulty_player_votes = {}
    storage.evo_raise_counter = 1
    storage.force_area = {}
    storage.main_attack_wave_amount = 0
    storage.map_pregen_message_counter = {}
    ---Refers to primary silos, which is either the silo generated in spawn
    ---or any that's placed in multi-silo special.
    ---@type table<string, LuaEntity[]> The silos of each team, keyed by team name.
    storage.rocket_silo = Teams.per_team(new_table)
    storage.spectator_rejoin_delay = {}
    storage.spy_fish_timeout = {}
    storage.tm_custom_name = {}
    storage.total_passive_feed_redpotion = 0
    storage.pending_autofeed_counts = Teams.per_team(new_table)
    storage.unit_spawners = Teams.per_biter_force(new_table)
    ---@type table<integer, HighHealthUnit>
    storage.high_health_units = {}
    storage.ai_targets = {}
    storage.player_data_afk = {}
    storage.max_group_size_initial = 300 --Maximum unit group size for all biters at start, just used as a reference, doesnt change initial group size.
    --Maximum unit group size, per regular biter force. The boss forces are not
    --seeded, exactly as they were not before teams became a parameter.
    storage.max_group_size = Teams.per_biter_force(function()
        return 300
    end)
    --The spawn types a side has not been shown yet. Two key conventions live
    --here and both are kept: the regular biters are keyed by TEAM name and the
    --boss biters by BOSS FORCE name (ai.lua:187,198 reads them that way).
    storage.biter_spawn_unseen = Teams.per_team(unseen_biter_spawns)
    for _, team in ipairs(Teams.all()) do
        storage.biter_spawn_unseen[Teams.boss_force(team)] = unseen_biter_spawns()
    end
    storage.difficulty_vote_value = 0.75
    storage.difficulty_vote_index = 4

    storage.difficulty_votes_timeout = 36000
    storage.threat_multiplier = nil

    -- Maximum evolution threshold after which biters have 100% chance
    -- to reanimate. The reanimation starts after evolution factor reaches
    -- 100, so this value starts having an effect only at that point.
    -- To reach 100% reanimation chance at 200% evolution, set it to 100.
    -- To reach 100% reanimation chance at 350% evolution, set it to 250.
    -- This is used to calculate biter_health_factor.
    storage.max_reanim_thresh = 250

    -- Container for storing health factor, accessed by key with force's index.
    ---@type table<integer, number>
    storage.biter_health_factor = {}

    storage.bb_pathfinder = storage.bb_pathfinder or Pathfinder.get_preset('bb-new')

    local rng = game.create_random_generator(storage.next_map_seed)
    local active = Teams.all()
    if Teams.count() == 2 then
        -- The draw of the two-team scenario, kept expression for expression:
        -- ONE `rng(1, 2)`, and a result of 1 means the SECOND team, not the
        -- first. `active[rng(1, #active)]` would flip the first attacker on
        -- every seed.
        storage.next_attack = active[1]
        if rng(1, 2) == 1 then
            storage.next_attack = active[2]
        end
    else
        storage.next_attack = active[rng(1, #active)]
    end

    -- Clear all ping UIs.  Otherwise, if a map reset happens when a ping is
    -- visible, it will be permanently visible.
    for _, player in pairs(game.connected_players) do
        local ping_messages = player.gui.screen.ping_messages
        if ping_messages then
            ping_messages.destroy()
        end
        local ping_header = player.gui.screen.ping_header
        if ping_header then
            ping_header.destroy()
        end
    end
    -- Threat nerf from non positive biters.
    -- Inserted ids of biters are from positive threat generation.
    -- Readed when enemy is killed.
    -- Cleared when biter of this id dies.
    ---@type { [integer]: true }
    storage.biters_from_positive_threat = {}

    storage.gui_bb_pause_cooldown = 0

    -- tt_mode: re-apply 80% lock, reset accumulators, etc. on soft-reset.
    -- on_map_reset is a no-op if tt_mode is off, so this is safe vanilla-wise.
    require('maps.biter_battles_v2.tt_mode').on_map_reset()
end

function Public.forces()
    -- Teams that this round needs and earlier rounds did not: their forces are
    -- created here, after the ones `initial_setup()` made, so no existing force
    -- index moves. A two-team round creates nothing.
    for _, team in ipairs(Teams.ensure_forces()) do
        setup_new_team_force(team)
    end

    for _, force in pairs(game.forces) do
        if force.name ~= 'spectator' then
            force.reset()
            force.reset_evolution()
        end
    end

    -- Relations only accumulate: everything below sets TRUE and the `reset()`
    -- above does not clear diplomacy. Whatever a round of another size left on
    -- the forces it is no longer playing with goes first, so that the matrix
    -- this round ends up with is the matrix this round built. Not one API call
    -- in a save that never played more than two teams.
    clear_dormant_team_relations()

    local surface = game.surfaces[storage.bb_surface_name]
    local teams = Teams.all()

    -- Every biter force of the round, the regular ones first and then the
    -- bosses: `north_biters, south_biters, north_biters_boss, south_biters_boss`
    -- for two teams.
    ---@type { name: string, team: string }[]
    local biters = {}
    for _, team in ipairs(teams) do
        biters[#biters + 1] = { name = Teams.biter_force(team), team = team }
    end
    for _, team in ipairs(teams) do
        biters[#biters + 1] = { name = Teams.boss_force(team), team = team }
    end

    -- A team: friend with the spectators and with every biter force but its own
    -- two, at cease-fire with the vanilla player force.
    for _, team in ipairs(teams) do
        local f = game.forces[team]
        f.set_spawn_position(team_spawn_position(team), surface)
        f.set_cease_fire('player', true)
        f.set_friend('spectator', true)
        for _, biter in ipairs(biters) do
            if biter.team ~= team then
                f.set_friend(biter.name, true)
            end
        end
        f.share_chart = true
    end

    -- A biter force: friend with every other biter force, with every team but
    -- the one it hunts, and with the player and spectator forces.
    for _, biter in ipairs(biters) do
        local f = game.forces[biter.name]
        for _, other in ipairs(biters) do
            if other.name ~= biter.name then
                f.set_friend(other.name, true)
            end
        end
        for _, team in ipairs(teams) do
            if team ~= biter.team then
                f.set_friend(team, true)
            end
        end
        f.set_friend('player', true)
        f.set_friend('spectator', true)
        f.share_chart = false
    end

    -- The spectators and the vanilla player force. Both know the regular biter
    -- forces and not the boss ones: that asymmetry is the scenario's and is
    -- reproduced, not repaired.
    local f = game.forces['spectator']
    f.set_spawn_position({ 0, 0 }, surface)
    f.technologies['toolbelt'].researched = true
    for _, team in ipairs(teams) do
        f.set_cease_fire(Teams.biter_force(team), true)
    end
    for _, team in ipairs(teams) do
        f.set_friend(team, true)
    end
    f.set_cease_fire('player', true)
    f.share_chart = true

    f = game.forces['player']
    f.set_spawn_position({ 0, 0 }, surface)
    f.set_cease_fire('spectator', true)
    for _, team in ipairs(teams) do
        f.set_cease_fire(Teams.biter_force(team), true)
    end
    for _, team in ipairs(teams) do
        f.set_cease_fire(team, true)
    end
    f.share_chart = false

    for _, force in pairs(game.forces) do
        game.forces[force.name].technologies['artillery'].enabled = false
        game.forces[force.name].technologies['artillery-shell-range-1'].enabled = false
        game.forces[force.name].technologies['artillery-shell-speed-1'].enabled = false
        game.forces[force.name].technologies['atomic-bomb'].enabled = false
        game.forces[force.name].technologies['cliff-explosives'].enabled = false
        game.forces[force.name].technologies['land-mine'].enabled = false
        storage.ai_targets[force.name] = { available = {}, available_list = {} }
        storage.ai_target_destroyed_map = {}
        storage.spy_fish_timeout[force.name] = 0
        storage.bb_evolution[force.name] = 0
        storage.biter_health_factor[force.index] = 1.0
        storage.bb_threat_income[force.name] = 0
        storage.bb_threat[force.name] = 0
    end
    -- `Tables.ammo_modified_forces_list` for this round: the teams, then the
    -- spectators. The constant in tables.lua is the two-team value of the same
    -- list and is left where it is.
    local ammo_modified_forces = {}
    for i, team in ipairs(teams) do
        ammo_modified_forces[i] = team
    end
    ammo_modified_forces[#ammo_modified_forces + 1] = 'spectator'

    for _, force in ipairs(ammo_modified_forces) do
        for ammo_category, value in pairs(Tables.base_ammo_modifiers) do
            game.forces[force].set_ammo_damage_modifier(ammo_category, value)
        end
    end

    for _, force in ipairs(ammo_modified_forces) do
        for turret_category, value in pairs(Tables.base_turret_attack_modifiers) do
            game.forces[force].set_turret_attack_modifier(turret_category, value)
        end
    end
end

return Public
