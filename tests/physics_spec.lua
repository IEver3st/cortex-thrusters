-- lua tests/physics_spec.lua (from the resource root)
-- Levelling: the eased turn never snaps, never exceeds its rate and stops
-- on the target; without limits it keeps the old proportional behaviour.
os = nil
local checks = 0
local function ok(cond, what) assert(cond, what); checks = checks + 1 end

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

local set
function SetEntityAngularVelocity(_, x, y, z) set = vector3(x, y, z) end
Config = { angularSpace = 'world' }
dofile('client/physics.lua')
local P = ThrusterPhysics

local function rotate(v, w, dt) -- small rotation of v by angular velocity w
    local c = vector3(w.y * v.z - w.z * v.y, w.z * v.x - w.x * v.z, w.x * v.y - w.y * v.x)
    local r = v + c * dt
    return r / #r
end

-- A car rolled 90 degrees onto its side, levelling to up at 60 fps.
local up = vector3(0.0, 0.0, 1.0)
local frame = { f = vector3(0.0, 1.0, 0.0), u = vector3(1.0, 0.0, 0.0), r = vector3(0.0, 0.0, -1.0) }
local limits = { rate = math.rad(80), accel = math.rad(220) }
local spin, dt, peak, biggestChange = vector3(0.0, 0.0, 0.0), 1 / 60, 0, 0
local angle
for _ = 1, 600 do
    angle = P.align(0, frame, up, 2.0, spin, limits, dt)
    biggestChange = math.max(biggestChange, #(set - spin))
    peak = math.max(peak, #set)
    spin = set
    frame = { f = rotate(frame.f, spin, dt), u = rotate(frame.u, spin, dt), r = rotate(frame.r, spin, dt) }
end
ok(peak <= limits.rate + 1e-9, 'never turns faster than the rate')
ok(biggestChange <= limits.accel * dt + 1e-9, 'never changes spin faster than accel')
ok(angle < math.rad(1), 'ends level: ' .. math.deg(angle))

-- First frame from rest: the old version jumped straight to angle * gain.
P.align(0, { f = vector3(0.0, 1.0, 0.0), u = vector3(1.0, 0.0, 0.0), r = vector3(0.0, 0.0, -1.0) }, up, 2.0, vector3(0.0, 0.0, 0.0), limits, dt)
ok(#set <= limits.accel * dt + 1e-9, 'eases in from rest')
P.align(0, { f = vector3(0.0, 1.0, 0.0), u = vector3(1.0, 0.0, 0.0), r = vector3(0.0, 0.0, -1.0) }, up, 2.0, vector3(0.0, 0.0, 0.0))
ok(math.abs(#set - math.pi / 2 * 2.0) < 1e-9, 'without limits it stays proportional (grip)')

-- Climbing: speed heading into a surface turns up it, never more.
local wall, climb = vector3(-1.0, 0.0, 0.0), vector3(0.0, 0.0, 1.0) -- wall ahead (+x), up the wall
local v = vector3(6.0, 2.0, 0.0)                                      -- 6 m/s into it, 2 along it
local dv = P.turnOnto(v, wall, climb, 2.0)
local after = v + dv
ok(math.abs(#after - #v) < 1e-9, 'speed unchanged')
ok(math.abs(after.x - 4.0) < 1e-9, 'into the wall drops by the share')
ok(after.z > 0 and math.abs(after.y - 2.0) < 1e-9, 'turned up the wall, sideways motion kept')
local all = v + P.turnOnto(v, wall, climb, 100.0)
ok(math.abs(all.x) < 1e-9 and math.abs(#all - #v) < 1e-9, 'never past the surface, never faster')
ok(#P.turnOnto(vector3(-3.0, 0.0, 0.0), wall, climb, 2.0) == 0, 'moving away from it: nothing')

print(('physics_spec: %d checks passed'):format(checks))
