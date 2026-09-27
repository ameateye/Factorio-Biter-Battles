-- The pure half of the CAPTAIN VOTE window (with more than two eligible
-- captains, vote for how many captains the game has, 2 minimum, and which
-- candidates to kick, by a 50 % majority). Nothing here touches `game`,
-- `storage`, `remote` or the GUI, so it loads outside Factorio and is
-- unit-tested by `tests/test-captain-vote.lua`.
--
-- The window only COLLECTS ballots and shows a live preview. The decision that
-- counts is taken by the captain orchestrator (league side), from the raw
-- ballots `captain_vote_result` hands it, with the SAME rules as below -- the
-- two are pinned on the same vectors.
--
-- The rules:
--   * the ELECTORATE is the called players the daemon names at open time who
--     are connected (`present`); a ballot of anybody else is never counted;
--   * the COUNT: one ballot per voter, changeable; most ballots wins, a TIE
--     goes to the SMALLER count (the League's team-count rule), no ballot at
--     all elects the `default_n` the daemon passed (today's derived count);
--   * the KICK: a candidate is out when the kick ballots against him reach
--     HALF of the present electorate other than himself (votes * 2 >= voters),
--     with at least one ballot. Nobody can vote to kick himself.
-- Every walk that decides something is `ipairs` over an ordered list, and the
-- counts are integer `+ 1`, so the answer is the same on every peer whatever
-- order `pairs` hands the ballots out in.

local Public = {}

Public.CHOICES = { 2, 3, 4 }
Public.MIN_TIMEOUT_S = 10
Public.MAX_TIMEOUT_S = 600
Public.DEFAULT_TIMEOUT_S = 60
Public.MAX_CANDIDATES = 4
Public.MAX_VOTERS = 40

---@param list any
---@param limit integer
---@return string[]|nil
---@return string|nil reason
local function name_list(list, limit)
    if type(list) ~= 'table' then
        return nil, 'expected an array of player names'
    end
    local out, seen = {}, {}
    for _, v in ipairs(list) do
        if type(v) ~= 'string' or v == '' or #v > 60 then
            return nil, 'a player name must be a non-empty string'
        end
        if not seen[v] then
            seen[v] = true
            out[#out + 1] = v
        end
    end
    if #out > limit then
        return nil, 'too many names (at most ' .. limit .. ')'
    end
    return out
end

---Validate and normalise the options of an open.
---`{ timeout_s, choices = {2,3,4 subset}, cands = {3..4 names}, voters = {names}, default_n, game }`
---@param options any
---@return table|nil vote fields (without state/ballots)
---@return string|nil reason
function Public.normalise_open(options)
    if type(options) ~= 'table' then
        return nil, 'open_captain_vote takes a table of options'
    end
    local seconds = options.timeout_s
    if seconds == nil then
        seconds = Public.DEFAULT_TIMEOUT_S
    end
    seconds = tonumber(seconds)
    if not seconds or seconds ~= math.floor(seconds) then
        return nil, 'the countdown must be a whole number of seconds'
    end
    if seconds < Public.MIN_TIMEOUT_S or seconds > Public.MAX_TIMEOUT_S then
        return nil,
            'the countdown must be between ' .. Public.MIN_TIMEOUT_S .. ' and ' .. Public.MAX_TIMEOUT_S .. ' seconds'
    end

    local cands, reason = name_list(options.cands, Public.MAX_CANDIDATES)
    if not cands then
        return nil, 'cands: ' .. reason
    end
    if #cands < 3 then
        return nil, 'a captain vote needs at least 3 candidates'
    end
    local voters
    voters, reason = name_list(options.voters, Public.MAX_VOTERS)
    if not voters then
        return nil, 'voters: ' .. reason
    end
    if #voters == 0 then
        return nil, 'a captain vote needs voters'
    end

    local seen = {}
    if type(options.choices) ~= 'table' then
        return nil, 'choices must be an array of captain counts'
    end
    for _, value in ipairs(options.choices) do
        local n = tonumber(value)
        if n ~= 2 and n ~= 3 and n ~= 4 then
            return nil, 'a captain vote can only offer 2, 3 or 4 captains'
        end
        if n > #cands then
            return nil, 'cannot offer ' .. n .. ' captains with ' .. #cands .. ' candidates'
        end
        seen[n] = true
    end
    local choices = {}
    for _, c in ipairs(Public.CHOICES) do
        if seen[c] then
            choices[#choices + 1] = c
        end
    end
    if #choices == 0 then
        return nil, 'a captain vote must offer at least one captain count'
    end
    local default_n = tonumber(options.default_n)
    if not default_n or not seen[default_n] then
        default_n = choices[1]
    end
    local game_id = tonumber(options.game) or 0
    return {
        seconds = seconds,
        cands = cands,
        voters = voters,
        choices = choices,
        default_n = default_n,
        game = math.floor(game_id),
    }
end

---@param list string[]
---@param name string
---@return boolean
function Public.has(list, name)
    for _, v in ipairs(list) do
        if v == name then
            return true
        end
    end
    return false
end

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

---The present electorate as a set.
---@param present string[]
---@return table<string, boolean>
local function set_of(present)
    local s = {}
    for _, n in ipairs(present) do
        s[n] = true
    end
    return s
end

---Count ballots per offered choice, present voters only.
---@param counts table<string, integer>
---@param choices integer[]
---@param present string[]
---@return table<integer, integer> tally
---@return integer total
function Public.tally(counts, choices, present)
    local here = set_of(present)
    local tally = {}
    for _, c in ipairs(choices) do
        tally[c] = 0
    end
    local total = 0
    for _, voter in ipairs(present) do
        local c = counts[voter]
        if here[voter] and c and tally[c] then
            tally[c] = tally[c] + 1
            total = total + 1
        end
    end
    return tally, total
end

---The elected count: most ballots, a tie to the smaller, `default_n` with none.
---@return integer
function Public.elected(counts, choices, present, default_n)
    local tally, total = Public.tally(counts, choices, present)
    if total == 0 then
        return default_n
    end
    local best = choices[1]
    for _, c in ipairs(choices) do
        if tally[c] > tally[best] then
            best = c
        end
    end
    return best
end

---Votes needed to kick `cand`: half of the present electorate other than him.
---@param cand string
---@param present string[]
---@return integer need
function Public.need(cand, present)
    local k = 0
    for _, v in ipairs(present) do
        if v ~= cand then
            k = k + 1
        end
    end
    local need = math.ceil(k / 2)
    if need < 1 then
        need = 1
    end
    return need
end

---Kick ballots against each candidate, present voters only, never his own.
---@param kicks table<string, table<string, boolean>> voter -> set of candidates
---@param cands string[]
---@param present string[]
---@return table<string, integer>
function Public.kick_tally(kicks, cands, present)
    local out = {}
    for _, c in ipairs(cands) do
        out[c] = 0
    end
    for _, voter in ipairs(present) do
        local mine = kicks[voter]
        if mine then
            for _, c in ipairs(cands) do
                if c ~= voter and mine[c] then
                    out[c] = out[c] + 1
                end
            end
        end
    end
    return out
end

---The candidates the ballots kick, in candidate order.
---@return string[]
function Public.kicked(kicks, cands, present)
    local t = Public.kick_tally(kicks, cands, present)
    local out = {}
    for _, c in ipairs(cands) do
        if t[c] >= Public.need(c, present) then
            out[#out + 1] = c
        end
    end
    return out
end

---The preview the window shows: the elected count and the kept candidates.
---It does NOT refill or re-cut the count against the kept list -- the daemon
---does, and announces the result.
---@return integer n
---@return string[] kept
function Public.preview(vote, present)
    local out = Public.kicked(vote.kicks, vote.cands, present)
    local gone = {}
    for _, c in ipairs(out) do
        gone[c] = true
    end
    local kept = {}
    for _, c in ipairs(vote.cands) do
        if not gone[c] then
            kept[#kept + 1] = c
        end
    end
    return Public.elected(vote.counts, vote.choices, present, vote.default_n), kept
end

return Public
