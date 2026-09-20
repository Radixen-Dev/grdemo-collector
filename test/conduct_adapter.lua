-- Contract tests for the opt-in server-side conduct observation adapter.
-- Run with stock Lua: FiveM globals are deliberately mocked at the boundary.

local root = (... and (...):match('^(.*)/test/[^/]+$')) or '.'

local function assertEqual(actual, expected, message)
    assert(actual == expected, (message or 'unexpected value') .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual))
end

local function countEntries(values)
    local count = 0
    for _ in pairs(values) do count = count + 1 end
    return count
end

local function loadCollector(enabled, invokingResource, deferCallbacks)
    local handlers = {}
    local requests = {}
    local registerNetEventCalls = 0
    local pendingCallbacks = {}

    Config = {
        ApiKey = 'test-key',
        ApiUrl = 'https://example.test/',
        CollectConductActions = enabled,
        TrackedEvents = {},
        HeartbeatIntervalSec = 60,
        AfkThresholdSec = 300,
        AfkMovementTolerance = 1.5,
        AfkMaxSampleGapSec = 120,
    }
    Framework = {
        GetName = function() return 'vanilla' end,
        GetPlayerInfo = function() return {} end,
        GetCapabilities = function() return {} end,
        Init = function() end,
        RegisterEvents = function() end,
    }
    json = {
        encode = function(value) return value end,
        decode = function() return { sessionId = 'session-1' } end,
    }
    AddEventHandler = function(name, handler) handlers[name] = handler end
    RegisterNetEvent = function() registerNetEventCalls = registerNetEventCalls + 1 end
    GetInvokingResource = function() return invokingResource end
    GetPlayerIdentifiers = function() return { 'license:abcdef0123456789', 'discord:123' } end
    GetPlayerName = function() return 'Test Player' end
    GetGameTimer = function() return 10 end
    GetPlayers = function() return {} end
    GetConvarInt = function() return 0 end
    GetResourceMetadata = function() return '0.0.0-test' end
    GetCurrentResourceName = function() return 'guildrate-collector' end
    CreateThread = function() end
    Wait = function() end
    print = function() end
    PerformHttpRequest = function(url, callback, method, body, headers)
        requests[#requests + 1] = { url = url, method = method, body = body, headers = headers }
        if deferCallbacks then
            pendingCallbacks[#pendingCallbacks + 1] = function() callback(201, '{}') end
        else
            callback(201, '{}')
        end
    end

    assert(loadfile(root .. '/server/collector.lua'))()
    return handlers['guildrate:conductAction'], requests, function() return registerNetEventCalls end, function()
        local callbacks = pendingCallbacks
        pendingCallbacks = {}
        for _, callback in ipairs(callbacks) do callback() end
    end
end

-- Disabled means the event is a complete no-op even when a server resource emits it.
local report, requests = loadCollector(false, 'staff-resource')
report(42, 'warn', { note = 'ignored' })
assertEqual(#requests, 0, 'disabled adapter must not report')

-- A console/client-originated event has no resource identity and is rejected.
report, requests = loadCollector(true, nil)
report(42, 'warn', { note = 'rejected' })
assertEqual(#requests, 0, 'unattributed caller must not report')

-- Unsupported action types and malformed targets are rejected before any session is created.
report, requests = loadCollector(true, 'staff-resource')
report(42, 'note', {})
report('42', 'warn', {})
assertEqual(#requests, 0, 'unsupported or malformed action must not report')

-- An accepted event records the already-made decision, attributes it to the actual
-- server resource, and cannot be spoofed through the supplied context table.
local registerNetEventCalls
report, requests, registerNetEventCalls = loadCollector(true, 'staff-resource')
local context = { note = 'reviewed by staff', action = 'ban', sourceResource = 'spoofed-resource' }
report(42, 'WARN', context)
assertEqual(#requests, 2, 'accepted action should create a session then emit one observation')
assertEqual(requests[2].url, 'https://example.test/api/ingest/event', 'event endpoint')
assertEqual(requests[2].body.eventType, 'conduct_action', 'event type')
assertEqual(requests[2].body.payload.action, 'warn', 'normalized action')
assertEqual(requests[2].body.payload.sourceResource, 'staff-resource', 'source must come from FiveM')
assertEqual(requests[2].body.payload.note, 'reviewed by staff', 'safe context should be retained')
assertEqual(registerNetEventCalls(), 0, 'adapter must never expose a network event')

-- A just-connected player's action is queued until session acknowledgement.
-- Mutating the caller-owned table after TriggerEvent returns must not alter the
-- recorded observation when that queued event is eventually flushed.
local flushCallbacks
report, requests, _, flushCallbacks = loadCollector(true, 'staff-resource', true)
context = { note = 'original', action = 'ban', sourceResource = 'spoofed-resource' }
report(42, 'warn', context)
assertEqual(#requests, 1, 'session acknowledgement should be pending')
context.note = 'mutated after report'
context.action = 'ban'
context.sourceResource = 'mutated-resource'
flushCallbacks()
assertEqual(#requests, 2, 'queued observation should flush after acknowledgement')
assertEqual(requests[2].body.payload.action, 'warn', 'queued action must remain collector-derived')
assertEqual(requests[2].body.payload.sourceResource, 'staff-resource', 'queued source must remain collector-derived')
assertEqual(requests[2].body.payload.note, 'original', 'queued context must be detached from the caller')

-- Context is bounded across the entire traversal: a nested table cannot turn
-- a modest root limit into an exponentially larger queued or HTTP payload.
report, requests = loadCollector(true, 'staff-resource')
context = { nested = {}, oversized = string.rep('x', 1025) }
for index = 1, 80 do context.nested['field' .. index] = 'x' end
report(42, 'warn', context)
local boundedPayload = requests[2].body.payload
assertEqual(boundedPayload.oversized, nil, 'oversized scalar context must be discarded')
assertEqual(countEntries(boundedPayload.nested), 63, 'nested entries must share the global field budget')

print('conduct adapter tests passed')
