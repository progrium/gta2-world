# Script command reference: player (runtime)

- **System:** The runtime script commands that act specifically on the human player, as distinct from the generic per-ped commands `script-characters.md` already covers. Covers: granting score/money with or without the multiplier, reading and changing the score multiplier, reading and changing spare lives, setting, clearing, raising and capping the wanted level, locking the player's own controls, a global "did the last mission fail from death or arrest" query, and a gang-respect snapshot/restore pair that acts on the player across every gang at once.
- **Out of scope:** everything these commands merely read or move money into/out of — the scoring formulas themselves (`scoring.md`), the wanted-level tiers and police response (`wanted-level.md`), the death/arrest/respawn sequence (`power-ups-death-and-arrest.md`), gang respect arithmetic (`gangs-and-respect.md`), and the camera's own follow/zoom/shake behaviour (`camera.md`). This note is only each command's own parameters and immediate effect. Also out of scope, already covered by `script-characters.md`: the generic per-ped commands that happen to only make sense on the player in practice — current-weapon test, kill-frenzy weapon grant/clear, and the whole gang-respect read/change family — because their handlers take an arbitrary character and the "assumes it's the player" behaviour is their quirk, not this note's. The on-screen timer, counter and pager commands (declare a timer, add time to it, clear it, add an on-screen counter) are HUD/messages-family bookkeeping, not player state, and belong with the not-yet-written Messages/Counters notes instead.
- **Builds on:** `mission-scripts.md` (file format, thread/tick model, "looked up by command number" convention, the death/arrest mission-fail check in §3.3). Cross-referenced throughout: `scoring.md`, `wanted-level.md`, `power-ups-death-and-arrest.md`, `gangs-and-respect.md`, `camera.md`, `script-declarations.md` (police-level declaration), `script-characters.md` (current-weapon test, kill-frenzy weapon, respect family, the character-warp command's camera side effect).
- **Sources read:** the decompilation's per-tick script-command dispatch and every handler it routes to for adding score or cash, reading and changing the score multiplier, reading and changing lives, setting/clearing/raising the wanted level and the runtime form of the police-level cap, the two player-control-lock commands, the global death/arrest-on-last-mission flag and what sets and clears it, and the gang-respect save/restore pair; cross-checked against the handlers `script-characters.md`'s own pass already covered to avoid re-claiming them.
- **Date and author:** 2026-11-20, Claude (notes writer, reader side).

Tags: **[scr]** the compiled script file format, **[exe]** fixed in the executable, **[obs]** to confirm in play.

---

## 1. What the player sees

Nothing here is its own visible event; it's the machinery behind a mission handing the player a cash reward or a point bonus, nudging the score multiplier or a spare life up or down, slapping on (or clearing) a wanted level as a mission beat rather than a crime, briefly taking away the player's controls during a cutscene-like moment, and a couple of bookkeeping checks a mission uses to notice that its last attempt ended because the player died or got arrested.

## 2. Inputs: the runtime player commands [scr]

These commands run like any other script command (`mission-scripts.md` §3.2): one per tick, in thread order, as the thread's current command. The "looked up by command number" convention from `script-declarations.md` §2 still applies. Most of them name a character parameter the way the generic character commands do, but only act when the named character turns out to be the player; a few take no entity parameter at all because they always act on the local player (single-player's only player).

### 2.1 Score, cash and the multiplier

| Type | Parameters | Effect |
|---|---|---|
| 141 | character, a signed amount | Adds the amount to the player's money, multiplied by the player's current score multiplier (`scoring.md` §3.1's `money += points × multiplier`, here with a script-chosen "points" value instead of a kill or wreck). |
| 392 | character, a signed amount | Adds the amount to the player's money directly, with **no** multiplier applied — shares its handler with 141, which of the two types the command was written as decides whether the multiplier is used. |
| 342 | character, a counter | Same effect as 141 (added with the multiplier), but the amount comes from a counter variable's current value instead of being written into the command itself. |
| 194 | character, a target value | A condition: true if the player's money is greater than the target. |
| 195 | character, a counter | Writes the player's current money into the counter. |
| 196 | character, a target value | A condition: true if the player's score multiplier is greater than the target. |
| 197 | character, a counter | Writes the player's current score multiplier into the counter. |
| 282 | character, a signed amount | Changes the score multiplier by that amount, clamped to the multiplier's own 1–99 range (`power-ups-death-and-arrest.md` §5). |

**Quirk — only 197 skips the player check.** 141/392/342/194/195/196/282 all check that the named character actually is the player before touching anything, and simply do nothing otherwise. 197 (get multiplier) reads the player data straight through with no such check; reproduce it as a command that's only safe to use on the player's own character, the same assumption `script-characters.md` flags for its own player-only commands.

### 2.2 Lives

| Type | Parameters | Effect |
|---|---|---|
| 281 | character, a signed amount | Changes the player's spare-life count by that amount, clamped to 0–99 (`power-ups-death-and-arrest.md` §5's lives cap). Does nothing if the named character isn't the player. |
| 192 | character, a target value | A condition: true if the player's life count is greater than the target. Does nothing (reads as neither true nor false) if the named character isn't the player. |
| 193 | character, a counter | Writes the player's current life count into the counter. **Unlike 281/192, this doesn't check that the character is the player** — the same unguarded-read quirk as 2.1's multiplier-read command (193 and 197 share their handler). |

### 2.3 Wanted level

These act on whichever character is named, the same way `wanted-level.md`'s own "each ped has a wanted-points total" framing is written — in practice scripts only ever use them on the player, since that's the only ped whose wanted level drives anything.

| Type | Parameters | Effect |
|---|---|---|
| 163 | character | Clears the character's wanted level to zero outright, the same as the "cop bribe" power-up (`power-ups-death-and-arrest.md` §3.1). |
| 164 | character, a star count (0–6) | Sets the character's wanted level directly to the points total for that many stars (`wanted-level.md` §3.1's table), replacing whatever it was — can raise or lower it. An out-of-range star count is silently ignored. |
| 421 | character, a star count (0–6) | Shares its handler with 164, but only takes effect if the character isn't already at a higher star count: it can raise the level up to that many stars, the same way the "set to at least one star" rule works (`wanted-level.md` §3.1), but it never lowers a level that's already higher. An out-of-range star count is silently ignored. |
| 418 | a maximum wanted level | The runtime form of the level-start "cap the wanted level this level can reach" declaration (`script-declarations.md`'s police-level entry) — same parameter, same effect, same handler, just runnable on any line instead of only during the one-shot declaration pass. |

### 2.4 Locking the player's own controls

Both of these read a character parameter but never actually use it — whichever character the command names, it's always the local player's own input that's affected. They're meant for forcing the player to sit still (or stay out of vehicles) during a scripted beat.

| Type | Parameters | Effect |
|---|---|---|
| 400 | character (ignored), on/off | Enables or disables the player's ability to get into vehicles. |
| 407 | character (ignored), on/off | Enables or disables all of the player's controls outright. |

### 2.5 Death/arrest and respect snapshot

| Type | Parameters | Tests or effect |
|---|---|---|
| 443 | none | A condition: true once the mission-fail handling (`mission-scripts.md` §3.3) has flagged that the mission just ended because the player died or was arrested. This is a single global flag, not a per-character test — distinct from the per-character "is dead"/"is arrested" conditions in `script-characters.md` §2.4, which can be asked about any ped at any time. |
| 445 | none | Saves the local player's respect with every gang in the level into a small internal list, one slot per gang. |
| 446 | none | Restores the local player's respect with every gang from that same list, overwriting whatever it is now. |

The save/restore pair is unlike the per-character respect commands in `script-characters.md` §2.5 (which read or change one named character's respect with one named gang): it has no parameters at all, always acts on the single local player, and always covers every gang in one go — a snapshot-and-restore rather than a read-or-change.

## 3. Order of events

No ordering beyond the general thread rule (`mission-scripts.md` §3.2): each of these commands is an ordinary one-tick command, so a script that reads a value needs the command that set it on an earlier line (lower command number reached first).

The death/arrest flag (2.5, type 443) behaves differently from the rest: it's set once by the mission-fail handling and stays set until something clears it, rather than being recomputed fresh each time it's tested. One mission-launch path (a gang's phone-trigger mission template) clears it back to false whenever it starts a follow-up mission; whether every way of starting a mission does the same wasn't confirmed (see Open questions).

## 4. Numbers

This note introduces no fixed values of its own beyond what's already tabulated elsewhere: the wanted-level star thresholds are in `wanted-level.md` §3.1, and the lives/multiplier 0–99 clamp range is in `power-ups-death-and-arrest.md` §5.

## 5. Edge cases and quirks worth reproducing

- **Two "get" commands skip the player check their siblings have.** Reading the multiplier (197) or the life count (193) into a counter doesn't check that the named character is actually the player, unlike every other command in 2.1/2.2; reproduce them as only safe to use on the player's own character, the way scripts always use them (2.1, 2.2).
- **The two wanted-level "set" commands aren't interchangeable.** Type 164 always sets the level, up or down; type 421 only ever raises it, never lowers a level that's already higher (2.3).
- **The control-lock commands ignore which character they're given.** Both always act on the local player's own controls regardless of the character parameter in the command (2.4).
- **The money-adding commands and the mission-fail flag quietly do nothing if the condition isn't met** — a non-player character for 141/392/342, or no mission having yet failed from death/arrest for 443 — rather than erroring.

## 6. Open questions

- **No distinct player-camera script commands were found.** The only script-triggered camera effect traced anywhere is the side effect already documented on the character-warp command (`script-characters.md` §2.2, type 357): it resets the local player's follow-camera whenever it runs. If a dedicated camera-cut/follow/shake command exists under a type number this pass didn't recognise, it wasn't found.
- **No dedicated ammo-reading command was found**, only the current-weapon test already claimed by `script-characters.md` §2.3 (type 420). Whether ammo can be read by a script at all, by some other means, wasn't confirmed.
- **Whether the death/arrest flag (2.5, type 443) is cleared on every path that starts a new mission**, or only by the one gang phone-trigger template this pass traced it through — unconfirmed either way. **[obs]**
- **What story moment actually uses the respect snapshot/restore pair** (2.5, types 445/446) wasn't traced; a kill-frenzy or bonus-stage sequence that temporarily zeroes respect and restores it afterward seems likely but isn't confirmed.
