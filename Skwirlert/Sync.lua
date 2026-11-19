-- =============================================================================
-- Skwirlert - Sync.lua  (Group Sync: share running timers with groupmates)
-- =============================================================================
-- WHAT THIS FILE DOES
--   Lets players in the same party/raid who all run Skwirlert see each other's
--   RUNNING timers (buff name, time left, verified/estimated, recipient for
--   buffs cast on others such as Soulstone). Nothing else is shared.
--
-- DESIGN: LOW OVERHEAD, EVENT-DRIVEN
--   * Messages go out only when something changes (a timer starts, refreshes
--     or ends, or the group changes). Changes inside the "frequency" window are
--     merged into ONE message. There is no polling and no heartbeat.
--   * Receivers count the timers down locally, so no repeated updates are needed.
--   * "Don't send during combat" (default on) holds updates until combat ends.
--   * If the client blocks addon messages (boss-fight lockdown) or throttles
--     them, the update is kept and retried later. Nothing is lost or spammed.
--
-- SETTINGS (per profile):  <profile>.sync = { mode, freq, noCombat }
--   mode = "share" (share and receive) | "receive" (receive only) | "off"
--   freq = "low" (at most every 15 s, default) | "normal" (8 s) | "high" (4 s)
--
-- MESSAGE FORMAT (prefix "SKWIRLERT", <= 255 bytes each, version 1)
--   1^H^<addon version>                      hello (sent with every update)
--   1^S^<set id>^<part>/<parts>^<entries>     timers; entries separated by ";"
--        entry = <name>,<seconds left>,<v|e|t>,<recipient or empty>
--        (a per-member copy, e.g. your Arcane Intellect on Bob, is sent with
--         recipient "Bob"; the format is unchanged from the first 0.8.0 build)
--   1^C                                      "I have no running timers / stopped sharing"
--   Names have the separators and "|" removed before sending. Everything
--   received is validated and length/count-limited before use.
--
-- WOW CONCEPTS
--   * C_ChatInfo.RegisterAddonMessagePrefix(prefix) once; then
--     C_ChatInfo.SendAddonMessage(prefix, text, "PARTY"|"RAID"|"INSTANCE_CHAT").
--   * CHAT_MSG_ADDON (prefix, text, channel, sender) delivers incoming messages.
--     Players never see these messages.
--   * Addon messages are throttled per prefix by the server and can be blocked
--     during encounters (C_ChatInfo.InChatMessagingLockdown()).
-- =============================================================================

local _, ns = ...
local C = ns.Compat
local Sync = {}
ns.Sync = Sync

Sync.PREFIX = "SKWIRLERT"
Sync.PROTOCOL = "1"
Sync.MODES = { "share", "receive", "off" }
Sync.MODE_LABEL = { share = "Share and receive", receive = "Receive only", off = "Off" }
Sync.FREQS = { "low", "normal", "high" }
Sync.FREQ_LABEL = { low = "Low (recommended)", normal = "Normal", high = "High" }
Sync.FREQ_GAP = { low = 15, normal = 8, high = 4 }     -- minimum seconds between updates
Sync.MAX_ENTRIES = 20       -- shared per player
Sync.MAX_PEERS = 40
Sync.MAX_MSG = 250          -- bytes (server limit is 255)

Sync.peers = {}             -- [sender] = { version, updated, entries = { {name, expiresAt, kind, recipient} } }
Sync.stats = { sent = 0, received = 0, deferred = 0, rejected = 0 }

local lastSent = -1e9
local pendingTimer
local dirty = false
local setCounter = 0
local incoming = {}         -- [sender] = { id, parts, got = {[n] = entries}, count }

local function now() return GetTime() end
function Sync.Settings() return ns.db and ns.db.sync end
local function mode() local s = Sync.Settings(); return s and s.mode or "off" end

local function plainBool(fn, ...)
    if not fn then return false end
    local ok, v = pcall(fn, ...)
    return ok and C.Bool(v) or false
end

-- Party, raid or instance-group channel; nil when solo.
function Sync.Channel()
    local home, inst = _G.LE_PARTY_CATEGORY_HOME, _G.LE_PARTY_CATEGORY_INSTANCE
    if inst and home and plainBool(_G.IsInGroup, inst) and not plainBool(_G.IsInGroup, home) then return "INSTANCE_CHAT" end
    if plainBool(_G.IsInRaid) then return "RAID" end
    if plainBool(_G.IsInGroup) then return "PARTY" end
    return nil
end

local function clean(s, maxLen)
    s = tostring(s or ""):gsub("[|%^;,%c]", ""):gsub("^%s+", ""):gsub("%s+$", "")
    if #s > maxLen then s = s:sub(1, maxLen) end
    return s
end

local function shortName(n)
    n = C.Str(n); if not n then return nil end
    return (n:gsub("%-.*$", ""))
end

-- Our running timers, soonest first, as compact entries.
local function collect()
    local list = {}
    if not ns.db then return list end
    local t = now()
    for _, r in ipairs(ns.db.reminders) do
        local st = r.enabled and ns.Engine:State(r.id)
        local all = {}
        if st then all[1] = st end
        if r.enabled then   -- per-member copies (0.8.0) are shared with the member's name
            for _, m in ipairs(ns.Engine:Members(r.id)) do all[#all + 1] = m end
        end
        for _, s in ipairs(all) do
            if s.expires > t then
                local kind = (r.kind == "timer" or s.source == "manual") and "t"
                    or ((s.source == "verified" or s.source == "shared") and "v" or "e")
                local who = s.member or (r.kind == "targeted" and s.recipient ~= "unknown target" and s.recipient)
                local rcp = who and clean(who, 24) or ""
                list[#list + 1] = { left = s.expires - t, text = clean(r.name, 32) .. "," .. math.floor(s.expires - t + 0.5) .. "," .. kind .. "," .. rcp }
            end
        end
    end
    table.sort(list, function(a, b) return a.left < b.left end)
    while #list > Sync.MAX_ENTRIES do table.remove(list) end
    return list
end

-- Split entries into messages of at most MAX_MSG bytes.
local function buildMessages(entries)
    setCounter = (setCounter % 999) + 1
    local header = Sync.PROTOCOL .. "^S^" .. setCounter .. "^"
    local chunks, cur = {}, {}
    local curLen = 0
    for _, e in ipairs(entries) do
        local add = #e.text + (#cur > 0 and 1 or 0)
        if #cur > 0 and #header + 6 + curLen + add > Sync.MAX_MSG then
            chunks[#chunks + 1] = cur; cur, curLen = {}, 0; add = #e.text
        end
        cur[#cur + 1] = e.text; curLen = curLen + add
    end
    if #cur > 0 then chunks[#chunks + 1] = cur end
    local msgs = {}
    for i, c in ipairs(chunks) do
        msgs[#msgs + 1] = header .. i .. "/" .. #chunks .. "^" .. table.concat(c, ";")
    end
    return msgs
end

local function rawSend(text, channel)
    local CI = _G.C_ChatInfo
    if not (CI and CI.SendAddonMessage) then return false, "no addon messaging API" end
    if CI.InChatMessagingLockdown and plainBool(CI.InChatMessagingLockdown) then return false, "lockdown" end
    local ok, res = pcall(CI.SendAddonMessage, Sync.PREFIX, text, channel)
    if not ok then return false, tostring(res) end
    if res == false then return false, "rejected" end
    if type(res) == "number" and res ~= 0 then return false, "throttled (" .. res .. ")" end
    return true
end

local schedule

-- Send our current state now (if allowed). Returns true if sent.
local function flush()
    pendingTimer = nil
    if mode() ~= "share" or not dirty then return false end
    local channel = Sync.Channel()
    if not channel then dirty = false; return false end
    local s = Sync.Settings()
    if s.noCombat and C.InCombat() then
        Sync.stats.deferred = Sync.stats.deferred + 1
        ns.Debug("sync: deferred (combat)")
        return false                                   -- PLAYER_REGEN_ENABLED retries
    end
    local entries = collect()
    local msgs = { Sync.PROTOCOL .. "^H^" .. clean(ns.version, 20) }
    if #entries == 0 then msgs[2] = Sync.PROTOCOL .. "^C"
    else for _, m in ipairs(buildMessages(entries)) do msgs[#msgs + 1] = m end end
    for _, m in ipairs(msgs) do
        local ok, why = rawSend(m, channel)
        if not ok and why == "no addon messaging API" then dirty = false; return false end   -- nothing to retry
        if not ok then
            Sync.stats.deferred = Sync.stats.deferred + 1
            ns.Debug("sync: send failed (" .. tostring(why) .. "), retrying later")
            schedule(math.max(10, Sync.FREQ_GAP[s.freq] or 15))
            return false
        end
        Sync.stats.sent = Sync.stats.sent + 1
    end
    dirty = false
    lastSent = now()
    ns.Log("sync: sent", #entries, "timers in", #msgs, "messages to", channel)
    return true
end

schedule = function(delay)
    if pendingTimer then return end
    pendingTimer = ns.NewTimer("group sync", delay, flush)
end

-- Something changed locally: send once the frequency window allows.
function Sync.MarkDirty()
    if mode() ~= "share" or not Sync.Channel() then return end
    dirty = true
    if pendingTimer then return end
    local gap = Sync.FREQ_GAP[Sync.Settings().freq] or 15
    local wait = math.max(1, lastSent + gap - now())     -- at least 1 s to merge bursts
    schedule(wait)
end

-- Receiving ------------------------------------------------------------------------
local function myName() return shortName(_G.UnitName and UnitName("player")) end

local function reject(why)
    Sync.stats.rejected = Sync.stats.rejected + 1
    ns.Debug("sync: ignored message (" .. why .. ")")
end

local function parseEntries(body, out)
    for item in body:gmatch("[^;]+") do
        if #out >= Sync.MAX_ENTRIES then break end
        local name, sec, kind, rcp = item:match("^([^,]*),(%d+),([vet]),([^,]*)$")
        if name and name ~= "" then
            sec = math.min(tonumber(sec), 86400)
            out[#out + 1] = { name = clean(name, 32), expiresAt = now() + sec, kind = kind, recipient = rcp ~= "" and clean(rcp, 24) or nil }
        end
    end
end

local function changed()
    if ns.Config and ns.Config.RefreshGroup then ns.Config.RefreshGroup() end
    if ns.Minimap and ns.Minimap.Refresh then ns.Minimap.Refresh() end
end

function Sync.OnMessage(prefix, text, channel, sender)
    if mode() == "off" then return end
    if C.IsSecret(prefix) or prefix ~= Sync.PREFIX then return end
    text, sender = C.Str(text), shortName(sender)
    if not (text and sender) then return reject("unreadable") end
    if sender == myName() then return end
    if #text > 255 then return reject("too long") end
    local proto, kind, rest = text:match("^(%d+)%^(%a)%^?(.*)$")
    if proto ~= Sync.PROTOCOL then return reject("unknown protocol") end
    local peer = Sync.peers[sender]
    if not peer then
        local n = 0; for _ in pairs(Sync.peers) do n = n + 1 end
        if n >= Sync.MAX_PEERS then return reject("too many players") end
        peer = { entries = {} }; Sync.peers[sender] = peer
    end
    peer.updated = now()
    Sync.stats.received = Sync.stats.received + 1
    if kind == "H" then
        peer.version = clean(rest, 20)
    elseif kind == "C" then
        peer.entries = {}; incoming[sender] = nil
    elseif kind == "S" then
        local id, part, parts, body = rest:match("^(%d+)%^(%d+)/(%d+)%^(.*)$")
        part, parts = tonumber(part), tonumber(parts)
        if not (id and part and parts and part >= 1 and part <= parts and parts <= 10) then return reject("bad timer message") end
        local inc = incoming[sender]
        if not inc or inc.id ~= id then inc = { id = id, parts = parts, got = {}, count = 0 }; incoming[sender] = inc end
        if not inc.got[part] then
            inc.got[part] = {}; parseEntries(body, inc.got[part]); inc.count = inc.count + 1
        end
        if inc.count >= inc.parts then
            local all = {}
            for i = 1, inc.parts do for _, e in ipairs(inc.got[i] or {}) do if #all < Sync.MAX_ENTRIES then all[#all + 1] = e end end end
            peer.entries = all; incoming[sender] = nil
            -- their own buff times can correct our estimate for copies we cast on them
            if ns.Engine and ns.Engine.OnPeerTimers then ns.Engine:OnPeerTimers(sender, all) end
        end
    else
        return reject("unknown type")
    end
    changed()
end

-- Group members' timers that are still running: { {player, version, entries} }
function Sync.Snapshot()
    local out, t = {}, now()
    for name, p in pairs(Sync.peers) do
        local live = {}
        for _, e in ipairs(p.entries) do if e.expiresAt > t then live[#live + 1] = e end end
        table.sort(live, function(a, b) return a.expiresAt < b.expiresAt end)
        out[#out + 1] = { player = name, version = p.version, entries = live }
    end
    table.sort(out, function(a, b) return a.player < b.player end)
    return out
end

function Sync.PeerCount() local n = 0; for _ in pairs(Sync.peers) do n = n + 1 end; return n end

-- Forget players who left the group (or everyone, when we're solo or sync is off).
local function prune()
    if not Sync.Channel() or mode() == "off" then
        if next(Sync.peers) then Sync.peers = {}; incoming = {}; changed() end
        return
    end
    local inGroup = {}
    local prefix, n = (plainBool(_G.IsInRaid) and "raid" or "party"), (plainBool(_G.IsInRaid) and 40 or 4)
    for i = 1, n do
        local ok, nm = pcall(UnitName, prefix .. i)
        nm = ok and shortName(nm)
        if nm then inGroup[nm] = true end
    end
    local removed = false
    for name in pairs(Sync.peers) do
        if not inGroup[name] then Sync.peers[name] = nil; incoming[name] = nil; removed = true end
    end
    if removed then changed() end
end

-- Settings changed (from the Group tab or a profile switch).
function Sync.OnSettingsChanged()
    if mode() == "off" then Sync.peers = {}; incoming = {} end
    if mode() == "share" and Sync.Channel() then dirty = true; Sync.MarkDirty() end
    if mode() ~= "share" and pendingTimer then pendingTimer:Cancel(); pendingTimer = nil end
    changed()
end

ns.RegisterInit(function()
    local CI = _G.C_ChatInfo
    if CI and CI.RegisterAddonMessagePrefix then pcall(CI.RegisterAddonMessagePrefix, Sync.PREFIX) end
    ns.On("CHAT_MSG_ADDON", function(_, prefix, text, channel, sender) Sync.OnMessage(prefix, text, channel, sender) end)
    ns.On("GROUP_ROSTER_UPDATE", function()
        prune()
        -- Someone joined (or we joined): everyone sends their state once, merged.
        if Sync.Channel() then dirty = true; Sync.MarkDirty() end
    end)
    ns.On("PLAYER_REGEN_ENABLED", function() if dirty then schedule(1) end end)
    ns.On("ENCOUNTER_END", function() if dirty then schedule(2) end end)
end)
