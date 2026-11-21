# Gaps filled from public sources

Research pass, 2026-11-21. It answers gaps the behaviour notes in `docs/behaviour/` leave open, using only public material: DMA's published format docs, community modding wikis and tutorials, and forum posts about how the game behaves in play. No page built from reverse-engineered code was used. Where an answer was checked against the player's own data files, it says so. Those checks were run locally and their data is not copied here; only the conclusion is.

Scope follows Jeff's steer: sound, police, traffic and drawing. Mission-script command coverage is out of scope for now.

Confidence levels:

- **High:** a primary doc says it, or a public source says it and the player's own data agrees.
- **Medium:** one community source, or a strong inference that fits the data.
- **Low:** a guess or a single forum remark. Check in play before relying on it.

## Sources

| Key | Source | What it is |
|---|---|---|
| STY | [GTA2 Style STY graphics file format](https://gtamp.com/gta2/gta2-style-sty-graphics-file-format/) | DMA's "GBH Style Format" v4.6, 16 Nov 1999 |
| WG-SCR | [Scripting manual (GTA2), WikiGTA](https://en.wikigta.org/wiki/Scripting_manual_(GTA2)) | DMA's scripting manual as a wiki page |
| CERB-SCR | [GTA2 Scripting Information, Project Cerbera](https://projectcerbera.com/gta/2/tutorials/scripting) | Another copy of DMA's scripting information |
| CERB-VEH | [Vehicles in GTA 2 Mission Scripts, Project Cerbera](https://projectcerbera.com/gta/2/tutorials/vehicles) | Script vehicle names, locks, trailers |
| WG-CRANE | [Cranes and crushers (GTA2), WikiGTA](https://en.wikigta.org/wiki/Cranes_and_crushers_(GTA2)) | Crane, crusher and conveyor tutorial |
| WG-ZONES | [Zones (GTA2), WikiGTA](https://en.wikigta.org/wiki/Zones_(GTA2)) | Map zone types |
| WG-LIGHT | [Lighting (GTA2), WikiGTA](https://en.wikigta.org/wiki/Lighting_(GTA2)) | Map lights in the editor |
| WG-OBJ | [Object, weapon and power-up placement (GTA2), WikiGTA](https://en.wikigta.org/wiki/Object,_weapon_and_power-up_placement_(GTA2)) | Script object names |
| WG-VEH | [Creating vehicles (GTA2), WikiGTA](https://en.wikigta.org/wiki/Creating_vehicles_(GTA2)) | Car sprites and deltas |
| GTW-VEH | [Vehicles in GTA 2, Grand Theft Wiki](https://www.grandtheftwiki.com/Vehicles_in_GTA_2) | Vehicle list with script codes |
| GTAMP-WEIRD | [Collection of gta scripting and map weirdness, GTAMP forum](https://www.gtamp.com/forum/viewtopic.php?p=5122) | Play-tested quirks |
| EPIC-LOG | [Epic GTA2 Map Editor changelog](https://gtamp.com/mapscript/_jed/03_compilation/extras/jed_pakx/workbench/EpicGTA2MapEditor066602/Changelog%20old.txt) | Third-party map editor notes |

## 1. Car model numbers for the special vehicles

**Answer.** Public sources give the script names but no numbers. The numbers follow the script names in alphabetical order, starting at 0. There are gaps at 9, 15, 20 and 43, where the unused names `CAR9`, `CAR15`, `CAR20` and `CAR43` sit. The wrecks `WRECK0` to `WRECK9` take 72 to 81. Three later additions come after `ZCX5` (83): `EDSELFBI` 84, `HOTDOG_D4` 85 and `KRSNABUS` 86.

The ones the open questions need:

| Kind | Script name | Model |
|---|---|---|
| Bus | `BUS` | 11 |
| Bus (gang car) | `KRSNABUS` | 86 |
| Tank | `TANK` | 54 |
| Fire truck | `FIRETRUK` | 17 |
| Police | `COPCAR` 12, `SWATVAN` 52, `EDSELFBI` 84, `APC` 3, `JEEP` 30, `GUNJEEP` 22 | |
| Ambulance | `MEDICAR` | 34 |
| Truck cabs | `TRUKCAB1` 63, `TRUKCAB2` 64 | |
| Trailers | `TANKER` 55, `TRUKCONT` 65, `TRUKTRNS` 66 (flatbed car transporter) | |
| Train | `BOXCAR` 6, `TRAIN` 59, `TRAINCAB` 60, `TRAINFB` 61 | |

**Sources.** Names, and which ones are emergency vehicles and public transport: CERB-VEH, GTW-VEH. The unused `CAR9`/`CAR15`/`CAR20`/`CAR43` names, which crash the game: GTAMP-WEIRD.

**Confidence: high.** The numbering is an inference, but the player's own style files (wil, ste, bil) agree on every point checked. Their car-info records cover 0 to 86 with exactly 9, 15, 20 and 43 missing. The flags also line up with the names: the cab bit is set only on 63 and 64 and the trailer bit only on 55, 65 and 66. Emergency lights are set on 12, 17, 34 and 52, with rear emergency lights only on 34. For-hire lights are set on 51 (`STYPECAB`) and 56 (`TAXI`), and the roof decal on 19 (`GT24640`, the roof-number car) and 67 (`TVVAN`). Pop-up headlights are set on 46 (`STINGRAY`). The four train models have no doors.

## 2. Which cars count as heavy

**Answer.** The public style doc has no flag called "heavy". The match is `info_flags_2` bit 0, `collide_over`, which the doc describes as "1 if this car can drive over other cars". In all three of the player's style files, only model 54 (`TANK`) has it. Treat "heavy" in `car-collision.md` and `shape-and-map-collision.md` as this bit.

`EDSELFBI` (84) has `info_flags_2` bit 2 set, which the current doc doesn't list. The doc's revision history says an FBI flag was added in 3.8 and removed in 3.9, so this is probably a leftover. Nothing should depend on it.

**Sources.** STY (car_info, info_flags_2). GTW-VEH lists the tank as "Uncrushable".

**Confidence: medium-high.** The bit's meaning comes from DMA's doc, and the tank is the only car anyone has seen climbing other cars. That the behaviour notes' "heavy" is this exact bit is still an inference.

## 3. Car info flags

**Answer.** Bits of `info_flags`, from the doc:

| Bit | Name | Meaning |
|---|---|---|
| 0x01 | ped_jump | too high for a ped to jump over |
| 0x02 | emerg_lights | has emergency lights (police car) |
| 0x04 | roof_lights | roof lights that come on with the headlights |
| 0x08 | cab | can be an artic cab |
| 0x10 | trailer | can be an artic trailer |
| 0x20 | forhire_lights | taxi light |
| 0x40 | roof_decal | roof decal (TV van; the roof-number car) |
| 0x80 | rear_emerg_lights | rear emergency lights (needs emerg_lights too) |

In `info_flags_2`, 0x01 is `collide_over` (see section 2) and 0x02 is `popup` (pop-up headlights). The doc's rules: a car has at most one of emerg, roof, for-hire lights and roof decal. No car is both cab and trailer.

`rating` sets how often a model spawns in traffic, in steps: 1–3 bad, 11–13 average, 21–23 good, and 99 never recycled into traffic. `wreck` is the wreck graphic, 0–8, or 99 for a car that can't be wrecked.

Car drawing, also from STY: deltas 5/22 are the brake lights, 6/23 the headlights, 7–14 and 24–31 the door frames, 15 the emergency lights, roof lights or decal, and 16–18 the emergency light frames. Deltas 22–31 are mirror images and aren't stored in the file. The racing car's roof numbers use deltas 11–20. If a door's `rx` is beyond ±64, peds walk straight in. Train sliding doors use this.

**Sources.** STY. Roof-number deltas: STY and WG-VEH.

**Confidence: high.**

## 4. Script car flags: proofing, locks, alarm, siren, jammed accelerator

**Answer.**

- `SET_CAR_BULLETPROOF (car, ON|OFF)`: no bullet damage. Rockets and nearby explosions still hurt it.
- `SET_CAR_ROCKETPROOF`: no damage from direct rockets, molotovs or small explosions. A car bomb going off very close still blows it up.
- `SET_CAR_FLAMEPROOF`: no flame damage.
- `CHANGE_CAR_LOCK (car, type)` takes one of six lock types:

  | Type | Meaning |
  |---|---|
  | `NO_LOCK` | not locked |
  | `LOCKED` | nobody can get in, players included |
  | `UNLOCKED` | open to everyone |
  | `LOCKED_PERMANENTLY` | always locked, for everyone |
  | `LOCKOUT_THIEF_ONLY` | AI thieves can't get in; the default for created cars |
  | `LOCKOUT_PLAYER` | players can't get in |

  This answers the "locked against AI thieves vs locked against the player" question in `script-cars.md`, but only at the level of who can get in.
- `GIVE_CAR_ALARM (car)`: the alarm rings if the car is stolen or shot.
- `SET_CAR_EMERG_LIGHTS (car, ON|OFF)` switches the siren and lights, and `ARE_EMERG_LIGHTS_ON (car)` tests them. There's no separate siren command.
- `SET_CAR_JAMMED_ACCELERATOR (car, ON|OFF)`: the accelerator sticks on and the player can't slow down. No source says AI cars read it.
- `SET_CAR_NUMBER_GRAPHIC` sets the roof number (only the name is public).
- `CHECK_CAR_DAMAGE_POSITION` takes `FRONT_LEFT`, `FRONT_RIGHT`, `BACK_LEFT`, `BACK_RIGHT` or `WINDOW`. These are quarters plus the windscreen, not front/back/left/right.

**Sources.** Proofing, alarm, emergency lights, jammed accelerator and damage position: WG-SCR. Lock types: CERB-VEH. Command names: CERB-SCR.

**Confidence: high** for what each flag does. **Low** for how a locked door looks to someone trying to get in; no source covers that.

## 5. Trailers and towing

**Answer.**

- A trailer is attached at load by giving a trailer model after the car model: `CAR_DATA name = (x, y, z) remap rotation MODEL TRAILERMODEL`. The cab goes at the given position. Cerbera's example uses `TRUKCAB2 TANKER`.
- Sources disagree on `PARKED_CAR_DATA`. Cerbera's vehicles page says it takes a trailer. Cerbera's scripting page and a play-tested forum note say it ignores the trailer, so use `CAR_DATA`.
- The trailer model `MINI_CAR` makes a small remote-control-style car.
- `PUT_CAR_ON_TRAILER (car, trailer)` puts a car on a `TRUKTRNS` flatbed and attaches it. `IS_TRAILER_ATTACHED (car, trailer)` with the same name twice matches any trailer. `IS_CAR_ON_TRAILER (car, transporter)` also exists.
- From play:
  - Only `TRUKCAB1` and `TRUKCAB2` tow most trailers at full speed.
  - Getting into an attached trailer crashes the game. Players can't enter a container trailer anyway.
  - A towing car with a gun selected won't detach until the player switches to a non-vehicle weapon.
  - Detaching a towed tank makes it roll over the car that was towing it and destroy it.
- A third-party map editor notes that any car model can be a trailer, and `TRUKTRNS` can carry another car on top.

**Sources.** WG-SCR (declaration form, `MINI_CAR`, the trailer commands). CERB-VEH and CERB-SCR (`PARKED_CAR_DATA`). GTAMP-WEIRD (behaviour in play). EPIC-LOG (any model as trailer).

**Confidence: medium.** The declaration side is solid. The towing physics (hitch point, how the trailer follows, jack-knifing) is **still open**, with no public description.

## 6. Cranes

**Answer.**

- `CRANE_DATA name = (x, y) rotation NO_HOMECRANE|home_crane [FIRST (tx, ty) rot] [SECOND (tx, ty) rot]`.
- A basic crane (no targets) moves cars to or from a transporter.
- `FIRST` is where the grabbed car is dropped, for example into a crusher, with rotation 0 or 180.
- `SECOND` is where a second, linked crane drops the wreck, usually onto a conveyor. The link is the second crane naming the first.
- `DECLARE_CRANE_POWERUP (crane, generator, x, y, z)` sets a scanner that fires the reward generator. `DECLARE_POWERUP_CARLIST` sets which crushed models give which reward. A level can script at most ten cranes.
- From play, a crane's reach is a square 4 blocks out from it, not a circle.

**Sources.** WG-CRANE, CERB-SCR, GTAMP-WEIRD.

**Confidence: medium.** Grab and release timing, hook speeds and swing are **still open**; no public source gives numbers.

## 7. How conveyor belts are stored

**Answer.** They aren't in the `.gmp` at all. A conveyor is a declaration in the level script: `CONVEYOR name = (x, y[, z]) (width, height) speedX speedY`, a rectangle with a push speed. The moving look comes from map tiles with a tile animation in the map's animation data. WikiGTA names the conveyor tiles in wil's style and gives their frame rate.

The two sources disagree on the speed values. Cerbera says pixels moved per game cycle, positive right/down. WikiGTA's example uses -1, 0 or 1 as a direction. Both fit "signed speed per axis", so read the value as-is from the player's script.

The runtime form `CREATE_CONVEYOR` did nothing when tested in play, which matches the dead runtime forms in `script-objects.md`.

**Sources.** CERB-SCR, WG-CRANE, GTAMP-WEIRD. EPIC-LOG lists `CONVEYOR` as a script object with its own sound range.

**Confidence: high** that conveyors live in the script. **Medium** on the speed unit.

## 8. Door animation frames (type 230)

**Answer.** `DECLARE_DOOR_INFO (startframe, endframe, speed)`. The start frame is the tile the door shows at first (closed), the end frame is the tile it shows when fully open, and speed is the animation speed, usually 1.

`DOOR_DATA` picks one of these by its index (`gfx_id`, in declaration order):

```
DOOR_DATA name = SINGLE|DOUBLE (x, y, z) (check area) FACE gfx_id OPEN_TYPE CLOSE_TYPE delay FLIP REVERSE
```

- `FACE`: `TOP` is north, `BOTTOM` south, `LEFT` west and `RIGHT` east.
- `DOUBLE` adds the second block clockwise.
- Open types: `ANY_PLAYER`, `ANY_CAR`, `ONE_CAR`, `ONE_MODEL`, `ONE_CHAR_ON_FOOT`, `ANY_PLAYER_ONE_CAR`.
- Close types: `CLOSE_NEVER`, `CLOSE_TIME_DELAY` (uses `delay`, 0–255), `CLOSE_WHEN_CLEAR`, `CLOSE_WHEN_OPEN_RULE_FAILS`.
- From play, garage doors pull a lined-up car in, and doors don't close while something stands in the check area.

The frames count **tiles**: the door face's tile steps from start to end. The sources don't say whether that's the raw tile number or relative to some base. The values A2's tests take from the levels (928–935) sit just below the style format's tile 992–1023 range, which the game keeps for its own animations, so raw tile numbers are the likely reading.

**Sources.** CERB-SCR. STY (reserved tile range).

**Confidence: medium.** "Tile, not sprite" is stated. "Raw tile number" is an inference; check it by drawing the frames.

## 9. Lamps and traffic lights: objects, sprites, colours

**Answer, partial.**

- **Traffic lights.** These are a map zone type, "Traffic Light", placed on a valid junction. The zone must not cover slopes and must be at least a screen from other lights. The mapper builds the poles as map blocks, "or else the traffic lights will float in the air", so the game draws the lamp heads itself at the zone. The script object `TRAFFIC_LIGHT` also exists, but a placed one stays on red.
- **Street lamps.** No public source describes lamp objects. The glow comes from map lights, which the editor places as markers with colour, intensity, radius and an optional flash timing. Script lights (`DECLARE_LIGHT`, `CHANGE_INTENSITY`, `CHANGE_COLOUR`, `CHANGE_RADIUS`) exist by name. `CHANGE_INTENSITY` takes integers.
- **Phones**, since the colour question overlaps: `PHONE` is blue, plus `GREEN_PHONE`, `YELLOW_PHONE` and `RED_PHONE`. This helps with the "which phone models are gang phones" question in `script-objects.md`.

**Still open:** which object model numbers and sprites the lamp heads use, and which sprite is red, amber or green. The public style doc gives only a sprite count per object model and the sprite base order (car, ped, code_obj, map_obj, user, font). Traffic-light heads are likely code objects, which have no OBJI entry. The way to settle this is to draw the code_obj and map_obj sprites from the player's style file on the bench page and match them by eye.

**Sources.** WG-ZONES, WG-OBJ, WG-LIGHT, STY, GTAMP-WEIRD.

**Confidence:** medium for the zone and pole setup; the sprite mapping is still open.

## 10. Other finds for traffic, police and sound

**Buses.** Buses have no route. They appear near bus stops when the player is near and stop at every bus stop zone (WG-ZONES). A bus holds up to 10 passengers (WG-SCR). `STOP_CHARS_GETTING_OFF_BUS` switches getting off (WG-SCR). The style files give `BUS` and `KRSNABUS` 30 seats, so the cap of 10 comes from the game, not the style data. **Medium.**

**Zone types** (WG-ZONES): General Purpose, Navigation, Traffic Light, Police Station, Fire Station, Hospital, Railway Station (platform), Bus Stop, General Trigger, Information, Railway Entry, Exit and Stop Points, Gang, Local Navigation, Restart, Arrest Restart. Where navigation zones overlap, the smaller one wins, and Local Navigation beats Navigation. **High.**

**Traffic and police density.** These come from the script's `MAP_ZONE` declarations (CERB-SCR), not the map:

```
MAP_ZONE name = (car_density, good_car_ratio, bad_car_ratio, police_car_ratio,
                 ped_density, mugger_ratio, carthief_ratio, elvis_ratio,
                 gang_char_ratio, police_ped_ratio, gang_car_ratio)
```

Densities run 0–1000. The car ratios add up to 1000, and whatever is left over is "average" cars. Car ratings (section 3) decide which models count as good, average or bad. `SUPPRESS_THIS_CAR_MODEL` stops a model spawning (CERB-VEH). **High.**

**AI drive tuning.** `SET_CHAR_DRIVE_AGGRESSION ON` makes a driver ignore traffic lights and speed limits. `SET_CHAR_MAX_DRIVESPEED` is sensible from 0.0 to 0.4 and is capped by the car's top speed (WG-SCR). **High.**

**Arrows.** The script arrow (`ARROW_DATA`, `POINT_ARROW_AT`, `REMOVE_ARROW`) can be pointed at a car, character, object or point. The page says the maximum is "around 4–6 arrows" (CERB-SCR). This matters for showing other players' directions. **Medium.**

**Crash and quirk list from play** (GTAMP-WEIRD): `TRAIN*`, `BOXCAR` and `CAR9/15/20/43` crash when created. `HOTDOG_D1–4` crash once wrecked, and `WRECK0–9` crash if destroyed. `GIVE_WEAPON` on a car always gives 50. These are worth guarding against if peers can load arbitrary scripts. **Medium.**

## Still open after this pass

- Traffic-light and lamp sprite numbers and colours (section 9). Settle it from the player's style data on the bench.
- Towing physics: how a trailer follows its cab (section 5).
- Crane movement speeds and grab/release timing (section 6).
- Whether door frames are raw tile numbers (section 8). Settle it by drawing them.
- What the undocumented `info_flags_2` bit 2 on `EDSELFBI` does (section 2). Probably nothing.
- No public source covers the fire truck water cannon, tank turret aim, or what a locked door looks like to someone trying to get in.
