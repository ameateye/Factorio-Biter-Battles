-- The geometry model: where a team's zone is, and the transform that carries the
-- canonical zone onto it.
--
-- Nothing else in the scenario is meant to know that the map has a river on
-- y = 0 or four quadrants: which team owns a position, where a team spawns,
-- which way its front river lies, and how a canonical position, tile, chunk or
-- entity direction lands in a team's zone all come from here.
--
-- The CANONICAL ZONE is today's north side cut at x = 0: the quadrant x < 0 and
-- y < 0, its own biters far to the north, the contested river in front of it at
-- y = 0. Every other zone is that one moved by a member of the layout's
-- transform group:
--
--   * 'cross4' (three or four teams) moves it by the transform of quadrant k,
--     k = `Teams.k_of(team)`: north 0 (top left) keeps it, east 1 (top right) is
--     its mirror image through x = 0, south 2 (bottom right) is it turned half
--     a turn, west 3 (bottom left) is its mirror image through y = 0. So the
--     top row is one picture and its left-right mirror, and the bottom row is
--     the top row upside down: the two top teams' biters come from the north,
--     the two bottom teams' from the south, and the horizontal river is every
--     team's front river, as on the two-team map. With three teams the
--     bottom-left quadrant is closed: water, no team.
--   * 'horizontal2' (two teams, today's map) leaves the first team's zone alone
--     and reflects it through y = 0 for the second. Its second team is the
--     cross's bottom-left transform over the whole half plane, but its generator is
--     not rewritten: this module only
--     answers for it the questions a caller can ask without re-deriving terrain.
--
-- Factorio coordinates: x grows to the east, y grows to the SOUTH. The four
-- transforms, T_k for quadrant k, are
--
--     T_0(x, y) = (x, y)      T_1(x, y) = (-x, y)
--     T_3(x, y) = (x, -y)     T_2(x, y) = (-x, -y)
--
-- and T_k sends the canonical quadrant onto quadrant k. Each is its own
-- inverse, and together they are a group (the Klein four-group, T_1 T_3 = T_2),
-- not a cyclic one: `k` is a quadrant number, not a turn count. The functions
-- keep the names `rotate_*` / `unrotate_*` from when the group was the quarter
-- turns; `unrotate_*` is now the same map as `rotate_*`.
--
-- Tiles and chunks are CELLS, not points: tile (tx, ty) is the half-open square
-- [tx, tx+1) x [ty, ty+1). Its image under x -> -x is (-tx-1, -tx] x [ty, ty+1),
-- and the cell covering that image starts at -tx - 1, so
--
--     T_1(tx, ty) = (-tx - 1, ty)
--
-- -- the -1 rides on the axis that becomes negative, exactly as the legacy
-- `-y - 1` of `mirror_terrain.lua:141-156` does for the reflection. A chunk is a
-- cell of the same lattice scaled by 32 and takes the SAME formula: T_k maps a
-- chunk-aligned 32x32 box onto a chunk-aligned 32x32 box, tile for tile, which
-- is the property the clone pipeline needs.
--
-- Everything here is a pure function of its arguments plus the round's layout
-- and roster, read from `teams.lua`. No `game`, no event, no write to `storage`
-- of its own, and no floating-point arithmetic: positions are negated, tiles
-- and chunks are integer arithmetic, directions are negated or offset mod 16. A
-- component that comes out as zero may be the IEEE negative zero, since it is
-- produced by negating a zero; it compares equal to 0 and adds like 0, so no
-- consumer can tell.
--
-- The parts that need the terrain -- `is_river`, `is_biter_area`, `can_build` --
-- live with the cross generator in `terrain.lua`, not here.

local Teams = require('maps.biter_battles_v2.teams')

local Public = {}

---Where the canonical zone's team spawns. Today's two-team spawn is {0, -44}
---(init.lua:141-150), which in the four-square map sits on the vertical river,
---so the canonical spawn moves off both axes; the value is tuned on screenshots
---(four-square map). Read-only by convention.
Public.CANONICAL_SPAWN = { x = -44, y = -44 }

---The canonical zone's inward direction: from the zone towards the river it
---faces, which for today's north side is the river at y = 0, i.e. +y.
local CANONICAL_INWARD = { x = 0, y = 1 }

---Today's two-team spawns in `Teams.all()` order (init.lua:141-150). The 44 is
---also `Config.border_river_width`; it was already duplicated there and stays
---duplicated -- an operator widening the river does not move the spawns today.
local HORIZONTAL2_SPAWNS = {
    { x = 0, y = -44 },
    { x = 0, y = 44 },
}

---True while the round plays the four-square map (three or four teams).
---@return boolean
local function is_cross4()
    return Teams.layout() == 'cross4'
end

-- ---------------------------------------------------------------------------
-- The transform group: each quadrant's transform of positions, tiles, chunks
-- and directions
-- ---------------------------------------------------------------------------

---Whether quadrant k's transform negates x, and whether it negates y. Quadrant 1
---(top right) is the mirror through x = 0, quadrant 3 (bottom left) the mirror
---through y = 0, and quadrant 2 (bottom right) both, which is the half turn.
---@param k integer Any integer; only `k % 4` matters.
---@return boolean flip_x
---@return boolean flip_y
local function flips_of(k)
    local quadrant = k % 4
    return quadrant == 1 or quadrant == 2, quadrant == 2 or quadrant == 3
end

---Quadrant `k`'s transform of a continuous position. Exact: the components are
---negated, never multiplied by anything.
---@param k integer Any integer; only `k % 4` matters.
---@param x number
---@param y number
---@return number x
---@return number y
function Public.rotate_position(k, x, y)
    local flip_x, flip_y = flips_of(k)
    if flip_x then
        x = -x
    end
    if flip_y then
        y = -y
    end
    return x, y
end

---The inverse of `rotate_position`. Every transform of the group is its own
---inverse, so this is `rotate_position` again.
---@param k integer
---@param x number
---@param y number
---@return number x
---@return number y
function Public.unrotate_position(k, x, y)
    return Public.rotate_position(k, x, y)
end

---Quadrant `k`'s transform of a TILE.
---
---A tile is the cell [tx, tx+1) x [ty, ty+1), so the mirror that sends the point
---x to -x sends the tile column tx to -tx - 1: the image of [tx, tx+1) is
---(-tx-1, -tx] and the tile covering it starts at -tx - 1. The same for y.
---Integer in, integer out.
---@param k integer Any integer; only `k % 4` matters.
---@param tx integer
---@param ty integer
---@return integer tx
---@return integer ty
function Public.rotate_tile(k, tx, ty)
    local flip_x, flip_y = flips_of(k)
    if flip_x then
        tx = -tx - 1
    end
    if flip_y then
        ty = -ty - 1
    end
    return tx, ty
end

---The inverse of `rotate_tile`: `rotate_tile` again.
---@param k integer
---@param tx integer
---@param ty integer
---@return integer tx
---@return integer ty
function Public.unrotate_tile(k, tx, ty)
    return Public.rotate_tile(k, tx, ty)
end

---Quadrant `k`'s transform of a CHUNK.
---
---A chunk is a cell of the 32-tile lattice, so it takes the very same formula as
---a tile. The two agree: the 1024 tiles of a chunk land on the 1024 tiles of
---the image chunk, which is what lets the clone pipeline move whole chunks --
---its scratch buffer is exactly 32 x 32 tiles long (`mirror_terrain.lua:133-139`)
---and `:147` asserts that the area fills it.
---@param k integer Any integer; only `k % 4` matters.
---@param cx integer
---@param cy integer
---@return integer cx
---@return integer cy
function Public.rotate_chunk(k, cx, cy)
    return Public.rotate_tile(k, cx, cy)
end

---The inverse of `rotate_chunk`: `rotate_chunk` again.
---@param k integer
---@param cx integer
---@param cy integer
---@return integer cx
---@return integer cy
function Public.unrotate_chunk(k, cx, cy)
    return Public.rotate_tile(k, cx, cy)
end

---Quadrant `k`'s transform of an entity direction. Factorio 2.0 has sixteen
---directions, clockwise from north = 0 (east = 4, south = 8, west = 12). The
---mirror through x = 0 swaps east and west and keeps north: d -> -d. The mirror
---through y = 0 swaps north and south and keeps east: d -> 8 - d. Both at once
---is the half turn, d -> d + 8. All modulo 16. The y mirror is the eight-entry
---table of `mirror_terrain.lua:6-15`, which stays the authority for the
---two-team map.
---@param k integer Any integer; only `k % 4` matters.
---@param d integer
---@return integer d
function Public.rotate_direction(k, d)
    local flip_x, flip_y = flips_of(k)
    if flip_x then
        d = -d
    end
    if flip_y then
        d = 8 - d
    end
    return d % 16
end

---The inverse of `rotate_direction`: `rotate_direction` again.
---@param k integer
---@param d integer
---@return integer d
function Public.unrotate_direction(k, d)
    return Public.rotate_direction(k, d)
end

-- ---------------------------------------------------------------------------
-- Quadrants
-- ---------------------------------------------------------------------------

---Which quadrant a cell or a point of the plane lies in: 0 is x < 0 and y < 0,
---the canonical one (top left), then clockwise 1 (top right), 2 (bottom right),
---3 (bottom left). Transform `k` sends quadrant 0 onto quadrant k, so a
---quadrant number IS the `k` of the team whose zone it is.
---@param ax number
---@param ay number
---@return integer k 0..3
local function quadrant_of(ax, ay)
    if ay < 0 then
        if ax < 0 then
            return 0
        end
        return 1
    end
    if ax < 0 then
        return 3
    end
    return 2
end

---The quadrant of a TILE. The axes fall between cells: tile -1 is the last one
---of the canonical side, tile 0 the first one past the axis.
---@param tx integer
---@param ty integer
---@return integer k 0..3
function Public.quadrant_of_tile(tx, ty)
    return quadrant_of(tx, ty)
end

---The quadrant of a CHUNK: chunk -1 is the last one before the axis, chunk 0 the
---first one after it, so the canonical quadrant is `cx < 0 and cy < 0`.
---@param cx integer
---@param cy integer
---@return integer k 0..3
function Public.quadrant_of_chunk(cx, cy)
    return quadrant_of(cx, cy)
end

---The quadrant of a continuous position. A point exactly on an axis counts as
---the non-negative side of it, as the `>= 0` of the table above says.
---@param x number
---@param y number
---@return integer k 0..3
function Public.quadrant_of_position(x, y)
    return quadrant_of(x, y)
end

---The canonical member of a chunk's orbit, and the transform that produces
---this chunk from it: `ccx < 0`, `ccy < 0` and `rotate_chunk(k, ccx, ccy)` is
---`(cx, cy)` again. The quadrant number is that transform, so the answer is one
---`unrotate_chunk`.
---@param cx integer
---@param cy integer
---@return integer ccx
---@return integer ccy
---@return integer k 0..3
function Public.canonical_chunk(cx, cy)
    local k = quadrant_of(cx, cy)
    local ccx, ccy = Public.unrotate_chunk(k, cx, cy)
    return ccx, ccy, k
end

---@class ChunkOrbitEntry
---@field x integer Chunk x.
---@field y integer Chunk y.
---@field k integer 0..3, the transform from the canonical chunk to this one.

---The four chunks of an orbit -- the canonical chunk under transforms 0, 1, 2 and
---3, one per quadrant. This is the list the cross terrain pipeline waits
---for before it clones.
---
---The array is 1-based, like every list of this scenario, so that `ipairs` walks
---it: entry i carries `k = i - 1` and the position `rotate_chunk(i - 1, canonical)`.
---A fresh array of fresh entries each call.
---@param cx integer
---@param cy integer
---@return ChunkOrbitEntry[]
function Public.chunk_orbit(cx, cy)
    local ccx, ccy = Public.canonical_chunk(cx, cy)
    local orbit = {}
    for i = 1, 4 do
        local k = i - 1
        local ox, oy = Public.rotate_chunk(k, ccx, ccy)
        orbit[i] = { x = ox, y = oy, k = k }
    end
    return orbit
end

-- ---------------------------------------------------------------------------
-- Who owns what
-- ---------------------------------------------------------------------------

---The ACTIVE team that owns quadrant `k`, or nil -- either nobody owns it (a
---three-team round leaves the bottom-left quadrant closed) or the round is not
---playing the four-square map at all, where quadrants mean nothing.
---@param k any 0..3; any integer is read modulo 4.
---@return string|nil
function Public.team_of_quadrant(k)
    if type(k) ~= 'number' or not is_cross4() then
        return nil
    end
    local quadrant = k % 4
    local active = Teams.all()
    for i = 1, #active do
        local team = active[i]
        if Teams.k_of(team) == quadrant then
            return team
        end
    end
    return nil
end

---True when the four-square map has no team in quadrant `k`: with three teams
---the bottom-left quadrant is generated as water and belongs to nobody
---False for the two-team map, which has no closed quadrant.
---@param k any
---@return boolean
function Public.is_closed_quadrant(k)
    if type(k) ~= 'number' or not is_cross4() then
        return false
    end
    return Public.team_of_quadrant(k) == nil
end

-- ---------------------------------------------------------------------------
-- Reading order: the teams as they sit on the map
-- ---------------------------------------------------------------------------

---The cells of a TWO-COLUMN grid read the way a player reads the map -- left to
---right, top row first -- as quadrant numbers: top left is quadrant 0, top right
---1, bottom left 3, bottom right 2. The ring order the rest of the scenario
---iterates in (`Teams.all()`, k = 0, 1, 2, 3) is a PINWHEEL, so laying it into a
---grid row by row puts the bottom-RIGHT team in the bottom-LEFT cell: the wrong
---cell, as once seen in the research-info panel.
---@type integer[]
local GRID_CELLS = { 0, 1, 3, 2 }

---`teams` laid out as they are ON THE MAP, for a panel that draws them in a
---two-column grid. The answer is a fresh array to be walked with `ipairs`:
---
---  * 'cross4': always four entries, one per cell of the map in reading order.
---    A cell no team of `teams` owns is `false` -- not nil, so that `ipairs`
---    walks past it and the caller can put an empty widget there and keep the
---    cells after it in their own places. With three teams that hole is the
---    bottom-left cell, the quadrant the terrain drowns (§4.3).
---  * 'horizontal2': today's order, `teams` copied entry for entry, no hole and
---    no fourth cell. A two-team round must draw exactly the tree it draws
---    today, so above this line is the only thing that changes with the layout.
---
---Only a GRID needs this. A panel that lists the teams in a row or a column is
---a list, and a list keeps `Teams.all()` order.
---@param teams? string[] Defaults to the round's active teams.
---@return (string|false)[]
function Public.grid_order(teams)
    local active = teams or Teams.all()
    if not is_cross4() then
        local order = {}
        for i = 1, #active do
            order[i] = active[i]
        end
        return order
    end
    local by_quadrant = {}
    for i = 1, #active do
        local k = Teams.k_of(active[i])
        if k then
            by_quadrant[k] = active[i]
        end
    end
    local order = {}
    for cell = 1, #GRID_CELLS do
        order[cell] = by_quadrant[GRID_CELLS[cell]] or false
    end
    return order
end

---The team whose zone contains `position`, or nil.
---
---'cross4': the active team of the position's quadrant, nil when that quadrant is
---closed. 'horizontal2': `position.y < 0` is the first active team, anything else
---the second.
---
---This is the ZONE question only. Whether the point is river, lake or spectator
---island is a terrain question (`terrain.lua`), so a point on a river still
---answers with the zone it nominally sits in.
---
---The legacy call sites keep their own comparison operators until each is
---migrated: the y-sign tests of the scenario do not all agree on which side
---`y == 0` belongs to (INVENTORY §1, I3 -- `calc_send_ui.lua:556-558` is the
---silently wrong one), so replacing one of them with this function is a
---behaviour change that belongs to the change migrating that site.
---@param position MapPosition
---@return string|nil
function Public.of_position(position)
    if is_cross4() then
        return Public.team_of_quadrant(quadrant_of(position.x, position.y))
    end
    local active = Teams.all()
    if position.y < 0 then
        return active[1]
    end
    return active[2]
end

-- ---------------------------------------------------------------------------
-- Canonical zone <-> a team's zone
-- ---------------------------------------------------------------------------
--
-- In 'cross4' every ROSTER team has a quadrant whether or not it plays this
-- round: the terrain code has to know where the closed quadrant of a three-team
-- round is in order to fill it with water. Ownership questions -- who may build
-- here, who gets fed -- go through `of_position` and `team_of_quadrant`, which
-- only ever answer with an ACTIVE team. In 'horizontal2' only the two active
-- teams have a zone, and everything else answers nil.

---A canonical POSITION placed in `team`'s zone. 'cross4': transform `k`.
---'horizontal2': the first active team's zone is the canonical one (identity),
---the second is its reflection through y = 0 -- the transform the legacy mirror
---applies to entity positions (`mirror_terrain.lua:90-100`).
---@param team string
---@param x number
---@param y number
---@return number|nil x nil when the team has no zone on this map.
---@return number|nil y
function Public.from_canonical(team, x, y)
    if is_cross4() then
        local k = Teams.k_of(team)
        if not k then
            return nil
        end
        return Public.rotate_position(k, x, y)
    end
    local index = Teams.index_of(team)
    if index == 1 then
        return x, y
    elseif index == 2 then
        return x, -y
    end
    return nil
end

---A POSITION of `team`'s zone brought back to the canonical zone: the inverse of
---`from_canonical`. The reflection of 'horizontal2' is its own inverse, so that
---layout runs the very same code.
---@param team string
---@param x number
---@param y number
---@return number|nil x nil when the team has no zone on this map.
---@return number|nil y
function Public.to_canonical(team, x, y)
    if is_cross4() then
        local k = Teams.k_of(team)
        if not k then
            return nil
        end
        return Public.unrotate_position(k, x, y)
    end
    return Public.from_canonical(team, x, y)
end

---A canonical TILE placed in `team`'s zone -- the cell transform, off-by-one
---included. 'cross4': transform `k`. 'horizontal2': (tx, ty) for the first
---active team and (tx, -ty - 1) for the second, which is the legacy
---`invert_tiles` (`mirror_terrain.lua:141-156`).
---
---The inverse is `unrotate_tile(Teams.k_of(team), ...)` in 'cross4'; in
---'horizontal2' this function is its own inverse.
---@param team string
---@param tx integer
---@param ty integer
---@return integer|nil tx nil when the team has no zone on this map.
---@return integer|nil ty
function Public.tile_from_canonical(team, tx, ty)
    if is_cross4() then
        local k = Teams.k_of(team)
        if not k then
            return nil
        end
        return Public.rotate_tile(k, tx, ty)
    end
    local index = Teams.index_of(team)
    if index == 1 then
        return tx, ty
    elseif index == 2 then
        return tx, -ty - 1
    end
    return nil
end

---A canonical CHUNK placed in `team`'s zone: the same cell transform as
---`tile_from_canonical`, on the 32-tile lattice.
---@param team string
---@param cx integer
---@param cy integer
---@return integer|nil cx nil when the team has no zone on this map.
---@return integer|nil cy
function Public.chunk_from_canonical(team, cx, cy)
    return Public.tile_from_canonical(team, cx, cy)
end

---An entity DIRECTION of the canonical zone as it must be built in `team`'s
---zone. 'cross4': `rotate_direction(k, d)`.
---
---'horizontal2': returned UNCHANGED. The reflection's
---`direction_translation` (`mirror_terrain.lua:6-15`) is the authoritative table
---for that layout; it is deliberately not copied here, so the legacy clone path
---keeps exactly one definition of it and this module cannot drift from it.
---@param team string
---@param d integer
---@return integer|nil d nil when the team has no zone on the four-square map.
function Public.direction_from_canonical(team, d)
    if is_cross4() then
        local k = Teams.k_of(team)
        if not k then
            return nil
        end
        return Public.rotate_direction(k, d)
    end
    return d
end

-- ---------------------------------------------------------------------------
-- Landmarks of a zone
-- ---------------------------------------------------------------------------

---Where `team`'s players spawn. 'horizontal2': today's two literals in
---`Teams.all()` order, {0, -44} then {0, 44} (init.lua:141-150). 'cross4': the
---canonical spawn under transform k -- north {-44, -44}, east {44, -44}, south
---{44, 44}, west {-44, 44}. A fresh table each call.
---@param team string
---@return MapPosition|nil
function Public.spawn_position(team)
    if is_cross4() then
        local k = Teams.k_of(team)
        if not k then
            return nil
        end
        local x, y = Public.rotate_position(k, Public.CANONICAL_SPAWN.x, Public.CANONICAL_SPAWN.y)
        return { x = x, y = y }
    end
    local index = Teams.index_of(team)
    local spawn = index and HORIZONTAL2_SPAWNS[index]
    if not spawn then
        return nil
    end
    return { x = spawn.x, y = spawn.y }
end

---The unit axis vector from `team`'s zone towards its FRONT river -- the one the
---enemy is across. For the canonical zone that is the river at y = 0, so {0, 1},
---under transform k in 'cross4': {0, 1} for east too, {0, -1} for south and
---west. In 'horizontal2' it is {0, 1} for the first active team and {0, -1} for
---the second.
---
---A fresh table each call. A component that is zero may be the IEEE negative
---zero; it compares and adds as zero.
---@param team string
---@return { x: number, y: number }|nil
function Public.inward(team)
    if is_cross4() then
        local k = Teams.k_of(team)
        if not k then
            return nil
        end
        local x, y = Public.rotate_position(k, CANONICAL_INWARD.x, CANONICAL_INWARD.y)
        return { x = x, y = y }
    end
    local index = Teams.index_of(team)
    if index == 1 then
        return { x = CANONICAL_INWARD.x, y = CANONICAL_INWARD.y }
    elseif index == 2 then
        return { x = CANONICAL_INWARD.x, y = -CANONICAL_INWARD.y }
    end
    return nil
end

---The opposite of `inward`: from the zone towards the team's own biters, which
---live far behind it (far north of the canonical zone).
---@param team string
---@return { x: number, y: number }|nil
function Public.outward(team)
    local vector = Public.inward(team)
    if not vector then
        return nil
    end
    return { x = -vector.x, y = -vector.y }
end

return Public
