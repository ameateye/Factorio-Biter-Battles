-- /feeding-params — retune the feeding curves in a running game.
--
-- The chat form of the Evo and threat setup tab, kept because a retune is
-- usually a line typed between two sends and because a command can set several
-- numbers in one go. Both go through the same report and the same announcement,
-- so the two can never quote a flask at different values.
--
-- There is one set of numbers per match format, so every form takes an optional
-- format in front of it. Without one it is the format being played -- which on
-- a server with no league match is `default`.
--
-- `default` is also the base the rest inherit from. A format stores only the
-- parameters it has been given explicitly and takes everything else from
-- `default`, so `/feeding-params b=12` moves b everywhere, and
-- `/feeding-params 1v1 b=7.5` then holds 1v1 apart from it until b is cleared.
-- `all` remains for the rarer intent of writing a number into all nine as their
-- own, which a later change to the base will not move.
--
--   /feeding-params                       show the set in force
--   /feeding-params 1v1                   show 1v1's set, whatever is being played
--   /feeding-params c=48.7 n=2.5          retune the set in force, by symbol or name
--   /feeding-params instant_scale=50      the long names work too
--   /feeding-params 1v1 b=7.5             retune 1v1 specifically
--   /feeding-params 1v1 k=0.5             k is the passive income multiplier
--   /feeding-params 2v2 interval=7200     ticks between waves; 3600 is one a minute
--   /feeding-params all b=12              pin b on every format individually
--   /feeding-params 1v1 b=default         stop overriding b on 1v1, so it
--                                         follows `default` again
--   /feeding-params reset                 the set in force, back to defaults
--   /feeding-params 3v3 reset             one format, back to defaults
--   /feeding-params all reset             every format
--
-- Reading is open to everyone, because once an admin has moved anything this
-- report is the only honest account of what a flask buys. Writing is admin-only.

local FeedingParams = require('maps.biter_battles_v2.feeding_params')
local MatchFormat = require('maps.biter_battles_v2.match_format')
local Utils = require('utils.utils')

local Public = {}

local ALL = 'all'

---Split off a leading format target, if there is one.
---
---`all` and the format keys are the only words that can appear where a target
---goes, and none of them can be confused with a `key=value`, so a bare word is
---unambiguous: either it names a set or it is a mistake worth reporting.
---@param text string
---@return string|nil target nil for "the format in force"
---@return string rest
local function split_target(text)
    local head, rest = string.match(text, '^([%w_]+)%s*(.*)$')
    if not head then
        return nil, text
    end
    local lowered = string.lower(head)
    if lowered == ALL or FeedingParams.is_format_key(lowered) then
        return lowered, rest
    end
    return nil, text
end

---Every set the command should write to for a given target.
---@param target string|nil
---@return string[]
local function keys_for(target)
    if target == ALL then
        return FeedingParams.format_keys
    end
    return { target or MatchFormat.format_key() }
end

---@param cmd table
local function feeding_params(cmd)
    local player = cmd.player_index and game.get_player(cmd.player_index) or nil
    local print_to = player and function(msg)
        player.print(msg)
    end or log
    local actor = player and player.name or 'server'

    local params = cmd.parameter and string.match(cmd.parameter, '^%s*(.-)%s*$') or ''
    local target, rest = split_target(params)
    rest = string.match(rest, '^%s*(.-)%s*$')

    -- Reading `all` has no single set to print, so it shows the one in force
    -- and leaves the rest to be asked for by name.
    if rest == '' then
        local key = (target and target ~= ALL) and target or MatchFormat.format_key()
        print_to(FeedingParams.report(FeedingParams.get(key), key, MatchFormat.describe()))
        return
    end

    if player and not is_admin(player) then
        player.print('[feeding-params] Admin only. Run it with no arguments to see the current values.')
        return
    end

    local keys = keys_for(target)

    if string.lower(rest) == 'reset' then
        for _, key in ipairs(keys) do
            FeedingParams.reset(key)
        end
        FeedingParams.announce_reset(actor, target or keys[1])
        return
    end

    -- Parsed and applied per set, so `all` is the same change made nine times
    -- rather than a second code path. A set that refuses a value stops the
    -- whole command: half-applied is worse than not applied.
    local applied = {}
    for pair in string.gmatch(rest, '([^%s]+)') do
        local key, value = string.match(pair, '^([%w_]+)=([%w%p]+)$')
        if not key then
            print_to(string.format('[feeding-params] cannot read %q — expected key=value', pair))
            return
        end

        local stored
        for _, format_key in ipairs(keys) do
            local result, err = FeedingParams.set(key, value, format_key)
            if err then
                print_to(string.format('[feeding-params] %s (%s)', err, format_key))
                return
            end
            stored = result
        end
        applied[#applied + 1] = string.format(
            '%s = %s%s',
            FeedingParams.resolve_key(key),
            FeedingParams.show(stored),
            FeedingParams.is_clear_word(value) and ' (inherited)' or ''
        )
    end

    FeedingParams.announce_changed(actor, applied, target or keys[1])
end

commands.add_command(
    'feeding-params',
    'Show the feeding curve constants for a match format; admins can retune them. Usage: /feeding-params [1v1|all] [reset | key=value | key=default ...]',
    function(cmd)
        Utils.safe_wrap_cmd(cmd, feeding_params, cmd)
    end
)

return Public
