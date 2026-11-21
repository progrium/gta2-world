# Script command reference: declarations

- **System:** The one-shot "declaration" commands applied once at level start, before any thread runs (`mission-scripts.md` §3.1). This covers the player ped, cars (including parked cars and trailers), characters, objects, map zone settings, arrows, cranes, conveyors, generators, destructors, crushers, doors, car/phone/area thread triggers, gang info, lights, trains, radio stations, police level, ambient sound points, and the mission-bookkeeping declarations (totals, pass/fail flags, finish score, car list, death-message base, crane power-up link, basic keyframe).
- **Out of scope:** the full runtime behaviour of the things declared here (a car's handling, a ped's AI, a crane's swing, a crusher's sequence, a door's animation, weapon/respect arithmetic) — each has, or will have, its own note. This note's job is only each declaration command's own parameters and immediate effect: what it creates or sets, and any immediate side effect.
- **Builds on:** `mission-scripts.md` (file format, the declaration pass, triggers). Cross-referenced throughout: `car-handling.md`, `entering-and-exiting-cars.md`, `gangs-and-respect.md`, `crushers-and-garages.md`, `power-ups-death-and-arrest.md`, `wanted-level.md`.
- **Sources read:** the decompilation's declaration-pass dispatch loop and every handler it calls, the command parameter layouts for each declaration type, the door and door-animation registration code, and the car-list/generator-type lookup used by one of the mission-bookkeeping declarations.
- **Date and author:** 2026-11-20, Claude (notes writer, reader side).

Tags: **[scr]** the compiled script file format, **[exe]** fixed in the executable, **[obs]** to confirm in play.

---

## 1. What the player sees

None of this is directly visible as an event — it's what makes the city look already "lived in" the moment a level opens: parked cars sitting in place, pedestrians and gang members standing around, pickups and shop markers in the street, gang colours on the map, doors already closed, trains already running their routes, and the police already capped at whatever maximum wanted level this level allows. A few declarations also quietly wire up triggers that don't do anything visible until the player touches a phone, gets in a particular car, or walks into a particular area.

## 2. Inputs: the declaration commands [scr]

Every command shares the four-value header described in `mission-scripts.md` §2 (own command number, type, next command, return value); the fields below follow that header. Repeating shapes, described once here rather than per command:

- **2D vs 3D:** several families offer both a "2D" and a "3D" form of the same declaration. Both store a full position (x, y, height); a "2D" declaration is simply one whose compiled height field has been written as the sentinel value 255.0 (see Numbers), which tells the declaration pass to read the real height from the map at that x, y instead of using the stored value. A "3D" declaration supplies a real height directly. The command data is the same size either way.
- **Named forms:** some families add a further form that also carries an entry in the script's string table (`mission-scripts.md` §2), so the declared thing can be found by name as well as by its command number. Naming has no effect on the thing itself; it only affects how later commands and the string table can refer to it.
- **Looked up by command number:** after a declaration creates something (a car, character, object, crane, generator, light, door, crusher…), the game keeps a handle to it attached to that same command. Looking the same command number up again later returns that handle. This is how a car-trigger declaration finds the exact car and character it names, how a door can be told to open for one specific earlier-declared car, and generally how one command refers to something another command declared.

### 2.1 Player ped

| Type | Parameters | Effect |
|---|---|---|
| 5 | position (2D/3D), heading, ped remap | Spawns the player's ped. |

### 2.2 Cars

| Type | Parameters | Effect |
|---|---|---|
| 10 / 11 / 12 / 13 | position (2D/3D, plain/named), heading, remap, car model, trailer model (or a flag for "mini car"/no trailer) | Spawns a car. |
| 425 / 426 / 427 / 428 | same as above | Spawns a car and immediately re-tags it as a **parked car** rather than a general mission car (see 6). |

### 2.3 Characters (peds)

| Type | Parameters | Effect |
|---|---|---|
| 7 / 8 | position (2D/3D), heading, remap, occupation | Spawns a ped. |

### 2.4 Objects

| Type | Parameters | Effect |
|---|---|---|
| 15 / 16 | position (2D/3D), rotation, object model | Spawns an object. |
| 17 / 18 / 19 / 20 | position (2D/3D, plain/named), rotation, object model, a numeric value | Spawns an object and also sets a "value" byte on it, used for a pickup's value or a shop's type. |

### 2.5 Map zone settings

| Type | Parameters | Effect |
|---|---|---|
| 102 | zone name (via the string table), overall car density, four car-type ratios (ordinary/"bad"/police/gang), overall ped density, four ped-type ratios (mugger/car thief/Elvis impersonator/gang member) | Sets the spawn-density settings for one map zone, by name. |

The ratios' effect on what actually spawns belongs to the traffic/ped spawning note (not yet written); gang car and ped models are per-gang (`gangs-and-respect.md`), gang **areas** are a separate zone lookup also not yet written.

### 2.6 Arrows

| Type | Parameters | Effect |
|---|---|---|
| 23 | none meaningful | Clears the slot's stored handle to "none." |

An arrow declaration does nothing visible by itself — it just reserves the slot that a later "point arrow" command (a different, non-declaration command family) fills in and moves each tick, and a "remove arrow" command clears again.

### 2.7 Cranes

| Type | Parameters | Effect |
|---|---|---|
| 37 ("basic") | home position, home rotation, two target positions with their own rotations, optionally a link to another already-declared crane | Creates a crane; sets **both** of its hook targets. |
| 38 ("target") | home position, home rotation, one target position and rotation, which of the two target slots to fill, optionally a link to another already-declared crane | Creates a crane; sets **one** of its hook targets. |
| 39 ("two-target") | same shape as "basic" | Creates a crane, sets its home position and rotation and the optional link — but neither hook target. See Edge cases. |

The link to another crane sets this crane's "home crane": a shared point cranes return to (exact runtime meaning in the cranes note, not yet written — see `crushers-and-garages.md` §3.4's outline). What the hook actually does when it reaches a target is also for that note.

### 2.8 Conveyors, generators, destructors, crushers

| Type | Parameters | Effect |
|---|---|---|
| 26 / 27 | an area (position, 2D/3D, and size), a 2-axis speed | Creates a conveyor-belt trigger area over that rectangle with that push speed. See `car-handling.md`'s conveyor-velocity steps for what driving onto one does. |
| 29 / 30 / 31 / 32 | position (2D/3D), rotation, an object model to spawn, a minimum and maximum respawn delay, an optional ammo-count override | Creates a generator: a spawner that periodically produces the given object (typically a pickup — `power-ups-death-and-arrest.md`) at random intervals between the two delays. |
| 34 / 35 | an area (position, 2D/3D, and size) | Creates a destructor trigger area over that rectangle. What touching it does belongs to the (not yet written) objects note. |
| 40 | position | Creates a car crusher at that point (`crushers-and-garages.md` §3 covers the crush sequence itself). |

### 2.9 Doors

| Type | Parameters | Effect |
|---|---|---|
| 230 | animation start frame, end frame, playback speed | Adds one entry to a short shared list (up to 5) of door-animation definitions. |
| 375 / 378 | map block and face, which animation definition (by its position in the list above) to use, an open rule, a close rule with a delay, an optional "presence check" area in front of the door, flip/reversed flags, "single" (375) vs "double" (378) leaf | Registers a door at that block face. |
| 376 / 379 | same shape as 375/378, plus (for the "one car" / "one character on foot" / "any player plus one car" open rules) the earlier-declared car or character this door opens for | Registers a door at that block face, and for those three open rules, resolves and records the specific car or character. |

**Open rules:** any player; any car; one specific car (named by its earlier declaration); any car of one model; one specific character on foot; any player plus one specific car; and one more, unconfirmed in play [obs]. **Close rules:** never closes on its own; closes after the given delay; closes once the presence-check area is clear; closes once the open rule stops being true. The presence-check area is only used when it has a non-zero size; a door declared with a zero-size check area skips that test entirely.

Type 375/378 records the open rule same as 376/379 but — per the decompilation — doesn't perform that same resolve step for the "one car"/"one character on foot"/"any player plus one car" rules. See Open questions.

### 2.10 Car, phone and area triggers (thread start points)

These are the one-shot setup half of `mission-scripts.md` §3.4's triggers; the trigger-firing and thread-spawning mechanics are described there.

| Type | Parameters | Effect |
|---|---|---|
| 211 | an earlier-declared character, an earlier-declared car, a thread start command | If the character and car both exist, attaches a car trigger: entering that specific car as that specific character starts a thread there. |
| 213 | an earlier-declared character, an earlier-declared phone object, a thread start command | If the character and phone both exist, attaches a phone trigger the same way, and marks the phone object as spoken for. |
| 212 | an earlier-declared character, a single map block position | If the character exists, attaches an on-foot trigger over that one block: that character walking into it starts the thread. |
| 214 | an earlier-declared character, a free-form rectangle (position, width, height) | If the character exists, attaches an on-foot trigger over that rectangle (not block-snapped). |
| 434 | same shape as 214 | The same, but the trigger fires however the character is travelling (not only on foot). |

### 2.11 Gang info

| Type | Parameters | Effect |
|---|---|---|
| 223 | gang name (via the string table), ped remap, basic/angry/hate weapons, map arrow colour, kill-respect-change value, a position, gang car model, gang car remap | Sets up that gang's identity: remap, weapons, arrow colour, car, and a position used for the gang's own phone/info marker [obs]. |

The weapons and kill-respect-change value feed `gangs-and-respect.md`'s weapon-choice and respect arithmetic directly — see that note for what they do, not what they are. The "always use basic weapon" switch and per-gang kill reactions that note also lists are set by separate, non-declaration commands (not covered here).

### 2.12 Lights

| Type | Parameters | Effect |
|---|---|---|
| 217, 302 | position (explicit height; no 2D ground-snap), colour, radius, intensity, optionally an on/off flash timing and a flash pattern | Creates a static light, optionally flashing. |

Two separate type numbers reach the same effect; a third, closely related type number exists in the format but has no effect during the declaration pass (see Open questions). How a light's radius/intensity/colour actually render isn't covered by any note yet.

### 2.13 Trains and radio stations

| Type | Parameters | Effect |
|---|---|---|
| 285 / 286 | a station's zone name (via the string table), a passenger-wagon count, a freight-wagon count, a boxcar count | Sets the wagon makeup for the named train station (type 286, "empty station," is the same declaration used with zero counts). |
| 295 / 296 / 297 / 298 | a station's zone name, a short raw wagon-type list | Sets the wagon makeup for the named station a different way. The exact meaning of the list is unclear — see Open questions. |
| 287 | a position, a station type | Declares a radio station/transmitter at that point. |

Full train and radio behaviour belongs to the public-transport and audio notes (not yet written).

### 2.14 Police

| Type | Parameters | Effect |
|---|---|---|
| 304 | a maximum wanted level | Caps the wanted level this level can reach (`wanted-level.md` covers the tiers themselves). Setting it to exactly 0 also force-enables normal police simulation (see Edge cases). |

### 2.15 Ambient sound points

| Type | Parameters | Effect |
|---|---|---|
| 327 | position, a sound id, a looping/one-shot flag | Creates a stationary sound-emitting point. |

### 2.16 Mission bookkeeping

| Type | Parameters | Effect |
|---|---|---|
| 240, 429, 430, 431 | an (unused, single-player) player slot, an earlier-declared counter | Points the "mission in progress" flag that `mission-scripts.md` §3.3's death/arrest check reads — the general flag (240), or a flag specific to gang 1/2/3 (429–431), at that counter. |
| 435, 436, 437 | a message-id base | Sets, per gang (1/2/3), where that gang's five death-fail and five arrest-fail messages begin in the game's message list — this is the base `mission-scripts.md` §3.3's random mission-fail message is added to, with a +5 offset for arrest vs death. If no gang's mission flag is active when a mission fails, a single fixed message is shown instead of a random one. |
| 343 | a target score | Sets a level-wide "finish score" value. What reads it is for the (not yet written) missions-command note. |
| 344, 345, 386, 387, 388 | a count | Sets a level-wide total: missions, secrets, or missions for gang 1/2/3. |
| 346, 347, 348, 349, 389, 390 | an earlier-declared counter | Links a completion-tracking flag — overall "passed," "passed" for gang 1/2/3, "secrets passed," "secrets failed" — to that counter, for the end-of-level summary to read. |
| 353 | a raw list of up to 19 car models, packed directly into the command's own data | Records the list a (not yet written) generator/power-up mechanic uses to decide, from a car's model, which fixed power-up type a "by car model" generator produces. The list of resulting power-up types itself is a game constant, out of scope here. |
| 439 | an earlier-declared crane, a command number | Records which command is that crane's "power-up" trigger. What running it does belongs to the cranes note. |
| 422 | a numeric id | Records that id into a short shared list (up to 25) of active "basic keyframe" sequences for the level. What a basic keyframe animates is unclear — see Open questions. |

## 3. Order of events

Declarations run once, in command-number order, exactly as `mission-scripts.md` §3.1 describes — this note adds no further ordering beyond what's implied by the "looked up by command number" rule above (a declaration that refers to another declared thing only finds it if that other declaration has already run, i.e. has a lower command number).

## 4. Numbers

| Value | Meaning | Source |
|---|---|---|
| 255.0 | height-field sentinel meaning "read the ground height here instead" | [scr] |
| 5 | shared door-animation definitions available | [exe] |
| 25 | active "basic keyframe" slots available | [exe] |
| 19 | car models in the car-list declaration | [scr] |

## 5. Edge cases and quirks worth reproducing

- **A "two-target" crane declaration sets no targets.** Per the decompilation, type 39 creates the crane and sets its home position/rotation and optional home-crane link, but neither of the two paths that set a hook target applies to it. Whether its targets are set some other way, or this type simply isn't used by any level's script, is unclear.
- **The first door-declaration type doesn't resolve its "one car"/"one character" target.** Types 375/378 record the open rule but, unlike 376/379, don't appear to resolve the named car or character for the rules that need one. Confirm whether any level actually pairs 375/378 with those rules.
- **Setting the max wanted level to exactly 0 also force-enables police simulation**, while any other value leaves that separate switch alone. This reads as asymmetric even in the source; reproduce the literal effect rather than "fixing" it.
- **A parked-car declaration is a car declaration plus a re-tag.** It creates the car exactly as the plain car declaration does, then marks it as a parked car and resets its "last seen" timer — the spawn parameters themselves (position, model, trailer…) are identical.

## 6. Open questions

- What a "basic keyframe" (type 422) actually animates.
- The exact meaning of the raw wagon-type list carried by types 295–298 (the decompilation's own authors were unsure too).
- Whether door-declaration types 375/378 are ever paired with the "one car," "one character on foot," or "any player plus one car" open rules, given they don't resolve the target the way 376/379 do.
- The on-screen meaning of a door's "unknown" open rule (one of the seven rule values, unconfirmed in play).
- What exactly the gang-info position (2.11) is used for on screen.
- Whether type 39 crane declarations ("two-target") are used by any level, given they set no hook targets (see Edge cases).
- Why light declarations have two working type numbers (217, 302) and one that does nothing in the declaration pass; whether the unused one has an effect elsewhere.
