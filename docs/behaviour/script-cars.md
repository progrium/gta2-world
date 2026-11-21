# Script command reference: cars (runtime)

- **System:** The runtime script commands that create and control cars during a mission thread — everything a script can do to a car *after* the level-start declaration pass, as opposed to the one-shot car declarations (`script-declarations.md` §2.2, command types 10/11/12/13 and the parked-car forms 425/426/427/428). Covers: creating a car mid-mission, handing a car to AI control or sending it to a point, assigning or removing a driver and passengers, trailers, protective flags, remap/graphic/siren changes, car-bomb and explosion commands, and the condition commands scripts use to test a car's state.
- **Out of scope:** the physics, AI driving, collision and destruction behaviour these commands trigger (`car-handling.md`, `traffic-and-car-ai.md`, `car-collision.md`, `explosions-and-damage.md`, `entering-and-exiting-cars.md` already cover those) — this note is only each command's own parameters and immediate effect. Also out of scope, and left for other command-family notes: zone car-density settings (type numbers in the same block as the map-zone-settings declaration, §2.5 of `script-declarations.md`; belongs with the not-yet-written spawning note); the scripted garage-parking commands (outlined in `crushers-and-garages.md` §3.3); a car-model-to-power-up decision command (belongs with the objects/power-ups note); and every command whose primary subject is a character rather than a car — a ped's "is in a car" / "is in any car" / "is in a car of model X" tests, the two ped behaviour flags that affect how a ped uses a car ("stay inside," "use the car's mounted weapon"), a ped's favourite-car-model setting, and the generic "has this ped arrived in a rectangle, optionally in a car" trigger family — even though several of these are tested through a car. Those belong with the characters family note.
- **Builds on:** `mission-scripts.md` (file format, thread/tick model, "looked up by command number" convention). Cross-referenced throughout: `car-handling.md`, `car-collision.md`, `traffic-and-car-ai.md`, `entering-and-exiting-cars.md`, `explosions-and-damage.md`, `script-declarations.md`.
- **Sources read:** the decompilation's per-tick script-command dispatch and every handler it routes to for car creation, handing a car to AI control, sending a car to a block, driver/passenger assignment, trailer attachment, protective and cosmetic flags, car-bomb/explosion handling, and the car-state condition tests; the route-finder call that starts a car's drive-to-block task; and the player-input function that reads the "jammed throttle" flag.
- **Date and author:** 2026-11-20, Claude (notes writer, reader side).

Tags: **[scr]** the compiled script file format, **[exe]** fixed in the executable, **[obs]** to confirm in play.

---

## 1. What the player sees

Nothing here is its own visible event; it's the machinery behind things the player does notice mid-mission: a car appearing out of nowhere partway through a job, a getaway car that suddenly drives itself away, a car that won't budge until you deal with it, a rival's car bursting into flames on command, a trailer appearing already hooked to a truck, a car that's suddenly bulletproof, or a parked car whose alarm goes off the moment anyone touches it. Scripts also use these commands silently, every tick, to check whether a mission car has been wrecked, has a driver, is underwater, is in the air, is being crushed, has a car bomb planted, or has been hit by a particular weapon — the conditions that drive IF-style branches in a mission thread.

## 2. Inputs: the runtime car commands [scr]

These commands run like any other script command (`mission-scripts.md` §3.2): one per tick, in thread order, as the thread's current command. The "looked up by command number" convention from `script-declarations.md` §2 still applies — a command that names "an earlier-declared car" means the handle created by whatever earlier command (declaration or runtime) was given that command number.

### 2.1 Creating or acquiring a car

| Type | Parameters | Effect |
|---|---|---|
| 43 / 44 / 45 / 46 | position (2D/3D, plain/named), heading, remap, car model, trailer model | Creates a car, exactly like the level-start car declaration (`script-declarations.md` §2.2) — same parameter shapes, same effect on the car itself. The only differences are *when* it runs (this line, this tick, instead of the one-shot pass) and that the new car is added to the mission's cleanup list, so it's removed automatically if the mission ends (unless this command happens to run during the level-start pass itself). |
| 394 / 395 / 396 / 397 | same as above | The same creation, for one of up to four gangs' own car models/colours in place of the explicit model/remap given. |
| 188 | an earlier-declared crane | Takes whatever car is currently sitting on that crane's hook (if any) and stores a handle to it. The condition result is true if a car was found. What put a car on the crane in the first place is the (not yet written) cranes note. |

### 2.2 Handing a car to AI control

| Type | Parameters | Effect |
|---|---|---|
| 100 | an earlier-declared car | If the car has no driver, spawns one for it; either way, switches the car to ordinary AI driving control (`traffic-and-car-ai.md`) and marks its driver as script-created. |
| 175 | an earlier-declared car | Switches the car to ordinary AI driving control. Unlike 100, it doesn't check for or spawn a driver first — it assumes one is already there (for example a car the player has just got out of). |
| 170 | an earlier-declared car | Like 100 (spawns a driver if needed, switches to AI control, marks the driver script-created), but also immediately halts the car under AI braking (`traffic-and-car-ai.md` §3.3), so it sits there running rather than driving off. |
| 169 | an earlier-declared car, a block position (column, row, level) | Gives the car's AI a destination: it starts a route to that map block and drives there (`traffic-and-car-ai.md`'s road-following applies once it's moving). The command's position fields are plain block coordinates here, not the 2D/3D world-position-with-ground-sentinel shape the same-shaped creation command uses. |
| 368 | an earlier-declared character | Halts, under AI braking, whichever car that character is currently in (looked up through the character, not the car). Has no effect if the character isn't in a car. |
| 374 | an earlier-declared car, on/off | Toggles the car's "always accelerate" flag — the same per-car flag `car-handling.md` §2 already documents as forcing the throttle on regardless of player input. Setting it on a player's car locks the gas pedal down; the player can still brake, steer and reverse. |

### 2.3 Driver and passengers

| Type | Parameters | Effect |
|---|---|---|
| 167 | an earlier-declared character, an earlier-declared car | Gives the character the objective of entering that car as its driver (the same objective the player's enter key sets — `entering-and-exiting-cars.md` §3.1–3.3 — so it plays out over several ticks: walk to the door, carjack if occupied, get in). |
| 171 | same as 167 | The same, except the character is placed straight through the car's back door, skipping the walk-to-door approach and door-choice logic. |
| 166 | an earlier-declared character | Gives the character (if currently in a car) the objective of leaving whichever car that is (`entering-and-exiting-cars.md` §3.5). |
| 330 | an earlier-declared character slot, an earlier-declared car, a remap, an occupation | Creates a new script-controlled ped already seated in that car (as opposed to 167's "walk over and get in" — this one spawns directly inside), and makes sure the car has its own AI controller object set up so it can be driven. |
| 254 | an earlier-declared character (a group leader) | True if that character (or, if it leads a ped group, every member of the group) is currently in some car. |
| 253 | an earlier-declared car | Kills every passenger in the car (not the driver). If the car is a bus, this instead kills every passenger on every bus in the level, not just this one. |

**Dead command:** a command type exists for "remove a character from this car's group-in-car bookkeeping" but has no handler at all in the decompilation — it can't do anything if a script calls it. See Open questions.

### 2.4 Trailers

| Type | Parameters | Effect |
|---|---|---|
| 316 | an earlier-declared car, an earlier-declared trailer car | Visually attaches the trailer car to the first car's hitch point (or, if the first car is itself a truck cab, to the cab's own trailer point) — the same attachment relationship `traffic-and-car-ai.md` and the collision notes assume a hooked trailer has. Does nothing if the trailer car has been despawned. |
| 246 | an earlier-declared car, a second earlier-declared car | A condition: if the two names refer to the *same* car, true if that car is itself a trailer or a cab able to tow one; otherwise true if the first car currently has the second attached as its trailer. |
| 247 | an earlier-declared car, a second earlier-declared car | A condition: true if the second car is specifically the trailer attached to the first (checked by walking the first car's own attachment, rather than asking the first car "do you have a trailer"). |

### 2.5 Protective and cosmetic properties

| Type | Parameters | Effect |
|---|---|---|
| 155 | an earlier-declared car, a remap (or a sentinel meaning "leave unchanged") | Changes the car's colour remap. Unlike the condition commands below, this one does **not** check whether the car has since been despawned before writing to it — see Edge cases. |
| 303 | an earlier-declared car, a number | Sets the number painted on the roof of the car (used for race/checkpoint cars). |
| 310 | an earlier-declared car | Arms the car's alarm, the same alarm `entering-and-exiting-cars.md`'s edge cases says goes off on any entry, even an empty parked car. |
| 278 | an earlier-declared car, a lock state | Sets the car's door lock: locked; locked specifically against AI car thieves; unlocked; locked against the player specifically; or locked permanently. Locking it permanently is sticky — none of the other four states can overwrite a permanently-locked car; only issuing "locked permanently" again has any effect once it's set. |
| 311 / 312 / 313 | an earlier-declared car, on/off | Toggles the car's bulletproof, rocketproof or flameproof flag independently. |
| 361 | an earlier-declared car, on/off | Turns the car's siren and emergency lights on or off, but only if the car actually has emergency-light fittings: cars whose model data is flagged as an emergency vehicle, or — regardless of that flag — the FBI's own car model. |

### 2.6 Destruction, explosions and car bombs

| Type | Parameters | Effect |
|---|---|---|
| 142, 144, 398, 399, 403, 404, 405, 406 | an earlier-declared car (shared with equivalent character/object/crane forms of the same commands) | Detonates an explosion at the car. **Quirk:** whichever of the "large/small/no-ring" size variants is used, a car target is always exploded as the plain "item" explosion size — the size choice only takes effect for the character/object/crane forms of the same command. See `explosions-and-damage.md` for what the explosion itself then does to the car and anything nearby. |
| 305 | an earlier-declared car | A condition: true if the car currently has a car bomb attached (planted via the car-bomb power-up/weapon, not a script creation). |

### 2.7 Car-state conditions

These are the IF-style tests a mission thread uses to branch on a car's state. All look up the named car (or, for a few, a character's car) and set the thread's condition result.

| Type | Parameters | Tests |
|---|---|---|
| 129 | an earlier-declared car, a 0–100-ish level | True once the car's raw damage total has reached 320 × that level — the same raw damage scale `explosions-and-damage.md`'s damage-stage table uses, so a script level of 100 lines up with that table's wreck threshold. |
| 200 | an earlier-declared car, a quarter (front/back/left/right) | True if that quarter of the car's bodywork is currently showing damage — the same "struck quarter" concept `car-collision.md`'s dents rule uses. |
| 157 / 158 / 159 | an earlier-declared car, a car model and/or a remap | True if the car's model matches, its remap matches, or (159) both match. 158 and 159 additionally require the car not to have been despawned; 157 doesn't check despawn status. |
| 139 | an earlier-declared car, a position (2D/3D) | True if the car's collision box is within one map block of that position. |
| 270 | an earlier-declared car, a rectangle (position, width, height) and a vertical band around that position | True if the car (and it hasn't been despawned) overlaps that rectangle, in plan view and in height. |
| 189 | an earlier-declared car, a rectangle | True if the car is within that area **and** is either wrecked (raw damage at or past the wreck threshold) or already in the process of despawning. |
| 208 | an earlier-declared car, a speed | True if the car's current physics speed exceeds that value. |
| 206 / 207 / 209 | an earlier-declared car (206, 209) or character (207), a destination counter | Reads the car's current speed (206), the speed of whatever car a named character is in (207), or the car's top speed (209) into a counter, instead of branching directly. |
| 241 | an earlier-declared car, a weapon | True if the car is currently carrying that vehicle weapon. |
| 250, 130 | an earlier-declared car | Both true if the car currently has a driver (ped or player) — these two separately-numbered commands run the identical test; see Edge cases. |
| 154 | an earlier-declared car | True if the car has been despawned, is in the process of despawning, has reached the wreck damage threshold, or is visually sunk/zoomed out of normal play. |
| 190 | an earlier-declared car | True if the car is visually "zoomed" the way a sunk or crane-lifted car is (the same flag 154 also checks, in isolation here — see Edge cases). |
| 191 | an earlier-declared car | True if the car is airborne. |
| 267 | an earlier-declared car | True if the car is currently being crushed (`crushers-and-garages.md` §3). |
| 417 | an earlier-declared car | True if the car's siren/emergency lights are switched on — only meaningful for cars eligible for them (see 361 above). |
| 358, 366 | an earlier-declared car, a weapon (358 only) | True once a hit by that weapon (358) or by any weapon (366) on this car has been recorded, per the hit-recording `mission-scripts.md` §3.4 already describes. The check is "sticky" across ticks: once it starts watching and finds nothing yet, it keeps watching on later visits without re-arming until a hit actually lands, then fires once and resets. |
| 128 | an earlier-declared character, a destination car variable | Not itself a condition: records whichever car the named character is currently in in the variable, and marks that car as a protected "mission car" so the traffic system won't recycle or despawn it. If a different car was already stored this way, the old one is released back to ordinary traffic (recycled or despawned) unless it's still the same physical car. |

## 3. Order of events

No ordering beyond the general thread rule (`mission-scripts.md` §3.2): each of these commands is an ordinary one-tick command unless noted, so a script that creates a car and immediately tries to drive it needs the creation on an earlier line (lower command number reached first) than the command that controls it — the usual "looked up by command number" rule.

## 4. Numbers

| Value | Meaning | Source |
|---|---|---|
| 320 | multiplier from a script's damage-check level to the car's raw damage total (type 129) | [exe] |
| 255 (0xFF) | sentinel for type 155 meaning "don't change the remap" | [scr] |
| 5 | door-lock states available to type 278 | [scr] |

Everything else here reuses numbers already tabulated in `car-handling.md`, `car-collision.md`, `traffic-and-car-ai.md` and `explosions-and-damage.md`; this note doesn't repeat them.

## 5. Edge cases and quirks worth reproducing

- **Exploding a car always uses the plain explosion size**, regardless of which size variant the script chose — reproduce the flattening, not the apparent intent (2.6).
- **Two separate command numbers (130 and 250) run the exact same "has a driver" test.** Either can be used; neither is more correct.
- **190 duplicates part of 154's test.** A sunk/zoomed car reads as wrecked under 154 and also, separately, as "sunk" under 190 — both can be true of the same car at once.
- **Changing a car's remap (155) skips the despawn check** that the otherwise-similar model/remap condition commands (158, 159) and most other car commands apply. Writing to an already-despawned car's remap appears to be harmless in practice but is inconsistent with the rest of the family.
- **Locking a car "permanently" can't be undone** by any of the other four lock states — only setting it to permanent again has any further effect.
- **The jammed-throttle flag (374) only visibly matters for a player-driven car** — it forces the gas pedal input itself, so it has no effect on a car already under full AI control, which doesn't read that input.
- **A "kill all passengers" on a bus kills every passenger on every bus**, not just the named one, if the named car happens to be a bus.

## 6. Open questions

- **Type 331 ("remove a character from a car's group-in-car bookkeeping") has no handler in the decompilation at all.** Either it's dead code, or its effect is handled somewhere this pass didn't find.
- **What exactly "locked against AI car thieves" vs. "locked against the player" (278) look like from a would-be enterer's side** — `entering-and-exiting-cars.md`'s own open questions already flag door usability as unresolved; these two lock states are presumably part of that answer.
- **The exact meaning of "jammed" beyond the accelerator lock** — whether AI cars ever read this flag in a different way than player cars do wasn't confirmed either way; only the player-input use was found.
- **Why command 305 (car-bomb-active) is reachable from two different places** in the dispatch (grouped once with the other explosion commands, once with the other car-state conditions) — functionally identical either way, but unclear if that's deliberate.
