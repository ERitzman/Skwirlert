-- =============================================================================
-- Skwirlert - Commands.lua  (the /skwirlert slash command)
-- =============================================================================
-- WHAT THIS FILE DOES
--   Defines /skwirlert and its sub-commands (test, status, buffs, casts, aura,
--   new, start, stop, profile, report, diag, errors, soundcheck, ...).
--   /skwirlert help lists them all.
--
-- WOW CONCEPTS
--   * Slash commands: set SLASH_<KEY>1 = "/command", then
--     SlashCmdList["<KEY>"] = function(msg) ... end. `msg` is the text after
--     the command.
--   * Colour codes in chat: "|cffRRGGBB" starts a colour, "|r" ends it.
--   * The handler runs inside ns.XCall, so an error in any sub-command is
--     captured and reported instead of breaking the command.
--
-- TO ADD A COMMAND: add an `elseif cmd == "name" then ... ` branch in
-- handleSlash, plus a line in HELP.
-- =============================================================================

local _, ns = ...

local HELP = {
    "/skwirlert - open or close settings",
    "/skwirlert test [1-6|name] - test popup + every sound (or one sound)",
    "/skwirlert status - what is running and how (verified/estimated)",
    "/skwirlert refresh - add every timed buff on you now (no duplicates) and refresh timers",
    "/skwirlert refresh min <duration> - Refresh only adds buffs at least this long (default 5m)",
    "/skwirlert refresh forget - let Refresh add buffs you deleted before",
    "/skwirlert pause [minutes|group] - pause dialog, or pause now (default 30 min) / while grouped",
    "/skwirlert resume - resume monitoring now",
    "/skwirlert minimap [show|hide|reset] - minimap button",
    "/skwirlert group [share|receive|off] - groupmates' timers, or set group sync",
    "/skwirlert check [announce] - run the after-combat group check now (cures / resurrections)",
    "/skwirlert aspect - Aspect warning status (Cheetah / Pack)",
    "/skwirlert welcome - open the welcome window",
    "/skwirlert tutorial - the short how-it-works tutorial",
    "/skwirlert version - your version and the newest one seen in your guild/group",
    "/skwirlert buffs - list the buffs on you with spell IDs and durations",
    "/skwirlert casts - your recent successful casts with spell IDs",
    "/skwirlert aura <spell ID or name> - is this buff on you and readable right now?",
    "/skwirlert new <name> - create a reminder",
    "/skwirlert start <name> | stop <name> - run/stop a reminder manually",
    "/skwirlert profile [list | use <name>] - show, list or switch profiles",
    "/skwirlert report - copyable bug report (errors, stack traces, activity log)",
    "/skwirlert diag on|off - diagnostics mode (records activity for bug reports)",
    "/skwirlert errors [clear] - list or clear captured errors",
    "/skwirlert soundcheck - show game sound settings (read-only) and play a test sound",
    "/skwirlert soundlog | chatlog - recent sound / chat results",
    "/skwirlert channel [Master/SFX/...] - sound channel",
    "/skwirlert api - client API probe",
    "/skwirlert debug - print debug messages in chat",
    "/skwirlert unlock | lock | resetpos - move the popup",
    "/skwirlert reset confirm - empty the current profile",
}

-- Green "yes" / red "no" for chat output.
local function yn(b) return b and "|cff40ff40yes|r" or "|cffff4040no|r" end

-- /skwirlert status: one line per reminder, plus combat and profile state.
local function status()
    local any = false
    for _, r in ipairs(ns.db.reminders) do
        local st = ns.Engine:State(r.id)
        local line = string.format("%s [%s%s]", r.name, r.kind, r.enabled and "" or ", disabled")
        if st then
            any = true
            line = line .. string.format(": %s left, %s%s%s", ns.Engine.fmtTime(st.expires - GetTime()),
                st.source == "verified" and "verified by aura" or (st.source == "manual" and "manual timer" or "estimated from cast"),
                st.recipient and (", on " .. st.recipient) or "",
                st.warned and ", warned" or "")
        else
            line = line .. ": not running"
        end
        for _, ms in ipairs(ns.Engine:Members(r.id)) do   -- per-member copies (0.8.0)
            any = true
            line = line .. string.format("; %s %s", ms.member, ns.Engine.fmtTime(ms.expires - GetTime()))
        end
        ns.Print(line)
    end
    if not any then ns.Print("nothing running. In combat, aura data may be hidden; estimates are used.") end
    ns.Print("in combat: " .. yn(ns.Compat.InCombat()) .. ", addon enabled: " .. yn(ns.db.enabled))
    if ns.lastError then ns.Print("|cffff8080last error:|r " .. tostring(ns.lastError) .. "  (/skwirlert report)") end
    ns.Print("profile: " .. tostring(ns.Profiles.Current()) .. ", diagnostics: " .. (ns.Diag.Enabled() and "on" or "off"))
    ns.Print(ns.Pause.Describe())
end

-- /skwirlert aura <id or name>: is this buff on me, and is it readable now?
local function auraCheck(arg)
    local id = tonumber(arg)
    local r = { spellIDs = id and { id } or {}, names = (not id and arg ~= "") and { arg } or {}, learnedIDs = {} }
    local s, a = ns.Compat.FindPlayerBuff(r)
    if s == "present" then
        ns.Print(string.format("%s: present (spell %s), expires %s, duration %s", arg,
            tostring(a.spellId or "?"),
            a.expires and (a.expires > 0 and ns.Engine.fmtTime(a.expires - GetTime()) .. " from now" or "never") or "unreadable",
            a.duration and tostring(a.duration) or "unreadable"))
    elseif s == "absent" then
        ns.Print(arg .. ": not on you (readable)")
    else
        ns.Print(arg .. ": unknown - aura data restricted or unsupported right now")
    end
    if id then
        local secret = ns.Compat.AuraSecret(id)
        ns.Print("C_Secrets says aura is secret: " .. (secret == nil and "n/a" or tostring(secret)))
    end
end

SLASH_SKWIRLERT1 = "/skwirlert"
-- Split "/skwirlert <cmd> <rest>" and run the matching sub-command.
local function handleSlash(msg)
    msg = (msg or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local cmd, rest = msg:match("^(%S*)%s*(.-)$")
    cmd = (cmd or ""):lower()
    if not ns.db and cmd ~= "report" then
        ns.Print("|cffff6060Skwirlert didn't finish starting this session.|r Type /skwirlert report and send the text.")
        return
    end

    if cmd == "" or cmd == "config" or cmd == "options" then
        ns.Config.Toggle()
    elseif cmd == "test" or cmd == "testsounds" then
        if rest ~= "" then
            ns.Sounds.TestOne(rest)
        else
            ns.Popup.Show("Skwirlert test popup")
            ns.Sounds.TestAll()
        end
    elseif cmd == "soundcheck" then
        for _, c in ipairs(ns.Sounds.ReadSettings()) do
            ns.Print(string.format("%s (%s): %s", c.label, c.cvar, c.value or "n/a"))
        end
        local problem = ns.Sounds.SettingsProblem()
        if problem then
            ns.Print("|cffff6060" .. problem .. "|r")
        else
            ns.Print("sound settings look fine; playing a test sound on '" .. ns.db.channel .. "'. If you hear nothing, check Windows volume or your output device (/console Sound_RestartSoundSystem).")
        end
        ns.Sounds.Play("quick-tone", true)
    elseif cmd == "soundlog" then
        if #ns.Sounds.log == 0 then ns.Print("no sounds played since login/reload") end
        for i, e in ipairs(ns.Sounds.log) do
            ns.Print(string.format("%d. %s  %s  %s%s  (%s ago)", i, e.key,
                e.ok and "|cff40ff40accepted|r" or "|cffff4040failed|r", e.path or "",
                e.ok and "" or (" - " .. tostring(e.reason) .. (e.fallback and "; fallback played" or "; fallback failed")),
                ns.Engine.fmtTime(GetTime() - e.t)))
        end
    elseif cmd == "chatlog" then
        if #ns.Announce.log == 0 then ns.Print("no chat announcements since login/reload") end
        for i, e in ipairs(ns.Announce.log) do
            ns.Print(string.format("%d. [%s] %s  %s  (%s ago)", i, tostring(e.chatType),
                e.ok and "|cff40ff40sent|r" or ("|cffff4040" .. (e.skipped and "skipped" or "failed") .. "|r: " .. tostring(e.reason)),
                e.msg, ns.Engine.fmtTime(GetTime() - e.t)))
        end
    elseif cmd == "channel" then
        local valid = { master = "Master", sfx = "SFX", music = "Music", ambience = "Ambience", dialog = "Dialog" }
        local c = valid[rest:lower()]
        if c then ns.db.channel = c; ns.Print("sound channel: " .. c)
        else ns.Print("current channel: " .. ns.db.channel .. " (options: Master, SFX, Music, Ambience, Dialog)") end
    elseif cmd == "status" then
        status()
    elseif cmd == "casts" then
        if #ns.Engine.recentCasts == 0 then ns.Print("no casts recorded since login/reload") end
        for i, c in ipairs(ns.Engine.recentCasts) do
            ns.Print(string.format("%d. %s  id=%d%s  (%s ago)", i, c.name, c.id,
                c.target and ("  target=" .. c.target) or "", ns.Engine.fmtTime(GetTime() - c.t)))
        end
    elseif cmd == "refresh" then
        local sub, val = rest:match("^(%S*)%s*(.-)$")
        sub = (sub or ""):lower()
        if sub == "min" then
            if val == "" then
                ns.Print("Refresh adds buffs lasting at least " .. ns.FormatDuration(ns.Picker.MinDuration()) .. ". Change: /skwirlert refresh min 2m (0 = any length)")
            else
                local n, err = ns.ParseDuration(val)
                if not n then ns.Print("|cffff6060not changed:|r " .. tostring(err))
                else
                    ns.db.refresh.minDuration = math.max(0, math.min(86400, n))
                    ns.Print("Refresh now adds buffs lasting at least " .. ns.FormatDuration(ns.db.refresh.minDuration) .. ".")
                    if ns.Config then ns.Config.Refresh() end
                end
            end
        elseif sub == "forget" then
            ns.Print(string.format("forgot %d deleted buff(s); Refresh may add them again.", ns.Picker.ForgetIgnored()))
        else
            ns.Picker.RefreshAll(true)
        end
    elseif cmd == "pause" then
        local arg = rest:lower()
        if arg == "" then
            ns.Pause.ShowDialog()
        elseif arg == "group" or arg == "grouped" then
            local ok, err = ns.Pause.StartGrouped()
            if not ok then ns.Print("|cffff6060" .. err .. "|r") end
        elseif tonumber(arg) then
            local ok, err = ns.Pause.Start(tonumber(arg))
            if not ok then ns.Print("|cffff6060" .. err .. "|r") end
        else
            ns.Print("usage: /skwirlert pause, /skwirlert pause 30, /skwirlert pause group")
        end
    elseif cmd == "resume" then
        if ns.Pause.IsPaused() then ns.Pause.Resume() else ns.Pause.Resume(true); ns.Print("monitoring is not paused") end
    elseif cmd == "check" then
        ns.CombatAlerts.Check(true, rest:lower() == "announce")
    elseif cmd == "welcome" then
        ns.Welcome.Show()
    elseif cmd == "version" then
        local nv = ns.Version.newest
        ns.Print(string.format("version %s%s. Update notice: %s.", ns.version,
            nv and (", newer seen: " .. nv) or ", no newer version seen this session",
            ns.Version.Enabled() and "on" or "off"))
    elseif cmd == "tutorial" then
        ns.Welcome.ShowTutorial()
    elseif cmd == "aspect" then
        local CA = ns.CombatAlerts
        local st, set = CA.aspectState, CA.Settings()
        ns.Print(string.format("aspect warning: %s; Cheetah on: %s, Pack on: %s%s; hunter: %s",
            set.aspect and "on" or "off", st.cheetah and "yes" or "no", st.pack and "yes" or "no",
            st.pack and (st.packMine and " (yours)" or " (another hunter's)") or "", CA.IsHunter() and "yes" or "no"))
    elseif cmd == "group" or cmd == "sync" then
        local arg = rest:lower()
        local s = ns.Sync.Settings()
        if arg == "share" or arg == "receive" or arg == "off" then
            s.mode = arg; ns.Sync.OnSettingsChanged()
            ns.Print("group sync: " .. ns.Sync.MODE_LABEL[arg])
            return
        end
        ns.Print(string.format("group sync: %s, frequency %s (at most every %d s)%s", ns.Sync.MODE_LABEL[s.mode],
            ns.Sync.FREQ_LABEL[s.freq], ns.Sync.FREQ_GAP[s.freq], s.noCombat and ", not during combat" or ""))
        local lines = ns.Config.GroupLines and ns.Config.GroupLines() or {}
        if not ns.Sync.Channel() then ns.Print("not in a group")
        elseif #lines == 0 then ns.Print("no groupmates running Skwirlert have shared timers yet") end
        for _, l in ipairs(lines) do ns.Print(l) end
    elseif cmd == "minimap" then
        local arg = rest:lower()
        if arg == "hide" then ns.Minimap.SetShown(false); ns.Print("minimap button hidden. /skwirlert minimap show to bring it back.")
        elseif arg == "reset" then ns.Minimap.ResetPosition(); ns.Print("minimap button reset")
        else ns.Minimap.SetShown(true); ns.Print("minimap button shown") end
    elseif cmd == "buffs" then
        local list, hidden = ns.Compat.ListPlayerBuffs()
        if #list == 0 then ns.Print(hidden and "buff data is hidden right now (combat?)" or "no buffs on you") end
        for _, a in ipairs(list) do
            ns.Print(string.format("%s  id=%s  %s", a.name or "?", a.spellId and tostring(a.spellId) or "?",
                (a.duration and a.duration > 0) and ns.Engine.fmtTime(a.duration) or "no timer"))
        end
        if hidden and #list > 0 then ns.Print("some buffs are hidden right now (combat)") end
    elseif cmd == "aura" then
        if rest == "" then ns.Print("usage: /skwirlert aura <spell ID or name>") else auraCheck(rest) end
    elseif cmd == "api" then
        ns.Print("API probe (" .. (select(4, GetBuildInfo()) or "?") .. "):")
        local parts = {}
        for _, p in ipairs(ns.Compat.Probe()) do
            parts[#parts + 1] = p[1] .. "=" .. (p[2] and "Y" or "n")
            if #parts == 4 then ns.Print(table.concat(parts, "  ")); parts = {} end
        end
        if #parts > 0 then ns.Print(table.concat(parts, "  ")) end
    elseif cmd == "debug" then
        ns.db.debug = not ns.db.debug
        ns.Print("debug " .. (ns.db.debug and "on" or "off"))
    elseif cmd == "start" or cmd == "stop" then
        local r = ns.FindReminderByName(rest)
        if not r then ns.Print("no reminder named '" .. rest .. "'"); return end
        if cmd == "start" then
            ns.Engine:StartManual(r)
            ns.Print(r.name .. " started (" .. ns.Engine.fmtTime(r.learnedDuration or r.duration) .. ")")
        else
            ns.Engine:Clear(r.id)
            ns.Print(r.name .. " stopped")
        end
        ns.Config.Refresh()
    elseif cmd == "new" then
        local name = rest ~= "" and rest or "New reminder"
        local r, err = ns.AddReminder({ name = name, kind = "self", duration = 600, warn = 30,
            warnSound = "quick-tone", expireSound = "Uh Oh" })
        if not r then ns.Print(err); return end
        ns.Print(string.format("created '%s' (%d/%d custom). Set its spell ID/name and duration in the window.",
            r.name, ns.CountReminders(), ns.MAX_REMINDERS))
        local _, win = ns.Config.Widgets()
        if not (win and win:IsShown()) then ns.Config.Toggle() end
        ns.Config.Select(r.id)
    elseif cmd == "profile" or cmd == "profiles" then
        local sub, arg = rest:match("^(%S*)%s*(.-)$")
        sub = (sub or ""):lower()
        if sub == "use" then
            local ok, err = ns.Profiles.Use(arg)
            ns.Print(ok and ("now using profile '" .. arg .. "'") or err)
        elseif sub == "rename" then
            local old = ns.Profiles.Current()
            local ok, err = ns.Profiles.Rename(old, arg)
            ns.Print(ok and ("renamed '" .. old .. "' to '" .. ns.Profiles.Current() .. "'") or err)
        elseif sub == "list" then
            for _, name in ipairs(ns.Profiles.List()) do
                local users = ns.Profiles.UsedBy(name)
                ns.Print(string.format("%s%s - %d reminders%s", name, name == ns.Profiles.Current() and " (in use)" or "",
                    #ns.sv.profiles[name].reminders, #users > 0 and (" - used by " .. table.concat(users, ", ")) or ""))
            end
        else
            ns.Print("character '" .. ns.charName .. "' uses profile '" .. ns.Profiles.Current() .. "'. Profiles tab or /skwirlert profile list | use <name> | rename <new name>")
        end
    elseif cmd == "report" then
        ns.Diag.ShowReport()
    elseif cmd == "diag" or cmd == "diagnostics" then
        local v = rest:lower()
        if v == "on" then ns.Diag.SetEnabled(true)
        elseif v == "off" then ns.Diag.SetEnabled(false)
        else ns.Print("diagnostics mode is " .. (ns.Diag.Enabled() and "ON" or "off") .. ". Use /skwirlert diag on|off") end
    elseif cmd == "errors" then
        local list = ns.sv.errors
        if rest:lower() == "clear" then ns.Diag.ClearErrors(); ns.Print("errors cleared"); return end
        if #list == 0 then ns.Print("no errors captured") end
        for i, e in ipairs(list) do
            ns.Print(string.format("%d. [%s] x%d %s", i, e.where, e.count or 1, e.msg))
        end
        if #list > 0 then ns.Print("full details with stack traces: /skwirlert report") end
    elseif cmd == "unlock" then
        ns.Popup.SetLocked(false); ns.Print("popup unlocked - drag it, then /skwirlert lock")
    elseif cmd == "lock" then
        ns.Popup.SetLocked(true); ns.Print("popup locked")
    elseif cmd == "resetpos" then
        ns.Popup.ResetPosition(); ns.Print("popup position reset")
    elseif cmd == "reset" then
        if rest == "confirm" then
            ns.Profiles.Reset()
            ns.Print("profile '" .. ns.Profiles.Current() .. "' is now empty")
        else
            ns.Print("this removes every reminder from profile '" .. ns.Profiles.Current() .. "'. Type /skwirlert reset confirm")
        end
    else
        for _, l in ipairs(HELP) do ns.Print(l) end
    end
end

SlashCmdList.SKWIRLERT = function(msg)
    ns.XCall("command /skwirlert " .. tostring(msg or ""), handleSlash, msg)
end
