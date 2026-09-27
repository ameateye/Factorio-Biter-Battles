---@diagnostic disable
--
-- Pins the SIDE RIVER of the four-square map: `Terrain.is_side_river_tile` and
-- `Terrain.chunk_has_side_river`, the one piece of the cross
-- terrain pipeline that is a pure function and can be checked without Factorio.
--
-- The design in one sentence: the second river is the legacy river TRANSPOSED,
-- so the tile (x, y) is side-river water exactly when the legacy generator makes
-- (y, x) front-river water. Everything below is that sentence made checkable:
--
--   * the offset table is read at the ROW, not at the column. Reading it at x --
--     the mistake the whole design invites -- gives a river with the same width
--     and the same statistics, and would only be caught on a rendered map, where
--     the arm wobbles across instead of along. The test recomputes the expected
--     edge from `precomputed/river.lua` and `config.border_river_width` itself;
--   * the water of a row is a half-line reaching the axis, never a band with
--     holes: the carve pass takes the tiles this predicate names and nothing
--     smooths them afterwards;
--   * the central lake is the same lake. It reaches x = -39 on the rows next to
--     the axis and never further, so no tile left of -40 is ever water and the
--     four arms meet in one round lake rather than four different ones;
--   * the spectator island is not water in this arm either;
--   * and the CHUNK test agrees with the tile test both ways: every side-river
--     tile of the canonical quadrant lies in a chunk the carve pass visits (a
--     chunk it misses would leave a hole in the river that no probe of the
--     rendered map could miss), and the chunk test is exactly the legacy
--     `chunk_type_at` river test with its coordinates swapped;
--   * at which `border_river_width` that agreement stops. The window is one
--     chunk column wide, so it covers the arm while
--     `floor(width/2) + max_offset <= 32` -- up to 57, and `config.lua:18`
--     allows up to 64. Past it the arm is narrowed to 32 tiles, and the LEGACY
--     river is narrowed in exactly the same places: a shared, pre-existing
--     limit rather than something the transposition introduced. The
--     two tests that pin it load `terrain.lua` again with another config,
--     which is the only way to ask the real module about another width.
--
-- `terrain.lua` is not a module that loads outside Factorio: through
-- `ai_targets.lua` and `session_data.lua` it reaches `script`, `defines` and the
-- control-stage-only `Global.register`. The four stubs below are the whole of
-- what it takes; the file itself is then the real one, offset table and all.

local lunatest = require('lunatest')

storage = {
    ['_TEST'] = true,
}

script = setmetatable({}, {
    __index = function()
        return function() end
    end,
})
defines = setmetatable({}, {
    __index = function(t, k)
        local group = setmetatable({}, {
            __index = function(_, name)
                return name
            end,
        })
        rawset(t, k, group)
        return group
    end,
})
commands = { add_command = function() end }
helpers = {}

package.loaded['utils.datastore.session_data'] = {
    get_trusted_table = function()
        return {}
    end,
}
package.loaded['maps.biter_battles_v2.ai_targets'] = {
    start_tracking = function() end,
    refresh_target_types = function() end,
}

local Terrain = require('maps.biter_battles_v2.terrain')
local Config = require('maps.biter_battles_v2.config')
local river = require('maps.biter_battles_v2.precomputed.river')

local is_side_river_tile = Terrain.is_side_river_tile
local chunk_has_side_river = Terrain.chunk_has_side_river

--- Three seeds, so that nothing below can pass by reading one lucky row of the
--- offset table. The first is the one the offset table starts at.
local SEEDS = { 0, 1234567, 4021957120 }

--- `terrain.lua:84`, recomputed here rather than imported: a test that asks the
--- file under test what it expects proves nothing.
local river_width_half = math.floor(Config.border_river_width * 0.5)

--- The x at which the water of row `y` starts, away from the central lake --
--- `river_start` with the row where the legacy passes the column.
local function expected_start_of_row(seed, y)
    return -river_width_half - river.offset[(y + seed) % river.size]
end

--- The lake radius (`terrain.lua:82`) and the island radius (`:87`), which the
--- module keeps to itself. Only used to say where the answers below come from.
local RIVER_CIRCLE_SIZE = 39
local SPAWN_ISLAND_SIZE = 9

--- The widest a row's water can start past the band edge: `river_start` takes
--- `-river_width_half - offset`, and the offsets are a table of 0..4.
local MAX_RIVER_OFFSET = 0
for i = 0, river.size - 1 do
    local offset = river.offset[i]
    if offset and offset > MAX_RIVER_OFFSET then
        MAX_RIVER_OFFSET = offset
    end
end

--- Run `fn` against a `terrain.lua` loaded for another `border_river_width`.
---
--- `river_width_half` is read once, at load, from `config.lua` -- so the only
--- way to ask the real module about another width is to give it another config
--- and load it again. The module has no state to lose: it registers nothing and
--- writes nothing outside itself. The one thing it does touch is the grid of
--- `precomputed.biter_texture`, which it rewrites in place, so that module is
--- dropped with it and both are put back at the shipped width afterwards --
--- lunatest walks the tests with `pairs` and the others must find the file as
--- they left it, `chunk_type_at` included.
---@param width integer
---@param fn fun(terrain: table)
local function with_border_river_width(width, fn)
    local shipped = Config.border_river_width
    local function load_at(w)
        Config.border_river_width = w
        package.loaded['maps.biter_battles_v2.terrain'] = nil
        package.loaded['maps.biter_battles_v2.precomputed.biter_texture'] = nil
        return require('maps.biter_battles_v2.terrain')
    end

    local ok, err = pcall(fn, load_at(width))
    load_at(shipped)
    if not ok then
        error(err, 0)
    end
end

--- Every tile of the canonical quadrant that the side river covers but the
--- carve pass never visits, as `{ x, y, cx, cy }` rows. Empty is the property
--- the pass needs; what is in it when it is not empty is the interesting part.
---@param terrain table
---@return table[]
local function tiles_the_carve_pass_would_miss(terrain)
    local missed = {}
    for _, seed in ipairs(SEEDS) do
        for cy = -8, -1 do
            for cx = -8, -1 do
                if not terrain.chunk_has_side_river({ x = cx, y = cy }) then
                    for y = cy * 32, cy * 32 + 31 do
                        for x = cx * 32, cx * 32 + 31 do
                            if terrain.is_side_river_tile(seed, x, y) then
                                missed[#missed + 1] = { x = x, y = y, cx = cx, cy = cy, seed = seed }
                            end
                        end
                    end
                end
            end
        end
    end
    return missed
end

-- ---------------------------------------------------------------------------
-- The offset table is read at the row
-- ---------------------------------------------------------------------------

--- Away from the lake -- `|y| > river_circle_size`, where the circle cannot
--- widen the arm -- the water of a row starts exactly at the legacy river edge
--- computed for that ROW.
function test_edge_of_a_row_is_the_offset_table_read_at_y()
    for _, seed in ipairs(SEEDS) do
        for y = -400, -40 do
            local expected = expected_start_of_row(seed, y)
            lunatest.assert_false(
                is_side_river_tile(seed, expected - 1, y),
                'row ' .. y .. ' seed ' .. seed .. ': land expected at x = ' .. (expected - 1)
            )
            lunatest.assert_true(
                is_side_river_tile(seed, expected, y),
                'row ' .. y .. ' seed ' .. seed .. ': water expected at x = ' .. expected
            )
        end
    end
end

--- The same rows read at the COLUMN instead would be a different river: over any
--- stretch of the map the two disagree, which is what makes the test above a
--- test and not a tautology.
function test_reading_the_offset_table_at_x_would_be_a_different_river()
    local seed = SEEDS[2]
    local disagreements = 0
    for y = -400, -40 do
        for x = -30, -20 do
            local by_row = is_side_river_tile(seed, x, y)
            local by_column = x >= expected_start_of_row(seed, x)
            if by_row ~= by_column then
                disagreements = disagreements + 1
            end
        end
    end
    lunatest.assert_true(disagreements > 0, 'the row-indexed and column-indexed rivers are the same river')
end

-- ---------------------------------------------------------------------------
-- The shape of an arm
-- ---------------------------------------------------------------------------

--- The water of a row runs from its edge to the axis without a hole: the carve
--- pass writes the cells this predicate names and nothing fills gaps afterwards.
function test_a_row_is_a_half_line_up_to_the_axis()
    for _, seed in ipairs(SEEDS) do
        for y = -400, -1 do
            local seen_water = false
            for x = -64, -1 do
                local water = is_side_river_tile(seed, x, y)
                if water then
                    seen_water = true
                elseif seen_water then
                    -- The island is the one hole a row may have, and only on the
                    -- rows it covers.
                    lunatest.assert_true(
                        math.abs(y) <= SPAWN_ISLAND_SIZE,
                        'row ' .. y .. ' seed ' .. seed .. ': land at x = ' .. x .. ' after water'
                    )
                end
            end
            lunatest.assert_true(seen_water, 'row ' .. y .. ' seed ' .. seed .. ' has no water at all')
        end
    end
end

--- No row of any seed reaches past the lake: `river_start` is the smaller of the
--- band edge, which never passes -river_width_half - 4, and the circle, which
--- never passes -river_circle_size.
function test_the_arm_never_reaches_past_the_lake()
    for _, seed in ipairs(SEEDS) do
        for y = -400, -1 do
            for x = -80, -RIVER_CIRCLE_SIZE - 1 do
                lunatest.assert_false(
                    is_side_river_tile(seed, x, y),
                    'seed ' .. seed .. ': water at (' .. x .. ', ' .. y .. '), left of the lake'
                )
            end
        end
    end
end

--- And it does reach the lake: the row next to the axis is water from -39, the
--- far edge of the circle of radius `river_circle_size` at the middle of the
--- column, so the four arms open into the one round lake at the origin.
function test_the_row_next_to_the_axis_opens_into_the_lake()
    for _, seed in ipairs(SEEDS) do
        lunatest.assert_true(
            is_side_river_tile(seed, -RIVER_CIRCLE_SIZE, -1),
            'seed ' .. seed .. ': the lake does not reach x = ' .. -RIVER_CIRCLE_SIZE .. ' on row -1'
        )
    end
end

-- ---------------------------------------------------------------------------
-- The spectator island
-- ---------------------------------------------------------------------------

--- The island is land in this arm as it is in the legacy one: the carve pass
--- must not drown the quarter `draw_spawn_island` is about to draw.
function test_the_island_quarter_is_never_water()
    for _, seed in ipairs(SEEDS) do
        for y = -SPAWN_ISLAND_SIZE, -1 do
            for x = -SPAWN_ISLAND_SIZE, -1 do
                -- `is_within_spawn_island`: the tile CENTRE within the radius.
                local distance = math.sqrt((x + 0.5) ^ 2 + (y + 0.5) ^ 2)
                if distance <= SPAWN_ISLAND_SIZE then
                    lunatest.assert_false(
                        is_side_river_tile(seed, x, y),
                        'seed ' .. seed .. ': island tile (' .. x .. ', ' .. y .. ') carved'
                    )
                end
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- The chunk test and the tile test agree
-- ---------------------------------------------------------------------------

--- Every side-river tile of the canonical quadrant lies in a chunk the carve
--- pass visits. A chunk it missed would leave the arm interrupted for 32 tiles.
function test_every_side_river_tile_lives_in_a_carved_chunk()
    for _, seed in ipairs(SEEDS) do
        for cy = -8, -1 do
            for cx = -8, -1 do
                if not chunk_has_side_river({ x = cx, y = cy }) then
                    for y = cy * 32, cy * 32 + 31 do
                        for x = cx * 32, cx * 32 + 31 do
                            lunatest.assert_false(
                                is_side_river_tile(seed, x, y),
                                'seed '
                                    .. seed
                                    .. ': water at ('
                                    .. x
                                    .. ', '
                                    .. y
                                    .. ') in chunk ('
                                    .. cx
                                    .. ', '
                                    .. cy
                                    .. '), which the carve pass skips'
                            )
                        end
                    end
                end
            end
        end
    end
end

--- ... and every chunk it visits has some, so the predicate is not simply true.
function test_a_carved_chunk_has_water_in_it()
    local seed = SEEDS[2]
    for cy = -12, -1 do
        for cx = -12, -1 do
            if chunk_has_side_river({ x = cx, y = cy }) then
                local found = false
                for y = cy * 32, cy * 32 + 31 do
                    for x = cx * 32, cx * 32 + 31 do
                        if is_side_river_tile(seed, x, y) then
                            found = true
                        end
                    end
                end
                lunatest.assert_true(found, 'chunk (' .. cx .. ', ' .. cy .. ') is carved but holds no water')
            end
        end
    end
end

--- The carve window covers the whole arm for every `border_river_width` up to
--- 57, which is where the arm stops fitting in one chunk column.
---
--- `chunk_has_side_river` visits chunk column -1 and, on chunk row -1, column
--- -2. A row's water starts at `-floor(width/2) - offset` with the offset never
--- past 4, so the arm lives in column -1 exactly while
--- `floor(width/2) + 4 <= 32`. `config.lua:18` allows values up to 64, and this
--- is what those cost.
function test_the_carve_window_covers_the_arm_only_while_the_arm_fits_one_chunk()
    for _, width in ipairs({ 44, 52, 56 }) do
        lunatest.assert_true(
            math.floor(width * 0.5) + MAX_RIVER_OFFSET <= 32,
            'width ' .. width .. ' should fit chunk column -1'
        )
        with_border_river_width(width, function(terrain)
            local missed = tiles_the_carve_pass_would_miss(terrain)
            local first = missed[1]
            lunatest.assert_equal(
                0,
                #missed,
                'width '
                    .. width
                    .. ': '
                    .. #missed
                    .. ' tiles of the arm are never carved, first ('
                    .. (first and first.x or 0)
                    .. ', '
                    .. (first and first.y or 0)
                    .. ')'
            )
        end)
    end
end

--- ... and past it the arm IS narrowed, exactly as the legacy front river is.
---
--- The window is `chunk_type_at`'s river rows transposed, so
--- it inherits the legacy generator's own bound: at 58 and at 64 the side arm
--- spills into chunk column -2 for every row, and the front river spills into
--- chunk row -2 for every column in the same places -- the chunk the legacy
--- generator does not visit either. A shared, pre-existing limit of
--- `border_river_width`, not something the transposition introduced; pinned so
--- that a change that raises the width is told what it has to widen first.
function test_past_that_width_the_side_arm_and_the_legacy_river_are_narrowed_together()
    for _, width in ipairs({ 58, 64 }) do
        lunatest.assert_false(
            math.floor(width * 0.5) + MAX_RIVER_OFFSET <= 32,
            'width ' .. width .. ' should not fit chunk column -1'
        )
        with_border_river_width(width, function(terrain)
            local missed = tiles_the_carve_pass_would_miss(terrain)
            lunatest.assert_true(#missed > 0, 'width ' .. width .. ': the arm still fits, the bound moved')

            local disagreements = 0
            for _, tile in ipairs(missed) do
                lunatest.assert_equal(-2, tile.cx, 'width ' .. width .. ': a miss outside chunk column -2')
                -- The transposition: the side-river tile (x, y) is the legacy
                -- front-river tile (y, x), and it sits in chunk (cy, cx) --
                -- which the legacy generator classifies as river or not.
                if chunk_type_at({ x = tile.cy, y = tile.cx }) == chunk_type.river then
                    disagreements = disagreements + 1
                end
            end
            lunatest.assert_equal(
                0,
                disagreements,
                'width ' .. width .. ': the legacy generator would have visited the chunk the carve pass skips'
            )
        end)
    end
end

--- The chunk test IS the legacy river-chunk test with its coordinates swapped.
---
--- `chunk_type_at` and `chunk_type` are globals of `terrain.lua` (they are
--- missing a `local`); a commit that gives them one has to
--- give this test the same treatment.
function test_the_chunk_test_is_the_legacy_one_transposed()
    for cy = -12, -1 do
        for cx = -12, -1 do
            local legacy_transposed = chunk_type_at({ x = cy, y = cx }) == chunk_type.river
            lunatest.assert_equal(
                legacy_transposed,
                chunk_has_side_river({ x = cx, y = cy }),
                'chunk (' .. cx .. ', ' .. cy .. ')'
            )
        end
    end
end

lunatest.run()
