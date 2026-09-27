-- Match format (team sizes, and how many teams), read from the league's own
-- record for this match.
--
-- The web server writes the record into the instance it booted and nothing in
-- this repository writes it; it is nil outside a league match. There is no way
-- to set it from in game: the format is a fact about the match rather than a
-- setting, and the league is the one thing that knows it. A game with no record
-- plays the 'default' parameter set, which is tunable like any other.
--
-- ===========================================================================
-- THE RECORD CONTRACT (this comment is the league daemon's reference)
-- ===========================================================================
--
-- Version 1 -- what the daemon writes today, read exactly as it always was:
--
--   storage.bb_league_match = {
--       id = 1234, ladder = '...', go_tick = 123456,
--       format = '2v2',                            -- the two team sizes
--       north = { 'a', 'b' }, south = { 'c', 'd' }, -- rosters, never read here
--   }
--
-- Version 2 -- 2 to 4 teams. `version` and `teams` are what make a record v2;
-- a record carrying neither field is a v1 record:
--
--   storage.bb_league_match = {
--       id = 1234, version = 2, ladder = '...', go_tick = 123456,
--       format = '2v2v2',              -- the team sizes joined by 'v', one per team
--       teams = {                      -- ORDERED, 2..4 entries
--           { name = 'north', players = { 'a', 'b' } },
--           { name = 'east',  players = { 'c', 'd' } },
--           { name = 'south', players = { 'e', 'f' } },
--       },
--       north = { 'a', 'b' }, south = { 'e', 'f' },  -- legacy mirror, still
--                                      -- written when #teams == 2
--   }
--
-- Version 2, the MAP form -- the same record with `teams` keyed by force name
-- instead of ordered by hand. It carries no order of its own, so the teams are
-- read in ring order; everything else is the v2 contract above:
--
--   storage.bb_league_match = {
--       id = 1234, version = 2, ladder = '...', go_tick = 123456,
--       format = '2v2v2',
--       teams = {                      -- keyed by force name, 2..4 entries
--           north = { 'a', 'b' },      -- the roster IS the value
--           south = { 'e', 'f' },
--           east  = { 'c', 'd' },
--       },
--   }
--
-- The rules this scenario applies:
--
--   * `format` is N team sizes joined by 'v', N in 2..4, and ALL SIZES MUST BE
--     EQUAL, each of them in 1..8. A two-team match keeps today's spelling
--     ('2v2'), so every v1 format reads exactly as it did. Asymmetric formats
--     ('2v2v1') are NOT played: they read as unreadable, exactly as '2v3' does
--     today, and the match plays 'default'.
--   * tolerance is unchanged: case is folded and every space is stripped
--     anywhere in the string, so ' 2V2 v 2 ' is '2v2v2'. The parts are compared
--     as strings, so '03v3' stays unreadable. Anything else -- '0v0' for a
--     record with no roster yet, a format written after this code -- is
--     unreadable and leaves the game on the 'default' set rather than stopping
--     it.
--   * `teams` is an array of 2..4 tables in play order. `name` is a roster team
--     ('north', 'east', 'south', 'west'), the names are distinct, `players` is
--     an array of strings, every team has the same number of them and that
--     number is the format's size, and `#teams` equals the number of parts of
--     `format`.
--   * the map form holds the same 2..4 teams, keyed by those same roster names
--     -- so they are distinct by construction -- with the roster array as the
--     value. As many keys as `format` has parts, every roster the format's
--     size, every player a string, and the order is the ring: the order the
--     round is played in, not the order a hash table happens to walk. A `teams`
--     field with a first element is an array; one with keys and no first
--     element is a map; an empty table is an array, and is refused for its
--     length, exactly as it was before the map form existed.
--   * ANY violation of the paragraph above is not an error: the record is read
--     as if only `format` were there, and the violation is named in the line
--     `Public.recognised()` returns. This reader never raises on the record.
--   * the parameter key stays '<size>v<size>' -- TWO parts, whatever the team
--     count (`Public.format_key()`). `storage.feeding_params` and the league's
--     tuning overrides are keyed by it, so a '2v2v2' match plays the '2v2'
--     parameter set.
--   * a `version` above 2 is read with the v2 rules and named as itself in the
--     recognition line: this reader is forward-tolerant, not a gatekeeper of
--     versions written after it.
--   * the recognition line names the form the `teams` field was read in, so an
--     operator can see which of the two the daemon wrote. A v1 record says
--     nothing about a form: it has no `teams` field, and its line is character
--     for character the one version 2 first produced.
--   * what the scenario made of the record is one line, `Public.recognised()`.
--     The daemon can read it back right after writing the record with
--     `remote.call('bb_teams', 'match_info')`, which also returns `version`,
--     `team_count`, `team_size` and `format_key`. The same line is written to
--     the log once per round -- but only when there is something new to say (a
--     record claiming version 2, a round of more than two teams, or a record
--     whose team count is not the round's), so a v1 record in a two-team round
--     logs nothing at all, exactly as before.
--
-- ===========================================================================
--
-- The rules a format imposes are not here -- they are parameters in
-- feeding_params, one set per format, retuned with /feeding-params or the Evo
-- and threat setup tab. This module only says which format is in force.

-- A leaf: `attack_clock.lua` requires nothing, registers nothing and writes
-- nothing at load, so asking it for the cadence cannot make a cycle here.
local AttackClock = require('maps.biter_battles_v2.attack_clock')
local FeedingParams = require('maps.biter_battles_v2.feeding_params')
local Teams = require('maps.biter_battles_v2.teams')

local Public = {}

local MIN_TEAM_SIZE = 1
local MAX_TEAM_SIZE = 8

---A format names one size per team, and the scenario plays 2, 3 or 4 of them.
local MIN_TEAMS = 2
local MAX_TEAMS = 4

---Today's record, the one with no `version` field at all.
local RECORD_V1 = 1

---The record version that carries a `teams` array. Anything at or above it is
---read with those rules; below it is today's record.
local RECORD_V2 = 2

---The two shapes a v2 `teams` field may be written in, spelled for the
---recognition line: the ordered array of `{ name, players }` that version 2
---first read, and the map of force name to roster. Both are version 2 and both are
---held to the same contract.
local FORM_ARRAY = 'teams as array'
local FORM_MAP = 'teams as map'

---A version outside 1..this is not a version, it is a corrupt field: it is not
---believed, and it never reaches the `%d` that renders it (Lua 5.2 raises on an
---infinity or a number out of integer range, and this reader may not raise).
local MAX_VERSION = 999

---Two teams is the game this scenario has always played. A round of more than
---that is new enough that what the league record said is worth a log line on
---its own; at two teams the log is compared against the baseline byte for byte.
local LEGACY_TEAM_COUNT = 2

local TICKS_PER_MINUTE = 3600

---The recognition line is prefixed so it can be grepped out of a server log.
local LEAGUE = '[LEAGUE] '

---How many teams the league's `format` string names and what size they all
---have, or nil if it is not a shape this scenario plays.
---
---Unreadable is nil rather than an error, and deliberately so: the league
---reports '0v0' for a record with no roster yet, and will one day report
---formats written after this code. An odd record has to leave the game playing
---the default set, not stop it.
---
---Two parts is what a v1 record carries and the answer for them is exactly the
---one the two-part pattern `^(%d+)v(%d+)$` used to give: the parts must be
---digits, they are compared AS STRINGS -- which is why '03v3' is unreadable and
---always was -- and the common size is bounded by MIN/MAX_TEAM_SIZE. So every
---format that reads today reads the same, and every two-part format that is nil
---today is still nil.
---@param format any
---@return integer|nil count Teams the format names, 2..4.
---@return integer|nil size The size every one of them has.
local function parse_format(format)
    if type(format) ~= 'string' then
        return nil
    end
    local text = format:lower():gsub('%s', '')
    local first, count = nil, 0
    -- The trailing separator turns "a v b" into a list of complete "<part>v"
    -- units, so a trailing or a doubled 'v' yields an empty part and is
    -- refused below rather than silently dropped.
    for part in (text .. 'v'):gmatch('([^v]*)v') do
        count = count + 1
        if count > MAX_TEAMS then
            return nil
        end
        if not part:match('^%d+$') then
            return nil
        end
        if first == nil then
            first = part
        elseif part ~= first then
            return nil
        end
    end
    if count < MIN_TEAMS then
        return nil
    end
    local size = tonumber(first)
    if size < MIN_TEAM_SIZE or size > MAX_TEAM_SIZE then
        return nil
    end
    return count, size
end

---Team size from the league's `format` string, or nil if it is not a shape this
---scenario plays. The size is common to every team by construction.
---@param format any
---@return integer|nil
local function team_size_of(format)
    local _, size = parse_format(format)
    return size
end

---The league's record for this match, or nil when there is none. Tolerates
---`storage` being absent so the module loads outside Factorio.
---@return table|nil
local function league_match()
    local store = storage
    if type(store) ~= 'table' then
        return nil
    end
    local match = store.bb_league_match
    if type(match) ~= 'table' then
        return nil
    end
    return match
end

---The version a record claims to be written to.
---
---A record carrying neither `version` nor `teams` is a v1 record: that is what
---the daemon writes today and what every record written before this code is. A
---`teams` array with no `version` is a v2 record that forgot to say so, and is
---read as one -- the array is validated either way, so nothing is taken on
---trust. A `version` that is not a whole number in 1..MAX_VERSION is not a
---version at all and is ignored the same way.
---@param match table
---@return integer
local function claimed_version(match)
    local version = tonumber(match.version)
    if version then
        version = math.floor(version)
        if version >= RECORD_V1 and version <= MAX_VERSION then
            return version
        end
    end
    if match.teams ~= nil then
        return RECORD_V2
    end
    return RECORD_V1
end

---The rosters of a MAP-form `teams` field, as the same ordered array the array
---form produces, or nil and the first violation found.
---
---The map carries no order, so RING ORDER is the order: `Teams.roster()`, which
---is `Teams.all()` for every key that plays this round and also orders a key
---that does not. The array form accepts a roster team outside the round -- the
---record describes a match, `Teams.count()` is what is being played, and the
---mismatch clause of the line is what names the disagreement -- so the map form
---accepts the same records.
---
---Nothing here walks the record in `pairs` order: an unknown key is reported as
---the first of the sorted names and the rosters are read in ring order, so the
---line does not depend on the hash order of a table another process wrote.
---@param teams table The `teams` field, keyed by force name.
---@param count integer Teams the `format` string names.
---@param size integer The size it gives every one of them.
---@param format any The record's `format`, for the violation line.
---@return table|nil teams
---@return string|nil form
---@return string|nil violation
local function validated_map(teams, count, size, format)
    -- The keys of a table are distinct by construction, so the array form's
    -- "repeats 'north'" cannot happen here; a key that is not a team can.
    local known = 0
    local unknown = {}
    for key in pairs(teams) do
        if Teams.is_team(key) then
            known = known + 1
        else
            unknown[#unknown + 1] = tostring(key)
        end
    end
    if #unknown > 0 then
        table.sort(unknown)
        return nil, nil, string.format("teams key '%s' is not a team", unknown[1])
    end
    if known < MIN_TEAMS or known > MAX_TEAMS then
        return nil, nil, string.format('teams map is %d long, not %d..%d', known, MIN_TEAMS, MAX_TEAMS)
    end
    if known ~= count then
        return nil, nil, string.format("%d teams but format '%s' names %d", known, tostring(format), count)
    end

    local ordered = {}
    for _, name in ipairs(Teams.roster()) do
        local players = teams[name]
        if players ~= nil then
            if type(players) ~= 'table' then
                return nil, nil, string.format("teams['%s'] has no players array", name)
            end
            if #players ~= size then
                return nil, nil, string.format("teams['%s'] roster is %d, the format says %d", name, #players, size)
            end
            for p = 1, size do
                if type(players[p]) ~= 'string' then
                    return nil, nil, string.format("teams['%s'] player %d is not a name", name, p)
                end
            end
            ordered[#ordered + 1] = { name = name, players = players }
        end
    end
    return ordered, FORM_MAP
end

---The `teams` field of a v2 record when it satisfies the contract in the file
---header, as an ordered array whatever form it was written in, plus the form it
---was read in -- or nil and the first violation found, spelled for a human.
---
---The checks run in the order the header lists them, so the operator reads the
---first thing that is wrong rather than the last. Nothing here raises: the
---record comes from another process and a malformed one has to leave the game
---running.
---
---A field with a first element is an array; one with keys and no first element
---is a map. An EMPTY table is read as an array, so the violation it produces is
---the one it produced before the map form existed, character for character.
---@param match table
---@param count integer Teams the `format` string names.
---@param size integer The size it gives every one of them.
---@return table|nil teams
---@return string|nil form
---@return string|nil violation
local function validated_teams(match, count, size)
    local teams = match.teams
    if type(teams) ~= 'table' then
        return nil, nil, 'no teams array'
    end
    local n = #teams
    if n == 0 and next(teams) ~= nil then
        return validated_map(teams, count, size, match.format)
    end
    if n < MIN_TEAMS or n > MAX_TEAMS then
        return nil, nil, string.format('teams array is %d long, not %d..%d', n, MIN_TEAMS, MAX_TEAMS)
    end
    if n ~= count then
        return nil, nil, string.format("%d teams but format '%s' names %d", n, tostring(match.format), count)
    end
    local seen = {}
    for i = 1, n do
        local entry = teams[i]
        if type(entry) ~= 'table' then
            return nil, nil, string.format('teams[%d] is not a table', i)
        end
        local name = entry.name
        if not Teams.is_team(name) then
            return nil, nil, string.format("teams[%d].name '%s' is not a team", i, tostring(name))
        end
        if seen[name] then
            return nil, nil, string.format("teams[%d] repeats '%s'", i, name)
        end
        seen[name] = true
        local players = entry.players
        if type(players) ~= 'table' then
            return nil, nil, string.format('teams[%d] (%s) has no players array', i, name)
        end
        if #players ~= size then
            return nil, nil, string.format('teams[%d] (%s) roster is %d, the format says %d', i, name, #players, size)
        end
        for p = 1, size do
            if type(players[p]) ~= 'string' then
                return nil, nil, string.format('teams[%d] (%s) player %d is not a name', i, name, p)
            end
        end
    end
    return teams, FORM_ARRAY
end

---@class LeagueReading
---@field match table|nil The record, when there is one.
---@field version integer|nil What the record claims to be; nil when there is none.
---@field count integer|nil Teams the record describes; nil when nothing readable.
---@field size integer|nil The common team size; nil when the format is unreadable.
---@field form string|nil The form a valid v2 `teams` field was written in.
---@field violation string|nil Why a v2 record was read from its `format` alone.

---Everything this module gets out of the record, in one read, so that the
---recognition line, `team_count()` and the remote handshake cannot describe the
---same record from three different reads.
---
---Pure: it reads `storage` and the static roster and calls nothing on `game`.
---@return LeagueReading
local function read_record()
    local match = league_match()
    if not match then
        return {}
    end
    local version = claimed_version(match)
    local count, size = parse_format(match.format)
    local reading = { match = match, version = version, count = count, size = size }
    -- An unreadable format leaves no size to measure the rosters against, so a
    -- v2 record is not held to the `teams` contract it cannot be checked
    -- against: it is simply unreadable, like any other.
    if version >= RECORD_V2 and count then
        -- A validated record always names its form, and it is the only reading
        -- `line_for` prints a form for: every other branch is taken first.
        local teams, form, violation = validated_teams(match, count, size)
        if teams then
            reading.count = #teams
            reading.form = form
        else
            reading.violation = violation
        end
    end
    return reading
end

---The one line that says what this scenario made of the record.
---@param reading LeagueReading
---@return string
local function line_for(reading)
    local line
    if not reading.match then
        line = 'no record -> default parameters'
    elseif not reading.size then
        line = string.format("record unreadable (format '%s') -> default parameters", tostring(reading.match.format))
    elseif reading.violation then
        line = string.format(
            'record v%d invalid (%s) -> read from format alone: %d teams, format %s, params %s',
            reading.version,
            reading.violation,
            reading.count,
            tostring(reading.match.format),
            Public.format_key()
        )
    elseif reading.version >= RECORD_V2 then
        line = string.format(
            'record v%d: %d %s, format %s, params %s',
            reading.version,
            reading.count,
            reading.form,
            tostring(reading.match.format),
            Public.format_key()
        )
    else
        line = string.format(
            'record v%d: format %s, params %s',
            reading.version,
            tostring(reading.match.format),
            Public.format_key()
        )
    end

    -- The record describes a match; the round is what is being played. They
    -- disagree when the daemon wrote a record for a count the map was not reset
    -- to, which is silent today and is the failure this line exists for.
    local round = Teams.count()
    if reading.count and reading.count ~= round then
        line = line .. string.format('; mismatch: record says %d teams, the round has %d', reading.count, round)
    end
    return LEAGUE .. line
end

---@return integer|nil team_size nil outside a league match, or on a record this
---scenario cannot read.
function Public.team_size()
    local match = league_match()
    if not match then
        return nil
    end
    return team_size_of(match.format)
end

---How many teams the RECORD describes: `#teams` for a v2 record that satisfies
---the contract, the number of parts of a readable `format` otherwise, and nil
---when there is no record or nothing in it can be read.
---
---This is what the league said, NOT what is being played -- `Teams.count()` is
---the round. The two disagreeing is exactly the mismatch `recognised()` names.
---
---Pure: `storage` and the static roster, nothing on `game`.
---@return integer|nil
function Public.team_count()
    return read_record().count
end

---The key the parameter sets are stored under: '1v1', '2v2', ... or 'default'.
---
---TWO parts whatever the team count, because this key is a save schema:
---`storage.feeding_params` and the league's tuning overrides are stored under
---it (feeding_params.lua:42-47). A '2v2v2' match therefore plays the '2v2' set.
---@return string
function Public.format_key()
    local size = Public.team_size()
    if not size then
        return FeedingParams.BASE_KEY
    end
    return string.format('%dv%d', size, size)
end

---The format as players read it: the team size once per team, joined by 'v' --
---'2v2' for two teams, '2v2v2' for three, '1v1v1v1' for four.
---
---A LABEL, never a key: `format_key()` stays two parts because it names a saved
---parameter set, and a '2v2v2' match plays the '2v2' set. At two teams the label
---IS the key ('%dv%d'), character for character, so every two-team sentence
---built from it is unchanged. A count below two is read as two.
---
---Pure.
---@param size integer
---@param count integer|nil
---@return string
function Public.display_label(size, count)
    local parts = {}
    local n = math.max(tonumber(count) or LEGACY_TEAM_COUNT, LEGACY_TEAM_COUNT)
    for i = 1, n do
        parts[i] = tostring(size)
    end
    return table.concat(parts, 'v')
end

---The label of the match being played: the record's team size, once per team
---of the round (`Teams.count()`, what is played -- the same count `describe()`
---schedules by). nil when there is no readable record, where `format_key()`
---answers 'default'.
---@return string|nil
function Public.format_label()
    local size = Public.team_size()
    if not size then
        return nil
    end
    return Public.display_label(size, Teams.count())
end

---One line saying what this scenario made of the league's record: the version
---it recognised, the teams and the format it read out of it, the parameter set
---that follows, and any disagreement with the round being played.
---
---`describe()` is the other sentence about the format -- the one the panel and
---the /feeding-params report quote, which says what the parameters in force are
---doing. This one is the handshake: the daemon reads it back through
---`remote.call('bb_teams', 'match_info')` and `log_recognised_once()` writes it
---to the log.
---@return string
function Public.recognised()
    return line_for(read_record())
end

---What the scenario made of the record, for the daemon to read back over RCON
---right after writing it.
---
---A fresh table every call: it crosses the remote boundary and the caller keeps
---it. `version` and the two counts are nil when there is no record; `recognised`
---and `format_key` always answer.
---@return { version: integer|nil, team_count: integer|nil, team_size: integer|nil, format_key: string, recognised: string }
function Public.match_info()
    local reading = read_record()
    return {
        version = reading.version,
        team_count = reading.count,
        team_size = reading.size,
        format_key = Public.format_key(),
        recognised = line_for(reading),
    }
end

---Write the recognition line to the log, at most once per round.
---
---Only when there is something new to say: a record claiming version 2 or
---later, a round of more than two teams, or a record whose team count is not
---the round's. A v1 record in a two-team round is today's game exactly and logs
---nothing -- the two-team log is compared line for line against the baseline,
---and a line added there is a regression.
---
---Idempotent: the round's start tick and the record's identity are remembered
---in a plain `storage` key. `Init.tables()` does not have to know about the key
---and does not clear it -- the stamp carries `bb_game_start_tick`, which the
---reset nils and the next GO sets to a later tick, so the next round's stamp
---differs by construction. Nothing is written when nothing is logged, so a
---two-team round does not gain a storage key either. A record rewritten
---mid-round under a new id is recognised again, on purpose.
function Public.log_recognised_once()
    local store = storage
    if type(store) ~= 'table' then
        return
    end
    local reading = read_record()
    local claims_v2 = reading.version ~= nil and reading.version >= RECORD_V2
    local round = Teams.count()
    local mismatched = reading.count ~= nil and reading.count ~= round
    if not (claims_v2 or round > LEGACY_TEAM_COUNT or mismatched) then
        return
    end

    local match = reading.match
    local stamp = table.concat({
        tostring(store.bb_game_start_tick),
        tostring(match and match.id),
        tostring(match and match.go_tick),
    }, '|')
    if store.bb_league_recognised == stamp then
        return
    end
    store.bb_league_recognised = stamp
    log(line_for(reading))
end

---Ticks between consecutive global attack waves, for the format in force.
---
---Vanilla offers a wave every minute and the wave alternates sides, so 3600 is
---"each side every two minutes" and is the floor: the dispatcher has nothing
---finer to offer.
---
---`FeedingParams.attack_interval()` is `FeedingParams.get().attack_interval`
---without the table the rest of the set would be built into -- the same number
---for every format, every override and every team count. The dispatcher asks
---for it on every 30-tick slot above two teams, which is why it stopped being
---worth nine clamps and an allocation.
---@return integer
function Public.attack_interval_ticks()
    return FeedingParams.attack_interval()
end

---True on the minutes where the whole main attack cycle should be skipped.
---
---The cycle occupies ticks 900..1140 of each 3600-tick minute, so a wave runs
---in the interval's *first* minute and the rest of the interval is skipped.
---Bucketing this way keeps setup, the seven waves and teardown agreeing with
---each other -- a cycle is never half-run. Skipping teardown too is the point:
---it is post_main_attack that flips sides, so a skipped minute leaves
---next_attack alone and the sides keep alternating, just further apart.
---
---At the 3600 floor `tick % interval` is always under a minute, so nothing is
---ever skipped and this costs one modulo.
---@param tick integer
---@return boolean
function Public.skip_attack_cycle(tick)
    local interval = Public.attack_interval_ticks()
    if interval <= TICKS_PER_MINUTE then
        return false
    end
    return (tick % interval) >= TICKS_PER_MINUTE
end

---bb_threat_income is only rewritten when someone feeds, so a parameter changed
---mid-game would otherwise keep paying the old rate until the next send.
---Rebuild every side from current evolution so a change takes effect at once.
---
---The list of biter forces is read at call time rather than captured once, so a
---round that starts with a different team count is served by the same code; at
---two teams it is `north_biters`, `south_biters`, in that order, as the literal
---it replaces was.
---
---Above two teams an eliminated team is skipped: `eliminate_team` sets its
---income to zero and stops its biters, and rebuilding the income here from its
---frozen evolution -- which any `/feeding-params` change does -- would start its
---threat pool growing again for the rest of the round.
---
---`passive_threat` already carries the format's income multiplier, so there is
---nothing to apply on top of it here.
function Public.refresh_threat_income()
    if not storage.bb_threat_income or not storage.bb_evolution then
        return
    end
    local params = FeedingParams.get()
    local biter_forces = Teams.biter_forces()
    if Teams.count() > 2 then
        biter_forces = Teams.alive_biter_forces()
    end
    for _, biter_force in ipairs(biter_forces) do
        local evo = storage.bb_evolution[biter_force]
        if evo then
            storage.bb_threat_income[biter_force] = FeedingParams.passive_threat(evo, params)
        end
    end
end

---What the format is and what it is doing, for the report and the panel to
---quote. One call so the two cannot describe it from different reads.
---@return string
function Public.describe()
    local match = league_match()
    local size = Public.team_size()

    if not size then
        if match then
            return string.format(
                'league match %s reports %q, which this scenario does not play — default set',
                tostring(match.id or '?'),
                tostring(match.format)
            )
        end
        return 'no league match — default set'
    end

    local params = FeedingParams.get()
    local interval = params.attack_interval
    -- How long a team waits for its turn -- the one sentence the passive income
    -- curve is tuned against, so it has to be the schedule that actually runs.
    -- Under the attack clock (the default above two teams) a rotation of the
    -- ring is `count` cycles of `2 * interval / count`, i.e. two intervals
    -- whatever the team count is; under the 'shared' fallback the global wave
    -- still serves one team per interval and the turn comes round every `count`
    -- of them. At two teams `is_on` answers false before it reads anything, so
    -- this is `interval * 2` -- the literal multiplier of old, character for
    -- character.
    local count = Teams.count()
    local per_team_ticks = AttackClock.is_on(count) and count * AttackClock.period(interval, count) or interval * count
    -- Above two teams the match is named as it is played ('2v2v2', not the
    -- two-part key of its parameter set) and a turn comes round to each TEAM:
    -- "each side" is the two-team word. At two teams the label is '%dv%d' and
    -- the word is 'side', so the sentence is today's to the byte.
    return string.format(
        '%s [league match %s] — passive income x%s, wave every %d ticks (%s min, each %s every %s min)',
        Public.display_label(size, count),
        tostring(match.id or '?'),
        FeedingParams.show(params.passive_income_scale),
        interval,
        FeedingParams.show(interval / TICKS_PER_MINUTE),
        count > LEGACY_TEAM_COUNT and 'team' or 'side',
        FeedingParams.show(per_team_ticks / TICKS_PER_MINUTE)
    )
end

return Public
