---@diagnostic disable
--
-- Pins the POSITION -> TEAM consumers: the pure questions the
-- scenario asks about a point of the map, once the four-square layout exists.
--
--   * `Terrain.build_denied` / `Terrain.deconstruction_denied` -- "may this
--     force act here", for construction robots, ghosts and deconstruction
--     orders. The two are NOT the same rule with two teams and that is the whole
--     reason they are two functions: the build rule stops a team half a river
--     width BEFORE the river, the deconstruction rule only half a river width
--     PAST it. Both expressions are today's, and the tests below say so in
--     numbers so that a later tidy-up cannot quietly align them;
--   * `Terrain.is_cross4_river_tile` -- the landfill mask of the cross. It has
--     to be the canonical mask turned, tile for tile, because the terrain of a
--     quadrant IS the canonical quadrant cloned with `rotate_tile`. Unrotating a
--     POSITION instead of a TILE answers for the tile next door on the axis that
--     gets negated, so the test walks whole quadrants rather than sampling;
--   * `Functions.is_roughly_biter_area`, `Functions.is_turret_creep_area` and
--     `Functions.is_river_landfill_band` -- the biter wedge, the fold that the
--     turret-creep rule probes it with (two independent `if`s today, so the
--     southern half is probed 200 tiles deeper than the northern one: an
--     asymmetry this suite pins rather than fixes), and the band along a river
--     where a biter is let through without landfilling.
--
-- Neither module loads outside Factorio by itself: `terrain.lua` reaches
-- `script` and `Global.register` through `ai_targets` and `session_data`, and
-- `functions.lua` pulls in the GUI and the server bridge unless `storage._TEST`
-- is set -- which it must NOT be here, since that same flag is what leaves
-- `Config` nil, and `Config` is exactly what the biter wedge is made of. The
-- stubs below are the whole of what it takes; both files are then the real ones.

local lunatest = require('lunatest')

storage = {}

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
package.loaded['utils.ui.closable_frame'] = {}
package.loaded['utils.gui'] = setmetatable({}, {
    __index = function()
        return function() end
    end,
})
package.loaded['utils.server'] = setmetatable({}, {
    __index = function()
        return function() end
    end,
})
package.loaded['utils.simplex_noise'] = {
    d2 = function() end,
}

local Terrain = require('maps.biter_battles_v2.terrain')
local Functions = require('maps.biter_battles_v2.functions')
local Layout = require('maps.biter_battles_v2.layout')
local Teams = require('maps.biter_battles_v2.teams')
local Config = require('maps.biter_battles_v2.config')
local river = require('maps.biter_battles_v2.precomputed.river')

--- Ask for `count` teams and start the round.
local function round_of(count)
    lunatest.assert_true(Teams.set_next_count(count), 'set_next_count(' .. tostring(count) .. ')')
    return Teams.begin_round()
end

--- Recomputed here rather than imported: a test that asks the file under test
--- what it expects proves nothing. `terrain.lua:85` and `:82`, `:87`.
local HALF_RIVER = Config.border_river_width / 2
local RIVER_WIDTH_HALF = math.floor(Config.border_river_width * 0.5)
local RIVER_CIRCLE_SIZE = 39
local SPAWN_ISLAND_SIZE = 9

--- Three seeds, so that nothing below can pass by reading one lucky row of the
--- offset table.
local SEEDS = { 0, 1234567, 4021957120 }

--- The legacy front river, `terrain.lua:307-318 is_horizontal_border_river`,
--- written out again: the central lake, or the offset table read at the column.
local function legacy_front_river(seed, x, y)
    if math.sqrt((x + 0.5) ^ 2 + (y + 0.5) ^ 2) < RIVER_CIRCLE_SIZE then
        return true
    end
    local offset = river.offset[(x + seed) % river.size]
    return -(y + offset) <= RIVER_WIDTH_HALF
end

--- Today's biter wedge in the canonical frame: `functions.lua:356-360`.
local function canonical_wedge(x, y)
    return y <= Config.bitera_area_distance * -1 - math.abs(x) * Config.biter_area_slope
end

--- One point per quadrant, all at the same distance from the origin, so that a
--- rule that only looks at signs and a rule that looks at distances are both
--- exercised. Index i is quadrant i - 1.
local QUADRANT_POINTS = {
    { x = -300, y = -300 },
    { x = 300, y = -300 },
    { x = 300, y = 300 },
    { x = -300, y = 300 },
}

--- Forces that are not a team of the round and must never be restricted: the
--- ones that actually place entities on the map plus a roster team sitting out.
local function non_team_forces()
    return { 'spectator', 'player', 'neutral', 'north_biters', 'enemy' }
end

function setup()
    storage = {}
end

-- ---------------------------------------------------------------------------
-- Two teams: the two rules stay different, and stay today's
-- ---------------------------------------------------------------------------

--- The build rule: a team is refused from half a river width BEFORE the river
--- onwards, i.e. it may not build on the last 22 tiles of its OWN bank.
function test_two_team_build_stops_a_team_short_of_its_own_bank()
    round_of(2)
    local first, second = Teams.all()[1], Teams.all()[2]

    for _, x in ipairs({ -1000, -1, 0, 1, 1000 }) do
        lunatest.assert_true(Terrain.build_denied(first, { x = x, y = -HALF_RIVER }), 'first team at its own bank')
        lunatest.assert_true(Terrain.build_denied(first, { x = x, y = 0 }), 'first team at the river')
        lunatest.assert_true(Terrain.build_denied(first, { x = x, y = 1000 }), 'first team deep in enemy land')
        lunatest.assert_false(
            Terrain.build_denied(first, { x = x, y = -HALF_RIVER - 0.001 }),
            'first team just past its own bank'
        )
        lunatest.assert_false(Terrain.build_denied(first, { x = x, y = -1000 }), 'first team at home')

        lunatest.assert_true(Terrain.build_denied(second, { x = x, y = HALF_RIVER }), 'second team at its own bank')
        lunatest.assert_true(Terrain.build_denied(second, { x = x, y = 0 }), 'second team at the river')
        lunatest.assert_true(Terrain.build_denied(second, { x = x, y = -1000 }), 'second team deep in enemy land')
        lunatest.assert_false(
            Terrain.build_denied(second, { x = x, y = HALF_RIVER + 0.001 }),
            'second team just past its own bank'
        )
        lunatest.assert_false(Terrain.build_denied(second, { x = x, y = 1000 }), 'second team at home')
    end
end

--- The deconstruction rule is the other one: it lets a team order deconstruction
--- across the whole river and half a river width up the ENEMY bank. The two
--- rules disagree about the sign, and that disagreement is today's behaviour.
function test_two_team_deconstruction_reaches_half_a_river_width_onto_the_enemy_bank()
    round_of(2)
    local first, second = Teams.all()[1], Teams.all()[2]

    for _, x in ipairs({ -1000, -1, 0, 1, 1000 }) do
        lunatest.assert_false(Terrain.deconstruction_denied(first, { x = x, y = -1000 }), 'first team at home')
        lunatest.assert_false(Terrain.deconstruction_denied(first, { x = x, y = 0 }), 'first team at the river')
        lunatest.assert_false(
            Terrain.deconstruction_denied(first, { x = x, y = HALF_RIVER }),
            'first team on the enemy bank, still allowed'
        )
        lunatest.assert_true(
            Terrain.deconstruction_denied(first, { x = x, y = HALF_RIVER + 0.001 }),
            'first team past the enemy bank'
        )

        lunatest.assert_false(Terrain.deconstruction_denied(second, { x = x, y = 1000 }), 'second team at home')
        lunatest.assert_false(Terrain.deconstruction_denied(second, { x = x, y = 0 }), 'second team at the river')
        lunatest.assert_false(
            Terrain.deconstruction_denied(second, { x = x, y = -HALF_RIVER }),
            'second team on the enemy bank, still allowed'
        )
        lunatest.assert_true(
            Terrain.deconstruction_denied(second, { x = x, y = -HALF_RIVER - 0.001 }),
            'second team past the enemy bank'
        )
    end

    -- And the two rules really do disagree, at a point each answers about.
    local probe = { x = 0, y = 10 }
    lunatest.assert_true(Terrain.build_denied(first, probe), 'the build rule stops the first team here')
    lunatest.assert_false(Terrain.deconstruction_denied(first, probe), 'the deconstruction rule does not')
end

--- A force that is not one of the two teams has no entry in the legacy table and
--- is not restricted anywhere; neither rule may invent one for it.
function test_two_teams_restrict_nobody_but_the_two_teams()
    round_of(2)
    for _, force in ipairs(non_team_forces()) do
        for _, y in ipairs({ -1000, -HALF_RIVER, 0, HALF_RIVER, 1000 }) do
            lunatest.assert_false(Terrain.build_denied(force, { x = 0, y = y }), force .. ' build at y = ' .. y)
            lunatest.assert_false(
                Terrain.deconstruction_denied(force, { x = 0, y = y }),
                force .. ' deconstruction at y = ' .. y
            )
        end
    end
end

-- ---------------------------------------------------------------------------
-- The cross: your own quadrant and nothing else
-- ---------------------------------------------------------------------------

function test_four_teams_act_in_their_own_quadrant_only()
    round_of(4)
    for i, team in ipairs(Teams.all()) do
        for j, point in ipairs(QUADRANT_POINTS) do
            local own = i == j
            local what = team .. ' in quadrant ' .. (j - 1)
            lunatest.assert_equal(not own, Terrain.build_denied(team, point), what .. ' build')
            lunatest.assert_equal(not own, Terrain.deconstruction_denied(team, point), what .. ' deconstruction')
        end
    end
end

--- Today's bands, turned into every square. Building: the last
--- half a river width of BOTH of a team's banks is denied, as `y >= -h` denies
--- north its own bank today -- and so is the team's quarter of the spectator
--- island. Deconstruction: allowed on both banks, over both rivers and half a
--- river width past either axis, as `y > h` lets north reach across today.
function test_the_cross_keeps_todays_band_along_both_rivers()
    round_of(4)
    for _, team in ipairs(Teams.all()) do
        local k = Teams.k_of(team)
        local function at(cx, cy)
            local x, y = Layout.rotate_position(k, cx, cy)
            return { x = x, y = y }, team .. ' at canonical ' .. cx .. ',' .. cy
        end
        -- inside the band of either arm: no building, deconstruction allowed
        for _, d in ipairs({ 0.001, 1, HALF_RIVER - 0.001, HALF_RIVER }) do
            for _, canonical in ipairs({ { -d, -d }, { -d, -500 }, { -500, -d } }) do
                local p, where = at(canonical[1], canonical[2])
                lunatest.assert_equal(k, Layout.quadrant_of_position(p.x, p.y), where .. ' is in its own quadrant')
                lunatest.assert_true(Terrain.build_denied(team, p), where .. ' build (band)')
                lunatest.assert_false(Terrain.deconstruction_denied(team, p), where .. ' deconstruction (band)')
            end
        end
        -- the island quarter of the square
        local island, where = at(-SPAWN_ISLAND_SIZE / 2, -SPAWN_ISLAND_SIZE / 2)
        lunatest.assert_true(Terrain.build_denied(team, island), where .. ' island')
        -- past the band on both axes: both allowed
        for _, canonical in ipairs({ { -HALF_RIVER - 1, -HALF_RIVER - 1 }, { -30, -30 }, { -500, -30 }, { -30, -500 } }) do
            local p, where2 = at(canonical[1], canonical[2])
            lunatest.assert_false(Terrain.build_denied(team, p), where2 .. ' build (free land)')
            lunatest.assert_false(Terrain.deconstruction_denied(team, p), where2 .. ' deconstruction (free land)')
        end
        -- across either river: deconstruction reaches half a river width up the
        -- neighbours' banks and no further; building never
        for _, canonical in ipairs({ { HALF_RIVER, -300 }, { -300, HALF_RIVER }, { 1, -300 }, { -300, 1 } }) do
            local p, where3 = at(canonical[1], canonical[2])
            lunatest.assert_true(Terrain.build_denied(team, p), where3 .. ' build (across)')
            lunatest.assert_false(Terrain.deconstruction_denied(team, p), where3 .. ' deconstruction (reach)')
        end
        for _, canonical in ipairs({
            { HALF_RIVER + 0.001, -300 },
            { -300, HALF_RIVER + 0.001 },
            { 300, -300 },
            { 300, 300 },
        }) do
            local p, where4 = at(canonical[1], canonical[2])
            lunatest.assert_true(Terrain.build_denied(team, p), where4 .. ' build (beyond)')
            lunatest.assert_true(Terrain.deconstruction_denied(team, p), where4 .. ' deconstruction (beyond)')
        end
    end
end

--- Three teams: the closed quadrant belongs to nobody, so nobody may reach into
--- it -- and the three that play keep their own.
function test_three_teams_close_the_fourth_quadrant_to_everyone()
    round_of(3)
    lunatest.assert_true(Layout.is_closed_quadrant(3), 'the fourth quadrant is closed')

    for i, team in ipairs(Teams.all()) do
        lunatest.assert_false(Terrain.build_denied(team, QUADRANT_POINTS[i]), team .. ' builds at home')
        lunatest.assert_true(Terrain.build_denied(team, QUADRANT_POINTS[4]), team .. ' cannot build in the closed one')
        lunatest.assert_true(
            Terrain.deconstruction_denied(team, QUADRANT_POINTS[4]),
            team .. ' cannot deconstruct in the closed one'
        )
    end
end

--- A force that is not playing is not restricted on the cross either -- neither
--- the spectators nor the fourth team of a three-team round.
function test_the_cross_restricts_nobody_but_the_teams_of_the_round()
    round_of(3)
    local forces = non_team_forces()
    forces[#forces + 1] = Teams.roster()[4]

    for _, force in ipairs(forces) do
        for _, point in ipairs(QUADRANT_POINTS) do
            lunatest.assert_false(Terrain.build_denied(force, point), force .. ' build')
            lunatest.assert_false(Terrain.deconstruction_denied(force, point), force .. ' deconstruction')
        end
    end
end

-- ---------------------------------------------------------------------------
-- The landfill mask of the cross
-- ---------------------------------------------------------------------------

--- In the canonical quadrant the mask is exactly "front river or side river",
--- with the front river recomputed here from the offset table and the config.
function test_the_canonical_quadrant_is_the_two_rivers_and_nothing_else()
    round_of(4)
    for _, seed in ipairs(SEEDS) do
        for y = -70, -1 do
            for x = -70, -1 do
                local expected = legacy_front_river(seed, x, y) or Terrain.is_side_river_tile(seed, x, y)
                lunatest.assert_equal(
                    expected,
                    Terrain.is_cross4_river_tile(seed, x, y),
                    'seed ' .. seed .. ' tile ' .. x .. ',' .. y
                )
            end
        end
    end
end

--- The mask of a quadrant is the canonical mask TURNED, tile for tile. This is
--- the test that says `unrotate_tile` and not `unrotate_position`: the two
--- differ by one tile on the axis that gets negated, so a whole edge of the
--- river would answer for its neighbour.
function test_every_quadrant_carries_the_canonical_mask_turned()
    round_of(4)
    for _, seed in ipairs(SEEDS) do
        for cy = -80, -1 do
            for cx = -80, -1 do
                local canonical = Terrain.is_cross4_river_tile(seed, cx, cy)
                for k = 1, 3 do
                    local x, y = Layout.rotate_tile(k, cx, cy)
                    lunatest.assert_equal(
                        canonical,
                        Terrain.is_cross4_river_tile(seed, x, y),
                        'seed ' .. seed .. ' canonical tile ' .. cx .. ',' .. cy .. ' turned ' .. k
                    )
                end
            end
        end
    end
end

--- The lake at the origin and the spectator island inside it take no landfill,
--- in any quadrant -- the island is protected today by the very same lake test.
function test_the_lake_and_the_island_take_no_landfill()
    round_of(4)
    local seed = SEEDS[2]
    for y = -RIVER_CIRCLE_SIZE, RIVER_CIRCLE_SIZE - 1 do
        for x = -RIVER_CIRCLE_SIZE, RIVER_CIRCLE_SIZE - 1 do
            if math.sqrt((x + 0.5) ^ 2 + (y + 0.5) ^ 2) < RIVER_CIRCLE_SIZE then
                lunatest.assert_true(Terrain.is_cross4_river_tile(seed, x, y), 'lake tile ' .. x .. ',' .. y)
            end
        end
    end
    for y = -SPAWN_ISLAND_SIZE, SPAWN_ISLAND_SIZE - 1 do
        for x = -SPAWN_ISLAND_SIZE, SPAWN_ISLAND_SIZE - 1 do
            lunatest.assert_true(Terrain.is_cross4_river_tile(seed, x, y), 'island tile ' .. x .. ',' .. y)
        end
    end
end

--- ... and the mask is not simply true: the free land of every quadrant takes
--- landfill, or the map would be unplayable.
function test_the_free_land_of_a_quadrant_takes_landfill()
    round_of(4)
    for _, seed in ipairs(SEEDS) do
        for k = 0, 3 do
            for _, canonical in ipairs({ { -200, -200 }, { -64, -300 }, { -300, -64 } }) do
                local x, y = Layout.rotate_tile(k, canonical[1], canonical[2])
                lunatest.assert_false(
                    Terrain.is_cross4_river_tile(seed, x, y),
                    'seed ' .. seed .. ': land expected at ' .. x .. ',' .. y
                )
            end
        end
    end
end

--- A closed quadrant is water from end to end, and closing it changes nothing
--- anywhere else.
function test_a_closed_quadrant_takes_no_landfill_at_all()
    local seed = SEEDS[3]

    round_of(4)
    local open = {}
    for i, canonical in ipairs({ { -200, -200 }, { -64, -300 }, { -300, -64 }, { -20, -20 } }) do
        open[i] = Terrain.is_cross4_river_tile(seed, canonical[1], canonical[2])
    end

    round_of(3)
    for i, canonical in ipairs({ { -200, -200 }, { -64, -300 }, { -300, -64 }, { -20, -20 } }) do
        lunatest.assert_equal(
            open[i],
            Terrain.is_cross4_river_tile(seed, canonical[1], canonical[2]),
            'the canonical quadrant is unchanged at ' .. canonical[1] .. ',' .. canonical[2]
        )
        local x, y = Layout.rotate_tile(3, canonical[1], canonical[2])
        lunatest.assert_true(
            Terrain.is_cross4_river_tile(seed, x, y),
            'the closed quadrant is water at ' .. x .. ',' .. y
        )
    end
end

-- ---------------------------------------------------------------------------
-- The biter wedge and the turret-creep fold
-- ---------------------------------------------------------------------------

function test_two_team_biter_area_is_todays_north_wedge()
    round_of(2)
    for _, x in ipairs({ 0, -100, 100, -2000, 2000 }) do
        local edge = Config.bitera_area_distance * -1 - math.abs(x) * Config.biter_area_slope
        lunatest.assert_true(Functions.is_roughly_biter_area({ x = x, y = edge }), 'on the edge at x = ' .. x)
        lunatest.assert_true(Functions.is_roughly_biter_area({ x = x, y = edge - 1 }), 'beyond the edge at x = ' .. x)
        lunatest.assert_false(Functions.is_roughly_biter_area({ x = x, y = edge + 1 }), 'short of it at x = ' .. x)
        -- The southern half is never biter area, however deep it goes: the
        -- expression only knows the north wedge.
        lunatest.assert_false(Functions.is_roughly_biter_area({ x = x, y = -edge }), 'mirrored, at x = ' .. x)
    end
end

--- The fold of `no_turret_creep`, exactly as it is today: `y < 0` is probed 100
--- tiles further out, `y > 0` is mirrored AND then pushed another 100 (two
--- independent `if`s, not an if/else), and `y == 0` is probed where it lies.
function test_two_team_turret_creep_probes_the_south_two_hundred_tiles_deeper()
    round_of(2)
    for _, x in ipairs({ 0, -100, 100, -2000, 2000 }) do
        for _, y in ipairs({ -3000, -600, -1, 0, 1, 600, 3000 }) do
            local folded
            if y > 0 then
                folded = -y - 200
            elseif y < 0 then
                folded = y - 100
            else
                folded = 0
            end
            lunatest.assert_equal(
                canonical_wedge(x, folded),
                Functions.is_turret_creep_area({ x = x, y = y }),
                'the creep probe at ' .. x .. ',' .. y
            )
        end
    end

    -- Read off the asymmetry itself, so that "fixing" it fails here: at the very
    -- same distance from the river the southern point is already treated as
    -- biter area and the northern one is not.
    local d = Config.bitera_area_distance - 150
    lunatest.assert_false(Functions.is_turret_creep_area({ x = 0, y = -d }), 'north, probed 100 tiles out')
    lunatest.assert_true(Functions.is_turret_creep_area({ x = 0, y = d }), 'south, probed 200 tiles out')
end

--- On the cross every wedge answers for itself: a canonical point turned into a
--- quadrant gives the canonical answer back.
function test_four_team_biter_area_is_the_same_wedge_turned()
    round_of(4)
    for k = 0, 3 do
        -- Strictly inside the quadrant: a canonical sample ON an axis belongs to
        -- the next quadrant round, which is a different question.
        for _, canonical in ipairs({ { -1, -2000 }, { -100, -600 }, { -100, -500 }, { -50, -100 } }) do
            local x, y = Layout.rotate_position(k, canonical[1], canonical[2])
            lunatest.assert_equal(
                canonical_wedge(canonical[1], canonical[2]),
                Functions.is_roughly_biter_area({ x = x, y = y }),
                'quadrant ' .. k .. ': ' .. canonical[1] .. ',' .. canonical[2] .. ' -> ' .. x .. ',' .. y
            )
        end
    end
end

--- ... and the creep probe folds every quadrant the same 100 tiles out, because
--- a canonical point never has a positive y.
function test_four_team_turret_creep_probes_every_wedge_the_same_way()
    round_of(4)
    for k = 0, 3 do
        for _, canonical in ipairs({ { -1, -2000 }, { -100, -600 }, { -100, -400 }, { -50, -100 } }) do
            local x, y = Layout.rotate_position(k, canonical[1], canonical[2])
            lunatest.assert_equal(
                canonical_wedge(canonical[1], canonical[2] - 100),
                Functions.is_turret_creep_area({ x = x, y = y }),
                'quadrant ' .. k .. ': ' .. canonical[1] .. ',' .. canonical[2] .. ' -> ' .. x .. ',' .. y
            )
        end
    end
end

--- Nobody's biters live in the closed quadrant, so it is neither biter area nor
--- ground the creep rule protects.
function test_the_closed_quadrant_has_no_biters_and_no_creep_rule()
    round_of(3)
    for _, canonical in ipairs({ { -1, -2000 }, { -100, -3000 }, { -500, -5000 } }) do
        lunatest.assert_true(
            Functions.is_roughly_biter_area({ x = canonical[1], y = canonical[2] }),
            'the very same point of a played quadrant is biter area'
        )
        local x, y = Layout.rotate_position(3, canonical[1], canonical[2])
        lunatest.assert_equal(3, Layout.quadrant_of_position(x, y), 'the sample lands in the closed quadrant')
        lunatest.assert_false(Functions.is_roughly_biter_area({ x = x, y = y }), 'the closed one is not')
        lunatest.assert_false(Functions.is_turret_creep_area({ x = x, y = y }), 'and has no creep rule')
    end
end

-- ---------------------------------------------------------------------------
-- The band a biter may not landfill
-- ---------------------------------------------------------------------------

function test_two_teams_keep_the_band_along_the_one_river()
    round_of(2)
    for _, x in ipairs({ 0, -4, 4, -1000, 1000 }) do
        lunatest.assert_true(Functions.is_river_landfill_band({ x = x, y = 0 }), 'on the river at x = ' .. x)
        lunatest.assert_true(Functions.is_river_landfill_band({ x = x, y = 7.99 }), 'inside the band at x = ' .. x)
        lunatest.assert_true(Functions.is_river_landfill_band({ x = x, y = -7.99 }), 'inside the band at x = ' .. x)
        -- The vertical axis means nothing on the two-team map, even at x = 0.
        lunatest.assert_false(Functions.is_river_landfill_band({ x = x, y = 8 }), 'outside the band at x = ' .. x)
        lunatest.assert_false(Functions.is_river_landfill_band({ x = x, y = -8 }), 'outside the band at x = ' .. x)
    end
end

function test_the_cross_adds_the_band_along_the_second_river()
    round_of(4)
    for _, v in ipairs({ 0, -4, 4, -7.99, 7.99 }) do
        for _, far in ipairs({ -1000, -8, 8, 1000 }) do
            lunatest.assert_true(Functions.is_river_landfill_band({ x = far, y = v }), 'the horizontal arm')
            lunatest.assert_true(Functions.is_river_landfill_band({ x = v, y = far }), 'the vertical arm')
        end
    end
    for _, x in ipairs({ -1000, -8, 8, 1000 }) do
        for _, y in ipairs({ -1000, -8, 8, 1000 }) do
            lunatest.assert_false(Functions.is_river_landfill_band({ x = x, y = y }), 'clear of both arms')
        end
    end
end

lunatest.run()
