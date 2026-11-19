-- =============================================================================
-- Skwirlert - Core.lua
-- =============================================================================
-- WHAT THIS FILE DOES
--   The foundation every other file builds on:
--     1. The addon namespace (`ns`) shared by all files.
--     2. Saved settings (SavedVariables) and PROFILES (one per character, plus
--        Default; characters can share, copy, rename and reset profiles).
--     3. Reminder storage helpers (add, find, delete, normalise).
--     4. Diagnostics: error capture with stack traces, the optional activity
--        log, and "safe" wrappers for events, timers and UI scripts.
--     5. The event dispatcher, and start-up at PLAYER_LOGIN.
--
-- WOW CONCEPTS FOR BEGINNERS
--   * `local ADDON, ns = ...`  WoW passes every file of an addon two values:
--     the addon's folder name and a private table that ALL files of the addon
--     share. Putting things on `ns` lets files talk to each other without
--     polluting the global namespace.
--   * SavedVariables: the TOC line `## SavedVariables: SkwirlertDB` tells WoW
--     to write the global table `SkwirlertDB` to disk on logout/reload and
--     load it again before ADDON_LOADED. Anything not stored there is lost.
--   * Events: WoW calls a frame's OnEvent script when something happens
--     (PLAYER_LOGIN, UNIT_AURA, ...). One hidden frame here receives all events
--     and hands them to the functions registered with ns.On().
--   * Errors: a Lua error inside an event handler normally stops that handler
--     and shows a popup. Every handler here runs through ns.XCall(), which
--     catches the error, records where it happened plus a stack trace, and
--     keeps the rest of the addon running.
--
-- SAVED DATA LAYOUT (dbVersion 3)
--   SkwirlertDB = {
--     dbVersion   = 3,
--     profiles    = { ["Default"] = <profile>, ["Name (US-PvE)"] = <profile> },
--     profileKeys = { [<character id>] = "<profile name in use>" },
--     chars       = { [<character id>] = { name = "Name (US-PvE)", active = {...} } },
--     errors      = { up to 25 captured errors },
--     diagnostics = true/false,
--   }
--   <profile> = { reminders = {}, nextId, enabled, debug, channel, popup = {...} }
--   * The character id is the character's GUID: unique even when first names
--     repeat under WoW Forever's two-name system.
--   * `ns.db` always points at the CURRENT character's profile, `ns.char` at
--     its per-character data. Running timers live in ns.char (not the profile),
--     so two characters sharing a profile never share timers.
--
-- REMINDER FIELDS (see ns.NormalizeReminder)
--   id, name, kind ("self" = buff on me, "targeted" = buff I cast on others,
--   "timer" = manual/custom timer), spellIDs, names, learnedIDs, duration,
--   learnedDuration, warn (0-60 s; 0 = expiration alert only), warnSound,
--   expireSound, enabled, expireAlert, announce, announceApplied, announceWarn,
--   perMember (0.8.0: also track your copy on each group member).
--
-- Independently authored for ERitzFoto. No third-party code or libraries.
-- =============================================================================

-- The two values WoW passes to every addon file (see header).
local ADDON, ns = ...
ns.name = ADDON or "Skwirlert"
ns.version = "0.8.0-beta"
_G.Skwirlert = ns

local DB_VERSION = 3
local unpack = _G.unpack or table.unpack
-- Lua 5.1 (WoW) has no table.pack. This keeps the count of values so that
-- trailing nils survive an unpack(t, 1, t.n) round trip.
local function pack(...) return { n = select("#", ...), ... } end
ns.MAX_REMINDERS = 100            -- per profile
ns.DEFAULT_PROFILE = "Default"    -- always exists, starts empty
-- The addon icon (owner's shutter-squirrel on black). WoW finds the .tga itself;
-- texture paths are written without the file extension.
ns.ICON = "Interface\\AddOns\\Skwirlert\\Media\\SkwirlertIcon"

-- Deep copy of a table (used for profile copies and test fixtures).
local function copy(t)
    if type(t) ~= "table" then return t end
    local r = {}
    for k, v in pairs(t) do r[k] = copy(v) end
    return r
end
ns.copy = copy

-- Durations ------------------------------------------------------------------
-- Durations are stored in SECONDS everywhere. These two functions only change
-- how they are shown and typed:  30 -> "30s", 600 -> "10m", 1830 -> "30m30s",
-- 3600 -> "1h", 3690 -> "1h1m30s".
function ns.FormatDuration(sec)
    sec = math.floor((tonumber(sec) or 0) + 0.5)
    if sec <= 0 then return "0s" end
    local h = math.floor(sec / 3600)
    local m = math.floor((sec % 3600) / 60)
    local s = sec % 60
    local out = ""
    if h > 0 then out = out .. h .. "h" end
    if m > 0 then out = out .. m .. "m" end
    if s > 0 then out = out .. s .. "s" end
    return out
end

local UNIT_SECONDS = {
    h = 3600, hr = 3600, hrs = 3600, hour = 3600, hours = 3600,
    m = 60, min = 60, mins = 60, minute = 60, minutes = 60,
    s = 1, sec = 1, secs = 1, second = 1, seconds = 1,
}

-- Parse what a player types into seconds. Accepts:
--   "90" (plain number = seconds), "30s", "10m", "1h", "30m30s", "1h 30m",
--   "1.5h", "2 min", "10:00" (m:ss) and "1:30:00" (h:mm:ss). Case and spaces
-- are ignored. Returns whole seconds, or nil + a message for the player.
function ns.ParseDuration(text)
    if type(text) ~= "string" then return nil, "type a duration such as 30s, 10m or 1h" end
    local s = text:lower():gsub("%s+", "")
    if s == "" then return nil, "type a duration such as 30s, 10m or 1h" end
    if s:match("^%d+%.?%d*$") then return math.floor(tonumber(s) + 0.5) end
    local a, b, c = s:match("^(%d+):(%d%d):(%d%d)$")
    if a then
        if tonumber(b) > 59 or tonumber(c) > 59 then return nil, "minutes and seconds must be 00-59" end
        return tonumber(a) * 3600 + tonumber(b) * 60 + tonumber(c)
    end
    a, b = s:match("^(%d+):(%d%d)$")
    if a then
        if tonumber(b) > 59 then return nil, "seconds must be 00-59" end
        return tonumber(a) * 60 + tonumber(b)
    end
    local total, pos, found = 0, 1, false
    while pos <= #s do
        local num, unit, nextPos = s:match("^(%d+%.?%d*)(%a+)()", pos)
        if not num or not UNIT_SECONDS[unit] then
            return nil, "couldn't read '" .. text .. "'. Examples: 30s, 10m, 30m30s, 1h"
        end
        total = total + tonumber(num) * UNIT_SECONDS[unit]
        pos, found = nextPos, true
    end
    if not found then return nil, "couldn't read '" .. text .. "'" end
    return math.floor(total + 0.5)
end

-- Make a reminder safe to use: fill missing fields with defaults and clamp
-- numbers to valid ranges. Called on load, on add, and on import, so the
-- rest of the code can trust every field.
function ns.NormalizeReminder(r, id)
    r.id = r.id or id
    r.name = (type(r.name) == "string" and r.name ~= "") and r.name or ("Reminder " .. tostring(r.id))
    if r.kind ~= "self" and r.kind ~= "targeted" and r.kind ~= "timer" then r.kind = "self" end
    r.spellIDs = type(r.spellIDs) == "table" and r.spellIDs or {}
    r.names = type(r.names) == "table" and r.names or {}
    r.learnedIDs = type(r.learnedIDs) == "table" and r.learnedIDs or {}
    r.duration = tonumber(r.duration) or 1800
    if r.duration < 1 then r.duration = 1 end
    if r.duration > 86400 then r.duration = 86400 end
    r.warn = math.floor(tonumber(r.warn) or 30)
    if r.warn < 0 then r.warn = 0 elseif r.warn > 60 then r.warn = 60 end
    r.warnSound = r.warnSound or "quick-tone"
    r.expireSound = r.expireSound or "Uh Oh"
    if r.enabled == nil then r.enabled = true end
    r.builtin = nil   -- 0.5.0: nothing is built in any more
    if r.expireAlert == nil then r.expireAlert = true end
    local valid = { off = true, say = true, party = true, raid = true, group = true }
    if not valid[r.announce] then r.announce = "off" end
    if r.announceApplied == nil then r.announceApplied = true end
    if r.announceWarn == nil then r.announceWarn = true end
    r.perMember = (r.perMember and r.kind ~= "timer") and true or false
    return r
end

-- A brand-new profile: no reminders, default popup and sound settings.
local function emptyProfile()
    return {
        reminders = {},
        nextId = 1,
        enabled = true,
        debug = false,
        channel = "Master",
        popup = { duration = 2, locked = true, point = "TOP", relPoint = "TOP", x = 0, y = -180 },
        minimap = { hide = false, angle = 200 },   -- minimap button (0.7.0)
        sync = { mode = "share", freq = "low", noCombat = true },   -- Group Sync (0.8.0)
        -- Refresh / auto-add (0.8.0): skip buffs shorter than minDuration seconds;
        -- ignored = buffs you deleted, so Refresh doesn't add them back.
        refresh = { minDuration = 300, ignored = {} },
    }
end
ns.EmptyProfile = emptyProfile

-- Repair a profile loaded from disk: add missing settings, drop corrupted
-- reminder entries, and make sure nextId is above every existing id.
local function normalizeProfile(p)
    local d = emptyProfile()
    for k, v in pairs(d) do if p[k] == nil then p[k] = v end end
    if type(p.popup) ~= "table" then p.popup = d.popup end
    for k, v in pairs(d.popup) do if p.popup[k] == nil then p.popup[k] = v end end
    p.popup.duration = tonumber(p.popup.duration) or 2
    if type(p.minimap) ~= "table" then p.minimap = { hide = false, angle = 200 } end
    p.minimap.hide = p.minimap.hide and true or false
    p.minimap.angle = (tonumber(p.minimap.angle) or 200) % 360
    if type(p.sync) ~= "table" then p.sync = {} end
    local validMode = { share = true, receive = true, off = true }
    local validFreq = { low = true, normal = true, high = true }
    if not validMode[p.sync.mode] then p.sync.mode = "share" end
    if not validFreq[p.sync.freq] then p.sync.freq = "low" end
    if p.sync.noCombat == nil then p.sync.noCombat = true end
    if type(p.refresh) ~= "table" then p.refresh = {} end
    local md = tonumber(p.refresh.minDuration) or 300
    p.refresh.minDuration = math.max(0, math.min(86400, math.floor(md)))
    if type(p.refresh.ignored) ~= "table" then p.refresh.ignored = {} end
    if type(p.reminders) ~= "table" then p.reminders = {} end
    for i = #p.reminders, 1, -1 do   -- drop corrupted entries
        if type(p.reminders[i]) ~= "table" then table.remove(p.reminders, i) end
    end
    local maxId = 0
    for i, r in ipairs(p.reminders) do
        ns.NormalizeReminder(r, r.id or i)
        if r.id > maxId then maxId = r.id end
    end
    if (tonumber(p.nextId) or 0) <= maxId then p.nextId = maxId + 1 end
    return p
end

-- "CAMWOW US2 Realm 1 PvE" -> "US-PvE". Forever is realmless: one server per
-- region and ruleset, so region + ruleset identifies it. Falls back to the
-- full realm text if it doesn't look like that.
function ns.ShortRealm(realm)
    if type(realm) ~= "string" or realm == "" then return "?" end
    local tokens = {}
    for t in realm:gmatch("%S+") do tokens[#tokens + 1] = t end
    local region, regionIdx
    for i, t in ipairs(tokens) do
        local r = t:match("^(%a%a)%d*$")
        if r and t:upper() == t then region, regionIdx = r, i; break end
    end
    local ruleset = tokens[#tokens]
    if region and ruleset and #tokens > regionIdx and not ruleset:match("^%d+$") then
        return region .. "-" .. ruleset
    end
    return realm
end

-- Read the character's name, server name and GUID. Values are checked for
-- "secret" status (see Compat.lua) before use.
local function playerInfo()
    local name = _G.UnitName and UnitName("player")
    local realm = _G.GetRealmName and GetRealmName()
    local guid = _G.UnitGUID and UnitGUID("player")
    if type(name) ~= "string" or name == "" then name = "Unknown" end
    if type(realm) ~= "string" or realm == "" then realm = "Realm" end
    if type(guid) ~= "string" or guid == "" or (ns.Compat and ns.Compat.IsSecret(guid)) then guid = nil end
    return name, realm, guid
end

-- Kept for older data: the 0.5.0 key format.
function ns.LegacyCharKey()
    local name, realm = playerInfo()
    return name .. " - " .. realm
end

-- "Name" -> "Name 2", "Name 3"... until it doesn't clash with an existing profile.
local function uniqueProfileName(base, sv)
    local name, i = base, 2
    while sv.profiles[name] do name = base .. " " .. i; i = i + 1 end
    return name
end

-- Build/upgrade the root table. Returns root.
local function upgradeRoot(sv, charKey, displayName)
    if type(sv) ~= "table" then sv = {} end
    if type(sv.profiles) ~= "table" then
        -- 0.1-0.4 kept a single flat profile at the root: move it to this character.
        local root = { dbVersion = DB_VERSION, profiles = {}, profileKeys = {}, chars = {} }
        if type(sv.reminders) == "table" then
            local p = {
                reminders = sv.reminders, nextId = sv.nextId, enabled = sv.enabled,
                debug = sv.debug, channel = sv.channel, popup = sv.popup,
            }
            root.profiles[displayName] = p
            root.profileKeys[charKey] = displayName
            root.chars[charKey] = { active = type(sv.active) == "table" and sv.active or {} }
            root.migratedFrom = tonumber(sv.dbVersion) or 1
        end
        sv = root
    end
    sv.profiles = sv.profiles or {}
    sv.profileKeys = sv.profileKeys or {}
    sv.chars = sv.chars or {}
    if type(sv.profiles[ns.DEFAULT_PROFILE]) ~= "table" then sv.profiles[ns.DEFAULT_PROFILE] = emptyProfile() end
    for k, p in pairs(sv.profiles) do
        if type(k) ~= "string" or type(p) ~= "table" then sv.profiles[k] = nil else normalizeProfile(p) end
    end
    if type(sv.profileKeys) ~= "table" then sv.profileKeys = {} end
    if type(sv.chars) ~= "table" then sv.chars = {} end
    if type(sv.errors) ~= "table" then sv.errors = nil end
    sv.dbVersion = DB_VERSION
    return sv
end

-- Re-key 0.5.0 data ("Name - Full Realm") to the character id and give the
-- character's own profile its short display name.
local function migrateLegacyKey(sv, key, legacy, display)
    if key == legacy then return end
    if sv.profileKeys[legacy] ~= nil and sv.profileKeys[key] == nil then
        sv.profileKeys[key] = sv.profileKeys[legacy]
        sv.profileKeys[legacy] = nil
    end
    if type(sv.chars[legacy]) == "table" and sv.chars[key] == nil then
        sv.chars[key] = sv.chars[legacy]
        sv.chars[legacy] = nil
    end
    if sv.profiles[legacy] and not sv.profiles[display] then
        sv.profiles[display] = sv.profiles[legacy]
        sv.profiles[legacy] = nil
        for k, p in pairs(sv.profileKeys) do
            if p == legacy then sv.profileKeys[k] = display end
        end
    end
end

-- Decide which profile this character uses and point ns.db / ns.char at it.
-- A character seen for the first time gets its own empty profile.
local function bindCharacter()
    local sv = ns.sv
    local key = ns.charKey
    migrateLegacyKey(sv, key, ns.legacyKey, ns.charName)
    local pname = sv.profileKeys[key]
    if not (pname and sv.profiles[pname]) then
        -- First login (or its profile was deleted): this character gets its own, empty profile.
        pname = sv.profiles[ns.charName] and not next(ns.Profiles.UsedBy(ns.charName)) and ns.charName
            or uniqueProfileName(ns.charName, sv)
        if not sv.profiles[pname] then sv.profiles[pname] = emptyProfile() end
        sv.profileKeys[key] = pname
    end
    sv.chars[key] = sv.chars[key] or {}
    sv.chars[key].name = ns.charName
    sv.chars[key].active = sv.chars[key].active or {}
    ns.char = sv.chars[key]
    ns.db = sv.profiles[pname]
    ns.profileName = pname
end

-- Start-up: work out who we are, upgrade old saved data, bind the profile.
-- Runs once, at PLAYER_LOGIN (see the bottom of this file).
local function initDB()
    local name, realm, guid = playerInfo()
    ns.realmName = realm
    ns.charName = name .. " (" .. ns.ShortRealm(realm) .. ")"
    ns.legacyKey = name .. " - " .. realm
    ns.charKey = guid or ns.legacyKey
    ns.sv = upgradeRoot(_G.SkwirlertDB, ns.charKey, ns.charName)
    _G.SkwirlertDB = ns.sv
    bindCharacter()
end

-- Profile operations ---------------------------------------------------------
local Profiles = {}
ns.Profiles = Profiles

-- Name of the profile this character is using right now.
function Profiles.Current() return ns.profileName end
-- Does a profile with this exact name exist?
function Profiles.Exists(name) return name and ns.sv.profiles[name] ~= nil end

-- All profile names, Default first, then alphabetical (for the Profiles tab).
function Profiles.List()
    local out = {}
    for name in pairs(ns.sv.profiles) do out[#out + 1] = name end
    table.sort(out, function(a, b)
        if a == ns.DEFAULT_PROFILE then return true end
        if b == ns.DEFAULT_PROFILE then return false end
        return a:lower() < b:lower()
    end)
    return out
end

-- Characters currently using a profile (display names).
function Profiles.UsedBy(name)
    local out = {}
    for char, p in pairs(ns.sv.profileKeys) do
        if p == name then
            local c = ns.sv.chars[char]
            out[#out + 1] = (type(c) == "table" and c.name) or char
        end
    end
    table.sort(out)
    return out
end

-- Rename a profile. Every character pointing at it follows the new name.
-- Returns true, or false + a message the UI can show.
function Profiles.Rename(old, new)
    new = type(new) == "string" and new:gsub("|", ""):gsub("^%s+", ""):gsub("%s+$", "") or ""
    if not Profiles.Exists(old) then return false, "no profile named '" .. tostring(old) .. "'" end
    if old == ns.DEFAULT_PROFILE then return false, "the Default profile can't be renamed" end
    if new == "" then return false, "type the new name first" end
    if new == old then return true end
    if Profiles.Exists(new) then return false, "a profile named '" .. new .. "' already exists" end
    ns.sv.profiles[new] = ns.sv.profiles[old]
    ns.sv.profiles[old] = nil
    for char, p in pairs(ns.sv.profileKeys) do
        if p == old then ns.sv.profileKeys[char] = new end
    end
    if ns.profileName == old then ns.profileName = new end
    if ns.Config then ns.Config.OnProfileChanged() end
    return true
end

-- Everything that must happen when the active profile changes: stop the old
-- profile's timers (silently), move the popup, re-read current buffs, and
-- refresh the settings window.
local function afterSwitch()
    ns.Log("profile now", ns.profileName, "reminders", #ns.db.reminders)
    if ns.Engine then ns.Engine:ClearAll() end
    if ns.Popup then ns.Popup.Reload() end
    if ns.Minimap then ns.Minimap.Reload() end
    if ns.Sync then ns.Sync.OnSettingsChanged() end
    if ns.Engine then ns.After("profile switch", 0.2, function() ns.Engine:VerifyAll() end) end
    if ns.Config then ns.Config.OnProfileChanged() end
end

-- Make this character use another existing profile.
function Profiles.Use(name)
    if not Profiles.Exists(name) then return false, "no profile named '" .. tostring(name) .. "'" end
    if name == ns.profileName then return true end
    ns.sv.profileKeys[ns.charKey] = name
    ns.db = ns.sv.profiles[name]
    ns.profileName = name
    afterSwitch()
    return true
end

-- Create a new EMPTY profile and switch to it.
function Profiles.Create(name)
    name = type(name) == "string" and name:gsub("^%s+", ""):gsub("%s+$", "") or ""
    if name == "" then return false, "enter a profile name" end
    if Profiles.Exists(name) then return false, "a profile named '" .. name .. "' already exists" end
    ns.sv.profiles[name] = emptyProfile()
    return Profiles.Use(name)
end

-- Overwrite the current profile with a copy of another one.
function Profiles.CopyFrom(name)
    if not Profiles.Exists(name) then return false, "no profile named '" .. tostring(name) .. "'" end
    if name == ns.profileName then return false, "that is the current profile" end
    local p = normalizeProfile(copy(ns.sv.profiles[name]))
    ns.sv.profiles[ns.profileName] = p
    ns.db = p
    afterSwitch()
    return true
end

-- Delete a profile (not Default, not the one in use). Characters that used it
-- get their own fresh profile at their next login.
function Profiles.Delete(name)
    if not Profiles.Exists(name) then return false, "no profile named '" .. tostring(name) .. "'" end
    if name == ns.DEFAULT_PROFILE then return false, "the Default profile can't be deleted" end
    if name == ns.profileName then return false, "you can't delete the profile you're using; switch first" end
    ns.sv.profiles[name] = nil
    for char, p in pairs(ns.sv.profileKeys) do
        if p == name then ns.sv.profileKeys[char] = nil end  -- that character gets its own profile next login
    end
    return true
end

-- Empty the current profile (keeps its name).
function Profiles.Reset()
    local p = emptyProfile()
    ns.sv.profiles[ns.profileName] = p
    ns.db = p
    afterSwitch()
    return true
end

-- Reminders ------------------------------------------------------------------
function ns.GetReminder(id)
    for _, r in ipairs(ns.db.reminders) do
        if r.id == id then return r end
    end
end

-- Find a reminder by name: exact (case-insensitive) match first, then partial.
function ns.FindReminderByName(name)
    if not name then return end
    local n = name:lower()
    for _, r in ipairs(ns.db.reminders) do
        if r.name:lower() == n then return r end
    end
    for _, r in ipairs(ns.db.reminders) do
        if r.name:lower():find(n, 1, true) then return r end
    end
end

-- Number of reminders in the current profile (the cap is ns.MAX_REMINDERS).
function ns.CountReminders() return #ns.db.reminders end

-- Adds a reminder to the current profile. Returns it, or nil + reason at the cap.
function ns.AddReminder(r)
    if #ns.db.reminders >= ns.MAX_REMINDERS then
        return nil, string.format("this profile already has %d reminders (the maximum). Delete one to add another.", ns.MAX_REMINDERS)
    end
    r = ns.NormalizeReminder(r or {}, ns.db.nextId)
    r.id = ns.db.nextId
    ns.db.nextId = ns.db.nextId + 1
    table.insert(ns.db.reminders, r)
    return r
end

-- Remove a reminder from the current profile and stop its timer.
function ns.DeleteReminder(id)
    for i, r in ipairs(ns.db.reminders) do
        if r.id == id then
            if ns.Engine then ns.Engine:Clear(id) end
            table.remove(ns.db.reminders, i)
            return true
        end
    end
end

-- Output -------------------------------------------------------------------
local PREFIX = "|cffffd100Skwirlert|r: "
-- Print a line to the chat window with the yellow "Skwirlert:" prefix.
function ns.Print(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. table.concat(parts, " "))
end

-- Diagnostics ------------------------------------------------------------------
-- Activity log: recorded only in Diagnostics mode (last 200 lines); printed in debug mode.
ns.log = {}
-- Seconds since the computer started (WoW's GetTime); used for timestamps.
local function now() return (_G.GetTime and GetTime()) or 0 end

-- Safe one-line description of any value (secret values are never inspected).
function ns.Describe(v)
    if ns.Compat and ns.Compat.IsSecret(v) then return "<secret>" end
    local t = type(v)
    if t == "string" then return '"' .. (#v > 40 and (v:sub(1, 40) .. "...") or v) .. '"' end
    if t == "number" or t == "boolean" or t == "nil" then return tostring(v) end
    return "<" .. t .. ">"
end

-- Add a line to the activity log. Does nothing unless Diagnostics mode is on,
-- so normal play costs no memory.
function ns.Log(...)
    if not (ns.sv and ns.sv.diagnostics) then return end
    local parts = {}
    for i = 1, select("#", ...) do
        local v = select(i, ...)
        parts[#parts + 1] = type(v) == "string" and v or ns.Describe(v)
    end
    local line = string.format("%.1f %s", now(), table.concat(parts, " "))
    table.insert(ns.log, line)
    if #ns.log > 200 then table.remove(ns.log, 1) end
    return line
end

-- Log a line, and also print it in chat if /skwirlert debug is on.
function ns.Debug(...)
    ns.Log(...)
    if ns.db and ns.db.debug then ns.Print("|cff888888[debug]|r", ...) end
end

-- Errors: kept in memory and in SkwirlertDB.errors (last 25, deduplicated).
ns.errors = {}
local reportedOnce = {}
local lastNotice = 0

-- Capture the current call stack as text (debugstack in WoW, debug.traceback elsewhere).
local function stack()
    if _G.debugstack then
        local ok, s = pcall(debugstack, 3, 14, 0)
        if ok and type(s) == "string" then return s end
    end
    if debug and debug.traceback then
        local ok, s = pcall(debug.traceback, "", 3)
        if ok and type(s) == "string" then return s end
    end
    return "(no stack available)"
end

-- Record an error: where it happened, the message, stack trace and arguments.
-- Identical errors are counted instead of repeated. The player sees one
-- chat line (rate-limited) and WoW's normal error popup / BugSack once.
function ns.ReportError(where, err, trace, context)
    local msg = tostring(err)
    local list = (ns.sv and ns.sv.errors) or ns.errors
    for _, e in ipairs(list) do
        if e.where == where and e.msg == msg then
            e.count = (e.count or 1) + 1
            e.last = now()
            return e
        end
    end
    local e = {
        where = where, msg = msg, stack = trace or "", context = context or "",
        count = 1, time = now(), last = now(),
        date = (_G.date and date("%Y-%m-%d %H:%M:%S")) or "",
        version = ns.version, profile = ns.profileName,
        combat = (_G.InCombatLockdown and not (ns.Compat and ns.Compat.IsSecret(InCombatLockdown())) and InCombatLockdown()) and true or false,
    }
    table.insert(list, 1, e)
    while #list > 25 do table.remove(list) end
    ns.lastError = where .. ": " .. msg
    ns.Log("ERROR in", where, msg)
    -- Chat notice (rate-limited)
    if now() - lastNotice > 5 then
        lastNotice = now()
        local first = msg:match("^[^\n]*") or msg
        DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. "|cffff6060error in " .. where .. ":|r " .. first ..
            "  |cffaaaaaa(type /skwirlert report to copy details)|r")
    end
    -- Hand it to the game's error handler once per unique error, so the normal
    -- Lua error popup (or BugSack) shows it with Skwirlert context.
    local key = where .. "|" .. msg
    if not reportedOnce[key] and _G.geterrorhandler then
        reportedOnce[key] = true
        local handler = geterrorhandler()
        if handler then
            pcall(handler, "Skwirlert " .. ns.version .. " [" .. where .. "] " .. msg)
        end
    end
    return e
end

-- Call fn(...) catching errors with a stack trace. Returns ok, results...
function ns.XCall(where, fn, ...)
    local args = { ... }
    local n = select("#", ...)
    local trace
    local function handler(err)
        trace = stack()
        return err
    end
    local res = pack(xpcall(function() return fn(unpack(args, 1, n)) end, handler))
    if not res[1] then
        local ctx = {}
        for i = 1, math.min(n, 6) do ctx[#ctx + 1] = ns.Describe(args[i]) end
        ns.ReportError(where, res[2], trace, table.concat(ctx, ", "))
    end
    return unpack(res, 1, res.n)
end

-- Wrap a callback (button, timer, slider...) so errors are captured with context.
function ns.Safe(where, fn)
    return function(...) return select(2, ns.XCall(where, fn, ...)) end
end

-- CreateFrame replacement for UI files: every script handler set on the frame
-- (OnClick, OnValueChanged, OnEnterPressed...) is wrapped with error capture.
function ns.SafeFrameFactory(area)
    return function(...)
        local f = _G.CreateFrame(...)
        local orig = f.SetScript
        f.SetScript = function(self, event, fn)
            if type(fn) == "function" then fn = ns.Safe(area .. " " .. tostring(event), fn) end
            return orig(self, event, fn)
        end
        return f
    end
end

-- Timer helpers with error capture.
function ns.After(where, delay, fn)
    return C_Timer.After(delay, ns.Safe("timer: " .. where, fn))
end
-- Like C_Timer.NewTimer, but errors inside fn are captured. Returns a handle with :Cancel().
function ns.NewTimer(where, delay, fn)
    return C_Timer.NewTimer(delay, ns.Safe("timer: " .. where, fn))
end

-- Events -------------------------------------------------------------------
local frame = CreateFrame("Frame", "SkwirlertEventFrame")
ns.frame = frame
local handlers = {}

-- Subscribe fn(event, ...) to a WoW event. Several files can subscribe to the
-- same event; each handler runs inside ns.XCall so one failure can't stop others.
function ns.On(event, fn)
    if not handlers[event] then
        handlers[event] = {}
        frame:RegisterEvent(event)
    end
    table.insert(handlers[event], fn)
end

-- Unit events are registered for one unit when the client supports it.
function ns.OnUnit(event, unit, fn)
    if not handlers[event] then
        handlers[event] = {}
        local ok = false
        if frame.RegisterUnitEvent then
            ok = pcall(frame.RegisterUnitEvent, frame, event, unit)
        end
        if not ok then frame:RegisterEvent(event) end
    end
    table.insert(handlers[event], fn)
end

frame:SetScript("OnEvent", function(_, event, ...)
    local list = handlers[event]
    if not list then return end
    for _, fn in ipairs(list) do
        -- Never let one handler break the addon; errors are recorded with context.
        ns.XCall("event " .. event, fn, event, ...)
    end
end)

ns.OnInitialize = {}
-- Modules call this to run set-up code once saved settings are ready
-- (at PLAYER_LOGIN). Order = TOC file order.
function ns.RegisterInit(fn) table.insert(ns.OnInitialize, fn) end

-- Initialise at PLAYER_LOGIN: the character name and realm are reliable then.
frame:RegisterEvent("PLAYER_LOGIN")
local initialized = false
handlers.PLAYER_LOGIN = { function()
    if initialized then return end
    initialized = true
    local ok = ns.XCall("startup: saved variables", initDB)
    if not ok then
        ns.Print("|cffff6060could not load saved settings; Skwirlert is inactive this session. Type /skwirlert report.|r")
        return
    end
    ns.sv.errors = ns.sv.errors or {}
    for _, e in ipairs(ns.errors) do table.insert(ns.sv.errors, 1, e) end  -- errors from before init
    while #ns.sv.errors > 25 do table.remove(ns.sv.errors) end
    for i, fn in ipairs(ns.OnInitialize) do ns.XCall("startup: module " .. i, fn) end
    ns.Log("login", ns.charKey, "profile", ns.profileName, "reminders", #ns.db.reminders)
    if ns.sv.migratedFrom then
        ns.Print(string.format("your reminders were moved into the profile '%s'. Other characters can copy it from the Profiles tab.", ns.profileName))
        ns.sv.migratedFrom = nil
    end
end }
