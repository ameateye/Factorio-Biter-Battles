---@diagnostic disable
--
-- Pins `maps/biter_battles_v2/captain_vote_model.lua`, the pure half of the
-- BB Captains CAPTAIN VOTE window: what an open may carry, how the count
-- ballots and the kick ballots are counted, and who the preview keeps.
--
-- The SAME vectors (V1..V8) are asserted by the league's own tests on the
-- daemon side, so the window's preview and the orchestrator's decision cannot drift apart.

local lunatest = require('lunatest')
local Model = require('maps.biter_battles_v2.captain_vote_model')

local function vote(t)
    return {
        cands = t.cands,
        choices = t.choices,
        default_n = t.default_n,
        counts = t.counts or {},
        kicks = t.kicks or {},
    }
end

local function same(a, b)
    lunatest.assert_equal(table.concat(a, ','), table.concat(b, ','))
end

local P8 = { 'pro1', 'pro2', 'noob1', 'noob2', 'p5', 'p6', 'p7', 'p8' }
local C4 = { 'pro1', 'pro2', 'noob1', 'noob2' }

-- V1: the reference example -- 8 players, 2 pros + 2 noobs, the noobs kicked by 4 of 7.
function test_v1_owner_example_two_noobs_kicked()
    local kicks = {}
    for _, v in ipairs({ 'pro1', 'pro2', 'p5', 'p6' }) do
        kicks[v] = { noob1 = true, noob2 = true }
    end
    local v = vote({ cands = C4, choices = { 2 }, default_n = 2, kicks = kicks })
    local n, kept = Model.preview(v, P8)
    lunatest.assert_equal(2, n)
    same({ 'pro1', 'pro2' }, kept)
    lunatest.assert_equal(4, Model.need('noob1', P8))
end

-- V2: 3 of 7 is below half: nobody is kicked.
function test_v2_three_of_seven_is_not_enough()
    local kicks = {}
    for _, v in ipairs({ 'pro1', 'p5', 'p6' }) do
        kicks[v] = { noob1 = true }
    end
    same({}, Model.kicked(kicks, C4, P8))
end

-- V3: exactly half of the others kicks: 9 present -> 8 others -> 4 ballots are enough.
function test_v3_exactly_half_kicks()
    local P9 = { 'pro1', 'pro2', 'noob1', 'noob2', 'p5', 'p6', 'p7', 'p8', 'p9' }
    local kicks = {}
    for _, v in ipairs({ 'p5', 'p6', 'p7', 'p8' }) do
        kicks[v] = { noob2 = true }
    end
    same({ 'noob2' }, Model.kicked(kicks, C4, P9))
end

-- V4: a ballot from a voter who is not present does not count; nor a self-kick.
function test_v4_absent_and_self_ballots_do_not_count()
    local present = { 'pro1', 'pro2', 'noob1', 'noob2', 'p5' }
    local kicks = { p6 = { noob1 = true }, p7 = { noob1 = true }, noob1 = { noob1 = true }, p5 = { noob1 = true } }
    local t = Model.kick_tally(kicks, C4, present)
    lunatest.assert_equal(1, t.noob1)
    same({}, Model.kicked(kicks, C4, present))
end

-- V5: count vote -- most ballots wins.
function test_v5_most_ballots()
    local counts = { pro1 = 4, pro2 = 4, p5 = 3, p6 = 2 }
    lunatest.assert_equal(4, Model.elected(counts, { 2, 3, 4 }, P8, 4))
end

-- V6: a tie goes to the smaller count.
function test_v6_tie_to_the_smaller()
    local counts = { pro1 = 4, pro2 = 2, p5 = 4, p6 = 2 }
    lunatest.assert_equal(2, Model.elected(counts, { 2, 3, 4 }, P8, 4))
end

-- V7: no ballot -> the default (the derived count the daemon passed).
function test_v7_no_ballot_is_the_default()
    lunatest.assert_equal(4, Model.elected({}, { 2, 3, 4 }, P8, 4))
    -- ballots of absent voters and for a count not offered are not ballots
    lunatest.assert_equal(3, Model.elected({ ghost = 2, pro1 = 4 }, { 2, 3 }, P8, 3))
end

-- V8: a lone voter pair: 2 present, the other one alone kicks (1 of 1).
function test_v8_small_electorate()
    local present = { 'a', 'b' }
    same({ 'b' }, Model.kicked({ a = { b = true } }, { 'a', 'b', 'c' }, present))
    lunatest.assert_equal(1, Model.need('c', present))
    -- c is not present: both others count, need 1
    same({ 'c' }, Model.kicked({ a = { c = true } }, { 'a', 'b', 'c' }, present))
end

function test_ballot_order_does_not_matter()
    local a = { pro1 = 3, pro2 = 3, p5 = 2 }
    local b = {}
    b.p5 = 2
    b.pro2 = 3
    b.pro1 = 3
    lunatest.assert_equal(Model.elected(a, { 2, 3 }, P8, 2), Model.elected(b, { 2, 3 }, P8, 2))
end

function test_open_validation()
    local ok = Model.normalise_open({ cands = C4, voters = P8, choices = { 4, 2 }, default_n = 4, game = 7 })
    lunatest.assert_equal(60, ok.seconds)
    same({ 2, 4 }, ok.choices)
    lunatest.assert_equal(4, ok.default_n)
    lunatest.assert_equal(7, ok.game)
    -- default_n not offered -> the smallest choice
    lunatest.assert_equal(
        2,
        Model.normalise_open({ cands = C4, voters = P8, choices = { 2 }, default_n = 4 }).default_n
    )
    local bad = {
        { cands = { 'a', 'b' }, voters = P8, choices = { 2 } }, -- 2 candidates: no vote
        { cands = { 'a', 'b', 'c', 'd', 'e' }, voters = P8, choices = { 2 } }, -- 5 candidates
        { cands = { 'a', 'b', 'c' }, voters = P8, choices = { 4 } }, -- 4 captains out of 3
        { cands = C4, voters = {}, choices = { 2 } },
        { cands = C4, voters = P8, choices = { 5 } },
        { cands = C4, voters = P8, choices = {} },
        { cands = C4, voters = P8, choices = { 2 }, timeout_s = 5 },
        { cands = C4, voters = P8, choices = { 2 }, timeout_s = 12.5 },
        { cands = { 'a', 'b', '' }, voters = P8, choices = { 2 } },
        'x',
    }
    for i, o in ipairs(bad) do
        local r, reason = Model.normalise_open(o)
        lunatest.assert_nil(r, 'accepted bad open #' .. i)
        lunatest.assert_true(type(reason) == 'string')
    end
end

lunatest.run()
