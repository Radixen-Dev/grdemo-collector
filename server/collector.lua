-- Core collector: session tracking + HTTP delivery to the GuildRate API.
-- Framework-specific detail is handled entirely by framework.lua.

local openSessions = {} -- [source] = { identifiers = {...}, joinedAt = os.time() }
local emitEvent -- forward declaration: session-start callbacks flush queued events
local insecureUrlWarningLogged = false

local function eventKey(source)
    return ('%s-%s-%s-%s'):format(os.time(), GetGameTimer(), source or 0, math.random(100000, 999999))
end

local function apiPost(path, body, cb)
    if Config.ApiKey == '' then
        print('[guildrate-collector] guildrate_api_key is not set, skipping report to ' .. path)
        return
    end

    -- Server owners commonly paste an API URL with a trailing slash. Normalize
    -- it here so concatenating an endpoint never produces `//api/...`, which
    -- Cloudflare custom-domain routing rejects before the Worker can handle it.
    local apiBaseUrl = Config.ApiUrl:gsub('/+$', '')

    -- Local development is allowed to use HTTP, but production telemetry and
    -- the API key must never be sent to a remote clear-text endpoint.
    local scheme = apiBaseUrl:match('^(https?)://')
    local loopback = apiBaseUrl:match('^http://localhost[:/]')
        or apiBaseUrl:match('^http://127%.0%.0%.1[:/]')
        or apiBaseUrl:match('^http://%[::1%][:/]')
        or apiBaseUrl:match('^http://::1[:/]')
    if scheme ~= 'https' and not loopback then
        if not insecureUrlWarningLogged then
            print('[guildrate-collector] refusing non-HTTPS remote API URL; set guildrate_api_url to an https:// endpoint')
            insecureUrlWarningLogged = true
        end
        return
    end

    PerformHttpRequest(apiBaseUrl .. path, function(statusCode, response, headers, errorData)
        if statusCode ~= 200 and statusCode ~= 201 then
            local detail = tostring(errorData or ''):gsub('[\r\n]', ' ')
            if #detail > 160 then detail = detail:sub(1, 160) .. '…' end
            local escapedKey = Config.ApiKey:gsub('([%^%$%(%)%%%.%[%]%*%+%-%?])', '%%%1')
            detail = detail:gsub(escapedKey, '[redacted]')
            print(('[guildrate-collector] %s -> HTTP %s%s'):format(
                path,
                tostring(statusCode),
                detail ~= '' and (' (' .. detail .. ')') or ''
            ))
        end
        if cb then cb(statusCode, response) end
    end, 'POST', json.encode(body), {
        ['Content-Type'] = 'application/json',
        ['X-Api-Key'] = Config.ApiKey,
    })
end

local function getIdentifiers(source)
    local ids = {}
    for _, id in ipairs(GetPlayerIdentifiers(source)) do
        local kind = id:match('^(%a+):')
        -- The license is the sole stable identifier needed by Analytics.
        -- Do not forward Discord, Steam, IP, or other platform identifiers.
        if kind == 'license' and id:match('^license:[%x]+$') then ids.license = id end
    end
    return ids
end

-- ---------------------------------------------------------------------------
-- Sessions
-- ---------------------------------------------------------------------------

local function startSession(source, name)
    if openSessions[source] then return openSessions[source] end

    local identifiers = getIdentifiers(source)

    if not identifiers.license then
        return nil -- no stable identifier, nothing worth reporting
    end

    openSessions[source] = {
        identifiers = identifiers,
        name = name,
        joinedAt = os.time(),
        pendingEvents = {},
        activity = {
            stationarySeconds = 0,
            pendingAfkSeconds = 0,
            reportSequence = 0,
            reportNonce = eventKey(source),
        },
    }

    apiPost('/api/ingest/session/start', {
        license = identifiers.license,
        name = name,
        identifiers = identifiers,
        framework = Framework.GetName(),
    }, function(_, response)
        local ok, decoded = pcall(json.decode, response)
        if ok and decoded and decoded.sessionId and openSessions[source] then
            local session = openSessions[source]
            session.sessionId = decoded.sessionId

            -- Framework events can arrive before the API has acknowledged a
            -- session (especially after this resource is restarted mid-play).
            -- Replaying them here preserves the event and lets the API attach
            -- it to the player and current character rather than dropping it.
            local pending = session.pendingEvents or {}
            session.pendingEvents = {}
            for _, event in ipairs(pending) do
                if emitEvent then emitEvent(source, event.eventType, event.payload) end
            end
        end
    end)

    return openSessions[source]
end

AddEventHandler('playerConnecting', function(name, _setKickReason, deferrals)
    startSession(source, name)
end)

AddEventHandler('playerDropped', function(reason)
    local source = source
    local session = openSessions[source]
    if not session then return end

    apiPost('/api/ingest/session/end', {
        sessionId = session.sessionId,
        license = session.identifiers.license,
    })

    openSessions[source] = nil
end)

-- ---------------------------------------------------------------------------
-- Framework events -> analytics events
-- ---------------------------------------------------------------------------

local trackedEventSet = {}
for _, eventType in ipairs(Config.TrackedEvents) do
    trackedEventSet[eventType] = true
end
if Config.CollectConductActions then trackedEventSet.conduct_action = true end

local function copyMoney(money)
    local snapshot = {}
    for moneyType, amount in pairs(money or {}) do
        if type(amount) == 'number' then snapshot[moneyType] = amount end
    end
    return snapshot
end

-- Context comes from another resource. Detach it before a session-start
-- callback can queue it, so that resource cannot alter collector-owned fields
-- (or the recorded context) after TriggerEvent has returned.
local function copyConductContext(context, depth, seen)
    if type(context) ~= 'table' then return {} end
    if depth >= 3 or seen[context] then return {} end

    seen[context] = true
    local copied = {}
    local entries = 0
    for key, value in pairs(context) do
        if entries >= 64 then break end
        if type(key) == 'string' and key ~= 'action' and key ~= 'sourceResource' then
            local valueType = type(value)
            if valueType == 'string' or valueType == 'number' or valueType == 'boolean' then
                copied[key] = value
                entries = entries + 1
            elseif valueType == 'table' then
                copied[key] = copyConductContext(value, depth + 1, seen)
                entries = entries + 1
            end
        end
    end
    seen[context] = nil
    return copied
end

emitEvent = function(source, eventType, payload)
    if not trackedEventSet[eventType] then return end

    local session = openSessions[source]
    if not session then
        session = startSession(source, GetPlayerName(source) or ('Player ' .. tostring(source)))
        if not session then
            print(('[guildrate-collector] unable to recover %s for source %s: no stable license'):format(eventType, tostring(source)))
            return
        end
    end

    if not session.sessionId then
        table.insert(session.pendingEvents, { eventType = eventType, payload = payload })
        return
    end

    payload = payload or {}

    -- Framework adapters return an intentionally small, analytics-oriented
    -- shape. Event payloads are also allowlisted here so a framework update
    -- cannot accidentally cause arbitrary metadata or identifiers to leak.
    local safePayload = {}
    local function safeText(value, maxLength)
        if type(value) ~= 'string' then return nil end
        value = value:gsub('[%z\r\n]', ' ')
        return #value > maxLength and value:sub(1, maxLength) or value
    end
    local function safeJob(value)
        if type(value) ~= 'table' then return nil end
        return {
            name = safeText(value.name, 128),
            label = safeText(value.label, 128),
            grade = type(value.grade) == 'number' and value.grade or nil,
            onDuty = type(value.onDuty) == 'boolean' and value.onDuty or nil,
        }
    end
    if eventType == 'player_death' then
        safePayload.weaponHash = type(payload.weaponHash) == 'number' and payload.weaponHash or nil
        safePayload.killerType = type(payload.killerType) == 'number' and payload.killerType or nil
    elseif eventType == 'job_change' then
        safePayload.job = safeJob(payload.job)
        safePayload.previousJob = safeText(payload.previousJob, 128)
    elseif eventType == 'job2_change' then
        safePayload.job2 = safeJob(payload.job2)
        safePayload.previousJob2 = safeText(payload.previousJob2, 128)
    elseif eventType == 'gang_change' then
        safePayload.gang = safeJob(payload.gang)
    elseif eventType == 'group_change' then
        safePayload.group = safeText(payload.group, 128)
    elseif eventType == 'money_change' then
        for _, key in ipairs({ 'moneyType', 'account', 'operation' }) do
            safePayload[key] = safeText(payload[key], 128)
        end
        for _, key in ipairs({ 'amount', 'balance', 'previousAmount' }) do
            if type(payload[key]) == 'number' then safePayload[key] = payload[key] end
        end
        if payload.observedByHeartbeat == true then safePayload.observedByHeartbeat = true end
    end
    safePayload.playerInfo = Framework.GetPlayerInfo(source)
    payload = safePayload

    -- Keep the heartbeat fallback in sync with framework-originated money
    -- events so one balance change is not reported twice.
    if eventType == 'money_change' and payload.playerInfo and payload.playerInfo.money then
        session.moneySnapshot = copyMoney(payload.playerInfo.money)
    end

    -- Events stay attributable to their actor, but do not transmit other
    -- players' identifiers or create relationship graphs from game events.
    local participants = { { role = 'actor', license = session.identifiers.license } }

    apiPost('/api/ingest/event', {
        license = session.identifiers.license,
        eventType = eventType,
        payload = payload,
        occurredAt = os.date('!%Y-%m-%dT%H:%M:%SZ'),
        schemaVersion = 1,
        idempotencyKey = eventKey(source),
        participants = participants,
    })
end

-- This intentionally uses AddEventHandler, not RegisterNetEvent: only code
-- running on the server can report a conduct action. The collector is an
-- observation sink, never an authority that performs the action itself.
AddEventHandler('guildrate:conductAction', function(targetSource, action, context)
    if not Config.CollectConductActions then return end
    local invokingResource = GetInvokingResource()
    if invokingResource == nil then
        print('[guildrate-collector] ignored conduct action without a server resource caller')
        return
    end
    if type(targetSource) ~= 'number' or type(action) ~= 'string' then return end
    local normalizedAction = action:lower()
    if normalizedAction ~= 'warn' and normalizedAction ~= 'kick' and normalizedAction ~= 'ban' then return end
    local payload = copyConductContext(context, 0, {})
    payload.action = normalizedAction
    payload.sourceResource = invokingResource
    emitEvent(targetSource, 'conduct_action', payload)
end)

local function observeMoneyChanges(source, session)
    local playerInfo = Framework.GetPlayerInfo(source)
    local money = playerInfo and playerInfo.money
    if type(money) ~= 'table' then return end

    if session.moneySnapshot then
        for moneyType, amount in pairs(money) do
            local previousAmount = session.moneySnapshot[moneyType]
            if type(amount) == 'number' and type(previousAmount) == 'number' and amount ~= previousAmount then
                emitEvent(source, 'money_change', {
                    moneyType = moneyType,
                    -- The framework event normally supplies a transaction
                    -- delta. Heartbeat observation only sees two balances,
                    -- so report their difference rather than accidentally
                    -- treating the entire resulting balance as an action.
                    amount = math.abs(amount - previousAmount),
                    balance = amount,
                    previousAmount = previousAmount,
                    operation = amount > previousAmount and 'add' or 'remove',
                    observedByHeartbeat = true,
                })
            end
        end
    end

    session.moneySnapshot = copyMoney(money)
end

-- ---------------------------------------------------------------------------
-- AFK accounting
-- ---------------------------------------------------------------------------

local function playerPosition(source)
    local okPed, ped = pcall(GetPlayerPed, source)
    if not okPed or not ped or ped <= 0 then return nil end
    local okCoords, coords = pcall(GetEntityCoords, ped)
    if not okCoords or not coords or type(coords.x) ~= 'number' or type(coords.y) ~= 'number' or type(coords.z) ~= 'number' then return nil end
    return { x = coords.x, y = coords.y, z = coords.z }
end

local function flushAfkTime(source, session)
    local activity = session.activity
    if activity.reportInFlight or activity.pendingAfkSeconds <= 0 then return end

    local seconds = math.min(900, activity.pendingAfkSeconds)
    local key = ('afk-%s-%d'):format(activity.reportNonce, activity.reportSequence)
    activity.reportInFlight = true
    -- Keep the same key until a successful response. If the response is lost,
    -- the API's idempotency ledger safely treats this retry as already applied.
    apiPost('/api/ingest/activity', {
        license = session.identifiers.license,
        afkSeconds = seconds,
        idempotencyKey = key,
    }, function(statusCode)
        activity.reportInFlight = false
        if statusCode == 200 or statusCode == 201 then
            activity.pendingAfkSeconds = math.max(0, activity.pendingAfkSeconds - seconds)
            activity.reportSequence = activity.reportSequence + 1
        end
    end)
end

local function observeAfkTime(source, session, observedAt)
    local position = playerPosition(source)
    if not position then return end

    local activity = session.activity
    if not activity.lastObservedAt or not activity.lastPosition then
        activity.lastObservedAt = observedAt
        activity.lastPosition = position
        return
    end

    local elapsed = observedAt - activity.lastObservedAt
    local previous = activity.lastPosition
    activity.lastObservedAt = observedAt
    activity.lastPosition = position
    if elapsed <= 0 or elapsed > Config.AfkMaxSampleGapSec then
        activity.stationarySeconds = 0
        return
    end

    local dx = position.x - previous.x
    local dy = position.y - previous.y
    local dz = position.z - previous.z
    local toleranceSquared = Config.AfkMovementTolerance * Config.AfkMovementTolerance
    if dx * dx + dy * dy + dz * dz > toleranceSquared then
        activity.stationarySeconds = 0
        return
    end

    local before = activity.stationarySeconds
    activity.stationarySeconds = before + elapsed
    local newlyAfk = math.max(0, activity.stationarySeconds - Config.AfkThresholdSec)
        - math.max(0, before - Config.AfkThresholdSec)
    if newlyAfk > 0 then activity.pendingAfkSeconds = activity.pendingAfkSeconds + newlyAfk end
    flushAfkTime(source, session)
end

-- ---------------------------------------------------------------------------
-- Heartbeat: keeps server.last_seen_at fresh and reports live player count
-- ---------------------------------------------------------------------------

local function heartbeat()
    local players = {}
    local observedAt = os.time()
    -- Use the authoritative player list rather than just our memory. This
    -- recovers sessions when the resource is started or restarted while users
    -- are already connected.
    for _, playerSource in ipairs(GetPlayers()) do
        local source = tonumber(playerSource)
        local session = source and (openSessions[source] or startSession(source, GetPlayerName(source) or ('Player ' .. playerSource)))
        if session then
            observeAfkTime(source, session, observedAt)
            players[#players + 1] = { license = session.identifiers.license, playerInfo = Framework.GetPlayerInfo(source) }
            observeMoneyChanges(source, session)
        end
    end

    apiPost('/api/ingest/heartbeat', {
        playerCount = #players,
        maxPlayers = GetConvarInt('sv_maxclients', 0),
        framework = Framework.GetName(),
        collector = {
            version = GetResourceMetadata(GetCurrentResourceName(), 'version', 0) or '0.2.0',
            framework = Framework.GetName(),
            capabilities = Framework.GetCapabilities(),
        },
        players = players,
    })
end

CreateThread(function()
    Framework.Init()
    Framework.RegisterEvents(emitEvent)

    -- Resources can be restarted while players are online. Re-register those
    -- players so reporting continues instead of losing the in-memory session
    -- map until each player reconnects.
    for _, playerSource in ipairs(GetPlayers()) do
        local source = tonumber(playerSource)
        if source then
            startSession(source, GetPlayerName(source) or ('Player ' .. playerSource))
        end
    end

    while true do
        Wait(Config.HeartbeatIntervalSec * 1000)
        heartbeat()
    end
end)
