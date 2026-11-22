-- =============================================================================
-- Skwirlert - Welcome.lua  (0.9.1: welcome window at login)
-- =============================================================================
-- WHAT THIS FILE DOES
--   Every character starts with an empty reminder list, so a new player who
--   never opens the settings would never be warned about anything. At a real
--   login (not a /reload or zone change) a small window opens with quick
--   buttons: Refresh my buffs, New timer, Open settings, plus a
--   "Don't show this again" checkbox.
--
--   * "Don't show this again" is per character (ns.char.welcomeHide); the
--     extra "for all my characters" box sets it account-wide
--     (SkwirlertDB.welcomeHideAll). Unticking "Don't show this again" clears both.
--   * Bring it back: the "Welcome" checkbox in settings, or /skwirlert welcome.
--   * Never opens in combat: it waits for the fight to end.
--   * After an update, characters that hid the window get ONE chat line naming
--     the new version instead (ns.char.lastVersion).
--   * The window is only built when it is first shown.
--   * FIRST LOAD ONLY: a character's very first time with Skwirlert (no
--     reminders yet, tutorial never seen) opens the window as a five-page
--     TUTORIAL (Back / Next / Skip). It is marked seen (ns.char.tutorialSeen)
--     when finished, skipped or closed, so it never runs by itself again.
--     Reopen it with the window's "Tutorial" button or /skwirlert tutorial.
-- =============================================================================

local _, ns = ...
local CreateFrame = ns.SafeFrameFactory("Welcome")
local C = ns.Compat
local Welcome = {}
ns.Welcome = Welcome

Welcome.WHATS_NEW = "Alerts tab: Aspect of the Cheetah / Pack warning and an after-combat group check (cures and resurrections)."
local BACKDROP = _G.BackdropTemplateMixin and "BackdropTemplate" or nil
local frame, W = nil, {}
local mode, page = "welcome", 1     -- "welcome" or "tutorial"

-- The tutorial: short pages, one idea each.
Welcome.TUTORIAL = {
    { "What Skwirlert does",
      "Skwirlert warns you before a buff or a timer runs out: a yellow popup and a sound, a few seconds before it ends and again when it's gone. You choose what to watch and how early to be warned.\n\n"
      .. "In the list, a |cff40ff40green check|r means the time was read from the buff itself; a |cffffd100yellow check|r means it's an estimate (e.g. buff data is hidden in combat)." },
    { "Step 1: add your buffs",
      "Get buffed (your own buffs or other players'), then click |cffffd100Refresh my buffs|r, or Shift+click the minimap button. Every timed buff on you is added and tracked from then on, whoever casts it.\n\n"
      .. "Buffs shorter than 5 minutes are skipped to keep things quiet. To pick one by hand, use |cffffd100Add from my buffs|r in the settings." },
    { "Step 2: timers and buffs on others",
      "Click |cffffd100New|r in the settings:\n"
      .. "- |cffffd100Custom timer|r: any countdown, no spell needed (/skwirlert start <name>).\n"
      .. "- |cffffd100Buff I cast on others|r: e.g. Soulstone; remembers who got it.\n"
      .. "- |cffffd100From my recent casts|r: pick a spell you just cast.\n"
      .. "Buffing your party? Tick |cffffd100Track on each group member|r on that reminder." },
    { "Step 3: combat and group alerts",
      "The |cffffd100Alerts|r tab warns you when a fight starts with Aspect of the Cheetah or the Pack on, and after a fight tells the group who needs a curse or disease removed or a resurrection.\n\n"
      .. "The |cffffd100Group|r tab shares your running timers with groupmates who use Skwirlert. Both work out of the box." },
    { "Handy controls",
      "Minimap button: |cffffd100click|r = settings, |cffffd100Shift+click|r = refresh buffs, |cffffd100right-click|r = pause alerts.\n"
      .. "|cffffd100/skwirlert|r opens the settings; |cffffd100/skwirlert pause|r silences alerts for a while.\n"
      .. "Something wrong? |cffffd100/skwirlert report|r gives a copyable bug report.\n\n"
      .. "That's it. Click Done to start." },
}

-- Hidden for this character (or for all characters)?
function Welcome.IsHidden()
    if not (ns.char and ns.sv) then return true end
    return ns.char.welcomeHide == true or ns.sv.welcomeHideAll == true
end

-- Turn the login window on or off. allChars applies to every character.
function Welcome.SetHidden(hide, allChars)
    if not (ns.char and ns.sv) then return end
    if hide then
        ns.char.welcomeHide = true
        if allChars then ns.sv.welcomeHideAll = true end
    else
        ns.char.welcomeHide = nil
        ns.sv.welcomeHideAll = nil
    end
    Welcome.Refresh()
    if ns.Config and ns.Config.Refresh then ns.Config.Refresh() end
end

-- Status line: profile, how many reminders, alerts on/off.
local function statusText()
    local n = ns.db and #ns.db.reminders or 0
    local a = ns.db and ns.db.alerts
    local alerts = a and (a.aspect or a.care) and "on" or "off"
    return string.format("Profile: %s  ·  %d reminder%s  ·  combat alerts %s",
        tostring(ns.Profiles.Current()), n, n == 1 and "" or "s", alerts)
end

local function bodyText()
    local n = ns.db and #ns.db.reminders or 0
    if n == 0 then
        return "Skwirlert warns you before your buffs or timers run out.\n\n"
            .. "Get buffed, then click |cffffd100Refresh my buffs|r to add the timed buffs on you. "
            .. "Use |cffffd100New timer|r for a custom countdown (no spell needed).\n\n"
            .. "|cff999999New in " .. ns.version .. ":|r " .. Welcome.WHATS_NEW
    end
    return "You're set up. |cffffd100Refresh my buffs|r adds any new timed buffs on you; "
        .. "|cffffd100Open settings|r to change sounds and warnings.\n\n"
        .. "|cff999999New in " .. ns.version .. ":|r " .. Welcome.WHATS_NEW
end

local function button(parent, text, w, x, y, fn)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(w, 22); b:SetPoint("BOTTOMLEFT", x, y); b:SetText(text)
    b:SetScript("OnClick", fn)
    return b
end

-- First time on this character? (no reminders yet and tutorial never seen)
function Welcome.NeedsTutorial()
    return ns.char and not ns.char.tutorialSeen and ns.db and #ns.db.reminders == 0
end
local function markSeen() if ns.char then ns.char.tutorialSeen = true end end

local function openSettings()
    local _, win = ns.Config.Widgets()
    if not (win and win:IsShown()) then ns.Config.Toggle() end
end

local function build()
    frame = CreateFrame("Frame", "SkwirlertWelcome", UIParent, BACKDROP)
    frame:SetSize(440, 280)
    frame:SetPoint("CENTER", 0, 80)
    frame:SetFrameStrata("DIALOG")
    frame:SetClampedToScreen(true)
    frame:SetMovable(true); frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    if frame.SetBackdrop then
        frame:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            edgeSize = 14, insets = { left = 3, right = 3, top = 3, bottom = 3 } })
        frame:SetBackdropColor(0.05, 0.05, 0.07, 0.97)
        frame:SetBackdropBorderColor(1, 0.82, 0, 1)
    end
    tinsert(UISpecialFrames, "SkwirlertWelcome")   -- Escape closes it
    local icon = frame:CreateTexture(nil, "ARTWORK")
    icon:SetSize(32, 32); icon:SetPoint("TOPLEFT", 14, -12); icon:SetTexture(ns.ICON)
    W.title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    W.title:SetPoint("TOPLEFT", 54, -14)
    W.status = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    W.status:SetPoint("TOPLEFT", 54, -34)
    W.body = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    W.body:SetPoint("TOPLEFT", 16, -58); W.body:SetWidth(408); W.body:SetJustifyH("LEFT")
    local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -2, -2)
    -- Closing the window during the tutorial counts as having seen it.
    frame:SetScript("OnHide", function() if mode == "tutorial" then markSeen() end end)

    -- Tutorial navigation (shown only in tutorial mode).
    W.back = button(frame, "< Back", 80, 14, 56, function() page = math.max(1, page - 1); Welcome.Refresh() end)
    W.skip = button(frame, "Skip tutorial", 110, 156, 56, function() Welcome.FinishTutorial() end)
    W.next = button(frame, "Next >", 90, 336, 56, function()
        if page >= #Welcome.TUTORIAL then Welcome.FinishTutorial() else page = page + 1; Welcome.Refresh() end
    end)
    W.tutorial = button(frame, "Tutorial", 76, 352, 56, function() Welcome.ShowTutorial() end)

    W.refresh = button(frame, "Refresh my buffs", 124, 12, 56, function()
        frame:Hide(); ns.Picker.RefreshAll(true)
    end)
    W.newTimer = button(frame, "New timer", 96, 140, 56, function()
        frame:Hide(); openSettings(); ns.Config.ShowTab("reminders"); ns.Config.NewOf("timer", "New timer")
    end)
    W.settings = button(frame, "Open settings", 112, 238, 56, function()
        frame:Hide(); openSettings()
    end)

    W.dontShow = CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
    W.dontShow:SetSize(22, 22); W.dontShow:SetPoint("BOTTOMLEFT", 12, 22)
    if W.dontShow.Text then W.dontShow.Text:SetText("Don't show this again") end
    W.dontShow:SetScript("OnClick", function(self) Welcome.SetHidden(self:GetChecked() and true or false, W.allChars:GetChecked()) end)
    W.allChars = CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
    W.allChars:SetSize(22, 22); W.allChars:SetPoint("BOTTOMLEFT", 200, 22)
    if W.allChars.Text then W.allChars.Text:SetText("for all my characters") end
    W.allChars:SetScript("OnClick", function(self)
        if W.dontShow:GetChecked() then
            if self:GetChecked() then ns.sv.welcomeHideAll = true else ns.sv.welcomeHideAll = nil end
            Welcome.Refresh()
        end
    end)
    W.hint = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    W.hint:SetPoint("BOTTOMLEFT", 16, 8)
    W.hint:SetText("Open it again any time: /skwirlert welcome")
    frame:Hide()
end

-- Update the texts and checkboxes (only while the window exists).
function Welcome.Refresh()
    if not frame then return end
    local tut = mode == "tutorial"
    if tut then
        local pg = Welcome.TUTORIAL[page]
        W.title:SetText(pg[1])
        W.status:SetText(string.format("Skwirlert tutorial  ·  %d of %d", page, #Welcome.TUTORIAL))
        W.body:SetText(pg[2])
        W.next:SetText(page >= #Welcome.TUTORIAL and "Done" or "Next >")
        if W.back.SetEnabled then W.back:SetEnabled(page > 1) end
    else
        W.title:SetText("Welcome to Skwirlert  |cff999999v" .. ns.version .. "|r")
        W.status:SetText(statusText())
        W.body:SetText(bodyText())
    end
    for _, b in ipairs({ W.back, W.skip, W.next }) do if tut then b:Show() else b:Hide() end end
    for _, b in ipairs({ W.refresh, W.newTimer, W.settings, W.tutorial }) do if tut then b:Hide() else b:Show() end end
    W.dontShow:SetChecked(Welcome.IsHidden())
    W.allChars:SetChecked(ns.sv and ns.sv.welcomeHideAll == true)
end

-- Show the window now (button, command, or login). Waits out combat.
local waiting = false
function Welcome.Show(keepMode)
    if not keepMode then mode = "welcome" end
    if C.InCombat() then
        waiting = true            -- PLAYER_REGEN_ENABLED shows it
        return false
    end
    waiting = false
    if not frame then build() end
    Welcome.Refresh()
    frame:Show()
    return true
end
function Welcome.Hide() if frame then frame:Hide() end end

-- Start the tutorial at page 1 (first load, the Tutorial button, /skwirlert tutorial).
function Welcome.ShowTutorial()
    mode, page = "tutorial", 1
    local shown = Welcome.Show(true)
    return shown
end
-- Done / Skip: mark it seen and switch to the normal welcome view.
function Welcome.FinishTutorial()
    markSeen()
    mode, page = "welcome", 1
    Welcome.Refresh()
end
function Welcome.Mode() return mode, page end
function Welcome.Frame() return frame, W end

-- At a real login: the window (unless hidden), or one "updated" chat line.
function Welcome.OnLogin()
    if not ns.char then return end
    local last = ns.char.lastVersion
    ns.char.lastVersion = ns.version
    if not Welcome.IsHidden() then
        -- First time on this character: the tutorial; afterwards the welcome view.
        ns.After("Welcome", 3, function()
            if Welcome.NeedsTutorial() then Welcome.ShowTutorial() else Welcome.Show() end
        end)
    elseif last and last ~= ns.version then
        ns.Print(string.format("updated to %s. New: %s  (/skwirlert)", ns.version, Welcome.WHATS_NEW))
    end
end

ns.RegisterInit(function()
    ns.On("PLAYER_ENTERING_WORLD", function(_, isInitialLogin, isReloadingUi)
        -- Only a real login: not a /reload, not a zone change or instance portal.
        if C.Bool(isInitialLogin) and not C.Bool(isReloadingUi) then Welcome.OnLogin() end
    end)
    ns.On("PLAYER_REGEN_ENABLED", function()
        if waiting then ns.After("Welcome", 1, function() if waiting then Welcome.Show(true) end end) end
    end)
end)
