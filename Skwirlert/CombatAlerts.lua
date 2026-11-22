-- =============================================================================
-- Skwirlert - CombatAlerts.lua  (0.9.0: Aspect warning + after-combat group check)
-- =============================================================================
-- WHAT THIS FILE DOES
--   Two alerts that are about combat rather than about a buff's timer:
--
--   1. ASPECT WARNING (Aspect of the Cheetah / Aspect of the Pack daze you
--      when you're hit).
--      * Hunter with Cheetah or Pack on: alert when YOU enter combat.
--      * Hunter with Pack on: also alert when a GROUP MEMBER enters combat
--        (Pack dazes everyone in range), e.g. "Aspect of the Pack is on —
--        Bob is in combat".
--      * Anyone (option "Pack on me"): a hunter's Pack shows as a buff on you;
--        alert when you or the group enter combat.
--      * Hunter (option "Tell the group in chat", off by default): post ONE
--        line to the group when Pack is on and the group enters combat, for
--        groupmates who don't run Skwirlert.
--      At most one aspect alert per fight. Aspects don't run out, so they are
--      not countdown reminders; this alert needs no setup and is on by default.
--
--   2. AFTER-COMBAT GROUP CHECK. When combat ends (and a few seconds later,
--      so healers can act first), check everyone in the group for a Curse,
--      Disease (optionally Poison, Magic) and for anyone dead. Show one popup,
--      and post ONE message to Group (auto) with names, e.g.
--        "Bob needs a Curse removed (Curse of Agony). Ann is dead - needs a resurrection.
--         Can help: Curse - Me; Resurrect - Cy."
--      "Can help" lists only players whose Skwirlert reported knowing a fitting
--      spell (your own spellbook + Group Sync). Nothing is guessed from class.
--      * Only one Skwirlert in the group posts: the others hear its claim over
--        Group Sync and stay quiet. Each person/problem is announced at most
--        once a minute.
--
-- DESIGN: events only, no polling.
--   PLAYER_REGEN_DISABLED / ENABLED (you), UNIT_FLAGS (group members' combat
--   flag). The aspect is remembered from Engine.lua's existing buff scan
--   (UNIT_AURA, out of combat), because buff data may be hidden the moment
--   combat starts. No extra scan of your buffs is made.
--
-- SETTINGS (per profile): <profile>.alerts  (see ns.EmptyProfile in Core.lua)
-- =============================================================================

local _, ns = ...
local C = ns.Compat
local CA = {}
ns.CombatAlerts = CA

local ASPECT_CHEETAH, ASPECT_PACK = 5118, 13159
local REPEAT_GAP = 60          -- seconds before the same person/problem is announced again
local ASPECT_GAP = 20          -- seconds between aspect alerts (one per fight)

CA.TYPES = { "curse", "disease", "poison", "magic" }
CA.TYPE_LABEL = { curse = "Curse", disease = "Disease", poison = "Poison", magic = "Magic", dead = "Resurrect" }
local DISPEL = { Curse = "curse", Disease = "disease", Poison = "poison", Magic = "magic" }
local CAP_LETTER = { curse = "c", disease = "d", poison = "p", magic = "m", dead = "r" }
CA.CAP_LETTER = CAP_LETTER

-- Spells that remove each problem. Used ONLY to check the player's own
-- spellbook (a name lookup succeeds only for spells you know), never to guess
-- what another class can do. English names; other client languages simply
-- report "can't help" (see UNVERIFIED.md).
CA.CURE_SPELLS = {
    curse   = { "Remove Curse", "Remove Lesser Curse" },
    disease = { "Cure Disease", "Abolish Disease", "Purify", "Cleanse" },
    poison  = { "Cure Poison", "Abolish Poison", "Purify", "Cleanse" },
    magic   = { "Dispel Magic", "Cleanse" },
    dead    = { "Resurrection", "Redemption", "Ancestral Spirit", "Revive", "Rebirth" },
}

local function now() return GetTime() end
function CA.Settings() return ns.db and ns.db.alerts end
local function quiet()
    return not (ns.db and ns.db.enabled) or (ns.Pause and ns.Pause.IsPaused())
end

-- Short name: "Bob-Server" -> "Bob".
local function short(n) n = C.Str(n); return n and (n:gsub("%-.*$", "")) or nil end

-- Unit tokens of the whole group, including you ("player"); raid tokens in a raid.
local function groupUnits(includePlayer)
    local out = {}
    local inRaid = _G.IsInRaid and C.Bool(IsInRaid())
    if inRaid then
        for i = 1, 40 do
            local u = "raid" .. i
            if _G.UnitExists and C.Bool(UnitExists(u)) then
                if includePlayer or not (_G.UnitIsUnit and C.Bool(UnitIsUnit(u, "player"))) then out[#out + 1] = u end
            end
        end
    else
        if includePlayer then out[1] = "player" end
        for i = 1, 4 do
            local u = "party" .. i
            if _G.UnitExists and C.Bool(UnitExists(u)) then out[#out + 1] = u end
        end
    end
    return out
end
CA.GroupUnits = groupUnits

-- =============================================================================
-- 1. Aspect warning
-- =============================================================================
local aspect = { cheetah = false, pack = false, packMine = false }   -- last readable state
CA.aspectState = aspect
local lastAspectAlert = -1e9
local fightAlerted = false
local memberCombat = {}       -- [unit] = true while that member is in combat

local function isHunter()
    if not _G.UnitClass then return false end
    local ok, _, file = pcall(UnitClass, "player")
    return ok and C.Str(file) == "HUNTER"
end
CA.IsHunter = isHunter

local function aspectName(id, fallback) return C.SpellName(id) or fallback end

-- Read the aspects from one buff snapshot. Returns false if buff data is hidden.
local function readAspects(snap)
    snap = snap or C.SnapshotPlayerBuffs()
    if snap.hidden then return false end
    local function find(id, name)
        local a = snap.byId[id]
        if not a and name then a = snap.byName[name:lower()] end
        return a
    end
    local ch = find(ASPECT_CHEETAH, aspectName(ASPECT_CHEETAH, "Aspect of the Cheetah"))
    local pk = find(ASPECT_PACK, aspectName(ASPECT_PACK, "Aspect of the Pack"))
    aspect.cheetah = ch ~= nil
    aspect.pack = pk ~= nil
    aspect.packMine = pk ~= nil and pk.source == "player"
    return true
end
CA.ReadAspects = readAspects

-- What should we warn about right now? reason = "you" or a member's name.
local function aspectMessage(reason)
    local s = CA.Settings()
    if not (s and s.aspect) then return nil end
    local hunter = isHunter()
    local cheetahName = aspectName(ASPECT_CHEETAH, "Aspect of the Cheetah")
    local packName = aspectName(ASPECT_PACK, "Aspect of the Pack")
    if reason == "you" then
        if hunter and aspect.cheetah then return cheetahName .. " is on - you'll be dazed when hit!" end
        if hunter and aspect.packMine then return packName .. " is on - you're in combat!" end
        if aspect.pack and s.packOnMe then return packName .. " is on you - you'll be dazed when hit!" end
    else
        if hunter and aspect.packMine and s.packGroup then return packName .. " is on - " .. reason .. " is in combat!" end
        if aspect.pack and not aspect.packMine and s.packOnMe and s.packGroup then
            return packName .. " is on you - " .. reason .. " is in combat!"
        end
    end
    return nil
end

local function fireAspect(reason)
    if fightAlerted or now() - lastAspectAlert < ASPECT_GAP then return end
    local msg = aspectMessage(reason)
    if not msg then return end
    fightAlerted = true
    lastAspectAlert = now()
    if quiet() then ns.Debug("aspect alert suppressed (paused/disabled)"); return end
    ns.Popup.Show(msg)
    ns.Sounds.Play(CA.Settings().aspectSound)
    ns.Log("aspect alert", reason)
    -- Hunter's own Pack: optionally tell the whole group (people without Skwirlert).
    local s = CA.Settings()
    local grouped = _G.IsInGroup and C.Bool(IsInGroup())
    if s.packAnnounce ~= "off" and grouped and isHunter() and aspect.packMine then
        ns.Announce.Send(s.packAnnounce, aspectName(ASPECT_PACK, "Aspect of the Pack") .. " is on - you'll be dazed if hit!")
    end
end
CA.FireAspect = fireAspect

-- Nobody (you or a groupmate) in combat any more -> the next fight may alert again.
local function maybeEndFight()
    if C.InCombat() then return end
    for _, v in pairs(memberCombat) do if v then return end end
    fightAlerted = false
end

local function onPlayerCombat()
    -- Buff data may already be hidden; then the state read before combat is used.
    readAspects()
    fireAspect("you")
end

local function onUnitFlags(_, unit)
    if C.IsSecret(unit) or type(unit) ~= "string" then return end
    if not (unit:find("^party%d") or unit:find("^raid%d")) then return end
    if _G.UnitIsUnit and C.Bool(UnitIsUnit(unit, "player")) then return end
    local ok, v = pcall(UnitAffectingCombat, unit)
    local inCombat = ok and C.Bool(v) or false
    local was = memberCombat[unit]
    memberCombat[unit] = inCombat or nil
    if inCombat and not was then
        local okN, n = pcall(UnitName, unit)
        fireAspect(okN and short(n) or "a group member")
    elseif not inCombat and was then
        maybeEndFight()
    end
end

-- =============================================================================
-- 2. After-combat group check
-- =============================================================================
local myCaps = ""
local announced = {}      -- ["bob/curse"] = time announced (by us or a groupmate)
local checkPending

-- Which problems can YOUR character fix? Letters c/d/p/m/r (see CAP_LETTER).
function CA.ComputeCaps()
    local letters = {}
    for _, kind in ipairs({ "curse", "disease", "poison", "magic", "dead" }) do
        for _, spell in ipairs(CA.CURE_SPELLS[kind]) do
            if C.SpellIDFromName(spell) then letters[#letters + 1] = CAP_LETTER[kind]; break end
        end
    end
    myCaps = table.concat(letters)
    return myCaps
end
function CA.Caps() return myCaps end

-- A groupmate's Skwirlert announced these (keys "name/type"): don't repeat them.
function CA.OnClaim(keys)
    local t = now()
    for _, k in ipairs(keys) do announced[k:lower()] = t end
end

-- Scan the group. Returns a list of { name, problems = { {type, debuff} }, dead }.
function CA.Scan()
    local s = CA.Settings()
    local out = {}
    local t = now()
    for _, unit in ipairs(groupUnits(true)) do
        local okN, n = pcall(UnitName, unit)
        local name = okN and short(n)
        local connected = not _G.UnitIsConnected or C.Bool(UnitIsConnected(unit)) or unit == "player"
        if name and connected then
            local entry = { name = name, unit = unit, problems = {} }
            if C.IsDead(unit) then
                if s.dead then entry.dead = true end
            else
                local seen = {}
                for _, d in ipairs(C.ListUnitDebuffs(unit)) do
                    local kind = DISPEL[d.dtype]
                    local lasting = not (d.expires and d.expires > 0 and d.expires - t < 5)   -- about to wear off anyway
                    if kind and s[kind] and lasting and not seen[kind] then
                        seen[kind] = true
                        entry.problems[#entry.problems + 1] = { type = kind, debuff = d.name }
                    end
                end
            end
            if entry.dead or #entry.problems > 0 then out[#out + 1] = entry end
        end
    end
    return out
end

-- Who can help with each problem: you (spellbook) + groupmates whose Skwirlert said so.
local function helpers(kind)
    local list = {}
    local letter = CAP_LETTER[kind]
    if myCaps:find(letter, 1, true) then list[#list + 1] = short(_G.UnitName and UnitName("player")) or "me" end
    if ns.Sync and ns.Sync.PeerCaps then
        local names = {}
        for name, caps in pairs(ns.Sync.PeerCaps()) do
            if caps:find(letter, 1, true) then names[#names + 1] = name end
        end
        table.sort(names)
        for _, n in ipairs(names) do list[#list + 1] = n end
    end
    return list
end
CA.Helpers = helpers

local function article(kind) return (kind == "magic") and "" or "a " end

-- Build the chat text (may be split later) and the popup text.
function CA.Compose(found)
    local parts, popup, keys, needed = {}, {}, {}, {}
    for _, e in ipairs(found) do
        if e.dead then
            parts[#parts + 1] = e.name .. " is dead - needs a resurrection."
            popup[#popup + 1] = e.name .. ": dead"
            keys[#keys + 1] = e.name .. "/dead"; needed.dead = true
        end
        if #e.problems > 0 then
            local bits, pbits = {}, {}
            for _, p in ipairs(e.problems) do
                bits[#bits + 1] = article(p.type) .. CA.TYPE_LABEL[p.type] .. " removed" .. (p.debuff and (" (" .. p.debuff .. ")") or "")
                pbits[#pbits + 1] = CA.TYPE_LABEL[p.type]
                keys[#keys + 1] = e.name .. "/" .. p.type; needed[p.type] = true
            end
            parts[#parts + 1] = e.name .. " needs " .. table.concat(bits, ", ") .. "."
            popup[#popup + 1] = e.name .. ": " .. table.concat(pbits, ", ")
        end
    end
    local help = {}
    for _, kind in ipairs({ "curse", "disease", "poison", "magic", "dead" }) do
        if needed[kind] then
            local h = helpers(kind)
            if #h > 0 then help[#help + 1] = CA.TYPE_LABEL[kind] .. " - " .. table.concat(h, ", ") end
        end
    end
    if #help > 0 then parts[#parts + 1] = "Can help: " .. table.concat(help, "; ") .. "." end
    return parts, "After combat: " .. table.concat(popup, "; "), keys
end

-- Split sentences into chat lines of at most maxLen characters.
local function chunk(parts, maxLen)
    local lines, cur = {}, ""
    for _, p in ipairs(parts) do
        if #p > maxLen then p = p:sub(1, maxLen) end
        if cur == "" then cur = p
        elseif #cur + 1 + #p <= maxLen then cur = cur .. " " .. p
        else lines[#lines + 1] = cur; cur = p end
    end
    if cur ~= "" then lines[#lines + 1] = cur end
    return lines
end
CA.Chunk = chunk

-- Run the check now. manual = typed /skwirlert check or pressed Test (always
-- reports, even repeats; never claims or posts to chat unless asked to).
function CA.Check(manual, postToChat)
    local s = CA.Settings()
    if not s then return {} end
    if not manual and (not s.care or quiet()) then return {} end
    local found = CA.Scan()
    local t = now()
    if not manual then
        -- drop what was announced recently (by us or another Skwirlert)
        local keep = {}
        for _, e in ipairs(found) do
            local fresh = { name = e.name, problems = {} }
            if e.dead and t - (announced[(e.name .. "/dead"):lower()] or -1e9) >= REPEAT_GAP then fresh.dead = true end
            for _, p in ipairs(e.problems) do
                if t - (announced[(e.name .. "/" .. p.type):lower()] or -1e9) >= REPEAT_GAP then fresh.problems[#fresh.problems + 1] = p end
            end
            if fresh.dead or #fresh.problems > 0 then keep[#keep + 1] = fresh end
        end
        found = keep
    end
    if #found == 0 then
        if manual then ns.Print("group check: nobody needs a cure or a resurrection.") end
        return found
    end
    local parts, popupText, keys = CA.Compose(found)
    ns.Popup.Show(popupText)
    ns.Sounds.Play(s.careSound)
    if not manual then for _, k in ipairs(keys) do announced[k:lower()] = t end end
    local grouped = _G.IsInGroup and C.Bool(IsInGroup())
    if grouped and (postToChat or not manual) and s.careChannel ~= "off" then
        for _, line in ipairs(chunk(parts, 230)) do ns.Announce.Send(s.careChannel, line, manual) end
        if ns.Sync and ns.Sync.SendClaim then ns.Sync.SendClaim(keys) end
    elseif manual then
        for _, line in ipairs(chunk(parts, 230)) do ns.Print(line) end
    end
    ns.Log("group check", #found, "people")
    return found
end

-- Combat ended: wait a moment (healers often cure straight away), staggered
-- by our place among the group's Skwirlert users so only one of us posts.
local function scheduleCheck()
    local s = CA.Settings()
    if not (s and s.care) then return end
    if checkPending then checkPending:Cancel() end
    local rank = 0
    if ns.Sync and ns.Sync.PeerCaps then
        local me = short(_G.UnitName and UnitName("player")) or ""
        for name in pairs(ns.Sync.PeerCaps()) do if name:lower() < me:lower() then rank = rank + 1 end end
    end
    checkPending = ns.NewTimer("CombatAlerts", (s.careDelay or 3) + rank * 1.5, function()
        checkPending = nil
        if C.InCombat() then return end          -- a new pull started: check after that one
        CA.Check(false)
    end)
end

-- Wiring -------------------------------------------------------------------------
ns.RegisterInit(function()
    CA.ComputeCaps()
    readAspects()
    ns.On("PLAYER_REGEN_DISABLED", function()
        if checkPending then checkPending:Cancel(); checkPending = nil end
        onPlayerCombat()
    end)
    ns.On("PLAYER_REGEN_ENABLED", function()
        maybeEndFight()
        scheduleCheck()
    end)
    ns.On("UNIT_FLAGS", onUnitFlags)
    -- Buff changes on you: Engine.lua's batched UNIT_AURA scan calls
    -- CA.ReadAspects(snapshot), so no second scan of your buffs is needed.
    ns.On("SPELLS_CHANGED", function()
        local before = myCaps
        CA.ComputeCaps()
        if myCaps ~= before and ns.Sync and ns.Sync.MarkDirty then ns.Sync.MarkDirty() end
    end)
    ns.On("GROUP_ROSTER_UPDATE", function()
        for u in pairs(memberCombat) do if not (_G.UnitExists and C.Bool(UnitExists(u))) then memberCombat[u] = nil end end
        maybeEndFight()
    end)
end)
