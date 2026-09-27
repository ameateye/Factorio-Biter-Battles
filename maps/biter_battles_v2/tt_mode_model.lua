-- The pure half of Triple Threat (`tt_mode.lua`): everything that is a
-- function of the round's teams and of numbers, with no `game`, no `storage`
-- write and no entity. It lives in its own module because `tt_mode.lua` calls
-- `commands.add_command` at load and therefore cannot be required outside
-- Factorio, while these answers are exactly the ones a unit test has to pin
-- (`tests/test-tt-mode.lua`).
--
-- Every function here answers for N teams and, at two teams, answers what the
-- two-team literals of `tt_mode.lua` answered before the mode grew past its
-- name: the same +-6 offsets, the same ramp arithmetic, the same `/tt-status`
-- line byte for byte.

local Teams = require('maps.biter_battles_v2.teams')
local Layout = require('maps.biter_battles_v2.layout')

local Public = {}

---The team power kit's offset from the silo, in the CANONICAL zone (the north
---side of the two-team map): six tiles east of the silo and six tiles
---*outward*, away from the river the team faces.
---
---`{ 6, -6 }` is what `tt_mode.lua` hard-coded for north; south's `{ 6, 6 }`
---is its reflection through y = 0, which is precisely `Layout.from_canonical`
---for the second team of 'horizontal2'. So the turned offset below is not a
---new convention, it is the old pair re-derived.
Public.CANONICAL_KIT_OFFSET = { x = 6, y = -6 }

---Where a team's power chest and energy interface sit relative to ITS silo:
---the canonical offset carried into the team's square (reflected with two
---teams, mirrored or half-turned by quadrant on the four-square map).
---
---`from_canonical` is linear -- a negation, never a cosine -- so
---applying it to a difference of positions is the same transform as applying
---it to a position, and with two teams it returns the integers -6 and 6
---themselves.
---
---Two teams: north {6, -6}, south {6, 6} -- today's literals.
---Four teams: north {6, -6}, east {6, 6}, south {-6, 6}, west {-6, -6}.
---@param team string
---@return number|nil dx nil when the team has no square on this map.
---@return number|nil dy
function Public.kit_offset(team)
    return Layout.from_canonical(team, Public.CANONICAL_KIT_OFFSET.x, Public.CANONICAL_KIT_OFFSET.y)
end

---The difficulty ramp above the 80% floor at minute `t`, given the minute the
---first laser turret was built (`laser_at_min`, nil while none was).
---
---Lifted verbatim out of `Public.update_ramp`: +5%/min from minute 60, and
---+3%/min FORWARD from the first laser, never applied backwards to the minutes
---already ramped at +5%/min. Team-count independent by construction -- it
---reads a clock and a latch, nothing per team.
---@param t number Minutes since the game started.
---@param laser_at_min number|nil
---@return number ramp
function Public.ramp(t, laser_at_min)
    local ramp = 0
    if t > 60 then
        local tl = laser_at_min
        if tl then
            if tl < 60 then
                tl = 60
            end
            if t <= tl then
                ramp = (t - 60) * 0.05
            else
                ramp = (tl - 60) * 0.05 + (t - tl) * 0.03
            end
        else
            ramp = (t - 60) * 0.05
        end
    end
    return ramp
end

---The biter forces `tt_recompute_all` restates the evolution of, in ring order.
---
---Two teams: every active biter force, i.e. today's pair -- a two-team round
---ends the moment a team is eliminated, so restating both is what the old
---`pairs(BIT_TEAMS)` did. Above two teams an eliminated team's biters are left
---where they were: the team no longer feeds and is no longer fed, so replaying
---its mutagen would be restating a number that cannot move again.
---@return string[]
function Public.recompute_forces()
    if Teams.count() == 2 then
        return Teams.biter_forces()
    end
    return Teams.alive_biter_forces()
end

---The one-letter column head a team gets in `/tt-status`: N, S, E, W -- the
---initial of the force name, upper-cased. With two teams that is the `N=` and
---`S=` of the line this command has always printed.
---@param team string
---@return string
function Public.column(team)
    return string.upper(string.sub(team, 1, 1))
end

---One `/tt-status` column group: ' N=<v> S=<v>' over the teams given.
---@param teams string[]
---@param value fun(team: string): string
---@return string
local function columns(teams, value)
    local parts = {}
    for i = 1, #teams do
        parts[i] = Public.column(teams[i]) .. '=' .. value(teams[i])
    end
    return table.concat(parts, ' ')
end

---The `/tt-status` line, one column per active team instead of the two fixed
---slots of INVENTORY §2.13.
---
---With two teams this rebuilds the old `string.format` output character for
---character: the same two leading spaces between groups, the same single space
---between the `N=` and `S=` columns, `%.1f%%`, `%.3f` and the `tostring` of a
---boolean-or-nil in the same places.
---@param teams string[] Active teams in ring order.
---@param mode string 'ON' or 'OFF'.
---@param diff number The difficulty vote value (0.8 = 80%).
---@param laser string 'YES' or 'NO'.
---@param raw fun(team: string): number Raw mutagen fed to that team's biters.
---@param bonus fun(team: string): any The team's power-bonus latch, as stored.
---@param eei fun(team: string): string The team's interface state.
---@return string
function Public.status_line(teams, mode, diff, laser, raw, bonus, eei)
    local raw_columns = columns(teams, function(team)
        return string.format('%.3f', raw(team))
    end)
    local bonus_columns = columns(teams, function(team)
        return tostring(bonus(team) == true)
    end)
    return string.format(
        '[TT] mode=%s  diff=%.1f%%  laser_placed=%s  raw_mutagen %s  power_bonus %s  eei %s',
        mode,
        diff * 100,
        laser,
        raw_columns,
        bonus_columns,
        columns(teams, eei)
    )
end

-- ---------------------------------------------------------------------------
-- What the mode says in chat
-- ---------------------------------------------------------------------------

---The mode's name in its chat announcements. 'Triple Threat (3v3)' is the name
---it was born with and keeps at two teams, byte for byte; above two teams a
---format in the name is simply wrong (the round is a '2v2v2', a '1v1v1v1'), so
---the name drops it.
---@param count integer The round's team count.
---@return string
function Public.mode_label(count)
    if count > 2 then
        return 'Triple Threat'
    end
    return 'Triple Threat (3v3)'
end

---'>> [TT] north team built first laser-turret — ...', the bonus announcement.
---Two teams keep the force name they have always printed; above two teams the
---team is named as everywhere else on the four-square map ('Top Right').
---@param team string The force name.
---@param count integer The round's team count.
---@param title string|nil The team's display name (used above two teams).
---@return string
function Public.laser_bonus_line(team, count, title)
    local who = team
    if count > 2 and title then
        who = title
    end
    return '>> [TT] '
        .. who
        .. ' team built first laser-turret — +50 MW bonus power live at the pre-placed power interface next to your silo.'
end

-- ---------------------------------------------------------------------------
-- The League's settings
-- ---------------------------------------------------------------------------

---What the BB League server plays differently in `storage.bb_settings`
---(`init.lua` ships the table; the Config tab of the admin panel toggles it).
---
---Read at the moment Triple Threat is turned ON from off -- `/tt-enable`, which
---the League's match-prep daemon sends before every match and which is what
---identifies the League (`FeedingParams.is_league`). The League starts a fresh
---scenario at each restart, so a setting its admins had toggled was lost with
---the restart and had to be toggled again (2026-09-27): these are the values
---they had been re-applying, made the shipped ones. Applied on the transition
---only, so they are defaults and not a lock -- an admin who moves one after
---that keeps it for the session, and the next `/tt-enable` (Triple Threat
---already on) leaves it alone. Off the League nothing reads this table.
---
---Automatic captain: the poll at game over that starts a captain game when
---enough players are on. The League's matches are made by its daemon, never
---by a poll.
Public.league_bb_settings = {
    automatic_captain = false,
}

---Write the League's settings into `settings` (a `bb_settings` table), and say
---which ones moved. Pure: the caller hands the table in and prints the answer.
---A setting already at the League's value is left alone and not reported; one
---the table does not carry yet is set, since the table then predates it.
---@param settings table|nil
---@return string[] moved `name = value` for each setting that changed, in a fixed order.
function Public.apply_league_settings(settings)
    local moved = {}
    if type(settings) ~= 'table' then
        return moved
    end
    local names = {}
    for name in pairs(Public.league_bb_settings) do
        names[#names + 1] = name
    end
    table.sort(names)
    for _, name in ipairs(names) do
        local value = Public.league_bb_settings[name]
        if settings[name] ~= value then
            settings[name] = value
            moved[#moved + 1] = string.format('%s = %s', name, tostring(value))
        end
    end
    return moved
end

return Public
