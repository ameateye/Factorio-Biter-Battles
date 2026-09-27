---@diagnostic disable
--
-- Pins `maps/biter_battles_v2/count_vote_model.lua`, the pure half of the
-- "Number of teams for this match" window: what a vote may offer,
-- how long it may run, how the ballots are counted and which count they elect.
--
-- The three rules the window exists for, and the ones a beta will lean on:
--
--   * MOST BALLOTS WINS;
--   * a TIE goes to the SMALLER count -- three players wanting four teams and
--     three wanting two play two, never four;
--   * NOBODY VOTED means 2. A vote nobody answers must leave the scenario where
--     it already is, because 2 is the default count and the two-team round is
--     the baseline the whole phase is measured against.
--
-- The walk that picks the winner is `ipairs` over the choices, which are sorted
-- ascending whatever order the caller wrote them in -- that is what makes the
-- tie rule true and the answer the same on every peer. The tally itself is
-- integer `+ 1` into a table keyed by choice, so it is tested against ballots
-- fed in several orders: the answer may not depend on the order `pairs` hands
-- the players out in.
--
-- The module requires nothing, touches no `game` and no `storage`, so there is
-- no mock here at all.

local lunatest = require('lunatest')

local Model = require('maps.biter_battles_v2.count_vote_model')

local FULL = { 2, 3, 4 }

---@param list string[] one entry per ballot, 'name=count'
local function ballots(list)
    local votes = {}
    for _, entry in ipairs(list) do
        local name, count = entry:match('^(%S+)=(%d+)$')
        votes[name] = tonumber(count)
    end
    return votes
end

function test_choices_default_to_the_three_counts()
    local choices = Model.normalise_choices(nil)
    lunatest.assert_equal(3, #choices)
    lunatest.assert_equal(2, choices[1])
    lunatest.assert_equal(3, choices[2])
    lunatest.assert_equal(4, choices[3])

    -- A copy: a caller must not be handed the module's own list.
    choices[1] = 9
    lunatest.assert_equal(2, Model.CHOICES[1])
end

function test_choices_are_sorted_and_deduplicated()
    local choices = Model.normalise_choices({ 4, 2, 4 })
    lunatest.assert_equal(2, #choices)
    lunatest.assert_equal(2, choices[1])
    lunatest.assert_equal(4, choices[2])
end

function test_choices_refuse_anything_that_is_not_a_playable_count()
    for _, bad in ipairs({ { 1 }, { 5 }, { 0 }, { 2.5 }, { 'north' }, {}, 'two', 7 }) do
        local ok, reason = Model.normalise_choices(bad)
        lunatest.assert_nil(ok, 'accepted ' .. tostring(bad))
        lunatest.assert_true(type(reason) == 'string')
    end
end

function test_timeout_bounds()
    lunatest.assert_equal(Model.DEFAULT_TIMEOUT_S, Model.normalise_timeout(nil))
    lunatest.assert_equal(30, Model.normalise_timeout(30))
    lunatest.assert_equal(30, Model.normalise_timeout('30'))
    lunatest.assert_equal(Model.MIN_TIMEOUT_S, Model.normalise_timeout(Model.MIN_TIMEOUT_S))
    lunatest.assert_equal(Model.MAX_TIMEOUT_S, Model.normalise_timeout(Model.MAX_TIMEOUT_S))
    lunatest.assert_nil(Model.normalise_timeout(Model.MIN_TIMEOUT_S - 1))
    lunatest.assert_nil(Model.normalise_timeout(Model.MAX_TIMEOUT_S + 1))
    lunatest.assert_nil(Model.normalise_timeout(12.5))
    lunatest.assert_nil(Model.normalise_timeout('soon'))
end

function test_offers()
    lunatest.assert_true(Model.offers(3, FULL))
    lunatest.assert_false(Model.offers(5, FULL))
    lunatest.assert_false(Model.offers(3, { 2, 4 }))
    lunatest.assert_false(Model.offers(nil, FULL))
end

function test_tally_has_one_entry_per_choice_zero_included()
    local tally, total = Model.tally({}, FULL)
    lunatest.assert_equal(0, total)
    lunatest.assert_equal(0, tally[2])
    lunatest.assert_equal(0, tally[3])
    lunatest.assert_equal(0, tally[4])

    tally, total = Model.tally(nil, FULL)
    lunatest.assert_equal(0, total)
    lunatest.assert_equal(0, tally[4])
end

function test_tally_counts_one_ballot_per_player_and_ignores_the_unoffered()
    local votes = ballots({ 'a=2', 'b=4', 'c=4', 'd=3' })
    votes['e'] = 5 -- a stale ballot for a count this vote does not offer
    local tally, total = Model.tally(votes, FULL)
    lunatest.assert_equal(4, total)
    lunatest.assert_equal(1, tally[2])
    lunatest.assert_equal(1, tally[3])
    lunatest.assert_equal(2, tally[4])

    -- The same ballots against a vote that only offers 2 and 4.
    tally, total = Model.tally(votes, { 2, 4 })
    lunatest.assert_equal(3, total)
    lunatest.assert_nil(tally[3])
end

function test_no_ballot_at_all_elects_two()
    lunatest.assert_equal(2, (Model.result({}, FULL)))
    lunatest.assert_equal(2, (Model.result(nil, FULL)))
    -- Even when the vote does not offer 2 at all: the default is the scenario's
    -- count, not a choice of the vote's.
    lunatest.assert_equal(2, (Model.result({}, { 3, 4 })))
end

function test_most_ballots_wins()
    lunatest.assert_equal(4, (Model.result(ballots({ 'a=4', 'b=4', 'c=3', 'd=2' }), FULL)))
    lunatest.assert_equal(3, (Model.result(ballots({ 'a=3', 'b=3', 'c=4' }), FULL)))
    lunatest.assert_equal(2, (Model.result(ballots({ 'a=2' }), FULL)))
end

function test_a_tie_goes_to_the_smaller_count()
    lunatest.assert_equal(2, (Model.result(ballots({ 'a=2', 'b=4' }), FULL)))
    lunatest.assert_equal(2, (Model.result(ballots({ 'a=2', 'b=2', 'c=4', 'd=4' }), FULL)))
    lunatest.assert_equal(3, (Model.result(ballots({ 'a=3', 'b=4' }), FULL)))
    lunatest.assert_equal(3, (Model.result(ballots({ 'a=3', 'b=4', 'c=3', 'd=4' }), { 3, 4 })))
end

function test_a_changed_ballot_replaces_the_first_one()
    local votes = ballots({ 'a=4', 'b=4' })
    lunatest.assert_equal(4, (Model.result(votes, FULL)))
    votes['a'] = 2
    -- 2 and 4 tied, so the smaller wins.
    lunatest.assert_equal(2, (Model.result(votes, FULL)))
    votes['b'] = 2
    lunatest.assert_equal(2, (Model.result(votes, FULL)))
end

function test_the_result_does_not_depend_on_the_order_of_the_ballots()
    -- The same twelve ballots, built under names that hash differently, must
    -- always elect 3.
    local orders = {
        { 'a=3', 'b=3', 'c=3', 'd=4', 'e=4', 'f=2' },
        { 'f=2', 'e=4', 'd=4', 'c=3', 'b=3', 'a=3' },
        { 'zzz=3', 'q=4', 'player1=3', 'player2=2', 'x=4', 'y=3' },
    }
    for i, order in ipairs(orders) do
        lunatest.assert_equal(3, (Model.result(ballots(order), FULL)), 'order ' .. i)
    end
end

function test_result_also_hands_back_the_tally_and_the_total()
    local count, tally, total = Model.result(ballots({ 'a=4', 'b=4', 'c=2' }), FULL)
    lunatest.assert_equal(4, count)
    lunatest.assert_equal(3, total)
    lunatest.assert_equal(1, tally[2])
    lunatest.assert_equal(0, tally[3])
    lunatest.assert_equal(2, tally[4])
end

lunatest.run()
