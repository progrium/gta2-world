# Camera

- **System:** Where the top-down camera points and how high it sits: following the player on foot or in a car, pulling back with speed, leading ahead of a fast car, tightening during police chases, smooth motion, shake from explosions, and the limits on height.
- **Builds on:** `car-handling.md` (units), `explosions-and-damage.md` (shake source), `wanted-level.md` (chases).
- **Sources read:** the decompilation's camera follow logic for peds and cars, the speed-based offset, the "suspicion" tightening, the smoothing helper, shake, and the pan offsets.
- **Date and author:** 2026-11-19, Claude (notes writer, reader side).

Tags: **[exe]** fixed in the executable, **[obs]** to confirm in play.

---

## 1. What the player sees

The camera looks straight down at the player. On foot it sits fairly close. In a car it rises as the car speeds up, showing more of the city, and slides ahead in the direction of travel, further when travelling north–south than east–west (the screen is wider than tall). During a police chase the lead-ahead shrinks so the action stays central. Explosions shake the view. Camera moves are smooth and never jump, except on teleports.

## 2. Inputs

- **Subject:** the player ped, or the car he's in or getting into or out of.
- **Car velocity, heading, height,** and whether it's a train, tank or truck cab.
- **Whether the subject's driver is being chased** (police or a chase task).
- **Screen size** (for the lead distance).

## 3. Rules

### 3.1 Camera state

The camera has a position `(x, y)`, a height `z`, and a zoom. A higher `z` means a wider view. It also keeps a velocity for each of the four, used for smoothing.

### 3.2 Target each tick

**On foot** (or dead):

- Target `x, y` = the ped's position. Target `z` = the ped's height − 2, but at least 1.
- Zoom is the default, about 0.887 **[exe]**. While the ped is dead it's about 3.55.

**In a car**, or while getting in or out (the car is used instead of the ped):

- Target `x, y` = the car's position. Target `z` = the car's height − 2, but at least 1. Zoom is the default.
- Let `s` = 16 × the car's speed (a fixed 8 for trains).
- **Speed lift:** if `s > 1.5`, add `s` to the target `z`. A car at 0.1 blocks/tick lifts the camera by 1.6 levels.
- **Lead-ahead** (not trains or tanks):
  - Base distance: 240 if the car is travelling mostly north or south (direction of travel between 45°–135° or 225°–315° from the reference axis), otherwise 180 **[exe]**. A truck cab with a trailer uses ¾ of that.
  - **Suspicion** (3.3) shortens it to `distance × (1 − min(suspicion, 64) / 128)`, so at most by half.
  - The lead in world units is `distance × (8 − car height + target z) / screen scale`, in the car's direction of travel. It grows with how high the camera is and shrinks on bigger screens.

The target `z` is always clamped to 0–14 **[exe]**.

### 3.3 Suspicion

A counter from 0 to 80 **[exe]**. It rises by 1 each tick the followed car's driver is being actively chased (by police or a chase task) and falls by 1 each tick he isn't. It reaches its full effect at 64.

### 3.4 Smooth movement

In the normal mode, each of `x`, `y` and zoom approaches its target like this:

- If the target is ahead and the camera is already moving toward it, its speed grows by a fixed step per tick, up to a cap. If the next step would overshoot, it moves exactly onto the target.
- If it's moving away from the target, its speed drops to 0 at once.

| Quantity | Speed step per tick | Speed cap |
|---|---|---|
| `x`, `y` | 1/64 | current camera `z` × 3/16 |
| zoom | 1/64 | 1/16 |

**Height** `z` uses its own, slower rule:

- rising: step 1/128, cap 5/8 per tick;
- falling: step 1/640, cap 5/64 per tick.

The camera climbs quickly as you speed up and sinks slowly as you slow down. *(Which of the two pairs of values is for rising and which for falling should be confirmed by watching the camera after a fast stop. [obs])*

A **snap** mode (used for teleports and cutscenes) sets the position to the target at once.

The target set during one tick is used on the next, so the camera lags its subject by one tick.

### 3.5 Shake

An explosion sets a shake of `strength × 1/64` (strength 8, so 1/8, for normal explosions). Every tick the shake value is added to `x`, `y` and `z` (with `z` kept ≥ 0), then the value is negated and multiplied by 0.75. The view rattles and dies away within a few dozen ticks.

### 3.6 Elevation and panning

- **Elevation:** a separate target offset that can be raised or lowered in steps of 0.5, between 0 and 20. Its user (debug controls or scripts) isn't traced yet.
- **Panning:** a screen-space look offset driven by direction keys.
  - Each key held moves it, starting at 5 per tick and accelerating by 5 per tick up to 20.
  - It's limited to ±300 horizontally and ±220 vertically, in screen units.
  - Releasing a key resets that direction's speed.
  - Where this is enabled (a free-look or debug mode) isn't traced yet.

## 4. Order of events (per tick, after the world update)

1. Remember the current position (for things that track camera motion).
2. Build the new target from the subject (3.2), updating suspicion (3.3).
3. Move toward the previous tick's target (3.4), or snap.
4. Apply shake (3.5).
5. Recompute the visible area (used for despawning, sound and "on screen" tests).

## 5. Numbers

| Value | Meaning | Source |
|---|---|---|
| −2, min 1 | camera height relative to the subject | [exe] |
| ≈0.887 / ≈3.55 | default zoom / zoom when dead | [exe] |
| 16, 1.5 | speed scale and threshold for lift | [exe] |
| 240 / 180, ×¾ | lead distance north–south / east–west, trailer cab factor | [exe] |
| 0–80, 64, ½ | suspicion range, full-effect point, maximum reduction | [exe] |
| 0–14 | camera height limits | [exe] |
| 1/64, z × 3/16 | x/y smoothing step and cap | [exe] |
| 1/128, 5/8, 1/640, 5/64 | height smoothing steps and caps | [exe] |
| ×−0.75 per tick | shake decay | [exe] |

## 6. Edge cases and quirks worth reproducing

- **Direction-dependent lead.** North–south travel shows more road ahead than east–west, to suit a 4:3 screen.
- **Trains always lift the camera** as if moving fast, even when stopped.
- **The camera follows the car while you're getting in or out,** not the walking ped.
- **The one-tick target lag** is visible as the subject being slightly off-centre at speed.

## 7. Open questions

- What raises or lowers the elevation offset, and when panning is active.
- The exact reference axis for the 45°/135° split, which follows the heading convention still open in `car-handling.md`.
- How zoom is converted into screen scale by the renderer (rendering note).
