local Admin = require('utils.admin')
local BBGui = require('maps.biter_battles_v2.gui')
local Captain_special = require('comfy_panel.special_games.captain')
local MultiSilo = require('comfy_panel.special_games.multi_silo')
local Color = require('utils.color_presets')
local Event = require('utils.event')
local Functions = require('maps.biter_battles_v2.functions')
local CraftingList = require('commands.crafting_queue_list')
local Gui = require('utils.gui')
local Init = require('maps.biter_battles_v2.init')
local MatchFormat = require('maps.biter_battles_v2.match_format')
local Report = require('maps.biter_battles_v2.game_over_report')
local Score = require('comfy_panel.score')
local Server = require('utils.server')
local Special_games = require('comfy_panel.special_games')
local Teams = require('maps.biter_battles_v2.teams')
local Announce = require('commands.announce')
local Task = require('utils.task')
local Token = require('utils.token')
local team_stats_compare = require('maps.biter_battles_v2.team_stats_compare')
local gui_style = require('utils.utils').gui_style

local math_sqrt = math.sqrt
local math_random = math.random
local math_floor = math.floor

local Public = {}

function Public.reveal_map()
    -- The teams of the round, then the two non-team forces that see the map:
    -- with two teams this is the list this replaces, in its order.
    local forces = {}
    for _, team in ipairs(Teams.all()) do
        forces[#forces + 1] = team
    end
    forces[#forces + 1] = 'player'
    forces[#forces + 1] = 'spectator'
    for _, f in pairs(forces) do
        local r = 768
        game.forces[f].chart(game.surfaces[storage.bb_surface_name], { { r * -1, r * -1 }, { r, r } })
    end
end

---@param surface LuaSurface
---@param origin { x: number, y: number }
---Spawn fishes around origin point
local function drop_fish(surface, origin)
    local req = {
        position = { 0, 0 },
        stack = { name = 'raw-fish', count = 1 },
        enable_looted = false,
        allow_belts = true,
    }

    ---Maximum radius around the origin where fish might drop
    local RADIUS = 32
    -- Lower the radius in case it's multisilo, so that if there are lots of silos placed
    -- next to each other and they blow up - we don't have to look as intensely for
    -- non-colliding position to spawn fish.
    if not MultiSilo.is_disabled() then
        RADIUS = 12
    end

    local RADIUS_SQ = RADIUS * RADIUS
    ---Controls how quickly density decreases with distance from origin
    local DENSITY_FALLOFF = 1.2
    ---Scales fish count
    local SCALING_FACTOR = 0.28
    ---Random sub-tile jitter, up to 0.9 in steps of 0.1
    local POSITION_JITTER_MAX = 9

    for dx = -RADIUS, RADIUS, 1 do
        for dy = -RADIUS, RADIUS, 1 do
            local dist_sq = dx * dx + dy * dy
            -- Is the point NOT within the radius
            if dist_sq >= RADIUS_SQ then
                goto drop_fish_cont
            end

            ---Distance to silo
            local dist = math_sqrt(dist_sq)
            ---Amount of fish to scatter
            local count = math_floor((RADIUS - dist * DENSITY_FALLOFF) * SCALING_FACTOR)
            if count <= 0 then
                goto drop_fish_cont
            end

            local px, py = origin.x + dx, origin.y + dy
            for _ = 1, count do
                req.position[1] = px + math_random(0, POSITION_JITTER_MAX) * 0.1
                req.position[2] = py + math_random(0, POSITION_JITTER_MAX) * 0.1
                surface.spill_item_stack(req)
            end

            ::drop_fish_cont::
        end
    end
end

local function silo_kaboom(entity)
    local surface = entity.surface
    local center_position = entity.position
    local force = entity.force.name .. '_biters'
    local req = {
        name = 'atomic-rocket',
        position = center_position,
        force = force,
        source = center_position,
        target = center_position,
        max_range = 1,
        speed = 0.1,
    }

    surface.create_entity(req)
    drop_fish(surface, center_position)
end

local function get_sorted_list(column_name, score_list)
    for _ = 1, #score_list, 1 do
        for y = 1, #score_list, 1 do
            if not score_list[y + 1] then
                break
            end
            if score_list[y][column_name] < score_list[y + 1][column_name] then
                local key = score_list[y]
                score_list[y] = score_list[y + 1]
                score_list[y + 1] = key
            end
        end
    end
    return score_list
end

local function get_mvps(force)
    local get_score = Score.get_table().score_table
    if not get_score[force] then
        return false
    end
    local score = get_score[force]
    local score_list = {}
    for _, p in pairs(game.players) do
        if score.players[p.name] then
            local killscore = 0
            if score.players[p.name].killscore then
                killscore = score.players[p.name].killscore
            end
            local deaths = 0
            if score.players[p.name].deaths then
                deaths = score.players[p.name].deaths
            end
            local built_entities = 0
            if score.players[p.name].built_entities then
                built_entities = score.players[p.name].built_entities
            end
            local mined_entities = 0
            if score.players[p.name].mined_entities then
                mined_entities = score.players[p.name].mined_entities
            end
            table.insert(score_list, {
                name = p.name,
                killscore = killscore,
                deaths = deaths,
                built_entities = built_entities,
                mined_entities = mined_entities,
            })
        end
    end
    local mvp = {}
    score_list = get_sorted_list('killscore', score_list)
    mvp.killscore = { name = score_list[1].name, score = score_list[1].killscore }
    score_list = get_sorted_list('deaths', score_list)
    mvp.deaths = { name = score_list[1].name, score = score_list[1].deaths }
    score_list = get_sorted_list('built_entities', score_list)
    mvp.built_entities = { name = score_list[1].name, score = score_list[1].built_entities }
    return mvp
end

---The name a team's end-game panel is titled with. With two teams it is the
---force name capitalised, which is exactly the 'North' / 'South' of the two
---hand-written MVP blocks this file used to carry -- derived rather than
---spelled out. The four-square layout uses the positional display name, because
---a compass word would point at the wrong corner there.
---@param team string
---@return string
local function team_title(team)
    if Teams.count() == 2 then
        return string.upper(string.sub(team, 1, 1)) .. string.sub(team, 2)
    end
    return Teams.display_name(team)
end

---The same name upper-cased: today's 'NORTH' / 'SOUTH' of the Discord headers.
---@param team string
---@return string
local function team_title_caps(team)
    return string.upper(team_title(team))
end

---Font colours of the MVP panels of the two-team layout: the literals of the
---two blocks this file used to carry. They are NOT the registry colours divided
---by 255, and repainting today's end-game panel is not part of this work, so
---they are kept -- listed by ring position (1 = first team of the ring, 3 =
---third) so that no team name is written out here.
local legacy_mvp_font_color = {
    [1] = { r = 0.55, g = 0.55, b = 0.99 },
    [3] = { r = 0.99, g = 0.33, b = 0.33 },
}

---@param team string
---@return { r: number, g: number, b: number }
local function mvp_font_color(team)
    if Teams.count() == 2 then
        local legacy = legacy_mvp_font_color[Teams.ring_index(team)]
        if legacy then
            return { r = legacy.r, g = legacy.g, b = legacy.b }
        end
    end
    local rgb = Teams.color(team)
    if not rgb then
        return { r = 1, g = 1, b = 1 }
    end
    return { r = rgb.r / 255, g = rgb.g / 255, b = rgb.b / 255 }
end

---Where a team came in the round that has just ended, read off the placement
---the game-over path recorded. nil for a team that never played -- the map gave
---it no silo, so it is not ranked -- and nil before there is a placement at all.
---@param team string
---@return integer|nil
local function placement_of(team)
    local placement = storage.bb_placement
    if not placement then
        return nil
    end
    for i = 1, #placement do
        if placement[i] == team then
            return i
        end
    end
    return nil
end

---One team's MVP panel, and once per team and per game its Discord embed.
---Called for every team of the round in `Teams.all()` order; with two teams it
---reproduces the two hand-written blocks it replaces element for element,
---caption for caption and byte for byte.
---@param sp LuaGuiElement The scroll pane of the MVP section.
---@param team string
---@param category_style table
---@param winner_style table
local function add_mvp_panel(sp, team, category_style, winner_style)
    local mvp = get_mvps(team)
    if not mvp then
        return
    end

    -- Above two teams the block says where its team came. The panel names only
    -- the winner, and 'Top Left:' over a dead team's MVPs says nothing about
    -- the round it lost; with the ranking the four blocks read as a result
    -- table. With two teams the heading is today's 'North:' and today's
    -- 'NORTH: \\n', from the same two calls as before.
    local heading, heading_caps = team_title(team), team_title_caps(team)
    if Teams.count() > 2 then
        local place = placement_of(team)
        if place then
            heading = Report.placed_title(heading, place)
            heading_caps = string.upper(heading)
        end
    end

    local f = sp.add({
        type = 'frame',
        style = 'bordered_frame',
        direction = 'vertical',
        caption = heading .. ':',
    })
    gui_style(f, { font = 'default-listbox', font_color = mvp_font_color(team) })

    local t = f.add({ type = 'table', column_count = 2 })

    local l = t.add({ type = 'label', caption = 'Defender >> ' })
    gui_style(l, category_style)

    local l = t.add({ type = 'label', caption = mvp.killscore.name .. ' with a score of ' .. mvp.killscore.score })
    gui_style(l, winner_style)

    local l = t.add({ type = 'label', caption = 'Builder >> ' })
    gui_style(l, category_style)

    local l = t.add({
        type = 'label',
        caption = mvp.built_entities.name .. ' built ' .. mvp.built_entities.score .. ' things',
    })
    gui_style(l, winner_style)

    local l = t.add({ type = 'label', caption = 'Deaths >> ' })
    gui_style(l, category_style)

    local l = t.add({ type = 'label', caption = mvp.deaths.name .. ' died ' .. mvp.deaths.score .. ' times' })
    gui_style(l, winner_style)

    local results_sent_key = 'results_sent_' .. team
    if not storage[results_sent_key] then
        local result = {}
        table.insert(result, heading_caps .. ': \\n')
        table.insert(result, 'MVP Defender: \\n')
        table.insert(result, mvp.killscore.name .. ' with a score of ' .. mvp.killscore.score .. '\\n')
        table.insert(result, '\\n')
        table.insert(result, 'MVP Builder: \\n')
        table.insert(result, mvp.built_entities.name .. ' built ' .. mvp.built_entities.score .. ' things\\n')
        table.insert(result, '\\n')
        table.insert(result, 'MVP Deaths: \\n')
        table.insert(result, mvp.deaths.name .. ' died ' .. mvp.deaths.score .. ' times')
        local message = table.concat(result)
        Server.to_discord_embed(message)
        storage[results_sent_key] = true
    end
end

local function show_endgame_gui(player)
    local get_score = Score.get_table().score_table
    if not get_score then
        return
    end
    if Gui.get_left_element(player, 'mvps') then
        return
    end
    local category_style = { font = 'default-listbox', font_color = { r = 0.22, g = 0.77, b = 0.44 } }
    local winner_style = { font = 'default-bold', font_color = { r = 0.33, g = 0.66, b = 0.9 } }

    local main_frame = Gui.add_left_element(player, { type = 'frame', name = 'mvps', direction = 'vertical' })
    gui_style(main_frame, {
        horizontally_stretchable = false,
    })
    local flow = main_frame.add({ type = 'flow', style = 'vertical_flow', direction = 'vertical' })
    local inner_frame = flow.add({ type = 'frame', style = 'inside_shallow_frame_packed', direction = 'vertical' })

    do -- Game overview
        local subheader = inner_frame.add({ type = 'frame', style = 'subheader_frame' })
        gui_style(subheader, {
            horizontally_squashable = true,
            use_header_filler = true,
            vertically_stretchable = true,
            minimal_height = 36,
            maximal_height = 180,
        })

        local icon = subheader.add({
            type = 'sprite-button',
            sprite = 'utility/side_menu_achievements_icon',
            style = 'transparent_slot',
        })
        Gui.add_pusher(subheader)

        local label =
            subheader.add({ type = 'label', caption = Functions.team_name(storage.bb_game_won_by_team) .. ' won!' })
        gui_style(
            label,
            { font = 'heading-2', font_color = { 165, 165, 165 }, single_line = false, maximal_width = 280, margin = 4 }
        )

        Gui.add_pusher(subheader)
        local icon = subheader.add({
            type = 'sprite-button',
            sprite = 'utility/side_menu_achievements_icon',
            style = 'transparent_slot',
        })

        local sp =
            inner_frame.add({ type = 'scroll-pane', style = 'scroll_pane_under_subheader', direction = 'vertical' })

        local l = sp.add({ type = 'label', style = 'caption_label', caption = storage.victory_time })
        gui_style(l, { left_padding = 8 })

        -- Who played the round. Above two teams `eliminate_team` forgets the
        -- team choice of every player of the team it kills, and the last loser
        -- never goes through it (the winner branch returns before it), so by the
        -- end of a four-team round `chosen_team` holds the winner's and the
        -- runner-up's players and nobody else -- half the round. The players who
        -- played are those plus the ones an elimination marked, and the two sets
        -- are disjoint: every mark forgets the choice in the same breath and
        -- `join_team` refuses a marked player from then on. A two-team round
        -- never clears anything and never marks anybody, so it keeps today's
        -- expression, verbatim.
        local total_players = table_size(storage.chosen_team)
        if Teams.count() > 2 then
            total_players = total_players + table_size(Teams.state().eliminated_players)
        end
        local l = sp.add({
            type = 'label',
            style = 'caption_label',
            caption = 'Total players - ' .. total_players,
        })
        gui_style(l, { left_padding = 8 })
    end

    do -- MVPs
        local subheader = inner_frame.add({ type = 'frame', style = 'subheader_frame' })
        gui_style(subheader, { horizontally_squashable = true, maximal_height = 40, use_header_filler = true })

        local icon =
            subheader.add({ type = 'sprite-button', sprite = 'utility/empty_armor_slot', style = 'transparent_slot' })
        Gui.add_pusher(subheader)

        local label = subheader.add({ type = 'label', caption = 'MVPs' })
        gui_style(label, { font = 'default-semibold', font_color = { 165, 165, 165 }, left_margin = 4 })

        Gui.add_pusher(subheader)
        local icon =
            subheader.add({ type = 'sprite-button', sprite = 'utility/empty_armor_slot', style = 'transparent_slot' })

        local sp =
            inner_frame.add({ type = 'scroll-pane', style = 'scroll_pane_under_subheader', direction = 'vertical' })

        -- Two teams: ring order, today's panel. Above two teams the blocks are
        -- headed 'Top Left - 3rd place' and read top to bottom as a ranking, so
        -- they follow the placement (winner first), then any team that never
        -- played.
        local mvp_teams = Teams.all()
        if Teams.count() > 2 then
            mvp_teams = Report.placement_order(mvp_teams, storage.bb_placement)
        end
        for _, team in ipairs(mvp_teams) do
            add_mvp_panel(sp, team, category_style, winner_style)
        end
    end
end

function Public.server_restart()
    if not storage.server_restart_timer then
        return
    end
    storage.server_restart_timer = storage.server_restart_timer - 5

    if storage.server_restart_timer <= 0 then
        if storage.restart then
            if not storage.announced_message then
                local message = 'Soft-reset is disabled! Server will restart from scenario to load new changes.'
                game.print(message, { color = { r = 0.22, g = 0.88, b = 0.22 } })
                Server.to_discord_bold(table.concat({ '*** ', message, ' ***' }))
                Server.start_scenario('Biter_Battles')
                storage.announced_message = true
                return
            end
        end
        if storage.shutdown then
            if not storage.announced_message then
                local message = 'Soft-reset is disabled! Server will shutdown. Most likely because of updates.'
                game.print(message, { color = { r = 0.22, g = 0.88, b = 0.22 } })
                Server.to_discord_bold(table.concat({ '*** ', message, ' ***' }))
                Server.stop_scenario()
                storage.announced_message = true
                return
            end
        end
        game.print('Map is restarting!', { color = { r = 0.22, g = 0.88, b = 0.22 } })
        local message = 'Map is restarting! '
        Server.to_discord_bold(table.concat({ '*** ', message, ' ***' }))

        Public.generate_new_map()
        return
    end
    if storage.server_restart_timer % 30 == 0 then
        game.print(
            'Map will restart in ' .. storage.server_restart_timer .. ' seconds!',
            { color = { r = 0.22, g = 0.88, b = 0.22 } }
        )
        if storage.server_restart_timer / 30 == 1 then
            game.print('Good luck with your next match!', { color = { r = 0.98, g = 0.66, b = 0.22 } })
        end
    end
end

local function set_victory_time()
    local tick = Functions.get_ticks_since_game_start()
    local minutes = tick % 216000
    local hours = tick - minutes
    minutes = math.floor(minutes / 3600)
    hours = math.floor(hours / 216000)
    storage.victory_time =
        table.concat({ 'Time - ', hours > 0 and (hours .. ' hours and ') or '', minutes, ' minutes' })
end

---@param surface LuaSurface
---@param force_names string[] The biter forces to stop.
local function freeze_biter_forces(surface, force_names)
    local filter = {
        force = force_names,
    }

    for _, e in pairs(surface.find_entities_filtered(filter)) do
        if e.name ~= 'atomic-rocket' then
            e.active = false
        end
    end
end

---Stop every biter of the round: the regular forces of the teams in `all()`
---order, then their boss forces. With two teams that is exactly the four names,
---in the order, of the literal list this replaces.
---@param surface LuaSurface
local function freeze_all_biters(surface)
    local force_names = {}
    for _, name in ipairs(Teams.biter_forces()) do
        force_names[#force_names + 1] = name
    end
    for _, name in ipairs(Teams.boss_forces()) do
        force_names[#force_names + 1] = name
    end
    freeze_biter_forces(surface, force_names)
end

---Stop the biters of one team only -- the elimination step of a 3-4 team round,
---where the surviving teams keep playing.
---@param surface LuaSurface
---@param team string
local function freeze_team_biters(surface, team)
    freeze_biter_forces(surface, { Teams.biter_force(team), Teams.boss_force(team) })
end

---A team lost its last silo while others are still playing (3-4 teams only):
---announce it, stop its biters, stop its threat income AND empty the threat
---pool that income had already bought, blind its spy fish and move its
---connected players to the spectator force. The round goes on, so
---`storage.bb_game_won_by_team` stays nil and none of the game-over sequence
---runs. Unreachable with two teams, where the first silo loss always leaves
---exactly one team standing.
---@param team string
---@param surface LuaSurface
local function eliminate_team(team, surface)
    -- `Teams.eliminate(team)` has already run, so the team is off the alive list
    -- and is the last of the eliminations: the place it takes is the number of
    -- teams that were still playing when its silo fell.
    local place = Report.place_of(Teams.state().eliminated, #Teams.alive(), team)
    local message = Report.elimination_message(team_title(team), place)
    game.print(message, { color = { r = 0.98, g = 0.66, b = 0.22 } })
    Server.to_discord_bold(table.concat({ '*** ', message, ' ***' }))

    freeze_team_biters(surface, team)
    local biter_force = Teams.biter_force(team)
    storage.bb_threat_income[biter_force] = 0
    -- A frozen pool is still a pool: the 60-tick loop would keep it, the wave
    -- dispatcher would keep counting it and a rejoining wave could still spend
    -- it. The team is out, so the threat it saved up goes with it.
    storage.bb_threat[biter_force] = 0
    storage.spy_fish_timeout[team] = game.tick + 999999

    -- Everyone who played for the team, connected or not: their team choice is
    -- forgotten before they are moved, exactly as `team_manager.switch_force`
    -- does it, and they are recorded as out for the rest of the round. Without
    -- the first the Resume button would put them straight back on the dead
    -- force; without the second the empty choice would let them pick a living
    -- team instead. An offline player is only marked -- `spectate` needs a
    -- character and there is nothing to move until they come back.
    for _, player in pairs(game.forces[team].players) do
        storage.chosen_team[player.name] = nil
        Teams.mark_player_eliminated(player.name, team)
    end
    -- ... and everyone who played for it but was WATCHING when the silo fell:
    -- `spectate()` moves the force and leaves the choice alone, so a player who
    -- pressed Spectate first is not in the list above and would keep a Resume
    -- button onto the dead team. Clear by choice as well as by force. `pairs`
    -- over a player-name-keyed table is safe here: every write is to a distinct
    -- key and nothing in the body prints, draws or draws a random number.
    for name, chosen in pairs(storage.chosen_team) do
        if chosen == team then
            storage.chosen_team[name] = nil
            Teams.mark_player_eliminated(name, team)
        end
    end
    -- The public line says a team is out; this one says it to the people it
    -- happened to, who have just been teleported to the spectator island with
    -- no explanation of their own. The rest of the round is still worth
    -- watching, and the panel's Join row is gone for them (gui.lua), so say so.
    local private = Report.eliminated_player_message(place)
    for _, player in pairs(game.forces[team].connected_players) do
        spectate(player, true)
        player.print(private, { color = { r = 0.98, g = 0.66, b = 0.22 } })
    end
end

---The League's last safety net: a team of a 3-4 team round that
---has NO player at all when the match is about to start is closed, never left
---alive and empty -- an empty team takes its share of every send and dies to
---its own biters. "Closed" is what the map does to a team it gave no silo
---(`Teams.eliminate(team, true)`): out of the alive set, so no share of the
---sends and idle attack turns, and NOT ranked -- it did not come last, it did
---not take part. On top of that its biters are frozen, its threat is emptied
---and its silo can no longer die.
---
---Never automatic: the daemon calls it just before GO
---(`remote.call('bb_teams', 'close_empty_teams')`), an admin types
---`/team-count close-empty`. A team counts as empty when its force has no
---player, connected or not -- a roster player who is merely offline is the
---daemon's no-show rule, not this one. Refused, and nothing is closed, in a
---two-team round, once the round is won, and when fewer than two teams would
---be left.
---@return string[]|nil closed The teams closed by this call, in ring order (may be empty).
---@return string|nil reason Why the call was refused, when it was.
function Public.close_empty_teams()
    if Teams.count() <= 2 then
        return nil, 'a two-team round has no team to close'
    end
    if storage.bb_game_won_by_team then
        return nil, 'the round is over'
    end

    local empty, manned = {}, 0
    for _, team in ipairs(Teams.alive()) do
        local force = game.forces[team]
        if force and #force.players > 0 then
            manned = manned + 1
        else
            empty[#empty + 1] = team
        end
    end
    if manned < 2 then
        return nil, 'fewer than two teams have players'
    end

    local surface = game.surfaces[storage.bb_surface_name]
    for _, team in ipairs(empty) do
        Teams.eliminate(team, true)
        if surface then
            freeze_team_biters(surface, team)
        end
        local biter_force = Teams.biter_force(team)
        storage.bb_threat_income[biter_force] = 0
        storage.bb_threat[biter_force] = 0
        storage.spy_fish_timeout[team] = game.tick + 999999
        for _, silo in pairs(storage.rocket_silo[team] or {}) do
            if silo.valid then
                silo.destructible = false
            end
        end
        local message = 'Team ' .. team_title(team) .. ' has no player: it is closed for this round.'
        game.print(message, { color = { r = 0.98, g = 0.66, b = 0.22 } })
        log({ '', '[TEAM-CLOSED] ', team })
    end
    return empty
end

---A player who was away when their team died is still standing on the dead
---force: `eliminate_team` moves the players who are connected and there is
---nothing to move for the others until they come back. This is that move, made
---on their way back in, with the private line the rest of their team got.
---
---Above two teams only, as the elimination step itself is: a two-team round
---marks nobody, so the first test alone keeps today's join path untouched.
---@param player LuaPlayer
function Public.spectate_if_eliminated(player)
    if Teams.count() == 2 or not Teams.is_player_eliminated(player.name) then
        return
    end
    -- They are refused every living team while the mark stands, so the only
    -- force they can be on is the one that died -- unless an admin put them
    -- somewhere with the team manager, and that is the admin's business.
    local team = player.force.name
    if not Teams.is_active(team) or Teams.is_alive(team) then
        return
    end

    spectate(player, true)
    local place = Report.place_of(Teams.state().eliminated, #Teams.alive(), team)
    player.print(Report.eliminated_player_message(place), { color = { r = 0.98, g = 0.66, b = 0.22 } })
end

local function biter_damage_source(event)
    local force = event.force
    if force ~= nil then
        return string.find(event.force.name, '_biters')
    end

    local cause = event.cause
    if cause ~= nil then
        return (cause.valid and cause.type == 'unit')
    end

    log('Could not determine what destroyed the silo')
    return false
end

local function log_to_db(message, appendBool)
    helpers.write_file('logToDBgameResult', message, appendBool, 0)
end

---@param silo LuaEntity
---@param list LuaEntity[]
---Go through list of silos and return its index or nil.
---@return integer|nil
local function get_silo(silo, list)
    for index, entry in ipairs(list) do
        if silo == entry then
            return index
        end
    end

    return nil
end

---@param silo LuaEntity
---Searches for position and list where silo is stored.
---Returns index of a silo in the list and reference to the list.
---@return [integer, LuaEntity[]]|nil
local function find_silo_ref(silo)
    ---@type integer|nil
    local index = nil
    ---@type LuaEntity[]|nil
    local list = nil
    for _, force in pairs(game.forces) do
        local f_name = force.name
        list = storage.rocket_silo[f_name]
        -- If no list, then not a valid force.
        if list == nil then
            goto find_silo_ref_loop
        end

        -- If silo tracked, break
        index = get_silo(silo, list)
        if index ~= nil then
            return { index, list }
        end

        ::find_silo_ref_loop::
    end

    return nil
end

---@param event LuaOnEntityDamaged
---Activated on final hit to the rocket-silo. We check if the hit was
---coming from biter source, if not we add health to entity to keep it
---alive.
function Public.on_entity_damaged(event)
    local entity = event.entity
    local ref = find_silo_ref(entity)
    if ref == nil then
        return
    end

    -- If biter wasn't cause of damage, then add health to silo as anti griefer mechanism.
    if not biter_damage_source(event) then
        entity.health = 5
        return
    end
end

---The `[MATCH-RESULT]` record of the round that has just ended: every playing
---team in ring order with its place and the tick its silo fell on, the winner,
---the two ticks of the round, and -- only when the league wrote a record -- the
---format that record was read as.
---
---`display_name` is the registry's name for the team, which above two teams is
---the very name the chat lines and the end-game panel use. The teams eliminated
---before the round began are in the list with neither a place nor a tick: they
---were dealt in and never played.
---@param teams string[] The round's teams, in `Teams.all()` order.
---@param placement string[] Team names, winner first.
---@return table
local function match_result(teams, placement)
    local ticks = {}
    for _, elimination in ipairs(Teams.state().eliminated) do
        ticks[elimination.team] = elimination.tick
    end

    -- Who played for each team. By the time the round ends the players of a
    -- dead team are spectators with their choice cleared, so the force's own
    -- list cannot say it: `LeagueState.roster_of` merges the mark left at the
    -- elimination, the force's players and the watchers' choice -- the very
    -- list `match_info` gives as `teams[].roster`. A lookup, not a load:
    -- `control.lua` has replaced `require` by the time a round ends.
    local LeagueState = require('maps.biter_battles_v2.league_state')

    local entries = {}
    for i = 1, #teams do
        local team = teams[i]
        entries[i] = {
            name = team,
            display_name = Teams.display_name(team),
            eliminated_tick = ticks[team],
            players = LeagueState.roster_of(team),
        }
    end

    -- `version` is nil exactly when there is no record to read; the key a record
    -- is read through is the one the league's parameters are stored under
    -- (match_format.lua:369-381), and it is what this scenario played by.
    local info = MatchFormat.match_info()
    return Report.match_result({
        teams = entries,
        placement = placement,
        winner = storage.bb_game_won_by_team,
        game_start_tick = storage.bb_game_start_tick,
        game_end_tick = game.tick,
        format = info.version and info.format_key or nil,
        -- The same match as players read it ('2v2v2'). `format` above stays the
        -- two-part key of the parameter set this scenario played by.
        format_label = info.version and MatchFormat.format_label() or nil,
    })
end

---@param entity LuaEntity
---Activated on any rocket-silo death. If the silo is tracked as objective
---then we explode it and check if it was a last one in given force. If yes
---then game is concluded.
function Public.on_entity_died(entity)
    if storage.bb_game_won_by_team then
        return
    end

    local ref = find_silo_ref(entity)
    if ref == nil then
        return
    end

    -- The only way to destroy the silo is to make last hit from biter force.
    local index, list = ref[1], ref[2]
    table.remove(list, index)
    silo_kaboom(entity)

    -- Check if it was last silo. Only relevant in multi-silo special.
    if #list >= 1 then
        return
    end

    local loser = entity.force.name
    Teams.eliminate(loser)
    local winner = Teams.winner()
    if Teams.count() == 2 then
        -- Two teams: the first silo to fall ends the game and the winner is the
        -- other team -- exactly what the `enemy_team_of[entity.force.name]`
        -- lookup this replaces returned. Read off the roster rather than off the
        -- alive set, so that the scalar the League daemon polls cannot depend on
        -- round state left behind by an earlier round.
        local active = Teams.all()
        winner = active[1] == loser and active[2] or active[1]
    end
    if not winner then
        -- 3-4 teams, several still alive: one team is out, the round goes on.
        eliminate_team(loser, entity.surface)
        return
    end

    storage.bb_game_won_by_team = winner
    local placement = Teams.placement()
    storage.bb_placement = placement

    if Teams.count() > 2 then
        -- Above two teams "X won" is half the result: three teams lost, in an
        -- order the players fought for and nothing has printed yet. One line,
        -- in the colour of the elimination announcements it closes, and the
        -- same line in bold to Discord. A two-team round keeps today's outputs,
        -- where the loser is the team that is not the winner.
        local titles = {}
        for i = 1, #placement do
            titles[i] = team_title(placement[i])
        end
        local message = Report.winner_message(titles)
        game.print(message, { color = { r = 0.98, g = 0.66, b = 0.22 } })
        Server.to_discord_bold(table.concat({ '*** ', message, ' ***' }))
    end

    set_victory_time()
    team_stats_compare.game_over()

    local teams = Teams.all()
    ---@type table<string, string>
    local team_players = {}
    for _, team in ipairs(teams) do
        team_players[team] = team_title_caps(team) .. ' PLAYERS: \\n'
    end

    for _, player in pairs(game.connected_players) do
        player.play_sound({ path = 'utility/game_won', volume_modifier = 1 })
        local main_frame = Gui.get_left_element(player, 'bb_main_gui')
        if main_frame then
            main_frame.visible = false
        end
        show_endgame_gui(player)
        local listed = team_players[player.force.name]
        if listed then
            team_players[player.force.name] = listed .. player.name .. '   '
        end
    end
    if Teams.count() > 2 then
        -- Above two teams the connected players' force is not their team any
        -- more: every eliminated team's players are spectators by now, and the
        -- lists above are empty for all but the winner. The embed names each
        -- team's roster instead -- the list `[MATCH-RESULT].teams[].players`
        -- carries. A lookup, not a load (see `match_result`).
        local LeagueState = require('maps.biter_battles_v2.league_state')
        for _, team in ipairs(teams) do
            team_players[team] = Report.players_line(team_title_caps(team), LeagueState.roster_of(team))
        end
    end

    for _, team in ipairs(teams) do
        storage.spy_fish_timeout[team] = game.tick + 999999
    end
    storage.server_restart_timer = 150

    game.speed = 1

    local team_evo = {}
    local team_threat = {}
    for _, team in ipairs(teams) do
        local biters = Teams.biter_force(team)
        team_evo[team] = math.floor(1000 * storage.bb_evolution[biters]) * 0.1
        team_threat[team] = math.floor(storage.bb_threat[biters])
    end

    local discord_message
    if Teams.count() == 2 then
        -- The embed an external bot has been parsing for years: the template is
        -- kept exactly as it was -- field order, wording and the two-character
        -- '\\n' sequences -- and only its values now come from the loops above.
        local first, second = teams[1], teams[2]
        discord_message = table.concat({
            '*** Team ',
            storage.bb_game_won_by_team,
            ' has won! ***',
            '\\n',
            storage.victory_time,
            '\\n\\n',
            'North Evo: ',
            team_evo[first],
            '%\\n',
            'North Threat: ',
            team_threat[first],
            '\\n\\n',
            'South Evo: ',
            team_evo[second],
            '%\\n',
            'South Threat: ',
            team_threat[second],
            '\\n\\n',
            team_players[first],
            '\\n\\n',
            team_players[second],
        })
    else
        local parts = {
            '*** Team ',
            team_title(storage.bb_game_won_by_team),
            ' has won! ***',
            '\\n',
            storage.victory_time,
            '\\n\\n',
        }
        for _, team in ipairs(teams) do
            local title = team_title(team)
            parts[#parts + 1] = title
            parts[#parts + 1] = ' Evo: '
            parts[#parts + 1] = team_evo[team]
            parts[#parts + 1] = '%\\n'
            parts[#parts + 1] = title
            parts[#parts + 1] = ' Threat: '
            parts[#parts + 1] = team_threat[team]
            parts[#parts + 1] = '\\n\\n'
        end
        for i, team in ipairs(teams) do
            if i > 1 then
                parts[#parts + 1] = '\\n\\n'
            end
            parts[#parts + 1] = team_players[team]
        end
        local placed = {}
        for i, team in ipairs(placement) do
            placed[i] = team_title(team)
        end
        parts[#parts + 1] = '\\n\\n'
        parts[#parts + 1] = 'Placement: '
        parts[#parts + 1] = table.concat(placed, ', ')
        discord_message = table.concat(parts)
    end

    Server.to_discord_embed(discord_message)
    log({ '', '[TEAMSTATS-FINAL]', helpers.table_to_json(storage.team_stats) })

    if Teams.count() > 2 then
        -- The round's result as one machine-readable line for the league daemon
        -- and the server log. Not for two teams:
        -- their log is compared against the baseline line for line, and the two
        -- outputs above already say who won.
        log({ '', '[MATCH-RESULT] ', helpers.table_to_json(match_result(teams, placement)) })
    end

    for _, team in ipairs(teams) do
        storage['results_sent_' .. team] = false
    end

    freeze_all_biters(entity.surface)
    local special = storage.special_games_variables.captain_mode
    -- The two-team block below is an external DB contract, so it stays literal;
    -- a captain game of more teams writes its own variant after it.
    if Teams.count() == 2 and special and not special.prepaPhase then
        storage.tournament_mode = false
        game.print('Tournament mode is now disabled')
        game.print('Updating logs for the game')
        if special.communityPickingMode then
            Server.send_special_game_state('[COMMUNITY-PICK]')
        else
            Server.send_special_game_state('[CAPTAIN-SPECIAL]')
        end
        log_to_db('>Game has ended\n', false)
        log_to_db('[RefereeName]' .. special.stats.InitialReferee .. '\n', true)
        if special.stats.NorthInitialCaptain then
            log_to_db('[CaptainNorth]' .. special.stats.NorthInitialCaptain .. '\n', true)
        end
        if special.stats.SouthInitialCaptain then
            log_to_db('[CaptainSouth]' .. special.stats.SouthInitialCaptain .. '\n', true)
        end
        local listPicks = table.concat(special.stats.northPicks, ';')
        log_to_db('[NorthTeam]' .. listPicks .. '\n', true)
        listPicks = table.concat(special.stats.southPicks, ';')
        log_to_db('[SouthTeam]' .. listPicks .. '\n', true)
        log_to_db('[Gamelength]' .. game.tick .. '\n', true)
        log_to_db('[StartTick]' .. special.stats.tickGameStarting .. '\n', true)
        log_to_db('[WinnerTeam]' .. storage.bb_game_won_by_team .. '\n', true)
        log_to_db('[ExtraInfo]' .. special.stats.extrainfo .. '\n', true)
        log_to_db('[SpecialEnabled]' .. special.stats.specialEnabled .. '\n', true)
        log_to_db('[CommunityPickMode]' .. tostring(special.communityPickingMode) .. '\n', true)
        for _, player in pairs(game.players) do
            if player.connected and Teams.is_active(player.force.name) then
                Captain_special.captain_log_end_time_player(player)
            end
            if special.stats.playerPlaytimes[player.name] ~= nil then
                log_to_db(
                    '[Playtime][' .. player.name .. ']' .. special.stats.playerPlaytimes[player.name] .. '\n',
                    true
                )
            end
        end
        if special.stats.communityPickInfo then
            log_to_db('[CommunityPickInfo]' .. helpers.table_to_json(special.stats.communityPickInfo) .. '\n', true)
        end
        log_to_db('[TeamStats]' .. helpers.table_to_json(storage.team_stats) .. '\n', true)
        log_to_db('>End of log', true)
    elseif special and not special.prepaPhase then
        -- A captain game of 3 or 4 teams: the same file with the same keys the
        -- daemons already parse, plus [TeamCount] and one [Captain<Team>] /
        -- [<Team>Team] pair per team of the round.
        -- [WinnerTeam] is the force name of the last team standing.
        storage.tournament_mode = false
        game.print('Tournament mode is now disabled')
        game.print('Updating logs for the game')
        Server.send_special_game_state('[CAPTAIN-SPECIAL]')
        local initial = special.stats.initialCaptains or {}
        log_to_db('>Game has ended\n', false)
        log_to_db('[RefereeName]' .. special.stats.InitialReferee .. '\n', true)
        log_to_db('[TeamCount]' .. Teams.count() .. '\n', true)
        for _, team in ipairs(Teams.all()) do
            local title = team:sub(1, 1):upper() .. team:sub(2)
            if initial[team] then
                log_to_db('[Captain' .. title .. ']' .. initial[team] .. '\n', true)
            end
            log_to_db('[' .. title .. 'Team]' .. table.concat(special.stats[team .. 'Picks'] or {}, ';') .. '\n', true)
        end
        log_to_db('[Gamelength]' .. game.tick .. '\n', true)
        log_to_db('[StartTick]' .. special.stats.tickGameStarting .. '\n', true)
        log_to_db('[WinnerTeam]' .. storage.bb_game_won_by_team .. '\n', true)
        log_to_db('[ExtraInfo]' .. special.stats.extrainfo .. '\n', true)
        log_to_db('[SpecialEnabled]' .. special.stats.specialEnabled .. '\n', true)
        log_to_db('[CommunityPickMode]' .. tostring(special.communityPickingMode) .. '\n', true)
        for _, player in pairs(game.players) do
            if player.connected and Teams.is_active(player.force.name) then
                Captain_special.captain_log_end_time_player(player)
            end
            if special.stats.playerPlaytimes[player.name] ~= nil then
                log_to_db(
                    '[Playtime][' .. player.name .. ']' .. special.stats.playerPlaytimes[player.name] .. '\n',
                    true
                )
            end
        end
        log_to_db('[TeamStats]' .. helpers.table_to_json(storage.team_stats) .. '\n', true)
        log_to_db('>End of log', true)
    end
end

local function chat_with_everyone(event)
    if not storage.server_restart_timer then
        return
    end
    if not event.message then
        return
    end
    if not event.player_index then
        return
    end
    local player = game.get_player(event.player_index)
    if not player or not player.valid then
        return
    end
    -- Only a player who is on a team shouts, and the shout is mirrored to every
    -- other team of the round. With two teams that is the single enemy of the
    -- `enemy_team_of` lookup this replaces, and a spectator is still silent.
    local force_name = player.force.name
    if not Teams.is_active(force_name) then
        return
    end
    local message = player.name .. '[auto-shout]: ' .. event.message
    for _, team in ipairs(Teams.all()) do
        if team ~= force_name then
            game.forces[team].print(message, { color = player.chat_color })
        end
    end
end

---@return number, number, number #success percent[0-1], yes count, no count
local function get_reroll_stats()
    local total_votes = table.size(storage.reroll_map_voting)
    if total_votes == 0 then
        return 0, 0, 0
    end

    local yes_votes = 0
    for _, vote in pairs(storage.reroll_map_voting) do
        yes_votes = yes_votes + vote
    end
    return math.floor(100 * yes_votes / total_votes), yes_votes, total_votes - yes_votes
end

local function draw_reroll_gui(player)
    if Gui.get_top_element(player, 'reroll_frame') then
        return
    end

    local frame = Gui.add_top_element(player, { type = 'frame', name = 'reroll_frame', style = 'subheader_frame' })
    gui_style(frame, { minimal_height = 36, maximal_height = 36, padding = 0, vertical_align = 'center' })

    local f = frame.add({ type = 'flow', name = 'flow', direction = 'horizontal' })
    local line = f.add({ type = 'line', direction = 'vertical' })

    do -- buttons
        local t = f.add({ type = 'table', name = 'reroll_table', column_count = 3, vertical_centering = true })
        gui_style(t, { top_margin = 2, left_margin = 8, right_margin = 8 })

        local l = t.add({ type = 'label', caption = { 'gui.reroll_caption', storage.reroll_time_left } })
        gui_style(l, {
            font = 'heading-2',
            font_color = { r = 0.88, g = 0.55, b = 0.11 },
            minimal_width = 120,
            maximal_width = 120,
            right_padding = 2,
        })

        local b = t.add({ type = 'button', caption = 'No', name = 'reroll_no', style = 'red_back_button' })
        gui_style(b, { minimal_width = 56, maximal_width = 56, font = 'heading-2' })

        local b =
            t.add({ type = 'button', caption = 'Yes', name = 'reroll_yes', style = 'confirm_button_without_tooltip' })
        gui_style(b, { minimal_width = 56, maximal_width = 56, font = 'heading-2' })
    end

    local line = f.add({ type = 'line', direction = 'vertical' })

    do -- stats
        local percent, yes_votes, no_votes = get_reroll_stats()

        local l = f.add({
            type = 'label',
            name = 'reroll_stats',
            caption = { 'gui.reroll_stats', no_votes, yes_votes, percent },
        })
        gui_style(
            l,
            { font = 'heading-2', right_padding = 4, left_padding = 4, top_margin = 6, font_color = { 165, 165, 165 } }
        )
    end
end

---@return number, number, number #success percent[0-1], yes count, no count
local function get_automatic_captain_stats()
    local total_votes = table.size(storage.automatic_captain_voting)
    if total_votes == 0 then
        return 0, 0, 0
    end

    local yes_votes = 0
    for _, vote in pairs(storage.automatic_captain_voting) do
        yes_votes = yes_votes + vote
    end
    return math.floor(100 * yes_votes / total_votes), yes_votes, total_votes - yes_votes
end

local function draw_automatic_captain_poll_gui(player)
    if Gui.get_top_element(player, 'automatic_captain_poll_frame') then
        return
    end

    local frame = Gui.add_top_element(
        player,
        { type = 'frame', name = 'automatic_captain_poll_frame', style = 'subheader_frame' }
    )
    gui_style(frame, { minimal_height = 36, maximal_height = 36, padding = 0, vertical_align = 'center' })

    local f = frame.add({ type = 'flow', name = 'flow', direction = 'horizontal' })
    local line = f.add({ type = 'line', direction = 'vertical' })

    do -- buttons
        local t =
            f.add({ type = 'table', name = 'automatic_captain_table', column_count = 3, vertical_centering = true })
        gui_style(t, { top_margin = 2, left_margin = 8, right_margin = 8 })

        local l = t.add({
            type = 'label',
            caption = { 'gui.automatic_captain_caption', storage.automatic_captain_time_left },
        })
        gui_style(l, {
            font = 'heading-2',
            font_color = { r = 0.88, g = 0.55, b = 0.11 },
            minimal_width = 120,
            maximal_width = 120,
            right_padding = 2,
        })

        local b = t.add({ type = 'button', caption = 'No', name = 'automatic_captain_no', style = 'red_back_button' })
        gui_style(b, { minimal_width = 56, maximal_width = 56, font = 'heading-2' })

        local b = t.add({
            type = 'button',
            caption = 'Yes',
            name = 'automatic_captain_yes',
            style = 'confirm_button_without_tooltip',
        })
        gui_style(b, { minimal_width = 56, maximal_width = 56, font = 'heading-2' })
    end

    local line = f.add({ type = 'line', direction = 'vertical' })

    do -- stats
        local percent, yes_votes, no_votes = get_automatic_captain_stats()

        local l = f.add({
            type = 'label',
            name = 'automatic_captain_stats',
            caption = { 'gui.automatic_captain_stats', no_votes, yes_votes, percent },
        })
        gui_style(
            l,
            { font = 'heading-2', right_padding = 4, left_padding = 4, top_margin = 6, font_color = { 165, 165, 165 } }
        )
    end
end

local function stop_automatic_captain()
    storage.automatic_captain_time_left = 0
    -- remove existing buttons
    for _, player in pairs(game.players) do
        local frame = Gui.get_top_element(player, 'automatic_captain_poll_frame')
        if frame then
            frame.destroy()
        end
    end
end

local decrement_timer_automatic_captain_token = Token.get_counter() + 1 -- predict what the token will look like
decrement_timer_automatic_captain_token = Token.register(function()
    if not storage.bb_settings.automatic_captain then
        stop_automatic_captain()
        return
    end

    storage.automatic_captain_time_left = storage.automatic_captain_time_left - 1
    if storage.automatic_captain_time_left > 0 then
        for _, player in pairs(game.connected_players) do
            local frame = Gui.get_top_element(player, 'automatic_captain_poll_frame')
            if frame and frame.valid then
                frame.flow.automatic_captain_table.children[1].caption =
                    { 'gui.automatic_captain_caption', storage.automatic_captain_time_left }
                local percent, yes_votes, no_votes = get_automatic_captain_stats()
                frame.flow.automatic_captain_stats.caption =
                    { 'gui.automatic_captain_stats', no_votes, yes_votes, percent }
            end
        end

        Sounds.notify_all('utility/armor_insert')
        Task.set_timeout_in_ticks(60, decrement_timer_automatic_captain_token)
    else
        stop_automatic_captain()
        -- count votes
        local result, yes_votes, _ = get_automatic_captain_stats()
        local amountVotesRequired = 13
        local percentRequired = 66
        if Teams.count() > 2 then
            -- The poll was started in a two-team round and outlived it: the
            -- timer is a queued `Task`, and a /team-count plus a reset inside
            -- its 45 seconds land it here in a round captain mode cannot be
            -- played in (`max_teams = 2`). `generate_automatic_captain()` does
            -- not go through the special-game contract, so the guard has to be
            -- on the effect, not only on `start_auto_captain_vote()`.
            --
            -- `stop_automatic_captain()` ran at the top of this branch, so the
            -- timer is already 0 and the poll frames are gone; what is left is
            -- what `start_auto_captain_vote()` set and what the votes filled.
            game.print('Captain mode is a two-team mode; the poll is discarded.')
            storage.tournament_mode = false
            storage.automatic_captain_voting = {}
        elseif result >= percentRequired and yes_votes > amountVotesRequired then
            game.print('Vote to start captain event has succeeded (' .. result .. '%)')
            Captain_special.generate_automatic_captain()
        else
            game.print('Vote to start captain event has failed (' .. result .. '%)')
            if yes_votes <= amountVotesRequired then
                game.print(
                    'At least '
                        .. amountVotesRequired
                        .. ' votes voting yes are required, there were only '
                        .. yes_votes
                        .. ' yes votes'
                )
            end
            if result < percentRequired then
                game.print('At least ' .. percentRequired .. '% of yes are required')
            end
            storage.tournament_mode = false
        end
    end
end)

local function start_auto_captain_vote()
    -- Captain mode is a two-sided draft and carries `max_teams = 2`, but this
    -- poll ends in `generate_automatic_captain()`, which starts it without
    -- going through the special-game contract. Above two teams the poll is not
    -- offered at all, which is also the only honest answer to a player who
    -- votes yes: there would be nothing for the vote to start.
    if Teams.count() > 2 then
        return
    end
    if
        storage.bb_settings.automatic_captain
        and #game.connected_players > storage.automatic_captain_min_connected_players_for_vote
    then
        game.print(
            'You can now vote to start or not a captain game, top of screen! You wont be able to play until the poll is over',
            { color = { r = 0.22, g = 0.88, b = 0.22 } }
        )
        storage.tournament_mode = true
        storage.automatic_captain_time_left = storage.automatic_captain_time_limit / 60
        Task.set_timeout_in_ticks(60, decrement_timer_automatic_captain_token)
        for _, player in pairs(game.connected_players) do
            draw_automatic_captain_poll_gui(player)
        end
        Sounds.notify_all('utility/scenario_message')
    end
end

local reroll_buttons_token = Token.register(
    -- create buttons for joining players
    function(event)
        local player = game.get_player(event.player_index)
        draw_reroll_gui(player)
    end
)

local function stop_map_reroll()
    storage.reroll_time_left = 0
    -- disable reroll buttons creation for joining players
    Event.remove_removable(defines.events.on_player_joined_game, reroll_buttons_token)
    -- remove existing buttons
    for _, player in pairs(game.players) do
        local frame = Gui.get_top_element(player, 'reroll_frame')
        if frame then
            frame.destroy()
        end
    end
end

local decrement_timer_token = Token.get_counter() + 1 -- predict what the token will look like
decrement_timer_token = Token.register(function()
    if not storage.bb_settings.map_reroll then
        stop_map_reroll()
        return
    end

    storage.reroll_time_left = storage.reroll_time_left - 1
    if storage.reroll_time_left > 0 then
        for _, player in pairs(game.connected_players) do
            local frame = Gui.get_top_element(player, 'reroll_frame')
            if frame and frame.valid then
                frame.flow.reroll_table.children[1].caption = { 'gui.reroll_caption', storage.reroll_time_left }

                local percent, yes_votes, no_votes = get_reroll_stats()
                frame.flow.reroll_stats.caption = { 'gui.reroll_stats', no_votes, yes_votes, percent }
            end
        end

        Sounds.notify_all('utility/armor_insert')
        Task.set_timeout_in_ticks(60, decrement_timer_token)
    else
        stop_map_reroll()
        -- count votes
        local result, _, _ = get_reroll_stats()
        if result >= 66 then
            game.print('Vote to reload the map has succeeded (' .. result .. '%)')
            game.print('Map is being rerolled!', { color = { r = 0.22, g = 0.88, b = 0.22 } })
            Public.generate_new_map()
        else
            game.print('Vote to reload the map has failed (' .. result .. '%)')
            start_auto_captain_vote()
        end
    end
end)

local function start_map_reroll()
    if storage.bb_settings.map_reroll then
        if not storage.reroll_time_left or storage.reroll_time_left <= 0 then
            Task.set_timeout_in_ticks(60, decrement_timer_token)
            Event.add_removable(defines.events.on_player_joined_game, reroll_buttons_token)
        end
        storage.reroll_time_left = storage.reroll_time_limit / 60
        for _, player in pairs(game.connected_players) do
            draw_reroll_gui(player)
        end
        Sounds.notify_all('utility/scenario_message')
    end
end

---The windows on `player.gui.screen` whose contents are shaped by the team
---list: research info (research_info.lua), the team manager (team_manager.lua),
---the team statistics comparison (team_stats_compare.lua), the sending
---calculator (calc_send_ui.lua) and the comfy panel, whose science-log tab
---(sciencelogs_tab.lua) draws one 'Total sent by <team>' row per active team
---and offers one dropdown entry per team, while its scoreboard tab is keyed by
---force name. Each is built once and then reused while it exists, so one built
---for a round of a different size would show the teams of that round -- or
---index a team that is not playing any more.
local TEAM_SHAPED_SCREEN_GUIS =
    { 'research_info_frame', 'team_manager_gui', 'teamstats_frame', 'calc_send', 'comfy_panel' }

---@param player LuaPlayer
local function destroy_team_shaped_screen_guis(player)
    local screen = player.gui.screen
    for _, name in ipairs(TEAM_SHAPED_SCREEN_GUIS) do
        local element = screen[name]
        if element and element.valid then
            element.destroy()
        end
    end
end

function Public.generate_new_map()
    game.speed = 1
    local prev_surface = storage.bb_surface_name
    -- Read before `Init.tables()`, whose first statement is `Teams.begin_round()`
    -- -- the one place where a team count requested with /team-count lands. This
    -- is the count every GUI the players have on screen was built for.
    local previous_team_count = Teams.count()
    Special_games.reset_special_games()
    Init.tables()
    Init.playground_surface()
    Init.forces()
    Init.draw_structures()
    BBGui.reset_tables_gui()
    Init.reset_feature_flags()
    Init.queue_reveal_map()
    Announce.announce_if_any()
    CraftingList.reset_crafting_queue_list()
    local team_count_changed = Teams.count() ~= previous_team_count
    for _, player in pairs(game.players) do
        Functions.init_player(player)
        Admin.switch_to_admin_mode(player, false)
        for _, e in pairs(player.gui.left.children) do
            e.destroy()
        end
        local suspend_frame = Gui.get_top_element(player, 'suspend_frame')
        if suspend_frame then
            suspend_frame.destroy()
        end
        if team_count_changed then
            -- The new round has a different number of teams than everything on
            -- this player's screen: the statistics strip has no block for a
            -- team that did not play the last round and the windows above list
            -- the teams of that one. Throw them away and build the strip and
            -- the main GUI again, instead of only the main GUI.
            destroy_team_shaped_screen_guis(player)
            BBGui.rebuild_team_guis(player)
        elseif Teams.count() > 2 then
            -- Same count, but above two teams the strip captions its blocks
            -- with `Teams.display_name`, written once when the strip is built:
            -- `Init.tables()` has just dropped the custom names of the round
            -- that ended, and without a rebuild every player would read last
            -- round's names for the whole of this one. Two teams caption the
            -- strip with the literal compass words, which no round changes, so
            -- they keep today's create_main_gui.
            BBGui.rebuild_team_guis(player)
        else
            BBGui.create_main_gui(player)
        end
        BBGui.refresh_feature_flags(player)
    end
    game.reset_time_played()
    storage.server_restart_timer = nil
    game.delete_surface(prev_surface)
    start_map_reroll()
end

function Public.automatic_captain_draw_buttons(event)
    if not storage.bb_settings.automatic_captain then
        return
    end

    if storage.automatic_captain_time_left > 0 then
        local player = game.get_player(event.player_index)
        draw_automatic_captain_poll_gui(player)
    end
end

Event.add(defines.events.on_console_chat, chat_with_everyone)
Event.add(defines.events.on_player_joined_game, Public.automatic_captain_draw_buttons)

return Public
