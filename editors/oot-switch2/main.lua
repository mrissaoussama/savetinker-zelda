local gamedata = require("gamedata")
local db = require("db")
local romfs = require("romfs")

local PAGE_SIZE = 25

function detect(save)
    for _, name in ipairs(save:files()) do
        if name:match("progress%.sav$") and save:file(name):u32(0) == gamedata.MAGIC then return true end
    end
    return false
end

local function slots(save)
    local list = {}
    for _, name in ipairs(save:files()) do
        local slot = name:match("^(slot_%d+)/progress%.sav$")
        if slot then list[#list + 1] = slot end
    end
    table.sort(list)
    return list
end

local function hearts(value) return string.format("%g hearts", value / 16) end

-- Overview -----------------------------------------------------------------------------------------------------

local function overview(page, progress, caption)
    if caption then
        page:section("Slot card (caption.sav)", function(card)
            for _, field in ipairs({ "LocationName", "Date", "IsAutoSave", "IsClear", "GoldToken" }) do
                local entry = caption:entry("CaptionData." .. field)
                if entry then caption:widget(card, entry, { label = field }) end
            end
            card:note("The slot card is what the game's save menu shows. It is a separate file: editing progress does not update it.")
        end)
    end

    local life, maxLife = progress:entry("PlayerStatus.Life"), progress:entry("PlayerStatus.MaxLife")
    page:section("Health and magic", function(section)
        if maxLife then
            progress:widget(section, maxLife, {
                label = "Max life", min = 16, max = 320, step = 16, help = hearts(progress:get(maxLife)),
                actions = { { label = "20 hearts", run = function() progress:set("PlayerStatus.MaxLife", 320) end } },
            })
        end
        if life then
            progress:widget(section, life, {
                label = "Life", min = 0, max = maxLife and progress:get(maxLife) or 320, step = 4,
                help = hearts(progress:get(life)),
                actions = { { label = "Refill", run = function() progress:set("PlayerStatus.Life", progress:get(maxLife)) end } },
            })
        end
        for _, item in ipairs({ { "PlayerStatus.MPMax", "Max magic" }, { "PlayerStatus.MP", "Magic" } }) do
            local entry = progress:entry(item[1])
            if entry then progress:widget(section, entry, { label = item[2], min = 0, max = 96, step = 48 }) end
        end
    end)

    page:section("Collection", function(section)
        for _, item in ipairs({
            { "PlayerStatus.CurrentRupee", "Rupees", 999 },
            { "PouchData.Obj_Heart_Piece.StockNum", "Heart pieces", 3 },
            { "PouchData.Item_Token_Gold.StockNum", "Gold Skulltula tokens", 100 },
        }) do
            local entry = progress:entry(item[1])
            if entry then
                progress:widget(section, entry, { label = item[2], min = 0, max = item[3],
                    actions = { { label = "Max", run = function() progress:set(item[1], item[3]) end } } })
            end
        end
    end)

    page:section("Equipment", function(section)
        for _, item in ipairs({ { "EquipWeapon", "Sword" }, { "EquipShield", "Shield" }, { "EquipArmor", "Tunic" },
            { "EquipBoot", "Boots" }, { "EquipOcarina", "Ocarina" } }) do
            local entry = progress:entry("PlayerStatus." .. item[1])
            if entry then progress:widget(section, entry, { label = item[2] }) end
        end
        local strength = progress:entry("PlayerStatus.LiftGrade")
        if strength then progress:widget(section, strength, { label = "Strength" }) end
    end)
end

-- Grouped flag pages ---------------------------------------------------------------------------------------------

local function flagList(page, progress, pattern, prefix)
    local found = progress:find(pattern)
    if #found == 0 then page:note("Nothing in this save.") end
    for _, item in ipairs(found) do progress:widget(page, item.entry, { prefix = prefix }) end
end

local function items(page, progress)
    local groups, order = {}, {}
    for _, item in ipairs(progress:find("^PouchData%.")) do
        local name, field = item.name:match("^PouchData%.([^.]+)%.(.+)$")
        if name then
            if not groups[name] then groups[name] = {}; order[#order + 1] = name end
            table.insert(groups[name], { field = field, entry = item.entry })
        end
    end
    local filter = page:state("item-filter", "Item")
    page:segmented{ label = "Show", bind = filter, options = {
        { value = "Item", label = "Items" }, { value = "Weapon", label = "Weapons" },
        { value = "Armor", label = "Armor" }, { value = "", label = "All" } } }
    for _, name in ipairs(order) do
        if filter:get() == "" or name:find("^" .. filter:get()) then
            local got = progress:entry("IsGet." .. name)
            page:section({ title = name, key = name, collapsed = not (got and progress:get(got)) }, function(section)
                if got then progress:widget(section, got, { label = "Obtained" }) end
                for _, field in ipairs(groups[name]) do progress:widget(section, field.entry, { label = field.field }) end
            end)
        end
    end
end

local function songs(page, progress)
    local found = {}
    for _, kind in ipairs({ "Melody", "Medal", "Stone" }) do
        for _, item in ipairs(progress:find("^IsGet%.Item_" .. kind .. "_")) do found[#found + 1] = item end
    end
    page:section({ title = "Songs, medallions and stones", actions = {
        { label = "Get all", run = function() for _, item in ipairs(found) do progress:set(item.entry.hash, true) end end },
    } }, function(section)
        for _, item in ipairs(found) do progress:widget(section, item.entry, { prefix = "IsGet.Item_" }) end
    end)
end

local function dungeons(page, progress)
    local groups, order = {}, {}
    for _, item in ipairs(progress:find("^DungeonInfo%.")) do
        local dungeon, field = item.name:match("^DungeonInfo%.([^.]+)%.(.+)$")
        if dungeon then
            if not groups[dungeon] then groups[dungeon] = {}; order[#order + 1] = dungeon end
            table.insert(groups[dungeon], { field = field, entry = item.entry })
        end
    end
    for _, dungeon in ipairs(order) do
        page:page(dungeon, function(section)
            section:section({ title = dungeon, actions = { { label = "Map, compass and boss key", run = function()
                for _, field in ipairs({ "IsGetMap", "IsGetCompass", "IsGetBossKey" }) do
                    progress:set("DungeonInfo." .. dungeon .. "." .. field, true)
                end
            end } } }, function(fields)
                for _, field in ipairs(groups[dungeon]) do progress:widget(fields, field.entry, { label = field.field }) end
            end)
            local rooms = progress:find("^DungeonRoomStep%." .. dungeon .. "%.")
            if #rooms > 0 then
                section:page(string.format("Rooms (%d)", #rooms), function(list)
                    for _, item in ipairs(rooms) do progress:widget(list, item.entry, { prefix = "DungeonRoomStep." .. dungeon .. "." }) end
                end)
            end
        end)
    end
end

-- Flags tied to placed actors (chests), grouped by the scene they sit in.
local function byScene(page, progress, pattern, prefix, onLabel)
    local scenes, order = {}, {}
    for _, item in ipairs(progress:find(pattern)) do
        local note = db.actor(item.entry.hash) or ""
        local scene = note:match("@ ([^_%s]+)") or "Unknown place"
        if not scenes[scene] then scenes[scene] = {}; order[#order + 1] = scene end
        table.insert(scenes[scene], item)
    end
    table.sort(order)
    for _, scene in ipairs(order) do
        local list = scenes[scene]
        local open = 0
        for _, item in ipairs(list) do if progress:get(item.entry) then open = open + 1 end end
        page:section({ title = string.format("%s  %d/%d", scene, open, #list), key = scene, collapsed = true, actions = {
            { label = onLabel, run = function() for _, item in ipairs(list) do progress:set(item.entry.hash, true) end end },
            { label = "Reset", run = function() for _, item in ipairs(list) do progress:set(item.entry.hash, false) end end },
        } }, function(section)
            for _, item in ipairs(list) do
                local actor = (db.actor(item.entry.hash) or ""):match("^(%S+)") or item.name:sub(#prefix + 1)
                progress:widget(section, item.entry, { label = actor })
            end
        end)
    end
end

local function skulltulas(page, progress)
    if not progress:actorKeyEntry() then return page:note("This save has no actor key list.") end
    local scenes, order, total, defeated = {}, {}, 0, 0
    for _, key in ipairs(db.actorKeys("Skulltula_Gold")) do
        local scene = key.label:match("@ ([%w_]-)_[SD][ty][an][ta][im]") or key.label:match("@ (%S+)") or "?"
        if not scenes[scene] then scenes[scene] = {}; order[#order + 1] = scene end
        key.on = progress:hasActorKey(key.key)
        table.insert(scenes[scene], key)
        total = total + 1
        if key.on then defeated = defeated + 1 end
    end
    table.sort(order)
    page:label{ label = "Defeated", value = string.format("%d / %d", defeated, total) }
    page:note("Each Gold Skulltula is stored as a key at the end of the file. Changing them resizes progress.sav.")
    for _, scene in ipairs(order) do
        local list = scenes[scene]
        local count = 0
        for _, key in ipairs(list) do if key.on then count = count + 1 end end
        page:section({ title = string.format("%s  %d/%d", scene, count, #list), key = scene, collapsed = true, actions = {
            { label = "Defeat all", run = function() for _, key in ipairs(list) do progress:setActorKey(key.key, true) end end },
        } }, function(section)
            for i, key in ipairs(list) do
                section:toggle{ label = string.format("%s #%d", "Gold Skulltula", i), key = tostring(key.key),
                    help = key.label,
                    bind = st.bind(function() return progress:hasActorKey(key.key) end,
                        function(on) progress:setActorKey(key.key, on) end) }
            end
        end)
    end
end

local function story(page, progress)
    page:section("Story steps", function(section) flagList(section, progress, "^Step_", "Step_") end)
    page:section("Current place", function(section) flagList(section, progress, "^Sequence_", nil) end)
    page:page("Visited places", function(list) flagList(list, progress, "^IsVisitLocation%.", "IsVisitLocation.") end)
end

-- Spawn point: picking a map changes which spawn points are offered.
local spawns
local function spawnPoint(page, progress)
    spawns = spawns or st.json.decode(st.data("data/spawns.json"))
    local maps = {}
    for map in pairs(spawns) do maps[#maps + 1] = map end
    table.sort(maps)
    local current = progress:get("Sequence_CurrentBanc")
    page:label{ label = "Current map", value = tostring(current) }
    local map = page:state("spawn-map", spawns[current] and current or maps[1])
    local point = page:state("spawn-point", 1)
    local options = {}
    for i, name in ipairs(maps) do options[i] = { value = name, label = name } end
    page:dropdown{ label = "Map", bind = map, options = options, on_change = function() point:set(1) end }
    local points = spawns[map:get()] or {}
    local pointOptions = {}
    for i, entry in ipairs(points) do pointOptions[i] = { value = i, label = entry.name } end
    if #pointOptions > 0 then page:dropdown{ label = "Spawn point", bind = point, options = pointOptions } end
    local chosen = points[point:get()]
    if chosen then
        page:label{ label = "Position", value = string.format("%.1f, %.1f, %.1f", chosen.pos[1], chosen.pos[2], chosen.pos[3]) }
        page:button{ label = "Start here", run = function()
            local degrees = (math.deg(chosen.yaw) + 360) % 360 - 180
            progress:set("Sequence_CurrentBanc", map:get())
            progress:set("PlayerStatus.SavePos", chosen.pos)
            progress:set("PlayerStatus.SavePosRadY", chosen.yaw)
            progress:set("Player_Pos_For_Map", chosen.pos)
            progress:set("Player_Rot_For_Map", degrees)
        end }
    end
    page:page("Manual position", function(manual)
        for _, name in ipairs({ "Sequence_CurrentBanc", "PlayerStatus.SavePos", "PlayerStatus.SavePosRadY" }) do
            local entry = progress:entry(name)
            if entry then progress:widget(manual, entry) end
        end
    end)
end

-- Every flag, searchable ----------------------------------------------------------------------------------------

local function allFlags(page, file, stateKey)
    local query = page:state(stateKey .. "-query", "")
    local onlySet = page:state(stateKey .. "-set", false)
    local named = page:state(stateKey .. "-named", false)
    local offset = page:state(stateKey .. "-page", 0)
    page:text{ label = "Search", bind = query, max_length = 64, on_change = function() offset:set(0) end }
    page:toggle{ label = "Only flags that are set", bind = onlySet, on_change = function() offset:set(0) end }
    page:toggle{ label = "Only named flags", bind = named, on_change = function() offset:set(0) end }

    local words = {}
    for word in query:get():lower():gmatch("%S+") do words[#words + 1] = word end
    local matches = {}
    for _, hash in ipairs(file.order) do
        local name = db.name(hash)
        local lower = name:lower()
        local ok = not named:get() or db.known(hash)
        for _, word in ipairs(words) do
            if ok and not lower:find(word, 1, true) then ok = false end
        end
        if ok and (not onlySet:get() or file:isSet(file.entries[hash])) then matches[#matches + 1] = { name = name, hash = hash } end
    end
    table.sort(matches, function(a, b) return a.name < b.name end)

    local first = offset:get() * PAGE_SIZE + 1
    local last = math.min(#matches, first + PAGE_SIZE - 1)
    page:label{ label = "Matches", value = #matches == 0 and "0" or string.format("%d-%d / %d", first, last, #matches) }
    for i = first, last do file:widget(page, file.entries[matches[i].hash]) end
    if offset:get() > 0 then page:button{ label = "Previous page", run = function() offset:set(offset:get() - 1) end } end
    if last < #matches then page:button{ label = "Next page", run = function() offset:set(offset:get() + 1) end } end
end

-- Game files (read only) -----------------------------------------------------------------------------------------

local function showValue(page, key, value, depth)
    if type(value) ~= "table" then
        page:label{ label = tostring(key), value = tostring(value) }
        return
    end
    page:page({ title = tostring(key), key = tostring(key) .. "#" .. depth }, function(child)
        local keys = {}
        for k in pairs(value) do keys[#keys + 1] = k end
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
        for i, k in ipairs(keys) do
            if i > 200 then child:note(string.format("%d more entries not shown", #keys - 200)); break end
            showValue(child, k, value[k], depth + 1)
        end
    end)
end

local function dialogue(page)
    local languages = romfs.languages()
    if #languages == 0 then return page:note("No message archives found.") end
    local options = {}
    for i, entry in ipairs(languages) do options[i] = { value = entry.code, label = entry.code } end
    local preferred = "EUen"
    for _, entry in ipairs(languages) do if entry.code:sub(3) == st.lang then preferred = entry.code end end
    local language = page:state("dialogue-language", preferred)
    page:dropdown{ label = "Language", bind = language, options = options }
    local query = page:state("dialogue-query", "Npc")
    page:text{ label = "File name contains", bind = query, max_length = 48 }

    local shown = 0
    for _, file in ipairs(romfs.messageFiles(language:get())) do
        if file:lower():find(query:get():lower(), 1, true) then
            shown = shown + 1
            if shown > 60 then page:note("More files match; refine the search."); break end
            page:page({ title = file:gsub("^EventFlowMsg/", ""), key = file }, function(messages)
                for _, message in ipairs(romfs.messages(language:get(), file)) do
                    messages:note(message.label .. "\n" .. message.text)
                end
            end)
        end
    end
end

local function actors(page)
    local query = page:state("actor-query", "Enemy_Dekubaba")
    page:text{ label = "Actor name contains", bind = query, max_length = 48 }
    local shown = 0
    for _, actor in ipairs(romfs.actors()) do
        if actor:lower():find(query:get():lower(), 1, true) then
            shown = shown + 1
            if shown > 40 then page:note("More actors match; refine the search."); break end
            page:page({ title = actor, key = actor }, function(details)
                local pack = romfs.actorPack(actor)
                local life = romfs.packDocument(pack, "^Life/LifeParameters/")
                if type(life) == "table" then
                    details:section("Life", function(section)
                        for key, value in pairs(life) do
                            if type(value) ~= "table" and key ~= "$parent" then section:label{ label = key, value = tostring(value) } end
                        end
                        if type(life.MaxLife) == "number" then section:note(string.format("%g hearts of damage to defeat", life.MaxLife / 4)) end
                    end)
                end
                local drops = romfs.packDocument(pack, "^Drop/DropSubTable/")
                if drops then showValue(details, "Drops", drops, 0) end
                local files = {}
                for path in pairs(pack) do files[#files + 1] = path end
                table.sort(files)
                details:page(string.format("All files (%d)", #files), function(list)
                    for _, path in ipairs(files) do
                        if path:find("%.bgyml$") then
                            list:page({ title = path, key = path }, function(view)
                                local ok, document = pcall(st.format.byml, pack[path])
                                if ok then showValue(view, "Contents", document, 0) else view:warning(tostring(document)) end
                            end)
                        else
                            list:label{ label = path, value = string.format("%d bytes", #pack[path]) }
                        end
                    end
                end)
            end)
        end
    end
end

local function gameFiles(ui)
    ui:page("Game files", function(page)
        page:note("Read straight from the installed game. Nothing here changes your save.")
        local ok, problem = pcall(romfs.languages)
        if not ok then return page:warning(tostring(problem)) end
        page:page("Dialogue", dialogue)
        page:page("Actors and enemies", actors)
    end)
end

-- Layout ---------------------------------------------------------------------------------------------------------

function build(ui, save)
    local list = slots(save)
    if #list == 0 then return ui:warning("No slot_NN/progress.sav found in this save.") end
    local slot = ui:state("slot", list[1])
    local slotOptions = {}
    for i, name in ipairs(list) do slotOptions[i] = { value = name, label = name } end
    ui:dropdown{ label = "Save slot", bind = slot, options = slotOptions }

    local progress = gamedata.open(save, slot:get() .. "/progress.sav")
    if not progress then return ui:warning("This slot is not a GameData save.") end
    local caption = gamedata.open(save, slot:get() .. "/caption.sav")

    ui:page("Overview", function(page) overview(page, progress, caption) end)
    ui:page("Player", function(page) flagList(page, progress, "^PlayerStatus%.", "PlayerStatus.") end)
    ui:page("Items", function(page) items(page, progress) end)
    ui:page("Songs and quest", function(page) songs(page, progress) end)
    ui:page("Dungeons", function(page) dungeons(page, progress) end)
    ui:page("Story", function(page) story(page, progress) end)
    ui:page("Chests", function(page) byScene(page, progress, "^IsTreasureBoxOpen%.", "IsTreasureBoxOpen.", "Open all") end)
    ui:page("Gold Skulltulas", function(page) skulltulas(page, progress) end)
    ui:page("Spawn point", function(page) spawnPoint(page, progress) end)
    ui:page("All flags", function(page) allFlags(page, progress, "progress") end)
    local options = gamedata.open(save, "option.sav")
    if options then ui:page("Options", function(page) allFlags(page, options, "options") end) end
    gameFiles(ui)
end
