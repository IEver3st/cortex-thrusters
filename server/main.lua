-- Server authority: who may fit a kit, which vehicles carry one, and the
-- firing mask other players see. The physics itself runs on the driver's
-- client (the network owner moves the car); the server only relays a small
-- validated mask on the vehicle's state bag.
local C, LY, B = Config, ThrusterLayout, ThrusterBridge
local RESOURCE = GetCurrentResourceName()
local INSTALL_REACH = 8.0
local MAX_FIT_SPEED = 2.0 -- m/s
local rates, pending, driving, buckets = {}, {}, {}, {}

local function ok(data) return { ok = true, data = data } end
local function fail(code) return { ok = false, error = { code = code } } end
local function log(...) print('[' .. RESOURCE .. ']', ...) end

local function limited(src, kind, ms)
    local now = GetGameTimer()
    rates[src] = rates[src] or {}
    local last = rates[src][kind]
    if last and now - last < ms then return true end
    rates[src][kind] = now
    return false
end

local function vehicleFrom(netId)
    netId = tonumber(netId)
    if not netId or netId % 1 ~= 0 then return nil end
    local entity = NetworkGetEntityFromNetworkId(math.floor(netId))
    if not entity or entity == 0 or not DoesEntityExist(entity) or GetEntityType(entity) ~= 2 then return nil end
    return entity
end

local function plateKey(vehicle)
    local plate = GetVehicleNumberPlateText(vehicle)
    if type(plate) ~= 'string' then return nil end
    plate = plate:gsub('^%s+', ''):gsub('%s+$', ''):upper()
    if plate == '' or #plate > 16 then return nil end
    return 'plate:' .. plate
end

local function remembered(vehicle)
    local key = C.persist and plateKey(vehicle)
    return key and GetResourceKvpInt(key) == 1 or false
end

local function remember(vehicle, on)
    local key = C.persist and plateKey(vehicle)
    if not key then return end
    if on then SetResourceKvpInt(key, 1) else DeleteResourceKvp(key) end
end

local function fitted(vehicle) return Entity(vehicle).state.cxThrusters == true end

local function setFitted(vehicle, on)
    local state = Entity(vehicle).state
    state:set('cxThrusters', on and true or nil, true)
    if not on then state:set('cxThrust', nil, true) end
end

local blockedModels = {}
for _, name in ipairs(C.blockedModels) do blockedModels[GetHashKey(name)] = true end

local function allowedVehicle(vehicle)
    return C.types[GetVehicleType(vehicle)] == true and not blockedModels[GetEntityModel(vehicle)]
end

local function near(src, vehicle)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return false end
    return #(GetEntityCoords(ped) - GetEntityCoords(vehicle)) <= INSTALL_REACH
end

local function allowed(src, rule)
    if not rule or not rule.ace then return true end
    return IsPlayerAceAllowed(src, rule.ace)
end

local function admin(src) return src == 0 or IsPlayerAceAllowed(src, C.adminAce) end

local function precheck(src, payload)
    local vehicle = type(payload) == 'table' and vehicleFrom(payload.netId)
    if not vehicle then return nil, 'VEHICLE' end
    if not near(src, vehicle) then return nil, 'TOO_FAR' end
    if not allowedVehicle(vehicle) then return nil, 'VEHICLE' end
    if fitted(vehicle) then return nil, 'ALREADY' end
    -- Nobody drives off mid-fitting: checked before and after the work.
    if #GetEntityVelocity(vehicle) > MAX_FIT_SPEED then return nil, 'MOVING' end
    if C.requireItem then
        local has = B.has(src, C.item)
        if has == nil then return nil, 'UNAVAILABLE' end
        if not has then return nil, 'NO_ITEM' end
    elseif not allowed(src, C.access) then
        return nil, 'NOT_ALLOWED'
    end
    return vehicle
end

lib.callback.register(RESOURCE .. ':canInstall', function(src, payload)
    if limited(src, 'check', 500) then return fail('RATE_LIMITED') end
    local vehicle, code = precheck(src, payload)
    if not vehicle then return fail(code) end
    pending[src] = { vehicle = vehicle, at = GetGameTimer() }
    return ok()
end)

lib.callback.register(RESOURCE .. ':install', function(src, payload)
    if limited(src, 'install', 1000) then return fail('RATE_LIMITED') end
    local vehicle, code = precheck(src, payload)
    if not vehicle then return fail(code) end
    -- The fitting has to have taken (most of) its time since canInstall.
    local work = pending[src]
    pending[src] = nil
    if not work or work.vehicle ~= vehicle or GetGameTimer() - work.at < C.installSeconds * 800 then return fail('NOT_ALLOWED') end
    if C.requireItem then
        local taken = B.take(src, C.item)
        if taken == nil then
            log(('could not confirm taking %s from player %d; no kit fitted'):format(C.item, src))
            return fail('UNAVAILABLE')
        end
        if not taken then return fail('NO_ITEM') end
    end
    setFitted(vehicle, true)
    remember(vehicle, true)
    log(('player %d fitted a kit to %s'):format(src, GetVehicleNumberPlateText(vehicle) or '?'))
    return ok()
end)

lib.callback.register(RESOURCE .. ':remove', function(src, payload)
    if limited(src, 'remove', 1000) then return fail('RATE_LIMITED') end
    if not admin(src) then return fail('NOT_ALLOWED') end
    local vehicle = type(payload) == 'table' and vehicleFrom(payload.netId)
    if not vehicle then return fail('VEHICLE') end
    if not near(src, vehicle) then return fail('TOO_FAR') end
    if not fitted(vehicle) then return fail('NOT_FITTED') end
    setFitted(vehicle, false)
    remember(vehicle, false)
    log(('player %d removed the kit from %s'):format(src, GetVehicleNumberPlateText(vehicle) or '?'))
    return ok()
end)

-- A driver sat in a vehicle without the kit flag: restore a remembered kit.
RegisterNetEvent(RESOURCE .. ':server:check', function(netId)
    local src = source
    if limited(src, 'restore', 1000) then return end
    local vehicle = vehicleFrom(netId)
    if not vehicle or fitted(vehicle) or GetPedInVehicleSeat(vehicle, -1) ~= GetPlayerPed(src) then return end
    if allowedVehicle(vehicle) and remembered(vehicle) then setFitted(vehicle, true) end
end)

-- The driver's firing mask, for everyone else's jets. At most ~20 a second
-- per player; the client sends at most 10.
RegisterNetEvent(RESOURCE .. ':server:thrust', function(netId, mask)
    local src = source
    mask = tonumber(mask)
    if not mask or mask % 1 ~= 0 or mask < 0 or mask > LY.MAX then return end
    local now = GetGameTimer()
    local bucket = buckets[src] or { tokens = 20, at = now }
    bucket.tokens = math.min(20, bucket.tokens + (now - bucket.at) * 0.02)
    bucket.at = now
    buckets[src] = bucket
    if bucket.tokens < 1 then return end
    bucket.tokens = bucket.tokens - 1
    local vehicle = vehicleFrom(netId)
    if not vehicle or not fitted(vehicle) or GetPedInVehicleSeat(vehicle, -1) ~= GetPlayerPed(src) then return end
    local state = Entity(vehicle).state
    mask = math.floor(mask)
    if state.cxThrust ~= mask then state:set('cxThrust', mask, true) end
    driving[src] = mask ~= 0 and vehicle or nil
end)

AddEventHandler('playerDropped', function()
    local src = source
    local vehicle = driving[src]
    if vehicle and DoesEntityExist(vehicle) then Entity(vehicle).state:set('cxThrust', 0, true) end
    rates[src], pending[src], driving[src], buckets[src] = nil, nil, nil, nil
end)

-- Item use ------------------------------------------------------------------------

local function useKit(src) TriggerClientEvent(RESOURCE .. ':client:install', src) end

local function registerUse()
    if C.item and not B.registerUsable(C.item, useKit) and B.framework() ~= 'standalone' then
        log(('could not make %s usable; is it already used by another resource?'):format(C.item))
    end
end

-- ox_inventory without a framework: `server = { export = 'cortex-thrusters.useKit' }`.
exports('useKit', function(event, _, inventory)
    if event == 'usingItem' and type(inventory) == 'table' then useKit(inventory.id) end
end)

AddEventHandler('onResourceStart', function(name)
    if name == RESOURCE then
        CreateThread(function() Wait(500); registerUse() end)
    elseif name == 'qbx_core' or name == 'qb-core' or name == 'es_extended' then
        B.reset()
        CreateThread(function() Wait(1000); registerUse() end)
    end
end)

AddEventHandler('onResourceStop', function(name)
    if name ~= RESOURCE then return end
    if C.item then B.releaseUsable(C.item) end
    for _, vehicle in pairs(driving) do
        if DoesEntityExist(vehicle) then Entity(vehicle).state:set('cxThrust', 0, true) end
    end
end)

-- Staff and other resources -------------------------------------------------------

-- thrusters_plate add|remove <PLATE>: remember or forget a kit by plate.
RegisterCommand('thrusters_plate', function(src, args)
    if not admin(src) then return end
    local action, plate = args[1], table.concat(args, ' ', 2):upper()
    if (action ~= 'add' and action ~= 'remove') or plate == '' or #plate > 16 then
        print('usage: thrusters_plate add|remove <PLATE>')
        return
    end
    if action == 'add' then SetResourceKvpInt('plate:' .. plate, 1) else DeleteResourceKvp('plate:' .. plate) end
    print(('[%s] kit %s for plate %s'):format(RESOURCE, action == 'add' and 'remembered' or 'forgotten', plate))
end, false)

-- exports['cortex-thrusters']:setFitted(vehicle, true|false) for garages and admin menus.
exports('setFitted', function(vehicle, on)
    if type(vehicle) ~= 'number' or not DoesEntityExist(vehicle) or GetEntityType(vehicle) ~= 2 then return false end
    setFitted(vehicle, on == true)
    remember(vehicle, on == true)
    return true
end)
exports('isFitted', function(vehicle)
    return type(vehicle) == 'number' and DoesEntityExist(vehicle) and fitted(vehicle)
end)
