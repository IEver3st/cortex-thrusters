-- The driver's side: controls, the tank, and the per-frame thrust while
-- anything is firing. Idle costs nothing per frame: a 250 ms watcher decides
-- whether you sit in a fitted driver's seat, and the frame loop only runs
-- while a key is held, a trick is turning or grip is on.
local C, LY, T, K, P, F = Config, ThrusterLayout, ThrusterTank, ThrusterTricks, ThrusterPhysics, ThrusterFx
local RESOURCE = GetCurrentResourceName()
local UP, ZERO, GRAVITY = P.UP, P.ZERO, P.GRAVITY
local dot, unit, length = P.dot, P.unit, P.length

ThrusterClient = { vehicle = nil }
local S = ThrusterClient

local ctx = { active = false, vehicle = 0, layout = nil, model = nil, enteredAt = 0, netId = 0 }
local held = { lift = false, liftPad = false, boost = false, boostPad = false, trick = false, trickPad = false }
local grip = { on = false, contact = false, climbing = false, n = UP, lastContact = 0, releaseUntil = 0, coolUntil = 0 }
-- Landing assist: armed by the watcher when the car leaves the ground.
local air = { armed = false, since = 0, lastAir = 0, settleUntil = 0, normal = UP }
-- Recovery: righting a car stuck on its roof or side.
local recover = { active = false, at = 0, pump = 1, pumpAt = 0, stuckSince = nil }
local trick, pendingHop, hopUntil, lastTrickEnd = nil, false, 0, 0
local mask, sent, sentAt, drainRate = 0, 0, 0, 0
-- Per-nozzle throttle in m/s^2 (warm start for the allocator) and the
-- scratch tables it works in, reused every frame.
local throttle, limit, want, weight, fanOut, wheels = {}, {}, { 0, 0, 0, 0, 0, 0 }, { 0, 0, 0, 0, 0, 0 }, { 0, 0, 0, 0 }, {}
for i = 1, LY.COUNT do throttle[i], limit[i] = 0.0, 0.0 end
local lit = 0 -- nozzles drawn as firing
local prevFrame, spin = nil, ZERO
local running, stopped = false, false
local tanks = {}  -- [vehicle] = tank; the gas lives in the car
local tank = T.new(C.tank)
local asked = {}  -- [vehicle] = time the server was last asked about a remembered kit
local hudRev = 0

local function debug(...) if C.debug then print('[cortex-thrusters]', ...) end end

local function notify(key, kind, vars)
    if lib and lib.notify then lib.notify({ description = L(key, vars), type = kind or 'error' }) end
end

local function lifting() return held.lift or held.liftPad end
local function boosting() return held.boost or held.boostPad end
local function tricking() return held.trick or held.trickPad end

local function fitted(vehicle) return vehicle ~= 0 and Entity(vehicle).state.cxThrusters == true end
S.fitted = fitted

function S.allowedVehicle(vehicle)
    if C.blockedClasses[GetVehicleClass(vehicle)] then return false end
    local model = GetEntityModel(vehicle)
    for _, name in ipairs(C.blockedModels) do
        if GetHashKey(name) == model then return false end
    end
    return true
end

-- HUD -----------------------------------------------------------------------

local TAB = 'cortex-thrusters'
local prefs = { legend = C.legend.mode or 'enter', hud = true, landing = true }
local view = {}

-- Above the speedometer, in 1080p units from the bottom-right corner. A
-- player's own placement (`/thrusters hud`) wins over the config default.
local place = { right = C.hud.right, bottom = C.hud.bottom }
do
    local saved = GetResourceKvpString('hud')
    local right, bottom = saved and saved:match('^(%-?[%d.]+),(%-?[%d.]+)$')
    if right then place.right, place.bottom = tonumber(right), tonumber(bottom) end
end

local function anchor()
    return { right = place.right, bottom = place.bottom, width = C.hud.width }
end

local function hud(now)
    local level, rate, wait = T.snapshot(tank, now)
    local state = T.state(tank, now)
    local live = mask & ~LY.GRIP ~= 0
    local gripState = grip.on and (grip.contact and 'hold' or 'search') or (now < grip.coolUntil and 'cool' or 'off')
    -- Shown for as long as you drive a fitted vehicle.
    local visible = ctx.active and C.hud.enabled and prefs.hud and not IsPauseMenuActive()
    if visible == view.visible and state == view.state and rate == view.rate and live == view.live
        and gripState == view.grip and hudRev == view.rev then return end
    view.visible, view.state, view.rate, view.live, view.grip, view.rev = visible, state, rate, live, gripState, hudRev
    SendNUIMessage({ action = 'thrusters:state', data = {
        visible = visible == true, state = state, live = live, grip = gripState,
        level = level, capacity = tank.capacity, rate = rate, wait = wait,
        lockout = tank.lockout, low = tank.low, anchor = visible and anchor() or nil,
    } })
end

-- nil, nil resets to the config default. Values are clamped to the screen.
function S.placeHud(right, bottom)
    if right == nil then
        place.right, place.bottom = C.hud.right, C.hud.bottom
        DeleteResourceKvp('hud')
    else
        place.right = math.max(0, math.min(1800, right))
        place.bottom = math.max(0, math.min(1000, bottom))
        SetResourceKvp('hud', ('%s,%s'):format(place.right, place.bottom))
    end
    view.visible = nil
    hud(GetGameTimer())
end

-- Controls legend ---------------------------------------------------------------

local legendShown, legendUntil = false, 0
local PAD_NAMES = { LRIGHT_INDEX = 'RIGHT', LUP_INDEX = 'UP', LLEFT_INDEX = 'LEFT', LDOWN_INDEX = 'DOWN', L3_INDEX = 'L3', R3_INDEX = 'R3' }

-- The player's own binding for a key mapping, as keycap text.
local function mapped(command, fallback)
    local label = GetControlInstructionalButton(0, GetHashKey(command) | 0x80000000, true)
    local key = type(label) == 'string' and label:sub(1, 2) == 't_' and #label > 2 and label:sub(3) or fallback
    return ({ LSHIFT = 'SHIFT', LCONTROL = 'CTRL', LMENU = 'ALT', CAPITAL = 'CAPS' })[key] or key
end

local function legendRows()
    local pad = not IsUsingKeyboard(0)
    local function key(name)
        if pad then return mapped('+cortexthrusters_' .. name .. 'pad', PAD_NAMES[C.keys[name .. 'Pad']] or C.keys[name .. 'Pad']) end
        return mapped((name == 'grip' and 'cortexthrusters_grip' or '+cortexthrusters_' .. name), C.keys[name])
    end
    if pad then
        return {
            { label = L('legend.lift'), value = key('lift') },
            { label = L('legend.boost'), value = key('boost') },
            { label = L('legend.grip'), value = key('grip') },
            { label = L('legend.tricks'), value = key('trick') .. '+' .. L('legend.padTricks') },
        }
    end
    return {
        { label = L('legend.lift'), value = key('lift') },
        { label = L('legend.boost'), value = key('boost') },
        { label = L('legend.grip'), value = key('grip') },
        { label = L('legend.tricks'), value = key('trick') .. '+W S A D' },
        { label = L('legend.spin'), value = key('trick') .. '+SPACE' },
    }
end

local function hideLegend()
    if legendShown and lib and lib.hideHelp then pcall(lib.hideHelp) end
    legendShown = false
end

local function showLegend(seconds)
    if not (lib and lib.showHelp) then return end
    local called, accepted = pcall(lib.showHelp, legendRows(), { compact = false })
    if called and accepted ~= false then
        legendShown, legendUntil = true, GetGameTimer() + seconds * 1000
    end
end
S.showLegend = showLegend

-- Network -----------------------------------------------------------------------

local function send(now, force)
    if sent == mask and not force then return end
    if not force and now - sentAt < 100 then return end
    sent, sentAt = mask, now
    if ctx.netId ~= 0 then TriggerServerEvent(RESOURCE .. ':server:thrust', ctx.netId, mask) end
end

local function output(m, now)
    if m ~= mask then
        if C.debug and (m ~ mask) & LY.MAX ~= LY.GRIP then debug(('jets 0x%03x -> 0x%03x at %.1fs'):format(mask & 0xFFF, m & 0xFFF, now / 1000)) end
        mask = m
        if ctx.vehicle ~= 0 then F.set(ctx.vehicle, m, true) end
    end
    send(now, false)
end

-- Tank --------------------------------------------------------------------------

local function emptied(now)
    drainRate = 0
    F.play(ctx.vehicle, 'empty')
    notify('notify.empty', 'warning')
    hudRev = hudRev + 1
    debug('tank empty at', now)
end

local function setDrain(rate, now)
    if rate == drainRate then
        if rate > 0 then
            T.advance(tank, now)
            if tank.locked then emptied(now) end
        end
        return
    end
    if not T.setDrain(tank, now, rate) then rate = 0 end
    if rate ~= drainRate then
        drainRate = rate
        hudRev = hudRev + 1
    end
end

local function spend(amount, now)
    if not T.spend(tank, now, amount) then return false end
    hudRev = hudRev + 1
    if tank.locked then emptied(now) end
    return true
end

local function refused(now)
    if tank.locked then notify('notify.locked', 'warning') else notify('notify.low', 'warning') end
    F.play(ctx.vehicle, 'empty')
end

-- Frame -------------------------------------------------------------------------

local TRICK_CONTROLS = { 59, 60, 61, 62, 63, 64, 71, 72, 76 }

local function tryTrick(kind, now)
    if trick or recover.active or now - lastTrickEnd < C.tricks.cooldown * 1000 then return end
    if grip.contact and grip.n.z < 0.8 then notify('notify.trickWall', 'warning'); return end
    if tank.locked or not T.can(tank, now, C.tricks.cost) then refused(now); return end
    local vehicle, layout = ctx.vehicle, ctx.layout
    local airborne = not IsVehicleOnAllWheels(vehicle) and GetEntityHeightAboveGround(vehicle) > layout.ground + 0.8
    local plan = K.plan(kind, layout, airborne, C.tricks)
    if not plan or not spend(plan.cost, now) then return end
    -- The turn axis is taken when the rise ends, from the car as it is then.
    trick = { plan = plan, at = now, hop = plan.hop }
    S.trickAt = now -- the debug attitude overlay measures yaw from here
    if grip.on then grip.releaseUntil = now + (plan.rise + plan.duration + (C.tricks.overtime or 1.0) + C.tricks.settle) * 1000 end
    debug(('trick %s rise %.2fs turn %.2fs hop %.1f m/s airborne %s'):format(kind, plan.rise, plan.duration, plan.hop, tostring(airborne)))
end

local function readTricks(now)
    for _, control in ipairs(TRICK_CONTROLS) do DisableControlAction(0, control, true) end
    if IsDisabledControlJustPressed(0, 71) then tryTrick('flip_front', now)
    elseif IsDisabledControlJustPressed(0, 72) then tryTrick('flip_back', now)
    elseif IsDisabledControlJustPressed(0, 63) then tryTrick('roll_left', now)
    elseif IsDisabledControlJustPressed(0, 64) then tryTrick('roll_right', now)
    elseif IsDisabledControlJustPressed(0, 76) then
        tryTrick(GetVehicleSteeringAngle(ctx.vehicle) > 5.0 and 'spin_left' or 'spin_right', now)
    end
end

-- How the RCS steers. Every turn is a wanted turn rate that the nozzles chase
-- at `response` per second; LEVEL eases landing and trick levelling in and
-- out, FOLLOW tracks a ramp under grip, RECOVER rights a stuck car.
local RCS = C.rcs
local NOZZLE = { lift = RCS.thrust.lift, boost = RCS.thrust.boost, corner = RCS.thrust.corner }
local RESPONSE = RCS.response or 8.0
local LEVEL = { rate = math.rad(C.landing.turnRate or 80), accel = math.rad(C.landing.turnAccel or 220), response = RESPONSE }
local FOLLOW = { rate = math.rad(C.grip.turnRate or 150), accel = math.rad(C.grip.turnAccel or 600), response = RESPONSE }
local RISE = { rate = 3.0, accel = 40.0, response = RESPONSE }
local BRAKE_ARC = math.pi -- radians a trick takes to slow from its peak rate to a stop
local RECOVER = { rate = math.rad(C.recovery.turnRate or 160), accel = math.rad(C.recovery.turnAccel or 500), response = RESPONSE }
-- Allocation weights: a commanded push matters most, then the turn, and
-- unasked-for push the least.
local FORCE_W, TURN_W, IDLE_W = 10.0, 4.0, 1.0
-- Thrust (m/s^2) at which a nozzle's jet is drawn, and stops being drawn.
-- Fixed, not a share of the nozzle's maximum: a gentle hover still shows.
local ON, OFF = 0.3, 0.1
local DRAIN_STEP = 2 -- gas per second; the gauge only hears about real changes
local DOWN = vector3(0.0, 0.0, -1.0)
local GAP = 250 -- ms a missed grip probe still counts as contact (seams, kerbs)
local PARKED = 4.0 -- m/s; below this with no throttle the fans hold the car still
local STUCK = math.cos(math.rad(C.recovery.tilt or 60))

local function assist() return C.landing.enabled and prefs.landing end

local function driving()
    return GetControlNormal(0, 71) > 0.05 or GetControlNormal(0, 72) > 0.05
end

-- The driver steering the car in the air (GTA's own air control).
local function airControl()
    return math.abs(GetControlNormal(0, 59)) > 0.25 or math.abs(GetControlNormal(0, 60)) > 0.25
end

-- On its roof or side, nearly stopped and resting on something.
local function flipped(vehicle)
    if not C.recovery.enabled or IsEntityInAir(vehicle) then return false end
    return GetEntityUprightValue(vehicle) < STUCK and length(GetEntityVelocity(vehicle)) < (C.recovery.maxSpeed or 3.0)
end

local function startRecovery(now)
    if recover.active or trick then return end
    if tank.locked or not T.can(tank, now, C.lift.hopCost) then refused(now); return end
    recover.active, recover.at, recover.pump, recover.pumpAt = true, now, 1, now
    debug('recovery start, upright', GetEntityUprightValue(ctx.vehicle))
end

local function line(from, to, hit, r, g, b)
    if not C.debug then return end
    if hit then DrawLine(from.x, from.y, from.z, to.x, to.y, to.z, r, g, b, 255)
    else DrawLine(from.x, from.y, from.z, to.x, to.y, to.z, 255, 60, 60, 255) end
end

-- Probe straight down (along the car's down) under one axle.
local function axle(frame, y, depth, vehicle)
    local from = frame.pos + frame.f * y + frame.u * 0.3
    local to = from - frame.u * depth
    local hit, _, normal = P.probe(from, to, vehicle)
    line(from, to, hit, 60, 255, 60)
    return hit, normal
end

-- Grip: underbody fans, not cold gas, so it costs no charge. The fans sit
-- under the four corners and pull the car onto the surface under its tyres;
-- pulling harder on one side lays it flat on that surface. Its weight is
-- carried and outward bounce is pulled back, so it sticks to walls; parked,
-- it holds still. Driving into a steeper surface the nose touches (a gutter
-- ramp, the foot of a wall) pulls the front onto it the way climbing front
-- wheels would: the speed heading into it is turned up it, never added to.
-- Off an edge, gravity is back at once. Applies its own forces; returns the
-- surface normal it holds, or nil.
local function gripFrame(now, dt, frame, velocity)
    if now < grip.releaseUntil or trick or recover.active or lifting() then
        grip.contact, grip.climbing = false, false
        return nil
    end
    local vehicle, layout, cfg = ctx.vehicle, ctx.layout, C.grip
    local depth = layout.ground + 0.3 + cfg.reach
    -- Front and rear axle: across a kerb or a ramp the car follows the
    -- average of both, as its wheels would, instead of flipping between them.
    local frontHit, frontN = axle(frame, layout.thrusters[1].pos.y, depth, vehicle)
    local rearHit, rearN = axle(frame, layout.thrusters[3].pos.y, depth, vehicle)
    if not (frontHit or rearHit) then
        if now - grip.lastContact > GAP then grip.contact, grip.climbing = false, false end
        return nil
    end
    local raw = frontHit and rearHit and unit(frontN + rearN, frontN) or frontHit and frontN or rearN
    grip.contact, grip.lastContact = true, now
    grip.n = unit(grip.n + (raw - grip.n) * math.min(1.0, dt * 10.0), raw)
    local n = grip.n
    local target = n
    local pull = cfg.press
    local carry = UP * GRAVITY

    -- Onto a steeper surface the nose is touching, only while driving at it.
    local forward = dot(velocity, frame.f)
    local climbing = false
    if cfg.climb ~= false and forward > 0.5 and GetControlNormal(0, 71) > 0.05 then
        local reach = math.min(2.0, cfg.climbReach + forward * 0.12)
        local from = frame.pos + frame.f * (layout.halfLength - 0.2) - frame.u * (layout.ground * 0.5)
        local to = from + frame.f * reach
        local hit, point, wall = P.probe(from, to, vehicle)
        line(from, to, hit, 60, 160, 255)
        if hit and dot(frame.f, wall) < -0.3 and dot(wall, n) < math.cos(math.rad(cfg.climbAngle)) then
            local w = 1.0 - math.min(1.0, #(point - from) / reach)
            target = unit(n * (1.0 - w) + wall * w, n)
            local climb = unit(n - wall * dot(n, wall), UP)
            local turn = P.turnOnto(velocity, wall, climb, -dot(velocity, wall) * math.min(1.0, dt * 10.0 * w))
            -- At the front axle, so it also lifts the nose onto the surface.
            P.pushWorldAt(vehicle, turn / dt, ctx.model.front, dt)
            climbing = true
            if not grip.climbing then
                debug(('grip climb: %.0f deg steeper, %.1f m ahead, %.1f m/s'):format(
                    math.deg(math.acos(math.max(-1.0, math.min(1.0, dot(wall, n))))), #(point - from), forward))
            end
        end
    end
    grip.climbing = climbing

    -- No bouncing off: the fans pull harder while the car lifts away, damped
    -- rather than cut so the suspension still works.
    local away = dot(velocity, n)
    if away > 0 then pull = pull + math.min(away * 8.0, cfg.press) end
    -- Parked on a slope or wall: holds still instead of creeping down. Never
    -- brakes a car that is driving or rolling at speed.
    if not driving() then
        local slide = velocity - n * dot(velocity, n)
        local speed = length(slide)
        if speed > 0.01 and speed < PARKED then carry = carry - slide * (math.min(speed / dt, cfg.hold) / speed) end
    end
    P.pushWorld(vehicle, carry, dt)
    local alpha = P.align(frame, target, cfg.align, spin, FOLLOW)
    P.fans(ctx.model, pull, P.toBody(frame, alpha), cfg.press * 2.0, fanOut)
    for i = 1, 4 do
        if fanOut[i] > 0 then P.push(vehicle, DOWN, fanOut[i], layout.thrusters[i].offset, dt) end
    end
    return target
end

-- Landing assist: once the car has been airborne a moment and is falling
-- toward ground it will reach within `lookahead` seconds, probe the ground
-- under each of the four tyres. Their plane is what the car levels to, so
-- all four wheels arrive together, and the corner sinking fastest for its
-- gap sets how hard the lift nozzles brake. Returns target normal, thrust
-- along the car's up (0 = none) and levelling gain; nil when idle.
local function landingFrame(now, fr, velocity)
    local cfg = C.landing
    if not assist() or (trick and not trick.turned) or lifting() or recover.active or (grip.on and grip.contact) then return nil end
    if now - air.since < cfg.minAir * 1000 or velocity.z >= 0 then return nil end
    local vehicle, layout = ctx.vehicle, ctx.layout
    local hit, point, normal = P.probe(fr.pos, fr.pos - UP * cfg.probe, vehicle)
    if not hit then return nil end
    local height = math.max(0.0, fr.pos.z - point.z - layout.ground)
    if height / -velocity.z > cfg.lookahead then return nil end
    local safe, need, hits = cfg.safeSpeed, 0.0, 0
    local reach = height + layout.ground + 3.0
    for i = 1, 4 do
        local p = layout.thrusters[i].pos
        local tyre = fr.pos + fr.r * p.x + fr.f * p.y - fr.u * layout.ground
        local from = tyre + UP * 0.5
        local found, ground = P.probe(from, tyre - UP * reach, vehicle)
        line(from, tyre - UP * reach, found, 255, 200, 60)
        if found then
            hits = hits + 1
            wheels[i] = ground
            local gap = math.max(0.05, tyre.z - ground.z)
            local sink = dot(velocity + P.cross(spin, tyre - fr.pos), UP)
            if sink < -safe then need = math.max(need, (sink * sink - safe * safe) / (2.0 * gap)) end
        end
    end
    if hits == 4 then
        -- Diagonals FR-RL and FL-RR span the ground under the tyres.
        local plane = unit(P.cross(wheels[2] - wheels[3], wheels[1] - wheels[4]), normal)
        if plane.z > 0.3 then normal = plane end
    elseif velocity.z < -safe then
        need = (velocity.z * velocity.z - safe * safe) / (2.0 * math.max(height, 0.05))
    end
    air.normal = normal
    local thrust = 0.0
    -- Only once the lift nozzles face the ground; levelling comes first.
    if need > 0 and fr.u.z > 0.3 then thrust = math.min(need * 1.1 + GRAVITY, cfg.maxAccel) / math.max(fr.u.z, 0.5) end
    -- Level faster the closer touchdown is, within LEVEL's limits.
    local gain = math.max(cfg.align, 3.0 * -velocity.z / math.max(height, 0.3))
    return normal, thrust, gain
end

-- Ends a recovery: righted, or given up after `seconds`.
local function recoveryDone(now, righted)
    recover.active = false
    if not righted then notify('notify.stuck', 'warning') end
    debug(('recovery %s after %.1fs'):format(righted and 'done' or 'gave up', (now - recover.at) / 1000))
end

local traceAt, prevVelocity = 0, nil
-- Turn disturbance (world rad/s^2): how the car's real turn differs from what
-- the nozzles were meant to give. An off-centre weight or a wrong inertia
-- guess shows up here, and the allocation asks for that much more or less.
-- Learned whenever the RCS steers the car in the air; forgotten on touchdown.
local disturb, prevSpin, lastTurn, observing = ZERO, nil, ZERO, false
local DISTURB_LAG = 0.08 -- seconds; smooths the noisy measurement
-- Lift trim: what the climb controller has learned the car needs on top of
-- its weight (downforce, suspension, the game delivering less than asked).
local liftTrim, liftHeight = 0.0, 0.0

local function frame(now, dt)
    local vehicle = ctx.vehicle
    if not NetworkHasControlOfEntity(vehicle) then
        -- Someone else simulates the car: no thrust, no gas, fresh spin later.
        for i = 1, LY.COUNT do throttle[i] = 0.0 end
        lit, prevFrame, prevVelocity = 0, nil, nil
        setDrain(0, now)
        output(grip.on and LY.GRIP or 0, now)
        return
    end
    if tricking() then readTricks(now) end

    local fr = P.frame(vehicle)
    local airborne = IsEntityInAir(vehicle)
    spin = P.spinBetween(prevFrame, fr, dt)
    if observing and prevSpin and prevFrame then
        local seen = (spin - prevSpin) / dt - lastTurn
        disturb = disturb + (seen - disturb) * math.min(1.0, dt / DISTURB_LAG)
    elseif not airborne then
        disturb = ZERO
    end
    prevSpin, observing = spin, false
    prevFrame = fr
    local velocity = GetEntityVelocity(vehicle)
    local locked = tank.locked
    local onWheels = IsVehicleOnAllWheels(vehicle)

    -- What the gas nozzles should do this frame: a push in the car's frame
    -- (fx right, fy forward, fz up) with how much each axis matters, and a
    -- turn (world angular acceleration).
    local fx, fy, fz = 0.0, 0.0, 0.0
    local wx, wy, wz = IDLE_W, IDLE_W, IDLE_W * 0.25
    local alpha, burst, paid = nil, false, false
    local trickRow = nil -- allocation row of the axis a trick turns about

    -- A hop always breaks the suction for a moment, wall or floor.
    if pendingHop then
        pendingHop = false
        if grip.contact then grip.releaseUntil, grip.contact = now + C.grip.release * 1000, false end
    end

    -- Grip first: it decides whether the car is on a surface this frame.
    local m = 0
    local gripTarget = nil
    if grip.on then
        m = m | LY.GRIP
        gripTarget = gripFrame(now, dt, fr, velocity)
    end

    -- Airborne bookkeeping and the landing assist.
    local landTarget, landThrust, landGain = nil, 0.0, nil
    if air.armed then
        if airborne then
            air.lastAir = now
            landTarget, landThrust, landGain = landingFrame(now, fr, velocity)
            landThrust = landThrust or 0.0
        elseif now - air.lastAir > 250 then
            air.armed = false
        elseif assist() and now - air.since >= C.landing.minAir * 1000 then
            air.settleUntil = now + 300
        end
    end

    -- Recovery: push away from the ground with whatever nozzles face it and
    -- turn upright. On the roof nothing faces the ground, so it rocks the car
    -- in time with its own sway until it tips onto a side.
    if recover.active then
        local cfg = C.recovery
        local t = (now - recover.at) / 1000
        if fr.u.z > 0.9 and length(spin) < 1.0 then
            recoveryDone(now, true)
        elseif t > (cfg.seconds or 6.0) or locked then
            recoveryDone(now, false)
        else
            local away = P.toBody(fr, UP * (GRAVITY * (cfg.lift or 1.15)))
            fx, fy, fz, wx, wy, wz = away.x, away.y, away.z, 3.0, 3.0, 3.0
            burst = true
            if fr.u.z < -0.5 then
                -- Nothing can push it off the ground: give the rocking every nozzle.
                fx, fy, fz, wx, wy, wz = 0.0, 0.0, 0.0, 0.25, 0.25, 0.25
                local sway = dot(spin, fr.f)
                if math.abs(sway) > 0.4 then
                    recover.pump, recover.pumpAt = sway > 0 and 1 or -1, now
                elseif now - recover.pumpAt > 700 then
                    recover.pump, recover.pumpAt = -recover.pump, now
                end
                alpha = fr.f * ((cfg.rock or 14.0) * recover.pump)
            else
                alpha = P.align(fr, UP, cfg.align or 3.0, spin, RECOVER)
            end
        end
    end

    if now < hopUntil and not recover.active and not trick then
        local hopTime = C.lift.hopTime or 0.25
        fz, wz = math.max(fz, C.lift.hop / hopTime + GRAVITY * math.max(0.0, fr.u.z)), FORCE_W
        burst, paid = true, true
    end
    if lifting() and not locked and not recover.active and trick then
        -- A trick owns the nozzles: held lift only tries to hold the height
        -- (vertical speed toward zero) while the lift nozzles face down,
        -- below the turn in priority. Upside down it gives nothing.
        if fz == 0 and fr.u.z > 0.3 then
            local hold = GRAVITY + math.max(0.0, liftTrim) - velocity.z * (C.lift.response or 6.0)
            fz, wz = P.clamp(hold, 0.0, C.lift.accel) / math.max(fr.u.z, 0.5), 1.0
        end
    elseif lifting() and not locked and not recover.active then
        -- Just enough thrust to carry the car's weight and climb at a steady
        -- `climb` m/s, easing to a hover at `ceiling` metres up. Along the
        -- car's up, so on a wall it pushes off gently instead of rising.
        -- If the car climbs slower than asked, the trim builds up until it
        -- doesn't, so every vehicle gets as much as it really needs.
        local cfg = C.lift
        local climb = cfg.climb or 8.0
        if cfg.ceiling then
            -- Brakes into the hover height at `brake` m/s^2 from any speed.
            liftHeight = GetEntityHeightAboveGround(vehicle) - ctx.layout.ground
            local gap = cfg.ceiling - liftHeight
            climb = (gap >= 0 and 1 or -1) * math.min(climb, math.sqrt(2.0 * (cfg.brake or 6.0) * math.abs(gap)))
        end
        local rise = dot(velocity, fr.u)
        local miss = climb - rise
        local raw = GRAVITY * fr.u.z + miss * (cfg.response or 3.0) + liftTrim
        -- Learns only from the steady push: not during a hop's burst, never
        -- past what the nozzles can give, and only a little below nothing.
        if now >= hopUntil and (raw < cfg.accel or miss < 0) and (raw > 0 or miss > 0) then
            liftTrim = P.clamp(liftTrim + miss * (cfg.trim or 4.0) * dt, -3.0, cfg.accel)
        end
        local thrust = P.clamp(raw, 0.0, cfg.accel)
        -- In the air the lift nozzles only push once they face the ground;
        -- until then the RCS turns the car upright (hover levelling below).
        local facing = airborne and P.clamp((fr.u.z - 0.3) / 0.4, 0.0, 1.0) or 1.0
        fz, wz = math.max(fz, thrust * facing), FORCE_W
    end
    if boosting() and not locked then
        fy, wy = C.boost.accel * P.clamp((C.boost.maxSpeed - dot(velocity, fr.f)) * 0.5, 0.0, 1.0), FORCE_W
    end
    if landThrust > 0 then fz, wz = math.max(fz, landThrust), FORCE_W end

    -- One owner for the turn each frame: trick, recovery, grip (its fans),
    -- landing, settle, hover, then in-flight steadying.
    if trick then
        local t = (now - trick.at) / 1000
        local plan = trick.plan
        local turnEnd = plan.rise + plan.duration
        paid = true
        if trick.hop > 0 then
            -- The rise: the lift nozzles push the car up evenly to the hop speed.
            local wanted = plan.rise > 0 and trick.hop * math.min(1.0, t / plan.rise) or trick.hop
            local up = math.max(0.0, trick.hop / math.max(plan.rise, 0.05) + GRAVITY + (wanted - velocity.z) * 6.0)
            fz, wz, burst = math.max(fz, up / math.max(fr.u.z, 0.5)), FORCE_W, true
            if t >= plan.rise then trick.hop = 0 end
        end
        if t < plan.rise then
            -- The rise pushes hard on all four lift nozzles; with the weight
            -- off centre that twists the car, so hold it level firmly.
            alpha = P.align(fr, UP, 8.0, spin, RISE)
        elseif not trick.turnedAt then
            -- The turn: one full turn about the axis the car had when the
            -- rise ended, counted from how far it has really turned. It
            -- spins up as fast as the nozzles manage, and brakes in time
            -- for what this car showed it can do, so a heavy car still
            -- finishes the turn instead of stopping halfway round.
            if not trick.axis then
                trick.axis = plan.axis == 'x' and fr.r or plan.axis == 'y' and fr.f or fr.u
                trick.angle, trick.from = 0.0, t
            end
            local w = dot(spin, trick.axis)
            trick.angle = trick.angle + w * dt
            local left = plan.sign * 2.0 * math.pi - trick.angle
            local peak = math.abs(plan.rate)
            local planned = peak / (plan.catch > 0 and plan.catch or 0.3)
            local elapsed = t - trick.from
            if elapsed > 0.05 and math.abs(w) < peak * 0.9 and left * plan.sign > math.pi then
                trick.authority = math.max(trick.authority or 0.0, math.abs(w) / elapsed)
            end
            local brake = P.clamp((trick.authority or planned) * 0.8, 2.0, planned)
            -- Only lift nozzles can stop a flip or roll, and they push along
            -- the car's up: braking hard at the end, with the car upright,
            -- throws it back into the air. Spread over the last half turn,
            -- the push starts out pointing at the ground and mostly cancels.
            -- Spins stop on the corner nozzles, which push sideways.
            if plan.axis ~= 'z' then brake = math.min(brake, peak * peak / (2.0 * BRAKE_ARC)) end
            -- The nozzles reach a new turn rate about 1/RESPONSE s late, so
            -- brake for where the car will be by then, not where it is: a
            -- late brake overshoots, and turning back fires the lift nozzles
            -- with the car upright, which throws it into the air.
            local closing = math.max(0.0, w * (left >= 0 and 1 or -1))
            local speed = math.min(peak, math.sqrt(2.0 * brake * math.max(0.0, math.abs(left) - closing / RESPONSE)))
            -- Keep the car's own axis on the trick's axis: a front flip stays
            -- a front flip even if the car's weight sits off centre and the
            -- push twists it, instead of only slowing the twist down.
            local own = plan.axis == 'x' and fr.r or plan.axis == 'y' and fr.f or fr.u
            local drift = P.cross(own, trick.axis)
            alpha = (trick.axis * ((left >= 0 and 1 or -1) * speed) - spin) * RESPONSE + drift * (C.tricks.hold or 30.0)
            burst = true
            trickRow = plan.axis == 'x' and 4 or plan.axis == 'y' and 5 or 6
            if C.debug and now >= (trick.traceAt or 0) then
                trick.traceAt = now + 100
                local rate = P.toBody(fr, spin)
                debug(('trick %.2fs turned %4.0f | rate pitch %5.2f roll %5.2f yaw %5.2f | off axis %4.1f deg | lift %4.1f %4.1f %4.1f %4.1f | corner %4.1f %4.1f %4.1f %4.1f'):format(
                    elapsed, math.deg(trick.angle), rate.x, rate.y, rate.z, math.deg(math.asin(math.min(1.0, length(drift)))),
                    throttle[1], throttle[2], throttle[3], throttle[4], throttle[9], throttle[10], throttle[11], throttle[12]))
            end
            -- Ends when the turn is done or the car has landed; the safety
            -- limit is long, so levelling never turns a slow flip back.
            local finished = math.abs(left) < math.rad(8) and math.abs(w) < 0.6
            if finished or (not airborne and elapsed > 0.3) or t > turnEnd + (C.tricks.overtime or 3.0) then
                trick.turnedAt, trick.turned = t, true
                debug(('trick turned %.0f deg in %.2fs (planned %.2fs), authority %.1f rad/s^2'):format(
                    math.deg(math.abs(trick.angle)), elapsed, plan.duration, trick.authority or 0))
            end
        elseif t < trick.turnedAt + C.tricks.settle then
            alpha = P.align(fr, landTarget or UP, C.landing.align, spin, LEVEL)
            -- Levelling keeps any spin about up; after a spin trick, stop it.
            if plan.axis == 'z' then alpha = alpha - fr.u * (dot(spin, fr.u) * RESPONSE) end
        else
            trick, lastTrickEnd = nil, now
        end
    elseif recover.active or gripTarget then
        -- Recovery set its own turn; under grip the fans do the turning.
    elseif landTarget then
        alpha = P.align(fr, landTarget, landGain, spin, LEVEL)
    elseif now < air.settleUntil and not onWheels then
        alpha = P.align(fr, air.normal, C.landing.align, spin, LEVEL)
    elseif lifting() and not onWheels then
        alpha = P.align(fr, UP, C.lift.level, spin, LEVEL)
    elseif airborne and air.armed and assist() and (RCS.damping or 0) > 0 and not airControl()
        and now - air.since >= C.landing.minAir * 1000 then
        -- In flight: calm any tumble (roll and pitch); a spin is kept.
        alpha = (fr.u * dot(spin, fr.u) - spin) * RCS.damping
    end

    -- Allocate the gas nozzles.
    local model, n = ctx.model, LY.COUNT
    local total = 0.0
    if locked or not (alpha or fx ~= 0 or fy ~= 0 or fz ~= 0) then
        for i = 1, n do throttle[i] = 0.0 end
        lastTurn = ZERO
    else
        want[1], want[2], want[3], weight[1], weight[2], weight[3] = fx, fy, fz, wx, wy, wz
        if alpha then
            -- In the air nothing else turns the car, so the gap between the
            -- turn asked for and the turn it made is the car's own (weight
            -- off centre, a heavier body than modelled): allow for it.
            if airborne and not gripTarget then
                observing = true
                alpha = alpha - disturb
            end
            local a = P.toBody(fr, alpha)
            want[4], want[5], want[6], weight[4], weight[5], weight[6] = a.x, a.y, a.z, TURN_W, TURN_W, TURN_W
            if trickRow then
                -- Out of nozzle: turn a little slower rather than twist sideways.
                for k = 4, 6 do if k ~= trickRow then weight[k] = TURN_W * 4.0 end end
            end
        else
            -- Nothing to turn: add no yaw, and no roll or pitch either unless
            -- the wheels are down and only the boost fires (its pitch is the
            -- suspension's to carry). Lifting off the wheels stays level.
            local free = (onWheels and fz <= 0) and 0.0 or TURN_W
            want[4], want[5], want[6], weight[4], weight[5], weight[6] = 0.0, 0.0, 0.0, free, free, TURN_W
        end
        local scale = burst and (RCS.burst or 2.5) or 1.0
        for i = 1, n do limit[i] = NOZZLE[model.groups[i]] * scale end
        P.allocate(model, want, weight, limit, throttle, 6)
        if observing then
            -- The turn these throttles give, by the model, for next frame's comparison.
            local ax, ay, az = 0.0, 0.0, 0.0
            for i = 1, n do
                local c, t = model.cols[i], throttle[i]
                ax, ay, az = ax + c[4] * t, ay + c[5] * t, az + c[6] * t
            end
            lastTurn = P.toWorld(fr, vector3(ax, ay, az))
        end
        local thrusters = ctx.layout.thrusters
        for i = 1, n do
            local t = throttle[i]
            if t > 0 then
                P.push(vehicle, model.push[i], t, thrusters[i].offset, dt)
                total = total + t
            end
        end
    end

    -- Jets drawn from the real throttles, with hysteresis so they don't flicker.
    local jets = 0
    for i = 1, n do
        local bit = 1 << (i - 1)
        if throttle[i] > (lit & bit ~= 0 and OFF or ON) then jets = jets | bit end
    end
    lit = jets
    m = m | jets

    -- Gas follows the thrust actually used; hops and tricks paid up front.
    local drain = 0.0
    if not paid and total > 0 then drain = math.floor(total * (RCS.gas or 1.6) / DRAIN_STEP + 0.5) * DRAIN_STEP end
    setDrain(drain, now)
    if tank.locked and not locked then m = m & LY.GRIP end

    if C.debug and now >= traceAt then
        traceAt = now + (lifting() and 500 or 1000)
        local meas = prevVelocity and P.toBody(fr, (velocity - prevVelocity) / dt + UP * GRAVITY) or ZERO
        local lift, boost, corner = 0.0, 0.0, 0.0
        for i = 1, n do
            local g = model.groups[i]
            if g == 'lift' then lift = lift + throttle[i] elseif g == 'boost' then boost = boost + throttle[i] else corner = corner + throttle[i] end
        end
        debug(('rcs want fwd %.1f up %.1f | felt fwd %.1f up %.1f | lift %.1f boost %.1f corner %.1f | gas %.0f/s air %s | rise %.1f h %.1f trim %.1f'):format(
            fy, fz, meas.y, meas.z, lift, boost, corner, drain, tostring(airborne), dot(velocity, fr.u), liftHeight, liftTrim))
    end
    prevVelocity = velocity

    output(grip.on and (m | LY.GRIP) or (m & ~LY.GRIP), now)
    hud(now)
end

local function busy(now)
    return ctx.active and (lifting() or boosting() or tricking() or trick ~= nil or recover.active or grip.on or pendingHop
        or air.armed or now < air.settleUntil or now < hopUntil or mask ~= 0 or sent ~= mask)
end

local function ensureFrame()
    if running or not ctx.active then return end
    running = true
    CreateThread(function()
        prevFrame, prevVelocity = nil, nil
        while not stopped and busy(GetGameTimer()) do
            Wait(0)
            if not ctx.active then break end
            local dt = GetFrameTime()
            if dt > 0 then frame(GetGameTimer(), math.min(0.05, dt)) end
        end
        local now = GetGameTimer()
        if ctx.active then
            setDrain(0, now)
            output(0, now)
            send(now, true)
            hud(now)
        end
        running = false
    end)
end

-- Context -----------------------------------------------------------------------

local function tankFor(vehicle)
    local entry = tanks[vehicle]
    if not entry then
        entry = T.new(C.tank)
        tanks[vehicle] = entry
    end
    return entry
end

local function reset(now)
    held.lift, held.liftPad, held.boost, held.boostPad, held.trick, held.trickPad = false, false, false, false, false, false
    trick, pendingHop, hopUntil = nil, false, 0
    recover.active, recover.stuckSince = false, nil
    grip.on, grip.contact = false, false
    air.armed, air.settleUntil = false, 0
    for i = 1, LY.COUNT do throttle[i] = 0.0 end
    lit = 0
    setDrain(0, now)
end

local function leave()
    local now = GetGameTimer()
    local vehicle = ctx.vehicle
    reset(now)
    mask = 0
    if vehicle ~= 0 and DoesEntityExist(vehicle) then F.set(vehicle, 0, false) end
    send(now, true)
    ctx.active, ctx.vehicle, ctx.netId, ctx.layout, ctx.model = false, 0, 0, nil, nil
    S.vehicle = nil
    hideLegend()
    hud(now)
end

local function enter(vehicle)
    if ctx.active then leave() end
    local now = GetGameTimer()
    F.clear(vehicle) -- whatever the remote renderer drew for the last driver
    ctx.active, ctx.vehicle, ctx.enteredAt = true, vehicle, now
    ctx.netId = NetworkGetEntityIsNetworked(vehicle) and VehToNet(vehicle) or 0
    ctx.layout = F.layout(vehicle)
    ctx.layout.rcs = ctx.layout.rcs or P.model(ctx.layout)
    ctx.model = ctx.layout.rcs
    for i = 1, LY.COUNT do throttle[i] = 0.0 end
    lit, liftTrim = 0, 0.0
    S.vehicle = vehicle
    tank = tankFor(vehicle)
    mask, sent = 0, 0
    if prefs.legend == 'enter' then showLegend(C.legend.seconds or 8) end
    hud(now)
end

local function usable(vehicle, ped)
    return not IsEntityDead(ped) and not IsEntityDead(vehicle) and S.allowedVehicle(vehicle)
        and GetEntitySubmergedLevel(vehicle) < 0.7
end

CreateThread(function()
    local wasFull = true
    while not stopped do
        local now = GetGameTimer()
        local ped = PlayerPedId()
        local vehicle = GetVehiclePedIsIn(ped, false)
        local driving = vehicle ~= 0 and GetPedInVehicleSeat(vehicle, -1) == ped
        local ok = driving and fitted(vehicle) and usable(vehicle, ped)
        if ok and ctx.vehicle ~= vehicle then enter(vehicle); wasFull = T.peek(tank, now) >= tank.capacity
        elseif not ok and ctx.active then leave() end

        if driving and not fitted(vehicle) and C.persist and NetworkGetEntityIsNetworked(vehicle)
            and now - (asked[vehicle] or -60000) > 15000 then
            asked[vehicle] = now
            TriggerServerEvent(RESOURCE .. ':server:check', VehToNet(vehicle))
        end

        if ctx.active then
            -- Off the ground: start the frame loop so the landing assist can watch the fall.
            if C.landing.enabled and prefs.landing and not air.armed and IsEntityInAir(ctx.vehicle) then
                air.armed, air.since, air.lastAir = true, now, now
                ensureFrame()
            end
            -- Stuck on the roof or side for `auto` seconds: right it without a key press.
            if C.recovery.auto and not recover.active then
                if flipped(ctx.vehicle) then
                    recover.stuckSince = recover.stuckSince or now
                    if now - recover.stuckSince >= C.recovery.auto * 1000 and T.can(tank, now, C.lift.hopCost) then
                        recover.stuckSince = nil
                        startRecovery(now)
                        ensureFrame()
                    end
                else
                    recover.stuckSince = nil
                end
            end
            T.setFactor(tank, now, GetIsVehicleEngineRunning(ctx.vehicle) and 1.0 or (C.tank.engineOff or 0.4))
            local full = T.peek(tank, now) >= tank.capacity
            if full and not wasFull then F.play(ctx.vehicle, 'full') end
            wasFull = full
            if legendShown and now >= legendUntil then hideLegend() end
            if not running then hud(now) end
        end
        for handle in pairs(tanks) do
            if handle ~= ctx.vehicle and not DoesEntityExist(handle) then tanks[handle], asked[handle] = nil, nil end
        end
        Wait(ctx.active and 100 or 500)
    end
end)

-- Input -------------------------------------------------------------------------

local function liftDown(key)
    held[key] = true
    if not ctx.active then return end
    local now = GetGameTimer()
    -- On the roof or side the lift nozzles can't hop it: they right it instead.
    if flipped(ctx.vehicle) then startRecovery(now); ensureFrame(); return end
    -- Mid-trick the nozzles are the trick's: no hop, no gas spent.
    if trick then ensureFrame(); return end
    -- Tumbling in the air with the nozzles facing up: no hop, holding still levels and lifts.
    if IsEntityInAir(ctx.vehicle) and GetEntityUprightValue(ctx.vehicle) < 0.3 then ensureFrame(); return end
    if tank.locked or not T.can(tank, now, C.lift.hopCost) then refused(now); ensureFrame(); return end
    if spend(C.lift.hopCost, now) then pendingHop, hopUntil = true, now + (C.lift.hopTime or 0.25) * 1000 end
    ensureFrame()
end

local function holdKey(name, key, label, default, pad, padDefault, onDown)
    local function down(which) return function() if onDown then onDown(which) else held[which] = true end; ensureFrame() end end
    local function up(which) return function() held[which] = false end end
    RegisterCommand('+cortexthrusters_' .. name, down(key), false)
    RegisterCommand('-cortexthrusters_' .. name, up(key), false)
    RegisterKeyMapping('+cortexthrusters_' .. name, label, 'keyboard', default)
    RegisterCommand('+cortexthrusters_' .. name .. 'pad', down(pad), false)
    RegisterCommand('-cortexthrusters_' .. name .. 'pad', up(pad), false)
    RegisterKeyMapping('+cortexthrusters_' .. name .. 'pad', label .. ' (' .. L('keys.controller') .. ')', 'PAD_DIGITALBUTTONANY', padDefault)
end

holdKey('lift', 'lift', L('keys.lift'), C.keys.lift, 'liftPad', C.keys.liftPad, liftDown)
holdKey('boost', 'boost', L('keys.boost'), C.keys.boost, 'boostPad', C.keys.boostPad, function(which)
    held[which] = true
    if ctx.active and tank.locked then refused(GetGameTimer()) end
end)
holdKey('trick', 'trick', L('keys.trick'), C.keys.trick, 'trickPad', C.keys.trickPad)

local function toggleGrip()
    if not ctx.active then return end
    local now = GetGameTimer()
    if grip.on then
        grip.on, grip.contact = false, false
        -- The fans need a rest before they grip again (Config.grip.cooldown, 0 = none).
        grip.coolUntil = now + (C.grip.cooldown or 0) * 1000
    elseif now < grip.coolUntil then
        notify('notify.gripCooling', 'warning', { seconds = math.ceil((grip.coolUntil - now) / 1000) })
        return
    else
        grip.on, grip.lastContact, grip.n = true, now, P.frame(ctx.vehicle).u
    end
    hudRev = hudRev + 1
    ensureFrame()
end
RegisterCommand('cortexthrusters_grip', toggleGrip, false)
RegisterKeyMapping('cortexthrusters_grip', L('keys.grip'), 'keyboard', C.keys.grip)
RegisterCommand('cortexthrusters_grippad', toggleGrip, false)
RegisterKeyMapping('cortexthrusters_grippad', L('keys.grip') .. ' (' .. L('keys.controller') .. ')', 'PAD_DIGITALBUTTONANY', C.keys.gripPad)

-- Server pushes -------------------------------------------------------------------

RegisterNetEvent(RESOURCE .. ':client:notify', function(key, kind)
    if type(key) == 'string' and key:match('^notify%.[%w]+$') then notify(key, kind == 'success' and 'success' or 'error') end
end)

-- Settings (Cortex settings > Thrusters) ---------------------------------------

local function readPrefs()
    local function read(key, fallback)
        local ok, value = pcall(function() return exports['cortex-lib']:getTabSetting(TAB, key) end)
        if ok and value ~= nil then return value end
        return fallback
    end
    local legend = read('legend', C.legend.mode or 'enter')
    prefs.legend = (legend == 'enter' or legend == 'off') and legend or 'enter'
    prefs.hud = read('hud', true) ~= false
    prefs.landing = read('landing', true) ~= false
    view.visible = nil
end

local function registerSettings()
    local rows = {
        { key = 'legend', type = 'select', label = L('settings.legend'), description = L('settings.legend.help'),
            options = { { value = 'enter', label = L('settings.legend.enter') }, { value = 'off', label = L('settings.legend.off') } } },
        { key = 'hud', type = 'toggle', label = L('settings.hud'), description = L('settings.hud.help') },
        { key = 'landing', type = 'toggle', label = L('settings.landing'), description = L('settings.landing.help') },
    }
    pcall(function()
        exports['cortex-lib']:registerSettings(TAB, L('settings.tab'), 'cortex-thrusters:', rows, { legend = C.legend.mode or 'enter', hud = true, landing = true })
    end)
    readPrefs()
end
AddEventHandler('cortex-lib:settingsChanged', function(tabId) if tabId == TAB then readPrefs() end end)
AddEventHandler('onClientResourceStart', function(name) if name == 'cortex-lib' then registerSettings() end end)
CreateThread(function() Wait(250); registerSettings() end)

RegisterNUICallback('ready', function(_, cb)
    SendNUIMessage({ action = 'thrusters:text', data = { label = L('hud.label'), locked = L('hud.locked'), grip = L('hud.grip') } })
    view.visible = nil
    hud(GetGameTimer())
    cb({ ok = true })
end)

AddEventHandler('onClientResourceStop', function(name)
    if name ~= RESOURCE then return end
    stopped = true
    if ctx.active then leave() end
    hideLegend()
end)

exports('isActive', function() return ctx.active end)
exports('getCharge', function() return T.peek(tank, GetGameTimer()), tank.capacity end)

-- Debug ---------------------------------------------------------------------------

if C.debug then
    local drawing, tuning = false, nil
    RegisterCommand('thrusters_debug', function()
        drawing = not drawing
        CreateThread(function()
            while drawing do
                local vehicle = GetVehiclePedIsIn(PlayerPedId(), true)
                if vehicle ~= 0 then
                    for _, thruster in ipairs(F.layout(vehicle).thrusters) do
                        local p = GetOffsetFromEntityInWorldCoords(vehicle, thruster.offset.x, thruster.offset.y, thruster.offset.z)
                        local onScreen, x, y = GetScreenCoordFromWorldCoord(p.x, p.y, p.z)
                        if onScreen then
                            SetTextScale(0.0, 0.32); SetTextFont(4); SetTextCentre(true); SetTextOutline()
                            BeginTextCommandDisplayText('STRING')
                            AddTextComponentSubstringPlayerName(tostring(thruster.index))
                            EndTextCommandDisplayText(x, y)
                        end
                    end
                end
                Wait(0)
            end
        end)
    end, false)
    RegisterCommand('thrusters_fx', function(_, args)
        local vehicle = GetVehiclePedIsIn(PlayerPedId(), true)
        if vehicle == 0 then return end
        local groups = { lift = LY.MASK_LIFT, boost = LY.MASK_BOOST, corner = LY.MASK_CORNER }
        local m = groups[args[1] or ''] or LY.MAX
        F.set(vehicle, m, true)
        SetTimeout(4000, function() F.set(vehicle, 0, false) end)
    end, false)
    -- /thrusters_layer <group> <layer> <asset> <effect> [scale]: swap one
    -- effect live (group 'ground' for the ground cloud), fire it for 4 s and
    -- print the config line.
    RegisterCommand('thrusters_layer', function(_, args)
        local group, index, asset, name = args[1], tonumber(args[2]), args[3], args[4]
        local scale = tonumber(args[5])
        local layers = group == 'ground' and C.fx.ground and C.fx.ground.layers or C.fx[group or '']
        local layer = type(layers) == 'table' and layers[index or 0]
        if not (layer and asset and name) then
            print('[cortex-thrusters] usage: /thrusters_layer lift|boost|corner|ground <layer> <asset> <effect> [scale]')
            return
        end
        layer.asset, layer.name = asset, name
        if scale then layer.scale = scale end
        RequestNamedPtfxAsset(asset)
        print(('[cortex-thrusters] fx.%s[%d]: asset = %q, name = %q, scale = %.2f'):format(
            group == 'ground' and 'ground.layers' or group, index, asset, name, layer.scale or 1.0))
        local vehicle = GetVehiclePedIsIn(PlayerPedId(), true)
        if vehicle == 0 then return end
        local masks = { lift = LY.MASK_LIFT, ground = LY.MASK_LIFT, boost = LY.MASK_BOOST, corner = LY.MASK_CORNER }
        F.clear(vehicle)
        CreateThread(function()
            local deadline = GetGameTimer() + 3000
            while not HasNamedPtfxAssetLoaded(asset) and GetGameTimer() < deadline do Wait(0) end
            if not HasNamedPtfxAssetLoaded(asset) then print(('[cortex-thrusters] asset %s did not load'):format(asset)) end
            F.set(vehicle, masks[group], false)
            local token = {}
            tuning = token
            SetTimeout(4000, function() if tuning == token then F.set(vehicle, 0, false) end end)
        end)
    end, false)
    -- /thrusters_rot <group> <layer> <x> <y> <z>: turn one effect layer live,
    -- fire the group for 4 s and print the line to paste into config.lua.
    RegisterCommand('thrusters_rot', function(_, args)
        local group, index = args[1], tonumber(args[2])
        local layer = C.fx[group or ''] and C.fx[group][index or 0]
        local x, y, z = tonumber(args[3]), tonumber(args[4]), tonumber(args[5])
        if not (layer and x and y and z) then
            print('[cortex-thrusters] usage: /thrusters_rot lift|boost|corner <layer> <x> <y> <z>')
            return
        end
        layer.rot = { x = x + 0.0, y = y + 0.0, z = z + 0.0 }
        print(('[cortex-thrusters] fx.%s[%d] %s: rot = { x = %.1f, y = %.1f, z = %.1f }'):format(group, index, layer.name, x, y, z))
        local vehicle = GetVehiclePedIsIn(PlayerPedId(), true)
        if vehicle == 0 then return end
        local masks = { lift = LY.MASK_LIFT, boost = LY.MASK_BOOST, corner = LY.MASK_CORNER }
        F.clear(vehicle)
        F.set(vehicle, masks[group], false)
        local token = {}
        tuning = token
        SetTimeout(4000, function() if tuning == token then F.set(vehicle, 0, false) end end)
    end, false)
end
