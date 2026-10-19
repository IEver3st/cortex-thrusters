-- Vector maths and the forces the kit puts on the car. Nothing here sets the
-- car's speed, spin or position: every effect is an impulse from a nozzle or
-- a grip fan, at the spot it sits on the car, handed to the game's physics.
-- Thrust is in m/s^2 and scaled by the vehicle's mass, so every car gets the
-- same push; how it turns comes from its own shape and weight.
ThrusterPhysics = {}
local P = ThrusterPhysics
local GRAVITY = 9.81
local UP = vector3(0.0, 0.0, 1.0)
local ZERO = vector3(0.0, 0.0, 0.0)
-- APPLY_TYPE_IMPULSE: applied once per frame as accel * dt it adds up to a
-- steady force at any frame rate.
local IMPULSE = 1

local function dot(a, b) return a.x * b.x + a.y * b.y + a.z * b.z end
local function cross(a, b)
    return vector3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
end
local function length(a) return math.sqrt(dot(a, a)) end
local function unit(a, fallback)
    local l = length(a)
    if l < 1e-6 then return fallback or UP end
    return a / l
end
local function clamp(x, lo, hi) if x < lo then return lo elseif x > hi then return hi end return x end
P.dot, P.cross, P.length, P.unit, P.clamp, P.UP, P.ZERO, P.GRAVITY = dot, cross, length, unit, clamp, UP, ZERO, GRAVITY

-- Position and orientation: forward, up, right. GetEntityMatrix is avoided
-- (unreliable under fxv2 oal); two offsets give the same axes.
function P.frame(vehicle)
    local pos = GetEntityCoords(vehicle)
    local forward = unit(GetOffsetFromEntityInWorldCoords(vehicle, 0.0, 1.0, 0.0) - pos)
    local up = unit(GetOffsetFromEntityInWorldCoords(vehicle, 0.0, 0.0, 1.0) - pos)
    return { pos = pos, f = forward, u = up, r = cross(forward, up) }
end

-- World vector to the car's frame (x right, y forward, z up) and back.
function P.toBody(frame, w) return vector3(dot(w, frame.r), dot(w, frame.f), dot(w, frame.u)) end
function P.toWorld(frame, b) return frame.r * b.x + frame.f * b.y + frame.u * b.z end

-- Angular velocity measured from how the axes turned since the last frame:
-- for a small rotation, sum(e x e') = 2w.
function P.spinBetween(a, b, dt)
    if not a or dt <= 0 then return ZERO end
    return (cross(a.f, b.f) + cross(a.u, b.u) + cross(a.r, b.r)) / (2.0 * dt)
end

-- The angular acceleration (world, rad/s^2) that turns the car's up toward
-- `target` while keeping its spin about `target` (steering still turns it).
-- The wanted turn rate is `angle * gain`, never above `limits.rate` and
-- slowing in time to stop on the target (`limits.accel`); the RCS closes
-- the gap to it at `limits.response` per second, never harder than
-- `limits.accel`. Returns the acceleration and the remaining angle.
function P.align(frame, target, gain, spin, limits)
    local c = dot(frame.u, target)
    local angle = math.acos(clamp(c, -1.0, 1.0))
    local axis = cross(frame.u, target)
    if length(axis) < 1e-4 then
        -- Upright already, or exactly upside down: any horizontal axis works.
        axis = angle > 1.0 and frame.f or ZERO
    end
    spin = spin or ZERO
    local speed = math.min(angle * gain, limits.rate, math.sqrt(2.0 * limits.accel * angle))
    local want = target * dot(spin, target) + unit(axis, ZERO) * speed
    local accel = (want - spin) * (limits.response or 8.0)
    local size = length(accel)
    if size > limits.accel then accel = accel * (limits.accel / size) end
    return accel, angle
end

-- Turns `share` m/s of the motion heading into a surface (normal `wall`)
-- toward `climb` (along that surface) without changing the speed: what the
-- front wheels do when they meet a ramp. Never adds speed. Returns the
-- velocity change.
function P.turnOnto(v, wall, climb, share)
    local into = -dot(v, wall)
    if into <= 0 or share <= 0 then return ZERO end
    local along = dot(v, climb)
    local left = math.max(0.0, into - share)
    local turned = math.sqrt(math.max(0.0, into * into + along * along - left * left))
    if along < 0 then turned = -turned end
    return wall * (into - left) + climb * (turned - along)
end

-- Thrust allocation -------------------------------------------------------------

-- What each nozzle can do, in the car's frame: the way it pushes the car
-- (opposite to its jet) and the angular acceleration one m/s^2 of it causes
-- about the model origin. Inertia per unit mass is a solid box of the
-- model's size; the game's real inertia differs a little and the feedback
-- loops absorb it. Built once per layout.
function P.model(layout)
    local w, l, h = layout.halfWidth * 2, layout.halfLength * 2, layout.height
    local inertia = { x = (l * l + h * h) / 12, y = (w * w + h * h) / 12, z = (w * w + l * l) / 12 }
    local cols, pushes, groups, fans = {}, {}, {}, { x2 = 0.0, y2 = 0.0 }
    for i, thruster in ipairs(layout.thrusters) do
        local p, d = thruster.pos, thruster.dir
        local push = vector3(-d.x + 0.0, -d.y + 0.0, -d.z + 0.0)
        local torque = cross(vector3(p.x, p.y, p.z), push)
        cols[i] = { push.x, push.y, push.z, torque.x / inertia.x, torque.y / inertia.y, torque.z / inertia.z }
        pushes[i], groups[i] = push, thruster.group
        if i <= 4 then fans.x2, fans.y2 = fans.x2 + p.x * p.x, fans.y2 + p.y * p.y end
    end
    local front = layout.thrusters[1].pos.y
    return { cols = cols, push = pushes, groups = groups, count = #cols, inertia = inertia, fans = fans, layout = layout,
        front = vector3(0.0, front + 0.0, 0.0) }
end

-- Throttles every nozzle (m/s^2 each, 0..limit[i]) so that together they
-- give the wanted push and turn: want[1..3] force and want[4..6] angular
-- acceleration in the car's frame, weight[k] how much each matters. Box
-- constrained least squares by coordinate descent, warm started from last
-- frame's `throttle` (updated in place), plus a small fuel cost so idle
-- nozzles stay off and a spread cost so matching nozzles share the load
-- (a hover fires all four lift nozzles, not one diagonal pair). Allocation
-- free.
local FUEL, SPREAD = 0.02, 0.25
function P.allocate(model, want, weight, limit, throttle, sweeps)
    local cols, n = model.cols, model.count
    local r1, r2, r3, r4, r5, r6 = -want[1], -want[2], -want[3], -want[4], -want[5], -want[6]
    for i = 1, n do
        local t = throttle[i]
        if t > limit[i] then t = limit[i]; throttle[i] = t end
        if t ~= 0 then
            local c = cols[i]
            r1, r2, r3 = r1 + c[1] * t, r2 + c[2] * t, r3 + c[3] * t
            r4, r5, r6 = r4 + c[4] * t, r5 + c[5] * t, r6 + c[6] * t
        end
    end
    local w1, w2, w3, w4, w5, w6 = weight[1], weight[2], weight[3], weight[4], weight[5], weight[6]
    for _ = 1, sweeps or 6 do
        for i = 1, n do
            local c, max, t = cols[i], limit[i], throttle[i]
            local g = FUEL + SPREAD * t + w1 * c[1] * r1 + w2 * c[2] * r2 + w3 * c[3] * r3 + w4 * c[4] * r4 + w5 * c[5] * r5 + w6 * c[6] * r6
            local h = 1e-6 + SPREAD + w1 * c[1] * c[1] + w2 * c[2] * c[2] + w3 * c[3] * c[3] + w4 * c[4] * c[4] + w5 * c[5] * c[5] + w6 * c[6] * c[6]
            local nt = clamp(t - g / h, 0.0, max)
            if nt ~= t then
                local d = nt - t
                r1, r2, r3 = r1 + c[1] * d, r2 + c[2] * d, r3 + c[3] * d
                r4, r5, r6 = r4 + c[4] * d, r5 + c[5] * d, r6 + c[6] * d
                throttle[i] = nt
            end
        end
    end
    return throttle
end

-- Grip fans sit where the four lift nozzles are and pull the car toward its
-- underside. A shared `pull` (m/s^2 in total) holds it on the surface; more
-- pull on one side turns it, the way the car levels onto the surface.
-- `alpha` is the wanted angular acceleration in the car's frame (only roll
-- and pitch: fans cannot yaw). Fills `out[1..4]` and returns it.
function P.fans(model, pull, alpha, max, out)
    local thrusters, inertia, fans = model.layout.thrusters, model.inertia, model.fans
    local roll = fans.x2 > 1e-6 and inertia.y * alpha.y / fans.x2 or 0.0
    local pitch = fans.y2 > 1e-6 and inertia.x * alpha.x / fans.y2 or 0.0
    for i = 1, 4 do
        local p = thrusters[i].pos
        out[i] = clamp(pull * 0.25 + roll * p.x - pitch * p.y, 0.0, max)
    end
    return out
end

-- Applying forces ---------------------------------------------------------------

-- `accel` m/s^2 along a direction in the car's frame, at a local offset.
function P.push(vehicle, dir, accel, offset, dt)
    local s = accel * dt
    ApplyForceToEntity(vehicle, IMPULSE, dir.x * s + 0.0, dir.y * s + 0.0, dir.z * s + 0.0,
        offset.x + 0.0, offset.y + 0.0, offset.z + 0.0, 0, true, true, true, false, true)
end

-- A world-space acceleration at a local offset.
function P.pushWorldAt(vehicle, accel, offset, dt)
    ApplyForceToEntity(vehicle, IMPULSE, accel.x * dt + 0.0, accel.y * dt + 0.0, accel.z * dt + 0.0,
        offset.x + 0.0, offset.y + 0.0, offset.z + 0.0, 0, false, true, true, false, true)
end

-- A world-space acceleration through the centre of mass: no turning.
function P.pushWorld(vehicle, accel, dt)
    ApplyForceToEntityCenterOfMass(vehicle, IMPULSE, accel.x * dt + 0.0, accel.y * dt + 0.0, accel.z * dt + 0.0,
        0, false, true, false)
end

-- One synchronous probe against the map and objects. Returns hit, point,
-- normal.
function P.probe(from, to, ignore)
    local handle = StartExpensiveSynchronousShapeTestLosProbe(from.x, from.y, from.z, to.x, to.y, to.z, 1 | 16, ignore, 7)
    local _, hit, point, normal = GetShapeTestResult(handle)
    if hit == 1 or hit == true then return true, point, unit(normal) end
    return false
end
