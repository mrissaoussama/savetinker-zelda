-- Flag names, enum labels and actor notes recovered from the game (data/flags.json), loaded on first use.
local M = {}

local loaded

local function numericKeys(source, convert)
    local out = {}
    for key, value in pairs(source or {}) do out[tonumber(key)] = convert and convert(value) or value end
    return out
end

local function load()
    if loaded then return loaded end
    local raw = st.json.decode(st.data("data/flags.json"))
    local names = numericKeys(raw.names)
    local byName = {}
    for hash, name in pairs(names) do byName[name] = hash end
    loaded = {
        names = names,
        byName = byName,
        partial = numericKeys(raw.partial),
        enums = numericKeys(raw.enum, function(labels) return numericKeys(labels) end),
        actors = numericKeys(raw.actor),
        meta = numericKeys(raw.meta),
        bkeys = raw.bkey or {},
    }
    return loaded
end

function M.hash(name)
    local known = load().byName[name]
    return known or st.hash.murmur3(name)
end

-- Recovered name, or "?xxxxxxxx" for hashes whose text is still unknown.
function M.name(hash)
    local data = load()
    return data.names[hash] or data.partial[hash] or string.format("?%08x", hash)
end

function M.known(hash)
    return load().names[hash] ~= nil
end

function M.actor(hash)
    return load().actors[hash]
end

-- Dropdown options for an Enum flag, sorted by label.
function M.enumOptions(hash)
    local labels = load().enums[hash]
    if not labels then return nil end
    local options = {}
    for value, label in pairs(labels) do options[#options + 1] = { value = value, label = label } end
    table.sort(options, function(a, b) return a.label < b.label end)
    return options
end

-- Per-placed-actor keys (Bool64bitKey list), as {key = integer, label = text}.
function M.actorKeys(filter)
    local out = {}
    for key, label in pairs(load().bkeys) do
        if not filter or label:find(filter, 1, true) then
            out[#out + 1] = { key = math.tointeger(tonumber(key:sub(3), 16)), label = label }
        end
    end
    table.sort(out, function(a, b) return a.label < b.label end)
    return out
end

return M
