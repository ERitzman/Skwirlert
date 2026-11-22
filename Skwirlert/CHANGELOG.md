# Skwirlert changelog

## 0.9.3-beta (beta — not stable until the owner approves)
* Settings window less crowded (owner feedback from an in-game screenshot): window 660 → 740 px wide; title, profile name and tabs no longer overlap; Name / Spell ID / Buff name boxes and the Type selector wider; hint text wider; "Track on each group member" back to its full label; bottom row re-spaced; the "Add from my buffs" / "My recent casts" panel wider.
* Info icons softer and smaller: 13 px (was 16), paler yellow, 55% opacity until hovered.
* No behaviour changes.

## 0.9.2-beta
* **"Loaded" line** at a real login (not /reload): version and how to open settings. Option on the Group tab (account-wide, default on).
* **Newer-version notice** (`Version.lua`): one hidden `1^V^<version>` message to the guild at login and whispered to online friends (and to a friend who comes online later, once per session, max 30); Group Sync hellos are checked too. A newer friend whispers back once (max once per 5 min per friend). A client with a newer version answers an older one once (random 2–8 s delay, skipped if someone answered first, max once per 5 min). One chat line per session. Option on the Group tab (default on); silent when Communication is Off. `/skwirlert version`. Guild messages never add guildmates to the Group tab. The newest version seen is saved (`SkwirlertDB.newestSeen`), so the notice then appears instantly at every login, on every character, until you update.

## 0.9.1-beta
* **Welcome window at login** (`Welcome.lua`): status line, Refresh my buffs / New timer / Open settings, and "Don't show this again" (per character, optionally "for all my characters"). Only at a real login (not /reload or zone changes); waits for combat to end. Bring it back with the new **Welcome** checkbox (Reminders tab, bottom row) or `/skwirlert welcome`. After an update, characters that hid it get one chat line instead. Built only when first shown.
* **First-load tutorial:** a character's very first time with Skwirlert (no reminders, tutorial not seen) opens the window as a five-page tutorial (Back / Next / Skip). Marked seen when finished, skipped or closed; never runs by itself again. Reopen: "Tutorial" button or `/skwirlert tutorial`. Characters that already have reminders get the normal welcome.
* **Info icons:** a small yellow "i" next to each main setting on all four tabs (29 in total); hover for a short explanation. New texture `Media/Info.tga` (32×32, own artwork). Settings row: "Refresh adds >=" is now "Refresh min"; "Alert on expiration" / "Track each group member" moved slightly so the icons fit.

## 0.9.0-beta
* **Aspect warning** (new Alerts tab, on by default): alert when a fight starts with Aspect of the Cheetah (you entering combat) or Aspect of the Pack on (you **or any group member** entering combat, via each member's combat flag). Non-hunters are warned when a hunter's Pack is on them. Hunters can also post one line to the group ("Tell the group", off by default). One alert per fight; uses the aspect state read before combat because buff data may be hidden at the pull. No extra buff scan.
* **After-combat group check** (on by default): a few seconds after combat, check the group for Curse / Disease (Poison / Magic optional) and anyone dead; one popup and one Group (auto) message by name, with "Can help" from players' own spellbooks (yours + Group Sync). One Skwirlert per group posts (Group Sync claim), once a minute per person/problem, skips debuffs about to wear off, postponed by a new pull, silent while paused. `/skwirlert check [announce]`, `/skwirlert aspect`.
* Group Sync: two new message types, P (what I can fix) and K (what I just announced). 0.8.0 clients ignore them.
* Totem timers moved to the next release (waiting on the shaman testers' TOTEM_CHECK results).

## 0.8.0-beta
* **Group Sync** (new Group tab): groupmates who run Skwirlert see each other's running timers through the hidden addon channel. Communication: Share and receive / Receive only / Off. Frequency: Low (15 s, default) / Normal (8 s) / High (4 s). Event-driven with merged updates, no polling or heartbeat; "Don't send during combat" (default on); boss-fight lockdown and server throttling handled with a retry. Incoming data is validated and size-limited. `/skwirlert group`.
* **Track on each group member**: per-reminder option for buffs you also cast on groupmates (e.g. Arcane Intellect). One timer per member who has *your* copy, from your cast or from reading their buffs. Merged alerts ("expires in 30s: Bob, Ann"), "has ended: Bob (died)", silent drop when another player's copy replaces yours or they leave, estimate kept when out of range, corrected by that player's Group Sync data when available. Off by default; a one-time tip suggests it.
* **Custom timers without spell IDs**: New opens a menu (Custom timer (no spell) / Buff on me / Buff I cast on others / From my recent casts). Spell ID labelled optional and filled in from a known spell name; "From my recent casts" adds a spell with its ID, target type and real duration; red note on buff reminders with nothing to match. "Manual / custom timer" renamed "Custom timer (no spell needed)".
* **Refresh noise fix**: Refresh only auto-adds buffs lasting at least 5m (setting "Refresh adds >=", `/skwirlert refresh min`); reminders you delete are not re-added (`/skwirlert refresh forget`). "Add from my buffs" can still add short buffs on purpose.
* Share codes carry the per-member flag and the Refresh minimum (older versions ignore both). Saved data from 0.7.0 is upgraded in place; nothing is reset.
* Source package: TOTEM_CHECK.md (in-game check for shaman testers ahead of totem timers).

## 0.7.0-beta
* **Minimap button** with the squirrel icon: left-click opens settings, Shift+left-click refreshes current buffs, right-click pauses monitoring, drag to move. Position and visibility are saved per profile. `/skwirlert minimap show | hide | reset`.
* **Refresh and Monitor** (`/skwirlert refresh`): adds every timed buff on you now, including buffs cast by others, without duplicates. It updates running timers from real buff times, keeps existing reminders' settings, respects the 100-reminder limit, skips hidden or permanent buffs, and opens settings.
* **Pause Monitoring** (`/skwirlert pause`, `pause 30`, `pause group`, `resume`): timed pause (default 30 min; 5/15/30/60 or any minutes) or pause while grouped. Silences popups, sounds and automatic chat. Timers keep running and missed alerts are never replayed. Resumes automatically, and survives `/reload`.
* README: macros section; MIT licence for Skwirlert's code; sound credits updated (owner-approved).

## 0.6.0-beta.1
* Durations shown and typed as `30s`, `10m`, `30m30s`, `1h`. Stored in seconds; timers and saved data unchanged.
* Player ZIP built from an allow-list (no developer files); CREDITS.md; `.pkgmeta`.

## 0.5.x
* 0.5.0: profiles (per character, Default, use/copy/rename/delete/reset), share codes, no hardcoded buffs, 100 reminders per profile, error capture and bug reports.
* 0.5.1: short profile names ("Name (US-PvE)"), character IDs, rename.
* 0.5.2: code documentation. 0.5.3–0.5.10: addon icon.

## 0.4.0 and earlier
* 0.4.0: "Add from my buffs", list checkboxes and status icons.
* 0.3.x: custom reminders, warning time 0–60 s.
* 0.2.0: chat announcements.
* 0.1.0: first build.
