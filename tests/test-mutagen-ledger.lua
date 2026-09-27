---@diagnostic disable
--
-- The elimination re-send (`maps/biter_battles_v2/mutagen_ledger.lua`): who fed
-- whom, and what the teams still standing re-send to each other when a team of
-- a 3-4 team round is out.
--
-- The splits come from the real registry (`Teams.feed_targets`), so a re-send
-- is pinned to be shared out exactly as a live send from the same team would
-- be. The worked example is the one the rule was specified with: the fallen
-- team got 50 from B, 60 from C and 70 from D.

local lunatest = require('lunatest')

storage = { ['_TEST'] = true }

local Ledger = require('maps.biter_battles_v2.mutagen_ledger')
local Teams = require('maps.biter_battles_v2.teams')

local EPS = 1e-9

local function round_of(count)
    storage = { ['_TEST'] = true }
    game = { tick = 0, forces = {} }
    lunatest.assert_true(Teams.set_next_count(count))
    Teams.begin_round()
end

--- Book the same amount in both units.
local function feed(ledger, source, target, amount)
    Ledger.record(ledger, source, target, amount, amount)
end

--- team -> total received, from a plan.
local function received(transfers)
    local out = {}
    for _, total in ipairs(Ledger.totals_by_target(transfers)) do
        out[total.team] = total
    end
    return out
end

local function assert_near(expected, actual, what)
    lunatest.assert_true(
        math.abs(expected - actual) < EPS,
        string.format('%s: expected %.9f, got %.9f', what, expected, actual)
    )
end

--- North falls in a four-team round after east, south and west fed it 50, 60, 70.
local function four_team_example()
    round_of(4)
    local ledger = {}
    feed(ledger, 'east', 'north', 50)
    feed(ledger, 'south', 'north', 60)
    feed(ledger, 'west', 'north', 70)
    Teams.eliminate('north')
    return ledger
end

function test_excess_resends_only_what_exceeds_the_smallest_feeder()
    local ledger = four_team_example()
    local transfers = Ledger.plan(ledger, 'north', Teams.alive(), Ledger.EXCESS, Teams.feed_targets)
    -- East fed the least and re-sends nothing; south re-sends 10, west 20, each
    -- split evenly over its two alive enemies.
    for _, transfer in ipairs(transfers) do
        lunatest.assert_not_equal('east', transfer.source, 'the smallest feeder re-sends nothing')
    end
    local got = received(transfers)
    assert_near(5 + 10, got.east.raw, 'east')
    assert_near(10, got.south.raw, 'south')
    assert_near(5, got.west.raw, 'west')
end

function test_full_resends_everything_fed()
    local ledger = four_team_example()
    local got = received(Ledger.plan(ledger, 'north', Teams.alive(), Ledger.FULL, Teams.feed_targets))
    assert_near(30 + 35, got.east.raw, 'east')
    assert_near(25 + 35, got.south.raw, 'south')
    assert_near(25 + 30, got.west.raw, 'west')
end

function test_off_moves_nothing()
    local ledger = four_team_example()
    lunatest.assert_equal(0, #Ledger.plan(ledger, 'north', Teams.alive(), Ledger.OFF, Teams.feed_targets))
end

function test_no_resend_goes_to_the_fallen_team_or_back_to_its_source()
    local ledger = four_team_example()
    for _, mode in ipairs({ Ledger.FULL, Ledger.EXCESS }) do
        for _, transfer in ipairs(Ledger.plan(ledger, 'north', Teams.alive(), mode, Teams.feed_targets)) do
            lunatest.assert_not_equal('north', transfer.target)
            lunatest.assert_not_equal(transfer.source, transfer.target)
        end
    end
end

function test_three_teams_the_bigger_feeder_hands_its_surplus_to_the_other()
    round_of(3)
    local ledger = {}
    local teams = Teams.all()
    local fallen, b, c = teams[1], teams[2], teams[3]
    feed(ledger, b, fallen, 50)
    feed(ledger, c, fallen, 60)
    Teams.eliminate(fallen)
    local transfers = Ledger.plan(ledger, fallen, Teams.alive(), Ledger.EXCESS, Teams.feed_targets)
    lunatest.assert_equal(1, #transfers)
    lunatest.assert_equal(c, transfers[1].source)
    lunatest.assert_equal(b, transfers[1].target)
    assert_near(10, transfers[1].raw, 'surplus')
end

function test_a_team_that_fed_nothing_makes_excess_the_same_as_full()
    round_of(4)
    local ledger = {}
    feed(ledger, 'south', 'north', 60)
    feed(ledger, 'west', 'north', 70)
    Teams.eliminate('north')
    local excess = received(Ledger.plan(ledger, 'north', Teams.alive(), Ledger.EXCESS, Teams.feed_targets))
    local full = received(Ledger.plan(ledger, 'north', Teams.alive(), Ledger.FULL, Teams.feed_targets))
    for _, team in ipairs({ 'east', 'south', 'west' }) do
        assert_near(full[team].raw, excess[team].raw, team)
    end
end

function test_raw_and_weighted_floors_are_taken_independently()
    round_of(3)
    local ledger = {}
    local teams = Teams.all()
    local fallen, b, c = teams[1], teams[2], teams[3]
    -- b fed early at a low difficulty, c late at a high one: c has the bigger
    -- weighted amount and b the bigger raw one.
    Ledger.record(ledger, b, fallen, 100, 80)
    Ledger.record(ledger, c, fallen, 60, 120)
    Teams.eliminate(fallen)
    local transfers = Ledger.plan(ledger, fallen, Teams.alive(), Ledger.EXCESS, Teams.feed_targets)
    local by_source = {}
    for _, transfer in ipairs(transfers) do
        by_source[transfer.source] = transfer
    end
    assert_near(40, by_source[b].raw, 'b raw surplus')
    assert_near(0, by_source[b].weighted, 'b weighted surplus')
    assert_near(0, by_source[c].raw, 'c raw surplus')
    assert_near(40, by_source[c].weighted, 'c weighted surplus')
end

function test_a_resend_is_booked_and_handed_on_by_a_later_elimination()
    local ledger = four_team_example()
    local transfers = Ledger.plan(ledger, 'north', Teams.alive(), Ledger.FULL, Teams.feed_targets)
    Ledger.forget_target(ledger, 'north')
    for _, transfer in ipairs(transfers) do
        Ledger.record(ledger, transfer.source, transfer.target, transfer.raw, transfer.weighted)
    end
    lunatest.assert_equal(0, Ledger.fed(ledger, 'east', 'north').raw, 'the fallen team is forgotten')
    -- South's 60 went 30 to east and 30 to west; west's 70 went 35 to east.
    assert_near(30, Ledger.fed(ledger, 'south', 'east').raw, 'south -> east')
    assert_near(35, Ledger.fed(ledger, 'west', 'east').raw, 'west -> east')

    Teams.eliminate('east')
    local got = received(Ledger.plan(ledger, 'east', Teams.alive(), Ledger.FULL, Teams.feed_targets))
    -- Two teams left: each re-sends all it had booked on east to the other.
    assert_near(35, got.south.raw, 'south gets west\'s')
    assert_near(30, got.west.raw, 'west gets south\'s')
end

function test_a_team_already_out_does_not_resend()
    local ledger = four_team_example()
    feed(ledger, 'north', 'east', 40) -- fed by north before it fell
    feed(ledger, 'south', 'east', 10)
    Teams.eliminate('east')
    local transfers = Ledger.plan(ledger, 'east', Teams.alive(), Ledger.FULL, Teams.feed_targets)
    for _, transfer in ipairs(transfers) do
        lunatest.assert_not_equal('north', transfer.source)
    end
    assert_near(10, received(transfers).west.raw, 'only south re-sends')
end

function test_self_feeding_is_not_booked()
    local ledger = {}
    Ledger.record(ledger, 'north', 'north', 10, 10)
    Ledger.record(ledger, 'north', 'south', 0, 0)
    lunatest.assert_nil(next(ledger))
end

function test_mode_falls_back_to_the_default()
    lunatest.assert_equal(Ledger.DEFAULT_MODE, Ledger.mode(nil))
    lunatest.assert_equal(Ledger.DEFAULT_MODE, Ledger.mode('bogus'))
    lunatest.assert_equal(Ledger.FULL, Ledger.mode('full'))
    lunatest.assert_equal(Ledger.OFF, Ledger.mode('off'))
end

lunatest.run()
