# Behaviour notes: index

Clean-room behaviour notes for the GTA2 engine rewrite. Each file follows the brief: what the player sees, inputs, rules, order of events, numbers (tagged by source), quirks, open questions.

## Written (2026-11-19)

| File | Covers | Status |
|---|---|---|
| car-handling.md | throttle, gears, grip, brakes, steering, damping, speed caps, oil, arrow snap, `.gci` format | full |
| car-collision.md | sub-stepping, impulses, damage, crushing, unstick nudge | full |
| shape-and-map-collision.md | collision boxes, wall faces, slopes, diagonal walls, sprite overlap | full |
| car-height.md | ground following, ramps, jumps, gravity, water, sinking, physics sleep | full |
| map-geometry.md | ground height and ramp profiles per slope type | full |
| ped-movement.md | on-foot controls, speed, wall slide, falling, jumping, car hits | full |
| entering-and-exiting-cars.md | choosing a car, doors, carjacking, exiting | mostly; door usability open |
| weapons.md | firing, ammo, throwing, electro gun, vehicle weapons | full |
| projectiles.md | projectile speed and range, hit damage to peds and cars | mostly; grenade bounce open |
| explosions-and-damage.md | explosions, car destruction stages, ped health and shock | full |
| wanted-level.md | wanted points and stars, crime reports, police response tiers | mostly; cop AI separate |
| power-ups-death-and-arrest.md | power-ups, wasted, busted, respawn | full |
| gangs-and-respect.md | respect arithmetic, kill reactions, gang weapons | full |
| scoring.md | kill and car scores, combos, multiplier | full (one short table flagged) |
| camera.md | follow, speed lift, lead-ahead, smoothing, shake | full |
| traffic-and-car-ai.md | AI speed control, look-ahead, halting, junction turns and lane centring, reverse-out-of-trouble, traffic lights, chase/follow/patrol task driving | mostly; two behaviour-intent questions open |
| crushers-and-garages.md | crusher sequence; garages and cranes outlined | first pass |
| mission-scripts.md | `.scr` file format, declarations, thread execution, triggers | machinery only |
| script-declarations.md | Script command reference: the level-start declaration pass (player ped, cars, characters, objects, map zones, arrows, cranes, conveyors/generators/destructors/crushers, doors, triggers, gang info, lights, trains, radio, police level, sound points, mission bookkeeping) | full |
| script-cars.md | Script command reference: runtime car commands (creation, AI control handoff, send-to-point, driver/passenger assignment, trailers, protective/cosmetic flags, car bombs and explosions, car-state conditions) | full |
| script-characters.md | Script command reference: runtime character commands (creation, objective assignment, weapons, health/invincibility/death/arrest, gang and group membership, threat-search/reaction and driving-style tuning, combat memory, ped-state conditions) | full |
| script-objects.md | Script command reference: runtime object commands (creation, removal and forced cleanup, generator activation and power-up decision, object-state conditions, door open/close/auto/manual and door-target updates, phone ring/answer/timeout/dead-phone, object-target explosions) | full |
| script-player.md | Script command reference: runtime player commands (score/cash with and without the multiplier, multiplier and lives read/change, wanted-level set/clear/raise/cap, player control locks, death/arrest-on-last-mission query, gang-respect snapshot/restore) | mostly; a few commands' consumers open |
| script-flow-control.md | Script command reference: thread flow control (the IF condition combinator and its "not," GOTO's no-opcode mechanism, GOSUB/RETURN, EXEC and WHILE_EXEC blocks, wait/delay, starting and stopping threads, thread-level flags) | mostly; several declared command types found dead, thread-flags field's purpose open |
| script-messages.md | Script command reference: on-screen text commands (one-line banner message, queued talking-head "brief" help/status text and its clear/query commands, countdown-timer display, on-screen counter display, and the shared text-table lookup behind them) | mostly; a couple of edge cases open |
| script-counters.md | Script command reference: counter variables (declaring one, setting its value, incrementing/decrementing, arithmetic against a literal or another counter, comparing a counter and feeding the condition result, save-game persistence) | mostly; a couple of edge cases open |
| script-missions.md | Script command reference: mission-level commands (starting a mission directly or through a gang's phone-respect gate, ending a mission and its cleanup pass, the timed bonus-challenge mechanism, the kill-frenzy weapon template built on it) | mostly; a couple of edge cases and one unclaimed command open |
| ped-ai.md | objectives, threat detection, fleeing, fighting, following, group formation and recruiting, gang attack/ignore decision, electro-fingers, invisibility | mostly; a few behaviour flags open |
| police-ai.md | crew dispatch and driving, car chase box-in/ram maneuver, roadblocks, searching, on-foot arrest trigger, SWAT/FBI/army specifics | mostly; a note conflict and a few numbers open |

## Still to write

In rough priority order:

1. **Spawning:** traffic and ped generators, density by zone, despawning.
2. **Objects:** pickups, physics objects, grenade bounce, mines, doors, phones.
3. **Fire:** burning peds and cars, fire spread, burning-car explosion.
4. **Public transport:** trains, buses.
5. **Emergency services:** ambulances, fire trucks.
6. **Cranes.**
7. **Skid marks, tyre smoke and particles.**
8. **HUD:** messages, arrows, pager, weapon and score display.
9. **Animation timing:** ped frame delays (several notes depend on it).
10. **Save games, audio cues and rendering:** lower priority for gameplay.

**Script command reference: done.** All families written: `script-declarations.md`, `script-cars.md`, `script-characters.md`, `script-objects.md`, `script-player.md`, `script-flow-control.md`, `script-messages.md`, `script-counters.md`, `script-missions.md`.

## Cross-cutting open questions

- **Absolute heading convention:** which way heading 0 faces. Several notes depend on it.
- **Animation frame timing:** fall damage and jumps depend on it.
