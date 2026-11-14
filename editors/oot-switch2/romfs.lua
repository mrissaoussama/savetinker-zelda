-- Read-only access to the game's own files: zstd with the game's dictionaries, SARC packs, BYML and MSBT.
-- Everything is cached for the life of the editor, so pages only pay once.
local M = {}

local cache = { packs = {}, archives = {}, messages = {} }

local function dictionaries()
    if not cache.dictionaries then
        local list = {}
        local pack = st.format.sarc(st.zstd.decompress(st.game_data.read("Pack/ZsDic.pack.zs")))
        for name, data in pairs(pack) do
            if name:find("%.zsdic$") then list[#list + 1] = data end
        end
        cache.dictionaries = list
    end
    return cache.dictionaries
end

function M.read(path)
    local data = st.game_data.read(path)
    if data:sub(1, 4) == "\x28\xB5\x2F\xFD" then data = st.zstd.decompress(data, dictionaries()) end
    return data
end

-- Newest file per stem in a folder: "EUen.Product.110.sarc.zs" beats "EUen.Product.sarc.zs".
local function newest(folder, suffix)
    local best = {}
    for _, entry in ipairs(st.game_data.list(folder)) do
        if not entry.directory and entry.name:sub(-#suffix) == suffix then
            local stem = entry.name:match("^([^.]+)")
            local version = tonumber(entry.name:match("%.(%d%d%d)%.") or "0")
            if not best[stem] or version > best[stem].version then best[stem] = { version = version, name = entry.name } end
        end
    end
    return best
end

function M.languages()
    if not cache.languages then
        local list = {}
        for stem, file in pairs(newest("Mals", ".sarc.zs")) do list[#list + 1] = { code = stem, file = "Mals/" .. file.name } end
        table.sort(list, function(a, b) return a.code < b.code end)
        cache.languages = list
    end
    return cache.languages
end

function M.messageArchive(language)
    if not cache.archives[language] then
        for _, entry in ipairs(M.languages()) do
            if entry.code == language then cache.archives[language] = st.format.sarc(M.read(entry.file)) end
        end
    end
    return cache.archives[language] or {}
end

function M.messageFiles(language)
    local names = {}
    for name in pairs(M.messageArchive(language)) do
        if name:find("%.msbt$") then names[#names + 1] = name:sub(1, -6) end
    end
    table.sort(names)
    return names
end

-- Turns control tags into readable text: page breaks become new lines, variables [Name], plurals {one/many}.
function M.cleanMessage(raw)
    local out, position = {}, 1
    while position <= #raw do
        local byte = raw:byte(position)
        if byte == 0x0E and position + 6 <= #raw then
            local group, kind, size = string.unpack("<I2I2I2", raw, position + 1)
            local data = raw:sub(position + 7, position + 6 + size)
            if group == 0 and kind == 4 then
                out[#out + 1] = "\n"
            elseif group == 2 and #data >= 2 then
                local length = string.unpack("<I2", data)
                out[#out + 1] = "[" .. data:sub(3, 2 + length) .. "]"
            elseif group == 201 and kind == 6 then
                local forms, at = {}, 1
                while at + 1 <= #data do
                    local length = string.unpack("<I2", data, at)
                    if length == 0 then break end
                    forms[#forms + 1] = data:sub(at + 2, at + 1 + length)
                    at = at + 2 + length
                end
                if #forms > 0 then out[#out + 1] = "{" .. table.concat(forms, "/") .. "}" end
            end
            position = position + 7 + size
        elseif byte == 0x0F then
            position = position + 5
        else
            local next = raw:find("[\x0E\x0F]", position) or #raw + 1
            out[#out + 1] = raw:sub(position, next - 1)
            position = next
        end
    end
    return table.concat(out)
end

function M.messages(language, file)
    local key = language .. "/" .. file
    if not cache.messages[key] then
        local data = M.messageArchive(language)[file .. ".msbt"]
        local list = {}
        if data then
            for label, raw in pairs(st.format.msbt(data, true)) do list[#list + 1] = { label = label, text = M.cleanMessage(raw) } end
            table.sort(list, function(a, b) return a.label < b.label end)
        end
        cache.messages[key] = list
    end
    return cache.messages[key]
end

function M.actors()
    if not cache.actors then
        local list = {}
        for _, entry in ipairs(st.game_data.list("Pack/Actor")) do
            local name = entry.name:match("^(.-)%.pack%.zs$")
            if name then list[#list + 1] = name end
        end
        table.sort(list)
        cache.actors = list
    end
    return cache.actors
end

function M.actorPack(actor)
    if not cache.packs[actor] then cache.packs[actor] = st.format.sarc(M.read("Pack/Actor/" .. actor .. ".pack.zs")) end
    return cache.packs[actor]
end

function M.packDocument(pack, pattern)
    for path, data in pairs(pack) do
        if path:find(pattern) and data:sub(1, 2) == "YB" then
            local document = st.format.byml(data)
            local parent = type(document) == "table" and document["$parent"]
            if type(parent) == "string" then
                local parentPath = parent:gsub("^Work/", ""):gsub("%.gyml$", ".bgyml")
                local base = pack[parentPath] and st.format.byml(pack[parentPath])
                if type(base) == "table" then
                    for key, value in pairs(document) do base[key] = value end
                    document = base
                end
            end
            return document, path
        end
    end
end

return M
