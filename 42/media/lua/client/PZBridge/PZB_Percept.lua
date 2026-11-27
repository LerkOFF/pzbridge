-- PZBridge: восприятие. Зомби, предметы, контейнеры, двери, окна, вода,
-- здания, транспорт, состояние персонажа. Только чтение мира, без действий.

require "PZBridge/PZB_Core"

local U = PZBridge.U
local S = PZBridge.S
PZBridge.P = PZBridge.P or {}
local P = PZBridge.P

---------------------------------------------------------------------------
-- Зомби
---------------------------------------------------------------------------

function P.zombieId(z)
    local id = U.try(z, "getID")
    if id == nil then id = U.try(z, "getOnlineID") end
    return id or -1
end

-- Видит ли игрок зомби: клетка зомби видима для игрока 0.
function P.playerSees(z, player)
    local sq = U.try(z, "getCurrentSquare")
    if sq then
        local v = U.try(sq, "isCanSee", player:getPlayerNum())
        if v ~= nil then return v == true end
    end
    return U.try(player, "CanSee", z) == true
end

function P.zombieInfo(z, player)
    local zx, zy, zz = z:getX(), z:getY(), z:getZ()
    local px, py = player:getX(), player:getY()
    local target = U.try(z, "getTarget")
    local targeting = (target ~= nil and target == player)
    local info = {
        id = P.zombieId(z),
        x = U.round(zx, 1), y = U.round(zy, 1), z = math.floor(zz),
        dist = U.round(U.dist(zx, zy, px, py), 1),
        targeting = targeting,                         -- цель зомби - игрок (идёт к нему)
        sees_player = targeting and (U.try(z, "isTargetVisible") == true) or false,
        visible = P.playerSees(z, player),           -- игрок видит зомби
        on_floor = U.try(z, "isOnFloor") == true,
        crawling = U.try(z, "isCrawling") == true,
    }
    return info
end

-- Список живых зомби в радиусе, отсортированный по расстоянию.
-- Обновляет память известных зомби.
function P.zombies(player, radius, sameLevelOnly)
    radius = radius or 20
    local out = {}
    local cell = getCell()
    if not cell then return out end
    local list = cell:getZombieList()
    if not list then return out end
    local px, py, pz = player:getX(), player:getY(), player:getZ()
    local now = U.nowMs()
    for i = 0, list:size() - 1 do
        local z = list:get(i)
        if z and not z:isDead() then
            local zx, zy = z:getX(), z:getY()
            local d = U.dist(zx, zy, px, py)
            local dz = math.abs(z:getZ() - pz)
            if d <= radius and (not sameLevelOnly or dz < 1) then
                local info = P.zombieInfo(z, player)
                info.obj = z
                out[#out + 1] = info
                S.knownZombies[info.id] = { id = info.id, x = info.x, y = info.y, z = info.z, seen_ms = now }
            end
        end
    end
    table.sort(out, function(a, b) return a.dist < b.dist end)
    return out
end

-- Убрать служебное поле obj перед сериализацией.
function P.strip(list)
    local out = U.array({})
    for i, v in ipairs(list) do
        local c = {}
        for k, val in pairs(v) do
            if k ~= "obj" then c[k] = val end
        end
        out[i] = c
    end
    return out
end

-- Оценка угрозы вокруг игрока.
function P.threat(player, g)
    g = g or PZBridge.guard
    local zs = P.zombies(player, math.max(g.threat_radius or 15, g.crowd_radius or 6, 20), false)
    local t = { nearest = nil, nearest_dist = nil, count = 0, seeing = 0, targeting = 0,
                danger = false, crowd = 0, list = zs }
    for _, z in ipairs(zs) do
        if z.dist <= (g.threat_radius or 15) then
            t.count = t.count + 1
            if z.targeting then t.targeting = t.targeting + 1 end
            if z.sees_player then t.seeing = t.seeing + 1 end
        end
        if z.dist <= (g.crowd_radius or 6) then t.crowd = t.crowd + 1 end
    end
    if zs[1] then
        t.nearest = zs[1]
        t.nearest_dist = zs[1].dist
    end
    t.danger = (t.seeing > 0) or (t.nearest_dist ~= nil and t.nearest_dist <= (g.danger_radius or 5))
    -- уровень: none / near / danger
    if t.danger then t.level = "danger"
    elseif t.count > 0 then t.level = "near"
    else t.level = "none" end
    return t
end

---------------------------------------------------------------------------
-- Предметы
---------------------------------------------------------------------------

local function fluidInfo(item)
    local fc = U.try(item, "getFluidContainer")
    if not fc then return nil end
    local info = { amount = U.round(U.try(fc, "getAmount") or 0, 3), capacity = U.round(U.try(fc, "getCapacity") or 0, 3) }
    info.empty = U.try(fc, "isEmpty") == true
    if not info.empty then
        local primary = U.try(fc, "getPrimaryFluid")
        info.fluid = primary and U.try(primary, "getFluidTypeString") or nil
        info.tainted = (U.try(fc, "isTainted") == true) or (Fluid and Fluid.TaintedWater and U.try(fc, "contains", Fluid.TaintedWater) == true) or false
        info.poison = U.try(fc, "isPoisonous") == true
        info.water = (info.fluid == "Water" or info.fluid == "TaintedWater" or info.fluid == "CarbonatedWater")
        local bev = false
        if primary and FluidCategory then
            bev = (U.try(primary, "isCategory", FluidCategory.Beverage) == true) or (U.try(primary, "isCategory", FluidCategory.Water) == true)
        end
        info.beverage = bev or info.water
        info.alcohol = primary and FluidCategory and U.try(primary, "isCategory", FluidCategory.Alcoholic) == true or false
    end
    return info
end
P.fluidInfo = fluidInfo

function P.itemCategory(item)
    if instanceof(item, "HandWeapon") then
        if U.try(item, "isRanged") then return "firearm" end
        return "weapon"
    end
    local fi = fluidInfo(item)
    if fi and not fi.empty and fi.beverage then
        if fi.water then return "water" end
        return "drink"
    end
    if instanceof(item, "Food") then
        local th = U.try(item, "getThirstChange") or 0
        local hu = U.try(item, "getHungerChange") or 0
        if th < 0 and math.abs(hu) < 0.001 then return "drink" end
        return "food"
    end
    local dc = U.try(item, "getDisplayCategory") or ""
    if dc == "FirstAid" or dc == "Bandage" or dc == "Wound" or U.try(item, "isCanBandage") then return "medical" end
    if dc == "Ammo" then return "ammo" end
    if U.try(item, "IsClothing") then return "clothing" end
    if dc == "Tool" or dc == "ToolWeapon" or dc == "Cooking" or dc == "Gardening" then return "tool" end
    if instanceof(item, "InventoryContainer") then return "container" end
    if U.try(item, "IsLiterature") then return "literature" end
    if dc == "WaterContainer" then return "water_container" end
    return "other"
end

function P.itemInfo(item, detail)
    local info = {
        id = U.try(item, "getID"),
        fullType = U.try(item, "getFullType"),
        name = U.try(item, "getDisplayName") or U.try(item, "getName"),
        cat = P.itemCategory(item),
        weight = U.round(U.try(item, "getActualWeight") or U.try(item, "getWeight") or 0, 2),
    }
    if U.try(item, "isEquipped") then info.equipped = true end
    if U.try(item, "isWorn") then info.worn = true end
    if instanceof(item, "Food") then
        info.rotten = U.try(item, "isRotten") == true
        info.fresh = U.try(item, "isFresh") == true
        info.cooked = U.try(item, "isCooked") == true
        info.burnt = U.try(item, "isBurnt") == true
        info.frozen = U.try(item, "isFrozen") == true
        info.poison = U.try(item, "isPoison") == true
        info.dangerous_uncooked = U.try(item, "isbDangerousUncooked") == true
        info.cookable = U.try(item, "isCookable") == true
        info.calories = U.round(U.try(item, "getCalories") or 0, 0)
        info.hunger = U.round(U.try(item, "getHungerChange") or 0, 3)
        info.thirst = U.round(U.try(item, "getThirstChange") or 0, 3)
        if detail then
            info.age = U.round(U.try(item, "getAge") or 0, 1)
            info.off_age = U.try(item, "getOffAge")
            info.off_age_max = U.try(item, "getOffAgeMax")
        end
    end
    local fi = fluidInfo(item)
    if fi then info.fluid = fi end
    if instanceof(item, "HandWeapon") then
        info.condition = U.try(item, "getCondition")
        info.condition_max = U.try(item, "getConditionMax")
        info.broken = U.try(item, "isBroken") == true
        info.ranged = U.try(item, "isRanged") == true
        info.dmg_min = U.round(U.try(item, "getMinDamage") or 0, 2)
        info.dmg_max = U.round(U.try(item, "getMaxDamage") or 0, 2)
        info.range = U.round(U.try(item, "getMaxRange") or 0, 2)
        info.two_hand = (U.try(item, "isTwoHandWeapon") == true) or (U.try(item, "isRequiresEquippedBothHands") == true)
        if info.ranged and detail then
            info.ammo = U.try(item, "getCurrentAmmoCount")
        end
    end
    if detail then
        info.display_category = U.try(item, "getDisplayCategory")
        local c = U.try(item, "getContainer")
        if c then info.container_type = U.try(c, "getType") end
    end
    return info
end

-- Универсальный фильтр предметов.
-- filter = { category = "food"|"drink"|"water_clean"|"water_dirty"|"weapon"|"firearm"|"medical"|"tool"|"clothing"|"ammo"|"any",
--            tag = "ItemTag-имя", fullType = "Base.X", name = "подстрока",
--            not_spoiled = true, no_cooking = false, safe = true, min_condition = 0 }
function P.matches(item, f)
    if not f then return true end
    if type(f) == "string" then
        f = { category = f }
    end
    if f.fullType and U.try(item, "getFullType") ~= f.fullType then return false end
    if f.type and U.try(item, "getType") ~= f.type then return false end
    if f.name then
        local n = U.lower(U.try(item, "getDisplayName") or "") .. " " .. U.lower(U.try(item, "getFullType") or "")
        if not string.find(n, U.lower(f.name), 1, true) then return false end
    end
    if f.tag and ItemTag then
        local tag = ItemTag[string.upper(f.tag)]
        if not tag or not U.try(item, "hasTag", tag) then return false end
    end
    if f.min_condition and U.try(item, "getCondition") and item:getCondition() < f.min_condition then return false end
    local cat = f.category
    if cat == nil or cat == "any" then return true end
    local safe = (f.safe ~= false)
    local notSpoiled = (f.not_spoiled ~= false)
    local c = P.itemCategory(item)
    if cat == "food" then
        if not instanceof(item, "Food") or c == "drink" then return false end
        if safe then
            if U.try(item, "isPoison") then return false end
            if U.try(item, "isbDangerousUncooked") and not U.try(item, "isCooked") then return false end
            if U.try(item, "isBurnt") then return false end
        end
        if notSpoiled and U.try(item, "isRotten") then return false end
        if f.no_cooking and U.try(item, "isCookable") and not U.try(item, "isCooked") then return false end
        if (U.try(item, "getHungerChange") or 0) >= 0 then return false end
        return true
    elseif cat == "drink" then
        local fi = fluidInfo(item)
        if fi and not fi.empty then
            if safe and (fi.poison or fi.tainted or fi.alcohol) then return false end
            return fi.beverage
        end
        if instanceof(item, "Food") and (U.try(item, "getThirstChange") or 0) < 0 then
            if safe and U.try(item, "isPoison") then return false end
            if notSpoiled and U.try(item, "isRotten") then return false end
            return true
        end
        return false
    elseif cat == "water_clean" then
        local fi = fluidInfo(item)
        return fi ~= nil and not fi.empty and fi.water and not fi.tainted and not fi.poison
    elseif cat == "water_dirty" then
        local fi = fluidInfo(item)
        return fi ~= nil and not fi.empty and fi.water and fi.tainted
    elseif cat == "weapon" then
        if not instanceof(item, "HandWeapon") then return false end
        if U.try(item, "isBroken") then return false end
        if U.try(item, "isRanged") and not f.firearms then return false end
        -- отсеять «оружие» вроде ножниц с ничтожным уроном
        return (U.try(item, "getMaxDamage") or 0) > 0.1
    elseif cat == "firearm" then
        return instanceof(item, "HandWeapon") and U.try(item, "isRanged") == true
    elseif cat == "water_container" then
        return U.try(item, "getFluidContainer") ~= nil
    else
        return c == cat
    end
end

-- Оценка оружия ближнего боя: средний урон * доля прочности.
function P.weaponScore(item)
    if not instanceof(item, "HandWeapon") then return -1 end
    if U.try(item, "isBroken") then return -1 end
    local mn = U.try(item, "getMinDamage") or 0
    local mx = U.try(item, "getMaxDamage") or 0
    local cond = U.try(item, "getCondition") or 1
    local cmax = U.try(item, "getConditionMax") or 1
    if cmax <= 0 then cmax = 1 end
    local ratio = 0.3 + 0.7 * (cond / cmax)
    return ((mn + mx) / 2) * ratio
end

-- Все предметы инвентаря, включая вложенные сумки.
function P.inventoryItems(player)
    local out = {}
    local function walk(container, depth)
        if not container or depth > 3 then return end
        local items = container:getItems()
        for i = 0, items:size() - 1 do
            local it = items:get(i)
            out[#out + 1] = it
            if instanceof(it, "InventoryContainer") then
                walk(U.try(it, "getInventory"), depth + 1)
            end
        end
    end
    walk(player:getInventory(), 0)
    return out
end

function P.containerItems(container)
    local out = {}
    if not container then return out end
    local items = container:getItems()
    for i = 0, items:size() - 1 do
        out[#out + 1] = items:get(i)
    end
    return out
end

---------------------------------------------------------------------------
-- Мир вокруг: клетки, объекты, контейнеры
---------------------------------------------------------------------------

function P.square(x, y, z)
    local cell = getCell()
    if not cell then return nil end
    return cell:getGridSquare(math.floor(x), math.floor(y), math.floor(z or 0))
end

-- Обойти клетки квадрата радиуса r вокруг (cx, cy) на уровне z.
function P.eachSquare(cx, cy, cz, r, fn)
    cx, cy, cz = math.floor(cx), math.floor(cy), math.floor(cz)
    for dy = -r, r do
        for dx = -r, r do
            local sq = P.square(cx + dx, cy + dy, cz)
            if sq then
                if fn(sq) == "break" then return end
            end
        end
    end
end

function P.containerId(sq, objIndex, ci)
    return sq:getX() .. "," .. sq:getY() .. "," .. sq:getZ() .. "," .. objIndex .. "," .. ci
end

function P.parseCid(cid)
    if type(cid) ~= "string" then return nil end
    local p = U.split(cid, ",")
    if #p < 5 then return nil end
    return tonumber(p[1]), tonumber(p[2]), tonumber(p[3]), tonumber(p[4]), tonumber(p[5])
end

-- Найти контейнер по id "x,y,z,objIndex,containerIndex".
function P.resolveContainer(cid)
    local x, y, z, oi, ci = P.parseCid(cid)
    if not x then return nil end
    local sq = P.square(x, y, z)
    if not sq then return nil end
    local objs = sq:getObjects()
    if oi >= 0 and oi < objs:size() then
        local o = objs:get(oi)
        local cc = U.try(o, "getContainerCount") or 0
        if ci < cc then return o:getContainerByIndex(ci), o, sq end
    end
    -- индекс объекта мог сдвинуться: ищем любой контейнер на клетке
    for i = 0, objs:size() - 1 do
        local o = objs:get(i)
        local cc = U.try(o, "getContainerCount") or 0
        if cc > ci then return o:getContainerByIndex(ci), o, sq end
    end
    return nil
end

function P.objectName(o)
    local props = U.try(o, "getProperties")
    local name = props and U.try(props, "get", "CustomName") or nil
    if not name or name == "" then name = U.try(o, "getObjectName") end
    if not name or name == "" then
        local spr = U.try(o, "getSprite")
        name = spr and U.try(spr, "getName") or "object"
    end
    return name
end

function P.isDoor(o)
    if instanceof(o, "IsoDoor") then return true end
    if instanceof(o, "IsoThumpable") and U.try(o, "isDoor") then return true end
    return false
end

function P.isWindow(o)
    return instanceof(o, "IsoWindow")
end

function P.doorInfo(o, sq)
    return {
        known_locked = P.knownStuck(o, sq),
        kind = "door",
        x = sq:getX(), y = sq:getY(), z = sq:getZ(),
        open = U.try(o, "IsOpen") == true,
        locked = (U.try(o, "isLocked") == true) or (U.try(o, "isLockedByKey") == true),
        barricaded = U.try(o, "isBarricaded") == true,
        north = U.try(o, "getNorth") == true,
        name = P.objectName(o),
    }
end

-- Босиком ли персонаж (нет надетой обуви). Битое стекло на полу режет босые ноги.
function P.barefoot(player)
    local worn = U.try(player, "getWornItems")
    if not worn then return false end
    for i = 0, worn:size() - 1 do
        local wi = worn:get(i)
        local loc = tostring(U.try(wi, "getLocation") or "")
        if string.find(string.lower(loc), "shoe", 1, true) then return false end
    end
    return true
end

-- Битое стекло на клетке (осколки от разбитого окна).
function P.hasGlass(sq)
    if not sq then return false end
    local objs = sq:getObjects()
    for i = 0, objs:size() - 1 do
        if instanceof(objs:get(i), "IsoBrokenGlass") then return true, objs:get(i) end
    end
    return false
end

-- Память мода: дверь или окно уже не открылись с первой попытки.
function P.knownStuck(o, sq)
    local mem = PZBridge.mem()
    if not mem.lockedDoors or not sq then return false end
    local k = sq:getX() .. "," .. sq:getY() .. "," .. sq:getZ() .. (U.try(o, "getNorth") and "N" or "W")
    return mem.lockedDoors[k] ~= nil
end

function P.windowInfo(o, sq)
    return {
        stuck = P.knownStuck(o, sq),
        kind = "window",
        x = sq:getX(), y = sq:getY(), z = sq:getZ(),
        open = U.try(o, "IsOpen") == true,
        locked = U.try(o, "isLocked") == true,
        perma_locked = U.try(o, "isPermaLocked") == true,
        smashed = U.try(o, "isSmashed") == true,
        glass_removed = U.try(o, "isGlassRemoved") == true,
        barricaded = U.try(o, "isBarricaded") == true,
        north = U.try(o, "getNorth") == true,
    }
end

-- Источник воды в мире (раковина, ванна, кулер, бочка, река...).
function P.waterSourceInfo(o, sq)
    if instanceof(o, "IsoWorldInventoryObject") then return nil end
    local amount = U.try(o, "getFluidAmount") or 0
    local hasWater = U.try(o, "hasWater") == true
    if not hasWater and amount <= 0 then return nil end
    local tainted = U.try(o, "isTaintedWater") == true
    return {
        kind = "water",
        x = sq:getX(), y = sq:getY(), z = sq:getZ(),
        name = P.objectName(o),
        amount = U.round(amount, 2),
        clean = not tainted,
        tainted = tainted,
        object_index = U.try(o, "getObjectIndex"),
    }
end

function P.containerInfo(container, o, sq, objIndex, ci, withItems)
    local mem = PZBridge.mem()
    local cid = P.containerId(sq, objIndex, ci)
    local explored = U.try(container, "isExplored") == true
    local info = {
        id = cid,
        x = sq:getX(), y = sq:getY(), z = sq:getZ(),
        type = U.try(container, "getType"),
        name = P.objectName(o),
        explored = explored,
        visited = mem.visitedContainers[cid] == true,
    }
    if explored then
        local items = container:getItems()
        info.count = items:size()
        if withItems then
            local list = U.array({})
            for i = 0, math.min(items:size(), 60) - 1 do
                list[#list + 1] = P.itemInfo(items:get(i), false)
            end
            info.items = list
        end
    end
    return info
end

function P.isBed(o)
    local props = U.try(o, "getProperties")
    if not props or not IsoFlagType then return false end
    return U.try(props, "has", IsoFlagType.bed) == true
end

function P.buildingKey(building)
    local def = U.try(building, "getDef")
    if not def then return nil end
    local id = U.try(def, "getIDString") or tostring(U.try(def, "getID"))
    return id, def
end

function P.buildingInfo(building, player)
    local key, def = P.buildingKey(building)
    if not key then return nil end
    local mem = PZBridge.mem()
    local info = {
        id = key,
        x = def:getX(), y = def:getY(), x2 = def:getX2(), y2 = def:getY2(),
        rooms = U.try(def, "getRoomsNumber"),
        all_explored = U.try(def, "isAllExplored") == true,
        visited = mem.visitedBuildings[key] == true,
        alarmed = U.try(def, "isAlarmed") == true,
        residential = U.try(building, "isResidential") == true,
    }
    if player then
        local cx = (def:getX() + def:getX2()) / 2
        local cy = (def:getY() + def:getY2()) / 2
        info.dist = U.round(U.dist(cx, cy, player:getX(), player:getY()), 1)
        local pb = player:getCurrentBuilding()
        info.inside = (pb ~= nil and pb == building)
    end
    return info
end

-- Полный обзор местности.
-- opts = { radius, doors, windows, containers, water, items, beds, vehicles, buildings, withItems }
function P.scanArea(player, opts)
    opts = opts or {}
    local r = U.clamp(math.floor(opts.radius or 8), 1, 30)
    local res = {
        doors = U.array({}), windows = U.array({}), containers = U.array({}),
        water = U.array({}), floor_items = U.array({}), beds = U.array({}), glass = U.array({}),
        buildings = U.array({}), vehicles = U.array({}), rooms = U.array({}),
    }
    local seenB, seenV, seenR = {}, {}, {}
    local px, py, pz = player:getX(), player:getY(), player:getZ()
    local all = (opts.only == nil)
    local function want(k) return all or opts.only[k] end
    P.eachSquare(px, py, pz, r, function(sq)
        local d = U.round(U.dist(sq:getX() + 0.5, sq:getY() + 0.5, px, py), 1)
        local objs = sq:getObjects()
        for i = 0, objs:size() - 1 do
            local o = objs:get(i)
            if want("doors") and P.isDoor(o) then
                local inf = P.doorInfo(o, sq); inf.dist = d
                res.doors[#res.doors + 1] = inf
            elseif want("windows") and P.isWindow(o) then
                local inf = P.windowInfo(o, sq); inf.dist = d
                res.windows[#res.windows + 1] = inf
            elseif want("glass") and instanceof(o, "IsoBrokenGlass") then
                res.glass[#res.glass + 1] = { x = sq:getX(), y = sq:getY(), z = sq:getZ(), dist = d }
            end
            local cc = U.try(o, "getContainerCount") or 0
            if want("containers") and cc > 0 and not instanceof(o, "IsoDeadBody") then
                for ci = 0, cc - 1 do
                    local c = o:getContainerByIndex(ci)
                    if c then
                        local inf = P.containerInfo(c, o, sq, i, ci, opts.withItems)
                        inf.dist = d
                        res.containers[#res.containers + 1] = inf
                    end
                end
            end
            if want("water") then
                local w = P.waterSourceInfo(o, sq)
                if w then w.dist = d; res.water[#res.water + 1] = w end
            end
            if want("beds") and P.isBed(o) then
                res.beds[#res.beds + 1] = { x = sq:getX(), y = sq:getY(), z = sq:getZ(), dist = d, name = P.objectName(o) }
            end
        end
        if want("items") then
            local wobs = sq:getWorldObjects()
            for i = 0, wobs:size() - 1 do
                local wo = wobs:get(i)
                local it = U.try(wo, "getItem")
                if it then
                    local inf = P.itemInfo(it, false)
                    inf.x, inf.y, inf.z, inf.dist = sq:getX(), sq:getY(), sq:getZ(), d
                    res.floor_items[#res.floor_items + 1] = inf
                end
            end
        end
        if want("buildings") then
            local b = sq:getBuilding()
            if b then
                local key = P.buildingKey(b)
                if key and not seenB[key] then
                    seenB[key] = true
                    res.buildings[#res.buildings + 1] = P.buildingInfo(b, player)
                end
            end
            local room = sq:getRoom()
            if room then
                local rd = U.try(room, "getRoomDef")
                local rid = rd and (U.try(rd, "getIDString") or tostring(U.try(rd, "getID"))) or nil
                if rid and not seenR[rid] then
                    seenR[rid] = true
                    res.rooms[#res.rooms + 1] = { id = rid, name = U.try(room, "getName"), z = rd and U.try(rd, "getZ") or nil,
                                                 explored = rd and U.try(rd, "isExplored") == true }
                end
            end
        end
        if want("vehicles") then
            local v = U.try(sq, "getVehicleContainer")
            if v then
                local key = tostring(v)
                if not seenV[key] then
                    seenV[key] = true
                    local script = U.try(v, "getScriptName")
                    res.vehicles[#res.vehicles + 1] = { x = U.round(v:getX(), 1), y = U.round(v:getY(), 1), z = math.floor(v:getZ()),
                                                       name = script, dist = d }
                end
            end
        end
    end)
    local function byDist(a, b) return (a.dist or 0) < (b.dist or 0) end
    for _, k in ipairs({ "doors", "windows", "containers", "water", "floor_items", "beds", "buildings", "vehicles" }) do
        table.sort(res[k], byDist)
    end
    return res
end

-- Найти дверь/окно/контейнер/воду на клетке.
function P.findObjectAt(x, y, z, kind)
    local sq = P.square(x, y, z)
    if not sq then return nil end
    local objs = sq:getObjects()
    for i = 0, objs:size() - 1 do
        local o = objs:get(i)
        if (kind == "door" or kind == nil) and P.isDoor(o) then return o, "door", sq end
        if (kind == "window" or kind == nil) and P.isWindow(o) then return o, "window", sq end
        if kind == "water" and P.waterSourceInfo(o, sq) then return o, "water", sq end
        if kind == "bed" and P.isBed(o) then return o, "bed", sq end
        if kind == "barricadable" and (P.isDoor(o) or P.isWindow(o)) then return o, "barricadable", sq end
    end
    -- дверь или окно на северной/западной стене соседней клетки
    if kind == "door" or kind == "window" or kind == nil or kind == "barricadable" then
        for _, d in ipairs({ { 1, 0 }, { 0, 1 } }) do
            local s2 = P.square(x + d[1], y + d[2], z)
            if s2 then
                local o2 = s2:getObjects()
                for i = 0, o2:size() - 1 do
                    local o = o2:get(i)
                    if (kind ~= "window" and P.isDoor(o)) then return o, "door", s2 end
                    if (kind ~= "door" and P.isWindow(o)) then return o, "window", s2 end
                end
            end
        end
    end
    return nil
end

-- Найти предмет по id: инвентарь, контейнеры и пол вокруг (radius).
function P.findItemById(player, id, radius)
    id = tonumber(id)
    if not id then return nil end
    for _, it in ipairs(P.inventoryItems(player)) do
        if U.try(it, "getID") == id then return it, "inventory" end
    end
    local found, where
    P.eachSquare(player:getX(), player:getY(), player:getZ(), radius or 10, function(sq)
        local objs = sq:getObjects()
        for i = 0, objs:size() - 1 do
            local o = objs:get(i)
            local cc = U.try(o, "getContainerCount") or 0
            for ci = 0, cc - 1 do
                local c = o:getContainerByIndex(ci)
                if c and U.try(c, "isExplored") then
                    local it = U.try(c, "getItemWithID", id)
                    if it then found = it; where = P.containerId(sq, i, ci); return "break" end
                end
            end
        end
        local wobs = sq:getWorldObjects()
        for i = 0, wobs:size() - 1 do
            local wo = wobs:get(i)
            local it = U.try(wo, "getItem")
            if it and U.try(it, "getID") == id then found = wo; where = "floor"; return "break" end
        end
    end)
    return found, where
end

-- Поиск предметов по фильтру. where = inventory | nearby | known | all
function P.findItems(player, filter, where, radius, limit)
    where = where or "all"
    limit = limit or 40
    local out = U.array({})
    local function add(it, w, extra)
        if #out >= limit then return end
        if P.matches(it, filter) then
            local inf = P.itemInfo(it, false)
            inf.where = w
            if extra then for k, v in pairs(extra) do inf[k] = v end end
            out[#out + 1] = inf
        end
    end
    if where == "inventory" or where == "all" then
        for _, it in ipairs(P.inventoryItems(player)) do add(it, "inventory") end
    end
    local unexplored = U.array({})
    if where == "nearby" or where == "all" then
        local px, py = player:getX(), player:getY()
        P.eachSquare(px, py, player:getZ(), U.clamp(radius or 10, 1, 25), function(sq)
            local d = U.round(U.dist(sq:getX() + 0.5, sq:getY() + 0.5, px, py), 1)
            local objs = sq:getObjects()
            for i = 0, objs:size() - 1 do
                local o = objs:get(i)
                local cc = U.try(o, "getContainerCount") or 0
                for ci = 0, cc - 1 do
                    local c = o:getContainerByIndex(ci)
                    if c then
                        local cid = P.containerId(sq, i, ci)
                        if U.try(c, "isExplored") then
                            for _, it in ipairs(P.containerItems(c)) do add(it, cid, { dist = d }) end
                        elseif #unexplored < 30 then
                            unexplored[#unexplored + 1] = { id = cid, type = U.try(c, "getType"), dist = d }
                        end
                    end
                end
            end
            local wobs = sq:getWorldObjects()
            for i = 0, wobs:size() - 1 do
                local it = U.try(wobs:get(i), "getItem")
                if it then add(it, "floor", { x = sq:getX(), y = sq:getY(), z = sq:getZ(), dist = d }) end
            end
        end)
    end
    if where == "known" or where == "all" then
        local mem = PZBridge.mem()
        for cid, kc in pairs(mem.knownContainers) do
            if type(kc) == "table" and kc.items then
                for _, inf in ipairs(kc.items) do
                    if #out >= limit then break end
                    if P.matchesInfo(inf, filter) then
                        local c = U.shallowCopy(inf)
                        c.where = cid
                        c.known = true
                        out[#out + 1] = c
                    end
                end
            end
        end
    end
    table.sort(out, function(a, b) return (a.dist or 0) < (b.dist or 0) end)
    return out, unexplored
end

-- Упрощённая проверка фильтра по сохранённой сводке предмета (память контейнеров).
function P.matchesInfo(inf, f)
    if not f then return true end
    if type(f) == "string" then f = { category = f } end
    if f.fullType and inf.fullType ~= f.fullType then return false end
    if f.name then
        local n = U.lower(inf.name) .. " " .. U.lower(inf.fullType)
        if not string.find(n, U.lower(f.name), 1, true) then return false end
    end
    local cat = f.category
    if not cat or cat == "any" then return true end
    if cat == "water_clean" then return inf.cat == "water" and inf.fluid and not inf.fluid.tainted end
    if cat == "water_dirty" then return inf.cat == "water" and inf.fluid and inf.fluid.tainted end
    if cat == "food" then return inf.cat == "food" and not inf.rotten and not inf.poison end
    return inf.cat == cat
end

---------------------------------------------------------------------------
-- Персонаж
---------------------------------------------------------------------------

local STAT_NAMES = { "HUNGER", "THIRST", "FATIGUE", "ENDURANCE", "PANIC", "STRESS", "PAIN",
                     "SICKNESS", "FOOD_SICKNESS", "BOREDOM", "UNHAPPINESS", "WETNESS", "TEMPERATURE",
                     "ZOMBIE_INFECTION", "INTOXICATION" }

local MOODLE_NAMES = { "HUNGRY", "THIRST", "TIRED", "ENDURANCE", "PANIC", "STRESS", "PAIN", "SICK",
                       "BLEEDING", "INJURED", "HEAVY_LOAD", "WET", "HYPOTHERMIA", "HYPERTHERMIA",
                       "ZOMBIE", "DRUNK", "BORED", "UNHAPPY", "FOOD_EATEN", "HAS_A_COLD" }

function P.stats(player)
    local st = player:getStats()
    local out = {}
    if CharacterStat then
        for _, n in ipairs(STAT_NAMES) do
            local key = CharacterStat[n]
            if key then
                local v = U.try(st, "get", key)
                if v ~= nil then out[string.lower(n)] = U.round(v, 3) end
            end
        end
    end
    return out
end

function P.moodles(player)
    local m = player:getMoodles()
    local out = {}
    if MoodleType then
        for _, n in ipairs(MOODLE_NAMES) do
            local key = MoodleType[n]
            if key then
                local lvl = U.try(m, "getMoodleLevel", key)
                if lvl and lvl > 0 then out[string.lower(n)] = lvl end
            end
        end
    end
    return out
end

function P.body(player)
    local bd = player:getBodyDamage()
    local out = {
        health = U.round(U.try(bd, "getOverallBodyHealth") or 0, 1),
        bleeding_parts = U.try(bd, "getNumPartsBleeding") or 0,
        bitten_parts = U.try(bd, "getNumPartsBitten") or 0,
        scratched_parts = U.try(bd, "getNumPartsScratched") or 0,
        -- заражение зомби (вирус Нокса), отдельно от ложного заражения (ипохондрик)
        -- и от инфекции раны (infected_wound у части тела)
        infected = U.try(bd, "IsInfected") == true,
        fake_infected = U.try(bd, "IsFakeInfected") == true,
        barefoot = P.barefoot(player),
        wounds = U.array({}),
    }
    local parts = U.try(bd, "getBodyParts")
    if parts then
        for i = 0, parts:size() - 1 do
            local bp = parts:get(i)
            local bleeding = (U.try(bp, "getBleedingTime") or 0) > 0
            local w = {
                part = tostring(U.try(bp, "getType")),
                health = U.round(U.try(bp, "getHealth") or 100, 0),
            }
            local any = false
            if bleeding then w.bleeding = true; any = true end
            if U.try(bp, "IsInfected") == true then w.zombie_infected = true; any = true end
            if (U.try(bp, "getWoundInfectionLevel") or 0) > 0 then w.infected_wound = true; any = true end
            if U.try(bp, "bandaged") then w.bandaged = true end
            if U.try(bp, "bitten") then w.bitten = true; any = true end
            if U.try(bp, "scratched") then w.scratched = true; any = true end
            if U.try(bp, "isCut") then w.cut = true; any = true end
            if U.try(bp, "isDeepWounded") then w.deep_wound = true; any = true end
            if U.try(bp, "haveGlass") then w.glass = true; any = true end
            if U.try(bp, "haveBullet") then w.bullet = true; any = true end
            if (U.try(bp, "getFractureTime") or 0) > 0 then w.fracture = true; any = true end
            if U.try(bp, "bandaged") then w.bandaged = true end
            if any then out.wounds[#out.wounds + 1] = w end
        end
    end
    return out
end

function P.isBusy(player)
    local q = ISTimedActionQueue.queues and ISTimedActionQueue.queues[player]
    local queued = q and #q.queue or 0
    local doing = false
    local ok, r = pcall(ISTimedActionQueue.isPlayerDoingAction, player)
    if ok then doing = r end
    local current = nil
    if q and q.queue[1] then current = q.queue[1].Type end
    return (queued > 0 or doing), queued, current
end

return P
