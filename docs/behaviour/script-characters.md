# Script command reference: characters (runtime)

- **System:** The runtime script commands that create and control peds ("characters") during a mission thread — everything a script can do to a ped *after* the level-start declaration pass, as opposed to the one-shot character declaration (`script-declarations.md` §2.3, command types 7/8, which just spawns a ped with a position, heading, remap and occupation). Covers: creating a ped mid-mission, assigning it a main objective (go to a point, follow, attack, wait, enter/leave a car, patrol, guard), arming it, health/invincibility/death/arrest handling, gang and follower-group membership, threat-search/reaction tuning, appearance and speed settings, and the ped-state query commands scripts use for IF-style conditions.
- **Out of scope:** the AI behaviour these commands trigger once set — objective handling, threat detection, fleeing, fighting, following and group formation are `ped-ai.md`'s job; on-foot movement, falling and car-hit reactions are `ped-movement.md`'s; weapon firing mechanics are `weapons.md`'s; gang respect arithmetic is `gangs-and-respect.md`'s; death/arrest/power-up bookkeeping is `power-ups-death-and-arrest.md`'s. This note is only each command's own parameters and immediate effect: what it sets, creates, triggers or reads on a ped. Also out of scope, already covered by `script-cars.md`: car creation/control, driver and passenger assignment, trailers, car-state conditions, and a car's own "kill all passengers"/"has a driver" tests.
- **Builds on:** `mission-scripts.md` (file format, thread/tick model, "looked up by command number" convention). Cross-referenced throughout: `ped-ai.md`, `ped-movement.md`, `weapons.md`, `gangs-and-respect.md`, `power-ups-death-and-arrest.md`, `traffic-and-car-ai.md`, `script-cars.md`, `script-declarations.md`.
- **Sources read:** the decompilation's per-tick script-command dispatch and every handler it routes to for character creation, objective assignment, weapon granting, health/invincibility/death/arrest, gang and group membership, threat-search/reaction tuning, appearance and speed settings, and the character-state condition tests; the ped-group follower-spawning call used by the script's own "add group" command; and the fields read by the mission-fail-on-death/arrest check (`mission-scripts.md` §3.3).
- **Date and author:** 2026-11-20, Claude (notes writer, reader side).

Tags: **[scr]** the compiled script file format, **[exe]** fixed in the executable, **[obs]** to confirm in play.

---

## 1. What the player sees

Nothing here is its own visible event; it's the machinery behind things a mission does to people mid-job: a target suddenly appearing on a street corner, a hostage who stands still until spoken to then walks off to a car, a thug who's handed a shotgun the moment the player gets close, a witness who can't be killed until the script says so, a gang that silently stops hating the player once a job is done, or a small escort that falls in line and follows on command. Scripts also use these commands silently, every tick, to check whether a mission character has died, been arrested, got into a car, caught fire, fallen, drowned, been knocked down, spotted the player, or landed a punch — the conditions that drive IF-style branches in a mission thread.

## 2. Inputs: the runtime character commands [scr]

These commands run like any other script command (`mission-scripts.md` §3.2): one per tick, in thread order, as the thread's current command. The "looked up by command number" convention from `script-declarations.md` §2 still applies throughout.

### 2.1 Creating a character

| Type | Parameters | Effect |
|---|---|---|
| 41 / 42 | position (2D/3D), heading, remap, occupation | Creates a ped, exactly like the level-start character declaration (`script-declarations.md` §2.3) — same parameter shapes, same effect on the ped itself. The only differences are *when* it runs (this line, this tick, instead of the one-shot pass) and that the new ped is added to the mission's cleanup list, so it's removed automatically if the mission ends (unless this command happens to run during the level-start pass itself). |

### 2.2 Objectives

A character tracks a **main objective** (`ped-ai.md` §2) — its assigned job. These commands set that main objective directly to one of the same objective numbers the AI's own internal objectives use (go to a point on foot/any means/in a car; follow a ped or a car; wait on foot, in a car or for a train; patrol on foot; guard a spot or area; enter or leave a car, bus or train; chase and kill a ped or a car, on foot or by any means; punch a ped; the flee variants `ped-ai.md` §3.5 already covers). What each objective number then makes the ped actually do is `ped-ai.md`'s territory; this note is only which command sets which shape of target alongside it.

| Type | Parameters | Effect |
|---|---|---|
| 131 | character, objective number | Sets the main objective alone, with no target data — used for objectives that need none: waiting, patrolling, guarding on the spot, and similar. Also clears a pending "scheduled for removal" flag, so giving a character a fresh objective cancels any outstanding mission cleanup. |
| 132 | character, objective number, a second entity (a character, a car, or an object — whichever the objective needs) and a variant value | Sets the main objective plus its target: a character for chase/flee-from/follow/kill/punch objectives, a car for kill-car/wait-in-car/leave-car/follow-car-in-car objectives, or an object for the two vehicle-mounted-weapon objectives. Only the "enter a car as driver" objective reads the variant value, and only to choose a passenger seat instead of the driver's. |
| 133 | character, objective number, a position (x, y, height) | Sets the main objective plus a fixed target point. Unlike the 2D/3D position fields elsewhere in the script format, the height here is always the value given directly — there's no ground-height lookup sentinel. |
| 315 | character, objective number, a car, an orbit angle (degrees) and a distance | Sets the main objective plus a target car and a fixed angle/distance to hold while following it on foot — an escort running alongside a moving vehicle at a set offset, rather than chasing it or riding in it. |

Two further character-control commands bypass the objective system entirely:

| Type | Parameters | Effect |
|---|---|---|
| 360 | character | Forces the character to drop whatever it's doing and stand idle immediately, overriding its current objective rather than replacing it with an explicit "wait". |
| 357 | character, a position and a facing | Pulls the character bodily out of whatever car it's in (clearing that car's driver) and places it on foot at the given position and facing. **Quirk:** it always resets the local player's follow-camera and briefly disables player input while doing this, even if the character being warped isn't the player. |

### 2.3 Weapons

| Type | Parameters | Effect |
|---|---|---|
| 138 / 266 | an earlier-declared character **or car**, a weapon, (266 only) an ammo amount | Gives the named entity a weapon. Against a character: type 138 gives a fixed ammo amount; type 266 gives the amount specified. **Quirk:** an ammo amount of exactly 100 isn't a literal amount — it's a sentinel meaning "use this weapon's own default pickup amount" (the same per-weapon default table `weapons.md` flags as not yet documented), so type 138's "fixed" amount is really "whatever that weapon normally hands out". A player character's ammo is tracked normally after this (`weapons.md` §3.1); a non-player character simply has its weapon forced and drops anything it was holding, since AI peds don't track ammo. Against a car instead of a character, the same two command types install a vehicle weapon with a flat ammo amount, independent of which of the two types was used. |
| 256 | character | Strips every weapon. For a player character this clears the player's whole weapon inventory; for a non-player character it clears whatever single weapon it's holding. |
| 420 | character, a weapon | A condition: true if that weapon is the character's currently-selected one. **Only meaningful for the player** — the original reads the character's player data unconditionally with no check that it's actually a player; scripts only ever use this on the player's own character. |
| 411 / 412 | character, (411 only) a weapon | Sets or clears the character's **kill-frenzy weapon** — the time-limited weapon a kill-frenzy power-up hands the player, which `power-ups-death-and-arrest.md`'s death sequence removes on death. Setting it installs either a hand weapon or, if the weapon is a vehicle one, a weapon on the character's current car. Like 420, this assumes the named character is the player. |

### 2.4 Health, invincibility, death and arrest

| Type | Parameters | Effect |
|---|---|---|
| 126 | character, a health level | A condition: true if the character's current health is at or above that level. |
| 127 | character | A condition: true if the character is dead. |
| 125 | character | A condition: true if the character is either lying on the floor or at 25 health or below — a broader "stunned" check than outright dead. |
| 202 / 203 | character | Conditions: true if the character is currently falling (airborne, `ped-movement.md` §3.5) or sinking in water (§3.7), respectively. |
| 324 | character | A condition: true if the character is on fire. |
| 363 | character, on/off | Sets or clears the character's invincibility. The "on" state sets an invulnerability counter far beyond any real timer (9999 ticks) rather than a finite duration — functionally permanent until turned off again, unlike the timed invulnerability power-up (`power-ups-death-and-arrest.md`). |
| 371 | character | Kills the character outright. |
| 355 | character | A condition: true if the character has been arrested (`power-ups-death-and-arrest.md` §3.3). |
| 432 | character (unused), on/off | Toggles the mission-wide switch that `mission-scripts.md` §3.3's death/arrest fail check reads ("has the script asked to be told about death or arrest"). **Quirk:** the handler requires a valid character handle to run at all, but never actually reads it — passing an invalid one silently no-ops the whole switch instead of just ignoring an unused argument. |

### 2.5 Gang and group membership

| Type | Parameters | Effect |
|---|---|---|
| 258 | character, a gang name | Assigns the character to that gang directly. |
| 232 | character, a gang name | A condition, but **not a membership test**: true if the character is currently standing in that gang's map zone — for the player, the same cached "current gang" location the respect power-up reads (`gangs-and-respect.md` §2); for anyone else, a fresh zone lookup at the character's own position. |
| 153 | character, a count | Spawns that many new followers directly into the character's group (creating one if it doesn't already have one) — a script-driven version of the "instant gang" power-up's follower-spawning (`ped-ai.md` §3.11), but with a script-chosen count instead of the power-up's fixed four. |
| 235 / 236 / 259 | two characters | Adds the second character to the first's group (235), removes it from the first's group (236), or makes the second character the leader of the first's current group without disbanding it (259). |
| 234 | character, a count | A condition: true if the character's group currently has at least that many living members. |
| 237 | character, a count | Writes a value onto the character's group, but nothing else in the game reads it — see Open questions. |
| 419 | character | Disbands the character's entire group. |
| 359 | character, a formation type | Sets which of the two follower layouts (`ped-ai.md` §3.11's chain or normal wedge) the character's group uses. |
| 409 | character, a rectangle | A condition intended to test whether every member of the character's group is within the rectangle. **Quirk:** it checks each follower in turn, but then unconditionally re-checks and overwrites the result with the leader's own position afterwards — so in practice only the leader's position decides the outcome, regardless of where the followers are. Reproduce this as written rather than "fixing" it. |
| 408 | character, a car model | Sets the car model the character treats as its target when stealing or spawning itself a car — gang members otherwise default to their own gang's car model (`script-declarations.md` §2.11) for the same behaviour; this command overrides that per character. |

The respect-reading and respect-changing commands also take a character parameter, but only to find which player's respect to read or change — they don't otherwise act on the character. **Quirk:** none of them check that the named character actually is a player; scripts only ever use these with the player's own character.

| Type | Parameters | Effect |
|---|---|---|
| 225 / 262 / 393 | character (identifies the player), a gang name, a step count | Sets a gang's respect for that player to an absolute level (225), or increments/decrements it by that many steps (262, 393) — the same ±20-per-step arithmetic `gangs-and-respect.md`'s "mission script adjusts respect" row already documents. Type 393 additionally runs the knock-on update to every gang with a kill-reaction to this one that row also describes; whether the plain increment/decrement form (262) does the same wasn't confirmed either way. |
| 198 / 199 / 231 | character (identifies the player), a gang name, a level | Conditions: true if that gang's respect for the player is greater than, less than, or equal to the given level. |

### 2.6 Threat search, reaction and driving style

| Type | Parameters | Effect |
|---|---|---|
| 151 / 152 | character, a value | Sets the character's threat search mode or threat-reaction setting (`ped-ai.md` §2's "Search mode" and "Threat-reaction setting" inputs) directly. |
| 383 | character, a speed | Sets the character's on-foot run-speed cap (`ped-movement.md` §3.2's target speed). |
| 307 | character, a speed | Sets the speed this character drives at under AI control once it's behind the wheel of a car (`traffic-and-car-ai.md` territory) — a per-character driving speed, not a per-car one. |
| 306 | character, on/off | Sets the character's "drive aggressively" flag, read by the car AI while this character is driving (`traffic-and-car-ai.md`). |

**Dead commands:** two further command types (a "set shooting style" and a "set bravery" setting) are dispatched to the same handler as 151/152, but that handler has no case for either of them — they silently do nothing. See Open questions.

### 2.7 Combat memory

| Type | Parameters | Tests or effect |
|---|---|---|
| 252 | two characters | Not a condition: copies whoever last punched the first character into the second character slot, then clears that memory on the first character. |
| 255 | character | A condition: true if the character currently remembers having punched someone (i.e. that memory hasn't been read and cleared by 252 yet). |
| 264 | two characters | A condition: true if the second character is specifically who the first character last punched. |
| 320 | character, a weapon | A condition on recorded weapon hits (`mission-scripts.md` §3.4), the character-side equivalent of the car hit-watch commands in `script-cars.md` §2.7 (types 358/366): the same "sticky" behaviour — once armed it keeps watching without re-arming until a hit from that weapon on this character lands, then fires once and resets. |

### 2.8 State queries involving a car

These are keyed by a character but read or test the car it's currently in; the car-primary commands sit in `script-cars.md` instead.

| Type | Parameters | Tests |
|---|---|---|
| 121 / 122 / 123 | character, (121/122 only) a car or a car model | True if the character is in that specific car (121), in a car of that model (122), or in any car at all (123). |
| 243 | character | True if the character's car currently has its horn sounding. |
| 244 | character, a passenger count | True if the character's current car can hold at least that many passengers. |
| 384 / 385 | character, on/off | The two ped-side car behaviour flags `script-cars.md`'s own scope left out: "stay in the car rather than get out" (384) and "use the car's mounted weapon" (385). |
| 369 | character | True if the character is riding a bus and that bus is currently full. |

One further bus command is a global switch rather than character-keyed: type 370 (on/off) stops anyone from being able to get off any bus in the level.

### 2.9 Other state queries

| Type | Parameters | Tests |
|---|---|---|
| 124 | character | True if the character's current velocity is exactly zero. |
| 242 | character, a zone name | True if the character is currently in the named map zone (its cached navigation zones for the player; a fresh lookup for anyone else) — a general zone-membership test, distinct from the gang-turf test in 2.5. |
| 176 | character, a rectangle | True if the character is currently attacking **and** within that rectangle. |
| 165 | character | True if the character is currently attacking, has a weapon selected, and hasn't gone off-screen. |
| 251 | character | True if the character has spotted the player (`ped-ai.md`'s threat detection feeds this). |
| 145 / 146 / 147 / 148 / 149 / 150 | character, a rectangle and a height level | The "has this character arrived here" trigger family: true if the character's position falls within the rectangle **and** its height matches the given level. 145 accepts the character by any means, 146 only counts it on foot, 147 only counts it in a car; 148/149/150 add the same by-any-means/on-foot/in-a-car split but additionally require the character to be stationary (zero velocity) as well as positioned there. |
| 367 / 381 / 382 | two characters, a width and height | The same family, but the rectangle is centred on the *second* character's current position rather than a fixed point — "has character A arrived within this box around character B", by any means (382), on foot (367), or in a car (381). |

### 2.10 Appearance and occupation

| Type | Parameters | Effect |
|---|---|---|
| 156 | character, a remap | Changes the character's colour remap. |
| 364 | character, a remap, a graphic set | Changes both the remap and which of the three built-in ped sprite sets the character draws with: the ordinary civilian set, the default set (the player, gang members, FBI and other script-created characters), or the law-enforcement set (police, SWAT, army). |
| 410 | character, an occupation | Changes the character's occupation flavour (`ped-ai.md` §2's "Occupation" input — civilian, mugger, car thief, taxi/bus/train customer, law enforcement, and so on) after it already exists, as opposed to the occupation given at creation (2.1, or the level-start declaration). |

One further command is a global switch rather than character-keyed: on/off, it makes every ordinary background ped in the level behave as a mugger (`ped-ai.md` §3.2) regardless of its own occupation.

### 2.11 Explosions aimed at a character

The shared explosion commands documented from the car's side in `script-cars.md` §2.6 can also target a character directly: they create an explosion at the character's current position, using whichever size variant the script chose. **Unlike the car-target form**, the size choice here is honoured as given — the "always the plain size" quirk `script-cars.md` flags is specific to car targets.

## 3. Order of events

No ordering beyond the general thread rule (`mission-scripts.md` §3.2): each of these commands is an ordinary one-tick command, so a script that creates a character and immediately gives it an objective needs the creation on an earlier line (lower command number reached first), per the usual "looked up by command number" rule.

## 4. Numbers

| Value | Meaning | Source |
|---|---|---|
| 9999 ticks | invincibility counter set by the "on" state of the invincibility command — far beyond any real timer, so effectively permanent until turned off | [exe] |
| 25 | health at or below which the "stunned" condition reads true (also true regardless of health while lying on the floor) | [exe] |
| 100 | ammo-amount sentinel on the give-weapon commands meaning "use this weapon's own default pickup amount" rather than a literal count | [exe] |
| 50 | fixed ammo given when a give-weapon command targets a car instead of a character | [exe] |

Everything else here reuses numbers already tabulated in `ped-ai.md`, `ped-movement.md`, `weapons.md`, `gangs-and-respect.md` and `power-ups-death-and-arrest.md`; this note doesn't repeat them.

## 5. Edge cases and quirks worth reproducing

- **A give-weapon ammo amount of 100 means "default", not "a hundred".** Reproduce the sentinel, not a literal count (2.3).
- **The group-in-area condition only tests the leader.** It loops over every follower first, but a final, unconditional leader check overwrites whatever that loop found (2.5).
- **The gang-turf condition isn't a membership test.** It asks "is this character standing in gang X's zone right now", not "does this character belong to gang X" (2.5).
- **The death/arrest-notification toggle needs an argument it never reads.** Supplying an invalid character handle silently no-ops the whole mission-wide switch instead of just ignoring an unused parameter (2.4).
- **Several commands assume the named character is the player and don't check.** The current-weapon condition, the kill-frenzy weapon commands, and the whole respect family read player-only data unconditionally; scripts only ever use them on the player's own character (2.3, 2.5).
- **Warping a character out of a car always touches the local player's camera and input**, even if the character being warped isn't the player (2.2).
- **A fresh objective command clears a pending mission-cleanup flag** on the character, as a side effect of simply assigning it something to do (2.2).

## 6. Open questions

- **Two dead commands:** a "set shooting style" and a "set bravery" command type are routed to the threat-search/reaction handler, which has no case for either — they appear to do nothing at all. Confirm this is unused/cut content before an implementer spends time on it (2.6).
- **`SET_MIN_ALIVE`'s target field is never read anywhere else.** Writing to it through this command has no observed effect; either it's dead code or something reads it that this pass didn't find (2.5).
- **The ammo unit a give-weapon command supplies to a character** — whether the amount given is in the same tenths `weapons.md` §3.1 uses for ammo bookkeeping, or a different unit matching a weapon pickup's own amount field — wasn't pinned down. **[obs]**
- **Whether the plain respect increment/decrement command also triggers the "other gangs move the opposite way" knock-on** that the absolute-set and script-adjust forms both do, or only those two — the decompilation calls a differently-named function for it that wasn't confirmed either way (2.5).
- **What exactly consumes a character's "favourite car model"** (2.5) beyond the car-stealing/car-spawning behaviour it was found wired into — likely the car-thief occupation (`ped-ai.md` §3.2), but not confirmed against that note's own sources. **[obs]**
