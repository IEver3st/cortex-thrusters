-- lua tests/physics_spec.lua (from the resource root)
-- The force path: levelling chases a wanted turn rate without snapping, the
-- allocator throttles the right nozzles for each push and turn, the fans
-- lay the car flat, impulses reach the native scaled by dt, and no client
-- code sets speed, spin or position directly.
os = nil
local checks = 0
local function ok(cond, what) assert(cond, what); checks = checks + 1 end
local function near(a, b, eps) return math.abs(a - b) <= (eps or 1e-6) end

-- vector3 double with the arithmetic CfxLua provides.
local V = {}
V.__index = V
function vector3(x, y, z) return setmetatable({ x = x, y = y, z = z }, V) end
V.__add = function(a, b) return vector3(a.x + b.x, a.y + b.y, a.z + b.z) end
V.__sub = function(a, b) return vector3(a.x - b.x, a.y - b.y, a.z - b.z) end
V.__unm = function(a) return vector3(-a.x, -a.y, -a.z) end
V.__mul = function(a, b)
    if type(a) == 'number' then a, b = b, a end
    return vector3(a.x * b, a.y * b, a.z * b)
end
V.__div = function(a, b) return vector3(a.x / b, a.y / b, a.z / b) end
V.__len = function(a) return math.sqrt(a.x * a.x + a.y * a.y + a.z * a.z) end

local calls = {}
function ApplyForceToEntity(...) calls[#calls + 1] = { 'offset', ... } end
function ApplyForceToEntityCenterOfMass(...) calls[#calls + 1] = { 'com', ... } end
Config = {}
dofile('shared/layout.lua')
dofile('client/physics.lua')
local P, L = ThrusterPhysics, ThrusterLayout
local dot, cross = P.dot, P.cross

local function rotate(v, w, dt) -- small rotation of v by angular velocity w
    local r = v + cross(w, v) * dt
    return r / #r
end
local function turn(frame, w, dt)
    local f, u = rotate(frame.f, w, dt), rotate(frame.u, w, dt)
    u = P.unit(u - f * dot(u, f))
    return { pos = frame.pos, f = f, u = u, r = cross(f, u) }
end

-- Levelling ---------------------------------------------------------------------

-- A car rolled 90 degrees onto its side, levelling to up at 60 fps as a
-- free rigid body: the RCS only ever gives it an angular acceleration.
local up = vector3(0.0, 0.0, 1.0)
local limits = { rate = math.rad(80), accel = math.rad(220), response = 8.0 }
local frame = { pos = up, f = vector3(0.0, 1.0, 0.0), u = vector3(1.0, 0.0, 0.0), r = vector3(0.0, 0.0, -1.0) }
local spin, dt, peak, biggest = vector3(0.0, 0.0, 0.0), 1 / 60, 0, 0
local angle, alpha
for _ = 1, 600 do
    alpha, angle = P.align(frame, up, 2.0, spin, limits)
    biggest = math.max(biggest, #alpha)
    spin = spin + alpha * dt
    peak = math.max(peak, #spin)
    frame = turn(frame, spin, dt)
end
ok(biggest <= limits.accel + 1e-9, 'never asks for more than accel')
ok(peak <= limits.rate * 1.02, 'never turns much faster than the rate: ' .. math.deg(peak))
ok(angle < math.rad(1), 'ends level: ' .. math.deg(angle))
ok(#spin < 0.05, 'and at rest')

local side = { pos = up, f = vector3(0.0, 1.0, 0.0), u = vector3(1.0, 0.0, 0.0), r = vector3(0.0, 0.0, -1.0) }
alpha = P.align(side, up, 2.0, vector3(0.0, 0.0, 0.0), limits)
ok(#alpha <= limits.accel + 1e-9 and #alpha > 0, 'eases in from rest')
ok(dot(P.cross(side.u, up), alpha) > 0, 'turns toward the target')
local yawing = up * 1.5 -- spinning about the target (steering)
alpha = P.align({ pos = up, f = vector3(0.0, 1.0, 0.0), u = up, r = vector3(1.0, 0.0, 0.0) }, up, 2.0, yawing, limits)
ok(#alpha < 1e-9, 'level and steering: spin about the target is kept')

-- Climbing --------------------------------------------------------------------

local wall, climb = vector3(-1.0, 0.0, 0.0), vector3(0.0, 0.0, 1.0) -- wall ahead (+x), up the wall
local v = vector3(6.0, 2.0, 0.0)                                      -- 6 m/s into it, 2 along it
local after = v + P.turnOnto(v, wall, climb, 2.0)
ok(near(#after, #v, 1e-9), 'speed unchanged')
ok(near(after.x, 4.0, 1e-9), 'into the wall drops by the share')
ok(after.z > 0 and near(after.y, 2.0, 1e-9), 'turned up the wall, sideways motion kept')
local all = v + P.turnOnto(v, wall, climb, 100.0)
ok(math.abs(all.x) < 1e-9 and near(#all, #v, 1e-9), 'never past the surface, never faster')
ok(#P.turnOnto(vector3(-3.0, 0.0, 0.0), wall, climb, 2.0) == 0, 'moving away from it: nothing')

-- Allocation --------------------------------------------------------------------

local layout = L.build({ x = -1.0, y = -2.3, z = -0.6 }, { x = 1.0, y = 2.3, z = 0.8 }, {})
local model = P.model(layout)
local NOZZLE = { lift = 6.0, boost = 3.0, corner = 6.0 }
local function limitsFor(scale)
    local out = {}
    for i = 1, model.count do out[i] = NOZZLE[model.groups[i]] * (scale or 1) end
    return out
end
local function zeros() local t = {} for i = 1, model.count do t[i] = 0.0 end return t end
local function achieved(t)
    local out = { 0, 0, 0, 0, 0, 0 }
    for i = 1, model.count do
        for k = 1, 6 do out[k] = out[k] + model.cols[i][k] * t[i] end
    end
    return out
end
local function sum(t, from, to) local s = 0 for i = from, to do s = s + t[i] end return s end
local function solve(want, weight, lim, sweeps)
    local t = zeros()
    for _ = 1, 10 do P.allocate(model, want, weight, lim or limitsFor(), t, sweeps or 6) end -- ten frames, warm started
    return t
end

-- Hover: 15 m/s^2 up, no turn.
local t = solve({ 0, 0, 15, 0, 0, 0 }, { 1, 1, 10, 4, 4, 4 })
local got = achieved(t)
ok(near(got[3], 15, 0.3), 'hover gives the asked lift, less a sliver for sharing: ' .. got[3])
ok(near(sum(t, 1, 4), 15, 0.3) and sum(t, 5, 12) < 0.05, 'hover uses the lift nozzles only')
ok(math.abs(got[4]) < 0.05 and math.abs(got[5]) < 0.05 and math.abs(got[6]) < 0.05, 'hover adds no turn')
for i = 1, 4 do ok(math.abs(t[i] - 3.75) < 0.4, 'hover shares the load across all four lift nozzles: ' .. t[i]) end

-- Boost: forward, evenly across the rear so it doesn't yaw.
t = solve({ 0, 10, 0, 0, 0, 0 }, { 1, 10, 0.25, 0, 0, 4 })
got = achieved(t)
ok(near(got[2], 10, 0.3), 'boost gives the asked push: ' .. got[2])
ok(math.abs(got[6]) < 0.05, 'boost adds no yaw')
for i = 5, 8 do ok(t[i] <= 3.0 + 1e-9, 'boost nozzle within its limit') end

-- Roll right in the air: the left lift nozzles kick it (as the trick plan says).
t = solve({ 0, 0, 0, 0, 5, 0 }, { 1, 1, 0.25, 4, 4, 4 })
ok(t[1] + t[3] > t[2] + t[4] + 1, 'roll right fires the left lift nozzles')
ok(achieved(t)[5] > 4.5, 'and turns the right way: ' .. achieved(t)[5])
-- Flip forward (nose down, -x): the rear lift nozzles.
t = solve({ 0, 0, 0, -5, 0, 0 }, { 1, 1, 0.25, 4, 4, 4 })
ok(t[3] + t[4] > t[1] + t[2] + 1, 'nose down fires the rear lift nozzles')
-- Spin left (+z): the corner nozzles, without drifting sideways.
t = solve({ 0, 0, 0, 0, 0, 5 }, { 1, 1, 0.25, 4, 4, 4 })
got = achieved(t)
ok(got[6] > 4.5 and math.abs(got[1]) < 0.3, 'spins on the corner nozzles without drifting: ' .. got[6])

-- On its left side (world up is the car's right): the left corner nozzles
-- face the ground and push it up; the lift nozzles can't.
t = solve({ 9.81 * 1.15, 0, 0, 0, 0, 0 }, { 3, 3, 3, 4, 4, 4 }, limitsFor(2.5))
ok(near(achieved(t)[1], 9.81 * 1.15, 0.5), 'pushes off the ground on its side')
ok(t[9] > 0 and t[11] > 0 and t[10] < 0.05 and t[12] < 0.05, 'with the corner nozzles facing the ground')

-- Locked tank: no nozzle may fire.
local lim0 = {} for i = 1, model.count do lim0[i] = 0.0 end
t = zeros(); t[1] = 4.0
P.allocate(model, { 0, 0, 15, 0, 0, 0 }, { 1, 1, 10, 4, 4, 4 }, lim0, t, 6)
ok(sum(t, 1, 12) == 0, 'nothing fires with every limit at zero')
-- Asked for more than the nozzles have: saturates, never past the limit.
t = solve({ 0, 0, 100, 0, 0, 0 }, { 1, 1, 10, 4, 4, 4 })
for i = 1, 4 do ok(near(t[i], 6.0, 1e-9), 'saturated lift nozzle at its limit') end

-- Closed loop: a car hovering 30 degrees rolled, as a free rigid body. The
-- RCS holds its height on the lift nozzles and levels it with the same
-- nozzles; only forces at the nozzles move it.
do
    local inertia = model.inertia
    local f = vector3(0.0, 1.0, 0.0)
    local u = P.unit(vector3(math.sin(math.rad(30)), 0.0, math.cos(math.rad(30))))
    local fr = { pos = vector3(0, 0, 10), f = f, u = u, r = cross(f, u) }
    local vel, w, th = vector3(0, 0, 0), vector3(0, 0, 0), zeros()
    local want, weight, lim = { 0, 0, 0, 0, 0, 0 }, { 1, 1, 10, 4, 4, 4 }, limitsFor()
    local hover = { rate = math.rad(80), accel = math.rad(220), response = 8.0 }
    local lowest = 10
    for _ = 1, 300 do
        local a = P.align(fr, up, 2.5, w, hover)
        local b = P.toBody(fr, a)
        want[3] = 9.81 / math.max(fr.u.z, 0.5) - vel.z * 2.0
        want[4], want[5], want[6] = b.x, b.y, b.z
        P.allocate(model, want, weight, lim, th, 6)
        local got6 = achieved(th)
        local accel = P.toWorld(fr, vector3(got6[1], got6[2], got6[3])) - up * 9.81
        vel = vel + accel * dt
        fr.pos = fr.pos + vel * dt
        w = w + P.toWorld(fr, vector3(got6[4], got6[5], got6[6])) * dt
        fr = turn(fr, w, dt)
        lowest = math.min(lowest, fr.pos.z)
    end
    ok(fr.u.z > math.cos(math.rad(2)), 'hovering car levels itself: ' .. math.deg(math.acos(fr.u.z)))
    ok(fr.pos.z > 9.0 and lowest > 8.5, 'and holds its height: ' .. fr.pos.z)
end

-- Fans --------------------------------------------------------------------------

local fans = P.fans(model, 13.0, vector3(0, 0, 0), 26.0, {})
ok(near(fans[1] + fans[2] + fans[3] + fans[4], 13.0), 'fans share the pull')
fans = P.fans(model, 13.0, vector3(0, 3.0, 0), 26.0, {})
ok(fans[2] + fans[4] > fans[1] + fans[3], 'roll right: the right fans pull harder')
fans = P.fans(model, 13.0, vector3(-3.0, 0, 0), 26.0, {})
ok(fans[1] + fans[2] > fans[3] + fans[4], 'nose down: the front fans pull harder')
fans = P.fans(model, 2.0, vector3(0, 50.0, 0), 26.0, {})
for i = 1, 4 do ok(fans[i] >= 0, 'a fan never pushes') end

-- Natives -----------------------------------------------------------------------

calls = {}
P.push(7, vector3(0.0, 0.0, 1.0), 12.0, vector3(0.5, 1.2, -0.3), 0.02)
local c = calls[1]
ok(c[1] == 'offset' and c[2] == 7 and c[3] == 1, 'nozzle push is an impulse on the vehicle')
ok(near(c[6], 12.0 * 0.02) and c[4] == 0 and c[5] == 0, 'scaled by the frame time')
ok(near(c[7], 0.5) and near(c[8], 1.2) and near(c[9], -0.3), 'at the nozzle')
ok(c[11] == true and c[12] == true and c[13] == true, 'local push, local offset, scaled by mass')
P.pushWorld(7, vector3(0.0, 0.0, 9.81), 0.02)
c = calls[2]
ok(c[1] == 'com' and c[3] == 1 and near(c[6], 9.81 * 0.02) and c[8] == false and c[9] == true, 'world push through the centre of mass, scaled by mass')

-- No scripted motion: nothing on the client sets speed, spin or position.
for _, file in ipairs({ 'client/main.lua', 'client/physics.lua', 'client/install.lua', 'client/remote.lua', 'client/vfx.lua' }) do
    local handle = assert(io.open(file, 'r'))
    local source = handle:read('a')
    handle:close()
    for _, native in ipairs({ 'SetEntityVelocity', 'SetEntityAngularVelocity', 'SetEntityCoords', 'SetEntityRotation',
        'SetEntityHeading', 'SetVehicleForwardSpeed', 'SetEntityQuaternion', 'SetVehicleOnGroundProperly' }) do
        ok(not source:find(native, 1, true), file .. ' does not call ' .. native)
    end
end

print(('physics_spec: %d checks passed'):format(checks))
