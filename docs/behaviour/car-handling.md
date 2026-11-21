# Car handling

- **System:** How a car on the ground responds to throttle, brake, steering and handbrake each tick: engine force, gears, tyre grip, braking, steering angle, damping, speed caps, oil slicks, steep-slope roll-back and the "arrow snap" lane assist. Also how per-model handling values are derived from the `.gci` and `.sty` files.
- **Out of scope (separate notes to follow):** collision response and damage from impacts, height/air physics (ramps, falling, water), skid marks and tyre smoke, trailers and trains beyond the few hooks mentioned here, AI driving decisions.
- **Sources read:** the decompilation's car physics module, its car-model data loader (the `.gci` parser and the per-model values derived from it), the code that turns the player's keys into car inputs, the car's damage and mass helpers, and the main loop's frame timing. No footage checked yet; items marked *(unverified in play)* should be confirmed against the real game.
- **Date and author:** 2026-11-19, Claude (notes writer, reader side).

Value tags used below: **[gci]** read from the player's `.gci` file, **[sty]** from the style file's car info, **[exe]** fixed in the executable (flagged, single values only), **[obs]** needs confirming by observation.

---

## 1. What the player sees

Cars feel loose and arcade-like. Pressing up accelerates through three gears with noticeably different pull; tapping down while moving brakes, and holding it once stopped reverses. Steering is sharp at low speed and much gentler at speed. The rear steps out easily, and the handbrake makes it slide further, with the effect building over about four seconds of holding it. Smashed-up cars lose top-end pull. Driving over an oil slick sends the car into a short uncontrolled spin. On steep 45° ramps a car with no brakes on rolls back down. On arrow-marked roads, a player car driving roughly along the lane is nudged straight when the player isn't steering.

## 2. Inputs

### Controls (player)

| Key | Meaning to the car |
|---|---|
| Up | "go forward" |
| Down | "go backward" |
| Left / Right | steer anticlockwise / clockwise. Both held together count as no steering. |
| Handbrake (shares the jump key) | handbrake |

How up and down become throttle, foot brake or reverse depends on how the car is moving (see Rules, step 1). A per-car "always accelerate" flag forces up on. The special key plus left/right turns a roof turret instead of steering, on cars that have one.

### `.gci` car record **[gci]**

The `.gci` file is text. Comments are in `{ }`. Whitespace and parentheses separate tokens. Each token is a number that becomes a fixed-size binary value, packed back to back:

- An optional leading `-`, then an optional type letter: `b` byte (the default when there is no letter), `w` 16-bit, `l` 32-bit, `f` decimal fraction. Then an optional `h` for hex (uppercase digits only), then an optional `-` that flips the sign again.
- `f` values are decimal with at most one `.`, and are stored as fixed point with 14 fractional bits.

Each car record is 72 bytes: four bytes, then 17 fractional (`f`) values, in this order:

1. model number (byte). Records are matched to style-file models by this number, not by their position.
2. turbo flag (byte, non-zero means the car has turbo)
3. value (byte, not used by handling)
4. unused padding byte (the file still has to supply it)
5. mass
6. front drive bias (share of engine force on the front wheels, 0–1)
7. front mass bias (share of mass in the front half, 0–1)
8. brake friction
9. turn in
10. turn ratio
11. rear end stability
12. handbrake slide value
13. thrust
14. max speed
15. anti-strength (used by damage, not handling)
16. skid threshold
17. gear 1 multiplier
18. gear 2 multiplier
19. gear 3 multiplier
20. gear 2 speed
21. gear 3 speed

Load-time checks: the number of records must equal the number of car models in the style file, or loading fails. For each model, gear 2 speed ≤ gear 3 speed ≤ max speed, or loading fails.

### Style file car info **[sty]**

From each car's entry in the `.sty` car info: sprite width and height in pixels, and the front and rear wheel offsets (signed pixels along the car's length). A pixel is 1/64 of a block.

## 3. Rules

### Units and conventions

- One tick is one game frame: 33 ms in single player, about 30 ticks per second **[exe]**. (Network games use a frame length agreed for the session. Fast-forward uses 11 ms.)
- Distance is measured in blocks (64 pixels). Speed is in blocks per tick. Accelerations are added straight to velocity once per tick, with no separate dt.
- Heading is stored in 1440 steps per full turn (quarter degrees). Angular velocity and steering angles are in radians. To turn radians into heading steps the game divides the 14-bit fixed-point radian value by 71. The exact factor would be about 71.5, so the car turns about 0.7% further than true radians would give. Reproduce this if you want turning circles to match.
- Car-local frame: +y points along the car's length towards the front wheels, and +x points across it. Rotating a vector by angle *a* gives `x' = x·cos a + y·sin a`, `y' = y·cos a − x·sin a`. "Anticlockwise" steering is the positive direction in this convention.
- The game does all of this in fixed point with 14 fractional bits. Floats are fine unless you need bit-identical replays.

### Values derived once per model at load

- **Mass:** `.gci` mass × 1.1. On top of that, a car with a player driver uses a further ×1.05 while driven **[exe]**. A car drawn at a non-default scale multiplies its mass by that scale.
- **Centre-of-mass offset and moment of inertia:** let *w* and *h* be the sprite width and length in blocks, *m* the mass and *b* the front mass bias. Model the car as two halves, each a uniform *w* × *h*/2 slab. The front half has mass *m·b* centred at +*h*/4, and the rear half has mass *m·(1−b)* centred at −*h*/4.
  - The centre of mass sits on the long axis at `y_c = (h/4)·(m_f − m_r)/m`.
  - Moment of inertia = Σ over both halves of `half_mass·(w² + (h/2)²)/12 + half_mass·(y_c − half_centre)²`.
  - The game uses the unadjusted `.gci` mass ×1.1 here, so the player and scale adjustments don't change inertia.
- **Wheel positions:** two points on the long axis at the front and rear wheel offsets **[sty]**. Each point stands in for an axle.
- **Thrust split:** `base_thrust = thrust/2`, `pedal_thrust = thrust/5`. The engine force formula is below.
- **Rear drive bias** = 1 − front drive bias.
- **Skid thresholds** = skid threshold × 0.9 and × 1.1. These are only used by the skid-mark and sound effects (separate note).

### Per-tick rules for a driven car on the ground

**1. Input interpretation.** Decide from the current velocity whether the car is moving "forwards": its direction of travel is within 90° of its heading.

- **Stopped** (velocity exactly zero): up means throttle, down means reverse, and there is no foot brake.
- **Moving forwards:** up means throttle and down means foot brake. If the car was in reverse last tick, all three are released for this tick instead.
- **Moving backwards:** down means reverse and up means foot brake. If the car was under forward throttle last tick, all three are released for this tick instead.
- The handbrake and steering direction are taken as pressed.

So changing direction always costs one tick with no drive. Combined with the "stopped means exactly zero" test, you must stop before up and down swap meaning.

**2. Gas pedal.** A pedal value runs from 0 to 5. While throttle or reverse is held it rises by 0.25 per tick, capped at 5 (full after 20 ticks). Otherwise it falls by 0.25 per tick to 0.

**3. Turbo.** Turbo is active when the model's turbo flag is set and the pedal is at 3 or more. While active, the pedal's contribution to engine force is doubled.

**4. Damage factor.** Car damage runs from 0 to 32000. Below 16000 the factor is 1. From 16000 up it is `(32001 − damage)/16000`, falling linearly to about 0 at full damage.

**5. Engine force** (zero if the engine is off or the car is in water).

- **Player-driven cars:**
  - Let `pull = base_thrust + pedal × pedal_thrust`, with the pedal term doubled under turbo.
  - **Reverse:** `−pull × gear 1 multiplier`.
  - **Forward:** pick the gear from current speed. Above gear 3 speed use gear 3, above gear 2 speed use gear 2, otherwise gear 1. Force = `pull × that gear's multiplier`, except that in gears 2 and 3 the pedal term is also scaled by the damage factor. Gear 1 and reverse ignore damage.
  - With the handbrake on and speed exactly zero, engine force is 0.
- **Non-player drivers:** no gears and no handbrake rule. Force = ±`(base_thrust + pedal × pedal_thrust × damage factor)`, with the pedal term doubled under turbo.

The engine force is split between the axles by the front and rear drive biases.

**6. Foot brake.** A brake pressure ramps from 0 by 0.25 per tick to a maximum of 1 while the foot brake is on, and resets to 0 the moment it's off (and always in water). `brake_force = pressure × brake friction` **[gci]**.

**7. Steering angle** (radians, signed by steering direction: +1 anticlockwise, −1 clockwise, 0 none).

- **Player-driven cars:** `angle = direction × turn_ratio × max(0.25, 0.6 − speed) / 0.48` **[exe constants 0.6, 0.25, 0.48]**. So the angle is turn_ratio × 1.25 when stopped and shrinks as speed rises, until it bottoms out at turn_ratio × 0.52 from speed 0.35 upward.
- **Non-player drivers:** `angle = direction × turn_ratio`, with no speed scaling.
- A truck cab with a trailer uses turn_ratio × 2.5.

**8. Tyre forces.** Each axle produces a force. Work out the velocity of the axle point (including the part due to rotation) and express it in that axle's own frame, which is the car heading turned by the axle's steering angle. Then:

- `lateral force = −lateral velocity × lateral grip`
- `longitudinal force = −longitudinal velocity × rolling drag + this axle's share of engine force`

Turn the force back into world space and apply it at the axle point. That adds to the car's total force and, through the lever arm from the centre of mass, to its torque. Tyre forces do **not** scale with mass, so heavier cars respond more sluggishly to the same grip and thrust.

| | Front axle | Rear axle |
|---|---|---|
| Axle angle | heading + steering angle | heading − steering angle × `(0.6 − speed)/2.28` **[exe]** |
| Lateral grip | 1, × (1 + turn in) while steering | 1, × (1 − turn in) while steering, × handbrake slide value while the handbrake is on |
| Rolling drag | 0.139 **[exe]** | 0.139 |
| Foot brake share | 0.8 × brake_force | 0.2 × brake_force |
| Handbrake | none | `brake friction × n/128`, where *n* counts ticks held, capped at 128. *n* resets to 0 when released. |
| Overall scale | none | the whole rear force vector × rear end stability **[gci]** |

So the rear axle counter-steers at low speed (it points slightly against the front wheels, which tightens the turn). Its contribution shrinks to nothing at speed 0.6 and reverses above that. *(Whether speeds above 0.6 occur in normal play depends on the `.gci` max speeds. [obs])*

The magnitude of each axle's lateral force is also kept as that axle's "skid amount" for the effects system.

**9. Steep-slope roll-back.** Applies when the car is on a slope that climbs a full level within one block (the 45° slope types, 41–44 in the `.gmp` slope numbering), neither brake is on, and the car is not a train. A constant force of 0.04 × mass **[exe]** pushes it in the downhill direction along the slope's axis. Gentler 2-block and 8-block slopes have no such push.

**10. Integrate velocity.** `linear acceleration = total force / mass` and `angular acceleration = −total torque / moment of inertia` (the minus sign matches the torque convention `torque = r_x·F_y − r_y·F_x` with the rotation rule above). Velocity and angular velocity each get their acceleration added. Then force and torque are cleared. Dead zones: if `|v_x| + |v_y| < 1/256`, velocity becomes exactly zero; if `|angular velocity| < 1/256`, it becomes exactly zero.

**11. Damping.** This step runs after integration. Express velocity in the car's frame and scale each part:

| | Lateral | Longitudinal | Angular |
|---|---|---|---|
| On the ground | × 0.9 | × 0.97 | × 0.88 |
| In the air | × 0.95 | × 0.985 | × 0.94 |

**[exe]** If both world velocity components are already ≤ 1/128, the whole velocity is scaled by the lateral factor instead, and angular velocity is not damped that tick.

**12. Speed cap** (ground only). The cap is the `.gci` max speed when moving forwards and the `.gci` gear 2 speed when moving backwards. If speed is over the cap, it is scaled down to the cap with direction unchanged. The cap does not include damage. Damage only slows a car through reduced pull in gears 2 and 3.

**13. Arrow snap (lane assist).** This applies when all of these hold:

- the car is player-driven or its AI permits it;
- the steering angle is exactly 0;
- the gas pedal is at least 2 for a player driver (no minimum for others);
- the car is moving forwards with non-zero velocity;
- it is not spinning on oil;
- the block directly under the car's centre, one level down, is a road block with direction arrows.

Then, if the arrows are along one axis and the heading is within 25° of either direction of that axis, compute the heading error to that exact direction. Clamp it to the car's max turn rate: `0.26 × speed`, or `0.13 × speed` for sprites longer than 64 pixels **[exe]**. Add it to angular velocity for this tick only (see Order of events), so the car's heading is pulled toward the lane by up to that much each tick.

**14. Movement.** Position advances by velocity and heading by angular velocity (converted as described under Units). Collision detection may shorten or replay this step (separate note).

### Oil slick

Hitting oil, for anything except trains, picks a random spin direction, sets a 30-tick timer and adds 30 damage. While the timer runs:

- An axle with no engine force on it exerts no force at all.
- An axle with engine force keeps normal grip, but the foot brake and handbrake have no effect on it, and its angle is offset by 30°. The front is offset one way and the rear the other way, by the chosen direction.

The timer counts down once per tick.

### Coasting

The game has a "coast" input state, set by game logic rather than the player's keys, in which both axles exert no tyre force at all. The car then slides on damping alone. *(Who sets it is an open question.)*

## 4. Order of events (one tick, driven car on the ground)

1. Clear any conveyor-belt velocity contribution from last tick.
2. Resolve car-versus-car (and trailer) contacts.
3. Non-player cars only: apply any forced steering. Then apply trailer control limits.
4. Compute the steering angle.
5. Work out the damage factor, then update the gas pedal and brake pressure.
6. Front axle force, then rear axle force.
7. Slope roll-back force.
8. Integrate velocity, clear accumulators, apply dead zones.
9. Damping.
10. Speed cap.
11. Add any conveyor-belt velocity.
12. Arrow snap (adds to angular velocity).
13. Scare pedestrians if the car is fast on pavement (separate note), and count down the oil-spin timer.
14. Move and resolve world collisions.
15. Skid-mark effects.
16. Subtract the conveyor velocity and the arrow-snap angular velocity again, so neither persists into the next tick.

A car whose physics has just been created or woken skips some of these on its first tick and then joins this sequence.

## 5. Numbers

| Value | Meaning | Source |
|---|---|---|
| 33 ms (≈30 ticks/s) | single-player tick length | [exe] |
| 64 px = 1 block | distance unit | [sty] format |
| 1440 | heading steps per turn | [exe] |
| 0 – 5, ±0.25/tick | gas pedal range and slew | [exe] |
| ≥ 3 | pedal level where turbo engages | [exe] |
| 0 – 1, +0.25/tick | foot-brake pressure | [exe] |
| 128 ticks | handbrake ramp to full | [exe] |
| 16000 / 32000 | damage where pull starts dropping / maximum damage | [exe] |
| ×1.1, ×1.05 | load-time mass scale; extra scale with a player driver | [exe] |
| 30 ticks, 30 damage, 30° | oil spin duration, damage, axle offset | [exe] |
| 25° | arrow-snap capture window | [exe] |

The other constants are given inline above, each tagged [exe].

## 6. Edge cases and quirks worth reproducing

- **One-tick neutral when reversing direction.** You have to come to an exact stop before down switches from brake to reverse. The velocity dead zone is what makes "exact stop" reachable.
- **Handbrake at standstill holds the car.** A player car with the handbrake on and zero speed makes no engine force, so holding handbrake and gas does not creep.
- **Reverse is capped at gear 2 speed** and never shifts gear.
- **Damage only hurts gears 2–3.** A wrecked car still launches normally from rest, then struggles to gain speed.
- **Rear steer reverses above speed 0.6.** See the rear axle in step 8.
- **The arrow snap is a one-tick nudge, not a lasting spin.** With debug instruments on, the real game prints "snap" when it fires. That is a good way to check your capture window.
- **Heavier is slipperier.** Tyre forces ignore mass, so high-mass vehicles drift more and accelerate less from the same `.gci` grip and thrust. This is part of why buses and trucks feel so different.
- **Player cars are 5% heavier than the same model under AI.**
- **Turning over-rotates by ≈0.7%.** See Units.

## 7. Open questions

- Which game events set the "coast" state (scripts, a driver getting out, or something else)?
- Absolute heading convention: which world direction heading 0 faces, and which way +y points on screen. This belongs with the sprite and map notes, and the arrow-snap directions depend on it.
- Typical `.gci` max speeds, to confirm whether the "above 0.6" behaviours ever occur in normal play. The implementer can read this directly from their data.
- Exactly when the arrow snap is permitted for AI cars (it depends on an AI state flag that will be covered in the AI driving note).
- What a parked car with no driver does each tick. Its physics appears to go to sleep after 20 ticks of exact stillness; to be covered in the collision/physics-lifecycle note.
