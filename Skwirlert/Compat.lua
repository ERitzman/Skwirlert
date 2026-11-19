-- =============================================================================
-- Skwirlert - Compat.lua  (API compatibility layer)
-- =============================================================================
-- WHAT THIS FILE DOES
--   Wraps every game API that reads buffs, spells or units, so the rest of the
--   addon gets plain, safe values (or nil) and never has to worry about which
--   client version it's running on.
--
-- WOW CONCEPT: SECRET VALUES
--   Modern WoW clients (including WoW Forever) can return "secret" values to
--   addons, especially in combat. A secret can be passed to some UI functions,
--   but comparing it, doing math with it, or using it as a table key raises an
--   error. RULE used everywhere in Skwirlert: test a value with C.IsSecret()
--   (or use C.Num / C.Str / C.Bool, which do it for you) BEFORE touching it.
--
-- WOW CONCEPT: AURAS
--   "Aura" = buff or debuff. C_UnitAuras returns an AuraData table with fields
--   such as spellId, name, icon, duration and expirationTime (a GetTime() value).
--
-- RESULT CONVENTION FOR BUFF LOOKUPS
--   "present" + aura   the buff is there (aura.expires may be nil if hidden)
--   "absent"           the buff is definitely not there (data was readable)
--   "unknown"          we can't tell right now (combat restrictions, etc.)
--   The engine only trusts "absent" when it's safe; see AbsenceTrustworthy.
-- =============================================================================

local _, ns = ...
local C = {}
ns.Compat = C

local _issecretvalue = _G.issecretvalue

-- true if v is a secret value (or if we can't tell). Safe to call on anything.
function C.IsSecret(v)
    if _issecretvalue then
        local ok, r = pcall(_issecretvalue, v)
        if not ok then return true end      -- if we cannot tell, treat as secret
        if r then return true end
    end
    return false
end

-- Returns a plain number, or nil if missing/secret/not a number.
function C.Num(v)
    if C.IsSecret(v) then return nil end
    if type(v) == "number" then return v end
    return nil
end

-- Returns a plain non-empty string, or nil if missing/secret/empty.
function C.Str(v)
    if C.IsSecret(v) then return nil end
    if type(v) == "string" and v ~= "" then return v end
    return nil
end

-- Returns true/false, or nil if secret/missing.
function C.Bool(v)
    if C.IsSecret(v) then return nil end
    if v == nil then return nil end
    return v and true or false
end

-- Is the player in combat? Both checks are secret-safe.
function C.InCombat()
    local a = _G.InCombatLockdown and C.Bool(InCombatLockdown())
    if a then return true end
    local b = _G.UnitAffectingCombat and C.Bool(UnitAffectingCombat("player"))
    return b and true or false
end

-- Would this spell's aura be secret right now? true / false / nil (unknown).
function C.AuraSecret(spellID)
    local S = _G.C_Secrets
    if S and S.ShouldSpellAuraBeSecret then
        local ok, r = pcall(S.ShouldSpellAuraBeSecret, spellID)
        if ok then return C.Bool(r) end
    end
    return nil
end

-- Can a negative ("aura not found") result be trusted right now?
-- Out of combat: yes. In combat: only if the client says the aura is not secret.
function C.AbsenceTrustworthy(spellIDs)
    if not C.InCombat() then return true end
    if not spellIDs or #spellIDs == 0 then return false end
    for _, id in ipairs(spellIDs) do
        if C.AuraSecret(id) ~= false then return false end
    end
    return true
end

-- Spell name for an ID, trying the newest API first and falling back to older ones.
function C.SpellName(spellID)
    if not C.Num(spellID) then return nil end
    local S = _G.C_Spell
    if S and S.GetSpellName then
        local ok, n = pcall(S.GetSpellName, spellID)
        if ok and C.Str(n) then return n end
    end
    if S and S.GetSpellInfo then
        local ok, info = pcall(S.GetSpellInfo, spellID)
        if ok and type(info) == "table" and not C.IsSecret(info) and C.Str(info.name) then return info.name end
    end
    if _G.GetSpellInfo then
        local ok, n = pcall(_G.GetSpellInfo, spellID)
        if ok and C.Str(n) then return n end
    end
    return nil
end

-- Normalise an aura record (AuraData table) into plain values.
local function readAuraTable(aura)
    if C.IsSecret(aura) or type(aura) ~= "table" then return nil end
    return {
        spellId = C.Num(aura.spellId),
        name = C.Str(aura.name),
        expires = C.Num(aura.expirationTime),
        duration = C.Num(aura.duration),
        source = C.Str(aura.sourceUnit),
        icon = C.Num(aura.icon) or C.Str(aura.icon),
    }
end

-- {"Arcane Intellect"} -> { ["arcane intellect"] = true } for case-insensitive lookups.
local function lowerSet(list)
    local s = {}
    for _, n in ipairs(list or {}) do
        if type(n) == "string" then s[n:lower()] = true end
    end
    return s
end

-- Merge two lists of spell IDs into one lookup set.
local function idSet(a, b)
    local s = {}
    for _, id in ipairs(a or {}) do s[id] = true end
    for _, id in ipairs(b or {}) do s[id] = true end
    return s
end

-- Iterate helpful auras on a unit; calls fn(aura) with normalised data.
-- Returns sawSecret (true if any record could not be read).
local function forEachHelpful(unit, fn)
    local sawSecret = false
    local U = _G.C_UnitAuras
    if U and (U.GetAuraDataByIndex or U.GetBuffDataByIndex) then
        for i = 1, 40 do
            local ok, aura
            if U.GetAuraDataByIndex then
                ok, aura = pcall(U.GetAuraDataByIndex, unit, i, "HELPFUL")
            else
                ok, aura = pcall(U.GetBuffDataByIndex, unit, i)
            end
            if not ok then sawSecret = true; break end
            if C.IsSecret(aura) then
                sawSecret = true
            else
                if aura == nil then break end
                local a = readAuraTable(aura)
                if a then
                    if not a.spellId and not a.name then sawSecret = true end
                    if fn(a) then return sawSecret, true end
                end
            end
        end
        return sawSecret, false
    end
    if _G.UnitBuff then
        for i = 1, 40 do
            local ok, name, _, _, _, duration, expires, source, _, _, spellId = pcall(_G.UnitBuff, unit, i)
            if not ok then sawSecret = true; break end
            if C.IsSecret(name) or C.IsSecret(spellId) then
                sawSecret = true
            else
                if name == nil then break end
                local a = { name = C.Str(name), spellId = C.Num(spellId), expires = C.Num(expires),
                            duration = C.Num(duration), source = C.Str(source) }
                if fn(a) then return sawSecret, true end
            end
        end
        return sawSecret, false
    end
    return true, false
end

-- Find a tracked buff on the player.
-- Returns status, aura:
--   "present", aura   (aura.expires may be nil if unreadable)
--   "absent",  nil    (trustworthy negative)
--   "unknown", nil    (restricted / secret / unsupported)
-- One pass over the player's buffs, for checking many reminders at once.
function C.SnapshotPlayerBuffs()
    local snap = { byId = {}, byName = {} }
    snap.hidden = forEachHelpful("player", function(a)
        if a.spellId and not snap.byId[a.spellId] then snap.byId[a.spellId] = a end
        if a.name then
            local n = a.name:lower()
            if not snap.byName[n] then snap.byName[n] = a end
        end
    end)
    return snap
end

-- Is reminder r's buff on the player? Matches by spell ID, learned ID or name.
-- Pass a snapshot (C.SnapshotPlayerBuffs) when checking many reminders at once.
-- Returns "present"/"absent"/"unknown" (see header) and the aura if present.
function C.FindPlayerBuff(r, snap)
    local ids = idSet(r.spellIDs, r.learnedIDs)
    if snap then
        for id in pairs(ids) do
            if snap.byId[id] then return "present", snap.byId[id] end
        end
        for _, n in ipairs(r.names or {}) do
            if type(n) == "string" and snap.byName[n:lower()] then return "present", snap.byName[n:lower()] end
        end
        local allIds = {}
        for id in pairs(ids) do allIds[#allIds + 1] = id end
        if not snap.hidden and C.AbsenceTrustworthy(allIds) then return "absent", nil end
        return "unknown", nil
    end
    local U = _G.C_UnitAuras
    if U and U.GetPlayerAuraBySpellID then
        for id in pairs(ids) do
            local ok, aura = pcall(U.GetPlayerAuraBySpellID, id)
            if ok and C.IsSecret(aura) then
                return "present", { spellId = id } -- exists, but timing unreadable
            elseif ok and aura ~= nil then
                local a = readAuraTable(aura)
                if a then a.spellId = a.spellId or id; return "present", a end
            end
        end
    end
    local names = lowerSet(r.names)
    local found
    local sawSecret = forEachHelpful("player", function(a)
        if (a.spellId and ids[a.spellId]) or (a.name and names[a.name:lower()]) then
            found = a; return true
        end
    end)
    if found then return "present", found end
    local allIds = {}
    for id in pairs(ids) do allIds[#allIds + 1] = id end
    if not sawSecret and C.AbsenceTrustworthy(allIds) then return "absent", nil end
    return "unknown", nil
end

-- Find a tracked buff on another unit (e.g. Soulstone recipient).
-- mineOnly (per-member tracking): only a copy whose caster is the player
-- counts. If only another player's copy is there, returns "other".
-- A copy whose caster can't be read is not treated as yours.
function C.FindUnitBuff(unit, r, mineOnly)
    if not unit then return "unknown", nil end
    local exists = _G.UnitExists and C.Bool(UnitExists(unit))
    if not exists then return "unknown", nil end
    local ids = idSet(r.spellIDs, r.learnedIDs)
    local names = lowerSet(r.names)
    local found, other, casterUnknown
    local sawSecret = forEachHelpful(unit, function(a)
        if (a.spellId and ids[a.spellId]) or (a.name and names[a.name:lower()]) then
            if not mineOnly or a.source == "player" then found = a; return true end
            if a.source then other = true else casterUnknown = true end
        end
    end)
    if found then return "present", found end
    if casterUnknown then return "unknown", nil end
    if other then return "other", nil end
    local allIds = {}
    for id in pairs(ids) do allIds[#allIds + 1] = id end
    -- Out of range units return no auras; only trust absence if visible.
    local visible = _G.UnitIsVisible and C.Bool(UnitIsVisible(unit))
    if not sawSecret and visible and C.AbsenceTrustworthy(allIds) then return "absent", nil end
    return "unknown", nil
end

-- List the player's current helpful auras for the buff picker.
-- Returns list (sorted by name), hidden (true if any record was unreadable).
function C.ListPlayerBuffs()
    local list, seen = {}, {}
    local hidden = forEachHelpful("player", function(a)
        if a.name or a.spellId then
            local key = tostring(a.spellId or a.name)
            if not seen[key] then
                seen[key] = true
                list[#list + 1] = a
            end
        end
    end)
    table.sort(list, function(x, y) return (x.name or "") < (y.name or "") end)
    return list, hidden
end

-- "Bob-Server" -> "bob" (for comparing names).
local function stripRealm(n)
    return (n:gsub("%-.*$", "")):lower()
end

-- Find a unit token in the player's group by character name.
function C.UnitByName(name)
    if not C.Str(name) then return nil end
    local want = stripRealm(name)
    local units = { "player" }
    local inRaid = _G.IsInRaid and C.Bool(IsInRaid())
    if inRaid then
        for i = 1, 40 do units[#units + 1] = "raid" .. i end
    else
        for i = 1, 4 do units[#units + 1] = "party" .. i end
    end
    for _, u in ipairs(units) do
        local ok, n = pcall(UnitName, u)
        if ok and C.Str(n) and stripRealm(n) == want then return u end
    end
    return nil
end

-- Is the unit dead or a ghost? false when unknown.
function C.IsDead(unit)
    local fn = _G.UnitIsDeadOrGhost
    if not fn then return false end
    local ok, v = pcall(fn, unit)
    return ok and C.Bool(v) or false
end

-- Spell ID for a spell NAME the character knows (used to fill in the optional
-- Spell ID field). Returns nil when unknown: matching by name works anyway,
-- and the ID is learned on the first cast. Unconfirmed on Forever: whether
-- these functions accept a name there (see UNVERIFIED.md).
function C.SpellIDFromName(name)
    if not C.Str(name) or name == "" then return nil end
    local S = _G.C_Spell
    if S and S.GetSpellInfo then
        local ok, info = pcall(S.GetSpellInfo, name)
        if ok and type(info) == "table" and not C.IsSecret(info) then
            local id = C.Num(info.spellID)
            if id then return id end
        end
    end
    if _G.GetSpellInfo then
        local ok, _, _, _, _, _, _, id = pcall(_G.GetSpellInfo, name)
        if ok and C.Num(id) then return id end
    end
    return nil
end

-- The player's own character name, or nil.
function C.PlayerName()
    local ok, n = pcall(UnitName, "player")
    if ok then return C.Str(n) end
end

-- Current time (GetTime). Kept as a function so tests can control the clock.
function C.Now()
    return GetTime()
end

-- Diagnostic probe for /skwirlert api
function C.Probe()
    local function has(path)
        local cur = _G
        for part in path:gmatch("[^%.]+") do
            if type(cur) ~= "table" then return false end
            cur = cur[part]
        end
        return cur ~= nil
    end
    local list = {
        "issecretvalue", "canaccessvalue", "C_Secrets", "C_Secrets.ShouldSpellAuraBeSecret",
        "C_UnitAuras", "C_UnitAuras.GetPlayerAuraBySpellID", "C_UnitAuras.GetAuraDataByIndex",
        "C_UnitAuras.GetBuffDataByIndex", "UnitBuff", "C_Spell", "C_Spell.GetSpellName",
        "C_Spell.GetSpellInfo", "GetSpellInfo", "UnitIsDeadOrGhost", "C_Timer", "C_Timer.NewTimer", "C_Timer.After",
        "PlaySoundFile", "PlaySound", "SOUNDKIT", "InCombatLockdown", "BackdropTemplateMixin",
        "Settings", "Settings.RegisterCanvasLayoutCategory", "InterfaceOptions_AddCategory",
        "CooldownViewerSettings", "C_CooldownViewer",
    }
    local out = {}
    for _, p in ipairs(list) do out[#out + 1] = { p, has(p) } end
    return out
end
