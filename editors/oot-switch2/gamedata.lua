-- GameData save files (progress.sav, option.sav, caption.sav, account.sav).
--   0x00 u32 magic 0x01020304, 0x08 u32 start of the data area
--   0x20 (u32 name hash, u32 value) pairs; hash 0 starts a section whose value is the type index.
--   Bool/Int/UInt/Float/Enum are stored inline, everything else is an offset into the data area.
local db = require("db")

local M = {}

local TYPES = { "Bool", "BoolArray", "Int", "IntArray", "Float", "FloatArray", "Enum", "EnumArray", "Vector2",
    "Vector2Array", "Vector3", "Vector3Array", "String16", "String16Array", "String32", "String32Array", "String64",
    "String64Array", "Binary", "BinaryArray", "UInt", "UIntArray", "Int64", "Int64Array", "UInt64", "UInt64Array",
    "WString16", "WString16Array", "WString32", "WString32Array", "WString64", "WString64Array", "Bool64bitKey" }

local STRINGS = {
    String16 = { 16, "utf8" }, String32 = { 32, "utf8" }, String64 = { 64, "utf8" },
    WString16 = { 16, "utf16le" }, WString32 = { 32, "utf16le" }, WString64 = { 64, "utf16le" },
}
local ARRAYS = {
    IntArray = { "s32", 4 }, UIntArray = { "u32", 4 }, FloatArray = { "f32", 4 }, EnumArray = { "u32", 4 },
    Int64Array = { "s64", 8 }, UInt64Array = { "u64", 8 },
}
M.MAGIC = 0x01020304

local Save = {}
Save.__index = Save
local cache = {}

-- Parses the hash table once per file; values are always read live from the document.
function M.open(save, path)
    if not save:has(path) then return nil end
    local file = save:file(path)
    if file:size() < 0x20 or file:u32(0) ~= M.MAGIC then return nil end
    local dataStart = file:u32(8)
    local cached = cache[path]
    if cached and cached.dataStart == dataStart then
        cached.file = file
        return cached
    end
    local blob = file:bytes(0x20, dataStart - 0x20)
    local entries, order, kind = {}, {}, nil
    for position = 1, #blob - 7, 8 do
        local hash, value = string.unpack("<I4I4", blob, position)
        if hash == 0 then
            kind = TYPES[value + 1] or ("type" .. value)
        else
            entries[hash] = { hash = hash, type = kind, offset = 0x20 + position - 1 }
            order[#order + 1] = hash
        end
    end
    local result = setmetatable({ file = file, path = path, dataStart = dataStart, entries = entries, order = order }, Save)
    cache[path] = result
    return result
end

function Save:entry(nameOrHash)
    local hash = type(nameOrHash) == "number" and nameOrHash or db.hash(nameOrHash)
    return self.entries[hash]
end

function Save:pointer(entry)
    return self.file:u32(entry.offset + 4)
end

-- Entries whose recovered name matches a Lua pattern, sorted by name.
function Save:find(pattern)
    local found = {}
    for _, hash in ipairs(self.order) do
        local name = db.name(hash)
        if name:find(pattern) then found[#found + 1] = { name = name, entry = self.entries[hash] } end
    end
    table.sort(found, function(a, b) return a.name < b.name end)
    return found
end

function Save:get(entryOrName)
    local entry = type(entryOrName) == "table" and entryOrName or self:entry(entryOrName)
    if not entry then return nil end
    local file, kind = self.file, entry.type
    local raw = file:u32(entry.offset + 4)
    if kind == "Bool" then return raw ~= 0 end
    if kind == "Int" then return file:s32(entry.offset + 4) end
    if kind == "UInt" then return raw end
    if kind == "Float" then return file:f32(entry.offset + 4) end
    if kind == "Enum" then
        for _, option in ipairs(db.enumOptions(entry.hash) or {}) do
            if option.value == raw then return option.label end
        end
        return string.format("0x%08x", raw)
    end
    local text = STRINGS[kind]
    if text then return file:str(raw, text[1], text[2]) end
    if kind == "Int64" then return file:s64(raw) end
    if kind == "UInt64" then return file:u64(raw) end
    if kind == "Vector3" then return { file:f32(raw), file:f32(raw + 4), file:f32(raw + 8) } end
    if ARRAYS[kind] or kind == "BoolArray" then return string.format("%d values", file:u32(raw)) end
    if kind == "Bool64bitKey" then return string.format("%d keys", #self:actorKeys()) end
    return string.format("%s, %d bytes", kind, file:u32(raw))
end

function Save:isSet(entry)
    local value = self:get(entry)
    return value ~= false and value ~= 0 and value ~= "" and value ~= "None" and value ~= "Empty" and value ~= "0x00000000"
end

-- Writes a scalar by name. Missing flags are ignored, so one action can cover several game versions.
function Save:set(name, value)
    local entry = self:entry(name)
    if not entry then return false end
    local file, kind = self.file, entry.type
    if kind == "Bool" then file:set(entry.offset + 4, "u32", value and 1 or 0)
    elseif kind == "Int" then file:set(entry.offset + 4, "s32", value)
    elseif kind == "UInt" or kind == "Enum" then file:set(entry.offset + 4, "u32", value)
    elseif kind == "Float" then file:set(entry.offset + 4, "f32", value)
    elseif STRINGS[kind] then
        file:setStr(self:pointer(entry), STRINGS[kind][1] - 1, value, STRINGS[kind][2])
    elseif kind == "Vector3" then
        local at = self:pointer(entry)
        for i = 1, 3 do file:set(at + (i - 1) * 4, "f32", value[i]) end
    else
        error("cannot set " .. kind .. " values directly")
    end
    return true
end

-- Per-placed-actor keys: a sorted, zero-terminated u64 list that must stay at the end of the file.
function Save:actorKeyEntry()
    for _, hash in ipairs(self.order) do
        if self.entries[hash].type == "Bool64bitKey" then return self.entries[hash] end
    end
end

function Save:actorKeys()
    local entry = self:actorKeyEntry()
    if not entry then return {} end
    local keys, at = {}, self:pointer(entry)
    while at + 8 <= self.file:size() do
        local key = self.file:u64(at)
        if key == 0 then break end
        keys[#keys + 1] = key
        at = at + 8
    end
    return keys
end

function Save:hasActorKey(key)
    for _, existing in ipairs(self:actorKeys()) do
        if existing == key then return true end
    end
    return false
end

function Save:setActorKey(key, on)
    local entry = self:actorKeyEntry()
    if not entry then error("this save has no actor key list") end
    local start = self:pointer(entry)
    local keys = self:actorKeys()
    if start + 8 * (#keys + 1) ~= self.file:size() then error("actor key list is not at the end of the file") end
    local set = {}
    for _, existing in ipairs(keys) do set[existing] = true end
    set[key] = on or nil
    local sorted = {}
    for existing in pairs(set) do sorted[#sorted + 1] = existing end
    table.sort(sorted, math.ult)
    local parts = {}
    for i, existing in ipairs(sorted) do parts[i] = string.pack("<I8", existing) end
    parts[#parts + 1] = string.pack("<I8", 0)
    self.file:splice(start, self.file:size() - start, table.concat(parts))
end

local function label(name, hash, prefix)
    local text = prefix and name:sub(#prefix + 1) or name
    local actor = db.actor(hash)
    return text, actor
end

-- Adds the right widget for a flag. `options.label` overrides the name, `options.prefix` is stripped from it.
function Save:widget(page, entry, options)
    options = options or {}
    local name = db.name(entry.hash)
    local text, actor = label(name, entry.hash, options.prefix)
    text = options.label or text
    local help = options.help or actor
    local file, kind, at = self.file, entry.type, entry.offset + 4
    local spec = { label = text, help = help, key = name, readonly = options.readonly, min = options.min,
        max = options.max, step = options.step, actions = options.actions, on_change = options.on_change }

    if kind == "Bool" then
        spec.bind, spec.on, spec.off = file:field(at, "u32"), 1, 0
        return page:toggle(spec)
    elseif kind == "Int" or kind == "UInt" then
        spec.bind = file:field(at, kind == "Int" and "s32" or "u32")
        return page:int(spec)
    elseif kind == "Float" then
        spec.bind = file:field(at, "f32")
        return page:float(spec)
    elseif kind == "Enum" then
        spec.bind = file:field(at, "u32")
        local choices = db.enumOptions(entry.hash)
        if choices then
            spec.options = choices
            return page:dropdown(spec)
        end
        spec.format = "hex"
        return page:int(spec)
    end

    local pointer = self:pointer(entry)
    if STRINGS[kind] then
        local size, encoding = STRINGS[kind][1], STRINGS[kind][2]
        spec.bind = file:text(pointer, size - 1, encoding)
        return page:text(spec)
    elseif kind == "Int64" or kind == "UInt64" then
        spec.bind = file:field(pointer, kind == "Int64" and "s64" or "u64")
        return page:int(spec)
    elseif kind == "Vector3" then
        return page:section({ title = text, help = help, key = name }, function(section)
            for i, axis in ipairs({ "X", "Y", "Z" }) do
                section:float{ label = axis, bind = file:field(pointer + (i - 1) * 4, "f32"), key = name .. axis }
            end
        end)
    elseif ARRAYS[kind] then
        local count = file:u32(pointer)
        local element = ARRAYS[kind]
        return page:page({ title = string.format("%s (%d)", text, count), key = name }, function(list)
            if help then list:note(help) end
            local choices = kind == "EnumArray" and db.enumOptions(entry.hash)
            for i = 1, math.min(count, 300) do
                local bind = file:field(pointer + 4 + (i - 1) * element[2], element[1])
                local item = { label = string.format("[%d]", i - 1), bind = bind, key = name .. i }
                if choices then
                    item.options = choices
                    list:dropdown(item)
                elseif kind == "FloatArray" then
                    list:float(item)
                else
                    list:int(item)
                end
            end
            if count > 300 then list:note(string.format("%d more values not shown", count - 300)) end
        end)
    end
    return page:label{ label = text, value = tostring(self:get(entry)), help = help, key = name }
end

return M
