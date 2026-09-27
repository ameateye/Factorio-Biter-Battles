local Public = {}
local LootRaffle = require('functions.loot_raffle')
local BiterRaffle = require('maps.biter_battles_v2.biter_raffle')
local bb_config = require('maps.biter_battles_v2.config')
local Layout = require('maps.biter_battles_v2.layout')
local Teams = require('maps.biter_battles_v2.teams')
local mixed_ore_map_special = require('maps.biter_battles_v2.mixed_ore_map_special')
local multi_octave_noise = require('utils.multi_octave_noise')
local noise = require('maps.biter_battles_v2.predefined_noise')
local AiTargets = require('maps.biter_battles_v2.ai_targets')
local tables = require('maps.biter_battles_v2.tables')
local session = require('utils.datastore.session_data')
local biter_texture = require('maps.biter_battles_v2.precomputed.biter_texture')
local river = require('maps.biter_battles_v2.precomputed.river')

local ai_targets_start_tracking = AiTargets.start_tracking
local bb_config_bitera_area_distance = bb_config.bitera_area_distance
local bb_config_biter_area_slope = bb_config.biter_area_slope
local biter_raffle_roll = BiterRaffle.roll
local spawn_ore = tables.spawn_ore
local table_insert = table.insert
local table_remove = table.remove
local math_abs = math.abs
local math_ceil = math.ceil
local math_floor = math.floor
local math_max = math.max
local math_min = math.min
local math_random = math.random
local math_sqrt = math.sqrt

local get_noise = multi_octave_noise.get
local get_lower_bounded_noise = multi_octave_noise.get_lower_bounded
local get_upper_bounded_noise = multi_octave_noise.get_upper_bounded
local get_noise_between_bounds = multi_octave_noise.get_between_bounds

function amp_sum(octaves)
    local result = 0
    for _, octave in pairs(octaves) do
        result = result + octave.amp
    end
    return result
end

local biter_area_border_noise = noise.biter_area_border
local biter_area_border_noise_amp_sum = amp_sum(biter_area_border_noise)

local mixed_ore_noise = noise.mixed_ore
local mixed_ore_noise_amp_sum = 1.0 -- normalized

local spawn_wall_noise = noise.spawn_wall
local spawn_wall_noise_amp_sum = amp_sum(spawn_wall_noise)

local spawn_wall_2_noise = noise.spawn_wall_2
local spawn_wall_2_noise_amp_sum = amp_sum(spawn_wall_2_noise)

local spawn_ore_noise = noise.spawn_ore
local spawn_ore_noise_amp_sum = amp_sum(spawn_ore_noise)

local biter_texture_width = biter_texture.width
local biter_texture_height = biter_texture.height
local biter_texture_grid = biter_texture.grid
local biter_texture_map = biter_texture.map

local river_offset = river.offset
local river_size = river.size

-- pre-map
for x = 1, biter_texture_width do
    for y = 1, biter_texture_height do
        biter_texture_grid[x][y] = biter_texture_map[biter_texture_grid[x][y]]
    end
end

-- avoid allocations to improve performance and maybe reduce gc lag
local preallocated_out_of_map_tiles = {}
local preallocated_tiles = {}
for i = 1, 32 * 32 do
    preallocated_out_of_map_tiles[i] = { name = 'out-of-map', position = { 0, 0 } }
    preallocated_tiles[i] = { name = '', position = { 0, 0 } }
end
local next_preallocated_tile = 1

-- max value 64
local river_circle_size = 39

local river_width_half = math_floor(bb_config.border_river_width * 0.5)

-- max value 32
local spawn_island_size = 9

local ores = {
    'iron-ore',
    'copper-ore',
    'iron-ore',
    'stone',
    'copper-ore',
    'iron-ore',
    'copper-ore',
    'iron-ore',
    'coal',
    'iron-ore',
    'copper-ore',
    'iron-ore',
    'stone',
    'copper-ore',
    'coal',
}
-- mixed_ore_multiplier order is based on the ores variable
local mixed_ore_multiplier = { 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1 }
local rocks = { 'huge-rock', 'big-rock', 'big-rock', 'big-rock', 'big-sand-rock' }

-- 32 * 32 buffers
local chunk_buffer = {}
local chunk_buffer2 = {}

local chunk_tile_vectors = {}
for x = 0, 31, 1 do
    for y = 0, 31, 1 do
        chunk_tile_vectors[#chunk_tile_vectors + 1] = { x, y }
    end
end
local size_of_chunk_tile_vectors = #chunk_tile_vectors

local loading_chunk_vectors = {}
for _, v in pairs(chunk_tile_vectors) do
    if v[1] == 0 or v[1] == 31 or v[2] == 0 or v[2] == 31 then
        table_insert(loading_chunk_vectors, v)
    end
end

local wrecks = {
    'crash-site-spaceship-wreck-big-1',
    'crash-site-spaceship-wreck-big-2',
    'crash-site-spaceship-wreck-medium-1',
    'crash-site-spaceship-wreck-medium-2',
    'crash-site-spaceship-wreck-medium-3',
}
local size_of_wrecks = #wrecks
local valid_wrecks = {}
for _, wreck in pairs(wrecks) do
    valid_wrecks[wreck] = true
end
local loot_blacklist = {
    ['automation-science-pack'] = true,
    ['logistic-science-pack'] = true,
    ['military-science-pack'] = true,
    ['chemical-science-pack'] = true,
    ['production-science-pack'] = true,
    ['utility-science-pack'] = true,
    ['space-science-pack'] = true,
    ['loader'] = true,
    ['fast-loader'] = true,
    ['express-loader'] = true,
}

function Public.adjust_map_gen_settings(map_gen_settings)
    map_gen_settings.starting_area = 2.5
    map_gen_settings.property_expression_names = {
        ['segmentation_multiplier'] = 0.1,
        ['control:moisture:bias'] = 0.2,
    }
    map_gen_settings.cliff_settings = { cliff_elevation_interval = 0, cliff_elevation_0 = 0 }
    map_gen_settings.autoplace_controls = {
        ['coal'] = { frequency = 6.5, size = 0.34, richness = 0.24 },
        ['water'] = {
            frequency = 10,
            size = 0.3,
            richness = 0.1,
        },
        ['stone'] = { frequency = 6, size = 0.385, richness = 0.25 },
        ['copper-ore'] = { frequency = 8.05, size = 0.352, richness = 0.35 },
        ['iron-ore'] = { frequency = 8.5, size = 0.8, richness = 0.23 },
        ['uranium-ore'] = { frequency = 2.2, size = 1, richness = 1 },
        ['crude-oil'] = { frequency = 8, size = 1.4, richness = 0.45 },
        ['trees'] = {
            frequency = 0.65,
            size = 0.04,
            richness = 0.002,
        },
        ['enemy-base'] = { frequency = 0, size = 0, richness = 0 },
    }
    mixed_ore_map_special.adjust_map_gen_settings(map_gen_settings)
end

---@enum area_intersection
area_intersection = {
    none = 1,
    partial = 2,
    full = 3,
}

---Analyzes partiality of intersection of a north chunk and the biter area
---@param chunk_pos {x: int, y: int} north chunk position (not tile position)
---@return area_intersection
local function chunk_biter_area_intersection(chunk_pos)
    local left_top_x = chunk_pos.x * 32
    local right_top_x = left_top_x + 32 - 1

    local bitera_area_distance = bb_config.bitera_area_distance * -1
    local min_slope = bitera_area_distance - (math_abs(left_top_x) * bb_config.biter_area_slope)
    local max_slope = bitera_area_distance - (math_abs(right_top_x) * bb_config.biter_area_slope)
    if min_slope > max_slope then
        min_slope, max_slope = max_slope, min_slope
    end
    local top = chunk_pos.y * 32
    local bottom = top + 32 - 1
    if top - 70 > max_slope then
        return area_intersection.none
    elseif bottom + 70 < min_slope then
        return area_intersection.full
    else
        return area_intersection.partial
    end
end

---@enum chunk_type
chunk_type = {
    river = 1,
    ordinary = 2,
    biter_area_border = 3,
    biter_area = 4,
}

---@param chunk_pos {x: int, y: int} north chunk position (not tile position)
---@return chunk_type
function chunk_type_at(chunk_pos)
    if chunk_pos.y == -1 or (chunk_pos.y == -2 and (chunk_pos.x == -1 or chunk_pos.x == 0)) then
        return chunk_type.river
    end

    local biterland_intersection = chunk_biter_area_intersection(chunk_pos)
    if biterland_intersection == area_intersection.none then
        return chunk_type.ordinary
    elseif biterland_intersection == area_intersection.partial then
        return chunk_type.biter_area_border
    else
        return chunk_type.biter_area
    end
end

local function draw_noise_ore_patch(x, y, name, surface, radius, richness)
    local ore_template = { name = 'iron-ore', position = { 0, 0 }, amount = 1 }
    local remove_structures_template = { position = { 0, 0 }, name = { 'wooden-chest', 'stone-wall', 'gun-turret' } }

    local seed = surface.map_gen_settings.seed
    local can_place_entity = surface.can_place_entity
    local create_entity = surface.create_entity
    local find_entities_filtered = surface.find_entities_filtered

    local richness_part = richness / radius
    for dy = radius * -3, radius * 3, 1 do
        for dx = radius * -3, radius * 3, 1 do
            local distance_to_center = math_sqrt(dx ^ 2 + dy ^ 2)
            local amount = richness - richness_part * distance_to_center
            if amount > 1 then
                local ore_x, ore_y = x + dx, y + dy

                -- old equation
                -- distance_to_center < radius - math_abs(noise * radius * 0.85)
                local bound = (radius - distance_to_center) / (radius * 0.85)
                local noise = get_noise_between_bounds(
                    spawn_ore_noise,
                    spawn_ore_noise_amp_sum,
                    ore_x,
                    ore_y,
                    seed,
                    25000,
                    -bound,
                    bound
                )

                if noise then
                    local pos = { ore_x, ore_y }
                    ore_template.position = pos
                    ore_template.name = name
                    ore_template.amount = amount
                    if can_place_entity(ore_template) then
                        create_entity(ore_template)
                        remove_structures_template.position = pos
                        for _, e in pairs(find_entities_filtered(remove_structures_template)) do
                            e.destroy()
                        end
                    end
                end
            end
        end
    end
end

-- distance to the center of the map from the center of the tile
local function tile_distance_to_center(x, y)
    return math_sqrt((x + 0.5) ^ 2 + (y + 0.5) ^ 2)
end

local function is_within_spawn_island(x, y)
    if math_abs(x) > spawn_island_size then
        return false
    end
    if math_abs(y) > spawn_island_size then
        return false
    end
    if tile_distance_to_center(x, y) > spawn_island_size then
        return false
    end
    return true
end

local function is_horizontal_border_river(x, y, seed)
    if tile_distance_to_center(x, y) < river_circle_size then
        return true
    end

    -- Offset contains coefficient in a range between [0,4]. Select it
    -- from pre-computed table. Position X coordinate is used to determinate
    -- which offset is selected.
    local offset = river.offset[(x + seed) % river.size]
    y = -(y + offset)
    return (y <= river_width_half)
end

--- Calculates tile y coordinate which has top border closest to the intersection point of the middle
---  of a vertical column and the top (negative) part of a circle at the origin, ties prefer tile below (towards positive)
---@param column_x number tile column x coordinate
---@param circle_radius number
---@return number? tile_y # intersection point, if any
local function tile_near_column_with_origin_circle_intersection(column_x, circle_radius)
    local tile_center = 0.5
    local circle_y_intersection_sq = circle_radius ^ 2 - (column_x + tile_center) ^ 2
    if circle_y_intersection_sq < 0 then
        return nil
    end
    local circle_y_intersection = -math_sqrt(circle_y_intersection_sq)
    -- round, tie breaker ceil
    circle_y_intersection = math_floor(circle_y_intersection + 0.5)
    return circle_y_intersection
end

---@param chunk_pos {x: number, y: number}
---@return boolean
local function in_spawn_river_circle_bbox(chunk_pos)
    return chunk_pos.y >= -2 and chunk_pos.x >= -2 and chunk_pos.x < 2
end

---@param seed any
---@param x number
---@param include_spawn_circle boolean
---@return number y
local function river_start(seed, x, include_spawn_circle)
    -- Offset contains coefficient in a range between [0, 4]. Select it
    -- from pre-computed table. Position X coordinate is used to determinate
    -- which offset is selected.
    local offset = river_offset[(x + seed) % river_size]
    local start = -river_width_half - offset

    if include_spawn_circle then
        local circle_y_intersection = tile_near_column_with_origin_circle_intersection(x, river_circle_size)
        if circle_y_intersection then
            start = math_min(start, circle_y_intersection)
        end
    end

    return start
end

---True for a tile of the canonical quadrant that the SIDE river covers.
---
---The four-square map gives every team a second river, along the other axis, and
---that river is the legacy one TRANSPOSED: the tile (x, y) is side-river water
---exactly when the legacy generator makes the tile (y, x) front-river water.
---Same half width, same 4096-entry offset table (read at the OTHER coordinate)
---and the same central lake of radius `river_circle_size`, so the four arms of
---the cross meet in one round lake.
---
---`river_start` already answers "where does the water of this COLUMN start";
---handed the row instead of the column it answers "where does the water of this
---ROW start", and that is the whole of the transposition. `y >= -64 and y < 64`
---is `generate_river`'s own `chunk_pos.x >= -2 and chunk_pos.x < 2` transposed:
---the rows the central lake reaches.
---
---The spectator island is water in neither arm, so it is cut out of this one too.
---Nothing on the two-team map calls this.
---@param seed uint
---@param x number tile x
---@param y number tile y
---@return boolean
function Public.is_side_river_tile(seed, x, y)
    if is_within_spawn_island(x, y) then
        return false
    end
    return x >= river_start(seed, y, y >= -64 and y < 64)
end

local is_side_river_tile = Public.is_side_river_tile

---True for a canonical chunk the side river can reach -- the chunks the carve
---pass has to visit, and the only ones.
---
---It is `chunk_type_at`'s river test transposed and cut down to the canonical
---quadrant: `cy == -1 or (cy == -2 and cx in {-1, 0})` becomes
---`cx == -1 or (cx == -2 and cy in {-1, 0})`, of which only `cy == -1` is
---canonical. The arm itself is never wider than `river_width_half + 4 = 26`
---tiles and so lives in chunk column -1; only the lake reaches further west, to
---x = -39, and only for the rows next to the axis.
---@param chunk_pos {x: int, y: int} canonical chunk position (not tile position)
---@return boolean
function Public.chunk_has_side_river(chunk_pos)
    return chunk_pos.x == -1 or (chunk_pos.x == -2 and chunk_pos.y == -1)
end

---@param chunk_pos {x: number, y: number}
local function is_outside_spawn(chunk_pos)
    return chunk_pos.x < -5 or chunk_pos.x >= 5 or chunk_pos.y < -5
end

local ore_template = { name = 'iron-ore', position = { 0, 0 }, amount = 1 }

---@param can_place_entity fun(LuaSurface.can_place_entity_param): boolean
---@param create_entity fun(LuaSurface.create_entity_param): LuaEntity?
---@param seed uint
---@param x number
---@param y number
---@param rng LuaRandomGenerator
local function generate_ordinary_tile(can_place_entity, create_entity, seed, x, y, rng)
    local noise = get_lower_bounded_noise(mixed_ore_noise, mixed_ore_noise_amp_sum, x, y, seed, 10000, 0.6)
    if noise then
        ore_template.position[1], ore_template.position[2] = x, y
        ore_template.name = 'iron-ore'
        ore_template.amount = 1
        if can_place_entity(ore_template) then
            local i = math_floor(noise * 25 + math_abs(x) * 0.05) % 15 + 1
            local amount = (rng(800, 1000) + math_sqrt(x ^ 2 + y ^ 2) * 3) * mixed_ore_multiplier[i]
            ore_template.name = ores[i]
            ore_template.amount = amount
            create_entity(ore_template)
        end
    end
end

local impactful_mixed_ore_noise = { mixed_ore_noise[1] }

local function chunk_noise_hint(seed, chunk_pos)
    local mid_x, mid_y = chunk_pos.x * 32 + 16, chunk_pos.y * 32 + 16
    return get_noise(impactful_mixed_ore_noise, mid_x, mid_y, seed, 10000)
end

-- calculate_chunk_has_ore_hint()
-- local chunk_has_ore_hint = -0.081660016785248 -- way too conservative
local chunk_has_ore_hint = 0.16

---@param surface LuaSurface
---@param chunk_pos {x: number, y: number}
---@return fun(x: number, y: number, rng: LuaRandomGenerator)?
local function get_tile_generator(surface, chunk_pos)
    local special_gen = mixed_ore_map_special.get_tile_generator(surface, chunk_pos)
    local suppress_tile_gen = special_gen == false
    if suppress_tile_gen then
        return nil
    elseif special_gen ~= nil then
        return special_gen ---@type fun(x: number, y: number, rng: LuaRandomGenerator)
    end
    if not is_outside_spawn(chunk_pos) then
        return nil
    end
    local seed = surface.map_gen_settings.seed
    if chunk_noise_hint(seed, chunk_pos) < chunk_has_ore_hint then
        return nil
    end
    local can_place_entity = surface.can_place_entity
    local create_entity = surface.create_entity
    return function(x, y, rng)
        generate_ordinary_tile(can_place_entity, create_entity, seed, x, y, rng)
    end
end

local DEFAULT_HIDDEN_TILE = 'dirt-3'

local spawn_wall_radius = 116
local spawn_wall_noise_multiplier = 15
local spawn_wall_noise_deviation = spawn_wall_noise_multiplier * spawn_wall_noise_amp_sum

local concrete_circle_radius = spawn_wall_radius - (10 + spawn_wall_noise_deviation)
local spawn_wall_noise_radius = spawn_wall_radius + (4.5 + spawn_wall_noise_deviation)

---@param surface LuaSurface
---@param chunk_pos {x: number, y: number}
---@param rng LuaRandomGenerator
---@param cross4 boolean|nil four-square map: clip the ring at the SIDE river too
local function generate_starting_area(surface, chunk_pos, rng, cross4)
    local wooden_chest_template = { name = 'wooden-chest', position = { 0, 0 }, force = 'north' }
    local coal_template = { name = 'coal', position = { 0, 0 } }
    local stone_wall_template = { name = 'stone-wall', position = { 0, 0 }, force = 'north' }
    local gun_turret_template = { name = 'gun-turret', position = { 0, 0 }, force = 'north' }
    local gun_turret_remnants_template = { name = 'gun-turret-remnants', position = { 0, 0 }, force = 'neutral' }
    local fire_magazine_template = { name = 'firearm-magazine', count = 0 }

    local seed = surface.map_gen_settings.seed
    local left_top_x = chunk_pos.x * 32
    local left_top_y = chunk_pos.y * 32
    local is_river_chunk = chunk_type_at(chunk_pos) == chunk_type.river
    local in_spawn_river_circle_bb = in_spawn_river_circle_bbox(chunk_pos)
    local mixed_ore_map_special_active = storage.active_special_games['mixed_ore_map']
    local can_place_entity = surface.can_place_entity
    local create_entity = surface.create_entity
    local get_tile = surface.get_tile
    local concrete_foundation = {}
    local concrete = {}

    -- distance_from_spawn_wall is the difference between the distance_to_center (with added noise)
    -- and our spawn_wall radius (spawn_wall_radius=116), i.e. how far are we from the ring with radius spawn_wall_radius.
    -- The following shows what happens depending on distance_from_spawn_wall:
    --   	min     max
    --  	N/A     -10	    => replace water
    -- if noise_2 > -0.4:
    --      -1.75    0 	    => wall
    -- else:
    --   	-6      -3 	 	=> 1/16 chance of turret or turret-remnants
    --   	-1.95    0 	 	=> wall
    --    	 0       4.5    => chest-remnants with 1/3, chest with 1/(distance_from_spawn_wall+2)
    --
    -- => We never do anything for (distance_to_center + min_noise - spawn_wall_radius) > 4.5
    for x = left_top_x, left_top_x + 32 - 1 do
        local noise_start = tile_near_column_with_origin_circle_intersection(x, spawn_wall_noise_radius)
        noise_start = noise_start and math_max(noise_start, left_top_y) or (left_top_y + 32)
        noise_end = left_top_y + 32 - 1

        local concrete_start = tile_near_column_with_origin_circle_intersection(x, concrete_circle_radius)
        if concrete_start then
            noise_end = math_min(noise_end, concrete_start - 1)
        else
            concrete_start = left_top_y + 32
        end

        local concrete_end = left_top_y + 32 - 1
        if is_river_chunk then
            local river_start = river_start(seed, x, in_spawn_river_circle_bb)
            concrete_end = math_min(concrete_end, river_start - 1)
            noise_end = math_min(noise_end, river_start - 1)
        end

        -- The two-team map clips the disc and the ring at the ONE river in front
        -- of the team (above). The four-square map gives the quadrant a second
        -- river along the other axis, and that one is a half-line of each ROW,
        -- not of each column, so it cannot be a bound of these two loops: it is
        -- a test per cell. Both loops skip it, so neither concrete nor wall nor
        -- turret ends up in the water the carve pass has taken.
        for y = concrete_start, concrete_end do
            if not (cross4 and is_side_river_tile(seed, x, y)) then
                if get_tile(x, y).collides_with('resource') then
                    concrete_foundation[#concrete_foundation + 1] = { name = DEFAULT_HIDDEN_TILE, position = { x, y } }
                end
                concrete[#concrete + 1] = { name = 'refined-concrete', position = { x, y } }
            end
        end

        for y = noise_start, noise_end do
            if cross4 and is_side_river_tile(seed, x, y) then
                goto continue
            end

            local distance_to_center = tile_distance_to_center(x, y)
            local noise = get_noise(spawn_wall_noise, x, y, seed, 25000) * spawn_wall_noise_multiplier
            local distance_from_spawn_wall = distance_to_center + noise - spawn_wall_radius

            local pos = { x, y }
            if distance_from_spawn_wall < -10 then
                if get_tile(x, y).collides_with('resource') then
                    concrete_foundation[#concrete_foundation + 1] = { name = DEFAULT_HIDDEN_TILE, position = pos }
                end
                concrete[#concrete + 1] = { name = 'refined-concrete', position = pos }
                goto continue
            end

            wooden_chest_template.name = 'wooden-chest'
            wooden_chest_template.position = pos
            coal_template.position = pos
            if
                not can_place_entity(wooden_chest_template)
                or (not mixed_ore_map_special_active and not can_place_entity(coal_template))
            then
                goto continue
            end

            local noise_2 = get_upper_bounded_noise(spawn_wall_2_noise, spawn_wall_2_noise_amp_sum, x, y, seed, 0, 0.4)
            if not noise_2 then
                goto continue
            end

            if noise_2 > -0.40 then
                if distance_from_spawn_wall > -1.75 and distance_from_spawn_wall < 0 then
                    stone_wall_template.position = pos
                    create_entity(stone_wall_template)
                end
                goto continue
            end

            if distance_from_spawn_wall > -1.95 and distance_from_spawn_wall < 0 then
                stone_wall_template.position = pos
                create_entity(stone_wall_template)
            elseif distance_from_spawn_wall > 0 and distance_from_spawn_wall < 4.5 then
                local r_max = math_floor(math_abs(distance_from_spawn_wall)) + 2
                if rng(1, 3) == 1 then
                    wooden_chest_template.name = 'wooden-chest-remnants'
                end
                if rng(1, r_max) == 1 then
                    create_entity(wooden_chest_template)
                end
            elseif distance_from_spawn_wall > -6 and distance_from_spawn_wall < -3 then
                if rng(1, 16) == 1 then
                    gun_turret_template.position = pos
                    if can_place_entity(gun_turret_template) then
                        local turret = surface.create_entity(gun_turret_template)
                        fire_magazine_template.count = rng(2, 16)
                        turret.insert(fire_magazine_template)
                        ai_targets_start_tracking(turret)
                    end
                else
                    if rng(1, 24) == 1 then
                        gun_turret_template.position = pos
                        if can_place_entity(gun_turret_template) then
                            gun_turret_remnants_template.position = pos
                            surface.create_entity(gun_turret_remnants_template)
                        end
                    end
                end
            end

            ::continue::
        end
    end

    surface.set_tiles(concrete_foundation, false)
    local tile_gen = get_tile_generator(surface, chunk_pos)
    if tile_gen then
        for _, filler in pairs(concrete_foundation) do
            local pos = filler.position
            tile_gen(pos[1], pos[2], rng)
        end
    end
    surface.set_tiles(concrete, true)
end

---@param surface LuaSurface
---@param chunk_pos {x: number, y: number}
---@param rng LuaRandomGenerator
local function generate_river(surface, chunk_pos, rng)
    local fish_template = { name = 'fish', position = { 0.5, 0.5 } }

    local chunk_pos_x = chunk_pos.x
    local chunk_pos_y = chunk_pos.y
    local left_top_x = chunk_pos.x * 32
    local left_top_y = chunk_pos.y * 32
    local seed = surface.map_gen_settings.seed
    local in_spawn_river_circle_bbox = chunk_pos.x >= -2 and chunk_pos.x < 2
    local create_entity = surface.create_entity
    local tile_gen = get_tile_generator(surface, chunk_pos)

    local tiles = {}
    local i = 1

    -- fill vertically strip by strip, dividing into river/ordinary/spec_island parts
    for x = left_top_x, left_top_x + 32 - 1 do
        local river_border_start_y = river_start(seed, x, in_spawn_river_circle_bbox)
        river_border_start_y = math_max(river_border_start_y, left_top_y)

        local river_border_end_y = left_top_y + 32 - 1
        local is_spec_island_chunk = (chunk_pos_x == -1 or chunk_pos_x == 0) and chunk_pos_y == -1
        if is_spec_island_chunk then
            local circle_y_intersection = tile_near_column_with_origin_circle_intersection(x, spawn_island_size)
            if circle_y_intersection then
                local spec_island_start = math_min(river_border_end_y, circle_y_intersection)
                river_border_end_y = spec_island_start - 1
            end
        end

        if tile_gen then
            for y = left_top_y, river_border_start_y - 1 do
                tile_gen(x, y, rng)
            end
        end

        for y = river_border_start_y, river_border_end_y do
            local tile = preallocated_tiles[next_preallocated_tile]
            next_preallocated_tile = (next_preallocated_tile % (32 * 32)) + 1

            tile.name = 'deepwater'
            tile.position[1], tile.position[2] = x, y
            tiles[i] = tile
            i = i + 1
            if rng(1, 64) == 1 then
                fish_template.position[1], fish_template.position[2] = x + 0.5, y + 0.5
                create_entity(fish_template)
            end
        end
    end
    surface.set_tiles(tiles)
end

local scrap_vectors = {}
for x = -8, 8, 1 do
    for y = -8, 8, 1 do
        if math_sqrt(x ^ 2 + y ^ 2) <= 8 then
            scrap_vectors[#scrap_vectors + 1] = { x, y }
        end
    end
end
local size_of_scrap_vectors = #scrap_vectors

local function populate_with_extra_worm_turrets(surface, chunk_pos, rng)
    local worm_template = { name = '', position = { 0, 0 }, force = 'north_biters' }
    local scrap_template = { name = '', position = { 0, 0 }, force = 'neutral', create_build_effect_smoke = false }

    local left_top_x = chunk_pos.x * 32
    local left_top_y = chunk_pos.y * 32

    local chunk_distance_to_center = math_sqrt(left_top_x ^ 2 + left_top_y ^ 2)
    if bb_config.bitera_area_distance > chunk_distance_to_center then
        return
    end

    local amount = (chunk_distance_to_center - bb_config.bitera_area_distance) * 0.0005
    if amount < 0 then
        return
    end
    local floor_amount = math_floor(amount)
    local r = math.round(amount - floor_amount, 3) * 1000
    if rng(0, 999) <= r then
        floor_amount = floor_amount + 1
    end

    if floor_amount > 64 then
        floor_amount = 64
    end

    local find_non_colliding_position = surface.find_non_colliding_position
    local create_entity = surface.create_entity
    for _ = 1, floor_amount, 1 do
        local worm_turret_name = biter_raffle_roll('worm', chunk_distance_to_center * 0.00015)
        local v = chunk_tile_vectors[rng(1, size_of_chunk_tile_vectors)]
        local position = find_non_colliding_position(worm_turret_name, { left_top_x + v[1], left_top_y + v[2] }, 8, 1)
        if position then
            worm_template.name = worm_turret_name
            worm_template.position = position
            local worm = create_entity(worm_template)

            -- add some scrap
            for _ = 1, rng(0, 4), 1 do
                local vector = scrap_vectors[rng(1, size_of_scrap_vectors)]
                local position = { worm.position.x + vector[1], worm.position.y + vector[2] }
                local name = wrecks[rng(1, size_of_wrecks)]
                position = find_non_colliding_position(name, position, 16, 1)
                if position then
                    scrap_template.name = name
                    scrap_template.position = position
                    local e = create_entity(scrap_template)
                end
            end
        end
    end
end

---@param x number
---@param y number
---@param seed number
---@param a number biter area slope start
---@return boolean
local function biter_area_noise_test(x, y, seed, a)
    -- original test
    -- return y + (get_noise(biter_area_border_noise, x, y, seed, 0) * 64) <= a
    local noise =
        get_lower_bounded_noise(biter_area_border_noise, biter_area_border_noise_amp_sum, x, y, seed, 0, (a - y) / 64)
    return noise == nil
end

---@param seed uint
---@param x number
---@param y number
---@return boolean
local function is_biter_area(seed, x, y)
    local bitera_area_distance = bb_config_bitera_area_distance * -1
    local a = bitera_area_distance - (math_abs(x) * bb_config_biter_area_slope)
    if y - 70 > a then
        return false
    end
    if y + 70 < a then
        return true
    end
    return biter_area_noise_test(x, y, seed, a)
end

local function populate_biter_area(surface, chunk_pos, rng, is_biter_area_chunk)
    local spitter_spawner_template = { name = 'spitter-spawner', position = { 0, 0 }, force = 'north_biters' }
    local biter_spawner_template = { name = 'biter-spawner', position = { 0, 0 }, force = 'north_biters' }
    local worm_turret_template = { name = '', position = { 0, 0 }, force = 'north_biters' }

    local left_top_x = chunk_pos.x * 32
    local left_top_y = chunk_pos.y * 32
    local seed = surface.map_gen_settings.seed
    local unit_spawners = storage.unit_spawners

    local can_place_entity = surface.can_place_entity
    local create_entity = surface.create_entity

    for _ = 1, 4 do
        local v = chunk_tile_vectors[rng(1, size_of_chunk_tile_vectors)]
        local x, y = left_top_x + v[1], left_top_y + v[2]
        spitter_spawner_template.position[1], spitter_spawner_template.position[2] = x, y
        if (is_biter_area_chunk or is_biter_area(seed, x, y)) and can_place_entity(spitter_spawner_template) then
            local e
            if rng(1, 4) == 1 then
                e = create_entity(spitter_spawner_template)
            else
                biter_spawner_template.position[1], biter_spawner_template.position[2] = x, y
                e = create_entity(biter_spawner_template)
            end
            table_insert(unit_spawners[e.force.name], e)
        end
    end

    local e = (math_abs(left_top_y) - bb_config_bitera_area_distance) * 0.0015
    for _ = 1, rng(5, 10), 1 do
        local v = chunk_tile_vectors[rng(1, size_of_chunk_tile_vectors)]
        local x, y = left_top_x + v[1], left_top_y + v[2]
        worm_turret_template.name = biter_raffle_roll('worm', e)
        worm_turret_template.position[1], worm_turret_template.position[2] = x, y
        if (is_biter_area_chunk or is_biter_area(seed, x, y)) and can_place_entity(worm_turret_template) then
            create_entity(worm_turret_template)
        end
    end
end

---@param seed uint
---@param x number
---@param y number
---@return any out_of_map_tile, any tile # returns params for `set_tile`
local function get_biter_area_tile(seed, x, y)
    -- Maps the relative x/y position into biter_texture with pre-computed 2D grid.
    -- The value from the grid is then mapped into tile name.
    -- + 1, because lua has 1-based indices
    local grid_p_x = ((x + seed) % biter_texture_width) + 1
    local grid_p_y = ((y + seed) % biter_texture_height) + 1
    local name = biter_texture_grid[grid_p_x][grid_p_y]

    local out_of_map = preallocated_out_of_map_tiles[next_preallocated_tile]
    local tile = preallocated_tiles[next_preallocated_tile]
    next_preallocated_tile = (next_preallocated_tile % (32 * 32)) + 1

    out_of_map.position[1], out_of_map.position[2] = x, y
    tile.position[1], tile.position[2] = x, y
    tile.name = name
    return out_of_map, tile
end

---@param surface LuaSurface
---@param chunk_pos {x: number, y: number}
---@param rng LuaRandomGenerator
local function generate_biter_area_border(surface, chunk_pos, rng)
    local bitera_area_distance = bb_config.bitera_area_distance * -1
    local left_top_x = chunk_pos.x * 32
    local left_top_y = chunk_pos.y * 32
    local seed = surface.map_gen_settings.seed
    local tile_gen = get_tile_generator(surface, chunk_pos)

    local out_of_map = {}
    local tiles = {}
    local i = 1

    -- fill vertically strip by strip, dividing into biter_area/transitional/ordinary parts
    for x = left_top_x, left_top_x + 32 - 1 do
        local a = bitera_area_distance - math_abs(x) * bb_config_biter_area_slope

        local transitional_area_start = math_ceil(a - 70)
        local transitional_area_end = math_floor(a + 70)

        local biter_area_end = math_min(left_top_y + 32 - 1, transitional_area_start - 1)
        local ordinary_start = math_max(transitional_area_end + 1, left_top_y)
        transitional_area_start = math_max(transitional_area_start, left_top_y)
        transitional_area_end = math_min(left_top_y + 32 - 1, transitional_area_end)

        for y = left_top_y, biter_area_end do
            out_of_map[i], tiles[i] = get_biter_area_tile(seed, x, y)
            i = i + 1
        end

        for y = transitional_area_start, transitional_area_end do
            local is_biter_area = biter_area_noise_test(x, y, seed, a)
            if is_biter_area then
                out_of_map[i], tiles[i] = get_biter_area_tile(seed, x, y)
                i = i + 1
            elseif tile_gen then
                tile_gen(x, y, rng)
            end
        end

        if tile_gen then
            for y = ordinary_start, left_top_y + 32 - 1 do
                tile_gen(x, y, rng)
            end
        end
    end

    surface.set_tiles(out_of_map, false)
    surface.set_tiles(tiles, true)

    populate_biter_area(surface, chunk_pos, rng, false)
end

---@param surface LuaSurface
---@param chunk_pos {x: number, y: number}
---@param rng LuaRandomGenerator
local function generate_biter_area(surface, chunk_pos, rng)
    local left_top_x = chunk_pos.x * 32
    local left_top_y = chunk_pos.y * 32
    local seed = surface.map_gen_settings.seed

    local out_of_map = chunk_buffer
    local tiles = chunk_buffer2
    local i = 1

    for y = left_top_y, left_top_y + 32 - 1 do
        for x = left_top_x, left_top_x + 32 - 1 do
            out_of_map[i], tiles[i] = get_biter_area_tile(seed, x, y)
            i = i + 1
        end
    end

    surface.set_tiles(out_of_map, false)
    surface.set_tiles(tiles, true)

    populate_biter_area(surface, chunk_pos, rng, true)
end

---@param surface LuaSurface
---@param chunk_pos {x: number, y: number}
---@param rng LuaRandomGenerator
local function generate_ordinary(surface, chunk_pos, rng)
    local tile_gen = get_tile_generator(surface, chunk_pos)
    if not tile_gen then
        return
    end

    local left_top_x = chunk_pos.x * 32
    local left_top_y = chunk_pos.y * 32

    for y = left_top_y, left_top_y + 32 - 1 do
        for x = left_top_x, left_top_x + 32 - 1 do
            tile_gen(x, y, rng)
        end
    end
end

-- this will enable collection of chunk generation profiling statistics, chart huge area around the map origin
-- and enable `chunk-profiling-stats` command to retrieve the statistics
local ENABLE_CHUNK_GEN_PROFILING = false

local chunk_profiling = nil
if ENABLE_CHUNK_GEN_PROFILING then
    local function enabled_mixed_ore_map_special(type, size)
        storage.active_special_games['mixed_ore_map'] = true
        if not size then
            if type == 1 then -- mixed ores
                size = 9
            elseif type == 2 then -- checkerboard, 3 - vertical lines
                size = 5
            elseif type == 4 then -- mixed patches
                size = 4
            elseif type == 5 then -- dots
                size = 7
            end
        end
        storage.special_games_variables['mixed_ore_map'] = { type = type, size = size }
    end

    -- you can uncomment this to test mixed ore map special performance
    -- enabled_mixed_ore_map_special(4, 4)

    local profile_stats = require('utils.profiler_stats')
    local event = require('utils.event')
    local token = require('utils.token')

    chunk_profiling = {
        per_chunk_type = {},
        all = profile_stats.new(),
    }

    for _, i in pairs(chunk_type) do
        chunk_profiling.per_chunk_type[i] = profile_stats.new()
    end

    local function chart_profiling_area(surface)
        game.forces['spectator'].chart(surface, { { x = -1024, y = -1024 }, { x = 1023, y = 1023 } })
    end

    local on_after_init -- pass self reference to the callback below
    on_after_init = token.register(function()
        local bb_surface = game.get_surface(storage.bb_surface_name)
        chart_profiling_area(bb_surface)
        event.remove_removable(defines.events.on_tick, on_after_init)
    end)
    event.add_removable(defines.events.on_tick, on_after_init)

    -- this won't be called if you create a surface during `on_init`
    event.add(defines.events.on_surface_created, function(event)
        local bb_surface = game.get_surface(storage.bb_surface_name)
        if not bb_surface or event.surface_index ~= bb_surface.index then
            return
        end
        chart_profiling_area(bb_surface)
    end)

    -- server and client output won't match
    commands.add_command('chunk-profiling-stats', 'Display and log statistics of chunk generation time', function(cmd)
        local caller = cmd.player_index and game.get_player(cmd.player_index)

        if caller and not is_admin(caller) then
            caller.print('Only admin may run this command')
            return
        end

        local stats = 'Chunk profiling statistics\nall: ' .. chunk_profiling.all.summarize_records()
        for chunk_name, i in pairs(chunk_type) do
            stats = stats .. '\n' .. chunk_name .. ': ' .. chunk_profiling.per_chunk_type[i].summarize_records()
        end
        log(stats)
        if caller then
            caller.print(stats)
        end
    end)
end

---@param chunk_pos {x: number, y: number}
---@param seed uint
---@return LuaRandomGenerator
local function create_rng_for_chunk(chunk_pos, seed)
    -- seeding from mixed ores special map generation
    return game.create_random_generator((chunk_pos.x * 374761393 + chunk_pos.y * 668265263 + seed) % 4294967296)
end

function Public.generate(event)
    local profiler = chunk_profiling and helpers.create_profiler(false)

    local surface = event.surface
    local chunk_pos = event.position
    local rng = create_rng_for_chunk(chunk_pos, surface.map_gen_settings.seed)

    local chunk_variant = chunk_type_at(chunk_pos)
    if chunk_variant == chunk_type.river then
        generate_river(surface, chunk_pos, rng)
    elseif chunk_variant == chunk_type.ordinary then
        generate_ordinary(surface, chunk_pos, rng)
    elseif chunk_variant == chunk_type.biter_area_border then
        generate_biter_area_border(surface, chunk_pos, rng)
    elseif chunk_variant == chunk_type.biter_area then
        generate_biter_area(surface, chunk_pos, rng)
    end

    populate_with_extra_worm_turrets(surface, chunk_pos, rng)

    if profiler then
        profiler.stop()
        chunk_profiling.all.add_record(profiler)
        chunk_profiling.per_chunk_type[chunk_variant].add_record(profiler)
    end
end

---The CARVE PASS of the four-square map: the side river of one canonical chunk.
---
---`Public.generate` has just produced the chunk exactly as it produces it for the
---two-team map -- front river, ore, nests, worms and all. This replaces the tiles
---the SIDE river covers, and only those, by deepwater, takes out whatever was
---left standing on them (ore, trees, rocks, nests, worms, scrap) and drops the
---same one-in-64 fish `generate_river` drops. Everything else in the chunk stays
---what the legacy generator made of it.
---
---Never called for the two-team map. One chunk per call, like the generator it
---follows: the module-level tile buffers are not re-entrant.
---
---Its own generator: `Public.generate` did not hand its rng back, and one drawn
---again from the same chunk position is just as deterministic and just as
---independent of the order chunks are generated in -- all the fish need.
---@param event EventData.on_chunk_generated
function Public.carve_side_river(event)
    local chunk_pos = event.position
    if not Public.chunk_has_side_river(chunk_pos) then
        return
    end

    local surface = event.surface
    local seed = surface.map_gen_settings.seed
    local rng = create_rng_for_chunk(chunk_pos, seed)
    local create_entity = surface.create_entity
    local fish_template = { name = 'fish', position = { 0.5, 0.5 } }
    local left_top_x = chunk_pos.x * 32
    local left_top_y = chunk_pos.y * 32

    -- Which of the chunk's 1024 cells the river took, so that the sweep below
    -- can tell an entity standing in the water from one standing on the bank.
    local carved = {}
    local tiles = {}
    local i = 1

    for y = left_top_y, left_top_y + 32 - 1 do
        for x = left_top_x, left_top_x + 32 - 1 do
            if is_side_river_tile(seed, x, y) then
                local tile = preallocated_tiles[next_preallocated_tile]
                next_preallocated_tile = (next_preallocated_tile % (32 * 32)) + 1

                tile.name = 'deepwater'
                tile.position[1], tile.position[2] = x, y
                tiles[i] = tile
                i = i + 1
                carved[(x - left_top_x) * 32 + (y - left_top_y) + 1] = true
                if rng(1, 64) == 1 then
                    fish_template.position[1], fish_template.position[2] = x + 0.5, y + 0.5
                    create_entity(fish_template)
                end
            end
        end
    end

    if i == 1 then
        return
    end
    surface.set_tiles(tiles)

    -- Matched by the cell an entity stands on, so a tree on the bank keeps its
    -- place and one in the water does not. The fish that were just dropped are
    -- standing in the water on purpose, and a character is never removed by the
    -- terrain code.
    local entities = surface.find_entities_filtered({
        area = { { left_top_x, left_top_y }, { left_top_x + 32, left_top_y + 32 } },
        name = { 'character', 'fish' },
        invert = true,
    })
    for _, entity in pairs(entities) do
        local position = entity.position
        local cell_x = math_floor(position.x) - left_top_x
        local cell_y = math_floor(position.y) - left_top_y
        if cell_x >= 0 and cell_x < 32 and cell_y >= 0 and cell_y < 32 and carved[cell_x * 32 + cell_y + 1] then
            entity.destroy()
        end
    end
end

local closed_quadrant_water = {}
for i = 1, 32 * 32 do
    closed_quadrant_water[i] = { name = 'deepwater', position = { 0, 0 } }
end

---A chunk of a CLOSED quadrant, filled edge to edge with water.
---
---Three teams play the four-square map with the bottom-left quadrant empty: it
---belongs to nobody, is a copy of nothing and holds no team, nests, ore or silo,
---so it is water. Characters are left where they are, as
---everywhere else in the clone machinery -- a spectator flying over it must not
---be deleted.
---@param surface LuaSurface
---@param chunk_pos {x: int, y: int}
function Public.fill_chunk_with_water(surface, chunk_pos)
    local left_top_x = chunk_pos.x * 32
    local left_top_y = chunk_pos.y * 32

    local i = 1
    for y = left_top_y, left_top_y + 32 - 1 do
        for x = left_top_x, left_top_x + 32 - 1 do
            local tile = closed_quadrant_water[i]
            tile.position[1], tile.position[2] = x, y
            i = i + 1
        end
    end
    surface.set_tiles(closed_quadrant_water)

    local area = { { left_top_x, left_top_y }, { left_top_x + 32, left_top_y + 32 } }
    surface.destroy_decoratives({ area = area })
    local entities = surface.find_entities_filtered({
        area = area,
        name = 'character',
        invert = true,
    })
    for _, entity in pairs(entities) do
        entity.destroy()
    end
end

---@param surface LuaSurface
---@param cross4 boolean|nil four-square map: the canonical quarter and no more
local function draw_spawn_island(surface, cross4)
    local tiles = {}
    for x = math_floor(spawn_island_size) * -1, -1, 1 do
        for y = math_floor(spawn_island_size) * -1, -1, 1 do
            if is_within_spawn_island(x, y) then
                local distance_to_center = tile_distance_to_center(x, y)
                local tile_name = 'refined-concrete'
                if storage.bb_settings['new_year_island'] then
                    tile_name = 'blue-refined-concrete'
                end
                if distance_to_center < 6.3 then
                    tile_name = 'sand-1'
                end

                table_insert(tiles, { name = tile_name, position = { x = x, y = y } })
            end
        end
    end

    if not cross4 then
        -- The two-team map draws the north-west quarter and duplicates it to the
        -- north-east, the mirror clone bringing the southern half. On the
        -- four-square map the mirror clones bring the other three quarters, so
        -- the canonical one is drawn alone.
        for i = 1, #tiles, 1 do
            table_insert(
                tiles,
                { name = tiles[i].name, position = { tiles[i].position.x * -1 - 1, tiles[i].position.y } }
            )
        end
    end

    surface.set_tiles(tiles, true)

    local island_area = { { -spawn_island_size, -spawn_island_size }, { spawn_island_size, 0 } }
    if cross4 then
        -- Only the quarter that was drawn; the other three quadrants are not
        -- this function's to wipe.
        island_area = { { -spawn_island_size, -spawn_island_size }, { 0, 0 } }
    end
    surface.destroy_decoratives({ area = island_area })
    for _, entity in pairs(surface.find_entities(island_area)) do
        entity.destroy()
    end
end

local chunk_r = 4

--- Create initial chunks to be populated with spawn objects
---@param surface LuaSurface
---@param mirror boolean force south spawn chunks generation
local function force_spawn_chunks_generation(surface, mirror)
    local start_row = mirror and 0 or -chunk_r
    local end_row = start_row + chunk_r - 1
    local request_to_generate_chunks = surface.request_to_generate_chunks
    for x = -chunk_r, chunk_r - 1 do
        for y = start_row, end_row do
            request_to_generate_chunks({ x * 32, y * 32 }, 0)
        end
    end
    surface.force_generate_chunk_requests()
end

--- The spawn chunks of the CANONICAL quadrant of the four-square map: the
--- quarter of `force_spawn_chunks_generation`'s box with cx < 0 and cy < 0.
---@param surface LuaSurface
local function force_canonical_spawn_chunks_generation(surface)
    local request_to_generate_chunks = surface.request_to_generate_chunks
    for x = -chunk_r, -1 do
        for y = -chunk_r, -1 do
            request_to_generate_chunks({ x * 32, y * 32 }, 0)
        end
    end
    surface.force_generate_chunk_requests()
end

--- The spawn chunks of the three IMAGE quadrants of the four-square map.
---
--- Generating them is what makes the chunk handler clone the canonical quadrant
--- onto them, so this call is the one that gives every other team its silo, its
--- spawn wall and its ore -- which is why it comes after the structures are
--- finished, exactly as the legacy map's second `force_spawn_chunks_generation`
--- does. A closed quadrant is skipped: it is water, not a copy of anything.
---@param surface LuaSurface
local function force_image_spawn_chunks_generation(surface)
    local request_to_generate_chunks = surface.request_to_generate_chunks
    for k = 1, 3 do
        if not Layout.is_closed_quadrant(k) then
            for x = -chunk_r, -1 do
                for y = -chunk_r, -1 do
                    local cx, cy = Layout.rotate_chunk(k, x, y)
                    request_to_generate_chunks({ cx * 32, cy * 32 }, 0)
                end
            end
        end
    end
    surface.force_generate_chunk_requests()
end

--- Generate some biter nests so attack groups could be spawned
---@param surface LuaSurface
---@param cross4 boolean|nil four-square map: the canonical quadrant's rows only
local function request_biters_area_generation(surface, cross4)
    -- skip biter area border at x=0 chunk and include solid biter area chunk which guaranteed to contain some nests
    local solid_biter_area_start = bb_config_bitera_area_distance + 70 + (32 - 1) * bb_config_biter_area_slope
    local start_row = -1 - math_ceil(solid_biter_area_start / 32)
    local end_row = -chunk_r - 1
    local end_column = cross4 and -1 or (chunk_r - 1)
    local request_to_generate_chunks = surface.request_to_generate_chunks
    for x = -chunk_r, end_column do
        for y = start_row, end_row do
            request_to_generate_chunks({ x * 32, y * 32 }, 0)
        end
    end
end

---@param surface LuaSurface
---@param rng LuaRandomGenerator
---@param cross4 boolean|nil four-square map: the canonical quadrant's chunks only
local function draw_spawn_area(surface, rng, cross4)
    local spawn_wall_area_radius = spawn_wall_radius + spawn_wall_noise_deviation
    local trees = surface.find_entities_filtered({
        type = 'tree',
        position = { 0, 0 },
        radius = spawn_wall_area_radius,
    })
    for _, tree in pairs(trees) do
        -- old code checked for each tile with 2x2 box with chance of skipping 23%
        -- 4 times same tree 23% gives chance < 1%
        -- if rng(1, 100) > 1 then
        tree.destroy()
        -- end
    end
    -- The tree wipe above is a disc around the ORIGIN, not around a team's
    -- spawn, and so is the ring `generate_starting_area` draws: the four-square
    -- map needs no new arithmetic for either, only the quarter of the chunks
    -- that lies in the canonical quadrant.
    local end_column = cross4 and -1 or (chunk_r - 1)
    for x = -chunk_r, end_column do
        for y = -chunk_r, -1 do
            generate_starting_area(surface, { x = x, y = y }, rng, cross4)
        end
    end

    surface.destroy_decoratives({})
    surface.regenerate_decorative()
end

local water_barrier = {}
for i = 1, 32 do
    water_barrier[i] = { name = 'deepwater', position = { 0, 0 } }
end

function Public.draw_water_for_river_ends(surface, chunk_pos)
    local left_top_x = chunk_pos.x * 32
    for x = 0, 32 - 1 do
        water_barrier[x + 1].position[1] = left_top_x + x
    end
    surface.set_tiles(water_barrier)
end

local vertical_water_barrier = {}
for i = 1, 32 do
    vertical_water_barrier[i] = { name = 'deepwater', position = { 0, 0 } }
end

---The twin of `draw_water_for_river_ends` for the vertical arm of the cross:
---a one-tile strip of water down the x = 0 column of a chunk the engine has not
---generated yet, so that the biter pathfinder cannot walk across that river over
---Factorio's three-chunk tile pre-generation.
---
---As in the horizontal template, only one coordinate of each entry is ever
---written -- here it is the x that stays 0 for good.
---@param surface LuaSurface
---@param chunk_pos {x: int, y: int}
function Public.draw_water_for_vertical_river_ends(surface, chunk_pos)
    local left_top_y = chunk_pos.y * 32
    for y = 0, 32 - 1 do
        vertical_water_barrier[y + 1].position[2] = left_top_y + y
    end
    surface.set_tiles(vertical_water_barrier)
end

local function draw_grid_ore_patch(count, grid, name, surface, size, density, rng)
    -- Takes a random left_top coordinate from grid, removes it and draws
    -- ore patch on top of it. Grid is held by reference, so this function
    -- is reentrant.
    for i = 1, count, 1 do
        local idx = rng(1, #grid)
        local pos = grid[idx]
        table_remove(grid, idx)

        draw_noise_ore_patch(pos[1], pos[2], name, surface, size, density)
    end
end

local function _clear_resources(surface, area)
    local resources = surface.find_entities_filtered({
        area = area,
        type = 'resource',
    })

    local i = 0
    for _, res in pairs(resources) do
        res.destroy()
        i = i + 1
    end

    return i
end

local function clear_ore_in_main(surface)
    local area = {
        left_top = { -150, -150 },
        right_bottom = { 150, 0 },
    }
    local limit = 20
    local cnt = 0
    repeat
        -- Keep clearing resources until there is none.
        -- Each cycle increases search area.
        cnt = _clear_resources(surface, area)
        limit = limit - 1
        area.left_top[1] = area.left_top[1] - 5
        area.left_top[2] = area.left_top[2] - 5
        area.right_bottom[1] = area.right_bottom[1] + 5
    until cnt == 0 or limit == 0

    if limit == 0 then
        log('Limit reached, some ores might be truncated in spawn area')
        log('If this is a custom build, remove a call to clear_ore_in_main')
        log('If this in a standard value, limit could be tweaked')
    end
end

---@param surface LuaSurface
---@param rng LuaRandomGenerator
---@param cross4 boolean|nil four-square map: the canonical quadrant's grid
local function generate_spawn_ore(surface, rng, cross4)
    -- This array holds indices of chunks onto which we desire to
    -- generate ore patches. It is visually representing north spawn
    -- area. One element was removed on purpose - we don't want to
    -- draw ore in the lake which overlaps with chunk [0,-1]. All ores
    -- will be mirrored to south.
    local grid = {
        { -2, -3 },
        { -1, -3 },
        { 0, -3 },
        { 1, -3 },
        { 2, -3 },
        { -2, -2 },
        { -1, -2 },
        { 0, -2 },
        { 1, -2 },
        { 2, -2 },
        { -2, -1 },
        { -1, -1 },
        { 1, -1 },
        { 2, -1 },
    }

    if cross4 then
        -- The four-square map draws the canonical quadrant and the mirror
        -- clones carry it to the others, so the grid moves west of the side
        -- river: the same three rows, and four columns with cx < 0 instead of
        -- five across the axis. [-1,-1] is dropped for the reason [0,-1] is
        -- dropped above -- it is the lake corner. Eleven cells, for the nine
        -- patches of `tables.spawn_ore`: the six cells of the legacy grid that
        -- have cx < 0 would run it empty, and `rng(1, 0)` is an error.
        grid = {
            { -4, -3 },
            { -3, -3 },
            { -2, -3 },
            { -1, -3 },
            { -4, -2 },
            { -3, -2 },
            { -2, -2 },
            { -1, -2 },
            { -4, -1 },
            { -3, -1 },
            { -2, -1 },
        }
    end

    -- Calculate left_top position of a chunk. It will be used as origin
    -- for ore drawing. Reassigns new coordinates to the grid.
    for i, _ in ipairs(grid) do
        grid[i][1] = grid[i][1] * 32 + rng(-12, 12)
        grid[i][2] = grid[i][2] * 32 + rng(-24, -1)
    end

    for name, props in pairs(spawn_ore) do
        draw_grid_ore_patch(props.big_patches, grid, name, surface, props.size, props.density, rng)
        draw_grid_ore_patch(props.small_patches, grid, name, surface, props.size / 2, props.density, rng)
    end
end

---@param surface LuaSurface
---@param rng LuaRandomGenerator
---@param cross4 boolean|nil four-square map: the canonical quadrant only
local function generate_additional_rocks(surface, rng, cross4)
    local r = 130
    local counted_area = { { r * -1, r * -1 }, { r, 0 } }
    if cross4 then
        counted_area = { { r * -1, r * -1 }, { 0, 0 } }
    end
    if surface.count_entities_filtered({ type = 'simple-entity', area = counted_area }) >= 12 then
        return
    end
    local position
    if cross4 then
        -- x gets the shape the legacy gives y, so the cluster sits in the middle
        -- of the quadrant, clear of both of its rivers.
        position = { x = -40 - rng(0, 96), y = -40 - rng(0, 96) }
    else
        position = { x = -96 + rng(0, 192), y = -40 - rng(0, 96) }
    end
    for _ = 1, rng(6, 10) do
        local name = rocks[rng(1, 5)]
        local p = surface.find_non_colliding_position(name, {
            position.x + (-10 + rng(0, 20)),
            position.y + (-10 + rng(0, 20)),
        }, 16, 1)
        -- `p.x < -16` is `p.y < -16` for the second river.
        if p and p.y < -16 and (not cross4 or p.x < -16) then
            surface.create_entity({ name = name, position = p })
        end
    end
end

---@param surface LuaSurface
---@param rng LuaRandomGenerator
---@param cross4 boolean|nil four-square map: the canonical quadrant only
local function generate_silo(surface, rng, cross4)
    local pos
    if cross4 then
        -- The canonical quadrant's silo: the legacy's 64-tile spread moved
        -- wholly to x < 0, and 40 tiles clear of the side river so that neither
        -- the silo nor the water it replaces below reaches it. One draw, as on
        -- the legacy map -- the three other silos are this one turned.
        pos = { x = -40 - rng(0, 64), y = -72 }
    else
        pos = { x = -32 + rng(0, 64), y = -72 }
    end

    for _, t in
        pairs(surface.find_tiles_filtered({
            area = { { pos.x - 6, pos.y - 6 }, { pos.x + 6, pos.y + 6 } },
            name = { 'water', 'deepwater' },
        }))
    do
        surface.set_tiles({ { name = DEFAULT_HIDDEN_TILE, position = t.position } })
    end
    if not cross4 then
        -- The two-team map also clears the water where the mirror clone will put
        -- the southern silo. The four-square map has no such place: the clones
        -- carry the tiles of the whole chunk, hidden tiles included.
        local mirror_position = { x = pos.x * -1, y = pos.y * -1 }
        for _, t in
            pairs(surface.find_tiles_filtered({
                area = {
                    { mirror_position.x - 6, mirror_position.y - 6 },
                    {
                        mirror_position.x + 6,
                        mirror_position.y + 6,
                    },
                },
                name = { 'water', 'deepwater' },
            }))
        do
            surface.set_tiles({ { name = DEFAULT_HIDDEN_TILE, position = t.position } })
        end
    end

    local silo = surface.create_entity({
        name = 'rocket-silo',
        position = pos,
        force = 'north',
    })
    silo.minable_flag = false
    table.insert(storage.rocket_silo[silo.force.name], silo)
    AiTargets.start_tracking(silo)

    for _, entity in pairs(surface.find_entities({ { pos.x - 4, pos.y - 6 }, { pos.x + 5, pos.y + 5 } })) do
        if entity.type == 'simple-entity' or entity.type == 'tree' then
            entity.destroy()
        end
    end
    local turret1 =
        surface.create_entity({ name = 'gun-turret', position = { x = pos.x, y = pos.y - 5 }, force = 'north' })
    turret1.insert({ name = 'firearm-magazine', count = 10 })
    AiTargets.start_tracking(turret1)
    local turret2 =
        surface.create_entity({ name = 'gun-turret', position = { x = pos.x + 2, y = pos.y - 5 }, force = 'north' })
    turret2.insert({ name = 'firearm-magazine', count = 10 })
    AiTargets.start_tracking(turret2)
end

function Public.generate_initial_structures(surface)
    force_spawn_chunks_generation(surface, false)
    local rng = create_rng_for_chunk({ x = 1, y = 1 }, surface.map_gen_settings.seed)
    draw_spawn_area(surface, rng)
    if not storage.active_special_games['mixed_ore_map'] then
        clear_ore_in_main(surface)
        generate_spawn_ore(surface, rng)
    end
    generate_additional_rocks(surface, rng)
    generate_silo(surface, rng)
    draw_spawn_island(surface)
    force_spawn_chunks_generation(surface, true)
    request_biters_area_generation(surface)
end

---The one-shot structures of the FOUR-SQUARE map: the canonical quadrant, and
---then the clones.
---
---`Public.generate_initial_structures` draws the whole north half and lets the
---mirror clone carry it south. This draws the top-left quarter and lets the
---mirror clones carry it into the other quadrants, so every team's base is the
---same base mirrored -- by construction, not by a second generation.
---
---The order is the legacy one, step for step, and for the legacy reasons:
---
---  1. the canonical spawn chunks exist before anything is drawn on them;
---  2. ONE rng for the whole pass, drawn from the very same `{1, 1}` chunk, so a
---     seed still means one thing;
---  3. spawn area, 4. ore, 5. rocks, 6. silo, 7. island -- each restricted to
---     the canonical quadrant and clipped by BOTH of its rivers;
---  8. and only THEN the image spawn chunks, because generating them is what
---     triggers the clones and the clones must copy the finished structures.
---     This is how the legacy map gets its silo into the south.
---  9. the biter rows are requested last, asynchronously, as on the legacy map.
---@param surface LuaSurface
function Public.generate_initial_structures_cross4(surface)
    force_canonical_spawn_chunks_generation(surface)
    local rng = create_rng_for_chunk({ x = 1, y = 1 }, surface.map_gen_settings.seed)
    draw_spawn_area(surface, rng, true)
    if not storage.active_special_games['mixed_ore_map'] then
        -- Not restricted: the box reaches into the three other quadrants, where
        -- not one chunk exists yet, so there is nothing of theirs to clear.
        clear_ore_in_main(surface)
        generate_spawn_ore(surface, rng, true)
    end
    generate_additional_rocks(surface, rng, true)
    generate_silo(surface, rng, true)
    draw_spawn_island(surface, true)
    force_image_spawn_chunks_generation(surface)
    request_biters_area_generation(surface, true)
end

---@param entity LuaEntity
---@param player LuaPlayer
function Public.minable_wrecks(entity, player)
    if not valid_wrecks[entity.name] then
        return
    end

    local surface = entity.surface

    local loot_worth = math_floor(math_abs(entity.position.x * 0.02)) + math_random(16, 32)
    local blacklist = LootRaffle.get_tech_blacklist(math_abs(entity.position.x * 0.0001) + 0.10)
    for k, _ in pairs(loot_blacklist) do
        blacklist[k] = true
    end
    local item_stacks = LootRaffle.roll(loot_worth, math_random(1, 3), blacklist)

    for k, stack in pairs(item_stacks) do
        local amount = stack.count
        local name = stack.name

        local inserted_count = player.insert({ name = name, count = amount })
        if inserted_count ~= amount then
            local amount_to_spill = amount - inserted_count
            surface.spill_item_stack({
                position = entity.position,
                stack = { name = name, count = amount_to_spill },
                enable_looted = true,
            })
        end

        player.create_local_flying_text({
            position = { entity.position.x, entity.position.y - 0.5 * k },
            text = '+' .. amount .. ' [img=item/' .. name .. ']',
            color = { r = 0.98, g = 0.66, b = 0.22 },
        })
    end
end

--Landfill Restriction

---True for a TILE of the four-square map that no landfill may cover: the water
---of the cross.
---
---Every quadrant is the canonical one mirrored, so the question is asked in the
---canonical frame: the tile is taken back through the transform of its own
---quadrant (`unrotate_tile`, the cell transform the clone pipeline moves the
---terrain with -- not `unrotate_position`, which would answer for the tile next
---door on the axis that gets negated) and then handed to the two river
---predicates above. The front river covers the central lake, which is
---the same disc in every frame (`tile_distance_to_center` is invariant under the
---cell transform), so the spectator island stays landfill-proof exactly as it is
---today.
---
---A closed quadrant -- the fourth one of a three-team round -- is water from end
---to end and takes no landfill at all.
---@param seed uint
---@param x number tile x
---@param y number tile y
---@return boolean
function Public.is_cross4_river_tile(seed, x, y)
    local k = Layout.quadrant_of_tile(x, y)
    if Layout.is_closed_quadrant(k) then
        return true
    end
    local cx, cy = Layout.unrotate_tile(k, x, y)
    return is_horizontal_border_river(cx, cy, seed) or is_side_river_tile(seed, cx, cy)
end

function Public.restrict_landfill(surface, user, tiles)
    local seed = game.surfaces[storage.bb_surface_name].map_gen_settings.seed
    local cross4 = Teams.layout() == 'cross4'
    for _, t in pairs(tiles) do
        local is_river
        if cross4 then
            is_river = Public.is_cross4_river_tile(seed, t.position.x, t.position.y)
        else
            local check_position = t.position
            if check_position.y > 0 then
                check_position = { x = check_position.x, y = (check_position.y * -1) - 1 }
            end
            is_river = is_horizontal_border_river(check_position.x, check_position.y, seed)
        end
        local trusted = session.get_trusted_table()
        if is_river then
            surface.set_tiles({ { name = t.old_tile.name, position = t.position } }, true)
            if user ~= nil then
                user.print('You can not landfill the river', { color = { r = 0.22, g = 0.99, b = 0.99 } })
            end
        elseif user ~= nil and not trusted[user.name] then
            surface.set_tiles({ { name = t.old_tile.name, position = t.position } }, true)
            user.print(
                'You have not grown accustomed to this technology yet.',
                { color = { r = 0.22, g = 0.99, b = 0.99 } }
            )
        end
    end
end

function Public.deny_bot_landfill(event)
    if event.item ~= nil and event.item.name == 'landfill' then
        Public.restrict_landfill(event.robot.surface, nil, event.tiles)
    end
end

--Construction Robot Restriction
local robot_build_restriction = {
    ['north'] = function(y)
        if y >= -bb_config.border_river_width / 2 then
            return true
        end
    end,
    ['south'] = function(y)
        if y <= bb_config.border_river_width / 2 then
            return true
        end
    end,
}

---The two rules of the four-square map for robots, ghosts and deconstruction
---orders: today's two-team BANDS, turned into every square. With `h` half a
---river width and `(cx, cy)` the position in the team's canonical frame (its own
---square is `x < 0, y < 0`, its two rivers run along the axes):
---
---  * building is allowed only inside the team's own square AND more than `h`
---    from both axes (`cx < -h and cy < -h`): the last `h` tiles of both banks,
---    both rivers and the spectator island are denied, exactly as today's
---    `y >= -h` denies them to north;
---  * deconstruction is denied past `h` tiles beyond either axis
---    (`cx > h or cy > h`): a team may order it over its rivers and `h` tiles up
---    the neighbours' banks, exactly as today's `y > h` lets north reach across.
---
---A force that is not an active team -- the spectators, the biters, `player`,
---and a team of the roster that sits this round out -- is not restricted at all,
---exactly as a force absent from `robot_build_restriction` is not restricted
---today. The closed square of a three-team round belongs to nobody
---(`Layout.of_position` is nil there), so nobody builds in it.
---@param force_name string
---@param position MapPosition
---@return boolean
local function cross_build_denied(force_name, position)
    if not Teams.is_active(force_name) then
        return false
    end
    if Layout.of_position(position) ~= force_name then
        return true
    end
    local half_river_width = bb_config.border_river_width / 2
    local cx, cy = Layout.to_canonical(force_name, position.x, position.y)
    return cx >= -half_river_width or cy >= -half_river_width
end

---@param force_name string
---@param position MapPosition
---@return boolean
local function cross_deconstruction_denied(force_name, position)
    if not Teams.is_active(force_name) then
        return false
    end
    local half_river_width = bb_config.border_river_width / 2
    local cx, cy = Layout.to_canonical(force_name, position.x, position.y)
    return cx > half_river_width or cy > half_river_width
end

---True when `force_name`'s construction robots may not build, and its players
---may not leave a ghost, at `position`.
---
---'horizontal2': the table above, verbatim -- a team is stopped from half a
---river width BEFORE the river onwards, i.e. it may not build on its own bank.
---'cross4': the same band along both of its rivers, inside its own square.
---@param force_name string
---@param position MapPosition
---@return boolean
function Public.build_denied(force_name, position)
    if Teams.layout() == 'cross4' then
        return cross_build_denied(force_name, position)
    end
    local restriction = robot_build_restriction[force_name]
    if not restriction then
        return false
    end
    return restriction(position.y) == true
end

---True when `force_name`'s deconstruction order at `position` is cancelled
---(`main.lua`'s `on_marked_for_deconstruction`, which is why the expression
---lives next to its twin).
---
---'horizontal2': today's expression, which is NOT the build rule above. The
---build rule stops a team half a river width BEFORE the river; this one only
---stops it half a river width PAST it, so a team may order deconstruction all
---over the river and a little way up the enemy bank. The two sites disagree
---about which side `y == 0` belongs to and that disagreement is today's
---behaviour (INVENTORY §1), so both are kept exactly as they are.
---'cross4': the same reach, half a river width past either of its two axes.
---@param force_name string
---@param position MapPosition
---@return boolean
function Public.deconstruction_denied(force_name, position)
    if Teams.layout() == 'cross4' then
        return cross_deconstruction_denied(force_name, position)
    end
    local half_river_width = bb_config.border_river_width / 2
    return (force_name == 'north' and position.y > half_river_width)
        or (force_name == 'south' and position.y < -half_river_width)
end

function Public.deny_construction_bots(event)
    if not event.entity.valid then
        return
    end
    if not Public.build_denied(event.robot.force.name, event.entity.position) then
        return
    end
    local inventory = event.robot.get_inventory(defines.inventory.robot_cargo)
    inventory.insert({ name = event.entity.name, count = 1 })
    event.robot.surface.create_entity({ name = 'explosion', position = event.entity.position })
    game.print(
        'Team ' .. event.robot.force.name .. "'s construction drone had an accident.",
        { color = { r = 200, g = 50, b = 100 } }
    )
    event.entity.destroy()
end

function Public.deny_enemy_side_ghosts(event)
    local e = event.entity
    if not e.valid then
        return
    end
    if e.type == 'entity-ghost' or e.type == 'tile-ghost' then
        local player = game.get_player(event.player_index)
        local force = player.force.name
        if not Public.build_denied(force, event.entity.position) then
            return
        end

        -- If cursor is not cleared before removing ghost of dragged pipe it
        -- will cause segfault from infinite recursion.
        player.clear_cursor()
        local ghosts = player.surface.find_entities_filtered({
            position = e.position,
            -- Undeground pipe creates two ghost tiles, but only one entity
            -- gets corresponding event
            radius = 2,
            name = 'tile-ghost',
        })
        e.order_deconstruction(force)
        for _, g in ipairs(ghosts) do
            if g.valid then
                g.order_deconstruction(force)
            end
        end
    end
end

local function add_gifts(surface)
    -- exclude dangerous goods
    local blacklist = LootRaffle.get_tech_blacklist(0.95)
    for k, _ in pairs(loot_blacklist) do
        blacklist[k] = true
    end

    for i = 1, math_random(8, 12) do
        local loot_worth = math_random(1, 35000)
        local item_stacks = LootRaffle.roll(loot_worth, 3, blacklist)
        for k, stack in pairs(item_stacks) do
            surface.spill_item_stack({
                position = { x = math_random(-10, 10) * 0.1, y = math_random(-5, 15) * 0.1 },
                stack = { name = stack.name, count = 1 },
                enable_looted = false,
                force = nil,
                allow_belts = true,
            })
        end
    end
end

function Public.add_new_year_island_decorations(surface)
    -- To fix lab-white tiles transition, draw border snow with sprites
    local function draw_sprite_snow(params)
        rendering.draw_sprite({
            surface = surface,
            sprite = 'virtual-signal/signal-dot',
            target = params.target,
            render_layer = '3',
            x_scale = params.x_scale,
            y_scale = params.y_scale,
            render_mode = params.render_mode,
        })
    end

    draw_sprite_snow({ target = { 0.4, 0.55 }, x_scale = 29.5, y_scale = 29.5 })
    draw_sprite_snow({ target = { 0.5, 0.5 }, x_scale = 34, y_scale = 34, render_mode = 'chart' })

    -- top and bottom corners
    draw_sprite_snow({ target = { 1.8, 0.45 }, x_scale = 10, y_scale = 30 })
    draw_sprite_snow({ target = { -1.8 + 0.33, 0.45 }, x_scale = 10, y_scale = 30 })

    -- left and right corners
    draw_sprite_snow({ target = { 0.4, -1.8 + 0.33 }, x_scale = 30, y_scale = 10 })
    draw_sprite_snow({ target = { 0.4, 1.8 }, x_scale = 30, y_scale = 10 })

    for _ = 1, math_random(0, 4) do
        local stump = surface.create_entity({
            name = 'tree-05-stump',
            position = { x = math_random(-40, 40) * 0.1, y = math_random(-40, 40) * 0.1 },
        })
        stump.corpse_expires = false
    end

    local scorchmark = surface.create_entity({
        name = 'medium-scorchmark-tintable',
        position = { x = 0, y = 0 },
    })
    scorchmark.corpse_expires = false

    local tree = surface.create_entity({
        name = 'tree-01',
        position = { x = 0, y = 0.05 },
    })
    tree.minable_flag = false
    tree.destructible = false

    add_gifts(surface)

    local signals = {
        { name = 'rail-signal', position = { -0.5, -5.5 }, direction = defines.direction.west },
        { name = 'rail-signal', position = { 0.5, -5.5 }, direction = defines.direction.west },
        { name = 'rail-signal', position = { 2.5, -4.5 }, direction = defines.direction.northwest },
        { name = 'rail-signal', position = { 4.5, -2.5 }, direction = defines.direction.northwest },
        { name = 'rail-signal', position = { 5.5, -0.5 }, direction = defines.direction.north },
        { name = 'rail-signal', position = { 5.5, 0.5 }, direction = defines.direction.north },
        { name = 'rail-signal', position = { 4.5, 2.5 }, direction = defines.direction.northeast },
        { name = 'rail-signal', position = { 2.5, 4.5 }, direction = defines.direction.northeast },
        { name = 'rail-signal', position = { 0.5, 5.5 }, direction = defines.direction.east },
        { name = 'rail-signal', position = { -0.5, 5.5 }, direction = defines.direction.east },
        { name = 'rail-signal', position = { -2.5, 4.5 }, direction = defines.direction.southeast },
        { name = 'rail-signal', position = { -4.5, 2.5 }, direction = defines.direction.southeast },
        { name = 'rail-signal', position = { -5.5, 0.5 }, direction = defines.direction.south },
        { name = 'rail-signal', position = { -5.5, -0.5 }, direction = defines.direction.south },
        { name = 'rail-signal', position = { -4.5, -2.5 }, direction = defines.direction.southwest },
        { name = 'rail-signal', position = { -2.5, -4.5 }, direction = defines.direction.southwest },
    }
    for _, v in pairs(signals) do
        local signal = surface.create_entity(v)
        signal.minable_flag = false
        signal.destructible = false
    end

    for _ = 1, math_random(0, 6) do
        surface.create_decoratives({
            check_collision = false,
            decoratives = {
                {
                    name = 'green-asterisk-mini',
                    position = {
                        x = math_random(-40, 40) * 0.1,
                        y = math_random(-40, 40) * 0.1,
                    },
                    amount = 1,
                },
            },
        })
    end
    for _ = 1, math_random(0, 6) do
        surface.create_decoratives({
            check_collision = false,
            decoratives = {
                {
                    name = 'tiny-rock',
                    position = {
                        x = math_random(-40, 40) * 0.1,
                        y = math_random(-40, 40) * 0.1,
                    },
                    amount = 1,
                },
            },
        })
    end
end

return Public
