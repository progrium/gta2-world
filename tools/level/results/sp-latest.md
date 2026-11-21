# Level runner results: single player

Written by `tools/level --sp` (workstream Q). Each level runs its own script in the `sp` configuration for 30000 ticks, seed 1e7e1. The autopilot follows the mission arrow, else the last phone that rang, else road waypoints; it is teleported to its target after 1800 ticks.

## bil.gmp

- scripts: main plus 22 mission sub-scripts; up to 2 threads live
- ran 30000 ticks
- missions: 0 started, 0 passed, 0 failed; phones rang 0 times
- player: wasted 2, busted 0; arrow shown 1 ticks; teleports 13
- unhandled commands met: 201
- threads on one command for 3000+ ticks: 0
- step: mean 0.0794 ms, p99 0.1131 ms, max 0.8106 ms
- invariant breaks: 0

```
invariants: 30000 ticks checked, 0 breaks
ticks 30000
kills 2
player_kills 0
run_over 1
fire_kills 1
suicides 0
explosions 2
pickups 1
rounds 0
shots 0
shot_hits 0
ped_deaths 57
car_wrecks 2
boardings 18
exits 15
contacts 57512
impacts 1352
wall_hits 15381
driven 1205
walked 69
ticks_in_cars 25360
score_total 486
max_kills 0
max_deaths 2
final_cars 97
final_peds 102
```

## lorne2e.gmp

- scripts: main plus 0 mission sub-scripts; up to 1 threads live
- ran 30000 ticks
- missions: 0 started, 0 passed, 0 failed; phones rang 0 times
- player: wasted 2, busted 0; arrow shown 0 ticks; teleports 13
- unhandled commands met: 328
- threads on one command for 3000+ ticks: 0
- step: mean 0.0758 ms, p99 0.1088 ms, max 2.5301 ms
- invariant breaks: 0

```
invariants: 30000 ticks checked, 0 breaks
ticks 30000
kills 2
player_kills 0
run_over 1
fire_kills 1
suicides 0
explosions 1
pickups 17
rounds 0
shots 0
shot_hits 0
ped_deaths 94
car_wrecks 1
boardings 23
exits 17
contacts 137307
impacts 1580
wall_hits 11937
driven 1272
walked 59
ticks_in_cars 27536
score_total -172198
max_kills 0
max_deaths 2
final_cars 55
final_peds 166
```

## lorne2h.gmp

- scripts: main plus 0 mission sub-scripts; up to 1 threads live
- ran 2408 ticks, ended in game over
- missions: 0 started, 0 passed, 0 failed; phones rang 0 times
- player: wasted 3, busted 0; arrow shown 1988 ticks; teleports 1
- unhandled commands met: 354
- threads on one command for 3000+ ticks: 0
- step: mean 0.0526 ms, p99 0.0771 ms, max 0.1442 ms
- invariant breaks: 0

```
invariants: 2408 ticks checked, 0 breaks
ticks 2408
kills 4
player_kills 0
run_over 0
fire_kills 4
suicides 0
explosions 0
pickups 0
rounds 0
shots 0
shot_hits 0
ped_deaths 13
car_wrecks 13
boardings 5
exits 1
contacts 3595
impacts 173
wall_hits 10641
driven 11
walked 25
ticks_in_cars 1986
score_total -69000
max_kills 0
max_deaths 4
final_cars 61
final_peds 166
```

## lorne2m.gmp

- scripts: main plus 0 mission sub-scripts; up to 1 threads live
- ran 30000 ticks
- missions: 0 started, 0 passed, 0 failed; phones rang 0 times
- player: wasted 2, busted 0; arrow shown 0 ticks; teleports 15
- unhandled commands met: 333
- threads on one command for 3000+ ticks: 0
- step: mean 0.0634 ms, p99 0.1132 ms, max 2.1829 ms
- invariant breaks: 0

```
invariants: 30000 ticks checked, 0 breaks
ticks 30000
kills 2
player_kills 0
run_over 2
fire_kills 0
suicides 0
explosions 5
pickups 16
rounds 0
shots 0
shot_hits 0
ped_deaths 65
car_wrecks 5
boardings 18
exits 12
contacts 84492
impacts 1337
wall_hits 21442
driven 991
walked 76
ticks_in_cars 23235
score_total -172363
max_kills 0
max_deaths 2
final_cars 53
final_peds 166
```

## mike1e.gmp

- scripts: main plus 0 mission sub-scripts; up to 1 threads live
- ran 30000 ticks
- missions: 0 started, 0 passed, 0 failed; phones rang 0 times
- player: wasted 2, busted 0; arrow shown 0 ticks; teleports 15
- unhandled commands met: 414
- threads on one command for 3000+ ticks: 0
- step: mean 0.0104 ms, p99 0.0288 ms, max 0.0922 ms
- invariant breaks: 0

```
invariants: 30000 ticks checked, 0 breaks
ticks 30000
kills 2
player_kills 0
run_over 1
fire_kills 1
suicides 0
explosions 1
pickups 0
rounds 0
shots 0
shot_hits 0
ped_deaths 7
car_wrecks 1
boardings 19
exits 17
contacts 17809
impacts 113
wall_hits 15146
driven 838
walked 53
ticks_in_cars 25887
score_total 95287
max_kills 0
max_deaths 2
final_cars 5
final_peds 21
```

## mike1h.gmp

- scripts: main plus 0 mission sub-scripts; up to 1 threads live
- ran 30000 ticks
- missions: 0 started, 0 passed, 0 failed; phones rang 0 times
- player: wasted 2, busted 0; arrow shown 89 ticks; teleports 12
- unhandled commands met: 406
- threads on one command for 3000+ ticks: 0
- step: mean 0.0098 ms, p99 0.0324 ms, max 2.4435 ms
- invariant breaks: 0

```
invariants: 30000 ticks checked, 0 breaks
ticks 30000
kills 2
player_kills 0
run_over 0
fire_kills 2
suicides 0
explosions 0
pickups 2
rounds 0
shots 0
shot_hits 0
ped_deaths 6
car_wrecks 5
boardings 11
exits 9
contacts 9554
impacts 59
wall_hits 11786
driven 705
walked 93
ticks_in_cars 22761
score_total 95145
max_kills 0
max_deaths 2
final_cars 6
final_peds 21
```

## mike1m.gmp

- scripts: main plus 0 mission sub-scripts; up to 1 threads live
- ran 11340 ticks, ended in game over
- missions: 0 started, 0 passed, 0 failed; phones rang 0 times
- player: wasted 3, busted 0; arrow shown 0 ticks; teleports 5
- unhandled commands met: 406
- threads on one command for 3000+ ticks: 0
- step: mean 0.0137 ms, p99 0.0534 ms, max 0.0936 ms
- invariant breaks: 0

```
invariants: 11340 ticks checked, 0 breaks
ticks 11340
kills 4
player_kills 0
run_over 0
fire_kills 4
suicides 0
explosions 0
pickups 0
rounds 0
shots 0
shot_hits 0
ped_deaths 6
car_wrecks 35
boardings 8
exits 6
contacts 2330
impacts 32
wall_hits 4440
driven 204
walked 42
ticks_in_cars 6760
score_total 95045
max_kills 0
max_deaths 4
final_cars 6
final_peds 26
```

## mike2e.gmp

- scripts: main plus 0 mission sub-scripts; up to 1 threads live
- ran 30000 ticks
- missions: 0 started, 0 passed, 0 failed; phones rang 0 times
- player: wasted 2, busted 0; arrow shown 0 ticks; teleports 10
- unhandled commands met: 157
- threads on one command for 3000+ ticks: 0
- step: mean 0.0794 ms, p99 0.2667 ms, max 0.7066 ms
- invariant breaks: 0

```
invariants: 30000 ticks checked, 0 breaks
ticks 30000
kills 2
player_kills 0
run_over 0
fire_kills 2
suicides 0
explosions 6
pickups 2
rounds 0
shots 0
shot_hits 0
ped_deaths 2
car_wrecks 0
boardings 0
exits 0
contacts 57186
impacts 0
wall_hits 0
driven 0
walked 914
ticks_in_cars 0
score_total 0
max_kills 0
max_deaths 2
final_cars 0
final_peds 166
```

## mike2h.gmp

- scripts: main plus 0 mission sub-scripts; up to 1 threads live
- ran 20999 ticks, ended in game over
- missions: 0 started, 0 passed, 0 failed; phones rang 0 times
- player: wasted 3, busted 0; arrow shown 0 ticks; teleports 2
- unhandled commands met: 160
- threads on one command for 3000+ ticks: 0
- step: mean 0.0725 ms, p99 0.2395 ms, max 0.4434 ms
- invariant breaks: 0

```
invariants: 20999 ticks checked, 0 breaks
ticks 20999
kills 4
player_kills 0
run_over 0
fire_kills 4
suicides 0
explosions 6
pickups 3
rounds 0
shots 0
shot_hits 0
ped_deaths 4
car_wrecks 0
boardings 0
exits 0
contacts 92420
impacts 0
wall_hits 0
driven 0
walked 1112
ticks_in_cars 0
score_total 0
max_kills 0
max_deaths 4
final_cars 0
final_peds 166
```

## mike2m.gmp

- scripts: main plus 0 mission sub-scripts; up to 1 threads live
- ran 30000 ticks
- missions: 0 started, 0 passed, 0 failed; phones rang 0 times
- player: wasted 3, busted 0; arrow shown 0 ticks; teleports 4
- unhandled commands met: 160
- threads on one command for 3000+ ticks: 0
- step: mean 0.0717 ms, p99 0.2365 ms, max 0.9807 ms
- invariant breaks: 0

```
invariants: 30000 ticks checked, 0 breaks
ticks 30000
kills 3
player_kills 0
run_over 0
fire_kills 2
suicides 0
explosions 6
pickups 2
rounds 0
shots 0
shot_hits 0
ped_deaths 3
car_wrecks 0
boardings 0
exits 0
contacts 189426
impacts 0
wall_hits 0
driven 0
walked 1525
ticks_in_cars 0
score_total 0
max_kills 0
max_deaths 3
final_cars 0
final_peds 166
```

## ste.gmp

- scripts: main plus 22 mission sub-scripts; up to 1 threads live
- ran 30000 ticks
- missions: 0 started, 0 passed, 0 failed; phones rang 0 times
- player: wasted 3, busted 0; arrow shown 1 ticks; teleports 15
- unhandled commands met: 1655
- threads on one command for 3000+ ticks: 0
- step: mean 0.0877 ms, p99 0.1600 ms, max 0.7441 ms
- invariant breaks: 0

```
invariants: 30000 ticks checked, 0 breaks
ticks 30000
kills 3
player_kills 0
run_over 1
fire_kills 2
suicides 0
explosions 2
pickups 4
rounds 0
shots 6
shot_hits 2
ped_deaths 22
car_wrecks 2
boardings 11
exits 8
contacts 648308
impacts 1575
wall_hits 17374
driven 1014
walked 34
ticks_in_cars 29194
score_total 840458
max_kills 0
max_deaths 3
final_cars 194
final_peds 43
```

## wil.gmp

- scripts: main plus 23 mission sub-scripts; up to 1 threads live
- ran 30000 ticks
- missions: 0 started, 0 passed, 0 failed; phones rang 0 times
- player: wasted 1, busted 0; arrow shown 1 ticks; teleports 15
- unhandled commands met: 30375
- threads on one command for 3000+ ticks: 1
  - thread 1 at command 795 (type 77), noticed at tick 3005
- step: mean 0.0720 ms, p99 0.0986 ms, max 0.2097 ms
- invariant breaks: 0

```
invariants: 30000 ticks checked, 0 breaks
ticks 30000
kills 1
player_kills 0
run_over 0
fire_kills 1
suicides 0
explosions 1
pickups 2
rounds 0
shots 0
shot_hits 0
ped_deaths 43
car_wrecks 1
boardings 10
exits 8
contacts 19194
impacts 1982
wall_hits 13737
driven 970
walked 103
ticks_in_cars 25864
score_total 530
max_kills 0
max_deaths 1
final_cars 82
final_peds 71
```

