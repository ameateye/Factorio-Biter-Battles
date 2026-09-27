-- The few sentences outside the game over that name the other team -- the spy
-- fish announcement, the "no longer spectating" line, the map intro, two
-- tooltips -- in the words of a round of more than two teams.
--
-- Pure: every function is handed the team count, the layout or the titles and
-- returns strings. No `game`, no `storage`, no registry, so
-- `tests/test-nteam-wording.lua` pins every sentence without Factorio; the
-- callers look the arguments up.
--
-- At two teams each function returns the literal its caller printed before,
-- byte for byte: that is what keeps the two-team game identical to its
-- baseline.

local Public = {}

---'bob sent 3 fish to spy on south team!' -- the chat line of a spy fish.
---
---Two teams: the enemy's force name, as always. Above two teams a fish buys
---vision on every alive enemy at once, so the line names them all by their
---titles ('Top Right, Bottom Right teams'); one enemy left is 'team', and with
---none (cannot happen from the fish path, but the line must not raise) it is
---'enemy team'.
---@param player_name string
---@param amount integer
---@param count integer The round's team count.
---@param enemy string|nil Two teams: the enemy's force name.
---@param enemy_titles string[]|nil Above two teams: the alive enemies' titles.
---@return string
function Public.spy_fish_message(player_name, amount, count, enemy, enemy_titles)
    local target
    if count > 2 then
        local titles = enemy_titles or {}
        if #titles == 0 then
            target = 'enemy team'
        elseif #titles == 1 then
            target = titles[1] .. ' team'
        else
            target = table.concat(titles, ', ') .. ' teams'
        end
    else
        target = tostring(enemy) .. ' team'
    end
    return player_name .. ' sent ' .. amount .. ' fish to spy on ' .. target .. '!'
end

---'Team north player bob is no longer spectating.' for the chat and for
---Discord. Two teams: the force name in both, as always. Above two teams the
---chat line carries the team's coloured title; the Discord line keeps the force
---name on every team count -- it is relayed through the server log, and a line
---a bot may parse keeps its shape.
---@param force_name string
---@param player_name string
---@param count integer The round's team count.
---@param colored_title string|nil The team's display name inside its colour tag.
---@return string chat
---@return string discord
function Public.spectating_messages(force_name, player_name, count, colored_title)
    local raw = table.concat({ 'Team ', force_name, ' player ', player_name, ' is no longer spectating.' })
    if count > 2 and colored_title then
        return table.concat({ 'Team ', colored_title, ' player ', player_name, ' is no longer spectating.' }), raw
    end
    return raw, raw
end

---The locale key of the map intro window: today's text on the two-team map,
---a four-square text (no horizontal river, no North and South) on 'cross4'.
---@param layout string|nil 'horizontal2' or 'cross4'.
---@return string
function Public.map_info_key(layout)
    if layout == 'cross4' then
        return 'biter_battles.map_info_cross4'
    end
    return 'biter_battles.map_info'
end

---The tooltip of the Apply button of the Evo and threat setup tab.
---@param count integer The round's team count.
---@return string
function Public.apply_tooltip(count)
    return 'Apply every box that differs from the value in force, to the format selected above. An emptied'
        .. ' box stops this format overriding that parameter, dropping it back to the Default column.'
        .. (count > 2 and ' Announced to all teams.' or ' Announced to both teams.')
end

---The tooltip of the Team Balancing switch. Above two teams the rule compares
---with the smallest other team still playing (gui.lua `is_over_balance_limit`).
---@param count integer The round's team count.
---@return string
function Public.balancing_tooltip(count)
    if count > 2 then
        return 'Players can only join a team that has less or equal players than the smallest other team.'
    end
    return 'Players can only join a team that has less or equal players than the opposing.'
end

return Public
