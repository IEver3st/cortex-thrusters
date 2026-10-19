# Changelog

## 2.0.0 (2026-10-19)

### Changed
- Physics-based thrusters. Every effect is now a force from a nozzle or grip fan at the spot it sits on the car, handed to the game's physics engine. Nothing sets the car's speed, spin or position any more, so collisions, weight and the car's own shape all play their part.
- Real-time RCS: every frame the twelve nozzles are throttled together to give the push and turn that is wanted, within what each nozzle can do. Jets are drawn from the real throttles, and gas follows the thrust actually used (`Config.rcs.gas`).
- Matching nozzles share the load (a hover fires all four lift nozzles evenly), and a jet shows whenever its nozzle really pushes, so the jets stay on through a long hover. The ground cloud now reaches 16 m (`Config.fx.ground.height`), above the hover height.
- Jets no longer fade out during a long hover or boost: a nozzle that keeps firing gets a fresh emitter every 3 seconds (`Config.fx.renew`), because the base-game leak effects run dry on their own.
- In flight the RCS calms a tumble (`Config.rcs.damping`) and yields to GTA's own air control.
- Four-wheel landing assist: close to touchdown it probes the ground under all four tyres, levels the car to that plane so the wheels land together, and brakes the corner sinking fastest.
- Holding lift launches at full thrust (lift nozzles up to six times gravity), climbs at 8 m/s (`Config.lift.climb`) and brakes into a hover 15 m up (`Config.lift.ceiling`, `Config.lift.brake`), instead of a fixed push that kept accelerating. The thrust adapts to what each car really needs (`Config.lift.trim`) and remembers it between presses.
- During a trick the trick owns the nozzles: held lift only holds the height while the lift nozzles face down, a tap of lift doesn't hop, and levelling waits until the turn is done or the car lands, so a hover-flip no longer gets pulled back halfway. A spin's leftover turn is stopped as it levels.
- Flips, rolls and spins count how far the car has really turned and keep turning until the full turn is done (`Config.tricks.overtime` is only a safety limit), braking for what that car showed it can do, so a heavy car no longer stops halfway round.
- Flips and rolls no longer throw the car back into the air as they finish. Braking now allows for the nozzles' reaction time, so the turn no longer overshoots and corrects back. It is also spread over the last half turn, so the lift nozzles that stop the turn mostly push while the car is upside down. A flip takes about 0.25 s longer.
- Cold gas lasts three times as long for the same thrust (`Config.rcs.gas` 0.53). A full tank hovers for about 33 seconds (about 8 before).
- Hops, trick rises and trick turns are nozzle bursts (`Config.rcs.burst`, `Config.lift.hopTime`) instead of set speeds.
- Wall grip fans pull at the four corners; more pull on one side lays the car flat on the surface.

### Added
- Recovery: tap lift on the roof or side and the nozzles right the car (`Config.recovery`, optional automatic start).
- Debug attitude overlay (`Config.debug`, `/thrusters_attitude`): roll and yaw rings drawn around the car, with live readouts.

### Removed
- `Config.lift.maxRise` (replaced by `Config.lift.climb`), `Config.lift.drain`, `Config.boost.drain`, `Config.landing.drain` (replaced by `Config.rcs.gas`) and `Config.angularSpace`.

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
