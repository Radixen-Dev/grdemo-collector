-- Core collector: session tracking + HTTP delivery to the GuildRate API.
-- Framework-specific detail is handled entirely by framework.lua.

local openSessions = {} -- [source] = { identifiers = {...}, joinedAt = os.time() }
local emitEvent -- forward declaration: session-start callbacks flush queued events

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

    PerformHttpRequest(apiBaseUrl .. path, function(statusCode, response, headers, errorData)
        if statusCode ~= 200 and statusCode ~= 201 then
            print(('[guildrate-collector] %s -> HTTP %s: %s%s'):format(
                path,
                tostring(statusCode),
                tostring(response),
                errorData and (' (' .. tostring(errorData) .. ')') or ''
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
        if kind then ids[kind] = id end
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
        reason = reason,
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

local function copyMoney(money)
    local snapshot = {}
    for moneyType, amount in pairs(money or {}) do
        if type(amount) == 'number' then snapshot[moneyType] = amount end
    end
    return snapshot
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
    payload.playerInfo = Framework.GetPlayerInfo(source)

    -- Keep the heartbeat fallback in sync with framework-originated money
    -- events so one balance change is not reported twice.
    if eventType == 'money_change' and payload.playerInfo and payload.playerInfo.money then
        session.moneySnapshot = copyMoney(payload.playerInfo.money)
    end

    local participants = { { role = 'actor', license = session.identifiers.license } }
    if payload.targetLicense then table.insert(participants, { role = 'target', license = payload.targetLicense }) end
    if payload.victimLicense then table.insert(participants, { role = 'victim', license = payload.victimLicense }) end
    if payload.recipientLicense then table.insert(participants, { role = 'recipient', license = payload.recipientLicense }) end
    if payload.killerLicense then table.insert(participants, { role = 'killer', license = payload.killerLicense }) end

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
-- Heartbeat: keeps server.last_seen_at fresh and reports live player count
-- ---------------------------------------------------------------------------

local function heartbeat()
    local players = {}
    -- Use the authoritative player list rather than just our memory. This
    -- recovers sessions when the resource is started or restarted while users
    -- are already connected.
    for _, playerSource in ipairs(GetPlayers()) do
        local source = tonumber(playerSource)
        local session = source and (openSessions[source] or startSession(source, GetPlayerName(source) or ('Player ' .. playerSource)))
        if session then
            players[#players + 1] = { license = session.identifiers.license, playerInfo = Framework.GetPlayerInfo(source) }
            observeMoneyChanges(source, session)
        end
    end

    apiPost('/api/ingest/heartbeat', {
        playerCount = #players,
        maxPlayers = GetConvarInt('sv_maxclients', 0),
        framework = Framework.GetName(),
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
