-- The clone that carries the canonical quadrant of the four-square map onto the
-- other three: the sibling of `mirror_terrain.lua`, and built from it line by
-- line.
--
-- `mirror_terrain` reflects the north half onto the south (y -> -y). This module
-- carries the canonical quadrant onto the zone of the team of quadrant `k` by
-- that quadrant's transform (`layout.lua`): mirrored through x = 0 for east
-- (top right), half-turned for south (bottom right), mirrored through y = 0 for
-- west (bottom left). The module keeps its name from when the transforms were
-- quarter turns. The mechanism is the same one as `mirror_terrain`'s, for the
-- same reasons:
--
--   * `surface.clone_area` copies the entities of a chunk-aligned 32x32 box onto
--     another one, TRANSLATED. Nothing in the engine can mirror them, so the
--     clone is only a way of duplicating: `on_entity_cloned` then teleports each
--     copy from the translated position to the mirrored one, and
--     `on_area_cloned` re-emplaces the 1024 tiles and the decoratives at their
--     mirrored cells.
--   * tiles are therefore not cloned (`clone_tiles = false`); the engine would
--     translate them too.
--   * the destination entities are cleared by hand, because
--     `clear_destination_entities` is unreliable (`mirror_terrain.lua:61-64`).
--
-- Every transform maps the tile lattice onto itself and a chunk onto a chunk
-- (`layout.lua`), which is the property that lets the whole mechanism work.
--
-- ONE CLONE AT A TIME. `clone()` calls `clone_area`, and the engine raises
-- `on_entity_cloned` for every entity of that area and then `on_area_cloned`
-- inside that call, so the module keeps the transform of the clone in progress and a
-- 1024-entry scratch buffer at module level -- the pattern of
-- `mirror_terrain.lua:133-139`. Nothing here is re-entrant.
--
-- Unlike `Mirror_terrain.clone`, this module never writes into the event table
-- it was handed (`mirror_terrain.lua:57-58` does, and `main.lua` reads the
-- mutated value afterwards): both bounding boxes are built from the two chunk
-- positions the caller passes.

local Public = {}

local AiTargets = require('maps.biter_battles_v2.ai_targets')
local Layout = require('maps.biter_battles_v2.layout')
local Teams = require('maps.biter_battles_v2.teams')

local table_insert = table.insert
local math_abs = math.abs
local math_floor = math.floor

---The quarter turns of the clone that is running, set by `clone()` for exactly
---as long as `clone_area` is inside the engine. `nil` between clones.
---@type integer|nil
local current_turn = nil

---Said once per save, not once per entity: a clone event outside a clone would
---otherwise fill the log with one line per cloned entity.
local warned_without_a_turn = false

---How far from the origin the hidden tiles of a cloned chunk are carried over;
---see `Public.rotate_tiles`. `main.lua:890` bounds the two-team map's own hidden
---tile repair at the same 192 tiles.
local HIDDEN_TILE_RADIUS = 192

---@param surface LuaSurface
---@param bb BoundingBox
local function clear_entities(surface, bb)
    local objects = surface.find_entities_filtered({
        area = bb,
        name = 'character',
        invert = true,
    })

    for _, object in pairs(objects) do
        object.destroy()
    end
end

---The 32x32 box of a chunk, in tile coordinates -- the shape
---`on_chunk_generated` hands out as `event.area`.
---@param chunk {x: int, y: int}
---@return BoundingBox
local function chunk_area(chunk)
    local left_top_x = chunk.x * 32
    local left_top_y = chunk.y * 32
    return {
        left_top = { x = left_top_x, y = left_top_y },
        right_bottom = { x = left_top_x + 32, y = left_top_y + 32 },
    }
end

---How far the clone that produced this destination turned the canonical zone.
---
---The clone in progress knows exactly, and is the answer whenever there is one:
---an entity sitting on the far edge of its chunk is translated onto the far edge
---of the image chunk, and reading the chunk back out of that position would name
---the chunk after it. Without a clone in progress -- which cannot happen, since
---the engine raises both clone events inside `clone_area` -- the destination
---chunk is still a good guess, and the guess is logged.
---@param position MapPosition Of the destination entity, or of the cloned area.
---@return integer k 0..3
local function turn_of(position)
    if current_turn ~= nil then
        return current_turn
    end
    local k = Layout.quadrant_of_chunk(math_floor(position.x / 32), math_floor(position.y / 32))
    if not warned_without_a_turn then
        warned_without_a_turn = true
        log(
            'rotate_terrain: a clone event arrived while no clone was running; '
                .. 'falling back on the destination quadrant '
                .. k
                .. '.'
        )
    end
    return k
end

---Clone the canonical chunk onto one of its three image chunks.
---
---The caller has checked that both chunks exist and that the canonical one has
---been through the script generator: cloning into a chunk the engine has not
---generated yet truncates entities on the chunk border, which is the rule
---`main.lua` keeps for the two-team map as well.
---@param surface LuaSurface
---@param canonical_chunk {x: int, y: int} The chunk of the canonical quadrant.
---@param image_chunk {x: int, y: int} Its image, `Layout.rotate_chunk(k, ...)`.
---@param k integer 1..3, the quarter turns from the canonical chunk to the image.
function Public.clone(surface, canonical_chunk, image_chunk, k)
    local source_bb = chunk_area(canonical_chunk)
    local destination_bb = chunk_area(image_chunk)

    -- Clone entities. This will trigger on_entity_cloned where we'll adjust
    -- positions, orientations etc. It will also trigger on_area_cloned where we
    -- can clone tiles at turned positions.
    local request = {
        source_area = source_bb,
        destination_area = destination_bb,
        destination_surface = surface,
        clone_tiles = false,
        clone_entities = true,
        clone_decoratives = false,
        clear_destination_entities = false,
        clear_destination_decoratives = true,
        create_build_effect_smoke = false,
        expand_map = true,
    }

    -- Workaround for what I assume is bug in game engine.
    -- "Source entities overlap with destination entities."
    -- Seems like clear_destination_entities flag is ignored in some edge cases.
    clear_entities(surface, destination_bb)

    current_turn = k
    surface.clone_area(request)
    current_turn = nil
end

---`on_entity_cloned`: put one cloned entity where, and on whose side, it belongs.
---@param event EventData.on_entity_cloned
function Public.rotate_entity(event)
    local destination = event.destination

    -- Don't allow soulless characters to be cloned into another quadrant.
    if destination.name == 'character' then
        destination.destroy()
        return
    end

    local k = turn_of(destination.position)
    local team = Layout.team_of_quadrant(k)
    -- The canonical zone is the quadrant the script generates, so everything it
    -- made carries the force of the team playing there; the clone carries the
    -- force of the team it lands on.
    local canonical_team = Layout.team_of_quadrant(0)
    if not team or not canonical_team then
        -- The chunk handler never clones into a quadrant no team owns, and the
        -- canonical quadrant's team plays in every round of every size.
        log(
            'rotate_terrain: an entity was cloned into quadrant '
                .. k
                .. ' (team '
                .. tostring(team)
                .. ', canonical team '
                .. tostring(canonical_team)
                .. '); destroyed.'
        )
        destination.destroy()
        return
    end

    if destination.force.name == canonical_team then
        destination.force = team
    elseif destination.force.name == Teams.biter_force(canonical_team) then
        destination.force = Teams.biter_force(team)
    end

    if destination.supports_direction then
        destination.direction = Layout.rotate_direction(k, destination.direction)
    end

    -- Mirror the entity's position in relation to the source entity: the clone
    -- is at the TRANSLATED position and this is the only step that makes the
    -- quadrant a mirror image rather than a copy.
    local source_position = event.source.position
    if source_position.x == 0 or source_position.y == 0 then
        -- Both axes are rivers on this map and a point of an axis stays on
        -- it, so nothing may stand there -- and `mirror_terrain.lua:92`
        -- destroys the entities of its own axis for the same reason.
        destination.destroy()
        return
    end
    local x, y = Layout.rotate_position(k, source_position.x, source_position.y)
    -- It's safe to use teleport() even if final position is on top of lake.
    if not destination.teleport({ x = x, y = y }) then
        -- Impossible: the turned position is inside the image chunk, which was
        -- cleared just before the clone. Kept where it landed rather than
        -- deleted, so that a team does not silently lose its silo.
        log(
            'rotate_terrain: could not teleport a cloned '
                .. destination.name
                .. ' to ('
                .. x
                .. ', '
                .. y
                .. '); it stays at the translated position.'
        )
    end

    local position = destination.position
    if destination.name == 'rocket-silo' and math_abs(position.x) < 150 and math_abs(position.y) < 150 then
        -- NOTE: Silo is cloned several times into a quadrant if it sits on a
        -- chunk border; the last clone is the one that stands, as on the
        -- two-team map (`mirror_terrain.lua:107-109`). The radius is that test
        -- made square: the canonical silo stands at y = -72 with |x| <= 104, so
        -- 150 tiles from the origin cover it in every quadrant.
        storage.rocket_silo[destination.force.name] = { destination }
        AiTargets.start_tracking(destination)
    elseif destination.name == 'gun-turret' then
        AiTargets.start_tracking(destination)
    elseif destination.name == 'spitter-spawner' or destination.name == 'biter-spawner' then
        table_insert(storage.unit_spawners[destination.force.name], destination)
    end
end

local tiles = {}
for i = 1, 32 * 32 do
    tiles[i] = {
        position = { 0, 0 },
        name = '',
    }
end

---`on_area_cloned`: re-emplace the 1024 tiles of the cloned chunk at their
---turned cells, hidden tiles included.
---
---Tile (tx, ty) goes to `Layout.rotate_tile(k, tx, ty)`, which carries the same
---off-by-one as the legacy `(x, -y - 1)`: a tile is the cell [tx, tx+1) x
---[ty, ty+1), not a point, and the -1 rides on the axis that becomes negative.
---
---The HIDDEN tiles are copied along with them, near the origin. On the two-team
---map they are not, and `Mirror_terrain.remove_hidden_tiles` has to repair the
---one case that matters afterwards -- the southern silo's refined concrete
---sitting on the water the northern silo generation had replaced by dirt, which a
---player could mine the silo into. Copying the source's hidden tile is that
---repair done for every tile at once, so there is no counterpart of that
---function here.
---
---`HIDDEN_TILE_RADIUS` is the bound of that repair (`main.lua:890`) made square,
---and it is here for the reason the legacy bound is there: past it the only
---tiles with a hidden one are the biter area's, where every single tile hides an
---out-of-map, and two API calls each over a chunk of 1024 of them -- three times,
---once per image -- is a cost the map reveal would feel. The two-team map has
---left its southern biter area without those hidden tiles since the beginning.
---@param event EventData.on_area_cloned
function Public.rotate_tiles(event)
    local surface = event.destination_surface
    local k = turn_of(event.destination_area.left_top)
    local to_emplace = surface.find_tiles_filtered({
        area = event.source_area,
    })

    if #to_emplace ~= #tiles then
        -- Impossible: a quarter turn maps a chunk-aligned 32x32 box onto a
        -- chunk-aligned 32x32 box, and only whole chunks are ever cloned.
        log(
            'rotate_terrain: the cloned area holds '
                .. #to_emplace
                .. ' tiles instead of '
                .. #tiles
                .. '; none re-emplaced.'
        )
        return
    end

    for i, src_tile in pairs(to_emplace) do
        local tile = tiles[i]
        local pos = src_tile.position
        tile.position[1], tile.position[2] = Layout.rotate_tile(k, pos.x, pos.y)
        tile.name = src_tile.name
    end

    surface.set_tiles(tiles)

    -- After `set_tiles`, which drops whatever the destination hid before.
    local source_left_top = event.source_area.left_top
    if math_abs(source_left_top.x) > HIDDEN_TILE_RADIUS or math_abs(source_left_top.y) > HIDDEN_TILE_RADIUS then
        return
    end
    local hidden = surface.find_tiles_filtered({
        area = event.source_area,
        has_hidden_tile = true,
    })
    for _, src_tile in pairs(hidden) do
        local pos = src_tile.position
        local tx, ty = Layout.rotate_tile(k, pos.x, pos.y)
        surface.set_hidden_tile({ tx, ty }, surface.get_hidden_tile(pos))
    end
end

---`on_area_cloned`: the decoratives of the cloned chunk, at their turned cells.
---
---A decorative sits on a tile, so it takes the tile transform, exactly as the
---legacy `invert_decoratives` gives it the tile reflection `(x, -y - 1)`.
---@param event EventData.on_area_cloned
function Public.rotate_decoratives(event)
    local surface = event.destination_surface
    local k = turn_of(event.destination_area.left_top)
    local src_decoratives = surface.find_decoratives_filtered({
        area = event.source_area,
    })

    local dest_decoratives = {}
    for i, d in pairs(src_decoratives) do
        local pos = d.position
        local x, y = Layout.rotate_tile(k, pos.x, pos.y)
        dest_decoratives[i] = {
            amount = d.amount,
            position = { x = x, y = y },
            name = d.decorative.name,
        }
    end

    surface.create_decoratives({ check_collision = false, decoratives = dest_decoratives })
end

return Public
