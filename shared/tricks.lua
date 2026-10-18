-- Trick planning, sized from the vehicle's own box. Pure.
-- From the ground a trick has three parts: the lift nozzles push the car up
-- for `rise` seconds, it turns once at a steady rate while still climbing,
-- and it has `finish` seconds of airtime left to level out and land.
-- Local frame: x right, y forward, z up (right-handed). A positive spin about
-- +y lowers the right side (roll right), about +x lifts the nose, about +z
-- turns the nose left.
ThrusterTricks = {}
local K = ThrusterTricks
local L = ThrusterLayout
local GRAVITY = 9.81
-- Share of the turn spent spinning up (start nozzles) and slowing down (the
-- catching nozzles). The peak rate covers the rest so the car turns once.
local SPIN_UP, SPIN_DOWN = 0.15, 0.2

-- start: nozzles that kick the rotation off; stop: the ones that catch it.
K.KINDS = {
    roll_right = { axis = 'y', sign = 1, reach = 'width', start = { 1, 3 }, stop = { 2, 4 } },
    roll_left = { axis = 'y', sign = -1, reach = 'width', start = { 2, 4 }, stop = { 1, 3 } },
    flip_front = { axis = 'x', sign = -1, reach = 'length', start = { 3, 4 }, stop = { 1, 2 } },
    flip_back = { axis = 'x', sign = 1, reach = 'length', start = { 1, 2 }, stop = { 3, 4 } },
    spin_left = { axis = 'z', sign = 1, reach = 'none', start = { 10, 11 }, stop = { 9, 12 } },
    spin_right = { axis = 'z', sign = -1, reach = 'none', start = { 9, 12 }, stop = { 10, 11 } },
}

-- Height above the take-off point `t` seconds into the turn. The rise
-- accelerates evenly from 0 to `hop`, so it ends hop * rise / 2 up.
function K.height(plan, t)
    return plan.hop * plan.rise * 0.5 + plan.hop * t - 0.5 * GRAVITY * t * t
end

-- Upward speed that keeps the turn and `finish` in the air, and the body
-- `margin` clear of the ground at a quarter and three quarters of the way
-- round, where a rolling or flipping car reaches lowest.
function K.hopFor(duration, rise, finish, reach, ground, margin)
    local hop = GRAVITY * (duration + finish) * 0.5
    local need = reach + margin - ground
    if need > 0 then
        for _, f in ipairs({ 0.25, 0.75 }) do
            local t = duration * f
            hop = math.max(hop, (need + 0.5 * GRAVITY * t * t) / (rise * 0.5 + t))
        end
    end
    return hop
end

-- `airborne` = already clear of the ground: no rise, it turns at once.
-- Returns nil for an unknown kind.
function K.plan(kind, layout, airborne, config)
    local def = K.KINDS[kind]
    if not def then return nil end
    config = config or {}
    local duration = tonumber((config.duration or {})[def.axis]) or 1.3
    duration = math.max(0.4, math.min(duration, tonumber(config.maxDuration) or 2.4))
    local rise = airborne and 0 or (tonumber(config.rise) or 0.35)
    local hop = 0
    if not airborne then
        local reach = def.reach == 'width' and math.max(layout.halfWidth, layout.height * 0.5)
            or def.reach == 'length' and layout.halfLength or 0
        hop = K.hopFor(duration, rise, tonumber(config.finish) or 0.25, reach, layout.ground,
            tonumber(config.margin) or 0.35)
        hop = math.min(hop, tonumber(config.maxHop) or 14.0)
    end
    return {
        kind = kind,
        axis = def.axis,
        sign = def.sign,
        rise = rise,
        duration = duration,
        rate = def.sign * 2 * math.pi / (duration * (1 - (SPIN_UP + SPIN_DOWN) / 2)), -- peak rad/s about the local axis
        hop = hop,
        burst = duration * 0.55,
        catch = duration * SPIN_DOWN,
        start = L.bits(def.start),
        stop = L.bits(def.stop),
        cost = tonumber(config.cost) or 20,
    }
end

-- Nozzles firing `t` seconds into a trick: every lift nozzle for the rise,
-- the side that starts the turn through most of it, the catching side last.
function K.mask(plan, t)
    if t < 0 then return 0 end
    if t < plan.rise then return L.MASK_LIFT end
    t = t - plan.rise
    if t >= plan.duration then return 0 end
    if t < plan.burst then return plan.start end
    if t >= plan.duration - plan.catch then return plan.stop end
    return 0
end

-- Turn rate `t` seconds into the turn (after the rise): ramps up, holds,
-- and comes back to zero exactly at the end, so the car stops upright.
function K.rate(plan, t)
    if t < 0 or t >= plan.duration then return 0 end
    local up, down = plan.duration * SPIN_UP, plan.duration * SPIN_DOWN
    if t < up then return plan.rate * t / up end
    if t > plan.duration - down then return plan.rate * (plan.duration - t) / down end
    return plan.rate
end
