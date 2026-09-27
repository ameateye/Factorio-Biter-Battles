-- The pure part of a captain game with 3 or 4 captains.
--
-- `captainList[i]` is the captain of the i-th team of the round, `Teams.all()`
-- order; at two teams that is today's north = 1, south = 2. Nothing here reads
-- `game` or `storage`: captain.lua passes the round's teams and counts in, and
-- only calls into this module above two teams, so the two-team game does not
-- depend on it (tests/test-captain-teams.lua).

local Public = {}

local TITLES = { north = 'North', east = 'East', south = 'South', west = 'West' }

---A copy of `list` starting at its (k+1)-th entry.
---@param list string[]
---@param k integer
---@return string[]
function Public.rotate(list, k)
    local out, n = {}, #list
    for i = 1, n do
        out[i] = list[((i - 1 + k) % n) + 1]
    end
    return out
end

---Fisher-Yates on a copy; `rnd(a, b)` is math.random's signature.
---@param list string[]
---@param rnd fun(a: integer, b: integer): integer
---@return string[]
function Public.shuffle(list, rnd)
    local out = {}
    for i, v in ipairs(list) do
        out[i] = v
    end
    for i = #out, 2, -1 do
        local j = rnd(1, i)
        out[i], out[j] = out[j], out[i]
    end
    return out
end

---A snake over `order`: 1,2,..,N,N,..,2,1,1,2,..
---@param order string[]
---@return table snake
function Public.new_snake(order)
    local copy = {}
    for i, v in ipairs(order) do
        copy[i] = v
    end
    return { order = copy, pos = 0, dir = 1 }
end

local function min_count(order, counts)
    local m
    for _, t in ipairs(order) do
        local c = counts[t] or 0
        if m == nil or c < m then
            m = c
        end
    end
    return m or 0
end

---The team that has the smallest count, ties by `order`.
---@param order string[]
---@param counts table<string, integer>
---@return string
function Public.fewest(order, counts)
    local m = min_count(order, counts)
    for _, t in ipairs(order) do
        if (counts[t] or 0) == m then
            return t
        end
    end
    return order[1]
end

local function step(snake)
    local n = #snake.order
    if snake.pos == 0 then
        snake.pos = 1
        return
    end
    local nxt = snake.pos + snake.dir
    if nxt < 1 or nxt > n then
        -- the end team picks twice in a row; the snake turns round
        snake.dir = -snake.dir
    else
        snake.pos = nxt
    end
end

---Advance the snake to the next team allowed to pick. A team that already
---has more players than the smallest team is skipped (a group was picked),
---which is the 2-team catch-up rule generalised. Mutates `snake`.
---@param snake table
---@param counts table<string, integer>
---@return string team
function Public.snake_next(snake, counts)
    local m = min_count(snake.order, counts)
    for _ = 1, 2 * #snake.order + 2 do
        step(snake)
        local t = snake.order[snake.pos]
        if (counts[t] or 0) <= m then
            return t
        end
    end
    return Public.fewest(snake.order, counts)
end

---@param teams string[]
---@param team string
---@return integer|nil
function Public.captain_index(teams, team)
    for i, t in ipairs(teams) do
        if t == team then
            return i
        end
    end
    return nil
end

---The team a captain or vice-captain belongs to, nil for anybody else.
---@param captain_list string[]
---@param vice table<string, table<string, boolean>>
---@param teams string[]
---@param name string
---@return string|nil
function Public.captain_team(captain_list, vice, teams, name)
    for i, t in ipairs(teams) do
        if captain_list[i] == name or (vice[t] and vice[t][name]) then
            return t
        end
    end
    return nil
end

---Only the first `count` names of the list are captains (the rest are
---volunteers until the automatic start trims the list).
---@param captain_list string[]
---@param count integer
---@param name string
---@return boolean
function Public.is_captain(captain_list, count, name)
    for i = 1, count do
        if captain_list[i] == name then
            return true
        end
    end
    return false
end

---What the automatic start does when its countdown reaches 0. At two teams
---these are today's literal thresholds (captain.lua decrement token).
---@param n_captains integer
---@param n_players integer
---@param count integer
---@return string 'too_few_captains'|'too_few_players'|'start'|'too_many'
function Public.auto_start_verdict(n_captains, n_players, count)
    if n_captains < count then
        return 'too_few_captains'
    elseif n_captains == count then
        if n_players < count then
            return 'too_few_players'
        end
        return 'start'
    end
    return 'too_many'
end

---@param team string
---@return string
function Public.title(team)
    return TITLES[team] or team
end

---"Team ann (North) vs Team bob (East) vs Team West"
---@param captain_list string[]
---@param teams string[]
---@return string
function Public.vs_text(captain_list, teams)
    local parts = {}
    for i, t in ipairs(teams) do
        if captain_list[i] then
            parts[i] = 'Team ' .. tostring(captain_list[i]) .. ' (' .. Public.title(t) .. ')'
        else
            parts[i] = 'Team ' .. Public.title(t)
        end
    end
    return table.concat(parts, ' vs ')
end

return Public
