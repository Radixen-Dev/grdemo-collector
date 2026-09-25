fx_version 'cerulean'
game 'gta5'

name 'guildrate-collector'
author 'GuildRate'
description 'Drop-in analytics collector: reports sessions, players and framework events to the GuildRate dashboard'
version '0.7.0'

shared_scripts {
    'config.lua'
}

server_scripts {
    'server/framework.lua',
    'server/collector.lua'
}

-- No hard dependency on any framework: framework.lua detects ESX / QBCore /
-- QBox at runtime via GetResourceState and falls back to vanilla natives.
