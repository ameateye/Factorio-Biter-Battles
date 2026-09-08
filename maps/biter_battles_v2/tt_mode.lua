-- BB Triple Threat 3v3 — sandbox-only feature pack.
-- All behavior gated by storage.tt_mode (default false). tt_mode off = vanilla BB.
-- See plan.md (root of this scenario tree) for the spec.

local Tables = require('maps.biter_battles_v2.tables')
local FeedingCalculations = require('maps.biter_battles_v2.feeding_calculations')

local math_round = math.round
local food_values = Tables.food_values

local Public = {}

local BIT_TEAMS = { ['north_biters'] = 'north', ['south_biters'] = 'south' }

-- Plan §A concrete: vanilla scenario uses a refined-concrete disk of radius
-- ~ (spawn_wall_radius - 10) ≈ 105 around each spawn. "Surface ×3" → radius
-- ×sqrt(3) ≈ 1.732, so 105 * 1.732 ≈ 182. TBC Neuro (surface vs radius).
local TT_CONCRETE_VANILLA_RADIUS = 105
local TT_CONCRETE_RADIUS = math.ceil(TT_CONCRETE_VANILLA_RADIUS * math.sqrt(3))  -- 182

-- Reset transient tt state. Called by Public.apply() on enable and by
-- on_map_reset() so a fresh map starts clean.
local function reset_state()
    storage.tt_raw_mutagen = { north_biters = 0, south_biters = 0 }
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

-- Force the e-miner tech researched for both teams (plan §A).
-- Safe to call before forces exist: silently no-ops.
local function unlock_electric_mining_drill()
    for _, fname in pairs({ 'north', 'south' }) do
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
    local dx = 6
    local dy = force_name == 'north' and -6 or 6
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

-- Pre-place the inert power interfaces for both teams at map setup.
-- Idempotent: skips a team whose stored EEI is still a valid entity.
local function place_power_interfaces()
    local surface = game.surfaces[storage.bb_surface_name]
    if not surface or not surface.valid then return end
    storage.tt_power_eei = storage.tt_power_eei or {}
    for _, fname in pairs({ 'north', 'south' }) do
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
    for _, fname in pairs({ 'north', 'south' }) do
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
-- per team near the silo with the FULL team power kit — one player builds
-- power for the team instead of 3 players each hauling 1/3 of it.
-- ~10.8 MW total: 3 offshore-pumps, 6 boilers (1.8 MW each), 12 steam-engines
-- (0.9 MW each), 50 pipes.
local function place_power_chests()
    local surface = game.surfaces[storage.bb_surface_name]
    if not surface or not surface.valid then return end
    storage.tt_power_chest_placed = storage.tt_power_chest_placed or {}
    for _, fname in pairs({ 'north', 'south' }) do
        if not storage.tt_power_chest_placed[fname] then
            local silos = storage.rocket_silo[fname]
            local silo = silos and silos[1]
            if silo and silo.valid then
                local dy = fname == 'north' and -6 or 6
                local pos = surface.find_non_colliding_position(
                    'steel-chest', { silo.position.x + 6, silo.position.y + dy }, 32, 1
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
    if player.force.name ~= 'north' and player.force.name ~= 'south' then return end
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
    local ramp = 0
    if t > 60 then
        -- The +3%/min slope applies FORWARD from the first laser, never to
        -- the minutes already ramped at +5%/min: a global slope switch would
        -- make difficulty (and, through tt_recompute, both teams' evo) DROP
        -- the instant a laser is placed.
        local tl = storage.tt_laser_at_min
        if tl then
            if tl < 60 then tl = 60 end
            if t <= tl then
                ramp = (t - 60) * 0.05
            else
                ramp = (tl - 60) * 0.05 + (t - tl) * 0.03
            end
        else
            ramp = (t - 60) * 0.05
        end
    end
    storage.difficulty_vote_value = 0.8 + ramp
end

---------------------------------------------------------------
-- D: retroactive send — recompute canonical evo from cumulative raw mutagen.
-- Uses feeding.Public.apply_evo_state (set, never add).
---------------------------------------------------------------
function Public.tt_recompute_evo(biter_force_name)
    if not storage.tt_mode then return end
    local raw = (storage.tt_raw_mutagen or {})[biter_force_name] or 0
    if raw <= 0 then return end
    local weighted = raw * storage.difficulty_vote_value
    local players = #game.forces.north.connected_players + #game.forces.south.connected_players
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
    for bf, _ in pairs(BIT_TEAMS) do
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
    if not (fname == 'north' or fname == 'south') then return end
    if not storage.tt_laser_placed then
        storage.tt_laser_placed = true
        local Functions = require('maps.biter_battles_v2.functions')
        storage.tt_laser_at_min = Functions.get_ticks_since_game_start() / 3600
    end
    if storage.tt_power_bonus_given[fname] then return end
    if drop_free_power(fname, 50 * 1000000) then
        storage.tt_power_bonus_given[fname] = true
        game.print(
            '>> [TT] ' .. fname .. ' team built first laser-turret — +50 MW bonus power live at the pre-placed power interface next to your silo.',
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
    local p = player and player.print or log
    if player and not is_admin(player) then return end
    storage.tt_mode = true
    Public.apply()
    game.print(
        '>> [TT] Triple Threat (3v3) mode ENABLED. Custom 80% difficulty, vote locked, e-miner unlocked, steam-power kit on team-join.',
        { r = 1, g = 0.85, b = 0.2 }
    )
end)

commands.add_command('tt-disable', 'Admin only — disable Triple Threat (3v3) mode.', function(cmd)
    local player = cmd.player_index and game.get_player(cmd.player_index) or nil
    if player and not is_admin(player) then return end
    storage.tt_mode = false
    -- clear the init latch: with tt off, on_map_reset no-ops, so a later
    -- disable -> map reset -> enable sequence would otherwise skip the full
    -- init on the fresh map (no concrete/chests/EEIs, stale bonus flags)
    storage.tt_initialized = nil
    game.print('>> [TT] Triple Threat (3v3) mode DISABLED (current map state preserved).')
end)

commands.add_command('tt-status', 'Show Triple Threat mode status.', function(cmd)
    local player = cmd.player_index and game.get_player(cmd.player_index) or nil
    local p = player and player.print or log
    local mode = storage.tt_mode and 'ON' or 'OFF'
    local diff = storage.difficulty_vote_value or 0
    local laser = storage.tt_laser_placed and 'YES' or 'NO'
    local raw_n = (storage.tt_raw_mutagen or {}).north_biters or 0
    local raw_s = (storage.tt_raw_mutagen or {}).south_biters or 0
    local function eei_state(fname)
        local e = (storage.tt_power_eei or {})[fname]
        if not (e and e.valid) then return 'missing' end
        if e.power_production > 0 then
            return string.format('%.0fMW', e.power_production * 60 / 1000000)
        end
        return 'inert'
    end
    p(string.format(
        '[TT] mode=%s  diff=%.1f%%  laser_placed=%s  raw_mutagen N=%.3f S=%.3f  power_bonus N=%s S=%s  eei N=%s S=%s',
        mode, diff * 100, laser, raw_n, raw_s,
        tostring((storage.tt_power_bonus_given or {}).north == true),
        tostring((storage.tt_power_bonus_given or {}).south == true),
        eei_state('north'), eei_state('south')
    ))
end)

return Public
