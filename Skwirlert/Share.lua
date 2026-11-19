-- =============================================================================
-- Skwirlert - Share.lua  (profile export / import "share codes")
-- =============================================================================
-- WHAT THIS FILE DOES
--   Turns a profile into one line of text you can send to a friend, and turns
--   such text back into a NEW profile.
--
--   Code format:  SKW1:<6 hex checksum>:<base64 of serialized data>
--   * Serialization is a tiny data-only format, written out by hand:
--       T ... E   table       S<len>:<bytes>  string
--       N<num>;   number      B1 / B0         boolean
--   * Base64 keeps the code to safe characters (A-Z a-z 0-9 + / =).
--   * The checksum detects codes that were cut off or changed.
--
-- SECURITY (good habits for any addon that imports text)
--   * Imported text is NEVER run as Lua code (no loadstring).
--   * Only whitelisted fields are read; every value is type-checked and
--     clamped; "|" (UI escape codes) and control characters are removed;
--     sizes and nesting depth are limited; unknown sounds are replaced.
--   * Import always creates a new profile; nothing existing is overwritten.
-- =============================================================================

local _, ns = ...
local Share = {}
ns.Share = Share

local PREFIX = "SKW1"
local MAX_CODE = 300000     -- characters
local MAX_DEPTH = 6
local MAX_STR = 60          -- reminder/profile names
local MAX_LIST = 20         -- spell IDs / names per reminder

-- Serializer -----------------------------------------------------------------
local function ser(v, out)
    local t = type(v)
    if t == "table" then
        out[#out + 1] = "T"
        -- deterministic order: array part first, then sorted string keys
        local n = #v
        for i = 1, n do ser(i, out); ser(v[i], out) end
        local keys = {}
        for k in pairs(v) do
            if not (type(k) == "number" and k >= 1 and k <= n and k % 1 == 0) then keys[#keys + 1] = k end
        end
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
        for _, k in ipairs(keys) do ser(k, out); ser(v[k], out) end
        out[#out + 1] = "E"
    elseif t == "string" then
        out[#out + 1] = "S" .. #v .. ":" .. v
    elseif t == "number" then
        out[#out + 1] = "N" .. string.format("%.17g", v) .. ";"
    elseif t == "boolean" then
        out[#out + 1] = v and "B1" or "B0"
    end -- other types are skipped
end

-- Parser: returns value or nil, error. No code execution.
local function parse(s)
    local pos = 1
    local function val(depth)
        if depth > MAX_DEPTH then error("too deeply nested") end
        local c = s:sub(pos, pos)
        if c == "T" then
            pos = pos + 1
            local t = {}
            local count = 0
            while true do
                if pos > #s then error("unexpected end") end
                if s:sub(pos, pos) == "E" then pos = pos + 1; return t end
                local k = val(depth + 1)
                local v = val(depth + 1)
                if type(k) ~= "string" and type(k) ~= "number" then error("bad key") end
                t[k] = v
                count = count + 1
                if count > 2000 then error("too many entries") end
            end
        elseif c == "S" then
            local colon = s:find(":", pos + 1, true)
            if not colon then error("bad string") end
            local len = tonumber(s:sub(pos + 1, colon - 1))
            if not len or len < 0 or len > 10000 or len % 1 ~= 0 then error("bad string length") end
            local str = s:sub(colon + 1, colon + len)
            if #str ~= len then error("unexpected end") end
            pos = colon + len + 1
            return str
        elseif c == "N" then
            local semi = s:find(";", pos + 1, true)
            if not semi then error("bad number") end
            local n = tonumber(s:sub(pos + 1, semi - 1))
            if not n or n ~= n or n == math.huge or n == -math.huge then error("bad number") end
            pos = semi + 1
            return n
        elseif c == "B" then
            local b = s:sub(pos + 1, pos + 1)
            pos = pos + 2
            if b == "1" then return true elseif b == "0" then return false end
            error("bad boolean")
        end
        error("unexpected data")
    end
    local ok, res = pcall(val, 1)
    if not ok then return nil, tostring(res):gsub("^.-:%d+: ", "") end
    if pos ~= #s + 1 then return nil, "trailing data" end
    return res
end

-- Base64 (no bit library needed) ----------------------------------------------
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64IDX = {}
for i = 1, 64 do B64IDX[B64:sub(i, i)] = i - 1 end

-- Bytes -> base64 text. Uses arithmetic instead of bit operations (Lua 5.1 has none).
local function b64encode(s)
    local out = {}
    for i = 1, #s, 3 do
        local a, b, c = s:byte(i, i + 2)
        local n = a * 65536 + (b or 0) * 256 + (c or 0)
        local c1 = math.floor(n / 262144) % 64
        local c2 = math.floor(n / 4096) % 64
        local c3 = math.floor(n / 64) % 64
        local c4 = n % 64
        out[#out + 1] = B64:sub(c1 + 1, c1 + 1) .. B64:sub(c2 + 1, c2 + 1)
            .. (b and B64:sub(c3 + 1, c3 + 1) or "=") .. (c and B64:sub(c4 + 1, c4 + 1) or "=")
    end
    return table.concat(out)
end

-- Base64 text -> bytes, or nil if the text isn't valid base64.
local function b64decode(s)
    if #s % 4 ~= 0 then return nil end
    local out = {}
    for i = 1, #s, 4 do
        local q = { s:byte(i, i + 3) }
        local v = {}
        local pad = 0
        for j = 1, 4 do
            local ch = string.char(q[j])
            if ch == "=" then
                if i + 3 ~= #s or j < 3 then return nil end
                v[j] = 0; pad = pad + 1
            else
                if pad > 0 then return nil end
                v[j] = B64IDX[ch]
                if not v[j] then return nil end
            end
        end
        local n = v[1] * 262144 + v[2] * 4096 + v[3] * 64 + v[4]
        local a = math.floor(n / 65536) % 256
        local b = math.floor(n / 256) % 256
        local c = n % 256
        if pad == 0 then out[#out + 1] = string.char(a, b, c)
        elseif pad == 1 then out[#out + 1] = string.char(a, b)
        else out[#out + 1] = string.char(a) end
    end
    return table.concat(out)
end

-- A small rolling hash, shown as 6 hex digits, to detect damaged codes.
local function checksum(s)
    local h = 7
    for i = 1, #s do h = (h * 31 + s:byte(i)) % 16777213 end
    return string.format("%06x", h)
end

-- Sanitising -------------------------------------------------------------------
local function cleanStr(v, maxLen)
    if type(v) ~= "string" then return nil end
    v = v:gsub("|", ""):gsub("[%c]", ""):gsub("^%s+", ""):gsub("%s+$", "")
    if v == "" then return nil end
    if #v > (maxLen or MAX_STR) then v = v:sub(1, maxLen or MAX_STR) end
    return v
end

-- Keep only valid, unique, positive whole-number spell IDs (max 20).
local function idList(v)
    local out, seen = {}, {}
    if type(v) ~= "table" then return out end
    for _, n in ipairs(v) do
        if type(n) == "number" and n > 0 and n < 2147483647 and n % 1 == 0 and not seen[n] then
            seen[n] = true; out[#out + 1] = n
            if #out >= MAX_LIST then break end
        end
    end
    return out
end

-- Keep only clean, non-empty spell names (max 20).
local function nameList(v)
    local out = {}
    if type(v) ~= "table" then return out end
    for _, n in ipairs(v) do
        local s = cleanStr(n)
        if s then out[#out + 1] = s end
        if #out >= MAX_LIST then break end
    end
    return out
end

local KINDS = { self = true, targeted = true, timer = true }
local ANNOUNCE = { off = true, say = true, party = true, raid = true, group = true }
local CHANNELS = { Master = true, SFX = true, Music = true, Ambience = true, Dialog = true }

-- The reminder fields that are shared (no ids or running state).
local function exportReminder(r)
    return {
        name = r.name, kind = r.kind, spellIDs = r.spellIDs, names = r.names, learnedIDs = r.learnedIDs,
        duration = r.duration, learnedDuration = r.learnedDuration, warn = r.warn,
        warnSound = r.warnSound, expireSound = r.expireSound, enabled = r.enabled, expireAlert = r.expireAlert,
        announce = r.announce, announceApplied = r.announceApplied, announceWarn = r.announceWarn,
        perMember = r.perMember or nil,   -- 0.8.0 (older versions ignore it)
    }
end

-- Rebuild a reminder from imported data, validating every field.
local function importReminder(x)
    if type(x) ~= "table" then return nil end
    local r = {
        name = cleanStr(x.name) or "Imported reminder",
        kind = KINDS[x.kind] and x.kind or "self",
        spellIDs = idList(x.spellIDs),
        names = nameList(x.names),
        learnedIDs = idList(x.learnedIDs),
        duration = type(x.duration) == "number" and x.duration or 1800,
        warn = type(x.warn) == "number" and x.warn or 30,
        warnSound = (type(x.warnSound) == "string" and ns.Sounds.Exists(x.warnSound)) and x.warnSound or "quick-tone",
        expireSound = (type(x.expireSound) == "string" and ns.Sounds.Exists(x.expireSound)) and x.expireSound or "Uh Oh",
        enabled = x.enabled ~= false,
        expireAlert = x.expireAlert ~= false,
        announce = ANNOUNCE[x.announce] and x.announce or "off",
        announceApplied = x.announceApplied ~= false,
        announceWarn = x.announceWarn ~= false,
        perMember = x.perMember == true,
    }
    if type(x.learnedDuration) == "number" and x.learnedDuration > 0 and x.learnedDuration <= 86400 then
        r.learnedDuration = x.learnedDuration
    end
    return r
end

-- Public -------------------------------------------------------------------------
function Share.Export(profileName)
    profileName = profileName or ns.Profiles.Current()
    local p = ns.sv.profiles[profileName]
    if not p then return nil, "no such profile" end
    local data = {
        app = "Skwirlert", v = 1, name = profileName,
        enabled = p.enabled, channel = p.channel, popupDuration = p.popup and p.popup.duration,
        refreshMin = p.refresh and p.refresh.minDuration,   -- 0.8.0 (older versions ignore it)
        reminders = {},
    }
    for _, r in ipairs(p.reminders) do data.reminders[#data.reminders + 1] = exportReminder(r) end
    local out = {}
    ser(data, out)
    local raw = table.concat(out)
    return PREFIX .. ":" .. checksum(raw) .. ":" .. b64encode(raw), #data.reminders
end

-- Decode and validate a code. Returns a ready profile table + suggested name, or nil + error.
function Share.Decode(code)
    if type(code) ~= "string" then return nil, "no code" end
    code = code:gsub("%s+", "")
    if code == "" then return nil, "paste a share code first" end
    if #code > MAX_CODE then return nil, "that code is too long" end
    local sum, body = code:match("^" .. PREFIX .. ":(%x%x%x%x%x%x):([A-Za-z0-9+/=]+)$")
    if not sum then return nil, "that isn't a Skwirlert share code (it should start with " .. PREFIX .. ":)" end
    local raw = b64decode(body)
    if not raw then return nil, "the code is damaged (bad characters or length). Copy it again in full." end
    if checksum(raw) ~= sum:lower() then return nil, "the code is incomplete or changed (checksum mismatch). Copy it again in full." end
    local data, err = parse(raw)
    if not data then return nil, "the code couldn't be read: " .. tostring(err) end
    if type(data) ~= "table" or data.app ~= "Skwirlert" or data.v ~= 1 then
        return nil, "the code is from an unsupported version"
    end
    local p = ns.EmptyProfile()
    p.enabled = data.enabled ~= false
    p.channel = CHANNELS[data.channel] and data.channel or "Master"
    if type(data.popupDuration) == "number" then
        p.popup.duration = math.max(0.5, math.min(10, data.popupDuration))
    end
    if type(data.refreshMin) == "number" then
        p.refresh.minDuration = math.max(0, math.min(86400, math.floor(data.refreshMin)))
    end
    local skipped = 0
    if type(data.reminders) == "table" then
        for _, x in ipairs(data.reminders) do
            if #p.reminders >= ns.MAX_REMINDERS then skipped = skipped + 1
            else
                local r = importReminder(x)
                if r then
                    r = ns.NormalizeReminder(r, p.nextId)
                    r.id = p.nextId
                    p.nextId = p.nextId + 1
                    p.reminders[#p.reminders + 1] = r
                end
            end
        end
    end
    return p, cleanStr(data.name), skipped
end

-- Avoid overwriting: "Name" -> "Name 2" if it already exists.
local function uniqueName(base)
    local name = base
    local i = 2
    while ns.Profiles.Exists(name) do name = base .. " " .. i; i = i + 1 end
    return name
end

-- Import a code as a NEW profile and switch to it. Never overwrites a profile.
function Share.Import(code, wantedName)
    local p, suggested, skipped = Share.Decode(code)
    if not p then return false, suggested end
    local name = cleanStr(wantedName) or ((suggested or "Shared") .. " (imported)")
    name = uniqueName(name)
    ns.sv.profiles[name] = p
    local ok, err = ns.Profiles.Use(name)
    if not ok then return false, err end
    return true, name, #p.reminders, skipped or 0
end

Share._test = { ser = ser, parse = parse, b64encode = b64encode, b64decode = b64decode, checksum = checksum }
