# Cortex Thrusters 1.0.0

A cold gas thruster kit for cars, motorbikes and quads. Once a vehicle has the kit, its driver can hop and hover on four lift nozzles, boost forward on the rear ones, flip, roll and spin in the air, and switch on wall grip to drive up ramps and walls. One tank feeds every nozzle and refills by itself. Landing assist levels the car after a jump and softens the touchdown. Other players see and hear the jets.

## Requirements

- [Cortex Lib](https://gsd-modifications.tebex.io/package/7696933) 3.3.1 or newer
- OneSync
- Optional, for a kit item: Qbox, QBCore or ESX, with ox_inventory or the framework's own inventory

## Install

1. Put `cortex-thrusters` in your resources and start it after Cortex Lib. Keep the folder name: other resources and the ox_inventory item export call it by name.

   ```cfg
   ensure cortex-lib
   ensure cortex-thrusters
   ```

2. That is all for standalone mode, the default. `/thrusters` fits a kit to the vehicle you sit in or stand next to, and anyone can use it. See [Access](#access) to limit who can.

### With a kit item

1. Add a `thruster_kit` item to your inventory (examples below).
2. In `config.lua`:

   ```lua
   Config.framework = 'auto'  -- or 'qbx', 'qb', 'esx'
   Config.requireItem = true
   ```

3. Restart the whole server. New items are not picked up by a resource restart.

Using the item next to a vehicle, or inside one, fits the kit and takes one item. With `Config.requireItem = true`, `/thrusters` needs the item too. With `requireItem = false` the item still fits a kit but is never taken.

ox_inventory (`data/items.lua`):

```lua
['thruster_kit'] = { label = 'Thruster Kit', weight = 5000, stack = true, close = true, consume = 0 },
```

Keep `consume = 0`: the resource takes the item itself, and only once the kit is on. On Qbox the item becomes usable automatically. With ox_inventory and no framework, leave `Config.framework = 'standalone'`, set `Config.requireItem = true` and add `server = { export = 'cortex-thrusters.useKit' }` to the item.

QBCore (`qb-core/shared/items.lua`):

```lua
thruster_kit = { name = 'thruster_kit', label = 'Thruster Kit', weight = 5000, type = 'item', image = 'thruster_kit.png', unique = false, useable = true, shouldClose = true, description = 'Fits a cold gas thruster kit to a vehicle.' },
```

ESX (database):

```sql
INSERT INTO items (name, label, weight) VALUES ('thruster_kit', 'Thruster Kit', 5);
```

No item icon ships with the resource. Add your own `thruster_kit.png` to your inventory's image folder.

## Use

Fitting takes 8 seconds and removing a kit takes 10, next to a vehicle that is standing still. Moving the vehicle or walking away cancels either one.

Take the driver's seat of a vehicle with a kit. A controls hint (Cortex Lib, bottom right) shows your own keys for 8 seconds, and a cold gas gauge sits at the bottom right, above where the Cortex HUD speedometer goes.

| Action | Keyboard | Controller |
| --- | --- | --- |
| Hop / hover | Tap / hold X | D-pad left |
| Boost | Hold Left Shift | Left stick click |
| Wall grip on / off | G | D-pad up |
| Front / back flip | Hold Left Ctrl, then W / S | Hold D-pad down, then RT / LT |
| Roll left / right | Hold Left Ctrl, then A / D | Hold D-pad down, then left stick left / right |
| Spin | Hold Left Ctrl, then Space | Hold D-pad down, then RB |

A spin turns right; steer left as you press it to spin left. Players rebind every key under Settings > Key Bindings > FiveM. `Config.keys` sets the defaults for players who never set their own.

Lift, boost, tricks and landing assist all run on cold gas. The tank starts refilling after 2.5 seconds of rest and goes from empty to full in about 22 seconds, slower with the engine off. Running it dry shuts the thrusters off until it is back to 30 percent. Wall grip runs on underbody fans, so it never uses gas; after you switch it off it needs 4 seconds before it can go on again. Hop off a wall before a trick.

The thrusters stop working when the vehicle is wrecked or mostly under water.

| Command | What it does |
| --- | --- |
| `/thrusters` | Fit a kit to the vehicle you sit in or stand next to |
| `/thrusters help` | Show the controls hint |
| `/thrusters hud <right> <bottom>` | Move the gauge, in 1080p units (default `40 200`); `/thrusters hud reset` puts it back |
| `/thrusters remove` | Take the kit off the vehicle you sit in or stand next to |
| `thrusters_plate add\|remove <PLATE>` | Remember or forget a kit by plate (server console, or admins allowed to run commands) |

### Player settings

Under Cortex settings > Thrusters, each player chooses:

- **Controls legend**: show it on taking the driver's seat, or never.
- **Cold gas gauge**: on or off.
- **Landing assist**: on or off.

## Configuration

Everything is in `config.lua`, with a comment on every value:

- `Config.framework`, `Config.item`, `Config.requireItem`, `Config.command`, `Config.installSeconds`, `Config.removeSeconds`: fitting, removing and the command.
- `Config.persist`: remember fitted kits by plate on the server, so a garage vehicle comes back with its kit. `false` keeps a kit only as long as the vehicle exists.
- `Config.blockedClasses`, `Config.types`, `Config.blockedModels`: which vehicles take a kit. By default cars, motorbikes, quads and amphibious cars do; bicycles, boats, helicopters, planes and trains never do.
- `Config.layouts`: nozzles are placed automatically from each model's size, wheels and exhausts. Correct them per model here.
- `Config.keys`, `Config.legend`: default keys and the controls hint.
- `Config.tank`, `Config.lift`, `Config.boost`, `Config.tricks`, `Config.grip`, `Config.landing`: the physics. Accelerations are in m/s² and do not depend on mass, so every vehicle feels the same.
- `Config.fx`, `Config.sounds`: base-game particles, the jet glow and sounds, and how far other players' jets are drawn and heard.
- `Config.hud`: the gauge's default position and width.

### Language

Set `Config.Locale`, or switch without editing files with `setr cortex_thrusters_locale <code>` in `server.cfg`. English ships in `locales/en.json`. To add a language, copy it to `locales/<code>.json` and translate the values; missing keys fall back to English.

## For developers

Client:

```lua
exports['cortex-thrusters']:isActive()   -- true while you drive a vehicle with a working kit
exports['cortex-thrusters']:getCharge()  -- current cold gas, tank capacity
```

Server:

```lua
exports['cortex-thrusters']:setFitted(vehicle, true)  -- fit (true) or remove (false) a kit; returns true on success
exports['cortex-thrusters']:isFitted(vehicle)         -- true when the vehicle has a kit
```

`setFitted` also updates the remembered plate when `Config.persist` is on. Fitted vehicles carry `Entity(vehicle).state.cxThrusters == true`.

## Updating

Replace the folder, then copy back your `config.lua` and any files you changed in `locales/`.

## Troubleshooting

- **The keys do nothing**: the thrusters work from the driver's seat of a vehicle with a kit. `/thrusters` fits one.
- **"This vehicle can't take a thruster kit"**: its class, type or model is blocked; see `Config.blockedClasses`, `Config.types` and `Config.blockedModels`.
- **"Your inventory didn't answer"**: `Config.requireItem = true`, but no supported inventory is running or it did not respond. Nothing was fitted and no item was taken.
- **Console: "could not make thruster_kit usable"**: the framework is not running, or another resource already registered the item.
- **The kit is gone after a restart**: with `Config.persist = true` kits are remembered by plate and come back when someone takes the driver's seat. A vehicle with no plate, or a new plate, comes back without it.
- **Nozzles sit in the wrong place on an add-on vehicle**: correct them in `Config.layouts`. Set `Config.debug = true` and use `/thrusters_debug` to see each nozzle's number.
- **The UI does not appear**: make sure the folder contains `web/dist/index.html`.

## Support

Ask in the [GSD Modifications Discord](https://discord.com/invite/gsdmods). Include your server artifact version, framework and the console or F8 error.

License: free to use and modify on servers you own or run, including commercial ones. Do not sell, resell or redistribute it; share the Tebex link instead.
