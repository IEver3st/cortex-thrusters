-- Other drivers' jets. The server copies each driver's firing mask onto the
-- vehicle's `cxThrust` state bag; every nearby client draws it locally. No
-- polling: the change handler does the work, and a slow sweep forgets
-- vehicles that left scope.
local C, F = Config, ThrusterFx
ThrusterRemote = {}

local function near(vehicle, distance)
    local here = GetEntityCoords(PlayerPedId())
    return #(GetEntityCoords(vehicle) - here) <= distance
end

AddStateBagChangeHandler('cxThrust', nil, function(bagName, _, value)
    local vehicle = GetEntityFromStateBagName(bagName)
    if not vehicle or vehicle == 0 or not DoesEntityExist(vehicle) then return end
    -- The local driver draws its own car straight from input.
    if ThrusterClient and vehicle == ThrusterClient.vehicle then return end
    local mask = math.floor(tonumber(value) or 0)
    if mask ~= 0 and not near(vehicle, C.fx.range) then mask = 0 end
    F.set(vehicle, mask, mask == 0 or near(vehicle, C.sounds.range or 60.0))
end)

CreateThread(function()
    while true do
        local any = false
        F.each(function(vehicle)
            any = true
            if ThrusterClient and vehicle == ThrusterClient.vehicle then return end
            if not DoesEntityExist(vehicle) or not near(vehicle, C.fx.range) then F.clear(vehicle) end
        end)
        Wait(any and 1000 or 2500)
    end
end)
