# Projectiles: flight, range and what a hit does

- **System:** What happens to the projectiles that weapons create: speed, range and lifetime, what stops them, and the damage and effects of a hit on a pedestrian or a car (bullets, pellets, rockets, flames, water, molotovs, grenades, mines, the electro baton spark). Also the accuracy and kill-credit bookkeeping a hit triggers.
- **Builds on:** `weapons.md` (what spawns them), `explosions-and-damage.md` (health, car damage, explosions), `shape-and-map-collision.md` (bullet walls).
- **Sources read:** the decompilation's built-in object definitions (for projectile speed and lifetime only), the ped "hit by object" handling, the car "hit by object" handling, the damage multiplier, and the death-cause mapping.
- **Date and author:** 2026-11-19, Claude (notes writer, reader side).

Tags: **[exe]** fixed in the executable, **[gmp]** map file, **[obs]** to confirm in play.

---

## 1. What the player sees

Bullets fly in straight lines a few screens' worth before vanishing. Shotgun pellets only carry a short way. Rockets are fast and blow up on whatever they touch. Thrown grenades bounce and roll, then explode. Molotovs burst into flames on impact. Flamethrowers set people alight. The fire truck's water cannon knocks people over and puts fires out. People shot from behind stagger forward, and from the front they stagger back. Being shot by the player's pistol is twice as deadly as by an enemy's.

## 2. Inputs

- **Projectile kind and owner**, set when fired (`weapons.md`).
- **Map:** block faces with the **bullet wall** bit **[gmp]** stop projectiles that use bullet walls, which is all the bullet kinds.
- **Target:** ped state (standing, down, dead), invulnerability, the armour power-up; car flags bullet-proof, rocket-proof, fire-proof.
- **Shooter power-up:** double damage doubles the damage numbers marked "× mult" below.

## 3. Rules

### 3.1 Flight

Each projectile moves straight each tick at its speed in its direction, plus the shooter's velocity at the moment of firing (`weapons.md`). It is removed when its lifetime runs out, or when it hits a bullet wall, a ped, a car or a solid object.

| Projectile | Speed (blocks/tick) | Lifetime (ticks) | Rough range |
|---|---|---|---|
| Bullet (machine gun, AI pistols) | 0.2 | 25 | 5 blocks |
| Player pistol bullet | as bullet **[obs]** | as bullet **[obs]** | 5 blocks |
| Shotgun pellet | 0.4 | 8 | 3.2 blocks |
| Rocket | 0.4 | 50 | 20 blocks |
| Flame / water stream piece | applied as an instant hit along the stream | 1 | stream length |

All values **[exe]**.

- **Grenades** fly with the throw speed (`weapons.md`), lose 0.01 speed per tick to friction, bounce off walls and the ground, and turn into a resting grenade when they stop. They explode when their fuse runs out (small explosion, owner credited).
- **Molotovs** explode into fire on any contact.
- **Mines** lie still until touched.

### 3.2 Hitting a pedestrian

**Which peds can be hit:** peds that are knocked down, held, or dead ignore hits, except that water still reaches the dead, and peds lying on the floor can still be hit.

**Credit and accuracy**, before damage. If the projectile has an owner:

- **The owner was targeting this ped** (or saw him as a threat): record the owner as this ped's attacker and, unless the kind gives no kill credit, as his killer for 50 ticks, with a cause from the projectile kind. The owner's weapon is told its shot connected. A player owner scores an accurate hit.
- **The owner is the player and the first case doesn't apply:** the same credit is recorded, the player scores a "hit someone else" accuracy event, and the handler stops before the damage step. *(Players obviously kill peds by shooting them, so the player's "threat or target" test must cover ordinary peds in practice. That test isn't traced yet; see Open questions.)*
- **The owner is an AI and this ped isn't its target:** the AI's weapon is told it hit the wrong person. That switches it to invisible probe shots until it has a clear line again (`weapons.md` 3.8). If this ped doesn't regard the shooter as his attacker, no damage is done.

The mission script is told about every hit.

**Effects:**

| Hit by | Effect | Damage (player victim / others) |
|---|---|---|
| Bullet, pellet, rocket, molotov, flame | staggers forward if hit from behind, back if from the front | 10 / 25, × mult |
| Player pistol bullet | as above | 20 / 50, × mult |
| Flame or fire hit | sets on fire | none directly (burning damages over time, fire note) |
| Water | staggers; puts out any fire | 2 / 5, × mult |
| Electro baton spark | latches the shooter's baton onto this ped for 20 ticks (`weapons.md` 3.6) | none directly |

All values **[exe]**.

- **Mult** is 2 if the owner is a player with the double-damage power-up, otherwise 1.
- **Armour power-up:** a player wearing armour loses one armour charge **instead of** any damage from a hit.
- **Invulnerable peds** stagger but take no damage.
- A rocket, molotov or mine touching a ped also sets off a small explosion at the ped, owner credited. Only one mine explosion is triggered per tick.

### 3.3 Hitting a car

| Hit by | Raw damage (before anti-strength) | Blocked by |
|---|---|---|
| Rocket, molotov | 32000 (destroyed), plus a small explosion at the hit point | rocket-proof; already a wreck |
| Mine | 32000, plus a small explosion | rocket-proof |
| Fire hit | 100 × mult | fire-proof |
| Player pistol bullet | 1600 × mult, with sparks | bullet-proof |
| Other bullets and pellets | 800 × mult, with sparks | bullet-proof |
| Water, baton spark | no damage | none |

All values **[exe]**. *(Which of 1600 or 800 applies to the player's pistol versus the other bullets should be confirmed. [obs])*

- Damage is applied at the midpoint between the projectile and the car's centre, which chooses the dent and fire position.
- Raw damage goes through the anti-strength scaling and damage stages in `car-collision.md` and `explosions-and-damage.md`.
- The owner is credited, and a player scores the damage.
- Only one rocket or mine explosion per car per tick is processed this way.

### 3.4 Death causes

The kind of projectile decides the recorded cause of death: bullet, shotgun, rocket, grenade, molotov, mine, bomb, fire, burning, and so on. Scoring, kill-frenzy missions and voice lines read it.

## 4. Order of events

1. Projectiles move and age (objects update).
2. On touching a ped or car, the hit handler runs (3.2–3.3), and the projectile is normally removed.
3. Explosions created by hits act from the next tick (`explosions-and-damage.md`).

## 5. Numbers

| Value | Meaning | Source |
|---|---|---|
| 0.2 / 25 | bullet speed / lifetime | [exe] |
| 0.4 / 8 | pellet speed / lifetime | [exe] |
| 0.4 / 50 | rocket speed / lifetime | [exe] |
| 10 and 25 | bullet damage to player / others | [exe] |
| ×2 | player pistol bullet; double-damage power-up | [exe] |
| 2 and 5 | water damage to player / others | [exe] |
| 1600 / 800 / 100 | bullet / bullet / fire raw damage to cars | [exe] |

## 6. Edge cases and quirks worth reproducing

- **Armour soaks whole hits,** not a share of each.
- **Rockets and molotovs destroy any normal car outright** unless it's rocket-proof.
- **The 32000 raw damage is still scaled by anti-strength.** Very tough models with low anti-strength may survive a rocket.

## 7. Open questions

- Grenade bounce rules and the exact fuse timing (object physics note).
- Flame and water stream geometry: how far the stream reaches and how it spreads.
- The player pistol bullet's own speed and lifetime (it's derived from the bullet definition in code, not listed separately).
- Fire spread and burning damage (fire note).
- Exactly which peds pass the player's "threat or target" test in 3.2. If some don't (for example, peds the player hasn't aggravated), then stray player bullets would credit without damaging them. Check this in play. [obs]
