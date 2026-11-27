-- PZBridge: ядро. Состояние моста, журнал событий, результаты команд,
-- доступ, реестр инструментов, менеджер задач (job), настройки guard, память.

require "PZBridge/PZB_Util"

PZBridge = PZBridge or {}
local U = PZBridge.U
local T = PZBridge.T

PZBridge.VERSION = "0.1.0"

-- Имена файлов в ~/Zomboid/Lua/
PZBridge.FILES = {
    state   = "pzbridge_state.json",
    cmd     = "pzbridge_cmd.txt",
    results = "pzbridge_results.json",
    events  = "pzbridge_events.json",
    inbox   = "pzbridge_inbox.txt",
}

-- Настройки по умолчанию. Меняются командой set_guard.
PZBridge.config = {
    stateIntervalMs = 1000,   -- как часто писать state
    cmdIntervalMs   = 250,    -- как часто читать файл команд
    jobIntervalMs   = 120,    -- шаг конечных автоматов
    guardIntervalMs = 200,    -- шаг глобального guard
    zombieRadius    = 20,     -- радиус зомби в state
    objectRadius    = 8,      -- радиус дверей/окон/контейнеров в state
    uiKey           = nil,    -- код клавиши окна, по умолчанию Keyboard.KEY_F9
    maxEvents       = 300,
    maxResults      = 60,
}

PZBridge.guard = {
    autopause      = true,    -- пауза, если зомби ближе pause_distance
    pause_distance = 6,
    autoflee       = false,   -- вместо паузы отбежать
    flee_distance  = 15,
    -- пороги предохранителя для fight/move_to/search (можно переопределить в вызове)
    hp_min         = 45,      -- общее здоровье 0..100
    bleeding_max   = 1,       -- сколько частей тела может кровоточить
    endurance_min  = 0.25,    -- выносливость 0..1
    crowd_max      = 4,       -- больше стольких зомби рядом - отступать
    crowd_radius   = 6,
    threat_radius  = 15,      -- радиус «есть угроза» для режима auto
    danger_radius  = 5,       -- ближе этого - бежать
}

PZBridge.S = PZBridge.S or {}
local S = PZBridge.S

function PZBridge.resetSession()
    S.memFileLoaded = false
    S.enabled = false          -- true только в одиночной игре
    S.access = false           -- включает только игрок в окне F9, не сохраняется
    S.lastCmdId = 0
    S.lastCmd = nil
    S.results = {}             -- список последних результатов
    S.resultById = {}
    S.events = {}
    S.eventSeq = 0
    S.eventsDirty = false
    S.resultsDirty = false
    S.stateDirty = true
    S.job = nil                -- активная задача
    S.pausedJob = nil          -- задача, поставленная на паузу guard'ом
    S.alert = nil
    S.lastError = nil
    S.inboxId = 0
    S.chat = {}                -- лог переписки для окна
    S.knownZombies = {}
    S.moveMode = nil           -- run/sprint для PZBWalkAction
    S.lastAutoPauseMs = 0
    S.autoPauseArmed = true
end

if S.enabled == nil then PZBridge.resetSession() end

---------------------------------------------------------------------------
-- Игрок и одиночный режим
---------------------------------------------------------------------------

function PZBridge.isSinglePlayer()
    local cl = isClient and isClient() or false
    local sv = isServer and isServer() or false
    return (not cl) and (not sv)
end

function PZBridge.player()
    local p = getSpecificPlayer(0)
    if p == nil or p:isDead() then return nil end
    return p
end

---------------------------------------------------------------------------
-- Память, сохраняемая в save через modData игрока
---------------------------------------------------------------------------

-- Знания, которые не должны теряться при загрузке сохранения без сохранения
-- (modData откатывается вместе с сохранением): запертые двери, здания, куда не
-- пройти, отмеченные места. Хранятся в отдельном файле на каждый мир.
local PERSIST_KEYS = { "lockedDoors", "blockedBuildings", "places" }

local function memFileName()
    local w = "world"
    local ok, r = pcall(function() return getWorld():getWorld() end)
    if ok and r then w = tostring(r) end
    w = string.gsub(w, "[^%w_%-]", "_")
    return "pzbridge_mem_" .. w .. ".json"
end

function PZBridge.loadMemFile(m)
    local lines = U.readLines(memFileName())
    if #lines == 0 then return end
    local ok, data = pcall(U.jsonDecode, table.concat(lines, "\n"))
    if not ok or type(data) ~= "table" then return end
    for _, k in ipairs(PERSIST_KEYS) do
        if type(data[k]) == "table" then
            m[k] = m[k] or {}
            for kk, vv in pairs(data[k]) do
                if m[k][kk] == nil then m[k][kk] = vv end
            end
        end
    end
end

function PZBridge.saveMemFile()
    local m = PZBridge.mem()
    local out = {}
    for _, k in ipairs(PERSIST_KEYS) do out[k] = m[k] or {} end
    pcall(U.writeFile, memFileName(), U.jsonEncode(out))
end

function PZBridge.mem()
    local p = getSpecificPlayer(0)
    if not p then return { places = {}, visitedBuildings = {}, visitedContainers = {}, knownContainers = {} } end
    local md = p:getModData()
    md.PZBridge = md.PZBridge or {}
    local m = md.PZBridge
    m.places = m.places or {}
    m.visitedBuildings = m.visitedBuildings or {}
    m.visitedContainers = m.visitedContainers or {}
    m.knownContainers = m.knownContainers or {}
    m.lockedDoors = m.lockedDoors or {}
    m.blockedBuildings = m.blockedBuildings or {}
    if not S.memFileLoaded then
        S.memFileLoaded = true
        PZBridge.loadMemFile(m)
    end
    return m
end

---------------------------------------------------------------------------
-- События
---------------------------------------------------------------------------

function PZBridge.gameTimeTable()
    local gt = getGameTime()
    if not gt then return nil end
    return {
        year = gt:getYear(), month = gt:getMonth() + 1, day = gt:getDay() + 1,
        hour = gt:getHour(), minute = gt:getMinutes(),
        nights = gt:getNightsSurvived(),
        world_hours = U.round(gt:getWorldAgeHours(), 3),
    }
end

function PZBridge.gameTimeStr()
    local t = PZBridge.gameTimeTable()
    if not t then return "" end
    local function p2(n)
        n = math.floor(n or 0)
        if n < 10 then return "0" .. tostring(n) end
        return tostring(n)
    end
    return p2(t.day) .. "." .. p2(t.month) .. " " .. p2(t.hour) .. ":" .. p2(t.minute)
end

-- Записать событие. type: kill, found, damage, bitten, alert, guard, job_done,
-- job_failed, job_paused, reply, player_message, access, error, info и т.п.
function PZBridge.event(etype, data, msg)
    S.eventSeq = S.eventSeq + 1
    local e = {
        seq = S.eventSeq,
        type = etype,
        rt = U.nowMs(),
        gt = PZBridge.gameTimeStr(),
        msg = msg,
        data = data,
    }
    S.events[#S.events + 1] = e
    while #S.events > PZBridge.config.maxEvents do
        table.remove(S.events, 1)
    end
    S.eventsDirty = true
    S.stateDirty = true
    return e
end

---------------------------------------------------------------------------
-- Лог окна (переписка игрока с агентом и заметки мода)
---------------------------------------------------------------------------

function PZBridge.chatAdd(who, text)
    S.chat[#S.chat + 1] = { who = who, text = tostring(text), gt = PZBridge.gameTimeStr() }
    while #S.chat > 200 do table.remove(S.chat, 1) end
    if PZBridge.UI and PZBridge.UI.onChat then
        pcall(PZBridge.UI.onChat, who, text)
    end
end

-- Сообщение от мода игроку: в окно и, по желанию, голосом персонажа.
function PZBridge.notify(text, say)
    PZBridge.chatAdd("mod", text)
    if say then
        local p = PZBridge.player()
        if p then pcall(p.Say, p, tostring(text)) end
    end
end

---------------------------------------------------------------------------
-- Результаты команд
---------------------------------------------------------------------------

local TERMINAL = { ok = true, done = true, error = true, failed = true, interrupted = true, paused = true, denied = true }
PZBridge.TERMINAL = TERMINAL

function PZBridge.setResult(id, tool, status, message, data)
    if id == nil then return end
    local r = S.resultById[id]
    if not r then
        r = { id = id, tool = tool, t_start = U.nowMs(), gt_start = PZBridge.gameTimeStr() }
        S.resultById[id] = r
        S.results[#S.results + 1] = r
        while #S.results > PZBridge.config.maxResults do
            local old = table.remove(S.results, 1)
            S.resultById[old.id] = nil
        end
    end
    r.status = status
    r.message = message
    if data ~= nil then r.data = data end
    r.final = TERMINAL[status] == true
    if r.final then r.t_end = U.nowMs() end
    S.lastCmd = { id = id, tool = tool, status = status, message = message }
    if status == "error" or status == "failed" then
        S.lastError = { id = id, tool = tool, message = message }
    end
    S.resultsDirty = true
    S.stateDirty = true
end

---------------------------------------------------------------------------
-- Реестр инструментов
--   PZBridge.tool(name, { params = {"x","y","z"}, kind = "query"|"action"|"control",
--                          always = true (работает без доступа), fn = function(p, ctx) end })
--   fn возвращает status, message, data. status: ok | error | running.
--   Для running fn сама вызывает PZBridge.startJob(job, ctx).
---------------------------------------------------------------------------

PZBridge.tools = PZBridge.tools or {}

function PZBridge.tool(name, def)
    def.name = name
    def.params = def.params or {}
    def.kind = def.kind or "action"
    PZBridge.tools[name] = def
end

---------------------------------------------------------------------------
-- Менеджер задач. Одна активная задача (job) за раз.
-- job = { name = "move_to", update = function(job, player, now) -> nil | status, msg, data,
--         stop = function(job, player) (необязательно),
--         step = "english text" (для агента, попадает в state.json),
--         stepUI = T("UI_PZBridge_...") (для окна F9; если нет, окно показывает step) }
---------------------------------------------------------------------------

function PZBridge.stopJob(reason, status)
    local job = S.job
    if not job then return end
    S.job = nil
    local p = PZBridge.player()
    if job.stop then pcall(job.stop, job, p) end
    PZBridge.setResult(job.cmdId, job.name, status or "interrupted", reason or "stopped", job.result)
end

function PZBridge.startJob(job, ctx)
    if S.job then PZBridge.stopJob("replaced by " .. tostring(job.name), "interrupted") end
    job.cmdId = ctx and ctx.id or job.cmdId
    job.startedMs = U.nowMs()
    job.step = job.step or "start"
    S.job = job
    S.stateDirty = true
    return job
end

-- Завершить активную задачу с итогом.
function PZBridge.finishJob(job, status, msg, data)
    if S.job ~= job then return end
    S.job = nil
    local p = PZBridge.player()
    if job.stop then pcall(job.stop, job, p) end
    if data ~= nil then job.result = data end
    PZBridge.setResult(job.cmdId, job.name, status, msg, job.result)
    local et = "job_done"
    if status == "failed" or status == "error" then et = "job_failed"
    elseif status == "paused" then et = "job_paused"
    elseif status == "interrupted" then et = "job_interrupted" end
    PZBridge.event(et, { job = job.name, cmd_id = job.cmdId, result = job.result }, msg)
    if status == "paused" then
        S.pausedJob = job
    end
end

function PZBridge.tickJob(now)
    local job = S.job
    if not job then return end
    local p = PZBridge.player()
    if not p then return end
    local ok, st, msg, data = pcall(job.update, job, p, now)
    if not ok then
        U.log("job error " .. tostring(job.name) .. ": " .. tostring(st))
        PZBridge.event("error", { job = job.name }, tostring(st))
        PZBridge.finishJob(job, "error", tostring(st))
        return
    end
    if st then PZBridge.finishJob(job, st, msg, data) end
end

---------------------------------------------------------------------------
-- Доступ
---------------------------------------------------------------------------

function PZBridge.setAccess(on)
    on = on and true or false
    if S.access == on then return end
    S.access = on
    if not on then
        PZBridge.stopAll("access disabled")
    end
    PZBridge.event("access", { access = on }, on and "control allowed by player" or "control denied by player")
    PZBridge.chatAdd("mod", on and T("UI_PZBridge_AccessOn") or T("UI_PZBridge_AccessOff"))
    S.stateDirty = true
end

-- Полная остановка: задача, очередь действий, режим бега.
function PZBridge.stopAll(reason)
    PZBridge.stopJob(reason or "stop", "interrupted")
    S.pausedJob = nil
    S.moveMode = nil
    local p = PZBridge.player()
    if p then
        pcall(ISTimedActionQueue.clear, p)
        pcall(function() p:getPathFindBehavior2():cancel() end)
        pcall(function() p:setPath2(nil) end)
        pcall(function() p:setRunning(false) end)
        pcall(function() p:setSprinting(false) end)
    end
end

return PZBridge
