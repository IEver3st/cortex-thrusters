fx_version 'cerulean'
game 'gta5'
lua54 'yes'
use_experimental_fxv2_oal 'yes'

name 'cortex-thrusters'
author 'GSDMODS/CORTEX'
description 'Cold gas thruster kit for any vehicle: lift, boost, wall grip and tricks'
version '2.0.0'

dependencies { 'cortex-lib', '/onesync' }

shared_scripts { '@cortex-lib/init.lua', 'config.lua', 'shared/locale.lua', 'shared/layout.lua', 'shared/tank.lua', 'shared/tricks.lua' }
client_scripts { '@cortex-lib/presentation-client.lua', 'client/vfx.lua', 'client/remote.lua', 'client/physics.lua', 'client/main.lua', 'client/install.lua', 'client/attitude.lua' }
server_scripts { 'server/bridge.lua', 'server/main.lua' }

ui_page 'web/dist/index.html'
files { 'web/dist/index.html', 'web/dist/assets/*', 'web/dist/barlow-condensed-OFL.txt', 'locales/*.json' }

escrow_ignore { 'config.lua', 'locales/*.json', 'shared/locale.lua' }
