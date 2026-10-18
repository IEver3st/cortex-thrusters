-- Vector maths and the forces the kit puts on the car. Linear effects change
-- the velocity directly (mass independent, so a bus and a supercar feel the
-- same); turning sets the angular velocity. Everything is in world space.
ThrusterPhysics = {}
local P, C = ThrusterPhysics, Config
local GRAVITY = 9.81
local UP = vector3(0.0, 0.0, 1.0)
local ZERO = vector3(0.0, 0.0, 0.0)

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
P.dot, P.cross, P.length, P.unit, P.UP, P.ZERO, P.GRAVITY = dot, cross, length, unit, UP, ZERO, GRAVITY

-- Position and orientation: forward, up, right. GetEntityMatrix is avoided
-- (unreliable under fxv2 oal); two offsets give the same axes.
function P.frame(vehicle)
    local pos = GetEntityCoords(vehicle)
    local forward = unit(GetOffsetFromEntityInWorldCoords(vehicle, 0.0, 1.0, 0.0) - pos)
    local up = unit(GetOffsetFromEntityInWorldCoords(vehicle, 0.0, 0.0, 1.0) - pos)
    return { pos = pos, f = forward, u = up, r = cross(forward, up) }
end

-- Angular velocity measured from how the axes turned since the last frame:
-- for a small rotation, sum(e x e') = 2w.
function P.spinBetween(a, b, dt)
    if not a or dt <= 0 then return ZERO end
    return (cross(a.f, b.f) + cross(a.u, b.u) + cross(a.r, b.r)) / (2.0 * dt)
end

function P.setSpin(vehicle, w, frame)
    if C.angularSpace == 'local' then
        SetEntityAngularVelocity(vehicle, dot(w, frame.r) + 0.0, dot(w, frame.f) + 0.0, dot(w, frame.u) + 0.0)
    else
        SetEntityAngularVelocity(vehicle, w.x + 0.0, w.y + 0.0, w.z + 0.0)
    end
end

-- Turns the car's up toward `target` at `gain` per second while keeping its
-- spin about `target` (steering on a wall still turns the car). With
-- `limits` ({ rate, accel } in rad/s and rad/s^2, plus the frame's `dt`) the
-- turn eases in and out instead of snapping: it never turns faster than
-- `rate`, slows in time to stop on the target, and changes the car's spin by
-- at most `accel` per second. Returns the remaining angle in radians.
function P.align(vehicle, frame, target, gain, spin, limits, dt)
    local c = dot(frame.u, target)
    local angle = math.acos(math.max(-1.0, math.min(1.0, c)))
    local axis = cross(frame.u, target)
    if length(axis) < 1e-4 then
        -- Upright already, or exactly upside down: any horizontal axis works.
        axis = angle > 1.0 and frame.f or ZERO
    end
    spin = spin or ZERO
    local keep = target * dot(spin, target)
    local speed = angle * gain
    if limits then speed = math.min(speed, limits.rate, math.sqrt(2.0 * limits.accel * angle)) end
    local want = keep + unit(axis, ZERO) * speed
    if limits and dt then
        local change = want - spin
        local size, step = length(change), limits.accel * dt
        if size > step then want = spin + change * (step / size) end
    end
    P.setSpin(vehicle, want, frame)
    return angle
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

-- One synchronous probe against the map and objects. Returns hit, point,
-- normal. One runs per frame only while grip holds a surface.
function P.probe(from, to, ignore)
    local handle = StartExpensiveSynchronousShapeTestLosProbe(from.x, from.y, from.z, to.x, to.y, to.z, 1 | 16, ignore, 7)
    local _, hit, point, normal = GetShapeTestResult(handle)
    if hit == 1 or hit == true then return true, point, unit(normal) end
    return false
end
