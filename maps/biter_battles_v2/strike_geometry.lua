-- Where a biter wave goes on the four-square map: the
-- waypoint a classic wave forms up on, and the position an advanced wave swings
-- out to before it charges.
--
-- WHY THIS MODULE EXISTS. The wave geometry of the two-team map lives in
-- `ai_strikes.lua`, which requires `utils.event`, `defines` and the multi-silo
-- special at load and so cannot be read by a unit test. The four-square map
-- needs a second boundary, an arc intersection that can come out empty and a
-- rotation per team -- all of it pure arithmetic, all of it worth pinning. So
-- the new arithmetic lives here, reachable from `tests/test-strike-geometry.lua`,
-- and the legacy functions stay in `ai_strikes.lua` exactly as they are: this
-- module is only ever reached when the round is NOT playing `horizontal2`.
--
-- THE CANONICAL FRAME is `layout.lua`'s: the canonical zone is today's north
-- side cut at x = 0, the quadrant x < 0 and y < 0. Its MAIN river -- the one the
-- enemy is across -- runs along y = 0, its SIDE river along x = 0, both of half
-- width `border_river_width / 2`, and its biters live far up, at very negative
-- y. Team k's zone is that quadrant turned k quarter turns clockwise, so a
-- question about team k is answered by turning the question into the canonical
-- frame (`Layout.to_canonical`), answering it there, and turning the answer back
-- (`Layout.from_canonical`). Both are exact: components are swapped and negated,
-- never multiplied by a cosine, so the answer for team k is the exact rotation
-- of the answer for the canonical team.
--
-- THE FOLDED FRAME is the legacy one. `ai_strikes.lua:154-165` folds the world
-- to `y = |y|` and does all of its arithmetic in the half plane the river bounds
-- from below. The canonical zone has negative y, so folding it is `y -> |y|`
-- again and unfolding is `y -> -y`; x is left alone and stays negative. Inside
-- the fold the arithmetic is the legacy arithmetic -- the same tangent line, the
-- same secant intersections, the same cone around the direction the wave comes
-- from -- with one boundary added:
--
--     main river: y >= half width   (the legacy boundary)
--     side river: x <= -half width  (new; the legacy map has no such river)
--
-- ARCS. Two boundaries and a cone cannot be intersected with the `max`/`min` of
-- `ai_strikes.lua:138-139`: on a circle an arc can wrap past 2*pi and the
-- intersection of two arcs can be two separate pieces. So an allowed range here
-- is a SET of arcs -- a list of `{ start, finish }` with `finish >= start`, each
-- at most a full turn long, sorted and disjoint -- and the set can come out
-- EMPTY, which the legacy shape cannot: `ai_strikes.lua:142-143` would then
-- divide by zero and call `math.random(0, negative)`. An empty or degenerate
-- range answers nil here, and the callers already treat a nil strike position as
-- "charge straight in, no flank".
--
-- Determinism: no `pairs`, no `table.sort` (the handful of arc pieces are put in
-- order by insertion), and the two `math.random` draws of a strike position are
-- the two draws of the legacy function, in the legacy order -- the radius first,
-- then the point on the arc.

local Config = require('maps.biter_battles_v2.config')
local Layout = require('maps.biter_battles_v2.layout')

local math_abs = math.abs
local math_acos = math.acos
local math_atan2 = math.atan2
local math_cos = math.cos
local math_floor = math.floor
local math_fmod = math.fmod
local math_max = math.max
local math_min = math.min
local math_pi = math.pi
local math_2pi = 2 * math_pi
local math_random = math.random
local math_sin = math.sin
local math_sqrt = math.sqrt

local Public = {}

---The three tuning radii of a strike, the same numbers as the legacy locals
---`ai_strikes.lua:25-27` -- they approximate the radius of an average player
---base and are tuned on the depth of one zone, which the four-square map does
---not change. Duplicated rather than imported because `ai_strikes.lua` is not
---loadable outside Factorio; a change to either set belongs in both.
Public.MAX_STRIKE_DISTANCE = 512
Public.MIN_STRIKE_DISTANCE = 256
Public.STRIKE_TARGET_CLEARANCE = 255

---The shortest strike arc worth a draw, in tiles. Below it the range is treated
---as empty: `math.floor(radius * angle)` is the denominator of the draw at
---`ai_strikes.lua:143`, so one tile is also the smallest value that keeps that
---division meaningful.
Public.MIN_STRIKE_ARC_LENGTH = 1

---How far from the side river a classic waypoint has to stay, in tiles. The
---`go_to_location` command it feeds carries a radius of 32
---(`ai_strikes.lua:223-228`), so a waypoint any closer would send the wave into
---the water -- or, once it is across, into the neighbour's zone.
Public.WAYPOINT_RIVER_CLEARANCE = 32

---Half the width of a river, in tiles: both arms are the one river of
---`config.lua` (`bb_config.border_river_width`), read per call as
---`ai_strikes.lua:158` reads it.
---@return number
local function river_half_width()
    return Config.border_river_width / 2
end

-- ---------------------------------------------------------------------------
-- Arcs of a circle
-- ---------------------------------------------------------------------------

---@class StrikeArc
---@field start number Where the arc begins, in radians.
---@field finish number Where it ends: `>= start`, at most a full turn later.

---An angle brought into (-pi, pi]. `ai_strikes.lua:74-80`, verbatim, including
---its limit: an input beyond a full turn either way is not brought back, which
---no caller here produces (the cone is built from an angle and a half width,
---both within a half turn).
---@param angle number
---@return number
local function normalize_angle(angle)
    angle = math_fmod(angle + math_2pi, math_2pi)
    if angle > math_pi then
        angle = angle - math_2pi
    end
    return angle
end

---The same arc with its start brought into [-pi, pi), which is what lets the
---intersection below try a fixed three turns of offset and know it has missed
---nothing. The length is carried over rather than recomputed, so it is exact.
---@param arc StrikeArc
---@return StrikeArc
local function on_principal_turn(arc)
    local length = arc.finish - arc.start
    local start = arc.start - math_floor((arc.start + math_pi) / math_2pi) * math_2pi
    return { start = start, finish = start + length }
end

---The pieces of a set put in order of their start and welded together where
---they touch or overlap. Insertion sort over at most a handful of pieces: it
---never compares two pieces equal, so every client gets the same list.
---@param pieces StrikeArc[]
---@return StrikeArc[]
local function sorted_and_merged(pieces)
    for i = 2, #pieces do
        local piece = pieces[i]
        local j = i - 1
        while
            j >= 1
            and (pieces[j].start > piece.start or (pieces[j].start == piece.start and pieces[j].finish > piece.finish))
        do
            pieces[j + 1] = pieces[j]
            j = j - 1
        end
        pieces[j + 1] = piece
    end

    local merged = {}
    for i = 1, #pieces do
        local piece = pieces[i]
        local last = merged[#merged]
        if last and piece.start <= last.finish then
            if piece.finish > last.finish then
                last.finish = piece.finish
            end
        else
            merged[#merged + 1] = { start = piece.start, finish = piece.finish }
        end
    end
    return merged
end

---The whole circle as an arc set.
---@return StrikeArc[]
function Public.full_circle()
    return { { start = -math_pi, finish = math_pi } }
end

---The intersection of two arc sets, as a new set.
---
---Each piece of the first set is cut against each piece of the second on the
---turn before, the turn of, and the turn after it -- three offsets, which is
---enough once both starts sit on the principal turn and no piece is longer than
---a full turn. An arc that wraps past 2*pi therefore meets the piece it overlaps
---whichever side of the seam that piece was written on, and an intersection that
---falls into two separate pieces stays two pieces.
---@param first StrikeArc[]
---@param second StrikeArc[]
---@return StrikeArc[]
function Public.intersect_arcs(first, second)
    local pieces = {}
    for i = 1, #first do
        local a = on_principal_turn(first[i])
        for j = 1, #second do
            local b = on_principal_turn(second[j])
            for turn = -1, 1 do
                local offset = turn * math_2pi
                local start = math_max(a.start, b.start + offset)
                local finish = math_min(a.finish, b.finish + offset)
                if finish > start then
                    pieces[#pieces + 1] = { start = start, finish = finish }
                end
            end
        end
    end
    return sorted_and_merged(pieces)
end

---The total angle a set covers, in radians. Multiply by the radius for its
---length in tiles.
---@param set StrikeArc[]
---@return number
function Public.total_angle(set)
    local total = 0
    for i = 1, #set do
        total = total + (set[i].finish - set[i].start)
    end
    return total
end

---The angle `t` radians into the set, measured along its pieces in order: the
---"point at arc length t" of a set that may have holes in it. `t` is clamped to
---the set, so 0 is the very start and `total_angle(set)` the very end.
---@param set StrikeArc[]
---@param t number
---@return number|nil angle nil for the empty set.
function Public.angle_at(set, t)
    if #set == 0 then
        return nil
    end
    if not (t > 0) then
        return set[1].start
    end
    for i = 1, #set do
        local piece = set[i]
        local length = piece.finish - piece.start
        if t <= length then
            return piece.start + t
        end
        t = t - length
    end
    return set[#set].finish
end

---The arc of the circle of radius `radius` about the origin that lies in the
---half plane `a*x + b*y + c >= 0`, where `(a, b)` is a UNIT normal pointing into
---the allowed side and `c` is therefore the signed distance from the circle's
---centre to the boundary line.
---
---The whole circle when the centre is at least a radius inside the half plane,
---nothing when it is at least a radius outside -- the two cases the legacy
---`calculate_boundary_range` never has to consider, because
---`ai_strikes.lua:136` only calls it when the boundary cuts the circle and the
---legacy map's one boundary can never exclude it whole.
---@param radius number
---@param a number
---@param b number
---@param c number
---@return StrikeArc[]
function Public.half_plane_arcs(radius, a, b, c)
    if c >= radius then
        return Public.full_circle()
    end
    if c <= -radius then
        return {}
    end
    local inward = math_atan2(b, a)
    local half_width = math_acos(-c / radius)
    return { { start = inward - half_width, finish = inward + half_width } }
end

-- ---------------------------------------------------------------------------
-- The cone a wave may strike from
-- ---------------------------------------------------------------------------
--
-- `calculate_secant_intersections`, `calculate_tangent_line` and
-- `calculate_strike_range` below are `ai_strikes.lua:44-102` copied statement
-- for statement. They are what puts the strike position on the wave's own side
-- of the target and outside the 255-tile core of the base, and the four-square
-- map changes nothing about them; they are copied rather than shared because the
-- legacy file stays untouched and is not loadable here.

---@param r number
---@param a number
---@param b number
---@param c number
local function calculate_secant_intersections(r, a, b, c)
    local t = a * a + b * b
    local x = -a * c / t
    local y = -b * c / t
    local d = r * r - c * c / t
    local m = math_sqrt(d / t)
    local bm = b * m
    local am = a * m
    return {
        a = {
            x = x + bm,
            y = y - am,
        },
        b = {
            x = x - bm,
            y = y + am,
        },
    }
end

---@param r number
---@param d number
local function calculate_tangent_line(r, d)
    local r2 = r * r
    local t = r * math_sqrt(d * d - r2)
    return {
        a = t / d,
        b = d - r2 / d,
        c = -t,
    }
end

---The cone of angles about the target that a wave coming from
---`(source_target_dx, source_target_dy)` may strike from: centred on the
---direction the wave comes from, widened to the tangents of the target's core.
---@param source_target_dx number
---@param source_target_dy number
---@param source_target_distance number
---@param inner_radius number
---@param outer_radius number
---@return StrikeArc
local function calculate_strike_range(
    source_target_dx,
    source_target_dy,
    source_target_distance,
    inner_radius,
    outer_radius
)
    local theta = math_atan2(source_target_dy, source_target_dx)
    local t = calculate_tangent_line(inner_radius, source_target_distance)
    local intersections = calculate_secant_intersections(outer_radius, t.a, t.b, t.c)
    local phi = math_atan2(intersections.b.y, intersections.b.x)
    local start = normalize_angle(theta - phi)
    local finish = normalize_angle(theta + phi)
    if finish < start then
        finish = finish + math_2pi
    end
    return {
        start = start,
        finish = finish,
    }
end

-- ---------------------------------------------------------------------------
-- A strike position
-- ---------------------------------------------------------------------------

---The strike position of a wave, in the FOLDED frame: x is the canonical x and
---stays negative, y is `|canonical y|` and grows away from the main river.
---
---The legacy `select_strike_position` (`ai_strikes.lua:118-152`) with the side
---river added and the empty range answered instead of divided by: a radius is
---drawn, the cone is cut against both rivers, and a point is drawn on what is
---left of it. Same two draws as the legacy, in the same order.
---@param source_x number
---@param source_y number
---@param target_x number
---@param target_y number
---@return number|nil x nil when nothing is left of the arc.
---@return number|nil y
function Public.folded_strike_position(source_x, source_y, target_x, target_y)
    local source_target_dx = source_x - target_x
    local source_target_dy = source_y - target_y
    local source_target_distance = math_sqrt(source_target_dx * source_target_dx + source_target_dy * source_target_dy)
    if source_target_distance < Public.MIN_STRIKE_DISTANCE then
        -- The legacy guard: too close to flank, strike where the wave stands.
        return source_x, source_y
    end

    local strike_distance =
        math_random(Public.MIN_STRIKE_DISTANCE, math_min(source_target_distance, Public.MAX_STRIKE_DISTANCE))
    local allowed = {
        calculate_strike_range(
            source_target_dx,
            source_target_dy,
            source_target_distance,
            Public.STRIKE_TARGET_CLEARANCE,
            strike_distance
        ),
    }

    local half_width = river_half_width()
    -- Main river: y >= half_width, so the inward normal is +y and the signed
    -- distance from the target to the bank is `target_y - half_width`. This is
    -- the legacy boundary, and for the legacy map it is the only one.
    allowed = Public.intersect_arcs(allowed, Public.half_plane_arcs(strike_distance, 0, 1, target_y - half_width))
    -- Side river: x <= -half_width, inward normal -x. New on the four-square
    -- map, where a zone is a quadrant and not a half plane.
    allowed = Public.intersect_arcs(allowed, Public.half_plane_arcs(strike_distance, -1, 0, -half_width - target_x))

    local strike_angle_magnitude = Public.total_angle(allowed)
    local strike_zone_arc_length = math_floor(strike_distance * strike_angle_magnitude)
    -- Written as a failed `>=` so that a NaN takes this path too. No live wave
    -- can produce one -- the strike radius is always larger than the clearance,
    -- which is what keeps the tangent line real -- but a degenerate call could,
    -- and `math.random(0, nan)` raises.
    if not (strike_zone_arc_length >= Public.MIN_STRIKE_ARC_LENGTH) then
        return nil
    end

    local random_angle_offset = (math_random(0, strike_zone_arc_length) / strike_zone_arc_length)
        * strike_angle_magnitude
    local strike_angle = Public.angle_at(allowed, random_angle_offset)
    return target_x + strike_distance * math_cos(strike_angle), target_y + strike_distance * math_sin(strike_angle)
end

---Where a wave of `team`'s biters swings out to before it charges the target, in
---world coordinates: the answer of `folded_strike_position` for a target and a
---source carried into `team`'s canonical frame and folded, brought back out.
---
---Unfolding always lands in the team's own quadrant, whichever side of the river
---the wave itself has drifted to -- the four-square map has no counterpart to
---the legacy mirror on the sign of the group's own y (`ai_strikes.lua:161`),
---which is the quirk that map keeps.
---@param team string
---@param source_x number
---@param source_y number
---@param target_x number
---@param target_y number
---@return number|nil x nil when the team has no zone, or nothing is left of the arc.
---@return number|nil y
function Public.strike_position(team, source_x, source_y, target_x, target_y)
    local canonical_source_x, canonical_source_y = Layout.to_canonical(team, source_x, source_y)
    if not canonical_source_x then
        return nil
    end
    local canonical_target_x, canonical_target_y = Layout.to_canonical(team, target_x, target_y)

    local folded_x, folded_y = Public.folded_strike_position(
        canonical_source_x,
        math_abs(canonical_source_y),
        canonical_target_x,
        math_abs(canonical_target_y)
    )
    if not folded_x then
        return nil
    end
    return Layout.from_canonical(team, folded_x, -folded_y)
end

-- ---------------------------------------------------------------------------
-- A classic waypoint
-- ---------------------------------------------------------------------------

---Where a classic wave forms up on its way to the target, in world coordinates.
---
---The canonical waypoint is the canonical target plus the canonical attack
---vector scaled by the wave's distance modifier -- the arithmetic of
---`ai_strikes.lua:216-219`, in the frame where the attack vectors were drawn.
---Turning the waypoint by k quarter turns is the same as turning the vector by k
---and adding it in the world frame, which is why the four-square map needs no
---per-team copy of the vector table.
---
---What the legacy map has no need of is the SIDE river. Three of the five
---vectors lean towards it, and a target near it would throw the waypoint across
---into the neighbour's zone, so a waypoint that is not clear of the side river
---has the vector's x mirrored (x -> -|x|, which leans it the other way, into the
---team's own free land) and, if even that is not enough, is clamped to the bank.
---The y component is left alone: it always points away from the main river, deep
---into the team's own ground.
---@param team string
---@param target_x number
---@param target_y number
---@param vector_x number
---@param vector_y number
---@param distance_modifier number
---@return number|nil x nil when the team has no zone on this map.
---@return number|nil y
function Public.classic_waypoint(team, target_x, target_y, vector_x, vector_y, distance_modifier)
    local canonical_target_x, canonical_target_y = Layout.to_canonical(team, target_x, target_y)
    if not canonical_target_x then
        return nil
    end

    local limit = -(river_half_width() + Public.WAYPOINT_RIVER_CLEARANCE)
    local waypoint_x = canonical_target_x + (vector_x * distance_modifier)
    if waypoint_x > limit then
        waypoint_x = canonical_target_x + (-math_abs(vector_x) * distance_modifier)
        if waypoint_x > limit then
            waypoint_x = limit
        end
    end
    local waypoint_y = canonical_target_y + (vector_y * distance_modifier)

    return Layout.from_canonical(team, waypoint_x, waypoint_y)
end

---True when going to `(waypoint_x, waypoint_y)` first brings the wave closer to
---the main river than it already is -- the four-square reading of
---`ai_strikes.lua:222`, where "closer to the river" is the smaller `|y|` of a map
---whose river is the x axis. In the canonical frame both y are negative and the
---river is at y = 0, so nearer means greater.
---@param team string
---@param waypoint_x number
---@param waypoint_y number
---@param group_x number
---@param group_y number
---@return boolean
function Public.is_towards_river(team, waypoint_x, waypoint_y, group_x, group_y)
    local _, canonical_waypoint_y = Layout.to_canonical(team, waypoint_x, waypoint_y)
    local _, canonical_group_y = Layout.to_canonical(team, group_x, group_y)
    if not canonical_waypoint_y or not canonical_group_y then
        return false
    end
    return canonical_waypoint_y > canonical_group_y
end

return Public
