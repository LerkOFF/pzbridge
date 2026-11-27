-- PZBridge: инструменты, доступные агенту. Каждый инструмент - одна команда моста.
-- Все действия идут через ванильные timed actions и помощники контекстного меню,
-- поэтому игра сама считает время, анимации, вес и условия.

require "PZBridge/PZB_Loops"
require "TimedActions/ISInventoryTransferAction"

local U = PZBridge.U
local S = PZBridge.S
local P = PZBridge.P
local L = PZBridge.L
local Tool = PZBridge.tool
local T = PZBridge.T

-- door/window -> перевод для окна.
local KIND_KEYS = { door = "UI_PZBridge_Obj_door", window = "UI_PZBridge_Obj_window" }
local function kindName(k)
    local key = KIND_KEYS[tostring(k)]
    if key then return T(key) end
    return tostring(k)
end

---------------------------------------------------------------------------
-- Баррикада: ванильный ISBarricadeAction:isValid проверяет
-- hasEquippedTag(ItemType.HAMMER), а такого поля в 42.22 нет, поэтому
-- проверка всегда проваливается. Наследник проверяет ItemTag.HAMMER.
---------------------------------------------------------------------------

require "TimedActions/ISBarricadeAction"

PZBBarricadeAction = ISBarricadeAction:derive("PZBBarricadeAction")

function PZBBarricadeAction:isValid()
    if not instanceof(self.item, "BarricadeAble") or self.item:getObjectIndex() == -1 then
        return false
    end
    local barricade = self.item:getBarricadeForCharacter(self.character)
    if barricade and not barricade:canAddPlank() then return false end
    if not self.character:hasEquippedTag(ItemTag.HAMMER) then return false end
    if not self.character:hasEquipped("Plank") then return false end
    if self.character:getInventory():getItemCount("Base.Nails", true) < 2 then return false end
    if self.isStarted and P.isDoor(self.item) and self.item:IsOpen() then return false end
    return true
end

function PZBBarricadeAction:new(character, item)
    return ISBarricadeAction.new(self, character, item, false, false)
end

---------------------------------------------------------------------------
-- Помощники
---------------------------------------------------------------------------

local function num(v) return tonumber(v) end

local function pnum(p) return p:getPlayerNum() end

-- Разобрать «что за предмет»: item_id, filter (таблица или строка-категория),
-- fullType, what (число = id, "Base.X" = fullType, иначе подстрока имени).
local function itemSpec(a)
    if a.item_id then return { id = num(a.item_id) } end
    if a.id and num(a.id) then return { id = num(a.id) } end
    if a.filter then
        if type(a.filter) == "string" then return { filter = { category = a.filter } } end
        return { filter = a.filter }
    end
    if a.fullType then return { filter = { fullType = a.fullType } } end
    if a.what then
        local w = tostring(a.what)
        if num(w) then return { id = num(w) } end
        if w == "all" then return { all = true } end
        if string.find(w, ".", 1, true) then return { filter = { fullType = w } } end
        return { filter = { name = w } }
    end
    if a.name then return { filter = { name = a.name } } end
    return nil
end

-- Найти предмет в инвентаре по спецификации.
local function invItem(p, a, pred)
    local spec = itemSpec(a)
    if not spec then return nil, "no item given (item_id, filter, fullType or what)" end
    if spec.id then
        for _, it in ipairs(P.inventoryItems(p)) do
            if U.try(it, "getID") == spec.id then return it end
        end
        return nil, "no item in inventory with id " .. tostring(spec.id)
    end
    for _, it in ipairs(P.inventoryItems(p)) do
        if (not spec.filter or P.matches(it, spec.filter)) and (not pred or pred(it)) then return it end
    end
    return nil, "no matching item in inventory"
end

local function xyz(a, p)
    local x, y, z = num(a.x), num(a.y), num(a.z)
    if z == nil and p then z = math.floor(p:getZ()) end
    return x, y, z
end

local function notBroken(item) return not item:isBroken() end

local function nearestObject(p, radius, test)
    local best, bestD, bestSq
    P.eachSquare(p:getX(), p:getY(), p:getZ(), radius, function(sq)
        local objs = sq:getObjects()
        for i = 0, objs:size() - 1 do
            local o = objs:get(i)
            if test(o, sq) then
                local d = U.dist(sq:getX() + 0.5, sq:getY() + 0.5, p:getX(), p:getY())
                if not bestD or d < bestD then best, bestD, bestSq = o, d, sq end
            end
        end
    end)
    return best, bestSq, bestD
end

local function barricadeCount(o)
    local n = 0
    local b1 = U.try(o, "getBarricadeOnSameSquare")
    local b2 = U.try(o, "getBarricadeOnOppositeSquare")
    if b1 then n = n + (U.try(b1, "getNumPlanks") or 1) end
    if b2 then n = n + (U.try(b2, "getNumPlanks") or 1) end
    return n
end

---------------------------------------------------------------------------
-- Восприятие (query: не меняют мир, не прерывают текущую задачу)
---------------------------------------------------------------------------

Tool("get_state", { kind = "query", fn = function(a, ctx, p)
    return "ok", "state", PZBridge.buildState(p, true)
end })

Tool("get_access", { kind = "query", always = true, fn = function(a, ctx, p)
    return "ok", S.access and "access on" or "access off", { access = S.access }
end })

Tool("scan_zombies", { kind = "query", params = { "radius" }, fn = function(a, ctx, p)
    local r = U.clamp(num(a.radius) or 20, 1, 60)
    local list = P.strip(P.zombies(p, r, false))
    local known = U.array({})
    local now = U.nowMs()
    for _, k in pairs(S.knownZombies) do
        if now - (k.seen_ms or 0) < 180000 then
            local c = U.shallowCopy(k)
            c.age_s = math.floor((now - (k.seen_ms or 0)) / 1000)
            c.dist = U.round(U.dist(k.x, k.y, p:getX(), p:getY()), 1)
            known[#known + 1] = c
        end
    end
    table.sort(known, function(x, y) return x.dist < y.dist end)
    while #known > 50 do table.remove(known) end
    return "ok", #list .. " zombies within " .. r, { zombies = list, known = known, kills = p:getZombieKills() }
end })

Tool("scan_area", { kind = "query", params = { "radius" }, fn = function(a, ctx, p)
    local only = nil
    if type(a.only) == "table" then
        only = {}
        for _, k in ipairs(a.only) do only[k] = true end
    end
    local res = P.scanArea(p, { radius = num(a.radius) or 8, only = only, withItems = a.with_items == true })
    return "ok", "area scanned", res
end })

Tool("find_items", { kind = "query", params = { "filter", "where", "radius" }, fn = function(a, ctx, p)
    local f = a.filter
    if type(f) == "string" then f = { category = f } end
    local items, unexplored = P.findItems(p, f, a.where or "all", num(a.radius) or 10, num(a.limit) or 40)
    return "ok", #items .. " items", { items = items, unexplored_containers = unexplored }
end })

Tool("get_item", { kind = "query", params = { "id" }, fn = function(a, ctx, p)
    local it, where = P.findItemById(p, a.id or a.item_id, num(a.radius) or 15)
    if not it then return "error", "item not found nearby" end
    if instanceof(it, "IsoWorldInventoryObject") then it = it:getItem() end
    local inf = P.itemInfo(it, true)
    inf.where = where
    return "ok", tostring(inf.name), inf
end })

Tool("get_building", { kind = "query", params = { "id" }, fn = function(a, ctx, p)
    local b
    if a.id then
        P.eachSquare(p:getX(), p:getY(), p:getZ(), 30, function(sq)
            local bb = sq:getBuilding()
            if bb and P.buildingKey(bb) == tostring(a.id) then b = bb; return "break" end
        end)
    else
        b = p:getCurrentBuilding()
    end
    if not b then return "error", a.id and "building not found nearby" or "player is not in a building" end
    local info = P.buildingInfo(b, p)
    local _, def = P.buildingKey(b)
    local rooms = U.array({})
    local rl = def and U.try(def, "getRooms")
    local total, visited = 0, 0
    if rl then
        for i = 0, rl:size() - 1 do
            local rd = rl:get(i)
            local r = { name = U.try(rd, "getName"), z = U.try(rd, "getZ"), explored = U.try(rd, "isExplored") == true,
                        x = U.try(rd, "getX"), y = U.try(rd, "getY"), x2 = U.try(rd, "getX2"), y2 = U.try(rd, "getY2") }
            local room = U.try(rd, "getIsoRoom")
            local cl = room and U.try(room, "getContainer")
            if cl then
                r.containers = cl:size()
                total = total + cl:size()
            end
            rooms[#rooms + 1] = r
        end
    end
    info.rooms_list = rooms
    info.containers_total = total
    return "ok", "building " .. tostring(info.id), info
end })

Tool("get_places", { kind = "query", always = false, fn = function(a, ctx, p)
    local mem = PZBridge.mem()
    local out = U.array({})
    for name, pl in pairs(mem.places) do
        local c = U.shallowCopy(pl)
        c.name = name
        c.dist = U.round(U.dist(pl.x, pl.y, p:getX(), p:getY()), 1)
        out[#out + 1] = c
    end
    table.sort(out, function(x, y) return x.dist < y.dist end)
    return "ok", #out .. " places", { places = out }
end })

Tool("get_guard", { kind = "query", always = true, fn = function(a, ctx, p)
    return "ok", "guard", PZBridge.guard
end })

---------------------------------------------------------------------------
-- Управление
---------------------------------------------------------------------------

Tool("stop", { kind = "control", fn = function(a, ctx, p)
    PZBridge.stopAll("stop command")
    return "ok", "stopped"
end })

local function setPause(on)
    local sc = UIManager and UIManager.getSpeedControls and UIManager.getSpeedControls()
    if sc then
        pcall(sc.SetCurrentGameSpeed, sc, on and 0 or 1)
    else
        setGameSpeed(on and 0 or 1)
    end
end
PZBridge.setPause = setPause

Tool("pause", { kind = "control", fn = function(a, ctx, p)
    setPause(true)
    return "ok", "paused"
end })

-- Явно сняли паузу, зная про зомби рядом: автопауза не срабатывает сразу снова
-- (повторно только если зомби вплотную, ближе 2 клеток, и прошло 8 секунд).
local function disarmAutopause()
    S.autoPauseArmed = false
    S.lastAutoPauseMs = U.nowMs()
end

Tool("unpause", { kind = "control", fn = function(a, ctx, p)
    disarmAutopause()
    setPause(false)
    S.alert = nil
    return "ok", "game running"
end })

Tool("resume", { kind = "control", fn = function(a, ctx, p)
    local job = S.pausedJob
    if not job then return "error", "no paused job" end
    S.pausedJob = nil
    if isGamePaused() then setPause(false) end
    PZBridge.startJob(job, ctx)
    return "running", "resuming " .. tostring(job.name)
end })

Tool("set_guard", { kind = "control", always = false, fn = function(a, ctx, p)
    local changed = {}
    for k, v in pairs(a) do
        if PZBridge.guard[k] ~= nil then
            local cur = PZBridge.guard[k]
            if type(cur) == "boolean" then
                if v == "on" or v == "true" or v == true or v == 1 then v = true
                elseif v == "off" or v == "false" or v == false or v == 0 then v = false end
            elseif type(cur) == "number" then v = num(v) end
            if type(v) == type(cur) then
                PZBridge.guard[k] = v
                changed[k] = v
            end
        end
    end
    S.autoPauseArmed = true
    return "ok", "guard updated", { guard = PZBridge.guard, changed = changed }
end })

Tool("autopause", { kind = "control", params = { "value", "distance" }, fn = function(a, ctx, p)
    local v = tostring(a.value or "on")
    PZBridge.guard.autopause = (v == "on" or v == "true" or v == "1")
    if num(a.distance) then PZBridge.guard.pause_distance = num(a.distance) end
    return "ok", "autopause " .. (PZBridge.guard.autopause and "on" or "off")
end })

Tool("autoflee", { kind = "control", params = { "value" }, fn = function(a, ctx, p)
    local v = tostring(a.value or "on")
    PZBridge.guard.autoflee = (v == "on" or v == "true" or v == "1")
    return "ok", "autoflee " .. (PZBridge.guard.autoflee and "on" or "off")
end })

Tool("reply", { kind = "control", always = true, params = { "text" }, fn = function(a, ctx, p)
    local text = tostring(a.text or "")
    if text == "" then return "error", "empty text" end
    PZBridge.chatAdd("agent", text)
    if a.say ~= false then pcall(p.Say, p, text) end
    PZBridge.event("reply", { text = text }, text)
    return "ok", "sent"
end })

Tool("say", { kind = "control", params = { "text" }, fn = function(a, ctx, p)
    p:Say(tostring(a.text or ""))
    return "ok", "said"
end })

-- Крик (клавиша Q в игре): стоя - громко, зомби вокруг слышат и идут на звук;
-- крадучись - шёпот. whisper=true/false временно включает или выключает скрытность.
Tool("shout", { params = { "whisper" }, fn = function(a, ctx, p)
    local wasSneak = p:isSneaking()
    if a.whisper == true and not wasSneak then p:setSneaking(true) end
    if a.whisper == false and wasSneak then p:setSneaking(false) end
    local quiet = p:isSneaking()
    local ok = pcall(p.Callout, p, true)
    if a.whisper ~= nil then p:setSneaking(wasSneak) end
    if not ok then return "error", "callout failed" end
    PZBridge.event("shout", { loud = not quiet }, quiet and "whispered" or "shouted loud")
    if quiet then return "ok", "whispered (quiet, almost no noise)" end
    return "ok", "shouted loud: zombies nearby will hear it and come"
end })

Tool("mark_place", { kind = "control", params = { "name", "x", "y", "z" }, fn = function(a, ctx, p)
    if not a.name or a.name == "" then return "error", "place name required" end
    local x, y, z = num(a.x) or math.floor(p:getX()), num(a.y) or math.floor(p:getY()), num(a.z) or math.floor(p:getZ())
    local mem = PZBridge.mem()
    local b = P.square(x, y, z)
    local bkey = b and b:getBuilding() and P.buildingKey(b:getBuilding()) or nil
    mem.places[tostring(a.name)] = { x = x, y = y, z = z, note = a.note, building = bkey, t = PZBridge.gameTimeStr() }
    PZBridge.saveMemFile()
    return "ok", "place marked: " .. tostring(a.name), mem.places[tostring(a.name)]
end })

Tool("forget_place", { kind = "control", params = { "name" }, fn = function(a, ctx, p)
    local mem = PZBridge.mem()
    mem.places[tostring(a.name)] = nil
    PZBridge.saveMemFile()
    return "ok", "place forgotten"
end })

Tool("forget_visited", { kind = "control", fn = function(a, ctx, p)
    local mem = PZBridge.mem()
    mem.visitedBuildings = {}
    mem.visitedContainers = {}
    if a.known then mem.knownContainers = {} end
    return "ok", "visited memory cleared"
end })

---------------------------------------------------------------------------
-- Движение и циклы
---------------------------------------------------------------------------

Tool("move_to", { params = { "x", "y", "z", "mode" }, fn = function(a, ctx, p)
    local x, y, z = xyz(a, p)
    if a.place then
        local pl = PZBridge.mem().places[tostring(a.place)]
        if not pl then return "error", "no such place: " .. tostring(a.place) end
        x, y, z = pl.x, pl.y, pl.z
    end
    if not x or not y then return "error", "x and y required (or place)" end
    return L.startMoveTo(ctx, p, x, y, z, a)
end })

Tool("move_rel", { params = { "dx", "dy", "mode" }, fn = function(a, ctx, p)
    local dx, dy = num(a.dx) or 0, num(a.dy) or 0
    return L.startMoveTo(ctx, p, p:getX() + dx, p:getY() + dy, p:getZ(), a)
end })

Tool("flee", { params = { "distance", "mode" }, fn = function(a, ctx, p)
    return L.startFlee(ctx, p, { distance = num(a.distance), mode = a.mode, x = num(a.x), y = num(a.y) })
end })

Tool("search", { params = { "scope", "target" }, fn = function(a, ctx, p)
    return L.startSearch(ctx, p, a)
end })

Tool("fight", { params = { "until", "radius" }, fn = function(a, ctx, p)
    if a.kills and not a["until"] then a["until"] = "kills:" .. tostring(a.kills) end
    -- бой идёт к зомби намеренно: автопаузу не ждём, паузу снимаем
    disarmAutopause()
    if a.unpause ~= false then setPause(false); S.alert = nil end
    if a.radius then a.radius = num(a.radius) end
    return L.startFight(ctx, p, a)
end })

Tool("wait", { params = { "seconds" }, fn = function(a, ctx, p)
    return L.startWait(ctx, p, { seconds = num(a.seconds), game_minutes = num(a.game_minutes), interrupt_on_threat = a.interrupt_on_threat })
end })

Tool("face", { params = { "x", "y" }, fn = function(a, ctx, p)
    local x, y = num(a.x), num(a.y)
    if not x or not y then return "error", "x and y required" end
    p:faceLocation(x, y)
    return "ok", "turned"
end })

Tool("attack", { params = { "target" }, fn = function(a, ctx, p)
    local zs = P.zombies(p, 4, true)
    local target
    for _, z in ipairs(zs) do
        if a.target == nil or z.id == num(a.target) then target = z; break end
    end
    if not target then return "error", "no zombies nearby" end
    if target.dist > L.weaponRange(p) + 0.6 then return "error", "zombie too far (" .. target.dist .. ")" end
    if L.attack(p, target.obj) then return "ok", "attacked zombie " .. tostring(target.id) end
    return "error", "attack did not start"
end })

---------------------------------------------------------------------------
-- Предметы
---------------------------------------------------------------------------

Tool("take", { params = { "what", "from" }, fn = function(a, ctx, p)
    local spec = itemSpec(a) or { all = true }
    local count = num(a.count) or (spec.all and 999) or 1
    local from = a.from
    -- 1) конкретный контейнер
    local srcC, srcO
    local items = {}
    if from and from ~= "nearby" and from ~= "floor" then
        srcC, srcO = P.resolveContainer(from)
        if not srcC then return "error", "container " .. tostring(from) .. " not found" end
        if not U.try(srcC, "isExplored") then
            local d = U.dist(srcO:getX() + 0.5, srcO:getY() + 0.5, p:getX(), p:getY())
            if d < 2 then
                L.exploreContainer(srcC, p)
                L.rememberContainer(from, srcC)
            else
                return "error", "container not explored yet: run search scope=container target=" .. tostring(from) .. " first"
            end
        end
        for _, it in ipairs(P.containerItems(srcC)) do
            if spec.all or (spec.id and it:getID() == spec.id) or (spec.filter and P.matches(it, spec.filter)) then
                items[#items + 1] = it
            end
        end
    else
        -- 2) рядом: открытые контейнеры и пол
        if spec.id then
            local it = P.findItemById(p, spec.id, num(a.radius) or 10)
            if it then items[1] = it end
        else
            local list = P.findItems(p, spec.filter, "nearby", num(a.radius) or 6, 50)
            for _, inf in ipairs(list) do
                if from ~= "floor" or inf.where == "floor" then
                    local it = P.findItemById(p, inf.id, num(a.radius) or 6)
                    if it then items[#items + 1] = it end
                end
            end
        end
    end
    if #items == 0 then return "error", "no matching items" end
    -- берём только из одного источника за команду (иначе ванильная ходьба сбросит очередь)
    local first = items[1]
    local taken = U.array({})
    if instanceof(first, "IsoWorldInventoryObject") then
        local sq = first:getSquare()
        if not luautils.walkAdj(p, sq, true) then return "error", "cannot get close" end
        for i = 1, math.min(count, #items) do
            local wo = items[i]
            if instanceof(wo, "IsoWorldInventoryObject") and wo:getSquare() == sq then
                local it = wo:getItem()
                ISTimedActionQueue.add(ISInventoryTransferUtil.newInventoryTransferAction(p, it, it:getContainer(), p:getInventory()))
                taken[#taken + 1] = P.itemInfo(it, false)
            end
        end
    else
        local c = first:getContainer()
        if c == p:getInventory() then return "error", "item already in inventory" end
        if not luautils.walkToContainer(c, pnum(p)) then return "error", "cannot reach the container" end
        for i = 1, math.min(count, #items) do
            local it = items[i]
            if not instanceof(it, "IsoWorldInventoryObject") and it:getContainer() == c then
                ISTimedActionQueue.add(ISInventoryTransferUtil.newInventoryTransferAction(p, it, c, p:getInventory()))
                taken[#taken + 1] = P.itemInfo(it, false)
            end
        end
    end
    ctx.data = { taken = taken }
    return L.actionJob(ctx, "take", function(job, pl)
        return "done", "took " .. #taken, { taken = taken }
    end, "taking " .. #taken, T("UI_PZBridge_StepTake", #taken))
end })

Tool("loot", { params = { "x", "y", "z", "what" }, fn = function(a, ctx, p)
    local x, y, z = xyz(a, p)
    local sq = P.square(x, y, z)
    if not sq then return "error", "square not found" end
    local objs = sq:getObjects()
    for i = 0, objs:size() - 1 do
        local o = objs:get(i)
        if (U.try(o, "getContainerCount") or 0) > 0 then
            local na = U.shallowCopy(a)
            na.from = P.containerId(sq, i, 0)
            return PZBridge.tools.take.fn(na, ctx, p)
        end
    end
    return "error", "no container on the square"
end })

Tool("drop", { params = { "what" }, fn = function(a, ctx, p)
    local it, err = invItem(p, a)
    if not it then return "error", err end
    ISInventoryPaneContextMenu.dropItem(it, pnum(p))
    local nm = tostring(it:getDisplayName())
    return L.actionJob(ctx, "drop", nil, "dropping " .. nm, T("UI_PZBridge_StepDrop", nm))
end })

Tool("transfer", { params = { "what", "to" }, fn = function(a, ctx, p)
    local it, err = invItem(p, a)
    if not it then return "error", err end
    -- куда: "inventory" (основной инвентарь), id сумки в инвентаре или cid контейнера в мире
    local dest
    local inv = p:getInventory()
    local toId = num(a.to)
    if a.to == "inventory" or a.to == "main" then
        dest = inv
    elseif toId then
        local bag = inv:getItemWithID(toId)
        if not bag or not instanceof(bag, "InventoryContainer") then return "error", "bag " .. tostring(a.to) .. " not found in inventory" end
        dest = bag:getInventory()
    else
        dest = P.resolveContainer(a.to)
        if not dest then return "error", "destination container not found" end
        if not luautils.walkToContainer(dest, pnum(p)) then return "error", "cannot reach the container" end
    end
    if it:getContainer() == dest then return "ok", "already there" end
    if U.try(dest, "hasRoomFor", p, it) == false then return "error", "no room in destination" end
    ISTimedActionQueue.add(ISInventoryTransferUtil.newInventoryTransferAction(p, it, it:getContainer(), dest))
    local nm = tostring(it:getDisplayName())
    return L.actionJob(ctx, "transfer", nil, "transferring " .. nm, T("UI_PZBridge_StepTransfer", nm))
end })

Tool("equip", { params = { "what", "slot" }, fn = function(a, ctx, p)
    local it, err = invItem(p, a)
    if not it then return "error", err end
    local slot = a.slot or "primary"
    local nm0 = tostring(it:getDisplayName())
    -- слоты хотбара (спина, пояс): как ванильный ISHotbar при перетаскивании
    if slot == "back" or slot == "belt" or slot == "attach" then
        local hb = getPlayerHotbar and getPlayerHotbar(pnum(p))
        if not hb or not hb.availableSlot then return "error", "hotbar not available" end
        local atype = U.try(it, "getAttachmentType")
        if not atype then return "error", "item cannot be attached" end
        local want = (slot == "back" and "Back") or nil
        for idx, s in pairs(hb.availableSlot) do
            local okName = (want == nil) or s.name == want or s.slotType == want
            if slot == "belt" then okName = s.slotType ~= "Back" and s.name ~= "Back" end
            if okName and s.def and s.def.attachments and s.def.attachments[atype] then
                if hb.attachedItems and hb.attachedItems[idx] == it then return "ok", "already attached: " .. nm0 end
                hb:attachItem(it, s.def.attachments[atype], idx, s.def, true)
                return L.actionJob(ctx, "equip", function(job, pl)
                    local sl = U.try(it, "getAttachedSlot")
                    if sl ~= nil and sl ~= -1 then return "done", "attached (" .. tostring(s.name) .. "): " .. nm0 end
                    return "failed", "could not attach"
                end, "attaching " .. nm0, T("UI_PZBridge_StepEquip", nm0))
            end
        end
        return "error", "no hotbar slot for attachment type " .. tostring(atype)
    end
    local two = slot == "both" or (U.try(it, "isTwoHandWeapon") == true) or (U.try(it, "isRequiresEquippedBothHands") == true)
    ISInventoryPaneContextMenu.equipWeapon(it, slot ~= "secondary", two, pnum(p))
    local nm = tostring(it:getDisplayName())
    return L.actionJob(ctx, "equip", function(job, pl)
        if pl:getPrimaryHandItem() == it or pl:getSecondaryHandItem() == it then return "done", "in hands: " .. nm end
        return "failed", "could not equip"
    end, "equipping " .. nm, T("UI_PZBridge_StepEquip", nm))
end })

Tool("unequip", { params = { "what" }, fn = function(a, ctx, p)
    local it
    if a.slot == "secondary" then it = p:getSecondaryHandItem()
    elseif itemSpec(a) then it = invItem(p, a)
    else it = p:getPrimaryHandItem() or p:getSecondaryHandItem() end
    if not it then return "ok", "hands already empty" end
    ISInventoryPaneContextMenu.unequipItem(it, pnum(p))
    local nm = tostring(it:getDisplayName())
    return L.actionJob(ctx, "unequip", nil, "unequipping " .. nm, T("UI_PZBridge_StepUnequip", nm))
end })

Tool("wear", { params = { "what" }, fn = function(a, ctx, p)
    local it, err = invItem(p, a)
    if not it then return "error", err end
    ISInventoryPaneContextMenu.wearItem(it, pnum(p))
    local nm = tostring(it:getDisplayName())
    return L.actionJob(ctx, "wear", nil, "putting on " .. nm, T("UI_PZBridge_StepWear", nm))
end })

local function pickWoundPart(p, partName)
    local parts = p:getBodyDamage():getBodyParts()
    local best
    for i = 0, parts:size() - 1 do
        local bp = parts:get(i)
        local name = tostring(bp:getType())
        if partName and name == partName then return bp end
        if not partName and not bp:bandaged() then
            if (bp:getBleedingTime() or 0) > 0 then return bp end
            if not best and (bp:scratched() or bp:bitten() or bp:isCut() or bp:isDeepWounded()) then best = bp end
        end
    end
    return best
end

-- Ремесло B42 из инвентаря (как правый клик по предмету -> рецепт):
-- рецепты, доступные для предмета, и запуск рецепта.
local function itemRecipes(p, it)
    local containers = ISInventoryPaneContextMenu.getContainers(p)
    local ok, list = pcall(CraftRecipeManager.getUniqueRecipeItems, it, p, containers)
    if not ok or not list then return {}, containers end
    local out = {}
    for i = 0, list:size() - 1 do out[#out + 1] = list:get(i) end
    return out, containers
end

local function recipeName(r)
    return tostring(U.try(r, "getName") or "?")
end

-- Карта: все здания мира в радиусе (по метаданным карты, как у игрока на бумажной карте).
-- Тип по комнатам: жилое (спальни, кухни), магазин, склад и т.п.
local function compass(dx, dy)
    -- в PZ x растёт на восток, y на юг
    local a = math.atan2(-dy, dx) * 180 / math.pi
    if a < 0 then a = a + 360 end
    local names = { "E", "NE", "N", "NW", "W", "SW", "S", "SE" }
    return names[math.floor((a + 22.5) / 45) % 8 + 1]
end

local SHOP_ROOMS = { grocery = true, gigamart = true, conveniencestore = true, pharmacy = true, toolstore = true,
    hardwarestore = true, gasstore = true, liquorstore = true, clothesstore = true, sportstore = true,
    gunstore = true, bookstore = true, policestorage = true, hospitalroom = true, medclinic = true }

Tool("map", { kind = "control", params = { "radius", "type", "limit" }, fn = function(a, ctx, p)
    local radius = num(a.radius) or 150
    local limit = num(a.limit) or 25
    local want = a.type or "any"
    local mg = getWorld():getMetaGrid()
    local list = U.try(mg, "getBuildings")
    if not list then return "error", "map data not available" end
    local mem = PZBridge.mem()
    local px, py = p:getX(), p:getY()
    local out = {}
    for i = 0, list:size() - 1 do
        local def = list:get(i)
        local x1, y1, x2, y2 = def:getX(), def:getY(), def:getX2(), def:getY2()
        local cx, cy = (x1 + x2) / 2, (y1 + y2) / 2
        local d = U.dist(cx, cy, px, py)
        if d <= radius then
            local rooms = U.try(def, "getRooms")
            local names, kinds = {}, { residential = false, shop = false }
            if rooms then
                for r = 0, rooms:size() - 1 do
                    local n = tostring(U.try(rooms:get(r), "getName") or "")
                    names[n] = (names[n] or 0) + 1
                    if n == "bedroom" or n == "kitchen" or n == "livingroom" then kinds.residential = true end
                    if SHOP_ROOMS[n] then kinds.shop = true end
                end
            end
            local t = kinds.shop and "shop" or (kinds.residential and "house" or "other")
            if want == "any" or want == t then
                local key = U.try(def, "getIDString") or tostring(U.try(def, "getID"))
                local rl = {}
                for n, c in pairs(names) do rl[#rl + 1] = (c > 1) and (n .. "x" .. c) or n end
                table.sort(rl)
                out[#out + 1] = {
                    id = key, type = t, dist = U.round(d, 0), dir = compass(cx - px, cy - py),
                    x = math.floor(cx), y = math.floor(cy), size = (x2 - x1) .. "x" .. (y2 - y1),
                    rooms = table.concat(rl, ","), visited = mem.visitedBuildings[key] == true,
                    blocked = mem.blockedBuildings and mem.blockedBuildings[key] ~= nil or false,
                    explored = U.try(def, "isAllExplored") == true,
                }
            end
        end
    end
    table.sort(out, function(x, y) return x.dist < y.dist end)
    local res = U.array({})
    for i = 1, math.min(limit, #out) do res[#res + 1] = out[i] end
    ctx.data = { buildings = res, total = #out, radius = radius }
    return "ok", #out .. " buildings within " .. radius, ctx.data
end })

-- Настройки песочницы, от которых зависит стратегия (что известно игроку из настроек мира).
Tool("get_sandbox", { kind = "control", params = {}, fn = function(a, ctx, p)
    local sv = SandboxVars or {}
    local zc = sv.ZombieConfig or {}
    local keys = { "Zombies", "Distribution", "DayLength", "StartMonth", "WaterShut", "WaterShutModifier",
        "ElecShut", "ElecShutModifier", "Alarm", "LockedHouses", "FoodLoot", "WeaponLoot", "MedicalLoot",
        "MultiHitZombies", "MuscleStrainFactor", "Helicopter", "NightDarkness" }
    local out = {}
    for _, k in ipairs(keys) do if sv[k] ~= nil then out[k] = sv[k] end end
    local zkeys = { "Speed", "Strength", "Toughness", "Transmission", "Mortality", "Reanimate", "Cognition",
        "Memory", "Sight", "Hearing", "FollowSoundDistance", "RallyGroupSize" }
    out.ZombieConfig = {}
    for _, k in ipairs(zkeys) do if zc[k] ~= nil then out.ZombieConfig[k] = zc[k] end end
    out.days_survived = U.round((getGameTime() and getGameTime():getWorldAgeHours() or 0) / 24, 2)
    ctx.data = out
    return "ok", "sandbox settings", out
end })

Tool("recipes", { kind = "control", params = { "what" }, fn = function(a, ctx, p)
    local it, err = invItem(p, a)
    if not it then return "error", err end
    local rs = itemRecipes(p, it)
    local names = U.array({})
    for _, r in ipairs(rs) do
        local tn = U.try(r, "getTranslationName")
        names[#names + 1] = { name = recipeName(r), title = tn and getText(tn) or nil }
    end
    ctx.data = { item = P.itemInfo(it, false), recipes = names }
    return "ok", #names .. " recipes", ctx.data
end })

local function startCraft(p, it, wanted)
    local rs = itemRecipes(p, it)
    local recipe
    for _, r in ipairs(rs) do
        local n = recipeName(r)
        if n == wanted or string.lower(n) == string.lower(tostring(wanted)) then recipe = r; break end
    end
    if not recipe then
        local names = {}
        for _, r in ipairs(rs) do names[#names + 1] = recipeName(r) end
        return nil, "recipe " .. tostring(wanted) .. " is not available for this item; available: " .. table.concat(names, ", ")
    end
    ISInventoryPaneContextMenu.OnNewCraft(it, recipe, pnum(p), false)
    return recipe
end

Tool("craft", { params = { "what", "recipe" }, fn = function(a, ctx, p)
    local it, err = invItem(p, a)
    if not it then return "error", err end
    if not a.recipe then return "error", "recipe required (see the recipes tool)" end
    local r, e = startCraft(p, it, a.recipe)
    if not r then return "error", e end
    local nm = tostring(it:getDisplayName())
    return L.actionJob(ctx, "craft", nil, "crafting " .. tostring(a.recipe), T("UI_PZBridge_StepCraft", nm))
end })

-- Первая помощь: каждую рану (кровотечение первым, потом по тяжести) обработать,
-- если есть чем (спирт, спиртовые салфетки, дезинфектор), и перевязать чистым бинтом
-- или чистыми тряпками. Нет бинтов: порвать простыню, шторы или ненадетую одежду на тряпки.
-- Грязные тряпки не используются.
local function isCleanBandage(x)
    return U.try(x, "isCanBandage") == true and not string.find(tostring(x:getFullType()), "Dirty", 1, true)
end

local function isDisinfectant(x)
    local fc = U.try(x, "getFluidContainer")
    if fc then
        local amt = U.try(fc, "getAmount") or 0
        local props = U.try(fc, "getProperties")
        local alc = props and U.try(props, "getAlcohol") or 0
        return amt > 0.15 and (alc / amt + 0.001) >= 0.4
    end
    return U.try(x, "IsDrainable") == true and U.try(x, "getAlcoholPower") == 4.0
end

local RIPPABLE = { "Base.Sheet", "Base.Curtains" }

local function findRippable(p)
    for _, it in ipairs(P.inventoryItems(p)) do
        local ft = tostring(it:getFullType())
        for _, r in ipairs(RIPPABLE) do if ft == r then return it, "RipSheets" end end
    end
    for _, it in ipairs(P.inventoryItems(p)) do
        if instanceof(it, "Clothing") and not U.try(it, "isWorn") and not U.try(it, "isEquipped") then
            for _, r in ipairs((itemRecipes(p, it))) do
                if recipeName(r) == "RipClothing" then return it, "RipClothing" end
            end
        end
    end
    return nil
end

local function woundList(p)
    local out = {}
    local parts = p:getBodyDamage():getBodyParts()
    for i = 0, parts:size() - 1 do
        local bp = parts:get(i)
        if not bp:bandaged() and ((bp:getBleedingTime() or 0) > 0 or bp:scratched() or bp:bitten() or bp:isCut() or bp:isDeepWounded()) then
            out[#out + 1] = bp
        end
    end
    table.sort(out, function(x, y)
        local bx, by = (x:getBleedingTime() or 0) > 0, (y:getBleedingTime() or 0) > 0
        if bx ~= by then return bx end
        return (x:getHealth() or 100) < (y:getHealth() or 100)
    end)
    return out
end

Tool("first_aid", { params = {}, fn = function(a, ctx, p)
    local wounds = woundList(p)
    if #wounds == 0 then return "ok", "no unbandaged wounds" end
    local inv = P.inventoryItems(p)
    local bandages, disinf = {}, nil
    for _, it in ipairs(inv) do
        if isCleanBandage(it) then bandages[#bandages + 1] = it end
        if not disinf and isDisinfectant(it) then disinf = it end
    end
    local plan = U.array({})
    local ripped = nil
    if #bandages < #wounds then
        local src, recipe = findRippable(p)
        if src then
            ripped = tostring(src:getDisplayName())
            startCraft(p, src, recipe)
            plan[#plan + 1] = "rip " .. ripped
        end
    end
    -- обработка и бинты ставятся в очередь после разрыва: бинты берутся, когда дойдёт очередь
    local state = { i = 0, wounds = wounds, done = U.array({}), disinfected = 0, noBandage = 0 }
    local function queueNext(pl)
        state.i = state.i + 1
        local bp = state.wounds[state.i]
        if not bp then return false end
        local name = tostring(bp:getType())
        local d
        for _, it in ipairs(P.inventoryItems(pl)) do if isDisinfectant(it) then d = it; break end end
        if d and (U.try(bp, "getAlcoholLevel") or 0) <= 0 then
            ISInventoryPaneContextMenu.transferIfNeeded(pl, d)
            ISTimedActionQueue.add(ISDisinfect:new(pl, pl, d, bp))
            state.disinfected = state.disinfected + 1
        end
        local b
        for _, it in ipairs(P.inventoryItems(pl)) do if isCleanBandage(it) then b = it; break end end
        if b then
            ISInventoryPaneContextMenu.transferIfNeeded(pl, b)
            ISTimedActionQueue.add(ISApplyBandage:new(pl, pl, b, bp, true))
            state.done[#state.done + 1] = name
        else
            state.noBandage = state.noBandage + 1
        end
        return true
    end
    if not ripped then queueNext(p) end
    local nm = "first aid"
    return L.actionJob(ctx, "first_aid", function(job, pl)
        -- очередь пуста: следующая рана
        if queueNext(pl) then return "continue" end
        local left = woundList(pl)
        local msg = "bandaged: " .. table.concat(state.done, ", ") .. "; disinfected " .. state.disinfected
        if ripped then msg = msg .. "; ripped " .. ripped .. " into rags" end
        if #left > 0 then msg = msg .. "; still unbandaged " .. #left .. " (no clean bandages)" end
        return (#left == 0) and "done" or "failed", msg, { bandaged = state.done, disinfected = state.disinfected, left = #left }
    end, "first aid", T("UI_PZBridge_StepFirstAid"))
end })

Tool("use", { params = { "what", "how" }, fn = function(a, ctx, p)
    local how = a.how or "eat"
    local percent = num(a.percent) or 1
    local it, err
    if how == "eat" then
        it, err = invItem(p, itemSpec(a) and a or { filter = { category = "food" } })
        if not it then return "error", err end
        if not instanceof(it, "Food") then return "error", "this is not food" end
        ISInventoryPaneContextMenu.eatItem(it, percent, pnum(p))
        local nm = tostring(it:getDisplayName())
        return L.actionJob(ctx, "use", nil, "eating " .. nm, T("UI_PZBridge_StepEat", nm))
    elseif how == "drink" then
        it, err = invItem(p, itemSpec(a) and a or { filter = { category = "drink" } })
        if not it then
            it, err = invItem(p, { filter = { category = "water_clean" } })
        end
        if not it then return "error", err end
        local fc = U.try(it, "getFluidContainer")
        if fc and not fc:isEmpty() then
            if fc:isTainted() and not a.allow_dirty then return "error", "water is tainted: use allow_dirty=true or boil it" end
            ISInventoryPaneContextMenu.onDrinkFluid(it, percent, p)
        elseif instanceof(it, "Food") then
            ISInventoryPaneContextMenu.eatItem(it, percent, pnum(p))
        else
            return "error", "cannot drink from this"
        end
        local nm = tostring(it:getDisplayName())
        return L.actionJob(ctx, "use", nil, "drinking " .. nm, T("UI_PZBridge_StepDrink", nm))
    elseif how == "read" then
        it, err = invItem(p, a)
        if not it then return "error", err end
        ISInventoryPaneContextMenu.readItem(it, pnum(p))
        local nm = tostring(it:getDisplayName())
        return L.actionJob(ctx, "use", nil, "reading " .. nm, T("UI_PZBridge_StepRead", nm))
    elseif how == "pill" then
        it, err = invItem(p, a)
        if not it then return "error", err end
        ISInventoryPaneContextMenu.takePill(it, pnum(p))
        local nm = tostring(it:getDisplayName())
        return L.actionJob(ctx, "use", nil, "taking pill " .. nm, T("UI_PZBridge_StepPill", nm))
    elseif how == "apply_bandage" or how == "bandage" then
        it, err = invItem(p, itemSpec(a) and a or { filter = { category = "medical" } }, function(x) return U.try(x, "isCanBandage") == true end)
        if not it then return "error", err or "no bandage" end
        local part = pickWoundPart(p, a.part)
        if not part then return "error", "no unbandaged wounds" end
        ISInventoryPaneContextMenu.transferIfNeeded(p, it)
        ISTimedActionQueue.add(ISApplyBandage:new(p, p, it, part, true))
        local pname = tostring(part:getType())
        return L.actionJob(ctx, "use", function(job, pl)
            if part:bandaged() then return "done", "bandaged " .. pname end
            return "failed", "bandage not applied"
        end, "bandaging " .. pname, T("UI_PZBridge_StepBandage", pname))
    end
    return "error", "unknown how=" .. tostring(how) .. " (eat, drink, read, pill, apply_bandage)"
end })

Tool("eat", { params = { "what" }, fn = function(a, ctx, p)
    a.how = "eat"
    return PZBridge.tools.use.fn(a, ctx, p)
end })

-- Найти источник воды: по координатам или ближайший чистый.
local function waterSource(p, a)
    local x, y, z = xyz(a, p)
    if x and y then
        local o, _, sq = P.findObjectAt(x, y, z, "water")
        return o, sq
    end
    local o, sq = nearestObject(p, num(a.radius) or 10, function(o, sq)
        local w = P.waterSourceInfo(o, sq)
        return w ~= nil and (w.clean or a.allow_dirty) and (w.amount or 0) > 0
    end)
    return o, sq
end

Tool("drink_from", { params = { "x", "y", "z" }, fn = function(a, ctx, p)
    local o, sq = waterSource(p, a)
    if not o then return "error", "no water source nearby" end
    if U.try(o, "isTaintedWater") and not a.allow_dirty then
        return "error", "water source is tainted (allow_dirty=true to drink anyway)"
    end
    if (U.try(o, "getFluidAmount") or 0) <= 0 then return "error", "water source is empty" end
    local thirst = CharacterStat and p:getStats():get(CharacterStat.THIRST) or 0
    if thirst < 0.05 then return "error", "character is not thirsty" end
    if not luautils.walkAdjObject(p, o, true, true) then return "error", "cannot reach the water source" end
    ISTimedActionQueue.add(ISTakeWaterAction:new(p, nil, o, U.try(o, "isTaintedWater") == true))
    local on = tostring(P.objectName(o))
    return L.actionJob(ctx, "drink_from", function(job, pl)
        -- проверяем по жажде: путь мог не найтись, и тогда персонаж не попил
        local now = CharacterStat and pl:getStats():get(CharacterStat.THIRST) or 0
        if now < thirst - 0.02 then return "done", "drank, thirst " .. U.round(thirst, 2) .. " -> " .. U.round(now, 2) end
        return "failed", "did not drink: could not reach the source (locked building?)"
    end, "drinking from " .. on, T("UI_PZBridge_StepDrinkFrom", on))
end })

Tool("drink", { params = { "what" }, fn = function(a, ctx, p)
    a.how = "drink"
    local st, msg, data = PZBridge.tools.use.fn(a, ctx, p)
    if st ~= "error" then return st, msg, data end
    -- нет напитка в инвентаре: ближайший чистый источник
    return PZBridge.tools.drink_from.fn({ radius = 10 }, ctx, p)
end })

Tool("fill", { params = { "what", "x", "y", "z" }, fn = function(a, ctx, p)
    local it, err = invItem(p, itemSpec(a) and a or { filter = { category = "water_container" } }, function(x)
        local fc = U.try(x, "getFluidContainer")
        return fc ~= nil and not fc:isFull()
    end)
    if not it then return "error", err end
    local o = waterSource(p, a)
    if not o then return "error", "no water source nearby" end
    local tainted = U.try(o, "isTaintedWater") == true
    if tainted and not a.allow_dirty then return "error", "water source is tainted (allow_dirty=true)" end
    ISInventoryPaneContextMenu.transferIfNeeded(p, it)
    if not luautils.walkAdjObject(p, o, true, true) then return "error", "cannot reach the water source" end
    ISTimedActionQueue.add(ISTakeWaterAction:new(p, it, o, tainted))
    return L.actionJob(ctx, "fill", nil, "filling with water", T("UI_PZBridge_StepFill"))
end })

---------------------------------------------------------------------------
-- Двери, окна, баррикады
---------------------------------------------------------------------------

local function doorOrWindow(a, p, kind)
    local x, y, z = xyz(a, p)
    if not x or not y then return nil, "x y z required" end
    local o, k, sq = P.findObjectAt(x, y, z, kind or a.kind)
    if not o then return nil, "no door or window on the square" end
    return o, k, sq
end

local function openClose(wantOpen)
    return function(a, ctx, p)
        local o, k, sq = doorOrWindow(a, p)
        if not o then return "error", k end
        if (U.try(o, "IsOpen") == true) == wantOpen then return "ok", wantOpen and "already open" or "already closed" end
        if wantOpen and U.try(o, "isBarricaded") then return "error", "barricaded" end
        -- дверь: одна попытка, не открылась - заперта. Окно можно дёргать, пока его не заклинит насовсем.
        if wantOpen and k == "door" and L.isKnownLocked(o) then
            return "error", "door is locked (did not open earlier): find a key, another way, or break it"
        end
        if wantOpen and k ~= "door" and (U.try(o, "isPermaLocked") == true or L.isKnownLocked(o)) then
            return "error", "window is jammed for good: only smash_window is left, it is loud - last resort"
        end
        if not luautils.walkAdjWindowOrDoor(p, sq, o) then return "error", "cannot get close" end
        if k == "door" then
            ISTimedActionQueue.add(ISOpenCloseDoor:new(p, o))
        else
            if wantOpen and (U.try(o, "isLocked") or U.try(o, "isPermaLocked")) then
                -- ванильное действие попробует открыть; заблокированное окно не откроется
            end
            ISTimedActionQueue.add(ISOpenCloseWindow:new(p, o))
        end
        return L.actionJob(ctx, wantOpen and "open" or "close", function(job, pl)
            if (U.try(o, "IsOpen") == true) == wantOpen then return "done", wantOpen and "opened" or "closed" end
            if wantOpen then
                if k == "door" then
                    -- дверь не открылась с первого раза: заперта, запоминаем
                    L.markLocked(o)
                    return "failed", "door did not open: locked"
                end
                -- окно: пробуем снова, пока не откроется или пока его не заклинит насовсем
                if U.try(o, "isPermaLocked") == true then
                    L.markLocked(o)
                    return "failed", "window jammed for good after " .. (job.tries or 1) .. " tries: can only be smashed (loud)"
                end
                job.tries = (job.tries or 1) + 1
                if job.tries <= (num(a.tries) or 10) then
                    ISTimedActionQueue.add(ISOpenCloseWindow:new(pl, o))
                    return "continue"
                end
                return "failed", "window did not open after " .. (job.tries - 1) .. " tries (not jammed yet): try again later or another way"
            end
            return "failed", "did not work"
        end, (wantOpen and "opening " or "closing ") .. tostring(k),
            T(wantOpen and "UI_PZBridge_StepOpen" or "UI_PZBridge_StepClose", kindName(k)))
    end
end

Tool("open", { params = { "x", "y", "z", "kind" }, fn = openClose(true) })
Tool("close", { params = { "x", "y", "z", "kind" }, fn = openClose(false) })

local function lockUnlock(lock)
    return function(a, ctx, p)
        local o, k, sq = doorOrWindow(a, p, "door")
        if not o then return "error", k end
        if not luautils.walkAdjWindowOrDoor(p, sq, o) then return "error", "cannot get close" end
        ISTimedActionQueue.add(ISLockDoor:new(p, o, lock))
        return L.actionJob(ctx, lock and "lock" or "unlock", function(job, pl)
            local locked = (U.try(o, "isLocked") == true) or (U.try(o, "isLockedByKey") == true)
            if locked == lock then return "done", lock and "locked" or "unlocked" end
            return "failed", "no key or did not work"
        end, lock and "locking" or "unlocking", T(lock and "UI_PZBridge_StepLock" or "UI_PZBridge_StepUnlock"))
    end
end

Tool("lock", { params = { "x", "y", "z" }, fn = lockUnlock(true) })
Tool("unlock", { params = { "x", "y", "z" }, fn = lockUnlock(false) })

Tool("climb_window", { params = { "x", "y", "z" }, fn = function(a, ctx, p)
    local o, k, sq = doorOrWindow(a, p, "window")
    if not o then return "error", k end
    if U.try(o, "isBarricaded") then return "error", "window is barricaded" end
    if not (U.try(o, "IsOpen") or U.try(o, "isSmashed")) then return "error", "window is closed: open or smash_window first" end
    if not luautils.walkAdjWindowOrDoor(p, sq, o) then return "error", "cannot get close" end
    -- осколки в раме режут при пролезании: сначала убрать их (как в ванильном меню)
    local cleaned = false
    if U.try(o, "isSmashed") and not U.try(o, "isGlassRemoved") then
        ISTimedActionQueue.add(ISRemoveBrokenGlass:new(p, o))
        cleaned = true
    end
    ISTimedActionQueue.add(ISClimbThroughWindow:new(p, o, 0))
    -- залез в здание с улицы, а рядом зомби: закрыть окно за собой (если оно целое)
    local fromOutside = p:getCurrentSquare() and p:getCurrentSquare():getBuilding() == nil
    local willClose = a.close_behind ~= false and fromOutside and not U.try(o, "isSmashed")
        and #P.zombies(p, num(a.close_radius) or 25, false) > 0
    if willClose then L.queueClose(p, o) end
    return L.actionJob(ctx, "climb_window", function(job, pl)
        local msg = cleaned and "removed glass from the frame and climbed through" or "climbed through"
        if willClose then msg = msg .. ", closed the window behind (zombies nearby)" end
        return "done", msg
    end, "climbing through window", T("UI_PZBridge_StepClimb"))
end })

-- Разбить окно: громко (игра поднимает шум на 70 клеток) и оставляет осколки на полу,
-- по которым босиком можно получить глубокую рану. Только в крайнем случае:
-- нужен явный noisy_ok=true, и рядом не должно быть зомби.
Tool("smash_window", { params = { "x", "y", "z" }, fn = function(a, ctx, p)
    local o, k, sq = doorOrWindow(a, p, "window")
    if not o then return "error", k end
    if U.try(o, "isSmashed") then return "ok", "already smashed" end
    if U.try(o, "IsOpen") then return "error", "window is open: no need to smash it, use climb_window" end
    if a.noisy_ok ~= true then
        return "error", "smashing is loud (heard about 70 tiles away) and leaves broken glass: last resort only; call again with noisy_ok=true"
    end
    local safeR = num(a.safe_radius) or 20
    local zs = P.zombies(p, safeR, false)
    if #zs > 0 then
        return "error", #zs .. " zombies within " .. safeR .. " tiles: smashing now is dangerous, deal with them or move away first"
    end
    if not luautils.walkAdjWindowOrDoor(p, sq, o) then return "error", "cannot get close" end
    ISTimedActionQueue.add(ISSmashWindow:new(p, o))
    return L.actionJob(ctx, "smash_window", nil, "smashing window", T("UI_PZBridge_StepSmash"))
end })

-- Убрать битое стекло с пола (клетка x,y,z или ближайшая в радиусе 3).
Tool("pickup_glass", { params = { "x", "y", "z" }, fn = function(a, ctx, p)
    local glass
    if num(a.x) and num(a.y) then
        local _, g = P.hasGlass(P.square(num(a.x), num(a.y), num(a.z) or math.floor(p:getZ())))
        glass = g
    else
        local bestD
        P.eachSquare(p:getX(), p:getY(), p:getZ(), 3, function(sq)
            local has, g = P.hasGlass(sq)
            if has then
                local d = U.dist(sq:getX() + 0.5, sq:getY() + 0.5, p:getX(), p:getY())
                if not bestD or d < bestD then glass, bestD = g, d end
            end
        end)
    end
    if not glass then return "error", "no broken glass found" end
    if not luautils.walkAdj(p, glass:getSquare()) then return "error", "cannot get close" end
    ISTimedActionQueue.add(ISPickupBrokenGlass:new(p, glass))
    return L.actionJob(ctx, "pickup_glass", nil, "picking up broken glass", T("UI_PZBridge_StepGlass"))
end })

Tool("barricade", { params = { "x", "y", "z" }, fn = function(a, ctx, p)
    local o, k, sq = doorOrWindow(a, p, "barricadable")
    if not o then return "error", k end
    local inv = p:getInventory()
    local hammer = inv:getFirstTagEvalRecurse(ItemTag.HAMMER, notBroken)
    local plank = inv:getFirstTypeRecurse("Base.Plank")
    local nails = inv:getItemCount("Base.Nails", true)
    local missing = {}
    if not hammer then missing[#missing + 1] = "hammer" end
    if not plank then missing[#missing + 1] = "plank" end
    if nails < 2 then missing[#missing + 1] = "nails (need 2)" end
    if #missing > 0 then return "error", "missing: " .. table.concat(missing, ", ") end
    if P.isDoor(o) and U.try(o, "IsOpen") then return "error", "close the door first" end
    local before = barricadeCount(o)
    if not luautils.walkAdjWindowOrDoor(p, sq, o) then return "error", "cannot get close" end
    ISInventoryPaneContextMenu.transferIfNeeded(p, hammer)
    ISInventoryPaneContextMenu.transferIfNeeded(p, plank)
    if p:getPrimaryHandItem() ~= hammer then
        ISTimedActionQueue.add(ISEquipWeaponAction:new(p, hammer, 50, true, false))
    end
    if p:getSecondaryHandItem() ~= plank then
        ISTimedActionQueue.add(ISEquipWeaponAction:new(p, plank, 50, false, false))
    end
    ISTimedActionQueue.add(PZBBarricadeAction:new(p, o))
    return L.actionJob(ctx, "barricade", function(job, pl)
        local after = barricadeCount(o)
        if after > before or (before == 0 and U.try(o, "isBarricaded")) then
            return "done", "plank nailed (" .. after .. ")"
        end
        return "failed", "plank not nailed"
    end, "barricading", T("UI_PZBridge_StepBarricade"))
end })

Tool("unbarricade", { params = { "x", "y", "z" }, fn = function(a, ctx, p)
    local o, k, sq = doorOrWindow(a, p, "barricadable")
    if not o then return "error", k end
    if not U.try(o, "isBarricaded") then return "ok", "not barricaded" end
    local tool = p:getInventory():getFirstEvalRecurse(function(it)
        return it:hasTag(ItemTag.REMOVE_BARRICADE) and not it:isBroken()
    end)
    if not tool then return "error", "no tool (crowbar or claw hammer)" end
    if not luautils.walkAdjWindowOrDoor(p, sq, o) then return "error", "cannot get close" end
    ISInventoryPaneContextMenu.transferIfNeeded(p, tool)
    if p:getPrimaryHandItem() ~= tool then
        ISTimedActionQueue.add(ISEquipWeaponAction:new(p, tool, 50, true, false))
    end
    ISTimedActionQueue.add(ISUnbarricadeAction:new(p, o))
    return L.actionJob(ctx, "unbarricade", nil, "removing planks", T("UI_PZBridge_StepUnbarricade"))
end })

---------------------------------------------------------------------------
-- Сон и отдых
---------------------------------------------------------------------------

local function findBed(p, a)
    local x, y, z = xyz(a, p)
    if x and y then
        local o = P.findObjectAt(x, y, z, "bed")
        return o
    end
    local o = nearestObject(p, num(a.radius) or 12, function(o) return P.isBed(o) end)
    return o
end

-- Подготовка ко сну в текущем здании: выключить свет, задёрнуть шторы,
-- положить подушку на кровать (игра даёт сон лучше, если подушка лежит на кровати
-- или в руке). Возвращает сводку того, что поставлено в очередь.
local function prepareSleep(p, bed)
    local sq0 = p:getCurrentSquare()
    local myB = sq0 and sq0:getBuilding()
    local out = { lights = 0, curtains = 0, pillow = false }
    if myB then
        P.eachSquare(p:getX(), p:getY(), p:getZ(), 14, function(sq)
            if sq:getBuilding() ~= myB then return end
            local objs = sq:getObjects()
            for i = 0, objs:size() - 1 do
                local o = objs:get(i)
                if instanceof(o, "IsoLightSwitch") and U.try(o, "isActivated") == true then
                    ISWorldObjectContextMenu.onToggleLight(nil, o, pnum(p))
                    out.lights = out.lights + 1
                end
                local c
                if P.isWindow(o) then c = U.try(o, "HasCurtains") elseif instanceof(o, "IsoCurtain") then c = o end
                if c and U.try(c, "IsOpen") == true then
                    ISWorldObjectContextMenu.onOpenCloseCurtain(nil, c, pnum(p))
                    out.curtains = out.curtains + 1
                end
            end
        end)
    end
    if bed and bed:getSquare() then
        local pillow
        for _, it in ipairs(P.inventoryItems(p)) do
            if U.try(it, "hasTag", ItemTag.PILLOW) == true then pillow = it; break end
        end
        if pillow and luautils.walkAdj(p, bed:getSquare(), true) then
            ISInventoryPaneContextMenu.transferIfNeeded(p, pillow)
            ISTimedActionQueue.add(ISDropWorldItemAction:new(p, pillow, bed:getSquare(), 0.5, 0.5, 0.4, 0, false))
            out.pillow = true
        end
    end
    return out
end

Tool("prepare_sleep", { params = { "x", "y", "z" }, fn = function(a, ctx, p)
    local bed = findBed(p, a)
    local r = prepareSleep(p, bed)
    ctx.data = r
    return L.actionJob(ctx, "prepare_sleep", function(job, pl)
        return "done", "lights off " .. r.lights .. ", curtains closed " .. r.curtains .. (r.pillow and ", pillow on the bed" or ", no pillow"), r
    end, "preparing to sleep", T("UI_PZBridge_StepSleep"))
end })

Tool("sleep", { params = { "x", "y", "z" }, fn = function(a, ctx, p)
    local bed = findBed(p, a)
    if a.floor then bed = nil end
    local prep = { lights = 0, curtains = 0, pillow = false }
    if a.prepare ~= false then prep = prepareSleep(p, bed) end
    local phase = "prepare"
    local function startSleep(pl)
        ISWorldObjectContextMenu.onConfirmSleep(nil, { internal = "YES" }, pnum(pl), bed)
    end
    if not P.isBusy(p) then phase = "sleep"; startSleep(p) end
    return L.actionJob(ctx, "sleep", function(job, pl)
        if phase == "prepare" then
            phase = "sleep"
            startSleep(pl)
            return "continue"
        end
        local note = " (lights off " .. prep.lights .. ", curtains closed " .. prep.curtains .. (prep.pillow and ", pillow on the bed)" or ")")
        if pl:isAsleep() then return "done", "sleeping" .. (bed and " in bed" or " on the floor") .. note, prep end
        return "failed", "could not fall asleep (zombies nearby, pain, panic or not tired)" .. note, prep
    end, "going to sleep", T("UI_PZBridge_StepSleep"))
end })

Tool("rest", { params = { "x", "y", "z" }, fn = function(a, ctx, p)
    local bed = findBed(p, a)
    if bed then
        ISWorldObjectContextMenu.onRest(bed, pnum(p))
    else
        ISTimedActionQueue.add(ISSitOnGround:new(p, nil))
    end
    return L.actionJob(ctx, "rest", function(job, pl) return "done", "resting" end, "resting", T("UI_PZBridge_StepRest"))
end })

---------------------------------------------------------------------------
-- Старые позиционные имена
---------------------------------------------------------------------------

Tool("walk", { params = { "x", "y", "z", "mode" }, fn = function(a, ctx, p) return PZBridge.tools.move_to.fn(a, ctx, p) end })
Tool("walk_rel", { params = { "dx", "dy", "mode" }, fn = function(a, ctx, p) return PZBridge.tools.move_rel.fn(a, ctx, p) end })

return PZBridge.tools
