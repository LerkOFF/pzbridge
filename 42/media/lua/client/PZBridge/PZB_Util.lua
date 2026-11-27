-- PZBridge: общие утилиты (JSON, файлы, лог, мелкие помощники).
-- Kahlua в Project Zomboid соответствует Lua 5.1: без goto, без битовых операций.

PZBridge = PZBridge or {}
PZBridge.U = PZBridge.U or {}
local U = PZBridge.U

U.PREFIX = "[PZBridge] "

function U.log(msg)
    print(U.PREFIX .. tostring(msg))
end

function U.nowMs()
    local ok, t = pcall(getTimestampMs)
    if ok and t then return t end
    return 0
end

function U.round(x, n)
    if type(x) ~= "number" then return x end
    if x ~= x then return 0 end
    local m = 10 ^ (n or 2)
    return math.floor(x * m + 0.5) / m
end

function U.clamp(x, a, b)
    if x < a then return a end
    if x > b then return b end
    return x
end

function U.dist(x1, y1, x2, y2)
    local dx, dy = x1 - x2, y1 - y2
    return math.sqrt(dx * dx + dy * dy)
end

-- Безопасный вызов метода Java-объекта: U.try(obj, "method", args...) -> значение или nil.
function U.try(obj, name, ...)
    if obj == nil then return nil end
    local f = obj[name]
    if f == nil then return nil end
    local ok, r = pcall(f, obj, ...)
    if ok then return r end
    return nil
end

function U.trim(s)
    return (tostring(s):gsub("^%s+", ""):gsub("%s+$", ""))
end

function U.lower(s)
    if s == nil then return "" end
    return string.lower(tostring(s))
end

function U.split(s, sep)
    local out = {}
    for part in string.gmatch(s, "[^" .. sep .. "]+") do
        out[#out + 1] = part
    end
    return out
end

function U.shallowCopy(t)
    local o = {}
    for k, v in pairs(t) do o[k] = v end
    return o
end

-- Перебор Java ArrayList / List: U.each(list, function(item, index0) ... end)
function U.each(list, fn)
    if list == nil then return end
    local n = list:size()
    for i = 0, n - 1 do
        local r = fn(list:get(i), i)
        if r == "break" then return end
    end
end

---------------------------------------------------------------------------
-- JSON
---------------------------------------------------------------------------

U.ARRAY_MT = { __jsonarray = true }

-- Пометить таблицу как JSON-массив (нужно для пустых массивов).
function U.array(t)
    return setmetatable(t or {}, U.ARRAY_MT)
end

local HEX = "0123456789abcdef"
local function hex4(n)
    local s = ""
    for _ = 1, 4 do
        local d = n % 16
        s = HEX:sub(d + 1, d + 1) .. s
        n = math.floor(n / 16)
    end
    return s
end

local ESC = { ['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }

local function escapeChar(c)
    local e = ESC[c]
    if e then return e end
    return "\\u" .. hex4(string.byte(c))
end

local function encodeString(s)
    s = tostring(s)
    s = s:gsub('[%c"\\]', escapeChar)
    return '"' .. s .. '"'
end

local function encodeNumber(x)
    if x ~= x or x == math.huge or x == -math.huge then return "null" end
    if x == math.floor(x) and math.abs(x) < 1e15 then
        local s = tostring(x)
        s = s:gsub("%.0+$", "")
        if s:find("[eE]") then
            s = string.format("%.0f", x)
        end
        return s
    end
    if math.abs(x) < 0.0001 then return "0" end
    local s = tostring(U.round(x, 4))
    return s
end

local function isArray(t)
    local mt = getmetatable(t)
    if mt and mt.__jsonarray then return true end
    local n = #t
    if n == 0 then return false end
    for k, _ in pairs(t) do
        if type(k) ~= "number" or k < 1 or k > n or k ~= math.floor(k) then
            return false
        end
    end
    return true
end

local encodeValue

encodeValue = function(v, depth, buf)
    depth = depth or 0
    if depth > 40 then buf[#buf + 1] = "null"; return end
    local tv = type(v)
    if v == nil then
        buf[#buf + 1] = "null"
    elseif tv == "boolean" then
        buf[#buf + 1] = v and "true" or "false"
    elseif tv == "number" then
        buf[#buf + 1] = encodeNumber(v)
    elseif tv == "string" then
        buf[#buf + 1] = encodeString(v)
    elseif tv == "table" then
        if isArray(v) then
            buf[#buf + 1] = "["
            for i = 1, #v do
                if i > 1 then buf[#buf + 1] = "," end
                encodeValue(v[i], depth + 1, buf)
            end
            buf[#buf + 1] = "]"
        else
            buf[#buf + 1] = "{"
            local keys = {}
            for k, _ in pairs(v) do
                keys[#keys + 1] = tostring(k)
            end
            table.sort(keys)
            local first = true
            for _, k in ipairs(keys) do
                local val = v[k]
                if val == nil then val = v[tonumber(k)] end
                if not first then buf[#buf + 1] = "," end
                first = false
                buf[#buf + 1] = encodeString(k)
                buf[#buf + 1] = ":"
                encodeValue(val, depth + 1, buf)
            end
            buf[#buf + 1] = "}"
        end
    else
        -- Java-объекты и функции в JSON не попадают, только их строковое имя.
        buf[#buf + 1] = encodeString(tostring(v))
    end
end

function U.jsonEncode(v)
    local buf = {}
    encodeValue(v, 0, buf)
    return table.concat(buf)
end

-- Разбор JSON. Возвращает значение или nil, текст ошибки.
local function utf8char(code)
    if code < 128 then return string.char(code) end
    -- В Kahlua строки - это Java-строки, символ с кодом > 255 допустим.
    local ok, c = pcall(string.char, code)
    if ok then return c end
    return "?"
end

function U.jsonDecode(str)
    if type(str) ~= "string" then return nil, "not a string" end
    local pos = 1
    local len = #str

    local function skip()
        while pos <= len do
            local c = str:sub(pos, pos)
            if c == " " or c == "\t" or c == "\n" or c == "\r" then
                pos = pos + 1
            else
                break
            end
        end
    end

    local parseValue

    local function parseString()
        pos = pos + 1
        local out = {}
        while pos <= len do
            local c = str:sub(pos, pos)
            if c == '"' then
                pos = pos + 1
                return table.concat(out)
            elseif c == "\\" then
                local n = str:sub(pos + 1, pos + 1)
                if n == "n" then out[#out + 1] = "\n"
                elseif n == "r" then out[#out + 1] = "\r"
                elseif n == "t" then out[#out + 1] = "\t"
                elseif n == "b" then out[#out + 1] = "\b"
                elseif n == "f" then out[#out + 1] = "\f"
                elseif n == "u" then
                    local h = str:sub(pos + 2, pos + 5)
                    local code = tonumber(h, 16) or 63
                    out[#out + 1] = utf8char(code)
                    pos = pos + 4
                else
                    out[#out + 1] = n
                end
                pos = pos + 2
            else
                out[#out + 1] = c
                pos = pos + 1
            end
        end
        error("unterminated string")
    end

    local function parseNumber()
        local s, e = str:find("^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
        if not s then error("bad number at " .. pos) end
        local num = tonumber(str:sub(s, e))
        pos = e + 1
        if num == nil then error("bad number at " .. s) end
        return num
    end

    local function parseArray()
        pos = pos + 1
        local arr = U.array({})
        skip()
        if str:sub(pos, pos) == "]" then pos = pos + 1; return arr end
        while true do
            arr[#arr + 1] = parseValue()
            skip()
            local c = str:sub(pos, pos)
            if c == "," then
                pos = pos + 1
            elseif c == "]" then
                pos = pos + 1
                return arr
            else
                error("expected , or ] at " .. pos)
            end
        end
    end

    local function parseObject()
        pos = pos + 1
        local obj = {}
        skip()
        if str:sub(pos, pos) == "}" then pos = pos + 1; return obj end
        while true do
            skip()
            if str:sub(pos, pos) ~= '"' then error("expected key at " .. pos) end
            local k = parseString()
            skip()
            if str:sub(pos, pos) ~= ":" then error("expected : at " .. pos) end
            pos = pos + 1
            obj[k] = parseValue()
            skip()
            local c = str:sub(pos, pos)
            if c == "," then
                pos = pos + 1
            elseif c == "}" then
                pos = pos + 1
                return obj
            else
                error("expected , or } at " .. pos)
            end
        end
    end

    parseValue = function()
        skip()
        local c = str:sub(pos, pos)
        if c == "{" then return parseObject()
        elseif c == "[" then return parseArray()
        elseif c == '"' then return parseString()
        elseif c == "t" and str:sub(pos, pos + 3) == "true" then pos = pos + 4; return true
        elseif c == "f" and str:sub(pos, pos + 4) == "false" then pos = pos + 5; return false
        elseif c == "n" and str:sub(pos, pos + 3) == "null" then pos = pos + 4; return nil
        else return parseNumber() end
    end

    local ok, res = pcall(parseValue)
    if not ok then return nil, tostring(res) end
    return res
end

---------------------------------------------------------------------------
-- Файлы. getFileWriter/getFileReader работают в ~/Zomboid/Lua/,
-- разрешены только расширения ini, cfg, txt, log, json.
---------------------------------------------------------------------------

function U.writeFile(name, content)
    local ok, err = pcall(function()
        local w = getFileWriter(name, true, false)
        if not w then error("getFileWriter returned nil for " .. name) end
        w:write(content)
        w:close()
    end)
    if not ok then U.log("write error " .. name .. ": " .. tostring(err)) end
    return ok
end

function U.appendLine(name, line)
    local ok, err = pcall(function()
        local w = getFileWriter(name, true, true)
        if not w then error("getFileWriter returned nil for " .. name) end
        w:write(line .. "\n")
        w:close()
    end)
    if not ok then U.log("append error " .. name .. ": " .. tostring(err)) end
    return ok
end

function U.readLines(name)
    local lines = {}
    local ok, err = pcall(function()
        local r = getFileReader(name, true)
        if not r then return end
        local line = r:readLine()
        while line ~= nil do
            lines[#lines + 1] = line
            line = r:readLine()
        end
        r:close()
    end)
    if not ok then U.log("read error " .. name .. ": " .. tostring(err)) end
    return lines
end

return U
