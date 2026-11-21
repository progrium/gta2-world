# Power-ups, death ("wasted"), arrest ("busted") and respawn

- **System:** What each power-up pickup does and how long it lasts; what happens when the player dies or is arrested: the death message, the body left behind, lives, losing weapons, the jail card, the multiplier penalty, and where he respawns.
- **Builds on:** `weapons.md` (fast reload), `projectiles.md` (armour, double damage), `wanted-level.md` (cop bribe, arrest), `explosions-and-damage.md` (health, invulnerability).
- **Sources read:** the decompilation's player power-up collection and timers, the player death and arrest handlers, and the respawn placement.
- **Date and author:** 2026-11-19, Claude (notes writer, reader side).

Tags: **[gmp]** map file, **[exe]** fixed in the executable, **[obs]** to confirm in play.

---

## 1. What the player sees

Power-ups give extra lives, health, armour, a jail card, a police bribe, invulnerability, double damage, fast reload, electro-fingers, invisibility, gang respect, an instant gang, or a score multiplier. Timed ones run out. Picking one up you already have at full strength is refused, and the pickup stays where it is. Dying shows "WASTED" (or "FRIED", "SHOCKED" and so on), costs a life, and the player comes back at the nearest restart point without his guns or power-ups. Being arrested shows "BUSTED". It doesn't cost a life, but it takes your guns and halves your multiplier, unless you hold a jail card. With no lives left it's game over.

## 2. Inputs

- **Power-up pickups** (objects note) and the kind each one gives.
- **Restart zones** in the map's zone list **[gmp]**.
- **Cheat or debug options:** keep weapons after death, unlimited jail card, unlimited double damage, permanent invisibility.

## 3. Rules

### 3.1 Power-ups

| Power-up | Effect | Duration or charges | Refused when |
|---|---|---|---|
| Multiplier | +1 score multiplier | permanent | already 99 |
| Extra life | +1 life | permanent | already 99 |
| Health | health to full (100) | instant | already at 100 or more |
| Armour | absorbs whole hits, one charge each (`projectiles.md`) | 10 charges | already 10 |
| Jail card | cancels the arrest penalty once (3.3) | 1 charge | already held |
| Cop bribe | clears the wanted level | instant | not wanted |
| Invulnerability | ignores damage (`explosions-and-damage.md`) | 1200 ticks (≈40 s) | timer already full |
| Double damage | ×2 weapon damage | 1800 ticks (≈60 s) | timer already full |
| Fast reload | halves the wait between shots | 1800 ticks | timer already full |
| Electro-fingers | electric touch attack (ped AI note) | 2100 ticks (≈70 s) | timer already full |
| Invisibility | not seen by peds and police | 1800 ticks | timer already full |
| Respect | +20 respect with the gang whose area you're in | instant | not in a gang area, or respect already 100 |
| Instant gang | recruits up to 4 nearby peds as followers | instant | player not on foot |

All values **[exe]**.

- **Refreshing:** picking up a timed power-up while it's running restarts it at full length, but only if it isn't already exactly full.
- **Countdown:** timers count down once per tick. When invulnerability, electro-fingers or invisibility run out, their effect is removed.

### 3.2 Death (wasted)

1. **Life:** the player loses a life (not in network games).
2. **Message and voice:** if lives remain, the death message (by cause) and the "wasted" voice line. On the last life, "game over" instead.
3. **Body double:** if more than one life remained, a copy of the player is left as the dead body. The camera stays on it, and the real player is moved to the respawn point straight away (3.4).
4. **Countdown:** a 70-tick countdown **[exe]** runs. When it ends with lives remaining:
   - any kill-frenzy weapon is removed;
   - unless the keep-weapons option is on, all weapons, car weapons and power-ups are removed, except the jail card;
   - the camera returns to the player with smoothing reset;
   - the body double is removed.
5. **Game over:** with no lives left when the countdown ends, the level exits as game over.

Death messages by cause: shot or ordinary death "wasted", burned "fried", electrocuted "shocked", arrested "nicked/busted" (text keys from the game's text file).

### 3.3 Arrest (busted)

1. **No life lost.** Show the death message, start the same 70-tick countdown, break up any gang the player leads, and leave a body double (the one the police arrest).
2. **Immediately:** the player is moved to the respawn point. His shock counter and wanted level are cleared.
3. **Two ticks before the end of the countdown**, the double is ordered to call a police car (it gets driven off).
4. **When the countdown ends:**
   - **Jail card held:** use one up (unless unlimited) and keep everything.
   - **No jail card:**
     - lose all weapons, car weapons and power-ups except the jail card (unless the keep-weapons option is on);
     - the **score multiplier is halved**, rounded down, minimum 1.
5. **Bonus stages and no lives:** in a bonus stage, or with no lives, the level exits as game over instead.

### 3.4 Respawn point

- **Single player:** the restart zone nearest the player's position at death.
- **Network games:** restart zones are used round-robin.

The player ped is placed there fresh: full health, standing, no wanted level.

## 4. Order of events (per tick for the player)

1. Count power-up timers down (3.1).
2. If dead or busted and not already handling it: start the death or arrest sequence (3.2–3.3), respawning the player at once.
3. If the sequence is running: count down and finish it when it reaches 0.

## 5. Numbers

| Value | Meaning | Source |
|---|---|---|
| 1200 / 1800 / 2100 ticks | invulnerability / double damage, fast reload, invisibility / electro-fingers | [exe] |
| 10 | armour charges | [exe] |
| 20 | respect from a respect pickup | [exe] |
| 4 | peds recruited by instant gang | [exe] |
| 99 | lives and multiplier cap | [exe] |
| 70 ticks | death or arrest countdown | [exe] |
| ½ (min 1) | multiplier after an arrest without a jail card | [exe] |

## 6. Edge cases and quirks worth reproducing

- **The player is already at the respawn point during the "wasted" countdown,** while the camera watches the body double. Anything that queries the player's position sees the new one.
- **The jail card survives death,** but not its own use.
- **Getting busted keeps your life but not your multiplier.**
- **A full-length timed power-up can't be re-collected,** but one that has ticked down even once can.

## 7. Open questions

- Electro-fingers and invisibility effects in detail (ped AI and police notes).
- Instant-gang recruit radius.
- Death-message selection for every cause.
