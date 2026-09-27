---@diagnostic disable
--
-- Pins `maps/biter_battles_v2/strike_geometry.lua`, the wave geometry of the
-- four-square map: where a classic wave
-- forms up on its way in, and where an advanced wave swings out to before it
-- charges.
--
-- The two-team map does not reach any of this -- `ai_strikes.lua` branches on
-- `Teams.layout()` and keeps its own fold -- so nothing here can move today's
-- game. What it is here to catch is everything the four-square map adds:
--
--   * the PINWHEEL. Every answer is computed in the canonical frame and turned
--     back, so the answer for team k has to be the exact rotation of the answer
--     the canonical team gets from the rotated question. Exact, not nearly: the
--     turns swap and negate components and never multiply by a cosine, so a
--     single `math.random` script feeding four teams must produce four positions
--     that agree bit for bit. If it ever stops being exact, the four zones are no
--     longer the same zone and the map is not fair;
--   * the SECOND RIVER. A zone is a quadrant now, not a half plane. Three of the
--     five classic attack vectors lean towards the side river, and the arc an
--     advanced wave may strike from is cut by two banks instead of one. Nothing
--     either function produces may land in the neighbour's zone or in the water;
--   * the EMPTY ARC, which the legacy shape cannot produce and therefore does
--     not handle: `ai_strikes.lua:142-143` would divide by zero and call
--     `math.random(0, negative)`. Two boundaries can leave nothing, or leave a
--     sliver too short to draw a point on, and both must answer nil -- the
--     callers read that as "charge in with no flank";
--   * the ARC SET itself, which is the only genuinely new piece of arithmetic:
--     an arc can wrap past 2*pi, so the `max`/`min` the legacy intersects with
--     is not enough, and the intersection of two arcs on a circle can be two
--     separate pieces.
--
-- `math.random` is captured by the module at load, exactly as `ai_strikes.lua`
-- captures it, so the stub below is installed BEFORE the require. It only
-- answers the draws a test has queued and hands everything else to the real
-- generator, so lunatest's own machinery is unaffected.

local lunatest = require('lunatest')

storage = { ['_TEST'] = true }

--- Values the module's next `math.random` calls return. A queued entry may be a
--- number, or a function of the call's own bounds -- `lowest` and `highest` pick
--- the ends of a range whose size the test does not want to know.
local queued_draws = {}
local draws_taken = 0
local real_random = math.random

math.random = function(lower, upper)
    if #queued_draws == 0 then
        return real_random(lower, upper)
    end
    draws_taken = draws_taken + 1
    local value = table.remove(queued_draws, 1)
    if type(value) == 'function' then
        return value(lower, upper)
    end
    return value
end

local Geometry = require('maps.biter_battles_v2.strike_geometry')
local Layout = require('maps.biter_battles_v2.layout')
local Teams = require('maps.biter_battles_v2.teams')

local HALF_RIVER = 22 -- `bb_config.border_river_width / 2`
local WAYPOINT_LIMIT = -(HALF_RIVER + Geometry.WAYPOINT_RIVER_CLEARANCE)

--- The five classic attack vectors of the canonical zone, built by the float
--- loop of `ai_strikes.lua:35-41` -- rebuilt here rather than imported because
--- that file reaches for `defines` and the event multiplexer at load.
local ATTACK_VECTORS = {}
for p = 0.3, 0.71, 0.1 do
    local a = math.pi * p
    ATTACK_VECTORS[#ATTACK_VECTORS + 1] = { 512 * math.cos(a), 512 * math.sin(a) * -1 }
end

--- Ask for `count` teams and start the round.
local function round_of(count)
    lunatest.assert_true(Teams.set_next_count(count), 'set_next_count(' .. tostring(count) .. ')')
    Teams.begin_round()
end

--- Run `body` with `draws` queued for the module to take.
local function with_draws(draws, body)
    queued_draws = {}
    for i = 1, #draws do
        queued_draws[i] = draws[i]
    end
    draws_taken = 0
    local result_x, result_y = body()
    queued_draws = {}
    return result_x, result_y
end

local function lowest(lower, _)
    return lower
end

local function highest(_, upper)
    return upper
end

--- Exact equality, which is what the rotations owe us: a tolerance would hide
--- the day the transform starts going through a cosine.
local function assert_exactly(what, expected, actual)
    lunatest.assert_not_nil(actual, what .. ' (nil)')
    lunatest.assert_true(expected == actual, string.format('%s: expected %.17g, got %.17g', what, expected, actual))
end

local function assert_at_most(what, limit, value)
    lunatest.assert_not_nil(value, what .. ' (nil)')
    lunatest.assert_true(value <= limit, string.format('%s: %.17g is not at most %.17g', what, value, limit))
end

--- Both components of a canonical position at once.
local function canonical_of(team, x, y)
    return Layout.to_canonical(team, x, y)
end

function setup()
    storage = { ['_TEST'] = true }
    queued_draws = {}
    draws_taken = 0
end

-- ---------------------------------------------------------------------------
-- Arcs of a circle
-- ---------------------------------------------------------------------------

function test_intersecting_with_the_whole_circle_changes_nothing()
    local straight = { { start = 0.5, finish = 2.5 } }
    local wrapping = { { start = 2.5, finish = 2.5 + math.pi } } -- past pi, so the seam is inside it

    local kept = Geometry.intersect_arcs(straight, Geometry.full_circle())
    lunatest.assert_equal(1, #kept, 'one piece')
    assert_exactly('start', 0.5, kept[1].start)
    assert_exactly('finish', 2.5, kept[1].finish)

    -- The wrapping arc is cut at the seam, so it may come back as two pieces --
    -- but not one radian of it may be lost, whichever side it is written on.
    local wrapped = Geometry.intersect_arcs(wrapping, Geometry.full_circle())
    lunatest.assert_equal(math.pi, Geometry.total_angle(wrapped), 'the whole arc survives')
end

function test_arcs_that_do_not_meet_intersect_to_nothing()
    local empty = Geometry.intersect_arcs({ { start = 0, finish = 1 } }, { { start = 1.5, finish = 2 } })
    lunatest.assert_equal(0, #empty, 'no pieces')
    lunatest.assert_equal(0, Geometry.total_angle(empty), 'no angle')
    lunatest.assert_nil(Geometry.angle_at(empty, 0), 'and no point to pick')

    -- Touching at a single angle is not an overlap either: a zero-length piece
    -- would divide by zero one line later.
    local touching = Geometry.intersect_arcs({ { start = 0, finish = 1 } }, { { start = 1, finish = 2 } })
    lunatest.assert_equal(0, #touching, 'touching is not overlapping')
end

function test_an_arc_that_wraps_meets_a_piece_on_either_side_of_the_seam()
    -- [2.5, 2.5 + 2] runs past pi and comes back at -(2*pi - 4.5); a piece
    -- written at -3 is inside it and the `max`/`min` of the legacy code would
    -- never find it.
    local wrapping = { { start = 2.5, finish = 4.5 } }

    local before_the_seam = Geometry.intersect_arcs(wrapping, { { start = 2.6, finish = 3.0 } })
    lunatest.assert_equal(1, #before_the_seam, 'one piece before the seam')
    lunatest.assert_true(math.abs(0.4 - Geometry.total_angle(before_the_seam)) < 1e-12, 'its whole length')

    local after_the_seam = Geometry.intersect_arcs(wrapping, { { start = -3.0, finish = -2.6 } })
    lunatest.assert_equal(1, #after_the_seam, 'one piece after the seam')
    lunatest.assert_true(
        math.abs(0.4 - Geometry.total_angle(after_the_seam)) < 1e-12,
        'its whole length too, reached across the seam'
    )

    -- And an intersection that really is two pieces stays two pieces: a cut that
    -- keeps both ends of a wrapping arc and drops its middle.
    local both_ends = Geometry.intersect_arcs(wrapping, { { start = -3.0, finish = 2.8 } })
    lunatest.assert_equal(2, #both_ends, 'two pieces')
    lunatest.assert_true(both_ends[1].start < both_ends[2].start, 'in order of their start')
end

function test_the_point_at_an_arc_length_walks_the_pieces_in_order()
    local set = { { start = -1, finish = -0.5 }, { start = 1, finish = 2 } }

    assert_exactly('the very start', -1, Geometry.angle_at(set, 0))
    assert_exactly('inside the first piece', -0.75, Geometry.angle_at(set, 0.25))
    assert_exactly('the end of the first piece', -0.5, Geometry.angle_at(set, 0.5))
    assert_exactly('the hole is stepped over', 1.25, Geometry.angle_at(set, 0.75))
    assert_exactly('the very end', 2, Geometry.angle_at(set, Geometry.total_angle(set)))
    assert_exactly('and past the end is the end', 2, Geometry.angle_at(set, 99))
    lunatest.assert_equal(1.5, Geometry.total_angle(set), 'total angle')
end

function test_a_boundary_that_misses_the_circle_keeps_it_whole_or_takes_it_all()
    -- The centre is further inside the allowed half plane than the radius: the
    -- boundary cannot reach the circle at all.
    lunatest.assert_equal(2 * math.pi, Geometry.total_angle(Geometry.half_plane_arcs(100, 0, 1, 100)), 'whole')
    -- ... and further outside it: nothing of the circle is allowed.
    lunatest.assert_equal(0, #Geometry.half_plane_arcs(100, 0, 1, -100), 'nothing')
    lunatest.assert_equal(0, #Geometry.half_plane_arcs(100, -1, 0, -101), 'nothing, the other bank')
end

function test_a_boundary_arc_is_the_side_its_normal_points_at()
    local radius = 100
    for _, boundary in ipairs({
        { a = 0, b = 1, c = 30 }, -- y >= -30, the main river seen from 30 tiles inside
        { a = -1, b = 0, c = 10 }, -- x <= 10, the side river
        { a = 0, b = 1, c = -40 }, -- the target sits in the water: y >= 40
    }) do
        local set = Geometry.half_plane_arcs(radius, boundary.a, boundary.b, boundary.c)
        local total = Geometry.total_angle(set)
        lunatest.assert_true(total > 0, 'the boundary leaves something')
        for step = 0, 16 do
            local angle = Geometry.angle_at(set, total * step / 16)
            local x = radius * math.cos(angle)
            local y = radius * math.sin(angle)
            lunatest.assert_true(
                boundary.a * x + boundary.b * y + boundary.c >= -1e-9,
                string.format('the point at %.4f is on the allowed side', angle)
            )
        end
        -- The angle a quarter turn past the end of the arc is not.
        local outside = Geometry.angle_at(set, total) + (2 * math.pi - total) / 2
        local x = radius * math.cos(outside)
        local y = radius * math.sin(outside)
        lunatest.assert_true(boundary.a * x + boundary.b * y + boundary.c < 0, 'and the far side is not')
    end
end

-- ---------------------------------------------------------------------------
-- The pinwheel: every team gets the canonical answer, turned
-- ---------------------------------------------------------------------------

function test_every_team_strikes_where_the_canonical_team_would()
    round_of(4)
    local source = { x = -300, y = -900 } -- canonical: deep in the zone, behind the base
    local target = { x = -150, y = -200 }

    local canonical_team = Teams.all()[1]
    local expected_x, expected_y = with_draws({ 300, 100 }, function()
        return Geometry.strike_position(canonical_team, source.x, source.y, target.x, target.y)
    end)
    lunatest.assert_not_nil(expected_x, 'the canonical answer exists')

    for _, team in ipairs(Teams.all()) do
        local k = Teams.k_of(team)
        local source_x, source_y = Layout.from_canonical(team, source.x, source.y)
        local target_x, target_y = Layout.from_canonical(team, target.x, target.y)
        local x, y = with_draws({ 300, 100 }, function()
            return Geometry.strike_position(team, source_x, source_y, target_x, target_y)
        end)
        local turned_x, turned_y = Layout.rotate_position(k, expected_x, expected_y)
        assert_exactly(team .. ' strike x', turned_x, x)
        assert_exactly(team .. ' strike y', turned_y, y)
    end
end

function test_every_team_forms_up_where_the_canonical_team_would()
    round_of(4)
    local target = { x = -150, y = -200 }

    for index = 1, #ATTACK_VECTORS do
        local vector = ATTACK_VECTORS[index]
        local canonical_team = Teams.all()[1]
        local expected_x, expected_y =
            Geometry.classic_waypoint(canonical_team, target.x, target.y, vector[1], vector[2], 0.75)
        lunatest.assert_not_nil(expected_x, 'the canonical waypoint exists')

        for _, team in ipairs(Teams.all()) do
            local k = Teams.k_of(team)
            local target_x, target_y = Layout.from_canonical(team, target.x, target.y)
            local x, y = Geometry.classic_waypoint(team, target_x, target_y, vector[1], vector[2], 0.75)
            local turned_x, turned_y = Layout.rotate_position(k, expected_x, expected_y)
            assert_exactly(team .. ' waypoint x, vector ' .. index, turned_x, x)
            assert_exactly(team .. ' waypoint y, vector ' .. index, turned_y, y)
        end
    end
end

function test_three_teams_answer_for_their_three_zones()
    round_of(3)
    lunatest.assert_equal(3, #Teams.all(), 'three teams play')
    for _, team in ipairs(Teams.all()) do
        local target_x, target_y = Layout.from_canonical(team, -150, -200)
        local x, y = Geometry.classic_waypoint(team, target_x, target_y, ATTACK_VECTORS[5][1], ATTACK_VECTORS[5][2], 1)
        lunatest.assert_equal(team, Layout.of_position({ x = x, y = y }), 'the waypoint is in its own zone')
    end
end

-- ---------------------------------------------------------------------------
-- Nothing lands in the water or next door
-- ---------------------------------------------------------------------------

function test_a_strike_position_stays_in_the_zone_and_off_both_rivers()
    round_of(4)
    local targets = { { -40, -60 }, { -30, -300 }, { -250, -40 }, { -600, -700 } }
    local sources = { { -300, -1200 }, { -1000, -900 }, { -60, -1500 } }
    local radii = { Geometry.MIN_STRIKE_DISTANCE, 300, Geometry.MAX_STRIKE_DISTANCE }
    local offsets = { lowest, highest, 7 }

    for _, team in ipairs(Teams.all()) do
        for _, target in ipairs(targets) do
            for _, source in ipairs(sources) do
                for _, radius in ipairs(radii) do
                    for _, offset in ipairs(offsets) do
                        local target_x, target_y = Layout.from_canonical(team, target[1], target[2])
                        local source_x, source_y = Layout.from_canonical(team, source[1], source[2])
                        local x, y = with_draws({ radius, offset }, function()
                            return Geometry.strike_position(team, source_x, source_y, target_x, target_y)
                        end)
                        local what = string.format(
                            '%s target (%d,%d) source (%d,%d) r=%d',
                            team,
                            target[1],
                            target[2],
                            source[1],
                            source[2],
                            radius
                        )
                        lunatest.assert_not_nil(x, what .. ': a position was found')
                        local canonical_x, canonical_y = canonical_of(team, x, y)
                        assert_at_most(what .. ': clear of the side river', -HALF_RIVER + 1e-9, canonical_x)
                        assert_at_most(what .. ': clear of the main river', -HALF_RIVER + 1e-9, canonical_y)
                        lunatest.assert_equal(team, Layout.of_position({ x = x, y = y }), what .. ': its own zone')
                    end
                end
            end
        end
    end
end

function test_a_target_next_to_the_side_river_never_sends_the_wave_next_door()
    round_of(4)
    -- Targets from right against the side river to well clear of it, with every
    -- vector and both a small and a full distance modifier: the three vectors
    -- that lean towards the river must be leaned the other way, and the one that
    -- leans nowhere must be clamped to the bank.
    for _, team in ipairs(Teams.all()) do
        for _, canonical_target_x in ipairs({ -23, -30, -54, -80, -200 }) do
            for index = 1, #ATTACK_VECTORS do
                for _, modifier in ipairs({ 0.25, 0.5, 0.75, 1 }) do
                    local vector = ATTACK_VECTORS[index]
                    local target_x, target_y = Layout.from_canonical(team, canonical_target_x, -120)
                    local x, y = Geometry.classic_waypoint(team, target_x, target_y, vector[1], vector[2], modifier)
                    local canonical_x, canonical_y = canonical_of(team, x, y)
                    local what = string.format(
                        '%s target x=%d vector %d modifier %.2f',
                        team,
                        canonical_target_x,
                        index,
                        modifier
                    )
                    assert_at_most(what .. ': clear of the side river', WAYPOINT_LIMIT, canonical_x)
                    assert_at_most(what .. ': behind the target', -120, canonical_y)
                    lunatest.assert_equal(team, Layout.of_position({ x = x, y = y }), what .. ': its own zone')
                end
            end
        end
    end
end

function test_a_vector_leaning_at_the_side_river_is_turned_around_before_it_is_clamped()
    round_of(4)
    local team = Teams.all()[2] -- east, k = 1
    local leaning = ATTACK_VECTORS[1] -- x = +300.9, the vector that leans hardest at the river

    -- Far enough from the river that leaning the other way is all it takes: the
    -- waypoint is the mirrored vector applied whole, not a clamp.
    local target_x, target_y = Layout.from_canonical(team, -60, -200)
    local x, y = Geometry.classic_waypoint(team, target_x, target_y, leaning[1], leaning[2], 0.5)
    local canonical_x, canonical_y = canonical_of(team, x, y)
    assert_exactly('mirrored, not clamped', -60 - math.abs(leaning[1]) * 0.5, canonical_x)
    assert_exactly('and the y component is left alone', -200 + leaning[2] * 0.5, canonical_y)

    -- The middle vector has no lean to mirror, so a target this close to the
    -- river can only be clamped to the bank.
    local straight = ATTACK_VECTORS[3]
    target_x, target_y = Layout.from_canonical(team, -30, -200)
    x, y = Geometry.classic_waypoint(team, target_x, target_y, straight[1], straight[2], 0.5)
    canonical_x, canonical_y = canonical_of(team, x, y)
    assert_exactly('clamped to the bank', WAYPOINT_LIMIT, canonical_x)
    assert_exactly('the y component is still left alone', -200 + straight[2] * 0.5, canonical_y)
end

-- ---------------------------------------------------------------------------
-- The arc that is not there
-- ---------------------------------------------------------------------------

function test_an_arc_with_nothing_left_of_it_answers_nil()
    round_of(4)
    local team = Teams.all()[2]
    -- A target more than a strike radius past the side river -- every point of
    -- the circle around it is in the neighbour's zone, so the range is empty
    -- where the legacy one could only ever be cut short.
    local target_x, target_y = Layout.from_canonical(team, 600, -300)
    local source_x, source_y = Layout.from_canonical(team, -300, -1200)
    local x, y = with_draws({ Geometry.MIN_STRIKE_DISTANCE, 0 }, function()
        return Geometry.strike_position(team, source_x, source_y, target_x, target_y)
    end)
    lunatest.assert_nil(x, 'no strike position')
    lunatest.assert_nil(y, 'and no second value either')
end

function test_an_arc_shorter_than_a_tile_answers_nil()
    -- The folded frame directly: a target just inside the reach of the side
    -- river bank, where the two banks leave a sliver a fifth of a tile long.
    local radius = Geometry.MIN_STRIKE_DISTANCE
    local target_x, target_y = 233.9999, 300

    local sliver = Geometry.intersect_arcs(
        Geometry.half_plane_arcs(radius, 0, 1, target_y - HALF_RIVER),
        Geometry.half_plane_arcs(radius, -1, 0, -HALF_RIVER - target_x)
    )
    local length = radius * Geometry.total_angle(sliver)
    lunatest.assert_true(length > 0, 'the banks do leave something')
    lunatest.assert_true(length < Geometry.MIN_STRIKE_ARC_LENGTH, 'but less than a tile of it: ' .. length)

    local x, y = with_draws({ radius, 0 }, function()
        return Geometry.folded_strike_position(-300, 900, target_x, target_y)
    end)
    lunatest.assert_nil(x, 'too short to strike on')
    lunatest.assert_nil(y, 'and no second value either')
end

function test_a_wave_too_close_to_flank_strikes_where_it_stands()
    round_of(4)
    local team = Teams.all()[3]
    local target_x, target_y = Layout.from_canonical(team, -200, -200)
    local source_x, source_y = Layout.from_canonical(team, -300, -300) -- 141 tiles away

    local x, y = with_draws({ 999, 999 }, function()
        return Geometry.strike_position(team, source_x, source_y, target_x, target_y)
    end)
    assert_exactly('the wave strikes from where it stands, x', source_x, x)
    assert_exactly('the wave strikes from where it stands, y', source_y, y)
    lunatest.assert_equal(0, draws_taken, 'and the legacy guard draws nothing')
end

function test_a_force_that_names_no_team_has_no_geometry()
    round_of(4)
    lunatest.assert_nil(Geometry.strike_position('nobody', -300, -900, -150, -200), 'no strike position')
    lunatest.assert_nil(Geometry.classic_waypoint('nobody', -150, -200, 1, -1, 0.5), 'no waypoint')
    lunatest.assert_false(Geometry.is_towards_river('nobody', -150, -200, -150, -900), 'and no progress')
end

-- ---------------------------------------------------------------------------
-- Progress towards the river
-- ---------------------------------------------------------------------------

function test_the_waypoint_is_taken_only_when_it_leads_towards_the_river()
    round_of(4)
    for _, team in ipairs(Teams.all()) do
        local group_x, group_y = Layout.from_canonical(team, -300, -900)
        local nearer_x, nearer_y = Layout.from_canonical(team, -250, -400)
        local further_x, further_y = Layout.from_canonical(team, -250, -1400)
        local level_x, level_y = Layout.from_canonical(team, -700, -900)

        lunatest.assert_true(
            Geometry.is_towards_river(team, nearer_x, nearer_y, group_x, group_y),
            team .. ': a waypoint closer to the river is worth going to'
        )
        lunatest.assert_false(
            Geometry.is_towards_river(team, further_x, further_y, group_x, group_y),
            team .. ': one further away is not'
        )
        lunatest.assert_false(
            Geometry.is_towards_river(team, level_x, level_y, group_x, group_y),
            team .. ': and neither is one level with the group'
        )
    end
end

lunatest.run()
