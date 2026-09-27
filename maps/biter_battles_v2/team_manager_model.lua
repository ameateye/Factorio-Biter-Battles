-- What the admin's team manager window shows above two teams, without touching
-- a single GUI element.
--
-- Two teams keep the window they have always had: three columns with the +-1
-- arrow chain between them, built by `force_chain()` in `team_manager.lua` and
-- untouched by this module. Above two teams the chain is replaced by one column
-- per team plus the spectators, and every player entry carries its own row of
-- destination buttons -- one click per move instead of a walk through the teams
-- in between. This module is that layout as data: which columns, which
-- destinations an entry in a given column offers, what a button is captioned
-- and how a click names its target.
--
-- It is pure: it reads the round through `teams.lua` (which itself needs only
-- `config.lua` and `utils/force.lua`) and touches neither `game` nor any GUI,
-- so `tests/test-team-manager-multiteam.lua` can pin all of it outside
-- Factorio.

local Teams = require('maps.biter_battles_v2.teams')

local Public = {}

--- The force the spectators sit on. It is not a team, so it is not in
--- `Teams.all()` and has no roster colour; the window gives it the grey the
--- chain's spectator button has always had.
Public.SPECTATOR = 'spectator'

--- The two tag keys a destination button carries: where the click sends the
--- player, and which player it sends. Names are used for nothing but telling
--- siblings apart -- a player name may contain dots, dashes and underscores, so
--- splitting one out of an element name is guesswork, while a tag is exact.
Public.DESTINATION_TAG = 'team_manager_destination'
Public.PLAYER_TAG = 'team_manager_player'

--- How many characters of a display name fit on a destination button. Four
--- buttons stand side by side in a column, so a caption is an abbreviation
--- unless the name is this short.
local CAPTION_BUDGET = 4

--- Bytes of the UTF-8 sequence that starts with `byte`. A custom team name may
--- be written in any alphabet and must not be cut in half.
---@param byte integer|nil
---@return integer
local function char_bytes(byte)
    if not byte then
        return 1
    end
    if byte >= 0xF0 then
        return 4
    end
    if byte >= 0xE0 then
        return 3
    end
    if byte >= 0xC0 then
        return 2
    end
    return 1
end

--- The first `count` characters of `text` -- characters, not bytes.
---@param text string
---@param count integer
---@return string
local function first_chars(text, count)
    local length = #text
    local at = 1
    local taken = 0
    while at <= length and taken < count do
        at = at + char_bytes(string.byte(text, at))
        taken = taken + 1
    end
    return string.sub(text, 1, at - 1)
end

--- The caption of a destination button: the display name itself when it fits,
--- else the initials of its words (upper case), else the first letters of the
--- one word it is. A name that is nothing but spaces answers '?', because a
--- button with no caption cannot be clicked on purpose.
---@param display_name string
---@return string
function Public.abbreviate(display_name)
    local name = string.match(display_name, '^%s*(.-)%s*$')
    if name == '' then
        return '?'
    end
    local fitted = first_chars(name, CAPTION_BUDGET)
    if fitted == name then
        return name
    end
    local initials = {}
    for word in string.gmatch(name, '[^%s_%-]+') do
        initials[#initials + 1] = string.upper(first_chars(word, 1))
        if #initials == CAPTION_BUDGET then
            break
        end
    end
    if #initials >= 2 then
        return table.concat(initials)
    end
    return fitted
end

---@class TeamManagerColumn
---@field force string The force the column lists: a team of the round, or 'spectator'.
---@field spectator boolean True for the one spectator column.
---@field display string The display name, custom name included.
---@field caption string What the column header says: the display name, upper case.
---@field color { r: integer, g: integer, b: integer }|nil The team colour; nil for the spectators.
---@field alive boolean False for a team that is out of the round.

--- The columns of the window, left to right: the teams of the round in ring
--- order, then the spectators. A team that is out of the round is still a
--- column -- its players have been moved to the spectators, but an admin still
--- has to see that the team is there and out.
---@return TeamManagerColumn[]
function Public.columns()
    local teams = Teams.all()
    local columns = {}
    for i = 1, #teams do
        local team = teams[i]
        local display = Teams.display_name(team)
        columns[i] = {
            force = team,
            spectator = false,
            display = display,
            caption = string.upper(display),
            color = Teams.color(team),
            alive = Teams.is_alive(team),
        }
    end
    local display = Teams.display_name(Public.SPECTATOR)
    columns[#columns + 1] = {
        force = Public.SPECTATOR,
        spectator = true,
        display = display,
        caption = string.upper(display),
        color = nil,
        alive = true,
    }
    return columns
end

---@class TeamManagerDestination
---@field force string Where the button sends the player.
---@field caption string The abbreviated display name on the button.
---@field tooltip string 'Move to <display name>'.
---@field color { r: integer, g: integer, b: integer }|nil The team colour; nil for the spectators.

--- The buttons every entry of the `from_force` column gets: the other teams of
--- the round that are still alive, in ring order, then the spectators. A team
--- that is out of the round is not a destination -- joining it teleports the
--- player into a quarter with no base and no silo -- and no column offers a
--- button back to itself.
---@param from_force string The force whose column the entry sits in.
---@return TeamManagerDestination[]
function Public.destinations(from_force)
    local teams = Teams.all()
    local destinations = {}
    for i = 1, #teams do
        local team = teams[i]
        if team ~= from_force and Teams.is_alive(team) then
            local display = Teams.display_name(team)
            destinations[#destinations + 1] = {
                force = team,
                caption = Public.abbreviate(display),
                tooltip = 'Move to ' .. display,
                color = Teams.color(team),
            }
        end
    end
    if from_force ~= Public.SPECTATOR then
        local display = Teams.display_name(Public.SPECTATOR)
        destinations[#destinations + 1] = {
            force = Public.SPECTATOR,
            caption = Public.abbreviate(display),
            tooltip = 'Move to ' .. display,
            color = nil,
        }
    end
    return destinations
end

--- True while a click on a button for `force_name` may still be carried out: an
--- alive team of the round, or the spectators. The window is rebuilt when the
--- team count changes but not when a team dies, so a button can outlive its
--- destination -- and a dormant `east` force left behind by an earlier round is
--- a force that exists and must never receive a player.
---@param force_name any
---@return boolean
function Public.is_available_destination(force_name)
    if force_name == Public.SPECTATOR then
        return true
    end
    return Teams.is_active(force_name) and Teams.is_alive(force_name)
end

--- The tags of the destination button that sends `player_name` to `destination`.
---@param destination string
---@param player_name string
---@return table
function Public.button_tags(destination, player_name)
    return {
        [Public.DESTINATION_TAG] = destination,
        [Public.PLAYER_TAG] = player_name,
    }
end

--- Read a click back: the destination and the player of a destination button,
--- or nil for every other element. Well-formedness only -- whether the
--- destination is still part of the round is `is_available_destination`.
---@param tags any The `tags` of the clicked element.
---@return string|nil destination
---@return string|nil player_name
function Public.parse_click(tags)
    if type(tags) ~= 'table' then
        return nil
    end
    local destination = tags[Public.DESTINATION_TAG]
    local player_name = tags[Public.PLAYER_TAG]
    if type(destination) ~= 'string' or type(player_name) ~= 'string' then
        return nil
    end
    if destination == '' or player_name == '' then
        return nil
    end
    return destination, player_name
end

--- The element name of a column's player list. One per force, so the columns
--- of the window are addressable.
---@param force_name string
---@return string
function Public.column_name(force_name)
    return 'team_manager_players_' .. force_name
end

--- The element name of one player's entry inside a column. Players are unique
--- within a force, so the entries of a column are.
---@param player_name string
---@return string
function Public.entry_name(player_name)
    return 'team_manager_entry_' .. player_name
end

--- The element name of a destination button inside an entry. One per
--- destination, so the buttons of an entry are unique -- and the pair
--- (entry, button) says who goes where without a tag being read.
---@param destination string
---@return string
function Public.move_button_name(destination)
    return 'team_manager_move_' .. destination
end

return Public
