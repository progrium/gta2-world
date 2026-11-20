# Car height: ground following, ramps, jumps, falling and water

- **System:** How a car's height changes: following the ground and ramps, refusing to climb walls, launching off ramp tops and ledges, gravity and landing, tipping off edges, entering water and sinking, and a crusher riding up onto the car it crushes. Also when a parked car's physics goes to sleep.
- **Builds on:** `car-handling.md` (units, tick order), `car-collision.md` (sub-steps, landing bounces), `shape-and-map-collision.md` (wall test, map data).
- **Sources read:** the decompilation's car height update, ground and surface detection, ramp slope maths, water corner tests, the train height variant, and the car's sinking and sleep handling.
- **Date and author:** 2026-11-19, Claude (notes writer, reader side).

Tags: **[gmp]** map file, **[sty]** style file, **[exe]** fixed in the executable, **[obs]** to confirm in play.

---

## 1. What the player sees

Cars hug the road, glide up and down ramps, and drop off ledges. A car driving off the top of a ramp, or off a raised road, flies in an arc and lands with sparks and a thump. Cars cannot drive up a full-block step. A car hanging half over a ledge is tipped off it. A car whose wheels reach the water's edge is drawn in; once fully on water it loses all drive and brakes, and when it slows to a crawl it shrinks away and sinks, killing anyone inside. Tanks ride up on top of cars they flatten.

## 2. Inputs

- **Map [gmp]:** block columns, slope types and their gradient direction, length (1, 2 or 8 blocks per level) and which step of the ramp a block is, lid tiles (to recognise water).
- **Style [sty]:** which lid tiles are water. The game has two kinds: water tiles drawn with the normal palette, and water tiles using a remap. Only the remapped kind is deep water that cars sink in. The other kind is ordinary ground for cars.
- **Car:** position, horizontal velocity, current height, vertical velocity, and the four corners of its collision rectangle.

## 3. Rules

### 3.1 Surface state

After every movement sub-step, the car's **surface** is re-classified as one of: flat, ramp (with uphill direction north, south, east or west), air, deep water (fully in), or partly-in water.

1. **Gravity.** If the car (or a towed pair: both halves) is in the air, its vertical velocity drops by 1/64 per tick, but never below −1/8 (terminal speed) **[exe]**.
2. **Centre unsupported.** If there is no ground at the centre of the car at its current height:
   - Test each of the four corners for ground at its height range.
   - **No corner supported:** the car is in the air, unless it was on a ramp and is still touching a ramp block.
   - **Some corners supported** (centre over a gap): each **unsupported** corner pushes the car with an impulse of `(corner − centre of mass) / 50` **[exe]**. This tips the car over the edge toward the gap. A towed pair only does this when the other half is also in the air.
3. **Surface type.** The block under the car's centre is the block at its height, or one level down if its height is a whole number. That block decides the surface:
   - **Deep water** (remapped water lid): if all four corners are over water, the car is fully in water. Otherwise each corner **not** over water pushes the car with `(centre of mass − corner) / 50`. This pulls partly-submerged cars further in.
   - **A ramp block:** record its direction, its length in blocks per level, and which step of the ramp it is.
   - **Anything else solid:** flat.
   - **No block** (or an air block): the previous surface is kept.
4. **Landing sparks.** If the car was in the air before this step and isn't now, emit impact sparks at each corner touching ground (not on water, not for wrecks) and queue a landing thud.

Every surface rule in the handling note reads from this: air disables tyre forces, water disables engine and brakes, and ramps feed the roll-back force.

### 3.2 Height while on the ground

Each movement step, after moving horizontally:

1. **Target height** = the ground height at the car's centre (the top of the highest solid surface in that column, ramps included). A column with no ground counts as height 1.
2. **Too high to climb.** If the target is at least half a block above the car:
   - Exception: on a ramp, when the target is a fractional height no more than one level above, it is accepted.
   - Otherwise look for ground below the target instead. If that is still a full level or more above the car, the car stays at its current height. In practice it will also have hit the wall face, so it stops.
3. **Dropping away.** If the target is at least half a block below the car (driving off a ledge or the end of a ramp), the car keeps climbing or descending at the ramp rate it had, and that rate becomes its vertical velocity (see 3.3). From the next step on it is in the air.
4. **Going down.** If the new height is lower than the current one, the game checks the car's rectangle against walls at the lower height. If that is blocked, the car keeps its current height.
5. **Water:** while in deep water or partly in water, height doesn't change.
6. **Ceiling:** height is capped just below 8 (8 − 1/64) **[exe]**.

### 3.3 Ramp rate and launching

On a ramp, height changes with distance travelled along the ramp's uphill axis by a gradient set by the ramp's length:

| Ramp length per level | Gradient (height per block of travel) |
|---|---|
| 1 block (45°) | 1 |
| 2 blocks | ≈ 0.499 **[exe]** |
| 8 blocks | ≈ 0.127 **[exe]** |

The height change for a step is `distance moved uphill × gradient`, which is negative going downhill. It is used in two places:

- **Leaving a ramp's top or a ledge.** The vertical velocity becomes that height change per tick. A car driving fast up a ramp leaves the top rising at its climb rate, then gravity pulls it down. That is the ramp jump.
- **Top of a ramp.** On the topmost step of a ramp (step 0 in `map-geometry.md`), while climbing and still within the same level, the car's height snaps to at least the next whole level. This stops it clipping into the floor it is driving onto.

A towed pair doesn't launch on a rising ramp unless the other half is already in the air.

### 3.4 Height while in the air

`height += vertical velocity × step fraction`, never going below the ground directly beneath and never above the ceiling. Landing happens when the surface check (3.1) finds ground again.

Bounces off walls, cars and objects while airborne are in `car-collision.md`: the vertical velocity is reversed and scaled by 0.7, then zeroed below 1/32.

### 3.5 Sinking

A car fully in deep water with speed ≤ 0.05 blocks per tick **[exe]** is drowning. Each tick that it drowns:

- it is stopped;
- its sprite zoom increases and its collision and drawn size shrink by 2 pixels in each dimension;
- a splash is emitted behind it;
- anything riding on it sinks too;
- any running explosion timer is held at 50.

When it has shrunk away, the car is destroyed along with its occupants. A player who set it up to die gets the destroyed-car score: the full-bus bonus if it was a bus carrying 10 or more, plus gang effects for gang cars (see the scoring and gang notes).

### 3.6 Crusher riding up

While a car is crushing another (heavy-crush rule in `car-collision.md`), its height becomes at least the crushed car's height + 0.2 **[exe]**. Tanks visibly climb onto their victims.

### 3.7 Towed pairs and trains

- **Cab and trailer** each follow the ground independently. Then whichever is lower is raised to the other's height and takes its vertical velocity.
- **Trains** follow the railway height instead of the ground. They use the same "too high / dropping away" rules, but never become airborne through gravity.

### 3.8 Physics sleep

A car with no driver whose position and spin have been exactly zero for 20 ticks in a row **[exe]**, and which didn't collide that tick and isn't in water or the air, has its physics state released. It becomes a static sprite until something wakes it (a driver, or being hit). Pairs check both halves.

## 4. Order of events

Within one movement sub-step (`car-collision.md` 3.1):

1. Horizontal move and turn.
2. Height update (3.2–3.4, plus 3.6 for crushers, and the towed-pair sync).
3. Wall and sprite contact test and response.
4. Surface re-classification, gravity, edge tipping, water pull, landing sparks (3.1).

Then, once per tick after the movement loop, the drowning check (3.5) and the sleep check (3.8).

## 5. Numbers

| Value | Meaning | Source |
|---|---|---|
| 1/64 per tick, −1/8 | gravity and terminal fall speed (blocks/tick) | [exe] |
| 0.5 block | step-up / drop-off threshold | [exe] |
| 1 level | largest climb ever allowed in one step | [exe] |
| 1, ≈0.499, ≈0.127 | ramp gradients for 1-, 2- and 8-block ramps | [exe] |
| 1/50 | corner push factor for edge tipping and water pull | [exe] |
| 8 − 1/64 | height ceiling | [exe] |
| 0.05 | speed below which a car in water sinks | [exe] |
| 2 px per tick | sinking shrink rate | [exe] |
| 0.2 | how far a crusher rides above its victim | [exe] |
| 20 ticks | stillness before an empty car's physics sleeps | [exe] |

## 6. Edge cases and quirks worth reproducing

- **No-ground columns count as height 1,** not 0.
- **Ramp jumps preserve the climb rate exactly.** A long 8-block ramp gives a tiny hop, and a 45° ramp gives a big one at the same speed.
- **Partly-in-water cars are pulled in,** not pushed out.
- **Normal-palette water tiles are solid ground** for cars.
- **Sleeping cars don't simulate.** A parked car beside a slope won't roll until disturbed.
- **Drowning freezes any explosion countdown at 50,** so a burning car that falls into water sinks rather than exploding.

## 7. Open questions

- Ground height for each slope type is now in `map-geometry.md`.
- What wakes a sleeping car besides a driver entering or a collision.
