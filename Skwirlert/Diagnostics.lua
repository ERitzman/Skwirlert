-- =============================================================================
-- Skwirlert - Diagnostics.lua  (Diagnostics mode and bug reports)
-- =============================================================================
-- WHAT THIS FILE DOES
--   * Error capture is ALWAYS on (see Core.lua). It costs nothing until
--     something breaks and keeps at most 25 errors in SkwirlertDB.errors.
--   * Diagnostics mode (SkwirlertDB.diagnostics, off by default) also records
--     an activity log: the last 200 lines of casts, timers, alerts, sounds and
--     chat results.
--   * BuildReport() gathers everything a developer needs into plain text, and
--     ShowReport() opens a window where the player can Ctrl+A, Ctrl+C it.
--
-- WOW CONCEPTS
--   * A multi-line EditBox inside a ScrollFrame (UIPanelScrollFrameTemplate)
--     is the usual way to give players copyable text.
--   * GetBuildInfo() returns the client version, build, date and interface
--     number.
-- =============================================================================

local _, ns = ...
local CreateFrame = ns.SafeFrameFactory("BugReport")
local Diag = {}
ns.Diag = Diag

-- Is Diagnostics mode on?
function Diag.Enabled() return ns.sv and ns.sv.diagnostics and true or false end

-- Turn Diagnostics mode on/off (off also clears the activity log).
function Diag.SetEnabled(v)
    if not ns.sv then return end
    ns.sv.diagnostics = v and true or false
    if not v then wipe(ns.log) end
    ns.Print(v and "diagnostics mode ON: recording activity. Reproduce the problem, then click Bug report (or /skwirlert report)."
               or "diagnostics mode off (activity log cleared; errors are still captured).")
    if ns.Config and ns.Config.Refresh then ns.Config.Refresh() end
end

-- Saved error list (or the in-memory one if start-up failed).
local function errorsList() return (ns.sv and ns.sv.errors) or ns.errors end

-- Forget all captured errors (/skwirlert errors clear, Clear errors button).
function Diag.ClearErrors()
    wipe(errorsList())
    ns.lastError = nil
end

-- Remove colour codes and "|" so the report is clean text.
local function plain(s)
    s = tostring(s or "")
    s = s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|", "/")
    return s
end

-- Build the full bug report text: versions, character/profile, reminders,
-- missing APIs, sound settings, errors with stack traces, activity log.
function Diag.BuildReport()
    local L = {}
    local function add(...) L[#L + 1] = plain(table.concat({ ... }, "")) end
    local version, build, bdate, iface = "?", "?", "?", "?"
    if _G.GetBuildInfo then version, build, bdate, iface = GetBuildInfo() end
    add("=== Skwirlert bug report ===")
    add("Addon: Skwirlert ", ns.version, "   Report time: ", (_G.date and date("%Y-%m-%d %H:%M:%S")) or "?")
    add("Client: ", tostring(version), " build ", tostring(build), " (", tostring(bdate), ")  Interface ", tostring(iface))
    add("Locale: ", (_G.GetLocale and GetLocale()) or "?")
    if ns.db then
        add("Character: ", tostring(ns.charName), " on '", tostring(ns.realmName), "'   Profile: ", tostring(ns.profileName),
            "   Reminders: ", #ns.db.reminders, "   Addon enabled: ", tostring(ns.db.enabled),
            "   Sound channel: ", tostring(ns.db.channel))
    else
        add("Saved settings NOT loaded (startup failed).")
    end
    add("In combat: ", tostring(ns.Compat and ns.Compat.InCombat()), "   Diagnostics mode: ", tostring(Diag.Enabled()))
    if ns.Sounds and ns.Sounds.ReadSettings then
        local parts = {}
        for _, c in ipairs(ns.Sounds.ReadSettings()) do parts[#parts + 1] = c.cvar .. "=" .. tostring(c.value) end
        add("Game sound settings (read-only): ", table.concat(parts, "  "))
        local problem = ns.Sounds.SettingsProblem()
        if problem then add("SOUND WARNING: ", problem) end
    end

    -- Reminder summary (no personal data beyond spell names)
    if ns.db and #ns.db.reminders > 0 then
        add("")
        add("--- Reminders ---")
        for _, r in ipairs(ns.db.reminders) do
            local st = ns.Engine and ns.Engine:State(r.id)
            local ids = {}
            for _, id in ipairs(r.spellIDs) do ids[#ids + 1] = tostring(id) end
            for _, id in ipairs(r.learnedIDs) do ids[#ids + 1] = tostring(id) .. "*" end
            add(string.format("#%d %s [%s%s] ids=%s names=%s dur=%s%s warn=%d %s",
                r.id, r.name, r.kind, r.enabled and "" or ",off", table.concat(ids, ","),
                table.concat(r.names, "/"), tostring(r.duration),
                r.learnedDuration and ("(aura " .. tostring(r.learnedDuration) .. ")") or "", r.warn,
                st and string.format("RUNNING %s %.0fs left", st.source, st.expires - GetTime()) or "idle"))
            if r.perMember then
                local m = ns.Engine:Members(r.id)
                add(string.format("    per-member: on, %d running copies", #m))
            end
        end
    end

    -- Missing APIs
    if ns.Compat then
        local missing = {}
        for _, p in ipairs(ns.Compat.Probe()) do if not p[2] then missing[#missing + 1] = p[1] end end
        add("")
        add("--- Missing APIs ---")
        add(#missing > 0 and table.concat(missing, ", ") or "(none)")
    end

    -- Errors
    local errs = errorsList()
    add("")
    add("--- Errors (", #errs, ") ---")
    if #errs == 0 then add("(no errors captured)") end
    for i, e in ipairs(errs) do
        add(string.format("[%d] %s  x%d  at %s  (v%s, profile %s, combat %s)", i, e.where or "?", e.count or 1,
            e.date or "?", tostring(e.version), tostring(e.profile), tostring(e.combat)))
        add("    message: ", e.msg or "?")
        if e.context and e.context ~= "" then add("    args: ", e.context) end
        if e.stack and e.stack ~= "" then
            for line in tostring(e.stack):gmatch("[^\n]+") do add("    ", line) end
        end
    end

    -- Activity log
    add("")
    if Diag.Enabled() then
        add("--- Activity log (last ", #ns.log, " lines) ---")
        for _, l in ipairs(ns.log) do add(l) end
    else
        add("--- Activity log: diagnostics mode was off. Turn it on, reproduce the problem, and make a new report. ---")
    end
    if ns.Sounds and #ns.Sounds.log > 0 then
        add("")
        add("--- Recent sounds ---")
        for i = 1, math.min(8, #ns.Sounds.log) do
            local e = ns.Sounds.log[i]
            add(e.key, "  ", e.ok and "accepted" or ("FAILED: " .. tostring(e.reason)), "  ", tostring(e.path))
        end
    end
    if ns.Announce and #ns.Announce.log > 0 then
        add("")
        add("--- Recent chat announcements ---")
        for i = 1, math.min(8, #ns.Announce.log) do
            local e = ns.Announce.log[i]
            add(tostring(e.chatType), "  ", e.ok and "sent" or ("not sent: " .. tostring(e.reason)), "  ", tostring(e.msg))
        end
    end
    add("=== end of report ===")
    return table.concat(L, "\n")
end

-- Report window ------------------------------------------------------------------
local win, box

-- Build the report window once (scrolling copy box + buttons).
local function buildWindow()
    win = CreateFrame("Frame", "SkwirlertReport", UIParent, _G.BackdropTemplateMixin and "BackdropTemplate" or nil)
    win:SetSize(620, 440)
    win:SetPoint("CENTER")
    win:SetFrameStrata("FULLSCREEN_DIALOG")
    win:SetMovable(true); win:EnableMouse(true); win:RegisterForDrag("LeftButton")
    win:SetScript("OnDragStart", win.StartMoving)
    win:SetScript("OnDragStop", win.StopMovingOrSizing)
    if win.SetBackdrop then
        win:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            edgeSize = 14, insets = { left = 3, right = 3, top = 3, bottom = 3 } })
        win:SetBackdropColor(0.04, 0.04, 0.06, 1)
        win:SetBackdropBorderColor(1, 0.82, 0, 1)
    end
    tinsert(UISpecialFrames, "SkwirlertReport")
    local t = win:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    t:SetPoint("TOPLEFT", 14, -12); t:SetText("Skwirlert bug report")
    local h = win:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    h:SetPoint("TOPLEFT", 14, -34); h:SetWidth(590); h:SetJustifyH("LEFT")
    h:SetText("Click in the box, press Ctrl+A then Ctrl+C, and paste it into your ticket or message.")

    -- Multi-line box in a scroll frame; falls back to a single-line box if the template is missing.
    local ok, scroll = pcall(CreateFrame, "ScrollFrame", "SkwirlertReportScroll", win, "UIPanelScrollFrameTemplate")
    box = CreateFrame("EditBox", nil, ok and scroll or win)
    box:SetMultiLine(true)
    box:SetAutoFocus(false)
    box:SetFontObject("ChatFontNormal")
    box:SetWidth(560)
    box:SetMaxLetters(0)
    box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    box:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
    if ok and scroll then
        scroll:SetPoint("TOPLEFT", 14, -54)
        scroll:SetPoint("BOTTOMRIGHT", -34, 46)
        scroll:SetScrollChild(box)
    else
        box:SetPoint("TOPLEFT", 14, -54)
        box:SetPoint("BOTTOMRIGHT", -14, 46)
    end

    local function btn(text, w, x, fn)
        local b = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
        b:SetSize(w, 22); b:SetPoint("BOTTOMLEFT", x, 14); b:SetText(text)
        b:SetScript("OnClick", fn)
        return b
    end
    btn("Select all", 90, 14, function() box:SetFocus(); box:HighlightText() end)
    btn("Refresh", 80, 108, function() Diag.ShowReport() end)
    btn("Clear errors", 100, 192, function() Diag.ClearErrors(); Diag.ShowReport() end)
    win.diagBtn = btn("", 170, 296, function() Diag.SetEnabled(not Diag.Enabled()); Diag.ShowReport() end)
    btn("Close", 80, 526, function() win:Hide() end)
    win:Hide()
end

-- Fill the report window with a fresh report and select all the text.
function Diag.ShowReport()
    if not win then buildWindow() end
    box:SetText(Diag.BuildReport())
    win.diagBtn:SetText(Diag.Enabled() and "Turn diagnostics off" or "Turn diagnostics on")
    win:Show()
    box:SetFocus()
    box:HighlightText()
end

-- The report window and its text box (used by tests).
function Diag.Window() return win, box end
