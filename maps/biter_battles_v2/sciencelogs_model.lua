-- What the science-log tab (`sciencelogs_tab.lua`) shows above two teams,
-- without touching a single GUI element.
--
-- Two teams keep the tab they have always had: `draw_legacy_summary_rows()` in
-- the tab draws the summary block and the force filter carries today's force
-- names, and nothing here is consulted. Above two teams the same block is drawn
-- from `columns()`, which keeps every element name and every cell of it and
-- changes only the heading -- the round's display name in the team's colour,
-- because a compass name is not what the four-square map calls that team
-- anywhere else -- and the filter carries display names, read back by position.
--
-- It is pure: it reads the round through `teams.lua` (which itself needs only
-- `config.lua` and `utils/force.lua`) and touches neither `game`, `storage` nor
-- any GUI, so `tests/test-sciencelogs-multiteam.lua` can pin all of it outside
-- Factorio -- including the two-team answers, which is how the element names of
-- a tab the client gate does not dump are held to today's.

local Teams = require('maps.biter_battles_v2.teams')

local Public = {}

--- Storage key of a team's running totals, one array per team under today's
--- key name (`feeding.lua`, `init.lua`, `team_stats_collect.lua`).
---@param team string
---@return string
function Public.totals_key(team)
    return 'science_logs_total_' .. team
end

--- The heading of a team that is out of the round, in the grey the main GUI
--- marks an eliminated team with (`gui.lua`'s 'out' label, { 180, 180, 180 }).
Public.OUT_COLOR = { r = 180 / 255, g = 180 / 255, b = 180 / 255 }

--- The heading of a team whose colour the roster does not know. `all()` only
--- ever hands out roster teams, so this is insurance against a nil `font_color`,
--- which is a hard error where a wrong colour is only ugly (same guard, same
--- value as `gui.lua:70`).
local UNKNOWN_COLOR = { r = 225 / 255, g = 225 / 255, b = 225 / 255 }

---@class ScienceLogColumn
---@field team string The force name of the team the row totals.
---@field key string Storage key of its totals array.
---@field header_name string Element name of the heading label.
---@field cell_prefix string Element name of cell `i` is this .. i.
---@field caption string What the heading says.
---@field color { r: number, g: number, b: number } Font colour of the heading, components in 0..1.
---@field alive boolean False for a team that is out of the round.

--- One entry per active team in ring order -- the rows of the summary block,
--- top to bottom. A team that is out of the round keeps its row: what it sent
--- while it played is part of the round's story, and the grey heading is what
--- says it is gone.
---
--- The element names are today's rule, the one the two-team tab has always
--- followed: `<key>_header` for the heading, and `<key>_` .. i for the cells of
--- the first row against `<key>` .. i for every row below it (INVENTORY defect,
--- kept so that the two-team names stay byte-identical -- the first row
--- separates, the rows below it do not).
---@return ScienceLogColumn[]
function Public.columns()
    local teams = Teams.all()
    local columns = {}
    for i = 1, #teams do
        local team = teams[i]
        local key = Public.totals_key(team)
        local alive = Teams.is_alive(team)
        local color = Public.OUT_COLOR
        if alive then
            local rgb = Teams.color(team)
            color = rgb and { r = rgb.r / 255, g = rgb.g / 255, b = rgb.b / 255 } or UNKNOWN_COLOR
        end
        columns[i] = {
            team = team,
            key = key,
            header_name = key .. '_header',
            cell_prefix = key .. (i == 1 and '_' or ''),
            caption = 'Total sent by ' .. Teams.display_name(team),
            color = color,
            alive = alive,
        }
    end
    return columns
end

--- The entries of the tab's force filter: the caller's 'all teams' entry first
--- -- index 1 is what the tab reads as "no filter" -- then one per active team
--- in ring order.
---
--- With two teams the entries are the force names, so the list is
--- `Tables.forces_list` itself and the tab keeps matching a row against the
--- entry's text. Above two teams they are the names the round shows everywhere
--- else, and `filtered_team()` reads the choice back instead.
---@param all_teams_label string The registry's first entry, `Tables.forces_list[1]`.
---@return string[]
function Public.force_filter_items(all_teams_label)
    local teams = Teams.all()
    local two_teams = Teams.count() == 2
    local items = { all_teams_label }
    for i = 1, #teams do
        items[i + 1] = two_teams and teams[i] or Teams.display_name(teams[i])
    end
    return items
end

--- The team a filter entry stands for, or nil for 'all teams' and for an index
--- outside the list -- both of which mean "show every row".
---
--- Position, not text: a display name is not a Lua pattern (a custom name may
--- carry '-', '%' or '('), and two teams may be given the same one, so the
--- entry a player picked is the only thing that says which team they meant.
---@param selected_index any The drop-down's `selected_index`.
---@return string|nil
function Public.filtered_team(selected_index)
    if type(selected_index) ~= 'number' then
        return nil
    end
    local teams = Teams.all()
    local at = selected_index - 1
    if at < 1 or at > #teams then
        return nil
    end
    return teams[at]
end

return Public
