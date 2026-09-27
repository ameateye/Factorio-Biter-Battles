---@diagnostic disable
--
-- Pins `maps/biter_battles_v2/layout.lua`, the geometry model: the transform
-- group that carries the canonical zone onto each team's zone, and every
-- answer that depends on where a team is.
--
-- This suite is the whole specification of the module -- and the terrain
-- pipeline is built on exactly these answers. What it is here to catch:
--
--   * the CELL OFF-BY-ONE. A tile is the half-open square [tx,tx+1) x [ty,ty+1),
--     so the turn that sends the point (x, y) to (-y, x) sends the tile (tx, ty)
--     to (-ty-1, tx) and not to (-ty, tx). Three tests nail it down: the corners
--     of a tile land on the corners of the turned tile, every interior point of
--     a tile lands inside the turned tile, and the 1024 tiles of a chunk land
--     one per tile on the 1024 tiles of the turned chunk. A missing -1 slides a
--     whole quadrant by one tile, and the `#to_emplace == #tiles` assert of
--     `mirror_terrain.lua:147` would not notice -- it only counts them;
--   * the GROUP LAWS: four turns are the identity, `unrotate` undoes `rotate`,
--     turns compose and a turn count is read modulo 4 -- for positions, tiles,
--     chunks and the sixteen directions of Factorio 2.0 alike;
--   * that quadrant numbers, the canonical chunk of an orbit and the team of a
--     quadrant all agree on one numbering: k = the team's quarter turns;
--   * the TWO-TEAM answers, which have to be today's: spawns {0,-44} and {0,44}
--     (init.lua:141-150), the y-sign test of `of_position`, the tile reflection
--     (tx, -ty-1) of `mirror_terrain.lua:141-156`, and no quadrants at all;
--   * that an ELIMINATION does not close a quadrant. `team_of_quadrant` reads
--     `Teams.all()` and not `Teams.alive()`, which is load-bearing: flipped to
--     `alive()` it would make `Terrain.is_cross4_river_tile` declare a dead
--     team's whole square un-landfillable and `Functions.is_roughly_biter_area`
--     turn its biter wedge off, mid-round.
--
-- The module loads outside Factorio: it requires only `teams.lua` (itself
-- needing nothing but `config.lua` and `utils/force.lua`, both pure) and touches
-- neither `game` nor any event. `storage` is the usual mock, rebuilt per test
-- because lunatest walks the test table with `pairs`; the two elimination tests
-- install a `game` of one field, `tick`, which is all `Teams.eliminate` reads.

local lunatest = require('lunatest')

storage = { ['_TEST'] = true }

local Layout = require('maps.biter_battles_v2.layout')
local Teams = require('maps.biter_battles_v2.teams')

--- Ask for `count` teams and start the round.
local function round_of(count)
    lunatest.assert_true(Teams.set_next_count(count), 'set_next_count(' .. tostring(count) .. ')')
    return Teams.begin_round()
end

--- A cell (tile or chunk) as one comparable string. Integer cells never carry a
--- negative zero -- the axis that is negated always has the -1 of the cell
--- transform taken off it -- so a `-0` can never reach one of these keys.
--- Positions can carry one and are compared component by component instead.
local function cell(x, y)
    return tostring(x) .. ',' .. tostring(y)
end

--- A rotated POSITION as a comparable string. Negating a zero gives the IEEE
--- negative zero, which compares equal to 0 but prints as '-0'; adding zero
--- folds it back (-0 + 0 = +0), so a corner on an axis keys the same whichever
--- way it was reached. The only place in this suite that makes a key of a point.
local function point(x, y)
    return cell(x + 0, y + 0)
end

--- Both components of a point or a cell at once.
---
--- The message comes FIRST so that the two-value call being tested can be
--- written last, where Lua expands it to both of its values instead of dropping
--- the second one. `assert_equal` on two numbers is a tolerance test, so the
--- IEEE negative zero that negating a zero produces compares equal to 0 here.
local function assert_xy(what, expected_x, expected_y, x, y)
    lunatest.assert_equal(expected_x, x, what .. ' [x]')
    lunatest.assert_equal(expected_y, y, what .. ' [y]')
end

--- The same for the `{ x =, y = }` tables of spawns and axis vectors.
local function assert_vector(what, expected_x, expected_y, vector)
    lunatest.assert_not_nil(vector, what)
    assert_xy(what, expected_x, expected_y, vector.x, vector.y)
end

--- The points and cells the group laws are checked on: both signs, the 0 / -1
--- boundary that the cell transform turns on, a chunk-sized pair and two far
--- ones.
local SAMPLES = {
    { 0, 0 },
    { -1, -1 },
    { 0, -1 },
    { -1, 0 },
    { 1, 0 },
    { 0, 1 },
    { 1, 1 },
    { -1, 1 },
    { 1, -1 },
    { 2, -3 },
    { -2, 3 },
    { -5, -7 },
    { 31, -32 },
    { -32, 31 },
    { 1000, -1001 },
    { -1001, 1000 },
}

--- Turn counts that are not already 0..3: negative, zero, and past a full turn.
local WINDINGS = { -9, -4, -3, -2, -1, 0, 1, 2, 3, 4, 5, 8, 11 }

--- The unit position a direction points at, y growing south (defines.direction:
--- north = 0, east = 4, south = 8, west = 12).
local CARDINALS = {
    [0] = { x = 0, y = -1 },
    [4] = { x = 1, y = 0 },
    [8] = { x = 0, y = 1 },
    [12] = { x = -1, y = 0 },
}

function setup()
    storage = { ['_TEST'] = true }
    game = nil
end

--- Nothing but `game.tick`, which is all `Teams.eliminate` reads. Only the
--- elimination test below needs it.
local function mock_game(tick)
    game = { tick = tick or 0 }
end

-- ---------------------------------------------------------------------------
-- The group laws
-- ---------------------------------------------------------------------------

function test_four_quarter_turns_are_the_identity()
    for _, sample in ipairs(SAMPLES) do
        local x, y = sample[1], sample[2]

        local px, py = x, y
        local tx, ty = x, y
        local cx, cy = x, y
        for _ = 1, 4 do
            px, py = Layout.rotate_position(1, px, py)
            tx, ty = Layout.rotate_tile(1, tx, ty)
            cx, cy = Layout.rotate_chunk(1, cx, cy)
        end

        assert_xy('position ' .. cell(x, y), x, y, px, py)
        assert_xy('tile ' .. cell(x, y), x, y, tx, ty)
        assert_xy('chunk ' .. cell(x, y), x, y, cx, cy)
    end

    for d = 0, 15 do
        local turned = d
        for _ = 1, 4 do
            turned = Layout.rotate_direction(1, turned)
        end
        lunatest.assert_equal(d, turned, 'direction ' .. d)
    end
end

function test_a_closed_form_turn_is_the_single_turn_applied_that_many_times()
    for _, sample in ipairs(SAMPLES) do
        local x, y = sample[1], sample[2]
        local px, py = x, y
        local tx, ty = x, y
        for k = 1, 4 do
            px, py = Layout.rotate_position(1, px, py)
            tx, ty = Layout.rotate_tile(1, tx, ty)
            local what = cell(x, y) .. ' turned ' .. k
            assert_xy('position ' .. what, px, py, Layout.rotate_position(k, x, y))
            assert_xy('tile ' .. what, tx, ty, Layout.rotate_tile(k, x, y))
            assert_xy('chunk ' .. what, tx, ty, Layout.rotate_chunk(k, x, y))
        end
    end
end

function test_unrotate_undoes_rotate_whatever_the_winding()
    for _, k in ipairs(WINDINGS) do
        for _, sample in ipairs(SAMPLES) do
            local x, y = sample[1], sample[2]
            local what = cell(x, y) .. ' k=' .. k

            assert_xy('position ' .. what, x, y, Layout.unrotate_position(k, Layout.rotate_position(k, x, y)))
            assert_xy(
                'position back first ' .. what,
                x,
                y,
                Layout.rotate_position(k, Layout.unrotate_position(k, x, y))
            )
            assert_xy('tile ' .. what, x, y, Layout.unrotate_tile(k, Layout.rotate_tile(k, x, y)))
            assert_xy('tile back first ' .. what, x, y, Layout.rotate_tile(k, Layout.unrotate_tile(k, x, y)))
            assert_xy('chunk ' .. what, x, y, Layout.unrotate_chunk(k, Layout.rotate_chunk(k, x, y)))
            assert_xy('chunk back first ' .. what, x, y, Layout.rotate_chunk(k, Layout.unrotate_chunk(k, x, y)))
        end

        for d = 0, 15 do
            local what = 'direction ' .. d .. ' k=' .. k
            lunatest.assert_equal(d, Layout.unrotate_direction(k, Layout.rotate_direction(k, d)), what)
            lunatest.assert_equal(d, Layout.rotate_direction(k, Layout.unrotate_direction(k, d)), what)
        end
    end
end

function test_a_turn_count_is_read_modulo_four()
    for _, k in ipairs(WINDINGS) do
        local folded = k % 4
        for _, sample in ipairs(SAMPLES) do
            local x, y = sample[1], sample[2]
            local what = cell(x, y) .. ' k=' .. k

            local px, py = Layout.rotate_position(folded, x, y)
            assert_xy('position ' .. what, px, py, Layout.rotate_position(k, x, y))
            local tx, ty = Layout.rotate_tile(folded, x, y)
            assert_xy('tile ' .. what, tx, ty, Layout.rotate_tile(k, x, y))
            local ux, uy = Layout.unrotate_tile(folded, x, y)
            assert_xy('unrotated tile ' .. what, ux, uy, Layout.unrotate_tile(k, x, y))
        end
        for d = 0, 15 do
            lunatest.assert_equal(Layout.rotate_direction(folded, d), Layout.rotate_direction(k, d), 'direction ' .. d)
        end
    end
end

function test_turns_compose()
    for a = 0, 3 do
        for b = 0, 3 do
            for _, sample in ipairs(SAMPLES) do
                local x, y = sample[1], sample[2]
                local what = cell(x, y) .. ' turned ' .. a .. ' then ' .. b

                local px, py = Layout.rotate_position(a + b, x, y)
                assert_xy('position ' .. what, px, py, Layout.rotate_position(a, Layout.rotate_position(b, x, y)))
                local tx, ty = Layout.rotate_tile(a + b, x, y)
                assert_xy('tile ' .. what, tx, ty, Layout.rotate_tile(a, Layout.rotate_tile(b, x, y)))
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- The quarter turn is the clockwise one of Factorio's axes
-- ---------------------------------------------------------------------------

function test_one_turn_sends_north_to_east_and_the_canonical_quadrant_to_the_top_right()
    -- Factorio's y grows to the SOUTH, so (0,-1) is north and R(x,y) = (-y,x).
    assert_xy('north -> east', 1, 0, Layout.rotate_position(1, 0, -1))
    assert_xy('north -> south', 0, 1, Layout.rotate_position(2, 0, -1))
    assert_xy('north -> west', -1, 0, Layout.rotate_position(3, 0, -1))

    assert_xy('canonical corner -> top right', 1, -1, Layout.rotate_position(1, -1, -1))
    lunatest.assert_equal(1, Layout.quadrant_of_position(Layout.rotate_position(1, -1, -1)))
    lunatest.assert_equal(2, Layout.quadrant_of_position(Layout.rotate_position(2, -1, -1)))
    lunatest.assert_equal(3, Layout.quadrant_of_position(Layout.rotate_position(3, -1, -1)))
end

function test_a_direction_turns_by_four_of_the_sixteen_steps()
    lunatest.assert_equal(4, Layout.rotate_direction(1, 0), 'north -> east')
    lunatest.assert_equal(2, Layout.rotate_direction(1, 14), '14 -> 2')
    lunatest.assert_equal(8, Layout.rotate_direction(2, 0), 'north -> south')
    lunatest.assert_equal(0, Layout.rotate_direction(1, 12), 'west -> north')
    lunatest.assert_equal(12, Layout.rotate_direction(3, 0), 'north -> west')
    lunatest.assert_equal(0, Layout.rotate_direction(0, 0), 'no turn at all')

    for d = 0, 15 do
        lunatest.assert_equal((d + 4) % 16, Layout.rotate_direction(1, d), 'direction ' .. d)
        lunatest.assert_equal((d + 12) % 16, Layout.unrotate_direction(1, d), 'direction ' .. d .. ' back')
    end
end

function test_directions_and_positions_mean_the_same_turn()
    for k = 0, 3 do
        for d, unit in pairs(CARDINALS) do
            local turned = CARDINALS[Layout.rotate_direction(k, d)]
            assert_xy(
                'direction ' .. d .. ' turned ' .. k,
                turned.x,
                turned.y,
                Layout.rotate_position(k, unit.x, unit.y)
            )
        end
    end
end

-- ---------------------------------------------------------------------------
-- The cell off-by-one
-- ---------------------------------------------------------------------------

function test_one_turn_of_a_tile_is_the_documented_formula()
    -- The four tiles that touch the origin, one per quadrant, turn onto one
    -- another: each stays against the axes instead of stepping over them.
    assert_xy('tile -1,-1 (canonical corner)', 0, -1, Layout.rotate_tile(1, -1, -1))
    assert_xy('tile 0,-1', 0, 0, Layout.rotate_tile(1, 0, -1))
    assert_xy('tile 0,0', -1, 0, Layout.rotate_tile(1, 0, 0))
    assert_xy('tile -1,0', -1, -1, Layout.rotate_tile(1, -1, 0))
    -- One step further out, on both sides of the vertical axis.
    assert_xy('tile -1,1', -2, -1, Layout.rotate_tile(1, -1, 1))
    assert_xy('tile -3,-1', 0, -3, Layout.rotate_tile(1, -3, -1))
    -- Two turns are the point reflection of the lattice: both axes take the -1.
    assert_xy('tile 0,0 twice', -1, -1, Layout.rotate_tile(2, 0, 0))
    assert_xy('tile -1,-1 twice', 0, 0, Layout.rotate_tile(2, -1, -1))
    -- Three turns: the -1 rides on the other axis.
    assert_xy('tile -1,-1 three times', -1, 0, Layout.rotate_tile(3, -1, -1))
end

function test_a_tiles_corners_rotate_onto_the_rotated_tiles_corners()
    local CORNERS = { { 0, 0 }, { 1, 0 }, { 0, 1 }, { 1, 1 } }
    for tx = -3, 3 do
        for ty = -3, 3 do
            for k = 0, 3 do
                local rtx, rty = Layout.rotate_tile(k, tx, ty)

                local wanted = {}
                for _, corner in ipairs(CORNERS) do
                    wanted[point(rtx + corner[1], rty + corner[2])] = true
                end

                for _, corner in ipairs(CORNERS) do
                    local key = point(Layout.rotate_position(k, tx + corner[1], ty + corner[2]))
                    lunatest.assert_true(
                        wanted[key],
                        ('corner %s of tile %s turned %d landed on %s'):format(
                            cell(corner[1], corner[2]),
                            cell(tx, ty),
                            k,
                            key
                        )
                    )
                    wanted[key] = nil
                end
                lunatest.assert_nil(next(wanted), 'every corner of the turned tile was hit exactly once')
            end
        end
    end
end

function test_the_inside_of_a_tile_rotates_into_the_rotated_tile()
    -- The real off-by-one test: a point strictly inside the cell [tx,tx+1) x
    -- [ty,ty+1) must land strictly inside the cell of the turned tile, whose
    -- floor is therefore that tile. Without the -1 the whole quadrant slides.
    local FRACTIONS = { 1e-9, 0.25, 0.5, 0.75, 1 - 1e-9 }
    for tx = -3, 3 do
        for ty = -3, 3 do
            for k = 0, 3 do
                local rtx, rty = Layout.rotate_tile(k, tx, ty)
                for _, a in ipairs(FRACTIONS) do
                    for _, b in ipairs(FRACTIONS) do
                        local x, y = Layout.rotate_position(k, tx + a, ty + b)
                        assert_xy(
                            ('tile %s + %g,%g turned %d'):format(cell(tx, ty), a, b, k),
                            rtx,
                            rty,
                            math.floor(x),
                            math.floor(y)
                        )
                    end
                end
            end
        end
    end
end

function test_a_chunks_1024_tiles_rotate_onto_the_rotated_chunks_1024_tiles()
    local CHUNKS = { { -1, -1 }, { 0, 0 }, { -1, 0 }, { 3, -2 }, { -5, -7 }, { 12, 9 } }
    for _, chunk in ipairs(CHUNKS) do
        local cx, cy = chunk[1], chunk[2]
        for k = 0, 3 do
            local rcx, rcy = Layout.rotate_chunk(k, cx, cy)
            local left, top = 32 * rcx, 32 * rcy
            local seen, count = {}, 0
            for i = 0, 31 do
                for j = 0, 31 do
                    local x, y = Layout.rotate_tile(k, 32 * cx + i, 32 * cy + j)
                    local what = ('tile %d,%d of chunk %s turned %d'):format(i, j, cell(cx, cy), k)
                    lunatest.assert_true(x >= left and x < left + 32, what .. ' has an x inside the turned chunk')
                    lunatest.assert_true(y >= top and y < top + 32, what .. ' has a y inside the turned chunk')
                    local key = (x - left) * 32 + (y - top)
                    lunatest.assert_nil(seen[key], what .. ' is not the second tile on one cell')
                    seen[key] = true
                    count = count + 1
                end
            end
            lunatest.assert_equal(1024, count, 'chunk ' .. cell(cx, cy) .. ' turned ' .. k)
        end
    end
end

-- ---------------------------------------------------------------------------
-- Quadrants
-- ---------------------------------------------------------------------------

function test_the_quadrants_split_the_plane_at_the_axes()
    -- Cells: -1 is the last one before the axis, 0 the first one after it.
    lunatest.assert_equal(0, Layout.quadrant_of_tile(-1, -1))
    lunatest.assert_equal(1, Layout.quadrant_of_tile(0, -1))
    lunatest.assert_equal(2, Layout.quadrant_of_tile(0, 0))
    lunatest.assert_equal(3, Layout.quadrant_of_tile(-1, 0))
    lunatest.assert_equal(0, Layout.quadrant_of_chunk(-1, -1))
    lunatest.assert_equal(1, Layout.quadrant_of_chunk(0, -1))
    lunatest.assert_equal(2, Layout.quadrant_of_chunk(0, 0))
    lunatest.assert_equal(3, Layout.quadrant_of_chunk(-1, 0))

    -- Points: an axis itself belongs to the non-negative side of it.
    lunatest.assert_equal(0, Layout.quadrant_of_position(-0.5, -0.5))
    lunatest.assert_equal(0, Layout.quadrant_of_position(-0.0001, -0.0001))
    lunatest.assert_equal(1, Layout.quadrant_of_position(0, -0.5))
    lunatest.assert_equal(2, Layout.quadrant_of_position(0, 0))
    lunatest.assert_equal(2, Layout.quadrant_of_position(0.5, 0))
    lunatest.assert_equal(3, Layout.quadrant_of_position(-0.5, 0))

    lunatest.assert_equal(0, Layout.quadrant_of_position(Layout.CANONICAL_SPAWN.x, Layout.CANONICAL_SPAWN.y))
    lunatest.assert_equal(2, Layout.quadrant_of_chunk(31, 31))
end

function test_turning_the_canonical_quadrant_k_times_lands_in_quadrant_k()
    for k = 0, 3 do
        for _, sample in ipairs(SAMPLES) do
            -- Force the sample into the canonical quadrant: both parts < 0.
            local tx = -math.abs(sample[1]) - 1
            local ty = -math.abs(sample[2]) - 1
            local what = cell(tx, ty) .. ' turned ' .. k

            lunatest.assert_equal(0, Layout.quadrant_of_tile(tx, ty), 'canonical ' .. cell(tx, ty))
            lunatest.assert_equal(k, Layout.quadrant_of_tile(Layout.rotate_tile(k, tx, ty)), 'tile ' .. what)
            lunatest.assert_equal(k, Layout.quadrant_of_chunk(Layout.rotate_chunk(k, tx, ty)), 'chunk ' .. what)
            lunatest.assert_equal(
                k,
                Layout.quadrant_of_position(Layout.rotate_position(k, tx + 0.5, ty + 0.5)),
                'position ' .. what
            )
        end
    end
end

function test_every_chunk_has_one_canonical_chunk_and_one_orbit_of_four()
    local reached = {}
    for cx = -5, 4 do
        for cy = -5, 4 do
            local ccx, ccy, k = Layout.canonical_chunk(cx, cy)
            local what = 'chunk ' .. cell(cx, cy)

            lunatest.assert_true(ccx < 0 and ccy < 0, what .. ' has its canonical member in the top left')
            lunatest.assert_equal(0, Layout.quadrant_of_chunk(ccx, ccy), what .. ' canonical quadrant')
            lunatest.assert_equal(Layout.quadrant_of_chunk(cx, cy), k, what .. ' turn count is its quadrant')
            assert_xy(what .. ' comes back from its canonical', cx, cy, Layout.rotate_chunk(k, ccx, ccy))

            -- A canonical chunk is its own canonical member, with no turn.
            local rcx, rcy, rk = Layout.canonical_chunk(ccx, ccy)
            assert_xy(what .. ' canonical is a fixed point', ccx, ccy, rcx, rcy)
            lunatest.assert_equal(0, rk, what .. ' canonical needs no turn')

            local orbit = Layout.chunk_orbit(cx, cy)
            lunatest.assert_equal(4, #orbit, what .. ' orbit size')
            local members = {}
            for i, entry in ipairs(orbit) do
                local which = what .. ' orbit entry ' .. i
                lunatest.assert_equal(i - 1, entry.k, which .. ' carries k = i - 1')
                assert_xy(
                    which .. ' is the canonical turned k times',
                    entry.x,
                    entry.y,
                    Layout.rotate_chunk(entry.k, ccx, ccy)
                )
                lunatest.assert_equal(
                    entry.k,
                    Layout.quadrant_of_chunk(entry.x, entry.y),
                    which .. ' sits in quadrant k'
                )
                lunatest.assert_nil(members[cell(entry.x, entry.y)], which .. ' is a fourth distinct chunk')
                members[cell(entry.x, entry.y)] = true
                -- Every member of the orbit answers with the same canonical.
                assert_xy(which .. ' shares the canonical', ccx, ccy, Layout.canonical_chunk(entry.x, entry.y))
            end
            lunatest.assert_true(members[cell(cx, cy)], what .. ' is a member of its own orbit')

            local key = cell(ccx, ccy)
            reached[key] = (reached[key] or 0) + 1
        end
    end

    -- The 100 chunks of [-5,4]^2 are 25 whole orbits of 4, each reached by its
    -- four members and by nothing else: one canonical member per orbit.
    local orbits = 0
    for _, hits in pairs(reached) do
        lunatest.assert_equal(4, hits, 'a canonical chunk is reached by its four members')
        orbits = orbits + 1
    end
    lunatest.assert_equal(25, orbits)
end

-- ---------------------------------------------------------------------------
-- Two teams: today's map
-- ---------------------------------------------------------------------------

function test_two_teams_have_no_quadrants()
    round_of(2)
    lunatest.assert_equal('horizontal2', Teams.layout())
    for k = 0, 3 do
        lunatest.assert_nil(Layout.team_of_quadrant(k), 'quadrant ' .. k .. ' belongs to nobody')
        lunatest.assert_false(Layout.is_closed_quadrant(k), 'quadrant ' .. k .. ' is not closed either')
    end
end

function test_two_teams_split_the_map_by_the_sign_of_y()
    round_of(2)
    local first, second = Teams.all()[1], Teams.all()[2]

    lunatest.assert_equal(first, Layout.of_position({ x = 0, y = -1 }))
    lunatest.assert_equal(first, Layout.of_position({ x = 500, y = -0.0001 }))
    lunatest.assert_equal(second, Layout.of_position({ x = 0, y = 0 }), 'y = 0 is the second team, as today')
    lunatest.assert_equal(second, Layout.of_position({ x = -500, y = 1 }))
end

function test_two_team_spawns_are_todays_two_literals()
    round_of(2)
    assert_vector('first team spawn', 0, -44, Layout.spawn_position(Teams.all()[1]))
    assert_vector('second team spawn', 0, 44, Layout.spawn_position(Teams.all()[2]))
end

function test_two_team_zones_are_the_identity_and_the_legacy_reflection()
    round_of(2)
    local first, second = Teams.all()[1], Teams.all()[2]

    assert_xy('first team keeps the canonical zone', 7, -3, Layout.from_canonical(first, 7, -3))
    assert_xy('and comes back unchanged', 7, -3, Layout.to_canonical(first, 7, -3))
    assert_xy('second team is reflected through y = 0', 7, 3, Layout.from_canonical(second, 7, -3))
    assert_xy('the reflection is its own inverse', 7, -3, Layout.to_canonical(second, 7, 3))

    -- Tiles take the -1 of `mirror_terrain.lua:141-156`: the tile against the
    -- river on one side becomes the tile against it on the other.
    assert_xy('first team tile', 7, -3, Layout.tile_from_canonical(first, 7, -3))
    assert_xy('second team tile', 7, 2, Layout.tile_from_canonical(second, 7, -3))
    assert_xy('the tile against the river', 7, 0, Layout.tile_from_canonical(second, 7, -1))
    assert_xy('and the same tile back again', 7, -1, Layout.tile_from_canonical(second, 7, 0))
    assert_xy('chunks take the same -1', 3, 0, Layout.chunk_from_canonical(second, 3, -1))
    assert_xy('the first team keeps its chunks', 3, -1, Layout.chunk_from_canonical(first, 3, -1))

    -- Directions are NOT turned here: `direction_translation`
    -- (mirror_terrain.lua:6-15) stays the authority for the reflection.
    for d = 0, 15 do
        lunatest.assert_equal(d, Layout.direction_from_canonical(first, d), 'direction ' .. d)
        lunatest.assert_equal(d, Layout.direction_from_canonical(second, d), 'direction ' .. d)
    end
end

function test_two_team_inward_vectors_face_the_river_on_y_zero()
    round_of(2)
    local first, second = Teams.all()[1], Teams.all()[2]

    assert_vector('first team faces +y', 0, 1, Layout.inward(first))
    assert_vector('its own biters are behind it', 0, -1, Layout.outward(first))
    assert_vector('second team faces -y', 0, -1, Layout.inward(second))
    assert_vector('its own biters are behind it', 0, 1, Layout.outward(second))
end

function test_a_team_that_does_not_play_the_two_team_map_has_no_zone()
    round_of(2)
    local absent = {}
    for _, team in ipairs(Teams.roster()) do
        if not Teams.is_active(team) then
            absent[#absent + 1] = team
        end
    end
    absent[#absent + 1] = 'spectator'
    absent[#absent + 1] = 'not a team at all'
    lunatest.assert_equal(4, #absent)

    for _, team in ipairs(absent) do
        lunatest.assert_nil(Layout.spawn_position(team), team .. ' spawn')
        lunatest.assert_nil(Layout.inward(team), team .. ' inward')
        lunatest.assert_nil(Layout.outward(team), team .. ' outward')
        lunatest.assert_nil(Layout.from_canonical(team, 1, 2), team .. ' position')
        lunatest.assert_nil(Layout.to_canonical(team, 1, 2), team .. ' position back')
        lunatest.assert_nil(Layout.tile_from_canonical(team, 1, 2), team .. ' tile')
        lunatest.assert_nil(Layout.chunk_from_canonical(team, 1, 2), team .. ' chunk')
    end
end

-- ---------------------------------------------------------------------------
-- Four teams: the pinwheel
-- ---------------------------------------------------------------------------

function test_four_teams_own_the_four_quadrants_in_ring_order()
    round_of(4)
    lunatest.assert_equal('cross4', Teams.layout())
    for k = 0, 3 do
        local team = Layout.team_of_quadrant(k)
        lunatest.assert_equal(Teams.all()[k + 1], team, 'quadrant ' .. k)
        lunatest.assert_equal(k, Teams.k_of(team), 'the team of quadrant ' .. k .. ' turns k times')
        lunatest.assert_false(Layout.is_closed_quadrant(k), 'quadrant ' .. k .. ' is played')
    end
end

function test_four_teams_take_the_position_of_their_quadrant()
    round_of(4)
    local active = Teams.all()

    lunatest.assert_equal(active[1], Layout.of_position({ x = -1, y = -1 }), 'top left')
    lunatest.assert_equal(active[2], Layout.of_position({ x = 1, y = -1 }), 'top right')
    lunatest.assert_equal(active[3], Layout.of_position({ x = 1, y = 1 }), 'bottom right')
    lunatest.assert_equal(active[4], Layout.of_position({ x = -1, y = 1 }), 'bottom left')
    lunatest.assert_equal(active[3], Layout.of_position({ x = 0, y = 0 }), 'the origin is the non-negative corner')
    lunatest.assert_equal(active[1], Layout.of_position({ x = -600, y = -600 }), 'far out in the canonical quadrant')
end

function test_four_team_spawns_are_the_canonical_spawn_turned()
    round_of(4)
    assert_vector('the canonical spawn', -44, -44, Layout.CANONICAL_SPAWN)

    local expected = { { -44, -44 }, { 44, -44 }, { 44, 44 }, { -44, 44 } }
    for i, team in ipairs(Teams.all()) do
        local spawn = Layout.spawn_position(team)
        assert_vector(team .. ' spawn', expected[i][1], expected[i][2], spawn)
        lunatest.assert_equal(
            Teams.k_of(team),
            Layout.quadrant_of_position(spawn.x, spawn.y),
            team .. ' spawns in its own quadrant'
        )
        assert_xy(
            team .. ' spawn is the canonical spawn moved into its zone',
            spawn.x,
            spawn.y,
            Layout.from_canonical(team, Layout.CANONICAL_SPAWN.x, Layout.CANONICAL_SPAWN.y)
        )
    end
end

function test_four_team_inward_vectors_point_at_the_front_river()
    round_of(4)
    -- The pinwheel: every team faces a river arm, with its
    -- own biters behind it -- the same picture four times, turned.
    local expected = { { 0, 1 }, { -1, 0 }, { 0, -1 }, { 1, 0 } }
    for i, team in ipairs(Teams.all()) do
        assert_vector(team .. ' inward', expected[i][1], expected[i][2], Layout.inward(team))
        assert_vector(team .. ' outward', -expected[i][1], -expected[i][2], Layout.outward(team))

        -- Outward stays in the team's quadrant however far it goes; inward
        -- crosses an axis well before the spawn's 44 tiles are used up.
        local spawn = Layout.spawn_position(team)
        local out = Layout.outward(team)
        lunatest.assert_equal(
            Teams.k_of(team),
            Layout.quadrant_of_position(spawn.x + out.x * 400, spawn.y + out.y * 400),
            team .. ' stays in its quadrant going outward'
        )
        local into = Layout.inward(team)
        lunatest.assert_not_equal(
            Teams.k_of(team),
            Layout.quadrant_of_position(spawn.x + into.x * 100, spawn.y + into.y * 100),
            team .. ' leaves its quadrant going inward'
        )
    end
end

function test_four_team_zones_are_the_canonical_zone_turned()
    round_of(4)
    for _, team in ipairs(Teams.all()) do
        local k = Teams.k_of(team)
        for _, sample in ipairs(SAMPLES) do
            local x, y = sample[1], sample[2]
            local what = team .. ' ' .. cell(x, y)

            local px, py = Layout.rotate_position(k, x, y)
            assert_xy(what .. ' position', px, py, Layout.from_canonical(team, x, y))
            assert_xy(what .. ' round trip', x, y, Layout.to_canonical(team, Layout.from_canonical(team, x, y)))
            assert_xy(
                what .. ' the other way round',
                x,
                y,
                Layout.from_canonical(team, Layout.to_canonical(team, x, y))
            )

            local tx, ty = Layout.rotate_tile(k, x, y)
            assert_xy(what .. ' tile', tx, ty, Layout.tile_from_canonical(team, x, y))
            assert_xy(what .. ' chunk', tx, ty, Layout.chunk_from_canonical(team, x, y))
            assert_xy(what .. ' tile back', x, y, Layout.unrotate_tile(k, Layout.tile_from_canonical(team, x, y)))
        end
        for d = 0, 15 do
            lunatest.assert_equal(
                Layout.rotate_direction(k, d),
                Layout.direction_from_canonical(team, d),
                team .. ' direction ' .. d
            )
        end
    end
end

function test_the_canonical_zone_belongs_to_the_first_team_on_both_maps()
    round_of(4)
    local first = Teams.all()[1]
    lunatest.assert_equal(0, Teams.k_of(first), 'the first team never turns')
    assert_xy('cross4 first team is the identity', 5, -6, Layout.from_canonical(first, 5, -6))
    assert_xy('and so are its tiles', 5, -6, Layout.tile_from_canonical(first, 5, -6))

    round_of(2)
    first = Teams.all()[1]
    assert_xy('horizontal2 first team is the identity', 5, -6, Layout.from_canonical(first, 5, -6))
    assert_xy('and so are its tiles', 5, -6, Layout.tile_from_canonical(first, 5, -6))
end

-- ---------------------------------------------------------------------------
-- Three teams: one quadrant closed
-- ---------------------------------------------------------------------------

function test_three_teams_close_the_fourth_quadrant()
    round_of(3)
    lunatest.assert_equal('cross4', Teams.layout())

    for k = 0, 2 do
        lunatest.assert_equal(Teams.all()[k + 1], Layout.team_of_quadrant(k), 'quadrant ' .. k)
        lunatest.assert_false(Layout.is_closed_quadrant(k), 'quadrant ' .. k .. ' is played')
    end

    lunatest.assert_nil(Layout.team_of_quadrant(3), 'the bottom-left quadrant has no team')
    lunatest.assert_true(Layout.is_closed_quadrant(3), 'the bottom-left quadrant is closed')
    lunatest.assert_nil(Layout.of_position({ x = -1, y = 1 }), 'nobody owns a position in it')
    lunatest.assert_nil(Layout.of_position({ x = -600, y = 600 }), 'not even far out')
    lunatest.assert_equal(Teams.all()[1], Layout.of_position({ x = -1, y = -1 }), 'the other three still answer')
end

function test_the_closed_quadrant_still_has_a_geometry()
    round_of(3)
    -- The terrain code has to know where the closed quadrant is in order to fill
    -- it with water, so the per-team transforms answer for every ROSTER team;
    -- only the ownership questions restrict themselves to the active ones.
    local absent = Teams.roster()[4]
    lunatest.assert_nil(Teams.index_of(absent), 'the fourth team does not play this round')
    lunatest.assert_equal(3, Teams.k_of(absent))

    assert_vector('its quadrant still has a spawn', -44, 44, Layout.spawn_position(absent))
    assert_xy('and a tile transform', -4, 6, Layout.tile_from_canonical(absent, -7, -4))
    lunatest.assert_equal(
        3,
        Layout.quadrant_of_chunk(Layout.chunk_from_canonical(absent, -2, -3)),
        'which lands in the closed quadrant'
    )
end

function test_an_eliminated_team_does_not_close_its_quadrant()
    -- `team_of_quadrant` reads `Teams.all()`, not `Teams.alive()`,
    -- and the terrain and the build rules are built on that: a quadrant that
    -- became "closed" when its team died would make
    -- `Terrain.is_cross4_river_tile` declare the dead team's whole square
    -- un-landfillable for the rest of the round and `Functions.is_roughly_biter_area`
    -- turn its biter wedge off -- mid-round, on a square people are still
    -- fighting over. The closed quadrant is the one NOBODY was given, and that
    -- is settled at `begin_round()` and never again.
    mock_game(600)
    round_of(4)
    local dead = Teams.all()[2]

    Teams.eliminate(dead)

    lunatest.assert_false(Teams.is_alive(dead), 'the team is out of the round')
    lunatest.assert_equal(dead, Layout.team_of_quadrant(1), 'its quadrant is still its own')
    lunatest.assert_false(Layout.is_closed_quadrant(1), 'and is not closed')
    lunatest.assert_equal(dead, Layout.of_position({ x = 600, y = -600 }), 'a position in it still answers')

    -- Down to one team standing: still four squares, still no closed quadrant.
    Teams.eliminate(Teams.all()[3])
    Teams.eliminate(Teams.all()[4])
    lunatest.assert_equal(1, #Teams.alive(), 'one team left alive')
    for k = 0, 3 do
        lunatest.assert_equal(Teams.all()[k + 1], Layout.team_of_quadrant(k), 'quadrant ' .. k)
        lunatest.assert_false(Layout.is_closed_quadrant(k), 'quadrant ' .. k .. ' is still open')
    end
end

function test_an_elimination_in_a_three_team_round_leaves_exactly_one_quadrant_closed()
    -- The same rule from the other side: the bottom-left quadrant is closed
    -- because no team was given it, and killing one of the three that were does
    -- not close a second one.
    mock_game(900)
    round_of(3)

    Teams.eliminate(Teams.all()[1])

    for k = 0, 2 do
        lunatest.assert_false(Layout.is_closed_quadrant(k), 'quadrant ' .. k .. ' was played')
    end
    lunatest.assert_true(Layout.is_closed_quadrant(3), 'only the quadrant nobody was given is closed')
end

-- ---------------------------------------------------------------------------
-- The round switch
-- ---------------------------------------------------------------------------

function test_the_layout_follows_the_round_and_nothing_else()
    -- A pending request is not the round: the geometry keeps answering for the
    -- teams that are playing until the next reset.
    round_of(2)
    lunatest.assert_nil(Layout.team_of_quadrant(1), 'two teams, no quadrants')

    lunatest.assert_true(Teams.set_next_count(4))
    lunatest.assert_nil(Layout.team_of_quadrant(1), 'still two teams')
    assert_vector('still the two-team spawn', 0, -44, Layout.spawn_position(Teams.all()[1]))

    Teams.begin_round()
    lunatest.assert_equal(Teams.all()[2], Layout.team_of_quadrant(1), 'four teams now')
    assert_vector('and the four-team spawn', -44, -44, Layout.spawn_position(Teams.all()[1]))
end

-- ---------------------------------------------------------------------------
-- Reading order: the teams as they sit on the map
-- ---------------------------------------------------------------------------

--- The map cell a grid index falls in, for a two-column grid read left to
--- right, top row first: index 1 is top left, 2 top right, 3 bottom left, 4
--- bottom right. Returned as the pair of signs a position in that cell has,
--- which is what `Layout.quadrant_of_position` reads.
local function cell_signs(index)
    local column = (index - 1) % 2
    local row = math.floor((index - 1) / 2)
    return column == 0 and -1 or 1, row == 0 and -1 or 1
end

function test_grid_order_at_two_teams_is_todays_order()
    round_of(2)

    local active = Teams.all()
    local grid = Layout.grid_order()

    lunatest.assert_equal(#active, #grid, 'two teams, two cells')
    for i = 1, #active do
        lunatest.assert_equal(active[i], grid[i], 'cell ' .. i .. ' is the team all() puts there')
    end
end

function test_grid_order_never_hands_out_the_round_array()
    round_of(2)

    local grid = Layout.grid_order()
    grid[1] = 'scribbled'

    lunatest.assert_not_equal('scribbled', Teams.all()[1], 'the round array is not the one handed out')
end

function test_grid_order_at_four_teams_reads_the_map_left_to_right_top_to_bottom()
    round_of(4)

    local grid = Layout.grid_order()

    lunatest.assert_equal(4, #grid, 'four cells')
    for index = 1, 4 do
        local team = grid[index]
        lunatest.assert_true(type(team) == 'string', 'cell ' .. index .. ' has a team')
        local want_x, want_y = cell_signs(index)
        local spawn = Layout.spawn_position(team)
        lunatest.assert_equal(
            want_x < 0,
            spawn.x < 0,
            'cell ' .. index .. ': ' .. team .. ' spawns on the right side of the map'
        )
        lunatest.assert_equal(
            want_y < 0,
            spawn.y < 0,
            'cell ' .. index .. ': ' .. team .. ' spawns on the right row of the map'
        )
        -- And the same statement in quadrant numbers, which is what the
        -- terrain, the feeder and the league all read.
        lunatest.assert_equal(
            Teams.k_of(team),
            Layout.quadrant_of_position(want_x, want_y),
            'cell ' .. index .. ' is ' .. team .. "'s quadrant"
        )
    end
end

function test_grid_order_at_four_teams_is_not_the_ring()
    -- The bug once seen: iterating `all()` puts the third team of the ring
    -- (bottom RIGHT on the map) in the bottom-LEFT cell of a two-column grid.
    round_of(4)

    local ring = Teams.all()
    local grid = Layout.grid_order()

    lunatest.assert_equal(ring[1], grid[1], 'top left is the first of the ring')
    lunatest.assert_equal(ring[2], grid[2], 'top right is the second')
    lunatest.assert_equal(ring[4], grid[3], 'bottom left is the LAST of the ring, not the third')
    lunatest.assert_equal(ring[3], grid[4], 'bottom right is the third')
end

function test_grid_order_at_three_teams_leaves_the_bottom_left_cell_empty()
    round_of(3)

    local grid = Layout.grid_order()

    lunatest.assert_equal(4, #grid, 'the grid still has four cells')
    lunatest.assert_equal(Teams.all()[1], grid[1], 'top left')
    lunatest.assert_equal(Teams.all()[2], grid[2], 'top right')
    lunatest.assert_false(grid[3], 'the bottom-left cell is a hole')
    lunatest.assert_equal(Teams.all()[3], grid[4], 'bottom right')

    -- The hole is exactly the quadrant the terrain drowns.
    local want_x, want_y = cell_signs(3)
    lunatest.assert_true(
        Layout.is_closed_quadrant(Layout.quadrant_of_position(want_x, want_y)),
        'the empty cell is the closed quadrant'
    )
end

function test_grid_order_reads_a_list_it_is_given()
    round_of(4)

    local grid = Layout.grid_order({ Teams.all()[3], Teams.all()[1] })

    lunatest.assert_equal(Teams.all()[1], grid[1], 'top left, whatever order it was handed in')
    lunatest.assert_false(grid[2], 'nothing in the top-right cell')
    lunatest.assert_false(grid[3], 'nothing in the bottom-left cell')
    lunatest.assert_equal(Teams.all()[3], grid[4], 'bottom right')
end

function test_grid_order_at_two_teams_ignores_a_pending_four_team_request()
    round_of(2)
    lunatest.assert_true(Teams.set_next_count(4))

    local grid = Layout.grid_order()

    lunatest.assert_equal(2, #grid, 'still the two-team strip')
    lunatest.assert_equal(Teams.all()[1], grid[1], 'and still in all() order')
    lunatest.assert_equal(Teams.all()[2], grid[2])
end

lunatest.run()
