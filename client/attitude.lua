-- Debug attitude overlay (Config.debug, /thrusters_attitude): the roll and
-- yaw of the fitted vehicle you drive, drawn in the world around it every
-- frame so the rings stay locked to the car, with Cortex slip tags in the NUI
-- riding on them.
--   Roll: a ring around the car's forward axis. Paper ticks mark the horizon,
--         accent ticks the car's right side, the accent wedge the bank
--         between them: how far the right side dips below the horizon. A
--         clean front flip keeps it at 0 the whole way round.
--   Yaw:  a flat ring around the car. The accent tick is the nose, the paper
--         tick the heading the last trick started at (or when the overlay was
--         turned on, or `/thrusters_attitude reset`), the wedge the turn since.
-- Strokes are camera-facing ribbons a few pixels wide with an ink edge, so
-- they read against a bright sky (CORTEX-DESIGN Law 4).
if not Config.debug then return end

local P = ThrusterPhysics
local UP, dot, cross, length, unit = P.UP, P.dot, P.cross, P.length, P.unit
local SEGMENTS = 36
local PAPER, INK = { 240, 240, 233 }, { 15, 16, 18 }
local accent = { 143, 203, 191 } -- the shared accent's fallback until cortex-lib answers
local on, reference, lastTrick, tagsAt, shown = false, nil, nil, 0, false
local prev, dims = nil, {}

-- The player's shared accent (Cortex settings), for the native strokes.
local function readAccent()
    local ok, data = pcall(function() return exports['cortex-lib']:getPresentation() end)
    local hex = ok and type(data) == 'table' and type(data.profile) == 'table' and data.profile.accent
    if type(hex) == 'string' and hex:match('^#%x%x%x%x%x%x$') then
        accent = { tonumber(hex:sub(2, 3), 16), tonumber(hex:sub(4, 5), 16), tonumber(hex:sub(6, 7), 16) }
    end
end
AddEventHandler('cortex-lib:presentation', readAccent)

-- Two windings: DrawPoly is single-sided and a billboard's facing depends on the segment direction.
local function quad(a, b, c, d, color, alpha)
    local r, g, bl = color[1], color[2], color[3]
    DrawPoly(a.x, a.y, a.z, b.x, b.y, b.z, c.x, c.y, c.z, r, g, bl, alpha)
    DrawPoly(c.x, c.y, c.z, b.x, b.y, b.z, a.x, a.y, a.z, r, g, bl, alpha)
    DrawPoly(a.x, a.y, a.z, c.x, c.y, c.z, d.x, d.y, d.z, r, g, bl, alpha)
    DrawPoly(d.x, d.y, d.z, c.x, c.y, c.z, a.x, a.y, a.z, r, g, bl, alpha)
end

-- A thick segment that always faces the camera, `width` metres wide.
local function ribbon(a, b, eye, width, color, alpha)
    local side = cross(b - a, eye - (a + b) * 0.5)
    local size = length(side)
    if size < 1e-6 then return end
    side = side * (width * 0.5 / size)
    quad(a + side, b + side, b - side, a - side, color, alpha)
end

-- A stroke `width` pixels wide over a slightly wider ink edge. The colour
-- sits a centimetre nearer the camera so the two never fight for depth.
local function stroke(a, b, eye, pixel, width, color, alpha)
    ribbon(a, b, eye, (width + 2.0) * pixel, INK, math.floor(alpha * 0.6))
    local na, nb = a + unit(eye - a) * 0.01, b + unit(eye - b) * 0.01
    ribbon(na, nb, eye, width * pixel, color, alpha)
end

-- A ring in the plane of `u` and `v`; the half facing away from the camera is
-- drawn faint so the near side reads first.
local function ring(centre, u, v, radius, eye, pixel)
    local view = unit(eye - centre)
    local last = centre + u * radius
    for i = 1, SEGMENTS do
        local t = i / SEGMENTS * math.pi * 2
        local point = centre + u * (radius * math.cos(t)) + v * (radius * math.sin(t))
        local far = dot(unit((last + point) * 0.5 - centre), view) < -0.08
        stroke(last, point, eye, pixel, 4.0, PAPER, far and 70 or 200)
        last = point
    end
end

-- A radial tick across the ring at direction `dir`.
local function tick(centre, dir, inner, outer, eye, pixel, width, color)
    stroke(centre + dir * inner, centre + dir * outer, eye, pixel, width, color, 255)
end

-- A filled wedge from direction `from` turning `angle` radians about `axis`.
local function wedge(centre, from, axis, angle, radius, color)
    local side = cross(axis, from)
    local steps = math.max(1, math.min(36, math.floor(math.abs(angle) / math.rad(5)) + 1))
    local r, g, b = color[1], color[2], color[3]
    local last = centre + from * radius
    for i = 1, steps do
        local t = angle * i / steps
        local point = centre + (from * math.cos(t) + side * math.sin(t)) * radius
        DrawPoly(centre.x, centre.y, centre.z, last.x, last.y, last.z, point.x, point.y, point.z, r, g, b, 70)
        DrawPoly(point.x, point.y, point.z, last.x, last.y, last.z, centre.x, centre.y, centre.z, r, g, b, 70)
        last = point
    end
end

local function heading(dir) return (math.deg(math.atan(-dir.x, dir.y)) + 360.0) % 360.0 end
local function wrap(deg) return (deg + 540.0) % 360.0 - 180.0 end

local function project(point)
    local visible, x, y = GetScreenCoordFromWorldCoord(point.x, point.y, point.z)
    if not visible then return nil end
    return { x = x + 0.0, y = y + 0.0 }
end

local function hideTags()
    if not shown then return end
    shown = false
    SendNUIMessage({ action = 'thrusters:attitude', data = { visible = false } })
end

local function draw(vehicle, now, dt)
    local fr = P.frame(vehicle)
    local model = GetEntityModel(vehicle)
    local box = dims[model]
    if not box then
        local min, max = GetModelDimensions(model)
        box = { mid = (min + max) * 0.5, half = (max - min) * 0.5 }
        dims[model] = box
    end
    local centre = GetOffsetFromEntityInWorldCoords(vehicle, box.mid.x, box.mid.y, box.mid.z)
    local eye = GetFinalRenderedCamCoord()
    -- World size of one pixel at the car, on a 1080-line view.
    local pixel = 2.0 * length(eye - centre) * math.tan(math.rad(GetFinalRenderedCamFov()) * 0.5) / 1080.0
    local spin = P.spinBetween(prev, fr, dt)
    prev = fr

    -- Roll: the car's right side against the horizon, about its forward axis.
    local rollR = math.max(box.half.x, box.half.z) + 0.45
    local level = UP - fr.f * dot(UP, fr.f)
    local bank, rollAt = 0.0, nil
    ring(centre, fr.r, fr.u, rollR, eye, pixel)
    if length(level) > 0.2 then
        local horizon = unit(cross(fr.f, unit(level)))
        if dot(horizon, fr.r) < 0 then horizon = -horizon end
        bank = math.asin(P.clamp(-fr.r.z, -1.0, 1.0))
        wedge(centre, horizon, fr.f, bank, rollR, accent)
        tick(centre, horizon, rollR - 0.12, rollR + 0.4, eye, pixel, 4.0, PAPER)
        tick(centre, -horizon, rollR - 0.12, rollR + 0.4, eye, pixel, 4.0, PAPER)
        rollAt = centre + horizon * (rollR + 0.75)
    end
    tick(centre, fr.r, rollR - 0.2, rollR + 0.2, eye, pixel, 6.0, accent)
    tick(centre, -fr.r, rollR - 0.2, rollR + 0.2, eye, pixel, 6.0, accent)
    tick(centre, fr.u, rollR - 0.2, rollR + 0.2, eye, pixel, 6.0, accent)

    -- Yaw: the nose on a flat ring, against the reference heading.
    local yawR = box.half.y + 0.5
    local flat = fr.f - UP * fr.f.z
    local nose = length(flat) > 0.1 and unit(flat) or unit(fr.u - UP * fr.u.z)
    local facing = heading(nose)
    if ThrusterClient.trickAt and ThrusterClient.trickAt ~= lastTrick then lastTrick, reference = ThrusterClient.trickAt, facing end
    reference = reference or facing
    local delta = wrap(facing - reference)
    local east, north = vector3(1.0, 0.0, 0.0), vector3(0.0, 1.0, 0.0)
    ring(centre, east, north, yawR, eye, pixel)
    local rad = math.rad(reference)
    local from = vector3(-math.sin(rad), math.cos(rad), 0.0)
    wedge(centre, from, UP, math.rad(delta), yawR, accent)
    tick(centre, from, yawR - 0.15, yawR + 0.35, eye, pixel, 4.0, PAPER)
    tick(centre, nose, yawR - 0.25, yawR + 0.25, eye, pixel, 6.0, accent)

    -- Tags, about 30 times a second.
    if now >= tagsAt then
        tagsAt = now + 33
        local rollTag = rollAt and project(rollAt)
        local yawTag = project(centre + nose * (yawR + 0.8))
        shown = true
        SendNUIMessage({ action = 'thrusters:attitude', data = {
            visible = true,
            roll = { on = rollTag ~= nil, x = rollTag and rollTag.x or 0.0, y = rollTag and rollTag.y or 0.0,
                deg = math.deg(bank) + 0.0, rate = math.deg(dot(spin, fr.f)) + 0.0 },
            yaw = { on = yawTag ~= nil, x = yawTag and yawTag.x or 0.0, y = yawTag and yawTag.y or 0.0,
                deg = facing + 0.0, delta = delta + 0.0, rate = math.deg(spin.z) + 0.0 },
        } })
    end
end

local function run()
    CreateThread(function()
        readAccent()
        local last = GetGameTimer()
        while on do
            local now = GetGameTimer()
            local vehicle = ThrusterClient.vehicle
            if vehicle and DoesEntityExist(vehicle) and not IsPauseMenuActive() then
                draw(vehicle, now, math.max(0.001, (now - last) / 1000))
                last = now
                Wait(0)
            else
                prev = nil
                hideTags()
                last = now
                Wait(250)
            end
        end
        prev = nil
        hideTags()
    end)
end

RegisterCommand('thrusters_attitude', function(_, args)
    if args[1] == 'reset' then reference = nil; return end
    on = not on
    reference = nil
    print(('[cortex-thrusters] attitude overlay %s'):format(on and 'on' or 'off'))
    if on then run() end
end, false)

AddEventHandler('onClientResourceStop', function(name)
    if name == GetCurrentResourceName() then on = false; hideTags() end
end)
