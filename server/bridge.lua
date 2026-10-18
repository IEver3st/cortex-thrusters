-- Framework and inventory adapters: making the kit item usable and taking
-- one when a kit is fitted. Detection runs on use, so start order does not
-- matter. Answers are true (done), false (definitely not) or nil (the
-- inventory did not answer; nothing is assumed).
ThrusterBridge = {}
local B = ThrusterBridge
local RESOURCE = GetCurrentResourceName()
local function started(name) return GetResourceState(name) == 'started' end
local function call(fn, ...)
    local result = table.pack(pcall(fn, ...))
    if not result[1] then return nil end
    return table.unpack(result, 2, result.n)
end

local qb, esx
local function qbCore()
    if not qb and started('qb-core') then qb = call(function() return exports['qb-core']:GetCoreObject() end) end
    return qb
end
local function esxCore()
    if not esx and started('es_extended') then esx = call(function() return exports.es_extended:getSharedObject() end) end
    return esx
end

-- Config.framework: 'standalone' (default) never touches a framework.
function B.framework()
    local wanted = Config.framework or 'standalone'
    if wanted == 'standalone' then return 'standalone' end
    if (wanted == 'auto' or wanted == 'qbx') and started('qbx_core') then return 'qbx' end
    if (wanted == 'auto' or wanted == 'qb') and qbCore() then return 'qb' end
    if (wanted == 'auto' or wanted == 'esx') and esxCore() then return 'esx' end
    return 'standalone'
end

-- Usable item ------------------------------------------------------------------

local registered
function B.registerUsable(name, fn)
    local kind = B.framework()
    if registered == kind then return true end
    local done
    if kind == 'qbx' then done = call(function() exports.qbx_core:CreateUseableItem(name, fn); return true end)
    elseif kind == 'qb' then done = call(function() qb.Functions.CreateUseableItem(name, fn); return true end)
    elseif kind == 'esx' then done = call(function() esx.RegisterUsableItem(name, fn); return true end) end
    if done then registered = kind end
    return done == true
end

function B.releaseUsable(name)
    if registered == 'qbx' and started('qbx_core') then call(function() exports.qbx_core:CreateUseableItem(name, nil) end) end
    registered = nil
end

function B.reset() qb, esx, registered = nil, nil, nil end

-- Inventory --------------------------------------------------------------------

local adapters = {
    ox = {
        ready = function() return started('ox_inventory') end,
        count = function(src, item) return exports.ox_inventory:GetItemCount(src, item) end,
        remove = function(src, item) return exports.ox_inventory:RemoveItem(src, item, 1) end,
    },
    qb = {
        ready = function() return B.framework() == 'qb' end,
        count = function(src, item)
            local player = qb.Functions.GetPlayer(src)
            local found = player and player.Functions.GetItemByName(item)
            return found and found.amount or 0
        end,
        remove = function(src, item)
            local player = qb.Functions.GetPlayer(src)
            return player ~= nil and player.Functions.RemoveItem(item, 1, false, RESOURCE) == true
        end,
    },
    esx = {
        ready = function() return B.framework() == 'esx' end,
        count = function(src, item)
            local player = esx.GetPlayerFromId(src)
            local found = player and player.getInventoryItem(item)
            return found and found.count or 0
        end,
        remove = function(src, item)
            local player = esx.GetPlayerFromId(src)
            if not player then return false end
            local before = adapters.esx.count(src, item)
            player.removeInventoryItem(item, 1)
            return adapters.esx.count(src, item) == before - 1
        end,
    },
}

function B.inventory()
    for _, key in ipairs({ 'ox', 'qb', 'esx' }) do
        if adapters[key].ready() then return key end
    end
    return nil
end

function B.has(src, item)
    local kind = B.inventory()
    if not kind then return nil end
    local amount = call(adapters[kind].count, src, item)
    if amount == nil then return nil end
    return (tonumber(amount) or 0) > 0
end

-- Takes one `item`. nil means the outcome is unknown: the caller fits nothing.
function B.take(src, item)
    local kind = B.inventory()
    if not kind then return nil end
    local has = B.has(src, item)
    if has ~= true then return has end
    local done = call(adapters[kind].remove, src, item)
    if done == nil then return nil end
    return done == true
end
