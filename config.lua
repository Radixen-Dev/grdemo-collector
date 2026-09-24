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

-- AFK is calculated server-side during the existing heartbeat, so no client
-- script, position history, or per-frame polling is needed. A player becomes
-- AFK after remaining within this radius for AfkThresholdSec.
Config.AfkThresholdSec = 300
Config.AfkMovementTolerance = 1.5
-- Do not classify time after a stalled heartbeat; wait for a fresh sample.
Config.AfkMaxSampleGapSec = 120

-- Which built-in framework events to translate into analytics events.
-- Set to false to only collect join/leave sessions, no framework payloads.
Config.CollectFrameworkEvents = true

-- Explicit event allowlist forwarded from a framework adapter. Keeps payload
-- volume predictable instead of mirroring every framework event verbatim.
-- Remove entries you don't care about, e.g. drop 'money_change' if your
-- server pays out frequently and you don't want an event per paycheck.
--
-- ESX emits:         player_death, player_respawned, job_change, job2_change,
--                    money_change, group_change, character_loaded
-- QBCore/QBox emit:  player_death, player_respawned, player_jailed,
--                    player_released, job_change, gang_change, money_change,
--                    character_loaded, character_unloaded
-- Any framework (or none): vehicle_trip_started, vehicle_trip_ended -- these
--                    are not framework-sourced at all (see
--                    Config.CollectVehicleTracking below); they are gated by
--                    this same allowlist purely for consistency with every
--                    other event type.
--
-- player_respawned is derived, not raw: it only reaches Analytics when it
-- can be paired with a preceding player_death for the same session (an
-- ordinary join/character-select spawn is not a respawn and is dropped
-- before it gets here). player_jailed/player_released are QBCore/QBox only
-- -- built from core's own isdead/injail metadata fields, never from any
-- specific ambulance/police job resource's event names (see
-- server/framework.lua and README.md "Character depth: death downtime and
-- jail time" for exactly why, and why base ESX has no equivalent jail
-- signal at all).
Config.TrackedEvents = {
    'player_death',
    'player_respawned',
    'player_jailed',
    'player_released',
    'job_change',
    'job2_change',
    'gang_change',
    'money_change',
    'group_change',
    'character_loaded',
    'character_unloaded',
    'vehicle_trip_started',
    'vehicle_trip_ended',
}

-- Open Track API: caps how many exports('TrackEvent', ...) calls this
-- resource accepts per player per minute. Custom events share the ingest
-- HTTP path with session/heartbeat traffic, so this keeps a chatty script
-- (e.g. a checkpoint fired every frame) from starving that load-bearing
-- telemetry. See README.md "Track API" for the full contract.
Config.TrackEventMaxPerMinute = 30

-- Vehicle trip tracking: framework-agnostic, built entirely from vanilla
-- FiveM natives (GetVehiclePedIsIn, GetPedInVehicleSeat,
-- GetVehicleNumberPlateText, GetEntityModel, GetVehicleClass, GetEntitySpeed
-- -- all verified server-side-callable against citizenfx/fivem's own
-- native-decls apiset metadata). Works identically on ESX, QBCore, QBox, or
-- no framework at all -- no adapter hook exists or is needed for it. Set to
-- false to disable the poll thread entirely (not just its output).
--
-- Deliberately does NOT collect vehicle ownership, purchase, theft, or
-- impound state: verified against current qb-core, qbx_core, and
-- es_extended source that none of the three frameworks expose a reliable,
-- core-owned signal for that (ownership/garage/shop state lives in addon
-- resources -- qb-garages/qbx_vehicles, qb-vehicleshop/esx_vehicleshop --
-- not in any core itself; even ESX's core vehicle class, the one partial
-- exception, never exposes its own impound flag on the event it fires). See
-- README.md "Vehicle trip tracking" and grdemo-analytics's
-- docs/METRICS_ROADMAP.md "Vehicles" for the full citations.
Config.CollectVehicleTracking = true

-- Seconds between vehicle-occupancy/distance samples. Distance is
-- accumulated as GetEntitySpeed(vehicle) * elapsed per sample (a right
-- Riemann sum), not a position-delta -- so, unlike AFK's tolerance check,
-- this interval does not create a route-shape bias, only ordinary sampling
-- noise (how much a vehicle's speed changes within one interval). A
-- shorter interval reduces that noise at the cost of one extra native call
-- per online player per tick; 20s is a reasonable default for a feature
-- whose headline numbers are trip/distance totals, not real-time telemetry.
Config.VehicleTrackIntervalSec = 20
