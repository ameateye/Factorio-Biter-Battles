-- Who fed how much mutagen to whom, and what happens to it when a team is out.
--
-- Above two teams a team whose last silo falls leaves the round, and until now
-- everything fed to its biters went with it: a team that had put most of its
-- science into the fallen team lost that pressure outright, while a rival that
-- fed the survivors kept all of its own. This module keeps a ledger of every
-- send, source team -> target team, and turns an elimination into a plan of
-- re-sends between the teams still standing.
--
-- Only sends are booked: a player's or a feeder chest's science, which is what
-- `feeding.lua`'s `feed_the_targets` delivers. The passive red-potion drip of
-- `ai.lua`'s `raise_evo` is driven by the clock, not by anyone, and goes to
-- every alive team alike, so it has no source to give back and is left out.
--
-- Every entry carries two amounts, because the two ways the scenario turns
-- mutagen into evolution read different ones:
--
--   raw       flasks x food value (white x3 under Triple Threat). Triple Threat
--             keeps this per biter force and derives evolution from it at the
--             CURRENT difficulty (tt_mode.lua, the retroactive send).
--   weighted  raw x the difficulty at the moment of the send. Everywhere else
--             evolution is a pure function of the sum of these.
--
-- Two policies, set by `/elimination-mutagen`:
--
--   full      Every alive team re-sends everything it ever fed to the fallen
--             team, to its own enemies still standing.
--   excess    Only what a team fed beyond the smallest amount any alive team
--             fed is re-sent. If B, C and D fed the fallen A 50, 60 and 70, the
--             first 50 of each cancel out: C re-sends 10 and D re-sends 20.
--   off       Nothing moves; the mutagen is lost with the team (the old rule).
--
-- A re-send is split the way a real send from that team would be at that
-- moment (`Teams.feed_targets`: the feed policy and the team's focus ticks),
-- and it moves evolution and the passive threat income derived from it only --
-- never the instant threat pool. It is booked in the ledger like a send, so a
-- team that is itself eliminated later hands it on again.
--
-- A team already out when a later one falls has no enemies to re-send to, so
-- what it fed the later team stays where it is. The minimum of `excess` is taken
-- over the alive teams only, for the same reason.
--
-- Pure: no `game`, no `storage`. The ledger is a table the caller keeps
-- (`storage.mutagen_ledger`) and the split is a function the caller passes in,
-- so every number below can be pinned without Factorio (tests/test-mutagen-ledger.lua).

local Public = {}

Public.OFF = 'off'
Public.FULL = 'full'
Public.EXCESS = 'excess'
Public.DEFAULT_MODE = Public.EXCESS

local MODES = { [Public.OFF] = true, [Public.FULL] = true, [Public.EXCESS] = true }

---@param mode any
---@return boolean
function Public.is_mode(mode)
    return MODES[mode] == true
end

---The mode a stored setting stands for: itself when it is one, the default
---when nothing (or nonsense) was ever stored.
---@param stored any `storage.elimination_mutagen_mode`
---@return string
function Public.mode(stored)
    if MODES[stored] then
        return stored
    end
    return Public.DEFAULT_MODE
end

---@class MutagenAmount
---@field raw number
---@field weighted number

---@alias MutagenLedger table<string, table<string, MutagenAmount>> source team -> target team -> amount

---Book a send of `raw` / `weighted` mutagen from `source` to `target`.
---A team feeding itself (training mode) is not a send between teams and is
---not booked.
---@param ledger MutagenLedger
---@param source string
---@param target string
---@param raw number
---@param weighted number
function Public.record(ledger, source, target, raw, weighted)
    if source == target or not (raw > 0 or weighted > 0) then
        return
    end
    local row = ledger[source]
    if not row then
        row = {}
        ledger[source] = row
    end
    local entry = row[target]
    if not entry then
        entry = { raw = 0, weighted = 0 }
        row[target] = entry
    end
    entry.raw = entry.raw + raw
    entry.weighted = entry.weighted + weighted
end

---What `source` has fed `target` so far, zero when nothing.
---@param ledger MutagenLedger
---@param source string
---@param target string
---@return MutagenAmount
function Public.fed(ledger, source, target)
    local row = ledger[source]
    local entry = row and row[target]
    if not entry then
        return { raw = 0, weighted = 0 }
    end
    return { raw = entry.raw, weighted = entry.weighted }
end

---@class MutagenTransfer
---@field source string The alive team the re-send is booked to.
---@field target string The alive team whose biters receive it.
---@field raw number
---@field weighted number

---The re-sends an elimination calls for, in the order they are to be applied:
---`sources` order, and within one source the order `targets_of` gives.
---
---The two amounts are handled independently -- the smallest raw and the
---smallest weighted amount are each taken over the sources -- so each of the
---two evolution models sees exactly the rule, in its own unit.
---@param ledger MutagenLedger
---@param fallen string The team that was just eliminated.
---@param sources string[] The teams still alive, in ring order; `fallen` is not among them.
---@param mode string One of the modes above.
---@param targets_of fun(source: string): FeedTarget[] How a send from `source` is split now.
---@return MutagenTransfer[]
function Public.plan(ledger, fallen, sources, mode, targets_of)
    local transfers = {}
    if mode ~= Public.FULL and mode ~= Public.EXCESS then
        return transfers
    end

    local floor_raw, floor_weighted = 0, 0
    if mode == Public.EXCESS then
        floor_raw, floor_weighted = math.huge, math.huge
        for i = 1, #sources do
            local fed = Public.fed(ledger, sources[i], fallen)
            floor_raw = math.min(floor_raw, fed.raw)
            floor_weighted = math.min(floor_weighted, fed.weighted)
        end
        if #sources == 0 then
            floor_raw, floor_weighted = 0, 0
        end
    end

    for i = 1, #sources do
        local source = sources[i]
        local fed = Public.fed(ledger, source, fallen)
        local raw = fed.raw - floor_raw
        local weighted = fed.weighted - floor_weighted
        if raw > 0 or weighted > 0 then
            local targets = targets_of(source)
            for j = 1, #targets do
                local target = targets[j]
                if target.team ~= fallen and target.team ~= source and target.share > 0 then
                    transfers[#transfers + 1] = {
                        source = source,
                        target = target.team,
                        raw = raw * target.share,
                        weighted = weighted * target.share,
                    }
                end
            end
        end
    end
    return transfers
end

---Forget what was fed to `fallen`: it has been handed on (or, with `off`,
---lost), and must not be counted again.
---@param ledger MutagenLedger
---@param fallen string
function Public.forget_target(ledger, fallen)
    for _, row in pairs(ledger) do
        row[fallen] = nil
    end
end

---What each target receives in total, in first-appearance order -- the
---announcement's one entry per team.
---@param transfers MutagenTransfer[]
---@return { team: string, raw: number, weighted: number }[]
function Public.totals_by_target(transfers)
    local order, by_team = {}, {}
    for i = 1, #transfers do
        local transfer = transfers[i]
        local total = by_team[transfer.target]
        if not total then
            total = { team = transfer.target, raw = 0, weighted = 0 }
            by_team[transfer.target] = total
            order[#order + 1] = total
        end
        total.raw = total.raw + transfer.raw
        total.weighted = total.weighted + transfer.weighted
    end
    return order
end

return Public
