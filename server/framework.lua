-- Detects the resource framework running on this server and exposes a small,
-- uniform adapter so collector.lua never has to know whether it's talking to
-- ESX, QBCore/QBox, or nothing at all.
--
-- getPlayerInfo deliberately just forwards whatever the framework already
-- tracks (job, money, gang, character metadata, ...) instead of reinventing
-- it — these frameworks maintain a rich player state object for their own
-- purposes; we're just reading it, not duplicating the bookkeeping.
--
-- Add a new framework by implementing the same shape (detect / init /
-- getPlayerInfo / registerEvents) and registering it in `Adapters` below.

Framework = {}

local Adapters = {}

local function licenseForSource(playerSource)
    if not playerSource then return nil end
    for _, identifier in ipairs(GetPlayerIdentifiers(playerSource)) do
        if identifier:sub(1, 8) == 'license:' then return identifier end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- ESX (tested against es_extended "legacy")
-- ---------------------------------------------------------------------------
Adapters.esx = {
    capabilities = {
        'character.state',
    },
    eventCapabilities = {
        player_death = 'combat.death',
        money_change = 'economy.transaction',
        job_change = 'role.job',
        job2_change = 'role.job',
    },
    deathEventAvailable = function()
        return true
    },
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
            identifier = xPlayer.identifier,
            job = xPlayer.job and { name = xPlayer.job.name, label = xPlayer.job.label, grade = xPlayer.job.grade },
            job2 = xPlayer.job2 and { name = xPlayer.job2.name, label = xPlayer.job2.label, grade = xPlayer.job2.grade },
            group = xPlayer.group,
        }

        -- getMoney/getAccount are standard on every ESX legacy build, but
        -- wrap defensively in case a fork renames or removes one.
        pcall(function() info.cash = xPlayer.getMoney() end)
        pcall(function()
            local bank = xPlayer.getAccount('bank')
            info.bank = bank and bank.money
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
    capabilities = {
        'character.state',
        'economy.balance',
    },
    eventCapabilities = {
        player_death = 'combat.death',
        money_change = 'economy.transaction',
        job_change = 'role.job',
        gang_change = 'role.gang',
    },
    deathEventAvailable = function()
        return GetResourceState('qb-ambulancejob') == 'started'
            or GetResourceState('qbx-medical') == 'started'
            or GetResourceState('baseevents') == 'started'
    },
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
            citizenid = data.citizenid, -- the actual per-character id; `license` (used elsewhere) is per Rockstar account
            charinfo = data.charinfo and {
                firstname = data.charinfo.firstname,
                lastname = data.charinfo.lastname,
            },
            job = data.job and { name = data.job.name, label = data.job.label, grade = data.job.grade, onDuty = data.job.onduty },
            gang = data.gang and { name = data.gang.name, label = data.gang.label, grade = data.gang.grade },
            money = data.money, -- { cash, bank, crypto } as tracked by QBCore itself

            -- Shape varies by QBCore fork (health/hunger/thirst/stress/isdead
            -- etc aren't all guaranteed keys) so it's passed through as-is
            -- rather than cherry-picked — jsonb doesn't care about the shape.
            metadata = data.metadata,
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
            if source then emit(source, 'character_loaded', { citizenid = Player.PlayerData.citizenid }) end
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
        -- baseevents supplies the victim through the server-event context and
        -- the killer as its first argument. Capture both sides when available
        -- so Player 360° and Event Investigator can trace an interaction from
        -- either participant, rather than treating every death as actor-only.
        AddEventHandler('baseevents:onPlayerKilled', function(killerSource, deathData)
            emit(source, 'player_death', {
                killerLicense = licenseForSource(killerSource),
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
    capabilities = QBCoreAdapter.capabilities,
    eventCapabilities = QBCoreAdapter.eventCapabilities,
    deathEventAvailable = QBCoreAdapter.deathEventAvailable,
}
Adapters.qbcore = QBCoreAdapter

-- ---------------------------------------------------------------------------
-- Fallback: no framework, vanilla natives only
-- ---------------------------------------------------------------------------
Adapters.vanilla = {
    capabilities = {},
    eventCapabilities = {},
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

function Framework.GetCapabilities()
    local capabilities = {
        'session.lifecycle',
        'population.heartbeat',
        'activity.afk_aggregate',
        'identity.identifiers',
    }
    for _, capability in ipairs(active.capabilities or {}) do
        capabilities[#capabilities + 1] = capability
    end
    if Config.CollectFrameworkEvents then
        local seen = {}
        for _, eventType in ipairs(Config.TrackedEvents or {}) do
            local capability = active.eventCapabilities and active.eventCapabilities[eventType]
            local deathUnavailable = capability == 'combat.death'
                and active.deathEventAvailable
                and not active:deathEventAvailable()
            if capability and not deathUnavailable and not seen[capability] then
                capabilities[#capabilities + 1] = capability
                seen[capability] = true
            end
        end
    end
    if Config.CollectConductActions then
        capabilities[#capabilities + 1] = 'moderation.audit_import'
    end
    return capabilities
end

function Framework.RegisterEvents(emit)
    if not Config.CollectFrameworkEvents then return end
    local ok, err = pcall(function() active:registerEvents(emit) end)
    if not ok then
        print(('[guildrate-collector] failed to register %s events: %s'):format(activeName, tostring(err)))
    end
end
