# Skwirlert 0.5.10 — API compatibility report

Target: WoW Forever 1.60.1, Interface 16001.
Status key: **Doc** = documented for the modern/secret-values client (warcraft.wiki.gg); **Mock** = exercised only in the offline mock test suite; **Untested** = not yet run in the Forever client. Every entry below is currently **Untested in Forever**.

Run `/skwirlert api` in game to see which of these exist on your client.

## Secret-value handling

| API | Use | Guard / fallback |
|---|---|---|
| `issecretvalue(v)` | Every value from a guarded API goes through `Compat.IsSecret` before any compare, math, concatenation or table-key use | If missing (older client), nothing is treated as secret. If calling it errors, the value is treated as secret. |
| `C_Secrets.ShouldSpellAuraBeSecret(id)` | In combat, decides whether "aura not found" can be trusted | If missing → absence in combat is never trusted |
| `InCombatLockdown`, `UnitAffectingCombat` | Combat state | Results are checked for secrecy |

Rules followed: no arithmetic or comparison on possibly secret values; a secret aura record counts as "present, timing unknown"; a secret target name gives the recipient "unknown target"; a secret spell ID on a cast is ignored, with a debug note. Secret values are never displayed (the client can show them, but we skip that for simplicity).

## Confirmed in game (Forever, Interface 16001, /skwirlert api on 2026-11-17)

Present: issecretvalue, canaccessvalue, C_Secrets(.ShouldSpellAuraBeSecret), C_UnitAuras (GetPlayerAuraBySpellID, GetAuraDataByIndex, GetBuffDataByIndex), C_Spell (GetSpellName, GetSpellInfo), GetSpellInfo, C_Timer (NewTimer, After), PlaySoundFile, PlaySound, SOUNDKIT, InCombatLockdown, BackdropTemplateMixin, Settings.RegisterCanvasLayoutCategory, CooldownViewerSettings, C_CooldownViewer.
Absent: UnitBuff (legacy fallback; not needed), InterfaceOptions_AddCategory (not used).

## Cast detection

| API / event | Use | Notes |
|---|---|---|
| `UNIT_SPELLCAST_SENT` (unit, target, castGUID, spellID) | Records the cast's target name, keyed by castGUID | Target may be nil (self/no-target) or secret |
| `UNIT_SPELLCAST_SUCCEEDED` (unit, castGUID, spellID) | Starts/resets timers | Registered with `RegisterUnitEvent(…, "player")`, or `RegisterEvent` as a fallback |
| `C_Spell.GetSpellName` → `C_Spell.GetSpellInfo` → `GetSpellInfo` | Name matching and ID learning | First one available is used |
| Combat log (`COMBAT_LOG_EVENT_UNFILTERED`) | **Not used** | Unavailable to addons on secret-values clients |

## Aura reading

| API | Use | Fallback |
|---|---|---|
| `C_UnitAuras.GetPlayerAuraBySpellID(id)` | Fast lookup of the player's own buffs by known/learned IDs | Index scan below |
| `C_UnitAuras.GetAuraDataByIndex(unit, i, "HELPFUL")` | Player name match; group member (Soulstone) scan | `C_UnitAuras.GetBuffDataByIndex`, then legacy `UnitBuff` |
| AuraData fields `spellId`, `name`, `expirationTime`, `duration` | Expiration and duration | Each field is checked for secrecy on its own; `expirationTime` 0 = permanent, ignored |
| `UNIT_AURA` | Triggers re-verification, at most one check per unit every 0.15 s | `PLAYER_REGEN_ENABLED` and `PLAYER_ENTERING_WORLD` trigger a full re-check |
| `UnitName`, `UnitExists`, `UnitIsVisible`, `IsInRaid` | Find the Soulstone recipient's unit token; trust "absent" only if the unit is visible | Results are checked for secrecy |
| Cooldown Manager frames | **Not used** in 0.1.0 | BuffReminder reads these in combat. This could be added later if testing shows combat prediction isn't good enough. |

## Buff picker (0.4.0)

Uses the same `C_UnitAuras.GetAuraDataByIndex(player, i, "HELPFUL")` scan, plus the AuraData `icon` field (number or string; checked for secrecy). Permanent auras (duration 0) are listed but can't be added. Unreadable (secret) records are skipped, and the picker says data is hidden.

## Timers, sound and UI

| API | Use | Notes |
|---|---|---|
| `C_Timer.NewTimer`, `C_Timer.After`, `timer:Cancel()` | All scheduling; no OnUpdate | |
| `GetTime()` | Clock for expirations; saved across `/reload` to restore running timers | Restored values are checked for sanity (must be in the future and within 24 h) |
| `PlaySoundFile(path, "Master")` | Custom sounds. Returns `willPlay`, `soundHandle` | Doc: `.ogg` and `.mp3` accepted, WAV not documented. A nil `willPlay` means rejected or channel muted |
| `PlaySound(SOUNDKIT.RAID_WARNING / READY_CHECK, channel)` | Built-in choices + fallback | Numeric IDs 8959/8960 are used if `SOUNDKIT` is missing |
| `CreateFrame` with `BackdropTemplate` | Popup, settings window, slider | Falls back to no template if `BackdropTemplateMixin` is missing |
| Templates `UIPanelButtonTemplate`, `InputBoxTemplate`, `UICheckButtonTemplate`, `UIPanelCloseButton` | Settings window | No `UIDropDownMenu` (avoids deprecated menu APIs) |
| `Settings.RegisterCanvasLayoutCategory` / `RegisterAddOnCategory` | Optional entry in the AddOns options list | Wrapped in pcall; skipped if missing |
| `UISpecialFrames` | Escape closes settings | |
| `SavedVariables: SkwirlertDB` | Config, learned IDs/durations, popup position, active timers | |

## Chat announcements (0.2.0)

| API | Use | Guard / fallback |
|---|---|---|
| `C_ChatInfo.SendChatMessage(msg, chatType)` | Sends announcements | Falls back to global `SendChatMessage`. Wrapped in pcall; failures are logged and shown in chat |
| `C_ChatInfo.InChatMessagingLockdown()` | If it exists and returns true, the send is skipped and logged | Not confirmed to exist on Forever; ignored if missing |
| `IsInGroup`, `IsInRaid`, `LE_PARTY_CATEGORY_HOME/INSTANCE` | Choose PARTY / RAID / INSTANCE_CHAT | Results are checked for secrecy; skipped if not in a group |
| `IsInInstance` | Say is used automatically only inside instances (outside, SAY needs a hardware event) | Button presses (Test chat) send SAY anywhere |

Message text is plain: `|` characters are replaced, and only plain names (never secret values) are included.

## Profiles, sharing and diagnostics (0.5.0)

| API | Use | Notes |
|---|---|---|
| `UnitGUID("player")` | Character identity (unique even with Forever's two-name system) | Checked for secrecy; falls back to "Name - Realm" if unavailable |
| `UnitName("player")`, `GetRealmName()` | Display name "Name (US-PvE)"; Forever returns e.g. "CAMWOW US2 Realm 1 PvE" (confirmed in game) | Initialisation at `PLAYER_LOGIN` |
| `xpcall` + `debugstack` (fallback `debug.traceback`) | Error capture with stack traces | Wraps every event handler, timer callback, UI script handler and slash command |
| `geterrorhandler()` | Each unique error is passed on once, so the Lua error popup or BugSack shows it | pcall-protected |
| `C_CVar.GetCVar` (fallback `GetCVar`) | `/skwirlert soundcheck` and the bug report read sound settings | Read-only; Skwirlert never sets CVars |
| `UIPanelScrollFrameTemplate` + multi-line `EditBox` | Bug report window | Falls back to a plain box if the template is missing |
| `EditBox:SetMaxLetters(0)`, `HighlightText` | Share code box | Long codes are not yet tested in game |
| `wipe`, `date`, `GetLocale` | Diagnostics helpers | |
| TOC `## IconTexture` | AddOns-list icon (0.5.3) | Supported in modern clients; not yet confirmed on Forever |
| `Texture:SetTexture(path)` with a 128×128 TGA | Icon in the settings window and options panel | |

Share codes use Skwirlert's own data-only format (no libraries): serialised data, base64, and a 6-hex checksum. Import never calls `loadstring` or runs any code.


## Spell data

Nothing is hardcoded since 0.5.0. Spell IDs and durations come from the buffs themselves (Add from my buffs), from `/skwirlert buffs` / `/skwirlert casts`, or from spell names.
