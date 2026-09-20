-- Unit tests for the collector's capability manifest. These run with stock
-- Lua and mock only the FiveM globals needed while selecting an adapter.

local root = (... and (...):match('^(.*)/test/[^/]+$')) or '.'

local function includes(values, target)
    for _, value in ipairs(values) do
        if value == target then return true end
    end
    return false
end

local function assertCapabilities(actual, required, forbidden)
    for _, capability in ipairs(required) do
        assert(includes(actual, capability), 'missing capability: ' .. capability)
    end
    for _, capability in ipairs(forbidden) do
        assert(not includes(actual, capability), 'unexpected capability: ' .. capability)
    end
end

local function capabilitiesFor(config, states)
    Config = config
    Framework = nil
    exports = {
        ['es_extended'] = { getSharedObject = function() return {} end },
        ['qb-core'] = { GetCoreObject = function() return {} end },
    }
    GetResourceState = function(name) return states[name] or 'missing' end
    AddEventHandler = function() end
    print = function() end
    assert(loadfile(root .. '/server/framework.lua'))()
    Framework.Init()
    return Framework.GetCapabilities()
end

local generic = {
    'session.lifecycle', 'population.heartbeat', 'activity.afk_aggregate', 'identity.identifiers',
}

local off = capabilitiesFor({ CollectFrameworkEvents = false, CollectConductActions = false, TrackedEvents = { 'money_change' } }, { ['qb-core'] = 'started' })
assertCapabilities(off, {
    'session.lifecycle', 'population.heartbeat', 'activity.afk_aggregate', 'identity.identifiers',
    'character.state', 'economy.balance',
}, { 'economy.transaction', 'role.job', 'role.gang', 'combat.death' })

local conductEnabled = capabilitiesFor({ CollectFrameworkEvents = false, CollectConductActions = true, TrackedEvents = {} }, {})
assertCapabilities(conductEnabled, {
    'session.lifecycle', 'population.heartbeat', 'activity.afk_aggregate', 'identity.identifiers', 'moderation.audit_import',
}, {})

local filtered = capabilitiesFor({ CollectFrameworkEvents = true, TrackedEvents = { 'job_change' } }, { qbx_core = 'started', ['qb-core'] = 'started' })
assertCapabilities(filtered, {
    'session.lifecycle', 'population.heartbeat', 'activity.afk_aggregate', 'identity.identifiers',
    'character.state', 'economy.balance', 'role.job',
}, { 'economy.transaction', 'role.gang', 'combat.death' })

local noDeathResource = capabilitiesFor({ CollectFrameworkEvents = true, TrackedEvents = { 'player_death' } }, { ['qb-core'] = 'started' })
assertCapabilities(noDeathResource, generic, { 'combat.death' })

local deathResource = capabilitiesFor({ CollectFrameworkEvents = true, TrackedEvents = { 'player_death' } }, { ['qb-core'] = 'started', baseevents = 'started' })
assertCapabilities(deathResource, {
    'session.lifecycle', 'population.heartbeat', 'activity.afk_aggregate', 'identity.identifiers', 'combat.death',
}, {})
