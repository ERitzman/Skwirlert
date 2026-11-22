-- =============================================================================
-- Skwirlert - Version.lua  (0.9.2: "loaded" line and "newer version" notice)
-- =============================================================================
-- WHAT THIS FILE DOES
--   1. LOADED LINE: one chat line at a real login (not /reload):
--      "Skwirlert v0.9.2-beta loaded - /skwirlert for settings ..."
--      Option: SkwirlertDB.loginMessage (default on).
--
--   2. UPDATE NOTICE: WoW addons cannot reach the internet, so - like other
--      addons do - Skwirlert compares versions with other players:
--      * At login it sends ONE hidden addon message to your guild: 1^V^<version>.
--        In a party/raid, Group Sync's hello already carries the version.
--      * If a guildmate or groupmate has a NEWER version, one of their clients
--        replies once (random 2-8 s delay; skipped if someone else replied
--        first; at most once per 5 minutes per client).
--      * You then see ONE chat line per session naming the newer version.
--      Option: SkwirlertDB.updateCheck (default on). Also silent when Group
--      Sync is set to "Off" (you opted out of addon communication).
--
--   * FRIENDS: the same message is whispered (hidden) to your online friends
--     at login, and to a friend when they come online later (once per friend
--     per session, at most 30 per session). A friend with a newer version
--     whispers back once (at most once per 5 minutes per friend). Friends
--     without Skwirlert never see anything.
--   * REMEMBERED: the newest version seen is saved (SkwirlertDB.newestSeen),
--     so from then on the notice appears INSTANTLY at every login, on every
--     character, even solo - until you install that version (then it clears).
--
--   Nothing here runs on a timer or polls: one message at login, replies only
--   when an older version is heard.
-- =============================================================================

local _, ns = ...
local C = ns.Compat
local V = {}
ns.Version = V

local REPLY_GAP = 300      -- seconds between our replies to older clients
local lastReply = -1e9
local replyTimer
local notified = false     -- one notice per session
V.newest = nil             -- newest version heard this session (if newer than ours)

local function now() return GetTime() end

-- "0.9.2-beta" -> { 0, 9, 2 }, stage, stageNumber. A release (no suffix) is
-- newer than any beta of the same numbers; "beta.2" is newer than "beta.1".
function V.Parse(s)
    if type(s) ~= "string" then return nil end
    local nums, rest = s:match("^v?(%d+[%.%d]*)(.*)$")
    if not nums then return nil end
    local parts = {}
    for n in nums:gmatch("%d+") do parts[#parts + 1] = tonumber(n) end
    local stage, stageNum = rest:match("^%-(%a+)%.?(%d*)")
    return parts, stage and stage:lower() or nil, tonumber(stageNum) or 0
end

-- -1 if a < b, 0 if equal, 1 if a > b; nil if either can't be read.
function V.Compare(a, b)
    local pa, sa, na = V.Parse(a)
    local pb, sb, nb = V.Parse(b)
    if not (pa and pb) then return nil end
    for i = 1, math.max(#pa, #pb) do
        local x, y = pa[i] or 0, pb[i] or 0
        if x ~= y then return x < y and -1 or 1 end
    end
    if sa == sb then
        if na == nb then return 0 end
        return na < nb and -1 or 1
    end
    if not sa then return 1 end          -- release beats a pre-release
    if not sb then return -1 end
    local rank = { alpha = 1, beta = 2, rc = 3 }
    local ra, rb = rank[sa] or 0, rank[sb] or 0
    if ra == rb then return sa < sb and -1 or 1 end
    return ra < rb and -1 or 1
end

local function enabled()
    if not (ns.sv and ns.sv.updateCheck ~= false) then return false end
    local s = ns.Sync and ns.Sync.Settings()
    return not (s and s.mode == "off")
end
V.Enabled = enabled

local function inGuild() return _G.IsInGuild and C.Bool(IsInGuild()) or false end

local MAX_FRIEND_SENDS = 30
local friendSent, friendSends = {}, 0     -- [name] = true this session
local loginRoundDone = false
local lastWhisperReply = {}               -- [name] = time

local function send(channel, target)
    local CI = _G.C_ChatInfo
    if not (CI and CI.SendAddonMessage) then return false end
    if CI.InChatMessagingLockdown then
        local ok, locked = pcall(CI.InChatMessagingLockdown)
        if ok and C.Bool(locked) then return false end
    end
    local ok, res = pcall(CI.SendAddonMessage, ns.Sync.PREFIX, ns.Sync.PROTOCOL .. "^V^" .. ns.version:gsub("[^%w%.%-]", ""), channel, target)
    return ok and res ~= false and (type(res) ~= "number" or res == 0)
end

-- Online friends' names (character friends list), at most 50.
function V.OnlineFriends()
    local out = {}
    local FL = _G.C_FriendList
    local okN, n = pcall(function() return (FL and FL.GetNumFriends and FL.GetNumFriends()) or (_G.GetNumFriends and GetNumFriends()) or 0 end)
    n = okN and C.Num(n) or 0
    for i = 1, math.min(n, 50) do
        local name, online
        if FL and FL.GetFriendInfoByIndex then
            local ok, info = pcall(FL.GetFriendInfoByIndex, i)
            if ok and type(info) == "table" and not C.IsSecret(info) then name, online = C.Str(info.name), C.Bool(info.connected) end
        elseif _G.GetFriendInfo then
            local ok, nm, _, _, _, conn = pcall(GetFriendInfo, i)
            if ok then name, online = C.Str(nm), C.Bool(conn) end
        end
        if name and online then out[#out + 1] = name end
    end
    return out
end

-- Whisper our version to online friends we haven't told this session.
local function tellFriends()
    if not enabled() then return end
    for _, name in ipairs(V.OnlineFriends()) do
        local key = name:lower()
        if not friendSent[key] and friendSends < MAX_FRIEND_SENDS then
            friendSent[key] = true
            friendSends = friendSends + 1
            send("WHISPER", name)
        end
    end
end
V.TellFriends = tellFriends

-- Tell the player once per session.
local function notify(newer)
    if notified then return end
    notified = true
    ns.Print(string.format("|cff40ff40A newer Skwirlert is available: %s|r (you have %s). Get it from wherever you downloaded Skwirlert.", newer, ns.version))
    ns.Log("newer version seen", newer)
end

-- Someone's version arrived (guild "V" message, or a Group Sync hello).
-- channel = "GUILD", "PARTY", "RAID", "INSTANCE_CHAT".
function V.OnVersion(sender, version, channel)
    if not enabled() then return end
    version = C.Str(version)
    -- Reject (don't trim) anything that isn't a plain short version string.
    if not version or #version > 20 or not version:find("^[%w%.%-]+$") then return end
    local cmp = V.Compare(version, ns.version)
    if cmp == nil then return end
    if cmp > 0 then
        if not V.newest or V.Compare(version, V.newest) > 0 then V.newest = version end
        if ns.sv and (not ns.sv.newestSeen or (V.Compare(version, ns.sv.newestSeen) or 0) > 0) then
            ns.sv.newestSeen = version      -- remembered for instant notices at later logins
        end
        notify(version)
        if replyTimer then replyTimer:Cancel(); replyTimer = nil end   -- someone newer already answered
    elseif cmp < 0 and channel == "WHISPER" then
        -- An older friend whispered us: answer them directly, at most once per 5 minutes each.
        local key = tostring(sender):lower()
        if now() - (lastWhisperReply[key] or -1e9) < REPLY_GAP then return end
        lastWhisperReply[key] = now()
        ns.After("Version", 1 + math.random() * 2, function() send("WHISPER", sender) end)
    elseif cmp < 0 and channel == "GUILD" then
        -- They're older: one of us answers (spread out so the guild doesn't all reply).
        if replyTimer or now() - lastReply < REPLY_GAP then return end
        replyTimer = ns.NewTimer("Version", 2 + math.random() * 6, function()
            replyTimer = nil
            lastReply = now()
            send("GUILD")
        end)
    elseif cmp == 0 and channel == "GUILD" and replyTimer then
        -- An equal-version client answered first: the older player has been told.
        replyTimer:Cancel(); replyTimer = nil
    end
end

-- Real login: the loaded line, then (a little later) our version to the guild.
function V.OnLogin()
    if ns.sv and ns.sv.loginMessage ~= false then
        ns.Print(string.format("v%s loaded - |cffffd100/skwirlert|r for settings (minimap button: right-click to pause).", ns.version))
    end
    -- A newer version seen in an earlier session: tell the player right away.
    local seen = ns.sv and ns.sv.newestSeen
    if type(seen) == "string" then
        local cmp = V.Compare(seen, ns.version)
        if cmp and cmp > 0 then
            V.newest = seen
            if enabled() then notify(seen) end
        else
            ns.sv.newestSeen = nil          -- you've updated: forget it
        end
    end
    ns.After("Version", 10, function()
        if enabled() and inGuild() then send("GUILD") end
        tellFriends()
        loginRoundDone = true
    end)
end

ns.RegisterInit(function()
    -- A friend came online: tell them too (once per session; batched).
    local queued = false
    ns.On("FRIENDLIST_UPDATE", function()
        if queued or not loginRoundDone then return end    -- only after the login round
        queued = true
        ns.After("Version", 5, function() queued = false; tellFriends() end)
    end)
    ns.On("PLAYER_ENTERING_WORLD", function(_, isInitialLogin, isReloadingUi)
        if C.Bool(isInitialLogin) and not C.Bool(isReloadingUi) then V.OnLogin() end
    end)
end)
