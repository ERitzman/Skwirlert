# Skwirlert 0.5.10 — what's verified and what isn't

The automated tests (295/295 passing) run against a mock of the WoW API. They check the logic, not the real client.

## Confirmed in WoW Forever (owner, 0.3.1–0.4.0, 2026-11-17)

* Loads at Interface 16001; the settings window renders correctly.
* Demon Armor is detected automatically on cast and verified from the buff ("aura reported 1800s").
* Arcane Intellect: the warning fired once at 30 s and the expiration alert fired once. Forever's duration is 3600 s, learned from the buff.
* All six sounds are audible (Master channel).
* `/skwirlert api`: every API Skwirlert relies on is present.
* 0.4.0: **Add from my buffs** lists buffs with icons, IDs and durations. Buffs cast by others (Power Word: Fortitude, Mark of the Wild, Unending Breath) are added and verified (green check). The list checkboxes and icons render.

## Confirmed in WoW Forever (owner, 0.5.0, 2026-11-17)

* 0.5.0 loads; the upgrade moved the 8 reminders into this character's profile; the Profiles tab lists Default and the character profile; Export produces a code; the Default tooltip works.
* `GetRealmName()` returns "CAMWOW US2 Realm 1 PvE" on Forever (the US PvE ruleset server).

## Confirmed in WoW Forever (owner, 0.5.1, 2026-11-17)

* The profile shows as "Skwirlaflicn (US-PvE)", with the full server name "CAMWOW US2 Realm 1 PvE" beside it; the existing profile was renamed automatically with all 8 reminders.
* The header, profile list and "Selected:" layout fixes; the Rename and Create buttons display.
* List hover tooltips and checkboxes (Power Word: Fortitude shown unchecked = monitoring off).

## 0.5.10

Icon artwork only: the owner chose a public-domain (CC0) squirrel silhouette from FreeSVG / publicdomainvectors.org; the circle was removed, the squirrel flipped to face right, and recoloured to yellow on black inside the owner's box. No code changes apart from the version number.

## 0.5.9

Icon artwork only (owner feedback): round head with a short muzzle, front paws stretched further out, a softer rounded tail. No code changes apart from the version number.

## 0.5.8

Icon artwork only (owner direction): an original crouching squirrel with outstretched front paws and a tall flared tail. No code changes apart from the version number.

## 0.5.7

Icon artwork only (owner feedback: less fat, more side-on, better contours). No code changes apart from the version number.

## 0.5.6

New icon artwork only (owner direction): an original right-facing sitting squirrel in classic silhouette style, in the owner's colours and box. No code changes apart from the version number.

## 0.5.5

Icon artwork only (owner feedback on 0.5.4): the tail is one continuous curve from plume to base, and the front paw is clearly raised. No code changes apart from the version number.

## 0.5.4

Icon artwork only: a more realistic squirrel body (owner request). No code changes apart from the version number.

## New in 0.5.3, needs an in-game check

* The icon shows in the AddOns list (character select → AddOns, and in game) via `## IconTexture`; this TOC field is supported by modern clients but not yet confirmed on Forever.
* The icon shows in the settings window title (left of "Skwirlert") and on Options → AddOns → Skwirlert.
* Needs a full client restart after installing (new image file).

## 0.5.2

Documentation only: file headers, function comments, TOC comments and DEVELOPER_GUIDE.md. The code is identical to 0.5.1 apart from the version number (checked by comparing all non-comment lines).

## New in 0.5.1, needs an in-game check

* The profile is shown as "Skwirlaflicn (US-PvE)", and the existing profile was renamed automatically with all 8 reminders.
* The header no longer runs into the tab buttons; "(in use)" stays on one line; "Selected:" stays inside the window.
* **Rename** on the Profiles tab.
* `UnitGUID("player")` is readable at login (if not, Skwirlert falls back to name-based tracking; the bug report shows which).

## New in 0.5.0, needs an in-game check

1. **Upgrade:** the first character logged in gets the old reminders in a profile named after it, with a chat message saying so.
2. **A second character** starts with an empty list; the Profiles tab shows both profiles plus Default.
3. **Use / Copy / Delete / Reset / New** on the Profiles tab, and the profile name in the header.
4. **Share:** Export puts a code in the box, highlighted. Ctrl+C copies all of it (check that a long code isn't cut off). Import on another character or account creates a new profile with the same reminders.
5. **Errors:** if one ever happens, you get a chat line plus the normal Lua error popup (or BugSack), and **Bug report** shows it with a stack trace. Check that the report box scrolls and that Ctrl+A, Ctrl+C copies everything.
6. **Diagnostics mode** checkbox; `/skwirlert soundcheck` shows your sound settings.
7. With many reminders (e.g. 30+), the list scrolls and there's no noticeable slowdown in combat.

## Still open from earlier builds

* **Combat:** when a buff is recast mid-fight, does the icon go yellow (estimated) or stay green?
* **Soulstone** on a party member: the recipient's name shows, and the timer verifies against their buff.
* **Chat announcements** in a group (Party/Raid); Say is skipped outdoors without an error.
* **Saving:** settings and the popup position survive `/reload` and a full restart.

## Known limitations

* No Cooldown Manager fallback for exact in-combat times (the API is present; it can be added if combat estimates prove too rough).
* Name matching uses the client's language.
* Share codes for very large profiles may be long. Paste them through Discord or email, not in-game chat.
* Lua 5.1 compatibility was checked by review and a syntax scan; the tests run on Lua 5.4.

## Branching

0.5.10 is a test build. 0.3.0, 0.3.1, 0.4.0, 0.5.0–0.5.9 are kept unchanged as baselines.
