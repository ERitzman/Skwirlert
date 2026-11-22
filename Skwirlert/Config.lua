-- =============================================================================
-- Skwirlert - Config.lua  (the settings window, /skwirlert)
-- =============================================================================
-- WHAT THIS FILE DOES
--   Builds and refreshes the settings window:
--     * Reminders tab: list (checkbox + status icon per row), editor, buttons.
--     * Profiles tab: profile list, Use / Copy / Delete / Create / Rename /
--       Reset, and Share (export / import codes).
--   The window is built the first time it's opened (saves memory until then).
--
-- HOW THE UI IS ORGANISED
--   * Small helper functions (label, button, edit, check, cycler, slider) create
--     widgets in one line each, positioned with x/y offsets from the top-left.
--   * W = table of every widget we need to read or update later.
--   * Config.Refresh() copies saved data INTO the widgets. Widget callbacks copy
--     user input back into the saved data, then call Refresh. While Refresh
--     runs, `refreshing = true` stops callbacks from firing in a loop.
--   * renderList() only updates the list and status line, so the engine can
--     call it live without overwriting text the user is typing.
--
-- WOW CONCEPTS
--   * Templates: UIPanelButtonTemplate (red button), InputBoxTemplate (text
--     box), UICheckButtonTemplate (checkbox), UIPanelCloseButton (X).
--     Dropdown menus are avoided on purpose: their API changes between clients.
--   * UISpecialFrames: frames listed there close when Escape is pressed.
--   * GameTooltip: the shared tooltip (SetOwner, AddLine, Show, Hide).
--   * `local CreateFrame = ns.SafeFrameFactory(...)` (below) wraps every script
--     handler with error capture; see Core.lua.
-- =============================================================================

local _, ns = ...
local CreateFrame = ns.SafeFrameFactory("Settings")  -- wraps script handlers with error capture
local Config = {}
ns.Config = Config

local KIND_ORDER = { "self", "targeted", "timer" }
local KIND_LABEL = { self = "Buff on me", targeted = "Buff I cast on others", timer = "Custom timer (no spell needed)" }
local ROWS = 20
local ROW_H = 20

local win, selectedId, scrollOffset = nil, nil, 0
local W = {}  -- widgets
local refreshing = false

local BACKDROP = _G.BackdropTemplateMixin and "BackdropTemplate" or nil

-- Small widget helpers -----------------------------------------------------
local function label(parent, text, x, y, font)
    local fs = parent:CreateFontString(nil, "OVERLAY", font or "GameFontNormal")
    fs:SetPoint("TOPLEFT", x, y)
    fs:SetText(text)
    return fs
end

-- A standard red button at (x, y) from the parent's top-left.
local function button(parent, text, w, x, y, onClick)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(w, 22)
    b:SetPoint("TOPLEFT", x, y)
    b:SetText(text)
    b:SetScript("OnClick", onClick)
    return b
end

-- A text box. onCommit(text) runs on Enter or when the box loses focus;
-- Escape restores the saved value.
local function edit(parent, w, x, y, onCommit)
    local e = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    e:SetSize(w, 20)
    e:SetPoint("TOPLEFT", x + 6, y)
    e:SetAutoFocus(false)
    e:SetFontObject("ChatFontNormal")
    local function commit(self)
        if refreshing then return end
        onCommit(self:GetText() or "")
    end
    e:SetScript("OnEnterPressed", function(self) commit(self); self:ClearFocus() end)
    e:SetScript("OnEditFocusLost", function(self) commit(self) end)
    e:SetScript("OnEscapePressed", function(self) self:ClearFocus(); Config.Refresh() end)
    return e
end

-- A checkbox with a label; onClick(checked).
local function check(parent, text, x, y, onClick)
    local c = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    c:SetSize(24, 24)
    c:SetPoint("TOPLEFT", x, y)
    local fs = c.Text or c.text
    if not fs then
        fs = c:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        fs:SetPoint("LEFT", c, "RIGHT", 2, 0)
    end
    fs:SetText(text)
    c:SetScript("OnClick", function(self) onClick(self:GetChecked() and true or false) end)
    return c
end

-- Info icon (0.9.1): a small yellow "i" in a circle; hovering shows what
-- the setting next to it does. Purely a tooltip: clicking does nothing.
local INFO_ICON = "Interface\\AddOns\\Skwirlert\\Media\\Info"
W.infos = {}
local function info(parent, x, y, title, text)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(13, 13)
    b:SetPoint("TOPLEFT", x + 2, y - 1)        -- centred where the 16 px icon used to sit
    local t = b:CreateTexture(nil, "ARTWORK")
    t:SetAllPoints(); t:SetTexture(INFO_ICON)
    t:SetVertexColor(1, 0.92, 0.7)             -- a paler yellow
    b:SetAlpha(0.55)                           -- soft until hovered
    b.icon, b.title, b.text = t, title, text
    b:SetScript("OnEnter", function(self)
        local tip = _G.GameTooltip
        if not tip then return end
        self:SetAlpha(1)
        tip:SetOwner(self, "ANCHOR_RIGHT")
        tip:AddLine(self.title, 1, 0.82, 0)
        tip:AddLine(self.text, 1, 1, 1, true)
        tip:Show()
    end)
    b:SetScript("OnLeave", function(self) self:SetAlpha(0.55); if _G.GameTooltip then GameTooltip:Hide() end end)
    W.infos[#W.infos + 1] = b
    return b
end
Config.Info = info

-- "< value >" cycler used instead of dropdowns.
local function cycler(parent, x, y, width, onStep)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(width, 22)
    f:SetPoint("TOPLEFT", x, y)
    local prev = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    prev:SetSize(24, 22); prev:SetPoint("LEFT"); prev:SetText("<")
    local nxt = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    nxt:SetSize(24, 22); nxt:SetPoint("RIGHT"); nxt:SetText(">")
    f.value = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.value:SetPoint("LEFT", prev, "RIGHT", 4, 0)
    f.value:SetPoint("RIGHT", nxt, "LEFT", -4, 0)
    prev:SetScript("OnClick", function() onStep(-1) end)
    nxt:SetScript("OnClick", function() onStep(1) end)
    return f
end

-- A horizontal slider built without a template (templates differ between
-- clients). Steps of 1; the mouse wheel also works; onChange(value).
local function slider(parent, x, y, width, minV, maxV, onChange)
    local s = CreateFrame("Slider", nil, parent, BACKDROP)
    s:SetOrientation("HORIZONTAL")
    s:SetSize(width, 16)
    s:SetPoint("TOPLEFT", x, y)
    if s.SetBackdrop then
        s:SetBackdrop({
            bgFile = "Interface\\Buttons\\UI-SliderBar-Background",
            edgeFile = "Interface\\Buttons\\UI-SliderBar-Border",
            tile = true, tileSize = 8, edgeSize = 8,
            insets = { left = 3, right = 3, top = 6, bottom = 6 },
        })
    end
    s:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
    s:SetMinMaxValues(minV, maxV)
    s:SetValueStep(1)
    if s.SetObeyStepOnDrag then s:SetObeyStepOnDrag(true) end
    s:EnableMouseWheel(true)
    s:SetScript("OnMouseWheel", function(self, delta)
        self:SetValue(math.max(minV, math.min(maxV, self:GetValue() + delta)))
    end)
    local lo = s:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    lo:SetPoint("TOPLEFT", s, "BOTTOMLEFT", 0, -1); lo:SetText(tostring(minV))
    local hi = s:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hi:SetPoint("TOPRIGHT", s, "BOTTOMRIGHT", 0, -1); hi:SetText(tostring(maxV))
    s:SetScript("OnValueChanged", function(self, value)
        if refreshing then return end
        onChange(math.floor(value + 0.5))
    end)
    return s
end

-- Parsing ------------------------------------------------------------------
local function parseIDs(text)
    local out, seen = {}, {}
    for tok in text:gmatch("%d+") do
        local n = tonumber(tok)
        if n and n > 0 and not seen[n] then seen[n] = true; out[#out + 1] = n end
    end
    return out
end

-- "Arcane Intellect, Kings" -> { "Arcane Intellect", "Kings" }
local function parseNames(text)
    local out = {}
    for tok in text:gmatch("[^,;]+") do
        tok = tok:gsub("^%s+", ""):gsub("%s+$", "")
        if tok ~= "" then out[#out + 1] = tok end
    end
    return out
end

-- { 1, 2 } -> "1, 2" for showing lists in text boxes.
local function joinList(t)
    local parts = {}
    for _, v in ipairs(t or {}) do parts[#parts + 1] = tostring(v) end
    return table.concat(parts, ", ")
end

-- Clamp/normalise a warning value; returns integer 0..60 or nil if not a number.
-- 0 = expiration-only (no advance warning).
function Config.ClampWarn(v)
    local n = tonumber(v)
    if not n then return nil end
    n = math.floor(n + 0.5)
    if n < 0 then n = 0 elseif n > 60 then n = 60 end
    return n
end

-- The reminder selected in the list (shown in the editor), or nil.
local function current() return selectedId and ns.GetReminder(selectedId) end

-- After an edit: let the engine re-schedule timers, then redraw.
local function changed(r)
    if ns.Engine then ns.Engine:OnConfigChanged(r) end
    Config.Refresh()
end

-- Row status icons ----------------------------------------------------------
local ICON_VERIFIED = "Interface\\RaidFrame\\ReadyCheck-Ready"      -- green check
local ICON_ESTIMATE = "Interface\\Buttons\\UI-CheckBox-Check"       -- yellow check
local ICON_TIMER    = "Interface\\RaidFrame\\ReadyCheck-NotReady"   -- X
Config.ICONS = { verified = ICON_VERIFIED, estimated = ICON_ESTIMATE, timer = ICON_TIMER }

-- Returns status key, icon, description for a reminder.
function Config.StatusOf(r)
    local st = ns.Engine:State(r.id)
    if not st then
        -- Only member copies running (e.g. your Arcane Intellect on Bob)?
        local m = ns.Engine:Members(r.id)[1]
        if not m then return "off", nil, "Not running" end
        st = m
    end
    if r.kind == "timer" or st.source == "manual" then
        return "timer", ICON_TIMER, "Custom timer running"
    end
    if st.source == "verified" then
        return "verified", ICON_VERIFIED, "Tracked: time read from the buff"
    end
    return "estimated", ICON_ESTIMATE, "Estimated from your cast (buff not readable right now)"
end

-- Turn monitoring on/off (list checkbox and editor checkbox share this).
local function setEnabled(r, v)
    r.enabled = v and true or false
    if ns.Engine then
        ns.Engine:OnConfigChanged(r)
        if r.enabled and r.kind == "self" then ns.Engine:VerifySelf(r) end
    end
end
Config.SetEnabled = setEnabled

-- Window -------------------------------------------------------------------
local function build()
    win = CreateFrame("Frame", "SkwirlertConfig", UIParent, BACKDROP)
    win:SetSize(740, 610)
    win:SetPoint("CENTER")
    win:SetFrameStrata("DIALOG")
    win:SetClampedToScreen(true)
    win:SetMovable(true)
    win:EnableMouse(true)
    win:RegisterForDrag("LeftButton")
    win:SetScript("OnDragStart", win.StartMoving)
    win:SetScript("OnDragStop", win.StopMovingOrSizing)
    if win.SetBackdrop then
        win:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            edgeSize = 14, insets = { left = 3, right = 3, top = 3, bottom = 3 },
        })
        win:SetBackdropColor(0.05, 0.05, 0.07, 0.95)
        win:SetBackdropBorderColor(1, 0.82, 0, 1)
    end
    tinsert(UISpecialFrames, "SkwirlertConfig")  -- close with Escape

    -- Title row: the addon icon, then the name and version.
    local icon = win:CreateTexture(nil, "ARTWORK")
    icon:SetSize(26, 26)
    icon:SetPoint("TOPLEFT", 12, -8)
    icon:SetTexture(ns.ICON)
    W.titleIcon = icon
    label(win, "Skwirlert  |cff999999v" .. ns.version .. "|r", 44, -12, "GameFontNormalLarge")
    local close = CreateFrame("Button", nil, win, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -2, -2)
    W.profileLabel = label(win, "", 240, -17, "GameFontHighlightSmall")
    W.profileLabel:SetWidth(162); W.profileLabel:SetJustifyH("LEFT")
    if W.profileLabel.SetWordWrap then W.profileLabel:SetWordWrap(false) end

    -- Pages + tabs -------------------------------------------------------------
    local page = CreateFrame("Frame", nil, win)
    page:SetAllPoints()
    W.page = page
    local ed = CreateFrame("Frame", nil, page)   -- editor: hidden when the profile is empty
    ed:SetAllPoints()
    W.editor = ed
    W.tabReminders = button(win, "Reminders", 80, 410, -10, function() Config.ShowTab("reminders") end)
    W.tabProfiles = button(win, "Profiles", 70, 492, -10, function() Config.ShowTab("profiles") end)
    W.tabGroup = button(win, "Group", 60, 564, -10, function() Config.ShowTab("group") end)
    W.tabAlerts = button(win, "Alerts", 60, 626, -10, function() Config.ShowTab("alerts") end)


    -- Reminder list ----------------------------------------------------------
    label(page, "Reminders", 14, -40)
    W.count = label(page, "", 84, -41, "GameFontHighlightSmall")
    info(page, 214, -38, "Your reminders",
        "Tick a reminder to monitor it; untick to stop without deleting it.\nGreen check: time read from the buff. Yellow check: estimated (buff data hidden, e.g. in combat). Red X: a custom timer is running.\nHover a row for details; scroll with the mouse wheel.")
    local function scroll(delta)
        local maxOff = math.max(0, #ns.db.reminders - ROWS)
        scrollOffset = math.max(0, math.min(maxOff, scrollOffset + delta))
        Config.Refresh()
    end
    W.up = button(page, "^", 22, 168, -36, function() scroll(-ROWS + 1) end)
    W.down = button(page, "v", 22, 190, -36, function() scroll(ROWS - 1) end)
    local list = CreateFrame("Frame", nil, page, BACKDROP)
    list:SetPoint("TOPLEFT", 12, -58)
    list:SetSize(200, ROWS * ROW_H + 8)
    if list.SetBackdrop then
        list:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8" })
        list:SetBackdropColor(0, 0, 0, 0.4)
    end
    list:EnableMouseWheel(true)
    list:SetScript("OnMouseWheel", function(_, delta)
        local maxOff = math.max(0, #ns.db.reminders - ROWS)
        scrollOffset = math.max(0, math.min(maxOff, scrollOffset - delta))
        Config.Refresh()
    end)
    W.empty = list:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    W.empty:SetPoint("TOPLEFT", 10, -12); W.empty:SetWidth(180); W.empty:SetJustifyH("LEFT")
    W.empty:SetText("No reminders in this profile yet.\n\nGet buffed, then click |cffffd100Add from my buffs|r below.\n\nOr click |cffffd100New|r for a custom timer or a buff you cast on others (e.g. Soulstone).\n\nTo use another character's setup, open the |cffffd100Profiles|r tab.")
    W.empty:Hide()
    W.rows = {}
    for i = 1, ROWS do
        local b = CreateFrame("Button", nil, list)
        b:SetSize(192, ROW_H)
        b:SetPoint("TOPLEFT", 4, -4 - (i - 1) * ROW_H)
        b.check = CreateFrame("CheckButton", nil, b, "UICheckButtonTemplate")
        b.check:SetSize(18, 18); b.check:SetPoint("LEFT", 0, 0)
        b.check:SetScript("OnClick", function(self)
            local r = b.rid and ns.GetReminder(b.rid)
            if r then setEnabled(r, self:GetChecked()); Config.Refresh() end
        end)
        b.status = b:CreateTexture(nil, "OVERLAY")
        b.status:SetSize(14, 14); b.status:SetPoint("RIGHT", -4, 0)
        b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightLeft")
        b.text:SetPoint("LEFT", 20, 0); b.text:SetPoint("RIGHT", -20, 0)
        b.hl = b:CreateTexture(nil, "BACKGROUND")
        b.hl:SetAllPoints(); b.hl:SetColorTexture(1, 0.82, 0, 0.25); b.hl:Hide()
        b:SetScript("OnClick", function(self)
            if self.rid then selectedId = self.rid; Config.Refresh() end
        end)
        b:SetScript("OnEnter", function(self)
            local r = self.rid and ns.GetReminder(self.rid)
            local tip = _G.GameTooltip
            if not (r and tip) then return end
            local _, _, desc = Config.StatusOf(r)
            tip:SetOwner(self, "ANCHOR_RIGHT")
            tip:AddLine(r.name)
            tip:AddLine(desc, 1, 1, 1)
            local st = ns.Engine:State(r.id)
            if st then tip:AddLine(ns.Engine.fmtTime(st.expires - GetTime()) .. " left" .. (st.recipient and (" on " .. st.recipient) or ""), 1, 1, 1) end
            for _, ms in ipairs(ns.Engine:Members(r.id)) do
                tip:AddLine(ms.member .. ": " .. ns.Engine.fmtTime(ms.expires - GetTime()) .. " left", 1, 1, 1)
            end
            tip:AddLine(r.enabled and "Monitoring on (checkbox)" or "Monitoring off (checkbox)", 0.7, 0.7, 0.7)
            tip:AddLine("Green check: read from the buff. Yellow check: estimated. X: custom timer.", 0.6, 0.6, 0.6, true)
            tip:Show()
        end)
        b:SetScript("OnLeave", function() if _G.GameTooltip then GameTooltip:Hide() end end)
        W.rows[i] = b
    end
    -- "New" opens a small menu: what kind of reminder? (0.8.0) A custom timer
    -- needs no spell at all; "From my recent casts" fills the spell in for you.
    local newBtnY = -58 - ROWS * ROW_H - 14
    local menu = CreateFrame("Frame", nil, page, BACKDROP)
    menu:SetSize(214, 132); menu:SetPoint("BOTTOMLEFT", page, "TOPLEFT", 8, newBtnY + 4)
    menu:SetFrameLevel((page:GetFrameLevel() or 1) + 30)
    menu:EnableMouse(true)
    if menu.SetBackdrop then
        menu:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
        menu:SetBackdropColor(0.04, 0.04, 0.06, 1); menu:SetBackdropBorderColor(1, 0.82, 0, 0.8)
    end
    menu:Hide()
    W.newMenu = menu
    local function newOf(kind, name)
        menu:Hide()
        local r, err = ns.AddReminder({ name = name, kind = kind, duration = 600, warn = 30,
            warnSound = "quick-tone", expireSound = "Uh Oh" })
        if not r then ns.Print(err); ns.Popup.Show("Reminder limit reached (" .. ns.MAX_REMINDERS .. ")"); return end
        selectedId = r.id
        scrollOffset = math.max(0, #ns.db.reminders - ROWS)
        Config.Refresh()
        return r
    end
    Config.NewOf = newOf
    W.newTimer = button(menu, "Custom timer (no spell)", 200, 7, -6, function() newOf("timer", "New timer") end)
    W.newSelf = button(menu, "Buff on me", 200, 7, -32, function() newOf("self", "New buff") end)
    W.newTargeted = button(menu, "Buff I cast on others", 200, 7, -58, function() newOf("targeted", "New buff on others") end)
    W.newFromCasts = button(menu, "From my recent casts...", 200, 7, -84, function()
        menu:Hide(); ns.Picker.Toggle(page, "casts")
    end)
    W.newCancel = button(menu, "Cancel", 200, 7, -110, function() menu:Hide() end)
    W.newBtn = button(page, "New", 64, 12, newBtnY, function()
        if menu:IsShown() then menu:Hide() else menu:Show() end
    end)
    info(page, 214, newBtnY - 3, "New, Delete, Test",
        "New: choose Custom timer (no spell needed), Buff on me, Buff I cast on others, or From my recent casts.\nDelete: click twice to confirm. Refresh won't add a deleted buff back.\nTest: shows this reminder's warning popup and sound.")
    W.delete = button(page, "Delete", 64, 80, -58 - ROWS * ROW_H - 14, function(self)
        local r = current()
        if not r then return end
        if self.armed then
            if ns.Picker and ns.Picker.Ignore then ns.Picker.Ignore(r) end   -- Refresh won't re-add it
            ns.DeleteReminder(r.id)
            selectedId = ns.db.reminders[1] and ns.db.reminders[1].id or nil
            self.armed = false
            self:SetText("Delete")
            Config.Refresh()
        else
            self.armed = true
            self:SetText("Confirm")
            ns.After("Config", 3, function() self.armed = false; self:SetText("Delete") end)
        end
    end)
    W.fromBuffs = button(page, "Add from my buffs", 200, 12, -58 - ROWS * ROW_H - 40, function()
        ns.Picker.Toggle(page)
    end)
    info(page, 214, -58 - ROWS * ROW_H - 43, "Add from my buffs",
        "Lists the buffs on you right now. Click one to track it: its name, spell ID and real duration are filled in for you.\nTo add all of them at once, use Refresh (Shift+click the minimap button or /skwirlert refresh).")
    button(page, "Test", 64, 148, -58 - ROWS * ROW_H - 14, function()
        local r = current()
        if not r then return end
        ns.Popup.Show(r.name .. " expires in " .. r.warn .. "s (test)")
        ns.Sounds.Play(r.warnSound, true)
    end)

    -- Editor ----------------------------------------------------------------
    local X, X2 = 228, 360
    local y = -40
    label(ed, "Name", X, y - 4);            W.name = edit(ed, 320, X2, y, function(t)
        local r = current(); if not r then return end
        t = t:gsub("^%s+", ""):gsub("%s+$", "")
        if t ~= "" then r.name = t end
        -- A buff reminder with nothing to match: if the name is a spell this
        -- character knows, use it (no spell ID needed from the player).
        if r.kind ~= "timer" and #r.names == 0 and #r.spellIDs == 0 then
            local id = ns.Compat.SpellIDFromName(r.name)
            if id then r.names = { r.name }; r.spellIDs = { id } end
        end
        changed(r)
    end)
    info(ed, 712, y - 1, "Name", "The name shown in alerts and in the list. For a buff, typing the spell's name (e.g. Arcane Intellect) also fills in the buff name and ID.")
    y = y - 30
    label(ed, "Type", X, y - 4)
    W.kind = cycler(ed, X2, y, 326, function(dir)
        local r = current(); if not r then return end
        local idx = 1
        for i, k in ipairs(KIND_ORDER) do if k == r.kind then idx = i end end
        idx = ((idx - 1 + dir) % #KIND_ORDER) + 1
        r.kind = KIND_ORDER[idx]
        ns.Engine:Clear(r.id)
        changed(r)
    end)
    info(ed, 712, y - 1, "Type", "Buff on me: a buff on you, whoever cast it.\nBuff I cast on others: e.g. Soulstone; remembers who got it.\nCustom timer: any countdown, no spell needed (Start, or /skwirlert start <name>).")
    y = y - 30
    W.idsLabel = label(ed, "Spell ID (optional)", X, y - 4);   W.ids = edit(ed, 320, X2, y, function(t)
        local r = current(); if not r then return end
        r.spellIDs = parseIDs(t); changed(r)
    end)
    info(ed, 712, y - 1, "Spell ID (optional)", "Not needed: the buff name is enough, and the ID is learned on your first cast or filled in from the name. Several IDs (ranks) can be separated with commas.")
    y = y - 30
    W.namesLabel = label(ed, "Buff name", X, y - 4);     W.names = edit(ed, 320, X2, y, function(t)
        local r = current(); if not r then return end
        r.names = parseNames(t)
        -- Fill in the optional ID when the player only typed a name (0.8.0).
        if #r.spellIDs == 0 then
            for _, n in ipairs(r.names) do
                local id = ns.Compat.SpellIDFromName(n)
                if id then r.spellIDs[#r.spellIDs + 1] = id end
            end
        end
        changed(r)
    end)
    info(ed, 712, y - 1, "Buff name", "The buff's name exactly as in game (case doesn't matter). For a custom timer, naming a spell here starts the timer automatically when you cast it.")
    y = y - 30
    -- Duration accepts "30s", "10m", "30m30s", "1h", "90" (seconds), "10:00"...
    -- and is stored in seconds (1 second to 24 hours).
    label(ed, "Duration", X, y - 4);  W.duration = edit(ed, 80, X2, y, function(t)
        local r = current(); if not r then return end
        local n, err = ns.ParseDuration(t)
        if not n then
            ns.Print("|cffff6060duration not changed:|r " .. err)
        elseif n < 1 then
            ns.Print("|cffff6060duration not changed:|r it must be at least 1s")
        else
            if n > 86400 then n = 86400; ns.Print("duration capped at 24h") end
            if n ~= r.duration then
                r.duration = n
                r.learnedDuration = nil  -- explicit value wins until a real aura is read again
            end
        end
        changed(r)
    end)
    W.learned = label(ed, "", X2 + 96, y - 4, "GameFontHighlightSmall")
    info(ed, 712, y - 1, "Duration", "How long it lasts: 30s, 10m, 30m30s, 1h, a plain number of seconds, or 10:00. For buffs, the real duration is read from the buff when possible and shown next to the box.")
    y = y - 34
    label(ed, "Warn before (0-60s)", X, y - 2)
    W.warnSlider = slider(ed, X2, y, 190, 0, 60, function(v)
        local r = current(); if not r then return end
        r.warn = Config.ClampWarn(v)
        refreshing = true; W.warnEdit:SetText(tostring(r.warn)); refreshing = false
        if ns.Engine then ns.Engine:OnConfigChanged(r) end
    end)
    W.warnEdit = edit(ed, 40, X2 + 200, y + 2, function(t)
        local r = current(); if not r then return end
        local n = Config.ClampWarn(t)
        if n then r.warn = n end
        changed(r)
    end)
    W.warnEdit:SetNumeric(true)
    W.warnEdit:SetMaxLetters(2)
    info(ed, 712, y + 1, "Warn before", "How many seconds before the end to warn you (popup, sound and optional chat). 0 = no early warning, only the expiration alert.")
    label(ed, "0 = expiry alert only", X, y - 17, "GameFontDisableSmall")
    y = y - 40
    label(ed, "Warning sound", X, y - 4)
    W.warnSound = cycler(ed, X2, y, 220, function(dir)
        local r = current(); if not r then return end
        r.warnSound = ns.Sounds.Next(r.warnSound, dir)
        ns.Sounds.Play(r.warnSound, true)
        Config.Refresh()
    end)
    button(ed, "Play", 46, X2 + 224, y, function()
        local r = current(); if r then ns.Sounds.Play(r.warnSound, true) end
    end)
    info(ed, 712, y - 1, "Warning sound", "Played with the early warning. Use the arrows to choose (it plays as you switch) or Play to hear it again.")
    y = y - 30
    label(ed, "Expiration sound", X, y - 4)
    W.expireSound = cycler(ed, X2, y, 220, function(dir)
        local r = current(); if not r then return end
        r.expireSound = ns.Sounds.Next(r.expireSound, dir)
        ns.Sounds.Play(r.expireSound, true)
        Config.Refresh()
    end)
    button(ed, "Play", 46, X2 + 224, y, function()
        local r = current(); if r then ns.Sounds.Play(r.expireSound, true) end
    end)
    info(ed, 712, y - 1, "Expiration sound", "Played when it runs out (if 'Alert on expiration' is ticked).")
    y = y - 30
    label(ed, "Chat announce", X, y - 4)
    W.announce = cycler(ed, X2, y, 160, function(dir)
        local r = current(); if not r then return end
        r.announce = ns.Announce.Next(r.announce, dir)
        Config.Refresh()
    end)
    button(ed, "Test chat", 80, X2 + 166, y, function()
        local r = current(); if not r then return end
        if r.announce == "off" then ns.Print("chat announce is Off for " .. r.name); return end
        local ok, info = ns.Announce.Send(r.announce, r.name .. " chat test", true)
        if not ok then ns.Print("chat test not sent: " .. tostring(info)) end
    end)
    info(ed, 712, y - 1, "Chat announce", "Optionally tell others in chat: Say, Party, Raid or Group (auto picks party/raid/instance). Say only works automatically inside instances. 'Test chat' sends a test line.")
    y = y - 28
    W.annApplied = check(ed, "Announce when applied", X, y, function(v)
        local r = current(); if not r then return end
        r.announceApplied = v
    end)
    W.annWarn = check(ed, "Announce at warning time", X + 190, y, function(v)
        local r = current(); if not r then return end
        r.announceWarn = v
    end)
    info(ed, 712, y - 3, "When to announce", "Applied: when you cast it (or start the timer). Warning time: at the same moment as the warning popup.")
    y = y - 32
    W.enabled = check(ed, "Enabled", X, y, function(v)
        local r = current(); if not r then return end
        setEnabled(r, v); Config.Refresh()
    end)
    W.expireAlert = check(ed, "Alert on expiration", X + 110, y, function(v)
        local r = current(); if not r then return end
        r.expireAlert = v; changed(r)
    end)
    -- 0.8.0: one timer per group member who has YOUR copy of this buff.
    W.perMember = check(ed, "Track on each group member", X + 262, y, function(v)
        local r = current(); if not r then return end
        r.perMember = v and r.kind ~= "timer" or false
        changed(r)
        if r.perMember and ns.Engine then ns.Engine:VerifyAll() end
    end)
    info(ed, 712, y - 3, "Enabled / Alert on expiration / Track on each group member",
        "Enabled: monitor this reminder (same as the list checkbox).\nAlert on expiration: also alert when it runs out.\nTrack on each group member: for buffs you also cast on groupmates (e.g. Arcane Intellect) - one timer per person who has YOUR copy, with merged alerts.")
    y = y - 30
    W.startBtn = button(ed, "Start timer now", 120, X, y, function()
        local r = current(); if r then ns.Engine:StartManual(r); Config.Refresh() end
    end)
    W.stopBtn = button(ed, "Stop", 60, X + 124, y, function()
        local r = current(); if r then ns.Engine:Clear(r.id); Config.Refresh() end
    end)
    W.status = label(ed, "", X + 210, y - 4, "GameFontHighlightSmall")
    info(ed, X + 189, y - 1, "Start / Stop", "Start the countdown by hand (any type), or stop it without an alert. The text shows what's running and how long is left.")
    y = y - 26
    W.hint = label(ed, "", X, y, "GameFontDisableSmall")
    W.hint:SetWidth(470); W.hint:SetJustifyH("LEFT")
    y = y - 28
    W.chatHint = label(ed, "Chat warnings go out at the same moment as the popup (uses the warning time above). Say works automatically only inside instances; Raid falls back to Party when you're not in a raid.", X, y, "GameFontDisableSmall")
    W.chatHint:SetWidth(470); W.chatHint:SetJustifyH("LEFT")

    -- Global settings -------------------------------------------------------
    local gy = -542
    local line = page:CreateTexture(nil, "ARTWORK")
    line:SetColorTexture(1, 0.82, 0, 0.3)
    line:SetPoint("TOPLEFT", 12, gy + 8); line:SetSize(716, 1)
    label(page, "Popup secs", 14, gy - 4)
    W.popupDur = edit(page, 40, 86, gy, function(t)
        local n = tonumber(t)
        if n then ns.db.popup.duration = math.max(0.5, math.min(10, n)) end
        Config.Refresh()
    end)
    W.unlock = check(page, "Unlock popup", 150, gy + 2, function(v) ns.Popup.SetLocked(not v) end)
    W.master = check(page, "Addon enabled", 290, gy + 2, function(v) ns.db.enabled = v end)
    W.diag = check(page, "Diagnostics mode", 420, gy + 2, function(v) ns.Diag.SetEnabled(v) end)
    -- 0.9.1: show the welcome window at login (same switch as its "Don't show this again").
    W.welcome = check(page, "Welcome", 590, gy + 2, function(v) ns.Welcome.SetHidden(not v) end)
    info(page, 712, gy - 1, "Window and popup settings",
        "Popup secs: how long alert popups stay up. Unlock popup: drag the popup to move it.\nAddon enabled: master switch for all alerts. Diagnostics mode: records an activity log for bug reports.\nWelcome: show the welcome window at login.")
    gy = gy - 30
    button(page, "Test popup", 100, 12, gy, function() ns.Popup.Show("Skwirlert test popup") end)
    button(page, "Test all sounds", 120, 116, gy, function() ns.Sounds.TestAll() end)
    button(page, "Reset popup position", 150, 240, gy, function() ns.Popup.ResetPosition() end)
    W.bugReport = button(page, "Bug report", 100, 396, gy, function() ns.Diag.ShowReport() end)
    -- Refresh only auto-adds buffs at least this long (0.8.0; default 5m).
    W.refreshMinLabel = label(page, "Refresh min", 560, gy - 4, "GameFontHighlightSmall")
    info(page, 712, gy - 1, "Tests, bug report, Refresh min",
        "Test popup / Test all sounds: check what alerts look and sound like. Reset popup position: put the popup back.\nBug report: a copyable report for when something goes wrong.\nRefresh min: Refresh only adds buffs at least this long (default 5m), so short buffs like shouts don't flood your list.")
    W.refreshMin = edit(page, 56, 628, gy, function(t)
        local n, err = ns.ParseDuration(t)
        if n then ns.db.refresh.minDuration = math.max(0, math.min(86400, n))
        else ns.Print("|cffff6060refresh minimum not changed:|r " .. tostring(err)) end
        Config.Refresh()
    end)

    Config.BuildProfiles(win)
    Config.BuildGroup(win)
    Config.BuildAlerts(win)
    win:SetScript("OnShow", function() Config.Refresh() end)
    win:Hide()
end

local HINTS = {
    self = "Tracks this buff on you, whoever cast it. Starts on your cast or when seen on you. The buff name is enough; the ID is optional and filled in for you.",
    targeted = "For buffs you cast on others (e.g. Soulstone). Starts on your cast, remembers who got it, and checks their buff when readable.",
    timer = "No spell needed: press Start, or use a macro: /skwirlert start <name>. Optionally fill in a spell to start it automatically when you cast that spell.",
}
local HINT_MEMBER = " Group members: one timer per member who has your copy; alerts that land together are merged into one popup."
local HINT_NOTHING = "|cffff8060No buff name or spell ID: this can only be started manually. Type the buff's name (e.g. Arcane Intellect) or use New > From my recent casts.|r"

-- List rows, counter and status line only: safe to call while the user is typing.
local function renderList()
    local reminders = ns.db.reminders
    local maxOff = math.max(0, #reminders - ROWS)
    if scrollOffset > maxOff then scrollOffset = maxOff end
    local n = #reminders
    W.count:SetText(string.format("%s%d/%d|r", n >= ns.MAX_REMINDERS and "|cffff6060" or "|cffaaaaaa", n, ns.MAX_REMINDERS))
    W.profileLabel:SetText("Profile: |cffffffff" .. tostring(ns.Profiles.Current()) .. "|r")
    if n == 0 then W.empty:Show() else W.empty:Hide() end
    if W.up.SetEnabled then W.up:SetEnabled(scrollOffset > 0); W.down:SetEnabled(scrollOffset < maxOff) end
    if selectedId and not ns.GetReminder(selectedId) then selectedId = nil end
    if not selectedId and reminders[1] then selectedId = reminders[1].id end
    for i, row in ipairs(W.rows) do
        local r = reminders[i + scrollOffset]
        if r then
            row.rid = r.id
            row.text:SetText((r.enabled and "" or "|cff777777") .. r.name .. "|r")
            row.check:SetChecked(r.enabled)
            local key, icon = Config.StatusOf(r)
            row.statusKey = key
            if icon then
                row.status:SetTexture(icon)
                row.status:SetDesaturated(false)
                if key == "timer" then row.status:SetVertexColor(1, 0.35, 0.35) else row.status:SetVertexColor(1, 1, 1) end
                row.status:Show()
            else
                row.status:Hide()
            end
            if r.id == selectedId then row.hl:Show() else row.hl:Hide() end
            row:Show()
        else
            row.rid = nil
            row.statusKey = nil
            row:Hide()
        end
    end
    local r = current()
    if r then
        local st = ns.Engine:State(r.id)
        local parts = {}
        if st then
            parts[1] = string.format("%s: %s left%s", st.source,
                ns.Engine.fmtTime(st.expires - GetTime()), st.recipient and (" on " .. st.recipient) or "")
        end
        local members = ns.Engine:Members(r.id)
        if #members > 0 then
            local m = {}
            for i, ms in ipairs(members) do
                if i > 4 then m[#m + 1] = "+" .. (#members - 4); break end
                m[#m + 1] = ms.member .. " " .. ns.Engine.fmtTime(ms.expires - GetTime())
            end
            parts[#parts + 1] = table.concat(m, ", ")
        end
        W.status:SetText(#parts > 0 and table.concat(parts, "; ") or "not running")
    end
end

-- Redraw the Reminders tab from saved data (list, editor fields, settings row).
function Config.Refresh()
    if not (win and win:IsShown()) then return end
    refreshing = true
    renderList()
    local r = current()
    if r then W.editor:Show() else W.editor:Hide() end
    if r then
        W.name:SetText(r.name)
        W.kind.value:SetText(KIND_LABEL[r.kind])
        W.ids:SetText(joinList(r.spellIDs))
        W.names:SetText(joinList(r.names))
        W.duration:SetText(ns.FormatDuration(r.duration))
        local extra = {}
        if r.learnedDuration then extra[#extra + 1] = "aura reported " .. ns.FormatDuration(r.learnedDuration) end
        if #r.learnedIDs > 0 then extra[#extra + 1] = "learned IDs: " .. joinList(r.learnedIDs) end
        W.learned:SetText(table.concat(extra, "; "))
        W.warnSlider:SetValue(r.warn)
        W.warnEdit:SetText(tostring(r.warn))
        W.warnSound.value:SetText(ns.Sounds.Label(r.warnSound))
        W.expireSound.value:SetText(ns.Sounds.Label(r.expireSound))
        W.announce.value:SetText(ns.Announce.LABEL[r.announce] or "Off")
        W.annApplied:SetChecked(r.announceApplied)
        W.annWarn:SetChecked(r.announceWarn)
        W.enabled:SetChecked(r.enabled)
        W.expireAlert:SetChecked(r.expireAlert)
        W.perMember:SetChecked(r.perMember)
        if r.kind == "timer" then W.perMember:Hide() else W.perMember:Show() end
        W.namesLabel:SetText(r.kind == "timer" and "Start on cast of (optional)" or "Buff name")
        local hint = HINTS[r.kind] or ""
        if r.kind ~= "timer" and #r.names == 0 and #r.spellIDs == 0 and #r.learnedIDs == 0 then
            hint = HINT_NOTHING
        elseif r.perMember then
            hint = hint .. HINT_MEMBER
        end
        W.hint:SetText(hint)
    end
    W.popupDur:SetText(tostring(ns.db.popup.duration))
    W.refreshMin:SetText(ns.FormatDuration(ns.db.refresh.minDuration))
    W.unlock:SetChecked(not ns.db.popup.locked)
    W.master:SetChecked(ns.db.enabled)
    W.diag:SetChecked(ns.Diag.Enabled())
    W.welcome:SetChecked(not ns.Welcome.IsHidden())
    refreshing = false
end

-- Alerts tab (0.9.0) ---------------------------------------------------------
-- Aspect warning and the after-combat group check (CombatAlerts.lua).
local CHANNELS = { "off", "party", "raid", "group" }
local CHANNEL_LABEL = { off = "Off (popup only)", party = "Party", raid = "Raid", group = "Group (auto)" }
function Config.BuildAlerts(parent)
    local A = CreateFrame("Frame", nil, parent)
    A:SetAllPoints(); A:Hide()
    W.alertsPage = A
    local function S() return ns.CombatAlerts.Settings() end
    label(A, "Combat alerts", 14, -44, "GameFontNormalLarge")

    label(A, "Aspect warning", 14, -76, "GameFontNormal")
    info(A, 120, -76, "Aspect warning", "Aspect of the Cheetah and Aspect of the Pack daze you when you're hit. Skwirlert warns when a fight starts with one on.\nPack dazes the whole party, so it also warns when a group member enters combat.\nAny class: warns you when a hunter's Pack is on YOU - the hunter doesn't need Skwirlert. One alert per fight.")
    W.alAspect = check(A, "Hunter: warn when combat starts with Aspect of the Cheetah or Aspect of the Pack on", 12, -94, function(v) S().aspect = v; Config.RefreshAlerts() end)
    W.alPackGroup = check(A, "Aspect of the Pack: also warn when a group member enters combat", 32, -118, function(v) S().packGroup = v end)
    W.alPackOnMe = check(A, "Any class: warn me when a hunter's Pack is on me", 32, -142, function(v) S().packOnMe = v end)
    label(A, "Sound", 36, -172)
    W.alAspectSound = cycler(A, 150, -168, 220, function(dir)
        S().aspectSound = ns.Sounds.Next(S().aspectSound, dir); ns.Sounds.Play(S().aspectSound, true); Config.RefreshAlerts()
    end)
    button(A, "Play", 46, 374, -168, function() ns.Sounds.Play(S().aspectSound, true) end)
    button(A, "Test", 60, 424, -168, function()
        ns.Popup.Show("Aspect of the Pack is on - Bob is in combat! (test)"); ns.Sounds.Play(S().aspectSound, true)
    end)
    info(A, 616, -144, "Tell the group (hunters)", "Also post one chat line when your Pack is on and the group pulls, for groupmates who don't run Skwirlert. Off by default to keep chat quiet.")
    -- Hunter: one chat line per fight for groupmates without Skwirlert.
    label(A, "Tell the group", 494, -144, "GameFontHighlightSmall")
    W.alPackAnnounce = cycler(A, 490, -168, 150, function(dir)
        local idx = 1
        for i, c in ipairs(CHANNELS) do if c == S().packAnnounce then idx = i end end
        S().packAnnounce = CHANNELS[((idx - 1 + dir) % #CHANNELS) + 1]; Config.RefreshAlerts()
    end)

    local line = A:CreateTexture(nil, "ARTWORK")
    line:SetColorTexture(1, 0.82, 0, 0.3); line:SetPoint("TOPLEFT", 12, -204); line:SetSize(716, 1)
    label(A, "After combat: group check", 14, -216, "GameFontNormal")
    info(A, 196, -216, "After-combat group check", "A few seconds after a fight, checks everyone in the group and posts ONE message naming who needs a curse/disease (poison/magic optional) removed or a resurrection.\n'Can help' only lists players whose Skwirlert found a fitting spell in their own spellbook. Only one Skwirlert in the group posts, at most once a minute per person.")
    local d = label(A, "When combat ends, Skwirlert checks everyone in your group and tells the group who needs a cure or a resurrection, by name. \"Can help\" lists players whose Skwirlert found a fitting spell in their own spellbook. Only one Skwirlert in the group posts.", 14, -234, "GameFontHighlightSmall")
    d:SetWidth(710); d:SetJustifyH("LEFT")
    W.alCare = check(A, "Check the group when combat ends", 12, -270, function(v) S().care = v; Config.RefreshAlerts() end)
    W.alKinds = {}
    local kinds = { { "curse", "Curse" }, { "disease", "Disease" }, { "poison", "Poison" }, { "magic", "Magic" }, { "dead", "Dead (resurrect)" } }
    for i, k in ipairs(kinds) do
        W.alKinds[k[1]] = check(A, k[2], 32 + (i - 1) * 110, -294, function(v) S()[k[1]] = v end)
    end
    label(A, "Announce in", 36, -326)
    W.alChannel = cycler(A, 150, -322, 220, function(dir)
        local idx = 1
        for i, c in ipairs(CHANNELS) do if c == S().careChannel then idx = i end end
        S().careChannel = CHANNELS[((idx - 1 + dir) % #CHANNELS) + 1]; Config.RefreshAlerts()
    end)
    info(A, 128, -324, "Announce in", "Where the message goes: Group (auto) picks party, raid or instance chat. Off (popup only) keeps it on your screen. Say isn't offered: it can't be sent automatically outside instances.")
    label(A, "Say isn't offered: it can't be sent automatically outside instances.", 378, -326, "GameFontDisableSmall")
    label(A, "Sound", 36, -356)
    W.alCareSound = cycler(A, 150, -352, 220, function(dir)
        S().careSound = ns.Sounds.Next(S().careSound, dir); ns.Sounds.Play(S().careSound, true); Config.RefreshAlerts()
    end)
    button(A, "Play", 46, 374, -352, function() ns.Sounds.Play(S().careSound, true) end)
    label(A, "Wait after combat", 36, -386)
    W.alDelay = edit(A, 40, 150, -382, function(t)
        local n = tonumber(t)
        if n then S().careDelay = math.max(0, math.min(30, math.floor(n))) end
        Config.RefreshAlerts()
    end)
    label(A, "seconds (gives healers a moment to cure first)", 196, -386, "GameFontDisableSmall")
    info(A, 470, -384, "Wait after combat", "How long to wait after the fight before checking (0-30 s), so healers can cure first. A new pull during the wait postpones the check.")
    button(A, "Check now", 100, 36, -416, function() ns.CombatAlerts.Check(true, false) end)
    button(A, "Check and announce", 150, 140, -416, function() ns.CombatAlerts.Check(true, true) end)
    info(A, 296, -419, "Check now", "Check now: run the check and show the result only to you. Check and announce: run it and post it to the group (/skwirlert check announce).")
    W.alCaps = label(A, "", 36, -452, "GameFontHighlightSmall")
    W.alNote = label(A, "Aspect of the Pack for group members uses each member's combat state; debuff types come from the game's aura data. Both are still to be confirmed on WoW Forever (see UNVERIFIED.md).", 14, -480, "GameFontDisableSmall")
    W.alNote:SetWidth(710); W.alNote:SetJustifyH("LEFT")
    A:SetScript("OnShow", function() Config.RefreshAlerts() end)
end

function Config.RefreshAlerts()
    if not (W.alertsPage and W.alertsPage:IsShown()) then return end
    local s = ns.CombatAlerts.Settings(); if not s then return end
    refreshing = true
    W.alAspect:SetChecked(s.aspect)
    W.alPackGroup:SetChecked(s.packGroup)
    W.alPackOnMe:SetChecked(s.packOnMe)
    W.alAspectSound.value:SetText(ns.Sounds.Label(s.aspectSound))
    W.alPackAnnounce.value:SetText(s.packAnnounce == "off" and "Off" or (CHANNEL_LABEL[s.packAnnounce] or s.packAnnounce))
    W.alCare:SetChecked(s.care)
    for k, c in pairs(W.alKinds) do c:SetChecked(s[k]) end
    W.alChannel.value:SetText(CHANNEL_LABEL[s.careChannel] or s.careChannel)
    W.alCareSound.value:SetText(ns.Sounds.Label(s.careSound))
    W.alDelay:SetText(tostring(s.careDelay))
    local caps = ns.CombatAlerts.ComputeCaps()
    local names = {}
    for kind, letter in pairs(ns.CombatAlerts.CAP_LETTER) do
        if caps:find(letter, 1, true) then names[#names + 1] = ns.CombatAlerts.TYPE_LABEL[kind] end
    end
    table.sort(names)
    W.alCaps:SetText("Your character can fix: " .. (#names > 0 and table.concat(names, ", ") or "nothing on the list (no cure or resurrection spell found)")
        .. (ns.CombatAlerts.IsHunter() and "   |   Hunter: aspect warnings active" or ""))
    refreshing = false
end

-- Tabs -----------------------------------------------------------------------
local activeTab = "reminders"
-- Switch between the "reminders" and "profiles" tabs.
function Config.ShowTab(tab)
    activeTab = tab
    if not W.page then return end
    if ns.Picker then ns.Picker.Hide() end
    W.page:Hide(); W.profPage:Hide(); W.groupPage:Hide(); W.alertsPage:Hide()
    if W.tabProfiles.SetEnabled then
        W.tabReminders:SetEnabled(tab ~= "reminders" and tab ~= nil)
        W.tabProfiles:SetEnabled(tab ~= "profiles")
        W.tabGroup:SetEnabled(tab ~= "group")
        W.tabAlerts:SetEnabled(tab ~= "alerts")
    end
    if tab == "profiles" then
        W.profPage:Show(); Config.RefreshProfiles()
    elseif tab == "group" then
        W.groupPage:Show(); Config.RefreshGroup()
    elseif tab == "alerts" then
        W.alertsPage:Show(); Config.RefreshAlerts()
    else
        W.page:Show(); Config.Refresh()
    end
end

-- Group tab (Group Sync, 0.8.0) -----------------------------------------------------
local GROUP_ROWS = 15
local groupOffset, groupTicking = 0, false

function Config.BuildGroup(parent)
    local G = CreateFrame("Frame", nil, parent)
    G:SetAllPoints(); G:Hide()
    W.groupPage = G
    label(G, "Group sync", 14, -44, "GameFontNormalLarge")
    local d = label(G, "See the running timers of groupmates who also use Skwirlert (e.g. Soulstone, key buffs), and share yours. Updates are sent only when something changes, merged, never on a timer. Players don't see these messages.", 14, -66, "GameFontHighlightSmall")
    d:SetWidth(710); d:SetJustifyH("LEFT")

    label(G, "Communication", 14, -110)
    W.syncMode = cycler(G, 150, -110, 210, function(dir)
        local s = ns.Sync.Settings(); if not s then return end
        local idx = 1
        for i, k in ipairs(ns.Sync.MODES) do if k == s.mode then idx = i end end
        s.mode = ns.Sync.MODES[((idx - 1 + dir) % #ns.Sync.MODES) + 1]
        ns.Sync.OnSettingsChanged(); Config.RefreshGroup()
    end)
    W.syncModeHint = label(G, "", 370, -114, "GameFontDisableSmall"); W.syncModeHint:SetWidth(280); W.syncModeHint:SetJustifyH("LEFT")
    info(G, 128, -111, "Communication", "Share and receive: groupmates who use Skwirlert see your running timers, and you see theirs.\nReceive only: see theirs, send nothing.\nOff: send nothing, ignore everything.")
    label(G, "Update frequency", 14, -140)
    W.syncFreq = cycler(G, 150, -140, 210, function(dir)
        local s = ns.Sync.Settings(); if not s then return end
        local idx = 1
        for i, k in ipairs(ns.Sync.FREQS) do if k == s.freq then idx = i end end
        s.freq = ns.Sync.FREQS[((idx - 1 + dir) % #ns.Sync.FREQS) + 1]
        ns.Sync.OnSettingsChanged(); Config.RefreshGroup()
    end)
    W.syncFreqHint = label(G, "", 370, -144, "GameFontDisableSmall"); W.syncFreqHint:SetWidth(280); W.syncFreqHint:SetJustifyH("LEFT")
    info(G, 128, -141, "Update frequency", "The shortest gap between your updates. Updates are only sent when something changes, and changes in between are merged. Low (15 s) is plenty for almost everyone.")
    W.syncNoCombat = check(G, "Don't send during combat (send when combat ends)", 12, -168, function(v)
        local s = ns.Sync.Settings(); if s then s.noCombat = v; ns.Sync.OnSettingsChanged() end
    end)
    info(G, 340, -170, "Don't send during combat", "Holds your updates until the fight ends, so nothing is sent mid-combat. Recommended.")
    W.syncStatus = label(G, "", 14, -200, "GameFontHighlight")

    local list = CreateFrame("Frame", nil, G, BACKDROP)
    list:SetPoint("TOPLEFT", 12, -220); list:SetSize(716, GROUP_ROWS * 18 + 10)
    if list.SetBackdrop then
        list:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8" }); list:SetBackdropColor(0, 0, 0, 0.4)
    end
    list:EnableMouseWheel(true)
    list:SetScript("OnMouseWheel", function(_, delta) groupOffset = math.max(0, groupOffset - delta); Config.RefreshGroup() end)
    W.groupRows = {}
    for i = 1, GROUP_ROWS do
        local fs = list:CreateFontString(nil, "OVERLAY", "GameFontHighlightLeft")
        fs:SetPoint("TOPLEFT", 8, -5 - (i - 1) * 18); fs:SetWidth(620)
        if fs.SetWordWrap then fs:SetWordWrap(false) end
        W.groupRows[i] = fs
    end
    -- 0.9.2: login line and update notice (account-wide settings).
    W.loginMsg = check(G, "Show a \"Skwirlert loaded\" line in chat at login", 12, -514, function(v) ns.sv.loginMessage = v end)
    info(G, 340, -516, "Loaded line", "One chat line at login saying Skwirlert is loaded and how to open the settings. Applies to all your characters.")
    W.updateCheck = check(G, "Tell me when a newer Skwirlert is around (guild, group, friends)", 12, -538, function(v) ns.sv.updateCheck = v end)
    info(G, 400, -540, "Newer version notice", "Addons can't reach the internet, so Skwirlert compares versions with your guild, group and online friends: one tiny hidden message at login (whispered to friends; they never see it), and anyone with a newer version answers once. Once seen, the notice appears instantly at every login until you update. You then get one chat line naming the new version. Off also when Communication is set to Off.")
    G:SetScript("OnShow", function() Config.RefreshGroup() end)
end

local MODE_HINT = {
    share = "Your running timers are shared with your group; theirs are shown here.",
    receive = "You see groupmates' timers; nothing about you is sent.",
    off = "No messages are sent or received.",
}

-- Lines for the Group tab list: one per player, then one per timer.
local function groupLines()
    local lines = {}
    for _, p in ipairs(ns.Sync.Snapshot()) do
        lines[#lines + 1] = "|cffffd100" .. p.player .. "|r  |cff888888Skwirlert " .. (p.version or "?") .. "|r"
        if #p.entries == 0 then lines[#lines + 1] = "     |cff888888no running timers|r" end
        for _, e in ipairs(p.entries) do
            local tag = e.kind == "v" and "" or (e.kind == "t" and " |cff888888(timer)|r" or " |cff888888(est.)|r")
            lines[#lines + 1] = string.format("     %s%s  -  %s left%s", e.name, e.recipient and (" on " .. e.recipient) or "",
                ns.FormatDuration(e.expiresAt - GetTime()), tag)
        end
    end
    return lines
end
Config.GroupLines = groupLines

function Config.RefreshGroup()
    if not (W.groupPage and W.groupPage:IsShown()) then return end
    local s = ns.Sync.Settings(); if not s then return end
    W.syncMode.value:SetText(ns.Sync.MODE_LABEL[s.mode])
    W.syncModeHint:SetText(MODE_HINT[s.mode])
    W.syncFreq.value:SetText(ns.Sync.FREQ_LABEL[s.freq])
    W.syncFreqHint:SetText(string.format("At most one update every %d s; changes in between are merged.", ns.Sync.FREQ_GAP[s.freq]))
    W.syncNoCombat:SetChecked(s.noCombat)
    W.loginMsg:SetChecked(ns.sv.loginMessage ~= false)
    W.updateCheck:SetChecked(ns.sv.updateCheck ~= false)
    local channel = ns.Sync.Channel()
    W.syncStatus:SetText(not channel and "Not in a group." or
        string.format("In %s: %d other player(s) running Skwirlert.", channel == "RAID" and "a raid" or "a group", ns.Sync.PeerCount()))
    local lines = groupLines()
    groupOffset = math.max(0, math.min(groupOffset, math.max(0, #lines - GROUP_ROWS)))
    for i, fs in ipairs(W.groupRows) do fs:SetText(lines[i + groupOffset] or "") end
    -- Count down once a second while this tab is open (a scheduled timer, not OnUpdate).
    if not groupTicking then
        groupTicking = true
        ns.After("group tab", 1, function() groupTicking = false; Config.RefreshGroup() end)
    end
end

-- Called after a profile switch/copy/reset/rename: reset selection and redraw.
function Config.OnProfileChanged()
    selectedId, scrollOffset = nil, 0
    if ns.Picker then ns.Picker.Hide() end
    if win and win:IsShown() then
        Config.Refresh()
        Config.RefreshProfiles()
        Config.RefreshAlerts()
    end
end

-- Profiles page --------------------------------------------------------------
local PROF_ROWS = 14
local profSel, profOffset = nil, 0

-- Two-click confirmation for destructive buttons: the first click changes the
-- label to "Click again to confirm" for 4 seconds; the second click runs fn.
local function armed(btn, text, fn)
    -- two-click confirmation for destructive actions
    if btn.armed then
        btn.armed = false; btn:SetText(text); fn()
    else
        btn.armed = true; btn:SetText("Click again to confirm")
        ns.After("Config", 4, function() btn.armed = false; btn:SetText(text) end)
    end
end

-- Print a result message (errors in red).
local function report(ok, msg) if msg then ns.Print(ok and msg or ("|cffff6060" .. msg .. "|r")) end end

-- Build the Profiles tab (profile list, actions, Share section).
function Config.BuildProfiles(parent)
    local P = CreateFrame("Frame", nil, parent)
    P:SetAllPoints()
    P:Hide()
    W.profPage = P
    label(P, "Profiles", 14, -44, "GameFontNormalLarge")
    local desc = label(P, "Each character gets its own profile, saved automatically on logout. You can use another character's profile, copy it into yours, or start fresh. |cffffd100Default|r is always available and starts empty.", 14, -66, "GameFontHighlightSmall")
    desc:SetWidth(710); desc:SetJustifyH("LEFT")
    W.profChar = label(P, "", 14, -96, "GameFontHighlight")
    W.profActive = label(P, "", 14, -114, "GameFontHighlight")

    label(P, "Existing profiles", 14, -140)
    info(P, 128, -138, "Profiles", "Each character has its own profile. Click a profile in the list, then use the buttons on the right. Hover a profile to see which characters use it.")
    local list = CreateFrame("Frame", nil, P, BACKDROP)
    list:SetPoint("TOPLEFT", 12, -158)
    list:SetSize(300, PROF_ROWS * ROW_H + 8)
    if list.SetBackdrop then
        list:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8" })
        list:SetBackdropColor(0, 0, 0, 0.4)
    end
    list:EnableMouseWheel(true)
    list:SetScript("OnMouseWheel", function(_, delta)
        profOffset = math.max(0, math.min(math.max(0, #ns.Profiles.List() - PROF_ROWS), profOffset - delta))
        Config.RefreshProfiles()
    end)
    W.profRows = {}
    for i = 1, PROF_ROWS do
        local b = CreateFrame("Button", nil, list)
        b:SetSize(292, ROW_H)
        b:SetPoint("TOPLEFT", 4, -4 - (i - 1) * ROW_H)
        b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightLeft")
        b.text:SetPoint("LEFT", 4, 0); b.text:SetPoint("RIGHT", -4, 0)
        if b.text.SetWordWrap then b.text:SetWordWrap(false) end
        b.hl = b:CreateTexture(nil, "BACKGROUND")
        b.hl:SetAllPoints(); b.hl:SetColorTexture(1, 0.82, 0, 0.25); b.hl:Hide()
        b:SetScript("OnClick", function(self) if self.pname then profSel = self.pname; Config.RefreshProfiles() end end)
        b:SetScript("OnEnter", function(self)
            local tip = _G.GameTooltip
            if not (self.pname and tip) then return end
            tip:SetOwner(self, "ANCHOR_RIGHT")
            tip:AddLine(self.pname)
            local p = ns.sv.profiles[self.pname]
            tip:AddLine((p and #p.reminders or 0) .. " reminders", 1, 1, 1)
            local users = ns.Profiles.UsedBy(self.pname)
            tip:AddLine(#users > 0 and ("Used by: " .. table.concat(users, ", ")) or "Not used by any character", 0.7, 0.7, 0.7, true)
            tip:Show()
        end)
        b:SetScript("OnLeave", function() if _G.GameTooltip then GameTooltip:Hide() end end)
        W.profRows[i] = b
    end

    local X = 330
    W.profSelLabel = label(P, "", X, -158, "GameFontNormal")
    W.profSelLabel:SetWidth(315); W.profSelLabel:SetJustifyH("LEFT")
    if W.profSelLabel.SetWordWrap then W.profSelLabel:SetWordWrap(false) end
    W.profUse = button(P, "Use this profile", 200, X, -180, function()
        if profSel then report(ns.Profiles.Use(profSel)); Config.RefreshProfiles() end
    end)
    W.profCopy = button(P, "Copy into current profile", 200, X, -206, function(self)
        if not profSel then return end
        armed(self, "Copy into current profile", function()
            local ok, err = ns.Profiles.CopyFrom(profSel)
            report(ok, ok and ("copied '" .. profSel .. "' into '" .. ns.Profiles.Current() .. "'") or err)
            Config.RefreshProfiles()
        end)
    end)
    W.profDelete = button(P, "Delete profile", 200, X, -232, function(self)
        if not profSel then return end
        armed(self, "Delete profile", function()
            local name = profSel
            local ok, err = ns.Profiles.Delete(name)
            report(ok, ok and ("deleted profile '" .. name .. "'") or err)
            if ok then profSel = nil end
            Config.RefreshProfiles()
        end)
    end)

    label(P, "Profile name (Create a new one, or Rename the selected one)", X, -268, "GameFontNormalSmall")
    W.profNewName = edit(P, 150, X - 6, -286, function() end)
    W.profRename = button(P, "Rename", 70, X + 224, -286, function()
        if not profSel then return end
        local old = profSel
        local ok, err = ns.Profiles.Rename(old, W.profNewName:GetText())
        if ok then profSel = W.profNewName:GetText():gsub("|", ""):gsub("^%s+", ""):gsub("%s+$", "") end
        report(ok, ok and ("renamed '" .. old .. "' to '" .. profSel .. "'") or err)
        if ok then W.profNewName:SetText("") end
        Config.RefreshProfiles()
    end)
    W.profCreate = button(P, "Create", 64, X + 156, -286, function()
        local ok, err = ns.Profiles.Create(W.profNewName:GetText())
        report(ok, ok and ("created and switched to '" .. ns.Profiles.Current() .. "'") or err)
        if ok then W.profNewName:SetText("") end
        Config.RefreshProfiles()
    end)
    info(P, X + 206, -182, "Use / Copy / Delete", "Use: this character switches to the selected profile (shared with the other characters using it).\nCopy: copies the selected profile's reminders and settings into yours (click twice).\nDelete: removes the selected profile (click twice; not the one in use).")
    info(P, X + 300, -288, "Create / Rename", "Type a name, then Create for a new empty profile, or Rename to rename the selected profile.")
    W.profReset = button(P, "Reset current profile", 200, X, -318, function(self)
        armed(self, "Reset current profile", function()
            ns.Profiles.Reset()
            report(true, "profile '" .. ns.Profiles.Current() .. "' is now empty")
            Config.RefreshProfiles()
        end)
    end)
    local rh = label(P, "Removes every reminder from the profile you're using.", X, -344, "GameFontDisableSmall")
    rh:SetWidth(300); rh:SetJustifyH("LEFT")

    -- Share (export / import) ---------------------------------------------------
    local line = P:CreateTexture(nil, "ARTWORK")
    line:SetColorTexture(1, 0.82, 0, 0.3)
    line:SetPoint("TOPLEFT", 12, -462); line:SetSize(716, 1)
    label(P, "Share a profile", 14, -472)
    info(P, 120, -470, "Share a profile", "Export makes a code you can send to a friend or another account (Ctrl+C to copy). To import, paste a code, give it a name and click Import: it becomes a new profile; nothing of yours is replaced.")
    local sh = label(P, "Export makes a code for your current profile: press Ctrl+C and send it (Discord, email; in-game chat is too short). To import, paste a code, name it, and click Import. It becomes a new profile.", 14, -490, "GameFontHighlightSmall")
    sh:SetWidth(710); sh:SetJustifyH("LEFT")
    W.shareBox = edit(P, 700, 8, -524, function() end)
    W.shareBox:SetMaxLetters(0)
    W.shareBox:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
    W.shareExport = button(P, "Export current profile", 170, 12, -552, function()
        local code, n = ns.Share.Export()
        W.shareBox:SetText(code or "")
        W.shareBox:SetFocus(); W.shareBox:HighlightText()
        report(true, string.format("exported '%s' (%d reminders). Press Ctrl+C to copy.", ns.Profiles.Current(), n or 0))
    end)
    label(P, "Import as:", 196, -556)
    W.shareName = edit(P, 160, 262, -552, function() end)
    W.shareImport = button(P, "Import", 80, 440, -552, function()
        local ok, name, n, skipped = ns.Share.Import(W.shareBox:GetText(), W.shareName:GetText())
        if ok then
            report(true, string.format("imported %d reminders into new profile '%s'%s", n, name,
                skipped > 0 and (" (" .. skipped .. " over the limit were skipped)") or ""))
            W.shareBox:SetText(""); W.shareName:SetText("")
            Config.ShowTab("reminders")
        else
            report(false, "import failed: " .. tostring(name))
        end
    end)
    W.shareClear = button(P, "Clear", 60, 526, -552, function() W.shareBox:SetText(""); W.shareName:SetText("") end)
end

-- Redraw the Profiles tab from saved data.
function Config.RefreshProfiles()
    if not (W.profPage and W.profPage:IsShown()) then return end
    local names = ns.Profiles.List()
    local cur = ns.Profiles.Current()
    if profSel and not ns.Profiles.Exists(profSel) then profSel = nil end
    profSel = profSel or cur
    profOffset = math.max(0, math.min(profOffset, math.max(0, #names - PROF_ROWS)))
    W.profChar:SetText("Character: |cffffffff" .. ns.charName .. "|r  |cff888888(" .. tostring(ns.realmName) .. ")|r")
    W.profActive:SetText("Active profile: |cff40ff40" .. cur .. "|r")
    W.profileLabel:SetText("Profile: |cffffffff" .. cur .. "|r")
    for i, row in ipairs(W.profRows) do
        local name = names[i + profOffset]
        if name then
            row.pname = name
            local p = ns.sv.profiles[name]
            local tag = (name == cur) and " |cff40ff40(in use)|r" or ""
            row.text:SetText(name .. tag .. " |cff999999- " .. (p and #p.reminders or 0) .. "|r")
            if name == profSel then row.hl:Show() else row.hl:Hide() end
            row:Show()
        else
            row.pname = nil
            row:Hide()
        end
    end
    W.profSelLabel:SetText("Selected: |cffffffff" .. profSel .. "|r")
    local isCur = profSel == cur
    if W.profUse.SetEnabled then
        W.profUse:SetEnabled(not isCur)
        W.profCopy:SetEnabled(not isCur)
        W.profDelete:SetEnabled(not isCur and profSel ~= ns.DEFAULT_PROFILE)
        W.profRename:SetEnabled(profSel ~= ns.DEFAULT_PROFILE)
    end
end

-- Called by the engine when timers change; updates icons/status without
-- touching the editor fields (so typing is never overwritten).
local liveQueued = false
-- Called by the engine whenever timers change. Batches updates (0.1 s) and
-- only redraws the list/status, never the text boxes.
function Config.RefreshLiveSoon()
    if not (win and win:IsShown()) or liveQueued then return end
    liveQueued = true
    ns.After("Config", 0.1, function()
        liveQueued = false
        if win and win:IsShown() then renderList() end
    end)
end

-- Open or close the window (builds it on first use). Bound to /skwirlert.
function Config.Toggle()
    if not win then build() end
    if ns.Picker then ns.Picker.Hide() end
    if not win:IsShown() then
        win:Show()
        Config.ShowTab(activeTab)
        return
    end
    if win:IsShown() then win:Hide() else win:Show() end
end

-- Select a reminder and scroll the list so it's visible.
function Config.Select(id)
    selectedId = id
    for i, r in ipairs(ns.db.reminders) do
        if r.id == id then
            if i <= scrollOffset then scrollOffset = i - 1
            elseif i > scrollOffset + ROWS then scrollOffset = i - ROWS end
        end
    end
    Config.Refresh()
end
-- Widgets table and window (used by other files and tests).
function Config.Widgets() return W, win end

ns.RegisterInit(function()
    ns.Popup.Init()
    -- Optional entry in the game's AddOns settings list, when the API exists.
    local S = _G.Settings
    if S and S.RegisterCanvasLayoutCategory and S.RegisterAddOnCategory then
        pcall(function()
            local panel = CreateFrame("Frame")
            local ic = panel:CreateTexture(nil, "ARTWORK")
            ic:SetSize(32, 32); ic:SetPoint("TOPLEFT", 16, -12); ic:SetTexture(ns.ICON)
            local t = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
            t:SetPoint("TOPLEFT", 56, -18); t:SetText("Skwirlert")
            local b = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
            b:SetSize(180, 24); b:SetPoint("TOPLEFT", 16, -50); b:SetText("Open Skwirlert settings")
            b:SetScript("OnClick", function()
                if _G.SettingsPanel and SettingsPanel.Close then pcall(SettingsPanel.Close, SettingsPanel, true) end
                if not (win and win:IsShown()) then Config.Toggle() end
            end)
            local cat = S.RegisterCanvasLayoutCategory(panel, "Skwirlert")
            S.RegisterAddOnCategory(cat)
        end)
    end
end)
