-- Locales: flat-key JSON in locales/<code>.json, loaded on client and server.
-- The active language is Config.Locale, or the cortex_thrusters_locale convar
-- when set. Missing keys fall back to English, then to the key itself.
--   L('notify.empty')  ->  'Cold gas empty. Recharging.'

Locale = {}

local RESOURCE = GetCurrentResourceName()
local fallback, active = {}, {}

local function read(code)
    if type(code) ~= 'string' or not code:match('^[%a%-]+$') then return nil end
    local raw = LoadResourceFile(RESOURCE, ('locales/%s.json'):format(code))
    if not raw then return nil end
    local ok, data = pcall(json.decode, raw)
    if not ok or type(data) ~= 'table' then
        print(('^3[cortex-thrusters]^0 locales/%s.json is not valid JSON; using English.'):format(code))
        return nil
    end
    return data
end

function Locale.code()
    local convar = GetConvar('cortex_thrusters_locale', '')
    if convar ~= '' then return convar end
    return (Config and Config.Locale) or 'en'
end

function Locale.load()
    fallback = read('en') or {}
    local code = Locale.code()
    active = code == 'en' and fallback or (read(code) or fallback)
    if active == fallback and code ~= 'en' then
        print(('^3[cortex-thrusters]^0 No locale "%s"; using English.'):format(code))
    end
end

function L(key, vars)
    local text = active[key] or fallback[key] or key
    if vars then
        text = text:gsub('{(%w+)}', function(name)
            local value = vars[name]
            if value == nil then return '{' .. name .. '}' end
            return tostring(value)
        end)
    end
    return text
end

-- Every string, active language over English, for the NUI.
function Locale.all()
    local merged = {}
    for key, value in pairs(fallback) do merged[key] = value end
    for key, value in pairs(active) do merged[key] = value end
    return merged
end

Locale.load()
