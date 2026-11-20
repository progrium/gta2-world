# Wanted level and police response

- **System:** How the player's crimes turn into wanted points and stars, how the one-star level wears off, how police notice crimes, and how many and which kind of police crews are sent at each star level.
- **Out of scope (separate notes):** how individual cops drive, chase, shoot and arrest (police AI note); roadblocks in detail; respray shops and other ways to clear the level (garages and pickups notes).
- **Builds on:** `weapons.md` and `explosions-and-damage.md` (where crime reports come from), `car-collision.md` (ramming police).
- **Sources read:** the decompilation's crime report queue, the ped wanted-points bookkeeping, kill crediting, the cop "sees a crime" check, and the police pursuit manager.
- **Date and author:** 2026-11-19, Claude (notes writer, reader side).

Tags: **[exe]** fixed in the executable, **[obs]** to confirm in play.

---

## 1. What the player sees

Shooting near cops, hitting them, or wrecking cars in their sight gets you a star. A single star wears off if you lie low for about half a minute; anything higher sticks. More stars bring more police cars, then SWAT vans, then FBI, then the army with tanks. Killing ordinary people raises the level steadily, and killing police or other emergency workers raises it fast. Killing gang members barely registers.

## 2. Inputs

- Crime events from other systems: shooting, killing, destroying cars, hitting police.
- The mission script can cap the maximum number of stars.
- A "no police" debug or cheat setting clears the level every tick.

## 3. Rules

### 3.1 Points and stars

Each ped has a wanted-points total from 0 to 12000. The player's stars are read from it:

| Points from | Stars | Response tier |
|---|---|---|
| 0 | 0 | none |
| 600 | 1 | police |
| 1600 | 2 | police |
| 3000 | 3 | police |
| 5000 | 4 | SWAT |
| 8000 | 5 | FBI |
| 12000 | 6 | army |

All thresholds **[exe]**.

- **Adding points:** add, clamp to 0–12000, then reduce the total to the script's maximum star count if it is above it.
- **"Set to at least one star"** means raising the total to 600 if it is below.

### 3.2 What earns points

| Event | Effect |
|---|---|
| The player kills an ordinary ped, and the kill is reportable | +100 |
| The player kills an emergency worker (police, medic, firefighter), reportable | +500 |
| The player kills a gang member, reportable | +1 |
| The player destroys a car, reportable | at least one star; if already wanted, +200 |
| A player-driven car crushes, or hits with impact over 0.6, a police, SWAT or FBI vehicle | at least one star |
| A cop sees the player committing a crime (3.3) | at least one star |

All values **[exe]**.

**Reportable:** a kill or destruction caused by a mine, or by an object hit, counts only if the victim is within the player's view area. A car destroyed while being crushed (crane or crusher) never counts.

### 3.3 Police noticing crimes

- **Crime reports.** Every time the player fires a weapon (`weapons.md`), damages a car, or commits another crime, a report is queued. It holds the crime kind and where the player was. The queue is a small ring that overwrites the oldest report when full. "Weapon fired" and "car damaged" are only queued if one of that kind isn't already waiting.
- **Exempt shooters:** reports are never filed for police, SWAT, FBI, army, guards or roadblock cops.
- **Recent-crime timer:** filing a report of any other kind also starts this timer on the ped, and moves the police's "last known position" of the player to his current spot.
- **When a cop has the player in view,** he treats the player as a target if any of these hold:
  - the player is attacking with a weapon that counts as an armed attack;
  - the player is already wanted;
  - the player attacked this cop;
  - the player's recent-crime timer is running.

  He then updates the last seen position and raises the player to at least one star. A player mid-jump is never noticed in that moment.
- The player's per-crime statistics are counted for the end-of-level stats (scoring note).

### 3.4 One-star timeout

At exactly the 1-star tier, a counter runs every tick that no police crew is actively pursuing the player. After 900 ticks (≈30 seconds) **[exe]** the level is cleared to 0. Being pursued resets the counter. Two stars and above never wear off by time alone.

A player who has just respawned has his level cleared.

### 3.5 Pursuit and crews

The police track up to a fixed number of wanted players (one per player in multiplayer). For each, every tick, the target crew mix comes from the star tier:

| Tier | Police car crews wanted | Extra units | Cap on new police cars spawning |
|---|---|---|---|
| 1 star | 1 | none | 1 until one crew exists, then 0 |
| 2 stars | 2 | none | 2 while there's one crew or fewer, then 0 |
| 3 stars | 2 | none | 2 while there's one crew or fewer, then 0 |
| 4 stars (SWAT) | 2 | one SWAT crew once police are active | as for 3 |
| 5 stars (FBI) | 0 (police crews sent home) | FBI | 2 while no police or SWAT and at most one FBI crew |
| 6 stars (army) | 0 (others sent home) | army | none |

The pursuit itself runs through states:

1. **Idle.** When the player becomes wanted and no crew is assigned, a crew is created. It starts on the nearest road tile to the player's last known position, with a spawn delay of 200 ticks **[exe]**.
2. **Responding.** While the crew drives over, its timer counts. At a fixed point, every crew assigned to this pursuit is switched to chasing.
3. **Active.** The crews chase. Extra crews are added up to the tier's target, or upgraded (SWAT, FBI, army). Surplus police crews are sent away when the target drops.
4. **Searching.** If the chase timer runs out (the player lost them), crews search around the last seen position. At the FBI tier, crews more than 5 blocks from it are drawn back toward it.
5. **Ended.** If the player's level returns to 0, or he dies or leaves the game, all crews are released.

When a pursuit ends, the global cap on new police cars resets to 2 **[exe]**.

### 3.6 Busted

If police arrest the player, the player is flagged as busted. The consequences (losing weapons, paying, respawning) are in the player-respawn note.

## 4. Order of events (once per tick)

1. Each wanted ped's update registers him with the police (or clears his level under "no police").
2. The police update each pursuit: read the tier, set the crew targets and the new-car cap, check the one-star timeout, then advance the pursuit state.
3. Crews act (police AI note).

## 5. Numbers

| Value | Meaning | Source |
|---|---|---|
| 600 / 1600 / 3000 / 5000 / 8000 / 12000 | points for 1–6 stars | [exe] |
| +100 / +500 / +1 / +200 | civilian kill / emergency worker kill / gang kill / car destroyed while wanted | [exe] |
| 0.6 | impact on a police vehicle that earns a star | [exe] |
| 900 ticks | one-star timeout | [exe] |
| 200 ticks | spawn delay for the first responding crew | [exe] |
| 5 blocks | FBI search leash | [exe] |

## 6. Edge cases and quirks worth reproducing

- **Only one star wears off.** Above that, the player has to use a respray or a similar service.
- **Gang kills are nearly free** (+1) for the wanted level, but they hit gang respect (gangs note).
- **Cops are allowed to commit crimes;** their gunfire never generates reports.
- **Jumping hides you** from a cop's witness check for that moment.
- **Reports are de-duplicated** for gunfire and car damage, so spraying bullets doesn't flood the queue.

## 7. Open questions

- How cops actually find and approach a target, and how arrest works (police AI note).
- Roadblock placement rules.
- The exact length of the "responding" and "active" timers.
