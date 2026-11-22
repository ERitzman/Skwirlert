-- =============================================================================
-- Skwirlert - Engine.lua  (cast detection, buff checks and timers)
-- =============================================================================
-- WHAT THIS FILE DOES
--   Decides WHEN to alert. For each reminder it keeps at most one running
--   "cycle" and schedules two timers: the advance warning and the expiration.
--
--   state = { rid, member, cycle, expires, startedAt, source, recipient,
--             warned, expired, warnTimer, expireTimer }
--   Cycles are stored under a KEY: the reminder id for the normal cycle, or
--   "<id>:<name>" for a per-member copy (see PER-MEMBER TRACKING below).
--   source:  "verified"  = expiration read from the actual buff
--            "predicted" = estimated from cast time + duration (e.g. in combat)
--            "manual"    = started with Start / /skwirlert start
--            "shared"    = time left reported by that player's own Skwirlert
--                          (Group Sync); it was read from the real buff
--
-- PER-MEMBER TRACKING (0.8.0, option "Track on each group member")
--   For buffs you also cast on groupmates (e.g. a mage's Arcane Intellect),
--   each member who has YOUR copy gets their own cycle: key "<id>:<name>".
--   * Started by your cast on them, or by seeing your copy on them (UNIT_AURA
--     on party/raid units; only auras whose caster is you are counted).
--   * Ends with "has ended" when they lose it early (dispel, death), or is
--     dropped silently when another player's copy replaced yours or they left.
--   * Out of range / hidden: the cast-time estimate keeps running; if that
--     player runs Skwirlert and tracks the same buff, the time they share
--     via Group Sync corrects it (source "shared").
--   * Alerts that fall within 1.5 s of each other for the same reminder are
--     merged: "Arcane Intellect expires in 30s: you, Bob, Ann".
--
-- HOW A CYCLE STARTS
--   1. You cast a matching spell (UNIT_SPELLCAST_SUCCEEDED)  -> predicted
--   2. The buff is seen on you or a group member (UNIT_AURA)  -> verified
--   3. Start button / slash command                          -> manual
--   A recast, or a buff refresh that moves expiration later, starts a NEW
--   cycle. Old timers are cancelled, and every callback also checks its cycle
--   number, so each cycle warns once and expires once.
--
-- HONESTY RULES (no false alerts)
--   * "has ended" / "has expired" only when the buff was seen in this cycle
--     and is then confirmed gone. Otherwise: "has likely expired (est.)".
--   * Estimated alerts are marked "(est.)".
--
-- WOW CONCEPTS
--   * UNIT_SPELLCAST_SENT (unit, target, castGUID, spellID) fires when a cast
--     starts and tells us the target's name; UNIT_SPELLCAST_SUCCEEDED
--     (unit, castGUID, spellID) fires when it lands. castGUID links the two.
--   * UNIT_AURA fires (often in bursts) when buffs change; checks are batched
--     0.15 s later, with one scan of the buff list for all reminders.
--   * C_Timer timers are used instead of OnUpdate, so nothing runs every frame.
-- =============================================================================

local _, ns = ...
local C = ns.Compat
local Engine = {}
ns.Engine = Engine

local states = {}        -- [key] = state  (key = reminder id, or "<id>:<name>" per member)
local pendingSent = {}   -- [castGUID] = { target=, t= }
local recentCasts = {}   -- ring buffer for /skwirlert casts
local cycleCounter = 0

Engine.states = states
Engine.recentCasts = recentCasts

-- Current time in seconds (same clock as aura expirationTime).
local function now() return GetTime() end

-- 75 -> "1m15s", 600 -> "10m", 3600 -> "1h" (used in popups, chat and the
-- settings window). See ns.FormatDuration in Core.lua.
local function fmtTime(sec)
    return ns.FormatDuration(math.max(0, sec))
end
Engine.fmtTime = fmtTime

-- Text for alerts: the reminder name, plus "(recipient)" for targeted buffs.
local function label(r, st)
    if st and st.member then return r.name .. " on " .. st.member end
    if r.kind == "targeted" then
        local who = st and st.recipient or "unknown target"
        return r.name .. " (" .. who .. ")"
    end
    return r.name
end

-- Stop a cycle's pending warning and expiration timers.
local function cancelTimers(st)
    if st.warnTimer then st.warnTimer:Cancel(); st.warnTimer = nil end
    if st.expireTimer then st.expireTimer:Cancel(); st.expireTimer = nil end
end

-- 0 = expiration-only: no advance warning (popup, sound or chat) is scheduled.
local function effectiveWarn(r)
    local w = r.warn
    if w <= 0 then return 0 end
    local d = r.learnedDuration or r.duration
    if w >= d then w = math.max(1, d - 1) end
    return w
end

-- Copy running cycles into the character's saved data (so /reload can restore
-- them) and nudge the settings window to update its status icons.
local function persist()
    if not ns.char then return end
    local out = {}
    for id, st in pairs(states) do
        out[id] = { expires = st.expires, startedAt = st.startedAt, source = st.source,
                    recipient = st.recipient, warned = st.warned, rid = st.rid, member = st.member }
    end
    ns.char.active = out
    if ns.Config and ns.Config.RefreshLiveSoon then ns.Config.RefreshLiveSoon() end
    if ns.Sync then ns.Sync.MarkDirty() end          -- groupmates get one merged update (Sync.lua)
end

-- Scheduling ---------------------------------------------------------------
local schedule

-- Merged alerts for per-member reminders --------------------------------------
-- Several members (and you) usually get the same buff within seconds, so
-- their warnings would arrive as a burst of popups. Alerts for one reminder
-- that fall within 1.5 s are merged into ONE popup and ONE sound.
local batches = {}   -- ["<id>:<type>"] = { rid, type, who = {}, est, remain }
local function flushBatch(bkey)
    local b = batches[bkey]; batches[bkey] = nil
    local r = b and ns.GetReminder(b.rid)
    if not r then return end
    local onlyYou = #b.who == 1 and b.who[1] == "you"
    local whoText = onlyYou and "" or (": " .. table.concat(b.who, ", "))
    local msg
    if b.type == "warn" then
        msg = r.name .. " expires in " .. fmtTime(b.remain or 0) .. whoText
    elseif b.type == "ended" then
        msg = r.name .. " has ended" .. whoText
    elseif b.type == "expired" then
        msg = r.name .. " has expired" .. whoText
    else
        msg = r.name .. " has likely expired" .. whoText
    end
    if b.est then msg = msg .. " (est.)" end
    ns.Popup.Show(msg)
    ns.Sounds.Play(b.type == "warn" and r.warnSound or r.expireSound)
end
local function queueAlert(r, kind, who, est, remain)
    local bkey = r.id .. ":" .. kind
    local b = batches[bkey]
    if not b then
        b = { rid = r.id, type = kind, who = {}, est = false, remain = remain }
        batches[bkey] = b
        ns.After("Engine", 1.5, function() flushBatch(bkey) end)
    end
    b.who[#b.who + 1] = who
    if est then b.est = true end
    if remain and (not b.remain or remain < b.remain) then b.remain = remain end
end

-- Advance warning: popup + warning sound + optional chat message. Ignored if
-- the cycle is stale, already warned, or the warning time is 0.
function Engine:FireWarn(id, cycle)
    local st = states[id]
    local r = st and ns.GetReminder(st.rid)
    if not (st and r) or st.cycle ~= cycle or st.warned then return end
    if effectiveWarn(r) <= 0 then return end  -- threshold changed to 0 after scheduling
    st.warned = true
    persist()
    if not (r.enabled and ns.db.enabled) then return end
    -- Paused: the warning is marked as done (so it is never replayed later) but
    -- no popup, sound or chat message is produced.
    if ns.Pause and ns.Pause.IsPaused() then ns.Debug("warn suppressed (paused)", r.name); return end
    local remain = st.expires - now()
    local est = st.source == "predicted" or st.source == "manual"
    if r.perMember then
        -- merged with the other members' warnings (see "Merged alerts")
        queueAlert(r, "warn", st.member or "you", est, remain)
        if not st.member and ns.Announce then ns.Announce.Warn(r, st, remain) end
        ns.Debug("warn", label(r, st), "cycle", cycle, st.source)
        return
    end
    local msg = string.format("%s expires in %s", label(r, st), fmtTime(remain))
    if est then msg = msg .. " (est.)" end
    ns.Popup.Show(msg)
    ns.Sounds.Play(r.warnSound)
    if ns.Announce then ns.Announce.Warn(r, st, remain) end
    ns.Debug("warn", r.name, "cycle", cycle, st.source)
end

-- Expiration: re-check the buff one last time (it may have been refreshed),
-- then alert once with honest wording (see header) and end the cycle.
function Engine:FireExpire(id, cycle, verifiedGone, why)
    local st = states[id]
    local r = st and ns.GetReminder(st.rid)
    if not (st and r) or st.cycle ~= cycle or st.expired then return end

    -- Last-moment re-check of a member's copy (it may have been refreshed).
    if not verifiedGone and st.member then
        local unit = C.UnitByName(st.member)
        if unit and C.IsDead(unit) then
            verifiedGone, why = true, "dead"
        elseif unit then
            local status, aura = C.FindUnitBuff(unit, r, true)
            if status == "present" and aura.expires and aura.expires > now() + 1 then
                Engine:ApplyMember(r, st.member, aura)
                return
            end
            if status == "absent" and st.source ~= "predicted" then verifiedGone = true end
        end
    end
    -- Last-moment re-check for self buffs: if a readable aura says it lasts
    -- longer (refreshed without a detected cast), move the timer instead.
    if not verifiedGone and r.kind == "self" and not st.member then
        local status, aura = C.FindPlayerBuff(r)
        if status == "present" and aura.expires and aura.expires > now() + 1 then
            Engine:ApplyAura(r, aura)
            return
        end
        -- Absence only counts if this cycle's aura was actually seen before;
        -- otherwise a spell ID/name mismatch could look like a removal.
        if status == "absent" and st.source == "verified" then verifiedGone = true end
    end

    st.expired = true
    cancelTimers(st)
    states[id] = nil
    persist()
    if not (r.enabled and ns.db.enabled and r.expireAlert) then return end
    -- Paused: the cycle has already ended above, so nothing can fire later.
    if ns.Pause and ns.Pause.IsPaused() then ns.Debug("expire suppressed (paused)", r.name); return end
    local kind
    if verifiedGone and st.expires - now() > 3 then
        kind = "ended"
    elseif verifiedGone or st.source == "verified" or st.source == "shared" then
        kind = "expired"
    else
        kind = "likely"
    end
    if r.perMember then
        local who = st.member or "you"
        if why == "dead" then who = who .. " (died)" end
        queueAlert(r, kind, who, kind == "likely")
        ns.Debug("expire", label(r, st), "cycle", cycle, st.source, why or "")
        return
    end
    local msg
    if kind == "ended" then
        msg = label(r, st) .. " has ended"
    elseif kind == "expired" then
        msg = label(r, st) .. " has expired"
    else
        msg = label(r, st) .. " has likely expired (est.)"
    end
    ns.Popup.Show(msg)
    ns.Sounds.Play(r.expireSound)
    ns.Debug("expire", r.name, "cycle", cycle, st.source, verifiedGone and "verified-gone" or "")
end

schedule = function(r, st)
    cancelTimers(st)
    local t = now()
    local cycle = st.cycle
    local key = st.key
    local warnAt = st.expires - effectiveWarn(r)
    if not st.warned and effectiveWarn(r) > 0 then
        if warnAt > t then
            st.warnTimer = ns.NewTimer("Engine", warnAt - t, function() Engine:FireWarn(key, cycle) end)
        elseif st.expires > t then
            -- Already inside the warning window (e.g. found on login): warn now, once.
            ns.After("Engine", 0, function() Engine:FireWarn(key, cycle) end)
        end
    end
    local d = st.expires - t
    if d < 0 then d = 0 end
    st.expireTimer = ns.NewTimer("Engine", d, function() Engine:FireExpire(key, cycle) end)
end

-- "Bob-Server" -> "Bob" (member names are shown and keyed without the realm).
local function shortName(n) return (tostring(n):gsub("%-.*$", "")) end
-- Key of a member's copy: "<id>:<lowercase name>".
local function memberKey(r, name) return r.id .. ":" .. shortName(name):lower() end
Engine.MemberKey = memberKey

-- Start a brand-new cycle (cast, recast, or first detection).
-- member: a group member's name for a per-member copy (nil = the normal cycle).
function Engine:Start(r, expires, source, recipient, member)
    local key = member and memberKey(r, member) or r.id
    local old = states[key]
    if old then cancelTimers(old) end
    cycleCounter = cycleCounter + 1
    local st = {
        key = key, rid = r.id, member = member and shortName(member) or nil,
        cycle = cycleCounter, expires = expires, startedAt = now(),
        source = source, recipient = recipient or (old and r.kind == "targeted" and old.recipient) or nil,
        warned = false, expired = false,
    }
    states[key] = st
    schedule(r, st)
    persist()
    ns.Debug("start", label(r, st), "cycle", st.cycle, source, "in", fmtTime(expires - now()))
    return st
end

-- Adjust current cycle's expiration (prediction corrected by a real aura).
local function adjust(r, st, expires, source)
    st.expires = expires
    st.source = source
    -- If the correction moves the warning point back into the future and no
    -- warning has fired yet, schedule() handles it; warned stays as it was.
    schedule(r, st)
    persist()
end

-- Feed a readable aura into the engine. member = group member's name for a
-- per-member copy (nil = the normal cycle).
local function applyAura(r, aura, recipient, member)
    ns.Debug("aura", r.name, member or "", "spell", aura.spellId, "dur", aura.duration, "left", aura.expires and (aura.expires - now()) or "?")
    local dur = aura.duration
    if dur and dur > 0 and math.abs(dur - (r.learnedDuration or 0)) > 0.5 then
        r.learnedDuration = dur
        ns.Debug("learned duration", r.name, dur)
    end
    local exp = aura.expires
    if not exp or exp <= 0 then return end   -- permanent or unreadable timing
    if exp <= now() then return end
    local st = states[member and memberKey(r, member) or r.id]
    if not st then
        Engine:Start(r, exp, "verified", recipient, member)
    elseif exp > st.expires + 1.5 and st.source == "verified" then
        -- Expiration moved later than a verified value: a refresh happened.
        Engine:Start(r, exp, "verified", recipient or st.recipient, member)
    elseif math.abs(exp - st.expires) > 0.25 or st.source ~= "verified" then
        adjust(r, st, exp, "verified")
    end
end
function Engine:ApplyAura(r, aura, recipient) applyAura(r, aura, recipient, nil) end
function Engine:ApplyMember(r, member, aura) applyAura(r, aura, nil, member) end

-- End a member's copy WITHOUT an alert (they left the group, another
-- player's copy replaced yours, or the option was turned off).
local function dropMember(key, why)
    local st = states[key]
    if not st then return end
    cancelTimers(st); states[key] = nil
    ns.Debug("member copy dropped", key, why or "")
    persist()
end

-- Verification -------------------------------------------------------------
function Engine:VerifySelf(r, snap)
    local status, aura = C.FindPlayerBuff(r, snap)
    local st = states[r.id]
    if status == "present" then
        if aura.expires then
            Engine:ApplyAura(r, aura)
        end
        return status
    end
    if status == "absent" and st and st.source == "verified" then
        -- Give a fresh cast time for the aura to land before trusting absence.
        if now() - st.startedAt < 3 then return status end
        Engine:FireExpire(r.id, st.cycle, true)
    end
    return status
end

-- Check a "buff I cast on others" reminder against the recipient's buffs.
function Engine:VerifyTargeted(r)
    local st = states[r.id]
    if not (st and st.recipient) then return "unknown" end
    local unit = C.UnitByName(st.recipient)
    if not unit then return "unknown" end
    local status, aura = C.FindUnitBuff(unit, r)
    if status == "present" and aura.expires then
        Engine:ApplyAura(r, aura, st.recipient)
    elseif status == "absent" and st.source == "verified" and now() - st.startedAt >= 3 then
        Engine:FireExpire(r.id, st.cycle, true)
    end
    return status
end

-- Per-member tracking: check one group member for YOUR copy of r's buff.
--   present (cast by you)   -> start / correct their cycle (verified)
--   another player's copy   -> drop their cycle silently (they're still buffed)
--   absent / dead           -> "has ended" (only once their copy was seen,
--                              or immediately when they died)
--   hidden / out of range   -> nothing changes; the estimate keeps running
function Engine:VerifyMember(r, unit)
    if not (r.perMember and r.kind ~= "timer") then return "unknown" end
    local ok, n = pcall(UnitName, unit)
    local name = ok and C.Str(n)
    local me = C.PlayerName()
    if not name or (me and shortName(name):lower() == me:lower()) then return "unknown" end
    local key = memberKey(r, name)
    local st = states[key]
    if st and C.IsDead(unit) then
        Engine:FireExpire(key, st.cycle, true, "dead")
        return "dead"
    end
    local status, aura = C.FindUnitBuff(unit, r, true)
    if status == "present" then
        if aura.expires then Engine:ApplyMember(r, name, aura) end
    elseif status == "other" then
        if st then dropMember(key, "replaced by another player's copy") end
    elseif status == "absent" and st and st.source ~= "predicted" and now() - st.startedAt >= 3 then
        Engine:FireExpire(key, st.cycle, true)
    end
    return status
end

-- Unit tokens of the other group members ("party1".."party4" or "raid1".."raid40").
local function groupUnits()
    local out = {}
    local inRaid = _G.IsInRaid and C.Bool(IsInRaid())
    local prefix, n = inRaid and "raid" or "party", inRaid and 40 or 4
    for i = 1, n do
        local u = prefix .. i
        if _G.UnitExists and C.Bool(UnitExists(u)) then out[#out + 1] = u end
    end
    return out
end

-- Forget member copies of players who are no longer in the group.
local function pruneMembers()
    for key, st in pairs(states) do
        if st.member and not C.UnitByName(st.member) then dropMember(key, "left the group") end
    end
end

-- Re-check every enabled reminder (login, after combat, after a profile switch).
function Engine:VerifyAll()
    if not ns.db then return end
    local snap = C.SnapshotPlayerBuffs()   -- one scan for all reminders
    local units
    for _, r in ipairs(ns.db.reminders) do
        if r.enabled then
            if r.kind == "self" then Engine:VerifySelf(r, snap)
            elseif r.kind == "targeted" then Engine:VerifyTargeted(r) end
            if r.perMember and r.kind ~= "timer" then
                units = units or groupUnits()
                for _, u in ipairs(units) do Engine:VerifyMember(r, u) end
            end
        end
    end
end

-- Coalesce bursts of UNIT_AURA into one check per unit.
local verifyQueued = {}
-- Batch a burst of UNIT_AURA events into one check per unit, 0.15 s later.
local function queueVerify(unit)
    if verifyQueued[unit] then return end
    verifyQueued[unit] = true
    ns.After("Engine", 0.15, function()
        verifyQueued[unit] = nil
        local snap = unit == "player" and C.SnapshotPlayerBuffs() or nil
        -- the Aspect warning (CombatAlerts.lua) reuses this one scan
        if snap and ns.CombatAlerts and not C.InCombat() then ns.CombatAlerts.ReadAspects(snap) end
        for _, r in ipairs(ns.db.reminders) do
            if r.enabled then
                if unit == "player" and r.kind == "self" then
                    Engine:VerifySelf(r, snap)
                elseif r.kind == "targeted" then
                    local st = states[r.id]
                    if st and st.recipient and C.UnitByName(st.recipient) == unit then
                        Engine:VerifyTargeted(r)
                    end
                end
                if unit ~= "player" and r.perMember and r.kind ~= "timer" then
                    Engine:VerifyMember(r, unit)
                end
            end
        end
    end)
end

-- Cast detection -----------------------------------------------------------
local function matchReminders(spellID, spellName)
    local out = {}
    local lname = spellName and spellName:lower()
    for _, r in ipairs(ns.db.reminders) do
        if r.enabled then
            local hit, byName = false, false
            for _, id in ipairs(r.spellIDs) do if id == spellID then hit = true end end
            for _, id in ipairs(r.learnedIDs) do if id == spellID then hit = true end end
            if not hit and lname then
                for _, n in ipairs(r.names) do
                    if type(n) == "string" and n:lower() == lname then hit, byName = true, true end
                end
            end
            if hit then
                if byName then
                    table.insert(r.learnedIDs, spellID)
                    ns.Print(string.format("learned spell ID %d for %s", spellID, r.name))
                end
                out[#out + 1] = r
            end
        end
    end
    return out
end

-- Remember who a cast is aimed at, keyed by castGUID, until it succeeds.
local function onSent(_, unit, target, castGUID, spellID)
    if unit ~= "player" then return end
    local guid = C.Str(castGUID)
    if not guid then return end
    pendingSent[guid] = { target = C.Str(target), t = now(), targetSecret = C.IsSecret(target) }
    -- prune
    for g, p in pairs(pendingSent) do
        if now() - p.t > 30 then pendingSent[g] = nil end
    end
end

-- A self buff cast on a group member: start (or restart) that member's copy
-- when "Track on each group member" is on; otherwise offer the option once.
local hinted = {}
local function castOnMember(r, target, dur)
    local unit = C.UnitByName(target)
    if not unit then
        ns.Debug(r.name, "cast on", target, "(not in group) - not tracked")
        return
    end
    if not r.perMember then
        if not hinted[r.id] then
            hinted[r.id] = true
            ns.Print(string.format("tip: you cast %s on %s. Turn on \"Track on each group member\" for %s (settings) to get alerts for their copy too.",
                r.name, shortName(target), r.name))
        end
        return
    end
    Engine:Start(r, now() + dur, "predicted", nil, target)
    ns.After("Engine", 0.6, function()
        local u = C.UnitByName(target)
        if u then Engine:VerifyMember(r, u) end
    end)
end

-- A cast landed: record it for /skwirlert casts, find matching reminders and
-- start (or restart) their cycles. Learns new spell IDs that match by name.
local function onSucceeded(_, unit, castGUID, spellID)
    if unit ~= "player" then return end
    if not (ns.db and ns.db.enabled) then return end
    local sid = C.Num(spellID)
    local guid = C.Str(castGUID)
    local sent = guid and pendingSent[guid]
    if guid then pendingSent[guid] = nil end
    if not sid then
        ns.Debug("cast succeeded but spell ID is secret/unavailable; cannot match")
        return
    end
    local sname = C.SpellName(sid)
    table.insert(recentCasts, 1, { id = sid, name = sname or "?", target = sent and sent.target, t = now() })
    while #recentCasts > 15 do table.remove(recentCasts) end

    local list = matchReminders(sid, sname)
    ns.Debug("cast", sid, sname or "?", "target", sent and sent.target or "-", "matched", #list)
    if #list == 0 then return end
    local me = C.PlayerName()
    for _, r in ipairs(list) do
        local dur = r.learnedDuration or r.duration
        local target = sent and sent.target
        if r.kind == "self" then
            -- A "self" buff cast on someone else (e.g. Arcane Intellect on a
            -- party member) does not refresh the player's own buff.
            local onOther = target and me and shortName(target):lower() ~= me:lower()
            if onOther then
                ns.Debug(r.name, "cast on", target, "- not a self refresh")
                castOnMember(r, target, dur)
            else
                local st = states[r.id]
                if st and st.source == "verified" and now() - st.startedAt < 1.0 then
                    ns.Debug(r.name, "already refreshed by aura update")
                else
                    Engine:Start(r, now() + dur, "predicted")
                end
                if ns.Announce then ns.Announce.Applied(r, states[r.id]) end
                ns.After("Engine", 0.4, function() Engine:VerifySelf(r) end)
            end
        elseif r.kind == "targeted" then
            local recipient = target
            if not recipient and not (sent and sent.targetSecret) then
                -- No explicit target reported: the client used the current target or self.
                local ok, tn = pcall(UnitName, "target")
                recipient = ok and C.Str(tn) or me
            end
            if r.perMember and recipient and recipient ~= me and C.UnitByName(recipient) then
                -- one copy per recipient (e.g. Blessing on several players)
                castOnMember(r, recipient, dur)
                local st = states[memberKey(r, recipient)]
                if st and ns.Announce then ns.Announce.Applied(r, st) end
            else
                local st = Engine:Start(r, now() + dur, "predicted", recipient or "unknown target")
                if ns.Announce then ns.Announce.Applied(r, st) end
                if recipient then ns.After("Engine", 0.6, function() Engine:VerifyTargeted(r) end) end
            end
        else -- timer
            local st = Engine:Start(r, now() + dur, "predicted")
            if ns.Announce then ns.Announce.Applied(r, st) end
        end
    end
end

-- Group Sync fill-in: a groupmate's own Skwirlert shared its timers. If it
-- tracks the same buff on itself (time read from the real aura), use that to
-- correct OUR estimate for the copy we put on them. Only estimates are
-- corrected; a value we read ourselves always wins.
function Engine:OnPeerTimers(sender, entries)
    if not (ns.db and sender) then return end
    for _, r in ipairs(ns.db.reminders) do
        local st = r.enabled and r.perMember and states[memberKey(r, sender)]
        if st and st.source == "predicted" then
            local names = { [r.name:lower()] = true }
            for _, n in ipairs(r.names) do if type(n) == "string" then names[n:lower()] = true end end
            for _, e in ipairs(entries) do
                if e.kind == "v" and not e.recipient and names[e.name:lower()]
                    and e.expiresAt > now() and math.abs(e.expiresAt - st.expires) < 600 then
                    adjust(r, st, e.expiresAt, "shared")
                    ns.Debug("member copy corrected from Group Sync", r.name, sender)
                    break
                end
            end
        end
    end
end

-- Manual control -----------------------------------------------------------
function Engine:StartManual(r)
    local st = Engine:Start(r, now() + (r.learnedDuration or r.duration), "manual")
    if ns.Announce then ns.Announce.Applied(r, st) end
    return st
end

-- Stop one reminder's cycles (its own and every member copy) without any
-- alert (disable, delete, Stop).
function Engine:Clear(id)
    local any = false
    for key, st in pairs(states) do
        if st.rid == id then cancelTimers(st); states[key] = nil; any = true end
    end
    if any then persist() end
end

-- Re-schedule after the reminder's settings changed.
function Engine:OnConfigChanged(r)
    if not r.enabled then Engine:Clear(r.id); return end
    for key, st in pairs(states) do
        if st.rid == r.id then
            if st.member and (not r.perMember or r.kind == "timer") then
                dropMember(key, "per-member tracking turned off")
            else
                schedule(r, st)
            end
        end
    end
end

-- The running cycle for a reminder, or nil if it isn't running.
function Engine:State(id) return states[id] end

-- Running member copies of a reminder, soonest first: { state, ... }
function Engine:Members(id)
    local out = {}
    for _, st in pairs(states) do
        if st.rid == id and st.member then out[#out + 1] = st end
    end
    table.sort(out, function(a, b) return a.expires < b.expires end)
    return out
end

-- Is anything running for this reminder (own cycle or any member copy)?
function Engine:Running(id)
    if states[id] then return true end
    for _, st in pairs(states) do if st.rid == id then return true end end
    return false
end

-- Stop everything (profile switch / reset). No alerts are fired.
function Engine:ClearAll()
    for id, st in pairs(states) do cancelTimers(st); states[id] = nil end
    persist()
end

-- Restore cycles saved before a UI reload.
local function restore()
    local saved = ns.char.active
    ns.char.active = {}
    if type(saved) ~= "table" then return end
    local t = now()
    for key, s in pairs(saved) do
        local rid = type(s) == "table" and (tonumber(s.rid) or tonumber(key))
        local r = rid and ns.GetReminder(rid)
        local member = type(s) == "table" and type(s.member) == "string" and s.member or nil
        if r and r.enabled and type(s.expires) == "number"
            and s.expires > t and s.expires < t + 86400
            and (not member or r.perMember) then
            local st = Engine:Start(r, s.expires, s.source or "predicted", s.recipient, member)
            st.startedAt = s.startedAt or t
            if s.warned then st.warned = true; schedule(r, st) end
        end
    end
    persist()
end

-- Wiring -------------------------------------------------------------------
ns.RegisterInit(function()
    ns.OnUnit("UNIT_SPELLCAST_SENT", "player", onSent)
    ns.OnUnit("UNIT_SPELLCAST_SUCCEEDED", "player", onSucceeded)
    ns.On("UNIT_AURA", function(_, unit)
        if C.IsSecret(unit) or type(unit) ~= "string" then return end
        if unit == "player" or unit:find("^party") or unit:find("^raid") then queueVerify(unit) end
    end)
    ns.On("PLAYER_REGEN_ENABLED", function() ns.After("Engine", 0.5, function() Engine:VerifyAll() end) end)
    ns.On("PLAYER_ENTERING_WORLD", function() ns.After("Engine", 2, function() Engine:VerifyAll() end) end)
    ns.On("GROUP_ROSTER_UPDATE", function() ns.After("Engine", 1, function() pruneMembers(); Engine:VerifyAll() end) end)
    ns.On("PLAYER_LOGOUT", function() persist() end)
    restore()
end)
