# Script command reference: objects (runtime)

- **System:** The runtime script commands that create and control non-car, non-ped "objects" during a mission thread — everything a script can do to an object, a generator, a door or a phone *after* the level-start declaration pass, as opposed to the one-shot object declarations (`script-declarations.md` §2.4, command types 15/16/17/18/19/20) and the generator/conveyor/destructor declarations (`script-declarations.md` §2.8). Covers: creating an object mid-mission, removing or force-cleaning up an object, switching a generator on and changing what it spawns, a car-model-driven power-up decision, object-state queries used by IF-style conditions, and the runtime commands for doors and phones (both of which are objects under the hood).
- **Out of scope:** the full runtime behaviour of objects as a gameplay system — what a pickup does when touched, physics-object movement, grenade bounce, mine behaviour, how a door's open/close animation actually plays out, how a phone call is answered on foot — all of that is the not-yet-written objects-behaviour note (`README.md`'s "Still to write" item 4). This note is only each command's own parameters and immediate effect. Also out of scope: car and character creation/control (`script-cars.md`, `script-characters.md`); the explosion commands' car/character forms (cross-referenced here only for the object form); cranes (not yet written); ambient sound points and radio stations, which go through the same object machinery internally but belong with the not-yet-written audio note; map-block editing commands (add/remove/lower/change a block) and car-model traffic-suppression, neither of which are "objects" in this note's sense and don't yet have an obvious home in the remaining families.
- **Builds on:** `mission-scripts.md` (file format, thread/tick model, "looked up by command number" convention). Cross-referenced throughout: `script-declarations.md` (object, generator/conveyor/destructor and door declarations), `script-cars.md` (shared explosion commands), `power-ups-death-and-arrest.md` (pickups), `crushers-and-garages.md`.
- **Sources read:** the decompilation's per-tick script-command dispatch and every handler it routes to for object creation, object/generator deallocation and forced mission cleanup, generator activation and power-up-type selection, object-state condition tests, door open/close/auto/manual control and door-target updates, and phone ring/answer/timeout/dead-phone handling; the mission cleanup list's own object-push logic; and the object-model enum ranges that the generator and cleanup logic test against.
- **Date and author:** 2026-11-20, Claude (notes writer, reader side).

Tags: **[scr]** the compiled script file format, **[exe]** fixed in the executable, **[obs]** to confirm in play.

---

## 1. What the player sees

Nothing here is its own visible event; it's the machinery behind things a mission does to the city's props mid-job: a pickup or crate that appears out of nowhere partway through a job, a generator that starts churning out a particular power-up because of which car the player is driving, a door that swings open or shut on cue, a phone that suddenly starts ringing with a countdown to answer it before the call is missed, and a phone that's "dead" and can't be used again once a job is done. Scripts also use these commands silently, every tick, to check an object's model (for example, to tell one pickup variant from another) or whether it's currently visible on screen.

## 2. Inputs: the runtime object commands [scr]

These commands run like any other script command (`mission-scripts.md` §3.2): one per tick, in thread order, as the thread's current command. The "looked up by command number" convention from `script-declarations.md` §2 still applies — a command that names "an earlier-declared object/generator/door" means the handle created by whatever earlier command (declaration or runtime) was given that command number.

### 2.1 Creating an object

| Type | Parameters | Effect |
|---|---|---|
| 47 / 48 / 49 / 50 / 51 / 52 | position (2D/3D, plain/named), rotation, object model, (some forms) a numeric value | Creates an object, exactly like the level-start object declaration (`script-declarations.md` §2.4) — same parameter shapes, same effect on the object itself. The only differences are *when* it runs (this line, this tick, instead of the one-shot pass) and that the new object is, with one exception (see Edge cases), added to the mission's cleanup list, so it's removed automatically if the mission ends. |

**Quirk — which forms actually apply the value:** the six type numbers don't pair up the way their names and the declaration equivalents suggest. Only the "2D, with a numeric value" and "3D, named" forms apply the given value (a pickup's value or a shop's type) to the new object. The "3D, with a numeric value" and "2D, named" forms are instead routed to the plain creation path and silently ignore whatever value they were given. The two genuinely plain forms (2D and 3D, no value) are, in turn, routed through the value-applying path — harmless in practice since a plain command's data has nothing meaningful there, but a real inconsistency in the dispatch. Reproduce this scrambled routing as written rather than "fixing" it into the sensible 2D/3D-paired shape the declaration version uses.

### 2.2 Removing an object

| Type | Parameters | Effect |
|---|---|---|
| 140 | an earlier-declared entity | Not object-specific: removes whatever the named command number refers to. For a car, marks it for despawn; for a character, deallocates it; for an object, a light, or a sound point, deallocates it the same way. Does nothing for an entity type it doesn't recognise. **This command isn't mentioned in `script-cars.md` or `script-characters.md`** — it's the one general-purpose "remove this" command, and it happens to matter most for objects (pickups, physics objects) since cars and peds are more often just left to despawn or die on their own. |
| 444 | an earlier-declared object (or ambient sound point) | Adds that object to the mission's cleanup list immediately, even if it's exempt from automatic cleanup (see Edge cases) — forcing it to be removed when the mission ends regardless. Does nothing if the named entity isn't an object or sound point. |

### 2.3 Generators (object spawners)

These act on a generator created by the level-start declaration (`script-declarations.md` §2.8, types 28–32). The runtime creation forms for generators, conveyors and destructors that the type numbering otherwise leaves room for have no handler at all — see Open questions.

| Type | Parameters | Effect |
|---|---|---|
| 268 / 269 | an earlier-declared generator, a spawn count | Turns the generator on and sets how many more times it will produce its object before stopping (its declared default is effectively unlimited). Also picks the generator's spawn pattern from its *current* object model: models in either of two fixed ranges — one covering the game's power-up/pickup objects, the other its weapon pickups — make it spawn one at a time (wait for the current one to be taken before producing the next); any other model makes it spawn a fresh one every cycle regardless of whether the last is still there. |
| 351 / 352 | an earlier-declared generator, a spawn count, a new object model | The same as 268/269, but first overwrites the generator's object model with the given one — so a single generator slot can be retasked to produce something different partway through a mission. |
| 354 | an earlier-declared car, an earlier-declared generator | Looks up the car's model in the level's declared car-model list (`script-declarations.md` §2.16, type 353) and, if it matches an entry, sets the named generator to produce the power-up type that entry maps to (a fixed per-model table in the executable, not reproduced here — flagged in Open questions) and turns it on with a small, fixed spawn count (3 or 1, depending on the resulting type). If the car's model isn't in the list at all, the generator is set to a specific default power-up type with a spawn count of 3 instead. This is the mechanic `script-declarations.md`'s type-353 entry describes as "not yet written" — it's this command. |

### 2.4 Object-state queries

| Type | Parameters | Tests |
|---|---|---|
| 362 | an earlier-declared object, an object model | True if the object's current model matches the given one. |
| 160, 356 | an earlier-declared car, character, or object | Not object-specific, but undocumented elsewhere (see 2.2's note on type 140): true if that entity's sprite currently falls within any player's camera view. Type 160 uses a more lenient "wide view" version of the test; type 356 ("onscreen accuracy") uses the exact one. Both reuse whatever view-boundary logic the camera itself uses — not reproduced here. |

### 2.5 Doors (runtime control)

These act on a door registered by the level-start declaration (`script-declarations.md` §2.9). A door isn't looked up by command number the way an object is — these commands reuse the same "earlier-declared" convention regardless.

| Type | Parameters | Effect |
|---|---|---|
| 177 | an earlier-declared door | Opens the door immediately: its primary leaf opens, and its secondary leaf too (flipped, if the door's declaration set the flip flag) if it has one. |
| 178 | an earlier-declared door | Closes the door — but only if the door's own internal state already has it flagged as "closing" (its declared close rule has already judged it should shut). It can't force shut a door the door's own logic still considers open. |
| 179 | an earlier-declared door | Switches the door to automatic: it goes back to following its declared open/close rules on its own. |
| 180 | an earlier-declared door | Switches the door to manual: its own open/close rule logic stops driving it, so only 177/178 move it from here on. |
| 265 | an earlier-declared door, an earlier-declared car or character | For a door whose declared open rule needs a specific target ("one specific car," "one specific character on foot," or "any player plus one specific car" — `script-declarations.md` §2.9), replaces which car or character that target is, without changing the open rule itself. Does nothing for a door declared with any other open rule. |

### 2.6 Phones (runtime control)

A phone is an ordinary object (one of the game's phone models) with its own small set of runtime commands, independent of the level-start phone trigger (`script-declarations.md` §2.10, type 213; `mission-scripts.md` §3.4). Both paths end up starting the same kind of thread once a phone is answered.

| Type | Parameters | Effect |
|---|---|---|
| 168 | an earlier-declared phone object, an earlier-declared character, a ring-timeout (ticks, or none) | Marks the phone as taken and registers a new phone trigger pointing back to this same command line, so this phone is now ringing for that specific character. Always sets the thread's condition result to false on the line it runs on; 227 and 228 are what later poll whether it's been answered. |
| 227 | an earlier-declared phone object | A condition: true once the phone registered by 168 has been answered — and, once true, removes that registration so it only fires once. |
| 228 | an earlier-declared phone object | A condition, for a phone with a ring-timeout: true if the timeout runs out before the phone is answered (and, when it does, marks the phone picked-up/gone the same way answering it would). Counts down once per tick while waiting; has no effect if 168 was never set up for this phone, or if it was set up with no timeout. |
| 229 | an earlier-declared phone object | Cancels any pending ring on this phone (removing its registration if one exists) and resets its appearance to an ordinary, not-ringing phone. |
| 245 | an earlier-declared phone object | Switches the phone to a dead, out-of-order appearance that can no longer be touched or called, cancels any pending ring on it, and records it as dead in a level-wide list (up to 31 phones) that's saved with the game, so it stays dead after a reload. |

### 2.7 Explosions aimed at an object

The shared explosion commands documented from the car's side in `script-cars.md` §2.6 can also target an object directly: they create an explosion at the object's current position, using whichever size variant the script chose. Like the character-target form (`script-characters.md` §2.11) and unlike the car-target form, the size choice here is honoured as given.

## 3. Order of events

No ordering beyond the general thread rule (`mission-scripts.md` §3.2): each of these commands is an ordinary one-tick command, so a script that creates an object and immediately removes or queries it needs the creation on an earlier line (lower command number reached first), per the usual "looked up by command number" rule.

## 4. Numbers

| Value | Meaning | Source |
|---|---|---|
| 64–108, 200–244 | object-model ranges treated as "pickups" for two purposes: a generator producing a model in either range spawns one at a time instead of every cycle (2.3), and a mission-created object in either range is *not* added to the mission cleanup list by default (see Edge cases) | [exe] |
| 91 | threshold on the power-up type a "decide power-up" command (2.3, type 354) picks: below it, the generator is given 3 spawns; at or above it, 1 | [exe] |
| 65 | the power-up/object type a "decide power-up" command falls back to if the car's model isn't in the level's declared car-model list | [exe] |
| 31 | dead phones tracked and saved per level (2.6) | [exe] |

Everything else here reuses numbers already tabulated in `script-declarations.md`; this note doesn't repeat them.

## 5. Edge cases and quirks worth reproducing

- **Mission-created objects in the "pickup" model ranges aren't auto-cleaned-up.** Unlike a mission-created car (always added to the cleanup list unconditionally), a mission-created object is only added if its model falls *outside* the two ranges in §4 — objects that look like power-ups or weapon pickups are left in the world when the mission ends, presumably because they're meant to behave like ordinary pickups rather than disappear. Type 444 (2.2) is the script's way to override this and force cleanup anyway.
- **The six runtime object-creation types don't apply their value the way their names imply** — see 2.1's quirk. Reproduce the scrambled routing, not the sensible pairing the declaration version uses.
- **Closing a door by script only works if the door already thinks it's closing.** 178 can't force an open door shut against its own declared close-rule state; it can only carry out a close the door's own logic has already decided on (2.5).
- **Answering a phone has two independent paths that converge:** the level-start phone trigger (`script-declarations.md` §2.10) and the runtime "ring this phone now" command (168) both register with the same phone-answer bookkeeping, so either can be the one a player's touch resolves (2.6).
- **Creating a coloured "gang phone" object (2.1) gets bookkeeping for free.** The plain creation form, when given one of the game's coloured phone models, automatically places a phone marker on the map and registers the phone in the same level-wide list type 245 (2.6) later writes "dead" entries into — without any script command asking for it directly. **[obs]** to confirm which phone models trigger this.

## 6. Open questions

- **Runtime creation forms for conveyors, generators and destructors (type numbers in the same numbering range as the runtime object/car creation commands) have no dispatch case at all** — a script using them would silently no-op, the same way other confirmed-dead command types in the sibling notes do. Either they're unused reserved slots, or a level never uses them; unconfirmed either way.
- **The exact object-model-to-power-up-type table a "decide power-up" command (2.3, type 354) reads** is a fixed table in the executable; only the spawn-count split (3 vs 1, at the threshold in §4) and the fallback type and count were confirmed, not the full mapping. Flagged rather than reproduced, per the brief's "no long tables of constants."
- **Which phone models actually count as the coloured "gang phone" kind** for the automatic marker/bookkeeping noted in Edge cases — confirmed that it's a specific sub-range of the phone-model objects, but the exact boundary wasn't pinned down against a published model list. **[obs]**
- **Whether any level script actually uses type 265 (door target update)** on a door declared with an open rule that doesn't need a target — confirmed it's a safe no-op either way, but not confirmed as ever exercised.
- Full object/pickup/physics-object runtime behaviour (what touching a pickup does, physics-object movement, grenade bounce, mines, a door's own open/close animation and timing, how a phone call is actually answered on foot) is out of scope here and depends on the not-yet-written objects-behaviour note (`README.md` item 4).
