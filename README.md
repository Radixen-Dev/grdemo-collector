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
of merging their job, gang, and money history into a single identity. Where
the character *slot number* itself is known (e.g. "slot 2 of 5"), the
collector also forwards that small integer so Analytics can distinguish a
handful of concurrently-used slots from many characters accumulated over time
via delete+recreate. The collector forwards the minimum needed for that:

- **QBCore / QBox**: `citizenid` (that framework's own stable per-character
  id) and `charinfo.firstname`/`charinfo.lastname`. No other `charinfo` field
  is read or sent. The character slot number (`PlayerData.cid`, typically
  1-5) is also forwarded.
- **ESX**: base ESX has no native multi-character support, so its login
  `identifier` already is a correct, stable per-character key -- but only on
  builds configured to use the license as that identifier. Some ESX builds
  instead run native multicharacter, where the identifier carries an
  explicit `char<N>:` slot prefix in front of the license (e.g.
  `char2:license:abcd...`); the collector forwards that identifier whole,
  including the prefix, since each `charN:` value is itself a stable,
  distinct per-character key -- stripping the prefix down to the bare
  license would wrongly merge separate characters into one identity. The
  slot number `N` is forwarded separately too, the same as QBCore/QBox's.
  The collector only forwards an identifier when it matches the
  `license:...` shape, with or without a `char<N>:` prefix; on
  Steam-primary builds `xPlayer.identifier` is a `steam:...` id, which
  platform-identifier policy excludes (even when it carries a `char<N>:`
  prefix), so nothing is sent for those and only the FiveM license (already
  sent, see above) identifies the player. A best-effort character name is
  sent only when `xPlayer.getName()` exists on the running build.
- **Vanilla (no framework)**: no character identity is available or sent.

No other character or inventory data is collected.

### Character depth: death downtime and jail time

**QBCore / QBox.** Both frameworks' own core (`qb-core`/`qbx_core`, not any
ambulance or police job resource) define and default two metadata fields:
`metadata.isdead` (boolean) and `metadata.injail` (a number both frameworks'
own source comments label "time in minutes"). Verified directly against
`qbcore-fivem/qb-core` and `Qbox-project/qbx_core`'s current source: core
initializes these fields and provides the only sanctioned way to change them
(`Player.Functions.SetMetaData` / the `SetMetadata` export), but never calls
that setter itself for these two fields -- only whichever ambulance/police
job resource is installed does, if one is installed at all.

The collector hooks that core setter's own change-notification mechanism
(`QBCore:Server:OnPlayerUpdated` / `qbx_core:server:onSetMetaData`), not any
specific job resource's event names. This means it works the same way
regardless of which ambulance/police job resource is installed (or a
community fork of one), as long as that resource uses core's own API to
persist its change -- the only way such a change would sync to the client or
survive a save in the first place. A 60-second heartbeat reconciliation (the
same pattern already used for `money_change`) backstops anything the
event-driven path missed. Two small, non-sensitive events result:

- **`player_respawned`**: `metadata.isdead` transitioning from `true` to
  `false`. No framework distinguishes an EMS revive from bleeding out and
  respawning at a hospital at this signal -- both flip the same field the
  same way -- so Analytics reports this as **death downtime**, not
  "time-to-revive." Empty payload; only the timing (paired against the
  preceding `player_death`) is meaningful.
- **`player_jailed`** / **`player_released`**: `metadata.injail` transitioning
  away from / back to zero. `player_jailed` carries `sentenceMinutes`
  (`injail`'s value at the moment of transition) -- treat this as best-effort,
  not authoritative, since it is read from a fork-dependent field that
  QBCore/QBox's own comments describe as minutes but don't strictly enforce.

Neither is a first-observation event: a player who connects already dead or
already jailed (a resource restart mid-session, for example) does not get a
retroactive `player_respawned`/`player_jailed`/`player_released` for state
that predates this session's first observation -- the same tradeoff already
accepted for `money_change`'s heartbeat reconciliation.

This tracking is per-connection, not per-character: a character switch
(`character_unloaded`/`character_loaded`) mid-session does not reset it. A
death as one character followed by a character switch and a respawn signal
as a *different* character on the same connection is paired together as one
(misleadingly short) downtime sample -- a known limitation, since events
carry no character id to disambiguate against today.

On QBox, the heartbeat backstop reads `PlayerData.metadata` through
`qb-core`'s QB-compatibility bridge (the same object `getPlayerInfo` already
reads job/money/citizenid from). If a given QBox build's bridge ever omits
`metadata`, the heartbeat backstop is a no-op for that field on that build --
the event-driven path (`qbx_core:server:onSetMetaData`) is unaffected either
way, since it reads directly from qbx_core, not through the bridge.

Criminal record accumulation (`metadata.criminalrecord`) is **not**
collected: both frameworks default it to a single `{hasRecord, date}` pair,
not a count, so there is nothing to accumulate from core state alone.

**ESX.** Base ESX has no server-side "dead" or jail state at all (verified
against `esx-framework/esx_core`: no such field exists on the server player
class, and jail is addon territory -- e.g. `esx_advancedjail` -- not core).
`player_respawned` is still built for ESX, from two events that genuinely are
part of `es_extended` core: `esx:onPlayerDeath` (already collected as
`player_death`) and `esx:onPlayerSpawn`/`playerSpawned`. The latter is
ambiguous on its own -- it also fires on a character's very first spawn after
joining -- so the collector only forwards it as `player_respawned` when this
session already has an unmatched `player_death` to pair it with; an ordinary
join-spawn is dropped, silently and expectedly, not logged as an error.
**Jail time is not buildable for ESX** -- there is no core signal to hook.
See "Track API" below for how to report it yourself if your server runs a
jail script.

## Track API

The Track API provides an open integration point for custom events from any FiveM resource outside the curated ESX/QBCore/QBox adapters. Use this for a custom or modified framework, or a non-RP gamemode (racing, deathmatch, minigames) with no framework at all—any resource can report a custom event without requiring a dedicated GuildRate adapter.

Call the export from your resource:

```lua
local ok = exports['guildrate-collector']:TrackEvent(source, 'race_finished', {
    track = 'sandy-shores',
    placement = 1,
    timeMs = 92340,
})
```

`TrackEvent(source, name, payload)` returns `true` if the event is accepted and queued for delivery, or `false` if rejected. It never throws.

Event names are automatically namespaced with `custom.` if not already prefixed (both `custom.race_finished` and `race_finished` produce the same result). After the `custom.` prefix, the name must be 1–80 characters of lowercase letters, digits, and underscores only (no dots, no uppercase, no spaces). Invalid names are rejected with a server-side log indicating the reason; they are never silently dropped.

The payload is a flat JSON object of at most 20 fields. Each field value must be a string (max 200 characters), number, boolean, null, or an array of up to 20 scalar values. Nested objects are rejected. Total encoded payload size is capped at 2000 bytes. This stricter structure reflects that custom events can originate from any third-party script.

No framework `playerInfo` snapshot (job, gang, money) is attached to custom events, and they never create or update a character record—they are pure, minimal event records tied only to the reporting player's session.

Rate limiting is enforced per connected player via `Config.TrackEventMaxPerMinute` (default 30 calls per player per minute). Calls beyond the limit return `false`; a single warning is logged the first time any player hits the limit, not on every rejected call, to avoid log spam. This exists because custom events share the ingest HTTP path with session and heartbeat traffic; an unthrottled custom event source must not starve that load-bearing telemetry.

The Worker independently re-validates this contract server-side; collector-side validation avoids wasted HTTP round trips, not as the sole line of defense. Once released, this contract is stable and versioned.

### Example: reporting jail time on ESX

Base ESX has no core jail state (see "Character depth" above), so
`player_jailed`/`player_released` are QBCore/QBox-only. If your server runs
ESX with a jail script (`esx_advancedjail` or your own), call the Track API
from it directly -- this is the exact scenario the Track API exists for:

```lua
-- In your jail resource, when a player is jailed:
exports['guildrate-collector']:TrackEvent(source, 'player_jailed', {
    sentenceMinutes = sentenceMinutes, -- however your script tracks it
})

-- ...and when they're released (sentence served, bailed out, admin release):
exports['guildrate-collector']:TrackEvent(source, 'player_released', {})
```

These land in Analytics as `custom.player_jailed` / `custom.player_released`
(the Track API's automatic namespacing -- see above), not the same
`player_jailed`/`player_released` type QBCore/QBox's native adapter emits, so
they will not be silently confused with core-sourced data from a different
framework. `sentenceMinutes` is a plain number field here, same as any other
Track API payload value -- no special handling.

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
