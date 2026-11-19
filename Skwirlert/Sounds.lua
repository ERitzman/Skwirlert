-- =============================================================================
-- Skwirlert - Sounds.lua  (sound manager)
-- =============================================================================
-- WHAT THIS FILE DOES
--   Plays the alert sounds, falls back to a Blizzard sound if a file fails,
--   keeps a short playback log, and can read (never change) the game's sound
--   settings for /skwirlert soundcheck.
--
-- WOW CONCEPTS
--   * PlaySoundFile(path, channel) plays a file shipped inside the addon
--     folder. Paths use backslashes: Interface\AddOns\<Addon>\file.ogg.
--     Supported formats: .ogg and .mp3. New files need a full client restart.
--   * PlaySound(soundKitID, channel) plays one of Blizzard's built-in sounds.
--   * Channel "Master" plays even when the Effects channel is turned off.
--   * A true return only means the game QUEUED the sound, not that it was heard.
--
-- FILES
--   Sounds\*.ogg + Sounds\Uh Oh.mp3 are played. Sounds\Originals\ holds the
--   owner's untouched originals (reference only, never played).
--
-- TO ADD A SOUND: put the .ogg in Sounds\, add a line to Sounds.files below,
-- then fully restart WoW.
-- =============================================================================

local _, ns = ...
local Sounds = {}
ns.Sounds = Sounds

local BASE = "Interface\\AddOns\\" .. (ns.name or "Skwirlert") .. "\\Sounds\\"

Sounds.files = {
    { key = "Uh Oh",                  file = "Uh Oh.mp3" },
    { key = "sci-fi-error-alert",     file = "sci-fi-error-alert.ogg" },
    { key = "toy-robot-alert",        file = "toy-robot-alert.ogg" },
    { key = "double-beep-tone-alert", file = "double-beep-tone-alert.ogg" },
    { key = "mechanical-alert",       file = "mechanical-alert.ogg" },
    { key = "quick-tone",             file = "quick-tone.ogg" },
}

local SK = _G.SOUNDKIT or {}
local FALLBACK_KIT = SK.RAID_WARNING or 8959
Sounds.builtin = {
    { key = "wow:raidwarning", label = "WoW: Raid Warning", kit = SK.RAID_WARNING or 8959 },
    { key = "wow:readycheck",  label = "WoW: Ready Check",  kit = SK.READY_CHECK or 8960 },
    { key = "none",            label = "(silent)" },
}

local byKey = {}
Sounds.order = {}
for _, s in ipairs(Sounds.files) do
    s.label = s.key
    s.path = BASE .. s.file
    byKey[s.key] = s
    table.insert(Sounds.order, s.key)
end
for _, s in ipairs(Sounds.builtin) do
    byKey[s.key] = s
    table.insert(Sounds.order, s.key)
end

-- Text shown in the settings window for a sound key.
function Sounds.Label(key)
    local s = byKey[key]
    return s and s.label or (tostring(key) .. " (missing)")
end
-- Is this a known sound key? (Used to validate imported profiles.)
function Sounds.Exists(key) return byKey[key] ~= nil end
-- The sound record for a key, or nil.
function Sounds.Get(key) return byKey[key] end

-- Next (dir = 1) or previous (dir = -1) sound in the list, wrapping around.
function Sounds.Next(key, dir)
    local n = #Sounds.order
    local idx = 1
    for i, k in ipairs(Sounds.order) do if k == key then idx = i end end
    idx = ((idx - 1 + (dir or 1)) % n) + 1
    return Sounds.order[idx]
end

-- Playback log (most recent first) for /skwirlert soundlog.
Sounds.log = {}
-- Keep the last 20 playback results for /skwirlert soundlog and bug reports.
local function log(entry)
    entry.t = GetTime()
    table.insert(Sounds.log, 1, entry)
    while #Sounds.log > 20 do table.remove(Sounds.log) end
end

-- Sound channel chosen with /skwirlert channel (default Master).
local function channel() return (ns.db and ns.db.channel) or "Master" end

-- Play an addon sound file. Returns accepted (bool), handle, error text.
local function playFile(path)
    if not _G.PlaySoundFile then return false, nil, "PlaySoundFile missing" end
    local ok, willPlay, handle = pcall(PlaySoundFile, path, channel())
    if not ok then return false, nil, tostring(willPlay) end
    return willPlay and true or false, handle, nil
end

-- Play a built-in Blizzard sound by SoundKit ID.
local function playKit(kit)
    if not (_G.PlaySound and kit) then return false end
    local ok, willPlay = pcall(PlaySound, kit, channel())
    return ok and willPlay and true or false
end

local lastPlayed = {}
local lastFailNotice = 0

-- Plays a sound by key. Returns accepted(bool), detail(string).
-- On a rejected custom file, the Blizzard raid-warning SoundKit is played instead.
function Sounds.Play(key, force)
    if key == nil or key == "none" then return true, "silent" end
    local now = GetTime()
    if not force and lastPlayed[key] and now - lastPlayed[key] < 0.4 then return true, "debounced" end
    lastPlayed[key] = now

    local s = byKey[key]
    if s and s.kit then
        local ok = playKit(s.kit)
        log({ key = key, path = "SoundKit " .. tostring(s.kit), ok = ok })
        return ok, ok and "SoundKit accepted" or "SoundKit rejected"
    end

    local path = s and s.path or nil
    local ok, handle, err
    if path then ok, handle, err = playFile(path) end
    if ok then
        log({ key = key, path = path, ok = true, handle = handle })
        ns.Debug("sound accepted:", path, "handle", tostring(handle))
        return true, "accepted"
    end

    local fbOk = playKit(FALLBACK_KIT)
    local reason = err or (path and "PlaySoundFile returned nil (file missing/unreadable or channel muted)" or "unknown sound key")
    local problem = Sounds.SettingsProblem and Sounds.SettingsProblem()
    if problem then reason = reason .. "; " .. problem end
    log({ key = key, path = path or tostring(key), ok = false, reason = reason, fallback = fbOk })
    if force or now - lastFailNotice > 10 then
        lastFailNotice = now
        ns.Print(string.format("|cffff6060sound failed|r: %s - %s; fallback SoundKit %s",
            tostring(key), reason, fbOk and "played" or "also failed"))
    end
    return false, reason
end

-- Plays every bundled file individually, in turn, reporting each result.
function Sounds.TestAll(gap)
    gap = gap or 2.75
    ns.Print(string.format("testing %d sounds on the '%s' channel. 'accepted' means the client queued it; confirm you heard each one.",
        #Sounds.files, channel()))
    for i, s in ipairs(Sounds.files) do
        ns.After("Sounds", (i - 1) * gap, function()
            local ok, detail = Sounds.Play(s.key, true)
            ns.Popup.Show(string.format("Sound %d/%d: %s", i, #Sounds.files, s.file), math.min(gap, 2.5))
            ns.Print(string.format("sound %d/%d: %s - %s", i, #Sounds.files, s.file,
                ok and "|cff40ff40accepted|r" or ("|cffff4040FAILED|r (" .. detail .. ")")))
        end)
    end
end

-- Test one sound by number (1-6) or key.
function Sounds.TestOne(arg)
    local s = Sounds.files[tonumber(arg) or 0]
    if not s then
        local want = tostring(arg):lower()
        for _, f in ipairs(Sounds.files) do
            if f.key:lower() == want or f.file:lower() == want then s = f end
        end
    end
    if not s then ns.Print("unknown sound '" .. tostring(arg) .. "' - use 1-6 or a name"); return end
    local ok, detail = Sounds.Play(s.key, true)
    ns.Print(s.file .. ": " .. (ok and "|cff40ff40accepted|r" or ("|cffff4040FAILED|r (" .. detail .. ")")))
end

-- Read-only look at the game's sound settings (never changes them).
local CVARS = {
    { "Sound_EnableAllSound", "Sound enabled" },
    { "Sound_EnableSFX", "Sound effects enabled" },
    { "Sound_MasterVolume", "Master volume" },
    { "Sound_SFXVolume", "Effects volume" },
    { "Sound_EnableMusic", "Music enabled" },
}
-- Read one game setting (CVar) as text, or nil. Read-only.
local function getCVar(name)
    local f = (_G.C_CVar and C_CVar.GetCVar) or _G.GetCVar
    if not f then return nil end
    local ok, v = pcall(f, name)
    if ok and type(v) == "string" then return v end
    return nil
end

-- The game's sound settings, for /skwirlert soundcheck and bug reports.
function Sounds.ReadSettings()
    local out = {}
    for _, c in ipairs(CVARS) do out[#out + 1] = { cvar = c[1], label = c[2], value = getCVar(c[1]) } end
    return out
end

-- Returns a short problem description, or nil if nothing looks off.
function Sounds.SettingsProblem()
    local all, master = getCVar("Sound_EnableAllSound"), tonumber(getCVar("Sound_MasterVolume") or "")
    if all == "0" then return "game sound is turned OFF (Ctrl+S toggles it, or Options > Audio > Enable Sound)" end
    if master and master <= 0 then return "Master volume is at 0 (Options > Audio)" end
    return nil
end
