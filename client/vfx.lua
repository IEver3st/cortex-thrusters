-- Nozzle layouts and the jets drawn on them. One renderer serves the local
-- driver and everyone else's fitted vehicles: give it a vehicle and a mask
-- and it starts and stops looped base-game particles for the bits that
-- changed. Only while some nearby car is lifting does a small loop run, for
-- the ground cloud (10 Hz) and the core glow (a script light lasts one frame).
ThrusterFx = {}
local F, C, L = ThrusterFx, Config, ThrusterLayout
local live = {}    -- [vehicle] = { mask, handles = { [index] = { handle, ... } }, ground }
local layouts = {} -- [model] = layout
local pending = {} -- [vehicle] = mask waiting for an asset
local retrying, glowing = false, false

local function debug(...) if C.debug then print('[cortex-thrusters]', ...) end end

local function loaded(asset)
    if HasNamedPtfxAssetLoaded(asset) then return true end
    RequestNamedPtfxAsset(asset)
    return false
end

local function assets()
    local list, seen = {}, {}
    for _, group in ipairs({ 'lift', 'boost', 'corner' }) do
        for _, layer in ipairs(C.fx[group] or {}) do
            if not seen[layer.asset] then seen[layer.asset] = true; list[#list + 1] = layer.asset end
        end
    end
    for _, layer in ipairs(C.fx.ground and C.fx.ground.layers or {}) do
        if not seen[layer.asset] then seen[layer.asset] = true; list[#list + 1] = layer.asset end
    end
    return list
end

-- Local offset of a bone, or nil when the model has no such bone.
local function bone(vehicle, name)
    local index = GetEntityBoneIndexByName(vehicle, name)
    if index == -1 then return nil end
    local world = GetWorldPositionOfEntityBone(vehicle, index)
    local offset = GetOffsetFromEntityGivenWorldCoords(vehicle, world.x, world.y, world.z)
    return { x = offset.x, y = offset.y, z = offset.z }
end

local function modelName(model)
    for name in pairs(C.layouts) do
        if GetHashKey(name) == model then return name end
    end
end

-- Measured once per model; every vehicle of that model shares it.
function F.layout(vehicle)
    local model = GetEntityModel(vehicle)
    local cached = layouts[model]
    if cached then return cached end
    local min, max = GetModelDimensions(model)
    local bones = {
        wheel_lf = bone(vehicle, 'wheel_lf'), wheel_rf = bone(vehicle, 'wheel_rf'),
        wheel_lr = bone(vehicle, 'wheel_lr'), wheel_rr = bone(vehicle, 'wheel_rr'),
        exhausts = {},
    }
    for i = 1, 16 do
        local pipe = bone(vehicle, i == 1 and 'exhaust' or ('exhaust_' .. i))
        if pipe then bones.exhausts[#bones.exhausts + 1] = pipe end
    end
    local layout = L.build({ x = min.x, y = min.y, z = min.z }, { x = max.x, y = max.y, z = max.z }, bones)
    local name = modelName(model)
    if name then L.apply(layout, C.layouts[name]) end
    for _, thruster in ipairs(layout.thrusters) do
        local p = thruster.pos
        thruster.offset = vector3(p.x + 0.0, p.y + 0.0, p.z + 0.0)
    end
    debug(('layout %s: %d exhausts, %.2f x %.2f x %.2f m'):format(name or model, #bones.exhausts,
        layout.halfWidth * 2, layout.halfLength * 2, layout.height))
    layouts[model] = layout
    return layout
end

local function sound(vehicle, key)
    local def = C.sounds[key]
    if not def then return end
    PlaySoundFromEntity(-1, def[1], vehicle, def[2], false, 0)
end

-- Optional colour and evolution parameters from a layer's config.
local function tint(handle, def)
    local c = def.color
    if c then SetParticleFxLoopedColour(handle, c[1] + 0.0, c[2] + 0.0, c[3] + 0.0, false) end
    for name, value in pairs(def.evolution or {}) do
        SetParticleFxLoopedEvolution(handle, name, value + 0.0, false)
    end
end

local function within(slots, slot)
    if not slots then return true end
    for _, s in ipairs(slots) do if s == slot then return true end end
    return false
end

-- Starts every layer of one nozzle. False when an asset is still loading.
local function start(entry, vehicle, layout, index)
    local thruster = layout.thrusters[index]
    local layers = thruster and C.fx[thruster.group]
    if not layers then return true end
    for _, layer in ipairs(layers) do
        if not loaded(layer.asset) then return false end
    end
    local p, mirror = thruster.offset, thruster.dir.x > 0.5
    local slot = (index - 1) % 4 + 1
    local handles = {}
    for i, layer in ipairs(layers) do
        if within(layer.slots, slot) then
            local r = layer.rot or { x = 0.0, y = 0.0, z = 0.0 }
            local ry, rz = r.y, r.z
            if mirror then ry, rz = -ry, -rz end
            UseParticleFxAsset(layer.asset)
            local handle = StartParticleFxLoopedOnEntity(layer.name, vehicle, p.x, p.y, p.z, r.x + 0.0, ry + 0.0, rz + 0.0,
                (layer.scale or 1.0) * (layout.scale or 1.0) + 0.0, false, false, false)
            if handle and handle ~= 0 then
                tint(handle, layer)
                handles[i] = handle
            end
        end
    end
    entry.handles[index] = handles
    return true
end

local function stop(entry, index)
    local handles = entry.handles[index]
    if not handles then return end
    for _, handle in pairs(handles) do StopParticleFxLooped(handle, false) end
    entry.handles[index] = nil
end

local function stopGround(entry)
    if not entry.ground then return end
    for _, point in pairs(entry.ground) do
        for _, handle in pairs(point.handles) do StopParticleFxLooped(handle, false) end
    end
    entry.ground = nil
end

local function lamp(light, at)
    DrawLightWithRange(at.x, at.y, at.z, math.floor(light.r), math.floor(light.g), math.floor(light.b),
        light.range + 0.0, light.intensity + 0.0)
end

-- Ground smoke where the lift jets hit the ground. Every 100 ms a probe
-- under each source finds the ground (or nothing within `height`); every
-- frame the emitters follow the nozzles along it, so moving leaves a trail
-- behind and hovering builds a cloud. Closer to the ground, more smoke.
local function groundSources(def)
    return def.each and 4 or 1
end

local function probeGround(vehicle, entry, def, layout)
    entry.ground = entry.ground or {}
    for index = 1, groundSources(def) do
        local p = def.each and layout.thrusters[index].offset or vector3(0.0, 0.0, 0.0)
        local from = GetOffsetFromEntityInWorldCoords(vehicle, p.x, p.y, p.z)
        local probe = StartExpensiveSynchronousShapeTestLosProbe(from.x, from.y, from.z, from.x, from.y, from.z - def.height, 1, vehicle, 7)
        local _, hit, at = GetShapeTestResult(probe)
        local point = entry.ground[index]
        if hit == 1 or hit == true then
            point = point or { handles = {} }
            point.z = at.z + 0.05
            point.near = 1.0 - math.min(1.0, (from.z - at.z) / def.height)
            entry.ground[index] = point
            for i, handle in pairs(point.handles) do
                local layer = def.layers[i]
                if layer then SetParticleFxLoopedScale(handle, (layer.scale or 1.0) * (0.35 + 0.65 * point.near) + 0.0) end
            end
        elseif point then
            for _, handle in pairs(point.handles) do StopParticleFxLooped(handle, false) end
            entry.ground[index] = nil
        end
    end
end

local function moveGround(vehicle, entry, def, layout)
    for index, point in pairs(entry.ground) do
        local p = def.each and layout.thrusters[index].offset or vector3(0.0, 0.0, 0.0)
        local at = GetOffsetFromEntityInWorldCoords(vehicle, p.x, p.y, p.z)
        for i, layer in ipairs(def.layers) do
            local handle = point.handles[i]
            if handle then
                SetParticleFxLoopedOffsets(handle, at.x, at.y, point.z, 0.0, 0.0, 0.0)
            elseif (not def.each or within(layer.slots, index)) and loaded(layer.asset) then
                UseParticleFxAsset(layer.asset)
                handle = StartParticleFxLoopedAtCoord(layer.name, at.x, at.y, point.z, 0.0, 0.0, 0.0,
                    (layer.scale or 1.0) * (0.35 + 0.65 * point.near) + 0.0, false, false, false, false)
                if handle and handle ~= 0 then tint(handle, layer); point.handles[i] = handle end
            end
        end
    end
end

-- Ground smoke and core glow for every car lifting or boosting near enough to see.
local function glow()
    if glowing then return end
    glowing = true
    CreateThread(function()
        local nextGround = 0
        while true do
            local any = false
            local now = GetGameTimer()
            local here = GetEntityCoords(PlayerPedId())
            local tick = now >= nextGround
            if tick then nextGround = now + 100 end
            local def = C.fx.ground
            for vehicle, entry in pairs(live) do
                local lifting = entry.mask & L.MASK_LIFT ~= 0
                local boosting = entry.mask & L.MASK_BOOST ~= 0
                if (lifting or boosting) and DoesEntityExist(vehicle) then
                    any = true
                    local layout = F.layout(vehicle)
                    local light = C.fx.light
                    if light and #(GetEntityCoords(vehicle) - here) <= light.distance then
                        if lifting then lamp(light, GetOffsetFromEntityInWorldCoords(vehicle, 0.0, 0.0, -layout.ground - 0.4)) end
                        if boosting then lamp(light, GetOffsetFromEntityInWorldCoords(vehicle, 0.0, -layout.halfLength - 1.2, 0.2 - layout.ground)) end
                    end
                    if lifting and def and def.layers then
                        if tick then probeGround(vehicle, entry, def, layout) end
                        if entry.ground then moveGround(vehicle, entry, def, layout) end
                    elseif entry.ground then
                        stopGround(entry)
                    end
                elseif entry.ground then
                    stopGround(entry)
                end
            end
            if not any then break end
            Wait(0)
        end
        glowing = false
    end)
end

local function retry()
    if retrying then return end
    retrying = true
    CreateThread(function()
        local deadline = GetGameTimer() + 5000
        while next(pending) and GetGameTimer() < deadline do
            Wait(100)
            for vehicle, mask in pairs(pending) do
                pending[vehicle] = nil
                if DoesEntityExist(vehicle) then F.set(vehicle, mask, true) end
            end
        end
        pending = {}
        retrying = false
    end)
end

-- `audible` false keeps it silent.
function F.set(vehicle, mask, audible)
    mask = mask & L.MAX
    local entry = live[vehicle]
    if not entry then
        if mask == 0 then return end
        entry = { mask = 0, handles = {} }
        live[vehicle] = entry
    end
    local old = entry.mask
    if old == mask and not pending[vehicle] then return end
    local layout = F.layout(vehicle)
    local missing = false
    for index = 1, L.COUNT do
        local on = mask & (1 << (index - 1)) ~= 0
        if on and not entry.handles[index] then
            if not start(entry, vehicle, layout, index) then missing = true end
        elseif not on and entry.handles[index] then
            stop(entry, index)
        end
    end
    if audible ~= false then
        if mask & L.MASK_BOOST ~= 0 and old & L.MASK_BOOST == 0 then sound(vehicle, 'boost') end
        if mask & (L.MASK_LIFT | L.MASK_CORNER) ~= 0 and old & (L.MASK_LIFT | L.MASK_CORNER) == 0 then sound(vehicle, 'burst') end
        if mask & L.GRIP ~= 0 and old & L.GRIP == 0 then sound(vehicle, 'gripOn') end
        if mask & L.GRIP == 0 and old & L.GRIP ~= 0 then sound(vehicle, 'gripOff') end
    end
    entry.mask = mask
    if mask & (L.MASK_LIFT | L.MASK_BOOST) ~= 0 then glow() end
    if missing then pending[vehicle] = mask; retry() end
    if mask & L.MASK_LIFT == 0 then stopGround(entry) end
    if mask == 0 and not next(entry.handles) then live[vehicle] = nil end
end

function F.play(vehicle, key) sound(vehicle, key) end

-- Restarts a vehicle's jets with the current config (live rotation tuning).
function F.refresh(vehicle)
    local entry = live[vehicle]
    if not entry then return end
    local mask = entry.mask
    F.clear(vehicle)
    F.set(vehicle, mask, false)
end

function F.clear(vehicle)
    local entry = live[vehicle]
    pending[vehicle] = nil
    if not entry then return end
    for index in pairs(entry.handles) do stop(entry, index) end
    stopGround(entry)
    live[vehicle] = nil
end

function F.each(fn)
    for vehicle, entry in pairs(live) do fn(vehicle, entry.mask) end
end

function F.clearAll()
    for vehicle in pairs(live) do F.clear(vehicle) end
end

-- Warm the particle assets so the first press already shows jets.
CreateThread(function()
    for _, asset in ipairs(assets()) do RequestNamedPtfxAsset(asset) end
end)

AddEventHandler('onClientResourceStop', function(name)
    if name ~= GetCurrentResourceName() then return end
    F.clearAll()
    for _, asset in ipairs(assets()) do
        if asset ~= 'core' then RemoveNamedPtfxAsset(asset) end
    end
end)
