local Public = {}
local BiterRaffle = require('maps.biter_battles_v2.biter_raffle')
local bb_config = require('maps.biter_battles_v2.config')
local BossUnit = require('functions.boss_unit')
local Event = require('utils.event')
local Feeding = require('maps.biter_battles_v2.feeding')
local Functions = require('maps.biter_battles_v2.functions')
local Layout = require('maps.biter_battles_v2.layout')
local Tables = require('maps.biter_battles_v2.tables')
local Teams = require('maps.biter_battles_v2.teams')
local AiStrikes = require('maps.biter_battles_v2.ai_strikes')
local AiTargets = require('maps.biter_battles_v2.ai_targets')
local AttackClock = require('maps.biter_battles_v2.attack_clock')
local MatchFormat = require('maps.biter_battles_v2.match_format')
local MultiSilo = require('comfy_panel.special_games.multi_silo')
local Pathfinder = require('commands.set_pathfinder')
local math_random = math.random
local math_floor = math.floor

local unit_type_raffle = { 'biter', 'mixed', 'mixed', 'spitter', 'spitter' }
local size_of_unit_type_raffle = #unit_type_raffle

local small = 15
local threat_values = {
    ['small-spitter'] = 10 / small,
    ['small-biter'] = 15 / small,
    ['medium-spitter'] = 50 / small,
    ['medium-biter'] = 75 / small,
    ['big-spitter'] = 200 / small,
    ['big-biter'] = 375 / small,
    ['behemoth-spitter'] = 1500 / small,
    ['behemoth-biter'] = 3000 / small,
    ['small-worm-turret'] = 200 / small,
    ['medium-worm-turret'] = 500 / small,
    ['big-worm-turret'] = 1500 / small,
    ['behemoth-worm-turret'] = 3000 / small,
    ['biter-spawner'] = 350 / small,
    ['spitter-spawner'] = 350 / small,
}

---The share of the map's threat that belongs to `biter_force_name` -- the
---fraction of the seven wave slots the team it attacks is worth this cycle.
---
---With two teams this is the legacy expression, kept statement for statement,
---quirks included: the `<= 0` early-out on the queried pool, the clamp of a
---negative pool applied to the *denominator only* (so +100 against -500 is
---still a full 1.0), and the unreachable 0.5 tie fallback. The only change is
---that the two force names come from the registry instead of being literals,
---and the registry hands them out in the same order -- so it is the same two
---reads, the same addition and the same division, in the same sequence.
---
---Above two teams the denominator is the sum of the ALIVE biter pools, each
---clamped at zero exactly as the two-team denominator clamps, the share is
---scaled by `#alive / 2` so an even split still buys today's four groups
---(`ceil(0.5 * 7)`), and the result is capped at one so a lone leader buys the
---full seven and no more. An eliminated team is left out of both: its pool is
---frozen where it died, and counting it would hold the survivors' share down
---for the rest of the round.
---@param biter_force_name string
---@return number
local function get_threat_ratio(biter_force_name)
    if storage.bb_threat[biter_force_name] <= 0 then
        return 0
    end
    if Teams.count() == 2 then
        local biter_forces = Teams.biter_forces()
        local t1 = storage.bb_threat[biter_forces[1]]
        local t2 = storage.bb_threat[biter_forces[2]]
        if t1 == 0 and t2 == 0 then
            return 0.5
        end
        if t1 < 0 then
            t1 = 0
        end
        if t2 < 0 then
            t2 = 0
        end
        local total_threat = t1 + t2
        local ratio = storage.bb_threat[biter_force_name] / total_threat
        return ratio
    end

    local alive = Teams.alive()
    local biter_forces = Teams.alive_biter_forces()
    local total_threat = 0
    for i = 1, #biter_forces do
        local t = storage.bb_threat[biter_forces[i]] or 0
        if t < 0 then
            t = 0
        end
        total_threat = total_threat + t
    end
    if total_threat == 0 then
        -- Only reachable when the queried force is not one of the alive ones;
        -- the early-out above guarantees a positive pool otherwise.
        return 0
    end
    local ratio = (storage.bb_threat[biter_force_name] / total_threat) * (#alive / 2)
    if ratio > 1 then
        return 1
    end
    return ratio
end

---Sends nearby biters from the given force to attack the silo target.
---@param force_name string Player force name (e.g. 'north', 'south').
---@param silo LuaEntity|nil Rocket silo entity; no-op if nil or invalid.
local function send_biters_to_silo_target(force_name, silo)
    if silo == nil or not silo.valid then
        return
    end
    game.surfaces[storage.bb_surface_name].set_multi_command({
        command = {
            type = defines.command.attack,
            target = silo,
            distraction = defines.distraction.none,
        },
        unit_count = 8,
        force = force_name .. '_biters',
        unit_search_distance = 64,
    })
end

---Goes through each valid force and sends direct attack to all rocket silos.
---If it's not a multi-silo special, then only the one at a spawn is considered.
Public.send_near_biters_to_silo = function()
    if Functions.get_ticks_since_game_start() < 108000 then
        return
    end
    if storage.bb_game_won_by_team then
        return
    end

    for _, force in pairs(game.forces) do
        local f_name = force.name
        local list = storage.rocket_silo[f_name]
        -- If no list, then not a valid force.
        if list == nil then
            goto send_biters_silo_loop_1
        end

        for _, silo in ipairs(list) do
            send_biters_to_silo_target(f_name, silo)
        end

        ::send_biters_silo_loop_1::
    end
end

--- Remove invalid spawner from the list at given index using swap-and-pop.
--- This is O(1) compared to table.remove which is O(n).
---@param spawners table
---@param index number
---@param size number
---@return number new_size
local function remove_invalid_spawner(spawners, index, size)
    spawners[index] = spawners[size]
    spawners[size] = nil
    return size - 1
end

local function get_random_spawner(biter_force_name)
    local spawners = storage.unit_spawners[biter_force_name]
    -- #spawners works because swap-and-pop maintains array contiguity (no holes)
    local size = #spawners

    for _ = 1, 256, 1 do
        if size == 0 then
            return nil
        end
        local index = math_random(1, size)
        local spawner = spawners[index]
        if spawner and spawner.valid then
            return spawner
        end
        -- Spawner is nil or invalid, remove it from the list
        size = remove_invalid_spawner(spawners, index, size)
    end
    return nil
end

--Manual spawning of units
local function spawn_biters(
    isItnormalBiters,
    maxLoopIteration,
    spawner,
    biter_threat,
    biter_force_name,
    max_unit_count,
    valid_biters,
    force_name
)
    local roll_type = unit_type_raffle[math_random(1, size_of_unit_type_raffle)]
    local boss_biter_force_name = biter_force_name .. '_boss'
    -- *1.5 because we add 50% health bonus as it's just one unit.
    -- *20 because one boss is equal of 20 biters in theory
    -- formula because 90% revive chance is 1/(1-0.9) = 10, which means biters needs to be killed 10 times, so *10 . easy fast-check : 50% revive is 2 biters worth, formula matches. 0% revive -> 1 biter worth
    local health_buff_equivalent_revive = storage.biter_health_factor[game.forces[biter_force_name].index]
    if not isItnormalBiters then
        health_buff_equivalent_revive = health_buff_equivalent_revive * 20
    end
    local i = #valid_biters
    for _ = 1, maxLoopIteration, 1 do
        local unit_name = BiterRaffle.roll(roll_type, storage.bb_evolution[biter_force_name])
        if isItnormalBiters and biter_threat < 0 then
            break
        end
        if not isItnormalBiters and biter_threat - threat_values[unit_name] * health_buff_equivalent_revive < 0 then
            break
        end -- Do not add a biter if it will make the threat goes negative when all the biters of wave were killed
        local position = spawner.surface.find_non_colliding_position(unit_name, spawner.position, 128, 2)
        if not position then
            break
        end
        local biter

        if isItnormalBiters then
            biter = spawner.surface.create_entity({ name = unit_name, force = biter_force_name, position = position })
        else
            biter =
                spawner.surface.create_entity({ name = unit_name, force = boss_biter_force_name, position = position })
        end
        if isItnormalBiters then
            biter_threat = biter_threat - threat_values[biter.name]
        else
            biter_threat = biter_threat - threat_values[biter.name] * health_buff_equivalent_revive
        end
        i = i + 1
        valid_biters[i] = biter
        if health_buff_equivalent_revive > 1 then
            BossUnit.add_high_health_unit(biter, health_buff_equivalent_revive, not isItnormalBiters)
        end

        --Announce New Spawn
        if isItnormalBiters and storage.biter_spawn_unseen[force_name][unit_name] then
            game.print({
                '',
                'A ',
                unit_name:gsub('-', ' '),
                ' was spotted far away on ',
                Functions.team_name_with_color(force_name),
                '...',
            })
            storage.biter_spawn_unseen[force_name][unit_name] = false
        end
        if not isItnormalBiters and storage.biter_spawn_unseen[boss_biter_force_name][unit_name] then
            game.print({
                '',
                'A ',
                unit_name:gsub('-', ' '),
                ' boss was spotted far away on ',
                Functions.team_name_with_color(force_name),
                '...',
            })
            storage.biter_spawn_unseen[boss_biter_force_name][unit_name] = false
        end
    end
end

local function on_entity_spawned(event)
    local entity = event.entity
    if not entity.valid then
        return
    end
    -- The buff goes to a naturally spawned unit of a *regular* biter force of a
    -- team that plays this round. At two teams those are exactly the two forces
    -- the literals used to name, and a boss force still fails the second test.
    local force_name = entity.force.name
    local team = Teams.team_of_biter_force(force_name)
    if team and force_name == Teams.biter_force(team) and Teams.is_active(team) then
        local health_factor = storage.biter_health_factor[entity.force.index]
        if health_factor > 1 then
            BossUnit.add_high_health_unit(entity, health_factor, false)
        end
    end
end

Event.add(defines.events.on_entity_spawned, on_entity_spawned)

local function select_units_around_spawner(spawner, force_name)
    local biter_force_name = spawner.force.name

    local valid_biters = {}
    local i = 0

    -- Half threat goes to normal biters, half threat goes for bosses, to get half bosses and half normal biters
    local threat = storage.bb_threat[biter_force_name] / 10
    local threat_for_normal_biters = threat

    local max_group_size_biters_force = storage.max_group_size[biter_force_name]

    if max_group_size_biters_force ~= storage.max_group_size_initial then
        threat_for_normal_biters = threat_for_normal_biters / 2
    end
    local threat_for_boss_biters = threat / 2
    local max_unit_count = math.floor(storage.bb_threat[biter_force_name] * 0.25) + math_random(6, 12)
    if max_unit_count > max_group_size_biters_force then
        max_unit_count = max_group_size_biters_force
    end

    --Manual spawning of units
    spawn_biters(
        true,
        max_unit_count,
        spawner,
        threat_for_normal_biters,
        biter_force_name,
        max_unit_count,
        valid_biters,
        force_name
    )

    --Manual spawning of boss units
    if max_group_size_biters_force ~= storage.max_group_size_initial then
        spawn_biters(
            false,
            math.ceil((storage.max_group_size_initial - max_group_size_biters_force) / 20),
            spawner,
            threat_for_boss_biters,
            biter_force_name,
            max_unit_count,
            valid_biters,
            force_name
        )
    end

    return valid_biters
end

---Where a wave forms up: four tiles from the nest towards the river the team it
---attacks faces.
---
---On the two-team map that is the legacy pair of signed steps on y, kept as it
---stands -- the literal test, the same branch, the same four tiles.
---
---On the four-square map the step is the same four tiles along `Layout.inward`,
---the unit axis vector from the victim's zone towards its front river, which for
---the canonical zone is +y and for the other three is that vector turned with
---their zone. A force that names no team (nothing the scheduler can produce)
---leaves the rally point on the nest.
local function get_unit_group_position(spawner)
    local p
    if Teams.layout() == 'horizontal2' then
        if spawner.force.name == 'north_biters' then
            p = { x = spawner.position.x, y = spawner.position.y + 4 }
        else
            p = { x = spawner.position.x, y = spawner.position.y - 4 }
        end
    else
        local team = Teams.team_of_biter_force(spawner.force.name)
        local inward = (team and Layout.inward(team)) or { x = 0, y = 0 }
        p = { x = spawner.position.x + 4 * inward.x, y = spawner.position.y + 4 * inward.y }
    end
    p = spawner.surface.find_non_colliding_position('electric-furnace', p, 256, 1)
    if not p then
        if storage.bb_debug then
            game.print('No unit_group_position found for force ' .. spawner.force.name)
        end
        return
    end
    return p
end

local function get_nearby_biter_nest(center, biter_force_name)
    local spawner = get_random_spawner(biter_force_name)
    if not spawner then
        return
    end
    local best_distance = (center.x - spawner.position.x) ^ 2 + (center.y - spawner.position.y) ^ 2

    for _ = 1, 16, 1 do
        local new_spawner = get_random_spawner(biter_force_name)
        if not new_spawner then
            break
        end
        local new_distance = (center.x - new_spawner.position.x) ^ 2 + (center.y - new_spawner.position.y) ^ 2
        if new_distance < best_distance then
            spawner = new_spawner
            best_distance = new_distance
        end
    end

    if not spawner then
        return
    end
    --print("Nearby biter nest found at x=" .. spawner.position.x .. " y=" .. spawner.position.y .. ".")
    return spawner
end

local function create_attack_group(surface, force_name, biter_force_name)
    local threat = storage.bb_threat[biter_force_name]
    if threat <= 0 then
        return false
    end

    local target_position = AiTargets.get_random_target(force_name)
    if not target_position then
        print('No side target found for ' .. force_name .. '.')
        return
    end

    local spawner = get_nearby_biter_nest(target_position, biter_force_name)
    if not spawner then
        print('No spawner found for ' .. force_name .. '.')
        return
    end

    local unit_group_position = get_unit_group_position(spawner)
    if not unit_group_position then
        return
    end
    local units = select_units_around_spawner(spawner, force_name)
    if not units then
        return
    end
    local boss_force_name = biter_force_name .. '_boss'
    local unit_group = surface.create_unit_group({ position = unit_group_position, force = biter_force_name })
    local unit_group_boss = nil
    local has_boss_units = false
    for _, unit in pairs(units) do
        unit.ai_settings.path_resolution_modifier = 0
        if unit.force.name == boss_force_name then
            if not unit_group_boss then
                unit_group_boss = surface.create_unit_group({ position = unit_group_position, force = boss_force_name })
                has_boss_units = true
            end
            unit_group_boss.add_member(unit)
        else
            unit_group.add_member(unit)
        end
        storage.biters_from_positive_threat[unit.unit_number] = true
    end

    if storage.bb_settings.classic_pathfinding then
        AiStrikes.initiate_classic_attack(unit_group, force_name, target_position)
        MultiSilo.track_group(unit_group)

        if has_boss_units then
            AiStrikes.initiate_classic_attack(unit_group_boss, force_name, target_position)
            MultiSilo.track_group(unit_group_boss)
        end
    else
        local strike_position = AiStrikes.calculate_strike_position(unit_group, target_position)
        if not strike_position then
            log('No strike position found for ' .. biter_force_name .. ', skipping flank')
        end

        AiStrikes.initiate_advanced_attack(unit_group, force_name, strike_position, target_position)
        MultiSilo.track_group(unit_group)

        if has_boss_units then
            AiStrikes.initiate_advanced_attack(unit_group_boss, force_name, strike_position, target_position)
            MultiSilo.track_group(unit_group_boss)
        end
    end
end

Public.pre_main_attack = function()
    Pathfinder.apply()
    local force_name = storage.next_attack

    -- Above two teams a team that has just been eliminated is not attacked: a
    -- budget of zero, which is also the idle turn the clock counts on -- the
    -- dead keep their place in the rotation so that the survivors' turns do not
    -- come round any faster. At two teams the cycle is untouched, dead side
    -- included: today a dead side keeps being scheduled and the waves print
    -- 'No side target found', and that is pinned behaviour.
    if Teams.count() > 2 and not Teams.is_alive(force_name) then
        storage.main_attack_wave_amount = 0
        return
    end

    -- In headless benchmarking, there are no connected_players so we need a global to override this
    if
        not storage.training_mode
        or (storage.training_mode and (storage.benchmark_mode or #game.forces[force_name].connected_players > 0))
    then
        local biter_force_name = force_name .. '_biters'
        storage.main_attack_wave_amount = math.ceil(get_threat_ratio(biter_force_name) * 7)

        if storage.bb_debug then
            local message = storage.main_attack_wave_amount
                .. ' unit groups designated for '
                .. force_name
                .. ' biters.'
            -- Above two teams the line also says which turn of the clock this
            -- is: the tick it ran on and the ticks to the next cycle, so a debug
            -- log can be read against the cadence. The shared-cycle fallback has
            -- no period of its own -- a cycle a minute, whole cycles dropped by
            -- `skip_attack_cycle` -- and names itself instead. The two-team
            -- string is the legacy one, to the byte.
            if Teams.count() > 2 then
                local period = AttackClock.SHARED
                if AttackClock.is_on(Teams.count()) then
                    period = AttackClock.period(MatchFormat.attack_interval_ticks(), Teams.count())
                end
                message = message .. ' (tick ' .. game.tick .. ', period ' .. period .. ')'
            end
            game.print(message)
        end
    else
        storage.main_attack_wave_amount = 0
    end
end

Public.perform_main_attack = function()
    if storage.main_attack_wave_amount > 0 then
        local surface = game.surfaces[storage.bb_surface_name]
        local force_name = storage.next_attack
        -- A team can be eliminated between the setup wave and this one; above
        -- two teams the rest of the cycle is dropped. Two teams keep today's
        -- behaviour (the guard short-circuits before the alive test).
        if Teams.count() > 2 and not Teams.is_alive(force_name) then
            storage.main_attack_wave_amount = 0
            return
        end
        local biter_force_name = force_name .. '_biters'

        create_attack_group(surface, force_name, biter_force_name)
        storage.main_attack_wave_amount = storage.main_attack_wave_amount - 1
    end
end

Public.post_main_attack = function()
    storage.main_attack_wave_amount = 0
    if Teams.count() == 2 then
        -- The legacy toggle, statement for statement: whoever is scheduled, the
        -- other one is next, and anything else (including a value the toggle
        -- has never seen) falls back to the first team. `active[1]`/`active[2]`
        -- are 'north'/'south', in that order.
        local active = Teams.all()
        if storage.next_attack == active[1] then
            storage.next_attack = active[2]
        else
            storage.next_attack = active[1]
        end
        return
    end

    if AttackClock.is_on(Teams.count()) then
        -- On the clock the turn walks the ring of every team PLAYING the round,
        -- the eliminated ones included: their turn is an idle one (the budget
        -- guard at the top of pre_main_attack) and it is what keeps a survivor's
        -- turn coming round every `2 * interval` for the whole round. Skipping
        -- the dead here instead would shorten the rotation by a turn each time a
        -- team falls, and the last two standing would be attacked twice as often
        -- as the game is tuned for.
        local playing = Teams.all()
        local next_playing = AttackClock.next_turn(playing, storage.next_attack)
        if next_playing then
            storage.next_attack = next_playing
        end
        return
    end

    -- With the shared-cycle fallback there is one cycle per interval, so a turn
    -- spent on a team that is out is a whole interval with no attack anywhere:
    -- the turn walks the ring clockwise stepping OVER the teams that are out,
    -- and a `next_attack` that is not a roster team at all restarts the rotation
    -- at the first alive team.
    local next_team = Teams.next_alive_clockwise(storage.next_attack) or Teams.alive()[1]
    if next_team then
        storage.next_attack = next_team
    end
end

---The teams the passive red-potion drip counts: who has to have players for it
---to run at all, and whose biters receive it.
---
---Two teams are `Teams.all()`, today's expression: a two-team round has no
---elimination step -- the first silo to fall ends the game -- so the active and
---the alive list can only differ once the game is over.
---
---Above two teams it is the teams still standing. An eliminated team has no
---players (they were moved to the spectators), so counting it would make the
---empty-team gate return on every call and freeze evolution, the raise counter
---and the derived threat income for every survivor until the map resets.
---@return string[]
local function passive_feed_teams()
    if Teams.count() == 2 then
        return Teams.all()
    end
    return Teams.alive()
end

Public.raise_evo = function()
    if storage.freeze_players then
        return
    end
    -- The passive drip is frozen while any team that counts this round is empty.
    -- At two teams this is the old `north is empty or south is empty`, tested in
    -- the same order and with the same short-circuit.
    if not storage.training_mode then
        for _, team in ipairs(passive_feed_teams()) do
            if #game.forces[team].connected_players == 0 then
                return
            end
        end
    end
    if Functions.get_ticks_since_game_start() < 7200 then
        return
    end
    -- tt_mode: update the 80%+ramp (plan §C). Replaces the index-based vanilla
    -- ramp below (which doesn't apply because difficulty_vote_index = nil under tt_mode).
    if storage.tt_mode then
        local TtMode = require('maps.biter_battles_v2.tt_mode')
        TtMode.update_ramp()
    end
    if storage.difficulty_vote_index and 1 <= storage.difficulty_vote_index and 4 >= storage.difficulty_vote_index then
        local matchTimeInMinutes = Functions.get_ticks_since_game_start() / 3600
        storage.difficulty_vote_value = ((matchTimeInMinutes / 470) ^ 3.7)
            + Tables.difficulties[storage.difficulty_vote_index].value
    end

    local amount = math.ceil(storage.evo_raise_counter * 0.75)

    if not storage.total_passive_feed_redpotion then
        storage.total_passive_feed_redpotion = 0
    end
    storage.total_passive_feed_redpotion = storage.total_passive_feed_redpotion + amount

    -- Ordered iteration, not `pairs` over a team-keyed literal: the body feeds
    -- and the order has to be the same on every client. `Teams.all()` is north
    -- then south at two teams, one `do_raw_feed` per team with players as today.
    -- Checked in game: Factorio's `pairs` walks a string-keyed table in
    -- INSERTION order, so the `{ north_biters = ..., south_biters = ... }`
    -- literal this replaces ran north then south too (plain lua5.2 on a command
    -- line orders by hash and does not show that).
    local a_team_has_players = false
    for _, team in ipairs(passive_feed_teams()) do
        if #game.forces[team].connected_players > 0 then
            Feeding.do_raw_feed(amount, 'automation-science-pack', Teams.biter_force(team))
            a_team_has_players = true
        end
    end
    if not a_team_has_players then
        return
    end
    storage.evo_raise_counter = storage.evo_raise_counter + (1 * 0.50)

    -- tt_mode: re-derive canonical evo from cumulative RAW mutagen at the new
    -- difficulty (plan §D — retroactive send). Idempotent and pure.
    if storage.tt_mode then
        require('maps.biter_battles_v2.tt_mode').tt_recompute_all()
    end
end

Public.reset_evo = function()
    -- Shouldn't reset evo if any of the teams fed. Feeding is blocked when voting is in progress.
    -- However, if /difficulty-revote is done late in a game, we don't want to reset evo.
    if storage.science_logs_text then
        return
    end

    local amount = storage.total_passive_feed_redpotion
    if amount < 1 then
        return
    end
    storage.total_passive_feed_redpotion = 0

    -- Same ordered walk as `raise_evo`, over the same teams, and the same
    -- interleaving as before: each force is zeroed and immediately re-fed
    -- before the next one is touched. An eliminated team is not re-fed above
    -- two teams -- its evolution is frozen where it died. Same check as there:
    -- Factorio's `pairs` walks a string-keyed table in INSERTION order, so the
    -- literal this replaces ran north then south as well.
    for _, team in ipairs(passive_feed_teams()) do
        local biter_force_name = Teams.biter_force(team)
        storage.bb_evolution[biter_force_name] = 0
        Feeding.do_raw_feed(amount, 'automation-science-pack', biter_force_name)
    end
end

--- Cache of "boss biter force -> the regular biter force it belongs to", with
--- `false` for every force name that is not a boss force.
---
--- `subtract_threat` runs on every biter death -- the hottest AI path in the
--- scenario -- and `Teams.team_of_biter_force` derives its answer with a pattern
--- match. Memoising on the force name keeps the death hook allocation-free after
--- the first death of each kind. The mapping is a property of the static roster,
--- so it cannot go stale between rounds.
---@type table<string, string|false>
local base_force_of_boss = {}

---The regular biter force behind a boss force, or false for anything else.
---@param force_name string
---@return string|false
local function boss_base_force(force_name)
    local cached = base_force_of_boss[force_name]
    if cached ~= nil then
        return cached
    end
    local team = Teams.team_of_biter_force(force_name)
    local base = false
    if team ~= nil and Teams.boss_force(team) == force_name then
        base = Teams.biter_force(team)
    end
    base_force_of_boss[force_name] = base
    return base
end

--Biter Threat Value Subtraction
function Public.subtract_threat(entity)
    if not threat_values[entity.name] then
        return
    end
    local biter_not_boss_force = entity.force.name
    local is_boss = false
    local factor = 1
    local from_non_positive_threat_factor = 0.5
    local is_from_non_positive_threat = not storage.biters_from_positive_threat[entity.unit_number]

    local base_force = boss_base_force(entity.force.name)
    if base_force then
        biter_not_boss_force = base_force
        is_boss = true
    end
    if is_boss == true then
        local health_buff_equivalent_revive = storage.biter_health_factor[game.forces[biter_not_boss_force].index]
        factor = bb_config.health_multiplier_boss * health_buff_equivalent_revive
    elseif entity.type == 'unit-spawner' then
        local evo = game.forces[biter_not_boss_force].get_evolution_factor(entity.surface.name)
        factor = 1 + 9 * evo ^ 2.25
    end
    -- 2-team only special (guarded by max_teams)
    if storage.active_special_games['threat_farm_threshold'] then
        local threat_value = threat_values[entity.name] * factor
        local special_variables = storage.special_games_variables['threat_farm_threshold']
        local threat_below_threshold = special_variables.threat_threshold
            - (storage.bb_threat[biter_not_boss_force] - threat_value)
        local enemy_force
        if threat_below_threshold > 0 then
            storage.bb_threat[biter_not_boss_force] = special_variables.threat_threshold
            if biter_not_boss_force == 'south_biters' then
                enemy_force = 'north_biters'
            else
                enemy_force = 'south_biters'
            end
            storage.bb_threat[enemy_force] = storage.bb_threat[enemy_force]
                + threat_below_threshold * special_variables.excess_threat_send_fraction
        else
            storage.bb_threat[biter_not_boss_force] = storage.bb_threat[biter_not_boss_force] - threat_value
        end
        return true
    end

    if entity.type == 'unit' and is_from_non_positive_threat then
        factor = factor * from_non_positive_threat_factor
    end
    storage.bb_threat[biter_not_boss_force] = storage.bb_threat[biter_not_boss_force]
        - threat_values[entity.name] * factor
    storage.biters_from_positive_threat[entity.unit_number] = nil
    return true
end

return Public
