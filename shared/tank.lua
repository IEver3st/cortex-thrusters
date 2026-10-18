-- The cold gas tank. One charge feeds every nozzle. Firing drains it; after a
-- short rest the compressor refills it. Running dry vents the system: nothing
-- fires again until the tank is back above the lockout level. Times are
-- milliseconds from GetGameTimer; levels are 0..capacity. Pure and analytic:
-- the level is only committed when something changes, never per frame.
ThrusterTank = {}
local T = ThrusterTank

function T.new(config)
    local capacity = tonumber(config.capacity) or 100.0
    return {
        capacity = capacity + 0.0,
        level = capacity + 0.0,
        at = 0,
        drain = 0.0,
        lastUse = -math.huge,
        locked = false,
        delay = (tonumber(config.rechargeDelay) or 2.5) * 1000,
        rate = (tonumber(config.rechargeRate) or 10.0) + 0.0,
        -- Configured as percent of capacity, kept as levels.
        lockout = capacity * (tonumber(config.lockout) or 30.0) / 100.0,
        low = capacity * (tonumber(config.low) or 25.0) / 100.0,
        factor = 1.0,
    }
end

-- Level at `now` without committing it.
function T.peek(t, now)
    local level = t.level
    if t.drain > 0 then
        level = level - t.drain * (now - t.at) / 1000
    else
        local start = math.max(t.at, t.lastUse + t.delay)
        if now > start then level = level + t.rate * t.factor * (now - start) / 1000 end
    end
    if level < 0 then level = 0.0 elseif level > t.capacity then level = t.capacity end
    return level
end

-- Commits the level at `now`. Running dry while draining locks the tank.
function T.advance(t, now)
    local level = T.peek(t, now)
    if t.drain > 0 then t.lastUse = now end
    t.level, t.at = level, now
    if t.drain > 0 and level <= 0 then t.locked, t.drain = true, 0.0 end
    if t.locked and t.drain == 0 and level >= t.lockout then t.locked = false end
    return level
end

-- Recharge speed multiplier (engine off recharges slower). Commits first so
-- the change only applies from now on.
function T.setFactor(t, now, factor)
    factor = (tonumber(factor) or 1.0) + 0.0
    if factor == t.factor then return end
    T.advance(t, now)
    t.factor = factor
end

-- Continuous use at `rate` units per second; 0 stops. Returns false when the
-- tank is locked or empty and nothing was started.
function T.setDrain(t, now, rate)
    T.advance(t, now)
    rate = math.max(0.0, (tonumber(rate) or 0.0) + 0.0)
    if rate > 0 and (t.locked or t.level <= 0) then
        t.drain = 0.0
        return false
    end
    if t.drain > 0 or rate > 0 then t.lastUse = now end
    t.drain = rate
    return true
end

function T.can(t, now, amount)
    if t.locked then
        T.advance(t, now)
        if t.locked then return false end
    end
    return T.peek(t, now) >= amount
end

-- One-off cost (a hop, a trick). All or nothing.
function T.spend(t, now, amount)
    if not T.can(t, now, amount) then return false end
    T.advance(t, now)
    t.level = t.level - amount
    t.lastUse = now
    if t.level <= 0 then t.level, t.locked = 0.0, true end
    return true
end

-- 'locked' (vented, refilling to the lockout level), 'low' or 'ready'.
function T.state(t, now)
    if t.locked then
        T.advance(t, now)
        if t.locked then return 'locked' end
    end
    return T.peek(t, now) < t.low and 'low' or 'ready'
end

-- What the gauge needs to animate on its own until the next change: level now,
-- signed units per second, and how long until that rate starts (recharge delay).
function T.snapshot(t, now)
    local level = T.peek(t, now)
    if t.drain > 0 then return level, -t.drain, 0 end
    if level >= t.capacity then return level, 0.0, 0 end
    return level, t.rate * t.factor, math.max(0, t.lastUse + t.delay - now)
end

-- Milliseconds until the tank is full (or 0).
function T.untilFull(t, now)
    local level, rate, wait = T.snapshot(t, now)
    if rate <= 0 then return level >= t.capacity and 0 or math.huge end
    return wait + (t.capacity - level) / rate * 1000
end
