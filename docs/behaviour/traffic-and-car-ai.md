# Traffic, AI driving and traffic lights (overview)

- **System:** How computer-driven cars move: they use the same car physics as the player but with AI inputs; they follow road arrows, pick turns at junctions, keep a target speed, look ahead for obstacles, stop when told to, give up when stuck off-road, and obey the city's single traffic-light cycle.
- **Status:** mostly; two behaviour-intent questions open (§7). This pass goes deeper on junction turn choice and lane centring, the reverse-out-of-trouble and car-following mechanics, how red lights are (and aren't) actually enforced, and how a non-police chase/follow/patrol task drives. The police-specific box-in/ram maneuver, roadblocks and arrest trigger still get their own note (`police-ai.md`).
- **Builds on:** `car-handling.md` (non-player handling differences), `map-geometry.md` (road blocks and arrows), `shape-and-map-collision.md` (sprite queries), `script-cars.md` (the commands that assign a chase/follow/patrol task to a car), `police-ai.md` (the police-specific maneuver built on the driving described here).
- **Sources read:** the decompilation's car AI per-tick driving update, its speed control, the look-ahead obstacle probe, the halt and forced-stop handling, the junction turn choice, and the traffic-light controller; read in more depth for this pass: the junction turn-choice and lane-centring procedures, the collision-stuck recovery and car-ahead/overtake reactions, the full traffic-light controller (checked for any code that actually reads the light phase), and the AI task/state machine that drives a chase, follow or patrol task.
- **Date and author:** 2026-11-19, Claude (notes writer, reader side); deepened 2026-11-20.

Tags: **[gmp]** map file, **[exe]** fixed in the executable, **[obs]** to confirm in play.

---

## 1. What the player sees

Traffic drives along the correct side of the road following the painted directions, turns at junctions, queues behind other cars, stops for people in the road and at red lights, and honks. A car that hits a pedestrian stops for a few seconds. Cars stranded off the road are eventually abandoned. All traffic lights in the city change together.

## 2. Inputs

- **Road arrows [gmp]:** each block's arrow byte actually holds two independent 4-bit direction sets — one "green" bit per compass direction marking it open to normal traffic, and one "red" bit per direction marking it against the normal flow at that tile (not simply "no arrow"). Ordinary traffic only ever turns onto a green direction; red bits are inert for everyday driving (see 3.7 for the one exception). The road ground type marks drivable road.
- **Driver:** whether he drives aggressively, his own preferred speed (used in chases).
- **Car:** physics state, speed, heading.

## 3. Rules

### 3.1 How AI drives the car

AI cars run the car physics in the non-player mode (`car-handling.md`): no gears, full turn ratio regardless of speed, damage-scaled pull. The AI sets the same inputs a player would (throttle, brake, reverse, handbrake, turn left, right or straight) each tick, plus an internal target heading.

### 3.2 Speed control

- Each AI car has a current speed setting, a target speed and an acceleration.
  - Default target: 0.1 blocks/tick. Default acceleration: 0.01 per tick. Maximum: 0.7 **[exe]**.
- Each tick:
  - below the target, the setting rises by the acceleration (straight to the target if the acceleration is negative);
  - above it, the setting falls by 0.08 per tick but not below the target **[exe]**.
- The car's throttle and brake inputs are then chosen to bring its real speed toward the setting.

### 3.3 Halting

A car can be ordered to halt (scripts, abandoned, collisions, or a forced-stop timer):

- **While halted:** above 0.05 blocks/tick it brakes with the handbrake on; below that it brakes, or just goes into neutral, depending on how the halt was set.
- **Hitting a pedestrian:** an ordinary calm driver who hits someone gets a forced stop of 100 ticks **[exe]** (`ped-movement.md` 3.8).
- **Off-road:** a car that has been looking for a road for over 200 ticks is marked abandoned and halts. Script-created cars never give up.

### 3.4 Following the road

- **Direction:** each tick the AI reads the arrow direction of the block under the car (or the one below, if it isn't on a ramp) and sets its target heading to the allowed direction.
- **Junctions — choosing a turn:**
  - A short-range probe ahead of the car (about 0.8 blocks normally, shrinking to about 0.4 while already turning and about 0.2 near a standstill) checks whether the car can keep going straight, and whether the tile needed for an already-chosen turn exists.
  - If nothing supports going straight, a second, farther probe (3 blocks ahead) reads that tile's green bits against the car's current heading: if the bit for whichever turn is already pending (or, with no turn pending yet, a fresh 50/50 left/right pick) is set and the heading is more than 45° off that exact direction, the car commits to the new heading.
  - The random choice is made only once per junction approach — the first time a turnable tile is found while neither a left- nor a right-turn is already pending — not re-rolled every tick. It stays pending until the car's heading matches the chosen direction (turn complete) or another car is found crossing the gap the turn would cross (the turn is cancelled and the car brakes instead).
  - A car with an assigned destination (a chase/follow/patrol task, or a script "drive to point" command) doesn't roll randomly: at each junction it looks up the route planner's own chosen turn and sets that pending directly instead — this is the "junction shortcut." If the block actually in front of the car doesn't support the route's planned turn (a map/route mismatch), the car aborts with a U-turn and drops the route, rather than reversing.
- **Junction right-of-way:** there's no stop-sign-style precedence. Instead, a car approaching a junction actively sweeps the cross street and forces any car it finds there to brake and hold (with a roughly 50-tick cooldown before that other car rechecks and can move again). Several cars doing this to each other at once is what keeps a busy junction from gridlocking or colliding, not a single arbitration rule.
- **Lane:** right after completing a turn, a separate "settle into the lane" procedure takes over from the continuous lane-centring nudge (`car-handling.md`'s arrow-snap, which still runs for every car, including the player, while driving straight on arrowed road). It compares how many road tiles over the turn should have landed the car against how many are actually ahead along the new heading; if it still needs to shift further over, it checks half a block to the side for a clear gap before nudging that way (holding its line if the gap is blocked), and once it's centred — its position within the block, measured across the direction of travel, falling in the middle 20% (0.4–0.6) — and its heading is within a few degrees of dead-on, it hands back to the ordinary continuous nudge and ends.
- **Lost:** if it isn't on a road, it steers using a "seek road" mode: it tries straight ahead, then left, then right, then directly behind (checking one level down too, for ramps), taking the first direction that finds a road tile. Reversing only happens if "behind" turns out to be the only option.

### 3.5 Looking ahead

Each tick the AI probes for anything in the way by testing the car's own shape placed ahead of it:

1. **First probe:** 1.75 blocks ahead along its target heading **[exe]**. While turning, it's 1 block ahead and 8° into the turn instead.
2. **Second probe:** if nothing is found (or on a ramp), 1 block ahead.
3. **Ramps:** a further probe at one level lower.

Whatever is found becomes the "nearest obstacle" and the AI reacts:

- **Car ahead:** brakes (handbrake above about 0.4 blocks/tick, otherwise the foot brake) once it's simply too close; honks and goes to neutral instead if the other car is very close (within about a block) and at a steep relative angle — crossing or oncoming traffic rather than one directly ahead in the same lane — or if that close car happens to be the player's. A car running a chase/follow/patrol task (3.7) skips this reaction entirely for its own target: instead it matches the target's speed directly (braking if the target's stopped, coasting once it's caught up, otherwise still accelerating toward it), and, while on a task to kill a specific pedestrian, doesn't brake for that one pedestrian either. The check only starts 20 ticks after a car's AI is first set up, never runs for buses, and is skipped on ramps or mid-maneuver.
- **Overtaking a stalled queue at a crossing:** a longer probe (3 blocks ahead) specifically watches for this: if the car directly ahead has been stopped 50+ ticks or is crawling below about 0.04 blocks/tick, and there are at least two more road tiles ahead sharing the same direction, the AI probes to the side (about 0.7, then about 2 blocks over) for a clear gap and, if found, commits to swinging out and overtaking through it. This only triggers near a pedestrian-crossing marker (3.6) — it reads as a deliberate fix to stop queues backing up at a crossing specifically, not a general "pass slow traffic" behaviour.
- **Ped in the way:** slow, stop or honk.
- **Pedestrian-crossing marker:** treated specially — see 3.6.
- **Other objects:** react by object kind.
- **Honking:** cosmetic only. Only about 1 in 8 ordinary cars actually plays the honk sound when the close/steep-angle reaction above fires (about 1 in 4 show the visual horn-flash); emergency vehicles (police, SWAT, FBI, army, fire, ambulance, train) always honk.

**Getting unstuck:** there's no single stuck timer with an escalating response — three independent checks, each re-evaluated fresh every tick, can each trigger reversing:

- blocked by solid geometry ahead with the car's actual speed at exactly zero;
- the "car ahead" reaction above finding a stopped car close ahead with the car's own speed at exactly zero;
- actively touching another car in a live collision.

In the first two cases the car simply reverses for as long as its actual backward speed is still below its own desired speed, then drops to neutral once it catches up — no steering direction is forced, so it backs straight out along whatever heading it already had. The collision case is different: it's a "wiggle," not a backing-up manoeuvre — for the first 20 ticks of being stuck in the collision it steers toward the other car's bearing while still trying to accelerate, then flips to steer the other way after that; it keeps trying only as long as the thing it's still touching is the same car.

### 3.6 Traffic lights

All traffic lights in the city share one cycle **[exe]**:

| Phase | Ticks |
|---|---|
| north–south green | 100 |
| north–south amber | 24 |
| north–south red | 24 |
| east–west green | 100 |
| east–west amber | 24 |
| east–west red | 24 |
| all red, pedestrians cross | 150 |
| all red | 80 |

The full cycle is 526 ticks (≈17.5 s), then it repeats. At the end of east–west amber, a shared "lights" state does toggle **[exe]** — but nothing was found anywhere that actually reads it. No AI driving code, and nothing else in the game, consults that value.

- Each light is a map zone **[gmp]** with lamp objects on each side; the lamps animate through the phase table above for the player to see.
- What actually makes a car brake near a light-controlled junction is unrelated to the phase: each light's setup places a pedestrian-crossing marker object on every approach that faces it, chosen once from the arrow layout there and never moved again. The look-ahead probe (3.5) treats that marker like any other obstacle — whenever it's the nearest thing found and the car isn't on a chase/follow/patrol task, the car brakes and holds the handbrake, every time it passes, with no check of whether the light is actually red, amber or green. So ordinary AI traffic doesn't wait for green; it does a brief rolling stop at every marked crossing on every pass, which can look like red-light obedience in play (especially with traffic density and the lamps' own animation alongside it) without actually being one.

### 3.7 Chase, follow and patrol tasks

A car given a chase, follow or patrol AI task (the script commands that assign one are `script-cars.md`'s runtime car commands) drives with the same speed-control, look-ahead and turn-choice rules as ordinary traffic (3.2–3.5), pointed at a different target, with a handful of specific overrides:

- **Heading source:** instead of reading the arrow direction tile-by-tile, the car asks the route planner for an actual path to its target (or to the nearest road tile to it, if the target isn't on one) and follows that, using the junction-shortcut turn choice from 3.4 instead of a random pick.
- **Speed cap:** its maximum speed comes from its own driver's preferred-speed stat, not the model's ordinary default or `.gci` top speed.
- **Obstacles:** it never slows for, brakes for, or honks at its own target (3.5) — it matches the target's speed directly instead. A task specifically to kill one named pedestrian also exempts that pedestrian from the ordinary "ped in the way" reaction. Everything else in the way (other traffic, other peds, roadblocks) is still reacted to normally.
- **Red lights:** no different from ordinary traffic — neither actually enforces them (above).
- **Off-road recovery:** uses the same "stuck off-road too long, snap to the nearest road point" handling as `police-ai.md` §3.1 describes for a pursuit crew (100 ticks for a cop car, or any car once the pursuit is at three-plus stars; 300 ticks otherwise) — confirming that mechanism is shared AI-car code, not police-specific.
- **One asymmetry found:** while approaching a junction heading south specifically, a chase/follow/patrol car is also allowed to turn onto a tile whose only set arrow bit is "red" (against the normal flow, no green arrow at all) — the one place the red arrow bits (2. Inputs) are read at all. The north, east and west approach cases have no equivalent allowance. Whether this is a deliberate "pursuit may go against the flow" rule that was never finished for the other three headings, or an unrelated quirk, isn't confirmed (§7).

This is the same generic task machinery `police-ai.md` §3.2's box-in/ram maneuver is built on top of for a dispatched police pursuit car; that note covers the police-specific approach/box-in/ram sequence, this note covers the plain driving underneath it that any chase/follow/patrol-tasked car uses.

## 4. Order of events (per AI car, per tick)

1. Release the handbrake. Read the actual speed.
2. Apply halt or forced-stop (3.3). If halted, brake and stop here.
3. If it has a chase, follow or patrol task (3.7), get its heading from the route planner instead of step 4, and apply that task's obstacle and speed-cap overrides.
4. Otherwise, read the road arrows and pick the heading, including junction turn choice, junction right-of-way and lane centring (3.4).
5. Look ahead (3.5): the nearest-obstacle reaction, the crossing-queue overtake check, and the per-tick stuck/reverse checks.
6. Handle collisions and reactions; update the AI state machine.
7. Adjust the speed setting (3.2) and turn it into pedal and steering inputs.

## 5. Numbers

| Value | Meaning | Source |
|---|---|---|
| 0.1, 0.01, 0.7 | default target speed, acceleration, maximum | [exe] |
| 0.08 per tick | speed setting fall rate | [exe] |
| 0.05 | speed above which a halting car also uses the handbrake | [exe] |
| 100 ticks | stop after hitting a pedestrian | [exe] |
| 200 ticks | off-road give-up time | [exe] |
| 1.75 / 1 block, 8° | look-ahead probe distances and turn offset | [exe] |
| 100/24/24/100/24/24/150/80 | traffic light phase lengths (lamp animation only; see 3.6) | [exe] |
| 4 + 4 bits | green (allowed) and red (against-flow) direction bits packed into the arrow byte | [gmp] |
| 0.8 / 0.4 / 0.2 blocks | junction near-probe distance: normal / already turning / near standstill | [exe] |
| 3 blocks | junction far probe (new-heading pick) and the crossing-overtake probe, same distance for both | [exe] |
| 45° | how far off a direction the heading must be before a junction turn is worth taking | [exe] |
| 1-in-2 | odds of the random left/right junction turn choice when nothing routes the car | [exe] |
| 0.4–0.6 | fractional position across a block counted as "lane-centred" | [exe] |
| ~50 ticks | cooldown before a car forced to yield at a junction rechecks and can move again | [exe] |
| 20 ticks | grace period before the car-ahead reaction starts checking at all | [exe] |
| 20 ticks | steer-direction flip threshold while stuck in an actual collision | [exe] |
| 50 ticks / ~0.04 blocks/tick | how long or how slow a car ahead must be stopped before the crossing-overtake check considers passing it | [exe] |
| ~0.7 / ~2 blocks | side-probe distances for the crossing-overtake gap check | [exe] |
| ~1 block | close-range threshold for the honk/steep-angle car-ahead reaction | [exe] |
| 1-in-8 / 1-in-4 | ordinary cars that actually play the honk sound / show the horn-flash when the reaction fires | [exe] |
| 100 / 300 ticks | off-road snap-to-road wait for a chase/follow/patrol car — same values `police-ai.md` §5 gives for a pursuit crew | [exe] |

## 6. Edge cases and quirks worth reproducing

- **One global light cycle for the lamp visuals.** Every junction's lamps are in phase — though, per 3.6, nothing in the AI driving code actually reacts to that phase.
- **AI steering doesn't soften with speed,** unlike the player's, so AI cars corner sharply and spin out more at speed.
- **The look-ahead uses the car's own shape,** so wide vehicles stop for things a narrow car would pass.
- **The arrow byte is really two 4-bit sets, not one.** Green bits mark normally-allowed directions; red bits separately mark a direction as against the flow. Ordinary traffic never reads the red bits (3.7 is the one exception).
- **Red lights aren't actually enforced by phase.** The light-state toggle the controller writes every cycle is never read by anything; cars instead brake briefly at a fixed crossing marker on every pass, regardless of whether the light is red, amber or green.
- **Chase/follow/patrol driving is barely a separate mode.** It's the same speed-control/look-ahead/turn-choice code as ordinary traffic, just fed a routed heading and a few target-specific exemptions, not a bespoke driving system.
- **Junctions have no priority rule.** Each approaching car independently forces crossing traffic to yield to it; several cars doing this at once is what prevents junction collisions, not a right-of-way rule.
- **A lane change after a turn can wait forever.** Settling into the correct lane just keeps re-probing for a gap if that lane stays occupied — there's no timeout into merging anyway.
- **The crossing overtake is narrowly scoped.** It only fires near a pedestrian-crossing marker, not for ordinary stopped traffic elsewhere on the road.
- **Buses never check for a car ahead at all.**
- **Honking and the horn-flash are cosmetic variety, not a rule** — only a fraction of ordinary cars do either when the reaction fires; emergency vehicles always do.

## 7. Open questions

- **Whether the chase-only allowance to turn onto an against-flow ("red") arrow, found only for cars approaching a junction heading south, is a deliberate pursuit rule or an unfinished check that was never extended to the other three headings** (3.7).
- **Whether the crossing-specific overtake manoeuvre (3.5) is a deliberate "don't let crossing queues back up" rule or a side effect of reusing the crossing-marker detection for something else.**
- Car spawning and despawning density by zone (traffic generator note) — unrelated to this pass, still belongs to the not-yet-written spawning note.
