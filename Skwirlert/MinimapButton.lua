-- =============================================================================
-- Skwirlert - MinimapButton.lua  (the squirrel button on the minimap)
-- =============================================================================
-- WHAT THIS FILE DOES
--   A round button on the minimap edge showing the Skwirlert icon.
--     Left-click         open/close the settings window
--     Shift+left-click   Refresh and Monitor (scan current buffs, open settings)
--     Right-click        Pause Monitoring dialog
--     Drag               move it around the minimap edge
--   Position (angle) and visibility are saved per profile:
--     <profile>.minimap = { hide = false, angle = 200 }
--   /skwirlert minimap show | hide | reset brings it back if hidden.
--
-- WOW CONCEPTS
--   * Minimap buttons are ordinary Buttons parented to the Minimap frame and
--     anchored at (cos a, sin a) * radius from its centre.
--   * Dragging: the frame moves freely with StartMoving(); when released we
--     compute the angle from the minimap centre and snap back onto the ring.
--     No OnUpdate is used.
--   * RegisterForClicks("LeftButtonUp", "RightButtonUp") enables right-clicks.
-- =============================================================================

local _, ns = ...
local CreateFrame = ns.SafeFrameFactory("MinimapButton")   -- wraps script handlers with error capture
local MB = {}
ns.Minimap = MB

local atan2 = math.atan2 or function(y, x) return math.atan(y, x) end   -- WoW (Lua 5.1) has math.atan2
local btn
local RADIUS_PAD = 5     -- distance outside the minimap's edge

local function settings() return ns.db and ns.db.minimap end

local function place()
    local s = settings()
    if not (btn and s and _G.Minimap) then return end
    local w = (Minimap.GetWidth and Minimap:GetWidth()) or 140
    local r = w / 2 + RADIUS_PAD
    local a = math.rad(s.angle or 200)
    btn:ClearAllPoints()
    btn:SetPoint("CENTER", Minimap, "CENTER", math.cos(a) * r, math.sin(a) * r)
end

-- Angle (degrees) of a screen point around the minimap centre.
local function angleFrom(x, y)
    local mx, my = Minimap:GetCenter()
    if not (mx and x) then return nil end
    return math.deg(atan2(y - my, x - mx)) % 360
end

local function tooltip(self)
    local tip = _G.GameTooltip
    if not tip then return end
    tip:SetOwner(self, "ANCHOR_LEFT")
    tip:AddLine("Skwirlert")
    local total, running = 0, 0
    if ns.db then
        for _, r in ipairs(ns.db.reminders) do
            if r.enabled then total = total + 1 end
            if ns.Engine:Running(r.id) then running = running + 1 end
        end
    end
    tip:AddLine(string.format("Reminders: %d active, %d running", total, running), 1, 1, 1)
    tip:AddLine("Monitoring: " .. ((ns.db and ns.db.enabled) and "|cff40ff40on|r" or "|cffff6060off|r"), 1, 1, 1)
    local paused = ns.Pause and ns.Pause.IsPaused()
    tip:AddLine("Pause: " .. (paused and ("|cffffd100" .. ns.Pause.Describe() .. "|r") or "|cff40ff40not paused|r"), 1, 1, 1)
    if ns.Sync and ns.Sync.Channel() and ns.Sync.Settings() and ns.Sync.Settings().mode ~= "off" then
        local snap = ns.Sync.Snapshot()
        tip:AddLine(string.format("Group: %d other player(s) with Skwirlert", #snap), 1, 1, 1)
        local shown = 0
        for _, p in ipairs(snap) do
            for _, e in ipairs(p.entries) do
                if shown < 6 then
                    tip:AddLine(string.format("   %s: %s%s %s", p.player, e.name, e.recipient and (" on " .. e.recipient) or "",
                        ns.FormatDuration(e.expiresAt - GetTime())), 0.85, 0.85, 0.85)
                    shown = shown + 1
                end
            end
        end
    end
    tip:AddLine(" ")
    tip:AddLine("Left-click: settings", 0.7, 0.7, 0.7)
    tip:AddLine("Shift+left-click: refresh current buffs", 0.7, 0.7, 0.7)
    tip:AddLine("Right-click: pause monitoring", 0.7, 0.7, 0.7)
    tip:AddLine("Drag: move", 0.7, 0.7, 0.7)
    tip:Show()
end

local function create()
    if btn or not _G.Minimap then return end
    btn = CreateFrame("Button", "SkwirlertMinimapButton", Minimap)
    btn:SetSize(31, 31)
    btn:SetFrameStrata("MEDIUM")
    btn:SetFrameLevel(8)
    btn:SetMovable(true)
    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    btn:RegisterForDrag("LeftButton")
    btn:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    local bg = btn:CreateTexture(nil, "BACKGROUND")
    bg:SetSize(20, 20); bg:SetPoint("CENTER", 0, 1)
    bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    btn.icon = btn:CreateTexture(nil, "ARTWORK")
    btn.icon:SetSize(19, 19); btn.icon:SetPoint("CENTER", 0, 1)
    btn.icon:SetTexture(ns.ICON)
    local border = btn:CreateTexture(nil, "OVERLAY")
    border:SetSize(53, 53); border:SetPoint("TOPLEFT")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    btn:SetScript("OnClick", function(self, mouse)
        if mouse == "RightButton" then
            ns.Pause.ShowDialog()
        elseif _G.IsShiftKeyDown and IsShiftKeyDown() then
            ns.Picker.RefreshAll(true)
        else
            ns.Config.Toggle()
        end
        if _G.GameTooltip and GameTooltip:IsOwned(self) then tooltip(self) end
    end)
    btn:SetScript("OnDragStart", function(self) self:StartMoving() end)
    btn:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local x, y = self:GetCenter()
        local a = angleFrom(x, y)
        if a and settings() then settings().angle = a end
        place()                                  -- snap back onto the ring
    end)
    btn:SetScript("OnEnter", tooltip)
    btn:SetScript("OnLeave", function() if _G.GameTooltip then GameTooltip:Hide() end end)
end

-- Show/hide and position from the current profile.
function MB.Reload()
    create()
    if not btn then return end
    local s = settings()
    if s and s.hide then btn:Hide() else btn:Show(); place() end
end

function MB.SetShown(show)
    local s = settings(); if not s then return end
    s.hide = not show
    MB.Reload()
end

function MB.ResetPosition()
    local s = settings(); if not s then return end
    s.angle = 200; s.hide = false
    MB.Reload()
end

-- Update the tooltip if it is open (pause changes, etc.).
function MB.Refresh()
    if btn and _G.GameTooltip and GameTooltip.IsOwned and GameTooltip:IsOwned(btn) then tooltip(btn) end
end

function MB.Button() return btn end

ns.RegisterInit(function() MB.Reload() end)
