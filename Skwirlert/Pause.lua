-- =============================================================================
-- Skwirlert - Pause.lua  (Pause Monitoring)
-- =============================================================================
-- WHAT THIS FILE DOES
--   Lets the player silence Skwirlert for a while without turning anything off:
--     * Timed pause (default 30 minutes; quick 5/15/30/60; any 1-1440 minutes).
--     * "Pause while grouped": silent while in a party or raid, resumes on
--       leaving the group.
--   While paused, warning and expiration popups, sounds and automatic chat
--   announcements are suppressed. Everything else keeps running: aura tracking,
--   timers, and recasts resetting timers. Alerts that fall inside the pause are
--   simply dropped, never queued, so nothing old fires after resuming.
--
-- SAVED DATA
--   SkwirlertDB.chars[<character>].pause = { untilEpoch = <time()>, grouped = true }
--   Stored per character, using time() (wall-clock seconds), so the pause
--   survives /reload, relog and a full client restart.
--
-- WOW CONCEPTS
--   * time() = wall-clock seconds (unlike GetTime(), which is uptime).
--   * GROUP_ROSTER_UPDATE fires when the party/raid changes; IsInGroup() tells
--     whether we are still in one.
-- =============================================================================

local _, ns = ...
local CreateFrame = ns.SafeFrameFactory("PauseDialog")   -- wraps script handlers with error capture
local C = ns.Compat
local Pause = {}
ns.Pause = Pause

Pause.DEFAULT_MINUTES = 30
Pause.QUICK = { 5, 15, 30, 60 }
local resumeTimer

local function wallclock() return (_G.time and time()) or 0 end
local function state() return ns.char and ns.char.pause end

-- In a party or raid? (secret-safe)
local function inGroup()
    if not _G.IsInGroup then return false end
    local ok, v = pcall(IsInGroup)
    return ok and C.Bool(v) or false
end

-- Is monitoring paused right now?
function Pause.IsPaused()
    local p = state()
    if not p then return false end
    if p.untilEpoch and wallclock() < p.untilEpoch then return true end
    if p.grouped and inGroup() then return true end
    return false
end

-- Seconds left on a timed pause (or nil).
function Pause.Remaining()
    local p = state()
    if p and p.untilEpoch then
        local left = p.untilEpoch - wallclock()
        if left > 0 then return left end
    end
    return nil
end

-- One-line description for the tooltip, /skwirlert status and the dialog.
function Pause.Describe()
    if not Pause.IsPaused() then return "Monitoring active" end
    local left = Pause.Remaining()
    if left then return "Paused for " .. ns.FormatDuration(left) .. " more" end
    return "Paused while in a group"
end

local function refreshUI()
    if ns.Minimap and ns.Minimap.Refresh then ns.Minimap.Refresh() end
    if Pause.RefreshDialog then Pause.RefreshDialog() end
end

local function cancelTimer()
    if resumeTimer then resumeTimer:Cancel(); resumeTimer = nil end
end

-- Resume immediately (also used when a timed pause runs out).
function Pause.Resume(silent)
    local was = Pause.IsPaused() or state() ~= nil
    cancelTimer()
    if ns.char then ns.char.pause = nil end
    ns.Log("pause: resumed")
    if was and not silent then ns.Print("monitoring resumed") end
    refreshUI()
end

local function schedule()
    cancelTimer()
    local left = Pause.Remaining()
    if left then
        resumeTimer = ns.NewTimer("pause end", left, function()
            resumeTimer = nil
            local p = state()
            if p and p.untilEpoch and wallclock() >= p.untilEpoch - 1 then
                Pause.Resume()
            end
        end)
    end
end

-- Pause for a number of minutes (1-1440). Returns true, or false + message.
function Pause.Start(minutes)
    minutes = math.floor((tonumber(minutes) or Pause.DEFAULT_MINUTES) + 0.5)
    if minutes < 1 then return false, "pause must be at least 1 minute" end
    if minutes > 1440 then minutes = 1440 end
    if not ns.char then return false, "Skwirlert isn't ready yet" end
    ns.char.pause = { untilEpoch = wallclock() + minutes * 60 }
    schedule()
    ns.Log("pause: timed", minutes, "min")
    ns.Print(string.format("monitoring paused for %s (alerts, sounds and chat announcements are silent; timers keep running). /skwirlert resume to resume now.",
        ns.FormatDuration(minutes * 60)))
    refreshUI()
    return true
end

-- Pause while in a party or raid; resumes automatically when leaving the group.
function Pause.StartGrouped()
    if not ns.char then return false, "Skwirlert isn't ready yet" end
    if not inGroup() then return false, "you're not in a party or raid" end
    cancelTimer()
    ns.char.pause = { grouped = true }
    ns.Log("pause: while grouped")
    ns.Print("monitoring paused while you're in a group. It resumes when you leave the party or raid.")
    refreshUI()
    return true
end

-- Dialog ----------------------------------------------------------------------
local dlg

local function buildDialog()
    dlg = CreateFrame("Frame", "SkwirlertPauseDialog", UIParent, _G.BackdropTemplateMixin and "BackdropTemplate" or nil)
    dlg:SetSize(330, 200)
    dlg:SetPoint("CENTER", 0, 120)
    dlg:SetFrameStrata("DIALOG")
    dlg:SetMovable(true); dlg:EnableMouse(true); dlg:RegisterForDrag("LeftButton")
    dlg:SetScript("OnDragStart", dlg.StartMoving)
    dlg:SetScript("OnDragStop", dlg.StopMovingOrSizing)
    if dlg.SetBackdrop then
        dlg:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            edgeSize = 14, insets = { left = 3, right = 3, top = 3, bottom = 3 } })
        dlg:SetBackdropColor(0.05, 0.05, 0.07, 0.97)
        dlg:SetBackdropBorderColor(1, 0.82, 0, 1)
    end
    tinsert(UISpecialFrames, "SkwirlertPauseDialog")   -- Escape closes it
    local icon = dlg:CreateTexture(nil, "ARTWORK")
    icon:SetSize(22, 22); icon:SetPoint("TOPLEFT", 12, -10); icon:SetTexture(ns.ICON)
    local title = dlg:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 40, -13); title:SetText("Pause monitoring")
    local close = CreateFrame("Button", nil, dlg, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -2, -2)
    dlg.status = dlg:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    dlg.status:SetPoint("TOPLEFT", 14, -42)
    local hint = dlg:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("TOPLEFT", 14, -60); hint:SetWidth(300); hint:SetJustifyH("LEFT")
    hint:SetText("Silences alerts, sounds and chat announcements. Timers keep running; nothing is replayed later.")

    local function btn(text, w, x, y, fn)
        local b = CreateFrame("Button", nil, dlg, "UIPanelButtonTemplate")
        b:SetSize(w, 22); b:SetPoint("TOPLEFT", x, y); b:SetText(text); b:SetScript("OnClick", fn)
        return b
    end
    dlg.quick = {}
    for i, m in ipairs(Pause.QUICK) do
        dlg.quick[i] = btn(m .. " min", 70, 14 + (i - 1) * 76, -90, function() Pause.Start(m) end)
    end
    local lbl = dlg:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    lbl:SetPoint("TOPLEFT", 14, -126); lbl:SetText("Minutes:")
    dlg.minutes = CreateFrame("EditBox", nil, dlg, "InputBoxTemplate")
    dlg.minutes:SetSize(50, 20); dlg.minutes:SetPoint("TOPLEFT", 80, -122)
    dlg.minutes:SetAutoFocus(false); dlg.minutes:SetNumeric(true); dlg.minutes:SetMaxLetters(4)
    dlg.minutes:SetText(tostring(Pause.DEFAULT_MINUTES))
    local function startTyped()
        local ok, err = Pause.Start(dlg.minutes:GetText())
        if not ok then ns.Print("|cffff6060" .. err .. "|r") end
        dlg.minutes:ClearFocus()
    end
    dlg.minutes:SetScript("OnEnterPressed", startTyped)
    dlg.minutes:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    dlg.pauseBtn = btn("Pause", 70, 140, -122, startTyped)
    dlg.groupBtn = btn("Pause while grouped", 150, 14, -156, function()
        local ok, err = Pause.StartGrouped()
        if not ok then ns.Print("|cffff6060" .. err .. "|r") end
    end)
    dlg.resumeBtn = btn("Resume now", 100, 172, -156, function() Pause.Resume() end)
    dlg:SetScript("OnShow", function() Pause.RefreshDialog() end)
    dlg:Hide()
end

function Pause.RefreshDialog()
    if not (dlg and dlg:IsShown()) then return end
    dlg.status:SetText((Pause.IsPaused() and "|cffffd100" or "|cff40ff40") .. Pause.Describe() .. "|r")
    if dlg.resumeBtn.SetEnabled then dlg.resumeBtn:SetEnabled(Pause.IsPaused()) end
end

function Pause.ShowDialog()
    if not dlg then buildDialog() end
    dlg:Show()
    Pause.RefreshDialog()
end

function Pause.Dialog() return dlg end

-- Start-up and group changes ------------------------------------------------------
ns.RegisterInit(function()
    local p = state()
    if p then
        if p.untilEpoch and wallclock() >= p.untilEpoch then
            ns.char.pause = nil                       -- expired while logged out / before reload
        elseif p.untilEpoch then
            schedule()                                -- resume on time after /reload or relog
        end
    end
    -- Group data can be empty for a moment at login, so a saved "while grouped"
    -- pause is only re-checked a few seconds after entering the world.
    ns.On("PLAYER_ENTERING_WORLD", function()
        ns.After("pause group check", 5, function()
            local s = state()
            if s and s.grouped and not inGroup() then Pause.Resume() end
        end)
    end)
    ns.On("GROUP_ROSTER_UPDATE", function()
        local s = state()
        if s and s.grouped and not inGroup() then Pause.Resume() end
        refreshUI()
    end)
end)
