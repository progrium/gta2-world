# Golden re-record report

Written by `replay rerecord` (tools/replay). Compare with the previous `stats.txt` in git history; the commit that changes the golden explains why.

- final hash before: `90ea3d22601acaaa`
- final hash after: `e79cfeae057492d4`
- state size: 55840 bytes, layout hash `e612733ecc94105e`
- invariant breaks in the new recording: 0

| measure | before | after | change |
|---|---:|---:|---:|
| ticks | 10000 | 10000 | same |
| kills | 15 | 14 | -6.7% |
| player_kills | 10 | 7 | -30.0% |
| run_over | 11 | 8 | -27.3% |
| fire_kills | 4 | 6 | +50.0% |
| suicides | 1 | 1 | same |
| explosions | 14 | 16 | +14.3% |
| pickups | 21 | 22 | +4.8% |
| rounds | 0 | 0 | same |
| shots | 1044 | 1057 | +1.2% |
| shot_hits | 32 | 29 | -9.4% |
| ped_deaths | 31 | 35 | +12.9% |
| car_wrecks | 3 | 5 | +66.7% |
| boardings | 139 | 142 | +2.2% |
| exits | 125 | 128 | +2.4% |
| contacts | 15236 | 15390 | +1.0% |
| impacts | 464 | 303 | -34.7% |
| wall_hits | 12098 | 11344 | -6.2% |
| driven | 15770 | 15528 | -1.5% |
| walked | 3570 | 3666 | +2.7% |
| ticks_in_cars | 88738 | 88888 | +0.2% |
| score_total | 16492 | 12504 | -24.2% |
| max_kills | 2 | 2 | same |
| max_deaths | 3 | 2 | -33.3% |
| final_cars | 22 | 21 | -4.5% |
| final_peds | 125 | 126 | +0.8% |

```
invariants: 10000 ticks checked, 0 breaks
```
