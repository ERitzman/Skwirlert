-- =============================================================================
-- Skwirlert - Announce.lua  (optional chat announcements)
-- =============================================================================
-- WHAT THIS FILE DOES
--   Posts "<buff> applied" and "<buff> expires in Ns" to Say / Party / Raid /
--   Group (auto) when a reminder asks for it.
--   Per reminder: r.announce = "off" | "say" | "party" | "raid" | "group",
--                 r.announceApplied, r.announceWarn (true/false).
--   The warning message is sent from the same timer callback as the popup, so
--   it follows that reminder's warning time exactly.
--
-- WOW CONCEPTS
--   * SendChatMessage(text, chatType). chatType is "SAY", "PARTY", "RAID" or
--     "INSTANCE_CHAT" (newer clients: C_ChatInfo.SendChatMessage).
--   * Outside instances, addons may only /say in response to a click or key
--     press (a "hardware event"); timers and game events don't count. We skip
--     such messages instead of triggering a blocked-action error.
--   * Chat text must not contain "|": it starts UI escape codes (colours, links).
-- =============================================================================

local _, ns = ...
local C = ns.Compat
local A = {}
ns.Announce = A

A.ORDER = { "off", "say", "party", "raid", "group" }
A.LABEL = { off = "Off", say = "Say", party = "Party", raid = "Raid", group = "Group (auto)" }

A.log = {}
-- Keep the last 20 results (sent / skipped / failed) for /skwirlert chatlog.
local function log(entry)
    entry.t = GetTime()
    table.insert(A.log, 1, entry)
    while #A.log > 20 do table.remove(A.log) end
end

-- Next/previous channel setting for the settings window's < > buttons.
function A.Next(cur, dir)
    local idx = 1
    for i, k in ipairs(A.ORDER) do if k == cur then idx = i end end
    idx = ((idx - 1 + (dir or 1)) % #A.ORDER) + 1
    return A.ORDER[idx]
end

-- Call a yes/no game function safely; secret or failed results count as false.
local function plainBool(fn, ...)
    if not fn then return false end
    local ok, v = pcall(fn, ...)
    return ok and C.Bool(v) or false
end

-- In a raid group?
local function inRaid() return plainBool(_G.IsInRaid) end
-- In any group (party or raid)?
local function inGroup() return plainBool(_G.IsInGroup) end
-- In an instance-only group (e.g. dungeon finder) but not a normal party?
local function inInstanceGroupOnly()
    local cat = _G.LE_PARTY_CATEGORY_INSTANCE
    local home = _G.LE_PARTY_CATEGORY_HOME
    if not (cat and home and _G.IsInGroup) then return false end
    return plainBool(IsInGroup, cat) and not plainBool(IsInGroup, home)
end
-- Inside a dungeon/raid/battleground instance?
local function inInstance()
    if not _G.IsInInstance then return false end
    local ok, v = pcall(IsInInstance)
    return ok and C.Bool(v) or false
end

-- Resolve the reminder's setting to a chat type, or nil + reason.
-- fromClick: true when triggered by a button press (hardware event).
function A.Resolve(setting, fromClick)
    if setting == "say" then
        -- Outside instances, SAY needs a hardware event (a click or key press);
        -- timer and spell-event callbacks are not, so skip instead of
        -- triggering a blocked-action error.
        if fromClick or inInstance() then return "SAY" end
        return nil, "Say only works inside instances for automatic alerts"
    elseif setting == "party" then
        if inInstanceGroupOnly() then return "INSTANCE_CHAT" end
        if inGroup() then return "PARTY" end
        return nil, "not in a party"
    elseif setting == "raid" then
        if inRaid() then return inInstanceGroupOnly() and "INSTANCE_CHAT" or "RAID" end
        if inGroup() then return inInstanceGroupOnly() and "INSTANCE_CHAT" or "PARTY" end
        return nil, "not in a group"
    elseif setting == "group" then
        if inInstanceGroupOnly() then return "INSTANCE_CHAT" end
        if inRaid() then return "RAID" end
        if inGroup() then return "PARTY" end
        return nil, "not in a group"
    end
    return nil, "off"
end

-- Chat text must not contain UI escape sequences.
local function clean(s)
    return (tostring(s):gsub("|", "/"))
end

-- Actually send one message. Returns ok, error text.
local function rawSend(msg, chatType)
    local CI = _G.C_ChatInfo
    if CI and CI.InChatMessagingLockdown and plainBool(CI.InChatMessagingLockdown) then
        return false, "chat messaging locked by the client right now"
    end
    local fn = (CI and CI.SendChatMessage) or _G.SendChatMessage
    if not fn then return false, "no SendChatMessage API" end
    local ok, err = pcall(fn, msg, chatType)
    if not ok then return false, tostring(err) end
    return true
end

-- Small queue so several alerts at the same moment go out in order.
local queue, busy = {}, false
-- Send queued messages one at a time, 0.3 s apart, so bursts stay in order.
local function pump()
    if #queue == 0 then busy = false; return end
    busy = true
    local item = table.remove(queue, 1)
    local ok, err = rawSend(item.msg, item.chatType)
    log({ msg = item.msg, chatType = item.chatType, ok = ok, reason = err })
    if not ok then ns.Print("|cffff6060chat announce failed|r (" .. item.chatType .. "): " .. tostring(err)) end
    ns.After("Announce", 0.3, pump)
end

-- Queue a message for a reminder's channel setting. fromClick = true when a
-- button press triggered it (allows Say outside instances). Returns ok, info.
function A.Send(setting, text, fromClick)
    local chatType, why = A.Resolve(setting, fromClick)
    local msg = "[Skwirlert] " .. clean(text)
    if not chatType then
        log({ msg = msg, chatType = setting, ok = false, reason = why, skipped = true })
        ns.Debug("announce skipped:", why)
        return false, why
    end
    table.insert(queue, { msg = msg, chatType = chatType })
    if not busy then pump() end
    return true, chatType
end

-- The recipient's name for targeted buffs, or nil if unknown.
local function who(st)
    local rcp = st and (st.member or st.recipient)   -- member = per-member copy (0.8.0)
    if rcp and rcp ~= "unknown target" then return rcp end
end

-- Called when a cast (or manual start) begins a new cycle.
function A.Applied(r, st)
    if not (r.announce and r.announce ~= "off" and r.announceApplied) then return end
    if ns.Pause and ns.Pause.IsPaused() then ns.Debug("announce suppressed (paused)"); return end
    if not (ns.db.enabled and r.enabled) then return end
    local dur = ns.Engine.fmtTime(st.expires - GetTime())
    local text
    if r.kind == "timer" then
        text = string.format("%s started (%s)", r.name, dur)
    elseif r.kind == "targeted" then
        local name = who(st)
        text = name and string.format("%s applied to %s (%s)", r.name, name, dur)
                    or string.format("%s applied (%s)", r.name, dur)
    else
        text = string.format("%s applied (%s)", r.name, dur)
    end
    A.Send(r.announce, text)
end

-- Called from the warning timer (same moment as the popup).
function A.Warn(r, st, remain)
    if not (r.announce and r.announce ~= "off" and r.announceWarn) then return end
    if ns.Pause and ns.Pause.IsPaused() then ns.Debug("announce suppressed (paused)"); return end
    local name = who(st)
    local subject = (r.kind == "targeted" and name) and (r.name .. " on " .. name) or r.name
    local text = string.format("%s expires in %s", subject, ns.Engine.fmtTime(remain))
    if st.source ~= "verified" then text = text .. " (est.)" end
    A.Send(r.announce, text)
end
