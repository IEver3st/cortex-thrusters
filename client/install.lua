-- Fitting and removing the kit. The client only picks the vehicle and plays
-- the work; the server checks reach and the item, then marks the
-- vehicle through its state bag.
local C, F, LY = Config, ThrusterFx, ThrusterLayout
local RESOURCE = GetCurrentResourceName()
local working = false

local ERRORS = {
    NO_ITEM = 'notify.noItem', NOT_ALLOWED = 'notify.denied', TOO_FAR = 'notify.tooFar',
    ALREADY = 'notify.already', NOT_FITTED = 'notify.notFitted', VEHICLE = 'notify.notAllowed',
    UNAVAILABLE = 'notify.inventory', RATE_LIMITED = 'notify.slowDown', MOVING = 'notify.moving',
}

local function notify(key, kind)
    if lib and lib.notify then lib.notify({ description = L(key), type = kind or 'error' }) end
end

local function request(name, payload)
    local ok, result = pcall(function() return lib.callback.await(RESOURCE .. ':' .. name, false, payload) end)
    if not ok or type(result) ~= 'table' then return { ok = false, error = { code = 'UNKNOWN_OUTCOME' } } end
    return result
end

local function failed(result)
    local code = type(result.error) == 'table' and result.error.code or 'UNKNOWN_OUTCOME'
    notify(ERRORS[code] or 'notify.unknown')
end

-- The vehicle you sit in, or the closest one within reach.
local function target()
    local ped = PlayerPedId()
    local inside = GetVehiclePedIsIn(ped, false)
    if inside ~= 0 then return inside, true end
    local here, best, bestDistance = GetEntityCoords(ped), nil, 5.0
    for _, vehicle in ipairs(GetGamePool('CVehicle')) do
        local distance = #(GetEntityCoords(vehicle) - here)
        if distance < bestDistance then best, bestDistance = vehicle, distance end
    end
    return best, false
end

-- Driving off (or walking away) during the work is blocked; a vehicle that
-- still moves, pushed or rolling, stops the fitting or removal.
local DRIVE = { 59, 60, 63, 64, 71, 72, 76 }
local WALK = { 21, 22, 23, 24, 25, 30, 31 }
local MAX_SPEED, MAX_DISTANCE = 2.0, 6.0

local function hold(vehicle, inside, state)
    CreateThread(function()
        local ped = PlayerPedId()
        local controls = inside and DRIVE or WALK
        while state.running do
            for _, control in ipairs(controls) do DisableControlAction(0, control, true) end
            if not state.moved and (not DoesEntityExist(vehicle) or GetEntitySpeed(vehicle) > MAX_SPEED
                or #(GetEntityCoords(ped) - GetEntityCoords(vehicle)) > MAX_DISTANCE) then
                state.moved = true
                lib.cancelProgress()
            end
            Wait(0)
        end
    end)
end

local function work(vehicle, inside, seconds, label)
    local ped = PlayerPedId()
    local anim = C.installAnim
    local state = { running = true, moved = false }
    hold(vehicle, inside, state)
    if not inside and anim then
        TaskTurnPedToFaceEntity(ped, vehicle, 700)
        Wait(700)
        RequestAnimDict(anim.dict)
        local deadline = GetGameTimer() + 2000
        while not HasAnimDictLoaded(anim.dict) and GetGameTimer() < deadline do Wait(0) end
        if HasAnimDictLoaded(anim.dict) then TaskPlayAnim(ped, anim.dict, anim.clip, 3.0, 3.0, -1, 1, 0.0, false, false, false) end
    end
    local done = not state.moved and lib.progress({ duration = math.floor(seconds * 1000), label = L(label), canCancel = true })
    state.running = false
    if not inside and anim then
        StopAnimTask(ped, anim.dict, anim.clip, 2.0)
        RemoveAnimDict(anim.dict)
    end
    if state.moved then return false, 'moved' end
    return done == true
end

local function install()
    if working then return end
    local vehicle, inside = target()
    if not vehicle then notify('notify.noVehicle'); return end
    if not NetworkGetEntityIsNetworked(vehicle) then notify('notify.notAllowed'); return end
    if not ThrusterClient.allowedVehicle(vehicle) then notify('notify.notAllowed'); return end
    if ThrusterClient.fitted(vehicle) then notify('notify.already'); return end
    if GetEntitySpeed(vehicle) > 1.0 then notify('notify.moving'); return end
    working = true
    local netId = VehToNet(vehicle)
    local check = request('canInstall', { netId = netId })
    if not check.ok then working = false; failed(check); return end
    local done, why = work(vehicle, inside, C.installSeconds, 'progress.install')
    if not done then
        working = false
        if why == 'moved' then notify('notify.interrupted') else notify('notify.cancelled', 'warning') end
        return
    end
    local result = request('install', { netId = netId })
    working = false
    if not result.ok then failed(result); return end
    notify('notify.fitted', 'success')
    F.play(vehicle, 'fitted')
    -- A short pressure test on every nozzle, unless you are about to drive it.
    if not inside then
        F.set(vehicle, LY.MAX & ~LY.GRIP, false)
        SetTimeout(700, function() if DoesEntityExist(vehicle) and ThrusterClient.vehicle ~= vehicle then F.set(vehicle, 0, false) end end)
    end
end

local function remove()
    if working then return end
    local vehicle, inside = target()
    if not vehicle then notify('notify.noVehicle'); return end
    if not NetworkGetEntityIsNetworked(vehicle) or not ThrusterClient.fitted(vehicle) then notify('notify.notFitted'); return end
    if GetEntitySpeed(vehicle) > 1.0 then notify('notify.moving'); return end
    working = true
    local netId = VehToNet(vehicle)
    local check = request('canRemove', { netId = netId })
    if not check.ok then working = false; failed(check); return end
    local done, why = work(vehicle, inside, C.removeSeconds, 'progress.remove')
    if not done then
        working = false
        if why == 'moved' then notify('notify.removeInterrupted') else notify('notify.removeCancelled', 'warning') end
        return
    end
    local result = request('remove', { netId = netId })
    working = false
    if result.ok then notify('notify.removed', 'success') else failed(result) end
end

RegisterNetEvent(RESOURCE .. ':client:install', function() CreateThread(install) end)

if C.command then
    RegisterCommand(C.command, function(_, args)
        local sub = args[1]
        if sub == 'remove' then CreateThread(remove)
        elseif sub == 'help' then ThrusterClient.showLegend(C.legend.seconds or 8)
        elseif sub == 'hud' then
            local right, bottom = tonumber(args[2]), tonumber(args[3])
            if args[2] == 'reset' then ThrusterClient.placeHud(nil, nil)
            elseif right and bottom then ThrusterClient.placeHud(right, bottom)
            else notify('notify.hudUsage', 'info') end
        else CreateThread(install) end
    end, false)
end
