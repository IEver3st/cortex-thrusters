-- lua tests/server_spec.lua (from the resource root): standalone install,
-- removal, plate memory and the thrust relay against stubbed natives.
local checks = 0
local function ok(cond, what) assert(cond, what); checks = checks + 1 end

local W = { clock = 0, kvp = {}, states = {}, resources = {}, peds = { [1] = 101, [2] = 102 }, seat = {}, logs = {} }
local vehicles = {
    [500] = { type = 'automobile', model = 7, plate = ' TEST 01 ', coords = { x = 0, y = 0, z = 0 } },
    [501] = { type = 'heli', model = 8, plate = 'HELI', coords = { x = 1, y = 0, z = 0 } },
}
local function vec(t) return setmetatable({ x = t.x, y = t.y, z = t.z }, { __sub = function(a, b) return setmetatable({ x = a.x - b.x, y = a.y - b.y, z = a.z - b.z }, { __len = function(v) return math.sqrt(v.x ^ 2 + v.y ^ 2 + v.z ^ 2) end }) end }) end
W.pedCoords = { [101] = { x = 2, y = 0, z = 0 }, [102] = { x = 50, y = 0, z = 0 } }

function GetCurrentResourceName() return 'cortex-thrusters' end
function GetResourceState(name) return W.resources[name] or 'missing' end
function GetGameTimer() return W.clock end
function GetHashKey(s) local h = 0; for i = 1, #s do h = (h * 31 + s:byte(i)) & 0xFFFFFFFF end; return h end
function NetworkGetEntityFromNetworkId(id) return id end
function DoesEntityExist(e) return vehicles[e] ~= nil or W.pedCoords[e] ~= nil end
function GetEntityType(e) return vehicles[e] and 2 or 1 end
function GetVehicleType(e) return vehicles[e].type end
function GetEntityModel(e) return vehicles[e].model end
function GetVehicleNumberPlateText(e) return vehicles[e].plate end
function GetPlayerPed(src) return W.peds[src] or 0 end
function GetEntityCoords(e) return vec(vehicles[e] and vehicles[e].coords or W.pedCoords[e]) end
function GetEntityVelocity(e) local v = vehicles[e].velocity or { x = 0, y = 0, z = 0 }; return setmetatable({ x = v.x, y = v.y, z = v.z }, { __len = function(t) return math.sqrt(t.x ^ 2 + t.y ^ 2 + t.z ^ 2) end }) end
function GetPedInVehicleSeat(e, seat) return W.seat[e] or 0 end
function GetResourceKvpInt(k) return W.kvp[k] or 0 end
function SetResourceKvpInt(k, v) W.kvp[k] = v end
function DeleteResourceKvp(k) W.kvp[k] = nil end
function Entity(e)
    W.states[e] = W.states[e] or {}
    local bag = W.states[e]
    return { state = setmetatable({ set = function(_, key, value) bag[key] = value end }, { __index = bag }) }
end
local handlers, callbacks, exported = {}, {}, {}
function RegisterNetEvent(name, fn) handlers[name] = fn end
function AddEventHandler(name, fn) handlers[name] = fn end
function RegisterCommand() end
function TriggerClientEvent() end
function CreateThread() end
function Wait() end
function exports(name, fn) exported[name] = fn end
function print(...) W.logs[#W.logs + 1] = table.concat({ ... }, ' ') end
lib = { callback = { register = function(name, fn) callbacks[name] = fn end } }
local function fire(name, src, ...) source = src; handlers[name](...) end

dofile('config.lua')
dofile('shared/layout.lua')
dofile('server/bridge.lua')
dofile('server/main.lua')

ok(Config.framework == 'standalone' and Config.requireItem == false, 'standalone by default')
ok(ThrusterBridge.framework() == 'standalone', 'bridge stays standalone')
W.resources.qbx_core = 'started'
ok(ThrusterBridge.framework() == 'standalone', 'a running Qbox is ignored in standalone mode')

local can, install, remove = callbacks['cortex-thrusters:canInstall'], callbacks['cortex-thrusters:install'], callbacks['cortex-thrusters:remove']
ok(can(1, { netId = 501 }).error.code == 'VEHICLE', 'helicopters refused')
W.clock = 1000
ok(can(2, { netId = 500 }).error.code == 'TOO_FAR', 'out of reach refused')
ok(can(1, { netId = 'x' }).error.code == 'VEHICLE', 'malformed net id refused')
W.clock = 2000
ok(can(1, { netId = 500 }).ok, 'standalone player may start fitting')
W.clock = 2600
vehicles[500].velocity = { x = 0, y = 4, z = 0 }
ok(can(1, { netId = 500 }).error.code == 'MOVING', 'a moving vehicle is refused')
vehicles[500].velocity = nil
W.clock = 3100
ok(install(1, { netId = 500 }).error.code == 'NOT_ALLOWED', 'fitting faster than the work time refused')
W.clock = 4000
ok(can(1, { netId = 500 }).ok, 'start again')
W.clock = 4000 + Config.installSeconds * 1000
ok(install(1, { netId = 500 }).ok, 'fitted after the work time')
ok(W.states[500].cxThrusters == true, 'state bag set')
ok(W.kvp['plate:TEST 01'] == 1, 'plate remembered, trimmed and upper case')
W.clock = W.clock + 2000
ok(can(1, { netId = 500 }).error.code == 'ALREADY', 'no second kit')

-- Thrust relay: driver only, bounded mask.
local thrust = 'cortex-thrusters:server:thrust'
fire(thrust, 1, 500, 0x0F)
ok(W.states[500].cxThrust == nil, 'a non-driver cannot fire')
W.seat[500] = 101
fire(thrust, 1, 500, 0x0F)
ok(W.states[500].cxThrust == 0x0F, 'driver mask relayed')
fire(thrust, 1, 500, 0x2000)
fire(thrust, 1, 500, -1)
fire(thrust, 1, 500, 1.5)
ok(W.states[500].cxThrust == 0x0F, 'out-of-range masks ignored')
for _ = 1, 40 do fire(thrust, 1, 500, 0xF0) end
fire(thrust, 1, 500, 0)
ok(W.states[500].cxThrust == 0xF0, 'flood is cut off by the bucket')
W.clock = W.clock + 1000
fire(thrust, 1, 500, 0)
ok(W.states[500].cxThrust == 0, 'bucket refills')
fire(thrust, 1, 500, 0x100)
handlers.playerDropped(); -- source is still 1
ok(W.states[500].cxThrust == 0, 'dropping clears the jets')

-- Remembered kit comes back on a fresh entity with the same plate.
W.states[500] = {}
W.clock = W.clock + 2000
fire('cortex-thrusters:server:check', 1, 500)
ok(W.states[500].cxThrusters == true, 'kit restored from plate')

-- Anyone in reach takes a kit off, once the removal work has taken its time.
local canRemove = callbacks['cortex-thrusters:canRemove']
W.clock = W.clock + 2000
ok(canRemove(2, { netId = 500 }).error.code == 'TOO_FAR', 'out of reach cannot remove')
vehicles[500].velocity = { x = 0, y = 4, z = 0 }
ok(canRemove(1, { netId = 500 }).error.code == 'MOVING', 'a moving vehicle is not stripped')
vehicles[500].velocity = nil
W.clock = W.clock + 2000
ok(remove(1, { netId = 500 }).error.code == 'NOT_ALLOWED', 'removing without starting the work refused')
W.clock = W.clock + 2000
ok(canRemove(1, { netId = 500 }).ok, 'player may start removing')
W.clock = W.clock + Config.removeSeconds * 500
ok(remove(1, { netId = 500 }).error.code == 'NOT_ALLOWED', 'removing faster than the work time refused')
ok(W.states[500].cxThrusters == true, 'kit still on')
W.clock = W.clock + 2000
ok(canRemove(1, { netId = 500 }).ok, 'start again')
W.clock = W.clock + Config.removeSeconds * 1000
ok(remove(1, { netId = 500 }).ok, 'removed after the work time')
ok(W.states[500].cxThrusters == nil and W.kvp['plate:TEST 01'] == nil, 'state and plate cleared')
W.clock = W.clock + 2000
ok(canRemove(1, { netId = 500 }).error.code == 'NOT_FITTED', 'nothing left to remove')
W.clock = W.clock + 1000
ok(can(1, { netId = 500 }).ok, 'the vehicle takes a kit again')
exported.setFitted(500, true) -- someone else fits it meanwhile
W.clock = W.clock + Config.removeSeconds * 1000
ok(remove(1, { netId = 500 }).error.code == 'NOT_ALLOWED', 'a fitting job does not count as a removal')
io.write(('server_spec: %d checks passed\n'):format(checks))
