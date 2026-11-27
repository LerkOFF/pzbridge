-- PZBridge: машины. Осмотр, посадка, двигатель, багажник и простой автопилот.
--
-- Игра читает руль, газ и тормоз только с клавиатуры или геймпада, из Lua их не
-- подменить. Поэтому автопилот управляет иначе:
--   * скорость: штатный круиз-контроль (setRegulator / setRegulatorSpeed);
--   * поворот: боковой толчок в нос машины (addImpulse), шины гасят боковое
--     движение, и машина поворачивает. Сила растёт с массой и скоростью;
--   * тормоз: setForceBrake.
-- Подход описан в открытом моде Minidoracat AutoDrive (MIT); здесь своя упрощённая
-- реализация для медленной езды (до ~30 км/ч) по открытой местности.

require "PZBridge/PZB_Tools"

local U = PZBridge.U
local S = PZBridge.S
local P = PZBridge.P
local L = PZBridge.L
local Tool = PZBridge.tool
local T = PZBridge.T

local V = {}
PZBridge.V = V

local function num(v) return tonumber(v) end

---------------------------------------------------------------------------
-- Поиск и описание машин
---------------------------------------------------------------------------

local function cellVehicles()
    local out = {}
    local vs = getCell() and getCell():getVehicles()
    if not vs then return out end
    if vs.size and vs.get then
        for i = 0, vs:size() - 1 do out[#out + 1] = vs:get(i) end
    elseif vs.iterator then
        local it = vs:iterator()
        while it:hasNext() do out[#out + 1] = it:next() end
    end
    return out
end

function V.byId(id)
    id = tonumber(id)
    for _, v in ipairs(cellVehicles()) do
        if U.try(v, "getSqlId") == id or U.try(v, "getId") == id then return v end
    end
    return nil
end

function V.nearest(p, radius)
    local best, bd
    for _, v in ipairs(cellVehicles()) do
        local d = U.dist(v:getX(), v:getY(), p:getX(), p:getY())
        if d <= (radius or 30) and (not bd or d < bd) then best, bd = v, d end
    end
    return best, bd
end

local function partInfo(v, id)
    local part = U.try(v, "getPartById", id)
    if not part then return nil end
    return part
end

function V.info(v, p)
    local key = nil
    if p then
        for _, it in ipairs(P.inventoryItems(p)) do
            if U.try(it, "getKeyId") ~= nil and U.try(it, "getKeyId") == U.try(v, "getKeyId") then key = it; break end
        end
    end
    local gas = partInfo(v, "GasTank")
    local bat = partInfo(v, "Battery")
    local eng = partInfo(v, "Engine")
    local trunk = partInfo(v, "TruckBed") or partInfo(v, "TrunkDoor")
    local batItem = bat and U.try(bat, "getInventoryItem")
    local info = {
        id = U.try(v, "getSqlId"),
        name = tostring(U.try(v, "getScriptName") or "?"),
        x = U.round(v:getX(), 1), y = U.round(v:getY(), 1), z = math.floor(v:getZ()),
        dist = p and U.round(U.dist(v:getX(), v:getY(), p:getX(), p:getY()), 1) or nil,
        fuel_pct = U.round((U.try(v, "getRemainingFuelPercentage") or 0), 0),
        battery = batItem and U.round((U.try(batItem, "getCurrentUsesFloat") or U.try(batItem, "getUsedDelta") or 0) * 100, 0) or 0,
        battery_live = U.try(v, "hasLiveBattery") == true,
        engine_condition = eng and U.try(eng, "getCondition") or nil,
        engine_running = U.try(v, "isEngineRunning") == true,
        speed_kmh = U.round(U.try(v, "getCurrentSpeedKmHour") or 0, 1),
        have_key = key ~= nil,
        key_in_ignition = U.try(v, "isKeysInIgnition") == true,
        hotwired = U.try(v, "isHotwired") == true,
        trunk = trunk and V.trunkId(v) or nil,
        driver = p and U.try(v, "isDriver", p) == true or false,
    }
    if gas then
        info.fuel_l = U.round(U.try(gas, "getContainerContentAmount") or 0, 1)
        info.fuel_cap = U.try(gas, "getContainerCapacity")
    end
    -- все контейнеры машины (сиденья, бардачок, кузов): лут бывает и на сиденьях
    local conts = U.array({})
    local n = U.try(v, "getPartCount") or 0
    for i = 0, n - 1 do
        local part = v:getPartByIndex(i)
        local c = part and U.try(part, "getItemContainer")
        if c and not string.find(tostring(U.try(part, "getId") or ""), "GasTank", 1, true) then
            local cnt = c:getItems():size()
            conts[#conts + 1] = { id = "vehicle," .. tostring(v:getSqlId()) .. "," .. tostring(part:getId()),
                part = tostring(part:getId()), items = cnt }
        end
    end
    info.containers = conts
    return info
end

-- Id багажника для take/transfer: vehicle,<sqlId>,<partId>
function V.trunkId(v)
    for _, pid in ipairs({ "TruckBed", "TruckBedOpen", "TrunkDoor" }) do
        local part = U.try(v, "getPartById", pid)
        if part and U.try(part, "getItemContainer") then return "vehicle," .. tostring(v:getSqlId()) .. "," .. pid end
    end
    return nil
end

-- Расширяем P.resolveContainer: контейнеры машины.
local baseResolve = P.resolveContainer
function P.resolveContainer(cid)
    local vid, pid = string.match(tostring(cid), "^vehicle,(%-?%d+),([%w_]+)$")
    if vid then
        local v = V.byId(vid)
        local part = v and U.try(v, "getPartById", pid)
        local c = part and U.try(part, "getItemContainer")
        if c then return c, v, v:getSquare() end
        return nil
    end
    return baseResolve(cid)
end

---------------------------------------------------------------------------
-- Инструменты: осмотр, посадка, двигатель, выход
---------------------------------------------------------------------------

Tool("vehicles", { kind = "control", params = { "radius" }, fn = function(a, ctx, p)
    local r = num(a.radius) or 40
    local list = U.array({})
    for _, v in ipairs(cellVehicles()) do
        local d = U.dist(v:getX(), v:getY(), p:getX(), p:getY())
        if d <= r then list[#list + 1] = V.info(v, p) end
    end
    table.sort(list, function(x, y) return (x.dist or 0) < (y.dist or 0) end)
    ctx.data = { vehicles = list }
    return "ok", #list .. " vehicles within " .. r, ctx.data
end })

local function pickVehicle(a, p)
    if a.vehicle_id or a.id then
        local v = V.byId(a.vehicle_id or a.id)
        if not v then return nil, "vehicle not found (id " .. tostring(a.vehicle_id or a.id) .. ")" end
        return v
    end
    local cur = p:getVehicle()
    if cur then return cur end
    local v = V.nearest(p, num(a.radius) or 20)
    if not v then return nil, "no vehicle nearby" end
    return v
end

Tool("enter_vehicle", { params = { "vehicle_id" }, fn = function(a, ctx, p)
    if p:getVehicle() then return "ok", "already in a vehicle" end
    local v, err = pickVehicle(a, p)
    if not v then return "error", err end
    local seat = num(a.seat) or 0
    ISVehicleMenu.onEnter(p, v, seat)
    return L.actionJob(ctx, "enter_vehicle", function(job, pl)
        if pl:getVehicle() == v then return "done", "in the vehicle, seat " .. seat, V.info(v, pl) end
        return "failed", "could not get in (locked doors? blocked?)"
    end, "getting into the vehicle", T("UI_PZBridge_StepVehicle"))
end })

Tool("exit_vehicle", { params = {}, fn = function(a, ctx, p)
    local v = p:getVehicle()
    if not v then return "ok", "not in a vehicle" end
    V.stopDrive("exit")
    ISVehicleMenu.onExit(p)
    return L.actionJob(ctx, "exit_vehicle", function(job, pl)
        if not pl:getVehicle() then return "done", "out of the vehicle" end
        return "failed", "could not get out"
    end, "getting out", T("UI_PZBridge_StepVehicle"))
end })

Tool("start_engine", { params = {}, fn = function(a, ctx, p)
    local v = p:getVehicle()
    if not v or not v:isDriver(p) then return "error", "not in the driver seat (enter_vehicle first)" end
    if v:isEngineRunning() then return "ok", "engine already running" end
    -- двигатель заводится не всегда с первого раза (зависит от состояния): ждём, пока стартер
    -- докрутит, и пробуем снова до tries раз
    local maxTries = num(a.tries) or 5
    ISVehicleMenu.onStartEngine(p)
    return L.actionJob(ctx, "start_engine", function(job, pl)
        if v:isEngineRunning() then return "done", "engine running after " .. (job.tries or 1) .. " tries", V.info(v, pl) end
        local now = U.nowMs()
        job.t0 = job.t0 or now
        local st = tostring(U.try(v, "getEngineState") or "")
        local cranking = string.find(st, "Start", 1, true) ~= nil
        if (cranking and now - job.t0 < 6000) or now - job.t0 < 2500 then return "continue" end
        job.tries = (job.tries or 1) + 1
        if job.tries <= maxTries and pl:getVehicle() == v then
            job.t0 = nil
            ISVehicleMenu.onStartEngine(pl)
            return "continue"
        end
        return "failed", "engine did not start after " .. maxTries .. " tries (no key, dead battery, no fuel or a bad engine)", V.info(v, pl)
    end, "starting the engine", T("UI_PZBridge_StepVehicle"))
end })

Tool("stop_engine", { params = {}, fn = function(a, ctx, p)
    local v = p:getVehicle()
    if not v or not v:isDriver(p) then return "error", "not in the driver seat" end
    V.stopDrive("stop_engine")
    if not v:isEngineRunning() then return "ok", "engine already off" end
    ISVehicleMenu.onShutOff(p)
    return L.actionJob(ctx, "stop_engine", nil, "stopping the engine", T("UI_PZBridge_StepVehicle"))
end })

---------------------------------------------------------------------------
-- Автопилот
---------------------------------------------------------------------------

local MULT_NORM = 0.8      -- getMultiplier при 60 к/с
local STRENGTH = 1.8       -- сила поворота
local MASS_K = 0.00015     -- добавка силы на (км/ч)^2 и кг
local MASS_BASE = 0.7      -- сила на кг на месте
local IMPULSE_SCALE = 10
local ARM = 2.0            -- точка приложения: нос машины, м
local KP = 3.0             -- поворот на радиан ошибки курса
local STEER_MAX = 2.5

local drive = nil          -- текущая поездка (одна)

function V.stopDrive(reason)
    if not drive then return end
    local v = drive.v
    pcall(v.setRegulator, v, false)
    pcall(v.setForceBrake, v)
    drive.stopped = reason or "stopped"
    drive = nil
end

local function forward(v)
    local out = BaseVehicle.allocVector3f()
    v:getForwardVector(out)
    local fx, fy = out:x(), out:z()
    BaseVehicle.releaseVector3f(out)
    local l = math.sqrt(fx * fx + fy * fy)
    if l < 1e-6 then return 0, 0 end
    return fx / l, fy / l
end

-- Каждый кадр: один толчок в нос по ошибке курса.
local function steerFrame()
    local d = drive
    if not d then return end
    local v = d.v
    if not v or isGamePaused() then return end
    local tx, ty = d.tx, d.ty
    local vx, vy = v:getX(), v:getY()
    local dx, dy = tx - vx, ty - vy
    local dist = math.sqrt(dx * dx + dy * dy)
    if dist < 0.5 then return end
    local fx, fy = forward(v)
    if fx == 0 and fy == 0 then return end
    local ux, uy = dx / dist, dy / dist
    local cross = fx * uy - fy * ux
    local dot = fx * ux + fy * uy
    local err = math.atan2(cross, dot)
    d.err = err
    local steer = KP * err
    if steer > STEER_MAX then steer = STEER_MAX elseif steer < -STEER_MAX then steer = -STEER_MAX end
    if math.abs(steer) < 0.02 then return end
    local kmh = math.abs(v:getCurrentSpeedKmHour() or 0)
    if kmh > 60 then kmh = 60 end
    local mass = U.try(v, "getMass") or 1200
    local mult = getGameTime():getMultiplier()
    if mult < 0.1 then mult = 0.1 elseif mult > 3 then mult = 3 end
    local F = math.abs(steer) * STRENGTH * (MASS_K * mass * kmh * kmh + MASS_BASE * mass) * IMPULSE_SCALE * (mult / MULT_NORM)
    local sgn = (steer > 0 and 1 or -1) * d.sign
    -- p: вектор курса, повёрнутый на 90 градусов
    local px, py = -fy, fx
    d.parity = -(d.parity or 1)
    local imp = BaseVehicle.allocVector3f()
    local rel = BaseVehicle.allocVector3f()
    imp:set(sgn * F * px, 0, sgn * F * py)
    rel:set(ARM * fx + d.parity * 0.5 * px, 0, ARM * fy + d.parity * 0.5 * py)
    v:addImpulse(imp, rel)
    BaseVehicle.releaseVector3f(imp)
    BaseVehicle.releaseVector3f(rel)
end
Events.OnTick.Add(function() pcall(steerFrame) end)

-- Зомби впереди по курсу в пределах dist.
local function zombiesAhead(v, distMax)
    local fx, fy = forward(v)
    local n, nearest = 0, nil
    for _, z in ipairs(P.zombies(getPlayer(), distMax + 5, false)) do
        local dx, dy = z.x - v:getX(), z.y - v:getY()
        local along = dx * fx + dy * fy
        local side = math.abs(dx * -fy + dy * fx)
        if along > 0 and along < distMax and side < 2.5 then
            n = n + 1
            if not nearest or along < nearest then nearest = along end
        end
    end
    return n, nearest
end

-- drive_to: ехать к точке (или по списку точек path=[[x,y],...]) на скорости до max_kmh.
Tool("drive_to", { params = { "x", "y" }, fn = function(a, ctx, p)
    local v = p:getVehicle()
    if not v or not v:isDriver(p) then return "error", "not in the driver seat (enter_vehicle, start_engine first)" end
    if not v:isEngineRunning() then return "error", "engine is off (start_engine)" end
    local pts = {}
    if type(a.path) == "table" then
        for _, pt in ipairs(a.path) do
            if type(pt) == "table" and num(pt[1]) and num(pt[2]) then pts[#pts + 1] = { num(pt[1]), num(pt[2]) } end
        end
    end
    if num(a.x) and num(a.y) then pts[#pts + 1] = { num(a.x), num(a.y) } end
    if #pts == 0 then return "error", "x,y or path required" end
    local maxKmh = math.min(num(a.max_kmh) or 25, 60)
    local arrive = num(a.arrive) or 5
    V.stopDrive("replaced")
    drive = { v = v, pts = pts, i = 1, tx = pts[1][1], ty = pts[1][2], sign = 1, parity = 1,
              calib = { t = U.nowMs(), err = nil, flips = 0 }, slowSince = nil }
    pcall(v.setRegulator, v, true)
    pcall(v.setRegulatorSpeed, v, math.min(10, maxKmh))
    local job = { name = "drive_to", step = "driving", stepUI = T("UI_PZBridge_StepDrive") }
    job.update = function(job, player, now)
        local d = drive
        if not d then return "interrupted", "drive stopped" end
        if player:getVehicle() ~= v then V.stopDrive("left vehicle"); return "failed", "not in the vehicle any more" end
        if not v:isEngineRunning() then V.stopDrive("engine off"); return "failed", "engine stopped (out of fuel?)" end
        local dist = U.dist(v:getX(), v:getY(), d.tx, d.ty)
        local last = d.i >= #d.pts
        if dist <= (last and arrive or math.max(arrive, 6)) then
            if last then
                V.stopDrive("arrived")
                return "done", "arrived at " .. math.floor(d.tx) .. "," .. math.floor(d.ty), V.info(v, player)
            end
            d.i = d.i + 1
            d.tx, d.ty = d.pts[d.i][1], d.pts[d.i][2]
        end
        -- автонастройка знака толчка: если ошибка курса растёт при повороте, знак наоборот
        local err = math.abs(d.err or 0)
        local kmh = math.abs(v:getCurrentSpeedKmHour() or 0)
        if now - d.calib.t > 700 then
            if d.calib.err and err > 0.35 and kmh > 3 and err > d.calib.err + 0.12 and d.calib.flips < 3 then
                d.sign = -d.sign
                d.calib.flips = d.calib.flips + 1
                PZBridge.event("drive_calibrate", { sign = d.sign }, "steering sign flipped")
            end
            d.calib.t, d.calib.err = now, err
        end
        -- скорость: медленно при большой ошибке курса, у цели и перед зомби
        local target = maxKmh
        if err > 0.6 then target = math.min(target, 8) elseif err > 0.3 then target = math.min(target, 15) end
        if dist < 20 then target = math.min(target, 10) end
        local zn, zd = zombiesAhead(v, 14)
        if zn > 0 then
            if zn >= 3 or (zd and zd < 4) then
                target = 0
            else
                target = math.min(target, 6)
            end
        end
        if target <= 0 then
            pcall(v.setRegulator, v, false)
            pcall(v.setForceBrake, v)
        else
            if not v:isRegulator() then pcall(v.setRegulator, v, true) end
            pcall(v.setRegulatorSpeed, v, math.max(5, math.floor(target)))
        end
        -- застряли: скорость почти ноль 5 секунд, а ехать надо
        if kmh < 1.5 and target > 0 then
            d.slowSince = d.slowSince or now
            if now - d.slowSince > 5000 then
                V.stopDrive("stuck")
                return "failed", "stuck (obstacle, ditch or zombies); get out or try another path", V.info(v, player)
            end
        else
            d.slowSince = nil
        end
        job.step = string.format("driving to %d,%d: %.0f m, %.0f km/h, heading error %.0f deg%s",
            math.floor(d.tx), math.floor(d.ty), dist, kmh, err * 57.3, zn > 0 and (", zombies ahead " .. zn) or "")
        job.stepUI = T("UI_PZBridge_StepDrive")
        return nil
    end
    job.stop = function(job, player) V.stopDrive("job stopped") end
    PZBridge.startJob(job, ctx)
    return "running", "driving to " .. math.floor(drive.tx) .. "," .. math.floor(drive.ty)
end })

Tool("stop_vehicle", { kind = "control", params = {}, fn = function(a, ctx, p)
    V.stopDrive("stop_vehicle")
    local v = p:getVehicle()
    if v then pcall(v.setRegulator, v, false); pcall(v.setForceBrake, v) end
    return "ok", "braking"
end })

return V
