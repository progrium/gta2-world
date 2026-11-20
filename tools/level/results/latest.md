# Level runner results

Written by `tools/level` (workstream Q). 20000 ticks per map, autopilot in slot 0, 7 bots, seed 1e7e1, teleport after 1800 ticks. Targets: random road waypoints (no mission arrow in the sim yet).

## bil-multi.gmp

- road cells: 15538
- autopilot trips: 14 (0 reached on foot, 4 by car, 10 teleported after 1800 ticks); mean 1374 ticks a trip
- autopilot deaths: 1; ticks with no ped: 70
- step: mean 0.0248 ms, p99 0.0606 ms, max 2.0547 ms
- invariant breaks: 0

```
invariants: 20000 ticks checked, 0 breaks
ticks 20000
kills 6
player_kills 0
run_over 0
fire_kills 6
suicides 4
explosions 20
pickups 12
rounds 0
shots 584
shot_hits 33
ped_deaths 27
car_wrecks 6
boardings 133
exits 126
contacts 5016
impacts 138
wall_hits 75698
driven 4898
walked 1570
ticks_in_cars 93363
score_total 3626
max_kills 0
max_deaths 2
final_cars 24
final_peds 108
```

## bil.gmp

- road cells: 15554
- autopilot trips: 16 (3 reached on foot, 5 by car, 8 teleported after 1800 ticks); mean 1205 ticks a trip
- autopilot deaths: 1; ticks with no ped: 70
- step: mean 0.0225 ms, p99 0.0400 ms, max 1.9415 ms
- invariant breaks: 2

```
invariants: 20000 ticks checked, 2 breaks
  below_world: 1
  void: 1
  first: void tick 15439 id 0001106a at (14.32, 115.26, 1.64)
  first: below_world tick 15456 id 0001106a at (14.32, 115.26, -0.05)
ticks 20000
kills 6
player_kills 0
run_over 2
fire_kills 4
suicides 4
explosions 11
pickups 12
rounds 0
shots 626
shot_hits 35
ped_deaths 27
car_wrecks 6
boardings 117
exits 112
contacts 8416
impacts 791
wall_hits 52550
driven 5359
walked 2009
ticks_in_cars 83111
score_total 4615
max_kills 0
max_deaths 1
final_cars 24
final_peds 108
```

## lorne2e.gmp

- road cells: 1082
- autopilot trips: 17 (0 reached on foot, 12 by car, 5 teleported after 1800 ticks); mean 1075 ticks a trip
- autopilot deaths: 5; ticks with no ped: 350
- step: mean 0.0206 ms, p99 0.0370 ms, max 2.8848 ms
- invariant breaks: 0

```
invariants: 20000 ticks checked, 0 breaks
ticks 20000
kills 11
player_kills 0
run_over 2
fire_kills 9
suicides 1
explosions 31
pickups 37
rounds 0
shots 3072
shot_hits 96
ped_deaths 52
car_wrecks 4
boardings 40
exits 34
contacts 6046
impacts 975
wall_hits 18266
driven 2947
walked 7185
ticks_in_cars 39422
score_total 2816
max_kills 0
max_deaths 5
final_cars 13
final_peds 108
```

## lorne2h.gmp

- road cells: 940
- autopilot trips: 13 (1 reached on foot, 2 by car, 10 teleported after 1800 ticks); mean 1455 ticks a trip
- autopilot deaths: 9; ticks with no ped: 630
- step: mean 0.0185 ms, p99 0.0343 ms, max 1.6166 ms
- invariant breaks: 0

```
invariants: 20000 ticks checked, 0 breaks
ticks 20000
kills 9
player_kills 0
run_over 0
fire_kills 9
suicides 0
explosions 5
pickups 25
rounds 0
shots 3127
shot_hits 81
ped_deaths 22
car_wrecks 11
boardings 3
exits 0
contacts 4332
impacts 11
wall_hits 4266
driven 124
walked 8299
ticks_in_cars 2343
score_total 268
max_kills 0
max_deaths 9
final_cars 7
final_peds 108
```

## lorne2m.gmp

- road cells: 848
- autopilot trips: 23 (0 reached on foot, 13 by car, 10 teleported after 1800 ticks); mean 859 ticks a trip
- autopilot deaths: 1; ticks with no ped: 70
- step: mean 0.0182 ms, p99 0.0335 ms, max 0.3160 ms
- invariant breaks: 0

```
invariants: 20000 ticks checked, 0 breaks
ticks 20000
kills 1
player_kills 0
run_over 1
fire_kills 0
suicides 0
explosions 4
pickups 19
rounds 0
shots 3482
shot_hits 70
ped_deaths 18
car_wrecks 1
boardings 2
exits 0
contacts 2370
impacts 206
wall_hits 14008
driven 859
walked 8693
ticks_in_cars 18050
score_total 441
max_kills 0
max_deaths 1
final_cars 13
final_peds 108
```

## mike1e.gmp

- road cells: 303
- autopilot trips: 19 (0 reached on foot, 9 by car, 10 teleported after 1800 ticks); mean 1037 ticks a trip
- autopilot deaths: 0; ticks with no ped: 0
- step: mean 0.0145 ms, p99 0.0300 ms, max 0.1295 ms
- invariant breaks: 0

```
invariants: 20000 ticks checked, 0 breaks
ticks 20000
kills 16
player_kills 4
run_over 4
fire_kills 11
suicides 1
explosions 8
pickups 23
rounds 0
shots 357
shot_hits 18
ped_deaths 56
car_wrecks 4
boardings 73
exits 68
contacts 59255
impacts 588
wall_hits 32950
driven 3102
walked 957
ticks_in_cars 58276
score_total 8473
max_kills 1
max_deaths 8
final_cars 12
final_peds 51
```

## mike1h.gmp

- road cells: 333
- autopilot trips: 13 (0 reached on foot, 3 by car, 10 teleported after 1800 ticks); mean 1494 ticks a trip
- autopilot deaths: 2; ticks with no ped: 141
- step: mean 0.0160 ms, p99 0.0401 ms, max 0.5814 ms
- invariant breaks: 0

```
invariants: 20000 ticks checked, 0 breaks
ticks 20000
kills 30
player_kills 5
run_over 11
fire_kills 19
suicides 5
explosions 56
pickups 81
rounds 0
shots 1728
shot_hits 68
ped_deaths 87
car_wrecks 25
boardings 87
exits 70
contacts 13748
impacts 2676
wall_hits 31815
driven 3214
walked 3481
ticks_in_cars 62554
score_total 12273
max_kills 1
max_deaths 6
final_cars 9
final_peds 45
```

## mike1m.gmp

- road cells: 673
- autopilot trips: 14 (2 reached on foot, 3 by car, 9 teleported after 1800 ticks); mean 1358 ticks a trip
- autopilot deaths: 7; ticks with no ped: 490
- step: mean 0.0193 ms, p99 0.0390 ms, max 0.1520 ms
- invariant breaks: 0

```
invariants: 20000 ticks checked, 0 breaks
ticks 20000
kills 39
player_kills 8
run_over 8
fire_kills 31
suicides 1
explosions 1
pickups 58
rounds 0
shots 1109
shot_hits 54
ped_deaths 83
car_wrecks 63
boardings 52
exits 31
contacts 27140
impacts 185
wall_hits 19847
driven 1822
walked 2558
ticks_in_cars 37734
score_total 11461
max_kills 3
max_deaths 7
final_cars 10
final_peds 82
```

## mike2e.gmp

- road cells: 58999
- autopilot trips: 17 (11 reached on foot, 0 by car, 6 teleported after 1800 ticks); mean 1171 ticks a trip
- autopilot deaths: 0; ticks with no ped: 0
- step: mean 0.0172 ms, p99 0.0339 ms, max 0.1435 ms
- invariant breaks: 1

```
invariants: 20000 ticks checked, 1 breaks
  inside_matter: 1
  first: inside_matter tick 6201 id 00001064 at (163.14, 203.52, 2.52)
ticks 20000
kills 0
player_kills 0
run_over 0
fire_kills 0
suicides 0
explosions 3
pickups 26
rounds 0
shots 3644
shot_hits 108
ped_deaths 21
car_wrecks 0
boardings 0
exits 0
contacts 2936
impacts 0
wall_hits 0
driven 0
walked 9242
ticks_in_cars 0
score_total 420
max_kills 0
max_deaths 0
final_cars 0
final_peds 108
```

## mike2h.gmp

- road cells: 61271
- autopilot trips: 25 (24 reached on foot, 0 by car, 1 teleported after 1800 ticks); mean 781 ticks a trip
- autopilot deaths: 5; ticks with no ped: 350
- step: mean 0.0172 ms, p99 0.0328 ms, max 0.1592 ms
- invariant breaks: 0

```
invariants: 20000 ticks checked, 0 breaks
ticks 20000
kills 10
player_kills 0
run_over 0
fire_kills 10
suicides 0
explosions 3
pickups 25
rounds 0
shots 3374
shot_hits 102
ped_deaths 26
car_wrecks 0
boardings 0
exits 0
contacts 3049
impacts 0
wall_hits 0
driven 0
walked 9716
ticks_in_cars 0
score_total 320
max_kills 0
max_deaths 5
final_cars 0
final_peds 108
```

## mike2m.gmp

- road cells: 65536
- autopilot trips: 23 (22 reached on foot, 0 by car, 1 teleported after 1800 ticks); mean 792 ticks a trip
- autopilot deaths: 0; ticks with no ped: 0
- step: mean 0.0171 ms, p99 0.0325 ms, max 0.0646 ms
- invariant breaks: 0

```
invariants: 20000 ticks checked, 0 breaks
ticks 20000
kills 0
player_kills 0
run_over 0
fire_kills 0
suicides 0
explosions 3
pickups 32
rounds 0
shots 3781
shot_hits 119
ped_deaths 17
car_wrecks 0
boardings 0
exits 0
contacts 2351
impacts 0
wall_hits 0
driven 0
walked 9642
ticks_in_cars 0
score_total 340
max_kills 0
max_deaths 0
final_cars 0
final_peds 108
```

## mp1-comp.gmp

- road cells: 833
- autopilot trips: 13 (2 reached on foot, 4 by car, 7 teleported after 1800 ticks); mean 1401 ticks a trip
- autopilot deaths: 2; ticks with no ped: 140
- step: mean 0.0159 ms, p99 0.0373 ms, max 0.1090 ms
- invariant breaks: 0

```
invariants: 20000 ticks checked, 0 breaks
ticks 20000
kills 51
player_kills 9
run_over 11
fire_kills 40
suicides 4
explosions 13
pickups 76
rounds 0
shots 590
shot_hits 45
ped_deaths 132
car_wrecks 44
boardings 128
exits 98
contacts 9870
impacts 1405
wall_hits 36984
driven 4751
walked 1618
ticks_in_cars 83134
score_total 16879
max_kills 3
max_deaths 12
final_cars 19
final_peds 45
```

## mp2-comp.gmp

- road cells: 890
- autopilot trips: 16 (0 reached on foot, 8 by car, 8 teleported after 1800 ticks); mean 1153 ticks a trip
- autopilot deaths: 1; ticks with no ped: 70
- step: mean 0.0209 ms, p99 0.0392 ms, max 0.0927 ms
- invariant breaks: 0

```
invariants: 20000 ticks checked, 0 breaks
ticks 20000
kills 23
player_kills 3
run_over 5
fire_kills 18
suicides 3
explosions 42
pickups 50
rounds 0
shots 978
shot_hits 28
ped_deaths 91
car_wrecks 35
boardings 108
exits 89
contacts 13406
impacts 1238
wall_hits 29893
driven 5291
walked 2238
ticks_in_cars 75255
score_total 7820
max_kills 1
max_deaths 5
final_cars 17
final_peds 94
```

## mp5-comp.gmp

- road cells: 1610
- autopilot trips: 13 (2 reached on foot, 2 by car, 9 teleported after 1800 ticks); mean 1467 ticks a trip
- autopilot deaths: 7; ticks with no ped: 490
- step: mean 0.0223 ms, p99 0.0412 ms, max 0.1526 ms
- invariant breaks: 0

```
invariants: 20000 ticks checked, 0 breaks
ticks 20000
kills 32
player_kills 5
run_over 7
fire_kills 25
suicides 4
explosions 51
pickups 51
rounds 0
shots 1163
shot_hits 32
ped_deaths 117
car_wrecks 36
boardings 115
exits 96
contacts 17077
impacts 1345
wall_hits 27122
driven 4157
walked 2872
ticks_in_cars 71391
score_total 9905
max_kills 1
max_deaths 9
final_cars 21
final_peds 102
```

## ste.gmp

- road cells: 17122
- autopilot trips: 14 (1 reached on foot, 3 by car, 10 teleported after 1800 ticks); mean 1395 ticks a trip
- autopilot deaths: 1; ticks with no ped: 70
- step: mean 0.0215 ms, p99 0.0402 ms, max 0.1476 ms
- invariant breaks: 3

```
invariants: 20000 ticks checked, 3 breaks
  below_world: 2
  void: 1
  first: void tick 5252 id 00020001 at (62.93, 240.67, 0.19)
  first: below_world tick 5254 id 0000106b at (62.93, 240.67, -0.06)
  first: below_world tick 5254 id 00020001 at (62.93, 240.67, -0.06)
ticks 20000
kills 8
player_kills 1
run_over 1
fire_kills 7
suicides 2
explosions 12
pickups 9
rounds 0
shots 929
shot_hits 26
ped_deaths 22
car_wrecks 7
boardings 52
exits 43
contacts 3878
impacts 133
wall_hits 21872
driven 2422
walked 2061
ticks_in_cars 61468
score_total 3512
max_kills 1
max_deaths 2
final_cars 24
final_peds 108
```

## wil-multi.gmp

- road cells: 16285
- autopilot trips: 11 (1 reached on foot, 1 by car, 9 teleported after 1800 ticks); mean 1710 ticks a trip
- autopilot deaths: 1; ticks with no ped: 70
- step: mean 0.0220 ms, p99 0.0396 ms, max 0.0763 ms
- invariant breaks: 0

```
invariants: 20000 ticks checked, 0 breaks
ticks 20000
kills 8
player_kills 3
run_over 4
fire_kills 3
suicides 2
explosions 7
pickups 13
rounds 0
shots 583
shot_hits 30
ped_deaths 37
car_wrecks 5
boardings 107
exits 102
contacts 35722
impacts 496
wall_hits 29815
driven 4679
walked 1552
ticks_in_cars 72714
score_total 7791
max_kills 1
max_deaths 3
final_cars 24
final_peds 108
```

## wil.gmp

- road cells: 16285
- autopilot trips: 11 (1 reached on foot, 1 by car, 9 teleported after 1800 ticks); mean 1710 ticks a trip
- autopilot deaths: 1; ticks with no ped: 70
- step: mean 0.0213 ms, p99 0.0382 ms, max 0.1134 ms
- invariant breaks: 3

```
invariants: 20000 ticks checked, 3 breaks
  below_world: 2
  void: 1
  first: void tick 4400 id 00010011 at (13.02, 31.52, 2.19)
  first: below_world tick 4418 id 00001068 at (13.02, 31.52, -0.06)
  first: below_world tick 4418 id 00010011 at (13.02, 31.52, -0.06)
ticks 20000
kills 7
player_kills 2
run_over 2
fire_kills 4
suicides 3
explosions 7
pickups 12
rounds 0
shots 647
shot_hits 28
ped_deaths 32
car_wrecks 5
boardings 91
exits 85
contacts 12461
impacts 487
wall_hits 27978
driven 4202
walked 1701
ticks_in_cars 77999
score_total 6694
max_kills 1
max_deaths 3
final_cars 24
final_peds 108
```

