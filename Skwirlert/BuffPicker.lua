-- =============================================================================
-- Skwirlert - BuffPicker.lua  ("Add from my buffs")
-- =============================================================================
-- WHAT THIS FILE DOES
--   Lists the buffs currently on the player (icon, name, spell ID, duration,
--   time left). Clicking one creates a "Buff on me" reminder with the ID, name
--   and real duration filled in, and starts tracking it immediately. Buffs
--   already tracked are marked; permanent buffs (no timer) can't be added.
--   This is the main way players add reminders: nothing is hardcoded.
--   0.8.0: the same panel also lists "My recent casts" (spells you cast,
--   with their target) so buffs you put on OTHER players can be added
--   without knowing a spell ID.
--
-- REFRESH NOISE CONTROL (0.8.0)
--   Refresh only auto-adds buffs lasting at least <profile>.refresh.minDuration
--   (default 5m), so short, constantly recast buffs (e.g. a 2-minute shout)
--   don't flood the list. Buffs whose reminder you DELETE are remembered in
--   <profile>.refresh.ignored and are not re-added by Refresh. Adding one by
--   hand ("Add from my buffs") always works and un-ignores it.
--
-- WOW CONCEPTS
--   * Buff data comes from Compat.ListPlayerBuffs (C_UnitAuras underneath).
--   * The list refreshes itself on UNIT_AURA while open (batched).
-- =============================================================================

local _, ns = ...
local CreateFrame = ns.SafeFrameFactory("BuffPicker")  -- wraps script handlers with error capture
local C = ns.Compat
local Picker = {}
ns.Picker = Picker

local ROWS, ROW_H = 16, 24
local BACKDROP = _G.BackdropTemplateMixin and "BackdropTemplate" or nil
local frame, rows, msg, offset, buffs = nil, {}, nil, 0, {}
local mode, title = "buffs", nil     -- "buffs" (Add from my buffs) or "casts" (My recent casts)

-- Is this buff already covered by an existing reminder? Returns that reminder.
function Picker.FindTracking(a)
    for _, r in ipairs(ns.db.reminders) do
        if a.spellId then
            for _, id in ipairs(r.spellIDs) do if id == a.spellId then return r end end
            for _, id in ipairs(r.learnedIDs) do if id == a.spellId then return r end end
        end
        if a.name then
            local n = a.name:lower()
            for _, nm in ipairs(r.names) do
                if type(nm) == "string" and nm:lower() == n then return r end
            end
        end
    end
end

-- Ignore list ----------------------------------------------------------------
local function ignoredSet()
    local rf = ns.db and ns.db.refresh
    return rf and rf.ignored or {}
end
local function keysOf(ids, names, out)
    for _, id in ipairs(ids or {}) do out[#out + 1] = "id:" .. tostring(id) end
    for _, n in ipairs(names or {}) do if type(n) == "string" then out[#out + 1] = "name:" .. n:lower() end end
    return out
end
-- Remember a deleted reminder's buff so Refresh won't add it back.
function Picker.Ignore(r)
    if not (r and ns.db and ns.db.refresh) or r.kind ~= "self" then return end
    local set = ns.db.refresh.ignored
    local n = 0
    for _ in pairs(set) do n = n + 1 end
    for _, k in ipairs(keysOf(r.learnedIDs, r.names, keysOf(r.spellIDs, nil, {}))) do
        if not set[k] then
            if n >= 200 then break end   -- keep the list bounded (it lives in SavedVariables)
            set[k] = true; n = n + 1
        end
    end
end
-- Is this buff record on the ignore list?
function Picker.IsIgnored(a)
    local set = ignoredSet()
    if a.spellId and set["id:" .. tostring(a.spellId)] then return true end
    if a.name and set["name:" .. a.name:lower()] then return true end
    return false
end
local function unignore(a)
    local set = ignoredSet()
    if a.spellId then set["id:" .. tostring(a.spellId)] = nil end
    if a.name then set["name:" .. a.name:lower()] = nil end
end
-- Clear the ignore list ('/skwirlert refresh forget'). Returns how many were cleared.
function Picker.ForgetIgnored()
    local set, n = ignoredSet(), 0
    for k in pairs(set) do set[k] = nil; n = n + 1 end
    return n
end
-- Minimum duration (seconds) for Refresh to auto-add a buff.
function Picker.MinDuration()
    return (ns.db and ns.db.refresh and ns.db.refresh.minDuration) or 300
end

-- Create a reminder from a buff record. Returns reminder or nil + reason.
function Picker.AddFromBuff(a)
    local existing = Picker.FindTracking(a)
    if existing then return existing, "already tracked" end
    local dur = a.duration
    if not dur or dur <= 0 then
        return nil, (a.name or "that buff") .. " has no duration (permanent or hidden), so there is nothing to time"
    end
    dur = math.floor(dur + 0.5)
    local warn = dur > 60 and 30 or math.max(0, math.floor(dur / 3))
    local r, err = ns.AddReminder({
        name = a.name or ("Spell " .. tostring(a.spellId)),
        kind = "self",
        spellIDs = a.spellId and { a.spellId } or {},
        names = a.name and { a.name } or {},
        duration = dur, warn = warn,
        warnSound = "quick-tone", expireSound = "Uh Oh",
    })
    if not r then return nil, err end
    unignore(a)
    ns.Engine:VerifySelf(r)   -- the buff is on you now: start tracking immediately
    return r
end

-- Recent casts ----------------------------------------------------------------
-- Unique spells from the engine's recent-cast list (newest first), each with
-- the last target it was cast on.
function Picker.RecentCasts()
    local out, seen = {}, {}
    for _, c in ipairs(ns.Engine.recentCasts) do
        if c.id and not seen[c.id] then
            seen[c.id] = true
            out[#out + 1] = c
        end
    end
    return out
end

-- Create a reminder from a recent cast. Cast on someone else -> "Buff I cast
-- on others"; on yourself / no target -> "Buff on me". The duration is read
-- from the buff if it's visible now, otherwise 30m until the first real read.
function Picker.AddFromCast(c)
    local me = C.PlayerName()
    local onOther = c.target and me and c.target:gsub("%-.*$", ""):lower() ~= me:lower()
    local a = { spellId = c.id, name = (c.name ~= "?" and c.name) or nil }
    local existing = Picker.FindTracking(a)
    if existing then return existing, "already tracked" end
    local probe = { spellIDs = { c.id }, names = a.name and { a.name } or {}, learnedIDs = {} }
    local unit = onOther and C.UnitByName(c.target) or "player"
    local dur
    if unit then
        local status, aura = C.FindUnitBuff(unit, probe)
        if status == "present" and aura.duration and aura.duration > 0 then dur = math.floor(aura.duration + 0.5) end
    end
    local r, err = ns.AddReminder({
        name = a.name or ("Spell " .. tostring(c.id)),
        kind = onOther and "targeted" or "self",
        spellIDs = { c.id }, names = a.name and { a.name } or {},
        duration = dur or 1800, warn = (dur and dur <= 60) and math.floor(dur / 3) or 30,
        warnSound = "quick-tone", expireSound = "Uh Oh",
    })
    if not r then return nil, err end
    unignore(a)
    if not dur then ns.Print(r.name .. ": duration set to 30m for now; it is corrected when the buff is first read.") end
    return r
end

-- Draw the visible rows (16 at a time; the mouse wheel scrolls).
-- Refresh and Monitor (/skwirlert refresh, Shift+click on the minimap button).
-- Scans the player's readable buffs (any caster), adds every new timed buff as
-- a "Buff on me" reminder, never duplicates (same spell ID / learned ID / name
-- as an existing reminder, enabled or not), then re-reads real expirations
-- for running timers and opens the settings window. Existing reminders keep
-- all their settings. Does not resume a pause. Returns a summary table.
function Picker.RefreshAll(openWindow)
    local res = { added = 0, tracked = 0, permanent = 0, full = 0, short = 0, ignored = 0, hidden = false }
    local minDur = Picker.MinDuration()
    if not ns.db then return res end
    local list, hidden = C.ListPlayerBuffs()
    res.hidden = hidden
    for _, a in ipairs(list) do
        if Picker.FindTracking(a) then
            res.tracked = res.tracked + 1
        elseif not (a.duration and a.duration > 0) then
            res.permanent = res.permanent + 1
        elseif Picker.IsIgnored(a) then
            res.ignored = res.ignored + 1
        elseif a.duration < minDur then
            res.short = res.short + 1
        elseif #ns.db.reminders >= ns.MAX_REMINDERS then
            res.full = res.full + 1
        else
            local r = Picker.AddFromBuff(a)
            if r then res.added = res.added + 1 end
        end
    end
    ns.Engine:VerifyAll()                       -- refresh running timers from real aura data
    local parts = { string.format("refresh: %d new, %d already tracked", res.added, res.tracked) }
    if res.permanent > 0 then parts[#parts + 1] = res.permanent .. " permanent (no timer) skipped" end
    if res.short > 0 then parts[#parts + 1] = res.short .. " shorter than " .. ns.FormatDuration(minDur) .. " skipped" end
    if res.ignored > 0 then parts[#parts + 1] = res.ignored .. " you deleted before skipped" end
    if res.full > 0 then parts[#parts + 1] = res.full .. " not added (" .. ns.MAX_REMINDERS .. "-reminder limit)" end
    if res.hidden then parts[#parts + 1] = "some buffs are hidden right now (combat) and were skipped" end
    if ns.Pause and ns.Pause.IsPaused() then parts[#parts + 1] = "monitoring is still paused" end
    ns.Print(table.concat(parts, "; ") .. ".")
    ns.Log("refresh", res.added, res.tracked, res.permanent, res.short, res.ignored, res.full, tostring(res.hidden))
    if openWindow ~= false and ns.Config then
        local _, win = ns.Config.Widgets()
        if not (win and win:IsShown()) then ns.Config.Toggle() end
        ns.Config.ShowTab("reminders")
    end
    return res
end

local function render()
    if not (frame and frame:IsShown()) then return end
    local maxOff = math.max(0, #buffs - ROWS)
    if offset > maxOff then offset = maxOff end
    for i, row in ipairs(rows) do
        local a = buffs[i + offset]
        if a and mode == "casts" then
            row.buff, row.cast = nil, a
            row.icon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
            row.name:SetText(a.name or "?")
            local detail = "ID " .. tostring(a.id)
            if a.target then detail = detail .. " - on " .. a.target:gsub("%-.*$", "") end
            detail = detail .. " - " .. ns.Engine.fmtTime(GetTime() - a.t) .. " ago"
            row.detail:SetText(detail)
            local tracked = Picker.FindTracking({ spellId = a.id, name = a.name ~= "?" and a.name or nil })
            row.tag:SetText(tracked and "|cff40ff40tracked|r" or "")
            row:Show()
        elseif a then
            row.buff, row.cast = a, nil
            row.icon:SetTexture(a.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
            local tracked = Picker.FindTracking(a)
            local timed = a.duration and a.duration > 0
            row.name:SetText((timed and "" or "|cff888888") .. (a.name or "?") .. "|r")
            local detail = "ID " .. (a.spellId and tostring(a.spellId) or "?")
            if timed then
                detail = detail .. " - " .. ns.Engine.fmtTime(a.duration)
                if a.expires and a.expires > 0 then
                    detail = detail .. " (" .. ns.Engine.fmtTime(a.expires - GetTime()) .. " left)"
                end
            else
                detail = detail .. " - no timer"
            end
            row.detail:SetText(detail)
            row.tag:SetText(tracked and "|cff40ff40tracked|r" or "")
            row:Show()
        else
            row.buff, row.cast = nil, nil
            row:Hide()
        end
    end
end

-- Re-read the player's buffs and redraw, with a hint if data is hidden (combat).
function Picker.Refresh()
    if not (frame and frame:IsShown()) then return end
    if mode == "casts" then
        title:SetText("My recent casts")
        buffs = Picker.RecentCasts()
        if #buffs == 0 then
            msg:SetText("No casts yet this session. Cast the spell (on yourself or a groupmate), then press Refresh.")
        else
            msg:SetText("Click a spell to add it. Cast on someone else = \"Buff I cast on others\". No spell ID needed.")
        end
        render()
        return
    end
    title:SetText("Buffs on you now")
    local list, hidden = C.ListPlayerBuffs()
    buffs = list
    if #list == 0 and hidden then
        msg:SetText("|cffff8080Buff data is hidden right now (usually in combat). Try again out of combat.|r")
    elseif #list == 0 then
        msg:SetText("No buffs on you right now. Get buffed, then press Refresh.")
    elseif hidden then
        msg:SetText("Some buffs are hidden right now (combat). Showing the readable ones.")
    else
        msg:SetText("Click a buff to add it. Grey = permanent (nothing to time).")
    end
    render()
end

-- Build the picker panel on top of the editor area (once).
local function build(parent)
    frame = CreateFrame("Frame", "SkwirlertBuffPicker", parent, BACKDROP)
    frame:SetSize(430, 476)
    frame:SetPoint("TOPLEFT", parent, "TOPLEFT", 220, -34)
    frame:SetFrameLevel((parent:GetFrameLevel() or 1) + 20)
    frame:EnableMouse(true)
    if frame.SetBackdrop then
        frame:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1,
        })
        frame:SetBackdropColor(0.04, 0.04, 0.06, 1)
        frame:SetBackdropBorderColor(1, 0.82, 0, 0.8)
    end
    title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", 10, -8)
    title:SetText("Buffs on you now")
    msg = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    msg:SetPoint("TOPLEFT", 10, -26)
    msg:SetWidth(410); msg:SetJustifyH("LEFT")

    frame:EnableMouseWheel(true)
    frame:SetScript("OnMouseWheel", function(_, delta)
        offset = math.max(0, offset - delta)
        render()
    end)
    for i = 1, ROWS do
        local b = CreateFrame("Button", nil, frame)
        b:SetSize(410, ROW_H - 2)
        b:SetPoint("TOPLEFT", 10, -44 - (i - 1) * ROW_H)
        b.icon = b:CreateTexture(nil, "ARTWORK")
        b.icon:SetSize(20, 20); b.icon:SetPoint("LEFT", 0, 0)
        b.name = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightLeft")
        b.name:SetPoint("LEFT", b.icon, "RIGHT", 6, 0); b.name:SetWidth(150)
        b.tag = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        b.tag:SetPoint("RIGHT", b, "RIGHT", -2, 0); b.tag:SetWidth(50); b.tag:SetJustifyH("RIGHT")
        b.detail = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmallLeft")
        b.detail:SetPoint("LEFT", b.name, "RIGHT", 4, 0); b.detail:SetPoint("RIGHT", b.tag, "LEFT", -4, 0)
        if b.detail.SetWordWrap then b.detail:SetWordWrap(false) end
        b.hl = b:CreateTexture(nil, "BACKGROUND")
        b.hl:SetAllPoints(); b.hl:SetColorTexture(1, 0.82, 0, 0.18); b.hl:Hide()
        b:SetScript("OnEnter", function(self) self.hl:Show() end)
        b:SetScript("OnLeave", function(self) self.hl:Hide() end)
        b:SetScript("OnClick", function(self)
            if not (self.buff or self.cast) then return end
            local r, why
            if self.cast then r, why = Picker.AddFromCast(self.cast) else r, why = Picker.AddFromBuff(self.buff) end
            if r and why then
                ns.Print(r.name .. " is already tracked")
            elseif r then
                ns.Print(string.format("now tracking %s (ID %s, %s). %d/%d reminders.", r.name,
                    r.spellIDs[1] and tostring(r.spellIDs[1]) or "?", ns.Engine.fmtTime(r.duration),
                    ns.CountReminders(), ns.MAX_REMINDERS))
            else
                ns.Print(why); return
            end
            frame:Hide()
            ns.Config.Select(r.id)
        end)
        rows[i] = b
    end
    local close = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    close:SetSize(80, 22); close:SetPoint("BOTTOMRIGHT", -10, 10); close:SetText("Close")
    close:SetScript("OnClick", function() frame:Hide() end)
    local refresh = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    refresh:SetSize(80, 22); refresh:SetPoint("RIGHT", close, "LEFT", -6, 0); refresh:SetText("Refresh")
    refresh:SetScript("OnClick", function() Picker.Refresh() end)
    frame:SetScript("OnShow", function() offset = 0; Picker.Refresh() end)
    frame:Hide()
end

-- Open/close the picker. which = "buffs" (default, "Add from my buffs") or
-- "casts" ("My recent casts"). Asking for the other list switches to it.
function Picker.Toggle(parent, which)
    which = which or "buffs"
    if not frame then build(parent) end
    if frame:IsShown() and mode == which then frame:Hide(); return end
    mode = which
    if frame:IsShown() then offset = 0; Picker.Refresh() else frame:Show() end
end
function Picker.Mode() return mode end
-- Close the picker (tab switch, window close, profile change).
function Picker.Hide() if frame then frame:Hide() end end
-- The picker frame and its rows (used by tests).
function Picker.Frame() return frame, rows end

-- Keep the list current while it is open (coalesced).
local queued = false
ns.RegisterInit(function()
    ns.On("UNIT_AURA", function(_, unit)
        if C.IsSecret(unit) or unit ~= "player" then return end
        if not (frame and frame:IsShown()) or queued then return end
        queued = true
        ns.After("BuffPicker", 0.3, function() queued = false; Picker.Refresh() end)
    end)
end)
