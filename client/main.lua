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

local ctx = { active = false, vehicle = 0, layout = nil, enteredAt = 0, netId = 0 }
local held = { lift = false, liftPad = false, boost = false, boostPad = false, trick = false, trickPad = false }
local grip = { on = false, contact = false, climbing = false, n = UP, lastContact = 0, releaseUntil = 0, coolUntil = 0 }
-- Landing assist: armed by the watcher when the car leaves the ground.
local air = { armed = false, since = 0, lastAir = 0, settleUntil = 0, normal = UP }
local trick, pendingHop, hopUntil, lastTrickEnd = nil, false, 0, 0
local mask, sent, sentAt, drainRate = 0, 0, 0, 0
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
    if trick or now - lastTrickEnd < C.tricks.cooldown * 1000 then return end
    if grip.contact and grip.n.z < 0.8 then notify('notify.trickWall', 'warning'); return end
    if tank.locked or not T.can(tank, now, C.tricks.cost) then refused(now); return end
    local vehicle, layout = ctx.vehicle, ctx.layout
    local airborne = not IsVehicleOnAllWheels(vehicle) and GetEntityHeightAboveGround(vehicle) > layout.ground + 0.8
    local plan = K.plan(kind, layout, airborne, C.tricks)
    if not plan or not spend(plan.cost, now) then return end
    -- The turn axis is taken when the rise ends, from the car as it is then.
    trick = { plan = plan, at = now, hop = plan.hop }
    if grip.on then grip.releaseUntil = now + (plan.rise + plan.duration + C.tricks.settle) * 1000 end
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

-- Grip: underbody fans, not cold gas, so it costs no charge. Heavy suction
-- on the surface under the tyres: weight cancelled, pulled flat against it,
-- no bouncing off, held still when parked on a slope or wall. Driving into a
-- steeper surface the nose touches (a gutter ramp, the foot of a wall)
-- carries the car onto it the way climbing front wheels would: the speed
-- heading into it is turned up it, never added to. Off an edge, gravity is
-- back at once. Returns extra velocity, target normal, alignment gain.
local GAP = 250 -- ms a missed probe still counts as contact (seams, kerbs)
-- Landing and trick levelling: top turn rate and how quickly it gets there.
local LEVEL = { rate = math.rad(C.landing.turnRate or 80), accel = math.rad(C.landing.turnAccel or 220) }
-- Following the surface: quick enough to track a ramp, never a snap.
local FOLLOW = { rate = math.rad(C.grip.turnRate or 150), accel = math.rad(C.grip.turnAccel or 600) }
local PARKED = 4.0 -- m/s; below this with no throttle the fans hold the car still

local function driving()
    return GetControlNormal(0, 71) > 0.05 or GetControlNormal(0, 72) > 0.05
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

local function gripFrame(now, dt, frame, velocity)
    if now < grip.releaseUntil or trick or lifting() then
        grip.contact, grip.climbing = false, false
        return ZERO, nil
    end
    local vehicle, layout, cfg = ctx.vehicle, ctx.layout, C.grip
    local depth = layout.ground + 0.3 + cfg.reach
    -- Front and rear axle: across a kerb or a ramp the car follows the
    -- average of both, as its wheels would, instead of flipping between them.
    local frontHit, frontN = axle(frame, layout.thrusters[1].pos.y, depth, vehicle)
    local rearHit, rearN = axle(frame, layout.thrusters[3].pos.y, depth, vehicle)
    if not (frontHit or rearHit) then
        if now - grip.lastContact > GAP then grip.contact, grip.climbing = false, false end
        return ZERO, nil
    end
    local raw = frontHit and rearHit and unit(frontN + rearN, frontN) or frontHit and frontN or rearN
    grip.contact, grip.lastContact = true, now
    grip.n = unit(grip.n + (raw - grip.n) * math.min(1.0, dt * 10.0), raw)
    local n = grip.n
    local target = n
    local dv = (UP * GRAVITY - n * cfg.press) * dt

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
            dv = dv + P.turnOnto(velocity, wall, climb, -dot(velocity, wall) * math.min(1.0, dt * 10.0 * w))
            climbing = true
            if not grip.climbing then
                debug(('grip climb: %.0f deg steeper, %.1f m ahead, %.1f m/s'):format(
                    math.deg(math.acos(math.max(-1.0, math.min(1.0, dot(wall, n))))), #(point - from), forward))
            end
        end
    end
    grip.climbing = climbing

    -- No bouncing off: outward motion is damped, not cut, so the suspension still works.
    local away = dot(velocity, n)
    if away > 0 then dv = dv - n * (away * math.min(1.0, dt * 8.0)) end
    -- Parked on a slope or wall: holds still instead of creeping down. Never
    -- brakes a car that is driving or rolling at speed.
    if not driving() then
        local slide = velocity - n * dot(velocity, n)
        local speed = length(slide)
        if speed > 0.01 and speed < PARKED then dv = dv - slide * (math.min(speed, cfg.hold * dt) / speed) end
    end
    return dv, target, cfg.align
end

-- Landing assist: once the car has been airborne a moment, level it to the
-- ground below and, close to touchdown, fire the lift nozzles just enough to
-- arrive at a gentle sink rate. Returns extra velocity, target normal, drain.
local function landingFrame(now, dt, frame, velocity, locked)
    local cfg = C.landing
    if not (cfg.enabled and prefs.landing) or (trick and not trick.turned) or lifting() or (grip.on and grip.contact) then return ZERO, nil, 0 end
    if now - air.since < cfg.minAir * 1000 or velocity.z >= 0 then return ZERO, nil, 0 end
    local hit, point, normal = P.probe(frame.pos, frame.pos - UP * cfg.probe, ctx.vehicle)
    if not hit then return ZERO, nil, 0 end
    local height = math.max(0.0, frame.pos.z - point.z - ctx.layout.ground)
    if height / -velocity.z > cfg.lookahead then return ZERO, nil, 0 end
    air.normal = normal
    local safe = -cfg.safeSpeed
    if locked or velocity.z >= safe or height < 0.05 then return ZERO, normal, 0 end
    local need = (velocity.z * velocity.z - safe * safe) / (2.0 * height)
    local accel = math.min(need * 1.15, cfg.maxAccel)
    return UP * (accel * dt), normal, cfg.drain
end

local function frame(now, dt)
    local vehicle = ctx.vehicle
    if not NetworkHasControlOfEntity(vehicle) then
        output(grip.on and LY.GRIP or 0, now)
        return
    end
    if tricking() then readTricks(now) end

    local fr = P.frame(vehicle)
    spin = P.spinBetween(prevFrame, fr, dt)
    prevFrame = fr
    local velocity = GetEntityVelocity(vehicle)
    local dv, m, drain = ZERO, 0, 0.0
    local locked = tank.locked

    -- Grip first: it decides whether the car is on a wall this frame.
    local target, gain = nil, nil
    if grip.on then
        m = m | LY.GRIP
        local gripDv
        gripDv, target, gain = gripFrame(now, dt, fr, velocity)
        dv = dv + gripDv
    end

    -- Airborne bookkeeping and the landing assist.
    local landTarget = nil
    if air.armed then
        if IsEntityInAir(vehicle) then
            air.lastAir = now
            local landDv, landDrain
            landDv, landTarget, landDrain = landingFrame(now, dt, fr, velocity, locked)
            if landDrain > 0 then
                dv, drain, m = dv + landDv, drain + landDrain, m | LY.MASK_LIFT
            end
        elseif now - air.lastAir > 250 then
            air.armed = false
        else
            -- Just touched down: no bounce, and settle flat on the ground.
            if C.landing.enabled and prefs.landing and now - air.since >= C.landing.minAir * 1000 then
                if velocity.z > 0.5 then dv = dv - UP * (velocity.z - 0.5) end
                air.settleUntil = now + 300
            end
        end
    end

    if pendingHop then
        pendingHop = false
        local onWall = grip.contact and grip.n.z < 0.8
        local dir = onWall and grip.n or (fr.u.z > 0.3 and fr.u or UP)
        dv = dv + dir * C.lift.hop
        -- A hop always breaks the suction for a moment, wall or floor.
        if grip.contact then
            grip.releaseUntil, grip.contact, target = now + C.grip.release * 1000, false, nil
        end
    end

    if lifting() and not locked then
        drain = drain + C.lift.drain
        if dot(velocity, fr.u) < C.lift.maxRise then dv = dv + fr.u * (C.lift.accel * dt) end
        m = m | LY.MASK_LIFT
    end
    if now < hopUntil then m = m | LY.MASK_LIFT end
    if boosting() and not locked then
        drain = drain + C.boost.drain
        if dot(velocity, fr.f) < C.boost.maxSpeed then dv = dv + fr.f * (C.boost.accel * dt) end
        m = m | LY.MASK_BOOST
    end

    -- One owner for the angular velocity each frame: trick, grip, landing,
    -- settle, hover. Every automatic levelling eases in and out (LEVEL).
    if trick then
        local t = (now - trick.at) / 1000
        local plan = trick.plan
        local turnEnd = plan.rise + plan.duration
        if trick.hop > 0 then
            -- The rise: the lift nozzles push the car up evenly to the hop speed.
            local want = plan.rise > 0 and trick.hop * math.min(1.0, t / plan.rise) or trick.hop
            if velocity.z < want then dv = dv + UP * (want - velocity.z) end
            if t >= plan.rise then trick.hop = 0 end
        end
        m = m | K.mask(plan, t)
        if t < plan.rise then
            P.align(vehicle, fr, UP, C.landing.align, spin, LEVEL, dt)
        elseif t < turnEnd then
            trick.axis = trick.axis or (plan.axis == 'x' and fr.r or plan.axis == 'y' and fr.f or fr.u)
            P.setSpin(vehicle, trick.axis * K.rate(plan, t - plan.rise), fr)
        elseif t < turnEnd + C.tricks.settle then
            trick.turned = true
            P.align(vehicle, fr, landTarget or UP, C.landing.align, spin, LEVEL, dt)
        else
            trick, lastTrickEnd = nil, now
        end
    elseif target then
        P.align(vehicle, fr, target, gain, spin, FOLLOW, dt)
    elseif landTarget then
        local angle = P.align(vehicle, fr, landTarget, C.landing.align, spin, LEVEL, dt)
        if angle > 0.3 and not locked then m = m | LY.MASK_CORNER end
    elseif now < air.settleUntil then
        P.align(vehicle, fr, air.normal, C.landing.align, spin, LEVEL, dt)
    elseif lifting() and not locked and not IsVehicleOnAllWheels(vehicle) then
        P.align(vehicle, fr, UP, C.lift.level, spin, LEVEL, dt)
    end

    setDrain(drain, now)
    if tank.locked and not locked then m = m & LY.GRIP end

    if dv.x ~= 0 or dv.y ~= 0 or dv.z ~= 0 then
        local v = velocity + dv
        SetEntityVelocity(vehicle, v.x + 0.0, v.y + 0.0, v.z + 0.0)
    end

    output(grip.on and (m | LY.GRIP) or (m & ~LY.GRIP), now)
    hud(now)
end

local function busy(now)
    return ctx.active and (lifting() or boosting() or tricking() or trick ~= nil or grip.on or pendingHop
        or air.armed or now < air.settleUntil or now < hopUntil or mask ~= 0 or sent ~= mask)
end

local function ensureFrame()
    if running or not ctx.active then return end
    running = true
    CreateThread(function()
        prevFrame = nil
        while not stopped and busy(GetGameTimer()) do
            Wait(0)
            if not ctx.active then break end
            frame(GetGameTimer(), math.min(0.05, GetFrameTime()))
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
    grip.on, grip.contact = false, false
    air.armed, air.settleUntil = false, 0
    setDrain(0, now)
end

local function leave()
    local now = GetGameTimer()
    local vehicle = ctx.vehicle
    reset(now)
    mask = 0
    if vehicle ~= 0 and DoesEntityExist(vehicle) then F.set(vehicle, 0, false) end
    send(now, true)
    ctx.active, ctx.vehicle, ctx.netId, ctx.layout = false, 0, 0, nil
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
    if tank.locked or not T.can(tank, now, C.lift.hopCost) then refused(now); ensureFrame(); return end
    if spend(C.lift.hopCost, now) then pendingHop, hopUntil = true, now + 250 end
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
