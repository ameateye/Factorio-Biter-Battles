-- /feeding-params — retune the feeding curves in a running game.
--
-- Admin only, and deliberately without a GUI: this is a balance-testing knob,
-- not a game setting. Reading it is open to everyone, because once an admin has
-- moved anything this report is the only honest account of what a flask buys.
--
--   /feeding-params                       show what is in force
--   /feeding-params c=48.7 n=2.5          set one or more, by symbol or name
--   /feeding-params instant_scale=50      the long names work too
--   /feeding-params reset                 back to the defaults
--
-- Changes are announced to everyone rather than applied quietly: they move what
-- a send is worth for both teams at once, and a silent retune mid-game would
-- read to players as the scenario misbehaving.

local FeedingParams = require('maps.biter_battles_v2.feeding_params')
local Utils = require('utils.utils')

local Public = {}

-- Evolutions the summary quotes at — the span the balance is argued over.
local QUOTE_AT = { 0.5, 1.0, 1.5, 2.5 }

---Human-readable value, without Lua's trailing ".0" on whole numbers.
---@param value number|boolean
---@return string
local function show(value)
    if type(value) == 'boolean' then
        return value and 'true' or 'false'
    end
    if value == math.floor(value) and math.abs(value) < 1e15 then
        return string.format('%d', value)
    end
    return (string.format('%.4f', value):gsub('0+$', ''):gsub('%.$', ''))
end

---The three formulas, with the numbers in force substituted in.
---@param params FeedingParams
---@return string
local function formulas(params)
    return string.format(
        'E = (M / %s) ^ %s%s   |   P = %s·E^%s + %s·E per sec   |   T = %s·M',
        show(params.evo_mutagen_at_100),
        show(params.evo_power),
        params.evo_stop_scaling_at_100 and ', tangent past 100%' or ', power law throughout',
        show(params.passive_scale),
        show(FeedingParams.effective_passive_power(params)),
        show(params.passive_linear),
        show(params.instant_scale)
    )
end

---Every parameter, one per line, marked where it has been moved.
---@param params FeedingParams
---@return string
local function report(params)
    local lines = { '[feeding-params] ' .. formulas(params) }
    for _, field in ipairs(FeedingParams.order) do
        local symbol = ''
        for alias, target in pairs(FeedingParams.aliases) do
            if target == field and #alias <= 2 then
                symbol = ' (' .. alias .. ')'
            end
        end
        lines[#lines + 1] = string.format(
            '  %s%s = %s%s',
            field,
            symbol,
            show(params[field]),
            FeedingParams.is_overridden(field) and string.format('   [default %s]', show(FeedingParams.defaults[field]))
                or ''
        )
    end

    local row = {}
    for _, evo in ipairs(QUOTE_AT) do
        row[#row + 1] = string.format(
            '%d%%: %.0f mutagen, %.0f threat/min, ratio %.1f min',
            evo * 100,
            FeedingParams.mutagen_for_evo(evo, params),
            FeedingParams.passive_threat(evo, params) * 60,
            FeedingParams.instant_over_passive(evo, params)
        )
    end
    lines[#lines + 1] = '  ' .. table.concat(row, ' | ')
    return table.concat(lines, '\n')
end

---@param cmd table
local function feeding_params(cmd)
    local player = cmd.player_index and game.get_player(cmd.player_index) or nil
    local print_to = player and function(msg)
        player.print(msg)
    end or log

    local params = cmd.parameter and string.match(cmd.parameter, '^%s*(.-)%s*$') or ''
    if params == '' then
        print_to(report(FeedingParams.get()))
        return
    end

    -- Anything that writes needs admin. Reading does not: players are entitled
    -- to know what a flask is worth, and the report is the only honest source
    -- once an admin has moved anything.
    if player and not is_admin(player) then
        player.print('[feeding-params] Admin only. Run it with no arguments to see the current values.')
        return
    end

    if string.lower(params) == 'reset' then
        FeedingParams.reset()
        game.print('>> [feeding-params] reset to defaults.\n' .. report(FeedingParams.get()))
        return
    end

    local applied = {}
    for pair in string.gmatch(params, '([^%s]+)') do
        local key, value = string.match(pair, '^([%w_]+)=([%w%p]+)$')
        if not key then
            print_to(string.format('[feeding-params] cannot read %q — expected key=value', pair))
            return
        end
        local stored, err = FeedingParams.set(key, value)
        if err then
            print_to('[feeding-params] ' .. err)
            return
        end
        applied[#applied + 1] = string.format('%s = %s', FeedingParams.resolve_key(key), show(stored))
    end

    local updated = FeedingParams.get()
    game.print(
        string.format(
            '>> [feeding-params] %s changed %s\n%s',
            player and player.name or 'server',
            table.concat(applied, ', '),
            report(updated)
        ),
        { r = 1, g = 0.85, b = 0.2 }
    )

    -- Evolution is reconstructed from each team's *current* evolution on every
    -- feed, so moving S or p re-prices future sends without moving anyone's
    -- evolution now. Triple Threat keeps the raw mutagen instead and derives
    -- evolution from it, so there the change is retroactive and the canonical
    -- value has to be recomputed or the two would disagree until the next send.
    if storage.tt_mode then
        require('maps.biter_battles_v2.tt_mode').tt_recompute_all()
        game.print('>> [feeding-params] Triple Threat is on — evolution recomputed from raw mutagen fed.')
    end
end

commands.add_command(
    'feeding-params',
    'Show the feeding curve constants; admins can retune them. Usage: /feeding-params [reset | key=value ...]',
    function(cmd)
        Utils.safe_wrap_cmd(cmd, feeding_params, cmd)
    end
)

return Public
