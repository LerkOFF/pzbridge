-- PZBridge: инструменты, доступные агенту. Каждый инструмент - одна команда моста.
-- Все действия идут через ванильные timed actions и помощники контекстного меню,
-- поэтому игра сама считает время, анимации, вес и условия.

require "PZBridge/PZB_Loops"
require "TimedActions/ISInventoryTransferAction"

local U = PZBridge.U
local S = PZBridge.S
local P = PZBridge.P
local L = PZBridge.L
local T = PZBridge.tool

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
    if not spec then return nil, "не указан предмет (item_id, filter, fullType или what)" end
    if spec.id then
        for _, it in ipairs(P.inventoryItems(p)) do
            if U.try(it, "getID") == spec.id then return it end
        end
        return nil, "в инвентаре нет предмета с id " .. tostring(spec.id)
    end
    for _, it in ipairs(P.inventoryItems(p)) do
        if (not spec.filter or P.matches(it, spec.filter)) and (not pred or pred(it)) then return it end
    end
    return nil, "в инвентаре нет подходящего предмета"
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

T("get_state", { kind = "query", fn = function(a, ctx, p)
    return "ok", "state", PZBridge.buildState(p, true)
end })

T("get_access", { kind = "query", always = true, fn = function(a, ctx, p)
    return "ok", S.access and "access on" or "access off", { access = S.access }
end })

T("scan_zombies", { kind = "query", params = { "radius" }, fn = function(a, ctx, p)
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

T("scan_area", { kind = "query", params = { "radius" }, fn = function(a, ctx, p)
    local only = nil
    if type(a.only) == "table" then
        only = {}
        for _, k in ipairs(a.only) do only[k] = true end
    end
    local res = P.scanArea(p, { radius = num(a.radius) or 8, only = only, withItems = a.with_items == true })
    return "ok", "area scanned", res
end })

T("find_items", { kind = "query", params = { "filter", "where", "radius" }, fn = function(a, ctx, p)
    local f = a.filter
    if type(f) == "string" then f = { category = f } end
    local items, unexplored = P.findItems(p, f, a.where or "all", num(a.radius) or 10, num(a.limit) or 40)
    return "ok", #items .. " items", { items = items, unexplored_containers = unexplored }
end })

T("get_item", { kind = "query", params = { "id" }, fn = function(a, ctx, p)
    local it, where = P.findItemById(p, a.id or a.item_id, num(a.radius) or 15)
    if not it then return "error", "предмет не найден рядом" end
    if instanceof(it, "IsoWorldInventoryObject") then it = it:getItem() end
    local inf = P.itemInfo(it, true)
    inf.where = where
    return "ok", tostring(inf.name), inf
end })

T("get_building", { kind = "query", params = { "id" }, fn = function(a, ctx, p)
    local b
    if a.id then
        P.eachSquare(p:getX(), p:getY(), p:getZ(), 30, function(sq)
            local bb = sq:getBuilding()
            if bb and P.buildingKey(bb) == tostring(a.id) then b = bb; return "break" end
        end)
    else
        b = p:getCurrentBuilding()
    end
    if not b then return "error", a.id and "здание не найдено рядом" or "игрок не в здании" end
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

T("get_places", { kind = "query", always = false, fn = function(a, ctx, p)
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

T("get_guard", { kind = "query", always = true, fn = function(a, ctx, p)
    return "ok", "guard", PZBridge.guard
end })

---------------------------------------------------------------------------
-- Управление
---------------------------------------------------------------------------

T("stop", { kind = "control", fn = function(a, ctx, p)
    PZBridge.stopAll("stop command")
    return "ok", "остановлено"
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

T("pause", { kind = "control", fn = function(a, ctx, p)
    setPause(true)
    return "ok", "пауза"
end })

T("unpause", { kind = "control", fn = function(a, ctx, p)
    setPause(false)
    S.alert = nil
    return "ok", "игра идёт"
end })

T("resume", { kind = "control", fn = function(a, ctx, p)
    local job = S.pausedJob
    if not job then return "error", "нет задачи на паузе" end
    S.pausedJob = nil
    if isGamePaused() then setPause(false) end
    PZBridge.startJob(job, ctx)
    return "running", "продолжаю " .. tostring(job.name)
end })

T("set_guard", { kind = "control", always = false, fn = function(a, ctx, p)
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

T("autopause", { kind = "control", params = { "value", "distance" }, fn = function(a, ctx, p)
    local v = tostring(a.value or "on")
    PZBridge.guard.autopause = (v == "on" or v == "true" or v == "1")
    if num(a.distance) then PZBridge.guard.pause_distance = num(a.distance) end
    return "ok", "autopause " .. (PZBridge.guard.autopause and "on" or "off")
end })

T("autoflee", { kind = "control", params = { "value" }, fn = function(a, ctx, p)
    local v = tostring(a.value or "on")
    PZBridge.guard.autoflee = (v == "on" or v == "true" or v == "1")
    return "ok", "autoflee " .. (PZBridge.guard.autoflee and "on" or "off")
end })

T("reply", { kind = "control", always = true, params = { "text" }, fn = function(a, ctx, p)
    local text = tostring(a.text or "")
    if text == "" then return "error", "пустой текст" end
    PZBridge.chatAdd("agent", text)
    if a.say ~= false then pcall(p.Say, p, text) end
    PZBridge.event("reply", { text = text }, text)
    return "ok", "отправлено"
end })

T("say", { kind = "control", params = { "text" }, fn = function(a, ctx, p)
    p:Say(tostring(a.text or ""))
    return "ok", "сказал"
end })

T("mark_place", { kind = "control", params = { "name", "x", "y", "z" }, fn = function(a, ctx, p)
    if not a.name or a.name == "" then return "error", "нужно имя места" end
    local x, y, z = num(a.x) or math.floor(p:getX()), num(a.y) or math.floor(p:getY()), num(a.z) or math.floor(p:getZ())
    local mem = PZBridge.mem()
    local b = P.square(x, y, z)
    local bkey = b and b:getBuilding() and P.buildingKey(b:getBuilding()) or nil
    mem.places[tostring(a.name)] = { x = x, y = y, z = z, note = a.note, building = bkey, t = PZBridge.gameTimeStr() }
    return "ok", "место отмечено: " .. tostring(a.name), mem.places[tostring(a.name)]
end })

T("forget_place", { kind = "control", params = { "name" }, fn = function(a, ctx, p)
    local mem = PZBridge.mem()
    mem.places[tostring(a.name)] = nil
    return "ok", "забыл место"
end })

T("forget_visited", { kind = "control", fn = function(a, ctx, p)
    local mem = PZBridge.mem()
    mem.visitedBuildings = {}
    mem.visitedContainers = {}
    if a.known then mem.knownContainers = {} end
    return "ok", "память посещённого очищена"
end })

---------------------------------------------------------------------------
-- Движение и циклы
---------------------------------------------------------------------------

T("move_to", { params = { "x", "y", "z", "mode" }, fn = function(a, ctx, p)
    local x, y, z = xyz(a, p)
    if a.place then
        local pl = PZBridge.mem().places[tostring(a.place)]
        if not pl then return "error", "нет места " .. tostring(a.place) end
        x, y, z = pl.x, pl.y, pl.z
    end
    if not x or not y then return "error", "нужны x и y (или place)" end
    return L.startMoveTo(ctx, p, x, y, z, a)
end })

T("move_rel", { params = { "dx", "dy", "mode" }, fn = function(a, ctx, p)
    local dx, dy = num(a.dx) or 0, num(a.dy) or 0
    return L.startMoveTo(ctx, p, p:getX() + dx, p:getY() + dy, p:getZ(), a)
end })

T("flee", { params = { "distance", "mode" }, fn = function(a, ctx, p)
    return L.startFlee(ctx, p, { distance = num(a.distance), mode = a.mode, x = num(a.x), y = num(a.y) })
end })

T("search", { params = { "scope", "target" }, fn = function(a, ctx, p)
    return L.startSearch(ctx, p, a)
end })

T("fight", { params = { "until", "radius" }, fn = function(a, ctx, p)
    if a.kills and not a["until"] then a["until"] = "kills:" .. tostring(a.kills) end
    if a.radius then a.radius = num(a.radius) end
    return L.startFight(ctx, p, a)
end })

T("wait", { params = { "seconds" }, fn = function(a, ctx, p)
    return L.startWait(ctx, p, { seconds = num(a.seconds), game_minutes = num(a.game_minutes), interrupt_on_threat = a.interrupt_on_threat })
end })

T("face", { params = { "x", "y" }, fn = function(a, ctx, p)
    local x, y = num(a.x), num(a.y)
    if not x or not y then return "error", "нужны x и y" end
    p:faceLocation(x, y)
    return "ok", "повернулся"
end })

T("attack", { params = { "target" }, fn = function(a, ctx, p)
    local zs = P.zombies(p, 4, true)
    local target
    for _, z in ipairs(zs) do
        if a.target == nil or z.id == num(a.target) then target = z; break end
    end
    if not target then return "error", "рядом нет зомби" end
    if target.dist > L.weaponRange(p) + 0.6 then return "error", "зомби слишком далеко (" .. target.dist .. ")" end
    if L.attack(p, target.obj) then return "ok", "удар по зомби " .. tostring(target.id) end
    return "error", "атака не началась"
end })

---------------------------------------------------------------------------
-- Предметы
---------------------------------------------------------------------------

T("take", { params = { "what", "from" }, fn = function(a, ctx, p)
    local spec = itemSpec(a) or { all = true }
    local count = num(a.count) or (spec.all and 999) or 1
    local from = a.from
    -- 1) конкретный контейнер
    local srcC, srcO
    local items = {}
    if from and from ~= "nearby" and from ~= "floor" then
        srcC, srcO = P.resolveContainer(from)
        if not srcC then return "error", "контейнер " .. tostring(from) .. " не найден" end
        if not U.try(srcC, "isExplored") then
            local d = U.dist(srcO:getX() + 0.5, srcO:getY() + 0.5, p:getX(), p:getY())
            if d < 2 then
                L.exploreContainer(srcC, p)
                L.rememberContainer(from, srcC)
            else
                return "error", "контейнер ещё не осмотрен: сначала search scope=container target=" .. tostring(from)
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
    if #items == 0 then return "error", "подходящих предметов нет" end
    -- берём только из одного источника за команду (иначе ванильная ходьба сбросит очередь)
    local first = items[1]
    local taken = U.array({})
    if instanceof(first, "IsoWorldInventoryObject") then
        local sq = first:getSquare()
        if not luautils.walkAdj(p, sq, true) then return "error", "не могу подойти" end
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
        if c == p:getInventory() then return "error", "предмет уже в инвентаре" end
        if not luautils.walkToContainer(c, pnum(p)) then return "error", "не могу подойти к контейнеру" end
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
        return "done", "взял " .. #taken, { taken = taken }
    end, "беру " .. #taken)
end })

T("loot", { params = { "x", "y", "z", "what" }, fn = function(a, ctx, p)
    local x, y, z = xyz(a, p)
    local sq = P.square(x, y, z)
    if not sq then return "error", "клетка не найдена" end
    local objs = sq:getObjects()
    for i = 0, objs:size() - 1 do
        local o = objs:get(i)
        if (U.try(o, "getContainerCount") or 0) > 0 then
            local na = U.shallowCopy(a)
            na.from = P.containerId(sq, i, 0)
            return PZBridge.tools.take.fn(na, ctx, p)
        end
    end
    return "error", "на клетке нет контейнера"
end })

T("drop", { params = { "what" }, fn = function(a, ctx, p)
    local it, err = invItem(p, a)
    if not it then return "error", err end
    ISInventoryPaneContextMenu.dropItem(it, pnum(p))
    return L.actionJob(ctx, "drop", nil, "бросаю " .. tostring(it:getDisplayName()))
end })

T("transfer", { params = { "what", "to" }, fn = function(a, ctx, p)
    local it, err = invItem(p, a)
    if not it then return "error", err end
    local dest = P.resolveContainer(a.to)
    if not dest then return "error", "контейнер назначения не найден" end
    if not luautils.walkToContainer(dest, pnum(p)) then return "error", "не могу подойти к контейнеру" end
    ISTimedActionQueue.add(ISInventoryTransferUtil.newInventoryTransferAction(p, it, it:getContainer(), dest))
    return L.actionJob(ctx, "transfer", nil, "перекладываю " .. tostring(it:getDisplayName()))
end })

T("equip", { params = { "what", "slot" }, fn = function(a, ctx, p)
    local it, err = invItem(p, a)
    if not it then return "error", err end
    local slot = a.slot or "primary"
    local two = slot == "both" or (U.try(it, "isTwoHandWeapon") == true) or (U.try(it, "isRequiresEquippedBothHands") == true)
    ISInventoryPaneContextMenu.equipWeapon(it, slot ~= "secondary", two, pnum(p))
    return L.actionJob(ctx, "equip", function(job, pl)
        if pl:getPrimaryHandItem() == it or pl:getSecondaryHandItem() == it then return "done", "в руках: " .. tostring(it:getDisplayName()) end
        return "failed", "не удалось взять в руки"
    end, "беру в руки " .. tostring(it:getDisplayName()))
end })

T("unequip", { params = { "what" }, fn = function(a, ctx, p)
    local it
    if a.slot == "secondary" then it = p:getSecondaryHandItem()
    elseif itemSpec(a) then it = invItem(p, a)
    else it = p:getPrimaryHandItem() or p:getSecondaryHandItem() end
    if not it then return "ok", "руки уже свободны" end
    ISInventoryPaneContextMenu.unequipItem(it, pnum(p))
    return L.actionJob(ctx, "unequip", nil, "убираю " .. tostring(it:getDisplayName()))
end })

T("wear", { params = { "what" }, fn = function(a, ctx, p)
    local it, err = invItem(p, a)
    if not it then return "error", err end
    ISInventoryPaneContextMenu.wearItem(it, pnum(p))
    return L.actionJob(ctx, "wear", nil, "надеваю " .. tostring(it:getDisplayName()))
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

T("use", { params = { "what", "how" }, fn = function(a, ctx, p)
    local how = a.how or "eat"
    local percent = num(a.percent) or 1
    local it, err
    if how == "eat" then
        it, err = invItem(p, itemSpec(a) and a or { filter = { category = "food" } })
        if not it then return "error", err end
        if not instanceof(it, "Food") then return "error", "это не еда" end
        ISInventoryPaneContextMenu.eatItem(it, percent, pnum(p))
        return L.actionJob(ctx, "use", nil, "ем " .. tostring(it:getDisplayName()))
    elseif how == "drink" then
        it, err = invItem(p, itemSpec(a) and a or { filter = { category = "drink" } })
        if not it then
            it, err = invItem(p, { filter = { category = "water_clean" } })
        end
        if not it then return "error", err end
        local fc = U.try(it, "getFluidContainer")
        if fc and not fc:isEmpty() then
            if fc:isTainted() and not a.allow_dirty then return "error", "вода заражена, нужно allow_dirty=true или кипятить" end
            ISInventoryPaneContextMenu.onDrinkFluid(it, percent, p)
        elseif instanceof(it, "Food") then
            ISInventoryPaneContextMenu.eatItem(it, percent, pnum(p))
        else
            return "error", "из этого нельзя пить"
        end
        return L.actionJob(ctx, "use", nil, "пью " .. tostring(it:getDisplayName()))
    elseif how == "read" then
        it, err = invItem(p, a)
        if not it then return "error", err end
        ISInventoryPaneContextMenu.readItem(it, pnum(p))
        return L.actionJob(ctx, "use", nil, "читаю " .. tostring(it:getDisplayName()))
    elseif how == "pill" then
        it, err = invItem(p, a)
        if not it then return "error", err end
        ISInventoryPaneContextMenu.takePill(it, pnum(p))
        return L.actionJob(ctx, "use", nil, "принимаю " .. tostring(it:getDisplayName()))
    elseif how == "apply_bandage" or how == "bandage" then
        it, err = invItem(p, itemSpec(a) and a or { filter = { category = "medical" } }, function(x) return U.try(x, "isCanBandage") == true end)
        if not it then return "error", err or "нет бинта" end
        local part = pickWoundPart(p, a.part)
        if not part then return "error", "нет ран без повязки" end
        ISInventoryPaneContextMenu.transferIfNeeded(p, it)
        ISTimedActionQueue.add(ISApplyBandage:new(p, p, it, part, true))
        return L.actionJob(ctx, "use", function(job, pl)
            if part:bandaged() then return "done", "перевязал " .. tostring(part:getType()) end
            return "failed", "повязка не наложена"
        end, "перевязываю " .. tostring(part:getType()))
    end
    return "error", "неизвестный способ how=" .. tostring(how) .. " (eat, drink, read, pill, apply_bandage)"
end })

T("eat", { params = { "what" }, fn = function(a, ctx, p)
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

T("drink_from", { params = { "x", "y", "z" }, fn = function(a, ctx, p)
    local o, sq = waterSource(p, a)
    if not o then return "error", "источника воды рядом нет" end
    if U.try(o, "isTaintedWater") and not a.allow_dirty then
        return "error", "вода в источнике заражена (allow_dirty=true, чтобы пить всё равно)"
    end
    if (U.try(o, "getFluidAmount") or 0) <= 0 then return "error", "в источнике нет воды" end
    local thirst = CharacterStat and p:getStats():get(CharacterStat.THIRST) or 0
    if thirst < 0.05 then return "error", "персонаж не хочет пить" end
    ISWorldObjectContextMenu.onDrink(nil, o, pnum(p))
    return L.actionJob(ctx, "drink_from", nil, "пью из " .. P.objectName(o))
end })

T("drink", { params = { "what" }, fn = function(a, ctx, p)
    a.how = "drink"
    local st, msg, data = PZBridge.tools.use.fn(a, ctx, p)
    if st ~= "error" then return st, msg, data end
    -- нет напитка в инвентаре: ближайший чистый источник
    return PZBridge.tools.drink_from.fn({ radius = 10 }, ctx, p)
end })

T("fill", { params = { "what", "x", "y", "z" }, fn = function(a, ctx, p)
    local it, err = invItem(p, itemSpec(a) and a or { filter = { category = "water_container" } }, function(x)
        local fc = U.try(x, "getFluidContainer")
        return fc ~= nil and not fc:isFull()
    end)
    if not it then return "error", err end
    local o = waterSource(p, a)
    if not o then return "error", "источника воды рядом нет" end
    local tainted = U.try(o, "isTaintedWater") == true
    if tainted and not a.allow_dirty then return "error", "вода в источнике заражена (allow_dirty=true)" end
    ISInventoryPaneContextMenu.transferIfNeeded(p, it)
    if not luautils.walkAdjObject(p, o, true, true) then return "error", "не могу подойти к источнику" end
    ISTimedActionQueue.add(ISTakeWaterAction:new(p, it, o, tainted))
    return L.actionJob(ctx, "fill", nil, "набираю воду")
end })

---------------------------------------------------------------------------
-- Двери, окна, баррикады
---------------------------------------------------------------------------

local function doorOrWindow(a, p, kind)
    local x, y, z = xyz(a, p)
    if not x or not y then return nil, "нужны x y z" end
    local o, k, sq = P.findObjectAt(x, y, z, kind or a.kind)
    if not o then return nil, "на клетке нет двери или окна" end
    return o, k, sq
end

local function openClose(wantOpen)
    return function(a, ctx, p)
        local o, k, sq = doorOrWindow(a, p)
        if not o then return "error", k end
        if (U.try(o, "IsOpen") == true) == wantOpen then return "ok", wantOpen and "уже открыто" or "уже закрыто" end
        if wantOpen and U.try(o, "isBarricaded") then return "error", "заколочено" end
        if not luautils.walkAdjWindowOrDoor(p, sq, o) then return "error", "не могу подойти" end
        if k == "door" then
            ISTimedActionQueue.add(ISOpenCloseDoor:new(p, o))
        else
            if wantOpen and (U.try(o, "isLocked") or U.try(o, "isPermaLocked")) then
                -- ванильное действие попробует открыть; заблокированное окно не откроется
            end
            ISTimedActionQueue.add(ISOpenCloseWindow:new(p, o))
        end
        return L.actionJob(ctx, wantOpen and "open" or "close", function(job, pl)
            if (U.try(o, "IsOpen") == true) == wantOpen then return "done", wantOpen and "открыто" or "закрыто" end
            local locked = U.try(o, "isLocked") or U.try(o, "isLockedByKey") or U.try(o, "isPermaLocked")
            return "failed", locked and "заперто" or "не получилось"
        end, (wantOpen and "открываю " or "закрываю ") .. k)
    end
end

T("open", { params = { "x", "y", "z", "kind" }, fn = openClose(true) })
T("close", { params = { "x", "y", "z", "kind" }, fn = openClose(false) })

local function lockUnlock(lock)
    return function(a, ctx, p)
        local o, k, sq = doorOrWindow(a, p, "door")
        if not o then return "error", k end
        if not luautils.walkAdjWindowOrDoor(p, sq, o) then return "error", "не могу подойти" end
        ISTimedActionQueue.add(ISLockDoor:new(p, o, lock))
        return L.actionJob(ctx, lock and "lock" or "unlock", function(job, pl)
            local locked = (U.try(o, "isLocked") == true) or (U.try(o, "isLockedByKey") == true)
            if locked == lock then return "done", lock and "заперто" or "отперто" end
            return "failed", "нет ключа или не получилось"
        end, lock and "запираю" or "отпираю")
    end
end

T("lock", { params = { "x", "y", "z" }, fn = lockUnlock(true) })
T("unlock", { params = { "x", "y", "z" }, fn = lockUnlock(false) })

T("climb_window", { params = { "x", "y", "z" }, fn = function(a, ctx, p)
    local o, k, sq = doorOrWindow(a, p, "window")
    if not o then return "error", k end
    if U.try(o, "isBarricaded") then return "error", "окно заколочено" end
    if not (U.try(o, "IsOpen") or U.try(o, "isSmashed")) then return "error", "окно закрыто: сначала open или smash_window" end
    if not luautils.walkAdjWindowOrDoor(p, sq, o) then return "error", "не могу подойти" end
    ISTimedActionQueue.add(ISClimbThroughWindow:new(p, o, 0))
    return L.actionJob(ctx, "climb_window", nil, "лезу в окно")
end })

T("smash_window", { params = { "x", "y", "z" }, fn = function(a, ctx, p)
    local o, k, sq = doorOrWindow(a, p, "window")
    if not o then return "error", k end
    if U.try(o, "isSmashed") then return "ok", "уже разбито" end
    if not luautils.walkAdjWindowOrDoor(p, sq, o) then return "error", "не могу подойти" end
    ISTimedActionQueue.add(ISSmashWindow:new(p, o))
    return L.actionJob(ctx, "smash_window", nil, "разбиваю окно")
end })

T("barricade", { params = { "x", "y", "z" }, fn = function(a, ctx, p)
    local o, k, sq = doorOrWindow(a, p, "barricadable")
    if not o then return "error", k end
    local inv = p:getInventory()
    local hammer = inv:getFirstTagEvalRecurse(ItemTag.HAMMER, notBroken)
    local plank = inv:getFirstTypeRecurse("Base.Plank")
    local nails = inv:getItemCount("Base.Nails", true)
    local missing = {}
    if not hammer then missing[#missing + 1] = "молоток" end
    if not plank then missing[#missing + 1] = "доска" end
    if nails < 2 then missing[#missing + 1] = "гвозди (нужно 2)" end
    if #missing > 0 then return "error", "не хватает: " .. table.concat(missing, ", ") end
    if P.isDoor(o) and U.try(o, "IsOpen") then return "error", "сначала закрой дверь" end
    local before = barricadeCount(o)
    if not luautils.walkAdjWindowOrDoor(p, sq, o) then return "error", "не могу подойти" end
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
            return "done", "прибил доску (" .. after .. ")"
        end
        return "failed", "доска не прибита"
    end, "заколачиваю")
end })

T("unbarricade", { params = { "x", "y", "z" }, fn = function(a, ctx, p)
    local o, k, sq = doorOrWindow(a, p, "barricadable")
    if not o then return "error", k end
    if not U.try(o, "isBarricaded") then return "ok", "не заколочено" end
    local tool = p:getInventory():getFirstEvalRecurse(function(it)
        return it:hasTag(ItemTag.REMOVE_BARRICADE) and not it:isBroken()
    end)
    if not tool then return "error", "нет инструмента (лом, гвоздодёр)" end
    if not luautils.walkAdjWindowOrDoor(p, sq, o) then return "error", "не могу подойти" end
    ISInventoryPaneContextMenu.transferIfNeeded(p, tool)
    if p:getPrimaryHandItem() ~= tool then
        ISTimedActionQueue.add(ISEquipWeaponAction:new(p, tool, 50, true, false))
    end
    ISTimedActionQueue.add(ISUnbarricadeAction:new(p, o))
    return L.actionJob(ctx, "unbarricade", nil, "отрываю доски")
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

T("sleep", { params = { "x", "y", "z" }, fn = function(a, ctx, p)
    local bed = findBed(p, a)
    if a.floor then bed = nil end
    ISWorldObjectContextMenu.onConfirmSleep(nil, { internal = "YES" }, pnum(p), bed)
    return L.actionJob(ctx, "sleep", function(job, pl)
        if pl:isAsleep() then return "done", "сплю" .. (bed and " на кровати" or " на полу") end
        return "failed", "не удалось уснуть (зомби рядом, боль, паника или не устал)"
    end, "ложусь спать")
end })

T("rest", { params = { "x", "y", "z" }, fn = function(a, ctx, p)
    local bed = findBed(p, a)
    if bed then
        ISWorldObjectContextMenu.onRest(bed, pnum(p))
    else
        ISTimedActionQueue.add(ISSitOnGround:new(p, nil))
    end
    return L.actionJob(ctx, "rest", function(job, pl) return "done", "отдыхаю" end, "отдыхаю")
end })

---------------------------------------------------------------------------
-- Старые позиционные имена
---------------------------------------------------------------------------

T("walk", { params = { "x", "y", "z", "mode" }, fn = function(a, ctx, p) return PZBridge.tools.move_to.fn(a, ctx, p) end })
T("walk_rel", { params = { "dx", "dy", "mode" }, fn = function(a, ctx, p) return PZBridge.tools.move_rel.fn(a, ctx, p) end })

return PZBridge.tools
