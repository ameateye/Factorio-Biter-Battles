-- BB Triple Threat 3v3 — sandbox-only feature pack.
-- All behavior gated by storage.tt_mode (default false). tt_mode off = vanilla BB.
-- See plan.md (root of this scenario tree) for the spec.

local Tables = require('maps.biter_battles_v2.tables')
local FeedingCalculations = require('maps.biter_battles_v2.feeding_calculations')
local Teams = require('maps.biter_battles_v2.teams')
local Model = require('maps.biter_battles_v2.tt_mode_model')

local math_round = math.round
local food_values = Tables.food_values

local Public = {}

-- Plan §A concrete: vanilla scenario uses a refined-concrete disk of radius
-- ~ (spawn_wall_radius - 10) ≈ 105 around each spawn. "Surface ×3" → radius
-- ×sqrt(3) ≈ 1.732, so 105 * 1.732 ≈ 182. TBC Neuro (surface vs radius).
local TT_CONCRETE_VANILLA_RADIUS = 105
local TT_CONCRETE_RADIUS = math.ceil(TT_CONCRETE_VANILLA_RADIUS * math.sqrt(3))  -- 182

-- Despite the name, Triple Threat is not a two-team mode: it is what defines
-- BB League in production, so it plays every count the round can have. The
-- two-team sandbox it started as is one case of it -- the one whose
-- every number and every string has to stay what it was -- and the per-team
-- tables, the kit positions and the /tt-status columns below follow
-- Teams.all() instead of a pair of literals.

-- Reset transient tt state. Called by Public.apply() on enable and by
-- on_map_reset() so a fresh map starts clean.
local function reset_state()
    -- One accumulator per biter force OF THIS ROUND, built in Teams.all()
    -- order: with two teams that is { north_biters = 0, south_biters = 0 },
    -- the literal this line carried, and after a count change it is the new
    -- round's forces rather than the old round's.
    storage.tt_raw_mutagen = Teams.per_biter_force(function()
        return 0
    end)
    storage.tt_laser_placed = false
    storage.tt_laser_at_min = nil
    storage.tt_power_bonus_given = {}
    storage.tt_pack_given = {}
    storage.tt_power_chest_placed = {}
    -- destroy stale EEIs before dropping the refs: on a same-map re-init
    -- (tt-disable → tt-enable) the old indestructible entity would both
    -- linger forever AND block can_place at the fixed anchor, pushing the
    -- new EEI to the find_non_colliding fallback (semi-random position).
    -- On a real map reset the refs are already invalid → guarded no-op.
    for _, e in pairs(storage.tt_power_eei or {}) do
        if e and e.valid then e.destroy() end
    end
    storage.tt_power_eei = {}
end

-- Lock the vote and pin difficulty to 80%. Idempotent.
local function lock_difficulty_80()
    storage.difficulty_vote_value = 0.8
    storage.difficulty_vote_index = nil       -- forces difficulty_name() to "Custom (80%)"
    storage.difficulty_player_votes = {}
    storage.difficulty_votes_timeout = 0      -- votes closed (also feeds become allowed)
    storage.tournament_mode = true            -- admin-only vote attempts
end

-- Force the e-miner tech researched for every team of the round (plan §A).
-- Team-count independent: the same one technology, set the same way, for each
-- team in Teams.all() order — with two teams that is north then south, the
-- order and the pair the literal list gave.
-- Safe to call before forces exist: silently no-ops.
local function unlock_electric_mining_drill()
    for _, fname in ipairs(Teams.all()) do
        local f = game.forces[fname]
        if f then
            local tech = f.technologies['electric-mining-drill']
            if tech then tech.researched = true end
        end
    end
end

-- Create one INERT electric-energy-interface (indestructible, 0 production,
-- 0 usage, ~0 buffer) at a FIXED offset from a team's silo. Returns the
-- entity or nil. Used at map setup so the +50MW bonus location is predictable;
-- drop_free_power() later flips the settings to deliver the bonus.
local function create_inert_eei(surface, force_name, silo)
    -- The canonical (+6, -6) of the north side, carried into this team's
    -- square: six tiles east of the silo and six tiles OUTWARD, away from the
    -- river the team faces. With two teams Model.kit_offset returns the very
    -- integers this line used to compute, -6 for north and 6 for south.
    -- (expanded rather than one line: this file is StyLua-dirty and only the
    -- lines the multi-team change touches are formatted — a new one-line `if` here
    -- would be a new complaint.)
    local dx, dy = Model.kit_offset(force_name)
    if not dx then
        return nil
    end
    -- snap to integer tile centers: silos sit at half-tile centers and the
    -- 2x2 EEI snaps on placement — validating the un-snapped anchor checks a
    -- footprint shifted by (-0.5,-0.5) from the one actually occupied
    local pos = { math.floor(silo.position.x + dx + 0.5), math.floor(silo.position.y + dy + 0.5) }
    -- Fixed, predictable offset first; find_non_colliding_position is a
    -- FALLBACK only (players complained the old always-search position was
    -- semi-random).
    if not surface.can_place_entity({
        name = 'electric-energy-interface', position = pos, force = force_name,
    }) then
        pos = surface.find_non_colliding_position(
            'electric-energy-interface', pos, 32, 1
        ) or pos
    end
    local e = surface.create_entity({
        name = 'electric-energy-interface',
        position = pos,
        force = force_name,
        raise_built = false,
    })
    if not e then return nil end
    e.minable_flag = false
    e.destructible = false
    e.operable     = false
    -- Inert: no production, no usage, zero buffer. Verified on 1.1.42:
    -- electric_buffer_size = 0 is accepted (and clamps energy to 0), so 0 is
    -- the smallest legal value.
    e.electric_buffer_size = 0
    e.power_production     = 0
    e.power_usage          = 0
    e.energy               = 0
    return e
end

-- Pre-place the inert power interfaces for every team at map setup.
-- Idempotent: skips a team whose stored EEI is still a valid entity.
local function place_power_interfaces()
    local surface = game.surfaces[storage.bb_surface_name]
    if not surface or not surface.valid then return end
    storage.tt_power_eei = storage.tt_power_eei or {}
    for _, fname in ipairs(Teams.all()) do
        local e = storage.tt_power_eei[fname]
        if not (e and e.valid) then
            local silos = storage.rocket_silo[fname]
            local silo = silos and silos[1]
            if silo and silo.valid then
                storage.tt_power_eei[fname] = create_inert_eei(surface, fname, silo)
            end
        end
    end
end

-- Activate the +50MW bonus on a team's pre-placed interface. If the
-- pre-placed entity is missing/invalid (pre-place failed, old map state),
-- falls back to creating it on the spot, then applies the same settings.
-- Returns true if the bonus is live, false if no silo/surface found.
local function drop_free_power(force_name, watts)
    storage.tt_power_eei = storage.tt_power_eei or {}
    local e = storage.tt_power_eei[force_name]
    if not (e and e.valid) then
        local surface = game.surfaces[storage.bb_surface_name]
        if not surface or not surface.valid then return false end
        local silos = storage.rocket_silo[force_name]
        if not silos or #silos == 0 then return false end
        local silo = silos[1]
        if not (silo and silo.valid) then return false end
        e = create_inert_eei(surface, force_name, silo)
        if not e then return false end
        storage.tt_power_eei[force_name] = e
    end
    e.electric_buffer_size = watts * 2
    -- power_production is JOULES PER TICK, not watts: raw watts here would
    -- output ×60 (50 MW became the reported 3 GW).
    e.power_production     = watts / 60
    e.power_usage          = 0
    e.energy = e.electric_buffer_size
    return true
end

-- Paint extended refined-concrete disk around each team's silo (plan §A).
-- Idempotent: only sets tiles where the current tile is NOT already collidable
-- with vehicles (i.e. dirt/grass/sand — avoids overwriting water tiles, which
-- would erase the river).
local function paint_extended_concrete()
    local surface = game.surfaces[storage.bb_surface_name]
    if not surface or not surface.valid then return end
    local r = TT_CONCRETE_RADIUS
    local rsq = r * r
    for _, fname in ipairs(Teams.all()) do
        local silos = storage.rocket_silo[fname]
        if silos and silos[1] and silos[1].valid then
            local origin = silos[1].position
            local tiles = {}
            for dx = -r, r do
                for dy = -r, r do
                    if dx*dx + dy*dy <= rsq then
                        local x = origin.x + dx
                        local y = origin.y + dy
                        -- Only paint chunks that are already generated (avoids
                        -- LuaTile-invalid crash on ungenerated chunks). Chunks
                        -- not yet generated will be handled by on_chunk_generated
                        -- if we later add a sweep there.
                        if surface.is_chunk_generated({ math.floor(x / 32), math.floor(y / 32) }) then
                            local tile = surface.get_tile(x, y)
                            if tile and tile.valid then
                                local tn = tile.name
                                if tn ~= 'water' and tn ~= 'deepwater' and tn ~= 'water-green'
                                   and tn ~= 'deepwater-green' and tn ~= 'water-shallow'
                                   and tn ~= 'water-mud' and tn ~= 'out-of-map'
                                   and tn ~= 'refined-concrete' then
                                    tiles[#tiles + 1] = { name = 'refined-concrete', position = { x, y } }
                                end
                            end
                        end
                    end
                end
            end
            if #tiles > 0 then surface.set_tiles(tiles, true) end
        end
    end
end

-- Team steam-power chest (plan §A, revised 2026-06-30 bis): one shared chest
-- per team, in EVERY team's square at the turned position of the north one's
-- (Model.kit_offset), near the silo with the FULL team power kit — one player builds
-- power for the team instead of 3 players each hauling 1/3 of it.
-- ~10.8 MW total: 3 offshore-pumps, 6 boilers (1.8 MW each), 12 steam-engines
-- (0.9 MW each), 50 pipes.
local function place_power_chests()
    local surface = game.surfaces[storage.bb_surface_name]
    if not surface or not surface.valid then return end
    storage.tt_power_chest_placed = storage.tt_power_chest_placed or {}
    for _, fname in ipairs(Teams.all()) do
        if not storage.tt_power_chest_placed[fname] then
            local silos = storage.rocket_silo[fname]
            local silo = silos and silos[1]
            local dx, dy = Model.kit_offset(fname)
            if silo and silo.valid and dx then
                local pos = surface.find_non_colliding_position(
                    'steel-chest', { silo.position.x + dx, silo.position.y + dy }, 32, 1
                )
                if pos then
                    local chest = surface.create_entity({
                        name = 'steel-chest',
                        position = pos,
                        force = fname,
                        raise_built = false,
                    })
                    if chest then
                        local inv = chest.get_inventory(defines.inventory.chest)
                        inv.insert({ name = 'offshore-pump', count = 3  })
                        inv.insert({ name = 'boiler',        count = 6  })
                        inv.insert({ name = 'steam-engine',  count = 12 })
                        inv.insert({ name = 'pipe',          count = 50 })
                        storage.tt_power_chest_placed[fname] = true
                    end
                end
            end
        end
    end
end

-- Give a fresh starting pack to a player. Called from on_player_joined_game under tt_mode.
-- Pole type kept as 'small-electric-pole' until Neuro confirms (plan §A TBC).
function Public.give_starting_pack(player)
    if not storage.tt_mode then return end
    -- Also flush late-apply here (covers soft-reset path where raise_evo gate keeps
    -- update_ramp silent for the first 2 minutes after map reset).
    if storage.tt_apply_pending_late then
        unlock_electric_mining_drill()
        paint_extended_concrete()
        place_power_interfaces()   -- before chests: EEI gets the fixed offset spot
        place_power_chests()
        storage.tt_initialized = true
        storage.tt_apply_pending_late = nil
    end
    -- A team of THIS round gets the kit; spectators, the neutral player force
    -- and a team force left over from an earlier round of another count do not.
    -- With two teams Teams.is_active answers true for exactly north and south.
    if not Teams.is_active(player.force.name) then return end
    if storage.tt_pack_given[player.name] then return end
    storage.tt_pack_given[player.name] = true
    player.insert({ name = 'grenade',             count = 10 })
    player.insert({ name = 'burner-mining-drill', count = 10 })
    player.insert({ name = 'stone-furnace',       count = 10 })
    player.insert({ name = 'small-electric-pole', count = 200 })
    player.insert({ name = 'raw-fish',            count = 20 })
    player.insert({ name = 'coal',                count = 100 })
end

---------------------------------------------------------------
-- C: ramp + 5%/min (or +3% after laser placed) from t=60min.
---------------------------------------------------------------
function Public.update_ramp()
    if not storage.tt_mode then return end
    -- Late-apply flush: on_map_reset queues tech/power for after on_init completes.
    if storage.tt_apply_pending_late then
        unlock_electric_mining_drill()
        paint_extended_concrete()
        place_power_interfaces()   -- before chests: EEI gets the fixed offset spot
        place_power_chests()
        storage.tt_initialized = true
        storage.tt_apply_pending_late = nil
    end
    local Functions = require('maps.biter_battles_v2.functions')
    local t = Functions.get_ticks_since_game_start() / 3600  -- minutes
    -- The +3%/min slope applies FORWARD from the first laser, never to the
    -- minutes already ramped at +5%/min: a global slope switch would make
    -- difficulty (and, through tt_recompute, every team's evo) DROP the instant
    -- a laser is placed. Moved into tt_mode_model.lua expression for
    -- expression so a unit test can pin it; the 80% floor and the slopes read
    -- a clock and a latch, never the team count, so they are the same at 2, 3
    -- and 4 teams.
    local ramp = Model.ramp(t, storage.tt_laser_at_min)
    storage.difficulty_vote_value = 0.8 + ramp
end

---------------------------------------------------------------
-- D: retroactive send — recompute canonical evo from cumulative raw mutagen.
-- Uses feeding.Public.apply_evo_state (set, never add).
--
-- WHICH FEEDING PARAMETERS. This mode never picks a parameter set of its own:
-- calc_feed_effects reads FeedingParams.get(), which is keyed by
-- MatchFormat.format_key(), and that key is TWO parts whatever the team count
-- -- players PER TEAM. A '2v2v2v2' round therefore plays the '2v2' set, and
-- the recompute below is priced with the same numbers a live send is. That is
-- a choice to revisit (match_format.lua:80-83): if four teams of two
-- should ever be tuned apart from two teams of two, the key changes there and
-- this function follows it for free.
---------------------------------------------------------------
function Public.tt_recompute_evo(biter_force_name)
    if not storage.tt_mode then return end
    local raw = (storage.tt_raw_mutagen or {})[biter_force_name] or 0
    if raw <= 0 then return end
    local weighted = raw * storage.difficulty_vote_value
    -- The same count feeding.lua's connected_team_player_count() makes, over
    -- the teams of the round in Teams.all() order: with two teams it is
    -- #north + #south added in that order, an exact integer sum either way.
    local players = 0
    local teams = Teams.all()
    for index = 1, #teams do
        local force = game.forces[teams[index]]
        if force then
            players = players + #force.connected_players
        end
    end
    -- `effects.threat_increase` is DELIBERATELY discarded, and must stay that
    -- way. This replays the whole game as one send from evo 0, so with instant
    -- threat parameterised (feeding_params.lua, c * M) that field is the instant
    -- threat of every flask ever fed -- banking it here, once a minute, would
    -- inflate bb_threat without bound. The send path already banked it: do_raw_feed
    -- adds threat_increase to storage.bb_threat before calling apply_evo_state,
    -- which by contract only ever writes bb_threat_income. Evolution is the only
    -- thing this function is here to restate.
    local effects = FeedingCalculations.calc_feed_effects(
        0, weighted, 1, players, storage.max_reanim_thresh
    )
    local evo = math_round(effects.evo_increase, 9)  -- evo from initial_evo=0 → absolute target
    local Feeding = require('maps.biter_battles_v2.feeding')
    Feeding.apply_evo_state(biter_force_name, evo, effects.biter_health_factor, effects.passive_threat)
end

function Public.tt_recompute_all()
    if not storage.tt_mode then return end
    -- Ring order instead of the hash order of the old two-entry BIT_TEAMS.
    -- Nothing here is order-sensitive -- tt_recompute_evo reads one force's
    -- accumulator and writes that same force's evolution, health factor and
    -- income, prints nothing and draws nothing -- so the two-team pair is
    -- restated exactly as before. Above two teams an eliminated team is left
    -- alone: it no longer feeds and is no longer fed, so its mutagen cannot
    -- move again (Model.recompute_forces).
    for _, bf in ipairs(Model.recompute_forces()) do
        Public.tt_recompute_evo(bf)
    end
end

---------------------------------------------------------------
-- F: on laser placed → +50MW one-shot per team + ramp slope switch.
---------------------------------------------------------------
function Public.on_laser_built(entity)
    if not storage.tt_mode then return end
    if not (entity and entity.valid) then return end
    if entity.name ~= 'laser-turret' then return end
    -- Only a TEAM laser counts ("once either team has placed a laser"):
    -- script-/spectator-placed turrets must not flip the ramp slope.
    local fname = entity.force and entity.force.name
    if not Teams.is_active(fname) then return end
    if not storage.tt_laser_placed then
        storage.tt_laser_placed = true
        local Functions = require('maps.biter_battles_v2.functions')
        storage.tt_laser_at_min = Functions.get_ticks_since_game_start() / 3600
    end
    if storage.tt_power_bonus_given[fname] then return end
    if drop_free_power(fname, 50 * 1000000) then
        storage.tt_power_bonus_given[fname] = true
        game.print(
            Model.laser_bonus_line(fname, Teams.count(), Teams.display_name(fname)),
            { r = 1, g = 0.85, b = 0.2 }
        )
    end
end

---------------------------------------------------------------
-- Apply tt_mode in this session: locks difficulty, init state, drops power,
-- unlocks e-miner tech. Called from /tt-enable AND on map reset.
---------------------------------------------------------------
-- Full init: state reset + EEI drop + concrete paint. Runs once per map.
-- /tt-enable on an already-initialized session only refreshes idempotent
-- ops (difficulty lock + tech unlock); to force a full re-init, /tt-disable
-- then /tt-enable, OR /scenario restart.
function Public.apply()
    lock_difficulty_80()
    unlock_electric_mining_drill()
    if not storage.tt_initialized then
        reset_state()
        paint_extended_concrete()
        place_power_interfaces()   -- before chests: EEI gets the fixed offset spot
        place_power_chests()
        storage.tt_initialized = true
    end
end

-- Called from init.tables() once per map reset, AFTER reset_evo / state clears.
-- At this point neither forces nor surface exist yet (on_init order: tables →
-- initial_setup → playground_surface → forces → draw_structures), so we run
-- the storage-only steps now and defer tech-unlock + power-drop to the first
-- raise_evo tick via the tt_apply_pending_late flag.
function Public.on_map_reset()
    if not storage.tt_mode then return end
    -- The mode SURVIVES a change of team count (2 → 4 → 2): it is what the
    -- League plays, so a reset must not silently turn it off. What does not
    -- survive is the round's bookkeeping — reset_state() rebuilds every
    -- per-team table for the teams of the NEW round, so a team that is not
    -- playing this time keeps no accumulator and a team that was not playing
    -- last time starts at zero.
    reset_state()
    storage.tt_initialized = nil   -- new surface → full init needed
    lock_difficulty_80()
    storage.tt_apply_pending_late = true
end

---------------------------------------------------------------
-- Admin commands.
---------------------------------------------------------------
commands.add_command('tt-enable', 'Admin only — enable Triple Threat (3v3) sandbox mode.', function(cmd)
    local player = cmd.player_index and game.get_player(cmd.player_index) or nil
    if player and not is_admin(player) then return end
    -- Turning the mode ON from off is what identifies the BB League server
    -- (feeding_params.lua `is_league`), and a fresh scenario -- which the League
    -- starts at every restart -- is the only state it is off in. So this is the
    -- moment the League's own `bb_settings` defaults go in (tt_mode_model.lua
    -- `league_bb_settings`): once per start, never over an admin's later toggle
    -- while the mode stays on (a /tt-disable then /tt-enable applies them
    -- again), and not at all on a server that never sends this command.
    local was_off = storage.tt_mode ~= true
    storage.tt_mode = true
    Public.apply()
    game.print(
        '>> [TT] '
            .. Model.mode_label(Teams.count())
            .. ' mode ENABLED. Custom 80% difficulty, vote locked, e-miner unlocked, steam-power kit on team-join.',
        { r = 1, g = 0.85, b = 0.2 }
    )
    if was_off then
        local moved = Model.apply_league_settings(storage.bb_settings)
        if #moved > 0 then
            game.print('>> [TT] League settings applied: ' .. table.concat(moved, ', '), { r = 1, g = 0.85, b = 0.2 })
        end
    end
end)

commands.add_command('tt-disable', 'Admin only — disable Triple Threat (3v3) mode.', function(cmd)
    local player = cmd.player_index and game.get_player(cmd.player_index) or nil
    if player and not is_admin(player) then return end
    storage.tt_mode = false
    -- clear the init latch: with tt off, on_map_reset no-ops, so a later
    -- disable -> map reset -> enable sequence would otherwise skip the full
    -- init on the fresh map (no concrete/chests/EEIs, stale bonus flags)
    storage.tt_initialized = nil
    game.print('>> [TT] ' .. Model.mode_label(Teams.count()) .. ' mode DISABLED (current map state preserved).')
end)

commands.add_command('tt-status', 'Show Triple Threat mode status.', function(cmd)
    local player = cmd.player_index and game.get_player(cmd.player_index) or nil
    local p = player and player.print or log
    local mode = storage.tt_mode and 'ON' or 'OFF'
    local diff = storage.difficulty_vote_value or 0
    local laser = storage.tt_laser_placed and 'YES' or 'NO'
    local function raw_of(team)
        return (storage.tt_raw_mutagen or {})[Teams.biter_force(team)] or 0
    end
    local function bonus_of(team)
        return (storage.tt_power_bonus_given or {})[team]
    end
    local function eei_state(fname)
        local e = (storage.tt_power_eei or {})[fname]
        if not (e and e.valid) then return 'missing' end
        if e.power_production > 0 then
            return string.format('%.0fMW', e.power_production * 60 / 1000000)
        end
        return 'inert'
    end
    -- One column per team of the round instead of the two fixed N=/S= slots
    -- (INVENTORY §2.13). The column letter is the initial of the force name,
    -- so with two teams the line is character for character the one this
    -- command has always printed (pinned in tests/test-tt-mode.lua).
    p(Model.status_line(Teams.all(), mode, diff, laser, raw_of, bonus_of, eei_state))
end)

return Public
