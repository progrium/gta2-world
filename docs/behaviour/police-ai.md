# Police AI: crews, chasing, roadblocks and arrest

- **System:** How an individual police (or SWAT/FBI/army) crew, once dispatched to a pursuit, actually drives to find the player, boxes in or rams their car, sets up and runs a roadblock, searches after losing them, and how an arrest is actually triggered and carried out — the mechanics behind the pursuit states already named in `wanted-level.md`, not the wanted-points bookkeeping or crew-count targets, which that note owns.
- **Out of scope (covered elsewhere):** wanted points, stars, crime reporting, and how many crews of which kind a pursuit targets per star tier (`wanted-level.md`); a cop-as-pedestrian's threat detection, ranged weapon rationing/take-turns firing, and the melee-knockdown-arrest rule itself (`ped-ai.md`); ordinary AI car driving — speed control, look-ahead, road-arrow following, junctions, traffic lights (`traffic-and-car-ai.md`); what "busted" does to the player once arrested — body double, countdown, weapon/multiplier loss, respawn (`power-ups-death-and-arrest.md`).
- **Builds on:** `wanted-level.md`'s pursuit state machine (idle → responding → active → searching → ended) and crew-count targets; `traffic-and-car-ai.md`'s ordinary driving, which a chasing or responding crew's car still falls back on outside the special maneuvers this note adds; `ped-ai.md`'s threat detection (a cop spotting the player), melee/ranged combat, and the "pull the driver out of a car" door objective, which is how an arrest is actually carried out once a crew has run the player down.
- **Sources read:** the decompilation's police and police-pursuit modules (crew dispatch, the car-chase box-in/ram maneuver and its shared coordination table, the roadblock builder and its upkeep/teardown, and the per-crew objective logic that decides between driving, chasing on foot, pulling a driver out, and fighting), plus the ordinary traffic-car spawner's roadblock hook and the car-AI chase-task driving code.
- **Date and author:** 2026-11-19, Claude (notes writer, reader side).

Tags: **[gmp]** map file (road/ground types), **[exe]** fixed in the executable, **[obs]** to confirm in play.

---

## 1. What the player sees

A dispatched crew doesn't just trickle through traffic like an ordinary car — once it's close enough to actually have you in its sights, it drives a real route toward you, cutting through junctions rather than just reacting to the road under its wheels. Catching up, it doesn't simply tailgate: it pulls out to one side, matches your speed alongside with its siren honking, then surges ahead and cuts in front of you, slamming the brakes to try to force you to a stop. If it can't get a clean run at your side, or you're simply too fast for it, it rams you instead — a deliberate hit that costs you noticeably more than an ordinary collision would. Several crews on the same pursuit don't pile onto the same side; they take turns, and the ones that can't get alongside either wait their turn or go straight for the ram.

From three stars up, the police can also seal off a stretch of road ahead of you — a line of parked cars and barriers spanning the width of the street, sometimes with an officer standing guard at one of them — rather than relying only on the chase. At six stars it's a tank in the roadblock instead of a car, with the barriers and guards dropped.

Lose them for too long and they switch to searching: driving (or, once there, walking) to wherever they last saw you, waiting a short while, then giving up and clearing out. If a search crew strays too far from that spot without finding you, it abandons the pursuit outright rather than wandering indefinitely.

However you're finally run down — stopped in your car, or caught on foot — the arrest itself isn't a separate "the police have you now" event. It's the same melee rule any cop or pedestrian uses: a hit that would otherwise knock you to the ground busts you instead, because the attacker is law enforcement. The car chase, the box-in and the roadblock all exist to get an officer close enough to land that hit (or to physically drag you out of a stopped car first) — none of them arrest you directly.

Oddly, FBI and army units essentially never turn up as a properly dispatched chase crew with their own car — in practice you only meet them standing at a roadblock, or riding in an ordinary passing car that the game has reskinned into an FBI or army unit once your heat is high enough.

## 2. Inputs

- **The pursuit this crew belongs to** (`wanted-level.md`): its target ped, its current state, and which crew kind (police, SWAT, FBI, army) this crew was dispatched as.
- **Road arrows and ground type [gmp]:** used both for ordinary driving and for measuring a road's width when building a roadblock.
- **The target's current and last-known position,** and whether any law-enforcement ped currently has them in sight (the threat/witness check from `ped-ai.md`/`wanted-level.md`).
- **How many other crews are already chasing the same target**, and which sides of the target's car they've already taken.

## 3. Rules

### 3.1 Dispatch and the drive to get there (idle → responding)

A newly created crew starts with a car-spawn delay before it has a vehicle at all; if nothing manages to spawn before the delay runs out, the crew is scrapped. Once its car and occupants exist, the crew drives toward the nearest drivable tile to the target's last-known position — not by reacting tile-by-tile the way ordinary wandering traffic does, but by planning an actual route across the road network, picking shortcuts through junctions. Critically, this route planner treats a junction as passable whether its light is showing stop or go, so a responding or searching crew can cut straight through what would stop ordinary traffic.

**Responding ends the instant a cop spots the player** — the same sighting that raises the player's wanted level (`wanted-level.md`, `ped-ai.md`) also flips every crew assigned to that pursuit over to actively chasing. There's no separate fixed "responding" timer; it's bounded only by however long it takes the dispatched crew to get close enough, or for some other cop, to actually see the player.

A crew whose destination point turns out not to sit squarely on a drivable tile just keeps trying to approach it; if it's still not there after 100 ticks (any cop car, or any car once the pursuit is at three stars or more) or 300 ticks (otherwise) **[exe]**, and no player can currently see it, it snaps straight onto the nearest valid road point, patches up its own damage, and is freed up for reassignment. This recovery never happens on screen.

### 3.2 The chase: boxing in and ramming

Once a crew's car is actually chasing the target's car, it runs through a sequence of positions relative to the target rather than just following behind:

1. **Follow behind** the target.
2. **Choose a free side** (left or right) that no other pursuing crew has already claimed.
3. **Approach** that side, then **pull alongside**, matching the target's speed.
4. **Pull ahead** of the target and move **in front** of it.
5. Once in front, brake and **turn to face the target square-on**; if it's lined up closely enough with the target's own heading, it holds the handbrake there, physically blocking the road.
6. Once the target's own speed has dropped to a near-standstill, the chasing car **parks and halts** — it doesn't do anything further to the target itself from this point.

Multiple crews chasing the same target take turns: a crew already alongside holds that side, and a newly-approaching crew either queues for the other side or, if both are taken or it's lost patience, rams instead. **Ramming** happens whenever a crew gives up waiting for a side (longer waits at lower heat, much shorter once there are several pursuers or the wanted level is high), or whenever the target is simply too fast for the chasing car to keep up with normally — in that case it drives straight at the target's car instead of trying to line up alongside. A deliberate ram adds a flat, substantial burst of extra damage on impact, on top of whatever the ordinary collision physics would already do. FBI cars hold back from this ramming shortcut noticeably more than police, SWAT or army cars do, and stay governed by the ordinary pursuer-count speed cap instead.

While actively chasing, a crew's car also ignores the ordinary "slow down for the car ahead" reaction that ordinary traffic uses — it just steers around anything in its way that isn't the actual target.

### 3.3 Losing the target and searching

Each pursuit has an "I can currently see them" clock that's reset to a fixed length every time any law-enforcement ped actually sights the target, and otherwise ticks down once per game tick. If it reaches zero while a pursuit is actively chasing, the pursuit drops to searching.

Searching looks like responding: crews drive to the frozen last-known position using the same route-planning as above. Once a crew physically gets there, the occupants get out and search the spot on foot for a short, bounded wait before giving up. A searching crew that strays too far from the last-known position — more than a handful of blocks — abandons the pursuit outright rather than drifting. (`wanted-level.md` describes this leash as specific to the FBI tier; the source behind it reads as a general rule for any searching crew, not one gated to a particular star tier — flagged below as worth reconciling.)

### 3.4 Roadblocks

Roadblocks don't use a bespoke "find a spot ahead of the player" search. They piggyback on the ordinary mechanism that spawns background traffic cars off-screen on a road ahead of the player: each time that system is about to place a plain car, it first checks whether a roadblock can begin instead. A roadblock can only start once the player is at three stars or higher, neither of the two roadblock slots already in use is occupied, and a cooldown between roadblock attempts has elapsed **[exe]**. If it goes ahead, the location and road direction the ordinary traffic spawner had already picked — off-screen, clear of other sprites and walls — is used for the roadblock instead of a normal car.

Building the roadblock measures the road's actual width at that spot (giving up if it can't find both edges within a short search, or if the road is wider than a generous cap), then fills the lanes across that width alternately: every other lane gets a parked vehicle, and the lanes in between get a pair of physical barrier objects, plus — depending on a coin-flip-style setting carried over from the previous lane — an officer standing guard there. The vehicle model follows the pursuit's current tier: an ordinary police car for both the police and SWAT tiers (SWAT roadblocks don't actually use a SWAT van here), an FBI car at the FBI tier, and a tank at the army tier — except army roadblocks skip the vehicle on the very last lane, and drop the barriers and guard peds entirely. Every roadblock vehicle has its emergency lights switched on. A roadblock guard who does spawn stands and fights rather than chasing — armed more heavily if it's an FBI-flavoured roadblock, ordinarily otherwise — using the same combat rules as any other cop (`ped-ai.md`).

A roadblock stays up as long as any of its vehicles, barriers or guards are still around and have recently been seen; once everything's been out of sight for long enough **and** the player has moved well away from it, the whole thing is quietly torn down and the slot freed for a future roadblock.

### 3.5 Chasing and arresting on foot

Once the target leaves their car, any crew member still sitting in a car abandons it and switches to chasing on foot — the shared ped combat/chase machinery documented in `ped-ai.md` takes over from here (closing distance, picking a weapon, firing in turns, melee). If the crew's car has caught up to and stopped a target who's still inside it, an officer who's close enough and has already gotten out of their own car instead runs the shared "pull the driver out" door objective to physically drag them out (`ped-ai.md` §3.9) — law enforcement uses a more forgiving car-speed tolerance for this than any other attacker.

A pursuing officer who's left their car to chase on foot will get back in and resume the car chase if the target pulls away far enough, or stays in a fast-moving car for too long without the officer closing the gap; it only commits to a foot chase once genuinely close and the target's car (if any) has slowed to a crawl.

There is no separate "the police have surrounded you, you're arrested" mechanic distinct from this. Boxing a car in, or sealing a road with a roadblock, only ever gets the player's car to stop — the arrest itself still runs through the ordinary melee rule: a hit that would otherwise knock the target down busts them instead, because the attacker is law enforcement (`ped-ai.md` §3.9). Car-chasing crews that succeed in stopping the target's car simply park and wait; they don't themselves deliver anything that triggers a bust.

### 3.6 SWAT, FBI and army specifics

A dispatched police crew is two officers sharing one car (a leader and a backup); at the lowest heat they're noticeably frailer and only carry a sidearm, toughening up once the chase is properly under way. A dispatched SWAT crew is four officers in one vehicle, all considerably tougher than ordinary police.

FBI and army crews, despite being named in the star-tier targets (`wanted-level.md`), were not found to ever go through the ordinary dispatch-and-spawn path that gives police and SWAT crews a car and occupants — reaching those tiers instead dismisses any existing police/SWAT crews and simply raises the "highest crew kind currently in this pursuit" marker, which flavours roadblocks and the ordinary traffic-car spawner (which can reskin a plain passing car into an FBI or army unit, more heavily armed and tougher than a dispatched police crew, once that marker is high enough) without ever creating a proper FBI/army chase crew of its own. Whether this is a deliberately scaled-back FBI/army experience or unfinished work is unclear (§7).

### 3.7 Sirens and lights

Emergency lights are switched on the moment a crew is actively assigned to a pursuit, and on every roadblock vehicle; they're a purely visual flashing effect. A car actively boxing in a target also honks its horn (if it's a police car) through the approach-and-overtake maneuver. No mechanism was found for ordinary traffic or pedestrians to react to a siren or flashing lights by yielding or pulling over — treat that as not implemented rather than an unresolved question.

## 4. Order of events (per tick, building on `wanted-level.md` §4)

1. `wanted-level.md`'s pursuit update runs first: tier, crew targets, the one-star timeout, and the overall pursuit state (idle/responding/active/searching/ended).
2. Each crew not yet spawned counts down its spawn delay; once ready, its car and fresh occupants are created.
3. A crew without the target currently in view drives toward the last-known position by the full route-planning described in §3.1/3.3, ignoring traffic-light legality on the way.
4. Any law-enforcement sighting of the target (this crew's own, or any other cop's) updates the last-known position and resets the "can still see them" clock; a car-crew that's now close enough and has a path to the target switches onto the active box-in/ram maneuver (§3.2).
5. If the target has left their car, or a crew's own car has been left behind, that crew's members chase and fight on foot instead (§3.5), including pulling a stopped target out of their car.
6. Separately, the ordinary off-screen traffic spawner's attempt to place a new background car may instead seed or maintain a roadblock (§3.4), and an existing roadblock's upkeep/teardown check runs on its own schedule.
7. If the "can still see them" clock reaches zero, the pursuit drops to searching; a search crew that strays too far from the last-known spot gives up.

## 5. Numbers

| Value | Meaning | Source |
|---|---|---|
| 250 ticks | "still have them in sight" clock; reset on every sighting, ends the active state at zero | [exe] |
| 100 ticks | wait before snapping an off-screen, stuck cop car (or any car at 3+ stars) onto the nearest road point | [exe] |
| 300 ticks | same wait for a non-cop car below 3 stars | [exe] |
| 200 ticks | spawn delay for the first crew dispatched to a newly active pursuit | [exe] |
| 50 ticks | spawn delay for a backup crew added to an already-active pursuit | [exe] |
| ~5 blocks | leash before a searching crew gives up on the last-known position (see §3.3 open point) | [exe] |
| 200 ticks | on-foot search wait at the last-known position before giving up | [exe] |
| 500 | flat extra damage dealt by a deliberate ram, on top of ordinary collision damage | [exe] |
| 3 stars | minimum tier for a roadblock to be allowed to start | [exe] |
| 2 | maximum number of roadblocks live at once | [exe] |
| up to 12 lanes | widest road a roadblock can be built across | [exe] |
| up to 6 vehicles / 6 guards / 12 barriers | per roadblock | [exe] |
| 200 ticks + player well away | roadblock teardown condition once unseen | [exe] |
| 2 | officers in a dispatched police crew's car | [exe] |
| 4 | officers in a dispatched SWAT crew's car | [exe] |

## 6. Edge cases and quirks worth reproducing

- **The chase doesn't arrest you — it only stops you.** Every car-side mechanic (box-in, ram, roadblock) exists purely to bring the player's car to a halt or to force them out on foot; the actual bust is the same melee-knockdown rule any cop uses (`ped-ai.md`).
- **A chasing car will ram rather than wait forever** for a clear side, especially with several pursuers already queued or at higher heat.
- **FBI cars are the cautious ones** — every other pursuing vehicle type commits to overtaking/ramming far more readily once alongside.
- **Roadblocks come from the ordinary traffic spawner**, not a dedicated placement search — they only ever appear where a background car would otherwise have spawned.
- **Army roadblocks are bare tanks** — no barriers, no guards, and a gap on the last lane.
- **FBI and army essentially never show up as a "real" dispatched chase crew** — only at roadblocks or as a reskinned ordinary traffic car.
- **Chasing cars shrug off ordinary traffic obstacles**, steering around anything that isn't the actual target instead of braking for it.
- **Sirens and lights don't make anyone yield** — purely cosmetic.

## 7. Open questions

- **Is the searching give-up leash really FBI-only?** `wanted-level.md` describes it as an FBI-tier behaviour; this note's sources read it as a general rule for any searching crew. Worth reconciling between the two notes once reviewed.
- **Whether FBI/army never being properly dispatched is intentional or unfinished.** It's consistent with other half-finished systems already flagged in `ped-ai.md` (the dead flee-objective handlers), but wasn't confirmed either way.
- **Exact pursuer-count speed caps** during the alongside/approach maneuver were read as roughly tiered (one pursuer slower, two a little faster, three or more essentially uncapped) but the precise values weren't pinned down with confidence. **[obs]**
- **Tank/gun-jeep turret aim and fire rate** during a chase reuses the ranged-weapon system `ped-ai.md` already documents for any ped; this note didn't re-derive it, so anything turret-specific there is still open.
- **Whether a red light is enforced for ordinary traffic but specifically bypassed by chase/search routing**, or whether ordinary traffic doesn't really enforce red lights either (an open question already flagged in `traffic-and-car-ai.md`), wasn't fully disentangled.
- **Absolute heading convention** (cross-cutting, `README.md`) affects which way "approach from the left/right" and "facing the target" point.
- **Animation frame timing** (cross-cutting, `README.md`) affects how many real ticks separate the maneuver steps described here as "every tick."
