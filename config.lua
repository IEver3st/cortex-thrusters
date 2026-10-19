Config = {}

Config.Locale = 'en' -- locales/<code>.json

-- Installing -----------------------------------------------------------------

-- 'standalone' (default): no framework and no item; anyone fits the kit with
-- `/thrusters`. Nothing to add to your inventory, so the resource starts with `ensure cortex-thrusters`, no server restart.
-- 'auto' detects Qbox, QBCore or ESX; or name one: 'qbx', 'qb', 'esx'.
-- A framework makes the kit item usable (new items need a full server restart).
Config.framework = 'standalone'

-- The kit item for framework mode. Using it near a vehicle (or inside one)
-- fits the kit; with Config.requireItem the item is used up once the kit is on.
Config.item = 'thruster_kit'
-- true: fitting always takes one kit item, through ox_inventory, the
-- framework's inventory or another supported one. Leave false in standalone.
Config.requireItem = false

-- `/thrusters` fits the kit to the vehicle you sit in or stand next to.
-- `/thrusters remove` takes it off again. Set false to disable the command.
Config.command = 'thrusters'

Config.installSeconds = 8
Config.removeSeconds = 10
Config.installAnim = { dict = 'mini@repair', clip = 'fixing_a_ped' }

-- Remember fitted kits by number plate on the server, so a garage vehicle
-- comes back with its kit. false = the kit lasts as long as the vehicle entity.
Config.persist = true

-- Vehicle classes that never take a kit: cycles, boats, helicopters, planes,
-- trains. Server-side the vehicle type decides (see `types`).
Config.blockedClasses = { [13] = true, [14] = true, [15] = true, [16] = true, [21] = true }
Config.types = { automobile = true, bike = true, quadbike = true, amphibious_automobile = true, amphibious_quadbike = true }
-- Spawn names that never take a kit.
Config.blockedModels = {}

-- Nozzles are placed automatically from each model's size, wheels and
-- exhausts. Per-model corrections, keyed by spawn name:
--   adder = { scale = 1.2, positions = { [5] = { x = -0.4, y = -2.2, z = 0.3 } } },
-- Indices: 1-4 lift (FL FR RL RR), 5-8 boost (left to right), 9-12 corner (FL FR RL RR).
-- `/thrusters_debug` (Config.debug) draws every nozzle's index in the world.
Config.layouts = {}

-- Controls ---------------------------------------------------------------------

-- Default keys. Players rebind every one under Settings > Key Bindings > FiveM,
-- so changing a default only affects players who never set their own.
Config.keys = {
    lift = 'X',              -- tap: hop; hold: hover on the four lift nozzles
    boost = 'LSHIFT',        -- hold: rear nozzles push you forward
    trick = 'LCONTROL',      -- hold, then W / S / A / D / SPACE for a trick
    grip = 'G',              -- wall grip on / off
    liftPad = 'LLEFT_INDEX', -- controller D-pad left
    boostPad = 'L3_INDEX',   -- controller left stick click (also the horn)
    trickPad = 'LDOWN_INDEX',-- controller D-pad down, then triggers / stick
    gripPad = 'LUP_INDEX',   -- controller D-pad up
}

-- Controls legend (Cortex Lib, bottom right): 'enter' shows it for `seconds`
-- after taking the driver's seat of a fitted vehicle, 'off' never. Each
-- player can change it under Cortex settings > Thrusters.
Config.legend = { mode = 'enter', seconds = 8 }

-- The cold gas tank ------------------------------------------------------------

-- One charge feeds every nozzle. Running dry vents the system until it has
-- refilled to `lockout` percent. `capacity` is in units of gas; every drain,
-- cost and the recharge rate below are units (per second where it says).
Config.tank = {
    capacity = 200,
    rechargeDelay = 2.5, -- seconds of rest before the compressor starts
    rechargeRate = 9.0,  -- units per second: about 22 s from empty to full
    engineOff = 0.4,     -- recharge speed with the engine off
    lockout = 30,        -- percent of capacity
    low = 25,            -- percent of capacity
}

-- Physics. Every effect is a push from a nozzle (or a grip fan) at the spot
-- it sits on the car, handed to the game's physics engine: nothing sets the
-- car's speed, spin or position. Thrust is in m/s^2 and scales with the
-- vehicle's mass, so every vehicle gets the same push; how it turns comes
-- from its own shape and weight. Speeds are m/s.
--
-- The RCS throttles all twelve nozzles every frame to give the push and turn
-- that is wanted (lift, boost, levelling, tricks, recovery), within what each
-- nozzle can do. Gas follows the thrust actually used.
Config.rcs = {
    -- Strongest push of one nozzle, m/s^2. Four lift nozzles at 15 give 60,
    -- about six times gravity, so any car launches hard.
    thrust = { lift = 15.0, boost = 3.0, corner = 6.0 },
    burst = 2.5,    -- hops, tricks and recovery dump gas: nozzles push this many times harder
    gas = 0.53,     -- cold gas per second for each m/s^2 of thrust (hovering uses about 6 a second)
    response = 8.0, -- how quickly the RCS catches up with a wanted turn rate, per second
    damping = 2.5,  -- in flight, how firmly it calms a tumble (roll and pitch); 0 = off. Yields to air control
}
Config.lift = {
    -- Holding lift gives just enough thrust to carry the car's weight and
    -- climb at `climb`, whatever the vehicle weighs; it never rockets up.
    climb = 8.0,    -- m/s while lift is held; it launches at full thrust until it gets there
    ceiling = 15.0, -- metres above the ground where it stops climbing and hovers; false = no limit
    brake = 6.0,    -- how hard it slows into that hover height, m/s^2
    response = 6.0, -- how firmly it holds that climb rate, per second
    trim = 8.0,     -- how quickly it adds thrust when the car climbs slower than `climb` (kept between presses)
    accel = 60.0,   -- the most the lift nozzles give while held, m/s^2 (gravity is 9.8)
    hop = 5.5,      -- upward speed a tap adds, as a burst on the lift nozzles
    hopTime = 0.25, -- seconds the burst lasts
    hopCost = 10,
    level = 2.5,    -- how firmly the lift nozzles hold the car level while hovering
}
Config.boost = {
    accel = 10.0,
    maxSpeed = 70.0, -- no boost past this forward speed (about 250 km/h)
}
-- Recovery: tap lift while the car lies on its roof or side and the nozzles
-- right it. On its side, the nozzles facing the ground push it up while the
-- lift nozzles roll it upright. On the roof nothing faces the ground, so the
-- lift nozzles rock it in time with its own sway until it tips onto a side.
Config.recovery = {
    enabled = true,
    auto = false,     -- or seconds stuck before it starts without a key press
    tilt = 60,        -- degrees from upright that count as stuck
    maxSpeed = 3.0,   -- m/s; only when nearly stopped
    seconds = 6.0,    -- gives up after this
    lift = 1.15,      -- push away from the ground, times the car's weight
    align = 3.0,      -- how firmly it turns upright
    turnRate = 160,   -- fastest it turns upright, degrees per second
    turnAccel = 500,  -- how quickly it reaches that rate, degrees per second^2
    rock = 14.0,      -- on the roof: how hard it rocks, rad/s^2
}
-- From the ground a trick first lifts the car on all four lift nozzles,
-- then turns it once while it is still climbing, high enough to clear the
-- ground and to level out before it lands. About 5 m up for a roll on a
-- normal car; bigger vehicles go higher.
Config.tricks = {
    cost = 20,
    cooldown = 0.4,
    rise = 0.35,      -- seconds the lift nozzles burst before the car starts to turn
    -- Seconds for one full turn, per axis: x flips, y rolls, z spins.
    duration = { x = 1.6, y = 1.5, z = 1.3 },
    finish = 0.25,    -- seconds of airtime left after the turn
    margin = 0.35,    -- metres the body keeps clear of the ground while turning
    maxHop = 14.0,    -- m/s; caps how high very large vehicles are thrown
    maxDuration = 2.4,
    settle = 0.6,     -- seconds of levelling after a trick
    hold = 30.0,      -- how firmly a trick keeps turning about its own axis (no sideways twist)
    overtime = 3.0,   -- safety limit: seconds a slow car may keep turning past `duration` to finish the turn
}
-- Wall grip runs on underbody fans, not cold gas: it never uses the tank.
-- Four fans under the corners pull the car onto the surface under the tyres;
-- pulling harder on one side lays it flat on that surface. Its weight is
-- carried, it doesn't bounce off, and parked (no throttle, nearly stopped)
-- it holds still. Driving into a steeper
-- surface the nose touches (a gutter ramp, the foot of a wall) carries the
-- car onto it; the speed heading into it is turned up it, never added to.
-- With Config.debug the probes are drawn: green under the axles, blue ahead.
Config.grip = {
    press = 13.0,       -- fan pull into the surface, m/s^2 (all four together)
    hold = 8.0,         -- how hard it holds a parked car still, m/s^2
    reach = 1.6,        -- metres below the tyres a surface is still held
    align = 5.0,        -- how firmly the car follows the surface
    turnRate = 150,     -- fastest it turns to follow the surface, degrees per second
    turnAccel = 600,    -- how quickly it reaches that rate, degrees per second^2
    climb = true,       -- false: never drives onto a steeper surface
    climbReach = 0.6,   -- metres ahead of the bumper (plus a little per m/s) that counts as touching
    climbAngle = 25,    -- degrees steeper than the current surface before it climbs
    cooldown = 4.0,     -- seconds the fans rest after grip is switched off; 0 = no cooldown
    release = 0.6,      -- seconds grip lets go after a hop
}

-- Landing assist: in flight the RCS calms a tumble (Config.rcs.damping). Close
-- to touchdown it probes the ground under all four tyres, levels the car to
-- that plane so the wheels land together, and the lift nozzles brake the
-- corner sinking fastest to a gentle sink rate. Players can turn it off
-- under Cortex settings > Thrusters.
Config.landing = {
    enabled = true,
    minAir = 0.35,    -- seconds in the air before it helps (ignores bumps)
    lookahead = 1.3,  -- starts this many seconds before touchdown
    safeSpeed = 3.5,  -- m/s sink rate it aims to land at
    maxAccel = 24.0,  -- strongest lift thrust while braking, m/s^2 (gravity takes 9.8 of it)
    align = 2.0,      -- how firmly it levels the car
    turnRate = 80,    -- fastest it turns the car while levelling, degrees per second
    turnAccel = 220,  -- how quickly it reaches that rate, degrees per second^2
    probe = 40.0,     -- metres it looks down for the ground
}

-- Effects ----------------------------------------------------------------------

-- Base-game particles, layered on the nozzles of a group. `rot` (degrees,
-- vehicle-relative) turns the effect so it fires along the nozzle: lift
-- straight down, boost straight back, corner out to the left (right-hand
-- corners are mirrored). `slots` limits a layer to some nozzles of its group
-- (1-4, left to right / FL FR RL RR), `color` tints it (0-1 per channel).
-- Tune live with Config.debug on:
--   /thrusters_fx lift|boost|corner      fire a group for 4 s
--   /thrusters_rot boost 1 90 0 0        set layer 1's rotation, refire, print the config line
--   /thrusters_layer lift 1 core ent_sht_steam 1.2   swap a layer's effect live (groups lift|boost|corner|ground)
Config.fx = {
    range = 150.0, -- metres; other players' jets beyond this are not drawn
    -- Seconds before a jet that keeps firing gets a fresh emitter. The
    -- base-game leak effects below run dry after several seconds on their
    -- own; false = never renew.
    renew = 3.0,
    -- Lift: straight-down jets only. Rising smoke (the boost's cloud) would
    -- billow up over the car; the jets carry the gas down and away.
    lift = {
        { asset = 'core', name = 'ent_sht_steam', scale = 1.2, rot = { x = 180.0, y = 0.0, z = 0.0 } },                   -- dense white column
        { asset = 'core', name = 'ent_sht_extinguisher', scale = 1.1, rot = { x = 180.0, y = 0.0, z = 0.0 } },            -- high-pressure spray
    },
    boost = {
        { asset = 'core', name = 'ent_sht_extinguisher', scale = 1.1, rot = { x = 90.0, y = 0.0, z = 0.0 } },             -- high-pressure jet
        { asset = 'scr_recartheft', name = 'scr_wheel_burnout', scale = 1.6, slots = { 2, 3 } },                         -- billowing cloud
        { asset = 'scr_ar_planes', name = 'scr_ar_trail_smoke', scale = 0.8, slots = { 1, 4 }, color = { 1.0, 1.0, 1.0 } }, -- long vapour trail
    },
    corner = {
        { asset = 'core', name = 'ent_sht_extinguisher', scale = 0.5, rot = { x = 0.0, y = -90.0, z = 0.0 } },
    },
    -- Smoke left on the ground where the lift jets hit it, only while the
    -- nozzles are within `height` metres of it: thicker the closer they are,
    -- and left behind as the car moves. The same billowing cloud and vapour
    -- trail as the boost. `each` = one source under each lift nozzle (`slots`
    -- pick which layer goes where), false = one under the car; false = off.
    ground = {
        height = 16.0, -- above Config.lift.ceiling, so a hover keeps its cloud
        each = true,
        layers = {
            { asset = 'scr_recartheft', name = 'scr_wheel_burnout', scale = 1.4, slots = { 2, 3 } },
            { asset = 'scr_ar_planes', name = 'scr_ar_trail_smoke', scale = 0.8, slots = { 1, 4 }, color = { 1.0, 1.0, 1.0 } },
        },
    },
    -- Warm glow inside the gas, under the car while lifting and behind it
    -- while boosting; false = off.
    light = { r = 255, g = 196, b = 150, range = 7.0, intensity = 6.0, distance = 80.0 },
}

-- Base-game sounds { name, soundset }; false turns one off.
Config.sounds = {
    fitted = { 'Hover_Unlock', 'DLC_XM17_IAA_Deluxos_Sounds' },
    gripOn = { 'Hydraulics_Down', 'Lowrider_Super_Mod_Garage_Sounds' },
    gripOff = { 'Hydraulics_Up', 'Lowrider_Super_Mod_Garage_Sounds' },
    boost = { 'Use_Boost', 'DLC_Biker_DL_Sounds' },
    burst = { 'Hydraulics_Down', 'Lowrider_Super_Mod_Garage_Sounds' },
    full = { 'Charge_Full', 'DLC_Exec_Jammer_Sounds' },
    empty = { 'Beep_Red', 'DLC_HEIST_HACKING_SNAKE_SOUNDS' },
    range = 60.0, -- other players' thruster sounds carry this far
}

-- Cold gas gauge, on screen the whole time you drive a fitted vehicle. It
-- sits above the speedometer: bottom-right, in 1080p units that scale with
-- screen height. The defaults match the Cortex HUD speedometer (176 wide,
-- 40 from the right, cruise slip room above it). Players who moved their
-- speedometer use `/thrusters hud <right> <bottom>` (`/thrusters hud reset`).
Config.hud = {
    enabled = true,
    right = 40,
    bottom = 200,
    width = 176,
}

Config.debug = false -- true: /thrusters_debug, /thrusters_attitude, /thrusters_fx, /thrusters_rot, /thrusters_layer and F8 traces.
