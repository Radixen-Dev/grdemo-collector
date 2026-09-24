-- Core collector: session tracking + HTTP delivery to the GuildRate API.
-- Framework-specific detail is handled entirely by framework.lua.

local openSessions = {} -- [source] = { identifiers = {...}, joinedAt = os.time() }
local emitEvent -- forward declaration: session-start callbacks flush queued events
local endVehicleTrip -- forward declaration: playerDropped closes an open trip before the session is torn down
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

    -- Close any open vehicle trip before the session disappears -- there is
    -- no later poll that will ever observe this player again. Must run
    -- before apiPost/openSessions[source] = nil below: endVehicleTrip calls
    -- emitEvent, which requires the session to still be present in
    -- openSessions. If sessionId never resolved, this queues into
    -- pendingEvents and is lost along with the rest of that queue -- the
    -- same accepted loss class as every other pendingEvents case in this
    -- file, not a new one.
    if session.vehicleTrip then endVehicleTrip(source, session, 'disconnected') end

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

local function copyMoney(money)
    local snapshot = {}
    for moneyType, amount in pairs(money or {}) do
        if type(amount) == 'number' then snapshot[moneyType] = amount end
    end
    return snapshot
end

-- ---------------------------------------------------------------------------
-- Track API: an open front door for anything outside the curated ESX/QBCore/
-- QBox adapters -- a custom or modified framework, or a non-RP gamemode
-- (racing, deathmatch, minigames) that has no framework at all. Every such
-- event is namespaced "custom.<name>" so it can never collide with a
-- framework event name, and is validated both here and, authoritatively, by
-- the Worker (worker/ingest.ts applies the same shape rules server-side).
-- ---------------------------------------------------------------------------

local CUSTOM_EVENT_PREFIX = 'custom.'
local CUSTOM_EVENT_NAME_SUFFIX_PATTERN = '^[%l%d_]+$'
local MAX_CUSTOM_EVENT_NAME_LENGTH = 80
local MAX_CUSTOM_PAYLOAD_KEYS = 20
local MAX_CUSTOM_STRING_LENGTH = 200
local MAX_CUSTOM_ARRAY_ITEMS = 20
local MAX_CUSTOM_PAYLOAD_BYTES = 2000
local TRACK_EVENT_WINDOW_MS = 60000

local function hasCustomPrefix(name)
    return type(name) == 'string' and name:sub(1, #CUSTOM_EVENT_PREFIX) == CUSTOM_EVENT_PREFIX
end

-- Strips control characters that have no business in a stored label. Shared
-- by the framework-payload branch below and the custom-payload sanitizer,
-- so there is exactly one "strip control characters" guarantee instead of
-- two independently maintained ones -- the two paths still apply different
-- length policies on top of it (see scrubText vs sanitizeCustomPayload),
-- because they are different trust boundaries: framework fields come from
-- this repo's own curated adapters and are safe to truncate, while Track
-- API fields come from arbitrary third-party scripts and are held to the
-- stricter, reject-not-truncate contract documented in README.md.
local function stripControlChars(value)
    if type(value) ~= 'string' then return nil end
    return value:gsub('[%z\r\n]', ' ')
end

-- Framework payload fields: scrub, then truncate rather than reject on
-- overflow (this data comes from the curated adapters, not arbitrary
-- third-party input).
local function scrubText(value, maxLength)
    local scrubbed = stripControlChars(value)
    if not scrubbed then return nil end
    return #scrubbed > maxLength and scrubbed:sub(1, maxLength) or scrubbed
end

-- Custom payload fields: scrub, then reject (not truncate) on overflow --
-- the Track API contract documented in README.md promises a 400/false
-- rejection for an oversized field, not a silent truncation. Stripping
-- control characters never changes string length (each match is replaced
-- one-for-one with a space), so checking the scrubbed length is equivalent
-- to checking the original.
local function customScalarText(value)
    local scrubbed = stripControlChars(value)
    if not scrubbed or #scrubbed > MAX_CUSTOM_STRING_LENGTH then return nil end
    return scrubbed
end

local function isCustomScalar(value)
    local kind = type(value)
    return kind == 'boolean' or kind == 'number'
end

-- A flat object of scalars or scalar arrays only -- deliberately tighter
-- than framework event payloads, since a custom event can originate from
-- any third-party script calling the public TrackEvent export. Returns
-- (sanitizedPayload, true) or (nil, false) if the shape is rejected.
local function sanitizeCustomPayload(payload)
    if payload == nil then return {}, true end
    if type(payload) ~= 'table' then return nil, false end
    local safe = {}
    local keyCount = 0
    for key, value in pairs(payload) do
        if type(key) ~= 'string' then return nil, false end
        keyCount = keyCount + 1
        if keyCount > MAX_CUSTOM_PAYLOAD_KEYS then return nil, false end
        if type(value) == 'table' then
            -- `ipairs` silently visits zero elements on a non-array table
            -- (e.g. a nested object like `{ deep = 'value' }`), which would
            -- let one through disguised as an empty array. Require every key
            -- to be a dense 1-based integer sequence first, so a nested
            -- object or a sparse/non-sequential table is rejected outright
            -- rather than laundered into `{}`. Bail out the moment the count
            -- goes over budget instead of finishing the scan, so a caller
            -- can't force a full walk of an arbitrarily large table.
            local totalKeys = 0
            for tableKey in pairs(value) do
                totalKeys = totalKeys + 1
                if totalKeys > MAX_CUSTOM_ARRAY_ITEMS
                    or type(tableKey) ~= 'number' or tableKey % 1 ~= 0 or tableKey < 1 then
                    return nil, false
                end
            end
            local safeArray = {}
            for index = 1, totalKeys do
                local item = value[index]
                if item == nil then return nil, false end
                if type(item) == 'string' then
                    item = customScalarText(item)
                    if item == nil then return nil, false end
                elseif not isCustomScalar(item) then
                    return nil, false
                end
                safeArray[index] = item
            end
            safe[key] = safeArray
        elseif type(value) == 'string' then
            local scrubbed = customScalarText(value)
            if scrubbed == nil then return nil, false end
            safe[key] = scrubbed
        elseif isCustomScalar(value) then
            safe[key] = value
        else
            return nil, false
        end
    end
    local ok, encoded = pcall(json.encode, safe)
    if not ok or #encoded > MAX_CUSTOM_PAYLOAD_BYTES then return nil, false end
    return safe, true
end

-- Custom events share the ingest HTTP path with session/heartbeat traffic.
-- A chatty custom script -- a checkpoint fired every frame, say -- must not
-- be able to starve that load-bearing telemetry, so it gets its own,
-- tighter, per-player budget on top. The window lives on the session table
-- itself so it rides the same create/destroy lifecycle as everything else
-- in `openSessions` (cleared on disconnect in `playerDropped`) instead of
-- being a second piece of per-source state nothing tears down -- source IDs
-- are recycled by FiveM, so a standalone table keyed by source would let a
-- reconnecting player inherit a stale window. It's timed off GetGameTimer(),
-- not os.time(), so a wall-clock adjustment can't wedge a window open.
local function trackEventAllowed(session, source)
    local nowMs = GetGameTimer()
    local window = session.trackEventWindow
    if not window or nowMs - window.windowStart >= TRACK_EVENT_WINDOW_MS then
        window = { windowStart = nowMs, count = 0, warned = false }
        session.trackEventWindow = window
    end
    window.count = window.count + 1
    if window.count > Config.TrackEventMaxPerMinute then
        if not window.warned then
            print(('[guildrate-collector] TrackEvent rate limit exceeded for source %s (max %d/min); further calls this window are dropped')
                :format(tostring(source), Config.TrackEventMaxPerMinute))
            window.warned = true
        end
        return false
    end
    return true
end

-- Returns true if the event was accepted (queued for delivery or sent),
-- false if it was dropped -- callers that report the outcome to a caller
-- of their own (the TrackEvent export) must propagate this, not assume
-- success.
emitEvent = function(source, eventType, payload)
    local isCustomEvent = hasCustomPrefix(eventType)
    if not isCustomEvent and not trackedEventSet[eventType] then return false end

    local session = openSessions[source]
    if not session then
        session = startSession(source, GetPlayerName(source) or ('Player ' .. tostring(source)))
        if not session then
            print(('[guildrate-collector] unable to recover %s for source %s: no stable license'):format(eventType, tostring(source)))
            return false
        end
    end

    if isCustomEvent and not trackEventAllowed(session, source) then return false end

    if not session.sessionId then
        table.insert(session.pendingEvents, { eventType = eventType, payload = payload })
        return true
    end

    -- player_respawned is ambiguous at the source (ESX's onPlayerSpawn fires
    -- on a character's very first spawn too, not only after a death; see
    -- framework.lua). Only forward it once this session has an unmatched
    -- death to pair it with -- an ordinary join-spawn is dropped here,
    -- silently and without penalty (this is the expected, common case, not
    -- an error). session.awaitingRespawn is armed both by the player_death
    -- branch below and, independently, by observeDeathJailField's own
    -- isdead-false-to-true detection, so this gate works whether or not the
    -- dedicated player_death hooks happened to fire for a given death.
    --
    -- Deliberately placed after the pendingEvents queue above, not before:
    -- an event queued while sessionId was still unresolved re-enters
    -- emitEvent a second time on replay (see startSession's callback), and
    -- consuming the gate on the first (queue-only) pass would make the
    -- replay -- the pass that actually sends it -- find it already
    -- consumed and drop it. This runs exactly once, at the point an event
    -- is actually about to be sent.
    if eventType == 'player_respawned' then
        if not session.awaitingRespawn then return false end
        session.awaitingRespawn = false
    end

    payload = payload or {}
    local safePayload

    if isCustomEvent then
        local sanitized, ok = sanitizeCustomPayload(payload)
        if not ok then
            print(('[guildrate-collector] dropped invalid TrackEvent payload for "%s" (source %s): must be a flat object of at most %d scalar/array-of-scalar fields, %d bytes total')
                :format(eventType, tostring(source), MAX_CUSTOM_PAYLOAD_KEYS, MAX_CUSTOM_PAYLOAD_BYTES))
            return false
        end
        -- Custom events come from scripts outside the curated framework
        -- adapters, so they never carry a framework playerInfo snapshot --
        -- the Worker also refuses to project a character snapshot from one.
        safePayload = sanitized
    else
        -- Framework adapters return an intentionally small, analytics-oriented
        -- shape. Event payloads are also allowlisted here so a framework
        -- update cannot accidentally cause arbitrary metadata or identifiers
        -- to leak.
        safePayload = {}
        local function safeJob(value)
            if type(value) ~= 'table' then return nil end
            return {
                name = scrubText(value.name, 128),
                label = scrubText(value.label, 128),
                grade = type(value.grade) == 'number' and value.grade or nil,
                onDuty = type(value.onDuty) == 'boolean' and value.onDuty or nil,
            }
        end
        if eventType == 'player_death' then
            safePayload.weaponHash = type(payload.weaponHash) == 'number' and payload.weaponHash or nil
            safePayload.killerType = type(payload.killerType) == 'number' and payload.killerType or nil
            -- Arms the player_respawned gate above. Harmless to set again if
            -- observeDeathJailField already armed it independently for this
            -- same death (QBCore/QBox).
            session.awaitingRespawn = true
        elseif eventType == 'player_respawned' then
            -- No fields: this event is purely the fact and timing of the
            -- transition. Analytics pairs it with the preceding player_death
            -- (same player, next respawn in the same session) to derive
            -- "death downtime" -- see docs/METRICS_ROADMAP.md for why this is
            -- named downtime, not time-to-revive: no framework distinguishes
            -- an EMS revive from a bleed-out respawn at this signal.
        elseif eventType == 'player_jailed' then
            -- sentenceMinutes is read directly from QBCore/QBox's own
            -- metadata.injail, which both frameworks' own type/config
            -- comments label "time in minutes" -- carried as-is, not
            -- authoritative (a fork could use a different unit or a
            -- countdown that doesn't mean "sentence length").
            safePayload.sentenceMinutes = type(payload.sentenceMinutes) == 'number' and payload.sentenceMinutes or nil
        elseif eventType == 'player_released' then
            -- No fields, same reasoning as player_respawned: Analytics
            -- derives jail time served by pairing this with the preceding
            -- player_jailed.
        elseif eventType == 'job_change' then
            safePayload.job = safeJob(payload.job)
            safePayload.previousJob = scrubText(payload.previousJob, 128)
        elseif eventType == 'job2_change' then
            safePayload.job2 = safeJob(payload.job2)
            safePayload.previousJob2 = scrubText(payload.previousJob2, 128)
        elseif eventType == 'gang_change' then
            safePayload.gang = safeJob(payload.gang)
        elseif eventType == 'group_change' then
            safePayload.group = scrubText(payload.group, 128)
        elseif eventType == 'money_change' then
            for _, key in ipairs({ 'moneyType', 'account', 'operation' }) do
                safePayload[key] = scrubText(payload[key], 128)
            end
            for _, key in ipairs({ 'amount', 'balance', 'previousAmount' }) do
                if type(payload[key]) == 'number' then safePayload[key] = payload[key] end
            end
            if payload.observedByHeartbeat == true then safePayload.observedByHeartbeat = true end
        elseif eventType == 'vehicle_trip_started' or eventType == 'vehicle_trip_ended' then
            -- tripId lets Analytics join a trip's start/end by an exact key
            -- instead of positional/timestamp pairing -- both events for one
            -- trip can land in the same delivery pass with the same
            -- second-granularity occurred_at on a rapid vehicle switch. See
            -- the "Vehicle trip tracking" section above.
            safePayload.tripId = scrubText(payload.tripId, 64)
            safePayload.plate = scrubText(payload.plate, 16)
            safePayload.modelHash = type(payload.modelHash) == 'number' and payload.modelHash or nil
            safePayload.vehicleClass = type(payload.vehicleClass) == 'number' and payload.vehicleClass or nil
            if eventType == 'vehicle_trip_ended' then
                safePayload.distanceMeters = type(payload.distanceMeters) == 'number' and payload.distanceMeters or nil
                safePayload.endReason = scrubText(payload.endReason, 32)
            end
        end
        safePayload.playerInfo = Framework.GetPlayerInfo(source)
    end
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
    return true
end

-- Public Track API. Any resource can report a custom event without a
-- dedicated framework adapter:
--   local ok = exports['guildrate-collector']:TrackEvent(source, 'race_finished', {
--       track = 'sandy-shores', placement = 1, timeMs = 92340,
--   })
-- `name` is namespaced "custom.<name>" automatically if not already
-- prefixed. Returns true if the event was accepted and queued for delivery,
-- false if it was rejected (invalid source/name, no stable license,
-- oversized or malformed payload, or the per-player rate limit). Rejections
-- are logged server-side with the reason; this export never throws.
--
-- Contract (stable once released -- see README.md "Track API"):
--   - event names: lowercase letters, digits, and underscores only, at most
--     80 characters (after the "custom." namespace)
--   - payload: a flat object of at most 20 fields, each a string (<=200
--     chars), number, boolean, null, or an array of up to 20 such scalars;
--     2000 bytes total. Nested objects are rejected.
--   - rate limit: Config.TrackEventMaxPerMinute calls per player per minute
exports('TrackEvent', function(source, name, payload)
    local resolvedSource = tonumber(source)
    if not resolvedSource then
        print(('[guildrate-collector] TrackEvent rejected: source %s is not a valid player id'):format(tostring(source)))
        return false
    end
    if type(name) ~= 'string' then
        print('[guildrate-collector] TrackEvent rejected: event name must be a string')
        return false
    end

    local fullName = hasCustomPrefix(name) and name or (CUSTOM_EVENT_PREFIX .. name)
    local suffix = fullName:sub(#CUSTOM_EVENT_PREFIX + 1)
    if #suffix < 1 or #suffix > MAX_CUSTOM_EVENT_NAME_LENGTH or not suffix:match(CUSTOM_EVENT_NAME_SUFFIX_PATTERN) then
        print(('[guildrate-collector] TrackEvent rejected: "%s" must be lowercase letters, digits, and underscores only (max %d characters)')
            :format(name, MAX_CUSTOM_EVENT_NAME_LENGTH))
        return false
    end

    -- emitEvent is the single source of truth for whether the player has a
    -- stable license (it already recovers/creates the session), so its
    -- outcome is propagated here rather than re-checked with a separate,
    -- weaker liveness test that could disagree with it.
    return emitEvent(resolvedSource, fullName, payload) == true
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
-- Death downtime / jail time (QBCore/QBox core metadata only -- see
-- README.md "Character depth: death downtime and jail time" for the full
-- reasoning). isdead and injail are schema'd and defaulted by qb-core/
-- qbx_core themselves but only ever mutated by whichever job resource is
-- installed, via core's own SetMetaData/SetMetadata -- never by core
-- directly. observeDeathJailField hooks that core mutation-notification
-- mechanism (or, as a backstop, reads the current value on the heartbeat),
-- not any specific job resource's event names, so it stays correct
-- regardless of which (or whether any) job resource is installed.
--
-- One session-scoped snapshot (session.deathJailSnapshot), diffed one field
-- at a time so the same function serves three call sites: the QBox event
-- (precise, gives old/new directly), the QBCore event (coarser, gives the
-- whole current metadata table -- decomposed into two single-field calls by
-- framework.lua), and the heartbeat backstop (catches anything either event
-- missed, e.g. a job resource that mutates metadata without ever reaching a
-- listening event, up to one heartbeat interval late). Calling this
-- repeatedly with the same value is always safe: a value equal to the last
-- known one is not a transition and emits nothing.
--
-- The first observation of a field only seeds the snapshot; it never emits.
-- This is deliberate, not an oversight: a player who reconnects already
-- jailed (server restarted mid-sentence, or they logged in on a fresh
-- session after being jailed in a previous one) must not have that
-- pre-existing state misreported as a jailing that started at reconnect.
-- The corresponding tradeoff -- a sentence that started before this
-- session's first observation is invisible to it -- is the same class of
-- best-effort limitation already accepted for observeMoneyChanges above.
--
-- This snapshot is per-connection (keyed by session, same as everything
-- else in openSessions), not per-character: a character switch
-- (character_unloaded/character_loaded) does not reset it. A death as one
-- character followed by a character switch and then a respawn signal as a
-- *different* character on the same connection would be paired together as
-- one (misleadingly short) downtime sample -- a known, documented gap, not
-- silently wrong on purpose. `events` carries no character_id today to
-- disambiguate against.
local function observeDeathJailField(source, field, rawValue)
    local session = openSessions[source]
    if not session then return end
    local snapshot = session.deathJailSnapshot
    if not snapshot then
        snapshot = { seen = {} }
        session.deathJailSnapshot = snapshot
    end

    if field == 'isdead' then
        local value = rawValue == true
        if snapshot.seen.isdead then
            if snapshot.isdead == true and value == false then
                emitEvent(source, 'player_respawned', {})
            elseif snapshot.isdead == false and value == true then
                -- Independently arms the player_respawned gate in
                -- emitEvent, whether or not a dedicated player_death hook
                -- also fired for this same death (it may not have, on a
                -- fork not using any of the three known event names).
                session.awaitingRespawn = true
            end
        end
        snapshot.isdead = value
        snapshot.seen.isdead = true
    elseif field == 'injail' then
        local value = tonumber(rawValue) or 0
        if snapshot.seen.injail then
            local previous = snapshot.injail or 0
            if previous <= 0 and value > 0 then
                emitEvent(source, 'player_jailed', { sentenceMinutes = value })
            elseif previous > 0 and value <= 0 then
                emitEvent(source, 'player_released', {})
            end
        end
        snapshot.injail = value
        snapshot.seen.injail = true
    end
end

-- ---------------------------------------------------------------------------
-- Vehicle trip tracking
-- ---------------------------------------------------------------------------
-- Framework-agnostic: built entirely from vanilla FiveM natives, verified
-- server-side-callable against citizenfx/fivem's own native-decls apiset
-- metadata (GetVehiclePedIsIn, GetPedInVehicleSeat, GetVehicleNumberPlateText,
-- GetEntityModel, GetEntitySpeed are all "apiset: server"; GetVehicleClass is
-- the same read-only-vehicle-property category as GetVehicleNumberPlateText,
-- which is). No framework adapter hook exists or is needed for this -- it
-- runs identically on ESX, QBCore, QBox, and vanilla. See config.lua and
-- README.md "Vehicle trip tracking" for why vehicle ownership, purchase,
-- theft, and impound state are deliberately NOT collected here.
--
-- Poll-only design, the same shape as observeAfkTime/observeDeathJailField:
-- there is no discrete "player entered/exited vehicle" event to miss, so
-- there is no separate class of dedup bug from a missed exit signal -- a
-- trip simply ends whenever the next poll finds the player no longer driving
-- that vehicle, including "no longer connected" (playerDropped below).
--
-- Distance is accumulated as GetEntitySpeed(vehicle) * elapsed per sample (a
-- right Riemann sum: each sample's speed is read at the *end* of the
-- interval it is applied to, since that is the only point the poll actually
-- observes), not a position-delta ("chord") measurement. Chord distance has
-- a route-dependent bias that collapses towards zero on a loop (a circuit
-- lap or a there-and-back drive would under-report to near nothing even
-- though real distance was covered); integrating the vehicle's own reported
-- speed avoids that bias entirely. The remaining error is ordinary sampling
-- noise -- how much speed changes within one poll interval -- bounded by
-- Config.VehicleTrackIntervalSec, not by the shape of the route. A trip's
-- opening and closing partial intervals are covered too (see
-- endVehicleTrip): without that, every trip would lose the fraction of a
-- poll interval between the driver's real exit and the next poll noticing
-- it, and any trip shorter than one full interval would report exactly zero
-- distance every time -- both one-directional undercounts, the same failure
-- shape as chord bias, just from the sampling window instead of the path.
--
-- Vehicle identity for "is this still the same trip" purposes is the game
-- entity handle, not the plate: plates on ambient/non-player-owned vehicles
-- are randomly generated by the game and are not a meaningful cross-session
-- vehicle identity anyway. This is also why this feature reports driving
-- activity (trip counts/distance by model), not a per-vehicle odometer --
-- see docs/METRICS_ROADMAP.md "Vehicles" in grdemo-analytics. The plate is
-- still carried in the payload for transparency/debugging.
--
-- Only the *driver* (seat -1) has an open trip -- passengers are not
-- tracked. A player who is promoted/demoted between driver and passenger
-- (or who switches vehicles entirely) mid-poll has their old trip closed and
-- a new one opened (or nothing opened, if now a passenger) on the same pass.
-- Both events land in the same HTTP delivery pass and can carry the same
-- second-granularity occurred_at timestamp, so Analytics cannot reliably
-- pair start/end by position or time alone on a rapid switch -- each trip
-- carries its own tripId (a value opaque to the collector, unique per trip
-- on this connection) on both its started and ended events specifically so
-- Analytics can join on that instead. See docs/METRICS_ROADMAP.md
-- "Vehicles" in grdemo-analytics for why this is exact-join, not
-- positional/timestamp pairing, unlike player_jailed/player_released above.
--
-- Unlike observeDeathJailField's first-observation-only-seeds rule, a poll
-- that first observes a player already driving (e.g. right after this
-- resource restarts mid-drive) DOES emit vehicle_trip_started immediately,
-- not just silently seed state. This is a deliberate difference, not an
-- oversight: the death/jail rule exists to avoid *misreporting a false
-- state-change claim* (a jailing declared to have started exactly at
-- reconnect, when it really started earlier). There is no equivalent false
-- claim here -- the trip simply starts measuring from the moment it was
-- first observed, the same honest truncation every other resource-restart
-- mid-session case in this file already accepts (e.g. observeMoneyChanges'
-- first snapshot).

-- Generous headroom over any real in-game ground vehicle's top speed, so a
-- genuine sample is never dropped -- this exists only to stop a
-- teleport/lag-spike-induced GetEntitySpeed misread (or a huge elapsed gap
-- from a resource hitch) from being accumulated as real distance. Rejected
-- samples drop that one sample's distance contribution; they never reset or
-- end the trip, and never overwrite the trip's last known-good speed either
-- (see accumulateTripDistance).
local MAX_PLAUSIBLE_VEHICLE_SPEED_MPS = 150 -- ~540 km/h

-- A misconfigured (e.g. 0 or negative) interval would otherwise turn this
-- poll thread into a tight per-frame loop across every online player's
-- vehicle state -- clamp at the point of use so a bad convar/config value
-- degrades to "check every 5 seconds", never "check every tick".
local function vehicleTrackIntervalSec()
    return math.max(5, tonumber(Config.VehicleTrackIntervalSec) or 20)
end

local function currentDriverVehicle(source)
    local okPed, ped = pcall(GetPlayerPed, source)
    if not okPed or not ped or ped <= 0 then return nil end
    local okVeh, vehicle = pcall(GetVehiclePedIsIn, ped, false)
    if not okVeh or not vehicle or vehicle == 0 then return nil end
    local okSeat, driver = pcall(GetPedInVehicleSeat, vehicle, -1)
    if not okSeat or driver ~= ped then return nil end -- passenger, not driver
    return vehicle
end

-- Accumulates one sample into trip.distanceMeters if, and only if, it passes
-- the same plausibility guard used for both regular polls and the final
-- partial-interval sample in endVehicleTrip -- one gate, two call sites,
-- rather than two independently-maintained copies of the same bounds.
-- Returns true when the sample was accepted (the caller uses this to decide
-- whether to advance trip.lastSpeed -- a rejected sample must not become the
-- new "last known good" extrapolation basis either).
local function accumulateTripDistance(trip, speed, elapsedSec)
    if type(speed) == 'number' and speed >= 0 and speed <= MAX_PLAUSIBLE_VEHICLE_SPEED_MPS
        and elapsedSec > 0 and elapsedSec <= vehicleTrackIntervalSec() * 3 then
        trip.distanceMeters = trip.distanceMeters + speed * elapsedSec
        return true
    end
    return false
end

endVehicleTrip = function(source, session, reason)
    local trip = session.vehicleTrip
    if not trip then return end
    session.vehicleTrip = nil

    -- Final partial-interval sample: the real exit could have happened
    -- anywhere between the last regular poll and this call, so extrapolate
    -- using the last known-good speed reading rather than querying the
    -- vehicle fresh -- by this point the player may already be out of the
    -- seat (or, on disconnect, gone entirely), so a fresh read would no
    -- longer reflect *their* driving. Without this, every trip would lose
    -- this tail entirely and a trip shorter than one poll interval would
    -- always report exactly zero distance (see the file header).
    local nowMs = GetGameTimer()
    local elapsedSec = (nowMs - trip.lastSampledAt) / 1000
    accumulateTripDistance(trip, trip.lastSpeed, elapsedSec)

    emitEvent(source, 'vehicle_trip_ended', {
        tripId = trip.tripId,
        plate = trip.plate,
        modelHash = trip.modelHash,
        vehicleClass = trip.vehicleClass,
        distanceMeters = math.floor(trip.distanceMeters + 0.5),
        endReason = reason,
    })
end

local function startVehicleTrip(source, session, vehicle)
    local okPlate, rawPlate = pcall(GetVehicleNumberPlateText, vehicle)
    local plate = (okPlate and type(rawPlate) == 'string') and rawPlate:gsub('^%s+', ''):gsub('%s+$', '') or nil
    if plate == '' then plate = nil end
    local okModel, modelHash = pcall(GetEntityModel, vehicle)
    local okClass, vehicleClass = pcall(GetVehicleClass, vehicle)
    modelHash = (okModel and type(modelHash) == 'number') and modelHash or nil
    vehicleClass = (okClass and type(vehicleClass) == 'number') and vehicleClass or nil
    -- Sampled once at the moment the trip opens (not left at 0) so a trip
    -- that closes before its first regular poll still has a real starting
    -- speed to extrapolate its (sub-interval) duration from in
    -- endVehicleTrip, instead of unconditionally reporting zero distance.
    local okSpeed0, speed0 = pcall(GetEntitySpeed, vehicle)
    local initialSpeed = (okSpeed0 and type(speed0) == 'number' and speed0 >= 0 and speed0 <= MAX_PLAUSIBLE_VEHICLE_SPEED_MPS)
        and speed0 or 0
    local tripId = eventKey(source)

    session.vehicleTrip = {
        entity = vehicle,
        tripId = tripId,
        plate = plate,
        modelHash = modelHash,
        vehicleClass = vehicleClass,
        distanceMeters = 0,
        lastSampledAt = GetGameTimer(),
        lastSpeed = initialSpeed,
    }
    emitEvent(source, 'vehicle_trip_started', { tripId = tripId, plate = plate, modelHash = modelHash, vehicleClass = vehicleClass })
end

local function observeVehicleTrip(source, session)
    local vehicle = currentDriverVehicle(source)
    local trip = session.vehicleTrip

    if not vehicle then
        if trip then endVehicleTrip(source, session, 'exited') end
        return
    end

    if trip and trip.entity ~= vehicle then
        endVehicleTrip(source, session, 'exited')
        trip = nil
    end

    if not trip then
        startVehicleTrip(source, session, vehicle)
        return
    end

    local nowMs = GetGameTimer()
    local elapsedSec = (nowMs - trip.lastSampledAt) / 1000
    trip.lastSampledAt = nowMs

    local okSpeed, speed = pcall(GetEntitySpeed, vehicle)
    if accumulateTripDistance(trip, okSpeed and speed or nil, elapsedSec) then
        trip.lastSpeed = speed
    end
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
            -- Backstop only: on QBCore/QBox, the dedicated metadata events
            -- (wired in framework.lua) normally catch isdead/injail
            -- transitions immediately. This reconciles anything they missed,
            -- up to one heartbeat interval late. Returns nil for ESX/vanilla
            -- (no adapter-level implementation), so this is a no-op there --
            -- ESX's death-downtime signal is purely event-driven (see
            -- framework.lua's esx:onPlayerSpawn handler).
            local deathJailState = Framework.GetDeathJailState(source)
            if type(deathJailState) == 'table' then
                observeDeathJailField(source, 'isdead', deathJailState.isdead)
                observeDeathJailField(source, 'injail', deathJailState.injail)
            end
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
    Framework.RegisterEvents(emitEvent, observeDeathJailField)

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

-- Separate thread, separate interval from the heartbeat above: distance
-- fidelity benefits from a tighter sampling interval than population/AFK
-- reporting needs (see config.lua). Gated on Config.CollectVehicleTracking
-- itself, not just on the emitEvent allowlist -- so disabling it also stops
-- paying the per-tick native calls, not just their output.
if Config.CollectVehicleTracking then
    CreateThread(function()
        while true do
            Wait(vehicleTrackIntervalSec() * 1000)
            -- Only players with an already-open session are polled; the
            -- heartbeat thread above is what recovers/creates sessions for
            -- newly-seen connections, so there is exactly one place that
            -- happens rather than two racing to do it.
            for _, playerSource in ipairs(GetPlayers()) do
                local source = tonumber(playerSource)
                local session = source and openSessions[source]
                if session then observeVehicleTrip(source, session) end
            end
        end
    end)
end
