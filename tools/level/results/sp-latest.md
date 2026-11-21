# Level runner results: single player

Written by `tools/level --sp` (workstream Q). Each level runs its own script in the `sp` configuration for 30000 ticks, seed 1e7e1. The autopilot follows the mission arrow, else the last phone that rang, else road waypoints; it is teleported to its target after 1800 ticks.

## bil.gmp

- scripts: main plus 22 mission sub-scripts; up to 3 threads live
- ran 30000 ticks
- missions: 1 started, 0 passed, 0 failed; phones rang 0 times
- player: wasted 0, busted 0; arrow shown 28163 ticks; teleports 2; phones stood at 3
- unhandled commands met: 32
- threads on one command for 3000+ ticks: 0
- step: mean 0.0671 ms, p99 0.2420 ms, max 0.4692 ms
- invariant breaks: 0
- mission log:
  - tick 1803: mission started

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
ped_deaths 1
car_wrecks 0
boardings 878
exits 878
contacts 147113
impacts 17
wall_hits 10
driven 0
walked 142
ticks_in_cars 1755
score_total 0
max_kills 0
max_deaths 0
final_cars 71
final_peds 54
```

## lorne2e.gmp

- scripts: main plus 0 mission sub-scripts; up to 1 threads live
- ran 30000 ticks
- missions: 0 started, 0 passed, 0 failed; phones rang 0 times
- player: wasted 0, busted 0; arrow shown 29992 ticks; teleports 0; phones stood at 0
- unhandled commands met: 67
- threads on one command for 3000+ ticks: 0
- step: mean 0.0939 ms, p99 0.1397 ms, max 0.2380 ms
- invariant breaks: 0

```
invariants: 30000 ticks checked, 0 breaks
ticks 30000
kills 0
player_kills 0
run_over 0
fire_kills 0
suicides 0
explosions 0
pickups 0
rounds 0
shots 0
shot_hits 0
ped_deaths 21
car_wrecks 0
boardings 926
exits 926
contacts 113075
impacts 4596
wall_hits 1453
driven 51
walked 163
ticks_in_cars 2760
score_total -173810
max_kills 0
max_deaths 0
final_cars 54
final_peds 170
```

## lorne2h.gmp

- scripts: main plus 0 mission sub-scripts; up to 1 threads live
- ran 30000 ticks
- missions: 0 started, 0 passed, 0 failed; phones rang 0 times
- player: wasted 1, busted 0; arrow shown 30000 ticks; teleports 0; phones stood at 0
- unhandled commands met: 84
- threads on one command for 3000+ ticks: 0
- step: mean 0.0740 ms, p99 0.1174 ms, max 0.2849 ms
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
pickups 0
rounds 0
shots 0
shot_hits 0
ped_deaths 10
car_wrecks 6
boardings 6
exits 4
contacts 73019
impacts 868
wall_hits 59436
driven 20
walked 10
ticks_in_cars 29808
score_total -74988
max_kills 0
max_deaths 1
final_cars 59
final_peds 167
```

## lorne2m.gmp

- scripts: main plus 0 mission sub-scripts; up to 1 threads live
- ran 30000 ticks
- missions: 0 started, 0 passed, 0 failed; phones rang 0 times
- player: wasted 1, busted 0; arrow shown 29992 ticks; teleports 0; phones stood at 0
- unhandled commands met: 74
- threads on one command for 3000+ ticks: 0
- step: mean 0.0736 ms, p99 0.1400 ms, max 0.5430 ms
- invariant breaks: 0

```
invariants: 30000 ticks checked, 0 breaks
ticks 30000
kills 1
player_kills 0
run_over 1
fire_kills 0
suicides 0
explosions 1
pickups 0
rounds 0
shots 0
shot_hits 0
ped_deaths 19
car_wrecks 1
boardings 6
exits 4
contacts 45922
impacts 2311
wall_hits 33868
driven 397
walked 36
ticks_in_cars 28779
score_total -173912
max_kills 0
max_deaths 1
final_cars 52
final_peds 167
```

## mike1e.gmp

- scripts: main plus 0 mission sub-scripts; up to 1 threads live
- ran 30000 ticks
- missions: 0 started, 0 passed, 0 failed; phones rang 0 times
- player: wasted 1, busted 0; arrow shown 0 ticks; teleports 13; phones stood at 0
- unhandled commands met: 64
- threads on one command for 3000+ ticks: 0
- step: mean 0.0134 ms, p99 0.0346 ms, max 0.3522 ms
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
pickups 1
rounds 0
shots 0
shot_hits 0
ped_deaths 4
car_wrecks 0
boardings 15
exits 14
contacts 22579
impacts 31
wall_hits 14755
driven 744
walked 344
ticks_in_cars 22452
score_total 95032
max_kills 0
max_deaths 1
final_cars 6
final_peds 23
```

## mike1h.gmp

- scripts: main plus 0 mission sub-scripts; up to 1 threads live
- ran 30000 ticks
- missions: 0 started, 0 passed, 0 failed; phones rang 0 times
- player: wasted 2, busted 0; arrow shown 89 ticks; teleports 15; phones stood at 0
- unhandled commands met: 58
- threads on one command for 3000+ ticks: 0
- step: mean 0.0098 ms, p99 0.0362 ms, max 0.1277 ms
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
pickups 3
rounds 0
shots 0
shot_hits 0
ped_deaths 6
car_wrecks 33
boardings 8
exits 6
contacts 20038
impacts 95
wall_hits 9957
driven 657
walked 90
ticks_in_cars 21014
score_total 95071
max_kills 0
max_deaths 2
final_cars 2
final_peds 21
```

## mike1m.gmp

- scripts: main plus 0 mission sub-scripts; up to 1 threads live
- ran 8891 ticks, ended in game over
- missions: 0 started, 0 passed, 0 failed; phones rang 0 times
- player: wasted 3, busted 0; arrow shown 0 ticks; teleports 4; phones stood at 0
- unhandled commands met: 58
- threads on one command for 3000+ ticks: 0
- step: mean 0.0139 ms, p99 0.0666 ms, max 3.1105 ms
- invariant breaks: 0

```
invariants: 8891 ticks checked, 0 breaks
ticks 8891
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
ped_deaths 5
car_wrecks 13
boardings 10
exits 8
contacts 2326
impacts 73
wall_hits 4308
driven 250
walked 58
ticks_in_cars 6620
score_total 95078
max_kills 0
max_deaths 4
final_cars 2
final_peds 25
```

## mike2e.gmp

- scripts: main plus 0 mission sub-scripts; up to 1 threads live
- ran 30000 ticks
- missions: 0 started, 0 passed, 0 failed; phones rang 0 times
- player: wasted 2, busted 0; arrow shown 0 ticks; teleports 10; phones stood at 0
- unhandled commands met: 26
- threads on one command for 3000+ ticks: 0
- step: mean 0.0891 ms, p99 0.2889 ms, max 1.1225 ms
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
- unhandled commands met: 29
- threads on one command for 3000+ ticks: 0
- step: mean 0.0807 ms, p99 0.2582 ms, max 2.6675 ms
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
- unhandled commands met: 29
- threads on one command for 3000+ ticks: 0
- step: mean 0.0772 ms, p99 0.2419 ms, max 0.4582 ms
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
- ran 30000 ticks
- missions: 1 started, 0 passed, 1 failed; phones rang 0 times
- player: wasted 1, busted 0; arrow shown 28067 ticks; teleports 2; phones stood at 3
- unhandled commands met: 1218
- threads on one command for 3000+ ticks: 0
- step: mean 0.1155 ms, p99 0.1895 ms, max 0.3528 ms
- invariant breaks: 0
- mission log:
  - tick 1910: mission started
  - tick 2142: mission failed after 232 ticks

```
invariants: 30000 ticks checked, 0 breaks
ticks 30000
kills 1
player_kills 0
run_over 0
fire_kills 1
suicides 0
explosions 0
pickups 0
rounds 0
shots 6
shot_hits 2
ped_deaths 8
car_wrecks 1
boardings 1752
exits 1752
contacts 703284
impacts 1844
wall_hits 1963
driven 152
walked 119
ticks_in_cars 4870
score_total 840346
max_kills 0
max_deaths 1
final_cars 196
final_peds 44
```

## wil.gmp

- scripts: main plus 23 mission sub-scripts; up to 3 threads live
- ran 30000 ticks
- missions: 1 started, 0 passed, 0 failed; phones rang 0 times
- player: wasted 0, busted 0; arrow shown 28324 ticks; teleports 2; phones stood at 3
- unhandled commands met: 30019
- threads on one command for 3000+ ticks: 1
  - thread 1 at command 790 (type 77), noticed at tick 4660
- step: mean 0.0900 ms, p99 0.1187 ms, max 0.2234 ms
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
ped_deaths 2
car_wrecks 0
boardings 3
exits 2
contacts 3210
impacts 257
wall_hits 3076
driven 107
walked 15
ticks_in_cars 4666
score_total 140
max_kills 0
max_deaths 0
final_cars 83
final_peds 70
```

