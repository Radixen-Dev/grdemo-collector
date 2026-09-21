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
Analytics API requires a player label. Framework snapshots are limited to
job/gang/group, numeric cash/bank/crypto balances, and character identity (see
below); arbitrary framework metadata is excluded. Event payloads use a fixed
allowlist, and failed HTTP requests never print response bodies (which might
contain sensitive server details). Events are attributable only to the acting
player; the collector does not forward other players' identifiers to form
relationship graphs. Disconnect reasons are also kept on the game server.

### Character identity

One FiveM license can play more than one in-game character over time (a
"character slot"), and Analytics needs to tell those characters apart instead
of merging their job, gang, and money history into a single identity. The
collector forwards the minimum needed for that:

- **QBCore / QBox**: `citizenid` (that framework's own stable per-character
  id) and `charinfo.firstname`/`charinfo.lastname`. No other `charinfo` field
  is read or sent.
- **ESX**: base ESX has no native multi-character support, so its login
  `identifier` already is a correct, stable per-character key -- but only on
  builds configured to use the license as that identifier. The collector only
  forwards it when it matches the `license:...` shape; on Steam-primary
  builds `xPlayer.identifier` is a `steam:...` id, which platform-identifier
  policy excludes, so nothing is sent for those and only the FiveM license
  (already sent, see above) identifies the player. A best-effort character
  name is sent only when `xPlayer.getName()` exists on the running build.
- **Vanilla (no framework)**: no character identity is available or sent.

No other character or inventory data is collected.

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
