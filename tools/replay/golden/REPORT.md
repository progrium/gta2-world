# Golden re-record report

Written by `replay rerecord` (tools/replay). Compare with the previous `stats.txt` in git history; the commit that changes the golden explains why.

- final hash before: `f999fd0d15093ec8`
- final hash after: `90ea3d22601acaaa`
- state size: 55840 bytes, layout hash `40dcdbb0d861a32b`
- invariant breaks in the new recording: 0

| measure | before | after | change |
|---|---:|---:|---:|
| ticks | 10000 | 10000 | same |
| kills | 15 | 15 | same |
| player_kills | 9 | 10 | +11.1% |
| run_over | 10 | 11 | +10.0% |
| fire_kills | 5 | 4 | -20.0% |
| suicides | 3 | 1 | -66.7% |
| explosions | 20 | 14 | -30.0% |
| pickups | 13 | 21 | +61.5% |
| rounds | 0 | 0 | same |
| shots | 1029 | 1044 | +1.5% |
| shot_hits | 46 | 32 | -30.4% |
| ped_deaths | 43 | 31 | -27.9% |
| car_wrecks | 4 | 3 | -25.0% |
| boardings | 154 | 139 | -9.7% |
| exits | 138 | 125 | -9.4% |
| contacts | 15599 | 15236 | -2.3% |
| impacts | 512 | 464 | -9.4% |
| wall_hits | 14554 | 12098 | -16.9% |
| driven | 16307 | 15770 | -3.3% |
| walked | 3446 | 3570 | +3.6% |
| ticks_in_cars | 92848 | 88738 | -4.4% |
| score_total | 15535 | 16492 | +6.2% |
| max_kills | 2 | 2 | same |
| max_deaths | 3 | 3 | same |
| final_cars | 24 | 22 | -8.3% |
| final_peds | 127 | 125 | -1.6% |

```
invariants: 10000 ticks checked, 0 breaks
```
