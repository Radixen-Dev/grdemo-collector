# GuildRate collector

FiveM resource that reports minimized player sessions, heartbeats, and selected
framework events to GuildRate Analytics.

Download the latest packaged release: [guildrate-collector.zip](https://github.com/radixen-dev/grdemo-collector/releases/latest/download/guildrate-collector.zip).

## Install

1. Download and unzip the latest release, then copy the extracted
   `guildrate-collector/` directory into your FiveM server's `resources/`
   directory. Building from source follows the same layout.
2. Add the following to `server.cfg` (the URL may include or omit a trailing
   slash; the collector normalizes it safely):

   ```cfg
   set guildrate_api_url "https://analytics.demo.guildrate.com"
   set guildrate_api_key "grk_live_..."
   ensure guildrate-collector
   ```

The API URL must use HTTPS for remote hosts. Plain HTTP is accepted only for
local development (`localhost`, `127.0.0.1`, or `::1`). Keep the API key in
your private `server.cfg`; never commit it to this resource.

3. Restart only this resource after changing either convar:

   ```cfg
   restart guildrate-collector
   ```

The collector detects ESX, QBCore, QBox, or vanilla FiveM automatically.

## Data minimization

Analytics receives only the FiveM `license` identifier needed to associate
records with a player. Other platform identifiers (Discord, Steam, IP, and
similar values) are not sent. The FiveM display name is retained because the
Analytics API requires a player label; framework character IDs and names are
not collected. Framework snapshots are limited to job/gang/group and numeric
cash, bank, and crypto balances; arbitrary framework metadata is excluded.
Event payloads use a fixed allowlist, and failed HTTP requests never print
response bodies (which might contain sensitive server details). Events are
attributable only to the acting player; the collector does not forward other
players' identifiers to form relationship graphs. Disconnect reasons are also
kept on the game server.

## Collection coverage

Each heartbeat reports the collector version, active framework, and only the
capabilities enabled by this server's current configuration. Optional event
sources are reported only when their resource is running. The dashboard uses
this to show which operational signals are covered. This metadata contains no
player data and does not enable automated moderation actions.

The capability manifest is covered by a standalone Lua test. Run it with
`lua test/framework_capabilities.lua` on a machine with Lua 5.4 installed.

## Conduct observations (optional)

Set `Config.CollectConductActions = true` only if a server resource already
makes staff decisions and you want to record those decisions as observations.
That resource may call the server-only API:

```lua
TriggerEvent('guildrate:conductAction', targetSource, 'warn', { reason = '...' })
```

Accepted actions are `warn`, `kick`, and `ban`. The adapter is not networked,
does not accept client calls, and never performs or recommends a player
action. It records the calling resource and the target's existing identifier.
Keep `context` limited to necessary, non-sensitive operational details.

## AFK accounting

During its existing 60-second heartbeat, the collector samples each player's
server-visible position once. It considers a player AFK after they remain
within `Config.AfkMovementTolerance` for `Config.AfkThresholdSec` (defaults:
1.5 metres for five minutes). Only newly accrued AFK seconds and an
idempotency key are sent to Analytics—coordinates, paths, and raw movement
samples are never transmitted or retained.

This is deliberately server-side and O(players) per heartbeat, not a client
script or a per-frame loop. It requires a OneSync-capable server for
server-visible player coordinates; when coordinates are unavailable, the
collector simply does not classify the interval as AFK.
