# Ped AI: objectives, threats, fleeing, fighting, following and gangs

- **System:** How a non-player ped decides what to do each tick: the two-layer objective system, spotting and judging threats, fleeing, fighting back (chasing, keeping range, choosing a weapon, melee), following the player or a leader, forming up and recruiting into a group, gang members' attack-or-leave-alone decision toward the player, and what electro-fingers and invisibility actually do to AI decisions.
- **Out of scope (separate notes):** on-foot movement mechanics — turning, speed, walls, falling (`ped-movement.md`); weapon firing mechanics and ammo (`weapons.md`); gang respect arithmetic (`gangs-and-respect.md`); wanted level and crime reporting (`wanted-level.md`); power-up activation and duration bookkeeping (`power-ups-death-and-arrest.md`); car entry/exit mechanics (`entering-and-exiting-cars.md`); how cop crews drive, chase in cars and arrest (police AI note, not yet written); traffic AI for ordinary drivers (`traffic-and-car-ai.md`).
- **Builds on:** `ped-movement.md` (run speed, turning, walls), `weapons.md` (weapon categories, the electro gun/baton shock mechanic), `gangs-and-respect.md` (respect value and weapon tiers), `wanted-level.md` (crime reports, "jumping hides you"), `power-ups-death-and-arrest.md` (invisibility and electro-fingers timers), `entering-and-exiting-cars.md` (the mechanics an objective triggers).
- **Sources read:** the decompilation's per-tick ped AI update and its objective system; the per-objective handler functions (chase, flee, melee, follow, pull a driver out, wait); the threat-detection rule and the best-target search; the ped-group formation, tight-follow and recruiting logic; the gang-vs-gang attack order; and the shared electric-shock routine also used by the electro gun and baton.
- **Date and author:** 2026-11-19, Claude (notes writer, reader side).

Tags: **[scr]** set by the mission script, **[gmp]** map file, **[exe]** fixed in the executable, **[obs]** to confirm in play.

---

## 1. What the player sees

Left alone, peds go about their business: walking a route, riding a bus, taxi or train, or just standing around. Trouble changes that. A pickpocket sprints up and punches the player for cash rather than for blood. Bystanders panic and run from anyone waving a gun or driving at them. Someone who's just been shot rounds on the shooter and fights back, unless they're the type who just runs. Gang turf matters: a gang that likes the player leaves them alone and will even gun down police on their behalf; a gang that hates them comes looking for a fight, and gang wars pair off fighters on each side. A small escort built up with the instant-gang power-up follows in a loose formation that falls apart into a huddle the moment the leader stops, and its members break off to fight anyone who threatens the group. Police hang back and take turns opening fire rather than everyone shooting at once. Electro-fingers zaps everyone standing close to the player automatically, no aiming needed. Invisibility makes peds and police simply stop caring, as long as the player is on foot and not already in a fight with someone.

## 2. Inputs

- **The two goals a ped tracks each tick:**
  - a **main objective** — its assigned job (patrol, walk somewhere, get into a car, wait, follow a route), usually set by the mission script or by however it was spawned;
  - an **internal objective** — a short-lived reactive goal the AI sets for itself (chase, fight, flee, follow, drag a driver out of a car), which can run on top of the main objective and effectively override what the ped looks like it's doing.
- **Threat-reaction setting [scr]/[exe]:** whether this ped flees or fights back when threatened or attacked.
- **Search mode [exe]:** how a ped looks for danger — a short plain-radius check restricted to the human player, a narrower or wider line-of-sight cone also restricted to the player, or a full check (on-screen, same level, a map sightline) used by the most alert peds.
- **Occupation [exe]:** a flavour on top of the same machinery — ordinary civilian, mugger, car thief, taxi/bus/train customer, a driver who's just been carjacked, law enforcement (police/SWAT/FBI/army/guard/roadblock), paramedic, and so on.
- **Gang membership [scr]:** which gang (if any) the ped belongs to; drives the threat rule and, with `gangs-and-respect.md`, which weapon it uses.
- **Group membership:** whether the ped is a follower in someone's group, and if so its formation slot.
- **Invisibility and electro-fingers flags** (`power-ups-death-and-arrest.md`): read by the threat rule and by the player's own per-tick update respectively.

## 3. Rules

### 3.1 Objectives

Every tick, both the main and the internal objective (if one is set) resolve the same way: find the target position (a target ped's position, a target car's position or its door, a target object's position, or a fixed point), work out the distance to it once, then dispatch to one specific handler by objective number (the handlers are described through the rest of this note). Each objective also maps to one of a small number of coarse movement/animation modes (walking, fleeing, running at a target, standing still, driving, walking to a car, exiting a car) that drives the sprite state described in `ped-movement.md` — the objective is the "why", the movement mode is "what it looks like".

Setting an objective resets its target and takes an optional **timeout in ticks**; many handlers fail the objective outright once that timer reaches 0, as a generic give-up safety net independent of whatever else might end it.

Two of the flee objective numbers are wired to handlers that do nothing at all. They read as stubs for a feature that was never finished or was cut (§10).

### 3.2 Default behaviour (no objective)

With nothing more pressing set, an ordinary ped just walks its route. A handful of occupations layer extra flavour on top of the same chase/flee/melee/follow machinery below rather than running separate logic: a **mugger** treats everyone as fair game and punches rather than shoots (§3.9), retiring for good after enough successful mugs; a **car thief** goes after cars; **taxi, bus and train customers** walk to and board their ride; a **carjacked driver** grows steadily angrier. These are documented here only where they change the shared rules; the rest of their behaviour follows ordinary chase/flee/follow.

### 3.3 Threat detection

Two separate questions get asked constantly: "is ped B a threat to ped A" (a yes/no rule), and "which nearby ped should I pick as my target" (a search that filters by that rule).

**Baseline eligibility** (checked before the rule runs): the candidate must not be scenery-only, must not be dead or immobilised, and must be currently active.

**The threat rule**, in priority order:

1. A ped who is **invisible and currently on foot** is never a threat to anyone (§3.15).
2. A ped configured to only ever notice the real player ignores anyone else.
3. Two peds in the **same follower group** never see each other as a threat.
4. A **mugger** treats everyone as a threat, except a special ped riding in a police car.
5. **If the asking ped belongs to a gang:**
   - same gang as the candidate → not a threat (the human player, if somehow in the same gang, is still treated as a threat — the player-default rule below);
   - the candidate's gang isn't hostile to mine → not a threat;
   - a hostile rival gang member → a threat, **unless** the candidate already has 4 or more current or 4 or more total-ever attackers on it (a crowd-control cap; a fully active ordinary gang member ignores this cap and piles on anyway);
   - if my gang currently has **high respect** (≥80) with the player, any law-enforcement or guard occupation → a threat (a friendly gang fights police for the player);
   - if the candidate is already attacking someone else → a threat if I'm the one being attacked within 1 block, or I'm already armed; otherwise, only if my gang's respect for the attacking player is negative **and** no police are currently visible on screen (gangs stand back once police are already on it).
6. **If the asking ped has no gang** (civilian or law enforcement):
   - two peds of the same low-level background "criminal" occupation never see each other as threats;
   - **law enforcement:** a player who is mid-jump is invisible to this check (confirms "jumping hides you", `wanted-level.md`); an unarmed, not-yet-wanted, not-recently-criminal player is otherwise ignored; once engaged, the cop updates the police's last-known position and either hands off to a car crew or, on foot, directly raises the player to at least one star. Against non-player targets, law enforcement only reacts to someone else's own aggression (actively attacking, or hunting a target on foot) and never treats fellow law-enforcement or medical occupations as a threat;
   - other civilians in a formed group only treat someone as a threat if that someone is hunting their group's leader.
7. **Player-default fallback:** in any case this rule leaves undecided, the human player defaults to "yes, a threat"; an AI-controlled ped defaults to "no" in the same undecided case.

### 3.4 Best-target search

The search first spirals outward from the searching ped for the nearest ped or car sprite within a tile radius. If that finds nothing, it falls back to a shared, game-wide list of currently-dangerous peds (anyone flagged dangerous anywhere), picking the closest one that passes a same-level check, a roughly 4-block distance check, an on-screen check (if it's the player), and the threat rule above. In network games, a group leader additionally prefers the nearest player on an enemy team within 4 blocks over anything the searches found. A hit on a car resolves to its driver.

### 3.5 Fleeing

Several flee objectives share a "distance to the danger" idea:

- **Flee till safe (no ped remembered):** sprints at max speed while within 6 blocks of where the flee started; once beyond 6 blocks **and** standing on a specific "safe" ground type, the objective passes. Inside 6 blocks it keeps sprinting regardless of ground type.
- **Flee a specific ped till safe:** same 6-block/ground-type rule, but tracks one dangerous ped; passes at once if that ped dies or deactivates. While fleeing it plays a dedicated "running away" state (not plain running) and drops any attacking flag.
- **Flee a specific ped, always:** no distance check — sprints indefinitely until the dangerous ped dies or deactivates; something else has to cancel it.
- **Flee once a car has stopped:** if currently riding in a car, waits for the car to stop, then issues a leave-the-car objective; once out, switches to "flee a specific ped, always" with the same remembered danger. A driver forced out of a car instead switches to the undirected "flee till safe", aimed at the car's last position.
- **The passive trigger** for an ordinary civilian's "run away" reaction: each tick, if the single nearest ped on the dangerous list (armed, or driving) is within 4 blocks, the ped panics, turns away from it, plays one of three fear lines (a car, a loud gun, or anything else), and starts fleeing that specific ped.

Fleeing uses ordinary run speed throughout (`ped-movement.md`) — there's no separate, faster "flee speed".

### 3.6 Reacting to being attacked

Every ped remembers whoever hit it last. Each tick: if that attacker has died or deactivated, it's forgotten and any panic stops. If the attacker is in the **same gang** or **same follower group**, it's also forgotten with no retaliation — as is an attacker who has since gone invisible on foot (§3.15). Otherwise it depends on the victim's threat-reaction setting: a "flee" ped flees that attacker; anyone else (except paramedics, who never retaliate) retaliates — a weapon fight if armed, a punch if not — **unless** it's in a group: a player-led group only joins in if the attacker is on screen, hasn't been out of sight for 5 or more ticks, and is roughly the same height; an AI-led group always piles on together.

### 3.7 Chasing and keeping range

**Chasing** (closing on an internal target ped on foot): stops entirely within 1/8 block (unless mid-jump). Otherwise speed is tiered by the remaining gap — full acceleration beyond 0.5 block, then three progressively slower fixed speeds as the gap narrows below 0.5, 0.375 and 0.3125 blocks, so a chasing ped visibly slows its final approach instead of running flat out into melee range.

**Ranged attacking** checks its own range table every tick, by weapon category (approach-and-fire range, and a "too close, back off" range, in blocks):

| Weapon category | Fire range | Back-off range | Notes |
|---|---|---|---|
| Unarmed | 2 | — | falls through to melee (§3.9) |
| Pistol / machine gun / rocket / other default | 4 | — | stands and fires once in range |
| Flamethrower | 2 | 1 | |
| Molotov (thrown) | 4 | 1.5 | won't throw under a solid ceiling — backs off instead |
| Grenade (thrown) | 2.5 | 2 | same ceiling restriction |
| Electro baton | 2 | 0.5 | treated as melee-ish: tries to close inside 0.5 block |
| Shotgun | 1 | 0.5 | same close-in preference as the baton |

A target that's a car, or a ped in a nearly-stationary car, uses its own override ranges (roughly 2–3 blocks) instead of the weapon's own numbers. **FBI peds and any group's leader** always try to close within 0.5 block before opening fire, whatever the weapon, as long as the target isn't a vehicle or object.

Two extra quirks: an attacker carrying an **explosive weapon** backs off or flees outright if it would otherwise end up inside its own blast range rather than throwing or firing anyway. And many ranged attackers break off and retreat to a safer distance at full speed immediately after **landing a hit** — a hit-and-run pattern — rather than standing and trading fire; whether a given ped does this looks tied to a per-ped behaviour setting, not universal (§10).

### 3.8 Weapon selection and aim

On top of the gang basic/angry/hate tiers (`gangs-and-respect.md`), two occupations have their own overrides:

- **Police and walking guards** only use their heavier weapon against the player inside a *moving* car, never against a parked car with the player in it. Against the player on foot there's a rationing rule: at least 2 police must already be on screen/in range before any of them open fire at all, and only one is allowed to be actively firing at a time — the rest hold fire until that one stops — producing a staggered, take-turns pattern rather than every cop shooting at once.
- **FBI and roadblock cops** use their stronger weapon at range or against vehicles, but switch to their ordinary sidearm once within about 0.5 block of a target on foot.

**Aim jitter** applies only to the pistol/machine-gun family, and only for shooters whose fire-mode setting allows it (versus always accurate, or the invisible "test shot" from `weapons.md`). A stationary shooter has a smaller miss chance than a moving one — a moving shooter re-rolls once if the first roll would have been dead accurate, biasing it toward a miss. A missed shot nudges the aim angle by roughly 10° or, less often, roughly 16°, left or right.

### 3.9 Melee (punch)

Gives up if the target has died or gone; if not at the same height, or the target is already lying down, it just keeps closing distance instead of swinging. A target riding in a car hands off to a "pull the driver out" door sequence (fails if the car is going too fast — a lower speed tolerance for law-enforcement attackers than anyone else). Once within 0.25 block, on specific animation frames: a **mugger** deals no damage at all — it docks the player 10 score and counts a mug, retiring for good after more than 9 successful mugs; everyone else deals **10 damage**, except that a low-level background "criminal" occupation never takes melee damage this way. Below **20 health**, a punch instead knocks the target down and the attack ends — unless the target was the attacker's originally-assigned target (rather than one picked up along the way), in which case the attacker keeps swinging instead of stopping at the knockdown. A **law-enforcement** attacker knocking down the actual player this way results in an **arrest** (an outright kill in network games) rather than ordinary damage — melee is a second way for police to bust the player, besides the mechanic in `power-ups-death-and-arrest.md`.

### 3.10 Following

**Following a specific ped on foot** (used both for a player-directed follower and for a ped simply told to follow another ped): fails if the target dies or deactivates. Within about 3/16 block of the target at the same height, it stops and the objective passes — deferred one tick while mid-jump, during which a wait counter builds; the wait is cleared either by panicking or after 200 ticks, letting the follower re-evaluate. While closing the gap it runs at full speed beyond 0.5 block and at walking speed inside it, so it slows as it catches up rather than overshooting. A separate timer can also end the objective early even without reaching the target.

**Following in a car** reuses the ordinary car-AI chase task (`traffic-and-car-ai.md` territory) with a dedicated follow-this-ped or follow-this-car task and a fixed max speed; a jeep performing this task also opens fire with its mounted gun once within 2 blocks of the target.

### 3.11 Group formation and recruiting

A group leader with followers (a gang, or a recruited escort) can hold either of two layouts:

- **Chain:** each follower trails the one directly ahead of it, forming a single nose-to-tail line.
- **Normal (default):** the first three followers trail the leader directly; up to five more trail specific front-rank followers (a two-tier wedge) — but only while the leader is moving. The instant the leader stops, every follower's target collapses back to the leader directly, so the group bunches up around a stationary leader instead of holding formation.

Separately, a **tight-follow check** runs every tick: a follower within 8 blocks of an on-foot leader is (re)assigned to simply follow the leader directly; beyond that, any plain "follow the leader" assignment is dropped, freeing the follower to fight or flee on its own instead of endlessly trying to catch up. A stricter 4-block check, used only mid-fight (§3.12), interrupts an attack to send a follower back to the leader instead.

A follow ends on the target dying or deactivating, the distance/timeout rules above, or being given a different order (attack, flee, get in a car).

**Recruiting ("instant gang" power-up):** searches a box roughly 4 blocks out from the player on each side for the nearest eligible ped and adds it to the player's group — creating a new group first if the player doesn't already have one — up to **4 recruits** for this power-up (the underlying recruiting routine itself allows any number up to a hard **9-member group cap**; the power-up always asks for 4). Eligible candidates: ordinary background peds, or — notably — a ped that's already someone else's follower, which gets poached into the player's group instead. A recruit is reskinned to match the recruiter, armed with **dual pistols**, copies the recruiter's threat-search and threat-reaction settings and gang membership, can't jump over obstacles, and is marked as a special "follower" ped type.

### 3.12 Gang-vs-gang fighting

A group-wide "attack this ped" order (distinct from an ordinary follow) sends every eligible, non-panicking, on-foot member of the group after the target. If the target has no group of its own, each member attacks it directly, falling back to "run to the leader" if too far away (the 4-block check in §3.11) — unless the leader is already close to boarding a getaway car, in which case members join the fight instead of waiting. If the target **does** belong to a rival group, members are paired off one-for-one against that rival's calmest (not-yet-fighting) members, with each paired target also told to fight back — a genuine gang-war pairing. Once every rival member is already fighting, it falls back to a random extra target (a member or their leader). If neither leader is already fighting, the two leaders are additionally set to target each other personally.

### 3.13 Gang members toward the player

This connects to the respect tiers in `gangs-and-respect.md` through the threat rule (§3.3): a gang member only treats the player as worth fighting when the player is actively attacking **and** (the member is close enough, or already armed), or — when the player isn't attacking — only when this gang's respect for the player is **negative**, and even then only while no police are visible on screen. At **high respect** (≥80) a gang will proactively treat any law-enforcement or guard-type ped as a threat on the player's behalf. The basic/angry/hate **weapon** tier doesn't otherwise feed this decision — attack, ignore or assist runs on the rule above, independent of which weapon tier happens to be active.

One addition to `gangs-and-respect.md`: a kill is credited to gang respect not only for roaming gang members, but also for a background ped carrying an ambient reference to the gang that owns its spawn zone, when that zone's gang has its "kills affect respect" setting on — killing an unimportant extra standing on a gang's turf can still move that gang's respect, at the same weighting already documented.

### 3.14 Electro-fingers

While active (`power-ups-death-and-arrest.md`), every tick the player automatically shocks everyone within a fixed **0.5-block radius** of themself — no aiming, no direction restriction, unlike the aimed electro gun or baton. Each ped caught in range with a clear line of sight takes **3 damage** that tick, credited to the player, with a small arc drawn to it. This reuses the same underlying shock routine as the electro gun and baton (`weapons.md`), just running in an unaimed "hit everyone in range, every tick" mode instead of the gun's aimed, line-of-sight chain.

### 3.15 Invisibility

Mechanically this is one flag, checked in exactly one place in the threat rule (§3.3, rule 1): a ped that is invisible **and currently on foot** is unconditionally skipped — no AI ped, gang or law enforcement included, can ever select it as a threat or a target while that holds, with no "unless already engaged" or "unless point-blank" exception visible in the logic. Two details matter:

- The exemption only applies **on foot**. Riding in a car doesn't grant it (a ped in a car has no on-foot body to satisfy the check) — though being in a car already changes a lot of how threat-detection runs for other reasons, so this doesn't mean an invisible player in a car is just as noticeable as a visible one, only that this specific rule doesn't cover them then.
- A **separate check** makes an already-chasing ped give up the chase specifically when its target has gone invisible on foot, using the same underlying flag. So invisibility both stops new threats from forming and actively calls off anyone already on your tail.

## 4. Order of events (one ped, one tick)

1. Update the main objective's target and distance, and dispatch it (3.1).
2. If an internal objective is set, do the same for it; its handler can override what the main objective looks like.
3. Re-evaluate the attacker memory (3.6) and, for a group member, the group formation and tight-follow checks (3.11–3.12).
4. The chosen handler runs its own logic for the tick (flee, chase, attack, follow, melee, wait, etc.), which may read or write turning, speed and target state that the on-foot movement update (`ped-movement.md`) then applies.
5. Threat search and best-target search (3.3–3.4) run as needed by whichever handler called for them, rather than once per tick for every ped.

## 5. Numbers

| Value | Meaning | Source |
|---|---|---|
| 1/8 block | chase: full-stop distance | [exe] |
| 0.3125 / 0.375 / 0.5 block | chase: speed-tier breakpoints | [exe] |
| 3/16 block | follow: close-enough-to-stop distance | [exe] |
| 0.25 block | melee: distance at which a punch lands | [exe] |
| 0.5 block | electro-fingers radius; flamethrower/electro-baton back-off range; FBI/leader preferred melee range; follow walk/run speed switch | [exe] |
| 1, 1.5, 2, 2.5, 3 blocks | ranged attack fire/back-off ranges by weapon, and car-target overrides (table, §3.7) | [exe] |
| 4 blocks | pistol/MG/rocket fire range; best-target search distance cap; group "too far, abandon the fight" distance; instant-gang recruit search half-width | [exe] |
| 6 blocks | undirected-flee and flee-a-ped "far enough to maybe stop" distance | [exe] |
| 8 blocks | group tight-follow "still close enough" distance | [exe] |
| 9 | maximum members in a ped group (leader + followers) | [exe] |
| 4 | peds recruited by the instant-gang power-up | [exe] |
| 4 | "too many attackers on one target" throttle (current and total-ever, each capped) | [exe] |
| 10 | melee punch damage; mugger's score theft per mug | [exe] |
| 9 (count) | successful mugs before a mugger retires | [exe] |
| 20 | health below which a punch knocks the target down | [exe] |
| 200 ticks | follow: forced wait reset | [exe] |
| 5 ticks | player-led group: "attacker out of sight" tolerance before dropping it | [exe] |
| ~10° / ~16° | aim-jitter miss angles (small / large) | [exe] |
| 3 | electro-fingers damage per ped per tick | [exe] |
| 2 (count) | police on foot: minimum on-screen before any will open fire | [exe] |
| 1 (count) | police on foot: how many may be actively firing at once | [exe] |
| 80 | gang "high respect" threshold (shared with `gangs-and-respect.md`) | [exe] |

## 6. Edge cases and quirks worth reproducing

- **A ped tracks two goals at once** (main and internal); the internal one can make it look like it's ignoring its assigned job without actually cancelling it.
- **Crowds don't all pile on one victim:** a rival gang member backs off once a target already has 4 attackers on it (current or ever) — except a fully active ordinary gang member, which ignores the cap.
- **A friendly gang fights the police for you** once its respect for you is 80 or more.
- **Gangs defer to the police** when picking a fight with a merely-disliked (not outright attacking) player, but only while police are actually visible.
- **Cops take turns shooting** at a player on foot, and won't open fire at all below a 2-cop minimum presence.
- **A chasing ped visibly slows its final approach** rather than sprinting straight into melee range.
- **A mugger does zero damage** — only steals score and eventually stops forever.
- **Police can arrest you with a punch**, not only through the separate arrest mechanic.
- **A stationary group leader collapses its own formation**; movement is what holds the wedge together.
- **Recruiting can poach another ped's follower**, not just free-roaming civilians.
- **Invisibility is on-foot only** and also calls off an existing chase, not just new ones.
- **Electro-fingers needs no aim** — it is the electro gun/baton's shock effect running in an automatic, every-tick, no-targeting mode.

## 7. Open questions

- **Dead code:** the two "flee by any means" objective handlers (till-safe and always) do nothing. Confirm this is unused/cut content before an implementer spends time on it.
- **"Safe ground" for an undirected flee** (§3.5) is a specific ground type distinct from ordinary road; which map block types qualify needs checking in play. **[obs]**
- **Hit-and-run retreat after landing a hit** (§3.7): whether this applies to a given ped looks tied to a per-ped setting, not every ranged attacker; which peds do it needs checking in play. **[obs]**
- **Aim jitter's weapon range:** confirmed for pistols and machine guns; the exact boundary of which weapons get jitter versus always-accurate fire needs checking in play. **[obs]**
- **Why law enforcement won't use its heavier weapon on a stationary car with the player inside** — deliberate "don't shoot the car", or a side effect of something else. Flag as unclear.
- **Instant-gang recruit search shape:** read as a box roughly 4 blocks out from the player on each side, not a true radius; worth confirming against observed behaviour before an implementer treats it as one or the other. **[obs]**
- Line of sight cone half-angles for ordinary threat search (as opposed to the electro gun's own cone in `weapons.md`) were only confirmed at two specific values (a narrower default and a widened one for the most alert search mode); whether other search modes use other values wasn't pinned down.
- **Absolute heading convention** (cross-cutting, `README.md`) affects which way "facing" and the melee/attack cones point.
- **Animation frame timing** (cross-cutting, `README.md`) affects exactly how many ticks the melee and chase handlers wait between checks where this note says "every tick" at a coarse level.
- How cop crews actually approach and arrest once a pursuit is active, and how roadblocks are placed, belong to the police AI note, not yet written.
