# Weapons: firing, ammo and throwing

- **System:** What happens when someone fires each weapon: rate of fire, how many projectiles and in which directions, ammo use, throwing grenades and molotovs (charge, strength, fuse), the electro gun's chain lightning, the electro baton, vehicle weapons (car guns, tank, fire truck, oil, mines, car bombs), and the side effects of firing (crime reports, scared peds).
- **Out of scope (separate notes):** how a projectile flies and what damage it does on hitting (projectiles and objects note); explosions and fire (explosions note); how AI decides to shoot (ped AI note); weapon pickups and power-ups (pickups note).
- **Builds on:** `car-handling.md` (units, angles), `ped-movement.md` (ped speed and facing).
- **Sources read:** the decompilation's weapon firing code for every weapon type, its ammo bookkeeping, the player's throw-charge handling, and the weapon allocation tables.
- **Date and author:** 2026-11-19, Claude (notes writer, reader side).

Tags: **[exe]** fixed in the executable, **[obs]** to confirm in play.

---

## 1. What the player sees

The pistol fires a steady stream of single shots and the dual pistols twice as fast in a narrow V. The machine gun sprays. The shotgun fans five pellets. The rocket launcher is slow but devastating. Holding attack with a grenade or molotov winds up the throw, so a longer hold throws further. Hold a grenade too long and it blows up in your hand. The electro gun arcs lightning to up to two people or cars in front of you, then on to more beyond them. The flamethrower sprays a continuous stream. Cars with weapons fire forward guns, drop oil or mines, or arm a bomb.

## 2. Inputs

- **Controls:** attack (held to fire repeatedly; for throwables, held to charge and released to throw). Weapon cycling is in the HUD/pickups note.
- **Shooter state:** position, facing, aim angle (the facing unless an AI aims elsewhere), current velocity, and whether the shooter is the player.
- **Power-up:** the fast-reload power-up halves the wait after each shot.

## 3. Rules

### 3.1 Ammo bookkeeping

- Ammo is stored in tenths. The displayed count is `ceil(stored / 10)`.
- Most weapons spend 10 tenths (one displayed round) per trigger pull. The machine guns, silenced machine gun and flamethrower spend 1 tenth per shot, so the counter only drops every 10 shots.
- The maximum is 99 displayed rounds for every weapon except the car bomb, which holds 1 **[exe]**.
- A special "infinite" value never decreases.
- **Only the player uses up ammo.** AI peds fire forever.
- If a shot fails to spawn (see 3.2), no ammo is spent.

### 3.2 Spawning a shot

Each shot creates a projectile object. Its type depends on the weapon (projectiles note).

- **Start point:** the shooter's centre, moved forward along his facing by a weapon-specific offset: 1/4 block for pistols and the flamethrower. The machine gun starts slightly to one side and in front, plus the shooter's current velocity.
- **Initial movement:** the projectile also inherits the shooter's current velocity.
- **Wall check:** the point halfway between the shooter's centre and the start point is checked against walls. If it's inside a wall, the shot is cancelled. You can't shoot through a wall you're pressed against.
- **Ownership:** the projectile records who fired it, for kill credit.

### 3.3 Hand weapons

All timings are in ticks **[exe]**, and the fast-reload power-up halves each wait. Every real shot also:

- plays a muzzle flash;
- scares nearby peds;
- if the shooter is the player, files a "weapon fired" crime report (wanted-level note).

The silenced machine gun is the exception: it does neither of the last two.

| Weapon | Per trigger pull | Wait before the next |
|---|---|---|
| Pistol | 1 bullet straight ahead | 20 |
| Dual pistols | 2 bullets at ±12° | 10 |
| Machine gun / silenced | 1 bullet at the aim angle | 2 |
| Shotgun | 5 pellets at 0°, ±6°, ±12° | 40 |
| Rocket launcher | 1 rocket | 50 |
| Flamethrower | 1 flame particle per tick, continuously | none |
| Electro baton | 1 short-range spark | 20 |
| Electro gun | chain lightning (3.5), every tick held | none |

The player's pistol and dual-pistol bullets use a distinct (player) bullet type. AI uses the machine-gun bullet type for those weapons.

### 3.4 Throwing (grenade, molotov)

**Player:**

- **Charging.** While attack is held, a throw charge counts up by 1 per tick, to a maximum of 270. Throw **strength** = `min(charge, 60)`.
- **Release** throws at the current strength. Then there is a wait of 4 ticks for the player (50 for AI), halved by fast reload.
- **Grenade held too long.** If the charge reaches 96 while a grenade is held, it explodes in his hand: a small explosion at his position, credited to him, using one grenade.

**AI peds** throw with a fixed strength of 30 and charge of 45.

**The thrown object:**

- **Starts** half a block above the thrower, heading along the aim angle.
- **Horizontal speed:**
  - grenade: `0.01 + (strength / 60) × 0.12`
  - molotov: `0.02 + (strength / 60) × 0.1`

  If the thrower is moving forwards (not backing up), his velocity is added, plus a bonus of ≈0.051 **[exe]**.
- **Vertical:** starts rising at 0.1 per tick, with gravity of 1/512 per tick² **[exe]**.
- **Grenade fuse** is set from `(96 − charge) / 8` on the object's own timer (projectiles note). Holding longer means a shorter fuse after the throw.
- **Molotov** carries an orange light and a burning flame with it while in flight. On landing, it bursts into fire (explosions note).
- If the object would start inside a wall, nothing is thrown and no ammo is spent.

### 3.5 Electro gun (chain lightning)

Each tick it's fired:

1. **Look around the shooter.** Search a 4 × 4 block square centred on him, with a height range of ±1 level.
2. **Pick targets.** Each ped or car in that square is a target if all of these hold:
   - it lies within 45° either side of the shooter's facing;
   - a clear line of sight exists (a 0.1-block probe passes no walls);
   - it hasn't already been hit by this tick's lightning.
3. **Hit each target:**
   - an arc is drawn to it;
   - **a ped** gets +5 shock (ped damage note), is credited to the shooter, and is marked as attacked by him;
   - **a car** that isn't flameproof takes 300 raw damage (scaled by anti-strength as in `car-collision.md`). It is marked to explode credited to the shooter if it reaches the threshold, and its alarm goes off.
4. **Chain once.** From each target, repeat with a 2 × 2 block square centred on that target. The cone is now centred on the direction from the shooter to that target. The chain stops there (two hops at most) **[exe]**.

Hits are reported to the mission script system, which can watch for them.

### 3.6 Electro baton

Fires a short-range spark projectile every 20 ticks. Once it has latched onto a target ped, the next presses trace a beam to that ped instead. The latch breaks if the target is down or dead (for the player) or has gone. *(The beam's damage is in the projectile handling. [obs])*

### 3.7 Vehicle weapons

These belong to the car and are fired by its driver. Waits are in ticks **[exe]**.

| Weapon | Behaviour | Wait |
|---|---|---|
| Car machine guns | 2 bullets, from the car's left and right front | 2 |
| Army jeep gun | 1 bullet from the turret | 2 |
| Tank main gun | 1 rocket from the end of the turret barrel (30/64 block out) | 50 |
| Fire truck water cannon | water projectile from the turret, every tick | none |
| Fire truck flamethrower | flame from the turret, every tick | none |
| Oil slick | drops an oil patch behind the car, every other tick of ammo | none |
| Mines | drops a mine behind the car | none |
| Car bomb | arms the car's bomb; a trailer cab arms its trailer and unhitches it | one use |

The car bomb, oil, mines, tank gun and the instant car bomb can't be fired just by holding attack; they need a fresh press. All other weapons fire continuously while held.

Of the car weapons, only the car machine guns, tank gun, fire truck flamethrower and army jeep gun count as an "armed attack" for crime reporting. Hand weapons count only when fired on foot.

### 3.8 AI test shots

When an AI shooter's real shot hits someone other than its target (`projectiles.md` 3.2), its weapon switches to firing invisible "test" projectiles. These check whether a shot would reach the target, and use a short 5-tick wait (1 for machine guns). It switches back to real shots once a test projectile reaches the target. The shotgun's test spreads at 0, ±12° and ±24°. Test shots spend no ammo, make no flash and file no reports. AI throwers also fire one test shot before each real throw.

## 4. Order of events (one weapon, one tick)

1. If the wait timer is running, count it down and stop. Throwables also track the charge.
2. If the weapon doesn't auto-fire and the press isn't fresh, stop.
3. Spawn the projectile(s) with the wall check (3.2).
4. Spend ammo if the shooter is the player and something spawned.
5. Set the wait, halved by fast reload.
6. Muzzle flash, scare nearby peds, file a crime report (player only).

## 5. Numbers

| Value | Meaning | Source |
|---|---|---|
| 10 tenths | ammo per displayed round | [exe] |
| 99 (1 for car bomb) | maximum displayed rounds | [exe] |
| 20 / 10 / 2 / 40 / 50 | pistol / dual / machine gun / shotgun / rocket waits | [exe] |
| ±6°, ±12° | shotgun pellet angles | [exe] |
| ±12° | dual pistol angles | [exe] |
| 60, 96, 270 | max throw strength; grenade-explodes-in-hand charge; charge cap | [exe] |
| 1/512 | thrown-object gravity per tick² | [exe] |
| 4 × 4, 2 × 2 blocks; 45°; 2 hops | electro gun search squares, cone half-angle, chain depth | [exe] |
| +5 shock, 300 damage | electro gun effect on peds and cars | [exe] |

The default ammo given by each weapon pickup is a per-weapon table in the executable. Read it from observation or a future pickups note rather than copying it here.

## 6. Edge cases and quirks worth reproducing

- **Point-blank walls block shots** (the halfway check), and you aren't charged ammo.
- **AI has infinite ammo.**
- **Machine-gun ammo display** drops every 10 shots.
- **A grenade held too long blows up in your hand,** at charge 96, which is well before the 270 cap.
- **The longer you hold a grenade, the shorter its fuse after the throw.**
- **Moving throws go further,** by your own speed plus a fixed bonus, but only when moving forwards.
- **The electro gun ignores walls for its search** but needs line of sight to each target.

## 7. Open questions

- Projectile speeds, lifetimes and damage per hit for each bullet, rocket and flame type (projectiles and objects note).
- Exactly how AI chooses between test shots and real shots (ped AI note).
- The electro baton beam's damage and range.
