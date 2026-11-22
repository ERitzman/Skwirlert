# Skwirlert — Developer Guide

This guide explains how Skwirlert is built, so you can maintain it or reuse its patterns in your own addon. It assumes you know basic Lua but are new to WoW addons. Every `.lua` file also starts with a plain-English header, and every function has a comment explaining what it does.

Version 0.5.10 · WoW Forever 1.60.1 (Interface 16001) · no libraries, no dependencies.

---

## 1. Ten-minute tour

| File | Lines | Role | Read it for… |
|---|---|---|---|
| `Skwirlert.toc` | — | Tells WoW what to load, and in what order; `IconTexture` sets the AddOns-list icon | TOC format |
| `Media/SkwirlertIcon.tga` | — | Addon icon, 128×128 32-bit TGA. Textures must be power-of-two sizes; paths are written without the extension | Using images in an addon |
| `Core.lua` | ~650 | Namespace, saved data, profiles, error capture, event dispatcher | The skeleton any addon needs |
| `Compat.lua` | ~340 | Safe wrappers for buff/spell/unit APIs ("secret values") | Writing code that survives combat restrictions |
| `Sounds.lua` | ~210 | Plays sounds, falls back, reads sound settings | `PlaySoundFile` / `PlaySound` |
| `Announce.lua` | ~175 | Optional Say / Party / Raid messages | `SendChatMessage` rules |
| `Popup.lua` | ~145 | The movable yellow alert box | A simple, draggable frame |
| `Engine.lua` | ~450 | Cast detection, buff checks, warning/expiry timers | Event-driven timing without OnUpdate |
| `Config.lua` | ~880 | Settings window (Reminders + Profiles tabs) | Building a UI without libraries |
| `BuffPicker.lua` | ~205 | "Add from my buffs" list | Reading the player's buffs into a UI |
| `Share.lua` | ~315 | Export/import share codes | Safe data serialization |
| `Diagnostics.lua` | ~220 | Diagnostics mode and copyable bug report | Making bugs easy to report |
| `Commands.lua` | ~250 | `/skwirlert` and its sub-commands | Slash commands |

**Load order matters.** Each file can use anything defined by the files above it in the TOC. Functions defined later are only called at run time, after everything has loaded.

---

## 2. WoW concepts used (glossary)

* **TOC file:** `##` lines are metadata (`Interface`, `SavedVariables`…), `#` lines are comments, and every other line is a file to load.
* **Namespace (`local ADDON, ns = ...`):** WoW passes every file the addon's folder name and one private table shared by all its files. Skwirlert puts its modules on it: `ns.Engine`, `ns.Sounds`, `ns.Profiles`… Only one global is created: `Skwirlert` (for debugging).
* **SavedVariables:** `## SavedVariables: SkwirlertDB` makes WoW save the global table `SkwirlertDB` on logout/reload and load it before `ADDON_LOADED`. Anything not in it is lost on reload.
* **Events:** WoW calls a frame's `OnEvent` script. Events used here:
  * `PLAYER_LOGIN`: start-up; the character's name and server are known.
  * `PLAYER_ENTERING_WORLD`, `PLAYER_REGEN_ENABLED` (combat ended): re-check buffs.
  * `UNIT_SPELLCAST_SENT` / `UNIT_SPELLCAST_SUCCEEDED`: a cast started / landed.
  * `UNIT_AURA`: buffs changed on a unit.
  * `PLAYER_LOGOUT`: last chance to write saved data.
* **Frames and templates:** `CreateFrame(type, globalName, parent, template)`. Templates used: `BackdropTemplate`, `UIPanelButtonTemplate`, `InputBoxTemplate`, `UICheckButtonTemplate`, `UIPanelCloseButton`, `UIPanelScrollFrameTemplate`.
* **Anchors:** `frame:SetPoint("TOPLEFT", x, y)` positions relative to the parent. Negative y goes down.
* **C_Timer:** `C_Timer.After(sec, fn)` runs once; `C_Timer.NewTimer(sec, fn)` returns a handle you can `:Cancel()`. Skwirlert never uses `OnUpdate` (which runs every frame).
* **GetTime():** seconds since the computer started, as a float. Buff `expirationTime` uses the same clock.
* **Secret values:** in modern clients, some API results in combat are opaque "secrets". You may pass them to some UI functions, but comparing, doing math, concatenating or indexing them raises an error. Check with `issecretvalue(v)` first; in Skwirlert, use `ns.Compat.IsSecret/Num/Str/Bool`.
* **Hardware events:** some actions (like `/say` from an addon outside instances) are only allowed during a click or key press, not from timers or events.
* **Escape codes:** `|cffRRGGBB` starts a colour and `|r` ends it. Never put a raw `|` into chat text or imported names.

---

## 3. What happens at run time

### Start-up
1. WoW loads the files in TOC order. Each module creates its table on `ns` and calls `ns.RegisterInit(fn)` for set-up that needs saved data.
2. `PLAYER_LOGIN` (in `Core.lua`):
   1. `initDB()` reads the character's name, server and GUID, upgrades old saved data, and binds the character to its profile (`ns.db`, `ns.char`).
   2. Every registered init function runs, in TOC order. For example, Engine subscribes to cast/buff events and restores running timers; Config builds the popup and registers the options entry.
3. `PLAYER_ENTERING_WORLD` → after 2 s, `Engine:VerifyAll()` picks up buffs you already have.

### A buff on you (e.g. Arcane Intellect)
```
UNIT_SPELLCAST_SENT ─► onSent: remember target by castGUID
UNIT_SPELLCAST_SUCCEEDED ─► onSucceeded
    ├─ matchReminders (spell ID, learned ID, or name)
    ├─ Engine:Start(r, now + duration, "predicted")   ← yellow check
    │      └─ schedule(): warnTimer at expires - warn, expireTimer at expires
    └─ Announce.Applied (if enabled)
UNIT_AURA ─► queueVerify (batched 0.15 s) ─► one buff snapshot ─► VerifySelf
    └─ ApplyAura: real expirationTime replaces the estimate ← green check
warnTimer ─► FireWarn: popup + warning sound + chat (skipped when warn = 0)
expireTimer ─► FireExpire: last re-check, then ONE expiration alert
```
A buff someone else casts on you skips the cast steps: the `UNIT_AURA` check starts a verified cycle directly.

### "Cycles" (why alerts never repeat)
Each start creates a new cycle number. Timers capture the number they were created for and do nothing if it's no longer current. `warned` / `expired` flags make each cycle alert once. Recasting cancels the old timers *and* bumps the cycle, so a stale callback is harmless even if cancelling somehow failed.

### Honest wording
* **"has expired"** when the expiry time was read from the buff.
* **"has likely expired (est.)"** when it was only estimated.
* **"has ended"** only if the buff was seen in this cycle and is then confirmed gone early.

Absence is only trusted out of combat, or when `C_Secrets.ShouldSpellAuraBeSecret` says the buff isn't hidden.

---

## 4. Data model

See the header of `Core.lua` for the full layout. In short:

```
SkwirlertDB
├─ profiles["Default"]              always exists, starts empty
├─ profiles["Skwirlaflicn (US-PvE)"]
│    ├─ reminders = { {id, name, kind, spellIDs, names, duration, warn, ...}, ... }
│    └─ nextId, enabled, channel, popup = {duration, locked, point, x, y}
├─ profileKeys[<GUID>] = "Skwirlaflicn (US-PvE)"   which profile each character uses
├─ chars[<GUID>] = { name, active = {running timers} }
├─ errors = { last 25 captured errors }
└─ diagnostics = true/false
```

* **`dbVersion` + upgrade code:** `upgradeRoot` and `migrateLegacyKey` turn older layouts (0.1–0.4 flat, 0.5.0 name-keyed) into the current one. Always bump the version and migrate; never delete a player's data.
* **Normalisation:** `ns.NormalizeReminder` fills defaults and clamps every field. It runs on load, on add and on import, so the rest of the code can trust the data.

---

## 5. Patterns worth copying

1. **One event frame + subscriber lists** (`ns.On`, `ns.OnUnit` in Core). Any file can listen to any event, and each handler is isolated.
2. **Catch every error with context** (`ns.XCall`, `ns.Safe`, `ns.After`, `ns.NewTimer`, `ns.SafeFrameFactory`).
   * `xpcall` with a handler that captures the stack.
   * Errors are deduplicated, stored in saved variables, shown once in chat, and passed to `geterrorhandler()` so BugSack still sees them.
   * `SafeFrameFactory` replaces `CreateFrame` at the top of the UI files: every `SetScript` handler is wrapped automatically, with no try/catch boilerplate.
3. **Guard secret values at the boundary** (`Compat.lua`). Convert to plain values once, at the edge; the rest of the code never sees a secret.
4. **Timers instead of OnUpdate**, plus cycle numbers for staleness.
5. **Batch noisy events** (`queueVerify`). `UNIT_AURA` can fire many times per second; schedule one check shortly after instead of reacting to each.
6. **Snapshot once, match many** (`SnapshotPlayerBuffs`). Scan the 40 buff slots once per update, not once per reminder.
7. **UI helpers + one widgets table + Refresh()** (`Config.lua`). Data → widgets in `Refresh`; widgets → data in callbacks; a `refreshing` flag prevents feedback loops. Live updates redraw only the list, never text boxes the user may be typing in.
8. **Two-click confirmation** (`armed()` in Config) for anything destructive.
9. **Data-only import** (`Share.lua`): never `loadstring` user text; whitelist fields, clamp values, strip `|`, limit size and depth, add a checksum.
10. **Build UI lazily.** The settings window, report window and buff picker are only created when first opened.
11. **Diagnostics a player can hand you** (`Diagnostics.lua`): an opt-in activity log plus a one-click, copyable report.

---

## 6. How to…

**Add a sound:** convert it to `.ogg` (44.1 kHz is fine), put it in `Sounds/`, add a line to `Sounds.files` in `Sounds.lua`, then **fully restart** WoW. `/reload` doesn't pick up new files.

**Add or replace an image:** use a 32-bit TGA (or BLP) with power-of-two sides (64, 128, 256…) in `Media/`. Refer to it without the extension, e.g. `texture:SetTexture("Interface\\AddOns\\Skwirlert\\Media\\SkwirlertIcon")`. Like sounds, new files need a full client restart.

**Add a slash command:** in `Commands.lua`, add `elseif cmd == "mycmd" then … end` inside `handleSlash`, and a line to `HELP`.

**Add a per-reminder setting** (example: `flash = true/false`):
1. Default and validate it in `ns.NormalizeReminder` (Core).
2. Use it where it matters (e.g. `Engine:FireWarn`).
3. Add a widget in `Config.lua`: create it in the Editor section, set it in `Config.Refresh`, and save it in its callback.
4. Add it to `exportReminder` and validate it in `importReminder` (Share), or it won't be shared.
5. Add tests (see below).

**React to a new event:** `ns.On("EVENT_NAME", function(event, ...) … end)` inside an `ns.RegisterInit` function. Check arguments with `ns.Compat` helpers if they could be secret.

**Change saved data layout:** bump `DB_VERSION` in Core, add a migration step in `upgradeRoot`, and add a test that loads the old layout.

---

## 7. Testing without the game

The separate test package (`Skwirlert-<version>-tests.zip`) contains:

* `luahost.c`: a ~20-line C program that runs Lua scripts using the system's Lua library (`gcc -o lua luahost.c /usr/lib/x86_64-linux-gnu/liblua5.4.so.0`). Any `lua` 5.1–5.4 interpreter also works.
* `mockwow.lua`: a fake WoW client with frames, events, timers (with a controllable clock), auras, sounds, chat, CVars, and **secret values that raise an error if misused**.
* `tests.lua`: about 290 checks covering every feature.

Run: `lua tests.lua /path/to/Skwirlert` → prints PASS/FAIL per check and a total.

Typical test shape:
```lua
local S = M.new(); S.load(nil)            -- fresh client + addon
S.addAura("player", 10157, 1800)          -- give the player a buff
S.fire("UNIT_AURA", "player")             -- fire an event
S.advance(1)                              -- move the clock 1 s (runs due timers)
ok(S.ns.Engine:State(id).source == "verified", "buff verified")
```

The mock proves the logic, not the real client. Anything visual, audible or timing-sensitive in combat still needs an in-game check (see `UNVERIFIED.md`).

---

## 8. Debugging in game

* `/console scriptErrors 1`: show Lua errors as popups.
* `/skwirlert report`: everything in one copyable box.
* `/skwirlert diag on`: record the activity log, reproduce the problem, then report.
* `/skwirlert debug`: also print each activity line in chat.
* `/skwirlert api`: which APIs this client has.
* `/skwirlert buffs` / `casts` / `aura <id>`: what the game is telling the addon right now.
* `/dump ns`-style inspection: `/dump Skwirlert.db` prints the current profile.
