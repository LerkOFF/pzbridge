-- PZBridge: циклы, которым нужна реакция быстрее, чем думает агент.
-- move_to (с режимом движения по угрозе и открытием дверей), search, fight, flee, wait.
-- Все циклы работают через ванильные timed actions и очередь ISTimedActionQueue.

require "PZBridge/PZB_Percept"
require "TimedActions/ISBaseTimedAction"
require "TimedActions/ISTimedActionQueue"
require "TimedActions/WalkToTimedAction"

local U = PZBridge.U
local S = PZBridge.S
local P = PZBridge.P
local T = PZBridge.T
PZBridge.L = PZBridge.L or {}
local L = PZBridge.L

-- Режим движения для окна: walk/sneak/run/sprint -> перевод.
local MODE_KEYS = { walk = "UI_PZBridge_Mode_walk", sneak = "UI_PZBridge_Mode_sneak",
                    run = "UI_PZBridge_Mode_run", sprint = "UI_PZBridge_Mode_sprint" }
function L.modeName(m)
    local k = MODE_KEYS[tostring(m)]
    if k then return T(k) end
    return tostring(m)
end

---------------------------------------------------------------------------
-- Ходьба с принудительным бегом. Бег и спринт у IsoPlayer каждый кадр
-- выставляются из ввода игрока, поэтому повторяем setRunning/setSprinting
-- в update() действия (оно вызывается каждый кадр, пока действие идёт).
---------------------------------------------------------------------------

PZBWalkAction = ISWalkToTimedAction:derive("PZBWalkAction")

function PZBWalkAction:update()
    local m = S.moveMode
    if m == "run" then
        pcall(self.character.setRunning, self.character, true)
    elseif m == "sprint" then
        pcall(self.character.setSprinting, self.character, true)
        pcall(self.character.setRunning, self.character, true)
    end
    ISWalkToTimedAction.update(self)
end

function PZBWalkAction:new(character, location)
    local o = ISWalkToTimedAction.new(self, character, location)
    return o
end

---------------------------------------------------------------------------
-- Предохранитель (guard): проверка здоровья, крови, выносливости, толпы.
---------------------------------------------------------------------------

-- g - таблица порогов (вызов перекрывает глобальные).
-- Возвращает причину (англ., для агента) и её перевод для игрока, или nil.
function L.guardReason(player, g, threat, weaponNeeded)
    local bd = player:getBodyDamage()
    local hp = U.try(bd, "getOverallBodyHealth") or 100
    if g.hp_min and hp < g.hp_min then
        return "low health " .. math.floor(hp), T("UI_PZBridge_GuardLowHp", math.floor(hp))
    end
    local bleed = U.try(bd, "getNumPartsBleeding") or 0
    if g.bleeding_max and bleed > g.bleeding_max then
        return "heavy bleeding (" .. bleed .. " parts)", T("UI_PZBridge_GuardBleeding", bleed)
    end
    local endu = 1
    if CharacterStat then endu = U.try(player:getStats(), "get", CharacterStat.ENDURANCE) or 1 end
    if g.endurance_min and endu < g.endurance_min then
        return "out of breath, endurance " .. U.round(endu, 2), T("UI_PZBridge_GuardBreath", U.round(endu, 2))
    end
    if g.crowd_max and threat and threat.crowd > g.crowd_max then
        return "too many zombies nearby (" .. threat.crowd .. ")", T("UI_PZBridge_GuardCrowd", threat.crowd)
    end
    return nil
end

function L.mergeGuard(p)
    local g = U.shallowCopy(PZBridge.guard)
    if type(p) == "table" then
        for k, v in pairs(p) do
            if g[k] ~= nil and type(v) == type(g[k]) then g[k] = v end
        end
    end
    return g
end

---------------------------------------------------------------------------
-- Mover: доводит игрока до клетки, переподаёт путь, открывает двери.
---------------------------------------------------------------------------

local Mover = {}
Mover.__index = Mover

-- opts: mode (auto|walk|sneak|run|sprint), adjacent (идти к соседней свободной клетке),
--       arrive (дистанция прибытия), open_doors (true по умолчанию)
function L.newMover(tx, ty, tz, opts)
    opts = opts or {}
    local m = setmetatable({}, Mover)
    m.tx, m.ty, m.tz = math.floor(tx), math.floor(ty), math.floor(tz or 0)
    m.mode = opts.mode or "auto"
    m.adjacent = opts.adjacent == true
    m.arrive = opts.arrive or 1.0
    m.openDoors = opts.open_doors ~= false
    m.repaths = 0
    m.maxRepaths = opts.max_repaths or 5
    m.state = "init"
    m.lastMoveMs = U.nowMs()
    m.doorsOpened = 0
    return m
end

function Mover:dest(player)
    local sq = P.square(self.tx, self.ty, self.tz)
    if not sq then return nil, "square not loaded (too far)" end
    if self.adjacent or not U.try(sq, "isFree", false) then
        local adj = AdjacentFreeTileFinder.Find(sq, player)
        if adj then return adj end
        if self.adjacent then return nil, "no free square next to the target" end
    end
    return sq
end

function Mover:distLeft(player)
    if self.destSq then
        return U.dist(self.destSq:getX() + 0.5, self.destSq:getY() + 0.5, player:getX(), player:getY())
    end
    return U.dist(self.tx + 0.5, self.ty + 0.5, player:getX(), player:getY())
end

function Mover:arrived(player)
    if math.abs(player:getZ() - self.tz) >= 1 and not self.adjacent then return false end
    if self.destSq then
        local d = self:distLeft(player)
        if d <= math.max(0.75, self.arrive) then return true end
    end
    local d0 = U.dist(self.tx + 0.5, self.ty + 0.5, player:getX(), player:getY())
    if self.adjacent then
        local psq = player:getCurrentSquare()
        local tsq = P.square(self.tx, self.ty, self.tz)
        if psq and tsq and d0 < 1.7 and U.try(psq, "canReachTo", tsq) and math.abs(player:getZ() - self.tz) < 1 then
            return true
        end
        return false
    end
    return d0 <= self.arrive
end

function Mover:begin(player)
    local sq, err = self:dest(player)
    if not sq then return false, err end
    self.destSq = sq
    ISTimedActionQueue.clear(player)
    local a = PZBWalkAction:new(player, sq)
    ISTimedActionQueue.add(a)
    self.action = a
    self.state = "moving"
    self.lastPos = { player:getX(), player:getY() }
    self.lastMoveMs = U.nowMs()
    return true
end

-- Выбрать фактический режим движения.
function Mover:applyMode(player, threat)
    local mode = self.mode
    if mode == "auto" then
        if threat == nil or threat.level == "none" then mode = "walk"
        elseif threat.level == "near" then
            if threat.seeing > 0 or threat.targeting > 0 then mode = "run" else mode = "sneak" end
        else mode = "run" end
    end
    self.current = mode
    if mode == "run" or mode == "sprint" then
        S.moveMode = mode
        pcall(player.setSneaking, player, false)
    else
        S.moveMode = nil
        pcall(player.setSneaking, player, mode == "sneak")
    end
    return mode
end

-- Закрытая дверь рядом (до 1.5 клетки), не запертая и не заколоченная.
function L.closedDoorNear(player, tx, ty)
    local best, bestD
    local px, py = player:getX(), player:getY()
    P.eachSquare(px, py, player:getZ(), 1, function(sq)
        local objs = sq:getObjects()
        for i = 0, objs:size() - 1 do
            local o = objs:get(i)
            if P.isDoor(o) and not U.try(o, "IsOpen") and not U.try(o, "isBarricaded") then
                local locked = U.try(o, "isLocked") or U.try(o, "isLockedByKey")
                if not locked then
                    local d = U.dist(sq:getX() + 0.5, sq:getY() + 0.5, px, py)
                    -- дверь должна быть примерно в сторону цели
                    local toT = U.dist(sq:getX() + 0.5, sq:getY() + 0.5, tx + 0.5, ty + 0.5)
                    local meT = U.dist(px, py, tx + 0.5, ty + 0.5)
                    if d <= 1.6 and toT <= meT + 0.5 and (not bestD or d < bestD) then
                        best, bestD = o, d
                    end
                end
            end
        end
    end)
    return best
end

-- Шаг. Возвращает "moving" | "arrived" | "failed", сообщение (англ.)
-- и, для шага "moving", текст для окна (перевод) или nil.
function Mover:update(player, now, threat)
    if self.state == "init" then
        local ok, err = self:begin(player)
        if not ok then return "failed", err end
    end
    self:applyMode(player, threat)
    if self:arrived(player) then
        S.moveMode = nil
        return "arrived"
    end
    -- прогресс
    local lp = self.lastPos
    if lp and U.dist(lp[1], lp[2], player:getX(), player:getY()) > 0.3 then
        self.lastPos = { player:getX(), player:getY() }
        self.lastMoveMs = now
    end
    local busy = P.isBusy(player)
    local stuck = (now - self.lastMoveMs) > 6000
    if (not busy) or stuck then
        if self.openDoors and self.doorsOpened < 6 then
            local door = L.closedDoorNear(player, self.tx, self.ty)
            if door then
                ISTimedActionQueue.clear(player)
                ISTimedActionQueue.add(ISOpenCloseDoor:new(player, door))
                self.doorsOpened = self.doorsOpened + 1
                self.state = "door"
                self.lastMoveMs = now
                return "moving", "opening door", T("UI_PZBridge_StepOpenDoor")
            end
        end
        if self.state == "door" and busy then return "moving" end
        self.repaths = self.repaths + 1
        if self.repaths > self.maxRepaths then
            S.moveMode = nil
            return "failed", "cannot reach (no path or stuck)"
        end
        local ok, err = self:begin(player)
        if not ok then return "failed", err end
    end
    return "moving"
end

function Mover:cancel(player)
    S.moveMode = nil
    if player then
        pcall(ISTimedActionQueue.clear, player)
    end
end

---------------------------------------------------------------------------
-- move_to
---------------------------------------------------------------------------

function L.startMoveTo(ctx, p, x, y, z, args)
    args = args or {}
    local g = L.mergeGuard(args)
    local useGuard = args.guard ~= false
    local mover = L.newMover(x, y, z or p:getZ(), { mode = args.mode or "auto", adjacent = args.adjacent, arrive = args.arrive, open_doors = args.open_doors })
    local timeout = (args.timeout or 300) * 1000
    local job = { name = ctx.tool or "move_to", step = "going to " .. math.floor(x) .. "," .. math.floor(y),
                  stepUI = T("UI_PZBridge_StepGoTo", math.floor(x), math.floor(y)) }
    job.update = function(job, player, now)
        local threat = P.threat(player, g)
        job.threat = threat
        if useGuard and threat.danger then
            mover:cancel(player)
            local reason = threat.seeing > 0 and "a zombie sees me" or ("zombie at " .. tostring(threat.nearest_dist) .. " tiles")
            PZBridge.event("guard", { reason = reason, nearest = threat.nearest and P.strip({ threat.nearest })[1] or nil }, reason)
            if args.flee_on_threat then
                L.startFlee({ id = job.cmdId, tool = "flee" }, player, { distance = g.flee_distance, mode = "run" })
                return nil
            end
            return "interrupted", "threat: " .. reason, { threat = reason, x = U.round(player:getX(), 1), y = U.round(player:getY(), 1) }
        end
        if now - job.startedMs > timeout then
            mover:cancel(player)
            return "failed", "move timeout"
        end
        local st, msg, msgUI = mover:update(player, now, threat)
        job.step = (msg or ("going to " .. mover.tx .. "," .. mover.ty)) .. " [" .. tostring(mover.current) .. "]"
        job.stepUI = (msgUI or T("UI_PZBridge_StepGoTo", mover.tx, mover.ty)) .. " [" .. L.modeName(mover.current) .. "]"
        if st == "arrived" then
            return "done", "arrived", { x = U.round(player:getX(), 1), y = U.round(player:getY(), 1), z = math.floor(player:getZ()) }
        elseif st == "failed" then
            return "failed", msg
        end
        return nil
    end
    job.stop = function(job, player) mover:cancel(player) end
    PZBridge.startJob(job, ctx)
    return "running", "moving"
end

---------------------------------------------------------------------------
-- flee: убежать от зомби (ближайшего или от точки) на distance клеток.
---------------------------------------------------------------------------

function L.fleePoint(player, fx, fy, dist)
    local px, py, pz = player:getX(), player:getY(), player:getZ()
    local ax, ay = px - fx, py - fy
    local len = math.sqrt(ax * ax + ay * ay)
    if len < 0.01 then ax, ay, len = 1, 0, 1 end
    ax, ay = ax / len, ay / len
    local base = math.atan2 and math.atan2(ay, ax) or math.atan(ay, ax)
    local offsets = { 0, 0.5, -0.5, 1.0, -1.0, 1.5, -1.5 }
    for _, scale in ipairs({ 1.0, 0.7, 0.45 }) do
        for _, off in ipairs(offsets) do
            local a = base + off
            local tx = px + math.cos(a) * dist * scale
            local ty = py + math.sin(a) * dist * scale
            local sq = P.square(tx, ty, pz)
            if sq and U.try(sq, "isFree", false) and U.try(sq, "isSolidFloor") ~= false then
                return sq
            end
        end
    end
    return nil
end

function L.startFlee(ctx, p, args)
    args = args or {}
    local dist = args.distance or PZBridge.guard.flee_distance or 15
    local mode = args.mode or "run"
    local fx, fy
    if args.x and args.y then
        fx, fy = args.x, args.y
    else
        local zs = P.zombies(p, 30, false)
        if not zs[1] then return "ok", "no zombies to flee from" end
        -- центр масс ближних зомби
        local sx, sy, n = 0, 0, 0
        for _, z in ipairs(zs) do
            if z.dist <= 12 or n == 0 then sx = sx + z.x; sy = sy + z.y; n = n + 1 end
        end
        fx, fy = sx / n, sy / n
    end
    local sq = L.fleePoint(p, fx, fy, dist)
    if not sq then return "error", "no free square to retreat to" end
    local mover = L.newMover(sq:getX(), sq:getY(), sq:getZ(), { mode = mode, arrive = 1.5 })
    local job = { name = "flee", step = "fleeing", stepUI = T("UI_PZBridge_StepFlee") }
    job.update = function(job, player, now)
        local st, msg = mover:update(player, now, nil)
        local dNow = U.dist(player:getX(), player:getY(), fx, fy)
        job.step = "fleeing, distance to threat " .. U.round(dNow, 1)
        job.stepUI = T("UI_PZBridge_StepFleeDist", U.round(dNow, 1))
        if st == "arrived" or dNow >= dist then
            mover:cancel(player)
            return "done", "retreated", { x = U.round(player:getX(), 1), y = U.round(player:getY(), 1), dist_from_threat = U.round(dNow, 1) }
        elseif st == "failed" then
            return "failed", msg
        end
        if now - job.startedMs > 60000 then return "failed", "flee timeout" end
        return nil
    end
    job.stop = function(job, player) mover:cancel(player) end
    PZBridge.startJob(job, ctx)
    return "running", "fleeing"
end

---------------------------------------------------------------------------
-- search: обход контейнеров с фильтром.
---------------------------------------------------------------------------

-- Собрать контейнеры по области.
local function containerEntry(c, o)
    if not c or not o then return nil end
    local sq = U.try(o, "getSquare")
    if not sq then return nil end
    local oi = U.try(o, "getObjectIndex") or 0
    local ci = 0
    local cc = U.try(o, "getContainerCount") or 1
    for i = 0, cc - 1 do
        if o:getContainerByIndex(i) == c then ci = i end
    end
    return { c = c, o = o, sq = sq, cid = P.containerId(sq, oi, ci) }
end

function L.collectContainers(player, scope, target, radius, includeCorpses)
    local list = {}
    local seen = {}
    local function add(e)
        if e and not seen[e.cid] then
            if (not includeCorpses) and instanceof(e.o, "IsoDeadBody") then return end
            if U.try(e.c, "getType") == "floor" then return end
            seen[e.cid] = true
            list[#list + 1] = e
        end
    end
    local function addSquare(sq)
        local objs = sq:getObjects()
        for i = 0, objs:size() - 1 do
            local o = objs:get(i)
            local cc = U.try(o, "getContainerCount") or 0
            for ci = 0, cc - 1 do
                local c = o:getContainerByIndex(ci)
                if c then add({ c = c, o = o, sq = sq, cid = P.containerId(sq, i, ci) }) end
            end
        end
    end
    local function addRoom(room)
        local cl = U.try(room, "getContainer")
        if cl then
            for i = 0, cl:size() - 1 do
                local c = cl:get(i)
                add(containerEntry(c, U.try(c, "getParent")))
            end
        end
        local sqs = U.try(room, "getSquares")
        if sqs then
            for i = 0, sqs:size() - 1 do addSquare(sqs:get(i)) end
        end
    end
    local building = nil
    if scope == "container" then
        local c, o, sq = P.resolveContainer(target)
        if c then add({ c = c, o = o, sq = sq, cid = target }) end
        return list, nil
    elseif scope == "room" then
        local sq = player:getCurrentSquare()
        local room = sq and sq:getRoom()
        if not room then return list, "player is not in a room" end
        addRoom(room)
        return list, nil
    elseif scope == "building" then
        if target then
            P.eachSquare(player:getX(), player:getY(), player:getZ(), 30, function(sq)
                local b = sq:getBuilding()
                if b and P.buildingKey(b) == tostring(target) then building = b; return "break" end
            end)
            if not building then return list, "building " .. tostring(target) .. " not found nearby" end
        else
            building = player:getCurrentBuilding()
            if not building then
                -- ближайшее непосещённое здание
                local mem = PZBridge.mem()
                local best, bestD
                P.eachSquare(player:getX(), player:getY(), player:getZ(), 30, function(sq)
                    local b = sq:getBuilding()
                    if b then
                        local key = P.buildingKey(b)
                        if key and not mem.visitedBuildings[key] then
                            local d = U.dist(sq:getX(), sq:getY(), player:getX(), player:getY())
                            if not bestD or d < bestD then best, bestD = b, d end
                        end
                    end
                end)
                building = best
            end
            if not building then return list, "no unvisited buildings nearby" end
        end
        local _, def = P.buildingKey(building)
        local rooms = def and U.try(def, "getRooms")
        if rooms then
            for i = 0, rooms:size() - 1 do
                local rd = rooms:get(i)
                local room = U.try(rd, "getIsoRoom")
                if room then addRoom(room) end
            end
        end
        return list, nil, building
    else
        P.eachSquare(player:getX(), player:getY(), player:getZ(), U.clamp(radius or 8, 1, 20), addSquare)
        return list, nil
    end
end

-- Открыть контейнер так же, как это делает окно лута (заполнить при первом осмотре).
function L.exploreContainer(c, player)
    if not U.try(c, "isExplored") then
        if ItemPicker and ItemPicker.fillContainer then
            pcall(ItemPicker.fillContainer, c, player)
        end
        pcall(c.setExplored, c, true)
    end
end

function L.rememberContainer(cid, c)
    local mem = PZBridge.mem()
    mem.visitedContainers[cid] = true
    local items = {}
    for i, it in ipairs(P.containerItems(c)) do
        if i > 40 then break end
        local inf = P.itemInfo(it, false)
        items[#items + 1] = { id = inf.id, fullType = inf.fullType, name = inf.name, cat = inf.cat,
                              rotten = inf.rotten, poison = inf.poison, fluid = inf.fluid }
    end
    mem.knownContainers[cid] = { t = PZBridge.gameTimeStr(), type = U.try(c, "getType"), items = items }
    -- ограничить размер памяти
    local n = 0
    for _ in pairs(mem.knownContainers) do n = n + 1 end
    if n > 400 then
        for k, _ in pairs(mem.knownContainers) do
            mem.knownContainers[k] = nil
            n = n - 1
            if n <= 350 then break end
        end
    end
end

function L.startSearch(ctx, p, args)
    args = args or {}
    local scope = args.scope or "building"
    local filter = args.filter
    local stopOnFirst = args.stop_on_first ~= false and filter ~= nil
    if args.stop_on_first == false then stopOnFirst = false end
    local includeVisited = args.include_visited == true
    local g = L.mergeGuard(args)
    local useGuard = args.guard ~= false
    local list, err, building = L.collectContainers(p, scope, args.target, args.radius, args.include_corpses)
    if err then return "error", err end
    local mem = PZBridge.mem()
    local todo = {}
    for _, e in ipairs(list) do
        if includeVisited or not mem.visitedContainers[e.cid] then todo[#todo + 1] = e end
    end
    local bkey = building and P.buildingKey(building) or nil
    if #todo == 0 then
        if bkey then mem.visitedBuildings[bkey] = true end
        return "ok", "nothing to search (everything already visited)", { searched = 0, found = U.array({}), building = bkey }
    end
    local maxC = args.max_containers or 60
    local job = { name = "search", step = "searching", stepUI = T("UI_PZBridge_StepSearch"), result = { searched = 0, found = U.array({}), containers = U.array({}), building = bkey } }
    job.update = function(job, player, now)
        local threat = P.threat(player, g)
        if useGuard and threat.danger then
            if job.mover then job.mover:cancel(player) end
            local reason = threat.seeing > 0 and "a zombie sees me" or ("zombie at " .. tostring(threat.nearest_dist) .. " tiles")
            PZBridge.event("guard", { reason = reason }, reason)
            return "interrupted", "threat: " .. reason
        end
        if job.cur == nil then
            if #todo == 0 or job.result.searched >= maxC then
                if bkey and #todo == 0 then mem.visitedBuildings[bkey] = true end
                local n = #job.result.found
                return "done", (n > 0) and ("found: " .. n) or "nothing matching", job.result
            end
            -- ближайший следующий
            local bi, bd
            for i, e in ipairs(todo) do
                local d = U.dist(e.sq:getX() + 0.5, e.sq:getY() + 0.5, player:getX(), player:getY()) + math.abs(e.sq:getZ() - player:getZ()) * 8
                if not bd or d < bd then bi, bd = i, d end
            end
            job.cur = table.remove(todo, bi)
            job.mover = L.newMover(job.cur.sq:getX(), job.cur.sq:getY(), job.cur.sq:getZ(), { mode = args.mode or "auto", adjacent = true, max_repaths = 3 })
            job.phase = "walk"
        end
        local e = job.cur
        if job.phase == "walk" then
            local st, msg = job.mover:update(player, now, threat)
            local ctype = tostring(U.try(e.c, "getType"))
            job.step = "going to " .. ctype .. " (" .. e.sq:getX() .. "," .. e.sq:getY() .. ")"
            job.stepUI = T("UI_PZBridge_StepSearchGo", ctype, e.sq:getX(), e.sq:getY())
            if st == "arrived" then
                job.mover:cancel(player)
                job.phase = "look"
                job.lookUntil = now + 500
                pcall(player.faceThisObject, player, e.o)
            elseif st == "failed" then
                job.result.containers[#job.result.containers + 1] = { id = e.cid, skipped = msg }
                job.cur = nil
            end
            return nil
        end
        if job.phase == "look" then
            if now < job.lookUntil then return nil end
            L.exploreContainer(e.c, player)
            L.rememberContainer(e.cid, e.c)
            job.result.searched = job.result.searched + 1
            local matched = U.array({})
            local summary = { id = e.cid, type = U.try(e.c, "getType"), count = e.c:getItems():size() }
            -- комната контейнера (kitchen, bedroom...), если объект в комнате
            local osq = e.sq or (e.o and U.try(e.o, "getSquare"))
            local oroom = osq and U.try(osq, "getRoom")
            if oroom then summary.room = U.try(oroom, "getName") end
            for _, it in ipairs(P.containerItems(e.c)) do
                if filter == nil or P.matches(it, filter) then
                    local inf = P.itemInfo(it, true)
                    inf.where = e.cid
                    matched[#matched + 1] = inf
                end
            end
            if filter then summary.matched = #matched else summary.items = matched end
            job.result.containers[#job.result.containers + 1] = summary
            PZBridge.event("container_searched", summary)
            job.cur = nil
            if filter and #matched > 0 then
                for _, inf in ipairs(matched) do
                    job.result.found[#job.result.found + 1] = inf
                    PZBridge.event("found", { item = inf, container = e.cid }, "found: " .. tostring(inf.name))
                end
                if args.take then
                    local it = U.try(e.c, "getItemWithID", matched[1].id)
                    if it then
                        ISTimedActionQueue.add(ISInventoryTransferUtil.newInventoryTransferAction(player, it, e.c, player:getInventory()))
                        job.result.taken = matched[1]
                    end
                end
                if stopOnFirst then
                    job.phase = "finish"
                    return nil
                end
            end
            return nil
        end
        if job.phase == "finish" then
            if P.isBusy(player) then return nil end
            return "done", "found: " .. tostring(job.result.found[1] and job.result.found[1].name), job.result
        end
        return nil
    end
    job.stop = function(job, player)
        if job.mover then job.mover:cancel(player) end
    end
    PZBridge.startJob(job, ctx)
    return "running", "searching " .. #todo .. " containers"
end

---------------------------------------------------------------------------
-- fight: цикл ближнего боя.
--   until = "clear" | "kills:N" | "target:ID"
---------------------------------------------------------------------------

function L.bestWeapon(player, firearms)
    local best, bestS
    for _, it in ipairs(P.inventoryItems(player)) do
        if instanceof(it, "HandWeapon") and (firearms or not U.try(it, "isRanged")) then
            local s = P.weaponScore(it)
            if s > 0.1 and (not bestS or s > bestS) then best, bestS = it, s end
        end
    end
    return best, bestS
end

function L.weaponRange(player)
    local w = player:getPrimaryHandItem()
    local r = 0.9
    if w and instanceof(w, "HandWeapon") then
        r = U.try(w, "getMaxRange", player) or U.try(w, "getMaxRange") or 0.9
    end
    return math.max(0.8, r + 0.15)
end

-- Один удар по зомби ванильным механизмом атаки игрока.
-- IsoLivingCharacter.AttemptAttack(float) вызывает Lua-хук "Attack"
-- (ISReloadWeaponAction.attackHook), который и делает DoAttack.
function L.attack(player, z)
    pcall(player.faceThisObject, player, z)
    if U.try(player, "isAttackStarted") or U.try(player, "isPerformingAttackAnimation") then return false end
    pcall(player.setIsAiming, player, true)
    -- по лежачему зомби бить в пол (добивание)
    local onFloor = U.try(z, "isOnFloor") == true
    pcall(player.setAimAtFloor, player, onFloor)
    local w = player:getPrimaryHandItem()
    if w and instanceof(w, "HandWeapon") and U.try(w, "isRanged") then
        -- без пересчёта баллистики огнестрел падает с NPE
        pcall(player.updateBallistics, player)
    end
    local ok = pcall(player.AttemptAttack, player, 0.0)
    if not ok then
        ok = pcall(player.DoAttack, player, 0.0)
    end
    return ok
end

local function parseUntil(u)
    if u == nil or u == "clear" then return "clear", nil end
    local k, v = string.match(tostring(u), "^(%a+):(.+)$")
    if k == "kills" then return "kills", tonumber(v) or 1 end
    if k == "target" then return "target", tonumber(v) end
    return "clear", nil
end

function L.startFight(ctx, p, args)
    args = args or {}
    local radius = args.radius or 10
    local seekRadius = args.seek_radius or 35
    local untilKind, untilVal = parseUntil(args["until"])
    local firearms = args.firearms == true
    local useGuard = args.guard ~= false
    local g = L.mergeGuard(args)
    local weaponMode = args.weapon or "best"
    local startKills = p:getZombieKills()
    local job = { name = "fight", step = "fight", stepUI = T("UI_PZBridge_StepFight"), result = { kills = 0 } }
    job.lastAttackMs = 0
    job.lastReportKills = 0
    job.noTargetSince = nil

    local function kills(player) return player:getZombieKills() - startKills end

    local function pickTarget(player)
        local zs = P.zombies(player, math.max(radius, seekRadius), false)
        if untilKind == "target" then
            for _, z in ipairs(zs) do if z.id == untilVal then return z, zs end end
            return nil, zs
        end
        -- приоритет: кто идёт ко мне, затем ближайший
        local best
        for _, z in ipairs(zs) do
            if math.abs(z.z - player:getZ()) < 1 then
                if z.targeting and z.dist <= radius then return z, zs end
                if not best then best = z end
            end
        end
        return best, zs
    end

    local function activeCount(zs)
        local n = 0
        for _, z in ipairs(zs) do
            if z.dist <= 15 and (z.targeting or z.sees_player) then n = n + 1 end
        end
        return n
    end

    job.update = function(job, player, now)
        local k = kills(player)
        job.result.kills = k
        if k > job.lastReportKills then
            job.lastReportKills = k
            local msg, msgUI
            if untilKind == "kills" then
                msg = "killed " .. k .. "/" .. untilVal
                msgUI = T("UI_PZBridge_FightKillsGoal", k, untilVal)
            else
                msg = "killed " .. k
                msgUI = T("UI_PZBridge_FightKills", k)
            end
            PZBridge.event("fight_progress", { kills = k, goal = untilVal }, msg)
            PZBridge.notify(msgUI, false)
        end
        local threat = P.threat(player, g)
        -- предохранитель
        if useGuard and job.phase ~= "retreat" then
            local reason, reasonUI = L.guardReason(player, g, threat)
            local w = player:getPrimaryHandItem()
            if not reason and weaponMode ~= "none" and (w == nil or U.try(w, "isBroken")) then
                local nw = L.bestWeapon(player, firearms)
                if not nw then reason, reasonUI = "no usable weapon", T("UI_PZBridge_GuardNoWeapon") end
            end
            if reason then
                job.phase = "retreat"
                job.reason = reason
                job.reasonUI = reasonUI or reason
                PZBridge.notify(T("UI_PZBridge_FightRetreat", job.reasonUI, k), true)
                PZBridge.event("guard", { reason = reason, kills = k }, "retreating: " .. reason)
                local fx, fy = player:getX() + 1, player:getY()
                if threat.nearest then fx, fy = threat.nearest.x, threat.nearest.y end
                local sq = L.fleePoint(player, fx, fy, g.flee_distance or 15)
                if sq then
                    job.mover = L.newMover(sq:getX(), sq:getY(), sq:getZ(), { mode = "run", arrive = 1.5 })
                else
                    return "paused", "retreating: " .. reason .. " (nowhere to run)", job.result
                end
            end
        end
        if job.phase == "retreat" then
            local st = job.mover:update(player, now, nil)
            job.step = "retreating: " .. tostring(job.reason)
            job.stepUI = T("UI_PZBridge_StepRetreat", tostring(job.reasonUI))
            if st ~= "moving" then
                job.mover:cancel(player)
                job.phase = nil
                return "paused", "retreated: " .. tostring(job.reason) .. ", killed " .. k, job.result
            end
            return nil
        end
        -- оружие
        local w = player:getPrimaryHandItem()
        if weaponMode ~= "current" and weaponMode ~= "none" and not P.isBusy(player) then
            local want
            if weaponMode == "best" then
                want = L.bestWeapon(player, firearms)
            elseif tonumber(weaponMode) then
                want = P.findItemById(player, weaponMode, 0)
            end
            if want and want ~= w and (not w or P.weaponScore(w) < P.weaponScore(want) * 0.9 or U.try(w, "isBroken")) then
                local two = (U.try(want, "isTwoHandWeapon") == true) or (U.try(want, "isRequiresEquippedBothHands") == true)
                ISInventoryPaneContextMenu.equipWeapon(want, true, two, player:getPlayerNum())
                job.step = "equipping weapon: " .. tostring(want:getDisplayName())
                job.stepUI = T("UI_PZBridge_StepTakeWeapon", tostring(want:getDisplayName()))
                return nil
            end
        end
        local target, zs = pickTarget(player)
        local active = activeCount(zs)
        -- условие завершения
        local goalMet = false
        if untilKind == "kills" then goalMet = k >= untilVal
        elseif untilKind == "clear" then
            goalMet = true
            for _, z in ipairs(zs) do if z.dist <= radius then goalMet = false; break end end
        elseif untilKind == "target" then goalMet = (target == nil) end
        if goalMet and active == 0 then
            PZBridge.notify(T("UI_PZBridge_FightDone", k), true)
            return "done", "done: killed " .. k .. " zombies", job.result
        end
        if goalMet and active > 0 and not job.reportedExtra then
            job.reportedExtra = true
            local kstr = k .. (untilVal and ("/" .. untilVal) or "")
            PZBridge.notify(T("UI_PZBridge_FightExtra", kstr, active), false)
            PZBridge.event("fight_progress", { kills = k, active = active },
                "killed " .. kstr .. ", but " .. active .. " more are coming, finishing them")
        end
        if not target then
            job.noTargetSince = job.noTargetSince or now
            job.step = "looking for zombies"
            job.stepUI = T("UI_PZBridge_StepSeek")
            if now - job.noTargetSince > 20000 then
                return "failed", "no zombies nearby, killed " .. k, job.result
            end
            return nil
        end
        job.noTargetSince = nil
        local range = L.weaponRange(player)
        local z = target.obj
        -- лежачий или ползущий зомби сам не подойдёт: идти к нему вплотную и добивать
        local downed = target.on_floor or target.crawling
        if downed then range = range + 0.2 end
        job.step = "target " .. tostring(target.id) .. " at " .. tostring(target.dist) .. " tiles, killed " .. k
        job.stepUI = T("UI_PZBridge_StepTarget", tostring(target.id), target.dist, k)
        if target.dist > range then
            -- зомби сам идёт ко мне: стоять и ждать, иначе подходить
            if target.targeting and target.dist < 3.5 and not downed then
                if job.mover then job.mover:cancel(player); job.mover = nil end
                pcall(player.faceThisObject, player, z)
                return nil
            end
            local need = (job.mover == nil) or (job.moverFor ~= target.id)
                or (job.moverAt and U.dist(job.moverAt[1], job.moverAt[2], target.x, target.y) > 1.5)
                or (job.moverDowned ~= downed)
            if need then
                if job.mover then job.mover:cancel(player) end
                job.mover = L.newMover(target.x, target.y, target.z, { mode = (target.dist > 8) and "sneak" or "walk", adjacent = not downed, max_repaths = 2, open_doors = true })
                job.moverFor = target.id
                job.moverDowned = downed
                job.moverAt = { target.x, target.y }
            end
            local st = job.mover:update(player, now, nil)
            if st == "failed" then job.mover = nil end
            return nil
        end
        -- в радиусе удара
        if job.mover then job.mover:cancel(player); job.mover = nil end
        if now - job.lastAttackMs > (args.attack_interval_ms or 650) then
            if L.attack(player, z) then job.lastAttackMs = now end
        end
        return nil
    end
    job.stop = function(job, player)
        if job.mover then job.mover:cancel(player) end
    end
    PZBridge.startJob(job, ctx)
    return "running", "fight: " .. tostring(args["until"] or "clear")
end

---------------------------------------------------------------------------
-- wait: подождать реальные секунды или игровые минуты.
---------------------------------------------------------------------------

function L.startWait(ctx, p, args)
    args = args or {}
    local job = { name = "wait", step = "waiting", stepUI = T("UI_PZBridge_StepWait") }
    local g = L.mergeGuard(args)
    if args.game_minutes then
        local gt = getGameTime()
        job.endHours = gt:getWorldAgeHours() + (args.game_minutes / 60)
    else
        job.endMs = U.nowMs() + (args.seconds or 5) * 1000
    end
    job.update = function(job, player, now)
        if args.interrupt_on_threat ~= false then
            local t = P.threat(player, g)
            if t.danger then return "interrupted", "threat nearby" end
        end
        if job.endMs and now >= job.endMs then return "done", "waited" end
        if job.endHours and getGameTime():getWorldAgeHours() >= job.endHours then return "done", "waited" end
        return nil
    end
    PZBridge.startJob(job, ctx)
    return "running", "waiting"
end

---------------------------------------------------------------------------
-- Отслеживание ванильных действий, поставленных в очередь одной командой.
---------------------------------------------------------------------------

-- step - англ. текст для агента, stepUI - перевод для окна (необязательно).
function L.actionJob(ctx, name, check, step, stepUI)
    local job = { name = name, step = step or name, stepUI = stepUI }
    local pl = PZBridge.player()
    if pl and P.isBusy(pl) then job.seenBusy = true end
    job.update = function(job, player, now)
        local busy = P.isBusy(player)
        if busy then
            job.seenBusy = true
            job.idleSince = nil
            local _, _, cur = P.isBusy(player)
            local suffix = cur and (": " .. tostring(cur)) or ""
            job.step = (step or name) .. suffix
            job.stepUI = (stepUI or step or name) .. suffix
            if now - job.startedMs > 15 * 60 * 1000 then return "failed", "took too long" end
            return nil
        end
        job.idleSince = job.idleSince or now
        if now - job.idleSince < 350 then return nil end
        if check then
            local ok, st, msg, data = pcall(check, job, player)
            if ok and st then return st, msg, data end
            if not ok then return "error", tostring(st) end
        end
        if not job.seenBusy then return "failed", "action did not start (not available in game)" end
        return "done", "done"
    end
    PZBridge.startJob(job, ctx)
    return "running", step or name
end

return L
