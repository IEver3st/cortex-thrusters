-- Where the twelve nozzles sit on a vehicle, derived from its model box and
-- bones so the kit fits any car without per-model setup. Pure: positions and
-- directions are plain {x, y, z} tables in the vehicle's local frame
-- (x right, y forward, z up). The client measures bones and converts.
ThrusterLayout = {}
local L = ThrusterLayout

-- Thruster index -> mask bit. 1-4 lift (fire down), 5-8 boost (fire back),
-- 9-12 corner RCS (fire sideways). Bit 13 is the grip (suction) state.
L.COUNT = 12
L.LIFT = { 1, 2, 3, 4 }      -- front left, front right, rear left, rear right
L.BOOST = { 5, 6, 7, 8 }     -- left to right across the rear
L.CORNER = { 9, 10, 11, 12 } -- front left, front right, rear left, rear right
L.MASK_LIFT = 0x00F
L.MASK_BOOST = 0x0F0
L.MASK_CORNER = 0xF00
L.GRIP = 0x1000
L.MAX = 0x1FFF

function L.bit(index) return 1 << (index - 1) end

function L.bits(list)
    local mask = 0
    for _, index in ipairs(list) do mask = mask | (1 << (index - 1)) end
    return mask
end

function L.group(index)
    if index <= 4 then return 'lift' elseif index <= 8 then return 'boost' end
    return 'corner'
end

local function v(x, y, z) return { x = x, y = y, z = z } end

-- Synthetic rear nozzles across the bumper, then each replaced by the nearest
-- unused exhaust bone. Four exhausts or more give four real tailpipes.
local function rear(box, exhausts)
    local slots = {}
    for i, f in ipairs({ -0.55, -0.2, 0.2, 0.55 }) do
        slots[i] = v(box.cx + box.halfWidth * f, box.min.y + 0.08, box.min.z + box.height * 0.3)
    end
    -- Closest slot/pipe pairs first, so the result does not depend on order.
    local pairs_ = {}
    for i, slot in ipairs(slots) do
        for j, pipe in ipairs(exhausts or {}) do
            pairs_[#pairs_ + 1] = { slot = i, pipe = j, distance = math.abs(pipe.x - slot.x) }
        end
    end
    table.sort(pairs_, function(a, b)
        if a.distance ~= b.distance then return a.distance < b.distance end
        return a.slot < b.slot
    end)
    local slotUsed, pipeUsed = {}, {}
    for _, pair in ipairs(pairs_) do
        if not slotUsed[pair.slot] and not pipeUsed[pair.pipe] then
            slotUsed[pair.slot], pipeUsed[pair.pipe] = true, true
            local slot, pipe = slots[pair.slot], exhausts[pair.pipe]
            slot.x, slot.y, slot.z = pipe.x, pipe.y - 0.05, pipe.z
        end
    end
    return slots
end

-- `min`/`max` from GetModelDimensions. `bones` may carry wheel_lf, wheel_rf,
-- wheel_lr, wheel_rr and an `exhausts` list, all local offsets. Missing bones
-- fall back to proportions of the box.
function L.build(min, max, bones)
    bones = bones or {}
    local box = {
        min = min, max = max,
        cx = (min.x + max.x) * 0.5,
        halfWidth = math.max(0.3, (max.x - min.x) * 0.5),
        halfLength = math.max(0.5, (max.y - min.y) * 0.5),
        height = math.max(0.4, max.z - min.z),
    }
    local length = box.halfLength * 2
    local thrusters = {}

    local wheels = {
        { bones.wheel_lf, -1, max.y - length * 0.2 },
        { bones.wheel_rf, 1, max.y - length * 0.2 },
        { bones.wheel_lr, -1, min.y + length * 0.2 },
        { bones.wheel_rr, 1, min.y + length * 0.2 },
    }
    for i, wheel in ipairs(wheels) do
        local bone, side, y = wheel[1], wheel[2], wheel[3]
        local x = bone and bone.x * 0.82 or box.cx + side * box.halfWidth * 0.6
        local z = bone and bone.z - 0.05 or min.z + 0.3
        thrusters[i] = { pos = v(x, bone and bone.y or y, z), dir = v(0, 0, -1) }
    end

    for i, pos in ipairs(rear(box, bones.exhausts)) do
        thrusters[4 + i] = { pos = pos, dir = v(0, -1, 0) }
    end

    local z = min.z + box.height * 0.45
    local front, back = max.y - length * 0.18, min.y + length * 0.18
    thrusters[9] = { pos = v(min.x + 0.05, front, z), dir = v(-1, 0, 0) }
    thrusters[10] = { pos = v(max.x - 0.05, front, z), dir = v(1, 0, 0) }
    thrusters[11] = { pos = v(min.x + 0.05, back, z), dir = v(-1, 0, 0) }
    thrusters[12] = { pos = v(max.x - 0.05, back, z), dir = v(1, 0, 0) }

    for i, thruster in ipairs(thrusters) do
        thruster.index, thruster.group = i, L.group(i)
    end
    return {
        thrusters = thrusters,
        halfWidth = box.halfWidth,
        halfLength = box.halfLength,
        height = box.height,
        -- Distance from the model origin down to the lowest point (tyres).
        ground = math.max(0.1, -min.z),
    }
end

-- Per-model overrides from config: { [index] = { x, y, z } } replaces a
-- nozzle position; `scale` multiplies the effect size for that model.
function L.apply(layout, override)
    if type(override) ~= 'table' then return layout end
    for index, pos in pairs(override.positions or {}) do
        local thruster = layout.thrusters[tonumber(index)]
        if thruster and type(pos) == 'table' then
            thruster.pos = v(tonumber(pos.x or pos[1]) or thruster.pos.x, tonumber(pos.y or pos[2]) or thruster.pos.y,
                tonumber(pos.z or pos[3]) or thruster.pos.z)
        end
    end
    layout.scale = tonumber(override.scale)
    return layout
end
