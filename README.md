# GuildRate collector

FiveM resource that reports player sessions, heartbeats, and framework events
to GuildRate Analytics.

## Install

1. Copy this directory into your FiveM server's `resources/` directory.
2. Add the following to `server.cfg` (the URL may include or omit a trailing
   slash; the collector normalizes it safely):

   ```cfg
   set guildrate_api_url "https://analytics.demo.guildrate.com"
   set guildrate_api_key "grk_live_..."
   ensure guildrate-collector
   ```

3. Restart only this resource after changing either convar:

   ```cfg
   restart guildrate-collector
   ```

The collector detects ESX, QBCore, QBox, or vanilla FiveM automatically.

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
