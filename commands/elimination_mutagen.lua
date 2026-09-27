-- /elimination-mutagen — what happens to the mutagen fed to a team that is out
-- of a 3-4 team round (maps/biter_battles_v2/mutagen_ledger.lua).
--
--   /elimination-mutagen          show the mode in force
--   /elimination-mutagen full     every alive team re-sends all it fed the fallen team
--   /elimination-mutagen excess   only what it fed beyond the smallest amount any alive team fed
--   /elimination-mutagen off      the mutagen is lost with the team
--
-- A re-send moves evolution and passive threat income only, never instant
-- threat. The mode applies from the next elimination on, survives map resets,
-- and has no effect on a two-team round, which ends at the first silo.
--
-- Reading is open to everyone; writing is admin-only. A caller with no player
-- is RCON and is trusted.

local Color = require('utils.color_presets')
local MutagenLedger = require('maps.biter_battles_v2.mutagen_ledger')
local Utils = require('utils.utils')

local Public = {}

local DESCRIPTION = {
    [MutagenLedger.FULL] = 'every alive team re-sends all it fed the fallen team',
    [MutagenLedger.EXCESS] = 'only what a team fed beyond the smallest amount any alive team fed is re-sent',
    [MutagenLedger.OFF] = 'the mutagen is lost with the team',
}

---@param player LuaPlayer|nil
---@param message string
---@param color table|nil
local function reply(player, message, color)
    if player then
        player.print(message, { color = color or Color.info })
    elseif rcon then
        rcon.print(message)
    end
end

---@param mode string
---@return string
local function status_line(mode)
    return '[elimination-mutagen] ' .. mode .. ': ' .. DESCRIPTION[mode] .. ' (evolution and passive threat only).'
end

---@param cmd CustomCommandData
function Public.elimination_mutagen(cmd)
    local player = cmd.player_index and game.get_player(cmd.player_index) or nil
    local arg = cmd.parameter and string.lower(string.match(cmd.parameter, '^%s*(.-)%s*$')) or ''
    if arg == '' then
        reply(player, status_line(MutagenLedger.mode(storage.elimination_mutagen_mode)))
        return
    end
    if player and not is_admin(player) then
        reply(player, '[elimination-mutagen] Admin only. Run it with no arguments to see the mode.', Color.warning)
        return
    end
    if not MutagenLedger.is_mode(arg) then
        reply(player, '[elimination-mutagen] Expected off, full or excess.', Color.warning)
        return
    end
    storage.elimination_mutagen_mode = arg
    game.print(
        '>> ' .. status_line(arg) .. ' Set by ' .. (player and player.name or 'the server') .. '.',
        { color = { r = 1, g = 0.85, b = 0.2 } }
    )
end

commands.add_command(
    'elimination-mutagen',
    'Show or set (admin) what happens to the mutagen fed to a team eliminated from a 3-4 team round: off, full or excess.',
    function(cmd)
        Utils.safe_wrap_cmd(cmd, Public.elimination_mutagen, cmd)
    end
)

return Public
