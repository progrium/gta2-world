# Pedestrian movement and on-foot control

- **System:** How a person on foot (the player, or anyone else) moves each tick: the player's turn, forward and back, and jump controls, walking speed, sliding along walls, slopes and height, stepping off ledges and falling (including lethal falls), drowning, electrified floors, and being knocked down by a car.
- **Out of scope (separate notes):** how AI peds choose where to go (ped AI note); entering and leaving cars; weapons and being shot; burning.
- **Builds on:** `car-handling.md` (units, ticks, angles), `shape-and-map-collision.md` (map data), `car-collision.md` (the knock-back a car hands a ped).
- **Sources read:** the decompilation's player on-foot input handling, the pedestrian movement states (walking, falling, knocked down), its tile-step and wall-slide rules, slope height handling, jump handling, and the reaction to being hit by a car.
- **Date and author:** 2026-11-19, Claude (notes writer, reader side).

Tags: **[gmp]** map file, **[sty]** style file, **[exe]** fixed in the executable, **[obs]** to confirm in play.

---

## 1. What the player sees

The player character always moves at one steady running pace. Left and right spin him on the spot, with the turn picking up speed while the key is held. Down makes him back-pedal at the same pace without turning round. Jump is a short hop with reduced steering. Running into a wall makes him slide along it at half speed. Running off a ledge makes him fall in an arc; a short fall is survived, a long one kills. Walking into deep water drowns him. Electrified floor tiles hurt while he stands on them, unless he's mid-jump. A car hit throws people through the air: light taps knock them down, and harder hits kill outright.

## 2. Inputs

### Controls (player on foot)

| Key | Effect |
|---|---|
| Up | move forward |
| Down | move backward (same speed, facing kept) |
| Left / Right | turn anticlockwise / clockwise, building up speed |
| Jump (shares the handbrake key) | jump, on a fresh press only, and not while already jumping or just after leaving a vehicle |
| Attack held without Up | faster turn build-up (aiming) |
| Special (without attack) | taunt/voice line |

Pressing any movement or turn key cancels a pending "walk to a car and get in" order.

### Data

- **Map [gmp]:** block ground types (air, road, pavement, field), slope types, lid tiles.
- **Style [sty]:** which lid tiles are deep water and which are electrified floor.

## 3. Rules

### 3.1 Turning (player)

The player has a turn speed, in heading steps per tick (1440 steps per turn).

- **Normal:** each tick a turn key is held, the turn speed changes by 11 steps toward that direction, up to a maximum of 48 steps (12°) per tick. With attack held and Up not held, the step is 12 instead of 11.
- **Mid-jump:** the step is 4 and the maximum is 24.
- **No turn key:** the turn speed resets to 0 at once.

The heading changes by the turn speed every tick. Turning is independent of moving, so he turns on the spot.

### 3.2 Speed

- Every ped has a target speed. For ordinary peds and the player it is **1/16 block per tick** (≈1.9 blocks per second) **[exe]**. Gang members following a leader use 5/64.
- **Moving and standing:** when the ped starts moving from rest, speed jumps straight to the target. After that it creeps toward the target by 1/256 per tick if it is above or below. When the player releases Up and Down, speed drops to zero at once.
- **Backing up:** the ped is turned 180° for the step only, then his facing is restored. Backing up is exactly as fast as running forward.
- **Push-back:** after being bumped (by another ped or an attacker), the ped is pushed at 1/32 per tick in the bump direction for a short timer, overriding the controls.
- **Conveyor belts** add their own offset each tick.

### 3.3 Walls and tiles

Peds don't use the car's rectangle test against walls. They move tile by tile.

1. **Look ahead:** probe a point 3/32 block ahead of the ped in his direction of travel **[exe]**.
2. **Can he step into that tile?** This uses the same wall faces, ramp and level rules as cars (`shape-and-map-collision.md`), plus a ground check. If yes, he moves the full step.
3. **If not (the player):** he slides. The game tries a step along one map axis, then the other. The order is chosen from his heading and the side of the tile that's blocked. The first axis that's free is used, at **half speed**.
4. **If not (AI peds):** they turn to face the nearest free side and pick a new heading (ped AI note).
5. **Veering:** AI peds walking close to a wall on one side get a gentle nudge away from it. The player doesn't.

Near the very centre of a tile the look-ahead check is skipped, and the ped just moves.

### 3.4 Height on the ground

After each step, the ped's height is set from the ground under him. On a ramp it follows the ramp surface. When he steps off a ramp onto flat ground, his height is rounded to the nearest whole level, rounding up from exactly half. On flat ground it is the level he's on.

### 3.5 Stepping off an edge and falling

When he isn't jumping and the block under his look-ahead point is open air, he starts falling.

- **Start:** he keeps his current horizontal speed in the direction he was moving (backwards if he was backing up), with vertical speed 0.
- **Each tick** of the fall:
  - he moves horizontally if the tile ahead allows it;
  - vertical speed grows by 0.01 per tick up to 0.1 per tick **[exe]**, and his height drops by it;
  - horizontal speed above 1 drops by 0.2 per tick. Ordinary running speed is far below 1, so in practice it stays constant.
- **Landing:** when he is within 1/8 block above the ground below him, he lands at ground height.
- **Fall damage:** while falling, the fall animation advances one frame every few ticks.
  - Its 12th and 13th frames each deal 4 damage.
  - Once it reaches frame 14, the fall is **lethal**: he dies on landing, unless he's temporarily invulnerable.
  - If he lands lethally on top of something (a car, say), he's thrown off it and dies as he lands.
  - A non-lethal landing on top of something turns into a jump off it.
- A ped who is mid-jump only starts falling once the jump's own animation finishes.

### 3.6 Jumping

- A jump sets speed to the run speed and plays an 8-frame jump animation **[exe]**. During it, the sprite is drawn slightly larger to suggest height. This is visual only; the ped stays at his height.
- **Holding Up** during the jump keeps him moving at his target speed. **Without Up** he still moves at run speed in his facing direction, so a jump always carries him forward.
- **Landing frame:** his height is set to the ground under him, but never below the level he jumped from. He can jump across a gap onto the same level but not drop into it mid-jump.

### 3.7 Water and electrified floors

- **Deep water** (remapped water lid under him) drowns him: any fire is put out, a splash plays, and he switches to sinking. Whoever last hurt him within the last 50 ticks is credited with a drowning kill.
- **Electrified floor tiles [sty]:** standing on one adds 3 to his shock counter each tick (ped damage note), except while jumping or in the moment after leaving a vehicle. A recent attacker is credited with an electrocution kill.

### 3.8 Being hit by a car

`car-collision.md` hands the ped a knock-back vector. Let `k` be its length, raised to at least 1/16.

| Knock-back `k` | Outcome |
|---|---|
| any, ped is temporarily invulnerable | hops (a jump) instead |
| < 0.1 | knocked over and slides along the ground. If he was already lying down, he dies. |
| ≥ 0.1, ordinary background ped | killed outright, with a blood burst |
| 0.1 – 0.2, anyone else | thrown into the air at half the knock-back speed, rising at 0.05. Ends up lying injured, or killed if a player was driving. |
| 0.2 – 0.3, the player hit by a non-player car | thrown at half speed, rising at 0.1, ends up knocked down. If already lying down, he dies. |
| 0.2 – 0.3, anyone else | killed |
| ≥ 0.3 | killed (an invulnerable ped is thrown instead) |

All thresholds are **[exe]**. Other details:

- **AI driver stops:** a calm AI driver of an ordinary car stops for 100 ticks after hitting someone.
- **The thrown ped** travels as a moving object. When that object stops, a knocked-over ped gets up, a knocked-down ped lies on the floor, and a fatally hit one dies. If the object is removed first, he dies.

### 3.9 Collision box

A ped is a 0.2 × 0.2 block square, 0.25 block tall **[exe]**.

## 4. Order of events (one ped, one tick)

1. If teleported (scripted), just place him and skip the rest.
2. Find the block under him. Apply electrified floor; if it's water, drown and stop.
3. If the block ahead is open air and he isn't jumping, start falling (3.5) and stop.
4. Player: apply turn speed, then set speed from Up/Down (3.2). AI peds: their state decides.
5. Look ahead and either step, slide or turn (3.3).
6. Update height from the ground (3.4).
7. Handle any sprite he's now touching (ped AI note).
8. Advance the animation, including jump and fall effects (3.5–3.6).
9. Set his velocity vector from his speed and heading, for other systems to read.

## 5. Numbers

| Value | Meaning | Source |
|---|---|---|
| 1/16 block/tick | run speed (player and most peds) | [exe] |
| 5/64 | gang follower speed | [exe] |
| 1/256 per tick | speed creep toward target | [exe] |
| 1/32 | push-back speed after a bump | [exe] |
| 11 (12 aiming), max 48 | turn build-up and cap, heading steps per tick | [exe] |
| 4, max 24 | turn build-up and cap mid-jump | [exe] |
| 3/32 block | look-ahead distance | [exe] |
| ½ | wall-slide speed factor | [exe] |
| +0.01 to 0.1 per tick | fall speed build-up and cap | [exe] |
| 1/8 block | landing tolerance | [exe] |
| 4, frame 14 | fall damage per late frame; lethal-fall frame | [exe] |
| 0.1 / 0.2 / 0.3 | car knock-back thresholds | [exe] |
| 0.2 × 0.2 × 0.25 | ped collision box | [exe] |

## 6. Edge cases and quirks worth reproducing

- **No walking for the player:** always full pace, and backing up is just as fast.
- **Jumping always moves you forward,** even with no direction held.
- **Jumps can't drop you.** Landing never goes below the take-off level.
- **Fall horizontal speed doesn't decay at normal speeds.** Peds fall in straight lines out from the ledge.
- **Lethal falls are decided by time in the air** (animation frames), not by measured height. *(Time how long a fall takes to become lethal in the real game. [obs])*
- **Ordinary peds die to any real hit;** the player and named peds get knocked about instead.

## 7. Open questions

- The exact tick length of each fall-animation frame. It depends on a frame-delay rule in the animation system, which will go in an animation note.
- How AI peds steer around obstacles and each other (ped AI note).
- The shock counter's effect and threshold (ped damage note).
