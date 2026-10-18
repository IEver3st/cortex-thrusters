# Changelog

## 1.1.0 (2026-10-18)

### Changed
- Removing a kit takes 10 seconds next to a vehicle that is standing still, like fitting (`Config.removeSeconds`). Anyone next to the vehicle can do it with `/thrusters remove`.
- `thrusters_plate` is a restricted command: the server console, or admins allowed to run commands.

### Removed
- `Config.access` and `Config.adminAce`: Thrusters no longer has its own ACE permissions. Use `Config.requireItem` to limit who can fit a kit.

## 1.0.0 (2026-10-17)

### Added
- First release. A cold gas thruster kit for cars, motorbikes and quads: hop and hover, boost, flips, rolls and spins, wall grip, and landing assist, all fed by one tank that refills by itself. Other players see and hear the jets.
- Fit it with `/thrusters`, or with a `thruster_kit` item on Qbox, QBCore or ESX with ox_inventory or the framework's inventory.
- Kits are remembered by plate (`Config.persist`), so a garage vehicle comes back with its kit.
- Player settings under Cortex settings > Thrusters: controls legend, cold gas gauge and landing assist.
