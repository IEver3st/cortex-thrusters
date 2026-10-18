-- lua tests/shared_spec.lua (from the resource root)
os = nil -- shared code also runs on the client, which has no os library
local checks = 0
local function ok(cond, what) assert(cond, what); checks = checks + 1 end
local function near(a, b, what, tol) ok(math.abs(a - b) <= (tol or 1e-6), (what or '') .. ': ' .. tostring(a) .. ' ~= ' .. tostring(b)) end

dofile('shared/layout.lua')
dofile('shared/tank.lua')
dofile('shared/tricks.lua')
local L, T, K = ThrusterLayout, ThrusterTank, ThrusterTricks

-- Layout ----------------------------------------------------------------------
local min, max = { x = -1.0, y = -2.3, z = -0.6 }, { x = 1.0, y = 2.3, z = 0.7 }

do -- no bones: proportions of the box
    local layout = L.build(min, max, {})
    ok(#layout.thrusters == 12, 'twelve nozzles')
    for i, t in ipairs(layout.thrusters) do
        ok(t.index == i, 'index ' .. i)
        ok(t.pos.x >= min.x - 1e-6 and t.pos.x <= max.x + 1e-6, 'nozzle ' .. i .. ' inside width')
        ok(t.pos.y >= min.y - 1e-6 and t.pos.y <= max.y + 1e-6, 'nozzle ' .. i .. ' inside length')
    end
    for _, i in ipairs(L.LIFT) do ok(layout.thrusters[i].dir.z == -1 and layout.thrusters[i].group == 'lift', 'lift fires down') end
    for _, i in ipairs(L.BOOST) do ok(layout.thrusters[i].dir.y == -1 and layout.thrusters[i].group == 'boost', 'boost fires back') end
    ok(layout.thrusters[9].dir.x == -1 and layout.thrusters[10].dir.x == 1, 'front corners fire outward')
    ok(layout.thrusters[1].pos.x < 0 and layout.thrusters[2].pos.x > 0, 'lift left/right')
    ok(layout.thrusters[1].pos.y > 0 and layout.thrusters[3].pos.y < 0, 'lift front/rear')
    for i = 5, 7 do ok(layout.thrusters[i].pos.x < layout.thrusters[i + 1].pos.x, 'boost left to right') end
    near(layout.ground, 0.6, 'ground clearance from min.z')
end

do -- wheels and two exhausts: real positions where they exist
    local bones = {
        wheel_lf = { x = -0.8, y = 1.4, z = -0.3 }, wheel_rf = { x = 0.8, y = 1.4, z = -0.3 },
        wheel_lr = { x = -0.8, y = -1.3, z = -0.3 }, wheel_rr = { x = 0.8, y = -1.3, z = -0.3 },
        exhausts = { { x = -0.45, y = -2.25, z = -0.35 }, { x = 0.45, y = -2.25, z = -0.35 } },
    }
    local layout = L.build(min, max, bones)
    near(layout.thrusters[1].pos.x, -0.8 * 0.82, 'lift pulled inboard of the wheel')
    near(layout.thrusters[1].pos.y, 1.4, 'lift at the wheel line')
    near(layout.thrusters[1].pos.z, -0.35, 'lift just under the hub')
    local pipes = 0
    for i = 5, 8 do if math.abs(layout.thrusters[i].pos.y - (-2.30)) < 1e-6 then pipes = pipes + 1 end end
    ok(pipes == 2, 'both exhausts became boost nozzles')
    ok(layout.thrusters[5].pos.x == -0.45 and layout.thrusters[8].pos.x == 0.45, 'each exhaust takes its nearest slot')
    local swapped = L.build(min, max, { exhausts = { bones.exhausts[2], bones.exhausts[1] } })
    ok(swapped.thrusters[5].pos.x == -0.45 and swapped.thrusters[8].pos.x == 0.45, 'bone order does not matter')
end

do -- overrides
    local layout = L.apply(L.build(min, max, {}), { scale = 1.5, positions = { [5] = { x = 0.1, y = -2.0, z = 0.2 } } })
    ok(layout.scale == 1.5 and layout.thrusters[5].pos.x == 0.1, 'override applied')
    ok(L.bits(L.LIFT) == L.MASK_LIFT and L.bits(L.BOOST) == L.MASK_BOOST and L.bits(L.CORNER) == L.MASK_CORNER, 'group masks')
    ok(L.MAX == (L.MASK_LIFT | L.MASK_BOOST | L.MASK_CORNER | L.GRIP), 'max mask')
end

-- Tank ------------------------------------------------------------------------
do
    local t = T.new({ capacity = 100, rechargeDelay = 2, rechargeRate = 10, lockout = 30, low = 25 })
    ok(T.state(t, 0) == 'ready', 'starts full')
    ok(T.spend(t, 0, 20), 'spend'); near(T.peek(t, 0), 80, 'spent 20')
    near(T.peek(t, 1999), 80, 'no refill before the delay')
    near(T.peek(t, 3000), 90, 'refills after the delay')
    ok(T.setDrain(t, 3000, 50), 'drain starts')
    near(T.peek(t, 4000), 40, 'drains 50/s')
    T.advance(t, 5000)
    ok(t.locked and t.drain == 0, 'running dry locks and stops the drain')
    ok(not T.setDrain(t, 5100, 10), 'no drain while locked')
    ok(not T.spend(t, 5100, 1), 'no spend while locked')
    ok(T.state(t, 6000) == 'locked', 'still locked inside the delay')
    ok(T.state(t, 9999) == 'locked', 'locked below the lockout level')
    ok(T.state(t, 10100) ~= 'locked', 'unlocks past the lockout level')
    local level, rate, wait = T.snapshot(t, 10100)
    ok(rate == 10 and wait == 0 and level > 30, 'snapshot while refilling')
    T.setFactor(t, 10100, 0.5)
    near(T.peek(t, 12100), level + 10, 'engine off halves the refill')
    local full = T.new({ capacity = 100 })
    local _, r0, w0 = T.snapshot(full, 0)
    ok(r0 == 0 and w0 == 0, 'a full tank reports no rate')
    local big = T.new({ capacity = 200, lockout = 30, low = 25 })
    ok(big.lockout == 60 and big.low == 50, 'lockout and low are percent of a bigger tank')
end

-- Tricks ----------------------------------------------------------------------
do
    local car = L.build(min, max, {})
    local cfg = { cost = 20, rise = 0.35, duration = { x = 1.5, y = 1.3, z = 1.2 }, finish = 0.25, margin = 0.35,
        maxHop = 14.0, maxDuration = 2.4 }
    local g = 9.81
    for kind in pairs(K.KINDS) do
        local plan = K.plan(kind, car, false, cfg)
        -- The eased rate still turns the car exactly once.
        local turned, step = 0, 0.0005
        for s = 0, plan.duration, step do turned = turned + K.rate(plan, s) * step end
        near(math.abs(turned), 2 * math.pi, kind .. ' turns once', 0.01)
        ok(K.rate(plan, 0) == 0 and math.abs(K.rate(plan, plan.duration - 1e-4)) < 0.01, kind .. ' starts and stops at rest')
        -- Still in the air (above the take-off point) when the turn and finish are done.
        ok(K.height(plan, plan.duration + cfg.finish) >= -1e-9, kind .. ' lands after the turn')
        -- A quarter and three quarters of the way round the body clears the ground.
        local reach = K.KINDS[kind].reach == 'length' and car.halfLength or K.KINDS[kind].reach == 'width' and math.max(car.halfWidth, car.height / 2) or 0
        for _, f in ipairs({ 0.25, 0.75 }) do
            ok(car.ground + K.height(plan, plan.duration * f) >= reach + cfg.margin - 1e-6, kind .. ' clears the ground at ' .. f)
        end
    end
    local roll = K.plan('roll_right', car, false, cfg)
    local apex = roll.hop * roll.rise / 2 + roll.hop ^ 2 / (2 * g)
    ok(apex > 2.5 and apex < 6, 'a roll lifts a car a few metres: ' .. apex)
    ok(roll.duration == 1.3 and math.abs(roll.rate) > 2 * math.pi / 1.3, 'roll takes its configured time, peak above the average')
    local air = K.plan('flip_front', car, true, cfg)
    ok(air.hop == 0 and air.rise == 0 and air.duration == 1.5, 'no rise when already airborne')
    ok(K.plan('nope', car, false, cfg) == nil, 'unknown trick')
    ok(K.mask(roll, 0.0) == L.MASK_LIFT and K.mask(roll, roll.rise - 0.01) == L.MASK_LIFT, 'the rise fires every lift nozzle')
    ok(K.mask(roll, roll.rise + 0.01) == L.bits({ 1, 3 }), 'left side kicks a right roll')
    ok(K.mask(roll, roll.rise + roll.duration * 0.7) == 0, 'coasts silently')
    ok(K.mask(roll, roll.rise + roll.duration - 0.05) == L.bits({ 2, 4 }), 'right side catches it')
    ok(K.mask(roll, roll.rise + roll.duration + 0.001) == 0, 'nothing after the end')
    local bus = L.build({ x = -1.4, y = -6.0, z = -0.5 }, { x = 1.4, y = 6.0, z = 2.8 }, {})
    local flip = K.plan('flip_front', bus, false, cfg)
    ok(flip.hop <= 14.0 and flip.hop > K.plan('flip_front', car, false, cfg).hop, 'long vehicles go higher, capped')
end

print(('shared_spec: %d checks passed'):format(checks))
