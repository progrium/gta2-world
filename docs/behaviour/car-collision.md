# Car collision response

- **System:** What happens when a moving car touches a wall, another car, a pedestrian or an object: how the tick's movement is split up to find the moment of contact, the impulse that bounces the cars apart, how impact turns into damage, crushing by heavy vehicles, the "unstick" nudge against walls, and the wanted-level and scoring side effects.
- **Out of scope (separate notes):** deciding *whether* two shapes overlap, and which map blocks count as solid (sprite/map collision note); what a pedestrian does when hit (pedestrian note); explosions and fire; height, ramps, falling and water (car height note).
- **Builds on:** `car-handling.md` for units, the car-local frame, mass, moment of inertia and the tick order.
- **Sources read:** the decompilation's car physics module (its move-and-collide step, impulse calculation, and the wall, car, object and pedestrian responses), the car's damage accumulation, and the edge of the map collision test.
- **Date and author:** 2026-11-19, Claude (notes writer, reader side).

Tags: **[gci]** player's `.gci` file, **[sty]** style file, **[exe]** fixed in the executable, **[obs]** to confirm in play.

---

## 1. What the player sees

Cars bounce off walls with little rebound and slide along them. Car-on-car hits are bouncier, and both cars spin about where they were struck. Hitting a stuck car head-on while holding the gas slowly rotates you until you can slip past. Hard hits dent the side of the car that was struck, start smoke, then fire, then an explosion. Tanks and other heavy vehicles flatten ordinary cars instead of bouncing off them, and doing this to a police car earns a wanted star. Running into pedestrians knocks them flying. A train hitting a car blows it up.

## 2. Inputs

- **Per model:** mass and moment of inertia (see `car-handling.md`); **anti-strength** **[gci]** (the 15th field of a `.gci` record), which scales how much damage each hit does; the **heavy** flag in the style file's car info **[sty]**, which allows crushing.
- **Per car:** current damage 0–32000; whether the driver is a player, an AI or nobody; flags that make a car ignore collisions or count as jammed or parked.
- **Controls:** holding gas or reverse while blocked triggers the unstick nudge. A held handbrake halves some push-apart impulses.

## 3. Rules

### 3.1 Moving with sub-steps

A car's movement for one tick is "move by velocity × remaining time, turn by angular velocity × remaining time". The remaining time starts at 1 each tick. While at least 1/8 of the tick remains **[exe]**:

1. **Try the whole remaining move** from the current pose.
2. **Pick a sub-step count** large enough that no sub-step jumps through anything. Take the largest of:
   - the move's |Δx|, |Δy| and |Δz|, each divided by the car's smaller sprite dimension;
   - the change in heading divided by 45° **[exe]**.

   A towed trailer gets the same treatment, and the larger result wins.
3. **Test for contact.** If the count is above 1, test at evenly spaced fractions (1/count, 2/count, … up to the whole-number part of the count) and stop at the first one that touches something. If nothing has been hit by then, or the count was 1 or less, test the full move.
4. **If nothing is touched,** the car keeps the full move and the tick's movement is finished.
5. **If something is touched:**
   - If it's the same thing this car already hit earlier in this tick, put the car back where this sub-move started and end the tick's movement there.
   - Otherwise, narrow down the time of contact with **3 bisection steps** **[exe]** between the last clear fraction and the first touching one.
   - Take the contact geometry from the car's pose at the touching fraction, and place the car at the last clear fraction.
   - Run the collision response below.
   - Remaining time × (1 − clear fraction).
6. **Cap on contacts.** At most 2 contacts per tick. Each contact with a pedestrian or object raises that cap by one, up to 4 **[exe]**. A car can plough through a crowd within one tick but stops at the second hard thing.

Any time left when the loop stops (under 1/8, or after the cap) is simply lost.

**Trains:** a train touching something while moving diagonally (both velocity components non-zero) gets a clear fraction of 0, so it doesn't advance that sub-step.

After movement, the car's "actual velocity" is the distance it really moved this tick. Speed readouts and anything else that asks how fast the car truly went use this, not the physics velocity.

### 3.2 Unstick nudge

Applies when a whole tick's movement was blocked immediately (no time used up), something was hit, and the driver is holding gas or reverse. The game applies a small nudge and runs the movement step once more:

- **Against a map wall edge** (wall faces are always aligned to the x or y axis): turn the car by 1° **[exe]**, in whichever direction brings its direction of travel toward running parallel to the wall. When reversing, the direction of travel is the heading turned 180°. Also push it 1/64 block **[exe]** per tick straight away from the wall.
- **Against a sprite** (car, object, ped): turn by 1° and push 1/64 block away from the contact.
  - A player car gets × 0.9 of both and an AI car × 1.1 **[exe]**.
  - The diagonal-wall object always uses the plain 1° and 1/64.
  - The turn direction depends on which side of the car's centre line the contact point is.

"Turn by an angle" here means an angular impulse of moment of inertia × angle, so it is independent of the car's size. "Push" is scaled by mass, so it is also size-independent.

If the retry still can't move at all, the car's velocity and angular velocity are set to zero.

*(Turn direction for the wall-edge case is reconstructed from quadrant tests; confirm by driving into a wall at a slight angle while holding gas. [obs])*

### 3.3 The collision impulse

Every response uses one rigid-body impulse formula. Let:

- `v` be the relative velocity of the contact point. This includes rotation and is measured as how far the contact point on this car would move in one tick, minus the same for the other body if it moves.
- `n` be the unit contact direction (defined per case below), pointing toward this car.
- `r_a` and `r_b` be the vectors from each body's centre of mass to the contact point, each turned 90° anticlockwise.
- `m_a`, `I_a`, `m_b`, `I_b` be the masses and moments of inertia. A towed trailer and its cab count as one body with summed mass and inertia, and the combined centre of mass.
- `e` be a restitution value per case.

```
j = −(1 + e) · (v · n)  /  [ (1/m_a + 1/m_b) + (r_a · n)²/I_a + (r_b · n)²/I_b ]
impulse = j · n
```

For an immovable body, the `1/m_b` and `(r_b·n)²/I_b` terms are dropped. If either `v` or the unnormalised `n` is exactly zero, the impulse is zero.

Applying an impulse to a car changes its velocity by `impulse / mass` and its angular velocity by the matching torque about the centre of mass, immediately and not on the next tick. Impulses on a trailer are passed to its cab.

| Contact | `n` (before normalising) | Other body | `e` |
|---|---|---|---|
| Map wall | the wall's axis direction, toward the car | immovable | 0.25 |
| Another car | this car's centre of mass − contact point | the other car | 0.5 |
| Pushable object | this car's centre of mass − contact point | the object's mass, inertia 1 | 1.0 |
| Fixed object | this car's centre of mass − contact point | immovable | 0.25 |
| Pedestrian | this car's centre of mass − contact point | mass 0.5, inertia 1 | 1.0 |

All `e` values, the ped mass and the object inertia are **[exe]**.

**Wall contact points.** If a corner of the car crossed the wall line, that corner is the contact point. If instead the end of a wall segment poked into the car's side, the contact point is that wall end. It is found by carrying the hit point from the touching pose into the car's current pose and then snapping to the nearer end of the wall segment.

For non-wall contacts, `n` points from the contact point to the car's own centre of mass, not along the surface normal of what was hit. Glancing blows therefore throw cars toward their own centres, which is part of the game's characteristic spin-outs.

### 3.4 Applying an impulse to a car

- If `|impulse| / mass ≤ 0.01` **[exe]**, the car's velocity is left alone, but the impulse size still counts toward damage.
- A **jammed** AI car (parked, handbrake on, or slower than 0.05) takes only a third of the impulse.
- The car's alarm goes off (if it has one).
- A car flagged to ignore collisions takes no impulse.
- An AI driver's handbrake is released by any impulse it takes.
- The car is marked "recently hit" for a number of ticks equal to the impact's base damage: 15 for walls and objects, 50 for cars **[exe]**. While that window is open, an unhitched trailer won't be drawn toward a cab's hitch.

### 3.5 Damage

The impact strength is the impulse magnitude.

- **Car damage gained** = `anti-strength × impact × 200`, rounded down and at least 1 unless anti-strength is 0. The total is capped at 32000.
- **Damage stages:**

  | Damage | Effect |
  |---|---|
  | 16 000 | first damage fire effect, and the speed penalty begins (see handling note) |
  | 25 000 | larger fire |
  | 31 500 | explosion sequence starts |
  | 32 000 | maximum damage; a wreck takes no further damage |

- **Dents:** the struck quarter of the car (front, back, left or right, decided by the overlap test) gets a visible dent when `anti-strength × impact ≥ 1`. It's attempted for walls only if the car's speed is over 0.03 blocks per tick, and for cars and objects only if the impact is over 0.3 **[exe]**.
- **Impact sparks** are emitted only when the car is moving faster than 0.03 and isn't already a wreck.
- **Taxis** (both taxi models) dump their passengers when the impact exceeds 2.
- **Scoring:** when a hit adds more than 200 damage points to a car, the player driving the other car scores for it.

### 3.6 Case details

**Wall.**
- Impulse and damage as above, base damage 15.
- An airborne car that is still rising or level bounces vertically, with vertical speed × −0.7, set to zero below 1/32.
- A car resting in the air against a wall with no motion at all takes a minimum impact of 1 per tick. This stops cars hanging on walls forever.

**Car versus car.** Both cars take the same impulse in opposite directions and the same damage figure, with base damage 50 for both.

- **Landing on another car** (this car is airborne and at a different height):
  - vertical bounce as for walls;
  - a push-apart impulse of 0.1 along the line between the two centres of mass, both ways (halved for a car with its handbrake on);
  - extra damage = `mass × |vertical speed| × 50`.

  If the heavy-crush rule below applies, the landing car crushes the other instead of pushing.
- **Heavy crush.** All of these must hold:
  - this car is *heavy* **[sty]** and is either a tank or not AI-driven;
  - the other car is not heavy;
  - the impulse exceeds 0.2;
  - this car is moving faster than 0.01.

  Then no bounce happens. This car becomes a crusher. On the next check, the touched car takes crush damage, has its velocity zeroed and becomes a flattened wreck. The crusher keeps crushing until it touches no other car.
- **A train** that hits a car makes that car explode.
- **Police:** if a player-driven car crushes a police, SWAT or FBI vehicle, or hits one with an impact over 0.6, the player's wanted level rises to at least one star.
- Both cars' AIs are told who they collided with.

**Object.**
- A pushable object takes `−impulse / object mass` as its new movement.
- An airborne car landing on an object at a different height bounces as for cars and pushes the object away.
- The object gets its own hit reaction (breaking, scoring and so on; separate note).

**Pedestrian.**
- The impulse is computed with the ped as mass 0.5.
- The ped is handed the knock-back `−impulse / 0.5`, plus a flag saying whether it was hit from above (a falling car) or by a grazing contact. What happens next is in the pedestrian note.
- The car's driver is recorded as the ped's killer for 50 ticks. This is "run over by stolen car" if the ped owned this car, otherwise "run over".
- A trailer passes credit to its cab's driver.
- The car itself takes no impulse from a ped.

### 3.7 Map edge

At the top level of the map (height ≥ 7), a car within 1 block of the map's outer edge (x or y < 1, or > 255) hits an invisible straight wall there. Lower levels rely on the map's own blocks. *(Check whether low-level map edges are always walled in the shipped maps. [obs])*

## 4. Order of events

Within the tick order given in `car-handling.md`:

1. At the very start of the tick, cars that already overlap other cars (from last tick or from spawning) are resolved first.
2. Velocity is updated by the handling rules.
3. The move is done with sub-steps (3.1). Each contact's response (3.3–3.6) is applied at the moment it's found, so a later sub-step in the same tick uses the post-bounce velocity.
4. If the tick was fully blocked while the driver holds gas or reverse, the unstick nudge (3.2) runs, then one more move attempt.
5. Pending crushes are applied.
6. The tick's actual movement is recorded as the car's true velocity.
7. Skid marks come next (separate note).

## 5. Numbers

| Value | Meaning | Source |
|---|---|---|
| 1/8 tick | smallest remaining time worth moving | [exe] |
| 45° | maximum heading change per sub-step | [exe] |
| 3 | bisection refinements per contact | [exe] |
| 2, up to 4 | contacts per tick (+1 per ped or object) | [exe] |
| 0.25 / 0.5 / 1.0 | restitution: wall and fixed object / car / pushable object and ped | [exe] |
| 0.5 | ped mass for impacts | [exe] |
| 200 | damage per unit of impact, before anti-strength | [exe] |
| 16000 / 25000 / 31500 / 32000 | damage stages | [exe] |
| 15 / 50 | base damage for wall and object / car | [exe] |
| 0.01 | smallest impulse per unit mass that moves a car | [exe] |
| 0.03 blocks/tick | speed for wall dents and sparks | [exe] |
| 0.3, 0.6 | impact for car and object dents; for wanted star on hitting police | [exe] |
| 1°, 1/64 block | unstick turn and push (×0.9 player, ×1.1 AI against sprites) | [exe] |
| 0.7, 1/32 | vertical bounce factor and cut-off | [exe] |

## 6. Edge cases and quirks worth reproducing

- **Same-object stop.** Hitting the same thing twice in one tick freezes the car at the start of that sub-move. Corner pinning against a single car looks like a dead stop rather than a jitter.
- **Contact direction is toward the centre of mass**, not the surface normal. Side-swipes spin both cars.
- **Lost time.** Leftover movement under 1/8 of a tick is dropped. Cars in long scraping contact with walls move slightly slower than their speed suggests.
- **Jammed AI cars are hard to shove** (a third of the impulse) until they start moving.
- **Hits release AI handbrakes.** A rammed parked car rolls.
- **Player cars nudge off walls less eagerly than AI cars** (0.9 against 1.1).
- **Wreck immunity.** At 32000 a wreck takes no more damage and no more dents.

## 7. Open questions

- The overlap test itself: the car's collision rectangle, which map block faces are solid at which heights, and how "front, back, left or right quarter" is chosen. Planned for the sprite/map collision note.
- How the overlap check at the start of the tick separates cars that spawned overlapping.
- The exact crush sequence and its timing (crush damage, the flattened sprite). Will go in a vehicle-damage note with explosions.
- What the jammed and ignore-collisions flags are set by (scripts? parked-car generators?).
