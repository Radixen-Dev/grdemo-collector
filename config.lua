Config = {}

-- Base URL of the GuildRate API, no trailing slash.
Config.ApiUrl = GetConvar('guildrate_api_url', 'http://localhost:5080')

-- Per-server API key, issued when the server is registered in the dashboard.
-- Set this in server.cfg instead of hardcoding it:
--   set guildrate_api_key "grk_live_xxxxxxxxxxxx"
Config.ApiKey = GetConvar('guildrate_api_key', '')

-- Seconds between heartbeats (keeps servers.last_seen_at fresh and reports
-- current player count even with no join/leave activity).
Config.HeartbeatIntervalSec = 60

-- Which built-in framework events to translate into analytics events.
-- Set to false to only collect join/leave sessions, no framework payloads.
Config.CollectFrameworkEvents = true

-- Explicit event allowlist forwarded from a framework adapter. Keeps payload
-- volume predictable instead of mirroring every framework event verbatim.
-- Remove entries you don't care about, e.g. drop 'money_change' if your
-- server pays out frequently and you don't want an event per paycheck.
--
-- ESX emits:    player_death, job_change, job2_change, money_change, group_change, character_loaded
-- QBCore emits: player_death, job_change, gang_change, money_change, character_loaded, character_unloaded
Config.TrackedEvents = {
    'player_death',
    'job_change',
    'job2_change',
    'gang_change',
    'money_change',
    'group_change',
    'character_loaded',
    'character_unloaded',
}
