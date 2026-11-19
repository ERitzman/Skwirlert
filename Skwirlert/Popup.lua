-- =============================================================================
-- Skwirlert - Popup.lua  (the movable yellow alert box)
-- =============================================================================
-- WHAT THIS FILE DOES
--   Shows alert text in a yellow-bordered box near the top of the screen. Up to
--   4 lines stack; each disappears after the profile's popup duration
--   (default 2 s). When unlocked (/skwirlert unlock) it can be dragged, and its
--   position is saved in the profile.
--
-- WOW CONCEPTS
--   * Frames: CreateFrame("Frame", name, parent, template). "BackdropTemplate"
--     gives a frame SetBackdrop (background + border).
--   * Positions are anchors: SetPoint(point, relativeTo, relativePoint, x, y).
--   * Dragging: SetMovable + RegisterForDrag + StartMoving/StopMovingOrSizing.
--   * `local CreateFrame = ns.SafeFrameFactory(...)` (below) wraps every script
--     handler with error capture; see Core.lua.
-- =============================================================================

local _, ns = ...
local CreateFrame = ns.SafeFrameFactory("Popup")  -- wraps script handlers with error capture
local Popup = {}
ns.Popup = Popup

local MAX_LINES = 4
local lines = {}   -- { text=, timer= }
local frame

-- Store the box's current anchor in the profile after dragging.
local function savePosition()
    local point, _, relPoint, x, y = frame:GetPoint(1)
    local p = ns.db.popup
    p.point, p.relPoint, p.x, p.y = point or "TOP", relPoint or "TOP", x or 0, y or -180
end

-- Move the box to the anchor saved in the profile.
local function applyPosition()
    local p = ns.db.popup
    frame:ClearAllPoints()
    frame:SetPoint(p.point or "TOP", UIParent, p.relPoint or "TOP", p.x or 0, p.y or -180)
end

-- Redraw the box from the current lines (hide it when empty and locked).
local function render()
    if not frame then return end
    local locked = ns.db.popup.locked
    if #lines == 0 and locked then frame:Hide(); return end
    local parts = {}
    for _, l in ipairs(lines) do parts[#parts + 1] = l.text end
    if #parts == 0 then parts[1] = "Skwirlert popup - drag to move" end
    frame.text:SetText(table.concat(parts, "\n"))
    local h = frame.text:GetStringHeight() or 24
    local w = frame.text:GetStringWidth() or 200
    frame:SetHeight(math.max(44, h + 24))
    frame:SetWidth(math.max(260, math.min(640, w + 40)))
    frame:SetAlpha(1)
    frame:Show()
end

-- Build the frame once, the first time it's needed.
local function create()
    if frame then return end
    frame = CreateFrame("Frame", "SkwirlertPopup", UIParent, _G.BackdropTemplateMixin and "BackdropTemplate" or nil)
    frame:SetFrameStrata("HIGH")
    frame:SetSize(300, 50)
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:RegisterForDrag("LeftButton")
    if frame.SetBackdrop then
        frame:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Buttons\\WHITE8x8",
            edgeSize = 2,
        })
        frame:SetBackdropColor(0.10, 0.08, 0.0, 0.85)
        frame:SetBackdropBorderColor(1, 0.85, 0.0, 1)
    end
    frame.text = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
    frame.text:SetPoint("CENTER")
    frame.text:SetTextColor(1, 0.9, 0.1)
    frame.text:SetJustifyH("CENTER")
    frame:SetScript("OnDragStart", function(self)
        if not ns.db.popup.locked then self:StartMoving() end
    end)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        savePosition()
    end)
    applyPosition()
    frame:Hide()
end

-- Called at start-up: create the box and apply the saved lock state.
function Popup.Init()
    create()
    Popup.SetLocked(ns.db.popup.locked)
end

-- Show one alert line for `duration` seconds (default: the profile's popup secs).
function Popup.Show(text, duration)
    create()
    duration = tonumber(duration) or tonumber(ns.db.popup.duration) or 2
    if duration < 0.5 then duration = 0.5 end
    local entry = { text = text }
    table.insert(lines, entry)
    while #lines > MAX_LINES do
        local old = table.remove(lines, 1)
        if old.timer then old.timer:Cancel() end
    end
    entry.timer = ns.NewTimer("Popup", duration, function()
        for i, l in ipairs(lines) do
            if l == entry then table.remove(lines, i); break end
        end
        render()
    end)
    render()
end

-- Lock (click-through) or unlock (draggable, shows a placeholder line).
function Popup.SetLocked(locked)
    create()
    ns.db.popup.locked = locked and true or false
    frame:EnableMouse(not locked)
    render()
end

-- Re-apply position/lock after a profile switch.
function Popup.Reload()
    create()
    for i = #lines, 1, -1 do
        if lines[i].timer then lines[i].timer:Cancel() end
        lines[i] = nil
    end
    applyPosition()
    Popup.SetLocked(ns.db.popup.locked)
end

-- Put the box back at its default position.
function Popup.ResetPosition()
    create()
    ns.db.popup.point, ns.db.popup.relPoint, ns.db.popup.x, ns.db.popup.y = "TOP", "TOP", 0, -180
    applyPosition()
end

-- The frame itself (used by tests).
function Popup.Frame() return frame end
