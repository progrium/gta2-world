# Level runner results: single player

Written by `tools/level --sp` (workstream Q). Each level runs its own script in the `sp` configuration for 30000 ticks, seed 1e7e1. The autopilot follows the mission arrow, else the last phone that rang, else road waypoints; it is teleported to its target after 1800 ticks.

## bil.gmp

- scripts: main plus 22 mission sub-scripts; up to 2 threads live
- ran 30000 ticks
- missions: 0 started, 0 passed, 0 failed; phones rang 0 times
- player: wasted 1, busted 0; arrow shown 1 ticks; teleports 15
- unhandled commands met: 200
- threads on one command for 3000+ ticks: 0
- step: mean 0.0779 ms, p99 0.1136 ms, max 1.1695 ms
- invariant breaks: 1

```
invariants: 30000 ticks checked, 1 breaks
  riding: 1
  first: riding tick 13780 id 00051042 at (0.00, 0.00, 0.00)
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
ped_deaths 39
car_wrecks 1
boardings 18
exits 16
contacts 54545
impacts 1103
wall_hits 15466
driven 1067
walked 66
ticks_in_cars 24183
score_total 658
max_kills 0
max_deaths 1
final_cars 98
final_peds 102
```

## lorne2e.gmp

- scripts: main plus 0 mission sub-scripts; up to 1 threads live
- ran 30000 ticks
- missions: 0 started, 0 passed, 0 failed; phones rang 0 times
- player: wasted 3, busted 0; arrow shown 0 ticks; teleports 12
- unhandled commands met: 346
- threads on one command for 3000+ ticks: 0
- step: mean 0.0886 ms, p99 0.1437 ms, max 1.7893 ms
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
- player: wasted 3, busted 0; arrow shown 200 ticks; teleports 0
- unhandled commands met: 372
- threads on one command for 3000+ ticks: 0
- step: mean 0.0604 ms, p99 0.0921 ms, max 0.1346 ms
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
- player: wasted 2, busted 0; arrow shown 0 ticks; teleports 15
- unhandled commands met: 353
- threads on one command for 3000+ ticks: 0
- step: mean 0.0733 ms, p99 0.1228 ms, max 0.2645 ms
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
- player: wasted 1, busted 0; arrow shown 0 ticks; teleports 14
- unhandled commands met: 414
- threads on one command for 3000+ ticks: 0
- step: mean 0.0094 ms, p99 0.0263 ms, max 0.0827 ms
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
- player: wasted 3, busted 0; arrow shown 89 ticks; teleports 14
- unhandled commands met: 406
- threads on one command for 3000+ ticks: 0
- step: mean 0.0092 ms, p99 0.0315 ms, max 0.0796 ms
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
- player: wasted 3, busted 0; arrow shown 0 ticks; teleports 4
- unhandled commands met: 390
- threads on one command for 3000+ ticks: 0
- step: mean 0.0187 ms, p99 0.0614 ms, max 0.1270 ms
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
- player: wasted 2, busted 0; arrow shown 0 ticks; teleports 10
- unhandled commands met: 157
- threads on one command for 3000+ ticks: 0
- step: mean 0.0782 ms, p99 0.2641 ms, max 3.1799 ms
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
- step: mean 0.0688 ms, p99 0.2342 ms, max 0.4153 ms
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
- step: mean 0.0693 ms, p99 0.2258 ms, max 0.4163 ms
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
- player: wasted 1, busted 0; arrow shown 1 ticks; teleports 15
- unhandled commands met: 1655
- threads on one command for 3000+ ticks: 0
- step: mean 0.0859 ms, p99 0.1562 ms, max 0.2835 ms
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
pickups 3
rounds 0
shots 6
shot_hits 2
ped_deaths 23
car_wrecks 3
boardings 222
exits 11
contacts 588105
impacts 3169
wall_hits 15922
driven 690
walked 154
ticks_in_cars 21492
score_total 841694
max_kills 0
max_deaths 1
final_cars 198
final_peds 43
```

## wil.gmp

- scripts: main plus 23 mission sub-scripts; up to 1 threads live
- ran 30000 ticks
- missions: 0 started, 0 passed, 0 failed; phones rang 0 times
- player: wasted 2, busted 0; arrow shown 1 ticks; teleports 15
- unhandled commands met: 30375
- threads on one command for 3000+ ticks: 1
  - thread 1 at command 795 (type 77), noticed at tick 3005
- step: mean 0.0635 ms, p99 0.0969 ms, max 0.1986 ms
- invariant breaks: 1

```
invariants: 30000 ticks checked, 1 breaks
  riding: 1
  first: riding tick 14202 id 00061058 at (0.00, 0.00, 0.00)
ticks 30000
kills 2
player_kills 0
run_over 0
fire_kills 2
suicides 0
explosions 2
pickups 5
rounds 0
shots 0
shot_hits 0
ped_deaths 29
car_wrecks 2
boardings 21
exits 18
contacts 21882
impacts 1973
wall_hits 20211
driven 965
walked 74
ticks_in_cars 25121
score_total 551
max_kills 0
max_deaths 2
final_cars 81
final_peds 70
```

