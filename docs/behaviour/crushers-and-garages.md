# Car crushers and scripted garages (first pass)

- **System:** The car crusher sequence (four pistons squeeze a car flat and destroy it) and the scripted "park the car in the garage" mechanism (a car driven to a garage door is taken over and pushed inside). Cranes, which drop cars into crushers, are only outlined here.
- **Builds on:** `explosions-and-damage.md` (car explosion), `car-height.md` (sprite shrink), `wanted-level.md` (crushed cars aren't reported).
- **Sources read:** the decompilation's crusher state machine and setup, and an outline of the garage parking service.
- **Date and author:** 2026-11-19, Claude (notes writer, reader side).

Tags: **[scr]** set up by the mission script, **[exe]** fixed in the executable, **[obs]** to confirm in play.

---

## 1. What the player sees

A crusher is a square pit with four piston blocks. Drop a car on its centre and the side pistons slam in, the car explodes and is squashed thin, then the front and back pistons squash it short. What's left is a crushed wreck. A scripted garage swallows a car you drive up to its door: the car is lined up and pushed inside, and the door closes.

## 2. Inputs

- **Crusher placement [scr]:** a centre point; the pistons and bases are placed around it.
- **Garage placement [scr]:** a door, its facing side, and the car (or model) it accepts.

## 3. Rules

### 3.1 Crusher layout

Four pistons sit 0.9375 block from the centre (north, east, south, west) when open, with base blocks further out at 1.125 block **[exe]**. A marker object sits at the centre.

### 3.2 Crushing a car

A car touching the centre marker is crushed if the crusher is idle and the car isn't already despawning, shrunk or crushed. The car is set to ignore collisions. Each tick, while active, a car that was about to despawn is kept alive. Then:

1. **Squeeze sideways.** The east and west pistons close by 1/64 block per tick, from 0.9375 to 0.5625 from the centre **[exe]**.
   - Once the piston gap minus 0.4375 is no more than half the car's width, the car's sprite and collision width shrink by 2 pixels per tick.
   - When the pistons are fully closed, the car explodes as a car explosion. If the local player is credited, the kill goes to him with cause "explosion".
2. **Open sideways** at the same rate.
3. **Squeeze lengthways** with the north and south pistons. The car's length shrinks the same way. When fully closed, the car's engine is marked crushed.
4. **Open lengthways.** The crusher becomes idle and the car is left as a crushed wreck.

Cars destroyed while being crushed don't generate crime reports (`wanted-level.md`).

### 3.3 Scripted garage parking (outline)

- **Waiting:** watching for an accepted car to arrive at the door, the right way round.
- **Pushing:** the car is lined up with the door, along the door side's axis, and pushed in at a fixed rate. The player can't control it.
- **Finished:** the car is parked and the script is told. While a car is being parked, peds can't enter it (`entering-and-exiting-cars.md`).

*(Speeds, alignment tolerances and door timing are still to be read. [obs])*

### 3.4 Cranes (outline)

Cranes swing a hook in angle and radius toward a target and lower it by depth. Each axis uses the same "accelerate toward target, capped speed, stop exactly" rule as the camera (`camera.md` 3.4). They pick up cars by the hook and can drop them, for example into a crusher. *(Details to follow in a cranes note.)*

## 4. Numbers

| Value | Meaning | Source |
|---|---|---|
| 0.9375 / 0.5625 | piston open and closed distance from the centre | [exe] |
| 1.125 | piston base distance | [exe] |
| 1/64 per tick | piston speed | [exe] |
| 0.4375 | piston face offset used for the shrink test | [exe] |
| 2 px per tick | crushed sprite shrink | [exe] |

## 5. Open questions

- The garage parking speeds and alignment rules, and what happens if the player gets out mid-push.
- How cranes grab and release cars, and their speeds.
- How the crushed wreck is scored (if at all) and when it despawns.
