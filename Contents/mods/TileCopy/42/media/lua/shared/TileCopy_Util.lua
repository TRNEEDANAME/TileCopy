--[[
    TileCopy_Util.lua  (shared)

    Small helpers shared by client + server code:
      - TileCopy.Util.isAdmin(playerObj)   -> boolean
      - TileCopy.Util.serialize(table)     -> string
      - TileCopy.Util.deserialize(string)  -> table or nil
      - TileCopy.Util.log(...)             -> debug print, only when TileCopy.DEBUG is true

]]

TileCopy = TileCopy or {}
TileCopy.DEBUG = false

TileCopy.Util = TileCopy.Util or {}
local Util = TileCopy.Util

local function joinArgs(...)
    local parts = {}
    for i = 1, select("#", ...) do
        parts[#parts + 1] = tostring(select(i, ...))
    end
    return table.concat(parts, " ")
end

function Util.log(...)
    if not TileCopy.DEBUG then return end
    print("[TileCopy] " .. joinArgs(...))
end

--- Always printed (to console.txt)
function Util.info(...)
    print("[TileCopy] " .. joinArgs(...))
end

--- Short, log-safe preview of a long string: its length plus the first
--- and last few characters.
function Util.preview(str, n)
    if type(str) ~= "string" then return tostring(str) end
    n = n or 40
    if #str <= n * 2 then return "(" .. #str .. " chars) " .. str end
    return "(" .. #str .. " chars) " .. str:sub(1, n) .. " ... " .. str:sub(-n)
end

--- Returns true if the given player should be allowed to use the tool.
--- Always true in single player / debug. In multiplayer, requires
--- Admin / Moderator / Overseer access level.
function Util.isAdmin(playerObj)
    playerObj = playerObj or getPlayer()
    if not playerObj then return false end

    if not isClient() and not isServer() then
        -- Single player: allow the tool freely.
        return true
    end

    local accessLevel = playerObj:getAccessLevel()
    if not accessLevel then return false end

    accessLevel = tostring(accessLevel)
    return accessLevel == "admin"
        or accessLevel == "moderator"
        or accessLevel == "overseer"
        or accessLevel == "gm"
end

--------------------------------------------------------------------------
-- Serialization: turns a plain Lua table (strings/numbers/booleans/nested
-- tables into a loadable Lua source string, and back.
--------------------------------------------------------------------------

local function quoteString(s)
    local out = { '"' }
    for i = 1, #s do
        local c = s:sub(i, i)
        local b = string.byte(c)
        if c == '"' or c == "\\" then
            out[#out + 1] = "\\" .. c
        elseif b < 32 or b > 126 then
            -- always 3 digits, or "\10" + "5" would read back as "\105"
            local digits = tostring(b)
            out[#out + 1] = "\\" .. string.rep("0", 3 - #digits) .. digits
        else
            out[#out + 1] = c
        end
    end
    out[#out + 1] = '"'
    return table.concat(out)
end

local function serializeValue(v, buffer)
    local t = type(v)
    if t == "string" then
        buffer[#buffer + 1] = quoteString(v)
    elseif t == "number" or t == "boolean" then
        buffer[#buffer + 1] = tostring(v)
    elseif t == "table" then
        buffer[#buffer + 1] = "{"
        -- array part
        local n = #v
        for i = 1, n do
            serializeValue(v[i], buffer)
            buffer[#buffer + 1] = ","
        end
        for k, val in pairs(v) do
            if not (type(k) == "number" and k >= 1 and k <= n and math.floor(k) == k) then
                buffer[#buffer + 1] = "["
                serializeValue(k, buffer)
                buffer[#buffer + 1] = "]="
                serializeValue(val, buffer)
                buffer[#buffer + 1] = ","
            end
        end
        buffer[#buffer + 1] = "}"
    else
        buffer[#buffer + 1] = "nil"
    end
end

function Util.serialize(tbl)
    local buffer = { "return " }
    serializeValue(tbl, buffer)
    return table.concat(buffer)
end

-- Parser for exactly what serializeValue writes. Used instead of
-- loadstring because compiling a huge pasted table as Lua code through
-- Kahlua's compiler is fragile (and the function doesn't exist in the stable build, thanks TIS), and it gives no useful error when it fails.
-- Returns the parsed value, or nil plus an error message.
local function parseSerialized(str)
    local pos = 1
    local len = #str
    local err

    local function fail(msg)
        err = err or ("parse error at char " .. pos .. ": " .. msg)
        return nil
    end

    local function skipSpace()
        while pos <= len do
            local c = str:sub(pos, pos)
            if c == " " or c == "\n" or c == "\r" or c == "\t" then
                pos = pos + 1
            else
                break
            end
        end
    end

    local parseValue

    local function parseString()
        pos = pos + 1 -- opening quote
        local out = {}
        while true do
            if pos > len then return fail("unterminated string") end
            local c = str:sub(pos, pos)
            if c == '"' then
                pos = pos + 1
                break
            elseif c == "\\" then
                local nextC = str:sub(pos + 1, pos + 1)
                local digits = str:sub(pos + 1, pos + 3):match("^%d%d?%d?")
                if digits then
                    out[#out + 1] = string.char(tonumber(digits))
                    pos = pos + 1 + #digits
                elseif nextC == "n" then
                    out[#out + 1] = "\n"
                    pos = pos + 2
                elseif nextC == "" then
                    return fail("unterminated escape")
                else
                    out[#out + 1] = nextC
                    pos = pos + 2
                end
            else
                out[#out + 1] = c
                pos = pos + 1
            end
        end
        return table.concat(out)
    end

    local function parseTable()
        pos = pos + 1 -- {
        local t = {}
        local arrayIndex = 1
        while true do
            skipSpace()
            local c = str:sub(pos, pos)
            if c == "}" then
                pos = pos + 1
                return t
            elseif c == "" then
                return fail("unterminated table")
            elseif c == "[" then
                pos = pos + 1
                skipSpace()
                local key = parseValue()
                if err then return nil end
                skipSpace()
                if str:sub(pos, pos) ~= "]" then return fail("expected ]") end
                pos = pos + 1
                skipSpace()
                if str:sub(pos, pos) ~= "=" then return fail("expected =") end
                pos = pos + 1
                skipSpace()
                local val = parseValue()
                if err then return nil end
                if key ~= nil then t[key] = val end
            else
                t[arrayIndex] = parseValue()
                if err then return nil end
                arrayIndex = arrayIndex + 1
            end
            skipSpace()
            if str:sub(pos, pos) == "," then pos = pos + 1 end
        end
    end

    parseValue = function()
        skipSpace()
        local c = str:sub(pos, pos)
        if c == "{" then return parseTable() end
        if c == '"' then return parseString() end
        for _, word in ipairs({ "true", "false", "nil" }) do
            if str:sub(pos, pos + #word - 1) == word then
                pos = pos + #word
                if word == "true" then return true end
                if word == "false" then return false end
                return nil
            end
        end
        -- Kahlua's tostring can also write NaN / Infinity for odd floats
        local window = str:sub(pos, pos + 40)
        local special = window:match("^%-?%a+")
        if special == "NaN" or special == "Infinity" or special == "-Infinity" or special == "inf" or special == "-inf" or special == "nan" then
            pos = pos + #special
            return nil
        end
        local num = window:match("^%-?[%d%.]+[eE]?[%-%+]?%d*")
        if num and num ~= "" then
            pos = pos + #num
            local n = tonumber(num)
            if n == nil then return fail("bad number '" .. num .. "'") end
            return n
        end
        return fail("unexpected '" .. c .. "'")
    end

    skipSpace()
    if str:sub(pos, pos + 5) == "return" then pos = pos + 6 end
    local result = parseValue()
    if err then return nil, err end
    return result
end

--- Parses a serialized table. Returns the table, or nil plus an error.
function Util.deserialize(str)
    if not str or str == "" then return nil, "empty input" end

    local result, parseErr = parseSerialized(str)
    if type(result) == "table" then return result end
    parseErr = parseErr or "did not contain a table"
    Util.info("deserialize: parser failed -", parseErr, "- trying loadstring fallback")

    -- Fallback for anything the parser doesn't understand (hand-edited
    -- save files, etc.)
    local chunk
    if loadstring then
        chunk = loadstring(str)
    elseif load then
        chunk = load(str)
    end
    if not chunk then
        return nil, parseErr
    end
    local loaded = chunk()
    if type(loaded) ~= "table" then
        return nil, parseErr
    end
    return loaded
end

-- Did I tell you that my code is *very* weird ? No ? Now you know
local B64_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

function Util.base64Encode(data)
    if not data or data == "" then return "" end
    local out = {}
    for i = 1, #data, 3 do
        -- one byte per call: Kahlua's multi-return string.byte isn't reliable
        local b1 = string.byte(data, i)
        local b2 = (i + 1 <= #data) and string.byte(data, i + 1) or nil
        local b3 = (i + 2 <= #data) and string.byte(data, i + 2) or nil
        local n = b1 * 65536 + (b2 or 0) * 256 + (b3 or 0)

        local c1 = math.floor(n / 262144) % 64
        local c2 = math.floor(n / 4096) % 64
        local c3 = math.floor(n / 64) % 64
        local c4 = n % 64

        local chunkLen = math.min(3, #data - i + 1)
        out[#out + 1] = B64_CHARS:sub(c1 + 1, c1 + 1)
        out[#out + 1] = B64_CHARS:sub(c2 + 1, c2 + 1)
        out[#out + 1] = (chunkLen >= 2) and B64_CHARS:sub(c3 + 1, c3 + 1) or "="
        out[#out + 1] = (chunkLen >= 3) and B64_CHARS:sub(c4 + 1, c4 + 1) or "="
    end
    return table.concat(out)
end

function Util.base64Decode(data)
    if not data or data == "" then return "" end

    local lookup = {}
    for i = 1, #B64_CHARS do lookup[B64_CHARS:sub(i, i)] = i - 1 end

    -- Drop anything that isn't base64 (line breaks, spaces, quotes a chat
    -- client added...) without running a pattern over the whole string.
    local clean = {}
    for i = 1, #data do
        local c = data:sub(i, i)
        if lookup[c] or c == "=" then clean[#clean + 1] = c end
    end
    data = table.concat(clean)

    local out = {}
    local i = 1
    while i <= #data do
        local c1 = lookup[data:sub(i, i)] or 0
        local c2 = lookup[data:sub(i + 1, i + 1)] or 0
        local s3, s4 = data:sub(i + 2, i + 2), data:sub(i + 3, i + 3)
        local c3 = lookup[s3] or 0
        local c4 = lookup[s4] or 0

        local n = c1 * 262144 + c2 * 4096 + c3 * 64 + c4

        local b1 = math.floor(n / 65536) % 256
        local b2 = math.floor(n / 256) % 256
        local b3 = n % 256

        out[#out + 1] = string.char(b1)
        if s3 ~= "" and s3 ~= "=" then out[#out + 1] = string.char(b2) end
        if s4 ~= "" and s4 ~= "=" then out[#out + 1] = string.char(b3) end

        i = i + 4
    end
    return table.concat(out)
end

--------------------------------------------------------------------------
-- File persistence
--------------------------------------------------------------------------

local SAVE_FILE = "TileCopy_Clipboard.txt"

function Util.saveClipboardToDisk(clipboardTable)
    local writer = getFileWriter(SAVE_FILE, true, false)
    if not writer then
        Util.info("save to disk: could not open", SAVE_FILE, "for writing")
        return false
    end
    local serialized = Util.serialize(clipboardTable)
    if not serialized then
        Util.info("save to disk: serialize FAILED")
        writer:close()
        return false
    end
    writer:write(serialized)
    writer:close()
    Util.info("save to disk:", #clipboardTable, "clipboards,", #serialized, "chars ->", SAVE_FILE)
    return true
end

function Util.loadClipboardFromDisk()
    local reader = getFileReader(SAVE_FILE, false)
    if not reader then
        Util.info("load from disk: could not open", SAVE_FILE)
        return nil
    end
    local lines = {}
    while true do
        local line = reader:readLine()
        if not line then break end
        lines[#lines + 1] = line
    end
    reader:close()
    if #lines == 0 then
        Util.info("load from disk:", SAVE_FILE, "is empty")
        return nil
    end
    local text = table.concat(lines, "\n")
    local loaded, err = Util.deserialize(text)
    if loaded then
        Util.info("load from disk:", #loaded, "clipboards from", #text, "chars")
    else
        Util.info("load from disk: parse FAILED -", err)
    end
    return loaded
end
