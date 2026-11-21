# Level runner results: single player

Written by `tools/level --sp` (workstream Q). Each level runs its own script in the `sp` configuration for 30000 ticks, seed 1e7e1. The autopilot follows the mission arrow, else the last phone that rang, else road waypoints; it is teleported to its target after 1800 ticks.

## bil.gmp

- scripts: main plus 22 mission sub-scripts; up to 3 threads live
- ran 30000 ticks
- missions: 1 started, 0 passed, 1 failed; phones rang 0 times
- player: wasted 1, busted 0; arrow shown 1 ticks; teleports 9; phones stood at 13
- unhandled commands met: 201
- threads on one command for 3000+ ticks: 0
- step: mean 0.0520 ms, p99 0.1515 ms, max 0.4435 ms
- invariant breaks: 0
- mission log:
  - tick 1803: mission started
  - tick 14552: mission failed after 12749 ticks

```
invariants: 30000 ticks checked, 0 breaks
ticks 30000
kills 1
player_kills 0
run_over 0
fire_kills 1
suicides 0
explosions 0
pickups 1
rounds 0
shots 0
shot_hits 0
ped_deaths 6
car_wrecks 0
boardings 4
exits 3
contacts 123072
impacts 981
wall_hits 23877
driven 224
walked 109
ticks_in_cars 21195
score_total 141
max_kills 0
max_deaths 1
final_cars 72
final_peds 42
```

## lorne2e.gmp

- scripts: main plus 0 mission sub-scripts; up to 1 threads live
- ran 30000 ticks
- missions: 0 started, 0 passed, 0 failed; phones rang 0 times
- player: wasted 3, busted 0; arrow shown 0 ticks; teleports 12; phones stood at 0
- unhandled commands met: 346
- threads on one command for 3000+ ticks: 0
- step: mean 0.0853 ms, p99 0.1391 ms, max 0.1839 ms
- invariant breaks: 3

```
invariants: 30000 ticks checked, 3 breaks
  riding: 3
  first: riding tick 12950 id 0001100c at (0.00, 0.00, 0.00)
  first: riding tick 14632 id 000010aa at (0.00, 0.00, 0.00)
  first: riding tick 17481 id 000010ac at (0.00, 0.00, 0.00)
ticks 30000
kills 3
player_kills 0
run_over 1
fire_kills 0
suicides 0
explosions 3
pickups 20
rounds 0
shots 48
shot_hits 40
ped_deaths 116
car_wrecks 3
boardings 28
exits 23
contacts 196345
impacts 2626
wall_hits 15390
driven 1249
walked 77
ticks_in_cars 27323
score_total -172381
max_kills 0
max_deaths 3
final_cars 59
final_peds 176
```

## lorne2h.gmp

- scripts: main plus 0 mission sub-scripts; up to 1 threads live
- ran 909 ticks, ended in game over
- missions: 0 started, 0 passed, 0 failed; phones rang 0 times
- player: wasted 3, busted 0; arrow shown 200 ticks; teleports 0; phones stood at 0
- unhandled commands met: 372
- threads on one command for 3000+ ticks: 0
- step: mean 0.0583 ms, p99 0.0812 ms, max 0.1047 ms
- invariant breaks: 0

```
invariants: 909 ticks checked, 0 breaks
ticks 909
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
ped_deaths 10
car_wrecks 17
boardings 6
exits 4
contacts 1990
impacts 196
wall_hits 1968
driven 49
walked 23
ticks_in_cars 312
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
- player: wasted 2, busted 0; arrow shown 0 ticks; teleports 15; phones stood at 0
- unhandled commands met: 353
- threads on one command for 3000+ ticks: 0
- step: mean 0.0698 ms, p99 0.1176 ms, max 0.2030 ms
- invariant breaks: 0

```
invariants: 30000 ticks checked, 0 breaks
ticks 30000
kills 2
player_kills 0
run_over 2
fire_kills 0
suicides 0
explosions 2
pickups 13
rounds 0
shots 43
shot_hits 0
ped_deaths 65
car_wrecks 2
boardings 21
exits 19
contacts 105718
impacts 1597
wall_hits 28336
driven 849
walked 105
ticks_in_cars 22380
score_total -172432
max_kills 0
max_deaths 2
final_cars 56
final_peds 173
```

## mike1e.gmp

- scripts: main plus 0 mission sub-scripts; up to 1 threads live
- ran 30000 ticks
- missions: 0 started, 0 passed, 0 failed; phones rang 0 times
- player: wasted 1, busted 0; arrow shown 0 ticks; teleports 14; phones stood at 0
- unhandled commands met: 414
- threads on one command for 3000+ ticks: 0
- step: mean 0.0094 ms, p99 0.0266 ms, max 0.0950 ms
- invariant breaks: 0

```
invariants: 30000 ticks checked, 0 breaks
ticks 30000
kills 1
player_kills 0
run_over 0
fire_kills 1
suicides 0
explosions 0
pickups 5
rounds 0
shots 0
shot_hits 0
ped_deaths 7
car_wrecks 0
boardings 34
exits 32
contacts 14895
impacts 8
wall_hits 18645
driven 945
walked 40
ticks_in_cars 28609
score_total 95155
max_kills 0
max_deaths 1
final_cars 6
final_peds 20
```

## mike1h.gmp

- scripts: main plus 0 mission sub-scripts; up to 1 threads live
- ran 30000 ticks
- missions: 0 started, 0 passed, 0 failed; phones rang 0 times
- player: wasted 3, busted 0; arrow shown 89 ticks; teleports 14; phones stood at 0
- unhandled commands met: 406
- threads on one command for 3000+ ticks: 0
- step: mean 0.0091 ms, p99 0.0309 ms, max 0.0996 ms
- invariant breaks: 0

```
invariants: 30000 ticks checked, 0 breaks
ticks 30000
kills 3
player_kills 0
run_over 0
fire_kills 3
suicides 0
explosions 0
pickups 3
rounds 0
shots 0
shot_hits 0
ped_deaths 5
car_wrecks 4
boardings 16
exits 14
contacts 6270
impacts 45
wall_hits 11010
driven 692
walked 106
ticks_in_cars 22130
score_total 95216
max_kills 0
max_deaths 3
final_cars 5
final_peds 22
```

## mike1m.gmp

- scripts: main plus 0 mission sub-scripts; up to 1 threads live
- ran 8869 ticks, ended in game over
- missions: 0 started, 0 passed, 0 failed; phones rang 0 times
- player: wasted 3, busted 0; arrow shown 0 ticks; teleports 4; phones stood at 0
- unhandled commands met: 390
- threads on one command for 3000+ ticks: 0
- step: mean 0.0181 ms, p99 0.0601 ms, max 0.1122 ms
- invariant breaks: 0

```
invariants: 8869 ticks checked, 0 breaks
ticks 8869
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
car_wrecks 31
boardings 7
exits 5
contacts 33976
impacts 153
wall_hits 6102
driven 168
walked 74
ticks_in_cars 4949
score_total 95046
max_kills 0
max_deaths 4
final_cars 5
final_peds 24
```

## mike2e.gmp

- scripts: main plus 0 mission sub-scripts; up to 1 threads live
- ran 30000 ticks
- missions: 0 started, 0 passed, 0 failed; phones rang 0 times
- player: wasted 2, busted 0; arrow shown 0 ticks; teleports 10; phones stood at 0
- unhandled commands met: 157
- threads on one command for 3000+ ticks: 0
- step: mean 0.0769 ms, p99 0.2600 ms, max 1.0859 ms
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
- player: wasted 3, busted 0; arrow shown 0 ticks; teleports 2; phones stood at 0
- unhandled commands met: 160
- threads on one command for 3000+ ticks: 0
- step: mean 0.0702 ms, p99 0.2366 ms, max 0.9442 ms
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
- player: wasted 3, busted 0; arrow shown 0 ticks; teleports 4; phones stood at 0
- unhandled commands met: 160
- threads on one command for 3000+ ticks: 0
- step: mean 0.0681 ms, p99 0.2206 ms, max 0.4128 ms
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

- scripts: main plus 22 mission sub-scripts; up to 2 threads live
- ran 27893 ticks, ended in game over
- missions: 1 started, 0 passed, 1 failed; phones rang 0 times
- player: wasted 3, busted 0; arrow shown 1 ticks; teleports 15; phones stood at 18
- unhandled commands met: 1588
- threads on one command for 3000+ ticks: 0
- step: mean 0.0796 ms, p99 0.1598 ms, max 0.3063 ms
- invariant breaks: 0
- mission log:
  - tick 1910: mission started
  - tick 2138: mission failed after 228 ticks

```
invariants: 27893 ticks checked, 0 breaks
ticks 27893
kills 4
player_kills 0
run_over 2
fire_kills 2
suicides 0
explosions 1
pickups 6
rounds 0
shots 6
shot_hits 2
ped_deaths 18
car_wrecks 6
boardings 11
exits 9
contacts 500812
impacts 3197
wall_hits 24309
driven 589
walked 84
ticks_in_cars 17854
score_total 840270
max_kills 0
max_deaths 4
final_cars 196
final_peds 44
```

## wil.gmp

- scripts: main plus 23 mission sub-scripts; up to 3 threads live
- ran 30000 ticks
- missions: 1 started, 0 passed, 0 failed; phones rang 0 times
- player: wasted 0, busted 0; arrow shown 1 ticks; teleports 4; phones stood at 6
- unhandled commands met: 30379
- threads on one command for 3000+ ticks: 1
  - thread 1 at command 790 (type 77), noticed at tick 4660
- step: mean 0.0522 ms, p99 0.0843 ms, max 0.2037 ms
- invariant breaks: 0
- mission log:
  - tick 21: mission started

```
invariants: 30000 ticks checked, 0 breaks
ticks 30000
kills 0
player_kills 0
run_over 0
fire_kills 0
suicides 0
explosions 0
pickups 1
rounds 0
shots 0
shot_hits 0
ped_deaths 11
car_wrecks 0
boardings 1
exits 1
contacts 7789
impacts 803
wall_hits 1332
driven 54
walked 49
ticks_in_cars 1669
score_total 34
max_kills 0
max_deaths 0
final_cars 83
final_peds 70
```

