-- PZBridge: окно «Доступ агента» (F9).
-- Переключатель доступа, чат игрока с агентом, лог, статус задачи, кнопка «Стоп».
-- Позиция окна и доступ не сохраняются: после каждой загрузки доступ выключен.

require "ISUI/ISCollapsableWindow"
require "ISUI/ISButton"
require "ISUI/ISTickBox"
require "ISUI/ISLabel"
require "ISUI/ISTextEntryBox"
require "ISUI/ISScrollingListBox"
require "PZBridge/PZB_Core"

local U = PZBridge.U
local S = PZBridge.S
local T = PZBridge.T
PZBridge.UI = PZBridge.UI or {}
local UI = PZBridge.UI

local COLORS = {
    player = { 0.55, 0.85, 1.0 },
    agent  = { 0.6, 1.0, 0.6 },
    mod    = { 0.85, 0.85, 0.85 },
}
-- Подписи в логе окна (переводы в Translate/<язык>/UI.json).
local WHO = { player = "UI_PZBridge_WhoPlayer", agent = "UI_PZBridge_WhoAgent", mod = "UI_PZBridge_WhoMod" }

PZBridgeWindow = ISCollapsableWindow:derive("PZBridgeWindow")

function PZBridgeWindow:new(x, y, w, h)
    local o = ISCollapsableWindow.new(self, x, y, w, h)
    o.title = T("UI_PZBridge_Title")
    o.minimumWidth = 360
    o.minimumHeight = 300
    return o
end

function PZBridgeWindow:createChildren()
    ISCollapsableWindow.createChildren(self)
    local font = UIFont.Small
    local fh = getTextManager():getFontHeight(font)
    local pad = 10
    local y = self:titleBarHeight() + 6

    self.tick = ISTickBox:new(pad, y, 220, fh + 4, "", self, PZBridgeWindow.onAccessTick)
    self.tick:initialise()
    self.tick:instantiate()
    self.tick:addOption(T("UI_PZBridge_AllowControl"))
    self:addChild(self.tick)

    self.stopBtn = ISButton:new(self.width - pad - 80, y, 80, fh + 6, T("UI_PZBridge_Stop"), self, PZBridgeWindow.onStop)
    self.stopBtn:initialise()
    self.stopBtn:instantiate()
    self:addChild(self.stopBtn)
    y = y + fh + 12

    self.lblTask = ISLabel:new(pad, y, fh, T("UI_PZBridge_Task", T("UI_PZBridge_TaskNone")), 1, 1, 1, 1, font, true)
    self.lblTask:initialise()
    self:addChild(self.lblTask)
    y = y + fh + 2
    self.lblStep = ISLabel:new(pad, y, fh, T("UI_PZBridge_Step", "-"), 0.9, 0.9, 0.9, 1, font, true)
    self.lblStep:initialise()
    self:addChild(self.lblStep)
    y = y + fh + 2
    self.lblThreat = ISLabel:new(pad, y, fh, T("UI_PZBridge_Threat", "-"), 1, 0.8, 0.5, 1, font, true)
    self.lblThreat:initialise()
    self:addChild(self.lblThreat)
    y = y + fh + 8

    local entryH = fh + 8
    local bottom = self.height - pad - entryH
    self.log = ISScrollingListBox:new(pad, y, self.width - pad * 2, bottom - y - 8)
    self.log:initialise()
    self.log:instantiate()
    self.log.itemheight = fh + 3
    self.log.font = font
    self.log.drawBorder = true
    self.log.doDrawItem = PZBridgeWindow.drawLogItem
    self:addChild(self.log)

    self.entry = ISTextEntryBox:new("", pad, bottom, self.width - pad * 3 - 90, entryH)
    self.entry:initialise()
    self.entry:instantiate()
    self.entry.font = font
    local win = self
    self.entry.onCommandEntered = function(_) win:onSend() end
    self:addChild(self.entry)

    self.sendBtn = ISButton:new(self.width - pad - 90, bottom, 90, entryH, T("UI_PZBridge_Send"), self, PZBridgeWindow.onSend)
    self.sendBtn:initialise()
    self.sendBtn:instantiate()
    self:addChild(self.sendBtn)

    self.tick:setSelected(1, S.access == true)
    for _, m in ipairs(S.chat) do self:addLogLine(m.who, m.text, m.gt) end
end

function PZBridgeWindow.drawLogItem(list, y, item, alt)
    local c = (item.item and item.item.color) or COLORS.mod
    list:drawText(item.text, 6, y + 1, c[1], c[2], c[3], 1, list.font)
    return y + list.itemheight
end

-- Перенос длинной строки по ширине списка.
local function wrap(text, font, width)
    local tm = getTextManager()
    local lines = {}
    local cur = ""
    for word in string.gmatch(tostring(text), "%S+") do
        local test = (cur == "") and word or (cur .. " " .. word)
        if tm:MeasureStringX(font, test) > width and cur ~= "" then
            lines[#lines + 1] = cur
            cur = word
        else
            cur = test
        end
    end
    if cur ~= "" then lines[#lines + 1] = cur end
    if #lines == 0 then lines[1] = "" end
    return lines
end

function PZBridgeWindow:addLogLine(who, text, gt)
    if not self.log then return end
    local prefix = (gt and gt ~= "" and ("[" .. gt .. "] ") or "") .. (WHO[who] and T(WHO[who]) or tostring(who)) .. ": "
    local lines = wrap(prefix .. tostring(text), self.log.font, self.log.width - 24)
    for _, l in ipairs(lines) do
        self.log:addItem(l, { color = COLORS[who] or COLORS.mod })
    end
    if #self.log.items > 600 and not self.rebuilding then
        -- пересобрать лог из последних сообщений, чтобы список не рос бесконечно
        self.rebuilding = true
        self.log:clear()
        for _, m in ipairs(S.chat) do self:addLogLine(m.who, m.text, m.gt) end
        self.rebuilding = false
    end
    pcall(self.log.ensureVisible, self.log, #self.log.items)
end

function PZBridgeWindow:onAccessTick(index, selected)
    PZBridge.setAccess(selected == true)
end

function PZBridgeWindow:onStop()
    PZBridge.stopAll("stop button")
    PZBridge.event("stop", { by = "player" }, "player pressed Stop")
    PZBridge.chatAdd("mod", T("UI_PZBridge_StoppedByPlayer"))
end

function PZBridgeWindow:onSend()
    local text = U.trim(self.entry:getText() or "")
    if text == "" then return end
    self.entry:setText("")
    PZBridge.sendPlayerMessage(text)
    if not S.access then
        PZBridge.chatAdd("mod", T("UI_PZBridge_AccessOffMsg"))
    end
end

function PZBridgeWindow:refreshStatus()
    if not self.lblTask then return end
    local job = S.job or S.pausedJob
    local name = job and job.name or T("UI_PZBridge_TaskNone")
    if S.pausedJob and not S.job then name = T("UI_PZBridge_TaskPaused", name) end
    self.lblTask:setName(T("UI_PZBridge_Task", name) .. (S.access and "" or ("   " .. T("UI_PZBridge_AccessOffTag"))))
    self.lblStep:setName(T("UI_PZBridge_Step", tostring(job and (job.stepUI or job.step) or "-")))
    local p = PZBridge.player()
    local threat = "-"
    if p and PZBridge.P then
        local ok, t = pcall(PZBridge.P.threat, p, PZBridge.guard)
        if ok and t then
            threat = T("UI_PZBridge_ThreatCount", t.count, PZBridge.guard.threat_radius or 15) ..
                (t.nearest_dist and T("UI_PZBridge_ThreatNearest", t.nearest_dist) or "") ..
                (t.seeing > 0 and T("UI_PZBridge_ThreatSeeing", t.seeing) or "")
        end
    end
    if S.alert then threat = threat .. "  ALERT" end
    self.lblThreat:setName(T("UI_PZBridge_Threat", threat))
    if self.tick:isSelected(1) ~= (S.access == true) then self.tick:setSelected(1, S.access == true) end
end

function PZBridgeWindow:close()
    ISCollapsableWindow.close(self)
    self:removeFromUIManager()
    UI.window = nil
end

---------------------------------------------------------------------------

function UI.toggle()
    if UI.window then
        UI.window:close()
        return
    end
    local w, h = 460, 420
    local x = getCore():getScreenWidth() - w - 40
    local y = 120
    local win = PZBridgeWindow:new(x, y, w, h)
    win:initialise()
    win:addToUIManager()
    win:setVisible(true)
    UI.window = win
    win:refreshStatus()
end

function UI.onChat(who, text)
    if UI.window then
        local last = S.chat[#S.chat]
        UI.window:addLogLine(who, text, last and last.gt or nil)
    end
end

local lastRefresh = 0
function UI.tick()
    if not UI.window then return end
    local now = U.nowMs()
    if now - lastRefresh < 400 then return end
    lastRefresh = now
    UI.window:refreshStatus()
end

-- Горячая клавиша через ModOptions (можно переназначить в настройках модов), по умолчанию F9.
if PZAPI and PZAPI.ModOptions and PZAPI.ModOptions.create then
    local ok, opts = pcall(function() return PZAPI.ModOptions:create("PZBridge", "PZBridge") end)
    if ok and opts then
        UI.keyOption = opts:addKeyBind("toggleWindow", T("UI_PZBridge_KeyToggle"), Keyboard.KEY_F9)
    end
end

local function onKeyPressed(key)
    if not S.enabled then return end
    local want = PZBridge.config.uiKey or (UI.keyOption and UI.keyOption:getValue()) or Keyboard.KEY_F9
    if key == want then UI.toggle() end
end

Events.OnKeyPressed.Add(onKeyPressed)

local function onGameStartUI()
    UI.window = nil
end
Events.OnGameStart.Add(onGameStartUI)
