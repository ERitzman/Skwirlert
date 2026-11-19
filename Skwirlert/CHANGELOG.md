# Skwirlert changelog

## 0.8.0-beta (beta — not stable until the owner approves)
* **Group Sync** (new Group tab): groupmates who run Skwirlert see each other's running timers through the hidden addon channel. Communication: Share and receive / Receive only / Off. Frequency: Low (15 s, default) / Normal (8 s) / High (4 s). Event-driven with merged updates, no polling or heartbeat; "Don't send during combat" (default on); boss-fight lockdown and server throttling handled with a retry. Incoming data is validated and size-limited. `/skwirlert group`.
* **Track on each group member**: per-reminder option for buffs you also cast on groupmates (e.g. Arcane Intellect). One timer per member who has *your* copy, from your cast or from reading their buffs. Merged alerts ("expires in 30s: Bob, Ann"), "has ended: Bob (died)", silent drop when another player's copy replaces yours or they leave, estimate kept when out of range, corrected by that player's Group Sync data when available. Off by default; a one-time tip suggests it.
* **Custom timers without spell IDs**: New opens a menu (Custom timer (no spell) / Buff on me / Buff I cast on others / From my recent casts). Spell ID labelled optional and filled in from a known spell name; "From my recent casts" adds a spell with its ID, target type and real duration; red note on buff reminders with nothing to match. "Manual / custom timer" renamed "Custom timer (no spell needed)".
* **Refresh noise fix**: Refresh only auto-adds buffs lasting at least 5m (setting "Refresh adds >=", `/skwirlert refresh min`); reminders you delete are not re-added (`/skwirlert refresh forget`). "Add from my buffs" can still add short buffs on purpose.
* Share codes carry the per-member flag and the Refresh minimum (older versions ignore both). Saved data from 0.7.0 is upgraded in place; nothing is reset.
* Source package: TOTEM_CHECK.md (in-game check for shaman testers ahead of 0.9.0 totem timers).

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
