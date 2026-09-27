-- The pure half of the "number of teams for this match" vote:
-- what a ballot is worth, what the tally is, and which count a set of ballots
-- elects. Nothing here touches `game`, `storage`, `remote` or the GUI, so it
-- loads outside Factorio and is unit-tested by `tests/test-count-vote.lua`.
--
-- The rules:
--   * the choices are 2, 3 and 4 -- a caller may offer a subset, never anything
--     else, and the list is always sorted ascending so that the window's three
--     buttons and the tallies of `count_vote_result` are in `ipairs` order on
--     every peer;
--   * one ballot per player, changeable until the vote closes;
--   * the winner is the choice with the most ballots; a TIE goes to the SMALLER
--     count, and no ballot at all means 2 -- so a vote nobody answers leaves the
--     scenario at its default and a two-team server is never surprised.
--
-- The tally is a table of integers keyed by choice, filled by `+ 1`: integer
-- addition, so the order the ballots are walked in cannot change the result and
-- `pairs` over the ballots is safe here (the ORDER-sensitive walk, the one that
-- picks the winner, is `ipairs` over the sorted choices).

local Public = {}

--- The counts a round can be played with, ascending. `Teams.set_next_count` is
--- the authority on the value; this list is what the window may OFFER.
Public.CHOICES = { 2, 3, 4 }

--- What a vote with no ballot elects.
Public.DEFAULT_COUNT = 2

--- Bounds on the countdown, in seconds: long enough for a window to be read,
--- short enough that a mistyped `/team-count vote 99999` cannot hold a match
--- prep hostage.
Public.MIN_TIMEOUT_S = 5
Public.MAX_TIMEOUT_S = 600
Public.DEFAULT_TIMEOUT_S = 60

---@param n any
---@return boolean
local function is_choice(n)
    for _, c in ipairs(Public.CHOICES) do
        if n == c then
            return true
        end
    end
    return false
end

---Validate and normalise the list of counts a vote offers.
---@param choices any nil for the full list, otherwise an array of counts.
---@return integer[]|nil choices Ascending, without duplicates.
---@return string|nil reason Why the list was refused, when it was.
function Public.normalise_choices(choices)
    if choices == nil then
        local copy = {}
        for i, c in ipairs(Public.CHOICES) do
            copy[i] = c
        end
        return copy
    end
    if type(choices) ~= 'table' then
        return nil, 'choices must be an array of team counts'
    end

    local seen = {}
    for _, value in ipairs(choices) do
        local n = tonumber(value)
        if not n or not is_choice(n) then
            return nil, 'a vote can only offer 2, 3 or 4 teams'
        end
        seen[n] = true
    end

    -- Built by walking CHOICES, so the answer is ascending whatever order the
    -- caller wrote its list in.
    local out = {}
    for _, c in ipairs(Public.CHOICES) do
        if seen[c] then
            out[#out + 1] = c
        end
    end
    if #out == 0 then
        return nil, 'a vote must offer at least one team count'
    end
    return out
end

---Validate and normalise the countdown.
---@param timeout_s any nil for the default.
---@return integer|nil seconds
---@return string|nil reason
function Public.normalise_timeout(timeout_s)
    if timeout_s == nil then
        return Public.DEFAULT_TIMEOUT_S
    end
    local n = tonumber(timeout_s)
    if not n or n ~= math.floor(n) then
        return nil, 'the countdown must be a whole number of seconds'
    end
    if n < Public.MIN_TIMEOUT_S or n > Public.MAX_TIMEOUT_S then
        return nil,
            'the countdown must be between ' .. Public.MIN_TIMEOUT_S .. ' and ' .. Public.MAX_TIMEOUT_S .. ' seconds'
    end
    return n
end

---Is `n` a count this vote offers?
---@param n any
---@param choices integer[]
---@return boolean
function Public.offers(n, choices)
    for _, c in ipairs(choices) do
        if n == c then
            return true
        end
    end
    return false
end

---Count the ballots.
---@param votes table<string, integer>|nil player name -> the count they voted for.
---@param choices integer[]
---@return table<integer, integer> tally One entry per offered choice, zero included.
---@return integer total
function Public.tally(votes, choices)
    local tally = {}
    for _, c in ipairs(choices) do
        tally[c] = 0
    end
    local total = 0
    if votes then
        -- Integer `+ 1` into a table keyed by choice: order-independent.
        for _, choice in pairs(votes) do
            if tally[choice] then
                tally[choice] = tally[choice] + 1
                total = total + 1
            end
        end
    end
    return tally, total
end

---Which count the ballots elect: most ballots, a tie to the smaller count, and
---the default when nobody voted.
---@param votes table<string, integer>|nil
---@param choices integer[]
---@return integer count
---@return table<integer, integer> tally
---@return integer total
function Public.result(votes, choices)
    local tally, total = Public.tally(votes, choices)
    if total == 0 then
        return Public.DEFAULT_COUNT, tally, total
    end

    -- `ipairs` over the ascending choices and a STRICT `>`: the first choice to
    -- reach the highest score keeps it, which is the smaller count on a tie.
    local best = choices[1]
    local best_votes = tally[best]
    for _, c in ipairs(choices) do
        if tally[c] > best_votes then
            best = c
            best_votes = tally[c]
        end
    end
    return best, tally, total
end

return Public
