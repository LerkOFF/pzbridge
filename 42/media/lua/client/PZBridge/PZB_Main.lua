-- PZBridge: главный цикл. Чтение команд, запись state/results/events,
-- глобальный guard (автопауза), игровые события, запуск в одиночной игре.

require "PZBridge/PZB_Tools"

local U = PZBridge.U
local S = PZBridge.S
local P = PZBridge.P
local L = PZBridge.L
local F = PZBridge.FILES

---------------------------------------------------------------------------
-- Разбор строки команды: "<id> <tool> {json}" или "<id> <tool> a b key=value"
---------------------------------------------------------------------------

local TEXT_TOOLS = { say = true, reply = true }

local function convert(v)
    if v == "true" then return true end
    if v == "false" then return false end
    local n = tonumber(v)
    if n ~= nil then return n end
    return v
end

function PZBridge.parseLine(line)
    line = U.trim(line or "")
    if line == "" or line:sub(1, 1) == "#" then return nil end
    local id, tool, rest = string.match(line, "^(%d+)%s+([%w_]+)%s*(.*)$")
    if not id then return nil, "bad line: " .. line end
    id = tonumber(id)
    local args = {}
    rest = rest or ""
    if rest:sub(1, 1) == "{" then
        local obj, err = U.jsonDecode(rest)
        if type(obj) ~= "table" then return id, tool, nil, "bad json: " .. tostring(err) end
        args = obj
    elseif TEXT_TOOLS[tool] then
        args.text = rest
    elseif rest ~= "" then
        local def = PZBridge.tools[tool]
        local names = def and def.params or {}
        local i = 0
        for tok in string.gmatch(rest, "%S+") do
            local k, v = string.match(tok, "^([%w_]+)=(.*)$")
            if k then
                args[k] = convert(v)
            else
                i = i + 1
                local name = names[i] or ("arg" .. i)
                args[name] = convert(tok)
            end
        end
    end
    return id, tool, args
end

---------------------------------------------------------------------------
-- Выполнение команды
---------------------------------------------------------------------------

function PZBridge.execute(id, toolName, args)
    local def = PZBridge.tools[toolName]
    if not def then
        PZBridge.setResult(id, toolName, "error", "unknown tool: " .. tostring(toolName))
        return
    end
    if not S.access and not def.always then
        PZBridge.setResult(id, toolName, "denied", "access=false: игрок не разрешил управление (окно F9)")
        return
    end
    local p = PZBridge.player()
    if not p then
        PZBridge.setResult(id, toolName, "error", "нет живого игрока")
        return
    end
    if def.kind == "action" then
        -- новое действие заменяет текущую задачу и очередь
        PZBridge.stopJob("replaced by " .. toolName, "interrupted")
        S.pausedJob = nil
        pcall(ISTimedActionQueue.clear, p)
    end
    local ctx = { id = id, tool = toolName }
    PZBridge.setResult(id, toolName, "running", "started")
    local ok, st, msg, data = pcall(def.fn, args or {}, ctx, p)
    if not ok then
        U.log("tool " .. toolName .. " error: " .. tostring(st))
        PZBridge.setResult(id, toolName, "error", tostring(st))
        PZBridge.event("error", { tool = toolName, cmd_id = id }, tostring(st))
        return
    end
    if st == "running" then
        local r = S.resultById[id]
        if r and not r.final then PZBridge.setResult(id, toolName, "running", msg, data) end
    else
        PZBridge.setResult(id, toolName, st or "ok", msg, data)
    end
end

-- Прочитать файл команд и выполнить новые (id больше последнего).
function PZBridge.pollCommands(skipOnly)
    local lines = U.readLines(F.cmd)
    local maxId = S.lastCmdId
    for _, line in ipairs(lines) do
        local id, tool, args, err = PZBridge.parseLine(line)
        if id and id > S.lastCmdId then
            if id > maxId then maxId = id end
            if not skipOnly then
                S.lastCmdId = id
                if err then
                    PZBridge.setResult(id, tool, "error", err)
                else
                    local ok, e = pcall(PZBridge.execute, id, tool, args)
                    if not ok then PZBridge.setResult(id, tool, "error", tostring(e)) end
                end
            end
        end
    end
    if skipOnly then S.lastCmdId = maxId end
end

---------------------------------------------------------------------------
-- Снимок состояния
---------------------------------------------------------------------------

local nearbyCache = { ms = 0, data = nil }

function PZBridge.buildState(p, full)
    local st = {
        version = PZBridge.VERSION,
        session = S.session,
        t_ms = U.nowMs(),
        enabled = S.enabled,
        access = S.access,
        paused = isGamePaused(),
        game_speed = getGameSpeed(),
        time = PZBridge.gameTimeTable(),
        last_cmd_id = S.lastCmdId,
        last_cmd = S.lastCmd,
        last_error = S.lastError,
        alert = S.alert,
        events_seq = S.eventSeq,
        inbox_last_id = S.inboxId,
        guard = PZBridge.guard,
    }
    if not p then
        st.player = nil
        st.dead = true
        return st
    end
    local sq = p:getCurrentSquare()
    local building = p:getCurrentBuilding()
    local room = sq and sq:getRoom()
    st.player = {
        name = U.try(p, "getFullName") or U.try(p, "getUsername"),
        x = U.round(p:getX(), 2), y = U.round(p:getY(), 2), z = math.floor(p:getZ()),
        indoors = sq and not sq:isOutside() or false,
        building = building and P.buildingKey(building) or nil,
        room = room and U.try(room, "getName") or nil,
        sneaking = U.try(p, "isSneaking") == true,
        running = U.try(p, "isRunning") == true,
        asleep = p:isAsleep(),
        in_vehicle = p:getVehicle() ~= nil,
        kills = p:getZombieKills(),
    }
    st.body = P.body(p)
    st.stats = P.stats(p)
    st.moodles = P.moodles(p)
    local ph, sh = p:getPrimaryHandItem(), p:getSecondaryHandItem()
    st.hands = { primary = ph and P.itemInfo(ph, false) or nil, secondary = (sh and sh ~= ph) and P.itemInfo(sh, false) or nil,
                 two_handed = (ph ~= nil and ph == sh) }
    st.weight = { current = U.round(p:getInventoryWeight(), 2), max = p:getMaxWeight() }
    local inv = U.array({})
    local items = P.inventoryItems(p)
    for i, it in ipairs(items) do
        if i > (full and 200 or 80) then break end
        inv[#inv + 1] = P.itemInfo(it, full)
    end
    st.inventory = inv
    st.inventory_count = #items
    local threat = P.threat(p, PZBridge.guard)
    local zl = P.strip(threat.list)
    while #zl > 30 do table.remove(zl) end
    st.zombies = zl
    st.threat = { level = threat.level, nearest_dist = threat.nearest_dist, count = threat.count,
                  seeing = threat.seeing, targeting = threat.targeting, crowd = threat.crowd }
    local now = U.nowMs()
    if full or now - nearbyCache.ms > 2000 or not nearbyCache.data then
        nearbyCache.data = P.scanArea(p, { radius = PZBridge.config.objectRadius,
            only = { doors = true, windows = true, containers = true, water = true, items = true }, withItems = true })
        nearbyCache.ms = now
    end
    st.nearby = nearbyCache.data
    local busy, queued, cur = P.isBusy(p)
    st.busy = busy
    st.queue = { length = queued, current = cur }
    if S.job then
        st.job = { name = S.job.name, cmd_id = S.job.cmdId, step = S.job.step, running_s = math.floor((now - (S.job.startedMs or now)) / 1000) }
    end
    if S.pausedJob then
        st.paused_job = { name = S.pausedJob.name, cmd_id = S.pausedJob.cmdId, step = S.pausedJob.step }
    end
    return st
end

---------------------------------------------------------------------------
-- Запись файлов
---------------------------------------------------------------------------

local lastWrite = { state = 0, results = 0, events = 0 }

function PZBridge.flush(now, force)
    if (force or S.resultsDirty) and (force or now - lastWrite.results > 200) then
        S.resultsDirty = false
        lastWrite.results = now
        U.writeFile(F.results, U.jsonEncode({ session = S.session, last_cmd_id = S.lastCmdId, results = U.array(S.results) }))
    end
    if (force or S.eventsDirty) and (force or now - lastWrite.events > 250) then
        S.eventsDirty = false
        lastWrite.events = now
        U.writeFile(F.events, U.jsonEncode({ session = S.session, seq = S.eventSeq, events = U.array(S.events) }))
    end
    local interval = PZBridge.config.stateIntervalMs
    if force or now - lastWrite.state > interval or (S.stateDirty and now - lastWrite.state > 300) then
        S.stateDirty = false
        lastWrite.state = now
        local ok, st = pcall(PZBridge.buildState, PZBridge.player(), false)
        if not ok then
            U.log("state error: " .. tostring(st))
            st = { version = PZBridge.VERSION, session = S.session, error = tostring(st), access = S.access, last_cmd_id = S.lastCmdId }
        end
        U.writeFile(F.state, U.jsonEncode(st))
    end
end

---------------------------------------------------------------------------
-- Глобальный guard: автопауза или автоотступление.
-- Работает только когда игрок разрешил управление (иначе играет человек).
---------------------------------------------------------------------------

function PZBridge.guardTick(p, now)
    if not S.access then return end
    local g = PZBridge.guard
    if S.job and (S.job.name == "fight" or S.job.name == "flee") then return end
    local t = P.threat(p, g)
    local d = t.nearest_dist
    if not d or d > g.pause_distance then
        if not d or d > g.pause_distance + 2 then
            S.autoPauseArmed = true
            if S.alert and S.alert.type == "zombie_close" then S.alert = nil; S.stateDirty = true end
        end
        return
    end
    if not S.autoPauseArmed then
        -- повторно: только если зомби вплотную и с прошлой паузы прошло 8 секунд
        if d > 2.0 or now - S.lastAutoPauseMs < 8000 then return end
    end
    if not g.autopause and not g.autoflee then return end
    S.autoPauseArmed = false
    S.lastAutoPauseMs = now
    S.alert = { type = "zombie_close", dist = d, count = t.count, seeing = t.seeing,
                zombie = P.strip({ t.nearest })[1], gt = PZBridge.gameTimeStr() }
    if g.autoflee then
        PZBridge.event("alert", S.alert, "зомби в " .. d .. " клетках, отступаю")
        L.startFlee({ id = nil, tool = "flee" }, p, { distance = g.flee_distance, mode = "run" })
    else
        PZBridge.stopJob("autopause", "interrupted")
        PZBridge.setPause(true)
        PZBridge.event("alert", S.alert, "зомби в " .. d .. " клетках, пауза")
        PZBridge.notify("Пауза: зомби в " .. d .. " клетках", false)
    end
    S.stateDirty = true
end

---------------------------------------------------------------------------
-- Сообщения игрока агенту (окно F9 -> pzbridge_inbox.txt)
---------------------------------------------------------------------------

function PZBridge.sendPlayerMessage(text)
    text = U.trim(text or "")
    if text == "" then return end
    S.inboxId = S.inboxId + 1
    local rec = { id = S.inboxId, session = S.session, rt = U.nowMs(), gt = PZBridge.gameTimeStr(), text = text, access = S.access }
    U.appendLine(F.inbox, U.jsonEncode(rec))
    PZBridge.chatAdd("player", text)
    PZBridge.event("player_message", { id = S.inboxId, text = text }, text)
    S.stateDirty = true
end

local function initInbox()
    local maxId = 0
    for _, line in ipairs(U.readLines(F.inbox)) do
        local rec = U.jsonDecode(line)
        if type(rec) == "table" and tonumber(rec.id) and rec.id > maxId then maxId = rec.id end
    end
    S.inboxId = maxId
end

---------------------------------------------------------------------------
-- Игровые события
---------------------------------------------------------------------------

local lastDamageMs = 0
local lastBitten = 0

local function onZombieDead(z)
    if not S.enabled then return end
    local p = PZBridge.player()
    if not p then return end
    local by = U.try(z, "getAttackedBy")
    if by == p then
        PZBridge.event("kill", { zombie = P.zombieId(z), x = U.round(z:getX(), 1), y = U.round(z:getY(), 1), kills = p:getZombieKills() })
    end
end

local function onPlayerGetDamage(character, damageType, damage)
    if not S.enabled then return end
    local p = PZBridge.player()
    if not p or character ~= p then return end
    local now = U.nowMs()
    if now - lastDamageMs < 1500 then return end
    lastDamageMs = now
    PZBridge.event("damage", { type = tostring(damageType), amount = U.round(damage or 0, 2),
                               health = U.round(p:getBodyDamage():getOverallBodyHealth(), 1) })
end

local function checkBites(p)
    local n = p:getBodyDamage():getNumPartsBitten()
    if n > lastBitten then
        PZBridge.event("bitten", { parts = n }, "укус")
        PZBridge.notify("Меня укусили!", false)
    end
    lastBitten = n
end

---------------------------------------------------------------------------
-- Тики
---------------------------------------------------------------------------

local lastPoll, lastJob, lastGuard, lastBite = 0, 0, 0, 0

-- Работает и на паузе: команды, файлы, окно.
local function onTickAlways()
    if not S.enabled then return end
    local now = U.nowMs()
    if now - lastPoll >= PZBridge.config.cmdIntervalMs then
        lastPoll = now
        local ok, err = pcall(PZBridge.pollCommands, false)
        if not ok then U.log("poll error: " .. tostring(err)) end
    end
    local ok, err = pcall(PZBridge.flush, now, false)
    if not ok then U.log("flush error: " .. tostring(err)) end
    if PZBridge.UI and PZBridge.UI.tick then pcall(PZBridge.UI.tick) end
end

-- Только когда игра идёт: циклы задач и guard.
local function onTickGame()
    if not S.enabled then return end
    if isGamePaused() then return end
    local p = PZBridge.player()
    if not p then return end
    local now = U.nowMs()
    if now - lastJob >= PZBridge.config.jobIntervalMs then
        lastJob = now
        if S.job and not S.access then PZBridge.stopAll("access off") end
        PZBridge.tickJob(now)
    end
    if now - lastGuard >= PZBridge.config.guardIntervalMs then
        lastGuard = now
        local ok, err = pcall(PZBridge.guardTick, p, now)
        if not ok then U.log("guard error: " .. tostring(err)) end
    end
    if now - lastBite >= 1000 then
        lastBite = now
        pcall(checkBites, p)
    end
end

local function onGameStart()
    PZBridge.resetSession()
    if not PZBridge.isSinglePlayer() then
        U.log("мультиплеер: мост выключен")
        return
    end
    S.enabled = true
    S.session = U.nowMs()
    -- старые команды из прошлых запусков не выполняем
    pcall(PZBridge.pollCommands, true)
    initInbox()
    local p = PZBridge.player()
    if p then lastBitten = p:getBodyDamage():getNumPartsBitten() end
    PZBridge.event("session_start", { version = PZBridge.VERSION, last_cmd_id = S.lastCmdId }, "PZBridge запущен")
    PZBridge.chatAdd("mod", "PZBridge " .. PZBridge.VERSION .. ": управление выключено. Включите в этом окне, если хотите дать доступ агенту.")
    PZBridge.flush(U.nowMs(), true)
    U.log("started, last cmd id " .. tostring(S.lastCmdId))
end

Events.OnGameStart.Add(onGameStart)
-- onTickAlways повешен и на OnTick, и на OnTickEvenPaused: троттлинг по времени
-- не даёт выполнить работу дважды, а мост работает при любой трактовке события.
Events.OnTick.Add(onTickAlways)
if Events.OnTickEvenPaused then
    Events.OnTickEvenPaused.Add(onTickAlways)
end
Events.OnTick.Add(onTickGame)
Events.OnZombieDead.Add(onZombieDead)
if Events.OnPlayerGetDamage then Events.OnPlayerGetDamage.Add(onPlayerGetDamage) end
