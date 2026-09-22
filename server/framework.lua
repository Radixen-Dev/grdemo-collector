-- Detects the resource framework running on this server and exposes a small,
-- uniform adapter so collector.lua never has to know whether it's talking to
-- ESX, QBCore/QBox, or nothing at all.
--
-- getPlayerInfo returns only the small analytics projection needed by the
-- dashboard. Platform identifiers (Discord, Steam, IP) and arbitrary
-- framework metadata stay excluded. Character identity is the exception:
-- a stable per-character id (QBCore/QBox citizenid, or the ESX identifier,
-- including its native multi-character `charN:license:...` form) and
-- character first/last name are forwarded so Analytics can distinguish a
-- player's separate characters instead of merging them into one identity.
-- When the character slot number itself is known (QBCore/QBox `cid`, or the
-- `N` in an ESX `charN:` prefix) it is forwarded too, as `info.cid`, so
-- Analytics can tell "N concurrent character slots" apart from "N
-- characters accumulated over time via delete+recreate". See the
-- "Character identity" section of README.md for exactly what this sends.
--
-- Add a new framework by implementing the same shape (detect / init /
-- getPlayerInfo / registerEvents) and registering it in `Adapters` below.

Framework = {}

local Adapters = {}

-- Normalizes a raw character-slot value into a positive integer, or nil if
-- it isn't one. Covers both QBCore/QBox PlayerData.cid (which some builds
-- or forks surface as a string, e.g. "1", rather than a number) and the
-- digit string captured from an ESX `charN:` identifier prefix.
local function toSlot(value)
    local n = tonumber(value)
    if type(n) == 'number' and n >= 1 and n % 1 == 0 then return n end
    return nil
end

-- ---------------------------------------------------------------------------
-- ESX (tested against es_extended "legacy")
-- ---------------------------------------------------------------------------
Adapters.esx = {
    detect = function()
        return GetResourceState('es_extended') == 'started'
    end,
    init = function(self)
        self.ESX = exports['es_extended']:getSharedObject()
    end,
    getPlayerInfo = function(self, source)
        local xPlayer = self.ESX.GetPlayerFromId(source)
        if not xPlayer then return nil end

        local info = {
            job = xPlayer.job and { name = xPlayer.job.name, label = xPlayer.job.label, grade = xPlayer.job.grade },
            job2 = xPlayer.job2 and { name = xPlayer.job2.name, label = xPlayer.job2.label, grade = xPlayer.job2.grade },
            group = xPlayer.group,
        }

        -- Base ESX has no native multi-character support: one FiveM license
        -- maps to one character slot, so the login identifier is already a
        -- stable, correct per-character key -- but only on builds configured
        -- to use the license as that identifier. Some ESX builds instead run
        -- native multicharacter, where the identifier carries an explicit
        -- `char<N>:` slot prefix in front of the license (e.g.
        -- `char2:license:abcd...`); that is still a stable, distinct
        -- per-character key and must be forwarded whole -- stripping the
        -- prefix down to the bare license would collapse genuinely distinct
        -- characters back into a single identity. On Steam-primary builds
        -- xPlayer.identifier is a steam:... id (with or without a char<N>:
        -- prefix), which platform-identifier policy excludes, so only
        -- forward it when the license-shaped suffix required by
        -- getIdentifiers() in collector.lua is present, in either form.
        if type(xPlayer.identifier) == 'string' then
            local slotDigits = xPlayer.identifier:match('^char(%d+):license:%x+$')
            if slotDigits then
                info.identifier = xPlayer.identifier
                info.cid = toSlot(slotDigits)
            elseif xPlayer.identifier:match('^license:%x+$') then
                info.identifier = xPlayer.identifier
            end
        end

        -- getMoney/getAccount are standard on every ESX legacy build, but
        -- wrap defensively in case a fork renames or removes one.
        pcall(function() info.cash = xPlayer.getMoney() end)
        pcall(function()
            local bank = xPlayer.getAccount('bank')
            info.bank = bank and bank.money
        end)
        -- getName() is common on modern es_extended legacy builds but not
        -- guaranteed across forks; fall back to no character name rather
        -- than the FiveM display name, which the API already has.
        pcall(function()
            local name = xPlayer.getName and xPlayer.getName()
            if type(name) == 'string' and name ~= '' then
                local firstname, lastname = name:match('^(%S+)%s+(.*)$')
                info.charinfo = { firstname = firstname or name, lastname = lastname or '' }
            end
        end)

        return info
    end,
    registerEvents = function(self, emit)
        -- Both event names have shipped across different ESX legacy versions;
        -- registering both is harmless if only one ever fires.
        AddEventHandler('esx:onPlayerDeath', function(source)
            emit(source, 'player_death', {})
        end)
        AddEventHandler('esx:playerDeath', function(source)
            emit(source, 'player_death', {})
        end)

        AddEventHandler('esx:setJob', function(source, job, lastJob)
            emit(source, 'job_change', {
                job = job and { name = job.name, label = job.label, grade = job.grade },
                previousJob = lastJob and lastJob.name,
            })
        end)
        AddEventHandler('esx:setJob2', function(source, job2, lastJob2)
            emit(source, 'job2_change', {
                job2 = job2 and { name = job2.name, label = job2.label, grade = job2.grade },
                previousJob2 = lastJob2 and lastJob2.name,
            })
        end)
        AddEventHandler('esx:setAccountMoney', function(source, account)
            emit(source, 'money_change', {
                account = account and account.name,
                amount = account and account.money,
            })
        end)
        AddEventHandler('esx:setGroup', function(source, group)
            emit(source, 'group_change', { group = group })
        end)
        AddEventHandler('esx:playerLoaded', function(source)
            emit(source, 'character_loaded', {})
        end)
    end,
}

-- ---------------------------------------------------------------------------
-- QBCore / QBox (share the same event names and PlayerData shape)
-- ---------------------------------------------------------------------------
local QBCoreAdapter = {
    detect = function()
        return GetResourceState('qb-core') == 'started'
    end,
    init = function(self)
        self.QBCore = exports['qb-core']:GetCoreObject()
    end,
    getPlayerInfo = function(self, source)
        local Player = self.QBCore.Functions.GetPlayer(source)
        if not Player then return nil end
        local data = Player.PlayerData

        return {
            job = data.job and { name = data.job.name, label = data.job.label, grade = data.job.grade, onDuty = data.job.onduty },
            gang = data.gang and { name = data.gang.name, label = data.gang.label, grade = data.gang.grade },
            money = data.money and {
                cash = type(data.money.cash) == 'number' and data.money.cash or nil,
                bank = type(data.money.bank) == 'number' and data.money.bank or nil,
                crypto = type(data.money.crypto) == 'number' and data.money.crypto or nil,
            },
            -- citizenid is QBCore/QBox's own stable per-character identifier:
            -- one license can hold several citizenids, one per character
            -- slot. charinfo carries only the two name fields Analytics uses
            -- to label a character; no other charinfo data is forwarded.
            citizenid = type(data.citizenid) == 'string' and data.citizenid or nil,
            -- cid is the character *slot number* (typically 1-5), distinct
            -- from citizenid: it tells Analytics how many concurrent
            -- character slots a license is using, separate from how many
            -- citizenids it has accumulated over time via delete+recreate.
            -- It's a small integer, not sensitive, but is still an explicit,
            -- deliberate addition -- see README.md "Character identity".
            cid = toSlot(data.cid),
            charinfo = data.charinfo and {
                firstname = data.charinfo.firstname,
                lastname = data.charinfo.lastname,
            },
        }
    end,
    registerEvents = function(self, emit)
        AddEventHandler('QBCore:Server:OnJobUpdate', function(source, job)
            emit(source, 'job_change', {
                job = job and { name = job.name, label = job.label, grade = job.grade, onDuty = job.onduty },
            })
        end)
        AddEventHandler('QBCore:Server:OnGangUpdate', function(source, gang)
            emit(source, 'gang_change', {
                gang = gang and { name = gang.name, label = gang.label, grade = gang.grade },
            })
        end)
        AddEventHandler('QBCore:Server:OnMoneyChange', function(source, moneyType, amount, operation, reason)
            emit(source, 'money_change', { moneyType = moneyType, amount = amount, operation = operation, reason = reason })
        end)
        AddEventHandler('QBCore:Server:PlayerLoaded', function(Player)
            local source = Player and Player.PlayerData and Player.PlayerData.source
            if source then emit(source, 'character_loaded', {}) end
        end)
        AddEventHandler('QBCore:Server:PlayerUnload', function(source)
            emit(source, 'character_unloaded', {})
        end)
        -- Not part of qb-core itself (comes from qb-ambulancejob), but common
        -- enough on QBCore servers that it's worth wiring up defensively —
        -- registering it is a no-op if that resource isn't installed.
        AddEventHandler('hospital:server:PlayerDied', function(playerSource)
            emit(playerSource or source, 'player_death', {})
        end)
        -- Current QBox medical resource. It supplies the player through the
        -- server event context rather than as an explicit event parameter.
        AddEventHandler('qbx-medical:server:playerDied', function()
            emit(source, 'player_death', {})
        end)
        -- Available on standard FXServer installations when baseevents is
        -- enabled; registering is harmless when it is absent.
        AddEventHandler('baseevents:onPlayerDied', function()
            emit(source, 'player_death', {})
        end)
        -- Do not associate one player's activity with another player's
        -- identifier. The event remains attributable to its actor only.
        AddEventHandler('baseevents:onPlayerKilled', function(_killerSource, deathData)
            emit(source, 'player_death', {
                weaponHash = deathData and deathData.weaponhash,
                killerType = deathData and deathData.killerType,
            })
        end)
    end,
}

-- QBox exposes its QB compatibility bridge through qb-core; qbx_core itself
-- does not export GetCoreObject. Keep detection separate so QBox is selected
-- when both resources are running.
Adapters.qbox = {
    detect = function()
        return GetResourceState('qbx_core') == 'started'
    end,
    init = QBCoreAdapter.init,
    getPlayerInfo = QBCoreAdapter.getPlayerInfo,
    registerEvents = QBCoreAdapter.registerEvents,
}
Adapters.qbcore = QBCoreAdapter

-- ---------------------------------------------------------------------------
-- Fallback: no framework, vanilla natives only
-- ---------------------------------------------------------------------------
Adapters.vanilla = {
    detect = function() return true end,
    init = function() end,
    getPlayerInfo = function() return {} end,
    registerEvents = function() end,
}

local active = nil
local activeName = 'unknown'

function Framework.Init()
    local adapterOrder = { 'esx', 'qbox', 'qbcore' }
    for _, name in ipairs(adapterOrder) do
        local adapter = Adapters[name]
        if name ~= 'vanilla' and adapter.detect() then
            active = adapter
            activeName = name
            break
        end
    end
    if not active then
        active = Adapters.vanilla
        activeName = 'vanilla'
    end

    local ok, err = pcall(function() active:init() end)
    if not ok then
        print(('[guildrate-collector] failed to init "%s" adapter, falling back to vanilla: %s'):format(activeName, err))
        active = Adapters.vanilla
        activeName = 'vanilla'
    end

    print(('[guildrate-collector] detected framework: %s'):format(activeName))
end

function Framework.GetName()
    return activeName
end

function Framework.GetPlayerInfo(source)
    local ok, result = pcall(function() return active:getPlayerInfo(source) end)
    if ok then return result or {} end
    return {}
end

function Framework.RegisterEvents(emit)
    if not Config.CollectFrameworkEvents then return end
    local ok, err = pcall(function() active:registerEvents(emit) end)
    if not ok then
        print(('[guildrate-collector] failed to register %s events: %s'):format(activeName, tostring(err)))
    end
end
