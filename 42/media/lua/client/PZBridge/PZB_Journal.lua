-- PZBridge: журнал игрока. Записывает, что делает сам игрок (и агент, с пометкой),
-- чтобы агент потом учился на игре человека: какие действия, где, с какими предметами,
-- бои, урон, перемещения. Файл ~/Zomboid/Lua/pzbridge_journal.txt, одна JSON-строка на запись.

require "PZBridge/PZB_Tools"
require "TimedActions/ISTimedActionQueue"

local U = PZBridge.U
local S = PZBridge.S
local P = PZBridge.P

local J = {}
PZBridge.J = J
J.file = "pzbridge_journal.txt"

local function who()
    -- действие агента: доступ включён и идёт задача мода
    if S.access and S.job then return "agent" end
    return "player"
end

local function objName(o)
    if not o then return nil end
    local ok, n = pcall(P.objectName, o)
    if ok and n then return tostring(n) end
    return tostring(U.try(o, "getObjectName") or U.try(o, "getName") or "?")
end

local function itemDesc(it)
    if not it or not U.try(it, "getFullType") then return nil end
    return { name = tostring(it:getDisplayName()), type = tostring(it:getFullType()), cat = P.itemCategory(it) }
end

local function contDesc(c)
    if not c then return nil end
    local t = tostring(U.try(c, "getType") or "?")
    local parent = U.try(c, "getParent")
    local sq = parent and U.try(parent, "getSquare")
    local room = sq and sq:getRoom() and U.try(sq:getRoom(), "getName")
    return { type = t, room = room and tostring(room) or nil }
end

function J.write(kind, data)
    local p = getPlayer()
    if not p then return end
    local rec = {
        t = PZBridge.gameTimeStr(), rt = U.nowMs(), by = who(), kind = kind,
        x = math.floor(p:getX()), y = math.floor(p:getY()), z = math.floor(p:getZ()),
        hp = U.round(p:getBodyDamage():getOverallBodyHealth(), 0),
    }
    local sq = p:getCurrentSquare()
    if sq and sq:getRoom() then rec.room = tostring(U.try(sq:getRoom(), "getName") or "") end
    if p:getVehicle() then rec.vehicle = true end
    for k, v in pairs(data or {}) do rec[k] = v end
    U.appendLine(J.file, U.jsonEncode(rec))
end

-- Все действия игры проходят через очередь: записываем тип и главное содержание.
local origAdd = ISTimedActionQueue.add
ISTimedActionQueue.add = function(action)
    pcall(function()
        if not action or not action.Type then return end
        local ty = tostring(action.Type)
        -- ходьбу пишем реже, она шумит
        if ty == "ISWalkToTimedAction" or ty == "ISPathFindAction" or ty == "PZBWalkAction" then return end
        local d = { action = ty }
        d.item = itemDesc(action.item) or itemDesc(action.weapon) or itemDesc(action.food)
        if action.srcContainer then d.from = contDesc(action.srcContainer) end
        if action.destContainer then d.to = contDesc(action.destContainer) end
        local o = action.object or action.door or action.window or action.curtain or action.vehicle
        if o and not d.item then d.object = objName(o) end
        if action.bodyPart then d.body_part = tostring(U.try(action.bodyPart, "getType")) end
        J.write("action", d)
    end)
    return origAdd(action)
end

-- Бой и урон
Events.OnZombieDead.Add(function(z)
    pcall(function()
        local p = getPlayer()
        if not p then return end
        local by = U.try(z, "getAttackedBy")
        if by ~= p then return end
        local w = p:getPrimaryHandItem()
        J.write("kill", { weapon = w and tostring(w:getDisplayName()) or "hands", on_floor = U.try(z, "isOnFloor") == true })
    end)
end)

if Events.OnPlayerGetDamage then
    Events.OnPlayerGetDamage.Add(function(character, damageType, damage)
        pcall(function()
            if character ~= getPlayer() then return end
            J.write("damage", { type = tostring(damageType), amount = U.round(tonumber(damage) or 0, 2) })
        end)
    end)
end

if Events.OnWeaponSwing then
    Events.OnWeaponSwing.Add(function(character, weapon)
        pcall(function()
            if character ~= getPlayer() then return end
            local now = U.nowMs()
            if now - (J.lastSwing or 0) < 1500 then return end
            J.lastSwing = now
            local zs = P.zombies(character, 6, false)
            J.write("swing", { weapon = weapon and tostring(weapon:getDisplayName()) or "hands",
                shove = U.try(character, "isDoShove") == true, zombies_near = #zs })
        end)
    end)
end

-- Перемещение и обстановка раз в 15 секунд
Events.OnTick.Add(function()
    local now = U.nowMs()
    if now - (J.lastPos or 0) < 15000 then return end
    J.lastPos = now
    pcall(function()
        local p = getPlayer()
        if not p or isGamePaused() then return end
        local zs = P.zombies(p, 20, false)
        local st = p:getStats()
        local function stat(n) return CharacterStat and U.round(st:get(CharacterStat[n]) or 0, 2) or nil end
        local w = p:getPrimaryHandItem()
        J.write("tick", {
            zombies20 = #zs, nearest = zs[1] and zs[1].dist or nil,
            sneaking = p:isSneaking() == true, running = U.try(p, "isRunning") == true,
            hunger = stat("HUNGER"), thirst = stat("THIRST"), fatigue = stat("FATIGUE"), endurance = stat("ENDURANCE"),
            weapon = w and tostring(w:getDisplayName()) or nil,
            speed = UIManager and UIManager.getSpeedControls and U.try(UIManager.getSpeedControls(), "getCurrentGameSpeed") or nil,
        })
    end)
end)

Events.OnGameStart.Add(function()
    pcall(J.write, "session", { note = "game loaded" })
end)

return J
