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
