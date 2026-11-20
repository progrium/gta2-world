# Explosions, car destruction and pedestrian damage

- **System:** How explosions work (size, timing, who and what they hurt, knock-back, burning debris, camera shake), how a car goes from damaged to destroyed, and how pedestrians take damage: health, the shock (electrocution) counter, invulnerability, and the knocked-down / knocked-out / killed outcomes.
- **Builds on:** `car-collision.md` (car damage scale 0–32000 and anti-strength), `ped-movement.md` (knock-down outcomes from car hits), `weapons.md` (what creates explosions).
- **Sources read:** the decompilation's explosion object (blast size, per-tick damage window, debris), the car's explode and wreck handling and explosion impulse, ped health, damage and shock handling, and the ped "thrown by an impact" reaction.
- **Date and author:** 2026-11-19, Claude (notes writer, reader side).

Tags: **[exe]** fixed in the executable, **[obs]** to confirm in play.

---

## 1. What the player sees

An explosion is a fireball with a flash and a camera shake. People close to it are flung away. Close in, they're killed; at the edge, they're knocked off their feet. Cars caught in it blow up too, so explosions chain along a line of parked cars. Burning fragments fly out and start small fires. A damaged car smokes, then burns, its lights die, and finally it explodes, killing everyone inside and leaving a wreck. People hit with electricity jerk on the spot and drop.

## 2. Inputs

- **Explosion kind**, chosen by whatever caused it. Cars use the car explosion; rockets, grenades and bombs use their own kinds (projectiles note); buildings have four directional kinds for scripted demolitions.
- **Car flags:** rocket-proof and fire-proof (both set by scripts or cheats).
- **Ped:** health, an invulnerability timer, the shock counter and its threshold.

## 3. Rules

### 3.1 Explosion size

| Kind | Blast radius (blocks) |
|---|---|
| Small (grenade in hand, and others) | 0.5 |
| Small, larger variant | 0.75 |
| Car / item | 1 |
| Car / item without the shock ring | 1 |
| Large | 2 |
| Building (four directions) | 0.5 |

All values **[exe]**. The vertical reach is ±0.2 block from the explosion's height for every kind.

"Distance" in this note means the larger of |dx| and |dy| (a square, not a circle), measured between centres.

### 3.2 Explosion timeline

An explosion has a timer that starts at 99 and counts down by 1 per tick **[exe]**.

| Timer | What happens |
|---|---|
| 99 (first tick) | camera shake of strength 8 at the explosion; a flash (except the small and no-ring kinds); every car within the radius gets an outward impulse (3.4) |
| 89, 79, 69, 59 | a burning fragment is thrown out at 0.09 per tick, rising at 0.2 with light gravity, carrying a small fire and an orange light **[exe]** |
| above 50 | the blast checks everything in a square of side 4 × radius around it, every tick (3.3) |
| 50 and below | visual only, fading |

Fragments and particles are only spawned while the explosion is on screen, except during its first 10 ticks. Damage is applied whether or not it's on screen.

### 3.3 Blast effects (timer above 50)

**Peds** that are standing (not already knocked down or dead):

- The explosion's owner is credited, with cause "explosion", for 50 ticks.
- **Within half the radius:** thrown outward at 0.09 per tick, launched upward at 0.3. They're killed when they land, unless invulnerable (then they get up).
- **Within the radius:** thrown at 0.09, launched up at 0.1. A non-player is killed. The player is knocked down and gets up.
- **Outside the radius but inside the search square, while the timer is above 70:** knocked over at 0.15 with no lift, then gets up.

Peds caught by later ticks of the same explosion are usually already down, so they aren't thrown twice.

**Cars** (not wrecks, not trains, and not immune):

- During timer 51–59 and again 81–89, a car within the radius takes 32000 raw damage. This is scaled by its anti-strength, as in `car-collision.md`. For most cars it reaches the maximum and they explode, which is how explosions chain.
- The owner is credited as the car's destroyer for 50 ticks. The player scores for any damage done (scoring note).
- Cars in the search square but outside the radius just have their alarms set off.

**Immunity:** a car flagged rocket-proof or fire-proof ignores every explosion kind except the large one.

**Objects** in the square during timer 51–59 are told an explosion went off nearby, and react by kind (objects note).

### 3.4 Explosion impulse on a car

The outward push is aimed from the explosion to a point near the car's centre. That point is offset diagonally by −0.5, −0.25, 0, +0.25 or +0.5 block in turn **[exe]**, cycling through those five values with each push. The cycle is shared by all cars, so cars in a blast spin different ways. The push size is `1 / (4 × distance)` along that direction. It's applied like a collision impulse with base damage 10. Nearer cars are thrown harder.

### 3.5 From damage to destruction (cars)

Car damage accumulates as described in `car-collision.md`.

| Damage | Stage |
|---|---|
| 16 000 | first fire on the car (smoke and small flames) |
| 25 000 | larger fire, replacing the first |
| 31 500 | all lights go out: headlights, brake lights, emergency lights, flashing lights |
| 32 000 | the car explodes (3.6) |

### 3.6 A car exploding

1. Cancel any police chase assignment for it.
2. Start the wreck countdown: the engine is marked dead, then 50 ticks **[exe]** of settling.
3. Create a car explosion at the car's position, owned by whoever is credited with destroying it.
4. Everyone inside dies, credited to the destroyer. A player driver's car physics switches to non-player handling.
5. Push the car itself (3.4) and remove everything attached to it.
6. Set damage past the maximum. The car is a wreck: it takes no more damage and can't explode again.
7. If the destroyer is a player:
   - **Score:** a full-bus bonus if it was a bus carrying 10 or more, otherwise the destroyed-car score. There's extra cash if the driver was an ordinary background driver.
   - **Gangs:** destroying a gang's car costs respect with that gang.
   - **Wanted level:** if the destruction counts as a reportable car crime, the wanted level rises to one star, or by 200 points if already wanted.
8. If a mission is watching for this car model to be destroyed, it's notified.

The "credited destroyer" is set by whatever last damaged the car with credit: weapons, explosions, collisions with the player. It is forgotten after 50 ticks without a new credited hit.

### 3.7 Pedestrian health and damage

- Peds have health; the player starts at 100 **[exe]**. Damage reduces it. At 0 the ped dies, unless he's currently knocked down or held, in which case health stays at 0 until the state ends.
- **Invulnerability:** while a ped's invulnerability timer runs (after respawning, or from a power-up), all damage is ignored. Every knock-back becomes the mildest kind: knocked over and gets up.
- **Kill credit:** whoever hurt the ped is remembered for 50 ticks, together with the cause (run over, shot, drowned, electrocuted, exploded, and so on). This drives scoring, gang respect and wanted level.

### 3.8 Shock and electrocution

- Each ped has a shock counter and a threshold of 100 **[exe]**.
- Sources: the electro gun adds 5 per tick to each ped it hits, and electrified floors add 3 per tick (`ped-movement.md`).
- Every tick the counter falls by 1. It is capped at the threshold.
- Reaching the threshold while standing and not mid-jump electrocutes the ped: he plays the electrocution animation and drops (ped AI note covers recovery and death).
- In net terms, an electrified floor takes about 50 ticks of standing, and the electro gun about 25 ticks of continuous fire.

### 3.9 Being thrown

Every "thrown" reaction (blasts here, car hits in `ped-movement.md`) works the same way:

- The ped is carried by a moving object at the given horizontal speed and angle, with the given upward speed, and gravity of 0.02 per tick **[exe]**.
- When the object stops, the outcome is applied: get up, lie on the floor, or die.
- A blood burst is shown for anything other than the mildest knock-over.

## 4. Order of events (one explosion, one tick)

1. Spawn particles, the flash and fragments if due (3.2).
2. If the timer is above 50, apply blast effects to everything in the search square (3.3).
3. On the first tick, shake cameras.
4. Count the timer down.

## 5. Numbers

| Value | Meaning | Source |
|---|---|---|
| 0.5 / 0.75 / 1 / 2 | blast radii | [exe] |
| ±0.2 | blast vertical reach | [exe] |
| 99 → 0, damage while > 50 | explosion timeline | [exe] |
| 51–59 and 81–89 | ticks when cars take blast damage | [exe] |
| 0.09 / 0.3 / 0.1 / 0.15 | thrown speeds (horizontal; up close; up within radius; knock-over outside) | [exe] |
| 16000 / 25000 / 31500 / 32000 | car damage stages | [exe] |
| 50 ticks | kill and destroy credit memory; wreck countdown | [exe] |
| 100 | player health; shock threshold | [exe] |
| +5 / +3 / −1 per tick | shock from electro gun / floor; decay | [exe] |
| 8 | camera shake strength | [exe] |

## 6. Edge cases and quirks worth reproducing

- **Square blasts.** Distance is the larger axis difference, so blasts reach further diagonally than a circle would.
- **Cars get two damage windows** per explosion, so cars with high anti-strength resistance may survive one window but not both.
- **Chain reactions** come from the car explosion's 1-block radius hitting neighbouring cars within ten ticks.
- **Rocket-proof and fire-proof cars still die to large explosions.**
- **The shared impulse offset cycle** makes cars in the same blast spin differently. To reproduce exact replays, keep the cycle global.
- **Invulnerable peds are knocked over, not killed,** even by point-blank blasts.

## 7. Open questions

- Whether the fires attached to a damaged car (16 000 and up) add damage over time and so make burning cars explode by themselves. This is in the fire and object code, still to be read.
- What the wreck countdown does when it runs out (despawn or sprite change).
- The non-player peds' starting health (set per ped type).
